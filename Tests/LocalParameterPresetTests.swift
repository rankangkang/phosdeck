import XCTest
import CoreImage
import GRDB
@testable import Phosdeck

final class LocalParameterPresetTests: XCTestCase {
    private func group(name: String = "源蒙版") -> LocalAdjustment {
        var base = MaskComponent(tool: .linear)
        base.start = MaskPoint(0.12, 0.2)
        base.end = MaskPoint(0.84, 0.76)
        base.inverted = true
        var subtract = MaskComponent(tool: .brush, operation: .subtract)
        subtract.strokes = [MaskStroke(points: [MaskPoint(0.2, 0.3), MaskPoint(0.4, 0.5)], radius: 0.08, feather: 0.2, flow: 0.8, density: 0.7)]
        var value = LocalAdjustment(components: [base, subtract])
        value.id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        value.name = name
        value.enabled = false
        value.inverted = true
        value.amount = 0.37
        value.exposure = 1.25
        value.contrast = 1.4
        value.saturation = 0.72
        value.settings = LocalDevelopSettings()
        value.settings?.temperature = 7100
        value.settings?.tint = -18
        value.settings?.asShotWhiteBalance = false
        value.settings?.develop.shadows = 34
        value.settings?.develop.grading.midtones.saturation = 21
        value.refinement = MaskRefinement(edgeRadius: 0.2, blurRadius: 0.1, expansion: -0.15, hardness: 0.3)
        return value
    }

    func testApplyingOnlyLocalValuesPreservesTargetMaskIdentityAndRegion() throws {
        let source = group()
        let values = LocalParameterValues(group: source)
        var target = LocalAdjustment(components: [MaskComponent(tool: .radial)])
        target.id = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        target.name = "目标选区"
        target.enabled = true
        target.amount = 0.61
        target.components[0].start = MaskPoint(0.77, 0.32)
        target.components[0].radiusX = 0.18
        target.components[0].radiusY = 0.29
        target.refinement = MaskRefinement(expansion: 0.1)
        let region = target.components
        let applied = try values.applying(to: target)

        XCTAssertEqual(applied.id, target.id)
        XCTAssertEqual(applied.name, target.name)
        XCTAssertEqual(applied.enabled, target.enabled)
        XCTAssertEqual(applied.amount, target.amount, accuracy: 0.000001, "局部参数不应覆盖目标强度")
        XCTAssertEqual(applied.components, region, "组件、几何、采样和反选状态保持目标自己的值")
        XCTAssertEqual(applied.refinement, target.refinement)
        XCTAssertEqual(applied.exposure, source.exposure, accuracy: 0.000001)
        XCTAssertEqual(applied.contrast, source.contrast, accuracy: 0.000001)
        XCTAssertEqual(applied.saturation, source.saturation, accuracy: 0.000001)
        XCTAssertEqual(applied.settings, source.settings)
    }

    func testPayloadIsLocalOnlyAndRejectsInvalidOrCorruptData() throws {
        let values = LocalParameterValues(group: group())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["exposure", "contrast", "saturation", "settings"])
        XCTAssertNil(object["sourceDigest"])
        XCTAssertNil(object["decoderVersion"])
        XCTAssertNil(object["amount"])

