import SwiftUI
import ImageIO

struct ImportSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var sourceLease: AccessLease?
    @State private var target: URL?
    @State private var targetLease: AccessLease?
    @State private var copy = false
    @State private var recursive = true
    @State private var skipImported = true
    @State private var onlyNew = false
    @State private var candidates: [ImportCandidate] = []
    @State private var selection: Set<String> = []
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

    private var shown: [ImportCandidate] { candidates.filter { !onlyNew || !$0.alreadyImported } }
    private var selected: [ImportCandidate] { candidates.filter { selection.contains($0.id) && eligible($0) } }
    private func eligible(_ item: ImportCandidate) -> Bool { item.problem == nil && (!skipImported || !item.alreadyImported) }

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
        .onChange(of: skipImported) { selection = selection.intersection(Set(candidates.filter(eligible).map(\.id))) }
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
                KeyRow(title: L10n.text("app.importMethod", defaultValue: "Import Method"), options: [KeyOption(true, L10n.text("app.copy_1359", defaultValue: "Copy")), KeyOption(false, L10n.text("app.added", defaultValue: "Added"))], selection: $copy, expand: true).frame(width: 230)
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
            DisclosureGroup(L10n.text("app.supportsRAWJPEGTIFFAndPNG", defaultValue: "Supports RAW, JPEG, TIFF, and PNG")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("app.rawARWDNGNEFCR3RAFVerifiedPerFile", defaultValue: "RAW: ARW, DNG, NEF, CR3, RAF, verified per file."))
                    Text(L10n.text("app.appleDNGProRAWIsNotCurrentlySupported", defaultValue: "Apple DNG / ProRAW is not currently supported."))
                    Text(L10n.text("app.tiffRGBPNGStatic816BitIncludingGrayscale", defaultValue: "TIFF: RGB. PNG: static 8/16-bit, including grayscale, indexed color, and transparency."))
                }.padding(.top, 4).fixedSize(horizontal: false, vertical: true)
            }.font(.caption11).foregroundStyle(Theme.textSecondary)
            Spacer()
        }.padding(16).frame(maxHeight: .infinity).background(Theme.panel)
    }

    private var photoPanel: some View {
        VStack(spacing: 0) {
            KeyRow(title: L10n.text("app.showPhotos", defaultValue: "Show Photos"), options: [KeyOption(false, L10n.text("app.allPhotos", defaultValue: "All Photos")), KeyOption(true, L10n.text("app.newPhotos", defaultValue: "New Photos"))], selection: $onlyNew, expand: true, height: 24)
                .frame(width: 190).frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) { Text(L10n.text("app.photos", defaultValue: "\(shown.count) photos")).foregroundStyle(Theme.textSecondary) }
                .padding(12).background(Theme.panel)
            if scanning {
                VStack(spacing: 14) { ProgressView(); Text(L10n.text("app.readingSourcePhotos", defaultValue: "Reading source photos…")); Button(L10n.text("app.cancelScan", defaultValue: "Cancel Scan")) { scanID = UUID(); scanTask?.cancel(); scanning = false }.buttonStyle(.key) }
                    .foregroundStyle(Color(nsColor: mat.text))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38)).foregroundStyle(Color(nsColor: mat.textSecondary))
                    Text(source == nil ? L10n.text("app.chooseAPhotoSource", defaultValue: "Choose a Photo Source") : L10n.text("app.noPhotosToDisplay", defaultValue: "No photos to display")).font(.title3)
                    Text(source == nil ? L10n.text("app.chooseAPhotoFolderOnTheLeft", defaultValue: "Choose a photo folder on the left.") : L10n.text("app.tryIncludeSubfoldersOrAllPhotos", defaultValue: "Try Include Subfolders or All Photos."))
                        .foregroundStyle(Color(nsColor: mat.textSecondary))
                }.foregroundStyle(Color(nsColor: mat.text)).multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 8)], spacing: 8) {
                        ForEach(shown) { item in
                            VStack(alignment: .leading, spacing: 7) {
                                ImportThumbnail(url: item.url).frame(height: 116).frame(maxWidth: .infinity)
                                Toggle(isOn: Binding(get: { selection.contains(item.id) }, set: { checked in
                                    if checked { selection.insert(item.id) } else { selection.remove(item.id) }
                                })) { Text(item.url.lastPathComponent).lineLimit(1) }
                                    .foregroundStyle(Color(nsColor: mat.text)).disabled(!eligible(item))
                                Text(item.problem ?? (item.alreadyImported ? L10n.text("app.alreadyInCatalog", defaultValue: "Already in Catalog") : ByteCountFormatter.string(fromByteCount: item.identity.size, countStyle: .file)))
                                    .font(.caption11).foregroundStyle(Color(nsColor: mat.textSecondary)).lineLimit(1)
                            }.padding(10)
                                .overlay(Rectangle().strokeBorder(selection.contains(item.id) ? Color(nsColor: mat.selection) : .clear, lineWidth: 2))
                                .help(item.problem ?? item.url.path)
                        }
                    }.padding(12)
                }
            }
            Seam()
            HStack {
                Button(L10n.text("app.selectAll", defaultValue: "Select All")) { selection.formUnion(shown.filter(eligible).map(\.id)) }.buttonStyle(.key)
                Button(L10n.text("app.deselectAll", defaultValue: "Deselect All")) { selection.subtract(shown.map(\.id)) }.buttonStyle(.key)
                Spacer()
                Image(systemName: "square.grid.2x2").foregroundStyle(Theme.textSecondary)
                GradientAdjustmentSlider(value: thumbnailSize, range: 120...210, step: 1, neutral: 150, track: .tonal,
                                         label: L10n.text("app.importThumbnailSize", defaultValue: "Import Thumbnail Size"), change: { thumbnailSize = $0 }, commit: {})
                    .frame(width: 90, height: 28)
            }.padding(12).background(Theme.panel).disabled(scanning)
        }.background(mat.color)
    }

    private var optionsPanel: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            SubgroupLabel(L10n.text("app.fileHandling", defaultValue: "File Handling"))
            Toggle(L10n.text("app.skipCatalogedPhotos", defaultValue: "Skip Cataloged Photos"), isOn: $skipImported)
                .toggleStyle(InstrumentToggleStyle(expand: true))
                .help(L10n.text("app.skipPhotosAlreadyRegisteredInThisCatalogCopyImport", defaultValue: "Skip photos already registered in this catalog. Copy import reuses verified destination files with identical contents."))
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
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("app.selectedPhotos_1404", defaultValue: "Selected \(selected.count) / \(candidates.count) photos · \(ByteCountFormatter.string(fromByteCount: selected.reduce(0) { $0 + $1.identity.size }, countStyle: .file))"))
                if let error { Text(error).foregroundStyle(Theme.warning).lineLimit(2) }
                if invalidDate { Text(L10n.text("app.enterAValidArchiveDateYyyyMMDd", defaultValue: "Enter a valid archive date: yyyy-MM-dd")).foregroundStyle(Theme.warning) }
            }
            Spacer()
            Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.buttonStyle(.key).keyboardShortcut(.cancelAction)
            Button(L10n.text("app.import", defaultValue: "Import")) {
                guard let source else { return }
                if copy, let target {
                    model.startCopy(source: source, target: target, selectedPaths: Set(selected.map(\.id)), includeSubfolders: recursive,
                        layout: layout, dateOverride: dateOverride.isEmpty ? nil : dateOverride, includeSidecars: includeSidecars,
                        collection: collection.isEmpty ? nil : collection, pairAfterImport:pairAfterImport)
                } else { model.runReference(source: source, candidates: selected, collection: collection.isEmpty ? nil : collection, pairAfterImport:pairAfterImport) }
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
        candidates = []; selection = []; error = nil
        guard let source, let catalog = model.catalog else { return }
        let token = scanID, recursive = recursive
        scanning = true
        scanTask = Task {
            do {
                let result = try await model.importer.preview(source: source, includeSubfolders: recursive, catalog: catalog)
                guard token == scanID, !Task.isCancelled else { return }
                candidates = result; selection = Set(result.filter(eligible).map(\.id))
            } catch {
                guard token == scanID else { return }
                self.error = error.localizedDescription
            }
            scanning = false
        }
    }
}

struct ImportThumbnail: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(Theme.textSecondary) }
        }.task(id: url) {
            let work = Task.detached(priority: .utility) { () -> CGImage? in
                guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            if !Task.isCancelled { image = result }
        }
    }
}
