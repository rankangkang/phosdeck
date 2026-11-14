import AppKit
import MCP
import UniformTypeIdentifiers

enum MCPFilePurpose: String, CaseIterable {
    case createCatalog = "create_catalog", openCatalog = "open_catalog"
    case importSource = "import_source", importDestination = "import_destination"
    case relocateRoot = "relocate_root", locateOriginal = "locate_original", restoreBackup = "restore_import_backup"
    case xmpPresets = "xmp_presets"
    case mergeDestination = "merge_destination", exportDestination = "export_destination"
    case languagePack = "language_pack"
    case catalogBackupDestination = "catalog_backup_destination", catalogBackupSource = "catalog_backup_source"
    case catalogManifestDestination = "catalog_manifest_destination"
    case cameraSamples = "camera_samples", cameraReportDestination = "camera_report_destination"

    var needsCatalog: Bool {
        ![.createCatalog, .openCatalog, .languagePack, .catalogBackupSource, .cameraSamples, .cameraReportDestination].contains(self)
    }

    @MainActor func panel() -> NSOpenPanel {
        switch self {
        case .openCatalog: return AppModel.catalogFilePanel()
        case .locateOriginal: return AppModel.originalFilePanel()
        case .createCatalog: return AppModel.directoryPanel(title: L10n.text("app.chooseWhereToSaveTheCatalogFile", defaultValue: "Choose Where to Save the Catalog File"))
        case .importSource: return AppModel.directoryPanel(title: L10n.text("app.chooseImportSource", defaultValue: "Choose Import Source"))
        case .importDestination: return AppModel.directoryPanel(title: L10n.text("app.chooseCopyDestination", defaultValue: "Choose Copy Destination"))
        case .relocateRoot: return AppModel.directoryPanel(title: L10n.text("agent.relocateRoot", defaultValue: "Authorize the New Location of the Library Folder"))
        case .restoreBackup: return AppModel.directoryPanel(title: L10n.text("agent.restoreBackup", defaultValue: "Choose a Folder for the Recovered File"))
        case .mergeDestination: return AppModel.directoryPanel(title: L10n.text("merge.chooseDestination", defaultValue: "Choose Destination…"))
        case .exportDestination: return AppModel.directoryPanel(title: L10n.text("app.chooseOutputDestination", defaultValue: "Choose Output Destination"))
        case .languagePack: return LanguagePackSettings.makeOpenPanel()
        case .catalogBackupSource: return AppModel.catalogBackupPanel()
        case .catalogBackupDestination:
            return AppModel.directoryPanel(title: L10n.text("app.backUpCatalogExcludesOriginalPhotosAndOutputs", defaultValue: "Back Up Catalog (excludes original photos and outputs)"))
        case .catalogManifestDestination:
            return AppModel.directoryPanel(title: L10n.text("app.exportManagementManifestExcludesAccessBookmarks", defaultValue: "Export management manifest (excludes access bookmarks)"))
        case .cameraSamples:
            return AppModel.directoryPanel(title: L10n.text("camera.choose", defaultValue: "Choose Sample Folder…"))
        case .cameraReportDestination:
            return AppModel.directoryPanel(title: L10n.text("camera.save", defaultValue: "Save Local Report…"))
        case .xmpPresets:
            let panel = NSOpenPanel()
            panel.title = L10n.text("app.chooseXMPFiles", defaultValue: "Choose XMP Files…")
            panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
            panel.allowsMultipleSelection = true
            return panel
        }
    }
}

