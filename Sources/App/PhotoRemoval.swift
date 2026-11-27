import AppKit
import GRDB

struct PhotoRemovalRequest: Identifiable {
    let id = UUID()
    let catalog: CatalogStore
    let ids: Set<String>
    let originals: [PhotoTrashItem]?
    var rejectedQuery: PhotoQuery?
}

struct PhotoTrashItem: Identifiable, Equatable, Sendable {
    let id: String
    let rootPath: String
    let relativePath: String
    let identity: FileIdentity
    let digest: String?
    let versionIDs: Set<String>

    var url: URL { URL(fileURLWithPath: rootPath, isDirectory: true).appendingPathComponent(relativePath) }

    static func plan(ids: Set<String>, catalog: CatalogStore) throws -> [Self] {
        try catalog.database.read { db in
            let values = Array(ids)
            var selected = [String: Set<String>]()
            for start in stride(from: 0, to: values.count, by: 500) {
                let chunk = values[start..<min(start + 500, values.count)]
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: "SELECT id, sourceID FROM photo WHERE deleted=0 AND id IN (\(marks))", arguments: StatementArguments(chunk))
                guard rows.count == chunk.count else { throw OrganizationError.photoUnavailable }
                for row in rows {
                    guard let sourceID: String = row["sourceID"] else { throw OrganizationError.photoUnavailable }
                    selected[sourceID, default: []].insert(row["id"])
                }
            }
            return try selected.map { sourceID, versions in
                try Task.checkCancellation()
                guard let source = try CatalogSource.fetchOne(db, key: sourceID),
                      let root = try StorageRoot.fetchOne(db, key: source.rootID) else { throw OrganizationError.photoUnavailable }
                let live = try Row.fetchAll(db, sql: "SELECT id, copyName FROM photo WHERE sourceID=? AND deleted=0", arguments: [sourceID])
                guard live.count == versions.count, live.contains(where: { ($0["copyName"] as String?) == nil }) else {
                    throw LRCError(L10n.text("photoRemoval.sharedOriginal", defaultValue: "Select the original version and all its virtual copies before moving this file to Trash: \(source.relativePath)"))
                }
                let identity = try JSONDecoder().decode(FileIdentity.self, from: source.identity)
                guard source.availability == "available", identity != .unverified else {
                    throw LRCError(L10n.text("photoRemoval.unverifiedOriginal", defaultValue: "Verify the original's location before moving it to Trash: \(source.relativePath)"))
                }
                return Self(id: sourceID, rootPath: root.path, relativePath: source.relativePath, identity: identity, digest: source.digest, versionIDs: versions)
            }.sorted { $0.url.path < $1.url.path }
        }
    }

    func verifiedURL(checkContents: Bool) throws -> URL {
        let url = try ProjectCopy.child(relativePath, of: URL(fileURLWithPath: rootPath, isDirectory: true))
        guard url.resolvingSymlinksInPath().path == url.path, try FileIdentity.read(url) == identity else {
            throw LRCError(L10n.text("photoRemoval.fileChanged", defaultValue: "The original or its path changed. Verify its location and try again."))
        }
        if checkContents, let digest, try SafeFileWriter.sha256(url) != digest {
            throw LRCError(L10n.text("photoRemoval.fileChanged", defaultValue: "The original or its path changed. Verify its location and try again."))
        }
        return url
    }

    struct Result: Sendable {
        var versions = Set<String>()
        var moved = 0
        var failures = [String]()
        var cancelled = false
    }

    static func moveToTrash(_ items: [Self], move: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) throws -> Result {
        // A stale target detected before moving anything leaves the entire selection alone.
        for item in items {
            try Task.checkCancellation()
            do { _ = try item.verifiedURL(checkContents: true) }
            catch is CancellationError { throw CancellationError() }
            catch { throw LRCError("\(item.url.path)\n\(error.localizedDescription)") }
        }
        var result = Result()
        for item in items {
            if Task.isCancelled { result.cancelled = true; break }
            do {
                try move(item.verifiedURL(checkContents: false))
                result.versions.formUnion(item.versionIDs)
                result.moved += 1
            } catch { result.failures.append("\(item.url.path) — \(error.localizedDescription)") }
        }
        return result
    }
}

extension AppModel {
    var canRemovePhotos: Bool { canSelectAllResults && !selection.isEmpty }
    var canTrashPhotos: Bool { canRemovePhotos && (selection.count > 1 || active?.isVirtualCopy == false) }
    var canRemoveRejected: Bool { canSelectAllResults && !editMode && resultCount > 0 }

