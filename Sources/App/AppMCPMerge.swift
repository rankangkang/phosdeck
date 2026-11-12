import Foundation
import MCP

enum MCPMergeOptions {
    static let schema = MCPCanvasFields.patch([
        "align": MCPOutputSchema.boolean, "deghost": MCPOutputSchema.integer(0...3),
        "projection": MCPOutputSchema.choice(MergeProjection.allCases.map(\.rawValue)), "auto_crop": MCPOutputSchema.boolean,
        "auto_level": MCPOutputSchema.boolean, "boundary_warp": MCPDevelopParameters.numberSchema(0...100),
        "fill_edges": MCPOutputSchema.boolean, "bracket_size": MCPOutputSchema.integer(2...9),
        "source_long_edge": ["type": "integer", "enum": [0, 2000, 4000, 6000]],
        "master_format": MCPOutputSchema.choice(MergeMasterFormat.allCases.map(\.rawValue))
    ])

    static func read(_ args: [String: Value]) -> PhotoMergeOptions {
        var options = PhotoMergeOptions.defaults(for: PhotoMergeKind(rawValue: args["merge_kind"]!.stringValue!)!)
        let fields = args["options"]?.objectValue ?? [:]
        if let align = fields["align"]?.boolValue { options.align = align }
        if let deghost = fields["deghost"]?.intValue { options.deghost = deghost }
        if let projection = fields["projection"]?.stringValue.flatMap(MergeProjection.init(rawValue:)) { options.projection = projection }
        if let crop = fields["auto_crop"]?.boolValue { options.autoCrop = crop }
        if let level = fields["auto_level"]?.boolValue { options.autoLevel = level }
        if let warp = fields["boundary_warp"]?.number { options.boundaryWarp = warp }
        if let fill = fields["fill_edges"]?.boolValue { options.fillEdges = fill }
        if let bracket = fields["bracket_size"]?.intValue { options.bracketSize = bracket }
        if let edge = fields["source_long_edge"]?.intValue { options.sourceLongEdge = edge }
        if let format = fields["master_format"]?.stringValue.flatMap(MergeMasterFormat.init(rawValue:)) { options.masterFormat = format }
        return options
    }

    static func describe(_ value: PhotoMergeOptions) -> Value {
        ["merge_kind": .string(value.kind.rawValue), "align": .bool(value.align), "deghost": .int(value.deghost),
         "projection": .string(value.projection.rawValue), "auto_crop": .bool(value.autoCrop),
         "auto_level": .bool(value.autoLevel), "boundary_warp": .double(value.boundaryWarp), "fill_edges": .bool(value.fillEdges),
         "bracket_size": .int(value.bracketSize), "source_long_edge": .int(value.sourceLongEdge), "master_format": .string(value.masterFormat.rawValue)]
    }
}

struct MCPMergePlan {
    let sources: MCPOutputSources
    let options: PhotoMergeOptions
    let collectionID: String?
    let defaultStem: String

    static func dimensions(_ photo: Photo) -> (width: Int, height: Int) {
        (photo.details?.orientation ?? 1) >= 5 ? (photo.height, photo.width) : (photo.width, photo.height)
    }

    static func validate(_ photos: [Photo], options: PhotoMergeOptions) throws {
        do { try options.validate(count: photos.count); try PhotoMergeEngine.validateSources(photos) }
        catch { throw MCPToolProblem.invalid(error.localizedDescription) }
        // RAW dimensions are checked by the native decode, including lens geometry.
        guard photos.first?.isRAW == false, options.kind != .panorama else { return }
        let groupSize = options.kind == .hdrPanorama ? options.bracketSize : photos.count
        for index in stride(from: 0, to: photos.count, by: groupSize) {
            let known = photos[index..<index + groupSize].map(dimensions).filter { $0.width > 0 && $0.height > 0 }
            if let first = known.first, known.contains(where: { $0 != first }) {
                throw MCPToolProblem.invalid("This merge mode requires matching oriented dimensions within each group.")
            }
        }
    }

    func filename(format: MergeMasterFormat) -> String { defaultStem + "." + format.fileExtension }
}

struct MCPPreparedMerge {
    let id: UUID
    let planID: String
    let plan: MCPMergePlan
    let engine: PhotoMergeEngine
}

struct MCPPublishedMerge {
    let url: URL
    let identity: FileIdentity
    let bookmark: Data
}

