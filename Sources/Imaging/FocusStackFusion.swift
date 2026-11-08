// Adapted from Redlamp 9fa9d915540782ce600ee6e4854dc3f2ccd15250 (2026-11-05).
// Copyright the Redlamp contributors; MPL-2.0. This file remains under MPL-2.0.
// FusionPyramid.swift and Shaders/FocusStack.metal (Auto strategy).
// Native float32 / linear-sRGB adaptation: coverage and clipping validity are
// independent of detail salience; negative values and HDR headroom are retained.
import Foundation
import simd

/// Depth-blended coarse colour and depth-gated sharp coefficients. Averaging
/// Gaussian masks at every level mixes focused and defocused fine detail.
final class FocusStackFusion {
    private let depth: MergePlane
    private let reference: Int
    private let levels: Int
    private let coarseFrom: Int
    private var blends = [MergeImage]()
    private var weights = [MergePlane]()
    private var near = [MergeImage]()
    private var far = [MergeImage]()
    private var grit: Float = 0

    init(width: Int,height: Int,depth: StackDepthMap,reference: Int) {
        self.depth = MergePlane(width:depth.width,height:depth.height,values:depth.depth)
        self.reference = reference
        let requested = max(3,Int(log2(Double(min(width,height))))-5)
        var w = width,h = height
        for level in 0...requested {
            blends.append(MergeImage(width:w,height:h)); weights.append(MergePlane(width:w,height:h))
            if level == requested || min(w,h) <= 2 { break }
            w = (w+1)/2; h = (h+1)/2
        }
        levels = blends.count-1; coarseFrom = max(0,levels-2)
        for image in blends.prefix(coarseFrom) {
            let empty = MergeImage(width:image.width,height:image.height,pixels:.init(repeating:SIMD4(0,0,0,-1),count:image.pixels.count))
            near.append(empty); far.append(empty)
        }
    }

    func add(_ image: MergeImage,validity: MergePlane,index: Int) throws {
        var g = try MergePyramid.extendColors(image),valid = validity
        for level in 0...levels {
            try Task.checkCancellation()
            let next = level < levels ? try MergePyramid.down(g) : nil
            var detail = g
            if let next {
                let up = try MergePyramid.up(next,width:g.width,height:g.height)
                for i in detail.pixels.indices { detail.pixels[i] -= up.pixels[i] }
            }
            let salience = level < coarseFrom ? try Self.salience(detail) : nil
            if level == 0,index == reference { grit = 3*Self.noiseSigma(detail) }
            for y in 0..<g.height {
                if y.isMultiple(of:32) { try Task.checkCancellation() }
                for x in 0..<g.width {
                    let p = y*g.width+x
                    let d = depth.sample((Double(x)+0.5)*Double(depth.width)/Double(g.width)-0.5,
                                         (Double(y)+0.5)*Double(depth.height)/Double(g.height)-0.5)
                    let distance = abs(d-Float(index)),coverage = valid.values[p]
                    let weight = (max(0,1-distance)+1e-6)*coverage
                    blends[level].pixels[p] += detail.pixels[p]*weight; weights[level].values[p] += weight
                    // Clipped edges and extended colours outside this frame do
                    // not compete for sharpness, even if their contrast is high.
                    if let salience,coverage >= 0.5 {
                        let s = salience.values[p],rgb = detail.pixels[p]
                        if distance <= 2 {
                            if s > near[level].pixels[p].w { near[level].pixels[p] = SIMD4(rgb.x,rgb.y,rgb.z,s) }
                        } else if s > far[level].pixels[p].w { far[level].pixels[p] = SIMD4(rgb.x,rgb.y,rgb.z,s) }
                    }
                }
            }
            if let next {
                let packed = MergeImage(width:valid.width,height:valid.height,pixels:valid.values.map { SIMD4(repeating:$0) })
                let small = try MergePyramid.down(packed)
                valid = MergePlane(width:small.width,height:small.height,values:small.pixels.map(\.x));g = next
            }
        }
    }

    func finish(coverage: [Float]) throws -> MergeImage {
        var result: MergeImage?
        for level in (0...levels).reversed() {
            try Task.checkCancellation()
            var image = blends[level]
            for p in image.pixels.indices {
                image.pixels[p] = weights[level].values[p] > 1e-10 ? image.pixels[p]/weights[level].values[p] : .zero
                if level < coarseFrom {
                    let n = near[level].pixels[p],f = far[level].pixels[p]
                    let chosen = n.w < 0 || f.w > sqrt(1.5)*max(0,n.w) ? f : n
                    if chosen.w >= 0,level > 1 || max(n.w,f.w) >= grit { image.pixels[p] = chosen }
                }
            }
            if let previous = result {
                let up = try MergePyramid.up(previous,width:image.width,height:image.height)
                for p in image.pixels.indices { image.pixels[p] += up.pixels[p] }
            }
            result = image
            blends[level] = MergeImage(width:1,height:1);weights[level] = MergePlane(width:1,height:1)
            if level < coarseFrom { near[level] = MergeImage(width:1,height:1);far[level] = MergeImage(width:1,height:1) }
        }
        var image = result!
        for p in image.pixels.indices { image.pixels[p].w = coverage[p];if coverage[p] == 0 { image.pixels[p] = .zero } }
        return image
    }

    private static func salience(_ image: MergeImage) throws -> MergePlane {
        let luma = image.pixels.map(MergeImage.luma),kernel: [Float] = [0.27406862,0.45186276,0.27406862]
        let plane = MergePlane(width:image.width,height:image.height,values:luma)
        var out = MergePlane(width:image.width,height:image.height)
        for y in 0..<image.height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<image.width {
            var value: Float = 0
            for dy in -1...1 { for dx in -1...1 { let v = plane.at(x+dx,y+dy);value += kernel[dx+1]*kernel[dy+1]*v*v } }
            out.values[y*image.width+x] = sqrt(value)
        } }
        return out
    }
    private static func noiseSigma(_ image: MergeImage) -> Float {
        let side = min(512,image.width,image.height),x = (image.width-side)/2,y = (image.height-side)/2
        var values = [Float]();values.reserveCapacity(side*side)
        for row in y..<y+side { for column in x..<x+side { values.append(abs(MergeImage.luma(image.pixels[row*image.width+column]))) } }
        values.sort();return values[values.count/2]/0.6745
    }
}
