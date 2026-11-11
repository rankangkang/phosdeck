import Foundation
import GRDB

enum PhotoSort: String, CaseIterable, Codable, Identifiable {
    case filename, captureDate, rating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filename: return L10n.text("app.filename", defaultValue: "Filename")
        case .captureDate: return L10n.text("app.captureTime", defaultValue: "Capture Time")
        case .rating: return L10n.text("app.rating_415", defaultValue: "Rating")
        }
    }
}

struct LibraryMetadataFilter: Codable, Equatable {
    var camera = ""
    var lens = ""
    var minimumISO = ""
    var maximumISO = ""
    var dateFrom = ""
    var dateThrough = ""
    var isActive: Bool { self != LibraryMetadataFilter() }
    var validationMessage: String? {
        for text in [minimumISO, maximumISO] where !text.isEmpty {
            guard let value = Int(text), value > 0 else { return L10n.text("app.isoMustBeAPositiveInteger", defaultValue: "ISO must be a positive integer") }
        }
        if let low = Int(minimumISO), let high = Int(maximumISO), low > high { return L10n.text("app.theMinimumISOCannotExceedTheMaximum", defaultValue: "The minimum ISO cannot exceed the maximum") }
        for text in [dateFrom, dateThrough] where !text.isEmpty {
            if Self.day(text) != text { return L10n.text("app.enterAValidDateAsYYYYMMDD", defaultValue: "Enter a valid date as YYYY-MM-DD") }
        }
        if !dateFrom.isEmpty, !dateThrough.isEmpty, dateFrom > dateThrough { return L10n.text("app.theStartDateCannotBeLaterThanTheEnd", defaultValue: "The start date cannot be later than the end date") }
        return nil
    }
    /// EXIF local calendar day, without inventing a time zone or using file timestamps.
    static func day(_ text: String?) -> String? {
        guard let text, text.count >= 10 else { return nil }
        let value = String(text.prefix(10)).replacingOccurrences(of: ":", with: "-")
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let days = [31, year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1] ? value : nil
    }
}

enum PhotoFlag: Int, CaseIterable, Identifiable {
    case picked = 1, unflagged = 0, rejected = -1
    var id: Int { rawValue }
    var title: String { switch self { case .picked: L10n.text("app.pick", defaultValue: "Pick"); case .unflagged: L10n.text("app.unflagged", defaultValue: "Unflagged"); case .rejected: L10n.text("app.reject", defaultValue: "Reject") } }
    var icon: String { switch self { case .picked: "flag.fill"; case .unflagged: "flag"; case .rejected: "flag.slash.fill" } }
    var shortcut: String { switch self { case .picked: "P / `"; case .unflagged: "U"; case .rejected: "X" } }
}

enum RatingComparison: String, CaseIterable, Identifiable {
    case atLeast, atMost, equal, greaterThan, lessThan
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .atLeast: "≥"; case .atMost: "≤"; case .equal: "＝"
        case .greaterThan: ">"; case .lessThan: "<"
        }
    }
    var title: String { L10n.text("app.rating_415", defaultValue: "Rating") + smartOperator.title }
    var smartOperator: SmartOperator {
        switch self {
        case .atLeast: .atLeast; case .atMost: .atMost; case .equal: .equal
        case .greaterThan: .greaterThan; case .lessThan: .lessThan
        }
    }
    var sqlSymbol: String {
        switch self {
        case .atLeast: ">="; case .atMost: "<="; case .equal: "="
        case .greaterThan: ">"; case .lessThan: "<"
        }
    }
    func isActive(threshold: Int) -> Bool { self != .atLeast || threshold != 0 }
}

