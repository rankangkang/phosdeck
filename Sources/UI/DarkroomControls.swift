import SwiftUI
import AppKit

/// Broad, quiet light on the moulded enclosure; never applied to a photo or its viewing mat.
struct InstrumentPlate: View {
    var body: some View {
        LinearGradient(colors: [Theme.plateTop, Theme.panel, Theme.plateBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Engraved seam between plate regions: a separator line followed by a light line, one physical pixel each.
struct Seam: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var scale
    var body: some View {
        let pixel = 1 / max(1, scale)
        if axis == .horizontal {
            VStack(spacing: 0) { Theme.separator.frame(height: pixel); Theme.seamLight.frame(height: pixel) }
                .accessibilityHidden(true)
        } else {
            HStack(spacing: 0) { Theme.separator.frame(width: pixel); Theme.seamLight.frame(width: pixel) }
                .accessibilityHidden(true)
        }
    }
}

/// Where a key sits in a joined row; only the outer corners of a row are rounded.
enum KeyPosition {
    case single, leading, middle, trailing
    init(index: Int, count: Int) {
        self = count == 1 ? .single : index == 0 ? .leading : index == count - 1 ? .trailing : .middle
    }
    func shape(radius: CGFloat = Metrics.keyRadius) -> UnevenRoundedRectangle {
        let leading: CGFloat = self == .single || self == .leading ? radius : 0
        let trailing: CGFloat = self == .single || self == .trailing ? radius : 0
        return UnevenRoundedRectangle(topLeadingRadius: leading, bottomLeadingRadius: leading,
                                      bottomTrailingRadius: trailing, topTrailingRadius: trailing)
    }
}

/// Key travel, as on a latching push-button panel: raised at rest, latched lower while its state is on,
/// and bottomed out only while a finger holds it. Releasing a latched key returns it to the latched position.
enum KeyTravel: Equatable {
    case raised, latched, held, limited(selected: Bool)
    init(pressed: Bool, selected: Bool, enabled: Bool = true) {
        self = pressed ? (enabled ? .held : .limited(selected: selected)) : (selected ? .latched : .raised)
    }
    /// Visible cap lip under the face. The face sinks by exactly what the lip loses, so travel reads as depth.
    func lip(height: CGFloat) -> CGFloat {
        let full: CGFloat = height >= 22 ? 1.25 : 0.75
        switch self {
        case .raised: return full
        case .latched: return full / 4
        case .held: return 0
        case .limited(let selected): return full * (selected ? 0.25 : 1) * 0.6
        }
    }
    /// Keeps a label centred on the face rather than on the whole cap.
    func labelOffset(height: CGFloat) -> CGFloat { -lip(height: height) / 2 }
}

/// Receives only pointer pressure on an unavailable key; the semantic button stays disabled.
private struct LockedKeyFeedback: NSViewRepresentable {
    @Binding var pressed: Bool
    func makeNSView(context: Context) -> LockedKeyFeedbackView { LockedKeyFeedbackView() }
    func updateNSView(_ view: LockedKeyFeedbackView, context: Context) { view.onPress = { pressed = $0 } }
}

final class LockedKeyFeedbackView: NSView {
    var onPress: (Bool) -> Void = { _ in }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func mouseDown(with event: NSEvent) { onPress(true) }
    override func mouseDragged(with event: NSEvent) { onPress(bounds.contains(convert(event.locationInWindow, from: nil))) }
    override func mouseUp(with event: NSEvent) { onPress(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(cancelPress), name: NSWindow.didResignKeyNotification, object: window)
        }
    }
    @objc private func cancelPress() { onPress(false) }
    deinit { NotificationCenter.default.removeObserver(self) }
}

/// Key cap for each travel position: a face sitting on a lip that shows the cap's thickness.
/// Disabled keys retain their travel and material, with quieter face lighting and shadows.
struct KeySurface: View {
    var position: KeyPosition = .single
    var radius: CGFloat = Metrics.keyRadius
    var height: CGFloat = Metrics.key
    var pressed = false
    var selected = false
    var enabled = true
    var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let shape = position.shape(radius: radius)
        let travel = KeyTravel(pressed: pressed, selected: selected, enabled: enabled)
        shape.fill(selected ? Theme.keyLipSelected : Theme.keyLip)
            .overlay(alignment: .top) {
                face(travel)
                    .overlay(enabled ? nil : shape.fill(Theme.panel.opacity(0.45)))
                    .padding(.bottom, travel.lip(height: height))
            }
            .overlay(shape.strokeBorder(contrast == .increased ? Theme.controlBorder : Theme.materialEdge, lineWidth: contrast == .increased ? 1 : 0.5))
            .shadow(color: travel == .held ? .clear : Theme.keyContactShadow.opacity(enabled ? 1 : 0.45), radius: 0.6, y: travel == .raised ? 0.8 : 0.25)
            .shadow(color: travel == .raised ? Theme.keyAmbientShadow.opacity(enabled ? 1 : 0.45) : .clear, radius: 2.5, y: 2)
    }
    @ViewBuilder private func face(_ travel: KeyTravel) -> some View {
        let shape = position.shape(radius: radius)
        switch travel {
        case .raised, .limited(selected: false):
            shape.fill(LinearGradient(colors: hovering && enabled ? [Theme.raised, Theme.keyTop] : [Theme.keyTop, Theme.keyBottom],
                                      startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.keyHighlight).frame(height: 0.5).padding(.horizontal, radius)
                }
        case .latched, .limited(selected: true):
            shape.fill(LinearGradient(colors: [Theme.selected, Theme.keyBottom], startPoint: .top, endPoint: .bottom)
                .shadow(.inner(color: Theme.insetShadow, radius: 2, y: 2)))
                .overlay(hovering && enabled ? shape.fill(Theme.keyHighlight.opacity(0.15)) : nil)
        case .held:
            shape.fill((selected ? Theme.selected : Theme.keyHeld).shadow(.inner(color: Theme.insetShadow, radius: 2.5, y: 1.5)))
                .overlay(selected ? shape.fill(Theme.insetShadow.opacity(0.5)) : nil)
        }
    }
}

struct KeyButtonStyle: ButtonStyle {
    var selected = false
    var position: KeyPosition = .single
    var height: CGFloat = Metrics.key
    var padding: CGFloat = 10
    var radius: CGFloat = Metrics.keyRadius
    var multiline = false
    var onPress: ((Bool) -> Void)?
    func makeBody(configuration: Configuration) -> some View { KeyButtonBody(configuration: configuration, style: self) }
}

/// A momentary eye key. Pointer events are captured separately from the
/// semantic Button action, so releasing a held pointer never starts a second
/// pulse. Keyboard and VoiceOver activation use `onPulse`; dragging out,
/// releasing, or losing the window always sends `onPress(false)`.
struct MomentaryPreviewKey: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let height: CGFloat
    let onPress: (Bool) -> Void
    let onPulse: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: onPulse) {
            Image(systemName: systemImage)
        }
        .buttonStyle(KeyButtonStyle(selected: selected, height: height, padding: 5))
        .overlay {
            MomentaryPreviewCapture(onPress: onPress, enabled: enabled).accessibilityHidden(true)
        }
        .accessibilityLabel(title)
        .accessibilityValue(selected ? L10n.text("app.temporarilyDisableThisGroupReleaseToRestore", defaultValue: "Temporarily disable this group; release to restore") : L10n.text("app.holdToTemporarilyDisableThisGroup", defaultValue: "Hold to Temporarily Disable This Group"))
        .accessibilityAction { onPulse() }
        .help(L10n.text("app.holdToPreviewWithoutThisGroupReleaseToRestore", defaultValue: "Hold to preview without this group; release to restore. History and exports are preserved"))
    }
}

