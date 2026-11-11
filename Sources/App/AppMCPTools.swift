import AppKit
import Combine
import ImageIO
import MCP
import UniformTypeIdentifiers

enum AppMCPTool: String, CaseIterable {
    case capabilities = "get_capabilities"
    case workspace = "get_workspace"
    case listPhotos = "list_photos"
    case preview = "get_photo_preview"
    case rate = "set_photo_rating"
    case undo = "undo_operation"
    case librarySources = "list_library_sources", recentCatalogs = "list_recent_catalogs"
    case fileAccess = "request_file_access", createCatalog = "create_catalog", openCatalog = "open_catalog"
    case relocateRoot = "relocate_library_root", locateOriginal = "locate_photo_original"
    case planImport = "plan_photo_import", startImport = "start_photo_import", resolveConflict = "resolve_import_conflict"
    case recentImport = "show_recent_import", scanFolder = "scan_library_folder"
    case planFolder = "plan_folder_review", applyFolder = "apply_folder_review"
    case importRecords = "list_import_records", resumeImport = "resume_photo_import"
    case restoreBackup = "restore_import_backup", cleanBackup = "clean_import_backup"
    case job = "get_job", cancelJob = "cancel_job"

    enum Field: String {
        case catalog = "catalog_session_id", photo = "photo_id", cursor, pageSize = "page_size"
        case sourceRevision = "source_revision", recipeRevision = "recipe_revision", longEdge = "long_edge"
        case expectedRating = "expected_rating", rating, epoch = "request_epoch", request = "request_id", operation = "operation_id"
        case offset, purpose, access = "access_id", recent = "recent_catalog_id", name, root = "root_id", folder = "folder_id"
        case sourceAccess = "source_access_id", destinationAccess = "destination_access_id", mode, recursive = "include_subfolders"
        case skipCataloged = "skip_cataloged", layout = "date_layout", archiveDate = "archive_date", sidecars = "include_sidecars"
        case collection = "collection_id", pair = "detect_pairs", policy, basePlan = "base_plan_id", attachments = "attachment_assignments"
        case plan = "plan_id", candidates = "candidate_ids", all = "select_all", job = "job_id", conflict = "conflict_id"
        case remaining = "apply_to_remaining", action, differences = "difference_ids", locations = "locations"
        case record = "record_id", member = "member_id"

        private var range: ClosedRange<Int>? {
            switch self {
            case .pageSize: 1...200
            case .longEdge: 1...1024
            case .expectedRating, .rating: 0...5
            case .sourceRevision, .recipeRevision: 0...Int.max
            case .offset: 0...Int.max
            default: nil
            }
        }
        private var options: [String]? {
            switch self {
            case .purpose: MCPFilePurpose.allCases.map(\.rawValue)
            case .mode: ["reference", "copy"]
            case .layout: DateLayout.allCases.map(\.rawValue)
            case .policy: ["ask"] + ConflictPolicy.allCases.map(\.rawValue)
            case .action: ["show", "start_culling", "return"]
            default: nil
            }
        }
        private var isBoolean: Bool {
            [.recursive, .skipCataloged, .sidecars, .pair, .all, .remaining].contains(self)
        }
        private var maxString: Int { self == .folder ? 4096 : self == .name ? 255 : 128 }
        private var identifierSchema: Value { ["type": "string", "minLength": 1, "maxLength": 128] }
        var schema: Value {
            if let range {
                var schema: [String: Value] = ["type": "integer", "minimum": .int(range.lowerBound)]
                if range.upperBound != Int.max { schema["maximum"] = .int(range.upperBound) }
                if self == .pageSize { schema["default"] = 50 }
                if self == .longEdge { schema["default"] = 768 }
                return .object(schema)
            }
            if let options { return ["type": "string", "enum": .array(options.map(Value.string))] }
            if isBoolean { return ["type": "boolean"] }
            if self == .candidates || self == .differences {
                return ["type": "array", "minItems": 1, "maxItems": 1000, "uniqueItems": true, "items": identifierSchema]
            }
            if self == .attachments || self == .locations {
                return ["type": "object", "maxProperties": 1000, "propertyNames": identifierSchema, "additionalProperties": identifierSchema]
            }
            return ["type": "string", "minLength": 1, "maxLength": .int(maxString)]
        }
        func accepts(_ value: Value) -> Bool {
            if let range { return value.intValue.map(range.contains) ?? false }
            if isBoolean { return value.boolValue != nil }
            if self == .candidates || self == .differences {
                guard let values = value.arrayValue, (1...1000).contains(values.count) else { return false }
                let ids = values.compactMap(\.stringValue)
                return Set(ids).count == values.count && ids.allSatisfy(Self.isID)
            }
            if self == .attachments || self == .locations {
                guard let values = value.objectValue, values.count <= 1000 else { return false }
                return values.allSatisfy { Self.isID($0.key) && ($0.value.stringValue.map(Self.isID) ?? false) }
            }
            guard let text = value.stringValue else { return false }
            return options?.contains(text) ?? ((1...maxString).contains(text.utf8.count) && !text.contains("\0"))
        }
        private static func isID(_ text: String) -> Bool { (1...128).contains(text.utf8.count) && !text.contains("\0") }
    }

