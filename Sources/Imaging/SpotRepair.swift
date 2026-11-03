import CoreGraphics
import Foundation
import CoreImage

/// Clone, heal, and ring-search removal. Parameters only; pixels are recomputed
/// on the current linear decode. The heal and the ring search follow lightcraft
/// `spots.rs` at commit 5436951. Radius and feather match our brush: short-edge
/// fraction, hard core `radius * (1 - feather)`, smoothstep to the outer edge.
/// Attribution: docs/references/lightcraft-LICENSE.txt.
enum SpotRepairMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case clone, heal, remove
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clone: return L10n.text("app.clone", defaultValue: "Clone")
        case .heal: return L10n.text("app.heal", defaultValue: "Heal")
        case .remove: return L10n.text("app.remove", defaultValue: "Remove")
        }
    }
}

struct SpotRepair: Codable, Equatable, Identifiable {
    var id = UUID()
    var enabled = true
    var mode = SpotRepairMode.heal
    var points: [MaskPoint] = []
    /// Fraction of the oriented image's short edge.
    var radius = 0.04
    var feather = 0.7
    var opacity = 1.0
    /// Normalized offset from each target point. Nil asks the renderer to pick a source.
    var sourceOffset: MaskPoint?
    func validate() throws {
        guard !points.isEmpty, points.count <= 4096, points.allSatisfy(\.valid),
              radius.isFinite, (0.001...1).contains(radius),
              feather.isFinite, (0...1).contains(feather),
              opacity.isFinite, (0...1).contains(opacity) else { throw LRCError(L10n.text("app.invalidSpotRemovalParameters", defaultValue: "Invalid spot removal parameters")) }
        if let offset = sourceOffset {
            guard offset.x.isFinite, offset.y.isFinite, (-2...2).contains(offset.x), (-2...2).contains(offset.y) else { throw LRCError(L10n.text("app.invalidSpotSourcePosition", defaultValue: "Invalid spot source position")) }
        }
    }
    static func cacheToken(_ repairs: [SpotRepair]) -> String {
        guard !repairs.isEmpty else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(repairs) else { return "" }
        return data.base64EncodedString()
    }
}

/// Bottom-left, y-up straight linear RGB with separate coverage. Nil alpha means
/// fully opaque. Repairs edit color while preserving the target's coverage.
struct SpotBuffer: Sendable, Equatable {
    var width: Int
    var height: Int
    var pixels: [SIMD3<Float>]
    var alpha: [Float]?
    init(width: Int, height: Int, pixels: [SIMD3<Float>], alpha: [Float]? = nil) {
        self.width = width; self.height = height; self.pixels = pixels
        self.alpha = alpha
    }
    func get(_ x: Int, _ y: Int) -> SIMD3<Float> {
        guard width > 0, height > 0 else { return .zero }
        let xx = min(width - 1, max(0, x)), yy = min(height - 1, max(0, y))
        return pixels[yy * width + xx]
    }
    mutating func set(_ x: Int, _ y: Int, _ value: SIMD3<Float>) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = value
    }
    func sample(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let tx = x - Float(x0), ty = y - Float(y0)
        let a = get(x0, y0), b = get(x0 + 1, y0), c = get(x0, y0 + 1), d = get(x0 + 1, y0 + 1)
        if alpha != nil {
            let aa = coverage(x0,y0), ab = coverage(x0+1,y0), ac = coverage(x0,y0+1), ad = coverage(x0+1,y0+1)
            let mass = sampleCoverage(x,y)
            guard mass > 0 else { return .zero }
            return (a*aa*(1-tx)*(1-ty) + b*ab*tx*(1-ty) + c*ac*(1-tx)*ty + d*ad*tx*ty) / mass
        }
        return a + (b - a) * tx + (c - a) * ty + (a - b - c + d) * tx * ty
    }
    func coverage(_ x: Int, _ y: Int) -> Float {
        guard let alpha else { return 1 }
        return alpha[min(height-1,max(0,y))*width + min(width-1,max(0,x))]
    }
    func sampleCoverage(_ x: Float, _ y: Float) -> Float {
        guard alpha != nil else { return 1 }
        let x0 = Int(floor(x)), y0 = Int(floor(y)), tx = x-Float(x0), ty = y-Float(y0)
        return coverage(x0,y0)*(1-tx)*(1-ty) + coverage(x0+1,y0)*tx*(1-ty)
            + coverage(x0,y0+1)*(1-tx)*ty + coverage(x0+1,y0+1)*tx*ty
    }
    func inside(_ x: Float, _ y: Float) -> Bool {
        x >= 0 && y >= 0 && x < Float(width) && y < Float(height)
    }
}

