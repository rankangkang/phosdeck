import XCTest
import AppKit
import CoreImage
import Darwin
@testable import Phosdeck

/// Quality evidence is measured, never converted into a product acceptance threshold.
final class PatchMatchPrototypeTests: XCTestCase {
    struct SavedOperation: Codable {
        var parameters: PatchMatchPrototype.Parameters
        var width: Int
        var height: Int
        var hole: [Bool]
    }
    struct Fixture {
        var clean: SpotBuffer
        var dirty: SpotBuffer
        var hole: [Bool]
    }
    static func fixture(_ name: String, width: Int = 128) -> Fixture {
        let height = width * 3 / 4
        var pixels = [SIMD3<Float>]()
        var mask = [Bool]()
        for y in 0..<height { for x in 0..<width {
            let u = Float(x) / Float(width), v = Float(y) / Float(height)
            let noise = Float((UInt64(x) &* 73856093 ^ UInt64(y) &* 19349663) % 1000) / 1000 * 0.04 - 0.02
            var value = SIMD3<Float>(0.2 + 0.4 * u + noise, 0.3 + 0.3 * v + noise, 0.35 + noise)
            switch name {
            case "stripes":
                let intensity: Float = (x / max(1, width / 24)) % 2 == 0 ? 0.2 : 0.8
                value = SIMD3(repeating: intensity)
            case "brick":
                let row = Int(v * 12), xx = (u * 12 + (row % 2 == 0 ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
                let yy = (v * 12).truncatingRemainder(dividingBy: 1)
                value = xx < 0.1 || yy < 0.14 ? SIMD3(repeating: 0.12) : SIMD3(0.5 + noise, 0.3 + noise, 0.22 + noise)
            case "perspective":
                let phase = (u * (14 + 10 * v)).truncatingRemainder(dividingBy: 1)
                let yy = (v * 14).truncatingRemainder(dividingBy: 1)
                value = phase < 0.12 || yy < 0.14 ? SIMD3(repeating: 0.12) : SIMD3(0.55 + noise, 0.35 + noise, 0.24 + noise)
            case "edge":
                value = u > 0.35 + v * 0.3 ? SIMD3(0.8 + noise, 0.65 + noise, 0.45 + noise) : SIMD3(0.15 + noise, 0.3 + noise, 0.35 + noise)
            default: break
            }
            let disc = hypot((u - 0.5) * Float(width), (v - 0.5) * Float(height)) < Float(width) * 0.065
            let wire = abs(u - (0.47 + 0.07 * v)) < 0.012 && v > 0.18 && v < 0.82
            pixels.append(value); mask.append(name == "wire" ? wire : disc)
        } }
        let clean = SpotBuffer(width: width, height: height, pixels: pixels)
        var dirty = clean
        for i in mask.indices where mask[i] { dirty.pixels[i] = SIMD3(0.03, 0.01, 0.02) }
        return Fixture(clean: clean, dirty: dirty, hole: mask)
    }
    static func rmse(_ a: SpotBuffer, _ b: SpotBuffer, mask: [Bool]) -> Double {
        var error = 0.0, count = 0.0
        for i in mask.indices where mask[i] {
            let d = a.pixels[i] - b.pixels[i]
            error += Double(d.x * d.x + d.y * d.y + d.z * d.z); count += 3
        }
        return count == 0 ? 0 : sqrt(error / count)
    }
    /// One physical synthetic source for scale comparisons; no independently rasterized patterns.
    static func reduced(_ f: Fixture, edge: Int) -> Fixture {
        let clean = SpotRepairMath.fitted(f.clean, longEdge: edge), dirty = SpotRepairMath.fitted(f.dirty, longEdge: edge)
        var mask = [Bool](repeating: false, count: clean.width * clean.height)
        for y in 0..<clean.height { for x in 0..<clean.width {
            let x0 = x * f.clean.width / clean.width, x1 = max(x0 + 1, (x + 1) * f.clean.width / clean.width)
            let y0 = y * f.clean.height / clean.height, y1 = max(y0 + 1, (y + 1) * f.clean.height / clean.height)
            for yy in y0..<y1 { for xx in x0..<x1 where f.hole[yy * f.clean.width + xx] { mask[y * clean.width + x] = true } }
        } }
        return Fixture(clean: clean, dirty: dirty, hole: mask)
    }
    func testCandidateDeterminismSourceProtectionAndRejection() throws {
        let fixture = Self.fixture("texture", width: 96)
        let parameters = PatchMatchPrototype.Parameters()
        let operation = SavedOperation(parameters: parameters, width: fixture.dirty.width, height: fixture.dirty.height, hole: fixture.hole)
        let encoded = try JSONEncoder().encode(operation)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try encoded.write(to: file)
        let restored = try JSONDecoder().decode(SavedOperation.self, from: Data(contentsOf: file))
        XCTAssertEqual(restored.width, fixture.dirty.width); XCTAssertEqual(restored.height, fixture.dirty.height)
        let output = try XCTUnwrap(PatchMatchPrototype.complete(fixture.dirty, hole: fixture.hole, parameters: parameters))
        let reopened = try XCTUnwrap(PatchMatchPrototype.complete(fixture.dirty, hole: restored.hole, parameters: restored.parameters))
        XCTAssertEqual(output, reopened, "Same source, mask, solver version, scale and seed reproduce every float after save/reopen")
        for i in fixture.hole.indices where !fixture.hole[i] { XCTAssertEqual(output.pixels[i], fixture.dirty.pixels[i]) }
        XCTAssertLessThan(Self.rmse(output, fixture.clean, mask: fixture.hole), 0.06, "Small smooth texture reference check from upstream, not a product gate")
        XCTAssertEqual(try PatchMatchPrototype.complete(fixture.clean, hole: Array(repeating: false, count: fixture.hole.count)), fixture.clean)
        XCTAssertNil(try PatchMatchPrototype.complete(fixture.dirty, hole: Array(repeating: true, count: fixture.hole.count)))
        XCTAssertThrowsError(try PatchMatchPrototype.complete(fixture.dirty, hole: []))
        var bad = parameters; bad.version = "unsupported"
        XCTAssertThrowsError(try PatchMatchPrototype.complete(fixture.dirty, hole: fixture.hole, parameters: bad))
        bad = parameters; bad.patchRadius = 100000
        XCTAssertThrowsError(try PatchMatchPrototype.complete(fixture.dirty, hole: fixture.hole, parameters: bad))
        var calls = 0
        XCTAssertThrowsError(try PatchMatchPrototype.complete(fixture.dirty, hole: fixture.hole, cancelled: { calls += 1; return calls > 40 })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(fixture.dirty, Self.fixture("texture", width: 96).dirty, "Cancellation has no source or catalog writes")
    }
    @MainActor func testWorkerCancellationDoesNotBlockTheUIExecutor() async throws {
        let fixture = Self.fixture("brick", width: 512)
        let worker = Task.detached(priority: .userInitiated) { try PatchMatchPrototype.complete(fixture.dirty, hole: fixture.hole) }
        let start = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(20))
        let heartbeat = start.duration(to: .now)
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled solver must not publish an image") }
        catch { XCTAssertTrue(error is CancellationError) }
        print("PATCHMATCH cancellation mainActorHeartbeat=\(heartbeat) total=\(start.duration(to: .now))")
    }
    func testQualityScaleAndResourceEvidence() throws {
        var evidence: [[String: Any]] = []
        for name in ["texture", "wire", "stripes", "brick", "perspective", "edge"] {
            let f = Self.fixture(name)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            let beforePeak = usage.ru_maxrss
            let started = ContinuousClock.now
            let output = try XCTUnwrap(PatchMatchPrototype.complete(f.dirty, hole: f.hole))
            let duration = started.duration(to: .now)
            getrusage(RUSAGE_SELF, &usage)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            let row: [String: Any] = ["scene": name, "width": f.clean.width, "height": f.clean.height, "maskedPixels": f.hole.filter { $0 }.count,
                                      "beforeRMSE": Self.rmse(f.dirty, f.clean, mask: f.hole), "afterRMSE": Self.rmse(output, f.clean, mask: f.hole),
                                      "seconds": seconds, "processPeakBytes": usage.ru_maxrss, "peakIncreaseBytes": max(0, usage.ru_maxrss - beforePeak)]
            evidence.append(row)
            XCTAssertTrue(output.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            for i in f.hole.indices where !f.hole[i] { XCTAssertEqual(output.pixels[i], f.dirty.pixels[i]) }
            try attach([f.clean, f.dirty, output], name: "patchmatch-\(name)-clean-dirty-filled")
        }
        // Different render resolutions are intentionally measured before choosing the shipping contract.
        let high = Self.fixture("perspective", width: 512)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let priorPeak = usage.ru_maxrss
        let start = ContinuousClock.now
        let highOut = try XCTUnwrap(PatchMatchPrototype.complete(high.dirty, hole: high.hole))
        let highSeconds = start.duration(to: .now)
        getrusage(RUSAGE_SELF, &usage)
        evidence.append(["scene": "perspective-512", "width": 512, "height": 384, "maskedPixels": high.hole.filter { $0 }.count,
                         "afterRMSE": Self.rmse(highOut, high.clean, mask: high.hole), "duration": "\(highSeconds)",
                         "processPeakBytes": usage.ru_maxrss, "peakIncreaseBytes": max(0, usage.ru_maxrss - priorPeak)])
        try attach([high.clean, high.dirty, highOut], name: "patchmatch-perspective-512-clean-dirty-filled")
        for width in [128, 256] {
            let f = Self.reduced(high, edge: width)
            let started = ContinuousClock.now
            let own = try XCTUnwrap(PatchMatchPrototype.complete(f.dirty, hole: f.hole))
            let duration = started.duration(to: .now)
            getrusage(RUSAGE_SELF, &usage)
            let reduced = SpotRepairMath.fitted(highOut, longEdge: width)
            evidence.append(["scene": "scale-perspective", "width": width, "independentVs512DownsampleRMSE": Self.rmse(own, reduced, mask: f.hole),
                             "ownVsTruthRMSE": Self.rmse(own, f.clean, mask: f.hole), "fixed512VsTruthRMSE": Self.rmse(reduced, f.clean, mask: f.hole),
                             "canonical512Duration": "\(highSeconds)", "independentDuration": "\(duration)", "processPeakBytes": usage.ru_maxrss])
            try attach([f.clean, own, reduced], name: "patchmatch-scale-\(width)-clean-own-fixed512")
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "patchmatch-prototype-metrics"; attachment.lifetime = .keepAlways; add(attachment)
        print("PATCHMATCH evidence=" + String(decoding: data, as: UTF8.self))
    }
    private func attach(_ images: [SpotBuffer], name: String) throws {
        let width = images[0].width, height = images[0].height
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * images.count, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
                                               hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * images.count * 3, bitsPerPixel: 24))
        let bytes = try XCTUnwrap(rep.bitmapData)
        for (column, image) in images.enumerated() { for y in 0..<height { for x in 0..<width {
            let pixel = image.get(x, y), index = (height - 1 - y) * rep.bytesPerRow + (column * width + x) * 3
            for c in 0..<3 { let v = max(0, min(1, pixel[c])); let encoded = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055; bytes[index + c] = UInt8((encoded * 255).rounded()) }
        } } }
        let attachment = XCTAttachment(data: try XCTUnwrap(rep.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
