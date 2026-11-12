import MCP
import XCTest
@testable import Phosdeck

final class AgentDevelopTests: XCTestCase {
    private struct Client {
        let model: AppModel
        let tools: AppMCPTools
        let catalog: CatalogStore
        let session: Value
        let epoch: Value

        @MainActor init(_ catalog: CatalogStore, picker: AppMCPWorkflows.FilePicker? = nil) async throws {
            self.catalog = catalog
            model = AppModel()
            model.catalog = catalog
            try model.reload()
            tools = AppMCPTools(model: model, appName: "Phosdeck Test", version: "1", bundleID: "test",
                                sharesImages: false, chooseFile: picker)
            let state = await tools.call(.init(name: AppMCPTool.workspace.rawValue))
            let data = state.structuredContent?.objectValue?["data"]?.objectValue
            session = try XCTUnwrap(data?["catalog_session_id"])
            epoch = try XCTUnwrap(data?["request_epoch"])
        }

        func call(_ tool: AppMCPTool, _ args: [String: Value] = [:], request: String = UUID().uuidString) async -> CallTool.Result {
            var args = args
            if tool.needsCatalog || tool == .fileAccess { args["catalog_session_id"] = session }
            if tool.needsRequestID {
                args["request_epoch"] = epoch
                args["request_id"] = .string(request)
            }
            return await tools.call(.init(name: tool.rawValue, arguments: args))
        }

        func data(_ result: CallTool.Result, line: UInt = #line) throws -> [String: Value] {
            XCTAssertEqual(result.isError, false, String(describing: result.structuredContent), line: line)
            return try XCTUnwrap(result.structuredContent?.objectValue?["data"]?.objectValue, line: line)
        }

        func error(_ result: CallTool.Result, _ code: String, line: UInt = #line) {
            XCTAssertEqual(result.isError, true, line: line)
            XCTAssertEqual(result.structuredContent?.objectValue?["error"]?.objectValue?["code"], .string(code), line: line)
        }

        func job(_ result: CallTool.Result, line: UInt = #line) async throws -> [String: Value] {
            let id = try XCTUnwrap(data(result, line: line)["job_id"], line: line)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            repeat {
                let state = try data(await call(.job, ["job_id": id]), line: line)
                if state["phase"] == "finished" { return state }
                try await Task.sleep(for: .milliseconds(15))
            } while ContinuousClock.now < deadline
            XCTFail("Timed out waiting for the develop job.", line: line)
            return [:]
        }

        func edits(_ id: String, _ fields: [String: Value] = [:]) throws -> [String: Value] {
            let photo = try XCTUnwrap(catalog.photo(id))
            return MCPDevelopPhoto.revisions(photo).merging(fields) { _, value in value }
        }