private struct MomentaryPreviewCapture: NSViewRepresentable {
    let onPress: (Bool) -> Void
    let enabled: Bool

    func makeNSView(context: Context) -> MomentaryPreviewCaptureView {
        let view = MomentaryPreviewCaptureView()
        view.onPress = onPress
        view.enabled = enabled
        return view
    }

    func updateNSView(_ view: MomentaryPreviewCaptureView, context: Context) {
        view.onPress = onPress
        view.enabled = enabled
    }
}

private final class MomentaryPreviewCaptureView: NSView {
    var onPress: (Bool) -> Void = { _ in }
    var enabled = true {
        didSet { if !enabled { cancelPress() } }
    }
    private var active = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        active = true
        onPress(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != active else { return }
        active = inside
        onPress(inside)
    }

    override func mouseUp(with event: NSEvent) {
        active = false
        onPress(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { cancelPress(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(cancelPress),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func cancelPress() {
        guard active else { return }
        active = false
        onPress(false)
    }

    deinit {
        if active { onPress(false) }
        NotificationCenter.default.removeObserver(self)
    }
}

private struct KeyButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: KeyButtonStyle
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var lockedPressed = false
    var body: some View {
        let pressed = configuration.isPressed || (!enabled && lockedPressed)
        let travel = KeyTravel(pressed: pressed, selected: style.selected, enabled: enabled)
        configuration.label
            .offset(y: !reduceMotion ? travel.labelOffset(height: style.height) : 0)
            .font(.system(size: 12, weight: style.selected ? .semibold : .regular))
            .foregroundStyle(enabled ? (configuration.role == .destructive ? Theme.error : Theme.text) : Theme.textDisabled)
            .lineLimit(style.multiline ? nil : 1)
            .fixedSize(horizontal: false, vertical: style.multiline)
            .padding(.horizontal, style.padding)
            .frame(minWidth: style.height, minHeight: style.height, maxHeight: style.multiline ? nil : style.height)
            .background(KeySurface(position: style.position, radius: style.radius, height: style.height, pressed: pressed,
                                   selected: style.selected, enabled: enabled, hovering: hovering))
            .overlay {
                if !enabled { LockedKeyFeedback(pressed: $lockedPressed).environment(\.isEnabled, true).accessibilityHidden(true) }
            }
            .overlay {
                if focused && enabled { style.position.shape(radius: style.radius).stroke(Theme.focusRing, lineWidth: 2).padding(-2).allowsHitTesting(false) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onChange(of: configuration.isPressed) { _, pressed in if enabled { style.onPress?(pressed) } }
            .onChange(of: enabled) { _, _ in lockedPressed = false; if !enabled { style.onPress?(false) } }
            .onDisappear { lockedPressed = false; style.onPress?(false) }
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.08 : 0.12), value: travel)
    }
}

extension ButtonStyle where Self == KeyButtonStyle {
    static var key: KeyButtonStyle { KeyButtonStyle() }
    static func key(selected: Bool = false, position: KeyPosition = .single, height: CGFloat = Metrics.key, padding: CGFloat = 10) -> KeyButtonStyle {
        KeyButtonStyle(selected: selected, position: position, height: height, padding: padding)
    }
    /// Square icon key.
    static var iconKey: KeyButtonStyle { KeyButtonStyle(padding: 0) }
}

/// The single signal-orange primary key of a view.
struct PrimaryKeyStyle: ButtonStyle {
    var height: CGFloat = Metrics.key
    func makeBody(configuration: Configuration) -> some View { PrimaryKeyBody(configuration: configuration, height: height) }
}

private struct PrimaryKeyBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lockedPressed = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.keyRadius)
        let pressed = configuration.isPressed || (!enabled && lockedPressed)
        let travel = KeyTravel(pressed: pressed, selected: false, enabled: enabled)
        let lip = travel.lip(height: height)
        configuration.label
            .offset(y: !reduceMotion ? travel.labelOffset(height: height) : 0)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? Theme.keyPrimaryText : Theme.textDisabled)
            .padding(.horizontal, 14).frame(height: height)
            .background {
                if enabled {
                    shape.fill(Theme.keyPrimaryLip)
                        .overlay(alignment: .top) {
                            Group {
                                if travel == .held {
                                    shape.fill(Theme.keyPrimaryBottom.shadow(.inner(color: .black.opacity(0.3), radius: 2, y: 1.5)))
                                } else {
                                    shape.fill(LinearGradient(colors: [Theme.keyPrimaryTop, Theme.keyPrimaryBottom], startPoint: .top, endPoint: .bottom))
                                        .overlay(alignment: .top) {
                                            Rectangle().fill(.white.opacity(0.55)).frame(height: 0.5).padding(.horizontal, Metrics.keyRadius)
                                        }
                                }
                            }.padding(.bottom, lip)
                        }
                        .overlay(shape.strokeBorder(Theme.keyPrimaryEdge, lineWidth: 1))
                        .shadow(color: travel == .held ? .clear : Theme.keyContactShadow, radius: 0.6, y: 0.8)
                        .shadow(color: travel == .held ? .clear : Theme.keyAmbientShadow, radius: 2.5, y: 2)
                } else {
                    KeySurface(height: height, pressed: pressed, enabled: false)
                }
            }
            .overlay {
                if !enabled { LockedKeyFeedback(pressed: $lockedPressed).environment(\.isEnabled, true).accessibilityHidden(true) }
            }
            .overlay { if focused && enabled { shape.stroke(Theme.focusRing, lineWidth: 2).padding(-2).allowsHitTesting(false) } }
            .contentShape(Rectangle())
            .onChange(of: enabled) { _, _ in lockedPressed = false }
            .onDisappear { lockedPressed = false }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: travel)
    }
}

