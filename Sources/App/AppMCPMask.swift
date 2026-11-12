import CoreGraphics
import Foundation
import MCP

enum MCPMask {
    static let refinementSchema = MCPCanvasFields.patch([
        "edge_radius": MCPCanvasFields.unit, "blur_radius": MCPCanvasFields.unit,
        "expansion": MCPDevelopParameters.numberSchema(-1...1), "hardness": MCPDevelopParameters.numberSchema(-1...1)
    ])

    static func group(_ id: UUID?, in recipe: EditRecipe) throws -> Int {
        guard let index = recipe.localAdjustments.firstIndex(where: { $0.id == id }) else { throw MCPToolProblem.maskUnavailable }
        return index
    }
    static func component(_ id: UUID?, in group: LocalAdjustment) throws -> Int {
        guard let index = group.components.firstIndex(where: { $0.id == id }) else { throw MCPToolProblem.maskUnavailable }
        return index
    }
    static func id(_ value: Value?) -> UUID? { value?.stringValue.flatMap(UUID.init(uuidString:)) }
    static func name(_ value: Value?) throws -> String? {
        guard let name = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard !name.isEmpty else { throw MCPToolProblem.invalid("Enter a nonempty mask or preset name.") }
        return name
    }

    static func row(_ group: LocalAdjustment, recipe: EditRecipe? = nil, detailedComponent: UUID? = nil) -> Value {
        var row: [String: Value] = [
            "mask_id": .string(group.id.uuidString), "name": .string(group.name), "enabled": .bool(group.enabled),
            "inverted": .bool(group.inverted), "amount": .double(group.amount), "component_count": .int(group.components.count)
        ]
        if let recipe {
            let refine = group.refinement ?? MaskRefinement()
            row["refinement"] = ["edge_radius": .double(refine.edgeRadius), "blur_radius": .double(refine.blurRadius),
                                 "expansion": .double(refine.expansion), "hardness": .double(refine.hardness)]
            row["adjustments"] = MCPDevelopParameters.describeLocal(group, source: recipe)
            row["components"] = .array(group.components.map { componentRow($0, detail: $0.id == detailedComponent) })
        }
        return .object(row)
    }
    static func componentRow(_ component: MaskComponent, detail: Bool = false) -> Value {
        var row: [String: Value] = [
            "component_id": .string(component.id.uuidString), "name": .string(component.name), "mask_kind": .string(component.tool.rawValue),
            "mask_operation": .string(component.operation.rawValue), "enabled": .bool(component.enabled), "inverted": .bool(component.inverted)
        ]
        if detail {
            switch component.tool {
            case .brush: row["stroke_count"] = .int(component.strokes.count)
            case .linear, .radial:
                row["shape"] = ["start": MCPCanvasFields.pointValue(component.start), "end": MCPCanvasFields.pointValue(component.end),
                                "radius_x": .double(component.radiusX), "radius_y": .double(component.radiusY),
                                "angle": .double(component.angle), "feather": .double(component.feather)]
            case .color:
                row["refine"] = .double(ColorRange.refine(radius: component.tolerance))
                row["samples"] = .array(component.samples.map { sample in
                    ["point": MCPCanvasFields.pointValue(sample.point), "linear_rgb": [.double(sample.red), .double(sample.green), .double(sample.blue)]]
                })
            case .luminance:
                row["range"] = ["lower": .double(component.lower), "upper": .double(component.upper), "smoothness": .double(component.smoothness)]
            case .object:
                row["has_coverage"] = .bool(component.raster != nil)
            }
        }
        return .object(row)
    }
    static func setRefinement(_ values: [String: Value], on group: inout LocalAdjustment) {
        var refinement = group.refinement ?? MaskRefinement()
        if let value = values["edge_radius"]?.number { refinement.edgeRadius = value }
        if let value = values["blur_radius"]?.number { refinement.blurRadius = value }
        if let value = values["expansion"]?.number { refinement.expansion = value }
        if let value = values["hardness"]?.number { refinement.hardness = value }
        group.refinement = refinement.isNeutral ? nil : refinement
    }
}

