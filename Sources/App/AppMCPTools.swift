import AppKit
import Combine
import GRDB
import MCP

enum AppMCPTool: String, CaseIterable {
    case capabilities = "get_capabilities"
    case workspace = "get_workspace"
    case listPhotos = "list_photos"
    case preview = "get_photo_preview"
    case editPhotoDraft = "edit_photo_draft"
    case rate = "set_photo_rating"
    case undo = "undo_operation"
    case librarySources = "list_library_sources", recentCatalogs = "list_recent_catalogs"
    case fileAccess = "request_file_access", createCatalog = "create_catalog", openCatalog = "open_catalog"
    case relocateRoot = "relocate_library_root", locateOriginal = "locate_photo_original"
    case planImport = "plan_photo_import", startImport = "start_photo_import", resolveConflict = "resolve_import_conflict"
    case recentImport = "show_recent_import", scanFolder = "scan_library_folder"
    case planFolder = "plan_folder_review", applyFolder = "apply_folder_review"
    case importRecords = "list_import_records", resumeImport = "resume_photo_import"
    case restoreBackup = "restore_import_backup", cleanBackup = "clean_import_backup"
    case job = "get_job", cancelJob = "cancel_job"
    case setQuery = "set_library_query", refreshQuery = "refresh_library_query"
    case listSelected = "list_selected_photos", selectPhotos = "select_photos", navigate = "navigate_library"
    case workspaceView = "set_workspace_view", viewport = "set_viewport", compare = "set_compare_photos", survey = "set_survey_photos"
    case developReference = "set_develop_reference", clipping = "set_clipping_display", retryPreview = "retry_photo_preview"
    case rateBatch = "set_photo_ratings", marks = "set_photo_marks", redo = "redo_operation"
    case keywords = "list_keywords", editKeywords = "edit_photo_keywords", renameKeyword = "rename_keyword", caption = "set_photo_caption"
    case getCollection = "get_collection", saveCollection = "save_collection", deleteCollection = "delete_collection"
    case collectionMembers = "set_collection_members", targetCollection = "set_target_collection"
    case quickCollection = "edit_quick_collection", reorderCollection = "reorder_collection"
    case saveSmartCollection = "save_smart_collection", deleteSmartCollection = "delete_smart_collection"
    case listVersions = "list_photo_versions", listEditRecords = "list_edit_records", createCopies = "create_virtual_copies"
    case renameVersion = "rename_photo_version", removeVersions = "remove_photo_versions"
    case listStacks = "list_photo_stacks", editStack = "edit_photo_stack", planStacks = "plan_auto_stacks", applyStacks = "apply_auto_stacks"
    case listPairs = "list_raw_jpeg_pairs", planPairs = "plan_raw_jpeg_pairs", applyPairs = "apply_raw_jpeg_pairs", unlinkPair = "unlink_raw_jpeg_pair"
    case photoRecipe = "get_photo_recipe", globalAdjustments = "set_global_adjustments", resetAdjustments = "reset_adjustments"
    case toneCurve = "set_tone_curve", zoneLighting = "set_zone_lighting", colorAdjustments = "set_color_adjustments"
    case detailAdjustments = "set_detail_adjustments", effects = "set_effects"
    case automaticAdjustment = "run_automatic_adjustment", relativeExposure = "apply_relative_exposure", matchExposure = "match_total_exposures"
    case transferAdjustments = "transfer_adjustments", beforeAfter = "set_before_after", adjustmentPreview = "preview_adjustment"
    case listPresets = "list_adjustment_presets", editPreset = "edit_adjustment_preset"
    case planXMP = "plan_xmp_preset_import", importXMP = "import_xmp_presets"
    case applyEditRecord = "apply_edit_record", saveSnapshot = "save_edit_snapshot", deleteSnapshot = "delete_edit_snapshot"
    case setCrop = "set_crop", photoGeometry = "set_photo_geometry", solvePerspective = "solve_perspective"
    case perspectiveGuides = "edit_perspective_guides", canvasGuides = "set_canvas_guides"
    case samplePreview = "sample_preview", adjustPreview = "adjust_from_preview", pointColor = "edit_point_color"
    case spotRepairs = "get_spot_repairs", editSpot = "edit_spot_repair"
    case maskState = "get_mask_state", maskGroup = "edit_mask_group", maskComponent = "edit_mask_component"
    case brushStroke = "apply_mask_brush_stroke", maskShape = "set_mask_shape", maskRange = "set_mask_range"
    case maskDisplay = "set_mask_display", localAdjustments = "set_local_adjustments"
    case transferLocal = "transfer_local_adjustments", listLocalPresets = "list_local_adjustment_presets"
    case editLocalPreset = "edit_local_adjustment_preset"
    case smartStart = "start_smart_mask", smartEdit = "edit_smart_mask_selection", smartApply = "apply_smart_mask"
    case planMerge = "plan_photo_merge", renderMerge = "render_merge_preview", getMergePreview = "get_merge_preview"
    case saveMerge = "save_photo_merge"
    case listExportPresets = "list_export_presets", editExportPreset = "edit_export_preset"
    case planExport = "plan_export", getExportPreview = "get_export_preview", runExport = "run_export"
    case exportRecords = "list_export_records", retryExport = "verify_or_retry_export", reauthorizeExport = "reauthorize_export_location"
    case revealFile = "reveal_file_in_finder"
    case getPreferences = "get_preferences", setPreferences = "set_preferences", showAppPanel = "show_app_panel"
    case listLanguagePacks = "list_language_packs", editLanguagePack = "edit_language_pack", selectLanguage = "select_language"
    case storageUsage = "get_storage_usage", setCacheQuota = "set_cache_quota", clearThumbnailCache = "clear_thumbnail_cache"
    case backupCatalog = "back_up_catalog", restoreCatalogBackup = "restore_catalog_backup", exportCatalogManifest = "export_catalog_manifest"
    case runCameraDiagnostics = "run_camera_diagnostics", getCameraDiagnosticPreview = "get_camera_diagnostic_preview"
    case saveCameraDiagnosticReport = "save_camera_diagnostics_report"

    enum Field: String {
        case catalog = "catalog_session_id", photo = "photo_id", cursor, pageSize = "page_size"
        case query, contactSheet = "contact_sheet"
        case sourceRevision = "source_revision", recipeRevision = "recipe_revision", longEdge = "long_edge"
        case expectedRating = "expected_rating", rating, epoch = "request_epoch", request = "request_id", operation = "operation_id"
        case offset, purpose, access = "access_id", recent = "recent_catalog_id", name, root = "root_id", folder = "folder_id"
        case sourceAccess = "source_access_id", destinationAccess = "destination_access_id", mode, recursive = "include_subfolders"
        case skipCataloged = "skip_cataloged", layout = "date_layout", archiveDate = "archive_date", sidecars = "include_sidecars"
        case collection = "collection_id", pair = "detect_pairs", policy, basePlan = "base_plan_id", attachments = "attachment_assignments"
        case plan = "plan_id", candidates = "candidate_ids", all = "select_all", job = "job_id", conflict = "conflict_id"
        case remaining = "apply_to_remaining", action, differences = "difference_ids", locations = "locations"
        case record = "record_id", member = "member_id"
        case source = "source_id", search, ratingComparison = "rating_comparison", ratingThreshold = "rating_threshold"
        case flags, labels = "color_labels", keyword, camera, lens, minimumISO = "minimum_iso", maximumISO = "maximum_iso"
        case dateFrom = "date_from", dateThrough = "date_through", sort, descending, hold = "hold_results"
        case filtersEnabled = "filters_enabled", filterSections = "filter_sections", filtersOpen = "filters_open", clearFilters = "clear_filters"
        case listing, queryRevision = "query_revision", selectionRevision = "selection_revision"
        case photoIDs = "photo_ids", activePhoto = "active_photo_id", referencePhoto = "reference_photo_id", candidatePhoto = "candidate_photo_id"
        case browseLocation = "location_id", view, tool, pane, zoom, scale, x, y, linked, locked, restricted = "restrict_to_group"
        case highlights, shadows, advance, markTargets = "targets", flag, label = "color_label", ratingStep = "rating_step"
        case keywordNames = "keywords", keywordID = "keyword_id", caption, expectedCaptions = "expected_captions"
        case collectionRevision = "collection_revision", manualOrder = "manual_order", beforePhoto = "before_photo_id"
        case rules, fromQuery = "from_current_query", expectedName = "expected_name"
        case versionRevisions = "expected_revisions", historyID = "history_id", snapshotID = "snapshot_id", recordType = "record_type"
        case stackID = "stack_id", stackIDs = "stack_ids", stackRevision = "stack_revision", direction, scope
        case interval = "interval_seconds", pairID = "pair_id", rawSource = "raw_source_id", jpegSource = "jpeg_source_id", sameCapture = "same_capture"
        case adjustments, group, groups, channel, points, pointIndex = "point_index", gains, amount, delta
        case presetID = "preset_id", presetRevision = "preset_revision", snapshotRevision = "snapshot_revision"
        case presetGroup = "preset_group", favorite, favoritesOnly = "favorites_only", previewVariant = "preview_variant", beforeLayout = "before_layout"
        case previewID = "preview_id", region, point, rect, aspectRatio = "aspect_ratio", turns
        case resolution, regionPixels = "region_pixels", planOnly = "plan_only"
        case draftID = "draft_id", draftRevision = "draft_revision", strokeIndex = "stroke_index"
        case straighten, flipHorizontal = "flip_horizontal", flipVertical = "flip_vertical", perspective
        case cropGuide = "crop_guide", spotGuides = "spot_guides", guideMode = "guide_mode", endpoint
        case start, end, sampleID = "sample_id", affectedRange = "affected_range", histogramRegion = "histogram_region"
        case spotID = "spot_id", spotMode = "spot_mode", sourcePoint = "source_point", sourcePreviewID = "source_preview_id"
        case path, radius, feather, opacity, enabled
        case maskID = "mask_id", componentID = "component_id", maskKind = "mask_kind", maskOperation = "mask_operation"
        case inverted, refinement, flow, density, erase, autoMask = "auto_mask", radiusX = "radius_x", radiusY = "radius_y", angle
        case sampleIndex = "sample_index", refine, lower, upper, smoothness
        case overlay, guides, overlayStyle = "overlay_style", overlayColor = "overlay_color", hideEffect = "hide_effect"
        case maskOverlay = "mask_overlay", withoutMaskID = "without_mask_id"
        case workflow, smartSessionID = "smart_session_id", smartOverlay = "smart_overlay"
        case candidateIndex = "candidate_index", personIndices = "person_indices", faceIndex = "face_index", part
        case separate, wholePerson = "whole_person"
        case mergeKind = "merge_kind", outputOptions = "options", displayEV = "display_ev"
        case masterFormat = "master_format", filename, stackWithSources = "stack_with_sources"
        case specifications, outputID = "output_id", recordIDs = "record_ids"
        case unfinishedOnly = "unfinished_only", includeCompleted = "include_completed"
        case fileID = "file_id", revealKind = "kind"
        case preferences, panel, packID = "pack_id", quotaGiB = "quota_gib", reportID = "report_id", previewKind = "preview_kind"