    var required: [Field] {
        switch self {
        case .capabilities, .workspace, .recentCatalogs: []
        case .listPhotos, .librarySources, .importRecords: [.catalog]
        case .preview: [.catalog, .photo, .sourceRevision, .recipeRevision]
        case .rate: [.catalog, .photo, .expectedRating, .rating]
        case .undo: [.catalog, .operation]
        case .fileAccess: [.purpose]
        case .createCatalog: [.access, .name]
        case .openCatalog: []
        case .relocateRoot: [.catalog, .root, .access]
        case .locateOriginal: [.catalog, .photo, .sourceRevision, .access]
        case .planImport: [.catalog, .mode, .sourceAccess]
        case .startImport: [.catalog, .plan]
        case .resolveConflict: [.job, .conflict, .policy, .remaining]
        case .recentImport: [.catalog, .action]
        case .scanFolder, .planFolder: [.catalog, .root]
        case .applyFolder: [.catalog, .plan, .differences]
        case .resumeImport: [.catalog, .record]
        case .restoreBackup: [.catalog, .record, .member, .access]
        case .cleanBackup: [.catalog, .record, .member]
        case .job, .cancelJob: [.job]
        }
    }
    var optional: [Field] {
        switch self {
        case .listPhotos: [.cursor, .pageSize]
        case .preview: [.longEdge]
        case .job, .librarySources, .importRecords: [.offset, .pageSize]
        case .fileAccess, .createCatalog: [.catalog]
        case .openCatalog: [.catalog, .access, .recent]
        case .planImport: [.destinationAccess, .recursive, .skipCataloged, .layout, .archiveDate, .sidecars, .collection, .pair, .policy, .basePlan, .candidates, .attachments]
        case .startImport: [.candidates, .all]
        case .scanFolder, .planFolder: [.folder, .recursive]
        case .applyFolder: [.locations]
        case .restoreBackup: [.name]
        default: []
        }
    }
    var writes: Bool {
        switch self {
        case .capabilities, .workspace, .listPhotos, .preview, .librarySources, .recentCatalogs, .importRecords, .job: false
        default: true
        }
    }
    var addressedJobAction: Bool { self == .cancelJob || self == .resolveConflict }
    var needsRequestID: Bool { writes && !addressedJobAction }
    var needsCatalog: Bool { required.contains(.catalog) }

