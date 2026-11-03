import SwiftUI
import UniformTypeIdentifiers

struct XMPPresetImportSheet: View {
    @Bindable var model: AppModel
    let catalog: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var reading = false
    @State private var items: [XMPPresetImportItem] = []
    @State private var problem: String?
    @State private var readerTask: Task<Void, Never>?
    private var drafts: [XMPPresetDraft] { items.filter(\.canImport).compactMap(\.draft) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("app.importLightroomXMPPresets_2258", defaultValue: "Import Lightroom XMP Presets")).font(.headline)
            Text(L10n.text("app.chooseXmpFilesReviewTheirConversionThenImportInto", defaultValue: "Choose .xmp files, review their conversion, then import into this catalog. Only declared global settings are applied; rendering approximates Lightroom."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("app.chooseXMPFiles", defaultValue: "Choose XMP Files…")) { picking = true }.buttonStyle(.key).disabled(reading)
                if reading { ProgressView().controlSize(.small); Text(L10n.text("app.readingPresets", defaultValue: "Reading presets…")).font(.caption11) }
                else if !items.isEmpty { Text(L10n.text("app.importableUnavailable", defaultValue: "\(drafts.count) importable · \(items.count - drafts.count) unavailable")).font(.caption11).foregroundStyle(Theme.textSecondary) }
                Spacer()
            }
            Seam()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if items.isEmpty, !reading {
                        Text(L10n.text("app.selectUpTo128FilesAtOnceEachWithin", defaultValue: "Select up to 128 files at once, each within 4 MiB. ZIP files, folders, and .lrtemplate files are not supported."))
                            .font(.caption11).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                Text(item.title).font(.headline)
                                Spacer()
                                Text(!item.canImport ? L10n.text("app.unavailable", defaultValue: "Unavailable") : item.draft?.settings.unsupported.isEmpty == true ? L10n.text("app.importable", defaultValue: "Importable") : L10n.text("app.partiallySupported", defaultValue: "Partially Supported"))
                                    .foregroundStyle(item.canImport ? Theme.textSecondary : Theme.error).font(.caption11)
                            }
                            Text(item.filename + (item.draft.map { " · " + $0.group } ?? ""))
                                .font(.caption11).foregroundStyle(Theme.textSecondary)
                            if let settings = item.draft?.settings, settings.hasContent {
                                Text(L10n.text("app.converted", defaultValue: "Converted: ") + settings.options.summary).font(.caption11).foregroundStyle(Theme.textSecondary)
                            }
                            ForEach(Array(item.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).font(.caption11).foregroundStyle(item.canImport ? Theme.warning : Theme.error)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Seam()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem { Text(problem).font(.caption11).foregroundStyle(Theme.error).textSelection(.enabled) }
            HStack {
                Text(L10n.text("app.importPreservesPhotoEditsDuplicatesAreSkippedUndoThe", defaultValue: "Import preserves photo edits; duplicates are skipped. Undo the batch as one action.")).font(.caption11).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("app.importPresets", defaultValue: "Import \(drafts.count) Presets")) {
                    if model.importXMPPresets(drafts, expectedCatalog: catalog) {
                        let failed = items.filter { !$0.canImport }
                        model.reports += failed.map { $0.filename + "：" + $0.issues.joined(separator: "；") }
                        if !failed.isEmpty { model.status += L10n.text("app.filesCannotBeImported", defaultValue: ", \(failed.count) files cannot be imported") }
                        dismiss()
                    }
                    else { problem = model.error; model.error = nil }
                }.buttonStyle(.key).keyboardShortcut(.defaultAction).disabled(reading || drafts.isEmpty || model.busy || problem != nil)
            }
        }.padding(24).frame(width: 660, height: 540).instrumentForm()
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "xmp") ?? .xml], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): load(urls)
            case .failure(let error): problem = error.localizedDescription
            }
        }
        .onDisappear { readerTask?.cancel() }
    }
    private func load(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard urls.count <= XMPPresetReader.maximumFiles else { problem = L10n.text("app.chooseUpTo128XMPFilesAtOnceReduce", defaultValue: "Choose up to 128 XMP files at once. Reduce the selection"); return }
        problem = nil; items = []; reading = true
        readerTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> [XMPPresetImportItem] in
                try urls.map { url in try Task.checkCancellation(); return XMPPresetReader.read(url) }
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }
                items = result
            } catch { if !Task.isCancelled { problem = error.localizedDescription } }
            reading = false
        }
    }
}
