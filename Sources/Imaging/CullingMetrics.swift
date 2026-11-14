import CoreGraphics
import Foundation

/// Display-referred metrics at a common thumbnail scale. Retain the signature,
/// never the decoded bitmap, between comparisons.
struct CullingMetrics: Sendable {
    static let longEdge = 320
    private static let grid = 8
    private static let minimumAlpha = 0.5

    let width: Int
    let height: Int
    let sharpness: Double?
    let shadowClipFraction: Double
    let highlightClipFraction: Double
    private let signature: [Double]?
    var hasSignature: Bool { signature != nil }

    static func measure(_ image: CGImage) throws -> Self? {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: ImagePipeline.outputSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let cellCount = grid * grid
        var luminance = [Double](repeating: 0, count: width * height)
        var alpha = luminance
        var sums = [Double](repeating: 0, count: cellCount)
        var weights = sums
        var covered = 0.0, shadow = 0.0, highlight = 0.0
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let index = y * width + x, byte = index * 4
                let coverage = Double(pixels[byte + 3]) / 255
                guard coverage > 0 else { continue }
                // Unpremultiply before measuring color. Transparent pixels
                // contribute neither clipping samples nor edge energy.
                let r = Double(pixels[byte]) / coverage, g = Double(pixels[byte + 1]) / coverage
                let b = Double(pixels[byte + 2]) / coverage
                let luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
                alpha[index] = coverage
                luminance[index] = luma
                covered += coverage
                if max(r, g, b) <= 1 { shadow += coverage }
                if max(r, g, b) >= 254 { highlight += coverage }
                let cell = (y * grid / height) * grid + x * grid / width
                sums[cell] += coverage * luma
                weights[cell] += coverage
            }
        }
        guard covered > 0 else { return nil }
        let mean = sums.reduce(0, +) / covered
        let centered = zip(sums, weights).map { sum, weight in weight > 0 ? sum / weight - mean : 0 }
        let norm = sqrt(centered.reduce(0) { $0 + $1 * $1 })
        let populated = weights.filter { $0 > 0 }.count
        // A featureless image cannot serve as evidence of visual similarity.
        let signature = populated >= cellCount / 2 && norm / sqrt(Double(cellCount)) >= 0.01
            ? centered.map { $0 / norm } : nil
        let sharpness = try focus(luminance, alpha: alpha, width: width, height: height)
        return Self(width: width, height: height, sharpness: sharpness, shadowClipFraction: shadow / covered,
                    highlightClipFraction: highlight / covered, signature: signature)
    }

    private static func focus(_ luminance: [Double], alpha: [Double], width: Int, height: Int) throws -> Double? {
        guard width >= grid, height >= grid else { return nil }
        // A high percentile of block Laplacian energy gives a sharp subject
        // more weight than an intentionally defocused background.
        let step = 16
        var blocks: [Double] = []
        for top in stride(from: 1, to: height - 1, by: step) {
            try Task.checkCancellation()
            for left in stride(from: 1, to: width - 1, by: step) {
                var energy = 0.0, count = 0
                for y in top..<min(top + step, height - 1) {
                    for x in left..<min(left + step, width - 1) {
                        let i = y * width + x
                        guard alpha[i] >= minimumAlpha, alpha[i - 1] >= minimumAlpha, alpha[i + 1] >= minimumAlpha,
                              alpha[i - width] >= minimumAlpha, alpha[i + width] >= minimumAlpha else { continue }
                        let laplacian = 4 * luminance[i] - luminance[i - 1] - luminance[i + 1]
                            - luminance[i - width] - luminance[i + width]
                        energy += laplacian * laplacian
                        count += 1
                    }
                }
                if count > 0 { blocks.append(energy / Double(count)) }
            }
        }
        guard !blocks.isEmpty else { return nil }
        blocks.sort()
        let energy = blocks[Int(0.9 * Double(blocks.count - 1))]
        return 100 * (1 - exp(-energy / 0.012))
    }

    func similarity(to other: Self) -> Double? {
        let aspect = Double(width) / Double(height)
        let otherAspect = Double(other.width) / Double(other.height)
        guard min(aspect, otherAspect) / max(aspect, otherAspect) >= 0.8,
              let signature, let target = other.signature else { return nil }
        return min(1, max(0, zip(signature, target).reduce(0) { $0 + $1.0 * $1.1 }))
    }
}