    var definition: Tool {
        let description: String
        let output: String
        switch self {
        case .capabilities:
            description = "Identify the connected Phosdeck instance and which tools are currently available."
            output = "app_name, version, bundle_id, instance_id, image_sharing, and tools with enabled and reason."
        case .workspace:
            description = "Read the current catalog, query, active photo, selection and native task state before working on photos."
            output = "catalog_session_id, request_epoch, catalog_name, source, query, view, tool, active_photo, selected_photo_ids, selection_count, selection_truncated, busy, modal, draft, and task."
        case .listPhotos:
            description = "Page through the current source, filters and sort without changing the app's selection. Reuse next_cursor for the next page."
            output = "items with photo_id, name, version_name, source_revision, recipe_revision, rating, flag, color_label, source_status, and stack. matched_count includes folded members. visible_count and next_cursor describe the displayed rows."
        case .preview:
            description = "Render the specified saved photo version as an sRGB PNG, when the user has enabled image sharing. Use revisions from list_photos or get_workspace."
            output = "preview_id, photo_id, source_revision, recipe_revision, width, height, coordinate_space, and histogram, plus a PNG content block."
        case .rate:
            description = "Set the rating of one explicit photo. Pass its current expected_rating and the request_epoch from get_workspace. Reuse request_id with identical arguments only when retrying the same operation."
            output = "photo_id, previous_rating, rating, changed, commit_state, and operation_id when an undo was registered."
        case .undo:
            description = "Undo a rating with its operation_id, if that action is still at the top of Phosdeck's undo stack. Use a fresh request_id."
            output = "operation_id, photo_id, restored rating, and commit_state."
        default:
            (description, output) = workflowDescription
        }
        let required = required + (needsRequestID ? [.epoch, .request] : [])
        let properties = Dictionary(uniqueKeysWithValues: (required + optional).map { ($0.rawValue, $0.schema) })
        let destructive = [.startImport, .resolveConflict, .resumeImport, .cleanBackup].contains(self)
        return Tool(name: rawValue, description: description, inputSchema: [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
            "required": .array(required.map { .string($0.rawValue) })
        ], annotations: .init(readOnlyHint: !writes, destructiveHint: destructive, idempotentHint: true, openWorldHint: false), outputSchema: [
            "type": "object", "required": ["status", "summary", "next_actions", "artifacts", "data"],
            "properties": [
                "status": ["enum": ["success", "warning", "error"]],
                "summary": ["type": "string"],
                "next_actions": ["type": "array", "items": ["type": "string"]],
                "artifacts": ["type": "array", "items": ["type": "object"]],
                "data": ["type": "object", "description": .string(output)],
                "error": ["type": "object", "required": ["code"], "properties": ["code": ["type": "string"]]]
            ]
        ])
    }
}

struct MCPToolProblem: Error {
    let code: String
    let summary: String
    let next: String
    var details: [String: Value] = [:]

    static let stopped = Self(code: "service_stopped", summary: "The Phosdeck MCP service stopped.", next: "Reconnect using the current settings.")
    static let noCatalog = Self(code: "no_catalog", summary: "Phosdeck has no open catalog.", next: "Open or create a catalog in Phosdeck.")
    static let catalogChanged = Self(code: "catalog_changed", summary: "The catalog session changed.", next: "Call get_workspace and locate the target again.")
    static let staleCursor = Self(code: "stale_cursor", summary: "The photo query or its results changed.", next: "Call get_workspace and restart list_photos without a cursor.")
    static let photoUnavailable = Self(code: "photo_unavailable", summary: "The requested photo is unavailable.", next: "Call list_photos to locate the photo.")
    static let stalePhoto = Self(code: "stale_photo", summary: "The requested photo version changed.", next: "Call list_photos to obtain the current revisions.")
    static let stalePreview = Self(code: "stale_preview", summary: "The photo changed during rendering.", next: "Call list_photos and request the current saved version.")
    static let imageDisabled = Self(code: "image_access_disabled", summary: "Photo preview sharing is off.", next: "Enable photo preview sharing in Phosdeck Settings.")
    static let fileAccess = Self(code: "file_access_required", summary: "Phosdeck could not access this photo source.", next: "Check the photo's source in Phosdeck.")
    static let busy = Self(code: "workspace_busy", summary: "Phosdeck has an open dialog or a task in progress.", next: "Wait for the task or close the dialog and call get_workspace.")
    static let nativeInteraction = Self(code: "native_interaction_active", summary: "A native edit or undo group is still active.", next: "Finish or cancel the edit in Phosdeck, then refresh the workspace.")
    static let undoConflict = Self(code: "undo_conflict", summary: "That operation is no longer the current undo action.", next: "Read the current workspace and photo rating.")
    static let expired = Self(code: "request_expired", summary: "This write request epoch expired.", next: "Read get_workspace and check the affected state before making a new request.")
    static let failed = Self(code: "operation_failed", summary: "Phosdeck could not complete the operation.", next: "Check the current state in Phosdeck before retrying.")
    static func invalid(_ message: String) -> Self {
        Self(code: "invalid_arguments", summary: message, next: "Read the tool's input schema and refresh the target IDs.")
    }
    static func ratingConflict(_ actual: Int) -> Self {
        Self(code: "rating_conflict", summary: "The photo has a different current rating.", next: "Use the actual rating to reassess the intended edit.",
             details: ["actual_rating": .int(actual)])
    }
}

