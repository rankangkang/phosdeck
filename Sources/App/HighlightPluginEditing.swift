import CoreGraphics
import Foundation
import PhosdeckPluginKit

@MainActor
extension AppModel {
    struct HighlightDraft {
        let photo: Photo
        let catalogSession: String?
        let recipe: EditRecipe
        let group: LocalAdjustment
        let reference: CGImage
    }

    var currentHighlightDraft: HighlightDraft? {
        guard let draft = highlightDraft, draft.photo.id == activeID, draft.catalogSession == catalogSessionID,
              draft.photo.recipeRevision == active?.recipeRevision, draft.recipe == recipe else { return nil }
        return draft
    }

    func previewHighlights() {
        guard canEdit, editMode, !cropMode, !spotMode, canvasCoordinatesCurrent, commitRecipe(),
              let photo = active, let recipe, let size = orientedSourceSize,
              let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        cancelHighlightPreview()
        let session = catalogSessionID
        let generation = UUID()
        highlightGeneration = generation
        let source = ImageRequest(photo: photo, root: root, recipe: recipe)
        highlightWorking = true
        highlightTask = Task {
            defer {
                if highlightGeneration == generation { highlightTask = nil; highlightWorking = false }
            }
            do {
                let (reference, input) = try await ImagePipeline().highlightPluginSource(source, orientedSize: size)
                let result = try await PhotoToolHost.shared.evaluate(key: "select-highlights",
                    request: .init(revision: 0, purpose: .quality, parameters: .luminanceRange), input: input)
                guard case .luminanceRange(let range) = result else { return }
                guard !Task.isCancelled, highlightGeneration == generation, catalogSessionID == session,
                      activeID == photo.id, active?.recipeRevision == photo.recipeRevision, self.recipe == recipe else { return }
                var component = MaskComponent(tool: .luminance)
                component.lower = range.lower
                component.upper = range.upper
                component.smoothness = range.feather
                var group = LocalAdjustment(components: [component])
                group.name = L10n.text("plugins.highlights", defaultValue: "Highlights")
                group.settings = LocalDevelopSettings()
                highlightDraft = HighlightDraft(photo: photo, catalogSession: session, recipe: recipe, group: group, reference: reference)
            } catch {
                guard !Task.isCancelled, highlightGeneration == generation else { return }
                highlightMessage = L10n.text("plugins.highlightFailed", defaultValue: "The extension could not select highlights. Check Plugins in Settings.")
            }
        }
    }

    func cancelHighlightPreview() {
        highlightGeneration = UUID()
        highlightTask?.cancel()
        highlightTask = nil
        highlightWorking = false
        highlightDraft = nil
        highlightMessage = ""
    }
}
