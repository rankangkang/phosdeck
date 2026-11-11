import AppKit
import ImageIO
import MCP
import XCTest
@testable import Phosdeck

final class AgentMCPTests: XCTestCase {
    private actor ReceivedResponse {
        var headers: [String: String] = [:]
        var body = Data()

        func collect(_ response: HTTPResponse) async throws -> Int {
            headers = response.headers
            if case .stream(let events, _) = response {
                for try await event in events { body.append(event) }
            }
            return body.count
        }
    }

    private func temporaryCatalog() throws -> (URL, CatalogStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-mcp-" + UUID().uuidString)
        let catalog = try CatalogStore(directory: directory)
        addTeardownBlock {
            try catalog.database.close()
            try FileManager.default.removeItem(at: directory)
        }
        return (directory, catalog)
    }

    @MainActor private func fixture(ids: [String] = ["a", "b", "c"]) throws -> (CatalogStore, AppModel, AppMCPTools) {
        let (directory, catalog) = try temporaryCatalog()
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        for id in ids {
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id, width: 1, height: 1))
        }
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        return (catalog, model, tools(model))
    }
    @MainActor private func tools(_ model: AppModel) -> AppMCPTools {
        AppMCPTools(model: model, appName: "Phosdeck Test", version: "1", bundleID: "dev.cmkk.phosdeck.tests", sharesImages: false)
    }
    private func data(_ result: CallTool.Result) -> [String: Value] { result.structuredContent?.objectValue?["data"]?.objectValue ?? [:] }
    private func checkError(_ result: CallTool.Result, _ code: String, line: UInt = #line) {
        XCTAssertEqual(result.isError, true, line: line)
        XCTAssertEqual(result.structuredContent?.objectValue?["error"]?.objectValue?["code"], .string(code), line: line)
    }
    private func call(_ tools: AppMCPTools, _ tool: AppMCPTool, _ arguments: [String: Value] = [:]) async -> CallTool.Result {
        await tools.call(.init(name: tool.rawValue, arguments: arguments))
    }

    @MainActor func testPagingTracksQueryAndDatabaseWithoutChangingSelection() async throws {
        let (catalog, model, tools) = try fixture()
        let emptyModel = AppModel()
        let empty = await call(self.tools(emptyModel), .workspace)
        XCTAssertEqual(data(empty)["catalog_session_id"], .null)
        try catalog.changeStacks(.group(top: "a", members: ["a", "b"]))
        try model.reloadPhotos()
        model.activeID = "c"
        model.selection = ["c"]
        let state = data(await call(tools, .workspace))
        let session = try XCTUnwrap(state["catalog_session_id"])
        let first = data(await call(tools, .listPhotos, ["catalog_session_id": session, "page_size": 1]))
        XCTAssertEqual(first["matched_count"], 3)
        XCTAssertEqual(first["visible_count"], 2)
        let row = first["items"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(row?["photo_id"], "a")
        XCTAssertEqual(row?["stack"]?.objectValue?["matched_count"], 2)
        let cursor = try XCTUnwrap(first["next_cursor"]?.stringValue)
        let continuation: [String: Value] = ["catalog_session_id": session, "cursor": .string(cursor)]
        let second = data(await call(tools, .listPhotos, continuation))
        XCTAssertEqual(second["items"]?.arrayValue?.first?.objectValue?["photo_id"], "c")
        XCTAssertEqual(second["next_cursor"], .null)
        XCTAssertEqual(model.selection, ["c"])
        XCTAssertEqual(model.activeID, "c")
        XCTAssertEqual(model.pageOffset, 0)
        checkError(await call(tools, .listPhotos, continuation.merging(["page_size": 2]) { _, size in size }), "stale_cursor")

        try catalog.changeStacks(.collapse(Set(try catalog.stacks().map(\.id)), false))
        checkError(await call(tools, .listPhotos, continuation), "stale_cursor")
        let unstacked = data(await call(tools, .listPhotos, ["catalog_session_id": session, "page_size": 1]))
        XCTAssertEqual(unstacked["visible_count"], 3)
        let newCursor = try XCTUnwrap(unstacked["next_cursor"])
        model.photoSort = .rating
        try model.reloadPhotos()
        checkError(await call(tools, .listPhotos, ["catalog_session_id": session, "cursor": newCursor]), "stale_cursor")
        try model.activateCatalog(catalog)
        checkError(await call(tools, .listPhotos, continuation), "catalog_changed")
    }

    @MainActor func testRatingIsExplicitDeduplicatedAndUsesNativeUndo() async throws {
        let (catalog, model, tools) = try fixture()
        model.autoAdvance = true
        model.activeID = "a"
        model.selection = ["a"]
        let state = data(await call(tools, .workspace))
        let base = ["catalog_session_id": try XCTUnwrap(state["catalog_session_id"]),
                    "request_epoch": try XCTUnwrap(state["request_epoch"])]
        func rate(_ id: String, expected: Int, rating: Int, requestID: String) async -> CallTool.Result {
            await call(tools, .rate, base.merging(["photo_id": .string(id), "expected_rating": .int(expected),
                                                  "rating": .int(rating), "request_id": .string(requestID)]) { _, new in new })
        }
        func undo(_ operation: Value, requestID: String) async -> CallTool.Result {
            await call(tools, .undo, base.merging(["operation_id": operation, "request_id": .string(requestID)]) { _, new in new })
        }

        let unchanged = await rate("b", expected: 0, rating: 0, requestID: "unchanged")
        XCTAssertEqual(data(unchanged)["changed"], false)
        XCTAssertEqual(data(unchanged)["operation_id"], .null)
        XCTAssertFalse(model.undo.canUndo)
        model.dirty = true
        checkError(await rate("b", expected: 0, rating: 3, requestID: "draft"), "native_interaction_active")
        XCTAssertTrue(model.dirty)
        model.dirty = false
        model.showExport = true
        checkError(await rate("b", expected: 0, rating: 3, requestID: "dialog"), "workspace_busy")
        model.showExport = false
        let changed = await rate("b", expected: 0, rating: 3, requestID: "rate-b")
        let operation = try XCTUnwrap(data(changed)["operation_id"]?.stringValue)
        XCTAssertEqual(data(changed)["commit_state"], "committed")
        XCTAssertEqual(try catalog.photoRating("b"), 3)
        XCTAssertEqual(try catalog.photoRating("a"), 0)
        XCTAssertEqual(model.activeID, "a")
        XCTAssertEqual(model.selection, ["a"])
        let duplicate = await rate("b", expected: 0, rating: 3, requestID: "rate-b")
        XCTAssertEqual(duplicate.structuredContent, changed.structuredContent)
        checkError(await rate("b", expected: 0, rating: 4, requestID: "rate-b"), "request_id_conflict")
        let conflict = await rate("b", expected: 0, rating: 4, requestID: "conflict")
        checkError(conflict, "rating_conflict")
        XCTAssertEqual(data(conflict)["actual_rating"], 3)
        let undone = await undo(.string(operation), requestID: "undo-b")
        XCTAssertEqual(data(undone)["rating"], 0)
        XCTAssertEqual(data(undone)["commit_state"], "committed")
        XCTAssertEqual(try catalog.photoRating("b"), 0)
        XCTAssertFalse(model.undo.canUndo)
        let repeatedUndo = await undo(.string(operation), requestID: "undo-b")
        XCTAssertEqual(repeatedUndo.structuredContent, undone.structuredContent)

        let ratedAgain = await rate("b", expected: 0, rating: 2, requestID: "again")
        let staleOperation = try XCTUnwrap(data(ratedAgain)["operation_id"]?.stringValue)
        model.undo.beginUndoGrouping()
        model.organize(rating: 5, advance: false)
        model.undo.endUndoGrouping()
        checkError(await undo(.string(staleOperation), requestID: "old-group"), "undo_conflict")
        XCTAssertEqual(try catalog.photoRating("a"), 5)
        XCTAssertEqual(try catalog.photoRating("b"), 2)
        model.undo.undo()
        model.undo.undo()
        XCTAssertEqual(try catalog.photoRating("a"), 0)
        XCTAssertEqual(try catalog.photoRating("b"), 0)
        model.undo.redo()
        XCTAssertEqual(try catalog.photoRating("b"), 2)
        checkError(await undo(.string(staleOperation), requestID: "old-redo"), "undo_conflict")
    }

    @MainActor func testRatingAndUndoKeepAnEmptySelectionEmpty() async throws {
        let (catalog, model, tools) = try fixture()
        let workspace = data(await call(tools, .workspace))
        let base = ["catalog_session_id": try XCTUnwrap(workspace["catalog_session_id"]),
                    "request_epoch": try XCTUnwrap(workspace["request_epoch"])]
        let rated = await call(tools, .rate, base.merging([
            "photo_id": "b", "expected_rating": 0, "rating": 4, "request_id": "rate"
        ]) { _, new in new })
        XCTAssertEqual(rated.isError, false)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.activeID)
        let operation = try XCTUnwrap(data(rated)["operation_id"])
        let undone = await call(tools, .undo, base.merging(["operation_id": operation, "request_id": "undo"]) { _, new in new })
        XCTAssertEqual(undone.isError, false)
        XCTAssertEqual(try catalog.photoRating("b"), 0)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.activeID)
    }

    @MainActor func testHeldQuerySelectsFoldedAndCrossPageVersions() async throws {
        let ids = (0..<205).map { String(format: "p%03d", $0) }
        let (catalog, model, tools) = try fixture(ids: ids)
        try catalog.setOrganization(ids: ids, rating: 3)
        try catalog.changeStacks(.group(top: ids[0], members: Array(ids.prefix(2))))
        try catalog.collection(name: "Subset", id: "subset")
        try catalog.membership(ids: [ids[0]], collection: "subset", add: true)
        try model.reload()
        let workspace = data(await call(tools, .workspace))
        let session = ["catalog_session_id": try XCTUnwrap(workspace["catalog_session_id"])]
        let base = session.merging(["request_epoch": try XCTUnwrap(workspace["request_epoch"])]) { _, value in value }
        func write(_ tool: AppMCPTool, _ args: [String: Value], _ request: String = UUID().uuidString) async -> CallTool.Result {
            await call(tools, tool, base.merging(args) { _, value in value }.merging(["request_id": .string(request)]) { _, value in value })
        }
        let query = await write(.setQuery, ["rating_threshold": 3, "sort": "filename", "hold_results": true])
        XCTAssertEqual(data(query)["matched_count"], 205)
        XCTAssertEqual(data(query)["visible_count"], 204)
        let queryRevision = try XCTUnwrap(data(query)["query_revision"])
        let visible = data(await call(tools, .listPhotos, session.merging(["page_size": 2]) { _, value in value }))
        let matches = data(await call(tools, .listPhotos, session.merging(["listing": "matches", "page_size": 2]) { _, value in value }))
        func photoIDs(_ page: [String: Value]) -> [String] {
            page["items"]?.arrayValue?.compactMap { $0.objectValue?["photo_id"]?.stringValue } ?? []
        }
        XCTAssertEqual(photoIDs(visible), [ids[0], ids[2]])
        XCTAssertEqual(photoIDs(matches), Array(ids.prefix(2)))
        let matchedCursor = try XCTUnwrap(matches["next_cursor"])
        let next = data(await call(tools, .listPhotos, session.merging(["cursor": matchedCursor]) { _, value in value }))
        XCTAssertEqual(photoIDs(next), Array(ids[2...3]))
        XCTAssertEqual(next["listing"], "matches")
        let all = await write(.selectPhotos, ["action": "all", "active_photo_id": .string(ids.last!), "query_revision": queryRevision])
        XCTAssertEqual(data(all)["selection_count"], 205)
        XCTAssertEqual(model.pageOffset, 200)
        XCTAssertTrue(model.selection.contains(ids[1]))
        XCTAssertEqual(model.activeID, ids.last)
        let selected = data(await call(tools, .listSelected, session.merging(["page_size": 200]) { _, value in value }))
        XCTAssertEqual(photoIDs(selected), Array(ids.prefix(200)))
        let selectedCursor = try XCTUnwrap(selected["next_cursor"])
        let tail = data(await call(tools, .listSelected, session.merging(["cursor": selectedCursor]) { _, value in value }))
        XCTAssertEqual(photoIDs(tail), Array(ids.suffix(5)))
        XCTAssertEqual(tail["next_cursor"], .null)

        let stack = await write(.selectPhotos, ["action": "stack", "photo_id": .string(ids[0]), "active_photo_id": .string(ids[1])])
        XCTAssertEqual(data(stack)["selection_count"], 2)
        XCTAssertEqual(model.activeID, ids[1])
        XCTAssertEqual(model.pageOffset, 0)
        checkError(await call(tools, .listSelected, session.merging(["cursor": selectedCursor]) { _, value in value }), "stale_cursor")
        let rated = await write(.rate, ["photo_id": .string(ids[1]), "expected_rating": 3, "rating": 0])
        XCTAssertFalse(rated.isError ?? true)
        XCTAssertEqual(model.resultCount, 205)
        XCTAssertEqual(model.activeID, ids[1], "A saved mark keeps an explicitly active folded member within the held query")
        let hiddenFilters = await write(.setQuery, ["filters_open": false])
        XCTAssertEqual(data(hiddenFilters)["query_revision"], queryRevision)
        XCTAssertEqual(model.resultCount, 205)

        let refreshed = await write(.refreshQuery, [:])
        XCTAssertEqual(data(refreshed)["matched_count"], 204)
        checkError(await write(.selectPhotos, ["action": "all", "query_revision": queryRevision]), "stale_query")
        checkError(await write(.setQuery, ["source_id": "collection:subset", "date_from": "2026-02-30"]), "invalid_arguments")
        XCTAssertEqual(model.scope, "all")
        let collection = await write(.setQuery, ["source_id": "collection:subset", "sort": "manual"])
        XCTAssertEqual(data(collection)["matched_count"], 1)
        XCTAssertTrue(model.query.isManualCollectionOrder)
        let back = await write(.navigate, ["action": "back"])
        XCTAssertEqual(data(back)["source_id"], "all")
        XCTAssertEqual(data(back)["matched_count"], 204)
        XCTAssertNotNil(model.query.snapshotID)
    }

    @MainActor func testBatchMarksAreAtomicDeduplicatedAndRedoUsesNativeStack() async throws {
        let (catalog, model, tools) = try fixture()
        model.choose(["a"], active: "a")
        let state = data(await call(tools, .workspace))
        let base = ["catalog_session_id": try XCTUnwrap(state["catalog_session_id"]),
                    "request_epoch": try XCTUnwrap(state["request_epoch"])]
        func write(_ tool: AppMCPTool, _ args: [String: Value], request: String = UUID().uuidString) async -> CallTool.Result {
            await call(tools, tool, base.merging(args) { _, value in value }.merging(["request_id": .string(request)]) { _, value in value })
        }
        try catalog.setOrganization(ids: ["c"], rating: 4)
        checkError(await write(.rateBatch, ["rating": 3, "targets": [
            ["photo_id": "b", "expected_rating": 0], ["photo_id": "c", "expected_rating": 0]
        ]]), "marks_conflict")
        XCTAssertEqual(try catalog.photoRating("b"), 0)
        XCTAssertFalse(model.undo.canUndo)

        let arguments: [String: Value] = ["rating_step": 1, "targets": [["photo_id": "b", "expected_rating": 0], ["photo_id": "c", "expected_rating": 4]]]
        let saved = await write(.rateBatch, arguments, request: "batch")
        XCTAssertEqual(data(saved)["changed_count"], 2)
        let retry = await write(.rateBatch, arguments, request: "batch")
        XCTAssertEqual(saved.structuredContent, retry.structuredContent)
        XCTAssertEqual(try catalog.photoRating("b"), 1)
        XCTAssertEqual(try catalog.photoRating("c"), 5)
        XCTAssertEqual(model.activeID, "a")
        let operation = try XCTUnwrap(data(saved)["operation_id"])
        let undone = await write(.undo, ["operation_id": operation])
        XCTAssertEqual(data(undone)["commit_state"], "committed")
        XCTAssertEqual(try catalog.photoRating("b"), 0)
        XCTAssertEqual(try catalog.photoRating("c"), 4)
        let redone = await write(.redo, ["operation_id": operation])
        XCTAssertEqual(data(redone)["commit_state"], "committed")
        XCTAssertEqual(try catalog.photoRating("b"), 1)
        XCTAssertEqual(try catalog.photoRating("c"), 5)

        let marked = await write(.marks, ["flag": -1, "color_label": 3, "targets": [
            ["photo_id": "a", "expected_flag": 0, "expected_color_label": 0],
            ["photo_id": "b", "expected_flag": 0, "expected_color_label": 0]
        ], "advance": true])
        XCTAssertEqual(data(marked)["changed_count"], 2)
        XCTAssertEqual(try catalog.photo("a")?.flag, -1)
        XCTAssertEqual(try catalog.photo("b")?.colorLabel, 3)
        XCTAssertEqual(model.activeID, "b")
        model.undo.undo()
        XCTAssertEqual(try catalog.photo("a")?.flag, 0)
        XCTAssertEqual(try catalog.photo("b")?.colorLabel, 0)
        checkError(await write(.redo, ["operation_id": try XCTUnwrap(data(marked)["operation_id"])]), "undo_conflict")

        let changed = await write(.rate, ["photo_id": "b", "expected_rating": 1, "rating": 3])
        try catalog.setOrganization(ids: ["b"], rating: 2)
        checkError(await write(.undo, ["operation_id": try XCTUnwrap(data(changed)["operation_id"])]), "undo_conflict")
        XCTAssertEqual(try catalog.photoRating("b"), 2)
    }

    @MainActor func testComparisonSurveyAndViewportUseNativeWorkspace() async throws {
        let (_, model, tools) = try fixture()
        let state = data(await call(tools, .workspace))
        let base = ["catalog_session_id": try XCTUnwrap(state["catalog_session_id"]),
                    "request_epoch": try XCTUnwrap(state["request_epoch"])]
        func write(_ tool: AppMCPTool, _ args: [String: Value]) async -> CallTool.Result {
            await call(tools, tool, base.merging(args) { _, value in value }.merging(["request_id": .string(UUID().uuidString)]) { _, value in value })
        }
        let compared = await write(.compare, ["action": "set", "reference_photo_id": "a", "candidate_photo_id": "b",
                                              "photo_ids": ["a", "b", "c"], "restrict_to_group": true])
        XCTAssertEqual(data(compared)["view"], "compare")
        XCTAssertEqual(model.comparison?.reference.photo?.id, "a")
        XCTAssertEqual(model.comparison?.candidate.photo?.id, "b")
        _ = await write(.viewport, ["pane": "candidate", "zoom": "scale", "scale": 2, "x": 0.25, "y": 0.75])
        XCTAssertEqual(model.comparison?.reference.zoom, 2)
        XCTAssertEqual(model.comparison?.candidate.viewport.requestedCenter, CGPoint(x: 0.25, y: 0.75))
        _ = await write(.viewport, ["pane": "reference", "linked": false, "zoom": "fit"])
        XCTAssertNil(model.comparison?.reference.zoom)
        XCTAssertEqual(model.comparison?.candidate.zoom, 2)
        _ = await write(.compare, ["action": "swap"])
        XCTAssertEqual(model.comparison?.reference.photo?.id, "b")
        XCTAssertEqual(model.comparison?.candidate.photo?.id, "a")

        let survey = await write(.survey, ["action": "set", "photo_ids": ["a", "b", "c"], "active_photo_id": "c"])
        XCTAssertEqual(data(survey)["view"], "survey")
        XCTAssertEqual(model.selection, ["a", "b", "c"])
        XCTAssertNil(model.comparison)
        _ = await write(.survey, ["action": "remove", "photo_id": "c"])
        XCTAssertEqual(model.selection, ["a", "b"])
        let opened = await write(.survey, ["action": "open", "photo_id": "b"])
        XCTAssertEqual(data(opened)["view"], "single")
        XCTAssertEqual(model.selection, ["b"])
        _ = await write(.viewport, ["zoom": "fill", "locked": true])
        XCTAssertTrue(model.fillView)
        XCTAssertTrue(model.lockViewPosition)
        _ = await write(.clipping, ["shadows": true])
        XCTAssertTrue(model.showShadowClipping)
        XCTAssertFalse(model.showHighlightClipping)
    }

    @MainActor func testKeywordsAndCaptionsUseExplicitVersionsAndUndo() async throws {
        let (catalog, model, tools) = try fixture()
        model.choose(["a"], active: "a")
        let state = data(await call(tools, .workspace))
        let session = ["catalog_session_id": try XCTUnwrap(state["catalog_session_id"])]
        let base = session.merging(["request_epoch": try XCTUnwrap(state["request_epoch"])]) { _, value in value }
        func write(_ tool: AppMCPTool, _ args: [String: Value]) async -> CallTool.Result {
            await call(tools, tool, base.merging(args) { _, value in value }.merging(["request_id": .string(UUID().uuidString)]) { _, value in value })
        }
        let keyword = await write(.editKeywords, ["action": "add", "keywords": ["海岸", "Fog"], "photo_ids": ["b", "c"]])
        XCTAssertEqual(data(keyword)["changed_count"], 2)
        XCTAssertEqual(try catalog.photoKeywords(ids: ["a"])["a"], [])
        let result = data(await call(tools, .keywords, session.merging(["photo_id": "b", "search": "FOG"]) { _, value in value }))
        XCTAssertEqual(result["photo_keywords"], ["Fog", "海岸"])
        XCTAssertEqual(result["caption"], "")
        XCTAssertEqual(result["total"], 1)
        XCTAssertEqual(result["items"]?.arrayValue?.first?.objectValue?["selected_count"], 0)
        let rename = await write(.renameKeyword, ["keyword_id": "fog", "name": "Mist"])
        XCTAssertEqual(data(rename)["affected_version_count"], 2)
        let renameID = try XCTUnwrap(data(rename)["operation_id"])
        let reverted = await write(.undo, ["operation_id": renameID])
        XCTAssertEqual(data(reverted)["keyword_id"], "fog")
        XCTAssertEqual(try catalog.photoKeywords(ids: ["c"])["c"], ["Fog", "海岸"])

        _ = try catalog.setCaptions(["c": "Native edit"])
        let conflict = await write(.caption, ["caption": "New caption", "expected_captions": ["b": "", "c": ""]])
        checkError(conflict, "caption_conflict")
        XCTAssertEqual(data(conflict)["actual_caption"], "Native edit")
        XCTAssertEqual(try catalog.photo("b")?.caption, "")
        let saved = await write(.caption, ["caption": "第一行\r\nSecond line", "expected_captions": ["b": "", "c": "Native edit"]])
        XCTAssertEqual(data(saved)["caption"], "第一行\nSecond line")
        XCTAssertEqual(try catalog.photo("c")?.caption, "第一行\nSecond line")
        let operation = try XCTUnwrap(data(saved)["operation_id"])
        let undo = await write(.undo, ["operation_id": operation])
        XCTAssertEqual(data(undo)["commit_state"], "committed")
        XCTAssertEqual(try catalog.photo("c")?.caption, "Native edit")
        XCTAssertEqual(try catalog.photo("b")?.caption, "")
        XCTAssertEqual(model.activeID, "a")
    }

    @MainActor func testPreviewSharesOnlyRequestedSavedVersionAndNeverCreatesBaseline() async throws {
        let (directory, catalog) = try temporaryCatalog()
        let file = directory.appendingPathComponent("synthetic.png")
        try PNGFixture.data().write(to: file)
        let root = try catalog.addRoot(url: directory, bookmark: AccessLease.bookmark(directory, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: directory)
        try catalog.index(photo)
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        let tools = tools(model)
        let session = try XCTUnwrap(model.catalogSessionID)
        let arguments: [String: Value] = ["catalog_session_id": .string(session), "photo_id": .string(photo.id),
                                          "source_revision": .int(photo.revision), "recipe_revision": 0, "long_edge": 64]
        checkError(await call(tools, .preview, arguments), "image_access_disabled")
        tools.setSharesImages(true)
        let preview = await call(tools, .preview, arguments)
        XCTAssertEqual(preview.isError, false)
        XCTAssertEqual(data(preview)["width"], 64)
        XCTAssertEqual(data(preview)["height"], 48)
        XCTAssertEqual(data(preview)["histogram"]?.arrayValue?.count, 3)
        guard case .image(let base64, "image/png", _, _) = preview.content.last else { return XCTFail("Missing PNG") }
        let png = try XCTUnwrap(Data(base64Encoded: base64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64)
        XCTAssertTrue([.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo))
        XCTAssertNil(try catalog.photo(photo.id)?.recipe)
        XCTAssertNil(model.activeID)

        var recipe = try await model.pipeline.baseline(.init(photo: photo, root: root, recipe: nil))
        recipe.exposure = 0.5
        try catalog.saveRecipe(id: photo.id, recipe: recipe)
        checkError(await call(tools, .preview, arguments), "stale_photo")
        let current = await call(tools, .preview, arguments.merging(["recipe_revision": 1]) { _, value in value })
        XCTAssertEqual(data(current)["recipe_revision"], 1)
        XCTAssertNotEqual(current.content.last, preview.content.last)
        tools.setSharesImages(false)
        checkError(await call(tools, .preview, arguments), "image_access_disabled")
    }

    @MainActor func testListenerLifecycleAndPerInstanceCredentials() async throws {
        let model = AppModel()
        let service = AppMCPService(preferences: nil)
        XCTAssertFalse(service.enabled)
        XCTAssertFalse(service.sharesImages)
        XCTAssertNil(service.endpoint)
        service.attach(to: model)
        service.setEnabled(true)
        do {
            for _ in 0..<200 where service.status == .starting || service.status == .off { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(service.status, .listening)
            let endpoint = try XCTUnwrap(service.endpoint)
            let token = try XCTUnwrap(service.connectionToken)
            XCTAssertTrue(endpoint.hasPrefix("http://127.0.0.1:"))
            XCTAssertEqual(token.utf8.count, 64)
            XCTAssertTrue(service.clientConfiguration?.contains(endpoint) == true)
            XCTAssertFalse(service.clientConfiguration?.contains(token) == true)
            let second = try await MCPHTTPListener.start(name: "phosdeck-test", version: "1", tools: tools(model))
            XCTAssertNotEqual(second.endpoint, endpoint)
            XCTAssertNotEqual(second.token, token)
            await second.stop()
        } catch {
            await service.shutdownForQuit()
            throw error
        }
        await service.shutdownForQuit()
        XCTAssertEqual(service.status, .off)
        XCTAssertNil(service.endpoint)
        XCTAssertNil(service.connectionToken)
        XCTAssertFalse(service.needsShutdown)
    }

    @MainActor func testClosedNotificationConnectionKeepsProtocolSession() async throws {
        let (catalog, model, tools) = try fixture()
        try catalog.collection(name: "Review set", id: "review")
        try catalog.membership(ids: ["a", "b"], collection: "review", add: true)
        let sessions = MCPHTTPSessions(name: "phosdeck-test", version: "1", tools: tools)
        addTeardownBlock { await sessions.stop() }
        let headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                       "MCP-Protocol-Version": "2025-11-25"]
        let initResponse = ReceivedResponse()
        let initBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
        await sessions.respond(to: HTTPRequest(method: "POST", headers: headers, body: initBody)) { try await initResponse.collect($0) }
        let initHeaders = await initResponse.headers
        let id = try XCTUnwrap(initHeaders["MCP-Session-Id"])
        let sessionHeaders = headers.merging(["MCP-Session-Id": id]) { _, value in value }
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        await sessions.respond(to: HTTPRequest(method: "POST", headers: sessionHeaders, body: notification)) { response in
            XCTAssertEqual(response.statusCode, 202)
            throw CancellationError()
        }
        func result(_ request: String) async throws -> [String: Value] {
            let response = ReceivedResponse()
            await sessions.respond(to: HTTPRequest(method: "POST", headers: sessionHeaders, body: Data(request.utf8))) { try await response.collect($0) }
            let body = String(decoding: await response.body, as: UTF8.self)
            let payloads = body.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            let event = try XCTUnwrap(payloads.first { !$0.isEmpty }, body)
            let decoded = try JSONDecoder().decode(Value.self, from: Data(event.utf8))
            return try XCTUnwrap(decoded.objectValue?["result"]?.objectValue, body)
        }
        let listed = try await result(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#)
        let names = try XCTUnwrap(listed["tools"]?.arrayValue).compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(Set(names), Set(AppMCPTool.allCases.map(\.rawValue)))
        XCTAssertTrue(["get_collection", "save_smart_collection", "create_virtual_copies", "plan_auto_stacks", "plan_raw_jpeg_pairs"]
            .allSatisfy(names.contains))
        let session = try XCTUnwrap(model.catalogSessionID)
        let collection = try await result(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_collection","arguments":{"catalog_session_id":"\#(session)","collection_id":"review","page_size":1}}}"#)
        let data = try XCTUnwrap(collection["structuredContent"]?.objectValue?["data"]?.objectValue)
        XCTAssertEqual(data["items"], [["photo_id": "a"]])
        XCTAssertEqual(data["next_offset"], 1)
    }
}