struct MCPMaskOverlay {
    static let styles = ["color", "color_on_gray", "on_black", "on_white", "monochrome"]
    static let colors = ["red", "green", "blue"]
    static let schema: Value = [
        "type": "object", "required": ["mask_id"], "additionalProperties": false, "properties": [
            "mask_id": ["type": "string", "format": "uuid"],
            "style": ["type": "string", "enum": .array(styles.map(Value.string))],
            "color": ["type": "string", "enum": .array(colors.map(Value.string))]
        ]
    ]
    let id: UUID
    let style: MaskOverlayStyle
    let color: Int

    init(_ value: Value) throws {
        guard let fields = value.objectValue, let id = MCPMask.id(fields["mask_id"]),
              Set(fields.keys).isSubset(of: ["mask_id", "style", "color"]),
              fields["style"].map({ $0.stringValue.map(Self.styles.contains) == true }) ?? true,
              fields["color"].map({ $0.stringValue.map(Self.colors.contains) == true }) ?? true else {
            throw MCPToolProblem.invalid("Supply a mask ID and a supported overlay style or color.")
        }
        self.id = id
        style = Self.style(fields["style"]?.stringValue ?? Self.styles[0])
        color = Self.colors.firstIndex(of: fields["color"]?.stringValue ?? Self.colors[0])!
    }
    static func style(_ name: String) -> MaskOverlayStyle {
        MaskOverlayStyle(rawValue: styles.firstIndex(of: name) ?? 0) ?? .color
    }
    static func colorName(_ index: Int) -> String { colors[min(colors.count - 1, max(0, index))] }
    var description: Value { ["mask_id": .string(id.uuidString), "style": .string(Self.styles[style.rawValue]), "color": .string(Self.colorName(color))] }
}

extension MCPToolProblem {
    static let maskUnavailable = Self(code: "mask_unavailable", summary: "The mask group or component is missing from this photo version.",
                                      next: "Read get_mask_state for the current groups and component IDs.")
}

extension AppMCPTool {
    var maskDescription: (String, String)? {
        switch self {
        case .maskState:
            ("Read the saved mask list and current native display. Add mask_id for its components and local parameters, and component_id for shape, stroke count or range details.", "photo revisions, masks, selected mask and component IDs, and display")
        case .maskGroup:
            ("Create a mask with mask_kind, or select, duplicate, patch, or delete an existing mask_id. Set name, enabled, inverted and edge refinement.", "job_id or native mask selection")
        case .maskComponent:
            ("Add a mask_kind using mask_operation=add, subtract or intersect. Select, rename, change the operation, enable, invert, or delete an existing component_id.", "job_id or native component selection")
        case .brushStroke:
            ("Paint or erase one path on a saved preview and a brush component. Radius is a fraction of the oriented source's short edge. Feather, flow and density are 0–1.", "job_id, then updated component and operation_id")
        case .maskShape:
            ("Edit linear start/end or a radial center (start) and optional corner (end) on a saved preview. You may also set feather or radial radii and angle in the oriented source.", "job_id, then saved source geometry")
        case .maskRange:
            ("Append, replace, remove or clear color samples, or set refine. Sample luminance or set its lower, upper and smoothness. A sampling point uses a current saved preview.", "job_id, then saved range and samples")
        case .maskDisplay:
            ("Change the active Mask workspace overlay, guides, style and tint, or temporarily hide the selected mask's local effect.", "native mask display and selected IDs")
        case .localAdjustments:
            ("Patch local basic, color, curve and zone controls, and mask amount, or reset a group of local controls.", "job_id, then saved mask and operation_id")
        case .transferLocal:
            ("Copy local parameter values from this saved mask, or paste copied values to this saved mask. The mask shape and amount are preserved.", "copied mask ID or job_id")
        case .listLocalPresets:
            ("Page through catalog local adjustment presets and their revisions.", "items and next_offset")
        case .editLocalPreset:
            ("Create a local parameter preset from a saved mask, apply it to a saved mask, or rename or delete it by preset_id and preset_revision.", "preset ID and revision or job_id")
        default: nil
        }
    }
}

