import AppKit
import GRDB
import MCP

extension AppMCPTool {
    var cullingDescription: (String, String)? {
        switch self {
        case .setQuery:
            ("Set library source, filters and sort. Use source_id from list_library_sources. Omitted criteria are preserved, and clear_filters clears stored criteria before applying any supplied fields. ISO 0 clears that bound. hold_results freezes membership and order.", "source_id, query, filter_settings, query_revision, counts and selection")
        case .refreshQuery:
            ("Re-evaluate the current query, including held membership and order.", "query, query_revision, counts and selection")
        case .listSelected:
            ("Page through the current selection by version ID, including selections on other pages and folded members. Reuse next_cursor until it is null.", "items, selection_count, selection_revision, next_cursor")
        case .selectPhotos:
            ("Replace, add or remove explicit photo_ids in the current query; clear; select all matches; select matching stack members of photo_id (default active); or open_version by photo_id even outside the query. active_photo_id may specify a selected version.", "active_photo_id, selected_photo_ids, selection_count, selection_revision, page_offset")
        case .navigate:
            ("Move to the previous or next photo or page, go back or forward in browse history, or open a location_id from get_workspace.", "source_id, active_photo_id, page_offset and browse history")
        case .workspaceView:
            ("Switch the native workspace to grid, single, develop, compare or survey. In develop choose adjust, crop, mask or spot if available.", "view, tool and active photo")
        case .viewport:
            ("Set fit, fill or an explicit zoom scale and normalized top-left center. Fill and locked position apply to the main canvas. Compare supports reference and candidate panes and linked zoom and pan. Develop reference zoom is independent.", "viewport, comparison and develop_reference")
        case .compare:
            ("Set explicit reference and candidate versions, optionally with a photo_ids candidate group. Swap, promote the candidate, set restrict_to_group, or compare the active photo's related versions or stack.", "comparison, active_photo_id and source_id")
        case .survey:
            ("Set survey photo_ids in the current query. Remove, activate or open a member by photo_id, or move between survey pages.", "survey, view, active_photo_id and selection")
        case .developReference:
            ("Pin the active saved photo as the develop reference, toggle the reference pane or clear the pin. To pin a particular photo, select it in Develop first and pass its photo_id.", "develop_reference and active_photo_id")
        case .clipping:
            ("Set the native display-only highlight and shadow clipping switches. Omitted switches keep their value.", "clipping with shadows and highlights")
        case .retryPreview:
            ("Retry the native canvas preview for the explicit active photo after a load failure.", "active_photo_id, loading_photo, preview_current and can_edit")
        case .rateBatch:
            ("Set a common rating from 0 to 5, or step each target by rating_step of -1 or 1. Every target needs its photo_id and expected_rating. The batch is atomic. Pass advance=true to advance from a targeted active photo.", "items with previous and current marks, changed_count, operation_id and commit_state")
        case .marks:
            ("Set flags (-1 rejected, 0 none, 1 picked) or color labels (0 none, 1 red, 2 yellow, 3 green, 4 blue, 5 purple). Each target needs its photo_id and expected values for the fields being changed. The batch is atomic.", "items with previous and current marks, changed_count, operation_id and commit_state")
        case .keywords:
            ("List catalog keywords and their total and selected counts, optionally searching the names. An explicit photo_id also returns that version's saved keywords and caption.", "items with keyword_id and counts, recent_keywords, next_offset and optional photo_keywords and caption")
        case .editKeywords:
            ("Add or remove named keywords for the explicit photo_ids. Use list_keywords to check the saved keywords for a particular photo.", "affected_photo_ids, changed_count, operation_id and commit_state")
        case .renameKeyword:
            ("Rename a keyword identified by keyword_id from list_keywords, across the entire catalog. The destination name must be distinct from other keywords.", "keyword_id, name, affected_version_count, operation_id and commit_state")
        case .caption:
            ("Set the same caption on explicit versions. expected_captions maps each photo_id to its current caption from list_keywords. Pass an empty caption to clear it. A mismatch rejects the whole batch.", "caption, affected_photo_ids, changed_count, operation_id and commit_state")
        default: nil
        }
    }
}