/// A 6 pt indicator lamp, always seated in its socket ring and always next to text or a key.
struct Lamp: View {
    var on: Bool
    var onScope = false
    var body: some View {
        Circle().fill(onScope ? Theme.scopeBezel : Theme.inset)
            .overlay {
                Circle().fill(on ? AnyShapeStyle(RadialGradient(colors: [Theme.lampSpecular, Theme.lampOn], center: .top,
                                                                 startRadius: 0, endRadius: 4))
                                : AnyShapeStyle(onScope ? Theme.scopeLampOff : Theme.lampOff))
                    .overlay(Circle().strokeBorder(Theme.lampSocket.opacity(0.45), lineWidth: 0.5))
                    .padding(1)
            }
            .overlay(Circle().strokeBorder(onScope ? Theme.scopeBezel : Theme.keyHighlight, lineWidth: 0.6))
            .shadow(color: onScope ? .clear : Theme.insetShadow, radius: 0.6, y: -0.5)
            .frame(width: Metrics.lamp, height: Metrics.lamp)
            .accessibilityHidden(true)
    }
}

/// Lamp seated on the key face before its label, for bars too shallow for a lamp row under the keys.
struct LampLabel<Content: View>: View {
    var on: Bool
    @ViewBuilder var content: Content
    var body: some View { HStack(spacing: 5) { Lamp(on: on); content } }
}

