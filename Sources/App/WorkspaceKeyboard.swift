import AppKit

@MainActor
final class WorkspaceKeyboard {
    private var monitor: Any?
    init(model: AppModel) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            return Self.handle(event, model: model)
        }
    }
    static func handle(_ event: NSEvent, model: AppModel) -> NSEvent? {
        guard model.workspaceAvailable else { return event }
        guard let window = event.window, isWorkspaceWindow(window),
              window.attachedSheet == nil, !(window.firstResponder is NSTextView),
              !(window.firstResponder is NSControl) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if model.smartMaskSession != nil {
            if event.keyCode == 53 { model.cancelSmartMask(); return nil }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "z" { model.undoSmartPrompt(); return nil }
            if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 { model.undoSmartPrompt(); return nil }
            if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
                if model.smartMaskSession?.inspection.focused != nil { model.selectFocusedSmartMask() }
                else { model.createSmartMask() }
                return nil
            }
            if model.smartMaskSession?.inspection.focused != nil, modifiers.intersection([.command, .control, .option]).isEmpty { return event }
        }
        if model.presetListFocused, modifiers.intersection([.command, .control, .option]).isEmpty { return event }
        if event.keyCode == 53, model.isPreviewingAdjustment { model.endAdjustmentPreview(); return nil }
        if event.keyCode == 53, model.previewingMaskID != nil { model.endMaskEffectPreview(); return nil }
        if modifiers == .command, event.keyCode == 30 || event.keyCode == 33 {
            if !event.isARepeat { model.navigateBrowse(event.keyCode == 33 ? -1 : 1) }
            return nil
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "l" { model.toggleFilters(); return nil }
        // Lightroom's direct 100% inspection command. Keep this before the
        // ordinary command guard so text fields and culling never see it.
        if (model.editMode || model.singleView), model.comparison == nil, model.survey == nil,
           modifiers == [.command, .option], event.keyCode == 29 {
            model.selectZoom(1); return nil
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return event }
        if event.charactersIgnoringModifiers == "\\", !model.editMode {
            model.libraryFiltersOpen.toggle(); model.persistWorkspace(); return nil
        }
        if stack(event,model:model) { return nil }
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "b", modifiers.isEmpty {
            if !event.isARepeat { model.toggleQuickCollection() }
            return nil
        }
        // Module switching is shared by grid, filmstrip and the single-image canvas.
        if !event.modifierFlags.contains(.shift) {
            if key == "g" { model.selectWorkspace(.grid); return nil }
            if key == "e" { model.selectWorkspace(.single); return nil }
            if key == "d" { model.selectWorkspace(.develop); return nil }
            if key == "c" { model.selectWorkspace(.compare); return nil }
            if key == "n" { model.selectWorkspace(.survey); return nil }
        }
        if let comparison = model.comparison {
            if event.keyCode == 53 { model.endComparison(); return nil }
            if key == "z" { comparison.toggleZoom(in: comparison.candidate); return nil }
            if modifiers.isEmpty, event.keyCode == 126 { model.promoteComparisonCandidate(); return nil }
            if modifiers.isEmpty, event.keyCode == 125 { model.swapComparison(); return nil }
        }
        if model.survey != nil, event.keyCode == 53 { model.selectWorkspace(.grid); return nil }
        if model.survey != nil, key == "/", modifiers.isEmpty, let id = model.activeID { model.removeFromSurvey(id); return nil }
        if model.survey != nil, key == "z", modifiers.isEmpty { model.selectWorkspace(.single); model.selectZoom(1); return nil }
        if !model.singleView && !model.editMode { return event } // NSCollectionView owns grid keyboard selection.
        if model.editMode, key == "r", modifiers.contains(.shift) { model.toggleDevelopReference(); return nil }
        if model.comparison == nil {
            if key == "\\" { model.toggleBefore(); return nil }
            if key == "y" { model.toggleBeforeAfter(event.modifierFlags.contains(.shift) ? .split : .sideBySide); return nil }
            if key == "j" { model.showClipping.toggle(); return nil }
        }
        if model.editMode, event.keyCode == 53, model.whiteBalanceSampling { model.cancelWhiteBalanceSampling(); return nil }
        // Delete belongs to the active local tool, even when nothing is selected.
        if model.editMode, modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            if model.maskMode { if !event.isARepeat { model.deleteMaskComponent() }; return nil }
            if model.spotMode { if !event.isARepeat, let id = model.selectedSpotID { model.deleteSpot(id) }; return nil }
        }
        if model.editMode, event.keyCode == 53, model.developTool != .adjust {
            if model.maskMode && model.maskChoosingTool { model.maskChoosingTool = false }
            else { model.selectDevelopTool(.adjust) }
            return nil
        }
        if model.editMode, event.keyCode == 53, model.developReference != nil { model.endDevelopReference(); return nil }
        if model.editMode, model.cropMode {
            if event.keyCode == 36 || event.keyCode == 76 { model.selectDevelopTool(.adjust); return nil }
            if !modifiers.contains(.shift) {
                if key == "x" { if !event.isARepeat { model.rotateCropAspect() }; return nil }
                if key == "a" { if !event.isARepeat { model.toggleCropAspectLock() }; return nil }
                if key == "o" { if !event.isARepeat { model.cycleCropGuide() }; return nil }
            }
            // A shifted X must never fall through into culling while the crop tool owns X.
            if key == "x" { return nil }
        }
        if model.editMode, model.canEdit {
            if !event.modifierFlags.contains(.shift) {
                if key == "r" { model.selectDevelopTool(model.cropMode ? .adjust : .crop); return nil }
                if key == "w" { model.toggleWhiteBalanceSampling(); return nil }
                if key == "q" { model.selectDevelopTool(model.spotMode ? .adjust : .spot); return nil }
            }
            if key == "w", event.modifierFlags.contains(.shift) { model.selectDevelopTool(model.maskMode ? .adjust : .mask); return nil }
            if key == "k" { model.addMask(.brush); return nil }
            if key == "m" { model.addMask(event.modifierFlags.contains(.shift) ? .radial : .linear); return nil }
            if model.maskMode {
                if key == "h" { if !event.isARepeat { model.showMaskGuides.toggle() }; return nil }
                if key == "o" { model.showMaskOverlay.toggle(); return nil }
                if key == "[" { model.brushRadius = max(0.001, model.brushRadius / 1.2); return nil }
                if key == "]" { model.brushRadius = min(0.5, model.brushRadius * 1.2); return nil }
            }
            if model.spotMode {
                if key == "h" { if !event.isARepeat { model.showSpotGuides.toggle() }; return nil }
                if key == "/" { if !event.isARepeat { model.refreshSpotSource() }; return nil }
                if key == "[" { model.nudgeSpotRadius(1 / 1.2); return nil }
                if key == "]" { model.nudgeSpotRadius(1.2); return nil }
            }
        }
        if key == "z" { model.toggleCanvasZoom(); return nil }
        // Page keys pan one visible viewport at a time when zoomed. Holding
        // Shift changes the axis, which keeps the operation useful on a
        // landscape canvas without introducing another permanent toolbar key.
        if (model.editMode || model.singleView), model.comparison == nil, model.survey == nil,
           (model.fullResolution || model.fillView), event.keyCode == 116 || event.keyCode == 121 {
            let forward = event.keyCode == 121 ? 1.0 : -1.0
            if modifiers.contains(.shift) {
                model.viewport.panVisible(horizontal: forward * 0.82)
            } else {
                model.viewport.panVisible(vertical: -forward * 0.82)
            }
            return nil
        }
        if event.keyCode == 123 { model.move(-1); return nil }
        if event.keyCode == 124 { model.move(1); return nil }
        return cull(event, model: model) ? nil : event
    }
    /// Rating and flag keys shared by the grid and the canvas; with Shift the next photo follows the mark.
    static func cull(_ event: NSEvent, model: AppModel) -> Bool {
        guard model.workspaceAvailable,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let advance = (model.autoAdvance || event.modifierFlags.contains(.capsLock)) != event.modifierFlags.contains(.shift)
        // Shift turns the digit row into symbols, so ratings fall back to the physical key.
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let rating = Int(key) ?? digitKeys[event.keyCode], (0...5).contains(rating) {
            model.organize(rating: rating, advance: advance); return true
        }
        if let digit = Int(key) ?? digitKeys[event.keyCode], (6...9).contains(digit) {
            if !event.isARepeat { model.toggleColorLabel(digit - 5, advance: advance) }
            return true
        }
        if key == "`" || key == "~" || event.keyCode == 50 {
            if !event.isARepeat { model.toggleFlag(advance: advance) }
            return true
        }
        switch key {
        case "p": model.organize(flag: 1, advance: advance)
        case "x": model.organize(flag: -1, advance: advance)
        case "u": model.organize(flag: 0, advance: advance)
        case "[", "{": model.stepRating(-1, advance: advance)
        case "]", "}": model.stepRating(1, advance: advance)
        default: return false
        }
        return true
    }
    static func stack(_ event: NSEvent, model: AppModel) -> Bool {
        guard model.workspaceAvailable, event.charactersIgnoringModifiers?.lowercased() == "s", let id = model.activeID else { return false }
        if event.modifierFlags.contains(.shift) { model.stackAction(.cover(id),title:L10n.text("app.setStackCover", defaultValue: "Set Stack Cover")) }
        else { model.toggleActiveStack() }
        return true
    }
    private static let digitKeys: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
    static func isWorkspaceWindow(_ window: NSWindow) -> Bool {
        window.title == "Phosdeck" || window.title.hasSuffix("— Phosdeck")
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
