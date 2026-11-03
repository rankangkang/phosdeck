import Foundation
import CoreImage

/// LightCraft 4f0b110 PointColor / PointK, translated under MIT.
/// Samples live in native linear-sRGB OkLCh, never Rec.2020 RGB.
struct PointColor:Codable,Equatable,Identifiable {
    var id = UUID()
    var lightness = 0.5
    var chroma = 0.1
    var hue = 0.0
    var hueShift = 0.0
    var saturationShift = 0.0
    var luminanceShift = 0.0
    var variance = 0.0
    var range = 50.0
    var hueRange = 50.0
    var saturationRange = 50.0
    var luminanceRange = 50.0
    var isNeutral:Bool { hueShift == 0 && saturationShift == 0 && luminanceShift == 0 && variance == 0 }
    func validate() throws {
        guard lightness.isFinite, (-16...16).contains(lightness), chroma.isFinite, (0...16).contains(chroma), hue.isFinite, (0..<360).contains(hue),
            [hueShift,saturationShift,luminanceShift,variance].allSatisfy({ $0.isFinite && (-100...100).contains($0) }),
            [range,hueRange,saturationRange,luminanceRange].allSatisfy({ $0.isFinite && (0...100).contains($0) }) else { throw LRCError(L10n.text("app.invalidPointColorSampleOrAdjustmentParameters", defaultValue: "Invalid point color sample or adjustment parameters")) }
    }
    static func wrap(_ v:Double) -> Double {
        let turn = 2 * Double.pi
        return v - turn * floor((v + .pi) / turn)
    }
    var widths:SIMD3<Double> {
        let k = max(range / 50,0.05)
        return SIMD3((0.1+0.6*hueRange/100)*k,(0.02+0.12*saturationRange/100)*k,(0.05+0.4*luminanceRange/100)*k)
    }
    /// The ordered input/output coordinates are L, C, h (radians).
    func weight(_ lch:SIMD3<Double>) -> Double {
        guard lch.x.isFinite, lch.y.isFinite, lch.z.isFinite else { return 0 }
        let w = widths
        let wh = chroma < 0.02 ? 1 : (1-DevelopPipeline.smooth(w.x/2,w.x,abs(Self.wrap(lch.z-hue * .pi/180)))) * DevelopPipeline.smooth(0.005,0.025,lch.y)
        return wh * (1-DevelopPipeline.smooth(w.y/2,w.y,abs(lch.y-chroma))) * (1-DevelopPipeline.smooth(w.z/2,w.z,abs(lch.x-lightness)))
    }
    func apply(_ input:SIMD3<Double>) -> SIMD3<Double> {
        guard !isNeutral else { return input }
        let weight = weight(input)
        guard weight > 0 else { return input }
        let v = variance / 100 * 0.8
        let h = input.z + weight * (v * Self.wrap(input.z-hue * .pi/180) + hueShift/100 * 0.5)
        let c = max(0,(input.y+weight*v*(input.y-chroma))*(1+weight*saturationShift/100))
        let l = input.x+weight*(v*(input.x-lightness)+luminanceShift/100 * 0.2)
        return SIMD3(l,c,h)
    }
    func scaled(_ amount:Double) -> Self {
        var result = self
        result.hueShift = min(100,max(-100,hueShift*amount)); result.saturationShift = min(100,max(-100,saturationShift*amount))
        result.luminanceShift = min(100,max(-100,luminanceShift*amount)); result.variance = min(100,max(-100,variance*amount))
        return result
    }
    /// Match stable sample identity AND sampled colour, never array position alone.
    /// Empty ↔ nonempty fades offsets; unrelated nonempty lists switch as a unit
    /// at 50%, following upstream presets.rs array semantics.
    static func mixing(_ from:[Self],_ to:[Self],amount:Double) -> [Self] {
        if amount == 0 { return from }; if amount == 1 { return to }
        if from.isEmpty { return to.map { $0.scaled(amount) } }
        if to.isEmpty { return amount >= 1 ? [] : from.map { $0.scaled(1-amount) } }
        guard from.map(\.id) == to.map(\.id),zip(from,to).allSatisfy({ $0.lightness == $1.lightness && $0.chroma == $1.chroma && $0.hue == $1.hue }) else { return amount < 0.5 ? from : to }
        let keys:[WritableKeyPath<Self,Double>] = [\.hueShift,\.saturationShift,\.luminanceShift,\.variance,\.range,\.hueRange,\.saturationRange,\.luminanceRange]
        return zip(from,to).map { a,b in
            var result = b
            for (index,key) in keys.enumerated() { let low = index < 4 ? -100.0 : 0; result[keyPath:key] = min(100,max(low,a[keyPath:key]+(b[keyPath:key]-a[keyPath:key])*amount)) }
            return result
        }
    }
    var vectors:[CIVector] {
        let w = widths
        return [CIVector(x:lightness,y:chroma,z:hue * .pi/180,w:hueShift/100 * 0.5),
            CIVector(x:saturationShift/100,y:luminanceShift/100 * 0.2,z:variance/100 * 0.8,w:w.x),CIVector(x:w.y,y:w.z,z:0,w:0)]
    }
}

