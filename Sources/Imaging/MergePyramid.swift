// Binomial/Laplacian blending adapted from LightCraft b3b4998 (2026-11-08),
// crates/merge/src/pano/blend.rs, MIT option. See lightcraft-LICENSE.txt.
// Native straight linear RGB, independently retained coverage, one incoming frame at a time.
import Foundation
import simd

final class MergePyramid {
    private var sums: [MergeImage] = []
    private var weights: [MergePlane] = []
    // Native reconstruction guard: a Laplacian blend is not a convex RGB
    // combination. At a clipped highlight it can reverse a channel relation
    // shared by every overlapping capture and introduce a new colour fringe.
    // Keep only that local consensus, using two bytes per full-size pixel.
    private var sourceCounts: [UInt8]
    private var channelOrders: [UInt8]
    static let consensusBytesPerPixel = 2
    let levels: Int
    init(width: Int,height: Int,levels requested: Int = 5) {
        sourceCounts = .init(repeating:0,count:width*height)
        channelOrders = .init(repeating:0x3f,count:width*height)
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
        for i in image.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            guard image.pixels[i].w > 0,mask.values[i] > 1e-10 else { continue }
            sourceCounts[i] = min(2,sourceCounts[i]+1)
            channelOrders[i] &= Self.channelOrder(image.pixels[i])
        }
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
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            if sourceCounts[i] >= 2 {
                image.pixels[i] = Self.preservingChannelOrder(image.pixels[i],order:channelOrders[i])
            }
            image.pixels[i].w = coverage[i]
            if coverage[i] == 0 { image.pixels[i] = .zero }
        }
        return image
    }

    /// Six directed channel comparisons. Intersecting them across captures
    /// retains partial orders too, without favouring a particular scene hue.
    static func channelOrder(_ p: SIMD4<Float>) -> UInt8 {
        var order: UInt8 = 0
        if p.x >= p.y { order |= 1 }; if p.y >= p.x { order |= 2 }
        if p.x >= p.z { order |= 4 }; if p.z >= p.x { order |= 8 }
        if p.y >= p.z { order |= 16 }; if p.z >= p.y { order |= 32 }
        return order
    }
    /// Weighted least-squares projection onto the shared channel comparisons.
    /// In three channels an active boundary pools either a pair or all three.
    /// Every candidate preserves Rec.709 luminance, including negative values
    /// and extended highlights; there is no clipping or tone mapping.
    static func preservingChannelOrder(_ p: SIMD4<Float>,order: UInt8) -> SIMD4<Float> {
        guard order != 0,channelOrder(p)&order != order else { return p }
        let coefficients = SIMD3<Double>(0.2126,0.7152,0.0722)
        let original = SIMD3<Double>(Double(p.x),Double(p.y),Double(p.z))
        let mean = simd_dot(original,coefficients)/(coefficients.x+coefficients.y+coefficients.z)
        var best = SIMD4<Float>(Float(mean),Float(mean),Float(mean),p.w)
        func distance(_ value: SIMD4<Float>) -> Double {
            let delta = SIMD3<Double>(Double(value.x),Double(value.y),Double(value.z))-original
            return simd_dot(delta*delta,coefficients)
        }
        var error = distance(best)
        for (a,b) in [(0,1),(0,2),(1,2)] {
            var candidate = p
            let pooled = Float((original[a]*coefficients[a]+original[b]*coefficients[b])/(coefficients[a]+coefficients[b]))
            candidate[a] = pooled;candidate[b] = pooled
            guard channelOrder(candidate)&order == order else { continue }
            let cost = distance(candidate)
            if cost < error { best = candidate;error = cost }
        }
        return best
    }
}
