import SwiftUI

struct ExportRecoverySheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [ExportLog] = []
    @State private var rejected: [String] = []
    @State private var feedback: String?
    @State private var failure: String?
    @State private var unfinishedOnly = false
    private var completed: Int { logs.count(where: \.isCompleted) }
    private var retryable: [ExportLog] { logs.filter(\.canRetryInBatch) }
    private var displayed: [ExportLog] { unfinishedOnly ? logs.filter { !$0.isCompleted } : logs }
    private var batch: Bool { model.exportRecordIDs != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(batch ? L10n.text("app.currentExportResults", defaultValue: "Current Export Results") : L10n.text("app.outputRecordsAndRetry_1203", defaultValue: "Output Records and Retry")).font(.headline)
            Text(L10n.text("app.verifyExistingOutputsRetryMissingFilesWithTheirFrozen", defaultValue: "Verify existing outputs. Retry missing files with their frozen names, settings, and capture metadata. Content mismatches stop processing without overwriting.")).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Text(L10n.text("app.completeIncomplete", defaultValue: "Complete \(completed) · Incomplete \(logs.count - completed)")).font(.caption11).monospacedDigit()
                Spacer(minLength: 4)
                Button(unfinishedOnly ? L10n.text("app.showAll", defaultValue: "Show All") : L10n.text("app.incompleteOnly", defaultValue: "Incomplete Only")) { unfinishedOnly.toggle() }
                    .buttonStyle(.key(selected: unfinishedOnly, height: 22, padding: 8))
                if batch {
                    Button(L10n.text("app.retryIncompleteOutputs", defaultValue: "Retry \(retryable.count) Incomplete Outputs")) {
                        model.retryExports(ids: Set(retryable.map(\.id))); dismiss()
                    }.buttonStyle(.key(height: 22, padding: 8)).disabled(model.busy || retryable.isEmpty)
                }
            }
            if batch, let result = model.lastExportResult, result.ids == model.exportRecordIDs {
                Text(result.operationSummary).font(.caption11).foregroundStyle(Theme.textSecondary)
                if result.unrecorded > 0 {
                    Text(L10n.text("app.outputPlansCouldNotBeSavedReviewTaskResults", defaultValue: "\(result.unrecorded) output plans could not be saved. Review task results, resolve the issues, then export again.")).font(.caption11).foregroundStyle(Theme.warning)
                }
            }
            if batch, !retryable.isEmpty,
               Set(retryable.map { $0.snapshot.destination.deletingLastPathComponent() }).count == 1 {
                Button(L10n.text("app.reauthorizeThisBatchSOriginalDestination", defaultValue: "Reauthorize This Batch's Original Destination…")) { reauthorizeBatch() }
                    .buttonStyle(.key(height: 22, padding: 8)).disabled(model.busy)
            }
            if !rejected.isEmpty {
                DisclosureGroup(L10n.text("app.recordsRejectedNoMigrationOriginalDataPreserved", defaultValue: "\(rejected.count) records rejected; no migration, original data preserved")) {
                    ScrollView { ForEach(rejected, id: \.self) { Text($0).font(.caption11).foregroundStyle(Theme.warning) } }.frame(maxHeight: 80)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(displayed) { log in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(log.snapshot.destination.lastPathComponent) · \(TaskStatusText.title(log.state))")
                            Text(log.snapshot.options.summary).font(.caption11).foregroundStyle(Theme.textSecondary)
                            Text(log.snapshot.destination.path).font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                            if log.snapshot.options.metadataPolicy == .capture { Text(log.snapshot.metadata.summary).font(.caption11).foregroundStyle(Theme.textSecondary) }
                            if let error = log.error { Text(error).foregroundStyle(Theme.warning) }
                            if let retained = log.snapshot.retainedStaging, !retained.isEmpty {
                                DisclosureGroup(L10n.text("app.preservedInterruptedTemporaryFilesNotCache", defaultValue: "Preserved Interrupted Temporary Files (Not Cache)")) {
                                    ForEach(retained, id: \.path) { url in Text(url.path).font(.caption11).textSelection(.enabled) }
                                }
                            }
                            if !log.isArchived {
                                HStack {
                                    if log.state == "completed" {
                                        Button(L10n.text("app.showInFinder", defaultValue: "Show in Finder")) { model.revealExports(ids: [log.id]) }
                                            .disabled(model.busy).accessibilityIdentifier("export-reveal-" + log.id)
                                    }
                                    Button(log.state == "completed" ? L10n.text("app.verifyOutputAndRetryIfNeeded", defaultValue: "Verify Output and Retry if Needed") : L10n.text("app.verifyAndRetryThisOutput", defaultValue: "Verify and Retry This Output")) {
                                        model.retryExport(log.snapshot); dismiss()
                                    }.disabled(model.busy).accessibilityIdentifier("export-retry-" + log.id)
                                    Button(L10n.text("app.reauthorizeOriginalDestination", defaultValue: "Reauthorize Original Destination…")) { reauthorize(log) }
                                        .disabled(model.busy).accessibilityIdentifier("export-reauthorize-" + log.id)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Seam()
                    }
                }
                .padding(12)
            }
            .overlay { if displayed.isEmpty { Text(unfinishedOnly ? L10n.text("app.noIncompleteOutputs", defaultValue: "No incomplete outputs") : L10n.text("app.noOutputRecords", defaultValue: "No output records")).foregroundStyle(Theme.textSecondary) } }
            Seam()
            if let failure { Text(failure).font(.caption11).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true) }
            else if let feedback { Text(feedback).font(.caption11).foregroundStyle(Theme.textSecondary) }
            HStack { Spacer(); Button(L10n.text("app.close", defaultValue: "Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 680, height: 440).instrumentForm()
        .onAppear { unfinishedOnly = model.exportRecordsUnfinishedOnly; load() }
    }
    private func load() {
        do {
            if let catalog = model.catalog { let history = try ExportService.history(catalog: catalog, ids: model.exportRecordIDs); logs = history.logs; rejected = history.rejected }
        } catch { failure = error.localizedDescription }
    }
    private func reauthorize(_ log: ExportLog) {
        guard !model.busy, let catalog = model.catalog,
              let directory = model.chooseDirectory(title: L10n.text("app.reauthorizeOriginalDestinationKeepExportLocation", defaultValue: "Reauthorize Original Destination · Keep Export Location"),
                                                     initialURL: log.snapshot.destination.deletingLastPathComponent()) else { return }
        do {
            try ExportService.reauthorizeTarget(id: log.id, directory: directory, catalog: catalog)
            failure = nil; feedback = L10n.text("app.destinationAuthorizationUpdatedVerifyAndRetryThisOutputIts", defaultValue: "Destination authorization updated. Verify and retry this output; its name and settings are preserved.")
            load()
        } catch { failure = error.localizedDescription }
    }
    private func reauthorizeBatch() {
        guard !model.busy, let catalog = model.catalog, let first = retryable.first,
              let directory = model.chooseDirectory(title: L10n.text("app.reauthorizeBatchDestinationKeepExportLocation", defaultValue: "Reauthorize Batch Destination · Keep Export Location"),
                                                     initialURL: first.snapshot.destination.deletingLastPathComponent()) else { return }
        do {
            for log in retryable { try ExportService.reauthorizeTarget(id: log.id, directory: directory, catalog: catalog) }
            failure = nil; feedback = L10n.text("app.batchDestinationAuthorizationUpdatedRetryIncompleteOutputsFrozenNames", defaultValue: "Batch destination authorization updated. Retry incomplete outputs; frozen names, sources, and settings are preserved.")
            load()
        } catch { failure = error.localizedDescription }
    }
}
