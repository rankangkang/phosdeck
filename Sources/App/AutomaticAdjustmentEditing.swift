import Foundation

extension AppModel {
    func cancelAutomaticAdjustment() {
        guard automaticAdjustmentKind != nil || automaticAdjustmentTask != nil else { return }
        automaticAdjustmentTask?.cancel(); automaticAdjustmentTask = nil
        automaticAdjustmentToken = UUID(); automaticAdjustmentKind = nil
    }

    /// One immutable request, one save/undo. No draft is published during analysis.
    func applyAutomaticAdjustment(_ kind: AutomaticAdjustmentKind) {
        applyAutomaticAdjustment(kind) { request, kind in
            let worker = Task.detached(priority: .userInitiated) {
                try await ImagePipeline.automaticAnalysis.automaticAdjustment(request, kind: kind)
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
    }
    func applyAutomaticAdjustment(_ kind: AutomaticAdjustmentKind,
        analyze: @escaping @Sendable (ImageRequest, AutomaticAdjustmentKind) async throws -> AutomaticAdjustmentResult) {
        guard automaticAdjustmentKind == nil, canEdit, editMode, commitRecipe(), selectDevelopTool(.adjust),
              let photo = active, let original = recipe, let catalog,
              let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        cancelTargetedAdjustment(); cancelWhiteBalanceSampling(); cancelPointColorTools(); cancelZoneSampling()
        before = false; beforeAfter = .off
        let token = UUID(); automaticAdjustmentToken = token; automaticAdjustmentKind = kind
        let request = ImageRequest(photo: photo, root: root, recipe: original)
        automaticAdjustmentTask = Task { [weak self] in
            defer { if self?.automaticAdjustmentToken == token { self?.cancelAutomaticAdjustment() } }
            do {
                let result = try await analyze(request, kind)
                guard let self, !Task.isCancelled, self.automaticAdjustmentToken == token,
                      self.automaticAdjustmentKind == kind, result.kind == kind, self.catalog === catalog,
                      self.canEdit, self.editMode, self.activeID == photo.id, self.active?.identity == photo.identity,
                      self.recipe == original, self.roots.first(where: { $0.id == root.id })?.bookmark == root.bookmark,
                      self.roots.first(where: { $0.id == root.id })?.path == root.path else { return }
                self.cancelAutomaticAdjustment()
                var proposed = original; result.apply(to: &proposed)
                guard proposed != original else { return }
                self.undo.beginUndoGrouping()
                self.changeRecipe({ $0 = proposed }, title: kind.title)
                self.undo.endUndoGrouping()
            } catch {
                guard let self, !Task.isCancelled, self.automaticAdjustmentToken == token else { return }
                self.cancelAutomaticAdjustment()
                self.showNotice(error.localizedDescription)
            }
        }
    }
}
