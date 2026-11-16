import Foundation
import GRDB

/// The table relationships follow LightCraft's Lightroom catalog reader. See the bundled attribution.
struct LightroomCatalog: Sendable {
    struct Root: Identifiable, Sendable {
        let id: Int64
        let path: String
        let relative: String
        let name: String
    }
    struct Version: Sendable {
        let id: Int64
        let master: Int64
        let root: Int64
        let path: String
        let name: String
        let rating: Int
        let flag: Int
        let label: String
        let captureDate: String?
        let orientation: String
        let width: Int
        let height: Int
        let settings: String?
        let currentHistoryID: Int64?
        let caption: String
        let keywords: [String]
    }
    struct Album: Sendable {
        let name: String
        let members: [Int64]
    }
    struct HistoryStep {
        let id: Int64
        let title: String
        let date: Double?
        let settings: String?
    }
    let file: URL
    let identity: FileIdentity
    let roots: [Root]
    let versions: [Version]
    let albums: [Album]
    let warnings: [String]
    var originalCount: Int { versions.count { $0.master == 0 } }

    static func preview(_ source: URL) throws -> Self {
        let identity = try requireClosed(source)
        let database = try openReadOnly(source)
        defer { try? database.close() }
        let preview = try database.read { db in
            let schema = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_schema WHERE type='table' AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'"))
            let required = ["AgLibraryRootFolder": ["id_local", "absolutePath"], "AgLibraryFolder": ["id_local", "rootFolder", "pathFromRoot"],
                            "AgLibraryFile": ["id_local", "folder", "idx_filename"], "Adobe_images": ["id_local", "rootFile"]]
            for (table, columns) in required {
                guard schema.contains(table), Set(columns.map { $0.lowercased() }).isSubset(of: try Set(db.columns(in: table).map { $0.name.lowercased() })) else { throw unsupported }
            }
            guard try String.fetchOne(db, sql: "PRAGMA quick_check(1)") == "ok" else { throw unsupported }
            var warnings: [String] = []
            func optional(_ table: String) throws -> [Row] {
                guard schema.contains(table) else { return [] }
                return try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
            }
            func keyed(_ rows: [Row]) -> [Int64: Row] {
                Dictionary(rows.compactMap { row in (try? row.decode(Int64.self, forColumn: "id_local")).map { ($0, row) } },
                           uniquingKeysWith: { first, _ in first })
            }
            let rootRows = try Row.fetchAll(db, sql: "SELECT * FROM AgLibraryRootFolder ORDER BY id_local")
            let roots = try rootRows.map { row in
                let path = value(row, "absolutePath") ?? ""
                let name = value(row, "name") ?? path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Photos"
                return Root(id: try row.decode(Int64.self, forColumn: "id_local"), path: path, relative: value(row, "relativePathFromCatalog") ?? "", name: name)
            }
            let rootIDs = Set(roots.map(\.id))
            guard rootIDs.count == roots.count else { throw unsupported }
            let folders = try keyed(Row.fetchAll(db, sql: "SELECT * FROM AgLibraryFolder"))
            let files = try keyed(Row.fetchAll(db, sql: "SELECT * FROM AgLibraryFile"))
            typealias DevelopState = (text: String?, historyID: Int64?)
            let develops = try Dictionary(optional("Adobe_imageDevelopSettings").compactMap { row -> (Int64, DevelopState)? in
                guard let image: Int64 = value(row, "image") else { return nil }
                return (image, (settingsText(row), value(row, "historySettingsID")))
            }, uniquingKeysWith: { first, _ in first })
            let xmp = try Dictionary(optional("Adobe_AdditionalMetadata").compactMap { row -> (Int64, String)? in
                let packet = value(row, "xmp", as: Data.self) ?? value(row, "xmp", as: String.self).map { Data($0.utf8) } ?? Data()
                guard let image: Int64 = value(row, "image"), let caption = LightroomSettings.caption(xmp: packet) else { return nil }
                return (image, caption)
            }, uniquingKeysWith: { first, _ in first })
            let iptc = try Dictionary(optional("AgHarvestedIptcMetadata").compactMap { row -> (Int64, String)? in
                guard let image: Int64 = value(row, "image"), let caption: String = value(row, "caption") else { return nil }
                return (image, caption)
            }, uniquingKeysWith: { first, _ in first })
            let exif = try Dictionary(optional("AgHarvestedExifMetadata").compactMap { row -> (Int64, String)? in
                guard let image: Int64 = value(row, "image"), let date: String = value(row, "dateTimeOriginal") else { return nil }
                return (image, date)
            }, uniquingKeysWith: { first, _ in first })
            let tags = try keyed(optional("AgLibraryKeyword"))
            var keywords: [Int64: [String]] = [:]
            for row in try optional("AgLibraryKeywordImage") {
                try Task.checkCancellation()
                guard let image: Int64 = value(row, "image"), let tag: Int64 = value(row, "tag") else { continue }
                let parts = hierarchy(tag, rows: tags)
                if !parts.isEmpty { keywords[image, default: []].append(parts.joined(separator: " | ")) }
            }
            var versions: [Version] = []
            let images = try Row.fetchCursor(db, sql: "SELECT * FROM Adobe_images ORDER BY id_local")
            while let row = try images.next() {
                try Task.checkCancellation()
                let id = try row.decode(Int64.self, forColumn: "id_local")
                guard let file = files[value(row, "rootFile") ?? 0], let folder = folders[value(file, "folder") ?? 0],
                      let root: Int64 = value(folder, "rootFolder"), rootIDs.contains(root), let filename: String = value(file, "idx_filename"),
                      !filename.isEmpty, !filename.contains("/"), !filename.contains("\\") else {
                    warnings.append("\(id) · " + L10n.text("lightroom.incompletePath", defaultValue: "Incomplete source path"))
                    continue
                }
                let folderPath = (value(folder, "pathFromRoot", as: String.self) ?? "").replacingOccurrences(of: "\\", with: "/")
                let path = folderPath + "/" + filename
                let relative = path.split(separator: "/").joined(separator: "/")
                guard !folderPath.hasPrefix("/"), !folderPath.contains(":"), (try? ProjectCopy.child(relative, of: URL(fileURLWithPath: "/"))) != nil else {
                    warnings.append("\(id) · " + L10n.text("lightroom.incompletePath", defaultValue: "Incomplete source path"))
                    continue
                }
                let develop = develops[id]
                let settings = develop?.text
                if develop != nil, settings == nil {
                    warnings.append(relative + " · " + L10n.text("lightroom.invalidSettings", defaultValue: "Unsupported Lightroom develop settings format."))
                }
                versions.append(Version(id: id, master: value(row, "masterImage") ?? 0, root: root, path: relative,
                    name: value(row, "copyName") ?? "", rating: value(row, "rating") ?? 0, flag: value(row, "pick") ?? 0,
                    label: value(row, "colorLabels") ?? "", captureDate: value(row, "captureTime") ?? exif[id], orientation: value(row, "orientation") ?? "",
                    width: value(row, "fileWidth") ?? 0, height: value(row, "fileHeight") ?? 0, settings: settings,
                    currentHistoryID: develop?.historyID,
                    caption: xmp[id] ?? iptc[id] ?? "", keywords: keywords[id] ?? []))
            }
            var members: [Int64: [(String, Int64)]] = [:]
            for row in try optional("AgLibraryCollectionImage") {
                guard let album: Int64 = value(row, "collection"), let image: Int64 = value(row, "image") else { continue }
                let order: String = value(row, "positionInCollection") ?? ""
                members[album, default: []].append((order, image))
            }
            let collections = try keyed(optional("AgLibraryCollection"))
            var albums: [Album] = []
            for id in collections.keys.sorted() {
                guard let row = collections[id], (value(row, "systemOnly", as: Int.self) ?? 0) == 0 else { continue }
                let creation = (value(row, "creationId", as: String.self) ?? "").lowercased()
                let name = hierarchy(id, rows: collections).joined(separator: " / ")
                guard !name.isEmpty else { continue }
                if creation.contains("group") { continue }
                if creation.contains("smart") || creation.contains("book") || creation.contains("slideshow") || creation.contains("print") || creation.contains("web") {
                    warnings.append(name + " · " + L10n.text("lightroom.sourceCollectionOnly", defaultValue: "Collection retained in the Lightroom catalog"))
                    continue
                }
                let sorted = (members[id] ?? []).sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                albums.append(Album(name: name, members: sorted.map(\.1)))
            }
            if schema.contains(historyTable), try !hasHistory(in: db) {
                warnings.append(L10n.text("lightroom.unsupportedHistory", defaultValue: "Unsupported Lightroom history layout. The steps remain in the source catalog copy."))
            }
            let usedRoots = Set(versions.lazy.filter { $0.master == 0 }.map(\.root))
            return Self(file: source, identity: identity, roots: roots.filter { usedRoots.contains($0.id) }, versions: versions, albums: albums, warnings: warnings)
        }
        guard try requireClosed(source) == identity else { throw ProjectCopy.changed(source) }
        return preview
    }

