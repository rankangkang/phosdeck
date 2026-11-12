import CoreGraphics
import ImageIO
import MCP
import os
import UniformTypeIdentifiers
import XCTest
@testable import Phosdeck

@MainActor
final class AgentOutputTests: XCTestCase {
    private typealias Fields = [String: Value]

    @MainActor private final class Picker {
        var directory: URL?
    }

    @MainActor private final class Client {
        let model: AppModel
        let tools: AppMCPTools
        let picker = Picker()

        init(model: AppModel, sharesImages: Bool = false) {
            self.model = model
            let picker = picker
            tools = AppMCPTools(model: model, appName: "Phosdeck Test", version: "1", bundleID: "test",
                                sharesImages: sharesImages, chooseFile: { _ in picker.directory })
        }

        func response(_ tool: AppMCPTool, _ input: Fields = [:]) async -> CallTool.Result {
            var args = input
            if tool.needsCatalog || tool.needsRequestID {
                let workspace = Self.data(await tools.call(.init(name: AppMCPTool.workspace.rawValue)))
                if tool.needsCatalog || tool.optional.contains(.catalog), workspace["catalog_session_id"] != .null {
                    args["catalog_session_id"] = workspace["catalog_session_id"]
                }
                if tool.needsRequestID {
                    args["request_epoch"] = workspace["request_epoch"]
                    args["request_id"] = args["request_id"] ?? .string(UUID().uuidString)
                }
            }
            return await tools.call(.init(name: tool.rawValue, arguments: args))
        }
        static func data(_ result: CallTool.Result) -> Fields {
            let payload = result.structuredContent?.objectValue ?? [:]
            var data = payload["data"]?.objectValue ?? [:]
            data["tool_error"] = payload["error"]?.objectValue?["code"]
            return data
        }
        func call(_ tool: AppMCPTool, _ args: Fields = [:]) async -> Fields {
            Self.data(await response(tool, args))
        }
        func finished(_ tool: AppMCPTool, _ args: Fields = [:]) async throws -> Fields {
            try await job(await call(tool, args))
        }
        func job(_ accepted: Fields) async throws -> Fields {
            let id = try XCTUnwrap(accepted["job_id"], "\(accepted)")
            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
            repeat {
                let state = await call(.job, ["job_id": id])
                if state["phase"] == "finished" { return state }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            throw LRCError("Output job did not finish")
        }
        func access(_ purpose: MCPFilePurpose, directory: URL) async throws -> Value {
            picker.directory = directory
            let result = try await finished(.fileAccess, ["purpose": .string(purpose.rawValue)])
            XCTAssertEqual(result["state"], "succeeded")
            return try XCTUnwrap(result["access_id"])
        }
    }

    private struct Fixture {
        let source: URL
        let masters: URL
        let output: URL
        let catalog: CatalogStore
        let client: Client

        func current(_ id: String) throws -> Photo { try XCTUnwrap(catalog.photo(id)) }
        func ordered(_ photos: [Photo], adding args: Fields = [:]) -> Fields {
            var fields = args
            fields["photo_ids"] = .array(photos.map { .string($0.id) })
            fields["expected_revisions"] = .object(Dictionary(uniqueKeysWithValues: photos.map {
                ($0.id, ["source_revision": .int($0.revision), "recipe_revision": .int($0.recipeRevision)])
            }))
            return fields
        }
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-agent-output-" + UUID().uuidString)
        let source = directory.appendingPathComponent("bracket"), masters = directory.appendingPathComponent("masters")
        let output = directory.appendingPathComponent("outputs")
        for folder in [source, masters, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
        addTeardownBlock {
            try catalog.database.close()
            try FileManager.default.removeItem(at: directory)
        }
        for (index, exposure) in [0.4, 1.0, 2.5].enumerated() {
            let width = 96, height = 72
            var raw = Data()
            for y in 0..<height {
                raw.append(0)
                for x in 0..<width {
                    let intensity = 0.04 + Double((x * 7 + y * 11) % 71) / 80
                    let red = UInt8((pow(min(1, intensity * exposure), 1 / 2.2) * 255).rounded())
                    let green = UInt8((pow(min(1, intensity * exposure * 0.82), 1 / 2.2) * 255).rounded())
                    let blue = UInt8((pow(min(1, intensity * exposure * 0.64), 1 / 2.2) * 255).rounded())
                    raw.append(contentsOf: [red, green, blue, x < 8 ? 0 : 255])
                }
            }
            let header = PNGFixture.word(width) + PNGFixture.word(height) + Data([8, 6, 0, 0, 0])
            let png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + PNGFixture.chunk("IHDR", header)
                + PNGFixture.chunk("IDAT", try PNGFixture.compress(raw)) + PNGFixture.chunk("IEND", Data())
            try png.write(to: source.appendingPathComponent("exposure-\(index).png"))
        }
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        return Fixture(source: source, masters: masters, output: output, catalog: catalog, client: Client(model: model))
    }

