import XCTest
import CoreImage
import AppKit
import SwiftUI
@testable import Phosdeck

final class ManualDefringeTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: space, .cacheIntermediates: false])
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
            baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func image(_ values: [Float], width: Int, height: Int) -> CIImage {
        values.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space) }
    }
    private func pixels(_ image: CIImage) -> [Float] {
        var result = Array(repeating: Float(0), count: Int(image.extent.width * image.extent.height) * 4)
        context.render(image, toBitmap: &result, rowBytes: Int(image.extent.width) * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
        return result
    }
    private func fixture() -> [Float] {
        (0..<(80 * 40)).flatMap { i -> [Float] in
            let x = i % 80, y = i / 80
            var color: [Float] = x < 30 ? [0.02, 0.02, 0.02] : [0.8, 0.8, 0.8]
            if (30..<32).contains(x) || (50..<72).contains(x) { color = y < 20 ? [0.5, 0.15, 0.6] : [0.1, 0.5, 0.1] }
            let alpha: Float = y % 3 == 0 ? 1 / 65535 : y % 2 == 0 ? 0.5 : 1
            if x < 2 { return [0, 0, 0, 0] }
            return color.map { $0 * alpha } + [alpha]
        }
    }
    func testSettingsValidateBoundariesRoundTripAndExactBypass() throws {
        let input = image(fixture(), width: 80, height: 40)
        var settings = ManualDefringe()
        XCTAssertTrue(try ManualDefringePipeline.apply(input, settings, sourceSize: input.extent.size) === input)
        settings.purpleLower = 200; settings.purpleUpper = 210; settings.greenLower = 190; settings.greenUpper = 200
        settings.purpleAmount = 100; settings.greenAmount = 100
        try settings.validate()
        XCTAssertEqual(try JSONDecoder().decode(ManualDefringe.self, from: JSONEncoder().encode(settings)), settings)
        for value in [-1.0, 101, .infinity, .nan] {
            var invalid = settings; invalid.purpleAmount = value; XCTAssertThrowsError(try invalid.validate())
        }
        var invalid = settings; invalid.purpleUpper = 209; XCTAssertThrowsError(try invalid.validate())
        invalid = settings; invalid.greenLower = 39; XCTAssertThrowsError(try invalid.validate())
        invalid = settings; invalid.version = "unknown"; XCTAssertThrowsError(try invalid.validate())
        var r = recipe(); r.manualDefringe.purpleLower = 250
        XCTAssertTrue(r.isUnadjustedRaster, "Inactive hue selection preserves the original raster path")
        r.manualDefringe.purpleAmount = 1; XCTAssertFalse(r.isUnadjustedRaster)
        r.pipelineVersion = 1; XCTAssertThrowsError(try r.validate())
    }
    func testThinPurpleAndGreenFringesLoseChromaWithoutMovingLumaOrAlpha() throws {
        let before = fixture(), input = image(before, width: 80, height: 40)
        var settings = ManualDefringe(); settings.purpleAmount = 100; settings.greenAmount = 100
        let after = pixels(try ManualDefringePipeline.apply(input, settings, sourceSize: input.extent.size))
        for y in [9, 10, 29] {
            let i = (y * 80 + 30) * 4
            let alpha = before[i+3]
            XCTAssertLessThan((after[i..<i+3].max()! - after[i..<i+3].min()!) / alpha, 0.001)
            let luma: (ArraySlice<Float>) -> Float = { $0[$0.startIndex] * 0.2126 + $0[$0.startIndex+1] * 0.7152 + $0[$0.startIndex+2] * 0.0722 }
            XCTAssertEqual(luma(after[i..<i+3]) / alpha, luma(before[i..<i+3]) / alpha, accuracy: 1e-6)
            let flat = (y * 80 + 60) * 4
            for c in 0..<4 { XCTAssertEqual(after[flat+c], before[flat+c], accuracy: 1e-6, "Broad target-colored objects remain unchanged") }
        }
        for i in stride(from: 0, to: before.count, by: 4) {
            XCTAssertEqual(after[i+3], before[i+3], accuracy: 1e-7)
            XCTAssertTrue(after[i..<i+4].allSatisfy(\.isFinite))
        }
    }
    func testHueSelectionAndTransparentNeighborsCannotBecomeFringeEvidence() throws {
        let before = fixture(), input = image(before, width: 80, height: 40)
        var settings = ManualDefringe(); settings.purpleAmount = 100; settings.purpleLower = 200; settings.purpleUpper = 230
        let after = pixels(try ManualDefringePipeline.apply(input, settings, sourceSize: input.extent.size))
        for i in before.indices { XCTAssertEqual(after[i], before[i], accuracy: 1e-6) }
        var isolated = Array(repeating: Float(0), count: 9 * 9 * 4)
        let index = (4 * 9 + 4) * 4
        isolated.replaceSubrange(index..<index+4, with: [0.5, 0.15, 0.6, 1])
        settings = ManualDefringe(); settings.purpleAmount = 100
        let output = pixels(try ManualDefringePipeline.apply(image(isolated, width: 9, height: 9), settings, sourceSize: CGSize(width: 9, height: 9)))
        for i in isolated.indices { XCTAssertEqual(output[i], isolated[i], accuracy: 1e-6) }
    }
    func testPastePresetGroupPreviewAndBaselineOwnTheNewOperation() throws {
        var source = recipe(); source.manualDefringe.purpleAmount = 40; source.manualDefringe.greenLower = 70
        let target = recipe()
        var options = RecipePasteOptions(); options.tone = false; options.whiteBalance = false; options.color = false; options.curves = false; options.zones = false
        XCTAssertEqual(try target.pasting(source, options: options), target)
        options.generalDetails = true
        XCTAssertEqual(try target.pasting(source, options: options).defringe, source.defringe)
        let half = try target.applyingPreset(source, options: options, amount: 0.5)
        XCTAssertEqual(half.manualDefringe.purpleAmount, 20)
        XCTAssertEqual(half.manualDefringe.greenLower, 75)
        var extremes = source; extremes.manualDefringe.purpleLower = 200; extremes.manualDefringe.purpleUpper = 210
        try target.applyingPreset(extremes, options: options, amount: 2).validate()
        XCTAssertEqual(DevelopGroup.defringe.previewRecipe(in: source), target)
        XCTAssertTrue(source.modifiedDevelopGroups.contains(.defringe))
        XCTAssertNil(source.baseline().defringe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(source)), source)
    }
    func testSamplingPinsNativeHueAndPreservesUnrelatedParameters() throws {
        var r = recipe(); r.exposure = 1; r.develop.mixer[6].hue = 50; r.develop.blackAndWhite = true
        let rgb = SIMD3<Double>(0.5, 0.15, 0.6)
        let sample = try XCTUnwrap(TargetedAdjustment.defringePurple.sample(rgb: rgb, recipe: r))
        XCTAssertNil(TargetedAdjustment.defringeGreen.sample(rgb: rgb, recipe: r))
        XCTAssertNil(TargetedAdjustment.defringePurple.sample(rgb: SIMD3(repeating: 0.4), recipe: r))
        XCTAssertNil(TargetedAdjustment.defringePurple.sample(rgb: SIMD3(.nan, 1, 1), recipe: r))
        XCTAssertNotNil(TargetedAdjustment.defringePurple.sample(rgb: SIMD3(-0.5, 0.2, 0.8), recipe: r), "Hue uses the same nonnegative encoding as the shader")
        XCTAssertNil(TargetedAdjustment.defringeGreen.sample(rgb: SIMD3(-0.5, 0.2, 0.8), recipe: r))
        XCTAssertEqual(try sample.applying(delta: 0, to: r).manualDefringe.purpleAmount, 25)
        XCTAssertEqual(try sample.applying(delta: -100, to: r).manualDefringe.purpleAmount, 0)
        let result = try sample.applying(delta: 200, to: r)
        XCTAssertEqual(result.manualDefringe.purpleAmount, 100)
        XCTAssertEqual(result.manualDefringe.purpleUpper - result.manualDefringe.purpleLower, 30)
        var restored = result; restored.defringe = r.defringe; XCTAssertEqual(restored, r)
        let reference = TargetedAdjustment.defringePurple.referenceRecipe(r)
        XCTAssertNil(reference.defringe); XCTAssertEqual(reference.develop, DevelopAdjustments())
        XCTAssertEqual(reference.exposure, r.exposure); XCTAssertEqual(reference.crop, r.crop)
        let pixels: [Float] = [0,0,0,1, 0.5,0.15,0.6,1, 0,0,0,1]
        let tiny = PointColorReference(width: 3, height: 1, rgba: pixels)
        let exact = try XCTUnwrap(tiny.linearRGB(at: CGPoint(x: 0.5, y: 0.5), radius: 0))
        XCTAssertEqual(exact.x, 0.5); XCTAssertLessThan(try XCTUnwrap(tiny.linearRGB(at: CGPoint(x: 0.5, y: 0.5))).x, exact.x)
    }
    func testSharedRenderingAndSamplingKeepCropPerspectiveRotationAndAlpha() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url: f.source, bookmark: AccessLease.bookmark(f.source, readOnly: true))
        let file = f.source.appendingPathComponent("fringe.png")
        try context.writePNGRepresentation(of: image(fixture(), width: 80, height: 40), to: file, format: .RGBA16, colorSpace: space)
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: f.source)
        let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        for turn in 0..<4 {
            var r = baseline; r.manualDefringe.purpleAmount = 100; r.manualDefringe.greenAmount = 100
            r.quarterTurns = turn; r.flipHorizontal = turn % 2 == 0
            r.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            r.perspective = PerspectiveSettings(horizontal: 12, vertical: -10, aspect: 5, constrainCrop: false)
            let neutral = TargetedAdjustment.defringePurple.referenceRecipe(r)
            let request = ImageRequest(photo: photo, root: root, recipe: r)
            let quality = try await pipeline.render(request, longEdge: nil, pixelFormat: .RGBAf)
            let draft = try await pipeline.renderInteractive(request, longEdge: 200)
            let sixteen = try await pipeline.render(request, longEdge: nil, pixelFormat: .RGBA16)
            XCTAssertEqual(sixteen.image.bitsPerComponent, 16)
            XCTAssertEqual(quality.image.width, draft.image.width); XCTAssertEqual(quality.image.height, draft.image.height)
            let a = pixels(CIImage(cgImage: quality.image)), b = pixels(CIImage(cgImage: draft.image))
            for i in a.indices { XCTAssertEqual(a[i], b[i], accuracy: 0.015, "Same graph, with draft 8-bit quantization") }
            let integer = pixels(CIImage(cgImage: sixteen.image))
            for i in a.indices { XCTAssertEqual(a[i], integer[i], accuracy: 0.0001, "TIFF16 quantizes the floating graph directly") }
            let reference = try await pipeline.pointColorReference(ImageRequest(photo: photo, root: root, recipe: neutral), longEdge: 200, nativeDecode: true)
            let shown = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: neutral), longEdge: nil, pixelFormat: .RGBAf)
            let display = PointColorReference(width: shown.image.width, height: shown.image.height, rgba: pixels(CIImage(cgImage: shown.image)))
            for point in [CGPoint(x: 0.35, y: 0.4), CGPoint(x: 0.65, y: 0.6)] {
                let expected = try XCTUnwrap(display.linearRGB(at: point, radius: 0))
                let actual = try XCTUnwrap(reference.linearRGB(at: point, radius: 0))
                for channel in 0..<3 { XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.003, "Output geometry at turn \(turn)") }
            }
        }
        XCTAssertEqual(try SafeFileWriter.sha256(file), baseline.sourceDigest)
    }

    func testPublicSonyRAWManualStageDoesNotReuseStaleSpatialPixels() async throws {
        try await checkPublicRAW("a7iii_12bit_compressed.ARW")
    }
    func testPublicLeicaRAWManualStageDoesNotReuseStaleSpatialPixels() async throws {
        try await checkPublicRAW("leica_m8_8bit_uncompressed.DNG")
    }
    private func checkPublicRAW(_ name: String) async throws {
        let input = try MoreRAWTests.request(name), pipeline = ImagePipeline()
        var r = try await pipeline.baseline(input)
        r.manualDefringe.purpleAmount = 100; r.manualDefringe.greenAmount = 100
        r.manualDefringe.purpleLower = 200; r.manualDefringe.purpleUpper = 360
        r.manualDefringe.greenLower = 40; r.manualDefringe.greenUpper = 200
        let activeRequest = ImageRequest(photo: input.photo, root: input.root, recipe: r)
        let active = try await pipeline.renderInteractive(activeRequest, longEdge: 768)
        let neutralRequest = ImageRequest(photo: input.photo, root: input.root, recipe: r.baseline())
        let neutral = try await pipeline.renderInteractive(neutralRequest, longEdge: 768)
        let freshNeutral = try await ImagePipeline().renderInteractive(neutralRequest, longEdge: 768)
        let activeAgain = try await pipeline.renderInteractive(activeRequest, longEdge: 768)
        let freshActive = try await ImagePipeline().renderInteractive(activeRequest, longEdge: 768)
        func bytes(_ value: RenderedImage) throws -> Data { try XCTUnwrap(value.image.dataProvider?.data) as Data }
        XCTAssertEqual(try bytes(neutral), try bytes(freshNeutral)); XCTAssertEqual(try bytes(activeAgain), try bytes(freshActive))
        let a = try bytes(active), b = try bytes(neutral)
        print("DEFRINGE_RAW \(name) changedBytes=\(zip(a,b).filter { $0 != $1 }.count) total=\(a.count); native cache comparison, not Adobe equivalence")
        let file = URL(fileURLWithPath: input.root.path).appendingPathComponent(input.photo.relativePath)
        XCTAssertEqual(try SafeFileWriter.sha256(file), r.sourceDigest)
    }

    func testOptionalPublicDomainPurpleFringeImage() throws {
        // Kitkatcrazy's public-domain crop, not a RAW or a colorimetric target:
        // https://commons.wikimedia.org/wiki/File:Purple_fringing.jpg
        guard let file = Bundle(for: Self.self).url(forResource: "Purple_fringing", withExtension: "jpg", subdirectory: "PublicDomainFringe") else {
            throw XCTSkip("Optional hash-verified public-domain purple fringe photograph is not staged")
        }
        XCTAssertEqual(try SafeFileWriter.sha256(file), "f59a589a8f88f6cb2dc18145325e031dd0334de1de001f377e298d5618fd8f37")
        let input = try XCTUnwrap(CIImage(contentsOf: file))
        var settings = ManualDefringe(); settings.purpleAmount = 100; settings.purpleLower = 200; settings.purpleUpper = 350
        let output = try ManualDefringePipeline.apply(input, settings, sourceSize: input.extent.size)
        let before = pixels(input), after = pixels(output)
        var changed = 0
        for i in stride(from: 0, to: before.count, by: 4) {
            if (0..<3).contains(where: { abs(before[i+$0] - after[i+$0]) > 1e-6 }) { changed += 1 }
        }
        print("DEFRINGE_PUBLIC changedPixels=\(changed) total=\(before.count / 4) amount=100 hue=200...350; no photographic acceptance threshold")
        XCTAssertGreaterThan(changed, 0, "The declared photographic fixture must exercise the active operation")
        for (name, image) in [("public-fringe-before", input), ("public-fringe-after", output)] {
            let cg = try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
            let attachment = XCTAttachment(image: NSImage(cgImage: cg, size: .zero)); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertEqual(try SafeFileWriter.sha256(file), "f59a589a8f88f6cb2dc18145325e031dd0334de1de001f377e298d5618fd8f37")
    }

    func testNativeFringeReferenceKeepsOnePixelColorInsideATightCrop() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url: f.source, bookmark: AccessLease.bookmark(f.source, readOnly: true))
        let file = f.source.appendingPathComponent("thin-crop.png")
        let rgba = (0..<(512 * 64)).flatMap { i -> [Float] in i % 512 == 255 ? [0.5, 0.15, 0.6, 1] : [0.2, 0.2, 0.2, 1] }
        try context.writePNGRepresentation(of: image(rgba, width: 512, height: 64), to: file, format: .RGBA16, colorSpace: space)
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: f.source), pipeline = ImagePipeline()
        var r = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        r.crop = Crop(x: 252.0/512, y: 0, width: 8.0/512, height: 1)
        let reference = try await pipeline.pointColorReference(ImageRequest(photo: photo, root: root, recipe: r), longEdge: 128, nativeDecode: true)
        XCTAssertEqual(reference.width, 8); XCTAssertEqual(reference.height, 64)
        let rgb = try XCTUnwrap(reference.linearRGB(at: CGPoint(x: 3.5/8, y: 0.5), radius: 0))
        XCTAssertEqual(rgb.x, 0.5, accuracy: 0.003); XCTAssertEqual(rgb.y, 0.15, accuracy: 0.003); XCTAssertEqual(rgb.z, 0.6, accuracy: 0.003)
        XCTAssertNotNil(TargetedAdjustment.defringePurple.sample(rgb: rgb, recipe: r))
    }

    @MainActor func testDefringePanelFitsInspectorWidthsAndRetainsSixNumericControls() async throws {
        var value = recipe(); value.manualDefringe.purpleAmount = 1
        let model = AppModel(); model.recipe = value; model.canEdit = true; model.editMode = true
        let suite = "defringe-layout-" + UUID().uuidString, prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(true, forKey: "developDefringeOpen"); prefs.set(true, forKey: "developShowOnlyModified")
        func sliders(_ view: NSView) -> [AdjustmentNSSlider] { (view as? AdjustmentNSSlider).map { [$0] } ?? view.subviews.flatMap(sliders) }
        for theme in [ChromeTheme.ivory, .graphite] {
            prefs.set(theme.rawValue, forKey: "chromeTheme")
            for width in [304.0, 336, 400] {
                let size = CGSize(width: width, height: 640)
                let host = NSHostingView(rootView: ScrollView { DevelopPanel(model: model) }
                    .frame(width: width, height: size.height).background(Theme.panel).defaultAppStorage(prefs).preferredColorScheme(theme.colorScheme))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua); window.contentView = host
                try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
                XCTAssertEqual(sliders(host).count, 6)
                for slider in sliders(host) { XCTAssertFalse(slider.accessibilityLabel()?.isEmpty ?? true) }
                if width == 304 {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                    let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                    attachment.name = "defringe-\(L10n.current.language)-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
                }
                window.contentView = nil
            }
        }
    }
}

