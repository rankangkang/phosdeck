import Darwin
import Foundation
import GRDB
import PhosdeckPluginKit

/// The stage recipes (including the operation ID) become durable together in
/// saveRecipes. The prepublication receipt bridges the filesystem/DB boundary.
struct PluginStageCommit: Codable {
    struct Change: Codable {
        let photo: Photo
        let recipe: EditRecipe
    }

    struct File: Codable {
        let name: String
        let identity: FileIdentity
        let stage: FrozenPluginStage
    }

    let operation: UUID
    let catalogID: UUID
    let title: String
    let changes: [Change]
    let expected: [Photo]
    let roots: [StorageRoot]
    let files: [File]

    var recipes: [(photo: Photo, recipe: EditRecipe)] { changes.map { ($0.photo, $0.recipe) } }

    static func prepare(catalog: CatalogStore, changes: [(photo: Photo, recipe: EditRecipe)], title: String,
                        expecting: [Photo] = [], expectingRoots: [StorageRoot] = []) async throws -> Self? {
        let needsStage = try changes.contains { try $0.recipe.requiresWarmPrintStage() }
        guard needsStage else { return nil }
        let catalogID = try identity(of: catalog)
        let operation = UUID()
        let roots = try catalog.roots()
        let pipeline = ImagePipeline()
        var new: [Change] = []
        var pending: [File] = []
        var usedRoots = Dictionary(uniqueKeysWithValues: expectingRoots.map { ($0.id, $0) })
        var ready = false
        defer { if !ready { for file in pending { try? discard(file) } } }

        for change in changes {
            try Task.checkCancellation()
            var recipe = change.recipe
            if try recipe.requiresWarmPrintStage() {
                guard let root = roots.first(where: { $0.id == change.photo.rootID }) else { throw OrganizationError.versionConflict }
                if let expected = usedRoots[root.id], expected.path != root.path || expected.bookmark != root.bookmark {
                    throw OrganizationError.versionConflict
                }
                usedRoots[root.id] = root
                let input = ImageRequest(photo: change.photo, root: root, recipe: recipe)
                let (stage, pixels) = try await pipeline.freezeWarmPrint(input, operation: operation)
                pending.append(try prepareFile(stage: stage, bytes: pixels.pixels))
                recipe.warmPrint?.frozen = stage
            }
            new.append(Change(photo: expectation(change.photo), recipe: recipe))
        }
        let receipt = Self(operation: operation, catalogID: catalogID, title: title, changes: new,
                           expected: expecting.map(expectation) + new.map(\.photo), roots: Array(usedRoots.values), files: pending)
        try Task.checkCancellation()
        ready = true
        return receipt
    }

    /// Keep the recoverable receipt on disk before exposing any stage file.
    func publish() async throws {
        try Task.checkCancellation()
        let url = try location()
        try SafeFileWriter.write(JSONEncoder().encode(self), to: url)
        try SafeFileWriter.flush(url.deletingLastPathComponent())
        try publishFiles()
    }

    func abandon() async {
        if let url = try? location(), let data = try? Data(contentsOf: url),
           let receipt = try? JSONDecoder().decode(Self.self, from: data),
           receipt.operation == operation, receipt.catalogID == catalogID {
            try? FileManager.default.removeItem(at: url)
        }
        for file in files { try? Self.discard(file) }
    }

    /// The DB transaction is the commit point. A crash after it and before
    /// removing the receipt is detected from the matching history entry.
    func commit(in catalog: CatalogStore) throws -> [Photo] {
        guard try Self.identity(of: catalog) == catalogID else { throw OrganizationError.versionConflict }
        let saved = try catalog.saveRecipes(recipes, title: title, expecting: expected, expectingRoots: roots)
        try? FileManager.default.removeItem(at: location())
        return saved
    }

