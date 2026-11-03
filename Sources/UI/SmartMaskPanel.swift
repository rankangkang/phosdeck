import SwiftUI

struct SmartMaskPanel: View {
    @Bindable var model: AppModel
    var compact = false
    @FocusState private var focusedTarget: SmartMaskInspectionTarget?
    @State private var faceRefinementOpen = false
    var body: some View {
        if let session = model.smartMaskSession {
            VStack(spacing: 0) {
                PanelTitle(session.workflow == .people ? L10n.text("app.selectPerson", defaultValue: "Select Person") : L10n.text("app.selectObject", defaultValue: "Select Object")) {
                    Button(L10n.text("app.back", defaultValue: "Back")) { model.cancelSmartMask(); model.maskChoosingTool = true }.buttonStyle(.key(height: 22))
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("smart-mask-cancel")
                }
                if !compact { SmartMaskInspectionHint(session: session).padding(.horizontal, 12).padding(.top, 8) }
                VStack(alignment: .leading, spacing: 10) {
                    if session.workflow == .people { peopleControls(session) }
                    else { objectControls(session) }

                }.padding(12)
            }
            .onChange(of: focusedTarget) { _, target in model.focusSmartMask(target, sessionID: session.id) }
            .onChange(of: session.inspection.focused) { _, target in if target == nil { focusedTarget = nil } }
            .onChange(of: session.id) { _, _ in focusedTarget = nil }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                focusedTarget = nil; session.inspection.clear()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                focusedTarget = nil; session.inspection.clear()
            }
            .onDisappear { focusedTarget = nil; session.inspection.clear() }
        }
    }
    private func inspectable<Content: View>(_ content: Content, target: SmartMaskInspectionTarget, session: SmartMaskSession) -> some View {
        content.focusable(true).focusEffectDisabled().focused($focusedTarget, equals: target)
            .overlay {
                if case .part = target, focusedTarget == target {
                    RoundedRectangle(cornerRadius: 3).stroke(Theme.focusRing, lineWidth: 1.5).padding(-2).allowsHitTesting(false)
                }
            }
            .onHover { model.inspectSmartMask(target, hovering: $0, sessionID: session.id) }
            .onKeyPress(.upArrow) { moveFocus(-1, session: session) }
            .onKeyPress(.downArrow) { moveFocus(1, session: session) }
            .onKeyPress(.leftArrow) { moveFocus(-1, session: session) }
            .onKeyPress(.rightArrow) { moveFocus(1, session: session) }
            .help(L10n.text("smartMask.inspectHelp", defaultValue: "Hover to preview. Use Tab and arrow keys to inspect; Return selects the focused option"))
    }
    private func moveFocus(_ step: Int, session: SmartMaskSession) -> KeyPress.Result {
        let targets: [SmartMaskInspectionTarget] = session.workflow == .object
            ? session.candidates.indices.map { .candidate($0) }
            : (session.people.count > 1 ? [.allPeople] : []) + session.people.indices.map { .person($0) } + [.wholePerson] + SmartMaskPart.allCases.map { .part($0) }
        let available = targets.filter { session.raster(for: $0) != nil }
        guard let focusedTarget, let index = available.firstIndex(of: focusedTarget) else { return .ignored }
        self.focusedTarget = available[min(available.count - 1, max(0, index + step))]
        return .handled
    }
    private func objectControls(_ session: SmartMaskSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("app.1SelectionMethod", defaultValue: "1  Selection Method")).font(.section)
            KeyRow(title: L10n.text("app.mouse", defaultValue: "Mouse"), options: [KeyOption(SmartMaskPickMode.include, L10n.text("app.clickToAdd", defaultValue: "Click to Add")),
                KeyOption(.exclude, L10n.text("app.clickToExclude", defaultValue: "Click to Exclude")), KeyOption(.box, L10n.text("app.boxSelection", defaultValue: "Box Selection"))],
                selection: Binding(get: { session.mode }, set: { model.smartMaskSession?.mode = $0 }), expand: true)
            Text(session.pointerInstruction).font(.body13).foregroundStyle(Theme.textSecondary)
                .frame(height: 38, alignment: .top).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("app.undoLastStep", defaultValue: "Undo Last Step")) { model.undoSmartPrompt() }.buttonStyle(.key(height: 24, padding: 6))
                    .disabled(!session.ready || session.promptHistory.isEmpty).accessibilityIdentifier("smart-mask-undo-prompt")
                Spacer(minLength: 0)
                Text("\(session.prompts.count)/64").font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            Seam()
            Text(L10n.text("app.2ReviewSelection", defaultValue: "2  Review Selection")).font(.section)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    inspectable(Button { model.chooseSmartCandidate(index) } label: {
                        VStack(spacing: 4) {
                            if session.candidates.indices.contains(index), let image = session.candidates[index].thumbnail {
                                Image(decorative: image, scale: 1).resizable().scaledToFit().frame(height: 54)
                            } else { Image(systemName: "square.dashed").foregroundStyle(Theme.textSecondary).frame(height: 54) }
                            Text("\(index + 1)").font(.caption11)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.key(selected: session.candidates.indices.contains(index) && session.candidate == index, height: 84, padding: 5)),
                        target: .candidate(index), session: session)
                    .disabled(session.busy || !session.candidates.indices.contains(index))
                    .accessibilityLabel(SmartMaskInspectionTarget.candidate(index).title)
                    .accessibilityValue(session.candidates.indices.contains(index) && session.candidate == index ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected"))
                    .accessibilityIdentifier("smart-mask-candidate-\(index)")
                }
            }.accessibilityIdentifier("smart-mask-candidates")
            Text(L10n.text("app.selectAPersonAnimalOrObjectDrawingABox", defaultValue: "Select a person, animal, or object. Drawing a box chooses a new target; clicking refines it."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func peopleControls(_ session: SmartMaskSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("app.1SelectPerson", defaultValue: "1  Select Person")).font(.section)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    if session.people.count > 1 {
                        inspectable(Button { model.selectAllSmartPeople() } label: {
                            SmartMaskAvatar(image: nil, title: SmartMaskInspectionTarget.allPeople.title, symbol: "person.2.fill",
                                selected: session.selectedPeople == Set(session.people.indices), focused: focusedTarget == .allPeople)
                        }.buttonStyle(.plain), target: .allPeople, session: session)
                            .disabled(!session.ready).accessibilityLabel(SmartMaskInspectionTarget.allPeople.title)
                            .accessibilityValue(session.selectedPeople == Set(session.people.indices) ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected"))
                            .accessibilityIdentifier("smart-mask-people-all")
                    }
                    ForEach(session.people.indices, id: \.self) { index in
                        inspectable(Button { model.chooseSmartPerson(index) } label: {
                            SmartMaskAvatar(image: session.people[index].thumbnail, title: SmartMaskInspectionTarget.person(index).title,
                                selected: session.selectedPeople.contains(index), focused: focusedTarget == .person(index))
                        }.buttonStyle(.plain), target: .person(index), session: session)
                            .disabled(!session.ready).accessibilityLabel(L10n.text("app.selectPerson_1907", defaultValue: "Select Person \(index + 1)"))
                            .accessibilityValue(session.selectedPeople.contains(index) ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected"))
                            .accessibilityIdentifier("smart-mask-person-\(index)")
                    }
                    if session.people.isEmpty {
                        Text(session.busy ? L10n.text("app.findingPeople", defaultValue: "Finding people…") : L10n.text("app.noPeopleDetected", defaultValue: "No people detected"))
                            .font(.body13).foregroundStyle(Theme.textSecondary).frame(height: 76)
                    }
                }.padding(.vertical, 3)
            }.scrollIndicators(.hidden).frame(height: 82)
            Text(L10n.text("smartMask.selectedPeople", defaultValue: "\(session.selectedPeople.count) selected · Click portraits to add or remove people"))
                .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Seam()
            Text(L10n.text("app.2SelectRegion", defaultValue: "2  Select Region")).font(.section)
            inspectable(Button(L10n.text("app.wholePerson", defaultValue: "Whole Person")) { model.selectWholeSmartPerson() }
                .buttonStyle(.key(selected: session.wholePerson && session.instance != nil, height: 26)), target: .wholePerson, session: session)
                .disabled(session.instance == nil).accessibilityValue(session.wholePerson && session.instance != nil ? L10n.text("app.selected", defaultValue: "Selected") : L10n.text("app.notSelected", defaultValue: "Not selected")).accessibilityIdentifier("smart-mask-whole-person")
            ForEach(SmartMaskPart.allCases) { part in
                inspectable(Toggle(isOn: Binding(get: { !session.wholePerson && session.selectedParts.contains(part) }, set: { _ in model.toggleSmartPart(part) })) {
                    HStack(spacing: 4) {
                        Text(part.title + (part == .faceSkin && session.parts != nil && !session.faceRefined
                            ? (!session.unrefinedPeople.isEmpty && session.unrefinedPeople.count < session.selectedPeople.count
                               ? L10n.text("smartMask.partlyCoarse", defaultValue: " · Partly Coarse") : L10n.text("app.coarse", defaultValue: " · Coarse")) : ""))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if session.parts?[part] == nil {
                            Text(!session.models.supports(part) ? L10n.text("smartMask.partUnavailable", defaultValue: "Not Included") : session.analyzingParts ? L10n.text("app.analyzing", defaultValue: "Analyzing") : session.selectedPeople.isEmpty ? "" : L10n.text("app.notDetected", defaultValue: "Not Detected"))
                                .foregroundStyle(Theme.textSecondary).font(.caption11)
                        }
                    }
                }.toggleStyle(.checkbox).font(.body13), target: .part(part), session: session)
                    .disabled(session.analyzingParts || session.parts?[part] == nil)
                    .accessibilityIdentifier("smart-mask-part-\(part.rawValue)")
            }
            if case .newMask = session.target {
                Toggle(L10n.text("app.createASeparateMaskForEachPart", defaultValue: "Create a Separate Mask for Each Part"), isOn: Binding(get: { session.separate }, set: { model.smartMaskSession?.separate = $0 }))
                    .toggleStyle(.checkbox).font(.body13).disabled(session.wholePerson || session.parts == nil)
                    .accessibilityIdentifier("smart-mask-separate-parts")
            }
            if session.models.faceURL != nil {
                DisclosureGroup(L10n.text("app.faceLocationAndRefinement", defaultValue: "Face Location and Refinement"), isExpanded: $faceRefinementOpen) {
                    VStack(alignment: .leading, spacing: 8) {
                        if session.faces.count > 1 {
                            ForEach(session.faces.indices, id: \.self) { index in
                                Button(L10n.text("app.face", defaultValue: "Face \(index + 1)")) { model.chooseSmartFace(index) }
                                    .buttonStyle(.key(selected: session.selectedFace == index, height: 24))
                                    .disabled(session.analyzingParts)
                                    .accessibilityIdentifier("smart-mask-face-\(index)")
                            }
                        }
                        Button(L10n.text("app.drawFaceBoxManually", defaultValue: "Draw Face Box Manually")) { model.smartMaskSession?.mode = .face }
                            .buttonStyle(.key(selected: session.mode == .face, height: 26))
                            .disabled(session.selectedPeople.count != 1 || session.instance == nil || session.analyzingParts).accessibilityIdentifier("smart-mask-manual-face")
                        Button(L10n.text("smartMask.resetFace", defaultValue: "Use Automatic Face Detection")) { model.resetSmartFace() }
                            .buttonStyle(.key(height: 26)).disabled(!session.canResetFace)
                            .accessibilityIdentifier("smart-mask-reset-face")
                            .help(session.faceFailure ?? L10n.text("smartMask.resetFaceHelp", defaultValue: "Discard this person's manual face region and restore automatic detection"))
                        if session.selectedPeople.count > 1 {
                            Text(L10n.text("smartMask.singleFaceRefinement", defaultValue: "Select one person to adjust their face region"))
                                .font(.caption11).foregroundStyle(Theme.textSecondary)
                        }
                        Text(session.mode == .face ? session.pointerInstruction : L10n.text("app.facialSkinExcludesDetectedEyebrowsEyesAndLipsRefine", defaultValue: "Facial skin excludes detected eyebrows, eyes, and lips. Refine hair and occlusions with a brush after creating the mask."))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 6)
                }.font(.caption11).accessibilityIdentifier("smart-mask-face-refinement")
            }
        }
    }
}

