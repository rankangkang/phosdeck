import Foundation
import MCP

extension AppMCPTool {
    var developDescription: (String, String)? {
        let recipeJob = "job_id, then items with actual photo revisions and results, operation_id and commit_state"
        let draftRecipeJob = recipeJob + ". A draft edit returns its current draft_id and draft_revision with commit_state=not_committed."
        switch self {
        case .photoRecipe:
            return ("Read the global parameters of an explicit photo version, a draft, or one saved history_id or snapshot_id. Omit record IDs for a draft. Use tools/list for writable ranges. Reports RAW decoder defaults when available.", "photo_id, source_revision, recipe_revision, recipe, saved, optional record and draft fields when requested")
        case .globalAdjustments:
            return ("Patch global parameters on an explicit photo version. Exposure is in EV; contrast and saturation are multipliers with neutral 1. Temperature in K or tint selects custom white balance. as_shot_white_balance=true restores both baseline values. Set pipeline_version=2 only to explicitly switch to current development.", draftRecipeJob)
        case .resetAdjustments:
            return ("Reset one Develop group. group=all performs Phosdeck's full Reset, including geometry, masks and repairs, to the current pipeline. Poll get_job.", recipeJob)
        case .toneCurve:
            return ("Edit one luminance or RGB curve. set takes 2–16 ordered points with normalized x/y, fixed first x=0 and last x=1. insert takes x/y, move takes a zero-based point_index and x/y, remove takes an interior point_index, and reset restores this channel.", recipeJob)
        case .zoneLighting:
            return ("Set all five zone gains in EV, ordered deep shadows, shadows, midtones, lights, highlights. Each is between -1 and +1.", recipeJob)
        case .colorAdjustments:
            return ("Patch HSL bands, black-and-white mixing or color grading. Omitted fields are preserved. Change color or monochrome mode with set_global_adjustments.", draftRecipeJob)
        case .detailAdjustments:
            return ("Patch general sharpening, denoise, manual defringe or supported RAW decoder controls. For RAW controls null selects the decoder default. Purple and green hue endpoints need at least 10 degrees of spacing.", recipeJob)
        case .effects:
            return ("Patch vignette or grain on the explicit photo version, using native ranges and vignette styles.", recipeJob)
        case .automaticAdjustment:
            return ("Run Phosdeck's automatic white balance or tone analysis on the current crop of the explicit photo version. Poll or cancel the job.", recipeJob)
        case .relativeExposure:
            return ("Add a nonzero EV delta to each explicit photo_id, clamping to ±5 EV. Supply expected_revisions for every target.", recipeJob)
        case .matchExposure:
            return ("Match total exposure using the source photo_id's aperture, shutter speed, ISO, decoder baseline and saved exposure. Pass distinct target photo_ids and expected_revisions for source and targets.", recipeJob)
        case .planAdjustmentBatch:
            return ("Plan a different Develop patch for each explicit photo version, without changing the active photo or saving. Supply up to \(MCPAdjustmentBatch.maximumPhotos) distinct edits with source_revision, recipe_revision and adjustments. Omitted parameters keep their current values. Poll get_job to review the changes before applying the plan.", "job_id, then plan_id, changed_count and ordered items with state and changes containing before and after values")
        case .applyAdjustmentBatch:
            return ("Save the entire reviewed plan_id from plan_adjustment_batch in one transaction. All target versions and original files are rechecked. If a target is stale or unavailable, nothing is saved. A successful commit registers one undo action for all changed photos.", recipeJob)
        case .transferAdjustments:
            return ("Copy settings from photo_id to Phosdeck's adjustment clipboard, or paste, sync from photo_id, use the previous photo's stored settings, or apply preset_id with preset_revision and optional amount (1 = 100%). Use explicit photo_ids for targets and expected_revisions for supplied photos. Choose groups, or omit groups to use the preset's saved groups. Draft transfers require action=preset and one target. Consecutive trials share a starting recipe. Use amount=0 to restore it. Other draft edits end the current preset trial.", draftRecipeJob + " Draft preset trials also return preset_trial.")
        case .beforeAfter:
            return ("Set off, original, side_by_side or split on the active photo in Develop or Single view. An optional history_id or snapshot_id pins that saved edit as the comparison baseline; omitting both restores the original baseline.", "before_after with layout, before and after, and commit_state")
        case .adjustmentPreview:
            return ("Show a saved history/snapshot in the navigator, preview a preset with optional amount and groups, hide one Develop group, or clear the temporary preview on the active photo in Develop. Use get_photo_preview for shared PNGs.", "adjustment_preview, before_after and commit_state")
        case .listPresets:
            return ("List catalog adjustment presets by name search, exact preset_group (empty means ungrouped), or favorites_only. Use each preset_id and preset_revision for preview, apply or management.", "items with preset IDs, revisions, groups and favorites, total, next_offset")
        case .editPreset:
            return ("Create, update, rename, delete, favorite or move a catalog preset. Existing presets need preset_id and preset_revision. Create/update use a photo_id, source/recipe revisions and groups. Rename/create use name. Move uses preset_group (empty clears it). Favorite uses favorite.", "preset, operation_id and commit_state")
        case .planXMP:
            return ("Parse the XMP files chosen through request_file_access purpose=xmp_presets. Poll get_job for candidate IDs and conversion diagnostics before importing.", "job_id, then plan_id and candidate items")
        case .importXMP:
            return ("Import eligible candidate_ids from an XMP plan_id, or pass select_all=true. Preserves existing presets and skips duplicates.", "imported and skipped items, operation_id and commit_state")
        case .applyEditRecord:
            return ("Restore one history_id or snapshot_id from the same photo as a new saved edit. Supply the photo's current source and recipe revisions.", recipeJob)
        case .saveSnapshot:
            return ("Create a named snapshot of an explicit saved photo, or rename an existing snapshot using snapshot_id and snapshot_revision from list_edit_records.", "snapshot, operation_id and commit_state")
        case .deleteSnapshot:
            return ("Delete an explicit snapshot by its snapshot_id and snapshot_revision. The photo remains in the catalog. The deletion can be undone.", "snapshot_id, operation_id and commit_state")
        default: return nil
        }
    }
}

