import SwiftUI
import AppKit

extension PhotoColorLabel {
    /// Semantic catalog colors, deliberately independent of chrome and photo-mat themes.
    var nsColor: NSColor {
        switch self {
        case .none: .clear
        case .red: Palette.labelRed
        case .yellow: Palette.labelYellow
        case .green: Palette.labelGreen
        case .blue: Palette.labelBlue
        case .purple: Palette.labelPurple
        }
    }
}

struct ColorLabelKeys: View {
    let selected: Set<Int>
    var prefix = "set-color-label"
    let action: (Int) -> Void

    var body: some View {
        HStack(spacing: -1) {
            ForEach(PhotoColorLabel.allCases) { label in
                ColorLabelKey(label: label, selected: selected.contains(label.rawValue), prefix: prefix) { action(label.rawValue) }
            }
        }.fixedSize().accessibilityElement(children: .contain).accessibilityLabel(L10n.text("app.colorLabel", defaultValue: "Color Label"))
    }
}

private struct ColorLabelKey: View {
    let label: PhotoColorLabel
    let selected: Bool
    let prefix: String
    let action: () -> Void
    private var title: String {
        let context = prefix == "color-filter" ? L10n.text("app.filterColor", defaultValue: "Filter Color: ") : prefix == "smart-color" ? L10n.text("app.conditionColor", defaultValue: "Condition Color: ") : L10n.text("app.colorLabel_1049", defaultValue: "Color Label: ")
        return context + label.title
    }
    private var help: String {
        if prefix == "smart-color" { return L10n.text("app.chooseColorCondition", defaultValue: "Choose Color Condition: ") + label.title }
        if prefix == "color-filter" { return L10n.text("app.filter", defaultValue: "Filter: ") + label.title + L10n.text("app.combineColorsOrTurnAllOffToShowEvery", defaultValue: "; combine colors, or turn all off to show every color") }
        if label == .none { return L10n.text("app.clearColorLabelsForSelectedPhotos", defaultValue: "Clear color labels for selected photos") }
        return label.titleWithShortcut + L10n.text("app.clickAgainToClear", defaultValue: "; click again to clear")
    }
    var body: some View {
        Button(action: action) {
            ZStack {
                if label == .none {
                    Image(systemName: "nosign").font(.system(size: 10))
                } else {
                    RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: label.nsColor)).frame(width: 10, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(Theme.text.opacity(0.3), lineWidth: 0.5))
                }
                if selected && label != .none {
                    Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                }
            }.frame(width: 12)
        }.buttonStyle(.key(selected: selected, position: KeyPosition(index: label.rawValue, count: 6), height: 22, padding: 4))
            .accessibilityLabel(title).accessibilityValue(selected ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(prefix + "-" + String(label.rawValue))
            .help(help)
    }
}

/// Keep direct swatches where space permits; retain one compact, labelled menu
/// in narrow toolbars so organization never pushes other commands offscreen.
struct ColorLabelPicker: View {
    @Bindable var model: AppModel
    var body: some View {
        ViewThatFits(in: .horizontal) {
            ColorLabelKeys(selected: Set(model.selectedColorLabel.map { [$0] } ?? []), action: { model.toggleColorLabel($0) })
            Menu {
                ForEach(PhotoColorLabel.allCases) { label in
                    Toggle(label.titleWithShortcut, isOn: Binding(
                        get: { model.selectedColorLabel == label.rawValue }, set: { _ in model.toggleColorLabel(label.rawValue) }))
                }
            } label: {
                Image(systemName: "square.fill").font(.system(size: 10))
                    .foregroundStyle(model.selectedColorLabel.flatMap(PhotoColorLabel.init(rawValue:)).map { Color(nsColor: $0 == .none ? .secondaryLabelColor : $0.nsColor) } ?? Theme.textSecondary)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().keySurface(height: 22)
                .accessibilityLabel(L10n.text("app.setColorLabel", defaultValue: "Set Color Label"))
                .accessibilityValue(model.selectedColorLabel.flatMap(PhotoColorLabel.init(rawValue:))?.title ?? L10n.text("app.mixedState", defaultValue: "Mixed State"))
        }.frame(minWidth: 24, idealWidth: 128, maxWidth: 128)
    }
}
