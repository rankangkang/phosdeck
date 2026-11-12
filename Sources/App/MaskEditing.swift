import SwiftUI
import CoreImage

enum MaskPointerPhase { case down, drag, up }
struct MaskEditGesture {
    enum Action { case draw, move, start, end, radiusX, radiusY, rotate }
    var groupID: UUID
    var componentID: UUID
    var origin: MaskPoint
    var original: MaskComponent
    var action: Action
    var stroke: MaskStroke?
}

// One geometry definition drives drawing, hit testing, and the gesture action.
extension MaskEditGesture {
    static func handles(_ c: MaskComponent, size: CGSize, rotationOffset: Double? = nil) -> [(action: Action, point: MaskPoint)] {
        if c.tool == .linear {
            let mid = MaskPoint((c.start.x + c.end.x) / 2, (c.start.y + c.end.y) / 2)
            let dx = (c.end.x - c.start.x) * size.width, dy = (c.end.y - c.start.y) * size.height
            let length = max(0.001, hypot(dx, dy)), offset = rotationOffset ?? min(size.width, size.height) * 0.12
            return [(.move, mid), (.start, c.start), (.end, c.end),
                    (.rotate, MaskPoint(c.start.x - dx / length * offset / size.width, c.start.y - dy / length * offset / size.height))]
        }
        guard c.tool == .radial else { return [] }
        let a = c.angle * .pi / 180
        func point(_ x: Double, _ y: Double) -> MaskPoint {
            MaskPoint(c.start.x + (x * cos(a) - y * sin(a)) / size.width,
                      c.start.y + (x * sin(a) + y * cos(a)) / size.height)
        }
        let x = c.radiusX * size.width, y = c.radiusY * size.height
        return [(.move, c.start), (.radiusX, point(x, 0)), (.radiusX, point(-x, 0)),
                (.radiusY, point(0, y)), (.radiusY, point(0, -y)), (.rotate, point(0, y + (rotationOffset ?? size.height * 0.07)))]
    }
    static func hit(_ p: MaskPoint, component c: MaskComponent, size: CGSize, tolerance: Double? = nil, rotationOffset: Double? = nil) -> Action? {
        let radius = tolerance ?? min(size.width, size.height) * 0.025
        let handle = handles(c, size: size, rotationOffset: rotationOffset).map { ($0.action, hypot(($0.point.x - p.x) * size.width, ($0.point.y - p.y) * size.height)) }
            .filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
        if let handle { return handle }
        // Visible guide lines/ellipse edges remain draggable when their center is off-screen.
        if c.tool == .linear {
            let dx = (c.end.x - c.start.x) * size.width, dy = (c.end.y - c.start.y) * size.height
            let length = hypot(dx, dy)
            guard length > 0.001 else { return nil }
            let distance = ((p.x - c.start.x) * size.width * dx + (p.y - c.start.y) * size.height * dy) / length
            return [(Action.start, abs(distance)), (.move, abs(distance - length / 2)), (.end, abs(distance - length))]
                .filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
        }
        if c.tool == .radial {
            let a = c.angle * .pi / 180, dx = (p.x - c.start.x) * size.width, dy = (p.y - c.start.y) * size.height
            let x = cos(a) * dx + sin(a) * dy, y = -sin(a) * dx + cos(a) * dy
            let rx = c.radiusX * size.width, ry = c.radiusY * size.height
            let q = hypot(x / rx, y / ry)
            let slope = hypot(x / (rx * rx), y / (ry * ry)) / max(q, 0.000001)
            if abs(q - 1) / max(slope, 0.000001) <= radius { return .move }
        }
        return nil
    }
}

