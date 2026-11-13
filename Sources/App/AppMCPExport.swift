import Foundation
import MCP

enum MCPExportOptions {
    static let namingSchema = MCPCanvasFields.patch([
        "original_name": MCPOutputSchema.boolean, "capture_date": MCPOutputSchema.boolean,
        "prefix": MCPOutputSchema.string(240, minimum: 0), "suffix": MCPOutputSchema.string(240, minimum: 0),
        "sequence": MCPOutputSchema.boolean, "start": MCPOutputSchema.integer(0...999_999_999),
        "digits": MCPOutputSchema.integer(1...9)
    ])
    static let schema = MCPCanvasFields.patch([
        "format": MCPOutputSchema.choice(ExportFormat.allCases.map(\.rawValue)),
        "long_edge": ["anyOf": [MCPOutputSchema.integer(1...30_000), ["type": "null"]]],
        "quality": MCPDevelopParameters.numberSchema(0.1...1), "naming": namingSchema,
        "metadata_policy": MCPOutputSchema.choice(ExportMetadataPolicy.allCases.map(\.rawValue)),
        "jpeg_matte": MCPOutputSchema.choice(JPEGMatte.allCases.map(\.rawValue))
    ])
    static let specificationSchema: Value = [
        "type": "object", "required": ["title", "subfolder"], "additionalProperties": false,
        "properties": ["title": MCPOutputSchema.string(100), "subfolder": MCPOutputSchema.string(120), "options": schema,
                       "preset_id": MCPOutputSchema.string(128), "preset_revision": MCPOutputSchema.string(128)]
    ]
    static let specificationsSchema: Value = ["type": "array", "minItems": 1, "items": specificationSchema]

    static func acceptsSpecifications(_ value: Value) -> Bool {
        guard let items = value.arrayValue, !items.isEmpty else { return false }
        return items.allSatisfy { item in
            item.objectValue?["title"] != nil && item.objectValue?["subfolder"] != nil &&
                MCPDevelopParameters.accepts(item, schema: specificationSchema)
        }
    }

    static func patch(_ value: Value?, onto original: ExportOptions) throws -> ExportOptions {
        var options = original
        let fields = value?.objectValue ?? [:]
        if let format = fields["format"]?.stringValue.flatMap(ExportFormat.init(rawValue:)) { options.format = format }
        if let edge = fields["long_edge"] { options.longEdge = edge.intValue }
        if let quality = fields["quality"]?.number { options.quality = quality }
        if let policy = fields["metadata_policy"]?.stringValue.flatMap(ExportMetadataPolicy.init(rawValue:)) { options.metadataPolicy = policy }
        if let matte = fields["jpeg_matte"]?.stringValue.flatMap(JPEGMatte.init(rawValue:)) { options.jpegMatte = matte }
        if let naming = fields["naming"]?.objectValue {
            if let original = naming["original_name"]?.boolValue { options.naming.originalName = original }
            if let date = naming["capture_date"]?.boolValue { options.naming.captureDate = date }
            if let prefix = naming["prefix"]?.stringValue { options.naming.prefix = prefix }
            if let suffix = naming["suffix"]?.stringValue { options.naming.suffix = suffix }
            if let sequence = naming["sequence"]?.boolValue { options.naming.sequence = sequence }
            if let start = naming["start"]?.intValue { options.naming.start = start }
            if let digits = naming["digits"]?.intValue { options.naming.digits = digits }
        }
        do { try options.validate() }
        catch { throw MCPToolProblem.invalid(error.localizedDescription) }
        return options
    }

    static func describe(_ options: ExportOptions) -> Value {
        let name = options.naming
        return ["format": .string(options.format.rawValue), "long_edge": options.longEdge.map(Value.int) ?? .null,
                "quality": .double(options.quality), "jpeg_matte": .string(options.jpegMatte.rawValue),
                "metadata_policy": .string(options.metadataPolicy.rawValue),
                "naming": ["original_name": .bool(name.originalName), "capture_date": .bool(name.captureDate),
                           "prefix": .string(name.prefix), "suffix": .string(name.suffix), "sequence": .bool(name.sequence),
                           "start": .int(name.start), "digits": .int(name.digits)]]
    }