extension MCPToolProblem {
    static let unsupportedEdit = Self(code: "editing_unavailable", summary: "Phosdeck cannot edit this photo format.", next: "Select a supported JPEG, TIFF, PNG or RAW version.")
    static let invalidEdit = Self(code: "invalid_adjustment", summary: "The adjustment is incompatible with this photo, pipeline or parameter range.", next: "Read get_photo_recipe and the tool schema, then check the source in Phosdeck.")
    static let savedEditUnavailable = Self(code: "edit_record_unavailable", summary: "This saved edit is unavailable for the photo version.", next: "Read list_edit_records for the same photo.")
    static let stalePreset = Self(code: "stale_preset", summary: "The preset changed or was deleted.", next: "Read list_adjustment_presets for the current revision.")
    static let staleSnapshot = Self(code: "stale_snapshot", summary: "The snapshot changed or was deleted.", next: "Read list_edit_records with record_type=snapshots.")
    static let staleDraft = Self(code: "stale_draft", summary: "The photo draft was changed or closed.", next: "Read photo_draft in get_workspace before continuing.")
    static let developUnavailable = Self(code: "view_unavailable", summary: "The requested action needs a ready canvas for this active photo.", next: "Use select_photos and set_workspace_view, then check get_workspace.")
}

enum MCPDevelopPhoto {
    static func current(_ args: [String: Value], catalog: CatalogStore) throws -> Photo {
        guard let id = args["photo_id"]?.stringValue, let photo = try catalog.photo(id) else { throw MCPToolProblem.photoUnavailable }
        if let source = args["source_revision"]?.intValue, let recipe = args["recipe_revision"]?.intValue {
            guard PhotoVersionRevision(source: source, recipe: recipe).matches(photo) else { throw MCPToolProblem.stalePhoto }
        }
        return photo
    }

    static func revisions(_ photo: Photo) -> [String: Value] {
        ["photo_id": .string(photo.id), "source_revision": .int(photo.revision), "recipe_revision": .int(photo.recipeRevision)]
    }

    struct Record {
        let data: Data
        let title: String
        let key: String
        var description: Value { ["record_key": .string(key), "title": .string(title)] }

        func recipe(for photo: Photo, current: EditRecipe? = nil) throws -> EditRecipe {
            let value = try MCPDevelopPhoto.decode(data, for: photo)
            guard current.map({ $0.sourceDigest == value.sourceDigest }) ?? (photo.digest == value.sourceDigest) else {
                throw MCPToolProblem.savedEditUnavailable
            }
            return value
        }
    }

