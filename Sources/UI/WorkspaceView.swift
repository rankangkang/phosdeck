import SwiftUI

private enum ViewMode: Hashable { case grid, single, compare, survey }

// Each region records its own Observation reads instead of invalidating the root.
private struct WorkspaceRegion<Content: View>: View {
    private let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View { content() }
}

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @AppStorage("showLeftPanel") private var left = true
    @AppStorage("showRightPanel") private var right = true
    @AppStorage("showFilmstrip") private var film = true
    @AppStorage("maskListExpanded") private var maskListExpanded = true
    @AppStorage("workspaceLeftWidth") private var leftWidth = Metrics.leftPanel.initial
    @AppStorage("workspaceRightWidth") private var rightWidth = Metrics.rightPanel.initial
    @AppStorage("workspaceFilmHeight") private var filmHeight = Metrics.filmstrip.initial
    @AppStorage("chromeTheme") private var chromeTheme = ChromeTheme.graphite
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    @AppStorage("developPreviewOpen") private var previewOpen = true
    @AppStorage("workspaceCollectionsOpen") private var collectionsOpen = true
    @AppStorage("workspaceHistoryOpen") private var historyOpen = true
    @AppStorage("workspaceSnapshotsOpen") private var snapshotsOpen = true
    @AppStorage("workspacePresetsOpen") private var presetsOpen = true
    @AppStorage("developScrollOffset") private var developScrollOffset = 0.0
    @AppStorage("cropScrollOffset") private var cropScrollOffset = 0.0
    @State private var fullScreen = false
    @State private var snapshotDialog = false
    @State private var snapshotName = ""
    @State private var snapshotRenameID: String?
    @State private var pasteDialog = false
    @State private var pasteOptions = RecipePasteOptions()
    @State private var adjustmentAction = AdjustmentAction.paste
    @State private var adjustmentSource: EditRecipe?
    @State private var adjustmentSourceName = ""
    @State private var adjustmentPresetID: String?
    @State private var adjustmentSourcePhoto: Photo?
    @State private var adjustmentTargets: [Photo] = []
    @State private var renamePresetID: String?
    @State private var renamePresetName = ""
    @State private var presetRenameDialog = false
    @State private var filterPopover = false
    @State private var keywordPopover = false
    @State private var matPopover = false
    @State private var newCollection = ""
    @State private var collectionDialog = false
    @State private var renameID: String?
    @State private var collectionFromResults = false
    @State private var smartDraft: PhotoCollection?
    @State private var versionRename = false
    @State private var versionName = ""
    @State private var versionID = ""
    @State private var reports = false
    @StateObject private var clippingPreview = ClippingPreviewSession()
    private var utilityOpen: Bool {
        smartDraft != nil || versionRename || collectionDialog || snapshotDialog || pasteDialog || presetRenameDialog || reports
    }
    var body: some View { presentations(workspace) }
    // Bound each expression for Xcode 26.6 without adding an Observation boundary.
    private var workspaceLayout: some View {
        GeometryReader { geometry in
        let showMasks = model.editMode && model.maskMode
        let maskDockWidth: CGFloat = showMasks ? (maskListExpanded ? 266 : 26) : 0
        let widths = WorkspaceDimensions.widths(available: geometry.size.width - maskDockWidth - 2 * (Metrics.rim + 1),
                                                left: leftWidth, right: rightWidth, showLeft: left, showRight: right)
        VStack(spacing: 0) {
            WorkspaceRegion { topBar }
            Seam()
            HStack(spacing: 0) {
                RimToggle(edge: .leading, isOpen: widths.left > 0, label: L10n.text("app.leftPanel", defaultValue: "Left Panel"), shortcut: "⌥⌘1",
                          blocked: left && widths.left == 0 ? L10n.text("app.theWindowIsTooNarrowTheLeftPanelWas", defaultValue: "The window is too narrow; the left panel was collapsed. Hide the right panel or widen the window to show it") : nil) { left.toggle() }
                Seam(axis: .vertical)
                panels(widths: widths, showMasks: showMasks, maskDockWidth: maskDockWidth,
                       compactMasks: showMasks && geometry.size.height < Metrics.compactMaskWindowHeight)
                Seam(axis: .vertical)
                RimToggle(edge: .trailing, isOpen: right, label: L10n.text("app.rightPanel", defaultValue: "Right Panel"), shortcut: "⌥⌘2") { right.toggle() }
            }
            if film {
                HStack(spacing: 0) {
                    Theme.base.frame(width: Metrics.rim)
                    Seam(axis: .vertical)
                    VStack(spacing: 0) {
                        Seam()
                        WorkspaceRegion { filmstripBar }
                        if !model.filtered.isEmpty {
                            WorkspaceResizeHandle(value: $filmHeight, range: Metrics.filmstrip.range, initial: Metrics.filmstrip.initial, horizontal: false, direction: -1, label: L10n.text("app.filmstripHeight", defaultValue: "Filmstrip Height"))
                            PhotoGrid(model: model, film: true, filmHeight: filmHeight, mat: mat, ordering: model.collectionOrdering).frame(height: filmHeight).disabled(model.applyingAdjustments)
                        }
                    }
                    Seam(axis: .vertical)
                    Theme.base.frame(width: Metrics.rim)
                }.fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 0) {
                Theme.base.frame(width: Metrics.rim)
                Seam()
                Theme.base.frame(width: Metrics.rim)
            }.fixedSize(horizontal: false, vertical: true)
            WorkspaceRegion { statusBar }
        }
        }
    }
    private var previewObservedWorkspace: some View {
        workspaceLayout
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("\(model.catalogName) — Phosdeck")
        .onChange(of: utilityOpen) {
            model.catalogUtilityOpen = utilityOpen
            if utilityOpen { model.endAdjustmentPreview(); clippingPreview.cancel() }
        }
        .onChange(of: model.activeID) { clippingPreview.cancel() }
        .onChange(of: model.developTool) { clippingPreview.cancel(); model.displayPixelReadout = nil }
        .onChange(of: model.showShadowClipping) { clippingPreview.cancel() }
        .onChange(of: model.showHighlightClipping) { clippingPreview.cancel() }
        .onChange(of: model.manualOrderEnabled) { model.filterCriteriaChanged() }
        .onChange(of: model.adjustmentRequest) {
            guard let action = model.adjustmentRequest else { return }
            model.adjustmentRequest = nil
            openAdjustments(action)
        }
    }
    private var observedWorkspace: some View {
        previewObservedWorkspace
        .onChange(of: model.search) { model.filterCriteriaChanged() }
        .onChange(of: model.ratingComparison) { model.filterCriteriaChanged() }
        .onChange(of: model.ratingThreshold) { model.filterCriteriaChanged() }
        .onChange(of: model.flagFilter) { model.filterCriteriaChanged() }
        .onChange(of: model.colorLabelFilter) { model.filterCriteriaChanged() }
        .onChange(of: model.keywordFilter) { model.filterCriteriaChanged() }
        .onChange(of: model.metadataFilter) { model.filterCriteriaChanged() }
        .onChange(of: model.photoSort) { model.filterCriteriaChanged() }
        .onChange(of: model.sortDescending) { model.filterCriteriaChanged() }
        .onChange(of: model.holdFilterResults) { model.filterCriteriaChanged() }
        .onChange(of: model.autoAdvance) { model.persistWorkspace() }
        .onChange(of: model.singleView) { model.persistWorkspace() }
        .onChange(of: model.editMode) { editModeChanged() }
    }
    private var workspace: some View {
        observedWorkspace
        .font(.body13).foregroundStyle(Theme.text).buttonStyle(.borderless).controlSize(.small)
        .tint(Theme.accentSignal)
        .background(InstrumentPlate()).preferredColorScheme(chromeTheme.colorScheme)
        .frame(minWidth: 1000, minHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in endTemporaryInspection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in endTemporaryInspection() }
        .onDisappear { endTemporaryInspection() }
    }
    private func endTemporaryInspection() {
        model.clearSavedEditPreview(); model.endMaskEffectPreview(); model.endAdjustmentPreview()
        model.displayPixelReadout = nil; clippingPreview.cancel()
    }
    private func editModeChanged() {
        if !model.editMode { model.clearSavedEditPreview() }
        if !model.editMode { model.maskMode = false }
        if !model.editMode && model.cropMode { model.cropMode = false; model.requestPreview() }
        model.persistWorkspace()
    }
    private func panels(widths: (left: CGFloat, right: CGFloat), showMasks: Bool, maskDockWidth: CGFloat, compactMasks: Bool) -> some View {
        HStack(spacing: 0) {
            if widths.left > 0 {
                Group {
                    if model.editMode {
                        GeometryReader { area in
                            ScrollView { WorkspaceRegion { sidebar }.frame(minHeight: area.size.height) }
                                .accessibilityIdentifier("develop-sidebar-scroll")
                        }
                    } else { WorkspaceRegion { sidebar } }
                }.frame(width: widths.left)
                WorkspaceResizeHandle(value: $leftWidth, range: Metrics.leftPanel.range, initial: Metrics.leftPanel.initial, label: L10n.text("app.leftPanelWidth", defaultValue: "Left Panel Width"))
            }
            // Bound the center before measuring its adaptive toolbar; otherwise
            // sidebar sizing repeatedly probes the entire toolbar and canvas.
            GeometryReader { center in
                VStack(spacing: 0) {
                    if !model.editMode && model.libraryFiltersOpen {
                        filterbar
                        Seam()
                    }
                    WorkspaceRegion { centerContent(showMasks: showMasks) }
                        .overlay(alignment: .bottom) {
                            if let notice = model.notice { WorkspaceNoticeBadge(text: notice.text).padding(.bottom, 18).id(notice.id) }
                        }
                    Seam()
                    WorkspaceRegion { centerToolbar }
                }.frame(width: center.size.width, height: center.size.height)
            }.frame(minWidth: showMasks ? 200 + maskDockWidth : 440)
            if widths.right > 0 {
                WorkspaceResizeHandle(value: $rightWidth, range: Metrics.rightPanel.range, initial: Metrics.rightPanel.initial, direction: -1, label: L10n.text("app.rightPanelWidth", defaultValue: "Right Panel Width"))
                WorkspaceRegion { inspector(compactMasks: compactMasks) }.frame(width: widths.right)
            }
        }
        .disabled(model.applyingAdjustments)
    }
    private func presentations(_ content: some View) -> some View {
        content
        .alert(L10n.text("app.actionIncomplete", defaultValue: "Action Incomplete"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.text("app.ok", defaultValue: "OK")) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented:$model.showPairing) { PairingSheet(model:model) }
        .sheet(isPresented:$model.showAutoStacks) { AutoStackSheet(model:model) }
        .sheet(item:$smartDraft) { SmartCollectionSheet(model:model,collection:$0) }
        .sheet(isPresented: $collectionDialog) {
            VStack(alignment: .leading, spacing: 16) {
                Text(renameID == nil ? L10n.text("app.newCollection", defaultValue: "New Collection") : L10n.text("app.renameCollection", defaultValue: "Rename Collection")).font(.headline)
                TextField(L10n.text("app.collectionName", defaultValue: "Collection Name"), text: $newCollection)
                if collectionFromResults { Text(L10n.text("app.addAllCurrentResultsPhotosAcrossEveryPageHold", defaultValue: "Add all current results: \(model.resultCount) photos across every page. Hold mode uses its fixed result membership.")).foregroundStyle(Theme.textSecondary) }
                HStack { Spacer(); Button(L10n.text("app.cancel", defaultValue: "Cancel")) { collectionDialog = false }.keyboardShortcut(.cancelAction); Button(L10n.text("app.save", defaultValue: "Save")) {
                    if collectionFromResults { model.collectResults(newName: newCollection) }
                    else { model.makeCollection(name: newCollection, id: renameID) }
                    collectionDialog = false
                }.keyboardShortcut(.defaultAction).disabled(newCollection.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 340).instrumentForm()
        }
        .alert(L10n.text("app.renameVirtualCopy", defaultValue: "Rename Virtual Copy"), isPresented: $versionRename) {
            TextField(L10n.text("app.copyName", defaultValue: "Copy Name"), text:$versionName)
            Button(L10n.text("app.cancel", defaultValue: "Cancel"),role:.cancel) {}
            Button(L10n.text("app.save", defaultValue: "Save")) { model.renameVirtualCopy(id:versionID,name:versionName) }
        }
        .sheet(isPresented: $snapshotDialog) {
            SnapshotNameSheet(name: $snapshotName, renameID: $snapshotRenameID, presented: $snapshotDialog) { name, id in
                model.saveSnapshot(name: name, replacingID: id)
            }
        }
        .sheet(isPresented: $pasteDialog) {
            if let source = adjustmentSource {
                PasteAdjustmentsSheet(model: model, source: source, sourceName: adjustmentSourceName, sourcePhoto: adjustmentSourcePhoto, targets: adjustmentTargets,
                    action: adjustmentAction, presetID: adjustmentPresetID, options: $pasteOptions, presented: $pasteDialog)
            }
        }
        .alert(L10n.text("app.renamePreset", defaultValue: "Rename Preset"), isPresented: $presetRenameDialog) {
            TextField(L10n.text("app.presetName", defaultValue: "Preset Name"), text: $renamePresetName)
            Button(L10n.text("app.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(L10n.text("app.save", defaultValue: "Save")) {
                if let id = renamePresetID { model.renamePreset(id: id, name: renamePresetName) }
            }
        }
        .sheet(isPresented: $model.showOutputRecovery) { ExportRecoverySheet(model: model) }
        .sheet(isPresented: $model.showCopyRecovery) { ImportRecoverySheet(model: model) }
        .sheet(isPresented: $model.showCameraDiagnostics) { CameraDiagnosticsView() }
        .sheet(isPresented: $model.showNewCatalog) { NewCatalogSheet(model: model) }
        .sheet(item: $model.importConflict) { conflict in
            ImportConflictSheet(model: model, conflict: conflict).id(conflict.id).interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.showImport) { ImportSheet(model: model) }
        .sheet(isPresented: $model.showXMPPresetImport) {
            if let catalog = model.catalog { XMPPresetImportSheet(model: model, catalog: catalog) }
        }
        .sheet(isPresented: $model.showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $reports) {
            VStack(alignment: .leading) {
                Text(L10n.text("app.taskResults", defaultValue: "Task Results")).font(.headline)
                ScrollView { Text(model.reports.isEmpty ? L10n.text("app.noPendingResults", defaultValue: "No pending results") : model.reports.joined(separator: "\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button(L10n.text("app.close", defaultValue: "Close")) { reports = false }.keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 620, height: 420).instrumentForm()
        }
    }
    private func saveCurrentSmartFilter() {
        model.perform {
            let rules = try SmartRules.from(model.query)
            smartDraft = PhotoCollection(id:UUID().uuidString,name:L10n.text("app.filteredResults", defaultValue: "Filtered Results"),rules:try JSONEncoder().encode(rules))
        }
    }
    private func openAdjustments(_ action: AdjustmentAction, preset: AdjustmentPreset? = nil) {
        guard !model.busy, model.commitRecipe() else { return }
        model.perform {
            let source: EditRecipe?
            if let preset {
                source = action == .update ? model.recipe : try JSONDecoder().decode(EditRecipe.self, from: preset.recipe)
                pasteOptions = try JSONDecoder().decode(RecipePasteOptions.self, from: preset.options)
                if action == .update { pasteOptions.importedXMP = nil }
                adjustmentSourceName = preset.name; adjustmentSourcePhoto = action == .update ? model.active : nil
            } else {
                source = action == .paste ? model.copiedRecipe : action == .previous ? model.previousAdjustmentSource?.recipe : model.recipe
                pasteOptions = action == .save ? RecipePasteOptions() : model.confirmedAdjustmentOptions
                adjustmentSourceName = action == .paste ? model.copiedPhotoName : action == .previous ? (model.previousAdjustmentSource?.photo.displayName ?? L10n.text("app.previousPhoto", defaultValue: "Previous Photo")) : (model.active?.displayName ?? L10n.text("app.currentPhoto", defaultValue: "Current Photo"))
                adjustmentSourcePhoto = action == .paste ? model.copiedAdjustmentPhoto : action == .previous ? model.previousAdjustmentSource?.photo : model.active
            }
            guard let source else { return }
            try source.validate()
            adjustmentPresetID = preset?.id
            adjustmentTargets = (action == .save || action == .update) ? [] : try model.catalog?.photos(ids: model.selection.union(Set([model.activeID].compactMap { $0 }))) ?? []
            adjustmentSource = source; adjustmentAction = action; pasteDialog = true
        }
    }
    private var adjustmentsMenu: some View {
        Menu(L10n.text("app.adjustments", defaultValue: "Adjustments")) {
            Button(L10n.text("app.locateCurrentOriginal", defaultValue: "Locate Current Original…"), action: model.locateOriginal).disabled(!model.canLocateOriginal)
            Divider()
            Menu(L10n.text("app.stacking", defaultValue: "Stacking")) { StackMenu(model:model) }
            Menu(L10n.text("app.rawJPEGPairing", defaultValue: "RAW/JPEG Pairing")) { PairMenu(model:model) }
            Divider()
            Button(L10n.text("app.createVirtualCopiesOfSelection", defaultValue: "Create Virtual Copies of Selection"),action:model.createVirtualCopies).disabled(model.selection.isEmpty)
            Button(L10n.text("app.renameCurrentCopy", defaultValue: "Rename Current Copy…")) {
                if let photo = model.active { versionID = photo.id; versionName = photo.versionName; versionRename = true }
            }.disabled(model.active?.isVirtualCopy != true)
            Button(L10n.text("app.removeSelectedVersionsKeepOriginals", defaultValue: "Remove Selected Versions (Keep Originals)"),action:model.deleteSelectedVersions).disabled(model.selection.isEmpty)
            Divider()
            Button(L10n.text("app.copyCurrentPhotoAdjustments", defaultValue: "Copy Current Photo Adjustments"), action: model.copyAdjustments).disabled(!model.canEdit)
            Button(L10n.text("app.pasteAdjustments_280", defaultValue: "Paste Adjustments…")) { model.requestAdjustments(.paste) }.disabled(model.copiedRecipe == nil || model.selection.isEmpty)
            Button(L10n.text("app.usePreviousAdjustments_282", defaultValue: "Use Previous Adjustments…")) { model.requestAdjustments(.previous) }.disabled(!model.canUsePreviousAdjustments)
            Button(L10n.text("app.syncCurrentPhotoToSelection", defaultValue: "Sync Current Photo to Selection…")) { model.requestAdjustments(.sync) }
                .disabled(!model.canEdit || model.selection.subtracting(Set([model.activeID].compactMap { $0 })).isEmpty)
            Divider()
            Button(L10n.text("app.saveCurrentAdjustmentsAsPreset", defaultValue: "Save Current Adjustments as Preset…")) { openAdjustments(.save) }.disabled(!model.canEdit)
            Menu(L10n.text("app.applyPreset", defaultValue: "Apply Preset")) {
                ForEach(model.adjustmentPresets) { preset in Button(preset.name) { openAdjustments(.preset, preset: preset) } }
            }.disabled(model.adjustmentPresets.isEmpty || model.selection.isEmpty)
        }.disabled(model.busy)
    }

    // MARK: Top bar

    private var module: Binding<WorkspaceModule> {
        Binding(get: { model.workspaceModule }, set: model.selectModule)
    }
    private var viewMode: Binding<ViewMode> {
        let current: ViewMode = model.survey != nil ? .survey : model.comparison != nil ? .compare : model.singleView || model.editMode ? .single : .grid
        return Binding(get: { current }, set: { mode in
            guard mode != current else { return }
            switch mode {
            case .grid: model.selectWorkspace(.grid)
            case .single: model.selectWorkspace(.single)
            case .compare: model.selectWorkspace(.compare)
            case .survey: model.selectWorkspace(.survey)
            }
        })
    }
    private var topBar: some View {
        HStack(alignment: .keyCenter, spacing: 12) {
            if !fullScreen { Color.clear.frame(width: 64, height: 1).accessibilityHidden(true) }
            Wordmark()
            Text(model.catalogName).font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                .help(model.catalog?.fileURL.path ?? L10n.text("app.noCatalogOpenFileNewCatalogOpenCatalog", defaultValue: "No catalog open (File › New Catalog / Open Catalog)"))
            Spacer(minLength: 8)
            KeyRow(title: L10n.text("app.module", defaultValue: "Module"), options: [KeyOption(.library, L10n.text("app.library", defaultValue: "Library"), help: L10n.text("app.returnToLibraryAndRestoreItsViewGGrid", defaultValue: "Return to Library and restore its view; G: Grid / E: Loupe")), KeyOption(.develop, L10n.text("app.develop", defaultValue: "Develop"), help: L10n.text("app.developD", defaultValue: "Develop (D)"))],
                   selection: module, lampsInside: true, height: Self.topKey, padding: 8)
                .disabled(!model.workspaceAvailable)
            Button(L10n.text("app.export_1997", defaultValue: "Export")) { model.requestExport() }
                .buttonStyle(PrimaryKeyStyle(height: Self.topKey))
                .disabled(!model.canExportPhotos)
                .help(L10n.text("app.exportSelectedPhotosE", defaultValue: "Export selected photos (⇧⌘E)"))
        }
        .padding(.top, Metrics.topBarKeyLine - Self.topKey / 2)
        .padding(.horizontal, 12).frame(height: Metrics.topBar, alignment: .top)
        .background { InstrumentPlate().gesture(WindowDragGesture()) }
        .background(FullScreenReader(fullScreen: $fullScreen))
    }
    private static let topKey: CGFloat = 24

    // MARK: Left panel

    private var sourceName: String {
        if let title = model.relatedBrowseTitle, model.isViewingRelated { return L10n.text("app.temporary", defaultValue: "Temporary · ") + title }
        if model.scope == "all" { return L10n.text("app.allPhotos", defaultValue: "All Photos") }
        if model.isViewingImport { return L10n.text("app.thisImport", defaultValue: "This Import") }
        if let collection = model.collections.first(where: { "collection:" + $0.id == model.scope }) { return collection.name }
        if let root = model.roots.first(where: { $0.id == model.scope }) { return root.label }
        return L10n.text("app.currentFolder", defaultValue: "Current Folder")
    }
    private var hasFilter: Bool { model.hasLibraryFilters }
    private var filterSummary: String {
        var parts: [String] = []
        if model.isFilterSectionActive(.text), !model.search.isEmpty { parts.append(L10n.text("app.filename_2002", defaultValue: "Filename: ") + model.search) }
        if model.isFilterSectionActive(.attribute), model.ratingComparison.isActive(threshold: model.ratingThreshold) {
            parts.append(model.ratingThreshold == 0 ? L10n.text("app.unrated_2003", defaultValue: "\(model.ratingComparison.symbol) Unrated") : "\(model.ratingComparison.symbol) \(model.ratingThreshold) ★")
        }
        if model.isFilterSectionActive(.attribute), !model.flagFilter.isEmpty { parts.append(PhotoFlag.allCases.filter { model.flagFilter.contains($0.rawValue) }.map(\.title).joined(separator: "＋")) }
        if model.isFilterSectionActive(.attribute), !model.colorLabelFilter.isEmpty { parts.append(PhotoColorLabel.allCases.filter { model.colorLabelFilter.contains($0.rawValue) }.map(\.title).joined(separator: "＋")) }
        if model.isFilterSectionActive(.metadata), !model.keywordFilter.isEmpty { parts.append(model.keywords.first { $0.keyword == model.keywordFilter }?.name ?? model.keywordFilter) }
        if model.isFilterSectionActive(.metadata), model.metadataFilter.isActive { parts.append(L10n.text("app.metadata", defaultValue: "Metadata")) }
        return (model.filtersEnabled ? "" : L10n.text("app.paused", defaultValue: "Paused: ")) + parts.joined(separator: " · ")
    }
    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(help).accessibilityLabel(help)
    }
    private func emptyNote(_ text: String) -> some View {
        Text(text).font(.caption11).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.editMode {
                WorkspaceRegion {
                    PanelSection(L10n.text("app.navigator", defaultValue: "Navigator"), isExpanded: $previewOpen, accessory: {
                        Text(model.fillView ? L10n.text("app.fill", defaultValue: "Fill") : model.fullResolution ? model.zoomLabel : L10n.text("app.fit_1691", defaultValue: "Fit"))
                            .font(.caption11).foregroundStyle(Theme.textSecondary)
                    }) {
                        ZStack {
                            mat.color
                            if let preview = model.savedEditPreview {
                                SavedEditNavigatorView(preview: preview, title: model.savedEditPreviewTitle)
                            } else if let image = model.image ?? model.photoSwitchDisplay?.image {
                                PhotoNavigator(viewport: model.viewport, image: image, zoomed: (model.fullResolution || model.fillView) && !model.cropMode,
                                               canNavigate: !model.cropMode && model.photoSwitchDisplay == nil, zoomLabel: model.fillView ? L10n.text("app.fill", defaultValue: "Fill") : model.zoomLabel).padding(8)
                            } else {
                                Text(L10n.text("app.selectAPhotoToPreview", defaultValue: "Select a photo to preview")).font(.caption11).foregroundStyle(Color(nsColor: mat.textSecondary))
                            }
                        }.frame(height: 154)
                    }
                }
                PanelSection(L10n.text("app.presets", defaultValue: "Presets"), isExpanded: $presetsOpen, accessory: {
                    headerButton("square.and.arrow.down", help: L10n.text("app.importLightroomXMPPresets", defaultValue: "Import Lightroom XMP Presets…")) { model.requestXMPPresetImport() }.disabled(!model.workspaceAvailable || model.catalog == nil)
                    headerButton("plus", help: L10n.text("app.saveCurrentAdjustmentsAsPreset", defaultValue: "Save Current Adjustments as Preset…")) { openAdjustments(.save) }.editingDisabled(!model.canEdit || model.busy, temporarilyLocked: model.editorUsesPreviousPhoto && !model.busy)
                }) {
                    VStack(alignment: .leading, spacing: 0) {
                        PresetBrowser(presets: model.adjustmentPresets,
                            onPreview: { model.previewPreset($0) },
                            onEndPreview: { model.endPresetPreview($0) },
                            onApply: { preset in model.endPresetPreview(); openAdjustments(.preset, preset: preset) },
                            onRename: { preset in
                                model.endPresetPreview(); renamePresetID = preset.id
                                renamePresetName = preset.name; presetRenameDialog = true
                            },
                            onDelete: { model.deletePreset($0) },
                            onKeyboardFocusChanged: { model.presetListFocused = $0 },
                            onUpdate: { preset in model.endPresetPreview(); openAdjustments(.update, preset: preset) },
                            onFavorite: { model.setPresetFavorite($0, favorite: $1) },
                            onGroup: { model.setPresetGroup($0, group: $1) })
                            .editingDisabled(!model.canEdit || !model.workspaceAvailable || model.developTool != .adjust, temporarilyLocked: model.editorUsesPreviousPhoto && model.workspaceAvailable && model.developTool == .adjust)
                            .frame(height: model.adjustmentPresets.isEmpty ? nil : 220, alignment: .top)
                    }.padding(.bottom, 6)
                }
                PanelSection(L10n.text("app.snapshots", defaultValue: "Snapshots"), isExpanded: $snapshotsOpen, accessory: {
                    if !model.editSnapshots.isEmpty { Text("\(model.editSnapshots.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary) }
                    headerButton("plus", help: L10n.text("app.newSnapshot", defaultValue: "New Snapshot")) { snapshotRenameID = nil; snapshotName = L10n.text("app.snapshot", defaultValue: "Snapshot \(model.editSnapshots.count + 1)"); snapshotDialog = true }
                        .editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto)
                }) {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.editSnapshots.isEmpty {
                            emptyNote(L10n.text("app.useToSaveCurrentAdjustments", defaultValue: "Use + to save current adjustments"))
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(model.editSnapshots) { entry in
                                        HStack(spacing: 0) {
                                            Button {
                                                model.applySavedEdit(data: entry.recipe, photoID: entry.photoID, title: L10n.text("app.restoreSnapshot", defaultValue: "Restore snapshot: ") + entry.title)
                                            } label: { ListRowLabel(title: entry.title) }
                                                .buttonStyle(.plain)
                                                .editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto)
                                                .help(entry.title + " · " + Date(timeIntervalSince1970: entry.createdAt).formatted())
                                                .onHover { hovering in
                                                    if hovering { model.previewSavedEdit(data: entry.recipe, photoID: entry.photoID, key: "snapshot:" + entry.id, title: entry.title) }
                                                    else { model.clearSavedEditPreview(key: "snapshot:" + entry.id) }
                                                }
                                                .onDisappear { model.clearSavedEditPreview(key: "snapshot:" + entry.id) }
                                                .contextMenu {
                                                    Button(L10n.text("app.previewInNavigator", defaultValue: "Preview in Navigator")) { model.previewSavedEdit(data: entry.recipe, photoID: entry.photoID, key: "snapshot:" + entry.id, title: entry.title) }
                                                    Button(L10n.text("app.useAsComparisonBaseline", defaultValue: "Use as Comparison Baseline")) { model.setBeforeReference(data: entry.recipe, photoID: entry.photoID, title: entry.title) }.disabled(!model.canShowBeforeAfter)
                                                    Button(L10n.text("app.createVirtualCopyFromThisState", defaultValue: "Create Virtual Copy from This State")) { model.createVirtualCopy(data: entry.recipe, photoID: entry.photoID, title: entry.title) }
                                                    Divider()
                                                    Button(L10n.text("app.rename", defaultValue: "Rename…")) { snapshotRenameID = entry.id; snapshotName = entry.title; snapshotDialog = true }
                                                    Divider()
                                                    Button(L10n.text("app.deleteSnapshot", defaultValue: "Delete Snapshot"), role: .destructive) { model.deleteSnapshot(entry) }
                                                }
                                            headerButton("trash", help: L10n.text("app.deleteSnapshotUndoAvailable", defaultValue: "Delete snapshot “\(entry.title)”; undo available")) { model.deleteSnapshot(entry) }
                                                .editingDisabled(!model.canEdit || !model.workspaceAvailable, temporarilyLocked: model.editorUsesPreviousPhoto && model.workspaceAvailable)
                                                .accessibilityIdentifier("snapshot-delete-" + entry.id)
                                                .padding(.trailing, 8)
                                        }
                                    }
                                }
                            }.frame(height: min(96, CGFloat(model.editSnapshots.count) * 24))
                        }
                    }.padding(.bottom, 6)
                }
                PanelSection(L10n.text("app.history", defaultValue: "History"), isExpanded: $historyOpen) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if model.editHistory.isEmpty {
                                emptyNote(L10n.text("app.historyAppearsAfterSavingAdjustments", defaultValue: "History appears after saving adjustments"))
                            }
                            ForEach(model.editHistory) { entry in
                                let date = Date(timeIntervalSince1970: entry.createdAt)
                                Button { model.applySavedEdit(data: entry.recipe, photoID: entry.photoID, title: L10n.text("app.restoreHistory", defaultValue: "Restore history: ") + entry.title) } label: {
                                    ListRowLabel(title: entry.title, detail: date.formatted(date: .omitted, time: .shortened),
                                                 selected: entry.id == model.editHistory.first?.id && !model.dirty)
                                }.buttonStyle(.plain).editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto).help(entry.title + " · " + date.formatted() + L10n.text("app.hoverToPreviewClickToRestoreOrRightClick", defaultValue: "; hover to preview, click to restore, or right-click to compare or create a copy"))
                                    .onHover { hovering in
                                        if hovering { model.previewSavedEdit(data: entry.recipe, photoID: entry.photoID, key: "history:\(entry.id)", title: entry.title) }
                                        else { model.clearSavedEditPreview(key: "history:\(entry.id)") }
                                    }
                                    .onDisappear { model.clearSavedEditPreview(key: "history:\(entry.id)") }
                                    .contextMenu {
                                        Button(L10n.text("app.previewInNavigator", defaultValue: "Preview in Navigator")) { model.previewSavedEdit(data: entry.recipe, photoID: entry.photoID, key: "history:\(entry.id)", title: entry.title) }
                                        Button(L10n.text("app.useAsComparisonBaseline", defaultValue: "Use as Comparison Baseline")) { model.setBeforeReference(data: entry.recipe, photoID: entry.photoID, title: entry.title) }.disabled(!model.canShowBeforeAfter)
                                        Button(L10n.text("app.createVirtualCopyFromThisState", defaultValue: "Create Virtual Copy from This State")) { model.createVirtualCopy(data: entry.recipe, photoID: entry.photoID, title: entry.title) }
                                    }
                            }
                            if model.hasMoreHistory {
                                Button(L10n.text("app.loadEarlierHistory", defaultValue: "Load Earlier History"), action: model.loadMoreHistory).buttonStyle(.key(height: 22)).padding(8)
                            }
                        }
                    }.frame(height: min(150, CGFloat(max(1, model.editHistory.count)) * 24 + (model.hasMoreHistory ? 38 : 0)))
                        .padding(.bottom, 6)
                }
            } else {
                PanelTitle(L10n.text("app.catalog", defaultValue: "Catalog"))
                Button { model.setScope("all") } label: {
                    ListRowLabel(title: L10n.text("app.allPhotos", defaultValue: "All Photos"), detail: "\(model.totalCount)", icon: "photo.on.rectangle", selected: model.scope == "all")
                }.buttonStyle(.plain).padding(.bottom, 6)
                if let batch = model.lastImport, !batch.photoIDs.isEmpty {
                    Button { model.showLastImport() } label: {
                        ListRowLabel(title: L10n.text("app.lastImport", defaultValue: "Last Import"), detail: "\(batch.photoIDs.count)", icon: "tray.and.arrow.down", selected: model.isViewingImport)
                    }.buttonStyle(.plain).padding(.bottom, 6)
                        .disabled(!model.workspaceAvailable)
                        .help(L10n.text("app.photosActuallyAddedInTheLastBatchRetainedAcross", defaultValue: "Photos actually added in the last batch, retained across restarts. Duplicates and failures are excluded"))
                }
                Seam()
                PanelTitle(L10n.text("app.folders", defaultValue: "Folders"))
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.roots) { root in
                            Button { model.setScope(root.id) } label: { ListRowLabel(title: root.label, icon: "folder", selected: model.scope == root.id) }
                                .buttonStyle(.plain)
                                .contextMenu { Button(L10n.text("app.rescan", defaultValue: "Rescan")) { model.scan(root) }; Button(L10n.text("app.reauthorizeLocate", defaultValue: "Reauthorize / Locate…")) { model.relocate(root) } }
                            OutlineGroup(model.folders[root.id] ?? [], children: \.children) { node in
                                Button { model.setScope(node.id) } label: { ListRowLabel(title: node.name, icon: "folder", selected: model.scope == node.id) }
                                    .buttonStyle(.plain)
                            }.padding(.leading, 12)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
                }.frame(maxHeight: 200)
                Seam()
            }
            PanelSection(L10n.text("app.collections", defaultValue: "Collections"), isExpanded: $collectionsOpen, accessory: {
                Menu {
                    Button(L10n.text("app.newRegularCollection", defaultValue: "New Regular Collection…")) { collectionFromResults = false; renameID = nil; newCollection = ""; collectionDialog = true }
                    Button(L10n.text("app.newSmartCollection", defaultValue: "New Smart Collection…")) { smartDraft = PhotoCollection(id:UUID().uuidString,name:L10n.text("app.newSmartCollection_2031", defaultValue: "New Smart Collection"),rules:try? JSONEncoder().encode(SmartRules())) }
                    Button(L10n.text("app.saveCurrentFiltersAsSmartCollection", defaultValue: "Save Current Filters as Smart Collection…")) { saveCurrentSmartFilter() }
                        .disabled(model.isViewingImport)
                } label:{ Image(systemName:"plus").font(.system(size: 10, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Theme.textSecondary).fixedSize()
                    .help(L10n.text("app.newCollection", defaultValue: "New Collection")).accessibilityLabel(L10n.text("app.newCollection", defaultValue: "New Collection"))
            }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.collections.isEmpty {
                            emptyNote(L10n.text("app.useToCreateACollection", defaultValue: "Use + to create a collection"))
                        }
                        ForEach(model.collections) { collection in
                            Button { model.setScope("collection:" + collection.id) } label: {
                                ListRowLabel(title: collection.name + (model.targetCollectionID == collection.id ? " +" : ""), detail:model.collectionCounts[collection.id].map { $0 < 0 ? L10n.text("app.invalidRules", defaultValue: "Invalid rules") : String($0) }, icon: collection.isSmart ? "line.3.horizontal.decrease.circle" : "rectangle.stack", selected: model.scope == "collection:" + collection.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if collection.isSmart {
                                    Button(L10n.text("app.editRulesRename", defaultValue: "Edit Rules / Rename…")) { smartDraft = collection }
                                    Button(L10n.text("app.deleteSmartCollectionKeepPhotos", defaultValue: "Delete Smart Collection (Keep Photos)")) { model.deleteSmartCollection(collection.id) }
                                } else {
                                    Button(model.targetCollectionID == collection.id ? L10n.text("app.currentQuickCollectionTargetB", defaultValue: "Current Quick Collection Target (B)") : L10n.text("app.setAsQuickCollectionTargetB", defaultValue: "Set as Quick Collection Target (B)")) { model.setTargetCollection(collection.id) }
                                        .disabled(model.targetCollectionID == collection.id)
                                    Divider()
                                    Button(L10n.text("app.addSelectedPhotos", defaultValue: "Add Selected Photos")) { model.membership(collection.id, add: true) }
                                    Button(L10n.text("app.removeSelectedPhotos", defaultValue: "Remove Selected Photos")) { model.membership(collection.id, add: false) }
                                    Button(L10n.text("app.rename_1545", defaultValue: "Rename")) { collectionFromResults = false; renameID = collection.id; newCollection = collection.name; collectionDialog = true }
                                    Button(L10n.text("app.deleteCollectionKeepPhotos", defaultValue: "Delete Collection (Keep Photos)")) { model.deleteCollection(collection.id) }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
                }
                .frame(height: model.editMode ? min(200, CGFloat(max(1, model.collections.count)) * 24 + 6) : nil)
            }
            Spacer(minLength: 0)
            Seam()
            HStack(spacing: Metrics.gap) {
                if model.editMode {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Metrics.gap) { copyAdjustmentsKey; pasteAdjustmentsKey }
                        VStack(spacing: Metrics.gap) { copyAdjustmentsKey; pasteAdjustmentsKey }
                    }
                } else {
                    Button { model.importReference() } label: { Text(L10n.text("app.import_2042", defaultValue: "Import…")).frame(maxWidth: .infinity) }.buttonStyle(.key)
                        .disabled(model.busy || model.catalog == nil).help(L10n.text("app.importPhotosI", defaultValue: "Import photos (⇧⌘I)"))
                }
            }.editingDisabled(model.editMode && !model.canEdit, temporarilyLocked: model.editMode && model.editorUsesPreviousPhoto).padding(12)
        }.background(InstrumentPlate())
    }
    private var copyAdjustmentsKey: some View {
        Button { model.copyAdjustments() } label: {
            Text(L10n.text("app.copyAdjustments", defaultValue: "Copy Adjustments")).fixedSize().frame(maxWidth: .infinity)
        }.buttonStyle(.key)
    }
    private var pasteAdjustmentsKey: some View {
        Button { model.requestAdjustments(.paste) } label: {
            Text(L10n.text("app.pasteAdjustments_280", defaultValue: "Paste Adjustments…")).fixedSize().frame(maxWidth: .infinity)
        }.buttonStyle(.key).controlUnavailable(model.copiedRecipe == nil)
    }

    // MARK: Center

    @ViewBuilder private func centerContent(showMasks: Bool) -> some View {
        if let survey = model.survey {
            PhotoSurveyView(model: model, survey: survey)
        } else if let comparison = model.comparison {
            PhotoComparisonView(model: model, comparison: comparison)
        } else if model.filtered.isEmpty && model.developReference == nil {
            emptyLibraryState
        } else if model.singleView || model.editMode {
            HStack(spacing: 0) {
                if let reference = model.developReference, model.editMode {
                    DevelopReferenceView(model: model, reference: reference)
                } else {
                    VStack(spacing: 0) {
                        if model.editMode, model.developTool == .adjust {
                            WorkspaceRegion { PhotoViewingInfo(photo: model.active, mat: mat) }
                        }
                        PhotoCanvas(model: model, clippingPreview: clippingPreview.preview)
                        if model.editMode, model.developTool == .adjust {
                            WorkspaceRegion { PhotoViewingInfo(photo: model.active, mat: mat, capture: true) }
                        }
                    }.background(mat.color)
                }
                if showMasks {
                    Seam(axis: .vertical)
                    VStack(spacing: 0) {
                        Button { maskListExpanded.toggle() } label: {
                            Image(systemName: maskListExpanded ? "chevron.right" : "chevron.left")
                                .frame(width: 26, height: 36).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .help(maskListExpanded ? L10n.text("app.collapseMaskPanelToTheRight", defaultValue: "Collapse Mask Panel to the Right") : L10n.text("app.expandMaskPanelToTheLeft", defaultValue: "Expand Mask Panel to the Left"))
                        .accessibilityLabel(maskListExpanded ? L10n.text("app.collapseMaskPanel", defaultValue: "Collapse Mask Panel") : L10n.text("app.expandMaskPanel", defaultValue: "Expand Mask Panel"))
                        .accessibilityIdentifier("mask-panel-toggle")
                        if !maskListExpanded {
                            Text(L10n.text("app.masks_2048", defaultValue: "Masks")).font(.silk).foregroundStyle(Theme.textSecondary).lineSpacing(4).padding(.top, 8)
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: 0)
                    }.frame(width: 25).background(InstrumentPlate())
                    if maskListExpanded {
                        Seam(axis: .vertical)
                        MaskListPanel(model: model).frame(width: 238).editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto)
                    }
                }
            }
        } else { PhotoGrid(model: model, mat: mat, ordering: model.collectionOrdering) }
    }
    private var emptyLibraryState: some View {
        VStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(Color(nsColor: mat.textSecondary))
                Text(model.catalog == nil ? L10n.text("app.createOrOpenACatalog", defaultValue: "Create or Open a Catalog") : model.totalCount == 0 ? L10n.text("app.importPhotos_1818", defaultValue: "Import Photos") : hasFilter ? L10n.text("app.noPhotosMatchTheConditions", defaultValue: "No photos match the conditions") : L10n.text("app.noPhotosInThisSource", defaultValue: "No photos in this source")).font(.title3)
                    .foregroundStyle(Color(nsColor: mat.text))
                Text(hasFilter ? filterSummary : L10n.text("app.originalsStayInTheSelectedFolderRatingsAndAdjustments", defaultValue: "Originals stay in the selected folder. Ratings and adjustments are saved in the local catalog."))
                    .font(.system(size: 12)).foregroundStyle(Color(nsColor: mat.textSecondary))
                    .multilineTextAlignment(.center).lineLimit(3)
                if model.catalog == nil {
                    HStack { Button(L10n.text("app.newCatalog", defaultValue: "New Catalog…"), action: model.createCatalog).buttonStyle(.key); Button(L10n.text("app.openCatalog", defaultValue: "Open Catalog…"), action: model.openCatalog).buttonStyle(.key) }
                    ForEach(model.recentCatalogs.prefix(3)) { recent in
                        Button(recent.filename) { model.openRecent(recent) }.buttonStyle(.key).help(recent.path)
                    }
                } else if model.totalCount == 0 { Button(L10n.text("app.importPhotos", defaultValue: "Import Photos…"), action: model.importReference).buttonStyle(.key) }
                else {
                    HStack(spacing: Metrics.gap) {
                        if hasFilter { Button(L10n.text("app.clearFilters", defaultValue: "Clear Filters"), action: model.clearFilters).buttonStyle(.key).accessibilityIdentifier("empty-clear-filters") }
                        if model.scope != "all" { Button(L10n.text("app.viewAllPhotos", defaultValue: "View All Photos")) { model.clearFilters(); model.setScope("all") }.buttonStyle(.key) }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(mat.color)
    }

    private var filterbar: some View {
        VStack(spacing: 0) {
            filterModeBar
            if model.isFilterSectionActive(.text) {
                HStack(spacing: 8) {
                    SilkText(L10n.text("app.filename", defaultValue: "Filename")).foregroundStyle(Theme.textSecondary)
                    TextField(L10n.text("app.searchFilenames", defaultValue: "Search Filenames"), text: $model.search).textFieldStyle(.instrument)
                        .accessibilityIdentifier("library-text-filter")
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help(L10n.text("app.clearTextConditions", defaultValue: "Clear Text Conditions")).accessibilityLabel(L10n.text("app.clearTextConditions", defaultValue: "Clear Text Conditions"))
                    }
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            if model.isFilterSectionActive(.attribute) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        attributeMarks
                        Seam(axis: .vertical).frame(height: 18)
                        ColorLabelKeys(selected: model.colorLabelFilter, prefix: "color-filter", action: model.toggleColorLabelFilter)
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        attributeMarks
                        HStack(spacing: 10) {
                            SilkText(L10n.text("app.color_2056", defaultValue: "Color")).foregroundStyle(Theme.textSecondary)
                            ColorLabelKeys(selected: model.colorLabelFilter, prefix: "color-filter", action: model.toggleColorLabelFilter)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
            if model.isFilterSectionActive(.metadata) {
                metadataFields.padding(.horizontal, 12).padding(.vertical, 8)
            }
        }.background(InstrumentPlate()).tint(Theme.text)
    }
    private var attributeMarks: some View {
        HStack(spacing: 10) {
            SilkText(L10n.text("app.flags", defaultValue: "Flags")).foregroundStyle(Theme.textSecondary)
            flagFilterKeys
            Seam(axis: .vertical).frame(height: 18).padding(.horizontal, 2)
            SilkText(L10n.text("app.rating", defaultValue: "Rating")).foregroundStyle(Theme.textSecondary)
            ratingFilterControls
        }.fixedSize()
    }
    private var ratingFilterControls: some View {
        HStack(spacing: -1) {
            Menu {
                Picker(L10n.text("app.ratingComparison", defaultValue: "Rating Comparison"), selection: $model.ratingComparison) {
                    ForEach(RatingComparison.allCases) { comparison in
                        Text(comparison.title).tag(comparison)
                    }
                }.pickerStyle(.inline)
            } label: { Text(model.ratingComparison.symbol).monospaced() }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .keySurface(position: .leading, height: 22)
                .accessibilityLabel(L10n.text("app.ratingComparison", defaultValue: "Rating Comparison"))
                .accessibilityValue(model.ratingComparison.title)
                .accessibilityIdentifier("library-rating-comparison")
                .help(L10n.text("app.chooseRatingComparison", defaultValue: "Choose Rating Comparison"))
            ForEach(1...5, id: \.self) { rating in
                Button { model.toggleRatingFilter(rating) } label: {
                    Image(systemName: rating <= model.ratingThreshold ? "star.fill" : "star")
                }
                .buttonStyle(.key(selected: rating == model.ratingThreshold, position: rating == 5 ? .trailing : .middle, height: 22, padding: 5))
                .accessibilityLabel(L10n.text("app.filterRatingStars", defaultValue: "Filter rating: \(rating) stars"))
                .accessibilityValue(rating == model.ratingThreshold ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected"))
                .accessibilityIdentifier("library-rating-filter-\(rating)")
                .help(L10n.text("app.compareAgainstStarsClickTheCurrentRatingAgainTo", defaultValue: "Compare against \(rating) stars; click the current rating again to return to Unrated"))
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.text("app.ratingFilter", defaultValue: "Rating Filter"))
            .accessibilityValue(model.ratingComparison.title + (model.ratingThreshold == 0 ? L10n.text("app.unrated", defaultValue: "Unrated") : L10n.text("app.stars_1722", defaultValue: "\(model.ratingThreshold) Stars")))
    }
    private var filterModeBar: some View {
        HStack(spacing: 8) {
            SilkText(L10n.text("app.libraryFilters", defaultValue: "Library Filters")).foregroundStyle(Theme.textSecondary).fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: -1) {
                ForEach(Array(LibraryFilterSection.allCases.enumerated()), id: \.element.id) { index, section in
                    let selected = model.isFilterSectionActive(section)
                    Button { model.selectFilterSection(section, additive: NSEvent.modifierFlags.contains(.shift)) } label: {
                        LampLabel(on: selected) { Text(section.title) }
                    }.buttonStyle(.key(selected: selected, position: index == 0 ? .leading : .middle, height: 22, padding: 6))
                        .accessibilityLabel(L10n.text("app.filterGroup", defaultValue: "Filter Group: ") + section.title).accessibilityValue(selected ? L10n.text("app.expanded", defaultValue: "Expanded") : L10n.text("app.collapsed", defaultValue: "Collapsed"))
                        .accessibilityIdentifier("filter-section-" + section.rawValue)
                        .help(L10n.text("app.showOrDisableFiltersShiftClickToCombineGroups", defaultValue: "Show or disable \(section.title) filters; Shift-click to combine groups"))
                }
                let none = !model.filtersEnabled || model.filterSections.isEmpty
                Button { model.disableLibraryFilters() } label: { LampLabel(on: none) { Text(L10n.text("app.none", defaultValue: "None")) } }
                    .buttonStyle(.key(selected: none, position: .trailing, height: 22, padding: 6))
                    .accessibilityLabel(L10n.text("app.filterGroupNone", defaultValue: "Filter Group: None")).accessibilityIdentifier("filter-section-none")
                    .help(L10n.text("app.disableAllFilterGroupsPreservingConditionsForReuse", defaultValue: "Disable all filter groups, preserving conditions for reuse"))
            }.fixedSize()
            Spacer(minLength: 0)
            Menu {
                Button(model.filtersEnabled ? L10n.text("app.disableFilters", defaultValue: "Disable Filters") : L10n.text("app.restoreFilters", defaultValue: "Restore Filters")) { model.toggleFilters() }
                Button(L10n.text("app.clearAllFilters", defaultValue: "Clear All Filters"), action: model.clearFilters)
            } label: { Text(!model.filtersEnabled ? L10n.text("app.off_1408", defaultValue: "Off") : hasFilter ? L10n.text("app.customFilters", defaultValue: "Custom Filters") : L10n.text("app.noFilters", defaultValue: "No Filters")) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L10n.text("app.filterStatus", defaultValue: "Filter Status")).help(hasFilter ? filterSummary : L10n.text("app.photosAreCurrentlyUnrestricted", defaultValue: "Photos are currently unrestricted"))
        }.font(.caption11).padding(.horizontal, 12).frame(height: 32)
            .disabled(!model.workspaceAvailable)
    }
    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SilkText(L10n.text("app.keywords", defaultValue: "Keywords")).foregroundStyle(Theme.textSecondary)
                keywordFilter
                Spacer(minLength: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.text("app.camera", defaultValue: "Camera"))
                    TextField(L10n.text("app.nameContains", defaultValue: "Name Contains"), text: $model.metadataFilter.camera).accessibilityLabel(L10n.text("app.cameraNameContains", defaultValue: "Camera Name Contains"))
                    Text(L10n.text("app.lens", defaultValue: "Lens"))
                    TextField(L10n.text("app.nameContains", defaultValue: "Name Contains"), text: $model.metadataFilter.lens).accessibilityLabel(L10n.text("app.lensNameContains", defaultValue: "Lens Name Contains"))
                }
                GridRow {
                    Text("ISO")
                    TextField(L10n.text("app.minimum", defaultValue: "Minimum"), text: $model.metadataFilter.minimumISO).accessibilityLabel(L10n.text("app.isoMinimum", defaultValue: "ISO Minimum"))
                    Text(L10n.text("app.to", defaultValue: "to"))
                    TextField(L10n.text("app.maximum", defaultValue: "Maximum"), text: $model.metadataFilter.maximumISO).accessibilityLabel(L10n.text("app.isoMaximum", defaultValue: "ISO Maximum"))
                }
                GridRow {
                    Text(L10n.text("app.date", defaultValue: "Date"))
                    TextField("YYYY-MM-DD", text: $model.metadataFilter.dateFrom).accessibilityLabel(L10n.text("app.captureDateFrom", defaultValue: "Capture Date From"))
                    Text(L10n.text("app.to", defaultValue: "to"))
                    TextField("YYYY-MM-DD", text: $model.metadataFilter.dateThrough).accessibilityLabel(L10n.text("app.captureDateTo", defaultValue: "Capture Date To"))
                }
            }.textFieldStyle(.instrument)
            if let message = model.metadataFilter.validationMessage { Text(message).foregroundStyle(Theme.warning).font(.caption11) }
        }.font(.caption11)
    }
    private var resultSort: some View {
        Group {
            if model.regularCollectionID != nil {
                Toggle(L10n.text("app.manualOrderDragPhotosToArrange", defaultValue: "Manual Order · Drag photos to arrange"), isOn: Binding(get: { model.manualOrderEnabled }, set: { model.setManualCollectionOrder($0) }))
                Divider()
            }
            Picker(L10n.text("app.sortField", defaultValue: "Sort Field"), selection: Binding(get: { model.photoSort }, set: { value in
                model.manualOrderEnabled = false; model.photoSort = value
            })) { ForEach(PhotoSort.allCases) { Text($0.title).tag($0) } }
            Picker(L10n.text("app.direction", defaultValue: "Direction"), selection: $model.sortDescending) { Text(L10n.text("app.ascending", defaultValue: "Ascending")).tag(false); Text(L10n.text("app.descending", defaultValue: "Descending")).tag(true) }
                .disabled(model.manualOrderEnabled && model.regularCollectionID != nil)
        }
    }
    private func resultControls(compact:Bool = false, narrow:Bool = false) -> some View {
        HStack(spacing: 8) {
            if !narrow {
                Menu { resultSort } label: { if compact { Image(systemName:"arrow.up.arrow.down") } else { Text(model.manualOrderEnabled && model.regularCollectionID != nil ? L10n.text("app.manualOrder", defaultValue: "Manual Order") : "\(model.photoSort.title) \(model.sortDescending ? "↓" : "↑")") } }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().keySurface(height: Self.toolKey)
                    .accessibilityLabel(L10n.text("app.photoSort", defaultValue: "Photo Sort")).accessibilityIdentifier("photo-sort")
            }
            Menu {
                if narrow { Menu(L10n.text("app.sort", defaultValue: "Sort")) { resultSort }; Divider() }
                Menu(L10n.text("app.stacking", defaultValue: "Stacking")) { StackMenu(model:model) }
                Menu(L10n.text("app.rawJPEGPairing", defaultValue: "RAW/JPEG Pairing")) { PairMenu(model:model) }
                Divider()
                Button(L10n.text("app.createVirtualCopiesOfSelection", defaultValue: "Create Virtual Copies of Selection"),action:model.createVirtualCopies).disabled(model.selection.isEmpty)
                Button(L10n.text("app.renameCurrentCopy", defaultValue: "Rename Current Copy…")) {
                    if let photo = model.active { versionID = photo.id; versionName = photo.versionName; versionRename = true }
                }.disabled(model.active?.isVirtualCopy != true)
                Button(L10n.text("app.removeSelectedVersionsKeepOriginals", defaultValue: "Remove Selected Versions (Keep Originals)"),action:model.deleteSelectedVersions).disabled(model.selection.isEmpty)
                Divider()
                Toggle(L10n.text("app.holdResultsUntilManualRefresh", defaultValue: "Hold Results Until Manual Refresh"), isOn: $model.holdFilterResults)
                Button(L10n.text("app.refreshAllResultsManually", defaultValue: "Refresh All Results Manually")) { model.refreshResults() }
                Divider()
                Menu(L10n.text("app.addAllResultsToCollectionVersionsAcrossAllPages", defaultValue: "Add all results to collection (\(model.resultCount) versions across all pages, including collapsed members)")) {
                    Button(L10n.text("app.createCollectionFromAllResults", defaultValue: "Create Collection from All Results…")) { collectionFromResults = true; renameID = nil; newCollection = ""; collectionDialog = true }
                    ForEach(model.collections.filter { !$0.isSmart }) { collection in Button(collection.name) { model.collectResults(collection: collection.id) } }
                }.disabled(model.resultCount == 0)
                Menu(L10n.text("app.addSelectedPhotosToCollection", defaultValue: "Add Selected Photos to Collection (\(model.selection.count))")) {
                    ForEach(model.collections.filter { !$0.isSmart }) { collection in Button(collection.name) { model.membership(collection.id, add: true) } }
                }.disabled(model.selection.isEmpty || model.collections.isEmpty)
                Button(L10n.text("app.saveCurrentFiltersAsSmartCollection", defaultValue: "Save Current Filters as Smart Collection…")) { saveCurrentSmartFilter() }
                Button(model.filtersEnabled ? L10n.text("app.pauseFiltersL", defaultValue: "Pause filters (⌘L)") : L10n.text("app.resumeFiltersL", defaultValue: "Resume filters (⌘L)")) { model.toggleFilters() }
                Button(L10n.text("app.clearFilters", defaultValue: "Clear Filters")) { model.clearFilters() }
            } label: { if compact { Image(systemName:model.holdFilterResults ? "lock" : "line.3.horizontal.decrease") } else { Label(model.holdFilterResults ? L10n.text("app.resultsHeld", defaultValue: "Results Held") : L10n.text("app.results", defaultValue: "Results"), systemImage: model.holdFilterResults ? "lock" : "line.3.horizontal.decrease") } }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .keySurface(height: Self.toolKey, selected: model.holdFilterResults)
                .accessibilityLabel(L10n.text("app.resultsAndOrganization", defaultValue: "Results and Organization")).accessibilityIdentifier("result-actions")
                .help(L10n.text("app.holdModeFreezesMembershipAndOrderForAllResults", defaultValue: "Hold mode freezes membership and order for all results. Changing conditions, sorting, or sources rebuilds the results. Deletions and removals from the current source apply immediately. Restarting the app runs the query again."))
                .disabled(!model.workspaceAvailable)
        }.tint(Theme.text)
    }
    private var keywordFilter: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L10n.text("app.allKeywords", defaultValue: "All Keywords")) { model.keywordFilter = "" }
                Divider()
                ForEach(model.keywords) { keyword in
                    Button(L10n.text("app.keywordCount", defaultValue: "\(keyword.name) (\(keyword.total))")) { model.keywordFilter = keyword.keyword }
                }
            } label: {
                Label(model.keywordFilter.isEmpty ? L10n.text("app.allKeywords", defaultValue: "All Keywords") : model.keywords.first { $0.keyword == model.keywordFilter }?.name ?? model.keywordFilter,
                      systemImage: "tag").lineLimit(1).frame(maxWidth: 240, alignment: .leading)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().keySurface(height: 24)
                .accessibilityIdentifier("keyword-filter")
            if !model.keywordFilter.isEmpty {
                Button { model.keywordFilter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    .help(L10n.text("app.clearKeywordFilter", defaultValue: "Clear Keyword Filter")).accessibilityLabel(L10n.text("app.clearKeywordFilter", defaultValue: "Clear Keyword Filter"))
            }
        }.tint(Theme.text)
    }
    private static let toolKey: CGFloat = 22
    private var zoomControls: some View {
        let fit = !model.fullResolution && !model.fillView
        return HStack(spacing: -1) {
            Button { model.selectZoom(nil) } label: { LampLabel(on: fit) { Text(L10n.text("app.fit_1691", defaultValue: "Fit")) } }
                .buttonStyle(.key(selected: fit, position: .leading, height: Self.toolKey, padding: 8))
                .accessibilityLabel(L10n.text("app.fit_1691", defaultValue: "Fit")).accessibilityAddTraits(fit ? .isSelected : [])
            Button { model.selectZoom(nil, fill: true) } label: { LampLabel(on: model.fillView) { Text(L10n.text("app.fill", defaultValue: "Fill")) } }
                .buttonStyle(.key(selected: model.fillView, position: .middle, height: Self.toolKey, padding: 8))
                .accessibilityLabel(L10n.text("app.fill", defaultValue: "Fill")).accessibilityAddTraits(model.fillView ? .isSelected : [])
            Button { model.selectZoom(1) } label: { Text("1:1") }
                .buttonStyle(.key(selected: model.fullResolution && model.zoomScale == 1, position: .middle, height: Self.toolKey, padding: 7))
                .help(L10n.text("app.inspectAt1000PageUpDownNavigatesSections", defaultValue: "Inspect at 100% (⌥⌘0); Page Up / Down navigates sections, Shift moves horizontally"))
                .accessibilityLabel(L10n.text("app.inspectAt100", defaultValue: "Inspect at 100%"))
            LampLabel(on: model.fullResolution) {
                Menu {
                    ForEach(AppModel.zoomScales, id: \.self) { scale in
                        Button(AppModel.zoomLabel(scale)) { model.selectZoom(scale) }
                    }
                    Divider()
                    Toggle(L10n.text("app.lockViewPosition", defaultValue: "Lock View Position"), isOn: $model.lockViewPosition)
                } label: { Text(model.zoomLabel).monospacedDigit() }
                    .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize()
            }
                .keySurface(position: .trailing, height: Self.toolKey, selected: model.fullResolution, enabled: !model.cropMode && model.image != nil, preservesAppearance: model.editorUsesPreviousPhoto && !model.cropMode)
                .accessibilityLabel(L10n.text("app.zoom", defaultValue: "Zoom")).accessibilityValue(model.zoomLabel)
        }
        .help(L10n.text("app.zoomLevelClickThePhotoToSwitchBetweenFit", defaultValue: "Zoom level; click the photo to switch between Fit and selected zoom (Z)"))
        .editingDisabled(model.cropMode || model.image == nil, temporarilyLocked: model.editorUsesPreviousPhoto && !model.cropMode)
    }
    private func previewIndicator(compact: Bool) -> some View {
        let text = model.isPreviewingAdjustment ? model.adjustmentPreviewTitle : model.previewCurrent ? L10n.text("app.qualityCurrent", defaultValue: "Quality · Current") : model.image == nil ? L10n.text("app.noPreview", defaultValue: "No Preview")
            : model.interactivePreview ? L10n.text("app.draftGenerating", defaultValue: "Draft · Generating") : model.imageStatus.hasPrefix(L10n.text("app.inProgress", defaultValue: "In Progress")) ? L10n.text("app.generating", defaultValue: "Generating") : L10n.text("app.outdated", defaultValue: "Outdated")
        return HStack(spacing: 6) {
            if !compact { SilkText(L10n.text("app.preview_2115", defaultValue: "Preview")).foregroundStyle(Theme.textSecondary) }
            Lamp(on: model.previewCurrent)
            if !compact { Text(text).font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize() }
        }
        .help(compact ? L10n.text("app.preview_2116", defaultValue: "Preview: \(text) · \(model.imageStatus)") : model.imageStatus)
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("app.preview_2115", defaultValue: "Preview")).accessibilityValue(text)
    }
    private var beforeAfterMenu: some View {
        let title = switch model.beforeAfter { case .off: L10n.text("app.off", defaultValue: "Off"); case .sideBySide: L10n.text("app.sideBySide", defaultValue: "Side by Side"); case .split: L10n.text("app.splitView", defaultValue: "Split View") }
        let enabled = model.hasRecipe && !model.cropMode
        return Menu {
            Button(model.before ? L10n.text("app.showAfter", defaultValue: "Show After") : L10n.text("app.showBefore", defaultValue: "Show Before")) { model.toggleBefore() }
            if let reference = model.beforeReference {
                Text(L10n.text("app.comparisonBaseline", defaultValue: "Comparison baseline: ") + reference.title)
                Button(L10n.text("app.restoreOriginalComparisonBaseline", defaultValue: "Restore Original Comparison Baseline"), action: model.resetBeforeReference)
            }
            Divider()
            Picker(L10n.text("app.beforeAfterComparison", defaultValue: "Before / After Comparison"), selection: Binding(get: { model.beforeAfter }, set: { model.showBeforeAfter($0) })) {
                Text(L10n.text("app.off", defaultValue: "Off")).tag(BeforeAfterLayout.off)
                Text(L10n.text("app.sideBySideY", defaultValue: "Side by Side (Y)")).tag(BeforeAfterLayout.sideBySide)
                Text(L10n.text("app.splitViewY", defaultValue: "Split View (⇧Y)")).tag(BeforeAfterLayout.split)
            }.pickerStyle(.inline).labelsHidden().disabled(!model.canShowBeforeAfter)
        } label: {
            Image(systemName: model.beforeAfter == .split ? "rectangle.lefthalf.inset.filled" : "rectangle.split.2x1")
        }
        .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize()
        .keySurface(height: Self.toolKey, selected: model.beforeAfter != .off || model.before, enabled: enabled, preservesAppearance: model.editorUsesPreviousPhoto)
        .editingDisabled(!enabled || model.editorUsesPreviousPhoto, temporarilyLocked: model.editorUsesPreviousPhoto)
        .help(L10n.text("app.beforeAfterSideBySideYOrSplitView", defaultValue: "Before / after: side by side (Y) or split view (⇧Y)"))
        .accessibilityLabel(L10n.text("app.beforeAfterComparison", defaultValue: "Before / After Comparison")).accessibilityValue(model.before ? L10n.text("app.showBefore", defaultValue: "Show Before") : title)
    }
    private var flagFilterKeys: some View {
        HStack(spacing: -1) {
            ForEach(Array(PhotoFlag.allCases.enumerated()), id: \.element.id) { index, flag in
                let selected = model.isFilterSectionActive(.attribute) && model.flagFilter.contains(flag.rawValue)
                Button { model.toggleFlagFilter(flag.rawValue) } label: {
                    LampLabel(on: selected) { Image(systemName: flag.icon).frame(width: 13) }
                }.buttonStyle(.key(selected: selected, position: KeyPosition(index: index, count: 3), height: 22, padding: 5))
                    .accessibilityLabel(L10n.text("app.filter", defaultValue: "Filter: ") + flag.title).accessibilityValue(selected ? L10n.text("app.enabled", defaultValue: "Enabled") : L10n.text("app.inactive", defaultValue: "Inactive"))
                    .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("flag-filter-\(flag.rawValue)")
                    .help(L10n.text("app.filterCombineFlagsOrTurnAllOffToShow", defaultValue: "Filter \(flag.title); combine flags, or turn all off to show every flag state"))
            }
        }.fixedSize().disabled(!model.workspaceAvailable)
    }
    private func flagHelp(_ flag: PhotoFlag) -> String {
        let clear = flag == .unflagged ? "" : L10n.text("app.clickAgainToClear", defaultValue: "; click again to clear")
        if model.survey != nil {
            return L10n.text("app.flagCurrentPhotoHelp", defaultValue: "\(flag.title) (\(flag.shortcut))\(clear). Applies to the current photo")
        }
        let count = L10n.text("app.photos", defaultValue: "\(model.organizationIDs.count) photos")
        return L10n.text("app.flagSelectionHelp", defaultValue: "\(flag.title) (\(flag.shortcut))\(clear). Selection: \(count)")
    }
    private var organizationControls: some View {
        HStack(alignment: .keyCenter, spacing: 8) {
            HStack(spacing: -1) {
                ForEach(Array(PhotoFlag.allCases.enumerated()), id: \.element.id) { index, flag in
                    let selected = model.selectedFlag == flag.rawValue
                    Button { model.toggleFlag(flag.rawValue) } label: {
                        LampLabel(on: selected) { Image(systemName: flag.icon).frame(width: 13) }
                    }.buttonStyle(.key(selected: selected, position: KeyPosition(index: index, count: 3), height: Self.toolKey, padding: 5))
                        .accessibilityLabel(flag.title).accessibilityValue(model.selectedFlag == nil ? L10n.text("app.mixedState", defaultValue: "Mixed State") : selected ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected"))
                        .accessibilityAddTraits(selected ? .isSelected : []).accessibilityIdentifier("set-flag-\(flag.rawValue)")
                        .help(flagHelp(flag))
                }
            }.fixedSize()
            HStack(spacing: 1) {
                Button { model.organize(rating: 0) } label: {
                    Text("0").font(.value).frame(width: 16)
                }.buttonStyle(.key(selected: model.selectedRating == 0, height: Self.toolKey, padding: 4))
                    .help(L10n.text("app.unrated0", defaultValue: "Unrated (0)"))
                    .accessibilityLabel(L10n.text("app.clearRating", defaultValue: "Clear Rating"))
                    .accessibilityValue(model.selectedRating == nil ? L10n.text("app.mixedState", defaultValue: "Mixed State") : model.selectedRating == 0 ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected"))
                    .accessibilityAddTraits(model.selectedRating == 0 ? .isSelected : [])
                    .accessibilityIdentifier("set-rating-0")
                ForEach(1...5, id: \.self) { n in
                    Button { model.toggleRating(n) } label: {
                        Image(systemName: (model.selectedRating ?? 0) >= n ? "star.fill" : "star").font(.system(size: 11))
                            .frame(width: 16, height: Self.toolKey).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(L10n.text("app.setToStarsClickTheCurrentRatingAgainTo", defaultValue: "Set \(model.survey == nil ? L10n.text("app.selectedPhotos_2133", defaultValue: "Selected Photos") : L10n.text("app.currentPhoto", defaultValue: "Current Photo")) to rating \(n); click the current rating again to clear (0)")).accessibilityLabel(L10n.text("app.ratingStars", defaultValue: "Rating \(n) Stars"))
                        .accessibilityIdentifier("set-rating-\(n)")
                }
            }.foregroundStyle(Theme.text).accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.text("app.rating", defaultValue: "Rating")).accessibilityValue(model.selectedRating.map { $0 == 0 ? L10n.text("app.unrated", defaultValue: "Unrated") : L10n.text("app.stars_1722", defaultValue: "\($0) Stars") } ?? L10n.text("app.mixedState", defaultValue: "Mixed State"))
            ColorLabelPicker(model: model)
            quickCollectionControls
        }.disabled(model.selection.isEmpty || !model.workspaceAvailable)
    }
    private var quickCollectionControls: some View {
        HStack(spacing: -1) {
            Button { model.toggleQuickCollection() } label: {
                LampLabel(on: model.quickCollectMembership == true) {
                    Image(systemName: model.quickCollectMembership == nil ? "tray.and.arrow.down" : "tray")
                }
            }.buttonStyle(.key(selected: model.quickCollectMembership == true, position: .leading, height: Self.toolKey, padding: 5))
                .accessibilityLabel(L10n.text("app.quickCollection", defaultValue: "Quick Collection")).accessibilityIdentifier("quick-collect")
                .accessibilityValue(model.quickCollectMembership == nil ? L10n.text("app.someAdded", defaultValue: "Some Added") : model.quickCollectMembership == true ? L10n.text("app.added_2136", defaultValue: "Added") : L10n.text("app.notAdded", defaultValue: "Not Added"))
                .help(model.quickCollectMembership == true
                      ? L10n.text("app.removeQuickCollectionShortcut", defaultValue: "B: Remove from \(model.targetCollection?.name ?? L10n.text("app.quickCollection", defaultValue: "Quick Collection")) · \(model.quickCollectScope)")
                      : L10n.text("app.addQuickCollectionShortcut", defaultValue: "B: Add to \(model.targetCollection?.name ?? L10n.text("app.quickCollection", defaultValue: "Quick Collection")) · \(model.quickCollectScope)"))
            Menu {
                Text(L10n.text("app.target", defaultValue: "Target: \(model.targetCollection?.name ?? L10n.text("app.quickCollection", defaultValue: "Quick Collection"))"))
                Text(L10n.text("app.scope", defaultValue: "Scope: \(model.quickCollectScope)"))
                Divider()
                Button(L10n.text("app.useQuickCollection", defaultValue: "Use Quick Collection")) { model.setTargetCollection(nil) }
                ForEach(model.collections.filter { !$0.isSmart }) { collection in
                    Button { model.setTargetCollection(collection.id) } label: {
                        if model.targetCollectionID == collection.id { Label(collection.name, systemImage: "checkmark") }
                        else { Text(collection.name) }
                    }
                }
            } label: { Image(systemName: "ellipsis").font(.system(size: 10)).frame(width: 12) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Theme.text).fixedSize()
                .keySurface(position: .trailing, height: Self.toolKey)
                .accessibilityLabel(L10n.text("app.quickCollectionTarget_2141", defaultValue: "Quick Collection Target")).help(L10n.text("app.chooseARegularCollectionForQuickCollectionTheCurrent", defaultValue: "Choose a regular collection for Quick Collection. The current target is marked with + in the sidebar"))
        }.fixedSize()
    }
    private var advanceControl: some View {
        Button { model.autoAdvance.toggle() } label: {
            LampLabel(on: model.autoAdvance) { Image(systemName: "arrow.right.to.line") }
        }.buttonStyle(.key(selected: model.autoAdvance, height: Self.toolKey, padding: 5))
            .accessibilityLabel(L10n.text("app.autoAdvance", defaultValue: "Auto Advance")).accessibilityValue(model.autoAdvance ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
            .help(L10n.text("app.autoAdvanceSelectTheNextPhotoAfterFlaggingOr", defaultValue: "Auto Advance: select the next photo after flagging or rating. Shift temporarily reverses it; Caps Lock also enables keyboard culling"))
            .disabled(!model.workspaceAvailable)
    }
    private var centerToolbar: some View {
        ViewThatFits(in: .horizontal) {
            centerToolbarContent(compact: false, narrow: false).frame(minWidth: 840).frame(height: Metrics.toolbar)
            VStack(spacing: 0) {
                HStack(alignment: .keyCenter, spacing: 8) { organizationControls; Spacer(minLength: 4); advanceControl }
                    .padding(.horizontal, 12).frame(height: Metrics.toolbar)
                Seam()
                centerToolbarContent(compact: true, narrow: true).frame(height: Metrics.toolbar)
            }
        }.background(InstrumentPlate())
    }
    private func centerToolbarContent(compact:Bool, narrow:Bool) -> some View {
        HStack(alignment: .keyCenter, spacing: compact ? 5 : 8) {
            if model.editMode {
                Button { model.selectModule(.library) } label: {
                    if narrow { Image(systemName: "square.grid.2x2") }
                    else { Label(L10n.text("app.returnToLibrary", defaultValue: "Return to Library"), systemImage: "square.grid.2x2") }
                }.buttonStyle(.key(height: Self.toolKey, padding: 6)).fixedSize()
                    .help(L10n.text("app.returnToLibraryAndRestoreItsPreviousView", defaultValue: "Return to Library and restore its previous view")).accessibilityLabel(L10n.text("app.returnToLibrary", defaultValue: "Return to Library"))
            } else {
                KeyRow(title: L10n.text("app.viewMode", defaultValue: "View Mode"), options: [
                KeyOption(.grid, L10n.text("app.grid", defaultValue: "Grid"), help: L10n.text("app.gridG", defaultValue: "Grid (G)"), icon: "square.grid.2x2"),
                KeyOption(.single, L10n.text("app.loupe", defaultValue: "Loupe"), help: L10n.text("app.loupeE", defaultValue: "Loupe (E)"), icon: "rectangle"),
                KeyOption(.compare, L10n.text("app.comparePhotos", defaultValue: "Compare Photos"), help: L10n.text("app.comparePhotosCPinTheCurrentPhotoAndSwitch", defaultValue: "Compare photos (C): pin the current photo and switch candidates on the right"), icon: "rectangle.split.2x1",
                          identifier: "comparison-start", enabled: model.active != nil || model.comparison != nil),
                KeyOption(.survey, L10n.text("app.surveyPhotos_2150", defaultValue: "Survey Photos"), help: L10n.text("app.surveyPhotosNViewTheSelectedGroupRemovingCandidates", defaultValue: "Survey photos (N): view the selected group; removing candidates preserves originals"), icon: "square.grid.3x3", identifier: "survey-start", enabled: model.selection.count >= 2 || model.survey != nil),
                ], selection: viewMode, lamps: false, height: Self.toolKey, padding: 7).fixedSize().disabled(!model.workspaceAvailable)
            }
            if !narrow { organizationControls; advanceControl }
            if model.comparison == nil, model.survey == nil {
                adjustmentsMenu.menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize().keySurface(height: Self.toolKey, enabled: !model.busy)
            }
            Button { keywordPopover.toggle() } label: { Image(systemName: "tag") }
                .buttonStyle(.key(selected: keywordPopover, height: Self.toolKey, padding: 6))
                .help(L10n.text("app.manageSelectedPhotosKeywordsAndCaptions", defaultValue: "Manage selected photos' keywords and captions")).accessibilityLabel(L10n.text("app.keywordsAndCaption", defaultValue: "Keywords and Caption")).accessibilityIdentifier("keyword-editor")
                .disabled(model.catalog == nil || !model.workspaceAvailable)
                .popover(isPresented: $keywordPopover) { KeywordEditor(model: model) }
            Spacer(minLength: 4)
            if !model.editMode, model.survey == nil { resultControls(compact:compact, narrow:narrow) }
            if let survey = model.survey {
                SurveyToolbarControls(model: model, survey: survey)
            } else if let comparison = model.comparison {
                ComparisonToolbarControls(model: model, comparison: comparison, compact: narrow)
            } else if model.singleView || model.editMode {
                ViewThatFits(in: .horizontal) {
                    previewIndicator(compact: false)
                    previewIndicator(compact: true)
                    Color.clear.frame(width: 0, height: 0)
                }
                if compact {
                    Button("1:1") { model.selectZoom(1) }
                        .buttonStyle(.key(selected: model.fullResolution && model.zoomScale == 1, height: Self.toolKey, padding: 6))
                        .editingDisabled(model.cropMode || model.image == nil, temporarilyLocked: model.editorUsesPreviousPhoto && !model.cropMode)
                        .accessibilityLabel(L10n.text("app.inspectAt100", defaultValue: "Inspect at 100%")).help(L10n.text("app.inspectAt1000", defaultValue: "Inspect at 100% (⌥⌘0)"))
                    Menu {
                        Button(L10n.text("app.fit_1691", defaultValue: "Fit")) { model.selectZoom(nil) }; Button(L10n.text("app.fill", defaultValue: "Fill")) { model.selectZoom(nil,fill:true) }
                        Divider()
                        ForEach(AppModel.zoomScales,id:\.self) { factor in Button(AppModel.zoomLabel(factor)) { model.selectZoom(factor) } }
                        Divider()
                        Toggle(L10n.text("app.lockViewPosition", defaultValue: "Lock View Position"), isOn: $model.lockViewPosition)
                    } label:{ Text(model.fullResolution ? model.zoomLabel : model.fillView ? L10n.text("app.fill", defaultValue: "Fill") : L10n.text("app.fit_1691", defaultValue: "Fit")) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .keySurface(height:Self.toolKey, selected:model.fullResolution || model.fillView, enabled:!model.cropMode && model.image != nil, preservesAppearance: model.editorUsesPreviousPhoto && !model.cropMode)
                        .editingDisabled(model.cropMode || model.image == nil, temporarilyLocked: model.editorUsesPreviousPhoto && !model.cropMode)
                        .accessibilityLabel(L10n.text("app.zoom", defaultValue: "Zoom")).accessibilityValue(model.fullResolution ? model.zoomLabel : model.fillView ? L10n.text("app.fill", defaultValue: "Fill") : L10n.text("app.fit_1691", defaultValue: "Fit"))
                } else { zoomControls.fixedSize() }
                if !narrow { Button { matPopover.toggle() } label: { Image(systemName: "circle.lefthalf.filled") }
                    .buttonStyle(.key(selected: matPopover, height: Self.toolKey, padding: 6))
                    .help(L10n.text("app.viewingMat_2154", defaultValue: "Viewing mat: \(mat.title)")).accessibilityLabel(L10n.text("app.viewingMat", defaultValue: "Viewing Mat")).accessibilityValue(mat.title)
                    .popover(isPresented: $matPopover, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            SilkText(L10n.text("app.viewingMat", defaultValue: "Viewing Mat")).foregroundStyle(Theme.textSecondary)
                            DetentSelector(title: L10n.text("app.viewingMat", defaultValue: "Viewing Mat"), options: PhotoMat.allCases.map { KeyOption($0, $0.title) }, selection: $mat)
                            Text(L10n.text("app.changesOnlyThePhotoSurroundPhotoPixelsArePreserved", defaultValue: "Changes only the photo surround; photo pixels are preserved")).font(.caption11).foregroundStyle(Theme.textSecondary)
                        }.padding(16)
                    }
                Button { model.toggleBefore() } label:{ if compact { Image(systemName:"backward.end") } else { Text(L10n.text("app.before", defaultValue: "Before")) } }
                    .buttonStyle(.key(selected: model.before, height: Self.toolKey)).fixedSize()
                    .editingDisabled(!model.hasRecipe || model.cropMode || model.editorUsesPreviousPhoto, temporarilyLocked: model.editorUsesPreviousPhoto && !model.cropMode)
                    .help(model.before ? L10n.text("app.showingBeforeClickToShowAdjustmentsBackslash", defaultValue: "Showing Before; click to show adjustments (Backslash)") : L10n.text("app.showBeforeBackslash", defaultValue: "Show Before (Backslash)"))
                    .accessibilityLabel(L10n.text("app.before", defaultValue: "Before")).accessibilityValue(model.before ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off")) }
                beforeAfterMenu
                if model.editMode {
                    Button { model.toggleDevelopReference() } label: { Text(L10n.text("app.reference_2157", defaultValue: "Reference")) }
                        .buttonStyle(.key(selected: model.developReference != nil, height: Self.toolKey, padding: 6)).fixedSize()
                        .editingDisabled(!model.canShowDevelopReference || !model.workspaceAvailable, temporarilyLocked: model.editorUsesPreviousPhoto && model.workspaceAvailable)
                        .help(L10n.text("app.pinAReferenceAndEditTheCurrentPhotoR", defaultValue: "Pin a reference and edit the current photo (⇧R); zoom each side independently"))
                        .accessibilityLabel(L10n.text("app.developReference", defaultValue: "Develop Reference")).accessibilityValue(model.developReference == nil ? L10n.text("app.off", defaultValue: "Off") : L10n.text("app.on", defaultValue: "On"))
                }
            } else {
                Image(systemName: "square.grid.2x2").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                GradientAdjustmentSlider(value: model.thumbnailSize, range: 100...240, step: 1, neutral: 156, track: .tonal,
                                         label: L10n.text("app.thumbnailSize", defaultValue: "Thumbnail Size"), change: { model.thumbnailSize = $0 }, commit: {})
                    .frame(width: 90, height: 28).help(L10n.text("app.thumbnailSize", defaultValue: "Thumbnail Size"))
            }
        }.padding(.horizontal, 12).frame(height: Metrics.toolbar).background(InstrumentPlate())
    }

    // MARK: Inspector

    private var tool: Binding<DevelopTool> {
        Binding(get: { model.developTool }, set: { model.selectDevelopTool($0) })
    }
    private func inspector(compactMasks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceRegion {
                HistogramScope(histogram: model.histogram ?? model.photoSwitchDisplay?.histogram,
                               details: model.editMode && model.developTool == .adjust && model.developReference == nil
                                   && model.comparison == nil && model.survey == nil ? nil : model.active?.details,
                               placeholder: model.comparison != nil ? L10n.text("app.histogramHiddenDuringComparison", defaultValue: "Histogram hidden during comparison") : L10n.text("app.waitingForPreview", defaultValue: "Waiting for preview"),
                               clippingShown: model.showClipping,
                               shadowClippingShown: clippingPreview.preview?.shadows ?? model.showShadowClipping,
                               highlightClippingShown: clippingPreview.preview?.highlights ?? model.showHighlightClipping,
                               toggleClipping: canInspectClipping ? { model.showClipping.toggle() } : nil,
                               toggleShadowClipping: canInspectClipping ? { clippingPreview.cancel(); model.showShadowClipping.toggle() } : nil,
                               toggleHighlightClipping: canInspectClipping ? { clippingPreview.cancel(); model.showHighlightClipping.toggle() } : nil,
                               previewClipping: canInspectClipping ? { shadows, pressed in
                                   if pressed { clippingPreview.begin(current: fixedClipping, preview: ClippingVisibility(shadows: shadows, highlights: !shadows)) }
                                   else { _ = clippingPreview.end() }
                               } : nil,
                               pulseClipping: canInspectClipping ? { shadows in
                                   clippingPreview.pulse(current: fixedClipping, preview: ClippingVisibility(shadows: shadows, highlights: !shadows))
                               } : nil,
                               pixelReadout: model.displayPixelReadout, compact: compactMasks, interactionID: model.activeID).padding(compactMasks ? 6 : 12)
            }
            if let photo = model.active {
                if model.editMode {
                    Seam()
                    KeyRow(title: L10n.text("app.tools", defaultValue: "Tools"), options: [KeyOption(.adjust, L10n.text("app.adjustTool", defaultValue: "Adjust")), KeyOption(.crop, L10n.text("app.crop", defaultValue: "Crop"), help: L10n.text("app.cropR", defaultValue: "Crop (R)")), KeyOption(.spot, L10n.text("app.spots", defaultValue: "Spots"), help: L10n.text("app.spotRemovalQ", defaultValue: "Spot Removal (Q)")), KeyOption(.mask, L10n.text("app.masks", defaultValue: "Masks"), help: L10n.text("app.masksW", defaultValue: "Masks (⇧W)"))],
                           selection: tool, expand: true)
                        .editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                    Seam()
                    if model.developTool != .adjust {
                        HStack {
                            Text(model.cropMode ? L10n.text("app.cropAndGeometry", defaultValue: "Crop and Geometry") : model.maskMode ? L10n.text("app.localMasks", defaultValue: "Local · Masks") : L10n.text("app.spotRemoval", defaultValue: "Spot Removal")).font(.caption11).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button(L10n.text("app.done", defaultValue: "Done")) { model.selectDevelopTool(.adjust) }.buttonStyle(.key(height: 22))
                                .help(L10n.text("app.finishCurrentToolAndRetainAdjustmentsEsc", defaultValue: "Finish current tool and retain adjustments (Esc)")).accessibilityIdentifier("develop-tool-done")
                        }.padding(.horizontal, 12).padding(.vertical, 6)
                        Seam()
                    }
                    if photo.supportsEditing, model.hasEditorRecipe {
                        if model.maskMode {
                            MaskPanel(model: model, compact: compactMasks).editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto)
                        } else if model.spotMode {
                            SpotPanel(model: model).editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto)
                        } else {
                            ScrollViewReader { proxy in
                                RememberedPanelScroll(offset: model.cropMode ? $cropScrollOffset : $developScrollOffset) {
                                    DevelopPanel(model: model,
                                    onPreviewGroup: { group, pressed in
                                        if pressed { model.beginDevelopGroupPreview(group) }
                                        else { model.endDevelopGroupPreview() }
                                    },
                                    onPulsePreviewGroup: { model.pulseDevelopGroupPreview($0) },
                                    previewingGroup: model.previewingDevelopGroup,
                                    onOpenGroup: { group in
                                        if group == .crop || group == .perspective { model.selectDevelopTool(.crop) }
                                        else if model.cropMode { model.selectDevelopTool(.adjust) }
                                        DispatchQueue.main.async {
                                            proxy.scrollTo("develop-group-\(group.rawValue)", anchor: .top)
                                        }
                                    }).editingDisabled(!model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto)
                                }.id(model.cropMode).accessibilityIdentifier("develop-scroll")
                            }
                        }
                    } else {
                        Text(L10n.text("app.adjustmentsBecomeAvailableAfterDecodingAndCreatingTheEdit", defaultValue: "Adjustments become available after decoding and creating the edit baseline."))
                            .foregroundStyle(Theme.textSecondary).padding(Metrics.padding)
                        Spacer()
                    }
                } else {
                    Seam()
                    PanelTitle(L10n.text("app.photoInformation", defaultValue: "Photo Information"))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(photo.displayName).fontWeight(.semibold)
                            Text((photo.isRAW ? "RAW" : URL(fileURLWithPath:photo.relativePath).pathExtension.uppercased()) + " · " + photo.versionName).font(.caption11).foregroundStyle(Theme.textSecondary)
                            SubgroupLabel(L10n.text("app.versionsAndPairing", defaultValue: "Versions and Pairing"))
                            HStack(spacing: Metrics.gap) {
                                Menu("RAW/JPEG") { PairMenu(model:model) }.accessibilityLabel(L10n.text("app.rawJPEGPairing", defaultValue: "RAW/JPEG Pairing")).keySurface(height: 24)
                                Menu(L10n.text("app.otherVersions", defaultValue: "Other Versions")) {
                                    Button(L10n.text("app.compareRelatedVersions", defaultValue: "Compare Related Versions")) { model.compareRelatedVersions() }
                                    if model.activeStack != nil { Button(L10n.text("app.compareStackMembers", defaultValue: "Compare Stack Members")) { model.compareRelatedVersions(inStack: true) } }
                                    Divider()
                                    ForEach((try? model.catalog?.versions(sourceID:photo.sourceKey)) ?? []) { version in
                                        Button(version.versionName) { model.openVersion(version.id) }.disabled(version.id == photo.id)
                                    }
                                }.accessibilityLabel(L10n.text("app.otherVersionsOfTheSameOriginal", defaultValue: "Other Versions of the Same Original")).keySurface(height: 24)
                            }.menuStyle(.borderlessButton).tint(Theme.text).fixedSize()
                            SubgroupLabel(L10n.text("app.capture", defaultValue: "Capture"))
                            Text("\(photo.width) × \(photo.height)").monospacedDigit()
                            Text(photo.camera ?? L10n.text("app.noCameraInformationProvided", defaultValue: "No camera information provided"))
                            Text(photo.captureDate ?? L10n.text("app.noCaptureDateProvided", defaultValue: "No capture date provided"))
                            if let info = photo.details {
                                if let lens = info.lens { Text(lens) }
                                if let iso = info.iso { Text("ISO \(iso)") }
                                if let aperture = info.aperture { Text(String(format: "ƒ/%.1f", aperture)) }
                                if let time = info.exposureText { Text(time) }
                                if let focal = info.focalLength { Text(String(format: "%.0f mm", focal)) }
                            }
                            if !photo.isRAW && photo.details?.profile == nil {
                                Text(L10n.text("app.noRecognizedICCProfileDisplayAndOutputAssumeSRGB", defaultValue: "No recognized ICC profile; display and output assume sRGB")).font(.caption11).foregroundStyle(Theme.textSecondary)
                            }
                            Text(photo.relativePath).font(.caption11).foregroundStyle(Theme.textSecondary)
                        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Metrics.padding).padding(.bottom, 12)
                    }
                }
            } else {
                Seam()
                Text(L10n.text("app.selectAPhotoToViewInformation", defaultValue: "Select a photo to view information")).foregroundStyle(Theme.textSecondary).padding(Metrics.padding)
                Spacer()
            }
            Seam()
            inspectorFooter.padding(12)
        }.background(InstrumentPlate())
            .environment(\.adjustmentPhotoID, model.activeID)
    }

    private var inspectorFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.gap) {
                inspectorUndoControls.fixedSize()
                Spacer(minLength: 0)
                inspectorTransferControl.fixedSize()
                inspectorResetControl.fixedSize()
            }
            VStack(alignment: .leading, spacing: Metrics.gap) {
                HStack(spacing: Metrics.gap) {
                    inspectorUndoControls.fixedSize()
                    Spacer(minLength: 0)
                    inspectorResetControl.fixedSize()
                }
                inspectorTransferControl.fixedSize()
            }
        }
    }
    @ViewBuilder private var inspectorUndoControls: some View {
        Button(L10n.text("app.undo_244", defaultValue: "Undo")) { if model.smartMaskSession != nil { model.undoSmartPrompt() } else { model.undo.undo() } }.buttonStyle(.key)
            .editingDisabled(model.editMode && !model.canEdit || (model.smartMaskSession.map { $0.busy || $0.promptHistory.isEmpty } ?? !model.undo.canUndo), temporarilyLocked: model.editorUsesPreviousPhoto && model.undo.canUndo).help(L10n.text("app.undoZ", defaultValue: "Undo (⌘Z)"))
        Button(L10n.text("app.redo_245", defaultValue: "Redo")) { model.undo.redo() }.buttonStyle(.key).editingDisabled(model.editMode && !model.canEdit || model.smartMaskSession != nil || !model.undo.canRedo, temporarilyLocked: model.editorUsesPreviousPhoto && model.undo.canRedo).help(L10n.text("app.redoZ", defaultValue: "Redo (⇧⌘Z)"))
    }
    @ViewBuilder private var inspectorTransferControl: some View {
        if model.editMode, model.selection.subtracting(Set([model.activeID].compactMap { $0 })).count > 0 {
            Button(L10n.text("app.sync", defaultValue: "Sync…")) { model.requestAdjustments(.sync) }.buttonStyle(.key)
                .editingDisabled(!model.canEdit || !model.workspaceAvailable, temporarilyLocked: model.editorUsesPreviousPhoto && model.workspaceAvailable)
                .help(L10n.text("app.syncSelectedAdjustmentsFromTheCurrentPhotoToOther", defaultValue: "Sync selected adjustments from the current photo to other selected photos")).accessibilityLabel(L10n.text("app.syncAdjustments", defaultValue: "Sync Adjustments"))
        }
        if model.editMode, model.selection.count == 1 {
            Button(L10n.text("app.usePrevious", defaultValue: "Use Previous…")) { model.requestAdjustments(.previous) }.buttonStyle(.key)
                .editingDisabled(!model.canUsePreviousAdjustments || !model.workspaceAvailable, temporarilyLocked: model.editorUsesPreviousPhoto && model.editorPreviousAdjustmentsAvailable && model.workspaceAvailable)
                .help(model.previousAdjustmentSource.map { L10n.text("app.source_2184", defaultValue: "Source: ") + $0.photo.displayName + L10n.text("app.scope_2185", defaultValue: "; scope: ") + model.confirmedAdjustmentOptions.summary } ?? L10n.text("app.viewAnotherDecodedPhotoToReuseItsAdjustments", defaultValue: "View another decoded photo to reuse its adjustments"))
                .accessibilityIdentifier("previous-adjustments")
        }
    }
    @ViewBuilder private var inspectorResetControl: some View {
        Button(L10n.text("app.reset_2187", defaultValue: "Reset")) { model.changeRecipe { $0 = $0.resetForCurrentPipeline() } }
            .buttonStyle(.key)
            .editingDisabled(!model.hasRecipe || !model.canEdit, temporarilyLocked: model.editorUsesPreviousPhoto)
            .help(L10n.text("app.resetAllAdjustmentsForTheCurrentPhotoUndoAvailable", defaultValue: "Reset all adjustments for the current photo; undo available"))
    }

    private var canInspectClipping: Bool {
        model.comparison == nil && model.survey == nil && !model.cropMode && !model.showPointColorRange && (model.singleView || model.editMode)
    }
    private var fixedClipping: ClippingVisibility {
        ClippingVisibility(shadows: model.showShadowClipping, highlights: model.showHighlightClipping)
    }

    // MARK: Filmstrip and status

    private var filmstripBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: -1) {
                Button { model.navigateBrowse(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.key(position: .leading, height: 18, padding: 5))
                    .disabled(!model.canBrowseBack || !model.workspaceAvailable)
                    .help(L10n.text("app.goToPreviousBrowseLocation", defaultValue: "Go to previous browse location (⌘[)")).accessibilityLabel(L10n.text("app.browseBack", defaultValue: "Browse Back"))
                Button { model.navigateBrowse(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.key(position: .trailing, height: 18, padding: 5))
                    .disabled(!model.canBrowseForward || !model.workspaceAvailable)
                    .help(L10n.text("app.goToNextBrowseLocation", defaultValue: "Go to next browse location (⌘])")).accessibilityLabel(L10n.text("app.browseForward", defaultValue: "Browse Forward"))
            }
            HStack(spacing: -1) {
                Button { model.move(-1) } label: { Image(systemName: "arrow.left").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.key(position: .leading, height: 18, padding: 6)).help(L10n.text("app.previousPhoto", defaultValue: "Previous Photo")).accessibilityLabel(L10n.text("app.previousPhoto", defaultValue: "Previous Photo"))
                Button { model.move(1) } label: { Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.key(position: .trailing, height: 18, padding: 6)).help(L10n.text("app.nextPhoto", defaultValue: "Next Photo")).accessibilityLabel(L10n.text("app.nextPhoto", defaultValue: "Next Photo"))
            }
            Menu {
                if !model.recentBrowseLocations.isEmpty {
                    Menu(L10n.text("app.recentBrowseLocations", defaultValue: "Recent Browse Locations")) {
                        ForEach(model.recentBrowseLocations) { location in
                            Button(location.title + (location.photo.isEmpty ? "" : " · " + location.photo)) { model.navigateBrowse(to: location.id) }
                        }
                    }
                    Divider()
                }
                if model.active != nil {
                    Button(L10n.text("app.compareRelatedVersions", defaultValue: "Compare Related Versions")) { model.compareRelatedVersions() }
                    if model.activeStack != nil { Button(L10n.text("app.compareStackMembers", defaultValue: "Compare Stack Members")) { model.compareRelatedVersions(inStack: true) } }
                    Divider()
                }
                Button(L10n.text("app.selectAllQueryVersionsIncludingCollapsedMembersAndAll", defaultValue: "Select All Query Versions, Including Collapsed Members and All Pages"),action:model.selectAllResults)
                Button(L10n.text("app.selectCurrentVisiblePage", defaultValue: "Select Current Visible Page")) { model.choose(Set(model.photos.map(\.id)), active: model.activeID ?? model.photos.first?.id) }
                Button(L10n.text("app.clearSelection", defaultValue: "Clear Selection")) { model.choose([], active: model.activeID) }
            } label: { Text(sourceName).lineLimit(1).truncationMode(.middle) }
                .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).frame(maxWidth: 180, alignment: .leading)
                .help(sourceName).accessibilityLabel(L10n.text("app.sourcesAndSelection", defaultValue: "Sources and Selection"))
            Text(L10n.text("app.matchingVisible", defaultValue: "Matching \(model.resultCount) / Visible \(model.visibleCount) / \(model.survey == nil ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.candidate_1903", defaultValue: "Candidate")) \(model.selection.count)")).monospacedDigit().fixedSize()
                .help(model.survey == nil ? L10n.text("app.matchingCountsBaseQueryVersionsVisibleCountsCardsAfter", defaultValue: "Matching counts base query versions; Visible counts cards after stack expansion / collapse; Selected counts actual action targets. All query versions include collapsed members.") : L10n.text("app.candidatesBelongToTheCurrentSurveyGroupRatingsFlags", defaultValue: "Candidates belong to the current Survey group. Ratings, flags, and Quick Collection affect the active photo only. Other batch commands use the scope stated in their menus."))
            if model.isViewingImport {
                Button(L10n.text("app.returnToPreviousBrowseLocation_2202", defaultValue: "Return to Previous Browse Location")) { model.returnFromImport() }
                    .buttonStyle(.key(height: 20, padding: 6)).disabled(!model.workspaceAvailable)
                    .help(L10n.text("app.restoreTheSourceFiltersPageAndSelectionFromBefore", defaultValue: "Restore the source, filters, page, and selection from before this import"))
            }
            if model.isViewingRelated {
                Button(L10n.text("app.returnToPreviousBrowseLocation_2202", defaultValue: "Return to Previous Browse Location")) { model.navigateBrowse(-1) }
                    .buttonStyle(.key(height: 20, padding: 6)).disabled(!model.workspaceAvailable)
                    .help(L10n.text("app.leaveTheTemporaryGroupAndRestoreThePreviousSource", defaultValue: "Leave the temporary group and restore the previous source, filters, and position"))
            }
            Text(model.active?.displayName ?? "").fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                .help(model.active?.relativePath ?? "")
            if model.visibleCount > model.pageSize {
                HStack(spacing: 4) {
                    Button { model.changePage(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).disabled(model.pageOffset == 0).help(L10n.text("app.previousPage", defaultValue: "Previous Page")).accessibilityLabel(L10n.text("app.previousPage", defaultValue: "Previous Page"))
                    Text("\(model.pageOffset + 1)–\(model.pageOffset + model.photos.count)").monospacedDigit()
                    Button { model.changePage(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).disabled(model.pageOffset + model.photos.count >= model.visibleCount).help(L10n.text("app.nextPage", defaultValue: "Next Page")).accessibilityLabel(L10n.text("app.nextPage", defaultValue: "Next Page"))
                }
            }
            Spacer(minLength: 4)
            if model.editMode { resultControls(compact: true, narrow: true) }
            if model.editMode { flagFilterKeys }
            Button {
                if model.editMode { filterPopover.toggle() }
                else { model.libraryFiltersOpen.toggle(); model.persistWorkspace() }
            } label: {
                Label(model.editMode ? (hasFilter ? L10n.text("app.filtered", defaultValue: "Filtered") : L10n.text("app.filter_2208", defaultValue: "Filter")) : L10n.text("app.libraryFilters", defaultValue: "Library Filters"), systemImage: "line.3.horizontal.decrease")
            }
            .buttonStyle(.key(selected: model.editMode ? filterPopover : model.libraryFiltersOpen, height: 22, padding: 6))
            .accessibilityLabel(model.editMode ? L10n.text("app.filmstripFilters", defaultValue: "Filmstrip Filters") : L10n.text("app.showLibraryFilterBar", defaultValue: "Show Library Filter Bar"))
            .accessibilityValue(model.editMode ? (filterPopover ? L10n.text("app.expand", defaultValue: "Expand") : L10n.text("app.collapse", defaultValue: "Collapse")) : (model.libraryFiltersOpen ? L10n.text("app.expand", defaultValue: "Expand") : L10n.text("app.collapse", defaultValue: "Collapse")))
            .help(model.editMode ? L10n.text("app.openFilmstripFilters", defaultValue: "Open Filmstrip Filters") : L10n.text("app.showOrHideTheEntireLibraryFilterBarBackslash", defaultValue: "Show or hide the entire Library filter bar (Backslash); hiding preserves conditions"))
            .popover(isPresented: $filterPopover) { filterbar.frame(width: 520).padding(8) }
        }.font(.caption11).padding(.horizontal, 12).frame(height: Metrics.filmBar).background(InstrumentPlate())
    }
    private var statusBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.status).lineLimit(1).truncationMode(.tail).help(model.status)
                if model.singleView || model.editMode {
                    Text(model.imageStatus).lineLimit(1).truncationMode(.tail).help(model.imageStatus)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            RimToggle(edge: .bottom, isOpen: film, label: L10n.text("app.filmstrip", defaultValue: "Filmstrip"), shortcut: "⌥⌘3") { film.toggle() }
            statusTasks.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.caption11).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12).frame(height: Metrics.statusBar).background(Theme.base)
    }
    private var statusTasks: some View {
        HStack(spacing: 10) {
            if model.showImportCompletion, !model.busy {
                Button(L10n.text("app.viewThisImport", defaultValue: "View This Import")) { model.showLastImport() }.buttonStyle(.key(height: 18, padding: 8))
                    .disabled(!model.workspaceAvailable)
                Button(L10n.text("app.startCulling", defaultValue: "Start Culling")) { model.showLastImport(startCulling: true) }.buttonStyle(.key(height: 18, padding: 8))
                    .disabled(!model.workspaceAvailable)
            } else if let result = model.lastExportResult, !model.busy {
                Button(L10n.text("app.exportResults", defaultValue: "Export results \(result.completed)/\(result.ids.count)")) { model.openExportRecords(ids: result.ids) }
                    .buttonStyle(.key(height: 18, padding: 8)).disabled(!model.workspaceAvailable)
                if result.completed > 0 {
                    Button(L10n.text("app.locateOutput", defaultValue: "Locate Output")) { model.revealExports(ids: result.ids) }.buttonStyle(.key(height: 18, padding: 8))
                }
                if result.completed < result.ids.count {
                    Button(L10n.text("app.viewIncomplete", defaultValue: "View Incomplete")) { model.openExportRecords(ids: result.ids, unfinishedOnly: true) }
                        .buttonStyle(.key(height: 18, padding: 8)).disabled(!model.workspaceAvailable)
                }
            }
            if model.dirty {
                Label(L10n.text("app.notSaved", defaultValue: "Not Saved"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Button(L10n.text("app.retrySave", defaultValue: "Retry Save")) { model.commitRecipe() }.buttonStyle(.key(height: 18, padding: 8))
            }
            if model.busy {
                if let progress = model.taskProgress {
                    Text(progress.title)
                    SegmentMeter(done: progress.done, total: progress.total)
                    Text("\(progress.done) / \(progress.total)").monospacedDigit()
                } else {
                    Text(L10n.text("app.processing", defaultValue: "Processing"))
                }
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { model.task?.cancel() }.buttonStyle(.key(height: 18, padding: 8))
            }
            Button(L10n.text("app.taskResults_2221", defaultValue: "Task results \(model.reports.count)")) { reports = true }
                .buttonStyle(.plain).foregroundStyle(model.reports.isEmpty ? Theme.textSecondary : Theme.text)
                .help(L10n.text("app.viewIndividualResultsFromTheLatestTask", defaultValue: "View individual results from the latest task"))
        }
    }
}

/// These strips read photo metadata independently of high-frequency canvas pixels.
struct PhotoViewingInfo: View {
    let photo: Photo?
    let mat: PhotoMat
    var capture = false

    static func captureItems(_ details: PhotoMetadata?) -> [String] {
        guard let details else { return [] }
        return [details.focalLength.map { String(format: "%.0f mm", $0) },
                details.aperture.map { String(format: "ƒ/%.1f", $0) }, details.exposureText,
                details.iso.map { "ISO \($0)" }].compactMap { $0 }
    }

    @ViewBuilder var body: some View {
        if let photo {
            if capture {
                let items = Self.captureItems(photo.details)
                if photo.camera?.isEmpty == false || !items.isEmpty {
                    HStack(spacing: Metrics.gap) {
                        if let camera = photo.camera {
                            Text(camera).lineLimit(1).truncationMode(.middle).help(camera)
                        }
                        Spacer(minLength: Metrics.gap)
                        Text(items.joined(separator: " · ")).fixedSize()
                    }
                    .font(.caption11).monospacedDigit().foregroundStyle(Color(nsColor: mat.textSecondary))
                    .padding(.horizontal, Metrics.padding).frame(height: Metrics.topBar).background(mat.color)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("develop-photo-capture")
                }
            } else {
                HStack(spacing: Metrics.gap) {
                    Image(systemName: "photo").accessibilityHidden(true)
                    Text(photo.displayName).lineLimit(1).truncationMode(.middle).help(photo.displayName)
                    Spacer(minLength: Metrics.gap)
                    Text(photo.isRAW ? "RAW" : URL(fileURLWithPath: photo.relativePath).pathExtension.uppercased())
                        .font(.caption11).foregroundStyle(Color(nsColor: mat.textSecondary))
                }
                .font(.section).foregroundStyle(Color(nsColor: mat.text))
                .padding(.horizontal, Metrics.padding).frame(height: Metrics.topBar).background(mat.color)
                .accessibilityElement(children: .combine).accessibilityIdentifier("develop-photo-title")
            }
        }
    }
}

/// Reserve a usable canvas even when both stored panel widths exceed the current window.
/// Narrow windows drop the optional left panel before squeezing the inspector's values.
enum WorkspaceDimensions {
    static func widths(available: CGFloat, left: Double, right: Double, showLeft: Bool, showRight: Bool) -> (left: CGFloat, right: CGFloat) {
        let leftRange = Metrics.leftPanel.range, rightRange = Metrics.rightPanel.range
        let minR = showRight ? rightRange.lowerBound : 0
        let fitsLeft = showLeft && available - minR - Metrics.photoMinWidth - 2 >= leftRange.lowerBound
        let l = fitsLeft ? min(leftRange.upperBound, max(leftRange.lowerBound, left)) : 0
        let r = showRight ? min(rightRange.upperBound, max(rightRange.lowerBound, right)) : 0
        let minL = fitsLeft ? leftRange.lowerBound : 0
        let seams: CGFloat = (fitsLeft ? 1 : 0) + (showRight ? 1 : 0)
        let budget = max(minL + minR, available - Metrics.photoMinWidth - seams)
        let extra = l + r - minL - minR
        let ratio = extra > 0 ? min(1, max(0, budget - minL - minR) / extra) : 1
        return (floor(minL + (l - minL) * ratio), floor(minR + (r - minR) * ratio))
    }
}

/// The seam itself is the resize handle; a wider invisible strip keeps it easy to grab.
/// Follows the hosting window's full-screen state; the system window buttons are hidden while it is full screen.
/// Flips at the start of each transition so the top bar never overlaps the returning buttons.
struct FullScreenReader: NSViewRepresentable {
    @Binding var fullScreen: Bool
    func makeNSView(context: Context) -> Probe { Probe { fullScreen = $0 } }
    func updateNSView(_ view: Probe, context: Context) { view.report = { fullScreen = $0 } }
    final class Probe: NSView {
        var report: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        init(report: @escaping (Bool) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let isFull = window.styleMask.contains(.fullScreen)
            DispatchQueue.main.async { [weak self] in self?.report(isFull) }
            for (name, value) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report(value) }
                })
            }
        }
    }
}

