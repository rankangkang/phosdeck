import XCTest
import CoreImage
@testable import Phosdeck

final class CreativeVignetteTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func gray(_ value: Double, width: Int, height: Int) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> SIMD3<Float> {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return SIMD3(data[0], data[1], data[2])
    }

    func testLightcraftMapping() throws {
        var v = CreativeVignette(); v.amount = -80; v.midpoint = 50; v.roundness = 0; v.feather = 50; v.highlights = 40
        let p = try XCTUnwrap(CreativeVignetteMath.prepared(v))
        XCTAssertEqual(Double(p.amount), -0.8, accuracy: 1e-6)
        XCTAssertEqual(Double(p.start), 0.625, accuracy: 1e-6)
        XCTAssertEqual(Double(p.width), 0.6, accuracy: 1e-6)
        XCTAssertEqual(Double(p.aspectMix), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(p.power), 2, accuracy: 1e-6)
        XCTAssertEqual(Double(p.highlights), 0.4, accuracy: 1e-6)
        v.roundness = 100
        XCTAssertEqual(Double(CreativeVignetteMath.prepared(v)?.aspectMix ?? -1), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(CreativeVignetteMath.prepared(v)?.power ?? -1), 2, accuracy: 1e-6)
        v.roundness = -100
        XCTAssertEqual(Double(CreativeVignetteMath.prepared(v)?.aspectMix ?? -1), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(CreativeVignetteMath.prepared(v)?.power ?? -1), 8, accuracy: 1e-6)
        v.amount = 0
        XCTAssertNil(CreativeVignetteMath.prepared(v))
    }

    func testCenterStaysAndCornersDarken() throws {
        var v = CreativeVignette(); v.amount = -100
        let source = gray(0.5, width: 80, height: 40)
        let image = try CreativeVignettePipeline.apply(source, v)
        let center = Double(pixel(image, 40, 20).x)
        let corner = Double(pixel(image, 1, 1).x)
        XCTAssertEqual(center, 0.5, accuracy: 0.002)
        XCTAssertLessThan(corner, 0.2)
        XCTAssertEqual(Double(pixel(try CreativeVignettePipeline.apply(source, CreativeVignette()), 1, 1).x), 0.5, accuracy: 0.002)
    }

    func testKernelMatchesCPUAtPixelCenters() throws {
        var v = CreativeVignette(); v.amount = -70; v.midpoint = 40; v.roundness = 20; v.feather = 60; v.highlights = 50
        let prepared = try XCTUnwrap(CreativeVignetteMath.prepared(v))
        let source = gray(0.6, width: 48, height: 32)
        let image = try CreativeVignettePipeline.apply(source, v)
        for (x, y) in [(0, 0), (24, 16), (47, 0), (0, 31), (47, 31), (10, 4)] {
            let actual = Double(pixel(image, x, y).x)
            let expected = Double(CreativeVignetteMath.shade(SIMD3(repeating: 0.6), x: Float(x) + 0.5, y: Float(y) + 0.5, width: 48, height: 32, vig: prepared).x)
            XCTAssertEqual(actual, expected, accuracy: 0.003, "\(x),\(y) actual \(actual) expected \(expected)")
        }
    }

    func testFollowsCroppedFrameNotTheUncroppedSource() throws {
        var v = CreativeVignette(); v.amount = -100
        let source = gray(0.5, width: 80, height: 40)
        var recipe = self.recipe()
        recipe.vignette = v
        recipe.crop = Crop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try ImagePipeline.geometry(source, recipe: recipe)
        XCTAssertEqual(cropped.extent.width, 40, accuracy: 0.001)
        XCTAssertEqual(cropped.extent.height, 20, accuracy: 0.001)
        let afterCrop = try CreativeVignettePipeline.apply(cropped, v)
        XCTAssertEqual(Double(pixel(afterCrop, 20, 10).x), 0.5, accuracy: 0.002)
        XCTAssertLessThan(Double(pixel(afterCrop, 1, 1).x), 0.25)

        let beforeCrop = try CreativeVignettePipeline.apply(source, v)
        let croppedAfterVignette = try ImagePipeline.geometry(beforeCrop, recipe: recipe)
        XCTAssertEqual(Double(pixel(croppedAfterVignette, 20, 10).x), 0.5, accuracy: 0.01)
        XCTAssertEqual(Double(pixel(croppedAfterVignette, 1, 1).x), 0.5, accuracy: 0.02, "vignette before crop leaves the kept centre patch alone")
    }

    func testHighlightPriorityProtectsBrightPixels() throws {
        var v = CreativeVignette(); v.amount = -100; v.highlights = 100; v.style = .highlightPriority
        let bright = gray(1, width: 40, height: 40)
        let mid = gray(0.3, width: 40, height: 40)
        let protected = Double(pixel(try CreativeVignettePipeline.apply(bright, v), 1, 1).x)
        let darkened = Double(pixel(try CreativeVignettePipeline.apply(mid, v), 1, 1).x)
        XCTAssertGreaterThan(protected, 0.85)
        XCTAssertLessThan(darkened, 0.15)
        v.style = .colorPriority
        XCTAssertLessThan(Double(pixel(try CreativeVignettePipeline.apply(bright, v), 1, 1).x), 0.2)
        v.style = .paintOverlay
        XCTAssertLessThan(Double(pixel(try CreativeVignettePipeline.apply(bright, v), 1, 1).x), 0.2)
    }

    func testPositiveAmountLightensCorners() throws {
        var v = CreativeVignette(); v.amount = 100
        let source = gray(0.2, width: 40, height: 40)
        let image = try CreativeVignettePipeline.apply(source, v)
        XCTAssertEqual(Double(pixel(image, 20, 20).x), 0.2, accuracy: 0.002)
        XCTAssertGreaterThan(Double(pixel(image, 1, 1).x), 0.7)
    }

    func testRecipeRoundTripPasteAndBaseline() throws {
        var value = recipe()
        value.vignette.amount = -40
        value.vignette.midpoint = 30
        value.vignette.roundness = -20
        value.vignette.feather = 70
        value.vignette.highlights = 15
        value.vignette.style = .paintOverlay
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: encoded).vignette, value.vignette)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "vignette")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: legacy)).vignette, CreativeVignette())
        XCTAssertTrue(value.baseline().vignette.isDefault)
        XCTAssertTrue(value.alignedBaseline().vignette.isDefault)
        XCTAssertTrue(value.changeTitle(from: recipe()).contains("创作暗角"))
        var target = recipe(); target.vignette.amount = -10
        XCTAssertEqual(try target.pasting(value, options: RecipePasteOptions()).vignette, value.vignette)
        XCTAssertEqual(try target.pasting(value, options: RecipePasteOptions(tone: false)).vignette.amount, -10)
        var invalid = value; invalid.vignette.feather = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = value; invalid.vignette.amount = 120
        XCTAssertThrowsError(try invalid.validate())
        let local = LocalAdjustment(components: [MaskComponent(tool: .radial)])
        XCTAssertTrue(local.editingRecipe(from: value).vignette.isDefault)
    }
}
