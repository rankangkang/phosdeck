import GRDB
import MCP
import XCTest
@testable import Phosdeck

final class AgentOrganizationTests: XCTestCase {
    private struct Client {
        let tools: AppMCPTools
        let catalog: Value
        let epoch: Value

        @MainActor init(_ model: AppModel) async throws {
            let tools = AppMCPTools(model: model, appName: "Phosdeck Test", version: "1", bundleID: "test", sharesImages: false)
            let workspace = await tools.call(.init(name: AppMCPTool.workspace.rawValue))
            let data = try XCTUnwrap(workspace.structuredContent?.objectValue?["data"]?.objectValue)
            self.tools = tools
            catalog = try XCTUnwrap(data["catalog_session_id"])
            epoch = try XCTUnwrap(data["request_epoch"])
        }
        func call(_ tool: AppMCPTool, _ args: [String: Value] = [:], request: String = UUID().uuidString) async -> CallTool.Result {
            var arguments = args
            if tool.needsCatalog { arguments["catalog_session_id"] = catalog }
            if tool.needsRequestID {
                arguments["request_epoch"] = epoch
                arguments["request_id"] = .string(request)
            }
            return await tools.call(.init(name: tool.rawValue, arguments: arguments))
        }
        func data(_ result: CallTool.Result, line: UInt = #line) throws -> [String: Value] {
            XCTAssertNotEqual(result.isError, true, String(describing: result.structuredContent), line: line)
            return try XCTUnwrap(result.structuredContent?.objectValue?["data"]?.objectValue, line: line)
        }
        func job(_ result: CallTool.Result, line: UInt = #line) async throws -> [String: Value] {
            let id = try XCTUnwrap(data(result, line: line)["job_id"], line: line)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            repeat {
                let state = try data(await call(.job, ["job_id": id]), line: line)
                if let phase = state["state"]?.stringValue, ["succeeded", "partially_succeeded", "failed", "cancelled"].contains(phase) { return state }
                try await Task.sleep(for: .milliseconds(20))
            } while clock.now < deadline
            XCTFail("Timed out waiting for the Agent job.", line: line)
            return [:]
        }
        func error(_ result: CallTool.Result, _ code: String, line: UInt = #line) {
            XCTAssertEqual(result.isError, true, line: line)
            XCTAssertEqual(result.structuredContent?.objectValue?["error"]?.objectValue?["code"], .string(code), line: line)
        }
    }

