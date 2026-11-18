import ColorSync
import CoreGraphics
import Foundation
import PhosdeckPluginKit

struct PrintProof: PhotoTool {
    let descriptor = ToolDescriptor(key: "soft-proof", name: "Soft Proof", kind: .proof, algorithm: 1)

    func evaluate(_ request: ToolRequest, input: PluginImage, profile: Data?) async throws -> ToolResult {
        guard case .proof(let intent, let gamutWarning) = request.parameters,
              let profile, Self.isOutputProfile(profile),
              let output = ColorSyncProfileCreate(profile as CFData, nil)?.takeRetainedValue(),
              ColorSyncProfileVerify(output, nil, nil),
              let inputSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)?.copyICCData(),
              let linear = ColorSyncProfileCreate(inputSpace, nil)?.takeRetainedValue() else {
            throw PluginFailure.invalidProfile
        }
        let relative = kColorSyncRenderingIntentRelative.takeUnretainedValue()
        let rendering = intent == .relativeColorimetric ? relative : kColorSyncRenderingIntentPerceptual.takeUnretainedValue()
        let intoPCS = kColorSyncTransformDeviceToPCS.takeUnretainedValue()
        let fromPCS = kColorSyncTransformPCSToDevice.takeUnretainedValue()
        let source = Self.step(linear, intoPCS, rendering, bpc: false)
        // BPC applies when mapping the sending RGB to the printer. The return
        // leg uses media-relative colorimetry to display the mapped result.
        let sequence = [source, Self.step(output, fromPCS, rendering, bpc: intent == .relativeColorimetric),
                        Self.step(output, intoPCS, relative, bpc: false), Self.step(linear, fromPCS, relative, bpc: false)]
        guard let proof = ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue(),
              let pixels = try Self.convert(proof, input: input, rgb: true) else {
            throw PluginFailure.invalidProfile
        }
        let gamutCheck = [Self.step(linear, intoPCS, relative, bpc: false),
                          Self.step(output, kColorSyncTransformGamutCheck.takeUnretainedValue(), relative, bpc: false)]
        var mask: Data?
        if gamutWarning, let gamut = ColorSyncTransformCreate(gamutCheck as CFArray, nil)?.takeRetainedValue(),
           let values = try Self.convert(gamut, input: input, rgb: false) {
            var warning = Data(count: input.frame.count)
            // ICC.1:2022 §9.2.29 defines zero as in gamut. Interpolation in
            // ColorSync's floating-point transform can return fractional values.
            let valid = values.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Float.self)
                return warning.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                    for i in samples.indices {
                        guard (0...1).contains(samples[i]) else { return false }
                        bytes[i] = samples[i] > 0 ? 255 : 0
                    }
                    return true
                }
            }
            if valid { mask = warning }
        }
        return .proof(try PluginImage(frame: input.frame, pixels: pixels), gamut: mask)
    }

    private static func isOutputProfile(_ bytes: Data) -> Bool {
        bytes.count >= 132 && bytes[12..<16].elementsEqual("prtr".utf8) &&
            bytes[36..<40].elementsEqual("acsp".utf8)
    }

    private static func step(_ profile: ColorSyncProfile, _ tag: CFString, _ intent: CFString, bpc: Bool) -> [String: Any] {
        [kColorSyncProfile.takeUnretainedValue() as String: profile,
         kColorSyncTransformTag.takeUnretainedValue() as String: tag,
         kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
         kColorSyncBlackPointCompensation.takeUnretainedValue() as String: bpc]
    }

    private static func convert(_ transform: ColorSyncTransform, input: PluginImage, rgb: Bool) throws -> Data? {
        let frame = input.frame
        let stride = rgb ? frame.rowBytes : frame.width * MemoryLayout<Float>.stride
        let layout = rgb ? kColorSyncAlphaLast.rawValue : kColorSyncAlphaNone.rawValue
        var result = Data(count: stride * frame.height)
        let okay = try input.pixels.withUnsafeBytes { src in
            try result.withUnsafeMutableBytes { dst in
                for y in Swift.stride(from: 0, to: frame.height, by: 32) {
                    try Task.checkCancellation()
                    guard ColorSyncTransformConvert(transform, frame.width, min(32, frame.height - y),
                        dst.baseAddress!.advanced(by: y * stride), kColorSync32BitFloat, layout, stride,
                        src.baseAddress!.advanced(by: y * frame.rowBytes), kColorSync32BitFloat,
                        kColorSyncAlphaLast.rawValue, frame.rowBytes, nil) else { return false }
                }
                return true
            }
        }
        return okay ? result : nil
    }
}
