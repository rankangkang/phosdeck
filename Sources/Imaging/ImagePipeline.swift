import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Metal
import os

enum PreviewLog {
    static let logger = Logger(subsystem: "dev.cmkk.phosdeck", category: "Preview")
}

struct ImageRequest: Codable {
    let photo: Photo
    let root: StorageRoot
    let recipe: EditRecipe?
}

struct RenderedImage {
    let image: CGImage
    let fullSize: CGSize
    let orientedSourceSize: CGSize
    let histogram: ImageHistogram?
    let elapsed: Double
    /// Sources chosen while rendering. A stored offset wins; this fills in automatic picks.
    var spotOffsets: [UUID: MaskPoint] = [:]
}
struct SmartMaskImage {
    let image: CGImage
    let region: CGRect
}

extension RAWDetailSettings {
    init(raw: CIRAWFilter) {
        luminanceNoiseReduction = raw.isLuminanceNoiseReductionSupported ? Double(raw.luminanceNoiseReductionAmount) : nil
        colorNoiseReduction = raw.isColorNoiseReductionSupported ? Double(raw.colorNoiseReductionAmount) : nil
        sharpness = raw.isSharpnessSupported ? Double(raw.sharpnessAmount) : nil
        lensCorrection = raw.isLensCorrectionSupported ? raw.isLensCorrectionEnabled : nil
    }
    func checkSupport(_ defaults: Self) throws {
        try validate()
        if let name = unavailableNames(defaults).first { throw LRCError(L10n.text("app.thisRAWDoesNotSupportAdjustmentsWereNotApplied", defaultValue: "This RAW does not support \(name). Adjustments were not applied")) }
    }
    func unavailableNames(_ defaults: Self) -> [String] {
        [
            (L10n.text("app.luminanceNoiseReduction", defaultValue: "Luminance Noise Reduction"), luminanceNoiseReduction != nil, defaults.luminanceNoiseReduction != nil),
            (L10n.text("app.colorNoiseReduction", defaultValue: "Color Noise Reduction"), colorNoiseReduction != nil, defaults.colorNoiseReduction != nil),
            (L10n.text("app.sharpening_759", defaultValue: "Sharpening"), sharpness != nil, defaults.sharpness != nil),
            (L10n.text("app.lensCorrection", defaultValue: "Lens Correction"), lensCorrection != nil, defaults.lensCorrection != nil)
        ].compactMap { name, requested, supported in requested && !supported ? name : nil }
    }
    /// A nil source value resets a supported target parameter to that target's
    /// own decoder default. Unsupported fields never make the whole paste fail.
    func supported(by defaults: Self) -> Self {
        Self(luminanceNoiseReduction: defaults.luminanceNoiseReduction == nil ? nil : luminanceNoiseReduction,
             colorNoiseReduction: defaults.colorNoiseReduction == nil ? nil : colorNoiseReduction,
             sharpness: defaults.sharpness == nil ? nil : sharpness,
             lensCorrection: defaults.lensCorrection == nil ? nil : lensCorrection)
    }
    func apply(to raw: CIRAWFilter, defaults: Self) throws {
        try checkSupport(defaults)
        if let v = luminanceNoiseReduction ?? defaults.luminanceNoiseReduction, raw.luminanceNoiseReductionAmount != Float(v) { raw.luminanceNoiseReductionAmount = Float(v) }
        if let v = colorNoiseReduction ?? defaults.colorNoiseReduction, raw.colorNoiseReductionAmount != Float(v) { raw.colorNoiseReductionAmount = Float(v) }
        if let v = sharpness ?? defaults.sharpness, raw.sharpnessAmount != Float(v) { raw.sharpnessAmount = Float(v) }
        if let v = lensCorrection ?? defaults.lensCorrection, raw.isLensCorrectionEnabled != v { raw.isLensCorrectionEnabled = v }
    }
}