struct MCPToolResult: Sendable {
    let payload: Value
    let image: String?
    let failed: Bool

    init(_ summary: String, data: [String: Value], warning: Bool = false, artifacts: [Value] = [], image: String? = nil, next: [Value] = []) {
        payload = ["status": warning ? "warning" : "success", "summary": .string(summary),
                   "next_actions": .array(warning && next.isEmpty ? ["Refresh the workspace before making another edit."] : next),
                   "artifacts": .array(artifacts), "data": .object(data)]
        self.image = image
        failed = false
    }
    init(_ problem: MCPToolProblem, commitState: String? = nil) {
        var data = problem.details
        if let commitState { data["commit_state"] = .string(commitState) }
        payload = ["status": "error", "summary": .string(problem.summary), "next_actions": [.string(problem.next)],
                   "artifacts": [], "data": .object(data), "error": ["code": .string(problem.code)]]
        image = nil
        failed = true
    }
    func response() -> CallTool.Result {
        let text = (try? JSONEncoder().encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
        if let image { content.append(.image(data: image, mimeType: "image/png", annotations: nil, _meta: nil)) }
        return .init(content: content, structuredContent: payload as Value?, isError: failed)
    }
}

@MainActor
final class AppMCPTools {
    private struct Cursor {
        let token = UUID().uuidString
        let query: PhotoQuery
        let generation: UUID
        let databaseChanges: Int
        let offset: Int
        let size: Int
    }
    private struct Write {
        let tool: AppMCPTool
        let arguments: [String: Value]
        let result: MCPToolResult
    }
    private struct Preview: Sendable {
        let data: [String: Value]
        let name: String
        let png: String
    }

    private weak var model: AppModel?
    private let appName: String
    private let version: String
    private let bundleID: String
    private let instanceID = UUID().uuidString
    private var sharesImages: Bool
    private var imageAccessGeneration = UUID()
    private var stopped = false
    private var observedCatalog: String?
    private var requestEpoch = UUID().uuidString
    private var writes: [String: Write] = [:]
    private var cursors: [Cursor] = []
    private var currentUndo: PhotoRatingUndo?
    private var undoObservers: [AnyCancellable] = []
    private var activeLists = 0
    private var previewWorker: Task<Preview, Error>?
    private lazy var previewPipeline = ImagePipeline(qualityCacheLimit: 0)
    private let workflows: AppMCPWorkflows

    init(model: AppModel, appName: String, version: String, bundleID: String, sharesImages: Bool,
         chooseFile: AppMCPWorkflows.FilePicker? = nil) {
        self.model = model
        self.appName = appName
        self.version = version
        self.bundleID = bundleID
        self.sharesImages = sharesImages
        workflows = AppMCPWorkflows(model: model, chooseFile: chooseFile)
        // A rating is registered in its own closed group. Any new group, undo or redo
        // invalidates the receipt before the next MCP request can reach the main actor.
        for name in [Notification.Name.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            undoObservers.append(NotificationCenter.default.publisher(for: name, object: model.undo).sink { [weak self] _ in
                self?.currentUndo = nil
            })
        }
    }

    func setSharesImages(_ value: Bool) {
        sharesImages = value
        if !value {
            imageAccessGeneration = UUID()
            previewWorker?.cancel()
        }
    }
    @discardableResult func stop() -> Task<Void, Never>? {
        stopped = true
        previewWorker?.cancel()
        undoObservers.removeAll()
        currentUndo = nil
        cursors.removeAll()
        writes.removeAll()
        return workflows.stop()
    }

    nonisolated func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let result = await execute(params)
        return result.response()
    }

