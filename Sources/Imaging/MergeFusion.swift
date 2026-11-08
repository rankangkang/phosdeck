// HDR ordering, adjacent exposure ratios, saturation weighting and deghosting adapt
// LightCraft b3b4998 crates/merge/src/hdr.rs (2026-11-08), MIT option.
// Focus alignment/depth call the separately attributed Redlamp MPL files.
// Frame streaming, alpha coverage and current linear-sRGB integration are native work.
import Foundation
import simd

struct MergeFusionPlan {
    let options: PhotoMergeOptions
    let frames: [MergeFrame]
    let reference: Int
    let order: [Int]
    /// Reference analysis pixels -> source analysis pixels.
    let transforms: [MergeMatrix]
    let gains: [SIMD3<Float>]
    let exposureRatios: [Float]
    let ghosts: [MergePlane]
    let depth: StackDepthMap?
    var width: Int { frames[reference].fullWidth }
    var height: Int { frames[reference].fullHeight }

    static func prepare(_ frames: [MergeFrame],options: PhotoMergeOptions) throws -> Self {
        try options.validate(count:frames.count)
        let size = frames[0].image
        guard frames.allSatisfy({ $0.image.width == size.width && $0.image.height == size.height && $0.fullWidth == frames[0].fullWidth && $0.fullHeight == frames[0].fullHeight }) else {
            throw LRCError(L10n.text("merge.sizeMismatch", defaultValue:"These merge modes require photos with matching oriented dimensions"))
        }
        let n = frames.count
        let medians = try frames.map { try Task.checkCancellation(); return $0.image.medianLuma() }
        let allExif = frames.allSatisfy { $0.exposure?.isFinite == true }
        let brightness = frames.enumerated().map { i,f in allExif ? f.exposure! : log2(Double(medians[i])) }
        let order = (0..<n).sorted { brightness[$0] == brightness[$1] ? frames[$0].sourceIndex < frames[$1].sourceIndex : brightness[$0] < brightness[$1] }
        var reference = options.kind == .hdr ? order[n/2] : 0
        var transforms = [MergeMatrix](repeating:.identity,count:n)
        var gains = [SIMD3<Float>](repeating:SIMD3(repeating:1),count:n)
        if options.kind == .focus {
            let analyses = try frames.map { f in
                try Task.checkCancellation()
                return FrameAnalysis(width:f.image.width,height:f.image.height,rgb:f.image.pixels.map { SIMD3(max(0,$0.x),max(0,$0.y),max(0,$0.z)) },factor:1)
            }
            let alignment: StackAlignment
            if options.align { alignment = StackAligner.align(analyses) }
            else { alignment = StackAlignment(reference:0,transforms:.init(repeating:.identity,count:n),gains:gains,correlations:.init(repeating:1,count:n)) }
            try Task.checkCancellation()
            reference = alignment.reference; gains = alignment.gains
            transforms = alignment.transforms.map { MergeMatrix([Double($0.a),Double(-$0.b),Double($0.tx),Double($0.b),Double($0.a),Double($0.ty),0,0,1]) }
            guard alignment.transforms.allSatisfy({ $0.scale.isFinite && (0.5...2).contains($0.scale) }),
                  !options.align || alignment.correlations.allSatisfy({ $0.isFinite && $0 > 0.1 }) else {
                throw LRCError(L10n.text("merge.alignmentFailed", defaultValue:"The photos could not be aligned reliably"))
            }
        } else if options.align {
            let features = try frames.map { try MergeRegistration.features($0.image.grey()) }
            for index in frames.indices where index != reference {
                try Task.checkCancellation()
                let matches = try MergeRegistration.matches(features[reference],features[index])
                if let fitted = try MergeRegistration.ransac(matches,similarity:true) {
                    transforms[index] = fitted.transform
                } else {
                    let a = frames[reference].image.grey(), b = frames[index].image.grey()
                    let fit = ECCAligner.align(template:LumaImage(width:a.width,height:a.height,pixels:a.values),image:LumaImage(width:b.width,height:b.height,pixels:b.values),iterations:35)
                    guard fit.correlation >= 0.55, fit.transform.scale.isFinite, (0.85...1.18).contains(fit.transform.scale),
                          abs(fit.transform.tx) < Float(size.width)*0.25, abs(fit.transform.ty) < Float(size.height)*0.25 else {
                        throw LRCError(L10n.text("merge.alignmentFailed", defaultValue:"The photos could not be aligned reliably"))
                    }
                    let t = fit.transform
                    transforms[index] = MergeMatrix([Double(t.a),Double(-t.b),Double(t.tx),Double(t.b),Double(t.a),Double(t.ty),0,0,1])
                }
            }
        }
        let aligned = try frames.indices.map { i in try MergeRegistration.warp(frames[i].image,to:(size.width,size.height),transform:transforms[i]) }
        var ratios = [Float](repeating:1,count:n)
        var ghosts = [MergePlane]()
        var depth: StackDepthMap?
        if options.kind == .hdr {
            var logs = [Double](repeating:0,count:n)
            for position in 1..<n {
                let a = order[position-1], b = order[position]
                let ratio = logRatio(aligned[a],aligned[b],clips:(frames[a].clip,frames[b].clip))
                    ?? (allExif ? (brightness[b]-brightness[a])*log(2) : log(Double(medians[b]/medians[a])))
                logs[b] = logs[a]+ratio
            }
            ratios = logs.map { Float(exp(max(-16,min(16,$0-logs[reference])))) }
            if options.deghost > 0 { ghosts = try ghostMaps(aligned,clips:frames.map(\.clip),ratios:ratios,reference:reference,order:order,strength:options.deghost) }
        } else if options.kind == .focus {
            let w = max(2,size.width/2), h = max(2,size.height/2)
            var lumas = [LumaImage](), volume = [[Float]](), validities = [[Float]]()
            for index in frames.indices {
                try Task.checkCancellation()
                let gain = simd_dot(gains[index],SIMD3<Float>(0.2126,0.7152,0.0722))
                let grey = frames[index].image.grey(normalize:false).resized(w,h)
                var luma = LumaImage(width:w,height:h,pixels:grey.values.map { $0*sqrt(max(0,gain)) })
                var sharp = LumaImage(width:w,height:h,pixels:StackDepthSolver.sumModifiedLaplacian(luma,radius:1))
                let peak = MergePlane(width:size.width,height:size.height,values:frames[index].image.pixels.map { $0.w > 0.99 ? MergeImage.peak($0) : frames[index].clip }).resized(w,h)
                var validity = LumaImage(width:w,height:h,pixels:.init(repeating:0,count:w*h))
                for y in 0..<h { for x in 0..<w {
                    var brightest: Float = 0
                    for dy in -1...1 { for dx in -1...1 { brightest = max(brightest,peak.at(x+dx,y+dy)) } }
                    validity.pixels[y*w+x] = 1-smooth(frames[index].clip*0.9,frames[index].clip*0.99,brightest)
                    sharp.pixels[y*w+x] *= validity.pixels[y*w+x]
                } }
                let t = transforms[index]
                let factor = Double(w)/Double(size.width)
                let small = MergeMatrix.scale(1/factor,1/factor).followed(by:t).followed(by:.scale(factor,factor))
                let s = Similarity(a:Float(small.m[0,0]),b:Float(small.m[0,1]),tx:Float(small.m[2,0]),ty:Float(small.m[2,1]))
                sharp = StackAligner.warp(sharp,by:s,outside:0); luma = StackAligner.warp(luma,by:s,outside:0)
                validity = StackAligner.warp(validity,by:s,outside:0)
                lumas.append(luma); volume.append(sharp.pixels); validities.append(validity.pixels)
            }
            let solved = try StackDepthSolver.solve(volume:volume,lumas:lumas)
            var labels = solved.depth
            for p in labels.indices {
                let value = min(Float(n-1),max(0,labels[p]))
                let lo = Int(floor(value)),hi = Int(ceil(value))
                if validities[lo][p] < 0.5 || validities[hi][p] < 0.5,
                   let best = frames.indices.filter({ validities[$0][p] >= 0.5 }).min(by:{ abs(Float($0)-value) < abs(Float($1)-value) }) { labels[p] = Float(best) }
            }
            depth = StackDepthMap(width:w,height:h,depth:labels,confident:solved.confident)
        }
        return Self(options:options,frames:frames,reference:reference,order:order,transforms:transforms,gains:gains,exposureRatios:ratios,ghosts:ghosts,depth:depth)
    }

