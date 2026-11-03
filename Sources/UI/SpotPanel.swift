import SwiftUI

struct SpotPanel: View {
    @Bindable var model: AppModel
    private var repairs: [SpotRepair] { model.recipe?.repairs ?? [] }
    private var mode: Binding<SpotRepairMode> {
        Binding(get: { model.spotKind }, set: { model.setSpotKind($0) })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelTitle(L10n.text("app.spotRemoval", defaultValue: "Spot Removal")) {
                    Button { model.showSpotGuides.toggle() } label: {
                        LampLabel(on: model.showSpotGuides) { Image(systemName: "mappin.and.ellipse") }
                    }.buttonStyle(.key(selected: model.showSpotGuides, height: 24, padding: 7))
                        .help(L10n.text("app.showSpotPinsAndSourcesHTheHealingEffect", defaultValue: "Show spot pins and sources (H); the healing effect is preserved"))
                        .accessibilityLabel(L10n.text("app.showSpotPins", defaultValue: "Show Spot Pins")).accessibilityValue(model.showSpotGuides ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
                }
                Button(model.refreshingSpotSource ? L10n.text("app.findingASource", defaultValue: "Finding a source…") : L10n.text("app.changeSource", defaultValue: "Change Source  /")) { model.refreshSpotSource() }
                    .buttonStyle(.key(height: 24)).padding(.horizontal, 12).padding(.top, 8)
                    .disabled(model.refreshingSpotSource || !repairs.contains(where: { $0.id == model.selectedSpotID && $0.enabled }))
                    .help(L10n.text("app.chooseAnotherSourceForThisSpotUndoIsAvailable", defaultValue: "Choose another source for this spot; undo is available, and you can also drag the source directly"))
                    .accessibilityIdentifier("spot-refresh-source")
                KeyRow(title: L10n.text("app.method", defaultValue: "Method"), options: SpotRepairMode.allCases.map { KeyOption($0, $0.title) }, selection: mode)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
                AdjustmentRow(label: L10n.text("app.size", defaultValue: "Size"), value: model.spotRadius * 200, range: 0.2...100, reset: 8,
                              change: { model.setSpotRadius($0 / 200, commit: $1) }, commit: { model.commitRecipe() })
                    .padding(.horizontal, 12)
                AdjustmentRow(label: L10n.text("app.feather", defaultValue: "Feather"), value: model.spotFeather * 100, range: 0...100, reset: 70,
                              change: { model.setSpotFeather($0 / 100, commit: $1) }, commit: { model.commitRecipe() })
                    .padding(.horizontal, 12)
                AdjustmentRow(label: L10n.text("app.strength", defaultValue: "Strength"), value: model.spotOpacity * 100, range: 0...100, reset: 100,
                              change: { model.setSpotOpacity($0 / 100, commit: $1) }, commit: { model.commitRecipe() })
                    .padding(.horizontal, 12)
                Seam().padding(.top, 8)
                if repairs.isEmpty {
                    Text(L10n.text("app.paintOverTheAreaToRepair", defaultValue: "Paint over the area to repair."))
                        .foregroundStyle(Theme.textSecondary).padding(12)
                } else {
                    ForEach(Array(repairs.enumerated()), id: \.element.id) { index, repair in
                        spotRow(repair, index: index + 1)
                    }
                }
                Text(L10n.text("app.healingPreservesTargetAlphaTransparentSourcesProvideNoColor", defaultValue: "Healing preserves target alpha. Transparent sources provide no color."))
                    .font(.caption).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).padding(.top, 8)
                Text(model.spotInstruction)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("spot-settings")
    }
    private func spotRow(_ repair: SpotRepair, index: Int) -> some View {
        HStack(spacing: 8) {
            Button { model.selectSpot(repair.id) } label: {
                ListRowLabel(title: "\(repair.mode.title) \(index)", detail: repair.enabled ? nil : L10n.text("app.disabled", defaultValue: "Disabled"),
                             selected: model.selectedSpotID == repair.id, height: Metrics.row)
            }.buttonStyle(.plain).accessibilityAddTraits(model.selectedSpotID == repair.id ? .isSelected : [])
            LampSwitch(title: L10n.text("app.spotRemoval_1932", defaultValue: "Spot Removal \(index)"), isOn: Binding(get: { repair.enabled }, set: { _ in model.toggleSpot(repair.id) }))
            Button(role: .destructive) { model.deleteSpot(repair.id) } label: {
                Image(systemName: "trash")
            }.buttonStyle(.key(height: 24, padding: 7))
                .help(L10n.text("app.deleteThisSpot", defaultValue: "Delete This Spot"))
                .accessibilityLabel(L10n.text("app.deleteSpotRemoval_1934", defaultValue: "Delete Spot Removal \(index)"))
        }.padding(.trailing, 12)
    }
}
