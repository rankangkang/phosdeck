import CoreGraphics
import CoreImage
import Foundation

struct PerspectiveSettings: Codable, Equatable {
    /// Required processing identifier; the old projective mapping is unsupported.
    var model = "camera-rotation-v2"
    var horizontal = 0.0
    var vertical = 0.0
    var aspect = 0.0
    var constrainCrop = true
    var isNeutral: Bool { horizontal == 0 && vertical == 0 && aspect == 0 }
    func validate() throws {
        guard model == "camera-rotation-v2" else { throw LRCError(L10n.text("app.unsupportedPerspectiveProcessingIdentifierOriginalDataPreserved", defaultValue: "Unsupported perspective processing identifier. Original data preserved")) }
        guard [horizontal, vertical, aspect].allSatisfy({ $0.isFinite && (-100...100).contains($0) })
        else { throw LRCError(L10n.text("app.invalidPerspectiveParametersRange100100", defaultValue: "Invalid perspective parameters (range −100…100)")) }
    }

    /// LightCraft transform.rs::manual/recentre at 4f0b110 (MIT), adapted to
    /// bottom-left pixels. Virtual camera: Ry(horizontal) * Rx(-vertical),
    /// focal length 1.5 in half-long-edge units, ±100 → ±0.5 radians.
    /// Aspect + stretches vertically with reciprocal horizontal scale.
    /// Attribution: docs/references/lightcraft-LICENSE.txt.
    func transform(canvas: CGSize) -> PhotoTransform {
        if isNeutral { return .identity }
        let ax = -vertical * 0.005, ay = horizontal * 0.005, f = 1.5
        let sx = sin(ax), cx = cos(ax), sy = sin(ay), cy = cos(ay)
        var h = PhotoTransform(values: [cy,sy*sx,f*sy*cx, 0,cx,-f*sx, -sy/f,cy*sx/f,cy*cx])
        // Preserve upstream's local-area normalization, including its 1e-4
        // finite difference, so independent upstream vectors remain reproducible.
        let origin = h.point(.zero)!
        h = h.concatenating(CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let epsilon = 1e-4
        let px = h.point(CGPoint(x: epsilon, y: 0))!, py = h.point(CGPoint(x: 0, y: epsilon))!
        let determinant = abs((px.x*py.y-px.y*py.x)/(epsilon*epsilon))
        let scale = determinant > 1e-12 ? 1/sqrt(determinant) : 1, k = pow(2,aspect/200)
        h = h.concatenating(CGAffineTransform(scaleX: scale/k, y: scale*k))
        let edge = max(canvas.width,canvas.height)/2
        // Reflect Y on both sides of the upstream y-down model. Photo storage,
        // masks, repairs and all native pointer coordinates keep their baseline.
        return PhotoTransform(CGAffineTransform(a: 1/edge, b: 0, c: 0, d: -1/edge, tx: -canvas.width/2/edge, ty: canvas.height/2/edge))
            .concatenating(h)
            .concatenating(CGAffineTransform(a: edge, b: 0, c: 0, d: -edge, tx: canvas.width/2, ty: canvas.height/2))
    }
}

/// Row-major homogeneous matrix, in bottom-left image pixel coordinates.
/// Composition, inverse, rendering, pointers and overlays all use these values.
struct PhotoTransform: Equatable {
    var values: [Double]
    static let identity = Self(CGAffineTransform.identity)
    static let invalid = Self(values: Array(repeating: .nan, count: 9))
    init(values: [Double]) { self.values = values }
    init(_ a: CGAffineTransform) { values = [a.a, a.c, a.tx, a.b, a.d, a.ty, 0, 0, 1] }
    var isAffine: Bool { values[6] == 0 && values[7] == 0 && values[8] == 1 }
    var affine: CGAffineTransform { CGAffineTransform(a: values[0], b: values[3], c: values[1], d: values[4], tx: values[2], ty: values[5]) }
    func concatenating(_ next: CGAffineTransform) -> Self { concatenating(Self(next)) }
    func concatenating(_ next: Self) -> Self {
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 { for col in 0..<3 {
            for k in 0..<3 { result[row * 3 + col] += next.values[row * 3 + k] * values[k * 3 + col] }
        } }
        return Self(values: result)
    }
    func inverted() -> Self {
        let m = values
        let a = m[4]*m[8]-m[5]*m[7], b = m[5]*m[6]-m[3]*m[8], c = m[3]*m[7]-m[4]*m[6]
        let determinant = m[0]*a + m[1]*b + m[2]*c
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return .invalid }
        return Self(values: [a, m[2]*m[7]-m[1]*m[8], m[1]*m[5]-m[2]*m[4],
                             b, m[0]*m[8]-m[2]*m[6], m[2]*m[3]-m[0]*m[5],
                             c, m[1]*m[6]-m[0]*m[7], m[0]*m[4]-m[1]*m[3]].map { $0 / determinant })
    }
    func point(_ p: CGPoint) -> CGPoint? {
        let m = values, w = m[6]*p.x + m[7]*p.y + m[8]
        guard p.x.isFinite, p.y.isFinite, w.isFinite, w > 1e-9 else { return nil }
        let q = CGPoint(x: (m[0]*p.x+m[1]*p.y+m[2])/w, y: (m[3]*p.x+m[4]*p.y+m[5])/w)
        return q.x.isFinite && q.y.isFinite ? q : nil
    }
    /// Curves become rational under perspective. Subdivide in source space;
    /// keep the exact Core Graphics path for the neutral affine case.
    func path(_ input: CGPath) -> CGPath {
        if isAffine { var a = affine; return input.copy(using: &a) ?? CGMutablePath() }
        let result = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero, connected = false
        func emit(_ p: CGPoint, move: Bool = false) {
            if let q = point(p), abs(q.x) < 1e7, abs(q.y) < 1e7 {
                if move || !connected { result.move(to: q) } else { result.addLine(to: q) }
                connected = true
            } else { connected = false }
        }
        input.applyWithBlock { item in
            let e = item.pointee, p = e.points
            switch e.type {
            case .moveToPoint: current = p[0]; start = current; emit(current, move: true)
            case .addLineToPoint:
                let from = current
                // Avoid connecting across the projective horizon of off-photo guides.
                for i in 1...32 { let t = Double(i)/32; emit(CGPoint(x: from.x+(p[0].x-from.x)*t, y: from.y+(p[0].y-from.y)*t)) }
                current = p[0]
            case .addQuadCurveToPoint:
                let from = current
                for i in 1...32 { let t = Double(i)/32, u = 1-t
                    emit(CGPoint(x: u*u*from.x+2*u*t*p[0].x+t*t*p[1].x, y: u*u*from.y+2*u*t*p[0].y+t*t*p[1].y)) }
                current = p[1]
            case .addCurveToPoint:
                let from = current
                for i in 1...48 { let t = Double(i)/48, u = 1-t
                    emit(CGPoint(x: u*u*u*from.x+3*u*u*t*p[0].x+3*u*t*t*p[1].x+t*t*t*p[2].x,
                                 y: u*u*u*from.y+3*u*u*t*p[0].y+3*u*t*t*p[1].y+t*t*t*p[2].y)) }
                current = p[2]
            case .closeSubpath: emit(start); current = start; connected = false
            @unknown default: connected = false
            }
        }
        return result
    }
}

