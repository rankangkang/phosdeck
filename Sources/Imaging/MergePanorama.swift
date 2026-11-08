// Feature graph, focal estimation, projections and centre-weighted multiband fusion
// reference LightCraft b3b49987d4b2c99f582b80ae91b2ec42ab24d14e (2026-11-08),
// crates/merge/src/pano.rs and pano/{camera,project,blend}.rs, MIT option.
// This native implementation keeps projective registrations; it does not port the
// upstream rotation bundle adjustment, boundary warp or generative edge filling.
import Foundation
import simd

extension MergeProjection {
    func forward(_ d: SIMD3<Double>,f: Double) -> SIMD2<Double>? {
        switch self {
        case .perspective:
            guard d.z > 1e-6 else { return nil }; return SIMD2(f*d.x/d.z,f*d.y/d.z)
        case .cylindrical:
            let r = hypot(d.x,d.z)
            guard r > 1e-12 else { return nil }; return SIMD2(f*atan2(d.x,d.z),f*d.y/r)
        case .spherical:
            let r = simd_length(d)
            guard r > 1e-12 else { return nil }; return SIMD2(f*atan2(d.x,d.z),f*asin(max(-1,min(1,d.y/r))))
        }
    }
    func inverse(_ x: Double,_ y: Double,f: Double) -> SIMD3<Double> {
        let t = x/f, p = y/f
        switch self {
        case .perspective: return SIMD3(t,p,1)
        case .cylindrical: return SIMD3(sin(t),p,cos(t))
        case .spherical: return SIMD3(sin(t)*cos(p),sin(p),cos(t)*cos(p))
        }
    }
}

struct MergePanoramaPlan {
    struct Edge {
        let i: Int
        let j: Int
        let fit: MergeRegistration.Fit
    }
    let options: PhotoMergeOptions
    let frames: [MergeFrame]
    let reference: Int
    /// World direction -> source analysis homogeneous pixel coordinates.
    let cameras: [MergeMatrix]
    let gains: [Float]
    let focal: Double
    let origin: SIMD2<Double>
    let width: Int
    let height: Int

