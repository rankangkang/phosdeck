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
        guard let text else { return nil }
        let utf8 = text.utf8
        guard utf8.count >= 10 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(10)
        var iter = utf8.makeIterator()
        for _ in 0..<10 {
            guard let b = iter.next() else { return nil }
            bytes.append(b)
        }
        // Positions 4 and 7 must be '-' (45) or ':' (58); all others ASCII digits.
        guard (bytes[4] == 45 || bytes[4] == 58), (bytes[7] == 45 || bytes[7] == 58) else { return nil }
        func digit(_ b: UInt8) -> Int? { (48...57).contains(b) ? Int(b - 48) : nil }
        guard let y0 = digit(bytes[0]), let y1 = digit(bytes[1]), let y2 = digit(bytes[2]), let y3 = digit(bytes[3]),
              let m0 = digit(bytes[5]), let m1 = digit(bytes[6]),
              let d0 = digit(bytes[8]), let d1 = digit(bytes[9]) else { return nil }
        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        let month = m0 * 10 + m1
        let day = d0 * 10 + d1
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let maxDay: Int
        switch month {
        case 2: maxDay = leap ? 29 : 28
        case 4, 6, 9, 11: maxDay = 30
        default: maxDay = 31
        }
        guard day <= maxDay else { return nil }
        bytes[4] = 45
        bytes[7] = 45
        return String(decoding: bytes, as: UTF8.self)
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
    var useRelatedSnapshotOrder = true
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
        var base = snapshotID == nil
            ? "photo JOIN temp.photoIndex AS idx ON idx.photoID=photo.id"
            : "photo JOIN temp.photoIndex AS idx ON idx.photoID=photo.id JOIN temp.browseSnapshot AS held ON photo.id=held.photoID"
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
        if useRelatedSnapshotOrder, smart == nil, scope.hasPrefix("related:") { return "related.position" }
        let direction = descending ? " DESC" : " ASC"
        let primary: String
        switch sort {
        case .filename: primary = "idx.filenameKey COLLATE BINARY" + direction
        case .captureDate: primary = "(idx.captureDay IS NULL) ASC, idx.captureDay" + direction + ", idx.captureSub" + direction
        case .rating: primary = "photo.rating" + direction
        }
        if isManualCollectionOrder { return "membership.rowid ASC, photo.relativePath COLLATE BINARY ASC, photo.id ASC" }
        return primary + ", photo.relativePath COLLATE BINARY ASC, photo.id ASC"
    }
    // Query arguments remain bound, including LIKE metacharacters in literal user input.
    var predicate: (String, StatementArguments) {
        // Hold metadata/filter membership and order, but still require that a
        // photo exists in the source shown. Mirrors Session::visible's `within`
        // constraint (LightCraft 4f0b110), without its dynamic admission of matches.
        if invalidSmart { return ("0", []) }
        let (source, sourceArgs) = sourcePredicate
        if let snapshotID { return ("photo.deleted=0 AND held.snapshotID=? AND (" + source + ")", [snapshotID] + sourceArgs) }
        var sql = ["photo.deleted=0", "photo.rating \(ratingComparison.sqlSymbol) ?"], values: [DatabaseValueConvertible] = [ratingThreshold]
        if metadata.validationMessage != nil { sql.append("0") }
        if !metadata.camera.isEmpty { sql.append("photo.camera LIKE ? ESCAPE '\\' COLLATE NOCASE"); values.append("%" + Self.escape(metadata.camera) + "%") }
        if !metadata.lens.isEmpty { sql.append("idx.lens LIKE ? ESCAPE '\\' COLLATE NOCASE"); values.append("%" + Self.escape(metadata.lens) + "%") }
        if let value = Int(metadata.minimumISO) { sql.append("idx.iso >= ?"); values.append(value) }
        if let value = Int(metadata.maximumISO) { sql.append("idx.iso <= ?"); values.append(value) }
        if !metadata.dateFrom.isEmpty { sql.append("idx.captureDay >= ?"); values.append(metadata.dateFrom) }
        if !metadata.dateThrough.isEmpty { sql.append("idx.captureDay <= ?"); values.append(metadata.dateThrough) }
        if !flags.isEmpty {
            let selected = flags.sorted()
            sql.append("photo.flag IN (" + selected.map { _ in "?" }.joined(separator: ",") + ")")
            values.append(contentsOf: selected)
        }
        if !colorLabels.isEmpty {
            let selected = colorLabels.sorted()
            sql.append("photo.colorLabel IN (" + selected.map { _ in "?" }.joined(separator: ",") + ")")
            values.append(contentsOf: selected)
        }
        if !keyword.isEmpty {
            sql.append("photo.id IN (SELECT photoID FROM photoKeyword WHERE keyword = ?)")
            values.append(KeywordSummary.key(keyword))
        }
        if !search.isEmpty { sql.append("idx.filename LIKE ? ESCAPE '\\' COLLATE NOCASE"); values.append("%" + Self.escape(search) + "%") }
        let (rules, ruleArgs) = smart?.sql ?? ("1", StatementArguments())
        return ((sql + [source, rules]).joined(separator: " AND "), StatementArguments(values) + sourceArgs + ruleArgs)
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
                return ("photo.rootID = ? AND photo.relativePath LIKE ? ESCAPE '\\'", [parts[1], Self.escape(parts[2]) + "/%"])
            }
            return ("0", [])
        } else if scope != "all" { return ("photo.rootID = ?", [scope]) }
        return ("1", [])
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

