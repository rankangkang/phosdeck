import Foundation
import CryptoKit
import simd

/// Image-space coordinates on the uncropped, aligned reference canvas (top left).
/// One stroke replaces from a source, or restores the automatic result. Opacity
/// applies once per stroke, including where the stroke crosses itself.
struct FocusRetouchStroke: Codable, Equatable {
    var source: Int
    var points: [MaskPoint]
    var radius: Double
    var hardness: Double
    var opacity: Double
    var restore = false

    func validate(count: Int) throws {
        guard (0..<count).contains(source), (1...8192).contains(points.count), points.allSatisfy(\.valid),
              radius.isFinite, (0.0001...0.5).contains(radius), hardness.isFinite, (0...1).contains(hardness),
              opacity.isFinite, (0...1).contains(opacity) else { throw FocusMergeProject.invalid }
    }

    func apply(to result: inout MergeImage, from sourceImage: MergeImage) throws {
        guard sourceImage.width == result.width, sourceImage.height == result.height else { throw FocusMergeProject.invalid }
        let w = result.width, h = result.height, r = radius * Double(min(w,h))
        let path = points.map { SIMD2($0.x * Double(w) - 0.5, $0.y * Double(h) - 0.5) }
        guard let first = path.first else { return }
        var lo = first, hi = first
        for p in path { lo = simd_min(lo,p); hi = simd_max(hi,p) }
        let x0 = max(0,Int(floor(lo.x-r))), x1 = min(w-1,Int(ceil(hi.x+r)))
        let y0 = max(0,Int(floor(lo.y-r))), y1 = min(h-1,Int(ceil(hi.y+r)))
        guard x0 <= x1, y0 <= y1 else { return }
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
        for y in y0...y1 {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in x0...x1 {
                let i = y*w+x, s = sourceImage.pixels[i], old = result.pixels[i]
                // Missing/transparent source pixels never erase valid automatic
                // coverage. Partial coverage attenuates the correction.
                guard old.w > 0 else { continue }
                let m = mask[(y-y0)*bw+x-x0] * (restore ? 1 : min(1,max(0,s.w/old.w)))
                guard m > 0 else { continue }
                result.pixels[i] = m == 1 ? SIMD4(s.x,s.y,s.z,old.w) : SIMD4(old.x+(s.x-old.x)*m, old.y+(s.y-old.y)*m, old.z+(s.z-old.z)*m, old.w)
            }
        }
    }
}

/// Frozen focus solve and minimal decoder state, stored in the master trailer,
/// never expanded into catalog metadata or passed through ordinary Develop.
struct FocusMergeProject: Codable, Equatable {
    static let algorithm = "phosdeck-focus-retouch-v1"
    static let maximumBytes = 16 * 1024 * 1024
    var version = algorithm
    var sources: [MergeProvenance.Source]
    var decoders: [Decoder]
    var temperature: Double
    var tint: Double
    var width: Int
    var height: Int
    var analysisWidth: Int
    var analysisHeight: Int
    var reference: Int
    var transforms: [[Double]]
    var gains: [[Float]]
    var depthWidth: Int
    var depthHeight: Int
    var depth: [Float]
    var strokes: [FocusRetouchStroke] = []

