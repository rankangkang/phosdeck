import Foundation
import CoreImage

/// Native residual fringe suppression after system decoding and general denoise.
/// Hue is encoded-sRGB degrees; this is not an Adobe process-value mapping.
struct ManualDefringe: Codable, Equatable, Sendable {
    var version = "native-fringe-v1"
    var purpleAmount = 0.0
    var purpleLower = 260.0
    var purpleUpper = 330.0
    var greenAmount = 0.0
    var greenLower = 80.0
    var greenUpper = 160.0
    var isActive: Bool { purpleAmount > 0 || greenAmount > 0 }

    func validate() throws {
        guard version == "native-fringe-v1",
              [purpleAmount, purpleLower, purpleUpper, greenAmount, greenLower, greenUpper].allSatisfy(\.isFinite),
              (0...100).contains(purpleAmount), (0...100).contains(greenAmount),
              (200...360).contains(purpleLower), (200...360).contains(purpleUpper), purpleUpper - purpleLower >= 10,
              (40...200).contains(greenLower), (40...200).contains(greenUpper), greenUpper - greenLower >= 10 else {
            throw LRCError(L10n.text("defringe.invalid", defaultValue: "Invalid defringe amount or hue range; endpoints must be at least 10° apart"))
        }
    }

    func mixing(_ toward: Self, amount: Double) -> Self {
        var value = self
        for key in [\Self.purpleAmount, \.purpleLower, \.purpleUpper, \.greenAmount, \.greenLower, \.greenUpper] {
            value[keyPath: key] += (toward[keyPath: key] - value[keyPath: key]) * amount
        }
        value.purpleAmount = min(100, max(0, value.purpleAmount))
        value.greenAmount = min(100, max(0, value.greenAmount))
        value.purpleLower = min(350, max(200, value.purpleLower))
        value.purpleUpper = min(360, max(value.purpleLower + 10, value.purpleUpper))
        value.greenLower = min(190, max(40, value.greenLower))
        value.greenUpper = min(200, max(value.greenLower + 10, value.greenUpper))
        return value
    }

    static func sampledHue(_ rgb: SIMD3<Double>, purple: Bool) -> Double? {
        guard (0..<3).allSatisfy({ rgb[$0].isFinite }) else { return nil }
        let encoded = PerceptualColor.encoded(SIMD3(max(0, rgb.x), max(0, rgb.y), max(0, rgb.z)))
        let high = max(encoded.x, max(encoded.y, encoded.z)), low = min(encoded.x, min(encoded.y, encoded.z))
        let hsl = DevelopPipeline.hsl(encoded)
        guard high > 0, (high - low) / high >= 0.05, (purple ? 200...360 : 40...200).contains(hsl.x) else { return nil }
        return hsl.x
    }

    mutating func setSample(_ hue: Double, purple: Bool) {
        let domain: ClosedRange<Double> = purple ? 200...360 : 40...200
        let lower = min(domain.upperBound - 30, max(domain.lowerBound, hue - 15))
        if purple { purpleLower = lower; purpleUpper = lower + 30 }
        else { greenLower = lower; greenUpper = lower + 30 }
    }
}

extension EditRecipe {
    /// An absent optional operation is the neutral state, including saved recipes.
    var manualDefringe: ManualDefringe {
        get { defringe ?? ManualDefringe() }
        set { defringe = newValue == ManualDefringe() ? nil : newValue }
    }
}

enum ManualDefringePipeline {
    private final class Resources {}
    private static let kernel: Result<CIKernel, Error> = Result {
        guard let url = Bundle(for: Resources.self).url(forResource: "default", withExtension: "metallib") else {
            throw LRCError(L10n.text("defringe.shadersMissing", defaultValue: "Develop shaders missing"))
        }
        return try CIKernel(functionName: "manualDefringe", fromMetalLibraryData: Data(contentsOf: url), outputPixelFormat: .RGBAf)
    }

    static func apply(_ input: CIImage, _ settings: ManualDefringe, sourceSize: CGSize) throws -> CIImage {
        try settings.validate()
        guard settings.isActive else { return input }
        try Task.checkCancellation()
        // Bounded opposite-side tests at three scales. Tiny images retain a
        // proportionally small footprint; full photographs cap at 12 source px.
        // Drafts keep a one-pixel minimum; judge fine fringes at 100%.
        let sourceRadius = min(12, min(sourceSize.width, sourceSize.height) * 0.05)
        let radius = max(1, sourceRadius * min(input.extent.width / max(1, sourceSize.width), input.extent.height / max(1, sourceSize.height)))
        let extent = input.extent
        guard let output = try kernel.get().apply(extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -ceil(radius), dy: -ceil(radius)).intersection(extent) },
            arguments: [input, CIVector(cgRect: extent),
                        CIVector(x: settings.purpleLower, y: settings.purpleUpper, z: settings.purpleAmount / 100, w: 0),
                        CIVector(x: settings.greenLower, y: settings.greenUpper, z: settings.greenAmount / 100, w: 0), radius]) else {
            throw LRCError(L10n.text("defringe.renderFailed", defaultValue: "Manual defringe rendering failed"))
        }
        return output
    }
}