enum SpotRepairMath {
    static let rankEdge = 512
    struct Rendered {
        var buffer: SpotBuffer
        var offsets: [UUID: MaskPoint]
    }
    /// Repairs in list order. A nil offset is chosen on a long-edge-512 copy, then
    /// applied at this buffer's own size. Later repairs see earlier ones.
    static func render(_ source: SpotBuffer, repairs: [SpotRepair]) -> Rendered {
        render(source, repairs: repairs, captureBefore: nil).rendered
    }
    /// `checkpoint` is the image just before repair `captureBefore`, so a later drag can
    /// reapply only that repair and the ones after it.
    static func render(_ source: SpotBuffer, repairs: [SpotRepair], captureBefore index: Int?) -> (rendered: Rendered, checkpoint: (buffer: SpotBuffer, offsets: [UUID: MaskPoint])?) {
        let active = repairs.filter { $0.enabled && !$0.points.isEmpty && $0.opacity > 0 }
        guard !active.isEmpty else { return (Rendered(buffer: source, offsets: [:]), nil) }
        var full = source
        var rank = fitted(source, longEdge: rankEdge)
        let sameGrid = rank.width == full.width && rank.height == full.height
        var offsets: [UUID: MaskPoint] = [:]
        var checkpoint: (buffer: SpotBuffer, offsets: [UUID: MaskPoint])?
        for (step, repair) in active.enumerated() {
            if step == index { checkpoint = (full, offsets) }
            let offset = repair.sourceOffset ?? pickOffset(in: rank, repair: repair)
            offsets[repair.id] = offset
            apply(repair, offset: offset, to: &full)
            if sameGrid { rank = full } else { apply(repair, offset: offset, to: &rank) }
        }
        return (Rendered(buffer: full, offsets: offsets), checkpoint)
    }
    /// Repairs that already have a source. Nil when one of them still needs an automatic pick.
    static func renderPinned(from source: SpotBuffer, repairs: [SpotRepair]) -> Rendered? {
        let active = repairs.filter { $0.enabled && !$0.points.isEmpty && $0.opacity > 0 }
        guard active.allSatisfy({ $0.sourceOffset != nil }) else { return nil }
        var image = source
        var offsets: [UUID: MaskPoint] = [:]
        for repair in active {
            let offset = repair.sourceOffset!
            offsets[repair.id] = offset
            apply(repair, offset: offset, to: &image)
        }
        return Rendered(buffer: image, offsets: offsets)
    }
    /// Same as `render`, but the rank image is the buffer itself when it is already small.
    /// Kept as one path: `render` always maintains a rank copy so a later auto source
    /// sees earlier repairs. When the buffer is already the rank size, the two copies
    /// still both update.
    static func guides(_ source: SpotBuffer, repairs: [SpotRepair]) -> [UUID: MaskPoint] {
        render(source, repairs: repairs).offsets
    }
    static func pickOffset(in image: SpotBuffer, repair: SpotRepair) -> MaskPoint {
        guard let first = repair.points.first, image.width > 0, image.height > 0 else { return MaskPoint(0, 0) }
        let radius = Float(max(1, repair.radius * Double(min(image.width, image.height))))
        let target = (Float(first.x) * Float(image.width), Float(first.y) * Float(image.height))
        let pixel = rankedSources(image, target: target, radius: radius).first ?? (radius * 2.5, 0)
        return MaskPoint(Double(pixel.0) / Double(image.width), Double(pixel.1) / Double(image.height))
    }
    /// Interaction borrowed from lightcraft 4f0b110 `spots::pick_source`.
    /// Native coordinates stay pre-crop; reject uncovered sources across the entire stroke.
    static func alternateSource(in source: SpotBuffer, repairs: [SpotRepair], selected id: UUID, avoiding current: MaskPoint?) throws -> MaskPoint? {
        guard let index = repairs.firstIndex(where: { $0.id == id }), let first = repairs[index].points.first else { return nil }
        try Task.checkCancellation()
        var image = source
        for prior in repairs.prefix(index) {
            try Task.checkCancellation()
            image = render(image, repairs: [prior]).buffer
        }
        let repair = repairs[index], w = Float(image.width), h = Float(image.height)
        guard w > 0, h > 0 else { return nil }
        let radius = Float(max(1, repair.radius * Double(min(image.width, image.height))))
        let target = (Float(first.x) * w, Float(first.y) * h)
        let old = current ?? pickOffset(in: image, repair: repair)
        for delta in rankedSources(image, target: target, radius: radius) {
            try Task.checkCancellation()
            guard hypot(delta.0 - Float(old.x) * w, delta.1 - Float(old.y) * h) > radius else { continue }
            let offset = MaskPoint(Double(delta.0 / w), Double(delta.1 / h))
            if sourceCoversStroke(image, repair: repair, offset: offset, radius: radius) { return offset }
        }
        try Task.checkCancellation()
        return nil
    }
    private static func sourceCoversStroke(_ image: SpotBuffer, repair: SpotRepair, offset: MaskPoint, radius: Float) -> Bool {
        for point in dabs(repair, width: image.width, height: image.height, radius: Double(radius)) {
            if Task.isCancelled { return false }
            let x = Float(point.x) + Float(offset.x) * Float(image.width)
            let y = Float(point.y) + Float(offset.y) * Float(image.height)
            guard image.inside(x-radius, y-radius), image.inside(x+radius, y+radius) else { return false }
            if image.alpha == nil { continue }
            // Cover the complete disc, including transparent holes inside its annulus.
            for yy in Int(floor(y-radius))...Int(ceil(y+radius)) {
                if Task.isCancelled { return false }
                for xx in Int(floor(x-radius))...Int(ceil(x+radius)) {
                    if hypot(Float(xx)-x, Float(yy)-y) <= radius, image.coverage(xx, yy) < 0.99 { return false }
                }
            }
        }
        return true
    }
    static func fitted(_ image: SpotBuffer, longEdge: Int) -> SpotBuffer {
        let long = max(image.width, image.height)
        guard long > longEdge, longEdge > 0, image.width > 0, image.height > 0 else { return image }
        let scale = Double(longEdge) / Double(long)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height)
        var alpha = image.alpha.map { _ in [Float](repeating: 0, count: width * height) }
        for y in 0..<height {
            let y0 = min(image.height - 1, Int(Double(y) / Double(height) * Double(image.height)))
            let y1 = min(image.height, max(y0 + 1, Int(Double(y + 1) / Double(height) * Double(image.height))))
            for x in 0..<width {
                let x0 = min(image.width - 1, Int(Double(x) / Double(width) * Double(image.width)))
                let x1 = min(image.width, max(x0 + 1, Int(Double(x + 1) / Double(width) * Double(image.width))))
                var sum = SIMD3<Float>.zero
                var count = 0
                var mass: Float = 0
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let weight = image.coverage(xx,yy)
                        sum += image.pixels[yy * image.width + xx] * weight
                        mass += weight
                        count += 1
                    }
                }
                pixels[y * width + x] = mass > 0 ? sum / mass : .zero
                alpha?[y * width + x] = count > 0 ? mass / Float(count) : 0
            }
        }
        return SpotBuffer(width: width, height: height, pixels: pixels, alpha: alpha)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        if edge1 <= edge0 { return x < edge0 ? 0 : 1 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
    private static func dabs(_ repair: SpotRepair, width: Int, height: Int, radius: Double) -> [SIMD2<Double>] {
        let points = repair.points.map { SIMD2($0.x * Double(width), $0.y * Double(height)) }
        guard let first = points.first else { return [] }
        var result = [first]
        let spacing = max(0.25, radius * 0.2)
        var remaining = spacing
        for (a, b) in zip(points, points.dropFirst()) {
            let distance = (b - a).length
            if distance <= 0 { continue }
            var offset = remaining
            while offset <= distance {
                result.append(a + (b - a) * (offset / distance))
                offset += spacing
            }
            remaining = offset - distance
        }
        return result
    }
    private static func apply(_ repair: SpotRepair, offset: MaskPoint, to image: inout SpotBuffer) {
        let width = image.width, height = image.height
        guard width > 1, height > 1 else { return }
        let radius = max(1, repair.radius * Double(min(width, height)))
        let stamps = dabs(repair, width: width, height: height, radius: radius)
        guard !stamps.isEmpty else { return }
        let sigma = max(1, radius * 0.6)
        let reach = radius + max(radius, sigma * 3)
        var minX = width, minY = height, maxX = 0, maxY = 0
        for dab in stamps {
            minX = min(minX, Int(floor(dab.x - reach)))
            minY = min(minY, Int(floor(dab.y - reach)))
            maxX = max(maxX, Int(ceil(dab.x + reach)))
            maxY = max(maxY, Int(ceil(dab.y + reach)))
        }
        minX = max(0, minX); minY = max(0, minY); maxX = min(width, maxX); maxY = min(height, maxY)
        let boxW = maxX - minX, boxH = maxY - minY
        guard boxW > 0, boxH > 0 else { return }
        var alpha = [Float](repeating: 0, count: boxW * boxH)
        let hard = radius * (1 - min(1, max(0, repair.feather)))
        for dab in stamps {
            let x0 = max(minX, Int(floor(dab.x - radius))), x1 = min(maxX, Int(ceil(dab.x + radius)))
            let y0 = max(minY, Int(floor(dab.y - radius))), y1 = min(maxY, Int(ceil(dab.y + radius)))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let distance = hypot(Double(x) + 0.5 - dab.x, Double(y) + 0.5 - dab.y)
                    if distance > radius { continue }
                    let coverage = Float((1 - smoothstep(hard, radius, distance)) * repair.opacity)
                    let index = (y - minY) * boxW + (x - minX)
                    if coverage > alpha[index] { alpha[index] = coverage }
                }
            }
        }
        guard alpha.contains(where: { $0 > 0 }) else { return }
        let shift = SIMD2(Float(offset.x * Double(width)), Float(offset.y * Double(height)))
        var source = [SIMD3<Float>](repeating: .zero, count: boxW * boxH)
        var target = [SIMD3<Float>](repeating: .zero, count: boxW * boxH)
        var sourceCoverage = [Float](repeating: 1, count: boxW * boxH)
        var confidence = sourceCoverage
        for y in 0..<boxH {
            for x in 0..<boxW {
                let px = Float(minX + x) + 0.5, py = Float(minY + y) + 0.5
                let index = y * boxW + x
                source[index] = image.sample(px + shift.x, py + shift.y)
                target[index] = image.get(minX + x, minY + y)
                sourceCoverage[index] = image.sampleCoverage(px + shift.x,py + shift.y)
                confidence[index] = sourceCoverage[index] * image.coverage(minX+x,minY+y)
            }
        }
        let low: [SIMD3<Float>]? = repair.mode == .clone ? nil : tone(target: target, source: source, alpha: alpha, confidence: confidence, width: boxW, height: boxH, sigma: Float(sigma))
        for y in 0..<boxH {
            for x in 0..<boxW {
                let index = y * boxW + x
                let coverage = alpha[index] * sourceCoverage[index]
                if coverage <= 0 || image.coverage(minX+x,minY+y) <= 0 { continue }
                var value = source[index]
                if let low { value += low[index] }
                let base = target[index]
                let mixed = base + (value - base) * coverage
                image.set(minX + x, minY + y, SIMD3(finite(mixed.x, fallback: base.x), finite(mixed.y, fallback: base.y), finite(mixed.z, fallback: base.z)))
            }
        }
    }
    private static func finite(_ value: Float, fallback: Float) -> Float {
        value.isFinite ? max(0, value) : fallback
    }
    /// Tone from the stroke's surroundings only: blur (target − source) where coverage is still
    /// below 0.02, divide by the blurred weights, and ignore the blemish inside the stroke.
    private static func tone(target: [SIMD3<Float>], source: [SIMD3<Float>], alpha: [Float], confidence: [Float], width: Int, height: Int, sigma: Float) -> [SIMD3<Float>] {
        var diff = [SIMD3<Float>](repeating: .zero, count: width * height)
        var weight = [Float](repeating: 0, count: width * height)
        for index in alpha.indices where alpha[index] < 0.02 {
            diff[index] = (target[index] - source[index]) * confidence[index]
            weight[index] = confidence[index]
        }
        diff = gaussian(diff, width: width, height: height, sigma: sigma)
        weight = gaussian(weight, width: width, height: height, sigma: sigma)
        return zip(diff, weight).map { sample, mass in
            let scale = max(mass, 1e-4)
            return sample / scale
        }
    }
    private static func rankedSources(_ image: SpotBuffer, target: (Float, Float), radius: Float) -> [(Float, Float)] {
        var scored: [(Float, (Float, Float))] = []
        for ring in [Float(2.4), 3.2, 4.2] {
            for step in 0..<16 {
                let angle = Float(step) / 16 * 2 * .pi
                let delta = (cos(angle) * radius * ring, sin(angle) * radius * ring)
                let source = (target.0 + delta.0, target.1 + delta.1)
                let value = score(image, target: target, source: source, radius: radius)
                if value < .greatestFiniteMagnitude { scored.append((value, delta)) }
            }
        }
        scored.sort { $0.0 < $1.0 }
        return scored.map(\.1)
    }
    private static func score(_ image: SpotBuffer, target: (Float, Float), source: (Float, Float), radius: Float) -> Float {
        guard let aroundTarget = ring(image, center: target, inner: radius * 1.05, outer: radius * 1.6),
              let aroundSource = ring(image, center: source, inner: radius * 1.05, outer: radius * 1.6) else { return .greatestFiniteMagnitude }
        var total: Float = 0
        for (left, right) in zip(aroundTarget, aroundSource) {
            for channel in 0..<3 {
                let a = sqrt(max(0, left[channel])), b = sqrt(max(0, right[channel]))
                total += (a - b) * (a - b)
            }
        }
        if let inside = ring(image, center: source, inner: radius * 0.2, outer: radius * 0.9) {
            let mean = aroundTarget.reduce(Float(0)) { $0 + sqrt(max(0, $1.y)) } / Float(aroundTarget.count)
            let variance = inside.reduce(Float(0)) { partial, sample in
                let delta = sqrt(max(0, sample.y)) - mean
                return partial + delta * delta
            } / Float(inside.count)
            total += variance * Float(aroundTarget.count) * 0.5
        }
        return total
    }
    private static func ring(_ image: SpotBuffer, center: (Float, Float), inner: Float, outer: Float) -> [SIMD3<Float>]? {
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(72)
        let radii = [inner, (inner + outer) / 2, outer]
        for step in 0..<24 {
            let angle = Float(step) / 24 * 2 * .pi
            for radius in radii {
                let x = center.0 + cos(angle) * radius
                let y = center.1 + sin(angle) * radius
                if !image.inside(x, y) || image.sampleCoverage(x,y) <= 0 { return nil }
                samples.append(image.sample(x, y))
            }
        }
        return samples
    }
    private static func boxRadii(_ sigma: Float) -> [Int] {
        let count: Float = 3
        let ideal = sqrt(12 * sigma * sigma / count + 1)
        var lower = Int(floor(ideal))
        if lower % 2 == 0 { lower -= 1 }
        lower = max(1, lower)
        let upper = lower + 2
        let lowerF = Float(lower)
        let passes = (12 * sigma * sigma - count * lowerF * lowerF - 4 * count * lowerF - 3 * count) / (-4 * lowerF - 4)
        let narrow = Int(passes.rounded())
        return (0..<3).map { index in
            let width = index < narrow ? lower : upper
            return max(0, (width - 1) / 2)
        }
    }
    private static func gaussian(_ source: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        guard sigma > 0.3, width > 0, height > 0 else { return source }
        var image = source
        for radius in boxRadii(sigma) where radius > 0 {
            image = box(image, width: width, height: height, radius: radius)
        }
        return image
    }
    private static func gaussian(_ source: [SIMD3<Float>], width: Int, height: Int, sigma: Float) -> [SIMD3<Float>] {
        let planes = (0..<3).map { channel in source.map { $0[channel] } }
        let blurred = planes.map { gaussian($0, width: width, height: height, sigma: sigma) }
        return (0..<source.count).map { index in SIMD3(blurred[0][index], blurred[1][index], blurred[2][index]) }
    }
    private static func box(_ source: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let scale = 1 / Float(radius * 2 + 1)
        var horizontal = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            var sum: Float = 0
            for index in 0...(radius * 2) {
                sum += source[y * width + min(width - 1, max(0, index - radius))]
            }
            for x in 0..<width {
                horizontal[y * width + x] = sum * scale
                sum += source[y * width + min(width - 1, x + radius + 1)]
                sum -= source[y * width + max(0, x - radius)]
            }
        }
        var vertical = [Float](repeating: 0, count: width * height)
        for x in 0..<width {
            var sum: Float = 0
            for index in 0...(radius * 2) {
                let y = min(height - 1, max(0, index - radius))
                sum += horizontal[y * width + x]
            }
            for y in 0..<height {
                vertical[y * width + x] = sum * scale
                sum += horizontal[min(height - 1, y + radius + 1) * width + x]
                sum -= horizontal[max(0, y - radius) * width + x]
            }
        }
        return vertical
    }
}

