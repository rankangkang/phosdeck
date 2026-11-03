import CoreImage
import Foundation

/// Post-crop creative vignette. Not lens-correction vignetting.
/// Parameter mapping and the per-pixel formula follow lightcraft
/// `crates/pipeline/src/finish.rs` (`Vig`, `vignette()`, and the display-linear
/// loop) at commit 5436951. Their luminance is Rec.2020 because that is their
/// working space; ours is Rec.709 because the pixels are linear sRGB.
/// Attribution: docs/references/lightcraft-LICENSE.txt.
enum CreativeVignetteStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    case highlightPriority, colorPriority, paintOverlay
    var id: String { rawValue }
    var title: String {
        switch self {
        case .highlightPriority: return L10n.text("app.highlightPriority", defaultValue: "Highlight Priority")
        case .colorPriority: return L10n.text("app.colorPriority", defaultValue: "Color Priority")
        case .paintOverlay: return L10n.text("app.overlay", defaultValue: "Overlay")
        }
    }
}

struct CreativeVignette: Codable, Equatable {
    var amount = 0.0
    var midpoint = 50.0
    var roundness = 0.0
    var feather = 50.0
    var highlights = 0.0
    var style = CreativeVignetteStyle.highlightPriority
    var isDefault: Bool { self == Self() }
    var isActive: Bool { amount != 0 }
    func validate() throws {
        let signed = [amount, roundness]
        let unsigned = [midpoint, feather, highlights]
        guard signed.allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
              unsigned.allSatisfy({ $0.isFinite && (0...100).contains($0) })
        else { throw LRCError(L10n.text("app.invalidCreativeVignetteParameters", defaultValue: "Invalid creative vignette parameters")) }
    }
}

enum CreativeVignetteMath {
    struct Prepared: Equatable {
        var amount: Float
        var start: Float
        var width: Float
        var aspectMix: Float
        var power: Float
        var highlights: Float
        var style: CreativeVignetteStyle
    }
    static func prepared(_ v: CreativeVignette) -> Prepared? {
        guard v.amount != 0 else { return nil }
        let r = v.roundness / 100
        return Prepared(
            amount: Float(v.amount / 100),
            start: Float(0.15 + v.midpoint / 100 * 0.95),
            width: Float(0.05 + v.feather / 100 * 1.1),
            aspectMix: Float(min(1, max(0, (r + 1) / 2))),
            power: Float(r >= 0 ? 2 : 2 + (-r) * 6),
            highlights: Float(v.highlights / 100),
            style: v.style
        )
    }
    static func smooth(_ lo: Float, _ hi: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - lo) / (hi - lo)))
        return t * t * (3 - 2 * t)
    }
    static func luma(_ c: SIMD3<Float>) -> Float {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }
    /// `x`/`y` are pixel centres in the cropped output, origin at the bottom left.
    static func shade(_ c: SIMD3<Float>, x: Float, y: Float, width: Float, height: Float, vig: Prepared) -> SIMD3<Float> {
        let aspect = width / max(height, 1e-6)
        let u = x / width * 2 - 1
        let v = y / height * 2 - 1
        let sx = 1 + (aspect - 1) * vig.aspectMix
        let sy = 1 + (1 / aspect - 1) * vig.aspectMix
        let n = max(sx, sy)
        let ax = abs(u * max(sx, 1) / n)
        let ay = abs(v * max(sy, 1) / n)
        let dist = pow(pow(ax, vig.power) + pow(ay, vig.power), 1 / vig.power)
        let t = smooth(vig.start, vig.start + vig.width, dist)
        guard t > 0 else { return c }
        if vig.amount < 0 {
            var f = 1 + vig.amount * t
            if vig.style == .highlightPriority {
                f += (1 - f) * vig.highlights * smooth(0.4, 1, min(1, max(0, luma(c))))
            }
            if vig.style == .paintOverlay {
                return c * (1 - (-vig.amount) * t)
            }
            return c * f
        }
        return c + (SIMD3(repeating: 1) - c) * (vig.amount * t * 0.85)
    }
}

enum CreativeVignettePipeline {
    private final class Resources {}
    private static let loaded: Result<CIColorKernel, Error> = Result {
        guard let url = Bundle(for: Resources.self).url(forResource: "default", withExtension: "metallib") else {
            throw LRCError(L10n.text("app.theDevelopShaderRequiredForCreativeVignetteIsMissing", defaultValue: "The develop shader required for creative vignette is missing"))
        }
        return try CIColorKernel(functionName: "creativeVignette", fromMetalLibraryData: Data(contentsOf: url), outputPixelFormat: .RGBAf)
    }
    static func apply(_ input: CIImage, _ vignette: CreativeVignette) throws -> CIImage {
        guard let vig = CreativeVignetteMath.prepared(vignette) else { return input }
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return input }
        let kernel = try loaded.get()
        let style: CGFloat = vig.style == .highlightPriority ? 0 : vig.style == .colorPriority ? 1 : 2
        guard let image = kernel.apply(extent: extent, arguments: [
            input, CIVector(cgRect: extent),
            CIVector(x: CGFloat(vig.amount), y: CGFloat(vig.start), z: CGFloat(vig.width), w: CGFloat(vig.power)),
            CIVector(x: CGFloat(vig.aspectMix), y: CGFloat(vig.highlights), z: style, w: 0)
        ]) else { throw LRCError(L10n.text("app.creativeVignetteShaderFailed", defaultValue: "Creative vignette shader failed")) }
        return image
    }
}
