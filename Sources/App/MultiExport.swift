import Foundation

extension AppModel {
    /// Re-read the selected versions at submission, then prepare every output before freezing
    /// any source. No directory or task journal is created by this preflight operation.
    func prepareMultiExport(specifications: [ExportSpecification], directory: URL, photos: [Photo]) throws -> (ExportBatchPlan, [ExportSnapshot]) {
        guard let catalog, !photos.isEmpty, Set(photos.map(\.id)) == selection,
              Set(photos.map(\.id)).count == photos.count else { throw LRCError(L10n.text("app.theSelectionChangedReopenTheExportWindow", defaultValue: "The selection changed. Reopen the export window")) }
        let current = try photos.map { previous -> Photo in
            guard let photo = try catalog.photo(previous.id), !photo.deleted else { throw LRCError(L10n.text("app.selectedPhotosAreNoLongerInTheCatalog", defaultValue: "Selected photos are no longer in the catalog")) }
            return photo
        }
        let originalURLs = try catalog.photos().compactMap { photo in
            roots.first(where: { $0.id == photo.rootID }).map { URL(fileURLWithPath: $0.path).appendingPathComponent(photo.relativePath) }
        }
        let plan = try ExportBatchPlanner.plan(photos: current, specifications: specifications, directory: directory, originalURLs: originalURLs)
        guard plan.isReady else { throw LRCError(L10n.text("app.multipleSizeOutputWasNotQueued", defaultValue: "Multiple-size output was not queued: ") + plan.issues.prefix(5).joined(separator: "；")) }
        let descriptions = specifications.contains(where: { $0.options.metadataPolicy.includesDescription }) ? try catalog.exportDescriptions(ids: Set(current.map(\.id))) : [:]
        let bookmark = try AccessLease.bookmark(directory, readOnly: false)
        let snapshots = try plan.requests.map { item -> ExportSnapshot in
            let photo = item.photo
            guard let root = roots.first(where: { $0.id == photo.rootID }) else { throw LRCError(L10n.text("app.theOriginalPhotoRootFolderIsMissing", defaultValue: "The original photo root folder is missing")) }
            let recipe = try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) } ?? (photo.id == activeID ? self.recipe : nil)
            return ExportSnapshot(id: UUID().uuidString, request: ImageRequest(photo: photo, root: root, recipe: recipe),
                                  destination: item.destination, targetBookmark: bookmark, options: item.options,
                                  metadata: ExportMetadata(descriptive: item.options.metadataPolicy.includesDescription ? descriptions[photo.id] ?? ExportDescription() : ExportDescription()))
        }
        return (plan, snapshots)
    }

    @discardableResult
    func export(specifications: [ExportSpecification], directory: URL, access: AccessLease, photos: [Photo]) -> Bool {
        guard !busy, commitRecipe(), let catalog else { return false }
        do {
            guard ExportBatchPlanner.canonicalKey(access.url) == ExportBatchPlanner.canonicalKey(directory) else { throw LRCError(L10n.text("app.theAuthorizedParentDestinationDiffersFromYourSelectionChoose", defaultValue: "The authorized parent destination differs from your selection. Choose the folder again")) }
            let (plan, snapshots) = try prepareMultiExport(specifications: specifications, directory: directory, photos: photos)
            beginExportPreparation(L10n.text("app.freezingMultipleSizeOutputsNotYetQueued", defaultValue: "Freezing multiple-size outputs · \(plan.summary) · Not yet queued"))
            task = Task {
                defer { busy = false; taskProgress = nil; withExtendedLifetime(access) {} }
                do {
                    var frozen = [ExportSnapshot]()
                    for (index, snapshot) in snapshots.enumerated() {
                        try Task.checkCancellation()
                        taskProgress = TaskProgress(title: L10n.text("app.prepareMultipleSizeOutput", defaultValue: "Prepare Multiple-Size Output"), done: index, total: snapshots.count)
                        frozen.append(try await pipeline.freezeExport(snapshot))
                    }
                    try ExportBatchPlanner.prepareDestinations(plan)
                    exportOperationCounts = ExportOperationCounts()
                    reports = await ExportService(pipeline: pipeline).run(frozen, catalog: catalog, step: { [self] done, total in
                        await MainActor.run { taskProgress = TaskProgress(title: L10n.text("app.multipleSizeOutput", defaultValue: "Multiple-Size Output"), done: done, total: total) }
                    }, outcome: { [self] in exportOperationCounts.record($0) }) { [self] text in await MainActor.run { status = text } }
                    perform { try recordExportResult(ids: Set(frozen.map(\.id))) }
                    status = lastExportResult?.summary ?? L10n.text("app.outputFinishedReviewTheTaskResults", defaultValue: "Output finished. Review the task results")
                } catch {
                    reports = [Task.isCancelled ? L10n.text("app.multipleSizeOutputPreparationCancelledNothingQueued", defaultValue: "Multiple-size output preparation cancelled; nothing queued") : L10n.text("app.multipleSizeOutputPreparationFailedNothingQueued", defaultValue: "Multiple-size output preparation failed; nothing queued: \(error.localizedDescription)")]
                    status = reports[0]
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
