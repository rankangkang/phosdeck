import Foundation
import ImageIO

enum ExportMetadataPolicy: String, Codable, CaseIterable, Identifiable {
    case none, capture, description, captureAndDescription
    var id: String { rawValue }
    var includesCapture: Bool { self == .capture || self == .captureAndDescription }
    var includesDescription: Bool { self == .description || self == .captureAndDescription }
    var title: String {
        switch self {
        case .none: L10n.text("app.noSourceMetadataDefault", defaultValue: "No Source Metadata (Default)")
        case .capture: L10n.text("app.keepSupportedCaptureMetadata", defaultValue: "Keep Supported Capture Metadata")
        case .description: L10n.text("app.keywordsAndCaption", defaultValue: "Keywords and Caption")
        case .captureAndDescription: L10n.text("app.captureMetadataKeywordsAndCaption", defaultValue: "Capture Metadata, Keywords, and Caption")
        }
    }
}

/// Typed allowlist only. No source dictionaries, paths, serials, input XMP or recipes.
struct ExportMetadata: Codable, Equatable {
    var cameraMake: String?
    var cameraModel: String?
    var lensMake: String?
    var lensModel: String?
    var capturedAt: String?
    var iso: Int?
    var aperture: Double?
    var exposureTime: Double?
    var focalLength: Double?
    var omitted: [String] = []
    var descriptive = ExportDescription()