extension AppMCPTool {
    var workflowDescription: (String, String) {
        switch self {
        case .librarySources:
            ("List catalog roots, indexed subfolders, collections and special sources. Use the returned root_id and folder_id for folder jobs.", "items, total, next_offset")
        case .recentCatalogs:
            ("List recent catalogs with opaque IDs and file availability.", "items with recent_catalog_id, name, available and is_current")
        case .fileAccess:
            ("Ask the user to select a file or folder in Phosdeck for the given purpose. Poll get_job for the access_id. For a catalog file, macOS may also ask for its parent folder.", "job_id, state, user_action and eventually access_id and name")
        case .createCatalog:
            ("Create and activate a new catalog using a create_catalog access_id and a catalog name. Existing files are preserved.", "job_id and then catalog_session_id, catalog_name and commit_state")
        case .openCatalog:
            ("Switch catalogs using exactly one recent_catalog_id or open_catalog access_id. A legacy extension requires the user's choice in Phosdeck.", "job_id and then catalog_session_id, catalog_name and commit_state")
        case .relocateRoot:
            ("Verify original identities at a new directory selected with relocate_root access. Preserve all relative paths and edits.", "job_id and then root_id, unverified_count, items and commit_state")
        case .locateOriginal:
            ("Relink the explicit saved photo version to a file selected with locate_original access. Verifies the source revision and original identity.", "job_id and then photo_id, source_id, root_id and commit_state")
        case .planImport:
            ("Preview a reference or copy import with import_source access. Copy requires import_destination access and supports date layout, sidecars and a conflict policy (default ask). To refine candidates or map attachments to copy groups, pass base_plan_id and use IDs from its results.", "job_id and then plan_id, candidate, group and attachment items")
        case .startImport:
            ("Run a frozen import plan. Pass candidate_ids for reference photos or copy groups, or select_all=true to run all eligible items. Poll the job and resolve any filename conflict.", "job_id and then per-item results, photo IDs, optional record_id and commit_state")
        case .resolveConflict:
            ("Answer the current copy conflict by job_id and conflict_id with skip, uniqueName or overwrite. Explicitly say whether to apply the policy to remaining conflicts. Only policies reported by get_job are available.", "job_id, state and cancel_requested")
        case .recentImport:
            ("Show the recent import, start culling it, or return to the previous browse position. Read get_workspace for the complete resulting query.", "source_id, result_count, active_photo_id, selection_count")
        case .scanFolder:
            ("Scan an indexed root or one of its listed folders directly, indexing available photos. Use plan_folder_review to inspect changes before applying them.", "job_id and then per-file results and commit_state")
        case .planFolder:
            ("Check a root or listed subfolder for new, missing, changed or moved photos without saving changes. include_subfolders defaults to true.", "job_id and then plan_id, checked_count and difference items")
        case .applyFolder:
            ("Apply only the explicit difference_ids from a folder review plan. For ambiguous moves map difference IDs to the returned location IDs. Phosdeck revalidates and commits the selected batch together.", "job_id and then applied_count, relinked, marked, photo items and commit_state")
        case .importRecords:
            ("List saved copy-import journals in the open catalog. Use a record_id with get_job for individual groups and files, or resume_photo_import for unfinished work.", "items, total, next_offset")
        case .resumeImport:
            ("Verify and continue unfinished work in a saved copy-import record.", "job_id, record_id and then file, catalog and recovery results")
        case .restoreBackup:
            ("Restore the specified import backup to an authorized restore_import_backup folder using a new filename. Existing files are preserved.", "job_id and then record_id, member_id, name, publication and commit_state")
        case .cleanBackup:
            ("Ask the user in Phosdeck to permanently remove a verified previous file from a completed copy import.", "job_id and then record_id, member_id, recovery_state and commit_state")
        case .job:
            ("Read a job by job_id, or a durable copy import by its record_id. Page individual results with next_offset. Follow user_action or conflict while waiting and check commit_state at completion.", "job_id, state, phase, progress, cancel_requested, results, items, next_offset")
        case .cancelJob:
            ("Request cancellation of an Agent job in Phosdeck. Poll get_job for its final state and any results already saved.", "job_id, state and cancel_requested")
        case .revealFile:
            ("Reveal the current catalog or explicit export records, a merge master, or an import backup in Finder. Use record_ids for export, file_id or photo_id for merge, and record_id and member_id for import_backup.", "job_id, then revealed and unavailable counts")
        default: preconditionFailure("Use the core tool description.")
        }
    }
}

@MainActor
final class AppMCPWorkflows {
    typealias FilePicker = @MainActor (NSOpenPanel) async -> URL?
    typealias Arguments = [String: Value]

