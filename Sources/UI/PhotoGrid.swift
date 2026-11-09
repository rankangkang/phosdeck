import SwiftUI
import AppKit

struct PhotoGrid: NSViewRepresentable {
    @Bindable var model: AppModel
    var film = false
    var filmHeight: Double = 84
    var mat = PhotoMat.dark
    /// Set only for a regular collection in manual-order mode. Grid and
    /// filmstrip share this bridge so the catalog remains the single order
    /// authority across both presentations.
    var ordering: CollectionOrdering? = nil
    func makeCoordinator() -> Coordinator { Coordinator(model: model, film: film, ordering: ordering) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll: NSScrollView = film ? FilmstripScrollView() : NSScrollView()
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0; layout.minimumLineSpacing = 0
        let inset = film ? Metrics.filmCell.inset : Metrics.thumbnailCell.inset
        layout.sectionInset = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        layout.scrollDirection = film ? .horizontal : .vertical
        let collection = KeyboardCollectionView()
        collection.command = { [weak model] event in
            guard let model, model.workspaceAvailable else { return false }
            if WorkspaceKeyboard.stack(event,model:model) { return true }
            if event.keyCode == 123, model.photos.first?.id == model.activeID, model.pageOffset > 0 { model.move(-1); return true }
            if event.keyCode == 124, model.photos.last?.id == model.activeID, model.pageOffset + model.photos.count < model.visibleCount { model.move(1); return true }
            if WorkspaceKeyboard.cull(event, model: model) { return true }
            guard !event.modifierFlags.contains(.shift) else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "g": model.selectWorkspace(.grid)
            case "e": model.selectWorkspace(.single)
            case "d": model.selectWorkspace(.develop)
            case "c": model.selectWorkspace(.compare)
            case "n": model.selectWorkspace(.survey)
            default: return false
            }
            return true
        }
        collection.openPhoto = { [weak model] in
            guard let model else { return }
            model.selectWorkspace(model.editMode ? .develop : .single)
        }
        collection.activateSelected = { [weak model, weak coordinator = context.coordinator] path in
            guard let model, let coordinator, let survey = model.survey,
                  model.workspaceAvailable, coordinator.photos.indices.contains(path.item) else { return false }
            let id = coordinator.photos[path.item].id
            guard survey.ids.contains(id) else { return false }
            model.activateSurveyPhoto(id)
            return true
        }
        collection.collectionViewLayout = layout
        collection.isSelectable = true; collection.allowsMultipleSelection = true
        collection.setDraggingSourceOperationMask(.move, forLocal: true)
        collection.registerForDraggedTypes([Coordinator.orderingPasteboardType])
        collection.backgroundColors = [mat.nsColor]
        scroll.drawsBackground = true; scroll.backgroundColor = mat.nsColor
        collection.register(PhotoItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("photo"))
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        scroll.documentView = collection
        scroll.hasVerticalScroller = !film; scroll.hasHorizontalScroller = film
        if film { scroll.horizontalLineScroll = 40 }
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = mat.gray < 0.5 ? .light : .dark
        context.coordinator.collection = collection
        scroll.contentView.postsBoundsChangedNotifications = true
        let coordinator = context.coordinator
        coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak coordinator, weak scroll] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let scroll, !coordinator.applyingChanges else { return }
                coordinator.model.scrollPositions[coordinator.positionKey] = scroll.contentView.bounds.origin
            }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.filmHeight = filmHeight
        c.ordering = ordering
        let matChanged = c.mat != mat
        c.mat = mat
        if matChanged {
            c.collection?.backgroundColors = [mat.nsColor]; scroll.backgroundColor = mat.nsColor
            scroll.scrollerKnobStyle = mat.gray < 0.5 ? .light : .dark
        }
        let photos = model.filtered
        c.applyingChanges = true
        defer { c.applyingChanges = false }
        // Scroll state belongs to the effective query, not only the most
        // visible filters. Include metadata, sort direction, manual order and
        // the semantic query so different result layouts keep their position.
        // History also restores the origin captured by each individual visit.
        let positionKey = model.browseScrollKey(film: film)
        let oldOrigin = scroll.contentView.bounds.origin
        let changedPage = c.positionKey != positionKey
        c.positionKey = positionKey
        let previous = c.photos
        c.photos = photos
        let difference = photos.map(\.id).difference(from: previous.map(\.id))
        if !difference.isEmpty {
            if changedPage || previous.isEmpty {
                c.collection?.reloadData()
            } else {
                var removed = Set<IndexPath>(), inserted = Set<IndexPath>()
                for change in difference {
                    switch change {
                    case .remove(let offset, _, _): removed.insert(IndexPath(item: offset, section: 0))
                    case .insert(let offset, _, _): inserted.insert(IndexPath(item: offset, section: 0))
                    }
                }
                // A flag/rating filter can remove a photo. Keep all surviving
                // item views instead of flashing the entire page in that case.
                NSAnimationContext.runAnimationGroup { animation in
                    animation.duration = 0
                    c.collection?.performBatchUpdates {
                        c.collection?.deleteItems(at: removed)
                        c.collection?.insertItems(at: inserted)
                    }
                }
            }
        }
        do {
            // Organization/metadata edits must not tear down every visible image.
            for item in c.collection?.visibleItems() ?? [] {
                guard let path = c.collection?.indexPath(for: item), photos.indices.contains(path.item),
                      let item = item as? PhotoItem else { continue }
                let photo = photos[path.item]
                let edges = c.stackEdges(at: path.item)
                item.configure(photo: photo, root: model.roots.first { $0.id == photo.rootID }, service: model.thumbnails,
                               film: film, active: model.activeID == photo.id, mat: mat, badge: model.stackBadges[photo.id],
                               paired: model.pairedSourceIDs.contains(photo.sourceKey), position: model.pageOffset + path.item + 1,
                               stackStart: edges.first, stackEnd: edges.last, toggleStack: { [weak model] in model?.toggleStack(photo.id) })
            }
        }
        if let layout = c.collection?.collectionViewLayout as? NSCollectionViewFlowLayout {
            let size = film ? c.filmItemSize(viewportHeight: scroll.contentSize.height) : c.gridItemSize(viewportWidth: scroll.contentSize.width)
            if layout.itemSize != size { layout.itemSize = size; layout.invalidateLayout() }
        }
        let indexes = Set(photos.enumerated().filter { model.selection.contains($0.element.id) }.map { IndexPath(item: $0.offset, section: 0) })
        if c.collection?.selectionIndexPaths != indexes { c.collection?.selectionIndexPaths = indexes }
        if changedPage || !difference.isEmpty {
            scroll.contentView.scroll(to: changedPage ? (model.scrollPositions[positionKey] ?? .zero) : oldOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let restoringPosition = changedPage && model.scrollPositions[positionKey] != nil
            && model.scrollActiveIDs[positionKey] == model.activeID
        if restoringPosition { c.lastActive = model.activeID }
        if c.lastActive != model.activeID, let index = photos.firstIndex(where: { $0.id == model.activeID }) {
            c.lastActive = model.activeID
            c.collection?.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: film ? .nearestHorizontalEdge : .nearestVerticalEdge)
        }
        model.scrollActiveIDs[positionKey] = model.activeID
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        let model: AppModel
        let film: Bool
        var ordering: CollectionOrdering?
        var filmHeight: Double = 84
        var mat = PhotoMat.dark
        var photos: [Photo] = []
        var applyingChanges = false
        var positionKey = ""
        var lastActive: String?
        var scrollObserver: NSObjectProtocol?
        private var selectionUpdateScheduled = false
        private var pendingActiveID: String?
        private var pendingSelectionModifiers: NSEvent.ModifierFlags = []
        deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
        weak var collection: NSCollectionView?
        init(model: AppModel, film: Bool, ordering: CollectionOrdering?) { self.model = model; self.film = film; self.ordering = ordering }
        func filmItemSize(viewportHeight: CGFloat) -> NSSize {
            // A persistent horizontal scrollbar consumes space inside the thumbnail band.
            let available = viewportHeight > 0 ? Double(viewportHeight) : filmHeight
            let height = max(1, min(filmHeight, available) - Double(2 * Metrics.filmCell.inset + 1))
            return NSSize(width: max(104, (filmHeight - 8) * 1.25), height: height)
        }
        func gridItemSize(viewportWidth: CGFloat) -> NSSize {
            let available = max(1, viewportWidth - 2 * Metrics.thumbnailCell.inset)
            let columns = max(1, floor(available / model.thumbnailSize))
            let width = available / columns
            let height = (width - 2 * Metrics.thumbnailCell.imageInset) * 0.75
                + Metrics.thumbnailCell.header + Metrics.thumbnailCell.footer + Metrics.thumbnailCell.imageGap
            return NSSize(width: width, height: height)
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            if film { return filmItemSize(viewportHeight: collectionView.enclosingScrollView?.contentSize.height ?? CGFloat(filmHeight)) }
            return gridItemSize(viewportWidth: collectionView.bounds.width)
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { photos.count }
        func stackEdges(at index: Int) -> (first: Bool, last: Bool) {
            guard photos.indices.contains(index), let stack = model.stackBadges[photos[index].id]?.stackID else { return (false, false) }
            return (index == 0 || model.stackBadges[photos[index - 1].id]?.stackID != stack,
                    index == photos.count - 1 || model.stackBadges[photos[index + 1].id]?.stackID != stack)
        }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("photo"), for: indexPath) as! PhotoItem
            let photo = photos[indexPath.item]
            let edges = stackEdges(at: indexPath.item)
            item.configure(photo: photo, root: model.roots.first { $0.id == photo.rootID }, service: model.thumbnails,
                           film: film, active: model.activeID == photo.id, mat: mat, badge: model.stackBadges[photo.id],
                           paired: model.pairedSourceIDs.contains(photo.sourceKey), position: model.pageOffset + indexPath.item + 1,
                           stackStart: edges.first, stackEnd: edges.last, toggleStack: { [weak model] in model?.toggleStack(photo.id) })
            return item
        }
        fileprivate static let orderingPasteboardType = NSPasteboard.PasteboardType("dev.cmkk.phosdeck.collection-order")
        private func movingIDs(for indexPath: IndexPath) -> [String] {
            guard photos.indices.contains(indexPath.item) else { return [] }
            let dragged = photos[indexPath.item].id
            let selected = model.selection.intersection(Set(photos.map(\.id)))
            // A drag starts from a non-selected card as a single-photo move;
            // dragging a selected card preserves the complete real selection,
            // including selected members on other pages.
            return selected.contains(dragged) ? photos.map(\.id).filter { selected.contains($0) } +
                model.selection.subtracting(Set(photos.map(\.id))).sorted() : [dragged]
        }
        private func currentOrderingToken() -> CollectionOrderingToken? {
            guard let path = model.catalog?.fileURL.path else { return nil }
            return CollectionOrderingToken(catalogPath: path, querySignature: model.query.orderingQuerySignature)
        }
        private func dragPayload(_ info: NSDraggingInfo) -> CollectionOrderingDragPayload? {
            guard let value = info.draggingPasteboard.string(forType: Self.orderingPasteboardType),
                  let data = value.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(CollectionOrderingDragPayload.self, from: data),
                  !payload.ids.isEmpty, Set(payload.ids).count == payload.ids.count else { return nil }
            return payload
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let ordering, ordering.enabled, let token = ordering.token,
                  token == currentOrderingToken() else { return nil }
            let ids = movingIDs(for: indexPath)
            guard !ids.isEmpty else { return nil }
            let item = NSPasteboardItem()
            let payload = CollectionOrderingDragPayload(ids: ids, token: token)
            guard let data = try? JSONEncoder().encode(payload), let value = String(data: data, encoding: .utf8) else { return nil }
            item.setString(value, forType: Self.orderingPasteboardType)
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard let ordering, ordering.enabled, let expected = ordering.token,
                  expected == currentOrderingToken(), let payload = dragPayload(draggingInfo),
                  payload.token == expected else { return [] }
            let ids = payload.ids
            let index = proposedIndexPath.pointee.item
            let before = photos.indices.contains(index) ? photos[index].id : nil
            guard before == nil || !ids.contains(before!) else { return [] }
            proposedDropOperation.pointee = .before
            return .move
        }
        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let ordering, ordering.enabled, let expected = ordering.token,
                  expected == currentOrderingToken(), dropOperation == .before,
                  let payload = dragPayload(draggingInfo), payload.token == expected else { return false }
            let ids = payload.ids
            let before = photos.indices.contains(indexPath.item) ? photos[indexPath.item].id : nil
            guard before == nil || !ids.contains(before!) else { return false }
            return ordering.reorder(ids, before)
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { selectionChanged(collectionView, active: indexPaths.sorted().last) }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { selectionChanged(collectionView, active: nil) }
        private func selectionChanged(_ collection: NSCollectionView, active: IndexPath?) {
            guard !applyingChanges else { return }
            if let active, photos.indices.contains(active.item) { pendingActiveID = photos[active.item].id }
            pendingSelectionModifiers = NSEvent.modifierFlags
            guard !selectionUpdateScheduled else { return }
            selectionUpdateScheduled = true
            let queryKey = positionKey, previousActive = model.activeID
            // A mouse selection reports an empty deselection before selecting
            // its replacement. Publish only the final set from this event.
            Task { @MainActor [weak self, weak collection] in
                guard let self, let collection else { return }
                self.selectionUpdateScheduled = false
                let active = self.pendingActiveID
                self.pendingActiveID = nil
                guard self.positionKey == queryKey, self.model.activeID == previousActive else { return }
                self.changed(collection, active: active, modifiers: self.pendingSelectionModifiers)
            }
        }
        private func changed(_ collection: NSCollectionView, active: String?, modifiers: NSEvent.ModifierFlags) {
            let visibleIDs = Set(photos.map(\.id))
            let carry = modifiers.intersection([.command, .shift]).isEmpty ? Set<String>() : model.selection.subtracting(visibleIDs)
            let ids = carry.union(Set(collection.selectionIndexPaths.compactMap { photos.indices.contains($0.item) ? photos[$0.item].id : nil }))
            let id = active.flatMap { ids.contains($0) ? $0 : nil } ?? (ids.contains(model.activeID ?? "") ? model.activeID : ids.sorted().first)
            if let survey = model.survey {
                if modifiers.intersection([.command, .shift]).isEmpty, let id, survey.ids.contains(id) { model.activateSurveyPhoto(id) }
                else { model.updateSurveySelection(ids, active: id) }
                return
            }
            model.choose(ids, active: id)
        }
    }
}

