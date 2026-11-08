import SwiftUI
import AppKit
import Combine
import Observation

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var keyboard: WorkspaceKeyboard?
    private var waitingForMergeTermination = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.changingCatalogExtension { return .terminateCancel }
        if !model.commitRecipe() { return .terminateCancel }
        if waitingForMergeTermination { return .terminateLater }
        if let session = model.mergeSession,session.working {
            waitingForMergeTermination = true
            Task { @MainActor in
                await session.cancelAndWait()
                waitingForMergeTermination = false
                sender.reply(toApplicationShouldTerminate:session.error == nil)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}

@main
struct PhosdeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("chromeTheme") private var chromeTheme = ChromeTheme.graphite
    var body: some Scene {
        Window("\(model.catalogName) — Phosdeck", id: "main") {
            WorkspaceView(model: model)
                .onOpenURL { model.openCatalog(url: $0) }
                .onAppear { delegate.model = model; delegate.keyboard = WorkspaceKeyboard(model: model); model.openStartupCatalogIfNeeded() }
        }.defaultSize(width: 1380, height: 850)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.presented)
        .commands { WorkspaceCommands(model: model) }
        Settings {
            SettingsSheet(model: model).preferredColorScheme(chromeTheme.colorScheme)
        }.windowResizability(.contentSize)
    }
}

/// Tracks the actual responder so text-field undo remains local, including in sheets and Settings.
@MainActor
final class CommandResponder: ObservableObject {
    struct State: Equatable {
        var workspace = false
        var textEditing = false
        var canUndo = false
        var canRedo = false
        var undoTitle = L10n.text("app.undo_244", defaultValue: "Undo")
        var redoTitle = L10n.text("app.redo_245", defaultValue: "Redo")
    }
    @Published private(set) var state = State()
    private weak var model: AppModel?
    private var observations = Set<AnyCancellable>()
    init(model: AppModel) {
        self.model = model
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didUpdateNotification,
                     NSMenu.didBeginTrackingNotification, NSText.didChangeNotification,
                     Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refresh()
            }.store(in: &observations)
        }
        observeModel()
    }
    private func observeModel() {
        guard let model else { return }
        withObservationTracking {
            _ = model.workspaceAvailable
            _ = model.smartMaskSession
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModel() }
        }
    }
    static func manager(model: AppModel, window: NSWindow?) -> UndoManager? {
        guard let window else { return nil }
        if let editor = window.firstResponder as? NSTextView { return editor.undoManager }
        guard WorkspaceKeyboard.isWorkspaceWindow(window), window.attachedSheet == nil, model.workspaceAvailable else { return nil }
        guard !model.editMode || !model.editorUsesPreviousPhoto else { return nil }
        return model.undo
    }
    func refresh() {
        guard let model else { return }
        let window = NSApp.keyWindow
        let manager = Self.manager(model: model, window: window)
        let smart = manager === model.undo ? model.smartMaskSession : nil
        let next = State(workspace: window.map { WorkspaceKeyboard.isWorkspaceWindow($0) && $0.attachedSheet == nil } ?? false,
                         textEditing: window?.firstResponder is NSTextView,
                         canUndo: smart.map { !$0.busy && !$0.promptHistory.isEmpty } ?? (manager?.canUndo == true), canRedo: smart == nil && manager?.canRedo == true,
                         undoTitle: smart != nil ? L10n.text("app.undoPointBox", defaultValue: "Undo Point / Box") : manager?.canUndo == true && manager?.undoActionName.isEmpty == false ? L10n.text("app.undo_247", defaultValue: "Undo \(manager!.undoActionName)") : L10n.text("app.undo_244", defaultValue: "Undo"),
                         redoTitle: manager?.canRedo == true && manager?.redoActionName.isEmpty == false ? L10n.text("app.redo_248", defaultValue: "Redo \(manager!.redoActionName)") : L10n.text("app.redo_245", defaultValue: "Redo"))
        if state != next { state = next }
    }
    func undo() {
        guard let model else { return }
        let manager = Self.manager(model: model, window: NSApp.keyWindow)
        if manager === model.undo, model.smartMaskSession != nil { model.undoSmartPrompt() } else { manager?.undo() }
        refresh()
    }
    func redo() { guard let model else { return }; let manager = Self.manager(model: model, window: NSApp.keyWindow); if manager !== model.undo || model.smartMaskSession == nil { manager?.redo() }; refresh() }
}

