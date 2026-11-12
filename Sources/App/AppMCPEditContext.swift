import Foundation
import MCP

enum MCPPreset {
    static func row(_ preset: AdjustmentPreset) -> Value {
        let options = try? JSONDecoder().decode(RecipePasteOptions.self, from: preset.options)
        return ["preset_id": .string(preset.id), "preset_revision": organizationRevision(preset), "name": .string(preset.name),
                "preset_group": .string(preset.groupName), "favorite": .bool(preset.favorite),
                "groups": options.map(MCPRecipeGroups.names) ?? .null, "imported_xmp": .bool(options?.importedXMP != nil)]
    }

    static func expected(_ args: [String: Value], catalog: CatalogStore) throws -> AdjustmentPreset {
        guard let id = args["preset_id"]?.stringValue, let revision = args["preset_revision"] else {
            throw MCPToolProblem.invalid("Use a preset_id and preset_revision from list_adjustment_presets.")
        }
        guard let preset = try catalog.preset(id), organizationRevision(preset) == revision else { throw MCPToolProblem.stalePreset }
        return preset
    }

    static func options(_ preset: AdjustmentPreset, selected: Value?) throws -> RecipePasteOptions {
        let defaults = try JSONDecoder().decode(RecipePasteOptions.self, from: preset.options)
        return try MCPRecipeGroups.options(selected, defaults: defaults)
    }
}

struct MCPDevelopPreview {
    let variant: String
    let record: MCPDevelopPhoto.Record?
    let preset: AdjustmentPreset?
    let group: DevelopGroup?
    let amount: Double
    let options: RecipePasteOptions?

    init(_ args: [String: Value], photo: Photo, catalog: CatalogStore) throws {
        variant = args["preview_variant"]?.stringValue ?? "saved"
        record = try MCPDevelopPhoto.record(args, photo: photo, catalog: catalog)
        group = args["group"]?.stringValue.flatMap(DevelopGroup.init(rawValue:))
        let hasPreset = args["preset_id"] != nil || args["preset_revision"] != nil
        let selectors = [record != nil, hasPreset, group != nil].filter { $0 }.count
        guard selectors <= 1, variant != "original" || selectors == 0,
              variant != "before" || (!hasPreset && group == nil),
              hasPreset || (args["amount"] == nil && args["groups"] == nil) else {
            throw MCPToolProblem.invalid("Use one preview source compatible with preview_variant.")
        }
        preset = hasPreset ? try MCPPreset.expected(args, catalog: catalog) : nil
        amount = args["amount"]?.number ?? 1
        options = try preset.map { try MCPPreset.options($0, selected: args["groups"]) }
    }

    func recipe(_ current: EditRecipe?, photo: Photo, root: StorageRoot, pipeline: ImagePipeline) async throws -> EditRecipe? {
        guard let current else {
            guard variant == "saved", record == nil, preset == nil, group == nil else { throw MCPToolProblem.unsupportedEdit }
            return nil
        }
        if variant == "original" { return current.baseline() }
        if let record {
            let value = try record.recipe(for: photo, current: current)
            return variant == "before" ? value.aligned(to: current) : value
        }
        if variant == "before" { return current.alignedBaseline() }
        if let preset {
            var value = try preset.previewRecipe(on: current, amount: amount, options: options)
            if photo.isRAW {
                let defaults = try await pipeline.rawDefaults(.init(photo: photo, root: root, recipe: current))
                value.rawDetails = value.rawDetails.supported(by: defaults)
            }
            return value
        }
        return group?.previewRecipe(in: current) ?? current
    }

    func verify(_ args: [String: Value], catalog: CatalogStore) throws {
        if let preset, try catalog.preset(preset.id) != preset { throw MCPToolProblem.stalePreset }
        if let record {
            let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
            let current = try MCPDevelopPhoto.record(args, photo: photo, catalog: catalog)
            guard current?.title == record.title, current?.data == record.data else { throw MCPToolProblem.stalePreview }
        }
    }

    var description: [String: Value] {
        ["preview_variant": .string(variant), "record": record?.description ?? .null,
         "preset_id": preset.map { .string($0.id) } ?? .null, "group": group.map { .string($0.rawValue) } ?? .null]
    }
}

