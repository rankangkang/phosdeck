import CoreImage
import Foundation

/// Decoded-image editing, separate from CIRAWFilter and from output sharpening.
/// Log-luminance detail/masking adapts LightCraft local.rs / finish.rs at f34c7a8.
/// See docs/references/lightcraft-LICENSE.txt and the current detail validation.
struct GeneralSharpening: Codable, Equatable {
    var amount = 0.0
    /// Gaussian sigma in original, EXIF-oriented source pixels, before user geometry.
    var radius = 1.0
    var protection = 25.0
    var isActive: Bool { amount > 0 }
    func validate() throws {
        guard amount.isFinite, (0...150).contains(amount), radius.isFinite, (0.5...3).contains(radius),
              protection.isFinite, (0...100).contains(protection) else { throw LRCError(L10n.text("app.invalidSharpeningParameters", defaultValue: "Invalid sharpening parameters")) }
    }
    func mixing(_ b: Self, amount t: Double) -> Self {
        func mix(_ a: Double, _ b: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, a+(b-a)*t)) }
        return Self(amount: mix(amount,b.amount,0...150), radius: mix(radius,b.radius,0.5...3), protection: mix(protection,b.protection,0...100))
    }
}

/// Independent Double reference. No Core Image, Metal, blur filters or readbacks.
/// Buffers are premultiplied linear sRGB, bottom row first; borders replicate.
enum GeneralDetailReference {
    typealias Pixel = SIMD4<Double>
    static func luma(_ c: SIMD3<Double>) -> Double { c.x*0.2126+c.y*0.7152+c.z*0.0722 }
    static func straight(_ p: Pixel) -> SIMD3<Double> { p.w > 0 ? SIMD3(p.x,p.y,p.z)/p.w : .zero }
    static func logLuma(_ c: SIMD3<Double>) -> Double { log2(max(1e-6,luma(c))/0.18) }
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t)
    }
    static func sampling(_ radius: Double, scale: Double) -> (sigma: Double, blend: Double) {
        let s = radius * min(1,max(0,scale.isFinite ? scale : 1))
        return (max(0.5,s), min(1,pow(s/0.5,2)))
    }
    static func gaussian(_ source: [Pixel], width: Int, height: Int, sigma: Double, bounds: Bool = false) -> [Pixel] {
        let r = Int(ceil(3*sigma))
        let weights = (-r...r).map { exp(-Double($0*$0)/(2*sigma*sigma)) }
        let total = weights.reduce(0,+)
        var horizontal = source, result = source
        for y in 0..<height { for x in 0..<width {
            var p = Pixel.zero, low = 1e6, high = -1e6
            for j in -r...r {
                let v = source[y*width+min(width-1,max(0,x+j))]; p += v * (weights[j+r]/total)
                if v.w > 0 { low = min(low,v.y); high = max(high,v.z) }
            }
            if bounds { p.y = low; p.z = high }
            horizontal[y*width+x] = p
        } }
        for y in 0..<height { for x in 0..<width {
            var p = Pixel.zero, low = 1e6, high = -1e6
            for j in -r...r {
                let v = horizontal[min(height-1,max(0,y+j))*width+x]; p += v * (weights[j+r]/total)
                if v.w > 0 { low = min(low,v.y); high = max(high,v.z) }
            }
            if bounds { p.y = low; p.z = high }
            result[y*width+x] = p
        } }
        return result
    }
    static func sharpen(_ source: [Pixel], width: Int, height: Int, settings s: GeneralSharpening, scale: Double = 1) -> [Pixel] {
        guard s.isActive else { return source }
        let p = sampling(s.radius,scale:scale)
        let moments = source.map { v -> Pixel in
            let a = v.w, l = logLuma(straight(v)); return Pixel(l*a,l,l,a)
        }
        let base = gaussian(moments,width:width,height:height,sigma:p.sigma,bounds:true)
        return zip(source,base).map { v, b in
            guard v.w > 0, b.w > 0 else { return .zero }
            let c = straight(v), d = logLuma(c)-b.x/b.w
            let mask = s.protection == 0 ? 1 : smooth(s.protection*0.0025,s.protection*0.0025+0.15,abs(d))
            let edge = (1-smooth(0.5,2,abs(d)))*(1-smooth(1,3,b.z-b.y))
            let raw = s.amount/150*1.3*d*mask*edge*p.blend
            let delta = 0.25*tanh(raw/0.25)
            let rgb = c*exp2(delta)*v.w
            return Pixel(rgb.x,rgb.y,rgb.z,v.w)
        }
    }
}