private struct SmartMaskAvatar: View {
    let image: CGImage?
    let title: String
    var symbol = "person.fill"
    let selected: Bool
    let focused: Bool
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Theme.inset)
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                else { Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Theme.textSecondary) }
            }.frame(width: 44, height: 44).clipShape(Circle())
                .overlay { Circle().strokeBorder(selected ? Theme.accentSignal : Theme.controlBorder, lineWidth: selected ? 2 : 0.5) }
                .padding(3)
                .overlay { if focused { Circle().strokeBorder(Theme.focusRing, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])) } }
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                            .foregroundStyle(Theme.accentSignal).background(Circle().fill(Theme.panel))
                    }
                }
            Text(title).font(.caption11).foregroundStyle(Theme.text).lineLimit(1)
        }.frame(width: 68, height: 76).contentShape(Rectangle())
    }
}

private struct SmartMaskInspectionHint: View {
    let session: SmartMaskSession
    var body: some View {
        let target = session.inspectedRaster == nil ? nil : session.inspection.target
        Text(target.map { target in
            session.inspection.hovered != nil
                ? L10n.text("smartMask.hovering", defaultValue: "Preview: \(target.title) · Click to select")
                : L10n.text("smartMask.inspecting", defaultValue: "Preview: \(target.title) · Return to select")
        }
             ?? L10n.text("smartMask.inspectHint", defaultValue: "Hover or use Tab to preview a selection"))
            .font(.caption11).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30, alignment: .top)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("smart-mask-inspection")
    }
}

