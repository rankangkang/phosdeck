import PhosdeckPluginKit
import SwiftUI
import UniformTypeIdentifiers

struct PrintProofControl: View {
    @Bindable var proof: PrintProofEditing
    @State private var open = false
    @State private var pickingFile = false
    @State private var installed: [PrintProfileChoice] = []
    private let title = L10n.text("plugins.softProof", defaultValue: "Soft Proof")

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "printer") }
            .buttonStyle(.key(selected: proof.enabled, height: 24, padding: 6))
            .help(title).accessibilityLabel(title).accessibilityIdentifier("soft-proof")
            .popover(isPresented: $open) {
                options.padding(16).frame(width: 300)
                    .task { installed = await Task.detached(priority: .utility) { PrintProfileChoice.installed() }.value }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [UTType(filenameExtension: "icc") ?? .data]) { result in
                if case .success(let url) = result {
                    proof.setProfile(PrintProfileChoice(url: url, title: url.deletingPathExtension().lastPathComponent))
                }
            }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(title, isOn: $proof.enabled).disabled(proof.profile == nil || !proof.extensionAvailable)
                .accessibilityIdentifier("soft-proof-enabled")
            Menu {
                ForEach(installed) { choice in
                    Button(choice.title) { proof.setProfile(choice) }
                }
                if !installed.isEmpty { Divider() }
                Button(L10n.text("plugins.choosePrintProfile", defaultValue: "Choose ICC Profile…")) {
                    open = false
                    pickingFile = true
                }
            } label: {
                Text(proof.profile?.title ?? L10n.text("plugins.printProfile", defaultValue: "Printer and Paper ICC Profile"))
                    .lineLimit(1).truncationMode(.middle)
            }
            .accessibilityIdentifier("soft-proof-profile")
            Picker(L10n.text("plugins.printIntent", defaultValue: "Rendering Intent"), selection: $proof.intent) {
                Text(L10n.text("plugins.relativeIntent", defaultValue: "Relative Colorimetric")).tag(ToolRequest.PrintIntent.relativeColorimetric)
                Text(L10n.text("plugins.perceptualIntent", defaultValue: "Perceptual")).tag(ToolRequest.PrintIntent.perceptual)
            }.accessibilityIdentifier("soft-proof-intent")
            Toggle(L10n.text("plugins.sendingColors", defaultValue: "Show Sending Colors"), isOn: $proof.showsSendingColors)
                .disabled(!proof.enabled).accessibilityIdentifier("soft-proof-sending-colors")
            Toggle(L10n.text("plugins.gamutWarning", defaultValue: "Target Gamut Warning"), isOn: $proof.warning)
                .disabled(!proof.enabled || proof.showsSendingColors).accessibilityIdentifier("soft-proof-gamut")
            if proof.processing {
                Text(L10n.text("plugins.proofRendering", defaultValue: "Rendering soft proof…"))
                    .foregroundStyle(Theme.textSecondary).font(.caption11)
            } else if !proof.message.isEmpty {
                Text(proof.message).foregroundStyle(Theme.warning).font(.caption11).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HighlightPluginControl: View {
    let model: AppModel
    @State private var open = false
    private let title = L10n.text("plugins.selectHighlights", defaultValue: "Select Highlights")

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "circle.dashed") }
            .buttonStyle(.key(selected: model.currentHighlightDraft != nil, height: 24, padding: 6))
            .help(title).accessibilityLabel(title).accessibilityIdentifier("select-highlights")
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    if model.highlightWorking { ProgressView().controlSize(.small) }
                    if !model.highlightMessage.isEmpty { Text(model.highlightMessage).foregroundStyle(Theme.warning).font(.caption11) }
                    HStack {
                        Button(L10n.text("plugins.previewHighlights", defaultValue: "Preview Highlights"), action: model.previewHighlights)
                            .buttonStyle(.key).disabled(model.highlightWorking || !model.canEdit)
                        if model.currentHighlightDraft != nil {
                            Button(L10n.text("app.cancel", defaultValue: "Cancel"), action: model.cancelHighlightPreview).buttonStyle(.key)
                            Button(L10n.text("plugins.applyHighlightMask", defaultValue: "Apply Mask")) {
                                model.applyHighlightPreview()
                                if model.currentHighlightDraft == nil { open = false }
                            }.buttonStyle(.key)
                        }
                    }
                }.padding(16).frame(minWidth: 245, alignment: .leading)
            }
    }
}
