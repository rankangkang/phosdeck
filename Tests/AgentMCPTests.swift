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

    private actor ThumbnailGate {
        private var started: CheckedContinuation<Void, Never>?
        private var pending: CheckedContinuation<Void, Never>?

        func block() async {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }
        func waitForRender() async {
            if pending == nil { await withCheckedContinuation { started = $0 } }
        }
        func resume() { pending?.resume(); pending = nil }
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

    private func cullingJob(_ tools: AppMCPTools, jobID: Value, pageSize: Int = 50) async throws -> [String: Value] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        repeat {
            let result = await call(tools, .job, ["job_id": jobID, "page_size": .int(pageSize)])
            XCTAssertEqual(result.isError, false, String(describing: result.structuredContent))
            let state = data(result)
            if state["phase"] == "finished" { return state }
            try await Task.sleep(for: .milliseconds(15))
        } while ContinuousClock.now < deadline
        XCTFail("Timed out waiting for assisted culling.")
        return [:]
    }

    private func cullingPNG(_ url: URL, detail: Bool = false, other: Bool = false) throws {
        let width = 320, height = 192
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = other ? 70 + (x * 124 / width) : 70 + (y * 124 / height)
                let texture = detail ? ((x / 2 + y / 2).isMultiple(of: 2) ? 38 : -38) : 0
                let code = UInt8(base + texture), offset = (y * width + x) * 4
                pixels[offset] = code; pixels[offset + 1] = code; pixels[offset + 2] = code
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: ImagePipeline.outputSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
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

    @MainActor func testIndependentPagingIgnoresNativeFiltersAndTemporarySnapshots() async throws {
        let (catalog, model, tools) = try fixture(ids: ["a", "b", "c", "d"])
        try catalog.setOrganization(ids: ["a"], rating: 4)
        try catalog.setOrganization(ids: ["b", "c"], rating: 5)
        try catalog.changeStacks(.group(top: "a", members: ["b"]))
        try model.updateLibraryQuery {
            model.search = "d.jpg"
            model.holdFilterResults = true
        }
        let workspace = data(await call(tools, .workspace))
        let session = try XCTUnwrap(workspace["catalog_session_id"])
        let query: Value = ["rating_threshold": 4, "sort": "rating", "descending": true]
        let start: [String: Value] = ["catalog_session_id": session, "page_size": 2, "query": query]
        let first = data(await call(tools, .listPhotos, start))
        XCTAssertEqual(first["query_mode"], "independent")
        XCTAssertNil(first["query_revision"])
        XCTAssertEqual(first["source_id"], "all")
        XCTAssertEqual(first["matched_count"], 3)
        XCTAssertEqual(first["visible_count"], 2)
        XCTAssertEqual(first["items"]?.arrayValue?.compactMap { $0.objectValue?["photo_id"] }, ["b", "c"])
        XCTAssertEqual(first["items"]?.arrayValue?.compactMap { $0.objectValue?["number"] }, [1, 2])
        let afterward = data(await call(tools, .workspace))
        for key in ["query", "query_revision", "selection_revision", "source_id", "page_offset", "active_photo_id",
                    "selected_photo_ids", "filter_settings", "browse_locations", "view", "viewport"] {
            XCTAssertEqual(afterward[key], workspace[key], key)
        }

        let cursor = try XCTUnwrap(first["next_cursor"])
        let next: [String: Value] = ["catalog_session_id": session, "cursor": cursor]
        checkError(await call(tools, .listPhotos, next.merging(["query": query]) { _, value in value }), "invalid_arguments")
        checkError(await call(tools, .listSelected, next), "stale_cursor")
        checkError(await call(tools, .listPhotos, next.merging(["listing": "visible"]) { _, value in value }), "stale_cursor")
        try model.updateLibraryQuery {
            model.search = "b.jpg"
            model.photoSort = .filename
        }
        let continuation = await call(tools, .listPhotos, next)
        XCTAssertEqual(continuation.isError, false, String(describing: continuation.structuredContent))
        let second = data(continuation)
        XCTAssertEqual(second["page_offset"], 2)
        XCTAssertEqual(second["items"]?.arrayValue?.first?.objectValue?["photo_id"], "a")
        XCTAssertEqual(second["items"]?.arrayValue?.first?.objectValue?["number"], 3)
        XCTAssertEqual(second["next_cursor"], .null)
        XCTAssertEqual(model.activeID, "b")
        try catalog.setOrganization(ids: ["a"], rating: 3)
        checkError(await call(tools, .listPhotos, next), "stale_cursor")
    }

    @MainActor func testIndependentQueryCombinesSmartRulesWithMetadataAndValidatesSort() async throws {
        let (directory, catalog) = try temporaryCatalog()
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        for (id, rating, day, lens) in [("a", 5, "12", "50 mm"), ("b", 4, "13", "50 mm"),
                                        ("c", 5, "13", "35 mm"), ("d", 3, "13", "50 mm")] {
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: "Shoot/\(id).jpg", identity: Data(), identityKey: id,
                                    captureDate: "2026:11:\(day) 12:00:00", width: 1, height: 1, camera: "Synthetic",
                                    metadata: try JSONEncoder().encode(PhotoMetadata(lens: lens, iso: 400))))
            try catalog.setOrganization(ids: [id], rating: rating)
        }
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        let tools = tools(model)
        let workspace = data(await call(tools, .workspace))
        let session = try XCTUnwrap(workspace["catalog_session_id"])
        let saved = await call(tools, .saveSmartCollection, [
            "catalog_session_id": session, "request_epoch": try XCTUnwrap(workspace["request_epoch"]), "request_id": "smart-query",
            "name": "Four or more", "rules": ["source_id": .string("folder:\(root.id):Shoot"),
                                            "conditions": [["field": "rating", "operator": "atLeast", "value": "4"]]]
        ])
        let source = try XCTUnwrap(data(saved)["source_id"])
        func list(_ query: Value) async -> CallTool.Result {
            await call(tools, .listPhotos, ["catalog_session_id": session, "query": query])
        }
        let result = data(await list(["source_id": source, "camera": "Synthetic", "lens": "50",
                                      "minimum_iso": 400, "date_from": "2026-11-13"]))
        XCTAssertEqual(result["source_id"], source)
        XCTAssertEqual(result["items"]?.arrayValue?.compactMap { $0.objectValue?["photo_id"] }, ["b"])
        checkError(await list(["source_id": source, "sort": "manual"]), "invalid_arguments")
        checkError(await list(["source_id": "unlisted"]), "invalid_arguments")
        checkError(await list(["date_from": "2026-02-30"]), "invalid_arguments")
        checkError(await list(["minimum_iso": 800, "maximum_iso": 400]), "invalid_arguments")
        checkError(await list(["filters_enabled": true]), "invalid_arguments")
        XCTAssertEqual(model.scope, "all")
        XCTAssertTrue(model.search.isEmpty)

        let related = "related:" + (try catalog.snapshotPhotos(["a", "b", "c"]))
        try model.updateLibraryQuery(source: related)
        let native = data(await call(tools, .listPhotos, ["catalog_session_id": session]))
        XCTAssertEqual(native["items"]?.arrayValue?.compactMap { $0.objectValue?["photo_id"] }, ["a", "b", "c"])
        let sorted = data(await list(["source_id": .string(related), "sort": "filename", "descending": true]))
        XCTAssertEqual(sorted["items"]?.arrayValue?.compactMap { $0.objectValue?["photo_id"] }, ["c", "b", "a"])
        XCTAssertEqual(model.scope, related)
    }

    @MainActor func testContactSheetMapsNativeTileAndDoesNotShareAStaleCachedSource() async throws {
        let (directory, catalog) = try temporaryCatalog()
        let root = try catalog.addRoot(url: directory, bookmark: AccessLease.bookmark(directory, readOnly: true))
        let file = directory.appendingPathComponent("a.png")
        try PNGFixture.data(width: 240, height: 160).write(to: file)
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: directory)
        try catalog.index(photo)
        try catalog.index(Photo(id: "missing", rootID: root.id, relativePath: "b.png", identity: Data(), identityKey: "missing",
                                width: 160, height: 240, availability: "missing"))
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        model.activeID = "missing"
        model.selection = ["missing"]
        let tools = tools(model)
        let session = Value.string(try XCTUnwrap(model.catalogSessionID))
        let arguments: [String: Value] = ["catalog_session_id": session, "query": ["sort": "filename"], "contact_sheet": true]
        checkError(await call(tools, .listPhotos, arguments), "image_access_disabled")
        let textOnly = await call(tools, .listPhotos, ["catalog_session_id": session, "query": [:]])
        XCTAssertEqual(textOnly.isError, false)
        XCTAssertEqual(textOnly.content.count, 1)
        tools.setSharesImages(true)
        checkError(await call(tools, .listPhotos, arguments.merging(["page_size": 25]) { _, value in value }), "invalid_arguments")
        let workspace = data(await call(tools, .workspace))
        let result = await call(tools, .listPhotos, arguments)
        XCTAssertEqual(result.structuredContent?.objectValue?["status"], "warning")
        let sheet = try XCTUnwrap(data(result)["contact_sheet"]?.objectValue)
        XCTAssertEqual(sheet["columns"], 2)
        XCTAssertEqual(sheet["unavailable_count"], 1)
        let cells = try XCTUnwrap(data(result)["items"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(cells.map { $0["number"] }, [1, 2])
        XCTAssertEqual(cells.map { $0["thumbnail_status"] }, ["ready", "unavailable"])
        XCTAssertEqual(cells[1]["image_pixels"], .null)
        XCTAssertEqual(cells[1]["thumbnail_error"], "file_access_required")
        guard case .image(let base64, "image/png", _, _) = result.content.last else { return XCTFail("Missing contact sheet PNG") }
        let png = try XCTUnwrap(Data(base64Encoded: base64))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(.int(image.width), sheet["width"])
        XCTAssertEqual(.int(image.height), sheet["height"])
        let rect = try XCTUnwrap(cells[0]["image_pixels"]?.objectValue)
        XCTAssertEqual(rect["width"], 192)
        XCTAssertEqual(rect["height"], 128)
        XCTAssertLessThan(rect["x"]?.intValue ?? image.width, image.width / 2)

        let tile = await call(tools, .preview, [
            "catalog_session_id": session, "photo_id": try XCTUnwrap(cells[0]["photo_id"]),
            "source_revision": try XCTUnwrap(cells[0]["source_revision"]), "recipe_revision": try XCTUnwrap(cells[0]["recipe_revision"]),
            "resolution": "native", "region_pixels": ["x": 32, "y": 20, "width": 64, "height": 48]
        ])
        XCTAssertEqual(tile.isError, false, String(describing: tile.structuredContent))
        XCTAssertEqual(data(tile)["width"], 64)
        XCTAssertEqual(data(tile)["height"], 48)
        XCTAssertEqual(data(tile)["resolution"], "native")
        let after = data(await call(tools, .workspace))
        for key in ["source_id", "query", "query_revision", "selection_revision", "active_photo_id", "selected_photo_ids", "page_offset", "view"] {
            XCTAssertEqual(after[key], workspace[key], key)
        }
        XCTAssertNil(try catalog.photo(photo.id)?.recipe)

        let numbered = data(await call(tools, .listPhotos, arguments.merging(["page_size": 1]) { _, value in value }))
        let next = try XCTUnwrap(numbered["next_cursor"])
        let continued = data(await call(tools, .listPhotos, ["catalog_session_id": session, "cursor": next, "contact_sheet": true]))
        XCTAssertEqual(continued["items"]?.arrayValue?.first?.objectValue?["number"], 2)
        XCTAssertEqual(continued["next_cursor"], .null)
        let empty = await call(tools, .listPhotos, arguments.merging(["query": ["search": "no match"]]) { _, value in value })
        XCTAssertEqual(data(empty)["contact_sheet"], .null)
        XCTAssertEqual(empty.content.count, 1)

        try PNGFixture.data(width: 250, height: 160).write(to: file, options: .atomic)
        let stale = data(await call(tools, .listPhotos, arguments))
        XCTAssertEqual(stale["items"]?.arrayValue?.first?.objectValue?["thumbnail_error"], "file_access_required")
        XCTAssertEqual(stale["items"]?.arrayValue?.first?.objectValue?["image_pixels"], .null)
    }

    @MainActor func testContactSheetRejectsInFlightCatalogChangesAndRevokedSharing() async throws {
        let (directory, catalog) = try temporaryCatalog()
        let root = try catalog.addRoot(url: directory, bookmark: AccessLease.bookmark(directory, readOnly: true))
        let file = directory.appendingPathComponent("photo.png")
        let png = try PNGFixture.data(width: 160, height: 120)
        try png.write(to: file)
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: directory)
        try catalog.index(photo)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let gate = ThumbnailGate()
        let thumbnails = ThumbnailService(renderer: { _, _ in await gate.block(); return image })
        let model = AppModel(thumbnails: thumbnails)
        model.catalog = catalog
        try model.reload()
        let tools = tools(model)
        tools.setSharesImages(true)
        let session = Value.string(try XCTUnwrap(model.catalogSessionID))
        let arguments: [String: Value] = ["catalog_session_id": session, "query": [:], "contact_sheet": true]
        let changed = Task { await call(tools, .listPhotos, arguments) }
        await gate.waitForRender()
        do { try catalog.setOrganization(ids: [photo.id], rating: 5) }
        catch { await gate.resume(); throw error }
        await gate.resume()
        checkError(await changed.value, "stale_cursor")

        _ = try await thumbnails.clear()
        let revoked = Task { await call(tools, .listPhotos, arguments) }
        await gate.waitForRender()
        tools.setSharesImages(false)
        tools.setSharesImages(true)
        await gate.resume()
        let revokedResult = await revoked.value
        checkError(revokedResult, "image_access_disabled")
        XCTAssertEqual(revokedResult.content.count, 1)
        XCTAssertNil(model.activeID)
    }

    @MainActor func testAssistedCullingRanksBurstAndFindsReferenceWithoutChangingWorkspace() async throws {
        let (directory, catalog) = try temporaryCatalog()
        let root = try catalog.addRoot(url: directory, bookmark: AccessLease.bookmark(directory, readOnly: true))
        for (index, id) in ["soft", "sharp", "other", "later"].enumerated() {
            let url = directory.appendingPathComponent(id + ".png")
            try cullingPNG(url, detail: id == "sharp", other: id == "other")
            var photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
            photo.id = id
            photo.captureDate = "2026-10-21T08:00:" + ["00", "01", "02", "30"][index] + "+08:00"
            try catalog.index(photo)
        }
        let alias = try XCTUnwrap(catalog.createVirtualCopies(ids: ["sharp"]).first?.id)
        try catalog.index(Photo(id: "missing", rootID: root.id, relativePath: "missing.png",
                                identity: Data(), identityKey: "missing", width: 320, height: 192, availability: "missing"))
        let model = AppModel()
        model.catalog = catalog
        model.search = "other"
        model.selection = ["other"]
        model.activeID = "other"
        try model.reload()
        let tools = tools(model)
        let workspace = data(await call(tools, .workspace))
        let session = try XCTUnwrap(workspace["catalog_session_id"])
        let args: [String: Value] = ["catalog_session_id": session, "query": ["sort": "filename"]]
        let accepted = await call(tools, .cullPhotos, args)
        XCTAssertEqual(accepted.content.count, 1)
        let jobID = try XCTUnwrap(data(accepted)["job_id"])
        let finished = try await cullingJob(tools, jobID: jobID, pageSize: 2)
        XCTAssertEqual(finished["state"], "partially_succeeded", String(describing: finished))
        XCTAssertEqual(finished["commit_state"], "not_committed")
        XCTAssertEqual(finished["analyzed_count"], 5)
        XCTAssertEqual(finished["group_count"], 1)
        XCTAssertEqual(finished["grouped_count"], 2)
        let rows = try XCTUnwrap(finished["items"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(rows.map { $0["photo_id"] }, ["sharp", "soft"])
        XCTAssertEqual(rows.map { $0["recommended"] }, [true, false])
        XCTAssertEqual(rows.map { $0["rank"] }, [1, 2])
        XCTAssertGreaterThan(try XCTUnwrap(rows[0]["sharpness"]?.number), try XCTUnwrap(rows[1]["sharpness"]?.number))
        let next = data(await call(tools, .job, ["job_id": jobID, "offset": try XCTUnwrap(finished["next_offset"])]))
        let remaining = try XCTUnwrap(next["items"]?.arrayValue?.compactMap(\.objectValue))
        for id in ["other", "later", alias] {
            XCTAssertEqual(remaining.first { $0["photo_id"] == .string(id) }?["group_number"], .null)
        }
        XCTAssertEqual(remaining.last?["error_code"], "file_access_required")
        let rankedIDs = try rows.map { try XCTUnwrap($0["photo_id"]) }
        let sheetArgs: [String: Value] = ["catalog_session_id": session, "photo_ids": .array(rankedIDs),
                                          "page_size": 1, "contact_sheet": true]
        checkError(await call(tools, .listPhotos, sheetArgs), "image_access_disabled")
        tools.setSharesImages(true)
        let sheet = await call(tools, .listPhotos, sheetArgs)
        XCTAssertEqual(sheet.content.count, 2)
        let firstCell = try XCTUnwrap(data(sheet)["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(firstCell["photo_id"], "sharp")
        XCTAssertEqual(firstCell["number"], 1)
        XCTAssertEqual(data(sheet)["query_mode"], "explicit")
        let nextSheet = data(await call(tools, .listPhotos, ["catalog_session_id": session,
            "cursor": try XCTUnwrap(data(sheet)["next_cursor"]), "contact_sheet": true]))
        XCTAssertEqual(nextSheet["items"]?.arrayValue?.first?.objectValue?["photo_id"], "soft")
        XCTAssertEqual(nextSheet["items"]?.arrayValue?.first?.objectValue?["number"], 2)
        let tile = await call(tools, .preview, ["catalog_session_id": session, "photo_id": "sharp",
            "source_revision": try XCTUnwrap(rows[0]["source_revision"]), "recipe_revision": try XCTUnwrap(rows[0]["recipe_revision"]),
            "resolution": "native", "region_pixels": ["x": 16, "y": 16, "width": 32, "height": 24]])
        XCTAssertEqual(tile.content.count, 2)
        XCTAssertEqual(data(tile)["width"], 32)
        XCTAssertEqual(data(tile)["height"], 24)
        checkError(await call(tools, .listPhotos, ["catalog_session_id": session, "photo_ids": ["absent"]]), "photo_unavailable")

        let similar = data(await call(tools, .cullPhotos, ["catalog_session_id": session,
            "photo_ids": ["later", "missing", "other", "sharp", "soft", .string(alias)], "reference_photo_id": "sharp"]))
        let matches = try await cullingJob(tools, jobID: XCTUnwrap(similar["job_id"]))
        XCTAssertEqual(matches["mode"], "similar")
        XCTAssertEqual(matches["match_count"], 2)
        let matched = try XCTUnwrap(matches["items"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(Set(matched.prefix(2).compactMap { $0["photo_id"]?.stringValue }), ["soft", "later"])

        let before = try XCTUnwrap(catalog.photo("sharp"))
        let baseline = try await model.pipeline.baseline(.init(photo: before, root: root, recipe: nil))
        var darkened = baseline
        darkened.exposure = -3
        darkened.crop = Crop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        try catalog.saveRecipe(id: "sharp", recipe: darkened)
        let afterEdit = data(await call(tools, .cullPhotos, ["catalog_session_id": session, "photo_ids": ["sharp", "soft"]]))
        let repeated = try await cullingJob(tools, jobID: XCTUnwrap(afterEdit["job_id"]))
        XCTAssertEqual(repeated["items"]?.arrayValue?.first?.objectValue?["sharpness"], rows[0]["sharpness"])
        XCTAssertEqual(repeated["items"]?.arrayValue?.first?.objectValue?["recipe_revision"], 1)
        let final = data(await call(tools, .workspace))
        for key in ["source_id", "query", "query_revision", "selection_revision", "active_photo_id", "selected_photo_ids", "page_offset", "view"] {
            XCTAssertEqual(final[key], workspace[key], key)
        }
        XCTAssertEqual(try catalog.photo("sharp")?.flag, 0)
        XCTAssertNil(try catalog.photo("soft")?.recipe)
        XCTAssertTrue(try catalog.stacks().isEmpty)
        XCTAssertFalse(model.undo.canUndo)

        try cullingPNG(directory.appendingPathComponent("soft.png"), other: true)
        let changed = data(await call(tools, .cullPhotos, ["catalog_session_id": session, "photo_ids": ["soft"]]))
        let staleFile = try await cullingJob(tools, jobID: XCTUnwrap(changed["job_id"]))
        XCTAssertEqual(staleFile["state"], "failed")
        XCTAssertEqual(staleFile["items"]?.arrayValue?.first?.objectValue?["state"], "unavailable")
        checkError(await call(tools, .cullPhotos, ["catalog_session_id": session]), "invalid_arguments")
    }

    @MainActor func testCullingCancellationAndCatalogScopeDoNotAffectTheWorkspace() async throws {
        let (catalog, model, tools) = try fixture()
        _ = await call(tools, .workspace)
        let start = data(try tools.workflows.startCulling(["query": [:]], catalog: catalog).response())
        let jobID = try XCTUnwrap(start["job_id"])
        XCTAssertTrue(model.workspaceAvailable)
        XCTAssertNil(model.task)
        XCTAssertThrowsError(try tools.workflows.startCulling(["query": [:]], catalog: catalog)) { error in
            XCTAssertEqual((error as? MCPToolProblem)?.code, "workspace_busy")
        }
        let response = try tools.workflows.control(.cancelJob, arguments: ["job_id": jobID])
        XCTAssertEqual(data(response.response())["cancel_requested"], true)
        let cancelled = try await cullingJob(tools, jobID: jobID)
        XCTAssertEqual(cancelled["state"], "cancelled")
        XCTAssertEqual(cancelled["total"], 0)
        XCTAssertEqual(cancelled["commit_state"], "not_committed")
        try model.activateCatalog(catalog)
        checkError(await call(tools, .job, ["job_id": jobID]), "catalog_changed")
    }

    @MainActor func testCullingMeasuresPublicRAWWithoutCreatingAnEditRecipe() async throws {
        let fixture = try MoreRAWTests.sample("leica_m8_8bit_uncompressed.DNG")
        let (directory, catalog) = try temporaryCatalog()
        let root = try catalog.addRoot(url: directory, bookmark: AccessLease.bookmark(directory, readOnly: true))
        let url = directory.appendingPathComponent("raw.DNG")
        try FileManager.default.copyItem(at: fixture, to: url)
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
        XCTAssertTrue(photo.isRAW)
        try catalog.index(photo)
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        let tools = tools(model)
        let session = Value.string(try XCTUnwrap(model.catalogSessionID))
        let start = data(await call(tools, .cullPhotos, ["catalog_session_id": session, "photo_ids": [.string(photo.id)]]))
        let report = try await cullingJob(tools, jobID: XCTUnwrap(start["job_id"]))
        XCTAssertEqual(report["state"], "succeeded", String(describing: report))
        let row = try XCTUnwrap(report["items"]?.arrayValue?.first?.objectValue)
        XCTAssertTrue((0...100).contains(try XCTUnwrap(row["sharpness"]?.number)))
        XCTAssertTrue((0...1).contains(try XCTUnwrap(row["shadow_clip_fraction"]?.number)))
        XCTAssertTrue((0...1).contains(try XCTUnwrap(row["highlight_clip_fraction"]?.number)))
        XCTAssertNil(try catalog.photo(photo.id)?.recipe)
        XCTAssertTrue(try catalog.editHistory(photoID: photo.id).isEmpty)
        XCTAssertEqual(try SafeFileWriter.sha256(url), try SafeFileWriter.sha256(fixture))
    }

    func testCullingClippingCountsOpaqueSamplesAndRejectsFeaturelessSimilarity() throws {
        let bytes: [UInt8] = [
            0, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0, 64, 64, 64, 128
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 16, space: ImagePipeline.outputSpace,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let metrics = try XCTUnwrap(CullingMetrics.measure(image))
        let expected = 1 / (2 + 128.0 / 255)
        XCTAssertEqual(metrics.shadowClipFraction, expected, accuracy: 0.00001)
        XCTAssertEqual(metrics.highlightClipFraction, expected, accuracy: 0.00001)
        XCTAssertNil(metrics.sharpness)
        XCTAssertNil(metrics.similarity(to: metrics))
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
        XCTAssertTrue(service.jsonClientConfiguration == nil)
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
            let json = try XCTUnwrap(service.jsonClientConfiguration)
            let document = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let configuration = try XCTUnwrap(document as? [String: [String: [String: Any]]])
            let servers = try XCTUnwrap(configuration["mcpServers"])
            XCTAssertEqual(Set(servers.keys), ["phosdeck"])
            let entry = try XCTUnwrap(servers["phosdeck"])
            XCTAssertEqual(entry["type"] as? String, "http")
            XCTAssertEqual(entry["url"] as? String, endpoint)
            let headers = try XCTUnwrap(entry["headers"] as? [String: String])
            XCTAssertTrue(headers["Authorization"] == "Bearer \(token)")
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
        XCTAssertTrue(service.jsonClientConfiguration == nil)
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
