import CoreGraphics
import Combine
import Foundation

/// A single pixel in the displayed sRGB preview. This is a display aid only:
/// it is never written into an edit recipe or passed to export.
struct DisplayPixelSample: Equatable, Sendable {
    let x: Int
    let y: Int
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var rgbText: String {
        "R \(red)  G \(green)  B \(blue)"
    }

    var accessibilityText: String {
        L10n.text("app.pixelAlpha", defaultValue: "Pixel \(x), \(y), \(rgbText), alpha \(alpha)")
    }
}

/// Visibility of the two clipping warnings. Lightroom exposes the two lamps
/// separately even though the warning is one display-only mode; keeping this
/// value independent lets the instrument preserve that distinction without
/// changing the rendered recipe.
struct ClippingVisibility: Equatable, Sendable {
    var shadows = false
    var highlights = false

    var isAnyVisible: Bool { shadows || highlights }

    mutating func toggleShadows() { shadows.toggle() }
    mutating func toggleHighlights() { highlights.toggle() }
}

/// Lifecycle helper for the display-only "hold to inspect" affordance. The
/// owner supplies the model's current persistent visibility and applies the
/// returned value; this object never touches an edit recipe or export state.
@MainActor
final class ClippingPreviewSession: ObservableObject {
    @Published private(set) var preview: ClippingVisibility?
    private var restore: ClippingVisibility?
    private var pulseTask: Task<Void, Never>?

    func begin(current: ClippingVisibility, preview value: ClippingVisibility) {
        pulseTask?.cancel(); pulseTask = nil
        if restore == nil { restore = current }
        preview = value
    }

    func end() -> ClippingVisibility? {
        pulseTask?.cancel(); pulseTask = nil
        let value = restore
        restore = nil; preview = nil
        return value
    }

    func pulse(current: ClippingVisibility, preview value: ClippingVisibility, nanoseconds: UInt64 = 1_200_000_000) {
        begin(current: current, preview: value)
        pulseTask?.cancel()
        pulseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            _ = self?.end()
        }
    }

    /// Call from `didResignKey`, tool/photo changes, and view disappearance.
    func cancel() { _ = end() }
}

/// Readout cache for the displayed sRGB preview. The cache canonicalizes every
/// source (including BGRA, little-endian, float and 16-bit images) once when a
/// readout consumer exists. Mouse moves only index these canonical bytes.
final class DisplayPixelSampler: Sendable {
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private let data: Data

    init(image: CGImage) {
        width = image.width
        height = image.height
        let stride = max(1, image.width) * 4
        bytesPerRow = stride
        let size = stride * max(1, image.height)
        var bytes = Data(count: size)
        let rendered = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: max(1, image.width), height: max(1, image.height),
                                           bitsPerComponent: 8, bytesPerRow: stride,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            // CGContext's canonical bitmap rows match CGImage's top-first
            // provider order here. This also forces color-space conversion and
            // handles BGRA/little-endian/float source layouts.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        data = rendered ? bytes : Data()
    }

    func sample(normalizedX: CGFloat, normalizedY: CGFloat) -> DisplayPixelSample? {
        // The canvas and PhotoViewport use a bottom-left normalized y while
        // this cache is canonicalized to top-left rows.
        sample(topLeftX: normalizedX, y: 1 - normalizedY)
    }

    func sample(topLeftX: CGFloat, y topLeftY: CGFloat) -> DisplayPixelSample? {
        guard width > 0, height > 0, topLeftX.isFinite, topLeftY.isFinite, !data.isEmpty else { return nil }
        let x = min(width - 1, Int(min(1, max(0, topLeftX)) * CGFloat(width)))
        let y = min(height - 1, Int(min(1, max(0, topLeftY)) * CGFloat(height)))
        let offset = y * bytesPerRow + x * 4
        guard offset >= 0, offset + 3 < data.count else { return nil }

        let bytes = data.withUnsafeBytes { raw -> (Int, Int, Int, Int) in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            return (Int(p[offset]), Int(p[offset + 1]), Int(p[offset + 2]), Int(p[offset + 3]))
        }
        let (r, g, b, a) = bytes
        guard a > 0 else {
            return DisplayPixelSample(x: x, y: height - 1 - y, red: 0, green: 0, blue: 0, alpha: 0)
        }
        return DisplayPixelSample(x: x, y: height - 1 - y,
                                  red: UInt8(min(255, (r * 255 + a / 2) / a)),
                                  green: UInt8(min(255, (g * 255 + a / 2) / a)),
                                  blue: UInt8(min(255, (b * 255 + a / 2) / a)), alpha: UInt8(a))
    }
}