    static func capture(from properties: [String: Any]) -> Self {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var result = Self()
        result.cameraMake = text(tiff[kCGImagePropertyTIFFMake as String])
        result.cameraModel = text(tiff[kCGImagePropertyTIFFModel as String])
        result.lensMake = text(exif[kCGImagePropertyExifLensMake as String])
        result.lensModel = text(exif[kCGImagePropertyExifLensModel as String])
        result.capturedAt = date(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String)
        if let value = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first,
           value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue, (1...2_000_000_000).contains(value.doubleValue) { result.iso = value.intValue }
        result.aperture = number(exif[kCGImagePropertyExifFNumber as String])
        result.exposureTime = number(exif[kCGImagePropertyExifExposureTime as String])
        result.focalLength = number(exif[kCGImagePropertyExifFocalLength as String])
        result.omitted = [(L10n.text("app.camera", defaultValue: "Camera"), result.cameraMake != nil || result.cameraModel != nil), (L10n.text("app.lens", defaultValue: "Lens"), result.lensMake != nil || result.lensModel != nil),
                          (L10n.text("app.captureTime", defaultValue: "Capture Time"), result.capturedAt != nil), ("ISO", result.iso != nil), (L10n.text("app.aperture", defaultValue: "Aperture"), result.aperture != nil),
                          (L10n.text("app.shutter", defaultValue: "Shutter"), result.exposureTime != nil), (L10n.text("app.focalLength", defaultValue: "Focal Length"), result.focalLength != nil)].compactMap { $0.1 ? nil : $0.0 }
        return result
    }
    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }
    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, value.doubleValue.isFinite, value.doubleValue > 0, value.doubleValue <= 1_000_000 else { return nil }
        return value.doubleValue
    }
    private static func date(_ value: String?) -> String? {
        guard let value, value.utf8.count == 19, value.unicodeScalars.allSatisfy({ $0.isASCII }),
              let day = LibraryMetadataFilter.day(value), value.prefix(10) == day.replacingOccurrences(of: "-", with: ":"),
              value[value.index(value.startIndex, offsetBy: 10)] == " " else { return nil }
        let time = value.suffix(8).split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 3, time.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let h = Int(time[0]), let m = Int(time[1]), let s = Int(time[2]), h < 24, m < 60, s < 60 else { return nil }
        return value
    }
    func validate(policy: ExportMetadataPolicy) throws {
        var captureOnly = self; captureOnly.descriptive = ExportDescription()
        guard policy.includesCapture || captureOnly == Self() else { throw LRCError(L10n.text("app.theCurrentPolicyDoesNotAllowSourceCaptureFields", defaultValue: "The current policy does not allow source capture fields")) }
        guard policy.includesDescription || descriptive == ExportDescription() else { throw LRCError(L10n.text("app.theCurrentPolicyDoesNotAllowKeywordsOrCaptions", defaultValue: "The current policy does not allow keywords or captions")) }
        try descriptive.validate()
        if policy.includesCapture {
            let missing = [(L10n.text("app.camera", defaultValue: "Camera"), cameraMake != nil || cameraModel != nil), (L10n.text("app.lens", defaultValue: "Lens"), lensMake != nil || lensModel != nil),
                           (L10n.text("app.captureTime", defaultValue: "Capture Time"), capturedAt != nil), ("ISO", iso != nil), (L10n.text("app.aperture", defaultValue: "Aperture"), aperture != nil), (L10n.text("app.shutter", defaultValue: "Shutter"), exposureTime != nil),
                           (L10n.text("app.focalLength", defaultValue: "Focal Length"), focalLength != nil)].compactMap { $0.1 ? nil : $0.0 }
            guard Set(missing) == Set(omitted), omitted.count == Set(omitted).count else { throw LRCError(L10n.text("app.captureMetadataWasNotCompletelyFrozenCurrentSourceValues", defaultValue: "Capture metadata was not completely frozen. Current source values will not be substituted")) }
        }
        for value in [cameraMake, cameraModel, lensMake, lensModel].compactMap({ $0 }) where Self.text(value) == nil { throw LRCError(L10n.text("app.invalidFrozenCaptureText", defaultValue: "Invalid frozen capture text")) }
        if let capturedAt, Self.date(capturedAt) == nil { throw LRCError(L10n.text("app.invalidFrozenCaptureDate", defaultValue: "Invalid frozen capture date")) }
        if let iso, !(1...2_000_000_000).contains(iso) { throw LRCError(L10n.text("app.invalidFrozenISO", defaultValue: "Invalid frozen ISO")) }
        for value in [aperture, exposureTime, focalLength].compactMap({ $0 }) where Self.number(NSNumber(value: value)) == nil { throw LRCError(L10n.text("app.invalidFrozenCaptureValue", defaultValue: "Invalid frozen capture value")) }
    }
    var summary: String {
        let fields = [(L10n.text("app.camera", defaultValue: "Camera"), cameraMake != nil || cameraModel != nil), (L10n.text("app.lens", defaultValue: "Lens"), lensMake != nil || lensModel != nil), (L10n.text("app.time", defaultValue: "Time"), capturedAt != nil),
                      ("ISO", iso != nil), (L10n.text("app.aperture", defaultValue: "Aperture"), aperture != nil), (L10n.text("app.shutter", defaultValue: "Shutter"), exposureTime != nil), (L10n.text("app.focalLength", defaultValue: "Focal Length"), focalLength != nil)].compactMap { $0.1 ? $0.0 : nil }
        return L10n.text("app.frozen", defaultValue: "Frozen: ") + (fields.isEmpty ? L10n.text("app.noValidCaptureFields", defaultValue: "No valid capture fields") : fields.joined(separator: "、")) + (omitted.isEmpty ? "" : L10n.text("app.missingOrInvalidSourceFieldsOmitted", defaultValue: "; missing or invalid source fields omitted: ") + omitted.joined(separator: "、")) +
            (descriptive.isEmpty ? "" : L10n.text("app.organizationKeywordsCaption", defaultValue: "; organization: \(descriptive.keywords.count) keywords, caption \(descriptive.caption.isEmpty ? L10n.text("app.none", defaultValue: "None") : L10n.text("app.present", defaultValue: "Present"))"))
    }
    var tiff: [String: Any] {
        var result = [String: Any]()
        result[kCGImagePropertyTIFFMake as String] = cameraMake
        result[kCGImagePropertyTIFFModel as String] = cameraModel
        return result
    }
    var exif: [String: Any] {
        var result = [String: Any]()
        result[kCGImagePropertyExifLensMake as String] = lensMake
        result[kCGImagePropertyExifLensModel as String] = lensModel
        result[kCGImagePropertyExifDateTimeOriginal as String] = capturedAt
        result[kCGImagePropertyExifISOSpeedRatings as String] = iso.map { [$0] }
        result[kCGImagePropertyExifFNumber as String] = aperture
        result[kCGImagePropertyExifExposureTime as String] = exposureTime
        result[kCGImagePropertyExifFocalLength as String] = focalLength
        return result
    }
    /// Read-back verification is also the format capability check: a silently
    /// dropped/changed requested field fails before publication.
    static func verify(_ properties: [String: Any], width: Int, height: Int, expected: Self?) throws {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let allowedExif: Set<String> = [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifDateTimeOriginal,
            kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureTime, kCGImagePropertyExifFocalLength,
            kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension, kCGImagePropertyExifColorSpace].map { $0 as String }.reduce(into: []) { $0.insert($1) }
        var allowedTIFF = Set([kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFOrientation,
            kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation, kCGImagePropertyTIFFResolutionUnit,
            kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution].map { $0 as String })
        let description = expected?.descriptive ?? ExportDescription()
        if !description.caption.isEmpty { allowedTIFF.insert(kCGImagePropertyTIFFImageDescription as String) }
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
        var allowedIPTC = Set([kCGImagePropertyIPTCKeywords as String, kCGImagePropertyIPTCCaptionAbstract as String])
        // ImageIO mirrors selected EXIF capture time into IPTC when writing XMP.
        if let date = expected?.capturedAt {
            allowedIPTC.formUnion([kCGImagePropertyIPTCDateCreated as String, kCGImagePropertyIPTCTimeCreated as String])
            for (key, wanted) in [(kCGImagePropertyIPTCDateCreated, String(date.prefix(10)).replacingOccurrences(of: ":", with: "")),
                                  (kCGImagePropertyIPTCTimeCreated, String(date.suffix(8)).replacingOccurrences(of: ":", with: ""))] {
                if let actual = iptc[key as String] { guard (actual as? String) == wanted else { throw LRCError(L10n.text("app.outputCaptureDateDiffersOnReadback", defaultValue: "Output capture date differs on readback")) } }
            }
        }
        guard Set(iptc.keys).isSubset(of: allowedIPTC),
              (iptc[kCGImagePropertyIPTCKeywords as String] as? [String] ?? []) == description.keywords,
              (iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String ?? "") == description.caption else {
            throw LRCError(L10n.text("app.outputKeywordsOrCaptionDifferOnReadbackPublicationStopped", defaultValue: "Output keywords or caption differ on readback. Publication stopped"))
        }
        let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
        for actual in [tiff[kCGImagePropertyTIFFImageDescription as String], png[kCGImagePropertyPNGDescription as String]].compactMap({ $0 }) {
            guard (actual as? String) == description.caption, !description.caption.isEmpty else { throw LRCError(L10n.text("app.outputDescriptionContainsUnselectedContentPublicationStopped", defaultValue: "Output description contains unselected content. Publication stopped")) }
        }
        guard Set(exif.keys).isSubset(of: allowedExif),
              Set(tiff.keys).isSubset(of: allowedTIFF),
              !properties.keys.contains(where: { $0 == kCGImagePropertyGPSDictionary as String || $0 == kCGImagePropertyExifAuxDictionary as String || $0.hasPrefix("{Maker") || $0.lowercased().contains("xmp") }),
              tiff[kCGImagePropertyTIFFArtist as String] == nil,
              tiff[kCGImagePropertyTIFFCopyright as String] == nil
        else { throw LRCError(L10n.text("app.outputMetadataContainsFieldsOutsideTheAllowlistPublicationStopped", defaultValue: "Output metadata contains fields outside the allowlist. Publication stopped")) }
        for (key, value) in [(kCGImagePropertyExifPixelXDimension, width), (kCGImagePropertyExifPixelYDimension, height), (kCGImagePropertyExifColorSpace, 1)] {
            if let actual = exif[key as String], (actual as? Int) != value { throw LRCError(L10n.text("app.outputEXIFDimensionsOrColorSpaceDoNotMatch", defaultValue: "Output EXIF dimensions or color space do not match the rendered output")) }
        }
        if let actual = tiff[kCGImagePropertyTIFFOrientation as String], (actual as? Int) != 1 { throw LRCError(L10n.text("app.outputTIFFOrientationDoesNotMatchTheRenderedOutput", defaultValue: "Output TIFF orientation does not match the rendered output")) }
        guard let expected else { return }
        if !expected.omitted.isEmpty || !expected.tiff.isEmpty || !expected.exif.isEmpty {
            guard exif[kCGImagePropertyExifPixelXDimension as String] as? Int == width,
                  exif[kCGImagePropertyExifPixelYDimension as String] as? Int == height,
                  (exif[kCGImagePropertyExifColorSpace as String] as? Int == 1 || (!description.isEmpty && exif[kCGImagePropertyExifColorSpace as String] == nil)) else { throw LRCError(L10n.text("app.thisFormatCannotVerifyOutputEXIFDimensionsColorSpace", defaultValue: "This format cannot verify output EXIF dimensions / color space. Publication stopped")) }
        }
        for (actual, wanted, keys) in [(tiff, expected.tiff, [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel]),
                                      (exif, expected.exif, [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureTime, kCGImagePropertyExifFocalLength])] {
            for key in keys {
                let key = key as String
                if let number = wanted[key] as? Double {
                    guard let read = actual[key] as? Double, read.isFinite, read > 0,
                          abs(read - number) <= max(0.000001, abs(number) * 0.00001) else { throw LRCError(L10n.text("app.thisFormatDoesNotSupportWritingVerifyingPublicationStopped", defaultValue: "This format does not support writing / verifying \(key). Publication stopped")) }
                } else if let value = wanted[key] {
                    guard let read = actual[key], (read as? NSObject)?.isEqual(value) == true else { throw LRCError(L10n.text("app.thisFormatDoesNotSupportWritingVerifyingPublicationStopped", defaultValue: "This format does not support writing / verifying \(key). Publication stopped")) }
                } else if actual[key] != nil { throw LRCError(L10n.text("app.outputContainsAnUnselectedField", defaultValue: "Output contains an unselected \(key) field")) }
            }
        }
    }
}


