import Foundation
import MCP

extension AppMCPTool {
    var maintenanceDescription: (String, String)? {
        switch self {
        case .getPreferences:
            ("Read the current theme, viewing mat, workspace layout and Develop preferences. The settings apply to this Phosdeck instance.", "preferences")
        case .setPreferences:
            ("Change only the supplied workspace preference fields. Panel sizes use the native point ranges. Agent sharing and connection controls remain in Settings.", "saved preferences and commit_state")
        case .showAppPanel:
            ("Open Settings, Task Results, copy import recovery, output records or camera diagnostics in Phosdeck. Use pane=shortcuts to show keyboard shortcuts.", "job_id, then the visible open_panel")
        case .listLanguagePacks:
            ("List installed community translations and the running and next-launch selections. The official language follows macOS.", "items, selected_pack_id, active_pack_id, active_language and restart_required")
        case .editLanguagePack:
            ("Import and select an authorized language bundle, or remove one installed pack by ID. Active translations change after reopening Phosdeck.", "job_id, then the affected pack and language state")
        case .selectLanguage:
            ("Select the official macOS language or an installed community pack for the next launch.", "job_id, then the selected pack, running language and restart_required")
        case .storageUsage:
            ("Measure the open catalog, thumbnail cache, task staging and recovery files. Returns the machine quota even without a catalog.", "catalog_session_id, byte counts, inaccessible_count and quota_gib")
        case .setCacheQuota:
            ("Set the native thumbnail quota in GiB. Applies to each catalog separately and saves the machine preference.", "job_id, then quota_gib and thumbnail_bytes")
        case .clearThumbnailCache:
            ("Clear rebuildable thumbnail data for the open catalog. Originals, catalog data and outputs are preserved.", "job_id, then removed_bytes and thumbnail_bytes at completion")
        case .backupCatalog:
            ("Write a verified SQLite backup of the current catalog to a catalog_backup_destination authorization. Backups exclude originals and rendered output files.", "job_id, then filename, publication and verification")
        case .restoreCatalogBackup:
            ("Restore an authorized catalog_backup_source into a new .phoscat file in a create_catalog authorization. Verify and open the new catalog.", "job_id, then publication, verification and the new catalog session")
        case .exportCatalogManifest:
            ("Write and verify the current catalog's JSON management manifest to a catalog_manifest_destination authorization. The file excludes access bookmarks.", "job_id, then filename, publication and verification")
        case .runCameraDiagnostics:
            ("Check the supported RAW files in an authorized camera_samples directory using the native diagnostics. Results are local evidence for the sampled files.", "job_id, then report_id, sample counts and paged per-file checks")
        case .getCameraDiagnosticPreview:
            ("Read a rendered or embedded sample PNG by report_id and sample_index when photo preview sharing is on.", "sample_index, preview kind, dimensions and an image/png block")
        case .saveCameraDiagnosticReport:
            ("Save the current camera report to a camera_report_destination authorization as verified JSON. The report excludes pixels, source paths and filenames.", "job_id, then report_id, filename and verification")
        default: nil
        }
    }
}

extension AppMCPWorkflows {
    func readStorageUsage() async throws -> MCPToolResult {
        let catalog = model.catalog, session = model.catalogSessionID
        let usage: StorageUsage
        let thumbnailBytes: Int64
        if let catalog {
            usage = try await StorageInspector().measure(catalog)
            thumbnailBytes = try await model.thumbnails.usage()
        } else {
            usage = StorageUsage()
            thumbnailBytes = 0
        }
        try Task.checkCancellation()
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        return .init("Measured Phosdeck storage.", data: [
            "catalog_session_id": session.map(Value.string) ?? .null,
            "catalog_bytes": .int(Int(usage.catalog)), "thumbnail_bytes": .int(Int(thumbnailBytes)),
            "staging_bytes": .int(Int(usage.staging)), "recovery_bytes": .int(Int(usage.recovery)),
            "inaccessible_count": .int(usage.inaccessible), "quota_gib": .int(model.cacheGigabytes)
        ], warning: usage.inaccessible > 0)
    }

