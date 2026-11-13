import SwiftUI

struct LightroomImportSheet: View {
    let model: AppModel
    let source: AccessLease
    @Environment(\.dismiss) private var dismiss
    @State private var preview: LightroomCatalog?
    @State private var folders: [Int64: AccessLease] = [:]
    @State private var destination: AccessLease?
    @State private var name = ""
    @State private var copying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("lightroom.title", defaultValue: "Import Lightroom Classic Catalog")).font(.headline)
            Text(source.url.lastPathComponent).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            if let preview {
                Text(L10n.text("lightroom.previewCount", defaultValue: "\(preview.originalCount) originals · \(preview.versions.count - preview.originalCount) virtual copies · \(preview.albums.count) collections"))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
                KeyRow(title: L10n.text("lightroom.fileHandling", defaultValue: "File Handling"), options: [
                    KeyOption(false, L10n.text("lightroom.reference", defaultValue: "Reference in Place")),
                    KeyOption(true, L10n.text("lightroom.copy", defaultValue: "Copy Originals"))
                ], selection: $copying)
                Seam()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(preview.roots) { root in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folders[root.id]?.url.path ?? root.path).textSelection(.enabled)
                                    if folders[root.id] == nil {
                                        Text(L10n.text("lightroom.unlinked", defaultValue: "Source folder was not located")).foregroundStyle(Theme.warning)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button(L10n.text("lightroom.locateFolder", defaultValue: "Locate…")) { locate(root) }.buttonStyle(.key)
                            }
                        }
                        if !preview.warnings.isEmpty {
                            Text(L10n.text("lightroom.previewWarnings", defaultValue: "\(preview.warnings.count) catalog items need review. See the import report after completion."))
                                .foregroundStyle(Theme.warning)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 130).font(.caption11)
                if folders.count < preview.roots.count {
                    Text(L10n.text("lightroom.unlinkedHelp", defaultValue: "Photos in unlocated folders stay in the saved Lightroom catalog copy.")).font(.caption11).foregroundStyle(Theme.warning)
                }
                TextField(L10n.text("app.catalogName", defaultValue: "Catalog Name"), text: $name).textFieldStyle(.instrument)
                HStack {
                    Text(destination?.url.path ?? L10n.text("archive.chooseDestination", defaultValue: "Choose the destination drive or folder."))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("app.chooseSaveLocation", defaultValue: "Choose Save Location…")) {
                        if let url = model.chooseDirectory(title: L10n.text("app.chooseWhereToSaveTheCatalogFile", defaultValue: "Choose Where to Save the Catalog File")) {
                            destination = AccessLease(url: url)
                        }
                    }.buttonStyle(.key)
                }.font(.caption11)
                Text(L10n.text("lightroom.scope", defaultValue: "Creates a new Phosdeck catalog with editable supported adjustments. The source catalog and its available settings files are saved alongside it."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else if error == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("lightroom.scanning", defaultValue: "Reading the catalog…"))
                }
            }
            if let error { Text(error).font(.caption11).foregroundStyle(Theme.warning).textSelection(.enabled) }
            Seam()
            HStack {
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.buttonStyle(.key).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("lightroom.start", defaultValue: "Import Catalog")) {
                    guard let preview, let destination else { return }
                    do { try model.startLightroomImport(preview, source: source, folders: folders, parent: destination, name: name, copying: copying) }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(PrimaryKeyStyle()).keyboardShortcut(.defaultAction)
                    .disabled(preview == nil || destination == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 620).instrumentForm()
        .task { await scan() }
    }

    private func scan() async {
        let source = source
        let worker = Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(source) {} }
            return try LightroomCatalog.preview(source.url.resolvingSymlinksInPath())
        }
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            name = result.file.deletingPathExtension().lastPathComponent
            let parent = source.url.deletingLastPathComponent()
            for root in result.roots {
                let relative = root.relative.replacingOccurrences(of: "\\", with: "/")
                let absolute = root.path.hasPrefix("/") && !root.path.hasPrefix("//") ? URL(fileURLWithPath: root.path, isDirectory: true) : nil
                let relativeFolder = relative.isEmpty || relative.hasPrefix("/") || relative.contains(":")
                    ? nil : parent.appendingPathComponent(relative).standardizedFileURL
                let candidates = [absolute, relativeFolder].compactMap { $0 }
                for url in candidates {
                    if let bookmark = try? AccessLease.bookmark(url, readOnly: true),
                       let lease = try? AccessLease(bookmark: bookmark), (try? ProjectCopy.directoryIdentity(lease.url)) != nil {
                        folders[root.id] = lease
                        break
                    }
                }
            }
            preview = result
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func locate(_ root: LightroomCatalog.Root) {
        let start = root.path.hasPrefix("/") ? URL(fileURLWithPath: root.path, isDirectory: true) : nil
        let title = L10n.text("lightroom.locateNamedFolder", defaultValue: "Locate Lightroom Folder: \(root.name)")
        if let url = model.chooseDirectory(title: title, initialURL: start) { folders[root.id] = AccessLease(url: url) }
    }
}
