import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Phosdeck

final class ImportTests: XCTestCase {
    var directory: URL!
    var source: URL!
    var target: URL!
    var catalog: CatalogStore!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = directory.appendingPathComponent("source"); target = directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
    }
    override func tearDownWithError() throws { catalog = nil; try FileManager.default.removeItem(at: directory) }
    func image(_ url: URL, color: CIColor = .red) throws {
        let input = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10))
        let cg = try XCTUnwrap(CIContext().createCGImage(input, from: input.extent))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
    }
    func plan(_ policy: ConflictPolicy = .uniqueName, skip: Bool = true, sidecars: Bool = false) async throws -> CopyPlan {
        try await ImportPlanner().plan(source: source, target: target, layout: .flat, policy: policy, skipIdentical: skip, dateOverride: nil, confirmSidecars: sidecars, catalog: catalog)
    }
    func testCalendarRules() throws {
        XCTAssertEqual(try DateLayout.yearMonthDay.directory(date: "2024:02:29 23:58:00"), "2024/02-29")
        XCTAssertEqual(try DateLayout.compact.directory(date: "2025-12-31"), "2025/1231")
        XCTAssertEqual(try DateLayout.full.directory(date: "2026-01-01"), "2026/2026-01-01")
        XCTAssertThrowsError(try DateLayout.full.directory(date: "2025-02-29"))
        XCTAssertThrowsError(try DateLayout.full.directory(date: nil))
        XCTAssertEqual(try DateLayout.flat.directory(date: nil), "")
    }
    func testReferenceBatchTracksOnlyNewVersionsNotDuplicatesOrFailures() async throws {
        let a = source.appendingPathComponent("A.jpg"), b = source.appendingPathComponent("B.jpg")
        try image(a); try image(b, color: .blue)
        try Data("broken".utf8).write(to: source.appendingPathComponent("broken.jpg"))
        let importer = ReferenceImporter()
        let candidates = try await importer.preview(source: source, includeSubfolders: true, catalog: catalog)
        let first = await importer.add(source: source, candidates: candidates.filter { $0.url == a }, collection: nil, catalog: catalog)
        XCTAssertEqual(first.importedPhotoIDs.count, 1)
        let report = await importer.add(source: source, candidates: candidates, collection: nil, catalog: catalog)
        XCTAssertEqual(report.indexed, 1); XCTAssertEqual(report.ignored, 1); XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(report.importedPhotoIDs, Set(try catalog.photos().filter { $0.relativePath == "B.jpg" }.map(\.id)))
        XCTAssertEqual(report.sourceIDs.count, 2, "Pairing still receives existing as well as new sources")
        let duplicate = await importer.add(source: source, candidates: candidates.filter { $0.problem == nil }, collection: nil, catalog: catalog)
        XCTAssertTrue(duplicate.importedPhotoIDs.isEmpty); XCTAssertEqual(duplicate.indexed, 0)
    }

    func testReferenceScanAndPreviewKeepSubdirectoriesAfterSkippingLinkedFiles() async throws {
        try FileManager.default.createDirectory(at: source.appendingPathComponent("sub/nested"), withIntermediateDirectories: true)
        for path in ["keep.jpg", "sub/new.jpg", "sub/nested/deep.jpg"] { try image(source.appendingPathComponent(path)) }
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("sub/link.jpg"), withDestinationURL: source.appendingPathComponent("keep.jpg"))
        let root = try catalog.addRoot(url: source, bookmark: AccessLease.bookmark(source, readOnly: true))
        let importer = ReferenceImporter()
        let candidates = try await importer.preview(source: source, includeSubfolders: true, catalog: catalog)
        XCTAssertEqual(Set(candidates.map { $0.url.lastPathComponent }), ["keep.jpg", "new.jpg", "deep.jpg"])
        let report = await importer.scan(root: root, catalog: catalog) { _ in }
        XCTAssertTrue(report.errors.isEmpty)
        XCTAssertEqual(Set(try catalog.photos().map(\.relativePath)), ["keep.jpg", "sub/new.jpg", "sub/nested/deep.jpg"])
    }

    @MainActor func testCopyWithNoNewPhotosKeepsLastImportAndReportsZeroNewPhotos() async throws {
        try image(source.appendingPathComponent("A.jpg"))
        let suite = "copy-last-import-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") }, importPreferences: preferences)
        model.catalog = catalog; try model.reload()
        for attempt in 0..<2 {
            model.runCopy(try await plan())
            for _ in 0..<200 where model.busy { try await Task.sleep(for: .milliseconds(15)) }
            XCTAssertFalse(model.busy); XCTAssertNil(model.error)
            XCTAssertEqual(model.lastImport?.photoIDs.count, 1)
            XCTAssertTrue(model.status.contains("新增 \(attempt == 0 ? 1 : 0) 张"), model.status)
            XCTAssertEqual(model.showImportCompletion, attempt == 0)
        }
        let reopened = AppModel(importPreferences: preferences)
        reopened.catalog = catalog; try reopened.reload()
        XCTAssertEqual(reopened.lastImport?.photoIDs, model.lastImport?.photoIDs)
    }
    func testCopyBatchReportsAlreadyIndexedPhotoWhenCancelledAfterIndexingOnlyOnce() async throws {
        try image(source.appendingPathComponent("A.jpg"))
        let frozen = try await plan()
        actor Members {
            var ids: Set<String> = []
            func add(_ id: String) { ids.insert(id) }
            func value() -> Set<String> { ids }
        }
        let members = Members()
        let interrupted = await CopyImporter(checkpoint: { phase in
            if phase == "indexed" { throw CancellationError() }
        }).run(frozen, catalog: catalog, onImported: { await members.add($0) }) { _ in }
        XCTAssertEqual(interrupted.state, "cancelled")
        let first = await members.value()
        XCTAssertEqual(first, Set(try catalog.photos().map(\.id)))
        XCTAssertEqual(first.count, 1, "A successfully indexed member remains available after cancellation")
        let retried = Members()
        let result = await CopyImporter().run(interrupted, catalog: catalog, onImported: { await retried.add($0) }) { _ in }
        XCTAssertEqual(result.state, "completed")
        let repeated = await retried.value()
        XCTAssertTrue(repeated.isEmpty, "Recovery must not claim an existing photo as a new import")
    }
    func testCopyAndIdempotentRecoveryDoNotTouchSource() async throws {
        let original = source.appendingPathComponent("A.jpg"); try image(original)
        let digest = try SafeFileWriter.sha256(original)
        let frozen = try await plan()
        let completed = await CopyImporter().run(frozen, catalog: catalog) { _ in }
        XCTAssertEqual(completed.state, "completed")
        XCTAssertEqual(try SafeFileWriter.sha256(original), digest)
        XCTAssertEqual(try catalog.photos().count, 1)
        _ = await CopyImporter().run(completed, catalog: catalog) { _ in }
        XCTAssertEqual(try catalog.photos().count, 1)
        let duplicate = try await plan()
        XCTAssertEqual(duplicate.groups.first?.state, "skippedVerified")
    }
    func testUniqueGroupNamingAndSkip() async throws {
        try image(source.appendingPathComponent("A.jpg")); try image(target.appendingPathComponent("A.jpg"), color: .blue)
        try Data("sidecar".utf8).write(to: source.appendingPathComponent("A.xmp"))
        let unique = try await plan(sidecars: true)
        XCTAssertEqual(Set(unique.groups[0].members.map { $0.destination.lastPathComponent }), ["A-1.jpg", "A-1.xmp"])
        let skip = try await plan(.skip, sidecars: true)
        XCTAssertEqual(skip.groups[0].state, "skippedConflict")
        let overwrite = try await plan(.overwrite, sidecars: true)
        XCTAssertEqual(overwrite.groups[0].state, "needsReview")
    }
    func testRestrictedOverwriteRetainsOldTargetAndRestoresToNewPath() async throws {
        try image(source.appendingPathComponent("A.jpg")); let existing = target.appendingPathComponent("A.jpg")
        try image(existing, color: .blue)
        let oldDigest = try SafeFileWriter.sha256(existing)
        let frozen = try await plan(.overwrite)
        let completed = await CopyImporter().run(frozen, catalog: catalog) { _ in }
        XCTAssertEqual(completed.groups[0].state, "completed", completed.groups[0].diagnostic ?? "")
        let member = completed.groups[0].members[0]
        XCTAssertEqual(try SafeFileWriter.sha256(XCTUnwrap(member.recovery)), oldDigest)
        XCTAssertNotEqual(try SafeFileWriter.sha256(existing), oldDigest)
        let restored = target.appendingPathComponent("old-restored.jpg")
        try await CopyImporter().restoreOld(member, to: restored)
        XCTAssertEqual(try SafeFileWriter.sha256(restored), oldDigest)
        do { try await CopyImporter().restoreOld(member, to: existing); XCTFail("must not replace") } catch {}
    }
    func testManagedTargetAndChangedTargetCannotBeOverwritten() async throws {
        try image(source.appendingPathComponent("A.jpg")); let existing = target.appendingPathComponent("A.jpg")
        try image(existing, color: .blue)
        let frozen = try await plan(.overwrite)
        try Data("external change".utf8).write(to: existing)
        let stopped = await CopyImporter().run(frozen, catalog: catalog) { _ in }
        XCTAssertEqual(stopped.groups[0].state, "needsReview")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "external change")
        try image(existing, color: .blue)
        let root = try catalog.addRoot(url: target, bookmark: AccessLease.bookmark(target, readOnly: true))
        try catalog.index(ReferenceImporter.inspect(url: existing, root: root, rootURL: target))
        let protected = try await plan(.overwrite)
        XCTAssertEqual(protected.groups[0].state, "needsReview")
    }
    func testTargetInsideSourceIsRejected() async throws {
        do {
            _ = try await ImportPlanner().plan(source: source, target: source.appendingPathComponent("nested"), layout: .flat, policy: .uniqueName, skipIdentical: true, dateOverride: nil, confirmSidecars: false, catalog: catalog)
            XCTFail("nested target must fail")
        } catch {}
    }
    func testPerGroupPoliciesAndExplicitUnknownAttachment() async throws {
        for name in ["A", "B"] {
            try image(source.appendingPathComponent(name + ".jpg"))
            try image(target.appendingPathComponent(name + ".jpg"), color: .blue)
        }
        let attachment = source.appendingPathComponent("notes.bin")
        try Data("opaque original bytes".utf8).write(to: attachment)
        let a = source.appendingPathComponent("A").path, b = source.appendingPathComponent("B").path
        var choices = ImportChoices()
        choices.policies[b] = .skip
        choices.attachments[attachment.path] = a
        var preview = try await ImportPlanner().plan(source: source, target: target, layout: .flat, policy: .uniqueName, skipIdentical: true, dateOverride: nil, confirmSidecars: false, catalog: catalog, choices: choices)
        XCTAssertEqual(preview.groups.first { $0.sourceKey == a }?.state, "needsReview", "opaque attachments must never be automatically renamed")
        choices.directories[a] = "separate"
        preview = try await ImportPlanner().plan(source: source, target: target, layout: .flat, policy: .uniqueName, skipIdentical: true, dateOverride: nil, confirmSidecars: false, catalog: catalog, choices: choices)
        XCTAssertEqual(preview.groups.first { $0.sourceKey == b }?.state, "skippedConflict")
        let completed = await CopyImporter().run(preview, catalog: catalog) { _ in }
        XCTAssertEqual(completed.groups.first { $0.sourceKey == a }?.state, "completed")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("separate/notes.bin")), try Data(contentsOf: attachment))
        XCTAssertEqual(try catalog.photos().count, 1)
        choices.directories[a] = "../outside"
        let rejected = try await ImportPlanner().plan(source: source, target: target, layout: .flat, policy: .uniqueName, skipIdentical: true, dateOverride: nil, confirmSidecars: false, catalog: catalog, choices: choices)
        XCTAssertEqual(rejected.groups.first { $0.sourceKey == a }?.state, "needsReview")
    }
    func testEveryCopyJournalBoundaryCanResumeWithoutReplacingSource() async throws {
        for boundary in ["stagingCreated", "copyVerified", "replacementPrepared", "oldTargetPreserved", "renamedBeforeJournal", "published", "indexed"] {
            let fixture = ImportTests(); try fixture.setUpWithError()
            defer { try? fixture.tearDownWithError() }
            let original = fixture.source.appendingPathComponent("A.jpg")
            try fixture.image(original)
            let existing = fixture.target.appendingPathComponent("A.jpg")
            try fixture.image(existing, color: .blue)
            let sourceHash = try SafeFileWriter.sha256(original), oldHash = try SafeFileWriter.sha256(existing)
            let frozen = try await fixture.plan(.overwrite)
            let stopped = await CopyImporter(checkpoint: { point in
                if point == boundary { throw LRCError("Injected interruption at " + point) }
            }).run(frozen, catalog: fixture.catalog) { _ in }
            XCTAssertEqual(stopped.state, "needsReview", boundary)
            var resumed = try XCTUnwrap(CopyImporter.savedPlans(catalog: fixture.catalog).first)
            resumed.groups[0].state = "planned"
            let result = await CopyImporter().run(resumed, catalog: fixture.catalog) { _ in }
            XCTAssertEqual(result.state, "completed", boundary + " " + (result.groups[0].diagnostic ?? ""))
            XCTAssertEqual(try SafeFileWriter.sha256(original), sourceHash)
            XCTAssertEqual(try SafeFileWriter.sha256(existing), sourceHash)
            XCTAssertEqual(try SafeFileWriter.sha256(XCTUnwrap(result.groups[0].members[0].recovery)), oldHash)
            XCTAssertEqual(try fixture.catalog.photos().count, 1)
        }
    }
    func testRecoveryCleanupOnlyDeletesVerifiedCompletedOldFile() async throws {
        try image(source.appendingPathComponent("A.jpg"))
        try image(target.appendingPathComponent("A.jpg"), color: .blue)
        let frozen = try await plan(.overwrite)
        let result = await CopyImporter().run(frozen, catalog: catalog) { _ in }
        let member = result.groups[0].members[0]
        let recovery = try XCTUnwrap(member.recovery)
        try await CopyImporter().cleanupOld(planID: result.id, memberID: member.id, catalog: catalog)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertEqual(try SafeFileWriter.sha256(member.source), member.digest)
        XCTAssertEqual(try SafeFileWriter.sha256(member.destination), member.digest)
        try await CopyImporter().cleanupOld(planID: result.id, memberID: member.id, catalog: catalog)
        XCTAssertEqual(try CopyImporter.savedPlans(catalog: catalog)[0].groups[0].members[0].recoveryState, "deleted")
    }

    func testActiveImportReservesOverwriteTarget() async throws {
        try image(source.appendingPathComponent("A.jpg")); try image(target.appendingPathComponent("A.jpg"), color: .blue)
        let original = try await plan(.overwrite)
        try await CopyImporter().persist(original, catalog: catalog)
        let second = try await plan(.overwrite)
        XCTAssertEqual(second.groups[0].state, "needsReview")
        XCTAssertTrue(second.groups[0].members.isEmpty)
    }
    func testChangedPublishedFileCannotBeIndexedOnResume() async throws {
        try image(source.appendingPathComponent("A.jpg"))
        let frozen = try await plan()
        var result = await CopyImporter(checkpoint: { boundary in
            if boundary == "published" { throw LRCError("stop after published journal") }
        }).run(frozen, catalog: catalog) { _ in }
        let destination = result.groups[0].members[0].destination
        try Data("third party content".utf8).write(to: destination)
        result.groups[0].state = "planned"
        let stopped = await CopyImporter().run(result, catalog: catalog) { _ in }
        XCTAssertEqual(stopped.state, "needsReview")
        XCTAssertEqual(try catalog.photoCount(), 0)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "third party content")
    }

}

