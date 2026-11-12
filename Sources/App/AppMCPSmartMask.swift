import AppKit
import Foundation
import MCP

struct MCPSmartOverlay {
    static let targets = ["selected", "candidate", "person", "all_people", "part", "whole_person"]
    static let schema: Value = [
        "type": "object", "required": ["smart_session_id", "selection_revision", "target"], "additionalProperties": false, "properties": [
            "smart_session_id": ["type": "string", "format": "uuid"],
            "selection_revision": ["type": "string"],
            "target": ["type": "string", "enum": .array(targets.map(Value.string))],
            "index": ["type": "integer", "minimum": 0, "maximum": 255],
            "part": ["type": "string", "enum": .array(SmartMaskPart.allCases.map { .string($0.rawValue) })],
            "style": ["type": "string", "enum": .array(MCPMaskOverlay.styles.map(Value.string))],
            "color": ["type": "string", "enum": .array(MCPMaskOverlay.colors.map(Value.string))]
        ]
    ]
    let fields: [String: Value]
    let target: String
    let index: Int?
    let part: SmartMaskPart?
    let style: MaskOverlayStyle
    let color: Int

    init(_ value: Value) throws {
        guard let fields = value.objectValue, MCPMask.id(fields["smart_session_id"]) != nil,
              let revision = fields["selection_revision"]?.stringValue, (1...128).contains(revision.utf8.count),
              let target = fields["target"]?.stringValue, Self.targets.contains(target),
              Set(fields.keys).isSubset(of: ["smart_session_id", "selection_revision", "target", "index", "part", "style", "color"]) else {
            throw MCPToolProblem.invalid("Supply the smart mask session, selection revision and overlay target.")
        }
        let index = fields["index"]?.intValue
        let part = fields["part"]?.stringValue.flatMap(SmartMaskPart.init(rawValue:))
        let indexed = ["candidate", "person"].contains(target)
        guard indexed ? index.map((0...255).contains) == true : fields["index"] == nil,
              target == "part" ? part != nil : fields["part"] == nil,
              fields["style"].map({ $0.stringValue.map(MCPMaskOverlay.styles.contains) == true }) ?? true,
              fields["color"].map({ $0.stringValue.map(MCPMaskOverlay.colors.contains) == true }) ?? true else {
            throw MCPToolProblem.invalid("Supply the index or part for the selected smart mask overlay.")
        }
        self.fields = fields
        self.target = target
        self.index = index
        self.part = part
        style = MCPMaskOverlay.style(fields["style"]?.stringValue ?? "color")
        color = MCPMaskOverlay.colors.firstIndex(of: fields["color"]?.stringValue ?? "red")!
    }

    @MainActor func raster(in session: SmartMaskSession) -> SmartMaskRaster? {
        switch target {
        case "candidate": session.raster(for: .candidate(index!))
        case "person": session.raster(for: .person(index!))
        case "all_people": session.raster(for: .allPeople)
        case "part": session.raster(for: .part(part!))
        case "whole_person": session.raster(for: .wholePerson)
        default: session.preview
        }
    }
}

extension MCPToolProblem {
    static let staleSmartSelection = Self(code: "stale_smart_selection", summary: "The smart mask session or selection has changed.",
                                          next: "Read get_mask_state for this photo version and use its current selection_revision.")
    static let smartSelectionUnavailable = Self(code: "smart_selection_unavailable", summary: "The requested smart selection is unavailable.",
                                                 next: "Read the current candidates, people, parts and analysis state in get_mask_state.")
    static func missingSmartModel(_ model: String) -> Self {
        .init(code: "smart_model_unavailable", summary: "\(model) is unavailable in this Phosdeck build.",
              next: "Check smart_mask_models in get_capabilities for available selections.")
    }
}

extension AppMCPTool {
    var smartMaskDescription: (String, String)? {
        switch self {
        case .smartStart:
            ("Start native object or people selection in the active Mask workspace. Create a new mask, append to mask_id with mask_operation, or refine an existing smart component_id in that mask.", "analysis job_id, then the smart session and selection revision")
        case .smartEdit:
            ("Edit a current smart selection: add/include or exclude points, draw a box, undo prompts, choose candidates, select people or parts, refine faces, split part masks, or cancel. Coordinates refer to a current saved preview.", "analysis job_id or cancelled session")
        case .smartApply:
            ("Save the current native smart selection as mask groups or components on the active photo. Use the current selection revision from get_mask_state.", "job_id, then affected mask IDs, recipe revision and operation_id")
        default: nil
        }
    }
}

