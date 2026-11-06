import SwiftUI
import CoreImage

private extension MaskTool {
    var icon: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .linear: return "rectangle.lefthalf.filled"
        case .radial: return "circle.inset.filled"
        case .color: return "eyedropper.halffull"
        case .luminance: return "circle.righthalf.filled"
        case .object: return "viewfinder"
        }
    }
    var shortcut: String {
        switch self { case .brush: return "K"; case .linear: return "M"; case .radial: return "⇧ M"; default: return "" }
    }
}

/// The inspector keeps selection editing and the resulting adjustments explicit.
struct MaskPanel: View {
    @Bindable var model: AppModel
    var compact = false
    @AppStorage("maskRefinementOpen") private var refinementOpen = true
    @State private var precise = false
    @State private var hoveredSample: Int?
    @State private var localPresetName = ""
    @State private var savingLocalPreset = false
    var body: some View {
        ScrollView { inspectorContent.frame(maxWidth: .infinity) }
            .accessibilityIdentifier("mask-settings")
            .safeAreaInset(edge: .bottom, spacing: 0) { SmartMaskFooter(model: model, compact: compact) }
    }
    private var inspectorContent: some View {
        VStack(spacing: 0) {
            if model.smartMaskSession != nil {
                SmartMaskPanel(model: model, compact: compact)
            } else if model.maskChoosingTool || model.selectedMask == nil {
                PanelTitle(L10n.text("app.createSelection", defaultValue: "Create Selection")) {
                    if model.selectedMask != nil { Button(L10n.text("app.cancel", defaultValue: "Cancel")) { model.maskChoosingTool = false }.buttonStyle(.key(height: 22)) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    SubgroupLabel(L10n.text("app.smartSelection", defaultValue: "Smart Selection")).padding(.horizontal, 12)
                    Button { model.beginSmartMask(workflow: .people) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.rectangle").font(.system(size: 15)).foregroundStyle(Theme.textSecondary).frame(width: 20)
                            Text(L10n.text("app.people", defaultValue: "People"))
                            Spacer()
                            Text(L10n.text("app.wholePersonAndParts", defaultValue: "Whole Person and Parts")).font(.caption11).foregroundStyle(Theme.textSecondary)
                        }.padding(.horizontal, 12).frame(height: Metrics.row).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("mask-create-people")
                    toolButton(.object)
                    SubgroupLabel(L10n.text("app.drawManually", defaultValue: "Draw Manually")).padding(.horizontal, 12)
                    ForEach([MaskTool.brush, .linear, .radial]) { tool in toolButton(tool) }
                    SubgroupLabel(L10n.text("app.range", defaultValue: "Range")).padding(.horizontal, 12)
                    ForEach([MaskTool.color, .luminance]) { tool in toolButton(tool) }
                }.padding(.bottom, 12)
            } else if let group = model.selectedMask {
                maskActions.padding(12)
                Seam()
                if let component = model.selectedMaskComponent { toolControls(component); Seam() }
                PanelSection(L10n.text("app.refineSelection", defaultValue: "Refine Selection"), isExpanded: $refinementOpen, reset: { model.showMaskOverlay = true; model.changeMask { $0.refinement = nil } }) {
                    refinementControls(group).sectionContent()
                }
                PanelTitle(L10n.text("app.localAdjustmentsTitle", defaultValue: "Local Adjustments")) {
                    Text(model.previewingMaskID == group.id ? L10n.text("app.previewing", defaultValue: "Previewing") : !group.enabled ? L10n.text("app.disabled", defaultValue: "Disabled") : group.isNeutral ? L10n.text("app.unmodified", defaultValue: "Unmodified") : L10n.text("app.modified", defaultValue: "Modified"))
                        .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize()
                    MomentaryPreviewKey(title: L10n.text("app.previewCurrentMaskEffect", defaultValue: "Preview Current Mask Effect"),
                        systemImage: model.previewingMaskID == group.id ? "eye.slash" : "eye",
                        selected: model.previewingMaskID == group.id, height: 22,
                        onPress: { pressed in
                            if pressed { model.beginMaskEffectPreview(group.id) } else { model.endMaskEffectPreview() }
                        }, onPulse: { model.pulseMaskEffectPreview(group.id) })
                        .disabled(!group.enabled || group.isNeutral || !model.workspaceAvailable)
                        .accessibilityIdentifier("mask-effect-preview")
                        .accessibilityValue(model.previewingMaskID == group.id ? L10n.text("app.temporarilyHidden_1458", defaultValue: "Temporarily Hidden") : L10n.text("app.normalDisplay", defaultValue: "Normal Display"))
                }
                Text(group.name).font(.caption11).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                groupRow(L10n.text("app.effectAmount", defaultValue: "Effect Amount"), \.amount, value: group.amount, scale: 100, range: 0...100, reset: 100)
                    .padding(.horizontal, 12).padding(.bottom, 6)
                    .help(L10n.text("app.controlsTheCurrentMaskSAdjustmentStrengthAdjustExposure", defaultValue: "Controls the current mask's adjustment strength. Adjust exposure or color first to see an effect"))
                Text(L10n.text("app.adjustExposureOrColorBelowThenControlTheEffect", defaultValue: "Adjust exposure or color below, then control the effect with Amount."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.bottom, 6)
                Seam()
                localParameterActions.padding(.horizontal, 12).padding(.vertical, 6)
                Seam()
                DevelopPanel(model: model, local: true)
                HStack(spacing: Metrics.gap) {
                    Spacer()
                    Button(L10n.text("app.resetAdjustments", defaultValue: "Reset Adjustments")) { model.changeMask { $0.amount = 1; $0.exposure = 0; $0.contrast = 1; $0.saturation = 1; if $0.settings != nil { $0.settings = LocalDevelopSettings() } } }
                        .buttonStyle(.key)
                        .help(L10n.text("app.resetTheCurrentMaskSAdjustmentsWhilePreservingThe", defaultValue: "Reset the current mask's adjustments while preserving the selection"))
                    Button(L10n.text("app.done", defaultValue: "Done")) { model.setMaskMode(false) }.buttonStyle(.key)
                }.padding(12)
            }
        }
        .onChange(of: model.selectedComponentID) { precise = false }
        .alert(L10n.text("app.saveLocalPreset", defaultValue: "Save Local Preset"), isPresented: $savingLocalPreset) {
            TextField(L10n.text("app.presetName", defaultValue: "Preset Name"), text: $localPresetName)
            Button(L10n.text("app.cancel", defaultValue: "Cancel"), role: .cancel) { localPresetName = "" }
            Button(L10n.text("app.save", defaultValue: "Save")) {
                let name = localPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    _ = model.saveLocalParameterPreset(name: name)
                } else {
                    model.error = L10n.text("app.localPresetNamesMustContain1100Characters", defaultValue: "Local preset names must contain 1–100 characters")
                }
                localPresetName = ""
            }
        }
    }
    private var localParameterActions: some View {
        HStack(spacing: 6) {
            Button { model.copyLocalParameters() } label: {
                Label(L10n.text("app.copy_1359", defaultValue: "Copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.key(height: 24, padding: 6))
            .help(L10n.text("app.copyTheCurrentMaskSExposureContrastSaturationAnd", defaultValue: "Copy the current mask's exposure, contrast, saturation, and local development settings without its selection"))
            .accessibilityLabel(L10n.text("app.copyLocalSettings", defaultValue: "Copy Local Settings"))
            .accessibilityIdentifier("mask-copy-local-parameters")

            Button { _ = model.pasteLocalParameters() } label: {
                Label(L10n.text("app.paste", defaultValue: "Paste"), systemImage: "arrow.down.doc")
            }
            .buttonStyle(.key(height: 24, padding: 6))
            .disabled(model.copiedLocalParameters == nil)
            .help(L10n.text("app.applyCopiedLocalSettingsToTheCurrentMaskPreserving", defaultValue: "Apply copied local settings to the current mask, preserving its selection and effect amount"))
            .accessibilityLabel(L10n.text("app.pasteLocalSettings", defaultValue: "Paste Local Settings"))
            .accessibilityIdentifier("mask-paste-local-parameters")
            Menu {
                Button(L10n.text("app.saveCurrentSettings", defaultValue: "Save Current Settings…")) {
                    localPresetName = ""
                    savingLocalPreset = true
                }
                if !model.localParameterPresets.isEmpty {
                    Divider()
                    Section(L10n.text("app.currentCatalog", defaultValue: "Current Catalog")) {
                        ForEach(model.localParameterPresets) { preset in
                            Menu(preset.name) {
                                Button(L10n.text("app.apply", defaultValue: "Apply")) { _ = model.applyLocalParameterPreset(preset) }
                                Button(L10n.text("app.delete", defaultValue: "Delete"), role: .destructive) { _ = model.deleteLocalParameterPreset(preset) }
                            }
                        }
                    }
                } else {
                    Text(L10n.text("app.noLocalPresetsInThisCatalog", defaultValue: "No local presets in this catalog")).foregroundStyle(Theme.textSecondary)
                }
            } label: {
                Label(L10n.text("app.presets", defaultValue: "Presets"), systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .keySurface(height: 24)
            .help(L10n.text("app.saveApplyOrDeleteLocalPresetsInTheCurrent", defaultValue: "Save, apply, or delete local presets in the current catalog"))
            .accessibilityLabel(L10n.text("app.localPresets", defaultValue: "Local Presets"))
            .accessibilityIdentifier("mask-local-parameter-presets")
            Spacer(minLength: 0)
        }.font(.body13).fixedSize(horizontal: false, vertical: true)
    }
    private var maskActions: some View {
        HStack(spacing: 8) {
            ForEach([MaskOperation.add, .subtract], id: \.self) { operation in
                Menu {
                    Button(L10n.text("app.people", defaultValue: "People")) { model.beginSmartMask(operation: operation, workflow: .people) }
                    ForEach(MaskTool.allCases) { tool in
                        Button(tool.title) { model.addMask(tool, operation: operation) }
                            .disabled(tool == .object && SmartMaskEngine.bundledModels.objectDirectory == nil)
                    }
                } label: { Label(operation.title, systemImage: operation == .add ? "plus" : "minus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .keySurface(height: 24).accessibilityLabel(L10n.text("app.maskComponent", defaultValue: "\(operation.title) mask component"))
            }
            Spacer(minLength: 0)
            Button(L10n.text("app.controls", defaultValue: "Controls")) { model.showMaskGuides.toggle() }
                .buttonStyle(.key(selected: hasControlLines && model.showMaskGuides, height: 24, padding: 7, lampInside: true))
                .disabled(!hasControlLines)
                .help(hasControlLines ? L10n.text("app.showPinsAndControlsHSelectionOverlayOIs", defaultValue: "Show pins and controls (H); selection overlay (O) is independent") : L10n.text("app.thisSelectionHasNoControlsUseThisSwitchFor", defaultValue: "This selection has no controls. Use this switch for gradients or color samples"))
                .accessibilityLabel(L10n.text("app.showMaskControls", defaultValue: "Show Mask Controls")).accessibilityValue(hasControlLines ? (model.showMaskGuides ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off")) : L10n.text("app.noControls", defaultValue: "No Controls"))
                .accessibilityAddTraits(hasControlLines && model.showMaskGuides ? .isSelected : [])
        }
    }
    private var hasControlLines: Bool {
        guard let component = model.selectedMaskComponent else { return false }
        return component.tool.isGradient || (component.tool == .color && !component.samples.isEmpty)
    }
    private func toolButton(_ tool: MaskTool) -> some View {
        Button { model.addMask(tool) } label: {
            HStack(spacing: 10) {
                Image(systemName: tool.icon).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).frame(width: 20)
                Text(tool.title)
                Spacer()
                Text(tool.shortcut).font(.caption11).foregroundStyle(Theme.textSecondary)
            }.padding(.horizontal, 12).frame(height: Metrics.row).contentShape(Rectangle())
        }.buttonStyle(.plain).help(tool == .object && SmartMaskEngine.bundledModels.objectDirectory == nil ? L10n.text("smartMask.objectUnavailable", defaultValue: "Object selection is not included in this build") : L10n.text("app.createMask", defaultValue: "Create \(tool.title) Mask"))
            .disabled(tool == .object && SmartMaskEngine.bundledModels.objectDirectory == nil).accessibilityIdentifier("mask-create-\(tool.rawValue)")
    }
    private func refinementControls(_ group: LocalAdjustment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            refinementRow(L10n.text("app.expandContract", defaultValue: "Expand / Contract"), \.expansion, group: group, range: -100...100)
                .help(L10n.text("app.positiveExpandsTheSelectionNegativeContractsItUpTo", defaultValue: "Positive expands the selection; negative contracts it. Up to 2% of the photo's short edge, independent of canvas zoom"))
            refinementRow(L10n.text("app.edgeSnapping", defaultValue: "Edge Snapping"), \.edgeRadius, group: group)
                .help(L10n.text("app.snapNearbyMaskEdgesToTonalBoundariesInThe", defaultValue: "Snap nearby mask edges to tonal boundaries in the photo. Draw close to the boundary first"))
            refinementRow(L10n.text("app.overallSoftness", defaultValue: "Overall Softness"), \.blurRadius, group: group)
                .help(L10n.text("app.softenTheCombinedSelectionSEdgesWithoutBlurringThe", defaultValue: "Soften the combined selection's edges without blurring the photo"))
            refinementRow(L10n.text("app.edgeHardness", defaultValue: "Edge Hardness"), \.hardness, group: group, range: -100...100)
                .help(L10n.text("app.positiveSharpensTransitionsNegativeSoftensThemFullyIncludedAnd", defaultValue: "Positive sharpens transitions; negative softens them. Fully included and excluded areas are preserved"))
            if (group.refinement?.edgeRadius ?? 0) > 0, model.maskReference == nil {
                Text(L10n.text("app.readingOriginalContours", defaultValue: "Reading original contours…")).font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            Text(L10n.text("app.appliesToTheCombinedSelectionALargeSnapRange", defaultValue: "Applies to the combined selection. A large snap range may include nearby areas; refine with contraction and hardness."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }
    private func refinementRow(_ label: String, _ key: WritableKeyPath<MaskRefinement, Double>, group: LocalAdjustment, range: ClosedRange<Double> = 0...100) -> some View {
        AdjustmentRow(label: label, value: (group.refinement ?? MaskRefinement())[keyPath: key] * 100, range: range,
            change: { value, commit in
                model.showMaskOverlay = true
                model.changeMask(commit: commit) {
                    var settings = $0.refinement ?? MaskRefinement(); settings[keyPath: key] = value / 100
                    $0.refinement = settings.isNeutral ? nil : settings
                }
            }, commit: { model.commitRecipe() })
    }
    @ViewBuilder private func toolControls(_ c: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: c.tool.icon).foregroundStyle(Theme.textSecondary)
                Text(c.name).font(.section)
                Spacer()
                Button(L10n.text("app.invert", defaultValue: "Invert")) { model.changeMaskComponent { $0.inverted.toggle() }; model.showMaskOverlay = true }
                    .buttonStyle(.key(selected: c.inverted, height: 24))
                    .accessibilityLabel(L10n.text("app.invertCurrentComponent", defaultValue: "Invert Current Component")).accessibilityValue(c.inverted ? L10n.text("app.on", defaultValue: "On") : L10n.text("app.off", defaultValue: "Off"))
                    .accessibilityAddTraits(c.inverted ? .isSelected : [])
            }
            switch c.tool {
            case .object:
                Button(L10n.text("app.editSmartSelection", defaultValue: "Edit Smart Selection…")) { model.beginSmartMask(replacing: true) }.buttonStyle(.key(height: 24, padding: 6))
                    .accessibilityIdentifier("mask-regenerate-object").disabled(c.raster?.isPersonSelection != true && SmartMaskEngine.bundledModels.objectDirectory == nil)
            case .brush:
                KeyRow(title: L10n.text("app.brushMode", defaultValue: "Brush Mode"), options: [KeyOption(false, L10n.text("app.brush", defaultValue: "Brush")), KeyOption(true, L10n.text("app.erase", defaultValue: "Erase"))], selection: $model.brushErase, expand: true)
                SubgroupLabel(L10n.text("app.autoMask", defaultValue: "Auto Mask"))
                KeyRow(title: L10n.text("app.autoMask", defaultValue: "Auto Mask"), options: [
                    KeyOption(false, L10n.text("app.off", defaultValue: "Off"), help: L10n.text("app.paintTheEntireStrokeRegardlessOfColor", defaultValue: "Paint the entire stroke regardless of color"), identifier: "brush-auto-off"),
                    KeyOption(true, L10n.text("app.on", defaultValue: "On"), help: L10n.text("app.paintColorsSimilarToTheStrokeStartThenSnap", defaultValue: "Paint colors similar to the stroke start, then snap edges to tonal boundaries"), identifier: "brush-auto-on")
                ], selection: Binding(get: { model.brushAutoMask }, set: { value in
                    model.brushAutoMask = value
                    if value { model.showMaskOverlay = true; model.prepareMaskReference() }
                }), expand: true)
                .accessibilityIdentifier("brush-auto-mask")
                brushRow(L10n.text("app.size", defaultValue: "Size"), value: $model.brushRadius, scale: 200, range: 0.2...100)
                brushRow(L10n.text("app.feather", defaultValue: "Feather"), value: $model.brushFeather)
                brushRow(L10n.text("app.flow", defaultValue: "Flow"), value: $model.brushFlow)
                brushRow(L10n.text("app.density", defaultValue: "Density"), value: $model.brushDensity)
                if model.brushAutoMask, model.maskReference == nil {
                    Text(L10n.text("app.readingTheOriginalSoTheBrushCanFollowColor", defaultValue: "Reading the original so the brush can follow color boundaries.")).font(.caption11).foregroundStyle(Theme.textSecondary)
                }
            case .linear:
                drawButton()
                precisePosition(c)
            case .radial:
                componentPercent(L10n.text("app.feather", defaultValue: "Feather"), \.feather, value: c.feather)
                drawButton()
                precisePosition(c)
            case .color:
                HStack(spacing: 8) {
                    samplingButton(c.samples.isEmpty ? L10n.text("app.sample", defaultValue: "Sample") : L10n.text("app.resample", defaultValue: "Resample"))
                    Button {
                        model.maskSampling = true; model.maskSampleAppending = true; model.prepareMaskReference()
                    } label: {
                        Label(L10n.text("app.add", defaultValue: "Add"), systemImage: "plus")
                    }.buttonStyle(.key(selected: model.maskSampling && model.maskSampleAppending))
                        .disabled(c.samples.count >= 16)
                        .help(L10n.text("app.clickThenSampleAnotherColorInThePhotoYou", defaultValue: "Click, then sample another color in the photo. You can also Shift-click the photo"))
                }
                if !c.samples.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 34))], alignment: .leading, spacing: 6) {
                        ForEach(Array(c.samples.enumerated()), id: \.offset) { i, sample in
                            Color(.sRGBLinear, red: sample.red, green: sample.green, blue: sample.blue, opacity: 1)
                                .frame(width: 28, height: 28).overlay(Rectangle().strokeBorder(Theme.controlBorder))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        model.showMaskOverlay = true
                                        model.changeMaskComponent { $0.samples.remove(at: i) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black).font(.system(size: 13))
                                            .frame(width: 18, height: 18)
                                    }.buttonStyle(.plain).opacity(hoveredSample == i ? 1 : 0.45)
                                        .help(L10n.text("app.removeThisColorSample", defaultValue: "Remove This Color Sample")).accessibilityLabel(L10n.text("app.removeColorSample", defaultValue: "Remove color sample \(i + 1)"))
                                }.onHover { hoveredSample = $0 ? i : nil }
                                .help(L10n.text("app.colorSampleClickAtTheTopRightToRemove", defaultValue: "Color sample \(i + 1); click × at the top right to remove it"))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    AdjustmentRow(label: L10n.text("app.similarColors", defaultValue: "Similar Colors"), value: ColorRange.refine(radius: c.tolerance), range: 0...100, reset: ColorRange.defaultRefine,
                        change: { v, commit in
                            let radius = ColorRange.radius(refine: v)
                            model.showMaskOverlay = true
                            model.changeMaskComponent(commit: commit) { $0.tolerance = radius; $0.smoothness = radius }
                        }, commit: { model.commitRecipe() })
                        .help(L10n.text("app.theDefaultIsCenteredMoveRightToIncludeMore", defaultValue: "The default is centered. Move right to include more, left to narrow. Luminance has half weight, keeping slightly lighter or darker shades of the same color."))
                    scaleLegend(L10n.text("app.narrower", defaultValue: "Narrower"), L10n.text("app.wider", defaultValue: "Wider"))
                }.disabled(c.samples.isEmpty)
                if c.samples.isEmpty { Text(L10n.text("app.sampleThePhotoFirstThenAdjustSimilarColors", defaultValue: "Sample the photo first, then adjust Similar Colors.")).font(.caption11).foregroundStyle(Theme.textSecondary) }
            case .luminance:
                SubgroupLabel(L10n.text("app.luminanceRange", defaultValue: "Luminance Range"))
                MaskLuminanceSlider(model: model, lower: c.lower, upper: c.upper)
                HStack {
                    Text(L10n.text("app.dark", defaultValue: "Dark"))
                    TextField(L10n.text("app.minimumLuminance", defaultValue: "Minimum Luminance"), value: Binding(get: { c.lower * 100 }, set: { v in model.showMaskOverlay = true; model.changeMaskComponent { $0.lower = min($0.upper, max(0, v / 100)) } }), format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.instrument)
                    Spacer()
                    TextField(L10n.text("app.maximumLuminance", defaultValue: "Maximum Luminance"), value: Binding(get: { c.upper * 100 }, set: { v in model.showMaskOverlay = true; model.changeMaskComponent { $0.upper = max($0.lower, min(1, v / 100)) } }), format: .number.precision(.fractionLength(0)))
                        .frame(width: 48).textFieldStyle(.instrument)
                    Text(L10n.text("app.light", defaultValue: "Light"))
                }.monospacedDigit()
                componentPercent(L10n.text("app.smoothness", defaultValue: "Smoothness"), \.smoothness, value: c.smoothness)
                samplingButton(L10n.text("app.selectLuminance", defaultValue: "Select Luminance"))
            }
            if (c.tool == .color || c.tool == .luminance), model.maskReference == nil {
                Text(L10n.text("app.preparingSampling", defaultValue: "Preparing sampling…")).font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            if c.tool != .color {
                Text(model.maskInstruction).font(.caption11).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12)
    }
    private func scaleLegend(_ low: String, _ high: String) -> some View {
        HStack { Text(low); Spacer(); Text(high) }
            .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            .padding(.leading, Metrics.rowLabel + Metrics.gap).padding(.trailing, Metrics.rowValue + Metrics.gap)
    }
    private func samplingButton(_ title: String) -> some View {
        Button { model.maskSampling.toggle(); model.maskSampleAppending = false; model.prepareMaskReference() } label: {
            Label(model.maskSampling ? (model.maskSampleAppending ? L10n.text("app.clickToAddSamplesFinish", defaultValue: "Click to add samples · Finish") : L10n.text("app.clickToSampleFinish", defaultValue: "Click to sample · Finish")) : title, systemImage: "eyedropper")
                .frame(maxWidth: .infinity)
        }.buttonStyle(.key(selected: model.maskSampling && !model.maskSampleAppending))
            .accessibilityLabel(title)
    }
    private func drawButton() -> some View {
        Button(model.maskDrawNew ? L10n.text("app.dragOnThePhotoToDraw", defaultValue: "Drag on the photo to draw…") : L10n.text("app.drawAgain", defaultValue: "Draw Again")) { model.maskDrawNew = true; model.showMaskOverlay = true }
            .buttonStyle(.key(selected: model.maskDrawNew))
    }
    private func precisePosition(_ c: MaskComponent) -> some View {
        DisclosureGroup(L10n.text("app.exactPosition", defaultValue: "Exact Position"), isExpanded: $precise) {
            VStack(spacing: 3) {
                componentRow(c.tool == .radial ? L10n.text("app.centerX", defaultValue: "Center X") : L10n.text("app.startX", defaultValue: "Start X"), \.start.x, value: c.start.x)
                componentRow(c.tool == .radial ? L10n.text("app.centerY", defaultValue: "Center Y") : L10n.text("app.startY", defaultValue: "Start Y"), \.start.y, value: c.start.y)
                if c.tool == .linear {
                    componentRow(L10n.text("app.endX", defaultValue: "End X"), \.end.x, value: c.end.x); componentRow(L10n.text("app.endY", defaultValue: "End Y"), \.end.y, value: c.end.y)
                } else {
                    componentRow(L10n.text("app.horizontalRadius", defaultValue: "Horizontal Radius"), \.radiusX, value: c.radiusX, range: 0.001...100)
                    componentRow(L10n.text("app.verticalRadius", defaultValue: "Vertical Radius"), \.radiusY, value: c.radiusY, range: 0.001...100)
                    componentRow(L10n.text("app.angle", defaultValue: "Angle"), \.angle, value: c.angle, range: -180...180)
                }
            }.padding(.top, 6)
        }.foregroundStyle(Theme.textSecondary)
    }
    private func groupRow(_ label: String, _ key: WritableKeyPath<LocalAdjustment, Double>, value: Double, scale: Double, offset: Double = 0, range: ClosedRange<Double>, reset: Double, digits: Int = 0) -> some View {
        AdjustmentRow(label: label, value: value * scale + offset, range: range, step: digits == 0 ? 1 : 0.01, digits: digits, reset: reset,
            change: { v, commit in model.showMaskOverlay = false; model.changeMask(commit: commit) { $0[keyPath: key] = (v - offset) / scale } }, commit: { model.commitRecipe() })
    }
    private func componentPercent(_ label: String, _ key: WritableKeyPath<MaskComponent, Double>, value: Double) -> some View {
        AdjustmentRow(label: label, value: value * 100, range: 0...100,
            change: { v, commit in model.showMaskOverlay = true; model.changeMaskComponent(commit: commit) { $0[keyPath: key] = v / 100 } }, commit: { model.commitRecipe() })
    }
    private func componentRow(_ label: String, _ key: WritableKeyPath<MaskComponent, Double>, value: Double, range: ClosedRange<Double> = MaskPoint.gradientRange) -> some View {
        AdjustmentRow(label: label, value: value, range: range, step: 0.01, digits: 2,
            change: { v, commit in model.changeMaskComponent(commit: commit) { $0[keyPath: key] = v } }, commit: { model.commitRecipe() })
    }
    private func brushRow(_ label: String, value: Binding<Double>, scale: Double = 100, range: ClosedRange<Double> = 0...100) -> some View {
        AdjustmentRow(label: label, value: value.wrappedValue * scale, range: range,
            change: { v, _ in value.wrappedValue = v / scale }, commit: {})
    }
}

/// Docked at the canvas trailing edge, before the tool inspector.
struct MaskListPanel: View {
    @Bindable var model: AppModel
    @State private var rename = false
    @State private var renameComponent = false
    @State private var name = ""
    @State private var collapsed: Set<UUID> = []
    @State private var overlayColors = false
    private var groups: [LocalAdjustment] { model.recipe?.localAdjustments ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("app.masks", defaultValue: "Masks")).font(.section)
                Text("\(groups.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { model.maskChoosingTool = true; model.maskSampling = false } label: {
                    Image(systemName: "plus")
                }.buttonStyle(.key(selected: model.maskChoosingTool, height: 24, padding: 7))
                    .help(L10n.text("app.newMask", defaultValue: "New Mask")).accessibilityLabel(L10n.text("app.newMask", defaultValue: "New Mask")).accessibilityIdentifier("mask-create-new")
            }.padding(.horizontal, 12).frame(height: 36).background(Theme.panel)
            Seam()
            ScrollViewReader { proxy in
                ScrollView { maskRows }.frame(maxHeight: .infinity)
                    .onChange(of: model.selectedMaskID) { id in if let id { proxy.scrollTo(id, anchor: .top) } }
            }
            Seam()
            HStack(spacing: 8) {
                Toggle(L10n.text("app.showSelection", defaultValue: "Show Selection"), isOn: $model.showMaskOverlay).toggleStyle(.instrument).help(L10n.text("app.showMaskSelectionO", defaultValue: "Show Mask Selection (O)"))
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            HStack(spacing: 8) {
                Menu {
                    Picker(L10n.text("app.selectionPreviewMode", defaultValue: "Selection Preview Mode"), selection: $model.maskOverlayStyle) {
                        ForEach(MaskOverlayStyle.allCases) { style in Text(style.title).tag(style) }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    HStack(spacing: 4) {
                        Text(model.maskOverlayStyle.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize()
                .keySurface(height: 24)
                .help(model.maskOverlayStyle.help)
                .accessibilityLabel(L10n.text("app.selectionPreviewMode", defaultValue: "Selection Preview Mode")).accessibilityValue(model.maskOverlayStyle.title)
                .accessibilityIdentifier("mask-overlay-style")
                .onChange(of: model.maskOverlayStyle) { _ in model.showMaskOverlay = true }
                Spacer(minLength: 0)
                Button { overlayColors = true } label: {
                    Rectangle().fill([Color.red, .green, .blue][min(2, max(0, model.maskOverlayColor))]).frame(width: 14, height: 14)
                        .overlay(Rectangle().strokeBorder(Theme.controlBorder))
                }.buttonStyle(.key(selected: overlayColors, height: 24, padding: 5))
                    .help(model.maskOverlayStyle.usesTint ? L10n.text("app.overlayColor", defaultValue: "Overlay Color") : L10n.text("app.overlayColorUnusedByTheCurrentPreviewMode", defaultValue: "Overlay color; unused by the current preview mode"))
                    .accessibilityLabel(L10n.text("app.overlayColor", defaultValue: "Overlay Color")).popover(isPresented: $overlayColors) {
                    KeyRow(title: L10n.text("app.overlayColor", defaultValue: "Overlay Color"), options: [KeyOption(0, L10n.text("app.red", defaultValue: "Red")), KeyOption(1, L10n.text("app.green", defaultValue: "Green")), KeyOption(2, L10n.text("app.blue", defaultValue: "Blue"))],
                           selection: Binding(get: { model.maskOverlayColor }, set: { model.maskOverlayColor = $0; overlayColors = false }))
                        .padding(12)
                }
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }.frame(maxWidth: .infinity)
        .background(Theme.panel).accessibilityIdentifier("mask-list")
        .alert(L10n.text("app.rename_1545", defaultValue: "Rename"), isPresented: $rename) {
            TextField(L10n.text("app.name", defaultValue: "Name"), text: $name)
            Button(L10n.text("app.cancel", defaultValue: "Cancel"), role: .cancel) {}
            Button(L10n.text("app.save", defaultValue: "Save")) {
                let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                if !value.isEmpty {
                    if renameComponent { model.changeMaskComponent { $0.name = value } }
                    else { model.changeMask { $0.name = value } }
                }
            }
        }
    }
    private var maskRows: some View {
        VStack(spacing: 0) {
            ForEach(groups) { group in
                maskRow(group).id(group.id)
                if model.selectedMaskID == group.id, !collapsed.contains(group.id) {
                    ForEach(group.components) { component in componentRow(component, group: group) }
                }
            }
        }.padding(.vertical, 6)
    }
    private func maskRow(_ group: LocalAdjustment) -> some View {
        let selected = model.selectedMaskID == group.id
        return HStack(spacing: 6) {
            Button {
                if selected {
                    if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                } else { model.selectMask(group.id, component: nil); collapsed.remove(group.id) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(selected && !collapsed.contains(group.id) ? 90 : 0))
                    .foregroundStyle(Theme.textSecondary).frame(width: 12, height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("app.expandOrCollapse", defaultValue: "Expand or collapse \(group.name)"))
            Button { model.selectMask(group.id, component: nil); collapsed.remove(group.id) } label: {
                HStack(spacing: 8) {
                    MaskThumbnail(group: group, recipe: model.recipe, size: model.orientedSourceSize, reference: model.maskReference)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.name).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                        Text(L10n.text("app.selections", defaultValue: "\(group.components.count) selections")).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if group.inverted { Image(systemName: "circle.lefthalf.filled").font(.system(size: 9)).foregroundStyle(Theme.textSecondary) }
                }.frame(height: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(group.name).accessibilityValue(selected && model.selectedComponentID == nil ? L10n.text("app.selectedMask", defaultValue: "Selected Mask") : "")
            LampSwitch(title: L10n.text("app.adjustments_1550", defaultValue: "\(group.name) adjustments"), isOn: Binding(get: { group.enabled }, set: { _ in model.toggleMaskAdjustment(group.id) }))
                .help(group.enabled ? L10n.text("app.disableThisMaskSAdjustmentsWhilePreservingItsSelection", defaultValue: "Disable this mask's adjustments while preserving its selection and settings") : L10n.text("app.enableThisMaskSAdjustments", defaultValue: "Enable this mask's adjustments"))
                .accessibilityIdentifier("mask-toggle-\(group.id)")
            Menu {
                Button(L10n.text("app.rename", defaultValue: "Rename…")) { model.selectMask(group.id, component: nil); name = group.name; renameComponent = false; rename = true }
                Button(L10n.text("app.invertMask", defaultValue: "Invert Mask")) { model.selectMask(group.id, component: nil); model.changeMask { $0.inverted.toggle() }; model.showMaskOverlay = true }
                ForEach([MaskOperation.add, .subtract, .intersect], id: \.self) { operation in
                    Menu(operation.title) {
                        ForEach(MaskTool.allCases) { tool in
                            Button(tool.title) {
                                model.selectMask(group.id, component: nil)
                                model.addMask(tool, operation: operation)
                            }
                        }
                    }
                }
                Divider()
                Button(L10n.text("app.duplicateMask", defaultValue: "Duplicate Mask")) { model.selectMask(group.id, component: nil); model.duplicateMask() }
                Button(group.enabled ? L10n.text("app.disableAdjustments", defaultValue: "Disable Adjustments") : L10n.text("app.enableAdjustments", defaultValue: "Enable Adjustments")) { model.toggleMaskAdjustment(group.id) }
                Divider()
                Button(L10n.text("app.deleteMask", defaultValue: "Delete Mask"), role: .destructive) { model.selectMask(group.id, component: nil); model.deleteMask() }
            } label: { Image(systemName: "ellipsis").frame(width: 16, height: 24) }
                .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize().accessibilityLabel(L10n.text("app.menu", defaultValue: "\(group.name) menu"))
        }.padding(.horizontal, 8)
        .background(selected && model.selectedComponentID == nil ? Theme.selected : .clear)
        .overlay(alignment: .leading) { if selected && model.selectedComponentID == nil { Theme.accentSignal.frame(width: 2) } }
    }
    private func componentRow(_ c: MaskComponent, group: LocalAdjustment) -> some View {
        let selected = model.selectedComponentID == c.id && !model.maskChoosingTool
        let ordinal = group.components.prefix(while: { $0.id != c.id }).filter { $0.tool == c.tool }.count + 1
        let title = c.name == c.tool.title ? "\(c.name) \(ordinal)" : c.name
        return HStack(spacing: 4) {
            Text(c.operation == .replace ? L10n.text("app.base", defaultValue: "Base") : c.operation.title)
                .font(.system(size: 10)).frame(width: 28).foregroundStyle(Theme.textSecondary)
            Button { model.selectMask(group.id, component: c.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: c.tool.icon).foregroundStyle(Theme.textSecondary).frame(width: 18)
                    Text(title).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(c.enabled ? Theme.text : Theme.textDisabled)
                    Spacer(minLength: 2)
                    if c.inverted { Image(systemName: "circle.lefthalf.filled").font(.system(size: 9)) }
                    if !c.enabled { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(Theme.textSecondary) }
                }.padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(c.operation.title) · \(title)").accessibilityValue(selected ? L10n.text("app.selectedComponent", defaultValue: "Selected Component") : "")
            Menu {
                Button(L10n.text("app.rename", defaultValue: "Rename…")) { model.selectMask(group.id, component: c.id); name = c.name; renameComponent = true; rename = true }
                Button(L10n.text("app.invertComponent", defaultValue: "Invert Component")) { model.selectMask(group.id, component: c.id); model.changeMaskComponent { $0.inverted.toggle() }; model.showMaskOverlay = true }
                Button(c.enabled ? L10n.text("app.hideComponent", defaultValue: "Hide Component") : L10n.text("app.showComponent", defaultValue: "Show Component")) { model.selectMask(group.id, component: c.id); model.changeMaskComponent { $0.enabled.toggle() } }
                Divider()
                Button(L10n.text("app.deleteComponent", defaultValue: "Delete Component"), role: .destructive) { model.selectMask(group.id, component: c.id); model.deleteMaskComponent() }
            } label: { Image(systemName: "ellipsis").frame(width: 14, height: 24) }
                .menuStyle(.borderlessButton).tint(Theme.text).menuIndicator(.hidden).fixedSize().accessibilityLabel(L10n.text("app.menu", defaultValue: "\(title) menu"))
        }.padding(.leading, 26).padding(.trailing, 8)
        .background(selected ? Theme.selected : .clear)
        .overlay(alignment: .leading) { if selected { Theme.accentSignal.frame(width: 2) } }
    }

}

private struct MaskThumbnail: View {
    struct Input: Equatable {
        var group: LocalAdjustment; var recipe: EditRecipe?; var size: CGSize?; var reference: CGImage?
        static func == (a: Self, b: Self) -> Bool { a.group == b.group && a.recipe == b.recipe && a.size == b.size && a.reference === b.reference }
    }
    let group: LocalAdjustment
    let recipe: EditRecipe?
    let size: CGSize?
    let reference: CGImage?
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.black
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "circle.dotted").foregroundStyle(.secondary) }
        }.frame(width: 30, height: 26).overlay(Rectangle().strokeBorder(Theme.controlBorder)).accessibilityHidden(true)
        .task(id: Input(group: group, recipe: recipe, size: size, reference: reference)) {
            guard let size, let recipe else { return }
            if group.needsBaseline, reference == nil { image = nil; return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let rendered = try await Task.detached(priority: .utility) {
                    let scale = 96 / max(size.width, size.height)
                    let extent = CGRect(x: 0, y: 0, width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
                    var visible = group; visible.enabled = true; visible.amount = 1
                    let mask = try ImagePipeline.geometry(try MaskPipeline.mask(visible, extent: extent, baseline: reference.map { CIImage(cgImage: $0) }), recipe: recipe, referenceSize: size)
                    return CIContext(options: [.workingFormat: CIFormat.RGBAf]).createCGImage(mask, from: mask.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
                }.value
                if !Task.isCancelled { image = rendered }
            } catch { /* A cancelled thumbnail keeps the previous preview during drawing. */ }
        }
    }
}

private struct MaskLuminanceSlider: View {
    @Bindable var model: AppModel
    let lower: Double
    let upper: Double
    @State private var editingLower: Bool?
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 16)
            ZStack(alignment: .leading) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing).frame(height: 8).padding(.horizontal, 8)
                Rectangle().stroke(Theme.accentSignal, lineWidth: 2).frame(width: max(1, (upper - lower) * width), height: 14).offset(x: lower * width + 8)
                ForEach([true, false], id: \.self) { isLower in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Theme.keyTop, Theme.keyBottom], startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.controlBorder))
                        .frame(width: 9, height: 18).offset(x: (isLower ? lower : upper) * width + 3.5)
                }
            }.frame(height: 28).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let value = min(1, max(0, (event.location.x - 8) / width))
                    if editingLower == nil { editingLower = lower == upper ? value <= lower : abs(value - lower) < abs(value - upper) }
                    model.showMaskOverlay = true
                    model.changeMaskComponent(commit: false) { c in
                        if editingLower == true { c.lower = min(value, c.upper) } else { c.upper = max(value, c.lower) }
                    }
                }.onEnded { _ in editingLower = nil; model.commitRecipe() })
        }.frame(height: 28)
        .accessibilityRepresentation {
            VStack {
                Slider(value: Binding(get: { lower * 100 }, set: { v in model.changeMaskComponent { $0.lower = min(v / 100, $0.upper) } }), in: 0...100).accessibilityLabel(L10n.text("app.luminanceRangeMinimum", defaultValue: "Luminance Range Minimum"))
                Slider(value: Binding(get: { upper * 100 }, set: { v in model.changeMaskComponent { $0.upper = max(v / 100, $0.lower) } }), in: 0...100).accessibilityLabel(L10n.text("app.luminanceRangeMaximum", defaultValue: "Luminance Range Maximum"))
            }
        }
    }
}
