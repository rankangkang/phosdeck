import Foundation
import CoreGraphics

/// nil uses the decoder's default for this photo.
struct RAWDetailSettings: Codable, Equatable {
    var luminanceNoiseReduction: Double?
    var colorNoiseReduction: Double?
    var sharpness: Double?
    var lensCorrection: Bool?
    var isDefault: Bool { self == Self() }
    func validate() throws {
        guard [luminanceNoiseReduction, colorNoiseReduction, sharpness].compactMap({ $0 })
            .allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw LRCError(L10n.text("app.invalidNoiseReductionOrSharpeningParameters", defaultValue: "Invalid noise reduction or sharpening parameters")) }
    }
}

struct Crop: Codable, Equatable {
    var x = 0.0, y = 0.0, width = 1.0, height = 1.0
    func flipped(horizontal: Bool, vertical: Bool) -> Self {
        Self(x: horizontal ? 1 - x - width : x, y: vertical ? 1 - y - height : y, width: width, height: height)
    }
    static func centered(aspectRatio: Double, orientedCanvas: CGSize, quarterTurns: Int) -> Self {
        let turned = quarterTurns % 2 != 0
        let width = turned ? orientedCanvas.height : orientedCanvas.width
        let height = turned ? orientedCanvas.width : orientedCanvas.height
        let aspect = width / max(1, height)
        if aspect > aspectRatio {
            let w = aspectRatio / aspect
            return Self(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = aspect / aspectRatio
        return Self(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

/// Version 0 preserves the initial linear contrast experiment. Version 1 applies
/// contrast/saturation in perceptual sRGB. Version 2 adds guided spatial processing
/// and perceptual color editing. Never silently reinterpret a saved version.
struct EditRecipe: Codable, Equatable {
    static let rasterDecoderVersion = "imageio-raster-response-v4"
    var isRaster: Bool { decoderVersion == Self.rasterDecoderVersion }
    /// Inactive grain may have a saved random seed. It does not change the neutral pixels.
    var isUnadjustedRaster: Bool {
        var neutral = baseline()
        neutral.grain = grain
        // A saved neutral point layout is still the unadjusted JPEG/TIFF/PNG path,
        // including its original 8-bit JPEG -> TIFF16 rounding contract.
        if develop.curves?.isNeutral == true { neutral.develop.curves = develop.curves }
        if !develop.blackAndWhite { neutral.develop.blackWhiteMixer = develop.blackWhiteMixer }
        if develop.blackAndWhite || develop.pointColors.allSatisfy(\.isNeutral) { neutral.develop.pointColors = develop.pointColors }
        if perspective.isNeutral { neutral.perspective = perspective }
        if !sharpening.isActive { neutral.sharpening = sharpening }
        if !manualDefringe.isActive { neutral.defringe = defringe }
        return isRaster && !grain.isActive && self == neutral
    }
    var schemaVersion = 2
    var pipelineVersion = 2
    var sourceDigest: String
    var decoderVersion: String
    var systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var appBuild = "0.1-dev"
    var baselineExposure: Double
    var baselineTemperature: Double
    var baselineTint: Double
    var exposure = 0.0
    var temperature: Double
    var tint: Double
    var asShotWhiteBalance = true
    var contrast = 1.0
    var saturation = 1.0
    var quarterTurns = 0
    /// Reflections in the final cropped frame's axes. EXIF is already applied by the decoder.
    var flipHorizontal = false
    var flipVertical = false
    var perspective = PerspectiveSettings()
    var crop = Crop()
    func hasSameGeometry(as other: Self?) -> Bool {
        guard let other else { return false }
        return quarterTurns == other.quarterTurns && straightenDegrees == other.straightenDegrees && crop == other.crop &&
            flipHorizontal == other.flipHorizontal && flipVertical == other.flipVertical && perspective == other.perspective &&
            rawDetails.lensCorrection == other.rawDetails.lensCorrection
    }
    var cropInDisplay: Crop { crop.flipped(horizontal: flipHorizontal, vertical: flipVertical) }
    func cropFromDisplay(_ value: Crop) -> Crop {
        let shown = cropInDisplay
        func unchanged(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 8 * Double.ulpOfOne }
        var result = value.flipped(horizontal: flipHorizontal, vertical: flipVertical)
        // Avoid a one-pixel integral-crop shift from round-tripping a coordinate
        // the user did not move (e.g. 0.1 -> 0.09999999999999998).
        if unchanged(value.width, shown.width) {
            result.width = crop.width
            if unchanged(value.x, shown.x) { result.x = crop.x }
        }
        if unchanged(value.height, shown.height) {
            result.height = crop.height
            if unchanged(value.y, shown.y) { result.y = crop.y }
        }
        return result
    }
    /// During crop editing the full frame is reflected before the live straighten.
    var cropPreviewAngle: Double { perspective.isNeutral ? (flipHorizontal != flipVertical ? -straightenDegrees : straightenDegrees) : 0 }
    var cropRenderRecipe: Self {
        var r = self
        r.crop = Crop(); r.perspective.constrainCrop = false
        if perspective.isNeutral { r.straightenDegrees = 0 }
        return r
    }
    func effectiveCropInDisplay(size: CGSize) -> Crop? {
        guard let g = try? PhotoGeometry(size: size, recipe: self) else { return nil }
        return Crop(x: g.cropRect.minX/g.canvas.width, y: g.cropRect.minY/g.canvas.height,
                    width: g.cropRect.width/g.canvas.width, height: g.cropRect.height/g.canvas.height)
            .flipped(horizontal: flipHorizontal, vertical: flipVertical)
    }
    mutating func rotateCanvas(by turns: Int) {
        let steps = (turns % 4 + 4) % 4
        // Reflections reverse handedness. The button still rotates the visible
        // canvas in the requested direction while preserving both flip states.
        quarterTurns = (quarterTurns + (flipHorizontal != flipVertical ? 4 - steps : steps)) % 4
    }

    var localAdjustments: [LocalAdjustment] = []
    var repairs: [SpotRepair] = []
    var maskVersion = 1
    var develop = DevelopAdjustments()
    var vignette = CreativeVignette()
    var grain = FilmGrain()
    var sharpening = GeneralSharpening()
    var noiseReduction = GeneralNoiseReduction()
    var defringe: ManualDefringe?
    var rawDetails = RAWDetailSettings()
    var straightenDegrees = 0.0
    /// Pixel aspect ratio, independent of portrait/landscape source dimensions.
    var cropAspectRatio: Double?

    enum CodingKeys: String, CodingKey {
        case localAdjustments, repairs, maskVersion, rawDetails, vignette, grain
        case schemaVersion, pipelineVersion, sourceDigest, decoderVersion, systemVersion, appBuild
        case baselineExposure, baselineTemperature, baselineTint, exposure, temperature, tint
        case asShotWhiteBalance, contrast, saturation, quarterTurns, crop, develop, straightenDegrees, cropAspectRatio
        case flipHorizontal, flipVertical, perspective, sharpening, noiseReduction, defringe
    }

    func validate() throws {
        guard !decoderVersion.hasPrefix("imageio-") || isRaster else { throw LRCError(L10n.text("app.unsupportedRasterDevelopmentVersionOriginalDataPreserved", defaultValue: "Unsupported raster development version. Original data preserved")) }
        guard (1...3).contains(schemaVersion), (0...2).contains(pipelineVersion) else { throw LRCError(L10n.text("app.unsupportedRecipeOrPipelineVersionOriginalDataPreserved", defaultValue: "Unsupported recipe or pipeline version. Original data preserved")) }
        if isRaster {
            guard pipelineVersion == 2, baselineExposure == 0, baselineTemperature == 5500, baselineTint == 0,
                  rawDetails.isDefault else { throw LRCError(L10n.text("app.jpegTIFFPNGRecipesCannotContainARAWBaseline", defaultValue: "JPEG/TIFF/PNG recipes cannot contain a RAW baseline or RAW-specific detail parameters")) }
        }
        try rawDetails.validate()
        try sharpening.validate()
        try noiseReduction.validate()
        try defringe?.validate()
        guard defringe == nil || pipelineVersion == 2 else { throw LRCError(L10n.text("defringe.currentPipeline", defaultValue: "Manual defringe requires the current development pipeline")) }
        try perspective.validate()
        try develop.validate()
        guard pipelineVersion == 2 || develop.pointColors.allSatisfy(\.isNeutral) else { throw LRCError(L10n.text("app.pointColorRequiresTheCurrentDevelopmentPipeline", defaultValue: "Point Color requires the current development pipeline")) }
        guard pipelineVersion == 2 || !develop.blackAndWhite || develop.blackWhiteMixer.allSatisfy({ $0 == 0 })
        else { throw LRCError(L10n.text("app.theBlackAndWhiteMixerRequiresTheCurrentDevelopment", defaultValue: "The black-and-white mixer requires the current development version. Original data preserved")) }
        guard (1...3).contains(maskVersion), (maskVersion >= 2 || localAdjustments.allSatisfy { $0.settings == nil }), localAdjustments.count <= 64,
              Set(localAdjustments.map(\.id)).count == localAdjustments.count,
              localAdjustments.isEmpty || schemaVersion >= 3 else { throw LRCError(L10n.text("app.invalidMaskVersionOrCount", defaultValue: "Invalid mask version or count")) }
        try localAdjustments.forEach { try $0.validate() }
        let rasters = localAdjustments.flatMap(\.components).compactMap(\.raster)
        guard rasters.isEmpty || maskVersion == 3 else { throw LRCError(L10n.text("app.smartMasksRequireTheCurrentMaskVersion", defaultValue: "Smart masks require the current mask version")) }
        guard rasters.allSatisfy({ $0.source.matches(self) }) else {
            throw LRCError(L10n.text("app.theSmartMaskSourceDecoderOrLensGeometryDiffers", defaultValue: "The smart mask source, decoder, or lens geometry differs. Remove the selection before recognizing again; existing results preserved"))
        }
        guard rasters.reduce(0, { $0 + $1.pixelCount }) <= 16 * 1024 * 1024,
              rasters.reduce(0, { $0 + $1.byteCount }) <= 32 * 1024 * 1024 else { throw LRCError(L10n.text("app.smartMaskDataExceedsThisPhotoSLimit", defaultValue: "Smart mask data exceeds this photo's limit")) }
        guard repairs.count <= 128, Set(repairs.map(\.id)).count == repairs.count else { throw LRCError(L10n.text("app.invalidSpotRemovalCount", defaultValue: "Invalid spot removal count")) }
        try repairs.forEach { try $0.validate() }
        try vignette.validate()
        try grain.validate()
        guard straightenDegrees.isFinite, (-45...45).contains(straightenDegrees),
              cropAspectRatio.map({ $0.isFinite && (0.1...10).contains($0) }) ?? true
        else { throw LRCError(L10n.text("app.invalidCropAngleOrAspectRatio", defaultValue: "Invalid crop angle or aspect ratio")) }
        guard [exposure, temperature, tint, contrast, saturation, baselineExposure, baselineTemperature, baselineTint,
               crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite),
              (-5...5).contains(exposure), (2000...50000).contains(temperature), (-150...150).contains(tint),
              (0...2).contains(contrast), (0...2).contains(saturation), (0...3).contains(quarterTurns),
              crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.x + crop.width <= 1.0000001, crop.y + crop.height <= 1.0000001,
              sourceDigest.count == 64, sourceDigest.allSatisfy(\.isHexDigit), !decoderVersion.isEmpty else { throw LRCError(L10n.text("app.theRecipeContainsInvalidOrOutOfRangeParameters", defaultValue: "The recipe contains invalid or out-of-range parameters")) }
    }
    func validate(for photo: Photo) throws {
        try validate()
        guard photo.supportsEditing, isRaster == !photo.isRAW else { throw LRCError(L10n.text("app.theRecipeDoesNotMatchTheSourceFileType", defaultValue: "The recipe does not match the source file type")) }
    }
    func resetForCurrentPipeline() -> Self {
        var value = baseline()
        value.pipelineVersion = 2
        value.schemaVersion = 2
        return value
    }
    func baseline() -> Self {
        var r = self
        r.exposure = 0; r.asShotWhiteBalance = true; r.temperature = baselineTemperature; r.tint = baselineTint
        r.localAdjustments = []; r.repairs = []; r.maskVersion = 1
        r.rawDetails = RAWDetailSettings()
        r.contrast = 1; r.saturation = 1; r.quarterTurns = 0; r.crop = Crop(); r.straightenDegrees = 0; r.cropAspectRatio = nil; r.develop = DevelopAdjustments()
        r.flipHorizontal = false; r.flipVertical = false
        r.perspective = PerspectiveSettings()
        r.vignette = CreativeVignette()
        r.grain = FilmGrain()
        r.sharpening = GeneralSharpening()
        r.noiseReduction = GeneralNoiseReduction()
        r.defringe = nil
        return r
    }
    /// `baseline()` tones on the current rotation, crop and lens correction, so before and after line up pixel for pixel.
    func alignedBaseline() -> Self {
        baseline().aligned(to: self)
    }
    /// Use a saved look on the current geometry for a registered before/after comparison.
    func aligned(to current: Self) -> Self {
        var r = self
        r.quarterTurns = current.quarterTurns; r.crop = current.crop; r.straightenDegrees = current.straightenDegrees; r.cropAspectRatio = current.cropAspectRatio
        r.flipHorizontal = current.flipHorizontal; r.flipVertical = current.flipVertical
        r.perspective = current.perspective
        r.rawDetails.lensCorrection = current.rawDetails.lensCorrection
        return r
    }
}

// Preserve the existing rendering-version rules. The current recipe structure
// requires reflection and perspective fields; older payloads are rejected, never migrated.
extension EditRecipe {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        pipelineVersion = try c.decode(Int.self, forKey: .pipelineVersion)
        sourceDigest = try c.decode(String.self, forKey: .sourceDigest)
        decoderVersion = try c.decode(String.self, forKey: .decoderVersion)
        systemVersion = try c.decode(String.self, forKey: .systemVersion)
        appBuild = try c.decode(String.self, forKey: .appBuild)
        baselineExposure = try c.decode(Double.self, forKey: .baselineExposure)
        baselineTemperature = try c.decode(Double.self, forKey: .baselineTemperature)
        baselineTint = try c.decode(Double.self, forKey: .baselineTint)
        exposure = try c.decode(Double.self, forKey: .exposure)
        temperature = try c.decode(Double.self, forKey: .temperature)
        tint = try c.decode(Double.self, forKey: .tint)
        asShotWhiteBalance = try c.decode(Bool.self, forKey: .asShotWhiteBalance)
        contrast = try c.decode(Double.self, forKey: .contrast)
        saturation = try c.decode(Double.self, forKey: .saturation)
        quarterTurns = try c.decode(Int.self, forKey: .quarterTurns)
        guard c.contains(.flipHorizontal), c.contains(.flipVertical) else { throw LRCError(L10n.text("app.unsupportedRecipeStructureFlipStateMissingOriginalDataPreserved", defaultValue: "Unsupported recipe structure: flip state missing. Original data preserved")) }
        flipHorizontal = try c.decode(Bool.self, forKey: .flipHorizontal)
        flipVertical = try c.decode(Bool.self, forKey: .flipVertical)
        guard c.contains(.perspective) else { throw LRCError(L10n.text("app.unsupportedRecipeStructurePerspectiveParametersMissingOriginalDataPreserved", defaultValue: "Unsupported recipe structure: perspective parameters missing. Original data preserved")) }
        perspective = try c.decode(PerspectiveSettings.self, forKey: .perspective)
        sharpening = try c.decode(GeneralSharpening.self, forKey: .sharpening)
        noiseReduction = try c.decode(GeneralNoiseReduction.self, forKey: .noiseReduction)
        defringe = try c.decodeIfPresent(ManualDefringe.self, forKey: .defringe)
        crop = try c.decode(Crop.self, forKey: .crop)
        if schemaVersion == 1 {
            develop = try c.decodeIfPresent(DevelopAdjustments.self, forKey: .develop) ?? DevelopAdjustments()
            straightenDegrees = try c.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        } else {
            develop = try c.decode(DevelopAdjustments.self, forKey: .develop)
            straightenDegrees = try c.decode(Double.self, forKey: .straightenDegrees)
        }
        if schemaVersion >= 3 {
            localAdjustments = try c.decode([LocalAdjustment].self, forKey: .localAdjustments)
            maskVersion = try c.decode(Int.self, forKey: .maskVersion)
        } else {
            localAdjustments = try c.decodeIfPresent([LocalAdjustment].self, forKey: .localAdjustments) ?? []
            maskVersion = try c.decodeIfPresent(Int.self, forKey: .maskVersion) ?? 1
        }
        cropAspectRatio = try c.decodeIfPresent(Double.self, forKey: .cropAspectRatio)
        rawDetails = try c.decodeIfPresent(RAWDetailSettings.self, forKey: .rawDetails) ?? RAWDetailSettings()
        repairs = try c.decodeIfPresent([SpotRepair].self, forKey: .repairs) ?? []
        vignette = try c.decodeIfPresent(CreativeVignette.self, forKey: .vignette) ?? CreativeVignette()
        grain = try c.decodeIfPresent(FilmGrain.self, forKey: .grain) ?? FilmGrain()
    }
}

struct RecipePasteOptions: Codable, Equatable {
    var tone = true
    var whiteBalance = true
    var color = true
    var geometry = false
    var details = false
    var generalDetails = false
    var curves = true
    var zones = true
    /// Present only for imported sparse presets; ordinary copy/paste keeps its group semantics.
    var importedXMP: XMPPresetSettings?
    var hasSelection: Bool { tone || whiteBalance || color || geometry || details || generalDetails || curves || zones }
    var summary: String {
        let groups = [(tone, L10n.text("app.tone", defaultValue: "Tone")), (curves, L10n.text("app.curves", defaultValue: "Curves")), (zones, L10n.text("app.zones", defaultValue: "Zones")), (whiteBalance, L10n.text("app.whiteBalance", defaultValue: "White Balance")),
                      (color, L10n.text("app.color", defaultValue: "Color")), (generalDetails, L10n.text("app.generalDetail", defaultValue: "General Detail")), (details, L10n.text("app.rawDetail", defaultValue: "RAW Detail")), (geometry, L10n.text("app.geometry", defaultValue: "Geometry"))]
        return groups.filter { $0.0 }.map { $0.1 }.joined(separator: "、")
    }
}

extension EditRecipe {
    /// Transfer adjustments, never source identity, decoder metadata or RAW baseline.
    func pasting(_ source: EditRecipe, options: RecipePasteOptions) throws -> Self {
        try source.validate()
        var value = self
        // Partial pastes must not silently reinterpret untouched settings in a new pipeline.
        guard source.pipelineVersion == pipelineVersion else { throw LRCError(L10n.text("app.developmentVersionsDifferUseTheSameVersionOnBoth", defaultValue: "Development versions differ. Use the same version on both photos before pasting")) }
        if options.tone {
            value.exposure = source.exposure; value.contrast = source.contrast
            value.develop.highlights = source.develop.highlights; value.develop.shadows = source.develop.shadows
            value.develop.whites = source.develop.whites; value.develop.blacks = source.develop.blacks
            value.develop.texture = source.develop.texture; value.develop.clarity = source.develop.clarity; value.develop.dehaze = source.develop.dehaze
            value.vignette = source.vignette
            value.grain = source.grain
        }
        if options.whiteBalance, isRaster == source.isRaster {
            value.asShotWhiteBalance = source.asShotWhiteBalance
            value.temperature = source.asShotWhiteBalance ? baselineTemperature : source.temperature
            value.tint = source.asShotWhiteBalance ? baselineTint : source.tint
        }
        if options.color {
            value.saturation = source.saturation; value.develop.vibrance = source.develop.vibrance
            value.develop.blackAndWhite = source.develop.blackAndWhite
            value.develop.blackWhiteMixer = source.develop.blackWhiteMixer
            value.develop.pointColors = source.develop.pointColors
            value.develop.mixer = source.develop.mixer; value.develop.grading = source.develop.grading
        }
        if options.geometry {
            value.quarterTurns = source.quarterTurns; value.straightenDegrees = source.straightenDegrees
            value.flipHorizontal = source.flipHorizontal; value.flipVertical = source.flipVertical
            value.perspective = source.perspective
            value.crop = source.crop; value.cropAspectRatio = nil // Relative crop can have a different pixel aspect on the target.
        }
        if options.generalDetails { value.sharpening = source.sharpening; value.noiseReduction = source.noiseReduction; value.defringe = source.defringe }
        if options.details, !isRaster, !source.isRaster { value.rawDetails = source.rawDetails }
        if options.curves { value.develop.curves = source.develop.curves }
        if options.zones { value.develop.zones = source.develop.zones }
        value.schemaVersion = max(value.schemaVersion, value.localAdjustments.isEmpty ? 2 : 3)
        try value.validate()
        return value
    }

    /// Apply a preset at `amount` (1 = 100 %). Numbers lerp from the current recipe toward the
    /// preset and clamp to control ranges. Integers such as the grain seed stay whole (taken from
    /// the preset at 50 % and above). Masks in the preset are added only when this photo does not
    /// already have the same name and components; their effect is scaled by amount.
    /// Follows lightcraft `crates/develop/src/presets.rs` `apply_partial` at commit 5436951.
    /// Attribution: docs/references/lightcraft-LICENSE.txt.
    func applyingPreset(_ source: EditRecipe, options: RecipePasteOptions, amount: Double) throws -> Self {
        try source.validate()
        if let imported = options.importedXMP {
            let resolved = try imported.resolved(on: self, options: options)
            var native = options
            native.importedXMP = nil
            return try applyingPreset(resolved, options: native, amount: amount)
        }
        guard source.pipelineVersion == pipelineVersion else { throw LRCError(L10n.text("app.developmentVersionsDifferUseTheSameVersionOnBoth", defaultValue: "Development versions differ. Use the same version on both photos before pasting")) }
        let t = amount.isFinite ? min(2, max(0, amount)) : 1
        let scaled: EditRecipe
        if abs(t - 1) < 1e-9 {
            scaled = source
        } else {
            var from = self, toward = source
            if from.asShotWhiteBalance { from.temperature = baselineTemperature; from.tint = baselineTint }
            if toward.asShotWhiteBalance { toward.temperature = baselineTemperature; toward.tint = baselineTint }
            scaled = from.mixing(toward, amount: t)
        }
        var value = try pasting(scaled, options: options)
        if abs(t - 1) >= 1e-9, options.whiteBalance, isRaster == source.isRaster {
            let atShot = value.temperature == baselineTemperature && value.tint == baselineTint
            value.asShotWhiteBalance = atShot && RecipeMix.pick(asShotWhiteBalance, source.asShotWhiteBalance, t)
            try value.validate()
        }
        return try value.addingPresetMasks(from: source, amount: t)
    }

    func transferNotes(from source: EditRecipe, options: RecipePasteOptions) -> [String] {
        if let imported = options.importedXMP {
            var notes = imported.warnings
            if options.whiteBalance, isRaster, imported.contains(.whiteBalance) { notes.append(L10n.text("app.xmpAbsoluteWhiteBalanceAppliesOnlyToRAWJPEG", defaultValue: "XMP absolute white balance applies only to RAW. JPEG/TIFF/PNG white balance preserved")) }
            return notes
        }
        var notes: [String] = []
        var maskTarget = self
        if options.details, !isRaster, !source.isRaster { maskTarget.rawDetails = source.rawDetails }
        if source.localAdjustments.contains(where: { $0.components.contains { $0.raster.map { !$0.source.matches(maskTarget) } ?? false } }) {
            notes.append(L10n.text("app.smartMasksFromOtherSourcesOrLensGeometryWere", defaultValue: "Smart masks from other sources or lens geometry were skipped. Recognize the target photo again"))
        }
        if options.whiteBalance, isRaster != source.isRaster { notes.append(L10n.text("app.rawAndJPEGTIFFPNGUseDifferentWhiteBalance", defaultValue: "RAW and JPEG/TIFF/PNG use different white balance models. Target white balance preserved")) }
        if options.details, isRaster || source.isRaster { notes.append(L10n.text("app.rawSpecificNoiseReductionSharpeningAndLensCorrectionSkipped", defaultValue: "RAW-specific noise reduction, sharpening, and lens correction skipped")) }
        return notes
    }

    func changeTitle(from previous: Self?) -> String {
        guard let previous else { return L10n.text("app.initialState", defaultValue: "Initial State") }
        var parts: [String] = []
        if localAdjustments != previous.localAdjustments { parts.append(L10n.text("app.masksAndLocalAdjustments", defaultValue: "Masks and Local Adjustments")) }
        if repairs != previous.repairs { parts.append(L10n.text("app.spotRemoval", defaultValue: "Spot Removal")) }
        if vignette != previous.vignette { parts.append(L10n.text("app.creativeVignette", defaultValue: "Creative Vignette")) }
        if grain != previous.grain { parts.append(L10n.text("app.grain", defaultValue: "Grain")) }
        if exposure != previous.exposure { parts.append(String(format: L10n.text("app.exposure2f", defaultValue: "Exposure %+.2f"), exposure)) }
        if temperature != previous.temperature || tint != previous.tint || asShotWhiteBalance != previous.asShotWhiteBalance { parts.append(L10n.text("app.whiteBalance", defaultValue: "White Balance")) }
        if contrast != previous.contrast || saturation != previous.saturation || develop != previous.develop { parts.append(L10n.text("app.toneAndColor", defaultValue: "Tone and Color")) }
        if crop != previous.crop || quarterTurns != previous.quarterTurns || straightenDegrees != previous.straightenDegrees || cropAspectRatio != previous.cropAspectRatio { parts.append(L10n.text("app.cropAndStraighten", defaultValue: "Crop and Straighten")) }
        if flipHorizontal != previous.flipHorizontal { parts.append(L10n.text("app.flipHorizontal", defaultValue: "Flip Horizontal")) }
        if flipVertical != previous.flipVertical { parts.append(L10n.text("app.flipVertical", defaultValue: "Flip Vertical")) }
        if perspective != previous.perspective { parts.append(L10n.text("app.manualPerspective", defaultValue: "Manual Perspective")) }
        if pipelineVersion != previous.pipelineVersion { parts.append(L10n.text("app.developmentVersion", defaultValue: "Development Version")) }
        if sharpening != previous.sharpening { parts.append(L10n.text("app.sharpening", defaultValue: "Sharpening")) }
        if noiseReduction != previous.noiseReduction { parts.append(L10n.text("app.generalNoiseReduction", defaultValue: "General Noise Reduction")) }
        if defringe != previous.defringe { parts.append(L10n.text("defringe.title", defaultValue: "Manual Defringe")) }
        if rawDetails != previous.rawDetails { parts.append(L10n.text("app.rawNoiseReductionSharpeningAndLensCorrection", defaultValue: "RAW Noise Reduction, Sharpening, and Lens Correction")) }
        return parts.isEmpty ? L10n.text("app.adjustPhoto", defaultValue: "Adjust Photo") : parts.joined(separator: " · ")
    }

    private func mixing(_ toward: EditRecipe, amount t: Double) -> EditRecipe {
        var value = toward
        value.exposure = RecipeMix.lerp(exposure, toward.exposure, t, -5...5)
        value.contrast = RecipeMix.lerp(contrast, toward.contrast, t, 0...2)
        value.saturation = RecipeMix.lerp(saturation, toward.saturation, t, 0...2)
        value.temperature = RecipeMix.lerp(temperature, toward.temperature, t, 2000...50000)
        value.tint = RecipeMix.lerp(tint, toward.tint, t, -150...150)
        value.asShotWhiteBalance = false
        value.straightenDegrees = RecipeMix.lerp(straightenDegrees, toward.straightenDegrees, t, -45...45)
        value.quarterTurns = RecipeMix.pick(quarterTurns, toward.quarterTurns, t)
        value.flipHorizontal = RecipeMix.pick(flipHorizontal, toward.flipHorizontal, t)
        value.flipVertical = RecipeMix.pick(flipVertical, toward.flipVertical, t)
        value.perspective = PerspectiveSettings(
            horizontal: RecipeMix.lerp(perspective.horizontal, toward.perspective.horizontal, t, -100...100),
            vertical: RecipeMix.lerp(perspective.vertical, toward.perspective.vertical, t, -100...100),
            aspect: RecipeMix.lerp(perspective.aspect, toward.perspective.aspect, t, -100...100),
            constrainCrop: RecipeMix.pick(perspective.constrainCrop, toward.perspective.constrainCrop, t))
        value.crop = RecipeMix.crop(crop, toward.crop, t)
        value.develop = develop.mixing(toward.develop, amount: t)
        value.vignette = vignette.mixing(toward.vignette, amount: t)
        value.grain = grain.mixing(toward.grain, amount: t)
        value.sharpening = sharpening.mixing(toward.sharpening, amount: t)
        value.noiseReduction = noiseReduction.mixing(toward.noiseReduction, amount: t)
        value.manualDefringe = manualDefringe.mixing(toward.manualDefringe, amount: t)
        value.rawDetails = isRaster == toward.isRaster ? rawDetails.mixing(toward.rawDetails, amount: t) : toward.rawDetails
        return value
    }

    private func addingPresetMasks(from source: EditRecipe, amount: Double) throws -> Self {
        guard !source.localAdjustments.isEmpty else { return self }
        var value = self
        for mask in source.localAdjustments {
            if mask.components.contains(where: { $0.raster.map { !$0.source.matches(value) } ?? false }) { continue }
            if value.localAdjustments.contains(where: { $0.name == mask.name && $0.components == mask.components }) { continue }
            guard value.localAdjustments.count < 64 else { break }
            var next = mask
            next.id = UUID()
            next.amount = min(1, max(0, mask.amount * amount))
            value.localAdjustments.append(next)
        }
        value.schemaVersion = max(value.schemaVersion, value.localAdjustments.isEmpty ? 2 : 3)
        if value.localAdjustments.contains(where: { $0.settings != nil }) { value.maskVersion = max(value.maskVersion, 2) }
        if value.localAdjustments.contains(where: { $0.components.contains(where: { $0.raster != nil }) }) { value.maskVersion = 3 }
        try value.validate()
        return value
    }
}

private enum RecipeMix {
    static func lerp(_ a: Double, _ b: Double, _ t: Double, _ range: ClosedRange<Double>) -> Double {
        let value = a + (b - a) * t
        return min(range.upperBound, max(range.lowerBound, value.isFinite ? value : a))
    }
    static func pick<T>(_ a: T, _ b: T, _ t: Double) -> T { t >= 0.5 ? b : a }
    static func optional(_ a: Double?, _ b: Double?, _ t: Double, _ range: ClosedRange<Double>) -> Double? {
        switch (a, b) {
        case (let x?, let y?): return lerp(x, y, t, range)
        default: return pick(a, b, t)
        }
    }
    static func crop(_ a: Crop, _ b: Crop, _ t: Double) -> Crop {
        var x = lerp(a.x, b.x, t, 0...1)
        var y = lerp(a.y, b.y, t, 0...1)
        var width = lerp(a.width, b.width, t, 0.0001...1)
        var height = lerp(a.height, b.height, t, 0.0001...1)
        if x + width > 1 { x = max(0, 1 - width) }
        if x + width > 1 { width = max(0.0001, 1 - x) }
        if y + height > 1 { y = max(0, 1 - height) }
        if y + height > 1 { height = max(0.0001, 1 - y) }
        return Crop(x: x, y: y, width: width, height: height)
    }
}

private extension DevelopAdjustments {
    func mixing(_ toward: Self, amount t: Double) -> Self {
        var value = toward
        value.highlights = RecipeMix.lerp(highlights, toward.highlights, t, -100...100)
        value.shadows = RecipeMix.lerp(shadows, toward.shadows, t, -100...100)
        value.whites = RecipeMix.lerp(whites, toward.whites, t, -100...100)
        value.blacks = RecipeMix.lerp(blacks, toward.blacks, t, -100...100)
        value.texture = RecipeMix.lerp(texture, toward.texture, t, -100...100)
        value.clarity = RecipeMix.lerp(clarity, toward.clarity, t, -100...100)
        value.dehaze = RecipeMix.lerp(dehaze, toward.dehaze, t, -100...100)
        value.vibrance = RecipeMix.lerp(vibrance, toward.vibrance, t, -100...100)
        value.blackAndWhite = RecipeMix.pick(blackAndWhite, toward.blackAndWhite, t)
        value.blackWhiteMixer = zip(blackWhiteMixer, toward.blackWhiteMixer).map { RecipeMix.lerp($0, $1, t, -100...100) }
        if mixer.count == toward.mixer.count {
            value.mixer = zip(mixer, toward.mixer).map { a, b in
                HSLBand(hue: RecipeMix.lerp(a.hue, b.hue, t, -100...100),
                        saturation: RecipeMix.lerp(a.saturation, b.saturation, t, -100...100),
                        luminance: RecipeMix.lerp(a.luminance, b.luminance, t, -100...100))
            }
        } else { value.mixer = RecipeMix.pick(mixer, toward.mixer, t) }
        value.pointColors = PointColor.mixing(pointColors,toward.pointColors,amount:t)
        value.grading = grading.mixing(toward.grading, amount: t)
        value.curves = mixingCurves(curves, toward.curves, amount: t)
        value.zones = mixingZones(zones, toward.zones, amount: t)
        return value
    }
    func mixingCurves(_ a: ToneCurves?, _ b: ToneCurves?, amount t: Double) -> ToneCurves? {
        ToneCurves.mixing(a, b, amount: t)
    }
    func mixingZones(_ a: ToneZones?, _ b: ToneZones?, amount t: Double) -> ToneZones? {
        guard let a, let b, a.gains.count == b.gains.count else { return RecipeMix.pick(a, b, t) }
        return ToneZones(gains: zip(a.gains, b.gains).map { RecipeMix.lerp($0, $1, t, -1...1) })
    }
}

private extension ColorGrading {
    func mixing(_ toward: Self, amount t: Double) -> Self {
        ColorGrading(
            shadows: shadows.mixing(toward.shadows, amount: t),
            midtones: midtones.mixing(toward.midtones, amount: t),
            highlights: highlights.mixing(toward.highlights, amount: t),
            global: global.mixing(toward.global, amount: t),
            blending: RecipeMix.lerp(blending, toward.blending, t, 0...100),
            balance: RecipeMix.lerp(balance, toward.balance, t, -100...100)
        )
    }
}

private extension GradingTone {
    func mixing(_ toward: Self, amount t: Double) -> Self {
        GradingTone(
            hue: RecipeMix.lerp(hue, toward.hue, t, 0...360),
            saturation: RecipeMix.lerp(saturation, toward.saturation, t, 0...100),
            luminance: RecipeMix.lerp(luminance, toward.luminance, t, -100...100)
        )
    }
}

private extension CreativeVignette {
    func mixing(_ toward: Self, amount t: Double) -> Self {
        CreativeVignette(
            amount: RecipeMix.lerp(amount, toward.amount, t, -100...100),
            midpoint: RecipeMix.lerp(midpoint, toward.midpoint, t, 0...100),
            roundness: RecipeMix.lerp(roundness, toward.roundness, t, -100...100),
            feather: RecipeMix.lerp(feather, toward.feather, t, 0...100),
            highlights: RecipeMix.lerp(highlights, toward.highlights, t, 0...100),
            style: RecipeMix.pick(style, toward.style, t)
        )
    }
}

private extension FilmGrain {
    func mixing(_ toward: Self, amount t: Double) -> Self {
        FilmGrain(
            amount: RecipeMix.lerp(amount, toward.amount, t, 0...100),
            size: RecipeMix.lerp(size, toward.size, t, 0...100),
            roughness: RecipeMix.lerp(roughness, toward.roughness, t, 0...100),
            seed: RecipeMix.pick(seed, toward.seed, t)
        )
    }
}

private extension RAWDetailSettings {
    func mixing(_ toward: Self, amount t: Double) -> Self {
        RAWDetailSettings(
            luminanceNoiseReduction: RecipeMix.optional(luminanceNoiseReduction, toward.luminanceNoiseReduction, t, 0...1),
            colorNoiseReduction: RecipeMix.optional(colorNoiseReduction, toward.colorNoiseReduction, t, 0...1),
            sharpness: RecipeMix.optional(sharpness, toward.sharpness, t, 0...1),
            lensCorrection: RecipeMix.pick(lensCorrection, toward.lensCorrection, t)
        )
    }
}
