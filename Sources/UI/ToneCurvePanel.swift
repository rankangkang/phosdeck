import SwiftUI
import AppKit

struct ToneCurvePanel: View {
    var curves: ToneCurves
    var change: (ToneCurves, Bool) -> Void
    var commit: () -> Void
    @State private var channel = 0
    @State private var point = 2
    private var selected: Int { min(point, curves.channels[channel].count - 1) }
    private var points: [CurvePoint] { curves.channels[channel] }
    private var current: CurvePoint { points[selected] }
    private func move(x: Double, y: Double, save: Bool) {
        var value = curves
        value.move(channel: channel, point: selected, x: x, y: y)
        change(value, save)
    }
    var body: some View {
        VStack(spacing: 0) {
            KeyRow(title: L10n.text("app.curveChannel", defaultValue: "Curve Channel"), options: (0..<4).map { KeyOption($0, ToneCurves.names[$0]) }, selection: $channel, expand: true)
            Bracket().stroke(Theme.textSecondary, lineWidth: 1).frame(height: 12).padding(.horizontal, 2).padding(.bottom, 4)
                .accessibilityHidden(true)
            ScopeDisplay {
                VStack(spacing: 0) {
                    ToneCurveGraph(curves: curves, channel: channel, selected: selected,
                        select: { point = $0 }, change: change, commit: commit).frame(height: 185)
                    Theme.scopeGrid.frame(height: 1)
                    Text(String(format: L10n.text("app.input1fOutput1f", defaultValue: "Input %.1f%% → Output %.1f%%"), current.x*100, current.y*100))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.scopeText)
                        .frame(maxWidth: .infinity).frame(height: 22)
                }
            }.padding(.bottom, 10)
            HStack(spacing: 8) {
                Picker(L10n.text("app.controlPoints", defaultValue: "Control Points"), selection: Binding(get: { selected }, set: { point = $0 })) {
                    ForEach(points.indices, id: \.self) { i in
                        Text(String(format: "%d · %.1f%%", i+1, points[i].x*100)).tag(i)
                    }
                }.labelsHidden().accessibilityLabel(L10n.text("app.curveControlPoints", defaultValue: "Curve Control Points")).frame(maxWidth: .infinity)
                Text("\(points.count)/16").font(.caption11).foregroundStyle(Theme.textSecondary)
                Button(L10n.text("app.added", defaultValue: "Added")) {
                    var value = curves
                    let i = min(selected, points.count-2), x = (points[i].x+points[i+1].x)/2
                    if let added = value.insert(channel: channel, x: x, y: TonalPipeline.evaluate(points, at: x)) {
                        point = added; change(value, true)
                    }
                }.buttonStyle(.key).controlUnavailable(points.count >= ToneCurves.maxPoints || points[min(selected,points.count-2)+1].x-points[min(selected,points.count-2)].x < 2*ToneCurves.minimumSpacing)
                Button(L10n.text("app.delete", defaultValue: "Delete")) {
                    var value = curves
                    if value.remove(channel: channel, point: selected) { point = max(0, selected-1); change(value, true) }
                }.buttonStyle(.key).controlUnavailable(selected == 0 || selected == points.count-1)
            }.padding(.bottom, 4)
            AdjustmentRow(label: L10n.text("app.input", defaultValue: "Input %"), value: current.x*100, range: 0...100, step: 0.1, digits: 1, reset: current.x*100,
                change: { v, save in move(x: v/100, y: current.y, save: save) }, commit: commit)
                .controlUnavailable(selected == 0 || selected == points.count-1).id("x-\(channel)-\(selected)")
            AdjustmentRow(label: L10n.text("app.output", defaultValue: "Output %"), value: current.y*100, range: 0...100, step: 0.1, digits: 1, reset: current.x*100,
                change: { v, save in move(x: current.x, y: v/100, save: save) }, commit: commit).id("y-\(channel)-\(selected)")
            HStack {
                Button(L10n.text("app.resetCurrentChannel", defaultValue: "Reset Current Channel")) { var value = curves; value.channels[channel] = ToneCurves.identity; point = 2; change(value, true) }
                    .buttonStyle(.key)
                Spacer()
            }.padding(.vertical, 6)
            Text(L10n.text("app.doubleClickEmptySpaceToAddAPointDrag", defaultValue: "Double-click empty space to add a point; drag points or use arrow keys. Shift accelerates, [ / ] selects points, and Delete removes interior points. Endpoint inputs are fixed; up to 16 points with ≥0.1% spacing. The title reset button resets all channels. Luminance preserves RGB ratios."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ToneCurveGraph: NSViewRepresentable {
    let curves: ToneCurves
    let channel: Int
    let selected: Int
    let select: (Int) -> Void
    let change: (ToneCurves, Bool) -> Void
    let commit: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> CurveNSView { CurveNSView() }
    func updateNSView(_ view: CurveNSView, context: Context) {
        view.curves = curves; view.channel = channel; view.selected = selected
        view.select = select; view.change = change; view.commit = commit; view.isEnabled = enabled
        view.setAccessibilityElement(true); view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(L10n.text("app.curveGraph", defaultValue: "\(ToneCurves.names[channel]) Curve Graph"))
        view.setAccessibilityValue(String(format: L10n.text("app.controlPointDInput1fOutput1f", defaultValue: "Control point %d, input %.1f%%, output %.1f%%"), selected+1,
            curves.channels[channel][selected].x*100, curves.channels[channel][selected].y*100))
        view.setAccessibilityHelp(L10n.text("app.doubleClickToAddPointsArrowsToMoveShift", defaultValue: "Double-click to add points, arrows to move, Shift to accelerate, brackets to select, and Delete to remove interior points"))
        view.needsDisplay = true
    }
}

/// Native first responder: graph keys must never navigate or rate photographs.
final class CurveNSView: NSControl {
    var curves = ToneCurves()
    var channel = 0
    var selected = 2
    var select: ((Int) -> Void)?
    var change: ((ToneCurves, Bool) -> Void)?
    var commit: (() -> Void)?
    private var dragging = false
    private var edited = false
    private var offset = CGPoint.zero
    override var acceptsFirstResponder: Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool { isEnabled && (window?.makeFirstResponder(self) ?? false) }
    private var plot: CGRect { bounds.insetBy(dx: 10, dy: 10) }
    private var points: [CurvePoint] { curves.channels[channel] }
    private func location(_ p: CurvePoint) -> CGPoint { CGPoint(x: plot.minX+p.x*plot.width, y: plot.minY+p.y*plot.height) }
    private func choose(_ i: Int) { selected = min(points.count-1, max(0,i)); select?(selected); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { finish(); needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
        let grid = NSBezierPath()
        for x in ToneCurves.grid {
            grid.move(to: location(CurvePoint(x:x,y:0))); grid.line(to: location(CurvePoint(x:x,y:1)))
            grid.move(to: location(CurvePoint(x:0,y:x))); grid.line(to: location(CurvePoint(x:1,y:x)))
        }
        Palette.scopeGrid.setStroke(); grid.lineWidth = 1; grid.stroke()
        let diagonal = NSBezierPath(); diagonal.move(to: location(CurvePoint(x:0,y:0))); diagonal.line(to: location(CurvePoint(x:1,y:1)))
        diagonal.setLineDash([3,3], count: 2, phase: 0); Palette.scopeAxis.setStroke(); diagonal.stroke()
        let color = [Palette.traceNeutral, Palette.traceRed, Palette.traceGreen, Palette.traceBlue][channel]
        let path = NSBezierPath()
        for i in 0...256 {
            let x = Double(i)/256, p = location(CurvePoint(x:x,y:TonalPipeline.evaluate(points,at:x)))
            if i == 0 { path.move(to:p) } else { path.line(to:p) }
        }
        color.setStroke(); path.lineWidth = 2; path.stroke()
        for i in points.indices {
            let p = location(points[i]), r = i == selected ? 5.0 : 3.5
            color.setFill(); NSBezierPath(ovalIn: CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r)).fill()
            if i == selected {
                Palette.traceActive.setStroke()
                NSBezierPath(ovalIn: CGRect(x:p.x-r-2,y:p.y-r-2,width:2*r+4,height:2*r+4)).stroke()
            }
        }
        if window?.firstResponder === self {
            Palette.traceActive.setStroke(); let ring = NSBezierPath(rect: bounds.insetBy(dx: 1,dy: 1)); ring.lineWidth = 2; ring.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let nearest = points.indices.min { a,b in
            let pa = location(points[a]), pb = location(points[b])
            return hypot(pa.x-p.x,pa.y-p.y) < hypot(pb.x-p.x,pb.y-p.y)
        }!
        let hit = location(points[nearest])
        if hypot(hit.x-p.x,hit.y-p.y) <= 11 { choose(nearest) }
        else if event.clickCount == 2 {
            guard let i = curves.insert(channel:channel,x:(p.x-plot.minX)/plot.width,y:(p.y-plot.minY)/plot.height) else { return }
            choose(i); change?(curves,false); edited = true
        } else { return }
        let anchor = location(points[selected]); offset = CGPoint(x:anchor.x-p.x,y:anchor.y-p.y); dragging = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, isEnabled else { return }
        let p = convert(event.locationInWindow, from:nil)
        curves.move(channel:channel,point:selected,x:(p.x+offset.x-plot.minX)/plot.width,y:(p.y+offset.y-plot.minY)/plot.height)
        change?(curves,false); edited = true; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { finish() }
    private func finish() { dragging = false; if edited { edited = false; commit?() } }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { finish() }; super.viewWillMove(toWindow:newWindow) }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { super.keyDown(with:event); return }
        let key = event.charactersIgnoringModifiers
        if key == "[" { choose(selected-1); return }; if key == "]" { choose(selected+1); return }
        if event.keyCode == 115 { choose(0); return }; if event.keyCode == 119 { choose(points.count-1); return }
        if [51,117].contains(event.keyCode) {
            if curves.remove(channel:channel,point:selected) { choose(selected-1); change?(curves,true) }; return
        }
        guard [123,124,125,126].contains(event.keyCode) else { super.keyDown(with:event); return }
        var p = points[selected]; let step = event.modifierFlags.contains(.shift) ? 0.01 : 0.001
        if event.keyCode == 123 { p.x -= step }; if event.keyCode == 124 { p.x += step }
        if event.keyCode == 125 { p.y -= step }; if event.keyCode == 126 { p.y += step }
        curves.move(channel:channel,point:selected,x:p.x,y:p.y); change?(curves,true); needsDisplay = true
    }
}