    static func record(_ args: [String: Value], photo: Photo, catalog: CatalogStore) throws -> Record? {
        let history = args["history_id"]?.intValue.map(Int64.init), snapshot = args["snapshot_id"]?.stringValue
        guard history == nil || snapshot == nil else { throw MCPToolProblem.invalid("Choose one history_id or snapshot_id.") }
        guard history != nil || snapshot != nil else { return nil }
        guard let record = try catalog.savedEdit(photoID: photo.id, historyID: history, snapshotID: snapshot) else {
            throw MCPToolProblem.savedEditUnavailable
        }
        let key = history.map { "history:\($0)" } ?? "snapshot:" + snapshot!
        return Record(data: record.data, title: record.title, key: key)
    }

    static func decode(_ data: Data, for photo: Photo) throws -> EditRecipe {
        do {
            let recipe = try JSONDecoder().decode(EditRecipe.self, from: data)
            try recipe.validate(for: photo)
            guard photo.digest == nil || recipe.sourceDigest == photo.digest else { throw MCPToolProblem.invalidEdit }
            return recipe
        } catch { throw MCPToolProblem.invalidEdit }
    }

    static func recipe(for photo: Photo, root: StorageRoot?, pipeline: ImagePipeline) async throws -> EditRecipe {
        guard photo.supportsEditing else { throw MCPToolProblem.unsupportedEdit }
        if let data = photo.recipe { return try decode(data, for: photo) }
        guard photo.availability == "available", let root else { throw MCPToolProblem.fileAccess }
        do { return try await pipeline.baseline(.init(photo: photo, root: root, recipe: nil)) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPToolProblem.fileAccess }
    }

    static func editRecipe(for photo: Photo, root: StorageRoot, pipeline: ImagePipeline) async throws -> (EditRecipe, RAWDetailSettings?) {
        let recipe = try await recipe(for: photo, root: root, pipeline: pipeline)
        let request = ImageRequest(photo: photo, root: root, recipe: recipe)
        do {
            if photo.isRAW { return (recipe, try await pipeline.rawDefaults(request)) }
            if photo.recipe != nil { try pipeline.verifySource(request) }
            return (recipe, nil)
        } catch is CancellationError { throw CancellationError() }
        catch { throw MCPToolProblem.fileAccess }
    }

    static func validate(_ value: EditRecipe, previous: EditRecipe, photo: Photo, root: StorageRoot,
                         defaults: RAWDetailSettings?, pipeline: ImagePipeline) async throws {
        do {
            try value.validate(for: photo)
            guard value.sourceDigest == previous.sourceDigest else { throw MCPToolProblem.invalidEdit }
            if let defaults { try value.rawDetails.checkSupport(defaults) }
            if !value.hasSameGeometry(as: previous) {
                let size = try await pipeline.geometrySourceSize(.init(photo: photo, root: root, recipe: value))
                _ = try PhotoGeometry(size: size, recipe: value)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw MCPToolProblem.invalidEdit }
    }
}

struct MCPPhotoDraft: Sendable {
    struct Reference: Equatable, Sendable {
        let id: String
        let revision: Int
    }

    struct PresetTrial: Sendable {
        let baseline: EditRecipe
        let selection: Value
    }

    let id = UUID().uuidString
    let photo: Photo
    let baseline: EditRecipe
    let rawDefaults: RAWDetailSettings?
    var recipe: EditRecipe
    var revision = 0
    var presetTrial: PresetTrial?

    var reference: Reference { .init(id: id, revision: revision) }
    var fields: [String: Value] { ["draft_id": .string(id), "draft_revision": .int(revision)] }
    var data: [String: Value] {
        var data = MCPDevelopPhoto.revisions(photo).merging(fields) { _, value in value }
        data["preset_trial"] = presetTrial?.selection
        return data
    }

