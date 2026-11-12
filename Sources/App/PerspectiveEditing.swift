import Foundation
import CoreGraphics

enum PerspectiveGuideTool { case straighten, perspective }
enum PerspectiveGuideEndpoint: Equatable { case start, end }

extension AppModel {
    func finishPerspectiveGuides() {
        perspectiveGuideTool = nil; perspectiveGuides = []; perspectiveGuideBase = nil
        selectedPerspectiveGuideIndex = nil; selectedPerspectiveGuideEndpoint = nil
        perspectiveGuideDragOriginal = nil; perspectiveMessage = ""
        cancelUprightAnalysis()
    }

    func cancelPerspectiveGuideInteraction() {
        if let original = perspectiveGuideDragOriginal {
            let wasDirty = original.dirty
            var restored = recipe ?? original.recipe
            restored.perspective = original.recipe.perspective
            restored.straightenDegrees = original.recipe.straightenDegrees
            let otherEditsChanged = restored != original.recipe
            applyingPerspective = true
            changeRecipe({ $0 = restored }, commit: false)
            applyingPerspective = false
            dirty = wasDirty || otherEditsChanged
            perspectiveGuides = original.lines
            perspectiveGuideDragOriginal = nil
        }
        finishPerspectiveGuides()
    }

    func cancelUprightAnalysis() {
        uprightTask?.cancel(); uprightTask = nil; uprightAnalyzing = false; uprightGeneration = UUID()
    }

    func beginPerspectiveGuides(_ tool: PerspectiveGuideTool) {
        guard workspaceAvailable, canEdit, cropMode, let recipe, commitRecipe() else { return }
        if perspectiveGuideTool == tool { finishPerspectiveGuides(); return }
        finishPerspectiveGuides()
        perspectiveGuideTool = tool; perspectiveGuideBase = recipe; perspectiveMessage = ""
    }

    func clearPerspectiveGuides() {
        guard perspectiveGuideTool != nil else { return }
        perspectiveGuides = []; perspectiveGuideBase = recipe
        selectedPerspectiveGuideIndex = nil; selectedPerspectiveGuideEndpoint = nil
        perspectiveGuideDragOriginal = nil; perspectiveMessage = ""
    }

    @discardableResult
    func beginPerspectiveGuideDrag(index: Int, endpoint: PerspectiveGuideEndpoint) -> Bool {
        guard perspectiveGuideTool != nil, canEdit, perspectiveGuides.indices.contains(index), let recipe else { return false }
        if perspectiveGuideDragOriginal == nil {
            perspectiveGuideDragOriginal = (recipe: recipe, lines: perspectiveGuides, dirty: dirty)
        }
        selectedPerspectiveGuideIndex = index
        selectedPerspectiveGuideEndpoint = endpoint
        return true
    }

