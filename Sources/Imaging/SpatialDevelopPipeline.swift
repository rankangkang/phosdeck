import CoreImage
import Foundation

/// Linear-light spatial operators compiled with the Core Image Metal ABI.
enum SpatialDevelopPipeline {
    private final class Resources {}
    private static let library: Result<Data, Error> = Result {
        guard let url = Bundle(for: Resources.self).url(forResource: "default", withExtension: "metallib") else {
            throw LRCError(L10n.text("app.theShaderRequiredForTheCurrentDevelopmentVersionIs", defaultValue: "The shader required for the current development version is missing"))
        }
        return try Data(contentsOf: url)
    }
    private static let rasterColourKernel: Result<CIKernel, Error> = Result {
        try CIKernel(functionName: "rasterExposureColour", fromMetalLibraryData: library.get(), outputPixelFormat: .RGBAf)
    }
    private static let kernels: Result<[String: CIColorKernel], Error> = Result {
        let data = try library.get()
        let names = ["logLuminance", "linearLuminance", "guideMoments", "guideProduct", "guideCoefficients", "guideReconstruct", "darkChannel", "transmission", "removeHaze", "toneEqualize", "detailEnhance", "toneCurves", "zoneExposure", "blackWhiteMix", "pointColorInput", "pointColorRange", "pointColorMix", "guideWeight", "guideUnweight", "alphaCoverage", "rasterExposure"]
        return try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try CIColorKernel(functionName: $0, fromMetalLibraryData: data, outputPixelFormat: .RGBAf))
        })
    }
    static func run(_ name: String, extent: CGRect, _ args: [Any]) throws -> CIImage {
        guard let kernel = try kernels.get()[name], let image = kernel.apply(extent: extent, arguments: args) else {
            throw LRCError(L10n.text("app.developShaderFailed", defaultValue: "Develop shader failed: \(name)"))
        }
        return image
    }
    static func rasterColour(_ input: CIImage, base: CIImage, low: CIImage, high: CIImage,
                             powers: CIVector, weight: Double) throws -> CIImage {
        guard let image = try rasterColourKernel.get().apply(extent: input.extent,
            roiCallback: { index, rect in index < 2 ? rect : low.extent },
            arguments: [input, base, low, high, powers, weight]) else {
            throw LRCError(L10n.text("app.rasterExposureColorShaderFailed", defaultValue: "Raster exposure color shader failed"))
        }
        return image
    }
    private static func box(_ input: CIImage, radius: Double) -> CIImage {
        // On our macOS target CIBoxBlur's named "radius" selects the odd window
        // width (1/2 are identity, 3/4 use 3 samples). Supply 2r+1 explicitly.
        // The independent CPU reference test freezes the intended box semantics.
        let width = 2 * floor(radius) + 1
        return input.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: width]).cropped(to: input.extent)
    }
    /// He et al. 2010, equations 5–8. Coefficients may be estimated at a reduced
    /// resolution and reconstructed with the original guide (He & Sun 2015).
    /// Caller supplies origin-zero scalar images; borders use replicated pixels.
    static func guided(_ input: CIImage, guide: CIImage, radius: Double, epsilon: Double, maxEdge: Double = 1536, reconstructionGuide: CIImage? = nil, coverage: CIImage? = nil) throws -> CIImage {
        let extent = guide.extent
        let scale = min(1, maxEdge / max(extent.width, extent.height))
        let smallGuide = downsample(guide, scale: scale)
        let smallInput = downsample(input, scale: scale)
        let smallExtent = smallGuide.extent
        let moments = try run("guideMoments", extent: smallExtent, [smallGuide, smallInput])
        let product = try run("guideProduct", extent: smallExtent, [smallGuide, smallInput])
        let r = max(1, radius * scale)
        // Keep opaque photos on the original graph. For transparent photos the
        // small grid stores coverage separately from scalar analysis values.
        let smallCoverage = try coverage.map { source -> CIImage in
            let alpha = try run("alphaCoverage", extent: source.extent, [source])
            let resized = downsample(alpha, scale: scale)
            return resized.applyingFilter("CIMaskToAlpha")
        }
        func mean(_ value: CIImage) throws -> CIImage {
            guard let smallCoverage else { return box(value,radius:r) }
            let weighted = try run("guideWeight",extent:smallExtent,[value,smallCoverage])
            return try run("guideUnweight",extent:smallExtent,[box(weighted,radius:r)])
        }
        let coefficients = try run("guideCoefficients", extent: smallExtent, [mean(moments), mean(product), epsilon])
        let averaged = try mean(coefficients)
        let outputGuide = reconstructionGuide ?? guide
        let upScale = outputGuide.extent.width / smallExtent.width
        let full = averaged.clampedToExtent().transformed(by: CGAffineTransform(scaleX: upScale, y: upScale)).cropped(to: outputGuide.extent)
        return try run("guideReconstruct", extent: outputGuide.extent, [outputGuide, full])
    }
    private static func downsample(_ input: CIImage, scale: Double) -> CIImage {
        guard scale < 1 else { return input }
        return input.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .cropped(to: input.extent.applying(CGAffineTransform(scaleX: scale, y: scale)))
    }
    static func beforeZones(_ input: CIImage, adjustments a: DevelopAdjustments, context: CIContext, opaque: Bool = false) throws -> CIImage {
        var image = ImagePipeline.originZero(input)
        if a.dehaze != 0 { image = try dehaze(image, amount: a.dehaze, context: context) }
        let extent = image.extent
        if a.highlights != 0 || a.shadows != 0 || a.whites != 0 || a.blacks != 0 {
            let guide = try run("logLuminance", extent: extent, [image])
            let coverage = !opaque && ImagePipeline.hasTransparency(image,context:context) ? image : nil
            let base = try guided(guide, guide: guide, radius: max(4, max(extent.width, extent.height) * 0.008), epsilon: 0.08, coverage:coverage)
            image = try run("toneEqualize", extent: extent, [image, base, CIVector(x: a.highlights, y: a.shadows, z: a.whites, w: a.blacks)])
        }
        return image
    }
    static func apply(_ input: CIImage, adjustments a: DevelopAdjustments, context: CIContext, opaque: Bool = false) throws -> CIImage {
        var image = try TonalPipeline.zones(beforeZones(input, adjustments: a, context: context, opaque: opaque),
                                            a.zones, context: context, opaque: opaque)
        let extent = image.extent
        for (amount, radius, epsilon, edge) in [
            (a.texture, 2.0, 0.04, Double.greatestFiniteMagnitude),
            (a.clarity, max(4, max(extent.width, extent.height) * 0.004), 0.16, 1536.0)
        ] where amount != 0 {
            let guide = try run("logLuminance", extent: extent, [image])
            let coverage = !opaque && ImagePipeline.hasTransparency(image,context:context) ? image : nil
            let base = try guided(guide, guide: guide, radius: radius, epsilon: epsilon, maxEdge: edge, coverage:coverage)
            image = try run("detailEnhance", extent: extent, [image, guide, base, amount / 100])
        }
        return image
    }
    static func dehaze(_ input: CIImage, amount: Double, context: CIContext) throws -> CIImage {
        guard amount != 0 else { return input }
        let extent = input.extent
        let air = try estimateAirlight(input, context: context)
        let vector = CIVector(x: air.x, y: air.y, z: air.z)
        // Transmission at a fixed analysis scale, independent of preview/export size.
        let scale = min(1, 1536 / max(extent.width, extent.height))
        let small = downsample(input, scale: scale)
        let dark = try run("darkChannel", extent: small.extent, [small, vector])
            .clampedToExtent().applyingFilter("CIMorphologyRectangleMinimum", parameters: ["inputWidth": 15, "inputHeight": 15]).cropped(to: small.extent)
        let coarse = try run("transmission", extent: small.extent, [dark])
        let guide = try run("linearLuminance", extent: small.extent, [small])
        let fullGuide = try run("linearLuminance", extent: extent, [input])
        let coverage = ImagePipeline.hasTransparency(input,context:context) ? small : nil
        let refined = try guided(coarse, guide: guide, radius: 24, epsilon: 0.001, reconstructionGuide: fullGuide,coverage:coverage)
        return try run("removeHaze", extent: extent, [input, refined, vector, amount / 100])
    }
    /// DCP: brightest source pixel among the top 0.1% of local dark-channel values.
    /// A bounded thumbnail readback is deliberate; no full-resolution CPU bitmap.
    static func estimateAirlight(_ input: CIImage, context: CIContext) throws -> SIMD3<Double> {
        let scale = min(1, 256 / max(input.extent.width, input.extent.height))
        let small = downsample(input, scale: scale)
        let extent = CGRect(x: 0, y: 0, width: max(1, floor(small.extent.width)), height: max(1, floor(small.extent.height)))
        let w = Int(extent.width), h = Int(extent.height)
        var rgb = [Float](repeating: 0, count: w * h * 4)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        context.render(small, toBitmap: &rgb, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: linear)
        // Compute the tiny 3×3 statistic on the single thumbnail readback. Rendering
        // a second dark-channel thumbnail would evaluate the RAW graph twice.
        // Readback is premultiplied. Airlight is a color, not covered energy.
        for i in 0..<(w*h) {
            let a = rgb[i*4+3]
            if a > 0 && a < 1 { for channel in 0..<3 { rgb[i*4+channel] /= a } }
        }
        var dark = [Float](repeating: 0, count: w * h)
        for i in dark.indices { dark[i] = max(0, min(rgb[i * 4], min(rgb[i * 4 + 1], rgb[i * 4 + 2]))) }
        for i in dark.indices where rgb[i*4+3] <= 0 { dark[i] = 1 }
        var values = dark
        for y in 0..<h { for x in 0..<w {
            var value = Float.infinity
            for dy in -1...1 { for dx in -1...1 {
                value = min(value, dark[min(h - 1, max(0, y + dy)) * w + min(w - 1, max(0, x + dx))])
            } }
            values[y * w + x] = value
        } }
        var candidates = [Int]()
        for i in 0..<(w * h) where rgb[i * 4 + 3] > 0 && values[i].isFinite { candidates.append(i) }
        candidates.sort { lhs, rhs in
            let a = values[lhs], b = values[rhs]
            return a == b ? lhs < rhs : a > b
        }
        // An empty transparent image has no airlight evidence and remains empty.
        guard !candidates.isEmpty else { return SIMD3(repeating: 1) }
        let top = candidates.prefix(max(1, Int(ceil(Double(candidates.count) * 0.001))))
        func brightness(_ i: Int) -> Float { rgb[i * 4] + rgb[i * 4 + 1] + rgb[i * 4 + 2] }
        let index = top.max { brightness($0) < brightness($1) }!
        let value = SIMD3<Double>(Double(rgb[index * 4]), Double(rgb[index * 4 + 1]), Double(rgb[index * 4 + 2]))
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { throw LRCError(L10n.text("app.invalidPhotoAtmosphericLightEstimate", defaultValue: "Invalid photo atmospheric light estimate")) }
        // A very dark image has no reliable atmospheric-light evidence. The floor
        // prevents division by zero; black still reconstructs as black.
        return SIMD3(max(0.05, value.x), max(0.05, value.y), max(0.05, value.z))
    }
}
