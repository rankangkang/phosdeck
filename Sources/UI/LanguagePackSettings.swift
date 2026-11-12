import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LanguagePackSettings: View {
    @AppStorage(LanguagePackStore.selectionKey) private var selection = ""
    @State private var packs: [LanguagePack] = []
    @State private var working = false
    @State private var failure: String?
    private var activeID: String { L10n.current.pack?.id ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SubgroupLabel(L10n.text("language.title", defaultValue: "Language"))
            Text(L10n.text("language.system", defaultValue: "English and Simplified Chinese follow macOS. Choose this app's language in System Settings › General › Language & Region."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker(L10n.text("language.community", defaultValue: "Community Translation"), selection: $selection) {
                    Text(L10n.text("language.none", defaultValue: "Use Official Language")).tag("")
                    ForEach(packs, id: \.id) { pack in Text(verbatim: pack.name + " · " + pack.author).tag(pack.id) }
                }.accessibilityIdentifier("community-language-picker")
                Button(L10n.text("language.import", defaultValue: "Import…"), action: choosePack)
                    .buttonStyle(.key).accessibilityIdentifier("import-language-pack")
                Button(L10n.text("language.remove", defaultValue: "Remove"), action: removeSelected)
                    .buttonStyle(.key).disabled(selection.isEmpty).accessibilityIdentifier("remove-language-pack")
            }.disabled(working)
            if let pack = packs.first(where: { $0.id == selection }) {
                Text(L10n.text("language.details", defaultValue: "Community translation · Version \(pack.version) · \(pack.keys.count) translated entries"))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            if working { ProgressView().controlSize(.small) }
            if let failure { Text(verbatim: failure).font(.caption11).foregroundStyle(Theme.error).accessibilityIdentifier("language-pack-error") }
            if L10n.current.loadFailed {
                Text(L10n.text("language.unavailable", defaultValue: "The selected language pack could not be loaded. The official language is active; import a valid pack or choose Use Official Language."))
                    .font(.caption11).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if selection != activeID {
                Text(L10n.text("language.restart", defaultValue: "Your language selection takes effect the next time you open the app."))
                    .font(.caption11).foregroundStyle(Theme.warning).accessibilityIdentifier("language-restart-required")
            }
            Text(L10n.text("language.help", defaultValue: "Community authors maintain and distribute their translations. Missing entries use English. macOS dialogs use the system's language settings."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LanguagePackStore.installedPacksChanged)) { _ in
            Task { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        do { packs = try await Task.detached { try LanguagePackStore().installed() }.value }
        catch { failure = error.localizedDescription }
    }

    @MainActor static func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = L10n.text("language.choose", defaultValue: "Choose a Community Language Bundle")
        panel.allowedContentTypes = [.bundle]
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        // Apply selection modes last: configuring a bundle type can change them in the sandboxed panel.
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        return panel
    }

    private func choosePack() {
        let panel = Self.makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; failure = nil
        let lease = AccessLease(url: url)
        Task { @MainActor in
            defer { working = false }
            do {
                let pack = try await Task.detached {
                    defer { withExtendedLifetime(lease) {} }
                    return try LanguagePackStore().install(from: url)
                }.value
                selection = pack.id
                await refresh()
            } catch { failure = error.localizedDescription }
        }
    }

    private func removeSelected() {
        let id = selection
        guard !id.isEmpty else { return }
        working = true; failure = nil
        Task { @MainActor in
            defer { working = false }
            do {
                let active = activeID
                try LanguagePackStore().remove(id: id, activeID: active)
                selection = ""
                await refresh()
            } catch { failure = error.localizedDescription }
        }
    }
}
