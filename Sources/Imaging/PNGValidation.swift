import Foundation
import CoreGraphics
import zlib

/// ImageIO can recover pixels from damaged/animated files. Import accepts only a
/// complete static datastream: CRCs, chunk ordering, zlib checksum and scanlines.
/// Pixel reconstruction and ICC conversion remain ImageIO/Core Image's job.
enum PNGValidation {
    @discardableResult static func validate(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let invalid = LRCError(L10n.text("app.pngDataIsDamagedOrIncompleteImportDevelopmentStopped", defaultValue: "PNG data is damaged or incomplete. Import / development stopped"))
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw invalid }
        func number(_ p: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(data[p + $1]) } }
        var position = 8, width = 0, height = 0, depth = 0, color = 0, interlace = 0
        var seen = Set<String>(), paletteCount = 0, idatEnded = false, compressed = Data()
        while position < data.count {
            try Task.checkCancellation()
            guard data.count - position >= 12 else { throw invalid }
            let length = number(position), start = position + 8, end = start + length
            guard length <= 0x7fff_ffff, length <= data.count - position - 12 else { throw invalid }
            let typeBytes = data[(position + 4)..<start]
            guard typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  typeBytes[typeBytes.startIndex + 2] & 32 == 0 else { throw invalid }
            let type = String(decoding: typeBytes, as: UTF8.self)
            let crc = data.withUnsafeBytes { raw in
                crc32(0, raw.bindMemory(to: Bytef.self).baseAddress!.advanced(by: position + 4), uInt(length + 4))
            }
            guard crc == uLong(number(end)), !seen.isEmpty || type == "IHDR" else { throw invalid }
            if ["acTL", "fcTL", "fdAT"].contains(type) { throw LRCError(L10n.text("app.animatedAndMultiFramePNGFilesAreNotSupported", defaultValue: "Animated and multi-frame PNG files are not supported")) }
            if type != "IDAT", seen.contains("IDAT") { idatEnded = true }
            switch type {
            case "IHDR":
                guard !seen.contains(type), length == 13 else { throw invalid }
                width = number(start); height = number(start + 4)
                depth = Int(data[start + 8]); color = Int(data[start + 9]); interlace = Int(data[start + 12])
                guard width > 0, height > 0, width <= 0x7fff_ffff, height <= 0x7fff_ffff,
                      data[start + 10] == 0, data[start + 11] == 0, interlace <= 1 else { throw invalid }
                // Same pre-allocation size gate as png_codec::decode/check_size
                // (LightCraft 4f0b110), using the native pipeline's existing cap.
                try PhotoGeometry.checkSize(CGSize(width:width,height:height))
                guard [8, 16].contains(depth), [0, 2, 3, 4, 6].contains(color), color != 3 || depth == 8 else {
                    throw LRCError(L10n.text("app.supportedPNGStatic816BitGrayscaleGrayscaleAlpha", defaultValue: "Supported PNG: static 8/16-bit grayscale, grayscale-alpha, RGB/RGBA, and 8-bit indexed color"))
                }
            case "PLTE":
                guard !seen.contains(type), !seen.contains("IDAT"), !seen.contains("tRNS"),
                      color != 0, color != 4, length > 0, length <= 768, length % 3 == 0 else { throw invalid }
                paletteCount = length / 3
            case "tRNS":
                guard !seen.contains(type), !seen.contains("IDAT") else { throw invalid }
                guard (color == 0 && length == 2) || (color == 2 && length == 6) ||
                        (color == 3 && paletteCount > 0 && length > 0 && length <= paletteCount) else { throw invalid }
                if color == 0 || color == 2 {
                    for p in stride(from: start, to: end, by: 2) {
                        guard Int(data[p]) * 256 + Int(data[p + 1]) < (1 << depth) else { throw invalid }
                    }
                }
            case "iCCP":
                guard !seen.contains(type), !seen.contains("PLTE"), !seen.contains("IDAT"), !seen.contains("sRGB"),
                      let zero = data[start..<end].firstIndex(of: 0), (1...79).contains(zero - start),
                      zero + 2 < end, data[zero + 1] == 0 else { throw invalid }
                let profile = try inflateData(Data(data[(zero + 2)..<end]), limit: 16 * 1024 * 1024)
                guard let space = CGColorSpace(iccData: profile as CFData),
                      space.model == (color == 0 || color == 4 ? .monochrome : .rgb) else { throw LRCError(L10n.text("app.thePNGICCProfileIsInvalidOrDoesNot", defaultValue: "The PNG ICC profile is invalid or does not match the image color model")) }
            case "sRGB":
                guard !seen.contains(type), !seen.contains("iCCP"), !seen.contains("PLTE"), !seen.contains("IDAT"),
                      length == 1, data[start] <= 3 else { throw invalid }
            case "IDAT":
                guard !idatEnded, color != 3 || paletteCount > 0 else { throw invalid }
                guard compressed.count <= Int(UInt32.max) - length else { throw invalid }
                compressed.append(data[start..<end])
            case "IEND":
                guard length == 0, seen.contains("IDAT"), end + 4 == data.count else { throw invalid }
                let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][color]!
                // Adam7 passes; empty passes have no filter byte or scanlines.
                let passes = interlace == 0 ? [(0, 0, 1, 1)] :
                    [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
                let rows = passes.compactMap { x, y, dx, dy -> (Int, Int)? in
                    guard width > x, height > y else { return nil }
                    return (((width - x + dx - 1) / dx * channels * depth + 7) / 8, (height - y + dy - 1) / dy)
                }
                var pass = 0, row = 0, column = 0
                try inflateBytes(compressed) { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        guard pass < rows.count else { throw invalid }
                        if column == 0, bytes[offset] > 4 { throw invalid }
                        let count = min(bytes.count - offset, rows[pass].0 + 1 - column)
                        column += count; offset += count
                        if column == rows[pass].0 + 1 {
                            column = 0; row += 1
                            if row == rows[pass].1 { pass += 1; row = 0 }
                        }
                    }
                }
                guard pass == rows.count, column == 0 else { throw invalid }
                return seen.contains("iCCP")
            default:
                guard typeBytes[typeBytes.startIndex] & 32 != 0 else { throw LRCError(L10n.text("app.thePNGContainsAnUnsupportedCriticalChunk", defaultValue: "The PNG contains an unsupported critical chunk")) }
            }
            seen.insert(type); position = end + 4
        }
        throw invalid
    }

    private static func inflateData(_ data: Data, limit: Int) throws -> Data {
        var result = Data()
        try inflateBytes(data) { bytes in
            guard bytes.count <= limit - result.count else { throw LRCError(L10n.text("app.thePNGICCProfileIsTooLarge", defaultValue: "The PNG ICC profile is too large")) }
            result.append(contentsOf: bytes)
        }
        return result
    }
    private static func inflateBytes(_ data: Data, consume: (UnsafeBufferPointer<UInt8>) throws -> Void) throws {
        let invalid = LRCError(L10n.text("app.compressedPNGDataIsDamagedIncompleteOrHasAn", defaultValue: "Compressed PNG data is damaged, incomplete, or has an incorrect length"))
        guard !data.isEmpty, data.count <= UInt32.max else { throw invalid }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid }
        defer { inflateEnd(&stream) }
        try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                try Task.checkCancellation()
                let status = try buffer.withUnsafeMutableBufferPointer { output -> Int32 in
                    stream.next_out = output.baseAddress!; stream.avail_out = uInt(output.count)
                    let code = inflate(&stream, Z_NO_FLUSH)
                    try consume(UnsafeBufferPointer(start: output.baseAddress!, count: output.count - Int(stream.avail_out)))
                    return code
                }
                if status == Z_STREAM_END { guard stream.avail_in == 0 else { throw invalid }; break }
                guard status == Z_OK, stream.avail_in > 0 || stream.avail_out == 0 else { throw invalid }
            }
        }
    }
}