extension PhotoMarks {
    var mcpValue: Value {
        ["rating": .int(rating), "flag": .int(flag), "color_label": .int(colorLabel)]
    }
}

struct MCPLibraryCriteria {
    static let attributes: [AppMCPTool.Field] = [.ratingComparison, .ratingThreshold, .flags, .labels]
    static let metadataFields: [AppMCPTool.Field] = [.camera, .lens, .minimumISO, .maximumISO, .dateFrom, .dateThrough, .keyword]
    static let fields: [AppMCPTool.Field] = [.source, .search, .sort, .descending] + attributes + metadataFields

    static func contains(_ fields: [AppMCPTool.Field], in arguments: [String: Value]) -> Bool {
        fields.contains { arguments[$0.rawValue] != nil }
    }

    static func metadata(_ arguments: [String: Value], startingWith initial: LibraryMetadataFilter = .init()) throws -> LibraryMetadataFilter {
        var filter = initial
        if let camera = arguments["camera"]?.stringValue { filter.camera = camera }
        if let lens = arguments["lens"]?.stringValue { filter.lens = lens }
        if let iso = arguments["minimum_iso"]?.intValue { filter.minimumISO = iso == 0 ? "" : String(iso) }
        if let iso = arguments["maximum_iso"]?.intValue { filter.maximumISO = iso == 0 ? "" : String(iso) }
        if let date = arguments["date_from"]?.stringValue { filter.dateFrom = date }
        if let date = arguments["date_through"]?.stringValue { filter.dateThrough = date }
        if let message = filter.validationMessage { throw MCPToolProblem.invalid(message) }
        return filter
    }

    @MainActor static func validateSource(_ source: String, model: AppModel) throws {
        let exists = source == "all" || source == model.scope || source == model.lastImport?.scope
            || model.roots.contains { $0.id == source }
            || model.collections.contains { "collection:" + $0.id == source }
            || (source.hasPrefix("folder:") && model.folders.values.contains { AppMCPWorkflows.flatten($0).contains { $0.id == source } })
        guard exists else { throw MCPToolProblem.invalid("Select a current source_id from list_library_sources.") }
    }
}

struct MCPIndependentPhotoQuery {
    let source: String
    let criteria: PhotoQuery

    init(_ arguments: [String: Value]) throws {
        source = arguments["source_id"]?.stringValue ?? "all"
        var query = PhotoQuery(scope: source)
        query.search = arguments["search"]?.stringValue ?? ""
        query.ratingComparison = arguments["rating_comparison"]?.stringValue.flatMap(RatingComparison.init(rawValue:)) ?? .atLeast
        query.ratingThreshold = arguments["rating_threshold"]?.intValue ?? 0
        query.flags = Set(arguments["flags"]?.arrayValue?.compactMap(\.intValue) ?? [])
        query.colorLabels = Set(arguments["color_labels"]?.arrayValue?.compactMap(\.intValue) ?? [])
        query.keyword = arguments["keyword"]?.stringValue ?? ""
        query.metadata = try MCPLibraryCriteria.metadata(arguments)
        query.sort = arguments["sort"]?.stringValue.flatMap(PhotoSort.init(rawValue:)) ?? .captureDate
        query.descending = arguments["descending"]?.boolValue ?? false
        query.manualCollectionOrder = arguments["sort"] == "manual"
        query.useRelatedSnapshotOrder = false
        criteria = query
    }

