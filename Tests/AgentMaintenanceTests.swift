import CoreImage
import GRDB
import ImageIO
import MCP
import UniformTypeIdentifiers
import XCTest
@testable import Phosdeck

@MainActor
final class AgentMaintenanceTests: XCTestCase {
    private typealias Fields = [String: Value]

    @MainActor private final class Client {
        let model: AppModel
        private(set) lazy var tools = AppMCPTools(model: model, appName: "Phosdeck Test", version: "1",
            bundleID: "test", sharesImages: false, chooseFile: { [weak self] _ in self?.choice })
        var choice: URL?

        init(_ model: AppModel? = nil) { self.model = model ?? AppModel() }

        func call(_ tool: AppMCPTool, _ args: Fields = [:]) async -> Fields {
            var arguments = args
            if tool.needsRequestID || tool.needsCatalog || tool.optional.contains(.catalog) {
                let state = Self.data(await tools.call(.init(name: AppMCPTool.workspace.rawValue)))
                if tool.needsCatalog || tool.optional.contains(.catalog), state["catalog_session_id"] != .null {
                    arguments["catalog_session_id"] = arguments["catalog_session_id"] ?? state["catalog_session_id"]
                }
                if tool.needsRequestID {
                    arguments["request_epoch"] = state["request_epoch"]
                    arguments["request_id"] = arguments["request_id"] ?? .string(UUID().uuidString)
                }
            }
            return Self.data(await tools.call(.init(name: tool.rawValue, arguments: arguments)))
        }

        private static func data(_ response: CallTool.Result) -> Fields {
            let payload = response.structuredContent?.objectValue ?? [:]
            var fields = payload["data"]?.objectValue ?? [:]
            fields["tool_error"] = payload["error"]?.objectValue?["code"]
            fields["image"] = .bool(response.content.contains {
                if case .image = $0 { return true }
                return false
            })
            return fields
        }

        func finish(_ tool: AppMCPTool, _ args: Fields) async throws -> Fields {
            let accepted = await call(tool, args)
            let id = try XCTUnwrap(accepted["job_id"], "\(accepted)")
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            repeat {
                let job = await call(.job, ["job_id": id])
                if job["phase"] == "finished" { return job }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            throw LRCError("The maintenance job did not finish.")
        }

        func access(_ purpose: MCPFilePurpose, _ url: URL) async throws -> Value {
            choice = url
            let job = try await finish(.fileAccess, ["purpose": .string(purpose.rawValue)])
            XCTAssertEqual(job["state"], "succeeded", "\(job)")
            return try XCTUnwrap(job["access_id"])
        }
    }

    private func defaults() throws -> UserDefaults {
        let suite = "phosdeck-agent-maintenance-" + UUID().uuidString
        let result = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { result.removePersistentDomain(forName: suite) }
        return result
    }

    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-agent-maintenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func image() throws -> CGImage {
        let input = CIImage(color: CIColor(red: 0.4, green: 0.7, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24))
        return try XCTUnwrap(CIContext().createCGImage(input, from: input.extent))
    }

    private func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }

    private func succeeded(_ job: Fields, line: UInt = #line) -> Fields {
        XCTAssertEqual(job["state"], "succeeded", "\(job)", line: line)
        return job
    }

