import XCTest
import CoreImage
@testable import Phosdeck

final class DevelopV2Tests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "b", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func image(width: Int, height: Int, pixels: (Int, Int) -> SIMD3<Double>) -> CIImage {
        var data = [Float]()
        for y in 0..<height { for x in 0..<width {
            let p = pixels(x, y); data.append(contentsOf: [Float(p.x), Float(p.y), Float(p.z), 1])
        } }
        return data.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: width * 16, size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: linear)
        }
    }
    private func pixels(_ input: CIImage) -> [Float] {
        let rect = input.extent.integral
        var values = [Float](repeating: 0, count: Int(rect.width * rect.height * 4))
        context.render(input, toBitmap: &values, rowBytes: Int(rect.width) * 16, bounds: rect, format: .RGBAf, colorSpace: linear)
        return values
    }
    func testGuidedFilterAgainstIndependentCPUBoxReference() throws {
        let w = 19, h = 13, r = 2, epsilon = 0.015
        let i = (0..<(w*h)).map { Double($0 % w < 9 ? 0.2 : 0.8) + Double($0 % 7) * 0.004 }
        let p = (0..<(w*h)).map { 0.3 * i[$0] + sin(Double($0)) * 0.07 }
        func mean(_ a: [Double]) -> [Double] {
            (0..<(w*h)).map { n in
                var sum = 0.0
                for dy in -r...r { for dx in -r...r {
                    sum += a[min(h-1, max(0, n/w+dy))*w + min(w-1, max(0, n%w+dx))]
                } }
                return sum / Double((2*r+1)*(2*r+1))
            }
        }
        let mi = mean(i), mp = mean(p), ii = mean(i.map { $0*$0 }), ip = mean(zip(i,p).map(*))
        let a = i.indices.map { (ip[$0] - mi[$0]*mp[$0]) / (ii[$0] - mi[$0]*mi[$0] + epsilon) }
        let b = i.indices.map { mp[$0] - a[$0]*mi[$0] }
        let ma = mean(a), mb = mean(b)
        let guide = image(width: w, height: h) { x,y in SIMD3(repeating: i[y*w+x]) }
        let input = image(width: w, height: h) { x,y in SIMD3(repeating: p[y*w+x]) }
        let actual = pixels(try SpatialDevelopPipeline.guided(input, guide: guide, radius: Double(r), epsilon: epsilon))
        let maxError = i.indices.map { abs(Double(actual[$0*4]) - (ma[$0]*i[$0]+mb[$0])) }.max()!
        XCTAssertLessThan(maxError, 0.0003)
        XCTAssertTrue(i.indices.allSatisfy { abs(actual[$0*4+3]-1) < 0.00001 })
    }
    func testFastGuideUsesFullResolutionEdgesAndPreservesConstants() throws {
        let guide = image(width: 160, height: 80) { x,_ in SIMD3(repeating: x < 79 ? 0.1 : 0.8) }
        let full = pixels(try SpatialDevelopPipeline.guided(guide, guide: guide, radius: 12, epsilon: 0.0001, maxEdge: 40))
        XCTAssertLessThan(full[(40*160+78)*4], 0.13)
        XCTAssertGreaterThan(full[(40*160+79)*4], 0.77)
        let constant = image(width: 160, height: 80) { _,_ in SIMD3(repeating: 0.37) }
        let filtered = pixels(try SpatialDevelopPipeline.guided(constant, guide: guide, radius: 12, epsilon: 0.01, maxEdge: 40))
        let maxError = stride(from:0,to:filtered.count,by:4).map { abs(filtered[$0]-0.37) }.max()!
        XCTAssertLessThan(maxError,0.0003)
    }
    func testDarkChannelRecoversSyntheticHazeAndNegativeAddsHaze() throws {
        let w = 128, h = 64, air = SIMD3<Double>(0.8,0.85,0.9), t = 0.55
        func clear(_ x: Int, _ y: Int) -> SIMD3<Double> {
            if x >= 104 { return air }
            if (x/4 + y/4) % 3 == 0 { return SIMD3(0, 0.12, 0.18) }
            return SIMD3(0.4 + Double(x%4)*0.03, 0.22, 0.08)
        }
        let source = image(width: w, height: h) { x,y in clear(x,y)*t + air*(1-t) }
        let estimate = try SpatialDevelopPipeline.estimateAirlight(source, context: context)
        XCTAssertEqual(estimate.x, air.x, accuracy: 0.001)
        XCTAssertEqual(estimate.y, air.y, accuracy: 0.001)
        XCTAssertEqual(estimate.z, air.z, accuracy: 0.001)
        let actual = pixels(try SpatialDevelopPipeline.dehaze(source, amount: 100, context: context))
        let fog = pixels(try SpatialDevelopPipeline.dehaze(source, amount: -100, context: context))
        var initialError = 0.0, restoredError = 0.0, fogError = 0.0
        for y in 16..<48 { for x in 16..<80 {
            let expected = clear(x,y), hazy = expected*t+air*(1-t)
            for c in 0..<3 {
                let n = (y*w+x)*4+c
                initialError += abs(hazy[c]-expected[c])
                restoredError += abs(Double(actual[n])-expected[c])
                fogError += abs(Double(fog[n])-expected[c])
            }
        } }
        XCTAssertLessThan(restoredError, initialError * 0.4)
        XCTAssertGreaterThan(fogError, initialError)
        XCTAssertTrue(actual.allSatisfy(\.isFinite))
        XCTAssertEqual(pixels(try SpatialDevelopPipeline.dehaze(source, amount: 0, context: context)), pixels(source))
    }
    func testToneCurveMonotonicAtExtremeCombinationsAndRetainsRGBRatios() throws {
        let guide = image(width: 513, height: 1) { x,_ in SIMD3(repeating: -16 + Double(x) / 32) }
        let source = image(width: 513, height: 1) { x,_ in SIMD3(1,0.5,0.25) * exp2(-16 + Double(x)/32) }
        for bits in 0..<16 {
            let p = (0..<4).map { bits & (1 << $0) == 0 ? -100.0 : 100.0 }
            let out = pixels(try SpatialDevelopPipeline.run("toneEqualize", extent: source.extent, [source, guide, CIVector(x:p[0], y:p[1], z:p[2], w:p[3])]))
            for x in 1...512 {
                XCTAssertGreaterThanOrEqual(out[x*4] + 1e-8, out[(x-1)*4])
                XCTAssertEqual(out[x*4], out[x*4+1]*2, accuracy: 1e-5)
                XCTAssertEqual(out[x*4], out[x*4+2]*4, accuracy: 1e-5)
            }
        }
    }
    func testAirlightSingleReadbackMatchesGPUMorphologyReference() throws {
        let source = image(width:64,height:32) { x,y in
            SIMD3(0.25 + Double((x*13+y*17)%73)/100,
                  0.2 + Double((x*7+y*11)%71)/100,
                  0.15 + Double((x*5+y*3)%67)/100)
        }
        let rgb = pixels(source)
        let dark = try SpatialDevelopPipeline.run("darkChannel",extent:source.extent,[source,CIVector(x:1,y:1,z:1)])
            .clampedToExtent().applyingFilter("CIMorphologyRectangleMinimum",parameters:["inputWidth":3,"inputHeight":3]).cropped(to:source.extent)
        let values = pixels(dark)
        let sorted = (0..<2048).sorted { lhs, rhs in
            let a = values[lhs * 4], b = values[rhs * 4]
            return a == b ? lhs < rhs : a > b
        }
        func brightness(_ i:Int) -> Float { rgb[i*4] + rgb[i*4+1] + rgb[i*4+2] }
        let index = sorted.prefix(3).max { brightness($0) < brightness($1) }!
        let actual = try SpatialDevelopPipeline.estimateAirlight(source,context:context)
        for c in 0..<3 { XCTAssertEqual(actual[c],Double(rgb[index*4+c]),accuracy:1e-6) }
    }
    func testDetailProtectsStrongEdgesAndChangesSmallTexture() throws {
        let w = 96, h = 48
        let source = image(width: w, height: h) { x,_ in
            let level = x < 48 ? 0.12 : 0.65
            return SIMD3(repeating: level * (1 + 0.05*sin(Double(x)*0.9)))
        }
        for key in [\DevelopAdjustments.texture, \.clarity] {
            var a = DevelopAdjustments(); a[keyPath:key] = 100
            let positive = pixels(try SpatialDevelopPipeline.apply(source, adjustments:a, context:context))
            a[keyPath:key] = -100
            let negative = pixels(try SpatialDevelopPipeline.apply(source, adjustments:a, context:context))
            let original = pixels(source)
            var beforeEnergy = 0.0, plusEnergy = 0.0, minusEnergy = 0.0
            for x in 12..<35 {
                let n = (24*w+x)*4
                beforeEnergy += pow(Double(original[n])-0.12, 2)
                plusEnergy += pow(Double(positive[n])-0.12, 2)
                minusEnergy += pow(Double(negative[n])-0.12, 2)
            }
            XCTAssertGreaterThan(plusEnergy, beforeEnergy)
            XCTAssertLessThan(minusEnergy, beforeEnergy)
            XCTAssertLessThan(positive[(24*w+48)*4], 0.74, "bright edge overshoot")
            XCTAssertGreaterThan(negative[(24*w+48)*4], 0.57, "negative detail must retain the main edge")
            for n in stride(from: 0, to: positive.count, by: 4) {
                XCTAssertTrue(positive[n].isFinite)
                XCTAssertEqual(positive[n+3], 1, accuracy: 0.0001)
            }
        }
    }
    func testOklabKnownVectorsRoundTripAndGamutHue() {
        let red = PerceptualColor.lab(SIMD3(1,0,0))
        XCTAssertEqual(red.x, 0.62795536, accuracy: 1e-7)
        XCTAssertEqual(red.y, 0.22486306, accuracy: 1e-7)
        XCTAssertEqual(red.z, 0.12584630, accuracy: 1e-7)
        for c in [SIMD3<Double>(0,0,0), SIMD3(1,1,1), SIMD3(0.05,0.2,0.8), SIMD3(0.7,0.3,0.1)] {
            let roundTrip = PerceptualColor.rgb(PerceptualColor.lab(c))
            // Published rounded matrices have ~3e-7 round-trip error at white.
            for n in 0..<3 { XCTAssertEqual(roundTrip[n], c[n], accuracy: 5e-7) }
        }
        let outOfGamut = SIMD3<Double>(0.6,0.4,-0.4)
        let mapped = PerceptualColor.lab(PerceptualColor.gamutMap(outOfGamut))
        XCTAssertEqual(mapped.x, 0.6, accuracy: 1e-5)
        XCTAssertEqual(atan2(mapped.z,mapped.y), -.pi/4, accuracy: 1e-5)
        XCTAssertLessThan(hypot(mapped.y,mapped.z), hypot(outOfGamut.y,outOfGamut.z))
    }
    func testDetailDoesNotAmplifyNearFlatNoiseAndBlackStaysFinite() throws {
        let flat = image(width:64,height:32) { x,y in SIMD3(repeating:0.3 + 0.0001*sin(Double(x+y*64))) }
        var a = DevelopAdjustments(); a.texture = 100; a.clarity = 100
        let original = pixels(flat)
        let adjusted = pixels(try SpatialDevelopPipeline.apply(flat,adjustments:a,context:context))
        for n in original.indices { XCTAssertEqual(adjusted[n],original[n],accuracy:0.00001) }
        a.highlights = -100; a.shadows = 100; a.whites = 100; a.blacks = -100; a.dehaze = 100
        let black = image(width:32,height:32) { _,_ in SIMD3(repeating:0) }
        let dark = pixels(try SpatialDevelopPipeline.apply(black,adjustments:a,context:context))
        for n in stride(from:0,to:dark.count,by:4) {
            XCTAssertEqual(dark[n],0,accuracy:0.000001)
            XCTAssertEqual(dark[n+3],1,accuracy:0.000001)
        }
    }
    func testMixerIndependentLightnessNeutralsAllBandsAndWrap() {
        for i in 0..<8 {
            let input = DevelopPipeline.rgb(SIMD3(HSLBand.centers[i],0.45,0.5))
            let baseline = PerceptualColor.lab(PerceptualColor.linear(input))
            var a = DevelopAdjustments(); a.mixer[i].saturation = -100
            let gray = PerceptualColor.transform(input, adjustments:a)
            XCTAssertEqual(gray.x,gray.y,accuracy:1e-5); XCTAssertEqual(gray.y,gray.z,accuracy:1e-5)
            a.mixer[i].saturation = 40
            let saturated = PerceptualColor.lab(PerceptualColor.linear(PerceptualColor.transform(input, adjustments:a)))
            XCTAssertEqual(saturated.x,baseline.x,accuracy:1e-5)
            XCTAssertEqual(atan2(saturated.z,saturated.y),atan2(baseline.z,baseline.y),accuracy:1e-5)
            a = DevelopAdjustments(); a.mixer[i].luminance = 50
            let raised = PerceptualColor.lab(PerceptualColor.linear(PerceptualColor.transform(input, adjustments:a)))
            XCTAssertGreaterThan(raised.x,baseline.x+0.02)
            a.mixer[i].hue = 100
            let neutral = PerceptualColor.transform(SIMD3(repeating:0.4),adjustments:a)
            XCTAssertEqual(neutral.x,0.4,accuracy:1e-5); XCTAssertEqual(neutral.y,0.4,accuracy:1e-5)
        }
        var a = DevelopAdjustments(); a.mixer[0].hue = 100
        let left = PerceptualColor.transform(DevelopPipeline.rgb(SIMD3(359.999,0.5,0.5)),adjustments:a)
        let right = PerceptualColor.transform(DevelopPipeline.rgb(SIMD3(0.001,0.5,0.5)),adjustments:a)
        XCTAssertLessThan(abs(left.x-right.x)+abs(left.y-right.y)+abs(left.z-right.z),0.0001)
    }
    func testGradingPreservesLightnessEndpointsAndBalance() {
        var a = DevelopAdjustments()
        a.grading.shadows = GradingTone(hue:240,saturation:60)
        a.grading.highlights = GradingTone(hue:30,saturation:60)
        let source = SIMD3<Double>(repeating:0.45)
        let originalL = PerceptualColor.lab(PerceptualColor.linear(source)).x
        let result = PerceptualColor.transform(source,adjustments:a)
        XCTAssertEqual(PerceptualColor.lab(PerceptualColor.linear(result)).x,originalL,accuracy:1e-5)
        a.grading.balance = 100
        let warm = PerceptualColor.transform(source,adjustments:a)
        a.grading.balance = -100
        let cool = PerceptualColor.transform(source,adjustments:a)
        XCTAssertGreaterThan(warm.x,cool.x); XCTAssertGreaterThan(cool.z,warm.z)
        a.grading.global = GradingTone(hue:120,saturation:100,luminance:60)
        for endpoint in [0.0,1.0] {
            let c = PerceptualColor.transform(SIMD3(repeating:endpoint),adjustments:a)
            for n in 0..<3 { XCTAssertEqual(c[n],endpoint,accuracy:1e-5) }
        }
    }
    func testVersionRoutingLegacyPixelsAndCurrentCube() throws {
        var r = recipe(); r.pipelineVersion = 1
        r.develop.shadows = 35; r.develop.texture = 15; r.develop.dehaze = 10
        r.develop.mixer[0].hue = 30
        let source = image(width:32,height:16) { x,_ in SIMD3(Double(x)/40,0.15,0.08) }
        let routed = try ImagePipeline.develop(source,recipe:r,context:context)
        let legacy = DevelopPipeline.apply(ImagePipeline.colorControls(source,recipe:r),adjustments:r.develop)
        XCTAssertEqual(pixels(routed),pixels(legacy))
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:JSONEncoder().encode(r)).pipelineVersion,1)
        r = recipe()
        XCTAssertEqual(r.pipelineVersion,2)
        XCTAssertEqual(pixels(try ImagePipeline.develop(source,recipe:r,context:context)),pixels(source))
        // Hue/blending selections with zero grading strength are also a true bypass.
        let bright = image(width:4,height:4) { _,_ in SIMD3(2,1.2,0.8) }
        var inactive = DevelopAdjustments()
        inactive.grading.global.hue = 240; inactive.grading.blending = 80; inactive.grading.balance = 40
        XCTAssertEqual(pixels(try PerceptualColor.apply(bright,adjustments:inactive,saturation:1)),pixels(bright))
        r.develop.mixer[0].saturation = -40
        r.develop.grading.global = GradingTone(hue:220,saturation:15)
        let actual = pixels(try ImagePipeline.develop(source,recipe:r,context:context))
        for x in 1..<31 {
            let c = SIMD3<Double>(Double(x)/40,0.15,0.08)
            let expected = PerceptualColor.linear(PerceptualColor.transform(PerceptualColor.encoded(c),adjustments:r.develop))
            for channel in 0..<3 { XCTAssertEqual(Double(actual[x*4+channel]),expected[channel],accuracy:0.003) }
        }
    }
    func testInteractiveColorCubeDoesNotPolluteFinalQualityCache() throws {
        let source = image(width: 32, height: 16) { x, y in
            SIMD3(Double(x) / 40, Double(y) / 20, 0.12)
        }
        for version in [1, 2] {
            var r = recipe(); r.pipelineVersion = version
            r.develop.vibrance = 20; r.develop.mixer[0].hue = 25
            r.develop.grading.shadows = GradingTone(hue: 220, saturation: 15)
            let final = pixels(try ImagePipeline.develop(source, recipe: r, context: context))
            let draft = pixels(try ImagePipeline.develop(source, recipe: r, context: context, interactive: true))
            let repeated = pixels(try ImagePipeline.develop(source, recipe: r, context: context))
            XCTAssertEqual(final, repeated, "Draft and final LUTs need distinct cache keys")
            XCTAssertTrue(draft.allSatisfy { $0.isFinite })
            let difference = zip(final, draft).map { abs($0 - $1) }.reduce(0, +) / Float(final.count)
            XCTAssertGreaterThan(difference, 0.000001)
            XCTAssertLessThan(difference, 0.01, "Draft should remain a useful color approximation")
        }
    }

}