enum GeneralDetailPipeline {
    private final class Resources {}
    private static let library: Result<Data, Error> = Result {
        guard let url = Bundle(for:Resources.self).url(forResource:"default",withExtension:"metallib") else { throw LRCError(L10n.text("app.theGeneralDetailShaderIsMissing", defaultValue: "The general detail shader is missing")) }
        return try Data(contentsOf:url)
    }
    private static let blurKernel: Result<CIKernel, Error> = Result {
        try CIKernel(functionName:"detailGaussian",fromMetalLibraryData:library.get(),outputPixelFormat:.RGBAf)
    }
    private static let colors: Result<[String:CIColorKernel], Error> = Result {
        try Dictionary(uniqueKeysWithValues:["detailLog", "generalSharpen", "noiseMoments", "noiseCoefficients", "generalLumaDenoise"].map {
            ($0,try CIColorKernel(functionName:$0,fromMetalLibraryData:library.get(),outputPixelFormat:.RGBAf))
        })
    }
    static func color(_ name: String, _ input: CIImage, _ arguments: [Any]) throws -> CIImage {
        guard let result = try colors.get()[name]?.apply(extent:input.extent,arguments:[input]+arguments) else { throw LRCError(L10n.text("app.generalDetailProcessingFailed", defaultValue: "General detail processing failed: \(name)")) }
        return result
    }
    static func gaussian(_ input: CIImage, sigma: Double, bounds: Bool = false) throws -> CIImage {
        var image = input
        let extent = input.extent, r = ceil(3*sigma)
        for axis in [CIVector(x:1,y:0),CIVector(x:0,y:1)] {
            try Task.checkCancellation()
            guard let result = try blurKernel.get().apply(extent:extent,roiCallback:{ _, rect in rect.insetBy(dx:-r,dy:-r).intersection(extent) },
                arguments:[image,CIVector(cgRect:extent),axis,sigma,bounds ? 1 : 0]) else { throw LRCError(L10n.text("app.generalDetailSamplingFailed", defaultValue: "General detail sampling failed")) }
            image = result
        }
        return image
    }
    static func sharpen(_ input: CIImage, _ settings: GeneralSharpening, sourceSize: CGSize) throws -> CIImage {
        guard settings.isActive else { return input }
        try settings.validate(); try Task.checkCancellation()
        // Uses the decoded grid/source ratio, never the window, crop or backing scale.
        let scale = min(input.extent.width/sourceSize.width,input.extent.height/sourceSize.height)
        let p = GeneralDetailReference.sampling(settings.radius,scale:scale)
        let moments = try color("detailLog",input,[])
        let base = try gaussian(moments,sigma:p.sigma,bounds:true)
        return try color("generalSharpen",input,[base,settings.amount/150,settings.protection/100,p.blend])
    }
}

/// Local, deterministic decoded-image noise reduction. No decoder or AI settings.
struct GeneralNoiseReduction: Codable, Equatable {
    var luminance = 0.0
    var color = 0.0
    var isActive: Bool { luminance > 0 || color > 0 }
    func validate() throws {
        guard [luminance,color].allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { throw LRCError(L10n.text("app.invalidNoiseReductionParameters", defaultValue: "Invalid noise reduction parameters")) }
    }
    func mixing(_ b: Self, amount t: Double) -> Self {
        Self(luminance:min(100,max(0,luminance+(b.luminance-luminance)*t)),color:min(100,max(0,color+(b.color-color)*t)))
    }
}

