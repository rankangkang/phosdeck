import SwiftUI

struct ImportConflictSheet: View {
    @Bindable var model: AppModel
    let conflict: ImportConflict
    @State private var applyToRemaining = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("app.aFileWithTheSameNameExistsAtThe", defaultValue: "A file with the same name exists at the destination"), systemImage: "doc.on.doc").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(conflict.members) { member in
                        Text(member.source.lastPathComponent).fontWeight(.medium)
                        Text(L10n.text("app.sourceNDestination", defaultValue: "Source: \(member.source.path)\nDestination: \(member.destination.path)"))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 140)
            if let reason = conflict.overwriteRestriction {
                Text(L10n.text("app.thisItemCannotBeOverwritten", defaultValue: "This item cannot be overwritten: \(reason)")).font(.caption11).foregroundStyle(Theme.warning)
            } else {
                Text(L10n.text("app.overwritingPreservesThePreviousFileForRecoveryInThe", defaultValue: "Overwriting preserves the previous file for recovery in the import log.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            Toggle(L10n.text("app.applyToRemainingConflictsInThisBatch", defaultValue: "Apply to remaining conflicts in this batch"), isOn: $applyToRemaining)
            HStack {
                Button(L10n.text("app.cancelImport", defaultValue: "Cancel Import")) { model.resolveImportConflict(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("app.skip", defaultValue: "Skip")) { choose(.skip) }
                Button(L10n.text("app.useUniqueNames", defaultValue: "Use Unique Names")) { choose(.uniqueName) }.disabled(!conflict.canRename)
                Button(L10n.text("app.overwrite", defaultValue: "Overwrite"), role: .destructive) { choose(.overwrite) }.disabled(conflict.overwriteRestriction != nil)
            }
        }.padding(24).frame(width: 560).instrumentForm()
    }
    private func choose(_ policy: ConflictPolicy) {
        model.resolveImportConflict(ImportConflictDecision(policy: policy, applyToRemaining: applyToRemaining))
    }
}