/// One serialized image lane. Preview and export share the same graph and sRGB conversion.
actor ImagePipeline {
    /// Shared serialized analysis lane, separate from interactive previews.
    static let automaticAnalysis = ImagePipeline()
    private let context: CIContext
    private let developContext: CIContext
    static let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var previewRAW: (key: String, filter: CIRAWFilter, defaults: RAWDetailSettings, details: RAWDetailSettings)?
    private var previewDecoded: (key: String, image: CIImage)?
    private var maskBaselineCache: (key: String, image: CIImage)?
    private var previewSpatial: (key: String, image: CIImage)?
    private let maskCache = MaskPipeline.RasterCache()
    private var qualityDecoded: (key: String, image: CIImage)?
    private var qualitySourceKey: String?
    private let qualityCacheLimit: Int
    private(set) var qualityCacheBytes = 0
    private var renderedSpotOffsets: [UUID: MaskPoint] = [:]
    private var spotLinearBase: (key: String, buffer: SpotBuffer)?
    private var spotDone: (key: String, repairs: [SpotRepair], rendered: SpotRepairMath.Rendered)?
    private var spotCut: (key: String, index: Int, prefix: [SpotRepair], buffer: SpotBuffer, offsets: [UUID: MaskPoint])?
    init(cacheIntermediates: Bool = false, qualityCacheLimit: Int = 512 * 1024 * 1024) {
        self.qualityCacheLimit = max(0, qualityCacheLimit)
        let options: [CIContextOption: Any] = [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: cacheIntermediates]
        if let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
        else { context = CIContext(options: options) }
        var developOptions = options
        // Guided-filter variances require float precision. Preserve the old context
        // for saved recipes so this precision change cannot alter their rendering.
        developOptions[.workingFormat] = CIFormat.RGBAf
        if let device = MTLCreateSystemDefaultDevice() { developContext = CIContext(mtlDevice: device, options: developOptions) }
        else { developContext = CIContext(options: developOptions) }
    }

    private func source(_ request: ImageRequest, verifyDigest: Bool = true) throws -> (AccessLease, URL) {
        try request.recipe?.validate(for: request.photo)
        let lease = try AccessLease(bookmark: request.root.bookmark)
        let url = lease.url.appendingPathComponent(request.photo.relativePath)
        try SourceAvailability.check(root: lease.url, file: url)
        guard request.photo.availability == "available" else { throw LRCError(L10n.text("app.sourceIdentityNeedsVerificationRelocateItBeforeEditingExporting", defaultValue: "Source identity needs verification. Relocate it before editing / exporting")) }
        let expected = try JSONDecoder().decode(FileIdentity.self, from: request.photo.identity)
        guard try FileIdentity.read(url) == expected else { throw LRCError(L10n.text("app.theSourceWasReplacedOrModifiedEditingAndExport", defaultValue: "The source was replaced or modified. Editing and export paused")) }
        if verifyDigest, let digest = request.recipe?.sourceDigest ?? request.photo.digest {
            guard try SafeFileWriter.sha256(url) == digest else { throw LRCError(L10n.text("app.theSourceContentDigestChangedEditingAndExportPaused", defaultValue: "The source content digest changed. Editing and export paused")) }
        }
        return (lease, url)
    }

    /// Validate geometry for a batch target against its current oriented decode,
    /// including lens settings. No bitmap or output file is materialized.
    func geometrySourceSize(_ request: ImageRequest) throws -> CGSize {
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        var oriented = CGSize.zero
        return try graph(request, url: url, orientedSourceSize: &oriented, decodeOnly: true).extent.size
    }

    func baseline(_ request: ImageRequest) throws -> EditRecipe {
        return try autoreleasepool {
            let (lease, url) = try source(request)
            defer { withExtendedLifetime(lease) {} }
            guard request.photo.supportsEditing else { throw LRCError(L10n.text("app.editingThisFormatIsNotYetSupported", defaultValue: "Editing this format is not yet supported")) }
            let digest = try SafeFileWriter.sha256(url)
            if !request.photo.isRAW {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      request.photo.details?.composite != nil || [UTType.jpeg.identifier, UTType.tiff.identifier, UTType.png.identifier].contains(CGImageSourceGetType(source) as String? ?? "") else {
                    throw LRCError(L10n.text("app.sourceContentsAreNotJPEGTIFFPNG", defaultValue: "Source contents are not JPEG/TIFF/PNG"))
                }
                _ = try raster(url)
                guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: request.photo.identity) else { throw LRCError(L10n.text("app.theSourceChangedWhileCreatingItsBaseline", defaultValue: "The source changed while creating its baseline")) }
                var recipe = EditRecipe(sourceDigest: digest, decoderVersion: request.photo.details?.composite == nil ? EditRecipe.rasterDecoderVersion : EditRecipe.linearCompositeDecoderVersion,
                    baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
                recipe.grain.ensureSeed()
                return recipe
            }
            let raw = try PhotoFileType.rawFilter(url)
            try PhotoFileType.validateRAWDecode(raw)
            guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: request.photo.identity) else { throw LRCError(L10n.text("app.theSourceChangedWhileCreatingItsBaseline", defaultValue: "The source changed while creating its baseline")) }
            var recipe = EditRecipe(sourceDigest: digest, decoderVersion: raw.decoderVersion.rawValue,
                              baselineExposure: Double(raw.baselineExposure), baselineTemperature: Double(raw.neutralTemperature),
                              baselineTint: Double(raw.neutralTint), temperature: Double(raw.neutralTemperature), tint: Double(raw.neutralTint))
            recipe.grain.ensureSeed()
            return recipe
        }
    }

    func rawDefaults(_ request: ImageRequest) throws -> RAWDetailSettings {
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        guard request.photo.isRAW else { throw LRCError(L10n.text("app.theSourceIsNotRAW", defaultValue: "The source is not RAW")) }
        let raw = try PhotoFileType.rawFilter(url)
        if let recipe = request.recipe {
            try recipe.validate()
            let decoder = CIRAWDecoderVersion(rawValue: recipe.decoderVersion)
            guard raw.supportedDecoderVersions.contains(decoder) else { throw LRCError(L10n.text("app.theRecipeSOriginalDecoderIsUnavailable", defaultValue: "The recipe's original decoder is unavailable")) }
            raw.decoderVersion = decoder
        }
        let defaults = RAWDetailSettings(raw: raw)
        try request.recipe?.rawDetails.checkSupport(defaults)
        return defaults
    }

    /// Independent full-float lane for merging originals. No geometry, creative edits,
    /// raster response LUT, global RAW look or preview cache enters the master.
    func mergeDecode(_ request: ImageRequest,longEdge: Int?,whiteBalance: WhiteBalanceValue) throws -> MergeFrame {
        try autoreleasepool {
            let (lease,url) = try source(request)
            defer { withExtendedLifetime(lease) {} }
            let image: CIImage
            let native: CGSize
            if request.photo.isRAW {
                let raw = try PhotoFileType.rawFilter(url)
                if let recipe = request.recipe {
                    let version = CIRAWDecoderVersion(rawValue:recipe.decoderVersion)
                    guard raw.supportedDecoderVersions.contains(version) else { throw LRCError(L10n.text("app.theRecipeSOriginalDecoderIsUnavailable", defaultValue:"The recipe's original decoder is unavailable")) }
                    raw.decoderVersion = version
                    // Lens geometry belongs to the source decode. Creative RAW detail settings do not.
                    if let lens = recipe.rawDetails.lensCorrection,raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = lens }
                }
                native = raw.orientation.rawValue >= 5 ? CGSize(width:raw.nativeSize.height,height:raw.nativeSize.width) : raw.nativeSize
                raw.scaleFactor = longEdge.map { Float(min(1,Double($0)/max(native.width,native.height))) } ?? 1
                raw.isDraftModeEnabled = false; raw.exposure = 0; raw.baselineExposure = 0
                raw.boostAmount = 0; raw.boostShadowAmount = 0; raw.extendedDynamicRangeAmount = 2
                raw.isGamutMappingEnabled = false
                if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
                raw.neutralTemperature = Float(whiteBalance.temperature); raw.neutralTint = Float(whiteBalance.tint)
                if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
                if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
                if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
                guard let output = raw.outputImage else { throw LRCError(L10n.text("app.rawDecodingFailed", defaultValue:"RAW decoding failed")) }
                image = Self.originZero(output)
            } else {
                var decoded = try raster(url,materializeSource:true)
                native = decoded.extent.size
                if whiteBalance.temperature != 5500 || whiteBalance.tint != 0 {
                    decoded = decoded.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:whiteBalance.temperature,y:whiteBalance.tint),"inputTargetNeutral":CIVector(x:5500,y:0)])
                }
                if let edge = longEdge,edge > 0,max(native.width,native.height) > Double(edge) {
                    let scale = Double(edge)/max(native.width,native.height)
                    let w = max(1,(native.width*scale).rounded()),h = max(1,(native.height*scale).rounded())
                    // A fractional affine extent rounded outward by readback
                    // otherwise adds a translucent row to an opaque original.
                    // Replicate source edges inside the exact integer canvas.
                    image = decoded.clampedToExtent().transformed(by:CGAffineTransform(scaleX:w/native.width,y:h/native.height))
                        .cropped(to:CGRect(x:0,y:0,width:w,height:h))
                } else { image = decoded }
            }
            try Task.checkCancellation()
            let pixels = try MergeImage.read(image,context:developContext)
            guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self,from:request.photo.identity) else { throw LRCError(L10n.text("merge.sourceChanged", defaultValue:"A source changed during the merge. Reopen the merge window")) }
            let metadata = request.photo.details
            var exposure: Double?
            if let t = metadata?.exposureTime,let f = metadata?.aperture,let iso = metadata?.iso,t > 0,f > 0,iso > 0 {
                exposure = log2(t*Double(iso)/(100*f*f))
            }
            return MergeFrame(image:pixels,exposure:exposure,focal35mm:metadata?.focal35mm,nativeWidth:Int(native.width.rounded()),nativeHeight:Int(native.height.rounded()),raw:request.photo.isRAW,focalLength:metadata?.focalLength,cameraModel:request.photo.camera)
        }
    }
    func verifySource(_ request: ImageRequest) throws {
        let (lease,_) = try source(request)
        withExtendedLifetime(lease) {}
    }

    private func graph(_ request: ImageRequest, url: URL, orientedSourceSize: inout CGSize, previewEdge: Int? = nil, zoneReferenceOnly: Bool = false, pointReferenceOnly: Bool = false, decodeOnly: Bool = false, reuseDecoded: Bool = false) throws -> CIImage {
        renderedSpotOffsets = [:]
        var image: CIImage
        if request.photo.isRAW {
            guard let recipe = request.recipe else { throw LRCError(L10n.text("app.theRAWEditBaselineHasNotBeenCreated", defaultValue: "The RAW edit baseline has not been created")) }
            try recipe.validate()
            let sourceKey = "\(url.path):\(request.photo.identity.base64EncodedString()):\(recipe.sourceDigest):\(recipe.decoderVersion)"
            if reuseDecoded, qualitySourceKey != sourceKey {
                qualityDecoded = nil; qualityCacheBytes = 0; qualitySourceKey = sourceKey
                maskBaselineCache = nil
                maskCache.removeAll()
                context.clearCaches(); developContext.clearCaches()
            }
            let raw: CIRAWFilter
            if previewEdge != nil, let cached = previewRAW, cached.key == sourceKey, cached.details == recipe.rawDetails { raw = cached.filter }
            else {
                raw = try PhotoFileType.rawFilter(url)
                if previewEdge != nil {
                    // A detail/lens change starts a fresh RAW filter. Reusing a
                    // mutated RAF filter can retain stale pixels after reset.
                    context.clearCaches(); developContext.clearCaches()
                    previewDecoded = nil; previewSpatial = nil
                    maskCache.removeAll()
                }
            }
            let decoder = CIRAWDecoderVersion(rawValue: recipe.decoderVersion)
            guard raw.supportedDecoderVersions.contains(decoder) else { throw LRCError(L10n.text("app.theRecipeSOriginalDecoderIsUnavailableReRendering", defaultValue: "The recipe's original decoder is unavailable. Re-rendering stopped")) }
            if raw.decoderVersion != decoder { raw.decoderVersion = decoder }
            let defaults = previewRAW?.key == sourceKey ? previewRAW!.defaults : RAWDetailSettings(raw: raw)
            if previewEdge != nil { previewRAW = (sourceKey, raw, defaults, recipe.rawDetails) }
            try recipe.rawDetails.apply(to: raw, defaults: defaults)
            let scale: Float = previewEdge.map { Float(min(1, Double($0) / max(raw.nativeSize.width, raw.nativeSize.height))) } ?? 1
            let temperature = Float(recipe.asShotWhiteBalance ? recipe.baselineTemperature : recipe.temperature)
            let tint = Float(recipe.asShotWhiteBalance ? recipe.baselineTint : recipe.tint)
            if raw.scaleFactor != scale { raw.scaleFactor = scale }
            let draft = previewEdge != nil && !zoneReferenceOnly && !pointReferenceOnly && !decodeOnly
            if raw.isDraftModeEnabled != draft { raw.isDraftModeEnabled = draft }
            if raw.extendedDynamicRangeAmount != 0 { raw.extendedDynamicRangeAmount = 0 }
            if raw.baselineExposure != Float(recipe.baselineExposure) { raw.baselineExposure = Float(recipe.baselineExposure) }
            if raw.exposure != Float(recipe.exposure) { raw.exposure = Float(recipe.exposure) }
            if raw.neutralTemperature != temperature { raw.neutralTemperature = temperature }
            if raw.neutralTint != tint { raw.neutralTint = tint }
            // CIRAWFilter owns EXIF orientation. Applying it again would rotate twice.
            let native = raw.nativeSize
            orientedSourceSize = raw.orientation.rawValue >= 5 ? CGSize(width: native.height, height: native.width) : native
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let detailsKey = try encoder.encode(recipe.rawDetails).base64EncodedString()
            let decodeKey = "\(sourceKey):\(pointReferenceOnly ? "float-reference" : "preview"):\(raw.scaleFactor):\(draft):\(recipe.baselineExposure):\(recipe.exposure):\(recipe.asShotWhiteBalance ? recipe.baselineTemperature : recipe.temperature):\(recipe.asShotWhiteBalance ? recipe.baselineTint : recipe.tint):\(detailsKey)"
            let decoded: CIImage
            if previewEdge != nil, let cached = previewDecoded, cached.key == decodeKey { decoded = cached.image }
            else if reuseDecoded, recipe.pipelineVersion >= 2, let cached = qualityDecoded, cached.key == decodeKey { decoded = cached.image }
            else {
                if reuseDecoded { qualityDecoded = nil; qualityCacheBytes = 0 }
                guard let output = raw.outputImage else { throw LRCError(L10n.text("app.rawDecodingFailed", defaultValue: "RAW decoding failed")) }
                if previewEdge != nil {
                    // Materialize only the small, linear RAW result. Reuse it for HSL,
                    // tone and spatial edits instead of decoding the RAW on each frame.
                    PreviewLog.logger.debug("raw-raster-start width=\(output.extent.width) height=\(output.extent.height)")
                    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                    guard let raster = developContext.createCGImage(output, from: output.extent, format: pointReferenceOnly ? .RGBAf : .RGBAh, colorSpace: space) else { throw LRCError(L10n.text("app.interactivePreviewDecodingFailed", defaultValue: "Interactive preview decoding failed")) }
                    PreviewLog.logger.debug("raw-raster-done")
                    decoded = CIImage(cgImage: raster)
                    previewDecoded = (decodeKey, decoded)
                } else if reuseDecoded, recipe.pipelineVersion >= 2, fitsQualityCache(output.extent.integral.size),
                          let raster = developContext.createCGImage(output, from: output.extent, format: .RGBAf,
                              colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, deferred: false) {
                    // Full float in the same working space; never cache an 8-bit
                    // screen bitmap as the input to a later quality render.
                    decoded = CIImage(cgImage: raster)
                    let bytes = raster.bytesPerRow * raster.height
                    if bytes <= qualityCacheLimit {
                        qualityDecoded = (decodeKey, decoded); qualityCacheBytes = bytes
                    }
                } else { decoded = output }
            }
            image = try processDecoded(decoded, request: request, url: url, recipe: recipe, decodeKey: decodeKey,
                previewEdge: previewEdge, zoneReferenceOnly: zoneReferenceOnly, pointReferenceOnly:pointReferenceOnly, decodeOnly: decodeOnly, sourceSize: orientedSourceSize)
        } else {
            // Raster sources never enter the RAW decode cache or CIRAWFilter's base look.
            if qualitySourceKey != nil || previewRAW != nil {
                qualityDecoded = nil; qualityCacheBytes = 0; qualitySourceKey = nil
                previewRAW = nil; previewDecoded = nil; previewSpatial = nil
                maskBaselineCache = nil; maskCache.removeAll()
                context.clearCaches(); developContext.clearCaches()
            }
            let decoded = try raster(url)
            orientedSourceSize = decoded.extent.size
            guard let recipe = request.recipe else { return decoded }
            // Exposure is nonlinear: sampling first changes mixed/high-contrast
            // pixels. Both paths apply WB/exposure at source size, then reduce
            // interactive feedback before the remaining spatial/geometry work.
            var base = decoded
            if !recipe.asShotWhiteBalance && (recipe.temperature != 5500 || recipe.tint != 0) {
                base = base.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: recipe.temperature, y: recipe.tint),
                    "inputTargetNeutral": CIVector(x: 5500, y: 0)])
            }
            base = try RasterExposure.apply(base, ev: recipe.exposure, linear:recipe.isLinearComposite)
            base = Self.resized(base, longEdge: previewEdge)
            let decodeKey = "\(url.path):\(request.photo.identity.base64EncodedString()):\(recipe.sourceDigest):\(recipe.decoderVersion):\(previewEdge ?? 0):\(recipe.exposure):\(recipe.asShotWhiteBalance):\(recipe.temperature):\(recipe.tint)"
            image = try processDecoded(base, request: request, url: url, recipe: recipe, decodeKey: decodeKey,
                previewEdge: previewEdge, zoneReferenceOnly: zoneReferenceOnly, pointReferenceOnly:pointReferenceOnly, decodeOnly: decodeOnly, sourceSize: orientedSourceSize)
        }
        return image
    }

    private func raster(_ url: URL,materializeSource: Bool = false) throws -> CIImage {
        if url.pathExtension.lowercased() == "dng",let file = try MergeDNGCodec.open(url) { return try file.image().ciImage() }
        var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        let inspected = try PhotoFileType.inspectSource(url), source = inspected.source
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw LRCError(L10n.text("app.cannotDecodeImageMetadata", defaultValue: "Cannot decode image metadata")) }
        // Preserve the embedded profile; untagged RGB is explicitly interpreted as sRGB.
        if inspected.pngICC == false || (inspected.pngICC == nil && properties[kCGImagePropertyProfileName as String] == nil) {
            options[.colorSpace] = Self.outputSpace
        }
        let decoded: CIImage
        if materializeSource {
            // Full-size JPEG -> RGBAf readback can take Core Image's direct file
            // conversion path, which overruns a decoder buffer on macOS 27 with
            // real 2048px macro JPEGs. ImageIO's decoded bitmap avoids that path;
            // allow float sources and keep their profile, alpha and orientation.
            guard let bitmap = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldAllowFloat:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {
                throw LRCError(L10n.text("app.cannotDecodeTheImageOrColorProfile", defaultValue:"Cannot decode the image or color profile"))
            }
            let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.int32Value ?? 1
            var bitmapOptions = options
            bitmapOptions.removeValue(forKey:.applyOrientationProperty)
            decoded = CIImage(cgImage:bitmap,options:bitmapOptions).oriented(forExifOrientation:orientation)
        } else {
            guard let image = CIImage(contentsOf:url,options:options) else { throw LRCError(L10n.text("app.cannotDecodeTheImageOrColorProfile", defaultValue:"Cannot decode the image or color profile")) }
            decoded = image
        }
        if properties[kCGImagePropertyHasAlpha as String] as? Bool == true, Self.hasTransparency(decoded,context:developContext) {
            // The file decoder can fuse affine sampling in straight/encoded
            // storage, leaking hidden RGB across transparent edges. Establish a
            // concrete premultiplied, linear full-float boundary before any
            // resize/geometry/color work; never use the display's 8-bit bitmap.
            guard let bitmap = developContext.createCGImage(decoded,from:decoded.extent,format:.RGBAf,
                colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,deferred:false) else { throw LRCError(L10n.text("app.floatingPointDecodingOfTheTransparentSourceFailed", defaultValue: "Floating-point decoding of the transparent source failed")) }
            return Self.originZero(CIImage(cgImage:bitmap))
        }
        return Self.originZero(decoded)
    }

    private func processDecoded(_ decoded: CIImage, request: ImageRequest, url: URL, recipe: EditRecipe, decodeKey: String,
                                previewEdge: Int?, zoneReferenceOnly: Bool, pointReferenceOnly:Bool, decodeOnly: Bool, sourceSize: CGSize) throws -> CIImage {
        try Task.checkCancellation()
        if decodeOnly { return Self.originZero(decoded) }
        let repaired = try repairedLinear(decoded, recipe: recipe, cacheKey: decodeKey)
        let denoised = try GeneralDetailPipeline.denoise(repaired,recipe.noiseReduction,sourceSize:sourceSize)
        let base = try ManualDefringePipeline.apply(denoised, recipe.manualDefringe, sourceSize: sourceSize)
        if pointReferenceOnly {
            let spatial = try SpatialDevelopPipeline.apply(base,adjustments:recipe.develop,context:developContext)
            var contrastOnly = recipe; contrastOnly.saturation = 1
            let curved = try TonalPipeline.curves(Self.colorControls(spatial,recipe:contrastOnly),recipe.develop.curves)
            let input = try PointColorPipeline.input(curved,adjustments:recipe.develop)
            return try Self.geometry(input,recipe:recipe,referenceSize:sourceSize)
        }
        if zoneReferenceOnly {
            let input = try SpatialDevelopPipeline.beforeZones(base, adjustments: recipe.develop, context: developContext)
            var guide = try TonalPipeline.zoneGuide(input,context:developContext)
            if Self.hasTransparency(input,context:developContext) {
                guide = try SpatialDevelopPipeline.run("guideWeight",extent:input.extent,[guide,input])
            }
            return try Self.geometry(guide, recipe: recipe, referenceSize: previewEdge != nil ? sourceSize : nil)
        }
        var image: CIImage
        if request.photo.isRAW, previewEdge != nil, recipe.pipelineVersion >= 2 {
            image = try interactiveDevelop(base, recipe: recipe, decodedKey: decodeKey)
        } else {
            image = try Self.develop(base, recipe: recipe, context: developContext, interactive: previewEdge != nil)
        }
        let needsBaseline = recipe.localAdjustments.contains { $0.enabled && $0.amount > 0 && !$0.isNeutral && $0.needsBaseline }
        let baseline = needsBaseline ? try maskBaseline(url: url, recipe: recipe, edge: previewEdge) : nil
        image = try MaskPipeline.apply(image, groups: recipe.localAdjustments, baseline: baseline, context: developContext,
            interactive: previewEdge != nil, cache: previewEdge != nil ? maskCache : nil)
        image = try GeneralDetailPipeline.sharpen(image,recipe.sharpening,sourceSize:sourceSize)
        if !request.photo.isRAW, Self.hasTransparency(image,context:developContext) {
            // Finish neighborhood/local processing on its native pixel grid.
            // Fusing a later affine sample into log-luminance/coverage guides
            // mixes invisible guide values into partially covered edge pixels.
            guard let bitmap = developContext.createCGImage(image,from:image.extent,format:.RGBAf,
                colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,deferred:false) else { throw LRCError(L10n.text("app.floatingPointRenderingOfTransparentAdjustmentsFailed", defaultValue: "Floating-point rendering of transparent adjustments failed")) }
            image = CIImage(cgImage:bitmap)
        }
        image = try Self.geometry(image, recipe: recipe, referenceSize: previewEdge != nil ? sourceSize : nil)
        return try CreativeVignettePipeline.apply(image, recipe.vignette)
    }

    private func fitsQualityCache(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 &&
            size.width <= Double(qualityCacheLimit / 16) && size.height <= Double(qualityCacheLimit / 16) / size.width
    }

    private func maskBaseline(url: URL, recipe: EditRecipe, edge: Int?) throws -> CIImage {
        let key = "\(url.path):\(recipe.sourceDigest):\(recipe.decoderVersion):\(recipe.baselineExposure):\(recipe.baselineTemperature):\(recipe.baselineTint):\(edge ?? 0):lens:\(String(describing: recipe.rawDetails.lensCorrection))"
        if let cached = maskBaselineCache, cached.key == key { return cached.image }
        if recipe.isRaster {
            let image = Self.resized(try raster(url), longEdge: edge)
            maskBaselineCache = (key, image)
            return image
        }
        let raw = try PhotoFileType.rawFilter(url)
        let version = CIRAWDecoderVersion(rawValue: recipe.decoderVersion)
        guard raw.supportedDecoderVersions.contains(version) else { throw LRCError(L10n.text("app.theMaskBaselineDecoderIsUnavailable", defaultValue: "The mask baseline decoder is unavailable")) }
        raw.decoderVersion = version; raw.extendedDynamicRangeAmount = 0
        // Range masks retain their original tonal baseline but must use the same lens geometry.
        try RAWDetailSettings(lensCorrection: recipe.rawDetails.lensCorrection).apply(to: raw, defaults: RAWDetailSettings(raw: raw))
        raw.baselineExposure = Float(recipe.baselineExposure); raw.exposure = 0
        raw.neutralTemperature = Float(recipe.baselineTemperature); raw.neutralTint = Float(recipe.baselineTint)
        raw.scaleFactor = edge.map { Float(min(1, Double($0) / max(raw.nativeSize.width, raw.nativeSize.height))) } ?? 1
        raw.isDraftModeEnabled = false
        guard let output = raw.outputImage else { throw LRCError(L10n.text("app.rangeMaskBaselineDecodingFailed", defaultValue: "Range mask baseline decoding failed")) }
        var image = Self.originZero(output)
        if edge != nil {
            guard let raster = developContext.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else { throw LRCError(L10n.text("app.rangeMaskBaselineRenderingFailed", defaultValue: "Range mask baseline rendering failed")) }
            image = CIImage(cgImage: raster)
        }
        maskBaselineCache = (key, image)
        return image
    }
    func maskReference(_ request: ImageRequest) throws -> CGImage {
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        guard let recipe = request.recipe else { throw LRCError(L10n.text("app.thePhotoIsNotReady", defaultValue: "The photo is not ready")) }
        try recipe.validate()
        let image = try maskBaseline(url: url, recipe: recipe, edge: 1536)
        guard let result = developContext.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else { throw LRCError(L10n.text("app.rangeSamplingFailed", defaultValue: "Range sampling failed")) }
        try Task.checkCancellation()
        return result
    }

    func sampleMask(_ request: ImageRequest, at point: MaskPoint) throws -> MaskSample? {
        try MaskSample.read(at: point, from: maskReference(request), context: developContext)
    }

    func renderMaskOverlay(_ rendered: RenderedImage, request: ImageRequest, group: LocalAdjustment,
                           style: MaskOverlayStyle, color: Int) throws -> CGImage {
        guard let recipe = request.recipe else { return rendered.image }
        let reference = try group.needsBaseline ? maskReference(request) : nil
        let coverage = try MaskPipeline.overlayCoverage(group, recipe: recipe, sourceSize: rendered.orientedSourceSize, reference: reference)
        let photo = CIImage(cgImage: rendered.image)
        let mask = Self.originZero(coverage).transformed(by: CGAffineTransform(
            scaleX: photo.extent.width / coverage.extent.width, y: photo.extent.height / coverage.extent.height))
        let overlay = DisplayOverlay.maskView(photo, coverage: mask, style: style, tint: DisplayOverlay.maskTint(color))
        guard let image = context.createCGImage(overlay, from: photo.extent, format: .RGBA8, colorSpace: Self.outputSpace, deferred: false)
        else { throw LRCError(L10n.text("app.rangeMaskBaselineRenderingFailed", defaultValue: "Range mask baseline rendering failed")) }
        try Task.checkCancellation()
        return image
    }

    /// A separate sRGB model input; the linear range/auto-brush reference is unchanged.
    /// A result cache skips decoding, but must retain the original access, identity and digest checks.
    func validateSmartMaskSource(_ request: ImageRequest) throws {
        try Task.checkCancellation()
        let (lease, _) = try source(request)
        withExtendedLifetime(lease) {}
        try Task.checkCancellation()
    }
    func smartMaskInput(_ request: ImageRequest, region: CGRect? = nil, longEdge: Int = 1536) throws -> SmartMaskImage {
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        guard let recipe = request.recipe, longEdge > 0, longEdge <= 2048 else { throw LRCError(L10n.text("app.smartMaskInputIsNotReady", defaultValue: "Smart mask input is not ready")) }
        let baseline = try maskBaseline(url: url, recipe: recipe, edge: region == nil ? longEdge : nil)
        let bounds = baseline.extent
        var area = bounds
        if let region {
            guard [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite), region.width > 0, region.height > 0 else { throw LRCError(L10n.text("app.invalidSmartMaskCropRegion", defaultValue: "Invalid smart mask crop region")) }
            area = CGRect(x: bounds.minX + region.minX * bounds.width, y: bounds.minY + region.minY * bounds.height,
                width: region.width * bounds.width, height: region.height * bounds.height).integral.intersection(bounds)
        }
        guard !area.isEmpty else { throw LRCError(L10n.text("app.theSmartMaskCropRegionIsEmpty", defaultValue: "The smart mask crop region is empty")) }
        let actual = CGRect(x: (area.minX - bounds.minX) / bounds.width, y: (area.minY - bounds.minY) / bounds.height,
            width: area.width / bounds.width, height: area.height / bounds.height)
        let cropped = Self.resized(Self.originZero(baseline.cropped(to: area)), longEdge: longEdge)
        let gray = CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: Self.outputSpace)!
        let opaque = cropped.composited(over: CIImage(color: gray).cropped(to: cropped.extent))
        guard let image = developContext.createCGImage(opaque, from: opaque.extent, format: .RGBA8, colorSpace: Self.outputSpace, deferred: false),
              try SafeFileWriter.sha256(url) == recipe.sourceDigest else { throw LRCError(L10n.text("app.smartMaskInputFailedOrItsSourceChanged", defaultValue: "Smart mask input failed or its source changed")) }
        try Task.checkCancellation()
        return SmartMaskImage(image: image, region: actual)
    }

    /// Linear decode at a long edge of 512, before spots and creative tone.
    /// Automatic source search uses this grid; the returned offset is normalized.
    func linearRank(_ request: ImageRequest, longEdge: Int = SpotRepairMath.rankEdge) throws -> SpotBuffer {
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        guard request.photo.supportsEditing, request.recipe != nil else { throw LRCError(L10n.text("app.thePhotoIsNotReady", defaultValue: "The photo is not ready")) }
        var size = CGSize.zero
        let image = try graph(request, url: url, orientedSourceSize: &size, previewEdge: longEdge, decodeOnly: true)
        try Task.checkCancellation()
        return try SpotRepairPipeline.buffer(image, context: developContext)
    }

    /// Analyze a bounded float decode, before repairs and all develop operations.
    /// Geometry uses the rendering transform itself, including crop, perspective
    /// and transparent invalid regions; no inverse-coordinate approximation.
    func automaticAdjustment(_ request: ImageRequest, kind: AutomaticAdjustmentKind) throws -> AutomaticAdjustmentResult {
        try Task.checkCancellation()
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        guard request.photo.supportsEditing, let recipe = request.recipe, recipe.pipelineVersion == 2 else { throw AutomaticAdjustmentPixels.insufficient }
        let raw: CIRAWFilter?
        let rasterBase: CIImage?
        let size: CGSize
        if request.photo.isRAW {
            let filter = try PhotoFileType.rawFilter(url)
            let version = CIRAWDecoderVersion(rawValue: recipe.decoderVersion)
            guard filter.supportedDecoderVersions.contains(version) else { throw LRCError(L10n.text("app.theRecipeSOriginalDecoderIsUnavailable", defaultValue: "The recipe's original decoder is unavailable")) }
            filter.decoderVersion = version
            try recipe.rawDetails.apply(to: filter, defaults: RAWDetailSettings(raw: filter))
            filter.scaleFactor = Float(min(1, 512 / max(filter.nativeSize.width, filter.nativeSize.height)))
            filter.isDraftModeEnabled = false; filter.extendedDynamicRangeAmount = 0
            filter.baselineExposure = Float(recipe.baselineExposure)
            size = filter.orientation.rawValue >= 5 ? CGSize(width: filter.nativeSize.height, height: filter.nativeSize.width) : filter.nativeSize
            raw = filter; rasterBase = nil
        } else {
            let decoded = try raster(url)
            size = decoded.extent.size; rasterBase = decoded; raw = nil
        }
        let initial = WhiteBalanceValue(temperature: recipe.baselineTemperature, tint: recipe.baselineTint)
        let current = recipe.asShotWhiteBalance ? initial : WhiteBalanceValue(temperature: recipe.temperature, tint: recipe.tint)
        func decode(_ wb: WhiteBalanceValue, exposure: Double = 0) throws -> CIImage {
            try Task.checkCancellation()
            let image: CIImage
            if let raw {
                raw.exposure = Float(exposure)
                raw.neutralTemperature = Float(wb.temperature); raw.neutralTint = Float(wb.tint)
                guard let output = raw.outputImage else { throw LRCError(L10n.text("app.rawDecodingFailed", defaultValue: "RAW decoding failed")) }
                image = Self.originZero(output)
            } else if let rasterBase {
                var balanced = rasterBase
                if wb.temperature != 5500 || wb.tint != 0 {
                    balanced = balanced.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: wb.temperature, y: wb.tint), "inputTargetNeutral": CIVector(x: 5500, y: 0)])
                }
                // Preserve the source-size raster exposure semantics. Analysis
                // never edits or substitutes the existing response table.
                image = try RasterExposure.apply(balanced, ev: exposure, linear:recipe.isLinearComposite)
            } else { throw AutomaticAdjustmentPixels.insufficient }
            return Self.resized(image, longEdge: 512)
        }
        func pixels(_ image: CIImage) throws -> AutomaticAdjustmentPixels {
            let visible = try Self.geometry(image, recipe: recipe, referenceSize: size)
            return AutomaticAdjustmentPixels(image: visible, context: developContext)
        }
        let result: AutomaticAdjustmentResult
        switch kind {
        case .whiteBalance:
            let selected = try pixels(decode(initial)).whiteBalanceIndices()
            let value = try WhiteBalanceSampling.solve(initial: initial) { wb in
                try pixels(decode(wb)).illuminant(at: selected)
            }
            result = .whiteBalance(value)
        case .tone:
            // Cache only the bounded exposed prefix. Tone trials reuse it and
            // run the same native spatial/contrast operators as preview/export.
            var exposed: [Double: CIImage] = [:]
            result = .tone(try AutomaticToneAnalysis.solve { value in
                let input: CIImage
                if let cached = exposed[value.exposure] { input = cached }
                else {
                    let decoded = try decode(current, exposure: value.exposure)
                    guard let cg = developContext.createCGImage(decoded, from: decoded.extent, format: .RGBAf,
                        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, deferred: false) else { throw AutomaticAdjustmentPixels.insufficient }
                    input = CIImage(cgImage: cg); exposed[value.exposure] = input
                }
                var toneRecipe = recipe
                toneRecipe.develop = DevelopAdjustments(); toneRecipe.saturation = 1
                value.apply(to: &toneRecipe)
                let spatial = try SpatialDevelopPipeline.beforeZones(input, adjustments: toneRecipe.develop, context: developContext)
                return try pixels(Self.colorControls(spatial, recipe: toneRecipe)).toneQuantiles()
            })
        }
        try Task.checkCancellation()
        guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: request.photo.identity) else { throw LRCError(L10n.text("app.theSourceChangedDuringSampling", defaultValue: "The source changed during sampling")) }
        return result
    }

    /// Sample before repairs, tone/color/local adjustments, and output geometry.
    /// RAW uses its own decoder's WB; raster retains the native relative 5500 K / 0 model.
    func sampledWhiteBalance(_ request: ImageRequest, at output: CGPoint) throws -> WhiteBalanceValue {
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        guard let recipe = request.recipe else { throw LRCError(L10n.text("app.thePhotoIsNotReady", defaultValue: "The photo is not ready")) }
        try recipe.validate(for: request.photo)
        let raw: CIRAWFilter?
        let base: CIImage?
        let size: CGSize
        if request.photo.isRAW {
            let filter = try PhotoFileType.rawFilter(url)
            let version = CIRAWDecoderVersion(rawValue: recipe.decoderVersion)
            guard filter.supportedDecoderVersions.contains(version) else { throw LRCError(L10n.text("app.theRecipeSOriginalDecoderIsUnavailable", defaultValue: "The recipe's original decoder is unavailable")) }
            filter.decoderVersion = version
            try recipe.rawDetails.apply(to: filter, defaults: RAWDetailSettings(raw: filter))
            filter.scaleFactor = Float(min(1, 1024 / max(filter.nativeSize.width, filter.nativeSize.height)))
            filter.isDraftModeEnabled = false; filter.extendedDynamicRangeAmount = 0
            filter.baselineExposure = Float(recipe.baselineExposure); filter.exposure = 0
            size = filter.orientation.rawValue >= 5 ? CGSize(width: filter.nativeSize.height, height: filter.nativeSize.width) : filter.nativeSize
            raw = filter; base = nil
        } else {
            let decoded = try raster(url)
            size = decoded.extent.size; base = Self.resized(decoded, longEdge: 1024); raw = nil
        }
        guard MaskPoint(output.x, output.y).valid,
              let point = MaskGeometry.sourcePoint(output, size: size, recipe: recipe) else { throw LRCError(L10n.text("app.thisLocationIsOutsideThePhotoSValidRegion", defaultValue: "This location is outside the photo's valid region")) }
        let initial = WhiteBalanceValue(temperature: request.photo.isRAW ? recipe.baselineTemperature : 5500,
                                        tint: request.photo.isRAW ? recipe.baselineTint : 0)
        func sample(_ value: WhiteBalanceValue, rejectClipped: Bool = false) throws -> SIMD3<Double> {
            try Task.checkCancellation()
            let image: CIImage
            if let raw {
                raw.neutralTemperature = Float(value.temperature); raw.neutralTint = Float(value.tint)
                guard let output = raw.outputImage else { throw LRCError(L10n.text("app.whiteBalanceSamplingDecodeFailed", defaultValue: "White balance sampling decode failed")) }
                image = Self.originZero(output)
            } else if let base {
                image = base.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: value.temperature, y: value.tint), "inputTargetNeutral": CIVector(x: 5500, y: 0)])
            } else { throw LRCError(L10n.text("app.thePhotoIsNotReady", defaultValue: "The photo is not ready")) }
            return try WhiteBalanceSampling.mean(image, at: point, context: developContext, rejectClipped: rejectClipped)
        }
        _ = try sample(initial, rejectClipped: true)
        let value = try WhiteBalanceSampling.solve(initial: initial) { try sample($0) }
        try Task.checkCancellation()
        guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: request.photo.identity) else { throw LRCError(L10n.text("app.theSourceChangedDuringSampling", defaultValue: "The source changed during sampling")) }
        return value
    }

    func alternateSpotSource(_ request: ImageRequest, selected: UUID, avoiding current: MaskPoint?) throws -> MaskPoint? {
        let buffer = try linearRank(request)
        try Task.checkCancellation()
        return try SpotRepairMath.alternateSource(in: buffer, repairs: request.recipe?.repairs ?? [], selected: selected, avoiding: current)
    }

    /// Current-stage sampling: after native curves and HSL, before every point,
    /// vibrance/saturation/BW/grading, local effects, sharpening and output finish.
    /// Float readback retains premultiplied coverage; never samples the screen.
    func pointColorRange(_ reference:PointColorReference,samples:[PointColor],selected:UUID) throws -> CGImage? {
        try Task.checkCancellation()
        let image = try PointColorPipeline.range(reference,samples:samples,selected:selected,context:developContext)
        try Task.checkCancellation(); return image
    }
    func pointColorReference(_ request:ImageRequest,longEdge:Int = 1024,nativeDecode:Bool = false) throws -> PointColorReference {
        let (lease,url) = try source(request); defer { withExtendedLifetime(lease) {} }
        guard let recipe = request.recipe, recipe.pipelineVersion == 2 else { throw LRCError(L10n.text("app.pointColorRequiresTheCurrentDevelopmentRecipe", defaultValue: "Point Color requires the current development recipe")) }
        var size = CGSize.zero
        // Fine fringe sampling must not discard native pixels before a tight
        // crop. Bound the final readback, after the shared output geometry.
        let graph = try graph(request,url:url,orientedSourceSize:&size,previewEdge:nativeDecode ? nil : longEdge,pointReferenceOnly:true)
        let image = Self.resized(graph,longEdge:longEdge), extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        var values = [Float](repeating:0,count:w*h*4)
        developContext.render(image,toBitmap:&values,rowBytes:w*16,bounds:extent,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
        try Task.checkCancellation()
        guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self,from:request.photo.identity) else { throw LRCError(L10n.text("app.theSourceChangedDuringSampling", defaultValue: "The source changed during sampling")) }
        return PointColorReference(width:w,height:h,rgba:values)
    }

    func zoneReference(_ request: ImageRequest) throws -> CGImage {
        let (lease, url) = try source(request)
        defer { withExtendedLifetime(lease) {} }
        guard request.photo.supportsEditing, request.recipe != nil else { throw LRCError(L10n.text("app.thePhotoIsNotReady", defaultValue: "The photo is not ready")) }
        var size = CGSize.zero
        let image = try graph(request, url: url, orientedSourceSize: &size, previewEdge: 1536, zoneReferenceOnly: true)
        guard let result = developContext.createCGImage(image, from: image.extent, format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!) else { throw LRCError(L10n.text("app.zoneLuminanceSamplingFailed", defaultValue: "Zone luminance sampling failed")) }
        try Task.checkCancellation()
        return result
    }

    func sampleZone(_ request: ImageRequest, at point: CGPoint) throws -> Double? {
        zoneExposure(try zoneReference(request), at: point, context: developContext)
    }

    /// Spots sit on the linear decode, before highlights, curves, masks and crop.
    /// The linear buffer and any unchanged repairs stay cached, so dragging one spot
    /// does not heal the others again or read the image back from the GPU.
    private func repairedLinear(_ decoded: CIImage, recipe: EditRecipe, cacheKey: String) throws -> CIImage {
        let active = recipe.repairs.filter { $0.enabled && !$0.points.isEmpty && $0.opacity > 0 }
        guard !active.isEmpty else { renderedSpotOffsets = [:]; return decoded }
        let base = try spotBaseBuffer(decoded, key: cacheKey)
        let rendered = renderSpots(base, repairs: active, key: cacheKey)
        renderedSpotOffsets = rendered.offsets
        return try SpotRepairPipeline.image(rendered.buffer)
    }
    private func spotBaseBuffer(_ decoded: CIImage, key: String) throws -> SpotBuffer {
        if let spotLinearBase, spotLinearBase.key == key { return spotLinearBase.buffer }
        let buffer = try SpotRepairPipeline.buffer(Self.originZero(decoded), context: developContext)
        if max(buffer.width, buffer.height) <= 4096 { spotLinearBase = (key, buffer) }
        return buffer
    }
    private func renderSpots(_ base: SpotBuffer, repairs: [SpotRepair], key: String) -> SpotRepairMath.Rendered {
        if let done = spotDone, done.key == key {
            let cut = sharedSpotPrefix(done.repairs, repairs)
            if cut == done.repairs.count, let tail = SpotRepairMath.renderPinned(from: done.rendered.buffer, repairs: Array(repairs.dropFirst(cut))) {
                return storeSpotResult(key, repairs: repairs, tail: tail, priorOffsets: done.rendered.offsets)
            }
            if let spotCut, spotCut.key == key, spotCut.index == cut, spotCut.prefix == Array(repairs.prefix(cut)),
               let tail = SpotRepairMath.renderPinned(from: spotCut.buffer, repairs: Array(repairs.dropFirst(cut))) {
                return storeSpotResult(key, repairs: repairs, tail: tail, priorOffsets: spotCut.offsets)
            }
        }
        let cut = spotDone?.key == key ? sharedSpotPrefix(spotDone?.repairs ?? [], repairs) : repairs.count
        let pass = SpotRepairMath.render(base, repairs: repairs, captureBefore: cut < repairs.count ? cut : nil)
        if let checkpoint = pass.checkpoint, cut < repairs.count, max(checkpoint.buffer.width, checkpoint.buffer.height) <= 4096 {
            spotCut = (key, cut, Array(repairs.prefix(cut)), checkpoint.buffer, checkpoint.offsets)
        }
        rememberSpotDone(key, repairs: repairs, rendered: pass.rendered)
        return pass.rendered
    }
    private func storeSpotResult(_ key: String, repairs: [SpotRepair], tail: SpotRepairMath.Rendered, priorOffsets: [UUID: MaskPoint]) -> SpotRepairMath.Rendered {
        var offsets = priorOffsets
        let live = Set(repairs.map(\.id))
        offsets = offsets.filter { live.contains($0.key) }
        for (id, offset) in tail.offsets { offsets[id] = offset }
        let rendered = SpotRepairMath.Rendered(buffer: tail.buffer, offsets: offsets)
        rememberSpotDone(key, repairs: repairs, rendered: rendered)
        return rendered
    }
    private func rememberSpotDone(_ key: String, repairs: [SpotRepair], rendered: SpotRepairMath.Rendered) {
        guard max(rendered.buffer.width, rendered.buffer.height) <= 4096 else { return }
        spotDone = (key, repairs, rendered)
    }
    private func sharedSpotPrefix(_ previous: [SpotRepair], _ next: [SpotRepair]) -> Int {
        let count = min(previous.count, next.count)
        for index in 0..<count where previous[index] != next[index] { return index }
        return count
    }

    private func interactiveDevelop(_ decoded: CIImage, recipe: EditRecipe, decodedKey: String) throws -> CIImage {
        var spatial = recipe.develop
        spatial.mixer = DevelopAdjustments().mixer; spatial.grading = ColorGrading()
        spatial.vibrance = 0; spatial.blackAndWhite = false
        spatial.blackWhiteMixer = DevelopAdjustments().blackWhiteMixer
        spatial.curves = nil; spatial.pointColors = []
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let spatialKey = (try encoder.encode(spatial)).base64EncodedString()
        let repairKey = SpotRepair.cacheToken(recipe.repairs)
        let decodedKey = decodedKey + ":nr:" + (try encoder.encode(recipe.noiseReduction)).base64EncodedString()
            + ":defringe:" + (try encoder.encode(recipe.defringe)).base64EncodedString()
        let key = repairKey.isEmpty ? decodedKey + ":" + spatialKey : decodedKey + ":" + repairKey + ":" + spatialKey
        let input: CIImage
        if let cached = previewSpatial, cached.key == key { input = cached.image }
        else {
            let graph = try SpatialDevelopPipeline.apply(decoded, adjustments: spatial, context: developContext)
            let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            guard let raster = developContext.createCGImage(graph, from: graph.extent, format: .RGBAh, colorSpace: space) else { throw LRCError(L10n.text("app.interactivePreviewProcessingFailed", defaultValue: "Interactive preview processing failed")) }
            input = CIImage(cgImage: raster)
            previewSpatial = (key, input)
        }
        var contrastOnly = recipe; contrastOnly.saturation = 1
        let curved = try TonalPipeline.curves(Self.colorControls(input, recipe: contrastOnly), recipe.develop.curves)
        return try PerceptualColor.apply(curved, adjustments: recipe.develop,
                                        saturation: recipe.saturation, interactive: true)
    }

    static func colorControls(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        colorControls(input, contrast: recipe.contrast, saturation: recipe.saturation, linear: recipe.pipelineVersion == 0)
    }
    private static func colorControls(_ input: CIImage, contrast: Double, saturation: Double, linear: Bool = false) -> CIImage {
        guard contrast != 1 || saturation != 1 else { return input }
        let parameters: [String: Any] = [kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation]
        if linear { return input.applyingFilter("CIColorControls", parameters: parameters) }
        // CIColorControls pivots around 0.5. Doing that in linear light crushes
        // ordinary photographic shadows; explicitly enter/leave perceptual sRGB.
        return input.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorControls", parameters: parameters)
            .applyingFilter("CISRGBToneCurveToLinear")
    }

    static func develop(_ input: CIImage, recipe: EditRecipe, context: CIContext, interactive: Bool = false) throws -> CIImage {
        if recipe.pipelineVersion < 2 {
            return DevelopPipeline.apply(colorControls(input, recipe: recipe), adjustments: recipe.develop, interactive: interactive)
        }
        return try develop(input, adjustments: recipe.develop, contrast: recipe.contrast, saturation: recipe.saturation, context: context, interactive: interactive)
    }
    static func develop(_ input: CIImage, adjustments: DevelopAdjustments, contrast: Double, saturation: Double, context: CIContext, interactive: Bool = false) throws -> CIImage {
        let spatial = try SpatialDevelopPipeline.apply(input, adjustments: adjustments, context: context)
        let contrasted = colorControls(spatial, contrast: contrast, saturation: 1)
        return try PerceptualColor.apply(TonalPipeline.curves(contrasted, adjustments.curves), adjustments: adjustments, saturation: saturation, interactive: interactive)
    }

    static func originZero(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    static func geometry(_ input: CIImage, recipe: EditRecipe, referenceSize: CGSize? = nil) throws -> CIImage {
        var image = originZero(input)
        let geometry = try PhotoGeometry(size: recipe.perspective.isNeutral ? image.extent.size : (referenceSize ?? image.extent.size), recipe: recipe)
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        image = originZero(image.oriented(orientations[recipe.quarterTurns]))
        let size = image.extent.size
        if recipe.straightenDegrees != 0 {
            image = image.transformed(by: CropPreviewGeometry.transform(size: size, degrees: recipe.straightenDegrees))
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        let sx = size.width / geometry.canvas.width, sy = size.height / geometry.canvas.height
        if !recipe.perspective.isNeutral {
            let transform = PhotoTransform(CGAffineTransform(scaleX: 1/sx, y: 1/sy)).concatenating(geometry.perspective)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            image = try PerspectivePipeline.apply(image, transform: transform)
        }
        let cropRect = geometry.cropRect.applying(CGAffineTransform(scaleX: sx, y: sy))
        if !recipe.perspective.isNeutral {
            // Translate before cropping: CI rounds a fractional crop origin
            // outward, which would shift low-resolution masks by one pixel.
            let target = CGSize(width: ceil(cropRect.width), height: ceil(cropRect.height))
            image = image.transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
                .transformed(by: CGAffineTransform(scaleX: target.width/cropRect.width, y: target.height/cropRect.height))
                .cropped(to: CGRect(origin: .zero, size: target))
        } else { image = originZero(image.cropped(to: cropRect)) }
        switch (recipe.flipHorizontal, recipe.flipVertical) {
        case (true, false): return originZero(image.oriented(.upMirrored))
        case (false, true): return originZero(image.oriented(.downMirrored))
        case (true, true): return originZero(image.oriented(.down))
        default: return image
        }
    }
    static func resized(_ image: CIImage, longEdge: Int?) -> CIImage {
        guard let edge = longEdge, edge > 0 else { return image }
        let scale = min(1, Double(edge) / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    /// Grain is sized to this bitmap, after crop and any output resize, so a
    /// preview and an export of the same crop keep the same relative grain.
    static func finish(_ image: CIImage, request: ImageRequest) throws -> CIImage {
        guard let recipe = request.recipe else { return image }
        return try FilmGrainPipeline.apply(originZero(image), recipe.grain)
    }

    private static func materialize16(_ image: CIImage, context: CIContext, preserveJPEG8: Bool) throws -> CGImage {
        // createCGImage(.RGBA16) can quantize through half-float on the current
        // Core Image implementation. Explicit readback preserves 16-bit values.
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0, width <= Int.max / 8 / height else { throw LRCError(L10n.text("app.invalid16BitOutputDimensions", defaultValue: "Invalid 16-bit output dimensions")) }
        let rowBytes = width * 8
        var data = Data(count: rowBytes * height)
        try data.withUnsafeMutableBytes { bytes in
            let destination = CIRenderDestination(bitmapData: bytes.baseAddress!, width: width, height: height, bytesPerRow: rowBytes, format: .RGBA16)
            // Storage/encoding use straight color. Quantizing premultiplied RGB
            // first loses effective color precision at small and fractional alpha.
            destination.colorSpace = outputSpace; destination.alphaMode = .unpremultiplied
            destination.isFlipped = true; destination.isDithered = false
            let task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
            let alphaSamples = bytes.bindMemory(to: UInt16.self)
            for index in stride(from:0,to:alphaSamples.count,by:4) where alphaSamples[index+3] == 0 {
                alphaSamples[index] = 0; alphaSamples[index+1] = 0; alphaSamples[index+2] = 0
            }
            if preserveJPEG8 {
                // Neutral, native-size 8-bit sRGB JPEGs retain their decoded codes.
                // Edits, RAW, resizing and higher-depth sources keep float precision.
                let samples = bytes.bindMemory(to: UInt16.self)
                for index in samples.indices { samples[index] = UInt16((UInt32(samples[index]) + 128) / 257 * 257) }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes,
                  space: outputSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder16Little),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric) else { throw LRCError(L10n.text("app.16BitRenderingFailed", defaultValue: "16-bit rendering failed")) }
        return result
    }

    private static func materialize8(_ image: CIImage, context: CIContext) throws -> CGImage {
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0, width <= Int.max / 4 / height else { throw LRCError(L10n.text("app.invalid8BitOutputDimensions", defaultValue: "Invalid 8-bit output dimensions")) }
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let destination = CIRenderDestination(bitmapData: bytes.baseAddress!, width: width, height: height,
                bytesPerRow: width * 4, format: .RGBA8)
            destination.colorSpace = outputSpace; destination.alphaMode = .unpremultiplied
            destination.isFlipped = true; destination.isDithered = false
            let task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
            let samples = bytes.bindMemory(to: UInt8.self)
            for index in stride(from:0,to:samples.count,by:4) where samples[index+3] == 0 {
                samples[index] = 0; samples[index+1] = 0; samples[index+2] = 0
            }
        }
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: outputSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .relativeColorimetric) else { throw LRCError(L10n.text("app.transparentImageRenderingFailed", defaultValue: "Transparent image rendering failed")) }
        return image
    }

    /// Test float alpha before quantization, so even 65534/65535 cannot silently
    /// become opaque. This examines coverage, never a viewing-mat composite.
    static func hasTransparency(_ image: CIImage, context: CIContext) -> Bool {
        let minimum = image.applyingFilter("CIAreaMinimum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(minimum, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return !pixel[3].isFinite || pixel[3] < 1
    }

    private static func mayHaveTransparency(_ request: ImageRequest) -> Bool {
        !request.photo.isRAW || request.recipe.map { $0.straightenDegrees != 0 || !$0.perspective.isNeutral } == true
    }

    private static func canCacheDecoded(_ request: ImageRequest) -> Bool {
        // Decoder 7 (the measured M8/D700/X-T20 files) changes pixels when
        // materialized early, even in RGBA32. Keep its original quality graph.
        // shortcut: early RAW materialization changes cropped pixels; keep the full graph until crop reuse is byte-exact.
        guard request.photo.isRAW, let recipe = request.recipe, recipe.decoderVersion == "8", recipe.pipelineVersion == 2, recipe.contrast == 1, recipe.straightenDegrees == 0, recipe.crop == Crop(),
              recipe.perspective.isNeutral, !recipe.vignette.isActive, !recipe.grain.isActive, !recipe.sharpening.isActive, !recipe.noiseReduction.isActive,
              !recipe.repairs.contains(where: { $0.enabled && $0.opacity > 0 && !$0.points.isEmpty }),
              !recipe.localAdjustments.contains(where: { $0.enabled && $0.amount > 0 && !$0.isNeutral }) else { return false }
        let a = recipe.develop
        // The new per-pixel black/white kernel retains the original quality graph;
        // its RAW materialization equivalence has not been established for caching.
        if a.blackAndWhite && a.blackWhiteMixer.contains(where: { $0 != 0 }) { return false }
        if !a.blackAndWhite && a.pointColors.contains(where:{ !$0.isNeutral }) { return false }
        return [a.highlights, a.shadows, a.whites, a.blacks, a.texture, a.clarity, a.dehaze].allSatisfy { $0 == 0 }
            && (a.zones?.isNeutral ?? true) && (a.curves?.isNeutral ?? true)
    }

    /// Materializing RAW can change Core Image's evaluation, even with full-float
    /// storage. Reuse only the verified color controls at original screen size;
    /// other processing and high-depth output retain the original graph.
    func render(_ request: ImageRequest, longEdge: Int?, pixelFormat: CIFormat = .RGBA8, reuseDecoded: Bool = false, jpegMatte: JPEGMatte? = nil) throws -> RenderedImage {
        return try autoreleasepool {
            var completed = false
            defer {
                // An interrupted or unverified decode must never seed a later
                // quality render, even if the source is subsequently restored.
                if !completed {
                    qualityDecoded = nil; qualityCacheBytes = 0; qualitySourceKey = nil
                    maskBaselineCache = nil; maskCache.removeAll()
                }
            }
            let started = Date()
            let cacheDecoded = reuseDecoded && longEdge == nil && pixelFormat == .RGBA8 && Self.canCacheDecoded(request)
            if reuseDecoded, !cacheDecoded, qualitySourceKey != nil {
                qualityDecoded = nil; qualityCacheBytes = 0; qualitySourceKey = nil
                maskBaselineCache = nil; maskCache.removeAll()
                context.clearCaches(); developContext.clearCaches()
            }
            let (lease, url) = try source(request)
            defer { withExtendedLifetime(lease) {} }
            try Task.checkCancellation()
            var orientedSize = CGSize.zero
            let graph = try graph(request, url: url, orientedSourceSize: &orientedSize, reuseDecoded: cacheDecoded)
            var image = try Self.finish(Self.resized(graph, longEdge: longEdge), request: request)
            let usesDevelop = (request.recipe?.pipelineVersion ?? 0) >= 2 && (request.photo.isRAW || request.recipe?.isUnadjustedRaster == false)
            var renderContext = pixelFormat == .RGBA16 || usesDevelop ? developContext : context
            if let jpegMatte, Self.hasTransparency(image, context: developContext) {
                renderContext = developContext
                guard jpegMatte != .unselected else { throw LRCError(L10n.text("app.thisOutputContainsTransparencyFromItsSourceOrGeometry", defaultValue: "This output contains transparency from its source or geometry. Choose a black or white JPEG matte")) }
                let mat = CIImage(color: jpegMatte == .white ? .white : .black).cropped(to: image.extent)
                // Composite linear float pixels before the single 8-bit/JPEG quantization.
                image = image.composited(over: mat)
            }
            // Publish a materialized bitmap. A deferred CGImage can outlive the RAW graph
            // and be consumed concurrently by the navigator and the Metal canvas.
            let result: CGImage
            if pixelFormat == .RGBA16 {
                var preserveJPEG8 = false
                if !request.photo.isRAW, request.recipe == nil || request.recipe?.isUnadjustedRaster == true, image.extent == graph.extent,
                   let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                    let profile = properties[kCGImagePropertyProfileName as String] as? String
                    preserveJPEG8 = (properties[kCGImagePropertyDepth as String] as? Int) == 8
                        && (profile == nil || profile == "sRGB IEC61966-2.1")
                }
                result = try Self.materialize16(image, context: renderContext, preserveJPEG8: preserveJPEG8)
            }
            else if pixelFormat == .RGBA8, jpegMatte == nil, Self.mayHaveTransparency(request), Self.hasTransparency(image, context: developContext) {
                result = try Self.materialize8(image, context: developContext)
            } else {
                guard let bitmap = renderContext.createCGImage(image, from: image.extent.integral, format: pixelFormat, colorSpace: Self.outputSpace, deferred: false) else { throw LRCError(L10n.text("app.renderingFailed", defaultValue: "Rendering failed")) }
                result = bitmap
            }
            try Task.checkCancellation()
            guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: request.photo.identity) else { throw LRCError(L10n.text("app.theSourceChangedDuringRendering", defaultValue: "The source changed during rendering")) }
            if let digest = request.recipe?.sourceDigest ?? request.photo.digest {
                guard try SafeFileWriter.sha256(url) == digest else { throw LRCError(L10n.text("app.sourceContentsChangedDuringRendering", defaultValue: "Source contents changed during rendering")) }
            }
            // High-depth export does not need a display histogram or an extra 16→8 bit readback.
            let histogram = pixelFormat == .RGBA8 ? ImageHistogram.calculate(result) : nil
            completed = true
            return RenderedImage(image: result, fullSize: graph.extent.size, orientedSourceSize: orientedSize, histogram: histogram, elapsed: Date().timeIntervalSince(started), spotOffsets: renderedSpotOffsets)
        }
    }

    /// Low-resolution screen feedback only. The committed render/export always
    /// validates the complete source digest and uses the full-resolution graph.
    func renderInteractive(_ request: ImageRequest, longEdge: Int = 960) throws -> RenderedImage {
        try autoreleasepool {
            var completed = false
            defer { if !completed { maskBaselineCache = nil; maskCache.removeAll() } }
            try Task.checkCancellation()
            PreviewLog.logger.debug("pipeline-draft-enter")
            let started = Date()
            let (lease, url) = try source(request, verifyDigest: false)
            defer { withExtendedLifetime(lease) {} }
            // Verify once when starting a new cached source; later frames reuse it.
            if let recipe = request.recipe {
                let key = "\(url.path):\(request.photo.identity.base64EncodedString()):\(recipe.sourceDigest):\(recipe.decoderVersion)"
                if previewRAW?.key != key {
                    guard try SafeFileWriter.sha256(url) == recipe.sourceDigest else { throw LRCError(L10n.text("app.theSourceContentDigestChanged", defaultValue: "The source content digest changed")) }
                }
            }
            var orientedSize = CGSize.zero
            let graph = try graph(request, url: url, orientedSourceSize: &orientedSize, previewEdge: longEdge)
            let image = try Self.finish(Self.resized(graph, longEdge: longEdge), request: request)
            let result: CGImage
            if Self.mayHaveTransparency(request), Self.hasTransparency(image, context: developContext) {
                result = try Self.materialize8(image, context: developContext)
            } else {
                guard let bitmap = developContext.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: Self.outputSpace) else { throw LRCError(L10n.text("app.interactivePreviewRenderingFailed", defaultValue: "Interactive preview rendering failed")) }
                result = bitmap
            }
            try Task.checkCancellation()
            guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: request.photo.identity) else { throw LRCError(L10n.text("app.theSourceChangedDuringRendering", defaultValue: "The source changed during rendering")) }
            let nativeSize = try request.recipe.map { try PhotoGeometry(size: orientedSize, recipe: $0).output } ?? orientedSize
            completed = true
            PreviewLog.logger.debug("pipeline-draft-done ms=\(Date().timeIntervalSince(started) * 1000)")
            return RenderedImage(image: result, fullSize: nativeSize, orientedSourceSize: orientedSize,
                                 histogram: nil, elapsed: Date().timeIntervalSince(started), spotOffsets: renderedSpotOffsets)
        }
    }

    /// Submission-time source read. Snapshot only the selected allowlist and pin
    /// its content digest; retries never re-read metadata from the catalog/source.
    func freezeExport(_ snapshot: ExportSnapshot) throws -> ExportSnapshot {
        try snapshot.options.validate()
        try Task.checkCancellation()
        let (lease, url) = try source(snapshot.request)
        defer { withExtendedLifetime(lease) {} }
        let digest = try SafeFileWriter.sha256(url)
        var frozen = ExportMetadata()
        if snapshot.options.metadataPolicy.includesCapture {
            let props = try PhotoFileType.inspectSource(url).properties
            frozen = ExportMetadata.capture(from: props)
        }
        frozen.descriptive = snapshot.metadata.descriptive
        try frozen.validate(policy: snapshot.options.metadataPolicy)
        guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: snapshot.request.photo.identity),
              try SafeFileWriter.sha256(url) == digest else { throw LRCError(L10n.text("app.theSourceChangedWhileFreezingCaptureMetadataNothingQueued", defaultValue: "The source changed while freezing capture metadata; nothing queued")) }
        try Task.checkCancellation()
        var photo = snapshot.request.photo; photo.digest = digest
        return ExportSnapshot(id: snapshot.id, request: ImageRequest(photo: photo, root: snapshot.request.root, recipe: snapshot.request.recipe),
                              destination: snapshot.destination, targetBookmark: snapshot.targetBookmark, options: snapshot.options,
                              retainedStaging: snapshot.retainedStaging, metadata: frozen)
    }

    func export(_ request: ImageRequest, staging: URL, options: ExportOptions, metadata: ExportMetadata = ExportMetadata()) throws -> (Int, Int) {
        return try autoreleasepool {
            try options.validate()
            try metadata.validate(policy: options.metadataPolicy)
            let (lease, url) = try source(request)
            defer { withExtendedLifetime(lease) {} }
            let digest = try SafeFileWriter.sha256(url)
            if let expected = request.recipe?.sourceDigest ?? request.photo.digest, expected != digest { throw LRCError(L10n.text("app.sourceContentsMismatchExportStopped", defaultValue: "Source contents mismatch. Export stopped")) }
            let result = try render(request, longEdge: options.longEdge, pixelFormat: options.format == .tiff ? .RGBA16 : .RGBA8,
                jpegMatte: options.format == .jpeg ? options.jpegMatte : nil)
            guard let destination = CGImageDestinationCreateWithURL(staging as CFURL, options.format.type.identifier as CFString, 1, nil) else { throw LRCError(L10n.text("app.cannotCreate", defaultValue: "Cannot create \(options.format.title)")) }
            CGImageDestinationSetProperties(destination, [kCGImageDestinationEmbedThumbnail: false,
                kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: metadata.descriptive.isEmpty] as CFDictionary)
            // Reconstruct from the frozen typed allowlist; structural fields
            // always describe the rendered image, never the original camera file.
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1, kCGImageDestinationEmbedThumbnail: false,
                kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: metadata.descriptive.isEmpty]
            var tiff = metadata.tiff
            if options.metadataPolicy.includesCapture {
                var exif = metadata.exif
                exif[kCGImagePropertyExifPixelXDimension as String] = result.image.width
                exif[kCGImagePropertyExifPixelYDimension as String] = result.image.height
                exif[kCGImagePropertyExifColorSpace as String] = 1
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if options.format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = options.quality }
            if options.format == .tiff { tiff[kCGImagePropertyTIFFCompression as String] = 5 } // Lossless LZW.
            if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }
            if let descriptive = try metadata.descriptive.imageMetadata() {
                CGImageDestinationAddImageAndMetadata(destination, result.image, descriptive, properties as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, result.image, properties as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw LRCError(L10n.text("app.writingFailedTheDestinationMayBeFull", defaultValue: "Writing \(options.format.title) failed. The destination may be full")) }
            try Self.verifyExport(staging, width: result.image.width, height: result.image.height, format: options.format, metadata: metadata)
            guard try SafeFileWriter.sha256(url) == digest else { throw LRCError(L10n.text("app.sourceContentsChangedDuringOutputPublicationStopped", defaultValue: "Source contents changed during output. Publication stopped")) }
            return (result.image.width, result.image.height)
        }
    }

    static func verifyExport(_ url: URL, width: Int, height: Int, format: ExportFormat = .jpeg, metadata: ExportMetadata? = nil) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == format.type.identifier,
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height, image.bitsPerComponent == format.bitDepth,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              (props[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1,
              props[kCGImagePropertyGPSDictionary as String] == nil,
              image.colorSpace?.name == CGColorSpace.sRGB,
              image.colorSpace?.copyICCData() != nil else { throw LRCError(L10n.text("app.readbackFormatBitDepthDimensionsOrientationOrICCValidation", defaultValue: "\(format.title) readback format, bit depth, dimensions, orientation, or ICC validation failed")) }
        try ExportMetadata.verify(props, width: width, height: height, expected: metadata)
        try (metadata?.descriptive ?? ExportDescription()).verifyEmbedded(in: source, capturedAt: metadata?.capturedAt)
    }
}

