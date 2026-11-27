import CLibRawBridge
import CoreGraphics
import CoreImage
import Foundation

public struct LibRawCameraLookHint: Equatable, Sendable {
    public let brand: String
    public let code: String
    public let name: String

    public init(brand: String, code: String, name: String) {
        self.brand = brand
        self.code = code
        self.name = name
    }
}

public struct LibRawProbeReport: Equatable, Sendable {
    public let openError: Int32
    public let unpackError: Int32
    public let dataErrorCount: Int32
    public let isUnsupported: Bool
    public let rawWidth: Int
    public let rawHeight: Int
    public let orientedWidth: Int
    public let orientedHeight: Int
    public let colors: Int
    public let hasColorFilterArray: Bool
    public let isXTrans: Bool
    public let isDNG: Bool
    public let blackLevel: UInt32
    public let whiteLevel: UInt32
    public let dataMaximum: UInt32
    public let sensorBits: Int?
    public let compression: String
    public let decoderName: String
    public let make: String
    public let model: String
    public let normalizedModel: String
    public let cameraMultipliers: (Float, Float, Float, Float)
    public let cameraLookHint: LibRawCameraLookHint?
    public let errorMessage: String

    public var isBitStreamCorrupted: Bool {
        dataErrorCount > 0 || unpackError == -100008 // LIBRAW_DATA_ERROR
    }

    public var succeeded: Bool {
        openError == 0 && unpackError == 0 && dataErrorCount == 0 && !isUnsupported
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.openError == rhs.openError && lhs.unpackError == rhs.unpackError &&
        lhs.dataErrorCount == rhs.dataErrorCount && lhs.isUnsupported == rhs.isUnsupported &&
        lhs.rawWidth == rhs.rawWidth && lhs.rawHeight == rhs.rawHeight &&
        lhs.orientedWidth == rhs.orientedWidth && lhs.orientedHeight == rhs.orientedHeight &&
        lhs.colors == rhs.colors && lhs.hasColorFilterArray == rhs.hasColorFilterArray && lhs.isXTrans == rhs.isXTrans && lhs.isDNG == rhs.isDNG &&
        lhs.blackLevel == rhs.blackLevel && lhs.whiteLevel == rhs.whiteLevel &&
        lhs.dataMaximum == rhs.dataMaximum && lhs.sensorBits == rhs.sensorBits &&
        lhs.compression == rhs.compression && lhs.decoderName == rhs.decoderName &&
        lhs.make == rhs.make && lhs.model == rhs.model && lhs.normalizedModel == rhs.normalizedModel &&
        lhs.cameraMultipliers == rhs.cameraMultipliers &&
        lhs.cameraLookHint == rhs.cameraLookHint && lhs.errorMessage == rhs.errorMessage
    }
}

public enum LibRawRuntimeError: LocalizedError, Equatable {
    case corruptedBitstream(String)
    case unsupported(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .corruptedBitstream(let msg): return msg
        case .unsupported(let msg): return msg
        case .decodeFailed(let msg): return msg
        }
    }
}

public struct LibRawLinearImage: @unchecked Sendable {
    public let image: CIImage
    public let width: Int
    public let height: Int
}

public enum LibRawRuntime {
    public static let decoderVersionIdentifier = "libraw-0.22-v1"

    public static let metalBayerVersion = "libraw-metal-bayer-v1"
    public static var metalBayerAvailable: Bool { phosdeck_metal_bayer_available() }

    public static var libraryVersion: String {
        String(cString: phosdeck_libraw_version())
    }

