import Foundation
import CoreGraphics
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
    var darkPhotoIDs = Set<String>()
    let options: PhotoMergeOptions
    let collectionID: String?
    let defaultStem: String

    static func dimensions(_ photo: Photo) -> (width: Int, height: Int) {
        (photo.details?.orientation ?? 1) >= 5 ? (photo.height, photo.width) : (photo.width, photo.height)
    }

    static func validate(_ allPhotos: [Photo], options: PhotoMergeOptions,darkPhotoIDs: Set<String> = []) throws {
        guard darkPhotoIDs.isSubset(of:Set(allPhotos.map(\.id))) else { throw MCPToolProblem.invalid("Dark photo IDs must be a subset of photo_ids.") }
        let photos = allPhotos.filter { !darkPhotoIDs.contains($0.id) }
        do { try MergeDarkCalibration.validate(lights:photos,darks:allPhotos.filter { darkPhotoIDs.contains($0.id) },kind:options.kind) }
        catch { throw MCPToolProblem.invalid(error.localizedDescription) }
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
    var retouch: MCPMergeRetouchDraft? = nil
    var master: MCPOutputSources? = nil
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
            ("Plan an ordered merge of distinct originals. Include lights and optional darks in photo_ids, mark the dark subset with dark_photo_ids, and provide every photo's saved source and recipe revisions, merge_kind and optional native settings. The plan retains the regular collection selected when planning, or an explicit collection_id.", "job_id, then plan_id, ordered sources, options and default_filename")
        case .renderMerge:
            ("Analyze originals and build a preview for the frozen merge plan. Poll get_job, then use its preview_id. A new render replaces the previous prepared preview.", "job_id, then preview_id and full canvas size")
        case .getMergePreview:
            ("Read the current merge preview as an sRGB PNG when image sharing is on. display_ev changes the preview only.", "preview_id, plan_id, canvas dimensions and an image/png block")
        case .editMergeRetouch:
            ("Begin retouching a prepared preview, or reopen a saved editable master using photo_id and its source/recipe revisions. Then set source strokes, frame exclusions, comet fading or star-gap settings with preview_id, draft_id and draft_revision. Supports undo, redo, reset and cancel. All coordinates are normalized top-left on the pre-finishing canvas. Poll the job and read back the new revision before saving.", "job_id, then preview_id, draft_id, draft_revision, settings counts and history availability")
        case .getMergeRetouch:
            ("Inspect a current merge retouch draft. view=state pages through strokes; view=sources pages through source identities and estimated coverage at an optional point. Image views source/result/coverage/constraints require image sharing and source_index. Use region_pixels for an unscaled tile, or long_edge for a scaled canvas. plan_only reports native tile limits without pixels. Overlay images are display-only and use full-resolution source alpha.", "draft identity/revision, canvas coordinates, source or stroke page, and optionally an image/png block")
        case .saveMerge:
            ("Save a prepared merge as a float TIFF or DNG master in a merge_destination authorization. Use a new filename, optionally override master_format, and choose whether to stack with sources (default true).", "job_id, then file_id, publication, verification, catalog photo and optional stack undo")
        case .exportStarSequence:
            ("Export one cumulative sRGB PNG per enabled light frame from a prepared star-trail preview. Supply a merge_destination authorization, new folder name, and current draft identity and revision if retouching. The verified sequence publishes as one folder and stays outside the catalog.", "job_id, then folder identity, dimensions, publication and verification state, and ordered PNG entries")
        default: nil
        }
    }
}

