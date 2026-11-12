import Foundation
import CoreImage
import CoreGraphics

struct MaskPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var cg: CGPoint { CGPoint(x: x, y: y) }
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    init(_ p: CGPoint) { x = p.x; y = p.y }
    // Generous finite limits keep malformed projects from overflowing GPU geometry.
    static let gradientRange: ClosedRange<Double> = -100...100
    var validForGradient: Bool { x.isFinite && y.isFinite && Self.gradientRange.contains(x) && Self.gradientRange.contains(y) }
    var valid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

enum MaskTool: String, Codable, CaseIterable, Identifiable {
    case brush, radial, linear, color, luminance, object
    var id: String { rawValue }
    var isGradient: Bool { self == .linear || self == .radial }
    var title: String {
        switch self { case .brush: return L10n.text("app.brush", defaultValue: "Brush"); case .radial: return L10n.text("app.radialGradient", defaultValue: "Radial Gradient"); case .linear: return L10n.text("app.linearGradient", defaultValue: "Linear Gradient"); case .color: return L10n.text("app.colorRange", defaultValue: "Color Range"); case .luminance: return L10n.text("app.luminanceRange", defaultValue: "Luminance Range"); case .object: return L10n.text("app.object", defaultValue: "Object") }
    }
}
enum MaskOperation: String, Codable, CaseIterable {
    case replace, add, subtract, intersect
    var title: String {
        switch self { case .replace: return L10n.text("app.base", defaultValue: "Base"); case .add: return L10n.text("app.addAction", defaultValue: "Add"); case .subtract: return L10n.text("app.subtract", defaultValue: "Subtract"); case .intersect: return L10n.text("app.intersect", defaultValue: "Intersect") }
    }
}
/// Color-range width, matched to lightcraft refine 0...100.
/// Refine 50 fully selects through 0.0225 and drops out by 0.045.
/// The fade is the outer half, so tolerance and smoothness stay equal.
enum ColorRange {
    static let defaultRefine = 50.0
    static func radius(refine: Double) -> Double {
        let t = min(max(refine, 0), 100) / 100
        return (0.015 + 0.06 * t) / 2
    }
    static func refine(radius: Double) -> Double {
        guard radius.isFinite else { return defaultRefine }
        return min(max((radius * 2 - 0.015) / 0.06 * 100, 0), 100)
    }
}

/// Auto-mask brush, matched to lightcraft `masks.rs` at commit 5436951.
/// `auto_similarity` divides log-luminance by `AUTO_TOL_EV` (0.5) and chromaticity
/// distance by `AUTO_TOL_CHROMA` (0.25), then takes the Euclidean length. Full paint
/// at or below 0.5, none at or above 1, smoothstep between. `auto_refine` is a
/// guided filter of radius `max(1, 0.25 × brush radius)` and epsilon 0.02; the
/// stroke keeps the larger of its own alpha and the filtered one.
/// Luminance weights are Rec.709 because our pixels are linear sRGB. Their Y is
/// Rec.2020 only because that is their working space. A constant log offset
/// (their division by 0.18) cancels in both the difference and the guided filter.
/// Attribution: docs/references/lightcraft-LICENSE.txt.
enum AutoMaskBrush {
    static let toleranceEV = 0.5
    static let toleranceChroma = 0.25
    static let epsilon = 0.02
    /// Same floor as `logLuminance` in DevelopKernels.metal (2⁻¹⁶).
    static let logFloor = 0.0000152587890625
    static func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }
    static func logLuminance(_ y: Double) -> Double { log2(max(y, logFloor)) }
    static func chromaticity(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let y = max(luminance(c), 1e-6)
        return c / y
    }
    static func similarity(logLuminance l: Double, chroma ch: SIMD3<Double>, referenceLogLuminance rl: Double, referenceChroma rch: SIMD3<Double>) -> Double {
        let dl = (l - rl) / toleranceEV
        let d = ch - rch
        let dc = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() / toleranceChroma
        let distance = (dl * dl + dc * dc).squareRoot()
        let t = min(1, max(0, (distance - 0.5) / 0.5))
        return 1 - t * t * (3 - 2 * t)
    }
    static func similarity(_ color: SIMD3<Double>, reference: SIMD3<Double>) -> Double {
        similarity(logLuminance: logLuminance(luminance(color)), chroma: chromaticity(color),
                   referenceLogLuminance: logLuminance(luminance(reference)), referenceChroma: chromaticity(reference))
    }
    static func filterRadius(brushRadius: Double) -> Double { max(1, 0.25 * brushRadius) }
}
struct MaskSample: Codable, Equatable {
    var point: MaskPoint
    // Linear sRGB, taken from the unedited, oriented source baseline.
    var red: Double
    var green: Double
    var blue: Double