    func changeCache(_ tool: AppMCPTool, args: Arguments) -> MCPToolResult {
        start(tool) { job in
            let quota = self.model.cacheGigabytes, bytes = self.model.cacheBytes
            self.running(job, phase: tool == .setCacheQuota ? "applying_cache_quota" : "clearing_thumbnail_cache")
            do {
                let removed = try await self.performCacheChange(quota: args["quota_gib"]?.intValue)
                job.data["quota_gib"] = .int(self.model.cacheGigabytes)
                job.data["thumbnail_bytes"] = .int(Int(self.model.cacheBytes))
                if let removed { job.data["removed_bytes"] = .int(Int(removed)) }
                let changed = tool == .clearThumbnailCache || quota != self.model.cacheGigabytes || bytes != self.model.cacheBytes
                job.finish(.succeeded, tool == .setCacheQuota ? "Applied the thumbnail quota." : "Cleared the thumbnail cache.",
                           committed: changed ? "committed" : "not_committed")
            } catch is CancellationError {
                job.data["quota_gib"] = .int(self.model.cacheGigabytes)
                job.finish(.cancelled, "Stopped cache maintenance.",
                           committed: quota != self.model.cacheGigabytes ? "committed" : "not_committed")
            } catch {
                let actual = try? await self.model.thumbnails.usage()
                self.model.error = error.localizedDescription
                job.data["quota_gib"] = .int(self.model.cacheGigabytes)
                job.data["thumbnail_bytes"] = actual.map { .int(Int($0)) } ?? .null
                if let actual { self.model.cacheBytes = actual }
                let changed = quota != self.model.cacheGigabytes
                job.finish(changed ? .partial : .failed, "Phosdeck could not finish cache maintenance.",
                           committed: changed ? "committed" : "unknown", error: "cache_maintenance_incomplete")
                job.data["follow_up"] = "Read get_storage_usage to check the current cache."
            }
        }
    }

    private func performCacheChange(quota: Int?) async throws -> Int64? {
        // Hand off the workspace lock to native cache maintenance before it first suspends.
        model.busy = false
        defer { model.busy = true }
        if let quota {
            try await model.updateCacheQuota(quota)
            return nil
        }
        return try await model.clearThumbnailCache()
    }

    func listLanguagePacks(_ args: Arguments) async throws -> MCPToolResult {
        let store = try makeLanguagePackStore()
        let worker = Task.detached { try store.installed().map(Self.languagePackRow) }
        let packs = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        var data = Self.page(packs, arguments: args)
        data.merge(Self.languageState(store)) { _, new in new }
        return .init("Read Phosdeck language choices.", data: data)
    }