    static func preset(_ args: [String: Value], preferences: ExportPreferences) throws -> ExportPreset? {
        let id = args["preset_id"]?.stringValue, revision = args["preset_revision"]
        if id == nil, revision == nil { return nil }
        guard let id, let revision else { throw MCPToolProblem.invalid("Supply both preset_id and preset_revision.") }
        guard let preset = (ExportPreset.builtIns + preferences.presets).first(where: { $0.id == id }),
              organizationRevision(preset) == revision else {
            throw MCPToolProblem(code: "stale_export_preset", summary: "The export preset changed or is unavailable.",
                                 next: "Read list_export_presets for the current settings and revision.")
        }
        return preset
    }

    static func describe(_ preset: ExportPreset) -> Value {
        ["preset_id": .string(preset.id), "preset_revision": organizationRevision(preset), "name": .string(preset.name),
         "built_in": .bool(ExportPreset.builtIns.contains { $0.id == preset.id }), "options": describe(preset.options)]
    }
}

struct MCPExportPlan {
    let sources: MCPOutputSources
    let directory: URL
    let bookmark: Data
    let specifications: [ExportSpecification]
    let single: Bool
    let descriptions: [String: ExportDescription]
    let items: [Value]
    let destinationKeys: [String]
    let issues: [Value]

    var ready: Bool { issues.isEmpty }

    static func names(_ batch: ExportBatchPlan) -> [String] {
        batch.requests.map { ExportBatchPlanner.canonicalKey($0.destination) + "\0" + $0.name.filename }
    }

    static func plan(photos: [Photo], specifications: [ExportSpecification], directory: URL, single: Bool, catalog: CatalogStore) throws -> ExportBatchPlan {
        let originals = try catalog.protectedPaths().map { URL(fileURLWithPath: $0) }
        return try ExportBatchPlanner.plan(photos: photos, specifications: specifications, directory: directory,
                                           originalURLs: originals, singleDestination: single)
    }

    static func row(_ request: ExportPlanRequest) -> Value {
        var fields = MCPDevelopPhoto.revisions(request.photo)
        fields.merge(["output_id": .string(request.id), "specification_id": .string(request.specificationID),
                      "specification_title": .string(request.specificationTitle), "subfolder": .string(request.subfolder),
                      "filename": .string(request.name.filename), "sequence": request.name.sequence.map(Value.int) ?? .null,
                      "warnings": .array(request.warnings.map(Value.string)), "errors": .array(request.errors.map(Value.string))]) { _, value in value }
        return .object(fields)
    }

    func summary(id: String) -> [String: Value] {
        ["plan_id": .string(id), "ready": .bool(ready), "output_count": .int(items.count), "destination_name": .string(directory.lastPathComponent),
         "issues": .array(issues.prefix(12).map { $0 }), "issue_count": .int(issues.count),
         "specifications": .array(specifications.map { specification in
            ["specification_id": .string(specification.id), "title": .string(specification.title), "subfolder": .string(specification.subfolder),
             "options": MCPExportOptions.describe(specification.options)]
         })]
    }
}