    private func imported(_ fixture: Fixture) async throws -> [Photo] {
        let client = fixture.client
        let access = try await client.access(.importSource, directory: fixture.source)
        let plan = try await client.finished(.planImport, ["mode": "reference", "source_access_id": access])
        let run = try await client.finished(.startImport, ["plan_id": try XCTUnwrap(plan["plan_id"]), "select_all": true])
        XCTAssertEqual(run["state"], "succeeded", "\(run)")
        let photos = try fixture.catalog.photos()
        XCTAssertEqual(photos.count, 3)
        return photos
    }

    @discardableResult private func succeeded(_ result: Fields, line: UInt = #line) -> Fields {
        XCTAssertEqual(result["state"], "succeeded", "\(result)", line: line)
        return result
    }

    private func png(_ result: CallTool.Result, line: UInt = #line) throws -> String {
        guard case .image(let data, "image/png", _, _) = result.content.last else {
            XCTFail("Missing PNG content", line: line); throw LRCError("Missing preview")
        }
        return data
    }

    func testReferenceBracketToHDRDNGAndLocalMaskToTwoVerifiedJPEGs() async throws {
        let files = try fixture(), client = files.client
        let photos = try await imported(files)
        let ordered = [photos[2], photos[0], photos[1]]
        let collection = await client.call(.saveCollection, ["name": "HDR Outputs"])
        let collectionID = try XCTUnwrap(collection["collection_id"])
        let plan = succeeded(try await client.finished(.planMerge, files.ordered(ordered, adding: [
            "merge_kind": "hdr", "collection_id": collectionID, "options": ["align": false, "deghost": 0]
        ])))
        XCTAssertEqual(plan["items"]?.arrayValue?.compactMap { $0.objectValue?["photo_id"]?.stringValue }, ordered.map(\.id))
        let rendered = succeeded(try await client.finished(.renderMerge, ["plan_id": try XCTUnwrap(plan["plan_id"])]))
        let previewID = try XCTUnwrap(rendered["preview_id"])
        let gated = await client.call(.getMergePreview, ["preview_id": previewID])
        XCTAssertEqual(gated["tool_error"], "image_access_disabled")
        client.tools.setSharesImages(true)
        let neutral = try png(await client.response(.getMergePreview, ["preview_id": previewID]))
        let raised = try png(await client.response(.getMergePreview, ["preview_id": previewID, "display_ev": 1]))
        XCTAssertNotEqual(neutral, raised)
        let destination = try await client.access(.mergeDestination, directory: files.masters)
        let save: Fields = ["preview_id": previewID, "destination_access_id": destination, "master_format": "dng",
                            "filename": "test-master.dng", "request_id": "hdr-master"]
        let accepted = await client.call(.saveMerge, save)
        let merged = succeeded(try await client.job(accepted))
        let replay = await client.call(.saveMerge, save)
        XCTAssertEqual(replay["job_id"], accepted["job_id"])
        XCTAssertEqual(merged["published"], true); XCTAssertEqual(merged["verified"], true); XCTAssertEqual(merged["indexed"], true)
        XCTAssertEqual(merged["collection_id"], collectionID)
        XCTAssertEqual(merged["bit_depth"], 32)
        let id = try XCTUnwrap(merged["photo_id"]?.stringValue)
        XCTAssertEqual(merged["stack_member_ids"]?.arrayValue?.compactMap(\.stringValue), [id] + ordered.map(\.id))
        let readback = try MergeMasterCodec.read(files.masters.appendingPathComponent("test-master.dng"), context: MergeMasterCodec.context())
        XCTAssertEqual(readback.provenance.sources.map(\.photoID), ordered.map(\.id))
        XCTAssertEqual(readback.provenance.options.masterFormat, .dng)
        XCTAssertEqual(readback.image.width, 96); XCTAssertEqual(readback.image.height, 72)
        let undo = await client.call(.undo, ["operation_id": try XCTUnwrap(merged["operation_id"])])
        XCTAssertEqual(undo["commit_state"], "committed")
        XCTAssertTrue(try files.catalog.stacks().isEmpty)
        XCTAssertNotNil(try files.catalog.photo(id))

        _ = await client.call(.selectPhotos, ["action": "open_version", "photo_id": .string(id)])
        _ = await client.call(.workspaceView, ["view": "develop"])
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (!client.model.canEdit || client.model.orientedSourceSize == nil) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = await client.call(.workspaceView, ["view": "develop", "tool": "mask"])
        XCTAssertNil(view["tool_error"], "\(view)")
        let master = try files.current(id)
        let root = try XCTUnwrap(files.catalog.roots().first { $0.id == master.rootID })
        let recipe = try MCPDevelopPhoto.decode(XCTUnwrap(master.recipe), for: master)
        let source = SmartMaskSource(recipe: recipe, size: CGSize(width: master.width, height: master.height))
        var session = SmartMaskSession(photoID: id, catalogPath: files.catalog.fileURL.path,
            request: ImageRequest(photo: master, root: root, recipe: recipe), source: source, target: .newMask)
        // A deterministic selection stands in for Vision's output on a real portrait.
        let person = try SmartMaskTile(values: [0, 1, 0, 0, 1, 0, 1, 1, 1, 0, 1, 0], width: 3, height: 4,
                                       region: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.7))
        session.workflow = .people; session.ready = true; session.wholePerson = true
        session.preview = SmartMaskRaster(source: source, model: "vision-person-instance-synthetic", base: person)
        client.model.smartMaskSession = session
        let state = await client.call(.maskState, MCPDevelopPhoto.revisions(master))
        let selection = try XCTUnwrap(state["smart_mask"]?.objectValue)
        var apply = MCPDevelopPhoto.revisions(master)
        apply["smart_session_id"] = selection["smart_session_id"]; apply["selection_revision"] = selection["selection_revision"]
        _ = succeeded(try await client.finished(.smartApply, apply))
        let masked = try files.current(id)
        let group = try XCTUnwrap(try MCPDevelopPhoto.decode(XCTUnwrap(masked.recipe), for: masked).localAdjustments.first)
        var local = MCPDevelopPhoto.revisions(masked)
        local.merge(["action": "set", "mask_id": .string(group.id.uuidString), "adjustments": ["basic": ["exposure": 0.65]]]) { _, value in value }
        _ = succeeded(try await client.finished(.localAdjustments, local))
        _ = try files.catalog.setCaptions([id: "Frozen synthetic portrait caption"])

