import SwiftUI

/// Two independent viewports: geometry changes must never feed back into the other pane.
@MainActor
final class PhotoComparison: ObservableObject {
    let reference = ComparisonPhoto()
    let candidate = ComparisonPhoto()
    @Published var linked = true
    var groupIDs: [String]?
    @Published var restrictToGroup = false
    let render: (ImageRequest, Int?) async throws -> RenderedImage

    init(render: @escaping (ImageRequest, Int?) async throws -> RenderedImage) { self.render = render }

    func selectZoom(_ scale: Double?, in pane: ComparisonPhoto, focus: CGPoint? = nil) {
        if let scale, !AppModel.zoomScales.contains(scale) { return }
        let point = focus ?? pane.viewport.center
        for target in linked ? [reference, candidate] : [pane] {
            let changedResolution = (target.zoom == nil) != (scale == nil)
            target.zoom = scale
            if scale == nil { target.viewport.reset() }
            else { target.viewport.focusOnNextGeometry(point) }
            if changedResolution { target.load(render: render) }
        }
    }
    func toggleZoom(in pane: ComparisonPhoto, at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        selectZoom(pane.zoom == nil ? 1 : nil, in: pane, focus: point)
    }
    func pan(from pane: ComparisonPhoto, to point: CGPoint) {
        guard linked else { return }
        let other = pane === reference ? candidate : reference
        other.viewport.move(to: point)
    }
    func setLinked(_ value: Bool) {
        linked = value
        if value { selectZoom(candidate.zoom, in: candidate) }
    }
    func update(_ pane: ComparisonPhoto, photo: Photo?, roots: [StorageRoot]) {
        let old = pane.photo
        let root = roots.first { $0.id == photo?.rootID }
        let changed = old?.id != photo?.id || old?.identity != photo?.identity || old?.digest != photo?.digest ||
            old?.relativePath != photo?.relativePath || old?.recipe != photo?.recipe || old?.availability != photo?.availability ||
            pane.root?.bookmark != root?.bookmark
        pane.photo = photo; pane.root = root
        if changed {
            pane.cancel()
            if linked { pane.viewport.focusOnNextGeometry((pane === candidate ? reference : candidate).viewport.center) }
            else { pane.viewport.reset() }
            pane.load(render: render)
        }
    }
    func cancel() { reference.cancel(); candidate.cancel() }
}

/// A chosen group can be large; only the current nine previews have render tasks and pixels.
@MainActor
final class PhotoSurvey: ObservableObject {
    static let pageSize = 9
    var members: [String]
    @Published var ids: [String]
    @Published var offset = 0
    @Published var tiles: [ComparisonPhoto] = []
    let renderer: PhotoComparison
    init(ids: [String], renderer: PhotoComparison) { self.members = ids; self.ids = ids; self.renderer = renderer }
    var visibleIDs: [String] { Array(ids.dropFirst(offset).prefix(Self.pageSize)) }
    func update(photos: [Photo], roots: [StorageRoot]) {
        let old = Dictionary(uniqueKeysWithValues: tiles.compactMap { tile in tile.photo.map { ($0.id, tile) } })
        let shown = Set(photos.map(\.id))
        for (id,tile) in old where !shown.contains(id) { tile.cancel() }
        tiles = photos.map { photo in
            let pane = old[photo.id] ?? ComparisonPhoto()
            renderer.update(pane, photo: photo, roots: roots)
            return pane
        }
    }
    func cancel() { tiles.forEach { $0.cancel() }; tiles = [] }
}

struct PhotoSurveyView: View {
    @Bindable var model: AppModel
    @ObservedObject var survey: PhotoSurvey
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    static func columns(count: Int, size: CGSize) -> Int {
        (1...max(1,count)).max { a,b in
            min(size.width / Double(a), size.height / ceil(Double(count) / Double(a)) * 1.5) <
            min(size.width / Double(b), size.height / ceil(Double(count) / Double(b)) * 1.5)
        } ?? 1
    }
    var body: some View {
        GeometryReader { geometry in
            if survey.tiles.isEmpty {
                VStack(spacing: 12) {
                    Text(L10n.text("app.noCandidatePhotos", defaultValue: "No candidate photos")).foregroundStyle(Color(nsColor: mat.text))
                    Button(L10n.text("app.returnToGrid", defaultValue: "Return to Grid")) { model.selectWorkspace(.grid) }.buttonStyle(.key)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let columns = Self.columns(count: survey.tiles.count, size: geometry.size)
                let rows = Int(ceil(Double(survey.tiles.count) / Double(columns)))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                    ForEach(survey.tiles, id: \.photo?.id) { pane in
                        SurveyTile(model: model, pane: pane, mat: mat)
                            .frame(height: max(80, (geometry.size.height - 12 - CGFloat(rows - 1) * 6) / CGFloat(rows)))
                    }
                }.padding(6)
            }
        }.background(mat.color)
    }
}

