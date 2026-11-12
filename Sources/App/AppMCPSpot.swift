import Foundation
import MCP

private extension SpotRepair {
    func mcpValue(offset: MaskPoint?, includePath: Bool = false) -> Value {
        let source = points.first.flatMap { target in
            (sourceOffset ?? offset).map { MaskPoint(target.x + $0.x, target.y + $0.y) }
        }
        var data: [String: Value] = [
            "spot_id": .string(id.uuidString), "spot_mode": .string(mode.rawValue), "enabled": .bool(enabled),
            "radius": .double(radius), "feather": .double(feather), "opacity": .double(opacity),
            "target": points.first.map(MCPCanvasFields.pointValue) ?? .null, "point_count": .int(points.count),
            "source": source.map(MCPCanvasFields.pointValue) ?? .null, "source_pinned": .bool(sourceOffset != nil)
        ]
        if includePath { data["path"] = .array(points.map(MCPCanvasFields.pointValue)) }
        return .object(data)
    }
}

extension AppMCPTools {
    func readSpots(_ args: [String: Value], model: AppModel, catalog: CatalogStore) async throws -> MCPToolResult {
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        let preview = try args["preview_id"].map { try canvasPreview($0, catalog: catalog, photo: photo, variant: "saved") }
        let requestedID = args["spot_id"]?.stringValue
        let offset = args["offset"]?.intValue ?? 0, pageSize = args["page_size"]?.intValue ?? 50
        guard requestedID == nil || (args["offset"] == nil && args["page_size"] == nil) else {
            throw MCPToolProblem.invalid("Use spot_id for one path, or offset and page_size for the list.")
        }
        let worker = Task.detached {
            let saved = try photo.recipe.map { try MCPDevelopPhoto.decode($0, for: photo).repairs } ?? []
            let spots: [SpotRepair]
            if let requestedID {
                guard let repair = saved.first(where: { $0.id == UUID(uuidString: requestedID) }) else { throw MCPToolProblem.spotUnavailable }
                spots = [repair]
            } else { spots = Array(saved.dropFirst(offset).prefix(pageSize)) }
            let items = spots.map { $0.mcpValue(offset: preview?.spotOffsets[$0.id], includePath: requestedID != nil) }
            let next = requestedID == nil && offset < saved.count - items.count ? offset + items.count : nil
            return (items, next, saved.count)
        }
        let (items, next, count) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try verifySavedCanvasRead(photo, catalog: catalog, model: model)
        if let preview { _ = try canvasPreview(.string(preview.id), catalog: catalog, photo: photo) }
        var data = MCPDevelopPhoto.revisions(photo)
        data["items"] = .array(items)
        data["total_count"] = .int(count)
        data["next_offset"] = next.map(Value.int) ?? .null
        data["coordinate_space"] = "oriented_source_normalized_top_left"
        data["selected_spot_id"] = (model.activeID == photo.id ? model.selectedSpotID : nil).map { .string($0.uuidString) } ?? .null
        return .init("Read the saved spot repairs.", data: data)
    }

