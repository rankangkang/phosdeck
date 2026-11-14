import Foundation
import MCP

struct MCPAdjustmentBatch {
    static let maximumPhotos = 64
    private static let targetFields: [AppMCPTool.Field] = [.photo, .sourceRevision, .recipeRevision]
    private static let parameterTools: [(String, AppMCPTool)] = [
        ("global", .globalAdjustments), ("color", .colorAdjustments), ("curves", .toneCurve),
        ("zone_gains", .zoneLighting), ("detail", .detailAdjustments), ("effects", .effects)
    ]

    private static let adjustmentsSchema: Value = [
        "type": "object", "minProperties": 1, "additionalProperties": false,
        "properties": .object(Dictionary(uniqueKeysWithValues: parameterTools.map { name, tool in
            let schema = switch tool {
            case .toneCurve: MCPDevelopParameters.curvesSchema
            case .zoneLighting: MCPDevelopParameters.gainsSchema
            default: MCPDevelopParameters.schema(tool)
            }
            return (name, schema)
        }))
    ]

    static let editsSchema: Value = {
        var properties = Dictionary(uniqueKeysWithValues: targetFields.map {
            ($0.rawValue, $0.schema(for: .planAdjustmentBatch))
        })
        properties["adjustments"] = adjustmentsSchema
        return ["type": "array", "minItems": 1, "maxItems": .int(maximumPhotos), "uniqueItems": true,
                "items": ["type": "object", "additionalProperties": false, "properties": .object(properties),
                          "required": .array(properties.keys.sorted().map(Value.string))]]
    }()

    static func acceptsEdits(_ value: Value) -> Bool {
        guard let edits = value.arrayValue, (1...maximumPhotos).contains(edits.count) else { return false }
        var ids = Set<String>()
        return edits.allSatisfy { edit in
            guard let fields = edit.objectValue, fields.count == targetFields.count + 1,
                  let id = fields["photo_id"]?.stringValue, ids.insert(id).inserted, let adjustments = fields["adjustments"] else { return false }
            return targetFields.allSatisfy { field in
                fields[field.rawValue].map { field.accepts($0, for: .planAdjustmentBatch) } == true
            } && MCPDevelopParameters.accepts(adjustments, schema: adjustmentsSchema)
        }
    }

    let sources: MCPOutputSources
    let proposals: [Proposal]

    struct Proposal {
        let patch: [String: Value]
        // Freeze the small baseline of an untouched photo and any generated grain seed. Existing
        // versions re-use their saved recipe by revision, including potentially large masks.
        let unsavedBaseline: EditRecipe?
        let grainSeed: UInt32
        let changed: Bool

        func recipe(on row: MCPOutputSources.Row, pipeline: ImagePipeline) throws -> EditRecipe? {
            let photo = row.photo
            var recipe: EditRecipe
            if let unsavedBaseline { recipe = unsavedBaseline }
            else if let saved = photo.recipe { recipe = try MCPDevelopPhoto.decode(saved, for: photo) }
            else { throw MCPToolProblem.stalePhoto.forPhoto(photo.id) }
            do { try pipeline.verifySource(.init(photo: photo, root: row.root, recipe: recipe)) }
            catch is CancellationError { throw CancellationError() }
            catch { throw MCPToolProblem.fileAccess.forPhoto(photo.id) }
            guard changed else { return nil }
            try MCPAdjustmentBatch.apply(patch, to: &recipe)
            recipe.grain.seed = grainSeed
            return recipe
        }
    }

    static func propose(_ patch: [String: Value], on row: MCPOutputSources.Row,
                        pipeline: ImagePipeline) async throws -> (Proposal, Value) {
        let photo = row.photo
        do {
            let (current, defaults) = try await MCPDevelopPhoto.editRecipe(for: photo, root: row.root, pipeline: pipeline)
            var recipe = current
            try apply(patch, to: &recipe)
            let changes = recipe == current ? nil : differences(from: .object(MCPDevelopParameters.describe(current)),
                                                                to: .object(MCPDevelopParameters.describe(recipe)))
            let changed = changes != nil
            if changed {
                try await MCPDevelopPhoto.validate(recipe, previous: current, photo: photo, root: row.root,
                                                   defaults: defaults, pipeline: pipeline)
            }
            var item = MCPDevelopPhoto.revisions(photo)
            item["name"] = .string(photo.displayName)
            item["state"] = changed ? "planned" : "unchanged"
            item["changes"] = changes ?? .object([:])
            return (Proposal(patch: patch, unsavedBaseline: photo.recipe == nil ? current : nil,
                             grainSeed: recipe.grain.seed, changed: changed), .object(item))
        } catch let problem as MCPToolProblem { throw problem.forPhoto(photo.id) }
    }

    private static func apply(_ patch: [String: Value], to recipe: inout EditRecipe) throws {
        for (name, tool) in parameterTools {
            guard let fields = patch[name] else { continue }
            switch tool {
            case .toneCurve:
                for channel in MCPDevelopParameters.channels {
                    guard let points = fields.objectValue?[channel] else { continue }
                    try MCPDevelopParameters.change(tool, args: ["channel": .string(channel), "action": "set", "points": points], recipe: &recipe)
                }
            case .zoneLighting:
                try MCPDevelopParameters.change(tool, args: ["gains": fields], recipe: &recipe)
            default:
                try MCPDevelopParameters.change(tool, args: ["adjustments": fields], recipe: &recipe)
            }
        }
    }

