import CoreGraphics
import Foundation

enum SpotPointerAction: Equatable { case draw, move, source }

enum SpotPlacement {
    static let markerRadius: CGFloat = 4.5
    static let markerHitRadius: CGFloat = 8

    /// Unselected spots are only the visible dot. The selected spot grabs its whole brush,
    /// and the source is that same shape shifted by the offset.
    static func hit(point: MaskPoint, size: CGSize, repairs: [SpotRepair], selectedID: UUID?, offsets: [UUID: MaskPoint], markerRadius: Double) -> (id: UUID, action: SpotPointerAction)? {
        let active = repairs.filter { $0.enabled && !$0.points.isEmpty }.reversed()
        for repair in active where repair.id != selectedID {
            guard let first = repair.points.first else { continue }
            let distance = hypot((first.x - point.x) * size.width, (first.y - point.y) * size.height)
            if distance <= markerRadius { return (repair.id, .move) }
        }
        guard let selected = active.first(where: { $0.id == selectedID }) else { return nil }
        let reach = selected.radius * min(size.width, size.height)
        let target = distance(selected.points, point, size)
        if let offset = offsets[selected.id] {
            let shifted = selected.points.map { MaskPoint($0.x + offset.x, $0.y + offset.y) }
            let source = distance(shifted, point, size)
            if source <= reach, source < target { return (selected.id, .source) }
        }
        if target <= reach { return (selected.id, .move) }
        return nil
    }

    /// Moving the target keeps the offset, so the source follows. Same for every mode.
    static func moved(originalPoints: [MaskPoint], delta: MaskPoint, pinnedOffset: MaskPoint?) -> (points: [MaskPoint], offset: MaskPoint?) {
        (originalPoints.map { MaskPoint($0.x + delta.x, $0.y + delta.y) }, pinnedOffset)
    }

    static func clampedMove(_ points: [MaskPoint], from origin: MaskPoint, to point: MaskPoint) -> MaskPoint {
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return MaskPoint(0, 0) }
        return MaskPoint(min(1 - maxX, max(-minX, point.x - origin.x)), min(1 - maxY, max(-minY, point.y - origin.y)))
    }

    /// Source drag keeps the grabbed point under the cursor instead of jumping to the first dab.
    static func sourced(displayedOffset: MaskPoint, from origin: MaskPoint, to point: MaskPoint) -> MaskPoint {
        MaskPoint(min(2, max(-2, displayedOffset.x + point.x - origin.x)), min(2, max(-2, displayedOffset.y + point.y - origin.y)))
    }

    private static func distance(_ points: [MaskPoint], _ point: MaskPoint, _ size: CGSize) -> Double {
        points.map { hypot(($0.x - point.x) * size.width, ($0.y - point.y) * size.height) }.min() ?? .greatestFiniteMagnitude
    }
}

struct SpotEditGesture {
    var id: UUID
    var action: SpotPointerAction
    var origin: MaskPoint
    var originalPoints: [MaskPoint]
    var pinnedOffset: MaskPoint?
    var displayedOffset: MaskPoint
    /// Geometry shown while the pointer is down. The recipe changes once, on release.
    var livePoints: [MaskPoint]
    var liveOffset: MaskPoint?
    /// A stroke that has not been inserted yet. Nil when the gesture edits an existing repair.
    var pending: SpotRepair?
}

/// What the canvas draws during a spot gesture. Reading it does not publish the recipe.
struct SpotCanvasDraft: Equatable {
    var id: UUID
    var action: SpotPointerAction
    var points: [MaskPoint]
    var offset: MaskPoint?
    var radius: Double
}

