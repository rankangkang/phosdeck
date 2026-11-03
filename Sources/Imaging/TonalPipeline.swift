import CoreImage

struct CurvePoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct ToneCurves: Codable, Equatable {
    static let maxPoints = 16
    static let minimumSpacing = 0.001
    static let grid: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let identity = grid.map { CurvePoint(x: $0, y: $0) }
    static let names = [L10n.text("app.luminance", defaultValue: "Luminance"), L10n.text("app.red_931", defaultValue: "Red"), L10n.text("app.green_932", defaultValue: "Green"), L10n.text("app.blue_933", defaultValue: "Blue")]
    var channels = Array(repeating: identity, count: 4)
    static func isIdentity(_ points: [CurvePoint]) -> Bool { points.allSatisfy { $0.x == $0.y } }
    var isNeutral: Bool { channels.allSatisfy(Self.isIdentity) }
    func validate() throws {
        guard channels.count == 4, channels.allSatisfy({ points in
            (2...Self.maxPoints).contains(points.count) && points.first?.x == 0 && points.last?.x == 1
                && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }
                && zip(points, points.dropFirst()).allSatisfy { $1.x - $0.x >= Self.minimumSpacing - 1e-12 }
        })
        else { throw LRCError(L10n.text("app.invalidCurveControlPoints", defaultValue: "Invalid curve control points")) }
    }

    /// Duplicate/too-close inputs select the existing point without replacing its output.
    @discardableResult mutating func insert(channel: Int, x: Double, y: Double) -> Int? {
        guard x.isFinite, y.isFinite else { return nil }
        let x = min(1, max(0, x)), y = min(1, max(0, y))
        if let existing = channels[channel].indices.min(by: { abs(channels[channel][$0].x-x) < abs(channels[channel][$1].x-x) }),
           abs(channels[channel][existing].x-x) < Self.minimumSpacing { return existing }
        guard channels[channel].count < Self.maxPoints else { return nil }
        let index = channels[channel].firstIndex { $0.x > x } ?? channels[channel].count
        channels[channel].insert(CurvePoint(x: x, y: y), at: index)
        return index
    }
    mutating func move(channel: Int, point: Int, x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let points = channels[channel]
        let newX = point == 0 ? 0 : point == points.count - 1 ? 1
            : min(points[point+1].x - Self.minimumSpacing, max(points[point-1].x + Self.minimumSpacing, x))
        channels[channel][point] = CurvePoint(x: newX, y: min(1, max(0, y)))
    }
    @discardableResult mutating func remove(channel: Int, point: Int) -> Bool {
        guard point > 0, point < channels[channel].count - 1 else { return false }
        channels[channel].remove(at: point)
        return true
    }

    /// Mix functions at shared X positions, never point indices. A missing curve is identity.
    /// Use the union of inputs (coalescing sub-spacing neighbours); if it exceeds 16,
    /// use the fixed 16-point grid. Intermediate Hermite segments are shape-preserving
    /// reconstructions of these samples, not an exact sum of the two cubic functions.
    static func mixing(_ from: Self?, _ toward: Self?, amount: Double) -> Self? {
        if amount == 0 { return from }; if amount == 1 { return toward }
        let a = from ?? Self(), b = toward ?? Self()
        var result = Self()
        for channel in 0..<4 {
            var xs = [0.0]
            for x in (a.channels[channel] + b.channels[channel]).map(\.x).sorted() where x > 0 && x < 1 {
                if x - xs.last! >= minimumSpacing && 1 - x >= minimumSpacing { xs.append(x) }
            }
            xs.append(1)
            if xs.count > maxPoints { xs = (0..<maxPoints).map { Double($0) / Double(maxPoints - 1) } }
            result.channels[channel] = xs.map { x in
                let y0 = TonalPipeline.evaluate(a.channels[channel], at: x)
                let y1 = TonalPipeline.evaluate(b.channels[channel], at: x)
                return CurvePoint(x: x, y: min(1, max(0, y0 + (y1-y0)*amount)))
            }
        }
        return result
    }
}

struct ToneZones: Codable, Equatable {
    static let names = [L10n.text("app.deepShadows", defaultValue: "Deep Shadows"), L10n.text("app.shadows", defaultValue: "Shadows"), L10n.text("app.midtones", defaultValue: "Midtones"), L10n.text("app.lights", defaultValue: "Lights"), L10n.text("app.highlights", defaultValue: "Highlights")]
    static let stops: [Double] = [-8, -6, -4, -2, 0]
    var gains = Array(repeating: 0.0, count: 5)
    var isNeutral: Bool { gains.allSatisfy { $0 == 0 } }
    func validate() throws {
        guard gains.count == 5, gains.allSatisfy({ $0.isFinite && (-1...1).contains($0) })
        else { throw LRCError(L10n.text("app.invalidZoneExposureParameters", defaultValue: "Invalid zone exposure parameters")) }
    }
    func gain(at ev: Double) -> Double {
        if ev <= -8 { return gains[0] }
        if ev >= 0 { return gains[4] }
        return min(1, max(-1, TonalPipeline.interpolate(zip(Self.stops, gains).map(+), at: (ev + 8) / 2) - ev))
    }
    static func nearest(to ev: Double) -> Int { Int(min(4, max(0, ((ev + 8) / 2).rounded()))) }
}

