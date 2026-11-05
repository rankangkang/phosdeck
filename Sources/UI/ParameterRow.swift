import SwiftUI
import AppKit

/// `label | scale fader | value`. Double-click or context-menu the label to reset.
struct AdjustmentRow: View {
    let label: String
    let value: Double
    var range: ClosedRange<Double> = -100...100
    var step = 1.0
    var digits = 0
    var reset = 0.0
    var track: AdjustmentTrack = .tonal
    var unit: String?
    let change: (Double, Bool) -> Void
    let commit: () -> Void
    @Environment(\.isEnabled) private var enabled
    @FocusState private var editing: Bool
    @State private var draft: String?
    @State private var invalid = false
    private var bipolar: Bool { range.lowerBound < 0 && range.upperBound > 0 }
    private var modified: Bool { abs(value - reset) >= max(step, 1e-9) / 2 }
    private func bounded(_ v: Double) -> Double { v.isFinite ? min(range.upperBound, max(range.lowerBound, v)) : value }
    var body: some View {
        HStack(spacing: Metrics.gap) {
            labelView.frame(width: Metrics.rowLabel, alignment: .leading)
            slider.frame(height: 28)
            valueField.frame(width: Metrics.rowValue, alignment: .trailing)
        }.frame(minHeight: Metrics.row)
    }
    private var labelView: some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 13, weight: modified ? .semibold : .regular))
                .foregroundStyle(enabled ? Theme.text : Theme.textDisabled)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if modified { Circle().fill(Theme.accentSignal).frame(width: 4, height: 4).accessibilityHidden(true) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { change(bounded(reset), true) }
        .contextMenu { Button(L10n.text("app.reset", defaultValue: "Reset \(label)")) { change(bounded(reset), true) } }
        .help(L10n.text("app.doubleClickTheLabelToReset", defaultValue: "Double-click the label to reset"))
    }
    private var slider: some View {
        GradientAdjustmentSlider(value: value, range: range, step: step, neutral: reset, track: track, label: label,
                                 change: { change(bounded($0), false) }, commit: commit)
    }
    private var valueField: some View {
        HStack(spacing: 3) {
            TextField(label, text: Binding(get: { draft ?? Self.display(value, digits: digits, signed: bipolar) },
                                           set: { draft = $0; invalid = false }))
                .textFieldStyle(.plain).font(.value).multilineTextAlignment(.trailing)
                .foregroundStyle(enabled ? Theme.text : Theme.textDisabled)
                .padding(.horizontal, 3).frame(height: 20)
                .background {
                    if editing {
                        RoundedRectangle(cornerRadius: Metrics.inputRadius).fill(Theme.raised)
                            .overlay(RoundedRectangle(cornerRadius: Metrics.inputRadius)
                                .strokeBorder(invalid ? Theme.error : Theme.focusRing, lineWidth: invalid ? 1.5 : 1))
                    }
                }
                .focused($editing)
                .onSubmit { apply(); if !invalid { editing = false } }
                .onExitCommand { draft = nil; invalid = false; editing = false }
                .onChange(of: editing) {
                    guard !editing, draft != nil else { return }
                    apply()
                    if invalid { draft = nil; invalid = false }
                }
                .help(invalid ? L10n.text("app.enterANumberBetweenAnd", defaultValue: "Enter a number between \(Self.display(range.lowerBound, digits: digits, signed: false)) and \(Self.display(range.upperBound, digits: digits, signed: false))") : "")
                .accessibilityLabel(L10n.text("app.value", defaultValue: "\(label) value"))
            Text(unit ?? "").font(.caption11).foregroundStyle(Theme.textSecondary)
                .frame(width: Metrics.rowUnit, alignment: .leading).accessibilityHidden(unit == nil || unit?.isEmpty == true)
        }
    }
    private func apply() {
        guard let text = draft else { commit(); return }
        let cleaned = text.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let number = Double(cleaned), number.isFinite else { invalid = true; return }
        draft = nil; invalid = false
        change(bounded(number), false); commit()
    }
    static func display(_ value: Double, digits: Int, signed: Bool) -> String {
        let text = String(format: "%.\(digits)f", abs(value))
        if Double(text) == 0 { return text }
        return value < 0 ? "−" + text : signed ? "+" + text : text
    }
}