        private func range(for tool: AppMCPTool) -> ClosedRange<Int>? {
            switch self {
            case .pageSize: 1...200
            case .longEdge: 1...1024
            case .expectedRating, .rating, .ratingThreshold: 0...5
            case .flag: -1...1
            case .label: 0...5
            case .minimumISO, .maximumISO: 0...Int.max
            case .sourceRevision, .recipeRevision, .draftRevision, .strokeIndex: 0...Int.max
            case .offset: 0...Int.max
            case .historyID: 1...Int.max
            case .pointIndex: 0...(ToneCurves.maxPoints - 1)
            case .turns: -3...3
            case .sampleIndex: tool == .getCameraDiagnosticPreview ? 1...CameraDiagnostics.maximumSamples : 0...15
            case .candidateIndex, .faceIndex: 0...255
            default: nil
            }
        }
        private func options(for tool: AppMCPTool) -> [String]? {
            switch self {
            case .purpose: MCPFilePurpose.allCases.map(\.rawValue)
            case .mode: tool == .solvePerspective ? UprightMode.allCases.map(\.rawValue) : ["reference", "copy"]
            case .layout: DateLayout.allCases.map(\.rawValue)
            case .policy: ["ask"] + ConflictPolicy.allCases.map(\.rawValue)
            case .ratingComparison: RatingComparison.allCases.map(\.rawValue)
            case .sort: PhotoSort.allCases.map(\.rawValue) + ["manual"]
            case .listing: tool == .listPairs ? ["pairs", "sources"] : ["visible", "matches"]
            case .recordType: ["history", "snapshots"]
            case .direction: ["earlier", "later"]
            case .scope: tool == .planPairs ? ["catalog", "query", "selection"] : ["query", "selection"]
            case .view: WorkspaceMode.allCases.map(\.rawValue)
            case .tool: DevelopTool.allCases.map(\.rawValue)
            case .pane: tool == .showAppPanel ? MCPAppPanel.settingsPanes.keys.sorted() : ["main", "reference", "candidate", "develop_reference"]
            case .zoom: ["fit", "fill", "scale"]
            case .action: tool.actions
            case .group:
                tool == .localAdjustments ? MCPDevelopParameters.localGroups.map(\.rawValue) + ["all"]
                    : MCPDevelopParameters.groups.map(\.rawValue) + (tool == .resetAdjustments ? ["all"] : [])
            case .channel: MCPDevelopParameters.channels
            case .previewVariant: ["saved", "original", "before", "crop_canvas"]
            case .resolution: ["scaled", "native"]
            case .beforeLayout: ["off", "original", "side_by_side", "split"]
            case .cropGuide: CropGuide.allCases.map(\.rawValue)
            case .guideMode: ["straighten", "perspective"]
            case .endpoint: ["start", "end"]
            case .histogramRegion: MCPCanvasFields.histogramRegions
            case .spotMode: SpotRepairMode.allCases.map(\.rawValue)
            case .maskKind: MaskTool.allCases.filter { $0 != .object }.map(\.rawValue)
            case .maskOperation: MaskOperation.allCases.filter { $0 != .replace }.map(\.rawValue)
            case .overlayStyle: MCPMaskOverlay.styles
            case .overlayColor: MCPMaskOverlay.colors
            case .workflow: ["object", "people"]
            case .part: SmartMaskPart.allCases.map(\.rawValue)
            case .mergeKind: PhotoMergeKind.allCases.map(\.rawValue)
            case .masterFormat: MergeMasterFormat.allCases.map(\.rawValue)
            case .revealKind: ["catalog", "export", "merge", "import_backup"]
            case .panel: MCPAppPanel.allCases.map(\.rawValue)
            case .previewKind: ["rendered", "embedded"]
            default: nil
            }
        }
        private var isBoolean: Bool {
            [.recursive, .skipCataloged, .sidecars, .pair, .all, .remaining, .descending, .hold, .filtersEnabled,
             .filtersOpen, .clearFilters, .linked, .locked, .restricted, .highlights, .shadows, .advance,
             .manualOrder, .fromQuery, .sameCapture, .favorite, .favoritesOnly, .flipHorizontal, .flipVertical,
             .spotGuides, .affectedRange, .enabled, .inverted, .erase, .autoMask, .overlay, .guides, .hideEffect,
             .separate, .wholePerson, .stackWithSources, .unfinishedOnly, .includeCompleted, .planOnly, .contactSheet].contains(self)
        }
        private var textCriteria: Bool { [.search, .keyword, .camera, .lens, .dateFrom, .dateThrough, .presetGroup].contains(self) }
        private var maxString: Int {
            switch self {
            case .folder, .source: 4096
            case .filename: 240
            case .outputID: 300
            case .name, .expectedName: 255
            case .search, .camera, .lens: 512
            case .keyword, .keywordID: 1024
            case .dateFrom, .dateThrough: 10
            default: 128
            }
        }
        private func nameLimit(for tool: AppMCPTool) -> Int {
            if self == .presetGroup || (self == .name && [.editPreset, .saveSnapshot, .editLocalPreset, .editExportPreset].contains(tool)) { return 100 }
            if self == .name && [.maskGroup, .maskComponent].contains(tool) { return 200 }
            return maxString
        }
        private var identifierSchema: Value { ["type": "string", "minLength": 1, "maxLength": 128] }
        func schema(for tool: AppMCPTool) -> Value {
            if let range = range(for: tool) {
                var schema: [String: Value] = ["type": "integer", "minimum": .int(range.lowerBound)]
                if range.upperBound != Int.max { schema["maximum"] = .int(range.upperBound) }
                if self == .pageSize {
                    if tool == .listPhotos {
                        schema["description"] = .string("Defaults to 50, or \(MCPContactSheet.defaultCount) with contact_sheet.")
                    } else { schema["default"] = 50 }
                }
                if self == .longEdge { schema["default"] = 768 }
                return .object(schema)
            }
            if let options = options(for: tool) { return ["type": "string", "enum": .array(options.map(Value.string))] }
            if isBoolean { return ["type": "boolean"] }
            switch self {
            case .query:
                return ["type": "object", "additionalProperties": false, "properties": .object(
                    Dictionary(uniqueKeysWithValues: MCPLibraryCriteria.fields.map { ($0.rawValue, $0.schema(for: tool)) }))]
            case .adjustments: return tool == .pointColor ? MCPCanvasFields.pointColorSchema : MCPDevelopParameters.schema(tool)
            case .preferences: return MCPPreferences.schema
            case .quotaGiB: return ["type": "integer", "enum": .array(ThumbnailService.quotaOptions.map(Value.int))]
            case .outputOptions: return tool == .planMerge ? MCPMergeOptions.schema : MCPExportOptions.schema
            case .specifications: return MCPExportOptions.specificationsSchema
            case .displayEV: return MCPDevelopParameters.numberSchema(-5...5)
            case .start, .end: return tool == .maskShape ? MCPCanvasFields.gradientPointSchema : MCPCanvasFields.pointSchema
            case .point, .sourcePoint: return MCPCanvasFields.pointSchema
            case .path: return MCPCanvasFields.pathSchema
            case .radius: return MCPDevelopParameters.numberSchema(0.001...1)
            case .feather, .opacity, .flow, .density, .lower, .upper, .smoothness: return MCPCanvasFields.unit
            case .radiusX, .radiusY: return MCPDevelopParameters.numberSchema(0.001...100)
            case .angle: return MCPDevelopParameters.numberSchema(-180...180)
            case .refine: return MCPDevelopParameters.numberSchema(0...100)
            case .refinement: return MCPMask.refinementSchema
            case .maskOverlay: return MCPMaskOverlay.schema
            case .smartOverlay: return MCPSmartOverlay.schema
            case .personIndices:
                return ["type": "array", "maxItems": 64, "uniqueItems": true, "items": Field.candidateIndex.schema(for: tool)]
            case .region, .rect: return MCPCanvasFields.rectSchema
            case .regionPixels: return MCPCanvasFields.pixelRectSchema
            case .perspective: return MCPCanvasFields.perspectiveSchema
            case .aspectRatio: return MCPDevelopParameters.numberSchema(0.1...10)
            case .straighten: return MCPDevelopParameters.numberSchema(-45...45)
            case .points: return MCPDevelopParameters.pointsSchema
            case .gains: return MCPDevelopParameters.gainsSchema
            case .groups:
                return ["type": "array", "minItems": 1, "maxItems": .int(MCPRecipeGroups.keys.count), "uniqueItems": true,
                        "items": ["enum": .array(MCPRecipeGroups.keys.map(Value.string))]]
            case .amount: return MCPDevelopParameters.numberSchema(tool == .localAdjustments ? 0...1 : 0...2)
            case .delta: return MCPDevelopParameters.numberSchema(tool == .adjustPreview ? -200...200 : -5...5)
            case .scale: return ["type": "number", "enum": .array(AppModel.zoomScales.map(Value.double))]
            case .x, .y: return ["type": "number", "minimum": 0, "maximum": 1]
            case .ratingStep: return ["type": "integer", "enum": [-1, 1]]
            case .flags, .labels, .filterSections:
                let values: [Value] = switch self {
                case .flags: PhotoFlag.allCases.map { .int($0.rawValue) }
                case .labels: PhotoColorLabel.allCases.map { .int($0.rawValue) }
                default: LibraryFilterSection.allCases.map { .string($0.rawValue) }
                }
                return ["type": "array", "uniqueItems": true, "items": ["enum": .array(values)]]
            case .photoIDs, .stackIDs, .recordIDs:
                let count = tool == .planMerge ? 2...128 : 1...1000
                return ["type": "array", "minItems": .int(count.lowerBound), "maxItems": .int(count.upperBound),
                        "uniqueItems": true, "items": identifierSchema]
            case .interval:
                return ["type": "number", "minimum": 0, "maximum": 86400]
            case .rules: return MCPCollectionState.rulesSchema
            case .versionRevisions:
                let revision: Value = ["type": "integer", "minimum": 0]
                return ["type": "object", "minProperties": 1, "maxProperties": 1000, "propertyNames": identifierSchema,
                        "additionalProperties": ["type": "object", "additionalProperties": false,
                                                  "required": ["source_revision", "recipe_revision"],
                                                  "properties": ["source_revision": revision, "recipe_revision": revision]]]
            case .markTargets:
                return ["type": "array", "minItems": 1, "maxItems": 200, "items": [
                    "type": "object", "additionalProperties": false, "required": ["photo_id"],
                    "properties": ["photo_id": identifierSchema, "expected_rating": Field.expectedRating.schema(for: tool),
                                   "expected_flag": Field.flag.schema(for: tool), "expected_color_label": Field.label.schema(for: tool)]
                ]]
            case .keywordNames:
                return ["type": "array", "minItems": 1, "maxItems": 64, "items": ["type": "string", "minLength": 1, "maxLength": 100]]
            case .caption:
                return ["type": "string", "maxLength": 2000]
            case .expectedCaptions:
                return ["type": "object", "minProperties": 1, "maxProperties": 200, "propertyNames": identifierSchema,
                        "additionalProperties": Field.caption.schema(for: tool)]
            default: break
            }
            if self == .candidates || self == .differences {
                return ["type": "array", "minItems": 1, "maxItems": 1000, "uniqueItems": true, "items": identifierSchema]
            }
            if self == .attachments || self == .locations {
                return ["type": "object", "maxProperties": 1000, "propertyNames": identifierSchema, "additionalProperties": identifierSchema]
            }
            return ["type": "string", "minLength": textCriteria ? 0 : 1, "maxLength": .int(nameLimit(for: tool))]
        }
        func accepts(_ value: Value, for tool: AppMCPTool) -> Bool {
            if let range = range(for: tool) { return value.intValue.map(range.contains) ?? false }
            if isBoolean { return value.boolValue != nil }
            if [.candidates, .differences, .photoIDs, .stackIDs, .recordIDs].contains(self) {
                let count = tool == .planMerge ? 2...128 : 1...1000
                guard let values = value.arrayValue, count.contains(values.count) else { return false }
                let ids = values.compactMap(\.stringValue)
                return Set(ids).count == values.count && ids.allSatisfy(Self.isID)
            }
            if self == .attachments || self == .locations {
                guard let values = value.objectValue, values.count <= 1000 else { return false }
                return values.allSatisfy { Self.isID($0.key) && ($0.value.stringValue.map(Self.isID) ?? false) }
            }
            switch self {
            case .query:
                guard let values = value.objectValue else { return false }
                let fields = Dictionary(uniqueKeysWithValues: MCPLibraryCriteria.fields.map { ($0.rawValue, $0) })
                return values.allSatisfy { name, item in fields[name]?.accepts(item, for: tool) == true }
            case .preferences: return MCPDevelopParameters.accepts(value, schema: MCPPreferences.schema)
            case .quotaGiB: return value.intValue.map(ThumbnailService.quotaOptions.contains) ?? false
            case .outputOptions: return MCPDevelopParameters.accepts(value, schema: schema(for: tool))
            case .specifications: return MCPExportOptions.acceptsSpecifications(value)
            case .displayEV: return value.number.map((-5...5).contains) ?? false
            case .adjustments:
                return tool == .pointColor ? MCPDevelopParameters.accepts(value, schema: MCPCanvasFields.pointColorSchema)
                    : MCPDevelopParameters.accepts(value, for: tool)
            case .start, .end: return MCPCanvasFields.point(value, range: tool == .maskShape ? MaskPoint.gradientRange : 0...1) != nil
            case .point, .sourcePoint: return MCPCanvasFields.point(value) != nil
            case .path:
                guard let items = value.arrayValue, (1...4096).contains(items.count) else { return false }
                return items.allSatisfy { MCPCanvasFields.point($0) != nil }
            case .radius: return value.number.map((0.001...1).contains) ?? false
            case .feather, .opacity, .flow, .density, .lower, .upper, .smoothness: return value.number.map((0...1).contains) ?? false
            case .radiusX, .radiusY: return value.number.map((0.001...100).contains) ?? false
            case .angle: return value.number.map((-180...180).contains) ?? false
            case .refine: return value.number.map((0...100).contains) ?? false
            case .refinement: return MCPDevelopParameters.accepts(value, schema: MCPMask.refinementSchema)
            case .maskOverlay: return (try? MCPMaskOverlay(value)) != nil
            case .smartOverlay: return (try? MCPSmartOverlay(value)) != nil
            case .personIndices:
                guard let indices = value.arrayValue, indices.count <= 64, Set(indices).count == indices.count else { return false }
                return indices.allSatisfy { Field.candidateIndex.accepts($0, for: tool) }
            case .region, .rect: return MCPCanvasFields.rect(value) != nil
            case .regionPixels: return MCPCanvasFields.pixelRect(value) != nil
            case .perspective: return MCPDevelopParameters.accepts(value, schema: MCPCanvasFields.perspectiveSchema)
            case .aspectRatio: return value.number.map((0.1...10).contains) ?? false
            case .straighten: return value.number.map((-45...45).contains) ?? false
            case .points: return (try? MCPDevelopParameters.points(value)) != nil
            case .gains: return (try? MCPDevelopParameters.gains(value)) != nil
            case .groups:
                guard let items = value.arrayValue, !items.isEmpty, Set(items).count == items.count else { return false }
                return items.allSatisfy { $0.stringValue.map(MCPRecipeGroups.keys.contains) == true }
            case .amount: return value.number.map((tool == .localAdjustments ? 0.0...1.0 : 0.0...2.0).contains) ?? false
            case .delta: return value.number.map((tool == .adjustPreview ? -200.0...200.0 : -5.0...5.0).contains) ?? false
            case .interval: return value.number.map((0...86400).contains) ?? false
            case .rules: return value.objectValue != nil
            case .versionRevisions:
                guard let values = value.objectValue, (1...1000).contains(values.count) else { return false }
                return values.allSatisfy { id, value in
                    guard Self.isID(id), let revision = value.objectValue, revision.count == 2,
                          let source = revision["source_revision"]?.intValue, let recipe = revision["recipe_revision"]?.intValue else { return false }
                    return source >= 0 && recipe >= 0
                }
            case .scale: return value.number.map(AppModel.zoomScales.contains) ?? false
            case .x, .y: return value.number.map((0...1).contains) ?? false
            case .ratingStep: return value.intValue == -1 || value.intValue == 1
            case .flags, .labels, .filterSections:
                guard let values = value.arrayValue, Set(values).count == values.count,
                      let allowed = schema(for: tool).objectValue?["items"]?.objectValue?["enum"]?.arrayValue else { return false }
                return values.allSatisfy(allowed.contains)
            case .markTargets:
                guard let values = value.arrayValue, (1...200).contains(values.count) else { return false }
                var ids = Set<String>()
                return values.allSatisfy {
                    guard let target = $0.objectValue, let id = target["photo_id"]?.stringValue, Self.isID(id), ids.insert(id).inserted else { return false }
                    return target.allSatisfy { key, value in
                        switch key {
                        case "photo_id": true
                        case "expected_rating": Field.expectedRating.accepts(value, for: tool)
                        case "expected_flag": Field.flag.accepts(value, for: tool)
                        case "expected_color_label": Field.label.accepts(value, for: tool)
                        default: false
                        }
                    }
                }
            case .keywordNames:
                guard let values = value.arrayValue, (1...64).contains(values.count) else { return false }
                return values.allSatisfy { term in
                    guard let text = term.stringValue, (try? KeywordSummary.name(text)) != nil else { return false }
                    return text.rangeOfCharacter(from: CharacterSet(charactersIn: ",，;；")) == nil
                }
            case .caption:
                return value.stringValue.map { (try? PhotoCaption.normalized($0)) != nil } ?? false
            case .expectedCaptions:
                guard let values = value.objectValue, (1...200).contains(values.count) else { return false }
                return values.allSatisfy { Self.isID($0.key) && Field.caption.accepts($0.value, for: tool) }
            default: break
            }
            guard let text = value.stringValue else { return false }
            let limit = nameLimit(for: tool)
            if limit != maxString { return ((textCriteria ? 0 : 1)...limit).contains(text.count) && !text.contains("\0") }
            return options(for: tool)?.contains(text) ?? (((textCriteria ? 0 : 1)...maxString).contains(text.utf8.count) && !text.contains("\0"))
        }
        private static func isID(_ text: String) -> Bool { (1...128).contains(text.utf8.count) && !text.contains("\0") }
    }
    var actions: [String]? {
        switch self {
        case .recentImport: ["show", "start_culling", "return"]
        case .selectPhotos: ["replace", "add", "remove", "clear", "all", "stack", "open_version"]
        case .navigate: ["previous_photo", "next_photo", "previous_page", "next_page", "back", "forward", "location"]
        case .compare: ["set", "swap", "promote", "restrict", "related_versions", "related_stack"]
        case .survey: ["set", "remove", "activate", "open", "previous_page", "next_page"]
        case .developReference: ["pin", "toggle", "clear"]
        case .editKeywords: ["add", "remove"]
        case .collectionMembers: ["add", "remove", "collect_results"]
        case .quickCollection: ["add", "remove"]
        case .reorderCollection: ["set_manual_order", "move"]
        case .editStack: ["group", "remove", "ungroup", "cover", "move", "split", "collapse", "expand"]
        case .planPairs: ["detect", "verify", "manual"]
        case .toneCurve: ["set", "insert", "move", "remove", "reset"]
        case .automaticAdjustment: ["white_balance", "tone"]
        case .transferAdjustments: ["copy", "paste", "sync", "previous", "preset"]
        case .adjustmentPreview: ["saved_edit", "preset", "hide_group", "clear"]
        case .editPreset: ["create", "update", "rename", "delete", "favorite", "move"]
        case .setCrop: ["set", "set_aspect", "lock", "unlock", "rotate_aspect", "reset"]
        case .perspectiveGuides: ["begin", "add", "select", "move_endpoint", "delete", "clear", "finish", "cancel"]
        case .samplePreview: ["rgb", "zone"]
        case .editPhotoDraft: ["begin", "commit", "cancel"]
        case .adjustPreview: ["white_balance", "histogram", "hue", "saturation", "luminance", "black_white", "curve", "defringe_purple", "defringe_green"]
        case .pointColor: ["add", "select", "set", "reset", "delete", "display"]
        case .editSpot: ["add", "select", "set", "move", "set_source", "refresh_source", "auto_source", "delete"]
        case .maskGroup: ["create", "select", "duplicate", "set", "delete"]
        case .maskComponent: ["add", "select", "set", "delete"]
        case .maskRange: ["set", "sample", "append_sample", "replace_sample", "remove_sample", "clear_samples"]
        case .localAdjustments: ["set", "reset"]
        case .transferLocal: ["copy", "paste"]
        case .editLocalPreset: ["create", "apply", "rename", "delete"]
        case .smartEdit:
            ["include", "exclude", "box", "undo_prompt", "select_candidate", "select_people", "select_all_people", "select_whole_person",
             "toggle_part", "select_face", "face_box", "reset_face", "set_separate", "cancel"]
        case .editExportPreset: ["create", "update", "rename", "delete", "restore_defaults"]
        case .editLanguagePack: ["import", "remove"]
        case .selectLanguage: ["official", "community"]
        default: nil
        }
    }

