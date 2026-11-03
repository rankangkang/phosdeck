import Foundation

/// Sparse Adobe CRS values. Field selection and reporting follow LightCraft's crs.rs /
/// preset_import.rs at 56b5c8b (2026-10-28); native ranges and rendering stay ours.
/// Attribution: docs/references/lightcraft-LICENSE.txt.
struct XMPPresetSettings: Codable, Equatable {
    enum Group: Equatable { case tone, color, whiteBalance, curves, generalDetails }
    struct Control {
        let path: WritableKeyPath<EditRecipe, Double>
        let group: Group
        let range: ClosedRange<Double>
        var scale = 1.0
        var offset = 0.0
    }
    var values: [String: Double] = [:]
    var curves: [String: [CurvePoint]] = [:]
    var blackAndWhite: Bool?
    var whiteBalance: String?
    var vignetteStyle: CreativeVignetteStyle?
    var unsupported: [String] = []
    var notes: [String] = []
    var warnings: [String] { unsupported + notes }
    var hasContent: Bool { !values.isEmpty || !curves.isEmpty || blackAndWhite != nil || whiteBalance != nil || vignetteStyle != nil }

    static let curveFields = ["ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"]
    static let controls: [String: Control] = {
        var fields: [String: Control] = [
            "Exposure2012": Control(path: \.exposure, group: .tone, range: -5...5),
            "Contrast2012": Control(path: \.contrast, group: .tone, range: -100...100, scale: 0.01, offset: 1),
            "Highlights2012": Control(path: \.develop.highlights, group: .tone, range: -100...100),
            "Shadows2012": Control(path: \.develop.shadows, group: .tone, range: -100...100),
            "Whites2012": Control(path: \.develop.whites, group: .tone, range: -100...100),
            "Blacks2012": Control(path: \.develop.blacks, group: .tone, range: -100...100),
            "Texture": Control(path: \.develop.texture, group: .tone, range: -100...100),
            "Clarity2012": Control(path: \.develop.clarity, group: .tone, range: -100...100),
            "Dehaze": Control(path: \.develop.dehaze, group: .tone, range: -100...100),
            "Vibrance": Control(path: \.develop.vibrance, group: .color, range: -100...100),
            "Saturation": Control(path: \.saturation, group: .color, range: -100...100, scale: 0.01, offset: 1),
            "Temperature": Control(path: \.temperature, group: .whiteBalance, range: 2000...50000),
            "Tint": Control(path: \.tint, group: .whiteBalance, range: -150...150),
            "Sharpness": Control(path: \.sharpening.amount, group: .generalDetails, range: 0...150),
            "SharpenRadius": Control(path: \.sharpening.radius, group: .generalDetails, range: 0.5...3),
            "LuminanceSmoothing": Control(path: \.noiseReduction.luminance, group: .generalDetails, range: 0...100),
            "ColorNoiseReduction": Control(path: \.noiseReduction.color, group: .generalDetails, range: 0...100),
            "PostCropVignetteAmount": Control(path: \.vignette.amount, group: .tone, range: -100...100),
            "PostCropVignetteMidpoint": Control(path: \.vignette.midpoint, group: .tone, range: 0...100),
            "PostCropVignetteRoundness": Control(path: \.vignette.roundness, group: .tone, range: -100...100),
            "PostCropVignetteFeather": Control(path: \.vignette.feather, group: .tone, range: 0...100),
            "PostCropVignetteHighlightContrast": Control(path: \.vignette.highlights, group: .tone, range: 0...100),
            "GrainAmount": Control(path: \.grain.amount, group: .tone, range: 0...100),
            "GrainSize": Control(path: \.grain.size, group: .tone, range: 0...100),
            "GrainFrequency": Control(path: \.grain.roughness, group: .tone, range: 0...100),
            "SplitToningBalance": Control(path: \.develop.grading.balance, group: .color, range: -100...100),
            "ColorGradeBlending": Control(path: \.develop.grading.blending, group: .color, range: 0...100)
        ]
        let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
        for (index, band) in bands.enumerated() {
            fields["HueAdjustment" + band] = Control(path: \EditRecipe.develop.mixer[index].hue, group: .color, range: -100...100)
            fields["SaturationAdjustment" + band] = Control(path: \EditRecipe.develop.mixer[index].saturation, group: .color, range: -100...100)
            fields["LuminanceAdjustment" + band] = Control(path: \EditRecipe.develop.mixer[index].luminance, group: .color, range: -100...100)
            fields["GrayMixer" + band] = Control(path: \EditRecipe.develop.blackWhiteMixer[index], group: .color, range: -100...100)
        }
        let tones: [(String, WritableKeyPath<EditRecipe, GradingTone>)] = [
            ("Shadow", \.develop.grading.shadows), ("Highlight", \.develop.grading.highlights),
            ("Midtone", \.develop.grading.midtones), ("Global", \.develop.grading.global)
        ]
        for (name, path) in tones {
            let split = name == "Shadow" || name == "Highlight"
            fields[(split ? "SplitToning" : "ColorGrade") + name + "Hue"] = Control(path: path.appending(path: \.hue), group: .color, range: 0...360)
            fields[(split ? "SplitToning" : "ColorGrade") + name + (split ? "Saturation" : "Sat")] = Control(path: path.appending(path: \.saturation), group: .color, range: 0...100)
            fields["ColorGrade" + name + "Lum"] = Control(path: path.appending(path: \.luminance), group: .color, range: -100...100)
        }
        return fields
    }()