    static func read(at point: MaskPoint, from image: CGImage, context: CIContext) -> Self? {
        guard point.valid else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        let x = PhotoGeometry.pixelIndex(point.x, dimension: image.width)
        let y = PhotoGeometry.pixelIndex(point.y, dimension: image.height)
        context.render(CIImage(cgImage: image), toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        guard pixel.allSatisfy(\.isFinite), pixel[3] > 0 else { return nil }
        func channel(_ index: Int) -> Double { Double(min(1, max(0, pixel[index] / pixel[3]))) }
        return Self(point: point, red: channel(0), green: channel(1), blue: channel(2))
    }

    var luminanceRange: ClosedRange<Double> {
        let lightness = min(1, max(0, PerceptualColor.lab(SIMD3(red, green, blue)).x))
        return max(0, lightness - 0.1)...min(1, lightness + 0.1)
    }
}
struct MaskStroke: Codable, Equatable {
    var points: [MaskPoint]
    var radius = 0.04 // Fraction of the original short edge.
    var feather = 0.7
    var flow = 0.5
    var density = 1.0
    var erase = false
    /// Paint only pixels like the one under each dab, then snap the stroke to luminance edges.
    var autoMask = false
    enum CodingKeys: String, CodingKey { case points, radius, feather, flow, density, erase, autoMask }
    init(points: [MaskPoint], radius: Double = 0.04, feather: Double = 0.7, flow: Double = 0.5, density: Double = 1.0, erase: Bool = false, autoMask: Bool = false) {
        self.points = points; self.radius = radius; self.feather = feather; self.flow = flow; self.density = density; self.erase = erase; self.autoMask = autoMask
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([MaskPoint].self, forKey: .points)
        radius = try c.decode(Double.self, forKey: .radius)
        feather = try c.decode(Double.self, forKey: .feather)
        flow = try c.decode(Double.self, forKey: .flow)
        density = try c.decode(Double.self, forKey: .density)
        erase = try c.decode(Bool.self, forKey: .erase)
        autoMask = try c.decodeIfPresent(Bool.self, forKey: .autoMask) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
        try c.encode(radius, forKey: .radius)
        try c.encode(feather, forKey: .feather)
        try c.encode(flow, forKey: .flow)
        try c.encode(density, forKey: .density)
        try c.encode(erase, forKey: .erase)
        try c.encode(autoMask, forKey: .autoMask)
    }
}
struct MaskComponent: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var tool: MaskTool
    var operation: MaskOperation = .replace
    var enabled = true
    var inverted = false
    var start = MaskPoint(0.5, 0.35)
    var end = MaskPoint(0.5, 0.75)
    var radiusX = 0.25
    var radiusY = 0.25
    var angle = 0.0
    var feather = 0.7
    var strokes: [MaskStroke] = []
    var samples: [MaskSample] = []
    var tolerance = 0.12
    var lower = 0.25
    var upper = 0.75
    var smoothness = 0.1
    var raster: SmartMaskRaster?
    init(tool: MaskTool, operation: MaskOperation = .replace) {
        self.tool = tool; self.name = tool.title; self.operation = operation
        if tool == .radial { start = MaskPoint(0.5, 0.5) }
        if tool == .color {
            let radius = ColorRange.radius(refine: ColorRange.defaultRefine)
            tolerance = radius
            smoothness = radius
        }
    }
    static func drawing(_ tool: MaskTool, operation: MaskOperation, number: Int) -> Self {
        var value = Self(tool: tool, operation: operation)
        if tool == .linear { value.end = value.start }
        if tool == .radial { value.radiusX = 0.001; value.radiusY = 0.001 }
        value.name = "\(tool.title) \(number)"
        return value
    }
    func validate() throws {
        let values = [radiusX, radiusY, angle, feather, tolerance, lower, upper, smoothness]
        guard values.allSatisfy(\.isFinite), (tool.isGradient ? start.validForGradient && end.validForGradient : start.valid && end.valid), !name.isEmpty, name.count <= 200,
              (0.001...100).contains(radiusX), (0.001...100).contains(radiusY), (-180...180).contains(angle),
              (0...1).contains(feather), (0...1).contains(tolerance), (0...1).contains(lower),
              (lower...1).contains(upper), (0...1).contains(smoothness), samples.count <= 16,
              strokes.count <= 10000, strokes.reduce(0, { $0 + $1.points.count }) <= 200000 else { throw LRCError(L10n.text("app.maskParametersAreInvalidOrExceedTheLimits", defaultValue: "Mask parameters are invalid or exceed the limits")) }
        for s in samples {
            guard s.point.valid, [s.red, s.green, s.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw LRCError(L10n.text("app.invalidColorSample", defaultValue: "Invalid color sample")) }
        }
        for s in strokes {
            guard !s.points.isEmpty, s.points.allSatisfy(\.valid), s.radius.isFinite, (0.001...1).contains(s.radius),
                  [s.feather, s.flow, s.density].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw LRCError(L10n.text("app.invalidBrushStroke", defaultValue: "Invalid brush stroke")) }
        }
        if tool == .object {
            guard let raster else { throw LRCError(L10n.text("app.theSmartSelectionHasNoSavedCoverage", defaultValue: "The smart selection has no saved coverage")) }
            try raster.validate()
        } else if raster != nil { throw LRCError(L10n.text("app.aRegularMaskCannotContainSmartSelectionCoverage", defaultValue: "A regular mask cannot contain smart selection coverage")) }
    }
}
/// Optional on legacy masks so their saved contrast/saturation rendering stays unchanged.
struct LocalDevelopSettings: Codable, Equatable {
    var temperature = 5500.0
    var tint = 0.0
    var asShotWhiteBalance = true
    var develop = DevelopAdjustments()
    var isNeutral: Bool { (asShotWhiteBalance || (temperature == 5500 && tint == 0)) && develop == DevelopAdjustments() }
    func validate() throws {
        guard temperature.isFinite, (2000...50000).contains(temperature), tint.isFinite, (-150...150).contains(tint) else { throw LRCError(L10n.text("app.invalidLocalWhiteBalanceParameters", defaultValue: "Invalid local white balance parameters")) }
        try develop.validate()
        guard develop.pointColors.isEmpty else { throw LRCError(L10n.text("app.pointColorCurrentlySupportsGlobalAdjustmentsOnly", defaultValue: "Point Color currently supports global adjustments only")) }
    }
}
struct MaskRefinement: Codable, Equatable {
    var edgeRadius = 0.0
    var blurRadius = 0.0
    var expansion = 0.0
    var hardness = 0.0
    var isNeutral: Bool { self == Self() }
    func validate() throws {
        guard [edgeRadius, blurRadius].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              [expansion, hardness].allSatisfy({ $0.isFinite && (-1...1).contains($0) })
        else { throw LRCError(L10n.text("app.invalidMaskRefinementParameters", defaultValue: "Invalid mask refinement parameters")) }
    }
}
struct LocalAdjustment: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = L10n.text("app.masks", defaultValue: "Masks")
    var enabled = true
    var inverted = false
    var amount = 1.0
    var components: [MaskComponent]
    var exposure = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var settings: LocalDevelopSettings?
    var refinement: MaskRefinement?
    var needsBaseline: Bool {
        (refinement?.edgeRadius ?? 0) > 0 || components.contains { c in
            guard c.enabled else { return false }
            if c.tool == .color || c.tool == .luminance { return true }
            return c.tool == .brush && c.strokes.contains(where: \.autoMask)
        }
    }
    var isNeutral: Bool { exposure == 0 && contrast == 1 && saturation == 1 && (settings?.isNeutral ?? true) }
    func editingRecipe(from source: EditRecipe) -> EditRecipe {
        var r = source.baseline()
        let settings = settings ?? LocalDevelopSettings()
        r.pipelineVersion = 2
        r.baselineTemperature = 5500; r.baselineTint = 0
        r.temperature = settings.temperature; r.tint = settings.tint; r.asShotWhiteBalance = settings.asShotWhiteBalance
        r.exposure = exposure; r.contrast = contrast; r.saturation = saturation; r.develop = settings.develop
        return r
    }
    mutating func updateDevelop(_ local: EditRecipe) {
        exposure = local.exposure; contrast = local.contrast; saturation = local.saturation
        let values = LocalDevelopSettings(temperature: local.temperature, tint: local.tint,
                                         asShotWhiteBalance: local.asShotWhiteBalance, develop: local.develop)
        settings = settings == nil && values.isNeutral ? nil : values
    }
    func duplicated() -> Self {
        var copy = self
        copy.id = UUID()
        copy.name += L10n.text("app.copy_213", defaultValue: " Copy")
        copy.components = components.map { component in
            var copy = component
            copy.id = UUID()
            return copy
        }
        return copy
    }
    func validate() throws {
        guard !name.isEmpty, name.count <= 200, !components.isEmpty, components.count <= 128,
              Set(components.map(\.id)).count == components.count, components.first?.operation == .replace,
              components.dropFirst().allSatisfy({ $0.operation != .replace }),
              amount.isFinite, (0...1).contains(amount), exposure.isFinite, (-5...5).contains(exposure),
              contrast.isFinite, (0...2).contains(contrast), saturation.isFinite, (0...2).contains(saturation) else { throw LRCError(L10n.text("app.invalidLocalAdjustmentParameters", defaultValue: "Invalid local adjustment parameters")) }
        try settings?.validate()
        try refinement?.validate()
        try components.forEach { try $0.validate() }
    }
}

