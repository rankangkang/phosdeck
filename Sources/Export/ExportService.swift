import Foundation
import GRDB
import ImageIO

struct ExportLog: Identifiable {
    let id: String
    let snapshot: ExportSnapshot
    let state: String
    let error: String?
    var isArchived: Bool { state.hasPrefix("archived:") }
    var isCompleted: Bool { state == "completed" || state == "archived:completed" }
    var canRetryInBatch: Bool { ["failed", "needsReview", "cancelled", "interrupted", "planned", "rendering", "verified", "published"].contains(state) }
}

enum ExportOutcome: Sendable { case published, verified }

struct ExportObservation: Sendable {
    let id: String
    let outcome: ExportOutcome
    let dimensions: (width: Int, height: Int)?
}

struct ExportOperationCounts {
    var published = 0
    var verified = 0
    mutating func record(_ outcome: ExportOutcome) {
        switch outcome { case .published: published += 1; case .verified: verified += 1 }
    }
}

struct ExportBatchResult {
    let ids: Set<String>
    let logs: [ExportLog]
    let rejected: [String]
    let reports: [String]
    var operationCounts = ExportOperationCounts()
    var completed: Int { logs.filter { $0.state == "completed" }.count }
    var retryableIDs: Set<String> { Set(logs.filter(\.canRetryInBatch).map(\.id)) }
    var unrecorded: Int { max(0, ids.count - logs.count - rejected.count) }
    var summary: String { L10n.text("app.thisExportComplete", defaultValue: "This export · \(completed)/\(ids.count) complete") + (completed < ids.count ? L10n.text("app.incomplete", defaultValue: " · \(ids.count - completed) incomplete") : "") }
    var operationSummary: String {
        L10n.text("app.newlyWrittenVerified", defaultValue: "\(operationCounts.published) newly written · \(operationCounts.verified) verified")
    }
}

struct ExportSnapshot: Codable {
    let id: String
    let request: ImageRequest
    let destination: URL
    let targetBookmark: Data
    let options: ExportOptions
    var retainedStaging: [URL]?
    var metadata = ExportMetadata()
}

