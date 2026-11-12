import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable {
    case appearance = "外观", storage = "缓存与存储", shortcuts = "快捷键", agent = "Agent"
    var title: String {
        switch self {
        case .appearance: L10n.text("app.appearance", defaultValue: "Appearance")
        case .storage: L10n.text("app.cacheAndStorage", defaultValue: "Cache and Storage")
        case .shortcuts: L10n.text("app.shortcuts", defaultValue: "Shortcuts")
        case .agent: L10n.text("agent.settings", defaultValue: "Agent")
        }
    }

}

/// Used by the macOS Settings scene; it does not make the workspace modal.
struct SettingsSheet: View {
    @Bindable var model: AppModel
    @State private var usage: StorageUsage?
    @State private var measuring = false
    @State private var feedback: String?
    @State private var failure: String?
    @AppStorage("chromeTheme") private var chromeTheme = ChromeTheme.graphite
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    private var unavailable: Bool { model.busy || model.applyingAdjustments || model.cacheMaintenance || measuring }

    var body: some View {
        VStack(spacing: 0) {
            KeyRow(title: L10n.text("app.settingsCategory", defaultValue: "Settings Category"), options: SettingsPane.allCases.map { KeyOption($0, $0.title) },
                   selection: $model.settingsPane, lampsInside: true, expand: true).padding(20)
            Seam()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.settingsPane {
                    case .appearance: appearance
                    case .storage: storage
                    case .shortcuts: shortcuts
                    case .agent: AgentSettings(service: model.mcp)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Seam()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    if model.settingsPane == .storage {
                        if let failure { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(Theme.error).accessibilityIdentifier("settings-error") }
                        else if let feedback { Label(feedback, systemImage: "checkmark.circle").foregroundStyle(Theme.textSecondary).accessibilityIdentifier("settings-feedback") }
                    }
                    Text(model.settingsPane == .shortcuts ? L10n.text("app.singleKeyShortcutsDoNotTriggerWorkspaceActionsWhile", defaultValue: "Single-key shortcuts do not trigger workspace actions while typing.") : L10n.text("app.preferencesTakeEffectImmediatelyAndAreSavedOnThis", defaultValue: "Preferences are saved on this Mac. Language changes take effect after reopening the app."))
                        .foregroundStyle(Theme.textSecondary)
                }.font(.caption11).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(L10n.text("app.wClose", defaultValue: "⌘W Close")).font(.caption11).foregroundStyle(Theme.textSecondary)
            }.padding(16)
        }.frame(width: 660, height: 500).instrumentForm()
        .task(id: model.catalog?.fileURL) { await refreshStorage() }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 20) {
            LanguagePackSettings()
            Seam()
            SubgroupLabel(L10n.text("app.interfaceTheme", defaultValue: "Interface Theme"))
            KeyRow(title: L10n.text("app.interfaceTheme", defaultValue: "Interface Theme"), options: ChromeTheme.allCases.map { KeyOption($0, $0.title) },
                   selection: $chromeTheme, lampsInside: true, expand: true)
            Text(L10n.text("app.followMacOSAppearanceOrUseIvoryOrGraphite", defaultValue: "Follow macOS appearance, or use Ivory or Graphite.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            SubgroupLabel(L10n.text("app.viewingMat", defaultValue: "Viewing Mat"))
            DetentSelector(title: L10n.text("app.viewingMat", defaultValue: "Viewing Mat"), options: PhotoMat.allCases.map { KeyOption($0, $0.title) }, selection: $mat)
            Text(L10n.text("app.thePhotoSurroundUsesNeutralColorsConsistentlyInThe", defaultValue: "The photo surround uses neutral colors consistently in the library, compare view, and filmstrip. Theme and viewing mat do not alter photo pixels or exports."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var storage: some View {
        VStack(alignment: .leading, spacing: 16) {
            SubgroupLabel(L10n.text("app.localCacheQuota", defaultValue: "Local Cache Quota"))
            DetentSlider(title: L10n.text("app.diskThumbnailQuota", defaultValue: "Disk Thumbnail Quota"), options: [1, 5, 10].map { KeyOption($0, "\($0) GiB") },
                         selection: Binding(get: { model.cacheGigabytes }, set: updateQuota), reset: 5)
                .disabled(unavailable).accessibilityIdentifier("settings-cache-quota")
            Text(L10n.text("app.eachCatalogUsesThisQuotaSeparatelyRebuildableThumbnailsAre", defaultValue: "Each catalog uses this quota separately. Rebuildable thumbnails are evicted when it is exceeded; originals and outputs are preserved."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            SubgroupLabel(L10n.text("app.currentCatalog", defaultValue: "Current Catalog"))
            if let catalog = model.catalog {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.catalogName).font(.section)
                        Text(catalog.fileURL.path).font(.caption11).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer()
                    Button(L10n.text("app.showInFinder_1803", defaultValue: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([catalog.fileURL]) }.buttonStyle(.key)
                }
                HStack {
                    Text(L10n.text("app.thumbnailCache", defaultValue: "Thumbnail Cache"))
                    Spacer()
                    Text(measuring ? L10n.text("app.measuring", defaultValue: "Measuring…") : formatted(model.cacheBytes)).font(.value)
                    Button(model.cacheMaintenance ? L10n.text("app.processing_1806", defaultValue: "Processing…") : L10n.text("app.clearCache", defaultValue: "Clear Cache"), action: clearCache)
                        .buttonStyle(.key).disabled(unavailable).accessibilityIdentifier("settings-clear-cache")
                }
                if let usage {
                    storageRow(L10n.text("app.catalogDatabase", defaultValue: "Catalog Database"), bytes: usage.catalog)
                    storageRow(L10n.text("app.taskTemporaryFiles", defaultValue: "Task Temporary Files"), bytes: usage.staging)
                    storageRow(L10n.text("app.previousDestinationRecoveryFiles", defaultValue: "Previous Destination Recovery Files"), bytes: usage.recovery)
                    if usage.inaccessible > 0 {
                        Text(L10n.text("app.additionalLocationsAreUnreadableAndExcludedFromTheTotal", defaultValue: "\(usage.inaccessible) additional locations are unreadable and excluded from the total.")).font(.caption11).foregroundStyle(Theme.warning)
                    }
                }
                HStack {
                    Text(L10n.text("app.clearsOnlyThisCatalogSThumbnailsBrowsingRegeneratesThem", defaultValue: "Clears only this catalog's thumbnails; browsing regenerates them. Task temporary files and recovery files are not cache."))
                        .font(.caption11).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button(L10n.text("app.refreshUsage", defaultValue: "Refresh Usage")) { Task { await refreshStorage() } }.buttonStyle(.key).disabled(unavailable)
                }
            } else {
                Text(L10n.text("app.noCatalogOpen_1814", defaultValue: "No Catalog Open")).font(.section)
                Text(L10n.text("app.theCacheQuotaIsSavedOnThisMacOpen", defaultValue: "The cache quota is saved on this Mac. Open or create a catalog to view usage and clear thumbnails here."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            if model.busy || model.applyingAdjustments { Text(L10n.text("app.adjustOrClearTheCacheAfterTheCurrentTask", defaultValue: "Adjust or clear the cache after the current task finishes.")).font(.caption11).foregroundStyle(Theme.warning) }
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            shortcutGroup(L10n.text("app.filesAndEditing", defaultValue: "Files and Editing"), rows: [(L10n.text("app.importPhotos_1818", defaultValue: "Import Photos"), "⇧⌘I"), (L10n.text("app.exportSelectedPhotos_1819", defaultValue: "Export Selected Photos"), "⇧⌘E"), (L10n.text("app.copyPasteAdjustments", defaultValue: "Copy / Paste Adjustments"), "⇧⌘C / ⇧⌘V"), (L10n.text("app.undoRedo", defaultValue: "Undo / Redo"), "⌘Z / ⇧⌘Z"), (L10n.text("app.openSettings", defaultValue: "Open Settings"), "⌘,")])
            shortcutGroup(L10n.text("app.viewingPhotos", defaultValue: "Viewing Photos"), rows: [(L10n.text("app.gridLoupeDevelopCompareSurvey", defaultValue: "Grid / Loupe / Develop / Compare / Survey"), "G / E / D / C / N"), (L10n.text("app.backForwardInBrowseHistory", defaultValue: "Back / Forward in Browse History"), "⌘[ / ⌘]"), (L10n.text("app.compareKeepAndContinueSwap", defaultValue: "Compare: Keep and Continue / Swap"), "↑ / ↓"), (L10n.text("app.surveyRemoveCurrentCandidate", defaultValue: "Survey: Remove Current Candidate"), "/"), (L10n.text("app.previousNextPhoto", defaultValue: "Previous / Next Photo"), "← / →"), (L10n.text("app.toggleFitAndSelectedZoom", defaultValue: "Toggle Fit and Selected Zoom"), "Z"), (L10n.text("app.actualPixels11", defaultValue: "Actual Pixels 1:1"), "⌥⌘0"), (L10n.text("app.browseZoomedSectionsHorizontally", defaultValue: "Browse Zoomed Sections / Horizontally"), L10n.text("app.pageUpDownHold", defaultValue: "Page Up, Down / Hold ⇧")), (L10n.text("app.beforeAfterSideBySideSplit", defaultValue: "Before / After Side by Side / Split"), "Y / ⇧Y"), (L10n.text("app.toggleBeforeAfterInDevelop", defaultValue: "Toggle Before / After in Develop"), "\\"), (L10n.text("app.clippingDisplay", defaultValue: "Clipping Display"), "J")])
            shortcutGroup(L10n.text("app.organizingPhotos", defaultValue: "Organizing Photos"), rows: [(L10n.text("app.toggleQuickCollection", defaultValue: "Toggle Quick Collection"), "B"), (L10n.text("app.setRating", defaultValue: "Set Rating"), "0–5"), (L10n.text("app.redYellowGreenBlueLabels", defaultValue: "Red / Yellow / Green / Blue Labels"), "6 / 7 / 8 / 9"), (L10n.text("app.clearMatchingColorLabel", defaultValue: "Clear Matching Color Label"), L10n.text("app.pressItsNumberAgain", defaultValue: "Press its number again")), (L10n.text("app.pickRejectUnflagged", defaultValue: "Pick / Reject / Unflagged"), "P / X / U"), (L10n.text("app.togglePickClearPick", defaultValue: "Toggle Pick / Clear Pick"), "`"), (L10n.text("app.autoAdvanceAfterRatingOrFlagging", defaultValue: "Auto Advance After Rating or Flagging"), L10n.text("app.capsLockAutoAdvanceKey", defaultValue: "Caps Lock / Auto Advance Key")), (L10n.text("app.temporarilyReverseAutoAdvance", defaultValue: "Temporarily Reverse Auto Advance"), L10n.text("app.hold", defaultValue: "Hold ⇧")), (L10n.text("app.pauseResumeFilters", defaultValue: "Pause / Resume Filters"), "⌘L"), (L10n.text("app.showHideLibraryFilterBar", defaultValue: "Show / Hide Library Filter Bar"), "\\"), (L10n.text("app.expandCollapseStackSetCover", defaultValue: "Expand / Collapse Stack / Set Cover"), "S / ⇧S")])
            shortcutGroup(L10n.text("app.developTools", defaultValue: "Develop Tools"), rows: [(L10n.text("app.developReference", defaultValue: "Develop Reference"), "⇧R"), (L10n.text("app.openFinishCropOrSpotRemoval", defaultValue: "Open / Finish Crop or Spot Removal"), "R / Q"), (L10n.text("app.finishCurrentTool", defaultValue: "Finish Current Tool"), "Esc"), (L10n.text("app.cropOrientationAspectLockGuides", defaultValue: "Crop: Orientation / Aspect Lock / Guides"), "X / A / O"), (L10n.text("app.finishCrop", defaultValue: "Finish Crop"), "Return"), (L10n.text("app.openCloseMasks", defaultValue: "Open / Close Masks"), "⇧W"), (L10n.text("app.brushLinearRadialGradient", defaultValue: "Brush / Linear / Radial Gradient"), "K / M / ⇧M"), (L10n.text("app.sampleWhiteBalanceExit", defaultValue: "Sample White Balance / Exit"), "W / Esc"), (L10n.text("app.showMaskSelection", defaultValue: "Show Mask Selection"), "O"), (L10n.text("app.showMaskOrSpotPins", defaultValue: "Show Mask or Spot Pins"), "H"), (L10n.text("app.healingChangeSource", defaultValue: "Healing: Change Source"), "/"), (L10n.text("app.deleteSelectedComponentOrSpot", defaultValue: "Delete Selected Component or Spot"), "Delete"), (L10n.text("app.changeBrushSize", defaultValue: "Change Brush Size"), "[ / ]")])
            shortcutGroup(L10n.text("app.panelsAndInput", defaultValue: "Panels and Input"), rows: [(L10n.text("app.leftPanelRightPanelFilmstrip", defaultValue: "Left Panel / Right Panel / Filmstrip"), "⌥⌘1 / 2 / 3"), (L10n.text("app.previewApplyEndPresetPreview", defaultValue: "Preview / Apply / End Preset Preview"), "↑、↓ / Return / Esc"), (L10n.text("app.fineSliderAdjustment", defaultValue: "Fine Slider Adjustment"), L10n.text("app.holdWhileDragging", defaultValue: "Hold ⇧ while dragging")), (L10n.text("app.commitCancelNumericInput", defaultValue: "Commit / Cancel Numeric Input"), "Return / Esc")])
            Text(L10n.text("app.useForMultiSelectionInGridClickAPhoto", defaultValue: "Use ⌘ / ⇧ for multi-selection in Grid. Click a photo to toggle zoom; drag to pan when zoomed. Drag dividers to resize. The zoom menu offers 6.25%–1600%."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
        }
    }
    private func shortcutGroup(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SubgroupLabel(title)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack { Text(row.0); Spacer(minLength: 16); Text(row.1).font(.value).foregroundStyle(Theme.textSecondary) }
            }
        }
    }
    private func storageRow(_ title: String, bytes: Int64) -> some View {
        HStack { Text(title).foregroundStyle(Theme.textSecondary); Spacer(); Text(formatted(bytes)).font(.value) }
    }
    private func formatted(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    @MainActor private func refreshStorage() async {
        let catalog = model.catalog
        measuring = true; failure = nil; usage = nil
        defer { measuring = false }
        guard let catalog else { return }
        do {
            let bytes = try await model.thumbnails.usage()
            let result = try await StorageInspector().measure(catalog)
            try Task.checkCancellation()
            guard model.catalog === catalog else { return }
            model.cacheBytes = bytes; usage = result
        } catch is CancellationError {} catch { failure = error.localizedDescription }
    }
    private func updateQuota(_ value: Int) {
        Task {
            feedback = nil; failure = nil
            do {
                try await model.updateCacheQuota(value)
                await refreshStorage()
                feedback = L10n.text("app.cacheQuotaSetToGiB", defaultValue: "Cache quota set to \(value) GiB.")
            } catch { failure = error.localizedDescription }
        }
    }
    private func clearCache() {
        Task {
            feedback = nil; failure = nil
            do {
                try await model.clearThumbnailCache()
                await refreshStorage()
                feedback = L10n.text("app.rebuildableCacheClearedForTheCurrentCatalog", defaultValue: "Rebuildable cache cleared for the current catalog.")
            } catch { failure = error.localizedDescription }
        }
    }
}

private struct AgentSettings: View {
    let service: AppMCPService
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: Binding(get: { service.enabled }, set: service.setEnabled)) {
                Text(L10n.text("agent.enable", defaultValue: "Local MCP Server"))
            }.toggleStyle(InstrumentToggleStyle(expand: true)).accessibilityIdentifier("settings-mcp-enable")
            Text(L10n.text("agent.localAccess", defaultValue: "Clients on this Mac can use the current catalog with the connection token."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            HStack {
                Text(status).foregroundStyle(service.status == .failed ? Theme.error : Theme.textSecondary)
                    .accessibilityIdentifier("settings-mcp-status")
                Spacer()
                if service.status == .failed {
                    Button(L10n.text("agent.retry", defaultValue: "Retry"), action: service.retry).buttonStyle(.key)
                }
            }.font(.caption11)
            Seam()
            Toggle(isOn: Binding(get: { service.sharesImages }, set: service.setSharesImages)) {
                Text(L10n.text("agent.shareImages", defaultValue: "Share Photo Previews"))
            }.toggleStyle(InstrumentToggleStyle(expand: true)).disabled(!service.enabled)
                .accessibilityIdentifier("settings-mcp-share-images")
            Text(L10n.text("agent.shareHelp", defaultValue: "Clients using cloud models may send shared previews to their model provider."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            if let endpoint = service.endpoint {
                Seam()
                SubgroupLabel(L10n.text("agent.connection", defaultValue: "Client Connection"))
                Text(endpoint).font(.value).textSelection(.enabled).accessibilityIdentifier("settings-mcp-endpoint")
                HStack(spacing: 8) {
                    Button(L10n.text("agent.copyConfig", defaultValue: "Copy Codex Configuration")) {
                        copy(service.clientConfiguration, feedback: L10n.text("agent.configCopied", defaultValue: "Configuration copied"))
                    }.buttonStyle(.key).accessibilityIdentifier("settings-mcp-copy-config")
                    Button(L10n.text("agent.copyJSONConfig", defaultValue: "Copy JSON Configuration")) {
                        copy(service.jsonClientConfiguration, feedback: L10n.text("agent.configCopied", defaultValue: "Configuration copied"))
                    }.buttonStyle(.key).accessibilityIdentifier("settings-mcp-copy-json-config")
                    Button(L10n.text("agent.copyToken", defaultValue: "Copy Token")) {
                        copy(service.connectionToken, feedback: L10n.text("agent.tokenCopied", defaultValue: "Token copied"))
                    }.buttonStyle(.key).accessibilityIdentifier("settings-mcp-copy-token")
                    if let feedback { Text(feedback).font(.caption11).foregroundStyle(Theme.textSecondary) }
                }
                Text(L10n.text("agent.connectionHelp", defaultValue: "JSON includes the token. Codex reads it from the environment. The address and token change on restart."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: service.endpoint) { _, _ in feedback = nil }
    }

    private var status: String {
        switch service.status {
        case .off: L10n.text("agent.off", defaultValue: "Server is off")
        case .starting: L10n.text("agent.starting", defaultValue: "Starting server…")
        case .listening: L10n.text("agent.listening", defaultValue: "Listening on this Mac")
        case .stopping: L10n.text("agent.stopping", defaultValue: "Stopping server…")
        case .failed: L10n.text("agent.startFailed", defaultValue: "Could not start the local MCP server.")
        }
    }

    private func copy(_ value: String?, feedback message: String) {
        guard let value else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        if pasteboard.setString(value, forType: .string) { feedback = message }
    }
}
