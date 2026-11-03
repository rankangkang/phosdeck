import CoreGraphics
import AppKit
import XCTest
@testable import Phosdeck

final class InspectionWorkflowTests: XCTestCase {
    @MainActor func testNativeCanvasPointerReadsDisplayedSourceAndClearsOnExit() throws {
        let view = PhotoMetalCanvas()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        view.drawableSize = CGSize(width: 400 * window.backingScaleFactor, height: 300 * window.backingScaleFactor)
        let pixels = Data([75, 100, 125, 255])
        view.source = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var sample: DisplayPixelSample?
        view.onPixelReadout = { sample = $0 }; view.readoutEnabled = true
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown,
            location: view.convert(CGPoint(x: 200, y: 150), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.rightMouseDown(with: event)
        XCTAssertEqual(sample, DisplayPixelSample(x: 0, y: 0, red: 75, green: 100, blue: 125, alpha: 255))
        view.mouseExited(with: event)
        XCTAssertNil(sample)
        view.mouseMoved(with: event)
        XCTAssertNotNil(sample)
        view.source = nil
        XCTAssertNil(sample)
    }

    @MainActor
    func testInspectionKeysKeepDirectionLastZoomAndTextFocus() throws {
        let model = AppModel()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        defer { window.contentView = nil }
        func key(_ text: String, _ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        model.singleView = true
        XCTAssertNil(WorkspaceKeyboard.handle(try key("0", 29, flags: [.command, .option]), model: model))
        XCTAssertEqual(model.zoomScale, 1); XCTAssertTrue(model.fullResolution)
        model.viewport.update(image: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 1000, height: 1000), zoomed: true)
        let center = model.viewport.center
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\u{F72D}", 121), model: model))
        XCTAssertLessThan(model.viewport.center.y, center.y, "PageDown 应向照片下部移动")
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\u{F72C}", 116), model: model))
        XCTAssertEqual(model.viewport.center.y, center.y, accuracy: 0.0001)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\u{F72D}", 121, flags: .shift), model: model))
        XCTAssertGreaterThan(model.viewport.center.x, center.x, "Shift+PageDown 应向右移动")

        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        model.image = CIContext().createCGImage(image, from: image.extent)
        model.selectZoom(2); model.selectZoom(nil)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("z", 6), model: model))
        XCTAssertEqual(model.zoomScale, 2); XCTAssertTrue(model.fullResolution, "Z 保留上次倍率")

        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView = editor; window.makeFirstResponder(editor)
        let previous = model.viewport.center
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("0", 29, flags: [.command, .option]), model: model))
        XCTAssertEqual(model.zoomScale, 2)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("\u{F72D}", 121), model: model))
        XCTAssertEqual(model.viewport.center, previous)
    }

    @MainActor
    func testClippingPreviewSessionRestoresOnReleaseAndCancel() {
        let session = ClippingPreviewSession()
        let current = ClippingVisibility(shadows: false, highlights: true)
        let preview = ClippingVisibility(shadows: true, highlights: false)
        session.begin(current: current, preview: preview)
        XCTAssertEqual(session.preview, preview)
        XCTAssertEqual(session.end(), current)
        XCTAssertNil(session.preview)
        session.begin(current: current, preview: preview)
        session.cancel()
        XCTAssertNil(session.preview)
    }

    @MainActor
    func testViewportPanVisibleUsesVisibleFractionAndClamps() {
        let viewport = PhotoViewport()
        viewport.update(image: CGSize(width: 2000, height: 1000), canvas: CGSize(width: 500, height: 500), zoomed: true)
        let start = viewport.center
        viewport.panVisible(horizontal: 1, vertical: 0)
        XCTAssertGreaterThan(viewport.center.x, start.x)
        viewport.panVisible(horizontal: 10, vertical: 10)
        XCTAssertLessThanOrEqual(viewport.center.x, 1 - viewport.visibleFraction.width / 2)
        XCTAssertLessThanOrEqual(viewport.center.y, 1 - viewport.visibleFraction.height / 2)
    }

    func testDisplayPixelSamplerCanonicalizesBGRAAndTransparentPixels() {
        let pixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255
        ]
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let sampler = DisplayPixelSampler(image: image)

        // Normalized y is bottom-left; the provider's first row is top-left.
        let bottomLeft = sampler.sample(normalizedX: 0.25, normalizedY: 0.25)
        XCTAssertEqual(bottomLeft, DisplayPixelSample(x: 0, y: 0, red: 0, green: 0, blue: 255, alpha: 255))
        let topRight = sampler.sample(normalizedX: 0.75, normalizedY: 0.75)
        XCTAssertEqual(topRight, DisplayPixelSample(x: 1, y: 1, red: 0, green: 255, blue: 0, alpha: 255))

        let transparentData = Data([99, 88, 77, 0])
        let transparent = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: CGDataProvider(data: transparentData as CFData)!, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)!
        XCTAssertEqual(DisplayPixelSampler(image: transparent).sample(normalizedX: .nan, normalizedY: .infinity), nil)
        XCTAssertEqual(DisplayPixelSampler(image: transparent).sample(normalizedX: 0.5, normalizedY: 0.5)?.alpha, 0)
        XCTAssertEqual(DisplayPixelSampler(image: transparent).sample(normalizedX: 0.5, normalizedY: 0.5)?.red, 0)

        // Little-endian premultiplied-first memory is BGRA. The sampler must
        // canonicalize it before returning straight sRGB values.
        let bgra = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: CGDataProvider(data: Data([0, 0, 128, 128]) as CFData)!, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        XCTAssertEqual(DisplayPixelSampler(image: bgra).sample(normalizedX: 0.5, normalizedY: 0.5),
                       DisplayPixelSample(x: 0, y: 0, red: 255, green: 0, blue: 0, alpha: 128))

        let sixteen = CGImage(width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64,
                              bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                              provider: CGDataProvider(data: Data([255, 255, 0, 0, 0, 0, 255, 255]) as CFData)!, decode: nil,
                              shouldInterpolate: false, intent: .defaultIntent)!
        XCTAssertEqual(DisplayPixelSampler(image: sixteen).sample(normalizedX: 0.5, normalizedY: 0.5)?.red, 255)
    }

    func testDisplayOverlayCanShowOnlyOneClippingSide() throws {
        try XCTSkipUnless(DisplayOverlay.available, "display overlay metallib unavailable in this test host")
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 1))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let input = black.composited(over: white)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        func render(_ image: CIImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 8)
            context.render(image, toBitmap: &bytes, rowBytes: 8, bounds: CGRect(x: 0, y: 0, width: 2, height: 1), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
            return bytes
        }
        let original = render(input)
        let shadows = render(DisplayOverlay.clipping(input, shadows: true, highlights: false))
        let highlights = render(DisplayOverlay.clipping(input, shadows: false, highlights: true))
        XCTAssertNotEqual(Array(shadows[0..<4]), Array(original[0..<4]))
        XCTAssertEqual(Array(shadows[4..<8]), Array(original[4..<8]))
        XCTAssertEqual(Array(highlights[0..<4]), Array(original[0..<4]))
        XCTAssertNotEqual(Array(highlights[4..<8]), Array(original[4..<8]))
    }
}
