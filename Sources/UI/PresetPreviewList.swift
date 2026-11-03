import SwiftUI
import AppKit

/// A small, keyboard and accessibility friendly preset list.
///
/// Hovering or moving keyboard focus onto a row asks the owner to render a
/// preview. Clicking still calls onApply; preview callbacks never perform
/// the apply action; the owner keeps rendering and edit state separate.
struct PresetPreviewList: View {
    let presets: [AdjustmentPreset]
    /// When enabled, rows are grouped by the model's groupName. The owner
    /// still supplies a flat filtered array so keyboard order remains stable.
    var groupHeaders = false
    var groupNames: [String] = []
    var onPreview: (AdjustmentPreset) -> Void
    /// Receives the row that ended. `nil` means the whole list lost focus or
    /// disappeared and must clear the active preview unconditionally.
    var onEndPreview: (String?) -> Void
    var onApply: (AdjustmentPreset) -> Void
    var onRename: ((AdjustmentPreset) -> Void)?
    var onDelete: ((AdjustmentPreset) -> Void)?
    var onUpdate: ((AdjustmentPreset) -> Void)?
    var onFavorite: ((AdjustmentPreset, Bool) -> Void)?
    var onGroup: ((AdjustmentPreset, String) -> Void)?
    /// The owner uses this as an input gate for global photo-navigation keys.
    var onKeyboardFocusChanged: ((Bool) -> Void)?

    @FocusState private var focusedID: String?
    @State private var hoveredID: String?
    @State private var newGroupPreset: AdjustmentPreset?
    @State private var newGroupName = ""

    init(presets: [AdjustmentPreset],
         groupHeaders: Bool = false,
         groupNames: [String] = [],
         onPreview: @escaping (AdjustmentPreset) -> Void,
         onEndPreview: @escaping (String?) -> Void,
         onApply: @escaping (AdjustmentPreset) -> Void,
         onRename: ((AdjustmentPreset) -> Void)? = nil,
         onDelete: ((AdjustmentPreset) -> Void)? = nil,
         onUpdate: ((AdjustmentPreset) -> Void)? = nil,
         onFavorite: ((AdjustmentPreset, Bool) -> Void)? = nil,
         onGroup: ((AdjustmentPreset, String) -> Void)? = nil,
         onKeyboardFocusChanged: ((Bool) -> Void)? = nil) {
        self.presets = presets
        self.groupHeaders = groupHeaders
        self.groupNames = groupNames
        self.onPreview = onPreview
        self.onEndPreview = onEndPreview
        self.onApply = onApply
        self.onRename = onRename
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        self.onFavorite = onFavorite
        self.onGroup = onGroup
        self.onKeyboardFocusChanged = onKeyboardFocusChanged
    }

