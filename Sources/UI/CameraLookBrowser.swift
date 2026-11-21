import SwiftUI
import AppKit

struct CameraLookRow: View {
    let selection: CameraLookSelection?
    let browsing: Bool
    let onBrowse: () -> Void

    @FocusState private var focused: Bool
    private var label: String { L10n.text("cameraLook.label", defaultValue: "Camera Look") }
    private var title: String {
        selection.map { CameraLookLibrary.shared.title(for: $0) }
            ?? L10n.text("cameraLook.default", defaultValue: "Default Rendering")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Metrics.gap) {
                Text(label).frame(width: Metrics.rowLabel, height: Metrics.key, alignment: .leading)
                Button(action: onBrowse) {
                    HStack(spacing: Metrics.gap) {
                        Text(title)
                        Spacer(minLength: 4)
                        Image(systemName: "square.grid.2x2").accessibilityHidden(true)
                    }
                }
                .buttonStyle(.key(selected: browsing, expand: true))
                .focusable()
                .focused($focused)
                .onKeyPress(.return) { onBrowse(); return .handled }
                .accessibilityIdentifier("camera-look-browser")
                .accessibilityLabel(label)
                .accessibilityValue(title)
                .accessibilityAddTraits(browsing ? .isSelected : [])
                .accessibilityHint(L10n.text("cameraLook.browse", defaultValue: "Browse Camera Looks"))
                .help(L10n.text("cameraLook.help", defaultValue: "Choose Default Rendering or a camera look for this RAW photo. Existing exposure, white balance, masks, and other adjustments are preserved."))
            }
            if let selection, CameraLookLibrary.shared.entry(for: selection)?.diagnostic == true {
                Text(L10n.text("cameraLook.diagnosticNote", defaultValue: "Test lookup table for camera-look pipeline verification only, not a calibrated camera profile."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .onChange(of: browsing) { _, open in if !open { focused = true } }
    }
}

struct CameraLookBrowser: View {
    let model: AppModel

    struct Choice: Identifiable, Equatable {
        let selection: CameraLookSelection?
        var id: String { selection.map { "\($0.id)@\($0.version)" } ?? "default" }
        var title: String {
            selection.map { CameraLookLibrary.shared.title(for: $0) }
                ?? L10n.text("cameraLook.default", defaultValue: "Default Rendering")
        }
    }
    enum Focus: Hashable { case done, group(String), tile(String) }
    struct LookGroup: Identifiable {
        let group: CameraLookGroup
        let choices: [Choice]
        let isExpanded: Bool
        var id: String { group.id }
        var visibleChoices: [Choice] { isExpanded ? choices : [] }
    }
    struct Layout {
        let ungrouped: [Choice]
        let groups: [LookGroup]
        let selectedTarget: Focus

        init(sections: [(group: CameraLookGroup, entries: [CameraLookEntry])],
             selection: CameraLookSelection?, collapsed: Set<String>) {
            let groups = sections.map { section in
                LookGroup(group: section.group, choices: section.entries.map { Choice(selection: $0.selection) },
                          isExpanded: !collapsed.contains(section.group.id))
            }
            let selected = Choice(selection: selection)
            let group = groups.first { $0.choices.contains(selected) }
            self.ungrouped = [Choice(selection: nil), Choice(selection: .asShot)] + (selection != nil && selection != .asShot && group == nil ? [selected] : [])
            self.groups = groups
            if let group, !group.isExpanded { self.selectedTarget = .group(group.id) }
            else { self.selectedTarget = .tile(selected.id) }
        }

        var visibleChoices: [Choice] { ungrouped + groups.flatMap(\.visibleChoices) }

        func destination(from current: Focus, key: KeyEquivalent, backwards: Bool = false) -> Focus? {
            let rows = [ungrouped.map { Focus.tile($0.id) }] + groups.flatMap { group in
                let choices = group.visibleChoices
                let tiles = stride(from: 0, to: choices.count, by: 2).map { index in
                    choices[index..<min(index + 2, choices.count)].map { Focus.tile($0.id) }
                }
                return [[Focus.group(group.id)]] + tiles
            }
            if key == .upArrow || key == .downArrow {
                guard let row = rows.firstIndex(where: { $0.contains(current) }),
                      let column = rows[row].firstIndex(of: current) else { return nil }
                let next = row + (key == .upArrow ? -1 : 1)
                if next < 0 { return .done }
                guard rows.indices.contains(next) else { return nil }
                return rows[next][min(column, rows[next].count - 1)]
            }
            let order = rows.flatMap { $0 }
            guard let index = order.firstIndex(of: current) else { return nil }
            let next = index + (key == .leftArrow || backwards ? -1 : 1)
            if next < 0 { return .done }
            return order.indices.contains(next) ? order[next] : nil
        }
    }
    private enum Thumbnail { case image(CGImage), unavailable }
    private struct PreviewRequest: Equatable {
        let source: CameraLookThumbnailSource?
        let choices: [Choice]
    }
    private struct PreviewBatch {
        let source: CameraLookThumbnailSource
        var thumbnails: [String: Thumbnail] = [:]
    }

    private static let sections = CameraLookLibrary.shared.menuSections()
    private static let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: Metrics.gap), count: 2)
    @AppStorage("cameraLookCollapsedGroups") private var storedCollapsedGroups = ""
    @FocusState private var focus: Focus?
    @State private var hovered: String?
    @State private var batch: PreviewBatch?

