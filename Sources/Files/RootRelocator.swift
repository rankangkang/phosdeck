import Foundation
import GRDB
import Darwin

/// A checked location for one physical source. No file is moved and no catalog
/// row changes until commit rechecks both the file and the source snapshot.
struct SourceRelocation {
    let source: CatalogSource
    let root: StorageRoot
    let relativePath: String
    let identity: FileIdentity
    let attachments: [String: String]
    var url: URL { URL(fileURLWithPath: root.path).appendingPathComponent(relativePath) }
}

actor RootRelocator {
    // Workflow reference: lightcraft 4f0b110 cmd/missing.rs and tests_import.rs.
    // Native policy is stricter: the same content/identity is required, versions
    // share one source, and existing frozen exports are never rewritten.
    func prepare(_ source: CatalogSource, file: URL, directory: URL? = nil, catalog: CatalogStore) throws -> SourceRelocation {
        try Task.checkCancellation()
        let fileAccess = AccessLease(url: file)
        defer { withExtendedLifetime(fileAccess) {} }
        let identity = try FileIdentity.read(file) // Reject a symbolic-link leaf before resolving parents.
        let url = file.standardizedFileURL.resolvingSymlinksInPath()
        let oldExtension = URL(fileURLWithPath: source.relativePath).pathExtension.lowercased()
        guard url.pathExtension.lowercased() == oldExtension else { throw LRCError(L10n.text("app.chooseAFileWithTheSameFormatAsThe", defaultValue: "Choose a file with the same format as the original. Relocation does not convert formats")) }
        let roots = try catalog.roots()
        let root: StorageRoot
        if let existing = roots.first(where: { Self.contains(url.path, in: $0.path) }) {
            root = existing
        } else {
            guard let directory else { throw LRCError(L10n.text("app.authorizeTheFolderContainingTheOriginalThenTryLocating", defaultValue: "Authorize the folder containing the original, then try locating it again")) }
            let grant = AccessLease(url: directory)
            defer { withExtendedLifetime(grant) {} }
            let folder = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  Self.contains(url.path, in: folder.path) else { throw LRCError(L10n.text("app.theSelectedFileIsOutsideTheAuthorizedFolder", defaultValue: "The selected file is outside the authorized folder")) }
            guard !roots.contains(where: { Self.overlaps(folder.path, $0.path) }) else { throw LRCError(L10n.text("app.theAuthorizedFolderOverlapsAnExistingOriginalFolderChoose", defaultValue: "The authorized folder overlaps an existing original folder. Choose the immediate parent of the original")) }
            root = StorageRoot(id: UUID().uuidString, path: folder.path,
                               bookmark: try AccessLease.bookmark(directory, readOnly: true), label: folder.lastPathComponent)
        }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        let attachments = try catalog.database.read { try Self.attachments($0, sourceID: source.id) }
        let proposal = SourceRelocation(source: source, root: root, relativePath: String(url.path.dropFirst(prefix.count)),
                                        identity: identity, attachments: attachments)
        try verify(proposal)
        try catalog.database.read { try Self.checkCatalog($0, proposal) }
        return proposal
    }

    func commit(_ proposal: SourceRelocation, catalog: CatalogStore) throws {
        try verify(proposal)
        try Task.checkCancellation()
        try catalog.database.write { db in
            try Task.checkCancellation()
            try Self.checkCatalog(db, proposal)
            if try StorageRoot.fetchOne(db, key: proposal.root.id) == nil { try proposal.root.insert(db) }
            let oldIdentity = try JSONDecoder().decode(FileIdentity.self, from: proposal.source.identity)
            let identity = oldIdentity == proposal.identity ? proposal.source.identity : try JSONEncoder().encode(proposal.identity)
            // The existing trigger projects this mapping to every version, including
            // retained/deleted versions. All per-version organization and edits stay put.
            try db.execute(sql: "UPDATE photoSource SET rootID=?,relativePath=?,identity=?,identityKey=?,availability='available' WHERE id=?",
                           arguments: [proposal.root.id, proposal.relativePath, identity, proposal.identity.key, proposal.source.id])
        }
    }

    private func verify(_ proposal: SourceRelocation) throws {
        try Task.checkCancellation()
        let lease = try AccessLease(bookmark: proposal.root.bookmark)
        defer { withExtendedLifetime(lease) {} }
        let parts = proposal.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              proposal.url.pathExtension.lowercased() == URL(fileURLWithPath: proposal.source.relativePath).pathExtension.lowercased(),
              lease.url.standardizedFileURL.resolvingSymlinksInPath().path == proposal.root.path,
              Self.contains(proposal.url.standardizedFileURL.resolvingSymlinksInPath().path, in: proposal.root.path),
              try FileIdentity.read(proposal.url) == proposal.identity else { throw LRCError(L10n.text("app.theCandidateFileOrAuthorizedLocationChangedLocateIt", defaultValue: "The candidate file or authorized location changed. Locate it again")) }
        if let digest = proposal.source.digest {
            guard try SafeFileWriter.sha256(proposal.url) == digest else { throw LRCError(L10n.text("app.candidateContentsDifferFromTheOriginalLocationAndOrganization", defaultValue: "Candidate contents differ from the original. Location and organization preserved")) }
        } else {
            guard try JSONDecoder().decode(FileIdentity.self, from: proposal.source.identity) == proposal.identity else {
                throw LRCError(L10n.text("app.noOriginalDigestIsAvailableToVerifyThisCandidate", defaultValue: "No original digest is available to verify this candidate. Location and organization preserved"))
            }
        }
        // Attachments are relative to the source root. When changing roots, they
        // must already be verifiable at the same relative paths under the new root.
        if proposal.root.id != proposal.source.rootID {
            for (path, digest) in proposal.attachments {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: proposal.root.path).appendingPathComponent(path)
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                      Self.contains(url.resolvingSymlinksInPath().path, in: proposal.root.path) else { throw LRCError(L10n.text("app.invalidAssociatedAttachmentLocationOriginalLocationPreserved", defaultValue: "Invalid associated attachment location. Original location preserved")) }
                do {
                    let identity = try FileIdentity.read(url)
                    guard try SafeFileWriter.sha256(url) == digest, try FileIdentity.read(url) == identity else { throw LRCError(L10n.text("app.contentsOrIdentityChanged", defaultValue: "Contents or identity changed")) }
                } catch {
                    throw LRCError(L10n.text("app.couldNotVerifyTheAssociatedAttachmentAtTheNew", defaultValue: "Could not verify the associated attachment at the new location: \(path) (\(error.localizedDescription)). Original location preserved"))
                }
            }
        }
        guard try FileIdentity.read(proposal.url) == proposal.identity else { throw LRCError(L10n.text("app.theCandidateChangedDuringVerificationOriginalLocationPreserved", defaultValue: "The candidate changed during verification. Original location preserved")) }
        try Task.checkCancellation()
    }

    private static func checkCatalog(_ db: Database, _ proposal: SourceRelocation) throws {
        guard try CatalogSource.fetchOne(db, key: proposal.source.id) == proposal.source,
              try attachments(db, sourceID: proposal.source.id) == proposal.attachments else { throw LRCError(L10n.text("app.theOriginalRecordChangedLocateItAgain", defaultValue: "The original record changed. Locate it again")) }
        if let root = try StorageRoot.fetchOne(db, key: proposal.root.id) {
            guard root.path == proposal.root.path, root.bookmark == proposal.root.bookmark else { throw LRCError(L10n.text("app.folderAuthorizationChangedLocateItAgain", defaultValue: "Folder authorization changed. Locate it again")) }
        } else {
            guard !(try StorageRoot.fetchAll(db)).contains(where: { overlaps($0.path, proposal.root.path) }) else { throw LRCError(L10n.text("app.theNewLocationOverlapsAnExistingOriginalFolder", defaultValue: "The new location overlaps an existing original folder")) }
        }
        let occupied = try CatalogSource.fetchAll(db, sql: "SELECT * FROM photoSource WHERE id<>? AND (identityKey=? OR rootID=?)",
                                                  arguments: [proposal.source.id, proposal.identity.key, proposal.root.id])
        guard !occupied.contains(where: { $0.identityKey == proposal.identity.key || ExportNamingPlanner.collisionKey($0.relativePath) == ExportNamingPlanner.collisionKey(proposal.relativePath) }) else {
            throw LRCError(L10n.text("app.theCandidateAlreadyBelongsToAnotherOriginalNoSources", defaultValue: "The candidate already belongs to another original. No sources were changed"))
        }
    }

    private static func attachments(_ db: Database, sourceID: String) throws -> [String: String] {
        var result = [String: String]()
        for row in try Row.fetchAll(db, sql: "SELECT DISTINCT a.relativePath,a.digest FROM attachment a JOIN photo p ON p.id=a.photoID WHERE p.sourceID=?", arguments: [sourceID]) {
            let path: String = row["relativePath"], digest: String = row["digest"]
            guard result[path] == nil || result[path] == digest else { throw LRCError(L10n.text("app.attachmentDigestsConflictBetweenRelatedVersionsLocationPreserved", defaultValue: "Attachment digests conflict between related versions. Location preserved")) }
            result[path] = digest
        }
        return result
    }
    private static func contains(_ path: String, in root: String) -> Bool { path != root && path.hasPrefix(root == "/" ? "/" : root + "/") }
    private static func overlaps(_ a: String, _ b: String) -> Bool { a == b || contains(a, in: b) || contains(b, in: a) }

    func relocate(_ root: StorageRoot, to url: URL, catalog: CatalogStore) throws -> [String] {
        let lease = AccessLease(url: url); defer { withExtendedLifetime(lease) {} }
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        guard !(try catalog.roots()).contains(where: { $0.id != root.id && ($0.path == normalized.path || $0.path.hasPrefix(normalized.path + "/") || normalized.path.hasPrefix($0.path + "/")) }) else { throw LRCError(L10n.text("app.theNewLocationOverlapsAnotherRootFolder", defaultValue: "The new location overlaps another root folder")) }
        // Relocate physical sources once, including retained sources with no active versions.
        let photos = try catalog.sources().filter { $0.rootID == root.id }
        var updates = [(String, FileIdentity?, String)]()
        var reports = [String]()
        for photo in photos {
            try Task.checkCancellation()
            let candidate = normalized.appendingPathComponent(photo.relativePath)
            do {
                let identity = try FileIdentity.read(candidate)
                let original = try JSONDecoder().decode(FileIdentity.self, from: photo.identity)
                let verified: Bool
                if let digest = photo.digest { verified = try SafeFileWriter.sha256(candidate) == digest }
                else { verified = identity == original }
                guard verified else { throw LRCError(L10n.text("app.identityCannotBeConfirmedOrganizationAndRecipePreservedDevelopment", defaultValue: "Identity cannot be confirmed. Organization and recipe preserved; development paused")) }
                updates.append((photo.id, identity, "available"))
            } catch {
                updates.append((photo.id, nil, "changed"))
                reports.append("\(photo.name)：\(error.localizedDescription)")
            }
        }
        let bookmark = try AccessLease.bookmark(url, readOnly: true)
        try catalog.database.write { db in
            try db.execute(sql: "UPDATE storageRoot SET path=?,bookmark=?,label=? WHERE id=?", arguments: [normalized.path, bookmark, url.lastPathComponent, root.id])
            for (id, identity, state) in updates {
                if let identity {
                    try db.execute(sql: "UPDATE photoSource SET identity=?,identityKey=?,availability=? WHERE id=?", arguments: [try JSONEncoder().encode(identity), identity.key, state, id])
                } else { try db.execute(sql: "UPDATE photoSource SET availability=? WHERE id=?", arguments: [state, id]) }
            }
        }
        return reports
    }
}