extension AppMCPWorkflows {
    func listPresets(_ args: Arguments, catalog: CatalogStore, session: String) async throws -> MCPToolResult {
        let worker = Task.detached {
            let groups = Set([args["preset_group"]?.stringValue].compactMap { $0 })
            let filtered = PresetBrowser.filtered(try catalog.presets(), search: args["search"]?.stringValue ?? "",
                                                groups: groups, favoritesOnly: args["favorites_only"]?.boolValue ?? false)
            let offset = min(args["offset"]?.intValue ?? 0, filtered.count)
            let end = min(offset + (args["page_size"]?.intValue ?? 50), filtered.count)
            return ["items": .array(filtered[offset..<end].map(MCPPreset.row)), "total": .int(filtered.count),
                    "next_offset": end < filtered.count ? .int(end) : .null] as Arguments
        }
        let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        return .init("Read catalog adjustment presets.", data: data)
    }

    nonisolated static func snapshotRow(_ snapshot: EditSnapshot) -> Value {
        snapshotRow(id: snapshot.id, title: snapshot.title, createdAt: snapshot.createdAt)
    }
    nonisolated static func snapshotRow(id: String, title: String, createdAt: Double) -> Value {
        ["snapshot_id": .string(id), "title": .string(title), "created_at": .double(createdAt),
         "snapshot_revision": organizationRevision([id, title])]
    }
}

extension AppMCPTools {
    static func developViewState(_ model: AppModel) -> [String: Value] {
        let layout = model.before ? "original" : model.beforeAfter.rawValue
        let photo = model.active.flatMap { $0.id == model.activeID ? $0 : nil }
        let after = photo.map { photo -> Value in
            var data = MCPDevelopPhoto.revisions(photo)
            data["preview_ready"] = .bool(!model.before && !model.isPreviewingAdjustment && model.previewCurrent && model.image != nil)
            return .object(data)
        } ?? .null
        let reference = model.beforeReference.flatMap { reference in
            reference.photoID == photo?.id && reference.recipe.sourceDigest == model.recipe?.sourceDigest ? reference : nil
        }
        let before = photo.flatMap { photo -> Value? in
            guard layout != "off" else { return nil }
            var data = MCPDevelopPhoto.revisions(photo)
            data["kind"] = reference == nil ? "original" : "saved_edit"
            data["title"] = reference.map { .string($0.title) } ?? .null
            data["record_key"] = reference?.key.map(Value.string) ?? .null
            data["aligned_to_after"] = .bool(layout != "original" || reference != nil)
            data["preview_ready"] = .bool(model.before ? model.previewCurrent && model.image != nil : model.beforeImage != nil)
            data["status"] = .string(model.before ? model.imageStatus : model.beforeStatus)
            return .object(data)
        } ?? .null
        let preview: Value
        if let pane = model.savedEditPreview {
            preview = ["kind": "saved_edit", "record_key": model.savedEditPreviewKey.map(Value.string) ?? .null,
                       "title": .string(model.savedEditPreviewTitle), "preview_ready": .bool(pane.image != nil), "status": .string(pane.status)]
        } else if model.isPreviewingAdjustment {
            preview = ["kind": model.previewingPresetID == nil ? "hide_group" : "preset",
                       "preset_id": model.previewingPresetID.map(Value.string) ?? .null,
                       "group": model.previewingDevelopGroup.map { .string($0.rawValue) } ?? .null,
                       "preview_ready": .bool(model.previewCurrent && model.image != nil), "status": .string(model.imageStatus)]
        } else { preview = .null }
        return ["before_after": ["layout": .string(layout), "before": before, "after": after], "adjustment_preview": preview,
                "copied_adjustments_from": model.copiedAdjustmentPhoto.map { .object(MCPDevelopPhoto.revisions($0)) } ?? .null,
                "previous_adjustments_from": model.previousAdjustmentSource.map { .object(MCPDevelopPhoto.revisions($0.photo)) } ?? .null]
    }

    func writeEditContext(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        switch tool {
        case .beforeAfter, .adjustmentPreview:
            return try changeDevelopView(tool, args: args, model: model, catalog: catalog)
        case .editPreset: return try editPreset(args, model: model, catalog: catalog)
        case .saveSnapshot, .deleteSnapshot: return try editSnapshot(tool, args: args, model: model, catalog: catalog)
        case .planXMP: return try planXMP(args, model: model)
        case .importXMP: return try importXMP(args, model: model, catalog: catalog)
        default: throw MCPToolProblem.failed
        }
    }

