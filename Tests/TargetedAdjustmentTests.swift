import XCTest
import AppKit
import CoreImage
@testable import Phosdeck

final class TargetedAdjustmentTests: XCTestCase {
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
            baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    func testHSLSamplesAdjacentBandsWrapsAndPreservesOtherParameters() throws {
        let r = recipe()
        for hue in [0.0, 15, 30, 330] {
            let rgb = PerceptualColor.linear(DevelopPipeline.rgb(SIMD3(hue, 1, 0.5)))
            let sample = try XCTUnwrap(TargetedAdjustment.saturation.sample(rgb: rgb, recipe: r))
            XCTAssertEqual(sample.weights.reduce(0, +), 1, accuracy: 1e-12)
            let result = try sample.applying(delta: 40, to: r)
            let expected: [Double] = hue == 0 ? [40, 0, 0, 0, 0, 0, 0, 0] : hue == 15 ? [20, 20, 0, 0, 0, 0, 0, 0] : hue == 30 ? [0, 40, 0, 0, 0, 0, 0, 0] : [20, 0, 0, 0, 0, 0, 0, 20]
            for i in 0..<8 { XCTAssertEqual(result.develop.mixer[i].saturation, expected[i], accuracy: 1e-10) }
            var preserved = result; preserved.develop.mixer = r.develop.mixer
            XCTAssertEqual(preserved, r)
            XCTAssertEqual(try sample.applying(delta: 0, to: r), r)
        }
        XCTAssertNil(TargetedAdjustment.hue.sample(rgb: SIMD3(repeating: 0.2), recipe: r))
        XCTAssertNil(TargetedAdjustment.hue.sample(rgb: SIMD3(.nan, 0, 0), recipe: r))
        let red = try XCTUnwrap(TargetedAdjustment.luminance.sample(rgb: SIMD3(1, 0, 0), recipe: r))
        XCTAssertEqual(try red.applying(delta: 1000, to: r).develop.mixer[0].luminance, 100)
        XCTAssertEqual(try red.applying(delta: -1000, to: r).develop.mixer[0].luminance, -100)
    }
    func testBlackWhiteUsesPostHSLHueAndRejectsColorlessInputs() throws {
        var r = recipe(); r.develop.blackAndWhite = true
        let red = SIMD3<Double>(1, 0, 0)
        let first = try XCTUnwrap(TargetedAdjustment.blackWhite.sample(rgb: red, recipe: r))
        XCTAssertEqual(first.weights[0], 1, accuracy: 1e-12)
        let adjusted = try first.applying(delta: 30, to: r)
        XCTAssertEqual(adjusted.develop.blackWhiteMixer[0], 30, accuracy: 1e-12)
        XCTAssertEqual(adjusted.develop.mixer, r.develop.mixer)
        r.develop.mixer[0].hue = 100
        let shifted = try XCTUnwrap(TargetedAdjustment.blackWhite.sample(rgb: red, recipe: r))
        XCTAssertNotEqual(first.weights, shifted.weights, "Selection follows HSL, rather than the original red band")
        XCTAssertEqual(shifted.weights.reduce(0, +), 1, accuracy: 1e-12)
        r.saturation = 0
        XCTAssertNil(TargetedAdjustment.blackWhite.sample(rgb: red, recipe: r))
        r.saturation = 1; r.develop.mixer[0].saturation = -100
        XCTAssertNil(TargetedAdjustment.blackWhite.sample(rgb: red, recipe: r))
        XCTAssertNil(TargetedAdjustment.blackWhite.sample(rgb: SIMD3(repeating: 0.2), recipe: r))
        r.develop.blackAndWhite = false
        XCTAssertNil(TargetedAdjustment.blackWhite.sample(rgb: red, recipe: r))
    }
    func testCurveSampleInsertsOrReusesOnePointAndRetainsIrregularCurve() throws {
        var r = recipe(), curves = ToneCurves()
        curves.channels[0] = [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 0.25, y: 0.4), CurvePoint(x: 0.8, y: 0.9), CurvePoint(x: 1, y: 1)]
        r.develop.curves = curves
        let rgb = PerceptualColor.linear(SIMD3(repeating: 0.4))
        let sample = try XCTUnwrap(TargetedAdjustment.curve(0).sample(rgb: rgb, recipe: r))
        XCTAssertEqual(try XCTUnwrap(sample.curveInput), 0.4, accuracy: 1e-10)
        let adjusted = try XCTUnwrap(sample.applying(delta: 10, to: r).develop.curves)
        XCTAssertEqual(adjusted.channels[0].count, 5)
        for point in curves.channels[0] { XCTAssertTrue(adjusted.channels[0].contains(point)) }
        let inserted = try XCTUnwrap(adjusted.channels[0].first { abs($0.x - 0.4) < 1e-10 })
        XCTAssertEqual(inserted.y, TonalPipeline.evaluate(curves.channels[0], at: 0.4) + 0.1, accuracy: 1e-10)
        XCTAssertEqual(Array(adjusted.channels.dropFirst()), Array(curves.channels.dropFirst()))
        let near = TargetedSample(target: .curve(0), weights: [], curveInput: 0.2504)
        let reused = try XCTUnwrap(near.applying(delta: -20, to: r).develop.curves)
        XCTAssertEqual(reused.channels[0].count, 4); XCTAssertEqual(reused.channels[0][1], CurvePoint(x: 0.25, y: 0.2))
        XCTAssertEqual(try sample.applying(delta: 0, to: r), r)
        curves.channels[0] = (0..<16).map { CurvePoint(x: Double($0) / 15, y: Double($0) / 15) }; r.develop.curves = curves
        let full = TargetedSample(target: .curve(0), weights: [], curveInput: 0.413)
        XCTAssertThrowsError(try full.applying(delta: 10, to: r))
        let endpoint = TargetedSample(target: .curve(0), weights: [], curveInput: 1)
        XCTAssertEqual(try endpoint.applying(delta: 10, to: r), r, "A clamped endpoint must not create a changed recipe")
    }
    func testRGBChannelSampleIncludesPrecedingLuminanceCurve() throws {
        var r = recipe(), curves = ToneCurves()
        curves.channels[0] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.75), CurvePoint(x: 1, y: 1)]
        r.develop.curves = curves
        let rgb = PerceptualColor.linear(SIMD3(repeating: 0.5))
        let sample = try XCTUnwrap(TargetedAdjustment.curve(1).sample(rgb: rgb, recipe: r))
        XCTAssertEqual(try XCTUnwrap(sample.curveInput), 0.75, accuracy: 1e-7)
    }
    func testReferencePrefixExcludesSelfDownstreamAndPreservesGeometry() {
        var r = recipe(); r.exposure = 1; r.contrast = 1.2; r.develop.curves = ToneCurves()
        r.develop.curves?.channels[0][2].y = 0.6
        let hsl = TargetedAdjustment.hue.referenceRecipe(r), curve = TargetedAdjustment.curve(0).referenceRecipe(r)
        r.develop.mixer[0].hue = 80; r.develop.pointColors = [PointColor(lightness: 0.5, chroma: 0.1, hue: 30)]
        r.develop.blackAndWhite = true; r.develop.blackWhiteMixer[0] = 30; r.saturation = 0.3
        r.develop.vibrance = 100; r.develop.grading.global.saturation = 80; r.vignette.amount = -40; r.grain.amount = 30
        XCTAssertEqual(TargetedAdjustment.hue.referenceRecipe(r), hsl)
        XCTAssertEqual(TargetedAdjustment.blackWhite.referenceRecipe(r), hsl)
        XCTAssertEqual(TargetedAdjustment.curve(2).referenceRecipe(r), curve)
        r.crop = Crop(x: 0.1, y: 0.2, width: 0.8, height: 0.7)
        r.perspective = PerspectiveSettings(horizontal: 30, vertical: -20)
        XCTAssertEqual(TargetedAdjustment.hue.referenceRecipe(r).crop, r.crop)
        XCTAssertEqual(TargetedAdjustment.hue.referenceRecipe(r).perspective, r.perspective)
        XCTAssertNotEqual(TargetedAdjustment.hue.referenceRecipe(r), hsl)
    }
    func testSamplingReferenceUsesNativeCropPerspectiveRotationAndFlips() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url: f.source, bookmark: AccessLease.bookmark(f.source, readOnly: true))
        let file = f.source.appendingPathComponent("target-gradient.png")
        let width = 96, height = 64
        let values = (0..<(width * height)).flatMap { index -> [Float] in
            [Float(0.1 + 0.8 * (Double(index % width) + 0.5) / Double(width)),
             Float(0.1 + 0.8 * (Double(index / width) + 0.5) / Double(height)), 0.2, 1]
        }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let image = values.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space) }
        try CIContext().writePNGRepresentation(of: image, to: file, format: .RGBA16, colorSpace: space)
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: f.source)
        let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        for turn in 0..<4 {
            var r = baseline
            r.quarterTurns = turn; r.flipHorizontal = turn % 2 == 0; r.flipVertical = turn % 2 != 0
            r.crop = Crop(x: 0.12, y: 0.15, width: 0.75, height: 0.7)
            r.straightenDegrees = 3
            r.perspective = PerspectiveSettings(horizontal: 20, vertical: -15, aspect: 10, constrainCrop: false)
            let input = TargetedAdjustment.hue.referenceRecipe(r)
            let reference = try await pipeline.pointColorReference(ImageRequest(photo: photo, root: root, recipe: input), longEdge: 256)
            // Sampling must follow actual native output geometry, without an
            // independently reconstructed inverse rotation. The existing source
            // inverse differs at odd quarter-turns (recorded in STATUS).
            let rendered = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: input), longEdge: nil, pixelFormat: .RGBAf)
            for point in [CGPoint(x: 0.35, y: 0.4), CGPoint(x: 0.65, y: 0.6)] {
                // Read a small CI-coordinate rectangle independently of the
                // full-bitmap sampler, so a shared row-order bug cannot agree
                // with itself on both sides of the comparison.
                let x = PhotoGeometry.pixelIndex(point.x, dimension: rendered.image.width)
                let y = PhotoGeometry.pixelIndex(point.y, dimension: rendered.image.height)
                var pixels = [Float](repeating: 0, count: 3 * 3 * 4)
                CIContext(options: [.workingFormat: CIFormat.RGBAf]).render(CIImage(cgImage: rendered.image), toBitmap: &pixels,
                    rowBytes: 3 * 16, bounds: CGRect(x: x - 1, y: y - 1, width: 3, height: 3), format: .RGBAf, colorSpace: space)
                var expected = SIMD3<Double>.zero, coverage = 0.0
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    expected += SIMD3(Double(pixels[i]), Double(pixels[i+1]), Double(pixels[i+2])); coverage += Double(pixels[i+3])
                }
                expected /= coverage
                let rgb = try XCTUnwrap(reference.linearRGB(at: point))
                for channel in 0..<3 { XCTAssertEqual(rgb[channel], expected[channel], accuracy: 0.003, "Reference matches displayed crop/perspective/rotation/flip at turn \(turn)") }
            }
        }
    }

    @MainActor func testNativeCanvasSamplesVisibleUpperAndLowerColorsInFitZoomAndPan() throws {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let purple = SIMD3<Double>(0.5, 0.15, 0.6), green = SIMD3<Double>(0.1, 0.5, 0.1)
        func block(_ rgb: SIMD3<Double>, _ y: Double) -> CIImage {
            CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1, colorSpace: space)!)
                .cropped(to: CGRect(x: 0, y: y, width: 96, height: 32))
        }
        let image = block(purple, 32).composited(over: block(green, 0)), context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        let cg = try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBAf, colorSpace: space))
        var pixels = [Float](repeating: 0, count: 96 * 64 * 4)
        context.render(image, toBitmap: &pixels, rowBytes: 96 * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
        let reference = PointColorReference(width: 96, height: 64, rgba: pixels)
        let view = PhotoMetalCanvas(); view.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; defer { window.contentView = nil }
        view.source = cg
        func event(_ type: NSEvent.EventType, _ fractionY: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: 150, y: 200 * fractionY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        for targeted in [true, false] {
            view.targetedToolID = targeted ? "defringe-purple" : nil
            var sampled: SIMD3<Double>?
            // Target adjustment and the existing point-color picker share this
            // floating reference; the canvas must deliver the same coordinates.
            view.onTargetBegin = { sampled = reference.linearRGB(at: $0, radius: 0); return true }
            view.onZoneSample = { sampled = reference.linearRGB(at: $0, radius: 0) }
            for zoomed in [false, true] {
                view.actualPixels = zoomed; view.nativeSize = CGSize(width: 600, height: 400); view.zoomScale = 2
                for upper in [true, false] {
                    view.displayCenter = CGPoint(x: 0.5, y: upper ? 0.25 : 0.75)
                    let fractionY = zoomed ? 0.5 : upper ? 0.75 : 0.25
                    view.mouseDown(with: try event(.leftMouseDown, fractionY)); view.mouseUp(with: try event(.leftMouseUp, fractionY))
                    let rgb = try XCTUnwrap(sampled), expected = upper ? purple : green
                    for channel in 0..<3 { XCTAssertEqual(rgb[channel], expected[channel], accuracy: 1e-6) }
                }
            }
        }
    }

    func testFloatingSampleRejectsTransparentCenterAndUsesCoverage() throws {
        let pixels: [Float] = [0.5, 0, 0, 0.5, 1, 0, 0, 1, 0, 0, 0, 0]
        let ref = PointColorReference(width: 3, height: 1, rgba: pixels)
        XCTAssertEqual(try XCTUnwrap(ref.linearRGB(at: CGPoint(x: 0.5, y: 0.5))), SIMD3(1, 0, 0))
        XCTAssertNil(ref.linearRGB(at: CGPoint(x: 1, y: 0.5)))
        XCTAssertNil(ref.linearRGB(at: CGPoint(x: -0.01, y: 0.5)))
        let rows = PointColorReference(width: 1, height: 2, rgba: [0.5,0,0,0.5, 0,1,0,1])
        XCTAssertEqual(rows.linearRGB(at: CGPoint(x: 0.5, y: 0), radius: 0), SIMD3(0, 1, 0))
        XCTAssertEqual(rows.linearRGB(at: CGPoint(x: 0.5, y: 0.5), radius: 0), SIMD3(1, 0, 0))
        XCTAssertEqual(rows.linearRGB(at: CGPoint(x: 0.5, y: 1 - Double.ulpOfOne), radius: 0), SIMD3(1, 0, 0))
        let transparentTop = PointColorReference(width: 1, height: 2, rgba: [0,0,0,0, 0,1,0,1])
        XCTAssertNil(transparentTop.linearRGB(at: CGPoint(x: 0.5, y: 0.75)), "A transparent upper center must not borrow a lower color")
    }
}

