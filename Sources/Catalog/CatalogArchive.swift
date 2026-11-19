import Foundation
import GRDB

struct CatalogArchive {
    private static let indexName = ".phosdeck-archive.json"
    private static let stageFolder = ".phosdeck-plugin-stages"
    private static let filesExtension = "phoscat-files"

    struct Index: Codable {
        let catalogID: String
        let roots: [String: Location]
        let folders: [String]
    }
    struct Location: Codable {
        let path: String
        let directoryIdentity: String
    }

    private struct Entry {
        let relative: String
        let url: URL
        let identity: FileIdentity
        let directory: Bool
    }

    static func create(catalog: CatalogStore, destination: URL, extras: [URL],
                       progress: (Int, Int) async -> Void = { _, _ in }) async throws -> URL {
        let snapshot = try await catalog.database.read { db in
            try StorageRoot.fetchAll(db, sql: "SELECT * FROM storageRoot ORDER BY path")
        }
        let recorded = try snapshot.map { root -> (StorageRoot, AccessLease) in
            let lease = try AccessLease(bookmark: root.bookmark)
            guard lease.url.resolvingSymlinksInPath().path == root.path else { throw ProjectCopy.changed(lease.url) }
            return (root, lease)
        }
        let extraLeases = extras.map { AccessLease(url: $0) }
        defer { withExtendedLifetime((recorded, extraLeases)) {} }
        let archivedFolders: [URL] = try loadProject(file: catalog.fileURL, database: catalog.database).map { archive in
            try archive.index.folders.map { relative in
                let folder = try ProjectCopy.child(relative, of: archive.directory)
                guard folder.resolvingSymlinksInPath().path == folder.path else { throw ProjectCopy.changed(folder) }
                return folder
            }
        } ?? []
        let directories = Set((recorded.map { $0.1.url } + archivedFolders + extras).map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let top = directories.sorted { $0.path < $1.path }.filter { folder in
            !directories.contains { $0.path != folder.path && ProjectCopy.contains($0, folder) }
        }
        let destination = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        guard !top.contains(where: { ProjectCopy.contains($0, destination) }),
              !ProjectCopy.contains(destination, catalog.fileURL) else {
            throw LRCError(L10n.text("archive.destinationInsideSource", defaultValue: "Choose a destination outside the project folders."))
        }
        let project = try ProjectCopy(destination: destination)
        defer { project.discard() }
        let file = project.staging.appendingPathComponent(CatalogFile.filename(destination.lastPathComponent))
        let contents = filesDirectory(beside: file)
        let finalContents = destination.appendingPathComponent(contents.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
        try catalog.backup(to: file)
        let database = try DatabaseQueue(path: file.path)
        defer { try? database.close() }
        let (roots, sources, attachments, pluginStages) = try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT p.rootID,a.relativePath,a.digest FROM attachment a JOIN photo p ON p.id=a.photoID").map { row in
                (root: row["rootID"] as String, path: row["relativePath"] as String, digest: row["digest"] as String)
            }
            return (try StorageRoot.fetchAll(db), try CatalogSource.fetchAll(db), rows, try PluginStageFiles.references(in: db))
        }
        let before = snapshot.map { ($0.id, $0.path, $0.bookmark) }
        let after = roots.sorted { $0.path < $1.path }.map { ($0.id, $0.path, $0.bookmark) }
        guard before.elementsEqual(after, by: { $0 == $1 }) else {
            throw ProjectCopy.changed(catalog.fileURL)
        }

        var mappings: [String: String] = [:]
        var entries: [Entry] = []
        var folders: [String] = []
        var labels = Set([indexName, stageFolder].map(ExportNamingPlanner.collisionKey))
        var catalogFiles = Set(["", ".lock", "-journal", "-wal", "-shm"].map { catalog.fileURL.path + $0 })
        catalogFiles.insert(CatalogLock.url(for: catalog.fileURL).path)
        for directory in [catalog.directory, filesDirectory(beside: catalog.fileURL)] {
            catalogFiles.insert(directory.appendingPathComponent(indexName).path)
            catalogFiles.insert(directory.appendingPathComponent(stageFolder).path)
        }
        for folder in top {
            try Task.checkCancellation()
            let name = folder.lastPathComponent.isEmpty ? "Files" : folder.lastPathComponent
            var label = name
            var suffix = 2
            while !labels.insert(ExportNamingPlanner.collisionKey(label)).inserted { label = "\(name) \(suffix)"; suffix += 1 }
            folders.append(label)
            for root in roots {
                let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
                guard ProjectCopy.contains(folder, rootURL) else { continue }
                let suffix = rootURL.path == folder.path ? "" : "/" + rootURL.path.dropFirst(folder.path == "/" ? 1 : folder.path.count + 1)
                mappings[root.id] = label + suffix
            }
            try collect(folder, relative: label, excluding: catalogFiles, entries: &entries)
        }
        var byPath: [String: Entry] = [:]
        var paths = Set<String>()
        for entry in entries {
            guard paths.insert(ExportNamingPlanner.collisionKey(entry.relative)).inserted else { throw ProjectCopy.changed(entry.url) }
            byPath[entry.relative] = entry
        }
        var expected: [String: CatalogSource] = [:]
        var digests: [String: String] = [:]
        for source in sources {
            let relative = try mapped(source.relativePath, root: source.rootID, in: mappings)
            guard let entry = byPath[relative], !entry.directory else { throw missing(relative) }
            expected[relative] = source
            digests[relative] = source.digest
        }
        for row in attachments {
            let relative = try mapped(row.path, root: row.root, in: mappings)
            let digest = row.digest
            guard let entry = byPath[relative], !entry.directory else { throw missing(relative) }
            guard digests[relative] == nil || digests[relative] == digest else { throw ProjectCopy.changed(entry.url) }
            digests[relative] = digest
        }
        if !pluginStages.isEmpty {
            let folder = contents.appendingPathComponent(stageFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for stage in pluginStages {
                let source = try PluginStageFiles.url(stage, create: false)
                let identity = try FileIdentity.read(source)
                guard identity.size == Int64(stage.width) * Int64(stage.height) * 16 else { throw ProjectCopy.changed(source) }
                let relative = stageFolder + "/" + stage.fileName
                entries.append(Entry(relative: relative, url: source, identity: identity, directory: false))
                digests[relative] = stage.digest
            }
        }
        let files = entries.filter { !$0.directory }
        let bytes = files.reduce(Int64(0)) { $0 + min($1.identity.size, Int64.max - $0) }
        try SafeFileWriter.requireCapacity(in: project.staging, bytes: bytes)
        await progress(0, files.count)
        var identities: [String: (FileIdentity, String)] = [:]
        var done = 0
        for entry in entries {
            try Task.checkCancellation()
            let target = try ProjectCopy.child(entry.relative, of: contents)
            if entry.directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                guard try FileIdentity.read(entry.url) == entry.identity else { throw ProjectCopy.changed(entry.url) }
                let original = try expected[entry.relative].map { try JSONDecoder().decode(FileIdentity.self, from: $0.identity) }
                let result = try ProjectCopy.copy(entry.url, to: target, expected: original, digest: digests[entry.relative])
                if let source = expected[entry.relative] { identities[source.id] = (result.identity, result.digest) }
                done += 1
                if done % 16 == 0 || done == files.count { await progress(done, files.count) }
            }
        }
        for entry in entries.reversed() {
            try Task.checkCancellation()
            if entry.directory {
                guard try ProjectCopy.directoryIdentity(entry.url) == entry.identity else { throw ProjectCopy.changed(entry.url) }
                try SafeFileWriter.flush(ProjectCopy.child(entry.relative, of: contents))
            } else {
                guard try FileIdentity.read(entry.url) == entry.identity else { throw ProjectCopy.changed(entry.url) }
            }
        }
        if !pluginStages.isEmpty { try SafeFileWriter.flush(contents.appendingPathComponent(stageFolder, isDirectory: true)) }
        let locations = try mappings.mapValues { relative in
            Location(path: relative, directoryIdentity: try ProjectCopy.directoryIdentity(ProjectCopy.child(relative, of: contents)).key)
        }

        let id = UUID().uuidString
        try await database.write { [mappings, identities] db in
            try db.execute(sql: "UPDATE catalogMeta SET id=?", arguments: [id])
            for root in roots {
                guard let relative = mappings[root.id] else { throw missing(root.path) }
                let new = try ProjectCopy.child(relative, of: finalContents)
                try db.execute(sql: "UPDATE storageRoot SET path=?,bookmark=? WHERE id=?", arguments: [new.path, Data(), root.id])
            }
            for source in sources {
                try Task.checkCancellation()
                guard let (identity, digest) = identities[source.id] else { throw missing(source.relativePath) }
                try db.execute(sql: "UPDATE photoSource SET identity=?,identityKey=?,digest=?,availability='available' WHERE id=?",
                               arguments: [try JSONEncoder().encode(identity), identity.key, digest, source.id])
            }
            try db.execute(sql: "UPDATE exportItem SET state='archived:' || state WHERE state NOT LIKE 'archived:%'")
            for row in try Row.fetchAll(db, sql: "SELECT id,payload FROM importPlan WHERE state NOT LIKE 'archived:%'") {
                let payload: Data = row["payload"]
                var plan = try JSONDecoder().decode(CopyPlan.self, from: payload)
                plan.state = "archived:" + plan.state
                try db.execute(sql: "UPDATE importPlan SET state=?,payload=? WHERE id=?",
                               arguments: [plan.state, try JSONEncoder().encode(plan), row["id"] as String])
            }
        }
        try CatalogStore.validate(database)
        try database.close()
        try SafeFileWriter.flush(file)
        try writeIndex(Index(catalogID: id, roots: locations, folders: folders), in: contents)
        try SafeFileWriter.flush(contents)
        let fileIdentity = try FileIdentity.read(file)
        try project.publish()
        let published = destination.appendingPathComponent(file.lastPathComponent)
        do { try CatalogStore.verifyBackup(published, identity: fileIdentity) }
        catch { throw LRCError(L10n.text("project.publishedNeedsVerification", defaultValue: "The project was published but needs verification:") + "\n" + published.path + "\n" + error.localizedDescription) }
        return published
    }