extension ImportTests {
    func testImportPreviewSelectionSubfoldersAndChangedFiles() async throws {
        let a = source.appendingPathComponent("A.jpg")
        let b = source.appendingPathComponent("B.jpg")
        let nested = source.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try image(a); try image(b); try image(nested.appendingPathComponent("C.jpg"))
        let importer = ReferenceImporter()
        let shallow = try await importer.preview(source: source, includeSubfolders: false, catalog: catalog)
        XCTAssertEqual(shallow.count, 2)
        XCTAssertEqual(try catalog.photoCount(), 0, "preview must never write catalog records")
        let all = try await importer.preview(source: source, includeSubfolders: true, catalog: catalog)
        XCTAssertEqual(all.count, 3)
        try catalog.collection(name: "导入精选", id: "selected")
        let report = await importer.add(source: source, candidates: all.filter { $0.url == a }, collection: "selected", catalog: catalog)
        XCTAssertTrue(report.errors.isEmpty, report.errors.joined(separator: ";"))
        XCTAssertEqual(report.indexed, 1)
        XCTAssertEqual(try catalog.photoCount(), 1)
        XCTAssertEqual(try catalog.members("selected").count, 1)
        let again = try await importer.preview(source: source, includeSubfolders: true, catalog: catalog)
        XCTAssertEqual(again.filter(\.alreadyImported).map(\.url), [a])
        try Data("changed".utf8).write(to: b)
        let stopped = await importer.add(source: source, candidates: all.filter { $0.url == b }, collection: nil, catalog: catalog)
        XCTAssertEqual(stopped.errors.count, 1)
        XCTAssertEqual(try catalog.photoCount(), 1)
        let copy = try await ImportPlanner().plan(source: source, target: target, layout: .flat, policy: .uniqueName, skipIdentical: true, dateOverride: nil, confirmSidecars: false, catalog: catalog, selectedPaths: [a.path], includeSubfolders: true)
        XCTAssertEqual(copy.groups.flatMap(\.members).map(\.source), [a])
        let result = await CopyImporter().run(copy, catalog: catalog) { _ in }
        XCTAssertEqual(result.groups.first?.state, "completed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("A.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("C.jpg").path))
    }
}