extension AppModel {
    var selectedMask: LocalAdjustment? { recipe?.localAdjustments.first { $0.id == selectedMaskID } }
    var selectedMaskComponent: MaskComponent? { selectedMask?.components.first { $0.id == selectedComponentID } }
    func setMaskMode(_ enabled: Bool) {
        if enabled, spotMode {
            setSpotMode(false)
            guard !spotMode else { return }
        }
        guard commitRecipe() else { return }
        maskGesture = nil; maskMode = enabled
        maskChoosingTool = false
        if enabled {
            cropMode = false; before = false; editMode = true
            if selectedMask == nil, let group = recipe?.localAdjustments.first { selectMask(group.id, component: group.components.first?.id) }
            if recipe?.localAdjustments.contains(where: { $0.needsBaseline }) == true
                || selectedMask?.components.contains(where: { $0.tool == .color || $0.tool == .luminance }) == true
                || brushAutoMask { prepareMaskReference() }
        }
        requestPreview()
    }
    func prepareMaskReference() {
        guard maskReference == nil, maskReferenceTask == nil, let photo = active, let recipe,
              let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        let token = UUID(); maskReferenceToken = token
        let request = ImageRequest(photo: photo, root: root, recipe: recipe)
        maskReferenceTask = Task {
            do {
                let reference = try await ImagePipeline().maskReference(request)
                guard !Task.isCancelled, token == maskReferenceToken, photo.id == activeID else { return }
                maskReference = reference
            } catch { if !Task.isCancelled, token == maskReferenceToken { self.error = error.localizedDescription } }
            if token == maskReferenceToken { maskReferenceTask = nil }
        }
    }
    func selectMask(_ group: UUID, component: UUID?) {
        guard commitRecipe() else { return }
        maskGesture = nil; maskSampleAppending = false; selectedMaskID = group; selectedComponentID = component; maskDrawNew = false
        maskChoosingTool = false; maskSampling = false; showMaskOverlay = component != nil
        if selectedMask?.needsBaseline == true || selectedMaskComponent?.tool == .color || selectedMaskComponent?.tool == .luminance
            || (selectedMaskComponent?.tool == .brush && brushAutoMask) { prepareMaskReference() }
    }
    func addMask(_ tool: MaskTool, operation: MaskOperation = .replace) {
        guard canEdit, commitRecipe() else { return }
        if tool == .object { beginSmartMask(operation: operation); return }
        cancelSmartMask()
        setMaskMode(true)
        maskSampleAppending = false
        let count = operation == .replace ? 0 : (selectedMask?.components.filter { $0.tool == tool }.count ?? 0)
        let c = MaskComponent.drawing(tool, operation: selectedMask == nil ? .replace : operation, number: count + 1)
        if operation == .replace || selectedMask == nil {
            var group = LocalAdjustment(components: [c]); group.settings = LocalDevelopSettings(); group.name = L10n.text("app.mask", defaultValue: "Mask \((recipe?.localAdjustments.count ?? 0) + 1)")
            changeRecipe({ $0.localAdjustments.append(group) }, title: L10n.text("app.new", defaultValue: "New \(tool.title)"))
            selectedMaskID = group.id
        } else { changeMask { $0.components.append(c) } }
        showMaskGuides = true
        selectedComponentID = c.id; maskDrawNew = tool == .linear || tool == .radial; maskChoosingTool = false; maskSampling = true; brushErase = false; showMaskOverlay = true
        if tool == .color || tool == .luminance { prepareMaskReference() }
    }
    func changeMask(commit: Bool = true, _ edit: (inout LocalAdjustment) -> Void) {
        guard let id = selectedMaskID else { return }
        changeRecipe({ r in
            guard let i = r.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            edit(&r.localAdjustments[i])
        }, commit: commit)
    }
    func toggleMaskAdjustment(_ id: UUID) {
        guard let group = recipe?.localAdjustments.first(where: { $0.id == id }) else { return }
        changeRecipe({ r in
            guard let i = r.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            r.localAdjustments[i].enabled.toggle()
        }, title: group.enabled ? L10n.text("app.disableMaskAdjustments", defaultValue: "Disable Mask Adjustments") : L10n.text("app.enableMaskAdjustments", defaultValue: "Enable Mask Adjustments"))
    }
    func changeLocalDevelop(_ edit: (inout EditRecipe) -> Void, commit: Bool = true) {
        guard let recipe, let group = selectedMask else { return }
        var local = group.editingRecipe(from: recipe)
        edit(&local)
        showMaskOverlay = false
        changeMask(commit: commit) { $0.updateDevelop(local) }
    }