    static func recover(in catalog: CatalogStore) throws -> [String] {
        let id = try identity(of: catalog)
        let dir = try receiptDirectory(id, create: false)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        var errors: [String] = []
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            guard url.pathExtension == "json", let operation = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do {
                _ = try FileIdentity.read(url)
                let receipt = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
                guard receipt.catalogID == id, receipt.operation == operation,
                      !receipt.files.isEmpty, !receipt.changes.isEmpty else { throw PluginFailure.invalidControl }
                if try receipt.isInHistory(of: catalog) {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try receipt.publishFiles()
                    do {
                        _ = try receipt.commit(in: catalog)
                    } catch is RecipeBatchConflict {
                        for item in receipt.files { try? discard(item) }
                        try FileManager.default.removeItem(at: url)
                        errors.append(L10n.text("plugins.stageRecoveryConflict", defaultValue: "A photo changed before Warm Print could be recovered. Its saved version was preserved."))
                    } catch OrganizationError.versionConflict {
                        for item in receipt.files { try? discard(item) }
                        try FileManager.default.removeItem(at: url)
                        errors.append(L10n.text("plugins.stageRecoveryConflict", defaultValue: "A photo changed before Warm Print could be recovered. Its saved version was preserved."))
                    }
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        return errors
    }

    static func hasPendingReceipts() -> Bool {
        guard let dir = try? PluginStageFiles.directory(create: false).appendingPathComponent("Receipts", isDirectory: true),
              let catalogs = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        return catalogs.contains { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  let receipts = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return false }
            return receipts.contains { $0.pathExtension == "json" }
        }
    }

    static func identity(of catalog: CatalogStore) throws -> UUID {
        let value = try catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM catalogMeta") }
        guard let value, let id = UUID(uuidString: value) else { throw OrganizationError.versionConflict }
        return id
    }

    private func isInHistory(of catalog: CatalogStore) throws -> Bool {
        guard let example = changes.first(where: { $0.recipe.warmPrint?.frozen?.operation == operation }) else {
            throw PluginFailure.invalidControl
        }
        return try catalog.database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM editHistory WHERE photoID=?
                    AND json_extract(CAST(recipe AS TEXT), '$.warmPrint.frozen.operation')=?)
                """, arguments: [example.photo.id, operation.uuidString]) ?? false
        }
    }

    private func publishFiles() throws {
        for item in files {
            let stage = item.stage
            let target = try PluginStageFiles.url(stage)
            let partial = try Self.stagedURL(item)
            if FileManager.default.fileExists(atPath: target.path) {
                try PluginStageFiles.check(stage, at: target)
                try? Self.discard(item)
                continue
            }
            guard try FileIdentity.read(partial) == item.identity else { throw PluginFailure.invalidResult }
            try PluginStageFiles.check(stage, at: partial)
            do {
                try SafeFileWriter.publish(partial, to: target)
            } catch {
                // A concurrent catalog can publish the exact same immutable content.
                guard (try? PluginStageFiles.check(stage, at: target)) != nil else { throw error }
                try? Self.discard(item)
                continue
            }
            guard try FileIdentity.read(target) == item.identity else { throw PluginFailure.invalidResult }
            try PluginStageFiles.check(stage, at: target)
        }
        try SafeFileWriter.flush(PluginStageFiles.directory())
    }

    private static func prepareFile(stage: FrozenPluginStage, bytes: Data) throws -> File {
        let dir = try PluginStageFiles.directory()
        try SafeFileWriter.requireCapacity(in: dir, bytes: Int64(bytes.count))
        let temp = try SafeFileWriter.stage(in: dir)
        let identity = try FileIdentity.read(temp)
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try PluginStageFiles.check(stage, at: temp)
            return File(name: temp.lastPathComponent, identity: try FileIdentity.read(temp), stage: stage)
        } catch {
            if (try? FileIdentity.read(temp).key) == identity.key { try? FileManager.default.removeItem(at: temp) }
            throw error
        }
    }

    private static func stagedURL(_ item: File) throws -> URL {
        guard item.name.hasPrefix(".phosdeck-"), item.name.hasSuffix(".partial"),
              UUID(uuidString: String(item.name.dropFirst(10).dropLast(8))) != nil else { throw PluginFailure.invalidControl }
        return try PluginStageFiles.directory().appendingPathComponent(item.name)
    }

    private static func discard(_ file: File) throws {
        let url = try stagedURL(file)
        if try FileIdentity.read(url) == file.identity { try FileManager.default.removeItem(at: url) }
    }

    private func location() throws -> URL {
        try Self.receiptDirectory(catalogID).appendingPathComponent(operation.uuidString + ".json")
    }

    private static func receiptDirectory(_ id: UUID, create: Bool = true) throws -> URL {
        let url = try PluginStageFiles.directory(create: create).appendingPathComponent("Receipts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    private static func expectation(_ photo: Photo) -> Photo {
        var expected = photo
        expected.recipe = nil
        return expected
    }
}

extension PluginStageFiles {
    static func references(in db: Database) throws -> [FrozenPluginStage] {
        let values = try String.fetchAll(db, sql: """
            WITH payload(value, key) AS (
                SELECT CAST(recipe AS TEXT), '$.warmPrint.frozen' FROM photo WHERE recipe IS NOT NULL
                UNION ALL SELECT CAST(recipe AS TEXT), '$.warmPrint.frozen' FROM editHistory
                UNION ALL SELECT CAST(recipe AS TEXT), '$.warmPrint.frozen' FROM editSnapshot
                UNION ALL SELECT CAST(snapshot AS TEXT), '$.request.recipe.warmPrint.frozen' FROM exportItem
            ), stages(stage) AS (
                SELECT CASE WHEN json_valid(value) THEN json_extract(value, key) END
                FROM payload WHERE instr(value, '"warmPrint"') > 0
            )
            SELECT DISTINCT stage FROM stages WHERE stage IS NOT NULL
            """)
        let decoder = JSONDecoder()
        var files: [String: FrozenPluginStage] = [:]
        for value in values {
            let stage = try decoder.decode(FrozenPluginStage.self, from: Data(value.utf8))
            try stage.validate()
            if let prior = files[stage.fileName], prior.width != stage.width || prior.height != stage.height {
                throw PluginFailure.invalidResult
            }
            files[stage.fileName] = stage
        }
        return files.values.sorted { $0.fileName < $1.fileName }
    }
}