extension AppMCPTool {
    var exportDescription: (String, String)? {
        switch self {
        case .listExportPresets:
            ("List built-in and custom export presets with their revisions and current default options.", "items, last_options, total and next_offset")
        case .editExportPreset:
            ("Create, update, rename or delete a custom export preset, or restore default current export options. Editing an existing preset requires its revision.", "saved preset or last_options, and commit_state")
        case .planExport:
            ("Check an ordered export for explicit saved photo versions and an export_destination authorization. Pass options and optional preset_id/revision for one destination, or specifications with separate subfolders for multiple outputs. Choose a black or white matte for JPEG.", "job_id, then plan_id, readiness, variants, and paged names and conflicts")
        case .getExportPreview:
            ("Read planned names and issues. With output_id, also render that saved edit with the chosen output geometry and JPEG matte as a PNG when image sharing is on.", "plan details, paged items, and optional image/png")
        case .runExport:
            ("Run a ready export plan. Phosdeck rechecks versions and names, freezes the recipe and metadata, then writes and verifies each output without replacing files.", "job_id, then actual publication and verification counts, file dimensions and durable record IDs")
        case .exportRecords:
            ("Page durable export records. Use unfinished_only to show incomplete records, or pass record_ids to read specific outputs.", "items with frozen names, options and retryable state")
        case .retryExport:
            ("Verify and retry explicitly selected export records using their original settings and location. Matching files are verified and missing files are regenerated when possible. include_completed defaults to true.", "job_id, then per-record results and counts")
        case .reauthorizeExport:
            ("Renew the original destination folder permission for specified export record_ids. Obtain an export_destination access_id for the exact parent folder of these outputs.", "job_id, then renewed records")
        default: nil
        }
    }
}

extension AppMCPWorkflows {
    func listExportPresets(_ args: Arguments) throws -> MCPToolResult {
        let preferences = try ExportPreferences.load(from: exportDefaults)
        var data = Self.page((ExportPreset.builtIns + preferences.presets).map(MCPExportOptions.describe), arguments: args)
        data["last_options"] = MCPExportOptions.describe(preferences.lastOptions)
        return .init("Read the export presets.", data: data)
    }

    func editExportPreset(_ args: Arguments) throws -> MCPToolResult {
        var preferences = try ExportPreferences.load(from: exportDefaults)
        let original = preferences
        let action = args["action"]!.stringValue!
        let hasName = args["name"] != nil, hasOptions = args["options"] != nil
        let existing = ["update", "rename", "delete"].contains(action)
        guard (action == "create" || action == "rename") == hasName,
              !hasOptions || action == "create" || action == "update", action != "update" || hasOptions,
              existing == (args["preset_id"] != nil), existing == (args["preset_revision"] != nil) else {
            throw MCPToolProblem.invalid("Provide the fields for the requested export preset action.")
        }
        let preset = try MCPExportOptions.preset(args, preferences: preferences)
        if let preset, !preferences.presets.contains(where: { $0.id == preset.id }) {
            throw MCPToolProblem.invalid("Save a new custom preset to change built-in settings.")
        }
        var savedID = preset?.id
        switch action {
        case "create", "update", "rename":
            let options = try MCPExportOptions.patch(args["options"], onto: preset?.options ?? ExportOptions())
            let name = args["name"]?.stringValue ?? preset!.name
            do { savedID = try preferences.storePreset(name: name, options: options, id: preset?.id) }
            catch { throw MCPToolProblem.invalid(error.localizedDescription) }
        case "delete":
            preferences.presets.removeAll { $0.id == preset?.id }
        default:
            preferences.lastOptions = ExportOptions()
        }
        let changed = preferences != original
        if changed { try preferences.save(to: exportDefaults) }
        return .init("Updated export settings.", data: [
            "preset_id": savedID.map(Value.string) ?? .null,
            "preset": preferences.presets.first(where: { $0.id == savedID }).map(MCPExportOptions.describe) ?? .null,
            "last_options": MCPExportOptions.describe(preferences.lastOptions),
            "commit_state": changed ? "committed" : "not_committed"
        ])
    }