        func expected(_ ids: [String]) throws -> Value {
            .object(try Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, .object(try edits(id).filter { $0.key != "photo_id" }))
            }))
        }

        func recipe(_ id: String) throws -> EditRecipe {
            try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(id)?.recipe))
        }
    }

    private func catalog(ids: [String] = ["a", "b"], withRecipes: Bool = true) async throws -> (CatalogStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-mcp-develop-" + UUID().uuidString)
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        addTeardownBlock {
            try catalog.database.close()
            try FileManager.default.removeItem(at: folder)
        }
        let root = try catalog.addRoot(url: folder, bookmark: AccessLease.bookmark(folder, readOnly: true))
        let pipeline = ImagePipeline()
        for (index, id) in ids.enumerated() {
            let url = folder.appendingPathComponent(id + ".png")
            try PNGFixture.data(width: 128, height: 96, transparency: false).write(to: url)
            var photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: folder)
            photo.id = id
            photo.metadata = try JSONEncoder().encode(PhotoMetadata(iso: 100, aperture: 4, exposureTime: 0.01 / pow(2, Double(index))))
            try catalog.index(photo)
            if withRecipes {
                var recipe = try await pipeline.baseline(.init(photo: photo, root: root, recipe: nil))
                if index == 0 { recipe.crop = Crop(x: 0.25, y: 0, width: 0.5, height: 1) }
                try catalog.saveRecipe(id: id, recipe: recipe)
            }
        }
        return (catalog, folder)
    }

    @MainActor func testExplicitVersionSaveIsDeduplicatedAndUsesNativeUndoRedo() async throws {
        let (catalog, folder) = try await catalog()
        let client = try await Client(catalog)
        let original = try client.recipe("a"), other = try client.recipe("b")
        let args = try client.edits("a", ["adjustments": ["exposure": 0.75, "temperature": 5900, "contrast": 1.15]])
        let first = await client.call(.globalAdjustments, args, request: "save")
        let saved = try await client.job(first)
        XCTAssertEqual(saved["commit_state"], "committed")
        XCTAssertEqual(saved["changed_count"], 1)
        let changed = try client.recipe("a")
        XCTAssertEqual(changed.exposure, 0.75)
        XCTAssertEqual(changed.temperature, 5900)
        XCTAssertFalse(changed.asShotWhiteBalance)
        XCTAssertEqual(changed.crop, original.crop)
        XCTAssertEqual(try client.recipe("b"), other)
        XCTAssertNil(client.model.activeID)
        let repeated = await client.call(.globalAdjustments, args, request: "save")
        XCTAssertEqual(first.structuredContent, repeated.structuredContent)
        client.error(await client.call(.globalAdjustments, args), "stale_photo")
        let noChange = try await client.job(await client.call(.globalAdjustments, client.edits("a", ["adjustments": ["exposure": 0.75]])))
        XCTAssertEqual(noChange["commit_state"], "not_committed")
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, 2)
        let operation = try XCTUnwrap(saved["operation_id"])
        let undone = try client.data(await client.call(.undo, ["operation_id": operation]))
        XCTAssertEqual(undone["items"]?.arrayValue?.first?.objectValue?["recipe_revision"], 3)
        XCTAssertEqual(try client.recipe("a"), original)
        _ = try client.data(await client.call(.redo, ["operation_id": operation]))
        XCTAssertEqual(try client.recipe("a"), changed)
        client.model.undo.undo()
        XCTAssertEqual(try client.recipe("a"), original)
        XCTAssertEqual(try SafeFileWriter.sha256(folder.appendingPathComponent("a.png")), original.sourceDigest)
    }

    @MainActor func testCanvasRegionSamplesTheSamePixelsAndInvalidatesOldCoordinates() async throws {
        let (catalog, _) = try await catalog(ids: ["a"])
        let client = try await Client(catalog)
        client.tools.setSharesImages(true)
        let original = try client.recipe("a")
        let complete = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128])))
        let detail = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128,
            "region": ["x": 0.25, "y": 0.125, "width": 0.5, "height": 0.5]])))
        XCTAssertEqual(detail["width"], 32)
        XCTAssertEqual(detail["height"], 48)
        XCTAssertEqual(detail["editable_canvas"], true)
        let wholeSample = try client.data(await client.call(.samplePreview, [
            "preview_id": try XCTUnwrap(complete["preview_id"]), "point": ["x": .double(20.5 / 64), "y": .double(17.5 / 96)]]))
        let cropSample = try client.data(await client.call(.samplePreview, [
            "preview_id": try XCTUnwrap(detail["preview_id"]), "point": ["x": .double(4.5 / 32), "y": .double(5.5 / 48)]]))
        XCTAssertEqual(wholeSample["pixel"], ["x": 20, "y": 17])
        XCTAssertEqual(cropSample["pixel"], ["x": 4, "y": 5])
        XCTAssertEqual(cropSample["rgba"], wholeSample["rgba"])
        XCTAssertEqual(cropSample["rgba"]?.arrayValue?.last, 255)

        let old = try XCTUnwrap(detail["preview_id"])
        let histogram = try await client.job(await client.call(.adjustPreview, client.edits("a", [
            "action": "histogram", "histogram_region": "exposure", "delta": 0.4, "preview_id": old])))
        XCTAssertEqual(histogram["commit_state"], "committed")
        XCTAssertEqual(try client.recipe("a").exposure, 0.4, accuracy: 0.000001)
        client.error(await client.call(.samplePreview, ["preview_id": old, "point": ["x": 0, "y": 0]]), "stale_preview")
        let before = try client.data(await client.call(.preview, client.edits("a", ["preview_variant": "original", "long_edge": 64])))
        XCTAssertEqual(before["editable_canvas"], false)
        client.error(await client.call(.pointColor, try client.edits("a", ["action": "add", "preview_id": XCTUnwrap(before["preview_id"]),
            "point": ["x": 0.5, "y": 0.5]])), "stale_preview")

        let undo = try XCTUnwrap(histogram["operation_id"])
        _ = try client.data(await client.call(.undo, ["operation_id": undo]))
        XCTAssertEqual(try client.recipe("a"), original)
        client.tools.setSharesImages(false)
        let sampleArgs: [String: Value] = ["preview_id": try XCTUnwrap(before["preview_id"]), "point": ["x": 0.5, "y": 0.5]]
        client.error(await client.call(.samplePreview, sampleArgs), "image_access_disabled")
        client.tools.setSharesImages(true)
        client.error(await client.call(.samplePreview, sampleArgs), "stale_preview")
    }

    @MainActor func testRotatedCanvasCropAndSpotTargetsShareTheNativeSourceCoordinates() async throws {
        let (catalog, folder) = try await catalog(ids: ["a"])
        let client = try await Client(catalog)
        client.tools.setSharesImages(true)
        let original = try client.recipe("a")
        let turn = try await client.job(await client.call(.photoGeometry, client.edits("a", ["turns": 1, "flip_horizontal": true])))
        XCTAssertEqual(turn["commit_state"], "committed")
        let full = try client.data(await client.call(.preview, client.edits("a", ["preview_variant": "crop_canvas", "long_edge": 128])))
        XCTAssertEqual(full["width"], 96)
        XCTAssertEqual(full["height"], 128)
        let box: Value = ["x": 0.125, "y": 0.25, "width": 0.5, "height": 0.5]
        let cropped = try await client.job(await client.call(.setCrop, client.edits("a", [
            "action": "set", "preview_id": try XCTUnwrap(full["preview_id"]), "rect": box])))
        XCTAssertEqual(cropped["commit_state"], "committed")
        let crop = try client.recipe("a")
        XCTAssertEqual(crop.crop, Crop(x: 0.375, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(crop.cropInDisplay.x, 0.125)

        let current = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128])))
        let args = try client.edits("a", ["action": "add", "spot_mode": "clone", "preview_id": try XCTUnwrap(current["preview_id"]),
            "path": [["x": 0.25, "y": 0.5], ["x": 0.375, "y": 0.625]], "source_point": ["x": 0.75, "y": 0.25],
            "radius": 0.06, "opacity": 0.8])
        let request = "one-spot-stroke"
        let started = await client.call(.editSpot, args, request: request)
        let spot = try await client.job(started)
        XCTAssertEqual(spot["commit_state"], "committed")
        let repeated = await client.call(.editSpot, args, request: request)
        XCTAssertEqual(started.structuredContent, repeated.structuredContent)
        let saved = try XCTUnwrap(client.recipe("a").repairs.first)
        XCTAssertEqual(try client.recipe("a").repairs.count, 1)
        XCTAssertEqual(saved.points, [MaskPoint(0.5, 0.75), MaskPoint(0.5625, 0.6875)])
        XCTAssertEqual(saved.sourceOffset, MaskPoint(-0.125, -0.25))
        let read = try client.data(await client.call(.spotRepairs, client.edits("a", ["spot_id": .string(saved.id.uuidString)])))
        let repair = try XCTUnwrap(read["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(repair["target"], ["x": 0.5, "y": 0.25])
        XCTAssertEqual(repair["source"], ["x": 0.375, "y": 0.5])
        XCTAssertEqual(repair["path"]?.arrayValue?.count, 2)
        let undo = try XCTUnwrap(spot["operation_id"])
        _ = try client.data(await client.call(.undo, ["operation_id": undo]))
        XCTAssertEqual(try client.recipe("a"), crop)
        _ = try client.data(await client.call(.redo, ["operation_id": undo]))
        XCTAssertEqual(try client.recipe("a").repairs, [saved])
        XCTAssertEqual(try SafeFileWriter.sha256(folder.appendingPathComponent("a.png")), original.sourceDigest)
    }

    @MainActor func testCanvasPointColorAndZoneUseNativeSamples() async throws {
        let (catalog, _) = try await catalog(ids: ["a"])
        let client = try await Client(catalog)
        client.tools.setSharesImages(true)
        let preview = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128])))
        let position: [String: Value] = ["preview_id": try XCTUnwrap(preview["preview_id"]), "point": ["x": 0.32, "y": 0.54]]
        let zone = try client.data(await client.call(.samplePreview, position.merging(["action": "zone"]) { _, value in value }))
        XCTAssertNotNil(zone["ev"]?.number)
        XCTAssertTrue((0...10).contains(try XCTUnwrap(zone["zone"]?.intValue)))
        let add = try await client.job(await client.call(.pointColor, client.edits("a", position.merging(["action": "add"]) { _, value in value })))
        XCTAssertEqual(add["commit_state"], "committed")
        let sample = try XCTUnwrap(client.recipe("a").develop.pointColors.first)
        let patch = try await client.job(await client.call(.pointColor, client.edits("a", [
            "action": "set", "sample_id": .string(sample.id.uuidString), "adjustments": ["hue_shift": -25, "range": 42]])))
        XCTAssertEqual(patch["commit_state"], "committed")
        let changed = try XCTUnwrap(client.recipe("a").develop.pointColors.first)
        XCTAssertEqual(changed.id, sample.id)
        XCTAssertEqual(changed.hue, sample.hue)
        XCTAssertEqual(changed.hueShift, -25)
        XCTAssertEqual(changed.range, 42)
    }

    @MainActor func testMaskBrushCoverageAndLocalPresetPreserveSelectionGeometry() async throws {
        let (catalog, _) = try await catalog(ids: ["a"])
        let client = try await Client(catalog)
        client.tools.setSharesImages(true)
        let create = try await client.job(await client.call(.maskGroup, client.edits("a", ["action": "create", "mask_kind": "brush", "name": "Center"])))
        XCTAssertEqual(create["commit_state"], "committed")
        let created = try XCTUnwrap(client.recipe("a").localAdjustments.first)
        let mask: Value = .string(created.id.uuidString)
        let component: Value = .string(created.components[0].id.uuidString)
        let preview = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128])))
        let position: Value = ["x": 0.5, "y": 0.5]
        let stroke = try await client.job(await client.call(.brushStroke, client.edits("a", [
            "mask_id": mask, "component_id": component, "preview_id": try XCTUnwrap(preview["preview_id"]), "path": .array([position]),
            "flow": 1, "radius": 0.12, "feather": 0.2])))
        XCTAssertEqual(stroke["commit_state"], "committed")
        let drawn = try XCTUnwrap(client.recipe("a").localAdjustments.first)
        XCTAssertEqual(drawn.components[0].strokes[0].points, [MaskPoint(0.5, 0.5)])
        let overlay = try client.data(await client.call(.preview, client.edits("a", [
            "long_edge": 128, "mask_overlay": ["mask_id": mask, "style": "monochrome"]])))
        let overlayID = try XCTUnwrap(overlay["preview_id"])
        XCTAssertEqual(overlay["editable_canvas"], false)
        let inside = try client.data(await client.call(.samplePreview, ["preview_id": overlayID, "point": position]))
        let outside = try client.data(await client.call(.samplePreview, ["preview_id": overlayID, "point": ["x": 0.1, "y": 0.1]]))
        XCTAssertGreaterThan(try XCTUnwrap(inside["rgba"]?.arrayValue?.first?.intValue), 220)
        XCTAssertLessThan(try XCTUnwrap(outside["rgba"]?.arrayValue?.first?.intValue), 5)
        client.error(await client.call(.brushStroke, try client.edits("a", [
            "mask_id": mask, "component_id": component, "preview_id": overlayID, "path": .array([position])])), "stale_preview")

        let adjusted = try await client.job(await client.call(.localAdjustments, client.edits("a", [
            "action": "set", "mask_id": mask, "amount": 0.8,
            "adjustments": ["basic": ["exposure": 0.75], "zone_gains": [0, 0, 0.2, 0, 0]]])))
        XCTAssertEqual(adjusted["commit_state"], "committed")
        let edited = try XCTUnwrap(client.recipe("a").localAdjustments.first)
        XCTAssertEqual(edited.exposure, 0.75)
        XCTAssertEqual(edited.amount, 0.8)
        XCTAssertEqual(edited.components, drawn.components)
        let stored = try await client.job(await client.call(.editLocalPreset, client.edits("a", [
            "action": "create", "mask_id": mask, "name": "Local Tone"])))
        XCTAssertEqual(stored["commit_state"], "committed")
        let preset = try XCTUnwrap(stored["preset"]?.objectValue)
        let presetFields = preset.filter { $0.key != "name" }
        let reset = try await client.job(await client.call(.localAdjustments, client.edits("a", ["action": "reset", "mask_id": mask])))
        XCTAssertEqual(reset["commit_state"], "committed")
        XCTAssertEqual(try client.recipe("a").localAdjustments.first?.exposure, 0)
        let applied = try await client.job(await client.call(.editLocalPreset, client.edits("a",
            presetFields.merging(["action": "apply", "mask_id": mask]) { _, value in value })))
        XCTAssertEqual(applied["commit_state"], "committed")
        XCTAssertEqual(try client.recipe("a").localAdjustments, [edited])
        let removed = try client.data(await client.call(.editLocalPreset, presetFields.merging(["action": "delete"]) { _, value in value }))
        let undo = try XCTUnwrap(removed["operation_id"])
        XCTAssertTrue(try catalog.localParameterPresets().isEmpty)
        _ = try client.data(await client.call(.undo, ["operation_id": undo]))
        XCTAssertEqual(try catalog.localParameterPresets().first?.name, "Local Tone")
    }

    @MainActor func testGradientAndRangeComponentsUseSavedVersionAndRebaseAfterDeletingBase() async throws {
        let (catalog, _) = try await catalog(ids: ["a"])
        let client = try await Client(catalog)
        client.tools.setSharesImages(true)
        let created = try await client.job(await client.call(.maskGroup, client.edits("a", ["action": "create", "mask_kind": "linear"])))
        XCTAssertEqual(created["commit_state"], "committed")
        let group = try XCTUnwrap(client.recipe("a").localAdjustments.first)
        let id: Value = .string(group.id.uuidString)
        let linear: Value = .string(group.components[0].id.uuidString)
        let preview = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128])))
        let positioned = try await client.job(await client.call(.maskShape, client.edits("a", [
            "mask_id": id, "component_id": linear, "preview_id": try XCTUnwrap(preview["preview_id"]),
            "start": ["x": -0.25, "y": 0.25], "end": ["x": 0.75, "y": 0.5]])))
        XCTAssertEqual(positioned["commit_state"], "committed")
        let gradient = try XCTUnwrap(client.recipe("a").localAdjustments.first?.components.first)
        XCTAssertEqual(gradient.start, MaskPoint(0.125, 0.75))
        XCTAssertEqual(gradient.end, MaskPoint(0.625, 0.5))
        let appended = try await client.job(await client.call(.maskComponent, client.edits("a", [
            "action": "add", "mask_id": id, "mask_kind": "color", "mask_operation": "subtract"])))
        XCTAssertEqual(appended["commit_state"], "committed")
        let added = try XCTUnwrap(client.recipe("a").localAdjustments.first?.components.last)
        let color: Value = .string(added.id.uuidString)
        let fresh = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128])))
        let sampled = try await client.job(await client.call(.maskRange, client.edits("a", [
            "action": "replace_sample", "mask_id": id, "component_id": color,
            "preview_id": try XCTUnwrap(fresh["preview_id"]), "point": ["x": 0.5, "y": 0.375]])))
        XCTAssertEqual(sampled["commit_state"], "committed")
        let sample = try XCTUnwrap(client.recipe("a").localAdjustments.first?.components.last?.samples.first)
        XCTAssertEqual(sample.point, MaskPoint(0.5, 0.625))
        let removed = try await client.job(await client.call(.maskComponent, client.edits("a", [
            "action": "delete", "mask_id": id, "component_id": linear])))
        XCTAssertEqual(removed["commit_state"], "committed")
        let remaining = try XCTUnwrap(client.recipe("a").localAdjustments.first?.components.first)
        XCTAssertEqual(remaining.id, added.id)
        XCTAssertEqual(remaining.operation, .replace)
        XCTAssertEqual(remaining.samples, [sample])
        let state = try client.data(await client.call(.maskState, client.edits("a", ["mask_id": id, "component_id": color])))
        XCTAssertEqual(state["mask"]?.objectValue?["components"]?.arrayValue?.count, 1)
    }

    @MainActor func testSmartSelectionRevisionBindsOverlayAndNativeCommit() async throws {
        let (catalog, _) = try await catalog(ids: ["a"])
        let client = try await Client(catalog)
        let model = client.model
        client.tools.setSharesImages(true)
        let original = try client.recipe("a")
        _ = try client.data(await client.call(.selectPhotos, ["action": "replace", "photo_ids": ["a"]]))
        _ = try client.data(await client.call(.workspaceView, ["view": "develop"]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (!model.canEdit || model.orientedSourceSize == nil) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.canEdit)
        _ = try client.data(await client.call(.workspaceView, ["view": "develop", "tool": "mask"]))
        if SmartMaskEngine.bundledModels.objectDirectory == nil {
            client.error(await client.call(.smartStart, try client.edits("a", ["workflow": "object"])), "smart_model_unavailable")
        }
        let started = try await client.job(await client.call(.smartStart, client.edits("a", ["workflow": "people"])))
        XCTAssertEqual(started["commit_state"], "not_committed")
        XCTAssertEqual(started["smart_mask"]?.objectValue?["ready"], true)
        XCTAssertEqual(try client.recipe("a"), original)

        // Supply known native candidate coverage independently of optional model bundles.
        var session = try XCTUnwrap(model.smartMaskSession)
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        let candidates = try [8..<16, 16..<24].map { columns in
            let row: [Float] = (0..<32).map { columns.contains($0) ? 1 : 0 }
            let values = (0..<16).flatMap { _ in row }
            let tile = try SmartMaskTile(values: values, width: 32, height: 16, region: region)
            return SmartMaskCandidate(raster: SmartMaskRaster(source: session.source, model: "synthetic-object", base: tile),
                                      score: 1, selectedPixels: 128)
        }
        session.workflow = .object
        session.candidates = candidates
        model.smartMaskSession = session
        model.chooseSmartCandidate(0)
        let initial = try client.data(await client.call(.maskState, client.edits("a")))
        let state = try XCTUnwrap(initial["smart_mask"]?.objectValue)
        let keys: Set<String> = ["smart_session_id", "selection_revision"]
        let identity = state.filter { keys.contains($0.key) }
        let png = try client.data(await client.call(.preview, client.edits("a", ["long_edge": 128,
            "smart_overlay": .object(identity.merging(["target": "candidate", "index": 1, "style": "monochrome"]) { _, value in value })])))
        XCTAssertEqual(png["editable_canvas"], false)
        let preview = try XCTUnwrap(png["preview_id"])
        let inside = try client.data(await client.call(.samplePreview, ["preview_id": preview, "point": ["x": 0.75, "y": 0.5]]))
        let outside = try client.data(await client.call(.samplePreview, ["preview_id": preview, "point": ["x": 0.25, "y": 0.5]]))
        XCTAssertGreaterThan(try XCTUnwrap(inside["rgba"]?.arrayValue?.first?.intValue), 220)
        XCTAssertLessThan(try XCTUnwrap(outside["rgba"]?.arrayValue?.first?.intValue), 5)
        let chosen = try await client.job(await client.call(.smartEdit, client.edits("a",
            identity.merging(["action": "select_candidate", "candidate_index": 1]) { _, value in value })))
        let updated = try XCTUnwrap(chosen["smart_mask"]?.objectValue).filter { keys.contains($0.key) }
        XCTAssertNotEqual(updated, identity)
        client.error(await client.call(.smartApply, try client.edits("a", identity)), "stale_smart_selection")
        let committed = try await client.job(await client.call(.smartApply, client.edits("a", updated)))
        XCTAssertEqual(committed["commit_state"], "committed")
        XCTAssertNil(model.smartMaskSession)
        XCTAssertEqual(try client.recipe("a").localAdjustments.first?.components.first?.raster, candidates[1].raster)
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(committed["operation_id"])]))
        XCTAssertEqual(try client.recipe("a"), original)
    }

    @MainActor func testPerspectiveGuideUsesCropCanvasAndSharesUndoWithNativeSolver() async throws {
        let (catalog, _) = try await catalog(ids: ["a"])
        let client = try await Client(catalog)
        let model = client.model
        client.tools.setSharesImages(true)
        let original = try client.recipe("a")
        model.detectPerspectiveLines = { _ in [] }
        let automatic = try await client.job(await client.call(.solvePerspective, client.edits("a", ["mode": "auto"])))
        XCTAssertEqual(automatic["commit_state"], "not_committed")
        XCTAssertEqual(automatic["items"]?.arrayValue?.first?.objectValue?["result"]?.objectValue?["solution"], "no_agreement")
        _ = try client.data(await client.call(.selectPhotos, ["action": "replace", "photo_ids": ["a"]]))
        _ = try client.data(await client.call(.workspaceView, ["view": "develop"]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (!model.canEdit || model.orientedSourceSize == nil) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try client.data(await client.call(.workspaceView, ["view": "develop", "tool": "crop"]))
        let state = try client.data(await client.call(.perspectiveGuides, client.edits("a", ["action": "begin", "guide_mode": "straighten"])))
        XCTAssertEqual(state["guide_mode"], "straighten")
        let full = try client.data(await client.call(.preview, client.edits("a", ["preview_variant": "crop_canvas", "long_edge": 128])))
        let line = try client.data(await client.call(.perspectiveGuides, client.edits("a", [
            "action": "add", "preview_id": try XCTUnwrap(full["preview_id"]),
            "start": ["x": 0.125, "y": 0.5], "end": ["x": 0.875, "y": 0.625]])))
        XCTAssertEqual(line["commit_state"], "committed")
        XCTAssertEqual(line["perspective_guides"]?.arrayValue?.first?.objectValue?["source_end"], ["x": 0.875, "y": 0.625])
        XCTAssertGreaterThan(abs(try client.recipe("a").straightenDegrees), 1)
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(line["operation_id"])]))
        XCTAssertEqual(try client.recipe("a"), original)
    }

    @MainActor func testParameterGroupsValidateAndPreserveUnchangedControls() async throws {
        let (catalog, _) = try await catalog()
        let client = try await Client(catalog)
        let original = try client.recipe("a")
        let writes: [(AppMCPTool, [String: Value])] = [
            (.toneCurve, ["action": "insert", "channel": "red", "x": 0.4, "y": 0.47]),
            (.toneCurve, ["action": "move", "channel": "red", "point_index": 2, "x": 0.45, "y": 0.52]),
            (.toneCurve, ["action": "remove", "channel": "red", "point_index": 1]),
            (.zoneLighting, ["gains": [0.25, 0, -0.25, 0, 0.2]]),
            (.colorAdjustments, ["adjustments": ["hsl": ["aqua": ["hue": 18]], "black_white_mixer": ["red": 20],
                                                "grading": ["balance": -15, "highlights": ["hue": 56, "saturation": 12]]]]),
            (.detailAdjustments, ["adjustments": ["sharpening_amount": 60, "denoise_color": 20, "purple_lower": 230, "purple_upper": 245]]),
            (.effects, ["adjustments": ["vignette_style": "colorPriority", "vignette_amount": -18, "grain_amount": 12, "grain_size": 40]])
        ]
        for (tool, fields) in writes {
            let state = try await client.job(await client.call(tool, client.edits("a", fields)))
            XCTAssertEqual(state["state"], "succeeded", String(describing: state))
        }
        let changed = try client.recipe("a")
        XCTAssertEqual(changed.develop.curves?.channels[1][1], CurvePoint(x: 0.45, y: 0.52))
        XCTAssertEqual(changed.develop.zones?.gains[2], -0.25)
        XCTAssertEqual(changed.develop.mixer[4].hue, 18)
        XCTAssertEqual(changed.develop.blackWhiteMixer[0], 20)
        XCTAssertEqual(changed.develop.grading.highlights.hue, 56)
        XCTAssertEqual(changed.sharpening.amount, 60)
        XCTAssertEqual(changed.manualDefringe.purpleUpper, 245)
        XCTAssertEqual(changed.vignette.style, .colorPriority)
        XCTAssertNotEqual(changed.grain.seed, 0)
        XCTAssertEqual(changed.crop, original.crop)
        let details = try client.data(await client.call(.photoRecipe, ["photo_id": "a"]))
        let recipe = try XCTUnwrap(details["recipe"]?.objectValue)
        XCTAssertEqual(recipe["global"]?.objectValue?["exposure"], 0.0)
        XCTAssertNil(recipe["detail"]?.objectValue?["raw_lens_correction"])
        client.error(await client.call(.colorAdjustments, try client.edits("a", ["adjustments": ["hsl": ["aqua": ["typo": 18]]]])), "invalid_arguments")
        let invalid = try await client.job(await client.call(.detailAdjustments, client.edits("a", ["adjustments": ["purple_lower": 243]])))
        XCTAssertEqual(invalid["error_code"], "invalid_adjustment")
        let rawOnRaster = try await client.job(await client.call(.detailAdjustments, client.edits("a", ["adjustments": ["raw_lens_correction": true]])))
        XCTAssertEqual(rawOnRaster["error_code"], "invalid_arguments")
        XCTAssertEqual(try client.recipe("a"), changed)
        let reset = try await client.job(await client.call(.resetAdjustments, client.edits("a", ["group": "curves"])))
        XCTAssertEqual(reset["commit_state"], "committed")
        XCTAssertNil(try client.recipe("a").develop.curves)
        XCTAssertEqual(try client.recipe("a").vignette, changed.vignette)
    }

    @MainActor func testBeforeAfterAndSnapshotsUseSavedRevisionAndLeavePreviewReadOnly() async throws {
        let (catalog, _) = try await catalog()
        let client = try await Client(catalog)
        let snapshotResult = try client.data(await client.call(.saveSnapshot, client.edits("a", ["name": "Start"])))
        let snapshot = try XCTUnwrap(snapshotResult["snapshot"]?.objectValue)
        let id = try XCTUnwrap(snapshot["snapshot_id"])
        let oldSnapshot = try XCTUnwrap(snapshot["snapshot_revision"])
        XCTAssertEqual(snapshotResult["operation_id"], .null)
        let renamed = try client.data(await client.call(.saveSnapshot, client.edits("a", [
            "name": "Reference", "snapshot_id": id, "snapshot_revision": oldSnapshot
        ])))
        let snapshotRevision = try XCTUnwrap(renamed["snapshot"]?.objectValue?["snapshot_revision"])
        let change = try await client.job(await client.call(.globalAdjustments, client.edits("a", ["adjustments": ["exposure": 1]])))
        XCTAssertEqual(change["state"], "succeeded")
        let beforeArgs = try client.edits("a", ["preview_variant": "before", "snapshot_id": id, "long_edge": 128])
        client.error(await client.call(.preview, beforeArgs), "image_access_disabled")
        client.tools.setSharesImages(true)
        let before = await client.call(.preview, beforeArgs)
        let after = await client.call(.preview, try client.edits("a", ["long_edge": 128]))
        let original = try client.data(await client.call(.preview, client.edits("a", ["preview_variant": "original", "long_edge": 128])))
        XCTAssertEqual(try client.data(before)["width"], 64)
        XCTAssertEqual(try client.data(after)["width"], 64)
        XCTAssertEqual(original["width"], 128)
        XCTAssertNotEqual(before.content.last, after.content.last)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, 2)
        _ = try client.data(await client.call(.selectPhotos, ["action": "replace", "photo_ids": ["a"]]))
        _ = try client.data(await client.call(.workspaceView, ["view": "develop"]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !client.model.canEdit && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(client.model.canEdit)
        client.model.changeRecipe({ $0.exposure = 0.25 }, commit: false)
        client.error(await client.call(.globalAdjustments, try client.edits("a", ["adjustments": ["exposure": 2]])),
                     "native_interaction_active")
        client.model.undo.groupsByEvent = false
        client.model.undo.beginUndoGrouping()
        client.model.changeRecipe({ $0.exposure = 1 })
        client.model.undo.endUndoGrouping()
        client.model.undo.groupsByEvent = true
        XCTAssertFalse(client.model.dirty)
        let shown = try client.data(await client.call(.beforeAfter, client.edits("a", ["before_layout": "split", "snapshot_id": id])))
        XCTAssertEqual(shown["before_after"]?.objectValue?["layout"], "split")
        XCTAssertEqual(client.model.beforeReference?.title, "Reference")
        let preview = try client.data(await client.call(.adjustmentPreview, client.edits("a", ["action": "saved_edit", "snapshot_id": id])))
        XCTAssertEqual(preview["adjustment_preview"]?.objectValue?["kind"], "saved_edit")
        let applied = try await client.job(await client.call(.applyEditRecord, client.edits("a", ["snapshot_id": id])))
        XCTAssertEqual(applied["commit_state"], "committed")
        XCTAssertEqual(try client.recipe("a").exposure, 0)
        XCTAssertEqual(client.model.recipe?.exposure, 0)
        XCTAssertNil(client.model.savedEditPreview)
        client.error(await client.call(.deleteSnapshot, try client.edits("a", ["snapshot_id": id, "snapshot_revision": oldSnapshot])), "stale_snapshot")
        let deleted = try client.data(await client.call(.deleteSnapshot, client.edits("a", ["snapshot_id": id, "snapshot_revision": snapshotRevision])))
        XCTAssertTrue(try catalog.snapshots(photoID: "a").isEmpty)
        XCTAssertEqual(client.model.beforeReference?.title, "Reference")
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(deleted["operation_id"])]))
        XCTAssertEqual(try catalog.snapshots(photoID: "a").first?.title, "Reference")
    }

    @MainActor func testRAWDetailUsesDecoderCapabilitiesAndClearsToDefault() async throws {
        let sample = try MoreRAWTests.sample("leica_m8_8bit_uncompressed.DNG")
        let (catalog, folder) = try await catalog(ids: [])
        let root = try XCTUnwrap(catalog.roots().first)
        let url = folder.appendingPathComponent("public.DNG")
        try FileManager.default.copyItem(at: sample, to: url)
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: folder)
        try catalog.index(photo)
        let client = try await Client(catalog)
        let initial = try client.data(await client.call(.photoRecipe, ["photo_id": .string(photo.id)]))
        let defaults = try XCTUnwrap(initial["recipe"]?.objectValue?["raw_defaults"]?.objectValue)
        let supported = try XCTUnwrap(defaults.first { $0.value.number != nil }?.key)
        let saved = try await client.job(await client.call(.detailAdjustments, client.edits(photo.id, ["adjustments": .object([supported: 0.37])])))
        XCTAssertEqual(saved["commit_state"], "committed")
        let cleared = try await client.job(await client.call(.detailAdjustments, client.edits(photo.id, ["adjustments": .object([supported: .null])])))
        XCTAssertEqual(cleared["commit_state"], "committed")
        XCTAssertTrue(try client.recipe(photo.id).rawDetails.isDefault)
        XCTAssertEqual(try SafeFileWriter.sha256(url), try SafeFileWriter.sha256(sample))
    }

    @MainActor func testPresetsAndExplicitBatchTransfersKeepTargetIdentity() async throws {
        let (catalog, _) = try await catalog()
        let client = try await Client(catalog)
        var source = try client.recipe("a"); source.exposure = 2
        try catalog.saveRecipe(id: "a", recipe: source)
        let before = try client.recipe("b")
        let created = try client.data(await client.call(.editPreset, client.edits("a", [
            "action": "create", "name": "Bright", "preset_group": "Studio", "groups": ["tone"]
        ])))
        let preset = try XCTUnwrap(created["preset"]?.objectValue)
        let id = try XCTUnwrap(preset["preset_id"])
        let revision = try XCTUnwrap(preset["preset_revision"])
        let favorited = try client.data(await client.call(.editPreset, [
            "action": "favorite", "preset_id": id, "preset_revision": revision, "favorite": true
        ]))
        let current = try XCTUnwrap(favorited["preset"]?.objectValue?["preset_revision"])
        let list = try client.data(await client.call(.listPresets, ["search": "bright", "favorites_only": true, "preset_group": "Studio"]))
        XCTAssertEqual(list["total"], 1)
        var apply: [String: Value] = ["action": "preset", "preset_id": id, "preset_revision": revision, "amount": 0.5,
                                      "photo_ids": ["b"], "expected_revisions": try client.expected(["b"])]
        client.error(await client.call(.transferAdjustments, apply), "stale_preset")
        apply["preset_revision"] = current
        let applied = try await client.job(await client.call(.transferAdjustments, apply))
        XCTAssertEqual(applied["commit_state"], "committed")
        XCTAssertEqual(try client.recipe("b").exposure, 1)
        XCTAssertEqual(try client.recipe("b").sourceDigest, before.sourceDigest)
        XCTAssertEqual(try client.recipe("b").crop, before.crop)
        let copied = try await client.job(await client.call(.transferAdjustments, [
            "action": "copy", "photo_id": "a", "expected_revisions": try client.expected(["a"])
        ]))
        XCTAssertEqual(copied["photo_id"], "a")
        let pasted = try await client.job(await client.call(.transferAdjustments, [
            "action": "paste", "photo_ids": ["b"], "groups": ["tone"], "expected_revisions": try client.expected(["b"])
        ]))
        XCTAssertEqual(pasted["commit_state"], "committed")
        XCTAssertEqual(try client.recipe("b").exposure, 2)
        let deleted = try client.data(await client.call(.editPreset, ["action": "delete", "preset_id": id, "preset_revision": current]))
        XCTAssertTrue(try catalog.presets().isEmpty)
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(deleted["operation_id"])]))
        XCTAssertTrue(try XCTUnwrap(catalog.preset(id.stringValue!)).favorite)
    }

    @MainActor func testExposureBatchConflictSkipsMissingAndRestoresUntouchedRecipe() async throws {
        let (catalog, folder) = try await catalog(ids: ["a", "b", "c"], withRecipes: false)
        let client = try await Client(catalog)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("c.png"))
        let batch: [String: Value] = ["photo_ids": ["a", "b", "c"], "expected_revisions": try client.expected(["a", "b", "c"]), "delta": 0.5]
        let applied = try await client.job(await client.call(.relativeExposure, batch))
        XCTAssertEqual(applied["state"], "partially_succeeded")
        XCTAssertEqual(applied["changed_count"], 2)
        XCTAssertNil(try catalog.photo("c")?.recipe)
        client.error(await client.call(.relativeExposure, batch), "stale_photo")
        _ = try client.data(await client.call(.selectPhotos, ["action": "replace", "photo_ids": ["b"]]))
        let operation = try XCTUnwrap(applied["operation_id"])
        _ = try client.data(await client.call(.undo, ["operation_id": operation]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !client.model.canEdit && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(client.model.canEdit)
        XCTAssertNil(try catalog.photo("a")?.recipe)
        XCTAssertNil(try catalog.photo("b")?.recipe)
        _ = try client.data(await client.call(.redo, ["operation_id": operation]))
        XCTAssertEqual(try client.recipe("b").exposure, 0.5)
        _ = try client.data(await client.call(.undo, ["operation_id": operation]))
        let matched = try await client.job(await client.call(.matchExposure, [
            "photo_id": "a", "photo_ids": ["b"], "expected_revisions": try client.expected(["a", "b"])
        ]))
        XCTAssertEqual(matched["state"], "succeeded")
        XCTAssertEqual(try client.recipe("b").exposure, 1, accuracy: 1e-9)
        let auto = try await client.job(await client.call(.automaticAdjustment, client.edits("b", ["action": "tone"])))
        XCTAssertEqual(auto["state"], "succeeded", String(describing: auto))
        XCTAssertTrue((-3...3).contains(try client.recipe("b").exposure))
    }

    @MainActor func testXMPPlanUsesNativeAuthorizationAndImportsReviewedSparseSettings() async throws {
        let (catalog, folder) = try await catalog()
        let url = folder.appendingPathComponent("synthetic.xmp")
        try """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
          <rdf:Description crs:Name="Sparse contrast" crs:Contrast2012="24"/>
        </rdf:RDF>
        """.write(to: url, atomically: true, encoding: .utf8)
        let client = try await Client(catalog) { panel in
            XCTAssertTrue(panel.allowsMultipleSelection)
            return url
        }
        let authorized = try await client.job(await client.call(.fileAccess, ["purpose": "xmp_presets"]))
        let plan = try await client.job(await client.call(.planXMP, ["access_id": try XCTUnwrap(authorized["access_id"])]))
        XCTAssertEqual(plan["eligible_count"], 1)
        let candidate = try XCTUnwrap(plan["items"]?.arrayValue?.first?.objectValue?["candidate_id"])
        let args: [String: Value] = ["plan_id": try XCTUnwrap(plan["plan_id"]), "candidate_ids": .array([candidate])]
        let imported = try client.data(await client.call(.importXMP, args))
        XCTAssertEqual(imported["imported_count"], 1)
        let duplicate = try client.data(await client.call(.importXMP, args))
        XCTAssertEqual(duplicate["skipped_count"], 1)
        let preset = try XCTUnwrap(imported["items"]?.arrayValue?.first?.objectValue?["preset"]?.objectValue)
        let applied = try await client.job(await client.call(.transferAdjustments, [
            "action": "preset", "preset_id": try XCTUnwrap(preset["preset_id"]), "preset_revision": try XCTUnwrap(preset["preset_revision"]),
            "photo_ids": ["b"], "expected_revisions": try client.expected(["b"])
        ]))
        XCTAssertEqual(applied["state"], "succeeded")
        XCTAssertEqual(try client.recipe("b").contrast, 1.24, accuracy: 1e-9)
        XCTAssertEqual(try client.recipe("b").exposure, 0)
    }
}
