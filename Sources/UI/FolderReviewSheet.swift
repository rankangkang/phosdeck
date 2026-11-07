import SwiftUI

struct FolderReviewSheet: View {
    @Bindable var model: AppModel
    let catalog: CatalogStore
    let scope: FolderReviewScope
    @Environment(\.dismiss) private var dismiss
    @State private var service = FolderReviewService()
    @State private var includeSubfolders = true
    @State private var preview: FolderReviewPreview?
    @State private var selected: Set<String> = []
    @State private var locations: [String: String] = [:]
    @State private var filter = 0
    @State private var working = false
    @State private var applying = false
    @State private var progress = 0
    @State private var job: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var message: String?
    @State private var failure: String?
    private var entries: [FolderDifference] {
        let all = preview?.entries ?? []
        return filter == 0 ? all : all.filter { $0.kind.rawValue == filter - 1 }
    }
    private var selectionIssue: String? {
        preview.flatMap { FolderReviewService.selectionIssue($0, selected: selected, locations: locations) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("folderReview.title", defaultValue: "Review Folder Changes")).font(.headline)
            Text(scope.url.path).font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("folderReview.help", defaultValue: "Choose the changes to apply. Missing records, edits and virtual copies are kept. Originals are never moved, replaced or deleted."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Toggle(L10n.text("app.includeSubfolders", defaultValue: "Include Subfolders"), isOn: $includeSubfolders)
                    .toggleStyle(InstrumentToggleStyle()).disabled(working)
                Button(L10n.text("folderReview.scanAgain", defaultValue: "Scan Again")) { scan() }.buttonStyle(.key).disabled(working)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                    Text(applying ? L10n.text("folderReview.applying", defaultValue: "Verifying and applying…")
                         : L10n.text("folderReview.checking", defaultValue: "Checking \(progress) locations…")).font(.caption11)
                } else if let preview {
                    Text(L10n.text("folderReview.checked", defaultValue: "\(preview.checkedCount) locations checked")).font(.caption11).foregroundStyle(Theme.textSecondary)
                }
            }
            KeyRow(title: L10n.text("folderReview.show", defaultValue: "Show"),
                options: [KeyOption(0, countLabel(L10n.text("app.all", defaultValue: "All"), preview?.entries.count ?? 0))] +
                    FolderDifferenceKind.allCases.map { kind in
                        KeyOption(kind.rawValue + 1, countLabel(kind.title, preview?.entries.filter { $0.kind == kind }.count ?? 0))
                    },
                selection: $filter, expand: true, wrappingColumns: 3).disabled(working)
            HStack {
                Button(L10n.text("folderReview.selectShown", defaultValue: "Select Shown Changes")) {
                    selected.formUnion(entries.filter { $0.kind != .issue }.map(\.id))
                }.buttonStyle(.key)
                Button(L10n.text("app.clearSelection", defaultValue: "Clear Selection")) { selected = [] }.buttonStyle(.key)
                Spacer()
            }.disabled(working || preview == nil)
            Seam()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in differenceRow(entry); Seam() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if entries.isEmpty && !working && preview != nil {
                    Text(L10n.text("folderReview.noChanges", defaultValue: "No changes in this view")).foregroundStyle(Theme.textSecondary)
                }
            }
            .disabled(working)
            if let text = failure ?? selectionIssue {
                Text(text).font(.caption11).foregroundStyle(Theme.warning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("folder-review-error")
            }
            if let message {
                Text(message).font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("folder-review-result")
            }
            Seam()
            HStack {
                Button(working ? L10n.text("app.cancel", defaultValue: "Cancel") : L10n.text("app.close", defaultValue: "Close")) {
                    if working { job?.cancel() } else { dismiss() }
                }.buttonStyle(.key).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("folderReview.applySelected", defaultValue: "Apply Selected (\(selected.count))")) { apply() }
                    .buttonStyle(PrimaryKeyStyle()).keyboardShortcut(.defaultAction)
                    .disabled(working || selected.isEmpty || selectionIssue != nil || preview == nil)
                    .accessibilityIdentifier("folder-review-apply")
            }
        }
        .padding(20).frame(width: 780, height: 610).instrumentForm()
        .interactiveDismissDisabled(working)
        .onAppear { scan() }
        .onChange(of: includeSubfolders) { scan() }
        .onDisappear { generation = UUID(); job?.cancel() }
    }
    private func countLabel(_ title: String, _ count: Int) -> String {
        L10n.text("folderReview.countLabel", defaultValue: "\(title) (\(count))")
    }
    private func differenceRow(_ entry: FolderDifference) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                if entry.kind != .issue {
                    Button(entry.actionTitle) {
                        if !selected.insert(entry.id).inserted { selected.remove(entry.id) }
                    }
                    .buttonStyle(.key(selected: selected.contains(entry.id), lampInside: true))
                    .frame(width: 140)
                    .accessibilityLabel(L10n.text("folderReview.actionForPath", defaultValue: "\(entry.actionTitle) · \(entry.path)"))
                    .accessibilityValue(selected.contains(entry.id) ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("folderReview.notSelected", defaultValue: "Not Selected"))
                }
                Text(entry.path).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.kind.title).font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            if entry.kind == .moved {
                Picker(L10n.text("folderReview.newLocation", defaultValue: "Candidate Location"), selection: Binding(
                    get: { entry.selectedFile(locations: locations)?.relativePath ?? "" },
                    set: { locations[entry.id] = $0 }
                )) {
                    Text(L10n.text("folderReview.chooseCandidate", defaultValue: "Choose a location…")).tag("")
                    ForEach(entry.candidates, id: \.relativePath) { Text($0.relativePath).tag($0.relativePath) }
                }
                .pickerStyle(.menu)
                if let candidate = entry.selectedFile(locations: locations) {
                    Text("→ " + candidate.relativePath).font(.caption11).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("folderReview.moveHelp", defaultValue: "Matching identity or content found. Confirm the new location; all versions keep their edits."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            } else if entry.kind == .changed {
                Text(entry.restoresAvailability
                    ? L10n.text("folderReview.sameContent", defaultValue: "The original identity or saved content is verified. Confirm to restore its location and availability.")
                    : L10n.text("folderReview.changedHelp", defaultValue: "The file differs from the saved original. Mark it unavailable and keep its original identity, edits and history."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = entry.problem {
                Text(problem).font(.caption11).foregroundStyle(Theme.warning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .contain)
    }
    private func scan() {
        guard !applying else { return }
        job?.cancel()
        let token = UUID(); generation = token
        selected = []; locations = [:]; preview = nil; failure = nil; message = nil; working = true; progress = 0
        job = Task {
            defer { if generation == token { working = false } }
            do {
                let result = try await service.preview(scope: scope, includeSubfolders: includeSubfolders, catalog: catalog) { count in
                    await MainActor.run { if generation == token { progress = count } }
                }
                try Task.checkCancellation()
                guard generation == token, model.catalog === catalog else { return }
                preview = result
            } catch is CancellationError {
                if generation == token { message = L10n.text("folderReview.cancelled", defaultValue: "Cancelled. No selected changes were applied.") }
            } catch { if generation == token { failure = error.localizedDescription } }
        }
    }
    private func apply() {
        guard !working, !model.busy, model.catalog === catalog, let preview, !selected.isEmpty, selectionIssue == nil else { return }
        working = true; applying = true; failure = nil; message = nil; model.busy = true
        let chosen = selected, choices = locations
        job = Task {
            defer { working = false; applying = false; model.busy = false }
            do {
                let result = try await service.apply(preview, selected: chosen, locations: choices, catalog: catalog)
                // Cancellation after publication still reports what was committed.
                selected = []; locations = [:]; self.preview = nil
                message = result.summary
                do { try model.completedFolderReview(result, catalog: catalog) }
                catch { failure = L10n.text("folderReview.refreshFailed", defaultValue: "Changes were saved, but the workspace could not refresh: \(error.localizedDescription)") }
            } catch is CancellationError {
                message = L10n.text("folderReview.cancelled", defaultValue: "Cancelled. No selected changes were applied.")
            } catch { failure = error.localizedDescription }
        }
    }
}