    func resolve(in db: Database) throws -> PhotoQuery {
        var query = criteria
        if source.hasPrefix("collection:") {
            let id = String(source.dropFirst("collection:".count))
            guard let collection = try PhotoCollection.fetchOne(db, key: id) else { throw MCPCollectionState.unavailable }
            if collection.isSmart {
                guard !query.manualCollectionOrder else { throw Self.manualOrderUnavailable }
                guard let queryWithRules = try? collection.resultQuery() else {
                    throw MCPToolProblem(code: "collection_unavailable", summary: "The smart collection's saved rules are invalid.",
                                         next: "Check its rules in get_collection or choose a different source.")
                }
                query.scope = queryWithRules.scope
                query.smart = queryWithRules.smart
            }
        } else if query.manualCollectionOrder {
            throw Self.manualOrderUnavailable
        }
        return query
    }

    private static let manualOrderUnavailable = MCPToolProblem.invalid("Manual order is available in regular collections.")
}

extension AppMCPTools {
    static func browseState(_ model: AppModel) -> [String: Value] {
        let query = model.query
        let selected = model.selection.prefix(50).sorted()
        let metadata = query.metadata
        var data: [String: Value] = [
            "source_id": model.catalog == nil ? .null : .string(model.scope),
            "query_revision": .string(model.browseGeneration.uuidString),
            "selection_revision": .string(model.selectionGeneration.uuidString),
            "query": [
                "search": .string(query.search), "rating_threshold": .int(query.ratingThreshold),
                "rating_comparison": .string(query.ratingComparison.rawValue), "flags": .array(query.flags.sorted().map(Value.int)),
                "color_labels": .array(query.colorLabels.sorted().map(Value.int)), "keyword": .string(query.keyword),
                "metadata": ["camera": .string(metadata.camera), "lens": .string(metadata.lens), "minimum_iso": .string(metadata.minimumISO),
                             "maximum_iso": .string(metadata.maximumISO), "date_from": .string(metadata.dateFrom), "date_through": .string(metadata.dateThrough)],
                "sort": .string(query.isManualCollectionOrder ? "manual" : query.sort.rawValue), "descending": .bool(query.descending),
                "frozen": .bool(query.snapshotID != nil), "smart_collection": .bool(query.smart != nil || query.invalidSmart)
            ],
            "filter_settings": [
                "enabled": .bool(model.filtersEnabled), "open": .bool(model.libraryFiltersOpen),
                "sections": .array(model.filterSections.map(\.rawValue).sorted().map(Value.string)), "hold_results": .bool(model.holdFilterResults)
            ],
            "matched_count": .int(model.resultCount), "visible_count": .int(model.visibleCount),
            "page_offset": .int(model.pageOffset), "page_size": .int(model.pageSize),
            "active_photo_id": model.activeID.map(Value.string) ?? .null, "selection_count": .int(model.selection.count),
            "selected_photo_ids": .array(selected.map(Value.string)), "selection_truncated": .bool(selected.count < model.selection.count),
            "can_browse_back": .bool(model.canBrowseBack), "can_browse_forward": .bool(model.canBrowseForward),
            "browse_locations": .array(model.recentBrowseLocations.map {
                ["location_id": .string($0.id.uuidString), "name": .string($0.title), "photo_name": .string($0.photo)]
            }),
            "view": .string(model.workspaceMode.rawValue), "tool": model.editMode ? .string(model.developTool.rawValue) : .null,
            "loading_photo": .bool(model.loadingPhoto), "preview_current": .bool(model.previewCurrent), "can_edit": .bool(model.canEdit),
            "viewport": viewportState(model.viewport, scale: model.fullResolution ? model.zoomScale : nil, fill: model.fillView, locked: model.lockViewPosition),
            "clipping": ["shadows": .bool(model.showShadowClipping), "highlights": .bool(model.showHighlightClipping)]
        ]
        data["comparison"] = model.comparison.map {
            ["reference": paneState($0.reference), "candidate": paneState($0.candidate), "linked": .bool($0.linked),
             "group_count": .int($0.groupIDs?.count ?? 0), "restrict_to_group": .bool($0.restrictToGroup)]
        } ?? .null
        data["survey"] = model.survey.map {
            ["photo_count": .int($0.ids.count), "page_offset": .int($0.offset), "visible_photo_ids": .array($0.visibleIDs.map(Value.string))]
        } ?? .null
        data["develop_reference"] = model.developReference.map(paneState) ?? .null
        return data
    }

