import Foundation

extension AppModel {
    var activeStack: PhotoStack? { guard let id = activeID else { return nil }; return (try? catalog?.stacks())?.first { $0.members.contains(id) } }
    func stackAction(_ action: StackAction, title: String) {
        guard !busy, !applyingAdjustments, let catalog, commitRecipe() else { return }
        perform {
            let before = try catalog.stacks(), previous = selection, active = activeID
            _ = try catalog.changeStacks(action)
            guard try before != catalog.stacks() else { return }
            undo.registerUndo(withTarget:self) { $0.restoreStackUndo(before,selection:previous,active:active) }
            undo.setActionName(title)
            try reloadPhotos()
            let visible = Set(try catalog.allResultIDs(query,visibleOnly:true))
            let representative = try activeID.flatMap { try catalog.representative(of:$0,query:query) }
            let retained = selection.intersection(visible)
            restoreStackSelection(retained.union(representative.map { [$0] } ?? []),active:representative)
            status = L10n.text("app.matchingVersionsVisiblePhotosSelectedVersions", defaultValue: "\(title) · \(resultCount) matching versions / \(visibleCount) visible photos / \(selection.count) selected versions")
        }
    }
    func groupSelection() {
        guard let catalog, let top = activeID, selection.contains(top) else { return }
        perform { stackAction(.group(top:top,members:try catalog.exportPhotos(ids:selection,query:query).map(\.id)),title:L10n.text("app.createMergeStack", defaultValue: "Create / Merge Stack")) }
    }
    func toggleStack(_ photoID: String) {
        guard let s = (try? catalog?.stacks())?.first(where: { $0.members.contains(photoID) }) else { return }
        stackAction(.collapse([s.id],!s.collapsed),title:s.collapsed ? L10n.text("app.expandStack", defaultValue: "Expand Stack") : L10n.text("app.collapseStack", defaultValue: "Collapse Stack"))
        if s.collapsed, let badge = stackBadges[photoID], !badge.collapsed, let message = badge.scopeNotice {
            status = message + " · " + status
            showNotice(message)
        }
    }
    func toggleActiveStack() { if let id = activeID { toggleStack(id) } }
    func collapseResultStacks(_ collapsed: Bool) {
        guard let catalog else { return }
        perform {
            let ids = Set(try catalog.stackInputs(query:query).map(\.id))
            let stacks = try catalog.stacks().filter { !ids.isDisjoint(with:$0.members) }
            stackAction(.collapse(Set(stacks.map(\.id)),collapsed),title:collapsed ? L10n.text("app.collapseAllStacksInCurrentQuery", defaultValue: "Collapse All Stacks in Current Query") : L10n.text("app.expandAllStacksInCurrentQuery", defaultValue: "Expand All Stacks in Current Query"))
        }
    }
    func selectStackMembers() {
        guard let stack = activeStack, let catalog else { return }
        perform {
            let ids = try catalog.resultIDs(query,within:Set(stack.members))
            choose(ids,active:activeID)
            showNotice(L10n.text("app.selectAllMatchingStackVersionsIncludingCollapsedMembersSubsequent", defaultValue: "Select all \(ids.count) matching stack versions, including collapsed members. Subsequent actions affect these \(ids.count) versions"))
        }
    }
    func selectAllResults() {
        guard let catalog else { return }
        perform { choose(Set(try catalog.allResultIDs(query)),active:activeID ?? photos.first?.id); showNotice(L10n.text("app.selectedAllQueryVersionsIncludingCollapsedMembersAndEvery", defaultValue: "Selected all \(selection.count) query versions, including collapsed members and every page")) }
    }
    func restoreStackSelection(_ ids: Set<String>, active: String?) {
        perform {
            guard let catalog else { return }
            let live = try catalog.resultIDs(query,within:ids)
            let representative = try active.flatMap { try catalog.representative(of:$0,query:query) }
            if let id = representative, let offset = try catalog.offset(of:id,query:query) { pageOffset = offset / pageSize * pageSize; try reloadPhotos() }
            let next = representative ?? photos.first?.id
            choose(live.isEmpty ? Set(next.map { [$0] } ?? []) : live,active:next)
        }
    }
    func restoreStackUndo(_ stacks: [PhotoStack], selection: Set<String>, active: String?) {
        guard let catalog, commitRecipe() else { return }
        perform {
            let previous = try catalog.restoreStacks(stacks), ids = self.selection, id = activeID
            undo.registerUndo(withTarget:self) { $0.restoreStackUndo(previous,selection:ids,active:id) }
            try reloadPhotos(); restoreStackSelection(selection,active:active)
        }
    }
    @discardableResult func applyAutoStacks(_ preview: AutoStackPreview) -> Bool {
        guard let catalog, !busy, commitRecipe() else { return false }
        do {
            guard !preview.groups.isEmpty else { return true }
            let previous = try catalog.applyAutoStacks(preview), ids = selection, id = activeID
            undo.registerUndo(withTarget:self) { $0.restoreStackUndo(previous,selection:ids,active:id) }
            undo.setActionName(L10n.text("app.autoStackByCaptureInterval", defaultValue: "Auto Stack by Capture Interval"))
            try reloadPhotos(); restoreStackSelection([],active:id)
            status = L10n.text("app.createdStacksVersionsUndoAsOneAction", defaultValue: "Created \(preview.groups.count) stacks · \(preview.photoCount) versions · Undo as one action")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
