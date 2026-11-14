import Foundation
import CryptoKit
import simd

/// Image-space coordinates on the uncropped, aligned reference canvas (top left).
/// One stroke replaces from a source, or restores the automatic result. Opacity
/// applies once per stroke, including where the stroke crosses itself.
struct MergeRetouchStroke: Codable, Equatable {
    var source: Int
    var points: [MaskPoint]
    var radius: Double
    var hardness: Double
    var opacity: Double
    var restore = false
    var exclude = false

    func validate(count: Int) throws {
        guard !(restore && exclude), (0..<count).contains(source), (1...8192).contains(points.count), points.allSatisfy(\.valid),
              radius.isFinite, (0.0001...0.5).contains(radius), hardness.isFinite, (0...1).contains(hardness),
              opacity.isFinite, (0...1).contains(opacity) else { throw MergeRetouchProject.invalid }
    }

    func mask(width w: Int,height h: Int) throws -> MergeBrushMask {
        let r = radius * Double(min(w,h))
        let path = points.map { SIMD2($0.x * Double(w) - 0.5, $0.y * Double(h) - 0.5) }
        guard let first = path.first else { throw MergeRetouchProject.invalid }
        var lo = first, hi = first
        for p in path { lo = simd_min(lo,p); hi = simd_max(hi,p) }
        let x0 = max(0,Int(floor(lo.x-r))), x1 = min(w-1,Int(ceil(hi.x+r)))
        let y0 = max(0,Int(floor(lo.y-r))), y1 = min(h-1,Int(ceil(hi.y+r)))
        guard x0 <= x1, y0 <= y1 else { throw MergeRetouchProject.invalid }
        // Only allocate the affected rectangle; segment rasterization avoids
        // scanning every segment for each pixel of a large image.
        let bw = x1-x0+1
        var mask = [Float](repeating:0,count:bw*(y1-y0+1))
        for i in path.indices {
            try Task.checkCancellation()
            let a = i == 0 ? first : path[i-1], b = path[i], ab = b-a, length = simd_length_squared(ab)
            let left = max(x0,Int(floor(min(a.x,b.x)-r))), right = min(x1,Int(ceil(max(a.x,b.x)+r)))
            let top = max(y0,Int(floor(min(a.y,b.y)-r))), bottom = min(y1,Int(ceil(max(a.y,b.y)+r)))
            guard left <= right, top <= bottom else { continue }
            for y in top...bottom {
                if y.isMultiple(of:32) { try Task.checkCancellation() }
                for x in left...right {
                    let p = SIMD2(Double(x),Double(y))
                    let t = length > 0 ? min(1,max(0,simd_dot(p-a,ab)/length)) : 0
                    let d = simd_length(p-(a+t*ab))/r
                    let coverage = d >= 1 ? 0 : d <= hardness ? 1 : (1-d)/max(1e-9,1-hardness)
                    let at = (y-y0)*bw+x-x0
                    mask[at] = max(mask[at],Float(coverage*opacity))
                }
            }
        }
        return MergeBrushMask(x:x0,y:y0,width:bw,height:y1-y0+1,values:mask)
    }
    func apply(to result: inout MergeImage, from sourceImage: MergeImage) throws {
        guard sourceImage.width == result.width, sourceImage.height == result.height else { throw MergeRetouchProject.invalid }
        let mask = try mask(width:result.width,height:result.height)
        for y in mask.y..<mask.y+mask.height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in mask.x..<mask.x+mask.width {
                let i = y*result.width+x, s = sourceImage.pixels[i], old = result.pixels[i]
                guard old.w > 0 else { continue }
                let m = mask.value(x,y) * (restore ? 1 : min(1,max(0,s.w/old.w)))
                guard m > 0 else { continue }
                result.pixels[i] = m == 1 ? SIMD4(s.x,s.y,s.z,old.w) : SIMD4(old.x+(s.x-old.x)*m, old.y+(s.y-old.y)*m, old.z+(s.z-old.z)*m, old.w)
            }
        }
    }
}

struct MergeBrushMask {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    var values: [Float]
    var rect: CGRect { CGRect(x:x,y:y,width:width,height:height) }
    func value(_ px: Int,_ py: Int) -> Float {
        guard px >= x,py >= y,px < x+width,py < y+height else { return 0 }
        return values[(py-y)*width+px-x]
    }
}

struct StarTrailSettings: Codable, Equatable {
    var gap = 0
    var threshold = 0.25
    var strength = 0.5
    func validate() throws {
        guard (0...16).contains(gap),threshold.isFinite,(0.01...1).contains(threshold),
              strength.isFinite,(0...1).contains(strength) else { throw MergeRetouchProject.invalid }
    }
}
struct MergeRetouchSettings: Codable, Equatable {
    var strokes: [MergeRetouchStroke] = []
    var excludedSources: Set<Int> = []
    var trails = StarTrailSettings()
    func validate(count: Int,kind: PhotoMergeKind) throws {
        guard strokes.count <= 2048,strokes.reduce(0,{ $0+$1.points.count }) <= 131072,
              excludedSources.allSatisfy({ (0..<count).contains($0) }),excludedSources.count < count,
              kind == .lighten || (excludedSources.isEmpty && trails == StarTrailSettings()),
              kind.isPanorama || kind == .lighten || !strokes.contains(where: \.exclude) else { throw MergeRetouchProject.invalid }
        try trails.validate()
        try strokes.forEach { try $0.validate(count:count) }
    }
}
