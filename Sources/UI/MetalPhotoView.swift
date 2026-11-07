import SwiftUI
import MetalKit
import CoreImage
import os

struct MetalPhotoView: NSViewRepresentable {
    @ObservedObject var viewport: PhotoViewport
    let image: CGImage?
    let actualPixels: Bool
    var photoID: String?
    var nativeSize: CGSize?
    var backdrop = 0.13
    var zoomScale = 1.0
    var fill = false
    var cropAngle: Double?
    var onClick: ((CGPoint) -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var accessibilityName = L10n.text("app.photoCanvas", defaultValue: "Photo Canvas")
    var targetedToolID: String?
    var onTargetBegin: ((CGPoint) -> Bool)?
    var onTargetChange: ((Double) -> Void)?
    var onTargetEnd: ((Bool) -> Void)?
    var onTargetNudge: ((Double) -> Bool)?
    var onTargetExit: (() -> Void)?
    var onZoneSample: ((CGPoint) -> Void)?
    var maskEditing: MaskCanvasEditing?
    var onMaskPointer: ((CGPoint, MaskPointerPhase, NSEvent.ModifierFlags, MaskEditGesture.Action?) -> Void)?
    var onMaskError: ((String) -> Void)?
    var spotEditing: SpotCanvasEditing?
    var onSpotPointer: ((CGPoint, MaskPointerPhase, Double) -> Void)?
    var spotDraft: (() -> SpotCanvasDraft?)? = nil
    var clipping = false
    /// Optional independent warning lamps. When nil, `clipping` keeps the
    /// existing all-or-nothing behavior for older callers.
    var clipShadows: Bool? = nil
    var clipHighlights: Bool? = nil
    var onPixelReadout: ((DisplayPixelSample?) -> Void)? = nil
    /// Drawn left of the split line, scaled onto `image`; both must share geometry.
    var splitBefore: CGImage?
    func makeNSView(context: Context) -> PhotoMetalCanvas { PhotoMetalCanvas() }
    func updateNSView(_ view: PhotoMetalCanvas, context: Context) {
        let maskChanged = view.maskEditing != maskEditing
        let coverageChanged = !(view.maskEditing?.hasSameCoverage(as: maskEditing) ?? (maskEditing == nil))
        let spotChanged = view.spotEditing != spotEditing
        let nextShadows = clipShadows ?? clipping
        let nextHighlights = clipHighlights ?? clipping
        // A split canvas contains two sources. Until the callback is made
        // pane-aware, disable the readout rather than reporting the After
        // source while the pointer is over the Before half.
        let nextReadoutEnabled = onPixelReadout != nil && splitBefore == nil
        let targetChanged = view.targetedToolID != targetedToolID
        let cursorChanged = targetChanged || (view.source == nil) != (image == nil) || view.actualPixels != actualPixels || view.fill != fill || view.cropAngle != cropAngle ||
            (view.onZoneSample == nil) != (onZoneSample == nil) || (view.maskEditing == nil) != (maskEditing == nil) || (view.spotEditing == nil) != (spotEditing == nil)
        let changed = maskChanged || spotChanged || view.source !== image || view.actualPixels != actualPixels || view.photoID != photoID || view.nativeSize != nativeSize || view.backdrop != backdrop || view.displayCenter != viewport.center || view.zoomScale != zoomScale || view.fill != fill || view.cropAngle != cropAngle
            || view.clipShadows != nextShadows || view.clipHighlights != nextHighlights || view.readoutEnabled != nextReadoutEnabled || view.splitSource !== splitBefore
        view.clipShadows = nextShadows; view.clipHighlights = nextHighlights; view.splitSource = splitBefore
        let zoomChanged = view.actualPixels != actualPixels || view.zoomScale != zoomScale || view.fill != fill
        let resetMotion = view.photoID != photoID || view.cropAngle != cropAngle || image == nil
        if resetMotion || targetChanged || zoomChanged { view.cancelTargetGesture() }
        view.targetedToolID = targetedToolID
        view.onTargetBegin = onTargetBegin; view.onTargetChange = onTargetChange; view.onTargetEnd = onTargetEnd
        view.onTargetNudge = onTargetNudge; view.onTargetExit = onTargetExit
        view.setAccessibilityCustomActions(targetedToolID == nil ? [] : [
            NSAccessibilityCustomAction(name: L10n.text("app.increaseTargetedAdjustment", defaultValue: "Increase Targeted Adjustment")) { [weak view] in view?.onTargetNudge?(1) ?? false },
            NSAccessibilityCustomAction(name: L10n.text("app.decreaseTargetedAdjustment", defaultValue: "Decrease Targeted Adjustment")) { [weak view] in view?.onTargetNudge?(-1) ?? false }
        ])
        view.photoID = photoID; view.nativeSize = nativeSize; view.backdrop = backdrop
        view.actualPixels = actualPixels
        view.zoomScale = zoomScale; view.fill = fill; view.cropAngle = cropAngle; view.onClick = onClick
        view.onPan = onPan; view.setAccessibilityLabel(accessibilityName)
        view.onPixelReadout = onPixelReadout
        view.readoutEnabled = nextReadoutEnabled
        view.source = image
        view.onZoneSample = onZoneSample
        if cursorChanged { view.window?.invalidateCursorRects(for: view) }
        view.viewport = viewport; view.displayCenter = viewport.center
        view.updateZoomMotion(animate: zoomChanged, reset: resetMotion)
        view.maskEditing = maskEditing; view.onMaskPointer = onMaskPointer; view.onMaskError = onMaskError
        view.spotEditing = spotEditing; view.onSpotPointer = onSpotPointer; view.spotDraft = spotDraft
        if let hold = view.spotHold, view.spotOverlayAbsorbed(hold) { view.spotHold = nil }
        if coverageChanged { view.rebuildMaskOverlay() }
        view.scheduleViewportUpdate()
        if changed {
            PreviewLog.logger.debug("canvas-update")
            // MTKView is paused: submit the new frame now. AppKit may defer
            // a needsDisplay-only update during continuous input.
            view.draw()
        }
    }
}

// The worker only reads immutable image snapshots; view geometry and guide layers stay on MainActor.
final class CanvasFrameRenderer: @unchecked Sendable {
    private struct Frame: @unchecked Sendable {
        let image: CIImage
        let bounds: CGRect
        let layer: CAMetalLayer
        var generation: UInt64
        let attempt: Int
        let queued: CFTimeInterval
    }
    private struct State {
        var pending: Frame?
        var running = false
        var generation: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let worker = DispatchQueue(label: "dev.cmkk.phosdeck.canvas", qos: .userInteractive)
    private let commands: MTLCommandQueue
    private let ci: CIContext
    private let acquire: @Sendable (CAMetalLayer) -> CAMetalDrawable?
    init(commands: MTLCommandQueue, acquire: @escaping @Sendable (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }) {
        self.commands = commands; self.acquire = acquire
        ci = CIContext(mtlDevice: commands.device, options: [.workingFormat: CIFormat.RGBAf])
    }
    var isIdle: Bool { state.withLock { !$0.running } }
    func invalidate() { state.withLock { $0.generation &+= 1; $0.pending = nil } }
    func submit(_ image: CIImage, bounds: CGRect, layer: CAMetalLayer, attempt: Int) {
        let snapshot = Frame(image: image, bounds: bounds, layer: layer, generation: 0, attempt: attempt, queued: CACurrentMediaTime())
        let start = state.withLock { state in
            var frame = snapshot; frame.generation = state.generation
            state.pending = frame
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if start { worker.async { [weak self] in self?.next() } }
    }
    private func requeue(_ frame: Frame) {
        state.withLock { if $0.generation == frame.generation, $0.pending == nil { $0.pending = frame } }
    }
    private func next() {
        let frame = state.withLock { state -> Frame? in
            guard let next = state.pending else { state.running = false; return nil }
            state.pending = nil
            return next
        }
        guard let frame else { return }
        let delay = autoreleasepool { render(frame) }
        worker.asyncAfter(deadline: .now() + delay) { [weak self] in self?.next() }
    }
    private func render(_ frame: Frame) -> TimeInterval {
        let started = CACurrentMediaTime()
        PreviewLog.logger.debug("drawable-acquire-begin attempt=\(frame.attempt) queue-ms=\((started - frame.queued) * 1000)")
        let drawable = acquire(frame.layer)
        PreviewLog.logger.debug("drawable-acquired attempt=\(frame.attempt) ms=\((CACurrentMediaTime() - started) * 1000) available=\(drawable != nil)")
        guard let drawable else { requeue(frame); return 0.1 }
        let current = state.withLock { state -> Frame? in
            guard frame.generation == state.generation else { return nil }
            let latest = state.pending ?? frame
            state.pending = nil
            return latest
        }
        guard let current else { return 0 }
        guard current.layer === frame.layer, abs(CGFloat(drawable.texture.width) - current.bounds.width) < 1,
              abs(CGFloat(drawable.texture.height) - current.bounds.height) < 1 else {
            requeue(current); return 0.016
        }
        guard let command = commands.makeCommandBuffer() else {
            PreviewLog.logger.error("canvas command buffer unavailable")
            return 0
        }
        let encoding = CACurrentMediaTime()
        ci.render(current.image, to: drawable.texture, commandBuffer: command, bounds: current.bounds, colorSpace: ImagePipeline.outputSpace)
        PreviewLog.logger.debug("encode-done attempt=\(current.attempt) ms=\((CACurrentMediaTime() - encoding) * 1000)")
        guard state.withLock({ $0.generation == current.generation }) else { return 0 }
        let submitted = CACurrentMediaTime(), frameID = drawable.drawableID
        PreviewLog.logger.debug("draw-submit frame=\(frameID)")
        command.addCompletedHandler { buffer in
            PreviewLog.logger.debug("gpu-complete frame=\(frameID) ms=\((CACurrentMediaTime() - submitted) * 1000) status=\(buffer.status.rawValue)")
        }
        drawable.addPresentedHandler { frame in
            PreviewLog.logger.debug("frame-presented frame=\(frameID) display-ms=\(frame.presentedTime > 0 ? (frame.presentedTime - submitted) * 1000 : -1) callback-ms=\((CACurrentMediaTime() - submitted) * 1000)")
        }
        command.present(drawable); command.commit()
        return 0
    }
}

final class PhotoMetalCanvas: MTKView, MTKViewDelegate {
    var source: CGImage? {
        didSet {
            if oldValue !== source {
                if oldValue == nil || source == nil || oldValue?.width != source?.width || oldValue?.height != source?.height { renderer?.invalidate() }
                sourceImage = source.map { CIImage(cgImage: $0) }
                pixelSampler = source.flatMap { readoutEnabled ? DisplayPixelSampler(image: $0) : nil }
                if source == nil { onPixelReadout?(nil) }
            }
        }
    }
    private var sourceImage: CIImage?
    var splitSource: CGImage? {
        didSet {
            if oldValue !== splitSource { splitImage = splitSource.map { CIImage(cgImage: $0) } }
        }
    }
    private var splitImage: CIImage?
    var clipShadows = false
    var clipHighlights = false
    var clipping: Bool {
        get { clipShadows || clipHighlights }
        set { clipShadows = newValue; clipHighlights = newValue }
    }
    private let splitLine = CAShapeLayer()
    var maskEditing: MaskCanvasEditing? {
        didSet { if maskEditing == nil, oldValue != nil {
            maskTracking = false; activeMaskAction = nil; pressPoint = nil; lastDragPoint = nil
            brushCursor.path = nil; pointerHint.isHidden = true; handleHighlight.path = nil
        } }
    }
    var onMaskPointer: ((CGPoint, MaskPointerPhase, NSEvent.ModifierFlags, MaskEditGesture.Action?) -> Void)?
    var onMaskError: ((String) -> Void)?
    var spotEditing: SpotCanvasEditing? {
        didSet { if spotEditing == nil {
            if oldValue != nil { spotTracking = false; pressPoint = nil; lastDragPoint = nil }
            brushCursor.path = nil; clearSpotOverlay(); spotHoverID = nil; spotAdjusting = false; spotHold = nil
        } }
    }
    var onSpotPointer: ((CGPoint, MaskPointerPhase, Double) -> Void)?
    var spotDraft: (() -> SpotCanvasDraft?)?
    /// Keeps the outline on the last gesture until SwiftUI has the committed repair.
    var spotHold: SpotCanvasDraft?
    private let spotGuideLayer = CAShapeLayer()
    private let spotSourceLayer = CAShapeLayer()
    private var spotMarkerLayers: [CAShapeLayer] = []
    private var spotOutlineID: UUID?
    private var spotOutlineCount = 0
    private var spotOutlineRadius: CGFloat = -1
    private var spotOutlineFirst = CGPoint.zero
    private var spotOutlineLast = CGPoint.zero
    private var spotOutline = SpotOutline(loops: [])
    private static let spotMarkerColors: [CGColor] = [
        NSColor(srgbRed: 0.22, green: 0.48, blue: 0.98, alpha: 1).cgColor,
        NSColor(srgbRed: 0.98, green: 0.62, blue: 0.12, alpha: 1).cgColor,
        NSColor(srgbRed: 0.18, green: 0.78, blue: 0.45, alpha: 1).cgColor,
        NSColor(srgbRed: 0.62, green: 0.36, blue: 0.96, alpha: 1).cgColor,
        NSColor(srgbRed: 0.96, green: 0.28, blue: 0.38, alpha: 1).cgColor,
        NSColor(srgbRed: 0.20, green: 0.74, blue: 0.86, alpha: 1).cgColor
    ]
    private var maskCoverage: CIImage?
    private let maskHandles = CAShapeLayer()
    private let brushCursor = CAShapeLayer()
    private let handleHighlight = CAShapeLayer()
    private let pointerHint = CATextLayer()
    private var activeMaskAction: MaskEditGesture.Action?
    private static let rotateCursor = NSCursor(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.text("app.rotate", defaultValue: "Rotate"))!, hotSpot: NSPoint(x: 8, y: 8))
    private var pointerArea: NSTrackingArea?
    private var maskTracking = false
    private(set) var targetTracking = false
    private var targetPointerY = 0.0
    private var targetDelta = 0.0
    private var spotTracking = false
    private var spotAdjusting = false
    private var spotHoverID: UUID?
    private var spaceHeld = false
    var actualPixels = false
    var photoID: String? { didSet { if oldValue != photoID { renderer?.invalidate() } } }
    var nativeSize: CGSize? { didSet { if oldValue != nativeSize { renderer?.invalidate() } } }
    var backdrop = 0.13
    var zoomScale = 1.0
    var fill = false
    var cropAngle: Double? { didSet { if oldValue != cropAngle { renderer?.invalidate() } } }
    var onClick: ((CGPoint) -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var targetedToolID: String?
    var onTargetBegin: ((CGPoint) -> Bool)?
    var onTargetChange: ((Double) -> Void)?
    var onTargetEnd: ((Bool) -> Void)?
    var onTargetNudge: ((Double) -> Bool)?
    var onTargetExit: (() -> Void)?
    var onZoneSample: ((CGPoint) -> Void)?
    var onPixelReadout: ((DisplayPixelSample?) -> Void)?
    private var pixelSampler: DisplayPixelSampler?
    var readoutEnabled = false {
        didSet {
            if !readoutEnabled {
                pixelSampler = nil
                onPixelReadout?(nil)
            } else if oldValue != readoutEnabled, let source {
                pixelSampler = DisplayPixelSampler(image: source)
            }
        }
    }
    private var pressPoint: CGPoint?
    private var lastDragPoint: CGPoint?
    private var dragged = false
    private var canPan: Bool { cropAngle == nil && (actualPixels || fill) }
    var displayCenter = CGPoint(x: 0.5, y: 0.5)
    var viewport: PhotoViewport?
    private var geometryUpdatePending = false
    private var zoomMotion: CanvasZoomMotion?
    private var zoomFrameCount = 0
    private var lastImageRect: CGRect?

    private func targetImageRect() -> CGRect? {
        guard let source, cropAngle == nil, drawableSize.width > 0, drawableSize.height > 0 else { return nil }
        let size = presentationSize(source: source, canvas: drawableSize)
        let center = PhotoViewport.clamp(canPan ? displayCenter : CGPoint(x: 0.5, y: 0.5),
                                         fraction: PhotoViewport.fraction(image: size, canvas: drawableSize))
        return CGRect(x: drawableSize.width / 2 - center.x * size.width,
                      y: drawableSize.height / 2 - (1 - center.y) * size.height, width: size.width, height: size.height)
    }
    func updateZoomMotion(animate: Bool, reset: Bool = false) {
        guard !reset, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let target = targetImageRect() else {
            zoomMotion = nil; lastImageRect = nil; isPaused = true; enableSetNeedsDisplay = true; return
        }
        // Retarget from the currently visible frame, including rapid Z / ratio changes.
        if (animate || zoomMotion != nil), let previous = zoomMotion?.rect(at: CACurrentMediaTime()) ?? lastImageRect,
           zoomMotion?.to != target, previous != target {
            zoomMotion = CanvasZoomMotion(from: previous, to: target, start: CACurrentMediaTime())
            zoomFrameCount = 0
            preferredFramesPerSecond = 60; enableSetNeedsDisplay = false; isPaused = false
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(targetWindowLost), name: NSWindow.didResignKeyNotification, object: window)
        } else { cancelTargetGesture() }
        if window == nil { renderer?.invalidate(); zoomMotion = nil; lastImageRect = nil; isPaused = true; enableSetNeedsDisplay = true }
    }
    @objc private func targetWindowLost() { cancelTargetGesture() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { cancelTargetGesture() }
        super.setFrameSize(newSize)
    }
    func cancelTargetGesture() {
        guard targetTracking else { return }
        targetTracking = false; onTargetEnd?(true); pressPoint = nil; lastDragPoint = nil
    }
    private var renderer: CanvasFrameRenderer?
    private var drawAttempt = 0
    init(acquireDrawable: @escaping @Sendable (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: .zero, device: device)
        framebufferOnly = false; isPaused = true; enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        layer?.masksToBounds = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        (layer as? CAMetalLayer)?.presentsWithTransaction = false
        if let commands = device?.makeCommandQueue() { renderer = CanvasFrameRenderer(commands: commands, acquire: acquireDrawable) }
        delegate = self
        maskHandles.strokeColor = NSColor.white.cgColor; maskHandles.fillColor = nil; maskHandles.lineWidth = 1.5
        maskHandles.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        maskHandles.shadowColor = NSColor.black.cgColor; maskHandles.shadowOpacity = 1
        maskHandles.shadowRadius = 1; maskHandles.shadowOffset = .zero
        layer?.addSublayer(maskHandles)
        handleHighlight.fillColor = NSColor.controlAccentColor.cgColor; handleHighlight.strokeColor = NSColor.white.cgColor
        handleHighlight.lineWidth = 2; handleHighlight.actions = ["path": NSNull()]
        layer?.addSublayer(handleHighlight)
        pointerHint.fontSize = 12; pointerHint.alignmentMode = .center; pointerHint.cornerRadius = 4
        pointerHint.foregroundColor = NSColor.white.cgColor; pointerHint.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
        pointerHint.contentsScale = NSScreen.main?.backingScaleFactor ?? 2; pointerHint.isHidden = true
        pointerHint.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(pointerHint)
        brushCursor.strokeColor = NSColor.white.cgColor; brushCursor.fillColor = nil; brushCursor.lineWidth = 1
        brushCursor.shadowColor = NSColor.black.cgColor; brushCursor.shadowOpacity = 1; brushCursor.shadowRadius = 1
        brushCursor.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(brushCursor)
        spotGuideLayer.strokeColor = NSColor.white.cgColor
        spotGuideLayer.fillColor = nil
        spotGuideLayer.lineWidth = 1
        spotGuideLayer.lineCap = .round
        spotGuideLayer.lineJoin = .round
        spotGuideLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        spotGuideLayer.shadowColor = NSColor.black.cgColor
        spotGuideLayer.shadowOpacity = 1
        spotGuideLayer.shadowRadius = 0.5
        spotGuideLayer.shadowOffset = .zero
        spotGuideLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(spotGuideLayer)
        spotSourceLayer.strokeColor = NSColor.white.cgColor
        spotSourceLayer.fillColor = nil
        spotSourceLayer.lineWidth = 1
        spotSourceLayer.lineCap = .round
        spotSourceLayer.lineJoin = .round
        spotSourceLayer.lineDashPattern = [NSNumber(value: 6), NSNumber(value: 4)]
        spotSourceLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        spotSourceLayer.shadowColor = NSColor.black.cgColor
        spotSourceLayer.shadowOpacity = 1
        spotSourceLayer.shadowRadius = 0.5
        spotSourceLayer.shadowOffset = .zero
        spotSourceLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "lineDashPattern": NSNull()]
        layer?.addSublayer(spotSourceLayer)
        splitLine.strokeColor = NSColor.white.cgColor; splitLine.lineWidth = 1
        splitLine.shadowColor = NSColor.black.cgColor; splitLine.shadowOpacity = 1; splitLine.shadowRadius = 1; splitLine.shadowOffset = .zero
        splitLine.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(splitLine)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.text("app.photoCanvas", defaultValue: "Photo Canvas"))
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.invalidate()
        updateZoomMotion(animate: false)
        scheduleViewportUpdate()
        needsDisplay = true
    }
    func scheduleViewportUpdate() {
        guard !geometryUpdatePending else { return }
        geometryUpdatePending = true
        // SwiftUI's representable update must not publish observable changes synchronously.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdatePending = false
            guard let source = self.source, self.drawableSize.width > 0, self.drawableSize.height > 0 else { return }
            let size = self.presentationSize(source: source, canvas: self.drawableSize)
            self.viewport?.update(image: size, canvas: self.drawableSize, zoomed: self.canPan)
        }
    }
    func draw(in view: MTKView) {
        drawAttempt += 1
        let attempt = drawAttempt
        let started = CACurrentMediaTime()
        PreviewLog.logger.debug("draw-begin attempt=\(attempt)")
        guard let renderer, let layer = layer as? CAMetalLayer, drawableSize.width > 0, drawableSize.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: drawableSize)
        var composition = CIImage(color: CIColor(red: backdrop, green: backdrop, blue: backdrop)).cropped(to: bounds)
        splitLine.path = nil
        if sourceImage == nil { clearSpotOverlay() }
        if let input = sourceImage {
            let translated: CIImage
            if let angle = cropAngle {
                clearSpotOverlay()
                let turned = input.transformed(by: CropPreviewGeometry.transform(size: input.extent.size, degrees: angle))
                let extent = turned.extent
                let scale = min(drawableSize.width / extent.width, drawableSize.height / extent.height)
                translated = turned.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: (drawableSize.width - extent.width * scale) / 2,
                                                     y: (drawableSize.height - extent.height * scale) / 2))
            } else {
                let now = CACurrentMediaTime()
                let rect = zoomMotion?.rect(at: now) ?? targetImageRect() ?? .zero
                lastImageRect = rect
                if zoomMotion != nil { zoomFrameCount += 1 }
                if let motion = zoomMotion, now >= motion.start + motion.duration {
                    PreviewLog.logger.info("zoom-transition-complete frames=\(self.zoomFrameCount) elapsed-ms=\((now - motion.start) * 1000)")
                    zoomMotion = nil; isPaused = true; enableSetNeedsDisplay = true
                }
                var presented = (clipShadows || clipHighlights)
                    ? DisplayOverlay.clipping(input, shadows: clipShadows, highlights: clipHighlights) : input
                var splitX: CGFloat?
                if let before = splitImage, rect.width > 0 {
                    // The split follows the canvas centre so it stays visible while zoomed.
                    let x = min(rect.maxX, max(rect.minX, drawableSize.width / 2))
                    let cut = (x - rect.minX) / rect.width * input.extent.width
                    let fitted = ((clipShadows || clipHighlights)
                        ? DisplayOverlay.clipping(before, shadows: clipShadows, highlights: clipHighlights) : before)
                        .transformed(by: CGAffineTransform(scaleX: input.extent.width / before.extent.width, y: input.extent.height / before.extent.height))
                    presented = fitted.cropped(to: CGRect(x: 0, y: 0, width: cut, height: input.extent.height)).composited(over: presented)
                    splitX = x
                }
                if let coverage = maskCoverage, let edit = maskEditing {
                    let fitted = Self.fitted(coverage, to: input.extent)
                    presented = DisplayOverlay.maskView(presented, coverage: fitted, style: edit.style, tint: DisplayOverlay.maskTint(edit.color))
                }
                updateMaskHandles(rect: rect)
                updateSpotGuides(rect: rect)
                updateSplitLine(x: splitX, rect: rect)
                translated = presented.transformed(by: CGAffineTransform(scaleX: rect.width / input.extent.width,
                                                                      y: rect.height / input.extent.height))
                    .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                    .cropped(to: rect)
            }
            composition = translated.composited(over: composition).cropped(to: bounds)
        }
        let composed = CACurrentMediaTime()
        PreviewLog.logger.debug("composition-built attempt=\(attempt) ms=\((composed - started) * 1000)")
        renderer.submit(composition, bounds: bounds, layer: layer, attempt: attempt)
    }
    func presentationSize(source: CGImage, canvas: CGSize) -> CGSize {
        let size = nativeSize ?? CGSize(width: source.width, height: source.height)
        let scale = actualPixels ? zoomScale : fill
            ? max(canvas.width / size.width, canvas.height / size.height)
            : min(canvas.width / size.width, canvas.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    override func resetCursorRects() {
        guard cropAngle == nil, source != nil else { return }
        if (onZoneSample != nil || targetedToolID != nil) && !spaceHeld { addCursorRect(bounds, cursor: .crosshair); return }
        if (maskEditing == nil && spotEditing == nil && targetedToolID == nil) || spaceHeld { addCursorRect(bounds, cursor: canPan ? .openHand : .zoomIn) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); pointerArea = area
    }
    override func mouseMoved(with event: NSEvent) { updatePixelReadout(event); updateMaskPointer(event); updateSpotCursor(event); updateBrushCursor(event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func cursorUpdate(with event: NSEvent) { updatePixelReadout(event); updateMaskPointer(event); updateSpotCursor(event) }
    override func rightMouseDown(with event: NSEvent) { updatePixelReadout(event); super.rightMouseDown(with: event) }
    override func flagsChanged(with event: NSEvent) { updateMaskPointer(event); updateSpotCursor(event); updateBrushCursor(event); super.flagsChanged(with: event) }
    override func mouseExited(with event: NSEvent) {
        onPixelReadout?(nil)
        brushCursor.path = nil; pointerHint.isHidden = true; handleHighlight.path = nil
        setSpotHover(nil)
        NSCursor.arrow.set()
    }
    private func maskAction(at event: NSEvent) -> MaskEditGesture.Action? {
        guard let edit = maskEditing, let c = edit.component, c.enabled,
              let rect = targetImageRect(), let point = MaskGeometry.sourcePoint(maskOutputPoint(event), size: edit.sourceSize, recipe: edit.recipe, allowOutside: c.tool.isGradient) else { return nil }
        if edit.awaitingDraw || c.tool == .brush { return .draw }
        guard edit.showGuides else { return nil }
        let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
        let tolerance = 11 * (window?.backingScaleFactor ?? 1) * mapping.output.width / rect.width
        if !edit.recipe.perspective.isNeutral {
            let position = convert(event.locationInWindow, from: nil), backing = window?.backingScaleFactor ?? 1
            let transform = mapping.transform.concatenating(CGAffineTransform(scaleX: rect.width/mapping.output.width/backing, y: rect.height/mapping.output.height/backing))
                .concatenating(CGAffineTransform(translationX: rect.minX/backing, y: rect.minY/backing))
            let handles = MaskEditGesture.handles(c, size: edit.sourceSize, rotationOffset: tolerance*36/11)
            if let nearest = handles.compactMap({ h -> (MaskEditGesture.Action, Double)? in
                guard let q = transform.point(CGPoint(x: h.point.x*edit.sourceSize.width, y: h.point.y*edit.sourceSize.height)) else { return nil }
                return (h.action, hypot(q.x-position.x, q.y-position.y))
            }).filter({ $0.1 <= 11 }).min(by: { $0.1 < $1.1 }) { return nearest.0 }
        }
        return MaskEditGesture.hit(point, component: c, size: edit.sourceSize, tolerance: tolerance, rotationOffset: tolerance * 36 / 11)
    }
    private func updateMaskPointer(_ event: NSEvent) {
        pointerHint.isHidden = true; handleHighlight.path = nil; toolTip = nil
        guard let edit = maskEditing, let c = edit.component, c.enabled, !spaceHeld else { if maskEditing != nil { (spaceHeld && canPan ? NSCursor.openHand : NSCursor.arrow).set() }; return }
        let action = maskTracking ? activeMaskAction : maskAction(at: event)
        var label = "", cursor = NSCursor.arrow
        switch action {
        case .draw: label = c.tool == .brush ? (edit.brushErase || event.modifierFlags.contains(.option) ? L10n.text("app.eraseBrush", defaultValue: "Erase Brush") : L10n.text("app.paintBrush", defaultValue: "Paint Brush")) : c.tool == .object ? (edit.smartInstruction ?? L10n.text("app.smartSelectionSaved", defaultValue: "Smart Selection Saved")) : L10n.text("app.dragToCreateSelection", defaultValue: "Drag to Create Selection"); cursor = edit.smartAllowsPointer ? .crosshair : .arrow
        case .move: label = L10n.text("app.moveSelection", defaultValue: "Move Selection"); cursor = maskTracking ? .closedHand : .openHand
        case .start, .end: label = L10n.text("app.adjustGradientRange", defaultValue: "Adjust Gradient Range"); cursor = .resizeUpDown
        case .radiusX: label = L10n.text("app.adjustWidth", defaultValue: "Adjust Width"); cursor = .resizeLeftRight
        case .radiusY: label = L10n.text("app.adjustHeight", defaultValue: "Adjust Height"); cursor = .resizeUpDown
        case .rotate:
            label = L10n.text("app.rotateSelection", defaultValue: "Rotate Selection"); cursor = Self.rotateCursor
            if maskTracking {
                label = rotationLabel(c, size: edit.sourceSize)
            }
        case nil:
            if (c.tool == .color || c.tool == .luminance) && (edit.sampling || event.modifierFlags.contains(.shift)) { label = L10n.text("app.clickPhotoToSample", defaultValue: "Click Photo to Sample"); cursor = .crosshair }
        }
        if action == .radiusX || action == .radiusY || action == .start || action == .end,
           let rect = targetImageRect() {
            let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
            let angle: Double
            if c.tool == .linear { angle = atan2((c.end.y - c.start.y) * edit.sourceSize.height, (c.end.x - c.start.x) * edit.sourceSize.width) }
            else { angle = c.angle * .pi / 180 + (action == .radiusY ? .pi / 2 : 0) }
            let anchor = CGPoint(x: c.start.x*edit.sourceSize.width, y: c.start.y*edit.sourceSize.height)
            let origin = anchor.applying(mapping.transform)
            let axis = CGPoint(x: anchor.x+cos(angle), y: anchor.y+sin(angle)).applying(mapping.transform)
            let x = (axis.x - origin.x) * rect.width / mapping.output.width
            let y = (axis.y - origin.y) * rect.height / mapping.output.height
            cursor = abs(x) > abs(y) ? .resizeLeftRight : .resizeUpDown
        }
        cursor.set(); toolTip = label.isEmpty ? nil : label
        guard !label.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerHint.string = label
        let width = CGFloat(label.count * 13 + 16)
        pointerHint.frame = CGRect(x: min(bounds.width - width, max(0, point.x + 18)), y: max(0, point.y - 32), width: width, height: 23)
        pointerHint.isHidden = false
        if action != .draw, action != nil {
            handleHighlight.frame = bounds
            handleHighlight.path = CGPath(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12), transform: nil)
        }
    }
    private func rotationLabel(_ c: MaskComponent, size: CGSize) -> String {
        let angle = c.tool == .linear ? atan2((c.end.y - c.start.y) * size.height, (c.end.x - c.start.x) * size.width) * 180 / .pi : c.angle
        return L10n.text("app.rotateSelectionShift15Increments", defaultValue: "Rotate selection · \(Int(angle.rounded()))° · Shift: 15° increments")
    }
    private func spotImageRect() -> CGRect? {
        let rect = zoomMotion?.rect(at: CACurrentMediaTime()) ?? targetImageRect()
        guard let rect, rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
    private func spotMarkerSourceRadius(_ edit: SpotCanvasEditing, rect: CGRect) -> Double {
        let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
        guard mapping.output.width > 0, rect.width > 0 else { return 0 }
        let backing = window?.backingScaleFactor ?? 1
        return Double(SpotPlacement.markerHitRadius * backing * mapping.output.width / rect.width)
    }
    private func spotHit(at event: NSEvent) -> (id: UUID, action: SpotPointerAction)? {
        guard let edit = spotEditing, edit.showGuides, let rect = spotImageRect(),
              let point = MaskGeometry.sourcePoint(maskOutputPoint(event), size: edit.sourceSize, recipe: edit.recipe) else { return nil }
        return SpotPlacement.hit(point: point, size: edit.sourceSize, repairs: edit.repairs, selectedID: edit.selectedID, offsets: edit.offsets, markerRadius: spotMarkerSourceRadius(edit, rect: rect))
    }
    private func setSpotHover(_ id: UUID?) {
        guard id != spotHoverID else { return }
        spotHoverID = id
        if let rect = spotImageRect() { updateSpotGuides(rect: rect) }
    }
    private func showPointerHint(_ text: String, near event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerHint.string = text
        let width = max(72, CGFloat(text.count) * 13 + 16)
        pointerHint.frame = CGRect(x: min(bounds.width - width, max(0, point.x + 18)), y: max(0, point.y - 32), width: width, height: 23)
        pointerHint.isHidden = false
    }
    private func spotHint(_ repair: SpotRepair, _ action: SpotPointerAction) -> String {
        switch (repair.mode, action) {
        case (.clone, .source): return L10n.text("app.dragTheSourceToCopyItsColorAndTexture", defaultValue: "Drag the source to copy its color and texture")
        case (.heal, .source), (.remove, .source): return L10n.text("app.dragTheSourceToChangeTextureOnly", defaultValue: "Drag the source to change texture only")
        case (_, .move): return L10n.text("app.moveThisSpot", defaultValue: "Move This Spot")
        case (_, .draw): return ""
        }
    }
    private func updateSpotCursor(_ event: NSEvent) {
        guard let edit = spotEditing else { return }
        guard !spaceHeld, let rect = spotImageRect() else {
            brushCursor.path = nil
            setSpotHover(nil)
            if spaceHeld { NSCursor.openHand.set() }
            return
        }
        let hit = spotTracking ? nil : spotHit(at: event)
        let adjusting = spotTracking ? spotAdjusting : hit != nil
        setSpotHover((!spotTracking && hit?.id != edit.selectedID) ? hit?.id : nil)
        if adjusting {
            brushCursor.path = nil
            if spotTracking {
                pointerHint.isHidden = true
                NSCursor.closedHand.set()
            } else if spotHoverID != nil {
                NSCursor.pointingHand.set()
                showPointerHint(L10n.text("app.selectThisSpot", defaultValue: "Select This Spot"), near: event)
            } else if let hit, let repair = edit.repairs.first(where: { $0.id == hit.id }) {
                NSCursor.openHand.set()
                let label = spotHint(repair, hit.action)
                if label.isEmpty { pointerHint.isHidden = true } else { showPointerHint(label, near: event) }
            } else {
                pointerHint.isHidden = true
                NSCursor.openHand.set()
            }
            return
        }
        pointerHint.isHidden = true
        NSCursor.arrow.set()
        let point = convert(event.locationInWindow, from: nil)
        let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
        if !edit.recipe.perspective.isNeutral {
            brushCursor.frame = bounds
            brushCursor.path = projectedBrush(at: maskOutputPoint(event), size: edit.sourceSize, recipe: edit.recipe,
                                              radius: edit.radius, feather: edit.feather, rect: rect)
            return
        }
        let radius = edit.radius * min(edit.sourceSize.width, edit.sourceSize.height) * rect.width / mapping.output.width / (window?.backingScaleFactor ?? 1)
        let path = CGMutablePath()
        for r in [radius, radius * (1 - edit.feather)] where r > 0.5 {
            path.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        }
        brushCursor.frame = bounds
        brushCursor.path = path
    }
    private func updateBrushCursor(_ event: NSEvent) {
        guard spotEditing == nil else { return }
        guard let edit = maskEditing, edit.component?.tool == .brush, !spaceHeld,
              let rect = targetImageRect() else { brushCursor.path = nil; return }
        let point = convert(event.locationInWindow, from: nil)
        let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
        if !edit.recipe.perspective.isNeutral {
            brushCursor.frame = bounds
            brushCursor.path = projectedBrush(at: maskOutputPoint(event), size: edit.sourceSize, recipe: edit.recipe,
                                              radius: edit.brushRadius, feather: edit.brushFeather, rect: rect)
            return
        }
        let radius = edit.brushRadius * min(edit.sourceSize.width, edit.sourceSize.height) * rect.width / mapping.output.width / (window?.backingScaleFactor ?? 1)
        let path = CGMutablePath()
        for r in [radius, radius * (1 - edit.brushFeather)] {
            path.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        }
        path.move(to: CGPoint(x: point.x - 3, y: point.y)); path.addLine(to: CGPoint(x: point.x + 3, y: point.y))
        if !edit.brushErase && !event.modifierFlags.contains(.option) {
            path.move(to: CGPoint(x: point.x, y: point.y - 3)); path.addLine(to: CGPoint(x: point.x, y: point.y + 3))
        }
        brushCursor.frame = bounds; brushCursor.path = path
    }
    private func projectedBrush(at output: CGPoint, size: CGSize, recipe: EditRecipe, radius: Double, feather: Double, rect: CGRect) -> CGPath? {
        guard let p = MaskGeometry.sourcePoint(output, size: size, recipe: recipe) else { return nil }
        let mapping = MaskGeometry.mapping(size: size, recipe: recipe), backing = window?.backingScaleFactor ?? 1
        let transform = mapping.transform.concatenating(CGAffineTransform(scaleX: rect.width/mapping.output.width/backing, y: rect.height/mapping.output.height/backing))
            .concatenating(CGAffineTransform(translationX: rect.minX/backing, y: rect.minY/backing))
        let path = CGMutablePath(), center = CGPoint(x: p.x*size.width, y: p.y*size.height)
        for fraction in [1.0, 1-feather] where fraction > 0 {
            let r = radius*min(size.width, size.height)*fraction
            path.addEllipse(in: CGRect(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r))
        }
        return transform.path(path)
    }
    override func mouseDown(with event: NSEvent) {
        guard cropAngle == nil, source != nil else { return }
        window?.makeFirstResponder(self)
        pressPoint = convert(event.locationInWindow, from: nil); lastDragPoint = pressPoint; dragged = false
        if targetedToolID != nil && !spaceHeld {
            targetPointerY = Double(pressPoint?.y ?? 0); targetDelta = 0
            targetTracking = onTargetBegin?(maskOutputPoint(event)) ?? false
            return
        }
        if spotEditing != nil && !spaceHeld {
            spotHold = nil
            spotTracking = true
            spotAdjusting = spotHit(at: event) != nil
            updateSpotCursor(event)
            let radius = spotEditing.flatMap { edit in spotImageRect().map { spotMarkerSourceRadius(edit, rect: $0) } } ?? 0
            onSpotPointer?(maskOutputPoint(event), .down, radius)
            if let rect = spotImageRect() { updateSpotGuides(rect: rect) }
            return
        }
        if maskEditing != nil && !spaceHeld {
            activeMaskAction = maskAction(at: event)
            if let tool = maskEditing?.component?.tool, tool == .linear || tool == .radial, activeMaskAction == nil { return }
            maskTracking = true
            updateBrushCursor(event); updateMaskPointer(event)
            onMaskPointer?(maskOutputPoint(event), .down, event.modifierFlags, activeMaskAction)
        }
    }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool {
        if source != nil, targetedToolID != nil,
           let rect = zoomMotion?.rect(at: CACurrentMediaTime()) ?? targetImageRect() {
            let point = Self.outputPoint(CGPoint(x: drawableSize.width / 2, y: drawableSize.height / 2), in: rect)
            // AXPress samples without mouseDown. Transfer keyboard ownership too,
            // otherwise arrows can still edit the previously focused histogram.
            guard window?.makeFirstResponder(self) == true else { return false }
            guard onTargetBegin?(point) == true else { return false }
            onTargetEnd?(false); return true
        }
        if source != nil, cropAngle == nil, let onZoneSample,
           let rect = zoomMotion?.rect(at: CACurrentMediaTime()) ?? targetImageRect(), rect.width > 0, rect.height > 0 {
            onZoneSample(CGPoint(x: (drawableSize.width / 2 - rect.minX) / rect.width,
                                 y: (drawableSize.height / 2 - rect.minY) / rect.height)); return true
        }
        guard source != nil, cropAngle == nil, let onClick else { return false }
        onClick(displayCenter)
        return true
    }
    override func mouseDragged(with event: NSEvent) {
        if targetTracking {
            let y = convert(event.locationInWindow, from: nil).y
            targetDelta += (y - targetPointerY) * (isFlipped ? -1 : 1) * (event.modifierFlags.contains(.shift) ? 0.1 : 1)
            targetPointerY = y; onTargetChange?(targetDelta * 0.5)
            return
        }
        if spotTracking {
            onSpotPointer?(maskOutputPoint(event), .drag, 0)
            updateSpotCursor(event)
            if let rect = spotImageRect() { updateSpotGuides(rect: rect) }
            return
        }
        if maskTracking { updateBrushCursor(event); updateMaskPointer(event); onMaskPointer?(maskOutputPoint(event), .drag, event.modifierFlags, activeMaskAction); return }
        guard let pressPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 3 { dragged = true }
        if dragged && canPan && ((onZoneSample == nil && targetedToolID == nil) || spaceHeld) {
            NSCursor.closedHand.set()
            let previous = lastDragPoint ?? pressPoint
            let delta = CGSize(width: point.x - previous.x,
                               height: isFlipped ? point.y - previous.y : previous.y - point.y)
            lastDragPoint = point
            // Absolute positions also work for tablet / synthesized events with zero deltas.
            panBy(delta, backingScale: window?.backingScaleFactor ?? 1)
        }
    }
    override func mouseUp(with event: NSEvent) {
        if targetTracking {
            mouseDragged(with: event); targetTracking = false; onTargetEnd?(false)
            pressPoint = nil; lastDragPoint = nil; return
        }
        if targetedToolID != nil && !spaceHeld { pressPoint = nil; lastDragPoint = nil; return }
        if spotTracking {
            let previous = spotDraft?()
            onSpotPointer?(maskOutputPoint(event), .up, 0)
            spotHold = previous.flatMap { spotOverlayAbsorbed($0) ? nil : $0 }
            spotTracking = false
            spotAdjusting = false
            pressPoint = nil
            lastDragPoint = nil
            if let rect = spotImageRect() { updateSpotGuides(rect: rect) }
            updateSpotCursor(event)
            return
        }
        if maskTracking {
            onMaskPointer?(maskOutputPoint(event), .up, event.modifierFlags, activeMaskAction); maskTracking = false; activeMaskAction = nil; pressPoint = nil; lastDragPoint = nil; updateMaskPointer(event); return
        }
        if maskEditing != nil || spotEditing != nil { pressPoint = nil; lastDragPoint = nil; dragged = false; return }
        defer { pressPoint = nil; lastDragPoint = nil; dragged = false; window?.invalidateCursorRects(for: self) }
        guard targetedToolID == nil, pressPoint != nil, !dragged, let source, cropAngle == nil else { return }
        if let onZoneSample {
            if !spaceHeld { onZoneSample(maskOutputPoint(event)) }
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let backing = window?.backingScaleFactor ?? 1
        let point = CGPoint(x: p.x * backing, y: (isFlipped ? p.y : bounds.height - p.y) * backing)
        let size = presentationSize(source: source, canvas: drawableSize)
        let center = canPan ? displayCenter : CGPoint(x: 0.5, y: 0.5)
        onClick?(Self.imagePoint(point, center: center, displayed: size, canvas: drawableSize))
    }
    func rebuildMaskOverlay() {
        maskCoverage = nil; maskHandles.path = nil
        if !maskTracking { pointerHint.isHidden = true; handleHighlight.path = nil }
        if maskEditing?.component?.tool != .brush { brushCursor.path = nil }
        guard let edit = maskEditing, edit.showOverlay, let group = edit.group else { return }
        // Coverage only. The view style is applied in draw and never enters the exported image.
        let scale = min(1, 1536 / max(edit.sourceSize.width, edit.sourceSize.height))
        let extent = CGRect(x: 0, y: 0, width: max(1, floor(edit.sourceSize.width * scale)), height: max(1, floor(edit.sourceSize.height * scale)))
        if group.needsBaseline, edit.reference == nil { return }
        do {
            let mask = try MaskPipeline.mask(group, extent: extent, baseline: edit.reference.map { CIImage(cgImage: $0) })
            maskCoverage = try ImagePipeline.geometry(mask, recipe: edit.recipe, referenceSize: edit.sourceSize)
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onMaskError?(message) }
        }
    }
    /// Scale a coverage image onto the photo's extent, including a non-zero origin.
    static func fitted(_ image: CIImage, to extent: CGRect) -> CIImage {
        guard image.extent.width > 0, image.extent.height > 0, extent.width > 0, extent.height > 0 else { return image }
        let scaleX = extent.width / image.extent.width, scaleY = extent.height / image.extent.height
        let transform = CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return image.transformed(by: transform).cropped(to: extent)
    }
    private func maskOutputPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let backing = window?.backingScaleFactor ?? 1
        let point = CGPoint(x: p.x * backing, y: (isFlipped ? bounds.height - p.y : p.y) * backing)
        let rect = zoomMotion?.rect(at: CACurrentMediaTime()) ?? targetImageRect() ?? .zero
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: CGFloat.nan, y: CGFloat.nan) }
        return Self.outputPoint(point, in: rect)
    }
    /// Same displayed-photo coordinates for sampling, masks and repair tools.
    /// Outside points remain outside so transparent mats never sample edge pixels.
    static func outputPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: CGFloat.nan, y: CGFloat.nan) }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
    private func clearSpotOverlay() {
        spotGuideLayer.path = nil
        spotSourceLayer.path = nil
        for marker in spotMarkerLayers { marker.path = nil }
    }
    private func cachedOutline(id: UUID, points: [CGPoint], radius: CGFloat) -> SpotOutline {
        let first = points.first ?? .zero
        let last = points.last ?? first
        if id == spotOutlineID, points.count == spotOutlineCount, radius == spotOutlineRadius, first == spotOutlineFirst, last == spotOutlineLast {
            return spotOutline
        }
        let made = SpotOutline.make(points: points, radius: radius)
        spotOutlineID = id
        spotOutlineCount = points.count
        spotOutlineRadius = radius
        spotOutlineFirst = first
        spotOutlineLast = last
        spotOutline = made
        return made
    }
    private func spotMarkerLayer(_ index: Int) -> CAShapeLayer {
        if index < spotMarkerLayers.count { return spotMarkerLayers[index] }
        let marker = CAShapeLayer()
        marker.strokeColor = NSColor.white.cgColor
        marker.lineWidth = 1
        marker.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        marker.shadowColor = NSColor.black.cgColor
        marker.shadowOpacity = 1
        marker.shadowRadius = 0.5
        marker.shadowOffset = .zero
        marker.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "fillColor": NSNull(), "contentsScale": NSNull()]
        spotGuideLayer.superlayer?.insertSublayer(marker, below: spotGuideLayer)
        spotMarkerLayers.append(marker)
        return marker
    }
    func spotOverlayAbsorbed(_ draft: SpotCanvasDraft) -> Bool {
        guard let edit = spotEditing, let repair = edit.repairs.first(where: { $0.id == draft.id }) else { return false }
        let offsetMatches = draft.offset == nil || edit.offsets[draft.id] == draft.offset
        return repair.points == draft.points && offsetMatches
    }
    private func updateSpotGuides(rect: CGRect) {
        guard let edit = spotEditing, edit.showGuides, rect.width > 0, rect.height > 0 else { clearSpotOverlay(); return }
        let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
        let backing = window?.backingScaleFactor ?? 1
        let transform = mapping.transform
            .concatenating(CGAffineTransform(scaleX: rect.width / mapping.output.width / backing, y: rect.height / mapping.output.height / backing))
            .concatenating(CGAffineTransform(translationX: rect.minX / backing, y: rect.minY / backing))
        let path = CGMutablePath()
        let heads = CGMutablePath()
        let short = min(edit.sourceSize.width, edit.sourceSize.height)
        let screen = backing * mapping.output.width / rect.width
        let draft = spotDraft?() ?? spotHold
        let focusedID = draft?.id ?? edit.selectedID
        let width = edit.sourceSize.width
        let height = edit.sourceSize.height
        func pixels(_ points: [MaskPoint]) -> [CGPoint] {
            points.map { CGPoint(x: $0.x * width, y: $0.y * height) }
        }
        func addBody(_ points: [CGPoint], radius: CGFloat, offset: MaskPoint?, shift: CGPoint, cacheID: UUID) {
            guard let first = points.first else { return }
            let base = cachedOutline(id: cacheID, points: points, radius: radius)
            let body = shift == .zero ? base : base.translated(dx: shift.x, dy: shift.y)
            path.addPath(body.cgPath())
            guard let offset else { return }
            let dx = CGFloat(offset.x) * width
            let dy = CGFloat(offset.y) * height
            guard hypot(dx, dy) > 0.5 else { return }
            path.addPath(body.translated(dx: dx, dy: dy).cgPath())
            let origin = CGPoint(x: first.x + shift.x, y: first.y + shift.y)
            // Head on the target rim, tail on the source rim.
            if let ends = body.bridge(from: origin, dx: dx, dy: dy),
               let arrow = SpotArrow.make(from: ends.1, to: ends.0, length: 8 * screen) {
                arrow.addShaft(to: path)
                arrow.addHead(to: heads)
            }
        }
        var markerIndex = 0
        var drewDraft = false
        for (ordinal, repair) in edit.repairs.enumerated() where repair.enabled && !repair.points.isEmpty {
            let repairPixels = pixels(repair.points)
            guard let first = repairPixels.first else { continue }
            if repair.id == focusedID {
                var shown = repairPixels
                var offset = edit.offsets[repair.id]
                var shift = CGPoint.zero
                let radius = max(1, repair.radius * short)
                if let draft, draft.id == repair.id {
                    if let live = draft.offset { offset = live }
                    switch draft.action {
                    case .draw:
                        shown = pixels(draft.points)
                    case .move:
                        if let from = repair.points.first, let to = draft.points.first {
                            shift = CGPoint(x: (to.x - from.x) * width, y: (to.y - from.y) * height)
                        }
                    case .source:
                        break
                    }
                }
                addBody(shown, radius: radius, offset: offset, shift: shift, cacheID: repair.id)
                drewDraft = draft?.id == repair.id
            } else {
                let marker = spotMarkerLayer(markerIndex)
                let dot = (repair.id == spotHoverID ? SpotPlacement.markerHitRadius : SpotPlacement.markerRadius) * screen
                let mark = CGMutablePath()
                mark.addEllipse(in: CGRect(x: first.x - dot, y: first.y - dot, width: dot * 2, height: dot * 2))
                let displayed = CGMutablePath()
                displayed.addPath(transform.path(mark))
                marker.contentsScale = backing
                marker.frame = bounds
                marker.fillColor = Self.spotMarkerColors[ordinal % Self.spotMarkerColors.count]
                marker.path = displayed
                markerIndex += 1
            }
        }
        if let draft, draft.action == .draw, !drewDraft, !draft.points.isEmpty {
            addBody(pixels(draft.points), radius: max(1, draft.radius * short), offset: draft.offset, shift: .zero, cacheID: draft.id)
        }
        for index in markerIndex..<spotMarkerLayers.count { spotMarkerLayers[index].path = nil }
        let displayed = CGMutablePath()
        displayed.addPath(transform.path(path))
        spotGuideLayer.contentsScale = backing
        spotGuideLayer.frame = bounds
        spotGuideLayer.path = displayed
        let displayedHeads = CGMutablePath()
        displayedHeads.addPath(transform.path(heads))
        spotSourceLayer.contentsScale = backing
        spotSourceLayer.frame = bounds
        spotSourceLayer.lineDashPattern = nil
        spotSourceLayer.fillColor = NSColor.white.cgColor
        spotSourceLayer.path = displayedHeads
    }
    override func keyDown(with event: NSEvent) {
        if targetedToolID != nil {
            if event.keyCode == 53 {
                if targetTracking { cancelTargetGesture() } else { onTargetExit?() }
                return
            }
            if event.keyCode == 49 { cancelTargetGesture(); spaceHeld = true; window?.invalidateCursorRects(for: self); return }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                let key = event.charactersIgnoringModifiers
                if event.keyCode == 126 || key == "+" || key == "=" { _ = onTargetNudge?(1); return }
                if event.keyCode == 125 || key == "-" { _ = onTargetNudge?(-1); return }
            }
        }
        if event.keyCode == 49, maskEditing != nil || spotEditing != nil || onZoneSample != nil { spaceHeld = true; window?.invalidateCursorRects(for: self); return }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false; window?.invalidateCursorRects(for: self); return }
        super.keyUp(with: event)
    }
    override func resignFirstResponder() -> Bool {
        cancelTargetGesture()
        spaceHeld = false
        onPixelReadout?(nil)
        if spotTracking {
            let previous = spotDraft?()
            onSpotPointer?(CGPoint(x: CGFloat.nan, y: CGFloat.nan), .up, 0)
            spotHold = previous.flatMap { spotOverlayAbsorbed($0) ? nil : $0 }
            spotTracking = false
            spotAdjusting = false
            if let rect = spotImageRect() { updateSpotGuides(rect: rect) }
        }
        if maskTracking { onMaskPointer?(CGPoint(x: CGFloat.nan, y: CGFloat.nan), .up, [], activeMaskAction); maskTracking = false }
        brushCursor.path = nil
        return super.resignFirstResponder()
    }

    private func updatePixelReadout(_ event: NSEvent) {
        guard readoutEnabled, let source, let sampler = pixelSampler,
              let rect = targetImageRect(), rect.width > 0, rect.height > 0 else {
            onPixelReadout?(nil); return
        }
        let local = convert(event.locationInWindow, from: nil)
        let backing = window?.backingScaleFactor ?? 1
        let point = CGPoint(x: local.x * backing,
                            y: (isFlipped ? bounds.height - local.y : local.y) * backing)
        guard rect.contains(point) else { onPixelReadout?(nil); return }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        // `source` is retained by the sampler; keep this guard so a stale
        // callback cannot survive an async photo switch.
        guard source.width > 0, source.height > 0 else { onPixelReadout?(nil); return }
        onPixelReadout?(sampler.sample(normalizedX: x, normalizedY: y))
    }
    private func updateMaskHandles(rect: CGRect) {
        if let edit = maskEditing, edit.showGuides, edit.component?.tool == .object, edit.awaitingDraw {
            let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
            let backing = window?.backingScaleFactor ?? 1
            let transform = mapping.transform
                .concatenating(CGAffineTransform(scaleX: rect.width / mapping.output.width / backing, y: rect.height / mapping.output.height / backing))
                .concatenating(CGAffineTransform(translationX: rect.minX / backing, y: rect.minY / backing))
            let path = CGMutablePath()
            func point(_ p: MaskPoint) -> CGPoint? { transform.point(CGPoint(x: p.x * edit.sourceSize.width, y: p.y * edit.sourceSize.height)) }
            for prompt in edit.smartPrompts where prompt.label < 2 {
                guard let p = point(prompt.point) else { continue }
                path.addEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                path.move(to: CGPoint(x: p.x - 3, y: p.y)); path.addLine(to: CGPoint(x: p.x + 3, y: p.y))
                if prompt.label == 1 { path.move(to: CGPoint(x: p.x, y: p.y - 3)); path.addLine(to: CGPoint(x: p.x, y: p.y + 3)) }
            }
            let boxes = edit.smartBox.map { [$0] } ?? []
            let promptBox = edit.smartPrompts.filter { $0.label >= 2 }
            var regions = boxes
            if promptBox.count == 2, let box = SmartMaskField.region(promptBox[0].point, promptBox[1].point) { regions.append(box) }
            for box in regions {
                let corners = [MaskPoint(box.minX, box.minY), MaskPoint(box.maxX, box.minY), MaskPoint(box.maxX, box.maxY), MaskPoint(box.minX, box.maxY)].compactMap(point)
                if corners.count == 4 { path.addLines(between: corners); path.closeSubpath() }
            }
            maskHandles.path = path; return
        }
        guard let edit = maskEditing, edit.showGuides, !edit.awaitingDraw, let c = edit.component, c.enabled else { maskHandles.path = nil; return }
        let mapping = MaskGeometry.mapping(size: edit.sourceSize, recipe: edit.recipe)
        let backing = window?.backingScaleFactor ?? 1
        let transform = mapping.transform
            .concatenating(CGAffineTransform(scaleX: rect.width / mapping.output.width / backing, y: rect.height / mapping.output.height / backing))
            .concatenating(CGAffineTransform(translationX: rect.minX / backing, y: rect.minY / backing))
        if maskTracking && activeMaskAction == .rotate { pointerHint.string = rotationLabel(c, size: edit.sourceSize) }
        let rotationOffset = 36 * backing * mapping.output.width / rect.width
        let editHandles = MaskEditGesture.handles(c, size: edit.sourceSize, rotationOffset: rotationOffset)
        let path = CGMutablePath()
        let center = CGPoint(x: c.start.x * edit.sourceSize.width, y: c.start.y * edit.sourceSize.height)
        var handles: [CGPoint] = []
        if c.tool == .linear {
            let end = CGPoint(x: c.end.x * edit.sourceSize.width, y: c.end.y * edit.sourceSize.height)
            let dx = end.x - center.x, dy = end.y - center.y
            let length = max(0.001, hypot(dx, dy))
            let half = max(edit.sourceSize.width, edit.sourceSize.height) * (2 + max(abs(c.start.x), abs(c.start.y), abs(c.end.x), abs(c.end.y)))
            let mid = CGPoint(x: (center.x + end.x) / 2, y: (center.y + end.y) / 2)
            for p in [center, mid, end] {
                path.move(to: CGPoint(x: p.x - dy / length * half, y: p.y + dx / length * half))
                path.addLine(to: CGPoint(x: p.x + dy / length * half, y: p.y - dx / length * half))
            }
            path.move(to: center); path.addLine(to: end)
            if let rotate = editHandles.last?.point {
                path.move(to: center); path.addLine(to: CGPoint(x: rotate.x * edit.sourceSize.width, y: rotate.y * edit.sourceSize.height))
            }
        } else if c.tool == .radial {
            let rx = c.radiusX * edit.sourceSize.width, ry = c.radiusY * edit.sourceSize.height
            let a = c.angle * .pi / 180
            var ellipse = CGAffineTransform(rotationAngle: a).concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            path.addPath(CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &ellipse))
            let rotation = ry + rotationOffset
            let top = CGPoint(x: center.x - ry * sin(a), y: center.y + ry * cos(a))
            let rotate = CGPoint(x: center.x - rotation * sin(a), y: center.y + rotation * cos(a))
            path.move(to: top); path.addLine(to: rotate)

        } else if c.tool == .color {
            handles = c.samples.map { CGPoint(x: $0.point.x * edit.sourceSize.width, y: $0.point.y * edit.sourceSize.height) }
        }
        let displayed = CGMutablePath()
        displayed.addPath(transform.path(path))
        for handle in editHandles {
            guard let point = transform.point(CGPoint(x: handle.point.x * edit.sourceSize.width, y: handle.point.y * edit.sourceSize.height)) else { continue }
            let box = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            if handle.action == .move || (c.tool == .linear && handle.action == .rotate) { displayed.addEllipse(in: box) }
            else if handle.action == .rotate {
                displayed.move(to: CGPoint(x: point.x + 7, y: point.y))
                displayed.addArc(center: point, radius: 7, startAngle: 0, endAngle: .pi * 1.7, clockwise: false)
                displayed.move(to: CGPoint(x: point.x + 7, y: point.y + 4)); displayed.addLine(to: CGPoint(x: point.x + 7, y: point.y)); displayed.addLine(to: CGPoint(x: point.x + 3, y: point.y + 1))
            } else { displayed.addRect(box) }
        }
        for handle in handles {
            guard let point = transform.point(handle) else { continue }
            displayed.addEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        }
        maskHandles.frame = bounds; maskHandles.path = displayed
    }
    private func updateSplitLine(x: CGFloat?, rect: CGRect) {
        guard let x else { splitLine.path = nil; return }
        let backing = window?.backingScaleFactor ?? 1
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x / backing, y: max(0, rect.minY) / backing))
        path.addLine(to: CGPoint(x: x / backing, y: min(drawableSize.height, rect.maxY) / backing))
        splitLine.frame = bounds; splitLine.path = path
    }

    static func imagePoint(_ point: CGPoint, center: CGPoint, displayed: CGSize, canvas: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, center.x + (point.x - canvas.width / 2) / max(1, displayed.width))),
                y: min(1, max(0, center.y + (point.y - canvas.height / 2) / max(1, displayed.height))))
    }
    func panBy(_ delta: CGSize, backingScale: CGFloat) {
        guard canPan, let source else { return }
        zoomMotion = nil; isPaused = true; enableSetNeedsDisplay = true
        let size = presentationSize(source: source, canvas: drawableSize)
        viewport?.move(to: CGPoint(x: displayCenter.x - delta.width * backingScale / max(1, size.width),
                                  y: displayCenter.y - delta.height * backingScale / max(1, size.height)))
        displayCenter = viewport?.center ?? displayCenter
        onPan?(displayCenter)
        draw()
    }

}