    func changeLanguage(_ tool: AppMCPTool, args: Arguments) throws -> MCPToolResult {
        let store = try makeLanguagePackStore()
        let id = args["pack_id"]?.stringValue
        let action = args["action"]!.stringValue!
        let grant: Grant?
        if tool == .editLanguagePack, action == "import" {
            guard id == nil else { throw MCPToolProblem.invalid("Import a language bundle using access_id.") }
            grant = try self.grant(args["access_id"], purpose: .languagePack)
        } else {
            guard args["access_id"] == nil, (action == "official") == (id == nil) else {
                throw MCPToolProblem.invalid("Supply pack_id for an installed community pack.")
            }
            grant = nil
        }
        return start(tool) { job in
            let before = Self.languageState(store)
            let activeID = L10n.current.pack?.id
            self.running(job, phase: "applying_language_choice")
            let worker = Task.detached { () throws -> Value? in
                try Task.checkCancellation()
                switch action {
                case "import":
                    guard let grant else { throw Self.accessExpired }
                    defer { withExtendedLifetime(grant) {} }
                    let pack = try store.install(from: grant.url)
                    store.defaults.set(pack.id, forKey: LanguagePackStore.selectionKey)
                    return Self.languagePackRow(pack)
                case "remove":
                    let pack = try store.read(id: id!)
                    try store.remove(id: pack.id, activeID: activeID)
                    return Self.languagePackRow(pack)
                default:
                    try store.select(id: id)
                    return nil
                }
            }
            let affected: Value?
            do { affected = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
            catch is CancellationError { throw CancellationError() }
            catch {
                self.model.error = error.localizedDescription
                throw MCPToolProblem(code: action == "import" ? "language_pack_invalid" : "language_pack_unavailable",
                                     summary: "Phosdeck could not apply the requested language bundle.",
                                     next: "Check the bundle or refresh list_language_packs.")
            }
            let after = Self.languageState(store)
            job.data.merge(after) { _, new in new }
            job.data["pack"] = affected ?? .null
            if affected != nil { NotificationCenter.default.post(name: LanguagePackStore.installedPacksChanged, object: nil) }
            job.finish(.succeeded, "Saved the language choice for the next launch.",
                       committed: affected != nil || before != after ? "committed" : "not_committed")
        }
    }

    nonisolated private static func languagePackRow(_ pack: LanguagePack) -> Value {
        ["pack_id": .string(pack.id), "identifier": .string(pack.identifier), "language": .string(pack.language),
         "name": .string(pack.name), "author": .string(pack.author), "version": .string(pack.version),
         "translated_count": .int(pack.keys.count)]
    }

    private static func languageState(_ store: LanguagePackStore) -> Arguments {
        let selected = store.defaults.string(forKey: LanguagePackStore.selectionKey) ?? ""
        let active = L10n.current.pack
        return ["selected_pack_id": selected.isEmpty ? .null : .string(selected),
                "active_pack_id": active.map { .string($0.id) } ?? .null,
                "active_language": .string(active?.language ?? L10n.current.language),
                "official_languages": ["en", "zh-Hans"], "load_failed": .bool(L10n.current.loadFailed),
                "restart_required": .bool(selected != (active?.id ?? ""))]
    }

    func writeCatalogOutput(_ tool: AppMCPTool, args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let manifest = tool == .exportCatalogManifest
        let grant = try self.grant(args["destination_access_id"], purpose: manifest ? .catalogManifestDestination : .catalogBackupDestination)
        let ext = manifest ? "json" : "sqlite"
        let filename = args["filename"]?.stringValue ?? "Phosdeck-\(UUID().uuidString.prefix(8)).\(ext)"
        guard Self.validCatalogOutputName(filename, extension: ext) else {
            throw MCPToolProblem.invalid("Use a new filename ending in .\(ext), without a folder path.")
        }
        return start(tool) { job in
            job.data.merge(["filename": .string(filename), "published": false, "verified": false]) { _, new in new }
            self.running(job, phase: manifest ? "writing_catalog_manifest" : "backing_up_catalog")
            let worker = Task.detached { () throws -> (URL, Result<Int64, Error>) in
                defer { withExtendedLifetime(grant) {} }
                let folder = grant.url.resolvingSymlinksInPath().standardizedFileURL
                let destination = folder.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: destination.path) { throw MCPToolProblem.outputConflict }
                if manifest {
                    let data = try catalog.exportManifest(to: destination)
                    return (destination, Result {
                        let identity = try FileIdentity.read(destination)
                        guard try Data(contentsOf: destination) == data, try FileIdentity.read(destination) == identity else {
                            throw Self.catalogOutputVerification
                        }
                        return identity.size
                    })
                }
                let identity = try catalog.backup(to: destination)
                return (destination, Result { try CatalogStore.verifyBackup(destination, identity: identity); return identity.size })
            }
            let (destination, verification) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            job.data["published"] = true
            job.data["destination_name"] = .string(destination.deletingLastPathComponent().lastPathComponent)
            switch verification {
            case .success(let bytes):
                job.data["verified"] = true
                job.data["bytes"] = .int(Int(bytes))
                job.finish(.succeeded, manifest ? "Wrote and verified the catalog manifest." : "Wrote and verified the catalog backup.",
                           committed: "committed")
            case .failure(let error):
                self.model.error = error.localizedDescription
                job.data["follow_up"] = "Inspect the preserved output in the selected folder before retrying."
                job.finish(.partial, "The catalog output was published and needs verification.",
                           committed: "committed", error: "catalog_output_verification_failed")
            }
        }
    }

