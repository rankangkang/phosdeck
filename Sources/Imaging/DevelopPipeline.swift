import CoreImage
import Foundation

/// Explicit perceptual-sRGB operations, shared by screen and full-resolution export.
/// The cube is 33³ RGBA floats, with red varying fastest (Core Image's layout).
enum DevelopPipeline {
    typealias RGB = SIMD3<Double>
    private static let cubes = NSCache<NSData, NSData>()
    static func apply(_ input: CIImage, adjustments settings: DevelopAdjustments, interactive: Bool = false) -> CIImage {
        var a = settings
        a.blackWhiteMixer = DevelopAdjustments().blackWhiteMixer // Inactive in the original pipeline.
        guard a != DevelopAdjustments() else { return input }
        var image = input.applyingFilter("CILinearToSRGBToneCurve")
        image = detail(image, amount: a.texture, radius: 2)
        image = detail(image, amount: a.clarity, radius: max(2, max(input.extent.width, input.extent.height) * 0.003))
        var color = a; color.texture = 0; color.clarity = 0
        if color != DevelopAdjustments() {
            let dimension = interactive ? 17 : 33
            image = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": cube(color, dimension: dimension)])
        }
        return image.applyingFilter("CISRGBToneCurveToLinear").cropped(to: input.extent)
    }

    private static func detail(_ input: CIImage, amount: Double, radius: Double) -> CIImage {
        guard amount != 0 else { return input }
        let extended = input.clampedToExtent()
        if amount > 0 {
            return extended.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: radius, kCIInputIntensityKey: amount / 100 * 0.8]).cropped(to: input.extent)
        }
        let blur = extended.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        return input.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: blur, kCIInputTimeKey: -amount / 100 * 0.65]).cropped(to: input.extent)
    }

    private static func cube(_ a: DevelopAdjustments, dimension: Int) -> Data {
        struct Key: Encodable { let adjustments: DevelopAdjustments; let dimension: Int }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = (try! encoder.encode(Key(adjustments: a, dimension: dimension))) as NSData // Validated finite parameters only.
        if let cached = cubes.object(forKey: key) { return cached as Data }
        var values = [Float](); values.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let result = transform(RGB(Double(r), Double(g), Double(b)) / Double(dimension - 1), adjustments: a)
            values.append(contentsOf: [Float(result.x), Float(result.y), Float(result.z), 1])
        } } }
        let data = values.withUnsafeBytes { Data($0) }
        cubes.totalCostLimit = 16 * 1024 * 1024
        cubes.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func smooth(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
        let t = clamp((x - lo) / (hi - lo)); return t * t * (3 - 2 * t)
    }
    static func luma(_ c: RGB) -> Double { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }
    static func hsl(_ c: RGB) -> RGB {
        let hi = max(c.x, max(c.y, c.z)), lo = min(c.x, min(c.y, c.z))
        let d = hi - lo, l = (hi + lo) / 2
        guard d > 0.000001 else { return RGB(0, 0, l) }
        var h: Double
        if hi == c.x { h = (c.y - c.z) / d }
        else if hi == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        return RGB(h, d / max(0.000001, 1 - abs(2 * l - 1)), l)
    }
    static func rgb(_ hsl: RGB) -> RGB {
        let h = (hsl.x.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = (1 - abs(2 * hsl.z - 1)) * hsl.y
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let p: RGB
        switch h {
        case ..<1: p = RGB(c, x, 0)
        case ..<2: p = RGB(x, c, 0)
        case ..<3: p = RGB(0, c, x)
        case ..<4: p = RGB(0, x, c)
        case ..<5: p = RGB(x, 0, c)
        default: p = RGB(c, 0, x)
        }
        return p + RGB(repeating: hsl.z - c / 2)
    }
    /// Adjacent hue bands interpolate smoothly, including magenta → red wraparound.
    static func mixerShift(hue: Double, bands: [HSLBand]) -> RGB {
        let h = (hue + 360).truncatingRemainder(dividingBy: 360)
        let index = HSLBand.centers.lastIndex(where: { $0 <= h }) ?? 0
        let next = (index + 1) % 8
        let end = next == 0 ? 360 : HSLBand.centers[next]
        let t = smooth(HSLBand.centers[index], end, h)
        let a = bands[index], b = bands[next]
        return RGB(a.hue, a.saturation, a.luminance) * (1 - t) + RGB(b.hue, b.saturation, b.luminance) * t
    }
    static func transform(_ input: RGB, adjustments a: DevelopAdjustments) -> RGB {
        var c = input
        let y = luma(c)
        let interior = 4 * y * (1 - y)
        let delta = (a.shadows * (1 - smooth(0.1, 0.65, y)) + a.highlights * smooth(0.35, 0.9, y)) * 0.0022 * interior
            + a.whites * 0.0018 * smooth(0.55, 1, y) + a.blacks * 0.0014 * (1 - smooth(0, 0.35, y))
        c += RGB(repeating: delta)
        c = (c - RGB(repeating: 0.85)) / (1 - a.dehaze * 0.003) + RGB(repeating: 0.85)
        c = RGB(clamp(c.x), clamp(c.y), clamp(c.z))
        var h = hsl(c)
        if h.y > 0.000001 {
            let shift = mixerShift(hue: h.x, bands: a.mixer)
            // Near-neutrals taper to prevent hue instability and tinting gray patches.
            let chroma = smooth(0, 0.15, h.y)
            h.x += shift.x * 0.3 * chroma
            h.y = clamp(h.y * (1 + shift.y / 100))
            h.z = clamp(h.z + shift.z * 0.003 * chroma * 4 * h.z * (1 - h.z))
            h.y = clamp(h.y * (1 + a.vibrance / 100 * (1 - h.y)))
            c = rgb(h)
        }
        if a.blackAndWhite { c = RGB(repeating: luma(c)) }
        let light = clamp(luma(c)), t = clamp(light + a.grading.balance * 0.003)
        let overlap = a.grading.blending * 0.002
        let shadow = 1 - smooth(0.15 - overlap, 0.55 + overlap, t)
        let highlight = smooth(0.45 - overlap, 0.85 + overlap, t)
        let middle = max(0, 1 - shadow - highlight)
        let weights = [shadow, middle, highlight, 1.0]
        let tones = [a.grading.shadows, a.grading.midtones, a.grading.highlights, a.grading.global]
        for (tone, weight) in zip(tones, weights) where weight > 0 && (tone.saturation != 0 || tone.luminance != 0) {
            let tint = rgb(RGB(tone.hue, 1, 0.5))
            let chroma = tint - RGB(repeating: luma(tint))
            c += chroma * (tone.saturation * 0.0022 * weight * 4 * light * (1 - light))
            c += RGB(repeating: tone.luminance * 0.002 * weight * 4 * light * (1 - light))
        }
        return RGB(clamp(c.x), clamp(c.y), clamp(c.z))
    }
}
