import CoreGraphics
import Foundation
import simd

enum UprightMode: String, CaseIterable, Identifiable {
    case auto, level, vertical, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: L10n.text("geometry.auto", defaultValue: "Auto")
        case .level: L10n.text("geometry.level", defaultValue: "Level")
        case .vertical: L10n.text("geometry.vertical", defaultValue: "Vertical")
        case .full: L10n.text("geometry.full", defaultValue: "Full")
        }
    }
}

struct PerspectiveLine: Equatable {
    var start: MaskPoint
    var end: MaskPoint
    var vertical: Bool
    var weight = 1.0
}

/// Line-angle fitting and conservative fallback inspired by Redlamp's Geometry.swift at
/// 21ff73eb (2026-11-01). Native implementation against our camera-rotation-v2 mapping;
/// no Redlamp transform coefficients or Adobe processing code/data are used.
enum UprightCorrection {
    static func guided(_ lines: [PerspectiveLine], size: CGSize, recipe: EditRecipe, straightenOnly: Bool = false) -> EditRecipe? {
        guard lines.count >= (straightenOnly ? 1 : 2), usable(lines, size: size) else { return nil }
        let verticals = lines.filter(\.vertical).count
        let free = straightenOnly ? [false, false, true] : [verticals > 0, verticals < lines.count, true]
        guard let result = fit(lines, size: size, recipe: recipe, free: free, robust: false),
              let residual = residuals(result, lines: lines, size: size),
              residual.allSatisfy({ abs($0) < 0.25 * .pi / 180 }),
              (try? PhotoGeometry(size: size, recipe: result)) != nil else { return nil }
        return result
    }

    static func automatic(_ mode: UprightMode, lines: [PerspectiveLine], size: CGSize, recipe: EditRecipe) -> EditRecipe? {
        let valid = lines.filter { usable([$0], size: size) }
        guard !valid.isEmpty else { return nil }
        var base = recipe
        base.perspective.horizontal = 0; base.perspective.vertical = 0; base.straightenDegrees = 0
        guard let angles = residuals(base, lines: valid, size: size) else { return nil }
        let candidates = zip(valid, angles).filter { abs($0.1) < .pi / 6 }.map(\.0)
        func solve(_ selected: [PerspectiveLine], free: [Bool]) -> EditRecipe? {
            let total = selected.reduce(0) { $0 + $1.weight }
            guard total >= 100, let result = fit(selected, size: size, recipe: base, free: free, robust: true),
                  abs(result.straightenDegrees) < 15, abs(result.perspective.vertical) < 99,
                  abs(result.perspective.horizontal) < 99,
                  let errors = residuals(result, lines: selected, size: size) else { return nil }
            let agreed = zip(selected, errors).filter { abs($0.1) < 1.5 * .pi / 180 }.map(\.0)
            guard agreed.reduce(0, { $0 + $1.weight }) >= max(100, total * 0.65) else { return nil }
            for vertical in [true, false] where free[vertical ? 0 : 1] {
                let family = agreed.filter { $0.vertical == vertical }
                var uncut = base; uncut.crop = Crop(); uncut.perspective.constrainCrop = false
                guard let geometry = try? PhotoGeometry(size: size, recipe: uncut) else { return nil }
                let positions = family.compactMap { line -> Double? in
                    let point = CGPoint(x: (line.start.x+line.end.x)/2*size.width, y: (line.start.y+line.end.y)/2*size.height)
                    guard let p = geometry.transform.point(point) else { return nil }
                    return vertical ? p.x/geometry.output.width : p.y/geometry.output.height
                }
                guard family.count >= 2, (positions.max() ?? 0) - (positions.min() ?? 0) >= 0.2 else { return nil }
            }
            return (try? PhotoGeometry(size: size, recipe: result)) == nil ? nil : result
        }
        let level = solve(candidates, free: [false, false, true])
        if mode == .level { return level }
        let vertical = solve(candidates.filter(\.vertical), free: [true, false, true]) ?? level
        if mode == .vertical { return vertical }
        let full = solve(candidates, free: [true, true, true]) ?? vertical
        guard mode == .auto, var result = full else { return full }
        // Auto eases strong perspective to preserve framing. This is an algorithm policy,
        // not a photo-quality acceptance threshold; the existing crop is never replaced.
        var entire = result; entire.crop = Crop(); entire.perspective.constrainCrop = true
        let canvasArea = size.width * size.height
        if let geometry = try? PhotoGeometry(size: size, recipe: entire), geometry.output.width * geometry.output.height < canvasArea * 0.8 {
            let original = result.perspective
            for step in stride(from: 0.9, through: 0.0, by: -0.1) {
                entire.perspective.horizontal = original.horizontal * step
                entire.perspective.vertical = original.vertical * step
                if let g = try? PhotoGeometry(size: size, recipe: entire), g.output.width * g.output.height >= canvasArea * 0.8 {
                    result.perspective.horizontal = entire.perspective.horizontal
                    result.perspective.vertical = entire.perspective.vertical
                    break
                }
            }
        }
        return result
    }

