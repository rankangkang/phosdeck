import Foundation

/// Decoded linear-image calibration, not a CFA/bias/flat calibration pipeline.
/// Average matching darks, subtract before resampling/registration, retain signed
/// RGB and light-frame coverage. No exposure scaling or automatic dark guessing.
struct MergeDarkCalibration: Codable, Equatable {
    var sources: [MergeProvenance.Source]
    var decoders: [MergeRetouchProject.Decoder]
    var width: Int
    var height: Int

    func validate(lightIDs: Set<String>) throws {
        guard (1...128).contains(sources.count),decoders.count == sources.count,
              Set(sources.map(\.photoID)).count == sources.count,
              lightIDs.isDisjoint(with:sources.map(\.photoID)),
              sources.allSatisfy({ !$0.photoID.isEmpty && $0.digest.count == 64 && $0.digest.allSatisfy(\.isHexDigit) }),
              decoders.allSatisfy({ !$0.version.isEmpty && $0.version.utf8.count <= 256 && $0.lensCorrection != true }),
              width > 0,height > 0 else { throw Self.invalid }
        try PhotoGeometry.checkSize(CGSize(width:width,height:height))
    }

    static func validate(lights: [Photo],darks: [Photo],kind: PhotoMergeKind) throws {
        guard !darks.isEmpty else { return }
        guard kind.supportsDarkFrames,darks.count <= 128,let first = lights.first else { throw invalid }
        try PhotoMergeEngine.validateSources(lights+darks)
        let reference = first.details
        for photo in lights+darks {
            let details = photo.details
            guard photo.width == first.width,photo.height == first.height,
                  (details?.orientation ?? 1) == (reference?.orientation ?? 1),
                  photo.camera == first.camera,details?.iso == reference?.iso,
                  details?.exposureTime == reference?.exposureTime else { throw invalid }
        }
    }

    static func accumulate(_ image: MergeImage,into mean: inout MergeImage?,count: Int) throws {
        guard count > 0 else { throw invalid }
        if mean == nil { mean = MergeImage(width:image.width,height:image.height) }
        guard mean!.width == image.width,mean!.height == image.height else { throw invalid }
        for i in image.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            let p = image.pixels[i]
            guard p.w == 1 else { throw invalid }
            for c in 0..<3 {
                let old = Double(mean!.pixels[i][c])
                mean!.pixels[i][c] = Float(old+(Double(p[c])-old)/Double(count))
            }
            mean!.pixels[i].w = 1
        }
    }

    static func subtract(_ dark: MergeImage,from image: inout MergeImage) throws {
        guard image.width == dark.width,image.height == dark.height else { throw invalid }
        for i in image.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            let p = image.pixels[i],d = dark.pixels[i]
            let corrected = p.w > 0 ? SIMD4(p.x-d.x,p.y-d.y,p.z-d.z,p.w) : .zero
            guard corrected.x.isFinite,corrected.y.isFinite,corrected.z.isFinite else { throw invalid }
            image.pixels[i] = corrected
        }
    }

    static var invalid: LRCError {
        LRCError(L10n.text("merge.dark.invalid",defaultValue:"Dark frames must be distinct, opaque originals matching the lights' camera, dimensions, orientation, ISO and exposure time. Use 1–128 darks with star trails or noise-reduction stacks."))
    }
}