    func planExport(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let grant = try grant(args["destination_access_id"], purpose: .exportDestination)
        let preferences = try ExportPreferences.load(from: exportDefaults)
        let variants = args["specifications"]?.arrayValue
        guard variants == nil || ["options", "preset_id", "preset_revision"].allSatisfy({ args[$0] == nil }) else {
            throw MCPToolProblem.invalid("Choose single output options or multiple specifications.")
        }
        let specs = try (variants?.map { $0.objectValue! } ?? [args]).map { fields in
            let preset = try MCPExportOptions.preset(fields, preferences: preferences)
            let options = try MCPExportOptions.patch(fields["options"], onto: preset?.options ?? ExportOptions())
            let specification = ExportSpecification(title: fields["title"]?.stringValue ?? preset?.name ?? "Export",
                                                    subfolder: fields["subfolder"]?.stringValue ?? "", options: options)
            do { try specification.validate(allowParent: variants == nil) }
            catch { throw MCPToolProblem.invalid(error.localizedDescription) }
            return specification
        }
        let photoCount = args["photo_ids"]!.arrayValue!.count
        guard specs.count <= 4096 / photoCount else { throw MCPToolProblem.invalid("Plan up to 4096 output files at a time.") }
        return start(.planExport) { job in
            self.running(job, phase: "checking_output_names")
            let worker = Task.detached {
                defer { withExtendedLifetime(grant) {} }
                let (sources, rows) = try MCPOutputSources.capture(args, catalog: catalog)
                let directory = grant.url.resolvingSymlinksInPath().standardizedFileURL
                let bookmark = try AccessLease.bookmark(grant.url, readOnly: false)
                let batch = try MCPExportPlan.plan(photos: rows.map(\.photo), specifications: specs, directory: directory,
                                                   single: variants == nil, catalog: catalog)
                let descriptions = specs.contains(where: { $0.options.metadataPolicy.includesDescription })
                    ? try catalog.exportDescriptions(ids: Set(rows.map { $0.photo.id })) : [:]
                let issues = batch.issues.map { Value.string($0.replacingOccurrences(of: directory.path + "/", with: "")) }
                return MCPExportPlan(sources: sources, directory: directory, bookmark: bookmark, specifications: specs, single: variants == nil,
                                     descriptions: descriptions, items: batch.requests.map(MCPExportPlan.row),
                                     destinationKeys: MCPExportPlan.names(batch), issues: issues)
            }
            let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard self.model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            self.exportPlans[job.id] = plan
            job.data.merge(plan.summary(id: job.id)) { _, value in value }
            job.items = plan.items
            job.finish(.succeeded, plan.ready ? "The export plan is ready." : "Review the output name and destination conflicts.")
        }
    }

    func readExportPreview(_ args: Arguments, catalog: CatalogStore) async throws -> MCPToolResult {
        let id = args["plan_id"]!.stringValue!
        guard let plan = exportPlans[id] else { throw MCPToolProblem.outputPlanExpired }
        var data = plan.summary(id: id)
        data.merge(Self.page(plan.items, arguments: args)) { _, value in value }
        guard let output = args["output_id"]?.stringValue else { return .init("Read the planned output names.", data: data) }
        guard let item = plan.items.first(where: { $0.objectValue?["output_id"]?.stringValue == output })?.objectValue,
              let photoID = item["photo_id"]?.stringValue,
              let spec = plan.specifications.first(where: { .string($0.id) == item["specification_id"] }) else {
            throw MCPToolProblem.invalid("Use an output_id from the requested export plan.")
        }
        let edge = min(args["long_edge"]?.intValue ?? 640, spec.options.longEdge ?? 640)
        let pipeline = outputPreviewPipeline
        let worker = Task.detached {
            let row = try plan.sources.resolve(catalog, only: photoID)[0]
            let request = try MCPOutputSources.request(row)
            let recipe: EditRecipe? = if request.recipe == nil && row.photo.isRAW { try await pipeline.baseline(request) } else { request.recipe }
            let image = try await pipeline.render(.init(photo: row.photo, root: row.root, recipe: recipe), longEdge: edge,
                jpegMatte: spec.options.format == .jpeg ? spec.options.jpegMatte : nil)
            _ = try plan.sources.resolve(catalog, only: photoID)
            return (image.image.width, image.image.height, try MCPOutputImage.png(image.image))
        }
        let (width, height, png) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
        guard exportPlans[id] != nil else { throw MCPToolProblem.outputPlanExpired }
        guard let source = item["source_revision"]?.intValue, let recipe = item["recipe_revision"]?.intValue,
              try catalog.matchesPhotoRevisions(id: photoID, source: source, recipe: recipe) else { throw MCPToolProblem.stalePhoto }
        data["output_id"] = .string(output)
        data["width"] = .int(width); data["height"] = .int(height)
        return .init("Read an output preview.", data: data, artifacts: [["type": "export_preview", "id": .string(output)]], image: png)
    }