extension AppModel {
    var spotInstruction: String {
        switch spotKind {
        case .clone: return L10n.text("app.copiesTheSourceColorAndTextureExactlyDragThe", defaultValue: "Copies the source color and texture exactly. Drag the source to choose another area; moving the target also moves the source. [ / ] changes size")
        case .heal: return L10n.text("app.usesSourceTextureWhileMatchingTheColorAroundThe", defaultValue: "Uses source texture while matching the color around the target. Move the source to a differently colored area to see how Heal differs from Clone. [ / ] changes size")
        case .remove: return L10n.text("app.usesTheHealAlgorithmAndAutomaticallySelectsASimilar", defaultValue: "Uses the Heal algorithm and automatically selects a similar nearby source. You can drag the source afterward. [ / ] changes size")
        }
    }
    func setSpotMode(_ enabled: Bool) {
        if enabled == spotMode { return }
        if enabled, !canEdit { return }
        if !enabled { finishSpotStroke() }
        guard commitRecipe() else { return }
        spotGesture = nil
        if enabled {
            maskGesture = nil
            maskMode = false
            cropMode = false
            before = false
            editMode = true
            spotMode = true
            prepareSpotRank()
        } else {
            spotMode = false
        }
        requestPreview()
    }
    func prepareSpotRank() {
        guard spotMode, let photo = active, photo.supportsEditing, let recipe,
              let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        let key = rankKey(recipe, photo: photo)
        if key == spotRankKey, spotRank != nil || spotRankTask != nil { return }
        let token = UUID()
        spotRankToken = token
        spotRankTask?.cancel()
        spotRankKey = key; spotRank = nil; spotGuides = [:]
        let request = ImageRequest(photo: photo, root: root, recipe: recipe)
        spotRankTask = Task { [weak self] in
            do {
                let buffer = try await ImagePipeline().linearRank(request)
                guard let self, !Task.isCancelled, token == self.spotRankToken, photo.id == self.activeID else { return }
                self.spotRankKey = key
                self.spotRank = buffer
                self.refreshSpotGuides()
                self.applyPendingSpotPins()
                self.noteDraftOffsetIfNeeded()
            } catch {
                guard let self, !Task.isCancelled, token == self.spotRankToken else { return }
                self.spotRankKey = nil
                self.error = error.localizedDescription
            }
            if token == self?.spotRankToken { self?.spotRankTask = nil }
        }
    }
    func refreshSpotGuides() {
        guard spotMode, let rank = spotRank, let repairs = recipe?.repairs else {
            if !spotGuides.isEmpty { spotGuides = [:] }
            return
        }
        let next = SpotRepairMath.guides(rank, repairs: repairs)
        if next != spotGuides { spotGuides = next }
    }
    var spotCanvasDraft: SpotCanvasDraft? {
        guard let gesture = spotGesture, !gesture.livePoints.isEmpty else { return nil }
        let radius = gesture.pending?.radius ?? recipe?.repairs.first(where: { $0.id == gesture.id })?.radius ?? spotRadius
        return SpotCanvasDraft(id: gesture.id, action: gesture.action, points: gesture.livePoints, offset: gesture.liveOffset, radius: radius)
    }
    func selectSpot(_ id: UUID?) {
        if selectedSpotID != id { cancelSpotSourceRefresh() }
        selectedSpotID = id
        guard let repair = recipe?.repairs.first(where: { $0.id == id }) else { return }
        spotKind = repair.mode
        spotRadius = repair.radius
        spotFeather = repair.feather
        spotOpacity = repair.opacity
    }
    func cancelSpotSourceRefresh() {
        spotSourceTask?.cancel(); spotSourceTask = nil; spotSourceToken = UUID(); refreshingSpotSource = false
    }
    func refreshSpotSource() {
        guard spotMode, canEdit, !refreshingSpotSource, spotGesture == nil, commitRecipe(),
              let photo = active, let original = recipe, let id = selectedSpotID,
              let repair = original.repairs.first(where: { $0.id == id }), repair.enabled,
              let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        refreshingSpotSource = true
        let token = UUID(); spotSourceToken = token
        let current = repair.sourceOffset ?? spotRenderedOffsets[id] ?? spotGuides[id]
        let request = ImageRequest(photo: photo, root: root, recipe: original)
        spotSourceTask = Task { [weak self] in
            do {
                let next = try await ImagePipeline().alternateSpotSource(request, selected: id, avoiding: current)
                guard let self, !Task.isCancelled, self.spotSourceToken == token, self.activeID == photo.id,
                      self.spotMode, self.selectedSpotID == id, self.recipe == original else { return }
                self.cancelSpotSourceRefresh()
                guard let next else { self.showNotice(L10n.text("app.noOtherCompleteNearbySourceDragTheSourceManually", defaultValue: "No other complete nearby source. Drag the source manually")); return }
                self.changeRecipe({ r in
                    guard let index = r.repairs.firstIndex(where: { $0.id == id }) else { return }
                    r.repairs[index].sourceOffset = next
                }, title: L10n.text("app.changeHealingSource", defaultValue: "Change Healing Source"))
                self.refreshSpotGuides()
            } catch {
                guard let self, !Task.isCancelled, self.spotSourceToken == token else { return }
                self.cancelSpotSourceRefresh(); self.error = error.localizedDescription
            }
        }
    }
    func setSpotKind(_ mode: SpotRepairMode) {
        spotKind = mode
        guard let id = selectedSpotID else { return }
        let resolved = spotGuides[id] ?? spotRenderedOffsets[id]
        changeRecipe({ recipe in
            guard let index = recipe.repairs.firstIndex(where: { $0.id == id }) else { return }
            recipe.repairs[index].mode = mode
            if recipe.repairs[index].sourceOffset == nil, let resolved {
                recipe.repairs[index].sourceOffset = resolved
            }
        }, title: L10n.text("app.spotRemovalMethod", defaultValue: "Spot Removal Method"))
        if recipe?.repairs.first(where: { $0.id == id })?.sourceOffset == nil {
            pendingSpotPins.insert(id)
            refreshSpotGuides()
        }
    }
    func setSpotRadius(_ value: Double, commit: Bool) {
        let next = min(0.5, max(0.001, value))
        spotRadius = next
        updateSelectedSpot(commit: commit, title: L10n.text("app.spotSize", defaultValue: "Spot Size")) { $0.radius = next }
    }
    func setSpotFeather(_ value: Double, commit: Bool) {
        let next = min(1, max(0, value))
        spotFeather = next
        updateSelectedSpot(commit: commit, title: L10n.text("app.spotFeather", defaultValue: "Spot Feather")) { $0.feather = next }
    }
    func setSpotOpacity(_ value: Double, commit: Bool) {
        let next = min(1, max(0, value))
        spotOpacity = next
        updateSelectedSpot(commit: commit, title: L10n.text("app.spotStrength", defaultValue: "Spot Strength")) { $0.opacity = next }
    }
    func nudgeSpotRadius(_ factor: Double) {
        setSpotRadius(spotRadius * factor, commit: true)
    }
    func toggleSpot(_ id: UUID) {
        let hiding = recipe?.repairs.first(where: { $0.id == id })?.enabled == true
        changeRecipe({ recipe in
            guard let index = recipe.repairs.firstIndex(where: { $0.id == id }) else { return }
            recipe.repairs[index].enabled.toggle()
        }, title: hiding ? L10n.text("app.hideSpotRemoval", defaultValue: "Hide Spot Removal") : L10n.text("app.showSpotRemoval", defaultValue: "Show Spot Removal"))
        refreshSpotGuides()
    }
    func deleteSpot(_ id: UUID) {
        guard commitRecipe() else { return }
        changeRecipe({ $0.repairs.removeAll { $0.id == id } }, title: L10n.text("app.deleteSpotRemoval", defaultValue: "Delete Spot Removal"))
        if selectedSpotID == id { selectSpot(nil) }
        refreshSpotGuides()
    }
    func spotPointer(_ output: CGPoint, phase: MaskPointerPhase, markerRadius: Double = 0) {
        guard spotMode, canEdit, canvasCoordinatesCurrent, !before, let recipe, let size = orientedSourceSize else { return }
        if let point = MaskGeometry.sourcePoint(output, size: size, recipe: recipe) {
            switch phase {
            case .down: beginSpot(at: point, size: size, recipe: recipe, markerRadius: markerRadius)
            case .drag, .up: updateSpot(to: point, size: size)
            }
        }
        if phase == .up {
            finishSpotStroke()
            _ = commitRecipe(title: L10n.text("app.spotRemoval", defaultValue: "Spot Removal"))
        }
    }

