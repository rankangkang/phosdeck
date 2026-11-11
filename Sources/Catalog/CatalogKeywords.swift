import Foundation
import GRDB

struct KeywordSummary: FetchableRecord, Decodable, Identifiable, Equatable {
    var keyword: String
    var name: String
    var total: Int
    var selected: Int
    var id: String { keyword }

    static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    /// Commas separate terms; validate the entire draft before any database write.
    static func terms(_ input: String) throws -> [String] {
        let parts = input.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty, parts.count <= 64 else { throw LRCError(L10n.text("app.enterKeywordsAddUpTo64AtOnce", defaultValue: "Enter keywords; add up to 64 at once")) }
        var seen: Set<String> = []
        return try parts.map { try name($0) }.filter { seen.insert(key($0)).inserted }
    }
    static func name(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...100).contains(name.count), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw LRCError(L10n.text("app.keywordsMustContain1100CharactersWithoutLineBreaks", defaultValue: "Keywords must contain 1–100 characters without line breaks or control characters"))
        }
        return name
    }
}

/// All associations of one flat keyword, including retained/deleted versions.
/// Keep each original spelling so one undo can restore the exact affected rows.
struct KeywordNameState: Equatable {
    let key: String
    let names: [String: String]
    var name: String { names.values.min() ?? key }
}