private actor ConflictReplies {
    var requests: [ImportConflict] = []
    var replies: [ImportConflictDecision]
    init(_ replies: [ImportConflictDecision] = []) { self.replies = replies }
    func answer(_ conflict: ImportConflict) -> ImportConflictDecision? {
        requests.append(conflict)
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}

extension ImportTests {
    private func deferredPlan(includeSidecars: Bool = true) async throws -> CopyPlan {
        try await ImportPlanner().plan(source: source, target: target, layout: .flat, policy: .skip, skipIdentical: true,
            dateOverride: nil, confirmSidecars: includeSidecars, catalog: catalog, deferConflicts: true, includeSidecars: includeSidecars)
    }
    func testDirectImportOnlyAsksAtConflictsAndAppliesPolicyToRemainingBatch() async throws {
        for name in ["A", "B", "C"] { try image(source.appendingPathComponent(name + ".jpg")) }
        let plan = try await deferredPlan()
        // A target appears after planning: runtime must ask, not silently choose a policy.
        for name in ["B", "C"] { try image(target.appendingPathComponent(name + ".jpg"), color: .blue) }
        let replies = ConflictReplies([ImportConflictDecision(policy: .uniqueName, applyToRemaining: true)])
        let result = await CopyImporter().run(plan, catalog: catalog, resolveConflict: { conflict in
            // The first non-conflicting photo must already be copied before asking about B.
            XCTAssertTrue(FileManager.default.fileExists(atPath: self.target.appendingPathComponent("A.jpg").path))
            return await replies.answer(conflict)
        }) { _ in }
        let count = await replies.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(result.state, "completed")
        XCTAssertEqual(result.groups.flatMap(\.members).map { $0.destination.lastPathComponent }, ["A.jpg", "B-1.jpg", "C-1.jpg"])
        XCTAssertEqual(try catalog.photoCount(), 3)
        let newBatch = try await deferredPlan()
        let cancelled = ConflictReplies()
        let next = await CopyImporter().run(newBatch, catalog: catalog, resolveConflict: { await cancelled.answer($0) }) { _ in }
        let nextCount = await cancelled.requests.count
        XCTAssertEqual(nextCount, 1, "a new batch must ask again")
        XCTAssertEqual(next.state, "cancelled")
    }
    func testConflictSkipOverwriteAndProtectedTargetNeverInheritUnsafeOverwrite() async throws {
        for name in ["A", "B", "C"] {
            try image(source.appendingPathComponent(name + ".jpg"))
            try image(target.appendingPathComponent(name + ".jpg"), color: .blue)
        }
        let root = try catalog.addRoot(url: target, bookmark: AccessLease.bookmark(target, readOnly: true))
        let managed = target.appendingPathComponent("C.jpg")
        try catalog.index(ReferenceImporter.inspect(url: managed, root: root, rootURL: target))
        let old = try SafeFileWriter.sha256(managed)
        let replies = ConflictReplies([
            ImportConflictDecision(policy: .skip, applyToRemaining: false),
            ImportConflictDecision(policy: .overwrite, applyToRemaining: true),
            ImportConflictDecision(policy: .skip, applyToRemaining: true)
        ])
        let result = await CopyImporter().run(try await deferredPlan(), catalog: catalog, resolveConflict: { await replies.answer($0) }) { _ in }
        let requests = await replies.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertNotNil(requests.last?.overwriteRestriction)
        XCTAssertEqual(result.groups.map(\.state), ["skippedConflict", "completed", "skippedConflict"])
        let replacement = result.groups[1].members[0]
        XCTAssertEqual(try SafeFileWriter.sha256(XCTUnwrap(replacement.recovery)), old)
        XCTAssertEqual(try SafeFileWriter.sha256(replacement.destination), replacement.digest)
        XCTAssertEqual(try SafeFileWriter.sha256(managed), old)
    }
    func testCancelConflictPreservesPendingFilesAndIdenticalCopyNeedsNoPrompt() async throws {
        for name in ["A", "B"] { try image(source.appendingPathComponent(name + ".jpg")) }
        let a = target.appendingPathComponent("A.jpg")
        try image(a, color: .blue)
        let old = try SafeFileWriter.sha256(a)
        let replies = ConflictReplies()
        let cancelled = await CopyImporter().run(try await deferredPlan(), catalog: catalog, resolveConflict: { await replies.answer($0) }) { _ in }
        XCTAssertEqual(cancelled.state, "cancelled")
        XCTAssertEqual(try SafeFileWriter.sha256(a), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("B.jpg").path))
        try image(a)
        let noPrompts = ConflictReplies()
        let completed = await CopyImporter().run(try await deferredPlan(), catalog: catalog, resolveConflict: { await noPrompts.answer($0) }) { _ in }
        let count = await noPrompts.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(completed.state, "completed")
        XCTAssertEqual(try catalog.photoCount(), 2)
        try Data("metadata".utf8).write(to: source.appendingPathComponent("A.xmp"))
        let withoutSidecars = try await deferredPlan(includeSidecars: false)
        XCTAssertFalse(withoutSidecars.groups.flatMap(\.members).contains { !$0.isImage })
    }
    @MainActor func testModelDirectImportCancelsWhileWaitingForConflict() async throws {
        try image(source.appendingPathComponent("A.jpg"))
        try image(target.appendingPathComponent("A.jpg"), color: .blue)
        let model = AppModel(); model.catalog = catalog
        model.startCopy(source: source, target: target, selectedPaths: [source.appendingPathComponent("A.jpg").path],
            includeSubfolders: true, layout: .flat, dateOverride: nil, includeSidecars: false, collection: nil)
        for _ in 0..<200 where model.importConflict == nil && model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.importConflict)
        model.task?.cancel()
        await model.task?.value
        XCTAssertNil(model.importConflict)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(try catalog.photoCount(), 0)
        XCTAssertTrue(model.status.contains("取消"))
        model.catalog = nil
    }
}