extension AppMCPTool {
    var mergeDescription: (String, String)? {
        switch self {
        case .planMerge:
            ("Plan an ordered merge of distinct originals. Provide each photo's saved source and recipe revisions, merge_kind and optional native settings. The plan retains the regular collection selected when planning, or an explicit collection_id.", "job_id, then plan_id, ordered sources, options and default_filename")
        case .renderMerge:
            ("Analyze originals and build a preview for the frozen merge plan. Poll get_job, then use its preview_id. A new render replaces the previous prepared preview.", "job_id, then preview_id and full canvas size")
        case .getMergePreview:
            ("Read the current merge preview as an sRGB PNG when image sharing is on. display_ev changes the preview only.", "preview_id, plan_id, canvas dimensions and an image/png block")
        case .saveMerge:
            ("Save a prepared merge as a float TIFF or DNG master in a merge_destination authorization. Use a new filename, optionally override master_format, and choose whether to stack with sources (default true).", "job_id, then file_id, publication, verification, catalog photo and optional stack undo")
        default: nil
        }
    }
}

extension AppMCPWorkflows {
    func planMerge(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let options = MCPMergeOptions.read(args)
        let collectionID = args["collection_id"]?.stringValue ?? model.regularCollectionID
        return start(.planMerge) { job in
            let worker = Task.detached {
                let (sources, rows) = try MCPOutputSources.capture(args, catalog: catalog)
                let photos = rows.map(\.photo)
                try MCPMergePlan.validate(photos, options: options)
                if let collectionID, try MCPCollectionState.read(catalog, id: collectionID)?.row.isSmart != false {
                    throw MCPCollectionState.unavailable
                }
                let base = (photos[0].name as NSString).deletingPathExtension
                let plan = MCPMergePlan(sources: sources, options: options, collectionID: collectionID,
                                        defaultStem: base + "-" + options.kind.suffix)
                let items = photos.enumerated().map { index, photo -> Value in
                    let size = MCPMergePlan.dimensions(photo)
                    var item = MCPDevelopPhoto.revisions(photo)
                    item.merge(["position": .int(index), "name": .string(photo.displayName), "source_id": .string(photo.sourceKey),
                                "oriented_width": .int(size.width), "oriented_height": .int(size.height), "is_raw": .bool(photo.isRAW)]) { _, value in value }
                    return .object(item)
                }
                return (plan, items)
            }
            let (plan, items) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard self.model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            self.mergePlans[job.id] = plan
            job.items = items
            job.data["plan_id"] = .string(job.id)
            job.data["options"] = MCPMergeOptions.describe(options)
            job.data["collection_id"] = collectionID.map(Value.string) ?? .null
            job.data["default_filename"] = .string(plan.filename(format: options.masterFormat))
            job.finish(.succeeded, "Planned the ordered photo merge.")
        }
    }

    func renderMerge(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let planID = args["plan_id"]!.stringValue!
        guard let plan = mergePlans[planID] else { throw MCPToolProblem.outputPlanExpired }
        return start(.renderMerge) { job in
            self.mergePreview = nil
            self.running(job, phase: "building_merge_preview")
            let worker = Task.detached { try plan.sources.resolve(catalog).map(MCPOutputSources.request) }
            let inputs = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            let engine = self.makeMergeEngine()
            let preview = try await engine.prepare(inputs, options: plan.options) { fraction, title in
                await self.progress(job, title: title, done: Int(fraction * 100), total: 100)
            }
            try Task.checkCancellation()
            guard self.model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            self.mergePreview = MCPPreparedMerge(id: preview.id, planID: planID, plan: plan, engine: engine)
            job.data.merge(Self.mergePreviewData(preview, planID: planID, ev: 0)) { _, value in value }
            job.finish(.succeeded, "The merge preview is ready.")
        }
    }

    func readMergePreview(_ args: Arguments, catalog: CatalogStore) async throws -> MCPToolResult {
        let prepared = try expectedMergePreview(args["preview_id"])
        let ev = args["display_ev"]?.number ?? 0, edge = args["long_edge"]?.intValue ?? 768
        let worker = Task.detached {
            _ = try prepared.plan.sources.resolve(catalog)
            let preview = try await prepared.engine.display(prepared.id, ev: ev, longEdge: edge)
            _ = try prepared.plan.sources.resolve(catalog)
            return (preview, try MCPOutputImage.png(preview.image))
        }
        let (preview, png) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
        _ = try expectedMergePreview(args["preview_id"])
        return .init("Read the prepared merge preview.", data: Self.mergePreviewData(preview, planID: prepared.planID, ev: ev),
                     artifacts: [["type": "merge_preview", "id": .string(preview.id.uuidString)]], image: png)
    }

