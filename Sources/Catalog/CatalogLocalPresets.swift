import Foundation
import GRDB

extension CatalogStore {
    /// Named local parameter presets belong to the current catalog, just like
    /// global adjustment presets.  Ordering is deterministic for the menu and
    /// survives backup/restore through SQLite's normal backup path.
    func localParameterPresets() throws -> [LocalParameterPreset] {
        try database.read { db in
            try LocalParameterPreset.order(Column("name"), Column("id")).fetchAll(db)
        }
    }

    func localParameterPreset(_ id: String) throws -> LocalParameterPreset? {
        try database.read { try LocalParameterPreset.fetchOne($0, key: id) }
    }

    @discardableResult
    func saveLocalParameterPreset(name: String, values: LocalParameterValues) throws -> LocalParameterPreset {
        let preset = try LocalParameterPreset(name: name, values: values)
        try database.write { db in
            try preset.insert(db)
        }
        return preset
    }

    func renameLocalParameterPreset(id: String, name: String, expecting: LocalParameterPreset? = nil) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else {
            throw LRCError(L10n.text("app.localPresetNamesMustContain1100Characters", defaultValue: "Local preset names must contain 1–100 characters"))
        }
        try database.write { db in
            if let expecting, try LocalParameterPreset.fetchOne(db, key: id) != expecting { throw OrganizationError.versionConflict }
            try db.execute(sql: "UPDATE localParameterPreset SET name=? WHERE id=?", arguments: [trimmed, id])
            guard db.changesCount == 1 else { throw LRCError(L10n.text("app.theLocalPresetDoesNotExist", defaultValue: "The local preset does not exist")) }
        }
    }

    @discardableResult
    func deleteLocalParameterPreset(_ id: String, expecting: LocalParameterPreset? = nil) throws -> LocalParameterPreset {
        try database.write { db in
            guard let old = try LocalParameterPreset.fetchOne(db, key: id) else {
                throw LRCError(L10n.text("app.theLocalPresetDoesNotExist", defaultValue: "The local preset does not exist"))
            }
            if let expecting, old != expecting { throw OrganizationError.versionConflict }
            try db.execute(sql: "DELETE FROM localParameterPreset WHERE id=?", arguments: [id])
            guard db.changesCount == 1 else { throw LRCError(L10n.text("app.theLocalPresetWasNotDeleted", defaultValue: "The local preset was not deleted")) }
            return old
        }
    }

    /// Restore the exact row captured by `deleteLocalParameterPreset`.
    /// This is used by the app's one-step preset deletion undo; it refuses to
    /// overwrite a row that appeared under the same id while the undo was away.
    func restoreLocalParameterPreset(_ preset: LocalParameterPreset) throws {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else {
            throw LRCError(L10n.text("app.localPresetNamesMustContain1100Characters", defaultValue: "Local preset names must contain 1–100 characters"))
        }
        _ = try preset.decodedValues()
        try database.write { db in
            guard try LocalParameterPreset.fetchOne(db, key: preset.id) == nil else {
                throw LRCError(L10n.text("app.theLocalPresetAlreadyExistsAndCannotBeRestored", defaultValue: "The local preset already exists and cannot be restored"))
            }
            try preset.insert(db)
        }
    }
}
