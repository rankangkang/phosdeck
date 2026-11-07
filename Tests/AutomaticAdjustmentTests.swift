import XCTest
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import GRDB
import SwiftUI
@testable import Phosdeck

private actor AutomaticAnalysisGate {
    var started = false
    private var continuation: CheckedContinuation<AutomaticAdjustmentResult, Never>?
    func analyze() async -> AutomaticAdjustmentResult {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ result: AutomaticAdjustmentResult) { continuation?.resume(returning: result); continuation = nil }
}

final class AutomaticAdjustmentTests: XCTestCase {
    private var folder: URL!
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: linear])
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func source(_ pixel: (Int, Int) -> SIMD4<Float>) throws -> ImageRequest {
        let width = 128, height = 96
        let values = (0..<height).flatMap { y in (0..<width).flatMap { x -> [Float] in
            let c = pixel(x, y); return [c.x, c.y, c.z, c.w]
        } }
        let image = values.withUnsafeBytes { bytes in CIImage(bitmapData: Data(bytes), bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linear) }
        let cg = try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: linear))
        let url = folder.appendingPathComponent(UUID().uuidString + ".tiff")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let root = StorageRoot(id: "synthetic", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "Synthetic")
        return ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: folder), root: root, recipe: nil)
    }
    private func chart() throws -> ImageRequest {
        try source { x, _ in
            let v = Float(x % 64 + 4) / 150
            return x < 64 ? SIMD4(v * 1.2, v, v * 0.8, 1) : SIMD4(v * 0.8, v, v * 1.2, 1)
        }
    }
    private func request(_ source: ImageRequest, _ recipe: EditRecipe) -> ImageRequest {
        ImageRequest(photo: source.photo, root: source.root, recipe: recipe)
    }
    private func wb(_ result: AutomaticAdjustmentResult) throws -> WhiteBalanceValue {
        guard case let .whiteBalance(value) = result else { throw LRCError("Expected white balance") }; return value
    }
    private func tone(_ result: AutomaticAdjustmentResult) throws -> AutomaticTone {
        guard case let .tone(value) = result else { throw LRCError("Expected tone") }; return value
    }

    func testShadesOfGrayUsesSixthNormAndFrozenValidPixels() throws {
        let pixels = AutomaticAdjustmentPixels((0..<100).flatMap { n -> [Float] in
            let c: Float = Float(n + 1) / 200
            return [c * 1.2, c, c * 0.8, 1]
        } + [1, 1, 1, 1, 0, 0, 0, 1, .nan, 0, 0, 0, 100, 100, 100, 0])
        let selected = try pixels.whiteBalanceIndices()
        XCTAssertEqual(selected, Array(0..<100))
        let value = try pixels.illuminant(at: selected)
        let expected = pow((1...100).reduce(0.0) { $0 + pow(Double($1) / 200, 6) } / 100, 1/6.0)
        XCTAssertEqual(value.y, expected, accuracy: 0.000001)
        XCTAssertEqual(value.x/value.y, 1.2, accuracy: 0.000001)
        XCTAssertEqual(value.z/value.y, 0.8, accuracy: 0.000001)
        let signed = try AutomaticAdjustmentPixels([-0.2, 0.3, 0.4, 1]).illuminant(at: [0])
        XCTAssertEqual(signed.x, 0.2, accuracy: 0.000001)
        XCTAssertEqual(signed.z, 0.4, accuracy: 0.000001)
        XCTAssertThrowsError(try AutomaticAdjustmentPixels([0, 0, 0]).whiteBalanceIndices())
        XCTAssertThrowsError(try AutomaticAdjustmentPixels([Float](repeating: 0, count: 400)).whiteBalanceIndices())
        XCTAssertThrowsError(try AutomaticAdjustmentPixels(Array(repeating: [Float(0.1), 0.8, 0.1, 1], count: 100).flatMap { $0 }).whiteBalanceIndices())
    }

    func testToneFitStopsAtExposureBoundsAndRejectsNonfiniteStatistics() throws {
        XCTAssertEqual(try AutomaticToneAnalysis.solve { _ in [0.1, 0.2, 0.3, 0.4, 0.5] }.exposure, 3)
        XCTAssertEqual(try AutomaticToneAnalysis.solve { _ in [0.6, 0.7, 0.8, 0.9, 1] }.exposure, -3)
        XCTAssertThrowsError(try AutomaticToneAnalysis.solve { _ in [0, 0.2, .nan, 0.8, 1] })
        XCTAssertThrowsError(try AutomaticToneAnalysis.solve { _ in [0, 0.2] })
    }

    func testAutoWhiteBalanceUsesVisibleCropAndIgnoresCreativeEdits() async throws {
        let source = try chart(), pipeline = ImagePipeline(), original = try await pipeline.baseline(source)
        var crop = original; crop.crop = Crop(x: 0, y: 0, width: 0.5, height: 1)
        let value = try wb(await pipeline.automaticAdjustment(request(source, crop), kind: .whiteBalance))
        var balanced = crop; AutomaticAdjustmentResult.whiteBalance(value).apply(to: &balanced)
        let rank = try await pipeline.linearRank(request(source, balanced), longEdge: 512)
        let image = try ImagePipeline.geometry(SpotRepairPipeline.image(rank), recipe: balanced)
        let pixels = AutomaticAdjustmentPixels(image: image, context: context)
        let c = try pixels.illuminant(at: pixels.whiteBalanceIndices())
        XCTAssertLessThan(abs(log(c.x/c.y)), 0.018); XCTAssertLessThan(abs(log(c.z/c.y)), 0.018)
        crop.exposure = 4; crop.contrast = 0.1; crop.saturation = 0
        crop.develop.blackAndWhite = true; crop.develop.highlights = -80; crop.develop.grading.global.saturation = 60
        crop.quarterTurns = 1; crop.flipHorizontal = true; crop.flipVertical = true
        crop.crop = Crop(x: 0, y: 0, width: 1, height: 0.5)
        // Independent transformed native pixels define which half is visible.
        let half = try ImagePipeline.geometry(SpotRepairPipeline.image(try await pipeline.linearRank(request(source, original), longEdge: 512)), recipe: crop)
        let expectedPixels = AutomaticAdjustmentPixels(image: half, context: context)
        let expectedCast = try expectedPixels.illuminant(at: expectedPixels.whiteBalanceIndices())
        let rotated = try wb(await pipeline.automaticAdjustment(request(source, crop), kind: .whiteBalance))
        var verify = original; verify.quarterTurns = crop.quarterTurns; verify.flipHorizontal = true; verify.flipVertical = true; verify.crop = crop.crop
        AutomaticAdjustmentResult.whiteBalance(rotated).apply(to: &verify)
        let forward = try ImagePipeline.geometry(SpotRepairPipeline.image(try await pipeline.linearRank(request(source, verify), longEdge: 512)), recipe: verify)
        let p = AutomaticAdjustmentPixels(image: forward, context: context), corrected = try p.illuminant(at: p.whiteBalanceIndices())
        XCTAssertGreaterThan(abs(log(expectedCast.x/expectedCast.z)), 0.1)
        XCTAssertLessThan(abs(log(corrected.x/corrected.y)), 0.018); XCTAssertLessThan(abs(log(corrected.z/corrected.y)), 0.018)
        crop.straightenDegrees = 4; crop.perspective = PerspectiveSettings(horizontal: 8, vertical: -5, aspect: 2)
        let perspective = try await pipeline.automaticAdjustment(request(source, crop), kind: .whiteBalance)
        let repeatedPerspective = try await pipeline.automaticAdjustment(request(source, crop), kind: .whiteBalance)
        XCTAssertEqual(perspective, repeatedPerspective)
        XCTAssertEqual(try SafeFileWriter.sha256(folder.appendingPathComponent(source.photo.relativePath)), original.sourceDigest)
    }

    func testAutoToneCorrectsDarkAndBrightChartsWithinBoundsAndIsRepeatable() async throws {
        for scale: Float in [0.08, 0.8] {
            let source = try source { x, _ in
                let v = scale * (0.3 + Float(x) / 128 * 0.7); return SIMD4(v, v, v, 1)
            }
            let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(source)
            let value = try tone(await pipeline.automaticAdjustment(request(source, baseline), kind: .tone))
            XCTAssertTrue((-3...3).contains(value.exposure)); XCTAssertTrue((0.7...1.35).contains(value.contrast))
            for v in [value.highlights, value.shadows, value.whites, value.blacks] { XCTAssertTrue((-60...60).contains(v)) }
            XCTAssertTrue(scale < 0.1 ? value.exposure > 0 : value.exposure < 0)
            var edited = baseline; edited.exposure = -4; edited.contrast = 2; edited.develop.shadows = 80
            edited.develop.curves = ToneCurves(); edited.develop.blackAndWhite = true; edited.saturation = 0.2
            let again = try await pipeline.automaticAdjustment(request(source, edited), kind: .tone)
            XCTAssertEqual(again, .tone(value), "Existing tone/color must not feed back into analysis")
            again.apply(to: &edited)
            XCTAssertEqual(edited.develop.curves, ToneCurves()); XCTAssertTrue(edited.develop.blackAndWhite)
            XCTAssertEqual(edited.saturation, 0.2); XCTAssertEqual(edited.asShotWhiteBalance, baseline.asShotWhiteBalance)
            let before = try await pipeline.linearRank(request(source, baseline), longEdge: 512)
            let after = try await pipeline.linearRank(request(source, edited), longEdge: 512)
            let old = try AutomaticAdjustmentPixels(image: SpotRepairPipeline.image(before), context: context).toneQuantiles()[2]
            let new = try AutomaticAdjustmentPixels(image: SpotRepairPipeline.image(after), context: context).toneQuantiles()[2]
            XCTAssertLessThan(abs(new - 0.46), abs(old - 0.46))
        }
    }

    func testInsufficientTransparentClippedAndChangedSourcesAreRejected() async throws {
        for color: SIMD4<Float> in [SIMD4(0,0,0,1), SIMD4(1,1,1,1), SIMD4(0,0,0,0), SIMD4(1,0,0,1)] {
            let s = try source { _, _ in color }, pipeline = ImagePipeline(), baseline = try await pipeline.baseline(s)
            for kind: AutomaticAdjustmentKind in [.whiteBalance, .tone] {
                do { _ = try await pipeline.automaticAdjustment(request(s, baseline), kind: kind); XCTFail("Unsuitable \(color), \(kind)") } catch {}
            }
        }
        let s = try chart(), pipeline = ImagePipeline(), baseline = try await pipeline.baseline(s)
        try Data("changed synthetic source".utf8).write(to: folder.appendingPathComponent(s.photo.relativePath))
        do { _ = try await pipeline.automaticAdjustment(request(s, baseline), kind: .tone); XCTFail("Changed source") } catch {}
    }

    func testAnalysisExcludesTransparentPaddingAndPreservesAlpha() async throws {
        let s = try source { x, _ in
            let v = Float(x + 4) / 180
            return x < 64 ? SIMD4(v * 1.2, v, v * 0.8, 1) : SIMD4(0, 0, 0, 0)
        }
        let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(s)
        var crop = baseline; crop.crop = Crop(x: 0, y: 0, width: 0.5, height: 1)
        let full = try await pipeline.automaticAdjustment(request(s, baseline), kind: .whiteBalance)
        let cropped = try await pipeline.automaticAdjustment(request(s, crop), kind: .whiteBalance)
        XCTAssertEqual(full, cropped, "Invisible padding must not bias the illuminant")
        var adjusted = baseline; full.apply(to: &adjusted)
        let tone = try await pipeline.automaticAdjustment(request(s, adjusted), kind: .tone)
        tone.apply(to: &adjusted)
        let before = try await pipeline.linearRank(request(s, baseline), longEdge: 512)
        let after = try await pipeline.linearRank(request(s, adjusted), longEdge: 512)
        XCTAssertNotNil(before.alpha); XCTAssertEqual(before.alpha, after.alpha)
    }

    @MainActor private func model(_ s: ImageRequest, recipe: EditRecipe) throws -> AppModel {
        let catalog = try CatalogStore(directory: folder.appendingPathComponent(UUID().uuidString))
        try catalog.database.write { try s.root.insert($0) }; try catalog.index(s.photo)
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.roots = [s.root]; model.photos = [s.photo]
        model.activeID = s.photo.id; model.activePhoto = s.photo; model.selection = [s.photo.id]
        model.recipe = recipe; model.canEdit = true; model.dirty = true
        model.undo.groupsByEvent = false; XCTAssertTrue(model.commitRecipe()); model.undo.removeAllActions(); model.editMode = true
        return model
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Automatic adjustment did not complete"); throw CancellationError()
    }
    @MainActor func testActionsSaveOnceUndoRedoAndRepeatedClickStartsOnlyOneAnalysis() async throws {
        let s = try chart(), recipe = try await ImagePipeline().baseline(s), model = try model(s, recipe: recipe)
        let catalog = try XCTUnwrap(model.catalog), count = try catalog.editHistory(photoID: s.photo.id).count
        let gate = AutomaticAnalysisGate(), result = AutomaticAdjustmentResult.tone(AutomaticTone(exposure: 0.4, contrast: 1.1, highlights: -20, shadows: 15, whites: 10, blacks: -5))
        model.applyAutomaticAdjustment(.tone) { _, _ in await gate.analyze() }
        model.applyAutomaticAdjustment(.tone) { _, _ in XCTFail("Duplicate analysis"); return result }
        XCTAssertEqual(model.recipe, recipe); XCTAssertEqual(try catalog.editHistory(photoID: s.photo.id).count, count)
        for _ in 0..<100 { if await gate.started { break }; await Task.yield() }
        await gate.finish(result)
        try await waitUntil { model.automaticAdjustmentKind == nil }
        var expected = recipe; result.apply(to: &expected)
        XCTAssertEqual(model.recipe, expected); XCTAssertEqual(try catalog.editHistory(photoID: s.photo.id).count, count + 1)
        model.undo.undo(); XCTAssertEqual(model.recipe, recipe)
        model.undo.redo(); XCTAssertEqual(model.recipe, expected)
        model.applyAutomaticAdjustment(.whiteBalance) { _, _ in .whiteBalance(WhiteBalanceValue(temperature: 5100, tint: -4)) }
        try await waitUntil { model.automaticAdjustmentKind == nil }
        XCTAssertFalse(try XCTUnwrap(model.recipe).asShotWhiteBalance)
        XCTAssertEqual(model.recipe?.exposure, expected.exposure)
        model.undo.undo(); XCTAssertEqual(model.recipe, expected)
    }

    @MainActor func testDefaultAnalysisTaskUsesNativePipelineAndSavesOnce() async throws {
        let s = try chart(), recipe = try await ImagePipeline().baseline(s), model = try model(s, recipe: recipe)
        let catalog = try XCTUnwrap(model.catalog), count = try catalog.editHistory(photoID: s.photo.id).count
        model.applyAutomaticAdjustment(.tone)
        XCTAssertEqual(model.recipe, recipe)
        try await waitUntil { model.automaticAdjustmentKind == nil }
        XCTAssertNotEqual(model.recipe, recipe)
        XCTAssertEqual(try catalog.editHistory(photoID: s.photo.id).count, count + 1)
        model.undo.undo(); XCTAssertEqual(model.recipe, recipe)
    }

    @MainActor func testCancelSwitchEditToolAndRefreshDiscardLateResultsWithoutDrafts() async throws {
        let s = try chart(), recipe = try await ImagePipeline().baseline(s)
        for event in 0..<6 {
            let model = try model(s, recipe: recipe), gate = AutomaticAnalysisGate()
            let catalog = try XCTUnwrap(model.catalog)
            model.applyAutomaticAdjustment(.tone) { _, _ in await gate.analyze() }
            for _ in 0..<100 { if await gate.started { break }; await Task.yield() }
            switch event {
            case 0: model.cancelAutomaticAdjustment()
            case 1: model.activeID = "another-photo"
            case 2:
                model.undo.beginUndoGrouping(); model.changeRecipe { $0.exposure = 0.5 }; model.undo.endUndoGrouping()
            case 3: XCTAssertTrue(model.selectDevelopTool(.crop))
            case 4: model.canEdit = false
            default: model.editMode = false
            }
            XCTAssertNil(model.automaticAdjustmentKind)
            let expected = model.recipe, count = try catalog.editHistory(photoID: s.photo.id).count
            await gate.finish(.tone(AutomaticTone(exposure: 2)))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(model.recipe, expected); XCTAssertFalse(model.dirty)
            XCTAssertEqual(try catalog.editHistory(photoID: s.photo.id).count, count)
        }
    }

    @MainActor func testNoOpAndAnalysisFailureDoNotAddHistoryAndEscapeCancels() async throws {
        let s = try chart(), recipe = try await ImagePipeline().baseline(s), model = try model(s, recipe: recipe)
        let catalog = try XCTUnwrap(model.catalog), count = try catalog.editHistory(photoID: s.photo.id).count
        model.applyAutomaticAdjustment(.tone) { _, _ in .tone(AutomaticTone()) }
        try await waitUntil { model.automaticAdjustmentKind == nil }
        XCTAssertEqual(model.recipe, recipe); XCTAssertEqual(try catalog.editHistory(photoID: s.photo.id).count, count)
        XCTAssertFalse(model.undo.canUndo)
        model.applyAutomaticAdjustment(.tone) { _, _ in throw AutomaticAdjustmentPixels.insufficient }
        try await waitUntil { model.automaticAdjustmentKind == nil }
        XCTAssertEqual(model.recipe, recipe); XCTAssertEqual(try catalog.editHistory(photoID: s.photo.id).count, count)
        let gate = AutomaticAnalysisGate()
        model.applyAutomaticAdjustment(.tone) { _, _ in await gate.analyze() }
        for _ in 0..<100 { if await gate.started { break }; await Task.yield() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        XCTAssertNil(WorkspaceKeyboard.handle(event, model: model)); XCTAssertNil(model.automaticAdjustmentKind)
        await gate.finish(.tone(AutomaticTone(exposure: 1)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.recipe, recipe); XCTAssertFalse(model.dirty)
    }

    @MainActor func testNarrowBasicPanelKeepsAutomaticControlsInBothThemes() async throws {
        print("AUTO_LAYOUT language=\(L10n.current.language)")
        let s = try chart(), recipe = try await ImagePipeline().baseline(s), model = try model(s, recipe: recipe)
        let suite = "auto-layout-" + UUID().uuidString, prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(true, forKey: "developBasicOpen")
        for theme in [ChromeTheme.ivory, .graphite] {
            prefs.set(theme.rawValue, forKey: "chromeTheme")
            let size = CGSize(width: 260, height: 720)
            let host = NSHostingView(rootView: ScrollView { DevelopPanel(model: model) }
                .frame(width: size.width, height: size.height).background(Theme.panel).defaultAppStorage(prefs).preferredColorScheme(theme.colorScheme))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua); window.contentView = host
            try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "automatic-basic-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            window.contentView = nil
        }
    }

    func testPublicARWAnalysisUsesItsOwnBaselineAndKeepsSourceBytes() async throws {
        try await checkPublicRAW("a7iii_12bit_compressed.ARW")
    }
    func testPublicDNGAnalysisUsesItsOwnBaselineAndKeepsSourceBytes() async throws {
        try await checkPublicRAW("leica_m8_8bit_uncompressed.DNG")
    }
    private func checkPublicRAW(_ name: String) async throws {
        let s = try MoreRAWTests.request(name), pipeline = ImagePipeline(), baseline = try await pipeline.baseline(s)
        let original = try await pipeline.render(request(s, baseline), longEdge: 768)
        let originalAttachment = XCTAttachment(data: try XCTUnwrap(NSBitmapImageRep(cgImage: original.image).representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        originalAttachment.name = "automatic-\(name)-baseline"; originalAttachment.lifetime = .keepAlways; add(originalAttachment)
        let inputRank = try await pipeline.linearRank(request(s, baseline), longEdge: 512)
        let inputPixels = try AutomaticAdjustmentPixels(image: SpotRepairPipeline.image(inputRank), context: context)
        let selected = try inputPixels.whiteBalanceIndices()
        for kind: AutomaticAdjustmentKind in [.whiteBalance, .tone] {
            let result = try await pipeline.automaticAdjustment(request(s, baseline), kind: kind)
            var value = baseline; result.apply(to: &value); try value.validate(for: s.photo)
            XCTAssertEqual(value.baselineExposure, baseline.baselineExposure)
            XCTAssertEqual(value.baselineTemperature, baseline.baselineTemperature)
            if kind == .whiteBalance {
                let rank = try await pipeline.linearRank(request(s, value), longEdge: 512)
                let pixels = try AutomaticAdjustmentPixels(image: SpotRepairPipeline.image(rank), context: context)
                let c = try pixels.illuminant(at: selected)
                XCTAssertLessThan(abs(log(c.x/c.y)), 0.02); XCTAssertLessThan(abs(log(c.z/c.y)), 0.02)
            }
            let repeated = try await pipeline.automaticAdjustment(request(s, value), kind: kind)
            XCTAssertEqual(result, repeated)
            let rendered = try await pipeline.render(request(s, value), longEdge: 768)
            XCTAssertGreaterThan(rendered.image.width, 0)
            let bitmap = NSBitmapImageRep(cgImage: rendered.image)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "automatic-\(name)-\(kind)"; attachment.lifetime = .keepAlways; add(attachment)
            print("AUTO_RAW sample=\(name) kind=\(kind) result=\(result)")
        }
        XCTAssertEqual(try SafeFileWriter.sha256(MoreRAWTests.sample(name)), baseline.sourceDigest)
    }
}
