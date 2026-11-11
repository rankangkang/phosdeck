import Foundation
import GRDB

/// Flat, catalog-wide groups of EDIT VERSIONS. First member is the persisted cover.
/// Ordering/merge/split/arrangement ported from LightCraft 4f0b110 stacks.rs (MIT).
/// See docs/references/lightcraft-LICENSE.txt. Persistence and query integration are native.
struct PhotoStack: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var members: [String]
    var collapsed = true
}
struct StackBadge: Equatable {
    var stackID: String
    var position: Int
    var count: Int
    var matching: Int
    var collapsed: Bool
    var text: String { matching == count ? String(count) : "\(matching)/\(count)" }
    var scopeNotice: String? {
        guard matching < count else { return nil }
        return L10n.text("app.stackMembersHiddenByScope", defaultValue: "Hidden by the current source or filters: \(count - matching)")
    }
    var description: String { [L10n.text("app.stackVersionMatchesInTheCurrentScope", defaultValue: "Stack version \(position + 1)/\(count), \(matching) matches in the current scope, \(collapsed ? L10n.text("app.collapsed", defaultValue: "Collapsed") : L10n.text("app.expanded", defaultValue: "Expanded"))"), scopeNotice].compactMap { $0 }.joined(separator: " · ") }
}
enum StackAction {
    case group(top: String, members: [String])
    case ungroup(Set<String>), remove(Set<String>)
    case move(String, Int), cover(String), split(String)
    case collapse(Set<String>, Bool) // stack IDs, explicit scope
}
struct StackChange {
    let previous: [PhotoStack]
    let current: [PhotoStack]
}
struct StackStateChanged: LocalizedError {
    var errorDescription: String? { L10n.text("app.theGroupingPreviewExpiredPreviewAgain", defaultValue: "The grouping preview expired. Preview again") }
}
struct AutoStackInput: Equatable {
    var id: String
    var name: String
    var rootID: String
    var captureDate: String?
    var stacked: Bool
}
struct AutoStackPreview {
    var inputs: [AutoStackInput]
    var groups: [[String]]
    var gap: Double
    var skippedTime: Int
    var skippedStacked: Int
    var photoCount: Int { groups.reduce(0) { $0 + $1.count } }
}

/// Strict full capture timestamp. Local clock values are arithmetic civil seconds,
/// NOT instants assigned the machine's time zone. Compare them only within one root.
/// Explicit offsets produce instants; never mix those with unknown-zone clocks.
struct CaptureTime: Equatable {
    var seconds: Double
    var hasOffset: Bool
    private static let pattern = try! NSRegularExpression(pattern: #"^(\d{4})[:-](\d{2})[:-](\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})?$"#)
    static func parse(_ value: String?) -> CaptureTime? {
        guard let value, let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), match.range == NSRange(value.startIndex...,in:value) else { return nil }
        func text(_ i: Int) -> String? { Range(match.range(at: i), in: value).map { String(value[$0]) } }
        guard let y = text(1), let m = text(2), let d = text(3), LibraryMetadataFilter.day("\(y)-\(m)-\(d)") != nil,
              let hour = Int(text(4) ?? ""), (0...23).contains(hour), let minute = Int(text(5) ?? ""), (0...59).contains(minute),
              let second = Int(text(6) ?? ""), (0...59).contains(second) else { return nil }
        let year = Int(y)!, month = Int(m)!, day = Int(d)!
        // Gregorian days-from-civil; includes leap-day validation above.
        let y2 = month <= 2 ? year - 1 : year, era = y2 / 400, yoe = y2 - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let days = era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + (153 * mp + 2) / 5 + day - 1 - 719468
        var seconds = Double(days * 86400 + hour * 3600 + minute * 60 + second) + (Double("0." + (text(7) ?? "0")) ?? 0)
        if let zone = text(8), zone != "Z" {
            let parts = zone.dropFirst().split(separator: ":")
            guard let h = Int(parts[0]), let m = Int(parts[1]), h <= 14, m <= 59, h < 14 || m == 0 else { return nil }
            seconds -= Double((h * 60 + m) * 60) * (zone.first == "-" ? -1 : 1)
        }
        return CaptureTime(seconds: seconds, hasOffset: text(8) != nil)
    }
}

