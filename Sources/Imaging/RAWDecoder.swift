import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LibRawRuntime

/// Immutable sensor baseline extracted from the active RAW decoder backend.
struct RAWBaselineMetrics: Equatable, Sendable {
    let decoderVersion: String
    let exposure: Double
    let temperature: Double
    let tint: Double
}

/// Dual-backend RAW decoder boundary isolating Apple's `CIRAWFilter` and the
/// LGPL-2.1 `LibRawRuntime` fallback + bitstream verifier from `ImagePipeline`.
final class RAWDecoderSession {
    private static let validationContext = CIContext(options: [.cacheIntermediates: false])

    static func releaseValidationCaches() { validationContext.clearCaches() }

    private enum Backend {
        case apple(CIRAWFilter)
        case libraw(URL, LibRawProbeReport)
    }

    private let url: URL
    private let backend: Backend
    private var cachedLibRawFull: CIImage?
    private var cachedLibRawHalf: CIImage?
    let defaults: RAWDetailSettings

    init(url: URL, decoderVersion: String? = nil, unavailableMessage: String? = nil) throws {
        self.url = url
        _ = try PhotoFileType.validateRAWContainer(url)

        if decoderVersion == LibRawRuntime.decoderVersionIdentifier {
            let probe = try Self.openLibRawProbe(url)
            self.backend = .libraw(url, probe)
            self.defaults = RAWDetailSettings()
            return
        }

        if let raw = CIRAWFilter(imageURL: url) {
            if let decoderVersion {
                let version = CIRAWDecoderVersion(rawValue: decoderVersion)
                guard raw.supportedDecoderVersions.contains(version) else {
                    throw LRCError(unavailableMessage ?? L10n.text("app.theRecipeSOriginalDecoderIsUnavailableReRendering", defaultValue: "The recipe's original decoder is unavailable. Re-rendering stopped"))
                }
                if raw.decoderVersion != version { raw.decoderVersion = version }
            }
            self.backend = .apple(raw)
            self.defaults = RAWDetailSettings(raw: raw)
            return
        }

        // Only fall back to LibRaw when creating a fresh baseline (no frozen Apple decoder version).
        guard decoderVersion == nil else {
            throw LRCError(unavailableMessage ?? L10n.text("app.theRecipeSOriginalDecoderIsUnavailableReRendering", defaultValue: "The recipe's original decoder is unavailable. Re-rendering stopped"))
        }
        let probe = try Self.openLibRawProbe(url)
        self.backend = .libraw(url, probe)
        self.defaults = RAWDetailSettings()
    }

    private static func openLibRawProbe(_ url: URL) throws -> LibRawProbeReport {
        let probe = try LibRawRuntime.probe(url: url, verifyBitstream: true)
        if probe.isBitStreamCorrupted {
            throw LRCError(L10n.text("app.rawBitstreamDamaged", defaultValue: "RAW sensor data is corrupted or incomplete. Import and development stopped"))
        }
        guard probe.succeeded, probe.orientedWidth > 0, probe.orientedHeight > 0 else {
            throw LRCError(L10n.text("app.thisMacOSVersionCannotDevelopThisCameraOrRAW", defaultValue: "This macOS version cannot develop this camera or RAW compression mode"))
        }
        try PhotoGeometry.checkSize(CGSize(width: probe.orientedWidth, height: probe.orientedHeight))
        return probe
    }

    var nativeSize: CGSize {
        switch backend {
        case .apple(let filter): return filter.nativeSize
        case .libraw(_, let probe): return CGSize(width: probe.orientedWidth, height: probe.orientedHeight)
        }
    }

    var orientedNativeSize: CGSize {
        switch backend {
        case .apple(let filter):
            let native = filter.nativeSize
            return filter.orientation.rawValue >= 5
                ? CGSize(width: native.height, height: native.width)
                : native
        case .libraw(_, let probe):
            return CGSize(width: probe.orientedWidth, height: probe.orientedHeight)
        }
    }

