import Foundation
import simd

/// Re-fuse only the painted rectangle using frozen source geometry. Outside
/// it the automatic multiband result stays exact. A fully excluded source has
/// no contribution; excluding every covering source produces a visible hole.
final class MergeConstrainedRegion {
    let region: CGRect
    private let settings: MergeRetouchSettings
    private let masks: [MergeBrushMask]
    private let kind: PhotoMergeKind
    private var sum: MergeImage
    private var total: [Float]
    private var coverage: [Float]
    private var influence: [Float]

    init(base: MergeImage,settings: MergeRetouchSettings,masks: [MergeBrushMask],kind: PhotoMergeKind) throws {
        guard !masks.isEmpty,masks.count == settings.strokes.count else { throw MergeRetouchProject.invalid }
        self.settings = settings; self.masks = masks; self.kind = kind
        region = masks.dropFirst().reduce(masks[0].rect) { $0.union($1.rect) }.intersection(CGRect(x:0,y:0,width:base.width,height:base.height)).integral
        let w = Int(region.width),h = Int(region.height)
        guard w > 0,h > 0 else { throw MergeRetouchProject.invalid }
        sum = MergeImage(width:w,height:h)
        total = .init(repeating:0,count:w*h); coverage = total; influence = total
        for (stroke,mask) in zip(settings.strokes,masks) {
            try visit(mask) { p,a in
                influence[p] = stroke.restore ? influence[p]*(1-a) : influence[p]+(1-influence[p])*a
            }
        }
    }
    private func visit(_ mask: MergeBrushMask,body: (Int,Float) -> Void) throws {
        let rect = region.intersection(mask.rect)
        guard !rect.isNull,!rect.isEmpty else { return }
        for y in Int(rect.minY)..<Int(rect.maxY) {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in Int(rect.minX)..<Int(rect.maxX) {
                body((y-Int(region.minY))*sum.width+x-Int(region.minX),mask.value(x,y))
            }
        }
    }
    func add(_ image: MergeImage,weights: MergePlane,index: Int) throws {
        guard image.width == sum.width,image.height == sum.height,weights.width == sum.width,weights.height == sum.height else { throw MergeRetouchProject.invalid }
        let neutral: Float = settings.excludedSources.contains(index) ? 0 : 1
        var allowed = [Float](repeating:neutral,count:sum.pixels.count)
        for (stroke,mask) in zip(settings.strokes,masks) {
            if stroke.exclude && stroke.source != index { continue }
            try visit(mask) { p,a in
                if stroke.restore { allowed[p] = allowed[p]*(1-a)+neutral*a }
                else if stroke.exclude || stroke.source != index { allowed[p] *= 1-a }
                else { allowed[p] = allowed[p]*(1-a)+a }
            }
        }
        for p in sum.pixels.indices {
            if p.isMultiple(of:65536) { try Task.checkCancellation() }
            let value = image.pixels[p],allowed = min(1,max(0,allowed[p]))
            guard value.w > 0,allowed > 0 else { continue }
            coverage[p] = max(coverage[p],value.w*allowed)
            if kind == .lighten {
                let a = total[p],b = allowed*value.w,u = a+b-a*b
                if a == 0 { sum.pixels[p] = value }
                else if u > 0 {
                    for c in 0..<3 {
                        // Coverage-aware maximum: opaque sources retain the
                        // existing per-channel max exactly, while a feathered
                        // exclusion mixes with available alternatives.
                        let old = sum.pixels[p][c]
                        sum.pixels[p][c] = (old*a*(1-b)+value[c]*b*(1-a)+max(old,value[c])*a*b)/u
                    }
                }
                total[p] = u
            } else {
                let weight = weights.values[p]*allowed
                sum.pixels[p] += SIMD4(value.x,value.y,value.z,0)*weight
                total[p] += weight
            }
        }
    }
    func finish(over base: MergeImage) throws -> MergeImage {
        var result = base
        for y in 0..<sum.height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<sum.width {
                let p = y*sum.width+x,m = influence[p]
                guard m > 0 else { continue }
                let at = (y+Int(region.minY))*base.width+x+Int(region.minX),old = base.pixels[at]
                var alternative = sum.pixels[p]
                if kind != .lighten,total[p] > 0 { alternative /= total[p] }
                alternative.w = total[p] > 0 ? coverage[p] : 0
                if alternative.w == 0 { alternative = .zero }
                if m == 1 { result.pixels[at] = alternative; continue }
                let a = old.w*(1-m),b = alternative.w*m,alpha = a+b
                result.pixels[at] = alpha > 1e-8 ? SIMD4((old.x*a+alternative.x*b)/alpha,(old.y*a+alternative.y*b)/alpha,(old.z*a+alternative.z*b)/alpha,alpha) : .zero
            }
        }
        return result
    }
}

enum StarTrailFusion {
    /// Native directional interpolation between nearby bright endpoints. Work
    /// from the captured image only, so filled pixels cannot bridge another gap.
    /// It is optional and bounded to 16 output pixels; no sky/track inference.
    static func fillGaps(_ image: MergeImage,settings: StarTrailSettings) throws -> MergeImage {
        try settings.validate()
        guard settings.gap > 0,settings.strength > 0 else { return image }
        var result = image
        let threshold = Float(settings.threshold),amount = Float(settings.strength)
        let reach = settings.gap+1
        func bright(_ x: Int,_ y: Int) -> Bool {
            guard x >= 0,y >= 0,x < image.width,y < image.height else { return false }
            let p = image.pixels[y*image.width+x]
            return p.w > 0 && MergeImage.luma(p) >= threshold
        }
        for y in 0..<image.height {
            if y.isMultiple(of:8) { try Task.checkCancellation() }
            for x in 0..<image.width {
                let start = image.pixels[y*image.width+x],startLuma = MergeImage.luma(start)
                guard start.w > 0,startLuma >= threshold else { continue }
                // Interior pixels of a bright foreground cannot start a gap.
                if (-1...1).allSatisfy({ dy in (-1...1).allSatisfy { dx in bright(x+dx,y+dy) } }) { continue }
                for dy in 0...reach {
                    for dx in -reach...reach {
                        if dy == 0 && dx <= 0 { continue }
                        let steps = max(abs(dx),dy)
                        guard steps >= 2 else { continue }
                        let xx = x+dx,yy = y+dy
                        guard bright(xx,yy) else { continue }
                        let end = image.pixels[yy*image.width+xx],endLuma = MergeImage.luma(end)
                        guard min(startLuma,endLuma) >= max(startLuma,endLuma)*0.25 else { continue }
                        var path = [Int](); path.reserveCapacity(steps-1)
                        for step in 1..<steps {
                            let t = Double(step)/Double(steps)
                            let px = x+Int((Double(dx)*t).rounded()),py = y+Int((Double(dy)*t).rounded())
                            let p = py*image.width+px,value = image.pixels[p]
                            if value.w <= 0 || MergeImage.luma(value) >= threshold { path.removeAll(); break }
                            path.append(p)
                        }
                        guard path.count == steps-1 else { continue }
                        for (offset,p) in path.enumerated() {
                            let t = Float(offset+1)/Float(steps),original = image.pixels[p],candidate = start*(1-t)+end*t
                            let mixed = original*(1-amount)+candidate*amount
                            if MergeImage.luma(mixed) > MergeImage.luma(result.pixels[p]) {
                                result.pixels[p] = SIMD4(mixed.x,mixed.y,mixed.z,original.w)
                            }
                        }
                    }
                }
            }
        }
        return result
    }
}