    private static func paneState(_ pane: ComparisonPhoto) -> Value {
        ["photo": pane.photo.map { .object(Self.photo($0, badge: nil)) } ?? .null,
         "viewport": viewportState(pane.viewport, scale: pane.zoom), "preview_ready": .bool(pane.image != nil)]
    }

    private static func viewportState(_ viewport: PhotoViewport, scale: Double?, fill: Bool = false, locked: Bool = false) -> Value {
        let center = viewport.center, requested = viewport.requestedCenter
        return ["zoom": scale == nil ? (fill ? "fill" : "fit") : "scale", "scale": scale.map(Value.double) ?? .null,
                "x": .double(center.x), "y": .double(center.y), "requested_x": .double(requested.x), "requested_y": .double(requested.y),
                "locked": .bool(locked)]
    }

    func writeCulling(_ tool: AppMCPTool, arguments args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let id = args["photo_id"]?.stringValue
        if let revision = args["query_revision"]?.stringValue, revision != model.browseGeneration.uuidString { throw MCPToolProblem.staleQuery }
        if let revision = args["selection_revision"]?.stringValue, revision != model.selectionGeneration.uuidString { throw MCPToolProblem.staleSelection }
        switch tool {
        case .setQuery: try setQuery(args, model: model)
        case .refreshQuery: try model.updateLibraryQuery()
        case .selectPhotos: try selectPhotos(args, model: model, catalog: catalog)
        case .navigate: try navigate(args, model: model)
        case .workspaceView:
            let mode = WorkspaceMode(rawValue: args["view"]!.stringValue!)!
            let developTool = args["tool"]?.stringValue.flatMap(DevelopTool.init(rawValue:))
            guard developTool == nil || mode == .develop else { throw MCPToolProblem.invalid("Only Develop accepts an editing tool.") }
            if let developTool, developTool != .adjust, !model.canEdit { throw Self.viewUnavailable }
            model.selectWorkspace(mode)
            guard model.workspaceMode == mode else { throw Self.viewUnavailable }
            if let developTool, developTool != model.developTool, !model.selectDevelopTool(developTool) { throw Self.viewUnavailable }
        case .viewport: try setViewport(args, model: model)
        case .compare: try setComparison(args, model: model, catalog: catalog)
        case .survey: try setSurvey(args, model: model, catalog: catalog)
        case .developReference:
            let action = args["action"]!.stringValue!
            switch action {
            case "pin":
                guard model.editMode, model.canEdit, id == nil || id == model.activeID else { throw Self.viewUnavailable }
                model.pinActiveAsDevelopReference()
                guard model.developReference != nil else { throw Self.viewUnavailable }
            case "toggle":
                guard model.canShowDevelopReference else { throw Self.viewUnavailable }
                model.toggleDevelopReference()
            default: model.clearDevelopReference()
            }
        case .clipping:
            if let shadows = args["shadows"]?.boolValue { model.showShadowClipping = shadows }
            if let highlights = args["highlights"]?.boolValue { model.showHighlightClipping = highlights }
        case .retryPreview:
            guard id == model.activeID, model.active != nil else { throw MCPToolProblem.photoUnavailable }
            guard !model.canEdit, !model.loadingPhoto, model.comparison == nil, model.survey == nil else { throw Self.viewUnavailable }
            model.retryPhotoLoad()
        default: throw MCPToolProblem.failed
        }
        return .init("Read the resulting workspace.", data: Self.browseState(model))
    }

    private static let viewUnavailable = MCPToolProblem(code: "view_unavailable", summary: "The requested view or action is unavailable in the current workspace.", next: "Check the active photo, selection and view in get_workspace.")