struct WorkspaceResizeHandle: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let initial: Double
    var horizontal = true
    var direction = 1.0
    let label: String
    @State private var start: Double?
    @State private var hovering = false
    var body: some View {
        Seam(axis: horizontal ? .vertical : .horizontal)
            .overlay {
                (hovering || start != nil ? Theme.controlBorder : Color.clear)
                    .frame(width: horizontal ? 2 : nil, height: horizontal ? nil : 2)
                    .allowsHitTesting(false)
            }
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { event in
                            if start == nil { start = value }
                            let delta = horizontal ? event.translation.width : event.translation.height
                            value = min(range.upperBound, max(range.lowerBound, (start ?? value) + delta * direction))
                        }.onEnded { _ in start = nil })
                    .onTapGesture(count: 2) { value = initial }
                    .onHover { inside in
                        hovering = inside
                        if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
                        else { NSCursor.arrow.set() }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(label).accessibilityValue("\(Int(value))")
                    .accessibilityAdjustableAction { action in
                        if action == .increment { value = min(range.upperBound, value + 10) }
                        if action == .decrement { value = max(range.lowerBound, value - 10) }
                    }
                    .help(L10n.text("app.dragToResizeDoubleClickToRestoreTheDefault", defaultValue: "Drag to resize \(label); double-click to restore the default"))
            }
            .zIndex(1)
    }
}

