import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers
import GRDB
import CoreImage

/// Countable progress of the running batch; nil when the task has no known item count.
struct TaskProgress: Equatable {
    var title: String
    var done: Int
    var total: Int
}

enum BeforeAfterLayout { case off, sideBySide, split }
enum AdjustmentAction: String {
    case paste = "粘贴调整", sync = "同步调整", previous = "沿用上一张调整", save = "保存预设", update = "更新预设", preset = "应用预设"
    var title: String {
        switch self {
        case .paste: L10n.text("app.pasteAdjustments", defaultValue: "Paste Adjustments")
        case .sync: L10n.text("app.syncAdjustments", defaultValue: "Sync Adjustments")
        case .previous: L10n.text("app.usePreviousAdjustments", defaultValue: "Use Previous Adjustments")
        case .save: L10n.text("app.savePreset", defaultValue: "Save Preset")
        case .update: L10n.text("app.updatePreset", defaultValue: "Update Preset")
        case .preset: L10n.text("app.applyPreset", defaultValue: "Apply Preset")
        }
    }

}

struct AdjustmentSource {
    let photo: Photo
    let recipe: EditRecipe
}

struct ImportBatch {
    let snapshotID: String
    let photoIDs: Set<String>
    let cancelled: Bool
    var scope: String { "import:" + snapshotID }
}

/// Local navigation state; SQL browse snapshots themselves remain session-owned.
private struct StoredImportBatch: Codable {
    let catalogID: String
    let photoIDs: [String]
    let cancelled: Bool
}

/// The import view borrows the workspace without replacing its browsing session.
private struct ImportBrowseContext {
    var scope: String
    let search: String
    let ratingComparison: RatingComparison
    let ratingThreshold: Int
    let flags: Set<Int>
    let colorLabels: Set<Int>
    let keyword: String
    let metadata: LibraryMetadataFilter
    let filtersEnabled: Bool
    let sections: Set<LibraryFilterSection>
    let filtersOpen: Bool
    let sort: PhotoSort
    let descending: Bool
    let hold: Bool
    var heldID: String?
    let page: Int
    let selection: Set<String>
    let activeID: String?
    let single: Bool
    let edit: Bool
    let librarySingle: Bool
    let comparisonReferenceID: String?
    let comparisonGroupIDs: [String]?
    let comparisonRestricted: Bool
    let surveyIDs: [String]?
    let surveyOffset: Int
    let pinnedDevelopPhoto: Photo?
    let developReferenceVisible: Bool
    var relatedTitle: String? = nil
    var manualOrder = false
    var zoomed = false
    var fill = false
    var zoom = 1.0
    var center = CGPoint(x: 0.5, y: 0.5)
    var gridScroll: CGPoint? = nil
    var filmScroll: CGPoint? = nil
}

struct BrowseLocation: Identifiable {
    let id: UUID
    let title: String
    let photo: String
}

private struct BrowseHistoryEntry {
    let location: BrowseLocation
    let context: ImportBrowseContext
}

private struct AdjustmentDisplayState {
    let photoID: String
    let recipe: EditRecipe
    let image: CGImage?
    let histogram: ImageHistogram?
    let nativeSize: CGSize?
    let sourceSize: CGSize?
    let coordinateRecipe: EditRecipe?
    let interactive: Bool
    let current: Bool
    let status: String
    let spotOffsets: [UUID: MaskPoint]
}

/// Display only: edits and exports always use the active photo's recipe.
struct PhotoSwitchDisplay {
    let photoID: String
    let image: CGImage
    let histogram: ImageHistogram?
    let nativeSize: CGSize?
}

enum WorkspaceMode { case grid, single, develop, compare, survey }
enum WorkspaceModule: Hashable { case library, develop }
enum DevelopTool: Hashable { case adjust, crop, mask, spot }
enum LibraryFilterSection: String, CaseIterable, Identifiable {
    case text, attribute, metadata
    var id: String { rawValue }
    var title: String { switch self { case .text: L10n.text("app.text", defaultValue: "Text"); case .attribute: L10n.text("app.attributes", defaultValue: "Attributes"); case .metadata: L10n.text("app.metadata", defaultValue: "Metadata") } }
}

struct WorkspaceNotice: Equatable {
    let id = UUID()
    let text: String
}

private struct BeforeImageKey: Equatable {
    let photoID: String
    let recipe: EditRecipe
    let edge: Int?
}
struct SavedEditComparison {
    let photoID: String
    let title: String
    let recipe: EditRecipe
}