extension DirectAdjustmentTests {
    @MainActor func testNativeDefringeClickSavesOnceCancelRestoresAndZeroNudgeDoesNotRestartSuggestion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("defringe-click-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await makeModel(folder), catalog = try XCTUnwrap(model.catalog), original = try XCTUnwrap(model.recipe)
        defer { model.choose([], active: nil) }
        model.targetedReferenceRenderer = { _ in PointColorReference(width: 1, height: 1, rgba: [0.5, 0.15, 0.6, 1]) }
        model.toggleTargetedAdjustment(.defringePurple); try await waitUntil { model.targetedReferenceReady }
        let view = PhotoMetalCanvas(); view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; defer { window.contentView = nil }
        view.source = model.image; view.targetedToolID = "defringe-purple"
        view.onTargetBegin = { model.beginTargetedAdjustment(at: $0) }
        view.onTargetChange = { model.updateTargetedAdjustment(delta: $0) }
        view.onTargetEnd = { if $0 { model.cancelDirectAdjustment() } else { _ = model.finishDirectAdjustment() } }
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: 150, y: 100), to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let history = try catalog.editHistory(photoID: "a").count
        view.mouseDown(with: try event(.leftMouseDown))
        XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 25)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, history)
        view.cancelTargetGesture(); XCTAssertEqual(model.recipe, original)
        view.mouseDown(with: try event(.leftMouseDown)); view.mouseUp(with: try event(.leftMouseUp))
        XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 25)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, history + 1)
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        model.updateTargetedAdjustment(delta: -100); XCTAssertTrue(model.finishDirectAdjustment())
        let saved = try catalog.editHistory(photoID: "a").count
        XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 0)
        XCTAssertTrue(model.nudgeTargetedAdjustment(-1)); XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 0)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, saved)
        XCTAssertTrue(model.nudgeTargetedAdjustment(1)); XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 1)
    }
    @MainActor func testLateDefringeReferenceCannotReturnAfterPhotoOrToolChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("defringe-late-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await makeModel(folder)
        defer { model.choose([], active: nil) }
        model.targetedReferenceRenderer = { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return PointColorReference(width: 1, height: 1, rgba: [0.5, 0.15, 0.6, 1])
        }
        model.toggleTargetedAdjustment(.defringePurple)
        model.choose(["b"], active: "b"); try await waitUntil { model.activeID == "b" && model.canEdit }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.targetedAdjustment); XCTAssertNil(model.targetedReference); XCTAssertFalse(model.targetedReferenceReady)
        model.toggleTargetedAdjustment(.defringePurple); model.toggleWhiteBalanceSampling()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.whiteBalanceSampling); XCTAssertNil(model.targetedAdjustment); XCTAssertFalse(model.targetedReferenceReady)
        model.toggleTargetedAdjustment(.defringeGreen)
        XCTAssertFalse(model.whiteBalanceSampling)
        model.togglePointColorSampling()
        XCTAssertTrue(model.pointSampling); XCTAssertNil(model.targetedAdjustment)
        model.cancelPointColorTools(); model.toggleTargetedAdjustment(.defringePurple)
        _ = model.selectDevelopTool(.crop)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.targetedAdjustment); XCTAssertNil(model.targetedReference); XCTAssertFalse(model.targetedReferenceReady)
    }
    @MainActor func testDefringeDragCommitsOnceAndCancelUndoAndPhotoSwitchStayIsolated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("defringe-drag-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await makeModel(folder), catalog = try XCTUnwrap(model.catalog), original = try XCTUnwrap(model.recipe)
        defer { model.choose([], active: nil) }
        model.targetedReferenceRenderer = { _ in PointColorReference(width: 1, height: 1, rgba: [0.5, 0.15, 0.6, 1]) }
        model.toggleTargetedAdjustment(.defringePurple); try await waitUntil { model.targetedReferenceReady }
        let history = try catalog.editHistory(photoID: "a").count
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        model.updateTargetedAdjustment(delta: 25); model.updateTargetedAdjustment(delta: 40)
        XCTAssertTrue(model.finishDirectAdjustment()); XCTAssertEqual(try catalog.editHistory(photoID: "a").count, history + 1)
        XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 65)
        model.undo.undo(); XCTAssertEqual(model.recipe, original)
        model.undo.redo(); XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 65)
        model.toggleTargetedAdjustment(.defringePurple); try await waitUntil { model.targetedReferenceReady }
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        model.updateTargetedAdjustment(delta: 10); model.cancelDirectAdjustment()
        XCTAssertEqual(model.recipe?.manualDefringe.purpleAmount, 65)
        let saved = try catalog.photo("a")?.recipe
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        model.updateTargetedAdjustment(delta: 20); model.choose(["b"], active: "b")
        try await waitUntil { model.activeID == "b" && model.canEdit }
        XCTAssertNil(model.targetedAdjustment); XCTAssertNil(model.targetedSample); XCTAssertNil(model.directAdjustment)
        XCTAssertEqual(try catalog.photo("a")?.recipe, saved); XCTAssertNil(model.recipe?.defringe)
    }
}