private struct SurveyTile: View {
    @Bindable var model: AppModel
    @ObservedObject var pane: ComparisonPhoto
    let mat: PhotoMat
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                MetalPhotoView(viewport: pane.viewport, image: pane.image, actualPixels: false, photoID: pane.photo?.id,
                    nativeSize: pane.nativeSize, backdrop: mat.gray,
                    onClick: { _ in if let id = pane.photo?.id { model.activateSurveyPhoto(id) } }, accessibilityName: L10n.text("app.survey", defaultValue: "Survey: ") + (pane.photo?.displayName ?? L10n.text("app.photo", defaultValue: "Photo")))
                if !pane.status.isEmpty { Text(pane.status).font(.caption11).foregroundStyle(Color(nsColor: mat.text)).padding().allowsHitTesting(false) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(4)
            HStack(spacing: 4) {
                Button { if let id = pane.photo?.id { model.activateSurveyPhoto(id) } } label: {
                    Text(pane.photo?.displayName ?? L10n.text("app.photo", defaultValue: "Photo")).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.plain).accessibilityLabel(L10n.text("app.makeActivePhoto", defaultValue: "Make Active Photo ") + (pane.photo?.displayName ?? ""))
                Spacer(minLength: 2)
                if let photo = pane.photo {
                    if photo.flag != 0 { Image(systemName: photo.flag == 1 ? "flag.fill" : "xmark") }
                    if photo.rating > 0 { Text(String(repeating: "★", count: photo.rating)) }
                    Button { model.removeFromSurvey(photo.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.key(height: 18, padding: 4)).accessibilityLabel(L10n.text("app.removeFromSurvey", defaultValue: "Remove from Survey ") + photo.displayName)
                        .help(L10n.text("app.removeFromCandidatesWhilePreservingThePhotoAndOriginal", defaultValue: "Remove from candidates while preserving the photo and original"))
                }
            }.font(.caption11).padding(.horizontal, 6).frame(height: 26)
        }.foregroundStyle(Color(nsColor: mat.text)).background(mat.color)
            .overlay(Rectangle().strokeBorder(Color(nsColor: mat.text).opacity(model.activeID == pane.photo?.id ? 0.9 : 0.2), lineWidth: model.activeID == pane.photo?.id ? 2 : 0.5))
    }
}

@MainActor
final class ComparisonPhoto: ObservableObject {
    @Published var photo: Photo?
    @Published var image: CGImage?
    @Published var nativeSize: CGSize?
    @Published var zoom: Double?
    @Published var status = L10n.text("app.noPhotosToCompare", defaultValue: "No photos to compare")
    let viewport = PhotoViewport()
    var root: StorageRoot?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func cancel() {
        task?.cancel(); task = nil; generation = UUID()
        image = nil; nativeSize = nil
    }
    func load(render: @escaping (ImageRequest, Int?) async throws -> RenderedImage) {
        task?.cancel(); generation = UUID()
        guard let photo else { status = L10n.text("app.noPhotosToCompare", defaultValue: "No photos to compare"); return }
        guard let root else { status = L10n.text("app.cannotFindThePhotoSource", defaultValue: "Cannot find the photo source"); return }
        let token = generation, edge: Int? = zoom == nil ? 2400 : nil
        status = edge == nil ? L10n.text("app.loadingFullSize", defaultValue: "Loading full size…") : L10n.text("app.loadingPhoto", defaultValue: "Loading photo…")
        task = Task { [weak self] in
            do {
                let recipe = try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) }
                try recipe?.validate()
                let result = try await render(ImageRequest(photo: photo, root: root, recipe: recipe), edge)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.image = result.image; self.nativeSize = result.fullSize; self.status = ""; self.task = nil
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.image = nil; self.nativeSize = nil; self.status = error.localizedDescription; self.task = nil
            }
        }
    }
}

struct PhotoComparisonView: View {
    @Bindable var model: AppModel
    @ObservedObject var comparison: PhotoComparison
    var body: some View {
        HStack(spacing: 0) {
            ComparisonPane(comparison: comparison, pane: comparison.reference, title: L10n.text("app.reference_1681", defaultValue: "Reference"), note: L10n.text("app.pinned", defaultValue: "Pinned"))
            Seam(axis: .vertical)
            ComparisonPane(comparison: comparison, pane: comparison.candidate, title: L10n.text("app.candidate", defaultValue: "Candidate"), note: L10n.text("app.switch", defaultValue: "← → Switch"))
        }
    }
}

