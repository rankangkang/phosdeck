import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum PhotoContainer: Equatable {
    case jpeg
    case png
    case tiff
    case heif
    case rawTIFF(magics: Set<Int>, extraOffsetTags: Set<Int> = [])
    case rawRAF
    case rawISOBMFF
}

struct PhotoFormatDescriptor: Equatable {
    let fileExtension: String
    let primaryUTI: String
    let acceptedUTIs: Set<String>
    let isRAW: Bool
    let container: PhotoContainer

    init(fileExtension: String, utis: [String], isRAW: Bool, container: PhotoContainer) {
        self.fileExtension = fileExtension
        self.primaryUTI = utis[0]
        self.acceptedUTIs = Set(utis)
        self.isRAW = isRAW
        self.container = container
    }
}

/// Declarative format registry and container integrity gate. Extensions select
/// a candidate format; ImageIO's detected UTI, container range checks, and an
/// actual pixel/RAW decode decide whether a file can enter the catalog.
enum PhotoFileType {
    static let descriptors: [PhotoFormatDescriptor] = [
        // Sensor RAW formats (validated per container family and per file via RAW decode).
        PhotoFormatDescriptor(fileExtension: "arw", utis: ["com.sony.arw-raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "sr2", utis: ["com.sony.sr2-raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "dng", utis: ["com.adobe.raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "nef", utis: ["com.nikon.raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "nrw", utis: ["com.nikon.nrw-raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "cr2", utis: ["com.canon.cr2-raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "cr3", utis: ["com.canon.cr3-raw-image"], isRAW: true, container: .rawISOBMFF),
        PhotoFormatDescriptor(fileExtension: "raf", utis: ["com.fuji.raw-image"], isRAW: true, container: .rawRAF),
        PhotoFormatDescriptor(fileExtension: "orf", utis: ["com.olympus.raw-image", "com.olympus.or-raw-image"], isRAW: true, container: .rawTIFF(magics: [0x4F52, 0x5352, 42])),
        PhotoFormatDescriptor(fileExtension: "rw2", utis: ["com.panasonic.rw2-raw-image", "com.panasonic.raw-image"], isRAW: true, container: .rawTIFF(magics: [0x0055], extraOffsetTags: [0x0118])),
        PhotoFormatDescriptor(fileExtension: "rwl", utis: ["com.leica.rwl-raw-image", "com.leica.raw-image"], isRAW: true, container: .rawTIFF(magics: [0x0055, 42], extraOffsetTags: [0x0118])),
        PhotoFormatDescriptor(fileExtension: "pef", utis: ["com.pentax.raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "3fr", utis: ["com.hasselblad.3fr-raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "fff", utis: ["com.hasselblad.fff-raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        PhotoFormatDescriptor(fileExtension: "srw", utis: ["com.samsung.raw-image"], isRAW: true, container: .rawTIFF(magics: [42])),
        // Raster formats.
        PhotoFormatDescriptor(fileExtension: "jpg", utis: [UTType.jpeg.identifier], isRAW: false, container: .jpeg),
        PhotoFormatDescriptor(fileExtension: "jpeg", utis: [UTType.jpeg.identifier], isRAW: false, container: .jpeg),
        PhotoFormatDescriptor(fileExtension: "tif", utis: [UTType.tiff.identifier], isRAW: false, container: .tiff),
        PhotoFormatDescriptor(fileExtension: "tiff", utis: [UTType.tiff.identifier], isRAW: false, container: .tiff),
        PhotoFormatDescriptor(fileExtension: "png", utis: [UTType.png.identifier], isRAW: false, container: .png),
        PhotoFormatDescriptor(fileExtension: "heic", utis: [UTType.heic.identifier, UTType.heif.identifier], isRAW: false, container: .heif),
        PhotoFormatDescriptor(fileExtension: "heif", utis: [UTType.heif.identifier, UTType.heic.identifier], isRAW: false, container: .heif),
        PhotoFormatDescriptor(fileExtension: "hif", utis: [UTType.heic.identifier, UTType.heif.identifier], isRAW: false, container: .heif)
    ]

    private static let byExtension: [String: PhotoFormatDescriptor] = Dictionary(
        uniqueKeysWithValues: descriptors.map { ($0.fileExtension, $0) }
    )

    static let rawTypes: [String: String] = Dictionary(
        uniqueKeysWithValues: descriptors.filter(\.isRAW).map { ($0.fileExtension, $0.primaryUTI) }
    )
    static let tiffExtensions: Set<String> = ["tif", "tiff"]
    static let heifExtensions: Set<String> = ["heic", "heif", "hif"]
    static let supportedRasterUTIs: Set<String> = Set(descriptors.filter { !$0.isRAW }.flatMap(\.acceptedUTIs))
    static let editableExtensions: Set<String> = Set(byExtension.keys)

    static func descriptor(for url: URL) -> PhotoFormatDescriptor? {
        byExtension[url.pathExtension.lowercased()]
    }

    static func isRAW(_ url: URL) -> Bool {
        descriptor(for: url)?.isRAW == true
    }

    static func isHEIF(_ url: URL) -> Bool {
        descriptor(for: url)?.container == .heif
    }

    static func isSupportedRasterUTI(_ identifier: String) -> Bool {
        supportedRasterUTIs.contains(identifier)
    }

    /// Formats that may carry transparency, non-sRGB profiles, or non-zero primary
    /// indices render thumbnails through the image pipeline rather than fast JPEG shortcuts.
    static func usesPipelineThumbnail(_ url: URL) -> Bool {
        guard let format = descriptor(for: url) else { return false }
        return format.container == .png || format.container == .heif
    }

    static var multipageTIFFPreviewOnly: String {
        L10n.text("app.multipageTIFFPreviewOnly", defaultValue: "Multi-page TIFF supports first-page preview only.")
    }

    static func imageSource(_ url: URL) throws -> CGImageSource {
        try inspectSource(url).source
    }

    /// The actual iCCP chunk distinguishes an embedded profile from ImageIO's
    /// inferred/calibrated profile names (for example an untagged PNG with gAMA).
    static func inspectSource(_ url: URL) throws -> (source: CGImageSource, primaryIndex: Int, pngICC: Bool?, composite: MergeProvenance?, properties: [String: Any], tiffPageCount: Int?) {
        try Task.checkCancellation()
        let ext = url.pathExtension.lowercased()
        guard let format = byExtension[ext] else {
            throw LRCError(L10n.text("app.thisFileFormatIsNotSupportedYet", defaultValue: "This file format is not supported yet"))
        }
        let nativeDNG = ext == "dng" ? try MergeDNGCodec.open(url) : nil
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              nativeDNG != nil || (CGImageSourceGetType(source) as String?).map({ format.acceptedUTIs.contains($0) }) == true else {
            throw LRCError(L10n.text("app.fileContentsDifferFromTheExtensionOrTheFormat", defaultValue: "File contents differ from the extension, or the format is unrecognized"))
        }
        if let nativeDNG {
            // ImageIO can expose incomplete metadata for float LinearRaw masters.
            // Read our format directly, independently of the camera RAW decoder.
            return (source, 0, nil, nativeDNG.provenance, [kCGImagePropertyPixelWidth as String: nativeDNG.width,
                kCGImagePropertyPixelHeight as String: nativeDNG.height, kCGImagePropertyOrientation as String: 1,
                kCGImagePropertyDepth as String: 32, kCGImagePropertyIsFloat as String: true,
                kCGImagePropertyHasAlpha as String: true, kCGImagePropertyColorModel as String: "RGB",
                kCGImagePropertyProfileName as String: "sRGB IEC61966-2.1 Linear"], nil)
        }
        let count = CGImageSourceGetCount(source), isTIFF = format.container == .tiff
        let tiffPageCount = isTIFF && count > 1 ? count : nil
        let rawPrimary = format.container == .heif ? CGImageSourceGetPrimaryImageIndex(source) : 0
        let primaryIndex = rawPrimary < count ? rawPrimary : 0
        guard (count == 1 || tiffPageCount != nil), CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, primaryIndex) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int, width > 0,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int, height > 0 else {
            throw LRCError(L10n.text("app.theFileIsDamagedIncompleteOrHasUnsupportedPages", defaultValue: "The file is damaged, incomplete, or has unsupported pages"))
        }
        // LightCraft codecs check_size bounds source pixels BEFORE decode, even
        // for a thumbnail. Reuse our existing geometry budget at the same boundary.
        try PhotoGeometry.checkSize(CGSize(width: width, height: height))
        if format.container == .jpeg {
            guard reachesJPEGEnd(try Data(contentsOf: url, options: .mappedIfSafe)) else {
                throw LRCError(L10n.text("app.jpegScanDataIsIncompleteImportDevelopmentStopped", defaultValue: "JPEG scan data is incomplete. Import / development stopped"))
            }
        }
        if isTIFF, props[kCGImagePropertyColorModel as String] as? String != "RGB" {
            throw LRCError(L10n.text("app.onlyStandardRGBTIFFFilesAreSupported", defaultValue: "Only standard RGB TIFF files are supported"))
        }
        let composite = try MergeProvenance.read(props)
        guard tiffPageCount == nil || composite == nil else { throw MergeMasterCodec.invalid }
        var pngICC: Bool?
        if format.container == .png {
            pngICC = try PNGValidation.validate(url)
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: true] as CFDictionary),
                  image.width == width, image.height == height, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw LRCError(L10n.text("app.pngPixelsCannotBeDecodedCompletely", defaultValue: "PNG pixels cannot be decoded completely"))
            }
        }
        if format.container == .heif {
            try validateHEIF(url, source: source, primaryIndex: primaryIndex, width: width, height: height, properties: props)
        }
        return (source, primaryIndex, pngICC, composite, props, tiffPageCount)
    }

    private static func validateHEIF(_ url: URL, source: CGImageSource, primaryIndex: Int,
                                     width: Int, height: Int, properties: [String: Any]) throws {
        try validateISOBMFFRanges(url, requireMeta: true, forbidMovie: true)
        if let model = properties[kCGImagePropertyColorModel as String] as? String,
           model != "RGB", model != "Gray" {
            throw LRCError(L10n.text("app.heifColorModelUnsupported", defaultValue: "Only standard RGB or grayscale SDR HEIC/HEIF files are supported"))
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, primaryIndex, [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary),
              image.width == width, image.height == height,
              CGImageSourceGetStatusAtIndex(source, primaryIndex) == .statusComplete else {
            throw LRCError(L10n.text("app.heifPixelsCannotBeDecodedCompletely", defaultValue: "HEIC/HEIF pixels cannot be decoded completely"))
        }
        if let space = image.colorSpace, CGColorSpaceUsesITUR_2100TF(space) {
            throw LRCError(L10n.text("app.heifHDRTransferNotSupported", defaultValue: "HDR PQ / HLG HEIC/HEIF files are not supported yet. Standard SDR HEIC/HEIF is supported"))
        }
    }

    /// Port of codecs/src/jpeg.rs::reaches_eoi, LightCraft 4f0b110 (MIT).
    /// Walk segment lengths and scan stuffing/restart markers; an FF D9 inside
    /// EXIF/ICC is not the end of the primary image. Never infer completeness
    /// from ImageIO's recoverable preview or a search for the last two bytes.
    /// Attribution: docs/references/lightcraft-LICENSE.txt.
    static func reachesJPEGEnd(_ data: Data) -> Bool {
        guard data.starts(with: [0xff, 0xd8]) else { return false }
        var position = 2
        while position < data.count {
            guard let markerStart = data[position...].firstIndex(of: 0xff), markerStart < data.count - 1 else { return false }
            let marker = data[markerStart + 1]
            switch marker {
            case 0xd9: return true
            case 0xff: position = markerStart + 1
            case 0x00, 0x01, 0xd0...0xd8: position = markerStart + 2
            default:
                guard markerStart <= data.count - 4 else { return false }
                let length = Int(data[markerStart + 2]) * 256 + Int(data[markerStart + 3])
                guard length >= 2, length <= data.count - markerStart - 2 else { return false }
                position = markerStart + 2 + length
            }
        }
        return false
    }

    static func rawFilter(_ url: URL) throws -> CIRAWFilter {
        try openAppleRAWFilter(url)
    }

    static func openAppleRAWFilter(_ url: URL) throws -> CIRAWFilter {
        guard let format = descriptor(for: url), format.isRAW else {
            throw LRCError(L10n.text("app.theSourceIsNotASupportedRAWCandidate", defaultValue: "The source is not a supported RAW candidate"))
        }
        if format.fileExtension == "dng", try MergeDNGCodec.open(url) != nil { throw MergeMasterCodec.invalid }
        let source = try imageSource(url)
        if format.fileExtension == "dng",
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "apple" {
            // The public iPhone 12 Pro fixture exhibits inconsistent colour in
            // repeated renders. Do not expose Apple DNG/ProRAW until validated.
            throw LRCError(L10n.text("app.appleDNGProRAWIsUnavailablePendingRepeatableDevelopmentValidation", defaultValue: "Apple DNG / ProRAW is unavailable pending repeatable development validation"))
        }
        switch format.container {
        case .rawTIFF(let magics, let extraOffsetTags):
            try validateTIFFRanges(url, acceptedMagics: magics, extraOffsetTags: extraOffsetTags)
        case .rawRAF:
            try validateRAFRanges(url)
        case .rawISOBMFF:
            try validateISOBMFFRanges(url, requireMeta: false, forbidMovie: false)
        case .jpeg, .png, .tiff, .heif:
            break
        }
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw LRCError(L10n.text("app.thisMacOSVersionCannotDevelopThisCameraOrRAW", defaultValue: "This macOS version cannot develop this camera or RAW compression mode"))
        }
        return raw
    }

    /// RAF stores the camera JPEG's big-endian offset and length at bytes 84–91.
    /// Read only that range. Missing or unsuitable previews use the native renderer.
    static func cameraJPEG(_ url: URL, edge: Int) throws -> CGImage? {
        guard edge > 0, url.pathExtension.lowercased() == "raf" else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        guard let header = try file.read(upToCount: 92), header.count == 92,
              header.prefix(16) == Data("FUJIFILMCCD-RAW ".utf8) else { return nil }
        func uint32(_ index: Int) -> UInt64 {
            header[index..<(index + 4)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let offset = uint32(84), length = uint32(88)
        guard offset >= 92, offset <= size, length >= 4, length <= size - offset,
              length <= 32 * 1024 * 1024 else { return nil }
        try file.seek(toOffset: offset)
        guard let jpeg = try file.read(upToCount: Int(length)), jpeg.count == Int(length),
              jpeg.starts(with: [0xff, 0xd8]),
              let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        try PhotoGeometry.checkSize(CGSize(width: width, height: height))
        try Task.checkCancellation()
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func validateRAFRanges(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 108, data.prefix(16) == Data("FUJIFILMCCD-RAW ".utf8) else {
            throw LRCError(L10n.text("app.invalidRAFHeader", defaultValue: "Invalid RAF header"))
        }
        // RAF header: embedded JPEG, metadata and CFA offset/length pairs (big endian).
        for position in [84, 92, 100] {
            func number(_ p: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(data[p + $1]) } }
            let start = number(position), length = number(position + 4)
            guard start <= data.count, length <= data.count - start else {
                throw LRCError(L10n.text("app.rafDataIsIncompleteDevelopmentStopped", defaultValue: "RAF data is incomplete. Development stopped"))
            }
        }
    }

    static func validateISOBMFFRanges(_ url: URL, requireMeta: Bool, forbidMovie: Bool) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try validateISOBMFFRanges(data, requireMeta: requireMeta, forbidMovie: forbidMovie)
    }

    static func validateISOBMFFRanges(_ data: Data, requireMeta: Bool, forbidMovie: Bool) throws {
        let invalid = LRCError(L10n.text("app.theISOBMFFContainerIsIncompleteOrUnsupported", defaultValue: "The ISOBMFF container is incomplete or unsupported. Development stopped"))
        guard data.count >= 8 else { throw invalid }
        var position = 0
        var boxCount = 0
        var sawMeta = false
        while position < data.count {
            try Task.checkCancellation()
            guard data.count - position >= 8 else { throw invalid }
            func number(_ p: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { ($0 << 8) | UInt64(data[p + $1]) } }
            var size = number(position, 4), header: UInt64 = 8
            let boxType = String(decoding: data[(position + 4)..<(position + 8)], as: UTF8.self)
            if boxCount == 0 {
                guard boxType == "ftyp" else { throw invalid }
            }
            if boxType == "meta" { sawMeta = true }
            if forbidMovie, boxType == "moov" {
                throw LRCError(L10n.text("app.animatedOrSequenceHEIFIsNotSupported", defaultValue: "Animated or sequence HEIC/HEIF files are not supported"))
            }
            if size == 1 {
                guard data.count - position >= 16 else { throw invalid }
                size = number(position + 8, 8); header = 16
            } else if size == 0 {
                // Open-ended box is only valid after ftyp as the final top-level box.
                guard boxCount > 0 else { throw invalid }
                size = UInt64(data.count - position)
            }
            guard size >= header, size <= UInt64(data.count - position) else { throw invalid }
            if boxCount == 0 {
                guard size >= header + 8 else { throw invalid }
                if forbidMovie {
                    let major = String(decoding: data[(position + Int(header))..<(position + Int(header) + 4)], as: UTF8.self)
                    if ["msf1", "hevc", "hevx", "avis"].contains(major) {
                        throw LRCError(L10n.text("app.animatedOrSequenceHEIFIsNotSupported", defaultValue: "Animated or sequence HEIC/HEIF files are not supported"))
                    }
                }
            }
            position += Int(size)
            boxCount += 1
        }
        guard boxCount > 0, !requireMeta || sawMeta else { throw invalid }
    }

    static func validateTIFFRanges(_ url: URL, acceptedMagics: Set<Int> = [42], extraOffsetTags: Set<Int> = []) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try validateTIFFRanges(data, acceptedMagics: acceptedMagics, extraOffsetTags: extraOffsetTags)
    }

    /// Apple can return pixels for a truncated RAW TIFF container. Walk IFDs
    /// and declared strip/tile/JPEG/raw offset ranges before invoking the decoder.
    static func validateTIFFRanges(_ data: Data, acceptedMagics: Set<Int> = [42], extraOffsetTags: Set<Int> = []) throws {
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
        guard acceptedMagics.contains(try number(2, 2)) else {
            throw LRCError(L10n.text("app.thisRAWTIFFContainerVersionHasNotBeenValidated", defaultValue: "This RAW TIFF container version has not been validated"))
        }
        var pending = [try number(4, 4)], visited = Set<Int>()
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
        let standardWanted: Set<Int> = [273, 279, 324, 325, 513, 514, 330, 34665, 34853]
        while let offset = pending.popLast() {
            try Task.checkCancellation()
            if offset == 0 { continue }
            guard visited.insert(offset).inserted, visited.count <= 128 else { throw invalid }
            let count = try number(offset, 2)
            guard offset <= data.count - 6, count <= (data.count - offset - 6) / 12 else { throw invalid }
            var fields: [Int: [Int]] = [:]
            var extraOffsets: [Int] = []
            for i in 0..<count {
                let entry = offset + 2 + i * 12
                let tag = try number(entry, 2), type = try number(entry + 2, 2), n = try number(entry + 4, 4)
                guard let size = sizes[type], n <= data.count / size else { throw invalid }
                let length = n * size, location = try length <= 4 ? entry + 8 : number(entry + 8, 4)
                guard location <= data.count, length <= data.count - location else { throw invalid }
                if standardWanted.contains(tag) {
                    guard [3, 4, 13].contains(type), n <= 1_000_000 else { throw invalid }
                    fields[tag] = try (0..<n).map { try number(location + $0 * size, size) }
                } else if extraOffsetTags.contains(tag), [3, 4].contains(type), n <= 1_000_000 {
                    extraOffsets += try (0..<n).map { try number(location + $0 * size, size) }
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
            for start in extraOffsets {
                guard start >= 0, start < data.count else { throw invalid }
            }
            for tag in [330, 34665, 34853] { pending += fields[tag] ?? [] }
            pending.append(try number(offset + 2 + count * 12, 4))
        }
    }

    static func releaseValidationCaches() { RAWDecoderSession.releaseValidationCaches() }

    static func validateRAWDecode(_ raw: CIRAWFilter) throws {
        try RAWDecoderSession.validateDecode(raw)
    }
}