struct KeyOption<Value: Hashable> {
    let value: Value
    let title: String
    var help: String?
    var icon: String?
    var identifier: String?
    var enabled = true
    init(_ value: Value, _ title: String, help: String? = nil, icon: String? = nil, identifier: String? = nil, enabled: Bool = true) {
        self.value = value; self.title = title; self.help = help; self.icon = icon; self.identifier = identifier; self.enabled = enabled
    }
}

extension VerticalAlignment {
    private enum KeyCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    /// Centre of the keys in a row, ignoring the lamp row under them, so lamped and plain keys line up.
    static let keyCenter = VerticalAlignment(KeyCenter.self)
}

extension View {
    /// Lamp under a key; lit while that key is the latched option of its group.
    func keyLamp(_ on: Bool, drop: CGFloat = Metrics.lampDrop) -> some View {
        overlay(alignment: .bottom) { Lamp(on: on).offset(y: drop) }
    }
    /// Reserves the lamp row under a group of lamped keys and keeps the group aligned on its keys.
    func lampRow(drop: CGFloat = Metrics.lampDrop) -> some View {
        padding(.bottom, drop).alignmentGuide(.keyCenter) { ($0.height - drop) / 2 }
    }
}

/// Interlocked joined keys: the chosen key stays latched in, bold, with its lamp lit; choosing another releases it.
struct KeyRow<Value: Hashable>: View {
    let title: String
    let options: [KeyOption<Value>]
    @Binding var selection: Value
    var lamps = true
    /// Seats each lamp on its key face instead of in a row below the keys.
    var lampsInside = false
    var expand = false
    var height: CGFloat = Metrics.key
    var lampDrop: CGFloat = Metrics.lampDrop
    var padding: CGFloat = 10
    /// Keep long option names intact, using extra rows only when necessary.
    var wrappingColumns: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Group {
            if let columns = wrappingColumns, columns > 0 {
                ViewThatFits(in: .horizontal) {
                    keys(options.indices, preserveLabels: true)
                    VStack(spacing: Metrics.gap) {
                        ForEach(Array(stride(from: 0, to: options.count, by: columns)), id: \.self) { start in
                            keys(start..<min(start + columns, options.count), preserveLabels: true)
                        }
                    }
                }
            } else {
                keys(options.indices)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
    }
    private func keys(_ indices: Range<Int>, preserveLabels: Bool = false) -> some View {
        let lampsBelow = lamps && !lampsInside
        return HStack(spacing: 1) {
            ForEach(indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                let minimumLabelWidth: CGFloat? = preserveLabels
                    ? (option.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
                    : nil
                Button { selection = option.value } label: {
                    Group {
                        let content = Group { if let icon = option.icon { Image(systemName: icon) } else { Text(option.title) } }
                        if lamps && lampsInside { LampLabel(on: selected) { content } } else { content }
                    }.fixedSize(horizontal: preserveLabels, vertical: false)
                        .frame(maxWidth: expand ? .infinity : nil)
                }
                .buttonStyle(.key(selected: selected, position: KeyPosition(index: index - indices.lowerBound, count: indices.count), height: height, padding: padding))
                .frame(minWidth: minimumLabelWidth.map { $0 + 2 * padding })
                .disabled(!option.enabled)
                .overlay(alignment: .bottom) { if lampsBelow { Lamp(on: selected).offset(y: lampDrop) } }
                .help(option.help ?? option.title)
                .accessibilityLabel(option.title)
                .accessibilityIdentifier(option.identifier ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.lampRow(drop: lampsBelow ? lampDrop : 0)
    }
    private func move(_ offset: Int) -> KeyPress.Result {
        guard enabled else { return .ignored }
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        var next = index + offset
        while options.indices.contains(next), !options[next].enabled { next += offset }
        guard options.indices.contains(next) else { return .handled }
        selection = options[next].value
        return .handled
    }
}

/// Background for a menu or other non-button content that must look like a joined key.
extension View {
    func keySurface(position: KeyPosition = .single, height: CGFloat = Metrics.key, selected: Bool = false, enabled: Bool = true) -> some View {
        offset(y: KeyTravel(pressed: false, selected: selected).labelOffset(height: height))
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(enabled ? Theme.text : Theme.textDisabled).tint(enabled ? Theme.text : Theme.textDisabled)
            .padding(.horizontal, 8).frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(KeySurface(position: position, height: height, selected: selected, enabled: enabled))
    }
}

/// List and tree row: selected rows use surface.selected plus a 2 pt signal bar on the leading edge.
struct ListRowLabel: View {
    let title: String
    var detail: String?
    var icon: String?
    var selected = false
    var height: CGFloat = 24
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).frame(width: 14) }
            Text(title).lineLimit(1).truncationMode(.middle)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(enabled ? Theme.text : Theme.textDisabled)
            Spacer(minLength: 4)
            if let detail { Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
        .padding(.horizontal, 12).frame(height: height).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.selected : .clear)
        .overlay(alignment: .leading) { if selected { Theme.accentSignal.frame(width: 2) } }
        .contentShape(Rectangle())
    }
}

/// 16 pt square latching key with a lamp: enable / bypass for a panel or local adjustment. Separate from disclosure.
struct LampSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: { Lamp(on: isOn) }
            .buttonStyle(KeyButtonStyle(selected: isOn, height: 16, padding: 0, radius: 2))
            .frame(width: 16, height: 16)
            .help(isOn ? L10n.text("app.enabledClickToDisable", defaultValue: "\(title): enabled; click to disable") : L10n.text("app.disabledClickToEnable", defaultValue: "\(title): disabled; click to enable"))
            .accessibilityRepresentation { Toggle(title, isOn: $isOn).toggleStyle(.checkbox) }
    }
}

