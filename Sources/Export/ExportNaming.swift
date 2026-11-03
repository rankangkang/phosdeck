import Foundation

struct ExportNaming: Codable, Equatable {
    var originalName = true
    var captureDate = false
    var prefix = ""
    var suffix = ""
    var sequence = false
    var start = 1
    var digits = 4

    func validate() throws {
        guard (0...999_999_999).contains(start), (1...9).contains(digits),
              prefix.utf8.count <= 240, suffix.utf8.count <= 240,
              originalName || captureDate || sequence || !(prefix + suffix).isEmpty
        else { throw LRCError(L10n.text("app.invalidNamingSelectAComponentOrEnterAPrefix", defaultValue: "Invalid naming: select a component or enter a prefix / suffix. Sequence start: 0–999999999; padding: 1–9 digits; prefix and suffix: up to 240 UTF-8 bytes each")) }
    }
}

struct ExportName: Identifiable, Equatable {
    let id: String
    let sourceName: String
    let filename: String
    let sequence: Int?
    var warnings: [String] = []
    var errors: [String] = []
}

enum ExportNamingPlanner {
    /// Conservative across case-sensitive/insensitive volumes and Unicode normalization.
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func preview(photos: [Photo], options: ExportOptions, directory: URL? = nil) throws -> [ExportName] {
        try options.validate()
        let naming = options.naming
        guard !naming.sequence || photos.count <= 1_000_000_000 - naming.start else { throw LRCError(L10n.text("app.theSequenceExceeds999999999NoNameWasAssigned", defaultValue: "The sequence exceeds 999999999. No name was assigned")) }
        let existing = try directory.map {
            Set(try FileManager.default.contentsOfDirectory(atPath: $0.path).map(collisionKey))
        } ?? []
        var result = photos.enumerated().map { index, photo in
            var components = [String](), warnings = [String]()
            if naming.captureDate {
                if let day = LibraryMetadataFilter.day(photo.captureDate) { components.append(day.replacingOccurrences(of: "-", with: "")) }
                else { components.append("undated"); warnings.append(L10n.text("app.captureDateMissingOrInvalidUsingUndated", defaultValue: "Capture date missing or invalid; using undated")) }
            }
            if naming.originalName {
                components.append((photo.name as NSString).deletingPathExtension)
                if let name = photo.copyName { components.append(name) }
            }
            let sequence = naming.sequence ? naming.start + index : nil
            if let sequence { components.append(String(repeating: "0", count: max(0, naming.digits - String(sequence).count)) + String(sequence)) }
            let raw = naming.prefix + components.joined(separator: "_") + naming.suffix
            let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
            let stem = String(String.UnicodeScalarView(raw.precomposedStringWithCanonicalMapping.unicodeScalars.map {
                forbidden.contains($0) ? UnicodeScalar(95)! : $0
            })).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if stem != raw { warnings.append(L10n.text("app.invalidCharactersReplacedWithLeadingTrailingSpacesAndDots", defaultValue: "Invalid characters replaced with _; leading / trailing spaces and dots removed; Unicode normalized")) }
            let filename = stem + "." + options.format.fileExtension
            var errors = [String]()
            if stem.isEmpty { errors.append(L10n.text("app.theNameCannotBeEmpty", defaultValue: "The name cannot be empty")) }
            if filename.utf8.count > 240 { errors.append(L10n.text("app.theFilenameExceeds240UTF8BytesIncludingThe", defaultValue: "The filename exceeds 240 UTF-8 bytes including the extension. Shorten the prefix / suffix or omit the original name")) }
            // Windows reserved names are refused even when exporting on macOS.
            let device = stem.split(separator: ".").first.map { String($0).uppercased() } ?? ""
            if ["CON", "PRN", "AUX", "NUL"].contains(device) || (1...9).contains(where: { device == "COM\($0)" || device == "LPT\($0)" }) {
                errors.append(L10n.text("app.systemReservedFilenameAddAPrefixSuffixOrSequence", defaultValue: "System-reserved filename. Add a prefix, suffix, or sequence"))
            }
            if existing.contains(collisionKey(filename)) { errors.append(L10n.text("app.anItemWithThisNameAlreadyExistsAtThe", defaultValue: "An item with this name already exists at the destination. Overwriting is not allowed")) }
            return ExportName(id: photo.id, sourceName: photo.displayName, filename: filename, sequence: sequence, warnings: warnings, errors: errors)
        }
        let counts = Dictionary(grouping: result, by: { collisionKey($0.filename) }).mapValues(\.count)
        for index in result.indices where counts[collisionKey(result[index].filename), default: 0] > 1 {
            result[index].errors.append(L10n.text("app.duplicateBatchNamesAfterCaseAndUnicodeNormalizationEnable", defaultValue: "Duplicate batch names after case and Unicode normalization. Enable a sequence or change the template"))
        }
        return result
    }
}
