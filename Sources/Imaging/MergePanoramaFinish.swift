// Boundary stretch and push/pull fill adapt LightCraft 2f4d0959039da9a624f3a76d53a539a155badff1
// (2026-11-09), crates/merge/src/pano/finish.rs, MIT. See lightcraft-LICENSE.txt.
// Native straight, signed linear RGB and coverage; no logarithm or display quantization.
import Foundation

enum MergePanoramaFinish {
    static func apply(_ image: MergeImage,options: PhotoMergeOptions) throws -> MergeImage {
        var result = try warp(image,amount:options.boundaryWarp/100)
        if options.fillEdges { result = try fill(result) }
        return options.autoCrop ? try MergeCrop.crop(result) : result
    }

    static func warp(_ image: MergeImage,amount: Double) throws -> MergeImage {
        try Task.checkCancellation()
        guard amount.isFinite, (0...1).contains(amount) else { throw MergeMasterCodec.invalid }
        guard amount > 0 else { return image }
        return try stretch(stretch(image,amount:amount,vertical:true),amount:amount,vertical:false)
    }

    private static func stretch(_ image: MergeImage,amount: Double,vertical: Bool) throws -> MergeImage {
        let n = vertical ? image.width : image.height, length = vertical ? image.height : image.width
        guard length > 1 else { return image }
        var low = [Double](repeating:.nan,count:n),high = low
        for i in 0..<n {
            if i.isMultiple(of:32) { try Task.checkCancellation() }
            for k in 0..<length where image.pixels[vertical ? k*image.width+i : i*image.width+k].w > 1e-6 {
                if !low[i].isFinite { low[i] = Double(k) }
                high[i] = Double(k)
            }
        }
        let known = low.indices.filter { low[$0].isFinite }
        guard let first = known.first,let last = known.last else { return image }
        // Interpolate missing rows/columns in linear time, then smooth the envelope.
        for i in 0..<first { low[i] = low[first];high[i] = high[first] }
        for i in last..<n { low[i] = low[last];high[i] = high[last] }
        for (a,b) in zip(known,known.dropFirst()) where b > a+1 {
            for i in a+1..<b {
                let t = Double(i-a)/Double(b-a)
                low[i] = low[a]+(low[b]-low[a])*t;high[i] = high[a]+(high[b]-high[a])*t
            }
        }
        func smooth(_ values: [Double]) -> [Double] {
            var prefix = [Double](repeating:0,count:n+1)
            for i in 0..<n { prefix[i+1] = prefix[i]+values[i] }
            let radius = max(1,n/40)
            return (0..<n).map { i in
                let a = max(0,i-radius),b = min(n,i+radius+1)
                return (prefix[b]-prefix[a])/Double(b-a)
            }
        }
        low = smooth(low);high = smooth(high)
        var result = MergeImage(width:image.width,height:image.height)
        for y in 0..<image.height {
            if y.isMultiple(of:16) { try Task.checkCancellation() }
            for x in 0..<image.width {
                let i = vertical ? x : y,k = Double(vertical ? y : x)
                let source = low[i]+k/Double(length-1)*(high[i]-low[i])
                let coordinate = (1-amount)*k+amount*source
                result.pixels[y*image.width+x] = image.sample(vertical ? Double(x) : coordinate,vertical ? coordinate : Double(y)) ?? .zero
            }
        }
        return result
    }

    /// Diffuse surrounding colours into uncovered pixels. Captured opaque pixels stay exact.
    static func fill(_ image: MergeImage) throws -> MergeImage {
        try Task.checkCancellation()
        guard image.pixels.contains(where:{ $0.w < 1 }) else { return image }
        let hasOpaque = image.pixels.contains { $0.w >= 0.999 }
        guard image.pixels.contains(where:{ $0.w > 1e-6 }) else { throw MergeMasterCodec.invalid }
        var seeds = image
        for i in seeds.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            let p = seeds.pixels[i]
            seeds.pixels[i] = p.w >= (hasOpaque ? 0.999 : 1e-6) ? SIMD4(p.x,p.y,p.z,1) : .zero
        }
        let extended = try MergePyramid.extendColors(seeds)
        var result = image
        for i in result.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            let p = image.pixels[i],q = extended.pixels[i]
            let a = min(1,max(0,p.w))
            result.pixels[i] = SIMD4(p.x*a+q.x*(1-a),p.y*a+q.y*(1-a),p.z*a+q.z*(1-a),1)
        }
        return result
    }
}