extension AppMCPTools {
    static func maskState(_ model: AppModel) -> [String: Value] {
        ["selected_mask_id": model.selectedMask.map { .string($0.id.uuidString) } ?? .null,
         "selected_component_id": model.selectedMaskComponent.map { .string($0.id.uuidString) } ?? .null,
         "overlay": .bool(model.showMaskOverlay), "guides": .bool(model.showMaskGuides),
         "overlay_style": .string(MCPMaskOverlay.styles[model.maskOverlayStyle.rawValue]),
         "overlay_color": .string(MCPMaskOverlay.colorName(model.maskOverlayColor)),
         "hidden_effect_mask_id": model.previewingMaskID.map { .string($0.uuidString) } ?? .null]
    }

    func readMasks(_ args: [String: Value], model: AppModel, catalog: CatalogStore) async throws -> MCPToolResult {
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        let maskID = MCPMask.id(args["mask_id"]), componentID = MCPMask.id(args["component_id"])
        guard (args["mask_id"] == nil || maskID != nil),
              (args["component_id"] == nil || (maskID != nil && componentID != nil)) else { throw MCPToolProblem.maskUnavailable }
        let worker = Task.detached {
            let recipe = try photo.recipe.map { try MCPDevelopPhoto.decode($0, for: photo) }
            let groups = recipe?.localAdjustments ?? []
            var data = MCPDevelopPhoto.revisions(photo)
            if let maskID {
                guard let recipe else { throw MCPToolProblem.maskUnavailable }
                let mask = groups[try MCPMask.group(maskID, in: recipe)]
                if let componentID { _ = try MCPMask.component(componentID, in: mask) }
                data["mask"] = MCPMask.row(mask, recipe: recipe, detailedComponent: componentID)
            } else { data["masks"] = .array(groups.map { MCPMask.row($0) }) }
            return data
        }
        var data = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try verifySavedCanvasRead(photo, catalog: catalog, model: model)
        data["display"] = model.activeID == photo.id ? .object(Self.maskState(model)) : .null
        data["smart_mask"] = model.smartMaskSession.flatMap { session in
            guard session.photoID == photo.id, session.request.photo.revision == photo.revision,
                  session.request.photo.recipeRevision == photo.recipeRevision else { return nil }
            return .object(Self.smartState(model, session: session))
        } ?? .null
        data["coordinate_space"] = "oriented_source_normalized_top_left"
        return .init("Read the saved mask state.", data: data)
    }

