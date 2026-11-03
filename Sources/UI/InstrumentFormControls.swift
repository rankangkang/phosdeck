import SwiftUI

/// Two physical forms, with one convention: right/up is on. Panel bypass keeps its separate lamp key.
enum InstrumentSwitchKind { case slide, lever }

struct InstrumentToggleStyle: ToggleStyle {
    var kind: InstrumentSwitchKind = .slide
    var expand = false
    func makeBody(configuration: Configuration) -> some View {
        InstrumentToggleBody(configuration: configuration, kind: kind, expand: expand)
    }
}

private struct InstrumentToggleBody: View {
    let configuration: ToggleStyleConfiguration
    let kind: InstrumentSwitchKind
    let expand: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label.fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: expand ? .infinity : nil, alignment: .leading)
                SwitchMechanism(on: configuration.isOn, kind: kind).accessibilityHidden(true)
                Text(configuration.isOn ? L10n.text("app.on_1407", defaultValue: "On") : L10n.text("app.off_1408", defaultValue: "Off")).font(.caption11).fixedSize().accessibilityHidden(true)
            }
            .foregroundStyle(enabled ? Theme.text : Theme.textDisabled)
            .frame(minHeight: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focused($focused)
        .overlay {
            if focused && enabled {
                RoundedRectangle(cornerRadius: 3).stroke(Theme.focusRing, lineWidth: 2).padding(-3).allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

extension ToggleStyle where Self == InstrumentToggleStyle {
    static var instrument: InstrumentToggleStyle { InstrumentToggleStyle() }
    static var instrumentLever: InstrumentToggleStyle { InstrumentToggleStyle(kind: .lever) }
}

private struct SwitchMechanism: View {
    let on: Bool
    let kind: InstrumentSwitchKind
    @Environment(\.isEnabled) private var enabled
    private var indexColor: Color { !enabled ? Theme.textDisabled : on ? Theme.lampOn : Theme.controlBorder }
    var body: some View {
        if kind == .slide {
            ZStack(alignment: .leading) {
                well(radius: 4)
                Capsule().fill(Theme.controlBorder).frame(width: 3, height: 5).offset(x: on ? 11 : 42)
                cap(size: Metrics.switchCap, radius: 3)
                    .overlay { RoundedRectangle(cornerRadius: 1).fill(indexColor).frame(width: 3, height: 10) }
                    .offset(x: 3 + (on ? Metrics.switchTravel : 0))
            }.frame(width: Metrics.switchTrack.width, height: Metrics.switchTrack.height)
        } else {
            HStack(spacing: 8) {
                ZStack {
                    well(radius: 4)
                    Capsule().fill(Theme.lampSocket).frame(width: 8, height: 38)
                    Capsule().fill(LinearGradient(colors: [Theme.controlBorder, Theme.capTop, Theme.controlBorder], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 4, height: 14).offset(y: on ? -5 : 5)
                    ballCap
                        .offset(y: on ? -Metrics.leverTravel / 2 : Metrics.leverTravel / 2)
                }.frame(width: Metrics.leverTrack.width, height: Metrics.leverTrack.height)
                VStack(alignment: .leading) { word(L10n.text("app.enable", defaultValue: "Enable"), active: on); Spacer(minLength: 0); word(L10n.text("app.close", defaultValue: "Close"), active: !on) }.frame(height: 47)
            }.padding(.vertical, 2)
        }
    }
    private func word(_ text: String, active: Bool) -> some View {
        Text(text).font(.system(size: 11, weight: active ? .semibold : .regular)).fixedSize()
            .foregroundStyle(!enabled ? Theme.textDisabled : active ? Theme.text : Theme.textSecondary)
    }
    private func well(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Theme.inset.shadow(.inner(color: Theme.insetShadow, radius: 1.5, y: 1)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(enabled ? Theme.controlBorder : Theme.textDisabled, lineWidth: 0.75))
    }
    private func cap(size: CGSize, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(LinearGradient(colors: enabled ? [Theme.capTop, Theme.capBottom] : [Theme.panel, Theme.panel], startPoint: .top, endPoint: .bottom))
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(enabled ? Theme.materialEdge : Theme.textDisabled, lineWidth: 0.75))
            .overlay {
                if enabled {
                    RoundedRectangle(cornerRadius: radius - 1)
                        .strokeBorder(LinearGradient(colors: [Theme.keyHighlight, .clear], startPoint: .top, endPoint: .bottom), lineWidth: 0.5).padding(1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: enabled ? Theme.keyContactShadow : .clear, radius: 1.5, y: 1.5)
    }
    private var ballCap: some View {
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: enabled ? Theme.capTop : Theme.panel, location: 0),
                .init(color: enabled ? Theme.capBottom : Theme.panel, location: 0.55),
                .init(color: enabled ? Theme.materialEdge : Theme.panel, location: 1)
            ], center: UnitPoint(x: 0.32, y: 0.25), startRadius: 0, endRadius: Metrics.leverCap.width * 0.85))
            .frame(width: Metrics.leverCap.width, height: Metrics.leverCap.height)
            .overlay(Circle().strokeBorder(enabled ? Theme.materialEdge : Theme.textDisabled, lineWidth: 0.6))
            .overlay {
                if enabled {
                    Circle().strokeBorder(LinearGradient(colors: [Theme.keyHighlight, .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75).padding(1)
                }
            }
            .overlay { Circle().fill(indexColor).frame(width: 3, height: 3) }
            .clipShape(Circle())
            .shadow(color: enabled ? Theme.keyContactShadow : .clear, radius: 1.8, y: 2)
    }
}

/// Independent latched keys; unlike a KeyRow, selecting one never releases its neighbours.
struct LatchingKeyToggleStyle: ToggleStyle {
    var vertical = false
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Group {
                if vertical {
                    VStack(spacing: 7) { configuration.label; Lamp(on: configuration.isOn) }.frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 8) {
                        configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                        Lamp(on: configuration.isOn)
                    }
                }
            }.padding(.vertical, vertical ? 9 : 4)
        }
        .buttonStyle(KeyButtonStyle(selected: configuration.isOn, height: vertical ? 72 : Metrics.key, multiline: true))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

extension ToggleStyle where Self == LatchingKeyToggleStyle {
    static var latchingKey: LatchingKeyToggleStyle { LatchingKeyToggleStyle() }
    static var namingComponent: LatchingKeyToggleStyle { LatchingKeyToggleStyle(vertical: true) }
}

/// Ordered fixed choices reuse the existing native fader's keyboard, AX, snapping and scroll behaviour.
struct DetentSlider<Value: Hashable>: View {
    let title: String
    let options: [KeyOption<Value>]
    @Binding var selection: Value
    let reset: Value
    @Environment(\.isEnabled) private var enabled
    private var index: Int { options.firstIndex { $0.value == selection } ?? 0 }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(options.first { $0.value == selection }?.title ?? L10n.text("app.notSelected_1410", defaultValue: "Not Selected")).font(.value)
            }.foregroundStyle(enabled ? Theme.text : Theme.textDisabled)
            GradientAdjustmentSlider(value: Double(index), range: 0...Double(max(1, options.count - 1)), step: 1,
                                     neutral: Double(options.firstIndex { $0.value == reset } ?? 0), track: .tonal, label: title, change: { value in
                let next = Int(value.rounded())
                if options.indices.contains(next), options[next].enabled, selection != options[next].value { selection = options[next].value }
            }, commit: {}, tickCount: options.count, valueDescription: options.first { $0.value == selection }?.title)
                .frame(height: 28).disabled(options.count < 2)
            HStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                    Button { selection = option.value } label: {
                        Text(option.title).font(.system(size: 11, weight: selection == option.value ? .semibold : .regular))
                            .foregroundStyle(enabled && option.enabled ? Theme.text : Theme.textDisabled)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: i == 0 ? .leading : i == options.count - 1 ? .trailing : .center)
                    }.buttonStyle(.plain).disabled(!option.enabled)
                        .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                }
            }
        }
    }
}

