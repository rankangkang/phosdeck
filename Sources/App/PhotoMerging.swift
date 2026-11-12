import Foundation
import Observation
import CoreGraphics

@MainActor @Observable final class PhotoMergeSession: Identifiable {
    let id = UUID()
    let catalog: CatalogStore
    let collectionID: String?
    var options = PhotoMergeOptions()
    var stackWithSources = true
    private(set) var inputs: [ImageRequest] = []
    private(set) var working = false
    private(set) var saving = false
    private(set) var progress = 0.0
    private(set) var phase = ""
    private(set) var preview: MergePreview?
    var previewEV = 0.0
    var directory: URL?
    var directoryBookmark: Data?
    var filename = ""
    var error: String?
    @ObservationIgnored private let engine = PhotoMergeEngine()
    @ObservationIgnored private var job: Task<Void,Never>?
    @ObservationIgnored private var displayJob: Task<Void,Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var displayToken = UUID()

    init(catalog: CatalogStore,ids: Set<String>,kind: PhotoMergeKind,collectionID: String? = nil) {
        self.catalog = catalog; self.collectionID = collectionID; options = .defaults(for: kind)
        working = true; phase = L10n.text("merge.loading", defaultValue:"Loading selected originals…")
        job = Task {
            do {
                let inputs = try await engine.loadInputs(catalog:catalog,ids:ids)
                try Task.checkCancellation()
                self.inputs = inputs
                let base = inputs.first.map { URL(fileURLWithPath:$0.photo.name).deletingPathExtension().lastPathComponent } ?? "Merged"
                filename = base+"-"+kind.suffix+"."+options.masterFormat.fileExtension
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            working = false; job = nil
        }
    }
    func invalidate() {
        if working && !saving { job?.cancel() }
        preview = nil; error = nil; displayJob?.cancel(); displayToken = UUID()
    }
    func applyModeDefaults() {
        options.align = options.kind.defaultAlignment; options.autoCrop = options.kind.isPanorama
        invalidate()
    }
    func updateFilenameExtension() {
        guard !filename.isEmpty else { return }
        filename = URL(fileURLWithPath:filename).deletingPathExtension().lastPathComponent+"."+options.masterFormat.fileExtension
    }
    func move(_ index: Int,by offset: Int) {
        guard !working,inputs.indices.contains(index),inputs.indices.contains(index+offset) else { return }
        inputs.swapAt(index,index+offset); invalidate()
    }
    func makePreview() {
        guard !working,!inputs.isEmpty else { return }
        displayJob?.cancel(); preview = nil; previewEV = 0; error = nil; working = true; saving = false; progress = 0
        let token = UUID(); self.token = token
        let inputs = inputs,options = options
        job = Task {
            do {
                let result = try await engine.prepare(inputs,options:options) { [weak self] value,phase in
                    await self?.report(value,phase:phase,token:token)
                }
                try Task.checkCancellation()
                guard self.token == token else { return }
                if self.options == options,self.inputs.map({ $0.photo.id }) == inputs.map({ $0.photo.id }) { preview = result }
            } catch is CancellationError { }
            catch { if self.token == token { self.error = error.localizedDescription } }
            if self.token == token { working = false; job = nil }
        }
    }
    func updateDisplay() {
        displayJob?.cancel()
        guard let preview,!working else { return }
        let token = UUID(); displayToken = token
        let ev = previewEV
        displayJob = Task {
            do {
                // Coalesce slider feedback into one latest request; at most one display
                // render runs on the serialized engine, plus one waiting request.
                try await Task.sleep(for:.milliseconds(80))
                let result = try await engine.display(preview.id,ev:ev)
                try Task.checkCancellation()
                if displayToken == token { self.preview = result }
            } catch is CancellationError { }
            catch { if displayToken == token { self.error = error.localizedDescription } }
        }
    }
    func save(completion: @escaping (MergeSaved) -> Void) {
        guard !working,let preview,let directoryBookmark else { return }
        displayJob?.cancel(); working = true; saving = true; progress = 0; error = nil
        let token = UUID(); self.token = token
        let filename = filename,stackWithSources = stackWithSources
        job = Task {
            do {
                let result = try await engine.save(preview.id,to:directoryBookmark,filename:filename,catalog:catalog,stackWithSources:stackWithSources,collectionID:collectionID) { [weak self] value,phase in
                    await self?.report(value,phase:phase,token:token)
                }
                guard self.token == token else { return }
                working = false; saving = false; job = nil
                completion(result)
            } catch is CancellationError {
                if self.token == token { working = false; saving = false; job = nil }
            } catch {
                if self.token == token { self.error = error.localizedDescription; working = false; saving = false; job = nil }
            }
        }
    }
    func cancel() {
        job?.cancel(); displayJob?.cancel(); displayToken = UUID()
        if working { phase = L10n.text("merge.cancelling", defaultValue:"Cancelling…") }
    }
    func cancelAndWait() async {
        let pending = job,display = displayJob
        cancel()
        await pending?.value; await display?.value
    }
    private func report(_ value: Double,phase: String,token: UUID) {
        guard self.token == token,job?.isCancelled != true else { return }
        progress = value; self.phase = phase
    }
}

extension AppModel {
    var canMergePhotos: Bool { workspaceAvailable && catalog != nil && (2...128).contains(selection.count) }
    func requestPhotoMerge(_ kind: PhotoMergeKind) {
        guard canMergePhotos,commitRecipe(),let catalog else { return }
        mergeSession = PhotoMergeSession(catalog:catalog,ids:selection,kind:kind,collectionID:regularCollectionID)
    }
    func completePhotoMerge(_ result: MergeSaved) {
        _ = completePhotoMerge(result, closedUndo: false)
    }
    func completePhotoMerge(_ result: MergeSaved, closedUndo: Bool) -> Bool {
        mergeSession = nil
        if let stacks = result.previousStacks {
            let previous = selection,active = activeID
            registerCatalogUndo(L10n.text("merge.stackUndo", defaultValue:"Stack Merged Photo"), closed: closedUndo) {
                $0.restoreStackUndo(stacks,selection:previous,active:active)
            }
        }
        do {
            let relocated = try revealMergedPhoto(result.photo.id)
            status = L10n.text("merge.completed", defaultValue:"Float master saved and added: \(result.url.lastPathComponent)")
            if relocated { status += L10n.text("merge.revealedAll", defaultValue:" · Shown in All Photos; return to your previous location with Back") }
            return true
        } catch {
            self.error = L10n.text("merge.savedRefreshFailed", defaultValue:"The master is saved and cataloged at \(result.url.path), but the workspace could not refresh: \(error.localizedDescription)")
            return false
        }
    }
}
