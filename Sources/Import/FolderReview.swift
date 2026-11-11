import Foundation
import GRDB
import Darwin

struct FolderReviewScope: Identifiable {
    let root: StorageRoot
    var directory = ""
    var id: String { root.id + ":" + directory }
    var url: URL { directory.isEmpty ? URL(fileURLWithPath: root.path) : URL(fileURLWithPath: root.path).appendingPathComponent(directory) }
}

enum FolderDifferenceKind: Int, CaseIterable {
    case added, missing, changed, moved, issue
    var title: String {
        switch self {
        case .added: L10n.text("folderReview.added", defaultValue: "New")
        case .missing: L10n.text("folderReview.missing", defaultValue: "Missing")
        case .changed: L10n.text("folderReview.changed", defaultValue: "Changed")
        case .moved: L10n.text("folderReview.moved", defaultValue: "Possible Moves")
        case .issue: L10n.text("folderReview.issues", defaultValue: "Needs Review")
        }
    }
}

struct FolderReviewFile {
    let relativePath: String
    let identity: FileIdentity
    var digest: String?
}

struct FolderDifference: Identifiable {
    let id: String
    var kind: FolderDifferenceKind
    var source: CatalogSource?
    var file: FolderReviewFile?
    var candidates: [FolderReviewFile] = []
    var restoresAvailability = false
    var problem: String?
    var unreadPath = ""
    var path: String { source?.relativePath ?? file?.relativePath ?? unreadPath }
    var actionTitle: String {
        switch kind {
        case .added: L10n.text("folderReview.addPhoto", defaultValue: "Add Photo")
        case .missing: L10n.text("folderReview.markMissing", defaultValue: "Mark Missing")
        case .changed: restoresAvailability
            ? L10n.text("folderReview.verifyLocation", defaultValue: "Verify Location")
            : L10n.text("folderReview.markChanged", defaultValue: "Mark Changed")
        case .moved: L10n.text("folderReview.relink", defaultValue: "Relink Original")
        case .issue: L10n.text("folderReview.issues", defaultValue: "Needs Review")
        }
    }
    func selectedFile(locations: [String: String]) -> FolderReviewFile? {
        if kind != .moved { return file }
        if let path = locations[id] { return candidates.first { $0.relativePath == path } }
        return candidates.count == 1 ? candidates.first : nil
    }
}

struct FolderReviewPreview {
    let scope: FolderReviewScope
    let includeSubfolders: Bool
    let entries: [FolderDifference]
    let checkedCount: Int
}

struct FolderReviewResult {
    var importedPhotoIDs: Set<String> = []
    var relinked = 0
    var marked = 0
    var appliedCount: Int { importedPhotoIDs.count + relinked + marked }
    var summary: String {
        L10n.text("folderReview.result", defaultValue: "Folder changes applied · Added \(importedPhotoIDs.count) · Verified locations \(relinked) · Marked unavailable \(marked)")
    }
}

struct StaleFolderReview: LocalizedError {
    var errorDescription: String? {
        L10n.text("folderReview.stale", defaultValue: "The folder, file or catalog changed after preview. Scan again; no selected changes were applied.")
    }
}

