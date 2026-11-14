import Foundation
import Observation
import AppKit

@MainActor @Observable final class FocusRetouchState {
    var active = false
    var source = 0
    var radius = 0.025
    var hardness = 0.5
    var opacity = 1.0
    var restore = false
    var overlay = false
    var zoom = 0.0 // 0 = fit; 1 = one image pixel per backing pixel.
    var preview: FocusRetouchPreview?
    var pending = false
    var revision = 0
    private(set) var strokes: [FocusRetouchStroke] = []
    var error: String?
    @ObservationIgnored private var savedStrokes: [FocusRetouchStroke] = []
    var hasChanges: Bool { strokes != savedStrokes }
    @ObservationIgnored let undo = UndoManager()

    func load(_ strokes: [FocusRetouchStroke]) {
        self.strokes = strokes; savedStrokes = strokes; undo.removeAllActions(); revision += 1
    }
    func replace(_ strokes: [FocusRetouchStroke]) {
        guard self.strokes != strokes else { return }
        let previous = self.strokes
        undo.registerUndo(withTarget:self) { $0.replace(previous) }
        undo.setActionName(L10n.text("merge.retouch.stroke",defaultValue:"Focus Correction"))
        self.strokes = strokes; revision += 1
    }
    func add(_ points: [MaskPoint],sourceCount: Int) {
        guard !pending,!points.isEmpty else { return }
        let stroke = FocusRetouchStroke(source:source,points:points,radius:radius,hardness:hardness,opacity:opacity,restore:restore)
        do {
            try stroke.validate(count:sourceCount)
            guard strokes.count < 2048, strokes.reduce(points.count,{ $0+$1.points.count }) <= 131072 else { throw FocusMergeProject.invalid }
            replace(strokes+[stroke]); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