extension CatalogStore {
    func keywordNameState(_ key: String) throws -> KeywordNameState {
        try database.read { try Self.keywordNameState($0, key: KeywordSummary.key(key)) }
    }
    private static func keywordNameState(_ db: Database, key: String) throws -> KeywordNameState {
        let rows = try Row.fetchAll(db, sql: "SELECT photoID,name FROM photoKeyword WHERE keyword=?", arguments: [key])
        return KeywordNameState(key: key, names: Dictionary(uniqueKeysWithValues: rows.map { ($0["photoID"] as String, $0["name"] as String) }))
    }
    /// Whole-library transaction, independent of selection, filters and pages.
    /// lightcraft 4f0b110 keywords.rs/commit_keywords guides scope and undo only;
    /// native flat names reject collisions rather than merging hierarchies.
    func renameKeyword(_ expected: KeywordNameState, to value: String) throws -> KeywordNameState {
        let name = try KeywordSummary.name(value)
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: ",，;；")) == nil else { throw LRCError(L10n.text("app.enterOneKeywordToRenameWithoutSeparators", defaultValue: "Enter one keyword to rename, without separators")) }
        let replacement = KeywordNameState(key: KeywordSummary.key(name), names: expected.names.mapValues { _ in name })
        try restoreKeywordName(from: expected, to: replacement)
        return replacement
    }
    func restoreKeywordName(from expected: KeywordNameState, to replacement: KeywordNameState) throws {
        guard !expected.names.isEmpty, Set(expected.names.keys) == Set(replacement.names.keys) else { throw LRCError(L10n.text("app.keywordAssociationsChangedReopenRename", defaultValue: "Keyword associations changed. Reopen Rename")) }
        for name in replacement.names.values {
            guard try KeywordSummary.key(KeywordSummary.name(name)) == replacement.key else { throw LRCError(L10n.text("app.theKeywordNameDoesNotMatchItsIdentifier", defaultValue: "The keyword name does not match its identifier")) }
        }
        try database.write { db in
            guard try Self.keywordNameState(db, key: expected.key) == expected else { throw LRCError(L10n.text("app.keywordAssociationsChangedReopenRename", defaultValue: "Keyword associations changed. Reopen Rename")) }
            if replacement.key != expected.key {
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM photoKeyword WHERE keyword=?", arguments: [replacement.key]) == 0 else {
                    throw LRCError(L10n.text("app.thisKeywordAlreadyExistsInTheCatalogChooseAnother", defaultValue: "This keyword already exists in the catalog. Choose another name"))
                }
            }
            for (id, name) in replacement.names {
                try db.execute(sql: "UPDATE photoKeyword SET keyword=?,name=? WHERE photoID=? AND keyword=?",
                               arguments: [replacement.key, name, id, expected.key])
            }
        }
    }

    func keywordSummary(selected ids: Set<String>) throws -> [KeywordSummary] {
        try database.read { try Self.keywordSummary($0, selected: ids) }
    }
    func keywordBrowser(selected ids: Set<String>, photoID: String?) throws -> (keywords: [KeywordSummary], terms: [String]?, caption: String?) {
        try database.read { db in
            let summary = try Self.keywordSummary(db, selected: ids)
            guard let photoID else { return (summary, nil, nil) }
            guard let caption = try String.fetchOne(db, sql: "SELECT caption FROM photo WHERE id=? AND deleted=0", arguments: [photoID]) else {
                throw OrganizationError.photoUnavailable
            }
            let terms = try Self.keywordState(db, ids: [photoID])[photoID]
            return (summary, terms, caption)
        }
    }
    private static func keywordSummary(_ db: Database, selected ids: Set<String>) throws -> [KeywordSummary] {
        // ponytail: aggregate on selection changes; cache totals if large keyword catalogs make this slow.
        let marks = ids.isEmpty ? "NULL" : ids.map { _ in "?" }.joined(separator: ",")
        return try KeywordSummary.fetchAll(db, sql: """
            SELECT keyword, min(name) AS name, count(*) AS total,
                   sum(CASE WHEN photoID IN (\(marks)) THEN 1 ELSE 0 END) AS selected
            FROM photoKeyword WHERE photoID IN (SELECT id FROM photo WHERE deleted=0) GROUP BY keyword ORDER BY keyword
            """, arguments: StatementArguments(ids))
    }

    func photoKeywords(ids: Set<String>) throws -> [String: [String]] {
        try database.read { try Self.keywordState($0, ids: ids) }
    }

    private static func keywordState(_ db: Database, ids: Set<String>, includeRemoved: Bool = false) throws -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        let marks = ids.map { _ in "?" }.joined(separator: ","), args = StatementArguments(ids)
        let live = includeRemoved ? "" : " AND deleted=0"
        let found = try String.fetchAll(db, sql: "SELECT id FROM photo WHERE id IN (\(marks))" + live, arguments: args)
        guard Set(found) == ids else { throw LRCError(L10n.text("app.thePhotoSelectionChangedKeywordsWereNotSaved", defaultValue: "The photo selection changed. Keywords were not saved")) }
        var result = Dictionary(uniqueKeysWithValues: found.map { ($0, [String]()) })
        for row in try Row.fetchAll(db, sql: "SELECT photoID,name FROM photoKeyword WHERE photoID IN (\(marks)) ORDER BY keyword", arguments: args) {
            let id: String = row["photoID"], name: String = row["name"]
            result[id, default: []].append(name)
        }
        return result
    }

    /// Return only changed photos, including empty keyword lists, for a precise batch undo.
    func changeKeyword(_ value: String, ids: Set<String>, adding: Bool) throws -> [String: [String]] {
        try changeKeywords([value], ids: ids, adding: adding)
    }

    func changeKeywords(_ values: [String], ids: Set<String>, adding: Bool) throws -> [String: [String]] {
        guard !values.isEmpty, values.count <= 64 else { throw LRCError(L10n.text("app.enter164KeywordsAtATime", defaultValue: "Enter 1–64 keywords at a time")) }
        var seen: Set<String> = []
        let terms = try values.map { try KeywordSummary.name($0) }.filter { seen.insert(KeywordSummary.key($0)).inserted }
        return try database.write { db in
            let previous = try Self.keywordState(db, ids: ids)
            var changed = [String: [String]]()
            for name in terms {
                let key = KeywordSummary.key(name)
                let spelling = try String.fetchOne(db, sql: "SELECT min(name) FROM photoKeyword WHERE keyword=?", arguments: [key]) ?? name
                for (id, keywords) in previous {
                    let exists = keywords.contains { KeywordSummary.key($0) == key }
                    guard exists != adding else { continue }
                    if adding {
                        try db.execute(sql: "INSERT INTO photoKeyword (photoID,keyword,name) VALUES (?,?,?)", arguments: [id, key, spelling])
                    } else {
                        try db.execute(sql: "DELETE FROM photoKeyword WHERE photoID=? AND keyword=?", arguments: [id, key])
                    }
                    changed[id] = keywords
                }
            }
            return changed
        }
    }

    func restoreKeywords(_ states: [String: [String]]) throws -> [String: [String]] {
        try database.write { db in
            let inverse = try Self.keywordState(db, ids: Set(states.keys), includeRemoved: true)
            for (id, keywords) in states {
                try db.execute(sql: "DELETE FROM photoKeyword WHERE photoID=?", arguments: [id])
                for value in keywords {
                    let name = try KeywordSummary.name(value)
                    try db.execute(sql: "INSERT INTO photoKeyword (photoID,keyword,name) VALUES (?,?,?)", arguments: [id, KeywordSummary.key(name), name])
                }
            }
            return inverse
        }
    }
}


