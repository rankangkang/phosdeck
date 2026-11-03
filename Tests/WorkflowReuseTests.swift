import XCTest
import GRDB
@testable import Phosdeck

final class WorkflowReuseTests: XCTestCase {
    @MainActor func testPresetManagementUndoRestoresPayloadGroupAndFavorite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preset-undo-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0,
                                baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        let options = RecipePasteOptions()
        try catalog.savePreset(name: "夜景", recipe: recipe, options: options, groupName: "拍摄")
        let original = try XCTUnwrap(catalog.presets().first)
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.undo.groupsByEvent = false; try model.reload()
        model.undo.beginUndoGrouping(); model.setPresetFavorite(original, favorite: true); model.undo.endUndoGrouping()
        model.undo.undo(); XCTAssertEqual(try catalog.presets().first, original)
        model.undo.redo(); XCTAssertTrue(try XCTUnwrap(catalog.presets().first).favorite)
        model.undo.beginUndoGrouping(); model.setPresetGroup(original, group: "交付"); model.undo.endUndoGrouping()
        recipe.exposure = 1.5
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.updatePreset(id: original.id, source: recipe, options: options))
        model.undo.endUndoGrouping()
        let updated = try XCTUnwrap(catalog.presets().first)
        XCTAssertEqual(updated.groupName, "交付"); XCTAssertTrue(updated.favorite)
        model.undo.undo()
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.presets().first).recipe).exposure, 0)
        model.undo.redo(); XCTAssertEqual(try catalog.presets().first, updated)
        model.undo.beginUndoGrouping(); model.deletePreset(updated); model.undo.endUndoGrouping(); XCTAssertTrue(try catalog.presets().isEmpty)
        model.undo.undo(); XCTAssertEqual(try catalog.presets().first, updated)
        model.undo.redo(); XCTAssertTrue(try catalog.presets().isEmpty)
    }

    @MainActor func testPresetFormCanCommitWhileItOwnsTheUtilitySheet() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preset-form-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0,
                                baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        try catalog.savePreset(name: "原名称", recipe: recipe, options: RecipePasteOptions())
        let preset = try XCTUnwrap(catalog.presets().first)
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.undo.groupsByEvent = false
        model.catalogUtilityOpen = true
        XCTAssertFalse(model.workspaceAvailable, "The sheet blocks unrelated workspace actions")
        recipe.exposure = 1.25
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.updatePreset(id: preset.id, source: recipe, options: RecipePasteOptions()))
        model.undo.endUndoGrouping()
        model.undo.beginUndoGrouping(); model.renamePreset(id: preset.id, name: "已确认名称"); model.undo.endUndoGrouping()
        XCTAssertEqual(try catalog.presets().first?.name, "已确认名称")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.presets().first).recipe).exposure, 1.25)
        model.busy = true
        recipe.exposure = 2
        XCTAssertFalse(model.updatePreset(id: preset.id, source: recipe, options: RecipePasteOptions()))
        model.renamePreset(id: preset.id, name: "不应写入")
        XCTAssertEqual(try catalog.presets().first?.name, "已确认名称")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.presets().first).recipe).exposure, 1.25)
    }

    @MainActor func testMultiExportUsesExistingQueueAndVerifiesBothSpecsOnRetry() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let url = fixture.source.appendingPathComponent("source.jpg"); try fixture.image(url)
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source)
        try fixture.catalog.index(photo)
        let originalDigest = try SafeFileWriter.sha256(url)
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = fixture.catalog; try model.reload(); model.choose([photo.id], active: photo.id)
        let specs = [ExportSpecification(id: "web", title: "网页", subfolder: "网页", options: ExportOptions(format: .png)),
                     ExportSpecification(id: "archive", title: "归档", subfolder: "归档", options: ExportOptions(format: .tiff))]
        XCTAssertTrue(model.export(specifications: specs, directory: fixture.target, access: AccessLease(url: fixture.target), photos: [photo]), model.error ?? "")
        await model.task?.value
        XCTAssertEqual(model.lastExportResult?.completed, 2, model.reports.joined(separator: ";"))
        let logs = try ExportService.logs(catalog: fixture.catalog)
        XCTAssertEqual(Set(logs.map { $0.snapshot.destination.deletingLastPathComponent().lastPathComponent }), ["网页", "归档"])
        XCTAssertEqual(Set(logs.map { $0.snapshot.options.format }), [.png, .tiff])
        let identities = try logs.map { try FileIdentity.read($0.snapshot.destination) }
        let digests = try logs.map { try SafeFileWriter.sha256($0.snapshot.destination) }
        model.retryExports(ids: Set(logs.map(\.id)), includeCompleted: true)
        await model.task?.value
        XCTAssertEqual(model.lastExportResult?.completed, 2)
        XCTAssertEqual(try logs.map { try FileIdentity.read($0.snapshot.destination) }, identities)
        XCTAssertEqual(try logs.map { try SafeFileWriter.sha256($0.snapshot.destination) }, digests)
        XCTAssertEqual(try SafeFileWriter.sha256(url), originalDigest)
    }

    @MainActor func testMultiExportInvalidPlanDoesNotCreateFoldersOrEnqueuePartialBatch() throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let url = fixture.source.appendingPathComponent("source.jpg"); try fixture.image(url)
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source); try fixture.catalog.index(photo)
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = fixture.catalog; try model.reload(); model.choose([photo.id], active: photo.id)
        let specs = [ExportSpecification(id: "1", title: "一个规格", subfolder: "重复", options: ExportOptions(format: .png)),
                     ExportSpecification(id: "2", title: "另一个规格", subfolder: "重复", options: ExportOptions(format: .tiff))]
        XCTAssertFalse(model.export(specifications: specs, directory: fixture.target, access: AccessLease(url: fixture.target), photos: [photo]))
        XCTAssertNotNil(model.error); XCTAssertFalse(model.busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("重复").path))
        XCTAssertTrue(try ExportService.logs(catalog: fixture.catalog).isEmpty)
    }
}