    private func setQuery(_ args: [String: Value], model: AppModel) throws {
        let source = args["source_id"]?.stringValue
        if let source { try MCPLibraryCriteria.validateSource(source, model: model) }
        let sort = args["sort"]?.stringValue
        if sort == "manual" {
            let target = source ?? model.scope
            guard model.collections.contains(where: { !$0.isSmart && "collection:" + $0.id == target }) else {
                throw MCPToolProblem.invalid("Manual order is available in regular collections.")
            }
        }

        let clear = args["clear_filters"]?.boolValue == true
        let metadata = try MCPLibraryCriteria.metadata(args, startingWith: clear ? .init() : model.metadataFilter)
        if let source, source != model.scope, source == model.lastImport?.scope {
            model.showLastImport()
            guard model.scope == source else { throw MCPToolProblem.failed }
        }
        try model.updateLibraryQuery(source: source, forceRefresh: false) {
            if clear { model.clearFilters() }
            if let text = args["search"]?.stringValue { model.search = text }
            if let threshold = args["rating_threshold"]?.intValue { model.ratingThreshold = threshold }
            if let comparison = args["rating_comparison"]?.stringValue { model.ratingComparison = RatingComparison(rawValue: comparison)! }
            if let flags = args["flags"]?.arrayValue { model.flagFilter = Set(flags.compactMap(\.intValue)) }
            if let labels = args["color_labels"]?.arrayValue { model.colorLabelFilter = Set(labels.compactMap(\.intValue)) }
            if let keyword = args["keyword"]?.stringValue { model.keywordFilter = keyword }
            model.metadataFilter = metadata
            let sections: [LibraryFilterSection] = [
                args["search"] != nil ? .text : nil,
                MCPLibraryCriteria.contains(MCPLibraryCriteria.attributes, in: args) ? .attribute : nil,
                MCPLibraryCriteria.contains(MCPLibraryCriteria.metadataFields, in: args) ? .metadata : nil
            ].compactMap { $0 }
            if !sections.isEmpty { model.filterSections.formUnion(sections); model.filtersEnabled = true }
            if let sections = args["filter_sections"]?.arrayValue {
                model.filterSections = Set(sections.compactMap { $0.stringValue.flatMap(LibraryFilterSection.init(rawValue:)) })
            }
            if let enabled = args["filters_enabled"]?.boolValue { model.filtersEnabled = enabled }
            if let open = args["filters_open"]?.boolValue { model.libraryFiltersOpen = open }
            if let sort {
                model.manualOrderEnabled = sort == "manual"
                if let order = PhotoSort(rawValue: sort) { model.photoSort = order }
            }
            if let descending = args["descending"]?.boolValue { model.sortDescending = descending }
            if let hold = args["hold_results"]?.boolValue { model.holdFilterResults = hold }
        }
    }