    private func execute(_ params: CallTool.Parameters) async -> MCPToolResult {
        guard !stopped, !Task.isCancelled, let model else { return .init(.stopped) }
        guard let tool = AppMCPTool(rawValue: params.name) else {
            return .init(.init(code: "unsupported_operation", summary: "This tool is unavailable.", next: "Read the registered tools."))
        }
        let arguments = params.arguments ?? [:]
        let required = tool.required + (tool.needsRequestID ? [.epoch, .request] : [])
        let fields = required + tool.optional
        guard Set(arguments.keys).isSubset(of: Set(fields.map(\.rawValue))) else {
            return invalidArguments("Unexpected tool argument.", writes: tool.writes)
        }
        if let field = required.first(where: { arguments[$0.rawValue] == nil }) ??
            fields.first(where: { field in arguments[field.rawValue].map { !field.accepts($0) } ?? false }) {
            return invalidArguments("Invalid or missing \(field.rawValue).", writes: tool.writes)
        }

        let catalogSession = model.catalogSessionID
        if observedCatalog != catalogSession {
            observedCatalog = catalogSession
            cursors.removeAll()
            currentUndo = nil
            workflows.catalogChanged()
        }
        switch tool {
        case .capabilities: return capabilities(model)
        case .workspace: return workspace(model)
        case .cancelJob, .resolveConflict:
            do { return try workflows.control(tool, arguments: arguments) }
            catch let problem as MCPToolProblem { return .init(problem, commitState: "not_committed") }
            catch { return .init(.failed, commitState: "not_committed") }
        default: break
        }
        if tool.needsRequestID { return write(tool, arguments: arguments, model: model) }
        do {
            try checkCatalog(tool, arguments: arguments, model: model)
            switch tool {
            case .listPhotos:
                return try await listPhotos(model, catalog: model.catalog!, session: catalogSession!, arguments: arguments)
            case .preview:
                return try await preview(model, catalog: model.catalog!, session: catalogSession!, arguments: arguments)
            default:
                let result = try await workflows.read(tool, arguments: arguments)
                guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
                return result
            }
        } catch let problem as MCPToolProblem {
            return .init(problem)
        } catch {
            return .init(.failed)
        }
    }

    private func checkCatalog(_ tool: AppMCPTool, arguments: [String: Value], model: AppModel) throws {
        if tool.needsCatalog && model.catalog == nil { throw MCPToolProblem.noCatalog }
        let session = arguments["catalog_session_id"]?.stringValue
        let catalogBound = tool.needsCatalog || [.fileAccess, .createCatalog, .openCatalog].contains(tool)
        if catalogBound && session != model.catalogSessionID {
            throw MCPToolProblem.catalogChanged
        }
    }

    private func invalidArguments(_ summary: String, writes: Bool) -> MCPToolResult {
        .init(.invalid(summary), commitState: writes ? "not_committed" : nil)
    }

    private func capabilities(_ model: AppModel) -> MCPToolResult {
        let tools: [Value] = AppMCPTool.allCases.map { tool in
            let problem: MCPToolProblem?
            switch tool {
            case .capabilities, .workspace, .recentCatalogs, .job, .cancelJob: problem = nil
            case .listPhotos: problem = model.catalog == nil ? .noCatalog : nil
            case .preview: problem = model.catalog == nil ? .noCatalog : sharesImages ? nil : .imageDisabled
            case .rate: problem = model.catalog == nil ? .noCatalog : writeProblem(model)
            case .undo:
                problem = model.catalog == nil ? .noCatalog : writeProblem(model) ?? (currentUndo == nil || !model.undo.canUndo ? .undoConflict : nil)
            case .resolveConflict: problem = workflows.waitingForConflict ? nil : .busy
            default: problem = tool.needsCatalog && model.catalog == nil ? .noCatalog : tool.writes ? writeProblem(model) : nil
            }
            return ["name": .string(tool.rawValue), "enabled": .bool(problem == nil),
                    "reason": problem.map { .string($0.code) } ?? .null]
        }
        return .init("Connected to \(appName).", data: [
            "app_name": .string(appName), "version": .string(version), "bundle_id": .string(bundleID),
            "instance_id": .string(instanceID), "image_sharing": .bool(sharesImages), "tools": .array(tools)
        ])
    }