/// Native read-only comparison followed by explicit, revalidated publication.
/// Adobe's Synchronize Folder is an interaction reference, not a code source.
/// Missing records, versions and frozen outputs are never removed or rewritten.
actor FolderReviewService {
    private static let stale = StaleFolderReview()

    func preview(scope: FolderReviewScope, includeSubfolders: Bool, catalog: CatalogStore,
                 progress: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> FolderReviewPreview {
        let lease = try Self.access(scope, catalog: catalog)
        defer { withExtendedLifetime(lease) {} }
        let allSources = try catalog.sources()
        let sources = allSources.filter {
            $0.rootID == scope.root.id && Self.inScope($0.relativePath, scope: scope, recursive: includeSubfolders)
        }
        let protected = try Self.excludedPaths(catalog, root: scope.root)
        let files = try ImportPlanner.sourceFiles(scope.url, includeSubfolders: includeSubfolders)
            .filter { PhotoFileType.editableExtensions.contains($0.pathExtension.lowercased()) && !protected.contains(ExportNamingPlanner.collisionKey($0.path)) }
        let pathOwners = Dictionary(uniqueKeysWithValues: allSources.filter { $0.rootID == scope.root.id }.map { ($0.relativePath, $0) })
        let identityOwners = Dictionary(uniqueKeysWithValues: allSources.map { ($0.identityKey, $0) })
        var entries = [FolderDifference](), missing = [CatalogSource](), checked = 0
        for source in sources {
            try Task.checkCancellation()
            checked += 1
            if checked % 25 == 0 { await progress(checked) }
            do {
                guard let current = try Self.identity(at: source.relativePath, root: scope.root) else {
                    missing.append(source)
                    entries.append(FolderDifference(id: source.id, kind: .missing, source: source))
                    continue
                }
                let old = try JSONDecoder().decode(FileIdentity.self, from: source.identity)
                if current == old && source.availability == "available" { continue }
                var file = FolderReviewFile(relativePath: source.relativePath, identity: current)
                if source.digest != nil { file.digest = try Self.digest(file, root: scope.root) }
                let same = current == old || source.digest.map { $0 == file.digest } == true
                entries.append(FolderDifference(id: source.id, kind: .changed, source: source, file: file, restoresAvailability: same))
            } catch is CancellationError { throw CancellationError() }
            catch { entries.append(FolderDifference(id: source.id, kind: .issue, source: source, problem: error.localizedDescription)) }
        }

        var candidates = [String: [FolderReviewFile]](), newIdentities: Set<String> = []
        let missingBySignature = Dictionary(grouping: missing) { source in
            let identity = try? JSONDecoder().decode(FileIdentity.self, from: source.identity)
            return URL(fileURLWithPath: source.relativePath).pathExtension.lowercased() + ":" + String(identity?.size ?? -1)
        }
        for url in files {
            try Task.checkCancellation()
            let path = String(url.path.dropFirst(Self.prefix(scope.root.path).count))
            guard pathOwners[path] == nil else { continue }
            checked += 1
            if checked % 25 == 0 { await progress(checked) }
            var file: FolderReviewFile?
            do {
                guard let identity = try Self.identity(at: path, root: scope.root) else { throw Self.stale }
                var candidate = FolderReviewFile(relativePath: path, identity: identity)
                file = candidate
                let possible = missingBySignature[url.pathExtension.lowercased() + ":" + String(identity.size)] ?? []
                if possible.contains(where: { $0.digest != nil }) { candidate.digest = try Self.digest(candidate, root: scope.root) }
                let matches = possible.filter { source in
                    let original = try? JSONDecoder().decode(FileIdentity.self, from: source.identity)
                    return original == identity || source.digest.map { $0 == candidate.digest } == true
                }
                if !matches.isEmpty {
                    for source in matches { candidates[source.id, default: []].append(candidate) }
                    continue
                }
                guard identityOwners[identity.key] == nil, newIdentities.insert(identity.key).inserted,
                      !pathOwners.keys.contains(where: { ExportNamingPlanner.collisionKey($0) == ExportNamingPlanner.collisionKey(path) }) else {
                    throw LRCError(L10n.text("folderReview.alreadyRepresented", defaultValue: "This location or file identity is already represented in the catalog or preview. Use Locate Original if its location needs confirmation."))
                }
                _ = try ReferenceImporter.inspect(url: url, root: scope.root, rootURL: URL(fileURLWithPath: scope.root.path))
                guard try Self.identity(at: path, root: scope.root) == identity else { throw Self.stale }
                entries.append(FolderDifference(id: "file:" + path, kind: .added, file: candidate))
            } catch is CancellationError { throw CancellationError() }
            catch { entries.append(FolderDifference(id: "file:" + path, kind: .issue, file: file, problem: error.localizedDescription, unreadPath: path)) }
        }
        for index in entries.indices where entries[index].kind == .missing {
            if let found = candidates[entries[index].id], !found.isEmpty {
                entries[index].kind = .moved
                entries[index].candidates = found
            }
        }
        try Task.checkCancellation()
        return FolderReviewPreview(scope: scope, includeSubfolders: includeSubfolders,
            entries: entries.sorted { $0.kind.rawValue == $1.kind.rawValue ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : $0.kind.rawValue < $1.kind.rawValue },
            checkedCount: checked)
    }

    nonisolated static func selectionIssue(_ preview: FolderReviewPreview, selected: Set<String>, locations: [String: String]) -> String? {
        let entries = preview.entries.filter { selected.contains($0.id) }
        guard entries.count == selected.count, !entries.contains(where: { $0.kind == .issue }) else { return stale.localizedDescription }
        var identities: Set<String> = []
        for entry in entries {
            if entry.kind == .moved && entry.selectedFile(locations: locations) == nil {
                return L10n.text("folderReview.chooseLocation", defaultValue: "Choose a candidate location for every selected possible move.")
            }
            if let file = entry.selectedFile(locations: locations), entry.kind == .added || entry.kind == .moved || entry.restoresAvailability {
                guard identities.insert(file.identity.key).inserted else {
                    return L10n.text("folderReview.duplicateCandidate", defaultValue: "The same file was selected for more than one original. Choose one mapping before applying.")
                }
            }
        }
        return nil
    }

    func apply(_ preview: FolderReviewPreview, selected: Set<String>, locations: [String: String], catalog: CatalogStore) async throws -> FolderReviewResult {
        if let issue = Self.selectionIssue(preview, selected: selected, locations: locations) { throw LRCError(issue) }
        guard !selected.isEmpty else { return FolderReviewResult() }
        let scope = preview.scope, root = scope.root
        let lease = try Self.access(scope, catalog: catalog)
        defer { withExtendedLifetime(lease) {} }
        let entries = preview.entries.filter { selected.contains($0.id) }
        let relocator = RootRelocator()
        var proposals = [SourceRelocation](), imports = [Photo]()
        for entry in entries {
            try Task.checkCancellation()
            if entry.kind == .missing { continue }
            guard let file = entry.selectedFile(locations: locations),
                  try Self.identity(at: file.relativePath, root: root) == file.identity else { throw Self.stale }
            if entry.kind == .moved || entry.restoresAvailability {
                guard let source = entry.source else { throw Self.stale }
                if entry.kind == .moved, try Self.identity(at: source.relativePath, root: root) != nil { throw Self.stale }
                proposals.append(try await relocator.prepare(source, file: URL(fileURLWithPath: root.path).appendingPathComponent(file.relativePath), catalog: catalog))
            } else if entry.kind == .added {
                let photo = try ReferenceImporter.inspect(url: URL(fileURLWithPath: root.path).appendingPathComponent(file.relativePath), root: root, rootURL: URL(fileURLWithPath: root.path))
                guard photo.identityKey == file.identity.key,
                      try JSONDecoder().decode(FileIdentity.self, from: photo.identity) == file.identity else { throw Self.stale }
                imports.append(photo)
            } else if let digest = file.digest, try Self.digest(file, root: root) != digest { throw Self.stale }
        }
        for proposal in proposals { try await relocator.verify(proposal) }
        try Task.checkCancellation()
        let verifiedProposals = proposals, preparedImports = imports
        // Image decoding and content hashing stay outside this publication transaction.
        // Any stale member, collision, database error or cancellation rolls it all back.
        return try await catalog.database.write { db in
            try Self.checkRoot(root, in: db)
            try SourceAvailability.check(root: URL(fileURLWithPath: root.path), file: scope.url)
            let excluded = try Self.excludedPaths(db, root: root)
            for entry in entries {
                try Task.checkCancellation()
                if let source = entry.source, try CatalogSource.fetchOne(db, key: source.id) != source { throw Self.stale }
                if entry.kind == .missing || entry.kind == .moved {
                    guard let source = entry.source, try Self.identity(at: source.relativePath, root: root) == nil else { throw Self.stale }
                }
                if let file = entry.selectedFile(locations: locations) {
                    guard try Self.identity(at: file.relativePath, root: root) == file.identity,
                          !excluded.contains(ExportNamingPlanner.collisionKey(URL(fileURLWithPath: root.path).appendingPathComponent(file.relativePath).path)) else { throw Self.stale }
                }
            }
            var result = FolderReviewResult()
            for proposal in verifiedProposals { try RootRelocator.publish(proposal, in: db); result.relinked += 1 }
            for entry in entries where entry.kind == .missing || (entry.kind == .changed && !entry.restoresAvailability) {
                try Task.checkCancellation()
                try db.execute(sql: "UPDATE photoSource SET availability=? WHERE id=?", arguments: [entry.kind == .missing ? "missing" : "changed", entry.id])
                result.marked += 1
            }
            for photo in preparedImports {
                try Task.checkCancellation()
                let occupied = try CatalogSource.fetchAll(db, sql: "SELECT * FROM photoSource WHERE rootID=? OR identityKey=?", arguments: [root.id, photo.identityKey])
                guard !occupied.contains(where: { $0.identityKey == photo.identityKey || ExportNamingPlanner.collisionKey($0.relativePath) == ExportNamingPlanner.collisionKey(photo.relativePath) }),
                      try CatalogStore.index(photo, in: db) else { throw Self.stale }
                result.importedPhotoIDs.insert(photo.id)
            }
            try Task.checkCancellation()
            return result
        }
    }

    private static func prefix(_ path: String) -> String { path == "/" ? "/" : path + "/" }
    private static func inScope(_ path: String, scope: FolderReviewScope, recursive: Bool) -> Bool {
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        if !recursive { return parent == scope.directory }
        return scope.directory.isEmpty || path.hasPrefix(scope.directory + "/")
    }
    private static func validRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
    private static func identity(at path: String, root: StorageRoot) throws -> FileIdentity? {
        guard validRelative(path) else { throw stale }
        let url = URL(fileURLWithPath: root.path).appendingPathComponent(path).standardizedFileURL
        // Reject linked parents before reading a file, including links inside the grant.
        guard url.resolvingSymlinksInPath().path == url.path, url.path.hasPrefix(prefix(root.path)) else { throw stale }
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw SafeFileWriter.posix(L10n.text("app.readFileIdentity", defaultValue: "Read File Identity"))
        }
        guard try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem != true else { throw stale }
        return try FileIdentity.read(url)
    }
    private static func digest(_ file: FolderReviewFile, root: StorageRoot) throws -> String {
        guard try identity(at: file.relativePath, root: root) == file.identity else { throw stale }
        let value = try SafeFileWriter.sha256(URL(fileURLWithPath: root.path).appendingPathComponent(file.relativePath))
        guard try identity(at: file.relativePath, root: root) == file.identity else { throw stale }
        return value
    }
    static func access(_ scope: FolderReviewScope, catalog: CatalogStore) throws -> AccessLease {
        guard scope.directory.isEmpty || validRelative(scope.directory) else { throw stale }
        try catalog.database.read { try checkRoot(scope.root, in: $0) }
        let lease = try AccessLease(bookmark: scope.root.bookmark)
        guard lease.url.standardizedFileURL.resolvingSymlinksInPath().path == scope.root.path,
              scope.url.standardizedFileURL.resolvingSymlinksInPath().path == scope.url.path,
              try scope.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw stale }
        try SourceAvailability.check(root: lease.url, file: scope.url)
        return lease
    }
    private static func checkRoot(_ root: StorageRoot, in db: Database) throws {
        guard let current = try StorageRoot.fetchOne(db, key: root.id), current.path == root.path, current.bookmark == root.bookmark else { throw stale }
    }
    private static func excludedPaths(_ catalog: CatalogStore, root: StorageRoot) throws -> Set<String> {
        try catalog.database.read { try excludedPaths($0, root: root) }
    }
    private static func excludedPaths(_ db: Database, root: StorageRoot) throws -> Set<String> {
        let outputs = try String.fetchAll(db, sql: "SELECT destination FROM exportItem")
        let attachments = try String.fetchAll(db, sql: "SELECT DISTINCT a.relativePath FROM attachment a JOIN photo p ON p.id=a.photoID WHERE p.rootID=?", arguments: [root.id])
        return Set((outputs + attachments.map { URL(fileURLWithPath: root.path).appendingPathComponent($0).path }).map(ExportNamingPlanner.collisionKey))
    }
}