    var required: [Field] {
        switch self {
        case .capabilities, .workspace, .recentCatalogs: []
        case .listPhotos, .listSelected, .librarySources, .importRecords, .setQuery, .refreshQuery, .viewport, .clipping, .keywords: [.catalog]
        case .preview: [.catalog, .photo, .sourceRevision, .recipeRevision]
        case .editPhotoDraft: [.catalog, .action]
        case .rate: [.catalog, .photo, .expectedRating, .rating]
        case .undo, .redo: [.catalog, .operation]
        case .selectPhotos, .navigate, .compare, .survey, .developReference: [.catalog, .action]
        case .workspaceView: [.catalog, .view]
        case .retryPreview: [.catalog, .photo]
        case .rateBatch, .marks: [.catalog, .markTargets]
        case .editKeywords: [.catalog, .action, .photoIDs, .keywordNames]
        case .renameKeyword: [.catalog, .keywordID, .name]
        case .caption: [.catalog, .caption, .expectedCaptions]
        case .getCollection, .deleteCollection, .deleteSmartCollection: [.catalog, .collection]
        case .saveCollection: [.catalog, .name]
        case .collectionMembers, .editStack, .planPairs: [.catalog, .action]
        case .targetCollection, .saveSmartCollection, .listVersions, .listStacks, .listPairs: [.catalog]
        case .quickCollection: [.catalog, .action, .photoIDs]
        case .reorderCollection: [.catalog, .collection, .action]
        case .listEditRecords: [.catalog, .photo]
        case .createCopies, .removeVersions: [.catalog, .photoIDs]
        case .renameVersion: [.catalog, .photo, .name]
        case .planStacks: [.catalog, .interval]
        case .applyStacks: [.catalog, .plan]
        case .applyPairs: [.catalog, .plan, .candidates]
        case .unlinkPair: [.catalog, .pairID]
        case .photoRecipe: [.catalog, .photo]
        case .globalAdjustments, .detailAdjustments, .effects, .colorAdjustments:
            [.catalog, .photo, .sourceRevision, .recipeRevision, .adjustments]
        case .toneCurve: [.catalog, .photo, .sourceRevision, .recipeRevision, .action, .channel]
        case .zoneLighting: [.catalog, .photo, .sourceRevision, .recipeRevision, .gains]
        case .resetAdjustments: [.catalog, .photo, .sourceRevision, .recipeRevision, .group]
        case .automaticAdjustment: [.catalog, .photo, .sourceRevision, .recipeRevision, .action]
        case .relativeExposure: [.catalog, .photoIDs, .versionRevisions, .delta]
        case .matchExposure: [.catalog, .photo, .photoIDs, .versionRevisions]
        case .transferAdjustments: [.catalog, .action, .versionRevisions]
        case .beforeAfter: [.catalog, .photo, .sourceRevision, .recipeRevision, .beforeLayout]
        case .adjustmentPreview: [.catalog, .photo, .sourceRevision, .recipeRevision, .action]
        case .listPresets: [.catalog]
        case .editPreset: [.catalog, .action]
        case .planXMP: [.catalog, .access]
        case .importXMP: [.catalog, .plan]
        case .applyEditRecord: [.catalog, .photo, .sourceRevision, .recipeRevision]
        case .saveSnapshot: [.catalog, .photo, .sourceRevision, .recipeRevision, .name]
        case .deleteSnapshot: [.catalog, .photo, .sourceRevision, .recipeRevision, .snapshotID, .snapshotRevision]
        case .setCrop, .perspectiveGuides, .pointColor, .editSpot, .maskGroup: [.catalog, .photo, .sourceRevision, .recipeRevision, .action]
        case .photoGeometry, .spotRepairs, .maskState, .maskDisplay: [.catalog, .photo, .sourceRevision, .recipeRevision]
        case .maskComponent, .localAdjustments, .transferLocal: [.catalog, .photo, .sourceRevision, .recipeRevision, .maskID, .action]
        case .brushStroke: [.catalog, .photo, .sourceRevision, .recipeRevision, .maskID, .componentID]
        case .maskShape: [.catalog, .photo, .sourceRevision, .recipeRevision, .maskID, .componentID]
        case .maskRange: [.catalog, .photo, .sourceRevision, .recipeRevision, .maskID, .componentID, .action]
        case .listLocalPresets: [.catalog]
        case .editLocalPreset: [.catalog, .action]
        case .smartStart: [.catalog, .photo, .sourceRevision, .recipeRevision, .workflow]
        case .smartEdit: [.catalog, .photo, .sourceRevision, .recipeRevision, .smartSessionID, .selectionRevision, .action]
        case .smartApply: [.catalog, .photo, .sourceRevision, .recipeRevision, .smartSessionID, .selectionRevision]
        case .planMerge: [.catalog, .photoIDs, .versionRevisions, .mergeKind]
        case .renderMerge: [.catalog, .plan]
        case .getMergePreview: [.catalog, .previewID]
        case .saveMerge: [.catalog, .previewID, .destinationAccess]
        case .listExportPresets: []
        case .editExportPreset: [.action]
        case .planExport: [.catalog, .photoIDs, .versionRevisions, .destinationAccess]
        case .getExportPreview, .runExport: [.catalog, .plan]
        case .exportRecords: [.catalog]
        case .retryExport: [.catalog, .recordIDs]
        case .reauthorizeExport: [.catalog, .recordIDs, .access]
        case .revealFile: [.catalog, .revealKind]
        case .getPreferences, .listLanguagePacks, .storageUsage: []
        case .setPreferences: [.preferences]
        case .showAppPanel: [.panel]
        case .editLanguagePack, .selectLanguage: [.action]
        case .setCacheQuota: [.quotaGiB]
        case .clearThumbnailCache: [.catalog]
        case .backupCatalog, .exportCatalogManifest: [.catalog, .destinationAccess]
        case .restoreCatalogBackup: [.sourceAccess, .destinationAccess, .name]
        case .runCameraDiagnostics: [.access]
        case .getCameraDiagnosticPreview: [.reportID, .sampleIndex]
        case .saveCameraDiagnosticReport: [.reportID, .destinationAccess]
        case .solvePerspective: [.catalog, .photo, .sourceRevision, .recipeRevision, .mode]
        case .canvasGuides: [.catalog]
        case .samplePreview: [.catalog, .previewID, .point]
        case .adjustPreview: [.catalog, .photo, .sourceRevision, .recipeRevision, .previewID, .action]
        case .fileAccess: [.purpose]
        case .createCatalog: [.access, .name]
        case .openCatalog: []
        case .relocateRoot: [.catalog, .root, .access]
        case .locateOriginal: [.catalog, .photo, .sourceRevision, .access]
        case .planImport: [.catalog, .mode, .sourceAccess]
        case .startImport: [.catalog, .plan]
        case .resolveConflict: [.job, .conflict, .policy, .remaining]
        case .recentImport: [.catalog, .action]
        case .scanFolder, .planFolder: [.catalog, .root]
        case .applyFolder: [.catalog, .plan, .differences]
        case .resumeImport: [.catalog, .record]
        case .restoreBackup: [.catalog, .record, .member, .access]
        case .cleanBackup: [.catalog, .record, .member]
        case .job, .cancelJob: [.job]
        }
    }
    var optional: [Field] {
        switch self {
        case .preview, .photoRecipe, .globalAdjustments, .colorAdjustments, .transferAdjustments,
             .samplePreview, .spotRepairs, .editSpot, .maskState, .maskGroup, .maskComponent, .brushStroke,
             .maskShape, .maskRange, .localAdjustments:
            return optionalFields + [.draftID, .draftRevision]
        default: return optionalFields
        }
    }