    final class Job {
        enum State: String {
            case queued, running, waiting = "waiting_for_user", succeeded, partial = "partially_succeeded", failed, cancelled
        }
        let id = UUID().uuidString
        let tool: AppMCPTool
        let session: String?
        var state = State.queued
        var phase = "queued"
        var action: String?
        var data: Arguments = ["commit_state": "not_committed"]
        var items: [Value] = []
        var summary = "Phosdeck accepted the job."
        var errorCode: String?
        var cancelRequested = false
        var onCancel: (() -> Void)?
        var outputObservations: [String: ExportObservation] = [:]
        var progress: TaskProgress?
        var conflictReplies: [String: ImportConflictDecision] = [:]

        init(tool: AppMCPTool, session: String?) { self.tool = tool; self.session = session }

        func finish(_ state: State, _ summary: String, committed: String = "not_committed", error: String? = nil) {
            self.state = state
            self.summary = summary
            errorCode = error
            phase = "finished"
            action = nil
            data["commit_state"] = .string(committed)
        }
    }

    struct Grant {
        let purpose: MCPFilePurpose
        let lease: AccessLease
        var directory: AccessLease?
        var identity: FileIdentity?
        var additionalFiles: [AccessLease] = []
        var url: URL { lease.url }
    }

    unowned let model: AppModel
    private let chooseFile: FilePicker?
    private var jobs: [Job] = []
    private(set) var activeJob: Job?
    var cullingJob: Job?
    var cullingTask: Task<Void, Never>?
    lazy var cullingPipeline = ImagePipeline(qualityCacheLimit: 0)
    var cullingCache = NSCache<NSString, MCPCullingReport.CachedMetrics>()
    private var cancelPanel: (() -> Void)?
    private var grants: [String: Grant] = [:]
    private var recentIDs: [String: String] = [:]
    var importPlans: [String: MCPImportPlan] = [:]
    var folderPlans: [String: MCPFolderPlan] = [:]
    var stackPlans: [String: MCPAutoStackPlan] = [:]
    var pairPlans: [String: MCPPairPlan] = [:]
    var xmpPlans: [String: [XMPPresetImportItem]] = [:]
    var adjustmentPlans: [String: MCPAdjustmentBatch] = [:]
    var mergePlans: [String: MCPMergePlan] = [:]
    var mergePreview: MCPPreparedMerge?
    var mergeFiles: [String: MCPPublishedMerge] = [:]
    var makeMergeEngine: () -> PhotoMergeEngine = { PhotoMergeEngine() }
    var exportPlans: [String: MCPExportPlan] = [:]
    var exportDefaults: UserDefaults = .standard
    lazy var outputPreviewPipeline = ImagePipeline(qualityCacheLimit: 0)
    var makeExportService: (ImagePipeline) -> ExportService = { ExportService(pipeline: $0) }
    var activateFilesInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var makeLanguagePackStore: () throws -> LanguagePackStore = { try LanguagePackStore() }
    var cameraReport: MCPCameraReport?
    private var activeReads = 0

    init(model: AppModel, chooseFile: FilePicker?) {
        self.model = model
        self.chooseFile = chooseFile
    }

    var isWorking: Bool { activeJob != nil }
    var waitingForConflict: Bool {
        guard let job = activeJob, [.startImport, .resumeImport].contains(job.tool), !job.cancelRequested else { return false }
        return model.importConflict != nil
    }
    var currentJob: Value {
        guard let job = activeJob ?? cullingJob else { return .null }
        return ["job_id": .string(job.id), "state": .string(state(of: job).rawValue), "operation": .string(job.tool.rawValue)]
    }

    func catalogChanged() {
        let current = model.catalogSessionID
        if let cullingJob, cullingJob.session != current { cancel(cullingJob) }
        cullingCache.removeAllObjects()
        mergePreview = nil
        for job in jobs where job.session != current {
            grants[job.id] = nil
            importPlans[job.id] = nil
            folderPlans[job.id] = nil
            stackPlans[job.id] = nil
            pairPlans[job.id] = nil
            xmpPlans[job.id] = nil
            adjustmentPlans[job.id] = nil
            mergePlans[job.id] = nil
            mergeFiles[job.id] = nil
            exportPlans[job.id] = nil
        }
    }

    func stop() -> Task<Void, Never>? {
        if let cullingJob { cancel(cullingJob) }
        guard let job = activeJob else { return cullingTask }
        cancel(job)
        guard let analysis = cullingTask else { return model.task }
        let foreground = model.task
        return Task { await foreground?.value; await analysis.value }
    }

