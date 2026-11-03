import Foundation

extension AdjustmentPreset {
    /// Decode a catalog preset once at the UI boundary. Applying it below is
    /// the same partial application used by the real Apply action, but remains
    /// a value-only operation for the preview path.
    func previewRecipe(on target: EditRecipe, amount: Double = 1) throws -> EditRecipe {
        let source = try JSONDecoder().decode(EditRecipe.self, from: recipe)
        let options = try JSONDecoder().decode(RecipePasteOptions.self, from: self.options)
        return try target.applyingPreset(source, options: options, amount: amount)
    }
}