final class FilmstripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
              let documentView, documentView.bounds.width > contentView.bounds.width else {
            super.scrollWheel(with: event)
            return
        }
        let distance = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll)
        var bounds = contentView.bounds
        bounds.origin.x -= distance
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(contentView)
        flashScrollers()
    }
}

final class KeyboardCollectionView: NSCollectionView {
    var command: ((NSEvent) -> Bool)?
    var openPhoto: (() -> Void)?
    var activateSelected: ((IndexPath) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, command?(event) == true { return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)), activateSelected?(path) == true {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 { openPhoto?() }
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2 { openPhoto?() }
    }
}

private final class PhotoCellView: NSView {
    private let leadingSeam = CALayer(), trailingSeam = CALayer(), topSeam = CALayer(), bottomSeam = CALayer()
    private var hoverTrackingArea: NSTrackingArea?
    var hoverChanged: (() -> Void)?
    var isHovered = false {
        didSet { if oldValue != isHovered { hoverChanged?() } }
    }
    var seamColor: CGColor? {
        didSet { for seam in [leadingSeam, trailingSeam, topSeam, bottomSeam] { seam.backgroundColor = seamColor } }
    }
    override func makeBackingLayer() -> CALayer {
        let backing = super.makeBackingLayer()
        for (name, seam) in zip(["leading", "trailing", "top", "bottom"], [leadingSeam, trailingSeam, topSeam, bottomSeam]) {
            seam.name = "photo-grid-seam-" + name; seam.zPosition = 1
            seam.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
            backing.addSublayer(seam)
        }
        return backing
    }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); needsLayout = true; refreshHover() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshHover), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(refreshHover), name: NSWindow.didResignKeyNotification, object: window)
        }
        refreshHover()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        hoverTrackingArea = area; addTrackingArea(area)
        super.updateTrackingAreas()
        refreshHover()
    }
    @objc func refreshHover() {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { isHovered = false; return }
        isHovered = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func layout() {
        super.layout()
        let width = Metrics.thumbnailCell.seamWidth
        leadingSeam.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        trailingSeam.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        topSeam.frame = NSRect(x: 0, y: bounds.height - width, width: bounds.width, height: width)
        bottomSeam.frame = NSRect(x: 0, y: 0, width: bounds.width, height: width)
        // Each cell owns its right/bottom seam; only the first row/column adds the outer edges.
        if let collection = enclosingScrollView?.documentView as? NSCollectionView,
           let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
            let frame = convert(bounds, to: collection)
            leadingSeam.isHidden = abs(frame.minX - layout.sectionInset.left) > 0.01
            topSeam.isHidden = abs(frame.minY - layout.sectionInset.top) > 0.01
        }
    }
}