    static func logRatio(_ a: MergeImage,_ b: MergeImage,clips: (Float,Float)) -> Double? {
        var values = [Float]()
        for i in stride(from:0,to:a.pixels.count,by:max(1,a.pixels.count/100000)) {
            let p = a.pixels[i], q = b.pixels[i]
            if p.w > 0.99, q.w > 0.99, p.y > 0.005*clips.0, q.y > 0.005*clips.1,
               MergeImage.peak(p) < clips.0*0.8, MergeImage.peak(q) < clips.1*0.8 { values.append(log(q.y/p.y)) }
        }
        guard values.count >= 32 else { return nil }; values.sort()
        return Double(values[values.count/2])
    }
    static func smooth(_ a: Float,_ b: Float,_ x: Float) -> Float {
        let t = min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t)
    }
    static func ghostMaps(_ frames: [MergeImage],clips: [Float],ratios: [Float],reference: Int,order: [Int],strength: Int) throws -> [MergePlane] {
        let thresholds: [Float] = [1,1,0.6,0.35], threshold = thresholds[strength]
        let w = frames[0].width,h = frames[0].height
        var prediction = frames[reference].pixels
        for p in prediction.indices {
            if p.isMultiple(of:65536) { try Task.checkCancellation() }
            let ref = prediction[p], peak = MergeImage.peak(ref)
            if peak >= clips[reference]*0.8 || peak <= clips[reference]*0.001 || ref.w < 0.99 {
                let candidates = order.filter { i in
                    let value = frames[i].pixels[p]
                    return value.w > 0.99 && MergeImage.peak(value) < clips[i]*0.8 && MergeImage.peak(value) > clips[i]*0.01
                }
                if let best = candidates.min(by:{ abs($0-reference) < abs($1-reference) }) {
                    let value = frames[best].pixels[p]/ratios[best]
                    prediction[p] = SIMD4(value.x,value.y,value.z,frames[best].pixels[p].w)
                }
            } else { prediction[p] /= ratios[reference] }
        }
        return try frames.indices.map { index in
            try Task.checkCancellation()
            var map = MergePlane(width:w,height:h)
            guard index != reference else { return map }
            for p in map.values.indices where frames[index].pixels[p].w > 0.5 {
                let seen = frames[index].pixels[p], predicted = prediction[p]*ratios[index], floor = clips[index]*0.01
                var difference: Float = 0
                for channel in 0..<3 {
                    difference = max(difference,abs(log((max(0,min(seen[channel],clips[index]))+floor)/(max(0,min(predicted[channel],clips[index]))+floor))))
                }
                map.values[p] = smooth(threshold*0.7,threshold,difference)
            }
            var dilated = map
            let radius = strength+1
            for y in 0..<h {
                if y.isMultiple(of:32) { try Task.checkCancellation() }
                for x in 0..<w {
                var value: Float = 0
                for dy in -radius...radius { for dx in -radius...radius { value = max(value,map.at(x+dx,y+dy)) } }
                dilated.values[y*w+x] = value
            } }
            return dilated.blurred(Float(radius))
        }
    }
}