    var body: some View {
        let source = model.cameraLookThumbnailSource
        let current = source?.selection
        let selected = Choice(selection: current)
        let layout = Layout(sections: Self.sections, selection: current, collapsed: collapsedGroups)
        let request = PreviewRequest(source: source, choices: layout.visibleChoices)
        let thumbnails = batch?.source == source ? batch?.thumbnails ?? [:] : [:]
        VStack(spacing: 0) {
            HStack(spacing: Metrics.gap) {
                Text(L10n.text("cameraLook.label", defaultValue: "Camera Look"))
                    .font(.section).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(L10n.text("app.done", defaultValue: "Done"), action: model.closeCameraLookBrowser)
                    .buttonStyle(.key(height: 22))
                    .focusable()
                    .focused($focus, equals: .done)
                    .onKeyPress(.return) { model.closeCameraLookBrowser(); return .handled }
                    .onKeyPress(.downArrow) { focus = layout.selectedTarget; return .handled }
                    .onKeyPress(keys: [.tab]) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        focus = layout.selectedTarget
                        return .handled
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("camera-look-done")
            }.padding(.horizontal, 12).frame(height: 36)
            Seam()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Metrics.gap) {
                        ForEach(layout.ungrouped) { choice in
                            tile(choice, selected: choice.selection == current, thumbnail: thumbnails[choice.id], layout: layout)
                        }
                        ForEach(layout.groups) { group in
                            Section {
                                if group.isExpanded {
                                    ForEach(group.choices) { choice in
                                        tile(choice, selected: choice.selection == current, thumbnail: thumbnails[choice.id], layout: layout)
                                    }
                                }
                            } header: {
                                groupHeader(group, layout: layout)
                            }
                        }
                    }
                    .padding(Metrics.gap)
                }
                .accessibilityIdentifier("camera-look-scroll")
                .onAppear {
                    if current != nil { proxy.scrollTo(layout.selectedTarget, anchor: .center) }
                    focus = .done
                }
                .onChange(of: focus) { _, value in
                    if let value, value != .done { proxy.scrollTo(value) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera-look-panel")
        .onChange(of: focus) { _, value in model.cameraLookBrowserFocused = value != nil }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in hovered = nil }
        .onDisappear { model.cameraLookBrowserFocused = false; model.endCameraLookPreview() }
        .task(id: request, priority: .utility) { await loadThumbnails(request, selected: selected) }
    }

    private var collapsedGroups: Set<String> {
        Set(storedCollapsedGroups.split(separator: ",").map(String.init))
    }