    func testPreferencesPatchUsesNativeBoundsAndSurvivesModelRecreation() async throws {
        let defaults = try defaults()
        let client = Client(AppModel(workspacePreferences: defaults))
        let rejected = await client.call(.setPreferences, ["preferences": ["left_panel_width": 281, "theme": "ivory"]])
        XCTAssertEqual(rejected["tool_error"], "invalid_arguments")
        XCTAssertNil(defaults.string(forKey: "chromeTheme"))
        let sharing = await client.call(.setPreferences, ["preferences": ["share_photo_previews": true]])
        XCTAssertEqual(sharing["tool_error"], "invalid_arguments")
        let changes: Value = [
            "theme": "ivory", "photo_mat": "white", "show_left_panel": false, "right_panel_width": 362,
            "filmstrip_height": 103, "history_open": false, "develop_solo_mode": true, "thumbnail_size": 184,
            "auto_advance": true, "library_filters_open": false, "develop_groups": ["curves": true]
        ]
        let saved = await client.call(.setPreferences, ["preferences": changes])
        XCTAssertEqual(saved["commit_state"], "committed")
        XCTAssertEqual(defaults.string(forKey: "chromeTheme"), "ivory")
        XCTAssertEqual(defaults.double(forKey: "workspaceRightWidth"), 362)
        XCTAssertTrue(defaults.bool(forKey: "developCurvesOpen"))
        XCTAssertFalse(defaults.bool(forKey: "developBasicOpen"))
        let ambiguous = await client.call(.setPreferences, [
            "preferences": ["theme": "graphite", "develop_groups": ["curves": true, "grain": true]]
        ])
        XCTAssertEqual(ambiguous["tool_error"], "invalid_arguments")
        XCTAssertEqual(defaults.string(forKey: "chromeTheme"), "ivory")
        let next = Client(AppModel(workspacePreferences: defaults))
        let readback = await next.call(.getPreferences)
        XCTAssertEqual(saved["preferences"], readback["preferences"])
        XCTAssertEqual(next.model.thumbnailSize, 184)
        XCTAssertTrue(next.model.autoAdvance)
        XCTAssertFalse(next.model.libraryFiltersOpen)
        let recovery = await next.call(.showAppPanel, ["panel": "output_recovery"])
        XCTAssertEqual(recovery["tool_error"], "no_catalog")
    }

    func testCommunityLanguageUsesNativeBundleValidationAndNextLaunchSelection() async throws {
        let folder = try directory(), defaults = try defaults()
        let store = try LanguagePackStore(directory: folder.appendingPathComponent("installed"), defaults: defaults)
        let source = folder.appendingPathComponent("Synthetic.bundle")
        let resources = source.appendingPathComponent("Contents/Resources/ru.lproj")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleIdentifier": "org.example.synthetic-translation",
            "CFBundleDevelopmentRegion": "ru", "CFBundleVersion": "1", "OMLRCFormatVersion": 1,
            "OMLRCPackIdentifier": "org.example.russian", "OMLRCLanguage": "ru", "OMLRCName": "Русский", "OMLRCAuthor": "Test"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["app.importPhotos": "Импорт фотографий…"], format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("Localizable.strings"))
        let client = Client()
        client.tools.workflows.makeLanguagePackStore = { store }
        let access = try await client.access(.languagePack, source)
        let imported = succeeded(try await client.finish(.editLanguagePack, ["action": "import", "access_id": access]))
        let id = try XCTUnwrap(imported["selected_pack_id"])
        XCTAssertEqual(imported["restart_required"], true)
        XCTAssertEqual(imported["active_pack_id"], .null)
        XCTAssertEqual(L10n.load(store).pack?.id, id.stringValue)
        let listed = await client.call(.listLanguagePacks)
        XCTAssertEqual(listed["items"]?.arrayValue?.first?.objectValue?["pack_id"], id)
        let official = succeeded(try await client.finish(.selectLanguage, ["action": "official"]))
        XCTAssertEqual(official["restart_required"], false)
        _ = succeeded(try await client.finish(.selectLanguage, ["action": "community", "pack_id": id]))
        _ = succeeded(try await client.finish(.editLanguagePack, ["action": "remove", "pack_id": id]))
        XCTAssertTrue(try store.installed().isEmpty)
        XCTAssertNil(L10n.load(store).pack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private actor RenderGate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var render: CheckedContinuation<Void, Never>?

        func block() async {
            await withCheckedContinuation { continuation in
                render = continuation
                waiting?.resume()
                waiting = nil
            }
        }
        func waitForRender() async {
            if render == nil { await withCheckedContinuation { waiting = $0 } }
        }
        func resume() { render?.resume(); render = nil }
    }

