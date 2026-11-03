import Foundation
import CoreGraphics

enum CropGuide: String, CaseIterable {
    case thirds, grid, golden, diagonal, none
    var title: String {
        switch self { case .thirds: L10n.text("app.ruleOfThirds", defaultValue: "Rule of Thirds"); case .grid: L10n.text("app.grid", defaultValue: "Grid"); case .golden: L10n.text("app.goldenRatio", defaultValue: "Golden Ratio"); case .diagonal: L10n.text("app.diagonals", defaultValue: "Diagonals"); case .none: L10n.text("app.none", defaultValue: "None") }
    }
    var next: Self { let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count] }
    func lines(in rect: CGRect) -> [(CGPoint, CGPoint)] {
        if self == .none { return [] }
        if self == .diagonal {
            return [(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
                    (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY))]
        }
        let fractions: [Double] = self == .grid ? (1..<8).map { Double($0) / 8 } : self == .golden ? [0.38196601125, 0.61803398875] : [1.0 / 3, 2.0 / 3]
        return fractions.flatMap { f in
            [(CGPoint(x: rect.minX + rect.width * f, y: rect.minY), CGPoint(x: rect.minX + rect.width * f, y: rect.maxY)),
             (CGPoint(x: rect.minX, y: rect.minY + rect.height * f), CGPoint(x: rect.maxX, y: rect.minY + rect.height * f))]
        }
    }
}

/// Display coordinates are top-left; recipe coordinates are bottom-left.
enum CropInteraction {
    enum Handle: Equatable { case move, draw, resize(Int, Int) }
    static func rect(_ crop: Crop, size: CGSize) -> CGRect {
        CGRect(x: crop.x * size.width, y: (1 - crop.y - crop.height) * size.height, width: crop.width * size.width, height: crop.height * size.height)
    }
    static func hit(_ point: CGPoint, crop: Crop, size: CGSize) -> Handle {
        let r = rect(crop, size: size), threshold = min(12.0, min(r.width, r.height) / 3)
        if r.insetBy(dx: -threshold, dy: -threshold).contains(point) {
            let x = abs(point.x - r.minX) <= threshold ? -1 : abs(point.x - r.maxX) <= threshold ? 1 : 0
            let y = abs(point.y - r.minY) <= threshold ? -1 : abs(point.y - r.maxY) <= threshold ? 1 : 0
            if x != 0 || y != 0 { return .resize(x, y) }
            if r.contains(point) { return .move }
        }
        return .draw
    }
    static func drag(_ original: Crop, handle: Handle, from start: CGPoint, to end: CGPoint, size: CGSize, aspectRatio: Double?) -> Crop {
        guard size.width > 0, size.height > 0 else { return original }
        let r = rect(original, size: CGSize(width: 1, height: 1))
        let dx = (end.x - start.x) / size.width, dy = (end.y - start.y) / size.height
        let ratio = aspectRatio.map { $0 * size.height / size.width }
        func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, v)) }
        func crop(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Crop {
            Crop(x: clamp(x, 0, 1 - w), y: clamp(1 - y - h, 0, 1 - h), width: w, height: h)
        }
        switch handle {
        case .move:
            return crop(clamp(r.minX + dx, 0, 1 - r.width), clamp(r.minY + dy, 0, 1 - r.height), r.width, r.height)
        case .draw:
            let anchor = CGPoint(x: clamp(start.x / size.width), y: clamp(start.y / size.height))
            let ex = clamp(end.x / size.width), ey = clamp(end.y / size.height)
            let sx = ex >= anchor.x ? 1.0 : -1.0, sy = ey >= anchor.y ? 1.0 : -1.0
            var w = max(0.01, abs(ex - anchor.x)), h = max(0.01, abs(ey - anchor.y))
            if let ratio {
                w = max(w, h * ratio)
                w = min(w, min(sx > 0 ? 1 - anchor.x : anchor.x, (sy > 0 ? 1 - anchor.y : anchor.y) * ratio))
                h = w / ratio
                guard w > 0.0001, h > 0.0001 else { return original }
            }
            return crop(sx > 0 ? anchor.x : anchor.x - w, sy > 0 ? anchor.y : anchor.y - h, w, h)
        case let .resize(ix, iy):
            let sx = Double(ix), sy = Double(iy)
            let anchorX = ix < 0 ? r.maxX : r.minX, anchorY = iy < 0 ? r.maxY : r.minY
            var w = ix == 0 ? r.width : clamp(r.width + dx * sx, 0.01, ix < 0 ? anchorX : 1 - anchorX)
            var h = iy == 0 ? r.height : clamp(r.height + dy * sy, 0.01, iy < 0 ? anchorY : 1 - anchorY)
            if let ratio {
                if ix == 0 { w = h * ratio }
                else if iy == 0 { h = w / ratio }
                else if abs(dx) >= abs(dy * ratio) { h = w / ratio }
                else { w = h * ratio }
                let maxW = ix == 0 ? 2 * min(r.midX, 1 - r.midX) : (ix < 0 ? anchorX : 1 - anchorX)
                let maxH = iy == 0 ? 2 * min(r.midY, 1 - r.midY) : (iy < 0 ? anchorY : 1 - anchorY)
                let scale = min(1, min(maxW / w, maxH / h)); w *= scale; h *= scale
            }
            return crop(ix == 0 ? r.midX - w / 2 : ix < 0 ? anchorX - w : anchorX,
                        iy == 0 ? r.midY - h / 2 : iy < 0 ? anchorY - h : anchorY, w, h)
        }
    }
}

/// The crop is stored in the original, axis-aligned output rectangle. During
/// editing expose the entire rotated image around it, including discarded edges.
enum CropPreviewGeometry {
    static func zoom(size: CGSize, degrees: Double) -> CGFloat {
        let a = degrees * .pi / 180, c = abs(cos(a)), s = abs(sin(a))
        return max(c + s * size.height / max(1, size.width), c + s * size.width / max(1, size.height))
    }
    static func transform(size: CGSize, degrees: Double) -> CGAffineTransform {
        let z = zoom(size: size, degrees: degrees)
        return CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
    }
    static func bounds(size: CGSize, degrees: Double) -> CGRect {
        CGRect(origin: .zero, size: size).applying(transform(size: size, degrees: degrees))
    }
    static func outputFrame(size: CGSize, canvas: CGSize, degrees: Double) -> CGRect {
        let extent = bounds(size: size, degrees: degrees)
        let scale = min(canvas.width / max(1, extent.width), canvas.height / max(1, extent.height))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }
}
