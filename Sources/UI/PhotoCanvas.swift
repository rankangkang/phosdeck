import SwiftUI

struct PhotoCanvas: View {
    static let fitPadding: CGFloat = 14
    @Bindable var model: AppModel
    var clippingPreview: ClippingVisibility?
    @AppStorage("photoMat") private var mat = PhotoMat.dark
    @State private var draft: Crop?
    @State private var dragOrigin: Crop?
    @State private var dragHandle: CropInteraction.Handle?
    private var displayImage: CGImage? {
        if let previous = model.photoSwitchDisplay { return previous.image }
        return model.cropMode == model.previewIsCrop ? (model.showPointColorRange && !model.pointSampling ? model.pointRangeImage ?? model.image : model.image) : nil
    }
    private var maskEditing: MaskCanvasEditing? {
        guard model.maskMode, model.previewingMaskID == nil, model.canvasCoordinatesCurrent, !model.before, let recipe = model.recipe, let size = model.orientedSourceSize else { return nil }
        var draftComponent: MaskComponent?
        if let session = model.smartMaskSession { var c = MaskComponent(tool: .object); c.id = session.id; c.raster = session.displayedRaster; draftComponent = c }
        let session = model.smartMaskSession
        let draftBox = session.flatMap { s in s.dragStart.flatMap { a in s.dragEnd.flatMap { SmartMaskField.region(a, $0) } } }
        return MaskCanvasEditing(group: session == nil ? model.selectedMask : model.smartMaskPreviewGroup,
                                 component: session != nil ? draftComponent : model.maskChoosingTool ? nil : model.selectedMaskComponent, recipe: recipe, sourceSize: size,
                                 reference: model.maskReference, showOverlay: model.showMaskOverlay || session?.inspectedRaster != nil, showGuides: model.showMaskGuides, color: model.maskOverlayColor,
                                 style: model.maskOverlayStyle,
                                 brushRadius: model.brushRadius, brushFeather: model.brushFeather, brushErase: model.brushErase,
                                 awaitingDraw: session != nil || (model.maskDrawNew && model.maskGesture == nil), sampling: model.maskSampling,
                                 smartPrompts: session?.prompts ?? [], smartBox: session?.mode == .box || session?.mode == .face ? draftBox : nil,
                                 smartInstruction: session?.pointerInstruction,
                                 smartAllowsPointer: session.map { $0.ready && ($0.workflow == .object || $0.mode == .face) } ?? true)
    }
    private var spotEditing: SpotCanvasEditing? {
        guard model.spotMode, model.canvasCoordinatesCurrent, !model.before, let recipe = model.recipe, let size = model.orientedSourceSize else { return nil }
        var offsets: [UUID: MaskPoint] = [:]
        for repair in recipe.repairs {
            if let offset = repair.sourceOffset ?? model.spotRenderedOffsets[repair.id] ?? model.spotGuides[repair.id] {
                offsets[repair.id] = offset
            }
        }
        return SpotCanvasEditing(repairs: recipe.repairs, offsets: offsets, selectedID: model.selectedSpotID, showGuides: model.showSpotGuides, recipe: recipe,
                                 sourceSize: size, radius: model.spotRadius, feather: model.spotFeather)
    }
    private var beforeAfter: BeforeAfterLayout { model.canShowBeforeAfter ? model.beforeAfter : .off }
    private var shadowWarning: Bool { !model.cropMode && !model.showPointColorRange && (clippingPreview?.shadows ?? model.showShadowClipping) }
    private var highlightWarning: Bool { !model.cropMode && !model.showPointColorRange && (clippingPreview?.highlights ?? model.showHighlightClipping) }
    private func pixelReadout(for source: CGImage?) -> ((DisplayPixelSample?) -> Void)? {
        guard source != nil, model.photoSwitchDisplay == nil, !model.cropMode, !model.showPointColorRange else { return nil }
        let photoID = model.activeID
        return { sample in
            guard model.activeID == photoID, model.image === source else { return }
            if model.displayPixelReadout != sample { model.displayPixelReadout = sample }
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if beforeAfter == .sideBySide {
                    HStack(spacing: 0) {
                        pane(model.beforeLabel, image: model.beforeImage, status: model.beforeStatus)
                        Seam(axis: .vertical)
                        pane(L10n.text("app.after", defaultValue: "After"), image: displayImage, status: model.imageStatus, after: true)
                    }
                } else {
                    MetalPhotoView(viewport: model.viewport, image: displayImage, actualPixels: model.fullResolution && !model.cropMode, photoID: model.photoSwitchDisplay?.photoID ?? model.activeID, nativeSize: model.photoSwitchDisplay?.nativeSize ?? model.renderedNativeSize, backdrop: mat.gray,
                                   zoomScale: model.zoomScale, fill: model.fillView && !model.cropMode,
                                   cropAngle: model.cropMode ? model.recipe?.cropPreviewAngle : nil,
                                   onClick: { model.toggleCanvasZoom(at: $0) },
                                   onZoneSample: model.whiteBalanceSampling ? { model.sampleWhiteBalance(at: $0) } : model.pointSampling ? { model.samplePointColor(at:$0) } : model.zoneSampling ? { model.sampleZone(at: $0) } : nil,
                                   maskEditing: maskEditing, onMaskPointer: { model.maskPointer($0, phase: $1, modifiers: $2, action: $3) },
                                   onMaskError: { model.error = $0 },
                                   spotEditing: spotEditing, onSpotPointer: { model.spotPointer($0, phase: $1, markerRadius: $2) },
                                   spotDraft: { model.spotCanvasDraft },
                                   clipping: model.showClipping && !model.cropMode && !model.showPointColorRange,
                                   clipShadows: shadowWarning, clipHighlights: highlightWarning,
                                   onPixelReadout: pixelReadout(for: displayImage),
                                   splitBefore: beforeAfter == .split ? model.beforeImage : nil)
                        .allowsHitTesting(model.photoSwitchDisplay == nil)
                    if model.photoSwitchDisplay != nil {
                        Text(L10n.text("app.loadingPreviousPhotoShown", defaultValue: "Loading photo… Previous photo shown"))
                            .font(.caption11).foregroundStyle(Color(nsColor: mat.textSecondary))
                            .padding(8).background(mat.color)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .allowsHitTesting(false)
                    }
                    if displayImage == nil {
                        VStack(spacing: 12) {
                            Text(model.imageStatus).foregroundStyle(Color(nsColor: mat.textSecondary))
                            if model.imageStatus.hasPrefix(L10n.text("app.originalMissingRatingsAndAdjustmentsPreserved", defaultValue: "Original missing; ratings and adjustments preserved")) || model.imageStatus.hasPrefix(L10n.text("app.theRootFolderIsMissingLocateItAgain", defaultValue: "The root folder is missing. Locate it again")) {
                                Button(L10n.text("app.locateOriginal_1644", defaultValue: "Locate Original…"), action: model.locateOriginal).buttonStyle(.key)
                                    .disabled(!model.canLocateOriginal).accessibilityIdentifier("locate-missing-original")
                            }
                        }.padding()
                    }
                    if beforeAfter == .split {
                        HStack {
                            paneLabel(model.beforeImage == nil ? model.beforeLabel + " · \(model.beforeStatus.isEmpty ? L10n.text("app.waitingForRendering", defaultValue: "Waiting for rendering") : model.beforeStatus)" : model.beforeLabel)
                            Spacer()
                            paneLabel(L10n.text("app.after", defaultValue: "After"))
                        }.frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                if model.cropMode, model.canvasCoordinatesCurrent, let image = displayImage, let recipe = model.recipe {
                    let frame = CropPreviewGeometry.outputFrame(size: CGSize(width: image.width, height: image.height),
                                                               canvas: geometry.size, degrees: recipe.cropPreviewAngle)
                    let size = frame.size
                    let crop = draft ?? recipe.cropInDisplay
                    Canvas { context, canvas in
                        let rect = CropInteraction.rect(crop, size: size).offsetBy(dx: frame.minX, dy: frame.minY)
                        var shade = Path(CGRect(origin: .zero, size: canvas)); shade.addRect(rect)
                        context.fill(shade, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                        context.stroke(Path(rect), with: .color(.white), lineWidth: 1)
                        if !recipe.perspective.isNeutral, recipe.perspective.constrainCrop, let sourceSize = model.orientedSourceSize {
                            var live = recipe; live.crop = recipe.cropFromDisplay(crop)
                            if let effective = live.effectiveCropInDisplay(size: sourceSize) {
                                let actual = CropInteraction.rect(effective, size: size).offsetBy(dx: frame.minX, dy: frame.minY)
                                context.stroke(Path(actual), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            }
                        }
                        var guides = Path()
                        for (start, end) in model.cropGuide.lines(in: rect) {
                            guides.move(to: start); guides.addLine(to: end)
                        }
                        context.stroke(guides, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
                        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                      CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
                                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                            context.fill(Path(CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(.white))
                        }
                    }.frame(width: geometry.size.width, height: geometry.size.height).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard model.canvasCoordinatesCurrent else { return }
                            if dragOrigin == nil {
                                dragOrigin = recipe.cropInDisplay
                                dragHandle = CropInteraction.hit(CGPoint(x: value.startLocation.x - frame.minX, y: value.startLocation.y - frame.minY), crop: recipe.cropInDisplay, size: size)
                            }
                            draft = CropInteraction.drag(dragOrigin ?? recipe.cropInDisplay, handle: dragHandle ?? .draw, from: CGPoint(x: value.startLocation.x - frame.minX, y: value.startLocation.y - frame.minY),
                                                         to: CGPoint(x: value.location.x - frame.minX, y: value.location.y - frame.minY), size: size, aspectRatio: recipe.cropAspectRatio)
                        }
                        .onEnded { _ in
                            if model.canvasCoordinatesCurrent, let draft { model.changeRecipe { $0.crop = $0.cropFromDisplay(draft) } }
                            draft = nil; dragOrigin = nil; dragHandle = nil
                        })
                    .help(L10n.text("app.dragTheSelectionToMoveOrItsCornersTo", defaultValue: "Drag the selection to move or its corners to resize. Drag outside it to create a new region"))
                    .allowsHitTesting(model.perspectiveGuideTool == nil)
                }
                if model.cropMode, model.perspectiveGuideTool != nil,
                   (model.canvasCoordinatesCurrent || model.perspectiveGuideDragOriginal != nil), let image = displayImage {
                    PerspectiveGuides(model: model, imageSize: CGSize(width: image.width, height: image.height), canvas: geometry.size)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)

        }
        .padding((model.fullResolution || model.fillView) && !model.cropMode ? 0 : Self.fitPadding)
        .background(mat.color)
        .onChange(of: model.activeID) { draft = nil; dragOrigin = nil; dragHandle = nil }
        .onChange(of: model.cropMode) { draft = nil; dragOrigin = nil; dragHandle = nil }
        .onChange(of: model.recipe?.flipHorizontal) { draft = nil; dragOrigin = nil; dragHandle = nil }
        .onChange(of: model.recipe?.flipVertical) { draft = nil; dragOrigin = nil; dragHandle = nil }
        .onChange(of: model.recipe?.quarterTurns) { draft = nil; dragOrigin = nil; dragHandle = nil }
        .onChange(of: model.recipe?.perspective) { draft = nil; dragOrigin = nil; dragHandle = nil }
        .onChange(of: model.recipe?.straightenDegrees) { draft = nil; dragOrigin = nil; dragHandle = nil }
    }
    private func pane(_ title: String, image: CGImage?, status: String, after: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            MetalPhotoView(viewport: model.viewport, image: image, actualPixels: model.fullResolution, photoID: model.activeID, nativeSize: model.renderedNativeSize, backdrop: mat.gray,
                           zoomScale: model.zoomScale, fill: model.fillView, onClick: { model.toggleCanvasZoom(at: $0) },
                           accessibilityName: L10n.text("app.canvas", defaultValue: "\(title) canvas"), clipping: model.showClipping,
                           clipShadows: shadowWarning, clipHighlights: highlightWarning,
                           onPixelReadout: after ? pixelReadout(for: image) : nil)
            if image == nil {
                Text(status.isEmpty ? L10n.text("app.waitingForRendering", defaultValue: "Waiting for rendering") : status).foregroundStyle(Color(nsColor: mat.textSecondary)).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            paneLabel(title)
        }
    }
    private func paneLabel(_ text: String) -> some View {
        Text(text).font(.caption11).foregroundStyle(Color(nsColor: mat.text))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(mat.color.opacity(0.85), in: RoundedRectangle(cornerRadius: 2))
            .padding(6).allowsHitTesting(false)
    }
    static func rectangle(from start: CGPoint, to end: CGPoint, size: CGSize) -> Crop {
        let x1 = min(1, max(0, start.x / max(1, size.width))), x2 = min(1, max(0, end.x / max(1, size.width)))
        let y1 = min(1, max(0, start.y / max(1, size.height))), y2 = min(1, max(0, end.y / max(1, size.height)))
        let width = max(0.01, abs(x2 - x1)), height = max(0.01, abs(y2 - y1))
        return Crop(x: min(min(x1, x2), 1 - width), y: min(1 - max(y1, y2), 1 - height), width: width, height: height)
    }
}

/// Histogram of the current preview in a recessed scope, with clip lamps and the capture readout.
struct HistogramScope: View {
    let histogram: ImageHistogram?
    let details: PhotoMetadata?
    var placeholder = L10n.text("app.waitingForPreview", defaultValue: "Waiting for preview")
    var clippingShown = false
    var shadowClippingShown: Bool?
    var highlightClippingShown: Bool?
    var toggleClipping: (() -> Void)?
    var toggleShadowClipping: (() -> Void)?
    var toggleHighlightClipping: (() -> Void)?
    var previewClipping: ((_ shadows: Bool, _ pressed: Bool) -> Void)?
    var pulseClipping: ((_ shadows: Bool) -> Void)?
    var pixelReadout: DisplayPixelSample?
    var compact = false
    var interactionID: String?
    /// Share of samples in the end bin of any channel that counts as clipping.
    static let clipShare = 0.001
    static func clipping(_ histogram: ImageHistogram?) -> (shadows: Bool, highlights: Bool) {
        guard let histogram, let first = histogram.channels.first else { return (false, false) }
        let total = max(1, first.reduce(0, +))
        let clipped = { (bin: Int) in histogram.channels.contains { $0.indices.contains(bin) && $0[bin] / total > clipShare } }
        return (clipped(0), clipped(first.count - 1))
    }
    private var readout: [String] {
        if let pixelReadout {
            return ["sRGB", pixelReadout.alpha == 0 ? L10n.text("app.transparent", defaultValue: "Transparent") : pixelReadout.rgbText]
                + (pixelReadout.alpha < 255 && pixelReadout.alpha > 0 ? ["α \(pixelReadout.alpha)"] : [])
        }
        let capture = PhotoViewingInfo.captureItems(details)
        return capture.isEmpty ? ["sRGB"] : capture
    }
    var body: some View {
        let clip = Self.clipping(histogram)
        let shadowShown = shadowClippingShown ?? clippingShown
        let highlightShown = highlightClippingShown ?? clippingShown
        VStack(spacing: 6) {
            if !compact {
                HStack(spacing: 12) {
                    Text(L10n.text("app.histogram_1659", defaultValue: "Histogram"))
                        .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize()
                    clippingControls(clip: clip, shadowShown: shadowShown, highlightShown: highlightShown)
                }
            }
            ScopeDisplay {
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        Canvas { context, size in
                            var grid = Path()
                            for i in 1..<4 {
                                let x = (size.width * Double(i) / 4).rounded() + 0.5
                                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                            }
                            context.stroke(grid, with: .color(Theme.scopeGrid), lineWidth: 1)
                            guard let histogram else { return }
                            let maximum = max(1, histogram.channels.flatMap { $0 }.max() ?? 1)
                            context.blendMode = .screen
                            for (index, values) in histogram.channels.enumerated() where index < Theme.traceRGB.count {
                                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                                for (bin, count) in values.enumerated() {
                                    path.addLine(to: CGPoint(x: Double(bin) / Double(max(1, values.count - 1)) * size.width,
                                                             y: size.height * (1 - sqrt(count / maximum))))
                                }
                                path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                                context.fill(path, with: .color(Theme.traceRGB[index].opacity(0.55)))
                            }
                        }
                        if compact {
                            clippingControls(clip: clip, shadowShown: shadowShown, highlightShown: highlightShown).padding(6)
                        }
                        if histogram == nil {
                            Text(placeholder).font(.caption11).foregroundStyle(Theme.scopeText).frame(maxHeight: .infinity)
                        }
                    }.frame(height: compact ? Metrics.histogramPlot.compact : Metrics.histogramPlot.regular)
                    if !compact {
                        Theme.scopeGrid.frame(height: 1)
                        HStack(spacing: 0) {
                            ForEach(Array(readout.enumerated()), id: \.offset) { _, item in
                                Text(item).frame(maxWidth: pixelReadout == nil ? .infinity : nil)
                            }
                        }
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.scopeText).lineLimit(1)
                        .frame(height: 23)
                    }
                }
            }
        }
        .help(histogram == nil ? L10n.text("app.histogram", defaultValue: "Histogram: \(placeholder)") : L10n.text("app.currentPreviewSRGBHistogramClippingKeyLamps", defaultValue: "Current preview · sRGB histogram. The key lamps light when clipping overlays are shown or a key is held"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("app.histogram_1659", defaultValue: "Histogram"))
        .accessibilityValue(histogram == nil ? placeholder : ([clip.shadows ? L10n.text("app.shadowClipping", defaultValue: "Shadow Clipping") : nil, clip.highlights ? L10n.text("app.highlightClipping", defaultValue: "Highlight Clipping") : nil,
                                                               shadowShown ? L10n.text("app.showShadowClippingOnPhoto", defaultValue: "Show Shadow Clipping on Photo") : nil,
                                                               highlightShown ? L10n.text("app.showHighlightClippingOnPhoto", defaultValue: "Show Highlight Clipping on Photo") : nil].compactMap { $0 } + readout).joined(separator: "，"))
        .accessibilityActions {
            if let toggle = toggleShadowClipping ?? toggleClipping {
                Button(shadowShown ? L10n.text("app.hideShadowClipping", defaultValue: "Hide Shadow Clipping") : L10n.text("app.showShadowClipping", defaultValue: "Show Shadow Clipping"), action: toggle)
            }
            if let toggle = toggleHighlightClipping ?? toggleClipping {
                Button(highlightShown ? L10n.text("app.hideHighlightClipping", defaultValue: "Hide Highlight Clipping") : L10n.text("app.showHighlightClipping", defaultValue: "Show Highlight Clipping"), action: toggle)
            }
            if let pulseClipping {
                Button(L10n.text("app.temporarilyInspectShadowClipping", defaultValue: "Temporarily Inspect Shadow Clipping")) { pulseClipping(true) }
                Button(L10n.text("app.temporarilyInspectHighlightClipping", defaultValue: "Temporarily Inspect Highlight Clipping")) { pulseClipping(false) }
            }
        }
    }
    private func clippingControls(clip: (shadows: Bool, highlights: Bool), shadowShown: Bool, highlightShown: Bool) -> some View {
        HStack(spacing: 4) {
            clipLamp(L10n.text("app.shadows_1650", defaultValue: "Shadows"), shadows: true,
                     on: clip.shadows, shown: shadowShown, toggle: toggleShadowClipping ?? toggleClipping)
            Spacer(minLength: 0)
            clipLamp(L10n.text("app.highlights", defaultValue: "Highlights"), shadows: false,
                     on: clip.highlights, shown: highlightShown, toggle: toggleHighlightClipping ?? toggleClipping)
        }
    }
    @ViewBuilder private func clipLamp(_ title: String, shadows: Bool, on: Bool, shown: Bool, toggle: (() -> Void)?) -> some View {
        let ink = compact ? Theme.scopeText : Theme.textSecondary
        let lamp = HStack(spacing: 4) {
            Lamp(on: shown, onScope: compact)
            Text(title).font(.system(size: 10)).foregroundStyle(ink)
        }
        .padding(.horizontal, 3).padding(.vertical, 1)
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(ink.opacity(shown ? 0.8 : 0), lineWidth: 1))
        if let toggle {
            HistogramClippingKey(title: title, detected: on, shown: shown,
                interactionID: interactionID, toggle: toggle,
                preview: previewClipping.map { callback in { callback(shadows, $0) } },
                pulse: pulseClipping.map { callback in { callback(shadows) } })
        } else {
            lamp.help(on ? L10n.text("app.clipped", defaultValue: "\(title) clipped") : L10n.text("app.notClipped", defaultValue: "\(title) not clipped"))
        }
    }
}

