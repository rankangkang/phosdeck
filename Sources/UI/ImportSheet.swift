import SwiftUI
import ImageIO
import AppKit

struct ImportSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var sourceLease: AccessLease?
    @State private var target: URL?
    @State private var targetLease: AccessLease?
    @State private var copy = false
    @State private var recursive = true
    @State private var onlyNew = false
    @State private var candidates: [ImportCandidate] = []
    @State private var selection = ImportSelection()
    @State private var collection = ""
    @State private var scanning = false
    @State private var scanTask: Task<Void, Never>?
    @State private var scanID = UUID()
    @State private var error: String?
    @AppStorage("copyDateLayout") private var layout = DateLayout.yearMonthDay
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    @State private var dateOverride = ""
    @State private var includeSidecars = true
    @State private var pairAfterImport = false
    @State private var thumbnailSize = 150.0
    @State private var gridColumns = 1
    @FocusState private var gridFocused: Bool

    private var shown: [ImportCandidate] { onlyNew ? candidates.filter { !$0.isDuplicate } : candidates }

    var body: some View {
        VStack(spacing: 0) {
            header
            Seam()
            HStack(spacing: 0) {
                sourcePanel.frame(width: 220)
                Seam(axis: .vertical)
                photoPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                Seam(axis: .vertical)
                optionsPanel.frame(width: 250)
            }
            Seam()
            footer
        }
        .instrumentForm()
        .frame(width: 1100, height: 700)
        .onChange(of: recursive) { scan() }
        .onChange(of: onlyNew) { selection.retainSelection(in: shown) }
        .onDisappear { scanTask?.cancel() }

    }

    private var header: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("app.from", defaultValue: "From")).foregroundStyle(Theme.textSecondary)
                Label(source?.lastPathComponent ?? L10n.text("app.chooseSource", defaultValue: "Choose Source"), systemImage: "externaldrive")
            }.frame(width: 200, alignment: .leading)
            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
            VStack(spacing: 7) {
                KeyRow(title: L10n.text("app.importMethod", defaultValue: "Import Method"), options: [KeyOption(true, L10n.text("app.copy_1359", defaultValue: "Copy")), KeyOption(false, L10n.text("app.addAction", defaultValue: "Add"))], selection: $copy, expand: true).frame(width: 230)
                Text(copy ? L10n.text("app.copyToANewLocationPreserveOriginals", defaultValue: "Copy to a new location; preserve originals") : L10n.text("app.keepFilesInPlaceAndAddToCatalog", defaultValue: "Keep files in place and add to catalog"))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }.frame(maxWidth: .infinity)
            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
            VStack(alignment: .trailing, spacing: 5) {
                Text(L10n.text("app.toCatalog", defaultValue: "To Catalog")).foregroundStyle(Theme.textSecondary)
                Text(model.catalogName).fontWeight(.medium).lineLimit(1).help(model.catalog?.fileURL.path ?? "")
            }.frame(width: 220, alignment: .trailing)
        }.padding(20).background(Theme.base)
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            SubgroupLabel(L10n.text("app.source", defaultValue: "Source"))
            Button(L10n.text("app.choosePhotoFolder", defaultValue: "Choose Photo Folder…")) {
                guard let url = model.chooseDirectory(title: L10n.text("app.chooseImportSource", defaultValue: "Choose Import Source")) else { return }
                if source != url { selection.resetChoices() }
                sourceLease = AccessLease(url: url); source = url
                scan()
            }.buttonStyle(.key)
            Toggle(L10n.text("app.includeSubfolders", defaultValue: "Include Subfolders"), isOn: $recursive)
                .toggleStyle(InstrumentToggleStyle(expand: true))
            if let source {
                Label(source.lastPathComponent, systemImage: "folder.fill").fontWeight(.medium)
                Text(source.path).font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            }
            Seam()
            DisclosureGroup(L10n.text("app.supportsRAWJPEGTIFFAndPNG", defaultValue: "Supports RAW, JPEG, TIFF, PNG, and HEIC/HEIF")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("app.rawARWDNGNEFCR3RAFVerifiedPerFile", defaultValue: "RAW: ARW, SR2, DNG, NEF, NRW, CR2, CR3, RAF, ORF, RW2, RWL, PEF, 3FR, FFF, SRW, verified per file."))
                    Text(L10n.text("app.appleLinearDNGSupport", defaultValue: "Apple DNG: iPhone XS sensor DNG and iPhone 12 Pro linear DNG."))
                    Text(L10n.text("app.tiffRGBPNGStatic816BitIncludingGrayscale", defaultValue: "TIFF: RGB. PNG: static 8/16-bit, including grayscale, indexed color, and transparency. HEIC/HEIF: static SDR, PQ or HLG images."))
                }.padding(.top, 4).fixedSize(horizontal: false, vertical: true)
            }.font(.caption11).foregroundStyle(Theme.textSecondary)
            Spacer()
        }.padding(16).frame(maxHeight: .infinity).background(Theme.panel)
    }

    private var photoPanel: some View {
        let visible = shown
        let selectedCount = selection.selectedIDs.isEmpty ? 0 : visible.count { selection.selectedIDs.contains($0.id) }
        return VStack(spacing: 0) {
            KeyRow(title: L10n.text("app.showPhotos", defaultValue: "Show Photos"), options: [KeyOption(false, L10n.text("app.allPhotos", defaultValue: "All Photos")), KeyOption(true, L10n.text("app.newPhotos", defaultValue: "New Photos"))], selection: $onlyNew, expand: true, height: 24)
                .frame(width: 190).frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) { Text(L10n.text("app.photos", defaultValue: "\(visible.count) photos")).foregroundStyle(Theme.textSecondary) }
                .padding(12).background(Theme.panel)
            if scanning {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("app.readingSourcePhotos", defaultValue: "Reading source photos…"))
                    Button(L10n.text("app.cancelScan", defaultValue: "Cancel Scan")) {
                        scanID = UUID()
                        scanTask?.cancel()
                        scanning = false
                        selection.retainSelection(in: shown)
                    }.buttonStyle(.key)
                }
                    .foregroundStyle(Color(nsColor: mat.text))
                    .padding(8)
            }
            if visible.isEmpty && scanning {
                Spacer()
            } else if visible.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38)).foregroundStyle(Color(nsColor: mat.textSecondary))
                    Text(emptyTitle).font(.title3)
                    Text(source == nil ? L10n.text("app.chooseAPhotoFolderOnTheLeft", defaultValue: "Choose a photo folder on the left.") : L10n.text("app.tryIncludeSubfoldersOrAllPhotos", defaultValue: "Try Include Subfolders or All Photos."))
                        .foregroundStyle(Color(nsColor: mat.textSecondary))
                }.foregroundStyle(Color(nsColor: mat.text)).multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                photoGrid(visible)
            }
            Seam()
            HStack {
                Button(L10n.text("app.importCheckAll", defaultValue: "Check All")) { selection.checkAll(in: visible) }
                    .buttonStyle(.key).disabled(scanning || !visible.contains { selection.canIncludeInCheckAll($0) && !selection.isChecked($0) })
                Button(L10n.text("app.importUncheckAll", defaultValue: "Uncheck All")) { selection.setChecked(false, for: visible) }
                    .buttonStyle(.key).disabled(scanning || !visible.contains(where: selection.isChecked))
                Spacer()
                if selectedCount > 0 {
                    Text(L10n.text("app.importSelectedCount", defaultValue: "\(selectedCount) selected"))
                        .font(.caption11).foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "square.grid.2x2").foregroundStyle(Theme.textSecondary)
                GradientAdjustmentSlider(value: thumbnailSize, range: 120...210, step: 1, neutral: 150, track: .tonal,
                                         label: L10n.text("app.importThumbnailSize", defaultValue: "Import Thumbnail Size"), change: { thumbnailSize = $0 }, commit: {})
                    .frame(width: 90, height: 28)
            }.padding(12).background(Theme.panel)
        }.background(mat.color)
    }

    private func photoGrid(_ visible: [ImportCandidate]) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 8)], spacing: 8) {
                    ForEach(visible, content: photoTile)
                }.padding(12)
            }
            .onGeometryChange(for: Int.self) { proxy in
                max(1, Int((proxy.size.width - 24 + 8) / (thumbnailSize + 8)))
            } action: { gridColumns = $0 }
            .background {
                Color.clear.focusable().focusEffectDisabled().focused($gridFocused)
                    .accessibilityLabel(L10n.text("app.showPhotos", defaultValue: "Show Photos"))
                    .allowsHitTesting(false)
            }
            .background {
                ImportGridCommands { event in handleGridKey(event, scroll: scroll) }
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
    }

    private func handleGridKey(_ event: NSEvent, scroll: ScrollViewProxy) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                selection.selectAll(shown)
                gridFocused = true
                return true
            case "d":
                selection.clearSelection()
                return true
            default: break
            }
        }
        guard gridFocused, modifiers.isEmpty || modifiers == .shift else { return false }
        let offset: Int
        switch event.keyCode {
        case 49 where modifiers.isEmpty:
            if !event.isARepeat { selection.toggleSelectedChecks(in: shown) }
            return true
        case 123: offset = -1
        case 124: offset = 1
        case 125: offset = gridColumns
        case 126: offset = -gridColumns
        default: return false
        }
        if let id = selection.move(offset, in: shown, extending: modifiers.contains(.shift)) { scroll.scrollTo(id) }
        return true
    }

    private var emptyTitle: String {
        if source == nil { return L10n.text("app.chooseAPhotoSource", defaultValue: "Choose a Photo Source") }
        if onlyNew && !candidates.isEmpty { return L10n.text("app.importNoNewPhotos", defaultValue: "No New Photos") }
        return L10n.text("app.noPhotosToDisplay", defaultValue: "No photos to display")
    }

    private func photoTile(_ item: ImportCandidate) -> some View {
        let selected = selection.selectedIDs.contains(item.id)
        let duplicate = item.alreadyImported ? L10n.text("app.alreadyInCatalog", defaultValue: "Already in Catalog") :
            L10n.text("app.importSuspectedDuplicate", defaultValue: "Suspected Duplicate")
        let status = item.problem ?? (item.isDuplicate ? duplicate : ByteCountFormatter.string(fromByteCount: item.identity.size, countStyle: .file))
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.option) {
                    selection.setChecked(!selection.isChecked(item), for: item, in: shown)
                } else {
                    selection.select(item, in: shown, extending: flags.contains(.shift), toggling: flags.contains(.command))
                }
                gridFocused = true
            } label: {
                ImportThumbnail(url: item.url, dimmed: item.isDuplicate && !selection.isChecked(item))
                    .frame(height: 116).frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!selection.canSelect(item))
            .accessibilityLabel(L10n.text("app.importSelectPhoto", defaultValue: "Select \(item.url.lastPathComponent)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            Toggle(isOn: Binding(get: { selection.isChecked(item) }, set: { selection.setChecked($0, for: item, in: shown) })) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            }
            .toggleStyle(.importCheck)
            .accessibilityHint(item.problem ?? (item.isDuplicate ? duplicate : ""))
            .disabled(!selection.canSelect(item))
            Text(status).font(.caption11).foregroundStyle(Color(nsColor: mat.textSecondary)).lineLimit(1)
        }.padding(10)
            .background(selected ? Color(nsColor: mat.selection).opacity(Metrics.thumbnailCellFill.selected) : .clear)
            .overlay { Rectangle().strokeBorder(selected ? Color(nsColor: mat.selection) : .clear, lineWidth: 2).allowsHitTesting(false) }
            .instrumentFocusMark(gridFocused && selection.activeID == item.id, color: Color(nsColor: mat.focus))
            .help(item.problem ?? item.url.path)
    }

    private var optionsPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            SubgroupLabel(L10n.text("app.fileHandling", defaultValue: "File Handling"))
            Toggle(L10n.text("app.skipCatalogedPhotos", defaultValue: "Skip Duplicates When Checking All"), isOn: $selection.skipDuplicatesOnCheckAll)
                .toggleStyle(InstrumentToggleStyle(expand: true))
                .help(L10n.text("app.skipPhotosAlreadyRegisteredInThisCatalogCopyImport", defaultValue: "Applies to Check All. You can check a duplicate directly or as part of a selection."))
            SubgroupLabel(copy ? L10n.text("app.destination_1386", defaultValue: "Destination") : L10n.text("app.photoLocation", defaultValue: "Photo Location"))
            if copy {
                Button(L10n.text("app.chooseDestinationFolder", defaultValue: "Choose Destination Folder…")) {
                    if let url = model.chooseDirectory(title: L10n.text("app.chooseCopyDestination", defaultValue: "Choose Copy Destination")) { targetLease = AccessLease(url: url); target = url }
                }.buttonStyle(.key)
                Text(target?.path ?? L10n.text("app.noDestinationFolderSelected", defaultValue: "No destination folder selected")).font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                Picker(L10n.text("app.organization", defaultValue: "Organization"), selection: $layout) {
                    ForEach(DateLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if layout != .flat {
                    TextField(L10n.text("app.archiveDateOptional", defaultValue: "Archive Date (Optional)"), text: $dateOverride).textFieldStyle(.instrument)
                    Text(L10n.text("app.leaveBlankToUseCaptureDatesFormatYyyyMM", defaultValue: "Leave blank to use capture dates. Format: yyyy-MM-dd."))
                        .font(.caption11).foregroundStyle(Theme.textSecondary)
                }
                Toggle(L10n.text("app.includeMatchingXMPACRAttachments", defaultValue: "Include Matching XMP / ACR Attachments"), isOn: $includeSidecars)
                    .toggleStyle(InstrumentToggleStyle(expand: true))
                Text(L10n.text("app.askHowToHandleFilenameConflicts", defaultValue: "Ask how to handle filename conflicts.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            } else {
                Text(L10n.text("app.originalsStayInTheirCurrentLocation", defaultValue: "Originals stay in their current location.")).foregroundStyle(Theme.textSecondary)
            }
            SubgroupLabel(L10n.text("app.sourceAssociation", defaultValue: "Source Association"))
            Toggle(L10n.text("app.rawJPEGPairing_1398", defaultValue: "RAW/JPEG Pairing"),isOn:$pairAfterImport)
                .toggleStyle(InstrumentToggleStyle(expand: true))
            Text(L10n.text("app.confirmPairsAfterImportStacksAreNotCreatedAutomatically", defaultValue: "Confirm pairs after import. Stacks are not created automatically.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            SubgroupLabel(L10n.text("app.applyDuringImport", defaultValue: "Apply During Import"))
            Picker(L10n.text("app.addToCollection", defaultValue: "Add to Collection"), selection: $collection) {
                Text(L10n.text("app.noCollection", defaultValue: "No Collection")).tag("")
                ForEach(model.collections.filter { !$0.isSmart }) { Text($0.name).tag($0.id) }
            }.labelsHidden().accessibilityLabel(L10n.text("app.addToCollectionOnImport", defaultValue: "Add to Collection on Import"))
            Spacer()
        }.padding(16).frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        let visible = shown
        let selected = visible.filter(selection.isChecked)
        return HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("app.selectedPhotos_1404", defaultValue: "Checked \(selected.count) / \(visible.count) photos · \(ByteCountFormatter.string(fromByteCount: selected.reduce(0) { $0 + $1.identity.size }, countStyle: .file))"))
                if let error { Text(error).foregroundStyle(Theme.warning).lineLimit(2) }
                if invalidDate { Text(L10n.text("app.enterAValidArchiveDateYyyyMMDd", defaultValue: "Enter a valid archive date: yyyy-MM-dd")).foregroundStyle(Theme.warning) }
            }
            Spacer()
            Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.buttonStyle(.key).keyboardShortcut(.cancelAction)
            Button(L10n.text("app.import", defaultValue: "Import")) {
                guard !scanning, !model.busy, !invalidDate, !copy || target != nil,
                      let source, let catalog = model.catalog else { return }
                let items = shown.filter(selection.isChecked)
                guard !items.isEmpty else { return }
                let sourceGrant = sourceLease, targetGrant = targetLease
                model.pendingSheetImport = { [copy, target, recursive, layout, dateOverride, includeSidecars, collection, pairAfterImport, model] in
                    defer { withExtendedLifetime((sourceGrant, targetGrant)) {} }
                    guard model.catalog === catalog else { return }
                    if copy, let target {
                        model.startCopy(source: source, target: target, selectedPaths: Set(items.map(\.id)), includeSubfolders: recursive,
                            layout: layout, dateOverride: dateOverride.isEmpty ? nil : dateOverride, includeSidecars: includeSidecars,
                            collection: collection.isEmpty ? nil : collection, pairAfterImport: pairAfterImport)
                    } else {
                        model.runReference(source: source, candidates: items, collection: collection.isEmpty ? nil : collection, pairAfterImport: pairAfterImport)
                    }
                }
                dismiss()
            }.buttonStyle(PrimaryKeyStyle()).keyboardShortcut(.defaultAction)
                .disabled(scanning || selected.isEmpty || (copy && target == nil) || model.busy || invalidDate)
        }.padding(16).background(Theme.base)
    }

    private var invalidDate: Bool {
        copy && layout != .flat && !dateOverride.isEmpty && (try? layout.directory(date: dateOverride)) == nil
    }
    private func scan() {
        scanTask?.cancel(); scanID = UUID()
        candidates = []; error = nil
        guard let source, let catalog = model.catalog else { return }
        let token = scanID, recursive = recursive
        scanning = true
        scanTask = Task {
            do {
                let result = try await model.importer.preview(source: source, includeSubfolders: recursive, catalog: catalog, mode: .browsing) { batch in
                    guard token == scanID, !Task.isCancelled else { return }
                    candidates.append(contentsOf: batch)
                }
                guard token == scanID, !Task.isCancelled else { return }
                candidates = result
                selection.retainSelection(in: shown)
            } catch {
                guard token == scanID else { return }
                candidates = []
                selection.clearSelection()
                self.error = error.localizedDescription
            }
            scanning = false
        }
    }
}

private struct ImportGridCommands: NSViewRepresentable {
    let handle: (NSEvent) -> Bool

    func makeNSView(context: Context) -> Receiver { Receiver() }
    func updateNSView(_ view: Receiver, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: Receiver, coordinator: ()) { view.removeMonitor() }

    final class Receiver: NSView {
        var handle: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !(window.firstResponder is NSTextView) else { return event }
                return self.handle?(event) == true ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private struct ImportThumbnail: View {
    let url: URL
    let dimmed: Bool
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
                    .overlay { if dimmed { Color.black.opacity(Metrics.importDuplicateShade).allowsHitTesting(false).accessibilityHidden(true) } }
            }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(Theme.textSecondary) }
        }.task(id: url, priority: .utility) {
            let result = await ImportThumbnailDecoder.shared.thumbnail(url)
            if !Task.isCancelled { image = result }
        }.onDisappear { image = nil }
    }
}

private actor ImportThumbnailDecoder {
    static let shared = ImportThumbnailDecoder()

    func thumbnail(_ url: URL) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            if let embedded = try? PhotoFileType.cameraJPEG(url, edge: 320) { return embedded }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 320
            ] as CFDictionary)
        }
    }
}
