// Binomial/Laplacian blending adapted from LightCraft b3b4998 (2026-11-08),
// crates/merge/src/pano/blend.rs, MIT option. See lightcraft-LICENSE.txt.
// Native straight linear RGB, independently retained coverage, one incoming frame at a time.
import Foundation
import simd

final class MergePyramid {
    private var sums: [MergeImage] = []
    private var weights: [MergePlane] = []
    let levels: Int
    init(width: Int,height: Int,levels requested: Int = 5) {
        var w = width, h = height, level = 0
        repeat {
            sums.append(MergeImage(width:w,height:h)); weights.append(MergePlane(width:w,height:h))
            if level >= requested || min(w,h) <= 8 { break }
            w = (w+1)/2; h = (h+1)/2; level += 1
        } while true
        levels = level
    }
    static func down(_ image: MergeImage) throws -> MergeImage {
        let w = (image.width+1)/2, h = (image.height+1)/2
        let kernel: [Float] = [1/16,4/16,6/16,4/16,1/16]
        var temp = MergeImage(width:w,height:image.height), out = MergeImage(width:w,height:h)
        for y in 0..<image.height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<w {
                var p = SIMD4<Float>.zero
                for k in -2...2 { p += image.pixels[y*image.width+min(image.width-1,max(0,2*x+k))]*kernel[k+2] }
                temp.pixels[y*w+x] = p
            }
        }
        for y in 0..<h { for x in 0..<w {
            var p = SIMD4<Float>.zero
            for k in -2...2 { p += temp.pixels[min(image.height-1,max(0,2*y+k))*w+x]*kernel[k+2] }
            out.pixels[y*w+x] = p
        } }
        return out
    }
    static func up(_ image: MergeImage,width: Int,height: Int) throws -> MergeImage {
        var out = MergeImage(width:width,height:height)
        for y in 0..<height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<width {
                let u = min(Double(image.width-1),Double(x)/2)
                let v = min(Double(image.height-1),Double(y)/2)
                let a = Int(u), b = Int(v), c = min(a+1,image.width-1), d = min(b+1,image.height-1)
                let fx = Float(u-Double(a)), fy = Float(v-Double(b))
                out.pixels[y*width+x] = (image.pixels[b*image.width+a]*(1-fx)+image.pixels[b*image.width+c]*fx)*(1-fy)
                    + (image.pixels[d*image.width+a]*(1-fx)+image.pixels[d*image.width+c]*fx)*fy
            }
        }
        return out
    }
    func add(_ image: MergeImage,mask: MergePlane) throws {
        var g = try Self.extendColors(image), m = mask
        for level in 0...levels {
            try Task.checkCancellation()
            let next = level < levels ? try Self.down(g) : nil
            var lap = g
            if let next {
                let expanded = try Self.up(next,width:g.width,height:g.height)
                for i in lap.pixels.indices { lap.pixels[i] -= expanded.pixels[i] }
            }
            for i in lap.pixels.indices {
                sums[level].pixels[i] += lap.pixels[i]*m.values[i]
                weights[level].values[i] += m.values[i]
            }
            if let next {
                let packed = MergeImage(width:m.width,height:m.height,pixels:m.values.map { SIMD4(repeating:$0) })
                let lower = try Self.down(packed)
                m = MergePlane(width:lower.width,height:lower.height,values:lower.pixels.map(\.x)); g = next
            }
        }
    }
    /// Push/pull colour extension prevents uncovered black from entering the colour pyramid.
    /// Coverage stays separate; synthesized colours are never published as image coverage.
    static func extendColors(_ image: MergeImage) throws -> MergeImage {
        guard image.pixels.contains(where: { $0.w < 0.999 }) else { return image }
        var levels = [image]
        while max(levels.last!.width,levels.last!.height) > 1 {
            var premultiplied = levels.last!
            for i in premultiplied.pixels.indices {
                let p = premultiplied.pixels[i]
                premultiplied.pixels[i] = SIMD4(p.x*p.w,p.y*p.w,p.z*p.w,p.w)
            }
            var down = try Self.down(premultiplied)
            for i in down.pixels.indices where down.pixels[i].w > 1e-8 {
                let p = down.pixels[i]; down.pixels[i] = SIMD4(p.x/p.w,p.y/p.w,p.z/p.w,p.w)
            }
            levels.append(down)
        }
        var filled = levels.removeLast()
        while var level = levels.popLast() {
            let expanded = try Self.up(filled,width:level.width,height:level.height)
            for i in level.pixels.indices where level.pixels[i].w < 1e-8 {
                let p = expanded.pixels[i]; level.pixels[i] = SIMD4(p.x,p.y,p.z,0)
            }
            filled = level
        }
        return filled
    }
    func finish(coverage: [Float]) throws -> MergeImage {
        var result: MergeImage?
        for level in (0...levels).reversed() {
            try Task.checkCancellation()
            var image = sums[level]
            for i in image.pixels.indices {
                image.pixels[i] = weights[level].values[i] > 1e-10 ? image.pixels[i]/weights[level].values[i] : .zero
            }
            if let previous = result {
                let expanded = try Self.up(previous,width:image.width,height:image.height)
                for i in image.pixels.indices { image.pixels[i] += expanded.pixels[i] }
            }
            result = image
            // Release completed levels before allocating finer reconstructions.
            sums[level] = MergeImage(width:1,height:1); weights[level] = MergePlane(width:1,height:1)
        }
        var image = result!
        for i in image.pixels.indices {
            image.pixels[i].w = coverage[i]
            if coverage[i] == 0 { image.pixels[i] = .zero }
        }
        return image
    }
}
