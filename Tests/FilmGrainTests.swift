import XCTest
import CoreImage
@testable import Phosdeck

final class FilmGrainTests: XCTestCase {
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
    private func grain(_ amount: Double = 80, size: Double = 25, roughness: Double = 50, seed: UInt32 = 1) -> FilmGrain {
        var g = FilmGrain()
        g.amount = amount
        g.size = size
        g.roughness = roughness
        g.seed = seed
        return g
    }

    func testLightcraftHashAndMapping() throws {
        XCTAssertEqual(Double(FilmGrainMath.hashNoise(0, 0, seed: 0)), -1, accuracy: 1e-6)
        XCTAssertEqual(Double(FilmGrainMath.noise(0, 0, seed: 0)), -1, accuracy: 1e-6)
        var g = grain()
        let p = try XCTUnwrap(FilmGrainMath.prepared(g, longEdge: 1000))
        XCTAssertEqual(Double(p.amount), 0.104, accuracy: 1e-6)
        XCTAssertEqual(Double(p.cell), 1.2, accuracy: 1e-6)
        XCTAssertEqual(Double(p.roughness), 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.seed, 1)
        g.amount = 0
        XCTAssertNil(FilmGrainMath.prepared(g, longEdge: 1000))
        g.amount = 100
        g.size = 0
        let tiny = try XCTUnwrap(FilmGrainMath.prepared(g, longEdge: 80))
        XCTAssertEqual(Double(tiny.cell), 0.6, accuracy: 1e-6)
    }

    func testAmountZeroLeavesPixels() throws {
        let source = gray(0.5, width: 48, height: 32)
        XCTAssertEqual(Double(pixel(try FilmGrainPipeline.apply(source, FilmGrain()), 24, 16).x), 0.5, accuracy: 0.002)
    }

    func testKernelMatchesCPUAtPixelCenters() throws {
        let g = grain(70, size: 40, roughness: 60, seed: 7)
        let prepared = try XCTUnwrap(FilmGrainMath.prepared(g, longEdge: 48))
        let source = gray(0.4, width: 48, height: 32)
        let image = try FilmGrainPipeline.apply(source, g)
        for (x, y) in [(0, 0), (24, 16), (47, 0), (0, 31), (47, 31), (10, 4)] {
            let actual = Double(pixel(image, x, y).x)
            let expected = Double(FilmGrainMath.shade(SIMD3(repeating: 0.4), x: Float(x) + 0.5, y: Float(y) + 0.5, width: 48, height: 32, grain: prepared).x)
            XCTAssertEqual(actual, expected, accuracy: 0.003, "\(x),\(y) actual \(actual) expected \(expected)")
        }
    }

    func testSameSeedRepeatsAndDifferentSeedChanges() throws {
        let source = gray(0.45, width: 64, height: 48)
        let first = try FilmGrainPipeline.apply(source, grain(seed: 11))
        let again = try FilmGrainPipeline.apply(source, grain(seed: 11))
        let other = try FilmGrainPipeline.apply(source, grain(seed: 12))
        XCTAssertEqual(Double(pixel(first, 8, 8).x), Double(pixel(again, 8, 8).x), accuracy: 1e-5)
        XCTAssertNotEqual(Double(pixel(first, 8, 8).x), Double(pixel(other, 8, 8).x), accuracy: 1e-4)
    }

    func testFollowsCroppedFrameNotTheUncroppedSource() throws {
        let g = grain(100, size: 100, roughness: 0, seed: 3)
        let source = gray(0.5, width: 160, height: 80)
        var recipe = self.recipe()
        recipe.grain = g
        recipe.crop = Crop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try ImagePipeline.geometry(source, recipe: recipe)
        let afterCrop = try FilmGrainPipeline.apply(cropped, g)
        let beforeCrop = try FilmGrainPipeline.apply(source, g)
        let croppedAfterGrain = try ImagePipeline.geometry(beforeCrop, recipe: recipe)
        XCTAssertNotEqual(Double(pixel(afterCrop, 2, 2).x), Double(pixel(croppedAfterGrain, 2, 2).x), accuracy: 1e-4)
    }

    func testRelativeSizeMatchesAcrossResolutions() throws {
        let g = grain(100, size: 100, roughness: 0, seed: 9)
        let small = try XCTUnwrap(FilmGrainMath.prepared(g, longEdge: 640))
        let large = try XCTUnwrap(FilmGrainMath.prepared(g, longEdge: 1280))
        let color = SIMD3<Float>(repeating: 0.5)
        let a = FilmGrainMath.shade(color, x: 320, y: 160, width: 640, height: 320, grain: small)
        let b = FilmGrainMath.shade(color, x: 640, y: 320, width: 1280, height: 640, grain: large)
        XCTAssertEqual(Double(a.x), Double(b.x), accuracy: 1e-5)
        let rendered = try FilmGrainPipeline.apply(gray(0.5, width: 64, height: 32), g)
        XCTAssertNotEqual(Double(pixel(rendered, 8, 8).x), 0.5, accuracy: 0.002)
    }

    func testRecipeRoundTripPasteAndBaseline() throws {
        var value = recipe()
        value.grain = grain(40, size: 30, roughness: 70, seed: 99)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: encoded).grain, value.grain)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "grain")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: legacy)).grain, FilmGrain())
        XCTAssertTrue(value.baseline().grain.isDefault)
        XCTAssertTrue(value.alignedBaseline().grain.isDefault)
        XCTAssertTrue(value.changeTitle(from: recipe()).contains("颗粒"))
        var target = recipe(); target.grain.amount = 10
        XCTAssertEqual(try target.pasting(value, options: RecipePasteOptions()).grain, value.grain)
        XCTAssertEqual(try target.pasting(value, options: RecipePasteOptions(tone: false)).grain.amount, 10)
        var invalid = value; invalid.grain.amount = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = value; invalid.grain.size = 120
        XCTAssertThrowsError(try invalid.validate())
        let local = LocalAdjustment(components: [MaskComponent(tool: .radial)])
        XCTAssertTrue(local.editingRecipe(from: value).grain.isDefault)
        var seeded = FilmGrain()
        seeded.ensureSeed()
        XCTAssertNotEqual(seeded.seed, 0)
        let kept = seeded.seed
        seeded.ensureSeed()
        XCTAssertEqual(seeded.seed, kept)
    }
}