    func restoreCatalogBackup(_ args: Arguments) throws -> MCPToolResult {
        let source = try grant(args["source_access_id"], purpose: .catalogBackupSource)
        let target = try grant(args["destination_access_id"], purpose: .createCatalog)
        let filename = try AppModel.catalogFilename(args["name"]!.stringValue!)
        guard Self.validCatalogOutputName(filename, extension: CatalogFile.pathExtension) else {
            throw MCPToolProblem.invalid("Use a valid new catalog name.")
        }
        guard let expectedSource = source.identity else { throw Self.accessExpired }
        return start(.restoreCatalogBackup) { job in
            job.data.merge(["filename": .string(filename), "published": false, "verified": false, "opened": false]) { _, new in new }
            self.running(job, phase: "restoring_catalog_backup")
            let worker = Task.detached {
                defer { withExtendedLifetime((source, target)) {} }
                let directory = target.url.resolvingSymlinksInPath().standardizedFileURL
                let url = directory.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: url.path) { throw Self.catalogExists }
                guard (try? FileIdentity.read(source.url)) == expectedSource else { throw Self.accessExpired }
                let bookmark = try AccessLease.bookmark(target.url, readOnly: false)
                let identity = try CatalogStore.publishRestoredBackup(from: source.url, to: url, expectedSource: expectedSource)
                return (url, identity, bookmark)
            }
            let (url, identity, bookmark) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            job.data["published"] = true
            job.data["bytes"] = .int(Int(identity.size))
            job.data["destination_name"] = .string(url.deletingLastPathComponent().lastPathComponent)
            job.data["commit_state"] = "committed"
            do {
                // After exclusive publication, finish checking the new file even if cancellation was requested.
                let next = try await Task.detached {
                    guard try FileIdentity.read(url) == identity else { throw Self.catalogOutputVerification }
                    let next = try CatalogStore(fileURL: url, access: target.lease)
                    guard try FileIdentity.read(url) == identity else { throw Self.catalogOutputVerification }
                    return next
                }.value
                job.data["verified"] = true
                try await self.activate(job) {
                    try self.model.activateCreatedCatalog(next, directory: target.url, bookmark: bookmark)
                }
                job.data["opened"] = true
                job.finish(.succeeded, "Restored, verified and opened the new catalog.", committed: "committed")
            } catch {
                self.model.error = error.localizedDescription
                job.data["opened"] = .bool(self.model.catalog?.fileURL.path == url.path)
                job.data["follow_up"] = "The restored file was preserved. Check it in the selected folder before opening or restoring again."
                job.finish(.partial, "The restored catalog was published and needs review.",
                           committed: "committed", error: "catalog_restore_incomplete")
            }
        }
    }

    nonisolated private static func validCatalogOutputName(_ name: String, extension ext: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return name == url.lastPathComponent && !name.hasPrefix(".") && !name.contains(":") &&
            name.rangeOfCharacter(from: .controlCharacters) == nil && name.utf8.count <= 240 && url.pathExtension.lowercased() == ext
    }

    nonisolated private static let catalogOutputVerification = MCPToolProblem(
        code: "catalog_output_verification_failed", summary: "The published file did not match on readback.",
        next: "Inspect the published file in the authorized folder."
    )
}