    private func changeDevelopView(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        guard model.activeID == photo.id, model.active?.id == photo.id else { throw MCPToolProblem.developUnavailable }
        if tool == .beforeAfter {
            let layout = args["before_layout"]!.stringValue!
            let record = try MCPDevelopPhoto.record(args, photo: photo, catalog: catalog)
            guard layout == "off" || ([.single, .develop].contains(model.workspaceMode) && model.canEdit && model.canShowBeforeAfter
                                     && model.active?.recipeRevision == photo.recipeRevision) else {
                throw MCPToolProblem.developUnavailable
            }
            guard layout != "off" || record == nil else { throw MCPToolProblem.invalid("Set a comparison layout to pin a saved edit.") }
            if let record {
                model.setBeforeReference(data: record.data, photoID: photo.id, key: record.key, title: record.title)
                guard model.beforeReference?.key == record.key else { throw MCPToolProblem.savedEditUnavailable }
            } else if model.beforeReference != nil { model.resetBeforeReference() }
            if layout == "original" {
                if !model.before { model.toggleBefore() }
            } else {
                if layout == "off", model.before { model.toggleBefore() }
                model.showBeforeAfter(BeforeAfterLayout(rawValue: layout)!)
            }
        } else {
            let action = args["action"]!.stringValue!
            let selection = try MCPDevelopPreview(args, photo: photo, catalog: catalog)
            guard model.workspaceMode == .develop, model.canEdit, model.active?.recipeRevision == photo.recipeRevision else {
                throw MCPToolProblem.developUnavailable
            }
            switch action {
            case "clear" where selection.record == nil && selection.preset == nil && selection.group == nil:
                model.clearSavedEditPreview()
                model.endAdjustmentPreview()
            case "saved_edit" where selection.record != nil:
                let record = selection.record!
                guard let recipe = model.recipe else { throw MCPToolProblem.developUnavailable }
                _ = try record.recipe(for: photo, current: recipe)
                model.previewSavedEdit(data: record.data, photoID: photo.id, key: record.key, title: record.title)
            case "preset" where selection.preset != nil:
                guard model.developTool == .adjust, !model.before, model.image != nil else { throw MCPToolProblem.developUnavailable }
                model.endAdjustmentPreview(redraw: false)
                let preset = selection.preset!
                model.previewPreset(preset, amount: selection.amount, options: selection.options)
                guard model.previewingPresetID == preset.id else { throw MCPToolProblem.invalidEdit }
            case "hide_group" where selection.group != nil:
                model.beginDevelopGroupPreview(selection.group!)
                guard model.previewingDevelopGroup == selection.group else { throw MCPToolProblem.developUnavailable }
            default: throw MCPToolProblem.invalid("Supply the selector for this preview action.")
            }
        }
        var data = Self.developViewState(model)
        data["commit_state"] = "not_committed"
        return .init("Read the updated Develop view.", data: data)
    }

    private func editSnapshot(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        let old: EditSnapshot?
        if let id = args["snapshot_id"]?.stringValue {
            guard let snapshot = try catalog.snapshot(id: id, photoID: photo.id),
                  AppMCPWorkflows.snapshotRow(snapshot).objectValue?["snapshot_revision"] == args["snapshot_revision"] else {
                throw MCPToolProblem.staleSnapshot
            }
            old = snapshot
        } else {
            guard args["snapshot_revision"] == nil else { throw MCPToolProblem.invalid("Supply snapshot_id when checking a snapshot revision.") }
            old = nil
        }
        let id: String
        let saved: EditSnapshot?
        let refreshed: Bool
        let operation: Value
        if tool == .deleteSnapshot, let old {
            id = old.id
            refreshed = try model.setSnapshotPresence(old, present: false, catalog: catalog, closedUndo: true)
            saved = nil
            operation = recordUndo(before: old as EditSnapshot?, after: nil, describe: {
                ["snapshot_id": .string(id), "snapshot": $0.map(AppMCPWorkflows.snapshotRow) ?? .null]
            }, read: { try $0.snapshot(id: id, photoID: photo.id) })
        } else {
            let name = try Self.editName(args["name"])
            if let old {
                id = old.id
                var snapshot = old
                if old.title != name {
                    try catalog.renameSnapshot(id: id, photoID: photo.id, title: name)
                    snapshot.title = name
                }
                saved = snapshot
            } else {
                guard photo.recipe != nil else {
                    throw MCPToolProblem(code: "no_saved_recipe", summary: "This photo has no saved adjustments to snapshot.", next: "Open the photo in Develop or save an adjustment first.")
                }
                let snapshot = try catalog.createSnapshot(photoID: photo.id, title: name)
                id = snapshot.id; saved = snapshot
            }
            refreshed = photo.id != model.activeID || model.perform { try model.reloadEditContext() }
            operation = .null
        }
        return .init("Updated the photo's snapshots.", data: [
            "photo_id": .string(photo.id), "snapshot_id": .string(id), "snapshot": saved.map(AppMCPWorkflows.snapshotRow) ?? .null,
            "operation_id": operation, "commit_state": old == saved ? "not_committed" : "committed",
            "workspace_refreshed": .bool(refreshed)
        ], warning: !refreshed)
    }

