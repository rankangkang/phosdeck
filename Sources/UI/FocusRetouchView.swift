import SwiftUI
import AppKit

struct FocusRetouchControls: View {
    @Bindable var session: PhotoMergeSession
    @Bindable var state: FocusRetouchState
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            SubgroupLabel(L10n.text("merge.retouch.title",defaultValue:"Focus Retouching"))
            Picker(L10n.text("merge.retouch.source",defaultValue:"Source"),selection:$state.source) {
                ForEach(Array(session.inputs.enumerated()),id:\.offset) { index,input in
                    Text("\(index+1) · \(input.photo.name)").tag(index)
                }
            }
            HStack {
                Button(L10n.text("merge.retouch.previous",defaultValue:"Previous")) { state.source -= 1 }
                    .disabled(state.source == 0)
                Button(L10n.text("merge.retouch.next",defaultValue:"Next")) { state.source += 1 }
                    .disabled(state.source+1 >= session.inputs.count)
            }.buttonStyle(.key)
            Toggle(L10n.text("merge.retouch.restore",defaultValue:"Restore Automatic Result"),isOn:$state.restore).toggleStyle(.instrument)
            AdjustmentRow(label:L10n.text("merge.retouch.radius",defaultValue:"Radius"),value:state.radius*100,range:0.01...50,step:0.1,digits:2,unit:"%",
                change:{ value,_ in state.radius = value/100 },commit:{})
            AdjustmentRow(label:L10n.text("merge.retouch.hardness",defaultValue:"Hardness"),value:state.hardness*100,range:0...100,step:1,digits:0,unit:"%",
                change:{ value,_ in state.hardness = value/100 },commit:{})
            AdjustmentRow(label:L10n.text("merge.retouch.opacity",defaultValue:"Opacity"),value:state.opacity*100,range:0...100,step:1,digits:0,unit:"%",
                change:{ value,_ in state.opacity = value/100 },commit:{})
            HStack {
                Button(L10n.text("app.undo_244",defaultValue:"Undo")) { state.undo.undo() }.disabled(!state.undo.canUndo || state.pending)
                Button(L10n.text("app.redo_245",defaultValue:"Redo")) { state.undo.redo() }.disabled(!state.undo.canRedo || state.pending)
                Button(L10n.text("merge.retouch.reset",defaultValue:"Reset")) { state.replace([]) }.disabled(state.strokes.isEmpty || state.pending)
            }.buttonStyle(.key)
            Toggle(L10n.text("merge.retouch.overlay",defaultValue:"Show Stroke Paths"),isOn:$state.overlay).toggleStyle(.instrument)
            Text(L10n.text("merge.retouch.hint",defaultValue:"Paint on the result to copy the selected aligned source. Space-drag or scroll to pan; left/right arrows switch sources. Escape cancels the current stroke. Corrections are saved with the new master."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal:false,vertical:true)
        }
            .onChange(of:state.source) { session.refreshRetouch() }
            .onChange(of:state.revision) { session.refreshRetouch() }
    }
}

struct FocusRetouchView: View {
    @Bindable var state: FocusRetouchState
    let sourceCount: Int
    let enabled: Bool
    let mat: PhotoMat
    var body: some View {
        VStack(spacing:6) {
            HStack(spacing:8) {
                Text(L10n.text("merge.retouch.source",defaultValue:"Source")).frame(maxWidth:.infinity,alignment:.leading)
                HStack(spacing:6) {
                Text(L10n.text("merge.retouch.result",defaultValue:"Result"))
                Spacer(minLength:0)
                Button(L10n.text("merge.retouch.fit",defaultValue:"Fit")) { state.zoom = 0 }.buttonStyle(.key(height:24))
                Button("100%") { state.zoom = 1 }.buttonStyle(.key(height:24))
                Button("200%") { state.zoom = 2 }.buttonStyle(.key(height:24))
                }.frame(maxWidth:.infinity)
            }.font(.caption11)
            FocusRetouchCanvas(state:state,sourceCount:sourceCount,enabled:enabled,mat:mat)
                .overlay(alignment:.bottom) {
                    if state.pending {
                        Text(L10n.text("merge.retouch.rendering",defaultValue:"Preparing full-size comparison…"))
                            .font(.caption11).padding(6).background(Theme.inset).allowsHitTesting(false)
                    }
                }
            if let error = state.error { Text(error).font(.caption11).foregroundStyle(Theme.warning).textSelection(.enabled) }
        }
    }
}

struct FocusRetouchCanvas: NSViewRepresentable {
    var state: FocusRetouchState
    var sourceCount: Int
    var enabled: Bool
    var mat: PhotoMat
    func makeNSView(context: Context) -> FocusRetouchNSView { FocusRetouchNSView() }
    func updateNSView(_ view: FocusRetouchNSView,context: Context) {
        view.state = state; view.sourceCount = sourceCount; view.mat = mat; view.interactionEnabled = enabled
        // Read only here: updates remain confined to the comparison canvas.
        _ = state.preview; _ = state.pending; _ = state.zoom; _ = state.radius
        _ = state.overlay; _ = state.strokes; _ = state.restore
        if state.pending || !enabled { view.cancelStroke() }
        view.needsDisplay = true
    }
}

