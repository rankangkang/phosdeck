import Accelerate
import Foundation
import PhosdeckPluginKit

struct WarmPrint: PhotoTool {
    let descriptor = ToolDescriptor(key: "warm-print", name: "Warm Print", kind: .developEffect, algorithm: 1)

    func evaluate(_ request: ToolRequest, input: PluginImage, profile: Data?) async throws -> ToolResult {
        guard case .developEffect(let strength) = request.parameters, (0...1).contains(strength), profile == nil else {
            throw PluginFailure.invalidControl
        }
        if strength == 0 { return .developEffect(input) }
        let amount = Float(strength)
        var redGain = 1 + 0.12 * amount
        var greenGain = 1 + 0.02 * amount
        var blueGain = 1 - 0.12 * amount
        var pixels = input.pixels
        try pixels.withUnsafeMutableBytes { raw in
            let channels = raw.bindMemory(to: Float.self).baseAddress!
            let chunkSize = 16_384
            for offset in stride(from: 0, to: input.frame.count, by: chunkSize) {
                try Task.checkCancellation()
                let count = vDSP_Length(min(chunkSize, input.frame.count - offset))
                let red = channels.advanced(by: offset * 4)
                let green = red.advanced(by: 1), blue = red.advanced(by: 2)
                vDSP_vsmul(red, 4, &redGain, red, 4, count)
                vDSP_vsmul(green, 4, &greenGain, green, 4, count)
                vDSP_vsmul(blue, 4, &blueGain, blue, 4, count)
            }
        }
        return .developEffect(try PluginImage(frame: input.frame, pixels: pixels))
    }
}
