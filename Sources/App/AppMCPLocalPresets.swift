import Foundation
import MCP

private extension LocalParameterPreset {
    var mcpRow: Value {
        ["preset_id": .string(id), "name": .string(name), "preset_revision": organizationRevision(self)]
    }
}

extension AppMCPTools {
    func readLocalPresets(_ args: [String: Value], catalog: CatalogStore) throws -> MCPToolResult {
        let offset = args["offset"]?.intValue ?? 0, limit = args["page_size"]?.intValue ?? 50
        let presets = try catalog.localParameterPresets()
        let page = presets.dropFirst(offset).prefix(limit)
        let next = offset < presets.count - page.count ? offset + page.count : nil
        return .init("Read local adjustment presets.", data: [
            "items": .array(page.map(\.mcpRow)), "next_offset": next.map(Value.int) ?? .null, "total_count": .int(presets.count)
        ])
    }

    func transferLocal(_ tool: AppMCPTool, args: [String: Value], photo: Photo, model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        guard let mask = MCPMask.id(args["mask_id"]) else { throw MCPToolProblem.maskUnavailable }
        if args["action"] == "copy" {
            return workflows.start(tool) { job in
                let values = try await self.savedLocalParameters(photo, mask: mask, model: model, catalog: catalog)
                model.copiedLocalParameters = values
                job.data.merge(MCPDevelopPhoto.revisions(photo)) { _, value in value }
                job.data["mask_id"] = .string(mask.uuidString)
                job.finish(.succeeded, "Copied saved local adjustment values.")
            }
        }
        guard let values = model.copiedLocalParameters else { throw MCPToolProblem.invalid("Copy local adjustment values before pasting them.") }
        return applyLocalValues(tool, values: values, photo: photo, mask: mask, model: model, catalog: catalog,
                                title: L10n.text("app.pasteLocalAdjustments", defaultValue: "Paste Local Adjustments"))
    }

    func editLocalPreset(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let action = args["action"]!.stringValue!
        let source: Set<String> = ["photo_id", "source_revision", "recipe_revision", "mask_id"]
        let presetFields: Set<String> = ["preset_id", "preset_revision"]
        let required: Set<String> = switch action {
        case "create": source.union(["name"])
        case "apply": source.union(presetFields)
        case "rename": presetFields.union(["name"])
        default: presetFields
        }
        let fields = Set(args.keys).subtracting(["action", "catalog_session_id", "request_id", "request_epoch"])
        guard fields == required else { throw MCPToolProblem.invalid("Supply the fields for the chosen local preset action.") }
        let name = try MCPMask.name(args["name"])
        if action == "create" || action == "apply" {
            let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
            guard let mask = MCPMask.id(args["mask_id"]) else { throw MCPToolProblem.maskUnavailable }
            if let name {
                return workflows.start(tool) { job in
                    let values = try await self.savedLocalParameters(photo, mask: mask, model: model, catalog: catalog)
                    let preset = try catalog.saveLocalParameterPreset(name: name, values: values)
                    job.data["preset"] = preset.mcpRow
                    job.data["commit_state"] = "committed"
                    let refreshed = model.perform { model.localParameterPresets = try catalog.localParameterPresets() }
                    job.data["workspace_refreshed"] = .bool(refreshed)
                    job.finish(.succeeded, "Saved the local adjustment preset.", committed: "committed")
                }
            }
            let preset = try expectedLocalPreset(args, catalog: catalog)
            return applyLocalValues(tool, values: try preset.decodedValues(), photo: photo, mask: mask, model: model, catalog: catalog,
                                    title: L10n.text("app.applyLocalPreset", defaultValue: "Apply Local Preset: \(preset.name)"),
                                    beforeSave: { _ = try self.expectedLocalPreset(args, catalog: catalog) })
        }
        let preset = try expectedLocalPreset(args, catalog: catalog)
        let operation: Value
        let refreshed: Bool
        var saved: LocalParameterPreset? = preset
        do {
            if let name {
                if name == preset.name { refreshed = true }
                else {
                    try catalog.renameLocalParameterPreset(id: preset.id, name: name, expecting: preset)
                    saved?.name = name
                    refreshed = model.perform { model.localParameterPresets = try catalog.localParameterPresets() }
                }
                operation = .null
            } else {
                refreshed = try model.deleteLocalParameterPreset(preset, in: catalog, closedUndo: true)
                saved = nil
                operation = recordUndo(before: preset as LocalParameterPreset?, after: nil, describe: {
                    ["preset_id": .string(preset.id), "preset": $0?.mcpRow ?? .null]
                }, read: { try $0.localParameterPreset(preset.id) })
            }
        } catch OrganizationError.versionConflict { throw MCPToolProblem.staleLocalPreset }
        return .init("Updated local adjustment presets.", data: [
            "preset_id": .string(preset.id), "preset": saved?.mcpRow ?? .null, "operation_id": operation,
            "commit_state": saved == preset ? "not_committed" : "committed", "workspace_refreshed": .bool(refreshed)
        ], warning: !refreshed)
    }

    private func expectedLocalPreset(_ args: [String: Value], catalog: CatalogStore) throws -> LocalParameterPreset {
        guard let id = args["preset_id"]?.stringValue, let preset = try catalog.localParameterPreset(id),
              organizationRevision(preset) == args["preset_revision"] else { throw MCPToolProblem.staleLocalPreset }
        return preset
    }

    private func savedLocalParameters(_ photo: Photo, mask: UUID, model: AppModel, catalog: CatalogStore) async throws -> LocalParameterValues {
        let worker = Task.detached {
            guard let data = photo.recipe else { throw MCPToolProblem.maskUnavailable }
            let recipe = try MCPDevelopPhoto.decode(data, for: photo)
            return LocalParameterValues(group: recipe.localAdjustments[try MCPMask.group(mask, in: recipe)])
        }
        let values = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try verifySavedCanvasRead(photo, catalog: catalog, model: model)
        return values
    }

    private func applyLocalValues(_ tool: AppMCPTool, values: LocalParameterValues, photo: Photo, mask: UUID, model: AppModel,
                                  catalog: CatalogStore, title: String, beforeSave: @escaping () throws -> Void = {}) -> MCPToolResult {
        startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: title, beforeSave: beforeSave) { _, original, _ in
            var recipe = original
            let index = try MCPMask.group(mask, in: recipe)
            let group = try values.applying(to: recipe.localAdjustments[index])
            recipe.localAdjustments[index] = group
            return (recipe, ["mask": MCPMask.row(group, recipe: recipe)])
        }
    }
}

private extension MCPToolProblem {
    static let staleLocalPreset = Self(code: "stale_preset", summary: "The local preset changed or was deleted.",
                                       next: "Read list_local_adjustment_presets for the current revision.")
}