/// General form inputs share the same well; parameter readouts keep their frameless editor.
struct InstrumentTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View { InstrumentField(content: configuration) }
}

private struct InstrumentField<Content: View>: View {
    let content: Content
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Bool
    var body: some View {
        content.textFieldStyle(.plain).focused($focused)
            .foregroundStyle(enabled ? Theme.text : Theme.textDisabled)
            .padding(.horizontal, 7).padding(.vertical, 4).frame(minHeight: 24)
            .background(Theme.raised.shadow(.inner(color: Theme.insetShadow.opacity(0.5), radius: 2, y: 1)), in: RoundedRectangle(cornerRadius: Metrics.inputRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.inputRadius)
                    .strokeBorder(focused ? Theme.focusRing : enabled ? (contrast == .increased ? Theme.controlBorder : Theme.materialEdge) : Theme.textDisabled, lineWidth: focused ? 2 : 0.75)
                    .allowsHitTesting(false)
            }
    }
}

extension TextFieldStyle where Self == InstrumentTextFieldStyle {
    static var instrument: InstrumentTextFieldStyle { InstrumentTextFieldStyle() }
}

extension View {
    /// Applies only to app-owned content; native sheets, pickers and menus retain their platform behaviour.
    func instrumentForm() -> some View {
        font(.body13).foregroundStyle(Theme.text).buttonStyle(.key).textFieldStyle(.instrument)
            .toggleStyle(.latchingKey)
            .controlSize(.small).tint(Theme.accentText).background(InstrumentPlate())
    }
}

