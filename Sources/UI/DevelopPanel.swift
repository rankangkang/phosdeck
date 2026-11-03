import SwiftUI
import AppKit

struct DevelopPanel: View {
    @Bindable var model: AppModel
    var local = false
    /// The owner supplies the display-only recipe swap.  Keeping this as a
    /// callback lets the panel remain independent of AppModel's preview
    /// lifecycle while the actual recipe/history/export state stays untouched.
    var onPreviewGroup: ((DevelopGroup, Bool) -> Void)? = nil
    var onPulsePreviewGroup: ((DevelopGroup) -> Void)? = nil
    var previewingGroup: DevelopGroup? = nil
    var onOpenGroup: ((DevelopGroup) -> Void)? = nil
    private var recipe: EditRecipe? {
        guard let source = model.recipe else { return nil }
        return local ? model.selectedMask?.editingRecipe(from: source) : source
    }
    private func change(_ edit: (inout EditRecipe) -> Void, commit: Bool = true) {
        if local { model.changeLocalDevelop(edit, commit: commit) }
        else { model.changeRecipe(edit, commit: commit) }
    }
    @AppStorage("developBasicOpen") private var basicOpen = true
    @AppStorage("developCropOpen") private var cropOpen = false
    @AppStorage("developPerspectiveOpen") private var perspectiveOpen = false
    @AppStorage("developMixerOpen") private var mixerOpen = false
    @AppStorage("developGradingOpen") private var gradingOpen = false
    @AppStorage("developBlackWhiteMixerOpen") private var blackWhiteOpen = false
    @AppStorage("developNoiseOpen") private var noiseOpen = false
    @AppStorage("developSharpenOpen") private var sharpenOpen = false
    @AppStorage("developDetailsOpen") private var detailsOpen = false
    @AppStorage("developCurvesOpen") private var curvesOpen = false
    @AppStorage("developZonesOpen") private var zonesOpen = false
    @AppStorage("developVignetteOpen") private var vignetteOpen = false
    @AppStorage("developGrainOpen") private var grainOpen = false
    @AppStorage("developPointColorOpen") private var pointOpen = false
    @AppStorage("developSoloMode") private var solo = false
    @AppStorage("developShowOnlyModified") private var showOnlyModified = false
    @State private var legacyDetails = false
    @State private var mixerTab = 0
    @State private var gradingTab = 0
    private let cropRatios: [Double] = [1, 1.5, 4.0/3, 16.0/9, 4.0/5, 2.0/3]
    private var modifiedGroups: Set<DevelopGroup> { recipe?.modifiedDevelopGroups ?? [] }
    private func isModified(_ group: DevelopGroup) -> Bool { modifiedGroups.contains(group) }
    private func isVisible(_ group: DevelopGroup) -> Bool { !showOnlyModified || local || isModified(group) }
    private func previewHandler(_ group: DevelopGroup) -> ((Bool) -> Void)? {
        guard !local, group != .crop, group != .perspective,
              isModified(group), let callback = onPreviewGroup else { return nil }
        return { pressed in callback(group, pressed) }
    }
    private func previewPulseHandler(_ group: DevelopGroup) -> (() -> Void)? {
        guard !local, group != .crop, group != .perspective,
              isModified(group), let callback = onPulsePreviewGroup else { return nil }
        return { callback(group) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !local { panelToolbar }
            if !local, let recipe = recipe, recipe.pipelineVersion < 2 {
                HStack {
                    Text(L10n.text("app.legacyDevelopment", defaultValue: "Legacy Development")).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button { legacyDetails.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                        .help(L10n.text("app.viewDevelopmentVersionNotes", defaultValue: "View Development Version Notes")).accessibilityLabel(L10n.text("app.developmentVersionNotes", defaultValue: "Development Version Notes"))
                        .popover(isPresented: $legacyDetails) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text("app.thisPhotoRetainsItsLegacyDevelopmentAppearance", defaultValue: "This photo retains its legacy development appearance"))
                                Text(L10n.text("app.switchingKeepsTheParametersButMayChangeTheAppearance", defaultValue: "Switching keeps the parameters but may change the appearance. You can undo this."))
                                    .font(.caption11).foregroundStyle(Theme.textSecondary)
                                Button(L10n.text("app.useCurrentDevelopment", defaultValue: "Use Current Development")) {
                                    change { $0.pipelineVersion = 2 }; legacyDetails = false
                                }.buttonStyle(.key)
                            }.padding(16).frame(width: 280)
                        }
                }.font(.caption11).padding(.horizontal, 12).frame(height: 24)
                Seam()
            }
            if !local && model.cropMode {
                if isVisible(.crop) { PanelSection(L10n.text("app.cropStraightenAndFlip", defaultValue: "Crop, Straighten, and Flip"), group: .crop, isExpanded: $cropOpen, reset: {
                    change { $0.crop = Crop(); $0.quarterTurns = 0; $0.straightenDegrees = 0; $0.cropAspectRatio = nil; $0.flipHorizontal = false; $0.flipVertical = false }
                }, modified: isModified(.crop), previewing: previewingGroup == .crop, preview: previewHandler(.crop), previewPulse: previewPulseHandler(.crop)) { crop.sectionContent() } }
                if isVisible(.perspective) { PanelSection(L10n.text("app.manualPerspective", defaultValue: "Manual Perspective"), group: .perspective, isExpanded: $perspectiveOpen, reset: { change { $0.perspective = PerspectiveSettings() } }, modified: isModified(.perspective), previewing: previewingGroup == .perspective, preview: previewHandler(.perspective), previewPulse: previewPulseHandler(.perspective)) {
                    perspective.sectionContent()
                } }
            } else {
            if isVisible(.basic) { PanelSection(L10n.text("app.basicAdjustments", defaultValue: "Basic Adjustments"), group: .basic, isExpanded: expansion(0), reset: resetBasic, modified: isModified(.basic), previewing: previewingGroup == .basic, preview: previewHandler(.basic), previewPulse: previewPulseHandler(.basic)) { basic.sectionContent() } }
            if isVisible(.curves) { PanelSection(L10n.text("app.curves", defaultValue: "Curves"), group: .curves, isExpanded: expansion(4), reset: { change { $0.pipelineVersion = 2; $0.develop.curves = nil } }, modified: isModified(.curves), previewing: previewingGroup == .curves, preview: previewHandler(.curves), previewPulse: previewPulseHandler(.curves)) {
                ToneCurvePanel(curves: recipe?.develop.curves ?? ToneCurves(), change: { value, save in
                    change({ $0.pipelineVersion = 2; $0.develop.curves = value }, commit: save)
                }, commit: { model.commitRecipe() }).sectionContent()
            } }
            if isVisible(.zones) { PanelSection(L10n.text("app.zoneLighting", defaultValue: "Zone Lighting"), group: .zones, isExpanded: expansion(5), reset: { change { $0.develop.zones = nil } }, modified: isModified(.zones), previewing: previewingGroup == .zones, preview: previewHandler(.zones), previewPulse: previewPulseHandler(.zones)) { zones.sectionContent() } }
            if isVisible(.mixer) { PanelSection(L10n.text("app.hslMixer", defaultValue: "HSL Mixer"), group: .mixer, isExpanded: expansion(1), reset: { change { $0.develop.mixer = Array(repeating: HSLBand(), count: 8) } }, modified: isModified(.mixer), previewing: previewingGroup == .mixer, preview: previewHandler(.mixer), previewPulse: previewPulseHandler(.mixer)) {
                mixer.sectionContent()
            } }
            if !local {
                if isVisible(.pointColor) { PanelSection(L10n.text("app.pointColor", defaultValue: "Point Color"), group: .pointColor, isExpanded:expansion(11),reset:{ model.cancelPointColorTools(); change { $0.develop.pointColors = [] } }, modified: isModified(.pointColor), previewing: previewingGroup == .pointColor, preview: previewHandler(.pointColor), previewPulse: previewPulseHandler(.pointColor)) {
                    PointColorPanel(model:model).sectionContent()
                } }
            }
            if isVisible(.blackWhite) { PanelSection(L10n.text("app.blackWhiteMixer", defaultValue: "Black & White Mixer"), group: .blackWhite, isExpanded: expansion(8), reset: {
                change { $0.develop.blackWhiteMixer = Array(repeating: 0, count: 8) }
            }, modified: isModified(.blackWhite), previewing: previewingGroup == .blackWhite, preview: previewHandler(.blackWhite), previewPulse: previewPulseHandler(.blackWhite)) { blackWhiteMixer.sectionContent() } }
            if isVisible(.grading) { PanelSection(L10n.text("app.colorGrading", defaultValue: "Color Grading"), group: .grading, isExpanded: expansion(2), reset: { change { $0.develop.grading = ColorGrading() } }, modified: isModified(.grading), previewing: previewingGroup == .grading, preview: previewHandler(.grading), previewPulse: previewPulseHandler(.grading)) { grading.sectionContent() } }
            if !local {
                if isVisible(.noiseReduction) { PanelSection(L10n.text("app.noiseReduction", defaultValue: "Noise Reduction"), group: .noiseReduction, isExpanded: expansion(10), reset: { change { $0.noiseReduction = GeneralNoiseReduction() } }, modified: isModified(.noiseReduction), previewing: previewingGroup == .noiseReduction, preview: previewHandler(.noiseReduction), previewPulse: previewPulseHandler(.noiseReduction)) {
                    noiseReduction.sectionContent()
                } }
                if isVisible(.sharpening) { PanelSection(L10n.text("app.sharpening", defaultValue: "Sharpening"), group: .sharpening, isExpanded: expansion(9), reset: { change { $0.sharpening = GeneralSharpening() } }, modified: isModified(.sharpening), previewing: previewingGroup == .sharpening, preview: previewHandler(.sharpening), previewPulse: previewPulseHandler(.sharpening)) {
                    sharpening.sectionContent()
                } }
                if recipe?.isRaster != true {
                    if isVisible(.rawDetails) { PanelSection(L10n.text("app.rawDetailAndLens", defaultValue: "RAW Detail and Lens"), group: .rawDetails, isExpanded: expansion(3), reset: { change { $0.rawDetails = RAWDetailSettings() } }, modified: isModified(.rawDetails), previewing: previewingGroup == .rawDetails, preview: previewHandler(.rawDetails), previewPulse: previewPulseHandler(.rawDetails)) {
                        details.sectionContent()
                    } }
                }
                if isVisible(.vignette) { PanelSection(L10n.text("app.creativeVignette", defaultValue: "Creative Vignette"), group: .vignette, isExpanded: expansion(6), reset: { change { $0.vignette = CreativeVignette() } }, modified: isModified(.vignette), previewing: previewingGroup == .vignette, preview: previewHandler(.vignette), previewPulse: previewPulseHandler(.vignette)) {
                    vignette.sectionContent()
                } }
                if isVisible(.grain) { PanelSection(L10n.text("app.grain", defaultValue: "Grain"), group: .grain, isExpanded: expansion(7), reset: { change { $0.grain = FilmGrain() } }, modified: isModified(.grain), previewing: previewingGroup == .grain, preview: previewHandler(.grain), previewPulse: previewPulseHandler(.grain)) {
                    grain.sectionContent()
                } }
            }
            }
        }
        .contextMenu { Toggle(L10n.text("app.expandOneAdjustmentPanelAtATime", defaultValue: "Expand One Adjustment Panel at a Time"), isOn: $solo) }
        .onChange(of: solo) { if solo { basicOpen = true; mixerOpen = false; gradingOpen = false; detailsOpen = false; curvesOpen = false; zonesOpen = false; vignetteOpen = false; grainOpen = false; blackWhiteOpen = false; sharpenOpen = false; noiseOpen = false; pointOpen = false } }
        .onChange(of: pointOpen) { if !pointOpen && !local { model.cancelPointColorTools() } }
        .onChange(of: zonesOpen) { if !zonesOpen && !local { model.cancelZoneSampling() } }
        .onChange(of: model.cropMode) { if model.cropMode { cropOpen = true; perspectiveOpen = true } }
        .onAppear { if model.cropMode { cropOpen = true; perspectiveOpen = true } }
    }

    @ViewBuilder private var panelToolbar: some View {
        HStack(spacing: 8) {
            Text(L10n.text("app.adjustments", defaultValue: "Adjustments")).font(.section).foregroundStyle(Theme.textSecondary)
            Seam().frame(maxWidth: .infinity)
            Menu {
                Toggle(L10n.text("app.expandOneAdjustmentPanelAtATime", defaultValue: "Expand One Adjustment Panel at a Time"), isOn: $solo)
                Toggle(L10n.text("app.modifiedOnly", defaultValue: "Modified Only"), isOn: $showOnlyModified)
                Divider()
                ForEach(DevelopGroup.allCases.filter { $0 != .rawDetails || recipe?.isRaster != true }) { group in
                    Button(group.title) { open(group) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).tint(Theme.textSecondary)
            .help(L10n.text("app.filterGroupsJumpToAdjustmentsAndUseSinglePanel", defaultValue: "Filter groups, jump to adjustments, and use single-panel mode"))
            .accessibilityLabel(L10n.text("app.adjustmentGroups", defaultValue: "Adjustment Groups"))
        }
        .padding(.horizontal, 12).frame(height: Metrics.sectionHeader)
        Seam()
    }

    private func open(_ group: DevelopGroup) {
        if !isModified(group) { showOnlyModified = false }
        if solo {
            basicOpen = false; mixerOpen = false; gradingOpen = false; detailsOpen = false
            curvesOpen = false; zonesOpen = false; vignetteOpen = false; grainOpen = false
            blackWhiteOpen = false; sharpenOpen = false; noiseOpen = false; pointOpen = false
            cropOpen = false; perspectiveOpen = false
        }
        if let callback = onOpenGroup, group == .crop || group == .perspective {
            callback(group)
            return
        }
        switch group {
        case .basic: basicOpen = true
        case .curves: curvesOpen = true
        case .zones: zonesOpen = true
        case .mixer: mixerOpen = true
        case .pointColor: pointOpen = true
        case .blackWhite: blackWhiteOpen = true
        case .grading: gradingOpen = true
        case .noiseReduction: noiseOpen = true
        case .sharpening: sharpenOpen = true
        case .rawDetails: detailsOpen = true
        case .vignette: vignetteOpen = true
        case .grain: grainOpen = true
        case .crop, .perspective: break
        }
        onOpenGroup?(group)
    }
    private func resetBasic() {
        change { r in
            let old = r.develop
            r.develop = DevelopAdjustments(); r.develop.mixer = old.mixer; r.develop.grading = old.grading
            r.develop.curves = old.curves; r.develop.zones = old.zones
            r.develop.blackWhiteMixer = old.blackWhiteMixer; r.develop.pointColors = old.pointColors
            r.exposure = 0; r.contrast = 1; r.saturation = 1
            r.asShotWhiteBalance = true; r.temperature = r.baselineTemperature; r.tint = r.baselineTint
        }
    }
    private func expansion(_ panel: Int) -> Binding<Bool> {
        Binding(get: { [basicOpen, mixerOpen, gradingOpen, detailsOpen, curvesOpen, zonesOpen, vignetteOpen, grainOpen, blackWhiteOpen, sharpenOpen, noiseOpen, pointOpen][panel] }, set: { open in
            if open && solo {
                basicOpen = false; mixerOpen = false; gradingOpen = false; detailsOpen = false; curvesOpen = false; zonesOpen = false; vignetteOpen = false; grainOpen = false; blackWhiteOpen = false; sharpenOpen = false; noiseOpen = false; pointOpen = false
            }
            if panel == 0 { basicOpen = open }
            else if panel == 1 { mixerOpen = open }
            else if panel == 2 { gradingOpen = open }
            else if panel == 3 { detailsOpen = open }
            else if panel == 4 { curvesOpen = open }
            else if panel == 5 { zonesOpen = open }
            else if panel == 6 { vignetteOpen = open }
            else if panel == 7 { grainOpen = open }
            else if panel == 8 { blackWhiteOpen = open }
            else if panel == 9 { sharpenOpen = open }
            else if panel == 10 { noiseOpen = open }
            else { pointOpen = open }
        })
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption11).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
    private var blackWhiteMixer: some View {
        VStack(spacing: 0) {
            if recipe?.develop.blackAndWhite != true { note(L10n.text("app.availableAfterSelectingBlackWhiteInBasicAdjustmentsValues", defaultValue: "Available after selecting Black & White in Basic Adjustments. Values are retained in color mode.")) }
            ForEach(0..<8, id: \.self) { band in
                AdjustmentRow(label: HSLBand.names[band], value: recipe?.develop.blackWhiteMixer[band] ?? 0,
                    track: .luminance(HSLBand.centers[band]), change: { value, save in
                        change({ $0.pipelineVersion = 2; $0.develop.blackWhiteMixer[band] = value }, commit: save)
                    }, commit: { model.commitRecipe() })
                    .disabled(recipe?.develop.blackAndWhite != true)
            }
            note(L10n.text("app.selectColorsAfterHSLVibranceAndSaturationToSmoothly", defaultValue: "Select colors after HSL, Vibrance, and Saturation to smoothly change black-and-white tones. Color Grading follows. Zero values preserve the original black-and-white appearance."))
                .padding(.top, 6)
        }
    }
    /// A labelled key row aligned with the parameter rows' label column.
    private func keyField<Value: Hashable>(_ title: String, _ options: [KeyOption<Value>], _ selection: Binding<Value>) -> some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            Text(title).frame(width: Metrics.rowLabel, height: Metrics.key, alignment: .leading)
            KeyRow(title: title, options: options, selection: selection, expand: true)
        }.padding(.vertical, 2)
    }
    private var zones: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !local {
                Button(model.zoneSampling ? L10n.text("app.cancelPhotoSampling", defaultValue: "Cancel Photo Sampling") : L10n.text("app.selectZoneInPhoto", defaultValue: "Select Zone in Photo")) { model.toggleZoneSampling() }
                    .buttonStyle(.key(selected: model.zoneSampling))
                    .accessibilityAddTraits(model.zoneSampling ? .isSelected : [])
                    .padding(.bottom, 6)
                if model.zoneSampling {
                    note(model.zoneReference == nil ? L10n.text("app.preparingLuminanceSampling", defaultValue: "Preparing luminance sampling…") : L10n.text("app.clickThePhotoToLocateALuminanceZoneThen", defaultValue: "Click the photo to locate a luminance zone, then adjust its slider.")).padding(.bottom, 4)
                } else if let ev = model.sampledZoneEV {
                    note(String(format: L10n.text("app.lastSample2fEV", defaultValue: "Last sample: %+.2f EV"), ev)).monospacedDigit().padding(.bottom, 4)
                }
            }
            ForEach(0..<5, id: \.self) { i in
                let selected = !local && model.selectedZone == i
                AdjustmentRow(label: "\(ToneZones.names[i])", value: recipe?.develop.zones?.gains[i] ?? 0,
                    range: -1...1, step: 0.05, digits: 2, unit: "EV", change: { value, save in
                        change({ r in
                            var zones = r.develop.zones ?? ToneZones(); zones.gains[i] = value
                            r.pipelineVersion = 2; r.develop.zones = zones.isNeutral ? nil : zones
                        }, commit: save)
                    }, commit: { model.commitRecipe() })
                    .padding(.horizontal, 6)
                    .background(selected ? Theme.selected : .clear)
                    .overlay(alignment: .leading) { if selected { Theme.accentSignal.frame(width: 2) } }
                    .padding(.horizontal, -6)
                    .help(L10n.text("app.tonesNearEVAdjustableByUpTo1EV", defaultValue: "Tones near \(Int(ToneZones.stops[i])) EV, adjustable by up to 1 EV"))
            }
            note(L10n.text("app.evUnitsSmoothlyAdjustFiveTonalZonesWhilePreserving", defaultValue: "EV units · Smoothly adjust five tonal zones while preserving texture and edges.")).padding(.top, 4)
        }
    }
    private var noiseReduction: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailZoom
            noiseRow(L10n.text("app.luminanceNoiseReduction", defaultValue: "Luminance Noise Reduction"), \.luminance)
            noiseRow(L10n.text("app.colorNoiseReduction", defaultValue: "Color Noise Reduction"), \.color)
            note(L10n.text("app.0DisablesReductionNoiseReductionPrecedesSharpeningCheckTexture", defaultValue: "0 disables reduction. Noise reduction precedes sharpening. Check texture and color edges at 100%.")).padding(.top, 6)
        }.disabled(model.applyingAdjustments)
    }
    private func noiseRow(_ name: String, _ key: WritableKeyPath<GeneralNoiseReduction,Double>) -> some View {
        AdjustmentRow(label:name,value:recipe?.noiseReduction[keyPath:key] ?? 0,range:0...100,digits:1,reset:0,
            change:{ value, save in change({ $0.noiseReduction[keyPath:key] = value },commit:save) },commit:{ model.commitRecipe() })
    }
    private var sharpening: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailZoom
            sharpenRow(L10n.text("app.sharpeningAmount", defaultValue: "Sharpening Amount"), \.amount, range: 0...150, reset: 0)
            sharpenRow(L10n.text("app.sharpeningRadius", defaultValue: "Sharpening Radius"), \.radius, range: 0.5...3, reset: 1, step: 0.1, unit: "px")
            sharpenRow(L10n.text("app.edgeProtection", defaultValue: "Edge Protection"), \.protection, range: 0...100, reset: 25)
            note(L10n.text("app.radiusUsesOriginalImagePixelsAmount0DisablesSharpening", defaultValue: "Radius uses original image pixels; amount 0 disables sharpening. Check fine lines and noise at 100%.")).padding(.top, 6)
        }.disabled(model.applyingAdjustments)
    }
    private func sharpenRow(_ name: String, _ key: WritableKeyPath<GeneralSharpening,Double>, range: ClosedRange<Double>, reset: Double, step: Double = 1, unit: String = "") -> some View {
        AdjustmentRow(label:name,value:recipe?.sharpening[keyPath:key] ?? reset,range:range,step:step,digits:step < 1 ? 1 : 0,reset:reset,unit:unit,
            change: { value, save in change({ $0.sharpening[keyPath:key] = value },commit:save) },commit: { model.commitRecipe() })
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailZoom
            if model.rawDefaults == nil {
                note(L10n.text("app.readingAvailableAdjustmentsForThisRAW", defaultValue: "Reading available adjustments for this RAW…"))
            } else {
                SubgroupLabel(L10n.text("app.noiseReduction_1116", defaultValue: "Noise Reduction"))
                detailRow(L10n.text("app.luminanceNoiseReduction", defaultValue: "Luminance Noise Reduction"), \.luminanceNoiseReduction)
                detailRow(L10n.text("app.colorNoiseReduction", defaultValue: "Color Noise Reduction"), \.colorNoiseReduction)
                SubgroupLabel(L10n.text("app.sharpening_759", defaultValue: "Sharpening"))
                detailRow(L10n.text("app.sharpening_759", defaultValue: "Sharpening"), \.sharpness)
                SubgroupLabel(L10n.text("app.lens", defaultValue: "Lens"))
                if let baseline = model.rawDefaults?.lensCorrection {
                    HStack(spacing: Metrics.gap) {
                        Text(L10n.text("app.lensCorrection", defaultValue: "Lens Correction")).frame(width: Metrics.rowLabel, alignment: .leading)
                        LampSwitch(title: L10n.text("app.lensCorrection", defaultValue: "Lens Correction"), isOn: Binding(get: { recipe?.rawDetails.lensCorrection ?? baseline },
                            set: { value in change { $0.rawDetails.lensCorrection = value == baseline ? nil : value } }))
                        Text(recipe?.rawDetails.lensCorrection ?? baseline ? L10n.text("app.enabled", defaultValue: "Enabled") : L10n.text("app.disabled", defaultValue: "Disabled")).font(.caption11).foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }.frame(height: Metrics.row)
                    if recipe?.localAdjustments.isEmpty == false || recipe?.repairs.isEmpty == false {
                        note(L10n.text("app.lensCorrectionMovesImageContentCheckMaskAndSpot", defaultValue: "Lens correction moves image content. Check mask and spot targets and sources afterward. Coordinates remain in the current corrected canvas."))
                    }
                } else { note(L10n.text("app.thisRAWDoesNotSupportSystemLensCorrection", defaultValue: "This RAW does not support system lens correction")) }
                note(L10n.text("app.reducedPreviewsAreApproximateReleaseThenInspectNoiseReduction", defaultValue: "Reduced previews are approximate. Release, then inspect noise reduction and sharpening at 100%. Reset restores system defaults.")).padding(.top, 6)
            }
        }.disabled(model.applyingAdjustments)
    }
    private var detailZoom: some View {
        let actual = model.fullResolution && model.zoomScale == 1
        return Button(L10n.text("app.inspectAt100", defaultValue: "Inspect at 100%")) { model.selectZoom(actual ? nil : 1) }
            .buttonStyle(.key(selected: actual)).padding(.bottom, 6)
            .help(actual ? L10n.text("app.viewingAt100ClickAgainToFit", defaultValue: "Viewing at 100%; click again to fit") : L10n.text("app.inspectDetailsAt100", defaultValue: "Inspect Details at 100%"))
            .accessibilityValue(actual ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
            .accessibilityAddTraits(actual ? .isSelected : [])
    }
    private var vignette: some View {
        VStack(alignment: .leading, spacing: 0) {
            keyField(L10n.text("app.style", defaultValue: "Style"), [
                KeyOption(CreativeVignetteStyle.highlightPriority, L10n.text("app.highlightPriority", defaultValue: "Highlight Priority")),
                KeyOption(CreativeVignetteStyle.colorPriority, L10n.text("app.colorPriority", defaultValue: "Color Priority")),
                KeyOption(CreativeVignetteStyle.paintOverlay, L10n.text("app.overlay", defaultValue: "Overlay"))
            ], Binding(get: { recipe?.vignette.style ?? .highlightPriority }, set: { style in
                change { $0.vignette.style = style }
            }))
            vignetteRow(L10n.text("app.amount", defaultValue: "Amount"), \.amount, range: -100...100)
            vignetteRow(L10n.text("app.midpoint", defaultValue: "Midpoint"), \.midpoint, range: 0...100, reset: 50)
            vignetteRow(L10n.text("app.roundness", defaultValue: "Roundness"), \.roundness, range: -100...100)
            vignetteRow(L10n.text("app.feather", defaultValue: "Feather"), \.feather, range: 0...100, reset: 50)
            vignetteRow(L10n.text("app.highlightProtection", defaultValue: "Highlight Protection"), \.highlights, range: 0...100)
            note(L10n.text("app.calculatedAfterCroppingIndependentlyOfLensCorrectionHighlightProtection", defaultValue: "Calculated after cropping, independently of lens correction. Highlight protection applies to Highlight Priority only.")).padding(.top, 6)
        }
    }
    private func vignetteRow(_ name: String, _ key: WritableKeyPath<CreativeVignette, Double>, range: ClosedRange<Double>, reset: Double = 0) -> some View {
        AdjustmentRow(label: name, value: recipe?.vignette[keyPath: key] ?? reset, range: range, reset: reset, track: .basic(name),
            change: { value, commit in change({ $0.vignette[keyPath: key] = value }, commit: commit) },
            commit: { model.commitRecipe() })
    }
    private var grain: some View {
        VStack(alignment: .leading, spacing: 0) {
            grainRow(L10n.text("app.amount", defaultValue: "Amount"), \.amount)
            grainRow(L10n.text("app.size", defaultValue: "Size"), \.size, reset: 25)
            grainRow(L10n.text("app.roughness", defaultValue: "Roughness"), \.roughness, reset: 50)
            note(L10n.text("app.calculatedAfterCroppingTheSamePhotoRetainsItsAppearance", defaultValue: "Calculated after cropping. The same photo retains its appearance when reopened.")).padding(.top, 6)
        }
    }
    private func grainRow(_ name: String, _ key: WritableKeyPath<FilmGrain, Double>, reset: Double = 0) -> some View {
        AdjustmentRow(label: name, value: recipe?.grain[keyPath: key] ?? reset, range: 0...100, reset: reset, track: .basic(name),
            change: { value, commit in
                change({
                    if key == \.amount, $0.grain.amount <= 0, value > 0 { $0.grain.ensureSeed() }
                    $0.grain[keyPath: key] = value
                }, commit: commit)
            },
            commit: { model.commitRecipe() })
    }
    @ViewBuilder private func detailRow(_ name: String, _ key: WritableKeyPath<RAWDetailSettings, Double?>) -> some View {
        if let baseline = model.rawDefaults?[keyPath: key] {
            AdjustmentRow(label: name, value: (recipe?.rawDetails[keyPath: key] ?? baseline) * 100,
                range: 0...100, reset: baseline * 100, change: { value, commit in
                    change({ $0.rawDetails[keyPath: key] = Float(value / 100) == Float(baseline) ? nil : value / 100 }, commit: commit)
                }, commit: { model.commitRecipe() })
        } else { note(L10n.text("app.thisRAWDoesNotSupport", defaultValue: "This RAW does not support \(name)")) }
    }
    private var basic: some View {
        VStack(spacing: 0) {
            keyField(L10n.text("app.treatment", defaultValue: "Treatment"), [KeyOption(false, L10n.text("app.color_1139", defaultValue: "Color")), KeyOption(true, L10n.text("app.blackWhite", defaultValue: "Black & White"))],
                     Binding(get: { recipe?.develop.blackAndWhite ?? false }, set: { v in change { $0.develop.blackAndWhite = v } }))
            HStack {
                SubgroupLabel(L10n.text("app.whiteBalance", defaultValue: "White Balance"))
                Spacer()
                if !local {
                    Button { model.toggleWhiteBalanceSampling() } label: {
                        LampLabel(on: model.whiteBalanceSampling) { Image(systemName: "eyedropper") }
                    }.buttonStyle(.key(selected: model.whiteBalanceSampling, height: 24, padding: 8))
                        .disabled(!model.canEdit).help(L10n.text("app.sampleWhiteBalanceFromANeutralAreaWEsc", defaultValue: "Sample white balance from a neutral area (W); Esc exits"))
                        .accessibilityLabel(L10n.text("app.sampleWhiteBalance", defaultValue: "Sample White Balance")).accessibilityValue(model.whiteBalanceSampling ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
                }
            }
            if !local, model.whiteBalanceSampling {
                KeyRow(title: L10n.text("app.afterSampling", defaultValue: "After Sampling"), options: [KeyOption(false, L10n.text("app.single", defaultValue: "Single")), KeyOption(true, L10n.text("app.continuous", defaultValue: "Continuous"))], selection: $model.whiteBalanceContinuous, expand: true)
                    .padding(.bottom, 6)
                note(model.whiteBalanceSamplingBusy ? L10n.text("app.calculatingWhiteBalance", defaultValue: "Calculating white balance…") : L10n.text("app.clickANeutralGrayAreaHoldSpaceToPan", defaultValue: "Click a neutral gray area. Hold Space to pan; Esc exits."))
            }
            keyField(L10n.text("app.whiteBalance", defaultValue: "White Balance"), [KeyOption(true, local ? L10n.text("app.unchanged", defaultValue: "Unchanged") : L10n.text("app.asShot", defaultValue: "As Shot")), KeyOption(false, L10n.text("app.custom", defaultValue: "Custom"))],
                     Binding(get: { recipe?.asShotWhiteBalance ?? true }, set: { v in change { r in
                        r.asShotWhiteBalance = v
                        if v { r.temperature = r.baselineTemperature; r.tint = r.baselineTint }
                     } }))
            row(L10n.text("app.temperature", defaultValue: "Temperature"), \.temperature, range: 2000...50000, step: 50, reset: recipe?.baselineTemperature ?? 5500, unit: "K")
            row(L10n.text("app.tint", defaultValue: "Tint"), \.tint, range: -150...150, reset: recipe?.baselineTint ?? 0)
            if local || recipe?.isRaster == true { note(L10n.text("app.5500K0IsNeutralAdjustmentsApplyOverThe", defaultValue: "5500 K / 0 is neutral. Adjustments apply over the current photo colors.")) }
            SubgroupLabel(L10n.text("app.tint", defaultValue: "Tint"))
            row(L10n.text("app.exposure", defaultValue: "Exposure"), \.exposure, range: -5...5, step: 0.05, digits: 2, unit: "EV")
            row(L10n.text("app.contrast", defaultValue: "Contrast"), \.contrast, scale: 100, offset: -100)
            row(L10n.text("app.highlights", defaultValue: "Highlights"), \.develop.highlights)
            row(L10n.text("app.shadows", defaultValue: "Shadows"), \.develop.shadows)
            row(L10n.text("app.whites", defaultValue: "Whites"), \.develop.whites)
            row(L10n.text("app.blacks", defaultValue: "Blacks"), \.develop.blacks)
            SubgroupLabel(L10n.text("app.preferences", defaultValue: "Preferences"))
            row(L10n.text("app.texture", defaultValue: "Texture"), \.develop.texture)
            row(L10n.text("app.clarity", defaultValue: "Clarity"), \.develop.clarity)
            row(L10n.text("app.dehaze", defaultValue: "Dehaze"), \.develop.dehaze)
            row(L10n.text("app.vibrance", defaultValue: "Vibrance"), \.develop.vibrance)
            row(L10n.text("app.saturation", defaultValue: "Saturation"), \.saturation, scale: 100, offset: -100)
        }
    }
    private var crop: some View {
        VStack(alignment: .leading, spacing: 8) {
            note(L10n.text("app.dragThePhotoBorderToCropThenReturnTo", defaultValue: "Drag the photo border to crop, then return to Adjustments."))
            HStack(spacing: Metrics.gap) {
                Text(L10n.text("app.aspect", defaultValue: "Aspect")).frame(width: Metrics.rowLabel, alignment: .leading)
                HStack(spacing: -1) {
                    Menu {
                        Button(L10n.text("app.free", defaultValue: "Free")) { model.setCropAspectRatio(nil) }
                        Button(L10n.text("app.originalAspect", defaultValue: "Original Aspect")) { if let size = model.orientedSourceSize, let r = recipe {
                            setRatio(r.quarterTurns % 2 == 0 ? size.width / size.height : size.height / size.width)
                        } }
                        ForEach(cropRatios, id: \.self) { ratio in
                            Button(Self.ratioName(ratio)) { setRatio(ratio) }
                        }
                    } label: { Text(ratioLabel).monospacedDigit() }
                        .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize()
                        .keySurface(position: .leading)
                        .accessibilityLabel(L10n.text("app.cropAspectRatio", defaultValue: "Crop Aspect Ratio")).accessibilityValue(ratioLabel)
                    Button(action: model.toggleCropAspectLock) { Image(systemName: recipe?.cropAspectRatio == nil ? "lock.open" : "lock") }
                        .buttonStyle(.key(selected: recipe?.cropAspectRatio != nil, position: .middle, padding: 8))
                        .help(L10n.text("app.lockOrUnlockTheCurrentCropAspectA", defaultValue: "Lock or unlock the current crop aspect (A)")).accessibilityLabel(L10n.text("app.lockAspect", defaultValue: "Lock Aspect"))
                    Button(L10n.text("app.landscapePortrait", defaultValue: "Landscape / Portrait"), action: model.rotateCropAspect)
                        .buttonStyle(.key(position: .trailing))
                        .help(L10n.text("app.swapCropOrientationXPhotoFlagsArePreserved", defaultValue: "Swap crop orientation (X); photo flags are preserved"))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Metrics.gap) {
                Text(L10n.text("app.guides", defaultValue: "Guides")).frame(width: Metrics.rowLabel, alignment: .leading)
                Menu {
                    ForEach(CropGuide.allCases, id: \.self) { guide in Button(guide.title) { model.cropGuide = guide } }
                } label: { Text(model.cropGuide.title) }
                    .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize().keySurface()
                    .accessibilityLabel(L10n.text("app.cropGuides", defaultValue: "Crop Guides")).accessibilityValue(model.cropGuide.title).help(L10n.text("app.cycleCompositionGuidesOAdjustmentsArePreserved", defaultValue: "Cycle composition guides (O); adjustments are preserved"))
                Spacer(minLength: 0)
            }
            row(L10n.text("app.angle", defaultValue: "Angle"), \.straightenDegrees, range: -45...45, step: 0.1, digits: 1, unit: "°")
            HStack(spacing: Metrics.gap) {
                Text(L10n.text("app.rotate", defaultValue: "Rotate")).frame(width: Metrics.rowLabel, alignment: .leading)
                HStack(spacing: -1) {
                    Button(L10n.text("app.90Left", defaultValue: "90° Left")) { rotate(3) }.buttonStyle(.key(position: .leading))
                    Button(L10n.text("app.90Right", defaultValue: "90° Right")) { rotate(1) }.buttonStyle(.key(position: .trailing))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Metrics.gap) {
                Text(L10n.text("app.flip", defaultValue: "Flip")).frame(width: Metrics.rowLabel, alignment: .leading)
                HStack(spacing: -1) {
                    Button(L10n.text("app.flipHorizontal", defaultValue: "Flip Horizontal")) { change { $0.flipHorizontal.toggle() } }
                        .buttonStyle(.key(selected: recipe?.flipHorizontal == true, position: .leading))
                        .accessibilityValue(recipe?.flipHorizontal == true ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
                    Button(L10n.text("app.flipVertical", defaultValue: "Flip Vertical")) { change { $0.flipVertical.toggle() } }
                        .buttonStyle(.key(selected: recipe?.flipVertical == true, position: .trailing))
                        .accessibilityValue(recipe?.flipVertical == true ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
                }
                Spacer(minLength: 0)
            }
            note(L10n.text("app.flipTheCurrentCropWhileRetainingTheSelectedContent", defaultValue: "Flip the current crop while retaining the selected content. The crop stays level during rotation and straightening."))
        }
    }
    private var perspective: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(L10n.text("app.horizontalPerspective", defaultValue: "Horizontal Perspective"), \.perspective.horizontal, step: 0.1, digits: 1)
            row(L10n.text("app.verticalPerspective", defaultValue: "Vertical Perspective"), \.perspective.vertical, step: 0.1, digits: 1)
            row(L10n.text("app.aspectFineTuning", defaultValue: "Aspect Fine-Tuning"), \.perspective.aspect, step: 0.1, digits: 1)
            Toggle(L10n.text("app.constrainCrop", defaultValue: "Constrain Crop"), isOn: Binding(get: { recipe?.perspective.constrainCrop ?? true }, set: { value in change { $0.perspective.constrainCrop = value } }))
                .toggleStyle(.instrument).padding(.vertical, 8)
                .help(L10n.text("app.shrinkInwardAroundTheCropCenterAtTheSelected", defaultValue: "Shrink inward around the crop center at the selected aspect to remove blank areas. Neutral perspective preserves the original crop."))
            note(L10n.text("app.negativeVerticalExpandsTheTopNegativeHorizontalExpandsThe", defaultValue: "Negative Vertical expands the top; negative Horizontal expands the left. Positive Aspect stretches vertically and narrows horizontally. Constrain Crop removes blank edges; otherwise transparency is retained and JPEG needs a black or white matte."))
        }
    }
    private var ratioLabel: String { recipe?.cropAspectRatio.map(Self.ratioName) ?? L10n.text("app.free", defaultValue: "Free") }
    private static func ratioName(_ ratio: Double) -> String {
        let presets: [(Double, String)] = [(1, "1 : 1"), (1.5, "3 : 2"), (4.0/3, "4 : 3"), (16.0/9, "16 : 9"), (4.0/5, "4 : 5"), (2.0/3, "2 : 3")]
        return presets.first { abs($0.0 - ratio) < 0.00001 }?.1 ?? String(format: "%.3f : 1", ratio)
    }
    private func setRatio(_ ratio: Double) {
        model.setCropAspectRatio(ratio)
    }
    private func rotate(_ turns: Int) {
        change { r in
            r.rotateCanvas(by: turns)
            if let ratio = r.cropAspectRatio, let size = model.orientedSourceSize { r.crop = Crop.centered(aspectRatio: ratio, orientedCanvas: size, quarterTurns: r.quarterTurns) }
            else { r.crop = Crop() }
        }
    }
    private var mixer: some View {
        VStack(spacing: 0) {
            KeyRow(title: L10n.text("app.hslMode", defaultValue: "HSL Mode"), options: [KeyOption(0, L10n.text("app.hue", defaultValue: "Hue")), KeyOption(1, L10n.text("app.saturation", defaultValue: "Saturation")), KeyOption(2, L10n.text("app.luminance_1188", defaultValue: "Luminance")), KeyOption(3, L10n.text("app.all", defaultValue: "All"))],
                   selection: $mixerTab, expand: true).padding(.bottom, 4)
            ForEach(mixerTab == 3 ? [0, 1, 2] : [mixerTab], id: \.self) { tab in
                if mixerTab == 3 { SubgroupLabel([L10n.text("app.hue", defaultValue: "Hue"), L10n.text("app.saturation", defaultValue: "Saturation"), L10n.text("app.luminance_1188", defaultValue: "Luminance")][tab]) }
                ForEach(0..<8, id: \.self) { index in
                    let key: WritableKeyPath<HSLBand, Double> = tab == 0 ? \.hue : tab == 1 ? \.saturation : \.luminance
                    AdjustmentRow(label: HSLBand.names[index], value: recipe?.develop.mixer[index][keyPath: key] ?? 0, track: .mixer(index, tab), change: { v, commit in
                        change({ $0.develop.mixer[index][keyPath: key] = v }, commit: commit)
                    }, commit: { model.commitRecipe() })
                }
            }
        }
    }
    private var grading: some View {
        VStack(spacing: 10) {
            KeyRow(title: L10n.text("app.colorWheelView", defaultValue: "Color Wheel View"), options: [KeyOption(0, L10n.text("app.threeWay", defaultValue: "Three-Way")), KeyOption(1, L10n.text("app.shadows", defaultValue: "Shadows")), KeyOption(2, L10n.text("app.midtones", defaultValue: "Midtones")), KeyOption(3, L10n.text("app.highlights", defaultValue: "Highlights")), KeyOption(4, L10n.text("app.global", defaultValue: "Global"))],
                   selection: $gradingTab, expand: true)
            if gradingTab == 0 {
                wheel(L10n.text("app.midtones_1193", defaultValue: "Midtones"), \.midtones, diameter: 118)
                HStack(alignment: .top, spacing: 12) {
                    wheel(L10n.text("app.shadows", defaultValue: "Shadows"), \.shadows, diameter: 110)
                    wheel(L10n.text("app.highlights", defaultValue: "Highlights"), \.highlights, diameter: 110)
                }
            } else {
                let key: WritableKeyPath<ColorGrading, GradingTone> = gradingTab == 1 ? \.shadows : gradingTab == 2 ? \.midtones : gradingTab == 3 ? \.highlights : \.global
                wheel(["", L10n.text("app.shadows", defaultValue: "Shadows"), L10n.text("app.midtones_1193", defaultValue: "Midtones"), L10n.text("app.highlights", defaultValue: "Highlights"), L10n.text("app.global", defaultValue: "Global")][gradingTab], key, diameter: 170)
                VStack(spacing: 0) {
                    toneRow(L10n.text("app.hue", defaultValue: "Hue"), key, \.hue, range: 0...360, unit: "°")
                    toneRow(L10n.text("app.saturation", defaultValue: "Saturation"), key, \.saturation, range: 0...100)
                    toneRow(L10n.text("app.luminance_1188", defaultValue: "Luminance"), key, \.luminance, range: -100...100)
                }
            }
            VStack(spacing: 0) {
                SubgroupLabel(L10n.text("app.blendingAndBalance", defaultValue: "Blending and Balance"))
                row(L10n.text("app.blending", defaultValue: "Blending"), \.develop.grading.blending, range: 0...100, reset: 50)
                row(L10n.text("app.balance", defaultValue: "Balance"), \.develop.grading.balance)
            }
        }
    }
    private func wheel(_ name: String, _ key: WritableKeyPath<ColorGrading, GradingTone>, diameter: CGFloat) -> some View {
        let tone = recipe?.develop.grading[keyPath: key] ?? GradingTone()
        return VStack(spacing: 5) {
            Text(name).font(.caption11).foregroundStyle(Theme.textSecondary)
            GradingWheel(tone: tone, change: { h, s in change({ r in r.develop.grading[keyPath: key].hue = h; r.develop.grading[keyPath: key].saturation = s }, commit: false) }, commit: { model.commitRecipe() })
                .frame(width: diameter, height: diameter)
            Text(String(format: "H %.0f° · S %.0f", tone.hue, tone.saturation)).font(.caption11).monospacedDigit().foregroundStyle(Theme.textSecondary)
            if gradingTab == 0 {
                GradientAdjustmentSlider(value: tone.luminance, range: -100...100, step: 1, neutral: 0, track: .luminance(tone.hue), label: L10n.text("app.luminance_1197", defaultValue: "\(name) Luminance"), change: { v in change({ $0.develop.grading[keyPath: key].luminance = v }, commit: false) }, commit: { model.commitRecipe() })
                    .accessibilityLabel(L10n.text("app.luminance_1197", defaultValue: "\(name) Luminance")).help(L10n.text("app.luminance_1198", defaultValue: "Luminance \(Int(tone.luminance))")).frame(width: diameter, height: 24)
            }
        }
    }
    private func toneRow(_ name: String, _ tone: WritableKeyPath<ColorGrading, GradingTone>, _ key: WritableKeyPath<GradingTone, Double>, range: ClosedRange<Double>, unit: String? = nil) -> some View {
        AdjustmentRow(label: name, value: recipe?.develop.grading[keyPath: tone][keyPath: key] ?? 0, range: range, track: key == \.hue ? .hue : key == \.saturation ? .saturation(recipe?.develop.grading[keyPath: tone].hue ?? 0) : .luminance(recipe?.develop.grading[keyPath: tone].hue ?? 0), unit: unit, change: { v, commit in
            change({ $0.develop.grading[keyPath: tone][keyPath: key] = v }, commit: commit)
        }, commit: { model.commitRecipe() })
    }
    private func row(_ name: String, _ key: WritableKeyPath<EditRecipe, Double>, range: ClosedRange<Double> = -100...100, step: Double = 1, digits: Int = 0, scale: Double = 1, offset: Double = 0, reset: Double = 0, unit: String? = nil) -> some View {
        DevelopParameterRow(model: model, local: local, name: name, key: key,
                            value: (recipe?[keyPath: key] ?? 0) * scale + offset,
                            range: range, step: step, digits: digits, scale: scale, offset: offset, reset: reset, unit: unit)
            .equatable()
    }
}

// Actions are derived from explicit inputs, so equal values can safely skip rebuilding native controls.
private struct DevelopParameterRow: View, Equatable {
    let model: AppModel
    let local: Bool
    let name: String
    let key: WritableKeyPath<EditRecipe, Double>
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let digits: Int
    let scale: Double
    let offset: Double
    let reset: Double
    let unit: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.local == rhs.local && lhs.name == rhs.name && lhs.key == rhs.key &&
            lhs.value == rhs.value && lhs.range == rhs.range && lhs.step == rhs.step && lhs.digits == rhs.digits &&
            lhs.scale == rhs.scale && lhs.offset == rhs.offset && lhs.reset == rhs.reset && lhs.unit == rhs.unit
    }
    var body: some View {
        AdjustmentRow(label: name, value: value, range: range, step: step, digits: digits, reset: reset,
                      track: .basic(name), unit: unit, change: { next, commit in
            let edit: (inout EditRecipe) -> Void = { recipe in
                recipe[keyPath: key] = (next - offset) / scale
                if key == \.temperature || key == \.tint { recipe.asShotWhiteBalance = false }
            }
            if local { model.changeLocalDevelop(edit, commit: commit) }
            else { model.changeRecipe(edit, commit: commit) }
        }, commit: { model.commitRecipe() })
    }
}

extension View {
    /// Inset for the controls inside a panel section.
    func sectionContent() -> some View {
        padding(.horizontal, Metrics.padding).padding(.top, 2).padding(.bottom, 12)
    }
}

struct GradingWheel: View {
    let tone: GradingTone
    let change: (Double, Double) -> Void
    let commit: () -> Void
    var body: some View {
        GeometryReader { geometry in
            let radius = min(geometry.size.width, geometry.size.height) / 2
            let angle = tone.hue * .pi / 180
            ZStack {
                Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: 1 - Double($0) / 12, saturation: 1, brightness: 1) }, center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.75), .clear], center: .center, startRadius: 0, endRadius: radius))
                Circle().strokeBorder(Theme.controlBorder, lineWidth: 1)
                Circle().fill(.clear).stroke(.black.opacity(0.7), lineWidth: 3).overlay(Circle().stroke(.white, lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .position(x: radius + cos(angle) * radius * tone.saturation / 100, y: radius - sin(angle) * radius * tone.saturation / 100)
            }.contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let dx = value.location.x - radius, dy = radius - value.location.y
                    let distance = hypot(dx, dy)
                    let hue = distance < 1 ? tone.hue : (atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                    change(hue, min(100, distance / radius * 100))
                }.onEnded { _ in commit() })
                .onTapGesture(count: 2) { change(tone.hue, 0); commit() }
                .accessibilityLabel(L10n.text("app.colorGradingWheel", defaultValue: "Color Grading Wheel"))
                .accessibilityValue(L10n.text("app.hueSaturation", defaultValue: "Hue \(Int(tone.hue)), saturation \(Int(tone.saturation))"))
                .help(L10n.text("app.dragToSetHueAndSaturationDoubleClickTo", defaultValue: "Drag to set hue and saturation; double-click to clear the tint. Use a single wheel to enter exact values."))
        }
    }
}
