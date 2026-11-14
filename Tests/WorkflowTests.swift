import XCTest
import CoreImage
import ImageIO
import AppKit
import SwiftUI
import GRDB
@testable import Phosdeck

final class WorkflowTests: XCTestCase {
    @MainActor func testImportCullingRestoresHeldBrowseContextWithoutRefreshingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        try catalog.database.write { db in
            for n in 0..<202 {
                let id = String(format: "%03d", n)
                try Photo(id: id, rootID: root.id, relativePath: "before-\(id).jpg", identity: Data(), identityKey: id,
                          rating: 5, flag: 1, width: 1, height: 1).insert(db)
            }
            for id in ["new-a", "new-b"] {
                try Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id, width: 1, height: 1).insert(db)
            }
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; model.scope = root.id; model.search = "before"; model.ratingThreshold = 3
        model.ratingComparison = .greaterThan; model.flagFilter = [1]; model.photoSort = .filename
        model.libraryFiltersOpen = false; model.holdFilterResults = true
        try model.reload(); model.pageOffset = 200; try model.reloadPhotos()
        model.choose(["001", "201"], active: "201")
        let original = model.query
        try model.completeImport(ids: ["new-a", "new-b"], cancelled: true)
        XCTAssertTrue(model.showImportCompletion)
        model.showLastImport(startCulling: true)
        XCTAssertTrue(model.isViewingImport); XCTAssertTrue(model.singleView); XCTAssertFalse(model.editMode)
        XCTAssertFalse(model.filtersEnabled); XCTAssertFalse(model.holdFilterResults)
        XCTAssertEqual(model.resultCount, 2); XCTAssertEqual(Set(model.photos.map(\.id)), ["new-a", "new-b"])
        XCTAssertEqual(model.selection, ["new-a"])
        model.organize(rating: 5, flag: 1)
        model.returnFromImport()
        XCTAssertEqual(model.query, original); XCTAssertEqual(model.pageOffset, 200)
        XCTAssertEqual(model.selection, ["001", "201"]); XCTAssertEqual(model.activeID, "201")
        XCTAssertFalse(model.libraryFiltersOpen); XCTAssertFalse(model.singleView)
        model.filterCriteriaChanged() // Delayed SwiftUI callbacks must not rebuild the held result.
        XCTAssertEqual(model.query, original); XCTAssertEqual(model.resultCount, 202)
        XCTAssertEqual(model.pageOffset, 200); XCTAssertEqual(model.selection, ["001", "201"])
        model.showLastImport(); model.setScope("all")
        XCTAssertFalse(model.isViewingImport)
        XCTAssertEqual(try catalog.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [original.snapshotID!]) }, 0)
        try model.completeImport(ids: [], cancelled: false)
        XCTAssertFalse(model.showImportCompletion); XCTAssertEqual(model.lastImport?.photoIDs, ["new-a", "new-b"])
        try model.activateCatalog(CatalogStore(directory: directory.appendingPathComponent("next")))
        XCTAssertNil(model.lastImport); XCTAssertFalse(model.isViewingImport)
    }

    @MainActor func testLatestNonemptyImportSurvivesCatalogReopenWithoutReusingSQLSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "latest-import-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let ids = Set((0..<205).map { String(format: "new-%03d", $0) })
        var oldSnapshot = ""
        do {
            let catalog = try CatalogStore(directory: directory)
            let root = try catalog.addRoot(url: directory, bookmark: Data())
            try catalog.database.write { db in
                for id in ids.union(["older", "unrelated"]) {
                    try Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id, width: 1, height: 1).insert(db)
                }
            }
            let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") }, importPreferences: preferences)
            model.catalog = catalog; model.search = "not-this-batch"; model.filterSections = [.text]
            try model.reload(); try model.completeImport(ids: ["older"], cancelled: false)
            oldSnapshot = try XCTUnwrap(model.lastImport?.snapshotID)
            try model.completeImport(ids: ids, cancelled: true)
            XCTAssertEqual(model.lastImport?.photoIDs, ids)
            XCTAssertTrue(model.lastImport?.cancelled == true)
            XCTAssertEqual(try catalog.database.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [oldSnapshot]) }, 0)
            let key = catalog.fileURL.path + ":lastImport", saved = preferences.data(forKey: key)
            XCTAssertNotNil(saved)
            try model.completeImport(ids: [], cancelled: false)
            try model.completeImport(ids: [], cancelled: true)
            XCTAssertEqual(preferences.data(forKey: key), saved, "No-op, failed or cancelled-before-import attempts retain the prior real batch")
            XCTAssertFalse(model.showImportCompletion)
            _ = try catalog.setVersionDeletion(["new-000": true])
            _ = try catalog.createVirtualCopies(ids: ["new-001"])
            oldSnapshot = try XCTUnwrap(model.lastImport?.snapshotID)
        }
        let catalog = try CatalogStore(directory: directory)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") }, importPreferences: preferences)
        model.catalog = catalog; try model.reload()
        XCTAssertEqual(model.lastImport?.photoIDs, ids.subtracting(["new-000"]))
        XCTAssertNotEqual(model.lastImport?.snapshotID, oldSnapshot)
        XCTAssertFalse(model.showImportCompletion, "Reopening must not show an old completion banner or start culling")
        XCTAssertEqual(model.scope, "all")
        XCTAssertEqual(try catalog.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 13)
        model.showLastImport()
        XCTAssertEqual(model.resultCount, 204); XCTAssertEqual(model.photos.count, 200)
        model.changePage(1)
        XCTAssertEqual(model.photos.count, 4)
        XCTAssertTrue(Set(model.photos.map(\.id)).isSubset(of: ids))
        XCTAssertFalse(model.lastImport!.photoIDs.contains("unrelated"))
        XCTAssertTrue(try catalog.photo("new-000") == nil, "Restoring navigation cannot revive a removed version")
    }

    @MainActor func testLastImportRejectsWrongCatalogAndMalformedRecordsWithoutDeletingThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "invalid-import-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        try catalog.index(Photo(id: "a", rootID: root.id, relativePath: "a.jpg", identity: Data(), identityKey: "a", width: 1, height: 1))
        let first = AppModel(importPreferences: preferences)
        first.catalog = catalog; try first.completeImport(ids: ["a"], cancelled: false)
        let key = catalog.fileURL.path + ":lastImport"
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(preferences.data(forKey: key))) as? [String: Any])
        value["catalogID"] = "different-catalog-at-the-same-path"
        let different = try JSONSerialization.data(withJSONObject: value)
        preferences.set(different, forKey: key)
        let second = AppModel(importPreferences: preferences)
        second.catalog = catalog; try second.reload()
        XCTAssertNil(second.lastImport); XCTAssertEqual(preferences.data(forKey: key), different)
        let malformed = Data([0xff, 0x00])
        preferences.set(malformed, forKey: key)
        let third = AppModel(importPreferences: preferences)
        third.catalog = catalog; try third.reload()
        XCTAssertNil(third.lastImport); XCTAssertEqual(third.totalCount, 1)
        XCTAssertTrue(third.reports.contains { $0.contains("最近一次导入记录无法读取") })
        XCTAssertEqual(preferences.data(forKey: key), malformed)
    }

    @MainActor func testLastImportCatalogIsolationAndReturnAfterDeletingOriginalCollection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "isolated-import-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let first = try CatalogStore(directory: directory.appendingPathComponent("one"))
        let second = try CatalogStore(directory: directory.appendingPathComponent("two"))
        for catalog in [first, second] {
            let root = try catalog.addRoot(url: catalog.directory, bookmark: Data())
            for id in ["a", "b"] {
                try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id, width: 1, height: 1))
            }
        }
        try first.collection(name: "Original", id: "original")
        try first.membership(ids: ["b"], collection: "original", add: true)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") }, importPreferences: preferences)
        model.catalog = first; model.scope = "collection:original"; model.holdFilterResults = true
        try model.reload(); try model.completeImport(ids: ["a"], cancelled: false)
        model.showLastImport(); model.deleteCollection("original")
        XCTAssertTrue(model.isViewingImport)
        model.returnFromImport()
        XCTAssertEqual(model.scope, "all", "An import's deleted return source must fall back to an existing source")
        XCTAssertEqual(model.resultCount, 2)
        try model.activateCatalog(second)
        XCTAssertNil(model.lastImport); XCTAssertFalse(model.undo.canUndo)
        try model.completeImport(ids: ["b"], cancelled: false)
        try model.activateCatalog(first)
        XCTAssertEqual(model.lastImport?.photoIDs, ["a"])
        XCTAssertFalse(model.isViewingImport); XCTAssertFalse(model.showImportCompletion)
        try model.activateCatalog(second)
        XCTAssertEqual(model.lastImport?.photoIDs, ["b"], "The same photo IDs in another catalog cannot merge batches")
    }

    @MainActor func testConfirmedAdjustmentRangePersistsAndDraftDoesNotOverwriteIt() throws {
        let suite = "workflow-options-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(adjustmentPreferences: preferences)
        XCTAssertFalse(model.confirmedAdjustmentOptions.geometry)
        XCTAssertFalse(model.confirmedAdjustmentOptions.details)
        let whiteBalanceOnly = RecipePasteOptions(tone: false, whiteBalance: true, color: false, curves: false, zones: false)
        model.confirmAdjustmentOptions(whiteBalanceOnly)
        var cancelledDraft = model.confirmedAdjustmentOptions
        cancelledDraft.tone = true
        XCTAssertEqual(AppModel(adjustmentPreferences: preferences).confirmedAdjustmentOptions, whiteBalanceOnly,
                       "Cancelling a sheet must leave the last confirmed range untouched")
        model.confirmAdjustmentOptions(RecipePasteOptions(tone: false, whiteBalance: false, color: false, curves: false, zones: false))
        XCTAssertEqual(model.confirmedAdjustmentOptions, whiteBalanceOnly, "An empty range is not a confirmation")
        model.confirmAdjustmentOptions(cancelledDraft)
        XCTAssertEqual(AppModel(adjustmentPreferences: preferences).confirmedAdjustmentOptions, cancelledDraft)
    }

    @MainActor func testPreviousAdjustmentsCaptureTheLastEditablePhotoAndRespectSheetGate() throws {
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        let a = Photo(id: "a", rootID: "r", relativePath: "a.jpg", identity: Data(), identityKey: "previous-a", width: 1, height: 1)
        let b = Photo(id: "b", rootID: "r", relativePath: "b.jpg", identity: Data(), identityKey: "previous-b", width: 1, height: 1)
        model.photos = [a,b]; model.activeID = a.id; model.activePhoto = a; model.selection = [a.id]
        var adjusted = recipe(); adjusted.exposure = 1.25
        model.recipe = adjusted; model.canEdit = true
        model.choose([b.id], active: b.id)
        XCTAssertEqual(model.previousAdjustmentSource?.photo.id, a.id)
        XCTAssertEqual(model.previousAdjustmentSource?.recipe.exposure, 1.25)
        model.recipe = recipe(); model.canEdit = true
        model.catalogUtilityOpen = true
        model.requestAdjustments(.previous)
        XCTAssertNil(model.adjustmentRequest, "Modal text/editing must not trigger another sheet")
        model.catalogUtilityOpen = false
        model.requestAdjustments(.previous)
        XCTAssertEqual(model.adjustmentRequest, .previous)
        model.adjustmentRequest = nil
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        var removedSource = a; removedSource.rootID = root.id; removedSource.deleted = true
        try catalog.database.write { try removedSource.insert($0) }
        model.catalog = catalog
        model.requestAdjustments(.previous)
        XCTAssertNil(model.adjustmentRequest, "A deleted prior source must not be applied")
        XCTAssertNil(model.previousAdjustmentSource)
        model.canEdit = false
        model.choose([a.id], active: a.id)
        XCTAssertNil(model.previousAdjustmentSource, "An unavailable intervening photo must not silently reuse an older source")
    }

    @MainActor func testRatingFilterStarsClearToUnratedWithoutChangingComparison() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        try catalog.database.write { db in
            for rating in [0, 3, 5] {
                try Photo(id: "r\(rating)", rootID: root.id, relativePath: "\(rating).jpg", identity: Data(), identityKey: "star-toggle-\(rating)", rating: rating, width: 1, height: 1).insert(db)
            }
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog
        model.ratingComparison = .equal
        model.toggleRatingFilter(3)
        XCTAssertEqual(try catalog.page(model.query, offset: 0).photos.map(\.id), ["r3"])
        model.toggleRatingFilter(3)
        XCTAssertEqual(model.ratingThreshold, 0)
        XCTAssertEqual(model.ratingComparison, .equal)
        XCTAssertTrue(model.hasLibraryFilters, "Unlit stars with equality find only unrated photos")
        XCTAssertEqual(try catalog.page(model.query, offset: 0).photos.map(\.id), ["r0"])
        model.ratingComparison = .atLeast
        model.toggleRatingFilter(5)
        model.toggleRatingFilter(3)
        XCTAssertEqual(model.ratingThreshold, 3, "Clicking another lit star changes the threshold")
        model.toggleRatingFilter(3)
        XCTAssertFalse(model.hasLibraryFilters, "Unlit stars with at-least remove the rating restriction")
        XCTAssertEqual(try catalog.page(model.query, offset: 0).total, 3)
    }

    @MainActor func testZeroStarComparisonSurvivesDisablingAndClearsToDefault() {
        let model = AppModel()
        model.ratingComparison = .equal
        XCTAssertTrue(model.filterSectionHasCriteria(.attribute))
        XCTAssertTrue(model.hasLibraryFilters)
        XCTAssertEqual(model.query.ratingComparison, .equal)
        model.filtersEnabled = false
        XCTAssertEqual(model.query.ratingComparison, .atLeast)
        XCTAssertEqual(model.query.ratingThreshold, 0)
        XCTAssertEqual(model.ratingComparison, .equal)
        model.filtersEnabled = true
        XCTAssertEqual(model.query.ratingComparison, .equal)
        model.clearFilters()
        XCTAssertEqual(model.ratingComparison, .atLeast)
        XCTAssertFalse(model.hasLibraryFilters)
    }

    @MainActor func testModuleRoundTripsKeepLibraryViewAndPhotoContext() {
        let model = AppModel()
        model.scope = "collection:synthetic"; model.search = "flower"; model.ratingThreshold = 3
        model.pageOffset = 200; model.activeID = "active"; model.selection = ["active", "other"]
        model.selectWorkspace(.single)
        model.selectModule(.library)
        XCTAssertEqual(model.workspaceMode, .single, "Clicking the current module must not reset its view")
        model.selectModule(.develop)
        model.selectModule(.library)
        XCTAssertEqual(model.workspaceMode, .single)
        model.selectWorkspace(.grid)
        model.selectModule(.develop)
        model.selectModule(.library)
        XCTAssertEqual(model.workspaceMode, .grid)
        XCTAssertEqual(model.scope, "collection:synthetic"); XCTAssertEqual(model.search, "flower")
        XCTAssertEqual(model.ratingThreshold, 3); XCTAssertEqual(model.pageOffset, 200)
        XCTAssertEqual(model.activeID, "active"); XCTAssertEqual(model.selection, ["active", "other"])
    }

    @MainActor func testDevelopToolsFinishConsistentlyAndKeepUnsavedDraftOnFailure() {
        let model = AppModel()
        model.selectWorkspace(.develop); model.canEdit = true; model.recipe = recipe()
        XCTAssertTrue(model.selectDevelopTool(.crop)); XCTAssertEqual(model.developTool, .crop)
        model.selectModule(.develop)
        XCTAssertEqual(model.developTool, .crop, "Clicking the active module leaves its tool open")
        XCTAssertTrue(model.selectDevelopTool(.mask)); XCTAssertFalse(model.cropMode)
        XCTAssertTrue(model.selectDevelopTool(.spot)); XCTAssertFalse(model.maskMode)
        model.selectWorkspace(.grid)
        XCTAssertEqual(model.workspaceMode, .grid); XCTAssertEqual(model.developTool, .adjust)
        model.selectWorkspace(.develop)
        XCTAssertTrue(model.selectDevelopTool(.crop))
        model.dirty = true // No writable catalog: saving must fail without leaving the draft/tool.
        XCTAssertFalse(model.selectDevelopTool(.adjust))
        model.selectModule(.library)
        XCTAssertEqual(model.workspaceMode, .develop); XCTAssertTrue(model.cropMode); XCTAssertTrue(model.dirty)
        model.dirty = false; model.busy = true
        XCTAssertFalse(model.selectDevelopTool(.mask)); XCTAssertEqual(model.developTool, .crop)
    }

    @MainActor func testToolKeysRespectEditingAndCompleteWithoutChangingModule() throws {
        let model = AppModel(); model.selectWorkspace(.develop); model.canEdit = true; model.recipe = recipe()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        func key(_ text: String, code: UInt16 = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        XCTAssertNil(WorkspaceKeyboard.handle(try key("r"), model: model)); XCTAssertTrue(model.cropMode)
        model.canEdit = false
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\u{1b}", code: 53), model: model))
        XCTAssertEqual(model.workspaceMode, .develop); XCTAssertEqual(model.developTool, .adjust)
        model.canEdit = true
        XCTAssertNil(WorkspaceKeyboard.handle(try key("q"), model: model)); XCTAssertTrue(model.spotMode)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("q"), model: model)); XCTAssertFalse(model.spotMode)
        model.selectDevelopTool(.mask); model.maskChoosingTool = true
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\u{1b}", code: 53), model: model))
        XCTAssertTrue(model.maskMode); XCTAssertFalse(model.maskChoosingTool)
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = editor; window.makeFirstResponder(editor)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("r"), model: model)); XCTAssertTrue(model.maskMode)
        withExtendedLifetime(window) {}
    }

    @MainActor func testEmptyFilterRecoveryRetainsSourceAndRestoresResults() throws {
        let f = ImportTests(); try f.setUpWithError()
        defer { try? f.tearDownWithError() }
        let url = f.source.appendingPathComponent("synthetic.jpg"); try f.image(url)
        let root = try f.catalog.addRoot(url: f.source, bookmark: AccessLease.bookmark(f.source, readOnly: true))
        try f.catalog.index(ReferenceImporter.inspect(url: url, root: root, rootURL: f.source))
        let model = AppModel(); model.catalog = f.catalog; try model.reload()
        defer { model.choose([], active: nil); model.catalog = nil }
        model.setScope(root.id); model.search = "does-not-exist"; model.ratingThreshold = 5; model.filterChanged()
        XCTAssertTrue(model.hasLibraryFilters); XCTAssertEqual(model.resultCount, 0)
        model.clearFilters(); model.filterChanged()
        XCTAssertFalse(model.hasLibraryFilters); XCTAssertEqual(model.scope, root.id)
        XCTAssertEqual(model.resultCount, 1); XCTAssertNotNil(model.activeID)
    }

    @MainActor func testCommandsDoNotStackSheetsOrChangeWorkspaceWhileBusy() throws {
        let fixture = ImportTests(); try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let model = AppModel(); model.catalog = fixture.catalog; model.selection = ["selected"]
        XCTAssertTrue(model.canImportPhotos); XCTAssertTrue(model.canExportPhotos)
        let presentations: [ReferenceWritableKeyPath<AppModel, Bool>] = [
            \.showExport, \.showImport, \.showNewCatalog, \.showOutputRecovery,
            \.showCopyRecovery, \.catalogUtilityOpen, \.showAutoStacks, \.showPairing
        ]
        for key in presentations {
            model[keyPath: key] = true
            XCTAssertTrue(model.presentingSheet)
            XCTAssertFalse(model.canSwitchCatalog)
            XCTAssertFalse(model.canImportPhotos); XCTAssertFalse(model.canExportPhotos)
            model.requestExport(preset: ExportPreset.builtIns[1])
            XCTAssertNil(model.requestedExportPreset, "Blocked commands must not replace the active form's draft")
            model.selectWorkspace(.develop)
            XCTAssertEqual(model.workspaceMode, .grid)
            model[keyPath: key] = false
        }
        model.busy = true
        model.importReference(); model.requestExport(); model.selectWorkspace(.develop)
        XCTAssertFalse(model.showImport); XCTAssertFalse(model.showExport)
        XCTAssertEqual(model.workspaceMode, .grid)
        model.busy = false; model.applyingAdjustments = true
        XCTAssertFalse(model.canSwitchCatalog); XCTAssertFalse(model.canExportPhotos)
        model.applyingAdjustments = false
        model.requestExport(preset: ExportPreset.builtIns[1])
        XCTAssertEqual(model.requestedExportPreset?.id, "tiff")
        XCTAssertTrue(model.showExport)
        model.showExport = false
        model.requestExport()
        XCTAssertNil(model.requestedExportPreset, "The normal entry opens last options, not a stale menu preset")
        model.catalog = nil
    }

    @MainActor func testKeyboardAndUndoStayWithinTheActiveWindow() throws {
        let model = AppModel()
        let main = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        main.title = "Synthetic — Phosdeck"
        let settings = NSWindow(contentRect: main.frame, styleMask: [.titled], backing: .buffered, defer: false)
        settings.title = "Phosdeck设置"
        func key(_ window: NSWindow, _ text: String, shift: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: 2))
        }
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key(settings, "d"), model: model))
        XCTAssertEqual(model.workspaceMode, .grid)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key(main, "D", shift: true), model: model))
        model.busy = true
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key(main, "d"), model: model))
        XCTAssertFalse(WorkspaceKeyboard.cull(try key(main, "p"), model: model))
        model.busy = false
        XCTAssertNil(WorkspaceKeyboard.handle(try key(main, "d"), model: model))
        XCTAssertEqual(model.workspaceMode, .develop)
        XCTAssertTrue(CommandResponder.manager(model: model, window: main) === model.undo)
        model.showExport = true
        XCTAssertNil(CommandResponder.manager(model: model, window: main), "Sheet commands must not undo photo edits behind the form")
        let editor = NSTextView(frame: main.contentView!.bounds); editor.allowsUndo = true
        main.contentView = editor; main.makeFirstResponder(editor)
        XCTAssertTrue(CommandResponder.manager(model: model, window: main) === editor.undoManager, "Typing undo remains available in a form")
        XCTAssertFalse(CommandResponder.manager(model: model, window: main) === model.undo)
        XCTAssertNil(CommandResponder.manager(model: model, window: settings))
        main.contentView = nil
    }

    @MainActor func testCacheQuotaPersistsWithoutCatalogAndRejectsChangesDuringTasks() async throws {
        let suite = "cache-preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(cachePreferences: defaults)
        XCTAssertNil(model.catalog)
        try await model.updateCacheQuota(10)
        XCTAssertEqual(AppModel(cachePreferences: defaults).cacheGigabytes, 10)
        model.busy = true
        do { try await model.updateCacheQuota(1); XCTFail("Running jobs disable cache changes") } catch {}
        XCTAssertEqual(defaults.integer(forKey: "cacheGB"), 10)
        model.busy = false
        do { try await model.updateCacheQuota(3); XCTFail("Only the documented quota stops are valid") } catch {}
        XCTAssertEqual(model.cacheGigabytes, 10)
        XCTAssertFalse(model.cacheMaintenance)
        do { try await model.clearThumbnailCache(); XCTFail("No catalog must not look like a successful clear") } catch {}
        defaults.set(3, forKey: "cacheGB")
        XCTAssertEqual(AppModel(cachePreferences: defaults).cacheGigabytes, 5)
    }

    @MainActor func testCacheMaintenancePreservesCatalogAndSource() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let source = fixture.source.appendingPathComponent("cache.jpg"); try fixture.image(source)
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
        try fixture.catalog.index(photo)
        let digest = try SafeFileWriter.sha256(source)
        let model = AppModel(); model.catalog = fixture.catalog
        try await model.updateCacheQuota(1)
        _ = try await model.thumbnails.image(photo: photo, root: root)
        let before = try await model.thumbnails.usage()
        XCTAssertGreaterThan(before, 0)
        try await model.clearThumbnailCache()
        XCTAssertEqual(model.cacheBytes, 0)
        XCTAssertEqual(try fixture.catalog.photoCount(), 1)
        XCTAssertEqual(try SafeFileWriter.sha256(source), digest)
        XCTAssertFalse(model.cacheMaintenance)
        model.catalog = nil
    }

    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "fixture",
                   baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func bitmap(_ color: CIColor = .red, width: Int = 80, height: Int = 40) throws -> CGImage {
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(CIContext().createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
    }
    private func pixels(_ image: CGImage) -> Data {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        CIContext().render(CIImage(cgImage: image), toBitmap: &data, rowBytes: image.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        return Data(data)
    }
    private actor RenderCounter {
        var count = 0
        func increment() { count += 1 }
    }
    @MainActor func testEditedThumbnailsCoalescePersistAndKeepVisibleImage() async throws {
        let counter = RenderCounter()
        let original = try bitmap(), edited = try bitmap(.blue, width: 40, height: 40)
        let service = ThumbnailService { request, _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(70))
            return request.recipe?.exposure == 0 ? original : edited
        }
        let catalogID = UUID().uuidString
        try await service.configure(catalogID: catalogID, gigabytes: 1)
        let root = StorageRoot(id: "r", path: "/unavailable", bookmark: Data(), label: "synthetic")
        var photo = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        photo.recipe = try JSONEncoder().encode(recipe()); photo.recipeRevision = 1
        let initialPhoto = photo
        async let first = service.image(photo: initialPhoto, root: root)
        async let second = service.image(photo: initialPhoto, root: root)
        let images = try await (first, second)
        XCTAssertEqual(images.0.width, 80); XCTAssertEqual(images.1.width, 80)
        let calls = await counter.count; XCTAssertEqual(calls, 1, "Grid and filmstrip share one render")
        let item = PhotoItem(); _ = item.view
        item.configure(photo: photo, root: root, service: service, film: false)
        try await waitUntil { item.displayedImage != nil }
        let shown = item.displayedImage
        let initialKey = ThumbnailService.key(photo: photo, edge: 320)
        photo.rating = 5; photo.flag = 1
        XCTAssertEqual(initialKey, ThumbnailService.key(photo: photo, edge: 320))
        var adjustment = recipe(); adjustment.exposure = 1; adjustment.crop.width = 0.5
        photo.recipe = try JSONEncoder().encode(adjustment); photo.recipeRevision += 1
        XCTAssertNotEqual(initialKey, ThumbnailService.key(photo: photo, edge: 320))
        item.configure(photo: photo, root: root, service: service, film: false)
        XCTAssertTrue(item.displayedImage === shown, "Keep the old edit until its replacement is ready")
        try await waitUntil { item.displayedImage !== shown }
        XCTAssertEqual(item.displayedImage?.size.width, 40)
        let restarted = ThumbnailService { _, _ in throw LRCError("Offline: rendering must not be needed") }
        try await restarted.configure(catalogID: catalogID, gigabytes: 1)
        let offline = try await restarted.image(photo: photo, root: root)
        XCTAssertEqual(offline.width, 40)
        let bytes = pixels(offline)
        XCTAssertGreaterThan(bytes[2], bytes[0], "Cached pixels contain the edited blue result")
        item.prepareForReuse()
        try await restarted.clear(); try await service.clear()
    }

    func testBatchWritesAreAtomicAndUndoRestoresUntouchedPhotos() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder.appendingPathComponent("source"), bookmark: Data())
        for id in ["a", "b"] {
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".ARW", identity: Data(), identityKey: id, width: 80, height: 40))
        }
        let original = try catalog.photos()
        var a = recipe(); a.exposure = 1
        var invalid = a; invalid.exposure = .nan
        XCTAssertThrowsError(try catalog.saveRecipes([(original[0], a), (original[1], invalid)], title: "batch"))
        XCTAssertTrue(try catalog.photos().allSatisfy { $0.recipe == nil && $0.digest == nil })
        let saved = try catalog.saveRecipes(original.map { ($0, a) }, title: "batch", expecting: original, expectingRoots: [root])
        XCTAssertEqual(saved, try catalog.photos())
        XCTAssertThrowsError(try catalog.saveRecipes([], title: "stale reviewed plan", expecting: original)) { error in
            XCTAssertEqual((error as? RecipeBatchConflict)?.photoID, original[0].id)
        }
        var oldRoot = root
        oldRoot.bookmark = Data([1])
        XCTAssertThrowsError(try catalog.saveRecipes([], title: "stale root", expecting: saved, expectingRoots: [oldRoot]))
        let redo = try catalog.restoreRecipes(original, title: "undo")
        XCTAssertTrue(try catalog.photos().allSatisfy { $0.recipe == nil && $0.digest == nil })
        _ = try catalog.restoreRecipes(redo, title: "redo")
        XCTAssertTrue(try catalog.photos().allSatisfy { $0.recipe != nil })
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, 3)
        XCTAssertThrowsError(try catalog.saveRecipes([(original[0], a)], title: "stale revision"))
    }

    func testTotalExposureMetadataCalculationBaselineAndLimits() throws {
        let capture = PhotoMetadata(iso: 100, aperture: 4, exposureTime: 1.0 / 125)
        var source = recipe(); source.exposure = 0.75; source.baselineExposure = 0.3
        let match = try TotalExposureMatch(metadata: capture, recipe: source)
        var target = source; target.baselineExposure = -0.2; target.exposure = -3
        XCTAssertEqual(try match.exposure(metadata: capture, recipe: target).value, 1.25, accuracy: 1e-10)
        for metadata in [PhotoMetadata(iso: 100, aperture: 4, exposureTime: 1.0 / 250),
                         PhotoMetadata(iso: 50, aperture: 4, exposureTime: 1.0 / 125)] {
            XCTAssertEqual(try match.exposure(metadata: metadata, recipe: target).value, 2.25, accuracy: 1e-10)
        }
        XCTAssertEqual(try match.exposure(metadata: PhotoMetadata(iso: 100, aperture: 8, exposureTime: 1.0 / 125), recipe: target).value, 3.25, accuracy: 1e-10)
        for (time, expected) in [(1e-100, 5.0), (1e100, -5.0)] {
            let value = try match.exposure(metadata: PhotoMetadata(iso: 100, aperture: 4, exposureTime: time), recipe: target)
            XCTAssertEqual(value.value, expected); XCTAssertTrue(value.limited)
        }
        for invalid in [nil, PhotoMetadata(), PhotoMetadata(iso: 0, aperture: 4, exposureTime: 1),
                        PhotoMetadata(iso: -100, aperture: 4, exposureTime: 1),
                        PhotoMetadata(iso: 100, aperture: 0, exposureTime: 1),
                        PhotoMetadata(iso: 100, aperture: .nan, exposureTime: 1),
                        PhotoMetadata(iso: 100, aperture: 4, exposureTime: -.infinity),
                        PhotoMetadata(iso: 100, aperture: 4, exposureTime: 0)] {
            XCTAssertThrowsError(try TotalExposureMatch(metadata: invalid, recipe: source))
            XCTAssertThrowsError(try match.exposure(metadata: invalid, recipe: target))
        }
        XCTAssertTrue(try TotalExposureMatch.captureStops(PhotoMetadata(iso: Int.max, aperture: .leastNonzeroMagnitude, exposureTime: .greatestFiniteMagnitude)).isFinite)
    }

    func testPublicRAWBaselineCompensationMatchesNativeForwardPixels() async throws {
        // Same-source controlled baseline experiment. This verifies the native
        // EV composition used by matching, not physical brackets or cameras.
        let pipeline = ImagePipeline()
        for name in ["a7iii_12bit_compressed.ARW", "leica_m8_8bit_uncompressed.DNG"] {
            let source = try MoreRAWTests.request(name)
            var reference = try await pipeline.baseline(source)
            let digest = reference.sourceDigest
            reference.exposure = 0.75
            let metadata: PhotoMetadata
            if name == "leica_m8_8bit_uncompressed.DNG" {
                // This public fixture has no usable aperture. Production matching
                // must reject it; equal synthetic capture terms below isolate EV
                // composition without claiming its missing metadata was recovered.
                XCTAssertThrowsError(try TotalExposureMatch(metadata: source.photo.details, recipe: reference))
                metadata = PhotoMetadata(iso: 100, aperture: 4, exposureTime: 1.0 / 125)
                print("RAW_BASELINE_MATCH file=\(name) capture=controlled-equal-terms actual-metadata=rejected")
            } else {
                metadata = try XCTUnwrap(source.photo.details)
            }
            let match = try TotalExposureMatch(metadata: metadata, recipe: reference)
            let expected = try await pipeline.linearRank(ImageRequest(photo: source.photo, root: source.root, recipe: reference), longEdge: 768)
            for offset in [-0.5, 0.5] {
                var target = reference
                target.baselineExposure += offset; target.exposure = -2
                let result = try match.exposure(metadata: metadata, recipe: target)
                XCTAssertFalse(result.limited)
                XCTAssertEqual(result.value, 0.75 - offset, accuracy: 1e-10)
                target.exposure = result.value
                let actual = try await pipeline.linearRank(ImageRequest(photo: source.photo, root: source.root, recipe: target), longEdge: 768)
                XCTAssertEqual(actual.width, expected.width); XCTAssertEqual(actual.height, expected.height)
                XCTAssertEqual(actual.alpha, expected.alpha)
                var differences = [Double]()
                for (a, b) in zip(expected.pixels, actual.pixels) {
                    let y = Double(a.x) * 0.2126 + Double(a.y) * 0.7152 + Double(a.z) * 0.0722
                    let z = Double(b.x) * 0.2126 + Double(b.y) * 0.7152 + Double(b.z) * 0.0722
                    if y > 0.01, y < 0.9, z > 0.01, z < 0.9 { differences.append(abs(log2(y / z))) }
                }
                differences.sort()
                XCTAssertGreaterThan(differences.count, 1000)
                let p99 = differences.isEmpty ? Double.infinity : differences[Int(Double(differences.count - 1) * 0.99)]
                XCTAssertLessThan(p99, 0.0001, "Equal total native EV should agree within float/half readback precision")
                print("RAW_BASELINE_MATCH file=\(name) offset=\(offset) exposure=\(result.value) pixels=\(differences.count) p99_abs_ev=\(p99)")
            }
            XCTAssertEqual(try SafeFileWriter.sha256(MoreRAWTests.sample(name)), digest)
        }
    }

    @MainActor func testMatchTotalExposuresBatchSkipClampUndoRedoAndAtomicFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        var originals = [String: EditRecipe]()
        for id in ["a", "b", "c", "missing", "unselected"] {
            var value = recipe(); value.exposure = id == "a" ? 0.5 : -1
            value.baselineExposure = id == "a" ? 0.2 : -0.3
            value.contrast = 1.2; value.develop.shadows = 15
            var photo = Photo(id: id, rootID: root.id, relativePath: id + ".ARW", identity: Data(), identityKey: id, width: 80, height: 40)
            photo.recipe = try JSONEncoder().encode(value); photo.recipeRevision = 1
            if id != "missing" {
                photo.metadata = try JSONEncoder().encode(PhotoMetadata(iso: 100, aperture: 4, exposureTime: id == "a" ? 1.0 / 125 : id == "c" ? 1e-10 : 1.0 / 250))
            }
            try catalog.index(photo); originals[id] = value
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; try model.reload(); model.activeID = "a"
        model.activePhoto = try catalog.photo("a"); model.recipe = originals["a"]; model.canEdit = true
        model.undo.groupsByEvent = false
        let selected: Set<String> = ["a", "b", "c", "missing"]
        func stored(_ id: String) throws -> EditRecipe {
            try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(id)?.recipe))
        }
        XCTAssertTrue(model.matchTotalExposures(ids: selected)); await model.task?.value
        XCTAssertEqual(try stored("b").exposure, 2, accuracy: 1e-10)
        var expected = try XCTUnwrap(originals["b"]); expected.exposure = try stored("b").exposure
        XCTAssertEqual(try stored("b"), expected)
        var limited = try XCTUnwrap(originals["c"]); limited.exposure = 5
        XCTAssertEqual(try stored("c"), limited)
        XCTAssertEqual(model.reports.count, 4, "Successes plus missing metadata and limiting reports")
        for id in ["a", "missing", "unselected"] {
            XCTAssertEqual(try catalog.photo(id)?.recipeRevision, 1)
            XCTAssertEqual(try stored(id), originals[id])
        }
        XCTAssertEqual(try catalog.editHistory(photoID: "b").count, 1)
        model.undo.undo()
        XCTAssertEqual(try stored("b"), originals["b"]); XCTAssertEqual(try stored("c"), originals["c"])
        XCTAssertFalse(model.undo.canUndo, "One undo restores the entire successful subset")
        model.undo.redo(); XCTAssertEqual(try stored("b"), expected); XCTAssertEqual(try stored("c"), limited)
        model.undo.undo()
        try await catalog.database.write { try $0.execute(sql: "CREATE TRIGGER fail_match BEFORE UPDATE OF recipe ON photo WHEN NEW.id='c' BEGIN SELECT RAISE(ABORT,'injected failure'); END") }
        XCTAssertTrue(model.matchTotalExposures(ids: selected)); await model.task?.value
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try stored("b"), originals["b"], "Storage failure rolls back all targets")
        XCTAssertEqual(try stored("c"), originals["c"])
        model.error = nil; model.activeID = "missing"; model.recipe = originals["missing"]
        XCTAssertFalse(model.matchTotalExposures(ids: selected)); XCTAssertNotNil(model.error)
        XCTAssertEqual(try stored("b"), originals["b"])
    }

    @MainActor func testRelativeExposureBatchAccumulatesPerPhotoBoundsSelectionAndUndoRedo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder.appendingPathComponent("source"), bookmark: Data())
        let initialValues: [(String, Double)] = [("a", -1), ("b", 0.25), ("c", 4.8), ("d", -4.8)]
        var originals = [String: EditRecipe]()
        for (id, exposure) in initialValues {
            var value = recipe()
            value.exposure = exposure
            value.baselineExposure = id == "b" ? 0.3 : id == "c" ? -0.2 : 0
            value.baselineTemperature = id == "b" ? 4800 : 5500
            value.baselineTint = id == "b" ? 4 : 0
            value.temperature = value.baselineTemperature
            value.tint = value.baselineTint
            value.contrast = 1.2
            value.saturation = 0.8
            originals[id] = value
            var photo = Photo(id: id, rootID: root.id, relativePath: id + ".ARW", identity: Data(), identityKey: id, width: 80, height: 40)
            photo.recipe = try JSONEncoder().encode(value)
            photo.recipeRevision = 1
            try catalog.index(photo)
        }

        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog
        try model.reload()
        model.canEdit = true
        model.undo.groupsByEvent = false
        let selected: Set<String> = ["a", "b", "c"]
        model.selection = selected
        let thirdEV = 1.0 / 3.0

        XCTAssertTrue(model.applyRelativeExposure(delta: thirdEV, ids: selected))
        await model.task?.value
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.error)

        func storedRecipe(_ id: String) throws -> EditRecipe {
            try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(id)?.recipe))
        }
        var afterFirst = originals
        afterFirst["a"]?.exposure = -1 + thirdEV
        afterFirst["b"]?.exposure = 0.25 + thirdEV
        afterFirst["c"]?.exposure = 5
        for id in ["a", "b", "c", "d"] {
            let expected = id == "d" ? try XCTUnwrap(originals[id]) : try XCTUnwrap(afterFirst[id])
            XCTAssertEqual(try storedRecipe(id), expected, "First relative exposure pass preserves per-photo settings")
        }
        XCTAssertEqual(try catalog.photo("d")?.recipeRevision, 1, "An unselected photo is not rewritten")

        XCTAssertTrue(model.applyRelativeExposure(delta: thirdEV, ids: selected))
        await model.task?.value
        var afterSecond = afterFirst
        afterSecond["a"]?.exposure = (afterFirst["a"]?.exposure ?? 0) + thirdEV
        afterSecond["b"]?.exposure = (afterFirst["b"]?.exposure ?? 0) + thirdEV
        afterSecond["c"]?.exposure = 5
        for id in ["a", "b", "c", "d"] {
            let expected = id == "d" ? try XCTUnwrap(originals[id]) : try XCTUnwrap(afterSecond[id])
            XCTAssertEqual(try storedRecipe(id), expected, "A second relative pass accumulates on each target")
        }

        model.undo.undo()
        XCTAssertEqual(try storedRecipe("a"), try XCTUnwrap(afterFirst["a"]))
        XCTAssertEqual(try storedRecipe("b"), try XCTUnwrap(afterFirst["b"]))
        XCTAssertEqual(try storedRecipe("c"), try XCTUnwrap(afterFirst["c"]))
        XCTAssertEqual(try storedRecipe("d"), try XCTUnwrap(originals["d"]))
        XCTAssertTrue(model.undo.canUndo, "One undo restores one whole relative batch and leaves the first batch undoable")
        model.undo.redo()
        XCTAssertEqual(try storedRecipe("a"), try XCTUnwrap(afterSecond["a"]))
        XCTAssertEqual(try storedRecipe("b"), try XCTUnwrap(afterSecond["b"]))
        XCTAssertEqual(try storedRecipe("c"), try XCTUnwrap(afterSecond["c"]))
        XCTAssertEqual(try storedRecipe("d"), try XCTUnwrap(originals["d"]))

        var beforeInvalid = [String: (Int, Data?, Int)]()
        for photo in try catalog.photos() {
            beforeInvalid[photo.id] = (photo.recipeRevision, photo.recipe, try catalog.editHistory(photoID: photo.id).count)
        }
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 5.001, -5.001, 0] {
            XCTAssertFalse(model.applyRelativeExposure(delta: invalid, ids: selected), "Invalid relative delta must be rejected")
        }
        for photo in try catalog.photos() {
            let before = try XCTUnwrap(beforeInvalid[photo.id])
            XCTAssertEqual(photo.recipeRevision, before.0)
            XCTAssertEqual(photo.recipe, before.1)
            XCTAssertEqual(try catalog.editHistory(photoID: photo.id).count, before.2)
        }

        XCTAssertTrue(model.applyRelativeExposure(delta: -1, ids: ["d"]))
        await model.task?.value
        var expectedLowerBound = try XCTUnwrap(originals["d"])
        expectedLowerBound.exposure = -5
        XCTAssertEqual(try storedRecipe("d"), expectedLowerBound, "A negative relative pass clamps the lower bound to -5 EV")
        for id in ["a", "b", "c"] {
            XCTAssertEqual(try storedRecipe(id), try XCTUnwrap(afterSecond[id]), "A single-photo relative pass leaves the other photos unchanged")
        }
    }

    @MainActor func testRelativeExposureSheetNativeSliderApplyPrecisionAndValidation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder.appendingPathComponent("source"), bookmark: Data())
        let initial = recipe()
        var photo = Photo(id: "a", rootID: root.id, relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        photo.recipe = try JSONEncoder().encode(initial)
        photo.recipeRevision = 1
        try catalog.index(photo)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog
        try model.reload()
        model.canEdit = true
        model.undo.groupsByEvent = false

        final class Presentation { var isPresented = true }
        func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
        }
        func hostSheet(_ presentation: Presentation) -> (NSHostingView<RelativeExposureSheet>, NSWindow) {
            let host = NSHostingView(rootView: RelativeExposureSheet(model: model, targets: ["a"],
                presented: Binding(get: { presentation.isPresented }, set: { presentation.isPresented = $0 })))
            host.frame = CGRect(x: 0, y: 0, width: 520, height: 320)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            host.layoutSubtreeIfNeeded()
            return (host, window)
        }
        func editableField(_ host: NSView) -> NSTextField? {
            descendants(host, NSTextField.self).first { $0.isEditable }
        }
        func pump() {
            let deadline = Date().addingTimeInterval(0.08)
            while Date() < deadline { RunLoop.current.run(mode: .default, before: deadline) }
        }
        func closeSheet(_ sheet: (NSHostingView<RelativeExposureSheet>, NSWindow)) {
            sheet.1.makeFirstResponder(nil)
            sheet.1.orderOut(nil)
            sheet.1.contentView = nil
        }
        func pressApply(_ sheet: (NSHostingView<RelativeExposureSheet>, NSWindow)) throws -> Bool {
            // Hosted SwiftUI AX children can be empty. Exercise its registered
            // default action through AppKit and assert the actual saved recipe.
            sheet.1.makeFirstResponder(sheet.0)
            pump()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.1.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            return sheet.0.performKeyEquivalent(with: event)
        }

        do {
            let presentation = Presentation()
            let first = hostSheet(presentation); defer { closeSheet(first) }
            try await waitUntil { editableField(first.0) != nil }
            let field = try XCTUnwrap(editableField(first.0))
            first.1.makeFirstResponder(field); field.selectText(nil)
            let slider = try XCTUnwrap(descendants(first.0, AdjustmentNSSlider.self).first { $0.accessibilityLabel() == L10n.text("app.exposureChange", defaultValue: "Exposure Change") })
            XCTAssertTrue(slider.accessibilityPerformIncrement())
            XCTAssertEqual(slider.doubleValue, 1.0 / 3.0, accuracy: 1e-12)
            pump()
            XCTAssertTrue(try pressApply(first), "The valid sheet must handle its native default-action shortcut")
            XCTAssertFalse(presentation.isPresented)
            await model.task?.value
        }
        let afterSlider = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo("a")?.recipe))
        XCTAssertEqual(afterSlider.exposure, 1.0 / 3.0, accuracy: 1e-12, "Native slider + Apply must preserve one-third EV precision")

        do {
            let presentation = Presentation(), invalidSheet = hostSheet(presentation)
            defer { closeSheet(invalidSheet) }
            try await waitUntil { editableField(invalidSheet.0) != nil }
            let field = try XCTUnwrap(editableField(invalidSheet.0))
            invalidSheet.1.makeFirstResponder(field); field.selectText(nil)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText("NaN", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            pump(); editor.insertNewline(nil); pump()
            _ = try pressApply(invalidSheet)
            pump()
            XCTAssertTrue(presentation.isPresented, "Invalid input must not dismiss the sheet")
            XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo("a")?.recipe)).exposure, afterSlider.exposure, accuracy: 1e-12, "Invalid input must not write, including through the default-action shortcut")
        }
        do {
            let presentation = Presentation(), validSheet = hostSheet(presentation)
            defer { closeSheet(validSheet) }
            try await waitUntil { editableField(validSheet.0) != nil }
            let field = try XCTUnwrap(editableField(validSheet.0))
            validSheet.1.makeFirstResponder(field); field.selectText(nil)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText("0.5", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            pump(); editor.insertNewline(nil); pump()
            XCTAssertTrue(try pressApply(validSheet))
            XCTAssertFalse(presentation.isPresented)
            await model.task?.value
        }
        let afterText = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo("a")?.recipe))
        XCTAssertEqual(afterText.exposure, afterSlider.exposure + 0.5, accuracy: 1e-12, "A valid entered EV applies through the native sheet")
    }

    func testPresetSelectionBackupAndDetailValidation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        var source = recipe(); source.schemaVersion = 3; source.exposure = 2; source.crop.width = 0.5
        source.rawDetails = RAWDetailSettings(luminanceNoiseReduction: 0.7, colorNoiseReduction: 0.4, sharpness: 0.6, lensCorrection: true)
        source.develop.curves = ToneCurves(); source.develop.curves?.channels[0][2].y = 0.6
        source.develop.zones = ToneZones(gains: [0, 0.2, 0.4, 0.1, 0])
        source.localAdjustments = [LocalAdjustment(components: [MaskComponent(tool: .linear)])]
        let options = RecipePasteOptions(tone: true, whiteBalance: false, color: false, geometry: false, details: true)
        try catalog.savePreset(name: "  夜景  ", recipe: source, options: options)
        let preset = try XCTUnwrap(catalog.presets().first)
        let saved = try JSONDecoder().decode(EditRecipe.self, from: preset.recipe)
        XCTAssertEqual(saved.exposure, 2); XCTAssertEqual(saved.rawDetails, source.rawDetails)
        XCTAssertEqual(saved.crop, Crop()); XCTAssertTrue(saved.localAdjustments.isEmpty)
        var target = recipe(); target.sourceDigest = String(repeating: "b", count: 64); target.baselineTemperature = 4300
        target.localAdjustments = source.localAdjustments; target.schemaVersion = 3
        let applied = try target.pasting(saved, options: JSONDecoder().decode(RecipePasteOptions.self, from: preset.options))
        XCTAssertEqual(applied.sourceDigest, target.sourceDigest); XCTAssertEqual(applied.baselineTemperature, 4300)
        XCTAssertEqual(applied.localAdjustments, target.localAdjustments)
        XCTAssertEqual(applied.rawDetails, source.rawDetails)
        XCTAssertEqual(applied.develop.curves, source.develop.curves)
        XCTAssertEqual(applied.develop.zones, source.develop.zones)
        XCTAssertTrue(applied.baseline().rawDetails.isDefault)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(applied)), applied)
        XCTAssertThrowsError(try source.rawDetails.checkSupport(RAWDetailSettings()))
        source.rawDetails.sharpness = .infinity; XCTAssertThrowsError(try source.validate())
        try catalog.renamePreset(id: preset.id, name: "夜景细节")
        let backup = folder.appendingPathComponent("backup.sqlite"); try catalog.backup(to: backup)
        let restored = try CatalogStore.restore(from: backup, to: folder.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.presets().first?.name, "夜景细节")
        XCTAssertEqual(try restored.presets().first?.recipe, preset.recipe)
        let manifest = folder.appendingPathComponent("manifest.json"); try restored.exportManifest(to: manifest)
        XCTAssertTrue(try String(contentsOf: manifest, encoding: .utf8).contains("夜景细节"))
        try catalog.deletePreset(preset.id); XCTAssertTrue(try catalog.presets().isEmpty)
    }

    /// A public sample copy is optional; the normal suite never searches private libraries.
    @MainActor func testPublicRAWBatchDetailsThumbnailAndExport() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let sample = support.appendingPathComponent("OhMyLRC/FeatureValidation/public.ARW")
        guard FileManager.default.fileExists(atPath: sample.path) else { throw XCTSkip("Public RAW fixture not prepared") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFolder = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url: sourceFolder, bookmark: AccessLease.bookmark(sourceFolder, readOnly: true))
        for name in ["a.ARW", "b.ARW"] {
            let url = sourceFolder.appendingPathComponent(name); try FileManager.default.copyItem(at: sample, to: url)
            try catalog.index(ReferenceImporter.inspect(url: url, root: root, rootURL: sourceFolder))
        }
        let jpeg = sourceFolder.appendingPathComponent("c.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try bitmap(), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        try catalog.index(ReferenceImporter.inspect(url: jpeg, root: root, rootURL: sourceFolder))
        let photos = try catalog.photos().sorted { $0.name < $1.name }
        let pipeline = ImagePipeline(cacheIntermediates: true)
        let initial = ImageRequest(photo: photos[0], root: root, recipe: nil)
        let baseline = try await pipeline.baseline(initial)
        let defaults = try await pipeline.rawDefaults(ImageRequest(photo: photos[0], root: root, recipe: baseline))
        var edited = baseline; edited.exposure = 0.5; edited.crop.width = 0.75
        edited.develop.curves = ToneCurves(); edited.develop.curves?.channels[0][2] = CurvePoint(x:0.43,y:0.62)
        edited.develop.curves?.insert(channel:1,x:0.36,y:0.42)
        edited.develop.blackAndWhite = true; edited.develop.blackWhiteMixer = [35,-20,15,-30,10,25,-15,40]
        edited.develop.zones = ToneZones(gains: [0, 0.4, 0.6, -0.2, 0])
        if defaults.luminanceNoiseReduction != nil { edited.rawDetails.luminanceNoiseReduction = 0.8 }
        if defaults.colorNoiseReduction != nil { edited.rawDetails.colorNoiseReduction = 0.6 }
        if defaults.sharpness != nil { edited.rawDetails.sharpness = 0.9 }
        if let value = defaults.lensCorrection { edited.rawDetails.lensCorrection = !value }
        XCTAssertFalse(edited.rawDetails.isDefault)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: sourceFolder.appendingPathComponent("a.ARW")))
        try edited.rawDetails.apply(to: raw, defaults: defaults)
        if let value = edited.rawDetails.sharpness { XCTAssertEqual(Double(raw.sharpnessAmount), value, accuracy: 0.000001) }
        try RAWDetailSettings().apply(to: raw, defaults: defaults)
        XCTAssertEqual(RAWDetailSettings(raw: raw), defaults)
        let baseRequest = ImageRequest(photo: photos[0], root: root, recipe: baseline)
        let draftBefore = try await pipeline.renderInteractive(baseRequest, longEdge: 512)
        let changedRequest = ImageRequest(photo: photos[0], root: root, recipe: edited)
        let draftChanged = try await pipeline.renderInteractive(changedRequest, longEdge: 512)
        XCTAssertNotEqual(pixels(draftChanged.image), pixels(draftBefore.image))
        let zoneReference = try await pipeline.zoneReference(changedRequest)
        var noTonal = edited; noTonal.develop.curves = nil; noTonal.develop.zones = nil
        let unchangedReference = try await pipeline.zoneReference(ImageRequest(photo: photos[0], root: root, recipe: noTonal))
        func evPixels(_ image: CGImage) -> [Float] {
            var p = [Float](repeating: 0, count: image.width*image.height*4)
            CIContext().render(CIImage(cgImage: image), toBitmap: &p, rowBytes: image.width*16,
                bounds: CGRect(x:0,y:0,width:image.width,height:image.height), format:.RGBAf,
                colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
            return p
        }
        XCTAssertEqual(evPixels(zoneReference), evPixels(unchangedReference), "Curve/zone edits must not feed back into the picker")
        XCTAssertEqual(Double(zoneReference.width)/Double(zoneReference.height), Double(draftChanged.image.width)/Double(draftChanged.image.height), accuracy:0.01)
        var turned = edited; turned.quarterTurns = 1; turned.straightenDegrees = 4
        let turnedRequest = ImageRequest(photo: photos[0], root: root, recipe: turned)
        let turnedReference = try await pipeline.zoneReference(turnedRequest)
        let turnedPreview = try await pipeline.renderInteractive(turnedRequest, longEdge:512)
        XCTAssertEqual(Double(turnedReference.width)/Double(turnedReference.height), Double(turnedPreview.image.width)/Double(turnedPreview.image.height), accuracy:0.01)
        let draftReset = try await pipeline.renderInteractive(baseRequest, longEdge: 512)
        XCTAssertEqual(pixels(draftBefore.image), pixels(draftReset.image), "Reset must restore cached decoder defaults")
        try catalog.saveRecipe(id: photos[0].id, recipe: baseline)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("No active preview in this test") })
        model.catalog = catalog; try model.reload(); model.undo.groupsByEvent = false
        let ids = Set(photos.map(\.id))
        XCTAssertTrue(model.applyAdjustments(source: edited, options: RecipePasteOptions(details: true), ids: ids, title: "同步测试"))
        await model.task?.value
        XCTAssertFalse(model.busy); XCTAssertNil(model.error)
        XCTAssertEqual(model.reports.filter { $0.hasPrefix("成功：") }.count, 3)
        XCTAssertEqual(model.reports.filter { $0.hasPrefix("跳过") }.count, 0)
        let jpegRecipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photos[2].id)?.recipe))
        XCTAssertTrue(jpegRecipe.isRaster)
        XCTAssertEqual(jpegRecipe.exposure, edited.exposure)
        XCTAssertTrue(jpegRecipe.rawDetails.isDefault, "RAW details must not be copied to JPEG")
        XCTAssertEqual(jpegRecipe.baselineExposure, 0)
        XCTAssertEqual(jpegRecipe.baselineTemperature, 5500)
        XCTAssertEqual(jpegRecipe.develop.curves, edited.develop.curves)
        XCTAssertTrue(model.reports.contains { $0.contains("c.jpg") && $0.contains("已略过 RAW 专属") })
        let updated = try XCTUnwrap(catalog.photo(photos[1].id))
        let resultRecipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(updated.recipe))
        XCTAssertEqual(resultRecipe.rawDetails, edited.rawDetails)
        XCTAssertEqual(resultRecipe.develop.curves, edited.develop.curves)
        XCTAssertEqual(resultRecipe.develop.zones, edited.develop.zones)
        XCTAssertEqual(resultRecipe.crop, Crop(), "Default batch paste must preserve geometry")
        let request = ImageRequest(photo: updated, root: root, recipe: resultRecipe)
        let thumbnail = try await ThumbnailService().image(photo: updated, root: root, edge: 320)
        let quality = try await pipeline.render(request, longEdge: 320)
        XCTAssertEqual(pixels(thumbnail), pixels(quality.image), "Thumbnail uses the export graph")
        let output = folder.appendingPathComponent("out.jpg")
        let dimensions = try await pipeline.export(request, staging: output, options: ExportOptions(longEdge: 320, quality: 0.98, jpegMatte: .black))
        try ImagePipeline.verifyExport(output, width: dimensions.0, height: dimensions.1)
        var masked = resultRecipe
        var shape = MaskComponent(tool: .radial); shape.feather = 0.1
        var mask = LocalAdjustment(components: [shape]); mask.exposure = 1
        mask.refinement = MaskRefinement(edgeRadius: 0.4, blurRadius: 0.05, expansion: -0.15, hardness: 0.3)
        masked.localAdjustments = [mask]; masked.schemaVersion = 3
        var maskedPhoto = updated; maskedPhoto.recipe = try JSONEncoder().encode(masked); maskedPhoto.recipeRevision += 1
        let maskedRequest = ImageRequest(photo: maskedPhoto, root: root, recipe: masked)
        let refined = try await pipeline.render(maskedRequest, longEdge: 320)
        let refinedDraft = try await pipeline.renderInteractive(maskedRequest, longEdge: 320)
        let refinedThumbnail = try await ThumbnailService().image(photo: maskedPhoto, root: root, edge: 320)
        XCTAssertNotEqual(pixels(refined.image), pixels(quality.image), "A refined manual mask actually affects the RAW")
        XCTAssertEqual(pixels(refined.image), pixels(refinedThumbnail))
        let refinedOutput = folder.appendingPathComponent("refined.jpg")
        let refinedDimensions = try await pipeline.export(maskedRequest, staging: refinedOutput, options: ExportOptions(longEdge: 320, quality: 0.98, jpegMatte: .black))
        try ImagePipeline.verifyExport(refinedOutput, width: refinedDimensions.0, height: refinedDimensions.1)
        let jpegSource = try XCTUnwrap(CGImageSourceCreateWithURL(refinedOutput as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil))
        func smallPixels(_ cg: CGImage) throws -> [UInt8] {
            let ci = ImagePipeline.resized(CIImage(cgImage: cg), longEdge: 64)
            let raster = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
            return Array(pixels(raster))
        }
        let referencePixels = try smallPixels(refined.image)
        for other in [refinedDraft.image, exported] {
            let actual = try smallPixels(other)
            XCTAssertEqual(actual.count, referencePixels.count)
            let errors = zip(referencePixels, actual).enumerated().filter { $0.offset % 4 != 3 }
                .map { abs(Double($0.element.0) - Double($0.element.1)) / 255 }
            XCTAssertLessThan(errors.reduce(0, +) / Double(errors.count), 0.04, "Draft/export matches quality rendering within RGB MAE 0.04")
        }
        // Keep a reviewable public-sample result, never a private library image.
        let attachment = XCTAttachment(data: try Data(contentsOf: refinedOutput), uniformTypeIdentifier: "public.jpeg")
        attachment.name = "public-raw-refined-mask"; attachment.lifetime = .keepAlways; add(attachment)
        for format in [ExportFormat.png, .tiff] {
            let file = folder.appendingPathComponent("refined." + format.fileExtension)
            let dimensions = try await pipeline.export(maskedRequest, staging: file, options: ExportOptions(format: format, longEdge: 320))
            try ImagePipeline.verifyExport(file, width: dimensions.0, height: dimensions.1, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let expected = pixels(refined.image), actual = pixels(output)
            XCTAssertEqual(expected.count, actual.count)
            XCTAssertLessThanOrEqual(zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1,
                "RAW curves, zones and refined masks survive lossless \(format.title) export")
        }
        let unedited = ExportSnapshot(id: "unedited-tiff", request: ImageRequest(photo: updated, root: root, recipe: nil),
            destination: folder.appendingPathComponent("unedited.tif"), targetBookmark: try AccessLease.bookmark(folder, readOnly: false),
            options: ExportOptions(format: .tiff, longEdge: 320))
        let exportedReports = await ExportService(pipeline: pipeline).run([unedited], catalog: catalog) { _ in }
        XCTAssertTrue(exportedReports[0].hasPrefix("成功"), exportedReports[0])
        let frozen = try XCTUnwrap(ExportService.logs(catalog: catalog).first { $0.id == unedited.id })
        XCTAssertEqual(frozen.snapshot.options, unedited.options)
        XCTAssertEqual(frozen.snapshot.request.recipe?.exposure, 0, "Unedited RAW freezes its own baseline")
        XCTAssertEqual(try SafeFileWriter.sha256(sourceFolder.appendingPathComponent("a.ARW")), baseline.sourceDigest)
        model.undo.undo()
        XCTAssertNil(try catalog.photo(photos[1].id)?.recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photos[0].id)?.recipe)), baseline)
        model.undo.redo()
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photos[1].id)?.recipe)), resultRecipe)
        model.undo.undo(); model.undo.removeAllActions()
        XCTAssertTrue(model.applyAdjustments(source: edited, options: RecipePasteOptions(), ids: ids, title: "取消测试"))
        model.task?.cancel(); await model.task?.value
        XCTAssertNil(try catalog.photo(photos[1].id)?.recipe); XCTAssertFalse(model.undo.canUndo)
    }

    @MainActor func testDetailPanelShowsSupportedControlsAndEditsRecipe() async throws {
        let suite = "detail-layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        for key in ["developBasicOpen", "developMixerOpen", "developGradingOpen"] { preferences.set(false, forKey: key) }
        preferences.set(true, forKey: "developDetailsOpen")
        let model = AppModel(); model.recipe = recipe(); model.canEdit = true
        model.rawDefaults = RAWDetailSettings(luminanceNoiseReduction: 0.25, colorNoiseReduction: 0.5, sharpness: 0.75, lensCorrection: true)
        let host = NSHostingView(rootView: DevelopPanel(model: model).defaultAppStorage(preferences)
            .font(.system(size: 12)).buttonStyle(.borderless).controlSize(.small)
            .background(Theme.panel).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func sliders(_ view: NSView) -> [AdjustmentNSSlider] {
            if let slider = view as? AdjustmentNSSlider { return [slider] }
            return view.subviews.flatMap(sliders)
        }
        try await waitUntil { sliders(host).count == 3 }
        host.layoutSubtreeIfNeeded()
        let sharpness = try XCTUnwrap(sliders(host).first { $0.accessibilityLabel() == "锐化" })
        XCTAssertEqual(sharpness.doubleValue, 75)
        XCTAssertGreaterThan(sharpness.visibleRect.width, 40)
        sharpness.doubleValue = 42
        sharpness.sendAction(sharpness.action, to: sharpness.target)
        XCTAssertEqual(model.recipe?.rawDetails.sharpness, 0.42)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "detail-panel"; attachment.lifetime = .keepAlways; add(attachment)
        model.rawDefaults?.sharpness = nil
        try await waitUntil { sliders(host).count == 2 }
    }

    @MainActor func testFlagAndRatingSelectionSummaryToggleAndUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        try catalog.database.write { db in
            for (id, rating, flag) in [("0", 3, 1), ("1", 3, 0), ("2", 4, -1)] {
                try Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: "summary-" + id,
                          rating: rating, flag: flag, width: 1, height: 1).insert(db)
            }
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; try model.reload()
        model.choose(["0", "1"], active: "0")
        XCTAssertNil(model.selectedFlag, "Mixed flags are represented as an indeterminate state")
        XCTAssertEqual(model.selectedRating, 3)

        model.undo.beginUndoGrouping(); model.toggleFlag(1, advance: false); model.undo.endUndoGrouping()
        XCTAssertEqual(try catalog.photo("0")?.flag, 1)
        XCTAssertEqual(try catalog.photo("1")?.flag, 1)
        XCTAssertEqual(model.selectedFlag, 1)
        model.undo.removeAllActions()
        model.undo.beginUndoGrouping(); model.toggleFlag(1, advance: false); model.undo.endUndoGrouping()
        XCTAssertTrue(try catalog.photos(ids: ["0", "1"]).allSatisfy { $0.flag == 0 }, "Clicking the active flag again clears it")
        model.undo.undo()
        XCTAssertTrue(try catalog.photos(ids: ["0", "1"]).allSatisfy { $0.flag == 1 }, "Flag changes remain one batch undo")

        model.undo.removeAllActions()
        model.undo.beginUndoGrouping(); model.toggleRating(3); model.undo.endUndoGrouping()
        XCTAssertTrue(try catalog.photos(ids: ["0", "1"]).allSatisfy { $0.rating == 0 }, "Clicking the active rating again clears it")
        model.undo.undo()
        XCTAssertTrue(try catalog.photos(ids: ["0", "1"]).allSatisfy { $0.rating == 3 })
        model.choose(["0", "2"], active: "0")
        XCTAssertNil(model.selectedRating, "Mixed ratings are represented as an indeterminate state")
        XCTAssertNil(model.selectedFlag, "Mixed flags remain indeterminate after changing selection")
    }

    @MainActor func testFlagShortcutsAutoAdvanceRepeatAndFilteredRemoval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        try catalog.database.write { db in
            for index in 0..<205 {
                let id = String(format: "%04d", index)
                try Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: "shortcut-" + id,
                          width: 1, height: 1).insert(db)
            }
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; try model.reload(); model.singleView = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        defer { window.contentView = nil }
        func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: repeated, keyCode: code))
        }
        func send(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws {
            XCTAssertNil(WorkspaceKeyboard.handle(try key(text, code: code, flags: flags, repeated: repeated), model: model))
        }

        model.choose(["0000"], active: "0000")
        try send("`", code: 50)
        XCTAssertEqual(try catalog.photo("0000")?.flag, 1)
        try send("`", code: 50, repeated: true)
        XCTAssertEqual(try catalog.photo("0000")?.flag, 1, "A repeated keydown must not toggle the flag again")
        try send("`", code: 50)
        XCTAssertEqual(try catalog.photo("0000")?.flag, 0)
        try send("p", code: 35); XCTAssertEqual(try catalog.photo("0000")?.flag, 1)
        try send("x", code: 7); XCTAssertEqual(try catalog.photo("0000")?.flag, -1)
        try send("u", code: 32); XCTAssertEqual(try catalog.photo("0000")?.flag, 0)

        model.autoAdvance = true; model.choose(["0000"], active: "0000")
        try send("p", code: 35); XCTAssertEqual(model.activeID, "0001", "Auto advance moves after an explicit flag")
        model.choose(["0001"], active: "0001")
        try send("x", code: 7, flags: [.shift]); XCTAssertEqual(model.activeID, "0001", "Shift reverses auto advance")
        model.autoAdvance = false; model.choose(["0001"], active: "0001")
        try send("p", code: 35, flags: [.capsLock]); XCTAssertEqual(model.activeID, "0002", "Caps Lock enables advance for a culling pass")
        model.choose(["0002"], active: "0002")
        try send("x", code: 7, flags: [.capsLock, .shift]); XCTAssertEqual(model.activeID, "0002", "Shift and Caps Lock cancel each other")

        try catalog.database.write { try $0.execute(sql: "UPDATE photo SET flag=0") }
        try model.reload(); model.flagFilter = [0]; model.filterChanged(); model.choose(["0000"], active: "0000"); model.autoAdvance = true
        try send("p", code: 35)
        XCTAssertEqual(model.activeID, "0001", "When a filter removes the marked photo, auto advance must not skip its replacement")

        model.flagFilter = []; model.filterChanged(); model.choose(["0199"], active: "0199"); model.autoAdvance = true
        try send("p", code: 35)
        XCTAssertEqual(model.pageOffset, 200); XCTAssertEqual(model.activeID, "0200", "Advancing at a page boundary enters the next page")
        model.choose(["0204"], active: "0204")
        try send("p", code: 35)
        XCTAssertEqual(model.activeID, "0204", "Advancing at the final photo stays on the final photo")
        withExtendedLifetime(window) {}
    }

    @MainActor func testLibraryFilterSectionsGateQueriesAndRetainConditions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder), root = try catalog.addRoot(url: folder, bookmark: Data())
        for (name, flag, camera) in [("A1", 1, "Camera A"), ("A2", 0, "Camera A"), ("A3", 1, "Camera B"), ("B1", 1, "Camera A")] {
            try catalog.index(Photo(id: name, rootID: root.id, relativePath: name + ".jpg", identity: Data(), identityKey: name, flag: flag, width: 1, height: 1, camera: camera))
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; model.search = "A"; model.flagFilter = [1]; model.metadataFilter.camera = "Camera A"
        try model.reload(); model.filterChanged()
        func ids() throws -> Set<String> { Set(try catalog.page(model.query, offset: 0).photos.map(\.id)) }
        XCTAssertEqual(try ids(), ["A1"])
        model.selectFilterSection(.attribute)
        XCTAssertEqual(try ids(), ["A1", "A2"])
        XCTAssertEqual(model.flagFilter, [1], "Closing a section retains its conditions but removes them from the query")
        model.selectFilterSection(.metadata)
        XCTAssertEqual(try ids(), ["A1", "A2", "A3"])
        model.disableLibraryFilters()
        XCTAssertEqual(try ids(), ["A1", "A2", "A3", "B1"])
        XCTAssertEqual(model.search, "A"); XCTAssertEqual(model.metadataFilter.camera, "Camera A")
        XCTAssertFalse(model.hasLibraryFilters)
        model.selectFilterSection(.attribute)
        XCTAssertEqual(model.filterSections, [.attribute])
        XCTAssertEqual(try ids(), ["A1", "A3", "B1"], "Reopening one section must not silently re-enable other saved conditions")
        model.selectFilterSection(.text)
        XCTAssertEqual(model.filterSections, [.text, .attribute], "A meaningful open group stays visible when another group opens")
        XCTAssertEqual(try ids(), ["A1", "A3"])
        model.selectFilterSection(.metadata)
        XCTAssertEqual(try ids(), ["A1"])
        model.libraryFiltersOpen = false; model.filterChanged()
        XCTAssertEqual(try ids(), ["A1"], "Hiding the entire bar does not turn filtering off")
        model.clearFilters(); model.filterChanged()
        XCTAssertEqual(try ids().count, 4); XCTAssertTrue(model.filterSections.isEmpty)
    }

    @MainActor func testLibraryFilterSectionSwitchingAndCombination() {
        let model = AppModel()
        XCTAssertEqual(model.filterSections, [.attribute])
        model.selectFilterSection(.text)
        XCTAssertEqual(model.filterSections, [.text], "Empty groups do not leave duplicate rows behind")
        model.selectFilterSection(.metadata)
        XCTAssertEqual(model.filterSections, [.metadata])
        model.selectFilterSection(.attribute, additive: true)
        XCTAssertEqual(model.filterSections, [.metadata, .attribute])
        model.selectFilterSection(.attribute)
        XCTAssertEqual(model.filterSections, [.metadata])
        model.disableLibraryFilters(); model.selectFilterSection(.text)
        XCTAssertEqual(model.filterSections, [.text]); XCTAssertTrue(model.filtersEnabled)
    }

    @MainActor func testFilterCommandsRestoreCriteriaAndRespectTextFocus() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder), root = try catalog.addRoot(url: folder, bookmark: Data())
        for index in 0..<3 {
            try catalog.index(Photo(id: String(index), rootID: root.id, relativePath: "\(index).jpg", identity: Data(), identityKey: "filter-\(index)", flag: index - 1, width: 1, height: 1))
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; model.flagFilter = [1]; try model.reload()
        model.choose(["2"], active: "2")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        func key(_ text: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        }
        XCTAssertNil(WorkspaceKeyboard.handle(try key("l", flags: .command), model: model))
        XCTAssertEqual(model.resultCount, 3); XCTAssertEqual(model.flagFilter, [1]); XCTAssertFalse(model.filtersEnabled)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("l", flags: .command), model: model))
        XCTAssertEqual(model.resultCount, 1); XCTAssertTrue(model.filtersEnabled)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\\"), model: model)); XCTAssertFalse(model.libraryFiltersOpen)
        model.clearFilters(); model.filterChanged(); model.beginComparison()
        XCTAssertNotNil(model.comparison)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\\"), model: model)); XCTAssertTrue(model.libraryFiltersOpen)
        let editor = NSTextView(frame: .zero); window.contentView = editor; window.makeFirstResponder(editor)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("l", flags: .command), model: model))
        XCTAssertTrue(model.filtersEnabled, "Text editing retains its shortcuts")
        window.contentView = nil
        withExtendedLifetime(window) {}
    }

    @MainActor func testGridCollectionRoutesCullingThroughSharedCommandPath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        try catalog.index(Photo(id: "0000", rootID: root.id, relativePath: "0000.jpg", identity: Data(), identityKey: "grid-0000", width: 1, height: 1))
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; try model.reload(); model.choose(["0000"], active: "0000")
        model.singleView = false; model.editMode = false
        let host = NSHostingView(rootView: PhotoGrid(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; host.frame = window.contentView?.bounds ?? .zero; host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        func collection(_ view: NSView) -> KeyboardCollectionView? {
            if let value = view as? KeyboardCollectionView { return value }
            return view.subviews.compactMap(collection).first
        }
        let grid = try XCTUnwrap(collection(host), "PhotoGrid must install its KeyboardCollectionView command handler")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        grid.keyDown(with: event)
        XCTAssertEqual(try catalog.photo("0000")?.flag, 1)
        withExtendedLifetime(window) {}
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw LRCError("Timed out waiting for thumbnail")
    }
}