    var body: some View {
        VStack(spacing: 1) {
            if presets.isEmpty {
                Text(L10n.text("app.noPresetsYet", defaultValue: "No presets yet")).font(.caption11).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.row, alignment: .leading)
            } else if groupHeaders {
                let sections = groupedSections
                ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
                    Text(section.title)
                        .font(.caption11.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                        .background(Theme.inset.opacity(0.35))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(section.presets.enumerated()), id: \.element.id) { rowIndex, preset in
                        row(preset, index: flatIndex(sectionIndex, rowIndex))
                    }
                }
            } else {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    row(preset, index: index)
                }
            }
        }
        .onChange(of: focusedID) { _, id in
            onKeyboardFocusChanged?(id != nil)
            if let id, let preset = presets.first(where: { $0.id == id }) {
                onPreview(preset)
            } else if let hoveredID, let preset = presets.first(where: { $0.id == hoveredID }) {
                // Keyboard focus leaving a row must hand preview ownership
                // back to the row still under the pointer.
                onPreview(preset)
            } else {
                onEndPreview(nil)
            }
        }
        .onChange(of: presetIDs) { _, _ in
            // A search, group or Favorites filter can remove the hovered row
            // while the pointer remains in the same place. End the preview
            // before SwiftUI reuses that cell for a different preset.
            focusedID = nil
            hoveredID = nil
            onKeyboardFocusChanged?(false)
            onEndPreview(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            focusedID = nil; hoveredID = nil; onKeyboardFocusChanged?(false); onEndPreview(nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            focusedID = nil; hoveredID = nil; onKeyboardFocusChanged?(false); onEndPreview(nil)
        }
        .onDisappear { focusedID = nil; hoveredID = nil; onKeyboardFocusChanged?(false); onEndPreview(nil) }
        .alert(L10n.text("app.newGroup", defaultValue: "New Group"), isPresented: Binding(get: { newGroupPreset != nil }, set: { shown in
            if !shown { newGroupPreset = nil }
        })) {
            TextField(L10n.text("app.groupName", defaultValue: "Group Name"), text: $newGroupName)
            Button(L10n.text("app.cancel", defaultValue: "Cancel"), role: .cancel) { newGroupPreset = nil }
            Button(L10n.text("app.move", defaultValue: "Move")) {
                let value = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let preset = newGroupPreset, !value.isEmpty { onGroup?(preset, value) }
                newGroupPreset = nil
            }.disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L10n.text("app.thePresetMovesToThisGroupYouCanAlso", defaultValue: "The preset moves to this group. You can also select existing groups directly from the menu."))
        }
    }

    private func row(_ preset: AdjustmentPreset, index: Int) -> some View {
        let position = KeyPosition(index: index, count: presets.count)
        let focused = focusedID == preset.id
        return HStack(spacing: 1) {
            Button { finishPreview(); onApply(preset) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").foregroundStyle(Theme.textSecondary)
                    Text(preset.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "return").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KeyButtonStyle(selected: focused, position: onFavorite == nil ? position : .leading, height: Metrics.row, padding: 9))
            .focusable(true)
            .focused($focusedID, equals: preset.id)
            .onHover { inside in
                if inside {
                    hoveredID = preset.id
                    onPreview(preset)
                } else if hoveredID == preset.id {
                    hoveredID = nil
                    if focusedID != preset.id { onEndPreview(preset.id) }
                }
            }
            .onKeyPress(.upArrow) { moveFocus(-1) }
            .onKeyPress(.downArrow) { moveFocus(1) }
            .onKeyPress(.return) {
                finishPreview(); onApply(preset)
                return .handled
            }
            .onKeyPress(.escape) {
                focusedID = nil
                hoveredID = nil
                onKeyboardFocusChanged?(false)
                onEndPreview(nil)
                return .handled
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                // macOS opens the context menu after the long press. Clear the
                // display-only hover lane first so its image cannot outlive
                // the menu or a subsequent row action.
                focusedID = nil
                hoveredID = nil
                onKeyboardFocusChanged?(false)
                onEndPreview(nil)
            })
            .contextMenu { contextMenu(for: preset) }
            .accessibilityLabel(L10n.text("app.preset", defaultValue: "Preset \(preset.name)"))
            .accessibilityValue(focused ? L10n.text("app.focusedPreviewAvailablePressReturnToApply", defaultValue: "Focused; preview available. Press Return to apply") : L10n.text("app.previewAvailablePressReturnToApply", defaultValue: "Preview available. Press Return to apply"))
            .accessibilityHint(L10n.text("app.hoverOrFocusToPreviewClickToApply", defaultValue: "Hover or focus to preview; click to apply"))

            if let onFavorite {
                Button {
                    finishPreview()
                    onFavorite(preset, !preset.favorite)
                } label: {
                    Image(systemName: preset.favorite ? "star.fill" : "star")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(preset.favorite ? Theme.accentSignal : Theme.textSecondary)
                        .frame(width: Metrics.row, height: Metrics.row)
                }
                .buttonStyle(KeyButtonStyle(selected: preset.favorite, position: .trailing, height: Metrics.row, padding: 0))
                .help(preset.favorite ? L10n.text("app.removeFromFavorites", defaultValue: "Remove from Favorites") : L10n.text("app.addToFavorites", defaultValue: "Add to Favorites"))
                .accessibilityLabel(preset.favorite ? L10n.text("app.removeFromFavorites", defaultValue: "Remove from Favorites") : L10n.text("app.addToFavorites", defaultValue: "Add to Favorites"))
                .accessibilityValue(preset.favorite ? L10n.text("app.favorite", defaultValue: "Favorite") : L10n.text("app.notAFavorite", defaultValue: "Not a Favorite"))
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for preset: AdjustmentPreset) -> some View {
        if let onUpdate {
            Button(L10n.text("app.updateWithCurrentAdjustments", defaultValue: "Update with Current Adjustments")) { finishPreview(); onUpdate(preset) }
        }
        if let onFavorite {
            Button(preset.favorite ? L10n.text("app.removeFromFavorites", defaultValue: "Remove from Favorites") : L10n.text("app.addToFavorites", defaultValue: "Add to Favorites")) { finishPreview(); onFavorite(preset, !preset.favorite) }
        }
        if let onGroup {
            Menu(L10n.text("app.moveToGroup", defaultValue: "Move to Group")) {
                Button(L10n.text("app.ungrouped", defaultValue: "Ungrouped")) { finishPreview(); onGroup(preset, "") }
                ForEach(groupNames.filter { !$0.isEmpty && $0 != preset.groupName }, id: \.self) { group in
                    Button(group) { finishPreview(); onGroup(preset, group) }
                }
                Divider()
                Button(L10n.text("app.newGroup_1790", defaultValue: "New Group…")) {
                    finishPreview()
                    newGroupName = preset.groupName
                    newGroupPreset = preset
                }
            }
        }
        if onUpdate != nil || onFavorite != nil || onGroup != nil { Divider() }
        if let onRename {
            Button(L10n.text("app.rename", defaultValue: "Rename…")) { finishPreview(); onRename(preset) }
        }
        if let onDelete {
            Button(L10n.text("app.deletePreset", defaultValue: "Delete Preset"), role: .destructive) { finishPreview(); onDelete(preset) }
        }
    }

    private struct PresetSection {
        let title: String
        let presets: [AdjustmentPreset]
    }

    private var groupedSections: [PresetSection] {
        var result = [PresetSection]()
        for preset in presets {
            let title = preset.groupName.isEmpty ? L10n.text("app.ungrouped", defaultValue: "Ungrouped") : preset.groupName
            if result.last?.title == title {
                result[result.count - 1] = PresetSection(title: title, presets: result[result.count - 1].presets + [preset])
            } else {
                result.append(PresetSection(title: title, presets: [preset]))
            }
        }
        return result
    }

    private func flatIndex(_ section: Int, _ row: Int) -> Int {
        groupedSections.prefix(section).reduce(row) { $0 + $1.presets.count }
    }

    private var presetIDs: [String] { presets.map(\.id) }

    private func finishPreview() {
        focusedID = nil
        hoveredID = nil
        onKeyboardFocusChanged?(false)
        onEndPreview(nil)
    }

    private func moveFocus(_ offset: Int) -> KeyPress.Result {
        guard !presets.isEmpty else { return .ignored }
        let current = focusedID.flatMap { id in presets.firstIndex(where: { $0.id == id }) } ?? (offset > 0 ? -1 : presets.count)
        let next = current + offset
        guard presets.indices.contains(next) else { return .handled }
        focusedID = presets[next].id
        return .handled
    }
}
