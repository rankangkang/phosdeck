import Foundation
@testable import Phosdeck

/// Experimental candidate, deliberately test-target only until the quality review.
/// Port of lightcraft f34c7a8 crates/inpaint/src/{patchmatch,membrane}.rs, MIT option.
/// Attribution and license: docs/references/lightcraft-LICENSE.txt.
/// Serial 16-row bands retain deterministic propagation and random streams.
/// Coordinates and float linear RGB follow the native SpotBuffer (bottom-left).
enum PatchMatchPrototype {
    struct Parameters: Codable, Equatable, Sendable {
        var version = "patchmatch-prototype-v1"
        var analysisEdge = 512
        var seed: UInt64 = 1
        var patchRadius = 3
        var coarseIterations = 8
        var minimumIterations = 2
        var matchPasses = 2
        var refineExtent = 96
        func validate() throws {
            guard version == "patchmatch-prototype-v1", (64...1024).contains(analysisEdge),
                  (1...5).contains(patchRadius), (1...12).contains(coarseIterations),
                  (1...coarseIterations).contains(minimumIterations), (1...4).contains(matchPasses),
                  (16...192).contains(refineExtent) else { throw LRCError("无效的填补原型参数") }
        }
    }
    struct Point: Equatable {
        var x: Int
        var y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
        static let zero = Point(0, 0)
        static func + (a: Self, b: Self) -> Self { Self(a.x + b.x, a.y + b.y) }
        static func - (a: Self, b: Self) -> Self { Self(a.x - b.x, a.y - b.y) }
        static func * (a: Self, b: Int) -> Self { Self(a.x * b, a.y * b) }
    }
    struct RNG {
        var state: UInt64
        init(_ seed: UInt64) { state = seed ^ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func range(_ low: Int, _ high: Int) -> Int { high <= low ? low : low + Int(next() % UInt64(high - low + 1)) }
    }
    struct Level {
        var image: SpotBuffer
        var hole: [Bool]
    }
    /// Pure solver: no catalog access, recipe mutation or publication of partial results.
    /// Call off MainActor. Cancellation throws and never returns an unfinished image.
    static func complete(_ source: SpotBuffer, hole: [Bool], parameters p: Parameters = Parameters(), cancelled: () -> Bool = { Task.isCancelled }) throws -> SpotBuffer? {
        try p.validate()
        let w = source.width, h = source.height
        guard w > 0, h > 0, w <= p.analysisEdge, h <= p.analysisEdge,
              source.pixels.count == w * h, hole.count == w * h,
              source.pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw LRCError("填补原型输入尺寸或像素无效") }
        func check() throws { if cancelled() { throw CancellationError() } }
        try check()
        let cells = hole.indices.filter { hole[$0] }
        guard !cells.isEmpty else { return source }
        guard cells.count < w * h else { return nil }
        let xs = cells.map { $0 % w }, ys = cells.map { $0 / w }
        var extent = max(xs.max()! - xs.min()! + 1, ys.max()! - ys.min()! + 1)
        let patchSize = 2 * p.patchRadius + 1
        var levels = [Level(image: source, hole: hole)], extents = [extent]
        while let level = levels.last {
            try check()
            if extent <= 2 * patchSize || level.image.width / 2 < 3 * patchSize || level.image.height / 2 < 3 * patchSize { break }
            levels.append(downsample(level)); extent = (extent + 1) / 2; extents.append(extent)
        }
        var previous: SpotBuffer?, field: [Point] = []
        for li in levels.indices.reversed() {
            try check()
            let level = levels[li], lw = level.image.width, lh = level.image.height, r = p.patchRadius
            var image = level.image
            if let previous {
                for i in level.hole.indices where level.hole[i] { image.pixels[i] = previous.get((i % lw) / 2, (i / lw) / 2) }
            } else { image = try membrane(image, hole: level.hole, cancelled: cancelled) }
            // Integral mask: O(1) complete-known donor/overlapping target queries.
            var integral = [Int](repeating: 0, count: (lw + 1) * (lh + 1))
            for y in 0..<lh {
                try check()
                var row = 0
                for x in 0..<lw {
                    row += level.hole[y * lw + x] ? 1 : 0
                    integral[(y + 1) * (lw + 1) + x + 1] = integral[y * (lw + 1) + x + 1] + row
                }
            }
            var valid = [Bool](repeating: false, count: lw * lh), targets = valid
            var validList: [Point] = []
            for y in 0..<lh { for x in 0..<lw {
                let x0 = max(0, x - r), y0 = max(0, y - r), x1 = min(lw, x + r + 1), y1 = min(lh, y + r + 1), stride = lw + 1
                let count = integral[y1 * stride + x1] + integral[y0 * stride + x0] - integral[y1 * stride + x0] - integral[y0 * stride + x1]
                let i = y * lw + x
                targets[i] = count > 0
                if x >= r && y >= r && x + r < lw && y + r < lh && count == 0 { valid[i] = true; validList.append(Point(x, y)) }
            } }
            guard !validList.isEmpty else {
                if li == 0 { return nil }
                previous = image; field = []; continue
            }
            var rng = RNG(p.seed ^ (UInt64(li) << 20))
            let old = field
            field = [Point](repeating: .zero, count: lw * lh)
            for y in 0..<lh {
                try check()
                for x in 0..<lw where targets[y * lw + x] {
                    let index = y * lw + x
                    var candidate: Point?
                    if !old.isEmpty, let previous {
                        let pi = y / 2 * previous.width + x / 2
                        if old.indices.contains(pi) {
                            let point = old[pi] * 2 + Point(x % 2, y % 2)
                            if isValid(point, width: lw, height: lh, valid: valid) { candidate = point }
                        }
                    }
                    field[index] = candidate ?? validList[Int(rng.next() % UInt64(validList.count))]
                }
            }
            let refineOnly = li + 1 < levels.count && extents[li] > p.refineExtent
            let iterations = li + 1 == levels.count ? p.coarseIterations : refineOnly ? 1 : max(p.minimumIterations, p.coarseIterations >> (levels.count - 1 - li))
            let passes = refineOnly ? 1 : p.matchPasses
            var costs = [Float](repeating: .infinity, count: lw * lh)
            for iteration in 0..<iterations {
                for y in 0..<lh {
                    try check()
                    for x in 0..<lw where targets[y * lw + x] {
                        let i = y * lw + x
                        costs[i] = distance(image, target: Point(x, y), source: field[i], radius: r, cutoff: .infinity)
                    }
                }
                let search = refineOnly ? 2 : (li + 1 == levels.count || iteration == 0) ? max(lw, lh) : min(4 * patchSize, max(lw, lh))
                for pass in 0..<passes {
                    try check()
                    try patchmatch(image, targets: targets, valid: valid, radius: r, field: &field, costs: &costs, pass: pass + iteration * passes,
                                   seed: p.seed &+ UInt64(li * 1000 + iteration), searchRadius: search, cancelled: cancelled)
                }
                try check()
                image = try vote(image, hole: level.hole, targets: targets, field: field, costs: costs, radius: r, cancelled: cancelled)
            }
            previous = image
        }
        try check()
        return previous
    }
    private static func downsample(_ level: Level) -> Level {
        let image = level.image, w = (image.width + 1) / 2, h = (image.height + 1) / 2
        var pixels = [SIMD3<Float>](repeating: .zero, count: w * h), mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var count: Float = 0
            for dy in 0...1 { for dx in 0...1 {
                let sx = x * 2 + dx, sy = y * 2 + dy
                guard sx < image.width, sy < image.height else { continue }
                let si = sy * image.width + sx
                if level.hole[si] { mask[y * w + x] = true }
                else { pixels[y * w + x] += image.pixels[si]; count += 1 }
            } }
            if count > 0 { pixels[y * w + x] /= count }
        } }
        return Level(image: SpotBuffer(width: w, height: h, pixels: pixels), hole: mask)
    }
    private static func isValid(_ point: Point, width: Int, height: Int, valid: [Bool]) -> Bool {
        point.x >= 0 && point.y >= 0 && point.x < width && point.y < height && valid[point.y * width + point.x]
    }
    private static func distance(_ image: SpotBuffer, target: Point, source: Point, radius r: Int, cutoff: Float) -> Float {
        var sum: Float = 0, count: Float = 0
        let full = Float((2 * r + 1) * (2 * r + 1) * 3)
        for dy in -r...r {
            let ty = target.y + dy
            guard ty >= 0 && ty < image.height else { continue }
            for dx in -r...r {
                let tx = target.x + dx
                guard tx >= 0 && tx < image.width else { continue }
                let delta = image.pixels[ty * image.width + tx] - image.pixels[(source.y + dy) * image.width + source.x + dx]
                sum += delta.x * delta.x + delta.y * delta.y + delta.z * delta.z; count += 3
            }
            if sum > cutoff * full { return .infinity }
        }
        return count > 0 ? sum / count : .infinity
    }
    private static func patchmatch(_ image: SpotBuffer, targets: [Bool], valid: [Bool], radius r: Int, field: inout [Point], costs: inout [Float], pass: Int, seed: UInt64, searchRadius: Int, cancelled: () -> Bool) throws {
        let w = image.width, h = image.height, reverse = pass % 2 == 1, step = reverse ? -1 : 1
        for band in stride(from: 0, to: h, by: 16) {
            if cancelled() { throw CancellationError() }
            var rng = RNG(seed ^ (UInt64(band / 16) &* 0x2545F4914F6CDD1D) ^ (UInt64(pass) << 40))
            let rows = min(16, h - band)
            for ry in 0..<rows {
                let y = band + (reverse ? rows - 1 - ry : ry)
                for rx in 0..<w {
                    let x = reverse ? w - 1 - rx : rx, i = y * w + x
                    guard targets[i] else { continue }
                    var best = field[i], cost = costs[i]
                    func consider(_ candidate: Point) {
                        guard candidate != best, isValid(candidate, width: w, height: h, valid: valid) else { return }
                        let value = distance(image, target: Point(x, y), source: candidate, radius: r, cutoff: cost)
                        if value < cost { best = candidate; cost = value }
                    }
                    if (0..<w).contains(x - step) { consider(field[y * w + x - step] + Point(step, 0)) }
                    if (band..<band + rows).contains(y - step) { consider(field[(y - step) * w + x] + Point(0, step)) }
                    var radius = searchRadius
                    while radius >= 1 { consider(best + Point(rng.range(-radius, radius), rng.range(-radius, radius))); radius /= 2 }
                    field[i] = best; costs[i] = cost
                }
            }
        }
    }
    private static func vote(_ image: SpotBuffer, hole: [Bool], targets: [Bool], field: [Point], costs: [Float], radius r: Int, cancelled: () -> Bool) throws -> SpotBuffer {
        let w = image.width, h = image.height
        let ordered = costs.indices.filter { targets[$0] && costs[$0].isFinite }.map { costs[$0] }.sorted()
        let sigma2 = ordered.isEmpty ? 1 : max(0.000001, ordered[min(ordered.count - 1, ordered.count * 3 / 4)])
        var output = image
        for y in 0..<h {
            if cancelled() { throw CancellationError() }
            for x in 0..<w where hole[y * w + x] {
                var sum = SIMD3<Float>.zero, weight: Float = 0
                for dy in -r...r { for dx in -r...r {
                    let tx = x + dx, ty = y + dy
                    guard tx >= 0 && ty >= 0 && tx < w && ty < h else { continue }
                    let index = ty * w + tx
                    guard targets[index], costs[index].isFinite else { continue }
                    let source = field[index] - Point(dx, dy)
                    let wt = max(0.00000001, exp(-costs[index] / (2 * sigma2)))
                    sum += image.pixels[source.y * w + source.x] * wt; weight += wt
                } }
                if weight > 0 { output.pixels[y * w + x] = sum / weight }
            }
        }
        return output
    }
    private static func membrane(_ source: SpotBuffer, hole: [Bool], cancelled: () -> Bool, depth: Int = 0) throws -> SpotBuffer {
        if cancelled() { throw CancellationError() }
        let w = source.width, h = source.height, unknown = hole.indices.filter { hole[$0] }, known = hole.indices.filter { !hole[$0] }
        guard !unknown.isEmpty, !known.isEmpty else { return source }
        var output = source
        let fine = w >= 8 && h >= 8 && unknown.count > 64 && depth < 16
        if fine {
            // Restriction marks a coarse cell unknown only when all its children are unknown.
            let cw = (w + 1) / 2, ch = (h + 1) / 2
            var coarse = SpotBuffer(width: cw, height: ch, pixels: [SIMD3<Float>](repeating: .zero, count: cw * ch))
            var mask = [Bool](repeating: true, count: cw * ch)
            for y in 0..<ch { for x in 0..<cw {
                var sum = SIMD3<Float>.zero, count: Float = 0
                for dy in 0...1 { for dx in 0...1 {
                    let sx = x * 2 + dx, sy = y * 2 + dy
                    if sx < w, sy < h, !hole[sy * w + sx] { sum += source.pixels[sy * w + sx]; count += 1 }
                } }
                if count > 0 { mask[y * cw + x] = false; coarse.pixels[y * cw + x] = sum / count }
            } }
            coarse = try membrane(coarse, hole: mask, cancelled: cancelled, depth: depth + 1)
            for i in unknown { output.pixels[i] = coarse.sample(max(0, (Float(i % w) + 0.5) / 2 - 0.5), max(0, (Float(i / w) + 0.5) / 2 - 0.5)) }
        } else {
            let mean = known.reduce(SIMD3<Float>.zero) { $0 + source.pixels[$1] } / Float(known.count)
            for i in unknown { output.pixels[i] = mean }
        }
        let omega: Float = fine ? 1.7 : 1.85
        for _ in 0..<(fine ? 30 : 2000) {
            if cancelled() { throw CancellationError() }
            var largest: Float = 0
            for i in unknown {
                let x = i % w, y = i / w
                var sum = SIMD3<Float>.zero, count: Float = 0
                if x > 0 { sum += output.pixels[i - 1]; count += 1 }
                if x + 1 < w { sum += output.pixels[i + 1]; count += 1 }
                if y > 0 { sum += output.pixels[i - w]; count += 1 }
                if y + 1 < h { sum += output.pixels[i + w]; count += 1 }
                if count > 0 {
                    let delta = omega * (sum / count - output.pixels[i]); output.pixels[i] += delta
                    largest = max(largest, abs(delta.x), abs(delta.y), abs(delta.z))
                }
            }
            if largest < 0.00002 { break }
        }
        return output
    }
}