    private func workspace(_ model: AppModel) -> MCPToolResult {
        if writes.count >= 256 && !workflows.isWorking { rotateRequestEpoch() }
        let query = model.query
        let metadata = query.metadata
        let selection = model.selection.prefix(50).sorted()
        let task: Value = model.taskProgress.map {
            ["title": .string($0.title), "done": .int($0.done), "total": .int($0.total)]
        } ?? .null
        return .init("Current Phosdeck workspace.", data: [
            "catalog_session_id": model.catalogSessionID.map(Value.string) ?? .null,
            "request_epoch": .string(requestEpoch), "catalog_name": model.catalog == nil ? .null : .string(model.catalogName),
            "source": model.catalog == nil ? .null : .string(model.browseSourceName),
            "query": [
                "search": .string(query.search), "rating_threshold": .int(query.ratingThreshold),
                "rating_comparison": .string(query.ratingComparison.rawValue), "flags": .array(query.flags.sorted().map(Value.int)),
                "color_labels": .array(query.colorLabels.sorted().map(Value.int)), "keyword": .string(query.keyword),
                "metadata": ["camera": .string(metadata.camera), "lens": .string(metadata.lens), "minimum_iso": .string(metadata.minimumISO),
                             "maximum_iso": .string(metadata.maximumISO), "date_from": .string(metadata.dateFrom), "date_through": .string(metadata.dateThrough)],
                "sort": .string(query.isManualCollectionOrder ? "manual" : query.sort.rawValue), "descending": .bool(query.descending),
                "frozen": .bool(query.snapshotID != nil), "smart_collection": .bool(query.smart != nil || query.invalidSmart)
            ],
            "view": .string(String(describing: model.workspaceMode)), "tool": model.editMode ? .string(String(describing: model.developTool)) : .null,
            "active_photo": model.active.flatMap { $0.id == model.activeID ? Self.photo($0, badge: model.stackBadges[$0.id]) : nil } ?? .null,
            "selected_photo_ids": .array(selection.map(Value.string)), "selection_count": .int(model.selection.count),
            "selection_truncated": .bool(selection.count < model.selection.count),
            "busy": .bool(model.busy || model.applyingAdjustments || model.cacheMaintenance),
            "modal": .bool(nativeModal(model)),
            "draft": .bool(nativeInteraction(model)), "task": task, "agent_job": workflows.currentJob
        ])
    }