struct PhotoPage {
    var order: CachedQueryOrder? = nil
    var photos: [Photo]
    var total: Int
    var offset: Int
    var visibleTotal: Int = 0
    var badges: [String: StackBadge] = [:]
}

struct CachedVisibleRow {
    let photoID: String
    let stackID: String?
    let position: Int?
    let collapsed: Bool
    let matching: Int
    let stackCount: Int
}

final class CachedQueryOrder {
    let query: PhotoQuery
    let includeCollapsed: Bool
    let revision: UInt64
    let snapshotGeneration: UInt64
    let total: Int
    let visibleTotal: Int
    let rows: [CachedVisibleRow]
    let indexByID: [String: Int]
    let hiddenToRepresentativeIndex: [String: Int]

    init(query: PhotoQuery, includeCollapsed: Bool, revision: UInt64, snapshotGeneration: UInt64,
         total: Int, visibleTotal: Int, rows: [CachedVisibleRow],
         hiddenToRepresentativeIndex: [String: Int]) {
        self.query = query
        self.includeCollapsed = includeCollapsed
        self.revision = revision
        self.snapshotGeneration = snapshotGeneration
        self.total = total
        self.visibleTotal = visibleTotal
        self.rows = rows
        var map = [String: Int](minimumCapacity: rows.count)
        for (index, row) in rows.enumerated() { map[row.photoID] = index }
        self.indexByID = map
        self.hiddenToRepresentativeIndex = hiddenToRepresentativeIndex
    }
}

