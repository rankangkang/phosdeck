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

    static func cropAngle(in properties: [String: [String]]) -> Double {
        properties["CropAngle"].map { $0.first.flatMap(Double.init) ?? .nan } ?? 0
    }

    static func cameraLensCorrection(in properties: [String: [String]]) -> Bool? {
        guard properties["LensProfileName"] == ["Camera Settings"],
              properties["LensProfileSetup"] == ["LensDefaults"] else { return nil }
        let scales = ["LensProfileDistortionScale", "LensProfileChromaticAberrationScale", "LensProfileVignettingScale"]
        guard scales.allSatisfy({ key in
            properties[key].map { $0.count == 1 && Double($0[0]) == 100 } ?? true
        }) else { return nil }
        switch properties["LensProfileEnable"]?.first {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    /// Map Lightroom's stored-image orientation to a transform after native EXIF decoding.
    static func applyGeometry(_ properties: inout [String: [String]], orientation: String, photo: Photo,
                              sourceSize: CGSize?, recipe: inout EditRecipe) -> [String] {
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
        let cropKeys = edges + ["CropAngle", "HasCrop"]
        if ["false", "0"].contains(properties["HasCrop"]?.first?.lowercased() ?? "") {
            for key in cropKeys { properties.removeValue(forKey: key) }
            return notes
        }
        let angle = cropAngle(in: properties)
        guard edges.contains(where: { properties[$0] != nil }) || angle != 0 else { return notes }
        let values = zip(edges, [0.0, 0.0, 1.0, 1.0]).map { key, fallback in
            properties[key].map { $0.first.flatMap(Double.init) ?? .nan } ?? fallback
        }
        guard (-45...45).contains(angle), values.allSatisfy({ (0...1).contains($0) }),
              values[0] < values[2], values[1] < values[3] else { return notes + ["CropAngle / Crop"] }
        var a = CGPoint(x: values[0], y: values[1]), b = CGPoint(x: values[2], y: values[3])
        if angle != 0 {
            guard notes.isEmpty, let size = sourceSize, (try? PhotoGeometry.checkSize(size)) != nil else {
                return notes + ["CropAngle / Crop"]
            }
            let stored = source >= 4 ? CGSize(width: size.height, height: size.width) : size
            let rotation = CropPreviewGeometry.transform(size: stored, degrees: angle, autoZoom: false)
            // The stored edges are opposing corners in the unrotated image.
            // Rotate in pixels before applying the saved orientation.
            func rotated(_ point: CGPoint) -> CGPoint {
                let p = CGPoint(x: point.x * stored.width, y: (1 - point.y) * stored.height).applying(rotation)
                return CGPoint(x: p.x / stored.width, y: 1 - p.y / stored.height)
            }
            a = rotated(a); b = rotated(b)
        }
        a = oriented(a, target); b = oriented(b, target)
        let left = min(a.x, b.x), right = max(a.x, b.x), top = min(a.y, b.y), bottom = max(a.y, b.y)
        guard left >= 0, top >= 0, right <= 1, bottom <= 1, right > left, bottom > top else {
            return notes + ["CropAngle / Crop"]
        }
        recipe.crop = recipe.cropFromDisplay(Crop(x: left, y: 1 - bottom, width: right - left, height: bottom - top))
        if angle != 0 {
            // EXIF reflections reverse angle handedness. The relative flip is applied after cropping.
            recipe.straightenDegrees = [1, 3, 4, 6].contains(source) ? -angle : angle
            recipe.straightenAtSourceScale = true
        }
        for key in cropKeys { properties.removeValue(forKey: key) }
        return notes
    }

    static func caption(xmp: Data) -> String? {
        guard !xmp.isEmpty, xmp.count <= XMPPresetReader.maximumBytes else { return nil }
        let xml: Data
        if let text = String(data: xmp, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") { xml = xmp }
        else if let output = unzip(xmp) { xml = output }
        else { return nil }
        guard let text = String(data: xml, encoding: .utf8), text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let metadata = CGImageMetadataCreateFromXMPData(xml as CFData) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(metadata, nil, "dc:description" as CFString) as String?
    }

    static func unzip(_ packet: Data) -> Data? {
        guard packet.count > 4, packet.count <= XMPPresetReader.maximumBytes else { return nil }
        let length = packet.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= XMPPresetReader.maximumBytes else { return nil }
        var output = Data(count: length)
        var written = uLongf(length)
        let status = output.withUnsafeMutableBytes { dst in
            packet.withUnsafeBytes { src in
                uncompress(dst.bindMemory(to: UInt8.self).baseAddress, &written,
                           src.bindMemory(to: UInt8.self).baseAddress?.advanced(by: 4), uLong(packet.count - 4))
            }
        }
        return status == Z_OK && written == length ? output : nil
    }

    private static var invalid: LRCError {
        LRCError(L10n.text("lightroom.invalidSettings", defaultValue: "Unsupported Lightroom develop settings format."))
    }
}
