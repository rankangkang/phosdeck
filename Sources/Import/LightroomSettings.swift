import Foundation
import ImageIO
import zlib

/// Lightroom stores a serialized Lua table. Read the values as data and never run Lua.
enum LightroomSettings {
    private enum Token: Equatable {
        case mark(UInt8), word(String), value(String)
    }

    static func properties(_ text: String) throws -> [String: [String]] {
        let bytes = Array(text.utf8)
        guard bytes.count <= XMPPresetReader.maximumBytes else { throw invalid }
        var index = 0
        func next() throws -> Token? {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            guard index < bytes.count else { return nil }
            let first = bytes[index]
            index += 1
            if [123, 125, 91, 93, 61, 44, 59].contains(first) { return .mark(first) }
            if first == 34 || first == 39 {
                var value: [UInt8] = []
                while index < bytes.count {
                    let byte = bytes[index]; index += 1
                    if byte == first { return .value(String(decoding: value, as: UTF8.self)) }
                    if byte == 92 {
                        guard index < bytes.count else { throw invalid }
                        value.append(bytes[index]); index += 1
                    } else { value.append(byte) }
                }
                throw invalid
            }
            let start = index - 1
            while index < bytes.count, ![9, 10, 13, 32, 123, 125, 91, 93, 61, 44, 59, 34, 39].contains(bytes[index]) { index += 1 }
            return .word(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        var token = try next()
        if case .word(let word) = token {
            if word != "return" { guard try next() == .mark(61) else { throw invalid } }
            token = try next()
        }
        guard token == .mark(123) else { throw invalid }
        var properties: [String: [String]] = [:]
        while let keyToken = try next(), keyToken != .mark(125) {
            let key: String
            switch keyToken {
            case .word(let name): key = name
            case .mark(91):
                guard case .value(let name) = try next(), try next() == .mark(93) else { throw invalid }
                key = name
            default: throw invalid
            }
            guard try next() == .mark(61), let value = try next() else { throw invalid }
            switch value {
            case .word(let value), .value(let value):
                if value != "nil", Double(value) != -999999 { properties[key] = [value] }
                else if value != "nil" { properties["Deferred " + key] = [] }
            case .mark(123):
                var depth = 1
                var values: [String] = []
                let curve = XMPPresetSettings.curveFields.contains(key)
                while depth > 0 {
                    guard let element = try next() else { throw invalid }
                    switch element {
                    case .mark(123): depth += 1
                    case .mark(125): depth -= 1
                    case .word(let value), .value(let value):
                        if depth == 1, curve, values.count < 64 { values.append(value) }
                    default: break
                    }
                    guard depth <= 64 else { throw invalid }
                }
                if curve, values.count.isMultiple(of: 2), values.allSatisfy({ Double($0) != nil }) {
                    properties[key] = stride(from: 0, to: values.count, by: 2).map { values[$0] + ", " + values[$0 + 1] }
                } else { properties[key] = [] }
            default: throw invalid
            }
            switch try next() {
            case .mark(44), .mark(59): continue
            case .mark(125):
                guard try next() == nil else { throw invalid }
                return properties
            default: throw invalid
            }
        }
        guard index > 0, bytes[index - 1] == 125, try next() == nil else { throw invalid }
        return properties
    }

    /// Map Lightroom's stored-image orientation to a transform after native EXIF decoding.
    static func applyGeometry(_ properties: inout [String: [String]], orientation: String, photo: Photo,
                              recipe: inout EditRecipe) -> [String] {
        let orientations = ["AB", "BA", "CD", "DC", "AD", "BC", "CB", "DA"]
        let source = min(8, max(1, photo.details?.orientation ?? 1)) - 1
        let target = orientations.firstIndex(of: orientation) ?? source
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
        func turn(_ point: CGPoint, _ turns: Int) -> CGPoint {
            switch turns {
            case 1: CGPoint(x: 1 - point.y, y: point.x)
            case 2: CGPoint(x: 1 - point.x, y: 1 - point.y)
            case 3: CGPoint(x: point.y, y: 1 - point.x)
            default: point
            }
        }
        func oriented(_ point: CGPoint, _ index: Int) -> CGPoint {
            let rotations = [0, 0, 2, 2, 1, 1, 3, 3]
            let rotated = turn(point, rotations[index])
            return [1, 3, 4, 6].contains(index) ? CGPoint(x: 1 - rotated.x, y: rotated.y) : rotated
        }
        for turns in 0..<4 {
            for mirror in [false, true] where points.allSatisfy({ point in
                let rotated = turn(oriented(point, source), turns)
                let mapped = mirror ? CGPoint(x: 1 - rotated.x, y: rotated.y) : rotated
                return mapped == oriented(point, target)
            }) {
                recipe.quarterTurns = turns
                recipe.flipHorizontal = mirror
            }
        }
        var notes = orientation.isEmpty || orientations.contains(orientation) ? [] : ["Orientation \(orientation)"]
        let edges = ["CropLeft", "CropTop", "CropRight", "CropBottom"]
        let angle = properties["CropAngle"].map { $0.first.flatMap(Double.init) ?? .nan } ?? 0
        guard edges.contains(where: { properties[$0] != nil }) || angle != 0 else { return notes }
        let values = zip(edges, [0.0, 0.0, 1.0, 1.0]).map { key, fallback in
            properties[key].map { $0.first.flatMap(Double.init) ?? .nan } ?? fallback
        }
        if angle == 0, values.allSatisfy({ (0...1).contains($0) }), values[0] < values[2], values[1] < values[3] {
            let a = oriented(CGPoint(x: values[0], y: values[1]), target)
            let b = oriented(CGPoint(x: values[2], y: values[3]), target)
            recipe.crop = recipe.cropFromDisplay(Crop(x: min(a.x, b.x), y: 1 - max(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
            for key in edges + ["CropAngle", "HasCrop"] { properties.removeValue(forKey: key) }
        } else { notes.append("CropAngle / Crop") }
        return notes
    }

    static func caption(xmp: Data) -> String? {
        guard !xmp.isEmpty, xmp.count <= XMPPresetReader.maximumBytes else { return nil }
        let xml: Data
        if let text = String(data: xmp, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { xml = xmp }
        else {
            guard xmp.count > 4 else { return nil }
            let length = xmp.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= XMPPresetReader.maximumBytes else { return nil }
            var output = Data(count: length)
            var written = uLongf(length)
            let status = output.withUnsafeMutableBytes { dst in
                xmp.withUnsafeBytes { src in
                    uncompress(dst.bindMemory(to: UInt8.self).baseAddress, &written,
                               src.bindMemory(to: UInt8.self).baseAddress?.advanced(by: 4), uLong(xmp.count - 4))
                }
            }
            guard status == Z_OK, written == length else { return nil }
            xml = output
        }
        guard let text = String(data: xml, encoding: .utf8), text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let metadata = CGImageMetadataCreateFromXMPData(xml as CFData) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description" as CFString) as String?
    }

    private static var invalid: LRCError {
        LRCError(L10n.text("lightroom.invalidSettings", defaultValue: "Unsupported Lightroom develop settings format."))
    }
}