extension AppMCPWorkflows {
    func planMerge(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let options = MCPMergeOptions.read(args)
        let darkIDs = Set(args["dark_photo_ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let collectionID = args["collection_id"]?.stringValue ?? model.regularCollectionID
        return start(.planMerge) { job in
            let worker = Task.detached {
                let (sources, rows) = try MCPOutputSources.capture(args, catalog: catalog)
                let photos = rows.map(\.photo)
                try MCPMergePlan.validate(photos, options: options,darkPhotoIDs:darkIDs)
                if let collectionID, try MCPCollectionState.read(catalog, id: collectionID)?.row.isSmart != false {
                    throw MCPCollectionState.unavailable
                }
                let base = (photos.first(where:{ !darkIDs.contains($0.id) })!.name as NSString).deletingPathExtension
                let plan = MCPMergePlan(sources: sources,darkPhotoIDs:darkIDs, options: options, collectionID: collectionID,
                                        defaultStem: base + "-" + options.kind.suffix)
                let items = photos.enumerated().map { index, photo -> Value in
                    let size = MCPMergePlan.dimensions(photo)
                    var item = MCPDevelopPhoto.revisions(photo)
                    item.merge(["role": .string(darkIDs.contains(photo.id) ? "dark" : "light"), "position": .int(index), "name": .string(photo.displayName), "source_id": .string(photo.sourceKey),
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
            job.data["dark_photo_ids"] = .array(darkIDs.sorted().map(Value.string))
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
            let preview = try await engine.prepare(inputs.filter { !plan.darkPhotoIDs.contains($0.photo.id) }, options: plan.options,darkInputs:inputs.filter { plan.darkPhotoIDs.contains($0.photo.id) }) { fraction, title in
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

    func exportStarSequence(_ args: Arguments,catalog: CatalogStore) throws -> MCPToolResult {
        let prepared = try expectedMergePreview(args["preview_id"])
        try MCPMergeRetouchDraft.verify(prepared.retouch,args:args,required:false)
        guard prepared.plan.options.kind == .lighten,let name = args["name"]?.stringValue,
              PhotoMergeEngine.validSequenceName(name) else {
            throw MCPToolProblem.invalid("Use a star-trail preview and a new sequence folder name.")
        }
        let grant = try self.grant(args["destination_access_id"],purpose:.mergeDestination)
        let settings = prepared.retouch?.settings ?? MergeRetouchSettings()
        return start(.exportStarSequence) { job in
            job.data["name"] = .string(name)
            job.data["published"] = false
            job.data["verified"] = false
            job.data["preview_id"] = .string(prepared.id.uuidString)
            let worker = Task.detached {
                _ = try prepared.master?.resolve(catalog)
                _ = try prepared.plan.sources.resolve(catalog)
            }
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            let bookmark = try AccessLease.bookmark(grant.url,readOnly:false)
            self.running(job,phase:"exporting_star_sequence")
            do {
                let sequence = try await prepared.engine.exportStarSequence(prepared.id,settings:settings,to:bookmark,
                    folderName:name,catalog:catalog) { fraction,title in
                        await self.progress(job,title:title,done:Int(fraction*100),total:100)
                    }
                self.recordStarSequence(sequence,bookmark:bookmark,verified:true,job:job)
                job.finish(.succeeded,"Exported and verified the cumulative star-trail PNG sequence.",committed:"committed")
            } catch let published as MergeSequencePublicationError {
                self.recordStarSequence(published.result,bookmark:bookmark,verified:false,job:job)
                job.data["follow_up"] = "Locate the published folder in Finder and verify it before use."
                self.model.reports = [published.localizedDescription]
                job.finish(.partial,"The sequence folder was published but needs verification.",committed:"committed",error:"sequence_verification_incomplete")
            }
        }
    }

    private func recordStarSequence(_ sequence: MergeSequenceResult,bookmark: Data,verified: Bool,job: Job) {
        starSequences[job.id] = MCPPublishedMerge(url:sequence.url,identity:sequence.identity,bookmark:bookmark)
        job.data.merge(["file_id":.string(job.id),"published":true,"verified":.bool(verified),
                        "width":.int(sequence.width),"height":.int(sequence.height),"frame_count":.int(sequence.frames.count)]) { _,value in value }
        job.items = sequence.frames.enumerated().map { offset,frame in
            ["frame_number":.int(offset+1),"name":.string(frame.name),"source_index":.int(frame.sourceIndex),"sha256":.string(frame.digest)]
        }
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
        try MCPMergeRetouchDraft.verify(prepared.retouch,args:args,required:false)
        let grant = try workflows.grant(args["destination_access_id"], purpose: .mergeDestination)
        let format = args["master_format"]?.stringValue.flatMap(MergeMasterFormat.init(rawValue:)) ?? plan.options.masterFormat
        let filename = args["filename"]?.stringValue ?? plan.filename(format: format)
        guard PhotoMergeEngine.validFilename(filename, format: format) else {
            throw MCPToolProblem.invalid("Use a new filename matching the float TIFF or DNG format, without a folder path.")
        }
        let stack = args["stack_with_sources"]?.boolValue ?? true
        return workflows.start(.saveMerge) { job in
            self.workflows.running(job, phase: "saving_merge_master")
            _ = try await Task.detached {
                _ = try prepared.master?.resolve(catalog)
                return try plan.sources.resolve(catalog)
            }.value
            if let id = plan.collectionID, try MCPCollectionState.read(catalog, id: id)?.row.isSmart != false { throw MCPCollectionState.unavailable }
            let directory = grant.url.resolvingSymlinksInPath().standardizedFileURL
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename).path) { throw MCPToolProblem.outputConflict }
            let bookmark = try AccessLease.bookmark(grant.url, readOnly: false)
            job.data.merge(["plan_id": .string(prepared.planID), "preview_id": .string(prepared.id.uuidString),
                            "name": .string(filename), "master_format": .string(format.rawValue), "published": false, "verified": false,
                            "indexed": false, "photo_id": .null, "operation_id": .null]) { _, value in value }
            do {
                if let draft = prepared.retouch { try await prepared.engine.setRetouchSettings(prepared.id,settings:draft.settings) }
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

struct MCPMergeRetouchDraft {
    let id = UUID().uuidString
    let initial: MergeRetouchSettings
    var settings: MergeRetouchSettings
    var revision = 0
    var past: [MergeRetouchSettings] = []
    var future: [MergeRetouchSettings] = []
    init(_ settings: MergeRetouchSettings) { initial = settings; self.settings = settings }

    static let changesSchema: Value = MCPCanvasFields.patch([
        "append_stroke": ["type":"object","additionalProperties":false,
            "required":["source_index","path","radius","hardness","opacity","operation"],
            "properties":["source_index":MCPOutputSchema.integer(0...2047),"path":MCPCanvasFields.pathSchema,
                "radius":MCPDevelopParameters.numberSchema(0.0001...0.5),"hardness":MCPCanvasFields.unit,
                "opacity":MCPCanvasFields.unit,"operation":MCPOutputSchema.choice(["keep","exclude","automatic"]) ]],
        "remove_stroke_index":MCPOutputSchema.integer(0...2047),
        "excluded_sources":["type":"array","maxItems":2047,"uniqueItems":true,"items":MCPOutputSchema.integer(0...2047)],
        "star_trails":MCPCanvasFields.patch(["gap":MCPOutputSchema.integer(0...16),
            "threshold":MCPDevelopParameters.numberSchema(0.01...1),"strength":MCPCanvasFields.unit,
            "comet_half_life":MCPOutputSchema.integer(StarTrailSettings.cometRange)])
    ])
    static func accepts(_ value: Value) -> Bool {
        guard let patch = value.objectValue,!patch.isEmpty,
              Set(patch.keys).isSubset(of:["append_stroke","remove_stroke_index","excluded_sources","star_trails"]) else { return false }
        if let value = patch["append_stroke"] {
            guard let stroke = value.objectValue,Set(stroke.keys) == ["source_index","path","radius","hardness","opacity","operation"],
                  let index = stroke["source_index"]?.intValue,(0...2047).contains(index),
                  let path = stroke["path"]?.arrayValue,(1...4096).contains(path.count),path.allSatisfy({ MCPCanvasFields.point($0) != nil }),
                  let radius = stroke["radius"]?.number,(0.0001...0.5).contains(radius),
                  let hardness = stroke["hardness"]?.number,(0...1).contains(hardness),
                  let opacity = stroke["opacity"]?.number,(0...1).contains(opacity),
                  let operation = stroke["operation"]?.stringValue,["keep","exclude","automatic"].contains(operation) else { return false }
        }
        if let value = patch["remove_stroke_index"],value.intValue.map({ (0...2047).contains($0) }) != true { return false }
        if let value = patch["excluded_sources"] {
            guard let values = value.arrayValue,values.count <= 2047,Set(values).count == values.count,
                  values.allSatisfy({ $0.intValue.map { (0...2047).contains($0) } == true }) else { return false }
        }
        if let value = patch["star_trails"] {
            guard let trails = value.objectValue,!trails.isEmpty,Set(trails.keys).isSubset(of:["gap","threshold","strength","comet_half_life"]) else { return false }
            if let value = trails["gap"],value.intValue.map({ (0...16).contains($0) }) != true { return false }
            if let value = trails["threshold"],value.number.map({ (0.01...1).contains($0) }) != true { return false }
            if let value = trails["strength"],value.number.map({ (0...1).contains($0) }) != true { return false }
            if let value = trails["comet_half_life"],value.intValue.map(StarTrailSettings.cometRange.contains) != true { return false }
        }
        return true
    }
    static let stale = MCPToolProblem(code:"stale_merge_retouch",summary:"The merge retouch draft or revision is no longer current.",
        next:"Read the latest edit job result, or begin/reopen a new draft. Use its preview_id, draft_id and draft_revision together.")
    static func verify(_ draft: Self?,args: [String:Value],required: Bool = true) throws {
        guard let draft else {
            if required || args["draft_id"] != nil || args["draft_revision"] != nil { throw stale }
            return
        }
        guard args["draft_id"]?.stringValue == draft.id,args["draft_revision"]?.intValue == draft.revision else { throw stale }
    }
    static func wantsImage(_ args: [String:Value]) -> Bool {
        !["state","sources"].contains(args["view"]?.stringValue ?? "state") && args["plan_only"]?.boolValue != true
    }
    mutating func change(_ value: MergeRetouchSettings) {
        guard settings != value else { return }
        past.append(settings); if past.count > 32 { past.removeFirst() }
        future = []; settings = value; revision += 1
    }
    mutating func apply(_ patch: [String:Value],kind: PhotoMergeKind,count: Int) throws {
        var value = settings
        if let index = patch["remove_stroke_index"]?.intValue {
            guard value.strokes.indices.contains(index) else { throw MCPToolProblem.invalid("The stroke index is outside this draft.") }
            value.strokes.remove(at:index)
        }
        if let stroke = patch["append_stroke"]?.objectValue {
            value.strokes.append(MergeRetouchStroke(source:stroke["source_index"]!.intValue!,
                points:stroke["path"]!.arrayValue!.map { MaskPoint(MCPCanvasFields.point($0)!) },
                radius:stroke["radius"]!.number!,hardness:stroke["hardness"]!.number!,opacity:stroke["opacity"]!.number!,
                restore:stroke["operation"] == "automatic",exclude:stroke["operation"] == "exclude"))
        }
        if let excluded = patch["excluded_sources"]?.arrayValue { value.excludedSources = Set(excluded.map { $0.intValue! }) }
        if let trails = patch["star_trails"]?.objectValue {
            if let gap = trails["gap"]?.intValue { value.trails.gap = gap }
            if let threshold = trails["threshold"]?.number { value.trails.threshold = threshold }
            if let strength = trails["strength"]?.number { value.trails.strength = strength }
            if let halfLife = trails["comet_half_life"]?.intValue { value.trails.cometHalfLife = halfLife }
        }
        do { try value.validate(count:count,kind:kind) }
        catch { throw MCPToolProblem.invalid("The changes are not valid for this merge kind, source count or native stroke budget.") }
        change(value)
    }
    var data: [String:Value] {
        ["draft_id":.string(id),"draft_revision":.int(revision),"stroke_count":.int(settings.strokes.count),
         "excluded_sources":.array(settings.excludedSources.sorted().map(Value.int)),
         "star_trails":["gap":.int(settings.trails.gap),"threshold":.double(settings.trails.threshold),"strength":.double(settings.trails.strength),
             "comet_half_life":.int(settings.trails.cometHalfLife)],
         "can_undo":.bool(!past.isEmpty),"can_redo":.bool(!future.isEmpty),"changed":.bool(settings != initial),
         "coordinate_space":"merge_canvas_normalized_top_left", "finishing_applied":false]
    }
    static func describe(_ stroke: MergeRetouchStroke,index: Int) -> Value {
        ["stroke_index":.int(index),"source_index":.int(stroke.source),"radius":.double(stroke.radius),
         "hardness":.double(stroke.hardness),"opacity":.double(stroke.opacity),
         "operation":.string(stroke.restore ? "automatic" : stroke.exclude ? "exclude" : "keep"),
         "path":.array(stroke.points.map { ["x":.double($0.x),"y":.double($0.y)] })]
    }
}

extension AppMCPWorkflows {
    func editMergeRetouch(_ args: Arguments,catalog: CatalogStore) throws -> MCPToolResult {
        let action = args["action"]!.stringValue!
        let source = args["source_index"]?.intValue ?? 0
        if action == "reopen" {
            guard args["preview_id"] == nil,args["draft_id"] == nil,args["draft_revision"] == nil,args["changes"] == nil,
                  let photoID = args["photo_id"]?.stringValue,let sr = args["source_revision"]?.intValue,let rr = args["recipe_revision"]?.intValue else {
                throw MCPToolProblem.invalid("Reopen requires photo_id, source_revision and recipe_revision, without a previous draft or changes.")
            }
            let collectionID = model.regularCollectionID
            return start(.editMergeRetouch) { job in
                self.mergePreview = nil
                let worker = Task.detached { try MCPOutputSources.capture([(photoID,PhotoVersionRevision(source:sr,recipe:rr))],catalog:catalog) }
                let (master,rows) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                let engine = self.makeMergeEngine()
                let restored = try await engine.reopenMerge(rows[0].photo,catalog:catalog) { fraction,title in
                    await self.progress(job,title:title,done:Int(fraction*100),total:100)
                }
                let targets = (restored.inputs+restored.darkInputs).map { ($0.photo.id,PhotoVersionRevision(source:$0.photo.revision,recipe:$0.photo.recipeRevision)) }
                let frozen = try await Task.detached { try MCPOutputSources.capture(targets,catalog:catalog).0 }.value
                let plan = MCPMergePlan(sources:frozen,darkPhotoIDs:Set(restored.darkInputs.map { $0.photo.id }),options:restored.options,collectionID:collectionID,
                    defaultStem:(rows[0].photo.name as NSString).deletingPathExtension+"-Refined")
                let draft = MCPMergeRetouchDraft(restored.project.settings)
                let image = try await engine.retouchPreview(restored.preview.id,settings:draft.settings,source:source,ev:0,progress:{ _,_ in })
                try Task.checkCancellation(); guard self.model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
                _ = try await Task.detached { try master.resolve(catalog) }.value
                let prepared = MCPPreparedMerge(id:restored.preview.id,planID:job.id,plan:plan,engine:engine,retouch:draft,master:master)
                self.mergePreview = prepared
                job.data = self.retouchData(prepared,draft:draft,width:image.width,height:image.height)
                job.finish(.succeeded,"Reopened the editable merge. Save to a new master to retain changes.")
            }
        }
        guard args["photo_id"] == nil,args["source_revision"] == nil,args["recipe_revision"] == nil else {
            throw MCPToolProblem.invalid("Photo revisions are only used by the reopen action.")
        }
        let current = try expectedMergePreview(args["preview_id"])
        guard current.plan.options.kind.supportsRetouch else { throw MCPToolProblem.invalid("This merge mode has no source retouch editor.") }
        if action == "begin" {
            guard current.retouch == nil,args["draft_id"] == nil,args["draft_revision"] == nil,args["changes"] == nil else { throw MCPMergeRetouchDraft.stale }
        } else {
            try MCPMergeRetouchDraft.verify(current.retouch,args:args)
            guard (action == "set") == (args["changes"] != nil) else { throw MCPToolProblem.invalid("Only set accepts a nonempty changes object.") }
        }
        return start(.editMergeRetouch) { job in
            let worker = Task.detached {
                _ = try current.master?.resolve(catalog)
                return try current.plan.sources.resolve(catalog)
            }
            _ = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            let initial = try await current.engine.retouchSettings(current.id)
            var draft = current.retouch ?? MCPMergeRetouchDraft(initial)
            let page = try await current.engine.retouchSources(current.id,offset:0,count:1,thumbnails:false)
            guard source < page.total else { throw MCPToolProblem.invalid("source_index is outside this merge.") }
            switch action {
            case "set": try draft.apply(args["changes"]!.objectValue!,kind:current.plan.options.kind,count:page.total)
            case "reset": draft.change(MergeRetouchSettings())
            case "undo":
                if let previous = draft.past.popLast() { draft.future.append(draft.settings); draft.settings = previous; draft.revision += 1 }
            case "redo":
                if let next = draft.future.popLast() { draft.past.append(draft.settings); draft.settings = next; draft.revision += 1 }
            case "cancel": draft.settings = draft.initial
            default: break
            }
            do {
                _ = try await current.engine.retouchPreview(current.id,settings:draft.settings,source:source,ev:0) { fraction,title in
                    await self.progress(job,title:title,done:Int(fraction*100),total:100)
                }
                try Task.checkCancellation()
                guard self.model.catalog === catalog,self.mergePreview?.id == current.id else { throw MCPToolProblem.catalogChanged }
                _ = try await Task.detached { try current.plan.sources.resolve(catalog) }.value
            } catch {
                // A cancelled/failed render must not silently change what save
                // would write. The published draft revision changes only below.
                try? await current.engine.setRetouchSettings(current.id,settings:initial)
                throw error
            }
            var prepared = current
            prepared.retouch = action == "cancel" ? nil : draft
            self.mergePreview = prepared
            job.data = self.retouchData(prepared,draft:draft,width:page.width,height:page.height)
            job.data["active"] = .bool(action != "cancel")
            job.finish(.succeeded,action == "cancel" ? "Discarded the merge retouch draft." : "Prepared the merge retouch revision.")
        }
    }

    private func retouchData(_ prepared: MCPPreparedMerge,draft: MCPMergeRetouchDraft,width: Int,height: Int) -> Arguments {
        var result = draft.data
        result.merge(["preview_id":.string(prepared.id.uuidString),"plan_id":.string(prepared.planID),
            "dark_photo_ids":.array(prepared.plan.darkPhotoIDs.sorted().map(Value.string)),
            "canvas_width":.int(width),"canvas_height":.int(height),"options":MCPMergeOptions.describe(prepared.plan.options),
            "default_filename":.string(prepared.plan.filename(format:prepared.plan.options.masterFormat))]) { _,value in value }
        return result
    }

    func readMergeRetouch(_ args: Arguments,catalog: CatalogStore) async throws -> MCPToolResult {
        guard !isWorking else { throw MCPToolProblem.busy }
        let prepared = try expectedMergePreview(args["preview_id"])
        try MCPMergeRetouchDraft.verify(prepared.retouch,args:args)
        let draft = prepared.retouch!,view = args["view"]?.stringValue ?? "state"
        guard args["region_pixels"] == nil || args["long_edge"] == nil else {
            throw MCPToolProblem.invalid("Use region_pixels for an unscaled tile or long_edge for a scaled canvas, not both.")
        }
        let offset = args["offset"]?.intValue ?? 0,count = args["page_size"]?.intValue ?? 6
        let ev = args["display_ev"]?.number ?? 0,source = args["source_index"]?.intValue ?? 0
        let worker = Task.detached { () -> MCPToolResult in
            _ = try prepared.master?.resolve(catalog); _ = try prepared.plan.sources.resolve(catalog)
            let metadata = try await prepared.engine.retouchSources(prepared.id,offset:0,count:1,thumbnails:false)
            var data = draft.data
            data.merge(["preview_id":.string(prepared.id.uuidString),"plan_id":.string(prepared.planID),
                "dark_photo_ids":.array(prepared.plan.darkPhotoIDs.sorted().map(Value.string)),
                "canvas_width":.int(metadata.width),"canvas_height":.int(metadata.height),"source_count":.int(metadata.total)]) { _,value in value }
            if view == "state" {
                guard offset <= draft.settings.strokes.count else { throw MCPToolProblem.invalid("Stroke offset is outside the current draft.") }
                var items = [Value](),points = 0
                for index in offset..<min(draft.settings.strokes.count,offset+count) {
                    let stroke = draft.settings.strokes[index]
                    if !items.isEmpty,points+stroke.points.count > 8192 { break }
                    points += stroke.points.count; items.append(MCPMergeRetouchDraft.describe(stroke,index:index))
                }
                data["items"] = .array(items); data["next_offset"] = offset+items.count < draft.settings.strokes.count ? .int(offset+items.count) : .null
                return .init("Read the current merge retouch state.",data:data)
            }
            if view == "sources" {
                guard offset <= metadata.total else { throw MCPToolProblem.invalid("Source offset is outside this merge.") }
                data["inspection_point"] = args["point"] ?? .null
                let page = try await prepared.engine.retouchSources(prepared.id,offset:offset,count:count,
                    point:args["point"].flatMap(MCPCanvasFields.point).map(MaskPoint.init),thumbnails:false)
                data["items"] = .array(page.items.map { item in
                    ["source_index":.int(item.index),"name":.string(item.name),"photo_ids":.array(item.memberIDs.map(Value.string)),
                     "coverage_at_point":item.coverage.map { .double(Double($0)) } ?? .null,
                     "excluded":.bool(draft.settings.excludedSources.contains(item.index))]
                })
                data["coverage_basis"] = "frozen_geometry_and_analysis_alpha"
                data["next_offset"] = offset+page.items.count < page.total ? .int(offset+page.items.count) : .null
                return .init("Read source identities and estimated point coverage.",data:data)
            }
            guard source < metadata.total else { throw MCPToolProblem.invalid("source_index is outside this merge.") }
            let region = try MCPNativePreviewRegion.resolve(canvas:CGSize(width:metadata.width,height:metadata.height),region:nil,
                pixelRegion:args["region_pixels"].flatMap(MCPCanvasFields.pixelRect))
            data["source_index"] = .int(source); data["view"] = .string(view); data["display_ev"] = .double(ev)
            if args["plan_only"]?.boolValue == true {
                data.merge(region.data) { _,value in value }; return .init("Planned the pre-finishing merge canvas region.",data:data)
            }
            if args["region_pixels"] != nil,!region.fits {
                throw MCPToolProblem(code:"preview_region_too_large",summary:"This native tile exceeds the image sharing limit.",
                    next:"Use the suggested region_pixels or request a scaled canvas.",details:region.data)
            }
            let overlay: MergeRetouchOverlay = view == "coverage" ? .coverage : view == "constraints" ? .constraints : .none
            let pair = try await prepared.engine.retouchPreview(prepared.id,settings:draft.settings,source:source,ev:ev,overlay:overlay,updateSettings:false,progress:{ _,_ in })
            var image = view == "source" ? pair.source : pair.result
            if let mask = pair.overlay {
                guard let context = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,
                    space:ImagePipeline.outputSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MCPToolProblem.failed }
                let rect = CGRect(x:0,y:0,width:image.width,height:image.height)
                context.draw(image,in:rect); context.draw(mask,in:rect)
                guard let combined = context.makeImage() else { throw MCPToolProblem.failed }; image = combined
            }
            if args["region_pixels"] != nil {
                guard let cropped = image.cropping(to:region.pixels) else { throw MCPToolProblem.failed }; image = cropped
                data.merge(region.data) { _,value in value }
            } else {
                let edge = args["long_edge"]?.intValue ?? 768
                let scale = min(1,Double(edge)/Double(max(image.width,image.height)))
                if scale < 1 {
                    let w = max(1,Int((Double(image.width)*scale).rounded())),h = max(1,Int((Double(image.height)*scale).rounded()))
                    guard let context = CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,
                        space:ImagePipeline.outputSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MCPToolProblem.failed }
                    context.interpolationQuality = .high; context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
                    guard let resized = context.makeImage() else { throw MCPToolProblem.failed }; image = resized
                }
                data["resolution"] = "scaled"
                data["region_pixels"] = MCPCanvasFields.pixelRectValue(CGRect(x:0,y:0,width:metadata.width,height:metadata.height))
            }
            data["width"] = .int(image.width); data["height"] = .int(image.height)
            data["overlay_is_display_only"] = .bool(overlay != .none)
            _ = try prepared.master?.resolve(catalog); _ = try prepared.plan.sources.resolve(catalog)
            return .init("Read the current merge retouch image.",data:data,image:try MCPOutputImage.png(image))
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard model.catalog === catalog,!isWorking else { throw MCPToolProblem.catalogChanged }
        let current = try expectedMergePreview(args["preview_id"])
        try MCPMergeRetouchDraft.verify(current.retouch,args:args)
        return result
    }
}