    private func selectPhotos(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws {
        let action = args["action"]!.stringValue!
        let explicit = args["active_photo_id"]?.stringValue
        let input = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let id = args["photo_id"]?.stringValue
        if action == "open_version" {
            guard let id, try catalog.photo(id) != nil, explicit == nil, input.isEmpty else { throw MCPToolProblem.photoUnavailable }
            model.openVersion(id)
            guard model.activeID == id else { throw Self.viewUnavailable }
            return
        }
        let query = model.query
        let ids: Set<String>
        switch action {
        case "all":
            guard input.isEmpty, id == nil else { throw MCPToolProblem.invalid("All selects the complete current query.") }
            ids = Set(try catalog.allResultIDs(query))
        case "stack":
            guard input.isEmpty, let member = id ?? model.activeID,
                  let stack = try catalog.stacks().first(where: { $0.members.contains(member) }) else {
                throw MCPToolProblem.invalid("Choose a version from a current stack.")
            }
            ids = try catalog.resultIDs(query, within: Set(stack.members))
        case "clear":
            guard input.isEmpty, id == nil else { throw MCPToolProblem.invalid("Clear uses no target IDs.") }
            ids = []
        default:
            guard id == nil, !input.isEmpty else { throw MCPToolProblem.invalid("Provide photo_ids for this selection action.") }
            let requested = Set(input)
            if action == "remove" { ids = model.selection.subtracting(requested) }
            else {
                guard try catalog.resultIDs(query, within: requested) == requested else { throw MCPToolProblem.staleQuery }
                ids = action == "add" ? model.selection.union(requested) : requested
            }
        }
        guard explicit.map(ids.contains) ?? true else { throw MCPToolProblem.invalid("The active photo must be in the resulting selection.") }
        if let comparison = model.comparison {
            guard ids.count <= 1, comparison.reference.photo.map({ !ids.contains($0.id) }) ?? true,
                  !comparison.restrictToGroup || ids.isSubset(of: Set(comparison.groupIDs ?? [])) else {
                throw Self.viewUnavailable
            }
        }
        let current = model.activeID.flatMap { ids.contains($0) ? $0 : nil }
        let visible = model.photos.first { ids.contains($0.id) }?.id
        let active = explicit ?? current ?? visible ?? input.first(where: ids.contains) ?? ids.min()
        if model.survey != nil {
            model.updateSurveySelection(ids, active: active)
            if let active { model.activateSurveyPhoto(active) }
        } else {
            if let active, let position = try catalog.offset(of: active, query: query, includingRepresentative: true) {
                let offset = position / model.pageSize * model.pageSize
                if offset != model.pageOffset { model.pageOffset = offset; try model.reloadPhotos() }
            }
            model.choose(ids, active: active)
        }
    }

    private func navigate(_ args: [String: Value], model: AppModel) throws {
        let action = args["action"]!.stringValue!
        if action != "location", args["location_id"] != nil { throw MCPToolProblem.invalid("location_id is only used with action=location.") }
        switch action {
        case "previous_photo": model.move(-1)
        case "next_photo": model.move(1)
        case "previous_page": model.changePage(-1)
        case "next_page": model.changePage(1)
        case "back": model.navigateBrowse(-1)
        case "forward": model.navigateBrowse(1)
        default:
            guard let id = args["location_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  model.recentBrowseLocations.contains(where: { $0.id == id }) else { throw Self.viewUnavailable }
            model.navigateBrowse(to: id)
        }
    }

    private func setComparison(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws {
        let action = args["action"]!.stringValue!
        if action == "set" {
            let input = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue)
            let restrict = args["restrict_to_group"]?.boolValue ?? false
            guard let reference = args["reference_photo_id"]?.stringValue, let candidate = args["candidate_photo_id"]?.stringValue,
                  reference != candidate, try catalog.photo(reference) != nil, try catalog.photo(candidate) != nil else {
                throw MCPToolProblem.invalid("Specify two distinct saved photo versions.")
            }
            if let input {
                guard input.contains(reference), input.contains(candidate),
                      try catalog.resultIDs(model.query, within: Set(input)) == Set(input) else {
                    throw MCPToolProblem.invalid("The candidate group must include both versions and be in the current query.")
                }
            } else if restrict { throw MCPToolProblem.invalid("Provide photo_ids to restrict the candidate group.") }
            model.endSurvey(); model.endComparison()
            model.choose([reference], active: reference)
            model.beginComparison(candidateID: candidate, groupIDs: input)
            guard let comparison = model.comparison, comparison.candidate.photo?.id == candidate else { throw Self.viewUnavailable }
            // The explicit pair stays put when setting the candidate range.
            comparison.restrictToGroup = restrict
            return
        }
        if action == "related_versions" || action == "related_stack" {
            let original = model.scope
            model.compareRelatedVersions(inStack: action == "related_stack")
            guard model.isViewingRelated, model.scope != original, model.comparison != nil else { throw Self.viewUnavailable }
            return
        }
        guard let comparison = model.comparison else { throw Self.viewUnavailable }
        switch action {
        case "swap": model.swapComparison()
        case "promote": model.promoteComparisonCandidate()
        default:
            guard let restrict = args["restrict_to_group"]?.boolValue, !restrict || comparison.groupIDs != nil else { throw Self.viewUnavailable }
            model.restrictComparisonToGroup(restrict)
        }
    }

    private func setSurvey(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws {
        let action = args["action"]!.stringValue!
        if action == "set" {
            guard let ids = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue), ids.count >= 2,
                  try catalog.resultIDs(model.query, within: Set(ids)) == Set(ids) else {
                throw MCPToolProblem.invalid("Specify two or more matching photo versions.")
            }
            let active = args["active_photo_id"]?.stringValue
            guard active.map(ids.contains) ?? true else { throw MCPToolProblem.invalid("The active version must belong to the survey.") }
            model.beginSurvey(ids: ids, active: active)
            if let id = model.activeID { model.activateSurveyPhoto(id) }
            guard model.survey != nil else { throw Self.viewUnavailable }
            return
        }
        guard let survey = model.survey else { throw Self.viewUnavailable }
        if action == "previous_page" || action == "next_page" {
            model.changeSurveyPage(action == "next_page" ? 1 : -1)
            return
        }
        guard let id = args["photo_id"]?.stringValue, survey.ids.contains(id) else { throw MCPToolProblem.photoUnavailable }
        switch action {
        case "remove": model.removeFromSurvey(id)
        case "activate": model.activateSurveyPhoto(id)
        default:
            model.activateSurveyPhoto(id)
            model.selectWorkspace(.single)
            model.choose([id], active: id)
        }
    }

    private func setViewport(_ args: [String: Value], model: AppModel) throws {
        let pane = args["pane"]?.stringValue ?? (model.comparison == nil ? "main" : "candidate")
        let zoom = args["zoom"]?.stringValue
        let scale = args["scale"]?.number
        let x = args["x"]?.number, y = args["y"]?.number
        guard (x == nil) == (y == nil), (zoom == "scale") == (scale != nil) else {
            throw MCPToolProblem.invalid("Provide both x and y for a center, or an explicit scale with zoom=scale.")
        }
        let point = x.map { CGPoint(x: $0, y: y!) }
        let locked = args["locked"]?.boolValue
        let linked = args["linked"]?.boolValue
        if pane == "main" {
            guard model.singleView, model.comparison == nil, model.survey == nil, linked == nil else { throw Self.viewUnavailable }
            let zoomed = zoom.map { $0 != "fit" } ?? (model.fullResolution || model.fillView)
            guard point == nil || zoomed else { throw MCPToolProblem.invalid("Use fill or an explicit scale to pan the main canvas.") }
            if let zoom { model.selectZoom(scale, fill: zoom == "fill") }
            if let locked { model.lockViewPosition = locked }
            if let point { model.viewport.focusOnNextGeometry(point); model.viewport.move(to: point) }
            return
        }
        guard zoom != "fill", locked == nil else { throw MCPToolProblem.invalid("Fill and position lock apply to the main canvas.") }
        if pane == "develop_reference" {
            guard let reference = model.developReference, linked == nil else { throw Self.viewUnavailable }
            guard point == nil || (zoom == nil ? reference.zoom : scale) != nil else { throw MCPToolProblem.invalid("Zoom before panning the reference.") }
            if zoom != nil || point != nil { model.selectDevelopReferenceZoom(zoom == nil ? reference.zoom : scale, focus: point) }
            if let point, reference.zoom != nil { reference.viewport.move(to: point) }
            return
        }
        guard let comparison = model.comparison else { throw Self.viewUnavailable }
        let target = pane == "reference" ? comparison.reference : comparison.candidate
        let currentScale = linked == true ? comparison.candidate.zoom : target.zoom
        guard point == nil || (zoom == nil ? currentScale : scale) != nil else { throw MCPToolProblem.invalid("Zoom before panning the comparison.") }
        if let linked { comparison.setLinked(linked) }
        if zoom != nil || point != nil { comparison.selectZoom(zoom == nil ? target.zoom : scale, in: target, focus: point) }
        if let point, target.zoom != nil { target.viewport.move(to: point); comparison.pan(from: target, to: point) }
    }

    func editMarks(_ tool: AppMCPTool, arguments args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let single = tool == .rate
        let rating = args["rating"]?.intValue, step = args["rating_step"]?.intValue
        let flag = args["flag"]?.intValue, label = args["color_label"]?.intValue
        if tool == .rateBatch, (rating == nil) == (step == nil) { throw MCPToolProblem.invalid("Choose exactly one rating or rating_step.") }
        if tool == .marks, flag == nil, label == nil { throw MCPToolProblem.invalid("Set a flag or color label.") }
        let targets = single ? [args] : args["targets"]!.arrayValue!.compactMap(\.objectValue)
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0["photo_id"]!.stringValue!, $0) })
        let ids = Set(byID.keys)
        let advance = args["advance"]?.boolValue == true && model.activeID.map(ids.contains) == true
        let (changes, refreshed) = try model.updateOrganization(ids: ids, advance: advance, explicit: true, notice: { changes in
            AppModel.organizationNotice(rating: changes.count == 1 ? changes.first?.current.rating : rating,
                                        flag: flag, colorLabel: label, count: changes.count)
        }) { id, actual in
            let target = byID[id]!
            let expectedRating = target["expected_rating"]?.intValue
            let expectedFlag = target["expected_flag"]?.intValue
            let expectedLabel = target["expected_color_label"]?.intValue
            guard (rating == nil && step == nil || expectedRating != nil), (flag == nil || expectedFlag != nil),
                  (label == nil || expectedLabel != nil) else {
                throw MCPToolProblem.invalid("Provide the expected current value for every field being changed.")
            }
            if let expectedRating, expectedRating != actual.rating, single { throw OrganizationError.ratingConflict(actual: actual.rating) }
            guard expectedRating.map({ $0 == actual.rating }) ?? true, expectedFlag.map({ $0 == actual.flag }) ?? true,
                  expectedLabel.map({ $0 == actual.colorLabel }) ?? true else { throw OrganizationError.marksConflict(id: id, actual: actual) }
            return actual.setting(rating: rating ?? step.map { min(5, max(0, actual.rating + $0)) }, flag: flag, colorLabel: label)
        }
        let changed = changes.filter { $0.previous != $0.current }
        let affected = Set(changed.map(\.id))
        func snapshot(_ rows: [(String, PhotoMarks)]) -> Value {
            let items = rows.sorted { $0.0 < $1.0 }.map { id, marks -> Value in
                ["photo_id": .string(id), "marks": marks.mcpValue]
            }
            if single, let (id, marks) = rows.first {
                return ["photo_id": .string(id), "rating": .int(marks.rating), "items": .array(items)]
            }
            return ["items": .array(items)]
        }
        let expected = snapshot(changed.map { ($0.id, $0.current) })
        let operation = changed.isEmpty ? .null : recordUndo(before: snapshot(changed.map { ($0.id, $0.previous) }), after: expected,
                                                            describe: { $0.objectValue ?? [:] }) {
            try snapshot($0.photos(ids: affected).map { ($0.id, PhotoMarks($0)) })
        }
        let verified = (try? snapshot(catalog.photos(ids: ids).map { ($0.id, PhotoMarks($0)) })) == snapshot(changes.map { ($0.id, $0.current) })
        var data: [String: Value] = [
            "items": .array(changes.map { ["photo_id": .string($0.id), "previous": $0.previous.mcpValue, "current": $0.current.mcpValue] }),
            "changed_count": .int(changed.count), "changed": .bool(!changed.isEmpty),
            "commit_state": changed.isEmpty ? "not_committed" : "committed", "operation_id": operation,
            "active_photo_id": model.activeID.map(Value.string) ?? .null
        ]
        if single, let result = changes.first {
            data["photo_id"] = .string(result.id); data["previous_rating"] = .int(result.previous.rating); data["rating"] = .int(result.current.rating)
        }
        return .init(changed.isEmpty ? "The photos already have those marks." : "Saved marks for \(changed.count) photos.",
                     data: data, warning: !refreshed || !verified)
    }
}
