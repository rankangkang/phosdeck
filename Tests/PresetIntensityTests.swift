import XCTest
@testable import Phosdeck

final class PresetIntensityTests: XCTestCase {
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test",
                   baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }

    func testAmountScalesNumbersAndClampsToControlRange() throws {
        let base = recipe()
        var preset = recipe()
        preset.exposure = 1
        preset.contrast = 1.4
        preset.develop.clarity = 40
        let half = try base.applyingPreset(preset, options: RecipePasteOptions(), amount: 0.5)
        XCTAssertEqual(half.exposure, 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.contrast, 1.2, accuracy: 1e-9)
        XCTAssertEqual(half.develop.clarity, 20, accuracy: 1e-9)
        let more = try base.applyingPreset(preset, options: RecipePasteOptions(), amount: 2)
        XCTAssertEqual(more.exposure, 2, accuracy: 1e-9)
        XCTAssertEqual(more.contrast, 1.8, accuracy: 1e-9)
        XCTAssertEqual(more.develop.clarity, 80, accuracy: 1e-9)
        var strong = recipe(); strong.exposure = 4
        let lots = try base.applyingPreset(strong, options: RecipePasteOptions(), amount: 2)
        XCTAssertEqual(lots.exposure, 5)
    }

    /// Matches lightcraft `amount_keeps_integer_fields_whole`: a grain seed must stay an integer,
    /// taken from the current recipe below 50 % and from the preset at 50 % and above.
    func testAmountKeepsIntegerFieldsWhole() throws {
        var preset = recipe()
        preset.exposure = 1
        preset.grain.amount = 40
        preset.grain.seed = 12345
        let base = recipe()
        for (amount, seed) in [(0.3, UInt32(0)), (0.5, UInt32(12345)), (1.5, UInt32(12345)), (2.0, UInt32(12345))] {
            let out = try base.applyingPreset(preset, options: RecipePasteOptions(), amount: amount)
            XCTAssertEqual(out.exposure, min(amount, 5), accuracy: 1e-9, "amount \(amount)")
            XCTAssertEqual(out.grain.amount, min(40 * amount, 100), accuracy: 1e-9, "amount \(amount)")
            XCTAssertEqual(out.grain.seed, seed, "amount \(amount)")
        }
    }

    func testFullAmountMatchesPastingWhenPresetHasNoMasks() throws {
        var preset = recipe()
        preset.exposure = 1.25
        preset.grain = FilmGrain(amount: 40, size: 30, roughness: 70, seed: 99)
        preset.vignette.amount = -20
        var target = recipe()
        target.exposure = 0.4
        target.grain.amount = 10
        let pasted = try target.pasting(preset, options: RecipePasteOptions())
        let applied = try target.applyingPreset(preset, options: RecipePasteOptions(), amount: 1)
        XCTAssertEqual(applied, pasted)
        XCTAssertEqual(try target.pasting(preset, options: RecipePasteOptions(tone: false)).grain.amount, 10)
        XCTAssertEqual(try target.applyingPreset(preset, options: RecipePasteOptions(tone: false), amount: 0.5).grain.amount, 10)
        XCTAssertEqual(try target.applyingPreset(preset, options: RecipePasteOptions(tone: false), amount: 0.5).exposure, 0.4)
    }

    func testPresetMasksAreAddedOnceAndScaled() throws {
        var preset = recipe()
        preset.schemaVersion = 3
        var mask = LocalAdjustment(components: [MaskComponent(tool: .linear)])
        mask.name = "天空"
        mask.amount = 0.4
        mask.exposure = 1
        preset.localAdjustments = [mask]
        var target = recipe()
        target.exposure = 0.2
        let maskOnly = RecipePasteOptions(tone: false, whiteBalance: false, color: false, details: true, curves: false, zones: false)
        let half = try target.applyingPreset(preset, options: maskOnly, amount: 0.5)
        XCTAssertEqual(half.localAdjustments.count, 1)
        XCTAssertEqual(half.localAdjustments[0].name, "天空")
        XCTAssertEqual(half.localAdjustments[0].amount, 0.2, accuracy: 1e-9)
        XCTAssertEqual(half.localAdjustments[0].exposure, 1)
        XCTAssertNotEqual(half.localAdjustments[0].id, mask.id)
        XCTAssertEqual(half.schemaVersion, 3)
        let again = try half.applyingPreset(preset, options: maskOnly, amount: 2)
        XCTAssertEqual(again.localAdjustments.count, 1)
        XCTAssertEqual(again.localAdjustments[0].amount, 0.2, accuracy: 1e-9)
        var other = mask
        other.name = "前景"
        other.amount = 1
        preset.localAdjustments = [other]
        let extra = try again.applyingPreset(preset, options: maskOnly, amount: 2)
        XCTAssertEqual(extra.localAdjustments.count, 2)
        XCTAssertEqual(extra.localAdjustments[1].name, "前景")
        XCTAssertEqual(extra.localAdjustments[1].amount, 1)
    }

    func testGeometryClampsAndDiscreteFieldsSnap() throws {
        var preset = recipe()
        preset.crop = Crop(x: 0.4, y: 0.4, width: 0.5, height: 0.5)
        preset.quarterTurns = 1
        preset.straightenDegrees = 10
        preset.develop.blackAndWhite = true
        var current = recipe()
        current.crop = Crop(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let over = try current.applyingPreset(preset, options: RecipePasteOptions(tone: false, color: true, geometry: true, curves: false, zones: false), amount: 2)
        XCTAssertEqual(over.crop.x + over.crop.width, 1, accuracy: 1e-9)
        XCTAssertEqual(over.crop.y + over.crop.height, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(over.crop.width, 0)
        XCTAssertEqual(over.quarterTurns, 1)
        XCTAssertEqual(over.straightenDegrees, 20)
        XCTAssertTrue(over.develop.blackAndWhite)
        let low = try recipe().applyingPreset(preset, options: RecipePasteOptions(tone: false, color: true, geometry: true, curves: false, zones: false), amount: 0.3)
        XCTAssertEqual(low.quarterTurns, 0)
        XCTAssertFalse(low.develop.blackAndWhite)
        XCTAssertEqual(low.straightenDegrees, 3, accuracy: 1e-9)
    }
}