struct PhotoQuery: Equatable {
    var scope = "all"
    var search = ""
    var ratingThreshold = 0
    var ratingComparison = RatingComparison.atLeast
    var flags: Set<Int> = []
    var colorLabels: Set<Int> = []
    var keyword = ""
    var metadata = LibraryMetadataFilter()
    var sort = PhotoSort.captureDate
    var descending = false
    /// Session-only SQL snapshot: freezes both membership and order, never photo state.
    var snapshotID: String?
    var smart: SmartRules?
    var invalidSmart = false
    /// Kept separate from PhotoSort so existing filename/date/rating sorting
    /// remains source-compatible. The AppModel exposes this only for regular
    /// collections.
    var manualCollectionOrder = false
    /// Manual order is meaningful only for a regular collection. The AppModel
    /// hides the option elsewhere; keeping the predicate defensive prevents a
    /// stale preference from changing all/root/smart ordering.
    var isManualCollectionOrder: Bool {
        manualCollectionOrder && smart == nil && scope.hasPrefix("collection:")
    }
    var relation: String {
        var base = snapshotID == nil ? "photo" : "photo JOIN temp.browseSnapshot AS held ON photo.id=held.photoID"
        if snapshotID == nil, smart == nil, scope.hasPrefix("related:") {
            base += " JOIN temp.browseSnapshot AS related ON photo.id=related.photoID"
        }
        guard isManualCollectionOrder else { return base }
        // The collection predicate below binds the collection id. Joining all
        // membership rows here is safe because the predicate narrows it to the
        // requested collection; it also lets ORDER BY use the existing rowid.
        return base + " JOIN membership ON membership.photoID=photo.id"
    }
    var order: String {
        if snapshotID != nil { return "held.position" }
        if smart == nil, scope.hasPrefix("related:") { return "related.position" }
        let direction = descending ? " DESC" : " ASC"
        let primary: String
        switch sort {
        case .filename: primary = "photo_filename_key(relativePath) COLLATE BINARY" + direction
        case .captureDate: primary = "(photo_day(captureDate) IS NULL) ASC, photo_day(captureDate)" + direction + ", substr(captureDate, 11)" + direction
        case .rating: primary = "rating" + direction
        }
        if isManualCollectionOrder { return "membership.rowid ASC, relativePath COLLATE BINARY ASC, photo.id ASC" }
        return primary + ", relativePath COLLATE BINARY ASC, photo.id ASC"
    }
    // Query arguments remain bound, including LIKE metacharacters in literal user input.
    var predicate: (String, StatementArguments) {
        // Hold metadata/filter membership and order, but still require that a
        // photo exists in the source shown. Mirrors Session::visible's `within`
        // constraint (LightCraft 4f0b110), without its dynamic admission of matches.
        if invalidSmart { return ("0",[]) }
        let (source, sourceArgs) = sourcePredicate
        if let snapshotID { return ("photo.deleted=0 AND held.snapshotID=? AND (" + source + ")", [snapshotID] + sourceArgs) }
        var sql = ["photo.deleted=0", "rating \(ratingComparison.sqlSymbol) ?"], values: [DatabaseValueConvertible] = [ratingThreshold]
        if metadata.validationMessage != nil { sql.append("0") }
        if !metadata.camera.isEmpty { sql.append("camera LIKE ? ESCAPE '\\' COLLATE NOCASE"); values.append("%" + Self.escape(metadata.camera) + "%") }
        if !metadata.lens.isEmpty { sql.append("photo_lens(metadata) LIKE ? ESCAPE '\\' COLLATE NOCASE"); values.append("%" + Self.escape(metadata.lens) + "%") }
        if let value = Int(metadata.minimumISO) { sql.append("photo_iso(metadata) >= ?"); values.append(value) }
        if let value = Int(metadata.maximumISO) { sql.append("photo_iso(metadata) <= ?"); values.append(value) }
        if !metadata.dateFrom.isEmpty { sql.append("photo_day(captureDate) >= ?"); values.append(metadata.dateFrom) }
        if !metadata.dateThrough.isEmpty { sql.append("photo_day(captureDate) <= ?"); values.append(metadata.dateThrough) }
        if !flags.isEmpty {
            let selected = flags.sorted()
            sql.append("flag IN (" + selected.map { _ in "?" }.joined(separator: ",") + ")")
            values.append(contentsOf: selected)
        }
        if !colorLabels.isEmpty {
            let selected = colorLabels.sorted()
            sql.append("colorLabel IN (" + selected.map { _ in "?" }.joined(separator: ",") + ")")
            values.append(contentsOf: selected)
        }
        if !keyword.isEmpty {
            sql.append("id IN (SELECT photoID FROM photoKeyword WHERE keyword = ?)")
            values.append(KeywordSummary.key(keyword))
        }
        if !search.isEmpty { sql.append("photo_filename(relativePath) LIKE ? ESCAPE '\\' COLLATE NOCASE"); values.append("%" + Self.escape(search) + "%") }
        let (rules,ruleArgs) = smart?.sql ?? ("1",StatementArguments())
        return ((sql + [source,rules]).joined(separator: " AND "), StatementArguments(values) + sourceArgs + ruleArgs)
    }
    private var sourcePredicate: (String, StatementArguments) {
        let scope = smart?.source ?? self.scope
        if scope.hasPrefix("import:") {
            return ("photo.id IN (SELECT photoID FROM temp.browseSnapshot WHERE snapshotID=?)", [String(scope.dropFirst(7))])
        } else if scope.hasPrefix("related:") {
            if snapshotID == nil, smart == nil { return ("related.snapshotID=?", [String(scope.dropFirst(8))]) }
            return ("photo.id IN (SELECT photoID FROM temp.browseSnapshot WHERE snapshotID=?)", [String(scope.dropFirst(8))])
        } else if scope.hasPrefix("collection:") {
            if isManualCollectionOrder {
                return ("membership.collectionID = ?", [String(scope.dropFirst(11))])
            }
            return ("photo.id IN (SELECT photoID FROM membership WHERE collectionID = ?)", [String(scope.dropFirst(11))])
        } else if scope.hasPrefix("folder:") {
            let parts = scope.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3 {
                return ("rootID = ? AND relativePath LIKE ? ESCAPE '\\'", [parts[1], Self.escape(parts[2]) + "/%"])
            }
            return ("0", [])
        } else if scope != "all" { return ("rootID = ?", [scope]) }
        return ("1", [])
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}
struct PhotoPage {
    var photos: [Photo]
    var total: Int
    var offset: Int
    var visibleTotal: Int = 0
    var badges: [String:StackBadge] = [:]
    var databaseChanges = 0
}
enum PhotoPageError: Error { case staleCursor }

extension CatalogStore {
    // Arrange the WHOLE base result before LIMIT/OFFSET. Only IDs/ranks enter
    // the windows; recipes/metadata are fetched for the displayed page alone.
    private func stackCTE(_ query: PhotoQuery) -> String {
        let (predicate,_) = query.predicate
        // A related temporary source represents an explicit stack/group
        // context. Show every captured member there even when the persistent
        // stack is collapsed; this is query-local and never mutates the stack.
        let visibleCondition = query.scope.hasPrefix("related:")
            ? "1"
            : "stackID IS NULL OR collapsed=0 OR position=firstPosition"
        let visibleOrder = query.scope.hasPrefix("related:") ? "basePosition" : "groupPosition,coalesce(position,0)"
        return """
        WITH base AS (SELECT photo.id, row_number() OVER (ORDER BY \(query.order)) AS basePosition FROM \(query.relation) WHERE \(predicate)),
        ranked AS (SELECT base.*,m.stackID,m.position,s.collapsed,
          min(basePosition) OVER (PARTITION BY CASE WHEN m.stackID IS NULL THEN 'p:'||base.id ELSE 's:'||m.stackID END) AS groupPosition,
          min(m.position) OVER (PARTITION BY m.stackID) AS firstPosition,
          count(*) OVER (PARTITION BY m.stackID) AS matching
          FROM base LEFT JOIN stackMember m ON m.photoID=base.id LEFT JOIN displayStack s ON s.id=m.stackID),
        visible AS (SELECT *, row_number() OVER (ORDER BY \(visibleOrder))-1 AS displayPosition
          FROM ranked WHERE \(visibleCondition))
        """
    }
    func page(_ query: PhotoQuery, offset: Int, limit: Int = 200, expectedChanges: Int? = nil) throws -> PhotoPage {
        let (_, args) = query.predicate, cte = stackCTE(query), size = max(1, min(1000, limit))
        return try database.read { db in
            let changes = db.totalChangesCount
            if let expectedChanges, changes != expectedChanges { throw PhotoPageError.staleCursor }
            let counts = try Row.fetchOne(db,sql:cte+" SELECT (SELECT count(*) FROM base) AS total,(SELECT count(*) FROM visible) AS shown",arguments:args)!
            let count: Int = counts["total"], shown: Int = counts["shown"]
            let start = min(max(0, offset), max(0, ((shown - 1) / size) * size))
            let rows = try Row.fetchAll(db,sql:cte+" SELECT photo.*,v.stackID,v.position,v.collapsed,v.matching,(SELECT count(*) FROM stackMember WHERE stackID=v.stackID) AS stackCount FROM visible v JOIN photo ON photo.id=v.id ORDER BY v.displayPosition LIMIT ? OFFSET ?",arguments:args+[size,start])
            var badges = [String:StackBadge]()
            for row in rows {
                if let sid: String = row["stackID"] { let id: String = row["id"]; badges[id] = StackBadge(stackID:sid,position:row["position"],count:row["stackCount"],matching:row["matching"],collapsed:row["collapsed"]) }
            }
            return PhotoPage(photos:try rows.map { try Photo(row:$0) },total:count,offset:start,visibleTotal:shown,badges:badges,databaseChanges:changes)
        }
    }
    func offset(of id: String, query: PhotoQuery) throws -> Int? {
        let (_,args) = query.predicate
        return try database.read { try Int.fetchOne($0,sql:stackCTE(query)+" SELECT displayPosition FROM visible WHERE id=?",arguments:args+[id]) }
    }
    func representative(of id: String, query: PhotoQuery) throws -> String? {
        let (_,args) = query.predicate
        return try database.read { try String.fetchOne($0,sql:stackCTE(query)+" SELECT v.id FROM visible v JOIN ranked r ON r.id=? WHERE v.id=r.id OR v.stackID=r.stackID ORDER BY v.displayPosition LIMIT 1",arguments:args+[id]) }
    }
    func allResultIDs(_ query: PhotoQuery, visibleOnly: Bool = false) throws -> [String] {
        let (predicate,args) = query.predicate
        return try database.read { db in
            if visibleOnly { return try String.fetchAll(db,sql:stackCTE(query)+" SELECT id FROM visible ORDER BY displayPosition",arguments:args) }
            return try String.fetchAll(db,sql:"SELECT photo.id FROM "+query.relation+" WHERE "+predicate+" ORDER BY "+query.order,arguments:args)
        }
    }
    /// Explicit members of the current import; independent from held filter results.
    /// The array overload preserves caller order for related version groups.
    func snapshotPhotos(_ ids: [String]) throws -> String {
        let snapshot = UUID().uuidString
        try database.write { db in
            let insert = try db.makeStatement(sql: "INSERT INTO temp.browseSnapshot SELECT ?, id, ? FROM photo WHERE id=? AND deleted=0")
            var seen = Set<String>(), position = 0
            for id in ids where seen.insert(id).inserted {
                try insert.execute(arguments: [snapshot, position, id])
                position += 1
            }
        }
        return snapshot
    }
    func snapshotPhotos(_ ids: Set<String>) throws -> String {
        try snapshotPhotos(ids.sorted())
    }
    func holdResults(_ query: PhotoQuery, replacing old: String?) throws -> String {
        var live = query; live.snapshotID = nil
        let (predicate, args) = live.predicate, id = UUID().uuidString
        try database.write { db in
            if let old { try db.execute(sql: "DELETE FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [old]) }
            // Keep the same relation used to build the live query. A manual
            // collection joins membership so its persisted rowid order is
            // frozen into the snapshot; using bare `photo` here would both
            // lose that order and leave the predicate's membership alias
            // unresolved.
            try db.execute(sql: "INSERT INTO temp.browseSnapshot SELECT ?, photo.id, row_number() OVER (ORDER BY " + live.order + ") FROM " + live.relation + " WHERE " + predicate, arguments: [id] + args)
        }
        return id
    }
    func releaseResults(_ id: String) throws {
        try database.write { try $0.execute(sql: "DELETE FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [id]) }
    }
    func resultIDs(_ query: PhotoQuery, within ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let (predicate, args) = query.predicate
        return try database.read { db in
            var result = Set<String>()
            // Bounded bindings, including selections carried across many pages.
            let values = Array(ids)
            for start in stride(from: 0, to: values.count, by: 500) {
                let chunk = Array(values[start..<min(values.count, start + 500)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                result.formUnion(try String.fetchAll(db, sql: "SELECT photo.id FROM " + query.relation + " WHERE " + predicate + " AND photo.id IN (" + placeholders + ")", arguments: args + StatementArguments(chunk)))
            }
            return result
        }
    }
    func firstResult(_ query: PhotoQuery, within ids: Set<String>) throws -> Photo? {
        guard !ids.isEmpty else { return nil }
        let (predicate, args) = query.predicate, values = Array(ids)
        let candidates = try database.read { db in
            try stride(from: 0, to: values.count, by: 500).compactMap { start -> Photo? in
                let chunk = Array(values[start..<min(values.count, start + 500)])
                return try Photo.fetchOne(db, sql: "SELECT photo.* FROM " + query.relation + " WHERE " + predicate + " AND photo.id IN (" + Array(repeating: "?", count: chunk.count).joined(separator: ",") + ") ORDER BY " + query.order + " LIMIT 1", arguments: args + StatementArguments(chunk))
            }
        }
        if candidates.count <= 1 { return candidates.first }
        return try candidates.compactMap { photo -> (Photo, Int)? in try offset(of: photo.id, query: query).map { (photo, $0) } }.min { $0.1 < $1.1 }?.0
    }
    /// One transaction, all SQL matches across every page. A held query uses its frozen members.
    @discardableResult func collectResults(_ query: PhotoQuery, collection: String, newName: String? = nil) throws -> Int {
        let (predicate, args) = query.predicate
        return try database.write { db in
            if let newName { try PhotoCollection(id: collection, name: newName.trimmingCharacters(in: .whitespacesAndNewlines)).insert(db) }
            try requireManualCollection(db,id:collection)
            // Explicitly preserve the current query order when appending to a
            // manual collection. SQLite does not promise row order for a bare
            // INSERT…SELECT, and rowid is the collection's persisted order.
            try db.execute(sql: "INSERT OR IGNORE INTO membership SELECT ?, photo.id FROM " + query.relation + " WHERE " + predicate + " ORDER BY " + query.order, arguments: [collection] + args)
            return db.changesCount
        }
    }
    func photo(_ id: String) throws -> Photo? { try database.read { try Photo.fetchOne($0, sql: "SELECT * FROM photo WHERE id=? AND deleted=0", arguments:[id]) } }
    func matchesPhotoRevisions(id: String, source: Int, recipe: Int) throws -> Bool {
        try database.read {
            try Int.fetchOne($0, sql: "SELECT 1 FROM photo WHERE id=? AND deleted=0 AND revision=? AND recipeRevision=? AND availability='available'",
                             arguments: [id, source, recipe]) != nil
        }
    }
    func photos(ids: Set<String>) throws -> [Photo] {
        try database.read { try Self.photos(ids: ids, in: $0) }
    }
    static func photos(ids: Set<String>, in db: Database) throws -> [Photo] {
        try Photo.filter(ids.contains(Column("id"))).filter(Column("deleted") == false).order(Column("captureDate"), Column("relativePath"), Column("id")).fetchAll(db)
    }
    /// All selected SQL results, in the current browse order, independent of pagination.
    func exportPhotos(ids: Set<String>, query: PhotoQuery) throws -> [Photo] {
        guard !ids.isEmpty else { return [] }
        let (predicate, args) = query.predicate, values = ids.sorted()
        return try database.read { db in
            var ordered = [(Int, Photo)]()
            for start in stride(from: 0, to: values.count, by: 500) {
                let chunk = Array(values[start..<min(values.count, start + 500)])
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM (SELECT photo.*, row_number() OVER (ORDER BY " + query.order + ") AS exportPosition FROM " + query.relation + " WHERE " + predicate + ") WHERE id IN (" + Array(repeating: "?", count: chunk.count).joined(separator: ",") + ")", arguments: args + StatementArguments(chunk))
                for row in rows { ordered.append((row["exportPosition"], try Photo(row: row))) }
            }
            guard ordered.count == ids.count else { throw LRCError(L10n.text("app.theSelectionIsNoLongerInTheCurrentCatalog", defaultValue: "The selection is no longer in the current catalog results. Refresh it before exporting")) }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
    func photoCount() throws -> Int { try database.read { try Photo.filter(Column("deleted") == false).fetchCount($0) } }
    func folderPaths() throws -> [String: [String]] {
        try database.read { db in
            var result: [String: Set<String>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT rootID, relativePath FROM photo") {
                let path: String = row["relativePath"], root: String = row["rootID"]
                let parts = path.split(separator: "/").dropLast()
                if !parts.isEmpty { result[root, default: []].insert(parts.joined(separator: "/")) }
            }
            return result.mapValues { $0.sorted() }
        }
    }
}
