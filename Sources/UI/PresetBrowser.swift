import SwiftUI

/// Searchable, grouped preset browser used inside the Develop sidebar.
///
/// Filtering is deliberately view-local: it never changes the catalog query
/// or the active photo. The owner remains responsible for applying, updating,
/// renaming, deleting and persisting favorite/group changes.
struct PresetBrowser: View {
    let presets: [AdjustmentPreset]

    var onPreview: (AdjustmentPreset) -> Void
    var onEndPreview: (String?) -> Void
    var onApply: (AdjustmentPreset) -> Void
    var onRename: ((AdjustmentPreset) -> Void)?
    var onDelete: ((AdjustmentPreset) -> Void)?
    var onKeyboardFocusChanged: ((Bool) -> Void)?
    var onUpdate: ((AdjustmentPreset) -> Void)?
    var onFavorite: ((AdjustmentPreset, Bool) -> Void)?
    var onGroup: ((AdjustmentPreset, String) -> Void)?

    @State private var search = ""
    @State private var selectedGroups = Set<String>()
    @State private var favoritesOnly = false
    @State private var filterRevision = 0
    @FocusState private var searchFocused: Bool

    init(presets: [AdjustmentPreset],
         onPreview: @escaping (AdjustmentPreset) -> Void,
         onEndPreview: @escaping (String?) -> Void,
         onApply: @escaping (AdjustmentPreset) -> Void,
         onRename: ((AdjustmentPreset) -> Void)? = nil,
         onDelete: ((AdjustmentPreset) -> Void)? = nil,
         onKeyboardFocusChanged: ((Bool) -> Void)? = nil,
         onUpdate: ((AdjustmentPreset) -> Void)? = nil,
         onFavorite: ((AdjustmentPreset, Bool) -> Void)? = nil,
         onGroup: ((AdjustmentPreset, String) -> Void)? = nil) {
        self.presets = presets
        self.onPreview = onPreview
        self.onEndPreview = onEndPreview
        self.onApply = onApply
        self.onRename = onRename
        self.onDelete = onDelete
        self.onKeyboardFocusChanged = onKeyboardFocusChanged
        self.onUpdate = onUpdate
        self.onFavorite = onFavorite
        self.onGroup = onGroup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            browserToolbar
            Seam()
            if visiblePresets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    PresetPreviewList(presets: visiblePresets,
                                      groupHeaders: true,
                                      groupNames: groupNames,
                                      onPreview: onPreview,
                                      onEndPreview: onEndPreview,
                                      onApply: onApply,
                                      onRename: onRename,
                                      onDelete: onDelete,
                                      onUpdate: onUpdate,
                                      onFavorite: onFavorite,
                                      onGroup: onGroup,
                                      onKeyboardFocusChanged: onKeyboardFocusChanged)
                        .id(filterRevision)
                        .padding(.bottom, 6)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: search) { _, _ in filtersChanged() }
        .onChange(of: selectedGroups) { _, _ in filtersChanged() }
        .onChange(of: favoritesOnly) { _, _ in filtersChanged() }
        .onChange(of: presets.map(\.id)) { _, ids in
            // If a caller deletes, renames or reloads a catalog while a row is
            // hovered, clear the display-only preview before rows are reused.
            if ids.isEmpty || !ids.contains(where: { visibleIDs.contains($0) }) { endPreview() }
            selectedGroups.formIntersection(Set(groupNames))
        }
        .onDisappear { endPreview(); searchFocused = false }
    }

    private var browserToolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField(L10n.text("app.searchPresets", defaultValue: "Search Presets"), text: $search)
                        .textFieldStyle(.instrument)
                        .focused($searchFocused)
                        .accessibilityLabel(L10n.text("app.searchPresetNames", defaultValue: "Search Preset Names"))
                        .onSubmit { searchFocused = false }
                    if !search.isEmpty {
                        Button {
                            search.removeAll()
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("app.clearPresetSearch", defaultValue: "Clear Preset Search"))
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(Theme.inset)
                .overlay(RoundedRectangle(cornerRadius: Metrics.inputRadius).strokeBorder(Theme.materialEdge, lineWidth: 0.6))

                Button {
                    favoritesOnly.toggle()
                } label: {
                    Image(systemName: favoritesOnly ? "star.fill" : "star")
                }
                .buttonStyle(.key(selected: favoritesOnly, height: 26, padding: 7))
                .help(favoritesOnly ? L10n.text("app.showAllPresets", defaultValue: "Show All Presets") : L10n.text("app.favoritesOnly", defaultValue: "Favorites Only"))
                .accessibilityLabel(favoritesOnly ? L10n.text("app.showAllPresets", defaultValue: "Show All Presets") : L10n.text("app.favoritesOnly", defaultValue: "Favorites Only"))
                .accessibilityValue(favoritesOnly ? L10n.text("app.favoritesFilterOn", defaultValue: "Favorites filter on") : L10n.text("app.favoritesFilterOff", defaultValue: "Favorites filter off"))

                groupFilterMenu
            }
            HStack(spacing: 6) {
                Text(resultSummary).font(.caption11).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 4)
                if !selectedGroups.isEmpty || favoritesOnly || !search.isEmpty {
                    Button(L10n.text("app.clearFilters", defaultValue: "Clear Filters")) { clearFilters() }
                        .buttonStyle(.plain)
                        .font(.caption11)
                        .foregroundStyle(Theme.accentText)
                        .accessibilityLabel(L10n.text("app.clearPresetFilters", defaultValue: "Clear Preset Filters"))
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var groupFilterMenu: some View {
        Menu {
            Button {
                selectedGroups.removeAll()
            } label: { Text(selectedGroups.isEmpty ? L10n.text("app.allGroups", defaultValue: "✓ All Groups") : L10n.text("app.allGroups_1767", defaultValue: "All Groups")) }
            Divider()
            ForEach(groupNames, id: \.self) { group in
                Toggle(isOn: Binding(get: { selectedGroups.contains(group) }, set: { enabled in
                    if enabled { selectedGroups.insert(group) } else { selectedGroups.remove(group) }
                })) {
                    Text(group.isEmpty ? L10n.text("app.ungrouped", defaultValue: "Ungrouped") : group)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .keySurface(height: 26, selected: !selectedGroups.isEmpty)
        .help(groupFilterTitle)
        .accessibilityLabel(L10n.text("app.presetGroupFilter", defaultValue: "Preset Group Filter"))
        .accessibilityValue(groupFilterTitle)
        .disabled(groupNames.isEmpty)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presets.isEmpty ? L10n.text("app.presetsAreSavedInTheCurrentCatalog", defaultValue: "Presets are saved in the current catalog") : L10n.text("app.noMatchingPresets", defaultValue: "No matching presets"))
                .font(.caption11)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }

    private var groupNames: [String] {
        Array(Set(presets.map(\.groupName)))
            .sorted { lhs, rhs in
                if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private var visiblePresets: [AdjustmentPreset] {
        Self.filtered(presets, search: search, groups: selectedGroups, favoritesOnly: favoritesOnly)
    }

    /// Pure filtering helper kept internal for regression tests and for any
    /// future compact preset picker that shares the browser's Unicode rules.
    static func filtered(_ presets: [AdjustmentPreset], search: String,
                         groups: Set<String> = [], favoritesOnly: Bool = false) -> [AdjustmentPreset] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return presets
            .filter { preset in
                let matchesText = query.isEmpty || preset.name.precomposedStringWithCanonicalMapping.lowercased().contains(query)
                let matchesGroup = groups.isEmpty || groups.contains(preset.groupName)
                let matchesFavorite = !favoritesOnly || preset.favorite
                return matchesText && matchesGroup && matchesFavorite
            }
            .sorted { lhs, rhs in
                let lg = lhs.groupName.isEmpty ? "\u{10FFFF}" : lhs.groupName
                let rg = rhs.groupName.isEmpty ? "\u{10FFFF}" : rhs.groupName
                let groupOrder = lg.localizedStandardCompare(rg)
                if groupOrder != .orderedSame { return groupOrder == .orderedAscending }
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
    }

    private var visibleIDs: Set<String> { Set(visiblePresets.map(\.id)) }

    private var groupFilterTitle: String {
        if selectedGroups.isEmpty { return L10n.text("app.allGroups_1767", defaultValue: "All Groups") }
        if selectedGroups.count == 1, let group = selectedGroups.first { return group.isEmpty ? L10n.text("app.ungrouped", defaultValue: "Ungrouped") : group }
        return L10n.text("app.groupsSelected", defaultValue: "\(selectedGroups.count) Groups Selected")
    }

    private var resultSummary: String {
        let total = presets.count
        if total == visiblePresets.count { return L10n.text("app.presets_1773", defaultValue: "\(total) presets") }
        return L10n.text("app.presets_1774", defaultValue: "\(visiblePresets.count) / \(total) presets")
    }

    private func clearFilters() {
        search.removeAll()
        selectedGroups.removeAll()
        favoritesOnly = false
    }

    private func filtersChanged() {
        filterRevision &+= 1
        endPreview()
    }

    private func endPreview() {
        onEndPreview(nil)
        onKeyboardFocusChanged?(false)
    }
}
