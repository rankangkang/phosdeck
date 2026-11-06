import XCTest
import SwiftUI
import CoreImage
@testable import Phosdeck

final class ComparisonTests: XCTestCase {
    @MainActor func testSurveyNineVisibleTilesFitBothThemesAtThreeWindowSizes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder, count: 12)
        model.choose(Set((0..<12).map { String(format: "%03d", $0) }), active: "000"); model.beginSurvey()
        let suite = "survey-layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); model.endSurvey(); model.choose([], active: nil) }
        for key in ["showLeftPanel", "showRightPanel", "showFilmstrip"] { preferences.set(true, forKey: key) }
        func canvases(_ root: NSView) -> [PhotoMetalCanvas] { (root as? PhotoMetalCanvas).map { [$0] } ?? root.subviews.flatMap(canvases) }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for size in [CGSize(width: 1440, height: 900), CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 640)] {
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                let container = NSView(frame: CGRect(origin: .zero, size: size))
                host.frame = container.bounds; container.addSubview(host); window.contentView = container
                defer { window.contentView = nil }
                try await waitUntil { canvases(host).count == 9 && canvases(host).allSatisfy { $0.source != nil } }
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
                for canvas in canvases(host) {
                    XCTAssertGreaterThan(canvas.frame.width, 65); XCTAssertGreaterThan(canvas.frame.height, 40)
                    let rect = canvas.convert(canvas.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertGreaterThanOrEqual(rect.minY, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, host.bounds.width); XCTAssertLessThanOrEqual(rect.maxY, host.bounds.height)
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "survey-\(Int(size.width))-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    @MainActor func testMomentaryMaskPreviewRestoresAndNeverLeaksIntoHistoryOrExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = try bitmap(), bypassPixels = try bitmap(40)
        var delay = false, release: CheckedContinuation<RenderedImage, Never>?
        let model = try model(in: folder, renderer: { request, _, _ in
            if delay, request.recipe?.localAdjustments.first?.enabled == false {
                delay = false; return await withCheckedContinuation { release = $0 }
            }
            return request.recipe?.localAdjustments.first?.enabled == false ? bypassPixels : pixels
        })
        model.activeID = nil; model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit }
        let group = LocalAdjustment(name: "测试蒙版", components: [MaskComponent(tool: .linear)], exposure: 1)
        model.changeRecipe({ $0.localAdjustments = [group] }, title: "蒙版调整")
        model.selectDevelopTool(.mask); model.selectMask(group.id, component: group.components.first?.id)
        try await waitUntil { model.previewCurrent }
        let saved = model.recipe, history = model.editHistory.count
        model.undo.removeAllActions()
        model.beginMaskEffectPreview(group.id)
        try await waitUntil { model.interactivePreview && model.image?.width == 40 }
        XCTAssertEqual(model.recipe, saved); XCTAssertFalse(model.dirty); XCTAssertFalse(model.undo.canUndo)
        XCTAssertEqual(model.editHistory.count, history)
        let photos = try model.exportSelection(), options = ExportOptions()
        let names = try ExportNamingPlanner.preview(photos: photos, options: options, directory: folder)
        let snapshots = try model.prepareExport(options: options, photos: photos, names: names, directory: folder)
        XCTAssertEqual(snapshots.first?.request.recipe?.localAdjustments.first?.enabled, true)
        model.endMaskEffectPreview()
        XCTAssertEqual(model.image?.width, 80, "Release restores the last real image before the quality render finishes")
        try await waitUntil { model.previewCurrent && model.image?.width == 80 }
        XCTAssertNil(model.previewingMaskID); XCTAssertEqual(model.recipe, saved)
        delay = true; model.beginMaskEffectPreview(group.id)
        try await waitUntil { release != nil }
        model.endMaskEffectPreview()
        release?.resume(returning: bypassPixels); release = nil
        try await waitUntil { model.previewCurrent && model.image?.width == 80 }
        XCTAssertNil(model.previewingMaskID); XCTAssertEqual(model.editHistory.count, history)
        model.beginMaskEffectPreview(group.id); model.choose(["001"], active: "001")
        XCTAssertNil(model.previewingMaskID)
        try await waitUntil { model.canEdit }
        model.beginMaskEffectPreview(group.id); XCTAssertNil(model.previewingMaskID)
    }

    @MainActor func testSavedStatePreviewBaselineAndDerivedCopyLeaveCurrentEditUntouched() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = try bitmap()
        var calls: [ImageRequest] = []
        let model = try model(in: folder, renderer: { request, _, _ in calls.append(request); return pixels })
        model.activeID = nil; model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit }
        let original = try XCTUnwrap(model.recipe), data = try JSONEncoder().encode(original)
        model.changeRecipe({ $0.exposure = 1; $0.quarterTurns = 1 }, title: "当前")
        let persisted = try model.catalog?.photo("000")?.recipe, history = model.editHistory.count
        model.changeRecipe({ $0.contrast = 1.2 }, commit: false) // Keep even an uncommitted current draft.
        let draft = model.recipe
        model.undo.removeAllActions()
        model.previewSavedEdit(data: data, photoID: "000", key: "old", title: "导入")
        let preview = try XCTUnwrap(model.savedEditPreview)
        try await waitUntil { preview.image != nil }
        XCTAssertEqual(model.recipe, draft); XCTAssertTrue(model.dirty); XCTAssertFalse(model.undo.canUndo)
        XCTAssertEqual(model.editHistory.count, history); XCTAssertEqual(try model.catalog?.photo("000")?.recipe, persisted)
        model.clearSavedEditPreview(key: "other"); XCTAssertNotNil(model.savedEditPreview)
        model.setBeforeReference(data: data, photoID: "000", title: "导入")
        try await waitUntil { model.beforeImage != nil }
        XCTAssertNil(model.savedEditPreview); XCTAssertNil(preview.image)
        XCTAssertEqual(model.beforeReference?.recipe, original)
        XCTAssertEqual(calls.last?.recipe?.exposure, 0)
        XCTAssertTrue(calls.contains { $0.recipe?.exposure == 0 && $0.recipe?.quarterTurns == 1 }, "Before uses the current orientation")
        XCTAssertEqual(model.recipe, draft); XCTAssertTrue(model.dirty); XCTAssertEqual(model.editHistory.count, history)
        model.undo.beginUndoGrouping(); model.createVirtualCopy(data: data, photoID: "000", title: "导入"); model.undo.endUndoGrouping()
        let versions = try XCTUnwrap(model.catalog).versions(sourceID: "000")
        let copy = try XCTUnwrap(versions.first { $0.id != "000" })
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(copy.recipe)), original)
        XCTAssertEqual(model.recipe, draft); XCTAssertTrue(model.dirty); XCTAssertEqual(model.activeID, "000")
        XCTAssertEqual(try model.catalog?.photo("000")?.recipe, persisted)
        XCTAssertEqual(model.editHistory.count, history)
        model.undo.undo(); XCTAssertNil(try model.catalog?.photo(copy.id)); XCTAssertEqual(model.recipe, draft)
        model.resetBeforeReference(); XCTAssertNil(model.beforeReference)
        model.choose(["001"], active: "001")
        XCTAssertNil(model.beforeReference); XCTAssertNil(model.savedEditPreview)
    }

    @MainActor func testSavedStatePreviewCancellationRejectsLatePixelsAndWrongIdentity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = try bitmap()
        var release: CheckedContinuation<RenderedImage, Never>?
        let model = try model(in: folder, renderer: { request, _, edge in
            if edge == 480 { return await withCheckedContinuation { release = $0 } }
            return pixels
        })
        model.activeID = nil; model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit }
        let original = try XCTUnwrap(model.recipe), data = try JSONEncoder().encode(original)
        model.previewSavedEdit(data: data, photoID: "000", key: "late", title: "旧状态")
        let pane = try XCTUnwrap(model.savedEditPreview)
        try await waitUntil { release != nil }
        model.choose(["001"], active: "001")
        release?.resume(returning: pixels); release = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(pane.image); XCTAssertNil(model.savedEditPreview); XCTAssertNil(model.beforeReference)
        try await waitUntil { model.canEdit }
        var wrong = original; wrong.sourceDigest = String(repeating: "b", count: 64)
        model.createVirtualCopy(data: try JSONEncoder().encode(wrong), photoID: "001", title: "外来状态")
        XCTAssertEqual(try model.catalog?.photoCount(), 3); XCTAssertNotNil(model.error)
        XCTAssertThrowsError(try model.catalog?.createVirtualCopies(ids: ["000", "001"], recipeOverride: original))
    }

    @MainActor func testQuickCollectMixedMembershipScopeUndoAndDeletedTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder, count: 203)
        let catalog = try XCTUnwrap(model.catalog)
        model.pageOffset = 200; try model.reloadPhotos()
        model.choose(["000", "201"], active: "201")
        model.undo.beginUndoGrouping(); model.toggleQuickCollection(); model.undo.endUndoGrouping()
        let quick = try XCTUnwrap(model.targetCollectionID)
        XCTAssertEqual(try catalog.members(quick), ["000", "201"])
        XCTAssertEqual(model.quickCollectMembership, true)
        model.undo.undo(); XCTAssertTrue(try catalog.members(quick).isEmpty)
        model.undo.redo(); XCTAssertEqual(try catalog.members(quick).count, 2)
        try catalog.collection(name: "交付", id: "delivery")
        try catalog.membership(ids: ["000"], collection: "delivery", add: true)
        try model.reload(); model.setTargetCollection("delivery")
        XCTAssertNil(model.quickCollectMembership)
        model.undo.removeAllActions(); model.undo.beginUndoGrouping(); model.toggleQuickCollection(); model.undo.endUndoGrouping()
        XCTAssertEqual(try catalog.members("delivery"), ["000", "201"])
        model.undo.undo(); XCTAssertEqual(try catalog.members("delivery"), ["000"], "Undo preserves the member present before a mixed add")
        model.selectWorkspace(.single)
        XCTAssertEqual(model.quickCollectIDs, ["201"])
        model.toggleQuickCollection(); XCTAssertEqual(try catalog.members("delivery"), ["000", "201"])
        model.toggleQuickCollection(); XCTAssertEqual(try catalog.members("delivery"), ["000"])
        model.beginSurvey(ids: ["000", "201"], active: "000")
        XCTAssertEqual(model.quickCollectIDs, ["000"]); XCTAssertEqual(model.quickCollectMembership, true)
        model.toggleQuickCollection(); XCTAssertTrue(try catalog.members("delivery").isEmpty)
        try catalog.deleteCollection("delivery"); try model.reload()
        XCTAssertEqual(model.targetCollectionID, quick, "A removed target falls back to this catalog's quick collection")
        model.catalogUtilityOpen = true; model.toggleQuickCollection()
        XCTAssertEqual(try catalog.members(quick), ["000", "201"])
        model.catalogUtilityOpen = false
        try model.activateCatalog(CatalogStore(directory: folder.appendingPathComponent("other")))
        XCTAssertNil(model.targetCollectionID); XCTAssertEqual(model.quickCollectMembership, false)
    }

    @MainActor func testQuickCollectEmptyAndSmartTargetsDoNotWriteAndSubsetReadIsBounded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder, count: 1103), catalog = try XCTUnwrap(model.catalog)
        model.choose([], active: nil); model.toggleQuickCollection()
        XCTAssertTrue(model.collections.isEmpty)
        _ = try catalog.replaceSmartCollection(id: "smart", with: PhotoCollection(id: "smart", name: "智能", rules: try JSONEncoder().encode(SmartRules())))
        try model.reload(); model.setTargetCollection("smart")
        XCTAssertNil(model.targetCollectionID)
        model.choose(["000"], active: "000"); model.toggleQuickCollection()
        let target = try XCTUnwrap(model.targetCollectionID)
        let ids = Set((0..<1103).map { String(format: "%03d", $0) })
        try catalog.membership(ids: Array(ids), collection: target, add: true)
        XCTAssertEqual(try catalog.members(target, within: ids).count, 1103)
        XCTAssertEqual(try catalog.members(target, within: ["000", "1102", "absent"]), ["000", "1102"])
        XCTAssertTrue(try catalog.members(target, within: []).isEmpty)
    }

    @MainActor func testPromoteComparisonCandidateAndExplicitGroupAcrossPages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder, count: 203)
        model.choose(["000", "201"], active: "000"); model.beginComparison()
        let pair = try XCTUnwrap(model.comparison)
        XCTAssertEqual(pair.reference.photo?.id, "000"); XCTAssertEqual(model.activeID, "201")
        model.promoteComparisonCandidate()
        XCTAssertEqual(pair.reference.photo?.id, "201"); XCTAssertEqual(model.activeID, "202")
        XCTAssertEqual(model.pageOffset, 200)
        model.restrictComparisonToGroup(true)
        XCTAssertEqual(model.activeID, "000", "The candidate must belong to the chosen group and differ from the reference")
        model.promoteComparisonCandidate()
        XCTAssertEqual(pair.reference.photo?.id, "000"); XCTAssertEqual(model.activeID, "201")
        model.move(1); XCTAssertEqual(model.activeID, "201", "A group boundary must not escape into unselected photos")
        model.swapComparison()
        XCTAssertEqual(pair.reference.photo?.id, "201"); XCTAssertEqual(model.activeID, "000")
        XCTAssertEqual(model.selection, ["000"])
        model.catalogUtilityOpen = true; model.promoteComparisonCandidate()
        XCTAssertEqual(pair.reference.photo?.id, "201", "Sheets block candidate promotion")
        model.catalogUtilityOpen = false; model.endComparison()
        XCTAssertNil(pair.reference.image); XCTAssertNil(pair.candidate.image)
    }

    @MainActor func testSurveyRendersOnlyVisibleGroupRatesActiveAndRemovesWithoutDeleting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder, count: 203)
        let selected = Set((0..<203).map { String(format: "%03d", $0) })
        try model.catalog?.setOrganization(ids: ["001"], rating: 3)
        model.choose(selected, active: "000"); model.beginSurvey()
        let survey = try XCTUnwrap(model.survey)
        try await waitUntil { survey.tiles.count == 9 && survey.tiles.allSatisfy { $0.image != nil } }
        let oldTiles = survey.tiles
        XCTAssertEqual(model.selection.count, 203); XCTAssertEqual(survey.members.count, 203)
        XCTAssertEqual(model.selectedRating, 0, "Entering Survey replaces the grid's mixed summary with the active photo")
        model.undo.beginUndoGrouping(); model.organize(rating: 4); model.undo.endUndoGrouping()
        XCTAssertEqual(try model.catalog?.photo("000")?.rating, 4)
        XCTAssertEqual(try model.catalog?.photo("001")?.rating, 3)
        XCTAssertEqual(model.selectedRating, 4)
        model.undo.undo(); XCTAssertEqual(model.selectedRating, 0)
        model.changeSurveyPage(1)
        XCTAssertEqual(survey.offset, 9); XCTAssertEqual(model.activeID, "009")
        XCTAssertTrue(oldTiles.allSatisfy { $0.image == nil }, "A page releases all previous preview pixels")
        model.activateSurveyPhoto("202")
        XCTAssertEqual(model.pageOffset, 200); XCTAssertEqual(survey.offset, 198); XCTAssertEqual(survey.tiles.count, 5)
        model.removeFromSurvey("202")
        XCTAssertEqual(survey.ids.count, 202); XCTAssertNotNil(try model.catalog?.photo("202"))
        XCTAssertEqual(try model.catalog?.photoCount(), 203)
        XCTAssertEqual(model.activeID, "201")
        model.selectWorkspace(.grid)
        XCTAssertNil(model.survey); XCTAssertEqual(model.selection.count, 202)
        XCTAssertNil(model.selectedRating, "Returning to the grid restores its group summary")
        XCTAssertTrue(survey.tiles.isEmpty)
    }

    @MainActor func testSurveyFilterUndoAndImportReturnRestoreCandidateMembers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder, count: 3)
        model.flagFilter = [0]; model.filterChanged()
        model.choose(["000", "001", "002"], active: "000"); model.beginSurvey()
        model.undo.beginUndoGrouping(); model.organize(flag: 1); model.undo.endUndoGrouping()
        XCTAssertEqual(model.survey?.ids, ["001", "002"])
        XCTAssertEqual(model.survey?.members.count, 3)
        model.undo.undo()
        XCTAssertEqual(model.survey?.ids.count, 3, "Undo restores a filtered candidate without undoing explicit deselection")
        model.removeFromSurvey("000"); model.removeFromSurvey("002")
        XCTAssertEqual(model.survey?.ids, ["001"])
        try model.completeImport(ids: ["002"], cancelled: false)
        model.showLastImport(startCulling: true); XCTAssertNil(model.survey)
        model.returnFromImport()
        XCTAssertEqual(model.survey?.ids, ["001"]); XCTAssertEqual(model.activeID, "001")
        try model.activateCatalog(CatalogStore(directory: folder.appendingPathComponent("another")))
        XCTAssertNil(model.survey)
    }

    @MainActor func testCropKeysOwnXWithoutRejectingOrAdvancingAndGuidesDoNotSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder)
        model.activeID = nil // The fixture starts with metadata only; choose must load its recipe.
        model.choose(["000", "001"], active: "000")
        model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit }
        model.flagFilter = [0]; model.filterChanged(); model.autoAdvance = true
        model.selectDevelopTool(.crop)
        let original = try XCTUnwrap(model.recipe)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        window.contentView = NSView()
        func key(_ text: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: repeated, keyCode: code))
        }
        model.undo.removeAllActions(); model.undo.beginUndoGrouping()
        XCTAssertNil(WorkspaceKeyboard.handle(try key("x", flags: .capsLock), model: model))
        model.undo.endUndoGrouping()
        XCTAssertEqual(model.recipe?.cropAspectRatio, 0.75)
        XCTAssertEqual(model.activeID, "000"); XCTAssertEqual(model.resultCount, 3)
        XCTAssertTrue(try model.catalog!.photos(ids: ["000", "001"]).allSatisfy { $0.flag == 0 })
        let swapped = model.recipe
        XCTAssertNil(WorkspaceKeyboard.handle(try key("x", repeated: true), model: model))
        XCTAssertNil(WorkspaceKeyboard.handle(try key("x", flags: .shift), model: model))
        XCTAssertEqual(model.recipe, swapped)
        model.undo.undo(); XCTAssertEqual(model.recipe, original)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("a"), model: model))
        XCTAssertEqual(model.recipe?.cropAspectRatio, 4.0 / 3)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("a"), model: model))
        XCTAssertNil(model.recipe?.cropAspectRatio)
        let historyCount = model.editHistory.count, current = model.recipe
        model.undo.removeAllActions()
        XCTAssertNil(WorkspaceKeyboard.handle(try key("o"), model: model))
        XCTAssertEqual(model.cropGuide, .grid); XCTAssertEqual(model.recipe, current)
        XCTAssertEqual(model.editHistory.count, historyCount); XCTAssertFalse(model.undo.canUndo)
        let editor = NSTextView(frame: .zero); window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("x"), model: model)); XCTAssertEqual(model.recipe, current)
        window.makeFirstResponder(window.contentView)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\r", code: 36), model: model))
        XCTAssertFalse(model.cropMode); XCTAssertTrue(model.editMode); XCTAssertEqual(model.recipe, current)
    }

    func testCropGuidesStayInsideNonSquareTranslatedFrameAndCycleBack() {
        let rect = CGRect(x: 17, y: 23, width: 310, height: 90)
        var guide = CropGuide.thirds
        for _ in CropGuide.allCases {
            for (a,b) in guide.lines(in: rect) {
                for p in [a,b] {
                    XCTAssertTrue((rect.minX...rect.maxX).contains(p.x))
                    XCTAssertTrue((rect.minY...rect.maxY).contains(p.y))
                }
            }
            guide = guide.next
        }
        XCTAssertEqual(guide, .thirds); XCTAssertTrue(CropGuide.none.lines(in: rect).isEmpty)
    }

    private func bitmap(_ width: Int = 80) throws -> RenderedImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: 40)
        let image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .red).cropped(to: rect), from: rect))
        return RenderedImage(image: image, fullSize: CGSize(width: 4000, height: 3000),
                             orientedSourceSize: CGSize(width: 4000, height: 3000), histogram: nil, elapsed: 0)
    }
    @MainActor private func model(in folder: URL, count: Int = 3, renderer: ((ImageRequest, Bool, Int?) async throws -> RenderedImage)? = nil) throws -> AppModel {
        let image = try bitmap()
        let model = AppModel(previewRenderer: renderer ?? { _, _, _ in image })
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        // The injected renderer uses synthetic pixels, with a ready raster recipe
        // so switching out of comparison does not need a filesystem decoder.
        let baseline = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
            baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        for n in 0..<count {
            let id = String(format: "%03d", n)
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(),
                                    identityKey: id, width: 4000, height: 3000, recipe: JSONEncoder().encode(baseline), metadata: JSONEncoder().encode(PhotoMetadata())))
        }
        model.catalog = catalog; try model.reload()
        model.activePhoto = model.photos.first; model.activeID = model.active?.id
        model.selection = Set(model.activeID.map { [$0] } ?? [])
        return model
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    @MainActor func testPhotoSwitchKeepsDisplaySeparateFromEditsAndRejectsStaleFrames() async throws {
        @MainActor final class Gate {
            var blocked: Set<String> = ["001", "002"]
            var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
            func wait(_ id: String) async {
                if blocked.contains(id) { await withCheckedContinuation { waiting[id, default: []].append($0) } }
            }
            func release(_ id: String) {
                blocked.remove(id)
                waiting.removeValue(forKey: id)?.forEach { $0.resume() }
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = Gate(), pixels = try ["000": bitmap(80), "001": bitmap(60), "002": bitmap(40)]
        let model = try model(in: folder, renderer: { request, _, _ in
            await gate.wait(request.photo.id)
            return try XCTUnwrap(pixels[request.photo.id])
        })
        defer { gate.release("001"); gate.release("002"); model.choose([], active: nil) }
        let catalog = try XCTUnwrap(model.catalog)
        var secondRecipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo("001")?.recipe))
        secondRecipe.exposure = 1
        try catalog.saveRecipe(id: "001", recipe: secondRecipe)
        try model.reloadPhotos()
        model.choose([], active: nil); model.choose(["000"], active: "000")
        try await waitUntil { model.canEdit && model.previewCurrent }
        let original = try XCTUnwrap(model.image)
        let originalRecipe = try XCTUnwrap(model.recipe)
        model.selectWorkspace(.develop)
        let suite = "switch-controls-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        for key in ["showLeftPanel", "showRightPanel", "showFilmstrip", "developBasicOpen"] { preferences.set(true, forKey: key) }
        preferences.set(false, forKey: "developSoloMode")
        preferences.set(false, forKey: "developShowOnlyModified")
        preferences.set(304.0, forKey: "workspaceRightWidth")
        preferences.set(160.0, forKey: "developScrollOffset")
        let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        window.contentView = host
        defer { window.contentView = nil; preferences.removePersistentDomain(forName: suite) }
        func sliders(_ root: NSView) -> [AdjustmentNSSlider] {
            (root as? AdjustmentNSSlider).map { [$0] } ?? root.subviews.flatMap(sliders)
        }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { sliders(host).count >= 13 }
        let originalSliders = sliders(host)
        let exposure = try XCTUnwrap(originalSliders.first { $0.accessibilityLabel() == L10n.text("app.exposure", defaultValue: "Exposure") })
        let editorScroll = try XCTUnwrap(exposure.enclosingScrollView)
        try await waitUntil { abs(editorScroll.contentView.bounds.minY - 160) < 1 }
        let originalFrame = exposure.convert(exposure.bounds, to: host)
        func collection(_ root: NSView) -> KeyboardCollectionView? {
            (root as? KeyboardCollectionView) ?? root.subviews.compactMap(collection).first
        }
        let film = try XCTUnwrap(collection(host))
        let selectionBridge = try XCTUnwrap(film.delegate as? PhotoGrid.Coordinator)
        let oldPath = IndexPath(item: try XCTUnwrap(model.filtered.firstIndex { $0.id == "000" }), section: 0)
        let newPath = IndexPath(item: try XCTUnwrap(model.filtered.firstIndex { $0.id == "001" }), section: 0)
        // AppKit reports deselection before selection when a thumbnail replaces
        // the current selection. That intermediate empty set is not a deselect command.
        film.selectionIndexPaths = []
        selectionBridge.collectionView(film, didDeselectItemsAt: [oldPath])
        XCTAssertEqual(model.activeID, "000", "An intermediate native deselection must not clear the editor")
        film.selectionIndexPaths = [newPath]
        selectionBridge.collectionView(film, didSelectItemsAt: [newPath])
        try await waitUntil { model.activeID == "001" }
        if let recipe = model.recipe { XCTAssertEqual(recipe, secondRecipe, "A native selection may already have loaded the current recipe") }
        XCTAssertNil(model.image); XCTAssertFalse(model.canEdit)
        XCTAssertTrue(model.loadingPhoto)
        XCTAssertEqual(model.photoSwitchDisplay?.photoID, "000")
        XCTAssertTrue(model.photoSwitchDisplay?.image === original)
        XCTAssertEqual(model.editorRecipe, originalRecipe)
        try await waitUntil { gate.waiting["001"]?.count == 2 }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sliders(host).map(ObjectIdentifier.init), originalSliders.map(ObjectIdentifier.init), "Loading must retain the mounted native controls")
        XCTAssertFalse(exposure.isEnabled)
        XCTAssertTrue(exposure.preservesAppearance, "Loading locks the actual control without dimming its material")
        XCTAssertNil(CommandResponder.manager(model: model, window: window), "Command-Z cannot consume photo undo while loading")
        XCTAssertTrue(exposure.enclosingScrollView === editorScroll)
        XCTAssertEqual(editorScroll.contentView.bounds.minY, 160, accuracy: 1)
        XCTAssertEqual(exposure.convert(exposure.bounds, to: host), originalFrame)
        XCTAssertEqual(model.recipe, secondRecipe, "Only the current photo's recipe can enter edit/export state")
        XCTAssertEqual(model.editorRecipe, originalRecipe, "The disabled panel remains stable until matching pixels arrive")
        XCTAssertFalse(model.canShowBeforeAfter, "Old pixels must not enter a comparison canvas identified as the new photo")
        model.changeRecipe { $0.exposure = 4 }
        XCTAssertEqual(model.recipe, secondRecipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo("001")?.recipe)), secondRecipe)
        let photos = try model.exportSelection(), options = ExportOptions()
        let names = try ExportNamingPlanner.preview(photos: photos, options: options, directory: folder)
        let snapshots = try model.prepareExport(options: options, photos: photos, names: names, directory: folder)
        XCTAssertEqual(snapshots.first?.request.photo.id, "001")
        XCTAssertEqual(snapshots.first?.request.recipe, secondRecipe, "Export must ignore the previous photo's display snapshot")
        model.choose(["002"], active: "002")
        XCTAssertTrue(model.loadingPhoto)
        XCTAssertTrue(model.photoSwitchDisplay?.image === original)
        try await waitUntil { model.recipe != nil }
        gate.release("001")
        try await waitUntil { gate.waiting["002"]?.count == 2 }
        XCTAssertNil(model.image, "A completed render for the skipped photo must not publish")
        XCTAssertEqual(model.photoSwitchDisplay?.photoID, "000")
        gate.release("002")
        try await waitUntil { model.canEdit && model.previewCurrent }
        XCTAssertNil(model.photoSwitchDisplay)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sliders(host).map(ObjectIdentifier.init), originalSliders.map(ObjectIdentifier.init), "Publication must update the existing controls")
        XCTAssertTrue(exposure.isEnabled)
        XCTAssertFalse(model.loadingPhoto)
        XCTAssertTrue(CommandResponder.manager(model: model, window: window) === model.undo)
        XCTAssertEqual(model.image?.width, 40)
        XCTAssertEqual(model.activeID, "002"); XCTAssertEqual(model.editorRecipe, model.recipe)
        XCTAssertTrue(model.canShowBeforeAfter)
        let thirdRecipe = try XCTUnwrap(model.recipe)
        try await catalog.database.write { db in
            try db.execute(sql: "UPDATE photo SET recipe = ? WHERE id = ?", arguments: [Data("invalid recipe".utf8), "001"])
        }
        try model.reloadPhotos()
        model.choose(["001"], active: "001")
        XCTAssertNotNil(model.photoSwitchDisplay)
        try await waitUntil { model.photoSwitchDisplay == nil }
        XCTAssertNil(model.image); XCTAssertNil(model.recipe); XCTAssertFalse(model.canEdit)
        XCTAssertFalse(model.loadingPhoto, "A failed decode must stop the waiting indicator")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sliders(host).map(ObjectIdentifier.init), originalSliders.map(ObjectIdentifier.init), "A failed load must retain disabled editor controls as well")
        XCTAssertFalse(exposure.isEnabled)
        XCTAssertTrue(exposure.preservesAppearance)
        XCTAssertTrue(exposure.enclosingScrollView === editorScroll)
        XCTAssertEqual(editorScroll.contentView.bounds.minY, 160, accuracy: 1)
        try await catalog.database.write { db in
            try db.execute(sql: "UPDATE photo SET recipe = ? WHERE id = ?", arguments: [try JSONEncoder().encode(secondRecipe), "001"])
        }
        try model.reloadPhotos()
        gate.blocked.insert("001")
        model.retryPhotoLoad()
        XCTAssertTrue(model.loadingPhoto)
        try await waitUntil { gate.waiting["001"]?.count == 2 }
        XCTAssertFalse(exposure.isEnabled)
        gate.release("001")
        try await waitUntil { model.canEdit && model.previewCurrent }
        XCTAssertFalse(model.loadingPhoto)
        XCTAssertEqual(model.recipe, secondRecipe)
        XCTAssertEqual(sliders(host).map(ObjectIdentifier.init), originalSliders.map(ObjectIdentifier.init), "Retry must reuse the same controls")
        // Fail again to cover changing photos when no previous image is available.
        try await catalog.database.write { db in
            try db.execute(sql: "UPDATE photo SET recipe = ? WHERE id = ?", arguments: [Data("invalid recipe".utf8), "002"])
        }
        try model.reloadPhotos()
        model.choose(["002"], active: "002")
        try await waitUntil { !model.loadingPhoto }
        try await catalog.database.write { db in
            try db.execute(sql: "UPDATE photo SET recipe = ? WHERE id = ?", arguments: [try JSONEncoder().encode(thirdRecipe), "002"])
        }
        try model.reloadPhotos()
        model.choose(["000"], active: "000")
        XCTAssertNil(model.photoSwitchDisplay, "There is no previous image after a failed decode")
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sliders(host).map(ObjectIdentifier.init), originalSliders.map(ObjectIdentifier.init), "Switching without an image must retain the same controls")
        try await waitUntil { model.canEdit && model.previewCurrent }
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(sliders(host).map(ObjectIdentifier.init), originalSliders.map(ObjectIdentifier.init))
        let thirdPath = IndexPath(item: try XCTUnwrap(model.filtered.firstIndex { $0.id == "002" }), section: 0)
        film.selectionIndexPaths = [oldPath, thirdPath]
        selectionBridge.collectionView(film, didSelectItemsAt: [thirdPath])
        try await waitUntil { model.selection == ["000", "002"] && model.activeID == "002" }
        film.selectionIndexPaths = [oldPath]
        selectionBridge.collectionView(film, didDeselectItemsAt: [thirdPath])
        try await waitUntil { model.selection == ["000"] && model.activeID == "000" }
        film.selectionIndexPaths = [oldPath]
        selectionBridge.collectionView(film, didSelectItemsAt: [oldPath])
        // A queued pointer update must not undo a later source/navigation change.
        model.choose(["002"], active: "002")
        try await waitUntil { model.canEdit && model.previewCurrent }
        XCTAssertEqual(model.activeID, "002")
        film.selectionIndexPaths = []
        selectionBridge.collectionView(film, didDeselectItemsAt: [thirdPath])
        try await waitUntil { model.activeID == nil }
        XCTAssertTrue(model.selection.isEmpty, "A final empty selection still clears the editor")
        XCTAssertFalse(model.loadingPhoto)
    }

    @MainActor func testPresetSearchKeepsItsVerticalPositionAcrossEmptyResults() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder)
        model.choose([], active: nil); model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit && model.previewCurrent }
        let recipe = try XCTUnwrap(model.recipe), historyCount = model.editHistory.count
        XCTAssertTrue(model.savePreset(name: "Window light", source: recipe, options: RecipePasteOptions()))
        let suite = "preset-empty-layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); model.choose([], active: nil) }
        for key in ["showLeftPanel", "showRightPanel", "showFilmstrip", "workspacePresetsOpen"] { preferences.set(true, forKey: key) }
        func fields(_ root: NSView) -> [NSTextField] { (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields) }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for width in [200.0, 280] {
                preferences.set(width, forKey: "workspaceLeftWidth")
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                defer { window.orderOut(nil); window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                let field = try XCTUnwrap(fields(host).first { $0.placeholderString == L10n.text("app.searchPresets", defaultValue: "Search Presets") })
                let original = field.convert(field.bounds, to: host)
                window.makeFirstResponder(field); field.selectText(nil)
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                for query in ["No matching preset", ""] {
                    editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(field.stringValue, query)
                    let frame = field.convert(field.bounds, to: host)
                    XCTAssertEqual(frame.minY, original.minY, accuracy: 1, "Filtering must not move the search toolbar at \(width) pt")
                    XCTAssertEqual(frame.height, original.height, accuracy: 1)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                    attachment.name = "preset-\(query.isEmpty ? "restored" : "empty")-\(Int(width))-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
                }
                window.makeFirstResponder(nil)
                XCTAssertEqual(model.recipe, recipe); XCTAssertEqual(model.editHistory.count, historyCount)
                XCTAssertEqual(model.activeID, "000"); XCTAssertEqual(model.selection, ["000"])
                XCTAssertEqual(try model.catalog?.presets().count, 1)
            }
        }
    }

    @MainActor func testNarrowInspectorAndLocalPanelLayouts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder)
        model.choose([], active: nil); model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit && model.previewCurrent }
        let suite = "narrow-panel-labels-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); model.choose([], active: nil) }
        for key in ["showLeftPanel", "showRightPanel", "showFilmstrip", "developBasicOpen", "developVignetteOpen"] { preferences.set(true, forKey: key) }
        for key in ["developSoloMode", "developShowOnlyModified"] { preferences.set(false, forKey: key) }
        func sliders(_ root: NSView) -> [AdjustmentNSSlider] {
            (root as? AdjustmentNSSlider).map { [$0] } ?? root.subviews.flatMap(sliders)
        }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for width in [304.0, 336, 400] {
                preferences.set(width, forKey: "workspaceRightWidth")
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                try await waitUntil { sliders(host).count >= 18 }
                let edge = 1280 - Metrics.rim - 1 - width
                for slider in sliders(host) {
                    let frame = slider.convert(slider.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(frame.minX, edge)
                    XCTAssertLessThanOrEqual(frame.maxX, 1280 - Metrics.rim)
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "narrow-workspace-\(Int(width))-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
                window.contentView = nil
            }
        }
        let group = LocalAdjustment(name: "Window highlights and background color refinement", components: [MaskComponent(tool: .linear), MaskComponent(tool: .brush), MaskComponent(tool: .luminance)], exposure: 0.25)
        model.recipe?.localAdjustments = [group]; model.selectedMaskID = group.id; model.selectedComponentID = group.components.first?.id
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for component in group.components {
                model.selectedComponentID = component.id
                let host = NSHostingView(rootView: MaskPanel(model: model).defaultAppStorage(preferences).preferredColorScheme(theme.colorScheme))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 304, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                window.contentView = host; host.layoutSubtreeIfNeeded()
                try await waitUntil { sliders(host).count >= 13 }
                for slider in sliders(host) {
                    let frame = slider.convert(slider.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, 304)
                }
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "local-inspector-\(component.tool.rawValue)-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
                window.contentView = nil
            }
        }
    }

    @MainActor func testAdjustmentErrorsPreserveDraftCancelAndClearOnPhotoSwitch() throws {
        final class Input: ObservableObject {
            @Published var value = 0.0
            @Published var photoID = "first"
            var commits = 0
        }
        struct InputView: View {
            @ObservedObject var input: Input
            var body: some View {
                AdjustmentRow(label: "Exposure", value: input.value, range: -5...5, step: 0.05, digits: 2,
                    change: { value, _ in input.value = value }, commit: { input.commits += 1 })
                    .environment(\.adjustmentPhotoID, input.photoID).padding(20)
            }
        }
        let input = Input(), host = NSHostingView(rootView: InputView(input: Input()))
        host.rootView = InputView(input: input)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 336, height: 145), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        func fields(_ root: NSView) -> [NSTextField] { (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields) }
        let field = try XCTUnwrap(fields(host).first { $0.isEditable })
        let validHeight = host.fittingSize.height
        func pump() {
            let deadline = Date().addingTimeInterval(0.08)
            while Date() < deadline { RunLoop.current.run(mode: .default, before: deadline) }
        }
        pump()
        let fieldPoint = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: host.superview)
        let readout = try XCTUnwrap(host.hitTest(fieldPoint) as? ParameterReadoutView)
        let clickPoint = readout.convert(CGPoint(x: readout.bounds.midX, y: readout.bounds.midY), to: nil)
        readout.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)))
        pump()
        XCTAssertNotNil(field.currentEditor(), "Clicking the resting readout must focus the original native editor")
        window.makeFirstResponder(nil); pump()
        func enter(_ text: String) throws -> NSTextView {
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field); field.selectText(nil)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            pump()
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            pump(); editor.insertNewline(nil); pump()
            return editor
        }
        for text in ["oops", "NaN", "6", "0+1"] {
            _ = try enter(text)
            XCTAssertEqual(input.value, 0); XCTAssertEqual(input.commits, 0)
            XCTAssertEqual(field.stringValue, text)
            XCTAssertGreaterThan(host.fittingSize.height, validHeight, "The error must occupy a visible line below the field")
            window.makeFirstResponder(nil)
            pump()
            XCTAssertEqual(field.stringValue, text, "Blur must preserve the invalid draft for correction")
        }
        let editor = try enter("oops")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        pump(); XCTAssertEqual(field.stringValue, "0.00")
        XCTAssertEqual(input.commits, 0)
        _ = try enter("bad draft")
        input.photoID = "second"; input.value = 2
        pump(); XCTAssertEqual(field.stringValue, "+2.00")
        window.makeFirstResponder(nil)
        XCTAssertEqual(input.value, 2); XCTAssertEqual(input.commits, 0)
        _ = try enter("−1,25")
        pump(); XCTAssertEqual(input.value, -1.25)
        XCTAssertEqual(input.commits, 1)
    }

    @MainActor func testLuminanceRangeInputsValidateBeforeSavingAndDiscardOtherComponentDrafts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder)
        model.choose([], active: nil); model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit && model.previewCurrent }
        model.maskReference = try bitmap().image
        let first = MaskComponent(tool: .luminance), second = MaskComponent(tool: .luminance, operation: .add)
        let group = LocalAdjustment(components: [first, second])
        model.changeRecipe { $0.localAdjustments = [group] }
        model.selectDevelopTool(.mask); model.selectMask(group.id, component: first.id)
        model.undo.removeAllActions()
        let history = model.editHistory.count
        let host = NSHostingView(rootView: MaskPanel(model: model).environment(\.adjustmentPhotoID, model.activeID))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 304, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil; model.choose([], active: nil) }
        func pump() {
            let end = Date().addingTimeInterval(0.08)
            while Date() < end { RunLoop.current.run(mode: .default, before: end) }
        }
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        func field(_ label: String) throws -> NSTextField {
            try XCTUnwrap(fields(host).first { $0.placeholderString == label })
        }
        func type(_ text: String, into field: NSTextField) throws -> NSTextView {
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field); field.selectText(nil); pump()
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count)); pump()
            return editor
        }
        host.layoutSubtreeIfNeeded(); pump()
        let minimumLabel = L10n.text("app.minimumLuminance", defaultValue: "Minimum Luminance")
        let maximumLabel = L10n.text("app.maximumLuminance", defaultValue: "Maximum Luminance")
        let lower = try field(minimumLabel)
        for text in ["85", "-1", "oops", "NaN", "1e309"] {
            let editor = try type(text, into: lower)
            XCTAssertEqual(model.selectedMaskComponent?.lower, 0.25, "Typing must not save intermediate digits")
            editor.insertNewline(nil); pump()
            XCTAssertEqual(model.selectedMaskComponent?.lower, 0.25)
            XCTAssertEqual(lower.stringValue, text, "Invalid drafts must remain available to correct")
            window.makeFirstResponder(nil); pump()
            XCTAssertEqual(lower.stringValue, text)
            XCTAssertEqual(model.editHistory.count, history); XCTAssertFalse(model.undo.canUndo)
        }
        let cancelled = try type("85", into: lower)
        cancelled.doCommand(by: #selector(NSResponder.cancelOperation(_:))); pump()
        XCTAssertEqual(lower.stringValue, "25"); XCTAssertEqual(model.editHistory.count, history)
        let valid = try type("30", into: lower)
        valid.insertNewline(nil); pump()
        XCTAssertEqual(model.selectedMaskComponent?.lower, 0.3)
        XCTAssertEqual(model.editHistory.count, history + 1)
        window.makeFirstResponder(nil); pump()
        XCTAssertEqual(model.editHistory.count, history + 1, "Blur after Return must not save twice")
        model.undo.undo(); pump()
        XCTAssertEqual(model.selectedMaskComponent?.lower, 0.25)
        let upper = try field(maximumLabel)
        let crossed = try type("20", into: upper)
        crossed.insertNewline(nil); pump()
        XCTAssertEqual(model.selectedMaskComponent?.upper, 0.75); XCTAssertEqual(upper.stringValue, "20")
        crossed.doCommand(by: #selector(NSResponder.cancelOperation(_:))); pump()
        let beforeSelection = model.editHistory.count
        _ = try type("35", into: lower)
        model.selectMask(group.id, component: second.id); pump()
        XCTAssertEqual(model.selectedMaskComponent?.lower, 0.25)
        XCTAssertEqual(model.recipe?.localAdjustments.first?.components.first?.lower, 0.25)
        XCTAssertEqual(model.editHistory.count, beforeSelection, "A retiring editor cannot apply its draft to another component")
        XCTAssertEqual(try field(minimumLabel).stringValue, "25")
    }

    @MainActor func testWrappingKeyRowsFitInspectorWidthsWithoutShrinkingLabels() throws {
        let languages = [["Three-Way", "Shadows", "Midtones", "Highlights", "Global"], ["三向", "阴影", "中间调", "高光", "全局"], ["Hue", "Saturation", "Luminance", "All"], ["Luminance", "Red", "Green", "Blue"]]
        for (language, titles) in languages.enumerated() {
            for theme in [ChromeTheme.ivory, .graphite] {
                for width in [304.0, 336, 400] {
                    let options = titles.enumerated().map { KeyOption($0.offset, $0.element) }
                    let controller = NSHostingController(rootView: KeyRow(title: "Wheel", options: options,
                        selection: .constant(0), expand: true, wrappingColumns: titles.count == 4 ? 2 : 3)
                        .padding(Metrics.padding).preferredColorScheme(theme.colorScheme))
                    let size = controller.sizeThatFits(in: CGSize(width: width, height: 1000))
                    XCTAssertLessThanOrEqual(size.width, width + 1)
                    let oneRow = Metrics.key + Metrics.lampDrop + 2 * Metrics.padding
                    XCTAssertLessThanOrEqual(size.height, oneRow + Metrics.key + Metrics.lampDrop + Metrics.gap + 1)
                    if language == 0 && width < 400 {
                        XCTAssertGreaterThanOrEqual(size.height, oneRow + Metrics.key + Metrics.lampDrop + Metrics.gap - 1,
                            "English names need a second row rather than truncation at \(width) pt")
                    } else if language != 0 {
                        XCTAssertLessThanOrEqual(size.height, oneRow + 1, "Short labels retain the existing single row")
                    }
                    let host = controller.view
                    host.frame = CGRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                    attachment.name = "wheel-keys-\(language)-\(Int(width))-\(theme.rawValue)"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
    }

    @MainActor func testAdjustmentValuesAlignWithAndWithoutUnitsAtInspectorWidths() async throws {
        func fields(_ root: NSView) -> [NSTextField] {
            (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields)
        }
        for width in [Metrics.rightPanel.range.lowerBound, Metrics.rightPanel.initial, Metrics.rightPanel.range.upperBound] {
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                AdjustmentRow(label: "色温", value: 5500, range: 2000...50000, unit: "K", change: { _, _ in }, commit: {})
                AdjustmentRow(label: "曝光度", value: 0, range: -5...5, digits: 2, unit: "EV", change: { _, _ in }, commit: {})
                AdjustmentRow(label: "饱和度", value: 100, change: { _, _ in }, commit: {})
            }.padding(.horizontal, Metrics.padding))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            try await waitUntil { fields(host).filter(\.isEditable).count == 3 }
            host.layoutSubtreeIfNeeded()
            let editors = fields(host).filter(\.isEditable)
            XCTAssertEqual(Set(editors.map(\.stringValue)), ["5500", "0.00", "+100"])
            let frames = editors.map { $0.convert($0.bounds, to: host) }
            for frame in frames {
                XCTAssertEqual(frame.maxX, frames[0].maxX, accuracy: 0.5, "Units keep their own lane at \(width) pt")
                XCTAssertEqual(frame.width, frames[0].width, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(frame.width, 42)
            }
        }
    }

    @MainActor func testAdjustmentReturnEndsEditingAndDoesNotReapplyAnUndoneValue() async throws {
        final class Input: ObservableObject {
            @Published var value = 0.0
            var commits = 0
        }
        struct InputView: View {
            @ObservedObject var input: Input
            var body: some View {
                AdjustmentRow(label: "曝光度", value: input.value, range: -5...5, step: 0.05, digits: 2,
                    change: { value, _ in input.value = value }, commit: { input.commits += 1 }).padding(20)
            }
        }
        let input = Input(), host = NSHostingView(rootView: InputView(input: Input()))
        host.rootView = InputView(input: input)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        func fields(_ root: NSView) -> [NSTextField] { (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(fields) }
        let field = try XCTUnwrap(fields(host).first { $0.isEditable })
        window.makeFirstResponder(field); field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        try await Task.sleep(for: .milliseconds(60)) // Let SwiftUI observe native focus before submitting.
        editor.insertText("1.00", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(30))
        editor.insertNewline(nil)
        try await waitUntil { input.value == 1 && window.firstResponder !== editor }
        let commitsAfterReturn = input.commits
        XCTAssertGreaterThan(commitsAfterReturn, 0)
        input.value = 0 // An external undo after Return must not resurrect the old field editor text.
        try await waitUntil { field.stringValue == "0.00" }
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(input.value, 0); XCTAssertEqual(input.commits, commitsAfterReturn)
    }

    @MainActor func testImportRoundTripRestoresTheOriginalDevelopReferenceAndActivePhoto() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder)
        defer { model.endDevelopReference(); model.choose([], active: nil) }
        model.choose([], active: nil); model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit }
        model.toggleDevelopReference()
        try await waitUntil { model.canEdit && model.developReference?.image != nil }
        XCTAssertEqual(model.activeID, "001"); XCTAssertEqual(model.developReference?.photo?.id, "000")
        try model.completeImport(ids: ["002"], cancelled: false)
        model.showLastImport(startCulling: true)
        XCTAssertNil(model.developReference)
        model.selectWorkspace(.develop); try await waitUntil { model.canEdit }
        model.pinActiveAsDevelopReference()
        XCTAssertEqual(model.developReference?.photo?.id, "002")
        model.returnFromImport()
        try await waitUntil { model.canEdit && model.developReference?.image != nil }
        XCTAssertEqual(model.activeID, "001"); XCTAssertEqual(model.selection, ["001"])
        XCTAssertEqual(model.developReference?.photo?.id, "000")
        XCTAssertTrue(model.editMode); XCTAssertFalse(model.isViewingImport)
    }

    @MainActor func testDevelopReferenceFreezesTheLookAcrossEditsPagesFiltersAndUnavailableSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = try bitmap()
        let model = try model(in: folder, count: 203, renderer: { request, _, _ in
            guard request.photo.availability == "available" else { throw LRCError("参考来源离线") }
            return pixels
        })
        let catalog = try XCTUnwrap(model.catalog)
        model.choose([], active: nil); model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit }
        model.toggleDevelopReference()
        let reference = try XCTUnwrap(model.developReference)
        defer { model.endDevelopReference(); model.choose([], active: nil) }
        try await waitUntil { reference.image != nil && model.canEdit }
        let frozenPixels = reference.image
        XCTAssertEqual(reference.photo?.id, "000"); XCTAssertEqual(model.activeID, "001")
        XCTAssertNil(model.comparison)
        model.changeRecipe { $0.exposure = 1 }
        XCTAssertTrue(reference.image === frozenPixels)
        let frozen = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(reference.photo?.recipe))
        XCTAssertEqual(frozen.exposure, 0)
        model.selectDevelopReferenceZoom(2)
        XCTAssertEqual(reference.zoom, 2); XCTAssertFalse(model.fullResolution)
        model.selectZoom(1)
        XCTAssertEqual(reference.zoom, 2, "Active and reference zoom are independent")
        model.changePage(1); XCTAssertEqual(model.activeID, "200"); model.move(1)
        XCTAssertEqual(model.activeID, "201"); XCTAssertEqual(reference.photo?.id, "000")
        model.search = "no match"; model.filterChanged()
        XCTAssertNil(model.activeID); XCTAssertNotNil(model.developReference)
        model.clearFilters(); model.filterChanged()
        try await waitUntil { model.canEdit }
        XCTAssertEqual(model.activeID, "000")
        model.changeRecipe { $0.exposure = 2 }
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(reference.photo?.recipe)).exposure, 0,
                       "Even editing that version later must not change the frozen reference look")
        model.showBeforeAfter(.sideBySide)
        XCTAssertNil(model.developReference); XCTAssertNil(reference.image)
        model.toggleDevelopReference()
        let reopened = try XCTUnwrap(model.developReference)
        XCTAssertEqual(model.beforeAfter, .off); XCTAssertEqual(reopened.photo?.id, "000")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(reopened.photo?.recipe)).exposure, 0)
        model.selectWorkspace(.single); XCTAssertNil(model.developReference)
        model.selectWorkspace(.develop); model.toggleDevelopReference()
        let restored = try XCTUnwrap(model.developReference)
        try await waitUntil { restored.image != nil }
        try await catalog.database.write { try $0.execute(sql: "UPDATE photo SET availability='missing' WHERE id='000'") }
        try model.reloadPhotos()
        try await waitUntil { restored.image == nil && restored.status == "参考来源离线" }
        try await catalog.database.write { try $0.execute(sql: "UPDATE photo SET availability='available' WHERE id='000'") }
        try model.reloadPhotos(); try await waitUntil { restored.image != nil }
        try await catalog.database.write { try $0.execute(sql: "UPDATE photo SET deleted=1 WHERE id='000'") }
        try model.reloadPhotos()
        XCTAssertNil(restored.image); XCTAssertEqual(restored.status, "参考照片已从图库移除")
        try model.activateCatalog(CatalogStore(directory: folder.appendingPathComponent("next")))
        XCTAssertNil(model.developReference); XCTAssertFalse(model.canShowDevelopReference)
    }

    @MainActor func testDevelopReferenceLayoutsKeyboardAndToolsStayOnTheActiveCanvas() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let landscape = try bitmap()
        let rect = CGRect(x: 0, y: 0, width: 40, height: 80)
        let cg = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .blue).cropped(to: rect), from: rect))
        let portrait = RenderedImage(image: cg, fullSize: CGSize(width: 2000, height: 4000), orientedSourceSize: CGSize(width: 2000, height: 4000), histogram: nil, elapsed: 0)
        let model = try model(in: folder, renderer: { request, _, _ in request.photo.id == "001" ? portrait : landscape })
        model.choose([], active: nil); model.choose(["000"], active: "000"); model.selectWorkspace(.develop); try await waitUntil { model.canEdit }
        let suite = "develop-reference-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); model.endDevelopReference(); model.choose([], active: nil) }
        preferences.set(true, forKey: "showLeftPanel"); preferences.set(true, forKey: "showRightPanel")
        func canvases(_ root: NSView) -> [PhotoMetalCanvas] { (root as? PhotoMetalCanvas).map { [$0] } ?? root.subviews.flatMap(canvases) }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for size in [CGSize(width: 1440, height: 900), CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 640)] {
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.title = "Develop reference — Phosdeck"; window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                let container = NSView(frame: CGRect(origin: .zero, size: size))
                host.frame = container.bounds; container.addSubview(host); window.contentView = container
                model.toggleDevelopReference()
                try await waitUntil { model.developReference?.image != nil && model.canEdit && canvases(host).count == 2 }
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
                let views = canvases(host)
                XCTAssertEqual(views[0].accessibilityLabel(), "参考图画布")
                XCTAssertEqual(views[1].accessibilityLabel(), "照片画布")
                XCTAssertTrue(views.allSatisfy { $0.frame.width > 150 && $0.frame.height > 150 })
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "develop-reference-\(Int(size.width))-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
                func key(_ text: String, modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 0) throws -> NSEvent? {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
                    return WorkspaceKeyboard.handle(event, model: model)
                }
                XCTAssertNil(try key("r")); XCTAssertTrue(model.cropMode); XCTAssertNotNil(model.developReference)
                XCTAssertNil(try key("", code: 53)); XCTAssertFalse(model.cropMode); XCTAssertNotNil(model.developReference)
                XCTAssertNil(try key("", code: 53)); XCTAssertNil(model.developReference)
                XCTAssertNil(try key("r", modifiers: .shift)); XCTAssertNotNil(model.developReference)
                let editor = NSTextView(); window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
                XCTAssertNotNil(try key("r", modifiers: .shift)); XCTAssertNotNil(model.developReference)
                window.makeFirstResponder(nil); editor.removeFromSuperview()
                model.endDevelopReference(); window.contentView = nil
            }
        }
    }

    @MainActor func testPinnedReferenceAcrossPagesFiltersRatingsAndModeChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder, count: 203), catalog = try XCTUnwrap(model.catalog)
        model.selection = ["000", "201"]; model.beginComparison()
        let comparison = try XCTUnwrap(model.comparison)
        defer { comparison.cancel() }
        try await waitUntil { comparison.reference.image != nil && comparison.candidate.image != nil }
        let referenceImage = comparison.reference.image
        XCTAssertEqual(comparison.reference.photo?.id, "000"); XCTAssertEqual(model.activeID, "201")
        XCTAssertEqual(model.selection, ["201"]); XCTAssertEqual(model.pageOffset, 200)
        model.move(-1); model.move(-1)
        XCTAssertEqual(model.activeID, "199"); XCTAssertEqual(model.pageOffset, 0)
        model.choose(["000", "001"], active: "000")
        XCTAssertEqual(model.activeID, "199"); XCTAssertEqual(model.selection, ["199"])
        model.choose(["000", "001"], active: "001")
        XCTAssertEqual(model.selection, ["001"])
        model.move(-1); XCTAssertEqual(model.activeID, "001", "Do not replace the candidate with the reference")
        model.organize(rating: 5, flag: 1)
        XCTAssertEqual(try catalog.photo("001")?.rating, 5); XCTAssertEqual(try catalog.photo("000")?.rating, 0)
        XCTAssertEqual(comparison.candidate.photo?.flag, 1)
        XCTAssertTrue(comparison.reference.image === referenceImage, "Rating must not rerender the reference")
        model.undo.undo(); XCTAssertEqual(comparison.candidate.photo?.rating, 0)
        model.undo.redo(); XCTAssertEqual(comparison.candidate.photo?.rating, 5)
        model.ratingThreshold = 5; model.filterChanged()
        XCTAssertEqual(comparison.reference.photo?.id, "000"); XCTAssertEqual(model.activeID, "001")
        model.organize(rating: 0)
        XCTAssertNil(comparison.candidate.photo); XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(comparison.candidate.image)
        model.ratingThreshold = 0; model.filterChanged()
        XCTAssertEqual(model.activeID, "001", "Skip the reference when choosing a replacement after filtering")
        model.swapComparison()
        XCTAssertEqual(comparison.reference.photo?.id, "001"); XCTAssertEqual(model.activeID, "000")
        model.move(1); XCTAssertEqual(model.activeID, "002")
        model.editMode = true
        XCTAssertNil(model.comparison); XCTAssertNil(comparison.reference.image); XCTAssertNil(comparison.candidate.image)
        try await waitUntil { model.image != nil }
        XCTAssertEqual(model.activeID, "002")
        model.beginComparison(); XCTAssertNotNil(model.comparison)
        model.singleView = false; XCTAssertNil(model.comparison)
        model.search = "000.jpg"; model.filterChanged(); model.beginComparison()
        XCTAssertNil(model.comparison); XCTAssertNotNil(model.error)
        model.search = ""; model.filterChanged(); model.beginComparison()
        let previous = try XCTUnwrap(model.comparison)
        try model.activateCatalog(CatalogStore(directory: folder.appendingPathComponent("next")))
        XCTAssertNil(model.comparison); XCTAssertNil(previous.reference.image); XCTAssertNil(previous.candidate.image)
    }

    @MainActor func testLatestRenderWinsAndErrorsClearOldPixels() async throws {
        let first = try bitmap(11), second = try bitmap(22)
        var calls: [(String, Int?, CheckedContinuation<RenderedImage, Error>)] = []
        let comparison = PhotoComparison { request, edge in
            try await withCheckedThrowingContinuation { calls.append((request.photo.id, edge, $0)) }
        }
        let root = StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")
        func photo(_ id: String) -> Photo { Photo(id: id, rootID: "r", relativePath: id + ".jpg", identity: Data(), identityKey: id, width: 4000, height: 3000) }
        let pane = comparison.candidate
        comparison.update(pane, photo: photo("a"), roots: [root])
        try await waitUntil { calls.count == 1 }
        comparison.update(pane, photo: photo("b"), roots: [root])
        try await waitUntil { calls.count == 2 }
        calls[1].2.resume(returning: second)
        try await waitUntil { pane.image != nil }
        calls[0].2.resume(returning: first)
        await Task.yield()
        XCTAssertEqual(pane.image?.width, 22)
        comparison.selectZoom(1, in: pane)
        try await waitUntil { calls.count == 3 }
        XCTAssertNil(calls[2].1); XCTAssertNotNil(pane.image, "Fit pixels remain while original size is loading")
        calls[2].2.resume(throwing: LRCError("来源离线"))
        try await waitUntil { pane.status == "来源离线" }
        XCTAssertNil(pane.image)
        comparison.selectZoom(nil, in: pane)
        try await waitUntil { calls.count == 4 }
        XCTAssertEqual(calls[3].1, 2400)
        comparison.cancel(); calls[3].2.resume(returning: first)
        await Task.yield(); XCTAssertNil(pane.image)
        var corrupt = photo("bad"); corrupt.recipe = Data("broken".utf8)
        comparison.update(pane, photo: corrupt, roots: [root])
        try await waitUntil { !pane.status.contains("正在读取") }
        XCTAssertEqual(calls.count, 4); XCTAssertNil(pane.image)
        comparison.cancel()
    }

    @MainActor func testLinkedCanvasPanAndIndependentGeometry() async throws {
        let rendered = try bitmap()
        let comparison = PhotoComparison { _, _ in rendered }
        let left = comparison.reference, right = comparison.candidate
        comparison.selectZoom(2, in: right, focus: CGPoint(x: 0.7, y: 0.3))
        XCTAssertEqual(left.zoom, 2); XCTAssertEqual(right.zoom, 2)
        let canvasSize = CGSize(width: 1000, height: 1200)
        left.viewport.update(image: CGSize(width: 8000, height: 12000), canvas: canvasSize, zoomed: true)
        right.viewport.update(image: CGSize(width: 12000, height: 8000), canvas: canvasSize, zoomed: true)
        XCTAssertEqual(left.viewport.center, right.viewport.center)
        let canvas = PhotoMetalCanvas()
        canvas.source = rendered.image; canvas.nativeSize = CGSize(width: 4000, height: 6000)
        canvas.viewport = left.viewport; canvas.displayCenter = left.viewport.center
        canvas.actualPixels = true; canvas.zoomScale = 2
        canvas.onPan = { comparison.pan(from: left, to: $0) }
        canvas.panBy(CGSize(width: 400, height: -600), backingScale: 2)
        XCTAssertEqual(left.viewport.center.x, 0.6, accuracy: 0.00001)
        XCTAssertEqual(left.viewport.center.y, 0.4, accuracy: 0.00001)
        XCTAssertEqual(right.viewport.center, left.viewport.center)
        let leftCenter = left.viewport.center
        right.viewport.update(image: CGSize(width: 600, height: 8000), canvas: canvasSize, zoomed: true)
        XCTAssertEqual(right.viewport.center.x, 0.5)
        XCTAssertEqual(left.viewport.center, leftCenter, "Geometry must not bounce back to the other pane")
        comparison.setLinked(false)
        comparison.selectZoom(4, in: right)
        canvas.panBy(CGSize(width: 200, height: 300), backingScale: 2)
        XCTAssertEqual(left.zoom, 2); XCTAssertEqual(right.zoom, 4)
        XCTAssertEqual(right.viewport.center.x, 0.5)
        comparison.setLinked(true); XCTAssertEqual(left.zoom, 4)
        comparison.selectZoom(nil, in: right)
        XCTAssertNil(left.zoom); XCTAssertNil(right.zoom)
        XCTAssertEqual(left.viewport.center, CGPoint(x: 0.5, y: 0.5))
        comparison.cancel()
    }

    @MainActor func testNativeComparisonLayoutAndKeyboard() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder)
        let suite = "comparison-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "showLeftPanel")
        preferences.set(true, forKey: "showRightPanel")
        let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Comparison test — Phosdeck"; window.contentView = host
        defer { model.endComparison(); window.contentView = nil }
        func key(_ text: String, code: UInt16 = 0) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            XCTAssertNil(WorkspaceKeyboard.handle(event, model: model))
        }
        try key("c")
        let comparison = try XCTUnwrap(model.comparison)
        try await waitUntil { comparison.reference.image != nil && comparison.candidate.image != nil }
        func canvases(_ view: NSView) -> [PhotoMetalCanvas] { (view as? PhotoMetalCanvas).map { [$0] } ?? view.subviews.flatMap(canvases) }
        try await waitUntil { canvases(host).count == 2 }
        host.layoutSubtreeIfNeeded()
        let views = canvases(host)
        XCTAssertEqual(Set(views.compactMap(\.photoID)), ["000", "001"])
        XCTAssertTrue(views.allSatisfy { $0.frame.width > 200 && $0.frame.height > 200 && $0.source != nil }, "\(views.map(\.frame))")
        XCTAssertEqual(views[0].frame.width, views[1].frame.width, accuracy: 1)
        let canvasRight = views.map { $0.convert($0.bounds, to: host).maxX }.max() ?? 0
        XCTAssertLessThanOrEqual(canvasRight, host.bounds.width - Metrics.rightPanel.range.lowerBound, "Inspector stays open during comparison")
        XCTAssertEqual(views[0].accessibilityLabel(), "参考图画布")
        XCTAssertEqual(views[1].accessibilityLabel(), "候选图画布")
        try key("z"); XCTAssertEqual(comparison.reference.zoom, 1); XCTAssertEqual(comparison.candidate.zoom, 1)
        try key("", code: 124); XCTAssertEqual(model.activeID, "002")
        try key("5"); XCTAssertEqual(comparison.candidate.photo?.rating, 5)
        try key("p"); XCTAssertEqual(comparison.candidate.photo?.flag, 1)
        XCTAssertEqual(comparison.reference.photo?.rating, 0)
        try await waitUntil { comparison.candidate.image != nil }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "comparison-1000x640"; attachment.lifetime = .keepAlways; add(attachment)
        for panel in ["showLeftPanel", "showRightPanel", "showFilmstrip"] { preferences.set(false, forKey: panel) }
        // Each seam contains two physical pixels. A locked/offscreen window can
        // have scale 1 even when the normal desktop uses a Retina display.
        let seamWidth = 2 / max(1, window.backingScaleFactor)
        let collapsedWidth = host.bounds.width - 2 * Metrics.rim - 3 * seamWidth
        try await waitUntil {
            let views = canvases(host)
            return views.count == 2 && abs(views.map(\.frame.width).reduce(0, +) - collapsedWidth) <= 1
        }
        host.layoutSubtreeIfNeeded()
        let collapsed = canvases(host)
        XCTAssertEqual(collapsed.map(\.frame.width).reduce(0, +), collapsedWidth, accuracy: 1,
                       "With every panel collapsed the canvases take all but the chassis rim")
        print("COMPARISON_LAYOUT scale=\(window.backingScaleFactor) seam=\(seamWidth) canvas=\(collapsed.map(\.frame.width).reduce(0, +)) expected=\(collapsedWidth)")
        let collapsedBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: collapsedBitmap)
        let collapsedAttachment = XCTAttachment(data: try XCTUnwrap(collapsedBitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        collapsedAttachment.name = "comparison-collapsed-1000x640"; collapsedAttachment.lifetime = .keepAlways; add(collapsedAttachment)
        try key("", code: 53); XCTAssertNil(model.comparison)
        try key("c"); try key("e"); XCTAssertNil(model.comparison); XCTAssertTrue(model.singleView)
        try key("c"); try key("g"); XCTAssertNil(model.comparison); XCTAssertFalse(model.singleView)
    }

    @MainActor func testPublicRAWComparisonUsesSavedEditsAndOriginalPixels() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let sample = support.appendingPathComponent("OhMyLRC/FeatureValidation/public.ARW")
        guard FileManager.default.fileExists(atPath: sample.path) else { throw XCTSkip("Public RAW fixture not prepared") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        let source = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.addRoot(url: source, bookmark: AccessLease.bookmark(source, readOnly: true))
        for name in ["a.ARW", "b.ARW"] {
            let url = source.appendingPathComponent(name)
            try FileManager.default.copyItem(at: sample, to: url)
            try catalog.index(ReferenceImporter.inspect(url: url, root: root, rootURL: source))
        }
        let photos = try catalog.photos()
        let model = AppModel(); model.catalog = catalog; try model.reload()
        model.activePhoto = photos[0]; model.activeID = photos[0].id; model.selection = [photos[0].id]
        var edited = try await model.pipeline.baseline(ImageRequest(photo: photos[0], root: root, recipe: nil))
        edited.exposure = 0.7; edited.crop.width = 0.5; edited.quarterTurns = 1
        model.recipe = edited; model.dirty = true; model.canEdit = true; model.editMode = true
        defer { model.comparison?.cancel(); model.comparison = nil }
        model.beginComparison()
        let comparison = try XCTUnwrap(model.comparison)
        try await waitUntil { comparison.reference.image != nil && comparison.candidate.image != nil }
        XCTAssertNil(model.error); XCTAssertFalse(model.dirty)
        let saved = try XCTUnwrap(catalog.photo(photos[0].id)?.recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: saved), edited, "Commit pending edits before pinning")
        XCTAssertNil(try catalog.photo(photos[1].id)?.recipe, "Comparing an unedited RAW does not write a recipe")
        let expected = try await model.pipeline.render(ImageRequest(photo: photos[0], root: root, recipe: edited), longEdge: 2400)
        let actual = try XCTUnwrap(comparison.reference.image)
        func pixels(_ image: CGImage) -> Data {
            var values = [UInt8](repeating: 0, count: image.width * image.height * 4)
            CIContext().render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 4,
                               bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
            return Data(values)
        }
        XCTAssertEqual(actual.width, expected.image.width); XCTAssertEqual(actual.height, expected.image.height)
        XCTAssertEqual(pixels(actual), pixels(expected.image))
        comparison.selectZoom(1, in: comparison.candidate)
        try await waitUntil { comparison.reference.status.isEmpty && comparison.candidate.status.isEmpty }
        for pane in [comparison.reference, comparison.candidate] {
            XCTAssertEqual(pane.image?.width, Int(try XCTUnwrap(pane.nativeSize).width))
            XCTAssertEqual(pane.image?.height, Int(try XCTUnwrap(pane.nativeSize).height))
        }
        let pinned = comparison.reference.image
        comparison.setLinked(false)
        try Data("changed fixture".utf8).write(to: source.appendingPathComponent("b.ARW"))
        comparison.selectZoom(nil, in: comparison.candidate)
        try await waitUntil { comparison.candidate.status.contains("来源") }
        XCTAssertNil(comparison.candidate.image); XCTAssertTrue(comparison.reference.image === pinned)
    }

    @MainActor func testCullKeysAdvanceStepRatingsAndAnnounce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder), catalog = try XCTUnwrap(model.catalog)
        // Undo first: without a run loop every later registration would join the same undo group.
        try catalog.setRatings(["000": 1]); try model.reload()
        model.choose(["000", "001"], active: "000")
        model.stepRating(1)
        XCTAssertEqual(try catalog.photo("000")?.rating, 2); XCTAssertEqual(try catalog.photo("001")?.rating, 1)
        XCTAssertEqual(model.notice?.text, "评级 +1 · 2 张")
        model.undo.undo()
        XCTAssertEqual(try catalog.photo("000")?.rating, 1); XCTAssertEqual(try catalog.photo("001")?.rating, 0)
        try catalog.setRatings(["000": 0]); try model.reload()
        model.choose(["000"], active: "000"); model.singleView = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Phosdeck"
        func key(_ text: String, code: UInt16 = 0, shift: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        XCTAssertNil(WorkspaceKeyboard.handle(try key("!", code: 18, shift: true), model: model), "Shift+1 arrives as a symbol")
        XCTAssertEqual(try catalog.photo("000")?.rating, 1); XCTAssertEqual(model.activeID, "001")
        XCTAssertEqual(model.notice?.text, "★ 1 星")
        XCTAssertNil(WorkspaceKeyboard.handle(try key("]", code: 30), model: model))
        XCTAssertNil(WorkspaceKeyboard.handle(try key("]", code: 30), model: model))
        XCTAssertEqual(try catalog.photo("001")?.rating, 2); XCTAssertEqual(model.activeID, "001")
        XCTAssertEqual(model.notice?.text, "★★ 2 星")
        for _ in 0..<3 { XCTAssertNil(WorkspaceKeyboard.handle(try key("[", code: 33), model: model)) }
        XCTAssertEqual(try catalog.photo("001")?.rating, 0, "Stepping stops at zero")
        XCTAssertNil(WorkspaceKeyboard.handle(try key("P", code: 35, shift: true), model: model))
        XCTAssertEqual(try catalog.photo("001")?.flag, 1); XCTAssertEqual(model.activeID, "002")
        XCTAssertEqual(model.notice?.text, "选取")
        XCTAssertTrue(WorkspaceKeyboard.cull(try key("{", code: 33, shift: true), model: model))
        XCTAssertEqual(model.activeID, "002", "No next photo after the last one")
        model.choose(["000", "001", "002"], active: "000"); model.organize(rating: 1)
        model.ratingThreshold = 1; model.filterChanged()
        model.choose(["000"], active: "000")
        XCTAssertNil(WorkspaceKeyboard.handle(try key(")", code: 29, shift: true), model: model))
        XCTAssertEqual(model.activeID, "001", "The filter already moved on; Shift must not skip a second photo")
        XCTAssertFalse(WorkspaceKeyboard.cull(try key("q", code: 12), model: model))
        withExtendedLifetime(window) {}
    }

    @MainActor func testBeforeAfterRendersAlignedBaselineAndLeavesWithModes() async throws {
        final class Requests: @unchecked Sendable {
            private let lock = NSLock(); private var values: [EditRecipe?] = []
            func append(_ recipe: EditRecipe?) { lock.lock(); values.append(recipe); lock.unlock() }
            var all: [EditRecipe?] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try bitmap(), requests = Requests()
        let model = try model(in: folder, count: 2) { request, _, _ in requests.append(request.recipe); return image }
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion, baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        recipe.exposure = 1.2; recipe.crop.width = 0.5; recipe.quarterTurns = 1; recipe.straightenDegrees = 3
        model.recipe = recipe; model.canEdit = true; model.editMode = true; model.singleView = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Phosdeck"
        func key(_ text: String, code: UInt16 = 0, shift: Bool = false) throws -> NSEvent? {
            WorkspaceKeyboard.handle(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)), model: model)
        }
        XCTAssertNil(try key("Y", code: 16, shift: true)); XCTAssertEqual(model.beforeAfter, .split)
        try await waitUntil { model.beforeImage != nil }
        let aligned = try XCTUnwrap(requests.all.compactMap { $0 }.first { $0 == recipe.alignedBaseline() })
        XCTAssertEqual(aligned.exposure, recipe.baseline().exposure); XCTAssertEqual(aligned.crop, recipe.crop)
        XCTAssertEqual(aligned.quarterTurns, 1); XCTAssertEqual(aligned.straightenDegrees, 3)
        let count = requests.all.count
        model.requestPreview(interactive: true)
        XCTAssertNotNil(model.beforeImage, "Tone edits keep the cached before image")
        try await waitUntil { model.previewCurrent || model.image != nil }
        XCTAssertEqual(requests.all.filter { $0 == recipe.alignedBaseline() }.count, 1, "\(requests.all.count - count) new requests")
        XCTAssertNil(try key("y", code: 16)); XCTAssertEqual(model.beforeAfter, .sideBySide)
        XCTAssertNil(try key("y", code: 16)); XCTAssertEqual(model.beforeAfter, .off); XCTAssertNil(model.beforeImage)
        XCTAssertNil(try key("y", code: 16)); XCTAssertNil(try key("\\", code: 42))
        XCTAssertTrue(model.before); XCTAssertEqual(model.beforeAfter, .off)
        XCTAssertNil(try key("y", code: 16)); XCTAssertFalse(model.before); XCTAssertEqual(model.beforeAfter, .sideBySide)
        model.cropMode = true
        XCTAssertEqual(model.beforeAfter, .off); XCTAssertFalse(model.canShowBeforeAfter)
        model.showBeforeAfter(.split); XCTAssertEqual(model.beforeAfter, .off)
        model.cropMode = false; model.showBeforeAfter(.split); model.setMaskMode(true)
        XCTAssertEqual(model.beforeAfter, .off)
        model.setMaskMode(false); model.showBeforeAfter(.sideBySide)
        XCTAssertNil(try key("j", code: 38)); XCTAssertTrue(model.showClipping)
        model.editMode = false; model.singleView = false
        XCTAssertEqual(model.beforeAfter, .off); XCTAssertNil(model.beforeImage)
        XCTAssertNotNil(try key("j", code: 38), "The grid leaves J to the collection view")
        XCTAssertTrue(model.showClipping)
        withExtendedLifetime(window) {}
    }

    @MainActor func testBeforeAfterSideBySideShowsTwoLinkedCanvases() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder)
        let suite = "before-after-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Before after test — Phosdeck"; window.contentView = host
        defer { window.contentView = nil }
        model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion, baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        model.singleView = true; model.requestPreview()
        model.showBeforeAfter(.sideBySide)
        try await waitUntil { model.image != nil && model.beforeImage != nil }
        func canvases(_ view: NSView) -> [PhotoMetalCanvas] { (view as? PhotoMetalCanvas).map { [$0] } ?? view.subviews.flatMap(canvases) }
        try await waitUntil { canvases(host).count == 2 }
        host.layoutSubtreeIfNeeded()
        let views = canvases(host)
        XCTAssertEqual(views.map { $0.accessibilityLabel() }, ["调整前画布", "调整后画布"])
        XCTAssertTrue(views.allSatisfy { $0.source != nil && $0.frame.width > 150 })
        XCTAssertEqual(views[0].frame.width, views[1].frame.width, accuracy: 1)
        model.showClipping = true
        try await waitUntil { canvases(host).allSatisfy(\.clipping) }
        model.showBeforeAfter(.split)
        try await waitUntil { canvases(host).count == 1 && canvases(host).first?.splitSource != nil }
    }
}
