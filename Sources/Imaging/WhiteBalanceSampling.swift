import Foundation
import CoreImage

struct WhiteBalanceValue: Equatable, Sendable {
    var temperature: Double
    var tint: Double
}

/// Native solver: measure the same Apple RAW / Core Image transform that renders the photo.
/// No camera matrix, temperature convention or Rec.2020 constants are copied from lightcraft.
enum WhiteBalanceSampling {
    static func mean(_ image: CIImage, at point: MaskPoint, context: CIContext, rejectClipped: Bool) throws -> SIMD3<Double> {
        let extent = image.extent.integral
        let x = extent.minX + CGFloat(PhotoGeometry.pixelIndex(point.x, dimension: Int(extent.width)))
        let y = extent.minY + CGFloat(PhotoGeometry.pixelIndex(point.y, dimension: Int(extent.height)))
        let region = CGRect(x: x - 2, y: y - 2, width: 5, height: 5).intersection(extent)
        let count = Int(region.width * region.height)
        guard count > 0 else { throw LRCError(L10n.text("app.noPhotoToSampleHere", defaultValue: "No photo to sample here")) }
        var rgba = [Float](repeating: 0, count: count * 4)
        context.render(image, toBitmap: &rgba, rowBytes: Int(region.width) * 16, bounds: region,
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var sum = SIMD3<Double>.zero, valid = 0
        for n in 0..<count {
            let a = Double(rgba[n*4+3])
            guard a.isFinite, a >= 0.99 else { continue }
            let rgb = SIMD3(Double(rgba[n*4])/a, Double(rgba[n*4+1])/a, Double(rgba[n*4+2])/a)
            guard (0..<3).allSatisfy({ rgb[$0].isFinite && rgb[$0] > 0.0001 }),
                  !rejectClipped || (0..<3).allSatisfy({ rgb[$0] < 0.98 }) else { continue }
            sum += rgb; valid += 1
        }
        guard valid * 4 >= count * 3 else { throw LRCError(L10n.text("app.chooseADetailedNeutralGrayAreaAvoidTransparentVery", defaultValue: "Choose a detailed neutral gray area. Avoid transparent, very dark, or overexposed areas")) }
        return sum / Double(valid)
    }

    /// Bounded Newton solve in log-temperature and tint, using linear R/G and B/G residuals.
    /// Every evaluation checks cancellation; a constrained/unreliable fit never writes a recipe.
    static func solve(initial: WhiteBalanceValue, sample: (WhiteBalanceValue) throws -> SIMD3<Double>) throws -> WhiteBalanceValue {
        func bounded(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(min(log(50000), max(log(2000), p.x)), min(1.5, max(-1.5, p.y)))
        }
        func value(_ p: SIMD2<Double>) -> WhiteBalanceValue { WhiteBalanceValue(temperature: exp(p.x), tint: p.y * 100) }
        func residual(_ p: SIMD2<Double>) throws -> SIMD2<Double> {
            try Task.checkCancellation()
            let c = try sample(value(p))
            guard (0..<3).allSatisfy({ c[$0].isFinite && c[$0] > 0.000001 }) else { throw LRCError(L10n.text("app.whiteBalanceCannotBeCalculatedReliablyHereChooseAnother", defaultValue: "White balance cannot be calculated reliably here. Choose another neutral area")) }
            return SIMD2(log(c.x / c.y), log(c.z / c.y))
        }
        func norm(_ p: SIMD2<Double>) -> Double { p.x*p.x + p.y*p.y }
        var p = bounded(SIMD2(log(initial.temperature), initial.tint/100))
        var r = try residual(p)
        for _ in 0..<12 {
            if norm(r) < 0.000004 { break }
            let dx = p.x > log(50000)-0.01 ? -0.01 : 0.01
            let dy = p.y > 1.48 ? -0.02 : 0.02
            let a = (try residual(p + SIMD2(dx, 0)) - r) / dx
            let b = (try residual(p + SIMD2(0, dy)) - r) / dy
            let det = a.x*b.y - b.x*a.y
            guard det.isFinite, abs(det) > 0.000001 else { break }
            let step = SIMD2((r.x*b.y-r.y*b.x)/det, (a.x*r.y-a.y*r.x)/det)
            var improved = false
            for damping in [1.0, 0.5, 0.25, 0.125] {
                let next = bounded(p - step * damping), nextR = try residual(next)
                if norm(nextR) < norm(r) { p = next; r = nextR; improved = true; break }
            }
            if !improved { break }
        }
        guard norm(r) < 0.000225 else { throw LRCError(L10n.text("app.thisColorExceedsTheWhiteBalanceCorrectionRangeChoose", defaultValue: "This color exceeds the white balance correction range. Choose a neutral gray area")) }
        var result = value(p)
        result.temperature = result.temperature.rounded()
        result.tint = (result.tint * 10).rounded() / 10
        return result
    }
}