/// Canvas-only diagnostics; never part of renders, histograms or exports.
enum DisplayOverlay {
    private final class Resources {}
    private static let library: Data? = {
        guard let url = Bundle(for: Resources.self).url(forResource: "default", withExtension: "metallib") else { return nil }
        return try? Data(contentsOf: url)
    }()
    private static let clipKernel: CIColorKernel? = library.flatMap { try? CIColorKernel(functionName: "clipWarning", fromMetalLibraryData: $0, outputPixelFormat: .RGBAf) }
    private static let maskViewKernel: CIColorKernel? = library.flatMap { try? CIColorKernel(functionName: "maskView", fromMetalLibraryData: $0, outputPixelFormat: .RGBAf) }
    /// Red, green, and the existing blue used by the color overlay. Not theme colours.
    static let maskTints = [CIVector(x: 1, y: 0, z: 0), CIVector(x: 0, y: 1, z: 0), CIVector(x: 0, y: 0.3, z: 1)]
    static func maskTint(_ index: Int) -> CIVector { maskTints[min(maskTints.count - 1, max(0, index))] }
    static var available: Bool { clipKernel != nil && maskViewKernel != nil }
    /// Paints channels at the preview's white code magenta and at its black code cyan, as the histogram clip lamps count them.
    static func clipping(_ image: CIImage) -> CIImage {
        clipping(image, shadows: true, highlights: true)
    }
    static func clipping(_ image: CIImage, shadows: Bool, highlights: Bool) -> CIImage {
        guard shadows || highlights else { return image }
        return clipKernel?.apply(extent: image.extent,
                                 arguments: [image, linear(Palette.clipShadow), linear(Palette.clipHighlight),
                                             shadows ? 1.0 : 0.0, highlights ? 1.0 : 0.0]) ?? image
    }
    /// Composites a mask view over the photo. The result replaces the displayed frame and is not exported.
    static func maskView(_ photo: CIImage, coverage: CIImage, style: MaskOverlayStyle, tint: CIVector) -> CIImage {
        let mat = style == .onWhite ? linear(Palette.overlayLight) : linear(Palette.overlayDark)
        return maskViewKernel?.apply(extent: photo.extent, arguments: [photo, coverage, tint, mat, Double(style.rawValue)]) ?? photo
    }
    /// Kernel arguments live in Core Image's linear sRGB working space.
    private static func linear(_ color: NSColor) -> CIVector {
        func decode(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return CIVector(x: decode(color.redComponent), y: decode(color.greenComponent), z: decode(color.blueComponent))
    }
}

/// Presentation-only motion: high-resolution frames may arrive without restarting it.
struct CanvasZoomMotion {
    var from: CGRect
    var to: CGRect
    var start: CFTimeInterval
    var duration: CFTimeInterval = 0.24
    func rect(at time: CFTimeInterval) -> CGRect {
        let t = min(1, max(0, (time - start) / duration))
        let eased = CGFloat(1 - pow(1 - t, 3))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }
}

/// Normalized top-left coordinates shared by the navigator and the Metal canvas.
@MainActor
final class PhotoViewport: ObservableObject {
    @Published private(set) var center = CGPoint(x: 0.5, y: 0.5)
    @Published private(set) var visibleFraction = CGSize(width: 1, height: 1)
    var visibleRect: CGRect {
        CGRect(x: center.x - visibleFraction.width / 2, y: center.y - visibleFraction.height / 2,
               width: visibleFraction.width, height: visibleFraction.height)
    }
    private var pendingFocus: CGPoint?
    var requestedCenter: CGPoint { pendingFocus ?? center }
    func restore(_ point: CGPoint) { pendingFocus = point; center = point }
    func reset() { pendingFocus = nil; move(to: CGPoint(x: 0.5, y: 0.5)) }
    func focusOnNextGeometry(_ point: CGPoint) { pendingFocus = point }
    func update(image: CGSize, canvas: CGSize, zoomed: Bool) {
        let fraction = zoomed ? Self.fraction(image: image, canvas: canvas) : CGSize(width: 1, height: 1)
        if visibleFraction != fraction { visibleFraction = fraction }
        move(to: zoomed ? pendingFocus ?? center : center)
        if zoomed { pendingFocus = nil }
    }
    func move(to point: CGPoint) {
        let bounded = Self.clamp(point, fraction: visibleFraction)
        if center != bounded { center = bounded }
    }
    /// Move by a fraction of the currently visible viewport. A value of 1
    /// advances one full screen; clamping keeps the navigator at an edge.
    func panVisible(horizontal: CGFloat = 0, vertical: CGFloat = 0) {
        move(to: CGPoint(x: center.x + horizontal * visibleFraction.width,
                         y: center.y + vertical * visibleFraction.height))
    }
    static func fraction(image: CGSize, canvas: CGSize) -> CGSize {
        CGSize(width: min(1, max(0, canvas.width) / max(1, image.width)),
               height: min(1, max(0, canvas.height) / max(1, image.height)))
    }
    static func clamp(_ point: CGPoint, fraction: CGSize) -> CGPoint {
        CGPoint(x: min(1 - fraction.width / 2, max(fraction.width / 2, point.x)),
                y: min(1 - fraction.height / 2, max(fraction.height / 2, point.y)))
    }
}

struct PhotoNavigator: View {
    @ObservedObject var viewport: PhotoViewport
    @State private var grabOffset: CGPoint?
    let image: CGImage
    let zoomed: Bool
    let canNavigate: Bool
    var zoomLabel = "100%"
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            let rect = viewport.visibleRect
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                if zoomed {
                    Rectangle().stroke(.black.opacity(0.8), lineWidth: 3)
                        .overlay(Rectangle().stroke(.white, lineWidth: 1))
                        .frame(width: rect.width * size.width, height: rect.height * size.height)
                        .offset(x: rect.minX * size.width, y: rect.minY * size.height)
                }
            }.frame(width: size.width, height: size.height).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    guard zoomed && canNavigate else { return }
                    let point = CGPoint(x: event.location.x / max(1, size.width), y: event.location.y / max(1, size.height))
                    if grabOffset == nil {
                        grabOffset = viewport.visibleRect.contains(point)
                            ? CGPoint(x: point.x - viewport.center.x, y: point.y - viewport.center.y) : .zero
                    }
                    viewport.move(to: CGPoint(x: point.x - (grabOffset?.x ?? 0), y: point.y - (grabOffset?.y ?? 0)))
                }.onEnded { _ in grabOffset = nil })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("app.photoNavigator", defaultValue: "Photo Navigator"))
                .accessibilityValue(zoomed ? L10n.text("app.horizontalVertical", defaultValue: "\(zoomLabel), horizontal \(Int(viewport.center.x * 100))%, vertical \(Int(viewport.center.y * 100))%") : L10n.text("app.fit", defaultValue: "Fit"))
                .accessibilityHint(L10n.text("app.whenZoomedDragTheThumbnailToNavigateOrDrag", defaultValue: "When zoomed, drag the thumbnail to navigate or drag the photo on the main canvas"))
                .accessibilityAction(named: Text(L10n.text("app.moveLeft", defaultValue: "Move Left"))) { nudge(x: -0.1, y: 0) }
                .accessibilityAction(named: Text(L10n.text("app.moveRight", defaultValue: "Move Right"))) { nudge(x: 0.1, y: 0) }
                .accessibilityAction(named: Text(L10n.text("app.moveUp", defaultValue: "Move Up"))) { nudge(x: 0, y: -0.1) }
                .accessibilityAction(named: Text(L10n.text("app.moveDown", defaultValue: "Move Down"))) { nudge(x: 0, y: 0.1) }
                .help(zoomed ? L10n.text("app.dragTheThumbnailToNavigateTheWhiteFrameShows", defaultValue: "Drag the thumbnail to navigate. The white frame shows the visible region") : L10n.text("app.chooseAZoomLevelToPan", defaultValue: "Choose a zoom level to pan"))
        }
    }
    private func nudge(x: CGFloat, y: CGFloat) {
        guard zoomed && canNavigate else { return }
        viewport.move(to: CGPoint(x: viewport.center.x + x, y: viewport.center.y + y))
    }
}

