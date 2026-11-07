import Foundation
import GRDB

final class CatalogStore: @unchecked Sendable {
    let fileURL: URL
    var directory: URL { fileURL.deletingLastPathComponent() }
    private let access: AccessLease?
    private let lock: CatalogLock
    let database: DatabaseQueue
    static let schemaVersion = 13

    /// New working directory or an exactly current catalog; no migration.
    convenience init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Catalog.sqlite")
        try self.init(fileURL: file, create: !FileManager.default.fileExists(atPath: file.path))
    }

    init(fileURL: URL, create: Bool = false, access: AccessLease? = nil) throws {
        self.fileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        self.access = access
        if create {
            // Exclusive publication refuses even a file created after the save dialog.
            try SafeFileWriter.write(Data(), to: self.fileURL)
        } else {
            _ = try FileIdentity.read(self.fileURL)
        }
        lock = try CatalogLock(fileURL: self.fileURL)
        if !create {
            var readOnly = Configuration(); readOnly.readonly = true
            let candidate = try DatabaseQueue(path: self.fileURL.path, configuration: readOnly)
            do { try Self.validate(candidate); try candidate.close() }
            catch { try? candidate.close(); throw LRCError(L10n.text("app.cannotOpenCatalogTheFileIsDamagedItsVersion", defaultValue: "Cannot open catalog: the file is damaged, its version is unsupported, or it is not a Phosdeck catalog.\n") + error.localizedDescription) }
        }
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("photo_filename", argumentCount: 1, pure: true) { values in
                guard let path = String.fromDatabaseValue(values[0]) else { return nil }
                return URL(fileURLWithPath: path).lastPathComponent
            })
            // query.rs::cmp_name, LightCraft 4f0b110: lowercase each Unicode
            // scalar, then compare lexically. SQLite NOCASE only covers ASCII.
            db.add(function: DatabaseFunction("photo_filename_key", argumentCount:1, pure:true) { values in
                guard let path = String.fromDatabaseValue(values[0]) else { return nil }
                // URL can expose a decomposed filesystem spelling. Keep the
                // same canonical-name convention as export conflict checks.
                return URL(fileURLWithPath:path).lastPathComponent.precomposedStringWithCanonicalMapping
                    .unicodeScalars.map { String($0).lowercased() }.joined()
            })
            db.add(function: DatabaseFunction("photo_day", argumentCount: 1, pure: true) { values in
                LibraryMetadataFilter.day(String.fromDatabaseValue(values[0]))
            })
            db.add(function: DatabaseFunction("photo_lens", argumentCount: 1, pure: true) { values in
                Data.fromDatabaseValue(values[0]).flatMap { try? JSONDecoder().decode(PhotoMetadata.self, from: $0) }?.lens
            })
            db.add(function: DatabaseFunction("photo_iso", argumentCount: 1, pure: true) { values in
                guard let data = Data.fromDatabaseValue(values[0]), let iso = (try? JSONDecoder().decode(PhotoMetadata.self, from: data))?.iso, iso > 0 else { return nil }
                return iso
            })
            try db.execute(sql: "CREATE TEMP TABLE browseSnapshot (snapshotID TEXT NOT NULL, photoID TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(snapshotID, photoID), UNIQUE(snapshotID, position))")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            // Single serialized connection, rollback journal; WAL is deliberately not enabled.
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        database = try DatabaseQueue(path: self.fileURL.path, configuration: configuration)
        if create {
            try database.write { db in
                try db.execute(sql: """
            CREATE TABLE catalogMeta (id TEXT PRIMARY KEY NOT NULL, schemaVersion INTEGER NOT NULL);
            INSERT INTO catalogMeta VALUES ('\(UUID().uuidString)', 13);
            CREATE TABLE storageRoot (id TEXT PRIMARY KEY NOT NULL, path TEXT NOT NULL UNIQUE, bookmark BLOB NOT NULL, label TEXT NOT NULL);
            CREATE TABLE photoSource (
                id TEXT PRIMARY KEY NOT NULL, rootID TEXT NOT NULL REFERENCES storageRoot(id),
                relativePath TEXT NOT NULL, identity BLOB NOT NULL, identityKey TEXT NOT NULL UNIQUE,
                digest TEXT, revision INTEGER NOT NULL DEFAULT 1, captureDate TEXT,
                width INTEGER NOT NULL, height INTEGER NOT NULL, camera TEXT,
                availability TEXT NOT NULL, metadata BLOB, UNIQUE(rootID,relativePath));
            CREATE TABLE photo (
                id TEXT PRIMARY KEY NOT NULL, sourceID TEXT REFERENCES photoSource(id), copyName TEXT CHECK(copyName IS NULL OR length(trim(copyName)) BETWEEN 1 AND 100), deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)), rootID TEXT NOT NULL REFERENCES storageRoot(id),
                relativePath TEXT NOT NULL, identity BLOB NOT NULL, identityKey TEXT NOT NULL,
                digest TEXT, revision INTEGER NOT NULL DEFAULT 1,
                rating INTEGER NOT NULL DEFAULT 0 CHECK(rating BETWEEN 0 AND 5),
                flag INTEGER NOT NULL DEFAULT 0 CHECK(flag BETWEEN -1 AND 1),
                colorLabel INTEGER NOT NULL DEFAULT 0 CHECK(colorLabel BETWEEN 0 AND 5),
                caption TEXT NOT NULL DEFAULT '' CHECK(length(caption)<=8000),
                captureDate TEXT, width INTEGER NOT NULL, height INTEGER NOT NULL, camera TEXT,
                availability TEXT NOT NULL, recipe BLOB, recipeRevision INTEGER NOT NULL DEFAULT 0, metadata BLOB);
            CREATE TABLE sourceCopyOrigin (sourceID TEXT PRIMARY KEY NOT NULL REFERENCES photoSource(id), originKey TEXT NOT NULL);
            CREATE TABLE rawJpegPair (id TEXT PRIMARY KEY NOT NULL, rawSourceID TEXT NOT NULL UNIQUE REFERENCES photoSource(id), jpegSourceID TEXT NOT NULL UNIQUE REFERENCES photoSource(id), CHECK(rawSourceID<>jpegSourceID));
            CREATE TRIGGER pair_one_partner BEFORE INSERT ON rawJpegPair WHEN EXISTS(SELECT 1 FROM rawJpegPair WHERE rawSourceID IN (NEW.rawSourceID,NEW.jpegSourceID) OR jpegSourceID IN (NEW.rawSourceID,NEW.jpegSourceID)) BEGIN SELECT RAISE(ABORT,'source already paired'); END;
            CREATE TABLE displayStack (id TEXT PRIMARY KEY NOT NULL, collapsed INTEGER NOT NULL CHECK(collapsed IN (0,1)));
            CREATE TABLE stackMember (stackID TEXT NOT NULL REFERENCES displayStack(id) ON DELETE CASCADE, photoID TEXT NOT NULL UNIQUE REFERENCES photo(id), position INTEGER NOT NULL CHECK(position>=0), PRIMARY KEY(stackID,position));
            CREATE TABLE collection (id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL CHECK(length(trim(name)) > 0), rules BLOB);
            CREATE TABLE membership (collectionID TEXT NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
                photoID TEXT NOT NULL REFERENCES photo(id), PRIMARY KEY(collectionID, photoID));
            CREATE TRIGGER smart_no_members BEFORE INSERT ON membership WHEN (SELECT rules FROM collection WHERE id=NEW.collectionID) IS NOT NULL BEGIN SELECT RAISE(ABORT,'smart members are dynamic'); END;
            CREATE INDEX photo_date ON photo(captureDate, id);
            CREATE TABLE exportItem (id TEXT PRIMARY KEY NOT NULL, snapshot BLOB NOT NULL, state TEXT NOT NULL,
                destination TEXT NOT NULL, staging TEXT, digest TEXT, error TEXT);
            CREATE INDEX photo_source ON photo(sourceID,deleted);
            CREATE UNIQUE INDEX photo_original ON photo(sourceID) WHERE copyName IS NULL;
            CREATE TABLE importPlan (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, state TEXT NOT NULL);
            CREATE TABLE attachment (photoID TEXT NOT NULL REFERENCES photo(id), relativePath TEXT NOT NULL, digest TEXT NOT NULL, PRIMARY KEY(photoID, relativePath));
            CREATE INDEX photo_root_date ON photo(rootID,captureDate,relativePath,id);
            CREATE INDEX photo_order ON photo(captureDate,relativePath,id);
            CREATE TABLE editHistory (id INTEGER PRIMARY KEY AUTOINCREMENT, photoID TEXT NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                title TEXT NOT NULL, createdAt DOUBLE NOT NULL, recipe BLOB NOT NULL);
            CREATE INDEX history_photo ON editHistory(photoID,id DESC);
            CREATE TABLE editSnapshot (id TEXT PRIMARY KEY NOT NULL, photoID TEXT NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
                title TEXT NOT NULL CHECK(length(trim(title)) > 0), createdAt DOUBLE NOT NULL, recipe BLOB NOT NULL);
            CREATE INDEX snapshot_photo ON editSnapshot(photoID,createdAt DESC);
            CREATE TABLE adjustmentPreset (id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 100),recipe BLOB NOT NULL,options BLOB NOT NULL,groupName TEXT NOT NULL DEFAULT '' CHECK(length(trim(groupName))<=100),favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0,1)));
            CREATE TABLE localParameterPreset (id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 100),parameters BLOB NOT NULL);
            CREATE TABLE photoKeyword (photoID TEXT NOT NULL REFERENCES photo(id) ON DELETE CASCADE,keyword TEXT NOT NULL CHECK(length(keyword)>0),name TEXT NOT NULL CHECK(length(name)>0),PRIMARY KEY(photoID,keyword));
            CREATE INDEX keyword_photos ON photoKeyword(keyword,photoID);
            PRAGMA user_version=13;
            CREATE TRIGGER photo_source_insert AFTER INSERT ON photo BEGIN
                INSERT INTO photoSource (id,rootID,relativePath,identity,identityKey,digest,revision,captureDate,width,height,camera,availability,metadata) SELECT COALESCE(NEW.sourceID,NEW.id),NEW.rootID,NEW.relativePath,NEW.identity,NEW.identityKey,NEW.digest,NEW.revision,NEW.captureDate,NEW.width,NEW.height,NEW.camera,NEW.availability,NEW.metadata WHERE NEW.sourceID IS NULL;
                SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM photoSource WHERE id=COALESCE(NEW.sourceID,NEW.id) AND rootID IS NEW.rootID AND relativePath IS NEW.relativePath AND identity IS NEW.identity AND identityKey IS NEW.identityKey AND digest IS NEW.digest AND revision IS NEW.revision AND captureDate IS NEW.captureDate AND width IS NEW.width AND height IS NEW.height AND camera IS NEW.camera AND availability IS NEW.availability AND metadata IS NEW.metadata) THEN RAISE(ABORT,'source projection mismatch') END;
                UPDATE photo SET sourceID=COALESCE(NEW.sourceID,NEW.id) WHERE id=NEW.id;
            END;
            CREATE TRIGGER photo_source_immutable BEFORE UPDATE OF sourceID ON photo WHEN OLD.sourceID IS NOT NULL AND NEW.sourceID IS NOT OLD.sourceID BEGIN SELECT RAISE(ABORT,'source identity is immutable'); END;
            CREATE TRIGGER photo_source_update AFTER UPDATE OF rootID,relativePath,identity,identityKey,digest,revision,captureDate,width,height,camera,availability,metadata ON photo
            WHEN EXISTS(SELECT 1 FROM photoSource WHERE id=NEW.sourceID AND (rootID IS NOT NEW.rootID OR relativePath IS NOT NEW.relativePath OR identity IS NOT NEW.identity OR identityKey IS NOT NEW.identityKey OR digest IS NOT NEW.digest OR revision IS NOT NEW.revision OR captureDate IS NOT NEW.captureDate OR width IS NOT NEW.width OR height IS NOT NEW.height OR camera IS NOT NEW.camera OR availability IS NOT NEW.availability OR metadata IS NOT NEW.metadata)) BEGIN
                UPDATE photoSource SET rootID=NEW.rootID,relativePath=NEW.relativePath,identity=NEW.identity,identityKey=NEW.identityKey,digest=NEW.digest,revision=NEW.revision,captureDate=NEW.captureDate,width=NEW.width,height=NEW.height,camera=NEW.camera,availability=NEW.availability,metadata=NEW.metadata WHERE id=NEW.sourceID;
            END;
            CREATE TRIGGER source_versions_update AFTER UPDATE ON photoSource BEGIN
                UPDATE photo SET rootID=NEW.rootID,relativePath=NEW.relativePath,identity=NEW.identity,identityKey=NEW.identityKey,digest=NEW.digest,revision=NEW.revision,captureDate=NEW.captureDate,width=NEW.width,height=NEW.height,camera=NEW.camera,availability=NEW.availability,metadata=NEW.metadata WHERE sourceID=NEW.id;
            END;
            """)
            }
        }
        try database.write { db in
            try db.execute(sql: "UPDATE exportItem SET state = 'interrupted' WHERE state IN ('planned','rendering','verified','published')")
            for payload in try Data.fetchAll(db, sql: "SELECT payload FROM importPlan WHERE state='running'") {
                var plan = try JSONDecoder().decode(CopyPlan.self, from: payload)
                guard plan.version == 2 else { throw LRCError(L10n.text("app.unsupportedImportTaskOriginalDataPreserved", defaultValue: "Unsupported import task. Original data preserved")) }
                plan.state = "interrupted"
                try db.execute(sql: "UPDATE importPlan SET state='interrupted',payload=? WHERE id=?", arguments: [try JSONEncoder().encode(plan), plan.id])
            }
        }
    }

    func diagnostics() throws -> String {
        try database.read { db in
            let version = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "?"
            let source = try String.fetchOne(db, sql: "SELECT sqlite_source_id()") ?? "?"
            let journal = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "?"
            return "SQLite \(version) / \(journal)\n\(source)"
        }
    }
    func roots() throws -> [StorageRoot] { try database.read { try StorageRoot.fetchAll($0) } }
    func photos() throws -> [Photo] { try database.read { try Photo.fetchAll($0, sql: "SELECT * FROM photo WHERE deleted=0 ORDER BY captureDate, relativePath, id") } }
    func collections() throws -> [PhotoCollection] { try database.read { try PhotoCollection.fetchAll($0, sql: "SELECT * FROM collection ORDER BY name") } }
    func addRoot(url: URL, bookmark: Data) throws -> StorageRoot {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let existing = try roots()
        if let root = existing.first(where: { $0.path == path }) { return root }
        guard !existing.contains(where: { path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") }) else {
            throw LRCError(L10n.text("app.theSelectedFolderOverlapsAnExistingRootRescanThe", defaultValue: "The selected folder overlaps an existing root. Rescan the existing root"))
        }
        let root = StorageRoot(id: UUID().uuidString, path: path, bookmark: bookmark, label: url.lastPathComponent)
        try database.write { try root.insert($0) }
        return root
    }
    /// Returns true only when this call creates a new catalog version.
    @discardableResult func index(_ photo: Photo) throws -> Bool {
        try database.write { try Self.index(photo, in: $0) }
    }
    /// Shared by explicit folder confirmation so a selected batch publishes atomically.
    @discardableResult static func index(_ photo: Photo, in db: Database) throws -> Bool {
        if let old = try Photo.fetchOne(db, sql: "SELECT * FROM photo WHERE rootID = ? AND relativePath = ?", arguments: [photo.rootID, photo.relativePath]) {
            let oldIdentity = try? JSONDecoder().decode(FileIdentity.self, from: old.identity)
            let newIdentity = try? JSONDecoder().decode(FileIdentity.self, from: photo.identity)
            let sameIdentity = old.identity == photo.identity || (oldIdentity != nil && oldIdentity == newIdentity)
            if !sameIdentity {
                try db.execute(sql: "UPDATE photo SET availability = 'changed' WHERE id = ?", arguments: [old.id])
            } else if let metadata = photo.metadata {
                try db.execute(sql: "UPDATE photo SET metadata=? WHERE id=?", arguments: [metadata, old.id])
            }
            return false
        } else if try Photo.filter(Column("identityKey") == photo.identityKey).fetchCount(db) > 0 {
            // Existing file identity (including hard links) already belongs to the catalog.
            return false
        } else {
            try photo.insert(db)
            return true
        }
    }
    func protectedPaths() throws -> Set<String> {
        try database.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT storageRoot.path || '/' || photo.relativePath FROM photo JOIN storageRoot ON storageRoot.id=photo.rootID")
            let attached = try String.fetchAll(db, sql: "SELECT storageRoot.path || '/' || attachment.relativePath FROM attachment JOIN photo ON photo.id=attachment.photoID JOIN storageRoot ON storageRoot.id=photo.rootID")
            return Set((paths + attached).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        }
    }
    func attachSidecars(group: CopyGroup, root: StorageRoot) throws {
        let images = group.members.filter(\.isImage)
        let sidecars = group.members.filter { !$0.isImage }
        try database.write { db in
            for image in images {
                let key = try FileIdentity.read(image.destination).key
                guard let id = try String.fetchOne(db, sql: "SELECT id FROM photo WHERE identityKey=?", arguments: [key]) else { continue }
                for sidecar in sidecars {
                    let relative = String(sidecar.destination.path.dropFirst(root.path.count + 1))
                    try db.execute(sql: "INSERT OR IGNORE INTO attachment VALUES (?,?,?)", arguments: [id, relative, sidecar.digest])
                }
            }
        }
    }
    func setOrganization(ids: [String], rating: Int? = nil, flag: Int? = nil, colorLabel: Int? = nil) throws {
        if let colorLabel, PhotoColorLabel(rawValue: colorLabel) == nil { throw LRCError(L10n.text("app.invalidColorLabel", defaultValue: "Invalid color label")) }
        try database.write { db in
            for id in ids {
                if let rating { try db.execute(sql: "UPDATE photo SET rating = ? WHERE id = ?", arguments: [rating, id]) }
                if let flag { try db.execute(sql: "UPDATE photo SET flag = ? WHERE id = ?", arguments: [flag, id]) }
                if let colorLabel { try db.execute(sql: "UPDATE photo SET colorLabel = ? WHERE id = ?", arguments: [colorLabel, id]) }
            }
        }
    }
    func setRatings(_ ratings: [String: Int]) throws {
        try database.write { db in
            for (id, rating) in ratings { try db.execute(sql: "UPDATE photo SET rating = ? WHERE id = ?", arguments: [rating, id]) }
        }
    }
    func saveRecipe(id: String, recipe: EditRecipe, title: String? = nil) throws {
        try database.write { try Self.saveRecipe(db: $0, id: id, recipe: recipe, title: title) }
    }
    private static func saveRecipe(db: Database, id: String, recipe: EditRecipe, title: String?) throws {
        try recipe.validate()
        let encoded = try JSONEncoder().encode(recipe)
        guard let photo = try Photo.fetchOne(db, key: id), photo.availability == "available" else { throw LRCError(L10n.text("app.theSourceIsUnavailableEditDraftPreserved", defaultValue: "The source is unavailable. Edit draft preserved")) }
        try recipe.validate(for: photo)
        if let digest = photo.digest, digest != recipe.sourceDigest { throw LRCError(L10n.text("app.sourceIdentityMismatchRecipeWasNotSaved", defaultValue: "Source identity mismatch. Recipe was not saved")) }
        let previous = try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) }
        guard previous != recipe else { return }
        try db.execute(sql: "UPDATE photo SET recipe = ?, digest = ?, recipeRevision = recipeRevision + 1 WHERE id = ?", arguments: [encoded, recipe.sourceDigest, id])
        try db.execute(sql: "INSERT INTO editHistory (photoID,title,createdAt,recipe) VALUES (?,?,?,?)",
                       arguments: [id, title ?? recipe.changeTitle(from: previous), Date().timeIntervalSince1970, encoded])
    }

    /// Prepare image baselines outside the transaction; publish the successful subset together.
    func saveRecipes(_ changes: [(photo: Photo, recipe: EditRecipe)], title: String) throws {
        try database.write { db in
            for change in changes {
                guard let current = try Photo.fetchOne(db, key: change.photo.id),
                      current.recipeRevision == change.photo.recipeRevision, current.revision == change.photo.revision,
                      current.identity == change.photo.identity else { throw LRCError(L10n.text("app.aPhotoChangedDuringSynchronizationBatchAdjustmentsWereNot", defaultValue: "A photo changed during synchronization. Batch adjustments were not saved")) }
                try Self.saveRecipe(db: db, id: current.id, recipe: change.recipe, title: title)
            }
        }
    }
    /// Keep nil recipes for previously untouched photos. Restore the whole undo step atomically.
    func restoreRecipes(_ states: [Photo], title: String) throws -> [Photo] {
        try database.write { db in
            var inverse = [Photo]()
            for state in states {
                guard let current = try Photo.fetchOne(db, key: state.id), current.availability == "available",
                      current.identity == state.identity else { throw LRCError(L10n.text("app.aPhotoSourceChangedTheseBatchAdjustmentsCannotBe", defaultValue: "A photo source changed. These batch adjustments cannot be restored")) }
                let old = try state.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) }
                try old?.validate()
                if let old, let digest = current.digest, old.sourceDigest != digest { throw LRCError(L10n.text("app.photoSourceMismatchAdjustmentsCannotBeRestored", defaultValue: "Photo source mismatch. Adjustments cannot be restored")) }
                inverse.append(current)
                let history = try state.recipe ?? current.recipe.map {
                    try JSONEncoder().encode(JSONDecoder().decode(EditRecipe.self, from: $0).baseline())
                }
                try db.execute(sql: "UPDATE photo SET recipe=?,digest=?,recipeRevision=recipeRevision+1 WHERE id=?",
                               arguments: [state.recipe, state.digest, state.id])
                if let history {
                    try db.execute(sql: "INSERT INTO editHistory (photoID,title,createdAt,recipe) VALUES (?,?,?,?)",
                                   arguments: [state.id, title, Date().timeIntervalSince1970, history])
                }
            }
            return inverse
        }
    }
    func presets() throws -> [AdjustmentPreset] {
        try database.read {
            try AdjustmentPreset.order(Column("groupName"), Column("name"), Column("id")).fetchAll($0)
        }
    }

    /// Save only the selected parameter groups. Geometry, masks and repair
    /// locations continue to follow the existing `baseline().pasting` contract.
    /// The optional group is intentionally a storage concern so the existing
    /// save dialog remains source-compatible until its caller grows a group
    /// picker.
    func savePreset(name: String, recipe: EditRecipe, options: RecipePasteOptions, groupName: String? = nil) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = Self.normalizedPresetGroup(groupName)
        guard !name.isEmpty, name.count <= 100, options.hasSelection else {
            throw LRCError(L10n.text("app.enterANameContaining1100CharactersAndSelect", defaultValue: "Enter a name containing 1–100 characters and select preset settings"))
        }
        try recipe.validate()
        let selected = try recipe.baseline().pasting(recipe, options: options)
        let preset = AdjustmentPreset(id: UUID().uuidString, name: name,
                                      recipe: try JSONEncoder().encode(selected),
                                      options: try JSONEncoder().encode(options),
                                      groupName: group)
        try database.write { try preset.insert($0) }
    }

    func renamePreset(id: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw LRCError(L10n.text("app.presetNamesMustContain1100Characters", defaultValue: "Preset names must contain 1–100 characters")) }
        try database.write { try $0.execute(sql: "UPDATE adjustmentPreset SET name=? WHERE id=?", arguments: [name, id]) }
    }

    /// Replace the selected settings of an existing preset and return the
    /// complete previous row for one-step undo. The preset identity, group and
    /// favorite state are deliberately retained.
    @discardableResult
    func updatePreset(id: String, recipe: EditRecipe, options: RecipePasteOptions) throws -> AdjustmentPreset {
        var options = options
        options.importedXMP = nil // Updating from a photo creates ordinary native parameter groups.
        guard options.hasSelection else { throw LRCError(L10n.text("app.selectAtLeastOnePresetParameterGroup", defaultValue: "Select at least one preset parameter group")) }
        try recipe.validate()
        let selected = try recipe.baseline().pasting(recipe, options: options)
        let recipeData = try JSONEncoder().encode(selected)
        let optionsData = try JSONEncoder().encode(options)
        return try database.write { db in
            guard let old = try AdjustmentPreset.fetchOne(db, key: id) else { throw LRCError(L10n.text("app.thePresetDoesNotExistOrWasDeleted", defaultValue: "The preset does not exist or was deleted")) }
            try db.execute(sql: "UPDATE adjustmentPreset SET recipe=?,options=? WHERE id=?",
                           arguments: [recipeData, optionsData, id])
            return old
        }
    }

    /// Set or clear the star without changing the recipe or its grouping.
    @discardableResult
    func setPresetFavorite(id: String, favorite: Bool) throws -> AdjustmentPreset {
        try database.write { db in
            guard let old = try AdjustmentPreset.fetchOne(db, key: id) else { throw LRCError(L10n.text("app.thePresetDoesNotExistOrWasDeleted", defaultValue: "The preset does not exist or was deleted")) }
            guard old.favorite != favorite else { return old }
            try db.execute(sql: "UPDATE adjustmentPreset SET favorite=? WHERE id=?", arguments: [favorite, id])
            return old
        }
    }

    /// Move a preset into an existing or newly-created group. Passing an empty
    /// string clears the group and shows it under “未分组”.
    @discardableResult
    func setPresetGroup(id: String, groupName: String) throws -> AdjustmentPreset {
        let group = Self.normalizedPresetGroup(groupName)
        return try database.write { db in
            guard let old = try AdjustmentPreset.fetchOne(db, key: id) else { throw LRCError(L10n.text("app.thePresetDoesNotExistOrWasDeleted", defaultValue: "The preset does not exist or was deleted")) }
            guard old.groupName != group else { return old }
            try db.execute(sql: "UPDATE adjustmentPreset SET groupName=? WHERE id=?", arguments: [group, id])
            return old
        }
    }

    /// Restore a complete preset row, including a row deleted by the user.
    /// This is intentionally an explicit operation for Undo; no migration or
    /// fallback schema is attempted here.
    func restorePreset(_ preset: AdjustmentPreset) throws {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = Self.normalizedPresetGroup(preset.groupName)
        guard !name.isEmpty, name.count <= 100 else { throw LRCError(L10n.text("app.presetNamesMustContain1100Characters", defaultValue: "Preset names must contain 1–100 characters")) }
        try database.write { db in
            if try AdjustmentPreset.fetchOne(db, key: preset.id) == nil {
                var restored = preset
                restored.name = name
                restored.groupName = group
                try restored.insert(db)
            } else {
                try db.execute(sql: "UPDATE adjustmentPreset SET name=?,recipe=?,options=?,groupName=?,favorite=? WHERE id=?",
                               arguments: [name, preset.recipe, preset.options, group, preset.favorite, preset.id])
            }
        }
    }

    /// Confirm a reviewed batch in one transaction. Never replace existing presets.
    func importXMPPresets(_ drafts: [XMPPresetDraft]) throws -> [AdjustmentPreset] {
        guard drafts.count <= XMPPresetReader.maximumFiles else { throw LRCError(L10n.text("app.importUpTo128XMPPresetsAtOnce", defaultValue: "Import up to 128 XMP presets at once")) }
        let candidates = try drafts.map { draft -> AdjustmentPreset in
            guard draft.settings.hasContent, (1...100).contains(draft.name.count), draft.group.count <= 100 else { throw LRCError(L10n.text("app.theXMPPresetHasNoUsableAdjustmentsOrIts", defaultValue: "The XMP preset has no usable adjustments or its name is invalid")) }
            let record = try draft.record()
            let source = try JSONDecoder().decode(EditRecipe.self, from: record.recipe)
            _ = try draft.settings.resolved(on: source, options: draft.settings.options)
            return record
        }
        return try database.write { db in
            var existing = try AdjustmentPreset.fetchAll(db)
            var imported: [AdjustmentPreset] = []
            for candidate in candidates {
                let payload = try JSONDecoder().decode(RecipePasteOptions.self, from: candidate.options).importedXMP
                let duplicate = existing.contains { row in
                    row.name == candidate.name && row.groupName == candidate.groupName
                        && (try? JSONDecoder().decode(RecipePasteOptions.self, from: row.options).importedXMP) == payload
                }
                guard !duplicate else { continue }
                try candidate.insert(db)
                imported.append(candidate); existing.append(candidate)
            }
            return imported
        }
    }

    /// One Undo/Redo restores exactly the imported rows, including sparse fields and notices.
    func restoreXMPPresetBatch(_ rows: [AdjustmentPreset], present: Bool) throws {
        try database.write { db in
            for row in rows {
                if present {
                    guard try AdjustmentPreset.fetchOne(db, key: row.id) == nil else { throw LRCError(L10n.text("app.presetIdentityConflictTheExistingPresetWasPreserved", defaultValue: "Preset identity conflict. The existing preset was preserved")) }
                    try row.insert(db)
                } else {
                    guard try AdjustmentPreset.fetchOne(db, key: row.id) == row else { throw LRCError(L10n.text("app.thePresetChangedItsCurrentContentsWereNotDeleted", defaultValue: "The preset changed. Its current contents were not deleted")) }
                    try db.execute(sql: "DELETE FROM adjustmentPreset WHERE id=?", arguments: [row.id])
                }
            }
        }
    }

    @discardableResult
    func deletePreset(_ id: String) throws -> AdjustmentPreset? {
        try database.write { db in
            let old = try AdjustmentPreset.fetchOne(db, key: id)
            try db.execute(sql: "DELETE FROM adjustmentPreset WHERE id=?", arguments: [id])
            return old
        }
    }

    private static func normalizedPresetGroup(_ value: String?) -> String {
        guard let value else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
    func editHistory(photoID: String, limit: Int = 100, offset: Int = 0, afterID: Int64? = nil) throws -> [EditHistoryEntry] {
        if let afterID {
            return try database.read { try EditHistoryEntry.fetchAll($0, sql: "SELECT * FROM editHistory WHERE photoID=? AND id>? ORDER BY id DESC LIMIT ? OFFSET ?", arguments: [photoID, afterID, limit, offset]) }
        }
        return try database.read { try EditHistoryEntry.fetchAll($0, sql: "SELECT * FROM editHistory WHERE photoID=? ORDER BY id DESC LIMIT ? OFFSET ?", arguments: [photoID, limit, offset]) }
    }
    func snapshots(photoID: String) throws -> [EditSnapshot] {
        try database.read { try EditSnapshot.fetchAll($0, sql: "SELECT * FROM editSnapshot WHERE photoID=? ORDER BY createdAt DESC,id", arguments: [photoID]) }
    }
    func createSnapshot(photoID: String, title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw LRCError(L10n.text("app.snapshotNamesMustContain1100Characters", defaultValue: "Snapshot names must contain 1–100 characters")) }
        try database.write { db in
            guard let photo = try Photo.fetchOne(db, key: photoID), photo.availability == "available", let data = photo.recipe else { throw LRCError(L10n.text("app.noAdjustmentsToSave", defaultValue: "No adjustments to save")) }
            let recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
            try recipe.validate()
            guard recipe.sourceDigest == photo.digest else { throw LRCError(L10n.text("app.sourceIdentityMismatch", defaultValue: "Source identity mismatch")) }
            try EditSnapshot(id: UUID().uuidString, photoID: photoID, title: name, createdAt: Date().timeIntervalSince1970, recipe: data).insert(db)
        }
    }
    func renameSnapshot(id: String, photoID: String, title: String) throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw LRCError(L10n.text("app.snapshotNamesMustContain1100Characters", defaultValue: "Snapshot names must contain 1–100 characters")) }
        try database.write { try $0.execute(sql: "UPDATE editSnapshot SET title=? WHERE id=? AND photoID=?", arguments: [name, id, photoID]) }
    }
    func deleteSnapshot(_ snapshot: EditSnapshot) throws {
        try database.write { db in
            guard try EditSnapshot.fetchOne(db, key: snapshot.id) == snapshot else { throw LRCError(L10n.text("app.theSnapshotChangedOrWasDeletedSelectItAgain", defaultValue: "The snapshot changed or was deleted. Select it again")) }
            try db.execute(sql: "DELETE FROM editSnapshot WHERE id=? AND photoID=?", arguments: [snapshot.id, snapshot.photoID])
        }
    }
    /// Undo inserts the original row verbatim; it must never replace a newer row.
    func restoreSnapshot(_ snapshot: EditSnapshot) throws {
        try database.write { db in
            guard let photo = try Photo.fetchOne(db, key: snapshot.photoID), !photo.deleted else { throw LRCError(L10n.text("app.thePhotoWasRemovedTheSnapshotCannotBeRestored", defaultValue: "The photo was removed. The snapshot cannot be restored")) }
            guard try EditSnapshot.fetchOne(db, key: snapshot.id) == nil else { throw LRCError(L10n.text("app.theSnapshotAlreadyExistsAndCannotBeOverwrittenDuring", defaultValue: "The snapshot already exists and cannot be overwritten during restoration")) }
            try snapshot.insert(db)
        }
    }
    func collection(name: String, id: String? = nil) throws {
        if let id, try collections().first(where: { $0.id == id })?.isSmart == true { throw LRCError(L10n.text("app.useTheSmartCollectionRuleEditor", defaultValue: "Use the smart collection rule editor")) }
        let value = PhotoCollection(id: id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        try database.write { try value.save($0) }
    }
    func collectionContents(_ id: String) throws -> CollectionContents {
        try database.read { try Self.readCollectionContents($0, id: id) }
    }
    private static func readCollectionContents(_ db: Database, id: String) throws -> CollectionContents {
        guard let collection = try PhotoCollection.fetchOne(db, key: id), !collection.isSmart else {
            throw LRCError(L10n.text("app.theRegularCollectionNoLongerExistsOrItsType", defaultValue: "The regular collection no longer exists or its type changed"))
        }
        return CollectionContents(collection: collection, members: try readManualCollectionOrder(db, id: id))
    }
    @discardableResult func deleteCollection(_ id: String, expecting expected: CollectionContents? = nil) throws -> CollectionContents {
        try database.write { db in
            let contents = try Self.readCollectionContents(db, id: id)
            guard expected == nil || expected == contents else { throw LRCError(L10n.text("app.theCollectionOrItsMembersChangedNothingWasDeleted", defaultValue: "The collection or its members changed. Nothing was deleted")) }
            try db.execute(sql: "DELETE FROM collection WHERE id=?", arguments: [id])
            return contents
        }
    }
    func restoreCollection(_ contents: CollectionContents) throws {
        try database.write { db in
            guard !contents.collection.isSmart, Set(contents.members).count == contents.members.count else {
                throw LRCError(L10n.text("app.invalidRegularCollectionRecoveryRecord", defaultValue: "Invalid regular collection recovery record"))
            }
            guard try PhotoCollection.fetchOne(db, key: contents.collection.id) == nil else {
                throw LRCError(L10n.text("app.aCollectionWithThisIDAlreadyExistsAndCannot", defaultValue: "A collection with this ID already exists and cannot be overwritten during restoration"))
            }
            try contents.collection.insert(db)
            let insert = try db.makeStatement(sql: "INSERT INTO membership(collectionID,photoID) VALUES (?,?)")
            for id in contents.members { try insert.execute(arguments: [contents.collection.id, id]) }
        }
    }
    func members(_ collection: String) throws -> Set<String> {
        if let c = try collections().first(where:{ $0.id == collection }), c.isSmart, let rules = try c.decodedRules() {
            let query = PhotoQuery(scope:rules.source,smart:rules), (predicate,args) = query.predicate
            return try database.read { Set(try String.fetchAll($0,sql:"SELECT photo.id FROM "+query.relation+" WHERE "+predicate,arguments:args)) }
        }
        return try database.read { Set(try String.fetchAll($0, sql: "SELECT photoID FROM membership WHERE collectionID = ?", arguments: [collection])) }
    }
    /// Read only the requested members, without materializing a potentially large collection.
    func members(_ collection: String, within ids: Set<String>) throws -> Set<String> {
        try database.read { db in
            var result = Set<String>()
            let ordered = ids.sorted()
            for start in stride(from: 0, to: ordered.count, by: 500) {
                let batch = Array(ordered[start..<min(start + 500, ordered.count)])
                let marks = batch.map { _ in "?" }.joined(separator: ",")
                result.formUnion(try String.fetchAll(db, sql: "SELECT photoID FROM membership WHERE collectionID=? AND photoID IN (\(marks))", arguments: StatementArguments([collection] + batch)))
            }
            return result
        }
    }
    func membership(ids: [String], collection: String, add: Bool) throws {
        try database.write { db in
            try requireManualCollection(db,id:collection)
            for id in ids {
                try db.execute(sql: add ? "INSERT OR IGNORE INTO membership VALUES (?, ?)" : "DELETE FROM membership WHERE collectionID = ? AND photoID = ?", arguments: [collection, id])
            }
        }
    }
    /// Atomic membership edit with exact inverse, including existing no-op rows.
    func restoreMembership(_ states: [String: Bool], collection: String) throws -> [String: Bool] {
        try restoreOrderedMembership(states, collection: collection).inverse
    }
    /// Apply a membership edit and, optionally, its complete resulting order
    /// in one transaction. `order` is the desired complete order *after* the
    /// state changes. Passing it is useful for a query-ordered import or for
    /// undo, where the previous complete order is already known. With nil,
    /// existing members retain their relative order and newly added IDs are
    /// appended in lexical order, never in Dictionary iteration order.
    @discardableResult func restoreOrderedMembership(_ states: [String: Bool], collection: String, order: [String]? = nil) throws -> OrderedMembershipChange {
        try database.write { db in
            try requireManualCollection(db,id:collection)
            let previousOrder = try Self.readManualCollectionOrder(db, id: collection)
            let previousSet = Set(previousOrder)
            let ids = states.keys.sorted()
            var inverse = [String: Bool]()

            for id in ids {
                let add = states[id] ?? false
                let present = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM membership WHERE collectionID=? AND photoID=?)", arguments: [collection,id]) ?? false
                guard present != add else { continue }
                inverse[id] = present
                try db.execute(sql: add ? "INSERT INTO membership VALUES (?,?)" : "DELETE FROM membership WHERE collectionID=? AND photoID=?", arguments: [collection,id])
            }

            let desiredOrder: [String]
            if let order {
                desiredOrder = order
            } else {
                let removed = Set(ids.filter { states[$0] == false })
                let added = ids.filter { states[$0] == true && !previousSet.contains($0) }
                desiredOrder = previousOrder.filter { !removed.contains($0) } + added
            }
            try Self.replaceManualCollectionOrder(db, id: collection, order: desiredOrder)
            return OrderedMembershipChange(inverse: inverse, previousOrder: previousOrder,
                                           changed: !inverse.isEmpty || desiredOrder != previousOrder)
        }
    }
    /// The current relative order of a regular collection. The implicit
    /// membership.rowid is intentionally an implementation detail: it is
    /// useful for the current catalog's order, but callers must not persist it
    /// as an external identifier.
    func collectionOrder(_ collection: String) throws -> [String] {
        try database.read { db in
            try Self.requireManualOrderCollection(db, id: collection)
            return try String.fetchAll(db, sql: "SELECT photoID FROM membership WHERE collectionID=? ORDER BY rowid ASC", arguments: [collection])
        }
    }
    /// Reorder selected real members before `before`, or append them when nil.
    /// Hidden members remain in their original relative positions because the
    /// operation starts from the complete collection order, not the filtered
    /// page passed by the UI. Returns the complete order before the change for
    /// one-step undo.
    @discardableResult func reorderCollection(_ collection: String, moving ids: [String], before: String? = nil) throws -> [String] {
        try database.write { db in
            try Self.requireManualOrderCollection(db, id: collection)
            let old = try Self.readManualCollectionOrder(db, id: collection)
            var unique = [String](), seen = Set<String>()
            for id in ids where seen.insert(id).inserted { unique.append(id) }
            let uniqueSet = Set(unique)
            let moving = old.filter { uniqueSet.contains($0) }
            guard uniqueSet.isSubset(of: Set(old)) else {
                throw LRCError(L10n.text("app.aMemberBeingReorderedIsNoLongerInThe", defaultValue: "A member being reordered is no longer in the collection. Refresh and try again"))
            }
            guard let before else {
                let movingSet = Set(moving)
                let rest = old.filter { !movingSet.contains($0) }
                try Self.replaceManualCollectionOrder(db, id: collection, order: rest + moving)
                return old
            }
            let movingSet = Set(moving)
            guard old.contains(before), !movingSet.contains(before) else {
                throw LRCError(L10n.text("app.theReorderTargetChangedRefreshAndTryAgain", defaultValue: "The reorder target changed. Refresh and try again"))
            }
            var rest = old.filter { !movingSet.contains($0) }
            guard let index = rest.firstIndex(of: before) else { throw LRCError(L10n.text("app.theReorderTargetChangedRefreshAndTryAgain", defaultValue: "The reorder target changed. Refresh and try again")) }
            rest.insert(contentsOf: moving, at: index)
            try Self.replaceManualCollectionOrder(db, id: collection, order: rest)
            return old
        }
    }
    /// Replace a regular collection's complete member order. This is used by
    /// AppModel after membership add/remove during undo so that re-inserting a
    /// row does not silently move it to the end.
    @discardableResult func restoreCollectionOrder(_ collection: String, order: [String]) throws -> [String] {
        try database.write { db in
            try Self.requireManualOrderCollection(db, id: collection)
            let old = try Self.readManualCollectionOrder(db, id: collection)
            try Self.replaceManualCollectionOrder(db, id: collection, order: order)
            return old
        }
    }
    private static func requireManualOrderCollection(_ db: Database, id: String) throws {
        guard let collection = try PhotoCollection.fetchOne(db, key: id), !collection.isSmart else {
            throw LRCError(L10n.text("app.onlyRegularCollectionsSupportManualOrdering", defaultValue: "Only regular collections support manual ordering"))
        }
    }
    private static func readManualCollectionOrder(_ db: Database, id: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT photoID FROM membership WHERE collectionID=? ORDER BY rowid ASC", arguments: [id])
    }
    private static func replaceManualCollectionOrder(_ db: Database, id: String, order: [String]) throws {
        guard Set(order).count == order.count else { throw LRCError(L10n.text("app.collectionOrderContainsDuplicateMembers", defaultValue: "Collection order contains duplicate members")) }
        let current = try readManualCollectionOrder(db, id: id)
        guard Set(current) == Set(order), current.count == order.count else {
            throw LRCError(L10n.text("app.collectionMembersChangedRefreshAndTryAgain", defaultValue: "Collection members changed. Refresh and try again"))
        }
        try db.execute(sql: "DELETE FROM membership WHERE collectionID=?", arguments: [id])
        let statement = try db.makeStatement(sql: "INSERT INTO membership(collectionID,photoID) VALUES (?,?)")
        for photoID in order { try statement.execute(arguments: [id, photoID]) }
    }
    func backup(to destination: URL) throws {
        let staging = try SafeFileWriter.stage(in: destination.deletingLastPathComponent())
        do {
            let target = try DatabaseQueue(path: staging.path)
            try database.backup(to: target)
            try Self.validate(target)
            try target.close()
            try SafeFileWriter.publish(staging, to: destination)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
    }
    static func validate(_ queue: DatabaseQueue) throws {
        try queue.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM (SELECT s.id FROM displayStack s LEFT JOIN stackMember m ON m.stackID=s.id GROUP BY s.id HAVING count(m.photoID)<2 OR min(m.position)<>0 OR max(m.position)<>count(m.photoID)-1)") == 0,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM stackMember m JOIN photo p ON p.id=m.photoID WHERE p.deleted<>0") == 0,
                  (try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0) == schemaVersion,
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM catalogMeta") == 1,
                  try Int.fetchOne(db,sql:"SELECT schemaVersion FROM catalogMeta") == schemaVersion,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM photo WHERE colorLabel NOT BETWEEN 0 AND 5 OR colorLabel IS NULL OR caption IS NULL OR typeof(caption)<>'text' OR length(caption)>8000") == 0,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM adjustmentPreset WHERE groupName IS NULL OR length(trim(groupName))>100 OR favorite NOT IN (0,1) OR favorite IS NULL") == 0,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM localParameterPreset WHERE length(trim(name)) NOT BETWEEN 1 AND 100 OR parameters IS NULL") == 0,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM sourceCopyOrigin WHERE length(originKey)=0") == 0,
                  try Int.fetchOne(db,sql:"SELECT count(*) FROM (SELECT sourceID FROM (SELECT rawSourceID AS sourceID FROM rawJpegPair UNION ALL SELECT jpegSourceID FROM rawJpegPair) GROUP BY sourceID HAVING count(*)>1)") == 0 else { throw LRCError(L10n.text("app.catalogValidationFailed", defaultValue: "Catalog validation failed")) }
        }
    }
    /// Recovery always creates a fresh working directory; never overwrites the open catalog.
    static func restore(from source: URL, to directory: URL) throws -> CatalogStore {
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw LRCError(L10n.text("app.restoreIntoANewWorkingDirectory", defaultValue: "Restore into a new working directory")) }
        var config = Configuration(); config.readonly = true
        let original = try DatabaseQueue(path: source.path, configuration: config)
        try validate(original)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try DatabaseQueue(path: directory.appendingPathComponent("Catalog.sqlite").path)
        try original.backup(to: destination)
        try validate(destination)
        try destination.close(); try original.close()
        return try CatalogStore(directory: directory)
    }
    static func restore(from source: URL, toFile destination: URL, access: AccessLease? = nil) throws -> CatalogStore {
        var config = Configuration(); config.readonly = true
        let original = try DatabaseQueue(path: source.path, configuration: config)
        defer { try? original.close() }
        try validate(original)
        let staging = try SafeFileWriter.stage(in: destination.deletingLastPathComponent())
        do {
            let copy = try DatabaseQueue(path: staging.path)
            try original.backup(to: copy); try validate(copy); try copy.close()
            try SafeFileWriter.publish(staging, to: destination)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
        return try CatalogStore(fileURL: destination, access: access)
    }
    func exportManifest(to url: URL) throws {
        // One database snapshot, with readable recipe objects and no sandbox bookmarks.
        let data = try database.read { db -> Data in
            let photos = try Photo.fetchAll(db)
            let roots = try StorageRoot.fetchAll(db)
            let collections = try PhotoCollection.fetchAll(db)
            var records = [[String: Any]]()
            for photo in photos {
                var value: [String: Any] = ["id": photo.id, "rootID": photo.rootID, "relativePath": photo.relativePath,
                    "rating": photo.rating, "flag": photo.flag, "colorLabel": photo.colorLabel, "sourceRevision": photo.revision, "recipeRevision": photo.recipeRevision,
                    "availability": photo.availability, "sourceID": photo.sourceKey, "versionName": photo.versionName, "virtualCopy": photo.isVirtualCopy, "width": photo.width, "height": photo.height]
                value["sha256"] = photo.digest; value["captureDate"] = photo.captureDate; value["camera"] = photo.camera
                value["caption"] = photo.caption
                value["keywords"] = try String.fetchAll(db, sql: "SELECT name FROM photoKeyword WHERE photoID=? ORDER BY keyword", arguments: [photo.id])
                if let metadata = photo.metadata { value["metadata"] = try JSONSerialization.jsonObject(with: metadata) }
                if let recipe = photo.recipe { value["recipe"] = try JSONSerialization.jsonObject(with: recipe) }
                for table in ["editHistory", "editSnapshot"] {
                    value[table] = try Row.fetchAll(db, sql: "SELECT id,title,createdAt,recipe FROM \(table) WHERE photoID=? ORDER BY createdAt", arguments: [photo.id]).map { row -> [String: Any] in
                        let data: Data = row["recipe"]
                        let title: String = row["title"]
                        let createdAt: Double = row["createdAt"]
                        return ["title": title, "createdAt": createdAt, "recipe": try JSONSerialization.jsonObject(with: data)]
                    }
                }
                records.append(value)
            }
            let memberships = try Row.fetchAll(db, sql: "SELECT collectionID,photoID FROM membership").map { row -> [String: String] in ["collectionID": row["collectionID"], "photoID": row["photoID"]] }
            let attachments = try Row.fetchAll(db, sql: "SELECT * FROM attachment").map { row -> [String: String] in ["photoID": row["photoID"], "relativePath": row["relativePath"], "sha256": row["digest"]] }
            let presets = try AdjustmentPreset.fetchAll(db).map { preset -> [String: Any] in
                ["id": preset.id, "name": preset.name, "groupName": preset.groupName, "favorite": preset.favorite, "recipe": try JSONSerialization.jsonObject(with: preset.recipe),
                 "options": try JSONSerialization.jsonObject(with: preset.options)]
            }
            let value: [String: Any] = ["sourceCopyOrigins": try Row.fetchAll(db,sql:"SELECT sourceID,originKey FROM sourceCopyOrigin ORDER BY sourceID").map { row -> [String:String] in ["sourceID":row["sourceID"],"originKey":row["originKey"]] }, "rawJpegPairs": try JSONSerialization.jsonObject(with:JSONEncoder().encode(RawJpegPair.fetchAll(db))), "stacks": try JSONSerialization.jsonObject(with:JSONEncoder().encode(Self.readStacks(db))), "schemaVersion": 3, "photos": records, "presets": presets, "localParameterPresets": try LocalParameterPreset.fetchAll(db).map { ["id": $0.id, "name": $0.name, "parameters": try JSONSerialization.jsonObject(with: $0.parameters)] },
                "roots": roots.map { ["id": $0.id, "label": $0.label, "path": $0.path] },
                "collections": try collections.map { c -> [String:Any] in
                    var value:[String:Any] = ["id":c.id,"name":c.name]
                    if let rules = c.rules { value["rules"] = try JSONSerialization.jsonObject(with:rules) }; return value
                }, "memberships": memberships, "attachments": attachments]
            return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        }
        try SafeFileWriter.write(data, to: url)
    }
}

