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

    @MainActor private func fixture() throws -> (CatalogStore, AppModel, AppMCPTools) {
        let (directory, catalog) = try temporaryCatalog()
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        for id in ["a", "b", "c"] {
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
        let model = AppModel()
        let sessions = MCPHTTPSessions(name: "phosdeck-test", version: "1", tools: tools(model))
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
        let call = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_capabilities","arguments":{}}}"#.utf8)
        let result = ReceivedResponse()
        await sessions.respond(to: HTTPRequest(method: "POST", headers: sessionHeaders, body: call)) { try await result.collect($0) }
        await sessions.stop()
        let body = await result.body
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("structuredContent"))
    }
}