/// The shared homogeneous geometry also handles projective pointers and overlays.
enum MaskGeometry {
    static func flipTransform(size: CGSize, horizontal: Bool, vertical: Bool) -> CGAffineTransform {
        CGAffineTransform(a: horizontal ? -1 : 1, b: 0, c: 0, d: vertical ? -1 : 1,
                          tx: horizontal ? size.width : 0, ty: vertical ? size.height : 0)
    }
    static func mapping(size: CGSize, recipe r: EditRecipe) -> (transform: PhotoTransform, output: CGSize) {
        guard let g = try? PhotoGeometry(size: size, recipe: r) else { return (.invalid, .zero) }
        return (g.transform, g.output)
    }
    static func sourcePoint(_ output: CGPoint, size: CGSize, recipe: EditRecipe, allowOutside: Bool = false) -> MaskPoint? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0, output.x.isFinite, output.y.isFinite,
              allowOutside || ((0...1).contains(output.x) && (0...1).contains(output.y)) else { return nil }
        let m = mapping(size: size, recipe: recipe)
        guard m.output.width > 0, m.output.height > 0,
              let p = m.transform.inverted().point(CGPoint(x: output.x * m.output.width, y: output.y * m.output.height)) else { return nil }
        if !allowOutside, !recipe.perspective.isNeutral {
            guard let g = try? PhotoGeometry(size: size, recipe: recipe) else { return nil }
            var q = CGPoint(x: output.x*g.output.width, y: output.y*g.output.height)
            if recipe.flipHorizontal { q.x = g.output.width-q.x }
            if recipe.flipVertical { q.y = g.output.height-q.y }
            q.x += g.cropRect.minX; q.y += g.cropRect.minY
            guard let beforePerspective = g.perspective.inverted().point(q),
                  beforePerspective.x >= 0, beforePerspective.x <= g.canvas.width,
                  beforePerspective.y >= 0, beforePerspective.y <= g.canvas.height else { return nil }
        }
        let result = MaskPoint(p.x / size.width, p.y / size.height)
        return (allowOutside ? result.validForGradient : result.valid) ? result : nil
    }
}