    private func groupHeader(_ group: LookGroup, layout: Layout) -> some View {
        let title = group.group.displayTitle()
        let count = group.choices.count.formatted()
        let target = Focus.group(group.id)
        return Button { toggleGroup(group) } label: {
            HStack(spacing: 6) {
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 10).accessibilityHidden(true)
                SilkText(title)
                Text("(\(count))").font(.caption11.monospacedDigit())
                Seam().frame(maxWidth: .infinity)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: target)
        .onKeyPress(.return) { toggleGroup(group); return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            if group.isExpanded == (press.key == .leftArrow) { toggleGroup(group) }
            return .handled
        }
        .onKeyPress(keys: [.tab, .upArrow, .downArrow]) { moveFocus(from: target, press: $0, layout: layout) }
        .accessibilityLabel("\(title) (\(count))")
        .accessibilityValue(group.isExpanded ? L10n.text("app.expanded", defaultValue: "Expanded") : L10n.text("app.collapsed", defaultValue: "Collapsed"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("camera-look-group-\(group.id)")
        .id(target)
    }

    private func toggleGroup(_ group: LookGroup) {
        focus = .group(group.id)
        var collapsed = collapsedGroups
        if group.isExpanded {
            collapsed.insert(group.id)
            if let hovered, group.choices.contains(where: { $0.id == hovered }) { endHover(hovered) }
        } else {
            collapsed.remove(group.id)
        }
        storedCollapsedGroups = collapsed.sorted().joined(separator: ",")
    }

    private func tile(_ choice: Choice, selected: Bool, thumbnail: Thumbnail?, layout: Layout) -> some View {
        let id = choice.id
        let target = Focus.tile(id)
        let isFocused = focus == target
        let title = choice.title
        let apply = { model.selectCameraLook(choice.selection) }
        return Button(action: apply) {
            VStack(spacing: 0) {
                PhotoMat.dark.color.aspectRatio(4.0 / 3, contentMode: .fit)
                    .overlay {
                        switch thumbnail {
                        case let .image(image):
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                        case .unavailable:
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(nsColor: PhotoMat.dark.textSecondary))
                        case nil:
                            Image(systemName: "photo").foregroundStyle(Color(nsColor: PhotoMat.dark.textSecondary))
                        }
                    }
                    .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(title).lineLimit(2).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.caption11.weight(.semibold)) }
                }
                .padding(.horizontal, 6).frame(height: 32)
                .font(.caption11.weight(selected ? .semibold : .regular))
                .background(selected ? Theme.selected : hovered == id ? Theme.raised : Theme.inset)
            }
            .contentShape(Rectangle())
            .overlay {
                Rectangle().strokeBorder(isFocused ? Theme.focusRing : selected ? Theme.accentSignal : Theme.controlBorder,
                                         lineWidth: isFocused ? 2 : 1).allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: target)
        .onKeyPress(.return) { apply(); return .handled }
        .onKeyPress(keys: [.tab, .leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            moveFocus(from: target, press: press, layout: layout)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("camera-look-choice-" + id)
        .help(tileHelp(title, thumbnail: thumbnail))
        .id(target)
        .onHover { inside in
            if inside { hovered = id; model.previewCameraLook(choice.selection) }
            else { endHover(id) }
        }
        .onDisappear { endHover(id) }
    }

    private func moveFocus(from target: Focus, press: KeyPress, layout: Layout) -> KeyPress.Result {
        guard let destination = layout.destination(from: target, key: press.key, backwards: press.modifiers.contains(.shift) && press.key == .tab)
        else { return press.key == .tab ? .ignored : .handled }
        focus = destination
        return .handled
    }

    private func tileHelp(_ title: String, thumbnail: Thumbnail?) -> String {
        if case .unavailable = thumbnail {
            return title + " · " + L10n.text("cameraLook.previewUnavailable", defaultValue: "Preview unavailable")
        }
        return title
    }

    private func endHover(_ id: String) {
        guard hovered == id else { return }
        hovered = nil
        model.endCameraLookPreview()
    }

    private func loadThumbnails(_ request: PreviewRequest, selected: Choice) async {
        guard !Task.isCancelled, let source = request.source else { return }
        if batch?.source != source { batch = PreviewBatch(source: source) }
        let choices = request.choices
        let start = max(0, (choices.firstIndex { $0.id == selected.id } ?? 0) - 4)
        for choice in choices[start...] + choices[..<start] {
            guard !Task.isCancelled else { return }
            if batch?.thumbnails[choice.id] != nil { continue }
            let thumbnail: Thumbnail
            do {
                let frame = try await ImagePipeline.cameraLookThumbnails.renderInteractive(source.request(for: choice.selection), longEdge: 256)
                thumbnail = .image(frame.image)
            } catch {
                thumbnail = .unavailable
            }
            guard !Task.isCancelled, batch?.source == source else { return }
            batch?.thumbnails[choice.id] = thumbnail
        }
    }
}