    func read(_ tool: AppMCPTool, arguments: Arguments, draft: MCPPhotoDraft? = nil) async throws -> MCPToolResult {
        if tool == .job, let job = jobs.first(where: { $0.id == arguments["job_id"]?.stringValue }) {
            if job.tool == .cullPhotos, job.session != model.catalogSessionID { throw MCPToolProblem.catalogChanged }
            return result(job, arguments: arguments)
        }
        guard activeReads < 2 else { throw MCPToolProblem.busy }
        activeReads += 1
        defer { activeReads -= 1 }
        let session = model.catalogSessionID
        switch tool {
        case .recentCatalogs: return await recentCatalogs()
        case .librarySources:
            return try await librarySources(catalog: model.catalog!, session: session!, arguments: arguments)
        case .keywords:
            return try await listKeywords(catalog: model.catalog!, session: session!, arguments: arguments)
        case .getCollection, .listVersions, .listEditRecords, .listStacks, .listPairs:
            return try await readOrganization(tool, catalog: model.catalog!, session: session!, args: arguments)
        case .photoRecipe:
            return try await readRecipe(arguments, catalog: model.catalog!, session: session!, draft: draft)
        case .listPresets:
            return try await listPresets(arguments, catalog: model.catalog!, session: session!)
        case .getMergePreview:
            return try await readMergePreview(arguments, catalog: model.catalog!)
        case .listExportPresets:
            return try listExportPresets(arguments)
        case .getExportPreview:
            return try await readExportPreview(arguments, catalog: model.catalog!)
        case .exportRecords:
            return try await readExportRecords(arguments, catalog: model.catalog!)
        case .getPreferences:
            return .init("Read Phosdeck preferences.", data: ["preferences": .object(MCPPreferences.read(model))])
        case .listLanguagePacks:
            return try await listLanguagePacks(arguments)
        case .storageUsage:
            return try await readStorageUsage()
        case .getCameraDiagnosticPreview:
            return try await readCameraDiagnosticPreview(arguments)
        case .job, .importRecords:
            guard let catalog = model.catalog else { throw Self.missingJob }
            let response = try await readImportRecords(catalog: catalog, tool: tool, arguments: arguments)
            guard session == model.catalogSessionID else { throw MCPToolProblem.catalogChanged }
            return response
        default: throw MCPToolProblem.failed
        }
    }