    func writeSpot(_ tool: AppMCPTool, args: [String: Value], photo: Photo, model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let action = args["action"]!.stringValue!
        let id = args["spot_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let settings = Set(["spot_mode", "radius", "feather", "opacity", "enabled"])
        let provided = Set(args.keys).subtracting(["action", "catalog_session_id", "photo_id", "source_revision",
                                                  "recipe_revision", "request_id", "request_epoch", "spot_id"])
        let allowed: Set<String> = switch action {
        case "add": settings.union(["preview_id", "point", "path", "source_point"])
        case "set": settings.union(["preview_id"])
        case "move": ["preview_id", "point"]
        case "set_source": ["preview_id", "source_point"]
        case "refresh_source": ["preview_id"]
        default: []
        }
        guard provided.isSubset(of: allowed),
              (action == "add") ? args["spot_id"] == nil : id != nil else {
            throw MCPToolProblem.invalid("Supply spot_id for an existing repair and fields for the chosen action.")
        }
        if action == "select" {
            guard model.activeID == photo.id, model.active?.recipeRevision == photo.recipeRevision,
                  model.spotMode, let recipe = model.recipe, model.canEdit else {
                throw MCPToolProblem.developUnavailable
            }
            guard recipe.repairs.contains(where: { $0.id == id }) else { throw MCPToolProblem.spotUnavailable }
            model.selectSpot(id)
            return .init("Selected the repair in the native canvas.", data: ["selected_spot_id": .string(id!.uuidString)])
        }
        let point = args["point"].flatMap(MCPCanvasFields.point)
        let path = args["path"]?.arrayValue?.compactMap(MCPCanvasFields.point)
        let source = args["source_point"].flatMap(MCPCanvasFields.point)
        guard action != "add" || (point == nil) != (path == nil),
              action != "move" || point != nil, action != "set_source" || source != nil,
              action != "set" || !provided.isDisjoint(with: settings) else {
            throw MCPToolProblem.invalid("Add one point or path, move to a point, set a source_point, or change at least one brush setting.")
        }
        let requiresPreview = ["add", "move", "set_source"].contains(action)
        let preview = try (requiresPreview || args["preview_id"] != nil)
            ? canvasPreview(args["preview_id"], catalog: catalog, photo: photo, variant: "saved") : nil
        let mode = args["spot_mode"]?.stringValue.flatMap(SpotRepairMode.init(rawValue:))
        return startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: L10n.text("app.spotRemoval", defaultValue: "Spot Removal"),
                               preview: preview) { request, original, pipeline in
            var value = original
            let index = value.repairs.firstIndex(where: { $0.id == id })
            if action == "delete" {
                guard let index else { throw MCPToolProblem.spotUnavailable }
                let removed = value.repairs.remove(at: index)
                return (value, ["spot_id": .string(removed.id.uuidString), "deleted": true])
            }
            var repair: SpotRepair
            if action == "add", let preview {
                guard value.repairs.count < 128 else { throw MCPToolProblem.invalid("A photo can have up to 128 spot repairs.") }
                let points = try (point.map { [$0] } ?? path ?? []).map { try preview.sourcePoint($0, recipe: original) }
                repair = SpotRepair(points: points)
            } else {
                guard let index else { throw MCPToolProblem.spotUnavailable }
                repair = value.repairs[index]
            }
            if let mode, repair.mode != mode {
                if index != nil, repair.sourceOffset == nil {
                    if let offset = preview?.spotOffsets[repair.id] { repair.sourceOffset = offset }
                    else {
                        let rank = try await pipeline.linearRank(request)
                        repair.sourceOffset = SpotRepairMath.guides(rank, repairs: original.repairs)[repair.id]
                    }
                }
                repair.mode = mode
            }
            if let radius = args["radius"]?.number { repair.radius = radius }
            if let feather = args["feather"]?.number { repair.feather = feather }
            if let opacity = args["opacity"]?.number { repair.opacity = opacity }
            if let enabled = args["enabled"]?.boolValue { repair.enabled = enabled }
            let target = repair.points[0]
            if let source, let preview {
                let position = try preview.sourcePoint(source, recipe: original)
                repair.sourceOffset = MaskPoint(position.x - target.x, position.y - target.y)
            } else if action == "add" {
                let rank = try await pipeline.linearRank(request)
                repair.sourceOffset = SpotRepairMath.pickOffset(in: rank, repair: repair)
            } else if action == "move", let point, let preview {
                let position = try preview.sourcePoint(point, recipe: original)
                let delta = SpotPlacement.clampedMove(repair.points, from: target, to: position)
                repair.points = SpotPlacement.moved(originalPoints: repair.points, delta: delta, pinnedOffset: repair.sourceOffset).points
            } else if action == "auto_source" {
                repair.sourceOffset = nil
            } else if action == "refresh_source" {
                guard repair.enabled else { throw MCPToolProblem.invalid("Enable the repair before searching for another source.") }
                let current = repair.sourceOffset ?? preview?.spotOffsets[repair.id]
                guard let next = try await pipeline.alternateSpotSource(request, selected: repair.id, avoiding: current) else {
                    throw MCPToolProblem(code: "spot_source_unavailable", summary: "No other complete nearby source was found.",
                                         next: "Choose a source_point on a current saved preview.")
                }
                repair.sourceOffset = next
            }
            if let index { value.repairs[index] = repair } else { value.repairs.append(repair) }
            return (value, ["repair": repair.mcpValue(offset: nil), "coordinate_space": "oriented_source_normalized_top_left"])
        }
    }
}

private extension MCPToolProblem {
    static let spotUnavailable = Self(code: "spot_unavailable", summary: "The spot repair is missing from this version.",
                                      next: "Read get_spot_repairs for this photo and its current revisions.")
}
