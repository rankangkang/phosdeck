import CoreImage
import Foundation

extension AppModel {
    func cancelZoneSampling() {
        guard zoneSampling || zoneReference != nil || zoneReferenceTask != nil else { return }
        zoneReferenceTask?.cancel(); zoneReferenceTask = nil; zoneReferenceToken = UUID()
        zoneReference = nil; zoneSampling = false
    }
    func toggleZoneSampling() {
        if zoneSampling { cancelZoneSampling(); return }
        guard canEdit, commitRecipe(), let photo = active, let recipe,
              let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        cancelWhiteBalanceSampling()
        cancelPointColorTools()
        cropMode = false; maskMode = false; before = false; editMode = true
        zoneSampling = true; selectedZone = nil; sampledZoneEV = nil
        requestPreview()
        let token = UUID(); zoneReferenceToken = token
        let request = ImageRequest(photo: photo, root: root, recipe: recipe)
        zoneReferenceTask = Task {
            do {
                let reference = try await ImagePipeline().zoneReference(request)
                guard !Task.isCancelled, token == zoneReferenceToken, photo.id == activeID else { return }
                zoneReference = reference
            } catch {
                if !Task.isCancelled, token == zoneReferenceToken { self.error = error.localizedDescription; cancelZoneSampling() }
            }
            if token == zoneReferenceToken { zoneReferenceTask = nil }
        }
    }
    func sampleZone(at point: CGPoint) {
        guard zoneSampling, canEdit, canvasCoordinatesCurrent, MaskPoint(point.x, point.y).valid, let reference = zoneReference,
              let recipe, let size = orientedSourceSize, MaskGeometry.sourcePoint(point, size: size, recipe: recipe) != nil else { return }
        let x = PhotoGeometry.pixelIndex(point.x,dimension:reference.width)
        let y = PhotoGeometry.pixelIndex(point.y,dimension:reference.height)
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(CIImage(cgImage: reference), toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        guard pixel[0].isFinite, pixel[3] > 0 else { return }
        let ev = Double(pixel[0]/pixel[3])
        selectedZone = ToneZones.nearest(to: ev); sampledZoneEV = ev
        cancelZoneSampling()
    }
}

extension AppModel {
    func cancelWhiteBalanceSampling(keepTool: Bool = false) {
        whiteBalanceTask?.cancel(); whiteBalanceTask = nil; whiteBalanceToken = UUID()
        whiteBalanceSamplingBusy = false
        if !keepTool { whiteBalanceSampling = false }
    }
    func toggleWhiteBalanceSampling() {
        if whiteBalanceSampling { cancelWhiteBalanceSampling(); return }
        guard canEdit, editMode, commitRecipe(), selectDevelopTool(.adjust) else { return }
        cancelPointColorTools(); cancelZoneSampling()
        before = false; beforeAfter = .off
        whiteBalanceSampling = true
    }
    func sampleWhiteBalance(at point: CGPoint) {
        guard whiteBalanceSampling, !whiteBalanceSamplingBusy, canEdit, canvasCoordinatesCurrent,
              let photo = active, let original = recipe,
              let root = roots.first(where: { $0.id == photo.rootID }), commitRecipe() else { return }
        let token = UUID(); whiteBalanceToken = token; whiteBalanceSamplingBusy = true
        let request = ImageRequest(photo: photo, root: root, recipe: original)
        whiteBalanceTask = Task { [weak self] in
            do {
                let value = try await ImagePipeline().sampledWhiteBalance(request, at: point)
                guard let self, !Task.isCancelled, self.whiteBalanceToken == token,
                      self.activeID == photo.id, self.recipe == original, self.whiteBalanceSampling else { return }
                self.cancelWhiteBalanceSampling(keepTool: self.whiteBalanceContinuous)
                self.changeRecipe({ r in
                    r.asShotWhiteBalance = false; r.temperature = value.temperature; r.tint = value.tint
                }, title: L10n.text("app.sampleWhiteBalance", defaultValue: "Sample White Balance"))
            } catch {
                guard let self, !Task.isCancelled, self.whiteBalanceToken == token else { return }
                self.cancelWhiteBalanceSampling(keepTool: true)
                self.showNotice(error.localizedDescription)
            }
        }
    }
}