    /// Copy only the selected mask's local adjustment values into the
    /// in-session clipboard.  Selection geometry, amount and enabled state
    /// are intentionally absent from the payload.
    func copyLocalParameters() {
        guard workspaceAvailable, canEdit, commitRecipe(), let group = selectedMask else { return }
        copiedLocalParameters = LocalParameterValues(group: group)
        status = L10n.text("app.copiedLocalAdjustmentsFrom", defaultValue: "Copied local adjustments from “\(group.name)”")
    }

    /// Apply a local payload to the selected mask as one ordinary recipe edit.
    /// The helper validates the complete target before mutating it, so a bad
    /// clipboard or preset cannot partially change a recipe.
    @discardableResult
    func pasteLocalParameters() -> Bool {
        guard let values = copiedLocalParameters else { return false }
        return applyLocalParameters(values, title: L10n.text("app.pasteLocalAdjustments", defaultValue: "Paste Local Adjustments"))
    }

    @discardableResult
    private func applyLocalParameters(_ values: LocalParameterValues, title: String) -> Bool {
        guard workspaceAvailable, canEdit, let group = selectedMask, commitRecipe() else { return false }
        do {
            let candidate = try values.applying(to: group)
            guard candidate.exposure != group.exposure || candidate.contrast != group.contrast ||
                    candidate.saturation != group.saturation || candidate.settings != group.settings else { return true }
            changeMask(commit: false) {
                $0.exposure = candidate.exposure
                $0.contrast = candidate.contrast
                $0.saturation = candidate.saturation
                $0.settings = candidate.settings
            }
            guard commitRecipe(title: title) else { return false }
            status = L10n.text("app.localAdjustmentsApplied", defaultValue: "Local adjustments applied")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveLocalParameterPreset(name: String) -> Bool {
        guard workspaceAvailable, canEdit, let catalog, let group = selectedMask, commitRecipe() else { return false }
        do {
            try catalog.saveLocalParameterPreset(name: name, values: LocalParameterValues(group: group))
            localParameterPresets = try catalog.localParameterPresets()
            status = L10n.text("app.localAdjustmentPresetSavedInTheCurrentCatalog", defaultValue: "Local adjustment preset saved in the current catalog")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func applyLocalParameterPreset(_ preset: LocalParameterPreset) -> Bool {
        do {
            return applyLocalParameters(try preset.decodedValues(), title: L10n.text("app.applyLocalPreset", defaultValue: "Apply Local Preset: \(preset.name)"))
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteLocalParameterPreset(_ preset: LocalParameterPreset) -> Bool {
        guard workspaceAvailable, let catalog else { return false }
        do {
            return try deleteLocalParameterPreset(preset, in: catalog, closedUndo: false)
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteLocalParameterPreset(_ preset: LocalParameterPreset, in catalog: CatalogStore, closedUndo: Bool) throws -> Bool {
        let deleted = try catalog.deleteLocalParameterPreset(preset.id, expecting: preset)
        let groupsByEvent = undo.groupsByEvent
        if closedUndo { undo.groupsByEvent = false; undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { $0.restoreLocalParameterPreset(deleted) }
        undo.setActionName(L10n.text("app.deleteLocalPreset", defaultValue: "Delete Local Preset"))
        if closedUndo { undo.endUndoGrouping(); undo.groupsByEvent = groupsByEvent }
        status = L10n.text("app.deletedLocalPreset", defaultValue: "Deleted local preset “\(deleted.name)”")
        return perform { localParameterPresets = try catalog.localParameterPresets() }
    }

    /// Inverse of deleting a named local parameter preset.  A complete row is
    /// restored so redo can remove the same id again without touching photos.
    private func restoreLocalParameterPreset(_ preset: LocalParameterPreset) {
        guard workspaceAvailable, let catalog else { return }
        perform {
            try catalog.restoreLocalParameterPreset(preset)
            self.localParameterPresets = try catalog.localParameterPresets()
            self.undo.registerUndo(withTarget: self) { $0.deleteLocalParameterPreset(preset) }
            self.undo.setActionName(L10n.text("app.restoreLocalPreset", defaultValue: "Restore Local Preset"))
            self.status = L10n.text("app.restoredLocalPreset", defaultValue: "Restored local preset “\(preset.name)”")
        }
    }

    @discardableResult
    func renameLocalParameterPreset(_ preset: LocalParameterPreset, name: String) -> Bool {
        guard workspaceAvailable, let catalog else { return false }
        do {
            try catalog.renameLocalParameterPreset(id: preset.id, name: name)
            localParameterPresets = try catalog.localParameterPresets()
            status = L10n.text("app.localPresetRenamed", defaultValue: "Local preset renamed")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func changeMaskComponent(commit: Bool = true, _ edit: (inout MaskComponent) -> Void) {
        guard let id = selectedComponentID else { return }
        changeMask(commit: commit) { g in
            guard let i = g.components.firstIndex(where: { $0.id == id }) else { return }
            edit(&g.components[i])
        }
    }
    func deleteMaskComponent() {
        guard let c = selectedComponentID, let g = selectedMask, g.components.contains(where: { $0.id == c }), commitRecipe() else { return }
        if g.components.count == 1 { deleteMask(); selectedComponentID = nil; return }
        changeMask { group in group.components.removeAll { $0.id == c }; group.components[0].operation = .replace }
        selectedComponentID = nil; maskGesture = nil
    }
    func deleteMask() {
        guard let id = selectedMaskID, commitRecipe() else { return }
        changeRecipe({ $0.localAdjustments.removeAll { $0.id == id } }, title: L10n.text("app.deleteMask", defaultValue: "Delete Mask"))
        selectedMaskID = recipe?.localAdjustments.first?.id; selectedComponentID = selectedMask?.components.first?.id; maskGesture = nil
    }
    func duplicateMask() {
        guard let selected = selectedMask, commitRecipe() else { return }
        let group = selected.duplicated()
        changeRecipe({ $0.localAdjustments.append(group) }, title: L10n.text("app.duplicateMask", defaultValue: "Duplicate Mask"))
        selectedMaskID = group.id; selectedComponentID = group.components.first?.id
    }
    func sampleMaskColor(at point: MaskPoint, append: Bool = true) {
        guard let sample = maskSample(at: point) else { return }
        guard !append || (selectedMaskComponent?.samples.count ?? 0) < 16 else { error = L10n.text("app.eachColorRangeCanHoldUpTo16Samples", defaultValue: "Each color range can hold up to 16 samples"); return }
        changeMaskComponent {
            if !append { $0.samples = [] }
            $0.samples.append(sample)
        }
    }
    private func maskSample(at point: MaskPoint) -> MaskSample? {
        guard point.valid else { return nil }
        guard let reference = maskReference else { prepareMaskReference(); status = L10n.text("app.preparingTheOriginalForSamplingTryClickingAgainShortly", defaultValue: "Preparing the original for sampling. Try clicking again shortly"); return nil }
        guard let sample = MaskSample.read(at: point, from: reference, context: CIContext()) else { status = L10n.text("app.fullyTransparentPixelsHaveNoColorToSample", defaultValue: "Fully transparent pixels have no color to sample"); return nil }
        return sample
    }
    var maskInstruction: String {
        if let session = smartMaskSession { return session.message }
        guard !maskChoosingTool, let c = selectedMaskComponent else { return L10n.text("app.selectAMaskToolToEditItsSelection", defaultValue: "Select a mask tool to edit its selection") }
        switch c.tool {
        case .object: return L10n.text("app.smartSelectionSavedUseAddSubtractOrRefineSelection", defaultValue: "Smart selection saved. Use Add, Subtract, or Refine Selection to adjust its edges")
        case .brush:
            if brushAutoMask {
                return brushErase ? L10n.text("app.autoMaskEraseColorsSimilarToTheStrokeStart", defaultValue: "Auto Mask: erase colors similar to the stroke start · [ / ] changes size") : L10n.text("app.autoMaskPaintSimilarColorsAlongTonalEdgesHold", defaultValue: "Auto Mask: paint similar colors along tonal edges · Hold Option to erase · [ / ] changes size")
            }
            return brushErase ? L10n.text("app.paintOnThePhotoToEraseThisBrushSelection", defaultValue: "Paint on the photo to erase this brush selection") : L10n.text("app.paintOnThePhotoHoldOptionToEraseChanges", defaultValue: "Paint on the photo · Hold Option to erase · [ / ] changes size")
        case .linear: return maskDrawNew ? L10n.text("app.dragOutwardFromTheAreaToAdjust", defaultValue: "Drag outward from the area to adjust") : L10n.text("app.dragTheCenterOrMiddleLineToMoveEdges", defaultValue: "Drag the center or middle line to move · Edges adjust transition · End circle rotates · Extends beyond the photo")
        case .radial: return maskDrawNew ? L10n.text("app.dragOutwardFromTheSelectionCenterToCreateAn", defaultValue: "Drag outward from the selection center to create an ellipse") : L10n.text("app.dragTheCenterOrEllipseEdgeToMoveSquares", defaultValue: "Drag the center or ellipse edge to move · Squares resize · Ring rotates · Extends beyond the photo")
        case .color: return maskSampling ? L10n.text("app.eyedropperClickToSampleAColorShiftClickTo", defaultValue: "Eyedropper: click to sample a color · Shift-click to add samples") : L10n.text("app.clickSelectColorToSampleThePhotoAgain", defaultValue: "Click Select Color to sample the photo again")
        case .luminance: return maskSampling ? L10n.text("app.eyedropperClickToSampleLuminanceOrDragTheRange", defaultValue: "Eyedropper: click to sample luminance, or drag the range sliders") : L10n.text("app.dragTheRangeEndpointsToSelectTheTonesTo", defaultValue: "Drag the range endpoints to select the tones to adjust")
        }
    }
    func maskPointer(_ output: CGPoint, phase: MaskPointerPhase, modifiers: NSEvent.ModifierFlags = [], action requestedAction: MaskEditGesture.Action? = nil) {
        guard maskMode, !maskChoosingTool, canEdit, canvasCoordinatesCurrent, !before, let recipe, let size = orientedSourceSize else { return }
        if smartMaskSession != nil {
            var point = MaskGeometry.sourcePoint(output, size: size, recipe: recipe, allowOutside: true)
            if let p = point {
                point = phase == .down && !p.valid ? nil : MaskPoint(min(1, max(0, p.x)), min(1, max(0, p.y)))
            }
            smartMaskPointer(point, phase: phase, modifiers: modifiers); return
        }
        let point = MaskGeometry.sourcePoint(output, size: size, recipe: recipe, allowOutside: selectedMaskComponent?.tool.isGradient == true)
        if phase == .down {
            guard commitRecipe(), let p = point, let group = selectedMask, let c = selectedMaskComponent else { return }
            if c.tool == .color {
                guard maskSampling || modifiers.contains(.shift) || modifiers.contains(.option) else { return }
                showMaskOverlay = true
                if modifiers.contains(.option) {
                    guard let index = c.samples.indices.min(by: { hypot(c.samples[$0].point.x - p.x, c.samples[$0].point.y - p.y) < hypot(c.samples[$1].point.x - p.x, c.samples[$1].point.y - p.y) }),
                          hypot((c.samples[index].point.x - p.x) * size.width, (c.samples[index].point.y - p.y) * size.height) < min(size.width, size.height) * 0.025 else { return }
                    changeMaskComponent { $0.samples.remove(at: index) }
                } else { sampleMaskColor(at: p, append: (maskSampling && maskSampleAppending) || modifiers.contains(.shift)); if !modifiers.contains(.shift), maskReference != nil { maskSampling = false; maskSampleAppending = false } }
                return
            }
            if c.tool == .luminance {
                guard maskSampling, let sample = maskSample(at: p) else { return }
                showMaskOverlay = true
                let range = sample.luminanceRange
                changeMaskComponent { $0.lower = range.lowerBound; $0.upper = range.upperBound }
                maskSampling = false
                return
            }
            let action: MaskEditGesture.Action
            if maskDrawNew || c.tool == .brush { action = .draw }
            else {
                guard let hit = requestedAction ?? MaskEditGesture.hit(p, component: c, size: size) else { return }
                action = hit
            }
            showMaskOverlay = true
            let stroke = c.tool == .brush ? MaskStroke(points: [p], radius: brushRadius, feather: brushFeather, flow: brushFlow, density: brushDensity, erase: brushErase || modifiers.contains(.option), autoMask: brushAutoMask) : nil
            maskGesture = MaskEditGesture(groupID: group.id, componentID: c.id, origin: p, original: c, action: action, stroke: stroke)
        }
        guard var gesture = maskGesture, gesture.groupID == selectedMaskID, gesture.componentID == selectedComponentID else { return }
        if let p = point {
            var c = gesture.original
            if var stroke = gesture.stroke {
                if stroke.points.last != p { stroke.points.append(p) }
                gesture.stroke = stroke; c.strokes.append(stroke)
            } else {
                let dx = p.x - gesture.origin.x, dy = p.y - gesture.origin.y
                switch gesture.action {
                case .draw:
                    if c.tool == .linear { c.start = p; c.end = gesture.origin }
                    else {
                        c.start = gesture.origin
                        c.radiusX = min(100, max(0.001, abs(dx))); c.radiusY = min(100, max(0.001, abs(dy))); c.angle = 0
                    }
                case .move:
                    c.start = MaskPoint(c.start.x + dx, c.start.y + dy)
                    c.end = MaskPoint(c.end.x + dx, c.end.y + dy)
                case .start, .end:
                    // Boundary handles change only the falloff; rotation has its own handle.
                    let vx = (c.end.x - c.start.x) * size.width, vy = (c.end.y - c.start.y) * size.height
                    let length = max(0.001, hypot(vx, vy)), ux = vx / length, uy = vy / length
                    let anchor = gesture.action == .start ? c.end : c.start
                    let distance = (p.x - anchor.x) * size.width * ux + (p.y - anchor.y) * size.height * uy
                    if gesture.action == .start { c.start = MaskPoint(anchor.x + min(-1, distance) * ux / size.width, anchor.y + min(-1, distance) * uy / size.height) }
                    else { c.end = MaskPoint(anchor.x + max(1, distance) * ux / size.width, anchor.y + max(1, distance) * uy / size.height) }
                case .rotate:
                    if c.tool == .linear {
                        let mid = MaskPoint((c.start.x + c.end.x) / 2, (c.start.y + c.end.y) / 2)
                        var angle = atan2((p.y - mid.y) * size.height, (p.x - mid.x) * size.width) + .pi
                        if modifiers.contains(.shift) { angle = (angle / (.pi / 12)).rounded() * (.pi / 12) }
                        let radius = hypot((c.end.x - c.start.x) * size.width, (c.end.y - c.start.y) * size.height) / 2
                        let x = cos(angle) * radius / size.width, y = sin(angle) * radius / size.height
                        c.start = MaskPoint(mid.x - x, mid.y - y)
                        c.end = MaskPoint(mid.x + x, mid.y + y)
                    } else {
                        c.angle = atan2(-(p.x - c.start.x) * size.width, (p.y - c.start.y) * size.height) * 180 / .pi
                        if modifiers.contains(.shift) { c.angle = (c.angle / 15).rounded() * 15 }
                    }
                case .radiusX, .radiusY:
                    let a = c.angle * .pi / 180, x = (p.x - c.start.x) * size.width, y = (p.y - c.start.y) * size.height
                    if gesture.action == .radiusX { c.radiusX = min(100, max(0.001, abs(cos(a) * x + sin(a) * y) / size.width)) }
                    else { c.radiusY = min(100, max(0.001, abs(-sin(a) * x + cos(a) * y) / size.height)) }
                }
            }
            changeMaskComponent(commit: false) { $0 = c }
            maskGesture = gesture
        }
        if phase == .up { maskGesture = nil; maskDrawNew = false; _ = commitRecipe(title: L10n.text("app.editMaskRegion", defaultValue: "Edit Mask Region")) }
    }
}
