import Foundation
import CoreGraphics

struct TargetedReferenceKey: Equatable {
    let photoID: String
    let identity: Data
    let recipe: EditRecipe
}

extension AppModel {
    func cancelTargetedAdjustment(clearReference: Bool = false) {
        if let session = directAdjustment, case .targeted = session.kind { cancelDirectAdjustment() }
        targetedReferenceTask?.cancel(); targetedReferenceTask = nil; targetedReferenceToken = UUID()
        targetedAdjustment = nil; targetedSample = nil; targetedReferenceReady = false
        if clearReference { targetedReference = nil; targetedReferenceKey = nil }
    }

    func toggleTargetedAdjustment(_ target: TargetedAdjustment) {
        if targetedAdjustment == target { cancelTargetedAdjustment(); return }
        guard canEdit, editMode, let recipe, target.available(in: recipe), selectDevelopTool(.adjust) else { return }
        cancelTargetedAdjustment(); cancelWhiteBalanceSampling(); cancelPointColorTools(); cancelZoneSampling()
        before = false; beforeAfter = .off
        targetedAdjustment = target
        prepareTargetedReference()
    }

    private func prepareTargetedReference() {
        guard let target = targetedAdjustment, let recipe, let photo = active,
              let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        let input = target.referenceRecipe(recipe)
        let key = TargetedReferenceKey(photoID: photo.id, identity: photo.identity, recipe: input)
        if key == targetedReferenceKey, targetedReference != nil { targetedReferenceReady = true; return }
        targetedReferenceReady = false; targetedReference = nil; targetedReferenceKey = key
        let token = UUID(); targetedReferenceToken = token
        let request = ImageRequest(photo: photo, root: root, recipe: input)
        let renderer = targetedReferenceRenderer, pipeline = targetedPipeline
        targetedReferenceTask = Task { [weak self] in
            do {
                let reference: PointColorReference
                if let renderer { reference = try await renderer(request) }
                else { reference = try await pipeline.pointColorReference(request) }
                guard let self, !Task.isCancelled, self.targetedReferenceToken == token,
                      self.activeID == photo.id, self.targetedAdjustment != nil, self.targetedReferenceKey == key else { return }
                self.targetedReference = reference; self.targetedReferenceReady = true
                self.targetedReferenceTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.targetedReferenceToken == token else { return }
                self.cancelTargetedAdjustment(clearReference: true); self.showNotice(error.localizedDescription)
            }
        }
    }

    @discardableResult func beginTargetedAdjustment(at point: CGPoint) -> Bool {
        guard let target = targetedAdjustment, targetedReferenceReady, canEdit, canvasCoordinatesCurrent,
              let recipe, MaskPoint(point.x, point.y).valid,
              let rgb = targetedReference?.linearRGB(at: point), let sample = target.sample(rgb: rgb, recipe: recipe) else {
            if targetedReferenceReady { showNotice(L10n.text("app.targetNoSample", defaultValue: "No target at this point: transparent area or no adjustable color")) }
            return false
        }
        targetedSample = sample
        return beginTargetedAdjustment(sample: sample)
    }

    @discardableResult private func beginTargetedAdjustment(sample: TargetedSample) -> Bool {
        guard canEdit, editMode, developTool == .adjust, !before, beforeAfter == .off,
              targetedAdjustment == sample.target else { return false }
        cancelDirectAdjustment()
        guard commitRecipe(), let id = activeID, let recipe else { return false }
        do { _ = try sample.applying(delta: sample.target.step, to: recipe) }
        catch { showNotice(error.localizedDescription); return false }
        directAdjustment = DirectAdjustmentSession(photoID: id, original: recipe, latest: recipe,
            title: L10n.text("app.targetedAdjustmentTitle", defaultValue: "Targeted Adjustment · \(sample.target.title)"), kind: .targeted(sample))
        return true
    }

    func updateTargetedAdjustment(delta: Double) {
        guard delta.isFinite, let session = directAdjustment, case let .targeted(sample) = session.kind,
              session.photoID == activeID, recipe == session.latest, canEdit, targetedAdjustment == sample.target else { return }
        do {
            let value = try sample.applying(delta: delta, to: session.original)
            applyingDirectAdjustment = true
            changeRecipe({ $0 = value }, commit: false)
            applyingDirectAdjustment = false
            directAdjustment?.latest = recipe ?? session.latest
        } catch { showNotice(error.localizedDescription); cancelDirectAdjustment() }
    }

    @discardableResult func nudgeTargetedAdjustment(_ direction: Double) -> Bool {
        guard let sample = targetedSample, beginTargetedAdjustment(sample: sample) else { return false }
        updateTargetedAdjustment(delta: direction * sample.target.step)
        return finishDirectAdjustment()
    }
}
