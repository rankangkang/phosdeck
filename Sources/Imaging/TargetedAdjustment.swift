import Foundation

/// Interaction choices map to existing native parameters, not Adobe process values.
enum TargetedAdjustment: Equatable, Sendable {
    case hue, saturation, luminance, blackWhite, curve(Int), defringePurple, defringeGreen
    var title: String {
        switch self {
        case .hue: L10n.text("app.hue", defaultValue: "Hue")
        case .saturation: L10n.text("app.saturation", defaultValue: "Saturation")
        case .luminance: L10n.text("app.luminance_1188", defaultValue: "Luminance")
        case .blackWhite: L10n.text("app.blackWhiteMixer", defaultValue: "Black & White Mixer")
        case .curve(let channel): ToneCurves.names[channel]
        case .defringePurple: L10n.text("defringe.purple", defaultValue: "Purple Fringe")
        case .defringeGreen: L10n.text("defringe.green", defaultValue: "Green Fringe")
        }
    }
    var isCurve: Bool { if case .curve = self { return true }; return false }
    var isDefringe: Bool { self == .defringePurple || self == .defringeGreen }
    var step: Double { isCurve ? 0.1 : 1 }
    func available(in recipe: EditRecipe) -> Bool {
        guard recipe.pipelineVersion == 2 else { return false }
        switch self {
        case .curve(let channel): return (0..<4).contains(channel)
        case .blackWhite: return recipe.develop.blackAndWhite
        default: return true
        }
    }

    /// Existing point reference is after curves/HSL. Neutralize HSL to obtain its
    /// input; also neutralize curves for a pre-curve reference. Downstream edits
    /// do not invalidate this cache. Repairs, RAW settings and geometry still do.
    func referenceRecipe(_ recipe: EditRecipe) -> EditRecipe {
        var r = recipe
        if isDefringe {
            // Residual fringe input: decoded WB/exposure, repairs and denoise,
            // before this operation and all tone/HSL/curve adjustments. Geometry
            // remains the actual output geometry, avoiding an inverse remapping.
            r.defringe = nil; r.develop = DevelopAdjustments(); r.contrast = 1
        }
        r.saturation = 1; r.develop.mixer = Array(repeating: HSLBand(), count: 8)
        if isCurve { r.develop.curves = nil }
        r.develop.blackAndWhite = false; r.develop.blackWhiteMixer = Array(repeating: 0, count: 8)
        r.develop.pointColors = []; r.develop.vibrance = 0; r.develop.grading = ColorGrading()
        r.localAdjustments = []; r.sharpening = GeneralSharpening(); r.vignette = CreativeVignette(); r.grain = FilmGrain()
        return r
    }

    func sample(rgb: SIMD3<Double>, recipe: EditRecipe) -> TargetedSample? {
        guard available(in: recipe), (0..<3).allSatisfy({ rgb[$0].isFinite }) else { return nil }
        switch self {
        case .defringePurple, .defringeGreen:
            guard let hue = ManualDefringe.sampledHue(rgb, purple: self == .defringePurple) else { return nil }
            let amount = self == .defringePurple ? recipe.manualDefringe.purpleAmount : recipe.manualDefringe.greenAmount
            return TargetedSample(target: self, weights: [], curveInput: nil, fringeHue: hue, fringeStartAmount: amount == 0 ? 25 : amount)
        case .curve(let channel):
            // Each channel receives the output of preceding native channels.
            var preceding = recipe.develop.curves ?? ToneCurves()
            for i in channel..<4 { preceding.channels[i] = ToneCurves.identity }
            let input = TonalPipeline.transform(rgb, curves: preceding)
            let linear = channel == 0 ? DevelopPipeline.luma(input) : input[channel - 1]
            let x = min(1, max(0, PerceptualColor.encoded(SIMD3(repeating: max(0, linear))).x))
            return TargetedSample(target: self, weights: [], curveInput: x)
        case .blackWhite:
            // The native blackWhiteMix kernel selects after HSL/vibrance/saturation,
            // before grayscale and grading. Derive that hue without gamut mapping.
            let original = PerceptualColor.lab(rgb), chroma = hypot(original.y, original.z)
            let mixed = PerceptualColor.mixerLab(rgb, adjustments: recipe.develop)
            let changedChroma = hypot(mixed.y, mixed.z) * recipe.saturation
                * (1 + recipe.develop.vibrance / 100 * (1 - DevelopPipeline.smooth(0.03, 0.25, chroma)))
            guard chroma > 1e-6, changedChroma > 1e-6 else { return nil }
            let hue = atan2(mixed.z, mixed.y)
            let weights = (0..<8).map { band -> Double in
                var basis = Array(repeating: 0.0, count: 8); basis[band] = 1
                return PerceptualColor.blackWhiteShift(hue: hue, values: basis)
            }
            return TargetedSample(target: self, weights: weights, curveInput: nil)
        default:
            let lab = PerceptualColor.lab(rgb)
            guard hypot(lab.y, lab.z) > 1e-6 else { return nil }
            let hue = DevelopPipeline.hsl(PerceptualColor.encoded(rgb)).x
            let weights = (0..<8).map { band -> Double in
                var basis = Array(repeating: HSLBand(), count: 8); basis[band].hue = 1
                return DevelopPipeline.mixerShift(hue: hue, bands: basis).x
            }
            return TargetedSample(target: self, weights: weights, curveInput: nil)
        }
    }
}