    var options: RecipePasteOptions {
        RecipePasteOptions(tone: contains(.tone), whiteBalance: contains(.whiteBalance), color: contains(.color),
                           geometry: false, details: false, generalDetails: contains(.generalDetails),
                           curves: contains(.curves), zones: false)
    }
    func contains(_ group: Group) -> Bool {
        values.keys.contains { Self.controls[$0]?.group == group }
            || (group == .curves && !curves.isEmpty)
            || (group == .color && blackAndWhite != nil)
            || (group == .whiteBalance && whiteBalance != nil)
            || (group == .tone && vignetteStyle != nil)
    }
    func selected(_ group: Group, in options: RecipePasteOptions) -> Bool {
        switch group {
        case .tone: return options.tone
        case .color: return options.color
        case .whiteBalance: return options.whiteBalance
        case .curves: return options.curves
        case .generalDetails: return options.generalDetails
        }
    }
    func resolved(on target: EditRecipe, options: RecipePasteOptions) throws -> EditRecipe {
        guard target.pipelineVersion == 2 else { throw LRCError(L10n.text("app.xmpPresetsRequireTheCurrentDevelopmentVersionUpdateThe", defaultValue: "XMP presets require the current development version. Update the photo's development version first")) }
        var result = target
        if options.whiteBalance, !target.isRaster, contains(.whiteBalance) {
            if whiteBalance == "asShot" {
                result.asShotWhiteBalance = true
                result.temperature = target.baselineTemperature; result.tint = target.baselineTint
            } else {
                if result.asShotWhiteBalance { result.temperature = target.baselineTemperature; result.tint = target.baselineTint }
                result.asShotWhiteBalance = false
            }
        }
        for (key, value) in values {
            guard let control = Self.controls[key], value.isFinite, control.range.contains(value) else { throw LRCError(L10n.text("app.invalidXMPPresetParameter", defaultValue: "Invalid XMP preset parameter: \(key)")) }
            guard selected(control.group, in: options) else { continue }
            if control.group == .whiteBalance, target.isRaster || whiteBalance == "asShot" { continue }
            result[keyPath: control.path] = value * control.scale + control.offset
        }
        if options.color, let blackAndWhite { result.develop.blackAndWhite = blackAndWhite }
        if options.tone, let vignetteStyle { result.vignette.style = vignetteStyle }
        if options.curves, !curves.isEmpty {
            var mapped = target.develop.curves ?? ToneCurves()
            for (key, points) in curves {
                guard let index = Self.curveFields.firstIndex(of: key) else { throw LRCError(L10n.text("app.invalidXMPPresetCurveChannel", defaultValue: "Invalid XMP preset curve channel")) }
                mapped.channels[index] = points
            }
            try mapped.validate()
            result.develop.curves = mapped
        }
        try result.validate()
        return result
    }
}
