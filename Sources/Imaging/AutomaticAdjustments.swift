import CoreImage
import Foundation

enum AutomaticAdjustmentKind: Equatable, Sendable {
    case whiteBalance, tone

    var title: String {
        switch self {
        case .whiteBalance: L10n.text("app.autoWhiteBalance", defaultValue: "Auto White Balance")
        case .tone: L10n.text("app.autoTone", defaultValue: "Auto Tone")
        }
    }
}

struct AutomaticTone: Equatable, Sendable {
    var exposure = 0.0, contrast = 1.0
    var highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0

    func apply(to recipe: inout EditRecipe) {
        recipe.exposure = exposure; recipe.contrast = contrast
        recipe.develop.highlights = highlights; recipe.develop.shadows = shadows
        recipe.develop.whites = whites; recipe.develop.blacks = blacks
    }
}

enum AutomaticAdjustmentResult: Equatable, Sendable {
    case whiteBalance(WhiteBalanceValue), tone(AutomaticTone)

    var kind: AutomaticAdjustmentKind {
        switch self { case .whiteBalance: .whiteBalance; case .tone: .tone }
    }
    func apply(to recipe: inout EditRecipe) {
        switch self {
        case let .whiteBalance(value):
            recipe.asShotWhiteBalance = false; recipe.temperature = value.temperature; recipe.tint = value.tint
        case let .tone(value): value.apply(to: &recipe)
        }
    }
}

/// Analysis only: no new rendering operation, response table, or saved recipe format.
/// Float pixels are premultiplied extended-linear sRGB from the native decode prefix.
struct AutomaticAdjustmentPixels {
    let rgba: [Float]

    init(_ rgba: [Float]) { self.rgba = rgba }
    init(image: CIImage, context: CIContext) {
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        rgba = values
    }
    func color(_ index: Int) -> SIMD3<Double>? {
        let alpha = Double(rgba[index * 4 + 3])
        guard alpha.isFinite, alpha >= 0.99 else { return nil }
        let rgb = SIMD3(Double(rgba[index * 4]), Double(rgba[index * 4 + 1]), Double(rgba[index * 4 + 2])) / alpha
        return (0..<3).allSatisfy { rgb[$0].isFinite } ? rgb : nil
    }
    static var insufficient: LRCError {
        LRCError(L10n.text("app.autoAnalysisInsufficient", defaultValue: "Not enough reliable image information for automatic adjustment. Use the manual controls or sample a neutral area."))
    }

    /// Finlayson & Trezzi, Shades of Gray (CIC 2004), p=6. Native safeguards
    /// exclude transparent, near-black and channel-clipped pixels. The selected
    /// positions stay fixed throughout the forward solve; no moving color mask.
    func whiteBalanceIndices() throws -> [Int] {
        guard rgba.count.isMultiple(of: 4) else { throw Self.insufficient }
        let indices = (0..<rgba.count / 4).filter { index in
            guard let c = color(index) else { return false }
            return (0..<3).allSatisfy { c[$0] > 0.0001 && c[$0] < 0.98 }
        }
        guard indices.count >= 64, indices.count * 20 >= rgba.count / 4 else { throw Self.insufficient }
        let estimate = try illuminant(at: indices)
        guard estimate.max() / estimate.min() < 4 else { throw Self.insufficient }
        return indices
    }
    func illuminant(at indices: [Int]) throws -> SIMD3<Double> {
        var sum = SIMD3<Double>.zero
        for (n, index) in indices.enumerated() {
            if n.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard index >= 0, index < rgba.count / 4, let c = color(index) else { throw Self.insufficient }
            // A WB trial can put a few selected, initially positive RAW pixels
            // outside sRGB. The even L6 norm is defined for signed finite RGB;
            // do not move the mask or reject the whole solve for those pixels.
            let squared = c * c
            sum += squared * squared * squared
        }
        guard !indices.isEmpty else { throw Self.insufficient }
        return SIMD3(pow(sum.x / Double(indices.count), 1/6.0), pow(sum.y / Double(indices.count), 1/6.0), pow(sum.z / Double(indices.count), 1/6.0))
    }
    func toneQuantiles() throws -> [Double] {
        guard rgba.count.isMultiple(of: 4) else { throw Self.insufficient }
        var bins = [Int](repeating: 0, count: 2049), count = 0
        for index in 0..<rgba.count / 4 {
            if index.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard let c = color(index) else { continue }
            let linear = max(0, DevelopPipeline.luma(c))
            let encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1/2.4) - 0.055
            bins[Int(min(1, encoded) * 2048)] += 1; count += 1
        }
        guard count >= 64, count * 20 >= rgba.count / 4 else { throw Self.insufficient }
        return [0.01, 0.10, 0.50, 0.90, 0.99].map { percentile in
            let rank = max(1, Int(ceil(Double(count) * percentile)))
            var accumulated = 0
            for (bin, n) in bins.enumerated() { accumulated += n; if accumulated >= rank { return Double(bin) / 2048 } }
            return 1
        }
    }
}

