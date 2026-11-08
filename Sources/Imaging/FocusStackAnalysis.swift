// Adapted from Redlamp 9fa9d915540782ce600ee6e4854dc3f2ccd15250 (2026-11-05).
// Copyright the Redlamp contributors; MPL-2.0. This file remains under MPL-2.0.
// Source paths and native adaptations: docs/references/redlamp-LICENSE.txt.
import Foundation
import simd

/// What alignment needs from one frame: its encoded luminance, and a smaller linear RGB copy
/// for the brightness match.
struct FrameAnalysis {
    /// Each `colour` pixel covers this many analysis pixels a side.
    static let colourScale = 4

    /// Square-root-encoded luminance: closer to perceptual, so dark detail counts.
    private(set) var luma: LumaImage
    /// Linear sRGB at a quarter of the analysis size (area averages).
    let colour: Array<SIMD3<Float>>
    let colourWidth: Int
    let colourHeight: Int
    /// Full-resolution pixels per `luma` pixel.
    private(set) var factor: Float

    init(width: Int, height: Int, rgb: [SIMD3<Float>], factor: Float) {
        self.factor = factor
        let weights = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        luma = LumaImage(width: width, height: height, pixels: rgb.map { simd_dot($0, weights).squareRoot() })
        let scale = Self.colourScale
        colourWidth = max(1, width / scale)
        colourHeight = max(1, height / scale)
        var colour = [SIMD3<Float>](repeating: .zero, count: colourWidth * colourHeight)
        for y in 0 ..< colourHeight * scale where y < height {
            for x in 0 ..< colourWidth * scale where x < width {
                colour[(y / scale) * colourWidth + x / scale] += rgb[y * width + x]
            }
        }
        self.colour = Array<SIMD3<Float>>(colour.lazy.map { $0 / Float(scale * scale) })
    }

    /// Replaces `luma` by its quarter-size copy, all the depth solve needs once the frames are aligned.
    mutating func quarterLuma() {
        let quarter = luma.halved().halved()
        factor = factor * Float(luma.width) / Float(quarter.width)
        luma = quarter
    }
}

/// Where every frame of a stack sits relative to the reference, and how bright it is.
struct StackAlignment: Equatable, Codable {
    /// The reference frame: the narrowest field of view, so every other frame is scaled down into it.
    var reference: Int
    /// Per frame, reference pixel coordinates to that frame's pixel coordinates, at full resolution.
    var transforms: [Similarity]
    /// Per frame, the per-channel gain that matches its brightness to the reference.
    var gains: [SIMD3<Float>]
    /// Per frame, ECC's correlation with the reference after alignment (1 for the reference).
    var correlations: [Float]
}

enum StackAligner {
    /// Below this correlation against the reference, a frame keeps its chained transform: frames
    /// focused far from the reference share too little sharp detail to align to it directly.
    static let minimumDirectCorrelation: Float = 0.5

    /// Aligns frames given in focus order (either direction).
    static func align(_ frames: [FrameAnalysis]) -> StackAlignment {
        precondition(!frames.isEmpty)
        // Chain: each frame to its neighbour, so consecutive frames (similar focus) do the matching.
        // Neighbour steps only seed the direct refinement below, so half resolution will do.
        let steps = FocusStackWork.map(frames.count - 1) { index in
            ECCAligner.align(template: frames[index].luma, image: frames[index + 1].luma, finest: 1).transform
        }
        var chained = [Similarity.identity]
        for step in steps {
            chained.append(step.composed(after: chained.last!))
        }
        // The frame whose content appears largest has the narrowest view (focus breathing).
        let reference = chained.last!.scale > 1 ? frames.count - 1 : 0
        let toReference = chained[reference].inverse
        let initials = chained.map { $0.composed(after: toReference) }

        let refined = FocusStackWork.map(frames.count) { index -> (Similarity, Float) in
            guard index != reference else { return (.identity, 1) }
            let direct = ECCAligner.align(
                template: frames[reference].luma, image: frames[index].luma, initial: initials[index], coarsest: 1,
            )
            let useDirect = direct.correlation >= minimumDirectCorrelation
            return (useDirect ? direct.transform : initials[index], direct.correlation)
        }
        let transforms = refined.map(\.0)
        let correlations = refined.map(\.1)
        let gains = frames.indices.map { gain(frames[$0], to: frames[reference], transform: transforms[$0]) }
        let fullTransforms = transforms.enumerated().map { index, transform in
            fullResolution(transform, factor: frames[index].factor)
        }
        return StackAlignment(
            reference: reference,
            transforms: fullTransforms,
            gains: gains,
            correlations: correlations,
        )
    }