    static func prepare(_ frames: [MergeFrame],options: PhotoMergeOptions) throws -> Self {
        guard frames.count >= 2 else { throw alignmentError }
        let features = try frames.map { try MergeRegistration.features($0.image.grey()) }
        var edges = [Edge]()
        let n = frames.count
        // Neighbours first, then bridge disconnected components. Every selected frame must connect.
        var parents = Array(0..<n)
        func root(_ x: Int) -> Int { var r = x; while parents[r] != r { r = parents[r] }; return r }
        for distance in 1..<n {
            for i in 0..<n-distance {
                let j = i+distance
                if distance > 2 && root(i) == root(j) { continue }
                try Task.checkCancellation()
                let matches = try MergeRegistration.matches(features[i],features[j])
                guard let fit = try MergeRegistration.ransac(matches),
                      Double(fit.matches.count) > 8+0.3*Double(matches.count), valid(fit.transform,from:frames[i].image,to:frames[j].image) else { continue }
                edges.append(Edge(i:i,j:j,fit:fit)); parents[root(j)] = root(i)
            }
            if distance >= 2, (0..<n).allSatisfy({ root($0) == root(0) }) { break }
        }
        guard (0..<n).allSatisfy({ root($0) == root(0) }) else { throw alignmentError }
        let reference = (0..<n).max { a,b in
            let aa = edges.filter { $0.i == a || $0.j == a }.reduce(0) { $0+$1.fit.matches.count }
            let bb = edges.filter { $0.i == b || $0.j == b }.reduce(0) { $0+$1.fit.matches.count }
            return aa == bb ? abs(a-n/2) > abs(b-n/2) : aa < bb
        }!
        var homographies = [MergeMatrix?](repeating:nil,count:n)
        homographies[reference] = .identity
        let sorted = edges.sorted { $0.fit.matches.count > $1.fit.matches.count }
        for _ in 0..<n {
            for edge in sorted {
                if let h = homographies[edge.i], homographies[edge.j] == nil {
                    homographies[edge.j] = h.followed(by:edge.fit.transform)
                } else if let h = homographies[edge.j], homographies[edge.i] == nil {
                    homographies[edge.i] = h.followed(by:edge.fit.transform.inverse)
                }
            }
        }
        let ref = frames[reference].image
        var estimates = [Double]()
        for edge in edges {
            let a = frames[edge.i].image, b = frames[edge.j].image
            let centred = MergeMatrix.translation(Double(a.width-1)/2,Double(a.height-1)/2)
                .followed(by:edge.fit.transform).followed(by:.translation(-Double(b.width-1)/2,-Double(b.height-1)/2))
            for f in focalCandidates(centred) where f > Double(max(a.width,a.height))*0.35 && f < Double(max(a.width,a.height))*8 {
                estimates.append(f*Double(max(ref.width,ref.height))/Double(max(a.width,a.height)))
            }
        }
        estimates.sort()
        let diagonal = hypot(Double(ref.width),Double(ref.height))
        let f = frames[reference].focal35mm.map { diagonal*$0/hypot(36,24) }
            ?? (estimates.isEmpty ? Double(max(ref.width,ref.height))*0.9 : estimates[estimates.count/2])
        let k = MergeMatrix([f,0,Double(ref.width-1)/2,0,f,Double(ref.height-1)/2,0,0,1])
        let cameras = homographies.map { k.followed(by:$0!) }
        let scale = Double(frames[reference].fullWidth)/Double(ref.width)
        let focal = f*scale
        var lo = SIMD2<Double>(repeating:.infinity), hi = SIMD2<Double>(repeating:-.infinity)
        for (index,camera) in cameras.enumerated() {
            let inverse = camera.m.inverse, image = frames[index].image
            for step in 0...64 {
                let t = Double(step)/64
                let w = Double(image.width-1), h = Double(image.height-1)
                for point in [SIMD2(t*w,0),SIMD2(t*w,h),SIMD2(0,t*h),SIMD2(w,t*h)] {
                    guard let q = options.projection.forward(inverse*SIMD3(point.x,point.y,1),f:focal),q.x.isFinite,q.y.isFinite else { throw projectionError }
                    lo = simd_min(lo,q); hi = simd_max(hi,q)
                }
            }
        }
        guard hi.x-lo.x < focal*2*Double.pi*0.99, hi.y-lo.y < focal*20 else { throw projectionError }
        let origin = SIMD2(floor(lo.x),floor(lo.y))
        let w = Int(ceil(hi.x)-origin.x)+1, h = Int(ceil(hi.y)-origin.y)+1
        try PhotoGeometry.checkSize(CGSize(width:w,height:h))
        guard UInt64(w)*UInt64(h)*128 <= ProcessInfo.processInfo.physicalMemory/3 else {
            throw LRCError(L10n.text("merge.memoryBudget", defaultValue:"The full-size merge exceeds the memory budget. Choose a smaller source size"))
        }
        let gains = exposureGains(frames,edges:edges,reference:reference)
        return Self(options:options,frames:frames,reference:reference,cameras:cameras,gains:gains,focal:focal,origin:origin,width:w,height:h)
    }
    static var alignmentError: LRCError { LRCError(L10n.text("merge.panoAlignmentFailed", defaultValue:"All panorama photos must share recognizable overlap. Reorder the sequence or remove unrelated photos")) }
    static var projectionError: LRCError { LRCError(L10n.text("merge.projectionFailed", defaultValue:"This projection cannot represent the panorama safely. Try another projection or a shorter sequence")) }
    static func valid(_ h: MergeMatrix,from a: MergeImage,to b: MergeImage) -> Bool {
        guard h.m.determinant.isFinite,abs(h.m.determinant) > 1e-9 else { return false }
        let corners = [SIMD2(0.0,0),SIMD2(Double(a.width-1),0),SIMD2(Double(a.width-1),Double(a.height-1)),SIMD2(0,Double(a.height-1))]
        let mapped = corners.compactMap { h.point($0.x,$0.y) }
        guard mapped.count == 4 else { return false }
        var area = 0.0
        for i in 0..<4 { let p = mapped[i],q = mapped[(i+1)%4]; area += p.x*q.y-p.y*q.x }
        return area > Double(b.width*b.height)*0.1 && area < Double(b.width*b.height)*12
    }
    static func focalCandidates(_ h: MergeMatrix) -> [Double] {
        let m = h.m
        let a=m[0,0], b=m[1,0], c=m[2,0], d=m[0,1], e=m[1,1], f=m[2,1], g=m[0,2], j=m[1,2]
        func pick(_ n: Double,_ den: Double,_ n2: Double,_ den2: Double) -> Double? {
            let first = abs(den) > 1e-12 && n/den > 0 ? sqrt(n/den) : nil
            let second = abs(den2) > 1e-12 && n2/den2 > 0 ? sqrt(n2/den2) : nil
            return first != nil && (second == nil || abs(den) > abs(den2)) ? first : second
        }
        return [pick(-c*f,a*d+b*e,f*f-c*c,a*a+b*b-d*d-e*e),pick(-(a*b+d*e),g*j,b*b+e*e-a*a-d*d,g*g-j*j)].compactMap { $0 }
    }
    static func exposureGains(_ frames: [MergeFrame],edges: [Edge],reference: Int) -> [Float] {
        let n = frames.count
        var a = [Double](repeating:0,count:n*n), b = [Double](repeating:0,count:n)
        for i in 0..<n { a[i*n+i] = 0.05 }; a[reference*n+reference] += 100
        for edge in edges {
            var ratios = [Float]()
            for pair in edge.fit.matches {
                guard let p = frames[edge.i].image.sample(pair.a.x,pair.a.y),let q = frames[edge.j].image.sample(pair.b.x,pair.b.y),p.w > 0.99,q.w > 0.99 else { continue }
                let x = MergeImage.luma(p),y = MergeImage.luma(q)
                if x > 0.005,y > 0.005,frames[edge.i].clip > MergeImage.peak(p)*1.05,frames[edge.j].clip > MergeImage.peak(q)*1.05 { ratios.append(log(x/y)) }
            }
            guard ratios.count >= 6 else { continue }; ratios.sort()
            let value = Double(ratios[ratios.count/2]), i = edge.i,j = edge.j
            // log gain_j - log gain_i = log signal_i - log signal_j.
            a[i*n+i] += 1; a[j*n+j] += 1; a[i*n+j] -= 1; a[j*n+i] -= 1; b[i] -= value; b[j] += value
        }
        return MergeLinearAlgebra.solve(a,b)?.map { Float(exp(max(-2,min(2,$0)))) } ?? .init(repeating:1,count:n)
    }
    func sourcePoint(_ x: Int,_ y: Int,index: Int) -> SIMD2<Double>? {
        let d = options.projection.inverse(Double(x)+origin.x,Double(y)+origin.y,f:focal)
        let p = cameras[index].m*d
        guard p.z > 1e-8 else { return nil }; return SIMD2(p.x/p.z,p.y/p.z)
    }
}

