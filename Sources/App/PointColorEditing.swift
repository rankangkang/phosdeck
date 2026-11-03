import Foundation
import CoreImage

extension AppModel {
    func cancelPointColorTools() {
        pointReferenceTask?.cancel(); pointReferenceTask = nil; pointReferenceToken = UUID()
        pointSampling = false; showPointColorRange = false; pointRangeImage = nil
        pointReference = nil; pointReferenceKey = nil; pointReferenceReady = false
    }
    func togglePointColorSampling() {
        if pointSampling { cancelPointColorTools(); return }
        guard canEdit, commitRecipe(), let recipe, !recipe.develop.blackAndWhite, recipe.develop.pointColors.count < 8 else { return }
        cancelWhiteBalanceSampling()
        cropMode = false; maskMode = false; spotMode = false; before = false; beforeAfter = .off
        cancelZoneSampling(); showPointColorRange = false; pointSampling = true
        requestPreview()
        refreshPointColorTools()
    }
    func refreshPointColorTools() {
        pointReferenceTask?.cancel(); pointReferenceTask = nil; pointReferenceToken = UUID()
        pointRangeImage = nil
        guard pointSampling || showPointColorRange else { return }
        guard canEdit, let photo = active, let recipe, !recipe.develop.blackAndWhite,
              let root = roots.first(where:{$0.id == photo.rootID}) else { cancelPointColorTools(); return }
        if showPointColorRange {
            guard let selected = recipe.develop.pointColors.first(where:{$0.id == selectedPointColorID}) ?? recipe.develop.pointColors.first else { showPointColorRange = false; return }
            // A reopened version or an undo can restore samples while the panel
            // stays mounted. Resolve its visible fallback in the model as well.
            if selectedPointColorID != selected.id { selectedPointColorID = selected.id; return }
            let needsPreview = cropMode || before
            pointSampling = false
            cropMode = false; maskMode = false; spotMode = false; before = false; beforeAfter = .off
            cancelZoneSampling()
            if needsPreview { requestPreview() }
        }
        var input = recipe
        // Only the prefix affects the sampling reference, so changing a point's
        // sliders reuses it. Version identity remains in the key and guards.
        input.saturation = 1; input.develop.pointColors = []; input.develop.vibrance = 0
        input.develop.grading = ColorGrading(); input.develop.blackAndWhite = false
        input.develop.blackWhiteMixer = Array(repeating:0,count:8)
        input.localAdjustments = []; input.sharpening = GeneralSharpening(); input.vignette = CreativeVignette(); input.grain = FilmGrain()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(input) else { return }
        let key = photo.id+":"+photo.identity.base64EncodedString()+":"+data.base64EncodedString()
        let cached = key == pointReferenceKey ? pointReference : nil
        pointReferenceReady = cached != nil
        let token = pointReferenceToken, selected = selectedPointColorID, show = showPointColorRange
        pointReferenceTask = Task {
            do {
                let reference:PointColorReference
                if let cached { reference = cached }
                else { reference = try await pointPipeline.pointColorReference(ImageRequest(photo:photo,root:root,recipe:recipe)) }
                guard !Task.isCancelled, token == pointReferenceToken, activeID == photo.id, self.recipe == recipe else { return }
                pointReference = reference; pointReferenceKey = key; pointReferenceReady = true
                if show, let selected {
                    let range = try await pointPipeline.pointColorRange(reference,samples:recipe.develop.pointColors,selected:selected)
                    guard !Task.isCancelled, token == pointReferenceToken, activeID == photo.id, self.recipe == recipe else { return }
                    pointRangeImage = range
                }
            } catch {
                if !Task.isCancelled, token == pointReferenceToken { self.error = error.localizedDescription; cancelPointColorTools() }
            }
            if token == pointReferenceToken { pointReferenceTask = nil }
        }
    }
    func samplePointColor(at point:CGPoint) {
        guard pointSampling, pointReferenceReady, canEdit, canvasCoordinatesCurrent, let recipe,
              let size = orientedSourceSize, MaskGeometry.sourcePoint(point,size:size,recipe:recipe) != nil,
              let sample = pointReference?.sample(at:point) else {
            if pointReferenceReady { showNotice(L10n.text("app.noSampleAddedTransparentPixelOrNoValidColor", defaultValue: "No sample added: transparent pixel or no valid color")) }
            return
        }
        guard recipe.develop.pointColors.count < 8 else { return }
        cancelPointColorTools()
        selectedPointColorID = sample.id
        changeRecipe({ $0.pipelineVersion = 2; $0.develop.pointColors.append(sample) },title:L10n.text("app.addPointColorSample", defaultValue: "Add Point Color Sample"))
    }
    func updatePointColor(id:UUID,key:WritableKeyPath<PointColor,Double>,value:Double,commit:Bool) {
        changeRecipe({ r in
            guard let index = r.develop.pointColors.firstIndex(where:{$0.id == id}) else { return }
            r.develop.pointColors[index][keyPath:key] = value
        },commit:commit,title:L10n.text("app.pointColorAdjustment", defaultValue: "Point Color Adjustment"))
    }
    func deletePointColor(_ id:UUID) {
        changeRecipe({ $0.develop.pointColors.removeAll { $0.id == id } },title:L10n.text("app.deletePointColorSample", defaultValue: "Delete Point Color Sample"))
        selectedPointColorID = recipe?.develop.pointColors.first?.id
    }
    func resetPointColor(_ id:UUID) {
        changeRecipe({ r in
            guard let index = r.develop.pointColors.firstIndex(where:{$0.id == id}) else { return }
            var sample = r.develop.pointColors[index]
            sample.hueShift = 0; sample.saturationShift = 0; sample.luminanceShift = 0; sample.variance = 0
            sample.range = 50; sample.hueRange = 50; sample.saturationRange = 50; sample.luminanceRange = 50
            r.develop.pointColors[index] = sample
        },title:L10n.text("app.resetPointColorSample", defaultValue: "Reset Point Color Sample"))
    }
}