/// How the mask is shown on the photo. Display only; not stored in the recipe.
enum MaskOverlayStyle: Int, CaseIterable, Identifiable {
    case color, colorOnGray, onBlack, onWhite, monochrome
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .color: L10n.text("app.colorOverlay", defaultValue: "Color Overlay")
        case .colorOnGray: L10n.text("app.colorOnBW", defaultValue: "Color on B&W")
        case .onBlack: L10n.text("app.onBlack", defaultValue: "On Black")
        case .onWhite: L10n.text("app.onWhite", defaultValue: "On White")
        case .monochrome: L10n.text("app.blackWhiteMask", defaultValue: "Black & White Mask")
        }
    }
    var help: String {
        switch self {
        case .color: L10n.text("app.translucentColorOverThePhoto", defaultValue: "Translucent color over the photo")
        case .colorOnGray: L10n.text("app.convertThePhotoToBlackAndWhiteThenAdd", defaultValue: "Convert the photo to black and white, then add translucent color")
        case .onBlack: L10n.text("app.keepSelectedPhotoAreasMakeTheRestBlack", defaultValue: "Keep selected photo areas; make the rest black")
        case .onWhite: L10n.text("app.keepSelectedPhotoAreasMakeTheRestWhite", defaultValue: "Keep selected photo areas; make the rest white")
        case .monochrome: L10n.text("app.whiteIsFullySelectedBlackIsUnselected", defaultValue: "White is fully selected; black is unselected")
        }
    }
    var usesTint: Bool { self == .color || self == .colorOnGray }
}

