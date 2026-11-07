import SwiftUI
import AppKit

/// Only this leaf observes the live parameters while a histogram drag is in flight.
struct HistogramAdjustment: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> HistogramAdjustmentView { HistogramAdjustmentView() }
    func updateNSView(_ view: HistogramAdjustmentView, context: Context) {
        view.synchronize(photoID: model.activeID, enabled: model.canDragHistogram)
        view.values = HistogramRegion.allCases.map { region in model.recipe.map { region.value(in: $0) } ?? 0 }
        view.begin = { model.beginHistogramAdjustment($0) }
        view.change = { model.updateHistogramAdjustment(delta: $0) }
        view.end = { cancel in if cancel { model.cancelDirectAdjustment() } else { _ = model.finishDirectAdjustment() } }
        view.nudge = { model.nudgeHistogram($0, direction: $1) }
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: HistogramAdjustmentView, coordinator: ()) { view.finish(cancel: true) }
}

final class HistogramAdjustmentView: NSControl {
    var values = Array(repeating: 0.0, count: 5)
    var begin: ((HistogramRegion) -> Bool)?
    var change: ((Double) -> Void)?
    var end: ((Bool) -> Void)?
    var nudge: ((HistogramRegion, Double) -> Void)?
    private(set) var selected = HistogramRegion.exposure
    private(set) var tracking = false
    private var acceptsEditing = false
    private var photoID: String?
    private var pointerX = 0.0
    private var delta = 0.0
    private var hovered = false
    override var acceptsFirstResponder: Bool { acceptsEditing }
    func synchronize(photoID: String?, enabled: Bool) {
        if self.photoID != photoID || !enabled { finish(cancel: true) }
        self.photoID = photoID; self.acceptsEditing = enabled; isEnabled = enabled
    }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            window.acceptsMouseMovedEvents = true
            NotificationCenter.default.addObserver(self, selector: #selector(lostWindow), name: NSWindow.didResignKeyNotification, object: window)
        } else { finish(cancel: true) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func lostWindow() { finish(cancel: true) }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { finish(cancel: true) }
        super.setFrameSize(newSize)
    }
    override func resetCursorRects() { if acceptsEditing { addCursorRect(bounds, cursor: .resizeLeftRight) } }
    override func mouseMoved(with event: NSEvent) {
        guard acceptsEditing, !tracking else { return }
        selected = HistogramRegion.at(convert(event.locationInWindow, from: nil).x / max(1, bounds.width))
        hovered = true; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        guard acceptsEditing else { return }
        window?.makeFirstResponder(self)
        pointerX = convert(event.locationInWindow, from: nil).x
        selected = HistogramRegion.at(pointerX / max(1, bounds.width))
        delta = 0; tracking = begin?(selected) ?? false; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        let x = convert(event.locationInWindow, from: nil).x
        delta += (x - pointerX) * (event.modifierFlags.contains(.shift) ? 0.1 : 1)
        pointerX = x
        change?(delta / max(1, bounds.width) * (selected.range.upperBound - selected.range.lowerBound))
    }
    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        mouseDragged(with: event); finish(cancel: false)
    }
    func finish(cancel: Bool) {
        guard tracking else { return }
        tracking = false; end?(cancel); needsDisplay = true
    }
    override func resignFirstResponder() -> Bool { finish(cancel: true); needsDisplay = true; return true }
    override func cancelOperation(_ sender: Any?) { finish(cancel: true) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(cancel: true); return }
        guard acceptsEditing, !tracking, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 123 || event.keyCode == 124 {
            selected = HistogramRegion.allCases[min(4, max(0, selected.rawValue + (event.keyCode == 124 ? 1 : -1)))]; needsDisplay = true
        } else if event.keyCode == 125 || event.keyCode == 126 {
            nudge?(selected, event.keyCode == 126 ? 1 : -1)
        } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard acceptsEditing, hovered || tracking || window?.firstResponder === self else { return }
        let range = selected.fractions
        Palette.traceNeutral.withAlphaComponent(0.1).setFill()
        NSRect(x: range.lowerBound * bounds.width, y: 0, width: (range.upperBound - range.lowerBound) * bounds.width, height: bounds.height).fill()
        let value = values[selected.rawValue]
        let text = selected.title + "  " + String(format: selected == .exposure ? "%+.2f EV" : "%+.0f", value)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: Palette.scopeText]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = NSRect(x: (bounds.width - size.width) / 2 - 4, y: 3, width: size.width + 8, height: size.height + 2)
        Palette.scopeBackground.setFill(); box.fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1), withAttributes: attrs)
    }
}
