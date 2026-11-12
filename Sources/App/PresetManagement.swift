import Foundation
import GRDB

extension AppModel {
    func requestXMPPresetImport() {
        guard workspaceAvailable, catalog != nil, commitRecipe() else { return }
        endPresetPreview()
        showXMPPresetImport = true
    }
    @discardableResult func importXMPPresets(_ drafts: [XMPPresetDraft], expectedCatalog: CatalogStore) -> Bool {
        guard !busy, !applyingAdjustments, !cacheMaintenance, let catalog, catalog === expectedCatalog else {
            error = L10n.text("app.theCatalogChangedOrATaskIsRunningReopen", defaultValue: "The catalog changed or a task is running. Reopen XMP Import"); return false
        }
        do {
            return try saveImportedPresets(drafts, catalog: catalog).refreshed
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveImportedPresets(_ drafts: [XMPPresetDraft], catalog: CatalogStore,
                             closedUndo: Bool = false) throws -> (rows: [AdjustmentPreset], refreshed: Bool) {
        let imported = try catalog.importXMPPresets(drafts)
        if !imported.isEmpty { registerXMPPresetUndo(rows: imported, present: false, closed: closedUndo) }
        let refreshed = perform { adjustmentPresets = try catalog.presets() }
        status = L10n.text("app.importedXMPPresetsSkippedDuplicates", defaultValue: "Imported \(imported.count) XMP presets; skipped \(drafts.count - imported.count) duplicates")
        reports = drafts.map { draft in
            "\(draft.group) / \(draft.name)：" + (draft.settings.warnings.isEmpty ? L10n.text("app.globalSettingsConvertedRenderedAppearanceIsApproximate", defaultValue: "Global settings converted; rendered appearance is approximate") : draft.settings.warnings.joined(separator: "；"))
        }
        return (imported, refreshed)
    }
    private func registerXMPPresetUndo(rows: [AdjustmentPreset], present: Bool, closed: Bool = false) {
        registerCatalogUndo(L10n.text("app.importXMPPresets", defaultValue: "Import XMP Presets"), closed: closed) {
            $0.restoreXMPPresetBatch(rows: rows, present: present)
        }
    }
    private func restoreXMPPresetBatch(rows: [AdjustmentPreset], present: Bool) {
        guard let catalog else { return }
        endPresetPreview()
        perform {
            try catalog.restoreXMPPresetBatch(rows, present: present)
            registerXMPPresetUndo(rows: rows, present: !present)
            adjustmentPresets = try catalog.presets()
        }
    }
    @discardableResult func updatePreset(id: String, source: EditRecipe, options: RecipePasteOptions) -> Bool {
        // The confirmed update form itself owns catalogUtilityOpen. Match the
        // existing save/apply commit boundary instead of blocking its own sheet.
        guard !busy, !applyingAdjustments, !cacheMaintenance, let catalog else { return false }
        endPresetPreview()
        do {
            let old = try catalog.updatePreset(id: id, recipe: source, options: options)
            registerPresetUndo(id: id, previous: old, title: L10n.text("app.updatePreset", defaultValue: "Update Preset"))
            adjustmentPresets = try catalog.presets()
            status = L10n.text("app.updatedPreset", defaultValue: "Updated preset “\(old.name)”")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setPresetFavorite(_ preset: AdjustmentPreset, favorite: Bool) {
        guard workspaceAvailable, let catalog else { return }
        endPresetPreview()
        perform {
            let old = try catalog.setPresetFavorite(id: preset.id, favorite: favorite)
            if old.favorite != favorite { registerPresetUndo(id: old.id, previous: old, title: favorite ? L10n.text("app.favoritePreset", defaultValue: "Favorite Preset") : L10n.text("app.unfavoritePreset", defaultValue: "Unfavorite Preset")) }
            adjustmentPresets = try catalog.presets()
        }
    }
    func setPresetGroup(_ preset: AdjustmentPreset, group: String) {
        guard workspaceAvailable, let catalog else { return }
        endPresetPreview()
        perform {
            let old = try catalog.setPresetGroup(id: preset.id, groupName: group)
            registerPresetUndo(id: old.id, previous: old, title: L10n.text("app.movePresetGroup", defaultValue: "Move Preset Group"))
            adjustmentPresets = try catalog.presets()
        }
    }
    func renamePreset(id: String, name: String) {
        guard !busy, !applyingAdjustments, !cacheMaintenance, let catalog else { return }
        endPresetPreview()
        perform {
            guard let old = try catalog.presets().first(where: { $0.id == id }) else { throw LRCError(L10n.text("app.thePresetDoesNotExist", defaultValue: "The preset does not exist")) }
            try catalog.renamePreset(id: id, name: name)
            registerPresetUndo(id: id, previous: old, title: L10n.text("app.renamePreset", defaultValue: "Rename Preset"))
            adjustmentPresets = try catalog.presets()
        }
    }
    func deletePreset(_ preset: AdjustmentPreset) {
        guard workspaceAvailable, let catalog else { return }
        endPresetPreview()
        perform {
            if let old = try catalog.deletePreset(preset.id) { registerPresetUndo(id: old.id, previous: old, title: L10n.text("app.deletePreset", defaultValue: "Delete Preset")) }
            adjustmentPresets = try catalog.presets()
        }
    }
    func registerPresetUndo(id: String, previous: AdjustmentPreset?, title: String, closed: Bool = false) {
        registerCatalogUndo(title, closed: closed) { $0.restorePreset(id: id, value: previous, title: title) }
    }
    private func restorePreset(id: String, value: AdjustmentPreset?, title: String) {
        guard let catalog else { return }
        endPresetPreview()
        perform {
            let current = try catalog.preset(id)
            if let value { try catalog.restorePreset(value) } else { try catalog.deletePreset(id) }
            registerPresetUndo(id: id, previous: current, title: title)
            adjustmentPresets = try catalog.presets()
        }
    }
}