/// Track colours describe the parameter's direction; they are not a colour proof.
/// `nil` draws a plain inset well; task colours appear only where the axis has physical meaning.
enum AdjustmentTrack {
    case tonal, basic(String), mixer(Int, Int), hue, saturation(Double), luminance(Double)
    var colors: [NSColor]? {
        func gray(_ value: CGFloat) -> NSColor { NSColor(white: value, alpha: 1) }
        func color(_ hue: Double, _ saturation: CGFloat = 0.75, _ brightness: CGFloat = 0.85) -> NSColor {
            NSColor(calibratedHue: CGFloat((hue + 360).truncatingRemainder(dividingBy: 360) / 360), saturation: saturation, brightness: brightness, alpha: 1)
        }
        switch self {
        case .tonal: return nil
        case .hue: return stride(from: 0.0, through: 360.0, by: 60).map { color($0) }
        case .saturation(let hue): return [gray(0.55), color(hue, 1)]
        case .luminance(let hue): return [color(hue, 0.8, 0.12), color(hue), color(hue, 0.18, 1)]
        case .mixer(let band, let mode):
            let hue = HSLBand.centers[band]
            if mode == 0 { return [color(hue - 30), color(hue), color(hue + 30)] }
            return (mode == 1 ? Self.saturation(hue) : Self.luminance(hue)).colors
        case .basic(let name):
            switch name {
            case L10n.text("app.temperature", defaultValue: "Temperature"): return [color(225), gray(0.65), color(48)]
            case L10n.text("app.tint", defaultValue: "Tint"): return [color(120), gray(0.65), color(300)]
            case L10n.text("app.vibrance", defaultValue: "Vibrance"), L10n.text("app.saturation", defaultValue: "Saturation"): return [gray(0.5), color(55, 0.4), color(125, 0.65), color(230), color(315), color(0, 1)]
            default: return nil
            }
        }
    }
}

/// Native keyboard/accessibility and event handling for the physical fader.
struct GradientAdjustmentSlider: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let neutral: Double
    let track: AdjustmentTrack
    let label: String
    let change: (Double) -> Void
    let commit: () -> Void
    var tickCount = 5
    var valueDescription: String?
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> AdjustmentNSSlider {
        let slider = AdjustmentNSSlider()
        slider.sliderType = .linear
        slider.isContinuous = true
        slider.focusRingType = .none
        slider.target = slider; slider.action = #selector(AdjustmentNSSlider.changed)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: AdjustmentNSSlider, context: Context) {
        slider.isEnabled = enabled
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        slider.synchronizeValue(value)
        slider.step = step
        slider.resetValue = neutral
        slider.change = change; slider.commit = commit
        if slider.tickCount != tickCount { slider.tickCount = tickCount; slider.needsDisplay = true }
        slider.setAccessibilityValueDescription(valueDescription)
        if slider.accessibilityLabel() != label { slider.setAccessibilityLabel(label) }
        let colors = track.colors
        let marker = (neutral - range.lowerBound) / (range.upperBound - range.lowerBound)
        let bipolar = range.lowerBound < 0 && range.upperBound > 0
        if slider.trackColors != colors || slider.neutral != marker || slider.bipolar != bipolar {
            slider.trackColors = colors; slider.neutral = marker; slider.bipolar = bipolar
            slider.needsDisplay = true
        }
    }
}

final class AdjustmentNSSlider: NSSlider {
    var step = 1.0
    var resetValue = 0.0
    var change: ((Double) -> Void)?
    var commit: (() -> Void)?
    var trackColors: [NSColor]?
    var neutral = 0.5
    var bipolar = false
    var tickCount = 5
    private(set) var trackingMouse = false
    private var anchor: (position: CGFloat, value: Double) = (0, 0)
    private var fine = false

    // SwiftUI may deliver an older render while the native control is tracking.
    func synchronizeValue(_ value: Double) {
        if !trackingMouse, doubleValue != value { doubleValue = value }
    }
    override var isFlipped: Bool { true }
    @objc func changed() {
        doubleValue = min(maxValue, max(minValue, minValue + ((doubleValue - minValue) / step).rounded() * step))
        change?(doubleValue)
        if !trackingMouse { commit?() }
    }