struct WorkspaceCommands: Commands {
    @Bindable var model: AppModel
    @StateObject private var responder: CommandResponder
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showLeftPanel") private var left = true
    @AppStorage("showRightPanel") private var right = true
    @AppStorage("showFilmstrip") private var film = true
    @AppStorage("chromeTheme") private var chromeTheme = ChromeTheme.graphite
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    init(model: AppModel) { self.model = model; _responder = StateObject(wrappedValue: CommandResponder(model: model)) }
    private var workspace: Bool { responder.state.workspace && model.workspaceAvailable }
    private var photoSelected: Bool { workspace && !model.selection.isEmpty }
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.text("app.settings", defaultValue: "Settings…")) { openSettings() }.keyboardShortcut(",").disabled(model.presentingSheet)
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("app.newCatalog", defaultValue: "New Catalog…")) { openWindow(id: "main"); model.createCatalog() }.keyboardShortcut("n").disabled(!model.canSwitchCatalog)
            Button(L10n.text("app.openCatalog", defaultValue: "Open Catalog…")) { openWindow(id: "main"); model.openCatalog() }.keyboardShortcut("o").disabled(!model.canSwitchCatalog)
            Menu(L10n.text("app.openRecentCatalog", defaultValue: "Open Recent Catalog")) {
                ForEach(model.recentCatalogs) { recent in
                    Button(recent.filename) { openWindow(id: "main"); model.openRecent(recent) }.help(recent.path)
                }
            }.disabled(!model.canSwitchCatalog || model.recentCatalogs.isEmpty)
            Button(L10n.text("app.showCatalogFileInFinder", defaultValue: "Show Catalog File in Finder")) {
                if let catalog = model.catalog { NSWorkspace.shared.activateFileViewerSelecting([catalog.fileURL]) }
            }.disabled(model.catalog == nil || model.presentingSheet)
            Divider()
            Button(L10n.text("app.importPhotos", defaultValue: "Import Photos…"), action: model.importReference).keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!workspace || !model.canImportPhotos)
            Button(L10n.text("folderReview.menu", defaultValue: "Review Folder Changes…"), action: model.reviewCurrentFolder)
                .disabled(!workspace || model.currentFolderReviewScope == nil)
            Button(L10n.text("app.importLightroomXMPPresets", defaultValue: "Import Lightroom XMP Presets…"), action: model.requestXMPPresetImport)
                .disabled(!workspace || model.catalog == nil)
            Button(L10n.text("app.exportSelectedPhotos", defaultValue: "Export Selected Photos…")) { model.requestExport() }.keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!workspace || !model.canExportPhotos)
            Menu(L10n.text("app.exportWithPreset", defaultValue: "Export with Preset")) {
                ForEach(ExportPreset.builtIns) { preset in Button(preset.name + "…") { model.requestExport(preset: preset) } }
                if let preferences = try? ExportPreferences.load(), !preferences.presets.isEmpty {
                    Divider()
                    ForEach(preferences.presets) { preset in Button(preset.name + "…") { model.requestExport(preset: preset) } }
                }
            }.disabled(!workspace || !model.canExportPhotos)
            Divider()
            Button(L10n.text("app.outputRecordsAndRetry", defaultValue: "Output Records and Retry…")) { model.openExportRecords() }.disabled(!workspace || model.catalog == nil)
            Button(L10n.text("app.copyImportLogsAndRecovery", defaultValue: "Copy Import Logs and Recovery…")) { model.showCopyRecovery = true }.disabled(!workspace || model.catalog == nil)
            Divider()
            Menu(L10n.text("app.catalogMaintenance", defaultValue: "Catalog Maintenance")) {
                Button(L10n.text("app.backUpCatalog", defaultValue: "Back Up Catalog…")) { model.backup() }.disabled(model.catalog == nil)
                Button(L10n.text("app.restoreFromBackup", defaultValue: "Restore from Backup…"), action: model.restoreBackup)
                Button(L10n.text("app.exportJSONManagementManifest", defaultValue: "Export JSON Management Manifest…")) { model.backup(manifest: true) }.disabled(model.catalog == nil)
            }.disabled(!model.canSwitchCatalog)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(responder.state.undoTitle, action: responder.undo).keyboardShortcut("z").disabled(!responder.state.canUndo)
            Button(responder.state.redoTitle, action: responder.redo).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!responder.state.canRedo)
        }
        CommandMenu(L10n.text("app.photo", defaultValue: "Photo")) {
            Menu(L10n.text("app.rating", defaultValue: "Rating")) {
                ForEach(0...5, id: \.self) { rating in
                    let stars = L10n.text("app.stars_1722", defaultValue: "\(rating) Stars")
                    let title = rating == 0 ? L10n.text("app.unrated0", defaultValue: "Unrated (0)") : L10n.text("app.titleWithShortcut", defaultValue: "\(stars) (\(String(rating)))")
                    Toggle(title, isOn: Binding(
                        get: { model.selectedRating == rating },
                        set: { if $0 { model.organize(rating: rating) } }))
                }
            }.disabled(!photoSelected)
            Menu(L10n.text("app.flag", defaultValue: "Flag")) {
                flag(L10n.text("app.pickP", defaultValue: "Pick (P)"), value: 1); flag(L10n.text("app.rejectX", defaultValue: "Reject (X)"), value: -1); flag(L10n.text("app.unflaggedU", defaultValue: "Unflagged (U)"), value: 0)
                Divider()
                Button(L10n.text("app.togglePick", defaultValue: "Toggle Pick (`)")) { model.toggleFlag() }
            }.disabled(!photoSelected)
            Menu(L10n.text("app.colorLabel", defaultValue: "Color Label")) {
                ForEach(PhotoColorLabel.allCases) { label in
                    Toggle(label.titleWithShortcut, isOn: Binding(
                        get: { model.selectedColorLabel == label.rawValue },
                        set: { _ in model.toggleColorLabel(label.rawValue) }))
                }
            }.disabled(!photoSelected)
            Toggle(L10n.text("app.autoAdvance", defaultValue: "Auto Advance"), isOn: $model.autoAdvance).disabled(!workspace)
            Button(L10n.text("app.toggleQuickCollectionB", defaultValue: "Toggle Quick Collection (B)"), action: model.toggleQuickCollection).disabled(!workspace || model.quickCollectIDs.isEmpty)
            Divider()
            Button(L10n.text("app.locateCurrentOriginal", defaultValue: "Locate Current Original…"), action: model.locateOriginal).disabled(!model.canLocateOriginal)
            Button(L10n.text("app.createVirtualCopy", defaultValue: "Create Virtual Copy"), action: model.createVirtualCopies).disabled(!photoSelected)
            Menu(L10n.text("app.stacking", defaultValue: "Stacking")) { StackMenu(model: model) }.disabled(!workspace || model.catalog == nil)
            Menu(L10n.text("merge.title", defaultValue:"Merge Photos")) { PhotoMergeMenu(model:model) }.disabled(!model.canMergePhotos)
            Menu(L10n.text("app.rawJPEGPairing", defaultValue: "RAW/JPEG Pairing")) { PairMenu(model: model) }.disabled(!workspace || model.catalog == nil)
            Divider()
            Menu(L10n.text("app.transferAdjustments", defaultValue: "Transfer Adjustments")) {
                Button(L10n.text("app.copyCurrentPhotoAdjustments", defaultValue: "Copy Current Photo Adjustments"), action: model.copyAdjustments)
                    .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!model.canEdit)
                Button(L10n.text("app.pasteAdjustments_280", defaultValue: "Paste Adjustments…")) { model.requestAdjustments(.paste) }
                    .keyboardShortcut("v", modifiers: [.command, .shift]).disabled(model.copiedRecipe == nil || !model.canEdit)
                Button(L10n.text("app.syncToOtherSelectedPhotos", defaultValue: "Sync to Other Selected Photos…")) { model.requestAdjustments(.sync) }
                    .disabled(!model.canEdit || model.selection.subtracting(Set([model.activeID].compactMap { $0 })).isEmpty)
                Button(L10n.text("app.usePreviousAdjustments_282", defaultValue: "Use Previous Adjustments…")) { model.requestAdjustments(.previous) }.disabled(!model.canUsePreviousAdjustments)
            }.disabled(!workspace || responder.state.textEditing)
            Divider()
            Menu(L10n.text("app.developTools", defaultValue: "Develop Tools")) {
                developTool(L10n.text("app.basicAdjustments", defaultValue: "Basic Adjustments"), .adjust)
                developTool(L10n.text("app.cropAndGeometryR", defaultValue: "Crop and Geometry (R)"), .crop)
                developTool(L10n.text("app.spotRemovalQ", defaultValue: "Spot Removal (Q)"), .spot)
                developTool(L10n.text("app.masksW", defaultValue: "Masks (⇧W)"), .mask)
                Divider()
                Button(L10n.text("app.finishCurrentToolEsc", defaultValue: "Finish Current Tool (Esc)")) { model.selectDevelopTool(.adjust) }.disabled(model.developTool == .adjust)
            }.disabled(!workspace || !model.editMode)
        }
        CommandGroup(before: .toolbar) {
            Button(L10n.text("app.goBack", defaultValue: "Go Back")) { model.navigateBrowse(-1) }
                .keyboardShortcut("[").disabled(!workspace || !model.canBrowseBack || responder.state.textEditing)
            Button(L10n.text("app.goForward", defaultValue: "Go Forward")) { model.navigateBrowse(1) }
                .keyboardShortcut("]").disabled(!workspace || !model.canBrowseForward || responder.state.textEditing)
            Divider()
            mode(L10n.text("app.gridG", defaultValue: "Grid (G)"), .grid)
            mode(L10n.text("app.loupeE", defaultValue: "Loupe (E)"), .single)
            mode(L10n.text("app.developD", defaultValue: "Develop (D)"), .develop)
            mode(L10n.text("app.comparePhotosC", defaultValue: "Compare Photos (C)"), .compare)
            mode(L10n.text("app.surveyPhotosN", defaultValue: "Survey Photos (N)"), .survey)
            Divider()
            Toggle(L10n.text("app.developReferenceR", defaultValue: "Develop Reference (⇧R)"), isOn: Binding(get: { model.developReference != nil }, set: { _ in model.toggleDevelopReference() }))
                .keyboardShortcut("r", modifiers: [.shift])
                .disabled(!workspace || !model.canShowDevelopReference || responder.state.textEditing)
            Button(L10n.text("app.useCurrentPhotoAsReference", defaultValue: "Use Current Photo as Reference"), action: model.pinActiveAsDevelopReference)
                .disabled(!workspace || !model.editMode || !model.canEdit || responder.state.textEditing)
            Divider()
            Menu(L10n.text("app.beforeAndAfter", defaultValue: "Before and After")) {
                Toggle(L10n.text("app.showBeforeBackslash", defaultValue: "Show Before (Backslash)"), isOn: Binding(get: { model.before }, set: { _ in model.toggleBefore() }))
                Toggle(L10n.text("app.beforeAfterSideBySideY", defaultValue: "Before / After Side by Side (Y)"), isOn: Binding(get: { model.beforeAfter == .sideBySide }, set: { _ in model.toggleBeforeAfter(.sideBySide) }))
                Toggle(L10n.text("app.beforeAfterSplitY", defaultValue: "Before / After Split (⇧Y)"), isOn: Binding(get: { model.beforeAfter == .split }, set: { _ in model.toggleBeforeAfter(.split) }))
            }.disabled(!workspace || !model.canShowBeforeAfter)
            Toggle(L10n.text("app.showLibraryFilterBarBackslash", defaultValue: "Show Library Filter Bar (Backslash)"), isOn: $model.libraryFiltersOpen).disabled(!workspace || model.editMode)
            Button(model.filtersEnabled ? L10n.text("app.pauseFilters", defaultValue: "Pause Filters") : L10n.text("app.resumeFilters", defaultValue: "Resume Filters")) { model.toggleFilters() }
                .keyboardShortcut("l").disabled(!workspace || responder.state.textEditing)
            Button(L10n.text("app.actualPixels11", defaultValue: "Actual Pixels 1:1")) { model.selectZoom(1) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(!workspace || model.active == nil || (!model.singleView && !model.editMode) || model.cropMode || model.comparison != nil || model.survey != nil || responder.state.textEditing)
            Toggle(L10n.text("app.showClippingJ", defaultValue: "Show Clipping (J)"), isOn: $model.showClipping).disabled(!workspace || model.active == nil || (!model.singleView && !model.editMode) || model.comparison != nil)
            Divider()
            Toggle(L10n.text("app.leftPanel", defaultValue: "Left Panel"), isOn: $left).keyboardShortcut("1", modifiers: [.command, .option]).disabled(!workspace)
            Toggle(L10n.text("app.rightPanel", defaultValue: "Right Panel"), isOn: $right).keyboardShortcut("2", modifiers: [.command, .option]).disabled(!workspace)
            Toggle(L10n.text("app.filmstrip", defaultValue: "Filmstrip"), isOn: $film).keyboardShortcut("3", modifiers: [.command, .option]).disabled(!workspace)
            Divider()
            Picker(L10n.text("app.interfaceTheme", defaultValue: "Interface Theme"), selection: $chromeTheme) { ForEach(ChromeTheme.allCases) { Text($0.title).tag($0) } }
            Picker(L10n.text("app.viewingMat", defaultValue: "Viewing Mat"), selection: $mat) { ForEach(PhotoMat.allCases) { Text($0.title).tag($0) } }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button(L10n.text("camera.title", defaultValue: "Camera Compatibility…")) { openWindow(id: "main"); model.showCameraDiagnostics = true }.disabled(model.presentingSheet)
            Button(L10n.text("app.keyboardShortcuts", defaultValue: "Keyboard Shortcuts…")) { model.settingsPane = .shortcuts; openSettings() }.disabled(model.presentingSheet)
        }
    }
    private func flag(_ title: String, value: Int) -> some View {
        Toggle(title, isOn: Binding(get: { model.selectedFlag == value },
                                   set: { model.organize(flag: $0 ? value : 0) }))
    }
    private func mode(_ title: String, _ value: WorkspaceMode) -> some View {
        Toggle(title, isOn: Binding(get: { model.workspaceMode == value }, set: { if $0 { model.selectWorkspace(value) } }))
            .disabled(!workspace || (value != .grid && model.active == nil) || (value == .compare && model.visibleCount < 2) || (value == .survey && model.selection.count < 2 && model.survey == nil))
    }
    private func developTool(_ title: String, _ value: DevelopTool) -> some View {
        Toggle(title, isOn: Binding(get: { model.developTool == value }, set: { if $0 { model.selectDevelopTool(value) } }))
            .disabled(value != .adjust && !model.canEdit)
    }
}
