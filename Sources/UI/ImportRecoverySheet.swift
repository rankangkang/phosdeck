import SwiftUI
import AppKit

struct ImportRecoverySheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plans: [CopyPlan] = []
    @State private var message = ""
    @State private var cleanup: (String, CopyMember)?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("app.importLogAndPreviousFileRecovery", defaultValue: "Import Log and Previous File Recovery")).font(.headline)
            Text(L10n.text("app.sourcesTemporaryFilesAndDestinationsAreVerifiedBeforeContinuing", defaultValue: "Sources, temporary files, and destinations are verified before continuing. Published files are preserved; previous destinations are restored only to new locations.")).foregroundStyle(Theme.textSecondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    ForEach(plans) { plan in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(plan.sourceRoot.lastPathComponent) → \(plan.targetRoot.lastPathComponent) · \(TaskStatusText.title(plan.state))").fontWeight(.medium)
                            ForEach(plan.groups) { group in
                                Text("\(group.members.first?.source.lastPathComponent ?? L10n.text("app.needsConfirmation", defaultValue: "Needs Confirmation")) · \(TaskStatusText.title(group.state)) \(group.diagnostic ?? "")").font(.caption11)
                                ForEach(group.members.filter { !plan.isArchived && $0.recovery != nil && $0.recoveryState != "deleted" }) { member in
                                    HStack {
                                        Text(L10n.text("app.previousFile", defaultValue: "Previous file: \(member.destination.lastPathComponent)"))
                                        Button(L10n.text("app.showLocation", defaultValue: "Show Location")) {
                                            do {
                                                let lease = try AccessLease(bookmark: plan.targetBookmark)
                                                NSWorkspace.shared.activateFileViewerSelecting([member.recovery!])
                                                withExtendedLifetime(lease) {}
                                            } catch { message = error.localizedDescription }
                                        }
                                        Button(L10n.text("app.restoreToNewLocation", defaultValue: "Restore to New Location…")) { restore(member, plan: plan) }
                                        if plan.state == "completed" {
                                            Button(L10n.text("app.cleanUpPreviousFile", defaultValue: "Clean Up Previous File…")) { cleanup = (plan.id, member) }.disabled(model.busy)
                                        }
                                    }
                                }
                            }
                            if plan.canResume {
                                Button(L10n.text("app.verifyAgainAndContinueIncompleteItems", defaultValue: "Verify Again and Continue Incomplete Items")) {
                                    model.runCopy(plan.resuming); dismiss()
                                }.disabled(model.busy)
                            }
                            Seam()
                        }
                    }
                }
            }
            .overlay { if plans.isEmpty { Text(L10n.text("app.noCopyImportRecords", defaultValue: "No copy import records")).foregroundStyle(Theme.textSecondary) } }
            if !message.isEmpty { Text(message).foregroundStyle(Theme.warning) }
            Seam()
            HStack { Spacer(); Button(L10n.text("app.close", defaultValue: "Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 740, height: 500).instrumentForm()
        .alert(L10n.text("app.permanentlyRemoveThisPreviousFile", defaultValue: "Permanently remove this previous file?"), isPresented: Binding(get: { cleanup != nil }, set: { if !$0 { cleanup = nil } })) {
            Button(L10n.text("app.cancel", defaultValue: "Cancel"), role: .cancel) { cleanup = nil }
            Button(L10n.text("app.cleanUpPreviousFile_1351", defaultValue: "Clean Up Previous File"), role: .destructive) {
                guard let (id, member) = cleanup, let catalog = model.catalog else { return }
                cleanup = nil
                Task {
                    do {
                        try await CopyImporter().cleanupOld(planID: id, memberID: member.id, catalog: catalog)
                        plans = try CopyImporter.savedPlans(catalog: catalog); message = L10n.text("app.selectedPreviousFileRemovedSourceAndCurrentDestinationPreserved", defaultValue: "Selected previous file removed. Source and current destination preserved")
                    } catch { message = error.localizedDescription }
                }
            }
        } message: { Text(L10n.text("app.previousVersionWillNoLongerBeRecoverableFromImportRecovery", defaultValue: "Previous version \(cleanup?.1.destination.lastPathComponent ?? "") will no longer be recoverable from ImportRecovery. Confirm a backup or recovery copy first.")) }
        .onAppear { do { if let catalog = model.catalog { plans = try CopyImporter.savedPlans(catalog: catalog) } } catch { message = error.localizedDescription } }
    }
    private func restore(_ member: CopyMember, plan: CopyPlan) {
        let panel = NSSavePanel(); panel.title = L10n.text("app.restorePreviousFileToNewLocationNoOverwrite", defaultValue: "Restore Previous File to New Location (No Overwrite)"); panel.nameFieldStringValue = "recovered-" + member.destination.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let from = try AccessLease(bookmark: plan.targetBookmark), to = AccessLease(url: url)
                defer { withExtendedLifetime([from, to]) {} }
                try await CopyImporter().restoreOld(member, to: url)
                message = L10n.text("app.previousFileRestoredToTheSelectedNewLocation", defaultValue: "Previous file restored to the selected new location")
            } catch { message = error.localizedDescription }
        }
    }
}