@MainActor
@Observable
final class AppModel {
    var photos: [Photo] = [] // Only the current SQL page, never the complete library.
    var totalCount = 0
    var resultCount = 0 // Base matching versions, including folded members.
    var visibleCount = 0
    var stackBadges: [String:StackBadge] = [:]
    var showAutoStacks = false
    var showPairing = false
    var pairedSourceIDs: Set<String> = []
    var pairingScope: Set<String>?
    let pairing = RawJpegPairing()
    var pageOffset = 0
    var activePhoto: Photo?
    var folders: [String: [FolderNode]] = [:]
    var cropMode = false { didSet { if !cropMode { finishPerspectiveGuides() }; if cropMode { cancelWhiteBalanceSampling(); cancelPointColorTools(); maskMode = false; spotMode = false; fillView = false; fullResolution = false; beforeAfter = .off; cancelZoneSampling() } } }
    var cropGuide = CropGuide.thirds
    var perspectiveGuideTool: PerspectiveGuideTool?
    var perspectiveGuides: [PerspectiveLine] = []
    var perspectiveGuideBase: EditRecipe?
    var selectedPerspectiveGuideIndex: Int?
    var selectedPerspectiveGuideEndpoint: PerspectiveGuideEndpoint?
    var perspectiveMessage = ""
    var uprightAnalyzing = false
    var uprightGeneration = UUID()
    @ObservationIgnored var uprightTask: Task<Void, Never>?
    @ObservationIgnored var applyingPerspective = false
    @ObservationIgnored var perspectiveGuideDragOriginal: (recipe: EditRecipe, lines: [PerspectiveLine], dirty: Bool)?
    @ObservationIgnored var detectPerspectiveLines: @Sendable (ImageRequest) async throws -> [PerspectiveLine] = { request in
        let worker = Task.detached(priority: .userInitiated) {
            let input = try await ImagePipeline().smartMaskInput(request, longEdge: 1024)
            try Task.checkCancellation()
            return try UprightLineDetector.lines(in: input.image)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    var showCameraDiagnostics = false
    var maskMode = false { didSet { if maskMode { cancelWhiteBalanceSampling(); cancelPointColorTools(); spotMode = false; beforeAfter = .off; cancelZoneSampling() } else if oldValue { endMaskEffectPreview(); cancelSmartMask() } } }
    var spotMode = false {
        didSet {
            if spotMode {
                cancelWhiteBalanceSampling()
                cancelPointColorTools()
                maskMode = false
                beforeAfter = .off
                cancelZoneSampling()
            } else if oldValue {
                cancelSpotSourceRefresh()
                spotGesture = nil
                spotRank = nil
                spotRankKey = nil
                spotGuides = [:]
                pendingSpotPins = []
                spotRankTask?.cancel()
                spotRankToken = UUID()
            }
        }
    }
    var pointSampling = false
    var selectedPointColorID:UUID? { didSet { if oldValue != selectedPointColorID { refreshPointColorTools() } } }
    var showPointColorRange = false { didSet { if oldValue != showPointColorRange { refreshPointColorTools() } } }
    var pointRangeImage:CGImage?
    var pointReferenceReady = false
    var pointReference:PointColorReference?
    var pointReferenceKey:String?
    @ObservationIgnored var pointReferenceTask:Task<Void,Never>?
    var pointReferenceToken = UUID()
    let pointPipeline = ImagePipeline()
    var whiteBalanceSampling = false
    var whiteBalanceContinuous = false
    var whiteBalanceSamplingBusy = false
    @ObservationIgnored var whiteBalanceTask: Task<Void, Never>?
    var whiteBalanceToken = UUID()
    var zoneSampling = false
    var zoneReference: CGImage?
    var selectedZone: Int?
    var sampledZoneEV: Double?
    @ObservationIgnored var zoneReferenceTask: Task<Void, Never>?
    var zoneReferenceToken = UUID()
    var maskChoosingTool = false { didSet { if maskChoosingTool { cancelSmartMask() } } }
    var smartMaskSession: SmartMaskSession?
    var smartMaskEngine: SmartMaskEngine?
    var smartMaskPipeline: ImagePipeline?
    @ObservationIgnored var smartMaskTask: Task<Void, Never>?
    @ObservationIgnored var smartMaskPreviewTask: Task<Void, Never>?
    var smartMaskGeneration = UUID()
    var smartMaskPreviewGeneration = UUID()
    var maskSampling = true
    var maskSampleAppending = false
    var maskOverlayStyle = MaskOverlayStyle.color
    var selectedMaskID: UUID? { didSet { if oldValue != selectedMaskID { endMaskEffectPreview(); cancelSmartMask() } } }
    private(set) var previewingMaskID: UUID?
    @ObservationIgnored private var maskPreviewPulse: Task<Void, Never>?
    private var maskPreviewOriginal: (photoID: String, recipe: EditRecipe, image: CGImage?, histogram: ImageHistogram?)?
    var selectedComponentID: UUID? { didSet { if oldValue != selectedComponentID { cancelSmartMask() } } }
    var showMaskGuides = true
    var showSpotGuides = true
    var showMaskOverlay = true
    var maskOverlayColor = 0
    var maskReference: CGImage?
    var maskDrawNew = true
    var brushRadius = 0.04
    var brushFeather = 0.7
    var brushFlow = 0.5
    var brushDensity = 1.0
    var brushErase = false
    var brushAutoMask = false
    var spotRadius = 0.04
    var spotFeather = 0.7
    var spotOpacity = 1.0
    var spotKind = SpotRepairMode.heal
    var selectedSpotID: UUID?
    var spotGuides: [UUID: MaskPoint] = [:]
    var spotRenderedOffsets: [UUID: MaskPoint] = [:]
    var refreshingSpotSource = false
    @ObservationIgnored var spotSourceTask: Task<Void, Never>?
    var spotSourceToken = UUID()
    var spotRank: SpotBuffer?
    var spotRankKey: String?
    @ObservationIgnored var spotRankTask: Task<Void, Never>?
    var spotRankToken = UUID()
    var pendingSpotPins: Set<UUID> = []
    var spotGesture: SpotEditGesture?
    var spotPreviewPending = false
    var maskGesture: MaskEditGesture?
    @ObservationIgnored var maskReferenceTask: Task<Void, Never>?
    var maskReferenceToken = UUID()
    let pageSize = 200
    // Native scrolling writes these during layout; restoring them must not invalidate that layout.
    @ObservationIgnored var scrollPositions: [String: CGPoint] = [:]
    @ObservationIgnored var scrollActiveIDs: [String: String] = [:]
    @ObservationIgnored private var folderPhotoCount = -1
    var roots: [StorageRoot] = []
    var collections: [PhotoCollection] = []
    var collectionCounts: [String:Int] = [:]
    private(set) var targetCollectionID: String?
    private var targetMemberIDs: Set<String> = []
    private var quickCollectionID: String?
    private var targetCatalogPath: String?
    var selection: Set<String> = [] { didSet { if selection != oldValue { perform { try reloadKeywords() } } } }
    var keywords: [KeywordSummary] = []
    var recentKeywords: [String] = []
    private var recentKeywordCatalog: String?
    var keywordFilter = "" { didSet { if keywordFilter != oldValue { prepareFilterSection(.metadata) } } }
    var activeID: String? { didSet { if activeID != oldValue { finishPerspectiveGuides(); perspectiveMessage = ""; cancelSmartMask(); cancelPointColorTools(); selectedPointColorID = nil; cancelSpotSourceRefresh(); rememberViewPosition(leaving: oldValue); cancelWhiteBalanceSampling(); cancelZoneSampling(); selectedZone = nil; sampledZoneEV = nil } } }
    var scope = "all"
    var search = "" { didSet { if search != oldValue { prepareFilterSection(.text) } } }
    var ratingComparison = RatingComparison.atLeast { didSet { if ratingComparison != oldValue { prepareFilterSection(.attribute) } } }
    var ratingThreshold = 0 { didSet { if ratingThreshold != oldValue { prepareFilterSection(.attribute) } } }
    var flagFilter: Set<Int> = [] { didSet { if flagFilter != oldValue { prepareFilterSection(.attribute) } } }
    var colorLabelFilter: Set<Int> = [] { didSet { if colorLabelFilter != oldValue { prepareFilterSection(.attribute) } } }
    var selectedColorLabel: Int?
    var selectedFlag: Int?
    var selectedRating: Int?
    var autoAdvance = false
    var libraryFiltersOpen = true
    var filtersEnabled = true
    var filterSections: Set<LibraryFilterSection> = [.attribute]
    var metadataFilter = LibraryMetadataFilter() { didSet { if metadataFilter != oldValue { prepareFilterSection(.metadata) } } }
    var photoSort = PhotoSort.captureDate
    var manualOrderEnabled = false
    var sortDescending = false
    var holdFilterResults = false
    private var heldResultsID: String?
    private(set) var lastImport: ImportBatch?
    var showImportCompletion = false
    private var importBrowseContext: ImportBrowseContext?
    private var browseBack: [BrowseHistoryEntry] = []
    private var browseForward: [BrowseHistoryEntry] = []
    private(set) var relatedBrowseTitle: String?
    private let browseHistoryLimit = 20
    private var importingPhotoIDs: Set<String> = []
    private var lastAppliedQuery: PhotoQuery?
    private var lastAppliedHold = false
    var isViewingImport: Bool { lastImport.map { scope == $0.scope } ?? false }
    private var librarySingleView = false
    var editMode = false { didSet { if !editMode { cancelSmartMask(); cancelWhiteBalanceSampling(); endAdjustmentPreview(); endDevelopReference(); cancelPointColorTools(); cancelZoneSampling(); if !singleView { beforeAfter = .off } } else { endComparison(); endSurvey() } } }
    var singleView = false { didSet { if !singleView { endComparison(); endSurvey(); if !editMode { beforeAfter = .off } } } }
    var comparison: PhotoComparison?
    var survey: PhotoSurvey?
    private(set) var developReference: ComparisonPhoto?
    private var pinnedDevelopPhoto: Photo?
    var canShowDevelopReference: Bool { editMode && (developReference != nil || pinnedDevelopPhoto != nil || canEdit) }
    var lockViewPosition = false
    var viewPositions: [String: CGPoint] = [:]
    var fullResolution = false { didSet { if fullResolution != oldValue { viewport.reset() } } }
    var zoomScale = 1.0
    var fillView = false
    static let zoomScales: [Double] = [0.0625, 0.125, 0.25, 0.5, 1, 2, 4, 8, 16]
    var zoomLabel: String { Self.zoomLabel(zoomScale) }
    static func zoomLabel(_ scale: Double) -> String { String(format: "%g%%", scale * 100) }
    var before = false { didSet { if before { cancelWhiteBalanceSampling(); endAdjustmentPreview(redraw: false); endDevelopReference(); cancelPointColorTools(); cancelZoneSampling() } } }
    var beforeAfter = BeforeAfterLayout.off {
        didSet { if beforeAfter != oldValue { if beforeAfter != .off { endDevelopReference(); cancelZoneSampling() }; refreshBeforeImage() } }
    }
    var beforeImage: CGImage?
    var beforeStatus = ""
    private(set) var savedEditPreview: ComparisonPhoto?
    private(set) var savedEditPreviewTitle = ""
    private var savedEditPreviewKey: String?
    private(set) var beforeReference: SavedEditComparison?
    var beforeLabel: String { beforeReference.map { L10n.text("app.reference", defaultValue: "Reference · ") + $0.title } ?? L10n.text("app.before", defaultValue: "Before") }
    @ObservationIgnored private var beforeTask: Task<Void, Never>?
    private var beforeKey: BeforeImageKey?
    var showShadowClipping = false
    var showHighlightClipping = false
    var showClipping: Bool {
        get { showShadowClipping || showHighlightClipping }
        set { showShadowClipping = newValue; showHighlightClipping = newValue }
    }
    var displayPixelReadout: DisplayPixelSample?
    var presetListFocused = false
    private(set) var previewingDevelopGroup: DevelopGroup?
    private(set) var previewingPresetID: String?
    private(set) var adjustmentPreviewTitle = ""
    private var adjustmentDisplayRecipe: EditRecipe?
    private var adjustmentDisplayOriginal: AdjustmentDisplayState?
    @ObservationIgnored private var adjustmentPreviewPulse: Task<Void, Never>?
    @ObservationIgnored private var adjustmentPreviewQuality: Task<Void, Never>?
    var notice: WorkspaceNotice?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    var image: CGImage? { didSet { if oldValue !== image { displayPixelReadout = nil } } }
    var previewIsCrop = false
    var histogram: ImageHistogram?
    var orientedSourceSize: CGSize?
    var renderedNativeSize: CGSize?
    private(set) var hasRecipe = false
    private(set) var photoSwitchDisplay: PhotoSwitchDisplay?
    // A missing image must not unmount the last real parameter controls.
    private var retainedEditorDisplay: (recipe: EditRecipe, rawDefaults: RAWDetailSettings?, previousAvailable: Bool)?
    private(set) var loadingPhoto = false
    var hasEditorRecipe: Bool { hasRecipe || retainedEditorDisplay != nil }
    var editorUsesPreviousPhoto: Bool { !canEdit && retainedEditorDisplay != nil }
    var editorRecipe: EditRecipe? { editorUsesPreviousPhoto ? retainedEditorDisplay?.recipe : recipe }
    var editorRawDefaults: RAWDetailSettings? {
        editorUsesPreviousPhoto ? retainedEditorDisplay?.rawDefaults : rawDefaults
    }
    var editorPreviousAdjustmentsAvailable: Bool {
        editorUsesPreviousPhoto ? retainedEditorDisplay?.previousAvailable == true : canUsePreviousAdjustments
    }
    var recipe: EditRecipe? {
        didSet {
            hasRecipe = recipe != nil
            let changed = oldValue != recipe
            if changed, uprightAnalyzing { cancelUprightAnalysis() }
            if perspectiveGuideTool != nil, !applyingPerspective {
                if let previous = oldValue, let current = recipe {
                    if !previous.hasSameGeometry(as: current) { finishPerspectiveGuides() }
                } else { finishPerspectiveGuides() }
            }
            if let session = smartMaskSession, recipe.map({ !session.acceptsRecipe($0) }) ?? true { cancelSmartMask() }
            if changed { cancelSpotSourceRefresh(); cancelWhiteBalanceSampling(keepTool: true); endAdjustmentPreview(redraw: false); cancelZoneSampling(); refreshPointColorTools() }
            if oldValue?.quarterTurns != recipe?.quarterTurns || oldValue?.straightenDegrees != recipe?.straightenDegrees ||
                oldValue?.crop != recipe?.crop || oldValue?.flipHorizontal != recipe?.flipHorizontal || oldValue?.flipVertical != recipe?.flipVertical ||
                oldValue?.perspective != recipe?.perspective || oldValue?.rawDetails.lensCorrection != recipe?.rawDetails.lensCorrection {
                cancelSmartMask()
                maskGesture = nil
                maskReferenceTask?.cancel(); maskReferenceTask = nil; maskReferenceToken = UUID(); maskReference = nil
                if maskMode { prepareMaskReference() }
                spotGesture = nil; spotRankTask?.cancel(); spotRankTask = nil; spotRankToken = UUID()
                spotRank = nil; spotRankKey = nil; spotGuides = [:]; spotRenderedOffsets = [:]
                if spotMode { prepareSpotRank() }
            }
            if maskMode, recipe?.localAdjustments.contains(where: { $0.needsBaseline }) == true { prepareMaskReference() }
        }
    }
    var rawDefaults: RAWDetailSettings?
    private var renderedCoordinateRecipe: EditRecipe?
    var canvasCoordinatesCurrent: Bool {
        guard let renderedCoordinateRecipe, let recipe else { return true }
        let expected = cropMode ? recipe.cropRenderRecipe : recipe
        return renderedCoordinateRecipe.hasSameGeometry(as: expected)
    }
    var adjustmentPresets: [AdjustmentPreset] = []
    var copiedLocalParameters: LocalParameterValues?
    var localParameterPresets: [LocalParameterPreset] = []
    var applyingAdjustments = false
    var editHistory: [EditHistoryEntry] = []
    var editSnapshots: [EditSnapshot] = []
    var copiedRecipe: EditRecipe?
    var copiedPhotoName = ""
    var copiedAdjustmentPhoto: Photo?
    var previousAdjustmentSource: AdjustmentSource?
    var adjustmentRequest: AdjustmentAction?
    private(set) var confirmedAdjustmentOptions = RecipePasteOptions()
    private let adjustmentPreferences: UserDefaults?
    var hasMoreHistory = false
    private var historyLimit = 100
    var status = L10n.text("app.chooseAPhotoCatalogToBegin", defaultValue: "Choose a photo catalog to begin")
    var imageStatus = L10n.text("app.noPhotoSelected", defaultValue: "No photo selected")
    var error: String?
    var reports: [String] = []
    var busy = false
    var dirty = false
    var canEdit = false
    var collectionMembers: Set<String> = []
    var thumbnailSize = 156.0
    var cacheBytes: Int64 = 0
    var cacheGigabytes = 5
    private(set) var cacheMaintenance = false
    @ObservationIgnored var exportOperationCounts = ExportOperationCounts()
    var settingsPane = SettingsPane.appearance
    var showExport = false
    var requestedExportPreset: ExportPreset?
    var showOutputRecovery = false
    private(set) var lastExportResult: ExportBatchResult?
    var exportRecordIDs: Set<String>?
    var exportRecordsUnfinishedOnly = false
    var showCopyRecovery = false
    var catalogUtilityOpen = false
    var showNewCatalog = false
    var catalogRestoreSource: URL?
    var importConflict: ImportConflict?
    private var conflictContinuation: CheckedContinuation<ImportConflictDecision?, Never>?
    var showImport = false
    var showXMPPresetImport = false
    var recentCatalogs: [RecentCatalog] = []
    private var startupCatalogOpen: CatalogOpenRequest?
    private var openingStartupCatalog = false
    private var deferredCatalogURL: URL?
    private(set) var changingCatalogExtension = false
    let viewport = PhotoViewport()
    let undo = UndoManager()
    let pipeline: ImagePipeline
    private let renderPreview: (ImageRequest, Bool, Int?) async throws -> RenderedImage
    let thumbnails = ThumbnailService()
    let importer = ReferenceImporter()
    var catalog: CatalogStore?
    var catalogName: String { catalog?.fileURL.deletingPathExtension().lastPathComponent ?? L10n.text("app.noCatalogOpen", defaultValue: "No catalog open") }
    /// Menu-bar commands stay reachable while a sheet is up, so they must not stack a second sheet.
    var presentingSheet: Bool { showCameraDiagnostics || showImport || showXMPPresetImport || showExport || showNewCatalog || showOutputRecovery || showCopyRecovery || importConflict != nil || catalogUtilityOpen || showAutoStacks || showPairing || startupCatalogOpen != nil }
    var canSwitchCatalog: Bool { !busy && !applyingAdjustments && !cacheMaintenance && !presentingSheet }
    var workspaceAvailable: Bool { !busy && !applyingAdjustments && !cacheMaintenance && !presentingSheet }
    var canLocateOriginal: Bool { catalog != nil && active != nil && workspaceAvailable && comparison == nil && survey == nil }
    var canImportPhotos: Bool { catalog != nil && workspaceAvailable }
    var canExportPhotos: Bool { canImportPhotos && !selection.isEmpty }
    var workspaceModule: WorkspaceModule { editMode ? .develop : .library }
    var workspaceMode: WorkspaceMode { survey != nil ? .survey : comparison != nil ? .compare : editMode ? .develop : singleView ? .single : .grid }
    var developTool: DevelopTool { cropMode ? .crop : maskMode ? .mask : spotMode ? .spot : .adjust }
    var hasLibraryFilters: Bool {
        filtersEnabled && filterSections.contains(where: filterSectionHasCriteria)
    }
    func filterSectionHasCriteria(_ section: LibraryFilterSection) -> Bool {
        switch section {
        case .text: !search.isEmpty
        case .attribute: ratingComparison.isActive(threshold: ratingThreshold) || !flagFilter.isEmpty || !colorLabelFilter.isEmpty
        case .metadata: !keywordFilter.isEmpty || metadataFilter.isActive
        }
    }
    func isFilterSectionActive(_ section: LibraryFilterSection) -> Bool { filtersEnabled && filterSections.contains(section) }
    private func prepareFilterSection(_ section: LibraryFilterSection) {
        filterSections.insert(section); filtersEnabled = true
    }
    /// Keep meaningful open conditions when switching groups; Shift can also keep empty groups open.
    func selectFilterSection(_ section: LibraryFilterSection, additive: Bool = false) {
        guard workspaceAvailable, commitRecipe() else { return }
        if isFilterSectionActive(section) { filterSections.remove(section) }
        else {
            let retained = filtersEnabled ? filterSections.filter { additive || filterSectionHasCriteria($0) } : []
            filterSections = Set(retained).union([section])
        }
        filtersEnabled = true
        filterChanged()
    }
    func disableLibraryFilters() {
        guard workspaceAvailable, commitRecipe() else { return }
        filtersEnabled = false; filterChanged()
    }
    func selectModule(_ module: WorkspaceModule) {
        guard module != workspaceModule else { return }
        selectWorkspace(module == .develop ? .develop : librarySingleView ? .single : .grid)
    }
    func selectWorkspace(_ mode: WorkspaceMode) {
        guard workspaceAvailable else { return }
        if editMode, mode != .develop, !selectDevelopTool(.adjust) { return }
        if mode != .survey { endSurvey() }
        switch mode {
        case .grid: editMode = false; singleView = false; librarySingleView = false
        case .single: endComparison(); editMode = false; singleView = true; librarySingleView = true
        case .develop:
            if !editMode { librarySingleView = singleView }
            editMode = true; singleView = true
        case .compare: beginComparison()
        case .survey: beginSurvey()
        }
        persistWorkspace()
    }
    /// Tools share one exit path so keyboard, toolbar and module changes preserve the same draft.
    @discardableResult func selectDevelopTool(_ tool: DevelopTool) -> Bool {
        guard workspaceAvailable, editMode, tool == .adjust || canEdit else { return false }
        cancelWhiteBalanceSampling()
        clearSavedEditPreview()
        endAdjustmentPreview()
        endMaskEffectPreview(redraw: false)
        if spotMode, tool != .spot {
            setSpotMode(false)
            guard !spotMode else { return false }
        }
        guard commitRecipe() else { return false }
        switch tool {
        case .adjust:
            let wasCrop = cropMode
            cropMode = false
            if maskMode { setMaskMode(false) }
            if wasCrop { requestPreview() }
        case .crop:
            if !cropMode {
                if maskMode { setMaskMode(false) }
                cropMode = true; before = false; requestPreview()
            }
        case .mask: if !maskMode { setMaskMode(true) }
        case .spot: if !spotMode { setSpotMode(true) }
        }
        return developTool == tool
    }
    func setCropAspectRatio(_ ratio: Double?) {
        guard workspaceAvailable, cropMode, canEdit, let size = orientedSourceSize,
              ratio.map({ $0.isFinite && (0.1...10).contains($0) }) ?? true else { return }
        changeRecipe({ r in
            r.cropAspectRatio = ratio
            if let ratio { r.crop = Crop.centered(aspectRatio: ratio, orientedCanvas: size, quarterTurns: r.quarterTurns) }
        }, title: L10n.text("app.cropAspectRatio", defaultValue: "Crop Aspect Ratio"))
    }
    func toggleCropAspectLock() {
        guard workspaceAvailable, cropMode, canEdit, let r = recipe, let s = orientedSourceSize else { return }
        changeRecipe({ value in
            if r.cropAspectRatio != nil { value.cropAspectRatio = nil }
            else {
                let w = r.quarterTurns % 2 == 0 ? s.width : s.height
                let h = r.quarterTurns % 2 == 0 ? s.height : s.width
                value.cropAspectRatio = w * r.crop.width / (h * r.crop.height)
            }
        }, title: L10n.text("app.lockCropAspectRatio", defaultValue: "Lock Crop Aspect Ratio"))
    }
    func rotateCropAspect() {
        guard workspaceAvailable, cropMode, canEdit, let r = recipe, let s = orientedSourceSize else { return }
        let w = r.quarterTurns % 2 == 0 ? s.width : s.height
        let h = r.quarterTurns % 2 == 0 ? s.height : s.width
        setCropAspectRatio(1 / (r.cropAspectRatio ?? (w * r.crop.width / (h * r.crop.height))))
    }
    func cycleCropGuide() {
        guard workspaceAvailable, cropMode else { return }
        cropGuide = cropGuide.next
    }
    func requestExport(preset: ExportPreset? = nil) {
        guard canExportPhotos, commitRecipe() else { return }
        requestedExportPreset = preset
        showExport = true
    }
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = UUID() { didSet { publishedDraft = nil } }
    private struct PendingPreview {
        let request: ImageRequest
        let generation: UUID
        let interactive: Bool
        let edge: Int?
        let revision: UInt64
        let cropPreview: Bool
        func hasSameContent(as other: Self) -> Bool {
            var photo = request.photo, otherPhoto = other.request.photo
            // Saving changes catalog recipe bookkeeping, not the rendered input.
            photo.recipe = nil; otherPhoto.recipe = nil
            photo.recipeRevision = 0; otherPhoto.recipeRevision = 0
            return generation == other.generation && cropPreview == other.cropPreview && edge == other.edge &&
                request.recipe == other.request.recipe && photo == otherPhoto &&
                request.root.id == other.request.root.id && request.root.path == other.request.root.path &&
                request.root.bookmark == other.request.root.bookmark && request.root.label == other.request.root.label
        }
    }
    @ObservationIgnored private var publishedDraft: (job: PendingPreview, image: CGImage)?
    @ObservationIgnored private var pendingPreview: PendingPreview?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var pendingQualityPreview: PendingPreview?
    @ObservationIgnored private var qualityWorker: Task<Void, Never>?
    @ObservationIgnored private var qualityRender: Task<RenderedImage, Error>?
    @ObservationIgnored private var previewRevision: UInt64 = 0
    @ObservationIgnored private var wantsInteractivePreview = false
    @ObservationIgnored private var publishedQualityRevision: UInt64?
    var interactivePreview = false
    /// The shown image is the quality render of the latest requested recipe.
    private(set) var previewCurrent = false
    var taskProgress: TaskProgress?
    private var savedRecipe: EditRecipe?
    private var renderedCropRecipe: EditRecipe?
    private let usesPreferences = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    private let cachePreferences: UserDefaults?
    private let importPreferences: UserDefaults?
    @ObservationIgnored private weak var importCatalog: CatalogStore?

    init(previewRenderer: ((ImageRequest, Bool, Int?) async throws -> RenderedImage)? = nil, cachePreferences: UserDefaults? = nil, adjustmentPreferences: UserDefaults? = nil, importPreferences: UserDefaults? = nil) {
        self.adjustmentPreferences = adjustmentPreferences ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : nil)
        self.cachePreferences = cachePreferences ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : nil)
        self.importPreferences = importPreferences ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : nil)
        let quota = self.cachePreferences?.integer(forKey: "cacheGB") ?? 5
        cacheGigabytes = [1, 5, 10].contains(quota) ? quota : 5
        let pipeline = ImagePipeline()
        self.pipeline = pipeline
        let interactivePipeline = ImagePipeline(cacheIntermediates: true)
        self.renderPreview = previewRenderer ?? Self.makePreviewRenderer(quality: pipeline, draft: interactivePipeline)
        if let data = self.adjustmentPreferences?.data(forKey: "confirmedAdjustmentOptions"),
           let options = try? JSONDecoder().decode(RecipePasteOptions.self, from: data), options.hasSelection {
            confirmedAdjustmentOptions = options
        }
        // XCTest exercises services explicitly, without opening the user's catalog.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        do {
            #if DEBUG
            // Explicit synthetic validation launch; failures never fall back to a recent/private catalog.
            if let path = ProcessInfo.processInfo.environment["PHOSDECK_SYNTHETIC_CATALOG"] {
                catalog = try CatalogStore(fileURL:URL(fileURLWithPath:path))
                try reload(); configureCache(); status = L10n.text("app.syntheticCatalogVerification", defaultValue: "Synthetic catalog verification · ") + catalogName; return
            }
            #endif
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("OhMyLRC", isDirectory: true)
            recentCatalogs = (UserDefaults.standard.data(forKey: "recentCatalogs").flatMap { try? JSONDecoder().decode([RecentCatalog].self, from: $0) }) ?? []
            if let recent = recentCatalogs.first {
                let lease = try AccessLease(bookmark: recent.bookmark)
                let url = lease.url.appendingPathComponent(recent.filename)
                if CatalogFile.isLegacy(url) {
                    startupCatalogOpen = CatalogOpenRequest(url: url, access: lease, bookmark: recent.bookmark, restoreWorkspace: true)
                    status = L10n.text("catalogExtension.waitingForChoice", defaultValue: "Choose how to open this catalog.")
                    return
                }
                catalog = try CatalogStore(fileURL: url, access: lease)
            } else {
                let folder = UserDefaults.standard.string(forKey: "catalogFolder") ?? "DefaultCatalog"
                let legacy = base.appendingPathComponent(folder).appendingPathComponent("Catalog.sqlite")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    catalog = try CatalogStore(fileURL: legacy)
                    try rememberCatalog(legacy, directory: legacy.deletingLastPathComponent())
                }
            }
            guard catalog != nil else { status = L10n.text("app.createOrOpenACatalogToBegin", defaultValue: "Create or open a catalog to begin"); return }
            try restoreCatalogWorkspace()
        } catch { self.error = error.localizedDescription; status = L10n.text("app.noCatalogIsOpen", defaultValue: "No catalog is open") }
    }
    private func restoreCatalogWorkspace() throws {
        let storedZoom = UserDefaults.standard.double(forKey: "lastZoomScale")
        if Self.zoomScales.contains(storedZoom) { zoomScale = storedZoom }
        scope = UserDefaults.standard.string(forKey: workspaceKey("lastScope")) ?? "all"
        search = UserDefaults.standard.string(forKey: workspaceKey("lastSearch")) ?? ""
        ratingComparison = RatingComparison(rawValue: UserDefaults.standard.string(forKey: workspaceKey("ratingComparison")) ?? "") ?? .atLeast
        ratingThreshold = UserDefaults.standard.integer(forKey: workspaceKey("lastRatingFilter"))
        flagFilter = Set(UserDefaults.standard.array(forKey: workspaceKey("flagFilterStates")) as? [Int] ?? []).intersection([-1,0,1])
        colorLabelFilter = Set(UserDefaults.standard.array(forKey: workspaceKey("colorLabelFilter")) as? [Int] ?? []).intersection(0...5)
        autoAdvance = UserDefaults.standard.bool(forKey: "autoAdvance")
        libraryFiltersOpen = UserDefaults.standard.object(forKey: "libraryFiltersOpen") as? Bool ?? true
        keywordFilter = UserDefaults.standard.string(forKey: workspaceKey("lastKeywordFilter")) ?? ""
        metadataFilter = UserDefaults.standard.data(forKey: workspaceKey("metadataFilter")).flatMap { try? JSONDecoder().decode(LibraryMetadataFilter.self, from: $0) } ?? LibraryMetadataFilter()
        if let storedSections = UserDefaults.standard.array(forKey: workspaceKey("filterSections")) as? [String] {
            filterSections = Set(storedSections.compactMap(LibraryFilterSection.init(rawValue:)))
        }
        filtersEnabled = UserDefaults.standard.object(forKey: workspaceKey("filtersEnabled")) as? Bool ?? true
        photoSort = PhotoSort(rawValue: UserDefaults.standard.string(forKey: workspaceKey("photoSort")) ?? "") ?? .captureDate
        manualOrderEnabled = UserDefaults.standard.bool(forKey: workspaceKey("manualCollectionOrder"))
        sortDescending = UserDefaults.standard.bool(forKey: workspaceKey("sortDescending"))
        holdFilterResults = UserDefaults.standard.bool(forKey: workspaceKey("holdFilterResults"))
        singleView = UserDefaults.standard.bool(forKey: workspaceKey("lastSingleView"))
        editMode = UserDefaults.standard.bool(forKey: workspaceKey("lastEditMode"))
        librarySingleView = UserDefaults.standard.bool(forKey: workspaceKey("librarySingleView"))
        pageOffset = UserDefaults.standard.integer(forKey: workspaceKey("lastPageOffset"))
        if let id = UserDefaults.standard.string(forKey: workspaceKey("activePhoto")), let offset = try catalog?.offset(of: id, query: query) { pageOffset = offset / pageSize * pageSize }
        try reload()
        configureCache()
        if let id = UserDefaults.standard.string(forKey: workspaceKey("activePhoto")), photos.contains(where: { $0.id == id }) { choose([id], active: id) }
        status = L10n.text("app.photosLocalCatalogOpen", defaultValue: "\(totalCount) photos · Local catalog open")
        if let count = try catalog?.database.read({ try Int.fetchOne($0, sql: "SELECT count(*) FROM exportItem WHERE state IN ('interrupted','needsReview')") }), count > 0 {
            reports = [L10n.text("app.outputsWereInterruptedOrNeedVerificationRetryThemManually", defaultValue: "\(count) outputs were interrupted or need verification. Retry them manually; published files will be preserved.")]
        }
    }

    // Construct this closure outside MainActor. A closure created in init can
    // otherwise hop back to the UI executor after each pipeline await, delaying
    // delivery even when the actual render has already completed.
    nonisolated private static func makePreviewRenderer(quality: ImagePipeline, draft: ImagePipeline)
        -> (ImageRequest, Bool, Int?) async throws -> RenderedImage {
        { request, interactive, edge in
            if interactive { return try await draft.renderInteractive(request) }
            return try await quality.render(request, longEdge: edge, reuseDecoded: true)
        }
    }

    var active: Photo? { activePhoto }
    var filtered: [Photo] { photos }
    var query: PhotoQuery {
        var value = PhotoQuery(scope: scope, search: isFilterSectionActive(.text) ? search : "", ratingThreshold: isFilterSectionActive(.attribute) ? ratingThreshold : 0, ratingComparison: isFilterSectionActive(.attribute) ? ratingComparison : .atLeast, flags: isFilterSectionActive(.attribute) ? flagFilter : [], colorLabels: isFilterSectionActive(.attribute) ? colorLabelFilter : [], keyword: isFilterSectionActive(.metadata) ? keywordFilter : "",
                   metadata: isFilterSectionActive(.metadata) ? metadataFilter : LibraryMetadataFilter(), sort: photoSort, descending: sortDescending, snapshotID: heldResultsID)
        value.manualCollectionOrder = manualOrderEnabled && regularCollectionID != nil
        if let collection = collections.first(where:{ "collection:"+$0.id == scope }), collection.isSmart {
            if let smart = try? collection.decodedRules() { value.scope = smart.source; value.smart = smart }
            else { value.invalidSmart = true }
        }
        return value
    }
    func reload() throws {
        guard let catalog else { return }
        totalCount = try catalog.photoCount(); roots = try catalog.roots(); collections = try catalog.collections()
        restoreLastImportIfNeeded()
        if targetCatalogPath != catalog.fileURL.path {
            targetCatalogPath = catalog.fileURL.path
            targetCollectionID = usesPreferences ? UserDefaults.standard.string(forKey: workspaceKey("targetCollection")) : nil
            quickCollectionID = usesPreferences ? UserDefaults.standard.string(forKey: workspaceKey("quickCollection")) : nil
        }
        adjustmentPresets = try catalog.presets()
        localParameterPresets = try catalog.localParameterPresets()
        try reloadKeywords()
        try reloadPhotos()
        try reloadEditContext()
        if folderPhotoCount != totalCount {
            let paths = try catalog.folderPaths()
            folders = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, FolderNode.build(root: $0, directories: paths[$0.id] ?? [])) })
            folderPhotoCount = totalCount
        }
    }
    /// Photo metadata and filter membership can change without changing roots,
    /// presets, keyword totals, folders or the active photo's edit history.
    func reloadPhotos() throws {
        guard let catalog else { return }
        if holdFilterResults, heldResultsID == nil { heldResultsID = try catalog.holdResults(query, replacing: nil) }
        collectionCounts = Dictionary(uniqueKeysWithValues:collections.map { ($0.id,(try? catalog.collectionCount($0)) ?? -1) })
        let page = try catalog.page(query, offset: pageOffset, limit: pageSize)
        photos = page.photos; resultCount = page.total; visibleCount = page.visibleTotal; stackBadges = page.badges; pageOffset = page.offset
        pairedSourceIDs = try catalog.pairedSources(within:Set(photos.map(\.sourceKey)))
        if let id = activeID { activePhoto = try photos.first { $0.id == id } ?? catalog.photo(id) }
        if let comparison {
            for pane in [comparison.reference, comparison.candidate] {
                let photo = try pane.photo.flatMap { previous in
                    try photos.first { $0.id == previous.id } ?? catalog.photo(previous.id)
                }
                comparison.update(pane, photo: photo, roots: roots)
            }
        }
        try refreshDevelopReference()
        try refreshSurvey()
        if survey == nil { try reloadOrganizationSummary() }
        lastAppliedQuery = query; lastAppliedHold = holdFilterResults
        persistWorkspace()
    }
    private func workspaceKey(_ key: String) -> String { (catalog?.fileURL.path ?? "none") + ":" + key }
    func persistWorkspace() {
        guard usesPreferences else { return }
        let defaults = UserDefaults.standard
        let original = persistedBrowseContext
        defaults.set(original?.scope ?? scope, forKey: workspaceKey("lastScope")); defaults.set(original?.search ?? search, forKey: workspaceKey("lastSearch"))
        defaults.set((original?.ratingComparison ?? ratingComparison).rawValue, forKey: workspaceKey("ratingComparison"))
        defaults.set(original?.ratingThreshold ?? ratingThreshold, forKey: workspaceKey("lastRatingFilter")); defaults.set((original?.flags ?? flagFilter).sorted(), forKey: workspaceKey("flagFilterStates"))
        defaults.set((original?.colorLabels ?? colorLabelFilter).sorted(), forKey: workspaceKey("colorLabelFilter"))
        defaults.set(original?.filtersEnabled ?? filtersEnabled, forKey: workspaceKey("filtersEnabled"))
        defaults.set((original?.sections ?? filterSections).map(\.rawValue).sorted(), forKey: workspaceKey("filterSections"))
        defaults.set(autoAdvance, forKey: "autoAdvance"); defaults.set(original?.filtersOpen ?? libraryFiltersOpen, forKey: "libraryFiltersOpen")
        defaults.set(original?.keyword ?? keywordFilter, forKey: workspaceKey("lastKeywordFilter"))
        defaults.set(try? JSONEncoder().encode(original?.metadata ?? metadataFilter), forKey: workspaceKey("metadataFilter"))
        defaults.set((original?.sort ?? photoSort).rawValue, forKey: workspaceKey("photoSort")); defaults.set(original?.descending ?? sortDescending, forKey: workspaceKey("sortDescending"))
        defaults.set(original?.manualOrder ?? manualOrderEnabled, forKey: workspaceKey("manualCollectionOrder"))
        defaults.set(original?.hold ?? holdFilterResults, forKey: workspaceKey("holdFilterResults"))
        defaults.set(original?.page ?? pageOffset, forKey: workspaceKey("lastPageOffset")); defaults.set(original?.single ?? singleView, forKey: workspaceKey("lastSingleView"))
        defaults.set(original?.edit ?? editMode, forKey: workspaceKey("lastEditMode"))
        defaults.set(original?.librarySingle ?? librarySingleView, forKey: workspaceKey("librarySingleView"))
    }
    func filterChanged() {
        guard commitRecipe() else { return }
        perform {
            if holdFilterResults, let catalog { heldResultsID = try catalog.holdResults(query, replacing: heldResultsID) }
            else if let id = heldResultsID { try catalog?.releaseResults(id); heldResultsID = nil }
            // Keep a surviving active photo on its SQL page; otherwise select a visible result.
            let offset = try activeID.flatMap { try catalog?.offset(of: $0, query: query) }
            pageOffset = (offset ?? 0) / pageSize * pageSize
            try reloadPhotos()
            reconcileVisibleSelection()
        }
    }
    /// Explicit refresh, filter/sort edits and source changes all begin a fresh result session.
    func refreshResults() { filterChanged() }
    func clearFilters() {
        filtersEnabled = true
        search = ""; ratingComparison = .atLeast; ratingThreshold = 0; flagFilter = []; colorLabelFilter = []; keywordFilter = ""; metadataFilter = LibraryMetadataFilter()
        filterSections = []
    }
    func reconcileVisibleSelection(preferredIndex: Int = 0) {
        if let survey {
            let id = activeID.flatMap { survey.ids.contains($0) ? $0 : nil } ?? survey.ids.first
            choose(Set(survey.ids), active: id); return
        }
        if let comparison, comparison.restrictToGroup, let group = comparison.groupIDs {
            perform {
                guard let catalog else { return }
                let allowed = try catalog.resultIDs(query, within: Set(group)).subtracting(Set([comparison.reference.photo?.id].compactMap { $0 }))
                let id = activeID.flatMap { allowed.contains($0) ? $0 : nil } ?? group.first { allowed.contains($0) }
                choose(id.map { [$0] } ?? [], active: id)
            }
            return
        }
        let visible = Set(photos.map(\.id))
        if let activeID, visible.contains(activeID) {
            let retained = selection.isSubset(of: visible) ? selection : ((try? catalog?.resultIDs(query, within: selection)) ?? selection.intersection(visible))
            choose(retained.union([activeID]), active: activeID)
        } else {
            let candidates = photos.filter { $0.id != comparison?.reference.photo?.id }
            let id = candidates.isEmpty ? nil : candidates[min(max(0, preferredIndex), candidates.count - 1)].id
            choose(id.map { [$0] } ?? [], active: id)
        }
    }
    func setScope(_ value: String) {
        guard value != scope, workspaceAvailable, commitRecipe() else { return }
        perform {
            try rememberBrowseDeparture()
            try discardTransientBrowse()
            manualOrderEnabled = false
            scope = value; filterChanged()
        }
    }
    var isViewingRelated: Bool { scope.hasPrefix("related:") }
    var canBrowseBack: Bool { importBrowseContext != nil || !browseBack.isEmpty }
    var canBrowseForward: Bool { importBrowseContext == nil && !browseForward.isEmpty }
    var recentBrowseLocations: [BrowseLocation] {
        browseBack.reversed().map(\.location) + browseForward.reversed().map(\.location)
    }
    /// Temporary version groups must never become a persisted recent source.
    private var persistedBrowseContext: ImportBrowseContext? {
        if let original = importBrowseContext, !original.scope.hasPrefix("related:") { return original }
        guard isViewingRelated || importBrowseContext?.scope.hasPrefix("related:") == true else { return nil }
        return (Array(browseBack.reversed()) + Array(browseForward.reversed())).first {
            !$0.context.scope.hasPrefix("related:") && !$0.context.scope.hasPrefix("import:")
        }?.context
    }
    private func browseTitle(_ context: ImportBrowseContext) -> String {
        if let title = context.relatedTitle { return title }
        if context.scope == "all" { return L10n.text("app.allPhotos", defaultValue: "All Photos") }
        if let collection = collections.first(where: { "collection:" + $0.id == context.scope }) { return collection.name }
        if let root = roots.first(where: { $0.id == context.scope }) { return root.label }
        if context.scope.hasPrefix("folder:") {
            return URL(fileURLWithPath: String(context.scope.split(separator: ":", maxSplits: 2).last ?? "")).lastPathComponent
        }
        return L10n.text("app.browseHistory", defaultValue: "Browse History")
    }
    private func currentBrowseContext() -> ImportBrowseContext {
        ImportBrowseContext(scope: scope, search: search, ratingComparison: ratingComparison,
            ratingThreshold: ratingThreshold, flags: flagFilter, colorLabels: colorLabelFilter, keyword: keywordFilter, metadata: metadataFilter,
            filtersEnabled: filtersEnabled, sections: filterSections, filtersOpen: libraryFiltersOpen,
            sort: photoSort, descending: sortDescending, hold: holdFilterResults, heldID: heldResultsID,
            page: pageOffset, selection: selection, activeID: activeID, single: singleView, edit: editMode,
            librarySingle: librarySingleView, comparisonReferenceID: comparison?.reference.photo?.id,
            comparisonGroupIDs: comparison?.groupIDs, comparisonRestricted: comparison?.restrictToGroup ?? false,
            surveyIDs: survey?.members, surveyOffset: survey?.offset ?? 0,
            pinnedDevelopPhoto: pinnedDevelopPhoto, developReferenceVisible: developReference != nil,
            relatedTitle: relatedBrowseTitle, manualOrder: manualOrderEnabled,
            zoomed: fullResolution, fill: fillView, zoom: zoomScale, center: viewport.center,
            gridScroll: scrollPositions[browseScrollKey(film: false)], filmScroll: scrollPositions[browseScrollKey(film: true)])
    }
    func browseScrollKey(film: Bool) -> String {
        "\(query.scrollQuerySignature)|page:\(pageOffset)|film:\(film)"
    }
    private func copyBrowseSnapshot(_ id: String) throws -> String {
        guard let catalog else { throw LRCError(L10n.text("app.noCatalogIsOpen", defaultValue: "No catalog is open")) }
        let next = UUID().uuidString
        try catalog.database.write { db in
            try db.execute(sql: "INSERT INTO temp.browseSnapshot SELECT ?,photoID,position FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [next,id])
        }
        return next
    }
    /// History owns its SQL snapshots. A filter refresh in the active source
    /// can replace its own snapshot without invalidating a previous location.
    private func preservedBrowseEntry() throws -> BrowseHistoryEntry {
        var context = importBrowseContext ?? currentBrowseContext()
        if let held = context.heldID { context.heldID = try copyBrowseSnapshot(held) }
        if context.scope.hasPrefix("related:") {
            do { context.scope = "related:" + (try copyBrowseSnapshot(String(context.scope.dropFirst(8)))) }
            catch { if let held = context.heldID { try? catalog?.releaseResults(held) }; throw error }
        }
        let photo = try context.activeID.flatMap { try catalog?.photo($0)?.displayName } ?? ""
        return BrowseHistoryEntry(location: BrowseLocation(id: UUID(), title: browseTitle(context), photo: photo), context: context)
    }
    private func releaseBrowseEntry(_ entry: BrowseHistoryEntry) {
        if let held = entry.context.heldID { try? catalog?.releaseResults(held) }
        if entry.context.scope.hasPrefix("related:") { try? catalog?.releaseResults(String(entry.context.scope.dropFirst(8))) }
    }
    private func trimBrowseHistory() {
        while browseBack.count > browseHistoryLimit { releaseBrowseEntry(browseBack.removeFirst()) }
        while browseForward.count > browseHistoryLimit { releaseBrowseEntry(browseForward.removeFirst()) }
    }
    private func clearBrowseHistory() {
        for entry in browseBack + browseForward { releaseBrowseEntry(entry) }
        browseBack = []; browseForward = []
    }
    private func rememberBrowseDeparture() throws {
        guard catalog != nil else { return }
        let entry = try preservedBrowseEntry()
        for future in browseForward { releaseBrowseEntry(future) }
        browseForward = []
        browseBack.append(entry); trimBrowseHistory()
    }
    /// Release only temporary rows owned by the current view. Last Import's
    /// batch remains available independently from its borrowed return context.
    private func discardTransientBrowse() throws {
        var snapshots = Set([heldResultsID, importBrowseContext?.heldID].compactMap { $0 })
        if isViewingRelated { snapshots.insert(String(scope.dropFirst(8))) }
        if let original = importBrowseContext, original.scope.hasPrefix("related:") { snapshots.insert(String(original.scope.dropFirst(8))) }
        for id in snapshots { try catalog?.releaseResults(id) }
        heldResultsID = nil; importBrowseContext = nil; relatedBrowseTitle = nil
    }
    private func browseSourceExists(_ context: ImportBrowseContext) -> Bool {
        if context.scope == "all" || context.scope.hasPrefix("related:") { return true }
        if context.scope.hasPrefix("collection:") { return collections.contains { "collection:" + $0.id == context.scope } }
        if context.scope.hasPrefix("folder:") {
            let parts = context.scope.split(separator: ":", maxSplits: 2)
            return parts.count == 3 && roots.contains { $0.id == String(parts[1]) }
        }
        return roots.contains { $0.id == context.scope }
    }
    func navigateBrowse(_ delta: Int) {
        guard delta != 0, workspaceAvailable, commitRecipe() else { return }
        if importBrowseContext != nil { if delta < 0 { returnFromImport() }; return }
        if editMode, !selectDevelopTool(.adjust) { return }
        perform {
            for _ in 0..<min(abs(delta), browseHistoryLimit) {
                var destination = delta < 0 ? browseBack.popLast() : browseForward.popLast()
                while let entry = destination, !browseSourceExists(entry.context) {
                    releaseBrowseEntry(entry)
                    destination = delta < 0 ? browseBack.popLast() : browseForward.popLast()
                }
                guard let entry = destination else { break }
                let inverse: BrowseHistoryEntry
                do {
                    inverse = try preservedBrowseEntry()
                } catch {
                    // The destination still owns its cloned snapshot until a
                    // restore succeeds. Put it back when capturing the
                    // current context fails instead of losing the history
                    // item and its temporary rows.
                    if delta < 0 { browseBack.append(entry) } else { browseForward.append(entry) }
                    throw error
                }
                do {
                    try discardTransientBrowse()
                    try restoreBrowseContext(entry.context)
                } catch {
                    // Restore the prior context from the inverse snapshot and
                    // return the failed destination to its original side.
                    // This keeps a transient SQL/read failure from silently
                    // dropping a history entry or leaving an unowned snapshot.
                    do { try restoreBrowseContext(inverse.context) }
                    catch { releaseBrowseEntry(inverse) }
                    if delta < 0 { browseBack.append(entry) } else { browseForward.append(entry) }
                    throw error
                }
                if delta < 0 { browseForward.append(inverse) } else { browseBack.append(inverse) }
                trimBrowseHistory()
                status = L10n.text("app.returned", defaultValue: "Returned · ") + entry.location.title
            }
        }
    }
    func navigateBrowse(to id: UUID) {
        if let index = browseBack.firstIndex(where: { $0.location.id == id }) { navigateBrowse(-(browseBack.count - index)) }
        else if let index = browseForward.firstIndex(where: { $0.location.id == id }) { navigateBrowse(browseForward.count - index) }
    }
    private func restoreBrowseContext(_ original: ImportBrowseContext) throws {
        guard let catalog else { return }
        endComparison(); endSurvey(); endDevelopReference(); pinnedDevelopPhoto = original.pinnedDevelopPhoto
        cropMode = false; maskMode = false; spotMode = false
        heldResultsID = original.heldID; relatedBrowseTitle = original.relatedTitle
        scope = original.scope; search = original.search; ratingComparison = original.ratingComparison
        ratingThreshold = original.ratingThreshold; flagFilter = original.flags; colorLabelFilter = original.colorLabels; keywordFilter = original.keyword
        metadataFilter = original.metadata; filterSections = original.sections; filtersEnabled = original.filtersEnabled
        libraryFiltersOpen = original.filtersOpen; photoSort = original.sort; sortDescending = original.descending
        manualOrderEnabled = original.manualOrder; holdFilterResults = original.hold; pageOffset = original.page
        singleView = original.single; editMode = original.edit; librarySingleView = original.librarySingle
        try reloadPhotos()
        let selected = try catalog.resultIDs(query, within: original.selection)
        let retained = try original.activeID.flatMap { try catalog.representative(of: $0, query: query) }
        let active = retained ?? photos.first?.id
        choose(selected.isEmpty && !original.selection.isEmpty ? Set(active.map { [$0] } ?? []) : selected, active: active)
        if let reference = original.comparisonReferenceID, let active, reference != active,
           let photo = try catalog.photo(reference), !photo.deleted {
            choose([reference], active: reference); beginComparison(candidateID: active)
            comparison?.groupIDs = original.comparisonGroupIDs; comparison?.restrictToGroup = original.comparisonRestricted
            choose(selected, active: active)
        }
        if let ids = original.surveyIDs { beginSurvey(ids: ids, active: active, offset: original.surveyOffset) }
        if original.developReferenceVisible { try displayDevelopReference(chooseNext: false) }
        fullResolution = original.zoomed; fillView = original.fill; zoomScale = original.zoom
        viewport.focusOnNextGeometry(original.center)
        for (film, origin) in [(false, original.gridScroll), (true, original.filmScroll)] {
            let key = browseScrollKey(film: film)
            scrollPositions[key] = origin
            scrollActiveIDs[key] = activeID
        }
        if comparison == nil, survey == nil { requestPreview() }
        persistWorkspace()
    }
    func changePage(_ delta: Int) {
        let destination = min(max(0, pageOffset + delta * pageSize), max(0, (visibleCount - 1) / pageSize * pageSize))
        guard destination != pageOffset, commitRecipe() else { return }
        pageOffset = destination
        perform {
            try reloadPhotos()
            let candidates = photos.filter { $0.id != comparison?.reference.photo?.id }
            let id = (delta < 0 ? candidates.last : candidates.first)?.id
            choose(id.map { [$0] } ?? [], active: id)
        }
    }
    func perform(_ operation: () throws -> Void) { do { try operation() } catch { self.error = error.localizedDescription } }
    func choose(_ ids: Set<String>, active id: String?) {
        guard !applyingAdjustments else { return }
        if let comparison, let id, id == comparison.reference.photo?.id {
            selection = Set(comparison.candidate.photo.map { [$0.id] } ?? [])
            return
        }
        let ids = comparison == nil ? ids : Set(id.map { [$0] } ?? [])
        if activeID != id {
            guard commitRecipe() else { return }
            clearSavedEditPreview(); endAdjustmentPreview(redraw: false); displayPixelReadout = nil; presetListFocused = false; beforeReference = nil; endMaskEffectPreview(redraw: false)
            if id != nil, comparison == nil, survey == nil {
                if let recipe, canEdit || retainedEditorDisplay == nil {
                    retainedEditorDisplay = (recipe, rawDefaults, canUsePreviousAdjustments)
                }
                if let activeID, let image, recipe != nil, !previewIsCrop {
                    photoSwitchDisplay = PhotoSwitchDisplay(photoID: activeID, image: image,
                        histogram: histogram, nativeSize: renderedNativeSize)
                }
            } else { photoSwitchDisplay = nil; retainedEditorDisplay = nil }
            if canEdit, let photo = activePhoto, let recipe {
                previousAdjustmentSource = AdjustmentSource(photo: photo, recipe: recipe)
            } else { previousAdjustmentSource = nil }
            historyLimit = 100; editHistory = []; editSnapshots = []; hasMoreHistory = false
            activeID = id; selection = ids; before = false; cropMode = false; resetBeforeImage()
            maskMode = false; maskChoosingTool = false; maskReference = nil; selectedMaskID = nil; selectedComponentID = nil; maskGesture = nil
            maskReferenceTask?.cancel(); maskReferenceTask = nil; maskReferenceToken = UUID()
            activePhoto = photos.first { $0.id == id } ?? id.flatMap { try? catalog?.photo($0) }
            if usesPreferences {
                UserDefaults.standard.set(persistedBrowseContext?.activeID ?? id, forKey: workspaceKey("activePhoto"))
            }
            image = nil; histogram = nil; canEdit = false; orientedSourceSize = nil; renderedNativeSize = nil; renderedCoordinateRecipe = nil; recipe = nil; savedRecipe = nil; rawDefaults = nil
            perform { try reloadEditContext() }
            loadActive()
        } else { selection = ids }
        if let comparison { comparison.update(comparison.candidate, photo: activePhoto, roots: roots) }
    }
    func move(_ delta: Int) {
        if let survey {
            guard !survey.ids.isEmpty else { return }
            let index = survey.ids.firstIndex(of: activeID ?? "") ?? 0
            activateSurveyPhoto(survey.ids[min(survey.ids.count - 1, max(0, index + delta))]); return
        }
        if let comparison {
            perform {
                if comparison.restrictToGroup {
                    if let id = activeID, let next = try comparisonNeighbor(after: id, delta: delta, excluding: comparison.reference.photo?.id) {
                        selectComparisonCandidate(next)
                    }
                    return
                }
                guard let catalog, delta != 0 else { return }
                let offset = try activeID.flatMap { try catalog.offset(of: $0, query: query) }
                let step = delta > 0 ? 1 : -1
                var index = (offset ?? (step > 0 ? -1 : visibleCount)) + step
                while index >= 0 && index < visibleCount {
                    if let photo = try catalog.page(query, offset: index, limit: 1).photos.first,
                       photo.id != comparison.reference.photo?.id {
                        pageOffset = index / pageSize * pageSize; try reloadPhotos()
                        choose([photo.id], active: photo.id); return
                    }
                    index += step
                }
            }
            return
        }
        let list = filtered
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == activeID } ?? 0
        if index + delta >= list.count, pageOffset + list.count < visibleCount {
            changePage(1); return
        }
        if index + delta < 0, pageOffset > 0 {
            changePage(-1); return
        }
        let photo = list[max(0, min(list.count - 1, index + delta))]
        choose([photo.id], active: photo.id)
    }
    func beginComparison() { beginComparison(candidateID:nil) }
    func beginComparison(candidateID: String?) {
        guard comparison == nil, !applyingAdjustments, commitRecipe(), let reference = active, let catalog else { return }
        perform {
            let group = selection.count > 1 ? try catalog.exportPhotos(ids: selection, query: query).map(\.id) : nil
            var candidate = try candidateID.flatMap { try catalog.photo($0) } ?? catalog.firstResult(query, within: selection.subtracting([reference.id]))
            if candidate == nil {
                let offset = try catalog.offset(of: reference.id, query: query) ?? -1
                let next = offset + 1 < visibleCount ? offset + 1 : offset - 1
                if next >= 0 { candidate = try catalog.page(query, offset: next, limit: 1).photos.first }
            }
            guard let candidate, candidate.id != reference.id else { error = L10n.text("app.selectAtLeastTwoPhotosToCompare", defaultValue: "Select at least two photos to compare"); return }
            let comparison = makeComparisonRenderer()
            comparison.groupIDs = group
            photoSwitchDisplay = nil; retainedEditorDisplay = nil
            editMode = false; singleView = true; beforeAfter = .off; self.comparison = comparison
            comparison.update(comparison.reference, photo: reference, roots: roots)
            if let offset = try catalog.offset(of: candidate.id, query: query) { pageOffset = offset / pageSize * pageSize; try reloadPhotos() }
            choose([candidate.id], active: candidate.id)
        }
    }
    func endComparison() {
        guard let comparison else { return }
        comparison.cancel(); self.comparison = nil
        loadActive()
    }
    private func makeComparisonRenderer() -> PhotoComparison {
        let pipeline = self.pipeline, render = renderPreview
        return PhotoComparison { request, edge in
            try Task.checkCancellation()
            var recipe = request.recipe
            if recipe == nil, request.photo.isRAW { recipe = try await pipeline.baseline(request) }
            try Task.checkCancellation()
            return try await render(ImageRequest(photo: request.photo, root: request.root, recipe: recipe), false, edge)
        }
    }
    private func comparisonNeighbor(after id: String, delta: Int, excluding excluded: String?) throws -> Photo? {
        guard let comparison, let catalog, delta != 0 else { return nil }
        let step = delta > 0 ? 1 : -1
        if comparison.restrictToGroup, let group = comparison.groupIDs {
            let allowed = try catalog.resultIDs(query, within: Set(group))
            var i = (group.firstIndex(of: id) ?? (step > 0 ? -1 : group.count)) + step
            while group.indices.contains(i) {
                if group[i] != excluded, allowed.contains(group[i]), let photo = try catalog.photo(group[i]) { return photo }
                i += step
            }
            return nil
        }
        var i = (try catalog.offset(of: id, query: query) ?? (step > 0 ? -1 : visibleCount)) + step
        while (0..<visibleCount).contains(i) {
            if let photo = try catalog.page(query, offset: i, limit: 1).photos.first, photo.id != excluded { return photo }
            i += step
        }
        return nil
    }
    private func selectComparisonCandidate(_ photo: Photo) {
        perform {
            if let offset = try catalog?.offset(of: photo.id, query: query) { pageOffset = offset / pageSize * pageSize; try reloadPhotos() }
            choose([photo.id], active: photo.id)
        }
    }
    func promoteComparisonCandidate() {
        guard workspaceAvailable, let comparison, let candidate = comparison.candidate.photo else { return }
        perform {
            guard let next = try comparisonNeighbor(after: candidate.id, delta: 1, excluding: candidate.id)
                    ?? comparisonNeighbor(after: candidate.id, delta: -1, excluding: candidate.id) else {
                status = L10n.text("app.noOtherCandidatePhotos", defaultValue: "No other candidate photos"); return
            }
            comparison.update(comparison.reference, photo: candidate, roots: roots)
            selectComparisonCandidate(next)
        }
    }
    func restrictComparisonToGroup(_ value: Bool) {
        guard workspaceAvailable, let comparison, !value || comparison.groupIDs != nil else { return }
        comparison.restrictToGroup = value
        reconcileVisibleSelection()
    }
    func beginSurvey(ids: [String]? = nil, active: String? = nil, offset: Int = 0) {
        guard workspaceAvailable, commitRecipe(), let catalog else { return }
        perform {
            let chosen = try ids ?? catalog.exportPhotos(ids: selection, query: query).map(\.id)
            guard ids != nil || chosen.count >= 2 else { error = L10n.text("app.selectAtLeastTwoPhotosForSurvey", defaultValue: "Select at least two photos for Survey"); return }
            endComparison(); endSurvey()
            editMode = false; singleView = true; beforeAfter = .off
            let next = PhotoSurvey(ids: chosen, renderer: makeComparisonRenderer())
            photoSwitchDisplay = nil; retainedEditorDisplay = nil
            next.offset = offset; survey = next
            choose(Set(chosen), active: active.flatMap { chosen.contains($0) ? $0 : nil } ?? activeID.flatMap { chosen.contains($0) ? $0 : nil } ?? chosen.first)
            try refreshSurvey()
        }
    }
    func endSurvey() {
        guard let survey else { return }
        survey.cancel(); self.survey = nil
        loadActive()
        perform { try reloadOrganizationSummary() }
    }
    private func refreshSurvey() throws {
        guard let survey, let catalog else { return }
        let previousIndex = survey.ids.firstIndex(of: activeID ?? "") ?? 0
        let allowed = try catalog.resultIDs(query, within: Set(survey.members))
        survey.ids = survey.members.filter { allowed.contains($0) }
        if !allowed.contains(activeID ?? "") || selection != Set(survey.ids) {
            let next = survey.ids.isEmpty ? nil : survey.ids[min(previousIndex, survey.ids.count - 1)]
            choose(Set(survey.ids), active: allowed.contains(activeID ?? "") ? activeID : next)
        }
        survey.offset = min(max(0, survey.offset / PhotoSurvey.pageSize * PhotoSurvey.pageSize), max(0, (survey.ids.count - 1) / PhotoSurvey.pageSize * PhotoSurvey.pageSize))
        let indexed = Dictionary(uniqueKeysWithValues: try catalog.photos(ids: Set(survey.visibleIDs)).map { ($0.id,$0) })
        survey.update(photos: survey.visibleIDs.compactMap { indexed[$0] }, roots: roots)
        try reloadOrganizationSummary()
    }
    func activateSurveyPhoto(_ id: String) {
        guard workspaceAvailable, let survey, survey.ids.contains(id), let catalog else { return }
        perform {
            choose(Set(survey.ids), active: id)
            survey.offset = (survey.ids.firstIndex(of: id) ?? 0) / PhotoSurvey.pageSize * PhotoSurvey.pageSize
            if let index = try catalog.offset(of: id, query: query) { pageOffset = index / pageSize * pageSize }
            try reloadPhotos()
        }
    }
    func removeFromSurvey(_ id: String) {
        guard workspaceAvailable, let survey else { return }
        let oldIndex = survey.ids.firstIndex(of: id) ?? 0
        survey.members.removeAll { $0 == id }
        survey.ids.removeAll { $0 == id }
        let active = activeID == id ? (survey.ids.isEmpty ? nil : survey.ids[min(oldIndex, survey.ids.count - 1)]) : activeID
        choose(Set(survey.ids), active: active)
        perform { try refreshSurvey() }
    }
    func changeSurveyPage(_ delta: Int) {
        guard let survey else { return }
        let start = min(max(0, survey.offset + delta * PhotoSurvey.pageSize), max(0, (survey.ids.count - 1) / PhotoSurvey.pageSize * PhotoSurvey.pageSize))
        if survey.ids.indices.contains(start) { activateSurveyPhoto(survey.ids[start]) }
    }
    func updateSurveySelection(_ ids: Set<String>, active: String?) {
        guard let survey, let catalog else { return }
        perform {
            survey.members = try catalog.exportPhotos(ids: ids, query: query).map(\.id)
            survey.ids = survey.members
            choose(ids, active: active.flatMap { ids.contains($0) ? $0 : nil } ?? survey.ids.first)
            try refreshSurvey()
        }
    }
    func toggleDevelopReference() {
        guard workspaceAvailable, editMode, commitRecipe() else { return }
        if developReference != nil { endDevelopReference(); return }
        if pinnedDevelopPhoto == nil { pinActiveAsDevelopReference() }
        else { perform { try displayDevelopReference() } }
    }
    func pinActiveAsDevelopReference() {
        guard workspaceAvailable, editMode, canEdit, var photo = active, let recipe, commitRecipe() else { return }
        perform {
            // Freeze the look shown now. Later edits, batch writes and undo never
            // replace this recipe; changing the reference is an explicit action.
            photo.recipe = try JSONEncoder().encode(recipe)
            pinnedDevelopPhoto = photo
            try displayDevelopReference()
        }
    }
    private func displayDevelopReference(chooseNext: Bool = true) throws {
        guard let pinned = pinnedDevelopPhoto, let catalog else { return }
        endDevelopReference(); before = false; beforeAfter = .off
        developReference = ComparisonPhoto()
        try refreshDevelopReference()
        if chooseNext, activeID == pinned.id, let offset = try catalog.offset(of: pinned.id, query: query), visibleCount > 1 {
            let next = offset + 1 < visibleCount ? offset + 1 : offset - 1
            if let candidate = try catalog.page(query, offset: next, limit: 1).photos.first {
                pageOffset = next / pageSize * pageSize; try reloadPhotos(); choose([candidate.id], active: candidate.id)
            }
        }
        status = L10n.text("app.referencePinnedEditOnTheRightZoomEachSide", defaultValue: "Reference pinned · Edit on the right · Zoom each side independently")
    }
    func endDevelopReference() {
        developReference?.cancel(); developReference = nil
    }
    func clearDevelopReference() {
        guard workspaceAvailable else { return }
        endDevelopReference(); pinnedDevelopPhoto = nil
    }
    private func refreshDevelopReference() throws {
        guard let pane = developReference, let pinned = pinnedDevelopPhoto, let catalog else { return }
        guard var photo = try catalog.photo(pinned.id), !photo.deleted else {
            pane.cancel(); pane.photo = pinned; pane.root = nil; pane.status = L10n.text("app.theReferencePhotoWasRemovedFromTheCatalog", defaultValue: "The reference photo was removed from the catalog"); return
        }
        photo.recipe = pinned.recipe
        let root = roots.first { $0.id == photo.rootID }
        let changed = pane.photo?.id != photo.id || pane.photo?.identity != photo.identity || pane.photo?.digest != photo.digest ||
            pane.photo?.relativePath != photo.relativePath || pane.photo?.availability != photo.availability ||
            pane.photo?.recipe != photo.recipe || pane.root?.bookmark != root?.bookmark || pane.root?.path != root?.path
        pane.photo = photo; pane.root = root
        if changed { pane.cancel(); loadDevelopReference(pane) }
    }
    private func loadDevelopReference(_ pane: ComparisonPhoto) {
        let render = renderPreview
        pane.load { request, edge in try await render(request, false, edge) }
    }
    func selectDevelopReferenceZoom(_ scale: Double?, focus: CGPoint? = nil) {
        guard workspaceAvailable, let pane = developReference else { return }
        if let scale, !Self.zoomScales.contains(scale) { return }
        let changedResolution = (pane.zoom == nil) != (scale == nil)
        let point = focus ?? pane.viewport.center
        pane.zoom = scale
        if scale == nil { pane.viewport.reset() } else { pane.viewport.focusOnNextGeometry(point) }
        if changedResolution { loadDevelopReference(pane) }
    }
    func swapComparison() {
        guard let comparison, let reference = comparison.reference.photo, let candidate = comparison.candidate.photo else { return }
        comparison.update(comparison.reference, photo: candidate, roots: roots)
        perform {
            if let offset = try catalog?.offset(of: reference.id, query: query) { pageOffset = offset / pageSize * pageSize; try reloadPhotos() }
            choose([reference.id], active: reference.id)
        }
    }
    func chooseDirectory(title: String, initialURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseDirectories = true
        panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = initialURL
        return panel.runModal() == .OK ? panel.url : nil
    }
    func importReference() {
        guard canImportPhotos, commitRecipe() else { return }
        showImport = true
    }
    func runReference(source: URL, candidates: [ImportCandidate], collection: String?, pairAfterImport: Bool = false) {
        guard !busy, let catalog else { return }
        busy = true
        task = Task {
            let report = await importer.add(source: source, candidates: candidates, collection: collection, catalog: catalog)
            perform { try reload() }
            perform { try completeImport(ids: report.importedPhotoIDs, cancelled: report.cancelled) }
            reports = report.errors
            status = L10n.text("app.addedSkippedErrors", defaultValue: "\(report.cancelled ? L10n.text("app.cancelled", defaultValue: "Cancelled") : L10n.text("app.importComplete", defaultValue: "Import Complete")) · Added \(report.indexed) · Skipped \(report.ignored) · \(report.errors.count) errors")
            busy = false
            if pairAfterImport, !report.cancelled, !report.sourceIDs.isEmpty { openPairing(within:report.sourceIDs) }
        }
    }
    private func importCatalogID(_ catalog: CatalogStore) throws -> String {
        guard let id = try catalog.database.read({ try String.fetchOne($0, sql: "SELECT id FROM catalogMeta") }), !id.isEmpty else {
            throw LRCError(L10n.text("app.cannotReadTheCatalogIdentity", defaultValue: "Cannot read the catalog identity"))
        }
        return id
    }
    private func restoreLastImportIfNeeded() {
        guard let catalog, importCatalog !== catalog else { return }
        if let previous = lastImport, let owner = importCatalog { try? owner.releaseResults(previous.snapshotID) }
        importCatalog = catalog; lastImport = nil; showImportCompletion = false
        guard let data = importPreferences?.data(forKey: workspaceKey("lastImport")) else { return }
        do {
            let stored = try JSONDecoder().decode(StoredImportBatch.self, from: data)
            guard stored.catalogID == (try importCatalogID(catalog)) else { return }
            guard Set(stored.photoIDs).count == stored.photoIDs.count, !stored.photoIDs.contains(where: \.isEmpty) else {
                throw LRCError(L10n.text("app.invalidMembershipRecord", defaultValue: "Invalid membership record"))
            }
            let ids = try catalog.resultIDs(PhotoQuery(), within: Set(stored.photoIDs))
            guard !ids.isEmpty else { return }
            lastImport = ImportBatch(snapshotID: try catalog.snapshotPhotos(ids), photoIDs: ids, cancelled: stored.cancelled)
        } catch {
            reports.append(L10n.text("app.cannotReadTheLastImportRecordTheOriginalRecord", defaultValue: "Cannot read the last import record. The original record was preserved: ") + error.localizedDescription)
        }
    }
    /// Remember only an import that actually added photos, independently of the current query.
    func completeImport(ids: Set<String>, cancelled: Bool) throws {
        guard let catalog else { return }
        restoreLastImportIfNeeded()
        if importBrowseContext != nil { try restoreImportBrowsing() }
        showImportCompletion = false
        let imported = try catalog.resultIDs(PhotoQuery(), within: ids)
        guard !imported.isEmpty else { return }
        let stored = try importPreferences.map { _ in
            try JSONEncoder().encode(StoredImportBatch(catalogID: importCatalogID(catalog), photoIDs: imported.sorted(), cancelled: cancelled))
        }
        let snapshotID = try catalog.snapshotPhotos(imported)
        do {
            if let previous = lastImport { try catalog.releaseResults(previous.snapshotID) }
        } catch {
            try? catalog.releaseResults(snapshotID)
            throw error
        }
        lastImport = ImportBatch(snapshotID: snapshotID, photoIDs: imported, cancelled: cancelled)
        if let stored { importPreferences?.set(stored, forKey: workspaceKey("lastImport")) }
        showImportCompletion = true
    }
    func showLastImport(startCulling: Bool = false) {
        guard workspaceAvailable, let batch = lastImport, !batch.photoIDs.isEmpty, commitRecipe() else { return }
        if editMode, !selectDevelopTool(.adjust) { return }
        perform {
            if importBrowseContext == nil {
                importBrowseContext = currentBrowseContext()
                heldResultsID = nil
            } else if let id = heldResultsID {
                try catalog?.releaseResults(id); heldResultsID = nil
            }
            endComparison(); endSurvey()
            scope = batch.scope; relatedBrowseTitle = nil; manualOrderEnabled = false; holdFilterResults = false; filtersEnabled = false
            editMode = false; singleView = startCulling; librarySingleView = startCulling
            fullResolution = false; fillView = false; beforeAfter = .off; pageOffset = 0
            try reloadPhotos()
            let first = photos.first?.id
            choose(first.map { [$0] } ?? [], active: first)
            showImportCompletion = false
            status = L10n.text("app.lastImportPhotosReturnToYourPreviousLocation", defaultValue: "Last import · \(batch.photoIDs.count) photos\(batch.cancelled ? L10n.text("app.importedBeforeCancellation", defaultValue: " (imported before cancellation)") : "") · Return to your previous location")
        }
    }
    func returnFromImport() {
        guard workspaceAvailable, commitRecipe() else { return }
        if editMode, !selectDevelopTool(.adjust) { return }
        perform { try restoreImportBrowsing(); status = L10n.text("app.returnedToYourPreviousLocation", defaultValue: "Returned to your previous location") }
    }
    private func restoreImportBrowsing() throws {
        guard var original = importBrowseContext, let catalog else { return }
        if let id = heldResultsID { try catalog.releaseResults(id) }
        if !browseSourceExists(original) {
            if let id = original.heldID { try catalog.releaseResults(id) }
            original.scope = "all"; original.heldID = nil; original.manualOrder = false
        }
        heldResultsID = nil; importBrowseContext = nil
        try restoreBrowseContext(original)
    }
    func scan(_ root: StorageRoot) {
        guard !busy, let catalog else { return }
        busy = true; status = L10n.text("app.scanning", defaultValue: "Scanning \(root.label)")
        task = Task {
            let report = await importer.scan(root: root, catalog: catalog) { [self] count in
                await MainActor.run { status = L10n.text("app.checkedPhotos", defaultValue: "Checked \(count) photos") }
            }
            perform { try reload() }
            status = L10n.text("app.checkedUnsupportedOrIgnoredErrors", defaultValue: "\(report.cancelled ? L10n.text("app.cancelled", defaultValue: "Cancelled") : L10n.text("app.scanComplete", defaultValue: "Scan complete")) · Checked \(report.indexed) · Unsupported or ignored \(report.ignored) · \(report.errors.count) errors")
            reports = report.errors
            busy = false
        }
    }
    /// `advance` moves on to the next photo unless the filter already hid the marked one and chose its neighbour.
    func organize(rating: Int? = nil, flag: Int? = nil, colorLabel: Int? = nil, advance: Bool? = nil) {
        updateOrganization(advance: advance ?? autoAdvance) { catalog, old in
            try catalog.setOrganization(ids: old.map(\.id), rating: rating, flag: flag, colorLabel: colorLabel)
            return Self.organizationNotice(rating: rating, flag: flag, colorLabel: colorLabel, count: old.count)
        }
    }
    func stepRating(_ delta: Int, advance: Bool? = nil) {
        updateOrganization(advance: advance ?? autoAdvance) { catalog, old in
            let ratings = Dictionary(uniqueKeysWithValues: old.map { ($0.id, max(0, min(5, $0.rating + delta))) })
            try catalog.setRatings(ratings)
            if old.count == 1, let rating = ratings.values.first { return Self.organizationNotice(rating: rating, flag: nil, count: 1) }
            return L10n.text("app.ratingPhotos", defaultValue: "Rating \(delta > 0 ? "+" : "−")\(abs(delta)) · \(old.count) photos")
        }
    }
    /// Repeating a lit state clears it; a mixed selection receives one explicit state.
    func toggleFlag(_ value: Int = 1, advance: Bool? = nil) {
        organize(flag: selectedFlag == value ? 0 : value, advance: advance)
    }
    func toggleColorLabel(_ value: Int, advance: Bool? = nil) {
        guard PhotoColorLabel(rawValue: value) != nil else { return }
        organize(colorLabel: selectedColorLabel == value ? 0 : value, advance: advance)
    }
    func toggleColorLabelFilter(_ value: Int) {
        guard PhotoColorLabel(rawValue: value) != nil else { return }
        let wasEnabled = isFilterSectionActive(.attribute)
        prepareFilterSection(.attribute)
        if !wasEnabled { colorLabelFilter = [value]; filterChanged() }
        else if colorLabelFilter.contains(value) { colorLabelFilter.remove(value) }
        else { colorLabelFilter.insert(value) }
    }
    func toggleRating(_ value: Int) { organize(rating: selectedRating == value ? 0 : value) }
    func toggleRatingFilter(_ value: Int) {
        guard (1...5).contains(value) else { return }
        ratingThreshold = ratingThreshold == value ? 0 : value
    }
    func toggleFlagFilter(_ value: Int) {
        let wasEnabled = isFilterSectionActive(.attribute)
        prepareFilterSection(.attribute)
        if !wasEnabled { flagFilter = [value]; filterChanged() }
        else if flagFilter.contains(value) { flagFilter.remove(value) }
        else { flagFilter.insert(value) }
    }
    func filterCriteriaChanged() {
        // SwiftUI delivers individual onChange callbacks after a restored context has
        // already been reloaded. Do not refresh its held membership or reset its page.
        guard query != lastAppliedQuery || holdFilterResults != lastAppliedHold else { return }
        filterChanged()
    }
    func toggleFilters() { filtersEnabled.toggle(); filterChanged() }
    var organizationIDs: Set<String> { survey == nil ? selection : Set(activeID.map { [$0] } ?? []) }
    private func reloadOrganizationSummary() throws {
        try reloadTargetCollectionState()
        guard let catalog, !selection.isEmpty else { selectedFlag = nil; selectedRating = nil; selectedColorLabel = nil; return }
        let marks = organizationIDs.map { _ in "?" }.joined(separator: ",")
        guard !marks.isEmpty else { selectedFlag = nil; selectedRating = nil; selectedColorLabel = nil; return }
        let summary = try catalog.database.read { db in
            try Row.fetchOne(db, sql: "SELECT count(DISTINCT flag) AS flags, min(flag) AS flag, count(DISTINCT rating) AS ratings, min(rating) AS rating, count(DISTINCT colorLabel) AS colors, min(colorLabel) AS colorLabel FROM photo WHERE deleted=0 AND id IN (\(marks))", arguments: StatementArguments(organizationIDs))
        }
        selectedFlag = summary.flatMap { ($0["flags"] as Int) == 1 ? $0["flag"] as Int? : nil }
        selectedColorLabel = summary.flatMap { ($0["colors"] as Int) == 1 ? $0["colorLabel"] as Int? : nil }
        selectedRating = summary.flatMap { ($0["ratings"] as Int) == 1 ? $0["rating"] as Int? : nil }
    }
    static func organizationNotice(rating: Int?, flag: Int?, colorLabel: Int? = nil, count: Int) -> String {
        var parts: [String] = []
        if let rating { parts.append(rating == 0 ? L10n.text("app.clearRating", defaultValue: "Clear Rating") : String(repeating: "★", count: rating) + L10n.text("app.stars", defaultValue: " \(rating) stars")) }
        if let flag { parts.append(flag == 1 ? L10n.text("app.pick", defaultValue: "Pick") : flag == -1 ? L10n.text("app.reject", defaultValue: "Reject") : L10n.text("app.unflagged", defaultValue: "Unflagged")) }
        if let colorLabel, let label = PhotoColorLabel(rawValue: colorLabel) { parts.append(label.title) }
        if count > 1 { parts.append(L10n.text("app.photos", defaultValue: "\(count) photos")) }
        return parts.joined(separator: " · ")
    }
    private func updateOrganization(advance: Bool, write: (CatalogStore, [Photo]) throws -> String) {
        guard workspaceAvailable, let catalog, !selection.isEmpty, commitRecipe() else { return }
        perform {
            let previousIndex = photos.firstIndex { $0.id == activeID } ?? 0
            let previousActive = activeID
            let old = try catalog.photos(ids: organizationIDs)
            let text = try write(catalog, old)
            undo.registerUndo(withTarget: self) { target in target.restoreOrganization(old) }
            undo.setActionName(L10n.text("app.ratingAndFlags", defaultValue: "Rating and Flags"))
            try reloadPhotos(); reconcileVisibleSelection(preferredIndex: previousIndex)
            status = L10n.text("app.savedRatingsAndFlagsForPhotos", defaultValue: "Saved ratings and flags for \(old.count) photos")
            showNotice(text)
            if advance, activeID == previousActive { move(1) }
        }
    }
    func showNotice(_ text: String) {
        let next = WorkspaceNotice(text: text)
        notice = next
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, self.notice?.id == next.id else { return }
            self.notice = nil
        }
        if let app = NSApp {
            NSAccessibility.post(element: app, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    private func restoreOrganization(_ old: [Photo]) {
        guard let catalog else { return }
        perform {
            let current = try catalog.photos(ids: Set(old.map(\.id)))
            try catalog.database.write { db in
                for photo in old { try db.execute(sql: "UPDATE photo SET rating=?,flag=?,colorLabel=? WHERE id=?", arguments: [photo.rating, photo.flag, photo.colorLabel, photo.id]) }
            }
            undo.registerUndo(withTarget: self) { $0.restoreOrganization(current) }
            try reloadPhotos(); reconcileVisibleSelection()
        }
    }
    func reloadKeywords() throws {
        keywords = try catalog?.keywordSummary(selected: selection) ?? []
        if recentKeywordCatalog != catalog?.fileURL.path {
            recentKeywordCatalog = catalog?.fileURL.path
            recentKeywords = usesPreferences && catalog != nil ? UserDefaults.standard.stringArray(forKey: workspaceKey("recentKeywords")) ?? [] : []
        }
        try reloadOrganizationSummary()
    }
    @discardableResult func changeKeyword(_ name: String, adding: Bool) -> Bool {
        changeKeywords([name], adding: adding)
    }
    @discardableResult func changeKeywords(_ names: [String], adding: Bool) -> Bool {
        var succeeded = false
        guard !applyingAdjustments, !selection.isEmpty, let catalog, commitRecipe() else { return false }
        perform {
            let previousIndex = photos.firstIndex { $0.id == activeID } ?? 0
            let previous = try catalog.changeKeywords(names, ids: selection, adding: adding)
            succeeded = true
            if adding {
                let keys = Set(names.map { KeywordSummary.key($0) })
                recentKeywords = Array((names + recentKeywords.filter { !keys.contains(KeywordSummary.key($0)) }).prefix(12))
                if usesPreferences { UserDefaults.standard.set(recentKeywords, forKey: workspaceKey("recentKeywords")) }
            }
            guard !previous.isEmpty else { return }
            undo.registerUndo(withTarget: self) { $0.restoreKeywordState(previous) }
            undo.setActionName(adding ? L10n.text("app.addKeywords", defaultValue: "Add Keywords") : L10n.text("app.removeKeywords", defaultValue: "Remove Keywords"))
            try reloadPhotos(); try reloadKeywords(); reconcileVisibleSelection(preferredIndex: previousIndex)
            status = L10n.text("app.keywordsForPhotos", defaultValue: "\(adding ? L10n.text("app.added", defaultValue: "Added") : L10n.text("app.removed", defaultValue: "Removed")) keywords for \(previous.count) photos")
        }
        return succeeded
    }
    func renameKeyword(_ state: KeywordNameState, to name: String, catalogPath: String) throws {
        guard workspaceAvailable, let catalog, catalog.fileURL.path == catalogPath, commitRecipe() else { throw LRCError(L10n.text("app.theWorkspaceChangedTheKeywordWasNotRenamed", defaultValue: "The workspace changed. The keyword was not renamed")) }
        let replacement = try catalog.renameKeyword(state, to: name)
        guard replacement != state else { return }
        undo.registerUndo(withTarget: self) { $0.restoreKeywordRename(from: replacement, to: state) }
        undo.setActionName(L10n.text("app.renameKeywordInCatalog", defaultValue: "Rename Keyword in Catalog"))
        try followKeywordRename(from: state, to: replacement)
        status = L10n.text("app.renamedThroughoutTheCatalogPhotoVersions", defaultValue: "Renamed throughout the catalog · \(state.names.count) photo versions")
    }
    private func restoreKeywordRename(from expected: KeywordNameState, to replacement: KeywordNameState) {
        guard workspaceAvailable, let catalog else { return }
        perform {
            try catalog.restoreKeywordName(from: expected, to: replacement)
            undo.registerUndo(withTarget: self) { $0.restoreKeywordRename(from: replacement, to: expected) }
            try followKeywordRename(from: expected, to: replacement)
        }
    }
    private func followKeywordRename(from old: KeywordNameState, to new: KeywordNameState) throws {
        let previousIndex = photos.firstIndex { $0.id == activeID } ?? 0
        if KeywordSummary.key(keywordFilter) == old.key { keywordFilter = new.key }
        // Recent names follow the word in place; normalize duplicates without
        // dropping unrelated entries (including later additions during undo).
        var seen = Set<String>()
        recentKeywords = recentKeywords.map { KeywordSummary.key($0) == old.key ? new.name : $0 }
            .filter { seen.insert(KeywordSummary.key($0)).inserted }
        if usesPreferences { UserDefaults.standard.set(recentKeywords, forKey: workspaceKey("recentKeywords")) }
        try reloadKeywords(); try reloadPhotos(); reconcileVisibleSelection(preferredIndex: previousIndex)
    }
    private func restoreKeywordState(_ states: [String: [String]]) {
        guard !applyingAdjustments, let catalog else { return }
        perform {
            let inverse = try catalog.restoreKeywords(states)
            undo.registerUndo(withTarget: self) { $0.restoreKeywordState(inverse) }
            try reloadPhotos(); try reloadKeywords(); reconcileVisibleSelection()
        }
    }
    @discardableResult
    func changeCaption(_ value: String, ids: Set<String>, catalogPath: String) -> Bool {
        guard workspaceAvailable, ids == selection, !ids.isEmpty, let catalog,
              catalog.fileURL.path == catalogPath, commitRecipe() else { return false }
        do {
            let previous = try catalog.setCaptions(Dictionary(uniqueKeysWithValues: ids.map { ($0, value) }))
            if !previous.isEmpty {
                undo.registerUndo(withTarget: self) { $0.restoreCaptions(previous) }
                undo.setActionName(L10n.text("app.editCaption", defaultValue: "Edit Caption"))
                try reloadPhotos()
                status = L10n.text("app.updatedCaptionsForPhotos", defaultValue: "Updated captions for \(previous.count) photos")
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func restoreCaptions(_ values: [String: String]) {
        guard !busy, !applyingAdjustments, let catalog else { return }
        perform {
            let inverse = try catalog.setCaptions(values)
            undo.registerUndo(withTarget: self) { $0.restoreCaptions(inverse) }
            try reloadPhotos()
        }
    }
    func makeCollection(name: String, id: String? = nil) {
        perform { try catalog?.collection(name: name, id: id); try reload() }
    }
    func deleteCollection(_ id: String) {
        guard workspaceAvailable, let catalog else { return }
        do { setCollectionPresence(try catalog.collectionContents(id), present: false, catalog: catalog) }
        catch { self.error = error.localizedDescription }
    }
    private func setCollectionPresence(_ contents: CollectionContents, present: Bool, catalog expectedCatalog: CatalogStore,
                                       restoringTargets: (target: String?, quick: String?)? = nil,
                                       expectingTargets: (target: String?, quick: String?)? = nil) {
        guard workspaceAvailable, let catalog, catalog === expectedCatalog else { return }
        let id = contents.collection.id
        guard present || scope != "collection:" + id || commitRecipe() else { return }
        perform {
            let previousTargets = (target: targetCollectionID, quick: quickCollectionID)
            if present { try catalog.restoreCollection(contents) }
            else { try catalog.deleteCollection(id, expecting: contents) }
            // Keep a recovery action even if a subsequent UI refresh fails.
            defer {
                let currentTargets = (target: targetCollectionID, quick: quickCollectionID)
                undo.registerUndo(withTarget: self) { target in
                    target.setCollectionPresence(contents, present: !present, catalog: expectedCatalog,
                                                 restoringTargets: previousTargets, expectingTargets: currentTargets)
                }
                undo.setActionName(L10n.text("app.deleteCollection", defaultValue: "Delete Collection"))
            }
            if !present, scope == "collection:" + id { setScope("all") }
            try reload()
            if let restoringTargets, let expectingTargets,
               previousTargets.target == expectingTargets.target, previousTargets.quick == expectingTargets.quick {
                targetCollectionID = restoringTargets.target; quickCollectionID = restoringTargets.quick
                try reloadTargetCollectionState()
            }
            status = present ? L10n.text("app.restoredCollectionAndItsMemberOrder", defaultValue: "Restored collection “\(contents.collection.name)” and its member order") : L10n.text("app.deletedCollectionPhotosWerePreservedYouCanUndoThis", defaultValue: "Deleted collection “\(contents.collection.name)”. Photos were preserved; you can undo this")
        }
    }
    var regularCollectionID: String? {
        collections.first { "collection:" + $0.id == scope && !$0.isSmart }?.id
    }
    func setManualCollectionOrder(_ enabled: Bool) {
        guard workspaceAvailable, !enabled || regularCollectionID != nil, commitRecipe() else { return }
        manualOrderEnabled = enabled
        filterChanged()
    }
    var collectionOrdering: CollectionOrdering? {
        guard manualOrderEnabled, let collection = regularCollectionID, let catalog else { return nil }
        let expected = query
        let token = CollectionOrderingToken(catalogPath: catalog.fileURL.path, querySignature: expected.orderingQuerySignature)
        return CollectionOrdering(enabled: workspaceAvailable, token: token) { [weak self, weak catalog] ids, before in
            guard let self, let catalog, self.catalog === catalog, self.workspaceAvailable,
                  self.manualOrderEnabled, self.regularCollectionID == collection,
                  self.query == expected, self.commitRecipe() else { return false }
            do {
                let requested = Set(ids)
                guard !requested.isEmpty, try catalog.resultIDs(expected, within: requested) == requested else { return false }
                if let before, !(try catalog.resultIDs(expected, within: [before])).contains(before) { return false }
                let old = try catalog.reorderCollection(collection, moving: ids, before: before)
                let new = try catalog.collectionOrder(collection)
                guard old != new else { return true }
                self.undo.registerUndo(withTarget: self) { $0.restoreCollectionOrder(collection, order: old) }
                self.undo.setActionName(L10n.text("app.reorderCollection", defaultValue: "Reorder Collection"))
                try self.refreshCollectionOrder()
                self.showNotice(L10n.text("app.collectionReorderedUndoAvailable", defaultValue: "Collection reordered · Undo available"))
                return true
            } catch { self.error = error.localizedDescription; return false }
        }
    }
    private func refreshCollectionOrder() throws {
        guard let catalog else { return }
        let selected = selection, active = activeID
        if let held = heldResultsID, manualOrderEnabled {
            // Reorder the held members, without admitting new matches or
            // dropping members whose rating changed during a culling pass.
            let frozen = query, (predicate, args) = frozen.predicate
            var liveOrder = frozen; liveOrder.snapshotID = nil
            let next = UUID().uuidString
            try catalog.database.write { db in
                try db.execute(sql: "INSERT INTO temp.browseSnapshot SELECT ?,photo.id,row_number() OVER (ORDER BY " + liveOrder.order + ") FROM " + frozen.relation + " WHERE " + predicate, arguments: [next] + args)
                try db.execute(sql: "DELETE FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [held])
            }
            heldResultsID = next
        }
        if let active, let offset = try catalog.offset(of: active, query: query) { pageOffset = offset / pageSize * pageSize }
        try reloadPhotos()
        let retained = try catalog.resultIDs(query, within: selected)
        choose(retained, active: active)
    }
    private func restoreCollectionOrder(_ collection: String, order: [String]) {
        guard workspaceAvailable, let catalog, commitRecipe() else { return }
        perform {
            let inverse = try catalog.restoreCollectionOrder(collection, order: order)
            undo.registerUndo(withTarget: self) { $0.restoreCollectionOrder(collection, order: inverse) }
            try refreshCollectionOrder()
        }
    }
    var targetCollection: PhotoCollection? { collections.first { $0.id == targetCollectionID && !$0.isSmart } }
    var quickCollectIDs: Set<String> { workspaceMode == .grid ? selection : Set(activeID.map { [$0] } ?? []) }
    var quickCollectMembership: Bool? {
        let count = quickCollectIDs.intersection(targetMemberIDs).count
        return count == 0 ? false : count == quickCollectIDs.count ? true : nil
    }
    var quickCollectScope: String { workspaceMode == .grid ? L10n.text("app.selectedPhotos", defaultValue: "\(quickCollectIDs.count) selected photos") : L10n.text("app.currentPhoto", defaultValue: "Current Photo") }
    private func persistTargetCollection() {
        guard usesPreferences else { return }
        UserDefaults.standard.set(targetCollectionID, forKey: workspaceKey("targetCollection"))
        UserDefaults.standard.set(quickCollectionID, forKey: workspaceKey("quickCollection"))
    }
    private func reloadTargetCollectionState() throws {
        guard targetCatalogPath == catalog?.fileURL.path else { targetMemberIDs = []; return }
        if !collections.contains(where: { $0.id == quickCollectionID && !$0.isSmart }) { quickCollectionID = nil }
        if targetCollection == nil { targetCollectionID = quickCollectionID }
        persistTargetCollection()
        targetMemberIDs = try targetCollectionID.flatMap { try catalog?.members($0, within: selection.union(activeID.map { [$0] } ?? [])) } ?? []
    }
    func setTargetCollection(_ id: String?) {
        guard workspaceAvailable, id == nil || collections.contains(where: { $0.id == id && !$0.isSmart }) else { return }
        targetCollectionID = id ?? quickCollectionID
        perform { try reloadTargetCollectionState() }
        status = L10n.text("app.quickCollectionTarget", defaultValue: "Quick Collection target · ") + (targetCollection?.name ?? L10n.text("app.quickCollectionCreatedOnFirstUse", defaultValue: "Quick Collection (created on first use)"))
    }
    func toggleQuickCollection() {
        guard workspaceAvailable, let catalog, !quickCollectIDs.isEmpty, commitRecipe() else { return }
        perform {
            let ids = quickCollectIDs
            if targetCollection == nil {
                let id = UUID().uuidString
                try catalog.collection(name: L10n.text("app.quickCollection", defaultValue: "Quick Collection"), id: id)
                quickCollectionID = id; targetCollectionID = id
                collections = try catalog.collections(); persistTargetCollection()
            }
            guard let target = targetCollection else { return }
            let present = try catalog.members(target.id, within: ids)
            let add = present.count != ids.count
            if restoreMembership(Dictionary(uniqueKeysWithValues: ids.map { ($0, add) }), collection: target.id) {
                status = L10n.text("app.photos_71", defaultValue: "\(add ? L10n.text("app.addTo", defaultValue: "Add to") : L10n.text("app.removeFrom", defaultValue: "Remove from")) \(target.name) · \(ids.count) photos")
                showNotice(status)
            }
        }
    }
    func membership(_ collection: String, add: Bool) {
        guard !applyingAdjustments, !selection.isEmpty, commitRecipe() else { return }
        restoreMembership(Dictionary(uniqueKeysWithValues: selection.map { ($0,add) }),collection:collection)
    }
    @discardableResult private func restoreMembership(_ states: [String: Bool], collection: String, order: [String]? = nil) -> Bool {
        guard let catalog, commitRecipe() else { return false }
        var succeeded = false
        perform {
            let previousIndex = photos.firstIndex { $0.id == activeID } ?? 0
            let desired: [String]?
            if let order { desired = order }
            else {
                let old = try catalog.collectionOrder(collection), previous = Set(old)
                let added = Set(states.filter { $0.value && !previous.contains($0.key) }.map(\.key))
                let visible = try catalog.exportPhotos(ids: added, query: query).map(\.id)
                desired = old.filter { states[$0] != false } + visible + added.subtracting(visible).sorted()
            }
            let change = try catalog.restoreOrderedMembership(states, collection: collection, order: desired)
            if change.changed {
                undo.registerUndo(withTarget:self) { $0.restoreMembership(change.inverse,collection:collection,order:change.previousOrder) }
                undo.setActionName(L10n.text("app.collectionMembers", defaultValue: "Collection Members"))
            }
            try reloadPhotos(); reconcileVisibleSelection(preferredIndex:previousIndex)
            succeeded = true
        }
        return succeeded
    }
    func collectResults(collection: String? = nil, newName: String? = nil) {
        guard let catalog else { return }
        perform {
            let count = try catalog.collectResults(query, collection: collection ?? UUID().uuidString, newName: newName)
            collections = try catalog.collections()
            status = L10n.text("app.addedResultsToCollectionNewPhotosResultsAcrossAll", defaultValue: "Added results to collection · \(count) new photos (\(resultCount) results across all pages)")
        }
    }
    func retryPhotoLoad() {
        guard workspaceAvailable, !canEdit, !loadingPhoto, active != nil, comparison == nil, survey == nil else { return }
        loadActive()
    }
    private func loadActive() {
        previewTask?.cancel(); previewGeneration = UUID(); pendingPreview = nil; pendingQualityPreview = nil; qualityRender?.cancel()
        interactivePreview = false; previewCurrent = false
        loadingPhoto = false
        guard comparison == nil, survey == nil else { photoSwitchDisplay = nil; return }
        let token = previewGeneration
        guard let photo = active, let root = roots.first(where: { $0.id == photo.rootID }) else { photoSwitchDisplay = nil; imageStatus = L10n.text("app.noPhotoSelected", defaultValue: "No photo selected"); return }
        imageStatus = L10n.text("app.loadingPhoto", defaultValue: "Loading photo…")
        loadingPhoto = true
        previewTask = Task {
            do {
                if photo.metadata == nil, let catalog {
                    try await importer.refreshMetadata(photo: photo, root: root, catalog: catalog)
                    guard token == previewGeneration, !Task.isCancelled else { return }
                    try reloadPhotos()
                }
                var value: EditRecipe?
                if let data = photo.recipe { value = try JSONDecoder().decode(EditRecipe.self, from: data); try value?.validate(for: photo) }
                else if photo.supportsEditing { value = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil)) }
                let defaults = photo.isRAW ? try await pipeline.rawDefaults(ImageRequest(photo: photo, root: root, recipe: value)) : nil
                guard token == previewGeneration, !Task.isCancelled else { return }
                if photo.recipe == nil, let value {
                    try catalog?.saveRecipe(id: photo.id, recipe: value)
                    try reloadPhotos(); try reloadEditContext()
                }
                rawDefaults = defaults; recipe = value; savedRecipe = value; dirty = false
                requestPreview(prepareInteractive: photo.supportsEditing)
            } catch { if token == previewGeneration { photoSwitchDisplay = nil; loadingPhoto = false; imageStatus = error.localizedDescription } }
        }
    }
    func changeRecipe(_ mutation: (inout EditRecipe) -> Void, commit: Bool = true, title: String? = nil, preview: Bool = true) {
        guard canEdit, !applyingAdjustments, var value = recipe else { return }
        let started = CFAbsoluteTimeGetCurrent()
        mutation(&value)
        value.schemaVersion = max(value.schemaVersion, value.localAdjustments.isEmpty ? 2 : 3)
        if value.localAdjustments.contains(where: { $0.settings != nil }) { value.maskVersion = 2 }
        if value.localAdjustments.contains(where: { $0.components.contains(where: { $0.raster != nil }) }) { value.maskVersion = 3 }
        do {
            if let photo = active { try value.validate(for: photo) }
            else { try value.validate() }
            if value.rawDetails != recipe?.rawDetails, let rawDefaults { try value.rawDetails.checkSupport(rawDefaults) }
            if let size = orientedSourceSize { _ = try PhotoGeometry(size: size, recipe: value) }
        } catch { self.error = error.localizedDescription; return }
        PreviewLog.logger.debug("recipe-validated ms=\((CFAbsoluteTimeGetCurrent() - started) * 1000)")
        guard value != recipe else { return }
        clearSavedEditPreview()
        endAdjustmentPreview(redraw: false)
        endMaskEffectPreview(redraw: false)
        recipe = value; dirty = true; before = false
        if commit {
            if !commitRecipe(title: title), preview { requestPreview() }
        } else if preview { requestPreview(interactive: true) }
    }
    @discardableResult func commitRecipe(title: String? = nil) -> Bool {
        endAdjustmentPreview(redraw: false)
        guard dirty else { return true }
        guard let catalog, let id = activeID, let value = recipe else { return false }
        do {
            let started = CFAbsoluteTimeGetCurrent()
            try catalog.saveRecipe(id: id, recipe: value, title: title)
            PreviewLog.logger.debug("recipe-saved ms=\((CFAbsoluteTimeGetCurrent() - started) * 1000)")
            if let previous = savedRecipe {
                undo.registerUndo(withTarget: self) { $0.restoreRecipe(previous, id: id) }
                undo.setActionName(L10n.text("app.adjustPhoto", defaultValue: "Adjust Photo"))
            }
            let refreshed = CFAbsoluteTimeGetCurrent()
            savedRecipe = value; dirty = false; try reloadSavedRecipe(id: id); try reloadEditHistory(keepingLoaded: true); status = L10n.text("app.adjustmentsSaved", defaultValue: "Adjustments saved")
            PreviewLog.logger.debug("recipe-refreshed ms=\((CFAbsoluteTimeGetCurrent() - refreshed) * 1000)")
            if spotMode { prepareSpotRank() }
            requestPreview(prepareInteractive: true)
            return true
        } catch { self.error = L10n.text("app.saveFailedYourDraftWasPreserved", defaultValue: "Save failed. Your draft was preserved: \(error.localizedDescription)"); return false }
    }
    private func restoreRecipe(_ value: EditRecipe, id: String) {
        guard !applyingAdjustments, let catalog else { return }
        perform {
            guard let photo = try catalog.photo(id), let data = photo.recipe else { return }
            let current = try JSONDecoder().decode(EditRecipe.self, from: data)
            try catalog.saveRecipe(id: id, recipe: value, title: undo.isRedoing ? L10n.text("app.redoAdjustment", defaultValue: "Redo Adjustment") : L10n.text("app.undoAdjustment", defaultValue: "Undo Adjustment"))
            undo.registerUndo(withTarget: self) { $0.restoreRecipe(current, id: id) }
            try reloadSavedRecipe(id: id); try reloadEditHistory(keepingLoaded: true)
            if id == activeID { recipe = value; savedRecipe = value; dirty = false; requestPreview(); if spotMode { prepareSpotRank() } }
        }
    }
    private func reloadSavedRecipe(id: String) throws {
        guard let catalog else { return }
        if comparison != nil || survey != nil { try reloadPhotos(); return }
        // Recipe changes do not affect query membership, order, stacks or organization counts.
        guard let photo = try catalog.photo(id) else { throw LRCError(L10n.text("app.thePhotoIsNoLongerInTheCatalog", defaultValue: "The photo is no longer in the catalog")) }
        if let index = photos.firstIndex(where: { $0.id == id }) { photos[index] = photo }
        if activeID == id { activePhoto = photo }
        try refreshDevelopReference()
    }
    private func reloadEditHistory(keepingLoaded: Bool = false) throws {
        guard let catalog, let id = activeID else { editHistory = []; hasMoreHistory = false; return }
        if keepingLoaded, let first = editHistory.first, first.photoID == id {
            let added = try catalog.editHistory(photoID: id, limit: historyLimit + 1, afterID: first.id)
            guard !added.isEmpty else { return }
            let combined = added + editHistory
            hasMoreHistory = hasMoreHistory || combined.count > historyLimit
            editHistory = Array(combined.prefix(historyLimit))
            return
        }
        let rows = try catalog.editHistory(photoID: id, limit: historyLimit + 1)
        hasMoreHistory = rows.count > historyLimit
        editHistory = Array(rows.prefix(historyLimit))
    }
    func reloadEditContext() throws {
        try reloadEditHistory()
        guard let catalog, let id = activeID else { editSnapshots = []; return }
        editSnapshots = try catalog.snapshots(photoID: id)
    }
    func loadMoreHistory() {
        historyLimit += 100
        perform { try reloadEditContext() }
    }
    @discardableResult func saveSnapshot(name: String, replacingID: String? = nil) -> Bool {
        guard canEdit, let id = activeID, let catalog, commitRecipe() else { return false }
        do {
            if let replacingID { try catalog.renameSnapshot(id: replacingID, photoID: id, title: name) }
            else { try catalog.createSnapshot(photoID: id, title: name) }
            try reloadEditContext(); status = replacingID == nil ? L10n.text("app.snapshotSaved", defaultValue: "Snapshot saved") : L10n.text("app.snapshotRenamed", defaultValue: "Snapshot renamed")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteSnapshot(_ snapshot: EditSnapshot) {
        guard workspaceAvailable, canEdit, snapshot.photoID == activeID, let catalog else { return }
        setSnapshotPresence(snapshot, present: false, catalog: catalog)
    }
    private func setSnapshotPresence(_ snapshot: EditSnapshot, present: Bool, catalog expectedCatalog: CatalogStore) {
        guard workspaceAvailable, let catalog, catalog === expectedCatalog else { return }
        perform {
            if present { try catalog.restoreSnapshot(snapshot) }
            else { try catalog.deleteSnapshot(snapshot); clearSavedEditPreview(key: "snapshot:" + snapshot.id) }
            // Snapshot metadata never commits the current recipe draft. A comparison
            // reference already owns its frozen recipe and remains usable after deletion.
            undo.registerUndo(withTarget: self) { $0.setSnapshotPresence(snapshot, present: !present, catalog: expectedCatalog) }
            undo.setActionName(L10n.text("app.deleteSnapshot", defaultValue: "Delete Snapshot"))
            try reloadEditContext()
            status = present ? L10n.text("app.restoredSnapshot", defaultValue: "Restored snapshot “\(snapshot.title)”") : L10n.text("app.deletedSnapshotUndoAvailable", defaultValue: "Deleted snapshot “\(snapshot.title)” · Undo available")
        }
    }
    func applySavedEdit(data: Data, photoID: String, title: String) {
        guard canEdit, photoID == activeID, commitRecipe() else { return }
        perform {
            let value = try JSONDecoder().decode(EditRecipe.self, from: data)
            try value.validate()
            guard value.sourceDigest == recipe?.sourceDigest else { throw LRCError(L10n.text("app.thePhotoSourceChangedThisAdjustmentCannotBeRestored", defaultValue: "The photo source changed. This adjustment cannot be restored")) }
            changeRecipe({ $0 = value }, title: title)
        }
    }
    private func validatedSavedEdit(data: Data, photoID: String) throws -> EditRecipe {
        guard let photo = active, photo.id == photoID, let current = recipe else { throw LRCError(L10n.text("app.selectTheCorrespondingPhotoFirst", defaultValue: "Select the corresponding photo first")) }
        let value = try JSONDecoder().decode(EditRecipe.self, from: data)
        try value.validate(for: photo)
        guard value.sourceDigest == current.sourceDigest, photo.digest == nil || photo.digest == value.sourceDigest else { throw LRCError(L10n.text("app.thePhotoSourceChangedThisAdjustmentCannotBeUsed", defaultValue: "The photo source changed. This adjustment cannot be used")) }
        return value
    }
    func previewSavedEdit(data: Data, photoID: String, key: String, title: String) {
        guard workspaceAvailable, editMode, canEdit, key != savedEditPreviewKey else { return }
        endAdjustmentPreview()
        clearSavedEditPreview()
        let preview = ComparisonPhoto(), render = renderPreview
        savedEditPreviewKey = key; savedEditPreviewTitle = title; savedEditPreview = preview
        do {
            let value = try validatedSavedEdit(data: data, photoID: photoID)
            guard var photo = active, let root = roots.first(where: { $0.id == photo.rootID }) else { preview.status = L10n.text("app.cannotFindThePhotoSource", defaultValue: "Cannot find the photo source"); return }
            photo.recipe = try JSONEncoder().encode(value)
            preview.photo = photo; preview.root = root
            preview.load { request, _ in try await render(request, false, 480) }
        } catch { preview.status = error.localizedDescription }
    }
    func clearSavedEditPreview(key: String? = nil) {
        guard key == nil || key == savedEditPreviewKey else { return }
        savedEditPreview?.cancel(); savedEditPreview = nil; savedEditPreviewKey = nil; savedEditPreviewTitle = ""
    }
    func setBeforeReference(data: Data, photoID: String, title: String) {
        guard workspaceAvailable, canEdit, canShowBeforeAfter else { return }
        perform {
            let value = try validatedSavedEdit(data: data, photoID: photoID)
            clearSavedEditPreview()
            beforeReference = SavedEditComparison(photoID: photoID, title: title, recipe: value)
            resetBeforeImage()
            if before { requestPreview() }
            else { showBeforeAfter(beforeAfter == .off ? .sideBySide : beforeAfter); refreshBeforeImage() }
            showNotice(L10n.text("app.reference", defaultValue: "Reference · ") + title)
        }
    }
    func resetBeforeReference() {
        beforeReference = nil; resetBeforeImage(); refreshBeforeImage()
        if before { requestPreview() }
    }
    var displayPreviewRecipe: EditRecipe? { adjustmentDisplayRecipe ?? maskEffectPreviewRecipe }
    var isPreviewingAdjustment: Bool { adjustmentDisplayRecipe != nil }
    func previewPreset(_ preset: AdjustmentPreset) {
        guard workspaceAvailable, editMode, developTool == .adjust, canEdit, !before,
              let current = recipe, let photo = active, image != nil,
              previewingPresetID != preset.id else { return }
        do {
            var value = try preset.previewRecipe(on: current)
            if photo.isRAW, let rawDefaults { value.rawDetails = value.rawDetails.supported(by: rawDefaults) }
            try value.validate(for: photo)
            startAdjustmentPreview(recipe: value, title: L10n.text("app.presetPreview", defaultValue: "Preset preview · ") + preset.name, preset: preset.id)
        } catch { showNotice(L10n.text("app.cannotPreviewThisPreset", defaultValue: "Cannot preview this preset: ") + error.localizedDescription) }
    }
    func endPresetPreview(_ presetID: String? = nil) {
        guard previewingPresetID != nil, presetID == nil || previewingPresetID == presetID else { return }
        endAdjustmentPreview()
    }
    func beginDevelopGroupPreview(_ group: DevelopGroup) {
        guard workspaceAvailable, editMode, developTool == .adjust, canEdit, !before,
              group != .crop, group != .perspective, let current = recipe, image != nil,
              group.isModified(in: current), previewingDevelopGroup != group else { return }
        startAdjustmentPreview(recipe: group.previewRecipe(in: current), title: L10n.text("app.temporarilyHidden", defaultValue: "Temporarily hidden · ") + group.title, group: group)
    }
    func endDevelopGroupPreview() {
        guard previewingDevelopGroup != nil else { return }
        endAdjustmentPreview()
    }
    func pulseDevelopGroupPreview(_ group: DevelopGroup) {
        beginDevelopGroupPreview(group)
        guard previewingDevelopGroup == group else { return }
        adjustmentPreviewPulse?.cancel()
        adjustmentPreviewPulse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, self.previewingDevelopGroup == group else { return }
            self.endAdjustmentPreview()
        }
    }
    private func startAdjustmentPreview(recipe value: EditRecipe, title: String, preset: String? = nil, group: DevelopGroup? = nil) {
        guard let id = activeID, let current = recipe else { return }
        adjustmentPreviewPulse?.cancel(); adjustmentPreviewQuality?.cancel()
        if adjustmentDisplayOriginal == nil {
            adjustmentDisplayOriginal = AdjustmentDisplayState(photoID: id, recipe: current, image: image,
                histogram: histogram, nativeSize: renderedNativeSize, sourceSize: orientedSourceSize,
                coordinateRecipe: renderedCoordinateRecipe, interactive: interactivePreview, current: previewCurrent,
                status: imageStatus, spotOffsets: spotRenderedOffsets)
        }
        clearSavedEditPreview(); endMaskEffectPreview(redraw: false)
        previewingPresetID = preset; previewingDevelopGroup = group; adjustmentDisplayRecipe = value
        adjustmentPreviewTitle = title
        previewGeneration = UUID()
        requestPreview(interactive: true)
        // A settled preset gets a quality preview; the held eye remains on
        // the common-mode interactive lane until released.
        if let preset {
            adjustmentPreviewQuality = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.previewingPresetID == preset else { return }
                self.requestPreview()
            }
        }
    }
    func endAdjustmentPreview(redraw: Bool = true) {
        adjustmentPreviewPulse?.cancel(); adjustmentPreviewPulse = nil
        adjustmentPreviewQuality?.cancel(); adjustmentPreviewQuality = nil
        guard isPreviewingAdjustment else { return }
        let original = adjustmentDisplayOriginal; adjustmentDisplayOriginal = nil
        adjustmentDisplayRecipe = nil; previewingPresetID = nil; previewingDevelopGroup = nil; adjustmentPreviewTitle = ""
        previewGeneration = UUID(); pendingPreview = nil; pendingQualityPreview = nil; qualityRender?.cancel()
        wantsInteractivePreview = false
        if let original, original.photoID == activeID, original.recipe == recipe {
            image = original.image; histogram = original.histogram; renderedNativeSize = original.nativeSize
            orientedSourceSize = original.sourceSize; renderedCoordinateRecipe = original.coordinateRecipe
            interactivePreview = original.interactive; previewCurrent = original.current; imageStatus = original.status
            spotRenderedOffsets = original.spotOffsets
        }
        if redraw { requestPreview() }
    }
    /// A display-only recipe. The editable recipe, saved state and export requests never borrow it.
    var maskEffectPreviewRecipe: EditRecipe? {
        guard maskMode, let id = previewingMaskID, var value = recipe,
              let index = value.localAdjustments.firstIndex(where: { $0.id == id }) else { return recipe }
        value.localAdjustments[index].enabled = false
        return value
    }
    func beginMaskEffectPreview(_ id: UUID) {
        guard workspaceAvailable, editMode, canEdit, maskMode, !before,
              let group = selectedMask, group.id == id, group.enabled, !group.isNeutral else { return }
        endAdjustmentPreview(redraw: false)
        maskPreviewPulse?.cancel(); maskPreviewPulse = nil
        guard previewingMaskID != id else { return }
        if let photoID = activeID, let recipe { maskPreviewOriginal = (photoID, recipe, image, histogram) }
        clearSavedEditPreview(); previewingMaskID = id
        requestPreview(interactive: true)
    }
    func endMaskEffectPreview(redraw: Bool = true) {
        maskPreviewPulse?.cancel(); maskPreviewPulse = nil
        guard previewingMaskID != nil else { return }
        previewingMaskID = nil
        let original = maskPreviewOriginal; maskPreviewOriginal = nil
        if redraw {
            if let original, original.photoID == activeID, original.recipe == recipe { image = original.image; histogram = original.histogram }
            requestPreview()
        }
    }
    func pulseMaskEffectPreview(_ id: UUID) {
        beginMaskEffectPreview(id)
        guard previewingMaskID == id else { return }
        maskPreviewPulse = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, self.previewingMaskID == id else { return }
            self.endMaskEffectPreview()
        }
    }
    func createVirtualCopy(data: Data, photoID: String, title: String) {
        guard workspaceAvailable, canEdit, let catalog else { return }
        perform {
            let value = try validatedSavedEdit(data: data, photoID: photoID)
            clearSavedEditPreview()
            let stacks = try catalog.stacks()
            let made = try catalog.createVirtualCopies(ids: [photoID], recipeOverride: value, historyTitle: L10n.text("app.createCopyFrom", defaultValue: "Create Copy from \(title)"))
            undo.registerUndo(withTarget: self) { $0.restoreVersionDeletion(Dictionary(uniqueKeysWithValues: made.map { ($0.id, true) }), stacks: stacks, preserveUnrelatedDraft: true) }
            undo.setActionName(L10n.text("app.createCopyFromHistory", defaultValue: "Create Copy from History"))
            try reload()
            status = L10n.text("app.createdFromCurrentAdjustmentsWerePreserved", defaultValue: "Created \(made.first?.copyName ?? L10n.text("app.copy", defaultValue: "Copy")) from “\(title)”. Current adjustments were preserved")
            showNotice(status)
        }
    }
    func copyAdjustments() {
        guard workspaceAvailable, canEdit, commitRecipe(), let recipe else { return }
        copiedRecipe = recipe; copiedPhotoName = active?.displayName ?? L10n.text("app.photo", defaultValue: "Photo")
        copiedAdjustmentPhoto = activeID.flatMap { try? catalog?.photo($0) } ?? active
        status = L10n.text("app.copiedAdjustmentsFrom", defaultValue: "Copied adjustments from \(copiedPhotoName)")
    }
    var canUsePreviousAdjustments: Bool {
        canEdit && activeID != nil && previousAdjustmentSource != nil && previousAdjustmentSource?.photo.id != activeID
    }
    func requestAdjustments(_ action: AdjustmentAction) {
        guard workspaceAvailable, canEdit, commitRecipe() else { return }
        switch action {
        case .paste: guard copiedRecipe != nil else { return }
        case .sync: guard !selection.subtracting(Set([activeID].compactMap { $0 })).isEmpty else { return }
        case .previous:
            guard canUsePreviousAdjustments else { return }
            if let catalog, let source = previousAdjustmentSource,
               (try? catalog.photo(source.photo.id))?.deleted != false {
                previousAdjustmentSource = nil; error = L10n.text("app.thePreviousPhotoIsNoLongerInThisCatalog", defaultValue: "The previous photo is no longer in this catalog"); return
            }
        case .save, .update, .preset: return
        }
        adjustmentRequest = action
    }
    func confirmAdjustmentOptions(_ options: RecipePasteOptions) {
        guard options.hasSelection else { return }
        confirmedAdjustmentOptions = options
        if let data = try? JSONEncoder().encode(options) { adjustmentPreferences?.set(data, forKey: "confirmedAdjustmentOptions") }
    }

    @discardableResult func pasteAdjustments(options: RecipePasteOptions) -> Bool {
        guard canEdit, options.hasSelection, let copiedRecipe, let recipe, commitRecipe() else { return false }
        do {
            var value = try recipe.pasting(copiedRecipe, options: options)
            var detailNotes: [String] = []
            if options.details, !recipe.isRaster, !copiedRecipe.isRaster {
                guard let rawDefaults else { throw LRCError(L10n.text("app.rawCapabilitiesAreNotReadyTryPastingDetailAdjustments", defaultValue: "RAW capabilities are not ready. Try pasting detail adjustments again shortly")) }
                detailNotes = value.rawDetails.unavailableNames(rawDefaults)
                value.rawDetails = value.rawDetails.supported(by: rawDefaults)
            }
            if let size = orientedSourceSize { _ = try PhotoGeometry(size: size, recipe: value) }
            changeRecipe({ $0 = value }, commit: false)
            let saved = commitRecipe(title: L10n.text("app.pasteAdjustments", defaultValue: "Paste Adjustments"))
            if saved {
                let notes = recipe.transferNotes(from: copiedRecipe, options: options)
                if !notes.isEmpty { status += " · " + notes.joined(separator: "；") }
                if !detailNotes.isEmpty { status += L10n.text("app.unsupportedByTargetSkipped", defaultValue: " · Unsupported by target, skipped: ") + detailNotes.joined(separator: "、") }
            }
            return saved
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func savePreset(name: String, source: EditRecipe, options: RecipePasteOptions) -> Bool {
        guard let catalog, !busy else { return false }
        do {
            try catalog.savePreset(name: name, recipe: source, options: options)
            adjustmentPresets = try catalog.presets(); status = L10n.text("app.presetSavedInTheCurrentCatalog", defaultValue: "Preset saved in the current catalog")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult func applyAdjustments(source: EditRecipe, options: RecipePasteOptions, ids: Set<String>, title: String, amount: Double? = nil) -> Bool {
        guard !busy, options.hasSelection, !ids.isEmpty, let catalog, commitRecipe() else { return false }
        do {
            try source.validate()
            let targets = try catalog.photos(ids: ids)
            guard !targets.isEmpty else { return false }
            busy = true; applyingAdjustments = true; reports = []
            task = Task {
                defer { busy = false; applyingAdjustments = false; taskProgress = nil }
                var changes = [(photo: Photo, recipe: EditRecipe)]()
                var results = [String]()
                var published = false
                do {
                    for (index, photo) in targets.enumerated() {
                        try Task.checkCancellation()
                        taskProgress = TaskProgress(title: title, done: index, total: targets.count)
                        status = L10n.text("app.checking", defaultValue: "\(title) · Checking \(index + 1)/\(targets.count) · \(photo.name)")
                        do {
                            guard photo.supportsEditing else { throw LRCError(L10n.text("app.editingThisFormatIsNotYetSupported", defaultValue: "Editing this format is not yet supported")) }
                            guard let root = roots.first(where: { $0.id == photo.rootID }) else { throw LRCError(L10n.text("app.theOriginalPhotoRootFolderIsMissing", defaultValue: "The original photo root folder is missing")) }
                            let original: EditRecipe
                            if let data = photo.recipe { original = try JSONDecoder().decode(EditRecipe.self, from: data) }
                            else { original = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil)) }
                            try original.validate(for: photo)
                            var value = try amount == nil
                                ? original.pasting(source, options: options)
                                : original.applyingPreset(source, options: options, amount: amount!)
                            var notes = original.transferNotes(from: source, options: options)
                            if photo.isRAW {
                                let defaults = try await pipeline.rawDefaults(ImageRequest(photo: photo, root: root, recipe: original))
                                if options.details, !source.isRaster {
                                    let skipped = value.rawDetails.unavailableNames(defaults)
                                    value.rawDetails = value.rawDetails.supported(by: defaults)
                                    if !skipped.isEmpty { notes.append(L10n.text("app.unsupportedByTargetSkipped_108", defaultValue: "Unsupported by target, skipped: ") + skipped.joined(separator: "、")) }
                                }
                                try value.rawDetails.checkSupport(defaults)
                            }
                            if options.geometry, !value.perspective.isNeutral {
                                let size = try await pipeline.geometrySourceSize(ImageRequest(photo: photo, root: root, recipe: value))
                                _ = try PhotoGeometry(size: size, recipe: value)
                            }
                            if !notes.isEmpty { results.append("\(photo.name)：" + notes.joined(separator: "；")) }
                            guard value != original else { results.append(L10n.text("app.noChangesNeeded", defaultValue: "No changes needed: \(photo.name)")); continue }
                            changes.append((photo, value))
                        } catch is CancellationError { throw CancellationError() }
                        catch { results.append(L10n.text("app.skipped", defaultValue: "Skipped \(photo.name): \(error.localizedDescription)")) }
                    }
                    try Task.checkCancellation()
                    try catalog.saveRecipes(changes, title: title)
                    published = true
                    if !changes.isEmpty {
                        let old = changes.map(\.photo)
                        undo.beginUndoGrouping()
                        undo.registerUndo(withTarget: self) { $0.restoreRecipeBatch(old, title: title) }
                        undo.setActionName(title); undo.endUndoGrouping()
                        try refreshAfterBatch(ids: Set(old.map(\.id)))
                    }
                    reports = changes.map { L10n.text("app.succeeded", defaultValue: "Succeeded: \($0.photo.name)") } + results
                    status = L10n.text("app.completeUpdatedPhotos", defaultValue: "\(title) complete · Updated \(changes.count)/\(targets.count) photos") + (changes.isEmpty ? "" : L10n.text("app.undoTheEntireBatch", defaultValue: " · Undo the entire batch"))
                } catch is CancellationError {
                    reports = [L10n.text("app.cancelledBatchAdjustmentsWereNotSaved", defaultValue: "Cancelled. Batch adjustments were not saved")] + results
                    status = L10n.text("app.cancelled_115", defaultValue: "Cancelled \(title)")
                } catch {
                    let message = published ? L10n.text("app.adjustmentsSavedButTheInterfaceCouldNotRefresh", defaultValue: "Adjustments saved, but the interface could not refresh") : L10n.text("app.batchAdjustmentsWereNotSaved", defaultValue: "Batch adjustments were not saved")
                    reports = ["\(message)：\(error.localizedDescription)"] + results
                    self.error = error.localizedDescription; status = message
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// Apply one exposure delta to every selected photo while preserving each
    /// photo's own baseline and all other recipe settings.
    ///
    /// This is deliberately separate from `applyAdjustments`: ordinary paste
    /// and sync copy the source recipe's absolute exposure, whereas Lightroom's
    /// multi-photo Quick Develop exposure control applies the same relative EV
    /// change to each target.
    @discardableResult func applyRelativeExposure(delta: Double, ids: Set<String>, title: String? = nil) -> Bool {
        let title = title ?? L10n.text("app.relativeExposure", defaultValue: "Relative Exposure")
        guard !busy, canEdit, !ids.isEmpty, delta.isFinite, (-5...5).contains(delta), delta != 0,
              let catalog, commitRecipe() else { return false }
        do {
            let targets = try catalog.photos(ids: ids)
            guard !targets.isEmpty else { return false }
            busy = true; applyingAdjustments = true; reports = []
            task = Task {
                defer { busy = false; applyingAdjustments = false; taskProgress = nil }
                var changes = [(photo: Photo, recipe: EditRecipe)]()
                var results = [String]()
                var published = false
                do {
                    for (index, photo) in targets.enumerated() {
                        try Task.checkCancellation()
                        taskProgress = TaskProgress(title: title, done: index, total: targets.count)
                        status = L10n.text("app.checking", defaultValue: "\(title) · Checking \(index + 1)/\(targets.count) · \(photo.name)")
                        do {
                            guard photo.supportsEditing else { throw LRCError(L10n.text("app.editingThisFormatIsNotYetSupported", defaultValue: "Editing this format is not yet supported")) }
                            guard let root = roots.first(where: { $0.id == photo.rootID }) else { throw LRCError(L10n.text("app.theOriginalPhotoRootFolderIsMissing", defaultValue: "The original photo root folder is missing")) }
                            let original: EditRecipe
                            if let data = photo.recipe { original = try JSONDecoder().decode(EditRecipe.self, from: data) }
                            else { original = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil)) }
                            try original.validate(for: photo)
                            var value = original
                            value.exposure = min(5, max(-5, original.exposure + delta))
                            try value.validate(for: photo)
                            guard value != original else {
                                results.append(L10n.text("app.noChangesNeeded", defaultValue: "No changes needed: \(photo.name)"))
                                continue
                            }
                            changes.append((photo, value))
                        } catch is CancellationError { throw CancellationError() }
                        catch { results.append(L10n.text("app.skipped", defaultValue: "Skipped \(photo.name): \(error.localizedDescription)")) }
                    }
                    try Task.checkCancellation()
                    if !changes.isEmpty {
                        try catalog.saveRecipes(changes, title: title)
                        published = true
                        let old = changes.map(\.photo)
                        undo.beginUndoGrouping()
                        undo.registerUndo(withTarget: self) { $0.restoreRecipeBatch(old, title: title) }
                        undo.setActionName(title); undo.endUndoGrouping()
                        try refreshAfterBatch(ids: Set(old.map(\.id)))
                    }
                    reports = changes.map { L10n.text("app.succeeded", defaultValue: "Succeeded: \($0.photo.name)") } + results
                    status = L10n.text("app.completeUpdatedPhotos", defaultValue: "\(title) complete · Updated \(changes.count)/\(targets.count) photos") + (changes.isEmpty ? "" : L10n.text("app.undoTheEntireBatch", defaultValue: " · Undo the entire batch"))
                } catch is CancellationError {
                    reports = [L10n.text("app.cancelledBatchAdjustmentsWereNotSaved", defaultValue: "Cancelled. Batch adjustments were not saved")] + results
                    status = L10n.text("app.cancelled_115", defaultValue: "Cancelled \(title)")
                } catch {
                    let message = published ? L10n.text("app.adjustmentsSavedButTheInterfaceCouldNotRefresh", defaultValue: "Adjustments saved, but the interface could not refresh") : L10n.text("app.batchAdjustmentsWereNotSaved", defaultValue: "Batch adjustments were not saved")
                    reports = ["\(message)：\(error.localizedDescription)"] + results
                    self.error = error.localizedDescription; status = message
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    private func refreshAfterBatch(ids: Set<String>) throws {
        try reloadPhotos(); try reloadEditContext()
        if let activeID, ids.contains(activeID) {
            if let data = activePhoto?.recipe {
                recipe = try JSONDecoder().decode(EditRecipe.self, from: data); savedRecipe = recipe; dirty = false; before = false
                requestPreview(prepareInteractive: true)
            } else { loadActive() }
        }
    }
    private func restoreRecipeBatch(_ states: [Photo], title: String) {
        guard !applyingAdjustments, let catalog else { return }
        perform {
            let action = undo.isRedoing ? L10n.text("app.redo", defaultValue: "Redo \(title)") : L10n.text("app.undo", defaultValue: "Undo \(title)")
            let inverse = try catalog.restoreRecipes(states, title: action)
            undo.registerUndo(withTarget: self) { $0.restoreRecipeBatch(inverse, title: title) }
            undo.setActionName(title)
            try refreshAfterBatch(ids: Set(states.map(\.id)))
            status = action
        }
    }
    /// Positions are relative to the displayed (cropped/rotated) photo, for this catalog session.
    /// Zoom mode remains shared, as with the existing Z inspection workflow.
    func rememberViewPosition(leaving id: String?) {
        let current = viewport.requestedCenter
        if let id, fullResolution || fillView { viewPositions[id] = current }
        let next = lockViewPosition ? current : activeID.flatMap { viewPositions[$0] } ?? CGPoint(x: 0.5, y: 0.5)
        viewport.restore(next)
    }
    func selectZoom(_ factor: Double?, fill: Bool = false) {
        guard !cropMode else { return }
        if let factor {
            guard Self.zoomScales.contains(factor) else { return }
            zoomScale = factor
            if usesPreferences { UserDefaults.standard.set(factor, forKey: "lastZoomScale") }
        }
        let needsRender = fullResolution != (factor != nil)
        fullResolution = factor != nil; fillView = fill
        if !fullResolution { viewport.reset() }
        if needsRender { requestPreview() }
    }
    func toggleCanvasZoom(at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        guard !cropMode, image != nil else { return }
        if fullResolution || fillView { selectZoom(nil) }
        else {
            selectZoom(zoomScale)
            viewport.focusOnNextGeometry(point)
        }
    }
    var canShowBeforeAfter: Bool { photoSwitchDisplay == nil && !editorUsesPreviousPhoto && !isPreviewingAdjustment && !whiteBalanceSampling && !pointSampling && !showPointColorRange && hasRecipe && !cropMode && !maskMode && !spotMode && comparison == nil }
    /// `\`: the whole canvas shows the untoned, uncropped original.
    func toggleBefore() {
        guard recipe != nil, !cropMode else { return }
        beforeAfter = .off; before.toggle(); requestPreview()
    }
    func toggleBeforeAfter(_ layout: BeforeAfterLayout) { showBeforeAfter(beforeAfter == layout ? .off : layout) }
    func showBeforeAfter(_ layout: BeforeAfterLayout) {
        guard layout == .off || canShowBeforeAfter else { return }
        if layout != .off, before { before = false; requestPreview() }
        beforeAfter = layout
    }
    private func resetBeforeImage() {
        beforeTask?.cancel(); beforeTask = nil; beforeKey = nil; beforeImage = nil; beforeStatus = ""
    }
    /// Renders the untoned photo on the current geometry for the side-by-side and split views.
    func refreshBeforeImage() {
        guard beforeAfter != .off, comparison == nil, let photo = active,
              let root = roots.first(where: { $0.id == photo.rootID }), let recipe else { resetBeforeImage(); return }
        let base = beforeReference.flatMap { $0.photoID == photo.id && $0.recipe.sourceDigest == recipe.sourceDigest ? $0.recipe : nil }
        let key = BeforeImageKey(photoID: photo.id, recipe: base?.aligned(to: recipe) ?? recipe.alignedBaseline(), edge: fullResolution ? nil : 2400)
        guard key != beforeKey else { return }
        beforeTask?.cancel()
        // An edge change keeps the old pixels in place while the new size renders; geometry changes must not.
        if beforeKey?.photoID != key.photoID || beforeKey?.recipe != key.recipe { beforeImage = nil }
        beforeKey = key; beforeStatus = L10n.text("app.renderingOriginal", defaultValue: "Rendering original…")
        let render = renderPreview, request = ImageRequest(photo: photo, root: root, recipe: key.recipe)
        beforeTask = Task { [weak self] in
            let outcome: Result<RenderedImage, Error>
            do { outcome = .success(try await render(request, false, key.edge)) } catch { outcome = .failure(error) }
            guard !Task.isCancelled, let self, self.beforeKey == key else { return }
            self.beforeTask = nil
            switch outcome {
            case .success(let result): self.beforeImage = result.image; self.beforeStatus = ""
            case .failure(let error): self.beforeImage = nil; self.beforeStatus = L10n.text("app.originalRenderingFailed", defaultValue: "Original rendering failed: \(error.localizedDescription)")
            }
        }
    }
    func requestPreview(interactive: Bool = false, prepareInteractive: Bool = false, override: EditRecipe? = nil) {
        guard comparison == nil, survey == nil else { return }
        guard let photo = active, let root = roots.first(where: { $0.id == photo.rootID }) else { return }
        refreshBeforeImage()
        let shown = override ?? displayPreviewRecipe
        let baseline = beforeReference.flatMap { state in shown.flatMap { state.photoID == photo.id && state.recipe.sourceDigest == $0.sourceDigest ? state.recipe.aligned(to: $0) : nil } }
        var renderRecipe = before ? baseline ?? shown?.baseline() : shown
        if cropMode {
            renderRecipe = renderRecipe?.cropRenderRecipe
            // Angle/crop-only edits use the already decoded, unstraightened image.
            if image != nil, !interactivePreview, renderedCropRecipe == renderRecipe { return }
        } else { renderedCropRecipe = nil }
        previewRevision &+= 1
        previewCurrent = false
        wantsInteractivePreview = interactive
        let job = PendingPreview(request: ImageRequest(photo: photo, root: root, recipe: renderRecipe),
                                 generation: previewGeneration, interactive: interactive,
                                 edge: fullResolution && !cropMode ? nil : 2400, revision: previewRevision, cropPreview: cropMode)
        PreviewLog.logger.debug("request draft=\(interactive) revision=\(job.revision)")
        if interactive {
            // A previous full RAW render must never own the interactive lane.
            // Cancellation is cooperative; the separate actor also handles the
            // interval in which Core Image cannot interrupt its current kernel.
            pendingQualityPreview = nil
            qualityRender?.cancel()
            pendingPreview = job
            startInteractiveWorker()
        } else {
            let draftAlreadyShown = publishedDraft.map { $0.image === image && $0.job.hasSameContent(as: job) } ?? false
            pendingPreview = prepareInteractive && !draftAlreadyShown ? PendingPreview(request: job.request, generation: job.generation, interactive: true, edge: job.edge, revision: job.revision, cropPreview: job.cropPreview) : nil
            if prepareInteractive { startInteractiveWorker() }
            pendingQualityPreview = job
            qualityRender?.cancel()
            imageStatus = L10n.text("app.rendering", defaultValue: "Rendering…")
            startQualityWorker()
        }
    }

    private func startInteractiveWorker() {
        guard renderTask == nil, let job = pendingPreview else { return }
        pendingPreview = nil
        let renderer = renderPreview
        // Start outside MainActor immediately. Main-queue jobs can be deferred
        // by a continuous stream of native input; common-mode delivery below
        // also remains runnable during AppKit tracking.
        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<RenderedImage, Error>
            do {
                PreviewLog.logger.debug("render-start draft=true revision=\(job.revision)")
                let result = try await renderer(job.request, true, job.edge)
                PreviewLog.logger.debug("render-done draft=true revision=\(job.revision) render-ms=\(result.elapsed * 1000)")
                outcome = .success(result)
            } catch { outcome = .failure(error) }
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.renderTask = nil
                    var delivery = job
                    if !self.wantsInteractivePreview, let pending = self.pendingPreview, pending.revision == self.previewRevision,
                       job.hasSameContent(as: pending) {
                        delivery = pending
                        self.pendingPreview = nil
                        PreviewLog.logger.debug("reuse-draft revision=\(job.revision) as=\(delivery.revision)")
                    }
                    let qualityAlreadyNewer = self.publishedQualityRevision.map { $0 >= delivery.revision } ?? false
                    let shownRecipe = self.displayPreviewRecipe
                    let base = self.beforeReference.flatMap { state in shownRecipe.flatMap { state.photoID == self.activeID && state.recipe.sourceDigest == $0.sourceDigest ? state.recipe.aligned(to: $0) : nil } }
                    let shown = self.before ? base ?? shownRecipe?.baseline() : shownRecipe
                    let expected = self.cropMode ? shown?.cropRenderRecipe : shown
                    let geometryCurrent = job.request.recipe?.hasSameGeometry(as: expected) ?? (expected == nil)
                    let mayPublish = !qualityAlreadyNewer && geometryCurrent &&
                        (self.wantsInteractivePreview || delivery.revision == self.previewRevision)
                    switch outcome {
                    case .success(let result):
                        if mayPublish { self.publishPreview(result, job: delivery) }
                    case .failure(let error):
                        if !(error is CancellationError), job.generation == self.previewGeneration,
                           mayPublish, self.pendingPreview == nil {
                            self.photoSwitchDisplay = nil; self.imageStatus = error.localizedDescription
                            if self.qualityWorker == nil, self.pendingQualityPreview == nil { self.loadingPhoto = false }
                        }
                    }
                    self.startInteractiveWorker()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func startQualityWorker() {
        guard qualityWorker == nil, let job = pendingQualityPreview else { return }
        pendingQualityPreview = nil
        let renderer = renderPreview
        // Input already coalesces in the draft lane; a settled request can start before UI bookkeeping finishes.
        let task = Task.detached(priority: .userInitiated) {
            PreviewLog.logger.debug("render-start draft=false revision=\(job.revision)")
            let result = try await renderer(job.request, false, job.edge)
            PreviewLog.logger.debug("render-done draft=false revision=\(job.revision) render-ms=\(result.elapsed * 1000)")
            return result
        }
        qualityRender = task
        qualityWorker = Task {
            do {
                let result = try await task.value
                if !task.isCancelled, job.revision == previewRevision { publishPreview(result, job: job) }
            } catch is CancellationError {} catch {
                if job.generation == previewGeneration, job.revision == previewRevision {
                    photoSwitchDisplay = nil
                    loadingPhoto = false
                    imageStatus = error.localizedDescription
                }
            }
            qualityRender = nil
            qualityWorker = nil
            startQualityWorker()
        }
    }

    private func publishPreview(_ result: RenderedImage, job: PendingPreview) {
        guard job.generation == previewGeneration, job.request.photo.id == activeID else { return }
        PreviewLog.logger.debug("publish draft=\(job.interactive) revision=\(job.revision) render-ms=\(result.elapsed * 1000)")
        publishedDraft = job.interactive ? (job, result.image) : nil
        if !job.interactive { publishedQualityRevision = job.revision }
        if !job.interactive, !job.cropPreview, !before, !dirty, job.request.recipe == savedRecipe,
           let photo = activePhoto {
            Task { try? await thumbnails.storePreview(result.image, photo: photo) }
        }
        image = result.image; interactivePreview = job.interactive
        loadingPhoto = false
        photoSwitchDisplay = nil
        previewCurrent = !job.interactive && job.revision == previewRevision
        previewIsCrop = job.cropPreview
        renderedCropRecipe = job.cropPreview ? job.request.recipe : nil
        if let value = result.histogram { histogram = value }
        canEdit = job.request.photo.supportsEditing && job.request.recipe != nil
        orientedSourceSize = result.orientedSourceSize
        renderedCoordinateRecipe = job.request.recipe
        renderedNativeSize = result.fullSize
        spotRenderedOffsets = result.spotOffsets
        imageStatus = job.interactive ? L10n.text("app.interactivePreviewReleaseToUpdateTheDetailedPreview", defaultValue: "Interactive preview · Release to update the detailed preview") :
            L10n.text("app.s", defaultValue: "\(job.edge == nil ? L10n.text("app.fullSizePreviewDragToPan", defaultValue: "Full-size preview · Drag to pan") : L10n.text("app.fit", defaultValue: "Fit")) · \(Int(result.fullSize.width)) × \(Int(result.fullSize.height)) · \(String(format: "%.2f", result.elapsed)) s")
    }
    func exportSelection() throws -> [Photo] {
        guard let catalog else { throw LRCError(L10n.text("app.openACatalogFirst", defaultValue: "Open a catalog first")) }
        return try catalog.exportPhotos(ids: selection, query: query)
    }
    /// Re-read recipes at submission, retaining exactly the order/names shown in the sheet.
    func prepareExport(options: ExportOptions, photos: [Photo], names: [ExportName], directory: URL) throws -> [ExportSnapshot] {
        guard let catalog, !photos.isEmpty, Set(photos.map(\.id)) == selection else { throw LRCError(L10n.text("app.theSelectionChangedReopenTheExportWindow", defaultValue: "The selection changed. Reopen the export window")) }
        let current = try photos.map { previous -> Photo in
            guard let photo = try catalog.photo(previous.id) else { throw LRCError(L10n.text("app.selectedPhotosAreNoLongerInTheCatalog", defaultValue: "Selected photos are no longer in the catalog")) }
            return photo
        }
        let descriptions = options.metadataPolicy.includesDescription ? try catalog.exportDescriptions(ids: Set(current.map(\.id))) : [:]
        let lease = AccessLease(url: directory); defer { withExtendedLifetime(lease) {} }
        let checked = try ExportNamingPlanner.preview(photos: current, options: options, directory: directory)
        guard checked.map(\.filename) == names.map(\.filename), checked.map(\.id) == names.map(\.id) else { throw LRCError(L10n.text("app.namingSettingsChangedRefreshThePreview", defaultValue: "Naming settings changed. Refresh the preview")) }
        guard checked.allSatisfy({ $0.errors.isEmpty }) else { throw LRCError(L10n.text("app.namingOrDestinationConflictNothingQueued", defaultValue: "Naming or destination conflict; nothing queued: ") + checked.flatMap(\.errors).prefix(5).joined(separator: "；")) }
        let bookmark = try AccessLease.bookmark(directory, readOnly: false)
        return try zip(current, checked).map { photo, name in
            guard let root = roots.first(where: { $0.id == photo.rootID }) else { throw LRCError(L10n.text("app.theOriginalPhotoRootFolderIsMissing", defaultValue: "The original photo root folder is missing")) }
            let recipe = try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) } ?? (photo.id == activeID ? self.recipe : nil)
            return ExportSnapshot(id: UUID().uuidString, request: ImageRequest(photo: photo, root: root, recipe: recipe), destination: directory.appendingPathComponent(name.filename), targetBookmark: bookmark, options: options, metadata: ExportMetadata(descriptive: descriptions[photo.id] ?? ExportDescription()))
        }
    }
    @discardableResult
    func export(options: ExportOptions, photos: [Photo], names: [ExportName], directory: URL) -> Bool {
        guard !busy, commitRecipe(), let catalog else { return false }
        do {
            let snapshots = try prepareExport(options: options, photos: photos, names: names, directory: directory)
            lastExportResult = nil; showImportCompletion = false
            busy = true; showExport = false; status = L10n.text("app.freezingExportSourcesAndCaptureMetadataNotYetQueued", defaultValue: "Freezing export sources and capture metadata · Not yet queued")
            task = Task {
                do {
                    var frozen = [ExportSnapshot]()
                    for snapshot in snapshots { frozen.append(try await pipeline.freezeExport(snapshot)) }
                    exportOperationCounts = ExportOperationCounts()
                    reports = await ExportService(pipeline: pipeline).run(frozen, catalog: catalog, step: { [self] done, total in
                        await MainActor.run { taskProgress = TaskProgress(title: L10n.text("app.export", defaultValue: "Export"), done: done, total: total) }
                    }, outcome: { [self] in exportOperationCounts.record($0) }) { [self] text in await MainActor.run { status = text } }
                    perform { try recordExportResult(ids: Set(frozen.map(\.id))) }
                    status = lastExportResult?.summary ?? L10n.text("app.outputFinishedButRecordsCouldNotBeReadCheck", defaultValue: "Output finished, but records could not be read. Check the task results")
                } catch {
                    reports = [Task.isCancelled ? L10n.text("app.exportPreparationCancelledNothingQueued", defaultValue: "Export preparation cancelled; nothing queued") : L10n.text("app.exportPreparationFailedNothingQueued", defaultValue: "Export preparation failed; nothing queued: \(error.localizedDescription)")]
                    status = reports[0]
                }
                busy = false; taskProgress = nil
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func beginExportPreparation(_ text: String) {
        lastExportResult = nil; showImportCompletion = false
        busy = true; showExport = false; status = text
    }
    func retryExport(_ snapshot: ExportSnapshot) {
        retryExports(ids: [snapshot.id], includeCompleted: true)
    }
    func recordExportResult(ids: Set<String>) throws {
        guard let catalog else { return }
        let history = try ExportService.history(catalog: catalog, ids: ids)
        lastExportResult = ExportBatchResult(ids: ids, logs: history.logs, rejected: history.rejected, reports: reports, operationCounts: exportOperationCounts)
    }
    func openExportRecords(ids: Set<String>? = nil, unfinishedOnly: Bool = false) {
        guard workspaceAvailable, catalog != nil else { return }
        exportRecordIDs = ids; exportRecordsUnfinishedOnly = unfinishedOnly; showOutputRecovery = true
    }
    func retryExports(ids: Set<String>, includeCompleted: Bool = false) {
        guard !busy, let catalog else { return }
        do {
            // Read the journal again: a sheet may have just renewed the target permission.
            let history = try ExportService.history(catalog: catalog, ids: ids)
            guard history.rejected.isEmpty, history.logs.count == ids.count else { throw LRCError(L10n.text("app.someOutputRecordsAreUnsupportedOrMissingOriginalRecords", defaultValue: "Some output records are unsupported or missing. Original records were preserved; review them first")) }
            let snapshots = history.logs.filter { includeCompleted || $0.canRetryInBatch }.map(\.snapshot)
            guard !snapshots.isEmpty else { return }
            let batchIDs = lastExportResult.flatMap { ids.isSubset(of: $0.ids) ? $0.ids : nil } ?? ids
            busy = true; showImportCompletion = false
            task = Task {
                exportOperationCounts = ExportOperationCounts()
                    reports = await ExportService(pipeline: pipeline).run(snapshots, catalog: catalog, step: { [self] done, total in
                    await MainActor.run { taskProgress = TaskProgress(title: L10n.text("app.verifyAndRetry", defaultValue: "Verify and Retry"), done: done, total: total) }
                }, outcome: { [self] in exportOperationCounts.record($0) }) { [self] text in await MainActor.run { status = text } }
                perform { try recordExportResult(ids: batchIDs) }
                status = lastExportResult?.summary ?? L10n.text("app.outputVerificationComplete", defaultValue: "Output verification complete"); busy = false; taskProgress = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    func revealExports(ids: Set<String>) {
        guard !busy, let catalog else { return }
        perform {
            let history = try ExportService.history(catalog: catalog, ids: ids)
            let completed = history.logs.filter { $0.state == "completed" }
            let leases = try completed.map { try AccessLease(bookmark: $0.snapshot.targetBookmark) }
            defer { withExtendedLifetime(leases) {} }
            let files = completed.map(\.snapshot.destination).filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { throw LRCError(L10n.text("app.anOutputWasMovedOrItsDestinationIsInaccessible", defaultValue: "An output was moved or its destination is inaccessible. Reauthorize and verify it in Output Records, then retry as needed")) }
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }
    func configureCache() {
        guard catalog != nil, !cacheMaintenance else { return }
        cacheMaintenance = true
        Task {
            defer { cacheMaintenance = false }
            do { try await applyCacheQuota() }
            catch { self.error = error.localizedDescription }
        }
    }
    /// A machine preference can be saved before the first catalog is created.
    func updateCacheQuota(_ value: Int) async throws {
        guard [1, 5, 10].contains(value) else { throw LRCError(L10n.text("app.cacheQuotaMustBe15Or10GiB", defaultValue: "Cache quota must be 1, 5, or 10 GiB")) }
        guard !cacheMaintenance, !busy, !applyingAdjustments else { throw LRCError(L10n.text("app.waitForTheCurrentTaskToFinishBeforeChanging", defaultValue: "Wait for the current task to finish before changing the cache quota")) }
        cacheMaintenance = true
        defer { cacheMaintenance = false }
        cacheGigabytes = value
        cachePreferences?.set(value, forKey: "cacheGB")
        try await applyCacheQuota()
    }
    private func applyCacheQuota() async throws {
        guard let catalog else { cacheBytes = 0; return }
        let id = try await catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM catalogMeta")! }
        try await thumbnails.configure(catalogID: id, gigabytes: cacheGigabytes)
        cacheBytes = try await thumbnails.usage()
    }
    func clearThumbnailCache() async throws {
        guard catalog != nil else { throw LRCError(L10n.text("app.openACatalogFirst", defaultValue: "Open a catalog first")) }
        guard !cacheMaintenance, !busy, !applyingAdjustments else { throw LRCError(L10n.text("app.waitForTheCurrentTaskToFinishBeforeClearing", defaultValue: "Wait for the current task to finish before clearing the cache")) }
        cacheMaintenance = true
        defer { cacheMaintenance = false }
        try await thumbnails.clear()
        cacheBytes = try await thumbnails.usage()
    }
    func locateOriginal() {
        guard canLocateOriginal, let photo = active, let catalog, commitRecipe() else { return }
        do {
            guard let source = try catalog.source(photo.sourceKey) else { throw LRCError(L10n.text("app.theSourcePhotoRecordDoesNotExist", defaultValue: "The source photo record does not exist")) }
            let panel = NSOpenPanel()
            panel.title = L10n.text("app.locateOriginal", defaultValue: "Locate Original · \(photo.name)"); panel.prompt = L10n.text("app.locateOriginal_146", defaultValue: "Locate Original")
            panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.resolvesAliases = false
            panel.directoryURL = roots.first { $0.id == source.rootID }.map { URL(fileURLWithPath: $0.path) }
            guard panel.runModal() == .OK, let file = panel.url else { return }
            let fileAccess = AccessLease(url: file)
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            let knownRoot = roots.contains { path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }
            let directory: URL?
            if knownRoot { directory = nil }
            else {
                guard let selected = chooseDirectory(title: L10n.text("app.authorizeTheOriginalPhotoFolder", defaultValue: "Authorize the original photo folder · \(file.lastPathComponent)"), initialURL: file.deletingLastPathComponent()) else { return }
                directory = selected
            }
            let directoryAccess = directory.map { AccessLease(url: $0) }
            busy = true; status = L10n.text("app.verifyingTheOriginalPhotoLocation", defaultValue: "Verifying the original photo location…")
            task = Task {
                defer { busy = false; withExtendedLifetime((fileAccess, directoryAccess)) {} }
                do {
                    let relocator = RootRelocator()
                    let proposal = try await relocator.prepare(source, file: file, directory: directory, catalog: catalog)
                    try await relocator.commit(proposal, catalog: catalog)
                    folderPhotoCount = -1
                    try reload(); loadActive()
                    status = L10n.text("app.originalLocatedRelatedVersionsAndOrganizationPreserved", defaultValue: "Original located · \(file.lastPathComponent) · Related versions and organization preserved")
                } catch is CancellationError { status = L10n.text("app.locationCancelledTheOriginalLocationWasPreserved", defaultValue: "Location cancelled. The original location was preserved") }
                catch { self.error = error.localizedDescription; status = L10n.text("app.originalLocationIncomplete", defaultValue: "Original location incomplete") }
            }
        } catch { self.error = error.localizedDescription }
    }
    func relocate(_ root: StorageRoot) {
        guard !busy, let catalog, let url = chooseDirectory(title: L10n.text("app.reauthorizeLocatePreserveRelativePaths", defaultValue: "Reauthorize / locate \(root.label) · Preserve relative paths")) else { return }
        busy = true
        task = Task {
            do {
                reports = try await RootRelocator().relocate(root, to: url, catalog: catalog)
                try reload(); loadActive(); status = L10n.text("app.folderVerificationCompleteIdentitiesNeedConfirmation", defaultValue: "Folder verification complete · \(reports.count) identities need confirmation")
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
    func startCopy(source: URL, target: URL, selectedPaths: Set<String>, includeSubfolders: Bool,
                   layout: DateLayout, dateOverride: String?, includeSidecars: Bool, collection: String?, pairAfterImport: Bool = false) {
        guard !busy, let catalog else { return }
        // Retain both grants after the import sheet closes and while planning runs.
        let sourceLease = AccessLease(url: source), targetLease = AccessLease(url: target)
        busy = true; status = L10n.text("app.importingReadingPhotosAndDestinations", defaultValue: "Importing: reading photos and destinations…")
        task = Task {
            defer { busy = false; withExtendedLifetime([sourceLease, targetLease]) {} }
            do {
                var plan = try await ImportPlanner().plan(source: source, target: target, layout: layout, policy: .skip,
                    skipIdentical: true, dateOverride: dateOverride, confirmSidecars: includeSidecars, catalog: catalog,
                    selectedPaths: selectedPaths, includeSubfolders: includeSubfolders, deferConflicts: true, includeSidecars: includeSidecars)
                try Task.checkCancellation()
                plan.collectionID = collection; plan.pairAfterImport = pairAfterImport
                await executeCopy(plan, catalog: catalog)
            } catch is CancellationError { status = L10n.text("app.importCancelled", defaultValue: "Import cancelled") }
            catch { self.error = error.localizedDescription; status = L10n.text("app.importIncomplete", defaultValue: "Import incomplete") }
        }
    }
    func runCopy(_ plan: CopyPlan) {
        guard !busy, let catalog else { return }
        busy = true
        task = Task {
            await executeCopy(plan, catalog: catalog)
            busy = false
        }
    }
    private func executeCopy(_ plan: CopyPlan, catalog: CatalogStore) async {
        if usesPreferences { UserDefaults.standard.set(plan.targetBookmark, forKey: "lastCopyTarget") }
        importingPhotoIDs = []
        let result = await CopyImporter().run(plan, catalog: catalog, resolveConflict: { [weak self] conflict in
            await self?.requestImportConflict(conflict)
        }, onImported: { [self] id in await MainActor.run { _ = importingPhotoIDs.insert(id) } }) { [self] text in await MainActor.run { status = text } }
        perform { try reload() }
        let importedCount = importingPhotoIDs.count
        perform { try completeImport(ids: importingPhotoIDs, cancelled: result.state == "cancelled") }
        importingPhotoIDs = []
        reports = result.groups.map { group in
            "\(group.members.first?.source.lastPathComponent ?? L10n.text("app.fileGroupsToReview", defaultValue: "File Groups to Review"))：\(group.state) \(group.diagnostic ?? "")"
        } + result.omitted
        if result.pairAfterImport, result.state == "completed" {
            let destinations = Set(result.groups.filter { $0.state == "completed" }.flatMap(\.members).filter(\.isImage).map { $0.destination.path })
            let sources = (try? catalog.sources()) ?? []
            let rootsByID = Dictionary(uniqueKeysWithValues:((try? catalog.roots()) ?? []).map { ($0.id,$0.path) })
            let ids = Set(sources.filter { source in rootsByID[source.rootID].map { destinations.contains(URL(fileURLWithPath:$0).appendingPathComponent(source.relativePath).path) } ?? false }.map(\.id))
            if !ids.isEmpty { pairingScope = ids; showPairing = true }
        }
        let pending = result.groups.filter { $0.state == "needsReview" }.count
        status = L10n.text("app.addedPhotosGroupsCompleteSkippedPending", defaultValue: "\(result.state == "cancelled" ? L10n.text("app.importCancelled", defaultValue: "Import cancelled") : L10n.text("app.importFinished", defaultValue: "Import finished")) · Added \(importedCount) photos · \(result.groups.filter { $0.state == "completed" }.count) groups complete · \(result.groups.filter { $0.state == "skippedConflict" }.count) skipped · \(pending) pending")
        if pending > 0 || result.state == "needsReview" {
            error = (result.groups.filter { $0.state == "needsReview" }.compactMap(\.diagnostic) + result.omitted).joined(separator: "\n")
        }
    }
    private func requestImportConflict(_ conflict: ImportConflict) async -> ImportConflictDecision? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                conflictContinuation = continuation
                status = L10n.text("app.importPausedResolveFilenameConflicts", defaultValue: "Import paused · Resolve filename conflicts")
                importConflict = conflict
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveImportConflict(nil) }
        }
    }
    func resolveImportConflict(_ decision: ImportConflictDecision?) {
        let continuation = conflictContinuation
        conflictContinuation = nil; importConflict = nil
        continuation?.resume(returning: decision)
    }
    func showImportRecovery() {
        guard let catalog else { return }
        perform {
            let plans = try CopyImporter.savedPlans(catalog: catalog)
            reports = plans.flatMap { plan in
                [L10n.text("app.batch", defaultValue: "Batch \(plan.id): \(plan.state)")] + plan.groups.flatMap { group in
                    group.members.compactMap { member in member.recovery.map { L10n.text("app.previousDestinationRecoveryFile", defaultValue: "Previous destination recovery file: \($0.path)") } }
                }
            }
            status = L10n.text("app.copyLogLoadedIntoTaskResultsTasksWereNot", defaultValue: "Copy log loaded into task results; tasks were not replayed")
        }
    }
    func backup(manifest: Bool = false) {
        guard let catalog else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = manifest ? "Phosdeck-\(UUID().uuidString.prefix(8)).json" : "Phosdeck-\(UUID().uuidString.prefix(8)).sqlite"
        panel.title = manifest ? L10n.text("app.exportManagementManifestExcludesAccessBookmarks", defaultValue: "Export management manifest (excludes access bookmarks)") : L10n.text("app.backUpCatalogExcludesOriginalPhotosAndOutputs", defaultValue: "Back Up Catalog (excludes original photos and outputs)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform {
            let lease = AccessLease(url: url); defer { withExtendedLifetime(lease) {} }
            if manifest { try catalog.exportManifest(to: url) } else { try catalog.backup(to: url) }
            status = manifest ? L10n.text("app.managementManifestWritten", defaultValue: "Management manifest written") : L10n.text("app.catalogBackupCompleteOriginalPhotosExcluded", defaultValue: "Catalog backup complete · Original photos excluded")
        }
    }
    func restoreBackup() {
        guard canSwitchCatalog, commitRecipe() else { return }
        let panel = NSOpenPanel(); panel.title = L10n.text("app.chooseCatalogBackup", defaultValue: "Choose Catalog Backup")
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        catalogRestoreSource = source; showNewCatalog = true
    }
}


struct RecentCatalog: Codable, Identifiable {
    let path: String
    let filename: String
    let bookmark: Data
    var id: String { path }
}

struct CatalogOpenRequest {
    let url: URL
    let access: AccessLease
    let bookmark: Data?
    var restoreWorkspace = false
}

extension AppModel {
    func openStartupCatalogIfNeeded() {
        guard let request = startupCatalogOpen else { return }
        startupCatalogOpen = nil
        openingStartupCatalog = true
        defer {
            openingStartupCatalog = false
            if let url = deferredCatalogURL {
                deferredCatalogURL = nil
                openCatalog(url: url)
            }
        }
        requestCatalogOpen(request)
    }

    @discardableResult
    func requestCatalogOpen(_ request: CatalogOpenRequest, choice: CatalogExtensionChoice? = nil) -> Task<Void, Never>? {
        guard canSwitchCatalog, commitRecipe() else { return nil }
        do {
            guard CatalogFile.isLegacy(request.url) else {
                try finishCatalogOpen(request.url, request: request)
                return nil
            }
            let change = try CatalogExtensionChange(source: request.url)
            switch choice ?? chooseCatalogExtension(change) {
            case .cancel:
                if catalog == nil { status = L10n.text("app.noCatalogIsOpen", defaultValue: "No catalog is open") }
            case .keepOriginal:
                guard try FileIdentity.read(request.url) == change.identity else {
                    throw LRCError(L10n.text("catalogExtension.sourceChanged", defaultValue: "The catalog changed after confirmation. Its name was not changed. Open it again to retry."))
                }
                try finishCatalogOpen(request.url, request: request)
            case .change:
                let previousStatus = status
                busy = true; changingCatalogExtension = true
                status = L10n.text("catalogExtension.changing", defaultValue: "Changing catalog file extension…")
                return Task { [self] in
                    defer { busy = false; changingCatalogExtension = false }
                    var renamed: URL?
                    do {
                        let destination = try await Task.detached(priority: .userInitiated) { try change.perform() }.value
                        renamed = destination
                        busy = false
                        try finishCatalogOpen(destination, request: request)
                    } catch {
                        self.error = renamed.map {
                            L10n.text("catalogExtension.renamedButNotOpened", defaultValue: "The renamed catalog was preserved at the following location, but could not be opened:") + "\n" + $0.path + "\n\n" + error.localizedDescription
                        } ?? error.localizedDescription
                        if catalog == nil { status = L10n.text("app.noCatalogIsOpen", defaultValue: "No catalog is open") }
                        else { status = previousStatus }
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
        return nil
    }

    private func chooseCatalogExtension(_ change: CatalogExtensionChange) -> CatalogExtensionChoice {
        catalogUtilityOpen = true
        defer { catalogUtilityOpen = false }
        let alert = NSAlert()
        defer { alert.window.orderOut(nil) }
        alert.messageText = L10n.text("catalogExtension.confirmTitle", defaultValue: "Use the new Phosdeck catalog extension?")
        alert.informativeText = change.source.lastPathComponent + "\n→ " + change.destination.lastPathComponent + "\n\n" +
            L10n.text("catalogExtension.confirmMessage", defaultValue: "Only the filename changes, in the same folder. Photos, adjustments and history stay unchanged. You can also keep the current name and open the catalog.")
        alert.addButton(withTitle: L10n.text("catalogExtension.changeAndOpen", defaultValue: "Change Extension and Open"))
        alert.addButton(withTitle: L10n.text("catalogExtension.keepAndOpen", defaultValue: "Keep Current Name and Open"))
        alert.addButton(withTitle: L10n.text("app.cancel", defaultValue: "Cancel"))
        alert.buttons[2].keyEquivalent = "\u{1b}"
        alert.window.appearance = NSApp.keyWindow?.effectiveAppearance
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .change
        case .alertSecondButtonReturn: return .keepOriginal
        default: return .cancel
        }
    }

    private func finishCatalogOpen(_ url: URL, request: CatalogOpenRequest) throws {
        let renamed = url != request.url
        if renamed {
            if usesPreferences { Self.transferCatalogPreferences(from: request.url, to: url, defaults: .standard) }
            // A completed rename must be discoverable even if opening later fails.
            try rememberCatalog(url, directory: request.access.url, bookmark: request.bookmark, replacing: request.url)
        }
        let next = try CatalogStore(fileURL: url, access: request.access)
        if request.restoreWorkspace && catalog == nil {
            catalog = next
            try restoreCatalogWorkspace()
        } else {
            try activateCatalog(next, restoringWorkspace: renamed && usesPreferences)
        }
        if !renamed { try rememberCatalog(url, directory: request.access.url, bookmark: request.bookmark) }
    }

    static func transferCatalogPreferences(from source: URL, to destination: URL, defaults: UserDefaults) {
        let prefix = source.path + ":"
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            defaults.set(value, forKey: destination.path + ":" + key.dropFirst(prefix.count))
        }
    }

    func createCatalog() {
        guard canSwitchCatalog, commitRecipe() else { return }
        catalogRestoreSource = nil; showNewCatalog = true
    }
    func createCatalog(name: String, directory: URL) throws {
        guard !busy, commitRecipe() else { throw LRCError(L10n.text("app.finishTheCurrentTaskAndSaveAdjustmentsFirst", defaultValue: "Finish the current task and save adjustments first")) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else { throw LRCError(L10n.text("app.enterAValidCatalogNameWithoutOr", defaultValue: "Enter a valid catalog name without / or :")) }
        let filename = CatalogFile.filename(name)
        let url = directory.appendingPathComponent(filename)
        let lease = AccessLease(url: directory)
        let bookmark = try AccessLease.bookmark(directory, readOnly: false)
        let next: CatalogStore
        if let source = catalogRestoreSource {
            let original = AccessLease(url: source); defer { withExtendedLifetime(original) {} }
            next = try CatalogStore.restore(from: source, toFile: url, access: lease)
        } else {
            next = try CatalogStore(fileURL: url, create: true, access: lease)
        }
        try activateCatalog(next)
        try rememberCatalog(url, directory: directory, bookmark: bookmark)
        showNewCatalog = false; catalogRestoreSource = nil
    }
    func openCatalog() {
        guard canSwitchCatalog, commitRecipe() else { return }
        let panel = NSOpenPanel(); panel.title = L10n.text("app.openAPhosdeckCatalog", defaultValue: "Open a Phosdeck Catalog")
        panel.allowedContentTypes = [CatalogFile.contentType, UTType(filenameExtension: "sqlite") ?? .database]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openCatalog(url: url)
    }
    func openCatalog(url: URL) {
        // A Finder open takes precedence over automatic recent-catalog restoration.
        startupCatalogOpen = nil
        if openingStartupCatalog && catalogUtilityOpen {
            deferredCatalogURL = url
            NSApp.abortModal()
            return
        }
        guard canSwitchCatalog else { error = L10n.text("app.finishTheCurrentTaskOrCloseTheImportWindow", defaultValue: "Finish the current task or close the import window before switching catalogs"); return }
        guard commitRecipe() else { return }
        if let recent = recentCatalogs.first(where: { $0.path == url.path }), (try? AccessLease(bookmark: recent.bookmark)) != nil { openRecent(recent); return }
        if url.resolvingSymlinksInPath().standardizedFileURL == catalog?.fileURL { return }
        guard url.pathExtension.lowercased() != "lrcat" else { error = L10n.text("app.adobeLrcatFilesUseADifferentFormatOpenAn", defaultValue: "Adobe .lrcat files use a different format. Open a .phoscat catalog file"); return }
        perform {
            guard let lease = catalogDirectoryAccess(for: url) else { return }
            let selected = lease.url
            let bookmark = try AccessLease.bookmark(selected, readOnly: false)
            requestCatalogOpen(CatalogOpenRequest(url: url, access: lease, bookmark: bookmark))
        }
    }
    private func catalogDirectoryAccess(for url: URL) -> AccessLease? {
        // SQLite needs its containing folder for the lock and rollback journal.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        if let recent = recentCatalogs.first(where: { URL(fileURLWithPath: $0.path).deletingLastPathComponent().resolvingSymlinksInPath() == parent }), let lease = try? AccessLease(bookmark: recent.bookmark) { return lease }
        let panel = NSOpenPanel(); panel.title = L10n.text("app.authorizeCatalogFolder", defaultValue: "Authorize Catalog Folder")
        panel.message = L10n.text("app.chooseToStoreTheCatalogAndRecoveryLogs", defaultValue: "Choose “\(parent.lastPathComponent)” to store the catalog and recovery logs.")
        panel.directoryURL = parent; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        guard selected.resolvingSymlinksInPath() == parent else { error = L10n.text("app.chooseTheFolderContainingTheCatalogFile", defaultValue: "Choose the folder containing the catalog file"); return nil }
        return AccessLease(url: selected)
    }
    func openRecent(_ recent: RecentCatalog) {
        guard canSwitchCatalog, commitRecipe() else { return }
        perform {
            let lease = try AccessLease(bookmark: recent.bookmark)
            let url = lease.url.appendingPathComponent(recent.filename)
            if url.resolvingSymlinksInPath().standardizedFileURL == catalog?.fileURL { return }
            requestCatalogOpen(CatalogOpenRequest(url: url, access: lease, bookmark: recent.bookmark))
        }
    }
    private func rememberCatalog(_ url: URL, directory: URL, bookmark: Data? = nil, replacing oldURL: URL? = nil) throws {
        guard usesPreferences else { return }
        let entry = RecentCatalog(path: url.path, filename: url.lastPathComponent, bookmark: try bookmark ?? AccessLease.bookmark(directory, readOnly: false))
        recentCatalogs.removeAll { $0.path == entry.path || $0.path == oldURL?.path }
        recentCatalogs.insert(entry, at: 0); recentCatalogs = Array(recentCatalogs.prefix(10))
        UserDefaults.standard.set(try JSONEncoder().encode(recentCatalogs), forKey: "recentCatalogs")
    }
    func activateCatalog(_ next: CatalogStore, restoringWorkspace: Bool = false) throws {
        guard !busy, commitRecipe() else { throw LRCError(L10n.text("app.theCurrentCatalogHasActiveTasksOrUnsavedAdjustments", defaultValue: "The current catalog has active tasks or unsaved adjustments")) }
        // Validate all initial reads before releasing the current working catalog.
        _ = try next.page(PhotoQuery(), offset: 0, limit: pageSize)
        _ = try next.roots(); _ = try next.collections()
        persistWorkspace()
        clearBrowseHistory()
        if isViewingRelated { try catalog?.releaseResults(String(scope.dropFirst(8))) }
        if let context = importBrowseContext, context.scope.hasPrefix("related:") { try catalog?.releaseResults(String(context.scope.dropFirst(8))) }
        relatedBrowseTitle = nil
        if let id = importBrowseContext?.heldID { try catalog?.releaseResults(id) }
        if let batch = lastImport { try catalog?.releaseResults(batch.snapshotID) }
        importBrowseContext = nil; lastImport = nil; importCatalog = nil; showImportCompletion = false; importingPhotoIDs = []
        lastExportResult = nil; exportRecordIDs = nil; exportRecordsUnfinishedOnly = false
        if let id = heldResultsID { try catalog?.releaseResults(id) }; heldResultsID = nil
        comparison?.cancel(); comparison = nil; survey?.cancel(); survey = nil
        clearSavedEditPreview(); endAdjustmentPreview(redraw: false); presetListFocused = false; displayPixelReadout = nil; beforeReference = nil; endMaskEffectPreview(redraw: false)
        endDevelopReference(); pinnedDevelopPhoto = nil
        previewTask?.cancel(); previewGeneration = UUID(); pendingPreview = nil; pendingQualityPreview = nil
        qualityWorker?.cancel(); qualityRender?.cancel(); maskReferenceTask?.cancel(); maskReferenceToken = UUID()
        undo.removeAllActions(); scrollPositions = [:]; scrollActiveIDs = [:]
        cancelPointColorTools(); selectedPointColorID = nil
        cancelWhiteBalanceSampling()
        catalog = next; error = nil
        selection = []; activeID = nil; activePhoto = nil; photos = []; roots = []; collections = []; folders = [:]
        viewPositions = [:]; lockViewPosition = false
        collectionMembers = []; reports = []; pageOffset = 0; folderPhotoCount = -1
        photoSwitchDisplay = nil; retainedEditorDisplay = nil; loadingPhoto = false
        recipe = nil; savedRecipe = nil; renderedCropRecipe = nil; image = nil; histogram = nil; dirty = false; canEdit = false; rawDefaults = nil
        orientedSourceSize = nil; renderedNativeSize = nil; renderedCoordinateRecipe = nil; imageStatus = L10n.text("app.noPhotoSelected", defaultValue: "No photo selected")
        editHistory = []; editSnapshots = []; copiedRecipe = nil; copiedLocalParameters = nil; localParameterPresets = []; copiedPhotoName = ""; copiedAdjustmentPhoto = nil; previousAdjustmentSource = nil; adjustmentRequest = nil; hasMoreHistory = false
        cropMode = false; maskMode = false; spotMode = false; maskReference = nil; maskGesture = nil; selectedMaskID = nil; selectedComponentID = nil
        selectedSpotID = nil; spotRenderedOffsets = [:]
        before = false; fullResolution = false; fillView = false; singleView = false; editMode = false; librarySingleView = false
        beforeAfter = .off; resetBeforeImage(); showClipping = false
        scope = "all"; search = ""; ratingComparison = .atLeast; ratingThreshold = 0; flagFilter = []; colorLabelFilter = []; keywordFilter = ""; filtersEnabled = true
        metadataFilter = LibraryMetadataFilter(); filterSections = [.attribute]; photoSort = .captureDate; manualOrderEnabled = false; sortDescending = false; holdFilterResults = false
        if restoringWorkspace { try restoreCatalogWorkspace() }
        else {
            try reload(); configureCache()
            status = L10n.text("app.openedPhotos", defaultValue: "Opened \(catalogName) · \(totalCount) photos")
        }
    }
}

extension AppModel {
    func createVirtualCopies() {
        guard !busy, !applyingAdjustments, let catalog, !selection.isEmpty, commitRecipe() else { return }
        perform {
            let previousStacks = try catalog.stacks()
            let made = try catalog.createVirtualCopies(ids:selection)
            undo.registerUndo(withTarget:self) { $0.restoreVersionDeletion(Dictionary(uniqueKeysWithValues:made.map { ($0.id,true) }), stacks:previousStacks) }
            undo.setActionName(L10n.text("app.createVirtualCopy", defaultValue: "Create Virtual Copy"))
            try reload()
            let visible = try catalog.resultIDs(query,within:Set(made.map(\.id)))
            if let id = made.last(where:{ visible.contains($0.id) })?.id {
                if let offset = try catalog.offset(of:id,query:query) { pageOffset = offset / pageSize * pageSize; try reloadPhotos() }
                choose(visible,active:id)
            }
            status = L10n.text("app.createdVirtualCopiesWithSharedOriginalsAndIndependentEdits", defaultValue: "Created \(made.count) virtual copies with shared originals and independent edits. Copies follow their originals in existing stacks; unstacked versions remain unstacked") + (holdFilterResults ? L10n.text("app.includedInHeldResultsAfterRefresh", defaultValue: " · Included in held results after refresh") : "")
        }
    }
    func deleteSelectedVersions() {
        guard !busy, !applyingAdjustments, commitRecipe(), !selection.isEmpty else { return }
        restoreVersionDeletion(Dictionary(uniqueKeysWithValues:selection.map { ($0,true) }))
        undo.setActionName(L10n.text("app.removeEditVersion", defaultValue: "Remove Edit Version"))
    }
    private func restoreVersionDeletion(_ states:[String:Bool], stacks:[PhotoStack]? = nil, preserveUnrelatedDraft: Bool = false) {
        guard let catalog, (preserveUnrelatedDraft && states[activeID ?? ""] == nil) || commitRecipe() else { return }
        perform {
            let oldStacks = try catalog.stacks(), oldSelection = selection, oldActive = activeID
            let inverse = try catalog.setVersionDeletion(states,restoringStacks:stacks)
            undo.registerUndo(withTarget:self) { target in
                target.restoreVersionDeletion(inverse,stacks:oldStacks,preserveUnrelatedDraft:preserveUnrelatedDraft)
                target.restoreStackSelection(oldSelection,active:oldActive)
            }
            if comparison != nil { endComparison() }
            try reload(); reconcileVisibleSelection()
            status = L10n.text("app.editVersionsUpdatedOriginalsAndSharedEditAssetsPreserved", defaultValue: "Edit versions updated · Originals and shared edit assets preserved")
        }
    }
    func renameVirtualCopy(id:String,name:String) {
        guard let catalog, commitRecipe() else { return }
        perform {
            let previous = try catalog.renameVersion(id:id,name:name)
            undo.registerUndo(withTarget:self) { $0.renameVirtualCopy(id:id,name:previous) }
            undo.setActionName(L10n.text("app.renameVirtualCopy", defaultValue: "Rename Virtual Copy"))
            try reload()
        }
    }
    func openVersion(_ id:String) {
        guard workspaceAvailable, commitRecipe(), let catalog else { return }
        perform {
            guard let target = try catalog.photo(id) else { throw LRCError(L10n.text("app.thisVersionWasRemoved", defaultValue: "This version was removed")) }
            if let offset = try catalog.offset(of: id, query: query) {
                try rememberBrowseDeparture()
                endComparison(); endSurvey()
                pageOffset = offset / pageSize * pageSize; try reloadPhotos()
                choose([id], active: id)
            } else {
                let ids = try catalog.versions(sourceID: target.sourceKey).map(\.id)
                try beginRelatedBrowsing(ids: ids, active: id, title: L10n.text("app.relatedVersions", defaultValue: "Related versions · ") + target.name)
            }
            showNotice(L10n.text("app.versionOpened", defaultValue: "Version opened · ") + target.versionName + L10n.text("app.returnToPreviousBrowseLocation", defaultValue: " · Return to previous browse location"))
        }
    }
    private func beginRelatedBrowsing(ids: [String], active: String, title: String) throws {
        guard let catalog else { return }
        let available = Set(try catalog.photos(ids: Set(ids)).map(\.id))
        guard available.contains(active) else { throw LRCError(L10n.text("app.theGroupTargetWasRemoved", defaultValue: "The group target was removed")) }
        // Preserve source/stack order in the temporary relation. `photos(ids:)`
        // is intentionally a general browse sort, while related navigation
        // must follow the caller's version or stack sequence.
        let ordered = ids.filter { available.contains($0) }
        let snapshot = try catalog.snapshotPhotos(ordered)
        do {
            try rememberBrowseDeparture()
            endComparison(); endSurvey()
            try discardTransientBrowse()
            scope = "related:" + snapshot; relatedBrowseTitle = title
            filtersEnabled = false; holdFilterResults = false; manualOrderEnabled = false
            pageOffset = 0
            try reloadPhotos()
            if let offset = try catalog.offset(of: active, query: query) {
                pageOffset = offset / pageSize * pageSize; try reloadPhotos()
            }
            choose([active], active: active)
        } catch {
            if scope != "related:" + snapshot { try? catalog.releaseResults(snapshot) }
            throw error
        }
    }
    func compareRelatedVersions(inStack: Bool = false) {
        guard workspaceAvailable, commitRecipe(), let active, let catalog else { return }
        perform {
            let ids = inStack ? (activeStack?.members ?? []) : try catalog.versions(sourceID: active.sourceKey).map(\.id)
            let existing = Set(try catalog.photos(ids: Set(ids)).map(\.id))
            let group = ids.filter { existing.contains($0) }
            guard group.count >= 2, let candidate = group.first(where: { $0 != active.id }) else {
                throw LRCError(inStack ? L10n.text("app.thisStackHasNoOtherAvailableVersions", defaultValue: "This stack has no other available versions") : L10n.text("app.thisOriginalHasNoOtherAvailableVersions", defaultValue: "This original has no other available versions"))
            }
            try beginRelatedBrowsing(ids: group, active: active.id, title: inStack ? L10n.text("app.stackMembers", defaultValue: "Stack Members") : L10n.text("app.relatedVersions", defaultValue: "Related versions · ") + active.name)
            choose(Set(group), active: active.id)
            beginComparison(candidateID: candidate)
            comparison?.groupIDs = group; comparison?.restrictToGroup = true
            showNotice(L10n.text("app.compareWithinThisGroupReturnToPreviousBrowseLocation", defaultValue: "Compare within this group · Return to previous browse location"))
        }
    }
}

extension AppModel {
    @discardableResult func saveSmartCollection(id:String,name:String,rules:SmartRules) -> Bool {
        guard let catalog, !busy, commitRecipe() else { return false }
        do {
            let collection = try PhotoCollection(id:id,name:name.trimmingCharacters(in:.whitespacesAndNewlines),rules:JSONEncoder().encode(rules))
            let old = try catalog.replaceSmartCollection(id:id,with:collection)
            undo.registerUndo(withTarget:self) { $0.restoreSmartCollection(id:id,value:old) }
            undo.setActionName(old == nil ? L10n.text("app.createSmartCollection", defaultValue: "Create Smart Collection") : L10n.text("app.editSmartCollection", defaultValue: "Edit Smart Collection"))
            try reload()
            if old == nil { clearFilters(); setScope("collection:"+id) }
            else if scope == "collection:"+id { filterChanged() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteSmartCollection(_ id:String) { restoreSmartCollection(id:id,value:nil); undo.setActionName(L10n.text("app.deleteSmartCollection", defaultValue: "Delete Smart Collection")) }
    private func restoreSmartCollection(id:String,value:PhotoCollection?) {
        guard let catalog, commitRecipe() else { return }
        perform {
            let inverse = try catalog.replaceSmartCollection(id:id,with:value)
            undo.registerUndo(withTarget:self) { $0.restoreSmartCollection(id:id,value:inverse) }
            if value == nil, scope == "collection:"+id { scope = "all" }
            try reload(); filterChanged()
        }
    }
}
