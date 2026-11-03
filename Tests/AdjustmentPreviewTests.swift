import XCTest
import CoreGraphics
import CoreImage
import SwiftUI
@testable import Phosdeck

final class AdjustmentPreviewTests: XCTestCase {
    @MainActor func testMomentaryEyeReleaseDoesNotStartAnotherPulseAndDetachingCancels() throws {
        var presses = [Bool](), pulses = 0
        let host = NSHostingView(rootView: MomentaryPreviewKey(title: "预览基本调整", systemImage: "eye", selected: false,
            height: 22, onPress: { presses.append($0) }, onPulse: { pulses += 1 }).frame(width: 50, height: 30))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let capture = try XCTUnwrap(descendants(host).first { String(describing: type(of: $0)) == "MomentaryPreviewCaptureView" })
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: capture.convert(CGPoint(x: 10, y: 10), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        capture.mouseDown(with: try event(.leftMouseDown))
        capture.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(presses, [true, false]); XCTAssertEqual(pulses, 0, "鼠标松开不能再次触发语义脉冲")
        capture.mouseDown(with: try event(.leftMouseDown))
        window.contentView = nil
        XCTAssertEqual(presses, [true, false, true, false], "移出窗口必须结束仍按住的预览")
    }

    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test",
                   baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0,
                   temperature: 5500, tint: 0)
    }

    func testGroupPreviewUsesTheRecipeBaselineAndPreservesOtherGroups() {
        var edited = recipe()
        edited.exposure = 1.25
        edited.develop.highlights = -40
        edited.vignette.amount = -35
        edited.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        edited.straightenDegrees = 4

        let basic = DevelopGroup.basic.previewRecipe(in: edited)
        XCTAssertEqual(basic.exposure, 0)
        XCTAssertEqual(basic.develop.highlights, 0)
        XCTAssertEqual(basic.vignette, edited.vignette, "预览基本调整不能顺带关闭创作暗角")
        XCTAssertEqual(basic.crop, edited.crop, "非几何组预览必须保持当前几何")
        XCTAssertEqual(basic.straightenDegrees, edited.straightenDegrees)
        XCTAssertTrue(edited.modifiedDevelopGroups.contains(.basic))
        XCTAssertTrue(edited.modifiedDevelopGroups.contains(.vignette))
        XCTAssertTrue(edited.modifiedDevelopGroups.contains(.crop))
        XCTAssertEqual(edited.exposure, 1.25, "临时预览不能修改原配方")

        let crop = DevelopGroup.crop.previewRecipe(in: edited)
        XCTAssertEqual(crop.crop, Crop(), "裁剪组使用真实中性基线，而不是把所有组归零")
        XCTAssertEqual(crop.straightenDegrees, 0)
        XCTAssertEqual(crop.vignette, edited.vignette)
        XCTAssertEqual(crop.exposure, edited.exposure)
    }

    func testUnmodifiedGroupHasNoTemporaryPreviewMarker() {
        var neutral = recipe()
        neutral.grain.ensureSeed()
        XCTAssertNotEqual(neutral.grain.seed, 0)
        XCTAssertFalse(DevelopGroup.basic.isModified(in: neutral))
        XCTAssertFalse(DevelopGroup.crop.isModified(in: neutral))
        XCTAssertEqual(DevelopGroup.grain.previewRecipe(in: neutral).grain.seed, neutral.grain.seed)
        XCTAssertTrue(neutral.modifiedDevelopGroups.isEmpty)
    }

    func testRawLensCorrectionIsARealModifiedGroupAndPreviewInput() {
        var edited = recipe()
        edited.rawDetails.lensCorrection = true
        XCTAssertTrue(DevelopGroup.rawDetails.isModified(in: edited))
        XCTAssertNil(DevelopGroup.rawDetails.previewRecipe(in: edited).rawDetails.lensCorrection)
        XCTAssertEqual(DevelopGroup.basic.previewRecipe(in: edited).rawDetails.lensCorrection, true,
                       "普通组预览保留未选中的 RAW 镜头参数")
    }

    func testPresetPreviewAppliesOnlyTheSavedGroupsToTheTarget() throws {
        var source = recipe(); source.exposure = 2; source.develop.highlights = -30
        source.develop.mixer[0].hue = 80
        var target = recipe(); target.exposure = -1; target.develop.mixer[0].hue = -20
        var options = RecipePasteOptions()
        options.whiteBalance = false; options.color = false; options.geometry = false
        options.details = false; options.generalDetails = false; options.curves = false; options.zones = false
        let preset = AdjustmentPreset(id: "preview", name: "仅明暗", recipe: try JSONEncoder().encode(source), options: try JSONEncoder().encode(options))

        let composed = try preset.previewRecipe(on: target)
        XCTAssertEqual(composed.exposure, source.exposure)
        XCTAssertEqual(composed.develop.highlights, source.develop.highlights)
        XCTAssertEqual(composed.develop.mixer, target.develop.mixer)
        XCTAssertEqual(composed.sourceDigest, target.sourceDigest)
    }

    @MainActor
    func testPresetPreviewUsesDisplayRecipeAndRestoresStateWithoutExportLeak() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let normal = try bitmap(80), presetDraft = try bitmap(42), presetQuality = try bitmap(48)
        let model = try model(in: folder, renderer: { request, interactive, _ in
            if request.recipe?.exposure == 2 {
                return interactive ? presetDraft : presetQuality
            }
            return normal
        })
        model.activeID = nil; model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit && model.previewCurrent && model.image?.width == normal.image.width }

        model.changeRecipe({ $0.exposure = 0.8 }, commit: false)
        try await waitUntil { model.dirty && model.recipe?.exposure == 0.8 }
        let draft = try XCTUnwrap(model.recipe)
        let saved = try XCTUnwrap(model.catalog?.photo("000")?.recipe)
        let history = model.editHistory.count
        var source = draft; source.exposure = 2
        var options = RecipePasteOptions()
        options.whiteBalance = false; options.color = false; options.geometry = false
        options.details = false; options.generalDetails = false; options.curves = false; options.zones = false
        let preset = AdjustmentPreset(id: "preview", name: "预览", recipe: try JSONEncoder().encode(source), options: try JSONEncoder().encode(options))

        model.previewPreset(preset)
        try await waitUntil { model.isPreviewingAdjustment && model.previewingPresetID == preset.id && model.displayPreviewRecipe?.exposure == 2 }
        try await waitUntil { model.image?.width == presetDraft.image.width || model.image?.width == presetQuality.image.width }
        XCTAssertEqual(model.recipe, draft)
        XCTAssertTrue(model.dirty)
        XCTAssertEqual(model.editHistory.count, history)
        XCTAssertEqual(try model.catalog?.photo("000")?.recipe, saved)

        let photos = try model.exportSelection(), output = folder.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let exportOptions = ExportOptions()
        let names = try ExportNamingPlanner.preview(photos: photos, options: exportOptions, directory: output)
        let snapshots = try model.prepareExport(options: exportOptions, photos: photos, names: names, directory: output)
        XCTAssertEqual(try XCTUnwrap(snapshots.first?.request.recipe?.exposure), 0,
                       "导出只能读取已保存配方，不能读取预设 display-only recipe")

        model.endPresetPreview("other")
        XCTAssertEqual(model.previewingPresetID, preset.id)
        model.endPresetPreview(preset.id)
        XCTAssertNil(model.previewingPresetID)
        XCTAssertNil(model.previewingDevelopGroup)
        XCTAssertFalse(model.isPreviewingAdjustment)
        XCTAssertEqual(model.image?.width, normal.image.width, "结束预览先恢复缓存画面")
        XCTAssertEqual(model.recipe, draft)
        try await waitUntil { model.previewCurrent && model.image?.width == normal.image.width }
    }

    @MainActor
    func testDevelopGroupPreviewPulseRestoresCachedImageAndKeepsRecipe() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let normal = try bitmap(80), hiddenBasic = try bitmap(36)
        let model = try model(in: folder, renderer: { request, interactive, _ in
            if interactive, request.recipe?.exposure == 0 { return hiddenBasic }
            return normal
        })
        model.activeID = nil; model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit && model.previewCurrent && model.image?.width == normal.image.width }
        model.changeRecipe({ $0.exposure = 0.8 }, commit: false)
        try await waitUntil { model.dirty && model.recipe?.exposure == 0.8 && model.image?.width == normal.image.width }
        let draft = try XCTUnwrap(model.recipe), saved = try XCTUnwrap(model.catalog?.photo("000")?.recipe)
        let history = model.editHistory.count

        model.beginDevelopGroupPreview(.basic)
        try await waitUntil { model.previewingDevelopGroup == .basic && model.displayPreviewRecipe?.exposure == 0 }
        try await waitUntil { model.interactivePreview && model.image?.width == hiddenBasic.image.width }
        XCTAssertEqual(model.recipe, draft); XCTAssertTrue(model.dirty)
        XCTAssertEqual(try model.catalog?.photo("000")?.recipe, saved); XCTAssertEqual(model.editHistory.count, history)
        model.endDevelopGroupPreview()
        XCTAssertNil(model.previewingDevelopGroup); XCTAssertFalse(model.isPreviewingAdjustment)
        XCTAssertEqual(model.image?.width, normal.image.width, "松开眼睛先恢复 cached image")
        try await waitUntil { model.previewCurrent && model.image?.width == normal.image.width }

        model.pulseDevelopGroupPreview(.basic)
        try await waitUntil { model.previewingDevelopGroup == .basic }
        try await Task.sleep(for: .milliseconds(1_350))
        XCTAssertNil(model.previewingDevelopGroup, "语义脉冲应由 root 统一在 1.2 秒后结束")
        XCTAssertEqual(model.recipe, draft); XCTAssertEqual(model.editHistory.count, history)
    }

    @MainActor
    func testDisplayPreviewCancelsLateFrameOnPhotoEditEndAndRecipeChange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let normal = try bitmap(80), late = try bitmap(99), other = try bitmap(70)
        var release: CheckedContinuation<RenderedImage, Never>?
        var blockNextPreview = false
        let model = try model(in: folder, count: 2, renderer: { request, interactive, _ in
            if blockNextPreview, request.photo.id == "000", interactive, request.recipe?.exposure == 0 {
                blockNextPreview = false
                return await withCheckedContinuation { release = $0 }
            }
            return request.photo.id == "001" ? other : normal
        })
        model.activeID = nil; model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit && model.previewCurrent && model.image?.width == normal.image.width }
        model.changeRecipe({ $0.exposure = 0.8 }, commit: false)
        try await waitUntil { model.dirty && model.recipe?.exposure == 0.8 && model.image?.width == normal.image.width }

        blockNextPreview = true; model.beginDevelopGroupPreview(.basic)
        try await waitUntil { release != nil && model.previewingDevelopGroup == .basic }
        model.choose(["001"], active: "001")
        release?.resume(returning: late); release = nil
        try await waitUntil { model.activeID == "001" && model.canEdit }
        try await waitUntil { model.image?.width == other.image.width }
        XCTAssertNil(model.previewingDevelopGroup); XCTAssertFalse(model.isPreviewingAdjustment)
        XCTAssertNotEqual(model.image?.width, late.image.width, "切图后的迟到预览帧不能回闪")

        model.choose(["000"], active: "000")
        try await waitUntil { model.canEdit && model.image?.width == normal.image.width }
        model.changeRecipe({ $0.exposure = 0.8 }, commit: false)
        blockNextPreview = true; model.beginDevelopGroupPreview(.basic)
        try await waitUntil { release != nil && model.previewingDevelopGroup == .basic }
        model.editMode = false
        release?.resume(returning: late); release = nil
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(model.previewingDevelopGroup); XCTAssertFalse(model.isPreviewingAdjustment)

        model.editMode = true; model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit }
        model.changeRecipe({ $0.exposure = 0.8 }, commit: false)
        blockNextPreview = true; model.beginDevelopGroupPreview(.basic)
        try await waitUntil { release != nil && model.previewingDevelopGroup == .basic }
        model.changeRecipe({ $0.exposure = 1.1 }, commit: false)
        release?.resume(returning: late); release = nil
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(model.previewingDevelopGroup); XCTAssertFalse(model.isPreviewingAdjustment)
        XCTAssertEqual(model.recipe?.exposure, 1.1)
    }

    private func bitmap(_ width: Int = 80) throws -> RenderedImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: 40)
        let image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .red).cropped(to: rect), from: rect))
        return RenderedImage(image: image, fullSize: CGSize(width: width, height: 40),
                             orientedSourceSize: CGSize(width: width, height: 40), histogram: nil, elapsed: 0)
    }

    @MainActor func testLongDevelopSidebarKeepsFilmstripInsideShortWindowsInBothThemes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try model(in: folder), catalog = try XCTUnwrap(model.catalog)
        var value = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo("000")?.recipe))
        for n in 1...13 {
            value.exposure = Double(n) / 10
            try catalog.saveRecipe(id: "000", recipe: value, title: "合成历史 \(n)")
        }
        try catalog.savePreset(name: "合成预设", recipe: value, options: RecipePasteOptions())
        try model.reload()
        model.activeID = nil; model.choose(["000"], active: "000"); model.selectWorkspace(.develop)
        try await waitUntil { model.canEdit && model.editHistory.count == 13 }
        let suite = "develop-short-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); model.choose([], active: nil) }
        for key in ["showLeftPanel", "showRightPanel", "showFilmstrip", "developPreviewOpen", "workspacePresetsOpen", "workspaceSnapshotsOpen", "workspaceHistoryOpen", "workspaceCollectionsOpen"] {
            preferences.set(true, forKey: key)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for size in [CGSize(width: 1281, height: 673), CGSize(width: 1000, height: 640)] {
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                let container = NSView(frame: CGRect(origin: .zero, size: size))
                host.frame = container.bounds; container.addSubview(host); window.contentView = container
                defer { window.contentView = nil }
                try await waitUntil { descendants(host).contains { $0 is NSCollectionView } }
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
                let film = try XCTUnwrap(descendants(host).compactMap { $0 as? NSCollectionView }.first?.enclosingScrollView)
                let rect = film.convert(film.bounds, to: nil)
                XCTAssertGreaterThanOrEqual(rect.minY, -1, "长左栏不能把胶片带推出窗口底部")
                XCTAssertLessThanOrEqual(rect.maxY, size.height + 1)
                XCTAssertGreaterThan(rect.height, 60)
            }
        }
    }

    @MainActor
    private func model(in folder: URL, count: Int = 3,
                       renderer: ((ImageRequest, Bool, Int?) async throws -> RenderedImage)? = nil) throws -> AppModel {
        let image = try bitmap()
        let model = AppModel(previewRenderer: renderer ?? { _, _, _ in image })
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
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

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