    private var optionalFields: [Field] {
        switch self {
        case .listPhotos: [.cursor, .pageSize, .listing, .query, .contactSheet]
        case .listSelected: [.cursor, .pageSize]
        case .setQuery: MCPLibraryCriteria.fields + [.hold, .filtersEnabled, .filterSections, .filtersOpen, .clearFilters, .queryRevision]
        case .refreshQuery: [.queryRevision]
        case .selectPhotos: [.photoIDs, .photo, .activePhoto, .queryRevision, .selectionRevision]
        case .navigate: [.browseLocation]
        case .workspaceView: [.tool]
        case .viewport: [.pane, .zoom, .scale, .x, .y, .linked, .locked]
        case .compare: [.referencePhoto, .candidatePhoto, .photoIDs, .restricted]
        case .survey: [.photoIDs, .activePhoto, .photo]
        case .developReference: [.photo]
        case .clipping: [.shadows, .highlights]
        case .rateBatch: [.rating, .ratingStep, .advance]
        case .marks: [.flag, .label, .advance]
        case .keywords: [.photo, .search, .offset, .pageSize]
        case .getCollection: [.offset, .pageSize, .collectionRevision]
        case .saveCollection, .quickCollection: [.collection, .collectionRevision]
        case .deleteCollection, .deleteSmartCollection: [.collectionRevision]
        case .collectionMembers: [.collection, .name, .photoIDs, .queryRevision, .collectionRevision]
        case .targetCollection: [.collection]
        case .reorderCollection: [.manualOrder, .photoIDs, .beforePhoto, .collectionRevision, .queryRevision]
        case .saveSmartCollection: [.collection, .name, .rules, .fromQuery, .queryRevision, .collectionRevision]
        case .listVersions: [.photo, .source, .offset, .pageSize]
        case .listEditRecords: [.recordType, .offset, .pageSize]
        case .createCopies: [.versionRevisions, .historyID, .snapshotID]
        case .removeVersions: [.versionRevisions]
        case .renameVersion: [.expectedName]
        case .listStacks: [.photo, .stackID, .offset, .pageSize, .stackRevision]
        case .editStack: [.photo, .photoIDs, .direction, .stackIDs, .all, .queryRevision, .stackRevision]
        case .planStacks: [.scope, .photoIDs, .queryRevision, .selectionRevision]
        case .listPairs: [.photo, .source, .listing, .offset, .pageSize]
        case .planPairs: [.plan, .candidates, .scope, .photoIDs, .queryRevision, .selectionRevision, .rawSource, .jpegSource, .sameCapture]
        case .preview: [.longEdge, .previewVariant, .historyID, .snapshotID, .presetID, .presetRevision, .amount, .groups, .group,
                        .region, .resolution, .regionPixels, .planOnly,
                        .maskOverlay, .withoutMaskID, .smartOverlay]
        case .editPhotoDraft: [.photo, .sourceRevision, .recipeRevision, .draftID, .draftRevision]
        case .setCrop: [.previewID, .rect, .aspectRatio]
        case .photoGeometry: [.turns, .straighten, .flipHorizontal, .flipVertical, .perspective]
        case .perspectiveGuides: [.guideMode, .previewID, .start, .end, .point, .pointIndex, .endpoint]
        case .canvasGuides: [.cropGuide, .spotGuides]
        case .samplePreview: [.action]
        case .adjustPreview: [.point, .delta, .channel, .histogramRegion]
        case .pointColor: [.previewID, .point, .sampleID, .adjustments, .affectedRange]
        case .spotRepairs: [.previewID, .spotID, .offset, .pageSize]
        case .editSpot: [.previewID, .spotID, .spotMode, .point, .path, .sourcePoint, .sourcePreviewID, .radius, .feather, .opacity, .enabled]
        case .maskState: [.maskID, .componentID]
        case .maskGroup: [.maskID, .maskKind, .name, .enabled, .inverted, .refinement]
        case .maskComponent: [.componentID, .maskKind, .maskOperation, .name, .enabled, .inverted]
        case .brushStroke: [.previewID, .path, .radius, .feather, .flow, .density, .erase, .autoMask, .strokeIndex]
        case .maskShape: [.previewID, .start, .end, .radiusX, .radiusY, .angle, .feather]
        case .maskRange: [.previewID, .point, .sampleIndex, .refine, .lower, .upper, .smoothness]
        case .maskDisplay: [.overlay, .guides, .overlayStyle, .overlayColor, .hideEffect]
        case .localAdjustments: [.adjustments, .amount, .group]
        case .listLocalPresets: [.offset, .pageSize]
        case .editLocalPreset: [.photo, .sourceRevision, .recipeRevision, .maskID, .presetID, .presetRevision, .name]
        case .smartStart: [.maskID, .componentID, .maskOperation]
        case .smartEdit: [.previewID, .point, .rect, .candidateIndex, .personIndices, .faceIndex, .part, .separate, .wholePerson]
        case .planMerge: [.outputOptions, .collection]
        case .getMergePreview: [.displayEV, .longEdge]
        case .saveMerge: [.filename, .masterFormat, .stackWithSources]
        case .listExportPresets: [.offset, .pageSize]
        case .editExportPreset: [.name, .presetID, .presetRevision, .outputOptions]
        case .planExport: [.outputOptions, .presetID, .presetRevision, .specifications]
        case .getExportPreview: [.offset, .pageSize, .outputID, .longEdge]
        case .exportRecords: [.offset, .pageSize, .unfinishedOnly, .recordIDs]
        case .retryExport: [.includeCompleted]
        case .revealFile: [.recordIDs, .record, .member, .fileID, .photo]
        case .showAppPanel: [.catalog, .pane, .recordIDs, .unfinishedOnly]
        case .listLanguagePacks: [.offset, .pageSize]
        case .editLanguagePack: [.access, .packID]
        case .selectLanguage: [.packID]
        case .storageUsage, .setCacheQuota, .restoreCatalogBackup: [.catalog]
        case .backupCatalog, .exportCatalogManifest: [.filename]
        case .getCameraDiagnosticPreview: [.previewKind]
        case .photoRecipe: [.historyID, .snapshotID]
        case .toneCurve: [.points, .pointIndex, .x, .y]
        case .transferAdjustments: [.photo, .photoIDs, .groups, .presetID, .presetRevision, .amount]
        case .beforeAfter, .applyEditRecord: [.historyID, .snapshotID]
        case .adjustmentPreview: [.historyID, .snapshotID, .group, .presetID, .presetRevision, .amount, .groups]
        case .listPresets: [.search, .presetGroup, .favoritesOnly, .offset, .pageSize]
        case .editPreset: [.presetID, .presetRevision, .name, .presetGroup, .favorite, .photo, .sourceRevision, .recipeRevision, .groups]
        case .importXMP: [.candidates, .all]
        case .saveSnapshot: [.snapshotID, .snapshotRevision]
        case .job, .librarySources, .importRecords: [.offset, .pageSize]
        case .fileAccess, .createCatalog: [.catalog]
        case .openCatalog: [.catalog, .access, .recent]
        case .planImport: [.destinationAccess, .recursive, .skipCataloged, .layout, .archiveDate, .sidecars, .collection, .pair, .policy, .basePlan, .candidates, .attachments]
        case .startImport: [.candidates, .all]
        case .scanFolder, .planFolder: [.folder, .recursive]
        case .applyFolder: [.locations]
        case .restoreBackup: [.name]
        default: []
        }
    }
    var writes: Bool {
        switch self {
        case .capabilities, .workspace, .listPhotos, .listSelected, .preview, .librarySources, .recentCatalogs, .importRecords, .job, .keywords,
             .getCollection, .listVersions, .listEditRecords, .listStacks, .listPairs, .photoRecipe, .listPresets,
             .samplePreview, .spotRepairs, .maskState, .listLocalPresets, .getMergePreview, .listExportPresets, .getExportPreview, .exportRecords,
             .getPreferences, .listLanguagePacks, .storageUsage, .getCameraDiagnosticPreview: false
        default: true
        }
    }
    var addressedJobAction: Bool { self == .cancelJob || self == .resolveConflict }
    var needsRequestID: Bool { writes && !addressedJobAction }
    var needsCatalog: Bool { required.contains(.catalog) }

