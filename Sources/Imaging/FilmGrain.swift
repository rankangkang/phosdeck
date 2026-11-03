import CoreImage
import Foundation

/// Post-crop film grain. Parameter mapping, value-noise hash and the encoded-domain
/// mix follow lightcraft `crates/pipeline/src/finish.rs` (`GRAIN_HASH`, `grain_noise`,
/// and the finish loop) at commit 5436951. Size is relative to the current image's
/// long edge so a preview and an export of the same crop look the same.
/// Attribution: docs/references/lightcraft-LICENSE.txt.
struct FilmGrain: Codable, Equatable {
    var amount = 0.0
    var size = 25.0
    var roughness = 50.0
    var seed: UInt32 = 0
    var isDefault: Bool { self == Self() }
    var isActive: Bool { amount > 0 }
    mutating func ensureSeed() {
        if seed == 0 { seed = UInt32.random(in: 1...UInt32.max) }
    }
    func validate() throws {
        guard [amount, size, roughness].allSatisfy({ $0.isFinite && (0...100).contains($0) })
        else { throw LRCError(L10n.text("app.invalidGrainParameters", defaultValue: "Invalid grain parameters")) }
    }
}

enum FilmGrainMath {
    static let hash: [UInt32] = [0x8da6_b343, 0xd816_3841, 0xcb1a_b31f, 0x5bd1_e995]
    struct Prepared: Equatable {
        var amount: Float
        var cell: Float
        var roughness: Float
        var seed: UInt32
    }
    static func prepared(_ grain: FilmGrain, longEdge: Float) -> Prepared? {
        guard grain.amount > 0, longEdge > 0 else { return nil }
        return Prepared(
            amount: Float(grain.amount / 100) * 0.13,
            cell: max(0.6, (0.0006 + Float(grain.size) / 100 * 0.0024) * longEdge),
            roughness: Float(grain.roughness / 100),
            seed: grain.seed
        )
    }
    static func hashNoise(_ i: Int32, _ j: Int32, seed: UInt32) -> Float {
        var v = UInt32(bitPattern: i) &* hash[0]
        v ^= UInt32(bitPattern: j) &* hash[1]
        v ^= seed &* hash[2]
        v ^= v &>> 13
        v = v &* hash[3]
        v ^= v &>> 15
        return Float(v & 0xffff) / 32768 - 1
    }
    static func noise(_ x: Float, _ y: Float, seed: UInt32) -> Float {
        let x0 = floor(x), y0 = floor(y)
        let fx = x - x0, fy = y - y0
        let i = Int32(x0), j = Int32(y0)
        let u = fx * fx * (3 - 2 * fx)
        let v = fy * fy * (3 - 2 * fy)
        let a0 = hashNoise(i, j, seed: seed)
        let a1 = hashNoise(i &+ 1, j, seed: seed)
        let b0 = hashNoise(i, j &+ 1, seed: seed)
        let b1 = hashNoise(i &+ 1, j &+ 1, seed: seed)
        let a = a0 + (a1 - a0) * u
        let b = b0 + (b1 - b0) * u
        return a + (b - a) * v
    }
    static func encode(_ v: Float) -> Float {
        let x = max(v, 0)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
    static func decode(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow(max((v + 0.055) / 1.055, 0), 2.4)
    }
    static func encode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(encode(c.x), encode(c.y), encode(c.z))
    }
    static func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(decode(c.x), decode(c.y), decode(c.z))
    }
    /// `x`/`y` are pixel centres in the cropped output, origin at the bottom left.
    static func shade(_ c: SIMD3<Float>, x: Float, y: Float, width: Float, height: Float, grain: Prepared) -> SIMD3<Float> {
        let long = max(width, height)
        let gx = x / long, gy = y / long
        let sc = long / grain.cell
        var g = noise(gx * sc, gy * sc, seed: grain.seed)
        g = g * (1 - grain.roughness * 0.5) + noise(gx * sc * 2.3, gy * sc * 2.3, seed: grain.seed ^ 0x55) * grain.roughness * 0.7
        let e = encode(c)
        let lum = 0.2126 * e.x + 0.7152 * e.y + 0.0722 * e.z
        let k = grain.amount * g * (0.35 + 2.6 * lum * (1 - lum))
        return decode(e + SIMD3(repeating: k))
    }
}

enum FilmGrainPipeline {
    private final class Resources {}
    private static let loaded: Result<CIColorKernel, Error> = Result {
        guard let url = Bundle(for: Resources.self).url(forResource: "default", withExtension: "metallib") else {
            throw LRCError(L10n.text("app.theDevelopShaderRequiredForGrainIsMissing", defaultValue: "The develop shader required for grain is missing"))
        }
        return try CIColorKernel(functionName: "filmGrain", fromMetalLibraryData: Data(contentsOf: url), outputPixelFormat: .RGBAf)
    }
    static func apply(_ input: CIImage, _ grain: FilmGrain) throws -> CIImage {
        let extent = input.extent
        let long = Float(max(extent.width, extent.height))
        guard let prepared = FilmGrainMath.prepared(grain, longEdge: long) else { return input }
        guard extent.width > 0, extent.height > 0 else { return input }
        let kernel = try loaded.get()
        guard let image = kernel.apply(extent: extent, arguments: [
            input, CIVector(cgRect: extent),
            CIVector(x: CGFloat(prepared.amount), y: CGFloat(prepared.cell), z: CGFloat(prepared.roughness), w: 0),
            CIVector(x: CGFloat(prepared.seed & 0xffff), y: CGFloat(prepared.seed >> 16), z: 0, w: 0)
        ]) else { throw LRCError(L10n.text("app.grainShaderFailed", defaultValue: "Grain shader failed")) }
        return image
    }
}
