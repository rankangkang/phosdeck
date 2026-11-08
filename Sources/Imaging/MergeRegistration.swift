// Harris/MOPS, mutual ratio matching and deterministic RANSAC adapted from LightCraft
// b3b49987d4b2c99f582b80ae91b2ec42ab24d14e (2026-11-08), crates/merge/src/
// features.rs, ransac.rs and align.rs. MIT option; see lightcraft-LICENSE.txt.
// Native coordinates are top-left integer-centred pixels, with explicit size conjugation.
import Foundation
import simd

struct MergeMatrix: Equatable {
    var m: simd_double3x3
    static let identity = Self(m: matrix_identity_double3x3)
    init(m: simd_double3x3) { self.m = m }
    init(_ rows: [Double]) {
        m = simd_double3x3(rows: [SIMD3(rows[0],rows[1],rows[2]),SIMD3(rows[3],rows[4],rows[5]),SIMD3(rows[6],rows[7],rows[8])])
    }
    func point(_ x: Double,_ y: Double) -> SIMD2<Double>? {
        let p = m * SIMD3(x,y,1)
        guard p.z.isFinite, abs(p.z) > 1e-9 else { return nil }
        let q = SIMD2(p.x/p.z,p.y/p.z)
        return q.x.isFinite && q.y.isFinite ? q : nil
    }
    var inverse: Self { Self(m:m.inverse) }
    func followed(by next: Self) -> Self { Self(m:next.m*m) }
    static func scale(_ x: Double,_ y: Double) -> Self { Self([x,0,(x-1)/2,0,y,(y-1)/2,0,0,1]) }
    static func translation(_ x: Double,_ y: Double) -> Self { Self([1,0,x,0,1,y,0,0,1]) }
    func fullResolution(from source: MergeImage, to target: MergeImage, smallSource: MergeImage, smallTarget: MergeImage) -> Self {
        let a = Self.scale(Double(smallSource.width)/Double(source.width),Double(smallSource.height)/Double(source.height))
        let b = Self.scale(Double(target.width)/Double(smallTarget.width),Double(target.height)/Double(smallTarget.height))
        return a.followed(by:self).followed(by:b)
    }
}

enum MergeLinearAlgebra {
    static func solve(_ matrix: [Double],_ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = matrix, b = rhs
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(a[row*n+column]) > abs(a[pivot*n+column]) { pivot = row }
            guard abs(a[pivot*n+column]) > 1e-11 else { return nil }
            if pivot != column {
                for j in 0..<n { a.swapAt(column*n+j,pivot*n+j) }; b.swapAt(column,pivot)
            }
            let d = a[column*n+column]
            for j in column..<n { a[column*n+j] /= d }; b[column] /= d
            for row in 0..<n where row != column {
                let f = a[row*n+column]
                for j in column..<n { a[row*n+j] -= f*a[column*n+j] }; b[row] -= f*b[column]
            }
        }
        return b.allSatisfy(\.isFinite) ? b : nil
    }
}

struct MergeFeature {
    var p: SIMD2<Double>
    var strength: Float
    var descriptor: [Float]
}