enum TonalPipeline {
    /// Nonuniform shape-preserving Hermite (weighted harmonic interior derivatives).
    /// Secant endpoints retain the original five-point reference appearance.
    static func slopes(_ points: [CurvePoint]) -> [Double] {
        let h = zip(points, points.dropFirst()).map { $1.x - $0.x }
        let d = zip(points, points.dropFirst()).enumerated().map { ($0.element.1.y - $0.element.0.y) / h[$0.offset] }
        return points.indices.map { i in
            if i == 0 { return d[0] }; if i == points.count - 1 { return d.last! }
            guard d[i-1] * d[i] > 0 else { return 0 }
            let w1 = 2*h[i] + h[i-1], w2 = h[i] + 2*h[i-1]
            return (w1+w2) / (w1/d[i-1] + w2/d[i])
        }
    }
    static func evaluate(_ points: [CurvePoint], at input: Double) -> Double {
        let x = min(1, max(0, input))
        // Identity layouts must stay exact during preset/function mixing. A
        // cubic round trip otherwise creates ~1 ulp deviations, disables the
        // neutral bypass and changes the raster precision path.
        if ToneCurves.isIdentity(points) { return x }
        let i = min(points.count - 2, max(0, (points.lastIndex { $0.x <= x } ?? 0)))
        let a = points[i], b = points[i+1], h = b.x-a.x, t = (x-a.x)/h
        let m = slopes(points)
        let y = (2*t*t*t-3*t*t+1)*a.y + (t*t*t-2*t*t+t)*h*m[i]
            + (-2*t*t*t+3*t*t)*b.y + (t*t*t-t*t)*h*m[i+1]
        return min(max(a.y,b.y), max(min(a.y,b.y), y))
    }
    static func transform(_ input: SIMD3<Double>, curves: ToneCurves) -> SIMD3<Double> {
        var c = input
        if !ToneCurves.isIdentity(curves.channels[0]) {
            let y = DevelopPipeline.luma(c)
            let target = PerceptualColor.linear(SIMD3(repeating: evaluate(curves.channels[0], at: PerceptualColor.encoded(SIMD3(repeating: max(0,y))).x))).x
            c = y > 1e-8 ? c * (target/y) : SIMD3(repeating: target)
        }
        for channel in 1..<4 where !ToneCurves.isIdentity(curves.channels[channel]) {
            let x = PerceptualColor.encoded(SIMD3(repeating: max(0,c[channel-1]))).x
            c[channel-1] = PerceptualColor.linear(SIMD3(repeating: evaluate(curves.channels[channel], at: x))).x
        }
        return c
    }
    /// Uniform cubic Hermite, harmonic interior slopes and secant endpoints.
    /// The same equations run in Metal; monotone anchors never overshoot.
    static func interpolate(_ y: [Double], at position: Double) -> Double {
        let x = min(4, max(0, position)), i = min(3, Int(x)), t = x - Double(i)
        let d = (0..<4).map { y[$0 + 1] - y[$0] }
        func slope(_ j: Int) -> Double {
            if j == 0 { return d[0] }; if j == 4 { return d[3] }
            return d[j - 1] * d[j] <= 0 ? 0 : 2 * d[j - 1] * d[j] / (d[j - 1] + d[j])
        }
        return (2*t*t*t - 3*t*t + 1)*y[i] + (t*t*t - 2*t*t + t)*slope(i)
            + (-2*t*t*t + 3*t*t)*y[i + 1] + (t*t*t - t*t)*slope(i + 1)
    }
    static func curves(_ input: CIImage, _ curves: ToneCurves?) throws -> CIImage {
        guard let curves else { return input }
        try curves.validate()
        guard !curves.isNeutral else { return input }
        var image = input
        for channel in 0..<4 where !ToneCurves.isIdentity(curves.channels[channel]) {
            let points = curves.channels[channel], slopes = slopes(points)
            let packed = (0..<ToneCurves.maxPoints).map { i -> CIVector in
                let j = min(i, points.count-1)
                return CIVector(x: points[j].x, y: points[j].y, z: slopes[j], w: 0)
            }
            image = try SpatialDevelopPipeline.run("toneCurves", extent: input.extent,
                [image] + packed + [Double(points.count), Double(channel)])
        }
        return image
    }
    static func zoneGuide(_ input: CIImage, context: CIContext? = nil) throws -> CIImage {
        let guide = try SpatialDevelopPipeline.run("logLuminance", extent: input.extent, [input])
        let coverage = context.flatMap { ImagePipeline.hasTransparency(input,context:$0) ? input : nil }
        return try SpatialDevelopPipeline.guided(guide, guide: guide,
            radius: max(4, max(input.extent.width, input.extent.height) * 0.008), epsilon: 0.08,coverage:coverage)
    }
    static func zones(_ input: CIImage, _ zones: ToneZones?, context: CIContext? = nil) throws -> CIImage {
        guard let zones else { return input }
        try zones.validate()
        guard !zones.isNeutral else { return input }
        let g = zones.gains
        return try SpatialDevelopPipeline.run("zoneExposure", extent: input.extent,
            [input, zoneGuide(input,context:context), CIVector(x: g[0], y: g[1], z: g[2], w: g[3]), g[4]])
    }
}