    func matches(_ value: Photo) -> Bool {
        photo.id == value.id && photo.revision == value.revision && photo.recipeRevision == value.recipeRevision
            && photo.rootID == value.rootID && photo.relativePath == value.relativePath
    }
}

extension AppMCPWorkflows {
    func readRecipe(_ args: Arguments, catalog: CatalogStore, session: String, draft: MCPPhotoDraft?) async throws -> MCPToolResult {
        guard draft == nil || (args["history_id"] == nil && args["snapshot_id"] == nil) else {
            throw MCPToolProblem.invalid("Choose a draft or a saved edit record.")
        }
        let roots = model.roots, pipeline = model.pipeline
        let worker = Task.detached {
            let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
            if let draft, !draft.matches(photo) { throw MCPToolProblem.stalePhoto }
            let record = try MCPDevelopPhoto.record(args, photo: photo, catalog: catalog)
            let recipe: EditRecipe
            let defaults: RAWDetailSettings?
            if let draft {
                recipe = draft.recipe
                defaults = draft.rawDefaults
            } else {
                let root = roots.first { $0.id == photo.rootID }
                if let record { recipe = try record.recipe(for: photo) }
                else { recipe = try await MCPDevelopPhoto.recipe(for: photo, root: root, pipeline: pipeline) }
                if photo.isRAW, let root { defaults = try? await pipeline.rawDefaults(.init(photo: photo, root: root, recipe: recipe)) }
                else { defaults = nil }
            }
            var data = draft?.data ?? MCPDevelopPhoto.revisions(photo)
            data["saved"] = .bool(draft == nil && (record != nil || photo.recipe != nil))
            data["record"] = record?.description ?? .null
            data["recipe"] = .object(MCPDevelopParameters.describe(recipe, rawDefaults: defaults))
            return data
        }
        let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        guard try catalog.matchesPhotoRevisions(id: data["photo_id"]!.stringValue!, source: data["source_revision"]!.intValue!,
                                                recipe: data["recipe_revision"]!.intValue!, requiringAvailable: false) else { throw MCPToolProblem.stalePhoto }
        return .init(draft == nil ? "Read the photo's development parameters." : "Read the draft's development parameters.", data: data)
    }
}

extension AppMCPTools {
    typealias CanvasRecipeEdit = @Sendable (ImageRequest, EditRecipe, ImagePipeline) async throws -> (EditRecipe, [String: Value])

    private enum RecipeEdit {
        case parameters(AppMCPTool, [String: Value])
        case automatic(AutomaticAdjustmentKind)
        case restore(MCPDevelopPhoto.Record)
        case transfer(EditRecipe, RecipePasteOptions, Double?)
        case relative(Double)
        case match(TotalExposureMatch)
        case canvas(CanvasRecipeEdit)

        func result(on photo: Photo, root: StorageRoot, pipeline: ImagePipeline, draft: MCPPhotoDraft?,
                    presetTrial: MCPPhotoDraft.PresetTrial?) async throws -> (EditRecipe?, [String], [String: Value]) {
            let original: EditRecipe
            let defaults: RAWDetailSettings?
            if let draft { (original, defaults) = (draft.recipe, draft.rawDefaults) }
            else { (original, defaults) = try await MCPDevelopPhoto.editRecipe(for: photo, root: root, pipeline: pipeline) }
            var value = original
            var notes: [String] = []
            var details: [String: Value] = [:]
            switch self {
            case let .parameters(tool, args): try MCPDevelopParameters.change(tool, args: args, recipe: &value)
            case .automatic(let kind):
                let result = try await ImagePipeline.automaticAnalysis.automaticAdjustment(.init(photo: photo, root: root, recipe: original), kind: kind)
                result.apply(to: &value)
            case .restore(let record): value = try record.recipe(for: photo, current: original)
            case let .transfer(source, options, amount):
                let base = presetTrial?.baseline ?? original
                if let presetTrial {
                    if draft?.presetTrial?.selection == presetTrial.selection { return (nil, notes, details) }
                    if amount == 0 {
                        value = base
                        break
                    }
                }
                value = try amount.map { try base.applyingPreset(source, options: options, amount: $0) } ?? base.pasting(source, options: options)
                notes = base.transferNotes(from: source, options: options)
                if options.details, !source.isRaster, let defaults {
                    notes += value.rawDetails.unavailableNames(defaults)
                    value.rawDetails = value.rawDetails.supported(by: defaults)
                }
            case .relative(let delta):
                let requested = original.exposure + delta
                value.exposure = min(5, max(-5, requested))
                if requested != value.exposure { notes.append("Exposure was limited to ±5 EV.") }
            case .match(let match):
                let exposure = try match.exposure(metadata: photo.details, recipe: original)
                value.exposure = exposure.value
                if exposure.limited { notes.append("Exposure was limited to ±5 EV.") }
            case .canvas(let edit):
                (value, details) = try await edit(.init(photo: photo, root: root, recipe: original), original, pipeline)
                if value == original { return (nil, notes, details) }
                value.schemaVersion = max(value.schemaVersion, value.localAdjustments.isEmpty ? 2 : 3)
                if value.localAdjustments.contains(where: { $0.settings != nil }) { value.maskVersion = max(value.maskVersion, 2) }
                if value.localAdjustments.contains(where: { $0.components.contains(where: { $0.raster != nil }) }) { value.maskVersion = 3 }
            }
            if value == original { return (nil, notes, details) }
            try await MCPDevelopPhoto.validate(value, previous: original, photo: photo, root: root, defaults: defaults, pipeline: pipeline)
            return (value, notes, details)
        }
    }