    func runExport(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let planID = args["plan_id"]!.stringValue!
        guard let plan = exportPlans[planID] else { throw MCPToolProblem.outputPlanExpired }
        guard plan.ready else { throw MCPToolProblem.outputConflict }
        return start(.runExport) { job in
            self.running(job, phase: "freezing_export_sources")
            job.data["plan_id"] = .string(planID)
            let pipeline = self.model.pipeline
            let worker = Task.detached {
                let lease = try AccessLease(bookmark: plan.bookmark)
                defer { withExtendedLifetime(lease) {} }
                guard lease.url.resolvingSymlinksInPath().standardizedFileURL.path == plan.directory.path else { throw Self.accessExpired }
                let rows = try plan.sources.resolve(catalog)
                let batch = try MCPExportPlan.plan(photos: rows.map(\.photo), specifications: plan.specifications, directory: plan.directory,
                                                   single: plan.single, catalog: catalog)
                guard batch.isReady, MCPExportPlan.names(batch) == plan.destinationKeys else { throw MCPToolProblem.outputConflict }
                let sources = Dictionary(uniqueKeysWithValues: try rows.map { ($0.photo.id, try MCPOutputSources.request($0)) })
                var frozen: [ExportSnapshot] = []
                for (index, output) in batch.requests.enumerated() {
                    try Task.checkCancellation()
                    await self.progress(job, title: "Freezing export sources", done: index, total: batch.outputCount)
                    let description = output.options.metadataPolicy.includesDescription ? plan.descriptions[output.photo.id] ?? ExportDescription() : ExportDescription()
                    let snapshot = ExportSnapshot(id: UUID().uuidString, request: sources[output.photo.id]!, destination: output.destination,
                                                  targetBookmark: plan.bookmark, options: output.options,
                                                  metadata: ExportMetadata(descriptive: description))
                    frozen.append(try await pipeline.freezeExport(snapshot))
                }
                _ = try plan.sources.resolve(catalog)
                do { try ExportBatchPlanner.prepareDestinations(batch) }
                catch is CancellationError { throw CancellationError() }
                catch { throw MCPToolProblem.outputConflict }
                guard MCPExportPlan.names(batch) == plan.destinationKeys else { throw MCPToolProblem.outputConflict }
                return (frozen, batch.requests.map(\.id))
            }
            let (frozen, outputs) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard self.model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            try Task.checkCancellation()
            self.exportPlans[planID] = nil
            await self.executeExport(frozen, outputs: outputs, previous: [], catalog: catalog, job: job)
        }
    }

