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

    private struct Choice: Identifiable {
        let selection: CameraLookSelection?
        var id: String { selection.map { "\($0.id)@\($0.version)" } ?? "default" }
        var title: String {
            selection.map { CameraLookLibrary.shared.title(for: $0) }
                ?? L10n.text("cameraLook.default", defaultValue: "Default Rendering")
        }
    }
    private enum Focus: Hashable { case done, tile(String) }
    private enum Thumbnail { case image(CGImage), unavailable }
    private struct PreviewKey: Equatable {
        let source: CameraLookThumbnailSource?
        let unlisted: CameraLookSelection?
    }
    private struct PreviewBatch {
        let key: PreviewKey
        var thumbnails: [String: Thumbnail] = [:]
    }

    private static let defaults = Choice(selection: nil)
    private static let sections = CameraLookLibrary.shared.menuSections()
    private static let choices = [defaults] + sections.flatMap { $0.entries.map { Choice(selection: $0.selection) } }
    private static let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: Metrics.gap), count: 2)
    @FocusState private var focus: Focus?
    @State private var hovered: String?
    @State private var batch: PreviewBatch?

    var body: some View {
        let source = model.cameraLookThumbnailSource
        let current = source?.selection
        let selected = Choice(selection: current)
        let unlisted = Self.choices.contains(where: { $0.selection == current }) ? nil : current
        let key = PreviewKey(source: source, unlisted: unlisted)
        let order = Self.choices(including: unlisted)
        let thumbnails = batch?.key == key ? batch?.thumbnails ?? [:] : [:]
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
                    .onKeyPress(.downArrow) { focus = .tile(selected.id); return .handled }
                    .onKeyPress(keys: [.tab]) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        focus = .tile(selected.id)
                        return .handled
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("camera-look-done")
            }.padding(.horizontal, 12).frame(height: 36)
            Seam()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Metrics.gap) {
                        tile(Self.defaults, selected: current == nil, thumbnail: thumbnails[Self.defaults.id], order: order)
                        if let unlisted {
                            let choice = Choice(selection: unlisted)
                            tile(choice, selected: true, thumbnail: thumbnails[choice.id], order: order)
                        }
                        ForEach(Self.sections, id: \.group.id) { section in
                            Section {
                                ForEach(section.entries) { entry in
                                    let choice = Choice(selection: entry.selection)
                                    tile(choice, selected: entry.selection == current, thumbnail: thumbnails[choice.id], order: order)
                                }
                            } header: {
                                SubgroupLabel(section.group.displayTitle())
                            }
                        }
                    }
                    .padding(Metrics.gap)
                }
                .accessibilityIdentifier("camera-look-scroll")
                .onAppear {
                    if current != nil { proxy.scrollTo(selected.id, anchor: .center) }
                    focus = .done
                }
                .onChange(of: focus) { _, value in
                    if case let .tile(id) = value { proxy.scrollTo(id) }
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
        .task(id: key, priority: .utility) { await loadThumbnails(key, selected: selected) }
    }

    private func tile(_ choice: Choice, selected: Bool, thumbnail: Thumbnail?, order: [Choice]) -> some View {
        let id = choice.id
        let isFocused = focus == .tile(id)
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
        .focused($focus, equals: .tile(id))
        .onKeyPress(.return) { apply(); return .handled }
        .onKeyPress(keys: [.tab, .leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            moveFocus(from: id, press: press, order: order)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("camera-look-choice-" + id)
        .help(tileHelp(title, thumbnail: thumbnail))
        .id(id)
        .onHover { inside in
            if inside { hovered = id; model.previewCameraLook(choice.selection) }
            else { endHover(id) }
        }
        .onDisappear { endHover(id) }
    }

    private func moveFocus(from id: String, press: KeyPress, order: [Choice]) -> KeyPress.Result {
        guard let index = order.firstIndex(where: { $0.id == id }) else { return .ignored }
        let offset: Int
        switch press.key {
        case .tab: offset = press.modifiers.contains(.shift) ? -1 : 1
        case .leftArrow: offset = -1
        case .rightArrow: offset = 1
        case .upArrow: offset = -2
        case .downArrow: offset = 2
        default: return .ignored
        }
        let next = index + offset
        if next < 0 { focus = .done; return .handled }
        if next >= order.count { return press.key == .tab ? .ignored : .handled }
        focus = .tile(order[next].id)
        return .handled
    }

    private static func choices(including unlisted: CameraLookSelection?) -> [Choice] {
        guard let unlisted else { return choices }
        var all = choices
        all.insert(Choice(selection: unlisted), at: 1)
        return all
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

    private func loadThumbnails(_ key: PreviewKey, selected: Choice) async {
        guard !Task.isCancelled, let source = key.source else { return }
        batch = PreviewBatch(key: key)
        let choices = Self.choices(including: key.unlisted)
        let start = max(0, (choices.firstIndex { $0.id == selected.id } ?? 0) - 4)
        for choice in choices[start...] + choices[..<start] {
            guard !Task.isCancelled else { return }
            let thumbnail: Thumbnail
            do {
                let frame = try await ImagePipeline.cameraLookThumbnails.renderInteractive(source.request(for: choice.selection), longEdge: 256)
                thumbnail = .image(frame.image)
            } catch {
                thumbnail = .unavailable
            }
            guard !Task.isCancelled, batch?.key == key else { return }
            batch?.thumbnails[choice.id] = thumbnail
        }
    }
}