        let exportAccess = try await client.access(.exportDestination, directory: files.output)
        let export = succeeded(try await client.finished(.planExport, files.ordered([try files.current(id)], adding: [
            "destination_access_id": exportAccess,
            "specifications": [
                ["title": "Large", "subfolder": "large", "options": ["format": "jpeg", "long_edge": 64, "jpeg_matte": "black", "metadata_policy": "description"]],
                ["title": "Small", "subfolder": "small", "options": ["format": "jpeg", "long_edge": 32, "jpeg_matte": "white", "metadata_policy": "description"]]
            ]
        ])))
        XCTAssertEqual(export["ready"], true); XCTAssertEqual(export["output_count"], 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.output.path).isEmpty)
        let exportID = try XCTUnwrap(export["plan_id"])
        let first = try XCTUnwrap(export["items"]?.arrayValue?.first?.objectValue?["output_id"])
        client.tools.setSharesImages(false)
        let names = await client.call(.getExportPreview, ["plan_id": exportID])
        XCTAssertEqual(names["total"], 2)
        let denied = await client.call(.getExportPreview, ["plan_id": exportID, "output_id": first])
        XCTAssertEqual(denied["tool_error"], "image_access_disabled")
        client.tools.setSharesImages(true)
        _ = try png(await client.response(.getExportPreview, ["plan_id": exportID, "output_id": first]))
        _ = try files.catalog.setCaptions([id: "Edited after planning"])
        let saved = succeeded(try await client.finished(.runExport, ["plan_id": exportID]))
        XCTAssertEqual(saved["published_count"], 2)
        let results = try XCTUnwrap(saved["items"]?.arrayValue)
        XCTAssertEqual(results.compactMap { $0.objectValue?["width"]?.intValue }, [64, 32])
        let logs = try ExportService.history(catalog: files.catalog).logs
        XCTAssertEqual(logs.count, 2)
        for (log, width) in zip(logs, [64, 32]) {
            XCTAssertEqual(log.state, "completed")
            XCTAssertEqual(log.snapshot.metadata.descriptive.caption, "Frozen synthetic portrait caption")
            XCTAssertEqual(log.snapshot.request.recipe?.localAdjustments.first?.exposure, 0.65)
            try ImagePipeline.verifyExport(log.snapshot.destination, width: width, height: width * 3 / 4,
                                           format: .jpeg, metadata: log.snapshot.metadata)
        }
    }

