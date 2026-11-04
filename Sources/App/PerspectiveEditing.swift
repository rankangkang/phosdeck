import Foundation
import CoreGraphics

enum PerspectiveGuideTool { case straighten, perspective }

extension AppModel {
    func finishPerspectiveGuides() {
        perspectiveGuideTool = nil; perspectiveGuides = []; perspectiveGuideBase = nil; perspectiveMessage = ""
        cancelUprightAnalysis()
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

    func addPerspectiveGuide(start: MaskPoint, end: MaskPoint) {
        guard let tool = perspectiveGuideTool, workspaceAvailable, canEdit, canvasCoordinatesCurrent,
              let size = orientedSourceSize, let current = recipe, let base = perspectiveGuideBase,
              let line = UprightCorrection.classified(start: start, end: end, size: size, recipe: current) else { return }
        var lines = perspectiveGuides
        if tool == .straighten { lines = [] }
        guard lines.count < 4 else {
            perspectiveMessage = L10n.text("geometry.fourGuides", defaultValue: "Up to four guides. Clear the guides to start again."); return
        }
        lines.append(line)
        perspectiveGuides = lines
        if tool == .perspective && lines.count < 2 {
            perspectiveMessage = L10n.text("geometry.secondGuide", defaultValue: "Draw another horizontal or vertical edge."); return
        }
        guard let solved = UprightCorrection.guided(lines, size: size, recipe: base, straightenOnly: tool == .straighten) else {
            perspectiveGuides.removeLast()
            perspectiveMessage = L10n.text("geometry.noAgreement", defaultValue: "The lines do not support a correction. The current edit is preserved."); return
        }
        applyPerspectiveSolution(solved, title: tool == .straighten ? L10n.text("geometry.straighten", defaultValue: "Straighten by Line") : L10n.text("geometry.guided", defaultValue: "Guided Perspective"))
        perspectiveMessage = ""
        if tool == .straighten { finishPerspectiveGuides() }
    }

    func applyPerspectiveSolution(_ solved: EditRecipe, title: String) {
        applyingPerspective = true
        defer { applyingPerspective = false }
        changeRecipe({ $0.perspective = solved.perspective; $0.straightenDegrees = solved.straightenDegrees }, title: title)
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