/// A triangle silk-printed on the chassis rim; the whole rim segment beside the panel is the hit area.
/// The triangle points the way the panel moves when clicked.
struct RimToggle: View {
    let edge: Edge
    let isOpen: Bool
    let label: String
    let shortcut: String
    var blocked: String?
    let toggle: () -> Void
    @State private var hovering = false
    private var vertical: Bool { edge == .leading || edge == .trailing }
    private var pointing: Edge {
        if isOpen { return edge }
        switch edge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .bottom
        case .bottom: return .top
        }
    }
    var body: some View {
        Button(action: toggle) {
            EdgeTriangle(pointing: pointing)
                .fill(blocked != nil ? Theme.textDisabled : hovering ? Theme.text : Theme.textSecondary)
                .frame(width: vertical ? 5 : 7, height: vertical ? 7 : 5)
                .frame(maxWidth: vertical ? Metrics.rim : 48, maxHeight: vertical ? .infinity : Metrics.statusBar)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: vertical ? Metrics.rim : 48)
        .background(vertical ? Theme.base : .clear)
        .disabled(blocked != nil)
        .onHover { hovering = $0 }
        .help(blocked ?? (isOpen
                         ? L10n.text("app.collapsePanelShortcut", defaultValue: "Collapse \(label) (\(shortcut))")
                         : L10n.text("app.expandPanelShortcut", defaultValue: "Expand \(label) (\(shortcut))")))
        .accessibilityLabel(label).accessibilityValue(isOpen ? L10n.text("app.expanded", defaultValue: "Expanded") : L10n.text("app.collapsed", defaultValue: "Collapsed"))
    }
}