    private static func editName(_ value: Value?) throws -> String {
        let name = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...100).contains(name.count) else { throw MCPToolProblem.invalid("Use a name of 1 to 100 characters.") }
        return name
    }

    private func editPreset(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let action = args["action"]!.stringValue!
        let fields = Set(args.keys).subtracting(["action", "catalog_session_id", "request_id", "request_epoch"])
        let sourceFields: Set<String> = ["photo_id", "source_revision", "recipe_revision", "groups"]
        let existing: Set<String> = ["preset_id", "preset_revision"]
        let needed: Set<String> = switch action {
        case "create": sourceFields.union(["name"])
        case "update": sourceFields.union(existing)
        case "rename": existing.union(["name"])
        case "favorite": existing.union(["favorite"])
        case "move": existing.union(["preset_group"])
        default: existing
        }
        guard fields == needed || (action == "create" && fields == needed.union(["preset_group"])) else {
            throw MCPToolProblem.invalid("Supply the fields for this preset action.")
        }
        let previous = action == "create" ? nil : try MCPPreset.expected(args, catalog: catalog)
        let name = try args["name"].map { try Self.editName($0) }
        let group = args["preset_group"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard group.map({ $0.count <= 100 }) ?? true else { throw MCPToolProblem.invalid("Use up to 100 characters in a preset group name.") }

        let id: String
        var title = ""
        if action == "create" || action == "update" {
            let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
            guard let data = photo.recipe else {
                throw MCPToolProblem(code: "no_saved_recipe", summary: "This photo has no saved settings for the preset.", next: "Open the photo in Develop or save an adjustment first.")
            }
            let recipe = try MCPDevelopPhoto.decode(data, for: photo)
            let options = try MCPRecipeGroups.options(args["groups"])
            if let previous {
                id = previous.id
                title = L10n.text("app.updatePreset", defaultValue: "Update Preset")
                try catalog.updatePreset(id: id, recipe: recipe, options: options)
            } else {
                id = try catalog.savePreset(name: name!, recipe: recipe, options: options, groupName: group).id
            }
        } else {
            id = previous!.id
            switch action {
            case "rename":
                title = L10n.text("app.renamePreset", defaultValue: "Rename Preset")
                if name != previous!.name { try catalog.renamePreset(id: id, name: name!) }
            case "favorite":
                let favorite = args["favorite"]!.boolValue!
                title = favorite ? L10n.text("app.favoritePreset", defaultValue: "Favorite Preset") : L10n.text("app.unfavoritePreset", defaultValue: "Unfavorite Preset")
                try catalog.setPresetFavorite(id: id, favorite: favorite)
            case "move":
                title = L10n.text("app.movePresetGroup", defaultValue: "Move Preset Group")
                try catalog.setPresetGroup(id: id, groupName: group!)
            default:
                title = L10n.text("app.deletePreset", defaultValue: "Delete Preset")
                try catalog.deletePreset(id)
            }
        }
        model.endPresetPreview(id)
        let saved: AdjustmentPreset?
        do { saved = try catalog.preset(id) }
        catch { return .init(.failed, commitState: "unknown") }
        let changed = saved != previous
        let operation: Value
        if changed, let previous {
            model.registerPresetUndo(id: id, previous: previous, title: title, closed: true)
            operation = recordUndo(before: previous as AdjustmentPreset?, after: saved, describe: {
                ["preset_id": .string(id), "preset": $0.map(MCPPreset.row) ?? .null]
            }, read: { try $0.preset(id) })
        } else { operation = .null }
        let refreshed = model.perform { model.adjustmentPresets = try catalog.presets() }
        return .init("Updated catalog adjustment presets.", data: [
            "preset_id": .string(id), "preset": saved.map(MCPPreset.row) ?? .null, "operation_id": operation,
            "commit_state": changed ? "committed" : "not_committed", "workspace_refreshed": .bool(refreshed)
        ], warning: !refreshed)
    }

    private func planXMP(_ args: [String: Value], model: AppModel) throws -> MCPToolResult {
        let grant = try workflows.grant(args["access_id"], purpose: .xmpPresets)
        return workflows.start(.planXMP) { [workflows] job in
            workflows.running(job, phase: "reading_xmp_presets")
            let worker = Task.detached { () throws -> [XMPPresetImportItem] in
                try ([grant.lease] + grant.additionalFiles).map { lease in
                    try Task.checkCancellation()
                    return XMPPresetReader.read(lease.url)
                }
            }
            let items = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard model.catalogSessionID == job.session else { throw MCPToolProblem.catalogChanged }
            workflows.xmpPlans[job.id] = items
            job.items = items.map { item in
                ["candidate_id": .string(item.id.uuidString), "name": .string(item.title), "filename": .string(item.filename),
                 "preset_group": item.draft.map { .string($0.group) } ?? .null, "can_import": .bool(item.canImport),
                 "groups": item.draft.map { MCPRecipeGroups.names($0.settings.options) } ?? .null,
                 "issue_count": .int(item.issues.count), "issues": .array(item.issues.prefix(20).map { .string(String($0.prefix(240))) })]
            }
            job.data["plan_id"] = .string(job.id)
            job.data["eligible_count"] = .int(items.filter(\.canImport).count)
            job.finish(.succeeded, "Read the XMP conversion plan.")
        }
    }

    private func importXMP(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let id = args["plan_id"]!.stringValue!
        guard let plan = workflows.xmpPlans[id] else { throw MCPToolProblem.staleOrganizationPlan }
        let ids = args["candidate_ids"]?.arrayValue?.compactMap(\.stringValue)
        let all = args["select_all"]?.boolValue == true
        guard (ids != nil) != all else { throw MCPToolProblem.invalid("Use candidate_ids or select_all=true.") }
        let selected = plan.filter { $0.canImport && (all || ids?.contains($0.id.uuidString) == true) }
        guard !selected.isEmpty, ids.map({ selected.count == $0.count }) ?? true else {
            throw MCPToolProblem.invalid("Select importable candidates from the plan.")
        }
        let saved = try model.saveImportedPresets(selected.compactMap(\.draft), catalog: catalog, closedUndo: true)
        let imported = saved.rows.sorted { $0.id < $1.id }
        let operation: Value
        if imported.isEmpty { operation = .null }
        else {
            operation = recordUndo(before: [], after: imported, describe: { rows in
                ["items": .array(rows.map(MCPPreset.row)), "imported_count": .int(rows.count)]
            }, read: { store in try imported.compactMap { try store.preset($0.id) } })
        }
        var remaining = saved.rows
        let items: [Value] = selected.map { item in
            let draft = item.draft!
            let index = remaining.firstIndex { preset in
                let settings = (try? JSONDecoder().decode(RecipePasteOptions.self, from: preset.options))?.importedXMP
                return preset.name == draft.name && preset.groupName == draft.group && settings == draft.settings
            }
            let row = index.map { remaining.remove(at: $0) }
            return ["candidate_id": .string(item.id.uuidString), "name": .string(draft.name),
                    "state": row == nil ? "skipped_duplicate" : "imported", "preset": row.map(MCPPreset.row) ?? .null]
        }
        return .init("Imported the selected XMP presets.", data: [
            "items": .array(items), "imported_count": .int(imported.count), "skipped_count": .int(selected.count - imported.count),
            "operation_id": operation, "commit_state": imported.isEmpty ? "not_committed" : "committed",
            "workspace_refreshed": .bool(saved.refreshed)
        ], warning: !saved.refreshed)
    }
}