/// Panel group with a silk title line: `▼ Title ———— [modified] [eye] ↺`.
/// The eye is a press-and-hold, display-only preview hook.  It deliberately
/// lives beside the title so every parameter group can share the same gesture
/// and accessibility wording without adding an enable flag to the recipe.
struct PanelSection<Accessory: View, Content: View>: View {
    let title: String
    var group: DevelopGroup?
    @Binding var isExpanded: Bool
    var reset: (() -> Void)?
    var modified = false
    var previewing = false
    var preview: ((Bool) -> Void)?
    var previewPulse: (() -> Void)?
    let accessory: Accessory
    private let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func pulsePreview(_ preview: ((Bool) -> Void)?) {
        guard let preview else { return }
        if let previewPulse {
            previewPulse()
            return
        }
        // The owner owns the pulse lifetime (normally AppModel's 1.2-second
        // pulse). Keep a semantic activation useful if an older call site has
        // not supplied it yet, without starting a competing local timer.
        preview(true)
        preview(false)
    }
    init(_ title: String, group: DevelopGroup? = nil, isExpanded: Binding<Bool>, reset: (() -> Void)? = nil,
         modified: Bool = false, previewing: Bool = false, preview: ((Bool) -> Void)? = nil,
         previewPulse: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.group = group; self._isExpanded = isExpanded; self.reset = reset
        self.modified = modified; self.previewing = previewing; self.preview = preview; self.previewPulse = previewPulse
        self.accessory = accessory(); self.content = content
    }
    var body: some View {
        VStack(spacing: 0) {
            if let group {
                Color.clear.frame(width: 0, height: 0).id("develop-group-\(group.rawValue)")
            }
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 10)
                        Text(title).font(.section).foregroundStyle(Theme.textSecondary).fixedSize()
                        Seam().frame(maxWidth: .infinity)
                    }.frame(maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title).accessibilityValue(isExpanded ? L10n.text("app.expanded", defaultValue: "Expanded") : L10n.text("app.collapsed", defaultValue: "Collapsed"))
                if modified {
                    Lamp(on: true).accessibilityLabel(L10n.text("app.modified", defaultValue: "Modified"))
                }
                if let preview {
                    MomentaryPreviewKey(title: L10n.text("app.preview", defaultValue: "Preview \(title)"),
                                        systemImage: previewing ? "eye.slash" : "eye",
                                        selected: previewing, height: 22,
                                        onPress: preview,
                                        onPulse: { pulsePreview(preview) })
                }
                accessory
                if let reset {
                    Button(action: reset) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .medium))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .help(L10n.text("app.reset", defaultValue: "Reset \(title)")).accessibilityLabel(L10n.text("app.reset", defaultValue: "Reset \(title)"))
                }
            }
            .padding(.horizontal, 12).frame(height: Metrics.sectionHeader)
            if isExpanded { content() }
            Seam()
        }
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: String, group: DevelopGroup? = nil, isExpanded: Binding<Bool>, reset: (() -> Void)? = nil,
         modified: Bool = false, previewing: Bool = false, preview: ((Bool) -> Void)? = nil,
         previewPulse: (() -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title, group: group, isExpanded: isExpanded, reset: reset, modified: modified,
                  previewing: previewing, preview: preview, previewPulse: previewPulse,
                  accessory: { EmptyView() }, content: content)
    }
}

/// Fixed panel title (no disclosure) with the same silk line.
struct PanelTitle<Accessory: View>: View {
    let title: String
    let accessory: Accessory
    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title; self.accessory = accessory()
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.section).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle).help(title)
            Seam().frame(maxWidth: .infinity)
            accessory
        }.padding(.horizontal, 12).frame(height: Metrics.sectionHeader)
    }
}

/// Sub-group label inside a panel (white balance, tone, presence).
struct SubgroupLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 8) {
            SilkText(title).foregroundStyle(Theme.textSecondary).fixedSize()
            Seam()
        }.frame(height: 24).accessibilityAddTraits(.isHeader)
    }
}

/// Recessed data display. Shows only measured data.
struct ScopeDisplay<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.scopeRadius)
        content
            .background(Theme.scopeBackground)
            .clipShape(shape)
            .overlay {
                shape.stroke(Color.black.opacity(0.7), lineWidth: 3).blur(radius: 1.5).clipShape(shape).allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(Theme.scopeBezel, lineWidth: 1))
            .padding(3)
            .background {
                RoundedRectangle(cornerRadius: Metrics.scopeRadius + 3)
                    .fill(LinearGradient(colors: [Theme.knobRimTop, Theme.seamLight], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.scopeRadius + 3).strokeBorder(Theme.materialEdge, lineWidth: 0.5))
            }
    }
}

/// Twenty segments lit in proportion to real task progress.
struct SegmentMeter: View {
    let done: Int
    let total: Int
    var body: some View {
        let lit = total > 0 ? min(20, Int(Double(done) / Double(total) * 20)) : 0
        HStack(spacing: 2) {
            ForEach(0..<20, id: \.self) { index in
                Rectangle().fill(index < lit ? Theme.accentSignal : Theme.separator).frame(width: 4, height: 8)
            }
        }
        .accessibilityElement().accessibilityLabel(L10n.text("app.taskProgress", defaultValue: "Task Progress")).accessibilityValue("\(done) / \(total)")
    }
}

