import Foundation
import GRDB

struct CatalogArchive {
    private static let indexName = ".phosdeck-archive.json"

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
        let existing = try loadIndex(file: catalog.fileURL, database: catalog.database)
        let archivedFolders: [URL] = try (existing?.folders ?? []).map { relative in
            let folder = try ProjectCopy.child(relative, of: catalog.directory)
            guard folder.resolvingSymlinksInPath().path == folder.path else { throw ProjectCopy.changed(folder) }
            return folder
        }
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
        try catalog.backup(to: file)
        let database = try DatabaseQueue(path: file.path)
        defer { try? database.close() }
        let (roots, sources, attachments) = try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT p.rootID,a.relativePath,a.digest FROM attachment a JOIN photo p ON p.id=a.photoID").map { row in
                (root: row["rootID"] as String, path: row["relativePath"] as String, digest: row["digest"] as String)
            }
            return (try StorageRoot.fetchAll(db), try CatalogSource.fetchAll(db), rows)
        }
        let before = snapshot.map { ($0.id, $0.path, $0.bookmark) }
        let after = roots.sorted { $0.path < $1.path }.map { ($0.id, $0.path, $0.bookmark) }
        guard before.elementsEqual(after, by: { $0 == $1 }) else {
            throw ProjectCopy.changed(catalog.fileURL)
        }

        var mappings: [String: String] = [:]
        var entries: [Entry] = []
        var folders: [String] = []
        var labels = Set<String>()
        let catalogFiles = Set(["", ".lock", "-journal", "-wal", "-shm"].map { catalog.fileURL.path + $0 } +
                               [catalog.directory.appendingPathComponent(indexName).path] +
                               (catalog.fileURL.lastPathComponent == "Catalog.sqlite" ? [catalog.directory.appendingPathComponent("Catalog.lock").path] : []))
        for folder in top {
            try Task.checkCancellation()
            let name = folder.lastPathComponent.isEmpty ? "Files" : folder.lastPathComponent
            var label = name
            var suffix = 2
            while !labels.insert(ExportNamingPlanner.collisionKey(label)).inserted { label = "\(name) \(suffix)"; suffix += 1 }
            let relative = "Files/" + label
            folders.append(relative)
            for root in roots {
                let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
                guard ProjectCopy.contains(folder, rootURL) else { continue }
                let suffix = rootURL.path == folder.path ? "" : "/" + rootURL.path.dropFirst(folder.path == "/" ? 1 : folder.path.count + 1)
                mappings[root.id] = relative + suffix
            }
            try collect(folder, relative: relative, excluding: catalogFiles, entries: &entries)
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
        let files = entries.filter { !$0.directory }
        let bytes = files.reduce(Int64(0)) { $0 + min($1.identity.size, Int64.max - $0) }
        try SafeFileWriter.requireCapacity(in: project.staging, bytes: bytes)
        await progress(0, files.count)
        var identities: [String: (FileIdentity, String)] = [:]
        var done = 0
        for entry in entries {
            try Task.checkCancellation()
            let target = try ProjectCopy.child(entry.relative, of: project.staging)
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
                try SafeFileWriter.flush(ProjectCopy.child(entry.relative, of: project.staging))
            } else {
                guard try FileIdentity.read(entry.url) == entry.identity else { throw ProjectCopy.changed(entry.url) }
            }
        }
        if !top.isEmpty { try SafeFileWriter.flush(project.staging.appendingPathComponent("Files", isDirectory: true)) }
        let locations = try mappings.mapValues { relative in
            Location(path: relative, directoryIdentity: try ProjectCopy.directoryIdentity(ProjectCopy.child(relative, of: project.staging)).key)
        }

        let id = UUID().uuidString
        try await database.write { [mappings, identities] db in
            try db.execute(sql: "UPDATE catalogMeta SET id=?", arguments: [id])
            for root in roots {
                guard let relative = mappings[root.id] else { throw missing(root.path) }
                let new = try ProjectCopy.child(relative, of: destination)
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
        try writeIndex(Index(catalogID: id, roots: locations, folders: folders), in: project.staging)
        let fileIdentity = try FileIdentity.read(file)
        try project.publish()
        let published = destination.appendingPathComponent(file.lastPathComponent)
        do { try CatalogStore.verifyBackup(published, identity: fileIdentity) }
        catch { throw LRCError(L10n.text("project.publishedNeedsVerification", defaultValue: "The project was published but needs verification:") + "\n" + published.path + "\n" + error.localizedDescription) }
        return published
    }

    /// Regrant access within the opened project and rebind verified copies after a move to another disk.
    static func restoreRoots(file: URL, database: DatabaseQueue) throws {
        let parent = file.deletingLastPathComponent()
        guard let index = try loadIndex(file: file, database: database) else { return }
        let roots = try database.read { try StorageRoot.fetchAll($0) }
        var updates: [(StorageRoot, URL, Data, [(String, FileIdentity?)])] = []
        for root in roots {
            try Task.checkCancellation()
            guard let mapping = index.roots[root.id], root.path.hasSuffix("/" + mapping.path) else { continue }
            let location = try ProjectCopy.child(mapping.path, of: parent)
            guard location.resolvingSymlinksInPath().path == location.path else { throw ProjectCopy.changed(location) }
            let lease = try? AccessLease(bookmark: root.bookmark)
            let folderIdentity = try? ProjectCopy.directoryIdentity(location)
            let present = folderIdentity != nil
            let sameDirectory = folderIdentity?.key == mapping.directoryIdentity
            let authorized = root.path == location.path && lease?.url.resolvingSymlinksInPath().path == location.path
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
        guard !updates.isEmpty else { return }
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
    }

    static func hasIndex(beside file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent(indexName).path)
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

    private static func loadIndex(file: URL, database: DatabaseQueue) throws -> Index? {
        guard hasIndex(beside: file) else { return nil }
        let url = file.deletingLastPathComponent().appendingPathComponent(indexName)
        let identity = try FileIdentity.read(url)
        guard identity.size <= 1_048_576 else { throw ProjectCopy.changed(url) }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
        return try database.read { try String.fetchOne($0, sql: "SELECT id FROM catalogMeta") == index.catalogID } ? index : nil
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