enum MaskPipeline {
    /// Owned by one serialized render lane. Cache coverage only: local effects
    /// still run in their original order against the preceding developed image.
    final class RasterCache {
        private struct Shape: Equatable {
            let components: [MaskComponent]
            let inverted: Bool
            let amount: Double
            let refinement: MaskRefinement?
        }
        private struct Entry {
            let shape: Shape
            let extent: CGRect
            let baseline: CIImage?
            let image: CIImage
            let bytes: Int
        }
        private let byteLimit: Int
        private var entries: [UUID: Entry] = [:]
        private(set) var retainedBytes = 0

        init(byteLimit: Int = 128 * 1024 * 1024) { self.byteLimit = max(0, byteLimit) }
        func removeAll() { entries.removeAll(); retainedBytes = 0 }
        func retain(groups: [LocalAdjustment]) {
            let ids = Set(groups.filter { $0.enabled && $0.amount > 0 && !$0.isNeutral }.map(\.id))
            for id in Set(entries.keys).subtracting(ids) { remove(id) }
        }
        private func remove(_ id: UUID) {
            if let old = entries.removeValue(forKey: id) { retainedBytes -= old.bytes }
        }
        func mask(_ group: LocalAdjustment, extent: CGRect, baseline: CIImage?, context: CIContext) throws -> CIImage {
            let shape = Shape(components: group.components, inverted: group.inverted, amount: group.amount, refinement: group.refinement)
            let guide = group.needsBaseline ? baseline : nil
            if group.enabled, group.amount > 0, let entry = entries[group.id],
               entry.shape == shape, entry.extent == extent, entry.baseline === guide { return entry.image }
            remove(group.id)
            let graph = try MaskPipeline.mask(group, extent: extent, baseline: baseline)
            // RGBA float preserves coverage. Core Image's single-channel .Lf
            // roundtrip loses precision even with an RGBAf working context.
            // Stop admission at the budget instead of evicting every earlier mask
            // in a long stack on each frame. Oversize graphs render normally.
            guard group.enabled, group.amount > 0, extent == extent.integral,
                  extent.width > 0, extent.height > 0, extent.width <= Double(byteLimit / 16),
                  extent.height <= Double(byteLimit / 16) / extent.width else { return graph }
            let width = Int(extent.width), height = Int(extent.height), cost = width * height * 16
            guard cost <= byteLimit - retainedBytes else { return graph }
            try Task.checkCancellation()
            var data = Data(count: cost)
            data.withUnsafeMutableBytes { bytes in
                context.render(graph, toBitmap: bytes.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
            }
            try Task.checkCancellation()
            let image = CIImage(bitmapData: data, bytesPerRow: width * 16, size: extent.size, format: .RGBAf, colorSpace: nil)
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            entries[group.id] = Entry(shape: shape, extent: extent, baseline: guide, image: image, bytes: cost)
            retainedBytes += cost
            return image
        }
    }
    private final class Resources {}
    private static let kernels: Result<[String: CIColorKernel], Error> = Result {
        guard let url = Bundle(for: Resources.self).url(forResource: "default", withExtension: "metallib") else { throw LRCError(L10n.text("app.theMaskShaderIsMissing", defaultValue: "The mask shader is missing")) }
        let data = try Data(contentsOf: url)
        return try Dictionary(uniqueKeysWithValues: ["maskShape", "maskCombine", "maskRange", "maskOverlay", "maskGuide", "maskHardness"].map { ($0, try CIColorKernel(functionName: $0, fromMetalLibraryData: data, outputPixelFormat: .RGBAf)) })
    }
    private static let brushCache = NSCache<NSData, CIImage>()
    static func run(_ name: String, extent: CGRect, _ args: [Any]) throws -> CIImage {
        guard let kernel = try kernels.get()[name], let image = kernel.apply(extent: extent, arguments: args) else { throw LRCError(L10n.text("app.maskRenderingFailed", defaultValue: "Mask rendering failed")) }
        return image
    }
    static func black(_ extent: CGRect) -> CIImage { CIImage(color: .black).cropped(to: extent) }
    static func combine(_ a: CIImage, _ b: CIImage, operation: MaskOperation, invert: Bool = false, amount: Double = 1) throws -> CIImage {
        let mode: Double = operation == .replace ? 0 : operation == .add ? 1 : operation == .subtract ? 2 : 3
        return try run("maskCombine", extent: a.extent, [a, b, mode, invert ? 1.0 : 0.0, amount])
    }
    static func mask(_ group: LocalAdjustment, extent: CGRect, baseline: CIImage?) throws -> CIImage {
        guard group.enabled, group.amount > 0 else { return black(extent) }
        var result = black(extent)
        for c in group.components where c.enabled {
            let component = try component(c, extent: extent, baseline: baseline)
            result = try combine(result, component, operation: c.operation, invert: c.inverted)
        }
        if group.inverted { result = try combine(black(extent), result, operation: .replace, invert: true) }
        result = try refine(result, settings: group.refinement, baseline: baseline)
        return try combine(black(extent), result, operation: .replace, amount: group.amount)
    }
    static func overlayCoverage(_ group: LocalAdjustment, recipe: EditRecipe, sourceSize: CGSize, reference: CGImage?) throws -> CIImage {
        let scale = min(1, 1536 / max(sourceSize.width, sourceSize.height))
        let extent = CGRect(x: 0, y: 0, width: max(1, floor(sourceSize.width * scale)), height: max(1, floor(sourceSize.height * scale)))
        let selection = try mask(group, extent: extent, baseline: reference.map { CIImage(cgImage: $0) })
        return try ImagePipeline.geometry(selection, recipe: recipe, referenceSize: sourceSize)
    }
    private static func fittedBaseline(_ image: CIImage, extent: CGRect) -> CIImage {
        ImagePipeline.originZero(image)
            .transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width, y: extent.height / image.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
    }
    static func refine(_ input: CIImage, settings: MaskRefinement?, baseline: CIImage?) throws -> CIImage {
        guard let settings else { return input }
        try settings.validate()
        guard !settings.isNeutral else { return input }
        var mask = ImagePipeline.originZero(input)
        let extent = mask.extent, shortEdge = min(extent.width, extent.height)
        // Work in normalized photo dimensions, never display/zoom pixels.
        if settings.expansion != 0 {
            mask = mask.clampedToExtent().applyingFilter(settings.expansion > 0 ? "CIMorphologyMaximum" : "CIMorphologyMinimum",
                parameters: [kCIInputRadiusKey: abs(settings.expansion) * shortEdge * 0.02]).cropped(to: extent)
        }
        if settings.edgeRadius > 0 {
            guard let baseline else { throw LRCError(L10n.text("app.theOriginalBaselineForEdgeSnappingIsNotReady", defaultValue: "The original baseline for edge snapping is not ready")) }
            let guide = try run("maskGuide", extent: extent, [fittedBaseline(baseline, extent: extent)])
            // ponytail: scalar Oklab lightness guide; use an RGB guide if equal-lightness color edges need refinement.
            mask = try SpatialDevelopPipeline.guided(mask, guide: guide,
                radius: max(1, settings.edgeRadius * shortEdge * 0.05), epsilon: 0.001)
        }
        if settings.blurRadius > 0 {
            mask = mask.clampedToExtent().applyingFilter("CIGaussianBlur",
                parameters: [kCIInputRadiusKey: settings.blurRadius * shortEdge * 0.05]).cropped(to: extent)
        }
        mask = try run("maskHardness", extent: extent, [mask, settings.hardness])
        return mask.transformed(by: CGAffineTransform(translationX: input.extent.minX, y: input.extent.minY))
    }
    static func component(_ c: MaskComponent, extent: CGRect, baseline: CIImage?) throws -> CIImage {
        switch c.tool {
        case .object:
            guard let raster = c.raster else { throw LRCError(L10n.text("app.smartSelectionDataIsMissing", defaultValue: "Smart selection data is missing")) }
            return try raster.image(extent: extent)
        case .linear, .radial:
            return try run("maskShape", extent: extent, [CIVector(cgRect: extent), CIVector(x: c.start.x, y: c.start.y, z: c.end.x, w: c.end.y),
                CIVector(x: c.radiusX, y: c.radiusY, z: c.angle * .pi / 180, w: c.feather), c.tool == .linear ? 0.0 : 1.0])
        case .brush: return try brush(c.strokes, extent: extent, baseline: baseline)
        case .color, .luminance:
            guard let baseline else { throw LRCError(L10n.text("app.theOriginalBaselineForRangeMaskingIsNotReady", defaultValue: "The original baseline for range masking is not ready")) }
            let input = fittedBaseline(baseline, extent: extent)
            if c.tool == .luminance {
                return try run("maskRange", extent: extent, [input, CIVector(x: c.lower, y: c.upper, z: c.smoothness, w: 0), CIVector(x: 0, y: 0, z: 0), 0.0])
            }
            var result = black(extent)
            for sample in c.samples {
                let one = try run("maskRange", extent: extent, [input, CIVector(x: c.tolerance, y: c.smoothness, z: 0, w: 0), CIVector(x: sample.red, y: sample.green, z: sample.blue), 1.0])
                result = try combine(result, one, operation: .add)
            }
            return result
        }
    }
    static func brush(_ strokes: [MaskStroke], extent: CGRect, baseline: CIImage? = nil) throws -> CIImage {
        struct Key: Encodable { var strokes: [MaskStroke]; var width: Int; var height: Int }
        let width = max(1, Int(ceil(extent.width))), height = max(1, Int(ceil(extent.height)))
        let automatic = strokes.contains(where: \.autoMask)
        if automatic, baseline == nil { throw LRCError(L10n.text("app.theOriginalBaselineForAutoMaskIsNotReady", defaultValue: "The original baseline for Auto Mask is not ready")) }
        let key = try JSONEncoder().encode(Key(strokes: strokes, width: width, height: height)) as NSData
        if !automatic, let cached = brushCache.object(forKey: key) { return cached }
        let photo = automatic ? fittedBaseline(baseline!, extent: CGRect(x: 0, y: 0, width: width, height: height)) : nil
        var coverage = Data(count: width * height)
        for stroke in strokes {
            if stroke.autoMask {
                guard let photo else { throw LRCError(L10n.text("app.theOriginalBaselineForAutoMaskIsNotReady", defaultValue: "The original baseline for Auto Mask is not ready")) }
                try stampAutomatic(stroke, width: width, height: height, photo: photo, coverage: &coverage)
                continue
            }
            let radius = stroke.radius * Double(min(width, height))
            let points = stroke.points.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
            guard let first = points.first else { continue }
            var box = CGRect(x: first.x, y: first.y, width: 0, height: 0)
            for point in points { box = box.union(CGRect(x: point.x, y: point.y, width: 0, height: 0)) }
            box = box.insetBy(dx: -radius - 1, dy: -radius - 1).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let bw = Int(box.width), bh = Int(box.height)
            guard bw > 0, bh > 0 else { continue }
            guard let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { throw LRCError(L10n.text("app.cannotAllocateABrushMask", defaultValue: "Cannot allocate a brush mask")) }
            ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: bw, height: bh))
            ctx.translateBy(x: -box.minX, y: -box.minY)
            let locations: [CGFloat] = [0, min(0.9999, max(0.0001, 1 - stroke.feather)), 1]
            let colors: [CGFloat] = [1, stroke.flow, 1, stroke.flow, 1, stroke.feather == 0 ? stroke.flow : 0]
            guard let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: colors, locations: locations, count: 3) else { throw LRCError(L10n.text("app.cannotCreateTheBrush", defaultValue: "Cannot create the brush")) }
            func stamp(_ p: CGPoint) {
                ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
            }
            stamp(first)
            // Fixed image-space spacing, with residual carried across mouse events.
            let spacing = max(0.25, radius * 0.2)
            var remaining = spacing
            for (a, b) in zip(points, points.dropFirst()) {
                let distance = hypot(b.x - a.x, b.y - a.y)
                var offset = remaining
                while offset <= distance {
                    stamp(CGPoint(x: a.x + (b.x - a.x) * offset / distance, y: a.y + (b.y - a.y) * offset / distance))
                    offset += spacing
                }
                remaining = offset - distance
            }
            guard let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { throw LRCError(L10n.text("app.cannotReadTheBrushMask", defaultValue: "Cannot read the brush mask")) }
            // Flatten each stroke into one coverage buffer; memory does not grow by image size per stroke.
            coverage.withUnsafeMutableBytes { raw in
                let target = raw.bindMemory(to: UInt8.self)
                for y in 0..<bh { for x in 0..<bw {
                    let index = (height - Int(box.maxY) + y) * width + Int(box.minX) + x
                    let previous = Double(target[index]) / 255
                    let value = Double(bytes[y * bw + x]) / 255
                    let next = stroke.erase ? previous * (1 - value * stroke.density) : previous + max(0, stroke.density - previous) * value
                    target[index] = UInt8(min(255, max(0, (next * 255).rounded())))
                } }
            }
        }
        let result = CIImage(bitmapData: coverage, bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY)).cropped(to: extent)
        // ponytail: replay strokes on cache miss; add checkpoints if long drawing sessions need them.
        // Automatic strokes depend on the photo, so they are not cached.
        if !automatic && width * height <= 64 * 1024 * 1024 {
            brushCache.totalCostLimit = 64 * 1024 * 1024
            brushCache.setObject(result, forKey: key, cost: width * height)
        }
        return result
    }
    /// One automatic stroke: same dab spacing, falloff, flow and density as the plain brush,
    /// each dab multiplied by `AutoMaskBrush.similarity`, then a guided-filter snap that
    /// only adds coverage (`max` with the unfiltered stroke).
    private static func stampAutomatic(_ stroke: MaskStroke, width: Int, height: Int, photo: CIImage, coverage: inout Data) throws {
        let radius = stroke.radius * Double(min(width, height))
        guard radius.isFinite, radius > 0 else { return }
        let points = stroke.points.map { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) }
        guard let first = points.first else { return }
        var dabs = [first]
        let spacing = max(0.25, radius * 0.2)
        var remaining = spacing
        for (a, b) in zip(points, points.dropFirst()) {
            let distance = hypot(b.x - a.x, b.y - a.y)
            if distance <= 0 { continue }
            var offset = remaining
            while offset <= distance {
                let t = offset / distance
                dabs.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                offset += spacing
            }
            remaining = offset - distance
        }
        let pad = Int(ceil(AutoMaskBrush.filterRadius(brushRadius: radius) * 3)) + 4
        var minX = width, minY = height, maxX = 0, maxY = 0
        for d in dabs {
            minX = min(minX, Int(floor(d.x - radius)) - pad)
            minY = min(minY, Int(floor(d.y - radius)) - pad)
            maxX = max(maxX, Int(ceil(d.x + radius)) + pad)
            maxY = max(maxY, Int(ceil(d.y + radius)) + pad)
        }
        minX = max(0, minX); minY = max(0, minY); maxX = min(width, maxX); maxY = min(height, maxY)
        let bw = maxX - minX, bh = maxY - minY
        guard bw > 0, bh > 0 else { return }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let box = CGRect(x: minX, y: minY, width: bw, height: bh)
        var rgb = [Float](repeating: 0, count: bw * bh * 4)
        developContext.render(photo, toBitmap: &rgb, rowBytes: bw * 16, bounds: box, format: .RGBAf, colorSpace: linear)
        for i in stride(from:0,to:rgb.count,by:4) {
            let a = rgb[i+3]
            for channel in 0..<3 { rgb[i+channel] = a > 0 ? rgb[i+channel]/a : 0 }
        }
        func colorAt(_ imageX: Int, _ imageY: Int) -> SIMD3<Double> {
            let localX = min(bw - 1, max(0, imageX - minX))
            let localY = min(bh - 1, max(0, imageY - minY))
            let i = ((bh - 1 - localY) * bw + localX) * 4
            return SIMD3(Double(rgb[i]), Double(rgb[i + 1]), Double(rgb[i + 2]))
        }
        func pixelIndex(_ imageX: Int, _ imageY: Int) -> Int {
            (bh - 1 - (imageY - minY)) * bw + (imageX - minX)
        }
        var alpha = [Float](repeating: 0, count: bw * bh)
        let hard = radius * (1 - min(1, max(0, stroke.feather)))
        for d in dabs {
            let sx = min(width - 1, max(0, Int(floor(Float(d.x)))))
            let sy = min(height - 1, max(0, Int(floor(Float(d.y)))))
            let referenceIndex = pixelIndex(sx,sy)
            guard rgb[referenceIndex*4+3] > 0 else { continue }
            let reference = colorAt(sx, sy)
            let rl = AutoMaskBrush.logLuminance(AutoMaskBrush.luminance(reference))
            let rch = AutoMaskBrush.chromaticity(reference)
            let x0 = max(minX, Int(floor(d.x - radius))), x1 = min(maxX, Int(ceil(d.x + radius)))
            let y0 = max(minY, Int(floor(d.y - radius))), y1 = min(maxY, Int(ceil(d.y + radius)))
            for y in y0..<y1 {
                for x in x0..<x1 {
                    if rgb[pixelIndex(x,y)*4+3] <= 0 { continue }
                    let dd = hypot(Double(x) + 0.5 - d.x, Double(y) + 0.5 - d.y)
                    if dd > radius { continue }
                    let falloff = stroke.feather <= 0 || dd <= hard ? 1 : (radius - dd) / max(radius - hard, 1e-6)
                    let sample = colorAt(x, y)
                    let sim = AutoMaskBrush.similarity(logLuminance: AutoMaskBrush.logLuminance(AutoMaskBrush.luminance(sample)), chroma: AutoMaskBrush.chromaticity(sample), referenceLogLuminance: rl, referenceChroma: rch)
                    let src = min(1, max(0, falloff * sim * stroke.flow))
                    let i = pixelIndex(x, y)
                    let dst = Double(alpha[i])
                    alpha[i] = Float(dst + src * (1 - dst))
                }
            }
        }
        if alpha.contains(where: { $0 > 0 }) {
            var guide = [Float](repeating: 0, count: bw * bh * 4)
            var packed = [Float](repeating: 0, count: bw * bh * 4)
            for i in 0..<(bw * bh) {
                let o = i * 4
                let l = Float(AutoMaskBrush.logLuminance(AutoMaskBrush.luminance(SIMD3(Double(rgb[o]), Double(rgb[o + 1]), Double(rgb[o + 2])))))
                guide[o] = l; guide[o + 1] = l; guide[o + 2] = l; guide[o + 3] = 1
                let v = alpha[i]
                packed[o] = v; packed[o + 1] = v; packed[o + 2] = v; packed[o + 3] = 1
            }
            func bitmap(_ pixels: [Float]) -> CIImage {
                let data = pixels.withUnsafeBytes { Data($0) }
                return CIImage(bitmapData: data, bytesPerRow: bw * 16, size: CGSize(width: bw, height: bh), format: .RGBAf, colorSpace: linear)
            }
            let hasAlpha = stride(from:3,to:rgb.count,by:4).contains { rgb[$0] < 1 }
            var sourceCoverage = [Float](repeating:0,count:rgb.count)
            if hasAlpha {
                for i in stride(from:0,to:rgb.count,by:4) { for channel in 0..<4 { sourceCoverage[i+channel] = rgb[i+3] } }
            }
            let refined = try SpatialDevelopPipeline.guided(bitmap(packed), guide: bitmap(guide), radius: AutoMaskBrush.filterRadius(brushRadius: radius), epsilon: AutoMaskBrush.epsilon,
                coverage:hasAlpha ? bitmap(sourceCoverage) : nil)
            var filtered = [Float](repeating: 0, count: bw * bh * 4)
            developContext.render(refined, toBitmap: &filtered, rowBytes: bw * 16, bounds: CGRect(x: 0, y: 0, width: bw, height: bh), format: .RGBAf, colorSpace: linear)
            for i in 0..<(bw * bh) { alpha[i] = max(alpha[i], min(1, max(0, filtered[i * 4]))) }
        }
        coverage.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: UInt8.self)
            for imageY in minY..<maxY {
                for imageX in minX..<maxX {
                    let value = Double(alpha[pixelIndex(imageX, imageY)])
                    if value < 0.5 / 255 { continue }
                    let index = (height - 1 - imageY) * width + imageX
                    let previous = Double(target[index]) / 255
                    let next = stroke.erase ? previous * (1 - value * stroke.density) : previous + max(0, stroke.density - previous) * value
                    target[index] = UInt8(min(255, max(0, (next * 255).rounded())))
                }
            }
        }
    }
    private static let developContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    static func apply(_ input: CIImage, groups: [LocalAdjustment], baseline: CIImage?, context: CIContext? = nil, interactive: Bool = false, cache: RasterCache? = nil) throws -> CIImage {
        cache?.retain(groups: groups)
        var image = input
        for group in groups where group.enabled && group.amount > 0 && !group.isNeutral {
            try Task.checkCancellation()
            let mask = try cache?.mask(group, extent: image.extent, baseline: baseline, context: context ?? developContext)
                ?? self.mask(group, extent: image.extent, baseline: baseline)
            var adjusted = image
            if group.exposure != 0 { adjusted = adjusted.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: group.exposure]) }
            if let settings = group.settings {
                if !settings.asShotWhiteBalance && (settings.temperature != 5500 || settings.tint != 0) {
                    // Local temperature is relative to the developed image: 5500 K / 0 is neutral.
                    adjusted = adjusted.applyingFilter("CITemperatureAndTint", parameters: [
                        "inputNeutral": CIVector(x: settings.temperature, y: settings.tint),
                        "inputTargetNeutral": CIVector(x: 5500, y: 0)])
                }
                adjusted = try ImagePipeline.develop(adjusted, adjustments: settings.develop, contrast: group.contrast,
                    saturation: group.saturation, context: context ?? developContext, interactive: interactive)
            } else if group.contrast != 1 || group.saturation != 1 {
                adjusted = adjusted.applyingFilter("CILinearToSRGBToneCurve")
                    .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: group.contrast, kCIInputSaturationKey: group.saturation])
                    .applyingFilter("CISRGBToneCurveToLinear")
            }
            image = adjusted.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask]).cropped(to: input.extent)
        }
        return image
    }
}
