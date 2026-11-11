import AppKit
import MCP
import XCTest
@testable import Phosdeck

@MainActor
final class AgentLibraryTests: XCTestCase {
    private typealias Data = [String: Value]

    @MainActor private final class Picker {
        var urls: [URL?] = []
        func choose(_ panel: NSOpenPanel) -> URL? {
            XCTAssertFalse(urls.isEmpty, "Unexpected chooser: \(panel.title ?? "")")
            return urls.isEmpty ? nil : urls.removeFirst()
        }
    }

    @MainActor private final class Client {
        let model: AppModel
        let tools: AppMCPTools
        init(_ model: AppModel, picker: Picker? = nil) {
            self.model = model
            let picker = picker ?? Picker()
            tools = AppMCPTools(model: model, appName: "Phosdeck Test", version: "1", bundleID: "test", sharesImages: false,
                                chooseFile: { picker.choose($0) })
        }
        func call(_ tool: AppMCPTool, _ input: Data = [:], context: Bool = true) async -> Data {
            var arguments = input
            if context && (tool.needsCatalog || tool.needsRequestID) {
                let workspace = await call(.workspace, context: false)
                if workspace["catalog_session_id"] != .null { arguments["catalog_session_id"] = workspace["catalog_session_id"] }
                if tool.needsRequestID {
                    arguments["request_epoch"] = workspace["request_epoch"]
                    arguments["request_id"] = arguments["request_id"] ?? .string(UUID().uuidString)
                }
            }
            let result = await tools.call(.init(name: tool.rawValue, arguments: arguments))
            let payload = result.structuredContent?.objectValue ?? [:]
            var output = payload["data"]?.objectValue ?? [:]
            if let error = payload["error"]?.objectValue?["code"] { output["tool_error"] = error }
            return output
        }
        func job(_ initial: Data, until desired: Set<String> = ["succeeded", "partially_succeeded", "failed", "cancelled"]) async throws -> Data {
            let id = try XCTUnwrap(initial["job_id"], "\(initial)")
            for _ in 0..<300 {
                let result = await call(.job, ["job_id": id])
                if let state = result["state"]?.stringValue, desired.contains(state) { return result }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LRCError("Timed out waiting for job \(id)")
        }
        func access(_ purpose: MCPFilePurpose) async throws -> Value {
            let accepted = await call(.fileAccess, ["purpose": .string(purpose.rawValue)])
            XCTAssertEqual(accepted["state"], "waiting_for_user")
            let result = try await job(accepted)
            XCTAssertEqual(result["state"], "succeeded", "\(result)")
            return try XCTUnwrap(result["access_id"])
        }
    }

    private func makeModel() throws -> (ImportTests, AppModel) {
        let files = ImportTests()
        try files.setUpWithError()
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = files.catalog
        try model.reload()
        addTeardownBlock { try files.tearDownWithError() }
        return (files, model)
    }

    private func items(_ data: Data) -> [Data] { data["items"]?.arrayValue?.compactMap(\.objectValue) ?? [] }

    func testNativePickerResultIsPurposeScopedAndCatalogWritesReplayAfterSwitch() async throws {
        let (files, model) = try makeModel()
        let picker = Picker()
        let client = Client(model, picker: picker)
        let old = try XCTUnwrap(model.catalogSessionID)
        picker.urls = [nil, files.directory, files.catalog.fileURL, files.catalog.directory]
        let pending = await client.call(.fileAccess, ["purpose": "import_source"])
        XCTAssertEqual(pending["state"], "waiting_for_user")
        let cancelled = try await client.job(pending)
        XCTAssertEqual(cancelled["state"], "cancelled")
        XCTAssertNil(cancelled["access_id"])
        let grant = try await client.access(.createCatalog)
        let wrongPurpose = await client.call(.planImport, ["mode": "reference", "source_access_id": grant])
        XCTAssertEqual(wrongPurpose["tool_error"], "file_access_required")
        let fileGrant = try await client.access(.openCatalog)
        let original = await client.call(.workspace)
        let create: Data = ["catalog_session_id": .string(old), "request_epoch": try XCTUnwrap(original["request_epoch"]),
                            "request_id": "make", "name": "Agent review", "access_id": grant]
        let accepted = await client.call(.createCatalog, create, context: false)
        let created = try await client.job(accepted)
        XCTAssertEqual(created["state"], "succeeded", "\(created)")
        XCTAssertEqual(model.catalog?.fileURL.lastPathComponent, "Agent review.phoscat")
        XCTAssertNotEqual(model.catalogSessionID, old)
        let replay = await client.call(.createCatalog, create, context: false)
        XCTAssertEqual(replay["job_id"], accepted["job_id"])
        let expired = await client.call(.openCatalog, ["access_id": fileGrant])
        XCTAssertEqual(expired["tool_error"], "file_access_required")
        let another = files.directory.appendingPathComponent("Another.phoscat")
        do { _ = try CatalogStore(fileURL: another, create: true) }
        picker.urls = [another, files.directory]
        let open = try await client.access(.openCatalog)
        let opened = try await client.job(await client.call(.openCatalog, ["access_id": open]))
        XCTAssertEqual(opened["catalog_name"], "Another")
        XCTAssertEqual(opened["state"], "succeeded")
        XCTAssertFalse(String(describing: opened).contains(files.directory.path))
        model.catalog = nil
    }

