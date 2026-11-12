import AppKit
import MCP

enum MCPAppPanel: String, CaseIterable {
    case settings, taskResults = "task_results", importRecovery = "import_recovery"
    case outputRecovery = "output_recovery", cameraDiagnostics = "camera_diagnostics"

    static let settingsPanes: [String: SettingsPane] = [
        "appearance": .appearance, "storage": .storage, "shortcuts": .shortcuts, "agent": .agent
    ]

    @MainActor static func visible(in model: AppModel) -> MCPAppPanel? {
        if workspaceWindow?.attachedSheet?.isVisible == true {
            if model.showTaskResults { return .taskResults }
            if model.showCopyRecovery { return .importRecovery }
            if model.showOutputRecovery { return .outputRecovery }
            if model.showCameraDiagnostics { return .cameraDiagnostics }
        }
        return model.settingsWindow?.isVisible == true ? .settings : nil
    }

    @MainActor static var workspaceWindow: NSWindow? {
        NSApp?.windows.first { $0.isVisible && WorkspaceKeyboard.isWorkspaceWindow($0) }
    }

    @MainActor func describe(_ model: AppModel) -> Value {
        ["panel": .string(rawValue), "pane": self == .settings
            ? Self.settingsPanes.first { $0.value == model.settingsPane }.map { .string($0.key) } ?? .null : .null]
    }
}

enum MCPPreferences {
    private static let switches: [(field: String, key: String, initial: Bool)] = [
        ("show_left_panel", "showLeftPanel", true), ("show_right_panel", "showRightPanel", true),
        ("show_filmstrip", "showFilmstrip", true), ("navigator_open", "developPreviewOpen", true),
        ("collections_open", "workspaceCollectionsOpen", true), ("presets_open", "workspacePresetsOpen", true),
        ("history_open", "workspaceHistoryOpen", true), ("snapshots_open", "workspaceSnapshotsOpen", true),
        ("mask_list_open", "maskListExpanded", true), ("develop_solo_mode", "developSoloMode", false),
        ("develop_show_only_modified", "developShowOnlyModified", false)
    ]
    private static let dimensions = [
        (field: "left_panel_width", key: "workspaceLeftWidth", metric: Metrics.leftPanel),
        (field: "right_panel_width", key: "workspaceRightWidth", metric: Metrics.rightPanel),
        (field: "filmstrip_height", key: "workspaceFilmHeight", metric: Metrics.filmstrip)
    ]
    private static let groups: [String: String] = [
        "basic": "developBasicOpen", "crop": "developCropOpen", "perspective": "developPerspectiveOpen",
        "mixer": "developMixerOpen", "grading": "developGradingOpen", "black_white_mixer": "developBlackWhiteMixerOpen",
        "noise": "developNoiseOpen", "sharpen": "developSharpenOpen", "details": "developDetailsOpen",
        "defringe": "developDefringeOpen", "curves": "developCurvesOpen", "zones": "developZonesOpen",
        "vignette": "developVignetteOpen", "grain": "developGrainOpen", "point_color": "developPointColorOpen"
    ]

    static var schema: Value {
        var fields: [String: Value] = [
            "theme": MCPOutputSchema.choice(ChromeTheme.allCases.map(\.rawValue)),
            "photo_mat": MCPOutputSchema.choice(PhotoMat.allCases.map(\.rawValue)),
            "library_filters_open": MCPOutputSchema.boolean, "auto_advance": MCPOutputSchema.boolean,
            "thumbnail_size": MCPOutputSchema.integer(AppModel.thumbnailSizeRange),
            "develop_groups": MCPCanvasFields.patch(groups.mapValues { _ in MCPOutputSchema.boolean })
        ]
        for item in switches { fields[item.field] = MCPOutputSchema.boolean }
        for item in dimensions { fields[item.field] = MCPDevelopParameters.numberSchema(item.metric.range) }
        return MCPCanvasFields.patch(fields)
    }

    @MainActor static func read(_ model: AppModel) -> [String: Value] {
        let defaults = model.workspacePreferences
        var fields: [String: Value] = [
            "theme": .string((defaults?.string(forKey: "chromeTheme").flatMap(ChromeTheme.init(rawValue:)) ?? .graphite).rawValue),
            "photo_mat": .string((defaults?.string(forKey: "photoMat").flatMap(PhotoMat.init(rawValue:)) ?? .dark).rawValue),
            "library_filters_open": .bool(model.libraryFiltersOpen), "auto_advance": .bool(model.autoAdvance),
            "thumbnail_size": .int(Int(model.thumbnailSize.rounded()))
        ]
        for item in switches { fields[item.field] = .bool(defaults?.object(forKey: item.key) as? Bool ?? item.initial) }
        for item in dimensions {
            let size = defaults?.object(forKey: item.key) as? Double
            fields[item.field] = .double(size.flatMap { item.metric.range.contains($0) ? $0 : nil } ?? item.metric.initial)
        }
        fields["develop_groups"] = .object(groups.mapValues { key in
            .bool(defaults?.object(forKey: key) as? Bool ?? (key == "developBasicOpen"))
        })
        return fields
    }