    func requestRejectedPhotoRemoval() {
        guard canRemoveRejected, let catalog, commitRecipe() else { return }
        perform {
            let query = self.query
            let ids = try catalog.database.read { try CatalogStore.rejectedResultIDs($0, query: query) }
            guard !ids.isEmpty else {
                showNotice(L10n.text("photoRemoval.noRejected", defaultValue: "No rejected photos in the current results"))
                return
            }
            photoRemoval = PhotoRemovalRequest(catalog: catalog, ids: ids, originals: nil, rejectedQuery: query)
        }
    }

    func deleteLibrarySelection() {
        guard canRemovePhotos else { return }
        if let collection = regularCollectionID { membership(collection, add: false) }
        else { requestPhotoRemoval() }
    }

    func requestPhotoRemoval(trash: Bool = false) {
        guard (trash ? canTrashPhotos : canRemovePhotos), let catalog, commitRecipe() else { return }
        let ids = selection
        guard trash else {
            photoRemoval = PhotoRemovalRequest(catalog: catalog, ids: ids, originals: nil)
            return
        }
        busy = true
        status = L10n.text("photoRemoval.preparing", defaultValue: "Preparing to move originals to Trash…")
        task = Task {
            defer { busy = false }
            do {
                let worker = Task.detached { try PhotoTrashItem.plan(ids: ids, catalog: catalog) }
                let originals = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                photoRemoval = PhotoRemovalRequest(catalog: catalog, ids: ids, originals: originals)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            status = L10n.text("photoRemoval.originalsUnchanged", defaultValue: "Original files unchanged")
        }
    }

    func confirmPhotoRemoval(_ request: PhotoRemovalRequest) throws {
        guard photoRemoval?.id == request.id, catalog === request.catalog, !busy else {
            throw OrganizationError.photoUnavailable
        }
        if let rejectedQuery = request.rejectedQuery {
            guard query == rejectedQuery else { throw CatalogStore.rejectedResultsChanged }
        } else if selection != request.ids { throw OrganizationError.photoUnavailable }
        guard let items = request.originals else {
            _ = try removePhotoVersions(request.ids, rejectedQuery: request.rejectedQuery)
            photoRemoval = nil
            return
        }
        // Import grants are read-only. Ask for write access to the exact sources for this operation only.
        var leases = [AccessLease]()
        for path in Set(items.map(\.rootPath)).sorted() {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let panel = Self.directoryPanel(title: L10n.text("photoRemoval.authorize", defaultValue: "Authorize Moving Originals to Trash"),
                                            initialURL: folder.deletingLastPathComponent())
            panel.message = L10n.text("photoRemoval.authorizePath", defaultValue: "Select this folder to authorize the move: \(path)")
            panel.canCreateDirectories = false
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            let lease = AccessLease(url: selected)
            guard lease.url.resolvingSymlinksInPath().path == path else {
                throw LRCError(L10n.text("photoRemoval.wrongFolder", defaultValue: "Select the original folder shown in the dialog. No files were moved."))
            }
            leases.append(lease)
        }
        photoRemoval = nil
        busy = true; movingPhotosToTrash = true
        status = L10n.text("photoRemoval.moving", defaultValue: "Verifying and moving originals to Trash…")
        task = Task { [leases] in
            defer { busy = false; movingPhotosToTrash = false }
            do {
                let worker = Task.detached {
                    defer { withExtendedLifetime(leases) {} }
                    guard try PhotoTrashItem.plan(ids: request.ids, catalog: request.catalog) == items else {
                        throw OrganizationError.photoUnavailable
                    }
                    return try PhotoTrashItem.moveToTrash(items)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                if !result.versions.isEmpty {
                    do { _ = try removePhotoVersions(result.versions, closedUndo: true) }
                    catch {
                        self.error = L10n.text("photoRemoval.catalogSaveFailed", defaultValue: "Files moved to Trash: \(result.moved). Their catalog entries could not be removed: \(error.localizedDescription)")
                    }
                }
                let count = items.count - result.moved
                status = L10n.text("photoRemoval.summary", defaultValue: "Moved to Trash: \(result.moved) · Not moved: \(count)")
                reports = [status] + result.failures
                if result.cancelled { reports.append(L10n.text("app.cancelled", defaultValue: "Cancelled")) }
                if count > 0, self.error == nil { showTaskResults = true }
                showNotice(status)
            } catch is CancellationError {
                status = L10n.text("photoRemoval.originalsUnchanged", defaultValue: "Original files unchanged")
            } catch {
                status = L10n.text("photoRemoval.originalsUnchanged", defaultValue: "Original files unchanged")
                self.error = error.localizedDescription
            }
        }
    }
}
