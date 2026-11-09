// Adapted from LightCraft b3b49987d4b2c99f582b80ae91b2ec42ab24d14e
// (2026-11-08), crates/merge/src/pano/camera.rs and linalg.rs, MIT option.
// Native SIMD, analysis-pixel centres, bounded focal lengths and cancellation.
// Optional levelling follows LightCraft 2f4d095 (2026-11-09), pano/camera.rs::straighten.
import Foundation
import simd

/// Homographies fitted to a narrow strip of mountains/clouds can align their
/// inliers yet shear the rest of the photograph. Rotating-camera constraints
/// remove those unsupported projective degrees of freedom.
enum MergeCameraRefinement {
    struct Camera {
        var f: Double
        var r: simd_double3x3
        let center: SIMD2<Double>
        var matrix: simd_double3x3 { MergeMatrix([f,0,center.x,0,f,center.y,0,0,1]).m*r }
        func ray(_ p: SIMD2<Double>) -> SIMD3<Double> { r.transpose*SIMD3((p.x-center.x)/f,(p.y-center.y)/f,1) }
        func project(_ d: SIMD3<Double>) -> SIMD2<Double>? {
            let p = r*d
            guard p.z > 1e-9 else { return nil };return SIMD2(f*p.x/p.z+center.x,f*p.y/p.z+center.y)
        }
        func perturbed(_ axis: Int,_ value: Double) -> Self {
            var c = self
            if axis == 3 { c.f += value }
            else { var w = SIMD3<Double>.zero;w[axis] = value;c.r = rotation(w)*r }
            return c
        }
    }
    struct Observation { let i: Int;let j: Int;let match: MergeRegistration.Match }
    struct Result { let cameras: [MergeMatrix];let focal: Double;let rms: Double }

    static func refine(_ frames: [MergeFrame],homographies: [MergeMatrix],edges: [MergePanoramaPlan.Edge],reference: Int,focal: Double,autoLevel: Bool = false) throws -> Result? {
        // A translated scan/crop is planar rather than a rotating camera. Its
        // exact affine registration must not acquire artificial curvature.
        guard edges.contains(where:{ abs($0.fit.transform.m[0,2])+abs($0.fit.transform.m[1,2]) > 1e-6 }) else { return nil }
        let ref = frames[reference].image
        let physical = frames.compactMap(\.focalLength)
        let knownFocals = frames.map { frame -> Double? in
            guard let mm = frame.focal35mm,mm.isFinite,mm > 0 else { return nil }
            return hypot(Double(frame.image.width),Double(frame.image.height))*mm/hypot(36,24)
        }
        func sameFocal(_ values: [Double]) -> Bool { values.count == frames.count && values.allSatisfy { $0 > 0 && abs($0-values[0])/values[0] < 0.01 } }
        let sameModel = frames[0].cameraModel != nil && frames.allSatisfy { $0.cameraModel == frames[0].cameraModel }
        let sharedFocal = knownFocals.allSatisfy { $0 == nil } && sameModel && sameFocal(physical)
        let k = MergeMatrix([focal,0,Double(ref.width-1)/2,0,focal,Double(ref.height-1)/2,0,0,1]).m
        var current = [Camera]()
        for i in frames.indices {
            let image = frames[i].image,c = SIMD2(Double(image.width-1)/2,Double(image.height-1)/2)
            let fi = knownFocals[i] ?? focal
            let ki = MergeMatrix([fi,0,c.x,0,fi,c.y,0,0,1]).m
            let m = ki.inverse*homographies[i].m*k
            guard m.determinant.isFinite,abs(m.determinant) > 1e-10 else { return nil }
            current.append(Camera(f:fi,r:orthonormalize(m*(1/cbrt(m.determinant))),center:c))
        }
        current[reference].r = matrix_identity_double3x3
        let observations = edges.flatMap { edge in
            stride(from:0,to:edge.fit.matches.count,by:max(1,edge.fit.matches.count/60)).map { Observation(i:edge.i,j:edge.j,match:edge.fit.matches[$0]) }
        }
        guard !observations.isEmpty else { return nil }
        let np = frames.count*4
        func residual(_ a: Camera,_ b: Camera,_ pair: MergeRegistration.Match) -> SIMD4<Double> {
            let p = a.project(b.ray(pair.b)),q = b.project(a.ray(pair.a))
            return SIMD4((p?.x ?? 1000)-pair.a.x,(p?.y ?? 1000)-pair.a.y,(q?.x ?? 1000)-pair.b.x,(q?.y ?? 1000)-pair.b.y)
        }
        func cost(_ cameras: [Camera]) -> (Double,Double) {
            var huber = 0.0,squares = 0.0
            for o in observations {
                let r = residual(cameras[o.i],cameras[o.j],o.match)
                for t in 0..<4 { let a = abs(r[t]);squares += r[t]*r[t];huber += a <= 2 ? 0.5*a*a : 2*(a-1) }
            }
            return (huber,sqrt(squares/Double(observations.count*4)))
        }
        var value = cost(current).0,lambda = 1e-3
        for _ in 0..<60 {
            try Task.checkCancellation()
            var normal = [Double](repeating:0,count:np*np),gradient = [Double](repeating:0,count:np)
            for o in observations {
                let a = current[o.i],b = current[o.j],r = residual(a,b,o.match)
                var columns = [(Int,SIMD4<Double>)]()
                for index in [o.i,o.j] {
                    for axis in 0..<4 where axis == 3 || index != reference {
                        if axis == 3,knownFocals[index] != nil { continue }
                        let camera = current[index],epsilon = axis < 3 ? 1e-6 : camera.f*1e-4
                        let changed = camera.perturbed(axis,epsilon)
                        let rr = index == o.i ? residual(changed,b,o.match) : residual(a,changed,o.match)
                        columns.append((sharedFocal && axis == 3 ? reference*4+3 : index*4+axis,(rr-r)/epsilon))
                    }
                }
                for t in 0..<4 {
                    let w = abs(r[t]) <= 2 ? 1 : 2/abs(r[t])
                    for (p,dp) in columns {
                        gradient[p] += w*dp[t]*r[t]
                        for (q,dq) in columns { normal[p*np+q] += w*dp[t]*dq[t] }
                    }
                }
            }
            for axis in 0..<3 { let p = reference*4+axis;normal[p*np+p] = 1 }
            if sharedFocal { for i in frames.indices where i != reference { let p = i*4+3;normal[p*np+p] = 1 } }
            for i in frames.indices where knownFocals[i] != nil { let p = i*4+3;normal[p*np+p] = 1 }
            var improved = false
            for _ in 0..<10 {
                var damped = normal
                for p in 0..<np { damped[p*np+p] += lambda*max(1e-9,normal[p*np+p])+1e-12 }
                guard let delta = MergeLinearAlgebra.solve(damped,gradient.map(-)) else { lambda *= 10;continue }
                var trial = current
                for i in frames.indices {
                    if i != reference { trial[i].r = orthonormalize(rotation(SIMD3(delta[i*4],delta[i*4+1],delta[i*4+2]))*current[i].r) }
                    let long = Double(max(frames[i].image.width,frames[i].image.height))
                    trial[i].f = knownFocals[i] ?? max(long*0.35,min(long*8,current[i].f+delta[(sharedFocal ? reference : i)*4+3]))
                }
                let next = cost(trial).0
                if next.isFinite,next < value {
                    let relative = (value-next)/max(value,1e-300)
                    current = trial;value = next;lambda = max(1e-9,lambda*0.3);improved = relative > 1e-9;break
                }
                lambda *= 10
            }
            if !improved { break }
        }
        let rms = cost(current).1
        guard rms.isFinite,rms < 5 else { return nil }
        if autoLevel { current = leveled(current) }
        return Result(cameras:current.map { MergeMatrix(m:$0.matrix) },focal:current[reference].f,rms:rms)
    }