/// A bounded integer window keeps direct entry alongside the two physical step keys.
struct InstrumentIntegerStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var validationChanged: (Bool) -> Void = { _ in }
    var fieldWidth: CGFloat = 42
    @State private var draft: String?
    @State private var invalid = false
    @FocusState private var editing: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                HStack(spacing: 0) {
                    Button { step(-1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.iconKey).disabled(value <= range.lowerBound).accessibilityLabel(L10n.text("app.decreaseByOne", defaultValue: "Decrease \(title) by one"))
                    TextField(title, text: Binding(get: { draft ?? String(value) }, set: edit))
                        .multilineTextAlignment(.center).font(.value).frame(width: fieldWidth).focused($editing)
                        .onSubmit(apply).onExitCommand { clearDraft(); editing = false }
                        .onChange(of: editing) { if !editing, draft != nil { apply() } }
                        .overlay { if invalid { RoundedRectangle(cornerRadius: Metrics.inputRadius).strokeBorder(Theme.error).allowsHitTesting(false) } }
                        .accessibilityLabel(title)
                    Button { step(1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.iconKey).disabled(value >= range.upperBound).accessibilityLabel(L10n.text("app.increaseByOne", defaultValue: "Increase \(title) by one"))
                }
            }
            if invalid { Text(L10n.text("app.enterAnIntegerBetweenAnd", defaultValue: "Enter an integer between \(range.lowerBound) and \(range.upperBound)")).font(.caption11).foregroundStyle(Theme.error) }
        }
        .onChange(of: value) { if !editing { clearDraft() } }
        .onDisappear { validationChanged(true) }
    }
    private func step(_ delta: Int) {
        guard range.contains(value + delta) else { return }
        value += delta; clearDraft()
    }
    private func apply() {
        guard let draft else { return }
        edit(draft)
        if !invalid { clearDraft() }
    }
    private func edit(_ text: String) {
        draft = text
        guard let number = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(number) else {
            invalid = true; validationChanged(false); return
        }
        value = number; invalid = false; validationChanged(true)
    }
    private func clearDraft() {
        draft = nil; invalid = false; validationChanged(range.contains(value))
    }
}