enum SpotRepairPipeline {
    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static func apply(_ input: CIImage, repairs: [SpotRepair], context: CIContext) throws -> (image: CIImage, offsets: [UUID: MaskPoint]) {
        let active = repairs.filter { $0.enabled && !$0.points.isEmpty && $0.opacity > 0 }
        guard !active.isEmpty else { return (input, [:]) }
        let base = ImagePipeline.originZero(input)
        let rendered = SpotRepairMath.render(try buffer(base, context: context), repairs: active)
        return (try image(rendered.buffer), rendered.offsets)
    }
    static func buffer(_ image: CIImage, context: CIContext) throws -> SpotBuffer {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width <= 20_000, height <= 20_000 else { throw LRCError(L10n.text("app.invalidHealingImageDimensions", defaultValue: "Invalid healing image dimensions")) }
        var raw = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &raw, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linear)
        var pixels = [SIMD3<Float>](repeating: .zero, count: width * height)
        var alpha = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let source = ((height - 1 - y) * width + x) * 4
                let a = raw[source+3].isFinite ? min(1,max(0,raw[source+3])) : 0
                alpha[y*width+x] = a
                let rgb = a > 0 ? SIMD3(raw[source], raw[source + 1], raw[source + 2]) / a : .zero
                pixels[y * width + x] = SIMD3(rgb.x.isFinite ? rgb.x : 0, rgb.y.isFinite ? rgb.y : 0, rgb.z.isFinite ? rgb.z : 0)
            }
        }
        return SpotBuffer(width: width, height: height, pixels: pixels, alpha: alpha.contains { $0 < 1 } ? alpha : nil)
    }
    static func image(_ buffer: SpotBuffer) throws -> CIImage {
        var raw = [Float](repeating: 0, count: buffer.width * buffer.height * 4)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let pixel = buffer.pixels[y * buffer.width + x]
                let index = ((buffer.height - 1 - y) * buffer.width + x) * 4
                let a = buffer.coverage(x,y)
                raw[index] = pixel.x*a; raw[index + 1] = pixel.y*a; raw[index + 2] = pixel.z*a; raw[index + 3] = a
            }
        }
        let data = raw.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16, size: CGSize(width: buffer.width, height: buffer.height), format: .RGBAf, colorSpace: linear)
    }
}