    /// Regrant access within the opened project and rebind verified copies after a move to another disk.
    static func restoreRoots(file: URL, database: DatabaseQueue) throws -> [String] {
        let parent = file.deletingLastPathComponent()
        guard let archive = try loadProject(file: file, database: database) else { return [] }
        let prefix = archive.directory.path == parent.path ? "" : archive.directory.lastPathComponent + "/"
        let stages = try database.read { try PluginStageFiles.references(in: $0) }
        let stageWarnings = try restorePluginStages(stages, from: archive.directory.appendingPathComponent(stageFolder, isDirectory: true))
        let roots = try database.read { try StorageRoot.fetchAll($0) }
        var updates: [(StorageRoot, URL, Data, [(String, FileIdentity?)])] = []
        for root in roots {
            try Task.checkCancellation()
            guard let mapping = archive.index.roots[root.id], root.path.hasSuffix("/" + prefix + mapping.path) else { continue }
            let location = try ProjectCopy.child(mapping.path, of: archive.directory)
            guard location.resolvingSymlinksInPath().path == location.path else { throw ProjectCopy.changed(location) }
            let lease = try? AccessLease(bookmark: root.bookmark)
            let folderIdentity = try? ProjectCopy.directoryIdentity(location)
            let present = folderIdentity != nil
            let sameDirectory = folderIdentity?.key == mapping.directoryIdentity
            let authorized = root.path == location.path && lease?.scoped == true &&
                lease?.url.resolvingSymlinksInPath().path == location.path
            let alreadyVerified = try authorized && !sameDirectory && present && sourceIdentityMatches(in: location, root: root, database: database)
            if authorized && (sameDirectory || alreadyVerified) { continue }
            let bookmark = present ? try AccessLease.bookmark(location, readOnly: true) : Data()
            let sources = try database.read { try CatalogSource.fetchAll($0, sql: "SELECT * FROM photoSource WHERE rootID=?", arguments: [root.id]) }
            let verified = try sources.map { source -> (String, FileIdentity?) in
                try Task.checkCancellation()
                let url = try ProjectCopy.child(source.relativePath, of: location)
                guard present, url.resolvingSymlinksInPath().path == url.path, let identity = try? FileIdentity.read(url) else { return (source.id, nil) }
                let old = try JSONDecoder().decode(FileIdentity.self, from: source.identity)
                if sameDirectory, identity == old { return (source.id, identity) }
                guard let digest = source.digest, (try? SafeFileWriter.sha256(url)) == digest,
                      (try? FileIdentity.read(url)) == identity else { return (source.id, nil) }
                return (source.id, identity)
            }
            updates.append((root, location, bookmark, verified))
        }
        guard !updates.isEmpty else { return stageWarnings }
        try database.write { db in
            for (root, location, bookmark, verified) in updates {
                try db.execute(sql: "UPDATE storageRoot SET path=?,bookmark=? WHERE id=?", arguments: [location.path, bookmark, root.id])
                for (id, identity) in verified {
                    if let identity {
                        try db.execute(sql: "UPDATE photoSource SET identity=?,identityKey=?,availability='available' WHERE id=?",
                                       arguments: [try JSONEncoder().encode(identity), identity.key, id])
                    } else { try db.execute(sql: "UPDATE photoSource SET availability='changed' WHERE id=?", arguments: [id]) }
                }
            }
        }
        return stageWarnings
    }