enum SourceAvailability {
    static func check(root: URL, file: URL) throws {
        var info = stat()
        if stat(root.path, &info) != 0 {
            let code = errno
            if code == EACCES || code == EPERM { throw LRCError(L10n.text("app.folderPermissionExpiredAuthorizeItAgain", defaultValue: "Folder permission expired. Authorize it again")) }
            let parts = root.pathComponents
            if parts.count > 2 && parts[1] == "Volumes" {
                let volume = URL(fileURLWithPath: "/Volumes").appendingPathComponent(parts[2])
                if !FileManager.default.fileExists(atPath: volume.path) { throw LRCError(L10n.text("app.theOriginalVolumeIsOfflineConnectTheOriginalDrive", defaultValue: "The original volume is offline. Connect the original drive")) }
            }
            throw LRCError(L10n.text("app.theRootFolderIsMissingLocateItAgain", defaultValue: "The root folder is missing. Locate it again"))
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else { throw LRCError(L10n.text("app.folderPermissionExpiredAuthorizeItAgain", defaultValue: "Folder permission expired. Authorize it again")) }
        if lstat(file.path, &info) != 0 {
            if errno == EACCES || errno == EPERM { throw LRCError(L10n.text("app.insufficientPermissionToReadTheOriginal", defaultValue: "Insufficient permission to read the original")) }
            throw LRCError(L10n.text("app.originalMissingRatingsAndAdjustmentsPreserved", defaultValue: "Original missing; ratings and adjustments preserved"))
        }
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw LRCError(L10n.text("app.insufficientPermissionToReadTheOriginal", defaultValue: "Insufficient permission to read the original")) }
    }
}
