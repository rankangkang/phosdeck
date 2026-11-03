import XCTest
import CoreImage
import GRDB
@testable import Phosdeck

final class DevelopTests: XCTestCase {
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 10, temperature: 5500, tint: 10)
    }
    func testLegacyDecodeNewRoundTripAndReset() throws {
        var original = recipe(); original.schemaVersion = 1; original.pipelineVersion = 0; original.contrast = 1.2
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["develop", "straightenDegrees", "cropAspectRatio"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old, original)
        json["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: json)), "New recipes must not silently lose missing edits")
        var new = old; new.schemaVersion = 2
        new.develop.highlights = -70; new.develop.mixer[0].hue = 50
        new.develop.grading.shadows = GradingTone(hue: 220, saturation: 40, luminance: 10)
        new.cropAspectRatio = 1.5; new.straightenDegrees = 12
        try new.validate()
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(new)), new)
        XCTAssertEqual(new.baseline().develop, DevelopAdjustments())
        XCTAssertEqual(new.baseline().straightenDegrees, 0)
        XCTAssertNil(new.baseline().cropAspectRatio)
        XCTAssertEqual(new.baseline().pipelineVersion, 0)
        XCTAssertEqual(new.resetForCurrentPipeline().schemaVersion, 2)
        XCTAssertEqual(new.resetForCurrentPipeline().pipelineVersion, 2)
        new.develop.mixer.removeLast(); XCTAssertThrowsError(try new.validate())
        new = recipe(); new.develop.grading.global.hue = .nan; XCTAssertThrowsError(try new.validate())
        new = recipe(); new.straightenDegrees = 46; XCTAssertThrowsError(try new.validate())
        new = recipe(); new.cropAspectRatio = .infinity; XCTAssertThrowsError(try new.validate())
    }
    @MainActor func testGroupedUndoRedoPersistenceAndInvalidDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        let photo = Photo(id: "edit", rootID: root.id, relativePath: "sample.ARW", identity: Data(), identityKey: "edit-fixture", width: 800, height: 600)
        try catalog.index(photo)
        let model = AppModel(); model.catalog = catalog; model.activeID = photo.id
        model.recipe = recipe(); model.recipe?.pipelineVersion = 1; model.canEdit = true; model.dirty = true
        XCTAssertTrue(model.commitRecipe())
        let baseline = model.recipe!
        model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping()
        model.changeRecipe({ $0.pipelineVersion = 2 }, commit: false)
        model.changeRecipe({ $0.develop.shadows = 10 }, commit: false)
        model.changeRecipe({ $0.develop.shadows = 40 }, commit: false)
        model.changeRecipe({ $0.develop.mixer[5].hue = 20; $0.develop.grading.shadows.saturation = 30 }, commit: false)
        XCTAssertTrue(model.dirty)
        XCTAssertTrue(model.commitRecipe())
        model.undo.endUndoGrouping()
        let edited = model.recipe!
        let data = try XCTUnwrap(catalog.photo(photo.id)?.recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: data), edited)
        model.undo.undo()
        XCTAssertEqual(model.recipe, baseline)
        model.undo.redo()
        XCTAssertEqual(model.recipe, edited)
        model.changeRecipe { $0.develop.shadows = .nan }
        XCTAssertEqual(model.recipe, edited)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.dirty)
        let backup = directory.appendingPathComponent("backup.sqlite")
        try catalog.backup(to: backup)
        let reopened = try CatalogStore.restore(from: backup, to: directory.appendingPathComponent("restored"))
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(reopened.photo(photo.id)?.recipe)), edited)
    }
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    private func patch(_ c: SIMD3<Double>, size: Int = 4) -> CIImage {
        CIImage(color: CIColor(red: c.x, green: c.y, blue: c.z, alpha: 1, colorSpace: ImagePipeline.outputSpace)!).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }
    private func pixel(_ input: CIImage, _ a: DevelopAdjustments, at point: CGPoint = .zero) -> [Float] {
        var rgba = [Float](repeating: 0, count: 4)
        context.render(DevelopPipeline.apply(input, adjustments: a), toBitmap: &rgba, rowBytes: 16,
                       bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)), format: .RGBAf, colorSpace: ImagePipeline.outputSpace)
        return rgba
    }
    func testBasicTonalControlsOnActualCoreImagePixels() {
        for (key, level) in [(\DevelopAdjustments.highlights, 0.8), (\.shadows, 0.2), (\.whites, 0.95), (\.blacks, 0.05)] {
            let source = patch(SIMD3(repeating: level))
            var a = DevelopAdjustments(); a[keyPath: key] = 80
            let raised = pixel(source, a)
            a[keyPath: key] = -80
            let lowered = pixel(source, a)
            XCTAssertGreaterThan(raised[0], Float(level) + 0.01)
            XCTAssertLessThan(lowered[0], Float(level) - 0.01)
            XCTAssertEqual(raised[0], raised[1], accuracy: 0.002)
            XCTAssertEqual(raised[3], 1, accuracy: 0.001)
        }
        var a = DevelopAdjustments(); a.dehaze = 70
        XCTAssertLessThan(pixel(patch(SIMD3(repeating: 0.4)), a)[0], 0.4)
        a = DevelopAdjustments(); a.vibrance = 100
        let c = pixel(patch(SIMD3(0.6, 0.4, 0.4)), a)
        XCTAssertGreaterThan(c[0] - c[1], 0.2)
        a.blackAndWhite = true
        let gray = pixel(patch(SIMD3(0.6, 0.4, 0.4)), a)
        XCTAssertEqual(gray[0], gray[1], accuracy: 0.002)
        XCTAssertEqual(gray[1], gray[2], accuracy: 0.002)
    }
    func testAllEightHSLBandsAndWraparound() {
        for i in 0..<8 {
            let color = DevelopPipeline.rgb(SIMD3(HSLBand.centers[i], 0.7, 0.5))
            let source = patch(color)
            var a = DevelopAdjustments(); a.mixer[i].saturation = -100
            let gray = pixel(source, a)
            XCTAssertLessThan(max(gray[0], max(gray[1], gray[2])) - min(gray[0], min(gray[1], gray[2])), 0.03, HSLBand.names[i])
            a = DevelopAdjustments(); a.mixer[i].luminance = 80
            XCTAssertGreaterThan(DevelopPipeline.luma(SIMD3<Double>(pixel(source, a).prefix(3).map(Double.init))), DevelopPipeline.luma(color) + 0.04)
            a = DevelopAdjustments(); a.mixer[i].hue = 80
            let shifted = pixel(source, a)
            let actualHue = DevelopPipeline.hsl(SIMD3<Double>(shifted.prefix(3).map(Double.init))).x
            let expected = (HSLBand.centers[i] + 24).truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(actualHue, expected, accuracy: 2)
            let graySource = pixel(patch(SIMD3(repeating: 0.5)), a)
            XCTAssertEqual(graySource[0], 0.5, accuracy: 0.002)
        }
        var a = DevelopAdjustments(); a.mixer[0].hue = 100
        let left = DevelopPipeline.transform(DevelopPipeline.rgb(SIMD3(359.99, 0.7, 0.5)), adjustments: a)
        let right = DevelopPipeline.transform(DevelopPipeline.rgb(SIMD3(0.01, 0.7, 0.5)), adjustments: a)
        XCTAssertLessThan(abs(left.x-right.x) + abs(left.y-right.y) + abs(left.z-right.z), 0.001)
        // Red adjustment must leave pure blue unchanged.
        let blue = patch(SIMD3(0.2, 0.2, 0.8))
        XCTAssertEqual(pixel(blue, a)[2], 0.8, accuracy: 0.003)
    }
    func testGradingTonalRangesBalanceBlendingAndGlobal() {
        var a = DevelopAdjustments()
        a.grading.shadows = GradingTone(hue: 240, saturation: 100)
        a.grading.highlights = GradingTone(hue: 0, saturation: 100)
        let dark = pixel(patch(SIMD3(repeating: 0.2)), a)
        let light = pixel(patch(SIMD3(repeating: 0.8)), a)
        XCTAssertGreaterThan(dark[2], dark[0] + 0.05)
        XCTAssertGreaterThan(light[0], light[2] + 0.05)
        a.grading.balance = 100
        let warm = pixel(patch(SIMD3(repeating: 0.5)), a)
        a.grading.balance = -100
        let cool = pixel(patch(SIMD3(repeating: 0.5)), a)
        XCTAssertGreaterThan(warm[0], cool[0]); XCTAssertGreaterThan(cool[2], warm[2])
        a.grading.balance = 0; a.grading.blending = 0
        let narrow = pixel(patch(SIMD3(repeating: 0.5)), a)
        a.grading.blending = 100
        let wide = pixel(patch(SIMD3(repeating: 0.5)), a)
        XCTAssertGreaterThan(abs(narrow[2] - wide[2]), 0.005)
        a = DevelopAdjustments(); a.grading.midtones = GradingTone(hue: 120, saturation: 100)
        let mid = pixel(patch(SIMD3(repeating: 0.5)), a)
        XCTAssertGreaterThan(mid[1], mid[0] + 0.05)
        a.grading.global = GradingTone(hue: 30, saturation: 50, luminance: 30)
        XCTAssertGreaterThan(pixel(patch(SIMD3(repeating: 0.5)), a)[0], mid[0])
        XCTAssertEqual(pixel(patch(SIMD3(repeating: 0)), a)[0], 0, accuracy: 0.002)
        XCTAssertEqual(pixel(patch(SIMD3(repeating: 1)), a)[0], 1, accuracy: 0.002)
    }
    func testTextureAndClarityPositiveAndNegativeAndNoEdgeBleed() {
        let background = patch(SIMD3(repeating: 0.3), size: 64)
        let stripe = patch(SIMD3(repeating: 0.7), size: 16).transformed(by: CGAffineTransform(translationX: 24, y: 24))
        let source = stripe.composited(over: background)
        for key in [\DevelopAdjustments.texture, \.clarity] {
            var a = DevelopAdjustments(); a[keyPath: key] = 100
            let sharp = pixel(source, a, at: CGPoint(x: 24, y: 30))
            a[keyPath: key] = -100
            let smooth = pixel(source, a, at: CGPoint(x: 24, y: 30))
            XCTAssertGreaterThan(sharp[0], 0.72); XCTAssertLessThan(smooth[0], 0.68)
            XCTAssertEqual(pixel(source, a)[3], 1, accuracy: 0.001)
        }
    }
    func testCropMovementAllHandlesAndRatioLock() throws {
        let size = CGSize(width: 800, height: 600)
        let original = Crop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let handles: [CropInteraction.Handle] = [.move, .draw, .resize(-1,-1), .resize(1,-1), .resize(-1,1), .resize(1,1), .resize(0,-1), .resize(0,1), .resize(-1,0), .resize(1,0)]
        for ratio in [nil, 4.0/3, 1.0, 2.0/3] as [Double?] {
            for handle in handles {
                for end in [CGPoint(x: -300, y: -200), CGPoint(x: 500, y: 500), CGPoint(x: 1600, y: 1200)] {
                    let crop = CropInteraction.drag(original, handle: handle, from: CGPoint(x: 200, y: 180), to: end, size: size, aspectRatio: ratio)
                    var r = recipe(); r.crop = crop; try r.validate()
                    if let ratio, handle != .move {
                        XCTAssertEqual(crop.width * size.width / (crop.height * size.height), ratio, accuracy: 0.000001)
                    }
                }
            }
        }
        let moved = CropInteraction.drag(original, handle: .move, from: .zero, to: CGPoint(x: 800, y: 600), size: size, aspectRatio: nil)
        XCTAssertEqual(moved.width, original.width); XCTAssertEqual(moved.height, original.height)
        XCTAssertEqual(moved.x, 0.4, accuracy: 0.000001); XCTAssertEqual(moved.y, 0, accuracy: 0.000001)
    }
    func testStraighteningAllRotationsHasNoTransparentBorders() throws {
        let input = patch(SIMD3(0.6, 0.4, 0.2), size: 120).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80))
        for turns in 0...3 { for angle in [-45.0, -13, 0, 13, 45] {
            var r = recipe(); r.quarterTurns = turns; r.straightenDegrees = angle
            let output = try ImagePipeline.geometry(input, recipe: r)
            XCTAssertEqual(output.extent.width, turns % 2 == 0 ? 120 : 80)
            XCTAssertEqual(output.extent.height, turns % 2 == 0 ? 80 : 120)
            for point in [CGPoint(x: 1, y: 1), CGPoint(x: output.extent.maxX - 2, y: 1), CGPoint(x: 1, y: output.extent.maxY - 2), CGPoint(x: output.extent.maxX - 2, y: output.extent.maxY - 2)] {
                XCTAssertEqual(pixel(output, DevelopAdjustments(), at: point)[3], 1, accuracy: 0.002)
            }
        } }
    }
}

