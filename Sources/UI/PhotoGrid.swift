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
        let scroll = NSScrollView()
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
                item.configure(photo: photo, root: model.roots.first { $0.id == photo.rootID }, service: model.thumbnails, film: film, active: model.activeID == photo.id, mat: mat, badge:model.stackBadges[photo.id],paired:model.pairedSourceIDs.contains(photo.sourceKey),position:model.pageOffset + path.item + 1,toggleStack:{ [weak model] in model?.toggleStack(photo.id) })
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
            let height = max(1, min(filmHeight, available) - 9)
            return NSSize(width: max(104, (filmHeight - 8) * 1.25), height: height)
        }
        func gridItemSize(viewportWidth: CGFloat) -> NSSize {
            let available = max(1, viewportWidth - 2 * Metrics.thumbnailCell.inset)
            let columns = max(1, floor(available / model.thumbnailSize))
            let width = floor(available / columns)
            let height = (width - 2 * Metrics.thumbnailCell.imageInset) * 0.75
                + Metrics.thumbnailCell.header + Metrics.thumbnailCell.footer + Metrics.thumbnailCell.imageGap
            return NSSize(width: width, height: height)
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            if film { return filmItemSize(viewportHeight: collectionView.enclosingScrollView?.contentSize.height ?? CGFloat(filmHeight)) }
            return gridItemSize(viewportWidth: collectionView.bounds.width)
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { photos.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("photo"), for: indexPath) as! PhotoItem
            let photo = photos[indexPath.item]
            item.configure(photo: photo, root: model.roots.first { $0.id == photo.rootID }, service: model.thumbnails, film: film, active: model.activeID == photo.id, mat: mat, badge:model.stackBadges[photo.id],paired:model.pairedSourceIDs.contains(photo.sourceKey),position:model.pageOffset + indexPath.item + 1,toggleStack:{ [weak model] in model?.toggleStack(photo.id) })
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

final class PhotoItem: NSCollectionViewItem {
    private let metadataWell = NSView()
    private let metadataSeam = NSView()
    private let picture = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let colorIndicator = NSView()
    private let stackButton = NSButton(title:"",target:nil,action:nil)
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
    private var filmCaptionTrailing: NSLayoutConstraint!
    private var stackedCaptionTrailing: NSLayoutConstraint!
    private var metadataHeight: NSLayoutConstraint!
    var displayedImage: NSImage? { picture.image }
    override func loadView() {
        view = NSView(); view.wantsLayer = true
        view.layer?.cornerRadius = 1
        metadataWell.wantsLayer = true; metadataSeam.wantsLayer = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        caption.font = .systemFont(ofSize: 11, weight: .medium); caption.lineBreakMode = .byTruncatingMiddle
        details.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        details.lineBreakMode = .byTruncatingMiddle
        positionLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        positionLabel.setAccessibilityElement(false)
        for sub in [metadataWell, metadataSeam, picture, caption, details, positionLabel] { sub.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(sub) }
        colorIndicator.wantsLayer = true; colorIndicator.layer?.cornerRadius = 1
        colorIndicator.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(colorIndicator)
        NSLayoutConstraint.activate([colorIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            colorIndicator.centerYAnchor.constraint(equalTo: caption.centerYAnchor), colorIndicator.widthAnchor.constraint(equalToConstant: 6), colorIndicator.heightAnchor.constraint(equalToConstant: 6)])
        stackButton.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stackButton)
        stackButton.bezelStyle = .inline; stackButton.font = .monospacedDigitSystemFont(ofSize:11,weight:.medium)
        stackButton.target = self; stackButton.action = #selector(toggleStack)
        stackButton.wantsLayer = true; stackButton.layer?.cornerRadius = 2
        stackButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        captionLeading = caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12)
        metadataHeight = metadataWell.heightAnchor.constraint(equalToConstant: Metrics.thumbnailCell.footer)
        NSLayoutConstraint.activate([
            metadataWell.leadingAnchor.constraint(equalTo: view.leadingAnchor), metadataWell.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metadataWell.bottomAnchor.constraint(equalTo: view.bottomAnchor), metadataHeight,
            metadataSeam.leadingAnchor.constraint(equalTo: view.leadingAnchor), metadataSeam.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metadataSeam.topAnchor.constraint(equalTo: metadataWell.topAnchor), metadataSeam.heightAnchor.constraint(equalToConstant: 0.5),
            captionLeading, caption.heightAnchor.constraint(equalToConstant: 14),
            stackButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6), stackButton.heightAnchor.constraint(equalToConstant: 18),
            positionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), positionLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            positionLabel.heightAnchor.constraint(equalToConstant: 14)
        ])
        gridConstraints = [
            picture.topAnchor.constraint(equalTo: view.topAnchor, constant: Metrics.thumbnailCell.header),
            picture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.thumbnailCell.imageInset),
            picture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.thumbnailCell.imageInset),
            picture.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.thumbnailCell.footer - Metrics.thumbnailCell.imageGap),
            stackButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            caption.topAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.thumbnailCell.footer + 6),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            details.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), details.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            details.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5), details.heightAnchor.constraint(equalToConstant: 12)
        ]
        filmConstraints = [
            picture.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            picture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Metrics.filmCell.imageInset),
            picture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Metrics.filmCell.imageInset),
            picture.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Metrics.filmCell.footer - 2),
            stackButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            caption.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2)
        ]
        filmCaptionTrailing = caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        stackedCaptionTrailing = caption.trailingAnchor.constraint(equalTo: stackButton.leadingAnchor, constant: -4)
    }
    override var isSelected: Bool { didSet { style() } }
    private func style() {
        view.layer?.backgroundColor = mat.nsColor.blended(withFraction: isSelected || isActivePhoto ? 0.1 : 0.025, of: mat.selection)?.cgColor
        view.layer?.borderWidth = isActivePhoto ? 2 : 1
        view.layer?.borderColor = mat.selection.withAlphaComponent(isActivePhoto ? 1 : isSelected ? 0.7 : 0.16).cgColor
        metadataWell.layer?.backgroundColor = mat.selection.withAlphaComponent(0.04).cgColor
        metadataSeam.layer?.backgroundColor = mat.selection.withAlphaComponent(0.14).cgColor
        caption.textColor = isSelected || isActivePhoto ? mat.text : mat.textSecondary
        details.textColor = mat.textSecondary; positionLabel.textColor = mat.textSecondary
        stackButton.layer?.backgroundColor = mat.selection.withAlphaComponent(0.08).cgColor
    }
    @objc private func toggleStack() { stackToggle?() }
    func configure(photo: Photo, root: StorageRoot?, service: ThumbnailService, film: Bool, active: Bool = false, mat: PhotoMat = .dark, badge: StackBadge? = nil, paired: Bool = false, position: Int? = nil, toggleStack: (() -> Void)? = nil) {
        _ = view
        isActivePhoto = active; self.mat = mat
        NSLayoutConstraint.deactivate([filmCaptionTrailing, stackedCaptionTrailing])
        if self.film != film {
            NSLayoutConstraint.deactivate(gridConstraints + filmConstraints)
            NSLayoutConstraint.activate(film ? filmConstraints : gridConstraints)
            self.film = film
            metadataHeight.constant = film ? Metrics.filmCell.footer : Metrics.thumbnailCell.footer
        }
        positionLabel.isHidden = film; details.isHidden = film
        positionLabel.stringValue = position.map { String(format: "%03d", $0) } ?? ""
        let label = PhotoColorLabel(rawValue: photo.colorLabel) ?? .none
        colorIndicator.isHidden = label == .none
        colorIndicator.layer?.backgroundColor = label.nsColor.cgColor
        colorIndicator.toolTip = label.title
        captionLeading.constant = label == .none ? (film ? 8 : 12) : 20
        stackToggle = toggleStack; stackButton.isHidden = badge == nil; stackButton.title = badge?.text ?? ""
        stackButton.attributedTitle = NSAttributedString(string:badge?.text ?? "",attributes:[.foregroundColor:mat.text,.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium)])
        stackButton.contentTintColor = mat.text; stackButton.setAccessibilityLabel(badge.map { $0.description + L10n.text("app.toggleExpansion", defaultValue: ", toggle expansion") })
        stackButton.toolTip = badge?.description

        let format = photo.isRAW ? "RAW" : ["jpg", "jpeg"].contains(URL(fileURLWithPath: photo.relativePath).pathExtension.lowercased()) ? "JPEG" : URL(fileURLWithPath: photo.relativePath).pathExtension.uppercased()
        let flags = photo.flag == -1 ? "×" : photo.flag == 1 ? "⚑" : ""
        let rating = photo.rating > 0 ? "★ \(photo.rating)" : ""
        details.stringValue = [format, paired ? "↔" : "", flags, rating].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        caption.stringValue = film ? [flags, rating, paired ? "↔" : "", format, photo.isVirtualCopy ? photo.versionName : ""].filter { !$0.isEmpty }.joined(separator: " ") : photo.displayName
        caption.toolTip = photo.displayName + "\n" + details.stringValue
        caption.font = .systemFont(ofSize: film ? 10 : 11, weight: .medium)
        if film { (badge == nil ? filmCaptionTrailing : stackedCaptionTrailing)?.isActive = true }
        view.setAccessibilityLabel(L10n.text("app.stars_1725", defaultValue: "\(photo.displayName), \(photo.isRAW ? "RAW" : URL(fileURLWithPath:photo.relativePath).pathExtension.uppercased()), \(paired ? L10n.text("app.rawJPEGPaired", defaultValue: "RAW/JPEG Paired") : L10n.text("app.unpaired", defaultValue: "Unpaired")), \(badge?.description ?? L10n.text("app.unstacked", defaultValue: "Unstacked")), \(photo.rating) stars, \(label.title)\(active ? L10n.text("app.activePhoto", defaultValue: ", active photo") : "")\(photo.flag == -1 ? L10n.text("app.rejected", defaultValue: ", rejected") : photo.flag == 1 ? L10n.text("app.picked", defaultValue: ", picked") : "")"))
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
        work?.cancel(); work = nil; token = UUID(); imageKey = nil; sourceKey = nil; picture.image = nil
        super.prepareForReuse()
    }
}