    /// Common down is perpendicular to the camera x axes; mean forward fixes the heading.
    static func leveled(_ cameras: [Camera]) -> [Camera] {
        guard !cameras.isEmpty else { return cameras }
        var covariance = simd_double3x3(),sumX = SIMD3<Double>.zero,sumY = sumX,sumZ = sumX
        for camera in cameras {
            let axes = camera.r.transpose,x = axes[0]
            covariance += simd_double3x3(columns:(x*x.x,x*x.y,x*x.z))
            sumX += x;sumY += axes[1];sumZ += axes[2]
        }
        // Jacobi on the symmetric 3×3 covariance; columns retain its eigenvectors.
        var vectors = matrix_identity_double3x3
        for _ in 0..<32 {
            let (p,q) = [(0,1),(0,2),(1,2)].max { abs(covariance[$0.0,$0.1]) < abs(covariance[$1.0,$1.1]) }!
            if abs(covariance[p,q]) < 1e-12 { break }
            let angle = 0.5*atan2(2*covariance[q,p],covariance[q,q]-covariance[p,p])
            var turn = matrix_identity_double3x3
            turn[p,p] = cos(angle);turn[q,q] = cos(angle);turn[q,p] = sin(angle);turn[p,q] = -sin(angle)
            covariance = turn.transpose*covariance*turn;vectors = vectors*turn
        }
        let order = (0..<3).sorted { covariance[$0,$0] < covariance[$1,$1] }
        var down = vectors[order[0]]
        let total = max(1e-12,(0..<3).reduce(0) { $0+covariance[$1,$1] })
        if covariance[order[1],order[1]] < 1e-3*total {
            guard simd_length(sumX) > 1e-9 else { return cameras }
            let x = simd_normalize(sumX)
            down = sumY-x*simd_dot(sumY,x)
        }
        guard simd_length(down) > 1e-9 else { return cameras }
        down = simd_normalize(down)
        if simd_dot(down,sumY) < 0 { down = -down }
        let projected = sumZ-down*simd_dot(sumZ,down)
        guard simd_length(projected) > 1e-9 else { return cameras }
        let forward = simd_normalize(projected),right = simd_normalize(simd_cross(down,forward))
        let world = simd_double3x3(columns:(right,down,forward))
        return cameras.map { camera in var result = camera;result.r = camera.r*world;return result }
    }
    private static func rotation(_ w: SIMD3<Double>) -> simd_double3x3 {
        let angle = simd_length(w)
        return angle > 1e-12 ? simd_double3x3(simd_quatd(angle:angle,axis:w/angle)) : matrix_identity_double3x3
    }
    private static func orthonormalize(_ m: simd_double3x3) -> simd_double3x3 {
        var x = m
        for _ in 0..<20 {
            guard x.determinant.isFinite,abs(x.determinant) > 1e-12 else { return matrix_identity_double3x3 }
            x = (x+x.inverse.transpose)*0.5
        }
        if x.determinant < 0 { x[2] = -x[2] }
        return x
    }
}