    func readExportRecords(_ args: Arguments, catalog: CatalogStore) async throws -> MCPToolResult {
        let ids = args["record_ids"]?.arrayValue?.compactMap(\.stringValue)
        let unfinished = args["unfinished_only"]?.boolValue ?? false
        let worker = Task.detached {
            if let ids {
                let history = try ExportService.history(catalog: catalog, ids: Set(ids))
                let logs = Dictionary(uniqueKeysWithValues: history.logs.map { ($0.id, $0) })
                let items = ids.compactMap { id -> Value? in
                    guard let log = logs[id] else { return ["record_id": .string(id), "state": "unavailable", "can_retry": false] }
                    return unfinished && log.state == "completed" ? nil : Self.exportRow(log.snapshot, state: log.state, error: log.error)
                }
                return Self.page(items, arguments: args)
            }
            let offset = args["offset"]?.intValue ?? 0, limit = args["page_size"]?.intValue ?? 50
            let page = try ExportService.historyPage(catalog: catalog, unfinishedOnly: unfinished, offset: offset, limit: limit)
            let logs = page.logs.map { Self.exportRow($0.snapshot, state: $0.state, error: $0.error) }
            let rejected = page.rejectedIDs.map { id -> Value in ["record_id": .string(id), "state": "unsupported", "can_retry": false] }
            let end = min(offset, page.total) + logs.count + rejected.count
            return ["items": .array(logs + rejected), "total": .int(page.total), "next_offset": end < page.total ? .int(end) : .null]
        }
        let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
        return .init("Read the saved export records.", data: data)
    }

    func retryExport(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let ids = args["record_ids"]!.arrayValue!.compactMap(\.stringValue)
        let includeCompleted = args["include_completed"]?.boolValue ?? true
        return start(.retryExport) { job in
            let history = try await Task.detached { try ExportService.history(catalog: catalog, ids: Set(ids)) }.value
            try Task.checkCancellation()
            guard self.model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            guard history.rejected.isEmpty, history.logs.count == ids.count else { throw Self.missingOutput }
            let records = Dictionary(uniqueKeysWithValues: history.logs.map { ($0.id, $0) })
            let logs = ids.compactMap { records[$0] }.filter { !$0.isArchived && (includeCompleted || $0.canRetryInBatch) }
            guard !logs.isEmpty else {
                job.finish(.succeeded, "The selected records have no incomplete outputs.")
                return
            }
            await self.executeExport(logs.map(\.snapshot), outputs: [], previous: logs, catalog: catalog, job: job)
        }
    }