    var definition: Tool {
        let description: String
        let output: String
        switch self {
        case .capabilities:
            description = "Identify the connected Phosdeck instance and which tools are currently available."
            output = "app_name, version, bundle_id, instance_id, image_sharing, smart_mask_models, and tools with enabled and reason."
        case .workspace:
            description = "Read the current catalog, query, active photo, selection and native task state before working on photos."
            output = "catalog_session_id, request_epoch, catalog_name, source, query, view, tool, active_photo, selected_photo_ids, selection_count, selection_truncated, busy, modal, draft, photo_draft, task, before_after, adjustment_preview, canvas, and adjustment transfer sources."
        case .listPhotos:
            description = "Read photos without changing the workspace. Pass query with source_id (default all), filters and sort for an independent query, or omit it to read the current view. listing=matches includes folded stack members and defaults for independent queries; listing=visible respects folding. Continue with next_cursor and omit query. Set contact_sheet=true to receive a numbered PNG alongside the page (default 12, max \(MCPContactSheet.maximumCount) photos; requires photo preview sharing)."
            output = "items with number, photo_id, name, version_name, source_revision, recipe_revision, marks, source_status and stack. query_mode, source_id, page_offset, matched_count, visible_count and next_cursor. With contact_sheet, items also describe cell_pixels, image_pixels and thumbnail_status for the numbered PNG. Pass a candidate's ID and revisions to get_photo_preview with resolution=native for a 1:1 region."
        case .preview:
            description = "Render an explicit photo version as an sRGB PNG when image sharing is on. Use crop_canvas for crop and guide editing, original for the baseline, or before for an aligned comparison. The default scaled resolution accepts a normalized top-left region. Use resolution=native with region or an integer top-left region_pixels for an unscaled tile of the edited frame. Omit long_edge in native mode. Use plan_only=true to check the tile dimensions and limits without receiving pixels; omit the region to inspect the full frame. Saved mode supports a history, snapshot, preset, hidden group, mask or smart selection overlay, or temporarily hidden local effect."
            output = "Photo revisions, canvas dimensions, region, actual width and height. Native requests also report region_pixels, fits and limits, and suggest a smaller region when needed. Rendered previews include preview_id, coordinate_space, editable_canvas, histogram, and a PNG content block."
        case .editPhotoDraft:
            description = "Begin an in-memory photo draft for exposure, color, preset strength, local masks and spot repairs with explicit photo_id, source_revision and recipe_revision. Poll get_job for draft_id and draft_revision. Pass them to draft-aware editing and preview tools. Commit with the current draft_id and draft_revision to create one saved edit and undo action, or cancel with the same fields to discard the draft. There is one active draft per catalog session."
            output = "job_id for begin and commit; draft identity, current revision and photo revisions on begin; saved revisions and operation_id on commit; discarded on cancel."
        case .rate:
            description = "Set the rating of one explicit photo. Pass its current expected_rating and the request_epoch from get_workspace. Reuse request_id with identical arguments only when retrying the same operation."
            output = "photo_id, previous_rating, rating, changed, commit_state, and operation_id when an undo was registered."
        case .undo, .redo:
            description = self == .undo
                ? "Undo the operation with this operation_id if it is still Phosdeck's current undo action."
                : "Redo an operation undone with undo_operation if it is still Phosdeck's current redo action."
            output = "operation_id, the verified restored values, and commit_state."
        default:
            (description, output) = cullingDescription ?? organizationDescription ?? developDescription ?? canvasDescription
                ?? maskDescription ?? smartMaskDescription ?? mergeDescription ?? exportDescription ?? maintenanceDescription ?? workflowDescription
        }
        let required = required + (needsRequestID ? [.epoch, .request] : [])
        let properties = Dictionary(uniqueKeysWithValues: (required + optional).map { ($0.rawValue, $0.schema(for: self)) })
        let destructive = [.startImport, .resolveConflict, .resumeImport, .cleanBackup,
                           .deleteCollection, .deleteSmartCollection, .removeVersions, .unlinkPair, .resetAdjustments,
                           .editPreset, .deleteSnapshot, .editLanguagePack, .clearThumbnailCache].contains(self)
        let draftHelp = optional.contains(.draftID) && self != .editPhotoDraft
            ? " Pass both draft_id and draft_revision to work on a photo draft from edit_photo_draft."
            : ""
        return Tool(name: rawValue, description: description + draftHelp, inputSchema: [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
            "required": .array(required.map { .string($0.rawValue) })
        ], annotations: .init(readOnlyHint: !writes, destructiveHint: destructive, idempotentHint: true, openWorldHint: false), outputSchema: [
            "type": "object", "required": ["status", "summary", "next_actions", "artifacts", "data"],
            "properties": [
                "status": ["enum": ["success", "warning", "error"]],
                "summary": ["type": "string"],
                "next_actions": ["type": "array", "items": ["type": "string"]],
                "artifacts": ["type": "array", "items": ["type": "object"]],
                "data": ["type": "object", "description": .string(output)],
                "error": ["type": "object", "required": ["code"], "properties": ["code": ["type": "string"]]]
            ]
        ])
    }
}

struct MCPToolProblem: Error {
    let code: String
    let summary: String
    let next: String
    var details: [String: Value] = [:]

    static let stopped = Self(code: "service_stopped", summary: "The Phosdeck MCP service stopped.", next: "Reconnect using the current settings.")
    static let noCatalog = Self(code: "no_catalog", summary: "Phosdeck has no open catalog.", next: "Open or create a catalog in Phosdeck.")
    static let catalogChanged = Self(code: "catalog_changed", summary: "The catalog session changed.", next: "Call get_workspace and locate the target again.")
    static let staleCursor = Self(code: "stale_cursor", summary: "The query, selection or catalog rows changed.", next: "Read the current workspace and repeat the first page of the same query without a cursor.")
    static let photoUnavailable = Self(code: "photo_unavailable", summary: "The requested photo is unavailable.", next: "Call list_photos to locate the photo.")
    static let stalePhoto = Self(code: "stale_photo", summary: "The requested photo version changed.", next: "Call list_photos to obtain the current revisions.")
    static let stalePreview = Self(code: "stale_preview", summary: "The photo changed during rendering.", next: "Call list_photos and request the current saved version.")
    static let imageDisabled = Self(code: "image_access_disabled", summary: "Photo preview sharing is off.", next: "Enable photo preview sharing in Phosdeck Settings.")
    static let fileAccess = Self(code: "file_access_required", summary: "Phosdeck could not access this photo source.", next: "Check the photo's source in Phosdeck.")
    static let busy = Self(code: "workspace_busy", summary: "Phosdeck has an open dialog or a task in progress.", next: "Wait for the task or close the dialog and call get_workspace.")
    static let nativeInteraction = Self(code: "native_interaction_active", summary: "A native edit or undo group is still active.", next: "Finish or cancel the edit in Phosdeck, then refresh the workspace.")
    static let undoConflict = Self(code: "undo_conflict", summary: "That operation is no longer available for undo or redo.", next: "Read the current workspace and the affected items.")
    static let staleQuery = Self(code: "stale_query", summary: "The library query changed.", next: "Call get_workspace and check the source and filters again.")
    static let staleSelection = Self(code: "stale_selection", summary: "The selection changed.", next: "Call get_workspace and review list_selected_photos.")
    static let expired = Self(code: "request_expired", summary: "This write request epoch expired.", next: "Read get_workspace and check the affected state before making a new request.")
    static let failed = Self(code: "operation_failed", summary: "Phosdeck could not complete the operation.", next: "Check the current state in Phosdeck before retrying.")
    static func invalid(_ message: String) -> Self {
        Self(code: "invalid_arguments", summary: message, next: "Read the tool's input schema and refresh the target IDs.")
    }
    static func ratingConflict(_ actual: Int) -> Self {
        Self(code: "rating_conflict", summary: "The photo has a different current rating.", next: "Use the actual rating to reassess the intended edit.",
             details: ["actual_rating": .int(actual)])
    }
}

struct MCPToolResult: Sendable {
    let payload: Value
    let image: String?
    let failed: Bool

    init(_ summary: String, data: [String: Value], warning: Bool = false, artifacts: [Value] = [], image: String? = nil, next: [Value] = []) {
        payload = ["status": warning ? "warning" : "success", "summary": .string(summary),
                   "next_actions": .array(warning && next.isEmpty ? ["Refresh the workspace before making another edit."] : next),
                   "artifacts": .array(artifacts), "data": .object(data)]
        self.image = image
        failed = false
    }
    init(_ problem: MCPToolProblem, commitState: String? = nil) {
        var data = problem.details
        if let commitState { data["commit_state"] = .string(commitState) }
        payload = ["status": "error", "summary": .string(problem.summary), "next_actions": [.string(problem.next)],
                   "artifacts": [], "data": .object(data), "error": ["code": .string(problem.code)]]
        image = nil
        failed = true
    }
    func response() -> CallTool.Result {
        let text = (try? JSONEncoder().encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var content: [Tool.Content] = [.text(text: text, annotations: nil, _meta: nil)]
        if let image { content.append(.image(data: image, mimeType: "image/png", annotations: nil, _meta: nil)) }
        return .init(content: content, structuredContent: payload as Value?, isError: failed)
    }
}

extension Value {
    var number: Double? { doubleValue ?? intValue.map(Double.init) }
}

@MainActor
final class AppMCPTools {
    private enum Listing: String { case visible, matches, selection }
    private enum PhotoListScope {
        case workspace(query: PhotoQuery, source: String, generation: UUID)
        case selection(query: PhotoQuery, source: String, generation: UUID, selection: UUID)
        case independent(MCPIndependentPhotoQuery)

        var mode: String {
            switch self {
            case .workspace: "workspace"
            case .selection: "selection"
            case .independent: "independent"
            }
        }
        var defaultListing: Listing {
            switch self {
            case .workspace: .visible
            case .selection: .selection
            case .independent: .matches
            }
        }
        var source: String {
            switch self {
            case .workspace(_, let source, _), .selection(_, let source, _, _): source
            case .independent(let query): query.source
            }
        }
        var generation: UUID? {
            switch self {
            case .workspace(_, _, let generation), .selection(_, _, let generation, _): generation
            case .independent: nil
            }
        }
        func resolve(in db: Database) throws -> PhotoQuery {
            switch self {
            case .workspace(let query, _, _), .selection(let query, _, _, _): query
            case .independent(let query): try query.resolve(in: db)
            }
        }
        @MainActor func isCurrent(in model: AppModel) -> Bool {
            switch self {
            case .workspace(let query, let source, let generation):
                return model.scope == source && model.browseGeneration == generation && model.query == query
            case .selection(let query, let source, let generation, let selection):
                return model.scope == source && model.browseGeneration == generation && model.query == query && model.selectionGeneration == selection
            case .independent(let query):
                if query.source.hasPrefix("import:") { return query.source == model.lastImport?.scope }
                if query.source.hasPrefix("related:") { return query.source == model.scope }
                return true
            }
        }
    }
    private struct Cursor {
        let token = UUID().uuidString
        let scope: PhotoListScope
        let catalogRevision: UInt64
        let offset: Int
        let size: Int
        let listing: Listing
    }
    private struct Write {
        let tool: AppMCPTool
        let arguments: [String: Value]
        let result: MCPToolResult
    }
    private struct Preview: Sendable {
        let data: [String: Value]
        let selection: MCPDevelopPreview
        let image: (canvas: MCPCanvasPreview, name: String, png: String)?
    }
    private struct UndoReceipt {
        let id = UUID().uuidString
        let verifiedData: (_ applied: Bool, _ catalog: CatalogStore) throws -> [String: Value]?
        var undone = false
    }

    private weak var model: AppModel?
    private let appName: String
    private let version: String
    private let bundleID: String
    private let instanceID = UUID().uuidString
    private var sharesImages: Bool
    private var imageAccessGeneration = UUID()
    private var stopped = false
    private var observedCatalog: String?
    private var requestEpoch = UUID().uuidString
    private var writes: [String: Write] = [:]
    private var cursors: [Cursor] = []
    private var currentUndo: UndoReceipt?
    private var undoObservers: [AnyCancellable] = []
    private var activeLists = 0
    private var contactSheetWorker: Task<MCPContactSheet, Error>?
    private var previewWorker: Task<Preview, Error>?
    private var canvasPreviews: [MCPCanvasPreview] = []
    var photoDraft: MCPPhotoDraft?
    var mcpSmartSessionID: UUID?
    private lazy var previewPipeline = ImagePipeline(qualityCacheLimit: 0)
    let workflows: AppMCPWorkflows

    init(model: AppModel, appName: String, version: String, bundleID: String, sharesImages: Bool,
         chooseFile: AppMCPWorkflows.FilePicker? = nil) {
        self.model = model
        self.appName = appName
        self.version = version
        self.bundleID = bundleID
        self.sharesImages = sharesImages
        workflows = AppMCPWorkflows(model: model, chooseFile: chooseFile)
        // Native activity can replace the stack top even when it produces the same values.
        for name in [Notification.Name.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerWillUndoChange, .NSUndoManagerWillRedoChange] {
            undoObservers.append(NotificationCenter.default.publisher(for: name, object: model.undo).sink { [weak self] _ in
                self?.currentUndo = nil
            })
        }
    }

