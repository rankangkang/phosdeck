import Foundation
import PhosdeckPluginKit

struct HighlightSelection: PhotoTool {
    let descriptor = ToolDescriptor(key: "select-highlights", name: "Select Highlights", kind: .luminanceRange, algorithm: 1)

    func evaluate(_ request: ToolRequest, input: PluginImage, profile: Data?) async throws -> ToolResult {
        guard case .luminanceRange = request.parameters, profile == nil else { throw PluginFailure.invalidControl }
        let bins = 1024
        var histogram = Array(repeating: 0, count: bins)
        try input.pixels.withUnsafeBytes { buffer in
            let pixels = buffer.bindMemory(to: SIMD4<Float>.self)
            for y in 0..<input.frame.height {
                try Task.checkCancellation()
                let start = y * input.frame.width
                for p in pixels[start..<(start + input.frame.width)] where p.w > 0 {
                    let light = Self.lightness(p)
                    histogram[Int(light * Float(bins - 1))] += 1
                }
            }
        }
        let count = histogram.reduce(0, +)
        guard count > 0 else { throw PluginFailure.invalidImage }
        let rank = (85 * count + 99) / 100
        var cumulative = 0
        let percentile = histogram.firstIndex { value in cumulative += value; return cumulative >= rank } ?? (bins - 1)
        let lower = min(0.97, Double(percentile) / Double(bins - 1))
        return .luminanceRange(try LuminanceSuggestion(lower: lower, upper: 1, feather: 0.08))
    }

    // Same clamped linear sRGB Oklab L used by the native luminance range kernel.
    private static func lightness(_ p: SIMD4<Float>) -> Float {
        let r = min(1, max(0, p.x)), g = min(1, max(0, p.y)), b = min(1, max(0, p.z))
        let l = cbrtf(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
        let m = cbrtf(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
        let s = cbrtf(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
        return min(1, max(0, 0.2104542553*l + 0.7936177850*m - 0.0040720468*s))
    }
}