extension CatalogStore {
    func stacks() throws -> [PhotoStack] { try database.read { try Self.readStacks($0) } }
    static func readStacks(_ db: Database) throws -> [PhotoStack] {
        let rows = try Row.fetchAll(db, sql: "SELECT s.id,s.collapsed,m.photoID FROM displayStack s JOIN stackMember m ON m.stackID=s.id ORDER BY s.id,m.position")
        var result = [PhotoStack]()
        for row in rows {
            let id: String = row["id"], member: String = row["photoID"]
            if result.last?.id == id { result[result.count - 1].members.append(member) }
            else { result.append(PhotoStack(id: id, members: [member], collapsed: row["collapsed"])) }
        }
        return result
    }
    /// All replacement writes are in the caller's one GRDB transaction.
    static func writeStacks(_ values: [PhotoStack], db: Database) throws {
        var seen = Set<String>(), stackIDs = Set<String>()
        for stack in values {
            guard stack.members.count >= 2, stackIDs.insert(stack.id).inserted else { throw LRCError(L10n.text("app.aStackNeedsAtLeastTwoValidDistinctVersions", defaultValue: "A stack needs at least two valid, distinct versions")) }
            for id in stack.members {
                guard seen.insert(id).inserted, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM photo WHERE id=? AND deleted=0)", arguments: [id]) == true else { throw LRCError(L10n.text("app.aStackMemberIsMissingRemovedDuplicatedOrBelongs", defaultValue: "A stack member is missing, removed, duplicated, or belongs to another stack")) }
            }
        }
        let old = try readStacks(db)
        let changed = Set(old.filter { !values.contains($0) }.map(\.id)).union(values.filter { !old.contains($0) }.map(\.id))
        for id in changed { try db.execute(sql: "DELETE FROM displayStack WHERE id=?", arguments: [id]) }
        for stack in values where changed.contains(stack.id) {
            try db.execute(sql: "INSERT INTO displayStack VALUES (?,?)", arguments: [stack.id, stack.collapsed])
            for (position, id) in stack.members.enumerated() { try db.execute(sql: "INSERT INTO stackMember VALUES (?,?,?)", arguments: [stack.id, id, position]) }
        }
    }
    @discardableResult func restoreStacks(_ values: [PhotoStack]) throws -> [PhotoStack] {
        try database.write { db in let old = try Self.readStacks(db); try Self.writeStacks(values, db: db); return old }
    }
    @discardableResult func changeStacks(_ action: StackAction) throws -> [PhotoStack] {
        try editStacks(action).previous
    }
    func editStacks(_ action: StackAction, expecting expected: [PhotoStack]? = nil) throws -> StackChange {
        try database.write { db in
            let old = try Self.readStacks(db)
            guard expected == nil || expected == old else { throw StackStateChanged() }
            var values = old
            switch action {
            case let .group(top, members):
                var seen = Set<String>(), order = [String]()
                for id in [top] + members where seen.insert(id).inserted { order.append(id) }
                let touched = order.compactMap { id in old.first { $0.members.contains(id) } }.reduce(into: [PhotoStack]()) { if !$0.contains($1) { $0.append($1) } }
                for s in touched { for id in s.members where seen.insert(id).inserted { order.append(id) } }
                guard order.count >= 2 else { throw LRCError(L10n.text("app.selectAtLeastTwoVersions", defaultValue: "Select at least two versions")) }
                values.removeAll { touched.contains($0) }
                values.append(PhotoStack(id: touched.first?.id ?? UUID().uuidString, members: order))
            case let .ungroup(ids): values.removeAll { !ids.isDisjoint(with: $0.members) }
            case let .remove(ids):
                for i in values.indices { values[i].members.removeAll { ids.contains($0) } }
                values.removeAll { $0.members.count < 2 }
            case let .collapse(ids, collapsed):
                for i in values.indices where ids.contains(values[i].id) { values[i].collapsed = collapsed }
            case let .move(id, delta):
                if let i = values.firstIndex(where: { $0.members.contains(id) }), let from = values[i].members.firstIndex(of: id) {
                    let to = max(0, min(values[i].members.count - 1, from + delta))
                    values[i].members.remove(at: from); values[i].members.insert(id, at: to)
                }
            case let .cover(id):
                if let i = values.firstIndex(where: { $0.members.contains(id) }) { values[i].members.removeAll { $0 == id }; values[i].members.insert(id, at: 0) }
            case let .split(id):
                guard let i = values.firstIndex(where: { $0.members.contains(id) }), let at = values[i].members.firstIndex(of: id), at > 0 else { throw LRCError(L10n.text("app.chooseAMemberAfterTheCoverAsTheSplit", defaultValue: "Choose a member after the cover as the split point")) }
                let tail = Array(values[i].members[at...]), collapsed = values[i].collapsed
                values[i].members = Array(values[i].members[..<at]); values.removeAll { $0.members.count < 2 }
                if tail.count >= 2 { values.append(PhotoStack(members: tail, collapsed: collapsed)) }
            }
            let next = values.sorted { $0.id < $1.id }
            if old != next { try Self.writeStacks(next, db: db) }
            return StackChange(previous: old, current: next)
        }
    }
    func stackInputs(query: PhotoQuery, ids: Set<String>? = nil) throws -> [AutoStackInput] {
        try database.read { try Self.stackInputs($0, query: query, ids: ids) }
    }
    private static func stackInputs(_ db: Database, query: PhotoQuery, ids: Set<String>?) throws -> [AutoStackInput] {
        let (predicate,args) = query.predicate
        return try Row.fetchAll(db, sql: "SELECT photo.id,photo.relativePath,photo.rootID,photo.captureDate,EXISTS(SELECT 1 FROM stackMember m WHERE m.photoID=photo.id) AS stacked FROM " + query.relation + " WHERE " + predicate + " ORDER BY " + query.order, arguments: args).compactMap { row in
            let id: String = row["id"]
            guard ids?.contains(id) ?? true else { return nil }
            return AutoStackInput(id: id, name: row["relativePath"], rootID: row["rootID"], captureDate: row["captureDate"], stacked: row["stacked"])
        }
    }
    static func previewAutoStacks(_ inputs: [AutoStackInput], gap: Double) throws -> AutoStackPreview {
        guard gap.isFinite, (0...86400).contains(gap) else { throw LRCError(L10n.text("app.theIntervalMustBe086400Seconds", defaultValue: "The interval must be 0–86400 seconds")) }
        var skippedTime = 0, skippedStacked = 0
        var timed = [(String, Double, String, String)]()
        for input in inputs {
            try Task.checkCancellation()
            if input.stacked { skippedStacked += 1; continue }
            guard let time = CaptureTime.parse(input.captureDate) else { skippedTime += 1; continue }
            timed.append((time.hasOffset ? "instant" : "local:" + input.rootID, time.seconds, input.name.precomposedStringWithCanonicalMapping.lowercased(), input.id))
        }
        timed.sort { a,b in a.0 != b.0 ? a.0 < b.0 : a.1 != b.1 ? a.1 < b.1 : a.2 != b.2 ? a.2 < b.2 : a.3 < b.3 }
        var groups = [[String]](), previous: (String, Double)?
        for (domain,time,_,id) in timed {
            if let p = previous, p.0 == domain, time - p.1 <= gap { groups[groups.count - 1].append(id) }
            else { groups.append([id]) }
            previous = (domain,time)
        }
        return AutoStackPreview(inputs: inputs, groups: groups.filter { $0.count >= 2 }, gap: gap, skippedTime: skippedTime, skippedStacked: skippedStacked)
    }
    @discardableResult func applyAutoStacks(_ preview: AutoStackPreview) throws -> [PhotoStack] {
        try saveAutoStacks(preview).previous
    }
    func saveAutoStacks(_ preview: AutoStackPreview, query: PhotoQuery? = nil, ids: Set<String>? = nil) throws -> StackChange {
        try database.write { db in
            if let query, try Self.stackInputs(db, query: query, ids: ids) != preview.inputs { throw StackStateChanged() }
            let old = try Self.readStacks(db), stacked = Set(old.flatMap(\.members))
            let inputs = Dictionary(uniqueKeysWithValues: preview.inputs.map { ($0.id,$0) })
            var seen = Set<String>()
            for id in preview.groups.flatMap({ $0 }) {
                guard seen.insert(id).inserted, !stacked.contains(id), let expected = inputs[id],
                      let row = try Row.fetchOne(db, sql: "SELECT rootID,relativePath,captureDate FROM photo WHERE id=? AND deleted=0", arguments: [id]),
                      expected.rootID == row["rootID"], expected.name == row["relativePath"], expected.captureDate == row["captureDate"] else { throw StackStateChanged() }
            }
            guard try Self.previewAutoStacks(preview.inputs, gap: preview.gap).groups == preview.groups else { throw LRCError(L10n.text("app.invalidGroupingPreview", defaultValue: "Invalid grouping preview")) }
            let next = (old + preview.groups.map { PhotoStack(members: $0) }).sorted { $0.id < $1.id }
            if old != next { try Self.writeStacks(next, db: db) }
            return StackChange(previous: old, current: next)
        }
    }
}
