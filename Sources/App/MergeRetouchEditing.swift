import Foundation
import Observation
import AppKit

@MainActor @Observable final class MergeRetouchState {
    var active = false
    var source = 0
    var radius = 0.025
    var hardness = 0.5
    var opacity = 1.0
    var restore = false
    var exclude = false
    var overlay = false
    var zoom = 0.0 // 0 = fit; 1 = one image pixel per backing pixel.
    var preview: MergeRetouchPreview?
    var pending = false
    var revision = 0
    private(set) var settings = MergeRetouchSettings()
    var strokes: [MergeRetouchStroke] { settings.strokes }
    var trailDraft = StarTrailSettings()
    var error: String?
    @ObservationIgnored private var savedSettings = MergeRetouchSettings()
    var hasChanges: Bool { settings != savedSettings }
    @ObservationIgnored let undo = UndoManager()

    func load(_ settings: MergeRetouchSettings) {
        self.settings = settings; savedSettings = settings; trailDraft = settings.trails
        undo.removeAllActions(); revision += 1
    }
    func replaceSettings(_ settings: MergeRetouchSettings) {
        guard self.settings != settings else { return }
        let previous = self.settings
        undo.registerUndo(withTarget:self) { $0.replaceSettings(previous) }
        undo.setActionName(L10n.text("merge.retouch.stroke",defaultValue:"Merge Correction"))
        self.settings = settings; trailDraft = settings.trails; revision += 1
    }
    func replace(_ strokes: [MergeRetouchStroke]) {
        var next = settings; next.strokes = strokes; replaceSettings(next)
    }
    func excludeSource(_ excluded: Bool,count: Int) {
        var next = settings
        if excluded { next.excludedSources.insert(source) } else { next.excludedSources.remove(source) }
        guard next.excludedSources.count < count else {
            error = L10n.text("merge.retouch.lastSource",defaultValue:"Keep at least one frame enabled."); return
        }
        error = nil; replaceSettings(next)
    }
    func commitTrails() {
        var next = settings; next.trails = trailDraft
        do { try next.trails.validate(); replaceSettings(next); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func add(_ points: [MaskPoint],sourceCount: Int) {
        guard !pending,!points.isEmpty else { return }
        let stroke = MergeRetouchStroke(source:source,points:points,radius:radius,hardness:hardness,opacity:opacity,restore:restore,exclude:exclude)
        do {
            try stroke.validate(count:sourceCount)
            guard strokes.count < 2048,strokes.reduce(points.count,{ $0+$1.points.count }) <= 131072 else { throw MergeRetouchProject.invalid }
            replace(strokes+[stroke]); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