extension CGPoint {
    func applying(_ transform: PhotoTransform) -> CGPoint { transform.point(self) ?? CGPoint(x: CGFloat.nan, y: CGFloat.nan) }
}

/// EXIF is already applied by the decoder. Then: quarter turn → existing
/// straighten (including its existing zoom) → perspective/aspect in the fixed
/// turned canvas → inward constrained/integral crop → reflections.
struct PhotoGeometry {
    let canvas: CGSize
    let perspective: PhotoTransform
    let cropRect: CGRect
    let transform: PhotoTransform
    var output: CGSize { cropRect.size }
    static let maximumDimension = 131_072.0
    /// Floor a normalized sample coordinate, snapping only floating-point noise
    /// at exact pixel boundaries after forward/inverse homography round trips.
    static func pixelIndex(_ position: Double, dimension: Int) -> Int {
        let pixel = position*Double(dimension), nearest = pixel.rounded()
        let stable = abs(pixel-nearest) <= 64*Double.ulpOfOne*max(1,abs(pixel)) ? nearest : pixel
        return min(dimension-1,max(0,Int(floor(stable))))
    }
    static func checkSize(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= maximumDimension, size.height <= maximumDimension,
              size.width * size.height <= 268_435_456 else { throw LRCError(L10n.text("app.geometryCanvasDimensionsAreInvalidOrTooLarge", defaultValue: "Geometry canvas dimensions are invalid or too large")) }
    }
    init(size: CGSize, recipe r: EditRecipe) throws {
        try Self.checkSize(size); try r.perspective.validate()
        guard (0...3).contains(r.quarterTurns), r.straightenDegrees.isFinite, (-45...45).contains(r.straightenDegrees),
              [r.crop.x, r.crop.y, r.crop.width, r.crop.height].allSatisfy(\.isFinite),
              r.crop.x >= 0, r.crop.y >= 0, r.crop.width > 0, r.crop.height > 0,
              r.crop.x+r.crop.width <= 1.0000001, r.crop.y+r.crop.height <= 1.0000001
        else { throw LRCError(L10n.text("app.invalidGeometryParameters", defaultValue: "Invalid geometry parameters")) }
        let w = size.width, h = size.height
        let turn: CGAffineTransform
        switch r.quarterTurns {
        case 1: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 2: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: turn = .identity
        }
        canvas = r.quarterTurns % 2 == 0 ? size : CGSize(width: h, height: w)
        let frame = CGRect(origin: .zero, size: canvas)
        perspective = r.perspective.transform(canvas: canvas)
        let requested = CGRect(x: r.crop.x*canvas.width, y: r.crop.y*canvas.height, width: r.crop.width*canvas.width, height: r.crop.height*canvas.height).integral.intersection(frame)
        guard !requested.isNull, !requested.isEmpty else { throw LRCError(L10n.text("app.cropOutputIsEmpty", defaultValue: "Crop output is empty")) }
        if !r.perspective.isNeutral && r.perspective.constrainCrop {
            let inverse = perspective.inverted()
            let safe = frame.insetBy(dx: min(1, canvas.width/4), dy: min(1, canvas.height/4))
            func inside(_ rect: CGRect) -> Bool {
                Self.corners(rect).allSatisfy { p in
                    guard let q = inverse.point(p) else { return false }
                    return q.x >= safe.minX && q.x <= safe.maxX && q.y >= safe.minY && q.y <= safe.maxY
                }
            }
            let center = CGPoint(x: requested.midX, y: requested.midY)
            guard inside(CGRect(origin: center, size: .zero)) else { throw LRCError(L10n.text("app.theCropCenterIsInAnEmptyPerspectiveArea", defaultValue: "The crop center is in an empty perspective area. Move the crop or disable Constrain Crop")) }
            var lo = 0.0, hi = 1.0
            func scaled(_ t: Double) -> CGRect { CGRect(x: center.x-requested.width*t/2, y: center.y-requested.height*t/2, width: requested.width*t, height: requested.height*t) }
            if inside(requested) { lo = 1 }
            else { for _ in 0..<56 { let t = (lo+hi)/2; if inside(scaled(t)) { lo = t } else { hi = t } } }
            let rect = scaled(lo)
            cropRect = CGRect(x: ceil(rect.minX), y: ceil(rect.minY), width: floor(rect.maxX)-ceil(rect.minX), height: floor(rect.maxY)-ceil(rect.minY))
        } else { cropRect = requested }
        try Self.checkSize(cropRect.size)
        transform = PhotoTransform(turn)
            .concatenating(CropPreviewGeometry.transform(size: canvas, degrees: r.straightenDegrees))
            .concatenating(perspective)
            .concatenating(CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            .concatenating(MaskGeometry.flipTransform(size: cropRect.size, horizontal: r.flipHorizontal, vertical: r.flipVertical))
        guard transform.values.allSatisfy(\.isFinite), transform.inverted().values.allSatisfy(\.isFinite) else { throw LRCError(L10n.text("app.degeneratePerspectiveTransform", defaultValue: "Degenerate perspective transform")) }
    }
    static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
}

enum PerspectivePipeline {
    private final class Resources {}
    private static let loaded: Result<CIKernel, Error> = Result {
        guard let url = Bundle(for: Resources.self).url(forResource: "default", withExtension: "metallib") else { throw LRCError(L10n.text("app.thePerspectiveShaderIsMissing", defaultValue: "The perspective shader is missing")) }
        return try CIKernel(functionName: "manualPerspective", fromMetalLibraryData: Data(contentsOf: url), outputPixelFormat: .RGBAf)
    }
    static func apply(_ input: CIImage, transform: PhotoTransform) throws -> CIImage {
        let inverse = transform.inverted(), m = inverse.values, extent = input.extent
        let vectors = (0..<3).map { row in CIVector(x: m[row*3], y: m[row*3+1], z: m[row*3+2]) }
        guard let image = try loaded.get().apply(extent: extent, roiCallback: { _, rect in
            let points = PhotoGeometry.corners(rect).compactMap { inverse.point($0) }
            guard points.count == 4 else { return extent }
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()!-xs.min()!, height: ys.max()!-ys.min()!).insetBy(dx: -2, dy: -2).intersection(extent)
        }, arguments: [input] + vectors + [CIVector(cgRect: extent)]) else { throw LRCError(L10n.text("app.perspectiveRenderingFailed", defaultValue: "Perspective rendering failed")) }
        return image
    }
}