    func requireUnchanged() throws {
        guard try Self.requireClosed(file) == identity else { throw ProjectCopy.changed(file) }
    }

    static func openReadOnly(_ source: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA trusted_schema = OFF") }
        // A closed catalog can still be in WAL mode. Read it without creating SQLite sidecars.
        return try DatabaseQueue(path: source.absoluteString + "?immutable=1", configuration: config)
    }

    private static let historyTable = "Adobe_libraryImageDevelopHistoryStep"

    static func hasHistory(in db: Database) throws -> Bool {
        guard try Bool.fetchOne(db, sql: """
            SELECT 1 FROM sqlite_schema WHERE type='table' AND name=? AND sql NOT LIKE 'CREATE VIRTUAL TABLE%'
            """, arguments: [historyTable]) == true else { return false }
        let columns = try Set(db.columns(in: historyTable).map { $0.name.lowercased() })
        return Set(["image", "id_local", "name", "datecreated", "text"]).isSubset(of: columns)
    }

    static func history(in db: Database, image: Int64) throws -> [HistoryStep] {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id_local, name, dateCreated, text FROM \(historyTable) WHERE image=? ORDER BY dateCreated, id_local
            """, arguments: [image])
        var steps: [HistoryStep] = []
        while let row = try rows.next() {
            try Task.checkCancellation()
            let id: Int64 = try row.decode(forColumn: "id_local")
            let date: Double? = value(row, "dateCreated")
            let timestamp = date.flatMap { $0.isFinite ? Date(timeIntervalSinceReferenceDate: $0).timeIntervalSince1970 : nil }
            let name = (value(row, "name", as: String.self) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? L10n.text("lightroom.historyStep", defaultValue: "Lightroom History Step") : String(name.prefix(200))
            steps.append(HistoryStep(id: id, title: title, date: timestamp, settings: settingsText(row)))
        }
        return steps
    }

    private static func settingsText(_ row: Row) -> String? {
        guard let stored: DatabaseValue = value(row, "text") else { return nil }
        switch stored.storage {
        case .string(let text): return text
        case .blob(let bytes):
            if let expanded = LightroomSettings.unzip(bytes) { return String(data: expanded, encoding: .utf8) }
            return String(data: bytes, encoding: .utf8)
        default: return nil
        }
    }

    private static func requireClosed(_ file: URL) throws -> FileIdentity {
        guard file.pathExtension.lowercased() == "lrcat" else { throw unsupported }
        let fm = FileManager.default
        let sideFiles = [".lock", "-journal", "-wal"]
        guard sideFiles.allSatisfy({ !fm.fileExists(atPath: file.path + $0) }) else {
            throw LRCError(L10n.text("lightroom.closeSource", defaultValue: "Close Lightroom Classic or choose a closed copy of the catalog, then scan again."))
        }
        return try FileIdentity.read(file)
    }

    private static func hierarchy(_ id: Int64, rows: [Int64: Row]) -> [String] {
        var parts: [String] = []
        var visited = Set<Int64>()
        var next = id
        while next != 0, visited.count < 64, visited.insert(next).inserted, let row = rows[next] {
            if let name: String = value(row, "name"), !name.isEmpty { parts.append(name) }
            next = value(row, "parent") ?? 0
        }
        return parts.reversed()
    }

    private static func value<T: DatabaseValueConvertible>(_ row: Row, _ column: String, as: T.Type = T.self) -> T? {
        try? row.decode(T.self, forColumn: column)
    }

    private static var unsupported: LRCError {
        LRCError(L10n.text("lightroom.unsupportedCatalog", defaultValue: "Choose a supported Lightroom Classic .lrcat catalog."))
    }
}
