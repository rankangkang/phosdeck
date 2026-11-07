import CoreGraphics

/// Display-referred RGB histogram of the current rendered preview, not sensor RAW values.
struct ImageHistogram {
    let channels: [[Double]]
    static func calculate(_ image: CGImage) -> Self? {
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)); return true
        }
        guard rendered else { return nil }
        var values = Array(repeating: [Double](repeating: 0, count: 256), count: 3)
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[pixel+3])
            if alpha == 0 { continue }
            // Covered color contributes in proportion to its visible area;
            // transparent black is not a photographic shadow sample.
            for channel in 0..<3 {
                let value = min(255,(Int(pixels[pixel+channel])*255+alpha/2)/alpha)
                values[channel][value] += Double(alpha)/255
            }
        }
        return Self(channels: values)
    }
}

/// Public Lightroom interaction zones; parameter response remains native.
enum HistogramRegion: Int, CaseIterable {
    case blacks, shadows, exposure, highlights, whites
    static let boundaries: [Double] = [0, 0.1, 0.3, 0.7, 0.9, 1]
    var fractions: ClosedRange<Double> { Self.boundaries[rawValue]...Self.boundaries[rawValue + 1] }
    static func at(_ x: Double) -> Self {
        guard x.isFinite else { return .exposure }
        return allCases.last(where: { x >= $0.fractions.lowerBound }) ?? .blacks
    }
    var title: String {
        switch self {
        case .blacks: L10n.text("app.blacks", defaultValue: "Blacks")
        case .shadows: L10n.text("app.shadows", defaultValue: "Shadows")
        case .exposure: L10n.text("app.exposure", defaultValue: "Exposure")
        case .highlights: L10n.text("app.highlights", defaultValue: "Highlights")
        case .whites: L10n.text("app.whites", defaultValue: "Whites")
        }
    }
    var range: ClosedRange<Double> { self == .exposure ? -5...5 : -100...100 }
    var step: Double { self == .exposure ? 0.01 : 1 }
    func value(in recipe: EditRecipe) -> Double {
        switch self {
        case .blacks: recipe.develop.blacks
        case .shadows: recipe.develop.shadows
        case .exposure: recipe.exposure
        case .highlights: recipe.develop.highlights
        case .whites: recipe.develop.whites
        }
    }
    func set(_ value: Double, in recipe: inout EditRecipe) {
        switch self {
        case .blacks: recipe.develop.blacks = value
        case .shadows: recipe.develop.shadows = value
        case .exposure: recipe.exposure = value
        case .highlights: recipe.develop.highlights = value
        case .whites: recipe.develop.whites = value
        }
    }
}