private struct EdgeTriangle: Shape {
    let pointing: Edge
    func path(in r: CGRect) -> Path {
        let points: [CGPoint]
        switch pointing {
        case .leading: points = [CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY)]
        case .trailing: points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.maxY)]
        case .top: points = [CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)]
        case .bottom: points = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)]
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

private struct SnapshotNameSheet: View {
    @Binding var name: String
    @Binding var renameID: String?
    @Binding var presented: Bool
    let save: (String, String?) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renameID == nil ? L10n.text("app.newSnapshot", defaultValue: "New Snapshot") : L10n.text("app.renameSnapshot", defaultValue: "Rename Snapshot")).font(.headline)
            TextField(L10n.text("app.snapshotName", defaultValue: "Snapshot Name"), text: $name)
            HStack {
                Spacer()
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { presented = false }.keyboardShortcut(.cancelAction)
                Button(L10n.text("app.save", defaultValue: "Save")) { if save(name, renameID) { presented = false } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100)
            }
        }.padding(24).frame(width: 340).instrumentForm()
    }
}

private struct PasteAdjustmentsSheet: View {
    @Bindable var model: AppModel
    let source: EditRecipe
    let sourceName: String
    let sourcePhoto: Photo?
    let targets: [Photo]
    let action: AdjustmentAction
    let presetID: String?
    private var saving: Bool { action == .save || action == .update }
    @Binding var options: RecipePasteOptions
    @Binding var presented: Bool
    @State private var allSelected = true
    @State private var name = ""
    @State private var amount = 100.0
    private var ids: Set<String> {
        let current = Set([model.activeID].compactMap { $0 })
        if action == .sync { return model.selection.subtracting(current) }
        if action == .previous { return current }
        return allSelected ? model.selection : current
    }
    private var allowsRAWDetails: Bool {
        !source.isRaster && (saving || targets.contains { ids.contains($0.id) && $0.isRAW })
    }
    private var allowsWhiteBalance: Bool {
        saving || targets.contains { ids.contains($0.id) && $0.supportsEditing && source.isRaster == !$0.isRAW }
    }
    private var effectiveOptions: RecipePasteOptions {
        var value = options
        if !allowsRAWDetails { value.details = false }
        if !allowsWhiteBalance { value.whiteBalance = false }
        return value
    }
    private var destinationPhotos: [Photo] { targets.filter { ids.contains($0.id) } }
    private var transferPreview: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                SilkText(L10n.text("app.source", defaultValue: "Source")).foregroundStyle(Theme.textSecondary)
                if let sourcePhoto { AdjustmentPhotoPreview(model: model, photo: sourcePhoto) }
                else { Text(sourceName).font(.caption11).frame(width: 94, alignment: .leading) }
            }
            Seam(axis: .vertical).frame(height: 90)
            VStack(alignment: .leading, spacing: 5) {
                SilkText(L10n.text("app.targetPhotos", defaultValue: "Target · \(ids.count) photos")).foregroundStyle(Theme.textSecondary)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(destinationPhotos) { photo in AdjustmentPhotoPreview(model: model, photo: photo) }
                    }
                }.frame(height: 80)
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if saving { Text(L10n.text("app.source_2227", defaultValue: "Source: \(action == .update ? sourcePhoto?.displayName ?? L10n.text("app.currentPhoto", defaultValue: "Current Photo") : sourceName)")).foregroundStyle(Theme.textSecondary) }
                    else { transferPreview }
                    if saving {
                        if action == .save { TextField(L10n.text("app.presetName", defaultValue: "Preset Name"), text: $name) }
                        else { Text(L10n.text("app.updateSelectedParameterGroupsInNameGroupAndFavorite", defaultValue: "Update selected parameter groups in “\(sourceName)”. Name, group, and favorite status are preserved; undo available.")).font(.caption11).foregroundStyle(Theme.textSecondary) }
                    } else {
                        if action != .sync && action != .previous && model.selection.count > 1 { Toggle(L10n.text("app.applyToAllSelectedPhotos", defaultValue: "Apply to All Selected Photos"), isOn: $allSelected) }
                        Text(L10n.text("app.applyThisTime", defaultValue: "Apply this time: ") + (effectiveOptions.hasSelection ? effectiveOptions.summary : L10n.text("app.selectParameterScope", defaultValue: "Select Parameter Scope")))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if action == .preset {
                        AdjustmentRow(label: L10n.text("app.presetAmount", defaultValue: "Preset Amount"), value: amount, range: 0...200, reset: 100, unit: "%",
                                      change: { value, _ in amount = value }, commit: {})
                    }
                    if let imported = options.importedXMP {
                        Text(L10n.text("app.xmpPresetsApplyOnlyDeclaredSupportedFieldsOtherSettings", defaultValue: "XMP presets apply only declared, supported fields; other settings are preserved. Conversion approximates Lightroom."))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(imported.warnings, id: \.self) { warning in
                            Text(warning).font(.caption11).foregroundStyle(Theme.warning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if options.importedXMP?.contains(.tone) ?? true { Toggle(L10n.text("app.exposureToneTextureDehazeVignetteAndGrain", defaultValue: "Exposure, tone, texture, dehaze, vignette, and grain"), isOn: $options.tone) }
                    if options.importedXMP?.contains(.curves) ?? true { Toggle(L10n.text("app.luminanceAndRGBCurves", defaultValue: "Luminance and RGB curves"), isOn: $options.curves) }
                    if options.importedXMP == nil { Toggle(L10n.text("app.zoneLighting", defaultValue: "Zone Lighting"), isOn: $options.zones) }
                    if options.importedXMP?.contains(.whiteBalance) ?? true {
                        Toggle(L10n.text("app.whiteBalance", defaultValue: "White Balance"), isOn: Binding(get: { allowsWhiteBalance && options.whiteBalance }, set: { options.whiteBalance = $0 })).disabled(!allowsWhiteBalance)
                    }
                    if options.importedXMP?.contains(.color) ?? true { Toggle(options.importedXMP == nil ? L10n.text("app.saturationBlackAndWhiteHSLPointColorAndGrading", defaultValue: "Saturation, black and white, HSL, Point Color, and grading") : L10n.text("app.saturationBlackAndWhiteHSLAndGrading", defaultValue: "Saturation, black and white, HSL, and grading"), isOn: $options.color) }
                    if options.importedXMP?.contains(.generalDetails) ?? true { Toggle(L10n.text("app.generalDetailNoiseReductionAndSharpening", defaultValue: "General Detail (Noise Reduction and Sharpening)"), isOn: $options.generalDetails) }
                    if options.importedXMP == nil {
                        Toggle(L10n.text("app.rawDecodingDetailAndLensCorrection", defaultValue: "RAW Decoding Detail and Lens Correction"), isOn: Binding(get: { allowsRAWDetails && options.details }, set: { options.details = $0 })).disabled(!allowsRAWDetails)
                        Toggle(L10n.text("app.cropRotateAndFlip", defaultValue: "Crop, Rotate, and Flip"), isOn: $options.geometry)
                    }
                    if action == .preset {
                        Text(L10n.text("app.0KeepsCurrentSettings100UsesThePresetAnd", defaultValue: "0% keeps current settings, 100% uses the preset, and 200% continues equally beyond it. Point Color amounts scale between empty and sampled lists; different nonempty lists switch at 50%, while matching samples blend by identity. Values are clamped to control ranges. Integer values such as grain seeds are preserved. Preset masks are added only when the photo lacks the same mask, with their effect scaled by Amount."))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L10n.text("app.applySelectedItemsOnlyPreservingTargetMasksAsShot", defaultValue: "Apply selected items only, preserving target masks. As Shot white balance uses each photo's baseline; crops copy relative positions."))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !saving {
                        Text(L10n.text("app.targetWhiteBalanceIsPreservedBetweenRAWAndJPEG", defaultValue: "Target white balance is preserved between RAW and JPEG/TIFF/PNG. Raster formats skip RAW-specific detail settings."))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Text(L10n.text("app.unsupportedOrUnavailablePhotosAreSkippedSeeTaskResults", defaultValue: "Unsupported or unavailable photos are skipped; see task results for details. Applied adjustments can be undone as one batch.")).font(.caption11).foregroundStyle(Theme.textSecondary)
                    }
                }
            }.frame(maxHeight: 520)
            Seam()
            HStack {
                Spacer()
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { presented = false }.keyboardShortcut(.cancelAction)
                Button(saving ? (action == .save ? L10n.text("app.save", defaultValue: "Save") : L10n.text("app.update", defaultValue: "Update")) : L10n.text("app.apply", defaultValue: "Apply")) {
                    let success = action == .save ? model.savePreset(name: name, source: source, options: effectiveOptions)
                        : action == .update ? presetID.map { model.updatePreset(id: $0, source: source, options: effectiveOptions) } ?? false
                        : model.applyAdjustments(source: source, options: effectiveOptions, ids: ids,
                            title: action == .preset ? L10n.text("app.applyPreset_2246", defaultValue: "Apply Preset: \(sourceName)") : action.title,
                            amount: action == .preset ? amount / 100 : nil)
                    if success {
                        if action == .paste || action == .sync || action == .previous { model.confirmAdjustmentOptions(options) }
                        presented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!effectiveOptions.hasSelection || model.busy || (action == .save ? name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100 : action == .update ? presetID == nil : ids.isEmpty))
            }
        }
        .padding(24)
        .frame(width: saving ? 390 : 560)
        .instrumentForm()
        .onAppear { amount = 100 }
    }
}