    private func listPhotos(_ model: AppModel, catalog: CatalogStore, session: String, arguments: [String: Value]) async throws -> MCPToolResult {
        let query = model.query
        let generation = model.browseGeneration
        let cursor: Cursor?
        let requestedSize = arguments["page_size"]?.intValue
        if let token = arguments["cursor"]?.stringValue {
            guard let saved = cursors.first(where: { $0.token == token }), saved.query == query, saved.generation == generation,
                  requestedSize == nil || requestedSize == saved.size else { throw MCPToolProblem.staleCursor }
            cursor = saved
        } else { cursor = nil }
        guard activeLists < 2 else {
            throw MCPToolProblem(code: "workspace_busy", summary: "Photo queries are in progress.", next: "Retry the read after the current query finishes.")
        }
        let size = cursor?.size ?? requestedSize ?? 50
        activeLists += 1
        defer { activeLists -= 1 }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let page = try catalog.page(query, offset: cursor?.offset ?? 0, limit: size, expectedChanges: cursor?.databaseChanges)
            let items = page.photos.map { Self.photo($0, badge: page.badges[$0.id]) }
            return (items, page.total, page.visibleTotal, page.offset + items.count, page.databaseChanges)
        }
        let result: ([Value], Int, Int, Int, Int)
        do {
            result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        } catch PhotoPageError.staleCursor { throw MCPToolProblem.staleCursor }
        guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        guard model.query == query, model.browseGeneration == generation else { throw MCPToolProblem.staleCursor }
        let (items, matched, visible, nextOffset, changes) = result
        var next: Value = .null
        if nextOffset < visible {
            let cursor = Cursor(query: query, generation: generation, databaseChanges: changes, offset: nextOffset, size: size)
            if cursors.count >= 128 { cursors.removeFirst() }
            cursors.append(cursor)
            next = .string(cursor.token)
        }
        return .init("Read \(items.count) photos.", data: ["items": .array(items), "matched_count": .int(matched),
                                                         "visible_count": .int(visible), "next_cursor": next])
    }

    nonisolated private static func photo(_ photo: Photo, badge: StackBadge?) -> Value {
        let stack: Value = badge.map {
            ["stack_id": .string($0.stackID), "position": .int($0.position), "member_count": .int($0.count),
             "matched_count": .int($0.matching), "collapsed": .bool($0.collapsed)]
        } ?? .null
        return ["photo_id": .string(photo.id), "name": .string(photo.name), "version_name": .string(String(photo.versionName.prefix(256))),
                "source_revision": .int(photo.revision), "recipe_revision": .int(photo.recipeRevision), "rating": .int(photo.rating),
                "flag": .int(photo.flag), "color_label": .int(photo.colorLabel), "source_status": .string(photo.availability), "stack": stack]
    }

    private func preview(_ model: AppModel, catalog: CatalogStore, session: String, arguments: [String: Value]) async throws -> MCPToolResult {
        guard sharesImages else { throw MCPToolProblem.imageDisabled }
        guard previewWorker == nil else {
            throw MCPToolProblem(code: "workspace_busy", summary: "A preview is rendering.", next: "Retry the preview after rendering finishes.")
        }
        let id = arguments["photo_id"]!.stringValue!
        let sourceRevision = arguments["source_revision"]!.intValue!
        let recipeRevision = arguments["recipe_revision"]!.intValue!
        let edge = arguments["long_edge"]?.intValue ?? 768
        let accessGeneration = imageAccessGeneration
        let roots = model.roots
        let pipeline = previewPipeline
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let photo = try catalog.photo(id) else { throw MCPToolProblem.photoUnavailable }
            guard photo.revision == sourceRevision, photo.recipeRevision == recipeRevision else { throw MCPToolProblem.stalePhoto }
            guard photo.availability == "available", let root = roots.first(where: { $0.id == photo.rootID }) else { throw MCPToolProblem.fileAccess }
            var recipe = try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) }
            if recipe == nil, photo.supportsEditing { recipe = try await pipeline.baseline(.init(photo: photo, root: root, recipe: nil)) }
            let rendered = try await pipeline.render(.init(photo: photo, root: root, recipe: recipe), longEdge: edge)
            try Task.checkCancellation()
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { throw MCPToolProblem.failed }
            CGImageDestinationAddImage(destination, rendered.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw MCPToolProblem.failed }
            let histogram = rendered.histogram.map { Value.array($0.channels.map { .array($0.map(Value.double)) }) } ?? .null
            return Preview(data: [
                "preview_id": .string(UUID().uuidString), "photo_id": .string(id), "source_revision": .int(sourceRevision),
                "recipe_revision": .int(recipeRevision), "width": .int(rendered.image.width), "height": .int(rendered.image.height),
                "coordinate_space": "normalized_top_left", "histogram": histogram
            ], name: String(photo.displayName.prefix(256)), png: png.base64EncodedString())
        }
        previewWorker = worker
        defer { previewWorker = nil }
        let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
        guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
        guard sharesImages, imageAccessGeneration == accessGeneration else { throw MCPToolProblem.imageDisabled }
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        let preview = try result.get()
        guard try catalog.matchesPhotoRevisions(id: id, source: sourceRevision, recipe: recipeRevision) else { throw MCPToolProblem.stalePreview }
        return .init("Rendered the saved photo preview.", data: preview.data,
                     artifacts: [["type": "photo_preview", "id": preview.data["preview_id"]!, "name": .string(preview.name)]], image: preview.png)
    }

    private func write(_ tool: AppMCPTool, arguments: [String: Value], model: AppModel) -> MCPToolResult {
        guard arguments["request_epoch"]?.stringValue == requestEpoch else { return .init(.expired, commitState: "not_committed") }
        let id = arguments["request_id"]!.stringValue!
        if let previous = writes[id] {
            guard previous.tool == tool, previous.arguments == arguments else {
                return .init(.init(code: "request_id_conflict", summary: "This request ID already has different arguments.",
                                  next: "Check the previous result and use a new request ID for a new action."), commitState: "not_committed")
            }
            return previous.result
        }
        if writes.count >= 256 {
            if workflows.isWorking { return .init(.busy, commitState: "not_committed") }
            rotateRequestEpoch()
            return .init(.expired, commitState: "not_committed")
        }
        let result: MCPToolResult
        do {
            try checkCatalog(tool, arguments: arguments, model: model)
            if tool == .undo, currentUndo?.id != arguments["operation_id"]?.stringValue { throw MCPToolProblem.undoConflict }
            if let problem = writeProblem(model) { throw problem }
            switch tool {
            case .rate: result = try rate(arguments, model: model, catalog: model.catalog!)
            case .undo: result = try undo(arguments, model: model, catalog: model.catalog!)
            default: result = try workflows.write(tool, arguments: arguments)
            }
        } catch OrganizationError.ratingConflict(let actual) {
            result = .init(.ratingConflict(actual), commitState: "not_committed")
        } catch OrganizationError.photoUnavailable {
            result = .init(.photoUnavailable, commitState: "not_committed")
        } catch let problem as MCPToolProblem {
            result = .init(problem, commitState: "not_committed")
        } catch {
            result = .init(.failed, commitState: "not_committed")
        }
        writes[id] = Write(tool: tool, arguments: arguments, result: result)
        return result
    }

    private func rotateRequestEpoch() {
        requestEpoch = UUID().uuidString
        writes.removeAll(keepingCapacity: true)
    }

    private func nativeInteraction(_ model: AppModel) -> Bool {
        let window = NSApp?.keyWindow
        let typing = window.map(WorkspaceKeyboard.isWorkspaceWindow) == true && window?.firstResponder is NSTextView
        return model.dirty || model.cropMode || model.maskGesture != nil || model.spotGesture != nil || model.directAdjustment != nil
            || model.perspectiveGuideDragOriginal != nil || model.smartMaskSession != nil || model.whiteBalanceSamplingBusy || typing
    }
    private func nativeModal(_ model: AppModel) -> Bool {
        model.presentingSheet || NSApp?.modalWindow != nil || NSApp?.windows.contains {
            $0.isVisible && $0.attachedSheet != nil && WorkspaceKeyboard.isWorkspaceWindow($0)
        } == true
    }
    private func writeProblem(_ model: AppModel) -> MCPToolProblem? {
        guard model.workspaceAvailable, !model.changingCatalogExtension, !nativeModal(model) else { return .busy }
        guard !nativeInteraction(model), model.undo.groupingLevel == 0, model.undo.isUndoRegistrationEnabled,
              !model.undo.isUndoing, !model.undo.isRedoing else { return .nativeInteraction }
        return nil
    }

    private func rate(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let id = args["photo_id"]!.stringValue!
        let expected = args["expected_rating"]!.intValue!
        let rating = args["rating"]!.intValue!
        let (receipt, refreshed) = try model.ratePhoto(id: id, expected: expected, rating: rating)
        if let receipt { currentUndo = receipt }
        let changed = receipt != nil
        let verified = (try? catalog.photoRating(id)) == rating
        let warning = !refreshed || !verified
        let summary = changed ? "Photo rating saved." : "The photo already has that rating."
        return .init(warning ? summary + " Refresh to verify the current state." : summary,
                     data: ["photo_id": .string(id), "previous_rating": .int(expected), "rating": .int(rating), "changed": .bool(changed),
                            "commit_state": changed ? "committed" : "not_committed", "operation_id": receipt.map { .string($0.id) } ?? .null],
                     warning: warning, artifacts: [["type": "photo", "id": .string(id)]])
    }
    private func undo(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        guard let receipt = currentUndo, receipt.id == args["operation_id"]?.stringValue, model.undo.canUndo,
              try catalog.photoRating(receipt.photoID) == receipt.applied else { throw MCPToolProblem.undoConflict }
        currentUndo = nil
        model.undo.undo()
        guard let restoration = receipt.restoration else { return .init(.failed, commitState: "unknown") }
        let refreshed = try restoration.get()
        let warning = !refreshed || (try? catalog.photoRating(receipt.photoID)) != receipt.previous
        return .init(warning ? "Photo rating restored. Refresh to verify the current state." : "Photo rating restored.",
                     data: ["operation_id": .string(receipt.id), "photo_id": .string(receipt.photoID),
                            "rating": .int(receipt.previous), "commit_state": "committed"], warning: warning,
                     artifacts: [["type": "photo", "id": .string(receipt.photoID)]])
    }
}