    func reauthorizeExport(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let grant = try grant(args["access_id"], purpose: .exportDestination)
        let ids = args["record_ids"]!.arrayValue!.compactMap(\.stringValue)
        return start(.reauthorizeExport) { job in
            let worker = Task.detached {
                defer { withExtendedLifetime(grant) {} }
                try Task.checkCancellation()
                return try ExportService.reauthorizeTargets(ids: ids, directory: grant.url, catalog: catalog)
            }
            let renewed: [ExportSnapshot]
            do { renewed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() } }
            catch is CancellationError { throw CancellationError() }
            catch {
                self.model.error = error.localizedDescription
                throw MCPToolProblem(code: "export_location_mismatch", summary: "The selected folder could not renew the frozen export locations.",
                                     next: "Choose the original parent folder shown for these records in Phosdeck.")
            }
            job.items = renewed.map { ["record_id": .string($0.id), "filename": .string($0.destination.lastPathComponent),
                                      "destination_name": .string($0.destination.deletingLastPathComponent().lastPathComponent)] }
            job.finish(.succeeded, "Renewed permission for the original output folder.", committed: "committed")
        }
    }

    private func executeExport(_ snapshots: [ExportSnapshot], outputs: [String], previous: [ExportLog], catalog: CatalogStore, job: Job) async {
        let title = job.tool == .retryExport ? "Verify and retry" : "Export"
        model.beginExportPreparation(title)
        model.exportOperationCounts = ExportOperationCounts()
        running(job, phase: "writing_outputs")
        let ids = Set(snapshots.map(\.id))
        let reports = await makeExportService(model.pipeline).run(snapshots, catalog: catalog, step: { done, total in
            await self.progress(job, title: title, done: done, total: total)
        }, outcome: { [model] outcome in
            model.exportOperationCounts.record(outcome)
        }, observe: { observation in
            job.outputObservations[observation.id] = observation
        }, progress: { status in await MainActor.run { self.model.status = status } })
        model.reports = reports
        let observations = job.outputObservations
        job.outputObservations.removeAll()
        var counts = ExportOperationCounts()
        for observation in observations.values { counts.record(observation.outcome) }
        job.data["published_count"] = .int(counts.published)
        job.data["verified_count"] = .int(counts.verified)
        job.data["output_count"] = .int(snapshots.count)
        do {
            // Read the durable rows even if cancellation arrived after publication.
            let history = try await Task.detached { try ExportService.history(catalog: catalog, ids: ids) }.value
            let logs = Dictionary(uniqueKeysWithValues: history.logs.map { ($0.id, $0) })
            let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let result = ExportBatchResult(ids: ids, logs: history.logs, rejected: history.rejected, reports: reports,
                                           operationCounts: counts)
            model.recordExportResult(result)
            model.status = result.summary
            job.items = snapshots.enumerated().map { index, snapshot in
                let log = logs[snapshot.id]
                return Self.exportRow(log?.snapshot ?? snapshot, state: log?.state ?? "unrecorded",
                                      error: log?.error, observation: observations[snapshot.id],
                                      outputID: outputs.indices.contains(index) ? outputs[index] : nil)
            }
            job.data["recorded_count"] = .int(history.logs.count)
            job.data["completed_count"] = .int(result.completed)
            let changed = !observations.isEmpty || history.logs.contains { before[$0.id]?.state != $0.state || before[$0.id]?.error != $0.error }
            let success = result.completed == snapshots.count && observations.count == snapshots.count
            let state: Job.State = success ? .succeeded : Task.isCancelled ? .cancelled : counts.published > 0 || counts.verified > 0 ? .partial : .failed
            let message = success ? "The requested outputs were verified." : "Review the finished and incomplete output records."
            if !success { job.data["follow_up"] = "Use list_export_records or Phosdeck Output Records for recovery." }
            job.finish(state, message, committed: changed ? "committed" : "not_committed",
                       error: state == .failed || state == .partial ? "export_incomplete" : nil)
        } catch {
            job.items = snapshots.map { Self.exportRow($0, state: "unknown", error: "The saved output record could not be read.", observation: observations[$0.id]) }
            job.data["follow_up"] = "Read list_export_records before retrying or writing to the same destination."
            job.finish(.partial, "The output records could not be read back.",
                       committed: counts.published > 0 ? "committed" : "unknown", error: "export_records_unavailable")
        }
    }

    nonisolated private static func exportRow(_ snapshot: ExportSnapshot, state: String, error: String?,
                                              observation: ExportObservation? = nil, outputID: String? = nil) -> Value {
        var data = MCPDevelopPhoto.revisions(snapshot.request.photo)
        let completed = state == "completed"
        data.merge(["record_id": .string(snapshot.id), "file_id": .string(snapshot.id), "state": .string(state),
                    "filename": .string(snapshot.destination.lastPathComponent),
                    "destination_name": .string(snapshot.destination.deletingLastPathComponent().lastPathComponent),
                    "can_retry": .bool(!["unrecorded", "unknown"].contains(state)), "has_error": .bool(error != nil),
                    "options": MCPExportOptions.describe(snapshot.options), "format": .string(snapshot.options.format.rawValue),
                    "bit_depth": .int(snapshot.options.format.bitDepth), "completed": .bool(completed)]) { _, value in value }
        if let outputID { data["output_id"] = .string(outputID) }
        if let error {
            data["error"] = .string(error.contains("/") ? "See the output record in Phosdeck for details." : String(error.prefix(500)))
        }
        if let observation {
            data["outcome"] = observation.outcome == .published ? "published" : "verified"
            if let size = observation.dimensions {
                data["width"] = .int(size.width); data["height"] = .int(size.height)
            }
        }
        return .object(data)
    }

    static let missingOutput = MCPToolProblem(code: "export_record_unavailable", summary: "An output record is missing or unsupported.",
                                              next: "Read list_export_records for the current record IDs.")
}