private struct AdjustmentPhotoPreview: View {
    @Bindable var model: AppModel
    let photo: Photo
    @State private var image: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                else { Image(systemName: "photo").foregroundStyle(Theme.textSecondary) }
            }.frame(width: 94, height: 56).background(PhotoMat.dark.color)
            Text(photo.displayName).font(.caption11).lineLimit(1).frame(width: 94, alignment: .leading)
        }.help(photo.displayName).accessibilityElement(children: .ignore).accessibilityLabel(photo.displayName)
            .task(id: ThumbnailService.key(photo: photo, edge: 160)) {
                guard let root = model.roots.first(where: { $0.id == photo.rootID }) else { image = nil; return }
                image = try? await model.thumbnails.image(photo: photo, root: root, edge: 160)
            }
    }
}

/// Remember user scrolling, not the transient zero geometry when SwiftUI mounts a panel.
struct RememberedPanelScroll<Content: View>: View {
    @Binding var offset: Double
    @State private var position = ScrollPosition()
    @State private var visible = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView { content() }
            .scrollPosition($position)
            .onAppear {
                visible = true
                position.scrollTo(y: max(0, offset))
            }
            .onDisappear { visible = false }
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(max(0, min(geometry.contentOffset.y + geometry.contentInsets.top,
                                  max(0, geometry.contentSize.height - geometry.containerSize.height))))
            } action: { _, value in
                if visible && position.isPositionedByUser { offset = value }
            }
    }
}