    private func temporaryCatalog() throws -> (URL, CatalogStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-organization-" + UUID().uuidString)
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        addTeardownBlock {
            try catalog.database.close()
            try FileManager.default.removeItem(at: folder)
        }
        return (folder, catalog)
    }
    @MainActor private func connect(_ catalog: CatalogStore) async throws -> (AppModel, Client) {
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        return (model, try await Client(model))
    }
    private func addSyntheticRows(_ catalog: CatalogStore, folder: URL, ids: [String]) throws {
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        for (index, id) in ids.enumerated() {
            let date = String(format: "2026:11:11 12:%02d:%02d", index / 60, index % 60)
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(),
                                    identityKey: id, captureDate: date, width: 1, height: 1))
        }
    }
    private func ids(_ data: [String: Value], key: String = "photo_id") -> [String] {
        data["items"]?.arrayValue?.compactMap { $0.objectValue?[key]?.stringValue } ?? []
    }

    @MainActor func testRegularAndQuickCollectionsKeepHeldMatchesAndUndoMemberOrder() async throws {
        let (folder, catalog) = try temporaryCatalog()
        let photos = (0..<205).map { String(format: "p%03d", $0) }
        try addSyntheticRows(catalog, folder: folder, ids: photos + ["outside"])
        try catalog.setOrganization(ids: photos, rating: 3)
        try catalog.changeStacks(.group(top: photos[0], members: [photos[1]]))
        let (model, client) = try await connect(catalog)
        let query = try client.data(await client.call(.setQuery, ["rating_threshold": 3, "hold_results": true, "sort": "filename"]))
        XCTAssertEqual(query["matched_count"], 205)
        XCTAssertEqual(query["visible_count"], 204)
        try catalog.setOrganization(ids: [photos[1]], rating: 0)
        let result = try client.data(await client.call(.collectionMembers, [
            "action": "collect_results", "name": "Review set", "query_revision": try XCTUnwrap(query["query_revision"])
        ]))
        let id = try XCTUnwrap(result["collection_id"])
        XCTAssertEqual(result["changed_count"], 205)
        XCTAssertEqual(result["operation_id"], .null)
        XCTAssertEqual(try catalog.collectionOrder(id.stringValue!), photos)

        let before = try client.data(await client.call(.getCollection, ["collection_id": id, "page_size": 2]))
        let revision = try XCTUnwrap(before["collection_revision"])
        XCTAssertEqual(ids(before), Array(photos.prefix(2)))
        client.error(await client.call(.collectionMembers, [
            "action": "add", "collection_id": id, "photo_ids": ["outside", "missing"]
        ]), "photo_unavailable")
        XCTAssertEqual(try catalog.collectionOrder(id.stringValue!), photos)
        let added = try client.data(await client.call(.collectionMembers, [
            "action": "add", "collection_id": id, "photo_ids": ["outside"], "collection_revision": revision
        ]))
        XCTAssertEqual(added["changed_photo_ids"], ["outside"])
        client.error(await client.call(.deleteCollection, ["collection_id": id, "collection_revision": revision]), "stale_collection")
        XCTAssertEqual(try catalog.collectionOrder(id.stringValue!).last, "outside")

        let moved = try client.data(await client.call(.reorderCollection, ["action": "move", "collection_id": id,
            "photo_ids": [.string(photos.last!)], "before_photo_id": .string(photos[0])]))
        XCTAssertEqual(try catalog.collectionOrder(id.stringValue!).first, photos.last)
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(moved["operation_id"])]))
        XCTAssertEqual(try catalog.collectionOrder(id.stringValue!), photos + ["outside"])
        _ = try client.data(await client.call(.targetCollection, ["collection_id": id]))
        let removed = try client.data(await client.call(.deleteCollection, ["collection_id": id]))
        XCTAssertNil(model.targetCollectionID)
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(removed["operation_id"])]))
        XCTAssertEqual(try catalog.collectionOrder(id.stringValue!), photos + ["outside"])
        XCTAssertEqual(model.targetCollectionID, id.stringValue)

        _ = try client.data(await client.call(.targetCollection))
        let quick = try client.data(await client.call(.quickCollection, ["action": "add", "photo_ids": ["outside"]]))
        let quickID = try XCTUnwrap(quick["target_collection_id"])
        XCTAssertEqual(quick["changed_count"], 1)
        XCTAssertEqual(try catalog.collectionOrder(quickID.stringValue!), ["outside"])
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(quick["operation_id"])]))
        XCTAssertEqual(model.targetCollectionID, quickID.stringValue)
        XCTAssertTrue(try catalog.collectionOrder(quickID.stringValue!).isEmpty)
        client.error(await client.call(.quickCollection, ["action": "add", "collection_id": id, "photo_ids": ["outside"]]), "stale_collection")
        XCTAssertEqual(try catalog.photoCount(), 206)
        _ = try client.data(await client.call(.setQuery, ["source_id": .string("collection:" + id.stringValue!), "clear_filters": true]))
        _ = try client.data(await client.call(.reorderCollection, ["collection_id": id, "action": "set_manual_order", "manual_order": true]))
        XCTAssertTrue(model.query.isManualCollectionOrder)
    }

    @MainActor func testSmartCollectionReadsRulesAndUsesNativeRuleValidation() async throws {
        let (folder, catalog) = try temporaryCatalog()
        try addSyntheticRows(catalog, folder: folder, ids: ["a", "b", "c"])
        try catalog.setOrganization(ids: ["b", "c"], rating: 3)
        let (model, client) = try await connect(catalog)
        _ = try client.data(await client.call(.setQuery, ["rating_threshold": 3]))
        let saved = try client.data(await client.call(.saveSmartCollection, ["name": "Three stars", "from_current_query": true]))
        let id = try XCTUnwrap(saved["collection_id"])
        XCTAssertEqual(saved["photo_count"], 2)
        XCTAssertEqual(model.scope, "all")
        let initial = try client.data(await client.call(.getCollection, ["collection_id": id]))
        XCTAssertEqual(ids(initial), ["b", "c"])
        client.error(await client.call(.collectionMembers, ["collection_id": id, "action": "add", "photo_ids": ["a"]]), "collection_unavailable")
        client.error(await client.call(.saveSmartCollection, ["collection_id": id, "rules": [
            "source_id": try XCTUnwrap(initial["source_id"]), "conditions": [["field": "rating", "operator": "equal", "value": "0"]]
        ]]), "invalid_arguments")

        let edited = try client.data(await client.call(.saveSmartCollection, ["collection_id": id, "name": "Unrated or picked", "rules": [
            "source_id": "all", "match": "any", "conditions": [
                ["field": "rating", "operator": "equal", "value": "0"], ["field": "flag", "operator": "equal", "value": "1"]
            ]
        ]]))
        XCTAssertEqual(edited["photo_count"], 1)
        let editedResult = try client.data(await client.call(.getCollection, ["collection_id": id]))
        XCTAssertEqual(ids(editedResult), ["a"])
        XCTAssertEqual(editedResult["rules"]?.objectValue?["match"], "any")
        let repeated = try client.data(await client.call(.saveSmartCollection, ["collection_id": id,
            "rules": try XCTUnwrap(editedResult["rules"])]))
        XCTAssertEqual(repeated["commit_state"], "not_committed")
        XCTAssertEqual(repeated["operation_id"], .null)
        let op = try XCTUnwrap(edited["operation_id"])
        _ = try client.data(await client.call(.undo, ["operation_id": op]))
        let restored = try client.data(await client.call(.getCollection, ["collection_id": id]))
        XCTAssertEqual(ids(restored), ["b", "c"])
        let removed = try client.data(await client.call(.deleteSmartCollection, ["collection_id": id]))
        client.error(await client.call(.getCollection, ["collection_id": id]), "collection_unavailable")
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(removed["operation_id"])]))
        XCTAssertEqual(try catalog.photoCount(), 3)
        XCTAssertEqual(try catalog.collections().first?.name, "Three stars")
    }

    @MainActor func testVirtualCopiesFromSavedEditsAndRemovalPreserveSourceAndVersions() async throws {
        let (folder, catalog) = try temporaryCatalog()
        let file = folder.appendingPathComponent("Synthetic.png")
        try PNGFixture.data().write(to: file)
        let root = try catalog.addRoot(url: folder, bookmark: AccessLease.bookmark(folder, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: folder)
        try catalog.index(photo)
        let pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(.init(photo: photo, root: root, recipe: nil))
        recipe.exposure = 0.5
        try catalog.saveRecipe(id: photo.id, recipe: recipe, title: "First exposure")
        try catalog.createSnapshot(photoID: photo.id, title: "Saved exposure")
        recipe.exposure = 1.5
        try catalog.saveRecipe(id: photo.id, recipe: recipe, title: "Current exposure")
        let (model, client) = try await connect(catalog)
        defer { withExtendedLifetime(model) {} }
        let id = Value.string(photo.id), expected = try XCTUnwrap(catalog.photo(photo.id))
        let snapshots = try client.data(await client.call(.listEditRecords, ["photo_id": id, "record_type": "snapshots"]))
        let snapshotID = try XCTUnwrap(snapshots["items"]?.arrayValue?.first?.objectValue?["snapshot_id"])
        let history = try client.data(await client.call(.listEditRecords, ["photo_id": id, "page_size": 1, "offset": 1]))
        let historyID = try XCTUnwrap(history["items"]?.arrayValue?.first?.objectValue?["history_id"])
        client.error(await client.call(.createCopies, ["photo_ids": [id], "expected_revisions": .object([
            photo.id: ["source_revision": .int(expected.revision), "recipe_revision": 0]
        ])]), "stale_photo")

        let request: [String: Value] = ["photo_ids": [id], "snapshot_id": snapshotID]
        let created = await client.call(.createCopies, request, request: "snapshot-copy")
        let copyData = try client.data(created)
        let copyID = try XCTUnwrap(ids(copyData).first)
        let retry = await client.call(.createCopies, request, request: "snapshot-copy")
        XCTAssertEqual(created.structuredContent, retry.structuredContent)
        XCTAssertEqual(try catalog.versions(sourceID: photo.sourceKey).count, 2)
        let made = try XCTUnwrap(catalog.photo(copyID))
        XCTAssertEqual(made.sourceKey, photo.sourceKey)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(made.recipe)).exposure, 0.5)
        let operation = try XCTUnwrap(copyData["operation_id"])
        _ = try client.data(await client.call(.undo, ["operation_id": operation]))
        XCTAssertNil(try catalog.photo(copyID))
        _ = try client.data(await client.call(.redo, ["operation_id": operation]))
        XCTAssertNotNil(try catalog.photo(copyID))

        let second = try client.data(await client.call(.createCopies, ["photo_ids": [id], "history_id": historyID]))
        let secondID = try XCTUnwrap(ids(second).first)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(secondID)?.recipe)).exposure, 0.5)
        _ = try client.data(await client.call(.renameVersion, ["photo_id": .string(copyID), "name": "Proof"]))
        let removed = try client.data(await client.call(.removeVersions, ["photo_ids": [id, .string(copyID)]]))
        let versions = try client.data(await client.call(.listVersions, ["source_id": .string(photo.sourceKey)]))
        XCTAssertEqual(ids(versions), [secondID])
        XCTAssertEqual(try SafeFileWriter.sha256(file), recipe.sourceDigest)
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(removed["operation_id"])]))
        XCTAssertEqual(try catalog.photo(copyID)?.copyName, "Proof")
        XCTAssertEqual(try catalog.photo(photo.id)?.recipe, expected.recipe)
    }

    @MainActor func testStackEditingAndStaleAutomaticPlan() async throws {
        let (folder, catalog) = try temporaryCatalog()
        try addSyntheticRows(catalog, folder: folder, ids: ["a", "b", "c", "d", "e", "f"])
        let (model, client) = try await connect(catalog)
        defer { withExtendedLifetime(model) {} }
        let group = try client.data(await client.call(.editStack, ["action": "group", "photo_id": "a", "photo_ids": ["b", "c", "d"]]))
        let id = try XCTUnwrap(group["changed_stack_ids"]?.arrayValue?.first)
        _ = try client.data(await client.call(.editStack, ["action": "cover", "photo_id": "b"]))
        _ = try client.data(await client.call(.editStack, ["action": "move", "photo_id": "d", "direction": "earlier"]))
        let split = try client.data(await client.call(.editStack, ["action": "split", "photo_id": "d"]))
        XCTAssertEqual(try catalog.stacks().count, 2)
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(split["operation_id"])]))
        XCTAssertEqual(try catalog.stacks().first?.members, ["b", "a", "d", "c"])
        _ = try client.data(await client.call(.setQuery, ["search": "a.jpg"]))
        _ = try client.data(await client.call(.editStack, ["action": "expand", "select_all": true]))
        let selected = try client.data(await client.call(.listStacks, ["stack_id": id, "page_size": 2]))
        XCTAssertEqual(ids(selected), ["b", "a"])
        XCTAssertEqual(selected["stack"]?.objectValue?["matched_count"], 1)
        XCTAssertEqual(selected["stack"]?.objectValue?["collapsed"], false)
        _ = try client.data(await client.call(.editStack, ["action": "collapse", "stack_ids": [id]]))
        _ = try client.data(await client.call(.editStack, ["action": "remove", "photo_ids": ["d"]]))
        _ = try client.data(await client.call(.editStack, ["action": "ungroup", "photo_ids": ["a"]]))
        XCTAssertTrue(try catalog.stacks().isEmpty)
        _ = try client.data(await client.call(.setQuery, ["clear_filters": true]))

        let request: [String: Value] = ["photo_ids": ["e", "f"], "interval_seconds": 1]
        let oldPlan = try await client.job(client.call(.planStacks, request))
        XCTAssertEqual(oldPlan["group_count"], 1)
        try await catalog.database.write { try $0.execute(sql: "UPDATE photo SET captureDate=? WHERE id='f'", arguments: ["2026:11:11 12:00:06"]) }
        client.error(await client.call(.applyStacks, ["plan_id": try XCTUnwrap(oldPlan["plan_id"])]), "stale_plan")
        XCTAssertTrue(try catalog.stacks().isEmpty)
        let fresh = try await client.job(client.call(.planStacks, ["photo_ids": ["e", "f"], "interval_seconds": 2]))
        let applied = try client.data(await client.call(.applyStacks, ["plan_id": try XCTUnwrap(fresh["plan_id"])]))
        XCTAssertEqual(try catalog.stacks().first?.members, ["e", "f"])
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(applied["operation_id"])]))
        XCTAssertTrue(try catalog.stacks().isEmpty)
    }

    @MainActor func testPairDetectionVerificationApplyUnlinkAndChangedOriginal() async throws {
        let sample = try MoreRAWTests.sample("a7iii_12bit_compressed.ARW")
        let (folder, catalog) = try temporaryCatalog()
        let rawURL = folder.appendingPathComponent("capture.ARW")
        let jpegURL = folder.appendingPathComponent("capture.jpg")
        let alternate = folder.appendingPathComponent("alternate.jpg")
        try FileManager.default.copyItem(at: sample, to: rawURL)
        try ImportTests().image(jpegURL, color: .red)
        try ImportTests().image(alternate, color: .blue)
        let root = try catalog.addRoot(url: folder, bookmark: AccessLease.bookmark(folder, readOnly: true))
        let raw = try ReferenceImporter.inspect(url: rawURL, root: root, rootURL: folder)
        let jpeg = try ReferenceImporter.inspect(url: jpegURL, root: root, rootURL: folder)
        let other = try ReferenceImporter.inspect(url: alternate, root: root, rootURL: folder)
        for photo in [raw, jpeg, other] { try catalog.index(photo) }
        let (model, client) = try await connect(catalog)
        defer { withExtendedLifetime(model) {} }
        let detected = try await client.job(client.call(.planPairs, ["action": "detect", "photo_ids": [.string(raw.id)]]))
        XCTAssertEqual(detected["state"], "succeeded")
        XCTAssertEqual(detected["eligible_count"], 1)
        let candidate = try XCTUnwrap(ids(detected, key: "candidate_id").first)
        let plan = try XCTUnwrap(detected["plan_id"])
        client.error(await client.call(.applyPairs, ["plan_id": plan, "candidate_ids": [.string(candidate)]]), "stale_plan")
        let verified = try await client.job(client.call(.planPairs, ["action": "verify", "plan_id": plan, "candidate_ids": [.string(candidate)]]))
        XCTAssertEqual(verified["verified_count"], 1)
        let apply: [String: Value] = ["plan_id": try XCTUnwrap(verified["plan_id"]), "candidate_ids": [.string(candidate)]]
        let accepted = await client.call(.applyPairs, apply, request: "apply-pair")
        let saved = try await client.job(accepted)
        XCTAssertEqual(saved["state"], "succeeded")
        XCTAssertEqual(saved["commit_state"], "committed")
        let retry = await client.call(.applyPairs, apply, request: "apply-pair")
        XCTAssertEqual(retry.structuredContent, accepted.structuredContent)
        let pair = try XCTUnwrap(catalog.pairs().first)
        let listed = try client.data(await client.call(.listPairs, ["photo_id": .string(jpeg.id)]))
        XCTAssertEqual(ids(listed, key: "pair_id"), [pair.id])
        XCTAssertEqual(pair.rawSourceID, raw.sourceKey)
        let op = try XCTUnwrap(saved["operation_id"])
        _ = try client.data(await client.call(.undo, ["operation_id": op]))
        XCTAssertTrue(try catalog.pairs().isEmpty)
        _ = try client.data(await client.call(.redo, ["operation_id": op]))
        XCTAssertEqual(try catalog.pairs(), [pair])
        let unlinked = try client.data(await client.call(.unlinkPair, ["pair_id": .string(pair.id)]))
        _ = try client.data(await client.call(.undo, ["operation_id": try XCTUnwrap(unlinked["operation_id"])]))
        XCTAssertEqual(try catalog.pairs(), [pair])
        _ = try client.data(await client.call(.unlinkPair, ["pair_id": .string(pair.id)]))
        XCTAssertEqual(try catalog.photoCount(), 3)

        var manual: [String: Value] = ["action": "manual", "raw_source_id": .string(raw.sourceKey), "jpeg_source_id": .string(other.sourceKey)]
        client.error(await client.call(.planPairs, manual), "invalid_arguments")
        manual["same_capture"] = true
        let manualPlan = try await client.job(client.call(.planPairs, manual))
        XCTAssertEqual(manualPlan["state"], "succeeded")
        try ImportTests().image(alternate, color: .green)
        let changed = try await client.job(client.call(.applyPairs, [
            "plan_id": try XCTUnwrap(manualPlan["plan_id"]),
            "candidate_ids": [.string(try XCTUnwrap(ids(manualPlan, key: "candidate_id").first))]
        ]))
        XCTAssertEqual(changed["error_code"], "stale_plan")
        XCTAssertEqual(changed["commit_state"], "not_committed")
        XCTAssertTrue(try catalog.pairs().isEmpty)
    }
}
