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
        do {
            let previous = try await pairing.apply(proposals,catalog:catalog)
            guard try catalog.pairs() != previous else { return true }
            undo.registerUndo(withTarget:self) { $0.restorePairUndo(previous) }
            undo.setActionName(L10n.text("app.pairRAWJPEGSources", defaultValue: "Pair RAW/JPEG Sources"))
            try reload()
            status = L10n.text("app.pairedSourcesIndependentEditsStacksPreserved", defaultValue: "Paired \(proposals.count) sources · Independent edits · Stacks preserved")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func unlinkPair(_ id: String) {
        guard let catalog, !busy, commitRecipe() else { return }
        perform { restorePairUndo(try catalog.pairs().filter { $0.id != id }); undo.setActionName(L10n.text("app.unpairRAWJPEGSources", defaultValue: "Unpair RAW/JPEG Sources")) }
    }
    private func restorePairUndo(_ values: [RawJpegPair]) {
        guard let catalog, !busy, commitRecipe() else { return }
        perform {
            let inverse = try catalog.restorePairs(values)
            undo.registerUndo(withTarget:self) { $0.restorePairUndo(inverse) }
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