extension AppMCPTools {
    static func smartModels(_ models: SmartMaskModels = SmartMaskEngine.bundledModels) -> Value {
        ["object": .bool(models.objectDirectory != nil), "people": true, "body_parts": .bool(models.bodyURL != nil),
         "face_refinement": .bool(models.faceURL != nil),
         "parts": .array(SmartMaskPart.allCases.filter(models.supports).map { .string($0.rawValue) })]
    }

    static func smartState(_ model: AppModel, session: SmartMaskSession) -> [String: Value] {
        func sourceRect(_ rect: CGRect) -> Value {
            MCPCanvasFields.rectValue(CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height))
        }
        let target: Value = switch session.target {
        case .newMask: ["action": "create"]
        case .append(let group, let operation): ["action": "append", "mask_id": .string(group.uuidString), "mask_operation": .string(operation.rawValue)]
        case .replace(let group, let component): ["action": "replace", "mask_id": .string(group.uuidString), "component_id": .string(component.uuidString)]
        }
        var data = MCPDevelopPhoto.revisions(session.request.photo)
        let state: [String: Value] = [
            "smart_session_id": .string(session.id.uuidString), "workflow": session.workflow == .object ? "object" : "people", "target": target,
            "ready": .bool(session.ready), "busy": .bool(session.busy || session.analyzingParts || session.combining),
            "can_apply": .bool(session.canCreate),
            "message": .string(session.analysisError == nil ? session.message : "Smart mask analysis failed. See Phosdeck for details."),
            "analysis_error": session.analysisError == nil ? .null : "smart_mask_analysis_failed",
            "can_undo_prompt": .bool(!session.promptHistory.isEmpty), "coordinate_space": "oriented_source_normalized_top_left",
            "candidate_index": session.candidates.indices.contains(session.candidate) ? .int(session.candidate) : .null,
            "whole_person": .bool(session.wholePerson), "separate": .bool(session.separate),
            "face_index": session.selectedFace.map(Value.int) ?? .null,
            "face_refined": .bool(session.faceRefined), "face_failure": session.faceFailure == nil ? .null : "face_refinement_failed"
        ]
        data.merge(state) { _, value in value }
        data["prompts"] = .array(session.prompts.map { ["label": .int($0.label), "point": MCPCanvasFields.pointValue($0.point)] })
        data["candidates"] = .array(session.candidates.enumerated().map { index, candidate in
            ["index": .int(index), "score": candidate.score.isFinite ? .double(Double(candidate.score)) : .null, "selected_pixels": .int(candidate.selectedPixels)]
        })
        data["people"] = .array(session.people.enumerated().map { index, person in
            ["index": .int(index), "bounds": sourceRect(person.bounds), "selected": .bool(session.selectedPeople.contains(index))]
        })
        data["faces"] = .array(session.faces.map(sourceRect))
        let parts = SmartMaskPart.allCases.filter { session.parts?[$0] != nil }
        data["parts"] = .array(parts.map { .string($0.rawValue) })
        data["selected_parts"] = .array(parts.filter { !session.wholePerson && session.selectedParts.contains($0) }.map { .string($0.rawValue) })
        data["selection_revision"] = organizationRevision([
            Value.object(data), .string(model.smartMaskGeneration.uuidString), .string(model.smartMaskPreviewGeneration.uuidString)
        ])
        return data
    }

    func smartOverlayGroup(_ overlay: MCPSmartOverlay, photo: Photo, model: AppModel) throws -> LocalAdjustment {
        let session = try expectedSmartSelection(overlay.fields, photo: photo, model: model)
        guard session.ready, let raster = overlay.raster(in: session),
              let group = model.smartMaskPreviewGroup(for: raster, in: session) else { throw MCPToolProblem.smartSelectionUnavailable }
        return group
    }

    func writeSmartMask(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let photo = try MCPDevelopPhoto.current(args, catalog: catalog)
        if tool == .smartStart { return try startSmartMask(tool, args: args, photo: photo, model: model, catalog: catalog) }
        let session = try expectedSmartSelection(args, photo: photo, model: model)
        if tool == .smartApply { return try applySmartMask(tool, args: args, photo: photo, model: model, catalog: catalog, session: session) }
        let action = args["action"]!.stringValue!
        if action == "cancel" {
            model.cancelSmartMask()
            return .init("Cancelled the native smart selection.", data: ["smart_session_id": .string(session.id.uuidString), "cancelled": true])
        }
        guard session.ready, !session.busy, !session.combining, !session.analyzingParts else { throw MCPToolProblem.busy }
        let needsPoint = ["include", "exclude"].contains(action)
        let needsBox = ["box", "face_box"].contains(action)
        guard needsPoint == (args["point"] != nil), needsBox == (args["rect"] != nil),
              (needsPoint || needsBox) == (args["preview_id"] != nil),
              (action == "select_candidate") == (args["candidate_index"] != nil),
              (action == "select_people") == (args["person_indices"] != nil),
              (action == "select_face") == (args["face_index"] != nil),
              (action == "toggle_part") == (args["part"] != nil),
              (action == "set_separate") == (args["separate"] != nil),
              args["whole_person"] == nil || ["select_people", "select_all_people"].contains(action) else {
            throw MCPToolProblem.invalid("Supply the coordinates or selection fields for the chosen smart mask action.")
        }
        let preview = try args["preview_id"].map { try canvasPreview($0, catalog: catalog, photo: photo, variant: "saved") }
        return runSmartAnalysis(tool, photo: photo, model: model, catalog: catalog) {
            let current = try self.expectedSmartSelection(args, photo: photo, model: model)
            if let preview { _ = try self.canvasPreview(.string(preview.id), catalog: catalog, photo: photo, variant: "saved") }
            try self.changeSmartSelection(action, args: args, model: model, session: current, preview: preview)
            return current.id
        }
    }

    private func expectedSmartSelection(_ args: [String: Value], photo: Photo, model: AppModel) throws -> SmartMaskSession {
        guard let session = model.smartMaskSession, session.id == MCPMask.id(args["smart_session_id"]),
              session.photoID == photo.id, model.activeID == photo.id, model.maskMode,
              model.active?.revision == photo.revision, model.active?.recipeRevision == photo.recipeRevision,
              session.request.photo.revision == photo.revision, session.request.photo.recipeRevision == photo.recipeRevision,
              Self.smartState(model, session: session)["selection_revision"] == args["selection_revision"] else {
            throw MCPToolProblem.staleSmartSelection
        }
        return session
    }

    private func startSmartMask(_ tool: AppMCPTool, args: [String: Value], photo: Photo, model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let group = MCPMask.id(args["mask_id"]), component = MCPMask.id(args["component_id"])
        let operation = args["mask_operation"]?.stringValue.flatMap(MaskOperation.init(rawValue:))
        let workflow: SmartMaskWorkflow = args["workflow"] == "people" ? .people : .object
        guard (args["mask_id"] == nil || group != nil), (args["component_id"] == nil || component != nil),
              group == nil ? (component == nil && operation == nil) : ((component == nil) != (operation == nil)) else {
            throw MCPToolProblem.invalid("Choose a new mask, a mask_id with mask_operation, or a mask_id with component_id.")
        }
        guard model.activeID == photo.id, model.active?.recipeRevision == photo.recipeRevision,
              model.canEdit, model.maskMode, model.orientedSourceSize != nil, model.canvasCoordinatesCurrent,
              let recipe = model.recipe else { throw MCPToolProblem.developUnavailable }
        if let group {
            let existing = recipe.localAdjustments[try MCPMask.group(group, in: recipe)]
            if let component {
                let saved = existing.components[try MCPMask.component(component, in: existing)]
                guard let raster = saved.raster, raster.isPersonSelection == (workflow == .people) else {
                    throw MCPToolProblem.invalid("Use the saved smart component's object or people workflow to refine it.")
                }
            } else if existing.components.count >= 128 { throw MCPToolProblem.invalid("A mask can have up to 128 components.") }
        } else if recipe.localAdjustments.count >= 64 { throw MCPToolProblem.invalid("A photo can have up to 64 mask groups.") }
        if workflow == .object && SmartMaskEngine.bundledModels.objectDirectory == nil { throw MCPToolProblem.missingSmartModel("Object selection") }
        return runSmartAnalysis(tool, photo: photo, model: model, catalog: catalog) {
            if let group { model.selectMask(group, component: component) }
            model.beginSmartMask(operation: operation ?? .replace, replacing: component != nil, workflow: workflow)
            guard let id = model.smartMaskSession?.id else { throw MCPToolProblem.developUnavailable }
            self.mcpSmartSessionID = id
            return id
        }
    }

    private func runSmartAnalysis(_ tool: AppMCPTool, photo: Photo, model: AppModel, catalog: CatalogStore,
                                  perform: @escaping @MainActor () throws -> UUID) -> MCPToolResult {
        workflows.start(tool) { [self] job in
            workflows.running(job, phase: "analyzing_smart_mask")
            try verifySavedCanvasRead(photo, catalog: catalog, model: model)
            let id = try perform()
            job.data["smart_session_id"] = .string(id.uuidString)
            job.onCancel = { if model.smartMaskSession?.id == id { model.cancelSmartMask() } }
            while let session = model.smartMaskSession, session.id == id, session.busy || session.combining || session.analyzingParts {
                guard let task = model.smartMaskTask ?? model.smartMaskPreviewTask else { throw MCPToolProblem.smartSelectionUnavailable }
                await task.value
                try Task.checkCancellation()
            }
            try verifySavedCanvasRead(photo, catalog: catalog, model: model)
            guard let session = model.smartMaskSession, session.id == id else { throw MCPToolProblem.staleSmartSelection }
            job.data["smart_mask"] = .object(Self.smartState(model, session: session))
            if session.analysisError != nil {
                job.finish(.failed, "Smart mask analysis failed. See Phosdeck for details.", error: "smart_mask_analysis_failed")
            } else { job.finish(.succeeded, "Read the resulting smart selection.") }
        }
    }

    private func changeSmartSelection(_ action: String, args: [String: Value], model: AppModel,
                                      session: SmartMaskSession, preview: MCPCanvasPreview?) throws {
        let object = session.workflow == .object
        switch action {
        case "include", "exclude", "box":
            guard object, let preview, let recipe = session.request.recipe else { throw MCPToolProblem.smartSelectionUnavailable }
            guard action != "exclude" || session.prompts.contains(where: { $0.label != 0 }) else {
                throw MCPToolProblem.invalid("Place an inclusion point or box before adding exclusions.")
            }
            guard action == "box" || session.prompts.count < 64 else { throw MCPToolProblem.invalid("Undo a prompt or draw a new box after 64 prompts.") }
            let points: (MaskPoint, MaskPoint)
            if let rect = args["rect"].flatMap(MCPCanvasFields.rect) { points = try smartBox(rect, preview: preview, recipe: recipe) }
            else {
                let point = try preview.sourcePoint(MCPCanvasFields.point(args["point"]!)!, recipe: recipe)
                points = (point, point)
            }
            model.smartMaskSession?.mode = SmartMaskPickMode(rawValue: action)!
            model.smartMaskPointer(points.0, phase: .down, modifiers: [])
            model.smartMaskPointer(points.1, phase: .up, modifiers: [])
        case "undo_prompt":
            guard object, !session.promptHistory.isEmpty else { throw MCPToolProblem.smartSelectionUnavailable }
            model.undoSmartPrompt()
        case "select_candidate":
            let index = args["candidate_index"]!.intValue!
            guard object, session.candidates.indices.contains(index) else { throw MCPToolProblem.smartSelectionUnavailable }
            model.chooseSmartCandidate(index)
        case "select_people", "select_all_people":
            let indices = args["person_indices"]?.arrayValue?.compactMap(\.intValue) ?? Array(session.people.indices)
            let whole = args["whole_person"]?.boolValue
            guard !object, indices.allSatisfy(session.people.indices.contains) else { throw MCPToolProblem.smartSelectionUnavailable }
            if whole == false && !session.models.hasParts { throw MCPToolProblem.missingSmartModel("Body part selection") }
            model.selectSmartPeople(Set(indices), whole: whole)
        case "select_whole_person":
            guard !object, session.instance != nil else { throw MCPToolProblem.smartSelectionUnavailable }
            model.selectWholeSmartPerson()
        case "toggle_part":
            let part = SmartMaskPart(rawValue: args["part"]!.stringValue!)!
            guard !object, session.models.supports(part) else { throw MCPToolProblem.missingSmartModel("The requested part") }
            guard session.parts?[part] != nil else { throw MCPToolProblem.smartSelectionUnavailable }
            model.toggleSmartPart(part)
        case "select_face", "face_box", "reset_face":
            guard !object, session.models.faceURL != nil else { throw MCPToolProblem.missingSmartModel("Face refinement") }
            guard session.selectedPeople.count == 1 else { throw MCPToolProblem.smartSelectionUnavailable }
            if action == "face_box", let preview, let recipe = session.request.recipe {
                let rect = MCPCanvasFields.rect(args["rect"]!)!
                let (start, end) = try smartBox(rect, preview: preview, recipe: recipe)
                model.smartMaskSession?.mode = .face
                model.smartMaskPointer(start, phase: .down, modifiers: [])
                model.smartMaskPointer(end, phase: .up, modifiers: [])
            } else if action == "select_face" {
                let index = args["face_index"]!.intValue!
                guard session.faces.indices.contains(index) else { throw MCPToolProblem.smartSelectionUnavailable }
                model.chooseSmartFace(index)
            } else {
                guard session.canResetFace else { throw MCPToolProblem.smartSelectionUnavailable }
                model.resetSmartFace()
            }
        case "set_separate":
            guard !object, case .newMask = session.target else { throw MCPToolProblem.smartSelectionUnavailable }
            model.smartMaskSession?.separate = args["separate"]!.boolValue!
        default: throw MCPToolProblem.invalid("Choose a smart mask action.")
        }
    }

    private func smartBox(_ rect: CGRect, preview: MCPCanvasPreview, recipe: EditRecipe) throws -> (MaskPoint, MaskPoint) {
        let start = try preview.sourcePoint(CGPoint(x: rect.minX, y: rect.minY), recipe: recipe)
        let end = try preview.sourcePoint(CGPoint(x: rect.maxX, y: rect.maxY), recipe: recipe)
        guard SmartMaskField.region(start, end) != nil else { throw MCPToolProblem.invalid("Draw a larger rectangle over the selection.") }
        return (start, end)
    }

    private func applySmartMask(_ tool: AppMCPTool, args: [String: Value], photo: Photo, model: AppModel,
                                catalog: CatalogStore, session: SmartMaskSession) throws -> MCPToolResult {
        guard session.canCreate, model.canEdit else { throw MCPToolProblem.smartSelectionUnavailable }
        return workflows.start(tool) { [self] job in
            try await model.pipeline.validateSmartMaskSource(session.request)
            try verifySavedCanvasRead(photo, catalog: catalog, model: model)
            let current = try expectedSmartSelection(args, photo: photo, model: model)
            guard current.canCreate, !model.dirty, model.undo.groupingLevel == 0,
                  model.undo.isUndoRegistrationEnabled else { throw MCPToolProblem.nativeInteraction }
            let previous = Set(model.recipe?.localAdjustments.map(\.id) ?? [])
            withCanvasUndo(model) { model.createSmartMask() }
            job.data["commit_state"] = "unknown"
            guard let saved = try catalog.photo(photo.id) else { throw MCPToolProblem.photoUnavailable }
            guard saved.recipeRevision != photo.recipeRevision else {
                job.data["commit_state"] = "not_committed"
                throw MCPToolProblem.invalidEdit
            }
            job.data.merge(MCPDevelopPhoto.revisions(saved)) { _, value in value }
            job.data["operation_id"] = recordRecipeUndo(before: [photo], after: [saved])
            job.data["created_mask_ids"] = .array((model.recipe?.localAdjustments ?? []).filter { !previous.contains($0.id) }.map { .string($0.id.uuidString) })
            job.data["display"] = .object(Self.maskState(model))
            job.finish(.succeeded, "Saved the smart mask to the photo version.", committed: "committed")
        }
    }
}