    func testReferenceImportReportsChangedCandidateAndFolderReviewRevalidatesBeforePublication() async throws {
        let (files, model) = try makeModel()
        let picker = Picker()
        let client = Client(model, picker: picker)
        let a = files.source.appendingPathComponent("A.jpg")
        let b = files.source.appendingPathComponent("B.jpg")
        try files.image(a); try files.image(b)
        picker.urls = [files.source]
        let source = try await client.access(.importSource)
        let plan = try await client.job(await client.call(.planImport, ["source_access_id": source, "mode": "reference"]))
        XCTAssertEqual(plan["eligible_count"], 2)
        XCTAssertEqual(try files.catalog.photoCount(), 0)
        try Foundation.Data("source changed".utf8).write(to: b)
        let started = await client.call(.startImport, ["plan_id": try XCTUnwrap(plan["plan_id"]), "select_all": true])
        let imported = try await client.job(started)
        XCTAssertEqual(imported["state"], "partially_succeeded")
        XCTAssertEqual(imported["commit_state"], "committed")
        XCTAssertEqual(imported["indexed_count"], 1)
        XCTAssertEqual(items(imported).first { $0["name"] == "B.jpg" }?["error_code"], "source_changed")
        let photo = try XCTUnwrap(files.catalog.photos().first)
        XCTAssertEqual(items(imported).first { $0["name"] == "A.jpg" }?["photo_id"], .string(photo.id))
        XCTAssertEqual(model.lastImport?.photoIDs, [photo.id])
        let recent = await client.call(.recentImport, ["action": "start_culling"])
        XCTAssertEqual(recent["active_photo_id"], .string(photo.id))
        _ = await client.call(.recentImport, ["action": "return"])
        XCTAssertEqual(model.scope, "all")
        let sources = await client.call(.librarySources)
        let root = try XCTUnwrap(items(sources).first { $0["kind"] == "root" }?["root_id"])
        let c = files.source.appendingPathComponent("C.jpg")
        try files.image(c)
        let review = try await client.job(await client.call(.planFolder, ["root_id": root]))
        let selected = try XCTUnwrap(items(review).first { $0["name"] == "C.jpg" }?["difference_id"])
        try files.image(c, color: .blue)
        let stale = try await client.job(await client.call(.applyFolder, ["plan_id": try XCTUnwrap(review["plan_id"]), "difference_ids": .array([selected])]))
        XCTAssertEqual(stale["state"], "failed")
        XCTAssertEqual(stale["error_code"], "stale_plan")
        XCTAssertEqual(try files.catalog.photoCount(), 1)
        let fresh = try await client.job(await client.call(.planFolder, ["root_id": root]))
        let add = try XCTUnwrap(items(fresh).first { $0["kind"] == "added" }?["difference_id"])
        let applied = try await client.job(await client.call(.applyFolder, ["plan_id": try XCTUnwrap(fresh["plan_id"]), "difference_ids": .array([add])]))
        XCTAssertEqual(applied["state"], "succeeded")
        XCTAssertEqual(applied["applied_count"], 1)
        XCTAssertEqual(try files.catalog.photoCount(), 2)
    }

