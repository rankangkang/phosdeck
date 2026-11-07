import Foundation

struct DirectAdjustmentSession {
    enum Kind { case histogram(HistogramRegion), targeted(TargetedSample) }
    let photoID: String
    let original: EditRecipe
    var latest: EditRecipe
    let title: String
    let kind: Kind
}

extension AppModel {
    var canDragHistogram: Bool {
        workspaceAvailable && canEdit && editMode && developTool == .adjust && !before && beforeAfter == .off
    }

    @discardableResult func beginHistogramAdjustment(_ region: HistogramRegion) -> Bool {
        guard canDragHistogram else { return false }
        cancelTargetedAdjustment()
        cancelDirectAdjustment()
        guard commitRecipe(), let id = activeID, let recipe else { return false }
        directAdjustment = DirectAdjustmentSession(photoID: id, original: recipe, latest: recipe,
            title: region.title, kind: .histogram(region))
        return true
    }

    func updateHistogramAdjustment(delta: Double) {
        guard delta.isFinite, let session = directAdjustment, case let .histogram(region) = session.kind,
              session.photoID == activeID, recipe == session.latest, canDragHistogram else { return }
        let raw = region.value(in: session.original) + delta
        let value = min(region.range.upperBound, max(region.range.lowerBound, (raw / region.step).rounded() * region.step))
        applyingDirectAdjustment = true
        changeRecipe({ region.set(value, in: &$0) }, commit: false)
        applyingDirectAdjustment = false
        directAdjustment?.latest = recipe ?? session.latest
    }

    @discardableResult func finishDirectAdjustment() -> Bool {
        guard let session = directAdjustment else { return false }
        directAdjustment = nil
        guard session.photoID == activeID, recipe == session.latest else { return false }
        if session.latest == session.original {
            let redraw = dirty; dirty = false
            if redraw { requestPreview() }
            return true
        }
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        let saved = commitRecipe(title: session.title)
        if saved { undo.setActionName(session.title) }
        return saved
    }

    func cancelDirectAdjustment() {
        guard let session = directAdjustment else { return }
        directAdjustment = nil
        guard session.photoID == activeID, recipe == session.latest else { return }
        applyingDirectAdjustment = true
        recipe = session.original; dirty = false
        applyingDirectAdjustment = false
        if session.latest != session.original { requestPreview() }
    }

    func nudgeHistogram(_ region: HistogramRegion, direction: Double) {
        guard beginHistogramAdjustment(region) else { return }
        updateHistogramAdjustment(delta: region.step * direction)
        _ = finishDirectAdjustment()
    }
}