    private struct RecipeState: Equatable {
        let photo: Photo
        // Undo/redo adds history and advances recipeRevision. Verify the restored contents.
        static func == (lhs: Self, rhs: Self) -> Bool {
            let a = lhs.photo, b = rhs.photo
            guard a.id == b.id, a.revision == b.revision, a.identity == b.identity,
                  a.availability == b.availability, a.digest == b.digest else { return false }
            if a.recipe == b.recipe { return true }
            // A native single-photo undo can re-encode the same recipe with different JSON key order.
            guard let first = a.recipe, let second = b.recipe,
                  let left = try? JSONDecoder().decode(EditRecipe.self, from: first),
                  let right = try? JSONDecoder().decode(EditRecipe.self, from: second) else { return false }
            return left == right
        }
    }

    func startCanvasEdit(_ tool: AppMCPTool, model: AppModel, catalog: CatalogStore, photo: Photo, title: String,
                         preview: MCPCanvasPreview? = nil, draft: MCPPhotoDraft? = nil, beforeSave: @escaping () throws -> Void = {},
                         edit: @escaping CanvasRecipeEdit) -> MCPToolResult {
        startRecipeEdit(tool, model: model, catalog: catalog, targets: [photo], title: title, draft: draft, beforeSave: {
            if let preview { _ = try self.canvasPreview(.string(preview.id), catalog: catalog, photo: photo, draft: draft?.reference) }
            try beforeSave()
        }) { .canvas(edit) }
    }

    func requestedDraft(_ args: [String: Value], photo: Photo? = nil) throws -> MCPPhotoDraft? {
        guard args["draft_id"] != nil || args["draft_revision"] != nil else { return nil }
        guard let id = args["draft_id"]?.stringValue, let revision = args["draft_revision"]?.intValue else {
            throw MCPToolProblem.invalid("Supply both draft_id and draft_revision.")
        }
        guard let draft = photoDraft, draft.reference == .init(id: id, revision: revision) else { throw MCPToolProblem.staleDraft }
        if let photo, !draft.matches(photo) { throw MCPToolProblem.stalePhoto }
        return draft
    }

    func verifyPhotoDraft(_ reference: MCPPhotoDraft.Reference?) throws {
        if let reference, photoDraft?.reference != reference { throw MCPToolProblem.staleDraft }
    }

    func writePhotoDraft(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        if args["action"] == "begin" {
            guard args["photo_id"] != nil, args["source_revision"] != nil, args["recipe_revision"] != nil,
                  args["draft_id"] == nil, args["draft_revision"] == nil else {
                throw MCPToolProblem.invalid("Begin with photo_id, source_revision and recipe_revision.")
            }
            if let draft = photoDraft {
                throw MCPToolProblem(code: "draft_already_open", summary: "A photo draft is already open.",
                                     next: "Commit or cancel that draft before opening another one.", details: draft.data)
            }
            let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
            guard photo.availability == "available", let root = model.roots.first(where: { $0.id == photo.rootID }) else { throw MCPToolProblem.fileAccess }
            let pipeline = model.pipeline
            return workflows.start(.editPhotoDraft) { [self] job in
                let worker = Task.detached { try await MCPDevelopPhoto.editRecipe(for: photo, root: root, pipeline: pipeline) }
                let (recipe, defaults) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                try verifySavedCanvasRead(photo, catalog: catalog, model: model)
                let draft = MCPPhotoDraft(photo: photo, baseline: recipe, rawDefaults: defaults, recipe: recipe)
                photoDraft = draft
                job.data.merge(draft.data) { _, value in value }
                job.finish(.succeeded, "Opened a photo draft without saving an edit.")
            }
        }
        guard args["photo_id"] == nil, args["source_revision"] == nil, args["recipe_revision"] == nil,
              let draft = try requestedDraft(args) else { throw MCPToolProblem.invalid("Supply the current draft_id and draft_revision.") }
        if args["action"] == "cancel" {
            clearPhotoDraft()
            return .init("Discarded the photo draft.", data: ["discarded": true, "commit_state": "not_committed"])
        }
        try verifySavedCanvasRead(draft.photo, catalog: catalog, model: model)
        return startRecipeEdit(.editPhotoDraft, model: model, catalog: catalog, targets: [draft.photo],
                               title: L10n.text("app.adjustPhoto", defaultValue: "Adjust Photo"),
                               beforeSave: { try self.verifyPhotoDraft(draft.reference) },
                               afterSave: { self.clearPhotoDraft() }) {
            .canvas { _, original, _ in (draft.recipe == draft.baseline ? original : draft.recipe, [:]) }
        }
    }

