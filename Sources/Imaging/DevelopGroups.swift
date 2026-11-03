import Foundation

/// A visible group in the Develop inspector.
///
/// The enum deliberately follows the native panel boundaries instead of the
/// storage layout.  It is used for the modified lamp, the temporary eye
/// preview and the quick-jump menu; it does not add an enable bit to a recipe.
enum DevelopGroup: String, CaseIterable, Identifiable, Hashable {
    case basic
    case curves
    case zones
    case mixer
    case pointColor
    case blackWhite
    case grading
    case noiseReduction
    case sharpening
    case rawDetails
    case vignette
    case grain
    case crop
    case perspective

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic: return L10n.text("app.basicAdjustments", defaultValue: "Basic Adjustments")
        case .curves: return L10n.text("app.curves", defaultValue: "Curves")
        case .zones: return L10n.text("app.zoneLighting", defaultValue: "Zone Lighting")
        case .mixer: return L10n.text("app.hslMixer", defaultValue: "HSL Mixer")
        case .pointColor: return L10n.text("app.pointColor", defaultValue: "Point Color")
        case .blackWhite: return L10n.text("app.blackWhiteMixer", defaultValue: "Black & White Mixer")
        case .grading: return L10n.text("app.colorGrading", defaultValue: "Color Grading")
        case .noiseReduction: return L10n.text("app.noiseReduction", defaultValue: "Noise Reduction")
        case .sharpening: return L10n.text("app.sharpening", defaultValue: "Sharpening")
        case .rawDetails: return L10n.text("app.rawDetailAndLens", defaultValue: "RAW Detail and Lens")
        case .vignette: return L10n.text("app.creativeVignette", defaultValue: "Creative Vignette")
        case .grain: return L10n.text("app.grain", defaultValue: "Grain")
        case .crop: return L10n.text("app.cropStraightenAndFlip", defaultValue: "Crop, Straighten, and Flip")
        case .perspective: return L10n.text("app.manualPerspective", defaultValue: "Manual Perspective")
        }
    }

    /// Groups that can be shown in the normal Develop inspector.
    static var adjustmentCases: [DevelopGroup] {
        [.basic, .curves, .zones, .mixer, .pointColor, .blackWhite, .grading,
         .noiseReduction, .sharpening, .rawDetails, .vignette, .grain]
    }

    /// Return a display-only recipe with this group's controls at their exact
    /// neutral baseline.  The original recipe is never mutated.  Geometry is
    /// kept intact for non-geometry groups so a preview does not jump in the
    /// canvas; crop and perspective each neutralize only their own controls.
    func previewRecipe(in recipe: EditRecipe, baseline: EditRecipe? = nil) -> EditRecipe {
        let aligned = baseline ?? recipe.alignedBaseline()
        var value = recipe
        switch self {
        case .basic:
            value.exposure = aligned.exposure
            value.temperature = aligned.temperature
            value.tint = aligned.tint
            value.asShotWhiteBalance = aligned.asShotWhiteBalance
            value.contrast = aligned.contrast
            value.saturation = aligned.saturation
            value.develop.highlights = aligned.develop.highlights
            value.develop.shadows = aligned.develop.shadows
            value.develop.whites = aligned.develop.whites
            value.develop.blacks = aligned.develop.blacks
            value.develop.texture = aligned.develop.texture
            value.develop.clarity = aligned.develop.clarity
            value.develop.dehaze = aligned.develop.dehaze
            value.develop.vibrance = aligned.develop.vibrance
            value.develop.blackAndWhite = aligned.develop.blackAndWhite
        case .curves:
            value.develop.curves = aligned.develop.curves
        case .zones:
            value.develop.zones = aligned.develop.zones
        case .mixer:
            value.develop.mixer = aligned.develop.mixer
        case .pointColor:
            value.develop.pointColors = aligned.develop.pointColors
        case .blackWhite:
            value.develop.blackWhiteMixer = aligned.develop.blackWhiteMixer
        case .grading:
            value.develop.grading = aligned.develop.grading
        case .noiseReduction:
            value.noiseReduction = aligned.noiseReduction
        case .sharpening:
            value.sharpening = aligned.sharpening
        case .rawDetails:
            // Lens correction is stored with RAW details and is part of this
            // group's real neutral state.  Unlike the before/after image
            // reference, a group eye is allowed to show the geometry change
            // caused by disabling lens correction.
            value.rawDetails = recipe.baseline().rawDetails
        case .vignette:
            value.vignette = aligned.vignette
        case .grain:
            value.grain = aligned.grain
            // The seed is assigned when a photo is first opened. It is not
            // an adjustment and must not light an otherwise neutral group.
            value.grain.seed = recipe.grain.seed
        case .crop:
            let neutral = recipe.baseline()
            value.quarterTurns = neutral.quarterTurns
            value.crop = neutral.crop
            value.straightenDegrees = neutral.straightenDegrees
            value.cropAspectRatio = neutral.cropAspectRatio
            value.flipHorizontal = neutral.flipHorizontal
            value.flipVertical = neutral.flipVertical
        case .perspective:
            value.perspective = PerspectiveSettings()
        }
        return value
    }

    func isModified(in recipe: EditRecipe, baseline: EditRecipe? = nil) -> Bool {
        // Compare only this group's fields.  Comparing a whole recipe would
        // make an unrelated crop light every group; comparing an aligned
        // recipe would hide a RAW lens-correction-only edit.  The preview
        // recipe above uses the same field ownership, so this remains a pure
        // value check without adding an enable flag to EditRecipe.
        previewRecipe(in: recipe, baseline: baseline) != recipe
    }
}

extension EditRecipe {
    /// The groups whose current values differ from the display-neutral state.
    /// The baseline is aligned to the current geometry for ordinary groups,
    /// preventing a crop change from lighting every unrelated group. The RAW
    /// group intentionally uses its actual baseline so lens-correction-only
    /// edits remain visible.
    var modifiedDevelopGroups: Set<DevelopGroup> {
        let baseline = alignedBaseline()
        return Set(DevelopGroup.allCases.filter { $0.isModified(in: self, baseline: baseline) })
    }
}