    public static func probe(url: URL, verifyBitstream: Bool = true) throws -> LibRawProbeReport {
        try Task.checkCancellation()
        var raw = PhosdeckLibRawProbe()
        url.path.withCString { cPath in
            phosdeck_libraw_probe(cPath, verifyBitstream, &raw)
        }
        try Task.checkCancellation()

        func readCString<T>(_ tuple: T) -> String {
            withUnsafePointer(to: tuple) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cstr in
                    String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        let make = readCString(raw.make)
        let model = readCString(raw.model)
        let normalized = readCString(raw.normalizedModel)
        let decoder = readCString(raw.decoderName)
        let nikonPC = readCString(raw.nikonPictureControl)
        let message = readCString(raw.errorMessage)
        let compression = classifyCompression(decoderName: decoder, isDNG: raw.isDNG)
        let lookHint = resolveCameraLookHint(make: make, fujiFilmMode: raw.fujiFilmMode, nikonPictureControl: nikonPC)

        return LibRawProbeReport(
            openError: raw.openError,
            unpackError: raw.unpackError,
            dataErrorCount: raw.dataErrorCount,
            isUnsupported: raw.isUnsupported,
            rawWidth: Int(raw.rawWidth),
            rawHeight: Int(raw.rawHeight),
            orientedWidth: Int(raw.flip & 4 == 0 ? raw.width : raw.height),
            orientedHeight: Int(raw.flip & 4 == 0 ? raw.height : raw.width),
            colors: Int(raw.colors),
            hasColorFilterArray: raw.hasColorFilterArray,
            isXTrans: raw.isXTrans,
            isDNG: raw.isDNG,
            blackLevel: raw.blackLevel,
            whiteLevel: raw.whiteLevel,
            dataMaximum: raw.dataMaximum,
            sensorBits: raw.rawBits > 0 ? Int(raw.rawBits) : nil,
            compression: compression,
            decoderName: decoder,
            make: make,
            model: model,
            normalizedModel: normalized,
            cameraMultipliers: (raw.camMul.0, raw.camMul.1, raw.camMul.2, raw.camMul.3),
            cameraLookHint: lookHint,
            errorMessage: message
        )
    }

    /// Decode a RAW file into extended linear sRGB RGBAf CIImage via LibRaw.
    public static func decodeLinear(
        url: URL,
        halfSize: Bool = false,
        metalBayer: Bool = false,
        multipliers: (Float, Float, Float, Float)? = nil
    ) throws -> LibRawLinearImage {
        try Task.checkCancellation()
        var result = PhosdeckLibRawImage()
        defer { phosdeck_libraw_free_image(&result) }

        url.path.withCString { cPath in
            if let m = multipliers {
                phosdeck_libraw_decode_linear16(cPath, halfSize, metalBayer, true, m.0, m.1, m.2, m.3, &result)
            } else {
                phosdeck_libraw_decode_linear16(cPath, halfSize, metalBayer, false, 1, 1, 1, 1, &result)
            }
        }
        try Task.checkCancellation()

        let message = withUnsafePointer(to: result.errorMessage) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: result.errorMessage)) {
                String(cString: $0)
            }
        }
        if result.errorCode != 0 || result.pixels == nil || result.width <= 0 || result.height <= 0 {
            if result.errorCode == -100008 || result.dataErrorCount > 0 {
                throw LibRawRuntimeError.corruptedBitstream(message.isEmpty ? "RAW bitstream is corrupted" : message)
            }
            if result.errorCode == -2 {
                throw LibRawRuntimeError.unsupported(message.isEmpty ? "Unsupported RAW format" : message)
            }
            throw LibRawRuntimeError.decodeFailed(message.isEmpty ? "LibRaw decoding failed (\(result.errorCode))" : message)
        }

        let width = Int(result.width)
        let height = Int(result.height)
        let count = width * height
        guard let src = result.pixels, result.pixelCount == count * 3 else {
            throw LibRawRuntimeError.decodeFailed("Unexpected LibRaw output dimensions")
        }

        // Convert linear 16-bit RGB into linear extended sRGB RGBAf.
        var data = Data(count: count * 4 * MemoryLayout<Float>.stride)
        let inv: Float = 1.0 / 65535.0
        try data.withUnsafeMutableBytes { bytes in
            let rgba = bytes.bindMemory(to: Float.self)
            for i in 0..<count {
                if i.isMultiple(of: 65536) { try Task.checkCancellation() }
                let s = i * 3, d = i * 4
                rgba[d] = Float(src[s]) * inv
                rgba[d + 1] = Float(src[s + 1]) * inv
                rgba[d + 2] = Float(src[s + 2]) * inv
                rgba[d + 3] = 1
            }
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = CIImage(
            bitmapData: data,
            bytesPerRow: width * 16,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: colorSpace
        )
        return LibRawLinearImage(image: image, width: width, height: height)
    }

    private static func classifyCompression(decoderName: String, isDNG: Bool) -> String {
        let lower = decoderName.lowercased()
        if lower.isEmpty { return "unknown" }
        if lower.contains("crx") { return "canon-crx" }
        if lower.contains("unpacked") { return isDNG ? "dng-uncompressed" : "uncompressed" }
        if lower.contains("fuji_compressed") { return "fuji-lossless-compressed" }
        if lower.contains("sony_arw2") { return "sony-arw2-compressed" }
        if lower.contains("sony_ljpeg") || lower.contains("lossless") { return "lossless-compressed" }
        if lower.contains("nikon_he") { return "nikon-he-compressed" }
        if lower.contains("nikon") { return "nikon-compressed" }
        if lower.contains("panasonic") || lower.contains("pana") { return "panasonic-compressed" }
        if lower.contains("olympus") { return "olympus-compressed" }
        if lower.contains("dng") { return "dng" }
        return decoderName
    }

    private static func resolveCameraLookHint(make: String, fujiFilmMode: UInt16, nikonPictureControl: String) -> LibRawCameraLookHint? {
        let lowerMake = make.lowercased()
        if lowerMake.contains("fuji"), fujiFilmMode != 0 || lowerMake.contains("fujifilm") {
            if let name = fujiFilmSimulationName(fujiFilmMode) {
                return LibRawCameraLookHint(brand: "fujifilm", code: String(format: "0x%04x", fujiFilmMode), name: name)
            }
        }
        if lowerMake.contains("nikon"), !nikonPictureControl.isEmpty {
            return LibRawCameraLookHint(brand: "nikon", code: nikonPictureControl.lowercased(), name: nikonPictureControl)
        }
        return nil
    }

    private static func fujiFilmSimulationName(_ mode: UInt16) -> String? {
        switch mode {
        case 0x0000: return "PROVIA / Standard"
        case 0x0100: return "Studio Portrait"
        case 0x0110: return "Studio Portrait Enhanced Saturation"
        case 0x0120: return "ASTIA"
        case 0x0130: return "Studio Portrait Increased Sharpness"
        case 0x0200: return "Velvia"
        case 0x0300: return "Studio Portrait Ex"
        case 0x0400: return "Velvia"
        case 0x0500: return "PRO Neg. Std"
        case 0x0501: return "PRO Neg. Hi"
        case 0x0600: return "Classic Chrome"
        case 0x0700: return "ETERNA"
        case 0x0800: return "Classic Negative"
        case 0x0900: return "ETERNA Bleach Bypass"
        case 0x0a00: return "Nostalgic Neg."
        case 0x0b00: return "REALA ACE"
        default: return nil
        }
    }
}