    func recordRecipeUndo(before: [Photo], after: [Photo]) -> Value {
        let ids = Set(before.map(\.id))
        let previous = before.sorted { $0.id < $1.id }.map { RecipeState(photo: $0) }
        let saved = after.sorted { $0.id < $1.id }.map { RecipeState(photo: $0) }
        return recordUndo(before: previous, after: saved,
                          describe: { states in ["items": .array(states.map { .object(MCPDevelopPhoto.revisions($0.photo)) })] },
                          read: { try $0.photos(ids: ids).sorted { $0.id < $1.id }.map { RecipeState(photo: $0) } })
    }

    func writeRecipes(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        switch tool {
        case .relativeExposure, .matchExposure, .transferAdjustments:
            return try writeRecipeBatch(tool, args: args, model: model, catalog: catalog)
        default: break
        }
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        let draft = try requestedDraft(args, photo: photo)
        let edit: RecipeEdit
        let title: String
        switch tool {
        case .automaticAdjustment:
            let kind: AutomaticAdjustmentKind = args["action"] == "tone" ? .tone : .whiteBalance
            edit = .automatic(kind); title = kind.title
        case .applyEditRecord:
            guard let record = try MCPDevelopPhoto.record(args, photo: photo, catalog: catalog) else {
                throw MCPToolProblem.invalid("Supply a history_id or snapshot_id.")
            }
            edit = .restore(record)
            title = (args["history_id"] == nil ? L10n.text("app.restoreSnapshot", defaultValue: "Restore snapshot: ")
                     : L10n.text("app.restoreHistory", defaultValue: "Restore history: ")) + record.title
        default:
            edit = .parameters(tool, args)
            title = L10n.text("app.adjustPhoto", defaultValue: "Adjust Photo")
        }
        return startRecipeEdit(tool, model: model, catalog: catalog, targets: [photo], title: title, draft: draft) { edit }
    }