enum AutomaticToneAnalysis {
    /// Own bounded percentile fit, evaluated through our real exposure, spatial
    /// tone and contrast operators. These are starting points, not scene intent
    /// detection or Adobe's Auto algorithm. A repeat analyzes the same prefix.
    static func solve(measure: (AutomaticTone) throws -> [Double]) throws -> AutomaticTone {
        let baseline = try measure(AutomaticTone())
        guard baseline.count == 5, baseline.allSatisfy(\.isFinite), baseline[4] - baseline[0] >= 0.02 else {
            throw AutomaticAdjustmentPixels.insufficient
        }
        var low = -3.0, high = 3.0
        for _ in 0..<10 {
            try Task.checkCancellation()
            let mid = (low + high) / 2
            let q = try measure(AutomaticTone(exposure: mid))
            if q[2] < 0.46 { low = mid } else { high = mid }
        }
        var best = AutomaticTone(exposure: (((low + high) / 2) * 100).rounded() / 100)
        let exposed = try measure(best), desired = [0.015, 0.10, 0.46, 0.88, 0.985]
        let targets = zip(exposed, desired).enumerated().map { index, pair in
            index == 2 ? pair.1 : (pair.0 + pair.1) / 2
        }
        func score(_ value: AutomaticTone) throws -> Double {
            try Task.checkCancellation()
            let q = try measure(value), weights = [1.0, 0.5, 2.0, 0.5, 1.0]
            return zip(zip(q, targets), weights).reduce(0) { $0 + pow($1.0.0 - $1.0.1, 2) * $1.1 }
                + 0.00001 * (pow((value.contrast - 1) * 4, 2) + [value.highlights, value.shadows, value.whites, value.blacks].reduce(0) { $0 + pow($1 / 60, 2) })
        }
        let fields: [(WritableKeyPath<AutomaticTone, Double>, Double, ClosedRange<Double>)] = [
            (\.contrast, 0.12, 0.70...1.35), (\.highlights, 30, -60...60), (\.shadows, 30, -60...60), (\.whites, 20, -60...60), (\.blacks, 20, -60...60)
        ]
        var bestScore = try score(best)
        for scale in [1.0, 0.5, 0.25] {
            for (field, step, range) in fields {
                let origin = best
                for direction in [-1.0, 1.0] {
                    var next = origin
                    next[keyPath: field] = min(range.upperBound, max(range.lowerBound, origin[keyPath: field] + step * direction * scale))
                    let nextScore = try score(next)
                    if nextScore < bestScore { best = next; bestScore = nextScore }
                }
            }
        }
        best.contrast = (best.contrast * 100).rounded() / 100
        for field in [\AutomaticTone.highlights, \.shadows, \.whites, \.blacks] { best[keyPath: field].round() }
        return best
    }
}
