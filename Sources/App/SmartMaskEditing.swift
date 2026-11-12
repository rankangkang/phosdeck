import SwiftUI
import CoreImage
import Observation

enum SmartMaskPickMode: String, CaseIterable {
    case include, exclude, box, face
    var title: String {
        switch self { case .include: L10n.text("app.clickToAdd", defaultValue: "Click to Add"); case .exclude: L10n.text("app.clickToExclude", defaultValue: "Click to Exclude"); case .box: L10n.text("app.boxSelection", defaultValue: "Box Selection"); case .face: L10n.text("app.manualFaceBox", defaultValue: "Manual Face Box") }
    }
}
enum SmartMaskWorkflow { case object, people }

enum SmartMaskTarget {
    case newMask
    case append(UUID, MaskOperation)
    case replace(UUID, UUID)
}

enum SmartMaskInspectionTarget: Hashable {
    case person(Int), allPeople, part(SmartMaskPart), candidate(Int), wholePerson
    var title: String {
        switch self {
        case .person(let index): L10n.text("app.person", defaultValue: "Person \(index + 1)")
        case .allPeople: L10n.text("smartMask.allPeople", defaultValue: "All People")
        case .part(let part): part.title
        case .candidate(let index): L10n.text("smartMask.candidateNumber", defaultValue: "Candidate \(index + 1)")
        case .wholePerson: L10n.text("app.wholePerson", defaultValue: "Whole Person")
        }
    }
}

/// Pointer inspection must not invalidate views observing the recipe or whole session.
@MainActor @Observable final class SmartMaskInspection {
    var hovered: SmartMaskInspectionTarget?
    var focused: SmartMaskInspectionTarget?
    var target: SmartMaskInspectionTarget? { hovered ?? focused }
    func clear() { hovered = nil; focused = nil }
    func didSelect(_ target: SmartMaskInspectionTarget) {
        hovered = nil
        if focused != target { focused = nil }
    }
}

@MainActor
struct SmartMaskSession {
    let id = UUID()
    let photoID: String
    let catalogPath: String
    let request: ImageRequest
    let source: SmartMaskSource
    let target: SmartMaskTarget
    let inspection = SmartMaskInspection()
    var models = SmartMaskEngine.bundledModels
    var workflow = SmartMaskWorkflow.object
    var people: [SmartMaskPerson] = []
    var allPeople: SmartMaskRaster?
    var selectedPeople: Set<Int> = []
    var faceRegions: [Int: CGRect] = [:]
    var wholePerson = false
    var analyzingParts = false
    var ready = false
    var image: CGImage?
    var prompts: [SmartMaskPrompt] = []
    var promptHistory: [[SmartMaskPrompt]] = []
    var candidates: [SmartMaskCandidate] = []
    var candidate = 0
    var preview: SmartMaskRaster?
    var instance: SmartMaskRaster?
    var parts: [SmartMaskPart: SmartMaskRaster]?
    var selectedParts: Set<SmartMaskPart> = [.faceSkin, .bodySkin]
    var faces: [CGRect] = []
    var selectedFace: Int?
    var faceRefined = false
    var unrefinedPeople: Set<Int> = []
    var faceFailure: String?
    var separate = false
    var mode = SmartMaskPickMode.include
    var dragStart: MaskPoint?
    var dragEnd: MaskPoint?
    var busy = false
    var combining = false
    var analysisError: String?
    var message = L10n.text("app.clickOrDrawABoxAroundTheSubject", defaultValue: "Click or draw a box around the subject")
    var canCreate: Bool { !busy && !combining && (wholePerson || !analyzingParts) && preview != nil }
    var canResetFace: Bool {
        guard selectedPeople.count == 1, let person = selectedPeople.first, !analyzingParts else { return false }
        return faceRegions[person] != nil || faceFailure != nil || mode == .face
    }
    var creationSelections: [SmartMaskRaster] {
        guard let preview else { return [] }
        let parts = wholePerson ? [] : SmartMaskPart.allCases.filter { selectedParts.contains($0) }.compactMap { self.parts?[$0] }
        return parts.isEmpty ? [preview] : parts
    }
    var creationCount: Int {
        guard preview != nil else { return 0 }
        if case .newMask = target, separate, !wholePerson, parts != nil { return creationSelections.count }
        return 1
    }
    func raster(for target: SmartMaskInspectionTarget) -> SmartMaskRaster? {
        guard ready else { return nil }
        switch target {
        case .person(let index): return workflow == .people && people.indices.contains(index) ? people[index].raster : nil
        case .allPeople: return workflow == .people ? allPeople : nil
        case .wholePerson: return workflow == .people ? instance : nil
        case .part(let part): return workflow == .people && !analyzingParts ? parts?[part] : nil
        case .candidate(let index): return workflow == .object && !busy && candidates.indices.contains(index) ? candidates[index].raster : nil
        }
    }
    var inspectedRaster: SmartMaskRaster? { inspection.target.flatMap { raster(for: $0) } }
    var displayedRaster: SmartMaskRaster? { inspectedRaster ?? preview }
    var pointerInstruction: String {
        if !ready { return L10n.text("app.preparingPleaseWait", defaultValue: "Preparing, please wait…") }
        if workflow == .people && mode != .face { return L10n.text("smartMask.peopleSelectionHelp", defaultValue: "Select one or more people on the right, then the whole person or body parts") }
        switch mode {
        case .include: return L10n.text("app.clickToAddASubjectOptionClickToExclude", defaultValue: "Click to add a subject · Option-click to exclude")
        case .exclude: return L10n.text("app.clickAnAreaToExclude", defaultValue: "Click an area to exclude")
        case .box: return L10n.text("app.dragFromOneCornerToTheOppositeCornerAround", defaultValue: "Drag from one corner to the opposite corner around the subject")
        case .face: return L10n.text("app.dragARectangleContainingTheEntireFace", defaultValue: "Drag a rectangle containing the entire face")
        }
    }
    func acceptsRecipe(_ recipe: EditRecipe) -> Bool {
        guard source.matches(recipe) else { return false }
        switch target {
        case .newMask: return true
        case .append(let id, _): return recipe.localAdjustments.contains { $0.id == id }
        case .replace(let id, let component): return recipe.localAdjustments.contains { $0.id == id && $0.components.contains { $0.id == component } }
        }
    }
}