private final class StackButton: NSButton {
    var edge = false
    var mat = PhotoMat.dark
    override func draw(_ dirtyRect: NSRect) {
        guard edge else { super.draw(dirtyRect); return }
        let focused = window?.firstResponder === self
        (focused ? mat.focus : cell?.isHighlighted == true ? mat.text : mat.textSecondary).setFill()
        let height = min(Metrics.thumbnailStack.markHeight, max(0, bounds.height - 4))
        for x in [bounds.midX - 2, bounds.midX + 1] {
            NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - height / 2, width: 1, height: height), xRadius: 0.5, yRadius: 0.5).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        // A double click must not immediately undo the first toggle or open the photo.
        guard event.clickCount == 1 else { return }
        super.mouseDown(with: event)
    }
}

final class PhotoItem: NSCollectionViewItem {
    private let picture = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let fileType = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let colorIndicator = NSView()
    private let stackButton = StackButton(title: "", target: nil, action: nil)
    private let stackLeading = StackButton(title: "", target: nil, action: nil)
    private let stackTrailing = StackButton(title: "", target: nil, action: nil)
    private var stackToggle: (() -> Void)?
    private var work: Task<Void, Never>?
    private var token = UUID()
    private var imageKey: String?
    private var sourceKey: String?
    private var isActivePhoto = false
    private var mat = PhotoMat.dark
    private var film: Bool?
    private var gridConstraints: [NSLayoutConstraint] = []
    private var filmConstraints: [NSLayoutConstraint] = []
    private var captionLeading: NSLayoutConstraint!
    private var detailsLeading: NSLayoutConstraint!
    private var stackedDetailsLeading: NSLayoutConstraint!
    private var stackInset: NSLayoutConstraint!
    private var handleWidths: [NSLayoutConstraint] = []
    var displayedImage: NSImage? { picture.image }
    override func loadView() {
        let cell = PhotoCellView()
        cell.hoverChanged = { [weak self] in self?.style() }
        view = cell; view.wantsLayer = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        caption.font = .systemFont(ofSize: 11, weight: .medium); caption.lineBreakMode = .byTruncatingMiddle
        fileType.font = .systemFont(ofSize: 9, weight: .semibold); fileType.alignment = .center
        fileType.setContentHuggingPriority(.required, for: .horizontal)
        fileType.setContentCompressionResistancePriority(.required, for: .horizontal)
        fileType.wantsLayer = true; fileType.layer?.cornerRadius = 2
        details.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        details.lineBreakMode = .byTruncatingMiddle
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        positionLabel.setAccessibilityElement(false)
        for (id, label) in [("photo-name", caption), ("photo-type", fileType), ("photo-status", details), ("photo-position", positionLabel)] {
            label.identifier = NSUserInterfaceItemIdentifier(id)
        }
        for sub in [picture, caption, fileType, details, positionLabel] { sub.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(sub) }
        colorIndicator.wantsLayer = true; colorIndicator.layer?.cornerRadius = 1
        colorIndicator.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(colorIndicator)
        NSLayoutConstraint.activate([colorIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            colorIndicator.widthAnchor.constraint(equalToConstant: 6), colorIndicator.heightAnchor.constraint(equalToConstant: 6)])
        for (id, button) in [("stack-count", stackButton), ("stack-leading", stackLeading), ("stack-trailing", stackTrailing)] {
            button.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(button)
            button.isBordered = false; button.bezelStyle = .inline
            button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            button.target = self; button.action = #selector(toggleStack); button.identifier = NSUserInterfaceItemIdentifier(id)
        }
        stackLeading.edge = true; stackTrailing.edge = true
        stackLeading.focusRingType = .none; stackTrailing.focusRingType = .none
        stackButton.wantsLayer = true; stackButton.layer?.cornerRadius = 2
        stackButton.setContentHuggingPriority(.required, for: .horizontal)
        captionLeading = caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12)
        detailsLeading = details.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12)
        stackedDetailsLeading = details.leadingAnchor.constraint(equalTo: stackButton.trailingAnchor, constant: 6)
        stackInset = stackButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            captionLeading, caption.heightAnchor.constraint(equalToConstant: 14),
            caption.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            caption.trailingAnchor.constraint(equalTo: fileType.leadingAnchor, constant: -8),
            fileType.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), fileType.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            fileType.heightAnchor.constraint(equalToConstant: 14),
            stackInset, stackButton.heightAnchor.constraint(equalToConstant: Metrics.thumbnailStack.countHeight),
            stackButton.widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.thumbnailStack.minWidth),
            stackButton.widthAnchor.constraint(lessThanOrEqualToConstant: Metrics.thumbnailStack.maxWidth),
            positionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), positionLabel.heightAnchor.constraint(equalToConstant: 14),
            positionLabel.centerYAnchor.constraint(equalTo: details.centerYAnchor),
            details.heightAnchor.constraint(equalToConstant: 14), details.centerYAnchor.constraint(equalTo: stackButton.centerYAnchor),
            stackLeading.leadingAnchor.constraint(equalTo: view.leadingAnchor), stackTrailing.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        for handle in [stackLeading, stackTrailing] {
            let width = handle.widthAnchor.constraint(equalToConstant: Metrics.thumbnailCell.imageInset)
            let height = handle.heightAnchor.constraint(equalToConstant: Metrics.thumbnailStack.handleHeight); height.priority = .defaultHigh
            handleWidths.append(width)
            NSLayoutConstraint.activate([width, height, handle.heightAnchor.constraint(lessThanOrEqualTo: picture.heightAnchor),
                                         handle.centerYAnchor.constraint(equalTo: picture.centerYAnchor)])
        }
        gridConstraints = [
            picture.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.thumbnailCell.header),
            picture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.thumbnailCell.imageInset),
            picture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.thumbnailCell.imageInset),
            picture.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.thumbnailCell.footer - Metrics.thumbnailCell.imageGap),
            stackButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            details.trailingAnchor.constraint(equalTo: positionLabel.leadingAnchor, constant: -6),
            colorIndicator.centerYAnchor.constraint(equalTo: caption.centerYAnchor)
        ]
        filmConstraints = [
            picture.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            picture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.filmCell.imageInset),
            picture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.filmCell.imageInset),
            picture.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.filmCell.footer - 2),
            stackButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            details.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            colorIndicator.centerYAnchor.constraint(equalTo: details.centerYAnchor)
        ]
    }
    override var isSelected: Bool { didSet { style() } }
    private func style() {
        let selected = isSelected || isActivePhoto, hovered = (view as! PhotoCellView).isHovered
        let fill = selected ? (hovered ? Metrics.thumbnailCellFill.selectedHover : Metrics.thumbnailCellFill.selected)
                            : (hovered ? Metrics.thumbnailCellFill.hover : Metrics.thumbnailCellFill.idle)
        let background = mat.nsColor.blended(withFraction: fill, of: mat.selection) ?? mat.nsColor
        view.layer?.backgroundColor = background.cgColor
        (view as! PhotoCellView).seamColor = background.blended(withFraction: 0.16, of: mat.selection)?.cgColor
        view.layer?.borderWidth = isActivePhoto ? 2 : isSelected ? 1 : 0
        view.layer?.borderColor = mat.selection.withAlphaComponent(isActivePhoto ? 1 : 0.7).cgColor
        caption.textColor = isSelected || isActivePhoto ? mat.text : mat.textSecondary
        details.textColor = mat.textSecondary; positionLabel.textColor = mat.textSecondary; fileType.textColor = mat.textSecondary
        fileType.layer?.backgroundColor = mat.selection.withAlphaComponent(0.06).cgColor
        stackButton.layer?.backgroundColor = mat.selection.withAlphaComponent(0.08).cgColor
        for button in [stackLeading, stackTrailing] { button.mat = mat; button.needsDisplay = true }
    }
    @objc private func toggleStack() { stackToggle?() }
    func configure(photo: Photo, root: StorageRoot?, service: ThumbnailService, film: Bool, active: Bool = false, mat: PhotoMat = .dark, badge: StackBadge? = nil, paired: Bool = false, position: Int? = nil, stackStart: Bool = true, stackEnd: Bool = true, toggleStack: (() -> Void)? = nil) {
        _ = view
        if imageKey == nil { (view as? PhotoCellView)?.refreshHover() }
        isActivePhoto = active; self.mat = mat
        NSLayoutConstraint.deactivate([detailsLeading, stackedDetailsLeading])
        if self.film != film {
            NSLayoutConstraint.deactivate(gridConstraints + filmConstraints)
            NSLayoutConstraint.activate(film ? filmConstraints : gridConstraints)
            self.film = film
            for width in handleWidths { width.constant = film ? Metrics.filmCell.imageInset : Metrics.thumbnailCell.imageInset }
        }
        positionLabel.isHidden = film; caption.isHidden = film; fileType.isHidden = film
        positionLabel.stringValue = position.map(String.init) ?? ""
        let label = PhotoColorLabel(rawValue: photo.colorLabel) ?? .none
        colorIndicator.isHidden = label == .none
        colorIndicator.layer?.backgroundColor = label.nsColor.cgColor
        colorIndicator.toolTip = label.title
        captionLeading.constant = label == .none ? (film ? 8 : 12) : 20
        stackToggle = toggleStack; stackButton.isHidden = badge == nil || !stackStart
        stackLeading.isHidden = badge == nil || !stackStart; stackTrailing.isHidden = badge == nil || !stackEnd
        stackButton.title = badge?.text ?? ""
        stackButton.attributedTitle = NSAttributedString(string: badge?.text ?? "", attributes: [.foregroundColor: mat.text, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)])
        for button in [stackButton, stackLeading, stackTrailing] {
            let action = badge?.collapsed == true ? L10n.text("app.expandStack", defaultValue: "Expand Stack") : L10n.text("app.collapseStack", defaultValue: "Collapse Stack")
            button.setAccessibilityLabel(badge.map { action + " · " + $0.description })
            button.toolTip = badge.map { action + " (S) · " + $0.description }
        }
        stackInset.constant = film && label != .none ? 20 : 8
        detailsLeading.constant = film ? (label == .none ? 8 : 20) : 12
        (stackButton.isHidden ? detailsLeading : stackedDetailsLeading)?.isActive = true

        let flags = photo.flag == -1 ? "×" : photo.flag == 1 ? "⚑" : ""
        let rating = photo.rating > 0 ? "★ \(photo.rating)" : ""
        details.stringValue = [paired ? "↔" : "", flags, rating, film && photo.isVirtualCopy ? photo.versionName : ""].filter { !$0.isEmpty }.joined(separator: " ")
        let filename = URL(fileURLWithPath: photo.name)
        caption.stringValue = filename.deletingPathExtension().lastPathComponent + (photo.isVirtualCopy ? " · " + photo.versionName : "")
        let ext = filename.pathExtension.uppercased(), raw = photo.isRAW
        fileType.stringValue = raw ? "RAW" : ["JPG": "JPEG", "TIF": "TIFF"][ext] ?? ext
        fileType.isHidden = film || fileType.stringValue.isEmpty
        fileType.toolTip = photo.name
        let tooltip = ([photo.displayName, details.stringValue].filter { !$0.isEmpty }).joined(separator: "\n")
        caption.toolTip = tooltip; details.toolTip = tooltip
        view.setAccessibilityLabel(L10n.text("app.stars_1725", defaultValue: "\(photo.displayName), \(raw ? "RAW" : ext), \(paired ? L10n.text("app.rawJPEGPaired", defaultValue: "RAW/JPEG Paired") : L10n.text("app.unpaired", defaultValue: "Unpaired")), \(badge?.description ?? L10n.text("app.unstacked", defaultValue: "Unstacked")), \(photo.rating) stars, \(label.title)\(active ? L10n.text("app.activePhoto", defaultValue: ", active photo") : "")\(photo.flag == -1 ? L10n.text("app.rejected", defaultValue: ", rejected") : photo.flag == 1 ? L10n.text("app.picked", defaultValue: ", picked") : "")"))
        style()
        let key = ThumbnailService.key(photo: photo, edge: 320)
        guard imageKey != key || (picture.image == nil && work == nil) else { return }
        work?.cancel(); token = UUID(); let current = token
        let source = ThumbnailService.sourceKey(photo: photo, edge: 320)
        if sourceKey != source { picture.image = nil }
        sourceKey = source
        imageKey = key; view.toolTip = nil
        guard let root else { work = nil; return }
        work = Task { @MainActor in
            do {
                let image = try await service.image(photo: photo, root: root)
                guard current == token, !Task.isCancelled else { return }
                picture.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            } catch { if current == token { view.toolTip = error.localizedDescription } }
            if current == token { work = nil }
        }
    }
    override func prepareForReuse() {
        work?.cancel(); work = nil; token = UUID(); imageKey = nil; sourceKey = nil; picture.image = nil; stackToggle = nil
        (view as? PhotoCellView)?.isHovered = false
        super.prepareForReuse()
    }
}