/// Only catalog-authored fields. Never copy an input packet or preserve foreign namespaces.
struct ExportDescription: Codable, Equatable {
    var caption = ""
    var keywords: [String] = []
    var isEmpty: Bool { caption.isEmpty && keywords.isEmpty }
    func validate() throws {
        guard try PhotoCaption.normalized(caption) == caption,
              keywords.count <= 1024, Set(keywords.map(KeywordSummary.key)).count == keywords.count,
              keywords.reduce(caption.utf8.count, { $0 + $1.utf8.count }) <= 65536 else { throw LRCError(L10n.text("app.organizationMetadataIsTooLongOrDuplicatedExportWas", defaultValue: "Organization metadata is too long or duplicated. Export was not frozen")) }
        for keyword in keywords { guard try KeywordSummary.name(keyword) == keyword else { throw LRCError(L10n.text("app.invalidFrozenKeywords", defaultValue: "Invalid frozen keywords")) } }
    }
    func imageMetadata() throws -> CGImageMetadata? {
        try validate()
        guard !isEmpty else { return nil }
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let captionXML = caption.isEmpty ? "" : "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escaped(caption))</rdf:li></rdf:Alt></dc:description>"
        let keywordsXML = keywords.isEmpty ? "" : "<dc:subject><rdf:Bag>" + keywords.map { "<rdf:li>\(escaped($0))</rdf:li>" }.joined() + "</rdf:Bag></dc:subject>"
        let xml = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\(captionXML)\(keywordsXML)</rdf:Description></rdf:RDF></x:xmpmeta>"
        guard let result = CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData) else { throw LRCError(L10n.text("app.cannotEncodeKeywordsAndCaptionPublicationStopped", defaultValue: "Cannot encode keywords and caption. Publication stopped")) }
        return result
    }
    func verifyEmbedded(in source: CGImageSource, capturedAt: String? = nil) throws {
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        guard let metadata else {
            guard isEmpty else { throw LRCError(L10n.text("app.outputDoesNotContainTheFrozenOrganizationMetadata", defaultValue: "Output does not contain the frozen organization metadata")) }
            return
        }
        // ImageIO also projects structural TIFF/EXIF fields into this API. Bound every
        // namespace/name; arbitrary XMP fields, GPS, serial numbers and recipes fail.
        let allowed: [String: Set<String>] = [
            "http://purl.org/dc/elements/1.1/": ["description", "subject"],
            "http://ns.apple.com/ImageIO/1.0/": ["hasXMP", "hasIIM", "hasExif"],
            "http://ns.adobe.com/tiff/1.0/": ["Make", "Model", "Orientation", "Compression", "PhotometricInterpretation", "ResolutionUnit", "XResolution", "YResolution", "ImageWidth", "ImageLength", "BitsPerSample", "SamplesPerPixel", "PlanarConfiguration"],
            "http://ns.adobe.com/exif/1.0/": ["PixelXDimension", "PixelYDimension", "ColorSpace", "DateTimeOriginal", "ISOSpeedRatings", "FNumber", "ExposureTime", "FocalLength"],
            "http://ns.adobe.com/photoshop/1.0/": ["DateCreated"],
            "http://cipa.jp/exif/1.0/": ["LensMake", "LensModel", "PhotographicSensitivity"],
            "http://ns.adobe.com/exif/1.0/aux/": ["Lens", "LensMake", "LensModel"]
        ]
        for tag in CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? [] {
            let ns = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            guard allowed[ns]?.contains(name) == true else { throw LRCError(L10n.text("app.outputContainsADisallowedMetadataFieldPublicationStopped", defaultValue: "Output contains a disallowed metadata field \(name). Publication stopped")) }
        }
        if let date = CGImageMetadataCopyStringValueWithPath(metadata, nil, "photoshop:DateCreated" as CFString) as String? {
            guard let capturedAt, date == String(capturedAt.prefix(10)).replacingOccurrences(of: ":", with: "-") + "T" + capturedAt.suffix(8) else {
                throw LRCError(L10n.text("app.outputContainsAnUnselectedCaptureDate", defaultValue: "Output contains an unselected capture date"))
            }
        }
        let actualCaption = CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description" as CFString) as String? ?? ""
        let subject = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString)
        let elements = subject.flatMap { CGImageMetadataTagCopyValue($0) as? [CGImageMetadataTag] } ?? []
        let actualKeywords = elements.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        guard actualCaption == caption, actualKeywords.count == elements.count,
              Set(actualKeywords) == Set(keywords), actualKeywords.count == keywords.count else {
            throw LRCError(L10n.text("app.outputXMPKeywordsOrCaptionDifferOnReadbackPublication", defaultValue: "Output XMP keywords or caption differ on readback. Publication stopped"))
        }
        if let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:description" as CFString) {
            let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] ?? []
            guard !caption.isEmpty, values.count == 1 else { throw LRCError(L10n.text("app.outputCaptionContainsAnUnselectedLanguageOrContent", defaultValue: "Output caption contains an unselected language or content")) }
        }
        if subject != nil && keywords.isEmpty { throw LRCError(L10n.text("app.outputContainsAnUnselectedKeywordsField", defaultValue: "Output contains an unselected keywords field")) }
    }
}