struct MaskCanvasEditing: Equatable {
    var group: LocalAdjustment?
    var component: MaskComponent?
    var recipe: EditRecipe
    var sourceSize: CGSize
    var reference: CGImage?
    var showOverlay: Bool
    var showGuides = true
    var color: Int
    var style = MaskOverlayStyle.color
    var brushRadius = 0.04
    var brushFeather = 0.7
    var brushErase = false
    var awaitingDraw = false
    var sampling = false
    var smartPrompts: [SmartMaskPrompt] = []
    var smartBox: CGRect?
    var smartInstruction: String?
    var smartAllowsPointer = true
    func hasSameCoverage(as other: Self?) -> Bool {
        guard let other else { return false }
        return group == other.group && recipe == other.recipe && sourceSize == other.sourceSize
            && reference === other.reference && showOverlay == other.showOverlay
    }
    static func == (a: Self, b: Self) -> Bool {
        a.group == b.group && a.component == b.component && a.recipe == b.recipe && a.sourceSize == b.sourceSize && a.reference === b.reference && a.showOverlay == b.showOverlay && a.showGuides == b.showGuides && a.color == b.color && a.style == b.style && a.brushRadius == b.brushRadius && a.brushFeather == b.brushFeather && a.brushErase == b.brushErase && a.awaitingDraw == b.awaitingDraw && a.sampling == b.sampling && a.smartPrompts == b.smartPrompts && a.smartBox == b.smartBox && a.smartInstruction == b.smartInstruction && a.smartAllowsPointer == b.smartAllowsPointer
    }
}

struct SpotCanvasEditing: Equatable {
    var repairs: [SpotRepair]
    var offsets: [UUID: MaskPoint]
    var selectedID: UUID?
    var showGuides = true
    var recipe: EditRecipe
    var sourceSize: CGSize
    var radius: Double
    var feather: Double
}
