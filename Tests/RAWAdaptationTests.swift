import XCTest
import AppKit
import SwiftUI
import CoreImage
import ImageIO
@testable import Phosdeck

final class RAWAdaptationTests: XCTestCase {
    private var folder: URL!
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAf,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func request(_ source: ImageRequest, _ recipe: EditRecipe) -> ImageRequest {
        ImageRequest(photo: source.photo, root: source.root, recipe: recipe)
    }
    private func pixels(_ image: CGImage) -> Data {
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            context.render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: image.width * 4,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        }
        return data
    }

    func testEveryRAWUsesItsActualDefaultsAndInvalidatesDecodedPixels() async throws {
        let pipeline = ImagePipeline(), cached = ImagePipeline()
        for name in MoreRAWTests.supportedFiles {
            let source = try MoreRAWTests.request(name), url = try MoreRAWTests.sample(name)
            let baseline = try await pipeline.baseline(source)
            let defaults = try await pipeline.rawDefaults(request(source, baseline))
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
            XCTAssertEqual(defaults, RAWDetailSettings(raw: raw))
            let normal = try await pipeline.render(request(source, baseline), longEdge: 512)
            var explicit = baseline; explicit.rawDetails = defaults
            let fixed = try await pipeline.render(request(source, explicit), longEdge: 512)
            XCTAssertEqual(pixels(normal.image), pixels(fixed.image), "nil 使用这张文件自己的默认值")
            var edited = baseline
            edited.rawDetails = RAWDetailSettings(luminanceNoiseReduction: 0.8, colorNoiseReduction: 0.1, sharpness: 0.25,
                lensCorrection: defaults.lensCorrection.map { !$0 }).supported(by: defaults)
            try edited.rawDetails.checkSupport(defaults)
            let changed = try await pipeline.render(request(source, edited), longEdge: 512)
            XCTAssertNotEqual(pixels(normal.image), pixels(changed.image), name)
            _ = try await cached.renderInteractive(request(source, baseline), longEdge: 512)
            let cachedChange = try await cached.renderInteractive(request(source, edited), longEdge: 512)
            let freshChange = try await ImagePipeline().renderInteractive(request(source, edited), longEdge: 512)
            XCTAssertEqual(pixels(cachedChange.image), pixels(freshChange.image), "细节变化使解码/空间缓存失效")
            let reset = try await cached.renderInteractive(request(source, baseline), longEdge: 512)
            let freshReset = try await ImagePipeline().renderInteractive(request(source, baseline), longEdge: 512)
            XCTAssertEqual(pixels(reset.image), pixels(freshReset.image), "复位不能留下之前的细节设置")
            XCTAssertEqual(try SafeFileWriter.sha256(url), baseline.sourceDigest)
            print("RAW_CAPABILITIES file=\(name) decoder=\(baseline.decoderVersion) defaults=\(defaults)")
        }
    }

    func testCapabilityProjectionPreservesTargetDefaultsAndRejectsDirectUnsupportedEdits() throws {
        let source = RAWDetailSettings(luminanceNoiseReduction: 0.8, colorNoiseReduction: 0.1, sharpness: 0.4, lensCorrection: true)
        for support in [RAWDetailSettings(), RAWDetailSettings(sharpness: 0.9),
                        RAWDetailSettings(luminanceNoiseReduction: 0, colorNoiseReduction: 0.5, sharpness: 1)] {
            let projected = source.supported(by: support)
            try projected.checkSupport(support)
            XCTAssertEqual(projected.sharpness, support.sharpness == nil ? nil : source.sharpness)
            XCTAssertNil(projected.lensCorrection)
            XCTAssertThrowsError(try source.checkSupport(support))
            XCTAssertTrue(RAWDetailSettings().supported(by: support).isDefault, "空源必须保持目标默认语义")
        }
    }

    func testLensGeometryReferencesRepairsAndPreviewCachesAgree() async throws {
        let source = try MoreRAWTests.request("fuji_xt20_14bit_lossless.RAF")
        let pipeline = ImagePipeline(), cached = ImagePipeline()
        var recipe = try await pipeline.baseline(source)
        let defaults = try await pipeline.rawDefaults(request(source, recipe))
        XCTAssertNotNil(defaults.lensCorrection)
        recipe.schemaVersion = 3
        var range = MaskComponent(tool: .luminance); range.lower = 0.2; range.upper = 0.8
        var group = LocalAdjustment(components: [range]); group.exposure = 0.25
        recipe.localAdjustments = [group]
        recipe.repairs = [SpotRepair(mode: .clone, points: [MaskPoint(0.35, 0.55)], radius: 0.04, sourceOffset: MaskPoint(0.2, 0))]
        recipe.quarterTurns = 1; recipe.straightenDegrees = 5
        recipe.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.75)
        let savedMasks = recipe.localAdjustments, savedSpots = recipe.repairs
        var previousReference: Data?
        for enabled in [false, true, false] {
            recipe.rawDetails.lensCorrection = enabled
            let job = request(source, recipe)
            let reference = try await cached.maskReference(job)
            let freshReference = try await ImagePipeline().maskReference(job)
            XCTAssertEqual(pixels(reference), pixels(freshReference), "镜头变化不能复用旧范围参考")
            if let previousReference { XCTAssertNotEqual(previousReference, pixels(reference)) }
            previousReference = pixels(reference)
            let rank = try await cached.linearRank(job)
            let freshRank = try await ImagePipeline().linearRank(job)
            XCTAssertTrue(rank == freshRank, "修复选源必须使用当前镜头几何的线性图")
            let preview = try await cached.renderInteractive(job, longEdge: 512)
            let fresh = try await ImagePipeline().renderInteractive(job, longEdge: 512)
            XCTAssertEqual(pixels(preview.image), pixels(fresh.image))
            let quality = try await pipeline.render(job, longEdge: 512)
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: MoreRAWTests.sample("fuji_xt20_14bit_lossless.RAF")))
            raw.isLensCorrectionEnabled = enabled
            XCTAssertEqual(quality.orientedSourceSize, try XCTUnwrap(raw.outputImage).extent.size)
            let mapping = MaskGeometry.mapping(size: quality.orientedSourceSize, recipe: recipe)
            XCTAssertEqual(quality.fullSize, mapping.output)
            let point = MaskPoint(0.35, 0.55)
            let displayed = CGPoint(x: point.x * quality.orientedSourceSize.width, y: point.y * quality.orientedSourceSize.height).applying(mapping.transform)
            let back = try XCTUnwrap(MaskGeometry.sourcePoint(CGPoint(x: displayed.x / mapping.output.width, y: displayed.y / mapping.output.height), size: quality.orientedSourceSize, recipe: recipe, allowOutside: true))
            XCTAssertEqual(back.x, point.x, accuracy: 1e-9); XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
            XCTAssertEqual(recipe.localAdjustments, savedMasks); XCTAssertEqual(recipe.repairs, savedSpots)
            let output = folder.appendingPathComponent("lens-\(enabled)-\(UUID()).png")
            _ = try await pipeline.export(job, staging: output, options: ExportOptions(format: .png, longEdge: 512))
            let readback = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            XCTAssertEqual(pixels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(readback, 0, nil))), pixels(quality.image))
            print("RAW_LENS enabled=\(enabled) source=\(quality.orientedSourceSize) output=\(quality.fullSize) reference=\(reference.width)x\(reference.height)")
        }
    }

    @MainActor func testActualCapabilitiesDriveControlsAndResetToNil() async throws {
        let preferences = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        for key in ["developBasicOpen", "developMixerOpen", "developGradingOpen", "developCurvesOpen", "developZonesOpen", "developVignetteOpen", "developGrainOpen", "developBlackWhiteMixerOpen"] { preferences.set(false, forKey: key) }
        preferences.set(true, forKey: "developDetailsOpen")
        let model = AppModel()
        let host = NSHostingView(rootView: DevelopPanel(model: model).defaultAppStorage(preferences).background(Theme.panel))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 336, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        func sliders(_ view: NSView) -> [AdjustmentNSSlider] {
            if let slider = view as? AdjustmentNSSlider { return [slider] }
            return view.subviews.flatMap(sliders)
        }
        for name in ["leica_m8_8bit_uncompressed.DNG", "canon_m50_raw.CR3", "fuji_xt20_14bit_lossless.RAF"] {
            let source = try MoreRAWTests.request(name)
            let baseline = try await model.pipeline.baseline(source)
            model.recipe = baseline; model.rawDefaults = try await model.pipeline.rawDefaults(request(source, baseline)); model.canEdit = true
            let count = [model.rawDefaults?.luminanceNoiseReduction, model.rawDefaults?.colorNoiseReduction, model.rawDefaults?.sharpness].compactMap { $0 }.count
            let expected = try XCTUnwrap(model.rawDefaults?.sharpness) * 100
            try await wait { sliders(host).count == count && sliders(host).contains { $0.accessibilityLabel() == "锐化" && abs($0.doubleValue - expected) < 0.00001 } }
            let slider = try XCTUnwrap(sliders(host).first { $0.accessibilityLabel() == "锐化" })
            slider.doubleValue = 42; slider.sendAction(slider.action, to: slider.target)
            XCTAssertEqual(model.recipe?.rawDetails.sharpness, 0.42)
            slider.doubleValue = try XCTUnwrap(model.rawDefaults?.sharpness) * 100; slider.sendAction(slider.action, to: slider.target)
            XCTAssertNil(model.recipe?.rawDetails.sharpness, "单参数回到默认也保存为 nil")
            XCTAssertGreaterThan(slider.visibleRect.width, 40)
        }
    }

    @MainActor func testMixedRAWBatchSinglePasteUndoAndReopen() async throws {
        var catalog: CatalogStore? = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        let sourceURL = try MoreRAWTests.sample("fuji_xt20_14bit_lossless.RAF").deletingLastPathComponent()
        let root = try catalog!.addRoot(url: sourceURL, bookmark: AccessLease.bookmark(sourceURL, readOnly: true))
        for name in MoreRAWTests.supportedFiles { try catalog!.index(ReferenceImporter.inspect(url: sourceURL.appendingPathComponent(name), root: root, rootURL: sourceURL)) }
        let photos = try catalog!.photos(), primary = try XCTUnwrap(photos.first { $0.name == "fuji_xt20_14bit_lossless.RAF" })
        let preview = ImagePipeline()
        let model = AppModel(previewRenderer: { job, _, _ in try await preview.render(job, longEdge: 128) })
        model.undo.groupsByEvent = false; model.catalog = catalog; try model.reload()
        model.choose([primary.id], active: primary.id)
        try await wait { model.canEdit && model.rawDefaults != nil }
        XCTAssertTrue(model.canvasCoordinatesCurrent)
        model.maskReference = model.image
        model.undo.beginUndoGrouping()
        model.changeRecipe { value in
            value.exposure = 0.4
            value.rawDetails = RAWDetailSettings(luminanceNoiseReduction: 0.75, colorNoiseReduction: 0.2, sharpness: 0.4, lensCorrection: false)
        }
        model.undo.endUndoGrouping()
        XCTAssertFalse(model.canvasCoordinatesCurrent, "镜头新几何不能在旧画面上接收蒙版/修复指针")
        XCTAssertNil(model.maskReference)
        try await wait { model.canvasCoordinatesCurrent && model.previewCurrent }
        let source = try XCTUnwrap(model.recipe)
        let targets = photos.filter { $0.id != primary.id }, ids = Set(targets.map(\.id))
        let options = RecipePasteOptions(tone: true, whiteBalance: false, color: false, geometry: false, details: true, curves: false, zones: false)
        XCTAssertTrue(model.applyAdjustments(source: source, options: options, ids: ids, title: "多格式细节同步"))
        try await wait { !model.applyingAdjustments }
        XCTAssertEqual(model.reports.filter { $0.hasPrefix("成功：") }.count, targets.count)
        XCTAssertTrue(model.reports.contains { $0.contains("目标不支持，已略过：镜头校正") })
        var expected: [String: RAWDetailSettings] = [:]
        for target in targets {
            let photo = try XCTUnwrap(catalog!.photo(target.id)), recipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(photo.recipe))
            let defaults = try await preview.rawDefaults(request(ImageRequest(photo: photo, root: root, recipe: nil), recipe))
            XCTAssertEqual(recipe.rawDetails, source.rawDetails.supported(by: defaults)); XCTAssertEqual(recipe.exposure, 0.4)
            let baseline = try await preview.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
            XCTAssertEqual(recipe.baselineTemperature, baseline.baselineTemperature)
            expected[photo.id] = recipe.rawDetails
        }
        model.undo.undo(); XCTAssertTrue(try catalog!.photos(ids: ids).allSatisfy { $0.recipe == nil })
        model.undo.redo(); XCTAssertTrue(try catalog!.photos(ids: ids).allSatisfy { $0.recipe != nil })
        let nef = try XCTUnwrap(targets.first { $0.name.hasSuffix(".NEF") })
        model.choose([nef.id], active: nef.id)
        try await wait { model.canEdit && model.rawDefaults != nil }
        var copied = source; copied.exposure = 0.8; copied.rawDetails.sharpness = 0.6
        model.copiedRecipe = copied; model.undo.beginUndoGrouping()
        XCTAssertTrue(model.pasteAdjustments(options: options)); model.undo.endUndoGrouping()
        XCTAssertNil(model.recipe?.rawDetails.lensCorrection); XCTAssertEqual(model.recipe?.rawDetails.sharpness, 0.6)
        XCTAssertTrue(model.status.contains("已略过：镜头校正"))
        model.undo.beginUndoGrouping(); model.changeRecipe { $0.rawDetails = RAWDetailSettings() }; model.undo.endUndoGrouping()
        XCTAssertTrue(try XCTUnwrap(model.recipe).rawDetails.isDefault)
        model.undo.undo(); XCTAssertEqual(model.recipe?.rawDetails.sharpness, 0.6)
        model.undo.redo(); expected[nef.id] = RAWDetailSettings()
        model.catalog = nil; model.undo.removeAllActions(); catalog = nil
        let reopened = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        for (id, detail) in expected {
            let photo = try XCTUnwrap(reopened.photo(id)), saved = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(photo.recipe))
            XCTAssertEqual(saved.rawDetails, detail)
            _ = try await preview.rawDefaults(ImageRequest(photo: photo, root: root, recipe: saved))
        }
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(15)) }
        throw LRCError("Timed out waiting for native RAW state")
    }
}