extension GeneralDetailReference {
    /// LightCraft detail=50 mapping with 0.1× variance tolerance: our decoded
    /// SDR base needs a conservative tradeoff to retain fine lines and texture.
    static func noiseParameters(_ n: GeneralNoiseReduction, scale: Double) -> (sigma: Double, epsilon: Double, blend: Double, colorSigma: Double, colorBlend: Double) {
        let k = min(1,max(0,scale.isFinite ? scale : 1)), l = n.luminance/100, c = n.color/100
        let lum = sampling(1+2.5*l,scale:k), chroma = sampling(1+c,scale:k)
        return (lum.sigma,max(1e-7,0.1*(0.002+l*l*0.25*0.65)*k*k),sqrt(l)*lum.blend,chroma.sigma,c*chroma.blend)
    }
    static func denoise(_ source: [Pixel], width: Int, height: Int, settings n: GeneralNoiseReduction, scale: Double = 1) -> [Pixel] {
        guard n.isActive else { return source }
        let p = noiseParameters(n,scale:scale)
        var image = source
        if n.luminance > 0 {
            let packed = source.map { v -> Pixel in let l = logLuma(straight(v)); return Pixel(l*v.w,l*l*v.w,0,v.w) }
            let stats = gaussian(packed,width:width,height:height,sigma:p.sigma)
            let coefficients = zip(stats,source).map { m, v -> Pixel in
                guard m.w > 0 else { return .zero }
                let mean = m.x/m.w, variance = max(0,m.y/m.w-mean*mean), a = variance/(variance+p.epsilon)
                return Pixel(a*v.w,mean*(1-a)*v.w,0,v.w)
            }
            let averaged = gaussian(coefficients,width:width,height:height,sigma:p.sigma)
            image = zip(source,averaged).map { v, b in
                guard v.w > 0, b.w > 0 else { return .zero }
                let c = straight(v), l = logLuma(c), f = (b.x*l+b.y)/b.w
                let gain = exp2(min(2,max(-2,(f-l)*p.blend))), out = c*gain*v.w
                return Pixel(out.x,out.y,out.z,v.w)
            }
        }
        if n.color > 0 {
            let r = Int(ceil(2*p.colorSigma)), range = 0.25+0.25*n.color/100
            let colors = image.map(straight), ys = colors.map(luma), logs = colors.map(logLuma)
            let chroma = zip(colors,ys).map { c,y in (c-SIMD3(repeating:y))/max(0.05,y) }
            image = image.enumerated().map { i,v in
                guard v.w > 0 else { return .zero }
                let x = i%width, y = i/width
                var sum = SIMD3<Double>.zero, mass = 0.0
                for dy in -r...r { for dx in -r...r {
                    let j = min(height-1,max(0,y+dy))*width+min(width-1,max(0,x+dx))
                    guard image[j].w > 0 else { continue }
                    let d = chroma[j]-chroma[i], cd = d.x*d.x+d.y*d.y+d.z*d.z
                    let spatial = Double(dx*dx+dy*dy)/(p.colorSigma*p.colorSigma)
                    let ld = pow((logs[j]-logs[i])/0.5,2)
                    let w = exp(-0.5*(spatial+ld+cd/(range*range)))*image[j].w
                    sum += chroma[j]*w; mass += w
                } }
                guard mass > 0 else { return v }
                var c = colors[i]+(sum/mass-chroma[i])*(p.colorBlend*max(0.05,ys[i]))
                // Remove roundoff in the zero-luminance chroma plane, not gamut clipping.
                c += SIMD3(repeating:ys[i]-luma(c))
                return Pixel(c.x*v.w,c.y*v.w,c.z*v.w,v.w)
            }
        }
        return image
    }
}

extension GeneralDetailPipeline {
    private static let chromaKernel: Result<CIKernel, Error> = Result {
        try CIKernel(functionName:"generalChromaDenoise",fromMetalLibraryData:library.get(),outputPixelFormat:.RGBAf)
    }
    static func denoise(_ input: CIImage, _ settings: GeneralNoiseReduction, sourceSize: CGSize) throws -> CIImage {
        guard settings.isActive else { return input }
        try settings.validate(); try Task.checkCancellation()
        let scale = min(input.extent.width/sourceSize.width,input.extent.height/sourceSize.height)
        let p = GeneralDetailReference.noiseParameters(settings,scale:scale)
        var image = input
        if settings.luminance > 0 {
            let moments = try color("noiseMoments",image,[])
            let stats = try gaussian(moments,sigma:p.sigma)
            let coefficients = try color("noiseCoefficients",image,[stats,p.epsilon])
            let average = try gaussian(coefficients,sigma:p.sigma)
            image = try color("generalLumaDenoise",image,[average,p.blend])
        }
        try Task.checkCancellation()
        if settings.color > 0 {
            let extent = input.extent, r = ceil(2*p.colorSigma)
            guard let result = try chromaKernel.get().apply(extent:extent,roiCallback:{ _, rect in rect.insetBy(dx:-r,dy:-r).intersection(extent) },
                arguments:[image,CIVector(cgRect:extent),p.colorSigma,p.colorBlend,0.25+0.25*settings.color/100]) else { throw LRCError(L10n.text("app.colorNoiseReductionSamplingFailed", defaultValue: "Color noise reduction sampling failed")) }
            image = result
        }
        return image
    }
}