final class MergePanoramaAccumulator {
    let plan: MergePanoramaPlan
    private let pyramid: MergePyramid
    private var coverage: [Float]
    init(_ plan: MergePanoramaPlan) {
        self.plan = plan; pyramid = MergePyramid(width:plan.width,height:plan.height)
        coverage = .init(repeating:0,count:plan.width*plan.height)
    }
    func add(_ image: MergeImage,index: Int) throws {
        let analysis = plan.frames[index].image
        let sx = Double(image.width)/Double(analysis.width),sy = Double(image.height)/Double(analysis.height)
        var warped = MergeImage(width:plan.width,height:plan.height),mask = MergePlane(width:plan.width,height:plan.height)
        for y in 0..<plan.height {
            if y.isMultiple(of:16) { try Task.checkCancellation() }
            for x in 0..<plan.width {
                guard let q = plan.sourcePoint(x,y,index:index),let value = image.sample((q.x+0.5)*sx-0.5,(q.y+0.5)*sy-0.5),value.w > 0 else { continue }
                let p = y*plan.width+x
                let gain = plan.gains[index]
                warped.pixels[p] = SIMD4(value.x*gain,value.y*gain,value.z*gain,value.w)
                let dx = abs((q.x+0.5)/Double(analysis.width)*2-1),dy = abs((q.y+0.5)/Double(analysis.height)*2-1)
                let edge = Float(max(1e-4,(1-dx*dx)*(1-dy*dy)))
                mask.values[p] = edge*edge*edge*edge*value.w
                coverage[p] = max(coverage[p],value.w)
            }
        }
        try pyramid.add(warped,mask:mask)
    }
    func finish() throws -> MergeImage {
        let image = try pyramid.finish(coverage:coverage)
        return plan.options.autoCrop ? try MergeCrop.crop(image) : image
    }
}

enum MergeCrop {
    /// Largest nonempty axis-aligned rectangle, O(width*height), O(width) storage.
    /// Partial source opacity is valid data; cropping must not discard it as a gap.
    static func rectangle(_ image: MergeImage) throws -> CGRect {
        var heights = [Int](repeating:0,count:image.width+1)
        var best = CGRect.zero,area = 0
        for y in 0..<image.height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<image.width { heights[x] = image.pixels[y*image.width+x].w > 1e-6 ? heights[x]+1 : 0 }
            var stack = [Int]()
            for x in 0...image.width {
                while let last = stack.last,heights[last] > heights[x] {
                    let h = heights[stack.removeLast()],start = (stack.last ?? -1)+1,w = x-start
                    if w*h > area { area = w*h; best = CGRect(x:start,y:y-h+1,width:w,height:h) }
                }
                stack.append(x)
            }
        }
        guard area > 0 else { throw LRCError(L10n.text("merge.emptyCoverage", defaultValue:"The merge has no fully covered area")) }; return best
    }
    static func crop(_ image: MergeImage) throws -> MergeImage {
        let rect = try rectangle(image),w = Int(rect.width),h = Int(rect.height),x = Int(rect.minX),y = Int(rect.minY)
        var result = MergeImage(width:w,height:h)
        for row in 0..<h {
            if row.isMultiple(of:64) { try Task.checkCancellation() }
            result.pixels.replaceSubrange(row*w..<(row+1)*w,with:image.pixels[(row+y)*image.width+x..<(row+y)*image.width+x+w])
        }
        return result
    }
}