    func writeMasks(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        if tool == .editLocalPreset { return try editLocalPreset(tool, args: args, model: model, catalog: catalog) }
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        if tool == .transferLocal { return try transferLocal(tool, args: args, photo: photo, model: model, catalog: catalog) }
        let action = args["action"]?.stringValue
        let id = MCPMask.id(args["mask_id"]), componentID = MCPMask.id(args["component_id"])
        let name = try MCPMask.name(args["name"])
        let kind = args["mask_kind"]?.stringValue.flatMap(MaskTool.init(rawValue:))
        let operation = args["mask_operation"]?.stringValue.flatMap(MaskOperation.init(rawValue:))
        guard (args["mask_id"] == nil || id != nil), (args["component_id"] == nil || componentID != nil) else {
            throw MCPToolProblem.maskUnavailable
        }
        if tool == .maskGroup || tool == .maskComponent {
            let target = tool == .maskGroup ? id : componentID
            let creates = action == "create" || action == "add"
            let changes = Set(["name", "enabled", "inverted", "refinement", "mask_kind", "mask_operation"].filter { args[$0] != nil })
            let valid: Bool = switch action {
            case "create": kind != nil
            case "add": kind != nil && operation != nil
            case "set": !changes.isEmpty && kind == nil
            case "duplicate": changes.isSubset(of: ["name"])
            default: changes.isEmpty
            }
            guard valid, creates == (target == nil) else { throw MCPToolProblem.invalid("Supply the target and fields for this mask action.") }
        }
        if tool == .maskDisplay || action == "select" {
            guard model.activeID == photo.id, model.active?.recipeRevision == photo.recipeRevision, model.maskMode,
                  let recipe = model.recipe, model.canEdit else { throw MCPToolProblem.developUnavailable }
            if action == "select" {
                let group = recipe.localAdjustments[try MCPMask.group(id, in: recipe)]
                if tool == .maskComponent { _ = try MCPMask.component(componentID, in: group) }
                model.selectMask(group.id, component: componentID)
            } else { try writeMaskDisplay(args, model: model) }
            return .init("Updated the native mask display.", data: Self.maskState(model))
        }
        let takesPoints = tool == .brushStroke || args["point"] != nil || args["start"] != nil || args["end"] != nil
        guard takesPoints == (args["preview_id"] != nil) else {
            throw MCPToolProblem.invalid("Supply a current saved preview_id with canvas coordinates.")
        }
        let preview = try args["preview_id"].map { try canvasPreview($0, catalog: catalog, photo: photo, variant: "saved") }
        let title = L10n.text("app.editMaskRegion", defaultValue: "Edit Mask Region")
        return startCanvasEdit(tool, model: model, catalog: catalog, photo: photo, title: title, preview: preview) { request, original, pipeline in
            var value = original
            if tool == .maskGroup && action == "create" {
                guard id == nil, let kind, value.localAdjustments.count < 64 else {
                    throw MCPToolProblem.invalid("Choose a mask_kind and keep at most 64 mask groups.")
                }
                let component = MaskComponent.drawing(kind, operation: .replace, number: 1)
                var group = LocalAdjustment(components: [component])
                group.settings = LocalDevelopSettings()
                group.name = name ?? L10n.text("app.mask", defaultValue: "Mask \(value.localAdjustments.count + 1)")
                Self.patchMask(args, group: &group)
                value.localAdjustments.append(group)
                return (value, ["mask": MCPMask.row(group), "component": MCPMask.componentRow(component)])
            }
            let index = try MCPMask.group(id, in: value)
            var group = value.localAdjustments[index]
            if tool == .maskGroup {
                switch action {
                case "duplicate":
                    guard value.localAdjustments.count < 64 else { throw MCPToolProblem.invalid("A photo can have up to 64 mask groups.") }
                    var copy = group.duplicated()
                    copy.name = name ?? String(copy.name.prefix(200))
                    value.localAdjustments.append(copy)
                    return (value, ["mask": MCPMask.row(copy, recipe: value)])
                case "delete":
                    value.localAdjustments.remove(at: index)
                    return (value, ["mask_id": .string(group.id.uuidString), "deleted": true])
                default:
                    if let name { group.name = name }
                    Self.patchMask(args, group: &group)
                }
            } else if tool == .localAdjustments {
                let set = action == "set"
                guard set ? args["group"] == nil && (args["adjustments"] != nil || args["amount"] != nil) : args["adjustments"] == nil else {
                    throw MCPToolProblem.invalid("Supply adjustments or amount for set, or choose a reset group.")
                }
                try MCPDevelopParameters.changeLocal(args, source: original, group: &group)
            } else {
                let component = try await Self.editMaskComponent(tool, args: args, id: componentID, name: name, kind: kind, operation: operation,
                                                                  group: &group, preview: preview, recipe: original, request: request, pipeline: pipeline)
                if group.components.isEmpty { value.localAdjustments.remove(at: index) }
                else { value.localAdjustments[index] = group }
                return (value, ["mask_id": .string(group.id.uuidString),
                                "mask_deleted": .bool(group.components.isEmpty),
                                "component": component.map { MCPMask.componentRow($0, detail: true) } ?? .null])
            }
            value.localAdjustments[index] = group
            return (value, ["mask": MCPMask.row(group, recipe: value)])
        }
    }