    private func writeRecipeBatch(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let ids = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let sourceID = args["photo_id"]?.stringValue
        let action = args["action"]?.stringValue
        let draft = try requestedDraft(args)
        guard draft == nil || (action == "preset" && ids.count == 1) else {
            throw MCPToolProblem.invalid("A draft transfer requires action=preset and one target photo ID.")
        }
        let requiresSource = tool == .matchExposure || action == "copy" || action == "sync"
        guard (sourceID != nil) == requiresSource, sourceID.map({ !ids.contains($0) }) ?? true,
              action == "copy" ? ids.isEmpty : !ids.isEmpty else {
            throw MCPToolProblem.invalid("Specify the explicit source and distinct target photo IDs for this action.")
        }
        if action != "preset", args["preset_id"] != nil || args["preset_revision"] != nil || args["amount"] != nil {
            throw MCPToolProblem.invalid("Preset fields apply only to action=preset.")
        }
        if action == "copy", args["groups"] != nil { throw MCPToolProblem.invalid("Choose groups when pasting the copied settings.") }
        let requested = Set(ids + [sourceID].compactMap { $0 })
        let expected = args["expected_revisions"]!.objectValue!
        guard Set(expected.keys) == requested else { throw MCPToolProblem.invalid("Supply expected_revisions for each supplied photo ID.") }
        let rows = try catalog.photos(ids: requested)
        guard rows.count == requested.count else { throw MCPToolProblem.photoUnavailable }
        for photo in rows {
            let revision = expected[photo.id]!.objectValue!
            guard revision["source_revision"]?.intValue == photo.revision, revision["recipe_revision"]?.intValue == photo.recipeRevision else {
                throw MCPToolProblem.stalePhoto
            }
        }
        let source = rows.first { $0.id == sourceID }
        let targets = rows.filter { $0.id != sourceID }.sorted { $0.id < $1.id }
        if let draft, targets.first.map(draft.matches) != true { throw MCPToolProblem.stalePhoto }
        let roots = model.roots, pipeline = model.pipeline
        if action == "copy", let source {
            return workflows.start(tool) { job in
                let recipe = try await MCPDevelopPhoto.recipe(for: source, root: roots.first { $0.id == source.rootID }, pipeline: pipeline)
                try Task.checkCancellation()
                guard model.catalog === catalog,
                      try catalog.matchesPhotoRevisions(id: source.id, source: source.revision, recipe: source.recipeRevision) else {
                    throw MCPToolProblem.stalePhoto
                }
                model.storeCopiedAdjustments(recipe, photo: source)
                job.data.merge(MCPDevelopPhoto.revisions(source)) { _, value in value }
                job.finish(.succeeded, "Copied the saved adjustment settings.")
            }
        }
        if tool == .relativeExposure {
            let delta = args["delta"]!.number!
            guard delta != 0 else { throw MCPToolProblem.invalid("Use a nonzero exposure delta.") }
            return startRecipeEdit(tool, model: model, catalog: catalog, targets: targets,
                                   title: L10n.text("app.relativeExposure", defaultValue: "Relative Exposure")) { .relative(delta) }
        }
        if tool == .matchExposure, let source {
            return startRecipeEdit(tool, model: model, catalog: catalog, targets: targets, source: source,
                                   title: L10n.text("app.matchTotalExposures", defaultValue: "Match Total Exposures")) {
                let recipe = try await MCPDevelopPhoto.recipe(for: source, root: roots.first { $0.id == source.rootID }, pipeline: pipeline)
                guard let match = try? TotalExposureMatch(metadata: source.details, recipe: recipe) else {
                    throw MCPToolProblem(code: "missing_exposure_metadata", summary: "The source needs valid aperture, shutter speed and ISO.", next: "Choose a source with complete exposure metadata.")
                }
                return .match(match)
            }
        }
        let title = L10n.text("app.pasteAdjustments", defaultValue: "Paste Adjustments")
        if action == "preset" {
            let preset = try MCPPreset.expected(args, catalog: catalog)
            let options = try MCPPreset.options(preset, selected: args["groups"])
            let amount = args["amount"]?.number ?? 1
            let trial = draft.map {
                MCPPhotoDraft.PresetTrial(baseline: $0.presetTrial?.baseline ?? $0.recipe,
                                         selection: ["preset_id": .string(preset.id), "preset_revision": args["preset_revision"]!,
                                                     "groups": MCPRecipeGroups.names(options), "amount": .double(amount)])
            }
            return startRecipeEdit(tool, model: model, catalog: catalog, targets: targets, title: preset.name, draft: draft,
                                   presetTrial: trial, beforeSave: {
                if trial != nil, try catalog.preset(preset.id) != preset { throw MCPToolProblem.stalePreset }
            }) {
                .transfer(try JSONDecoder().decode(EditRecipe.self, from: preset.recipe), options, amount)
            }
        }
        let options = try MCPRecipeGroups.options(args["groups"])
        if let source {
            return startRecipeEdit(tool, model: model, catalog: catalog, targets: targets, source: source, title: title) {
                let recipe = try await MCPDevelopPhoto.recipe(for: source, root: roots.first { $0.id == source.rootID }, pipeline: pipeline)
                return .transfer(recipe, options, nil)
            }
        }
        let cached: EditRecipe?
        if action == "previous", let previous = model.previousAdjustmentSource,
           try catalog.photo(previous.photo.id)?.revision == previous.photo.revision { cached = previous.recipe }
        else if action == "paste" { cached = model.copiedRecipe }
        else { cached = nil }
        guard let cached else { throw MCPToolProblem.invalid("There are no saved settings for this transfer source.") }
        return startRecipeEdit(tool, model: model, catalog: catalog, targets: targets, title: title) { .transfer(cached, options, nil) }
    }