/// Hovering a saved state never borrows the editable canvas or its viewport.
struct SavedEditNavigatorView: View {
    @ObservedObject var preview: ComparisonPhoto
    let title: String
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    var body: some View {
        VStack(spacing: 4) {
            if let image = preview.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Text(preview.status).font(.caption11).foregroundStyle(Color(nsColor: mat.textSecondary)).frame(maxHeight: .infinity)
            }
            Text(L10n.text("app.preview_1685", defaultValue: "Preview · ") + title).font(.caption11).foregroundStyle(Color(nsColor: mat.textSecondary)).lineLimit(1)
        }.padding(8).accessibilityElement(children: .combine).accessibilityLabel(L10n.text("app.navigatorPreview", defaultValue: "Navigator preview: ") + title)
    }
}

/// The reference has its own immutable look and viewport. Only the right canvas
/// receives the editing model, mask pointers, crop gestures or repair tools.
struct DevelopReferenceView: View {
    @Bindable var model: AppModel
    @ObservedObject var reference: ComparisonPhoto
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(L10n.text("app.referencePinned", defaultValue: "Reference · Pinned")).fontWeight(.semibold).lineLimit(1)
                    Menu {
                        Button(L10n.text("app.useCurrentPhotoAsReference", defaultValue: "Use Current Photo as Reference"), action: model.pinActiveAsDevelopReference).disabled(!model.canEdit)
                        Button(L10n.text("app.clearReference", defaultValue: "Clear Reference"), action: model.clearDevelopReference)
                    } label: { Image(systemName: "pin.fill").accessibilityLabel(L10n.text("app.replaceDevelopReference", defaultValue: "Replace Develop Reference")) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Theme.textSecondary)
                        .accessibilityLabel(L10n.text("app.replaceDevelopReference", defaultValue: "Replace Develop Reference")).help(L10n.text("app.adjustmentsRemainAsPinnedReplaceTheReferenceWithThe", defaultValue: "Adjustments remain as pinned. Replace the reference with the current photo if needed"))
                    Spacer(minLength: 4)
                    HStack(spacing: -1) {
                        Button { model.selectDevelopReferenceZoom(nil) } label: { Text(L10n.text("app.fit_1691", defaultValue: "Fit")) }
                            .buttonStyle(.key(selected: reference.zoom == nil, position: .leading, height: 22, padding: 6))
                            .accessibilityLabel(L10n.text("app.fitReferenceToWindow", defaultValue: "Fit Reference to Window"))
                        Menu {
                            ForEach(AppModel.zoomScales, id: \.self) { scale in
                                Button(AppModel.zoomLabel(scale)) { model.selectDevelopReferenceZoom(scale) }
                            }
                        } label: { Text(reference.zoom.map(AppModel.zoomLabel) ?? "100%").monospacedDigit() }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Theme.text).fixedSize()
                            .keySurface(position: .trailing, height: 22, selected: reference.zoom != nil)
                            .accessibilityLabel(L10n.text("app.referenceZoom", defaultValue: "Reference Zoom"))
                    }.disabled(!model.workspaceAvailable)
                }.font(.caption11).padding(.horizontal, 10).frame(height: Metrics.row).background(Theme.panel)
                ZStack {
                    MetalPhotoView(viewport: reference.viewport, image: reference.image, actualPixels: reference.zoom != nil,
                        photoID: reference.photo?.id, nativeSize: reference.nativeSize, backdrop: mat.gray,
                        zoomScale: reference.zoom ?? 1,
                        onClick: { model.selectDevelopReferenceZoom(reference.zoom == nil ? 1 : nil, focus: $0) },
                        accessibilityName: L10n.text("app.developReferenceCanvas", defaultValue: "Develop Reference Canvas"))
                    if !reference.status.isEmpty {
                        Text(reference.status).font(.caption11).multilineTextAlignment(.center).padding(16)
                            .foregroundStyle(Color(nsColor: mat.text)).allowsHitTesting(false)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .padding(reference.zoom == nil ? PhotoCanvas.fitPadding : 0).background(mat.color)
                caption(reference.photo?.displayName ?? L10n.text("app.reference_1681", defaultValue: "Reference"), path: reference.photo?.relativePath ?? "")
            }.frame(maxWidth: .infinity)
            Seam(axis: .vertical)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(L10n.text("app.currentEdit", defaultValue: "Current Edit")).fontWeight(.semibold)
                    Spacer(minLength: 4)
                    Button(L10n.text("app.exitReference", defaultValue: "Exit Reference"), action: model.endDevelopReference).buttonStyle(.key(height: 22, padding: 6))
                        .accessibilityIdentifier("develop-reference-done").help(L10n.text("app.exitReferenceREscRetainThePinnedPhotoFor", defaultValue: "Exit reference (⇧R / Esc); retain the pinned photo for next time"))
                        .disabled(!model.workspaceAvailable)
                }.font(.caption11).padding(.horizontal, 10).frame(height: Metrics.row).background(Theme.panel)
                PhotoCanvas(model: model)
                caption(model.active?.displayName ?? L10n.text("app.chooseAPhotoToEdit", defaultValue: "Choose a photo to edit"), path: model.active?.relativePath ?? "")
            }.frame(maxWidth: .infinity)
        }.background(mat.color)
    }
    private func caption(_ text: String, path: String) -> some View {
        Text(text).font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            .help(path).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 24).background(Theme.panel)
    }
}

