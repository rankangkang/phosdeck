import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Immutable sensor baseline extracted from the active RAW decoder backend.
struct RAWBaselineMetrics: Equatable, Sendable {
    let decoderVersion: String
    let exposure: Double
    let temperature: Double
    let tint: Double
}

/// Thin decoder boundary isolating Apple's `CIRAWFilter` from `ImagePipeline`.
/// Future backends (for example a dedicated LibRaw + Metal lane) can implement
/// the same contract under their own frozen `EditRecipe.decoderVersion`.
final class RAWDecoderSession {
    private static let validationContext = CIContext(options: [.cacheIntermediates: false])

    static func releaseValidationCaches() { validationContext.clearCaches() }

    private let filter: CIRAWFilter
    let defaults: RAWDetailSettings

    init(url: URL, decoderVersion: String? = nil, unavailableMessage: String? = nil) throws {
        let raw = try PhotoFileType.openAppleRAWFilter(url)
        if let decoderVersion {
            let version = CIRAWDecoderVersion(rawValue: decoderVersion)
            guard raw.supportedDecoderVersions.contains(version) else {
                throw LRCError(unavailableMessage ?? L10n.text("app.theRecipeSOriginalDecoderIsUnavailableReRendering", defaultValue: "The recipe's original decoder is unavailable. Re-rendering stopped"))
            }
            if raw.decoderVersion != version { raw.decoderVersion = version }
        }
        self.filter = raw
        self.defaults = RAWDetailSettings(raw: raw)
    }

    var nativeSize: CGSize { filter.nativeSize }

    var orientedNativeSize: CGSize {
        let native = filter.nativeSize
        return filter.orientation.rawValue >= 5
            ? CGSize(width: native.height, height: native.width)
            : native
    }

    var baselineMetrics: RAWBaselineMetrics {
        RAWBaselineMetrics(
            decoderVersion: filter.decoderVersion.rawValue,
            exposure: Double(filter.baselineExposure),
            temperature: Double(filter.neutralTemperature),
            tint: Double(filter.neutralTint)
        )
    }

    var resolvedLensCorrection: Bool? {
        filter.isLensCorrectionSupported ? filter.isLensCorrectionEnabled : nil
    }

    /// Evaluate actual RAW pixels instead of trusting metadata or an embedded JPEG.
    func validateDecode() throws {
        try Self.validateDecode(filter)
    }

    static func validateDecode(_ raw: CIRAWFilter) throws {
        try Task.checkCancellation()
        try PhotoGeometry.checkSize(raw.nativeSize)
        raw.scaleFactor = Float(min(1, 256 / max(raw.nativeSize.width, raw.nativeSize.height)))
        raw.isDraftModeEnabled = false
        guard let image = raw.outputImage, !image.extent.isEmpty, !image.extent.isInfinite,
              image.extent.width.isFinite, image.extent.height.isFinite,
              image.extent.width <= 1024, image.extent.height <= 1024 else {
            throw LRCError(L10n.text("app.rawDecodingFailedOrDimensionsAreInvalid", defaultValue: "RAW decoding failed or dimensions are invalid"))
        }
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        var data = Data(count: width * height * 4)
        do {
            try data.withUnsafeMutableBytes { bytes in
                let destination = CIRenderDestination(bitmapData: bytes.baseAddress!, width: width, height: height,
                                                      bytesPerRow: width * 4, format: .RGBA8)
                destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
                let task = try validationContext.startTask(toRender: image, from: bounds, to: destination, at: .zero)
                _ = try task.waitUntilCompleted()
            }
        } catch {
            throw LRCError(L10n.text("app.cannotDecodeRAWPixelsTheFileMayBeDamaged", defaultValue: "Cannot decode RAW pixels. The file may be damaged or this system may not support its mode: \(error.localizedDescription)"))
        }
        try Task.checkCancellation()
    }

    func applyDetails(_ details: RAWDetailSettings) throws {
        try details.apply(to: filter, defaults: defaults)
    }

    func renderDevelop(previewEdge: Int?, displayEdge: Int? = nil, draft: Bool, baselineExposure: Double, exposure: Double,
                       temperature: Double, tint: Double, details: RAWDetailSettings) throws -> (image: CIImage, scaleFactor: Float) {
        try details.apply(to: filter, defaults: defaults)
        let scale: Float = (previewEdge ?? displayEdge).map { Float(min(1, Double($0) / max(filter.nativeSize.width, filter.nativeSize.height))) } ?? 1
        if filter.scaleFactor != scale { filter.scaleFactor = scale }
        if filter.isDraftModeEnabled != draft { filter.isDraftModeEnabled = draft }
        if filter.extendedDynamicRangeAmount != 0 { filter.extendedDynamicRangeAmount = 0 }
        if filter.baselineExposure != Float(baselineExposure) { filter.baselineExposure = Float(baselineExposure) }
        if filter.exposure != Float(exposure) { filter.exposure = Float(exposure) }
        if filter.neutralTemperature != Float(temperature) { filter.neutralTemperature = Float(temperature) }
        if filter.neutralTint != Float(tint) { filter.neutralTint = Float(tint) }
        guard let output = filter.outputImage else {
            throw LRCError(L10n.text("app.rawDecodingFailed", defaultValue: "RAW decoding failed"))
        }
        return (output, scale)
    }

