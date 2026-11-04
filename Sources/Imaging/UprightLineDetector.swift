// Adapted from Redlamp LineDetector.swift, copyright Redlamp contributors, MPL-2.0.
// Source: pdcgomes/redlamp 21ff73eb33f3185a6c31eff752a330579a8801c9 (2026-11-01).
// Native pixel input and coordinate/output types changed for Phosdeck.
// See bundled redlamp-LICENSE.txt. This file remains available under MPL-2.0.
import CoreImage
import Foundation
import simd

/// Burns/Hanson/Riseman line-support regions (1986), weighted by gradient strength.
enum UprightLineDetector {
    struct Image {
        let width: Int
        let height: Int
        let values: [Float]
    }
    static let angleTolerance: Float = 22.5 * .pi / 180
    static let minimumGradient: Float = 0.012
    static let minimumLength: Float = 20
    static let minimumDensity: Float = 0.6

    static func lines(in image: CGImage) throws -> [PerspectiveLine] {
        try Task.checkCancellation()
        let input = ImagePipeline.resized(CIImage(cgImage: image), longEdge: 1024)
        let w = Int(input.extent.width), h = Int(input.extent.height)
        var pixels = [Float](repeating: 0, count: w*h*4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: space])
        context.render(input, toBitmap: &pixels, rowBytes: w*16, bounds: input.extent, format: .RGBAf, colorSpace: space)
        let values = (0..<w*h).map { i in
            sqrt(max(0, pixels[i*4]*0.2126 + pixels[i*4+1]*0.7152 + pixels[i*4+2]*0.0722))
        }
        try Task.checkCancellation()
        return lines(in: Image(width: w, height: h, values: values)).filter { line in
            // Image-frame edges are not scene geometry.
            !((max(line.start.x,line.end.x) < 0.015 || min(line.start.x,line.end.x) > 0.985) ||
              (max(line.start.y,line.end.y) < 0.015 || min(line.start.y,line.end.y) > 0.985))
        }
    }
    static func lines(in image: Image) -> [PerspectiveLine] {
        let (width, height) = (image.width, image.height)
        guard width >= 8, height >= 8 else { return [] }
        // A light blur first: the 3x3 binomial, so pixel noise doesn't break regions apart.
        var smooth = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            if Task.isCancelled { return [] }
            for x in 0 ..< width {
                var sum: Float = 0
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 {
                        let v = image.values[min(max(y + dy, 0), height - 1) * width + min(max(x + dx, 0), width - 1)]
                        sum += v * Float((dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1))
                    }
                }
                smooth[y * width + x] = sum / 16
            }
        }
        // Gradients on the 2x2 cell below and right of each pixel; the edge runs across them.
        var magnitude = [Float](repeating: 0, count: width * height)
        var angle = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height - 1 {
            for x in 0 ..< width - 1 {
                let a = smooth[y * width + x], b = smooth[y * width + x + 1]
                let c = smooth[(y + 1) * width + x], d = smooth[(y + 1) * width + x + 1]
                let gx = (b + d - a - c) / 2, gy = (c + d - a - b) / 2
                magnitude[y * width + x] = (gx * gx + gy * gy).squareRoot()
                // The edge's own direction, which keeps which side is brighter.
                angle[y * width + x] = atan2(gx, -gy)
            }
        }
        // Seeds strongest first.
        let order = (0 ..< width * height).filter { magnitude[$0] >= minimumGradient }
            .sorted { magnitude[$0] > magnitude[$1] }
        var used = [Bool](repeating: false, count: width * height)
        var found: [PerspectiveLine] = []
        var region: [Int] = []
        for seed in order where !used[seed] {
            if Task.isCancelled { return [] }
            region.removeAll(keepingCapacity: true)
            region.append(seed)
            used[seed] = true
            var direction = SIMD2(cos(angle[seed]), sin(angle[seed]))
            var regionAngle = angle[seed]
            var next = 0
            while next < region.count {
                let index = region[next]
                next += 1
                let (x, y) = (index % width, index / width)
                for dy in -1 ... 1 {
                    for dx in -1 ... 1 where dx != 0 || dy != 0 {
                        let (nx, ny) = (x + dx, y + dy)
                        guard nx >= 0, ny >= 0, nx < width - 1, ny < height - 1 else { continue }
                        let neighbour = ny * width + nx
                        guard !used[neighbour], magnitude[neighbour] >= minimumGradient else { continue }
                        let difference = abs(remainder(angle[neighbour] - regionAngle, 2 * .pi))
                        guard difference <= angleTolerance else { continue }
                        used[neighbour] = true
                        region.append(neighbour)
                        direction += SIMD2(cos(angle[neighbour]), sin(angle[neighbour]))
                        regionAngle = atan2(direction.y, direction.x)
                    }
                }
            }
            if let line = fit(region, width: width, height: height, magnitude: magnitude) {
                found.append(line)
            }
        }
        return found
    }

    /// The region's principal axis, weighted by gradient strength, and its extent along it.
    private static func fit(_ region: [Int], width: Int, height: Int, magnitude: [Float]) -> PerspectiveLine? {
        guard Float(region.count) >= minimumLength else { return nil }
        var total: Float = 0
        var centre = SIMD2<Float>.zero
        for index in region {
            let w = magnitude[index]
            // The cell's centre, half a pixel right and down.
            centre += w * SIMD2(Float(index % width) + 1, Float(index / width) + 1)
            total += w
        }
        centre /= total
        var (xx, xy, yy): (Float, Float, Float) = (0, 0, 0)
        for index in region {
            let w = magnitude[index]
            let d = SIMD2(Float(index % width) + 1, Float(index / width) + 1) - centre
            xx += w * d.x * d.x
            xy += w * d.x * d.y
            yy += w * d.y * d.y
        }
        // The larger eigenvector of the inertia matrix.
        let theta = 0.5 * atan2(2 * xy, xx - yy)
        let axis = SIMD2(cos(theta), sin(theta))
        let normal = SIMD2(-axis.y, axis.x)
        var (low, high, nearest, farthest): (Float, Float, Float, Float) = (
            .infinity,
            -.infinity,
            .infinity,
            -.infinity,
        )
        for index in region {
            let d = SIMD2(Float(index % width) + 1, Float(index / width) + 1) - centre
            let along = simd_dot(d, axis), across = simd_dot(d, normal)
            low = min(low, along)
            high = max(high, along)
            nearest = min(nearest, across)
            farthest = max(farthest, across)
        }
        let length = high - low + 1
        let thickness = farthest - nearest + 1
        guard length >= minimumLength, Float(region.count) / (length * thickness) >= minimumDensity,
              length >= 4 * thickness
        else { return nil }
        let start = centre + low * axis, end = centre + high * axis
        func point(_ p: SIMD2<Float>) -> MaskPoint {
            // Bitmap rows run downwards; stored photo coordinates run upwards.
            MaskPoint(Double(p.x) / Double(width), 1 - Double(p.y) / Double(height))
        }
        let contrast = total / Float(region.count)
        return PerspectiveLine(start: point(start), end: point(end), vertical: abs(end.y-start.y) > abs(end.x-start.x),
                               weight: Double(length * min(contrast / (4 * minimumGradient), 1)))
    }
}
