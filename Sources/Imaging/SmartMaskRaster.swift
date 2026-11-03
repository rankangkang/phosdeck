import Foundation
import CoreImage
import CryptoKit
import Compression
import os

enum SmartMaskPart: String, CaseIterable, Identifiable, Codable {
    case faceSkin, bodySkin, hair, clothes, brows, eyes, lips
    var id: String { rawValue }
    var title: String {
        switch self {
        case .faceSkin: L10n.text("app.facialSkin", defaultValue: "Facial Skin")
        case .bodySkin: L10n.text("app.bodySkin", defaultValue: "Body Skin")
        case .hair: L10n.text("app.hair", defaultValue: "Hair")
        case .clothes: L10n.text("app.clothes", defaultValue: "Clothes")
        case .brows: L10n.text("app.eyebrows", defaultValue: "Eyebrows")
        case .eyes: L10n.text("app.entireEyes", defaultValue: "Entire Eyes")
        case .lips: L10n.text("app.lips", defaultValue: "Lips")
        }
    }
}

struct SmartMaskSource: Codable, Equatable {
    var digest: String
    var decoder: String
    var lensCorrection: Bool?
    var size: CGSize
    init(recipe: EditRecipe, size: CGSize) {
        digest = recipe.sourceDigest; decoder = recipe.decoderVersion
        lensCorrection = recipe.rawDetails.lensCorrection; self.size = size
    }
    func matches(_ recipe: EditRecipe) -> Bool {
        digest == recipe.sourceDigest && decoder == recipe.decoderVersion && lensCorrection == recipe.rawDetails.lensCorrection
    }
    func validate() throws {
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit), !decoder.isEmpty, decoder.count <= 200,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 100_000, size.height <= 100_000 else { throw LRCError(L10n.text("app.invalidSmartMaskSourceInformation", defaultValue: "Invalid smart mask source information")) }
    }
}

/// Pixels are top-to-bottom; the region is in the existing bottom-left source plane.
struct SmartMaskTile: Codable, Equatable {
    let width: Int
    let height: Int
    let region: CGRect
    let checksum: String
    let payload: Data
    private let identity = PayloadIdentity()
    private enum CodingKeys: String, CodingKey { case width, height, region, checksum, payload }
    static let maxPixels = 1024 * 1024
    private static let decoded = NSCache<NSString, NSData>()
    private static let cacheSetup: Void = { decoded.totalCostLimit = 64 * 1024 * 1024; decoded.countLimit = 128 }()

    private final class PayloadIdentity: @unchecked Sendable {
        private let stored = OSAllocatedUnfairLock<String?>(initialState: nil)
        func key(width: Int, height: Int, checksum: String, payload: Data) -> String {
            stored.withLock { key in
                if let key { return key }
                let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                let result = "\(width)x\(height):\(checksum):\(digest)"
                key = result
                return result
            }
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.region == rhs.region &&
            lhs.checksum == rhs.checksum && lhs.payload == rhs.payload
    }