    var baselineMetrics: RAWBaselineMetrics {
        switch backend {
        case .apple(let filter):
            return RAWBaselineMetrics(
                decoderVersion: filter.decoderVersion.rawValue,
                exposure: Double(filter.baselineExposure),
                temperature: Double(filter.neutralTemperature),
                tint: Double(filter.neutralTint)
            )
        case .libraw:
            return RAWBaselineMetrics(
                decoderVersion: LibRawRuntime.decoderVersionIdentifier,
                exposure: 0,
                temperature: 5500,
                tint: 0
            )
        }
    }

    var resolvedLensCorrection: Bool? {
        switch backend {
        case .apple(let filter): return filter.isLensCorrectionSupported ? filter.isLensCorrectionEnabled : nil
        case .libraw: return nil
        }
    }

    /// Evaluate actual RAW pixels and verify the compressed sensor bitstream.
    func validateDecode() throws {
        switch backend {
        case .apple(let filter):
            try Self.validateDecode(filter)
            // Verify compressed sensor bitstream when LibRaw recognizes the camera/mode.
            // Unknown newer cameras (isUnsupported) pass through to Apple's validated decode.
            let probe = try LibRawRuntime.probe(url: url, verifyBitstream: true)
            if probe.isBitStreamCorrupted {
                throw LRCError(L10n.text("app.rawBitstreamDamaged", defaultValue: "RAW sensor data is corrupted or incomplete. Import and development stopped"))
            }
        case .libraw(let url, let probe):
            try PhotoGeometry.checkSize(CGSize(width: probe.orientedWidth, height: probe.orientedHeight))
            _ = try LibRawRuntime.decodeLinear(url: url, halfSize: true)
        }
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
        switch backend {
        case .apple(let filter): try details.apply(to: filter, defaults: defaults)
        case .libraw: try details.checkSupport(defaults)
        }
    }