final class MergeFusionAccumulator {
    let plan: MergeFusionPlan
    let width: Int
    let height: Int
    private var sum: MergeImage
    private var weight: [Float]
    private var coverage: [Float]
    private let pyramid: MergePyramid?
    private var medianFrames: [MergeImage] = []
    init(plan: MergeFusionPlan,width: Int,height: Int) throws {
        self.plan = plan; self.width = width; self.height = height
        try PhotoGeometry.checkSize(CGSize(width:width,height:height))
        let bytesPerPixel = plan.options.kind == .median ? 32+plan.frames.count*16 : plan.options.kind == .focus ? 112 : 64
        guard UInt64(width)*UInt64(height)*UInt64(bytesPerPixel) <= ProcessInfo.processInfo.physicalMemory/3 else {
            throw LRCError(L10n.text("merge.memoryBudget", defaultValue:"The full-size merge exceeds the memory budget. Choose a smaller source size"))
        }
        sum = MergeImage(width:width,height:height); weight = .init(repeating:0,count:width*height); coverage = weight
        pyramid = plan.options.kind == .focus ? MergePyramid(width:width,height:height,levels:4) : nil
    }
    func add(_ frame: MergeImage,index: Int) throws {
        let r = plan.frames[plan.reference].image, s = plan.frames[index].image
        let toSmall = MergeMatrix.scale(Double(r.width)/Double(width),Double(r.height)/Double(height))
        let toFull = MergeMatrix.scale(Double(frame.width)/Double(s.width),Double(frame.height)/Double(s.height))
        let transform = toSmall.followed(by:plan.transforms[index]).followed(by:toFull)
        var image = try MergeRegistration.warp(frame,to:(width,height),transform:transform)
        let kind = plan.options.kind
        let depthPlane = plan.depth.map { MergePlane(width:$0.width,height:$0.height,values:$0.depth) }
        var mask = MergePlane(width:width,height:height)
        let clip = plan.frames[index].clip, ratio = plan.exposureRatios[index]
        for y in 0..<height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<width {
                let p = y*width+x, value = image.pixels[p]
                guard value.w > 0 else { continue }
                coverage[p] = max(coverage[p],value.w)
                if kind == .hdr {
                    var peak = MergeImage.peak(value)
                    for dy in -1...1 { for dx in -1...1 {
                        let xx = min(width-1,max(0,x+dx)), yy = min(height-1,max(0,y+dy))
                        peak = max(peak,MergeImage.peak(image.pixels[yy*width+xx]))
                    } }
                    var w = ratio*(1-MergeFusionPlan.smooth(clip*0.8,clip*0.96,peak))
                    if index == plan.order[0] { w += 1e-6 }; if index == plan.reference { w += 1e-9 }
                    let sx = (Double(x)+0.5)*Double(r.width)/Double(width)-0.5
                    let sy = (Double(y)+0.5)*Double(r.height)/Double(height)-0.5
                    let ref = r.sample(max(0,min(Double(r.width-1),sx)),max(0,min(Double(r.height-1),sy))) ?? .zero
                    let bound = MergeImage.peak(ref)
                    if index != plan.reference, bound >= plan.frames[plan.reference].clip*0.8 { w *= MergeFusionPlan.smooth(0.35,0.6,peak/ratio/max(bound,1e-6)) }
                    if !plan.ghosts.isEmpty, index != plan.reference { w *= 1-plan.ghosts[index].sample(sx,sy) }
                    if index == plan.order[0] { w += 1e-10 }
                    w *= value.w
                    sum.pixels[p] += SIMD4(value.x/ratio,value.y/ratio,value.z/ratio,0)*w; weight[p] += w
                } else if kind == .focus, let plane = depthPlane {
                    let depth = plan.depth!
                    let label = plane.sample((Double(x)+0.5)*Double(depth.width)/Double(width)-0.5,(Double(y)+0.5)*Double(depth.height)/Double(height)-0.5)
                    let distance = Float(index)-label
                    let valid = max(0.001,1-MergeFusionPlan.smooth(clip*0.9,clip*0.99,MergeImage.peak(value)))
                    mask.values[p] = exp(-distance*distance/0.5)*value.w*valid
                    let gain = plan.gains[index]
                    image.pixels[p] = SIMD4(value.x*gain.x,value.y*gain.y,value.z*gain.z,value.w)
                } else {
                    switch kind {
                    case .lighten:
                        for c in 0..<3 { sum.pixels[p][c] = weight[p] == 0 ? value[c] : max(sum.pixels[p][c],value[c]) }
                    case .darken:
                        for c in 0..<3 { sum.pixels[p][c] = weight[p] == 0 ? value[c] : min(sum.pixels[p][c],value[c]) }
                    case .screen:
                        if weight[p] == 0 { sum.pixels[p] = value }
                        else { for c in 0..<3 {
                            // Ordinary screen below white; preserve/add excess above
                            // white so two HDR highlights cannot invert into black.
                            let a = sum.pixels[p][c],b = value[c]
                            sum.pixels[p][c] = a+b-min(a,1)*min(b,1)
                        } }
                    case .median: break
                    default: sum.pixels[p] += SIMD4(value.x,value.y,value.z,0)*value.w
                    }
                    weight[p] += value.w
                }
            }
        }
        if kind == .median { medianFrames.append(image) }
        if let pyramid { try pyramid.add(image,mask:mask) }
    }
    func finish() throws -> MergeImage {
        if let pyramid { return try pyramid.finish(coverage:coverage) }
        for i in sum.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            switch plan.options.kind {
            case .median:
                let values = medianFrames.map { $0.pixels[i] }.filter { $0.w > 0 }
                if !values.isEmpty { for c in 0..<3 { let sorted = values.map { $0[c] }.sorted(); sum.pixels[i][c] = (sorted[(sorted.count-1)/2]+sorted[sorted.count/2])/2 } }
            case .hdr, .average:
                if weight[i] > 0 { sum.pixels[i] /= weight[i] }
            case .additive:
                if coverage[i] > 0 { sum.pixels[i] /= coverage[i] }
            default: break
            }
            sum.pixels[i].w = coverage[i]
            if coverage[i] == 0 { sum.pixels[i] = .zero }
        }
        return sum
    }
}