extension DevelopTests {
    func testPastePreservesTargetIdentityBaselineAndUnselectedGeometry() throws {
        var source = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "source", baselineExposure: 0.2, baselineTemperature: 6000, baselineTint: 5, temperature: 6000, tint: 5)
        source.exposure = 1.5; source.develop.clarity = 20
        source.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8); source.quarterTurns = 1
        var target = EditRecipe(sourceDigest: String(repeating: "b", count: 64), decoderVersion: "target", baselineExposure: -0.3, baselineTemperature: 4000, baselineTint: -4, temperature: 5000, tint: 3)
        target.asShotWhiteBalance = false
        let pasted = try target.pasting(source, options: RecipePasteOptions())
        XCTAssertEqual(pasted.sourceDigest, target.sourceDigest)
        XCTAssertEqual(pasted.decoderVersion, target.decoderVersion)
        XCTAssertEqual(pasted.baselineExposure, target.baselineExposure)
        XCTAssertEqual(pasted.temperature, 4000); XCTAssertEqual(pasted.tint, -4)
        XCTAssertEqual(pasted.crop, target.crop); XCTAssertEqual(pasted.quarterTurns, 0)
        XCTAssertEqual(pasted.exposure, 1.5); XCTAssertEqual(pasted.develop.clarity, 20)
        source.asShotWhiteBalance = false; source.temperature = 7200
        let wbOnly = try target.pasting(source, options: RecipePasteOptions(tone: false, whiteBalance: true, color: false, geometry: false))
        XCTAssertEqual(wbOnly.temperature, 7200); XCTAssertEqual(wbOnly.exposure, target.exposure)
        source.pipelineVersion = 0
        XCTAssertThrowsError(try target.pasting(source, options: RecipePasteOptions()))
    }
}