    @MainActor static func apply(_ patch: [String: Value], to model: AppModel) throws -> MCPToolResult {
        guard let defaults = model.workspacePreferences else { throw MCPToolProblem.failed }
        let before = read(model)
        let groupChanges = patch["develop_groups"]?.objectValue ?? [:]
        let wasSolo = before["develop_solo_mode"]?.boolValue ?? false
        let solo = patch["develop_solo_mode"]?.boolValue ?? wasSolo
        let soloGroups = groups.filter { !["crop", "perspective"].contains($0.key) }
        let expanded = groupChanges.filter { soloGroups[$0.key] != nil && $0.value.boolValue == true }
        guard !solo || expanded.count <= 1 else {
            throw MCPToolProblem.invalid("Expand one adjustment group at a time while Develop solo mode is enabled.")
        }
        if let theme = patch["theme"]?.stringValue { defaults.set(theme, forKey: "chromeTheme") }
        if let mat = patch["photo_mat"]?.stringValue { defaults.set(mat, forKey: "photoMat") }
        for item in switches {
            if let value = patch[item.field]?.boolValue { defaults.set(value, forKey: item.key) }
        }
        for item in dimensions {
            if let value = patch[item.field]?.number { defaults.set(value, forKey: item.key) }
        }
        if solo, let group = expanded.keys.first ?? (wasSolo ? nil : "basic") {
            for (field, key) in soloGroups { defaults.set(field == group, forKey: key) }
        }
        for (field, value) in groupChanges {
            if let key = groups[field], let open = value.boolValue { defaults.set(open, forKey: key) }
        }
        if let value = patch["thumbnail_size"]?.intValue {
            model.thumbnailSize = Double(value)
            model.persistThumbnailSize()
        }
        if let value = patch["auto_advance"]?.boolValue { model.autoAdvance = value }
        if let value = patch["library_filters_open"]?.boolValue { model.libraryFiltersOpen = value }
        if patch["auto_advance"] != nil || patch["library_filters_open"] != nil { model.persistWorkspace() }
        let after = read(model)
        return .init("Updated Phosdeck preferences.", data: [
            "preferences": .object(after), "commit_state": before == after ? "not_committed" : "committed"
        ])
    }
}

extension AppMCPWorkflows {
    func showAppPanel(_ args: Arguments) throws -> MCPToolResult {
        let panel = MCPAppPanel(rawValue: args["panel"]!.stringValue!)!
        let pane = args["pane"]?.stringValue.flatMap { MCPAppPanel.settingsPanes[$0] }
        guard pane == nil || panel == .settings else { throw MCPToolProblem.invalid("Choose a pane only for Settings.") }
        guard (args["record_ids"] == nil && args["unfinished_only"] == nil) || panel == .outputRecovery else {
            throw MCPToolProblem.invalid("Output record filters require the output_recovery panel.")
        }
        if panel == .importRecovery || panel == .outputRecovery {
            guard model.catalog != nil else { throw MCPToolProblem.noCatalog }
            guard model.catalogSessionID == args["catalog_session_id"]?.stringValue else { throw MCPToolProblem.catalogChanged }
        }
        return start(.showAppPanel) { job in
            if panel == .settings {
                guard let openSettings = self.model.openSettingsWindow else { throw Self.panelUnavailable }
                if let pane { self.model.settingsPane = pane }
                NSApp.activate()
                openSettings()
            } else {
                guard let window = MCPAppPanel.workspaceWindow else { throw Self.panelUnavailable }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                switch panel {
                case .taskResults: self.model.showTaskResults = true
                case .importRecovery: self.model.showCopyRecovery = true
                case .outputRecovery:
                    let ids = args["record_ids"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
                    self.model.busy = false
                    self.model.openExportRecords(ids: ids, unfinishedOnly: args["unfinished_only"]?.boolValue ?? false)
                    self.model.busy = true
                case .cameraDiagnostics:
                    self.model.cameraDiagnosticPresentation = self.cameraReport.map { ($0.report, $0.results) }
                    self.model.showCameraDiagnostics = true
                case .settings: break
                }
            }
            job.data["requested_panel"] = .string(panel.rawValue)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while MCPAppPanel.visible(in: self.model) != panel {
                guard ContinuousClock.now < deadline else { throw Self.panelUnavailable }
                try await Task.sleep(for: .milliseconds(25))
            }
            job.data["open_panel"] = panel.describe(self.model)
            job.finish(.succeeded, "Opened the Phosdeck panel.")
        }
    }

    private static let panelUnavailable = MCPToolProblem(code: "panel_unavailable", summary: "The requested panel is not visible.",
                                                        next: "Show the Phosdeck workspace and check its current dialog before retrying.")
}