enum TaskStatusText {
    static func title(_ state: String) -> String {
        ["planned": L10n.text("app.pending", defaultValue: "Pending"), "running": L10n.text("app.processing", defaultValue: "Processing"), "rendering": L10n.text("app.developing", defaultValue: "Developing"), "completed": L10n.text("app.complete", defaultValue: "Complete"),
         "cancelled": L10n.text("app.cancelled", defaultValue: "Cancelled"), "failed": L10n.text("app.failed", defaultValue: "Failed"), "needsReview": L10n.text("app.needsReview", defaultValue: "Needs Review"),
         "skippedVerified": L10n.text("app.verifiedAndReused", defaultValue: "Verified and Reused"), "skippedConflict": L10n.text("app.conflictSkipped", defaultValue: "Conflict Skipped")][state] ?? state
    }
}

/// Silk bracket ⊔ with a notch pointing at the display or parameter its keys control.
struct Bracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let line = rect.minY + 6
        path.move(to: CGPoint(x: rect.minX + 0.5, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + 0.5, y: line))
        path.addLine(to: CGPoint(x: rect.midX - 5, y: line))
        path.addLine(to: CGPoint(x: rect.midX, y: line + 5))
        path.addLine(to: CGPoint(x: rect.midX + 5, y: line))
        path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: line))
        path.addLine(to: CGPoint(x: rect.maxX - 0.5, y: rect.minY))
        return path
    }
}

struct DetentLabelLayout: OptionSet {
    let rawValue: Int
    static let top = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let left = Self(rawValue: 1 << 3)
}

/// Labels follow clockwise sectors; every leader starts radially and ends along its label's axis.
struct DetentSelectorGeometry {
    struct Entry {
        let side: DetentLabelLayout
        let angle: CGFloat
        var start: CGPoint
        var bend: CGPoint
        var end: CGPoint
        var label: CGRect
        var alignment: Alignment { side == .right ? .leading : side == .left ? .trailing : .center }
    }
    let size: CGSize
    let center: CGPoint
    let entries: [Entry]
    static let diameter: CGFloat = 44

    init(labelSizes: [CGSize], layout: DetentLabelLayout) {
        let requested = [DetentLabelLayout.top, .right, .bottom, .left].filter { layout.contains($0) }
        let sides = Array((requested.isEmpty ? [.right] : requested).prefix(labelSizes.count))
        var labels: [(side: DetentLabelLayout, size: CGSize, offset: CGFloat)] = []
        var halfSpan: CGFloat = 0
        for (group, side) in sides.enumerated() {
            let count = labelSizes.count / sides.count + (group < labelSizes.count % sides.count ? 1 : 0)
            let sizes = Array(labelSizes[labels.count..<(labels.count + count)])
            let vertical = side == .right || side == .left
            let row = max(18, sizes.map(\.height).max() ?? 0)
            let width = sizes.map(\.width).max() ?? 0
            let span = vertical ? CGFloat(count) * row : sizes.map(\.width).reduce(0, +) + CGFloat(count - 1) * 12
            halfSpan = max(halfSpan, span / 2)
            var cursor = -span / 2
            for size in sizes {
                let length = vertical ? row : size.width
                labels.append((side, CGSize(width: vertical ? width : size.width, height: row), cursor + length / 2))
                cursor += length + (vertical ? 0 : 12)
            }
        }
        let outerOffset = labels.map { abs($0.offset) }.max() ?? 0
        // Keep combined groups inside their own sectors, including the full label hit areas.
        let fan = max(38, sides.count > 1 ? max(halfSpan + 8, outerOffset * sqrt(2) + 3) : outerOffset + 8)
        var rawEntries: [Entry] = []
        var bounds = CGRect(x: -22, y: -22, width: Self.diameter, height: Self.diameter)
        for label in labels {
            let normal: CGPoint
            switch label.side {
            case .top: normal = CGPoint(x: 0, y: -1)
            case .right: normal = CGPoint(x: 1, y: 0)
            case .bottom: normal = CGPoint(x: 0, y: 1)
            default: normal = CGPoint(x: -1, y: 0)
            }
            let tangent = CGPoint(x: -normal.y, y: normal.x)
            func point(_ distance: CGFloat) -> CGPoint {
                CGPoint(x: normal.x * distance + tangent.x * label.offset, y: normal.y * distance + tangent.y * label.offset)
            }
            let bend = point(sqrt(fan * fan - label.offset * label.offset))
            let angle = atan2(bend.y, bend.x)
            let end = point(fan + 14)
            let normalSize = normal.x == 0 ? label.size.height : label.size.width
            let middle = CGPoint(x: end.x + normal.x * (4 + normalSize / 2), y: end.y + normal.y * (4 + normalSize / 2))
            let frame = CGRect(x: middle.x - label.size.width / 2, y: middle.y - label.size.height / 2,
                               width: label.size.width, height: label.size.height)
            rawEntries.append(Entry(side: label.side, angle: angle, start: CGPoint(x: 25 * cos(angle), y: 25 * sin(angle)),
                                    bend: bend, end: end, label: frame))
            bounds = bounds.union(frame)
        }
        center = CGPoint(x: -bounds.minX, y: -bounds.minY)
        size = bounds.size
        entries = rawEntries.map { entry in
            var entry = entry
            entry.start.x -= bounds.minX; entry.start.y -= bounds.minY
            entry.bend.x -= bounds.minX; entry.bend.y -= bounds.minY
            entry.end.x -= bounds.minX; entry.end.y -= bounds.minY
            entry.label = entry.label.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            return entry
        }
    }
}