    func expectedMergePreview(_ value: Value?) throws -> MCPPreparedMerge {
        guard let prepared = mergePreview, value?.stringValue == prepared.id.uuidString else {
            throw MCPToolProblem(code: "stale_merge_preview", summary: "The prepared merge preview is no longer available.",
                                 next: "Render the merge plan again and use its new preview_id.")
        }
        return prepared
    }

    nonisolated private static func mergePreviewData(_ preview: MergePreview, planID: String, ev: Double) -> Arguments {
        ["plan_id": .string(planID), "preview_id": .string(preview.id.uuidString), "display_ev": .double(ev),
         "width": .int(preview.image.width), "height": .int(preview.image.height),
         "canvas_width": .int(preview.width), "canvas_height": .int(preview.height)]
    }
}

extension AppMCPTools {
    func saveMerge(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let prepared = try workflows.expectedMergePreview(args["preview_id"])
        let plan = prepared.plan
        let grant = try workflows.grant(args["destination_access_id"], purpose: .mergeDestination)
        let format = args["master_format"]?.stringValue.flatMap(MergeMasterFormat.init(rawValue:)) ?? plan.options.masterFormat
        let filename = args["filename"]?.stringValue ?? plan.filename(format: format)
        guard PhotoMergeEngine.validFilename(filename, format: format) else {
            throw MCPToolProblem.invalid("Use a new filename matching the float TIFF or DNG format, without a folder path.")
        }
        let stack = args["stack_with_sources"]?.boolValue ?? true
        return workflows.start(.saveMerge) { job in
            self.workflows.running(job, phase: "saving_merge_master")
            _ = try await Task.detached { try plan.sources.resolve(catalog) }.value
            if let id = plan.collectionID, try MCPCollectionState.read(catalog, id: id)?.row.isSmart != false { throw MCPCollectionState.unavailable }
            let directory = grant.url.resolvingSymlinksInPath().standardizedFileURL
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) { throw MCPToolProblem.outputConflict }
            let bookmark = try AccessLease.bookmark(grant.url, readOnly: false)
            job.data.merge(["plan_id": .string(prepared.planID), "preview_id": .string(prepared.id.uuidString),
                            "name": .string(filename), "master_format": .string(format.rawValue), "published": false, "verified": false,
                            "indexed": false, "photo_id": .null, "operation_id": .null]) { _, value in value }
            do {
                let result = try await prepared.engine.save(prepared.id, to: bookmark, filename: filename, catalog: catalog,
                    stackWithSources: stack, collectionID: plan.collectionID, masterFormat: format) { fraction, title in
                        await self.workflows.progress(job, title: title, done: Int(fraction * 100), total: 100)
                    }
                self.workflows.mergePreview = nil
                job.data.merge(MCPDevelopPhoto.revisions(result.photo)) { _, value in value }
                job.data.merge(["file_id": .string(job.id), "published": true, "verified": true, "indexed": true,
                                "width": .int(result.photo.width), "height": .int(result.photo.height), "bit_depth": 32,
                                "collection_id": plan.collectionID.map(Value.string) ?? .null]) { _, value in value }
                if let identity = try? JSONDecoder().decode(FileIdentity.self, from: result.photo.identity) {
                    self.workflows.mergeFiles[job.id] = MCPPublishedMerge(url: result.url, identity: identity, bookmark: bookmark)
                }
                // The native reveal and selection methods check the busy flag.
                model.busy = false
                let refreshed = model.completePhotoMerge(result, closedUndo: true)
                model.busy = true
                job.data["workspace_refreshed"] = .bool(refreshed)
                if let before = result.previousStacks, let after = try? catalog.stacks() {
                    let current = after.first { $0.members.first == result.photo.id }
                    job.data["stack_id"] = current.map { .string($0.id) } ?? .null
                    job.data["stack_member_ids"] = .array((current?.members ?? []).map(Value.string))
                    job.data["operation_id"] = self.recordUndo(before: before, after: after,
                        describe: { ["stack_revision": organizationRevision($0)] }, read: { try $0.stacks() })
                }
                job.finish(.succeeded, "Saved, verified and indexed the float master.", committed: "committed")
            } catch let published as MergePublicationError {
                self.workflows.mergePreview = nil
                self.workflows.mergeFiles[job.id] = MCPPublishedMerge(url: published.url, identity: published.identity, bookmark: bookmark)
                model.error = published.localizedDescription
                job.data["file_id"] = .string(job.id)
                job.data["published"] = true
                job.data["verified"] = .bool(published.verified)
                job.data["follow_up"] = "Locate the preserved master and verify or import it by reference."
                job.finish(.partial, "The master was published. Catalog registration or final verification failed.",
                           committed: "committed", error: "merge_publication_incomplete")
            }
        }
    }
}
