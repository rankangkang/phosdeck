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