/// One labelled key: click latches the warning; Option-pressure is a temporary inspection.
struct HistogramClippingKey: View {
    let title: String
    let detected: Bool
    let shown: Bool
    var interactionID: String?
    let toggle: () -> Void
    var preview: ((Bool) -> Void)?
    var pulse: (() -> Void)?
    @Environment(\.isEnabled) private var enabled
    @State private var held = false
    private var detection: String {
        detected ? L10n.text("app.clipped", defaultValue: "\(title) clipped") : L10n.text("app.notClipped", defaultValue: "\(title) not clipped")
    }
    var body: some View {
        Button(action: toggle) {
            Text(title).fixedSize().frame(minWidth: (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width)
        }
        .buttonStyle(KeyButtonStyle(selected: shown, height: 18, padding: 6, held: held, lampInside: true))
        .fixedSize()
        .overlay {
            if let preview {
                MomentaryPreviewCapture(onPress: { pressed in held = pressed; preview(pressed) }, enabled: enabled,
                                        requiresOption: true, interactionID: interactionID)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(title)
        .onChange(of: interactionID) { held = false; preview?(false) }
        .accessibilityValue(L10n.text("app.clippingKeyState", defaultValue: "\(detection); overlay \(shown ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))"))
        .accessibilityActions {
            if let pulse {
                Button(L10n.text("app.temporarilyInspectClipping", defaultValue: "Temporarily inspect clipping"), action: pulse)
            }
        }
        .help(preview == nil ? L10n.text("app.clickToClipping", defaultValue: "\(detection); click to \(shown ? L10n.text("app.hide", defaultValue: "Hide") : L10n.text("app.show", defaultValue: "Show")) \(title) clipping") :
            L10n.text("app.clippingKeyHelp", defaultValue: "\(detection). Click to toggle the warning; Option-hold to inspect temporarily, release to restore."))
    }
}
