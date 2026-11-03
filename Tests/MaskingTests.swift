import XCTest
import CoreImage
import GRDB
import SwiftUI
import AppKit
import Darwin
@testable import Phosdeck

final class MaskingTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func image(_ value: Double, size: CGSize = CGSize(width: 100, height: 80)) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: CGRect(origin: .zero, size: size))
    }
    private func pixel(_ image: CIImage, _ x: Int = 0, _ y: Int = 0) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return data
    }
    func testMaskRasterCachePreservesCoverageAndInvalidatesGeometryAndGuide() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 48)
        let other = image(0.8, size: extent.size)
        let base = image(0.125, size: CGSize(width: 32, height: 48)).composited(over: other)
        let cache = MaskPipeline.RasterCache(byteLimit: 64 * 48 * 16)
        var group = LocalAdjustment(components: [MaskComponent(tool: .luminance)])
        group.refinement = MaskRefinement(edgeRadius: 0.1, blurRadius: 0.1, expansion: 0.1, hardness: 0.2)
        group.exposure = 1
        func cached(_ guide: CIImage, bounds: CGRect = CGRect(x: 0, y: 0, width: 64, height: 48)) throws -> CIImage {
            let result = try cache.mask(group, extent: bounds, baseline: guide, context: context)
            let reference = try MaskPipeline.mask(group, extent: bounds, baseline: guide)
            var a = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4), b = a
            context.render(result, toBitmap: &a, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
            context.render(reference, toBitmap: &b, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
            XCTAssertLessThan(zip(a, b).map { abs($0 - $1) }.max() ?? 0, 0.00001)
            return result
        }
        let first = try cached(base)
        group.name = "重命名"; group.exposure = 2; group.settings = LocalDevelopSettings()
        group.settings?.develop.clarity = 20
        XCTAssertTrue(try cached(base) === first, "Effect changes reuse coverage")
        group.components[0].upper = 0.4
        let changedShape = try cached(base)
        XCTAssertFalse(changedShape === first)
        group.amount = 0.5
        let changedAmount = try cached(base)
        XCTAssertFalse(changedAmount === changedShape)
        group.refinement?.hardness = -0.2
        let changedRefinement = try cached(base)
        XCTAssertFalse(changedRefinement === changedAmount)
        XCTAssertFalse(try cached(other) === changedRefinement)
        let small = try cached(other, bounds: CGRect(x: 3, y: 5, width: 32, height: 24))
        XCTAssertEqual(small.extent, CGRect(x: 3, y: 5, width: 32, height: 24))
        XCTAssertEqual(cache.retainedBytes, 32 * 24 * 16)
        var second = group; second.id = UUID()
        _ = try cache.mask(second, extent: extent, baseline: base, context: context)
        XCTAssertEqual(cache.retainedBytes, 32 * 24 * 16, "Do not churn an admitted mask when the next mask exceeds the remaining budget")
        XCTAssertTrue(try cached(other, bounds: small.extent) === small)
        cache.retain(groups: [])
        XCTAssertEqual(cache.retainedBytes, 0)
        _ = try cache.mask(group, extent: CGRect(x: 0, y: 0, width: 128, height: 96), baseline: base, context: context)
        XCTAssertEqual(cache.retainedBytes, 0, "Oversize masks follow the uncached path")
    }
    func testRepeatedMultiMaskRendering() throws {
        let extent = CGRect(x: 0, y: 0, width: 960, height: 640)
        let base = try XCTUnwrap(CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 63])?.outputImage).cropped(to: extent)
        for count in [1, 5, 10] {
            var groups = (0..<count).map { index in
                var component = MaskComponent(tool: .brush)
                component.strokes = [MaskStroke(points: [MaskPoint(0.1, Double(index + 1) / 12), MaskPoint(0.8, 0.7)], radius: 0.06, autoMask: true)]
                var group = LocalAdjustment(components: [component])
                group.settings = LocalDevelopSettings()
                group.settings?.develop.texture = 10
                group.exposure = 0.1
                return group
            }
            let cache = MaskPipeline.RasterCache()
            var coldTimes: [Double] = [], cachedTimes: [Double] = []
            for frame in 0..<4 {
                groups[0].saturation = 1 + Double(frame) * 0.03
                _ = try PerceptualColor.apply(base, adjustments: groups[0].settings!.develop, saturation: groups[0].saturation)
                try autoreleasepool {
                    var started = Date()
                    let graph = try MaskPipeline.apply(base, groups: groups, baseline: base, context: context)
                    let reference = try XCTUnwrap(context.createCGImage(graph, from: extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
                    coldTimes.append(Date().timeIntervalSince(started) * 1000)
                    started = Date()
                    let result = try MaskPipeline.apply(base, groups: groups, baseline: base, context: context, cache: cache)
                    let rendered = try XCTUnwrap(context.createCGImage(result, from: extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
                    cachedTimes.append(Date().timeIntervalSince(started) * 1000)
                    XCTAssertTrue(reference.dataProvider?.data == rendered.dataProvider?.data, "Cache must preserve ordered local effects")
                }
            }
            print("NATIVE_PERF masks=\(count) uncached_ms=\(coldTimes) cached_ms=\(cachedTimes) bytes=\(cache.retainedBytes)")
            var usage = rusage()
            if getrusage(RUSAGE_SELF, &usage) == 0 { print("NATIVE_PERF masks=\(count) test_host_peak_rss_bytes=\(usage.ru_maxrss)") }
        }
    }
    func testSoftOperationsAndOrdering() throws {
        let a = image(0.4), b = image(0.6)
        for (operation, expected) in [(MaskOperation.replace, 0.6), (.add, 0.6), (.subtract, 0.16), (.intersect, 0.24)] {
            XCTAssertEqual(Double(pixel(try MaskPipeline.combine(a, b, operation: operation))[0]), expected, accuracy: 0.0001)
        }
        XCTAssertEqual(pixel(try MaskPipeline.combine(a, b, operation: .replace, invert: true, amount: 0.5))[0], 0.2, accuracy: 0.0001)
        let left = try MaskPipeline.combine(MaskPipeline.combine(a, b, operation: .add), image(0.5), operation: .intersect)
        let right = try MaskPipeline.combine(MaskPipeline.combine(a, image(0.5), operation: .intersect), b, operation: .add)
        XCTAssertEqual(pixel(left)[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(pixel(right)[0], 0.6, accuracy: 0.0001)
    }
    func testFiveToolsAndLocalAdjustments() throws {
        let base = image(0.2), extent = base.extent
        var linear = MaskComponent(tool: .linear); linear.start = MaskPoint(0, 0); linear.end = MaskPoint(1, 0)
        var group = LocalAdjustment(components: [linear]); group.exposure = 1
        let mask = try MaskPipeline.mask(group, extent: extent, baseline: nil)
        XCTAssertEqual(pixel(mask, 24, 20)[0], 0.245, accuracy: 0.01)
        let edited = try MaskPipeline.apply(base, groups: [group], baseline: nil)
        XCTAssertEqual(pixel(edited, 24, 20)[0], 0.2 * 1.245, accuracy: 0.003)
        group.inverted = true
        XCTAssertEqual(pixel(try MaskPipeline.mask(group, extent: extent, baseline: nil), 24, 20)[0], 0.755, accuracy: 0.01)
        group.inverted = false; group.components[0].inverted = true
        XCTAssertEqual(pixel(try MaskPipeline.mask(group, extent: extent, baseline: nil), 24, 20)[0], 0.755, accuracy: 0.01)
        group.amount = 0
        XCTAssertEqual(pixel(try MaskPipeline.apply(base, groups: [group], baseline: nil), 24, 20)[0], 0.2, accuracy: 0.0001)
        var radial = MaskComponent(tool: .radial); radial.feather = 0
        let radialMask = try MaskPipeline.component(radial, extent: extent, baseline: nil)
        XCTAssertEqual(pixel(radialMask, 50, 40)[0], 1, accuracy: 0.001)
        XCTAssertEqual(pixel(radialMask, 2, 2)[0], 0, accuracy: 0.001)
        group = LocalAdjustment(components: [radial]); group.exposure = 2
        XCTAssertEqual(pixel(try MaskPipeline.apply(base, groups: [group], baseline: nil), 2, 2)[0], pixel(base, 2, 2)[0], accuracy: 0.00001)
        let enabledResult = try MaskPipeline.apply(base, groups: [group], baseline: nil)
        group.enabled = false
        XCTAssertEqual(pixel(try MaskPipeline.apply(base, groups: [group], baseline: nil), 50, 40)[0], pixel(base, 50, 40)[0])
        group.enabled = true
        XCTAssertEqual(pixel(try MaskPipeline.apply(base, groups: [group], baseline: nil), 50, 40)[0], pixel(enabledResult, 50, 40)[0])
        group.exposure = 0
        XCTAssertEqual(pixel(try MaskPipeline.apply(base, groups: [group], baseline: nil))[0], pixel(base)[0])

        var color = MaskComponent(tool: .color); color.tolerance = 0.01; color.smoothness = 0.01
        color.samples = [MaskSample(point: MaskPoint(0.5, 0.5), red: 0.2, green: 0.2, blue: 0.2)]
        XCTAssertEqual(pixel(try MaskPipeline.component(color, extent: extent, baseline: base))[0], 1, accuracy: 0.0001)
        XCTAssertEqual(pixel(try MaskPipeline.component(color, extent: extent, baseline: image(0.8)))[0], 0, accuracy: 0.0001)
        color.tolerance = 1
        XCTAssertEqual(pixel(try MaskPipeline.component(color, extent: extent, baseline: image(0.8)))[0], 1, accuracy: 0.0001)
        color.tolerance = 0.01
        color.samples.append(MaskSample(point: MaskPoint(0.2, 0.2), red: 0.8, green: 0.8, blue: 0.8))
        XCTAssertEqual(pixel(try MaskPipeline.component(color, extent: extent, baseline: image(0.8)))[0], 1, accuracy: 0.0001)
        XCTAssertThrowsError(try MaskPipeline.component(color, extent: extent, baseline: nil))
        var luminance = MaskComponent(tool: .luminance); luminance.lower = 0.4; luminance.upper = 0.6; luminance.smoothness = 0.1
        // Neutral Oklab L is cube-root(linear luminance).
        XCTAssertEqual(pixel(try MaskPipeline.component(luminance, extent: extent, baseline: image(0.125)))[0], 1, accuracy: 0.001)
        XCTAssertEqual(pixel(try MaskPipeline.component(luminance, extent: extent, baseline: image(0.35 * 0.35 * 0.35)))[0], 0.5, accuracy: 0.002)
        XCTAssertEqual(pixel(try MaskPipeline.component(luminance, extent: extent, baseline: image(0.001)))[0], 0, accuracy: 0.001)
    }
    /// Lightcraft refine 50: lightness counts half, full select through 0.0225, gone by 0.045.
    func testColorRangeUsesHalfLightnessAndTheLightcraftDefault() throws {
        XCTAssertEqual(ColorRange.radius(refine: 0), 0.0075, accuracy: 0.000001)
        XCTAssertEqual(ColorRange.radius(refine: 50), 0.0225, accuracy: 0.000001)
        XCTAssertEqual(ColorRange.radius(refine: 100), 0.0375, accuracy: 0.000001)
        XCTAssertEqual(ColorRange.refine(radius: 0.0225), 50, accuracy: 0.001)
        var component = MaskComponent(tool: .color)
        XCTAssertEqual(component.tolerance, 0.0225, accuracy: 0.000001)
        XCTAssertEqual(component.smoothness, 0.0225, accuracy: 0.000001)
        XCTAssertEqual(MaskComponent(tool: .luminance).smoothness, 0.1, accuracy: 0.000001)
        let sample = SIMD3<Double>(0.45, 0.12, 0.04)
        component.samples = [MaskSample(point: MaskPoint(0.5, 0.5), red: sample.x, green: sample.y, blue: sample.z)]
        let extent = CGRect(x: 0, y: 0, width: 1, height: 1)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func coverage(_ rgb: SIMD3<Double>) throws -> Float {
            let block = CIImage(color: CIColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1, colorSpace: space)!).cropped(to: extent)
            return pixel(try MaskPipeline.component(component, extent: extent, baseline: block))[0]
        }
        func weighted(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let d = a - b
            return (0.25 * d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        }
        let origin = PerceptualColor.lab(sample)
        func shifted(_ deltaL: Double) -> SIMD3<Double> {
            PerceptualColor.rgb(SIMD3(origin.x + deltaL, origin.y, origin.z))
        }
        XCTAssertEqual(try coverage(sample), 1, accuracy: 0.001)
        let slight = shifted(0.08)
        XCTAssertEqual(weighted(PerceptualColor.lab(slight), origin), 0.04, accuracy: 0.002)
        XCTAssertEqual(try coverage(slight), 0.126, accuracy: 0.04, "A half-weighted 0.08 L shift sits in the fade from 0.0225 to 0.045")
        let lighter = shifted(0.16)
        XCTAssertEqual(weighted(PerceptualColor.lab(lighter), origin), 0.08, accuracy: 0.002)
        XCTAssertEqual(try coverage(lighter), 0, accuracy: 0.02, "A half-weighted 0.16 L shift is past 0.045")
        let neutral = PerceptualColor.rgb(SIMD3(origin.x, 0, 0))
        XCTAssertEqual(weighted(PerceptualColor.lab(neutral), origin), 0.119, accuracy: 0.002)
        XCTAssertEqual(try coverage(neutral), 0, accuracy: 0.02, "The equal-lightness neutral is outside the default")
        XCTAssertEqual(try coverage(SIMD3(0.05, 0.08, 0.40)), 0, accuracy: 0.02)
    }
    func testGradientGeometryOutsidePhoto() throws {
        var linear = MaskComponent(tool: .linear)
        linear.start = MaskPoint(-0.5, 0.5); linear.end = MaskPoint(1.5, 0.5)
        try linear.validate()
        let mask = try MaskPipeline.component(linear, extent: CGRect(x: 0, y: 0, width: 100, height: 80), baseline: nil)
        XCTAssertEqual(pixel(mask, 0, 40)[0], 0.2525, accuracy: 0.001)
        let larger = try MaskPipeline.component(linear, extent: CGRect(x: 0, y: 0, width: 1000, height: 800), baseline: nil)
        XCTAssertEqual(pixel(mask, 49, 40)[0], pixel(larger, 494, 400)[0], accuracy: 0.001)
        var radial = MaskComponent(tool: .radial)
        radial.start = MaskPoint(-0.1, 0.5); radial.radiusX = 0.3; radial.feather = 0
        try radial.validate()
        let ellipse = try MaskPipeline.component(radial, extent: mask.extent, baseline: nil)
        XCTAssertEqual(pixel(ellipse, 0, 40)[0], 1, accuracy: 0.001)
        XCTAssertEqual(pixel(ellipse, 90, 40)[0], 0, accuracy: 0.001)
        XCTAssertEqual(MaskEditGesture.hit(MaskPoint(0.2, 0.5), component: radial, size: mask.extent.size), .radiusX)
        linear.start = MaskPoint(-0.5, 0.2); linear.end = MaskPoint(-0.5, 0.8)
        XCTAssertEqual(MaskEditGesture.hit(MaskPoint(0.6, 0.5), component: linear, size: mask.extent.size), .move, "The visible center line remains reachable")
        for turn in 0...3 {
            var r = recipe(); r.quarterTurns = turn; r.straightenDegrees = 12
            r.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            let mapping = MaskGeometry.mapping(size: mask.extent.size, recipe: r)
            let original = CGPoint(x: -0.2 * 100, y: 1.2 * 80)
            let mapped = original.applying(mapping.transform)
            let output = CGPoint(x: mapped.x / mapping.output.width, y: mapped.y / mapping.output.height)
            let inverse = try XCTUnwrap(MaskGeometry.sourcePoint(output, size: mask.extent.size, recipe: r, allowOutside: true))
            XCTAssertEqual(inverse.x, -0.2, accuracy: 0.000001); XCTAssertEqual(inverse.y, 1.2, accuracy: 0.000001)
            XCTAssertNil(MaskGeometry.sourcePoint(output, size: mask.extent.size, recipe: r), "Sampling still requires a point inside the photo")
        }
        linear.start.x = .nan; XCTAssertThrowsError(try linear.validate())
        XCTAssertNil(MaskGeometry.sourcePoint(CGPoint(x: CGFloat.nan, y: 0), size: mask.extent.size, recipe: recipe(), allowOutside: true))
    }

    func testFixedRotationRod() throws {
        var c = MaskComponent(tool: .radial)
        for tool in [MaskTool.linear, .radial] {
            c = MaskComponent(tool: tool)
            for scale in [0.2, 1.0, 3.0] {
                let size = CGSize(width: 6000, height: 4000)
                let offset = 36 / scale
                let h = try XCTUnwrap(MaskEditGesture.handles(c, size: size, rotationOffset: offset).last)
                let anchor = tool == .linear ? c.start : MaskPoint(c.start.x, c.start.y + c.radiusY)
                XCTAssertEqual(hypot((h.point.x - anchor.x) * size.width, (h.point.y - anchor.y) * size.height) * scale, 36, accuracy: 0.0001)
                XCTAssertEqual(MaskEditGesture.hit(h.point, component: c, size: size, tolerance: 11 / scale, rotationOffset: offset), .rotate)
            }
        }
    }

    func testRefinementMorphologyHardnessAndOperationOrder() throws {
        let size = CGSize(width: 400, height: 200), extent = CGRect(origin: .zero, size: size)
        var c = MaskComponent(tool: .radial); c.feather = 0
        var group = LocalAdjustment(components: [c])
        let original = try MaskPipeline.mask(group, extent: extent, baseline: nil)
        XCTAssertEqual(pixel(try MaskPipeline.refine(original, settings: MaskRefinement(), baseline: nil), 99, 100), pixel(original, 99, 100))
        group.refinement = MaskRefinement(expansion: 1)
        XCTAssertEqual(pixel(original, 98, 100)[0], 0)
        XCTAssertGreaterThan(pixel(try MaskPipeline.mask(group, extent: extent, baseline: nil), 98, 100)[0], 0.9)
        group.refinement?.expansion = -1
        XCTAssertLessThan(pixel(try MaskPipeline.mask(group, extent: extent, baseline: nil), 102, 100)[0], 0.1)
        group.inverted = true; group.refinement?.expansion = 1
        XCTAssertGreaterThan(pixel(try MaskPipeline.mask(group, extent: extent, baseline: nil), 102, 100)[0], 0.9, "Positive expansion grows the inverted selection")
        group.inverted = false; group.refinement = MaskRefinement(blurRadius: 0.5)
        let blurred = try MaskPipeline.mask(group, extent: extent, baseline: nil)
        XCTAssertGreaterThan(pixel(blurred, 97, 100)[0], 0.05)
        XCTAssertLessThan(pixel(blurred, 102, 100)[0], 0.95)
        XCTAssertEqual(pixel(blurred, 200, 100)[0], 1, accuracy: 0.001)
        XCTAssertEqual(pixel(blurred, 5, 100)[0], 0, accuracy: 0.001)
        for h in [-1.0, 1.0] {
            for x in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let output = try MaskPipeline.refine(image(x), settings: MaskRefinement(hardness: h), baseline: nil)
                let power = pow(2, h * 2), a = pow(x, power), b = pow(1 - x, power)
                XCTAssertEqual(Double(pixel(output)[0]), a / (a + b), accuracy: 0.00002)
                XCTAssertEqual(pixel(output)[3], 1)
            }
        }
        group.refinement?.hardness = 0.7
        let full = try MaskPipeline.mask(group, extent: extent, baseline: nil)
        group.amount = 0.25
        XCTAssertEqual(pixel(try MaskPipeline.mask(group, extent: extent, baseline: nil), 100, 100)[0], pixel(full, 100, 100)[0] * 0.25, accuracy: 0.00001)
        group.refinement?.edgeRadius = 1; group.enabled = false
        XCTAssertEqual(pixel(try MaskPipeline.mask(group, extent: extent, baseline: nil))[0], 0, "Disabled masks need no baseline")
        group.enabled = true; XCTAssertThrowsError(try MaskPipeline.mask(group, extent: extent, baseline: nil))
        group.refinement?.edgeRadius = .nan; XCTAssertThrowsError(try group.validate())
        group.refinement = MaskRefinement(expansion: 1.1); XCTAssertThrowsError(try group.validate())
    }

    func testGuidedRefinementFollowsBaselineEdgesAndPreservesConstants() throws {
        let size = CGSize(width: 400, height: 200), extent = CGRect(origin: .zero, size: size)
        let reference = image(0.729, size: size).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 200))
            .composited(over: image(0.008, size: size))
        let rough = image(1, size: size).cropped(to: CGRect(x: 202, y: 0, width: 198, height: 200))
            .composited(over: image(0, size: size))
        let settings = MaskRefinement(edgeRadius: 1)
        let refined = try MaskPipeline.refine(rough, settings: settings, baseline: reference)
        let blurred = try MaskPipeline.refine(rough, settings: MaskRefinement(blurRadius: 1), baseline: nil)
        XCTAssertGreaterThan(pixel(refined, 201, 100)[0], 0.6)
        XCTAssertLessThan(pixel(refined, 199, 100)[0], 0.08)
        XCTAssertGreaterThan(pixel(blurred, 199, 100)[0], 0.2, "Gaussian smoothing cannot align to this edge")
        for value in [0.0, 0.5, 1.0] {
            let constant = try MaskPipeline.refine(image(value, size: size), settings: settings, baseline: reference)
            for x in [0, 199, 201, 399] { XCTAssertEqual(Double(pixel(constant, x, 100)[0]), value, accuracy: 0.001) }
        }
        let offset = CGAffineTransform(translationX: 37, y: 23)
        let translated = try MaskPipeline.refine(rough.transformed(by: offset), settings: settings, baseline: reference.transformed(by: offset))
        XCTAssertEqual(translated.extent, extent.applying(offset))
        XCTAssertEqual(pixel(translated, 238, 123)[0], pixel(refined, 201, 100)[0], accuracy: 0.00001)
        var linear = MaskComponent(tool: .linear); linear.start = MaskPoint(0.5, 0); linear.end = MaskPoint(0.51, 0)
        var group = LocalAdjustment(components: [linear]); group.refinement = MaskRefinement(edgeRadius: 1, blurRadius: 0.1, expansion: 0.2, hardness: 0.2)
        let large = try MaskPipeline.mask(group, extent: extent, baseline: reference)
        let small = try MaskPipeline.mask(group, extent: CGRect(x: 0, y: 0, width: 200, height: 100), baseline: reference)
        let downsampled = large.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1])
        for x in [20, 80, 95, 98, 99, 100, 101, 105, 120, 180] {
            XCTAssertEqual(pixel(downsampled, x, 50)[0], pixel(small, x, 50)[0], accuracy: 0.08)
        }
    }

    func testFullDevelopIsRestrictedToMask() throws {
        let extent = CGRect(x: 0, y: 0, width: 100, height: 80)
        let scene = CIImage(color: CIColor(red: 0.6, green: 0.2, blue: 0.08)).cropped(to: CGRect(x: 40, y: 25, width: 20, height: 30))
            .composited(over: image(0.15))
        var c = MaskComponent(tool: .radial); c.feather = 0
        let changes: [(String, (inout LocalDevelopSettings) -> Void)] = [
            ("tone", { $0.develop.highlights = -40; $0.develop.shadows = 35; $0.develop.whites = 15; $0.develop.blacks = -12 }),
            ("detail", { $0.develop.texture = 40; $0.develop.clarity = 30; $0.develop.dehaze = 20 }),
            ("curves", { $0.develop.curves = ToneCurves(); $0.develop.curves?.channels[0][2] = CurvePoint(x:0.42,y:0.65); $0.develop.curves?.insert(channel:1,x:0.37,y:0.45) }),
            ("zones", { $0.develop.zones = ToneZones(gains: [0,0.3,0.8,0.4,0]) }),
            ("color", { $0.develop.vibrance = 40; $0.develop.mixer[0].hue = 35; $0.develop.mixer[0].saturation = -20; $0.develop.mixer[0].luminance = 15 }),
            ("grading", { $0.develop.grading.midtones = GradingTone(hue: 220, saturation: 45, luminance: 10); $0.develop.grading.balance = 20; $0.develop.grading.blending = 75 }),
            ("black and white", { $0.develop.blackAndWhite = true; $0.develop.blackWhiteMixer = [30,-20,15,25,-30,40,10,-15] })
        ]
        for (name, edit) in changes {
            var settings = LocalDevelopSettings(); edit(&settings)
            var group = LocalAdjustment(components: [c]); group.settings = settings
            let local = try MaskPipeline.apply(scene, groups: [group], baseline: nil, context: context)
            let expected = try ImagePipeline.develop(scene, recipe: group.editingRecipe(from: recipe()), context: context)
            var difference: Float = 0
            for (x, y) in [(45, 30), (50, 40), (38, 40), (62, 40)] {
                for channel in 0..<3 {
                    XCTAssertEqual(pixel(local, x, y)[channel], pixel(expected, x, y)[channel], accuracy: 0.001, name)
                    difference += abs(pixel(local, x, y)[channel] - pixel(scene, x, y)[channel])
                }
            }
            XCTAssertGreaterThan(difference, 0.0001, name)
            XCTAssertEqual(pixel(local, 2, 2), pixel(scene, 2, 2), "Outside the mask: \(name)")
            group.amount = 0
            XCTAssertEqual(pixel(try MaskPipeline.apply(scene, groups: [group], baseline: nil), 50, 40), pixel(scene, 50, 40))
        }
        var group = LocalAdjustment(components: [c]); group.settings = LocalDevelopSettings(temperature: 8000, tint: 20, asShotWhiteBalance: false)
        let balanced = try MaskPipeline.apply(image(0.3), groups: [group], baseline: nil)
        XCTAssertNotEqual(pixel(balanced, 50, 40), pixel(image(0.3), 50, 40))
        XCTAssertEqual(pixel(balanced, 2, 2), pixel(image(0.3), 2, 2))
        group.settings?.asShotWhiteBalance = true
        XCTAssertEqual(pixel(try MaskPipeline.apply(image(0.3), groups: [group], baseline: nil), 50, 40), pixel(image(0.3), 50, 40))
        XCTAssertEqual(balanced.extent, extent)
    }

    func testBrushOrientationDensityEraseAndResolution() throws {
        var brush = MaskComponent(tool: .brush)
        let stroke = MaskStroke(points: [MaskPoint(0.25, 0.75), MaskPoint(0.75, 0.75)], radius: 0.08, feather: 0, flow: 1, density: 0.6)
        brush.strokes = [stroke]
        let extent = CGRect(x: 0, y: 0, width: 200, height: 160)
        let mask = try MaskPipeline.component(brush, extent: extent, baseline: nil)
        XCTAssertEqual(pixel(mask, 70, 120)[0], 0.6, accuracy: 0.01)
        XCTAssertEqual(pixel(mask, 70, 40)[0], 0, accuracy: 0.01)
        brush.strokes.append(stroke)
        XCTAssertEqual(pixel(try MaskPipeline.component(brush, extent: extent, baseline: nil), 70, 120)[0], 0.6, accuracy: 0.01)
        var eraser = stroke; eraser.erase = true; eraser.density = 1
        brush.strokes.append(eraser)
        XCTAssertEqual(pixel(try MaskPipeline.component(brush, extent: extent, baseline: nil), 70, 120)[0], 0, accuracy: 0.01)
        brush.strokes = [stroke]
        let doubled = try MaskPipeline.component(brush, extent: CGRect(x: 0, y: 0, width: 400, height: 320), baseline: nil)
        XCTAssertEqual(pixel(doubled, 140, 240)[0], pixel(mask, 70, 120)[0], accuracy: 0.01)
        var bent = stroke; bent.density = 1
        bent.points = [MaskPoint(0.2, 0.2), MaskPoint(0.2, 0.8), MaskPoint(0.8, 0.8)]
        let bend = try MaskPipeline.brush([bent], extent: extent)
        XCTAssertEqual(pixel(bend, 40, 80)[0], 1, accuracy: 0.01)
        XCTAssertEqual(pixel(bend, 100, 128)[0], 1, accuracy: 0.01)
        XCTAssertEqual(pixel(bend, 100, 32)[0], 0, accuracy: 0.01)
        var sparse = stroke; sparse.flow = 0.15
        var dense = sparse; dense.points = (0...20).map { MaskPoint(0.25 + Double($0) * 0.025, 0.75) }
        let a = try MaskPipeline.brush([sparse], extent: extent), b = try MaskPipeline.brush([dense], extent: extent)
        XCTAssertEqual(pixel(a, 80, 120)[0], pixel(b, 80, 120)[0], accuracy: 0.01, "Flow must not depend on mouse event count")
    }
    /// Lightcraft auto_similarity: Euclidean of (ΔEV / 0.5, chroma distance / 0.25).
    /// Full at or below 0.5, gone at or above 1. A pure 0.25 EV shift is the full-paint edge.
    func testAutoMaskSimilarityMatchesLightcraft() {
        func s(_ l: Double, _ ch: SIMD3<Double>, _ rl: Double, _ rch: SIMD3<Double>) -> Double {
            AutoMaskBrush.similarity(logLuminance: l, chroma: ch, referenceLogLuminance: rl, referenceChroma: rch)
        }
        let neutral = SIMD3<Double>(1, 1, 1)
        XCTAssertEqual(s(0, neutral, 0, neutral), 1, accuracy: 0.0001)
        XCTAssertEqual(s(0.25, neutral, 0, neutral), 1, accuracy: 0.0001, "0.25 EV is half of the 0.5 EV tolerance")
        XCTAssertEqual(s(0.5, neutral, 0, neutral), 0, accuracy: 0.0001, "0.5 EV is the cutoff")
        XCTAssertEqual(s(0.375, neutral, 0, neutral), 0.5, accuracy: 0.0001)
        XCTAssertEqual(s(0, SIMD3(1.125, 1, 1), 0, neutral), 1, accuracy: 0.0001, "chroma 0.125 is half of 0.25")
        XCTAssertEqual(s(0, SIMD3(1.25, 1, 1), 0, neutral), 0, accuracy: 0.0001)
        // Both axes at the full-paint edge: Euclidean is about 0.627, not still fully painted.
        XCTAssertEqual(s(0.25, SIMD3(1.125, 1, 1), 0, neutral), 0.627417, accuracy: 0.0001)
        XCTAssertEqual(AutoMaskBrush.filterRadius(brushRadius: 8), 2, accuracy: 0.0001)
        XCTAssertEqual(AutoMaskBrush.filterRadius(brushRadius: 2), 1, accuracy: 0.0001)
        let gray = SIMD3<Double>(0.2, 0.2, 0.2)
        XCTAssertEqual(AutoMaskBrush.chromaticity(gray).x, 1, accuracy: 0.0001)
        XCTAssertEqual(AutoMaskBrush.luminance(SIMD3(0.6, 0.5, 0.4)), 0.2126 * 0.6 + 0.7152 * 0.5 + 0.0722 * 0.4, accuracy: 0.000001)
    }
    func testAutoMaskBrushStopsAtLuminanceEdges() throws {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func solid(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) -> CIImage {
            CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linear)!).cropped(to: rect)
        }
        let extent = CGRect(x: 0, y: 0, width: 80, height: 60)
        let dark = solid(0.03, 0.03, 0.03, extent)
        let vertical = solid(0.6, 0.5, 0.4, CGRect(x: 40, y: 0, width: 40, height: 60)).composited(over: dark)
        XCTAssertEqual(pixel(vertical, 10, 10)[0], 0.03, accuracy: 0.002)
        XCTAssertEqual(pixel(vertical, 50, 10)[0], 0.6, accuracy: 0.002)
        func stroke(_ auto: Bool, points: [MaskPoint]) -> MaskStroke {
            MaskStroke(points: points, radius: 12.0 / 60, feather: 0, flow: 1, density: 1, autoMask: auto)
        }
        let verticalPoints = [MaskPoint(34.0 / 80, 8.0 / 60), MaskPoint(34.0 / 80, 52.0 / 60)]
        let plain = try MaskPipeline.brush([stroke(false, points: verticalPoints)], extent: extent, baseline: vertical)
        let auto = try MaskPipeline.brush([stroke(true, points: verticalPoints)], extent: extent, baseline: vertical)
        XCTAssertGreaterThan(pixel(plain, 43, 30)[0], 0.9, "the plain brush crosses the edge")
        XCTAssertGreaterThan(pixel(auto, 28, 30)[0], 0.9, "painted side \(pixel(auto, 28, 30)[0])")
        XCTAssertLessThan(pixel(auto, 45, 30)[0], 0.2, "spill \(pixel(auto, 45, 30)[0])")
        XCTAssertLessThan(pixel(auto, 70, 30)[0], 0.02)
        let top = solid(0.6, 0.5, 0.4, CGRect(x: 0, y: 30, width: 80, height: 30)).composited(over: dark)
        let horizontalPoints = [MaskPoint(10.0 / 80, 22.0 / 60), MaskPoint(70.0 / 80, 22.0 / 60)]
        let held = try MaskPipeline.brush([stroke(true, points: horizontalPoints)], extent: extent, baseline: top)
        XCTAssertGreaterThan(pixel(held, 40, 18)[0], 0.9, "below the edge \(pixel(held, 40, 18)[0])")
        XCTAssertLessThan(pixel(held, 40, 34)[0], 0.2, "above the edge \(pixel(held, 40, 34)[0])")
        let flat = solid(0.2, 0.2, 0.2, extent)
        let dot = [MaskPoint(0.5, 0.5)]
        let flatPlain = try MaskPipeline.brush([stroke(false, points: dot)], extent: extent, baseline: flat)
        let flatAuto = try MaskPipeline.brush([stroke(true, points: dot)], extent: extent, baseline: flat)
        XCTAssertEqual(pixel(flatPlain, 40, 30)[0], 1, accuracy: 0.02)
        XCTAssertEqual(pixel(flatAuto, 40, 30)[0], pixel(flatPlain, 40, 30)[0], accuracy: 0.02, "a flat area stays like the plain brush")
        XCTAssertLessThan(pixel(flatAuto, 70, 30)[0], 0.02, "the snap does not flood the frame")
        XCTAssertThrowsError(try MaskPipeline.brush([stroke(true, points: dot)], extent: extent))
        var stored = stroke(false, points: dot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        object.removeValue(forKey: "autoMask")
        let legacy = try JSONDecoder().decode(MaskStroke.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.autoMask)
        stored.autoMask = true
        XCTAssertTrue(try JSONDecoder().decode(MaskStroke.self, from: JSONEncoder().encode(stored)).autoMask)
        var component = MaskComponent(tool: .brush)
        XCTAssertFalse(LocalAdjustment(components: [component]).needsBaseline)
        component.strokes = [stored]
        XCTAssertTrue(LocalAdjustment(components: [component]).needsBaseline)
    }
    func testGeometryMatchesRenderingAndInverse() throws {
        let size = CGSize(width: 100, height: 80)
        // A pixel marker verifies the affine transform against actual CI orientation/crop.
        let marker = image(1, size: CGSize(width: 3, height: 3)).transformed(by: CGAffineTransform(translationX: 40, y: 44)).composited(over: image(0))
        for turns in 0...3 { for angle in [-12.0, 0, 9] { for (horizontal, vertical) in [(false, false), (true, false), (false, true), (true, true)] {
            var r = recipe(); r.quarterTurns = turns; r.straightenDegrees = angle; r.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            r.flipHorizontal = horizontal; r.flipVertical = vertical
            let m = MaskGeometry.mapping(size: size, recipe: r)
            let transformed = try ImagePipeline.geometry(marker, recipe: r)
            XCTAssertEqual(transformed.extent.size, m.output)
            let point = CGPoint(x: 41.5, y: 45.5).applying(m.transform)
            XCTAssertGreaterThan(pixel(transformed, Int(point.x), Int(point.y))[0], 0.2, "turns=\(turns), angle=\(angle)")
            let inverse = try XCTUnwrap(MaskGeometry.sourcePoint(CGPoint(x: point.x / m.output.width, y: point.y / m.output.height), size: size, recipe: r))
            XCTAssertEqual(inverse.x, 0.415, accuracy: 0.000001); XCTAssertEqual(inverse.y, 0.56875, accuracy: 0.000001)
        } } }
        XCTAssertNil(MaskGeometry.sourcePoint(CGPoint(x: -0.1, y: 0.5), size: size, recipe: recipe()))
    }
    @MainActor func testRecipePersistenceUndoBackupAndValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        let photo = Photo(id: "mask", rootID: root.id, relativePath: "sample.ARW", identity: Data(), identityKey: "mask-fixture", width: 100, height: 80)
        try catalog.index(photo)
        let model = AppModel(); model.catalog = catalog; model.activeID = photo.id; model.recipe = recipe(); model.canEdit = true; model.dirty = true
        XCTAssertTrue(model.commitRecipe())
        let original = model.recipe!
        var group = LocalAdjustment(components: [MaskComponent(tool: .linear), MaskComponent(tool: .radial, operation: .intersect), MaskComponent(tool: .brush, operation: .subtract), MaskComponent(tool: .color, operation: .add), MaskComponent(tool: .luminance, operation: .intersect)])
        group.components[0].start = MaskPoint(-0.2, 1.3)
        group.components[1].start = MaskPoint(1.2, -0.1)
        group.exposure = 0.5
        let legacy = try JSONEncoder().encode(group)
        XCTAssertNil(try JSONDecoder().decode(LocalAdjustment.self, from: legacy).settings)
        group.settings = LocalDevelopSettings()
        group.settings?.develop.shadows = 32; group.settings?.develop.mixer[2].hue = -20
        group.settings?.develop.grading.highlights.saturation = 30
        group.settings?.temperature = 6800; group.settings?.asShotWhiteBalance = false
        group.refinement = MaskRefinement(edgeRadius: 0.3, blurRadius: 0.1, expansion: -0.2, hardness: 0.4)
        model.undo.groupsByEvent = false; model.undo.beginUndoGrouping()
        model.changeRecipe({ $0.localAdjustments = [group] }, commit: false)
        model.changeRecipe({ $0.localAdjustments[0].exposure = 1 }, commit: false)
        XCTAssertTrue(model.commitRecipe()); model.undo.endUndoGrouping()
        let edited = model.recipe!
        XCTAssertEqual(edited.maskVersion, 2)
        XCTAssertEqual(edited.schemaVersion, 3); XCTAssertEqual(edited.pipelineVersion, original.pipelineVersion)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photo.id)?.recipe)), edited)
        model.undo.undo(); XCTAssertEqual(model.recipe, original)
        model.undo.redo(); XCTAssertEqual(model.recipe, edited)
        let backup = directory.appendingPathComponent("backup.sqlite"); try catalog.backup(to: backup)
        let reopened = try CatalogStore.restore(from: backup, to: directory.appendingPathComponent("restored"))
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(reopened.photo(photo.id)?.recipe)), edited)
        XCTAssertTrue(edited.baseline().localAdjustments.isEmpty)
        XCTAssertTrue(edited.resetForCurrentPipeline().localAdjustments.isEmpty)
        XCTAssertEqual(try edited.pasting(original, options: RecipePasteOptions()).localAdjustments, edited.localAdjustments)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]); data.removeValue(forKey: "localAdjustments")
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: data)))
        var invalid = edited; invalid.localAdjustments[0].components[0].feather = .nan
        XCTAssertThrowsError(try invalid.validate())
        invalid = edited; invalid.maskVersion = 1; XCTAssertThrowsError(try invalid.validate())
        invalid = edited; invalid.localAdjustments[0].settings?.develop.mixer = []; XCTAssertThrowsError(try invalid.validate())
        invalid = edited; invalid.localAdjustments[0].settings?.temperature = .nan; XCTAssertThrowsError(try invalid.validate())
        invalid = edited; invalid.maskVersion = 99; XCTAssertThrowsError(try invalid.validate())
        invalid = edited; invalid.localAdjustments[0].components[4].lower = 0.9; invalid.localAdjustments[0].components[4].upper = 0.1
        XCTAssertThrowsError(try invalid.validate())
    }
    @MainActor func testNativeGestureAndPanelLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "mask-layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "developBasicOpen")
        preferences.set(true, forKey: "maskRefinementOpen")
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        let photo = Photo(id: "canvas", rootID: root.id, relativePath: "synthetic.ARW", identity: Data(), identityKey: "canvas", width: 800, height: 500)
        try catalog.index(photo)
        let size = CGSize(width: 800, height: 500)
        let scene = CIImage(color: CIColor(red: 0.8, green: 0.3, blue: 0.08)).cropped(to: CGRect(x: 280, y: 80, width: 220, height: 260))
            .composited(over: CIImage(color: CIColor(red: 0.12, green: 0.3, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size)))
        let cg = try XCTUnwrap(context.createCGImage(scene, from: scene.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!))
        let model = AppModel(previewRenderer: { request, _, _ in
            let recipe = try XCTUnwrap(request.recipe)
            let image = try ImagePipeline.geometry(try MaskPipeline.apply(scene, groups: recipe.localAdjustments, baseline: scene), recipe: recipe)
            let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
            let output = try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
            return RenderedImage(image: output, fullSize: image.extent.size, orientedSourceSize: size, histogram: nil, elapsed: 0)
        })
        model.catalog = catalog; model.activeID = photo.id; model.activePhoto = photo; model.roots = [root]
        model.recipe = recipe(); model.canEdit = true; model.dirty = true; XCTAssertTrue(model.commitRecipe())
        model.image = cg; model.maskReference = cg; model.orientedSourceSize = size; model.renderedNativeSize = size
        model.editMode = true; model.singleView = true
        model.addMask(.linear)
        XCTAssertEqual(model.selectedMaskComponent?.start, model.selectedMaskComponent?.end, "A new gradient waits for the first drag")
        let host = NSHostingView(rootView: HStack(spacing: 0) { PhotoCanvas(model: model); MaskPanel(model: model).frame(width: 300).background(Theme.panel) }
            .defaultAppStorage(preferences).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func find<T: NSView>(_ view: NSView, type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type: type) }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let canvas = try XCTUnwrap(find(host, type: PhotoMetalCanvas.self).first)
        XCTAssertEqual(canvas.layer?.masksToBounds, true, "Gradient guides must stay inside the canvas, not cover adjacent panels")
        XCTAssertGreaterThan(canvas.bounds.width, 400)
        let displayed = canvas.presentationSize(source: cg, canvas: canvas.drawableSize)
        func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
            let backing = window.backingScaleFactor
            let local = CGPoint(x: (canvas.drawableSize.width / 2 + (point.x - 0.5) * displayed.width) / backing,
                                y: (canvas.drawableSize.height / 2 + (point.y - 0.5) * displayed.height) / backing)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let before = try catalog.editHistory(photoID: photo.id, limit: 100).count
        canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 0.3, y: 0.2)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: 0.7, y: 0.8)))
        XCTAssertEqual(try catalog.editHistory(photoID: photo.id, limit: 100).count, before)
        canvas.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: 0.7, y: 0.8)))
        XCTAssertEqual(try catalog.editHistory(photoID: photo.id, limit: 100).count, before + 1)
        let component = try XCTUnwrap(model.selectedMaskComponent)
        try await Task.sleep(for: .milliseconds(80))
        canvas.mouseMoved(with: try event(.mouseMoved, point: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(canvas.toolTip, "移动选区")
        let rotationHandle = try XCTUnwrap(MaskEditGesture.handles(component, size: size, rotationOffset: 36 * window.backingScaleFactor * size.width / displayed.width).first { $0.action == .rotate })
        canvas.mouseMoved(with: try event(.mouseMoved, point: CGPoint(x: rotationHandle.point.x, y: rotationHandle.point.y)))
        XCTAssertEqual(canvas.toolTip, "旋转选区")
        canvas.mouseMoved(with: try event(.mouseMoved, point: CGPoint(x: 0.05, y: 0.95)))
        XCTAssertNil(canvas.toolTip)

        canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 0.5, y: 0.5)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: 1.15, y: 1.15)))
        canvas.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: 1.15, y: 1.15)))
        let outside = try XCTUnwrap(model.selectedMaskComponent)
        XCTAssertGreaterThan(outside.start.x, 1); XCTAssertGreaterThan(outside.start.y, 1)
        XCTAssertEqual(outside.end.x - outside.start.x, component.end.x - component.start.x, accuracy: 0.001)
        XCTAssertEqual(outside.end.y - outside.start.y, component.end.y - component.start.y, accuracy: 0.001)
        try outside.validate()
        let outsideCenter = CGPoint(x: (outside.start.x + outside.end.x) / 2, y: (outside.start.y + outside.end.y) / 2)
        model.maskPointer(outsideCenter, phase: .down)
        model.maskPointer(CGPoint(x: 0.5, y: 0.5), phase: .up)
        XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).start.x, component.start.x, accuracy: 0.001)
        // Losing focus ends the gesture without treating the old (-1,-1) sentinel as a real location.
        try await Task.sleep(for: .milliseconds(80))
        canvas.mouseDown(with: try event(.leftMouseDown, point: CGPoint(x: 0.5, y: 0.5)))
        let beforeResign = model.selectedMaskComponent
        _ = canvas.resignFirstResponder()
        XCTAssertEqual(model.selectedMaskComponent, beforeResign)
        model.changeMaskComponent { $0 = component }
        // Classic starts at full coverage and fades toward the drag destination.
        XCTAssertEqual(component.start.x, 0.7, accuracy: 0.002); XCTAssertEqual(component.start.y, 0.8, accuracy: 0.002)
        XCTAssertEqual(component.end.x, 0.3, accuracy: 0.002); XCTAssertEqual(component.end.y, 0.2, accuracy: 0.002)
        model.maskPointer(CGPoint(x: 0.5, y: 0.5), phase: .down)
        model.maskPointer(CGPoint(x: 1, y: 1), phase: .up)
        let moved = try XCTUnwrap(model.selectedMaskComponent)
        XCTAssertEqual(moved.end.x - moved.start.x, component.end.x - component.start.x, accuracy: 0.001)
        XCTAssertEqual(moved.end.y - moved.start.y, component.end.y - component.start.y, accuracy: 0.001)
        model.changeMaskComponent { $0 = component }
        let stable = model.recipe
        model.maskPointer(CGPoint(x: 0.05, y: 0.95), phase: .down)
        model.maskPointer(CGPoint(x: 0.15, y: 0.8), phase: .up)
        XCTAssertEqual(model.recipe, stable, "Dragging away from handles must not move a gradient")
        let rotation = try XCTUnwrap(MaskEditGesture.handles(component, size: size).first { $0.action == .rotate })
        XCTAssertEqual(MaskEditGesture.hit(rotation.point, component: component, size: size), .rotate)
        let axisX = (component.end.x - component.start.x) * size.width
        let axisY = (component.end.y - component.start.y) * size.height
        let rodX = (rotation.point.x - component.start.x) * size.width
        let rodY = (rotation.point.y - component.start.y) * size.height
        XCTAssertEqual(axisX * rodY - axisY * rodX, 0, accuracy: 0.001, "Rotation rod follows the gradient axis")
        XCTAssertLessThan(axisX * rodX + axisY * rodY, 0, "Rotation handle extends beyond the fade-out boundary")
        model.maskPointer(rotation.point.cg, phase: .down)
        model.maskPointer(rotation.point.cg, phase: .up)
        XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).start.x, component.start.x, accuracy: 0.001, "Grabbing rotation must not jump")
        XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).start.y, component.start.y, accuracy: 0.001)

        model.maskPointer(CGPoint(x: rotation.point.x, y: rotation.point.y), phase: .down)
        model.maskPointer(CGPoint(x: 0.7, y: 0.5), phase: .up)
        let rotated = try XCTUnwrap(model.selectedMaskComponent)
        XCTAssertEqual(rotated.start.y, rotated.end.y, accuracy: 0.001)
        XCTAssertEqual((rotated.start.x + rotated.end.x) / 2, 0.5, accuracy: 0.001)
        XCTAssertEqual(hypot((rotated.end.x - rotated.start.x) * size.width, (rotated.end.y - rotated.start.y) * size.height), hypot((component.end.x - component.start.x) * size.width, (component.end.y - component.start.y) * size.height), accuracy: 0.01)
        model.changeMaskComponent { $0 = component }
        model.maskPointer(rotation.point.cg, phase: .down)
        model.maskPointer(CGPoint(x: 0.7, y: 0.58), phase: .up, modifiers: .shift)
        let snapped = try XCTUnwrap(model.selectedMaskComponent)
        let snappedAngle = atan2((snapped.end.y - snapped.start.y) * size.height, (snapped.end.x - snapped.start.x) * size.width) * 180 / .pi
        XCTAssertEqual(snappedAngle / 15, (snappedAngle / 15).rounded(), accuracy: 0.0001)
        model.changeMaskComponent { $0 = component }
        model.maskPointer(CGPoint(x: component.start.x, y: component.start.y), phase: .down)
        model.maskPointer(CGPoint(x: 0.8, y: 0.75), phase: .up)
        let resized = try XCTUnwrap(model.selectedMaskComponent)
        XCTAssertEqual(atan2((resized.end.y - resized.start.y) * size.height, (resized.end.x - resized.start.x) * size.width), atan2((component.end.y - component.start.y) * size.height, (component.end.x - component.start.x) * size.width), accuracy: 0.001)
        model.changeMaskComponent { $0 = component }
        model.changeMask { $0.exposure = 0.8 }
        for tool in [MaskTool.radial, .brush, .luminance, .color] {
            model.addMask(tool, operation: .intersect)
            if tool == .radial {
                XCTAssertEqual(pixel(try MaskPipeline.component(XCTUnwrap(model.selectedMaskComponent), extent: scene.extent, baseline: nil), 400, 250)[0], 0, accuracy: 0.001, "A new radial selection waits for drawing")
            }
            if tool == .radial {
                model.maskPointer(CGPoint(x: 0.48, y: 0.5), phase: .down)
                model.maskPointer(CGPoint(x: 0.7, y: 0.8), phase: .up)
                XCTAssertEqual(model.selectedMaskComponent?.start, MaskPoint(0.48, 0.5))
                XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).radiusX, 0.22, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).radiusY, 0.3, accuracy: 0.001)
                model.maskPointer(CGPoint(x: 0.48, y: 0.87), phase: .down)
                model.maskPointer(CGPoint(x: 0.25, y: 0.5), phase: .up)
                XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).angle, 90, accuracy: 0.001)
                model.changeMaskComponent { $0.angle = 0 }
                let originalRadial = try XCTUnwrap(model.selectedMaskComponent)
                model.maskPointer(CGPoint(x: 0.48, y: 0.5), phase: .down)
                model.maskPointer(CGPoint(x: -0.15, y: 1.1), phase: .up)
                XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).start.x, -0.15, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).start.y, 1.1, accuracy: 0.001)
                XCTAssertEqual(model.selectedMaskComponent?.radiusX, originalRadial.radiusX)
                XCTAssertEqual(model.selectedMaskComponent?.radiusY, originalRadial.radiusY)
                model.changeMaskComponent { $0 = originalRadial }

            }
            if tool == .luminance {
                let sampled = pixel(CIImage(cgImage: cg), 160, 100)
                let lightness = PerceptualColor.lab(SIMD3(Double(sampled[0]), Double(sampled[1]), Double(sampled[2]))).x
                model.maskPointer(CGPoint(x: 0.2, y: 0.2), phase: .down)
                XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).lower, max(0, lightness - 0.1), accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(model.selectedMaskComponent).upper, min(1, lightness + 0.1), accuracy: 0.001)
                XCTAssertFalse(model.maskSampling)
            }
            if tool == .color { model.sampleMaskColor(at: MaskPoint(0.45, 0.4)); XCTAssertEqual(model.selectedMaskComponent?.samples.count, 1) }
            if tool == .brush {
                model.maskPointer(CGPoint(x: 0.35, y: 0.3), phase: .down)
                model.maskPointer(CGPoint(x: 0.6, y: 0.55), phase: .drag)
                model.maskPointer(CGPoint(x: 0.6, y: 0.55), phase: .up)
                XCTAssertEqual(model.selectedMaskComponent?.strokes.count, 1)
                XCTAssertFalse(model.brushAutoMask)
                XCTAssertEqual(model.selectedMaskComponent?.strokes.last?.autoMask, false)
                model.maskPointer(CGPoint(x: 0.5, y: 0.4), phase: .down, modifiers: .option)
                model.maskPointer(CGPoint(x: 0.5, y: 0.4), phase: .up, modifiers: .option)
                XCTAssertEqual(model.selectedMaskComponent?.strokes.last?.erase, true)
                model.brushAutoMask = true
                model.maskPointer(CGPoint(x: 0.2, y: 0.2), phase: .down)
                model.maskPointer(CGPoint(x: 0.25, y: 0.25), phase: .up)
                XCTAssertEqual(model.selectedMaskComponent?.strokes.last?.autoMask, true)
                XCTAssertFalse(model.selectedMaskComponent?.strokes.last?.erase ?? true)
                model.brushAutoMask = false
            }
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80))
            if tool == .radial {
                let group = try XCTUnwrap(model.selectedMask)
                let mask = try MaskPipeline.mask(group, extent: scene.extent, baseline: scene)
                let overlay = try MaskPipeline.run("maskOverlay", extent: scene.extent, [mask, CIVector(x: 1, y: 0, z: 0)]).composited(over: scene)
                let adjusted = try MaskPipeline.apply(scene, groups: [group], baseline: scene)
                for (label, result) in [("original", scene), ("overlay", overlay), ("adjusted", adjusted)] {
                    let rendered = try XCTUnwrap(context.createCGImage(result, from: result.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
                    let attachment = XCTAttachment(image: NSImage(cgImage: rendered, size: size))
                    attachment.name = "mask-example-" + label; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
            if tool == .radial, ProcessInfo.processInfo.environment["LRC_MASK_UI_REVIEW"] == "1" {
                window.styleMask = [.titled]
                window.title = "蒙版交互验证 — Phosdeck"
                window.center()
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                canvas.draw()
                print("MASK_UI_REVIEW_READY")
                try await Task.sleep(for: .seconds(90))
                window.orderOut(nil)
            }
            let sliders = find(host, type: AdjustmentNSSlider.self)
            for label in ["扩张收缩", "边缘吸附", "整体柔化", "边界硬度"] {
                XCTAssertTrue(sliders.contains { $0.accessibilityLabel() == label })
            }
            if tool == .radial {
                let refinement = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "边缘吸附" })
                let historyBefore = try catalog.editHistory(photoID: photo.id).count
                refinement.doubleValue = 40; refinement.sendAction(refinement.action, to: refinement.target)
                XCTAssertEqual(try XCTUnwrap(model.selectedMask?.refinement?.edgeRadius), 0.4, accuracy: 0.000001)
                XCTAssertEqual(try catalog.editHistory(photoID: photo.id).count, historyBefore + 1, "A native control action saves once")
                XCTAssertTrue(model.commitRecipe())
                XCTAssertEqual(try catalog.editHistory(photoID: photo.id).count, historyBefore + 1, "A clean commit creates no duplicate history")
                XCTAssertTrue(model.showMaskOverlay)
                model.changeMask { $0.refinement = nil }
            }
            XCTAssertTrue(sliders.contains { $0.accessibilityLabel() == "曝光度" }, "Tool controls and full local adjustments are visible together")
            XCTAssertFalse(sliders.contains { $0.accessibilityLabel() == "中心 X" || $0.accessibilityLabel() == "起点 X" }, "Coordinates stay collapsed; users draw the region directly")
            if tool == .radial { XCTAssertEqual(try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "羽化" }).doubleValue, 70, accuracy: 0.1) }
            if tool == .color {
                XCTAssertEqual(try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "相近颜色" }).doubleValue, 50, accuracy: 0.1)
                XCTAssertNil(sliders.first { $0.accessibilityLabel() == "颜色过渡" })
            }
            if tool == .brush {
                model.brushAutoMask = true
                XCTAssertTrue(model.maskInstruction.contains("自动蒙版"))
                model.brushAutoMask = false
                XCTAssertFalse(model.maskInstruction.contains("自动蒙版"))
            }
            XCTAssertEqual(host.bounds.width, 1100, accuracy: 1)
            if tool == .radial || tool == .color {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "mask-panel-\(tool.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertEqual(model.selectedMask?.components.count, 5)
        XCTAssertFalse(model.maskDrawNew, "Color sample pins do not wait for a gradient drag")
        model.maskPointer(CGPoint(x: 0.45, y: 0.4), phase: .down)
        XCTAssertEqual(model.selectedMaskComponent?.samples.count, 1, "A normal color click replaces the sample")
        model.maskPointer(CGPoint(x: 0.2, y: 0.2), phase: .down, modifiers: .shift)
        XCTAssertEqual(model.selectedMaskComponent?.samples.count, 2)
        model.maskPointer(CGPoint(x: 0.9, y: 0.9), phase: .down, modifiers: .option)
        XCTAssertEqual(model.selectedMaskComponent?.samples.count, 2, "Option removes a sample only when clicking its pin")
        model.maskPointer(CGPoint(x: 0.2, y: 0.2), phase: .down, modifiers: .option)
        XCTAssertEqual(model.selectedMaskComponent?.samples.count, 1)
        XCTAssertFalse(model.maskSampling, "Picking a color ends normal sampling so a stray click cannot replace it")
        let sampled = model.recipe
        model.maskPointer(CGPoint(x: 0.8, y: 0.8), phase: .down)
        XCTAssertEqual(model.recipe, sampled)
        model.maskSampling = true; model.maskSampleAppending = true
        model.maskPointer(CGPoint(x: 0.8, y: 0.8), phase: .down)
        XCTAssertEqual(model.selectedMaskComponent?.samples.count, 2, "Append button preserves the existing sample without Shift")
        XCTAssertFalse(model.maskSampling); XCTAssertFalse(model.maskSampleAppending)
        model.changeMaskComponent { $0.samples.removeLast() }
        let beforePreview = model.recipe
        model.maskOverlayStyle = .monochrome
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try XCTUnwrap(canvas.maskEditing).style, .monochrome)
        model.maskOverlayStyle = .onWhite
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(try XCTUnwrap(canvas.maskEditing).style, .onWhite)
        model.maskOverlayStyle = .color
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.recipe, beforePreview, "Preview controls must not change saved edits")
        let beforeToggle = try XCTUnwrap(model.recipe)
        let selectedComponent = model.selectedComponentID
        let target = try XCTUnwrap(model.selectedMaskID)
        model.toggleMaskAdjustment(target)
        var disabled = beforeToggle; disabled.localAdjustments[0].enabled = false
        XCTAssertEqual(model.recipe, disabled, "Only this mask's enabled flag changes")
        XCTAssertEqual(model.selectedComponentID, selectedComponent, "Toggling keeps the active tool selected")
        model.toggleMaskAdjustment(target)
        XCTAssertEqual(model.recipe, beforeToggle, "Re-enabling restores every parameter and component")
        let global = try XCTUnwrap(model.recipe)
        let selection = model.selectedComponentID
        model.changeLocalDevelop {
            $0.develop.shadows = 40; $0.develop.texture = 25
            $0.develop.mixer[0].hue = 20; $0.develop.grading.midtones.saturation = 30
            $0.temperature = 7000; $0.asShotWhiteBalance = false
        }
        XCTAssertEqual(model.recipe?.develop, global.develop)
        XCTAssertEqual(model.recipe?.temperature, global.temperature)
        XCTAssertEqual(model.selectedComponentID, selection, "Adjusting color does not leave the selected tool")
        XCTAssertFalse(model.showMaskOverlay)
        XCTAssertEqual(model.selectedMask?.settings?.develop.shadows, 40)
        model.maskPointer(CGPoint(x: 0.2, y: 0.2), phase: .down, modifiers: .shift)
        XCTAssertEqual(model.selectedMaskComponent?.samples.count, 2, "The selection remains directly editable after adjusting color")
        XCTAssertTrue(model.showMaskOverlay)
        let unchanged = model.recipe
        model.maskChoosingTool = true
        model.maskPointer(CGPoint(x: 0.2, y: 0.2), phase: .down)
        XCTAssertEqual(model.recipe, unchanged, "Opening the tool chooser must not edit the current mask")
        model.maskChoosingTool = false
        let groupID = try XCTUnwrap(model.selectedMaskID)
        model.selectMask(groupID, component: nil)
        XCTAssertNil(model.selectedMaskComponent, "Selecting a parent edits its adjustments, not an arbitrary component")
        XCTAssertEqual(model.recipe, unchanged)
        model.selectMask(groupID, component: model.selectedMask?.components.last?.id)
        model.duplicateMask(); XCTAssertEqual(model.recipe?.localAdjustments.count, 2)
        model.deleteMaskComponent(); XCTAssertEqual(model.selectedMask?.components.count, 4)
        model.deleteMask(); XCTAssertEqual(model.recipe?.localAdjustments.count, 1)
        XCTAssertNil(model.error)
    }

}