private struct NewCatalogSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = L10n.text("app.untitledCatalog", defaultValue: "Untitled Catalog")
    @State private var directory: URL?
    @State private var lease: AccessLease?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.catalogRestoreSource == nil ? L10n.text("app.newCatalog_2248", defaultValue: "New Catalog") : L10n.text("app.restoreAsNewCatalog", defaultValue: "Restore as New Catalog")).font(.headline)
            TextField(L10n.text("app.catalogName", defaultValue: "Catalog Name"), text: $name).textFieldStyle(.instrument)
            HStack {
                Text(L10n.text("app.phoscatCatalogFile", defaultValue: ".phoscat catalog file")).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(L10n.text("app.chooseSaveLocation", defaultValue: "Choose Save Location…")) {
                    if let url = model.chooseDirectory(title: L10n.text("app.chooseWhereToSaveTheCatalogFile", defaultValue: "Choose Where to Save the Catalog File")) { lease = AccessLease(url: url); directory = url }
                }
            }
            Text(directory?.path ?? L10n.text("app.aSeparateCatalogFileWillBeCreatedInsideThe", defaultValue: "A separate catalog file will be created inside the selected folder."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            Text(L10n.text("app.theCatalogStoresPhotoLocationsRatingsAndAdjustmentsOriginals", defaultValue: "The catalog stores photo locations, ratings, and adjustments. Originals remain in their photo folders."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            if let error { Text(error).foregroundStyle(Theme.warning).font(.caption11) }
            HStack {
                Spacer()
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.catalogRestoreSource == nil ? L10n.text("app.create", defaultValue: "Create") : L10n.text("app.restore", defaultValue: "Restore")) {
                    guard let directory else { return }
                    do { try model.createCatalog(name: name, directory: directory) }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
                    .disabled(directory == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440).instrumentForm()
        .onAppear {
            do {
                let folder = try model.catalog?.directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OhMyLRC/Catalogs")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                directory = folder
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Brief confirmation of a rating or flag key over the centre view; VoiceOver hears the same text as an announcement.
private struct WorkspaceNoticeBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.body13).monospacedDigit().foregroundStyle(Theme.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.controlBorder.opacity(0.6), lineWidth: 1))
            .shadow(color: Theme.keyAmbientShadow, radius: 4, y: 1)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}
