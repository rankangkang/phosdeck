import Foundation
import GRDB

struct StorageRoot: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "storageRoot"
    var id: String
    var path: String
    var bookmark: Data
    var label: String
}
struct Photo: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "photo"
    var id: String
    var sourceID: String? = nil
    var copyName: String? = nil
    var deleted = false
    var sourceKey: String { sourceID ?? id }
    var isVirtualCopy: Bool { copyName != nil }
    var versionName: String { copyName ?? L10n.text("app.originalVersion", defaultValue: "Original Version") }
    var displayName: String { isVirtualCopy ? name + " · " + versionName : name }
    var rootID: String
    var relativePath: String
    var identity: Data
    var identityKey: String
    var digest: String?
    var revision: Int = 1
    var rating: Int = 0
    var flag: Int = 0
    var colorLabel: Int = 0
    /// User-authored description belongs to this version, not its physical source.
    var caption: String = ""
    var captureDate: String?
    var width: Int
    var height: Int
    var camera: String?
    var availability: String = "available"
    var recipe: Data?
    var recipeRevision: Int = 0
    var metadata: Data?
    var details: PhotoMetadata? { metadata.flatMap { try? JSONDecoder().decode(PhotoMetadata.self, from: $0) } }
    var name: String { URL(fileURLWithPath: relativePath).lastPathComponent }
    var isRAW: Bool {
        let url = URL(fileURLWithPath:relativePath)
        guard PhotoFileType.isRAW(url) else { return false }
        return url.pathExtension.lowercased() != "dng" || details?.composite == nil
    }
    var supportsEditing: Bool { PhotoFileType.editableExtensions.contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased()) }
}
struct PhotoCollection: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "collection"
    var id: String
    var name: String
    var rules: Data? = nil
}

/// The complete regular collection and its relative membership order.
struct CollectionContents: Equatable {
    let collection: PhotoCollection
    let members: [String]
}

struct PhotoMetadata: Codable, Equatable {
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var exposureTime: Double?
    var focalLength: Double?
    var orientation: Int?
    var profile: String?
    var focal35mm: Double? = nil
    var composite: MergeProvenance? = nil
    var exposureText: String? {
        guard let value = exposureTime, value > 0 else { return nil }
        return value < 1 ? L10n.text("app.1S", defaultValue: "1/\(Int((1 / value).rounded())) s") : String(format: L10n.text("app.1fS", defaultValue: "%.1f s"), value)
    }
}

struct EditHistoryEntry: Codable, FetchableRecord, Identifiable {
    var id: Int64
    var photoID: String
    var title: String
    var createdAt: Double
    var recipe: Data
}
struct EditSnapshot: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "editSnapshot"
    var id: String
    var photoID: String
    var title: String
    var createdAt: Double
    var recipe: Data
}

struct AdjustmentPreset: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "adjustmentPreset"
    var id: String
    var name: String
    var recipe: Data
    var options: Data
    /// User-defined group for the preset browser. An empty value means the
    /// preset is shown in the ungrouped section.
    var groupName: String = ""
    /// Whether the preset is pinned to the browser's Favorites filter.
    var favorite: Bool = false
}

/// Organization belongs to a version, never to its shared physical source.
/// Stored values are stable identifiers; colors do not alter photo pixels.
enum PhotoColorLabel: Int, CaseIterable, Identifiable {
    case none = 0, red, yellow, green, blue, purple
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: L10n.text("app.noColorLabel", defaultValue: "No Color Label"); case .red: L10n.text("app.red", defaultValue: "Red"); case .yellow: L10n.text("app.yellow", defaultValue: "Yellow")
        case .green: L10n.text("app.green", defaultValue: "Green"); case .blue: L10n.text("app.blue", defaultValue: "Blue"); case .purple: L10n.text("app.purple", defaultValue: "Purple")
        }
    }
    var shortcut: String? { (1...4).contains(rawValue) ? String(rawValue + 5) : nil }
    var titleWithShortcut: String {
        guard let shortcut else { return title }
        return L10n.text("app.titleWithShortcut", defaultValue: "\(title) (\(shortcut))")
    }
}