    func testCopyConflictCancelKeepsPublishedFilesAndFreshServiceResumesTheJournal() async throws {
        let (files, model) = try makeModel()
        let picker = Picker()
        let client = Client(model, picker: picker)
        let first = files.source.appendingPathComponent("A.jpg")
        let second = files.source.appendingPathComponent("B.jpg")
        let conflictFile = files.target.appendingPathComponent("B.jpg")
        try files.image(first); try files.image(second); try files.image(conflictFile, color: .blue)
        let old = try SafeFileWriter.sha256(conflictFile)
        picker.urls = [files.source, files.target]
        let source = try await client.access(.importSource), target = try await client.access(.importDestination)
        let plan = try await client.job(await client.call(.planImport, ["mode": "copy", "source_access_id": source,
                                                                        "destination_access_id": target, "date_layout": "flat"]))
        XCTAssertEqual(plan["group_count"], 2)
        let started = await client.call(.startImport, ["plan_id": try XCTUnwrap(plan["plan_id"]), "select_all": true])
        let waiting = try await client.job(started, until: ["waiting_for_user"])
        let id = try XCTUnwrap(waiting["job_id"])
        XCTAssertEqual(waiting["user_action"], "resolve_import_conflict")
        XCTAssertNotNil(model.importConflict)
        XCTAssertEqual(try files.catalog.photoCount(), 1)
        let cancel = await client.call(.cancelJob, ["job_id": id])
        XCTAssertEqual(cancel["cancel_requested"], true)
        let cancelled = try await client.job(started)
        XCTAssertEqual(cancelled["state"], "cancelled")
        XCTAssertEqual(cancelled["can_resume"], true)
        XCTAssertEqual(cancelled["record_saved"], true)
        XCTAssertEqual(try SafeFileWriter.sha256(conflictFile), old)
        XCTAssertEqual(try SafeFileWriter.sha256(files.target.appendingPathComponent("A.jpg")), try SafeFileWriter.sha256(first))
        client.tools.stop()
        let restarted = Client(model, picker: picker)
        let records = await restarted.call(.importRecords)
        XCTAssertEqual(items(records).first?["record_id"], id)
        let restored = await restarted.call(.job, ["job_id": id, "page_size": 1])
        XCTAssertEqual(restored["state"], "cancelled")
        XCTAssertEqual(restored["next_offset"], 1)
        let resumed = await restarted.call(.resumeImport, ["record_id": id])
        let secondWait = try await restarted.job(resumed, until: ["waiting_for_user"])
        let conflict = try XCTUnwrap(secondWait["conflict"]?.objectValue)
        let resolved = await restarted.call(.resolveConflict, ["job_id": try XCTUnwrap(secondWait["job_id"]),
            "conflict_id": try XCTUnwrap(conflict["conflict_id"]), "policy": "overwrite", "apply_to_remaining": false])
        XCTAssertNil(resolved["tool_error"])
        let finished = try await restarted.job(resumed)
        XCTAssertEqual(finished["state"], "succeeded")
        XCTAssertEqual(finished["record_id"], id)
        XCTAssertEqual(try files.catalog.photoCount(), 2)
        XCTAssertEqual(try SafeFileWriter.sha256(conflictFile), try SafeFileWriter.sha256(second))
        let file = try XCTUnwrap(items(finished).first { $0["kind"] == "file" && $0["name"] == "B.jpg" })
        XCTAssertEqual(file["publication"], "verified")
        XCTAssertNotEqual(file["photo_id"], .null)
        XCTAssertEqual(file["recovery_state"], "recorded")
        picker.urls = [files.directory]
        let backupFolder = try await restarted.access(.restoreBackup)
        let recovery = try await restarted.job(await restarted.call(.restoreBackup, ["record_id": id, "member_id": try XCTUnwrap(file["member_id"]),
                                                                                     "access_id": backupFolder, "name": "prior.jpg"]))
        XCTAssertEqual(recovery["state"], "succeeded")
        XCTAssertEqual(try SafeFileWriter.sha256(files.directory.appendingPathComponent("prior.jpg")), old)
    }

    func testCopyJournalReportsPublishedMemberEvenWhenIndexingDidNotFinish() async throws {
        let (files, model) = try makeModel()
        let original = files.source.appendingPathComponent("A.jpg")
        try files.image(original)
        let plan = try await files.plan()
        let interrupted = await CopyImporter(checkpoint: { point in
            if point == "renamedBeforeJournal" { throw LRCError("Simulated interruption") }
        }).run(plan, catalog: files.catalog) { _ in }
        XCTAssertEqual(try files.catalog.photoCount(), 0)
        let client = Client(model)
        let result = await client.call(.job, ["job_id": .string(interrupted.id)])
        XCTAssertEqual(result["state"], "partially_succeeded")
        let file = try XCTUnwrap(items(result).first { $0["kind"] == "file" })
        XCTAssertEqual(file["publication"], "present_at_staged_identity")
        XCTAssertEqual(file["photo_id"], .null)
        XCTAssertEqual(try SafeFileWriter.sha256(files.target.appendingPathComponent("A.jpg")), try SafeFileWriter.sha256(original))
    }
}
