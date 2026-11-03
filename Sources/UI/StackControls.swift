import SwiftUI

struct StackMenu: View {
    @Bindable var model: AppModel
    var body: some View {
        let stack = model.activeStack
        Button(L10n.text("app.createMergeSelectedStacks", defaultValue: "Create / Merge Selected Stacks"),action:model.groupSelection).keyboardShortcut("g",modifiers:.command).disabled(model.selection.count < 2)
        Button(L10n.text("app.unstackGroupsContainingSelectedVersions", defaultValue: "Unstack Groups Containing Selected Versions")) { model.stackAction(.ungroup(model.selection),title:L10n.text("app.unstack", defaultValue: "Unstack")) }.keyboardShortcut("g",modifiers:[.command,.shift]).disabled(stack == nil)
        Button(L10n.text("app.removeSelectedVersionsFromStacks", defaultValue: "Remove Selected Versions from Stacks")) { model.stackAction(.remove(model.selection),title:L10n.text("app.removeStackMembers", defaultValue: "Remove Stack Members")) }.disabled(stack == nil)
        Divider()
        Button(stack?.collapsed == true ? L10n.text("app.expandCurrentStackS", defaultValue: "Expand Current Stack (S)") : L10n.text("app.collapseCurrentStackS", defaultValue: "Collapse Current Stack (S)"),action:model.toggleActiveStack).disabled(stack == nil)
        Button(L10n.text("app.selectMatchingStackMembersIncludingCollapsedMembers", defaultValue: "Select Matching Stack Members, Including Collapsed Members"),action:model.selectStackMembers).disabled(stack == nil)
        if let id = model.activeID {
            Button(L10n.text("app.setAsCoverS", defaultValue: "Set as Cover (⇧S)")) { model.stackAction(.cover(id),title:L10n.text("app.setStackCover", defaultValue: "Set Stack Cover")) }.disabled(stack == nil)
            Button(L10n.text("app.moveMemberEarlier", defaultValue: "Move Member Earlier")) { model.stackAction(.move(id,-1),title:L10n.text("app.reorderStack", defaultValue: "Reorder Stack")) }.disabled(stack?.members.first == id || stack == nil)
            Button(L10n.text("app.moveMemberLater", defaultValue: "Move Member Later")) { model.stackAction(.move(id,1),title:L10n.text("app.reorderStack", defaultValue: "Reorder Stack")) }.disabled(stack?.members.last == id || stack == nil)
            Button(L10n.text("app.splitStackAtCurrentMember", defaultValue: "Split Stack at Current Member")) { model.stackAction(.split(id),title:L10n.text("app.splitStack", defaultValue: "Split Stack")) }.disabled(stack?.members.first == id || stack == nil)
        }
        Divider()
        Button(L10n.text("app.expandAllStacksInCurrentQuery", defaultValue: "Expand All Stacks in Current Query")) { model.collapseResultStacks(false) }
        Button(L10n.text("app.collapseAllStacksInCurrentQuery", defaultValue: "Collapse All Stacks in Current Query")) { model.collapseResultStacks(true) }
        Button(L10n.text("app.autoStackByCaptureTime", defaultValue: "Auto Stack by Capture Time…")) { model.showAutoStacks = true }.disabled(model.resultCount < 2)
    }
}
struct AutoStackSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedOnly = false
    @State private var gap = "2"
    @State private var preview: AutoStackPreview?
    @State private var message: String?
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.text("app.autoStackByAdjacentCaptureInterval", defaultValue: "Auto Stack by Adjacent Capture Interval")).font(.headline)
            SubgroupLabel(L10n.text("app.scopeAndInterval", defaultValue: "Scope and Interval"))
            Text(L10n.text("app.range", defaultValue: "Range"))
            KeyRow(title: L10n.text("app.range", defaultValue: "Range"), options: [KeyOption(false, L10n.text("app.allQueryResultsAllPagesAndCollapsedMembers", defaultValue: "All Query Results (All Pages and Collapsed Members)")), KeyOption(true, L10n.text("app.explicitlySelectedVersions", defaultValue: "Explicitly Selected Versions (\(model.selection.count))"))],
                   selection: $selectedOnly, lampsInside: true, expand: true)
            HStack { Text(L10n.text("app.maximumAdjacentIntervalSeconds", defaultValue: "Maximum Adjacent Interval (Seconds)")); TextField("0–86400",text:$gap).frame(width:110).accessibilityIdentifier("auto-stack-gap") }
            Text(L10n.text("app.existingStacksAreSkippedOnlyValidFullCaptureTimes", defaultValue: "Existing stacks are skipped. Only valid full capture times are compared, preserving fractional seconds and explicit time zones. Unknown time zones are compared within the same source root only, never mixed with known zones. File modification times are not used.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            Button(L10n.text("app.previewGroups", defaultValue: "Preview Groups")) { makePreview() }.buttonStyle(.key)
            if let message { Text(message).foregroundStyle(Theme.warning) }
            if let p = preview {
                Text(L10n.text("app.groupsVersionsSkippedExistingStacksAndWithoutComparableTimes", defaultValue: "\(p.groups.count) groups / \(p.photoCount) versions; skipped \(p.skippedStacked) existing stacks and \(p.skippedTime) without comparable times")).monospacedDigit()
                List(Array(p.groups.enumerated()),id:\.offset) { number,group in
                    VStack(alignment:.leading,spacing:4) {
                        Text(L10n.text("app.stackVersions", defaultValue: "Stack \(number+1) · \(group.count) versions")).fontWeight(.medium)
                        Text(group.compactMap { id in p.inputs.first { $0.id == id }?.name }.joined(separator:" → ")).font(.caption11).textSelection(.enabled)
                    }
                }.scrollContentBackground(.hidden).background(Theme.inset).frame(minHeight:140)
            } else {
                Text(L10n.text("app.previewReviewEachGroupSMembersThenApplyStacking", defaultValue: "Preview, review each group's members, then apply stacking.")).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Seam()
            HStack { Spacer(); Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction); Button(L10n.text("app.applyStacks", defaultValue: "Apply Stacks")) { if let preview, model.applyAutoStacks(preview) { dismiss() } }.disabled(preview?.groups.isEmpty != false).keyboardShortcut(.defaultAction).help(L10n.text("app.undoThisBatchOfStacksAsOneAction", defaultValue: "Undo this batch of stacks as one action")) }
        }.padding(24).frame(width:720,height:560).instrumentForm()
        .onChange(of:gap) { preview = nil }.onChange(of:selectedOnly) { preview = nil }
    }
    private func makePreview() {
        do {
            guard let catalog = model.catalog, let seconds = Double(gap) else { throw LRCError(L10n.text("app.enterAValidNumberOfSeconds", defaultValue: "Enter a valid number of seconds")) }
            preview = try CatalogStore.previewAutoStacks(catalog.stackInputs(query:model.query,ids:selectedOnly ? model.selection : nil),gap:seconds); message = nil
        } catch { message = error.localizedDescription; preview = nil }
    }
}