/// Empty means deliberately cleared; no EXIF/XMP input is imported into this field.
enum PhotoCaption {
    static func normalized(_ value: String) throws -> String {
        let text = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        guard text.count <= 2000, text.utf8.count <= 16000,
              text.unicodeScalars.allSatisfy({ $0.value == 10 || $0.value == 9 || (!CharacterSet.controlCharacters.contains($0) && $0.value != 0xFFFE && $0.value != 0xFFFF) })
        else { throw LRCError(L10n.text("app.captionsSupportUpTo2000CharactersAndLineBreaks", defaultValue: "Captions support up to 2000 characters and line breaks, without other control characters")) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }
}

struct PhotoCaptionConflict: Error {
    let id: String
    let actual: String
}

extension CatalogStore {
    func captions(ids: Set<String>) throws -> [String: String] {
        try database.read { db in
            var result = [String: String]()
            for id in ids {
                guard let photo = try Photo.fetchOne(db, key: id), !photo.deleted else { throw LRCError(L10n.text("app.thePhotoSelectionChangedTheCaptionWasNotSaved", defaultValue: "The photo selection changed. The caption was not saved")) }
                result[id] = photo.caption
            }
            return result
        }
    }
    /// Validate the whole batch before writing, returning only changed versions for one undo.
    func setCaptions(_ values: [String: String], expecting: [String: String]? = nil) throws -> [String: String] {
        let normalized = try values.mapValues { try PhotoCaption.normalized($0) }
        return try database.write { db in
            var old = [String: String]()
            for (id, value) in normalized {
                guard let photo = try Photo.fetchOne(db, key: id), !photo.deleted else { throw LRCError(L10n.text("app.thePhotoSelectionChangedTheCaptionWasNotSaved", defaultValue: "The photo selection changed. The caption was not saved")) }
                if let expecting, expecting[id] != photo.caption { throw PhotoCaptionConflict(id: id, actual: photo.caption) }
                if photo.caption != value { old[id] = photo.caption }
            }
            for id in old.keys { try db.execute(sql: "UPDATE photo SET caption=? WHERE id=?", arguments: [normalized[id]!, id]) }
            return old
        }
    }
    func exportDescriptions(ids: Set<String>) throws -> [String: ExportDescription] {
        try database.read { db in
            var result = [String: ExportDescription]()
            for id in ids {
                guard let photo = try Photo.fetchOne(db, key: id), !photo.deleted else { throw LRCError(L10n.text("app.thePhotoSelectionChangedOrganizationMetadataWasNotFrozen", defaultValue: "The photo selection changed. Organization metadata was not frozen")) }
                let keywords = try String.fetchAll(db, sql: "SELECT name FROM photoKeyword WHERE photoID=? ORDER BY keyword", arguments: [id])
                let value = ExportDescription(caption: photo.caption, keywords: keywords)
                try value.validate()
                result[id] = value
            }
            return result
        }
    }
}