/// Discrete mode knob with aligned elbow leaders; combine label sides in clockwise order.
struct DetentSelector<Value: Hashable>: View {
    let title: String
    let options: [KeyOption<Value>]
    @Binding var selection: Value
    var labelLayout: DetentLabelLayout = .right
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let index = options.firstIndex { $0.value == selection } ?? 0
        // Measure the heavier label in every state so changing selection never moves the leaders.
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let sizes = options.map { option in
            let size = (option.title as NSString).size(withAttributes: [.font: font])
            return CGSize(width: max(18, ceil(size.width)), height: max(18, ceil(size.height)))
        }
        let geometry = DetentSelectorGeometry(labelSizes: sizes, layout: labelLayout)
        let knob = DetentSelectorGeometry.diameter
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let center = geometry.center
                let radius = knob / 2
                for (i, entry) in geometry.entries.enumerated() {
                    var line = Path()
                    line.move(to: entry.start); line.addLine(to: entry.bend); line.addLine(to: entry.end)
                    context.stroke(line, with: .color(i == index ? Theme.text : Theme.textSecondary),
                                   style: StrokeStyle(lineWidth: i == index ? 1.5 : 1, lineCap: .round, lineJoin: .round))
                }
                let base = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: knob, height: knob))
                context.fill(base, with: .linearGradient(Gradient(colors: [Theme.knobRimTop, Theme.knobRimBottom]),
                                                        startPoint: CGPoint(x: center.x, y: center.y - radius),
                                                        endPoint: CGPoint(x: center.x, y: center.y + radius)))
                context.stroke(base, with: .color(Theme.materialEdge), lineWidth: 0.5)
                let disc = Path(ellipseIn: CGRect(x: center.x - radius + 5, y: center.y - radius + 5, width: knob - 10, height: knob - 10))
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: Theme.keyAmbientShadow, radius: 6, y: 6))
                    layer.addFilter(.shadow(color: Theme.keyContactShadow, radius: 1.5, y: 2))
                    layer.fill(disc, with: .color(Theme.capBottom))
                }
                context.fill(disc, with: .radialGradient(Gradient(colors: [Theme.capTop, Theme.capBottom]),
                                                          center: CGPoint(x: center.x, y: center.y - radius * 0.4),
                                                          startRadius: 0, endRadius: knob * 0.75))
                context.stroke(disc, with: .color(Theme.keyHighlight), lineWidth: 1)
                if geometry.entries.indices.contains(index) {
                    let a = geometry.entries[index].angle
                    var pointer = Path()
                    pointer.move(to: CGPoint(x: center.x + (radius - 16) * cos(a), y: center.y + (radius - 16) * sin(a)))
                    pointer.addLine(to: CGPoint(x: center.x + (radius - 8) * cos(a), y: center.y + (radius - 8) * sin(a)))
                    context.stroke(pointer, with: .color(Theme.accentSignal), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
            .allowsHitTesting(false)
            Color.clear.frame(width: knob, height: knob).contentShape(Circle())
                .onTapGesture { if !options.isEmpty { selection = options[(index + 1) % options.count].value } }
                .position(geometry.center)
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                let entry = geometry.entries[i]
                Button { selection = option.value } label: {
                    Text(option.title).font(.system(size: 12, weight: i == index ? .semibold : .regular))
                        .foregroundStyle(i == index ? Theme.text : Theme.textSecondary)
                        .fixedSize().frame(width: entry.label.width, height: entry.label.height, alignment: entry.alignment)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).position(x: entry.label.midX, y: entry.label.midY)
            }
        }.frame(width: geometry.size.width, height: geometry.size.height)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1, from: index) }
        .onKeyPress(.downArrow) { step(1, from: index) }
        .onKeyPress(.leftArrow) { step(-1, from: index) }
        .onKeyPress(.rightArrow) { step(1, from: index) }
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in Text(option.title).tag(option.value) }
            }
        }
    }
    private func step(_ offset: Int, from index: Int) -> KeyPress.Result {
        guard enabled else { return .ignored }
        let next = index + offset
        if options.indices.contains(next) { selection = options[next].value }
        return .handled
    }
}