extension AppModel {
    func inspectSmartMask(_ target: SmartMaskInspectionTarget, hovering: Bool, sessionID: UUID) {
        guard let session = smartMaskSession, session.id == sessionID else { return }
        if hovering {
            guard session.raster(for: target) != nil else { return }
            session.inspection.hovered = target
        } else if session.inspection.hovered == target { session.inspection.hovered = nil }
    }
    func focusSmartMask(_ target: SmartMaskInspectionTarget?, sessionID: UUID) {
        guard let session = smartMaskSession, session.id == sessionID else { return }
        session.inspection.focused = target.flatMap { session.raster(for: $0) != nil ? $0 : nil }
    }
    func selectFocusedSmartMask() {
        guard let session = smartMaskSession, let target = session.inspection.focused, session.raster(for: target) != nil else { return }
        switch target {
        case .person(let index): chooseSmartPerson(index)
        case .allPeople: selectAllSmartPeople()
        case .part(let part): toggleSmartPart(part)
        case .candidate(let index): chooseSmartCandidate(index)
        case .wholePerson: selectWholeSmartPerson()
        }
    }
    func cancelSmartMask() {
        smartMaskSession?.inspection.clear()
        smartMaskTask?.cancel(); smartMaskTask = nil
        smartMaskPreviewTask?.cancel(); smartMaskPreviewTask = nil
        smartMaskGeneration = UUID(); smartMaskPreviewGeneration = UUID()
        smartMaskSession = nil
    }
    func beginSmartMask(operation: MaskOperation = .replace, replacing: Bool = false, workflow: SmartMaskWorkflow = .object) {
        guard canEdit, commitRecipe(), let photo = active, let recipe, let size = orientedSourceSize,
              let catalog, let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        let component = selectedMaskComponent
        let savedPerson = component?.raster?.isPersonSelection ?? false
        let requestedWorkflow: SmartMaskWorkflow = replacing && savedPerson ? .people : workflow
        let models = SmartMaskEngine.bundledModels
        guard requestedWorkflow == .people || models.objectDirectory != nil else {
            error = L10n.text("smartMask.objectUnavailable", defaultValue: "Object selection is not included in this build"); return
        }
        let target: SmartMaskTarget
        if replacing, let group = selectedMaskID, let id = component?.id { target = .replace(group, id) }
        else if operation != .replace, let group = selectedMaskID { target = .append(group, operation) }
        else { target = .newMask }
        let seed: SmartMaskRaster?
        if let saved = component?.raster, replacing {
            if let instance = saved.instance { seed = SmartMaskRaster(source: saved.source, model: String(saved.model.split(separator: "+").first ?? "stored-instance"), base: instance) }
            else { seed = saved }
        } else { seed = nil }
        setMaskMode(true); cancelSmartMask()
        maskChoosingTool = false; maskGesture = nil; showMaskOverlay = true; showMaskGuides = true
        let request = ImageRequest(photo: photo, root: root, recipe: recipe)
        var session = SmartMaskSession(photoID: photo.id, catalogPath: catalog.fileURL.path, request: request,
            source: SmartMaskSource(recipe: recipe, size: size), target: target)
        session.workflow = requestedWorkflow
        session.busy = true; session.message = session.workflow == .people ? L10n.text("app.findingPeopleInThePhoto", defaultValue: "Finding people in the photo…") : L10n.text("app.preparingPointSelection", defaultValue: "Preparing point selection…")
        session.wholePerson = session.workflow == .people && seed == nil
        if let seed { session.instance = seed; session.preview = seed }
        if replacing, let saved = component?.raster, !saved.parts.isEmpty { session.selectedParts = Set(saved.parts) }
        smartMaskSession = session
        if smartMaskEngine == nil { smartMaskEngine = SmartMaskEngine(models: models) }
        let engine = smartMaskEngine!
        let pipeline = smartMaskPipeline ?? ImagePipeline(); smartMaskPipeline = pipeline
        let id = session.id, token = UUID(); smartMaskGeneration = token
        smartMaskTask = Task {
            do {
                let input = try await pipeline.smartMaskInput(request)
                guard acceptSmartMask(id: id, token: token) else { return }
                smartMaskSession?.image = input.image
                if session.workflow == .people {
                    if let seed {
                        let bounds = try await engine.bounds(of: seed) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                        guard acceptSmartMask(id: id, token: token) else { return }
                        smartMaskSession?.people = [SmartMaskPerson(raster: seed, bounds: bounds, thumbnail: nil)]
                        smartMaskSession?.allPeople = seed
                    } else {
                        let people = try await engine.people(image: input.image, source: session.source, baseline: SmartMaskBaseline(recipe))
                        let allPeople = people.isEmpty ? nil : (try await engine.combinePeople(people.map(\.raster)))
                        guard acceptSmartMask(id: id, token: token) else { return }
                        smartMaskSession?.people = people
                        smartMaskSession?.allPeople = allPeople
                    }
                    smartMaskSession?.busy = false; smartMaskSession?.ready = true; smartMaskTask = nil
                    let hasPeople = smartMaskSession?.people.isEmpty == false
                    smartMaskSession?.message = hasPeople ? L10n.text("app.selectAPersonToAdjust", defaultValue: "Select a person to adjust") : L10n.text("app.noPeopleDetectedUseObjectPointOrBoxSelection", defaultValue: "No people detected. Use object point or box selection instead")
                    if seed != nil {
                        chooseSmartPerson(0, whole: component?.raster?.parts.isEmpty ?? true)
                        if !models.hasParts, let saved = component?.raster { smartMaskSession?.preview = saved }
                    }
                } else {
                    try await engine.prepare(image: input.image, source: session.source)
                    guard acceptSmartMask(id: id, token: token) else { return }
                    smartMaskSession?.busy = false; smartMaskSession?.ready = true; smartMaskTask = nil
                    smartMaskSession?.message = L10n.text("app.readyClickTheSubjectInThePhoto", defaultValue: "Ready · Click the subject in the photo")
                }
            } catch { finishSmartMaskError(error, id: id, token: token) }
        }
    }
    func acceptSmartMask(id: UUID, token: UUID) -> Bool {
        guard !Task.isCancelled, let session = smartMaskSession, session.id == id,
              token == smartMaskGeneration, maskMode, editMode, session.photoID == activeID,
              catalog?.fileURL.path == session.catalogPath, let recipe, session.source.matches(recipe) else { return false }
        switch session.target {
        case .newMask: return true
        case .append(let group, _): return recipe.localAdjustments.contains { $0.id == group }
        case .replace(let group, let component): return recipe.localAdjustments.contains { $0.id == group && $0.components.contains { $0.id == component } }
        }
    }
    private func finishSmartMaskError(_ failure: Error, id: UUID, token: UUID) {
        guard acceptSmartMask(id: id, token: token) else { return }
        smartMaskSession?.inspection.clear()
        smartMaskSession?.busy = false; smartMaskSession?.analyzingParts = false; smartMaskSession?.combining = false; smartMaskTask = nil
        if smartMaskSession?.workflow == .object { smartMaskSession?.preview = nil; smartMaskSession?.candidates = [] }
        if !(failure is CancellationError) {
            smartMaskSession?.analysisError = failure.localizedDescription
            smartMaskSession?.message = failure.localizedDescription; error = failure.localizedDescription
        }
    }
    func smartMaskPointer(_ point: MaskPoint?, phase: MaskPointerPhase, modifiers: NSEvent.ModifierFlags) {
        guard var session = smartMaskSession, session.ready, !session.combining,
              session.workflow == .object || session.mode == .face else { return }
        if phase == .down { session.inspection.clear(); session.dragStart = point; session.dragEnd = point; smartMaskSession = session; return }
        if phase == .drag {
            if session.mode == .box || session.mode == .face { session.dragEnd = point; smartMaskSession = session }
            return
        }
        guard let start = session.dragStart, let end = point else { smartMaskSession?.dragStart = nil; smartMaskSession?.dragEnd = nil; return }
        session.dragStart = nil; session.dragEnd = nil
        smartMaskSession = session
        if session.mode == .face {
            smartMaskSession = session
            guard let region = SmartMaskField.region(start, end) else { smartMaskSession?.message = L10n.text("app.drawARectangleContainingTheEntireFace", defaultValue: "Draw a rectangle containing the entire face"); return }
            analyzeSmartParts(face: SmartMaskField.faceRegion(region, size: session.source.size)); return
        }
        session.promptHistory.append(session.prompts)
        if session.mode == .box {
            guard let region = SmartMaskField.region(start, end) else { smartMaskSession?.message = L10n.text("app.drawARectangleContainingTheSubject", defaultValue: "Draw a rectangle containing the subject"); return }
            session.prompts = [SmartMaskPrompt(point: MaskPoint(region.minX, region.maxY), label: 2), SmartMaskPrompt(point: MaskPoint(region.maxX, region.minY), label: 3)]
        } else {
            guard session.prompts.count < 64 else { smartMaskSession?.message = L10n.text("app.the64PromptLimitWasReachedUndoAPrompt", defaultValue: "The 64-prompt limit was reached. Undo a prompt or draw a new box"); return }
            let exclude = session.mode == .exclude || modifiers.contains(.option)
            guard !exclude || session.prompts.contains(where: { $0.label != 0 }) else { smartMaskSession?.message = L10n.text("app.selectAnObjectBeforeAddingExclusionPoints", defaultValue: "Select an object before adding exclusion points"); return }
            guard hypot(start.x - end.x, start.y - end.y) < 0.01 else {
                smartMaskSession?.message = L10n.text("app.clickModeIsActiveChooseBoxSelectionBeforeDragging", defaultValue: "Click mode is active. Choose Box Selection before dragging"); return
            }
            session.prompts.append(SmartMaskPrompt(point: start, label: exclude ? 0 : 1))
        }
        session.parts = nil; session.instance = nil
        smartMaskSession = session; runSmartSelection()
    }
    func undoSmartPrompt() {
        guard var session = smartMaskSession, session.workflow == .object, session.ready, let previous = session.promptHistory.popLast() else { return }
        session.inspection.clear()
        smartMaskPreviewTask?.cancel(); smartMaskPreviewGeneration = UUID()
        session.combining = false
        session.analysisError = nil
        session.prompts = previous; session.parts = nil; session.instance = nil; session.preview = nil
        session.candidates = []; smartMaskSession = session
        if !previous.isEmpty { runSmartSelection() }
        else { smartMaskTask?.cancel(); smartMaskGeneration = UUID(); smartMaskSession?.busy = false }
    }
    private func runSmartSelection() {
        guard let session = smartMaskSession, let image = session.image, let engine = smartMaskEngine else { return }
        session.inspection.clear()
        smartMaskTask?.cancel(); smartMaskPreviewTask?.cancel()
        let token = UUID(); smartMaskGeneration = token
        smartMaskSession?.busy = true; smartMaskSession?.message = L10n.text("app.recognizingObject", defaultValue: "Recognizing object…")
        smartMaskSession?.analysisError = nil
        smartMaskTask = Task {
            do {
                let candidates = try await engine.select(image: image, source: session.source, prompts: session.prompts)
                guard acceptSmartMask(id: session.id, token: token) else { return }
                smartMaskSession?.candidates = candidates; smartMaskSession?.candidate = 0
                smartMaskSession?.busy = false; smartMaskTask = nil
                chooseSmartCandidate(0)
            } catch { finishSmartMaskError(error, id: session.id, token: token) }
        }
    }
    func chooseSmartCandidate(_ index: Int) {
        guard let session = smartMaskSession, !session.busy, session.candidates.indices.contains(index) else { return }
        session.inspection.didSelect(.candidate(index))
        let candidate = session.candidates[index]
        smartMaskSession?.candidate = index; smartMaskSession?.preview = candidate.selectedPixels > 0 ? candidate.raster : nil
        smartMaskSession?.analysisError = nil
        smartMaskSession?.instance = candidate.selectedPixels > 0 ? candidate.raster : nil
        smartMaskSession?.parts = nil
        smartMaskSession?.message = candidate.selectedPixels > 0 ? L10n.text("app.selectionUpdatedContinueClickingToRefineItOrCreate", defaultValue: "Selection updated · Continue clicking to refine it or create a mask") : L10n.text("app.thisCandidateHasNoSelectedAreaChooseAnotherCandidate", defaultValue: "This candidate has no selected area. Choose another candidate or draw a new box")
    }
    func chooseSmartPerson(_ index: Int, whole: Bool? = nil) {
        guard let session = smartMaskSession, session.ready, session.people.indices.contains(index) else { return }
        session.inspection.didSelect(.person(index))
        var selected = session.selectedPeople
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        selectSmartPeople(selected, whole: whole)
    }
    func selectAllSmartPeople() {
        guard let session = smartMaskSession, session.ready, !session.people.isEmpty else { return }
        session.inspection.didSelect(.allPeople)
        let all = Set(session.people.indices)
        selectSmartPeople(session.selectedPeople == all ? [] : all)
    }
    func selectSmartPeople(_ indices: Set<Int>, whole: Bool? = nil) {
        guard let session = smartMaskSession, session.ready, session.workflow == .people,
              indices.allSatisfy({ session.people.indices.contains($0) }) else { return }
        session.inspection.hovered = nil
        smartMaskTask?.cancel(); smartMaskTask = nil
        smartMaskPreviewTask?.cancel(); smartMaskPreviewTask = nil
        smartMaskGeneration = UUID(); smartMaskPreviewGeneration = UUID()
        let useWhole = whole ?? (session.selectedPeople.isEmpty ? true : session.wholePerson)
        let instance = indices.isEmpty ? nil : indices.count == session.people.count ? session.allPeople
            : indices.count == 1 ? session.people[indices.first!].raster : nil
        smartMaskSession?.selectedPeople = indices; smartMaskSession?.wholePerson = useWhole
        smartMaskSession?.analysisError = nil
        smartMaskSession?.instance = instance; smartMaskSession?.preview = useWhole ? instance : nil
        smartMaskSession?.parts = nil; smartMaskSession?.faces = []; smartMaskSession?.selectedFace = nil
        smartMaskSession?.faceRefined = false; smartMaskSession?.unrefinedPeople = []; smartMaskSession?.faceFailure = nil
        smartMaskSession?.combining = !indices.isEmpty && instance == nil; smartMaskSession?.mode = .include
        smartMaskSession?.analyzingParts = !indices.isEmpty && session.models.hasParts
        guard !indices.isEmpty else {
            smartMaskSession?.message = L10n.text("app.selectAPersonToAdjust", defaultValue: "Select a person to adjust")
            return
        }
        analyzeSmartParts()
    }
    func selectWholeSmartPerson() {
        guard let instance = smartMaskSession?.instance else { return }
        smartMaskSession?.inspection.didSelect(.wholePerson)
        smartMaskPreviewTask?.cancel(); smartMaskPreviewGeneration = UUID()
        smartMaskSession?.wholePerson = true; smartMaskSession?.combining = false; smartMaskSession?.preview = instance
        smartMaskSession?.analysisError = nil
    }
    func analyzeSmartParts(face manual: CGRect? = nil) {
        guard var session = smartMaskSession, session.workflow == .people, let image = session.image, !session.selectedPeople.isEmpty,
              manual == nil || session.selectedPeople.count == 1,
              let engine = smartMaskEngine, let pipeline = smartMaskPipeline else { return }
        if let manual, let index = session.selectedPeople.first {
            session.faceRegions[index] = manual
            smartMaskSession?.faceRegions = session.faceRegions
        }
        session.inspection.hovered = nil
        smartMaskTask?.cancel(); smartMaskPreviewTask?.cancel()
        let token = UUID(); smartMaskGeneration = token
        smartMaskSession?.analyzingParts = session.models.hasParts
        smartMaskSession?.analysisError = nil
        smartMaskSession?.faceFailure = nil
        smartMaskSession?.message = L10n.text("app.fullPersonSelectionReadyAnalyzingBodyParts", defaultValue: "Full-person selection ready. Analyzing body parts…")
        smartMaskTask = Task {
            do {
                let indices = session.selectedPeople.sorted()
                let instance: SmartMaskRaster
                if let cached = session.instance { instance = cached }
                else { instance = try await engine.combinePeople(indices.map { session.people[$0].raster }) }
                guard acceptSmartMask(id: session.id, token: token) else { return }
                smartMaskSession?.instance = instance; smartMaskSession?.combining = false
                if smartMaskSession?.wholePerson == true { smartMaskSession?.preview = instance }
                guard session.models.hasParts else {
                    smartMaskTask = nil
                    smartMaskSession?.message = L10n.text("smartMask.wholePersonOnly", defaultValue: "Whole-person selection is ready. Body-part selection is not included in this build")
                    return
                }
                var results: [SmartMaskPersonAnalysis] = []
                for index in indices {
                    try Task.checkCancellation()
                    results.append(try await engine.analyzePerson(image: image, selection: session.people[index].raster,
                        request: session.request, pipeline: pipeline, face: session.faceRegions[index]))
                }
                var parts: [SmartMaskPart: SmartMaskRaster] = [:]
                for part in SmartMaskPart.allCases {
                    let rasters = results.compactMap { $0.parts[part] }
                    if !rasters.isEmpty {
                        var raster = try await engine.combinePeople(rasters)
                        // Each input was clipped to its own instance; all inputs belong to
                        // this selected set. Use that set as the shared refinement boundary.
                        raster.instance = instance.base; parts[part] = raster
                    }
                }
                guard acceptSmartMask(id: session.id, token: token) else { return }
                let faces = results.count == 1 ? results[0].faces : []
                let refined = results.allSatisfy(\.faceRefined)
                smartMaskSession?.parts = parts; smartMaskSession?.faces = faces
                smartMaskSession?.faceRefined = refined
                smartMaskSession?.unrefinedPeople = Set(zip(indices, results).filter { !$0.1.faceRefined }.map(\.0))
                smartMaskSession?.faceFailure = results.compactMap(\.faceFailure).first
                smartMaskSession?.selectedFace = faces.firstIndex {
                    session.faceRegions[indices[0]] == SmartMaskField.faceRegion($0, size: session.source.size)
                }
                smartMaskSession?.mode = .include; smartMaskSession?.analyzingParts = false; smartMaskTask = nil
                smartMaskSession?.message = session.models.faceURL == nil ? L10n.text("smartMask.coarsePartsReady", defaultValue: "Body parts are ready. Fine facial selection is not included in this build")
                    : results.contains(where: { $0.faceFailure != nil }) ? L10n.text("smartMask.faceFailed", defaultValue: "Fine facial selection failed. Existing body parts remain available; select one person to retry automatic face detection.")
                    : refined ? L10n.text("app.selectBodyPartsPreviewThenCreateTheMaskUse", defaultValue: "Select body parts, preview, then create the mask. Use a brush to repair occlusions and fine edges")
                    : results.count > 1 ? L10n.text("smartMask.someFacesUnresolved", defaultValue: "Some faces could not be located. Select one person to refine their face region; existing parts remain available.")
                    : faces.count > 1 ? L10n.text("app.multipleFacesFoundSelectOneOrDrawAFace", defaultValue: "Multiple faces found. Select one or draw a face box manually")
                    : L10n.text("app.noFaceLocatedAutomaticallyDrawAFaceBoxOr", defaultValue: "No face located automatically. Draw a face box or use the existing body parts")
                if smartMaskSession?.wholePerson == false { refreshSmartPartsPreview() }
            } catch { finishSmartMaskError(error, id: session.id, token: token) }
        }
    }
    func chooseSmartFace(_ index: Int) {
        guard let session = smartMaskSession, session.models.faceURL != nil, session.selectedPeople.count == 1, session.faces.indices.contains(index) else { return }
        smartMaskSession?.selectedFace = index
        analyzeSmartParts(face: SmartMaskField.faceRegion(session.faces[index], size: session.source.size))
    }
    func resetSmartFace() {
        guard let session = smartMaskSession, session.models.faceURL != nil, session.canResetFace,
              let person = session.selectedPeople.first else { return }
        smartMaskSession?.faceRegions[person] = nil
        smartMaskSession?.selectedFace = nil; smartMaskSession?.mode = .include
        analyzeSmartParts()
    }
    func toggleSmartPart(_ part: SmartMaskPart) {
        guard smartMaskSession?.analyzingParts == false, smartMaskSession?.parts?[part] != nil else { return }
        smartMaskSession?.inspection.didSelect(.part(part))
        if smartMaskSession?.wholePerson == true { smartMaskSession?.selectedParts = [] }
        smartMaskSession?.wholePerson = false
        if smartMaskSession?.selectedParts.contains(part) == true { smartMaskSession?.selectedParts.remove(part) }
        else { smartMaskSession?.selectedParts.insert(part) }
        refreshSmartPartsPreview()
    }
    private func refreshSmartPartsPreview() {
        guard let session = smartMaskSession, let parts = session.parts, let engine = smartMaskEngine else { return }
        smartMaskPreviewTask?.cancel(); let token = UUID(); smartMaskPreviewGeneration = token
        smartMaskSession?.analysisError = nil
        let rasters = SmartMaskPart.allCases.filter { session.selectedParts.contains($0) }.compactMap { parts[$0] }
        guard !rasters.isEmpty else { smartMaskSession?.combining = false; smartMaskSession?.preview = nil; return }
        smartMaskSession?.combining = true
        smartMaskPreviewTask = Task {
            do {
                let preview = session.selectedPeople.count > 1 ? (try await engine.combinePeople(rasters)) : (try await engine.combine(rasters))
                guard !Task.isCancelled, smartMaskSession?.id == session.id, smartMaskPreviewGeneration == token else { return }
                smartMaskSession?.preview = preview; smartMaskSession?.combining = false; smartMaskPreviewTask = nil
            } catch {
                guard !Task.isCancelled, smartMaskSession?.id == session.id, smartMaskPreviewGeneration == token else { return }
                smartMaskSession?.analysisError = error.localizedDescription
                smartMaskSession?.combining = false; smartMaskSession?.message = error.localizedDescription
            }
        }
    }
    var smartMaskPreviewGroup: LocalAdjustment? {
        guard let session = smartMaskSession, let raster = session.displayedRaster else { return nil }
        return smartMaskPreviewGroup(for: raster, in: session)
    }
    func smartMaskPreviewGroup(for raster: SmartMaskRaster, in session: SmartMaskSession) -> LocalAdjustment? {
        var component = MaskComponent(tool: .object); component.id = session.id; component.raster = raster
        switch session.target {
        case .newMask:
            var group = LocalAdjustment(components: [component]); group.id = session.id; return group
        case .append(let id, let operation):
            guard var group = recipe?.localAdjustments.first(where: { $0.id == id }) else { return nil }
            component.operation = operation; group.components.append(component); return group
        case .replace(let id, let target):
            guard var group = recipe?.localAdjustments.first(where: { $0.id == id }), let index = group.components.firstIndex(where: { $0.id == target }) else { return nil }
            group.components[index].raster = raster; return group
        }
    }
    func createSmartMask() {
        guard let session = smartMaskSession, session.canCreate, let preview = session.preview,
              let recipe, session.photoID == activeID, session.source.matches(recipe), catalog?.fileURL.path == session.catalogPath, commitRecipe() else { return }
        var next = recipe, selectedGroup: UUID?, selectedComponent: UUID?
        func component(_ raster: SmartMaskRaster, operation: MaskOperation = .replace) -> MaskComponent {
            var c = MaskComponent(tool: .object, operation: operation); c.raster = raster
            c.name = raster.parts.isEmpty ? (session.workflow == .people ? L10n.text("app.wholePerson", defaultValue: "Whole Person") : L10n.text("app.object", defaultValue: "Object")) : raster.parts.map(\.title).joined(separator: "、"); return c
        }
        switch session.target {
        case .newMask:
            let selections = session.creationSelections
            if session.separate && !session.wholePerson && session.parts != nil {
                for raster in selections {
                    let c = component(raster)
                    var group = LocalAdjustment(components: [c]); group.name = c.name; group.settings = LocalDevelopSettings()
                    next.localAdjustments.append(group)
                    if selectedGroup == nil { selectedGroup = group.id; selectedComponent = c.id }
                }
            } else {
                let components = selections.enumerated().map { component($0.element, operation: $0.offset == 0 ? .replace : .add) }
                var group = LocalAdjustment(components: components); group.settings = LocalDevelopSettings()
                group.name = session.workflow == .people ? (session.wholePerson ? L10n.text("app.wholePersonMask", defaultValue: "Whole Person Mask") : L10n.text("app.personParts", defaultValue: "Person Parts")) + " \(next.localAdjustments.count + 1)" : L10n.text("app.object_369", defaultValue: "Object \(next.localAdjustments.count + 1)")
                next.localAdjustments.append(group); selectedGroup = group.id; selectedComponent = components.first?.id
            }
        case .append(let id, let operation):
            guard let index = next.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            let c = component(preview, operation: operation); next.localAdjustments[index].components.append(c)
            selectedGroup = id; selectedComponent = c.id
        case .replace(let id, let target):
            guard let index = next.localAdjustments.firstIndex(where: { $0.id == id }), let c = next.localAdjustments[index].components.firstIndex(where: { $0.id == target }) else { return }
            next.localAdjustments[index].components[c].raster = preview
            next.localAdjustments[index].components[c].name = component(preview).name
            selectedGroup = id; selectedComponent = target
        }
        next.schemaVersion = 3; next.maskVersion = 3
        do { try next.validate() } catch { self.error = error.localizedDescription; return }
        changeRecipe({ $0 = next }, commit: false)
        guard self.recipe == next, commitRecipe(title: L10n.text("app.createSmartMask", defaultValue: "Create Smart Mask")) else { return }
        undo.setActionName(L10n.text("app.createSmartMask", defaultValue: "Create Smart Mask")); cancelSmartMask()
        selectedMaskID = selectedGroup; selectedComponentID = selectedComponent
        maskChoosingTool = false; showMaskOverlay = true; maskDrawNew = false
        status = L10n.text("app.smartMaskSavedUndoRefineOrAddABrush", defaultValue: "Smart mask saved · Undo, refine, or add a brush")
    }
}
