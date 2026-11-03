import SwiftUI

/// Navigation and blocking feedback share the same destinations.
enum ExportSection: String, CaseIterable, Identifiable {
    case destination = "导出位置", image = "文件设置", naming = "文件命名", metadata = "元数据", review = "检查文件"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .destination: "folder"
        case .image: "photo"
        case .naming: "textformat.abc"
        case .metadata: "info.circle"
        case .review: "checklist"
        }
    }
    var title: String {
        switch self {
        case .destination: L10n.text("app.destination", defaultValue: "Destination")
        case .image: L10n.text("app.fileSettings", defaultValue: "File Settings")
        case .naming: L10n.text("app.fileNaming", defaultValue: "File Naming")
        case .metadata: L10n.text("app.metadata", defaultValue: "Metadata")
        case .review: L10n.text("app.reviewFiles", defaultValue: "Review Files")
        }
    }

}

struct ExportFormIssue: Equatable {
    let section: ExportSection
    let message: String
}

/// UI readiness supplements, but never replaces, the submission-time file checks.
struct ExportReadiness {
    var loaded: Bool
    var photoCount: Int
    var multiple: Bool
    var options: ExportOptions
    var namingInputValid: Bool
    var sizeInputValid: Bool
    var directory: URL?
    var names: [ExportName]
    var previewError: String?
    var matteReady: Bool
    var matteError: String?
    var busy: Bool
    var batchPlan: ExportBatchPlan?
    var batchPreviewError: String?

    init(loaded: Bool, photoCount: Int, options: ExportOptions, namingInputValid: Bool,
         sizeInputValid: Bool, directory: URL?, names: [ExportName], previewError: String?,
         matteReady: Bool, matteError: String?, busy: Bool, multiple: Bool = false,
         batchPlan: ExportBatchPlan? = nil, batchPreviewError: String? = nil) {
        self.loaded = loaded
        self.photoCount = photoCount
        self.multiple = multiple
        self.options = options
        self.namingInputValid = namingInputValid
        self.sizeInputValid = sizeInputValid
        self.directory = directory
        self.names = names
        self.previewError = previewError
        self.matteReady = matteReady
        self.matteError = matteError
        self.busy = busy
        self.batchPlan = batchPlan
        self.batchPreviewError = batchPreviewError
    }

    var presetIssue: ExportFormIssue? {
        if !loaded { return .init(section: .image, message: L10n.text("app.exportSettingsAreNotLoadedResolveTheSettingsRead", defaultValue: "Export settings are not loaded. Resolve the settings read error first.")) }
        if multiple {
            if let batchPreviewError { return .init(section: .review, message: batchPreviewError) }
            guard let batchPlan else { return .init(section: .image, message: L10n.text("app.chooseAParentDestinationFolderAndAddAtLeast", defaultValue: "Choose a parent destination folder and add at least one output variant.")) }
            if let issue = batchPlan.issues.first { return .init(section: .review, message: issue) }
            if batchPlan.requests.isEmpty { return .init(section: .review, message: L10n.text("app.noFilenamesWereGeneratedForMultipleSizeOutput", defaultValue: "No filenames were generated for multiple-size output.")) }
            return nil
        }
        if !sizeInputValid { return .init(section: .image, message: L10n.text("app.enterALongEdgeBetween1And30000Pixels", defaultValue: "Enter a long edge between 1 and 30000 pixels.")) }
        if !namingInputValid { return .init(section: .naming, message: L10n.text("app.correctTheSequenceStartOrPaddingDigits", defaultValue: "Correct the sequence start or padding digits.")) }
        do { try options.naming.validate() }
        catch { return .init(section: .naming, message: error.localizedDescription) }
        do { try options.validate() }
        catch { return .init(section: .image, message: error.localizedDescription) }
        if options.format == .jpeg && options.jpegMatte == .unselected {
            return .init(section: .image, message: L10n.text("app.chooseAJPEGMatteColorForTransparentAreas", defaultValue: "Choose a JPEG matte color for transparent areas."))
        }
        return nil
    }
    var issue: ExportFormIssue? {
        if let presetIssue { return presetIssue }
        if photoCount == 0 { return .init(section: .review, message: L10n.text("app.noPhotosToExportCloseThisWindowAndSelect", defaultValue: "No photos to export. Close this window and select photos again.")) }
        if directory == nil { return .init(section: .destination, message: L10n.text("app.chooseWhereToSaveTheOutputFiles", defaultValue: "Choose where to save the output files.")) }
        if multiple {
            if busy { return .init(section: .review, message: L10n.text("app.waitForTheCurrentTaskToFinish", defaultValue: "Wait for the current task to finish.")) }
            return nil
        }
        if let previewError { return .init(section: .review, message: previewError) }
        if let item = names.first(where: { !$0.errors.isEmpty }) {
            return .init(section: .review, message: "\(item.filename)：\(item.errors[0])")
        }
        if names.count != photoCount { return .init(section: .review, message: L10n.text("app.theFilenamePreviewIsIncompleteCheckAgain", defaultValue: "The filename preview is incomplete. Check again.")) }
        if options.format == .jpeg {
            if let matteError { return .init(section: .image, message: L10n.text("app.mattePreviewFailed", defaultValue: "Matte preview failed: \(matteError)")) }
            if !matteReady { return .init(section: .image, message: L10n.text("app.generatingJPEGMattePreview", defaultValue: "Generating JPEG matte preview…")) }
        }
        if busy { return .init(section: .review, message: L10n.text("app.waitForTheCurrentTaskToFinish", defaultValue: "Wait for the current task to finish.")) }
        return nil
    }
}