    private func startRecipeEdit(_ tool: AppMCPTool, model: AppModel, catalog: CatalogStore, targets: [Photo], source: Photo? = nil,
                                 title: String, draft: MCPPhotoDraft? = nil, presetTrial: MCPPhotoDraft.PresetTrial? = nil,
                                 beforeSave: @escaping () throws -> Void = {},
                                 afterSave: @escaping () -> Void = {}, prepare: @escaping () async throws -> RecipeEdit) -> MCPToolResult {
        let roots = Dictionary(uniqueKeysWithValues: model.roots.map { ($0.id, $0) })
        let pipeline = model.pipeline
        let singleEdit = draft != nil || tool.required.contains(.sourceRevision) || tool == .editLocalPreset || tool == .editPhotoDraft
        return workflows.start(tool) { [self] job in
            model.applyingAdjustments = true
            defer { model.applyingAdjustments = false }
            workflows.running(job, phase: "preparing_adjustments")
            let edit = try await prepare()
            var changes: [(photo: Photo, recipe: EditRecipe)] = []
            var items: [[String: Value]] = []
            for (index, photo) in targets.enumerated() {
                try Task.checkCancellation()
                workflows.progress(job, title: title, done: index, total: targets.count)
                var item = MCPDevelopPhoto.revisions(photo)
                do {
                    guard photo.availability == "available", let root = roots[photo.rootID] else { throw MCPToolProblem.fileAccess }
                    let worker = Task.detached {
                        try await edit.result(on: photo, root: root, pipeline: pipeline, draft: draft, presetTrial: presetTrial)
                    }
                    let (value, notes, details) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    if let value { changes.append((photo, value)) }
                    item["state"] = value == nil ? "unchanged" : "updated"
                    item["notes"] = .array(notes.map(Value.string))
                    if !details.isEmpty { item["result"] = .object(details) }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let problem = error as? MCPToolProblem ?? .invalidEdit
                    if singleEdit { throw problem }
                    item["state"] = "skipped"
                    item["error_code"] = .string(problem.code)
                    item["reason"] = .string(problem.summary)
                }
                items.append(item)
            }
            try Task.checkCancellation()
            guard model.catalog === catalog, model.catalogSessionID == job.session else { throw MCPToolProblem.catalogChanged }
            if var draft {
                try verifyPhotoDraft(draft.reference)
                try verifySavedCanvasRead(draft.photo, catalog: catalog, model: model)
                try beforeSave()
                let updated = !changes.isEmpty || (presetTrial != nil && draft.presetTrial?.selection != presetTrial?.selection)
                if updated {
                    if let change = changes.first { draft.recipe = change.recipe }
                    draft.presetTrial = presetTrial
                    draft.revision += 1
                    photoDraft = draft
                }
                job.data.merge(draft.data) { _, value in value }
                job.data["changed_count"] = .int(changes.count)
                job.items = items.map(Value.object)
                job.finish(.succeeded, updated ? "Updated the photo draft without saving an edit." : "The draft was unchanged.")
                return
            }
            guard !model.dirty, model.undo.groupingLevel == 0, model.undo.isUndoRegistrationEnabled else { throw MCPToolProblem.nativeInteraction }
            try beforeSave()
            let after: [Photo]
            do {
                after = try model.publishRecipeBatch(changes, title: title, catalog: catalog, expecting: targets + [source].compactMap { $0 }, closedUndo: true)
            } catch let conflict as RecipeBatchConflict { throw MCPToolProblem.stalePhoto.forPhoto(conflict.photoID) }
            afterSave()

            let committed = after.isEmpty ? "not_committed" : "committed"
            job.data["commit_state"] = .string(committed)
            let revisions = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.recipeRevision) })
            job.data["workspace_refreshed"] = .bool(after.isEmpty || model.perform { try model.refreshAfterBatch(ids: Set(revisions.keys)) })
            job.data["changed_count"] = .int(after.count)
            if singleEdit, !after.isEmpty, let saved = changes.first?.recipe { job.data["recipe"] = .object(MCPDevelopParameters.describe(saved)) }
            job.data["operation_id"] = after.isEmpty ? .null : recordRecipeUndo(before: changes.map(\.photo).filter { revisions[$0.id] != nil }, after: after)
            job.items = items.map { item in
                var value = item
                if let id = item["photo_id"]?.stringValue, let revision = revisions[id] { value["recipe_revision"] = .int(revision) }
                else if item["state"] == "updated" { value["state"] = "unchanged" }
                return .object(value)
            }
            workflows.progress(job, title: title, done: targets.count, total: targets.count)
            let skipped = items.filter { $0["state"] == "skipped" }.count
            model.status = L10n.text("app.completeUpdatedPhotos", defaultValue: "\(title) complete · Updated \(after.count)/\(targets.count) photos")
            model.reports = zip(targets, items).compactMap { photo, item in
                let notes = item["reason"]?.stringValue.map { [$0] } ?? item["notes"]?.arrayValue?.compactMap(\.stringValue) ?? []
                return notes.isEmpty ? nil : photo.displayName + ": " + notes.joined(separator: " · ")
            }
            if skipped == targets.count {
                job.finish(.failed, "No photos could be adjusted.", error: "adjustment_failed")
            } else {
                job.finish(skipped > 0 ? .partial : .succeeded,
                           after.isEmpty ? "The saved adjustments were unchanged." : "Saved the photo adjustments.", committed: committed)
            }
        }
    }
}