actor ThumbnailService {
    private let cache = NSCache<NSString, CGImage>()
    private var disk: PreviewDiskCache?
    private var generation = UUID()
    private var pending: [String: Task<CGImage, Error>] = [:]
    private let render: @Sendable (ImageRequest, Int) async throws -> CGImage
    init(renderer: (@Sendable (ImageRequest, Int) async throws -> CGImage)? = nil) {
        let pipeline = ImagePipeline()
        render = renderer ?? { request, edge in
            let recipe = request.recipe == nil && request.photo.isRAW ? try await pipeline.baseline(request) : request.recipe
            return try await pipeline.render(ImageRequest(photo: request.photo, root: request.root, recipe: recipe), longEdge: edge).image
        }
        cache.totalCostLimit = 128 * 1024 * 1024
    }
    func configure(catalogID: String, gigabytes: Int) throws {
        guard [1, 5, 10].contains(gigabytes), UUID(uuidString: catalogID) != nil else { throw LRCError(L10n.text("app.invalidCacheSettings", defaultValue: "Invalid cache settings")) }
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        generation = UUID(); cache.removeAllObjects()
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        disk = try PreviewDiskCache(directory: base.appendingPathComponent("OhMyLRC/\(catalogID)/Thumbnail-v3"), limit: Int64(gigabytes) * 1024 * 1024 * 1024)
        try disk?.trim()
    }
    func usage() throws -> Int64 { try disk?.usage() ?? 0 }
    nonisolated static func key(photo: Photo, edge: Int) -> String {
        sourceKey(photo: photo, edge: edge) + (photo.recipe != nil ? ":edit-geometry-v1:\(photo.recipeRevision)" : photo.isRAW ? ":apple-raw-source-v1" : ":source")
    }
    nonisolated static func sourceKey(photo: Photo, edge: Int) -> String {
        "\(photo.id):\(photo.identity.base64EncodedString()):\(edge)"
    }
    func image(photo: Photo, root: StorageRoot, edge: Int = 320) async throws -> CGImage {
        try Task.checkCancellation()
        let key = Self.key(photo: photo, edge: edge) as NSString
        if let image = cache.object(forKey: key) { return image }
        if let data = try? disk?.read(key: key as String), let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
            return image
        }
        if photo.recipe != nil || photo.isRAW || URL(fileURLWithPath: photo.relativePath).pathExtension.lowercased() == "png" {
            let recipe = try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) }
            try recipe?.validate(for: photo)
            if let work = pending[key as String] { return try await work.value }
            let prefix = Self.sourceKey(photo: photo, edge: edge) + ":"
            for previous in Array(pending.keys) where previous.hasPrefix(prefix) {
                pending.removeValue(forKey: previous)?.cancel()
            }
            let render = render, token = generation
            // ponytail: one serialized quality lane; reuse delivered previews first,
            // add scaled RAW thumbnail rendering only if cold-cache profiling warrants it.
            let work = Task.detached(priority: .utility) { try await render(ImageRequest(photo: photo, root: root, recipe: recipe), edge) }
            pending[key as String] = work
            defer { if token == generation { pending[key as String] = nil } }
            let result = try await work.value
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            return try store(result, key: key)
        }
        let lease = try AccessLease(bookmark: root.bookmark)
        defer { withExtendedLifetime(lease) {} }
        let url = lease.url.appendingPathComponent(photo.relativePath)
        guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: photo.identity) else { throw LRCError(L10n.text("app.sourceChanged", defaultValue: "Source changed")) }
        let token = generation
        if photo.details?.composite != nil,url.pathExtension.lowercased() == "dng",let file = try MergeDNGCodec.open(url) {
            let pixels = try file.image().resized(longEdge:edge),context = MergeMasterCodec.context()
            guard let image = context.createCGImage(pixels.ciImage(),from:CGRect(x:0,y:0,width:pixels.width,height:pixels.height),format:.RGBA8,colorSpace:ImagePipeline.outputSpace),
                  token == generation,try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self,from:photo.identity) else { throw MergeMasterCodec.invalid }
            return try store(image,key:key)
        }
        let source = try PhotoFileType.imageSource(url)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge] as CFDictionary) else { throw LRCError(L10n.text("app.noThumbnailAvailable", defaultValue: "No thumbnail available")) }
        try Task.checkCancellation()
        guard token == generation, try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: photo.identity) else { throw CancellationError() }
        return try store(image, key: key)
    }
    /// Only committed, uncropped-canvas quality previews are supplied by the model.
    func storePreview(_ image: CGImage, photo: Photo, edge: Int = 320) throws {
        guard photo.recipe != nil else { return }
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(1, CGFloat(edge) / max(size.width, size.height))
        guard let context = CGContext(data: nil, width: max(1, Int(size.width * scale)), height: max(1, Int(size.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: ImagePipeline.outputSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LRCError(L10n.text("app.thumbnailGenerationFailed", defaultValue: "Thumbnail generation failed")) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let thumbnail = context.makeImage() else { throw LRCError(L10n.text("app.thumbnailGenerationFailed", defaultValue: "Thumbnail generation failed")) }
        try store(thumbnail, key: Self.key(photo: photo, edge: edge) as NSString)
    }
    @discardableResult private func store(_ image: CGImage, key: NSString) throws -> CGImage {
        let data = NSMutableData()
        if let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(output, image, nil)
            if CGImageDestinationFinalize(output), let source = CGImageSourceCreateWithData(data, nil),
               let canonical = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                // PNG stores straight color. Use the same encoded bitmap for the
                // first delivery and a cold cache read, including alpha rounding.
                cache.setObject(canonical, forKey: key, cost: canonical.bytesPerRow * canonical.height)
                try? disk?.store(data as Data, key: key as String)
                return canonical
            }
        }
        throw LRCError(L10n.text("app.transparentThumbnailEncodingFailed", defaultValue: "Transparent thumbnail encoding failed"))
    }
    func clear() throws {
        generation = UUID(); pending.values.forEach { $0.cancel() }; pending.removeAll()
        cache.removeAllObjects(); try disk?.clear()
    }
}