    func setSharesImages(_ value: Bool) {
        sharesImages = value
        if !value {
            imageAccessGeneration = UUID()
            contactSheetWorker?.cancel()
            previewWorker?.cancel()
            canvasPreviews.removeAll()
        }
    }
    @discardableResult func stop() -> Task<Void, Never>? {
        stopped = true
        if let model, let id = mcpSmartSessionID, model.smartMaskSession?.id == id { model.cancelSmartMask() }
        mcpSmartSessionID = nil
        contactSheetWorker?.cancel()
        previewWorker?.cancel()
        canvasPreviews.removeAll()
        clearPhotoDraft()
        undoObservers.removeAll()
        currentUndo = nil
        cursors.removeAll()
        writes.removeAll()
        return workflows.stop()
    }

    nonisolated func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let result = await execute(params)
        return result.response()
    }

    private func execute(_ params: CallTool.Parameters) async -> MCPToolResult {
        guard !stopped, !Task.isCancelled, let model else { return .init(.stopped) }
        guard let tool = AppMCPTool(rawValue: params.name) else {
            return .init(.init(code: "unsupported_operation", summary: "This tool is unavailable.", next: "Read the registered tools."))
        }
        let arguments = params.arguments ?? [:]
        let required = tool.required + (tool.needsRequestID ? [.epoch, .request] : [])
        let fields = required + tool.optional
        guard Set(arguments.keys).isSubset(of: Set(fields.map(\.rawValue))) else {
            return invalidArguments("Unexpected tool argument.", writes: tool.writes)
        }
        if let field = required.first(where: { arguments[$0.rawValue] == nil }) ??
            fields.first(where: { field in arguments[field.rawValue].map { !field.accepts($0, for: tool) } ?? false }) {
            return invalidArguments("Invalid or missing \(field.rawValue).", writes: tool.writes)
        }

        let catalogSession = model.catalogSessionID
        if observedCatalog != catalogSession {
            observedCatalog = catalogSession
            cursors.removeAll()
            contactSheetWorker?.cancel()
            canvasPreviews.removeAll()
            clearPhotoDraft()
            currentUndo = nil
            workflows.catalogChanged()
        }
        switch tool {
        case .capabilities: return capabilities(model)
        case .workspace: return workspace(model)
        case .cancelJob, .resolveConflict:
            do { return try workflows.control(tool, arguments: arguments) }
            catch let problem as MCPToolProblem { return .init(problem, commitState: "not_committed") }
            catch { return .init(.failed, commitState: "not_committed") }
        default: break
        }
        if tool.needsRequestID { return write(tool, arguments: arguments, model: model) }
        do {
            try checkCatalog(tool, arguments: arguments, model: model)
            switch tool {
            case .listPhotos, .listSelected:
                return try await listPhotos(model, catalog: model.catalog!, session: catalogSession!, arguments: arguments,
                                            selectionOnly: tool == .listSelected)
            case .preview:
                return try await preview(model, catalog: model.catalog!, session: catalogSession!, arguments: arguments)
            case .photoRecipe:
                let draft = try requestedDraft(arguments)
                let result = try await workflows.read(tool, arguments: arguments, draft: draft)
                try verifyCanvasRead(catalogSession!, model: model)
                try verifyPhotoDraft(draft?.reference)
                return result
            case .getMergePreview, .getExportPreview, .getCameraDiagnosticPreview:
                let withImage = tool != .getExportPreview || arguments["output_id"] != nil
                guard !withImage || sharesImages else { throw MCPToolProblem.imageDisabled }
                let accessGeneration = imageAccessGeneration
                let result = try await workflows.read(tool, arguments: arguments)
                if tool == .getCameraDiagnosticPreview {
                    guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
                } else {
                    try verifyCanvasRead(catalogSession!, model: model)
                }
                guard !withImage || (sharesImages && imageAccessGeneration == accessGeneration) else { throw MCPToolProblem.imageDisabled }
                return result
            case .samplePreview:
                return try await sampleCanvas(arguments, model: model, catalog: model.catalog!, session: catalogSession!)
            case .spotRepairs:
                return try await readSpots(arguments, model: model, catalog: model.catalog!)
            case .maskState:
                return try await readMasks(arguments, model: model, catalog: model.catalog!)
            case .listLocalPresets:
                return try readLocalPresets(arguments, catalog: model.catalog!)
            default:
                let result = try await workflows.read(tool, arguments: arguments)
                guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
                return result
            }
        } catch let problem as MCPToolProblem {
            return .init(problem)
        } catch OrganizationError.photoUnavailable {
            return .init(.photoUnavailable)
        } catch {
            return .init(.failed)
        }
    }

    private func checkCatalog(_ tool: AppMCPTool, arguments: [String: Value], model: AppModel) throws {
        if tool.needsCatalog && model.catalog == nil { throw MCPToolProblem.noCatalog }
        let session = arguments["catalog_session_id"]?.stringValue
        let catalogBound = tool.needsCatalog || [.fileAccess, .createCatalog, .openCatalog, .restoreCatalogBackup].contains(tool) || session != nil
        if catalogBound && session != model.catalogSessionID {
            throw MCPToolProblem.catalogChanged
        }
    }

    private func invalidArguments(_ summary: String, writes: Bool) -> MCPToolResult {
        .init(.invalid(summary), commitState: writes ? "not_committed" : nil)
    }

    private func capabilities(_ model: AppModel) -> MCPToolResult {
        let tools: [Value] = AppMCPTool.allCases.map { tool in
            let problem: MCPToolProblem?
            switch tool {
            case .capabilities, .workspace, .recentCatalogs, .job, .cancelJob: problem = nil
            case .listPhotos, .listSelected: problem = model.catalog == nil ? .noCatalog : nil
            case .preview, .samplePreview, .getMergePreview: problem = model.catalog == nil ? .noCatalog : sharesImages ? nil : .imageDisabled
            case .getCameraDiagnosticPreview: problem = sharesImages ? nil : .imageDisabled
            case .rate: problem = model.catalog == nil ? .noCatalog : writeProblem(model)
            case .undo, .redo:
                problem = model.catalog == nil ? .noCatalog : writeProblem(model, tool: tool) ?? (undoAvailable(model, redo: tool == .redo) ? nil : .undoConflict)
            case .resolveConflict: problem = workflows.waitingForConflict ? nil : .busy
            case .smartEdit, .smartApply:
                problem = model.catalog == nil ? .noCatalog : model.smartMaskSession == nil ? .smartSelectionUnavailable : writeProblem(model, tool: tool)
            default: problem = tool.needsCatalog && model.catalog == nil ? .noCatalog : tool.writes ? writeProblem(model, tool: tool) : nil
            }
            return ["name": .string(tool.rawValue), "enabled": .bool(problem == nil),
                    "reason": problem.map { .string($0.code) } ?? .null]
        }
        return .init("Connected to \(appName).", data: [
            "app_name": .string(appName), "version": .string(version), "bundle_id": .string(bundleID),
            "instance_id": .string(instanceID), "image_sharing": .bool(sharesImages), "tools": .array(tools), "smart_mask_models": Self.smartModels()
        ])
    }

    private func workspace(_ model: AppModel) -> MCPToolResult {
        if writes.count >= 256 && !workflows.isWorking { rotateRequestEpoch() }
        let task: Value = model.taskProgress.map {
            ["title": .string($0.title), "done": .int($0.done), "total": .int($0.total)]
        } ?? .null
        var data: [String: Value] = [
            "catalog_session_id": model.catalogSessionID.map(Value.string) ?? .null,
            "request_epoch": .string(requestEpoch), "catalog_name": model.catalog == nil ? .null : .string(model.catalogName),
            "source": model.catalog == nil ? .null : .string(model.browseSourceName),
            "active_photo": model.active.flatMap { $0.id == model.activeID ? .object(Self.photo($0, badge: model.stackBadges[$0.id])) : nil } ?? .null,
            "busy": .bool(model.busy || model.applyingAdjustments || model.cacheMaintenance),
            "modal": .bool(nativeModal(model)),
            "draft": .bool(nativeInteraction(model)), "task": task, "agent_job": workflows.currentJob,
            "target_collection_id": model.targetCollectionID.map(Value.string) ?? .null,
            "quick_collection_id": model.quickCollectionID.map(Value.string) ?? .null,
            "undo_operation_id": undoAvailable(model, redo: false) ? .string(currentUndo!.id) : .null,
            "redo_operation_id": undoAvailable(model, redo: true) ? .string(currentUndo!.id) : .null
        ]
        data.merge(Self.browseState(model)) { _, value in value }
        data.merge(Self.developViewState(model)) { _, value in value }
        data["canvas"] = .object(Self.canvasState(model))
        data["mask_display"] = .object(Self.maskState(model))
        data["photo_draft"] = photoDraft.map { .object($0.data) } ?? .null
        data["smart_session_id"] = model.smartMaskSession.map { .string($0.id.uuidString) } ?? .null
        data["open_panel"] = MCPAppPanel.visible(in: model).map { $0.describe(model) } ?? .null
        return .init("Current Phosdeck workspace.", data: data)
    }