    init(values: [Float], width: Int, height: Int, region: CGRect) throws {
        guard width > 0, height > 0, width <= Self.maxPixels / height, values.count == width * height,
              values.allSatisfy(\.isFinite) else { throw LRCError(L10n.text("app.smartMaskPixelsAreInvalidOrExceedTheLimit", defaultValue: "Smart mask pixels are invalid or exceed the limit")) }
        self.width = width; self.height = height; self.region = region
        var raw = Data(count: values.count * 2)
        raw.withUnsafeMutableBytes { bytes in
            let target = bytes.bindMemory(to: UInt16.self)
            for i in values.indices { target[i] = UInt16((min(1, max(0, values[i])) * 65535).rounded()).littleEndian }
        }
        checksum = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        var compressed = Data(count: raw.count * 2 + 1024)
        let count = compressed.withUnsafeMutableBytes { dst in raw.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_LZFSE)
        } }
        guard count > 0 else { throw LRCError(L10n.text("app.smartMaskCompressionFailed", defaultValue: "Smart mask compression failed")) }
        compressed.count = count; payload = compressed
        try validate()
    }
    var pixelCount: Int { width * height }
    func validate() throws {
        guard width > 0, height > 0, height <= Self.maxPixels, width <= Self.maxPixels / height,
              [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite),
              region.minX >= 0, region.minY >= 0, region.width > 0, region.height > 0,
              region.maxX <= 1.0000001, region.maxY <= 1.0000001,
              checksum.count == 64, checksum.allSatisfy(\.isHexDigit),
              !payload.isEmpty, payload.count <= width * height * 4 + 1024
        else { throw LRCError(L10n.text("app.smartMaskRasterIsInvalidOrExceedsTheLimit", defaultValue: "Smart mask raster is invalid or exceeds the limit")) }
        _ = try pixels()
    }
    func pixels() throws -> Data {
        guard width > 0, height > 0, height <= Self.maxPixels, width <= Self.maxPixels / height,
              !payload.isEmpty, payload.count <= width * height * 4 + 1024 else { throw LRCError(L10n.text("app.smartMaskDecompressionDimensionsExceedTheLimit", defaultValue: "Smart mask decompression dimensions exceed the limit")) }
        _ = Self.cacheSetup
        // Immutable tile copies share the fingerprint; decoded or changed bytes get a new identity.
        let key = identity.key(width: width, height: height, checksum: checksum, payload: payload) as NSString
        if let data = Self.decoded.object(forKey: key) { return data as Data }
        guard width > 0, height > 0, height <= Self.maxPixels, width <= Self.maxPixels / height else {
            throw LRCError(L10n.text("app.smartMaskDecompressionDimensionsExceedTheLimit", defaultValue: "Smart mask decompression dimensions exceed the limit"))
        }
        var raw = Data(count: width * height * 2)
        let count = raw.withUnsafeMutableBytes { dst in payload.withUnsafeBytes { src -> Int in
            guard let source = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                source, src.count, nil, COMPRESSION_LZFSE)
        } }
        guard count == raw.count, SHA256.hash(data: raw).map({ String(format: "%02x", $0) }).joined() == checksum else {
            throw LRCError(L10n.text("app.smartMaskDecompressionOrDigestVerificationFailedOriginalData", defaultValue: "Smart mask decompression or digest verification failed. Original data preserved"))
        }
        Self.decoded.setObject(raw as NSData, forKey: key, cost: raw.count)
        return raw
    }
    func image(extent: CGRect) throws -> CIImage {
        try validate()
        let raw = try pixels()
        guard let provider = CGDataProvider(data: raw as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: .byteOrder16Little, provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent) else { throw LRCError(L10n.text("app.couldNotReadSmartMaskCoverage", defaultValue: "Could not read smart mask coverage")) }
        let target = CGRect(x: extent.minX + region.minX * extent.width, y: extent.minY + region.minY * extent.height,
            width: region.width * extent.width, height: region.height * extent.height)
        return CIImage(cgImage: image, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: target.width / Double(width), y: target.height / Double(height)))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY)).cropped(to: target)
    }
}

/// One optional higher-resolution face patch replaces the coarse coverage in its ROI.
struct SmartMaskRaster: Codable, Equatable {
    var isPersonSelection: Bool { !parts.isEmpty || model.hasPrefix("vision-person-instance") }
    var source: SmartMaskSource
    var model: String
    var preprocessing = 1
    var base: SmartMaskTile
    var facePatch: SmartMaskTile?
    var instance: SmartMaskTile?
    var parts: [SmartMaskPart] = []
    var pixelCount: Int { base.pixelCount + (facePatch?.pixelCount ?? 0) + (instance?.pixelCount ?? 0) }
    var byteCount: Int { base.payload.count + (facePatch?.payload.count ?? 0) + (instance?.payload.count ?? 0) }
    func validate() throws {
        try source.validate()
        guard !model.isEmpty, model.count <= 300, preprocessing == 1 else { throw LRCError(L10n.text("app.invalidSmartMaskModelInformation", defaultValue: "Invalid smart mask model information")) }
        guard parts.count <= 7, Set(parts).count == parts.count, parts.isEmpty || instance != nil else { throw LRCError(L10n.text("app.bodyPartsAreMissingInstanceInformation", defaultValue: "Body parts are missing instance information")) }
        try base.validate(); try facePatch?.validate(); try instance?.validate()
    }
    func image(extent: CGRect) throws -> CIImage {
        var image = try base.image(extent: extent).composited(over: MaskPipeline.black(extent))
        if let facePatch { image = try facePatch.image(extent: extent).composited(over: image) }
        return image.cropped(to: extent)
    }
}
