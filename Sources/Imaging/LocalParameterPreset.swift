import Foundation
import GRDB

/// The editable part of a mask.  A local parameter payload deliberately has
/// no photo, decoder, source, component, or mask intensity identity.  It can
/// therefore be copied between photos and between RAW/raster recipes without
/// changing the target's selection geometry or its global develop pipeline.
struct LocalParameterValues: Codable, Equatable {
    var exposure: Double
    var contrast: Double
    var saturation: Double
    var settings: LocalDevelopSettings?

    init(group: LocalAdjustment) {
        exposure = group.exposure
        contrast = group.contrast
        saturation = group.saturation
        settings = group.settings
    }

    func validate() throws {
        guard exposure.isFinite, (-5...5).contains(exposure),
              contrast.isFinite, (0...2).contains(contrast),
              saturation.isFinite, (0...2).contains(saturation) else {
            throw LRCError(L10n.text("app.invalidLocalAdjustmentParameters", defaultValue: "Invalid local adjustment parameters"))
        }
        try settings?.validate()
    }

    /// Copy only the values into an existing mask.  The target id, name,
    /// amount, enabled state, refinement and every component remain intact.
    func applying(to target: LocalAdjustment) throws -> LocalAdjustment {
        try validate()
        var value = target
        value.exposure = exposure
        value.contrast = contrast
        value.saturation = saturation
        value.settings = settings
        try value.validate()
        return value
    }
}

/// A named, directory-scoped set of local mask parameters.
///
/// The payload is JSON in a BLOB so the catalog table remains deliberately
/// narrow.  Decoding and validation happen at the UI boundary; malformed
/// rows are rejected without touching a photo recipe.
struct LocalParameterPreset: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "localParameterPreset"

    var id: String
    var name: String
    var parameters: Data

    init(id: String, name: String, parameters: Data) {
        self.id = id
        self.name = name
        self.parameters = parameters
    }

    init(id: String = UUID().uuidString, name: String, values: LocalParameterValues) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else {
            throw LRCError(L10n.text("app.localPresetNamesMustContain1100Characters", defaultValue: "Local preset names must contain 1–100 characters"))
        }
        try values.validate()
        self.init(id: id, name: trimmed, parameters: try JSONEncoder().encode(values))
    }

    func decodedValues() throws -> LocalParameterValues {
        let values: LocalParameterValues
        do {
            values = try JSONDecoder().decode(LocalParameterValues.self, from: parameters)
        } catch {
            throw LRCError(L10n.text("app.theLocalPresetDataIsDamagedAndCannotBe", defaultValue: "The local preset data is damaged and cannot be applied"))
        }
        do {
            try values.validate()
        } catch {
            throw LRCError(L10n.text("app.theLocalPresetDataIsInvalidAndCannotBe", defaultValue: "The local preset data is invalid and cannot be applied"))
        }
        return values
    }
}