    func testCacheMaintenanceClearsOnlyThumbnailsAndDiscardsInFlightRendering() async throws {
        let folder = try directory(), defaults = try defaults(), image = try image()
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        let catalog = try CatalogStore(fileURL: folder.appendingPathComponent("Synthetic.phoscat"), create: true)
        let root = try catalog.addRoot(url: sources, bookmark: AccessLease.bookmark(sources, readOnly: true))
        let jpg = sources.appendingPathComponent("cached.jpg"), png = sources.appendingPathComponent("pending.png")
        try writeImage(image, to: jpg, type: .jpeg)
        try writeImage(image, to: png, type: .png)
        let cached = try ReferenceImporter.inspect(url: jpg, root: root, rootURL: sources)
        let pending = try ReferenceImporter.inspect(url: png, root: root, rootURL: sources)
        try catalog.index(cached); try catalog.index(pending)
        let sourceHash = try SafeFileWriter.sha256(png), gate = RenderGate()
        let thumbnails = ThumbnailService(renderer: { _, _ in await gate.block(); return image })
        let model = AppModel(cachePreferences: defaults, thumbnails: thumbnails)
        model.catalog = catalog
        let client = Client(model)
        let quota = succeeded(try await client.finish(.setCacheQuota, ["quota_gib": 1]))
        XCTAssertEqual(quota["quota_gib"], 1)
        XCTAssertEqual(AppModel(cachePreferences: defaults).cacheGigabytes, 1)
        _ = try await thumbnails.image(photo: cached, root: root)
        let before = await client.call(.storageUsage)
        XCTAssertGreaterThan(before["catalog_bytes"]?.intValue ?? 0, 0)
        XCTAssertGreaterThan(before["thumbnail_bytes"]?.intValue ?? 0, 0)
        let request = Task { try await thumbnails.image(photo: pending, root: root) }
        await gate.waitForRender()
        let clear: Result<Fields, Error>
        do { clear = .success(try await client.finish(.clearThumbnailCache, [:])) }
        catch { clear = .failure(error) }
        await gate.resume()
        let cleared = succeeded(try clear.get())
        XCTAssertEqual(cleared["removed_bytes"], before["thumbnail_bytes"])
        do { _ = try await request.value; XCTFail("A cleared thumbnail generation must not be delivered") }
        catch is CancellationError {}
        let after = await client.call(.storageUsage)
        XCTAssertEqual(after["thumbnail_bytes"], 0)
        XCTAssertEqual(after["catalog_bytes"], before["catalog_bytes"])
        XCTAssertEqual(try catalog.photoCount(), 2)
        XCTAssertEqual(try SafeFileWriter.sha256(png), sourceHash)
    }