    func write(_ tool: AppMCPTool, arguments: Arguments) throws -> MCPToolResult {
        switch tool {
        case .fileAccess:
            let purpose = MCPFilePurpose(rawValue: arguments["purpose"]!.stringValue!)!
            if purpose.needsCatalog && model.catalog == nil { throw MCPToolProblem.noCatalog }
            return start(tool, waitingFor: purpose.rawValue) { job in try await self.requestAccess(purpose, job: job) }
        case .planMerge: return try planMerge(arguments, catalog: model.catalog!)
        case .renderMerge: return try renderMerge(arguments, catalog: model.catalog!)
        case .editExportPreset: return try editExportPreset(arguments)
        case .planExport: return try planExport(arguments, catalog: model.catalog!)
        case .runExport: return try runExport(arguments, catalog: model.catalog!)
        case .retryExport: return try retryExport(arguments, catalog: model.catalog!)
        case .reauthorizeExport: return try reauthorizeExport(arguments, catalog: model.catalog!)
        case .revealFile: return try revealFile(arguments, catalog: model.catalog!)
        case .setPreferences: return try MCPPreferences.apply(arguments["preferences"]!.objectValue!, to: model)
        case .showAppPanel: return try showAppPanel(arguments)
        case .editLanguagePack, .selectLanguage: return try changeLanguage(tool, args: arguments)
        case .setCacheQuota, .clearThumbnailCache: return changeCache(tool, args: arguments)
        case .backupCatalog, .exportCatalogManifest: return try writeCatalogOutput(tool, args: arguments, catalog: model.catalog!)
        case .restoreCatalogBackup: return try restoreCatalogBackup(arguments)
        case .runCameraDiagnostics: return try runCameraDiagnostics(arguments)
        case .saveCameraDiagnosticReport: return try saveCameraDiagnosticReport(arguments)
        case .createCatalog:
            let grant = try grant(arguments["access_id"], purpose: .createCatalog)
            let name = arguments["name"]!.stringValue!
            guard (try? AppModel.catalogFilename(name)) != nil else { throw MCPToolProblem.invalid("Use a valid catalog filename.") }
            return start(tool) { job in
                let filename = try AppModel.catalogFilename(name)
                let url = grant.url.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: url.path) { throw Self.catalogExists }
                // Activation can fail after the new file has been created.
                job.data["commit_state"] = "unknown"
                try await self.activate(job) { try self.model.createCatalog(name: name, directory: grant.url, restoring: nil) }
                job.finish(.succeeded, "Created and opened the catalog.", committed: "committed")
            }
        case .openCatalog:
            let access = arguments["access_id"], recentID = arguments["recent_catalog_id"]?.stringValue
            guard (access == nil) != (recentID == nil) else { throw MCPToolProblem.invalid("Provide exactly one catalog access ID or recent catalog ID.") }
            if let access {
                let grant = try grant(access, purpose: .openCatalog)
                return start(tool) { job in
                    guard let directory = grant.directory, try FileIdentity.read(grant.url) == grant.identity else { throw Self.accessExpired }
                    try await self.open(.init(url: grant.url, access: directory, bookmark: nil), job: job)
                }
            }
            guard let recent = model.recentCatalogs.first(where: { recentIDs[$0.path] == recentID }) else {
                throw MCPToolProblem(code: "recent_catalog_unavailable", summary: "The recent catalog is no longer listed.", next: "Refresh list_recent_catalogs or request file access.")
            }
            return start(tool) { job in
                let lease = try AccessLease(bookmark: recent.bookmark)
                try await self.open(.init(url: lease.url.appendingPathComponent(recent.filename), access: lease, bookmark: recent.bookmark), job: job)
            }
        default:
            guard let catalog = model.catalog else { throw MCPToolProblem.noCatalog }
            return try writeLibrary(tool, catalog: catalog, arguments: arguments)
        }
    }

    func remember(_ job: Job) {
        if jobs.count >= 64 {
            let index = jobs.firstIndex { $0 !== activeJob && $0 !== cullingJob }!
            let oldest = jobs.remove(at: index)
            grants[oldest.id] = nil
            importPlans[oldest.id] = nil
            folderPlans[oldest.id] = nil
            stackPlans[oldest.id] = nil
            pairPlans[oldest.id] = nil
            xmpPlans[oldest.id] = nil
            adjustmentPlans[oldest.id] = nil
            mergePlans[oldest.id] = nil
            mergeFiles[oldest.id] = nil
            exportPlans[oldest.id] = nil
        }
        jobs.append(job)
    }

    func start(_ tool: AppMCPTool, waitingFor action: String? = nil, _ work: @escaping @MainActor (Job) async throws -> Void) -> MCPToolResult {
        let job = Job(tool: tool, session: model.catalogSessionID)
        if let action { wait(job, action: action) }
        remember(job)
        activeJob = job
        model.busy = true
        model.task = Task { [self, model] in
            defer { job.onCancel = nil; activeJob = nil; model.taskProgress = nil; model.busy = false; model.task = nil }
            do {
                try Task.checkCancellation()
                if action == nil { running(job, phase: "working") }
                try await work(job)
            } catch is CancellationError {
                job.finish(.cancelled, "The job was cancelled.", committed: job.data["commit_state"]?.stringValue ?? "not_committed")
            } catch let problem as MCPToolProblem {
                fail(job, with: problem)
            } catch {
                model.reports = [error.localizedDescription]
                model.status = L10n.text("app.actionIncomplete", defaultValue: "Action Incomplete")
                job.finish(.failed, "Phosdeck could not finish the job. See the app for details.",
                           committed: job.data["commit_state"]?.stringValue ?? "not_committed", error: "operation_failed")
            }
        }
        return result(job)
    }

    func wait(_ job: Job, action: String) {
        job.state = .waiting
        job.phase = "awaiting_user"
        job.action = action
    }
    func running(_ job: Job, phase: String) {
        job.state = .running
        job.phase = phase
        job.action = nil
    }
    func fail(_ job: Job, with problem: MCPToolProblem) {
        job.finish(.failed, problem.summary, committed: job.data["commit_state"]?.stringValue ?? "not_committed", error: problem.code)
        job.data["follow_up"] = .string(problem.next)
        if !problem.details.isEmpty { job.data["error_details"] = .object(problem.details) }
    }
    func progress(_ job: Job, title: String, done: Int, total: Int) {
        let progress = TaskProgress(title: title, done: done, total: total)
        job.progress = progress
        model.taskProgress = progress
    }

    func control(_ tool: AppMCPTool, arguments: Arguments) throws -> MCPToolResult {
        guard let job = jobs.first(where: { $0.id == arguments["job_id"]?.stringValue }) else { throw Self.missingJob }
        if tool == .cancelJob {
            if job === activeJob || job === cullingJob { cancel(job) }
            return result(job)
        }
        let id = arguments["conflict_id"]!.stringValue!
        guard let policy = ConflictPolicy(rawValue: arguments["policy"]!.stringValue!) else { throw MCPToolProblem.invalid("Select a policy offered by get_job.") }
        let remaining = arguments["apply_to_remaining"]!.boolValue!
        if let reply = job.conflictReplies[id], reply.policy == policy, reply.applyToRemaining == remaining { return result(job) }
        guard job === activeJob, waitingForConflict, let conflict = model.importConflict, conflict.id == id else {
            throw MCPToolProblem(code: "stale_conflict", summary: "This conflict is no longer waiting for a decision.", next: "Read get_job for the current state.")
        }
        guard policy != .overwrite || conflict.overwriteRestriction == nil, policy != .uniqueName || conflict.canRename else {
            throw MCPToolProblem(code: "conflict_policy_unavailable", summary: "Phosdeck cannot apply that policy to this group.", next: "Choose one of the available policies in get_job.")
        }
        let reply = ImportConflictDecision(policy: policy, applyToRemaining: remaining)
        job.conflictReplies[id] = reply
        model.resolveImportConflict(reply)
        return result(job)
    }

    private func cancel(_ job: Job) {
        guard !job.cancelRequested else { return }
        job.cancelRequested = true
        if job === cullingJob { cullingTask?.cancel(); return }
        model.task?.cancel()
        job.onCancel?()
        cancelPanel?()
        if [.startImport, .resumeImport].contains(job.tool), model.importConflict != nil { model.resolveImportConflict(nil) }
    }

    private func state(of job: Job) -> Job.State {
        job === activeJob && waitingForConflict ? .waiting : job.state
    }
    func result(_ job: Job, arguments: Arguments = [:]) -> MCPToolResult {
        let conflict = job === activeJob && waitingForConflict ? model.importConflict : nil
        let state = state(of: job)
        let action = conflict == nil ? job.action : "resolve_import_conflict"
        var data = job.data
        data["job_id"] = .string(job.id)
        data["catalog_session_id"] = data["catalog_session_id"] ?? job.session.map(Value.string) ?? .null
        data["operation"] = .string(job.tool.rawValue)
        data["state"] = .string(state.rawValue)
        data["phase"] = .string(conflict == nil ? job.phase : "awaiting_conflict")
        data["user_action"] = action.map(Value.string) ?? .null
        data["cancel_requested"] = .bool(job.cancelRequested)
        data["progress"] = job.progress.map { ["done": .int($0.done), "total": .int($0.total)] } ?? .null
        data["error_code"] = job.errorCode.map(Value.string) ?? .null
        if let conflict {
            var allowed = [Value.string("skip")]
            if conflict.canRename { allowed.append("uniqueName") }
            if conflict.overwriteRestriction == nil { allowed.append("overwrite") }
            data["conflict"] = ["conflict_id": .string(conflict.id), "allowed_policies": .array(allowed),
                                "files": .array(conflict.members.prefix(50).map {
                ["source_name": .string($0.source.lastPathComponent), "destination_name": .string($0.destination.lastPathComponent)]
            }), "file_count": .int(conflict.members.count)]
        }
        data.merge(Self.page(job.items, arguments: arguments)) { _, page in page }
        let summary = state == .waiting ? "Phosdeck is waiting for a choice." : job.summary
        let followUp: [Value]
        if conflict != nil { followUp = ["Call resolve_import_conflict with an allowed policy, or choose in Phosdeck."] }
        else if action != nil { followUp = ["Complete the requested choice in Phosdeck, then call get_job."] }
        else if let next = job.data["follow_up"] { followUp = [next] }
        else { followUp = [] }
        return .init(summary, data: data, warning: state == .failed || state == .partial || data["workspace_refreshed"] == .bool(false), next: followUp)
    }

    nonisolated static func page(_ items: [Value], arguments: Arguments) -> Arguments {
        let offset = min(arguments["offset"]?.intValue ?? 0, items.count)
        let end = min(offset + (arguments["page_size"]?.intValue ?? 50), items.count)
        return ["items": .array(Array(items[offset..<end])), "total": .int(items.count),
                "next_offset": end < items.count ? .int(end) : .null]
    }

    func grant(_ value: Value?, purpose: MCPFilePurpose) throws -> Grant {
        guard let id = value?.stringValue, let grant = grants[id], grant.purpose == purpose,
              jobs.first(where: { $0.id == id })?.session == model.catalogSessionID else { throw Self.accessExpired }
        return grant
    }

    private func requestAccess(_ purpose: MCPFilePurpose, job: Job) async throws {
        let urls = try await pickURLs(purpose.panel(), job: job, action: purpose.rawValue)
        guard let url = urls.first else { throw CancellationError() }
        guard purpose != .xmpPresets || urls.count <= XMPPresetReader.maximumFiles else {
            throw MCPToolProblem.invalid("Select up to 128 XMP files.")
        }
        let lease = AccessLease(url: url)
        var grant = Grant(purpose: purpose, lease: lease)
        if purpose == .catalogBackupSource { grant.identity = try FileIdentity.read(url) }
        if purpose == .xmpPresets {
            grant.additionalFiles = urls.dropFirst().map(AccessLease.init(url:))
            job.data["file_count"] = .int(urls.count)
        }
        if purpose == .openCatalog || purpose == .locateOriginal {
            grant.identity = try FileIdentity.read(url)
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            if purpose == .openCatalog {
                if let directory = model.cachedCatalogDirectoryAccess(parent) { grant.directory = directory }
                else {
                    guard let directory = try await pick(AppModel.catalogDirectoryPanel(parent), job: job, action: "authorize_catalog_folder") else { throw CancellationError() }
                    guard directory.resolvingSymlinksInPath().standardizedFileURL.path == parent.path else { throw Self.accessExpired }
                    grant.directory = AccessLease(url: directory)
                }
            } else {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if !model.roots.contains(where: { path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }) {
                    let title = L10n.text("app.authorizeTheOriginalPhotoFolder", defaultValue: "Authorize the original photo folder · \(url.lastPathComponent)")
                    let panel = AppModel.directoryPanel(title: title, initialURL: parent)
                    guard let directory = try await pick(panel, job: job, action: "authorize_original_folder") else { throw CancellationError() }
                    grant.directory = AccessLease(url: directory)
                }
            }
        }
        try Task.checkCancellation()
        grants[job.id] = grant
        job.data["access_id"] = .string(job.id)
        job.data["name"] = .string(url.lastPathComponent)
        job.data["purpose"] = .string(purpose.rawValue)
        job.finish(.succeeded, "The user authorized this location.")
    }

    private func pick(_ panel: NSOpenPanel, job: Job, action: String) async throws -> URL? {
        try await pickURLs(panel, job: job, action: action).first
    }

    private func pickURLs(_ panel: NSOpenPanel, job: Job, action: String) async throws -> [URL] {
        wait(job, action: action)
        let urls: [URL]
        if let chooseFile { urls = await chooseFile(panel).map { [$0] } ?? [] }
        else {
            cancelPanel = { panel.cancel(nil) }
            defer { cancelPanel = nil }
            NSApp.activate()
            urls = await panel.begin() == .OK ? panel.urls : []
        }
        try Task.checkCancellation()
        return urls
    }

    func confirm(_ alert: NSAlert, job: Job, action: String) async throws -> NSApplication.ModalResponse {
        wait(job, action: action)
        try Task.checkCancellation()
        NSApp.activate()
        let response: NSApplication.ModalResponse
        if let window = NSApp.windows.first(where: { $0.isVisible && WorkspaceKeyboard.isWorkspaceWindow($0) }) ?? NSApp.keyWindow {
            cancelPanel = { [weak window] in window?.endSheet(alert.window, returnCode: .cancel) }
            defer { cancelPanel = nil }
            response = await alert.beginSheetModal(for: window)
        } else {
            cancelPanel = { NSApp.abortModal() }
            defer { cancelPanel = nil; alert.window.orderOut(nil) }
            response = alert.runModal()
        }
        try Task.checkCancellation()
        running(job, phase: "working")
        return response
    }

    private func open(_ request: CatalogOpenRequest, job: Job) async throws {
        var url = request.url
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        guard request.access.url.resolvingSymlinksInPath().standardizedFileURL.path == normalized.deletingLastPathComponent().path else { throw Self.accessExpired }
        let previous = model.catalogSessionID
        if normalized != model.catalog?.fileURL {
            if CatalogFile.isLegacy(url) {
                let change = try CatalogExtensionChange(source: url)
                let response = try await confirm(AppModel.catalogExtensionAlert(change), job: job, action: "catalog_extension_choice")
                switch AppModel.catalogExtensionChoice(response) {
                case .cancel: throw CancellationError()
                case .keepOriginal:
                    guard try FileIdentity.read(url) == change.identity else { throw Self.accessExpired }
                case .change:
                    model.changingCatalogExtension = true
                    defer { model.changingCatalogExtension = false }
                    job.data["commit_state"] = "unknown"
                    url = try await AppModel.renameCatalogFile(change)
                    job.data["name"] = .string(url.lastPathComponent)
                    job.data["commit_state"] = "committed"
                }
            }
            try await activate(job) { try model.finishCatalogOpen(url, request: request) }
        }
        job.data["catalog_session_id"] = model.catalogSessionID.map(Value.string) ?? .null
        job.data["catalog_name"] = .string(model.catalogName)
        job.finish(.succeeded, "Catalog opened.", committed: previous == model.catalogSessionID ? "not_committed" : "committed")
    }

    func activate(_ job: Job, _ work: () throws -> Void) async throws {
        // The native catalog activation is synchronous and checks the busy flag.
        model.busy = false
        let previous = model.catalogSessionID
        let outcome = Result { try work() }
        model.busy = true
        if previous != model.catalogSessionID {
            job.data["catalog_session_id"] = model.catalogSessionID.map(Value.string) ?? .null
            job.data["catalog_name"] = .string(model.catalogName)
            job.data["commit_state"] = "committed"
            if let cache = model.cacheConfigurationTask {
                running(job, phase: "refreshing_workspace")
                await cache.value
            }
        }
        try outcome.get()
    }

    private func recentCatalogs() async -> MCPToolResult {
        let entries = model.recentCatalogs
        let current = model.catalog?.fileURL.path
        let previous = recentIDs
        recentIDs = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, previous[$0.path] ?? UUID().uuidString) })
        let ids = recentIDs
        let items: [Value] = await Task.detached {
            entries.map { entry in
                let available: Bool
                if let lease = try? AccessLease(bookmark: entry.bookmark) {
                    available = (try? FileIdentity.read(lease.url.appendingPathComponent(entry.filename))) != nil
                    withExtendedLifetime(lease) {}
                } else { available = false }
                return ["recent_catalog_id": .string(ids[entry.path]!), "name": .string(entry.filename),
                        "available": .bool(available), "is_current": .bool(current == entry.path)]
            }
        }.value
        return .init("Read recent catalogs.", data: ["items": .array(items)])
    }

    nonisolated static let missingJob = MCPToolProblem(code: "job_unavailable", summary: "The job is no longer available.", next: "For a saved copy import, open its catalog and use list_import_records.")
    nonisolated static let accessExpired = MCPToolProblem(code: "file_access_required", summary: "This file authorization expired, changed, or is for a different purpose.", next: "Request file access for this operation again.")
    nonisolated static let catalogExists = MCPToolProblem(code: "catalog_exists", summary: "A file already has this catalog name.", next: "Choose another name or open the existing catalog.")
}
