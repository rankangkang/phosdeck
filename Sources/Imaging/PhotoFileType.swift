import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Extensions select a candidate decoder; the file's actual ImageIO type and
/// an evaluated Apple RAW decode decide whether it can enter the catalog.
enum PhotoFileType {
    static let rawTypes = [
        "arw": "com.sony.arw-raw-image", "dng": "com.adobe.raw-image",
        "nef": "com.nikon.raw-image", "cr3": "com.canon.cr3-raw-image",
        "raf": "com.fuji.raw-image"
    ]
    static let editableExtensions = Set(rawTypes.keys).union(["jpg", "jpeg", "tif", "tiff", "png"])
    static func isRAW(_ url: URL) -> Bool { rawTypes[url.pathExtension.lowercased()] != nil }

    static func imageSource(_ url: URL) throws -> CGImageSource {
        try inspectSource(url).source
    }

    /// The actual iCCP chunk distinguishes an embedded profile from ImageIO's
    /// inferred/calibrated profile names (for example an untagged PNG with gAMA).
    static func inspectSource(_ url: URL) throws -> (source: CGImageSource, pngICC: Bool?) {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        let expected = rawTypes[ext] ?? ["jpg": UTType.jpeg.identifier, "jpeg": UTType.jpeg.identifier,
            "tif": UTType.tiff.identifier, "tiff": UTType.tiff.identifier, "png": UTType.png.identifier][ext]
        guard let expected else { throw LRCError(L10n.text("app.thisFileFormatIsNotSupportedYet", defaultValue: "This file format is not supported yet")) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == expected else { throw LRCError(L10n.text("app.fileContentsDifferFromTheExtensionOrTheFormat", defaultValue: "File contents differ from the extension, or the format is unrecognized")) }
        guard CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int, width > 0,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int, height > 0 else {
            throw LRCError(L10n.text("app.theFileIsDamagedIncompleteOrIsNotA", defaultValue: "The file is damaged, incomplete, or is not a single-page image"))
        }
        // LightCraft codecs check_size bounds source pixels BEFORE decode, even
        // for a thumbnail. Reuse our existing geometry budget at the same boundary.
        try PhotoGeometry.checkSize(CGSize(width:width,height:height))
        if ext == "jpg" || ext == "jpeg" {
            guard reachesJPEGEnd(try Data(contentsOf:url,options:.mappedIfSafe)) else { throw LRCError(L10n.text("app.jpegScanDataIsIncompleteImportDevelopmentStopped", defaultValue: "JPEG scan data is incomplete. Import / development stopped")) }
        }
        if ["tif", "tiff"].contains(ext), props[kCGImagePropertyColorModel as String] as? String != "RGB" {
            throw LRCError(L10n.text("app.onlyStandardRGBSinglePageTIFFFilesAreSupported", defaultValue: "Only standard RGB single-page TIFF files are supported"))
        }
        _ = try MergeProvenance.read(props)
        var pngICC: Bool?
        if ext == "png" {
            pngICC = try PNGValidation.validate(url)
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: true] as CFDictionary),
                  image.width == width, image.height == height, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw LRCError(L10n.text("app.pngPixelsCannotBeDecodedCompletely", defaultValue: "PNG pixels cannot be decoded completely"))
            }
        }
        return (source,pngICC)
    }

    /// Port of codecs/src/jpeg.rs::reaches_eoi, LightCraft 4f0b110 (MIT).
    /// Walk segment lengths and scan stuffing/restart markers; an FF D9 inside
    /// EXIF/ICC is not the end of the primary image. Never infer completeness
    /// from ImageIO's recoverable preview or a search for the last two bytes.
    /// Attribution: docs/references/lightcraft-LICENSE.txt.
    static func reachesJPEGEnd(_ data: Data) -> Bool {
        guard data.starts(with:[0xff,0xd8]) else { return false }
        var position = 2
        while position < data.count {
            guard let markerStart = data[position...].firstIndex(of:0xff), markerStart < data.count-1 else { return false }
            let marker = data[markerStart+1]
            switch marker {
            case 0xd9: return true
            case 0xff: position = markerStart+1
            case 0x00,0x01,0xd0...0xd8: position = markerStart+2
            default:
                guard markerStart <= data.count-4 else { return false }
                let length = Int(data[markerStart+2])*256+Int(data[markerStart+3])
                guard length >= 2, length <= data.count-markerStart-2 else { return false }
                position = markerStart+2+length
            }
        }
        return false
    }

    static func rawFilter(_ url: URL) throws -> CIRAWFilter {
        guard isRAW(url) else { throw LRCError(L10n.text("app.theSourceIsNotASupportedRAWCandidate", defaultValue: "The source is not a supported RAW candidate")) }
        let source = try imageSource(url)
        if url.pathExtension.lowercased() == "dng",
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "apple" {
            // The public iPhone 12 Pro fixture exhibits inconsistent colour in
            // repeated renders. Do not expose Apple DNG/ProRAW until validated.
            throw LRCError(L10n.text("app.appleDNGProRAWIsUnavailablePendingRepeatableDevelopmentValidation", defaultValue: "Apple DNG / ProRAW is unavailable pending repeatable development validation"))
        }
        if ["arw", "dng", "nef"].contains(url.pathExtension.lowercased()) { try validateTIFFRanges(url) }
        if url.pathExtension.lowercased() == "raf" { try validateRAFRanges(url) }
        if url.pathExtension.lowercased() == "cr3" { try validateCR3Ranges(url) }
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw LRCError(L10n.text("app.thisMacOSVersionCannotDevelopThisCameraOrRAW", defaultValue: "This macOS version cannot develop this camera or RAW compression mode"))
        }
        return raw
    }

    private static func validateRAFRanges(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 108, data.prefix(16) == Data("FUJIFILMCCD-RAW ".utf8) else { throw LRCError(L10n.text("app.invalidRAFHeader", defaultValue: "Invalid RAF header")) }
        // RAF header: embedded JPEG, metadata and CFA offset/length pairs (big endian).
        for position in [84, 92, 100] {
            func number(_ p: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(data[p + $1]) } }
            let start = number(position), length = number(position + 4)
            guard start <= data.count, length <= data.count - start else { throw LRCError(L10n.text("app.rafDataIsIncompleteDevelopmentStopped", defaultValue: "RAF data is incomplete. Development stopped")) }
        }
    }

    private static func validateCR3Ranges(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var position = 0
        while position < data.count {
            try Task.checkCancellation()
            guard data.count - position >= 8 else { throw LRCError(L10n.text("app.theCR3ContainerIsIncomplete", defaultValue: "The CR3 container is incomplete")) }
            func number(_ p: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { ($0 << 8) | UInt64(data[p + $1]) } }
            var size = number(position, 4), header: UInt64 = 8
            if size == 1 {
                guard data.count - position >= 16 else { throw LRCError(L10n.text("app.theCR3ContainerIsIncomplete", defaultValue: "The CR3 container is incomplete")) }
                size = number(position + 8, 8); header = 16
            } else if size == 0 { size = UInt64(data.count - position) }
            guard size >= header, size <= UInt64(data.count - position) else { throw LRCError(L10n.text("app.cr3DataIsIncompleteDevelopmentStopped", defaultValue: "CR3 data is incomplete. Development stopped")) }
            position += Int(size)
        }
    }

    /// Apple can return pixels for a truncated NEF. Check the TIFF container's
    /// declared data ranges as well as evaluating its decoder; this is not a RAW decoder.
    private static func validateTIFFRanges(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let invalid = LRCError(L10n.text("app.theRAWTIFFDataRangeIsIncompleteOrInvalid", defaultValue: "The RAW TIFF data range is incomplete or invalid. Development stopped"))
        guard data.count >= 8 else { throw invalid }
        let little = data[0] == 0x49 && data[1] == 0x49
        guard little || (data[0] == 0x4d && data[1] == 0x4d) else { throw invalid }
        func number(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - width else { throw invalid }
            var value = 0
            for i in 0..<width { value |= Int(data[offset + i]) << ((little ? i : width - 1 - i) * 8) }
            return value
        }
        guard try number(2, 2) == 42 else { throw LRCError(L10n.text("app.thisRAWTIFFContainerVersionHasNotBeenValidated", defaultValue: "This RAW TIFF container version has not been validated")) }
        var pending = [try number(4, 4)], visited = Set<Int>()
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
        let wanted: Set<Int> = [273, 279, 324, 325, 513, 514, 330, 34665, 34853]
        while let offset = pending.popLast() {
            try Task.checkCancellation()
            if offset == 0 { continue }
            guard visited.insert(offset).inserted, visited.count <= 128 else { throw invalid }
            let count = try number(offset, 2)
            guard offset <= data.count - 6, count <= (data.count - offset - 6) / 12 else { throw invalid }
            var fields: [Int: [Int]] = [:]
            for i in 0..<count {
                let entry = offset + 2 + i * 12
                let tag = try number(entry, 2), type = try number(entry + 2, 2), n = try number(entry + 4, 4)
                guard let size = sizes[type], n <= data.count / size else { throw invalid }
                let length = n * size, location = try length <= 4 ? entry + 8 : number(entry + 8, 4)
                guard location <= data.count, length <= data.count - location else { throw invalid }
                if wanted.contains(tag) {
                    guard [3, 4, 13].contains(type), n <= 1_000_000 else { throw invalid }
                    fields[tag] = try (0..<n).map { try number(location + $0 * size, size) }
                }
            }
            for (offsetTag, countTag) in [(273, 279), (324, 325), (513, 514)] {
                if let offsets = fields[offsetTag] {
                    guard let counts = fields[countTag], counts.count == offsets.count else { throw invalid }
                    for (start, length) in zip(offsets, counts) {
                        guard start <= data.count, length <= data.count - start else { throw invalid }
                    }
                }
            }
            for tag in [330, 34665, 34853] { pending += fields[tag] ?? [] }
            pending.append(try number(offset + 2 + count * 12, 4))
        }
    }

    private static let validationContext = CIContext(options: [.cacheIntermediates: false])
    static func validateRAWDecode(_ raw: CIRAWFilter) throws {
        try Task.checkCancellation()
        try PhotoGeometry.checkSize(raw.nativeSize)
        // Evaluate RAW pixels, never accept only metadata or the embedded JPEG.
        raw.scaleFactor = Float(min(1, 256 / max(raw.nativeSize.width, raw.nativeSize.height)))
        raw.isDraftModeEnabled = false
        guard let image = raw.outputImage, !image.extent.isEmpty, !image.extent.isInfinite,
              image.extent.width.isFinite, image.extent.height.isFinite,
              image.extent.width <= 1024, image.extent.height <= 1024 else { throw LRCError(L10n.text("app.rawDecodingFailedOrDimensionsAreInvalid", defaultValue: "RAW decoding failed or dimensions are invalid")) }
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        var data = Data(count: width * height * 4)
        do {
            try data.withUnsafeMutableBytes { bytes in
                let destination = CIRenderDestination(bitmapData: bytes.baseAddress!, width: width, height: height,
                    bytesPerRow: width * 4, format: .RGBA8)
                destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                let task = try validationContext.startTask(toRender: image, from: bounds, to: destination, at: .zero)
                _ = try task.waitUntilCompleted()
            }
        } catch { throw LRCError(L10n.text("app.cannotDecodeRAWPixelsTheFileMayBeDamaged", defaultValue: "Cannot decode RAW pixels. The file may be damaged or this system may not support its mode: \(error.localizedDescription)")) }
        try Task.checkCancellation()
    }
}