struct PointColorReference:Sendable {
    let width:Int
    let height:Int
    /// Premultiplied floating-point linear sRGB, in displayed geometry.
    let rgba:[Float]
    func sample(at point:CGPoint) -> PointColor? {
        guard MaskPoint(point.x,point.y).valid, width > 0, height > 0, rgba.count == width*height*4 else { return nil }
        let x = PhotoGeometry.pixelIndex(point.x,dimension:width), y = PhotoGeometry.pixelIndex(point.y,dimension:height)
        let center = (y*width+x)*4
        guard rgba[center..<(center+4)].allSatisfy(\.isFinite), rgba[center+3] > 0 else { return nil }
        var rgb = SIMD3<Double>.zero, coverage = 0.0
        for dy in -1...1 { for dx in -1...1 {
            let i = (min(height-1,max(0,y+dy))*width+min(width-1,max(0,x+dx)))*4
            let p = rgba[i..<(i+4)].map(Double.init)
            guard p.allSatisfy(\.isFinite), p[3] > 0 else { continue }
            rgb += SIMD3(p[0],p[1],p[2]); coverage += p[3]
        } }
        guard coverage > 0 else { return nil }
        let lab = PerceptualColor.lab(rgb / coverage), c = hypot(lab.y,lab.z)
        var result = PointColor(lightness:lab.x,chroma:c,hue:c < 1e-6 ? 0 : (atan2(lab.z,lab.y)*180 / .pi+360).truncatingRemainder(dividingBy:360))
        if c < 1e-6 { result.chroma = 0 }
        return (try? result.validate()) == nil ? nil : result
    }
    var image:CIImage {
        CIImage(bitmapData:rgba.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
    }
}

enum PointColorPipeline {
    static func mixerVectors(_ a:DevelopAdjustments) -> [Any] {
        func pair(_ key:KeyPath<HSLBand,Double>) -> [Any] {
            let p = a.mixer.map { $0[keyPath:key] }
            return [CIVector(x:p[0],y:p[1],z:p[2],w:p[3]),CIVector(x:p[4],y:p[5],z:p[6],w:p[7])]
        }
        return pair(\.hue)+pair(\.saturation)+pair(\.luminance)
    }
    static func packed(_ samples:[PointColor]) -> [Any] {
        var result:[Any] = samples.flatMap(\.vectors)
        while result.count < 24 { result.append(CIVector(x:0,y:0,z:0,w:0)) }
        return result
    }
    static func input(_ image:CIImage,adjustments:DevelopAdjustments) throws -> CIImage {
        if adjustments.mixer.allSatisfy({ $0 == HSLBand() }) { return image }
        return try SpatialDevelopPipeline.run("pointColorInput",extent:image.extent,[image]+mixerVectors(adjustments))
    }
    static func apply(_ image:CIImage,adjustments a:DevelopAdjustments,saturation:Double) throws -> CIImage {
        let points = a.pointColors.filter { !$0.isNeutral }
        guard !a.blackAndWhite, !points.isEmpty else { return image }
        try a.validate()
        func grade(_ tone:GradingTone) -> CIVector {
            let c = PerceptualColor.lab(PerceptualColor.linear(DevelopPipeline.rgb(SIMD3(tone.hue,1,0.5))))
            let length = max(1e-6,hypot(c.y,c.z))
            return CIVector(x:c.y/length*tone.saturation*0.0012,y:c.z/length*tone.saturation*0.0012,z:tone.luminance*0.002,w:0)
        }
        return try SpatialDevelopPipeline.run("pointColorMix",extent:image.extent,[image]+mixerVectors(a)+packed(points)+[Double(points.count),saturation,a.vibrance,grade(a.grading.shadows),grade(a.grading.midtones),grade(a.grading.highlights),grade(a.grading.global),a.grading.blending,a.grading.balance])
    }
    static func range(_ reference:PointColorReference,samples:[PointColor],selected:UUID,context:CIContext) throws -> CGImage? {
        guard samples.count <= 8, reference.rgba.count == reference.width*reference.height*4 else { throw LRCError(L10n.text("app.invalidPointColorRangeData", defaultValue: "Invalid point color range data")) }
        for sample in samples { try sample.validate() }
        guard let index = samples.firstIndex(where:{$0.id == selected}) else { return nil }
        let image = try SpatialDevelopPipeline.run("pointColorRange",extent:reference.image.extent,[reference.image]+packed(samples)+[Double(index)])
        guard let result = context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:ImagePipeline.outputSpace) else { throw LRCError(L10n.text("app.pointColorRangeDisplayFailed", defaultValue: "Point color range display failed")) }
        return result
    }
}