/// Comparison actions shown in the centre toolbar, where Lightroom Classic keeps them.
struct ComparisonToolbarControls: View {
    @Bindable var model: AppModel
    @ObservedObject var comparison: PhotoComparison
    var compact = false
    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button(L10n.text("app.allCurrentResults", defaultValue: "All Current Results")) { model.restrictComparisonToGroup(false) }
                if let group = comparison.groupIDs { Button(L10n.text("app.onlyThePhotosSelectedWhenEnteringCompare", defaultValue: "Only the \(group.count) Photos Selected When Entering Compare")) { model.restrictComparisonToGroup(true) } }
            } label: { Text(comparison.restrictToGroup ? L10n.text("app.selectedPhotos", defaultValue: "\(comparison.groupIDs?.count ?? 0) selected photos") : L10n.text("app.allResults", defaultValue: "All Results")) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().keySurface(height: 22)
                .accessibilityLabel(L10n.text("app.compareScope", defaultValue: "Compare Scope"))
            Toggle(compact ? L10n.text("app.linked", defaultValue: "Linked") : L10n.text("app.syncZoom", defaultValue: "Sync Zoom"), isOn: Binding(get: { comparison.linked }, set: comparison.setLinked))
                .toggleStyle(.instrument).help(L10n.text("app.synchronizeZoomAndPanOnBothSides", defaultValue: "Synchronize zoom and pan on both sides")).accessibilityIdentifier("comparison-link")
            Button(action: model.swapComparison) { if compact { Image(systemName: "arrow.down") } else { Text(L10n.text("app.swap", defaultValue: "Swap")) } }
                .buttonStyle(.key(height: 22)).accessibilityLabel(L10n.text("app.swapReferenceAndCandidate", defaultValue: "Swap Reference and Candidate"))
                .help(L10n.text("app.swapReferenceAndCandidate_1708", defaultValue: "Swap reference and candidate (↓)"))
                .disabled(comparison.reference.photo == nil || comparison.candidate.photo == nil)
            Button(action: model.promoteComparisonCandidate) { if compact { Image(systemName: "arrow.up") } else { Text(L10n.text("app.keepAndContinue", defaultValue: "Keep and Continue")) } }
                .buttonStyle(.key(height: 22)).accessibilityLabel(L10n.text("app.keepCandidateAndContinue", defaultValue: "Keep Candidate and Continue"))
                .help(L10n.text("app.promoteTheCandidateToReferenceAndCompareTheNext", defaultValue: "Promote the candidate to reference and compare the next photo (↑)")).disabled(comparison.candidate.photo == nil)
            Button(L10n.text("app.done", defaultValue: "Done"), action: model.endComparison).buttonStyle(.key(height: 22)).help(L10n.text("app.exitCompareEscE", defaultValue: "Exit Compare (Esc / E)"))
                .accessibilityIdentifier("comparison-done")
        }.fixedSize()
    }
}