extension CatalogStore {
    // Arrange the WHOLE base result before LIMIT/OFFSET. Only IDs/ranks enter
    // the windows; recipes/metadata are fetched for the displayed page alone.
    private static func stackCTE(_ query: PhotoQuery) -> String {
        let (predicate, _) = query.predicate
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

    private static func computeOrder(_ query: PhotoQuery, in db: Database, includeCollapsed: Bool,
                                     revision: UInt64, snapshotGeneration: UInt64) throws -> CachedQueryOrder {
        let (predicate, args) = query.predicate
        let hasStacks = try Int.fetchOne(db, sql: "SELECT 1 FROM displayStack LIMIT 1") != nil
        if !hasStacks {
            let ids = try String.fetchAll(db, sql: "SELECT photo.id FROM \(query.relation) WHERE \(predicate) ORDER BY \(query.order)", arguments: args)
            let rows = ids.map { CachedVisibleRow(photoID: $0, stackID: nil, position: nil, collapsed: false, matching: 0, stackCount: 0) }
            return CachedQueryOrder(query: query, includeCollapsed: includeCollapsed, revision: revision, snapshotGeneration: snapshotGeneration,
                                    total: ids.count, visibleTotal: ids.count, rows: rows, hiddenToRepresentativeIndex: [:])
        }

        // Single-pass ordered fetch + linear O(N) stack grouping/collapsing in Swift,
        // preserving exact equivalence with stackCTE without SQLite's triple window sort.
        var stackCounts = [String: Int]()
        let countCursor = try Row.fetchCursor(db, sql: "SELECT stackID, count(*) AS c FROM stackMember GROUP BY stackID")
        while let row = try countCursor.next() {
            stackCounts[row["stackID"] as String] = row["c"] as Int
        }

        struct BaseMember {
            let photoID: String
            let stackID: String?
            let position: Int?
            let collapsed: Bool
        }
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT photo.id, m.stackID, m.position, s.collapsed
            FROM \(query.relation)
            LEFT JOIN stackMember m ON m.photoID=photo.id
            LEFT JOIN displayStack s ON s.id=m.stackID
            WHERE \(predicate)
            ORDER BY \(query.order)
            """, arguments: args)
        var base = [BaseMember]()
        var grouped = [String: [BaseMember]]()
        while let row = try cursor.next() {
            let member = BaseMember(
                photoID: row["id"],
                stackID: row["stackID"],
                position: row["position"],
                collapsed: (row["collapsed"] as Int? ?? 0) != 0
            )
            base.append(member)
            if let sid = member.stackID {
                grouped[sid, default: []].append(member)
            }
        }
        let total = base.count
        for (sid, members) in grouped where members.count > 1 {
            grouped[sid] = members.sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        }

        let relatedScope = query.scope.hasPrefix("related:")
        if includeCollapsed {
            var rows = [CachedVisibleRow]()
            rows.reserveCapacity(total)
            var visibleCount = 0
            for item in base {
                if let sid = item.stackID, let group = grouped[sid] {
                    let matching = group.count
                    let firstPos = group[0].position ?? 0
                    if relatedScope || !item.collapsed || (item.position ?? 0) == firstPos { visibleCount += 1 }
                    rows.append(CachedVisibleRow(photoID: item.photoID, stackID: sid, position: item.position,
                                                 collapsed: item.collapsed, matching: matching,
                                                 stackCount: stackCounts[sid] ?? matching))
                } else {
                    visibleCount += 1
                    rows.append(CachedVisibleRow(photoID: item.photoID, stackID: nil, position: nil, collapsed: false, matching: 0, stackCount: 0))
                }
            }
            return CachedQueryOrder(query: query, includeCollapsed: true, revision: revision, snapshotGeneration: snapshotGeneration,
                                    total: total, visibleTotal: visibleCount, rows: rows, hiddenToRepresentativeIndex: [:])
        }

        if relatedScope {
            var rows = [CachedVisibleRow]()
            rows.reserveCapacity(total)
            for item in base {
                if let sid = item.stackID, let group = grouped[sid] {
                    let matching = group.count
                    rows.append(CachedVisibleRow(photoID: item.photoID, stackID: sid, position: item.position,
                                                 collapsed: item.collapsed, matching: matching,
                                                 stackCount: stackCounts[sid] ?? matching))
                } else {
                    rows.append(CachedVisibleRow(photoID: item.photoID, stackID: nil, position: nil, collapsed: false, matching: 0, stackCount: 0))
                }
            }
            return CachedQueryOrder(query: query, includeCollapsed: false, revision: revision, snapshotGeneration: snapshotGeneration,
                                    total: total, visibleTotal: total, rows: rows, hiddenToRepresentativeIndex: [:])
        }

        var rows = [CachedVisibleRow]()
        rows.reserveCapacity(total)
        var emittedStacks = Set<String>()
        var hiddenToRep = [String: Int]()
        for item in base {
            guard let sid = item.stackID else {
                rows.append(CachedVisibleRow(photoID: item.photoID, stackID: nil, position: nil, collapsed: false, matching: 0, stackCount: 0))
                continue
            }
            guard emittedStacks.insert(sid).inserted, let group = grouped[sid] else { continue }
            let matching = group.count
            let count = stackCounts[sid] ?? matching
            if item.collapsed {
                let repIndex = rows.count
                let rep = group[0]
                rows.append(CachedVisibleRow(photoID: rep.photoID, stackID: sid, position: rep.position,
                                             collapsed: true, matching: matching, stackCount: count))
                for hidden in group.dropFirst() {
                    hiddenToRep[hidden.photoID] = repIndex
                }
            } else {
                for member in group {
                    rows.append(CachedVisibleRow(photoID: member.photoID, stackID: sid, position: member.position,
                                                 collapsed: false, matching: matching, stackCount: count))
                }
            }
        }
        return CachedQueryOrder(query: query, includeCollapsed: false, revision: revision, snapshotGeneration: snapshotGeneration,
                                total: total, visibleTotal: rows.count, rows: rows, hiddenToRepresentativeIndex: hiddenToRep)
    }

    private func cachedOrder(_ query: PhotoQuery, in db: Database, includeCollapsed: Bool) throws -> CachedQueryOrder {
        let rev = browseRevision
        let snap = snapshotGeneration
        if let hit = queryCache.first(where: {
            $0.revision == rev && $0.snapshotGeneration == snap && $0.includeCollapsed == includeCollapsed && $0.query == query
        }) {
            return hit
        }
        let order = try Self.computeOrder(query, in: db, includeCollapsed: includeCollapsed, revision: rev, snapshotGeneration: snap)
        queryCache.removeAll { $0.revision != rev || $0.snapshotGeneration != snap }
        queryCache.append(order)
        if queryCache.count > 2 { queryCache.removeFirst(queryCache.count - 2) }
        return order
    }

    private static func materializePage(from order: CachedQueryOrder, in db: Database, offset: Int, limit: Int) throws -> PhotoPage {
        let size = max(1, min(1000, limit))
        let length = order.rows.count
        let start = min(max(0, offset), max(0, ((length - 1) / size) * size))
        let end = min(length, start + size)
        guard start < end else {
            return PhotoPage(order: order, photos: [], total: order.total, offset: start, visibleTotal: order.visibleTotal, badges: [:])
        }
        let slice = order.rows[start..<end]
        let ids = slice.map(\.photoID)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let fetched = try Photo.fetchAll(db, sql: "SELECT * FROM photo WHERE id IN (\(placeholders))", arguments: StatementArguments(ids))
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        var photos = [Photo]()
        photos.reserveCapacity(ids.count)
        var badges = [String: StackBadge]()
        for item in slice {
            if let photo = byID[item.photoID] {
                photos.append(photo)
                if let sid = item.stackID, let pos = item.position {
                    badges[item.photoID] = StackBadge(stackID: sid, position: pos, count: item.stackCount,
                                                      matching: item.matching, collapsed: item.collapsed)
                }
            }
        }
        return PhotoPage(order: order, photos: photos, total: order.total, offset: start, visibleTotal: order.visibleTotal, badges: badges)
    }

    func page(_ query: PhotoQuery, offset: Int, limit: Int = 200) throws -> PhotoPage {
        try database.read { db in
            let order = try cachedOrder(query, in: db, includeCollapsed: false)
            return try Self.materializePage(from: order, in: db, offset: offset, limit: limit)
        }
    }

    static func page(_ query: PhotoQuery, in db: Database, offset: Int, limit: Int,
                     includeCollapsed: Bool = false) throws -> PhotoPage {
        let order = try computeOrder(query, in: db, includeCollapsed: includeCollapsed, revision: 0, snapshotGeneration: 0)
        return try materializePage(from: order, in: db, offset: offset, limit: limit)
    }

    func offset(of id: String, query: PhotoQuery, includingRepresentative: Bool = false) throws -> Int? {
        try database.read { db in
            let order = try cachedOrder(query, in: db, includeCollapsed: false)
            if let index = order.indexByID[id] { return index }
            if includingRepresentative { return order.hiddenToRepresentativeIndex[id] }
            return nil
        }
    }

    func representative(of id: String, query: PhotoQuery) throws -> String? {
        try database.read { db in
            let order = try cachedOrder(query, in: db, includeCollapsed: false)
            if order.indexByID[id] != nil { return id }
            if let repIndex = order.hiddenToRepresentativeIndex[id], order.rows.indices.contains(repIndex) {
                return order.rows[repIndex].photoID
            }
            return nil
        }
    }

    func allResultIDs(_ query: PhotoQuery, visibleOnly: Bool = false) throws -> [String] {
        try database.read { db in
            if visibleOnly {
                return try cachedOrder(query, in: db, includeCollapsed: false).rows.map(\.photoID)
            }
            let (predicate, args) = query.predicate
            return try String.fetchAll(db, sql: "SELECT photo.id FROM " + query.relation + " WHERE " + predicate + " ORDER BY " + query.order, arguments: args)
        }
    }

    func comparisonStacks(_ query: PhotoQuery) throws -> [PhotoStack] {
        let (_, args) = query.predicate
        return try database.read { db in
            let rows = try Row.fetchCursor(db, sql: Self.stackCTE(query) + """
                SELECT stackID, id, collapsed FROM ranked
                WHERE stackID IS NOT NULL AND matching >= 2
                ORDER BY groupPosition, position
                """, arguments: args)
            var stacks = [PhotoStack]()
            while let row = try rows.next() {
                let stackID: String = row["stackID"], id: String = row["id"]
                if stacks.last?.id == stackID { stacks[stacks.count - 1].members.append(id) }
                else { stacks.append(PhotoStack(id: stackID, members: [id], collapsed: row["collapsed"])) }
            }
            return stacks
        }
    }

    func liveComparisonMembers(of stack: PhotoStack) throws -> [String] {
        let admitted = Set(stack.members)
        return try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.photoID FROM stackMember m JOIN photo p ON p.id=m.photoID
                WHERE m.stackID=? AND p.deleted=0 ORDER BY m.position
                """, arguments: [stack.id]).filter { admitted.contains($0) }
        }
    }

    static func resultIDs(_ db: Database, query: PhotoQuery, within ids: [String]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let (predicate, args) = query.predicate
        // One JSON parameter also supports selections larger than the SQLite bind limit.
        let requested = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
        return try String.fetchAll(db, sql: "SELECT photo.id FROM " + query.relation + " WHERE " + predicate
            + " AND photo.id IN (SELECT value FROM json_each(?)) ORDER BY " + query.order, arguments: args + [requested])
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
            snapshotGeneration &+= 1
            queryCache.removeAll()
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
            snapshotGeneration &+= 1
            queryCache.removeAll()
        }
        return id
    }

    func releaseResults(_ id: String) throws {
        try database.write {
            try $0.execute(sql: "DELETE FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [id])
            snapshotGeneration &+= 1
            queryCache.removeAll()
        }
    }

    func resultIDs(_ query: PhotoQuery, within ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let (predicate, args) = query.predicate
        return try database.read { db in
            let encoded = String(decoding: try JSONEncoder().encode(Array(ids)), as: UTF8.self)
            return Set(try String.fetchAll(db, sql: "SELECT photo.id FROM " + query.relation + " WHERE " + predicate
                + " AND photo.id IN (SELECT value FROM json_each(?))", arguments: args + [encoded]))
        }
    }

    func firstResult(_ query: PhotoQuery, within ids: Set<String>) throws -> Photo? {
        guard !ids.isEmpty else { return nil }
        let (predicate, args) = query.predicate
        return try database.read { db in
            let encoded = String(decoding: try JSONEncoder().encode(Array(ids)), as: UTF8.self)
            return try Photo.fetchOne(db, sql: "SELECT photo.* FROM " + query.relation + " WHERE " + predicate
                + " AND photo.id IN (SELECT value FROM json_each(?)) ORDER BY " + query.order + " LIMIT 1",
                                      arguments: args + [encoded])
        }
    }

    /// One transaction, all SQL matches across every page. A held query uses its frozen members.
    @discardableResult func collectResults(_ query: PhotoQuery, collection: String, newName: String? = nil) throws -> Int {
        let (predicate, args) = query.predicate
        return try database.write { db in
            if let newName { try PhotoCollection(id: collection, name: newName.trimmingCharacters(in: .whitespacesAndNewlines)).insert(db) }
            try requireManualCollection(db, id: collection)
            // Explicitly preserve the current query order when appending to a
            // manual collection. SQLite does not promise row order for a bare
            // INSERT…SELECT, and rowid is the collection's persisted order.
            try db.execute(sql: "INSERT OR IGNORE INTO membership SELECT ?, photo.id FROM " + query.relation + " WHERE " + predicate + " ORDER BY " + query.order, arguments: [collection] + args)
            return db.changesCount
        }
    }

    func photo(_ id: String) throws -> Photo? { try database.read { try Photo.fetchOne($0, sql: "SELECT * FROM photo WHERE id=? AND deleted=0", arguments: [id]) } }

    func matchesPhotoRevisions(id: String, source: Int, recipe: Int, requiringAvailable: Bool = true) throws -> Bool {
        try database.read {
            try Int.fetchOne($0, sql: "SELECT 1 FROM photo WHERE id=? AND deleted=0 AND revision=? AND recipeRevision=? AND (?=0 OR availability='available')",
                             arguments: [id, source, recipe, requiringAvailable]) != nil
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
        let (predicate, args) = query.predicate
        return try database.read { db in
            let encoded = String(decoding: try JSONEncoder().encode(Array(ids)), as: UTF8.self)
            let photos = try Photo.fetchAll(db, sql: """
                SELECT photo.* FROM \(query.relation)
                WHERE \(predicate) AND photo.id IN (SELECT value FROM json_each(?))
                ORDER BY \(query.order)
                """, arguments: args + [encoded])
            guard photos.count == ids.count else {
                throw LRCError(L10n.text("app.theSelectionIsNoLongerInTheCurrentCatalog", defaultValue: "The selection is no longer in the current catalog results. Refresh it before exporting"))
            }
            return photos
        }
    }

    func photoCount() throws -> Int { try database.read { try Photo.filter(Column("deleted") == false).fetchCount($0) } }

    func folderPaths() throws -> [String: [String]] {
        try database.read { db in
            let rev = browseRevision
            if let cached = folderPathsCache, cached.revision == rev { return cached.paths }
            var result: [String: Set<String>] = [:]
            let cursor = try Row.fetchCursor(db, sql: "SELECT rootID, relativePath FROM photo")
            while let row = try cursor.next() {
                let path: String = row["relativePath"], root: String = row["rootID"]
                if let slash = path.lastIndex(of: "/") {
                    let dir = String(path[..<slash])
                    if !dir.isEmpty { result[root, default: []].insert(dir) }
                }
            }
            let sorted = result.mapValues { $0.sorted() }
            folderPathsCache = (rev, sorted)
            return sorted
        }
    }
}