struct ExportSheet: View {
    @Bindable var model: AppModel
    var defaults: UserDefaults = .standard
    @State private var options = ExportOptions()
    @State private var multiple = false
    @State private var batchDrafts: [ExportBatchDraft] = []
    @State private var batchPlan: ExportBatchPlan?
    @State private var batchPreviewError: String?
    @State private var preferences = ExportPreferences()
    @State private var presetID = "custom"
    @State private var loaded = false
    @State private var error: String?
    @State private var naming = false
    @State private var renaming = false
    @State private var name = ""
    @State private var photos: [Photo] = []
    @State private var names: [ExportName] = []
    @State private var directory: URL?
    @State private var targetAccess: AccessLease?
    @State private var previewError: String?
    @State private var mattePhotoID = ""
    @State private var matteImage: CGImage?
    @State private var matteError: String?
    @State private var matteReady = ""
    @State private var namingInputValid = true
    @State private var sizeInputValid = true
    @State private var mattePipeline = ImagePipeline()
    @State private var showAllNames = false
    @State private var deletingPreset = false
    @State private var inputRevision = 0
    private var matteToken: String { "\(options.format):\(options.jpegMatte):\(options.longEdge ?? 0):\(mattePhotoID)" }
    private var presets: [ExportPreset] { ExportPreset.builtIns + preferences.presets }
    private var selected: ExportPreset? { preferences.presets.first { $0.id == presetID } }
    private var readiness: ExportReadiness {
        ExportReadiness(loaded: loaded, photoCount: photos.count, options: options, namingInputValid: namingInputValid,
                        sizeInputValid: sizeInputValid, directory: directory, names: names, previewError: previewError,
                        matteReady: matteReady == matteToken, matteError: matteError, busy: model.busy,
                        multiple: multiple, batchPlan: batchPlan, batchPreviewError: batchPreviewError)
    }
    private var currentSummary: String { multiple ? (batchPlan?.summary ?? L10n.text("app.multipleSizeOutput", defaultValue: "Multiple-Size Output")) : options.summary }
    private var allPresets: [ExportPreset] { ExportPreset.builtIns + preferences.presets }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("app.exportPhotos", defaultValue: "Export \(photos.count) Photos")).font(.headline)
                    Spacer()
                    Text(L10n.text("app.selectedPhotosCurrentCatalogOrder", defaultValue: "Selected photos · Current catalog order")).font(.caption11).foregroundStyle(Theme.textSecondary)
                }.padding(20)
                Seam()
                HStack(spacing: 0) {
                    navigation(proxy)
                    Seam(axis: .vertical)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            destinationSection
                            imageSection
                            namingSection
                            metadataSection
                            reviewSection
                        }.padding(20)
                    }.accessibilityIdentifier("export-options-scroll")
                }
                Seam()
                footer(proxy)
            }
        }.frame(width: 860, height: 580).instrumentForm()
        .onAppear(perform: load)
        .onChange(of: presetID) {
            guard !multiple else { return }
            if let preset = presets.first(where: { $0.id == presetID }) {
                options = preset.options
                inputRevision += 1
                namingInputValid = true; sizeInputValid = true
            }
        }
        .onChange(of: options) {
            guard !multiple else { return }
            if presets.first(where: { $0.id == presetID })?.options != options { presetID = "custom" }
            refreshPreview()
        }
        .onChange(of: multiple) {
            if multiple {
                if batchDrafts.isEmpty { batchDrafts = defaultBatchDrafts() }
            }
            refreshPreview()
        }
        .onChange(of: batchDrafts) { if multiple { refreshPreview() } }
        .task(id: matteToken) { await refreshMatte() }
        .alert(renaming ? L10n.text("app.renameExportPreset", defaultValue: "Rename Export Preset") : L10n.text("app.saveExportPreset", defaultValue: "Save Export Preset"), isPresented: $naming) {
            TextField(L10n.text("app.presetName", defaultValue: "Preset Name"), text: $name)
            Button(L10n.text("app.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(L10n.text("app.save", defaultValue: "Save")) {
                do {
                    var next = preferences
                    let id = try next.storePreset(name: name, options: options, id: renaming ? presetID : nil)
                    if persist(next) { presetID = id }
                } catch { self.error = error.localizedDescription }
            }
        } message: { Text(L10n.text("app.savesOutputOptionsOnlyWithoutTheDestinationFolderNames", defaultValue: "Saves output options only, without the destination folder. Names support up to 100 characters.")) }
        .confirmationDialog(L10n.text("app.deletePreset_1248", defaultValue: "Delete preset “\(selected?.name ?? "")”?"), isPresented: $deletingPreset, titleVisibility: .visible) {
            Button(L10n.text("app.deletePreset", defaultValue: "Delete Preset"), role: .destructive) {
                guard let selected else { return }
                var next = preferences; next.presets.removeAll { $0.id == selected.id }
                if persist(next) { presetID = "custom" }
            }
            Button(L10n.text("app.cancel", defaultValue: "Cancel"), role: .cancel) {}
        }
    }
    private func navigation(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("app.exportPresets", defaultValue: "Export Presets")).font(.section)
            if multiple {
                Text(L10n.text("app.chooseABuiltInOrUserPresetForEach", defaultValue: "Choose a built-in or user preset for each variant on the right."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            } else {
                Picker(L10n.text("app.exportPresets", defaultValue: "Export Presets"), selection: $presetID) {
                    Text(L10n.text("app.currentSettings", defaultValue: "Current Settings")).tag("custom")
                    Section(L10n.text("app.builtInPresets", defaultValue: "Built-In Presets")) { ForEach(ExportPreset.builtIns) { Text($0.name).tag($0.id) } }
                    if !preferences.presets.isEmpty {
                        Section(L10n.text("app.myPresets", defaultValue: "My Presets")) { ForEach(preferences.presets) { Text($0.name).tag($0.id) } }
                    }
                }.labelsHidden().disabled(!loaded).accessibilityIdentifier("export-preset")
                Menu(L10n.text("app.managePresets", defaultValue: "Manage Presets")) {
                    Button(L10n.text("app.saveAsPreset", defaultValue: "Save as Preset…")) { renaming = false; name = ""; naming = true }.disabled(readiness.presetIssue != nil)
                    if let selected {
                        Button(L10n.text("app.rename", defaultValue: "Rename…")) { renaming = true; name = selected.name; naming = true }
                        Button(L10n.text("app.deletePreset_1257", defaultValue: "Delete Preset…"), role: .destructive) { deletingPreset = true }
                    }
                }.disabled(!loaded).menuStyle(.borderlessButton).keySurface()
                }
            Seam().padding(.vertical, 4)
            ForEach(ExportSection.allCases) { section in
                Button { proxy.scrollTo(section, anchor: .top) } label: {
                    Label(section.title, systemImage: section.symbol).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.key).accessibilityIdentifier("export-jump-\(section)")
            }
            Spacer(minLength: 8)
            Text(L10n.text("app.outputsAlwaysUseSRGBNExistingFilenamesPreventExport", defaultValue: "Outputs always use sRGB.\nExisting filenames prevent export.")).font(.caption11).foregroundStyle(Theme.textSecondary).lineSpacing(4)
        }.padding(16).frame(width: 182)
    }
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubgroupLabel(ExportSection.destination.title)
            KeyRow(title: L10n.text("app.outputMode", defaultValue: "Output Mode"), options: [KeyOption(false, L10n.text("app.singleVariant", defaultValue: "Single Variant")), KeyOption(true, L10n.text("app.multipleVariants", defaultValue: "Multiple Variants"))],
                   selection: $multiple, lampsInside: true, expand: true)
                .disabled(!loaded).accessibilityIdentifier("export-output-mode")
            Text(multiple ? L10n.text("app.eachVariantUsesASeparateSubfolderUnderOneParent", defaultValue: "Each variant uses a separate subfolder under one parent destination. Presets supply output options only.") : L10n.text("app.theSingleVariantUsesTheCurrentPresetAndFull", defaultValue: "The single variant uses the current preset and full output settings."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(directory?.lastPathComponent ?? L10n.text("app.noFolderSelected", defaultValue: "No folder selected")).font(.section)
                    if let directory { Text(directory.path).font(.caption11).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(directory == nil ? L10n.text("app.chooseFolder", defaultValue: "Choose Folder…") : L10n.text("app.change", defaultValue: "Change…"), action: chooseDirectory)
                    .buttonStyle(.key).accessibilityIdentifier("export-directory")
            }.padding(12).background(Theme.inset)
            Text(L10n.text("app.saveNewOutputsWhilePreservingOriginalsIfFilenamesAlready", defaultValue: "Save new outputs while preserving originals. If filenames already exist, change the destination or naming.")).font(.caption11).foregroundStyle(Theme.textSecondary)
        }.id(ExportSection.destination)
    }
    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubgroupLabel(ExportSection.image.title)
            if multiple {
                multiSpecForm
            } else {
                ExportOptionsForm(options: $options, validationChanged: { sizeInputValid = $0 }).id(inputRevision).disabled(!loaded)
            }
            if !multiple && options.format == .jpeg {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let matteImage, matteReady == matteToken {
                            Image(decorative: matteImage, scale: 1).resizable().scaledToFit()
                        } else { Text(options.jpegMatte == .unselected ? L10n.text("app.chooseAMatteColor", defaultValue: "Choose a Matte Color") : matteError == nil ? L10n.text("app.generatingPreview", defaultValue: "Generating preview…") : L10n.text("app.previewIncomplete", defaultValue: "Preview incomplete")).font(.caption11) }
                    }.frame(width: 160, height: 120).background(Theme.inset)
                        .accessibilityLabel(L10n.text("app.jpegMattePreview", defaultValue: "JPEG Matte Preview"))
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L10n.text("app.previewPhoto", defaultValue: "Preview Photo"), selection: $mattePhotoID) { ForEach(photos) { Text($0.displayName).tag($0.id) } }
                            .accessibilityIdentifier("export-matte-photo")
                        Text(L10n.text("app.theCurrentPhotoBeforeCompressionTransparentContentAndGeometry", defaultValue: "The current photo before compression. Transparent content and geometry gaps use the same matte color. Switch photos to inspect.")).font(.caption11).foregroundStyle(Theme.textSecondary)
                        if let matteError { Text(matteError).font(.caption11).foregroundStyle(Theme.error) }
                    }
                }
            }
        }.id(ExportSection.image)
    }
    private var namingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubgroupLabel(ExportSection.naming.title)
            if multiple {
                Text(L10n.text("app.eachVariantUsesItsPresetSNamingComponentsFull", defaultValue: "Each variant uses its preset's naming components. Full paths are previewed below; these selections preserve presets."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            } else {
                ExportNamingForm(naming: $options.naming, photo: photos.first, preview: names.first?.filename,
                                 validationChanged: { namingInputValid = $0 }).id(inputRevision).disabled(!loaded)
            }
        }.id(ExportSection.naming)
    }

    private var multiSpecForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach($batchDrafts) { draft in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L10n.text("app.variant", defaultValue: "Variant \(batchDrafts.firstIndex(where: { $0.id == draft.wrappedValue.id }).map { $0 + 1 } ?? 0)"))
                            .font(.section)
                        Spacer()
                        if batchDrafts.count > 1 {
                            Button(L10n.text("app.removed", defaultValue: "Removed")) { batchDrafts.removeAll { $0.id == draft.wrappedValue.id } }
                                .buttonStyle(.key).accessibilityIdentifier("export-multi-remove-\(draft.wrappedValue.id)")
                        }
                    }
                    Picker(L10n.text("app.outputPreset", defaultValue: "Output Preset"), selection: presetBinding(for: draft)) {
                        ForEach(ExportPreset.builtIns) { Text($0.name).tag($0.id) }
                        if !preferences.presets.isEmpty {
                            Section(L10n.text("app.myPresets", defaultValue: "My Presets")) { ForEach(preferences.presets) { Text($0.name).tag($0.id) } }
                        }
                    }.accessibilityIdentifier("export-multi-preset-\(draft.wrappedValue.id)")
                    HStack(spacing: 10) {
                        Text(L10n.text("app.subfolder", defaultValue: "Subfolder")).frame(width: Metrics.rowLabel, alignment: .leading)
                        TextField(L10n.text("app.forExampleWebSharing", defaultValue: "For example: Web Sharing"), text: Binding(get: { draft.wrappedValue.subfolder }, set: { draft.wrappedValue.subfolder = $0 }))
                            .textFieldStyle(.instrument)
                            .accessibilityLabel(L10n.text("app.variantSubfolder", defaultValue: "Variant Subfolder"))
                            .accessibilityIdentifier("export-multi-subfolder-\(draft.wrappedValue.id)")
                    }
                    if draft.wrappedValue.options.format == .jpeg {
                        KeyRow(title: L10n.text("app.jpegTransparencyMatte", defaultValue: "JPEG Transparency Matte"), options: [KeyOption(JPEGMatte.black, L10n.text("app.blackMatte", defaultValue: "Black Matte")), KeyOption(JPEGMatte.white, L10n.text("app.whiteMatte", defaultValue: "White Matte"))],
                               selection: Binding(get: { draft.wrappedValue.options.jpegMatte }, set: { draft.wrappedValue.options.jpegMatte = $0 }),
                               expand: true).accessibilityIdentifier("export-multi-jpeg-matte-\(draft.wrappedValue.id)")
                    }
                    Text(draft.wrappedValue.options.summary).font(.caption11).foregroundStyle(Theme.textSecondary)
                    Text(L10n.text("app.selectionsAndDraftsApplyToThisOutputOnlyUser", defaultValue: "Selections and drafts apply to this output only. User presets are preserved."))
                        .font(.caption11).foregroundStyle(Theme.textSecondary)
                }.padding(12).background(Theme.inset).accessibilityIdentifier("export-multi-spec-\(draft.wrappedValue.id)")
            }
            HStack {
                Button(L10n.text("app.addOutputVariant", defaultValue: "Add Output Variant")) { addBatchDraft() }.buttonStyle(.key).accessibilityIdentifier("export-multi-add")
                Spacer()
                Text(L10n.text("app.eachVariantHasItsOwnFilenamesAndSubfolderAll", defaultValue: "Each variant has its own filenames and subfolder. All variants are checked before submission."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func multiReviewSection() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SubgroupLabel(ExportSection.review.title)
            HStack {
                Text(batchPlan?.issues.isEmpty == false ? L10n.text("app.foundBlockingIssues", defaultValue: "Found \(batchPlan?.issues.count ?? 0) blocking issues") : L10n.text("app.generatedFilenames", defaultValue: "Generated \(batchPlan?.outputCount ?? 0) filenames"))
                    .foregroundStyle(batchPlan?.issues.isEmpty == false ? Theme.error : Theme.text)
                Spacer()
                Button(L10n.text("app.checkAgain", defaultValue: "Check Again"), action: refreshPreview).buttonStyle(.key)
            }
            if let batchPreviewError { Text(batchPreviewError).font(.caption11).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true) }
            if let batchPlan {
                ForEach(batchPlan.groups) { group in
                    DisclosureGroup(group.summary, isExpanded: .constant(true)) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(group.requests) { request in nameRow(request.name, destination: request.destination) }
                        }.padding(.top, 8)
                    }
                }
                ForEach(batchPlan.issues, id: \.self) { issue in
                    Text(issue).font(.caption11).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L10n.text("app.filenamesSubfoldersBatchConflictsAndOriginalProtectionAreFrozen", defaultValue: "Filenames, subfolders, batch conflicts, and original protection are frozen before submission. Later destination conflicts are preserved and reported by the export queue."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
        }.id(ExportSection.review).accessibilityIdentifier("export-multi-name-preview")
    }

    private func defaultBatchDrafts() -> [ExportBatchDraft] {
        let candidates = [ExportPreset.builtIns.first(where: { $0.id == "tiff" }), ExportPreset.builtIns.first(where: { $0.id == "png" })].compactMap { $0 }
        return candidates.enumerated().map { index, preset in
            ExportBatchDraft(preset: preset, subfolder: index == 0 ? "TIFF" : "PNG")
        }
    }

    private func addBatchDraft() {
        guard let preset = allPresets.first else { return }
        let base = preset.name
        var candidate = base
        var number = 2
        while batchDrafts.contains(where: { ExportNamingPlanner.collisionKey($0.subfolder) == ExportNamingPlanner.collisionKey(candidate) }) {
            candidate = "\(base)-\(number)"; number += 1
        }
        batchDrafts.append(ExportBatchDraft(preset: preset, subfolder: candidate))
    }

    private func presetBinding(for draft: Binding<ExportBatchDraft>) -> Binding<String> {
        Binding(get: { draft.wrappedValue.presetID }, set: { id in
            guard let preset = allPresets.first(where: { $0.id == id }) else { return }
            draft.wrappedValue.presetID = preset.id
            draft.wrappedValue.title = preset.name
            draft.wrappedValue.options = preset.options
        })
    }

    private var metadataExplanation: String {
        switch options.metadataPolicy {
        case .none: L10n.text("app.excludesCaptureMetadataKeywordsAndCaptionsOutputsStillContain", defaultValue: "Excludes capture metadata, keywords, and captions. Outputs still contain the dimensions, orientation, and color description needed for display.")
        case .capture: L10n.text("app.keepsValidCameraLensCaptureTimeISOApertureShutter", defaultValue: "Keeps valid camera, lens, capture time, ISO, aperture, shutter, and focal length. Missing fields are omitted.")
        case .description: L10n.text("app.includesOnlyTheSelectedVersionSKeywordsAndCaption", defaultValue: "Includes only the selected version's keywords and caption. Empty fields and capture metadata are omitted.")
        case .captureAndDescription: L10n.text("app.includesSupportedCaptureMetadataAndTheSelectedVersionS", defaultValue: "Includes supported capture metadata and the selected version's keywords and caption. Empty fields are omitted.")
        }
    }
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SubgroupLabel(ExportSection.metadata.title)
            if multiple {
                Text(L10n.text("app.eachVariantUsesItsPresetSMetadataPolicyPresets", defaultValue: "Each variant uses its preset's metadata policy. Presets exclude folder authorization and parent destinations."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            } else {
                KeyRow(title: L10n.text("app.outputMetadata", defaultValue: "Output Metadata"), options: [KeyOption(ExportMetadataPolicy.none, L10n.text("app.none_1295", defaultValue: "None")), KeyOption(.capture, L10n.text("app.capture", defaultValue: "Capture")), KeyOption(.description, L10n.text("app.keywordsAndCaption", defaultValue: "Keywords and Caption")), KeyOption(.captureAndDescription, L10n.text("app.both", defaultValue: "Both"))],
                       selection: $options.metadataPolicy, lampsInside: true, expand: true)
                    .disabled(!loaded).accessibilityIdentifier("export-metadata")
                Text(metadataExplanation)
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            Text(L10n.text("app.gpsDeviceSerialNumbersSourcePathsAndEditRecipes", defaultValue: "GPS, device serial numbers, source paths, and edit recipes are always excluded.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            DisclosureGroup(L10n.text("app.fieldDetailsAndVerification", defaultValue: "Field Details and Verification")) {
                Text(L10n.text("app.captureFieldsAreLimitedToCameraLensTimeISO", defaultValue: "Capture fields are limited to camera / lens, time, ISO, aperture, shutter, and focal length. Keywords and captions come from the selected version and are frozen at submission. Only corresponding XMP / IPTC fields are generated; original XMP, MakerNotes, and thumbnails are excluded. Orientation, dimensions, ICC, and bit depth reflect the output. Readback mismatches stop publication. Originals are preserved."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).padding(.top, 6)
            }
        }.id(ExportSection.metadata)
    }
    @ViewBuilder private var reviewSection: some View {
        if multiple {
            multiReviewSection()
        } else {
        VStack(alignment: .leading, spacing: 12) {
            SubgroupLabel(ExportSection.review.title)
            HStack {
                Text(names.contains { !$0.errors.isEmpty } ? L10n.text("app.foundNamingOrFileConflicts", defaultValue: "Found \(names.filter { !$0.errors.isEmpty }.count) naming or file conflicts") : L10n.text("app.generatedFilenames", defaultValue: "Generated \(names.count) filenames"))
                    .foregroundStyle(names.contains { !$0.errors.isEmpty } ? Theme.error : Theme.text)
                Spacer()
                Button(L10n.text("app.checkAgain", defaultValue: "Check Again"), action: refreshPreview).buttonStyle(.key)
            }
            if let previewError { Text(previewError).font(.caption11).foregroundStyle(Theme.error) }
            if let first = names.first { nameRow(first) }
            if names.count > 1 {
                DisclosureGroup(L10n.text("app.viewMoreFilenames", defaultValue: "View \(names.count - 1) More Filenames"), isExpanded: $showAllNames) {
                    LazyVStack(alignment: .leading, spacing: 12) { ForEach(names.dropFirst()) { nameRow($0) } }.padding(.top, 8)
                }
            }
            Text(L10n.text("app.sequenceNumbersFollowTheCurrentCatalogOrderAndRemain", defaultValue: "Sequence numbers follow the current catalog order and remain fixed for retries. Destinations are checked again before export; later conflicts do not rename or overwrite files.")).font(.caption11).foregroundStyle(Theme.textSecondary)
        }.id(ExportSection.review).accessibilityIdentifier("export-name-preview")
        }
    }
    private func nameRow(_ item: ExportName, destination: URL? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let label = destination.map { "\(item.sourceName) → \($0.path)" } ?? "\(item.sourceName) → \(item.filename)"
            Text(label).font(.value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(label)
            ForEach(item.warnings, id: \.self) { Text($0).font(.caption11).foregroundStyle(Theme.warning) }
            ForEach(item.errors, id: \.self) { Text($0).font(.caption11).foregroundStyle(Theme.error) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Theme.inset)
    }
    private func footer(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                HStack(alignment: .top) {
                    Text(error).font(.caption11).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if !loaded { Button(L10n.text("app.useDefaultSettings", defaultValue: "Use Default Settings")) { preferences = ExportPreferences(); options = preferences.lastOptions; loaded = true; self.error = nil; refreshPreview() }.buttonStyle(.key) }
                }
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(currentSummary).font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    if let issue = readiness.issue {
                        Button { proxy.scrollTo(issue.section, anchor: .top); if issue.section == .review { showAllNames = true } } label: {
                            Label(issue.message, systemImage: "exclamationmark.circle").lineLimit(2).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain).font(.caption11).foregroundStyle(Theme.warning).accessibilityIdentifier("export-blocking-reason")
                    } else {
                        Label(L10n.text("app.readyProgressAndResultsWillAppearInTheWorkspace", defaultValue: "Ready · Progress and results will appear in the workspace"), systemImage: "checkmark.circle").font(.caption11).foregroundStyle(Theme.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { model.showExport = false }.buttonStyle(.key).keyboardShortcut(.cancelAction)
                Button(multiple ? L10n.text("app.exportFiles", defaultValue: "Export \(batchPlan?.outputCount ?? 0) Files") : L10n.text("app.exportPhotos_1307", defaultValue: "Export \(photos.count) Photos"), action: submit).buttonStyle(PrimaryKeyStyle()).keyboardShortcut(.defaultAction)
                    .disabled(readiness.issue != nil).accessibilityIdentifier("export-submit")
            }
        }.padding(16)
    }
    private func load() {
        do {
            photos = try model.exportSelection()
            mattePhotoID = photos.first(where: { $0.id == model.activeID })?.id ?? photos.first?.id ?? ""
        } catch { self.error = error.localizedDescription }
        do {
            preferences = try ExportPreferences.load(from: defaults)
            options = model.requestedExportPreset?.options ?? preferences.lastOptions
            presetID = model.requestedExportPreset?.id ?? "custom"
            loaded = true
        }
        catch { self.error = L10n.text("app.cannotReadExportSettings", defaultValue: "Cannot read export settings: \(error.localizedDescription)") }
        multiple = false
        batchDrafts = []
        refreshPreview()
    }
    private func chooseDirectory() {
        if let url = model.chooseDirectory(title: L10n.text("app.chooseOutputDestination", defaultValue: "Choose Output Destination")) {
            targetAccess = AccessLease(url: url); directory = url; refreshPreview()
        }
    }
    private func submit() {
        refreshPreview()
        guard readiness.issue == nil, let directory else { return }
        if multiple {
            guard let plan = batchPlan else { return }
            let access = targetAccess ?? AccessLease(url: directory)
            targetAccess = access
            if !model.export(specifications: plan.specifications, directory: directory, access: access, photos: photos) {
                error = model.error ?? L10n.text("app.multipleSizeExportDidNotStartCheckTheCurrent", defaultValue: "Multiple-size export did not start. Check the current task status."); model.error = nil
            }
            return
        }
        guard persist(preferences) else { return }
        if !model.export(options: options, photos: photos, names: names, directory: directory) {
            error = model.error ?? L10n.text("app.exportDidNotStartCheckTheCurrentTaskStatus", defaultValue: "Export did not start. Check the current task status."); model.error = nil
        }
    }
    private func refreshPreview() {
        if multiple {
            names = []; previewError = nil; batchPlan = nil; batchPreviewError = nil
            guard let directory else { return }
            do {
                let specs = batchDrafts.map { ExportSpecification(id: $0.id, title: $0.title, subfolder: $0.subfolder, options: $0.options) }
                let originals = photos.compactMap { photo in
                    model.roots.first(where: { $0.id == photo.rootID }).map { URL(fileURLWithPath: $0.path).appendingPathComponent(photo.relativePath) }
                }
                batchPlan = try ExportBatchPlanner.plan(photos: photos, specifications: specs, directory: directory, originalURLs: originals)
            } catch { batchPreviewError = error.localizedDescription }
            return
        }
        do { names = try ExportNamingPlanner.preview(photos: photos, options: options, directory: directory); previewError = nil }
        catch { names = []; previewError = error.localizedDescription }
    }
    @MainActor private func refreshMatte() async {
        let token = matteToken
        matteImage = nil; matteError = nil; matteReady = ""
        guard options.format == .jpeg, options.jpegMatte != .unselected,
              let photo = photos.first(where: { $0.id == mattePhotoID }) else { return }
        do {
            guard let root = model.roots.first(where: { $0.id == photo.rootID }) else { throw LRCError(L10n.text("app.thePreviewSourceRootFolderIsMissing", defaultValue: "The preview source root folder is missing")) }
            let recipe = photo.id == model.activeID ? model.recipe : try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self,from:$0) }
            let request = ImageRequest(photo:photo,root:root,recipe:recipe)
            let resolved = recipe == nil && photo.isRAW ? try await mattePipeline.baseline(request) : recipe
            let result = try await mattePipeline.render(ImageRequest(photo:photo,root:root,recipe:resolved),
                longEdge:min(640,options.longEdge ?? 640),jpegMatte:options.jpegMatte)
            try Task.checkCancellation()
            guard token == matteToken else { return }
            matteImage = result.image; matteReady = token
        } catch {
            guard !Task.isCancelled, token == matteToken else { return }
            matteError = error.localizedDescription
        }
    }
    private func persist(_ preferences: ExportPreferences) -> Bool {
        do {
            var next = preferences; next.lastOptions = options
            try next.save(to: defaults)
            self.preferences = next; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct ExportNamingForm: View {
    @Binding var naming: ExportNaming
    var photo: Photo?
    var preview: String?
    var validationChanged: (Bool) -> Void = { _ in }
    @State private var startValid = true
    @State private var digitsValid = true
    private var datePart: String {
        guard let photo else { return "—" }
        return LibraryMetadataFilter.day(photo.captureDate)?.replacingOccurrences(of: "-", with: "") ?? "undated"
    }
    private var originalPart: String {
        guard let photo else { return "—" }
        return [(photo.name as NSString).deletingPathExtension, photo.copyName].compactMap { $0 }.joined(separator: "_")
    }
    private var sequencePart: String {
        let number = String(naming.start)
        return String(repeating: "0", count: max(0, min(9, naming.digits) - number.count)) + number
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("app.filenameComponentsDateOriginalNameSequence", defaultValue: "Filename Components · Date → Original Name → Sequence")).font(.caption11).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                component(L10n.text("app.captureDate", defaultValue: "Capture Date"), value: datePart, selection: $naming.captureDate, identifier: "export-naming-date")
                component(L10n.text("app.originalFilename", defaultValue: "Original Filename"), value: originalPart, selection: $naming.originalName, identifier: "export-naming-original")
                component(L10n.text("app.sequenceNumber", defaultValue: "Sequence Number"), value: sequencePart, selection: $naming.sequence, identifier: "export-naming-sequence")
            }
            HStack {
                LabeledContent(L10n.text("app.prefix", defaultValue: "Prefix")) { TextField(L10n.text("app.optional", defaultValue: "Optional"), text: $naming.prefix).accessibilityLabel(L10n.text("app.customPrefix", defaultValue: "Custom Prefix")).accessibilityIdentifier("export-prefix") }
                LabeledContent(L10n.text("app.suffix", defaultValue: "Suffix")) { TextField(L10n.text("app.optional", defaultValue: "Optional"), text: $naming.suffix).accessibilityLabel(L10n.text("app.customSuffix", defaultValue: "Custom Suffix")).accessibilityIdentifier("export-suffix") }
            }.textFieldStyle(.instrument)
            if naming.sequence {
                HStack {
                    InstrumentIntegerStepper(title: L10n.text("app.start", defaultValue: "Start"), value: $naming.start, range: 0...999_999_999,
                                             validationChanged: { startValid = $0; validationChanged($0 && digitsValid) }, fieldWidth: 90)
                    Spacer(minLength: 8)
                    InstrumentIntegerStepper(title: L10n.text("app.paddingDigits", defaultValue: "Padding Digits"), value: $naming.digits, range: 1...9,
                                             validationChanged: { digitsValid = $0; validationChanged($0 && startValid) })
                }.textFieldStyle(.instrument)
            }
            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("app.firstOutputFilename", defaultValue: "First Output Filename")).font(.caption11).foregroundStyle(Theme.textSecondary)
                    Text(preview).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Theme.inset)
                    .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("app.firstOutputFilename_1324", defaultValue: "First output filename \(preview)"))
            }
            DisclosureGroup(L10n.text("app.namingRules", defaultValue: "Naming Rules")) {
                Text(L10n.text("app.prefixDateOriginalSequenceSelectedComponentsOnlySuffixMissing", defaultValue: "Prefix + date_original_sequence (selected components only) + suffix. Missing capture dates use undated. Invalid characters / \\ : * ? \" < > | and control characters become _; leading / trailing spaces and dots are removed. Names may use up to 240 UTF-8 bytes including the extension. Conflicts prevent export."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }
    private func component(_ title: String, value: String, selection: Binding<Bool>, identifier: String) -> some View {
        Toggle(isOn: selection) {
            VStack(spacing: 5) {
                Text(value).font(.value).lineLimit(1).truncationMode(.middle).help(value)
                Text(title).font(.caption11)
            }.frame(maxWidth: .infinity)
        }.toggleStyle(.namingComponent).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
}

struct ExportOptionsForm: View {
    @Binding var options: ExportOptions
    var validationChanged: (Bool) -> Void = { _ in }
    @State private var lastLongEdge = 2048
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: Metrics.gap) {
                Text(L10n.text("app.fileFormat", defaultValue: "File Format")).frame(width: Metrics.rowLabel, height: Metrics.key, alignment: .leading)
                KeyRow(title: L10n.text("app.fileFormat", defaultValue: "File Format"), options: ExportFormat.allCases.map { KeyOption($0, $0.title) }, selection: $options.format, expand: true)
            }.accessibilityIdentifier("export-format")
            Text(options.format == .jpeg ? L10n.text("app.lossyCompressionSuitableForSharing", defaultValue: "Lossy compression, suitable for sharing.") : options.format == .png ? L10n.text("app.8BitLosslessImageSuitableForTheWebAnd", defaultValue: "8-bit lossless image, suitable for the web and general image exchange.") : L10n.text("app.16BitLosslessTIFFForArchivingAndFurtherEditing", defaultValue: "16-bit lossless TIFF for archiving and further editing; files are usually larger."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.text("app.limitLongEdge", defaultValue: "Limit Long Edge"), isOn: Binding(get: { options.longEdge != nil }, set: { options.longEdge = $0 ? lastLongEdge : nil }))
                .toggleStyle(.instrument).accessibilityIdentifier("export-limit-long-edge")
            if options.longEdge != nil {
                HStack {
                    InstrumentIntegerStepper(title: L10n.text("app.longEdge", defaultValue: "Long Edge"), value: Binding(get: { options.longEdge ?? lastLongEdge }, set: { options.longEdge = $0 }),
                                             range: 1...30000, validationChanged: validationChanged, fieldWidth: 65)
                        .textFieldStyle(.instrument)
                    Text("px")
                    Spacer()
                    Menu(L10n.text("app.commonSizes", defaultValue: "Common Sizes")) {
                        ForEach([2048, 3840, 6000], id: \.self) { edge in Button("\(edge) px") { options.longEdge = edge } }
                    }.menuStyle(.borderlessButton).tint(Theme.text).fixedSize().keySurface()
                }
                if !(1...30000).contains(options.longEdge ?? 0) { Text(L10n.text("app.theLongEdgeMustBe130000Px", defaultValue: "The long edge must be 1–30000 px.")).foregroundStyle(Theme.error).font(.caption11) }
            }
            Text(options.longEdge == nil ? L10n.text("app.preserveOriginalPixelDimensionsAfterCropping", defaultValue: "Preserve original pixel dimensions after cropping.") : L10n.text("app.onlyReducesPhotosExceedingTheLimitSmallerPhotosAre", defaultValue: "Only reduces photos exceeding the limit. Smaller photos are not enlarged."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            if options.format == .jpeg {
                AdjustmentRow(label: L10n.text("app.jpegQuality", defaultValue: "JPEG Quality"), value: options.quality * 100, range: 10...100, reset: ExportOptions().quality * 100,
                              change: { value, _ in options.quality = value / 100 }, commit: {})
                KeyRow(title: L10n.text("app.jpegTransparencyMatte", defaultValue: "JPEG Transparency Matte"), options: [KeyOption(JPEGMatte.black,L10n.text("app.blackMatte", defaultValue: "Black Matte")),KeyOption(JPEGMatte.white,L10n.text("app.whiteMatte", defaultValue: "White Matte"))],
                    selection:$options.jpegMatte,expand:true).accessibilityIdentifier("export-jpeg-matte")
                Text(options.jpegMatte == .unselected ? L10n.text("app.chooseAJPEGMatteColorTheViewingMatIs", defaultValue: "Choose a JPEG matte color. The viewing mat is not used for export.") : L10n.text("app.transparentAreasUseAMatteTheColorIsFrozen", defaultValue: "Transparent areas use a \(options.jpegMatte.title) matte. The color is frozen for this output; later changes do not affect queued tasks."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal:false,vertical:true)
            } else {
                Text(L10n.text("app.preserveSourceTransparencyAndEmptyAreasCreatedByGeometry", defaultValue: "Preserve source transparency and empty areas created by geometry. The viewing mat is for display only."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal:false,vertical:true)
            }
        }
        .onAppear { if let edge = options.longEdge { lastLongEdge = edge } }
        .onChange(of: options.longEdge) { if let edge = options.longEdge { lastLongEdge = edge } }
    }
}