    func testCatalogBackupManifestAndExclusiveRestoreToNewSession() async throws {
        let folder = try directory()
        let model = AppModel()
        let original = try CatalogStore(fileURL: folder.appendingPathComponent("Synthetic.phoscat"), create: true)
        try original.collection(name: "Before backup", id: "before")
        model.catalog = original
        let client = Client(model)
        let initialSession = try XCTUnwrap(model.catalogSessionID)
        let backupAccess = try await client.access(.catalogBackupDestination, folder)
        let backupArgs: Fields = ["destination_access_id": backupAccess, "filename": "snapshot.sqlite"]
        let backup = succeeded(try await client.finish(.backupCatalog, backupArgs))
        XCTAssertEqual(backup["verified"], true)
        let backupURL = folder.appendingPathComponent("snapshot.sqlite")
        let backupDigest = try SafeFileWriter.sha256(backupURL)
        let conflict = try await client.finish(.backupCatalog, backupArgs)
        XCTAssertEqual(conflict["error_code"], "output_conflict")
        XCTAssertEqual(try SafeFileWriter.sha256(backupURL), backupDigest)
        let manifestAccess = try await client.access(.catalogManifestDestination, folder)
        let manifest = succeeded(try await client.finish(.exportCatalogManifest, ["destination_access_id": manifestAccess, "filename": "management.json"]))
        XCTAssertEqual(manifest["verified"], true)
        let data = try Data(contentsOf: folder.appendingPathComponent("management.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("bookmark"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["collections"] as? [[String: String]])?.first?["id"], "before")

        try original.collection(name: "Added later", id: "after")
        let originalDigest = try SafeFileWriter.sha256(original.fileURL)
        let source = try await client.access(.catalogBackupSource, backupURL)
        let destination = try await client.access(.createCatalog, folder)
        let refused = try await client.finish(.restoreCatalogBackup, ["source_access_id": source, "destination_access_id": destination, "name": "Synthetic"])
        XCTAssertEqual(refused["error_code"], "catalog_exists")
        XCTAssertTrue(model.catalog === original)
        let restored = succeeded(try await client.finish(.restoreCatalogBackup, ["source_access_id": source, "destination_access_id": destination, "name": "Restored"]))
        XCTAssertEqual(restored["published"], true)
        XCTAssertEqual(restored["verified"], true)
        XCTAssertEqual(restored["opened"], true)
        XCTAssertEqual(restored["catalog_session_id"]?.stringValue, model.catalogSessionID)
        XCTAssertNotEqual(model.catalogSessionID, initialSession)
        let working = try XCTUnwrap(model.catalog)
        XCTAssertEqual(working.fileURL.lastPathComponent, "Restored.phoscat")
        XCTAssertEqual(try working.collections().map(\.id), ["before"])
        func namespace(_ catalog: CatalogStore) throws -> String? {
            try catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM catalogMeta") }
        }
        XCTAssertNotEqual(try namespace(working), try namespace(original))
        XCTAssertEqual(try SafeFileWriter.sha256(original.fileURL), originalDigest)
        XCTAssertEqual(try SafeFileWriter.sha256(backupURL), backupDigest)
    }

    func testCameraReportWithoutCatalogPreservesFailureAndOmitsSourceNames() async throws {
        let folder = try directory(), client = Client()
        let sample = folder.appendingPathComponent("synthetic-corrupt.ARW")
        try Data([0, 1, 2]).write(to: sample)
        let access = try await client.access(.cameraSamples, folder)
        let result = succeeded(try await client.finish(.runCameraDiagnostics, ["access_id": access]))
        XCTAssertEqual(result["checked_count"], 1)
        XCTAssertEqual(result["completed"], true)
        let row = try XCTUnwrap(result["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(row["outcome"], "failed")
        let id = try XCTUnwrap(result["report_id"])
        let preview: Fields = ["report_id": id, "sample_index": 1]
        let gated = await client.call(.getCameraDiagnosticPreview, preview)
        XCTAssertEqual(gated["tool_error"], "image_access_disabled")
        client.tools.setSharesImages(true)
        let missing = await client.call(.getCameraDiagnosticPreview, preview)
        XCTAssertEqual(missing["tool_error"], "diagnostic_preview_unavailable")
        let output = try await client.access(.cameraReportDestination, folder)
        let saved = succeeded(try await client.finish(.saveCameraDiagnosticReport, ["report_id": id, "destination_access_id": output]))
        XCTAssertEqual(saved["verified"], true)
        let filename = try XCTUnwrap(saved["filename"]?.stringValue)
        let contents = try Data(contentsOf: folder.appendingPathComponent(filename))
        let report = try JSONDecoder().decode(CameraDiagnosticReport.self, from: contents)
        XCTAssertEqual(report.photos.map(\.outcome), [.failed])
        XCTAssertFalse(String(decoding: contents, as: UTF8.self).contains(sample.lastPathComponent))
        XCTAssertFalse(String(decoding: contents, as: UTF8.self).contains(folder.path))
        XCTAssertEqual(try Data(contentsOf: sample), Data([0, 1, 2]))
    }

    func testCameraPreviewReturnsPNGForTheAuthorizedPublicRAW() async throws {
        let raw = try MoreRAWTests.sample("a7iii_12bit_compressed.ARW")
        let folder = try directory(), client = Client()
        try FileManager.default.copyItem(at: raw, to: folder.appendingPathComponent("public-test.ARW"))
        let access = try await client.access(.cameraSamples, folder)
        let report = succeeded(try await client.finish(.runCameraDiagnostics, ["access_id": access]))
        XCTAssertEqual(report["checked_count"], 1)
        let first = try XCTUnwrap(report["items"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(first["rendered_preview_available"], true)
        client.tools.setSharesImages(true)
        let preview = await client.call(.getCameraDiagnosticPreview, ["report_id": try XCTUnwrap(report["report_id"]), "sample_index": 1])
        XCTAssertEqual(preview["image"], true)
        XCTAssertEqual(max(preview["width"]?.intValue ?? 0, preview["height"]?.intValue ?? 0), 256)
    }
}
