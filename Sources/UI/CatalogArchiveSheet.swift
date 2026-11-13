import SwiftUI

struct CatalogArchiveSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var destination: AccessLease?
    @State private var extras: [AccessLease] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("archive.title", defaultValue: "Archive Entire Catalog")).font(.headline)
            Text(L10n.text("archive.contents", defaultValue: "Creates an independent catalog and copies the complete contents of these folders, including files outside the catalog."))
                .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            TextField(L10n.text("archive.name", defaultValue: "Archive Name"), text: $name).textFieldStyle(.instrument)
            HStack {
                Text(destination?.url.path ?? L10n.text("archive.chooseDestination", defaultValue: "Choose the destination drive or folder."))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.text("app.chooseSaveLocation", defaultValue: "Choose Save Location…")) {
                    if let url = model.chooseDirectory(title: L10n.text("archive.title", defaultValue: "Archive Entire Catalog")) {
                        destination = AccessLease(url: url)
                    }
                }.buttonStyle(.key)
            }.font(.caption11)
            Seam()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.roots) { root in
                        Text(root.path).textSelection(.enabled)
                    }
                    ForEach(extras, id: \.url) { folder in
                        HStack {
                            Text(folder.url.path).textSelection(.enabled)
                            Spacer()
                            Button(L10n.text("archive.removeFolder", defaultValue: "Remove")) { extras.removeAll { $0.url == folder.url } }
                                .buttonStyle(.key)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).font(.caption11)
            }.frame(height: 122)
            Button(L10n.text("archive.addFolder", defaultValue: "Add Project Folder…")) {
                guard let url = model.chooseDirectory(title: L10n.text("archive.addFolder", defaultValue: "Add Project Folder…")),
                      !extras.contains(where: { $0.url == url }), !model.roots.contains(where: { $0.path == url.resolvingSymlinksInPath().path }) else { return }
                extras.append(AccessLease(url: url))
            }.buttonStyle(.key)
            if let error { Text(error).font(.caption11).foregroundStyle(Theme.warning) }
            Seam()
            HStack {
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.buttonStyle(.key).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("archive.create", defaultValue: "Create Archive")) {
                    guard let destination else { return }
                    do { try model.startCatalogArchive(name: name, parent: destination, extras: extras) }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(PrimaryKeyStyle()).keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 580).instrumentForm()
        .onAppear { name = L10n.text("archive.defaultName", defaultValue: "\(model.catalogName) Archive") }
    }
}