/// Connector head. The tip is the target rim and the tail is the source rim.
struct SpotArrow {
    var tail: CGPoint
    var tip: CGPoint
    var left: CGPoint
    var right: CGPoint

    static func make(from source: CGPoint, to target: CGPoint, length: CGFloat) -> SpotArrow? {
        let dx = target.x - source.x, dy = target.y - source.y
        let span = hypot(dx, dy)
        guard span > 1, length > 0, length.isFinite else { return nil }
        let ux = dx / span, uy = dy / span
        let head = min(length, span * 0.65)
        let wing = head * 0.55
        let base = CGPoint(x: target.x - ux * head, y: target.y - uy * head)
        return SpotArrow(tail: source, tip: target,
                         left: CGPoint(x: base.x - uy * wing, y: base.y + ux * wing),
                         right: CGPoint(x: base.x + uy * wing, y: base.y - ux * wing))
    }

    func addShaft(to path: CGMutablePath) {
        let base = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        path.move(to: tail)
        path.addLine(to: base)
    }

    func addHead(to path: CGMutablePath) {
        path.move(to: left)
        path.addLine(to: tip)
        path.addLine(to: right)
        path.closeSubpath()
    }
}

/// Outer boundary of the brush area. A drag is the union of the round stroke, and the source uses the same shape shifted by the offset.
struct SpotOutline {
    var loops: [[CGPoint]]