        var invalid = values
        // Keep the payload JSON-encodable; range validation, rather than
        // JSONEncoder's non-finite-number guard, should reject it.
        invalid.exposure = 6.5
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try LocalParameterPreset(name: " ", values: values))

        let corrupt = LocalParameterPreset(id: "bad", name: "损坏", parameters: Data("not-json".utf8))
        XCTAssertThrowsError(try corrupt.decodedValues())
        let invalidJSON = try JSONEncoder().encode(invalid)
        XCTAssertThrowsError(try LocalParameterPreset(id: "bad2", name: "越界", parameters: invalidJSON).decodedValues())
    }

    func testNamedPresetPersistsAcrossReopenAndBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-parameter-preset-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var catalog: CatalogStore? = try CatalogStore(directory: folder)
        let values = LocalParameterValues(group: group())
        try catalog?.saveLocalParameterPreset(name: "柔和肤色", values: values)
        let saved = try XCTUnwrap(try catalog?.localParameterPresets().first)
        XCTAssertEqual(saved.name, "柔和肤色")
        XCTAssertEqual(try saved.decodedValues(), values)

        let catalogURL = try XCTUnwrap(catalog?.fileURL)
        // CatalogLock intentionally rejects two live handles. Release the
        // original owner before reopening the same SQLite file.
        catalog = nil
        let reopened = try CatalogStore(fileURL: catalogURL)
        XCTAssertEqual(try reopened.localParameterPresets().map(\.name), ["柔和肤色"])
        let backup = folder.appendingPathComponent("backup.sqlite")
        try reopened.backup(to: backup)
        let restored = try CatalogStore.restore(from: backup, to: folder.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.localParameterPresets().map(\.name), ["柔和肤色"])

        try reopened.renameLocalParameterPreset(id: saved.id, name: "柔和肤色 2")
        XCTAssertEqual(try reopened.localParameterPresets().first?.name, "柔和肤色 2")
        try reopened.deleteLocalParameterPreset(saved.id)
        XCTAssertTrue(try reopened.localParameterPresets().isEmpty)
        XCTAssertThrowsError(try reopened.deleteLocalParameterPreset(saved.id))
    }

    @MainActor
    func testModelApplyCreatesOneRecipeUndoAndDoesNotReplaceTargetRegion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-parameter-undo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder.appendingPathComponent("source"), bookmark: Data())
        let photo = Photo(id: "local-undo", rootID: root.id, relativePath: "sample.ARW", identity: Data(), identityKey: "local-undo", width: 80, height: 40)
        try catalog.index(photo)
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
        let rendered = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .black).cropped(to: bounds), from: bounds))
        let model = AppModel(previewRenderer: { request, _, _ in
            RenderedImage(image: rendered, fullSize: CGSize(width: request.photo.width, height: request.photo.height),
                          orientedSourceSize: CGSize(width: request.photo.width, height: request.photo.height),
                          histogram: nil, elapsed: 0)
        })
        model.catalog = catalog
        model.activePhoto = photo
        model.activeID = photo.id
        var base = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test-raw",
                              baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0,
                              temperature: 5500, tint: 0)
        base.schemaVersion = 3
        model.recipe = base
        model.canEdit = true
        model.dirty = true
        XCTAssertTrue(model.commitRecipe())

        let source = group(name: "源")
        var target = group(name: "目标")
        target.id = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        target.components[0].start = MaskPoint(0.71, 0.23)
        target.amount = 0.42
        target.exposure = -0.5
        let targetRegion = target.components
        model.changeRecipe({ $0.localAdjustments = [source, target] }, commit: false)
        XCTAssertTrue(model.commitRecipe())
        model.selectMask(target.id, component: nil)
        model.undo.removeAllActions()
        model.copiedLocalParameters = LocalParameterValues(group: source)
        let history = try catalog.editHistory(photoID: photo.id).count

        XCTAssertTrue(model.pasteLocalParameters())
        XCTAssertEqual(try catalog.editHistory(photoID: photo.id).count, history + 1)
        XCTAssertEqual(model.selectedMask?.components, targetRegion)
        XCTAssertEqual(try XCTUnwrap(model.selectedMask).amount, target.amount, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(model.selectedMask).exposure, source.exposure, accuracy: 0.000001)
        model.undo.undo()
        XCTAssertEqual(try XCTUnwrap(model.selectedMask).exposure, target.exposure, accuracy: 0.000001)
        XCTAssertEqual(model.selectedMask?.components, targetRegion)

        try catalog.saveLocalParameterPreset(name: "撤销预设", values: LocalParameterValues(group: source))
        model.localParameterPresets = try catalog.localParameterPresets()
        let preset = try XCTUnwrap(model.localParameterPresets.first)
        model.undo.removeAllActions()
        XCTAssertTrue(model.deleteLocalParameterPreset(preset))
        XCTAssertTrue(try catalog.localParameterPresets().isEmpty)
        model.undo.undo()
        XCTAssertEqual(try catalog.localParameterPresets().map(\.name), ["撤销预设"])
        model.undo.redo()
        XCTAssertTrue(try catalog.localParameterPresets().isEmpty)
    }
}