    nonisolated private static func patchMask(_ args: [String: Value], group: inout LocalAdjustment) {
        if let enabled = args["enabled"]?.boolValue { group.enabled = enabled }
        if let inverted = args["inverted"]?.boolValue { group.inverted = inverted }
        if let refinement = args["refinement"]?.objectValue { MCPMask.setRefinement(refinement, on: &group) }
    }

    nonisolated private static func editMaskComponent(_ tool: AppMCPTool, args: [String: Value], id: UUID?, name: String?, kind: MaskTool?,
                                                       operation: MaskOperation?, group: inout LocalAdjustment, preview: MCPCanvasPreview?,
                                                       recipe: EditRecipe, request: ImageRequest, pipeline: ImagePipeline) async throws -> MaskComponent? {
        let action = args["action"]?.stringValue
        if tool == .maskComponent && action == "add" {
            guard id == nil, let kind, let operation, group.components.count < 128 else {
                throw MCPToolProblem.invalid("Choose a mask_kind and mask_operation and keep at most 128 components.")
            }
            let number = group.components.filter { $0.tool == kind }.count + 1
            var component = MaskComponent.drawing(kind, operation: operation, number: number)
            patchComponent(args, name: name, component: &component)
            group.components.append(component)
            return component
        }
        let index = try MCPMask.component(id, in: group)
        if tool == .maskComponent && action == "delete" {
            group.components.remove(at: index)
            if !group.components.isEmpty { group.components[0].operation = .replace }
            return nil
        }
        var component = group.components[index]
        switch tool {
        case .maskComponent:
            if let operation {
                guard index > 0 else { throw MCPToolProblem.invalid("The first component uses the base operation.") }
                component.operation = operation
            }
            patchComponent(args, name: name, component: &component)
        case .brushStroke:
            guard component.tool == .brush, let preview else { throw MCPToolProblem.invalid("Choose a brush component.") }
            let points = try args["path"]!.arrayValue!.compactMap(MCPCanvasFields.point).map { try preview.sourcePoint($0, recipe: recipe) }
            component.strokes.append(MaskStroke(points: points, radius: args["radius"]?.number ?? 0.04, feather: args["feather"]?.number ?? 0.7,
                                                flow: args["flow"]?.number ?? 0.5, density: args["density"]?.number ?? 1,
                                                erase: args["erase"]?.boolValue ?? false, autoMask: args["auto_mask"]?.boolValue ?? false))
        case .maskShape:
            try updateMaskShape(args, component: &component, preview: preview, recipe: recipe)
        case .maskRange:
            try await updateMaskRange(args, component: &component, preview: preview, recipe: recipe, request: request, pipeline: pipeline)
        default: throw MCPToolProblem.failed
        }
        group.components[index] = component
        return component
    }

    nonisolated private static func patchComponent(_ args: [String: Value], name: String?, component: inout MaskComponent) {
        if let name { component.name = name }
        if let enabled = args["enabled"]?.boolValue { component.enabled = enabled }
        if let inverted = args["inverted"]?.boolValue { component.inverted = inverted }
    }

    nonisolated private static func updateMaskShape(_ args: [String: Value], component: inout MaskComponent, preview: MCPCanvasPreview?,
                                                     recipe: EditRecipe) throws {
        let radial = component.tool == .radial
        let radii = args["radius_x"] != nil || args["radius_y"] != nil
        guard component.tool.isGradient, radial || (!radii && args["angle"] == nil),
              !(radial && radii && args["end"] != nil) else {
            throw MCPToolProblem.invalid("Choose a gradient. A radial corner or explicit radii can set its size.")
        }
        func mapped(_ key: String) throws -> MaskPoint? {
            guard let preview, let point = args[key].flatMap({ MCPCanvasFields.point($0, range: MaskPoint.gradientRange) }) else { return nil }
            return try preview.sourcePoint(point, recipe: recipe, allowOutside: true)
        }
        if let start = try mapped("start") { component.start = start }
        if let end = try mapped("end") {
            if radial {
                component.radiusX = min(100, max(0.001, abs(end.x - component.start.x)))
                component.radiusY = min(100, max(0.001, abs(end.y - component.start.y)))
                component.angle = 0
            } else { component.end = end }
        }
        if let x = args["radius_x"]?.number { component.radiusX = x }
        if let y = args["radius_y"]?.number { component.radiusY = y }
        if let angle = args["angle"]?.number { component.angle = angle }
        if let feather = args["feather"]?.number { component.feather = feather }
    }