struct SurveyToolbarControls: View {
    @Bindable var model: AppModel
    @ObservedObject var survey: PhotoSurvey
    var body: some View {
        HStack(spacing: 6) {
            Text(L10n.text("app.surveyPhotos", defaultValue: "Survey \(survey.ids.count) Photos")).font(.caption11).fixedSize().help(L10n.text("app.flagsAndRatingsAffectTheActivePhotoOnlyRemoves", defaultValue: "Flags and ratings affect the active photo only. / removes the current candidate while preserving the photo"))
            if survey.ids.count > PhotoSurvey.pageSize {
                Button { model.changeSurveyPage(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.key(height: 22, padding: 5)).accessibilityLabel(L10n.text("app.previousCandidates", defaultValue: "Previous Candidates")).disabled(survey.offset == 0)
                Text("\(survey.offset + 1)–\(min(survey.ids.count, survey.offset + PhotoSurvey.pageSize))").font(.caption11).monospacedDigit().fixedSize()
                Button { model.changeSurveyPage(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.key(height: 22, padding: 5)).accessibilityLabel(L10n.text("app.nextCandidates", defaultValue: "Next Candidates")).disabled(survey.offset + PhotoSurvey.pageSize >= survey.ids.count)
            }
            Button(L10n.text("app.done", defaultValue: "Done")) { model.selectWorkspace(.grid) }.buttonStyle(.key(height: 22)).help(L10n.text("app.returnToGridAndRetainRemainingCandidateSelectionEsc", defaultValue: "Return to Grid and retain remaining candidate selection (Esc)"))
        }.fixedSize()
    }
}

private struct ComparisonPane: View {
    @ObservedObject var comparison: PhotoComparison
    @ObservedObject var pane: ComparisonPhoto
    let title: String
    let note: String
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .keyCenter, spacing: 6) {
                Text(title).fontWeight(.semibold).fixedSize()
                Text(note).font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: -1) {
                    Button { comparison.selectZoom(nil, in: pane) } label: { LampLabel(on: pane.zoom == nil) { Text(L10n.text("app.fit_1691", defaultValue: "Fit")) } }
                        .buttonStyle(.key(selected: pane.zoom == nil, position: .leading, height: 22, padding: 8))
                        .accessibilityLabel(L10n.text("app.fit_1691", defaultValue: "Fit")).accessibilityAddTraits(pane.zoom == nil ? .isSelected : [])
                    LampLabel(on: pane.zoom != nil) {
                        Menu {
                            ForEach(AppModel.zoomScales, id: \.self) { scale in
                                Button(AppModel.zoomLabel(scale)) { comparison.selectZoom(scale, in: pane) }
                            }
                        } label: { Text(pane.zoom.map(AppModel.zoomLabel) ?? "100%").monospacedDigit() }
                            .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize()
                    }
                        .keySurface(position: .trailing, height: 22, selected: pane.zoom != nil)
                        .accessibilityLabel(L10n.text("app.zoom", defaultValue: "Zoom"))
                }.help(L10n.text("app.zoomLevelClickThePhotoToToggleFitAnd", defaultValue: "Zoom level; click the photo to toggle Fit and 100%"))
            }.padding(.horizontal, 12).frame(height: Metrics.toolbar).background(Theme.panel)
            ZStack {
                MetalPhotoView(viewport: pane.viewport, image: pane.image, actualPixels: pane.zoom != nil,
                               photoID: pane.photo?.id, nativeSize: pane.nativeSize, backdrop: mat.gray,
                               zoomScale: pane.zoom ?? 1,
                               onClick: { comparison.toggleZoom(in: pane, at: $0) },
                               onPan: { comparison.pan(from: pane, to: $0) }, accessibilityName: title + L10n.text("app.canvas_1720", defaultValue: "Canvas"))
                if !pane.status.isEmpty {
                    Text(pane.status).multilineTextAlignment(.center).padding(12)
                        .foregroundStyle(Color(nsColor: mat.text))
                        .padding(16).allowsHitTesting(false)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            HStack(spacing: 8) {
                if let photo = pane.photo {
                    Text((photo.isRAW ? "RAW · " : ["jpg","jpeg"].contains(URL(fileURLWithPath:photo.relativePath).pathExtension.lowercased()) ? "JPEG · " : "") + photo.displayName).lineLimit(1).truncationMode(.middle).help(photo.relativePath)
                    Spacer(minLength: 4)
                    if photo.flag != 0 {
                        Image(systemName: photo.flag == 1 ? "flag.fill" : "xmark")
                            .accessibilityLabel(photo.flag == 1 ? L10n.text("app.pick", defaultValue: "Pick") : L10n.text("app.reject", defaultValue: "Reject"))
                    }
                    Text(photo.rating == 0 ? L10n.text("app.unrated", defaultValue: "Unrated") : String(repeating: "★", count: photo.rating))
                        .accessibilityLabel(L10n.text("app.stars_1722", defaultValue: "\(photo.rating) Stars"))
                }
            }.font(.caption11).foregroundStyle(Theme.textSecondary).padding(.horizontal, 12).frame(height: 30).background(Theme.panel)
        }.frame(maxWidth: .infinity).background(mat.color)
    }
}