    private func rankKey(_ recipe: EditRecipe, photo: Photo) -> String {
        let temperature = recipe.asShotWhiteBalance ? recipe.baselineTemperature : recipe.temperature
        let tint = recipe.asShotWhiteBalance ? recipe.baselineTint : recipe.tint
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let details = (try? encoder.encode(recipe.rawDetails)).map { $0.base64EncodedString() } ?? ""
        return [photo.id, recipe.sourceDigest, recipe.decoderVersion, String(recipe.exposure), String(recipe.baselineExposure),
                String(temperature), String(tint), String(recipe.asShotWhiteBalance), details].joined(separator: "|")
    }
    private func beginSpot(at point: MaskPoint, size: CGSize, recipe: EditRecipe, markerRadius: Double) {
        guard commitRecipe() else { return }
        cancelSpotSourceRefresh()
        if let hit = hitSpot(point, size: size, recipe: recipe, markerRadius: markerRadius) {
            selectSpot(hit.id)
            let repair = recipe.repairs.first { $0.id == hit.id }
            let pinned = repair?.sourceOffset
            let displayed = pinned ?? spotRenderedOffsets[hit.id] ?? spotGuides[hit.id] ?? MaskPoint(0, 0)
            let points = repair?.points ?? []
            spotGesture = SpotEditGesture(id: hit.id, action: hit.action, origin: point, originalPoints: points, pinnedOffset: pinned, displayedOffset: displayed, livePoints: points, liveOffset: pinned, pending: nil)
            return
        }
        guard recipe.repairs.count < 128 else { error = L10n.text("app.upTo128SpotRemovalsAreSupported", defaultValue: "Up to 128 spot removals are supported"); return }
        var repair = SpotRepair(mode: spotKind, points: [point], radius: spotRadius, feather: spotFeather, opacity: spotOpacity)
        let offset = spotRank.map { SpotRepairMath.pickOffset(in: $0, repair: repair) }
        repair.sourceOffset = offset
        spotGesture = SpotEditGesture(id: repair.id, action: .draw, origin: point, originalPoints: [point], pinnedOffset: nil, displayedOffset: offset ?? MaskPoint(0, 0), livePoints: [point], liveOffset: offset, pending: repair)
    }
    /// Rank arrived while a new stroke is still on the canvas. Keep the picked source on the gesture.
    private func noteDraftOffsetIfNeeded() {
        guard var gesture = spotGesture, gesture.action == .draw, gesture.liveOffset == nil,
              let rank = spotRank, let pending = gesture.pending else { return }
        gesture.liveOffset = SpotRepairMath.pickOffset(in: rank, repair: pending)
        spotGesture = gesture
    }
    private func updateSpot(to point: MaskPoint, size: CGSize) {
        guard var gesture = spotGesture else { return }
        switch gesture.action {
        case .draw:
            let radius = gesture.pending?.radius ?? recipe?.repairs.first(where: { $0.id == gesture.id })?.radius ?? spotRadius
            let short = min(size.width, size.height)
            let spacing = max(0.25, radius * short * 0.2)
            guard let last = gesture.livePoints.last, gesture.livePoints.count < 4096 else { return }
            let distance = hypot((point.x - last.x) * size.width, (point.y - last.y) * size.height)
            guard distance >= spacing else { return }
            gesture.livePoints.append(point)
        case .move:
            guard recipe?.repairs.contains(where: { $0.id == gesture.id }) == true else { return }
            let delta = SpotPlacement.clampedMove(gesture.originalPoints, from: gesture.origin, to: point)
            let placed = SpotPlacement.moved(originalPoints: gesture.originalPoints, delta: delta, pinnedOffset: gesture.pinnedOffset)
            gesture.livePoints = placed.points
            gesture.liveOffset = placed.offset
        case .source:
            guard recipe?.repairs.contains(where: { $0.id == gesture.id }) == true else { return }
            gesture.liveOffset = SpotPlacement.sourced(displayedOffset: gesture.displayedOffset, from: gesture.origin, to: point)
        }
        spotGesture = gesture
        // The outline follows the pointer locally. Move and source refresh pixels on a timer;
        // a new stroke waits until release so painting does not republish the recipe.
        if gesture.action != .draw { scheduleSpotPreview() }
    }
    private func livePreviewRecipe() -> EditRecipe? {
        guard var value = recipe, let gesture = spotGesture, gesture.action != .draw,
              let index = value.repairs.firstIndex(where: { $0.id == gesture.id }) else { return nil }
        value.repairs[index].points = gesture.livePoints
        value.repairs[index].sourceOffset = gesture.liveOffset
        return value
    }
    private func scheduleSpotPreview() {
        guard !spotPreviewPending else { return }
        spotPreviewPending = true
        requestPreview(interactive: true, override: livePreviewRecipe())
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self else { return }
            self.spotPreviewPending = false
            if let action = self.spotGesture?.action, action != .draw { self.scheduleSpotPreview() }
        }
    }
    private func finishSpotStroke() {
        guard let gesture = spotGesture else { return }
        spotGesture = nil
        if var repair = gesture.pending {
            repair.points = gesture.livePoints
            repair.sourceOffset = gesture.liveOffset
            guard !repair.points.isEmpty else { return }
            changeRecipe({ recipe in
                guard !recipe.repairs.contains(where: { $0.id == repair.id }) else { return }
                recipe.repairs.append(repair)
            }, commit: false, preview: false)
            if recipe?.repairs.contains(where: { $0.id == repair.id }) == true { selectedSpotID = repair.id }
            if repair.sourceOffset == nil { pendingSpotPins.insert(repair.id) }
            return
        }
        changeRecipe({ recipe in
            guard let index = recipe.repairs.firstIndex(where: { $0.id == gesture.id }) else { return }
            recipe.repairs[index].points = gesture.livePoints
            recipe.repairs[index].sourceOffset = gesture.liveOffset
        }, commit: false, preview: false)
    }
    private func applyPendingSpotPins() {
        let ids = pendingSpotPins
        pendingSpotPins = []
        var updates: [UUID: MaskPoint] = [:]
        for id in ids {
            guard let repair = recipe?.repairs.first(where: { $0.id == id }), repair.sourceOffset == nil,
                  let offset = spotGuides[id] else { continue }
            updates[id] = offset
        }
        guard !updates.isEmpty else { return }
        changeRecipe { recipe in
            for (id, offset) in updates {
                guard let index = recipe.repairs.firstIndex(where: { $0.id == id }), recipe.repairs[index].sourceOffset == nil else { continue }
                recipe.repairs[index].sourceOffset = offset
            }
        }
    }
    private func updateSelectedSpot(commit: Bool, title: String, _ edit: @escaping (inout SpotRepair) -> Void) {
        guard let id = selectedSpotID, recipe?.repairs.contains(where: { $0.id == id }) == true else {
            if commit { _ = commitRecipe(title: title) }
            return
        }
        changeRecipe({ recipe in
            guard let index = recipe.repairs.firstIndex(where: { $0.id == id }) else { return }
            edit(&recipe.repairs[index])
        }, commit: commit, title: title)
        refreshSpotGuides()
    }
    private func hitSpot(_ point: MaskPoint, size: CGSize, recipe: EditRecipe, markerRadius: Double) -> (id: UUID, action: SpotPointerAction)? {
        var offsets: [UUID: MaskPoint] = [:]
        for repair in recipe.repairs {
            if let offset = repair.sourceOffset ?? spotRenderedOffsets[repair.id] ?? spotGuides[repair.id] {
                offsets[repair.id] = offset
            }
        }
        guard showSpotGuides else { return nil }
        return SpotPlacement.hit(point: point, size: size, repairs: recipe.repairs, selectedID: selectedSpotID, offsets: offsets, markerRadius: markerRadius)
    }
}