    nonisolated private static func updateMaskRange(_ args: [String: Value], component: inout MaskComponent, preview: MCPCanvasPreview?,
                                                     recipe: EditRecipe, request: ImageRequest, pipeline: ImagePipeline) async throws {
        let action = args["action"]!.stringValue!
        let color = component.tool == .color
        let options = color ? ["set", "append_sample", "replace_sample", "remove_sample", "clear_samples"] : ["set", "sample"]
        let sampling = ["sample", "append_sample", "replace_sample"].contains(action)
        let numeric = color ? ["refine"] : ["lower", "upper", "smoothness"]
        let provided = ["refine", "lower", "upper", "smoothness"].filter { args[$0] != nil }
        guard color || component.tool == .luminance, options.contains(action), sampling == (preview != nil),
              (action == "remove_sample") == (args["sample_index"] != nil), provided.allSatisfy(numeric.contains),
              action == "set" ? !provided.isEmpty : provided.isEmpty else {
            throw MCPToolProblem.invalid("Supply the sample or parameter fields for this range component and action.")
        }
        if let preview, let point = args["point"].flatMap(MCPCanvasFields.point) {
            let source = try preview.sourcePoint(point, recipe: recipe)
            guard let sample = try await pipeline.sampleMask(request, at: source) else { throw MCPToolProblem.noCanvasSample }
            if color {
                guard action != "append_sample" || component.samples.count < 16 else { throw MCPToolProblem.invalid("A color range can hold up to 16 samples.") }
                if action == "replace_sample" { component.samples.removeAll() }
                component.samples.append(sample)
            } else {
                let range = sample.luminanceRange
                component.lower = range.lowerBound; component.upper = range.upperBound
            }
        } else if action == "remove_sample" {
            let index = args["sample_index"]!.intValue!
            guard component.samples.indices.contains(index) else { throw MCPToolProblem.invalid("Read the current color samples before removing one.") }
            component.samples.remove(at: index)
        } else if action == "clear_samples" { component.samples.removeAll() }
        if let refine = args["refine"]?.number {
            let radius = ColorRange.radius(refine: refine)
            component.tolerance = radius; component.smoothness = radius
        }
        if let lower = args["lower"]?.number { component.lower = lower }
        if let upper = args["upper"]?.number { component.upper = upper }
        if let smoothness = args["smoothness"]?.number { component.smoothness = smoothness }
        guard component.lower <= component.upper else { throw MCPToolProblem.invalid("The lower limit must be at or below the upper limit.") }
    }

    private func writeMaskDisplay(_ args: [String: Value], model: AppModel) throws {
        if args["hide_effect"] == true {
            guard model.smartMaskSession == nil, let group = model.selectedMask, group.enabled, !group.isNeutral else {
                throw MCPToolProblem.invalid("Select a mask with a visible local effect first.")
            }
            model.beginMaskEffectPreview(group.id)
            guard model.previewingMaskID == group.id else { throw MCPToolProblem.developUnavailable }
        } else if args["hide_effect"] == false { model.endMaskEffectPreview() }
        if let show = args["overlay"]?.boolValue { model.showMaskOverlay = show }
        if let show = args["guides"]?.boolValue { model.showMaskGuides = show }
        if let style = args["overlay_style"]?.stringValue { model.maskOverlayStyle = MCPMaskOverlay.style(style) }
        if let color = args["overlay_color"]?.stringValue { model.maskOverlayColor = MCPMaskOverlay.colors.firstIndex(of: color)! }
    }
}
