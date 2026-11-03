import Foundation
import UniformTypeIdentifiers

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, png, tiff
    var id: String { rawValue }
    var title: String { self == .jpeg ? "JPEG" : self == .png ? L10n.text("app.png8Bit", defaultValue: "PNG · 8-bit") : L10n.text("app.tiff16Bit", defaultValue: "TIFF · 16-bit") }
    var fileExtension: String { self == .jpeg ? "jpg" : self == .png ? "png" : "tif" }
    var type: UTType { self == .jpeg ? .jpeg : self == .png ? .png : .tiff }
    var bitDepth: Int { self == .tiff ? 16 : 8 }
}

enum JPEGMatte: String, Codable, CaseIterable, Identifiable {
    case unselected, black, white
    var id: String { rawValue }
    var title: String { self == .unselected ? L10n.text("app.chooseAMatteColor", defaultValue: "Choose a Matte Color") : self == .black ? L10n.text("app.black", defaultValue: "Black") : L10n.text("app.white", defaultValue: "White") }
}

struct ExportOptions: Codable, Equatable {
    var format: ExportFormat = .jpeg
    var longEdge: Int?
    var quality = 0.9
    var naming = ExportNaming()
    var metadataPolicy = ExportMetadataPolicy.none
    // Required in persisted settings/tasks. Older structures are rejected, not migrated.
    var jpegMatte = JPEGMatte.unselected
    func validate() throws {
        try naming.validate()
        guard quality.isFinite, (0.1...1).contains(quality), longEdge.map({ (1...30000).contains($0) }) ?? true
        else { throw LRCError(L10n.text("app.invalidOutputOptionsLongEdgeMustBe130000", defaultValue: "Invalid output options: long edge must be 1–30000 px and JPEG quality must be 10–100")) }
    }
    var summary: String {
        "\(format.title) · sRGB · \(longEdge.map { L10n.text("app.longEdgePx", defaultValue: "Long edge \($0) px") } ?? L10n.text("app.originalSize", defaultValue: "Original Size")) · \(metadataPolicy.title)" +
            (format == .jpeg ? L10n.text("app.matte", defaultValue: " · Matte: \(jpegMatte.title)") : L10n.text("app.preserveAlpha", defaultValue: " · Preserve Alpha"))
    }
}

struct ExportPreset: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var options: ExportOptions
    static let builtIns = [
        Self(id: "web", name: L10n.text("app.webSharing", defaultValue: "Web Sharing"), options: ExportOptions(longEdge: 2048)),
        Self(id: "tiff", name: L10n.text("app.16BitTIFFArchive", defaultValue: "16-bit TIFF Archive"), options: ExportOptions(format: .tiff)),
        Self(id: "png", name: L10n.text("app.losslessPNG", defaultValue: "Lossless PNG"), options: ExportOptions(format: .png))
    ]
}

/// App-wide presets contain output settings only, never paths or file-access bookmarks.
struct ExportPreferences: Codable, Equatable {
    var lastOptions = ExportOptions()
    var presets: [ExportPreset] = []
    static let key = "exportPreferences"
    mutating func storePreset(name: String, options: ExportOptions, id: String? = nil) throws -> String {
        var next = self
        let preset = ExportPreset(id: id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), options: options)
        if let id {
            guard let index = next.presets.firstIndex(where: { $0.id == id }) else { throw LRCError(L10n.text("app.theExportPresetDoesNotExist", defaultValue: "The export preset does not exist")) }
            next.presets[index] = preset
        } else { next.presets.append(preset) }
        try next.validate()
        self = next
        return preset.id
    }
    func validate() throws {
        try lastOptions.validate()
        guard presets.count <= 100, Set(presets.map(\.id)).count == presets.count,
              !presets.contains(where: { p in ExportPreset.builtIns.contains { $0.id == p.id } }),
              Set(presets.map { $0.name.lowercased() }).count == presets.count
        else { throw LRCError(L10n.text("app.exportPresetsAreDuplicatedOrExceedTheLimitOf", defaultValue: "Export presets are duplicated or exceed the limit of 100")) }
        for preset in presets {
            guard !preset.id.isEmpty, !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, preset.name.count <= 100
            else { throw LRCError(L10n.text("app.presetNamesMustHave1100Characters", defaultValue: "Preset names must have 1–100 characters")) }
            try preset.options.validate()
        }
    }
    static func load(from defaults: UserDefaults = .standard) throws -> Self {
        guard let data = defaults.data(forKey: key) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func save(to defaults: UserDefaults = .standard) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: Self.key)
    }
}