    private var travel: ClosedRange<CGFloat> { (bounds.minX + 5.5)...max(bounds.minX + 6.5, bounds.maxX - 5.5) }
    private var trackY: CGFloat { floor(bounds.height / 2) - 2 }
    private var fraction: Double { maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0 }
    private func x(at fraction: Double) -> CGFloat { travel.lowerBound + CGFloat(fraction) * (travel.upperBound - travel.lowerBound) }
    private var capRect: NSRect { NSRect(x: x(at: fraction).rounded() - 4.5, y: trackY - 8, width: 9, height: 16) }
    private var focused: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = isEnabled
        let y = trackY
        let track = NSRect(x: bounds.minX + 1, y: y - 1.5, width: bounds.width - 2, height: 3)
        let well = NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1)
        Palette.seamLight.setFill()
        NSRect(x: track.minX + 1, y: track.maxY, width: track.width - 2, height: 1).fill()
        if enabled, let colors = trackColors, let gradient = NSGradient(colors: colors) { gradient.draw(in: well, angle: 0) }
        else { Palette.lampSocket.withAlphaComponent(enabled ? 0.65 : 0.25).setFill(); well.fill() }
        Palette.insetShadow.setFill()
        NSRect(x: track.minX + 1, y: track.minY, width: track.width - 2, height: 1).fill(using: .sourceOver)
        (enabled ? Palette.materialEdge : Palette.textDisabled).setStroke()
        well.lineWidth = 0.5; well.stroke()

        let ticks = NSBezierPath()
        for index in 0..<max(2, tickCount) {
            let f = Double(index) / Double(max(2, tickCount) - 1)
            if bipolar && abs(f - neutral) < 0.001 { continue }
            ticks.move(to: NSPoint(x: x(at: f), y: y + 4)); ticks.line(to: NSPoint(x: x(at: f), y: y + 7))
        }
        if bipolar && (0...1).contains(neutral) {
            ticks.move(to: NSPoint(x: x(at: neutral), y: y + 4)); ticks.line(to: NSPoint(x: x(at: neutral), y: y + 9))
        }
        (enabled ? Palette.textSecondary : Palette.textDisabled).setStroke()
        ticks.lineWidth = 1; ticks.stroke()

        let cap = capRect
        let capPath = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        if enabled {
            for (color, offset, blur) in [(Palette.keyAmbientShadow, 4.0, 4.0), (Palette.keyContactShadow, 1.5, 1.0)] {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = color; shadow.shadowOffset = NSSize(width: 0, height: -offset); shadow.shadowBlurRadius = blur
                shadow.set()
                Palette.capBottom.setFill(); capPath.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            Palette.keyLip.setFill(); capPath.fill()
            let face = NSBezierPath(roundedRect: cap.insetBy(dx: 0.75, dy: 0.5).offsetBy(dx: 0, dy: -0.5), xRadius: 2, yRadius: 2)
            NSGradient(starting: Palette.capTop, ending: Palette.capBottom)?.draw(in: face, angle: 90)
            Palette.keyHighlight.setFill()
            NSRect(x: cap.minX + 2, y: cap.minY + 1.5, width: cap.width - 4, height: 1).fill(using: .sourceOver)
        } else {
            Palette.surfacePanel.setFill(); capPath.fill()
        }
        (enabled ? (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Palette.controlBorder : Palette.materialEdge) : Palette.textDisabled).setStroke()
        capPath.lineWidth = 0.75; capPath.stroke()
        let active = enabled && (trackingMouse || focused)
        (active ? Palette.accentSignal : enabled ? Palette.textSecondary : Palette.textDisabled).setFill()
        NSRect(x: cap.minX + 2, y: y - (active ? 1 : 0.5), width: cap.width - 4, height: active ? 2 : 1).fill()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }
    /// Passing scroll wheel never edits a parameter.
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }

    private func nudge(_ direction: Double) -> Bool {
        guard isEnabled, step.isFinite, step > 0 else { return false }
        doubleValue = min(maxValue, max(minValue, doubleValue + direction*step))
        changed(); needsDisplay = true
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
        _ = nudge(event.keyCode == 124 || event.keyCode == 126 ? 1 : -1)
    }
    override func accessibilityPerformIncrement() -> Bool { nudge(1) }
    override func accessibilityPerformDecrement() -> Bool { nudge(-1) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            doubleValue = min(maxValue, max(minValue, resetValue))
            change?(doubleValue); commit?(); needsDisplay = true
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        PreviewLog.logger.debug("gesture-begin")
        trackingMouse = true
        fine = event.modifierFlags.contains(.shift)
        // Grabbing the cap never jumps; clicking the track moves the cap there first.
        if !capRect.insetBy(dx: -2, dy: -6).contains(point) {
            let f = (point.x - travel.lowerBound) / (travel.upperBound - travel.lowerBound)
            doubleValue = minValue + Double(min(1, max(0, f))) * (maxValue - minValue)
            changed()
        }
        anchor = (point.x, doubleValue)
        needsDisplay = true
        // Do not call super.mouseDown: NSSlider enters a synchronous tracking
        // loop there. Return to AppKit after every event so main-actor preview
        // work and SwiftUI/Metal display updates can run while the mouse is down.
    }

    override func mouseDragged(with event: NSEvent) {
        guard trackingMouse else { return }
        updateDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard trackingMouse else { return }
        updateDrag(event)
        finishDrag()
    }

    /// Shift reduces the drag ratio to one tenth, re-anchored whenever Shift changes.
    private func updateDrag(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        let position = point.x
        if shift != fine { anchor = (position, doubleValue); fine = shift }
        let distance = travel.upperBound - travel.lowerBound
        let delta = Double((position - anchor.position) / distance) * (maxValue - minValue) * (fine ? 0.1 : 1)
        doubleValue = min(maxValue, max(minValue, anchor.value + delta))
        changed()
        needsDisplay = true
    }

    private func finishDrag() {
        guard trackingMouse else { return }
        PreviewLog.logger.debug("gesture-end")
        trackingMouse = false
        needsDisplay = true
        commit?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
}
