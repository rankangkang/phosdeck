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

/// Sample the materialized frame in sRGB on demand. Rendering a new frame
/// never converts or copies the entire bitmap on the UI thread.
final class DisplayPixelSampler: Sendable {
    private let image: CGImage
    init(image: CGImage) { self.image = image }

    func sample(normalizedX: CGFloat, normalizedY: CGFloat) -> DisplayPixelSample? {
        // The canvas and PhotoViewport use a bottom-left normalized y while
        // this cache is canonicalized to top-left rows.
        sample(topLeftX: normalizedX, y: 1 - normalizedY)
    }

    func sample(topLeftX: CGFloat, y topLeftY: CGFloat) -> DisplayPixelSample? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, topLeftX.isFinite, topLeftY.isFinite else { return nil }
        let x = min(width - 1, Int(min(1, max(0, topLeftX)) * CGFloat(width)))
        let y = min(height - 1, Int(min(1, max(0, topLeftY)) * CGFloat(height)))
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = SIMD4<UInt8>.zero
        let rendered = withUnsafeMutableBytes(of: &rgba) { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: ImagePipeline.outputSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { return nil }
        let (r,g,b,a) = (Int(rgba.x),Int(rgba.y),Int(rgba.z),Int(rgba.w))
        guard a > 0 else {
            return DisplayPixelSample(x: x, y: height - 1 - y, red: 0, green: 0, blue: 0, alpha: 0)
        }
        return DisplayPixelSample(x: x, y: height - 1 - y,
                                  red: UInt8(min(255, (r * 255 + a / 2) / a)),
                                  green: UInt8(min(255, (g * 255 + a / 2) / a)),
                                  blue: UInt8(min(255, (b * 255 + a / 2) / a)), alpha: UInt8(a))
    }
}