struct SmartMaskFooter: View {
    @Bindable var model: AppModel
    var compact = false
    var body: some View {
        if let session = model.smartMaskSession {
            VStack(alignment: .leading, spacing: 8) {
                Seam()
                HStack(alignment: .top, spacing: 8) {
                    ProgressView().controlSize(.small)
                        .opacity(session.busy || session.combining || session.analyzingParts ? 1 : 0)
                    Text(session.combining ? L10n.text("app.updatingPreview", defaultValue: "Updating preview…") : session.message)
                        .font(.caption11).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }.frame(minHeight: compact ? 24 : 40, alignment: .top).accessibilityElement(children: .combine)
                Button(createTitle(session)) { model.createSmartMask() }.buttonStyle(.key)
                    .keyboardShortcut(.defaultAction).disabled(!session.canCreate)
                    .accessibilityIdentifier("smart-mask-create")
            }.padding(compact ? 8 : 12).background(Theme.panel)
        }
    }
    private func createTitle(_ session: SmartMaskSession) -> String {
        switch session.target {
        case .newMask:
            if session.creationCount > 1 { L10n.text("smartMask.createMasks", defaultValue: "Create \(session.creationCount) Masks") }
            else if session.creationCount == 1 { L10n.text("smartMask.createOneMask", defaultValue: "Create 1 Mask") }
            else { L10n.text("app.createMask_1920", defaultValue: "Create Mask") }
        case .append: L10n.text("app.addSelection", defaultValue: "Add Selection")
        case .replace: L10n.text("app.replaceSelection", defaultValue: "Replace Selection")
        }
    }
}