    static func classified(start: MaskPoint, end: MaskPoint, weight: Double = 1, size: CGSize, recipe: EditRecipe) -> PerspectiveLine? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              [start.x, start.y, end.x, end.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              weight.isFinite, weight > 0,
              hypot(end.x - start.x, end.y - start.y) > 1e-9 else { return nil }
        var source = recipe; source.crop = Crop(); source.perspective.constrainCrop = false
        guard let geometry = try? PhotoGeometry(size: size, recipe: source),
              let a = geometry.transform.point(CGPoint(x: start.x * size.width, y: start.y * size.height)),
              let b = geometry.transform.point(CGPoint(x: end.x * size.width, y: end.y * size.height)) else { return nil }
        return PerspectiveLine(start: start, end: end, vertical: abs(b.y-a.y) > abs(b.x-a.x), weight: weight)
    }

    private static func usable(_ lines: [PerspectiveLine], size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite && !lines.isEmpty && lines.allSatisfy {
            [$0.start.x, $0.start.y, $0.end.x, $0.end.y].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && hypot($0.end.x-$0.start.x, $0.end.y-$0.start.y) > 0.01 && $0.weight.isFinite && $0.weight > 0
        }
    }

    private static func residuals(_ recipe: EditRecipe, lines: [PerspectiveLine], size: CGSize) -> [Double]? {
        var uncut = recipe; uncut.crop = Crop(); uncut.perspective.constrainCrop = false
        guard let geometry = try? PhotoGeometry(size: size, recipe: uncut) else { return nil }
        var result = [Double]()
        for line in lines {
            guard let a = geometry.transform.point(CGPoint(x: line.start.x*size.width, y: line.start.y*size.height)),
                  let b = geometry.transform.point(CGPoint(x: line.end.x*size.width, y: line.end.y*size.height)) else { return nil }
            let dx = b.x-a.x, dy = b.y-a.y
            guard hypot(dx, dy) > 1e-6 else { return nil }
            let angle = line.vertical ? atan2(dx, dy) : atan2(dy, dx)
            result.append(remainder(angle, .pi))
        }
        return result
    }

    private static func fit(_ lines: [PerspectiveLine], size: CGSize, recipe: EditRecipe, free: [Bool], robust: Bool) -> EditRecipe? {
        var p = SIMD3(recipe.perspective.vertical, recipe.perspective.horizontal, recipe.straightenDegrees)
        let initial = p
        func candidate(_ p: SIMD3<Double>) -> EditRecipe {
            var r = recipe
            r.perspective.vertical = min(100, max(-100, p.x)); r.perspective.horizontal = min(100, max(-100, p.y))
            r.straightenDegrees = min(45, max(-45, p.z))
            return r
        }
        // Regularise undetermined degrees towards the user's existing parameters.
        for _ in 0..<40 {
            guard let r = residuals(candidate(p), lines: lines, size: size) else { return nil }
            var columns = [[Double]]()
            for axis in 0..<3 {
                var moved = p; moved[axis] += 0.001
                guard let shifted = residuals(candidate(moved), lines: lines, size: size) else { return nil }
                columns.append(zip(shifted, r).map { remainder($0-$1, .pi)/0.001 })
            }
            let weights = zip(lines, r).map { line, error in line.weight * (robust ? 1/(1+pow(error/(.pi/180),2)) : 1) }
            let damping = 1e-9
            var matrix = simd_double3x3(diagonal: SIMD3(repeating: damping))
            var gradient = (initial-p)*damping
            for i in 0..<3 {
                if !free[i] { matrix[i][i] = 1; gradient[i] = 0; continue }
                for j in 0..<3 where free[j] {
                    for k in r.indices { matrix[j][i] += columns[i][k]*columns[j][k]*weights[k] }
                }
                for k in r.indices { gradient[i] -= columns[i][k]*r[k]*weights[k] }
            }
            let delta = matrix.inverse * gradient
            guard delta.x.isFinite, delta.y.isFinite, delta.z.isFinite else { return nil }
            p += delta
            p = SIMD3(min(100,max(-100,p.x)), min(100,max(-100,p.y)), min(45,max(-45,p.z)))
            if simd_length(delta) < 1e-6 { break }
        }
        return candidate(p)
    }
}
