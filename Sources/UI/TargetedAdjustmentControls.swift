import SwiftUI

struct TargetedAdjustmentKey: View {
    let model: AppModel
    let target: TargetedAdjustment
    var available = true
    private var help: String {
        target.isDefringe ? L10n.text("defringe.sampleHelp", defaultValue: "Click a fringe to select a 30° hue range. Amount starts at 25 if zero; an existing amount is kept. Drag up/down to adjust, Shift fine-tunes. Release saves once; Escape cancels before release. Hold Space to pan.")
            : L10n.text("app.targetedAdjustmentHelp", defaultValue: "Sample the photo, then drag up/down or use Up/Down keys. Shift fine-tunes; Escape cancels a drag, then exits. Hold Space to pan.")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(target.isDefringe ? (target == .defringePurple
                ? L10n.text("defringe.samplePurple", defaultValue: "Sample Purple Fringe")
                : L10n.text("defringe.sampleGreen", defaultValue: "Sample Green Fringe"))
                : L10n.text("app.targetedAdjustment", defaultValue: "Targeted Adjustment")) { model.toggleTargetedAdjustment(target) }
                .buttonStyle(.key(selected: model.targetedAdjustment == target, height: 22, lampInside: true))
                .controlUnavailable(!available || model.recipe.map { !target.available(in: $0) } != false)
                .accessibilityIdentifier("targeted-adjustment-\(target.identifier)")
                .accessibilityValue(model.targetedAdjustment == target ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
                .help(help)
            if model.targetedAdjustment == target {
                Text(model.targetedReferenceReady
                    ? help
                    : L10n.text("app.preparingTargetSample", defaultValue: "Preparing sampling reference…"))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
        .onDisappear { if model.targetedAdjustment == target { model.cancelTargetedAdjustment() } }
    }
}

struct TargetedCanvasStatus: View {
    let model: AppModel
    let mat: PhotoMat
    var body: some View {
        if let target = model.targetedAdjustment {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("app.targetedAdjustmentTitle", defaultValue: "Targeted Adjustment · \(target.title)"))
                Text(model.targetedReferenceReady ? model.targetedSample?.description
                    ?? L10n.text("app.clickPhotoToSelectTarget", defaultValue: "Click the photo to select a target")
                    : L10n.text("app.preparingTargetSample", defaultValue: "Preparing sampling reference…"))
            }
            .font(.caption11).foregroundStyle(Color(nsColor: mat.text))
            .padding(8).background(mat.color.opacity(0.92))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
        }
    }
}

extension TargetedAdjustment {
    var identifier: String {
        switch self {
        case .hue: "hue"
        case .saturation: "saturation"
        case .luminance: "luminance"
        case .blackWhite: "black-white"
        case .curve(let channel): "curve-\(channel)"
        case .defringePurple: "defringe-purple"
        case .defringeGreen: "defringe-green"
        }
    }
}
