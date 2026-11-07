import Foundation

/// Capture exposure in stops, plus the native decoder baseline and user Exposure.
/// This is metadata matching, not scene analysis or an Adobe rendering algorithm.
struct TotalExposureMatch {
    let reference: Double

    static func captureStops(_ metadata: PhotoMetadata?) throws -> Double {
        guard let metadata, let aperture = metadata.aperture, let time = metadata.exposureTime,
              let iso = metadata.iso, aperture.isFinite, aperture > 0, time.isFinite, time > 0, iso > 0 else {
            throw LRCError(L10n.text("app.matchExposureMissingMetadata", defaultValue: "Matching requires valid aperture, shutter speed, and ISO"))
        }
        // Logs avoid overflow/underflow when otherwise valid metadata is extreme.
        return log2(time) + log2(Double(iso) / 100) - 2 * log2(aperture)
    }

    init(metadata: PhotoMetadata?, recipe: EditRecipe) throws {
        try recipe.validate()
        reference = try Self.captureStops(metadata) + recipe.baselineExposure + recipe.exposure
    }

    func exposure(metadata: PhotoMetadata?, recipe: EditRecipe) throws -> (value: Double, limited: Bool) {
        try recipe.validate()
        let requested = try reference - Self.captureStops(metadata) - recipe.baselineExposure
        let value = min(5, max(-5, requested))
        return (value, value != requested)
    }
}