final class FocusRetouchNSView: NSView {
    var state: FocusRetouchState?
    var sourceCount = 0
    var interactionEnabled = true
    var mat = PhotoMat.dark
    private var center = CGPoint(x:0.5,y:0.5)
    private var points: [MaskPoint] = []
    private var panStart: CGPoint?
    private var cursor: CGPoint?
    private var space = false
    private var tracking: NSTrackingArea?
    private var focusObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { state?.undo }
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L10n.text("merge.retouch.canvas",defaultValue:"Focus source and result comparison"))
        setAccessibilityIdentifier("focus-retouch-canvas")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var panes: [CGRect] {
        let width = max(1,(bounds.width-8)/2)
        return [CGRect(x:0,y:0,width:width,height:bounds.height),CGRect(x:width+8,y:0,width:width,height:bounds.height)]
    }
    private func imageRect(in pane: CGRect) -> CGRect {
        guard let state,let pair = state.preview else { return .zero }
        let scale = state.zoom == 0 ? min(pane.width/Double(pair.width),pane.height/Double(pair.height)) : state.zoom/(window?.backingScaleFactor ?? 1)
        let size = CGSize(width:Double(pair.width)*scale,height:Double(pair.height)*scale)
        let c = state.zoom == 0 ? CGPoint(x:0.5,y:0.5) : center
        return CGRect(x:pane.midX-c.x*size.width,y:pane.midY-c.y*size.height,width:size.width,height:size.height)
    }
    private func point(_ p: CGPoint) -> MaskPoint? {
        let pane = panes[1], rect = imageRect(in:pane)
        guard rect.width > 0,rect.height > 0,pane.contains(p),rect.contains(p) else { return nil }
        return MaskPoint((p.x-rect.minX)/rect.width,(p.y-rect.minY)/rect.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        mat.nsColor.setFill(); bounds.fill()
        guard let state,let pair = state.preview,let cg = NSGraphicsContext.current?.cgContext else { return }
        for (pane,image) in zip(panes,[pair.source,pair.result]) {
            let rect = imageRect(in:pane)
            cg.saveGState(); cg.clip(to:pane)
            NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height)).draw(in:rect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.none.rawValue])
            cg.restoreGState()
        }
        let pane = panes[1], rect = imageRect(in:pane)
        cg.saveGState(); cg.clip(to:pane.intersection(rect))
        func path(_ points: [MaskPoint],radius: Double,restore: Bool) {
            guard let first = points.first else { return }
            let line = NSBezierPath(); line.lineCapStyle = .round; line.lineJoinStyle = .round
            func position(_ p: MaskPoint) -> CGPoint { CGPoint(x:rect.minX+p.x*rect.width,y:rect.minY+p.y*rect.height) }
            let start = position(first); line.move(to:start)
            if points.count == 1 { line.line(to:CGPoint(x:start.x+0.01,y:start.y)) }
            for point in points.dropFirst() { line.line(to:position(point)) }
            line.lineWidth = max(1,radius*min(rect.width,rect.height)*2)
            (restore ? NSColor.white : Palette.accentSignal).withAlphaComponent(0.22).setStroke(); line.stroke()
        }
        if state.overlay { for stroke in state.strokes { path(stroke.points,radius:stroke.radius,restore:stroke.restore) } }
        path(points,radius:state.radius,restore:state.restore)
        if let cursor,point(cursor) != nil,!space {
            let r = state.radius*min(rect.width,rect.height)
            let outline = NSBezierPath(ovalIn:CGRect(x:cursor.x-r,y:cursor.y-r,width:2*r,height:2*r))
            NSColor.black.setStroke(); outline.lineWidth = 3; outline.stroke()
            NSColor.white.setStroke(); outline.lineWidth = 1; outline.stroke()
        }
        cg.restoreGState()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        if let window {
            focusObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelStroke(); self?.space = false }
            }
        }
        cancelStroke(); space = false
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.inVisibleRect,.mouseMoved,.mouseEnteredAndExited],owner:self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { cursor = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { cursor = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow,from:nil)
        guard interactionEnabled else { return }
        if space { panStart = p; return }
        guard state?.pending == false,let point = point(p) else { return }
        points = [point]; cursor = p; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        if let last = panStart { pan(dx:p.x-last.x,dy:p.y-last.y); panStart = p; return }
        guard !points.isEmpty,let next = point(p) else { return }
        if points.count < 8192 { points.append(next) }
        else { cancelStroke(); state?.error = L10n.text("merge.retouch.longStroke",defaultValue:"This stroke is too long. Paint shorter strokes.") }
        cursor = p; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { points = []; panStart = nil; needsDisplay = true }
        if interactionEnabled,!points.isEmpty { state?.add(points,sourceCount:sourceCount) }
    }
    private func pan(dx: Double,dy: Double) {
        let rect = imageRect(in:panes[1])
        guard rect.width > 0,rect.height > 0,state?.zoom != 0 else { return }
        center.x = min(1,max(0,center.x-dx/rect.width)); center.y = min(1,max(0,center.y-dy/rect.height)); needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) { cancelStroke(); pan(dx:event.scrollingDeltaX,dy:event.scrollingDeltaY) }
    override func keyDown(with event: NSEvent) {
        guard interactionEnabled,let state else { return }
        switch event.keyCode {
        case 49: cancelStroke(); space = true
        case 53: cancelStroke()
        case 123: cancelStroke(); state.source = max(0,state.source-1)
        case 124: cancelStroke(); state.source = min(sourceCount-1,state.source+1)
        case 33: state.radius = max(0.0001,state.radius/1.2)
        case 30: state.radius = min(0.5,state.radius*1.2)
        default: super.keyDown(with:event)
        }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { space = false; panStart = nil } else { super.keyUp(with:event) } }
    override func resignFirstResponder() -> Bool { cancelStroke(); space = false; return super.resignFirstResponder() }
    func cancelStroke() { points = []; panStart = nil; needsDisplay = true }
}