    static func make(points: [CGPoint], radius: CGFloat) -> SpotOutline {
        guard let first = points.first, radius > 0, radius.isFinite else { return SpotOutline(loops: []) }
        let moved = points.contains { hypot($0.x - first.x, $0.y - first.y) > 0.5 }
        if points.count == 1 || !moved { return SpotOutline(loops: [circle(center: first, radius: radius)]) }
        let traced = trace(points, radius: radius)
        return traced.loops.isEmpty ? SpotOutline(loops: [circle(center: first, radius: radius)]) : traced
    }

    func translated(dx: CGFloat, dy: CGFloat) -> SpotOutline {
        SpotOutline(loops: loops.map { loop in loop.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } })
    }

    func cgPath() -> CGPath {
        let path = CGMutablePath()
        for loop in loops where loop.count >= 3 {
            path.move(to: loop[0])
            for point in loop.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        return path
    }

    func contains(_ point: CGPoint) -> Bool {
        loops.reduce(0) { $0 + Self.winding($1, point) } != 0
    }

    /// The open gap along the offset, from where the ray leaves this shape to where it enters the shifted copy.
    func bridge(from origin: CGPoint, dx: CGFloat, dy: CGFloat) -> (CGPoint, CGPoint)? {
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let source = translated(dx: dx, dy: dy)
        func at(_ t: CGFloat) -> CGPoint { CGPoint(x: origin.x + dx * t, y: origin.y + dy * t) }
        let steps = 64
        var exitStep: Int?
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let inTarget = contains(at(t))
            let inSource = source.contains(at(t))
            if inTarget && !inSource { exitStep = step }
            else if inSource && !inTarget, let exitStep {
                let leave = refine(from: exitStep, to: min(steps, exitStep + 1), steps: steps, inside: { self.contains(at($0)) })
                let enter = refine(from: max(0, step - 1), to: step, steps: steps, inside: { !source.contains(at($0)) })
                guard enter > leave else { return nil }
                let gap = hypot(dx * (enter - leave), dy * (enter - leave))
                guard gap > 1.5 else { return nil }
                return (at(leave), at(enter))
            }
        }
        return nil
    }

    /// Line from the outline toward a sample point, stopping short of that point by `clearance`.
    func link(from origin: CGPoint, to end: CGPoint, clearance: CGFloat) -> (CGPoint, CGPoint)? {
        let dx = end.x - origin.x, dy = end.y - origin.y
        let length = hypot(dx, dy)
        guard length > clearance + 1.5 else { return nil }
        func at(_ t: CGFloat) -> CGPoint { CGPoint(x: origin.x + dx * t, y: origin.y + dy * t) }
        let steps = 48
        var insideStep = -1
        var left = false
        if contains(origin) { insideStep = 0 }
        for step in 1...steps {
            if contains(at(CGFloat(step) / CGFloat(steps))) { insideStep = step; continue }
            if insideStep >= 0 { left = true }
            break
        }
        guard left else { return nil }
        var low = CGFloat(insideStep) / CGFloat(steps)
        var high = CGFloat(min(steps, insideStep + 1)) / CGFloat(steps)
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if contains(at(mid)) { low = mid } else { high = mid }
        }
        let stop = (length - clearance) / length
        guard stop > high + 0.002 else { return nil }
        return (at(high), at(stop))
    }

    private func refine(from lower: Int, to upper: Int, steps: Int, inside: (CGFloat) -> Bool) -> CGFloat {
        var low = CGFloat(lower) / CGFloat(steps)
        var high = CGFloat(upper) / CGFloat(steps)
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if inside(mid) { low = mid } else { high = mid }
        }
        return high
    }

    private static func circle(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        (0..<48).map { index in
            let angle = CGFloat(index) * 2 * .pi / 48
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
    }

    private static func trace(_ points: [CGPoint], radius: CGFloat) -> SpotOutline {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for point in points {
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        }
        let margin = radius + 2
        minX -= margin; minY -= margin; maxX += margin; maxY += margin
        let span = max(maxX - minX, maxY - minY, 1)
        var scale = min(4, max(1, 10 / radius))
        if span * scale > 720 { scale = 720 / span }
        let pad = 2
        let width = max(2, Int(ceil((maxX - minX) * scale)) + pad * 2)
        let height = max(2, Int(ceil((maxY - minY) * scale)) + pad * 2)
        guard width <= 800, height <= 800 else { return SpotOutline(loops: []) }
        var mask = [UInt8](repeating: 0, count: width * height)
        mask.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.translateBy(x: CGFloat(pad) - minX * scale, y: CGFloat(pad) - minY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineWidth(radius * 2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: points[0])
            for point in points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
        }
        func solid(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            // Bitmap row 0 is the top of the context. Device y grows upward.
            return mask[(height - 1 - y) * width + x] >= 128
        }
        struct Corner: Hashable { var x: Int; var y: Int }
        var outgoing: [Corner: [Corner]] = [:]
        func link(_ from: Corner, _ to: Corner) { outgoing[from, default: []].append(to) }
        for y in 0..<height {
            for x in 0..<width where solid(x, y) {
                if !solid(x, y - 1) { link(Corner(x: x, y: y), Corner(x: x + 1, y: y)) }
                if !solid(x, y + 1) { link(Corner(x: x + 1, y: y + 1), Corner(x: x, y: y + 1)) }
                if !solid(x - 1, y) { link(Corner(x: x, y: y + 1), Corner(x: x, y: y)) }
                if !solid(x + 1, y) { link(Corner(x: x + 1, y: y), Corner(x: x + 1, y: y + 1)) }
            }
        }
        var loops: [[CGPoint]] = []
        while let start = outgoing.first(where: { !$0.value.isEmpty })?.key {
            var loop = [start]
            var current = start
            var closed = false
            var guardCount = 0
            while guardCount < width * height * 4 {
                guard var ends = outgoing[current], !ends.isEmpty else { break }
                let next = ends.removeLast()
                outgoing[current] = ends
                guardCount += 1
                if next == start { closed = true; break }
                loop.append(next)
                current = next
            }
            guard closed, loop.count >= 3 else { continue }
            var device = loop.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            device.append(device[0])
            var simple = simplify(device, epsilon: 1.6)
            if simple.count >= 2, simple.first == simple.last { simple.removeLast() }
            guard simple.count >= 3 else { continue }
            loops.append(simple.map { CGPoint(x: ($0.x - CGFloat(pad)) / scale + minX, y: ($0.y - CGFloat(pad)) / scale + minY) })
        }
        return SpotOutline(loops: loops)
    }

    private static func simplify(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var farthest = 0
        var distance: CGFloat = 0
        let last = points.count - 1
        for index in 1..<last {
            let candidate = segmentDistance(points[index], points[0], points[last])
            if candidate > distance { distance = candidate; farthest = index }
        }
        if distance > epsilon {
            let left = simplify(Array(points[0...farthest]), epsilon: epsilon)
            let right = simplify(Array(points[farthest...last]), epsilon: epsilon)
            return left.dropLast() + right
        }
        return [points[0], points[last]]
    }

    private static func segmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = dx * dx + dy * dy
        if length < 1e-8 { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
        return hypot(point.x - (start.x + dx * t), point.y - (start.y + dy * t))
    }

    private static func winding(_ loop: [CGPoint], _ point: CGPoint) -> Int {
        guard loop.count >= 3 else { return 0 }
        var sum = 0
        for index in 0..<loop.count {
            let start = loop[index]
            let end = loop[(index + 1) % loop.count]
            let cross = (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
            if start.y <= point.y {
                if end.y > point.y, cross > 0 { sum += 1 }
            } else if end.y <= point.y, cross < 0 {
                sum -= 1
            }
        }
        return sum
    }
}

private extension SIMD2 where Scalar == Double {
    var length: Double { (x * x + y * y).squareRoot() }
}
