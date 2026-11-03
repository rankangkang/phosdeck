import Foundation
import GRDB
import Darwin

struct ImportConflict: Identifiable {
    let id: String
    let members: [CopyMember]
    let canRename: Bool
    let overwriteRestriction: String?
}

struct ImportConflictDecision {
    let policy: ConflictPolicy
    let applyToRemaining: Bool
}

actor CopyImporter {
    private let checkpoint: @Sendable (String) throws -> Void
    init(checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }) { self.checkpoint = checkpoint }

    func run(_ input: CopyPlan, catalog: CatalogStore, resolveConflict: (@Sendable (ImportConflict) async -> ImportConflictDecision?)? = nil,
             onImported: @escaping @Sendable (String) async -> Void = { _ in }, progress: @escaping @Sendable (String) async -> Void) async -> CopyPlan {
        guard input.version == 2 else {
            var refused = input; refused.omitted.append(L10n.text("app.unsupportedCopyPlanVersionOriginalTaskPreservedWithoutExecution", defaultValue: "Unsupported copy plan version. Original task preserved without execution or modification"))
            refused.state = "needsReview"; return refused
        }
        var plan = input
        var batchPolicy: ConflictPolicy?
        do {
            let sourceLease = try AccessLease(bookmark: plan.sourceBookmark), targetLease = try AccessLease(bookmark: plan.targetBookmark)
            defer { withExtendedLifetime([sourceLease, targetLease]) {} }
            guard sourceLease.url.resolvingSymlinksInPath() == plan.sourceRoot, targetLease.url.resolvingSymlinksInPath() == plan.targetRoot else { throw LRCError(L10n.text("app.theCatalogLocationChangedCreateANewPlan", defaultValue: "The catalog location changed. Create a new plan")) }
            // Persist the complete immutable naming decisions before any copy.
            plan.state = "running"; try persist(plan, catalog: catalog)
            let required = plan.groups.filter { $0.selected && $0.state != "completed" && $0.state != "skippedVerified" && $0.state != "skippedConflict" }.flatMap(\.members).reduce(Int64(0)) { $0 + $1.sourceIdentity.size }
            try SafeFileWriter.requireCapacity(in: plan.targetRoot, bytes: required)
            let root = try catalog.addRoot(url: plan.targetRoot, bookmark: plan.targetBookmark)
            for g in plan.groups.indices {
                guard plan.groups[g].selected, !["completed", "skippedConflict", "needsReview"].contains(plan.groups[g].state) else { continue }
                if Task.isCancelled { plan.state = "cancelled"; break }
                do {
                    if plan.groups[g].requiresConflictCheck == true {
                        var group = plan.groups[g]
                        for member in group.members { try ensureDestination(member.destination, root: plan.targetRoot) }
                        let exists = group.members.map { FileManager.default.fileExists(atPath: $0.destination.path) }
                        if exists.contains(true) {
                            let identical = plan.skipIdentical && exists.allSatisfy { $0 } && group.members.allSatisfy { (try? SafeFileWriter.sha256($0.destination)) == $0.digest }
                            if identical {
                                group.state = "skippedVerified"
                            } else {
                                var replacement = group.members.first!
                                var restriction: String?
                                do {
                                    guard group.allowsOverwrite == true else { throw LRCError(L10n.text("app.groupsWithAttachmentsOrMultiplePhotosCannotOverwriteFiles", defaultValue: "Groups with attachments or multiple photos cannot overwrite files")) }
                                    replacement.targetIdentity = try FileIdentity.read(replacement.destination)
                                    replacement.targetDigest = try SafeFileWriter.sha256(replacement.destination)
                                    try validateReplacement(replacement, plan: plan, catalog: catalog)
                                } catch { restriction = error.localizedDescription }
                                let conflict = ImportConflict(id: group.id, members: group.members, canRename: group.allowsRename == true, overwriteRestriction: restriction)
                                let policy: ConflictPolicy
                                if let saved = batchPolicy, (saved != .overwrite || restriction == nil), (saved != .uniqueName || conflict.canRename) {
                                    policy = saved
                                } else {
                                    guard let resolveConflict else { throw LRCError(L10n.text("app.chooseHowToHandleTheFilenameConflict", defaultValue: "Choose how to handle the filename conflict")) }
                                    guard let decision = await resolveConflict(conflict) else { throw CancellationError() }
                                    try Task.checkCancellation()
                                    policy = decision.policy
                                    if decision.applyToRemaining { batchPolicy = policy }
                                }
                                group.policy = policy
                                switch policy {
                                case .skip:
                                    group.state = "skippedConflict"; group.diagnostic = L10n.text("app.filenameConflictGroupSkipped", defaultValue: "Filename conflict group skipped")
                                case .uniqueName:
                                    guard conflict.canRename else { throw LRCError(L10n.text("app.unknownAttachmentsCannotBeRenamedAutomaticallySkipThemOr", defaultValue: "Unknown attachments cannot be renamed automatically. Skip them or change the destination")) }
                                    let reserved = Set(plan.groups.filter { $0.id != group.id }.flatMap(\.members).map { ImportPlanner.nameKey($0.destination) })
                                    let destinations = try ImportPlanner.uniqueDestinations(members: group.members, reserved: reserved)
                                    for i in group.members.indices { group.members[i].destination = destinations[i] }
                                case .overwrite:
                                    guard restriction == nil else { throw LRCError(restriction!) }
                                    // The decision authorizes only the exact old file shown in the dialog.
                                    try validateReplacement(replacement, plan: plan, catalog: catalog)
                                    group.members[0] = replacement
                                }
                            }
                        }
                        group.requiresConflictCheck = false
                        plan.groups[g] = group
                        try persist(plan, catalog: catalog)
                        if group.state == "skippedConflict" { continue }
                    }
                    let verifiedReuse = plan.groups[g].state == "skippedVerified"
                    for m in plan.groups[g].members.indices {
                        var member = plan.groups[g].members[m]
                        if member.state == "completed" {
                            guard try SafeFileWriter.sha256(member.destination) == member.digest else { throw LRCError(L10n.text("app.completedGroupMembersChangedRecoveryStopped", defaultValue: "Completed group members changed. Recovery stopped")) }
                            continue
                        }
                        await progress(L10n.text("app.copyingGroup", defaultValue: "Copying group \(g + 1)/\(plan.groups.count) · \(member.source.lastPathComponent)"))
                        try Task.checkCancellation()
                        try ensureDestination(member.destination, root: plan.targetRoot)
                        guard try FileIdentity.read(member.source) == member.sourceIdentity,
                              try SafeFileWriter.sha256(member.source) == member.digest else { throw LRCError(L10n.text("app.theSourceChangedThisGroupWasStopped", defaultValue: "The source changed. This group was stopped")) }
                        // Reconcile interruption after a rename but before journal update using inode + hash.
                        if let stagedIdentity = member.stagedIdentity,
                           let actual = try? FileIdentity.read(member.destination), actual == stagedIdentity,
                           try SafeFileWriter.sha256(member.destination) == member.digest { member.state = "published" }
                        if verifiedReuse {
                            guard try SafeFileWriter.sha256(member.destination) == member.digest else { throw LRCError(L10n.text("app.theReusableDestinationChangedAfterPreview", defaultValue: "The reusable destination changed after preview")) }
                            member.state = "published"
                        }
                        if member.state == "published" {
                            guard try SafeFileWriter.sha256(member.destination) == member.digest,
                                  (try (verifiedReuse || FileIdentity.read(member.destination) == member.stagedIdentity)) else { throw LRCError(L10n.text("app.thePublishedDestinationChangedAndCannotBeRegistered", defaultValue: "The published destination changed and cannot be registered")) }
                        }
                        if member.state != "published" {
                            if member.staging == nil {
                                member.staging = try SafeFileWriter.stage(in: member.destination.deletingLastPathComponent())
                                member.stagingCreatedIdentity = try FileIdentity.read(member.staging!)
                                member.state = "copying"
                                plan.groups[g].members[m] = member; try persist(plan, catalog: catalog)
                                try checkpoint("stagingCreated")
                            }
                            guard let staging = member.staging else { throw LRCError(L10n.text("app.theStagingLogIsMissing", defaultValue: "The staging log is missing")) }
                            if member.stagedIdentity == nil {
                                guard let created = member.stagingCreatedIdentity,
                                      try FileIdentity.read(staging).key == created.key else { throw LRCError(L10n.text("app.theTemporaryFileWasReplacedAndCannotBeRewritten", defaultValue: "The temporary file was replaced and cannot be rewritten")) }
                                try streamCopy(member.source, to: staging, expected: created)
                                guard try FileIdentity.read(member.source) == member.sourceIdentity,
                                      try SafeFileWriter.sha256(staging) == member.digest else { throw LRCError(L10n.text("app.copyReadbackVerificationFailed", defaultValue: "Copy readback verification failed")) }
                                member.stagedIdentity = try FileIdentity.read(staging); member.state = "verified"
                                plan.groups[g].members[m] = member; try persist(plan, catalog: catalog)
                                try checkpoint("copyVerified")
                            } else {
                                guard try FileIdentity.read(staging) == member.stagedIdentity,
                                      try SafeFileWriter.sha256(staging) == member.digest else { throw LRCError(L10n.text("app.unknownTemporaryFileIdentityManualVerificationRequired", defaultValue: "Unknown temporary file identity. Manual verification required")) }
                            }
                            if let old = member.targetIdentity {
                                // Never blindly repeat an overwrite after interruption.
                                if let recovery = member.recovery, FileManager.default.fileExists(atPath: recovery.path) {
                                    guard try FileIdentity.read(recovery) == old, try SafeFileWriter.sha256(recovery) == member.targetDigest else { throw LRCError(L10n.text("app.previousDestinationRecoveryIdentityMismatchBothFilesPreserved", defaultValue: "Previous destination recovery identity mismatch. Both files preserved")) }
                                } else {
                                    try validateReplacement(member, plan: plan, catalog: catalog)
                                    if member.recovery == nil {
                                        let directory = plan.targetRoot.appendingPathComponent("ImportRecovery/\(plan.id)")
                                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                        member.recovery = directory.appendingPathComponent(member.id + "-" + member.destination.lastPathComponent)
                                    }
                                    member.state = "replacementPrepared"; plan.groups[g].members[m] = member; try persist(plan, catalog: catalog)
                                    try checkpoint("replacementPrepared")
                                    guard let recovery = member.recovery,
                                          renamex_np(member.destination.path, recovery.path, UInt32(RENAME_EXCL)) == 0 else { throw SafeFileWriter.posix(L10n.text("app.preservePreviousDestination", defaultValue: "Preserve Previous Destination")) }
                                    guard try FileIdentity.read(recovery) == old, try SafeFileWriter.sha256(recovery) == member.targetDigest else { throw LRCError(L10n.text("app.theDestinationWasReplacedWhileBeingProtectedRecoveryFile", defaultValue: "The destination was replaced while being protected. Recovery file preserved; task paused")) }
                                }
                                member.state = "oldTargetPreserved"; plan.groups[g].members[m] = member; try persist(plan, catalog: catalog)
                                try checkpoint("oldTargetPreserved")
                            }
                            try SafeFileWriter.publish(staging, to: member.destination)
                            try checkpoint("renamedBeforeJournal")
                            member.state = "published"; plan.groups[g].members[m] = member; try persist(plan, catalog: catalog)
                            try checkpoint("published")
                        }
                        if member.isImage {
                            var photo = try ReferenceImporter.inspect(url: member.destination, root: root, rootURL: plan.targetRoot)
                            photo.digest = member.digest
                            if try catalog.index(photo) { await onImported(photo.id) }
                            try catalog.recordCopyOrigin(member)
                            try checkpoint("indexed")
                            if let collection = plan.collectionID {
                                let identityKey = photo.identityKey
                                let actualID = try await catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM photo WHERE identityKey=?", arguments: [identityKey]) }
                                if let actualID { try catalog.membership(ids: [actualID], collection: collection, add: true) }
                            }
                        }
                        member.state = "completed"; plan.groups[g].members[m] = member; try persist(plan, catalog: catalog)
                    }
                    try catalog.attachSidecars(group: plan.groups[g], root: root)
                    plan.groups[g].state = "completed"
                } catch {
                    plan.groups[g].state = (error is CancellationError || Task.isCancelled) ? "cancelled" : "needsReview"
                    plan.groups[g].diagnostic = error.localizedDescription
                }
                try persist(plan, catalog: catalog)
                if plan.groups[g].state == "cancelled" { plan.state = "cancelled"; break }
            }
            if plan.groups.contains(where: { $0.selected && $0.state == "cancelled" }) { plan.state = "cancelled" }
            if plan.state != "cancelled" { plan.state = plan.groups.contains { $0.selected && $0.state == "needsReview" } ? "needsReview" : "completed" }
            try persist(plan, catalog: catalog)
        } catch { plan.state = (error is CancellationError || Task.isCancelled) ? "cancelled" : "needsReview"; plan.omitted.append(error.localizedDescription); try? persist(plan, catalog: catalog) }
        return plan
    }
    func persist(_ plan: CopyPlan, catalog: CatalogStore) throws {
        let payload = try JSONEncoder().encode(plan)
        try catalog.database.write { try $0.execute(sql: "INSERT INTO importPlan(id,payload,state) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,state=excluded.state", arguments: [plan.id, payload, plan.state]) }
    }
    static func savedPlans(catalog: CatalogStore) throws -> [CopyPlan] {
        try catalog.database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM importPlan").map {
                let plan = try JSONDecoder().decode(CopyPlan.self,from:$0)
                guard plan.version == 2 else { throw LRCError(L10n.text("app.unsupportedCopyTaskOriginalDataPreserved", defaultValue: "Unsupported copy task. Original data preserved")) }
                return plan
            }
        }
    }
    private func ensureDestination(_ url: URL, root: URL) throws {
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw LRCError(L10n.text("app.theDestinationIsOutsideTheAuthorizedFolder", defaultValue: "The destination is outside the authorized folder")) }
        let directory = url.deletingLastPathComponent()
        // Reject symlink directories both before and after mkdir; never follow a known alias.
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw LRCError(L10n.text("app.theDestinationContainsASymbolicLink", defaultValue: "The destination contains a symbolic link")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw LRCError(L10n.text("app.theDestinationFolderIdentityChanged", defaultValue: "The destination folder identity changed")) }
    }
    private func streamCopy(_ source: URL, to staging: URL, expected: FileIdentity? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        let fd = Darwin.open(staging.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { try? input.close(); throw SafeFileWriter.posix(L10n.text("app.openStagingFile", defaultValue: "Open Staging File")) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        if let expected {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_ino == expected.inode, info.st_dev == expected.device else {
                try? input.close(); try? output.close(); throw LRCError(L10n.text("app.stagingFileIdentityChanged", defaultValue: "Staging file identity changed"))
            }
        }
        defer { try? input.close(); try? output.close() }
        try output.truncate(atOffset: 0)
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); try output.write(contentsOf: data)
        }
        try output.synchronize()
    }
    private func validateReplacement(_ member: CopyMember, plan: CopyPlan, catalog: CatalogStore) throws {
        guard try FileIdentity.read(member.destination) == member.targetIdentity,
              try SafeFileWriter.sha256(member.destination) == member.targetDigest else { throw LRCError(L10n.text("app.theOverwriteTargetChangedAfterPreviewThePreviousOverwrite", defaultValue: "The overwrite target changed after preview. The previous overwrite decision is invalid")) }
        let targetID = try FileIdentity.read(member.destination).key
        let managed = try catalog.photos()
        let protectedPaths = try catalog.protectedPaths()
        let otherPlans = try Self.savedPlans(catalog: catalog).filter { $0.id != plan.id && $0.state != "completed" }
        let activeImport = otherPlans.contains { $0.groups.contains { $0.members.contains { $0.destination == member.destination } } }
        let activeExport = try catalog.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM exportItem WHERE destination=? AND state NOT IN ('completed','cancelled','failed')", arguments: [member.destination.path]) ?? 0 }
        guard !activeImport, activeExport == 0 else { throw LRCError(L10n.text("app.anotherTaskReferencesTheTargetThePreviousOverwriteDecision", defaultValue: "Another task references the target. The previous overwrite decision is invalid")) }
        let sources = plan.groups.flatMap(\.members)
        guard !protectedPaths.contains(member.destination.resolvingSymlinksInPath().path), !managed.contains(where: { $0.identityKey == targetID }), !sources.contains(where: { $0.sourceIdentity.key == targetID }),
              plan.groups.filter({ $0.members.contains { $0.destination == member.destination } }).count == 1 else { throw LRCError(L10n.text("app.theTargetBecameAProtectedOriginalOrAnOutput", defaultValue: "The target became a protected original or an output of this batch")) }
        let siblings = try FileManager.default.contentsOfDirectory(at: member.destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        guard !siblings.contains(where: { $0 != member.destination && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(member.destination.deletingPathExtension().lastPathComponent) == .orderedSame }) else { throw LRCError(L10n.text("app.theOverwriteTargetGainedAnAttachmentRelationship", defaultValue: "The overwrite target gained an attachment relationship")) }
    }
    /// Only completed imports can release a verified recovery file, after explicit UI confirmation.
    /// Intent is persisted first, so a crash after unlink can be reconciled without touching another file.
    func cleanupOld(planID: String, memberID: String, catalog: CatalogStore) throws {
        guard var plan = try Self.savedPlans(catalog: catalog).first(where: { $0.id == planID }), plan.state == "completed",
              let g = plan.groups.firstIndex(where: { $0.members.contains { $0.id == memberID } }),
              let m = plan.groups[g].members.firstIndex(where: { $0.id == memberID }) else { throw LRCError(L10n.text("app.onlyPreviousFilesFromCompletedImportsCanBeCleaned", defaultValue: "Only previous files from completed imports can be cleaned up")) }
        let lease = try AccessLease(bookmark: plan.targetBookmark)
        defer { withExtendedLifetime(lease) {} }
        let member = plan.groups[g].members[m]
        guard let recovery = member.recovery, let old = member.targetIdentity,
              lease.url.resolvingSymlinksInPath() == plan.targetRoot,
              recovery.deletingLastPathComponent() == plan.targetRoot.appendingPathComponent("ImportRecovery/\(plan.id)"),
              recovery.resolvingSymlinksInPath() == recovery.standardizedFileURL else { throw LRCError(L10n.text("app.recoveryFileLocationMismatchCleanupRefused", defaultValue: "Recovery file location mismatch. Cleanup refused")) }
        if member.recoveryState == "deleted" { return }
        if FileManager.default.fileExists(atPath: recovery.path) {
            guard try FileIdentity.read(recovery) == old, try SafeFileWriter.sha256(recovery) == member.targetDigest else { throw LRCError(L10n.text("app.theRecoveryFileChangedCleanupRefused", defaultValue: "The recovery file changed. Cleanup refused")) }
            plan.groups[g].members[m].recoveryState = "deleting"; try persist(plan, catalog: catalog)
            try FileManager.default.removeItem(at: recovery)
        } else if member.recoveryState != "deleting" { throw LRCError(L10n.text("app.theRecoveryFileIsMissingCleanupCannotBeConfirmed", defaultValue: "The recovery file is missing. Cleanup cannot be confirmed")) }
        plan.groups[g].members[m].recoveryState = "deleted"; try persist(plan, catalog: catalog)
    }
    /// Restore old content to a new path only; never put it back by overwriting the current target.
    func restoreOld(_ member: CopyMember, to destination: URL) throws {
        guard let recovery = member.recovery, try FileIdentity.read(recovery) == member.targetIdentity,
              try SafeFileWriter.sha256(recovery) == member.targetDigest else { throw LRCError(L10n.text("app.recoveryFileVerificationFailed", defaultValue: "Recovery file verification failed")) }
        let staging = try SafeFileWriter.stage(in: destination.deletingLastPathComponent())
        try streamCopy(recovery, to: staging)
        guard try SafeFileWriter.sha256(staging) == member.targetDigest else { throw LRCError(L10n.text("app.recoveryCopyVerificationFailed", defaultValue: "Recovery copy verification failed")) }
        try SafeFileWriter.publish(staging, to: destination)
    }
}