    struct Decoder: Codable, Equatable {
        var version: String
        var lensCorrection: Bool?
    }
    struct Reference: Codable, Equatable {
        var bytes: Int
        var sha256: String
        func validate() throws {
            guard (1...FocusMergeProject.maximumBytes).contains(bytes), sha256.count == 64,
                  sha256.allSatisfy(\.isHexDigit) else { throw FocusMergeProject.invalid }
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    func encoded() throws -> (Data,Reference) {
        try validate()
        let data = try JSONEncoder().encode(self)
        let ref = Reference(bytes:data.count,sha256:Self.digest(data))
        try ref.validate()
        return (data,ref)
    }
    static func read(from url: URL, reference: Reference) throws -> Self {
        try reference.validate()
        let handle = try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > UInt64(reference.bytes) else { throw invalid }
        try handle.seek(toOffset:size-UInt64(reference.bytes))
        guard let data = try handle.read(upToCount:reference.bytes), data.count == reference.bytes,
              digest(data) == reference.sha256 else { throw invalid }
        let project = try JSONDecoder().decode(Self.self,from:data)
        try project.validate()
        return project
    }
    func validate() throws {
        let n = sources.count
        guard version == Self.algorithm, (2...128).contains(n), decoders.count == n,
              Set(sources.map(\.photoID)).count == n, sources.allSatisfy({ !$0.photoID.isEmpty && $0.digest.count == 64 && $0.digest.allSatisfy(\.isHexDigit) }),
              temperature.isFinite, (2000...50000).contains(temperature), tint.isFinite, (-150...150).contains(tint),
              width > 0, height > 0, (1...1000).contains(analysisWidth), (1...1000).contains(analysisHeight),
              (0..<n).contains(reference), transforms.count == n, gains.count == n,
              transforms.allSatisfy({ $0.count == 9 && $0.allSatisfy(\.isFinite) && $0.allSatisfy({ abs($0) <= 1e6 }) }),
              gains.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100 }) }),
              (1...1000).contains(depthWidth), (1...1000).contains(depthHeight), depth.count == depthWidth*depthHeight,
              depth.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Float(n-1) }),
              strokes.count <= 2048, strokes.reduce(0,{ $0+$1.points.count }) <= 131072 else { throw Self.invalid }
        try PhotoGeometry.checkSize(CGSize(width:width,height:height))
        for transform in transforms {
            guard transform[6] == 0,transform[7] == 0,transform[8] == 1,
                  abs(MergeMatrix(transform).m.determinant) > 1e-12 else { throw Self.invalid }
        }
        guard decoders.allSatisfy({ !$0.version.isEmpty && $0.version.utf8.count <= 256 }) else { throw Self.invalid }
        try strokes.forEach { try $0.validate(count:n) }
    }
    init(plan: MergeFusionPlan, requests: [ImageRequest], whiteBalance: WhiteBalanceValue) throws {
        guard let depth = plan.depth, plan.options.kind == .focus else { throw Self.invalid }
        sources = requests.map { .init(photoID:$0.photo.id,digest:$0.recipe!.sourceDigest,recipeRevision:$0.photo.recipeRevision) }
        decoders = requests.indices.map { Decoder(version:requests[$0].recipe!.decoderVersion,lensCorrection:plan.frames[$0].resolvedLensCorrection) }
        temperature = whiteBalance.temperature; tint = whiteBalance.tint
        width = plan.width; height = plan.height
        analysisWidth = plan.frames[plan.reference].image.width; analysisHeight = plan.frames[plan.reference].image.height
        reference = plan.reference
        transforms = plan.transforms.map { t in (0..<3).flatMap { row in (0..<3).map { column in t.m[column,row] } } }
        gains = plan.gains.map { [$0.x,$0.y,$0.z] }
        depthWidth = depth.width; depthHeight = depth.height; self.depth = depth.depth
        try validate()
    }
    func plan(frames: [MergeFrame], options: PhotoMergeOptions) throws -> MergeFusionPlan {
        try validate()
        guard options.kind == .focus, frames.count == sources.count,
              frames.allSatisfy({ $0.fullWidth == width && $0.fullHeight == height && $0.image.width == analysisWidth && $0.image.height == analysisHeight }) else { throw Self.invalid }
        return MergeFusionPlan(options:options,frames:frames,reference:reference,order:Array(frames.indices),
            transforms:transforms.map(MergeMatrix.init),gains:gains.map { SIMD3($0[0],$0[1],$0[2]) },
            exposureRatios:.init(repeating:1,count:frames.count),ghosts:[],
            depth:StackDepthMap(width:depthWidth,height:depthHeight,depth:depth,confident:.init(repeating:false,count:depth.count)))
    }
    static var invalid: LRCError { LRCError(L10n.text("merge.retouch.invalid",defaultValue:"The editable focus merge is invalid or uses an unavailable processing version.")) }
}