    func renderDevelop(previewEdge: Int?, displayEdge: Int? = nil, draft: Bool, baselineExposure: Double, exposure: Double,
                       temperature: Double, tint: Double, details: RAWDetailSettings) throws -> (image: CIImage, scaleFactor: Float) {
        let targetEdge = previewEdge ?? displayEdge
        switch backend {
        case .apple(let filter):
            try details.apply(to: filter, defaults: defaults)
            let scale: Float = targetEdge.map { Float(min(1, Double($0) / max(filter.nativeSize.width, filter.nativeSize.height))) } ?? 1
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

        case .libraw(_, let probe):
            try details.checkSupport(defaults)
            let useHalf = draft && targetEdge != nil && max(probe.orientedWidth, probe.orientedHeight) > (targetEdge ?? 0) * 2
            var image = try librawBaseImage(halfSize: useHalf)
            if temperature != 5500 || tint != 0 {
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: temperature, y: tint),
                    "inputTargetNeutral": CIVector(x: 5500, y: 0)
                ])
            }
            let totalEV = baselineExposure + exposure
            if totalEV != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: totalEV])
            }
            let scale: Float = targetEdge.map { Float(min(1, Double($0) / max(Double(probe.orientedWidth), Double(probe.orientedHeight)))) } ?? 1
            return (ImagePipeline.resized(image, longEdge: targetEdge), scale)
        }
    }

    func renderMaskBaseline(edge: Int?, baselineExposure: Double, temperature: Double, tint: Double,
                            lensCorrection: Bool?) throws -> CIImage {
        switch backend {
        case .apple(let filter):
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
        case .libraw:
            try RAWDetailSettings(lensCorrection: lensCorrection).checkSupport(defaults)
            let base = try librawBaseImage(halfSize: false)
            return ImagePipeline.resized(base, longEdge: edge)
        }
    }

    func renderLinearMerge(longEdge: Int?, whiteBalance: WhiteBalanceValue, lensCorrection: Bool?,
                           forDarkCalibration: Bool) throws -> (image: CIImage, nativeSize: CGSize, resolvedLensCorrection: Bool?) {
        switch backend {
        case .apple(let filter):
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
                if filter.isContrastSupported { filter.contrastAmount = 0 }
                if filter.isDetailSupported { filter.detailAmount = 0 }
                if filter.isMoireReductionSupported { filter.moireReductionAmount = 0 }
                if filter.responds(to: #selector(getter: CIRAWFilter.isDespeckleSupported)),
                   filter.responds(to: #selector(setter: CIRAWFilter.despeckleAmount)),
                   filter.isDespeckleSupported { filter.despeckleAmount = 0 }
            }
            guard let output = filter.outputImage else {
                throw LRCError(L10n.text("app.rawDecodingFailed", defaultValue: "RAW decoding failed"))
            }
            return (output, native, resolvedLens)

        case .libraw(_, let probe):
            let native = CGSize(width: probe.orientedWidth, height: probe.orientedHeight)
            var image = try librawBaseImage(halfSize: false)
            if whiteBalance.temperature != 5500 || whiteBalance.tint != 0 {
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: whiteBalance.temperature, y: whiteBalance.tint),
                    "inputTargetNeutral": CIVector(x: 5500, y: 0)
                ])
            }
            if let edge = longEdge, edge > 0, max(native.width, native.height) > Double(edge) {
                let scale = Double(edge) / max(native.width, native.height)
                let w = max(1, (native.width * scale).rounded()), h = max(1, (native.height * scale).rounded())
                image = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: w / native.width, y: h / native.height))
                    .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return (image, native, nil)
        }
    }

    func renderCullingThumbnail(longEdge: Int, context: CIContext) throws -> CGImage? {
        switch backend {
        case .apple(let filter):
            try PhotoGeometry.checkSize(filter.nativeSize)
            filter.scaleFactor = Float(min(1, CGFloat(longEdge) / max(filter.nativeSize.width, filter.nativeSize.height)))
            filter.isDraftModeEnabled = false
            filter.extendedDynamicRangeAmount = 0
            return filter.outputImage.flatMap {
                let scaled = ImagePipeline.resized($0, longEdge: longEdge)
                return context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
            }
        case .libraw:
            let scaled = ImagePipeline.resized(try librawBaseImage(halfSize: true), longEdge: longEdge)
            return context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        }
    }

    private var analysisEdge: Int = 512
    private var analysisBaselineExposure: Double = 0

    func configureAnalysis(longEdge: Int, baselineExposure: Double, details: RAWDetailSettings) throws {
        analysisEdge = longEdge
        analysisBaselineExposure = baselineExposure
        switch backend {
        case .apple(let filter):
            try details.apply(to: filter, defaults: defaults)
            filter.scaleFactor = Float(min(1, Double(longEdge) / max(filter.nativeSize.width, filter.nativeSize.height)))
            filter.isDraftModeEnabled = false
            filter.extendedDynamicRangeAmount = 0
            filter.baselineExposure = Float(baselineExposure)
            filter.exposure = 0
        case .libraw:
            try details.checkSupport(defaults)
        }
    }

    func evaluateAnalysis(whiteBalance: WhiteBalanceValue, exposure: Double = 0, failureMessage: String) throws -> CIImage {
        switch backend {
        case .apple(let filter):
            filter.exposure = Float(exposure)
            filter.neutralTemperature = Float(whiteBalance.temperature)
            filter.neutralTint = Float(whiteBalance.tint)
            guard let output = filter.outputImage else { throw LRCError(failureMessage) }
            return output
        case .libraw:
            var image = ImagePipeline.resized(try librawBaseImage(halfSize: true), longEdge: analysisEdge)
            if whiteBalance.temperature != 5500 || whiteBalance.tint != 0 {
                image = image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: whiteBalance.temperature, y: whiteBalance.tint),
                    "inputTargetNeutral": CIVector(x: 5500, y: 0)
                ])
            }
            let totalEV = analysisBaselineExposure + exposure
            if totalEV != 0 {
                image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: totalEV])
            }
            return image
        }
    }

    private func librawBaseImage(halfSize: Bool) throws -> CIImage {
        if halfSize, let cachedLibRawHalf { return cachedLibRawHalf }
        if !halfSize, let cachedLibRawFull { return cachedLibRawFull }
        let decoded = try LibRawRuntime.decodeLinear(url: url, halfSize: halfSize)
        if halfSize { cachedLibRawHalf = decoded.image } else { cachedLibRawFull = decoded.image }
        return decoded.image
    }
}