    /// An analysis-resolution transform at full resolution, with pixel centres mapped exactly:
    /// analysis x_a = (x_f + 0.5) / factor - 0.5.
    static func fullResolution(_ transform: Similarity, factor: Float) -> Similarity {
        let toAnalysis = Similarity(a: 1 / factor, b: 0, tx: 0.5 / factor - 0.5, ty: 0.5 / factor - 0.5)
        return toAnalysis.inverse.composed(after: transform.composed(after: toAnalysis))
    }

    /// The inverse of `fullResolution(_:factor:)`: a full-resolution transform at analysis resolution.
    static func analysisResolution(_ transform: Similarity, factor: Float) -> Similarity {
        let toAnalysis = Similarity(a: 1 / factor, b: 0, tx: 0.5 / factor - 0.5, ty: 0.5 / factor - 0.5)
        return toAnalysis.composed(after: transform.composed(after: toAnalysis.inverse))
    }

    /// `image` resampled into the reference's geometry (bilinear): `transform` maps reference
    /// pixels to the image's. Outside the image, `outside` if given, else the nearest edge.
    static func warp(_ image: LumaImage, by transform: Similarity, outside: Float? = nil) -> LumaImage {
        let width = image.width
        let height = image.height
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (u, v) = transform.apply(Float(x), Float(y))
                if let outside, image.sample(u, v) == nil {
                    pixels[y * width + x] = outside
                    continue
                }
                let cu = min(max(u, 0), Float(width - 1))
                let cv = min(max(v, 0), Float(height - 1))
                pixels[y * width + x] = image.sample(cu, cv) ?? 0
            }
        }
        return LumaImage(width: width, height: height, pixels: pixels)
    }

    /// Per-channel gain matching `frame` to `reference` over their overlap, in linear light.
    static func gain(_ frame: FrameAnalysis, to reference: FrameAnalysis, transform: Similarity) -> SIMD3<Float> {
        if Task.isCancelled { return SIMD3(repeating:1) }
        // Colour pixel centres in analysis pixels: (c + 0.5) * scale - 0.5.
        let scale = Float(FrameAnalysis.colourScale)
        var sumReference = SIMD3<Double>.zero
        var sumFrame = SIMD3<Double>.zero
        for y in 0 ..< reference.colourHeight {
            for x in 0 ..< reference.colourWidth {
                let (u, v) = transform.apply((Float(x) + 0.5) * scale - 0.5, (Float(y) + 0.5) * scale - 0.5)
                let fx = Int(((u + 0.5) / scale - 0.5).rounded())
                let fy = Int(((v + 0.5) / scale - 0.5).rounded())
                guard fx >= 0, fy >= 0, fx < frame.colourWidth, fy < frame.colourHeight else { continue }
                let r = reference.colour[y * reference.colourWidth + x]
                let f = frame.colour[fy * frame.colourWidth + fx]
                // Clipped or black areas say nothing about exposure.
                guard r.max() < 0.95, f.max() < 0.95, r.min() > 0.002, f.min() > 0.002 else { continue }
                sumReference += SIMD3<Double>(r)
                sumFrame += SIMD3<Double>(f)
            }
        }
        guard sumFrame.min() > 0 else { return SIMD3(repeating: 1) }
        return SIMD3<Float>(sumReference / sumFrame)
    }
}

/// Bounded serial analysis runs on the composite worker, never on MainActor.
enum FocusStackWork {
    static func map<T>(_ count: Int, _ body: (Int) throws -> T) rethrows -> [T] { try (0..<max(0,count)).map(body) }
}

// Saturation suppression from Redlamp FocusStacker+Merge.swift (same revision
// and MPL-2.0 attribution above), with native float clipping and cancellation.
extension MergeFusionPlan {
    /// Remove focus responses in a small neighbourhood of clipped pixels before
    /// depth solving. The threshold follows Redlamp's balanced-green guard
    /// (0.9 of the frame clip); the native adaptation uses the decoded linear-sRGB
    /// green channel already on the analysis grid.
    static let focusClipLevel: Float = 0.9
    static func ignoreClippedFocus(_ focus: inout LumaImage,clipPlane: MergePlane,clip: Float,radius: Int) throws {
        guard clip.isFinite,clip > 0,radius >= 0 else { return }
        let threshold = clip*focusClipLevel
        let width = min(focus.width,clipPlane.width),height = min(focus.height,clipPlane.height)
        for y in 0..<height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<width where clipPlane.values[y*clipPlane.width+x] >= threshold {
                for dy in max(0,y-radius)...min(focus.height-1,y+radius) {
                    for dx in max(0,x-radius)...min(focus.width-1,x+radius) {
                        focus.pixels[dy*focus.width+dx] = 0
                    }
                }
            }
        }
    }
}