struct TargetedSample: Equatable, Sendable {
    let target: TargetedAdjustment
    let weights: [Double]
    let curveInput: Double?
    var fringeHue: Double? = nil
    var fringeStartAmount: Double? = nil
    var description: String {
        if let fringeHue { return String(format: L10n.text("defringe.sampleHue", defaultValue: "Sample hue %.1f° · drag to adjust amount"), fringeHue) }
        if let curveInput { return String(format: L10n.text("app.targetCurveInput", defaultValue: "Input %.1f%%"), curveInput * 100) }
        return weights.enumerated().filter { $0.element > 0.001 }.map { HSLBand.names[$0.offset] + " " + String(format: "%.0f%%", $0.element * 100) }.joined(separator: " · ")
    }
    func applying(delta: Double, to original: EditRecipe) throws -> EditRecipe {
        guard delta.isFinite, target.available(in: original) else { return original }
        // Tonal/color targets keep click-only selection. Defringe also applies a
        // sampled range and a native starting amount on one click, saved on release.
        guard delta != 0 || target.isDefringe else { return original }
        var r = original
        switch target {
        case .defringePurple, .defringeGreen:
            guard let hue = fringeHue else { return original }
            var settings = original.manualDefringe
            let purple = target == .defringePurple
            let previous = purple ? settings.purpleAmount : settings.greenAmount
            let amount = min(100, max(0, (fringeStartAmount ?? previous) + delta))
            settings.setSample(hue, purple: purple)
            if purple { settings.purpleAmount = amount } else { settings.greenAmount = amount }
            r.manualDefringe = settings
        case .curve(let channel):
            guard let x = curveInput else { return original }
            var curves = original.develop.curves ?? ToneCurves()
            guard let point = curves.insert(channel: channel, x: x, y: TonalPipeline.evaluate(curves.channels[channel], at: x)) else {
                throw LRCError(L10n.text("app.targetCurveFull", defaultValue: "This curve already has 16 points. Remove a point or sample near an existing point."))
            }
            let y = curves.channels[channel][point].y
            curves.move(channel: channel, point: point, x: curves.channels[channel][point].x, y: y + delta / 100)
            if curves == (original.develop.curves ?? ToneCurves()) { return original }
            r.develop.curves = curves
        case .blackWhite:
            for i in 0..<8 { r.develop.blackWhiteMixer[i] = min(100, max(-100, original.develop.blackWhiteMixer[i] + delta * weights[i])) }
        default:
            let key: WritableKeyPath<HSLBand, Double> = target == .hue ? \.hue : target == .saturation ? \.saturation : \.luminance
            for i in 0..<8 { r.develop.mixer[i][keyPath: key] = min(100, max(-100, original.develop.mixer[i][keyPath: key] + delta * weights[i])) }
        }
        try r.validate()
        return r
    }
}