    func renderMaskBaseline(edge: Int?, baselineExposure: Double, temperature: Double, tint: Double,
                            lensCorrection: Bool?) throws -> CIImage {
        filter.extendedDynamicRangeAmount = 0
        try RAWDetailSettings(lensCorrection: lensCorrection).apply(to: filter, defaults: defaults)
        filter.baselineExposure = Float(baselineExposure)
        filter.exposure = 0
        filter.neutralTemperature = Float(temperature)
        filter.neutralTint = Float(tint)
        filter.scaleFactor = edge.map { Float(min(1, Double($0) / max(filter.nativeSize.width, filter.nativeSize.height))) } ?? 1
        filter.isDraftModeEnabled = false
        guard let output = filter.outputImage else {
            throw LRCError(L10n.text("app.rangeMaskBaselineDecodingFailed", defaultValue: "Range mask baseline decoding failed"))
        }
        return output
    }

    func renderLinearMerge(longEdge: Int?, whiteBalance: WhiteBalanceValue, lensCorrection: Bool?,
                           forDarkCalibration: Bool) throws -> (image: CIImage, nativeSize: CGSize, resolvedLensCorrection: Bool?) {
        if let lensCorrection, filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = lensCorrection
        }
        let resolvedLens = resolvedLensCorrection
        let native = orientedNativeSize
        filter.scaleFactor = longEdge.map { Float(min(1, Double($0) / max(native.width, native.height))) } ?? 1
        filter.isDraftModeEnabled = false
        filter.exposure = 0
        filter.baselineExposure = 0
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.extendedDynamicRangeAmount = 2
        filter.isGamutMappingEnabled = false
        if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
        filter.neutralTemperature = Float(whiteBalance.temperature)
        filter.neutralTint = Float(whiteBalance.tint)
        if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
        if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
        if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
        if forDarkCalibration {
            // Scene-dependent detail processing can alter the same hot pixel
            // differently in a light and a dark before their linear subtraction.
            if filter.isContrastSupported { filter.contrastAmount = 0 }
            if filter.isDetailSupported { filter.detailAmount = 0 }
            if filter.isMoireReductionSupported { filter.moireReductionAmount = 0 }
            // Some runtimes lack these selectors even when the SDK declares them.
            if filter.responds(to: #selector(getter: CIRAWFilter.isDespeckleSupported)),
               filter.responds(to: #selector(setter: CIRAWFilter.despeckleAmount)),
               filter.isDespeckleSupported { filter.despeckleAmount = 0 }
        }
        guard let output = filter.outputImage else {
            throw LRCError(L10n.text("app.rawDecodingFailed", defaultValue: "RAW decoding failed"))
        }
        return (output, native, resolvedLens)
    }

    func renderCullingThumbnail(longEdge: Int, context: CIContext) throws -> CGImage? {
        try PhotoGeometry.checkSize(filter.nativeSize)
        filter.scaleFactor = Float(min(1, CGFloat(longEdge) / max(filter.nativeSize.width, filter.nativeSize.height)))
        filter.isDraftModeEnabled = false
        filter.extendedDynamicRangeAmount = 0
        return filter.outputImage.flatMap {
            let scaled = ImagePipeline.resized($0, longEdge: longEdge)
            return context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        }
    }

    func configureAnalysis(longEdge: Int, baselineExposure: Double, details: RAWDetailSettings) throws {
        try details.apply(to: filter, defaults: defaults)
        filter.scaleFactor = Float(min(1, Double(longEdge) / max(filter.nativeSize.width, filter.nativeSize.height)))
        filter.isDraftModeEnabled = false
        filter.extendedDynamicRangeAmount = 0
        filter.baselineExposure = Float(baselineExposure)
        filter.exposure = 0
    }

    func evaluateAnalysis(whiteBalance: WhiteBalanceValue, exposure: Double = 0, failureMessage: String) throws -> CIImage {
        filter.exposure = Float(exposure)
        filter.neutralTemperature = Float(whiteBalance.temperature)
        filter.neutralTint = Float(whiteBalance.tint)
        guard let output = filter.outputImage else { throw LRCError(failureMessage) }
        return output
    }
}
