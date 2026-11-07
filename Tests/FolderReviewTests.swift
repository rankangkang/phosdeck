import XCTest
import GRDB
import CoreImage
@testable import Phosdeck

final class FolderReviewTests: XCTestCase {
    private var fixture: ImportTests!
    private var root: StorageRoot!
    private let service = FolderReviewService()
    override func setUpWithError() throws {
        fixture = ImportTests(); try fixture.setUpWithError()
        root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
    }
    override func tearDownWithError() throws { try fixture.tearDownWithError(); fixture = nil }
    private func image(_ path: String, color: CIColor = .red, index: Bool = true, digest: Bool = false) throws -> Photo {
        let file = fixture.source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.image(file, color: color)
        var photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: fixture.source)
        if digest { photo.digest = try SafeFileWriter.sha256(file) }
        if index { try fixture.catalog.index(photo) }
        return photo
    }
    private func preview(_ directory: String = "", recursive: Bool = true) async throws -> FolderReviewPreview {
        try await service.preview(scope: FolderReviewScope(root: root, directory: directory), includeSubfolders: recursive, catalog: fixture.catalog)
    }
    private func fail(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected refusal without publishing selected changes", file: file, line: line) }
        catch { }
    }

    func testPreviewIsReadOnlyAndClassifiesPhysicalSourcesOnce() async throws {
        let missing = try image("missing.jpg"), changed = try image("changed.jpg", digest: true)
        let moved = try image("old.jpg"), untouched = try image("untouched.jpg")
        let copies = try fixture.catalog.createVirtualCopies(ids: [missing.id, changed.id, moved.id])
        try fixture.catalog.setOrganization(ids: [untouched.id], rating: 4, flag: 1, colorLabel: 2)
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("missing.jpg"))
        try fixture.image(fixture.source.appendingPathComponent("changed.jpg"), color: .blue)
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("old.jpg"), to: fixture.source.appendingPathComponent("moved.jpg"))
        _ = try image("new.jpg", index: false)
        try Data("not an image".utf8).write(to: fixture.source.appendingPathComponent("broken.jpg"))
        let before = try fixture.catalog.photos(), sources = try fixture.catalog.sources()
        let found = try await preview()
        XCTAssertEqual(found.entries.filter { $0.kind == .added }.map(\.path), ["new.jpg"])
        XCTAssertEqual(found.entries.filter { $0.kind == .missing }.map(\.path), ["missing.jpg"])
        XCTAssertEqual(found.entries.filter { $0.kind == .changed }.map(\.path), ["changed.jpg"])
        let candidate = try XCTUnwrap(found.entries.first { $0.kind == .moved })
        XCTAssertEqual(candidate.path, "old.jpg"); XCTAssertEqual(candidate.candidates.map(\.relativePath), ["moved.jpg"])
        XCTAssertEqual(found.entries.filter { $0.kind == .issue }.map(\.path), ["broken.jpg"])
        XCTAssertEqual(try fixture.catalog.photos(), before)
        XCTAssertEqual(try fixture.catalog.sources(), sources)
        XCTAssertEqual(copies.count, 3)
    }

    func testConfirmBatchPreservesVersionsOrganizationHistoryAndFrozenOutputs() async throws {
        let moved = try image("old.jpg")
        let originalFile = fixture.source.appendingPathComponent("old.jpg")
        var recipe = EditRecipe(sourceDigest: try SafeFileWriter.sha256(originalFile), decoderVersion: EditRecipe.rasterDecoderVersion,
            baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        recipe.exposure = 0.7
        try fixture.catalog.saveRecipe(id: moved.id, recipe: recipe)
        try fixture.catalog.setOrganization(ids: [moved.id], rating: 5, flag: 1, colorLabel: 3)
        _ = try fixture.catalog.setCaptions([moved.id: "保留题注"])
        _ = try fixture.catalog.changeKeyword("保留词", ids: [moved.id], adding: true)
        try fixture.catalog.createSnapshot(photoID: moved.id, title: "keep")
        let copy = try XCTUnwrap(fixture.catalog.createVirtualCopies(ids: [moved.id]).first)
        let deleted = try XCTUnwrap(fixture.catalog.createVirtualCopies(ids: [moved.id]).first)
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE photo SET deleted=1 WHERE id=?", arguments: [deleted.id]) }
        let collection = PhotoCollection(id: "keep", name: "keep")
        try await fixture.catalog.database.write { try collection.insert($0) }
        try fixture.catalog.membership(ids: [moved.id, copy.id], collection: collection.id, add: true)
        let missing = try image("missing.jpg"), changed = try image("changed.jpg", color: .green, digest: true)
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("missing.jpg"))
        try fixture.image(fixture.source.appendingPathComponent("changed.jpg"), color: .blue)
        let new = try image("new.jpg", color: .blue, index: false)
        try FileManager.default.moveItem(at: originalFile, to: fixture.source.appendingPathComponent("renamed.jpg"))
        let frozen = Data("frozen export snapshot".utf8)
        try await fixture.catalog.database.write { try $0.execute(sql: "INSERT INTO exportItem(id,snapshot,state,destination) VALUES ('frozen',?,'failed',?)", arguments: [frozen, fixture.target.appendingPathComponent("old.jpg").path]) }
        func keptTables() throws -> [[Row]] {
            try fixture.catalog.database.read { db in
                try ["editHistory", "editSnapshot", "photoKeyword", "membership", "attachment", "exportItem"].map {
                    try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid")
                }
            }
        }
        let before = try await fixture.catalog.database.read { try Photo.fetchAll($0, sql: "SELECT * FROM photo WHERE sourceID=?", arguments: [moved.sourceKey]) }
        let kept = try keptTables()
        let found = try await preview()
        let confirmed = Set(found.entries.filter { $0.kind != .issue }.map(\.id))
        let result = try await service.apply(found, selected: confirmed, locations: [:], catalog: fixture.catalog)
        XCTAssertEqual(result.importedPhotoIDs.count, 1); XCTAssertEqual(result.relinked, 1); XCTAssertEqual(result.marked, 2)
        XCTAssertEqual(try fixture.catalog.photos().first { $0.relativePath == new.relativePath }?.id, result.importedPhotoIDs.first)
        let retainedVersions = try await fixture.catalog.database.read { try Photo.fetchAll($0, sql: "SELECT * FROM photo WHERE sourceID=?", arguments: [moved.sourceKey]) }
        XCTAssertEqual(retainedVersions.count, 3, "Deleted versions must retain the same source mapping too")
        for current in retainedVersions {
            var expected = try XCTUnwrap(before.first { $0.id == current.id }); expected.relativePath = "renamed.jpg"
            XCTAssertEqual(current, expected)
        }
        XCTAssertEqual(try fixture.catalog.photo(missing.id)?.availability, "missing")
        XCTAssertEqual(try fixture.catalog.photo(changed.id)?.availability, "changed")
        XCTAssertEqual(try keptTables(), kept, "Confirmation must leave edits, snapshots, membership and frozen bytes intact")
        XCTAssertEqual(try SafeFileWriter.sha256(fixture.source.appendingPathComponent("renamed.jpg")), recipe.sourceDigest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalFile.path))
    }

    func testStaleFilesCatalogAndDatabaseFailureRollBackTheEntireSelection() async throws {
        let missing = try image("missing.jpg")
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("missing.jpg"))
        _ = try image("new.jpg", index: false)
        let found = try await preview(), selected = Set(try await preview().entries.map(\.id))
        let before = try fixture.catalog.sources()
        try await fixture.catalog.database.write { try $0.execute(sql: "CREATE TRIGGER refuse_folder_import BEFORE INSERT ON photo BEGIN SELECT RAISE(ABORT,'injected folder failure'); END") }
        await fail { _ = try await service.apply(found, selected: selected, locations: [:], catalog: fixture.catalog) }
        XCTAssertEqual(try fixture.catalog.sources(), before, "An import failure must roll back earlier missing marks")
        try await fixture.catalog.database.write { try $0.execute(sql: "DROP TRIGGER refuse_folder_import") }
        try fixture.image(fixture.source.appendingPathComponent("new.jpg"), color: .blue)
        await fail { _ = try await service.apply(found, selected: selected, locations: [:], catalog: fixture.catalog) }
        XCTAssertEqual(try fixture.catalog.sources(), before)
        let refreshed = try await preview()
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE photoSource SET revision=revision+1 WHERE id=?", arguments: [missing.sourceKey]) }
        let edited = try fixture.catalog.sources()
        await fail { _ = try await service.apply(refreshed, selected: Set(refreshed.entries.map(\.id)), locations: [:], catalog: fixture.catalog) }
        XCTAssertEqual(try fixture.catalog.sources(), edited)
        XCTAssertEqual(try fixture.catalog.photos().count, 1)
    }

    func testCancellationDoesNotPublishOrLoseEarlierRecords() async throws {
        let old = try image("gone.jpg")
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("gone.jpg"))
        _ = try image("new.jpg", index: false)
        let found = try await preview(), selected = Set(try await preview().entries.map(\.id))
        let catalog = try XCTUnwrap(fixture.catalog), service = service
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.apply(found, selected: selected, locations: [:], catalog: catalog)
        }
        await fail { _ = try await task.value }
        XCTAssertEqual(try catalog.photo(old.id)?.availability, "available")
        XCTAssertEqual(try catalog.photos().count, 1)
    }

    func testOnlyExplicitSelectionAppliesAndReappearingOriginalRejectsAMove() async throws {
        let moved = try image("old.jpg")
        let missing = try image("gone.jpg")
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("old.jpg"), to: fixture.source.appendingPathComponent("candidate.jpg"))
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("gone.jpg"), to: fixture.target.appendingPathComponent("held.jpg"))
        _ = try image("new.jpg", index: false)
        let found = try await preview(), row = try XCTUnwrap(found.entries.first { $0.kind == .added })
        let result = try await service.apply(found, selected: [row.id], locations: [:], catalog: fixture.catalog)
        XCTAssertEqual(result.importedPhotoIDs.count, 1)
        XCTAssertEqual(try fixture.catalog.photo(moved.id)?.relativePath, "old.jpg")
        XCTAssertEqual(try fixture.catalog.photo(missing.id)?.availability, "available", "An unselected missing item must not change")
        try FileManager.default.copyItem(at: fixture.source.appendingPathComponent("candidate.jpg"), to: fixture.source.appendingPathComponent("old.jpg"))
        let movement = try XCTUnwrap(found.entries.first { $0.kind == .moved })
        await fail { _ = try await service.apply(found, selected: [movement.id], locations: [:], catalog: fixture.catalog) }
        XCTAssertEqual(try fixture.catalog.photo(moved.id)?.relativePath, "old.jpg", "An original reappearing after preview invalidates the proposed movement")
    }

    func testAmbiguousCopiesRequireAnExplicitLocationAndCannotShareOneFile() async throws {
        _ = try image("a.jpg", digest: true); _ = try image("b.jpg", digest: true)
        try FileManager.default.copyItem(at: fixture.source.appendingPathComponent("a.jpg"), to: fixture.source.appendingPathComponent("candidate-1.jpg"))
        try FileManager.default.copyItem(at: fixture.source.appendingPathComponent("a.jpg"), to: fixture.source.appendingPathComponent("candidate-2.jpg"))
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("a.jpg"))
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("b.jpg"))
        let found = try await preview(), rows = found.entries.filter { $0.kind == .moved }, chosen = Set(found.entries.map(\.id))
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(rows.allSatisfy { $0.candidates.count == 2 })
        XCTAssertNotNil(FolderReviewService.selectionIssue(found, selected: chosen, locations: [:]))
        let conflict = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, "candidate-1.jpg") })
        XCTAssertNotNil(FolderReviewService.selectionIssue(found, selected: chosen, locations: conflict))
        await fail { _ = try await service.apply(found, selected: chosen, locations: conflict, catalog: fixture.catalog) }
        let resolved = [rows[0].id: "candidate-1.jpg", rows[1].id: "candidate-2.jpg"]
        XCTAssertNil(FolderReviewService.selectionIssue(found, selected: chosen, locations: resolved))
        let result = try await service.apply(found, selected: chosen, locations: resolved, catalog: fixture.catalog)
        XCTAssertEqual(result.relinked, 2); XCTAssertTrue(result.importedPhotoIDs.isEmpty)
    }

    func testReturnedOrSameContentFilesRestoreAvailabilityWithoutResettingEdits() async throws {
        let photo = try image("returned.jpg", digest: true)
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE photoSource SET availability='missing' WHERE id=?", arguments: [photo.sourceKey]) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: fixture.source.appendingPathComponent("returned.jpg").path)
        let found = try await preview(), row = try XCTUnwrap(found.entries.first)
        XCTAssertEqual(row.kind, .changed); XCTAssertTrue(row.restoresAvailability)
        try fixture.catalog.setOrganization(ids: [photo.id], rating: 4)
        let result = try await service.apply(found, selected: [row.id], locations: [:], catalog: fixture.catalog)
        XCTAssertEqual(result.relinked, 1); XCTAssertEqual(result.marked, 0)
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.availability, "available")
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.rating, 4, "Per-version organization can change independently of a physical-source snapshot")
        let after = try await preview(); XCTAssertTrue(after.entries.isEmpty)
    }

    func testFolderBoundariesRecursionAndExcludedExportsAttachmentsAndHardLinks() async throws {
        let tracked = try image("keep.jpg")
        _ = try image("sub/new.jpg", index: false); _ = try image("sub/nested/deep.jpg", index: false)
        _ = try image("sub-other/outside.jpg", index: false)
        let exported = try image("sub/export.jpg", index: false), attached = try image("sub/attachment.jpg", index: false)
        let exportURL = fixture.source.appendingPathComponent(exported.relativePath)
        try await fixture.catalog.database.write { db in
            try db.execute(sql: "INSERT INTO exportItem(id,snapshot,state,destination) VALUES ('output',?,'completed',?)", arguments: [Data(), exportURL.path])
            try db.execute(sql: "INSERT INTO attachment VALUES (?,?,?)", arguments: [tracked.id, attached.relativePath, String(repeating: "a", count: 64)])
        }
        // Paths stored by the app are normalized, just like an output destination.
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE exportItem SET destination=? WHERE id='output'", arguments: [exportURL.resolvingSymlinksInPath().path]) }
        try FileManager.default.linkItem(at: fixture.source.appendingPathComponent("keep.jpg"), to: fixture.source.appendingPathComponent("sub/hardlink.jpg"))
        try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("sub/link.jpg"), withDestinationURL: fixture.source.appendingPathComponent("keep.jpg"))
        let direct = try await preview("sub", recursive: false)
        XCTAssertEqual(direct.entries.filter { $0.kind == .added }.map(\.path), ["sub/new.jpg"])
        XCTAssertEqual(direct.entries.filter { $0.kind == .issue }.map(\.path), ["sub/hardlink.jpg"])
        let recursive = try await preview("sub")
        let enumerated = try ImportPlanner.sourceFiles(URL(fileURLWithPath: root.path).appendingPathComponent("sub"), includeSubfolders: true).map(\.path)
        XCTAssertTrue(enumerated.contains { $0.hasSuffix("/nested/deep.jpg") }, "Skipping a symbolic-link leaf must not suppress a later directory")
        XCTAssertEqual(Set(recursive.entries.filter { $0.kind == .added }.map(\.path)), ["sub/new.jpg", "sub/nested/deep.jpg"],
            recursive.entries.map { "\($0.kind): \($0.path) \($0.problem ?? "")" }.joined(separator: "\n"))
        XCTAssertFalse(recursive.entries.contains { $0.path.contains("sub-other") || $0.path.hasSuffix("link.jpg") && !$0.path.hasSuffix("hardlink.jpg") })
        let before = try fixture.catalog.sources()
        await fail { _ = try await preview("../target") }
        XCTAssertEqual(try fixture.catalog.sources(), before)
    }

    func testMissingRootLinkedSourceAndChangedAuthorizationCannotMarkEverythingMissing() async throws {
        let photo = try image("keep.jpg")
        let original = fixture.source.appendingPathComponent("keep.jpg")
        let elsewhere = fixture.target.appendingPathComponent("outside.jpg")
        try FileManager.default.moveItem(at: original, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: elsewhere)
        let linked = try await preview()
        XCTAssertEqual(linked.entries.first?.kind, .issue)
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.availability, "available")
        try FileManager.default.removeItem(at: original)
        let found = try await preview()
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE storageRoot SET bookmark=? WHERE id=?", arguments: [Data("changed".utf8), root.id]) }
        await fail { _ = try await service.apply(found, selected: Set(found.entries.map(\.id)), locations: [:], catalog: fixture.catalog) }
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.availability, "available")
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE storageRoot SET bookmark=? WHERE id=?", arguments: [root.bookmark, root.id]) }
        try FileManager.default.moveItem(at: fixture.source, to: fixture.target.appendingPathComponent("offline"))
        await fail { _ = try await preview() }
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.availability, "available")
    }

    @MainActor func testReviewPresentationLocksCompetingCommandsAndCompletionKeepsLastImport() async throws {
        let photo = try image("keep.jpg")
        _ = try image("new.jpg", index: false)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = fixture.catalog; try model.reload()
        model.scope = root.id
        try model.completeImport(ids: [photo.id], cancelled: false)
        let previous = model.lastImport?.photoIDs
        model.reviewCurrentFolder()
        XCTAssertEqual(model.folderReview?.root.id, root.id)
        XCTAssertTrue(model.presentingSheet); XCTAssertFalse(model.canSwitchCatalog); XCTAssertFalse(model.canImportPhotos)
        let found = try await preview()
        let empty = try await service.apply(found, selected: [], locations: [:], catalog: fixture.catalog)
        try model.completedFolderReview(empty, catalog: fixture.catalog)
        XCTAssertEqual(model.lastImport?.photoIDs, previous)
        let result = try await service.apply(found, selected: Set(found.entries.filter { $0.kind == .added }.map(\.id)), locations: [:], catalog: fixture.catalog)
        try model.completedFolderReview(result, catalog: fixture.catalog)
        XCTAssertEqual(model.lastImport?.photoIDs, result.importedPhotoIDs)
        XCTAssertEqual(model.totalCount, 2)
        model.folderReview = nil
        XCTAssertTrue(model.canSwitchCatalog)
    }

    @MainActor func testConfirmingMissingActivePhotoLocksEditingAndRetainsItsRecipe() async throws {
        let photo = try image("active.jpg")
        let model = AppModel()
        model.catalog = fixture.catalog; try model.reload()
        model.choose([photo.id], active: photo.id)
        defer { model.choose([], active: nil) }
        for _ in 0..<300 where !model.canEdit { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.canEdit, "Start with a genuinely rendered synthetic photo")
        let recipe = try XCTUnwrap(model.recipe), stored = try fixture.catalog.photo(photo.id)?.recipe
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("active.jpg"), to: fixture.target.appendingPathComponent("active-held.jpg"))
        let found = try await preview()
        let result = try await service.apply(found, selected: [photo.sourceKey], locations: [:], catalog: fixture.catalog)
        try model.completedFolderReview(result, catalog: fixture.catalog)
        XCTAssertFalse(model.canEdit, "Reloading the same photo must lock the previous editable state immediately")
        for _ in 0..<300 where model.loadingPhoto { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.canEdit); XCTAssertEqual(model.recipe, recipe)
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.recipe, stored)
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.availability, "missing")
    }
}