    private static func restorePluginStages(_ stages: [FrozenPluginStage], from folder: URL) throws -> [String] {
        var failures = 0
        for stage in stages {
            try Task.checkCancellation()
            let target = try PluginStageFiles.url(stage)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try PluginStageFiles.check(stage, at: target)
                } else {
                    let source = folder.appendingPathComponent(stage.fileName)
                    let identity = try FileIdentity.read(source)
                    guard identity.size == Int64(stage.width) * Int64(stage.height) * 16 else { throw ProjectCopy.changed(source) }
                    try SafeFileWriter.requireCapacity(in: target.deletingLastPathComponent(), bytes: identity.size)
                    do { try ProjectCopy.copy(source, to: target, expected: identity, digest: stage.digest) }
                    catch {
                        guard (try? PluginStageFiles.check(stage, at: target)) != nil else { throw error }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failures += 1 }
        }
        return failures == 0 ? [] : [L10n.text("plugins.archiveStagesMissing", defaultValue: "\(failures) Warm Print stage files from the archive could not be restored.")]
    }

    static func filesDirectory(beside file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension(filesExtension)
    }

    static func hasIndex(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(indexName).path)
    }

    static func hasIndex(beside file: URL) -> Bool {
        hasIndex(in: filesDirectory(beside: file)) || hasIndex(in: file.deletingLastPathComponent())
    }

    static func accessFiles(beside file: URL) throws -> AccessLease? {
        let directory = filesDirectory(beside: file)
        guard hasIndex(in: directory) else { return nil }
        let identity = try ProjectCopy.directoryIdentity(directory)
        return try CatalogRelatedFile.coordinate(directory, beside: file) { url in
            guard url.standardizedFileURL.path == directory.path,
                  try ProjectCopy.directoryIdentity(url) == identity else { throw ProjectCopy.changed(directory) }
            let lease = try AccessLease(bookmark: AccessLease.bookmark(url, readOnly: true))
            guard lease.scoped, lease.url.standardizedFileURL.path == directory.path,
                  try ProjectCopy.directoryIdentity(lease.url) == identity else { throw ProjectCopy.changed(directory) }
            return lease
        }
    }

    static func writeIndex(_ index: Index, in directory: URL) throws {
        try SafeFileWriter.write(try JSONEncoder().encode(index), to: directory.appendingPathComponent(indexName))
    }

    private static func sourceIdentityMatches(in folder: URL, root: StorageRoot, database: DatabaseQueue) throws -> Bool {
        try database.read { db in
            guard let source = try CatalogSource.fetchOne(db, sql: "SELECT * FROM photoSource WHERE rootID=? AND availability='available' LIMIT 1", arguments: [root.id]) else { return false }
            let expected = try JSONDecoder().decode(FileIdentity.self, from: source.identity)
            let url = try ProjectCopy.child(source.relativePath, of: folder)
            return (try? FileIdentity.read(url)) == expected
        }
    }

    private static func loadProject(file: URL, database: DatabaseQueue) throws -> (directory: URL, index: Index)? {
        for directory in [filesDirectory(beside: file), file.deletingLastPathComponent()] where hasIndex(in: directory) {
            _ = try ProjectCopy.directoryIdentity(directory)
            let url = directory.appendingPathComponent(indexName)
            let identity = try FileIdentity.read(url)
            guard identity.size <= 1_048_576 else { throw ProjectCopy.changed(url) }
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
            if try database.read({ try String.fetchOne($0, sql: "SELECT id FROM catalogMeta") == index.catalogID }) {
                return (directory, index)
            }
        }
        return nil
    }

    private static func mapped(_ relative: String, root: String, in mappings: [String: String]) throws -> String {
        guard let base = mappings[root] else { throw missing(relative) }
        let anchor = URL(fileURLWithPath: "/", isDirectory: true)
        return String(try ProjectCopy.child(base + "/" + relative, of: anchor).path.dropFirst())
    }

    private static func missing(_ path: String) -> LRCError {
        LRCError(L10n.text("archive.missingFile", defaultValue: "A catalog original or attachment is missing:") + "\n" + path)
    }

    private static func collect(_ folder: URL, relative: String, excluding: Set<String>, entries: inout [Entry]) throws {
        try Task.checkCancellation()
        entries.append(Entry(relative: relative, url: folder, identity: try ProjectCopy.directoryIdentity(folder), directory: true))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isUbiquitousItemKey]
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        for item in children where !excluding.contains(item.path) {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isUbiquitousItem != true else { throw ProjectCopy.changed(item) }
            let path = relative + "/" + item.lastPathComponent
            if values.isDirectory == true { try collect(item, relative: path, excluding: excluding, entries: &entries) }
            else { entries.append(Entry(relative: path, url: item, identity: try FileIdentity.read(item), directory: false)) }
        }
    }
}