enum MergeRegistration {
    struct Match { let a: SIMD2<Double>; let b: SIMD2<Double> }
    struct Fit { let transform: MergeMatrix; let matches: [Match]; let rms: Double }
    static func features(_ input: MergePlane, maximum: Int = 700) throws -> [MergeFeature] {
        var levels = [input]
        while levels.count < 4, min(levels.last!.width,levels.last!.height) >= 96 {
            let last = levels.last!
            levels.append(last.blurred(0.9).resized(max(1,last.width/2),max(1,last.height/2)))
        }
        var all = [MergeFeature]()
        for (level,image) in levels.enumerated() {
            try Task.checkCancellation()
            let w = image.width, h = image.height
            guard w > 46, h > 46 else { continue }
            let smoothed = image.blurred(1)
            var gx = MergePlane(width:w,height:h), gy = gx
            for y in 0..<h { for x in 0..<w {
                gx.values[y*w+x] = (smoothed.at(x+1,y)-smoothed.at(x-1,y))*0.5
                gy.values[y*w+x] = (smoothed.at(x,y+1)-smoothed.at(x,y-1))*0.5
            } }
            let xx = MergePlane(width:w,height:h,values:gx.values.map { $0*$0 }).blurred(1.5)
            let yy = MergePlane(width:w,height:h,values:gy.values.map { $0*$0 }).blurred(1.5)
            let xy = MergePlane(width:w,height:h,values:zip(gx.values,gy.values).map(*)).blurred(1.5)
            let response = (0..<w*h).map { i -> Float in
                let a = xx.values[i], b = yy.values[i], c = xy.values[i]
                return (a*b-c*c)/max(a+b,1e-12)
            }
            // A single sharp highlight must not suppress the low-contrast corners
            // in sky/mountain overlaps. Use the same robust upper percentile as
            // MOPS in LightCraft, rather than the strongest response alone.
            let strengths = stride(from:0,to:response.count,by:7).map { response[$0] }.sorted(by:>)
            let threshold = max(1e-8,strengths[strengths.count/200]*0.01)
            let orientation = image.blurred(4.5), descriptor = image.blurred(2.5)
            for y in 22..<h-22 {
                if y.isMultiple(of:32) { try Task.checkCancellation() }
                for x in 22..<w-22 {
                    let v = response[y*w+x]
                    guard v > threshold else { continue }
                    var isMaximum = true
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let other = response[(y+dy)*w+x+dx]
                        if other > v || (other == v && (dy < 0 || (dy == 0 && dx < 0))) { isMaximum = false }
                    } }
                    guard isMaximum else { continue }
                    func offset(_ a: Float,_ b: Float,_ c: Float) -> Double {
                        let d = a-2*b+c
                        return abs(d) > 1e-12 ? Double(max(-0.5,min(0.5,0.5*(a-c)/d))) : 0
                    }
                    let px = Double(x)+offset(response[y*w+x-1],v,response[y*w+x+1])
                    let py = Double(y)+offset(response[(y-1)*w+x],v,response[(y+1)*w+x])
                    let angle = atan2(orientation.at(x,y+1)-orientation.at(x,y-1),orientation.at(x+1,y)-orientation.at(x-1,y))
                    let cosine = Double(cos(angle)), sine = Double(sin(angle))
                    var d = [Float](); d.reserveCapacity(64)
                    var valid = true
                    for j in 0..<8 { for i in 0..<8 {
                        let u = (Double(i)-3.5)*5, v = (Double(j)-3.5)*5
                        let sx = px+cosine*u-sine*v, sy = py+sine*u+cosine*v
                        if sx < 0 || sy < 0 || sx > Double(w-1) || sy > Double(h-1) { valid = false }
                        d.append(descriptor.sample(sx,sy))
                    } }
                    guard valid else { continue }
                    let mean = d.reduce(0,+)/64, variance = d.reduce(Float(0)) { $0+($1-mean)*($1-mean) }/64
                    guard variance > 1e-10 else { continue }
                    let scale = Double(1 << level)
                    all.append(MergeFeature(p:SIMD2((px+0.5)*scale-0.5,(py+0.5)*scale-0.5),strength:v,descriptor:d.map { ($0-mean)/sqrt(variance) }))
                }
            }
        }
        all.sort { $0.strength > $1.strength }; all = Array(all.prefix(maximum*5))
        var ranked = [(Int,Double)](); ranked.reserveCapacity(all.count)
        for i in all.indices {
            if i.isMultiple(of:128) { try Task.checkCancellation() }
            var radius = Double.infinity
            for j in 0..<i where all[j].strength*0.9 > all[i].strength { radius = min(radius,simd_distance_squared(all[i].p,all[j].p)) }
            ranked.append((i,radius))
        }
        ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return ranked.prefix(maximum).map { all[$0.0] }
    }
    static func matches(_ a: [MergeFeature],_ b: [MergeFeature]) throws -> [Match] {
        guard a.count > 1, b.count > 1 else { return [] }
        func nearest(_ x: [MergeFeature],_ y: [MergeFeature]) throws -> [(Int,Float,Float)] {
            var out = [(Int,Float,Float)]()
            for (i,f) in x.enumerated() {
                if i.isMultiple(of:32) { try Task.checkCancellation() }
                var best = (-1,Float.infinity,Float.infinity)
                for (j,g) in y.enumerated() {
                    var distance: Float = 0
                    for k in 0..<64 { let delta = f.descriptor[k]-g.descriptor[k]; distance += delta*delta }
                    if distance < best.1 { best = (j,distance,best.1) } else if distance < best.2 { best.2 = distance }
                }
                out.append(best)
            }
            return out
        }
        let ab = try nearest(a,b), ba = try nearest(b,a)
        return ab.enumerated().compactMap { i,value in
            value.0 >= 0 && value.1 < 0.64*value.2 && ba[value.0].0 == i ? Match(a:a[i].p,b:b[value.0].p) : nil
        }
    }
    static func fit(_ pairs: [Match], similarity: Bool = false) -> MergeMatrix? {
        guard pairs.count >= (similarity ? 2 : 4) else { return nil }
        let count = Double(pairs.count)
        let ca = pairs.reduce(SIMD2<Double>.zero) { $0+$1.a }/count
        let cb = pairs.reduce(SIMD2<Double>.zero) { $0+$1.b }/count
        if similarity {
            var aa = 0.0, bb = 0.0, variance = 0.0
            for pair in pairs {
                let a = pair.a-ca, b = pair.b-cb
                aa += simd_dot(a,b); bb += a.x*b.y-a.y*b.x; variance += simd_length_squared(a)
            }
            guard variance > 1e-9 else { return nil }
            aa /= variance; bb /= variance
            return MergeMatrix([aa,-bb,cb.x-aa*ca.x+bb*ca.y,bb,aa,cb.y-bb*ca.x-aa*ca.y,0,0,1])
        }
        let sa = sqrt(2)*count/max(1e-9,pairs.reduce(0) { $0+simd_distance($1.a,ca) })
        let sb = sqrt(2)*count/max(1e-9,pairs.reduce(0) { $0+simd_distance($1.b,cb) })
        var matrix = [Double](repeating:0,count:64), rhs = [Double](repeating:0,count:8)
        for pair in pairs {
            let a = (pair.a-ca)*sa, b = (pair.b-cb)*sb
            let rows = [([a.x,a.y,1,0,0,0,-b.x*a.x,-b.x*a.y],b.x),([0,0,0,a.x,a.y,1,-b.y*a.x,-b.y*a.y],b.y)]
            for (row,value) in rows { for i in 0..<8 {
                rhs[i] += row[i]*value
                for j in 0..<8 { matrix[i*8+j] += row[i]*row[j] }
            } }
        }
        guard let h = MergeLinearAlgebra.solve(matrix,rhs) else { return nil }
        let ta = MergeMatrix([sa,0,-sa*ca.x,0,sa,-sa*ca.y,0,0,1])
        let tb = MergeMatrix([1/sb,0,cb.x,0,1/sb,cb.y,0,0,1])
        return ta.followed(by:MergeMatrix(h+[1])).followed(by:tb)
    }
    static func ransac(_ pairs: [Match], similarity: Bool = false) throws -> Fit? {
        let k = similarity ? 2 : 4, minimum = similarity ? 6 : 10
        guard pairs.count >= minimum else { return nil }
        var seed: UInt64 = 0x9e3779b97f4a7c15
        func next(_ n: Int) -> Int { seed ^= seed >> 12; seed ^= seed << 25; seed ^= seed >> 27; return Int((seed &* 0x2545f4914f6cdd1d) % UInt64(n)) }
        var best = [Match](), limit = 1600, iteration = 0
        while iteration < limit {
            if iteration.isMultiple(of:32) { try Task.checkCancellation() }; iteration += 1
            var indices = Set<Int>()
            while indices.count < k { indices.insert(next(pairs.count)) }
            guard let h = fit(indices.sorted().map { pairs[$0] },similarity:similarity) else { continue }
            let good = pairs.filter { pair in h.point(pair.a.x,pair.a.y).map { simd_distance_squared($0,pair.b) < 4 } ?? false }
            if good.count > best.count {
                best = good
                let probability = 1-pow(Double(good.count)/Double(pairs.count),Double(k))
                if probability < 1e-9 { limit = iteration }
                else { limit = min(limit,max(24,Int(ceil(log(0.001)/log(probability))))) }
            }
        }
        guard best.count >= minimum, Double(best.count) >= Double(pairs.count)*0.25 else { return nil }
        var h: MergeMatrix?
        for _ in 0..<3 {
            guard let fitted = fit(best,similarity:similarity) else { break }
            h = fitted
            let next = pairs.filter { pair in fitted.point(pair.a.x,pair.a.y).map { simd_distance_squared($0,pair.b) < 4 } ?? false }
            if next.count < best.count { break }; best = next
        }
        guard let h else { return nil }
        let rms = sqrt(best.reduce(0) { sum,pair in sum + (h.point(pair.a.x,pair.a.y).map { simd_distance_squared($0,pair.b) } ?? 1000) }/Double(best.count))
        return Fit(transform:h,matches:best,rms:rms)
    }
    static func warp(_ image: MergeImage, to size: (Int,Int), transform: MergeMatrix) throws -> MergeImage {
        var out = MergeImage(width:size.0,height:size.1)
        for y in 0..<out.height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<out.width {
                if let p = transform.point(Double(x),Double(y)) { out.pixels[y*out.width+x] = image.sample(p.x,p.y) ?? .zero }
            }
        }
        return out
    }
}