extension DirectAdjustmentTests {
    @MainActor func testTargetedDragOnceCancelReturnToOriginAndKeyboard() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await makeModel(folder)
        defer { model.choose([], active: nil) }
        model.targetedReferenceRenderer = { _ in PointColorReference(width: 1, height: 1, rgba: [1, 0, 0, 1]) }
        model.undo.groupsByEvent = false
        model.toggleTargetedAdjustment(.saturation)
        try await waitUntil { model.targetedReferenceReady }
        let original = model.recipe, catalog = try XCTUnwrap(model.catalog)
        let history = try catalog.editHistory(photoID: "a").count
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        for delta in [10.0, 30, 50] { model.updateTargetedAdjustment(delta: delta) }
        XCTAssertEqual(model.recipe?.develop.mixer[0].saturation, 50)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, history)
        model.cancelDirectAdjustment(); XCTAssertEqual(model.recipe, original)
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        model.updateTargetedAdjustment(delta: 10); model.updateTargetedAdjustment(delta: 0)
        XCTAssertTrue(model.finishDirectAdjustment()); XCTAssertEqual(model.recipe, original)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, history); XCTAssertFalse(model.undo.canUndo)
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        model.updateTargetedAdjustment(delta: 40); XCTAssertTrue(model.finishDirectAdjustment())
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, history + 1)
        XCTAssertTrue(model.nudgeTargetedAdjustment(1)); XCTAssertEqual(model.recipe?.develop.mixer[0].saturation, 41)
        model.undo.undo(); XCTAssertEqual(model.recipe?.develop.mixer[0].saturation, 40)
        model.undo.undo(); XCTAssertEqual(model.recipe, original)
        model.undo.redo(); XCTAssertEqual(model.recipe?.develop.mixer[0].saturation, 40)
    }

    @MainActor func testTargetedPhotoSwitchAndLateReferenceCannotCrossPhotosOrTools() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await makeModel(folder)
        defer { model.choose([], active: nil) }
        model.targetedReferenceRenderer = { _ in
            try? await Task.sleep(for: .milliseconds(100)) // Deliberately ignores cancellation.
            return PointColorReference(width: 1, height: 1, rgba: [1, 0, 0, 1])
        }
        model.toggleTargetedAdjustment(.hue)
        model.choose(["b"], active: "b")
        try await waitUntil { model.canEdit && model.activeID == "b" }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.targetedAdjustment); XCTAssertFalse(model.targetedReferenceReady)
        XCTAssertNil(model.targetedReference); XCTAssertNil(model.targetedSample)
        model.toggleTargetedAdjustment(.hue); try await waitUntil { model.targetedReferenceReady }
        XCTAssertTrue(model.beginTargetedAdjustment(at: CGPoint(x: 0.5, y: 0.5)))
        model.updateTargetedAdjustment(delta: 60)
        let history = try model.catalog?.editHistory(photoID: "b").count
        model.choose(["a"], active: "a"); try await waitUntil { model.canEdit && model.activeID == "a" }
        XCTAssertNil(model.targetedAdjustment); XCTAssertNil(model.directAdjustment)
        XCTAssertFalse(model.finishDirectAdjustment()); XCTAssertEqual(model.recipe?.develop.mixer[0].hue, 0)
        XCTAssertEqual(try model.catalog?.editHistory(photoID: "b").count, history)
        model.toggleTargetedAdjustment(.hue); model.toggleZoneSampling()
        XCTAssertNil(model.targetedAdjustment); XCTAssertFalse(model.targetedReferenceReady)
        model.cancelZoneSampling()
    }

    @MainActor func testNativeTargetDragFineCancelAndDisplayedCoordinateMapping() throws {
        let view = PhotoMetalCanvas()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; view.frame = window.contentView!.bounds
        defer { window.contentView = nil }
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40))
        view.source = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent))
        view.targetedToolID = "hue"
        var ends = [Bool](), changes = [Double](), samples = [CGPoint]()
        view.onTargetBegin = { samples.append($0); return true }; view.onTargetEnd = { ends.append($0) }; view.onTargetChange = { changes.append($0) }
        func event(_ type: NSEvent.EventType, _ y: Double, fine: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: 150, y: y), to: nil), modifierFlags: fine ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, 100)); view.mouseDragged(with: try event(.leftMouseDragged, 120))
        view.mouseDragged(with: try event(.leftMouseDragged, 130, fine: true))
        XCTAssertEqual(abs(try XCTUnwrap(changes.last)), 10.5, accuracy: 1e-10)
        view.mouseUp(with: try event(.leftMouseUp, 130, fine: true)); XCTAssertEqual(ends, [false])
        view.mouseDown(with: try event(.leftMouseDown, 100)); view.cancelTargetGesture(); XCTAssertEqual(ends, [false, true])
        let previousControl = NSSlider(frame: CGRect(x: 0, y: 0, width: 80, height: 20))
        view.addSubview(previousControl); XCTAssertTrue(window.makeFirstResponder(previousControl))
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(window.firstResponder === view, "AX sampling must take focus from the previous parameter or histogram control")
        XCTAssertEqual(ends, [false, true, false], "AX press selects a sample without leaving a draft")
        view.mouseDown(with: try event(.leftMouseDown, 100)); window.contentView = nil; XCTAssertEqual(ends, [false, true, false, true])
        XCTAssertEqual(samples.first?.x ?? -1, 0.5, accuracy: 1e-8)
        XCTAssertEqual(samples.first?.y ?? -1, 0.5, accuracy: 1e-8)
        // A zoomed/panned image rect can extend outside the visible canvas.
        let p = PhotoMetalCanvas.outputPoint(CGPoint(x: 100, y: 60), in: CGRect(x: -100, y: -40, width: 800, height: 400))
        XCTAssertEqual(p, CGPoint(x: 0.25, y: 0.25))
        XCTAssertLessThan(PhotoMetalCanvas.outputPoint(.zero, in: CGRect(x: 50, y: 30, width: 200, height: 100)).x, 0)
    }
}