    func testExportPresetRevisionAndOptionsAreFrozenAtPlanning() async throws {
        let files = try fixture(), client = files.client
        let photos = try await imported(files)
        let suite = "phosdeck-agent-output-presets-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        client.tools.workflows.exportDefaults = defaults
        var original = ExportPreferences()
        original.lastOptions.format = .tiff
        try original.save(to: defaults)

        let presets = await client.call(.listExportPresets)
        let builtIn = try XCTUnwrap(presets["items"]?.arrayValue?.first?.objectValue)
        let locked = await client.call(.editExportPreset, ["action": "delete", "preset_id": try XCTUnwrap(builtIn["preset_id"]),
            "preset_revision": try XCTUnwrap(builtIn["preset_revision"])])
        XCTAssertEqual(locked["tool_error"], "invalid_arguments")

        let created = await client.call(.editExportPreset, ["action": "create", "name": "Synthetic PNG",
            "options": ["format": "png", "long_edge": 48, "naming": ["prefix": "preset-"]]])
        let preset = try XCTUnwrap(created["preset"]?.objectValue, "\(created)")
        let id = try XCTUnwrap(preset["preset_id"]), revision = try XCTUnwrap(preset["preset_revision"])
        let access = try await client.access(.exportDestination, directory: files.output)
        let input = files.ordered([photos[0]], adding: ["destination_access_id": access, "preset_id": id,
            "preset_revision": revision, "options": ["long_edge": 32]])
        let plan = succeeded(try await client.finished(.planExport, input))
        let renamed = await client.call(.editExportPreset, ["action": "rename", "name": "Updated PNG",
            "preset_id": id, "preset_revision": revision])
        let currentRevision = try XCTUnwrap(renamed["preset"]?.objectValue?["preset_revision"])
        XCTAssertNotEqual(currentRevision, revision)
        let stale = await client.call(.planExport, input)
        XCTAssertEqual(stale["tool_error"], "stale_export_preset")

        let restored = await client.call(.editExportPreset, ["action": "restore_defaults"])
        XCTAssertEqual(restored["commit_state"], "committed")
        XCTAssertEqual(try ExportPreferences.load(from: defaults).lastOptions, ExportOptions())
        XCTAssertEqual(try ExportPreferences.load(from: defaults).presets.map(\.name), ["Updated PNG"])
        let saved = succeeded(try await client.finished(.runExport, ["plan_id": try XCTUnwrap(plan["plan_id"])]))
        let item = try XCTUnwrap(saved["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(item["width"], 32)
        XCTAssertEqual(item["format"], "png")
        XCTAssertTrue(item["filename"]?.stringValue?.hasPrefix("preset-") == true)
        let deleted = await client.call(.editExportPreset, ["action": "delete", "preset_id": id, "preset_revision": currentRevision])
        XCTAssertEqual(deleted["commit_state"], "committed")
        XCTAssertTrue(try ExportPreferences.load(from: defaults).presets.isEmpty)
    }

    func testMergeReportsPublishedMasterWhenCatalogRegistrationFails() async throws {
        let files = try fixture(), client = files.client
        let photos = try await imported(files)
        client.tools.workflows.makeMergeEngine = {
            PhotoMergeEngine(checkpoint: { phase in if phase == "published" { throw LRCError("Injected failure after publication") } })
        }
        let plan = succeeded(try await client.finished(.planMerge, files.ordered(Array(photos.prefix(2)), adding: [
            "merge_kind": "average", "options": ["align": false]
        ])))
        let preview = succeeded(try await client.finished(.renderMerge, ["plan_id": try XCTUnwrap(plan["plan_id"])]))
        let access = try await client.access(.mergeDestination, directory: files.masters)
        let result = try await client.finished(.saveMerge, ["preview_id": try XCTUnwrap(preview["preview_id"]),
            "destination_access_id": access, "filename": "preserved.tif"])
        XCTAssertEqual(result["state"], "partially_succeeded")
        XCTAssertEqual(result["commit_state"], "committed")
        XCTAssertEqual(result["published"], true)
        XCTAssertEqual(result["verified"], false)
        XCTAssertEqual(result["indexed"], false)
        XCTAssertEqual(result["photo_id"], .null)
        XCTAssertEqual(try files.catalog.photoCount(), photos.count)
        let path = files.masters.appendingPathComponent("preserved.tif")
        XCTAssertEqual(try MergeMasterCodec.read(path, context: MergeMasterCodec.context()).provenance.sources.map(\.photoID),
                       photos.prefix(2).map(\.id))
        var revealed: [URL] = []
        client.tools.workflows.activateFilesInFinder = { revealed = $0 }
        let shown = succeeded(try await client.finished(.revealFile, ["kind": "merge", "file_id": try XCTUnwrap(result["file_id"])]))
        XCTAssertEqual(shown["revealed_count"], 1)
        XCTAssertEqual(revealed.map { $0.resolvingSymlinksInPath().path }, [path.resolvingSymlinksInPath().path])
    }

    func testOutputConflictsAndPublishedRecoveryAcrossAServiceRestart() async throws {
        let files = try fixture(), client = files.client
        let photos = try await imported(files)
        let access = try await client.access(.exportDestination, directory: files.output)
        let single = files.ordered([photos[0]], adding: ["destination_access_id": access,
            "options": ["format": "png", "naming": ["prefix": "check-"]]])
        let plan = succeeded(try await client.finished(.planExport, single))
        let planned = try XCTUnwrap(plan["items"]?.arrayValue?.first?.objectValue?["filename"]?.stringValue)
        let occupied = files.output.appendingPathComponent(planned), contents = Data("Existing output".utf8)
        try contents.write(to: occupied)
        let refused = try await client.finished(.runExport, ["plan_id": try XCTUnwrap(plan["plan_id"])])
        XCTAssertEqual(refused["error_code"], "output_conflict")
        XCTAssertEqual(try Data(contentsOf: occupied), contents)
        XCTAssertTrue(try ExportService.history(catalog: files.catalog).logs.isEmpty)
        let conflict = succeeded(try await client.finished(.planExport, single))
        XCTAssertEqual(conflict["ready"], false)

        let fault = OSAllocatedUnfairLock(initialState: true)
        client.tools.workflows.makeExportService = { pipeline in
            ExportService(pipeline: pipeline, checkpoint: { phase in
                if phase == "publishedBeforeJournal", fault.withLock({ first in let result = first; first = false; return result }) {
                    throw LRCError("Injected journal failure")
                }
            })
        }
        let multi = succeeded(try await client.finished(.planExport, files.ordered([photos[0]], adding: [
            "destination_access_id": access, "specifications": [
                ["title": "PNG", "subfolder": "png", "options": ["format": "png"]],
                ["title": "TIFF", "subfolder": "tiff", "options": ["format": "tiff"]]
            ]
        ])))
        let result = try await client.finished(.runExport, ["plan_id": try XCTUnwrap(multi["plan_id"])])
        XCTAssertEqual(result["state"], "partially_succeeded")
        XCTAssertEqual(result["published_count"], 2)
        XCTAssertEqual(result["completed_count"], 1)
        let rows = try XCTUnwrap(result["items"]?.arrayValue)
        let ids = rows.compactMap { $0.objectValue?["record_id"] }
        XCTAssertEqual(rows.compactMap { $0.objectValue?["state"] }, ["needsReview", "completed"])
        XCTAssertTrue(rows.first?.objectValue?["error"]?.stringValue?.contains("Injected journal failure") == true)
        let fresh = Client(model: client.model)
        let incomplete = await fresh.call(.exportRecords, ["unfinished_only": true, "page_size": 1])
        XCTAssertEqual(incomplete["total"], 1)
        let wrong = try await fresh.access(.exportDestination, directory: files.output)
        let unrenewed = try await fresh.finished(.reauthorizeExport, ["record_ids": .array([ids[0]]), "access_id": wrong])
        XCTAssertEqual(unrenewed["error_code"], "export_location_mismatch")
        let right = try await fresh.access(.exportDestination, directory: files.output.appendingPathComponent("png"))
        _ = succeeded(try await fresh.finished(.reauthorizeExport, ["record_ids": .array([ids[0]]), "access_id": right]))
        let verified = succeeded(try await fresh.finished(.retryExport, ["record_ids": .array(ids)]))
        XCTAssertEqual(verified["verified_count"], 2)
        XCTAssertEqual(verified["published_count"], 0)
        let records = try ExportService.history(catalog: files.catalog).logs
        for record in records {
            let format = record.snapshot.options.format
            try ImagePipeline.verifyExport(record.snapshot.destination, width: 96, height: 72, format: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(record.snapshot.destination as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.bitsPerComponent, format.bitDepth)
            XCTAssertTrue([CGImageAlphaInfo.last, .premultipliedLast, .first, .premultipliedFirst].contains(image.alphaInfo))
        }
    }
}
