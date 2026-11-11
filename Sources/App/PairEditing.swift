import Foundation

extension AppModel {
    var activePair: RawJpegPair? { guard let photo = active else { return nil }; return try? catalog?.pair(sourceID:photo.sourceKey) }
    var partnerVersions: [Photo] {
        guard let photo = active, let source = activePair?.partner(of:photo.sourceKey) else { return [] }
        return (try? catalog?.versions(sourceID:source)) ?? []
    }
    func openPairing(within: Set<String>? = nil) { pairingScope = within; showPairing = true }
    @discardableResult func applyPairs(_ proposals: [PairProposal]) async -> Bool {
        guard let catalog, !busy, !applyingAdjustments, commitRecipe() else { return false }
        busy = true; defer { busy = false }
        do { return try await savePairs(proposals, catalog: catalog).refreshed }
        catch { self.error = error.localizedDescription; return false }
    }
    func savePairs(_ proposals: [PairProposal], catalog: CatalogStore, closedUndo: Bool = false) async throws
        -> (change: PairChange, refreshed: Bool) {
        let change = try await pairing.apply(proposals, catalog: catalog)
        guard self.catalog === catalog else { return (change, false) }
        let title = L10n.text("app.pairRAWJPEGSources", defaultValue: "Pair RAW/JPEG Sources")
        let refreshed = finishPairChange(change, title: title, closedUndo: closedUndo)
        if refreshed, change.previous != change.current {
            status = L10n.text("app.pairedSourcesIndependentEditsStacksPreserved", defaultValue: "Paired \(proposals.count) sources · Independent edits · Stacks preserved")
        }
        return (change, refreshed)
    }
    func unlinkPair(_ id: String) {
        guard !busy, commitRecipe() else { return }
        perform { _ = try removePair(id) }
    }
    func removePair(_ id: String, closedUndo: Bool = false) throws -> (change: PairChange, refreshed: Bool) {
        guard let catalog else { throw OrganizationError.photoUnavailable }
        let change = try catalog.unlinkPair(id)
        let title = L10n.text("app.unpairRAWJPEGSources", defaultValue: "Unpair RAW/JPEG Sources")
        return (change, finishPairChange(change, title: title, closedUndo: closedUndo))
    }
    private func finishPairChange(_ change: PairChange, title: String, closedUndo: Bool) -> Bool {
        guard change.previous != change.current else { return true }
        registerCatalogUndo(title, closed: closedUndo) { $0.restorePairUndo(change.previous, title: title) }
        return perform {
            try reload()
            status = L10n.text("app.rawJPEGPairingUpdatedPhotosVersionsEditsAndStacks", defaultValue: "RAW/JPEG pairing updated · Photos, versions, edits, and stacks preserved")
        }
    }
    private func restorePairUndo(_ values: [RawJpegPair], title: String) {
        guard let catalog, !busy, commitRecipe() else { return }
        perform {
            let inverse = try catalog.restorePairs(values)
            registerCatalogUndo(title, closed: false) { $0.restorePairUndo(inverse, title: title) }
            try reload(); status = L10n.text("app.rawJPEGPairingUpdatedPhotosVersionsEditsAndStacks", defaultValue: "RAW/JPEG pairing updated · Photos, versions, edits, and stacks preserved")
        }
    }
    func comparePartner(_ id: String) {
        guard let reference = active, partnerVersions.contains(where: { $0.id == id }), commitRecipe() else { return }
        if comparison != nil { endComparison() }
        // Navigation explicitly leaves the filter to reveal BOTH chosen versions.
        openVersion(reference.id)
        if let s = (try? catalog?.stacks())?.first(where: { $0.members.contains(id) }), s.collapsed { stackAction(.collapse([s.id],false),title:L10n.text("app.showPairedComparisonTargets", defaultValue: "Show Paired Comparison Targets")) }
        beginComparison(candidateID:id)
    }
    func stackPartner(_ id: String) {
        guard let photo = active, partnerVersions.contains(where: { $0.id == id }) else { return }
        stackAction(.group(top:photo.id,members:[id]),title:L10n.text("app.createMergePairedVersionStacks", defaultValue: "Create / Merge Paired Version Stacks"))
    }
}