    private func listPhotos(_ model: AppModel, catalog: CatalogStore, session: String, arguments: [String: Value],
                            selectionOnly: Bool) async throws -> MCPToolResult {
        let query = arguments["query"]?.objectValue
        let withSheet = arguments["contact_sheet"] == true
        if withSheet {
            guard sharesImages else { throw MCPToolProblem.imageDisabled }
            guard contactSheetWorker == nil else {
                throw MCPToolProblem(code: "workspace_busy", summary: "A contact sheet is rendering.", next: "Retry the page after rendering finishes.")
            }
        }
        let cursor: Cursor?
        let scope: PhotoListScope
        let requestedSize = arguments["page_size"]?.intValue
        let requestedListing = selectionOnly ? Listing.selection : arguments["listing"]?.stringValue.flatMap(Listing.init(rawValue:))
        if let token = arguments["cursor"]?.stringValue {
            guard query == nil else { throw MCPToolProblem.invalid("Omit query when continuing with a cursor.") }
            guard let saved = cursors.first(where: { $0.token == token }),
                  selectionOnly == (saved.listing == .selection), saved.scope.isCurrent(in: model),
                  requestedListing == nil || requestedListing == saved.listing,
                  requestedSize == nil || requestedSize == saved.size else { throw MCPToolProblem.staleCursor }
            cursor = saved
            scope = saved.scope
        } else {
            cursor = nil
            if let query {
                let independent = try MCPIndependentPhotoQuery(query)
                try MCPLibraryCriteria.validateSource(independent.source, model: model)
                scope = .independent(independent)
            } else if selectionOnly {
                scope = .selection(query: model.query, source: model.scope, generation: model.browseGeneration, selection: model.selectionGeneration)
            } else {
                scope = .workspace(query: model.query, source: model.scope, generation: model.browseGeneration)
            }
        }
        let size = cursor?.size ?? requestedSize ?? (withSheet ? MCPContactSheet.defaultCount : 50)
        if withSheet, size > MCPContactSheet.maximumCount {
            throw MCPToolProblem.invalid("Contact sheets support at most \(MCPContactSheet.maximumCount) photos per page. Start a new list with a smaller page_size.")
        }
        guard activeLists < 2 else {
            throw MCPToolProblem(code: "workspace_busy", summary: "Photo queries are in progress.", next: "Retry the read after the current query finishes.")
        }
        let listing = cursor?.listing ?? requestedListing ?? scope.defaultListing
        let selection = selectionOnly ? model.selection : []
        let accessGeneration = imageAccessGeneration
        activeLists += 1
        defer { activeLists -= 1 }
        let worker = Task.detached(priority: .userInitiated) { () throws -> (page: PhotoPage, items: [[String: Value]], nextOffset: Int, revision: UInt64) in
            try Task.checkCancellation()
            let result = try catalog.database.read { db -> (PhotoPage, Int, UInt64) in
                let revision = catalog.browseRevision
                if let cursor, cursor.catalogRevision != revision { throw MCPToolProblem.staleCursor }
                let offset = cursor?.offset ?? 0
                if listing == .selection {
                    let ids = selection.sorted().dropFirst(offset).prefix(size)
                    let photos = try CatalogStore.photos(ids: Set(ids), in: db)
                    let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
                    let page = PhotoPage(photos: ids.compactMap { byID[$0] }, total: selection.count, offset: offset, visibleTotal: selection.count)
                    return (page, offset + ids.count, revision)
                }
                let page = try CatalogStore.page(scope.resolve(in: db), in: db, offset: offset, limit: size, includeCollapsed: listing == .matches)
                return (page, page.offset + page.photos.count, revision)
            }
            let (page, nextOffset, revision) = result
            let items = page.photos.enumerated().map { index, photo in
                var item = Self.photo(photo, badge: page.badges[photo.id])
                if listing != .selection { item["number"] = .int(page.offset + index + 1) }
                return item
            }
            return (page, items, nextOffset, revision)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try verifyCanvasRead(session, model: model)
        guard scope.isCurrent(in: model) else { throw MCPToolProblem.staleCursor }
        let page = result.page
        var items = result.items
        var sheet: MCPContactSheet?
        if withSheet {
            guard sharesImages, imageAccessGeneration == accessGeneration else { throw MCPToolProblem.imageDisabled }
            if !items.isEmpty {
                let rendered = try await renderContactSheet(page, revision: result.revision, model: model, catalog: catalog,
                                                            session: session, accessGeneration: accessGeneration)
                guard scope.isCurrent(in: model) else { throw MCPToolProblem.staleCursor }
                for (index, cell) in rendered.cells.enumerated() { items[index].merge(cell) { _, value in value } }
                sheet = rendered
            }
        }
        var next: Value = .null
        if result.nextOffset < (listing == .visible ? page.visibleTotal : page.total) {
            let cursor = Cursor(scope: scope, catalogRevision: result.revision, offset: result.nextOffset, size: size, listing: listing)
            if cursors.count >= 128 { cursors.removeFirst() }
            cursors.append(cursor)
            next = .string(cursor.token)
        }
        var data: [String: Value] = ["items": .array(items.map(Value.object)), "listing": .string(listing.rawValue), "next_cursor": next]
        if selectionOnly {
            data["selection_count"] = .int(page.total)
            data["selection_revision"] = .string(model.selectionGeneration.uuidString)
        } else {
            data["matched_count"] = .int(page.total)
            data["visible_count"] = .int(page.visibleTotal)
            data["query_mode"] = .string(scope.mode)
            data["source_id"] = .string(scope.source)
            data["page_offset"] = .int(page.offset)
            if let generation = scope.generation { data["query_revision"] = .string(generation.uuidString) }
            if withSheet { data["contact_sheet"] = sheet.map { .object($0.data) } ?? .null }
        }
        if let sheet {
            let warning = sheet.unavailableCount > 0
            return .init(warning ? "Read \(items.count) photos. \(sheet.unavailableCount) thumbnails are unavailable." : "Read \(items.count) photos.",
                         data: data, warning: warning, image: sheet.png,
                         next: [warning
                                ? "Use ready cells for review and check thumbnail_error for unavailable cells."
                                : "Choose an item by number and use its photo_id and revisions with get_photo_preview for a native 1:1 region."])
        }
        return .init("Read \(items.count) photos.", data: data)
    }

    private func renderContactSheet(_ page: PhotoPage, revision: UInt64, model: AppModel, catalog: CatalogStore,
                                    session: String, accessGeneration: UUID) async throws -> MCPContactSheet {
        guard contactSheetWorker == nil else {
            throw MCPToolProblem(code: "workspace_busy", summary: "A contact sheet is rendering.", next: "Retry the page after rendering finishes.")
        }
        let thumbnails = model.thumbnails, roots = model.roots, pipeline = model.pipeline
        let worker = Task.detached(priority: .utility) {
            try await MCPContactSheet.render(photos: page.photos, offset: page.offset, roots: roots, thumbnails: thumbnails, pipeline: pipeline)
        }
        contactSheetWorker = worker
        defer { contactSheetWorker = nil }
        let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
        try verifyCanvasRead(session, model: model)
        guard sharesImages, imageAccessGeneration == accessGeneration else { throw MCPToolProblem.imageDisabled }
        let current = try await catalog.database.read { _ in catalog.browseRevision }
        try verifyCanvasRead(session, model: model)
        guard sharesImages, imageAccessGeneration == accessGeneration else { throw MCPToolProblem.imageDisabled }
        guard current == revision else { throw MCPToolProblem.staleCursor }
        return try result.get()
    }

    nonisolated static func photo(_ photo: Photo, badge: StackBadge?) -> [String: Value] {
        let stack: Value = badge.map {
            ["stack_id": .string($0.stackID), "position": .int($0.position), "member_count": .int($0.count),
             "matched_count": .int($0.matching), "collapsed": .bool($0.collapsed)]
        } ?? .null
        let metadata = photo.details
        return ["photo_id": .string(photo.id), "source_id": .string(photo.sourceKey), "name": .string(photo.name),
                "version_name": .string(String(photo.versionName.prefix(256))),
                "source_revision": .int(photo.revision), "recipe_revision": .int(photo.recipeRevision), "rating": .int(photo.rating),
                "flag": .int(photo.flag), "color_label": .int(photo.colorLabel), "source_status": .string(photo.availability), "stack": stack,
                "is_virtual_copy": .bool(photo.isVirtualCopy),
                "camera": photo.camera.map { .string(String($0.prefix(256))) } ?? .null,
                "lens": metadata?.lens.map { .string(String($0.prefix(256))) } ?? .null,
                "iso": metadata?.iso.map(Value.int) ?? .null,
                "capture_date": LibraryMetadataFilter.day(photo.captureDate).map(Value.string) ?? .null]
    }

    private func preview(_ model: AppModel, catalog: CatalogStore, session: String, arguments: [String: Value]) async throws -> MCPToolResult {
        guard sharesImages else { throw MCPToolProblem.imageDisabled }
        guard previewWorker == nil else {
            throw MCPToolProblem(code: "workspace_busy", summary: "A preview is rendering.", next: "Retry the preview after rendering finishes.")
        }
        let id = arguments["photo_id"]!.stringValue!
        let sourceRevision = arguments["source_revision"]!.intValue!
        let recipeRevision = arguments["recipe_revision"]!.intValue!
        let edge = arguments["long_edge"]?.intValue ?? 768
        let region = arguments["region"].flatMap(MCPCanvasFields.rect)
        let native = arguments["resolution"] == "native"
        let planOnly = arguments["plan_only"]?.boolValue ?? false
        let pixelRegion = arguments["region_pixels"].flatMap(MCPCanvasFields.pixelRect)
        if native {
            guard arguments["long_edge"] == nil, region == nil || pixelRegion == nil,
                  planOnly || region != nil || pixelRegion != nil else {
                throw MCPToolProblem.invalid("For native previews omit long_edge and choose one region or region_pixels. plan_only may omit the region.")
            }
        } else if pixelRegion != nil || planOnly {
            throw MCPToolProblem.invalid("region_pixels and plan_only require resolution=native.")
        }
        let draft = try requestedDraft(arguments)
        if draft != nil {
            let saved = arguments["preview_variant"] == nil || arguments["preview_variant"] == "saved"
            let alternatives = ["history_id", "snapshot_id", "preset_id", "preset_revision", "amount", "groups", "group", "smart_overlay"]
            guard saved, !alternatives.contains(where: { arguments[$0] != nil }) else {
                throw MCPToolProblem.invalid("Render the draft on its own. Omit draft fields to render a saved comparison or smart overlay.")
            }
        }
        let smartOverlay = try arguments["smart_overlay"].map(MCPSmartOverlay.init)
        let smartGroup = try smartOverlay.map { try smartOverlayGroup($0, photo: MCPDevelopPhoto.current(arguments, catalog: catalog), model: model) }
        let accessGeneration = imageAccessGeneration
        let roots = model.roots
        let pipeline = previewPipeline
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let photo = try catalog.photo(id) else { throw MCPToolProblem.photoUnavailable }
            guard photo.revision == sourceRevision, photo.recipeRevision == recipeRevision else { throw MCPToolProblem.stalePhoto }
            if let draft, !draft.matches(photo) { throw MCPToolProblem.stalePhoto }
            guard photo.availability == "available", let root = roots.first(where: { $0.id == photo.rootID }) else { throw MCPToolProblem.fileAccess }
            let selection = try MCPDevelopPreview(arguments, photo: photo, catalog: catalog)
            let current: EditRecipe?
            if let draft { current = draft.recipe }
            else if photo.supportsEditing { current = try await MCPDevelopPhoto.recipe(for: photo, root: root, pipeline: pipeline) }
            else { current = nil }
            var recipe = try await selection.recipe(current, photo: photo, root: root, pipeline: pipeline)
            let overlay = try arguments["mask_overlay"].map(MCPMaskOverlay.init)
            let withoutMask = MCPMask.id(arguments["without_mask_id"])
            if overlay != nil || arguments["without_mask_id"] != nil || smartOverlay != nil {
                guard selection.editableCanvas, selection.variant == "saved", recipe != nil,
                      arguments["without_mask_id"] == nil || withoutMask != nil,
                      [overlay != nil, withoutMask != nil, smartOverlay != nil].filter({ $0 }).count == 1 else {
                    throw MCPToolProblem.invalid("Choose one mask display option on the current saved or draft version.")
                }
            }
            if let withoutMask {
                let index = try MCPMask.group(withoutMask, in: recipe!)
                recipe?.localAdjustments[index].enabled = false
            }
            let request = ImageRequest(photo: photo, root: root, recipe: recipe)
            var data = MCPDevelopPhoto.revisions(photo)
            data.merge(selection.description) { _, value in value }
            if let draft { data.merge(draft.data) { _, value in value } }
            if planOnly {
                let canvas = try await pipeline.nativeOutputSize(request)
                let plan = try MCPNativePreviewRegion.resolve(canvas: canvas, region: region, pixelRegion: pixelRegion)
                data.merge(plan.data) { _, value in value }
                return Preview(data: data, selection: selection, image: nil)
            }
            let rendered: RenderedImage
            if native {
                rendered = try await pipeline.render(request, longEdge: nil, nativePixelRegion: { canvas in
                    let plan = try MCPNativePreviewRegion.resolve(canvas: canvas, region: region, pixelRegion: pixelRegion)
                    guard plan.fits else {
                        throw MCPToolProblem(code: "preview_region_too_large", summary: "The region exceeds the native preview limits.",
                                             next: "Use suggested_region_pixels or split the region into smaller rectangles.",
                                             details: plan.data)
                    }
                    return plan.pixels
                })
            } else {
                let renderEdge = region.map { max(edge, Int(min(2048, Double(max(1, edge - 2)) / max($0.width, $0.height)))) } ?? edge
                rendered = try await pipeline.render(request, longEdge: renderEdge)
            }
            let full: CGImage
            if let overlay, let recipe {
                let group = recipe.localAdjustments[try MCPMask.group(overlay.id, in: recipe)]
                full = try await pipeline.renderMaskOverlay(rendered, request: request, group: group, style: overlay.style, color: overlay.color)
            } else if let smartOverlay, let smartGroup {
                full = try await pipeline.renderMaskOverlay(rendered, request: request, group: smartGroup, style: smartOverlay.style, color: smartOverlay.color)
            } else { full = rendered.image }
            try Task.checkCancellation()
            let image: CGImage
            let actualRegion: CGRect
            if let pixels = rendered.nativePixelRegion {
                let tile = MCPNativePreviewRegion(canvas: rendered.fullSize, pixels: pixels)
                image = full
                actualRegion = tile.normalized
                data.merge(tile.data) { _, value in value }
            } else {
                (image, actualRegion) = try MCPCanvasPreview.detail(full, region: region)
                data["resolution"] = "scaled"
                data["canvas_width"] = .int(Int(rendered.fullSize.width.rounded(.up)))
                data["canvas_height"] = .int(Int(rendered.fullSize.height.rounded(.up)))
            }
            let editable = selection.editableCanvas && recipe != nil && overlay == nil && withoutMask == nil && smartOverlay == nil
            let canvas = MCPCanvasPreview(photo: photo, image: image, region: actualRegion,
                                          sourceSize: rendered.orientedSourceSize, variant: editable ? selection.variant : nil,
                                          spotOffsets: rendered.spotOffsets, draft: draft?.reference)
            let png = try MCPOutputImage.png(image)
            let recalculateHistogram = native ? overlay != nil || smartOverlay != nil : region != nil
            let histogram = (recalculateHistogram ? ImageHistogram.calculate(image) : rendered.histogram)
                .map { Value.array($0.channels.map { .array($0.map(Value.double)) }) } ?? .null
            data.merge([
                "preview_id": .string(canvas.id), "width": .int(image.width), "height": .int(image.height),
                "source_width": .int(Int(rendered.orientedSourceSize.width)), "source_height": .int(Int(rendered.orientedSourceSize.height)),
                "coordinate_space": "normalized_top_left", "histogram": histogram,
                "region": MCPCanvasFields.rectValue(actualRegion), "editable_canvas": .bool(canvas.variant != nil)
            ]) { _, value in value }
            if let overlay { data["mask_overlay"] = overlay.description }
            if let withoutMask { data["without_mask_id"] = .string(withoutMask.uuidString) }
            if let smartOverlay { data["smart_overlay"] = .object(smartOverlay.fields) }
            return Preview(data: data, selection: selection, image: (canvas, String(photo.displayName.prefix(256)), png))
        }
        previewWorker = worker
        defer { previewWorker = nil }
        let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
        guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
        guard sharesImages, imageAccessGeneration == accessGeneration else { throw MCPToolProblem.imageDisabled }
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        try verifyPhotoDraft(draft?.reference)
        let preview = try result.get()
        guard try catalog.matchesPhotoRevisions(id: id, source: sourceRevision, recipe: recipeRevision) else { throw MCPToolProblem.stalePreview }
        try preview.selection.verify(arguments, catalog: catalog)
        if let smartOverlay { _ = try smartOverlayGroup(smartOverlay, photo: MCPDevelopPhoto.current(arguments, catalog: catalog), model: model) }
        guard let image = preview.image else { return .init("Checked the native preview region.", data: preview.data) }
        if canvasPreviews.count >= 6 { canvasPreviews.removeFirst() }
        canvasPreviews.append(image.canvas)
        return .init("Rendered the requested photo preview.", data: preview.data,
                     artifacts: [["type": "photo_preview", "id": .string(image.canvas.id), "name": .string(image.name)]], image: image.png)
    }