    private static func differences(from old: Value, to new: Value) -> Value? {
        if let before = old.objectValue, let after = new.objectValue {
            let changed = before.compactMap { key, value -> (String, Value)? in
                guard let updated = after[key], let change = differences(from: value, to: updated) else { return nil }
                return (key, change)
            }
            return changed.isEmpty ? nil : .object(Dictionary(uniqueKeysWithValues: changed))
        }
        return old == new ? nil : ["before": old, "after": new]
    }
}

extension AppMCPTools {
    func writeAdjustmentBatch(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let pipeline = model.pipeline
        let title = L10n.text("agent.adjustmentBatch", defaultValue: "Batch Adjustments")
        if tool == .planAdjustmentBatch {
            let edits = args["edits"]!.arrayValue!.compactMap(\.objectValue)
            let targets = edits.map { edit in
                (edit["photo_id"]!.stringValue!,
                 PhotoVersionRevision(source: edit["source_revision"]!.intValue!, recipe: edit["recipe_revision"]!.intValue!))
            }
            return workflows.start(tool) { [workflows] job in
                workflows.running(job, phase: "planning_adjustments")
                let worker = Task.detached {
                    let (sources, rows) = try MCPOutputSources.capture(targets, catalog: catalog)
                    var proposals: [MCPAdjustmentBatch.Proposal] = []
                    var items: [Value] = []
                    for (index, row) in rows.enumerated() {
                        try Task.checkCancellation()
                        await workflows.progress(job, title: title, done: index, total: rows.count)
                        let (proposal, item) = try await MCPAdjustmentBatch.propose(edits[index]["adjustments"]!.objectValue!,
                                                                                   on: row, pipeline: pipeline)
                        proposals.append(proposal)
                        items.append(item)
                    }
                    return (MCPAdjustmentBatch(sources: sources, proposals: proposals), items)
                }
                let (plan, items) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard model.catalog === catalog, model.catalogSessionID == job.session else { throw MCPToolProblem.catalogChanged }
                workflows.adjustmentPlans[job.id] = plan
                workflows.progress(job, title: title, done: items.count, total: items.count)
                job.data["plan_id"] = .string(job.id)
                job.data["changed_count"] = .int(plan.proposals.filter(\.changed).count)
                job.items = items
                job.finish(.succeeded, "Planned the per-photo adjustments.")
            }
        }

        let planID = args["plan_id"]!.stringValue!
        guard let plan = workflows.adjustmentPlans[planID] else {
            throw MCPToolProblem(code: "adjustment_plan_expired", summary: "This adjustment plan has expired or was already applied.",
                                 next: "Read the current recipes before planning another adjustment batch.")
        }
        return workflows.start(tool) { [self, workflows] job in
            model.applyingAdjustments = true
            defer { model.applyingAdjustments = false }
            workflows.running(job, phase: "verifying_adjustments")
            job.data["plan_id"] = .string(planID)
            let worker = Task.detached {
                let rows = try plan.sources.resolve(catalog)
                var changes: [(photo: Photo, recipe: EditRecipe)] = []
                for (index, row) in rows.enumerated() {
                    try Task.checkCancellation()
                    await workflows.progress(job, title: title, done: index, total: rows.count)
                    if let recipe = try plan.proposals[index].recipe(on: row, pipeline: pipeline) {
                        changes.append((row.photo, recipe))
                    }
                }
                return (rows, changes)
            }
            let (rows, changes) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard model.catalog === catalog, model.catalogSessionID == job.session else { throw MCPToolProblem.catalogChanged }
            guard !model.dirty, model.undo.groupingLevel == 0, model.undo.isUndoRegistrationEnabled else { throw MCPToolProblem.nativeInteraction }

            let saved: [Photo]
            let roots = Dictionary(rows.map { ($0.root.id, $0.root) }, uniquingKeysWith: { first, _ in first })
            do {
                saved = try model.publishRecipeBatch(changes, title: title, catalog: catalog, expecting: rows.map(\.photo),
                                                     expectingRoots: Array(roots.values), closedUndo: true)
            } catch let conflict as RecipeBatchConflict {
                throw MCPToolProblem.stalePhoto.forPhoto(conflict.photoID)
            } catch OrganizationError.versionConflict { throw MCPToolProblem.stalePhoto }
            let committed = saved.isEmpty ? "not_committed" : "committed"
            job.data["commit_state"] = .string(committed)
            workflows.adjustmentPlans[planID] = nil
            let revisions = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0.recipeRevision) })
            job.data["changed_count"] = .int(saved.count)
            job.data["operation_id"] = saved.isEmpty ? .null : recordRecipeUndo(before: changes.map(\.photo).filter { revisions[$0.id] != nil }, after: saved)
            job.data["workspace_refreshed"] = .bool(saved.isEmpty || model.perform { try model.refreshAfterBatch(ids: Set(revisions.keys)) })
            job.items = rows.map { photo, _ in
                var item = MCPDevelopPhoto.revisions(photo)
                if let revision = revisions[photo.id] { item["recipe_revision"] = .int(revision) }
                item["state"] = revisions[photo.id] == nil ? "unchanged" : "updated"
                return .object(item)
            }
            workflows.progress(job, title: title, done: rows.count, total: rows.count)
            model.status = L10n.text("app.completeUpdatedPhotos", defaultValue: "\(title) complete · Updated \(saved.count)/\(rows.count) photos")
            job.finish(.succeeded, saved.isEmpty ? "The saved adjustments were unchanged." : "Saved the adjustment batch.",
                       committed: committed)
        }
    }
}
