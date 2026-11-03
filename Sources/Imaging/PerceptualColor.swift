import CoreImage
import Foundation

/// Oklab conversion matrices: Björn Ottosson (2021 revision), public domain/MIT.
/// Attribution: docs/references/oklab-LICENSE.txt. Slider mapping is our own;
/// this is not a port of darktable UCS or Adobe's HSL implementation.
enum PerceptualColor {
    typealias RGB = SIMD3<Double>
    private static let cubes = NSCache<NSData, NSData>()
    private static func decode(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    private static func encode(_ x: Double) -> Double { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    private static func unit(_ c: RGB) -> RGB { RGB(DevelopPipeline.clamp(c.x), DevelopPipeline.clamp(c.y), DevelopPipeline.clamp(c.z)) }
    static func linear(_ c: RGB) -> RGB {
        RGB(decode(c.x), decode(c.y), decode(c.z))
    }
    static func encoded(_ c: RGB) -> RGB {
        RGB(encode(c.x), encode(c.y), encode(c.z))
    }
    static func lab(_ c: RGB) -> RGB {
        let l = cbrt(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = cbrt(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let s = cbrt(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        return RGB(0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
                   1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
                   0.0259040371*l + 0.7827717662*m - 0.8086757660*s)
    }
    static func rgb(_ c: RGB) -> RGB {
        let lc = c.x + 0.3963377774*c.y + 0.2158037573*c.z
        let mc = c.x - 0.1055613458*c.y - 0.0638541728*c.z
        let sc = c.x - 0.0894841775*c.y - 1.2914855480*c.z
        let l = lc * lc * lc, m = mc * mc * mc, s = sc * sc * sc
        return RGB(4.0767416621*l - 3.3077115913*m + 0.2309699292*s,
                   -1.2684380046*l + 2.6097574011*m - 0.3413193965*s,
                   -0.0041960863*l - 0.7034186147*m + 1.7076147010*s)
    }
    private static func inGamut(_ c: RGB) -> Bool {
        c.x >= -1e-7 && c.y >= -1e-7 && c.z >= -1e-7 && c.x <= 1.0000001 && c.y <= 1.0000001 && c.z <= 1.0000001
    }
    /// LightCraft colorops.rs band_hues/band_weights at 4f0b110 (MIT).
    /// Convert the same sRGB HSV centres directly to our linear-sRGB Oklab;
    /// Rec.2020 RGB coefficients do not belong in this working space.
    /// Attribution: docs/references/lightcraft-LICENSE.txt.
    static let blackWhiteHues: [Double] = [0.0,30,60,120,180,225,270,315].map {
        let c = lab(linear(DevelopPipeline.rgb(RGB($0,1,0.5))))
        return atan2(c.z,c.y)
    }
    static func blackWhiteShift(hue: Double, values: [Double]) -> Double {
        func positive(_ angle: Double) -> Double { (angle.truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi) }
        for i in 0..<8 {
            let next = (i+1)%8, span = positive(blackWhiteHues[next]-blackWhiteHues[i])
            let distance = positive(hue-blackWhiteHues[i])
            if distance <= span {
                let t = 0.5-0.5*cos(distance/span * .pi)
                return values[i]+(values[next]-values[i])*t
            }
        }
        return 0
    }
    /// Reduce chroma at fixed Oklab lightness/hue until sRGB is reachable. This is
    /// strict radial clipping, not the CSS local-MINDE algorithm or darktable's soft knee.
    static func gamutMap(_ value: RGB) -> RGB {
        let value = RGB(DevelopPipeline.clamp(value.x), value.y, value.z)
        let initial = rgb(value)
        if inGamut(initial) { return unit(initial) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            if inGamut(rgb(RGB(value.x, value.y * mid, value.z * mid))) { lo = mid } else { hi = mid }
        }
        return unit(rgb(RGB(value.x, value.y * lo, value.z * lo)))
    }
    static func transform(_ encodedInput: RGB, adjustments a: DevelopAdjustments, saturation: Double = 1) -> RGB {
        var value = lab(linear(encodedInput))
        let originalL = value.x
        let chroma = hypot(value.y, value.z)
        // Keep the familiar eight sRGB color selections, but perform the changes in LCh.
        let shift = DevelopPipeline.mixerShift(hue: DevelopPipeline.hsl(encodedInput).x, bands: a.mixer)
        if chroma > 1e-6 {
            let protection = DevelopPipeline.smooth(0, 0.03, chroma)
            let angle = atan2(value.z, value.y) + shift.x * 0.3 * .pi / 180 * protection
            let vibrance = 1 + a.vibrance / 100 * (1 - DevelopPipeline.smooth(0.03, 0.25, chroma))
            let changedChroma = max(0, chroma * (1 + shift.y / 100) * saturation * vibrance)
            value.y = changedChroma * cos(angle); value.z = changedChroma * sin(angle)
            value.x += shift.z * 0.002 * protection * 4 * originalL * (1 - originalL)
        }
        if !a.blackAndWhite, a.pointColors.contains(where:{ !$0.isNeutral }) {
            value = mixerLab(linear(encodedInput),adjustments:a)
            var lch = RGB(value.x,hypot(value.y,value.z),atan2(value.z,value.y))
            for point in a.pointColors { lch = point.apply(lch) }
            let factor = saturation * (1+a.vibrance/100*(1-DevelopPipeline.smooth(0.03,0.25,chroma)))
            lch.y = max(0,lch.y*factor)
            value = RGB(lch.x,lch.y*cos(lch.z),lch.y*sin(lch.z))
        }
        if a.blackAndWhite, a.blackWhiteMixer.contains(where: { $0 != 0 }) {
            // ColorOps::apply: select AFTER HSL/vibrance/saturation, then clear
            // chroma, then grade. Keep our established HSL and grading models.
            let changedChroma = hypot(value.y,value.z)
            if chroma > 1e-6, changedChroma > 1e-6 {
                let shift = blackWhiteShift(hue: atan2(value.z,value.y), values: a.blackWhiteMixer)
                value.x = max(0,value.x + shift/100 * min(changedChroma/0.2,1) * 0.25)
            }
        }
        if a.blackAndWhite || saturation == 0 { value.y = 0; value.z = 0 }
        // Masks are frozen at the input to grading. Positive balance favors highlights.
        let light = DevelopPipeline.clamp(value.x)
        let position = DevelopPipeline.clamp(light + a.grading.balance * 0.0025)
        let width = 0.08 + a.grading.blending * 0.002
        let shadow = 1 - DevelopPipeline.smooth(0.33 - width, 0.33 + width, position)
        let highlight = DevelopPipeline.smooth(0.67 - width, 0.67 + width, position)
        let middle = max(0, 1 - shadow - highlight)
        let weights = [shadow, middle, highlight, 1]
        let tones = [a.grading.shadows, a.grading.midtones, a.grading.highlights, a.grading.global]
        let envelope = 4 * light * (1 - light)
        for (tone, weight) in zip(tones, weights) where weight > 0 {
            if tone.saturation != 0 {
                // The UI wheel retains its sRGB hue labels; convert the target hue to Oklab.
                let target = lab(linear(DevelopPipeline.rgb(RGB(tone.hue, 1, 0.5))))
                let length = max(1e-6, hypot(target.y, target.z))
                let strength = tone.saturation * 0.0012 * weight * envelope
                value.y += target.y / length * strength
                value.z += target.z / length * strength
            }
            value.x += tone.luminance * 0.002 * weight * envelope
        }
        return encoded(gamutMap(value))
    }
    static func mixerLab(_ input:RGB,adjustments a:DevelopAdjustments) -> RGB {
        var value = lab(input)
        let c = hypot(value.y,value.z), l = value.x
        if c > 1e-6 {
            let shift = DevelopPipeline.mixerShift(hue:DevelopPipeline.hsl(encoded(input)).x,bands:a.mixer)
            let protect = DevelopPipeline.smooth(0,0.03,c), h = atan2(value.z,value.y)+shift.x*0.3 * .pi/180*protect
            let changed = max(0,c*(1+shift.y/100))
            value = RGB(l+shift.z*0.002*protect*4*l*(1-l),changed*cos(h),changed*sin(h))
        }
        return value
    }
    static func apply(_ input: CIImage, adjustments: DevelopAdjustments, saturation: Double, interactive: Bool = false) throws -> CIImage {
        if !adjustments.blackAndWhite, adjustments.pointColors.contains(where:{ !$0.isNeutral }) {
            return try PointColorPipeline.apply(input,adjustments:adjustments,saturation:saturation)
        }
        var a = DevelopAdjustments()
        a.mixer = adjustments.mixer; a.grading = adjustments.grading
        a.vibrance = adjustments.vibrance; a.blackAndWhite = adjustments.blackAndWhite
        if a.blackAndWhite { a.blackWhiteMixer = adjustments.blackWhiteMixer }
        // Keep the existing zero-mixer cube path bit for bit. Active mixing is
        // evaluated per pixel by Metal to avoid hue-band seams from a coarse cube.
        if a.blackAndWhite, a.blackWhiteMixer.contains(where: { $0 != 0 }) {
            try a.validate()
            func vector(_ values: [Double]) -> CIVector { CIVector(x:values[0],y:values[1],z:values[2],w:values[3]) }
            func grade(_ tone: GradingTone) -> CIVector {
                let target = lab(linear(DevelopPipeline.rgb(RGB(tone.hue,1,0.5))))
                let length = max(1e-6,hypot(target.y,target.z)), strength = tone.saturation * 0.0012
                return CIVector(x:target.y/length*strength,y:target.z/length*strength,z:tone.luminance*0.002,w:0)
            }
            return try SpatialDevelopPipeline.run("blackWhiteMix", extent:input.extent,
                [input, vector(Array(a.blackWhiteMixer.prefix(4))), vector(Array(a.blackWhiteMixer.suffix(4))),
                 vector(Array(a.mixer.prefix(4)).map(\.hue)), vector(Array(a.mixer.suffix(4)).map(\.hue)),
                 vector(Array(a.mixer.prefix(4)).map(\.saturation)), vector(Array(a.mixer.suffix(4)).map(\.saturation)),
                 vector(Array(a.mixer.prefix(4)).map(\.luminance)), vector(Array(a.mixer.suffix(4)).map(\.luminance)),
                 vector(Array(blackWhiteHues.prefix(4))), vector(Array(blackWhiteHues.suffix(4))), saturation, a.vibrance,
                 grade(a.grading.shadows), grade(a.grading.midtones), grade(a.grading.highlights), grade(a.grading.global),
                 a.grading.blending, a.grading.balance])
        }
        let tones = [a.grading.shadows, a.grading.midtones, a.grading.highlights, a.grading.global]
        let active = saturation != 1 || a.vibrance != 0 || a.blackAndWhite
            || a.mixer.contains { $0 != HSLBand() }
            || tones.contains { $0.saturation != 0 || $0.luminance != 0 }
        guard active else { return input }
        // A fresh 65³ CPU color cube for every pointer event dominates latency.
        // The screen draft uses 17³; committed previews and exports retain 65³.
        let dimension = interactive ? 17 : 65
        struct Key: Encodable { let adjustments: DevelopAdjustments; let saturation: Double; let dimension: Int }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = try encoder.encode(Key(adjustments: a, saturation: saturation, dimension: dimension)) as NSData
        let data: Data
        if let cached = cubes.object(forKey: key) { data = cached as Data }
        else {
            var values = [Float](); values.reserveCapacity(dimension * dimension * dimension * 4)
            for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
                let c = transform(RGB(Double(r), Double(g), Double(b)) / Double(dimension - 1), adjustments: a, saturation: saturation)
                values.append(contentsOf: [Float(c.x), Float(c.y), Float(c.z), 1])
            } } }
            data = values.withUnsafeBytes { Data($0) }
            cubes.totalCostLimit = 32 * 1024 * 1024
            cubes.setObject(data as NSData, forKey: key, cost: data.count)
        }
        return input.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorCube", parameters: ["inputCubeDimension": dimension, "inputCubeData": data])
            .applyingFilter("CISRGBToneCurveToLinear").cropped(to: input.extent)
    }
}