    func clearPhotoDraft() {
        photoDraft = nil
        canvasPreviews.removeAll { $0.draft != nil }
    }

    func canvasPreview(_ id: Value?, catalog: CatalogStore, photo: Photo? = nil, variant: String? = nil,
                       draft: MCPPhotoDraft.Reference? = nil) throws -> MCPCanvasPreview {
        guard sharesImages else { throw MCPToolProblem.imageDisabled }
        try verifyPhotoDraft(draft)
        guard let id = id?.stringValue, let preview = canvasPreviews.first(where: { $0.id == id }),
              preview.draft == draft,
              photo.map({ preview.matches($0) }) ?? true,
              variant.map({ preview.variant == $0 }) ?? true,
              try catalog.matchesPhotoRevisions(id: preview.photoID, source: preview.sourceRevision, recipe: preview.recipeRevision) else {
            throw MCPToolProblem.staleCanvasPreview
        }
        return preview
    }

    func verifyCanvasRead(_ catalogSession: String, model: AppModel) throws {
        guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
        guard model.catalogSessionID == catalogSession else { throw MCPToolProblem.catalogChanged }
    }
    func verifySavedCanvasRead(_ photo: Photo, catalog: CatalogStore, model: AppModel) throws {
        guard !stopped, !Task.isCancelled else { throw MCPToolProblem.stopped }
        guard model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
        guard try catalog.matchesPhotoRevisions(id: photo.id, source: photo.revision, recipe: photo.recipeRevision,
                                                requiringAvailable: false) else { throw MCPToolProblem.stalePhoto }
    }

    private func write(_ tool: AppMCPTool, arguments: [String: Value], model: AppModel) -> MCPToolResult {
        guard arguments["request_epoch"]?.stringValue == requestEpoch else { return .init(.expired, commitState: "not_committed") }
        let id = arguments["request_id"]!.stringValue!
        if let previous = writes[id] {
            guard previous.tool == tool, previous.arguments == arguments else {
                return .init(.init(code: "request_id_conflict", summary: "This request ID already has different arguments.",
                                  next: "Check the previous result and use a new request ID for a new action."), commitState: "not_committed")
            }
            return previous.result
        }
        if writes.count >= 256 {
            if workflows.isWorking { return .init(.busy, commitState: "not_committed") }
            rotateRequestEpoch()
            return .init(.expired, commitState: "not_committed")
        }
        let result: MCPToolResult
        do {
            try checkCatalog(tool, arguments: arguments, model: model)
            if tool == .undo || tool == .redo {
                guard undoAvailable(model, redo: tool == .redo),
                      currentUndo?.id == arguments["operation_id"]?.stringValue else { throw MCPToolProblem.undoConflict }
            }
            let discardingDraft = tool == .editPhotoDraft && arguments["action"] == "cancel"
            if !discardingDraft, let problem = writeProblem(model, tool: tool) { throw problem }
            switch tool {
            case .editPhotoDraft:
                result = try writePhotoDraft(arguments, model: model, catalog: model.catalog!)
            case .rate, .rateBatch, .marks:
                result = try editMarks(tool, arguments: arguments, model: model, catalog: model.catalog!)
            case .editKeywords, .renameKeyword, .caption:
                result = try editMetadata(tool, arguments: arguments, model: model, catalog: model.catalog!)
            case .saveCollection, .deleteCollection, .collectionMembers, .targetCollection, .quickCollection, .reorderCollection,
                 .saveSmartCollection, .deleteSmartCollection:
                result = try writeCollections(tool, args: arguments, model: model, catalog: model.catalog!)
            case .createCopies, .renameVersion, .removeVersions:
                result = try writeVersions(tool, args: arguments, model: model, catalog: model.catalog!)
            case .editStack, .planStacks, .applyStacks:
                result = try writeStacks(tool, args: arguments, model: model, catalog: model.catalog!)
            case .planPairs, .applyPairs, .unlinkPair:
                result = try writePairs(tool, args: arguments, model: model, catalog: model.catalog!)
            case .globalAdjustments, .resetAdjustments, .toneCurve, .zoneLighting, .colorAdjustments, .detailAdjustments, .effects,
                 .automaticAdjustment, .relativeExposure, .matchExposure, .transferAdjustments, .applyEditRecord:
                result = try writeRecipes(tool, args: arguments, model: model, catalog: model.catalog!)
            case .beforeAfter, .adjustmentPreview, .editPreset, .planXMP, .importXMP, .saveSnapshot, .deleteSnapshot:
                result = try writeEditContext(tool, args: arguments, model: model, catalog: model.catalog!)
            case .setCrop, .photoGeometry, .solvePerspective, .perspectiveGuides, .canvasGuides, .adjustPreview, .pointColor, .editSpot:
                result = try writeCanvas(tool, args: arguments, model: model, catalog: model.catalog!)
            case .maskGroup, .maskComponent, .brushStroke, .maskShape, .maskRange, .maskDisplay, .localAdjustments, .transferLocal, .editLocalPreset:
                result = try writeMasks(tool, args: arguments, model: model, catalog: model.catalog!)
            case .smartStart, .smartEdit, .smartApply:
                result = try writeSmartMask(tool, args: arguments, model: model, catalog: model.catalog!)
            case .saveMerge:
                result = try saveMerge(arguments, model: model, catalog: model.catalog!)
            case .undo, .redo: result = try replay(model, redo: tool == .redo)
            default:
                if tool.cullingDescription != nil {
                    result = try writeCulling(tool, arguments: arguments, model: model, catalog: model.catalog!)
                } else {
                    result = try workflows.write(tool, arguments: arguments)
                }
            }
        } catch OrganizationError.ratingConflict(let actual) {
            result = .init(.ratingConflict(actual), commitState: "not_committed")
        } catch OrganizationError.photoUnavailable {
            result = .init(.photoUnavailable, commitState: "not_committed")
        } catch OrganizationError.versionConflict {
            result = .init(.stalePhoto, commitState: "not_committed")
        } catch OrganizationError.marksConflict(let photo, let actual) {
            result = .init(.init(code: "marks_conflict", summary: "A target photo's marks changed.", next: "Read its actual marks before editing again.",
                                 details: ["photo_id": .string(photo), "actual": actual.mcpValue]), commitState: "not_committed")
        } catch let conflict as PhotoCaptionConflict {
            result = .init(.init(code: "caption_conflict", summary: "A target photo's caption changed.", next: "Review the current caption before replacing it.",
                                 details: ["photo_id": .string(conflict.id), "actual_caption": .string(conflict.actual)]), commitState: "not_committed")
        } catch let problem as MCPToolProblem {
            result = .init(problem, commitState: "not_committed")
        } catch {
            result = .init(.failed, commitState: "not_committed")
        }
        writes[id] = Write(tool: tool, arguments: arguments, result: result)
        return result
    }

    private func rotateRequestEpoch() {
        requestEpoch = UUID().uuidString
        writes.removeAll(keepingCapacity: true)
    }

    private func nativeInteraction(_ model: AppModel, allowingSmartMask: Bool = false) -> Bool {
        let window = NSApp?.keyWindow
        let typing = window.map(WorkspaceKeyboard.isWorkspaceWindow) == true && window?.firstResponder is NSTextView
        return model.dirty || model.maskGesture != nil || model.spotGesture != nil || model.directAdjustment != nil || model.automaticAdjustmentKind != nil
            || model.perspectiveGuideDragOriginal != nil || model.uprightAnalyzing || (!allowingSmartMask && model.smartMaskSession != nil)
            || model.whiteBalanceSamplingBusy || model.refreshingSpotSource || typing
    }
    private func nativeModal(_ model: AppModel) -> Bool {
        model.presentingSheet || NSApp?.modalWindow != nil || NSApp?.windows.contains {
            $0.isVisible && $0.attachedSheet != nil && WorkspaceKeyboard.isWorkspaceWindow($0)
        } == true
    }
    private func writeProblem(_ model: AppModel, tool: AppMCPTool? = nil) -> MCPToolProblem? {
        guard model.workspaceAvailable, !model.changingCatalogExtension, !nativeModal(model) else { return .busy }
        let cropTools: [AppMCPTool] = [.workspaceView, .setCrop, .photoGeometry, .solvePerspective, .perspectiveGuides, .canvasGuides, .undo, .redo]
        let smartTools: [AppMCPTool] = [.smartEdit, .smartApply, .maskDisplay]
        guard !nativeInteraction(model, allowingSmartMask: tool.map(smartTools.contains) == true),
              !model.cropMode || tool.map(cropTools.contains) == true,
              model.undo.groupingLevel == 0, model.undo.isUndoRegistrationEnabled,
              !model.undo.isUndoing, !model.undo.isRedoing else { return .nativeInteraction }
        return nil
    }

    func recordUndo<State: Equatable>(before: State, after: State, describe: @escaping (State) -> [String: Value],
                                     read: @escaping (CatalogStore) throws -> State) -> Value {
        let receipt = UndoReceipt { applied, catalog in
            let actual = try read(catalog)
            return actual == (applied ? after : before) ? describe(actual) : nil
        }
        currentUndo = receipt
        return .string(receipt.id)
    }
    private func undoAvailable(_ model: AppModel, redo: Bool) -> Bool {
        guard currentUndo?.undone == redo else { return false }
        return redo ? model.undo.canRedo : model.undo.canUndo
    }
    private func replay(_ model: AppModel, redo: Bool) throws -> MCPToolResult {
        guard let catalog = model.catalog, var receipt = currentUndo, (try? receipt.verifiedData(!redo, catalog)) != nil else {
            currentUndo = nil
            throw MCPToolProblem.undoConflict
        }
        currentUndo = nil
        let previousError = model.error
        if redo { model.undo.redo() } else { model.undo.undo() }
        guard var data = try? receipt.verifiedData(redo, catalog) else {
            return .init(.failed, commitState: "unknown")
        }
        receipt.undone = !redo
        if redo ? model.undo.canUndo : model.undo.canRedo { currentUndo = receipt }
        data["operation_id"] = .string(receipt.id)
        data["commit_state"] = "committed"
        return .init(redo ? "Redid the operation." : "Undid the operation.", data: data, warning: model.error != previousError)
    }
}