actor ExportService {
    let pipeline: ImagePipeline
    private let checkpoint: @Sendable (String) throws -> Void
    init(pipeline: ImagePipeline, checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }) {
        self.pipeline = pipeline; self.checkpoint = checkpoint
    }

    static func logs(catalog: CatalogStore) throws -> [ExportLog] {
        try history(catalog: catalog).logs
    }
    /// Renew permission for the exact frozen destination. Never relocate or re-plan an existing job.
    @discardableResult
    static func reauthorizeTarget(id: String, directory: URL, catalog: CatalogStore) throws -> ExportSnapshot {
        try reauthorizeTargets(ids: [id], directory: directory, catalog: catalog)[0]
    }

    static func reauthorizeTargets(ids: [String], directory: URL, catalog: CatalogStore) throws -> [ExportSnapshot] {
        let lease = AccessLease(url: directory)
        defer { withExtendedLifetime(lease) {} }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LRCError(L10n.text("app.chooseTheOriginalDestinationFolder", defaultValue: "Choose the original destination folder")) }
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        let bookmark = try AccessLease.bookmark(directory, readOnly: false)
        let checked = try AccessLease(bookmark: bookmark)
        guard checked.url.standardizedFileURL.resolvingSymlinksInPath() == canonical else { throw LRCError(L10n.text("app.destinationAuthorizationDiffersOnReadback", defaultValue: "Destination authorization differs on readback")) }
        return try catalog.database.write { db in
            try ids.map { id in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM exportItem WHERE id=?", arguments: [id]) else {
                    throw LRCError(L10n.text("app.theOutputRecordNoLongerExists", defaultValue: "The output record no longer exists"))
                }
                let item = try log(row)
                guard !item.isArchived else { throw LRCError(L10n.text("archive.historyOnly", defaultValue: "Archived task records are kept for reference.")) }
                let frozen = item.snapshot
                guard frozen.destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == canonical.path else {
                    throw LRCError(L10n.text("app.chooseTheOriginalDestinationFolderReauthorizationPreservesTheFrozen", defaultValue: "Choose the original destination folder: \(frozen.destination.deletingLastPathComponent().path). Reauthorization preserves the frozen export destination."))
                }
                let renewed = ExportSnapshot(id: frozen.id, request: frozen.request, destination: frozen.destination,
                                             targetBookmark: bookmark, options: frozen.options, retainedStaging: frozen.retainedStaging, metadata: frozen.metadata)
                try db.execute(sql: "UPDATE exportItem SET snapshot=? WHERE id=?", arguments: [try JSONEncoder().encode(renewed), id])
                return renewed
            }
        }
    }
    /// Unsupported snapshots are errors, never upgraded or silently rewritten.
    static func history(catalog: CatalogStore, ids: Set<String>? = nil) throws -> (logs: [ExportLog], rejected: [String]) {
        try catalog.database.read { db in
            var logs = [ExportLog](), rejected = [String]()
            let rows = try ids.map { try $0.sorted().compactMap { try Row.fetchOne(db, sql: "SELECT * FROM exportItem WHERE id=?", arguments: [$0]) } }
                ?? Row.fetchAll(db, sql: "SELECT * FROM exportItem ORDER BY rowid")
            for row in rows {
                do {
                    logs.append(try log(row))
                } catch { rejected.append(L10n.text("app.taskUnsupportedOrDamagedStructureRetryRefusedOriginalRecord", defaultValue: "Task \(row["id"] as String): unsupported or damaged structure. Retry refused; original record preserved")) }
            }
            return (logs, rejected)
        }
    }
    static func historyPage(catalog: CatalogStore, unfinishedOnly: Bool, offset: Int, limit: Int) throws -> (logs: [ExportLog], rejectedIDs: [String], total: Int) {
        try catalog.database.read { db in
            let filter = unfinishedOnly ? " WHERE state NOT IN ('completed','archived:completed')" : ""
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM exportItem" + filter) ?? 0
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM exportItem" + filter + " ORDER BY rowid DESC LIMIT ? OFFSET ?",
                                        arguments: [limit, offset])
            var logs = [ExportLog](), rejected = [String]()
            for row in rows {
                if let item = try? log(row) { logs.append(item) }
                else { rejected.append(row["id"]) }
            }
            return (logs, rejected, total)
        }
    }

    private static func log(_ row: Row) throws -> ExportLog {
        let snapshot = try JSONDecoder().decode(ExportSnapshot.self, from: row["snapshot"])
        guard snapshot.id == row["id"] as String, snapshot.destination.path == row["destination"] as String else {
            throw LRCError(L10n.text("app.frozenTaskIdentityOrLocationMismatch", defaultValue: "Frozen task identity or location mismatch"))
        }
        return ExportLog(id: row["id"], snapshot: snapshot, state: row["state"], error: row["error"])
    }

    static func authorizedFolder(for destination: URL, scope: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let authorized = scope.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = authorized == "/" ? "/" : authorized + "/"
        guard parent.path == authorized || parent.path.hasPrefix(prefix) else {
            throw LRCError(L10n.text("app.chooseTheOriginalDestinationFolder", defaultValue: "Choose the original destination folder"))
        }
        return parent
    }

    func run(_ snapshots: [ExportSnapshot], catalog: CatalogStore, step: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
             outcome: @escaping @MainActor @Sendable (ExportOutcome) -> Void = { _ in },
             observe: (@MainActor @Sendable (ExportObservation) -> Void)? = nil,
             progress: @escaping @Sendable (String) async -> Void) async -> [String] {
        var reports = [String]()
        do {
            let rows = try snapshots.map { ($0.id, try JSONEncoder().encode($0), $0.destination.path) }
            // Journal the entire submitted batch before observing cancellation. The
            // async database API can itself cancel before saving any planned rows.
            try Self.journal(catalog) { db in
                for (id, payload, destination) in rows {
                    try db.execute(sql: "INSERT OR IGNORE INTO exportItem (id,snapshot,state,destination) VALUES (?,?,'planned',?)", arguments: [id, payload, destination])
                }
            }
        } catch { return [L10n.text("app.couldNotSaveTheOutputPlanNoOutputWas", defaultValue: "Could not save the output plan. No output was written: \(error.localizedDescription)")] }
        for (index, snapshot) in snapshots.enumerated() {
            if Task.isCancelled { reports.append(L10n.text("app.remainingOutputsCancelled", defaultValue: "Remaining outputs cancelled")); break }
            await step(index, snapshots.count)
            var published = false
            var previouslyCompleted = false
            do {
                let id = snapshot.id
                let existing = try await catalog.database.read { db -> (state: String, digest: String?, snapshot: Data, staging: String?)? in
                    try Row.fetchOne(db, sql: "SELECT state,digest,snapshot,staging FROM exportItem WHERE id=?", arguments: [id])
                        .map { ($0["state"], $0["digest"], $0["snapshot"], $0["staging"]) }
                }
                if existing?.state.hasPrefix("archived:") == true {
                    reports.append(L10n.text("archive.historyOnly", defaultValue: "Archived task records are kept for reference."))
                    continue
                }
                previouslyCompleted = existing?.state == "completed"
                let frozen = try existing.map { try JSONDecoder().decode(ExportSnapshot.self, from: $0.snapshot) } ?? snapshot
                try frozen.options.validate()
                try frozen.metadata.validate(policy: frozen.options.metadataPolicy)
                let lease = try AccessLease(bookmark: frozen.targetBookmark)
                defer { withExtendedLifetime(lease) {} }
                let folder = try Self.authorizedFolder(for: frozen.destination, scope: lease.url)
                // A journal entry is not evidence that its external output still exists.
                // Verify before preparing the source, so intact output can be checked offline.
                if FileManager.default.fileExists(atPath: frozen.destination.path) {
                    _ = try FileIdentity.read(frozen.destination)
                    if let digest = existing?.digest, try SafeFileWriter.sha256(frozen.destination) == digest {
                        try state(frozen.id, "completed", catalog: catalog)
                        await outcome(.verified)
                        if let observe {
                            await observe(ExportObservation(id: frozen.id, outcome: .verified,
                                                           dimensions: Self.dimensions(at: frozen.destination)))
                        }
                        reports.append(previouslyCompleted ? L10n.text("app.verifiedWithoutWritingAgain", defaultValue: "Verified without writing again: \(frozen.destination.lastPathComponent)") :
                            L10n.text("app.verifiedTheOutputPublishedBeforeInterruption", defaultValue: "Verified the output published before interruption: \(frozen.destination.lastPathComponent)"))
                        continue
                    }
                    throw LRCError(L10n.text("app.theDestinationExistsAndCannotBeVerifiedAsThis", defaultValue: "The destination exists and cannot be verified as this task's output. Overwriting is not allowed"))
                }
                var snapshot = try await prepared(frozen)
                if let previous = existing?.staging, FileManager.default.fileExists(atPath: previous) {
                    var retained = snapshot.retainedStaging ?? []
                    let url = URL(fileURLWithPath: previous)
                    if !retained.contains(url) { retained.append(url) }
                    snapshot.retainedStaging = retained
                }
                let encoded = try JSONEncoder().encode(snapshot)
                let snapshotID = snapshot.id
                try await catalog.database.write { db in
                    try db.execute(sql: "UPDATE exportItem SET snapshot=? WHERE id=?", arguments: [encoded, snapshotID])
                }
                let staging = try SafeFileWriter.stage(in: snapshot.destination.deletingLastPathComponent())
                try state(snapshot.id, "rendering", catalog: catalog, staging: staging.path)
                try checkpoint("rendering")
                await progress(L10n.text("app.writing", defaultValue: "Writing \(index + 1)/\(snapshots.count) · \(snapshot.request.photo.displayName)"))
                let dimensions = try await pipeline.export(snapshot.request, staging: staging, options: snapshot.options, metadata: snapshot.metadata)
                let renderedIdentity = try FileIdentity.read(staging)
                let digest = try SafeFileWriter.sha256(staging)
                try await catalog.database.write { try $0.execute(sql: "UPDATE exportItem SET state='verified', digest=? WHERE id=?", arguments: [digest, snapshotID]) }
                try checkpoint("verified")
                try Task.checkCancellation()
                guard try Self.authorizedFolder(for: snapshot.destination, scope: lease.url).path == folder.path,
                      try FileIdentity.read(staging) == renderedIdentity else {
                    throw LRCError(L10n.text("app.theDestinationChangedWhileCreatingSubfoldersNothingQueued", defaultValue: "The destination changed before publication"))
                }
                try SafeFileWriter.publish(staging, to: snapshot.destination)
                published = true
                let sameFile = (try? FileIdentity.read(snapshot.destination)) == renderedIdentity
                if let observe {
                    await observe(ExportObservation(id: snapshot.id, outcome: .published, dimensions: sameFile ? dimensions : nil))
                }
                guard sameFile else { throw LRCError(L10n.text("app.frozenTaskIdentityOrLocationMismatch", defaultValue: "Frozen task identity or location mismatch")) }
                try checkpoint("publishedBeforeJournal")
                try state(snapshot.id, "completed", catalog: catalog)
                await outcome(.published)
                reports.append(L10n.text("app.succeeded", defaultValue: "Succeeded: \(snapshot.destination.lastPathComponent)"))
            } catch {
                let message = published ? L10n.text("app.publishedButRecordingFailedVerificationRequired", defaultValue: "Published, but recording failed. Verification required: \(error.localizedDescription)") : error.localizedDescription
                let failureState = published || previouslyCompleted ? "needsReview" : (Task.isCancelled ? "cancelled" : "failed")
                try? Self.journal(catalog) { try $0.execute(sql: "UPDATE exportItem SET state=?,error=? WHERE id=?", arguments: [failureState, message, snapshot.id]) }
                reports.append("\(snapshot.request.photo.displayName)：\(message)")
            }
        }
        if Task.isCancelled {
            let ids = snapshots.map(\.id)
            try? Self.journal(catalog) { db in
                for id in ids { try db.execute(sql: "UPDATE exportItem SET state='cancelled' WHERE id=? AND state='planned'", arguments: [id]) }
            }
        }
        return reports
    }
    private static func dimensions(at url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = info[kCGImagePropertyPixelWidth as String] as? Int,
              let height = info[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
        return (width, height)
    }
    private static func journal(_ catalog: CatalogStore, _ changes: (Database) throws -> Void) throws {
        try catalog.database.write(changes)
    }
    private func prepared(_ snapshot: ExportSnapshot) async throws -> ExportSnapshot {
        guard snapshot.request.photo.supportsEditing, snapshot.request.recipe == nil else { return snapshot }
        // Freeze the source's own neutral baseline, never the later mutable catalog recipe.
        let baseline = try await pipeline.baseline(snapshot.request)
        return ExportSnapshot(id: snapshot.id, request: ImageRequest(photo: snapshot.request.photo, root: snapshot.request.root, recipe: baseline),
                              destination: snapshot.destination, targetBookmark: snapshot.targetBookmark, options: snapshot.options, retainedStaging: snapshot.retainedStaging, metadata: snapshot.metadata)
    }
    private func state(_ id: String, _ state: String, catalog: CatalogStore, staging: String? = nil) throws {
        try catalog.database.write { db in
            try db.execute(sql: "UPDATE exportItem SET state=?,error=NULL,staging=coalesce(?,staging) WHERE id=?", arguments: [state, staging, id])
        }
    }
}