/// The inverse of one membership edit together with the complete collection
/// order that preceded it. Both pieces are restored by one catalog write so a
/// membership undo cannot leave a re-added photo appended after its peers.
struct OrderedMembershipChange: Equatable {
    let inverse: [String: Bool]
    let previousOrder: [String]
    let changed: Bool

    /// Alias kept close to the SQL/API vocabulary used by callers.
    var oldOrder: [String] { previousOrder }
}

extension CatalogStore {
    // Behavior adapted from LightCraft 4f0b110 organize.rs (MIT; see third-party notice).
    // Source identity belongs to photoSource, never another version, so deleting
    // the initially imported version cannot break its siblings.
    func versions(sourceID: String) throws -> [Photo] {
        try database.read { try Photo.fetchAll($0, sql:"SELECT * FROM photo WHERE sourceID=? AND deleted=0 ORDER BY (copyName IS NOT NULL),copyName,id", arguments:[sourceID]) }
    }
    func createVirtualCopies(ids: Set<String>, recipeOverride: EditRecipe? = nil, historyTitle: String = L10n.text("app.createVirtualCopy", defaultValue: "Create Virtual Copy")) throws -> [Photo] {
        guard recipeOverride == nil || ids.count == 1 else { throw LRCError(L10n.text("app.aHistoryStateCanOnlyBeUsedForOne", defaultValue: "A history state can only be used for one copy of its corresponding photo")) }
        return try database.write { db in
            var copies = [Photo]()
            for id in ids.sorted() {
                guard let original = try Photo.fetchOne(db,key:id), !original.deleted else { throw LRCError(L10n.text("app.theSelectedVersionNoLongerExistsNoCopyWas", defaultValue: "The selected version no longer exists. No copy was created")) }
                if let data = original.recipe { try JSONDecoder().decode(EditRecipe.self,from:data).validate(for:original) }
                let names = Set(try String.fetchAll(db,sql:"SELECT copyName FROM photo WHERE sourceID=? AND copyName IS NOT NULL",arguments:[original.sourceKey]))
                var number = 1
                while names.contains(L10n.text("app.copy_458", defaultValue: "Copy \(number)")) { number += 1 }
                var copy = original
                if let recipeOverride {
                    try recipeOverride.validate(for: original)
                    let current = try original.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) }
                    guard recipeOverride.sourceDigest == (original.digest ?? current?.sourceDigest) else { throw LRCError(L10n.text("app.thePhotoSourceChangedNoCopyWasCreated", defaultValue: "The photo source changed. No copy was created")) }
                    copy.recipe = try JSONEncoder().encode(recipeOverride)
                }
                copy.id = UUID().uuidString; copy.sourceID = original.sourceKey; copy.copyName = L10n.text("app.copy_458", defaultValue: "Copy \(number)")
                copy.recipeRevision = 0; copy.deleted = false
                try copy.insert(db)
                try db.execute(sql:"INSERT INTO photoKeyword SELECT ?,keyword,name FROM photoKeyword WHERE photoID=?",arguments:[copy.id,id])
                try db.execute(sql:"INSERT INTO membership SELECT collectionID,? FROM membership WHERE photoID=?",arguments:[copy.id,id])
                // Attachments and repair assets remain retained by the shared source;
                // embedded masks/repair data are value-copied in the recipe.
                try db.execute(sql:"INSERT INTO attachment SELECT ?,relativePath,digest FROM attachment WHERE photoID=?",arguments:[copy.id,id])
                if let data = copy.recipe {
                    try db.execute(sql:"INSERT INTO editHistory(photoID,title,createdAt,recipe) VALUES (?,?,?,?)",arguments:[copy.id,historyTitle,Date().timeIntervalSince1970,data])
                }
                var stacks = try Self.readStacks(db)
                if let i = stacks.firstIndex(where: { $0.members.contains(id) }), let at = stacks[i].members.firstIndex(of:id) {
                    stacks[i].members.insert(copy.id,at:at+1); stacks[i].collapsed = false
                    try Self.writeStacks(stacks,db:db)
                }
                copies.append(copy)
            }
            return copies
        }
    }
    func renameVersion(id: String, name: String) throws -> String {
        let value = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (1...100).contains(value.count), value.rangeOfCharacter(from:.controlCharacters) == nil else { throw LRCError(L10n.text("app.copyNamesMustContain1100CharactersWithoutControl", defaultValue: "Copy names must contain 1–100 characters without control characters")) }
        return try database.write { db in
            guard let photo = try Photo.fetchOne(db,key:id), !photo.deleted, let previous = photo.copyName else { throw LRCError(L10n.text("app.onlyExistingVirtualCopiesCanBeRenamed", defaultValue: "Only existing virtual copies can be renamed")) }
            try db.execute(sql:"UPDATE photo SET copyName=? WHERE id=?",arguments:[value,id])
            return previous
        }
    }
    /// Catalog-only deletion. Retain recipes, history, attachments and original
    /// bytes for undo and source siblings. No filesystem deletion or asset GC.
    func setVersionDeletion(_ states: [String: Bool], restoringStacks: [PhotoStack]? = nil) throws -> [String: Bool] {
        try database.write { db in
            var inverse = [String: Bool]()
            for (id,deleted) in states {
                guard let photo = try Photo.fetchOne(db,key:id) else { throw LRCError(L10n.text("app.theVersionDoesNotExist", defaultValue: "The version does not exist")) }
                inverse[id] = photo.deleted
                try db.execute(sql:"UPDATE photo SET deleted=? WHERE id=?",arguments:[deleted,id])
            }
            let stacks = try Self.readStacks(db).compactMap { stack -> PhotoStack? in
                var value = stack
                value.members = try value.members.filter { try Bool.fetchOne(db,sql:"SELECT deleted=0 FROM photo WHERE id=?",arguments:[$0]) == true }
                return value.members.count >= 2 ? value : nil
            }
            try Self.writeStacks(restoringStacks ?? stacks,db:db)
            return inverse
        }
    }
}