    @discardableResult
    func updatePerspectiveGuide(index: Int, endpoint: PerspectiveGuideEndpoint, point: MaskPoint) -> Bool {
        guard let tool = perspectiveGuideTool, let base = perspectiveGuideBase,
              let size = orientedSourceSize, let recipe, perspectiveGuides.indices.contains(index),
              canEdit, point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return false }
        var lines = perspectiveGuides
        var line = lines[index]
        switch endpoint {
        case .start: line.start = point
        case .end: line.end = point
        }
        guard let classified = UprightCorrection.classified(start: line.start, end: line.end, weight: line.weight, size: size, recipe: recipe) else {
            perspectiveMessage = L10n.text("geometry.noAgreement", defaultValue: "The lines do not support a correction. The current edit is preserved.")
            return false
        }
        lines[index] = classified
        if tool == .perspective && lines.count < 2 {
            if perspectiveGuideDragOriginal == nil {
                perspectiveGuideDragOriginal = (recipe: recipe, lines: perspectiveGuides, dirty: dirty)
            }
            perspectiveGuides = lines
            selectedPerspectiveGuideIndex = index; selectedPerspectiveGuideEndpoint = endpoint
            perspectiveMessage = ""
            return true
        }
        let solved = UprightCorrection.guided(lines, size: size, recipe: base, straightenOnly: tool == .straighten)
        guard let solved else {
            perspectiveMessage = L10n.text("geometry.noAgreement", defaultValue: "The lines do not support a correction. The current edit is preserved.")
            return false
        }
        if perspectiveGuideDragOriginal == nil {
            perspectiveGuideDragOriginal = (recipe: recipe, lines: perspectiveGuides, dirty: dirty)
        }
        perspectiveGuides = lines
        selectedPerspectiveGuideIndex = index; selectedPerspectiveGuideEndpoint = endpoint
        applyPerspectiveSolution(solved, title: tool == .straighten ? L10n.text("geometry.straighten", defaultValue: "Straighten by Line") : L10n.text("geometry.guided", defaultValue: "Guided Perspective"), commit: false)
        perspectiveMessage = ""
        return true
    }

    @discardableResult
    func endPerspectiveGuideDrag() -> Bool {
        guard perspectiveGuideDragOriginal != nil else { return true }
        let title = perspectiveGuideTool == .straighten
            ? L10n.text("geometry.straighten", defaultValue: "Straighten by Line")
            : L10n.text("geometry.guided", defaultValue: "Guided Perspective")
        let committed = commitRecipe(title: title)
        if committed { perspectiveGuideDragOriginal = nil }
        return committed
    }

    @discardableResult
    func selectPerspectiveGuide(index: Int?, endpoint: PerspectiveGuideEndpoint? = nil) -> Bool {
        guard let index else {
            selectedPerspectiveGuideIndex = nil; selectedPerspectiveGuideEndpoint = nil
            return true
        }
        guard perspectiveGuideTool != nil, perspectiveGuides.indices.contains(index) else { return false }
        selectedPerspectiveGuideIndex = index; selectedPerspectiveGuideEndpoint = endpoint
        return true
    }

    @discardableResult
    func deleteSelectedPerspectiveGuide() -> Bool {
        guard let tool = perspectiveGuideTool, let index = selectedPerspectiveGuideIndex,
              perspectiveGuides.indices.contains(index), let base = perspectiveGuideBase,
              let size = orientedSourceSize else { return false }
        let oldLines = perspectiveGuides
        var lines = oldLines; lines.remove(at: index)
        perspectiveGuideDragOriginal = nil
        selectedPerspectiveGuideIndex = nil; selectedPerspectiveGuideEndpoint = nil
        let minimum = tool == .straighten ? 1 : 2
        if lines.count < minimum {
            perspectiveGuides = lines
            applyPerspectiveSolution(base, title: L10n.text("geometry.deleteGuide", defaultValue: "Delete Guide"))
            perspectiveMessage = ""
            return true
        }
        guard let solved = UprightCorrection.guided(lines, size: size, recipe: base, straightenOnly: tool == .straighten) else {
            selectedPerspectiveGuideIndex = min(index, oldLines.count - 1)
            perspectiveMessage = L10n.text("geometry.noAgreement", defaultValue: "The lines do not support a correction. The current edit is preserved.")
            return false
        }
        perspectiveGuides = lines
        applyPerspectiveSolution(solved, title: L10n.text("geometry.deleteGuide", defaultValue: "Delete Guide"))
        perspectiveMessage = ""
        return true
    }

    func addPerspectiveGuide(start: MaskPoint, end: MaskPoint) {
        guard let tool = perspectiveGuideTool, workspaceAvailable, canEdit,
              let size = orientedSourceSize, let current = recipe, let base = perspectiveGuideBase,
              let line = UprightCorrection.classified(start: start, end: end, size: size, recipe: current) else { return }
        var lines = perspectiveGuides
        if tool == .straighten { lines = [] }
        guard lines.count < 4 else {
            perspectiveMessage = L10n.text("geometry.fourGuides", defaultValue: "Up to four guides. Clear the guides to start again."); return
        }
        lines.append(line)
        perspectiveGuides = lines
        selectedPerspectiveGuideIndex = lines.count - 1; selectedPerspectiveGuideEndpoint = nil
        if tool == .perspective && lines.count < 2 {
            perspectiveMessage = L10n.text("geometry.secondGuide", defaultValue: "Draw another horizontal or vertical edge."); return
        }
        guard let solved = UprightCorrection.guided(lines, size: size, recipe: base, straightenOnly: tool == .straighten) else {
            perspectiveGuides.removeLast()
            selectedPerspectiveGuideIndex = perspectiveGuides.indices.last
            selectedPerspectiveGuideEndpoint = nil
            perspectiveMessage = L10n.text("geometry.noAgreement", defaultValue: "The lines do not support a correction. The current edit is preserved."); return
        }
        applyPerspectiveSolution(solved, title: tool == .straighten ? L10n.text("geometry.straighten", defaultValue: "Straighten by Line") : L10n.text("geometry.guided", defaultValue: "Guided Perspective"))
        perspectiveMessage = ""
    }

    func applyPerspectiveSolution(_ solved: EditRecipe, title: String, commit: Bool = true) {
        applyingPerspective = true
        defer { applyingPerspective = false }
        changeRecipe({ $0.perspective = solved.perspective; $0.straightenDegrees = solved.straightenDegrees }, commit: commit, title: title)
    }

    func applyUpright(_ mode: UprightMode) {
        guard !uprightAnalyzing, workspaceAvailable, canEdit, cropMode, let photo = active, let recipe,
              let size = orientedSourceSize, let root = roots.first(where: { $0.id == photo.rootID }), commitRecipe() else { return }
        finishPerspectiveGuides(); perspectiveMessage = ""
        let token = UUID(); uprightGeneration = token; uprightAnalyzing = true
        let request = ImageRequest(photo: photo, root: root, recipe: recipe), detect = detectPerspectiveLines
        let catalogURL = catalog?.fileURL
        uprightTask = Task { [weak self] in
            defer {
                if let self, self.uprightGeneration == token { self.uprightTask = nil; self.uprightAnalyzing = false }
            }
            do {
                let detected = try await detect(request)
                guard !Task.isCancelled, let self, self.uprightGeneration == token,
                      self.activeID == photo.id, self.recipe == recipe, self.catalog?.fileURL == catalogURL,
                      self.cropMode, self.canEdit, self.workspaceAvailable else { return }
                let lines = detected.compactMap { UprightCorrection.classified(start: $0.start, end: $0.end, weight: $0.weight, size: size, recipe: recipe) }
                let result = UprightCorrection.automatic(mode, lines: lines, size: size, recipe: recipe)
                self.uprightTask = nil; self.uprightAnalyzing = false
                if let result { self.applyPerspectiveSolution(result, title: mode.title) }
                else { self.perspectiveMessage = L10n.text("geometry.noAgreement", defaultValue: "The lines do not support a correction. The current edit is preserved.") }
            } catch {
                guard let self, self.uprightGeneration == token else { return }
                self.uprightTask = nil; self.uprightAnalyzing = false
                if !(error is CancellationError) { self.perspectiveMessage = error.localizedDescription }
            }
        }
    }
}
