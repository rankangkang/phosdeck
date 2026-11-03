import CoreImage
import CryptoKit
import Foundation

/// Colour corrections from synthetic image comparisons; see LR-EXPOSURE-001.
/// Tables store signed linear-sRGB corrections; clipping belongs to the output.
enum RasterExposureColour {
    static let dimension = 65
    private final class Resources {}
    private struct Entry: Decodable {
        let index: Int
        let axisPower: Int
        let offset: Int
        let compressedBytes: Int
        let rawBytes: Int
        let sha256: String
    }
    private struct Header: Decodable {
        let version: Int
        let dimension: Int
        let denominator: Int
        let rows: [Entry]
    }
    private struct Archive {
        let data: Data
        let payload: Int
        let rows: [Entry]
    }
    struct Row {
        let image: CIImage
        let values: Data
        let axisPower: Int
    }
    private static let archive: Result<Archive, Error> = Result {
        guard let url = Bundle(for: Resources.self).url(forResource: "raster-exposure-colour-v4", withExtension: "bin") else {
            throw LRCError(L10n.text("app.rasterExposureCalibrationDataIsMissing", defaultValue: "Raster exposure calibration data is missing"))
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12, data.count <= 64 * 1024 * 1024,
              data.prefix(8) == Data("OMLRCEX4".utf8) else { throw LRCError(L10n.text("app.invalidExposureCalibrationFormat", defaultValue: "Invalid exposure calibration format")) }
        let length = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
        guard (1...65536).contains(length), 12 + length <= data.count else { throw LRCError(L10n.text("app.invalidExposureCalibrationHeader", defaultValue: "Invalid exposure calibration header")) }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + length)))
        guard header.version == 4, header.dimension == dimension, header.denominator == 65535,
              header.rows.count == 41 else { throw LRCError(L10n.text("app.unsupportedExposureCalibrationData", defaultValue: "Unsupported exposure calibration data")) }
        var offset = 0
        for (index, row) in header.rows.enumerated() {
            guard row.index == index, row.axisPower == (index > 20 ? 2 : 1), row.offset == offset,
                  row.rawBytes == dimension * dimension * dimension * 6,
                  (1...(row.rawBytes * 2)).contains(row.compressedBytes),
                  row.compressedBytes <= data.count - (12 + length) - offset,
                  row.sha256.count == 64, row.sha256.allSatisfy(\.isHexDigit) else {
                throw LRCError(L10n.text("app.invalidExposureCalibrationRow", defaultValue: "Invalid exposure calibration row"))
            }
            offset += row.compressedBytes
        }
        guard 12 + length + offset == data.count else { throw LRCError(L10n.text("app.exposureCalibrationDataLengthMismatch", defaultValue: "Exposure calibration data length mismatch")) }
        return Archive(data: data, payload: 12 + length, rows: header.rows)
    }
    // Only the two adjacent quarter-stop rows are cached. Existing CI graphs retain
    // their immutable images until the render finishes; no mutable texture reuse.
    private final class Cache {
        let lock = NSLock()
        var rows: [Int: Row] = [:]
        var recent: [Int] = []
    }
    private static let cache = Cache()
    static func row(_ index: Int) throws -> Row {
        guard (0...40).contains(index) else { throw LRCError(L10n.text("app.invalidExposureCalibrationIndex", defaultValue: "Invalid exposure calibration index")) }
        let source = try archive.get()
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let row = cache.rows[index] {
            cache.recent.removeAll { $0 == index }; cache.recent.append(index)
            return row
        }
        let entry = source.rows[index], start = source.payload + entry.offset
        let raw = try (source.data.subdata(in: start..<(start + entry.compressedBytes)) as NSData).decompressed(using: .lzfse) as Data
        guard raw.count == entry.rawBytes,
              SHA256.hash(data: raw).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
            throw LRCError(L10n.text("app.exposureCalibrationDataVerificationFailed", defaultValue: "Exposure calibration data verification failed"))
        }
        let count = dimension * dimension * dimension
        var pixels = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: count)
        raw.withUnsafeBytes { bytes in
            for i in 0..<count { for c in 0..<3 {
                let v = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: (i * 3 + c) * 2, as: Int16.self))
                pixels[i][c] = Float(v) / 65535
            } }
        }
        let values = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: values, bytesPerRow: dimension * dimension * 16,
            size: CGSize(width: dimension * dimension, height: dimension), format: .RGBAf, colorSpace: nil)
        let row = Row(image: image, values: values, axisPower: entry.axisPower)
        cache.rows[index] = row; cache.recent.append(index)
        while cache.recent.count > 2 { cache.rows.removeValue(forKey: cache.recent.removeFirst()) }
        return row
    }
    static func position(_ ev: Double) -> (lo: Int, hi: Int, weight: Double) {
        let p = min(40, max(0, (ev + 5) * 4)), lo = min(39, Int(p))
        return (lo, lo + 1, p - Double(lo))
    }
    private static func axis(_ encoded: Double, power: Int) -> (Int, Double) {
        let x = min(1, max(0, encoded)), n = Double(dimension - 1)
        var i = min(dimension - 2, Int(floor(pow(x, 1 / Double(power)) * n)))
        func anchor(_ k: Int) -> Double { floor(pow(Double(k) / n, Double(power)) * 65535 + 0.5) / 65535 }
        if x < anchor(i), i > 0 { i -= 1 }
        if x > anchor(i + 1), i < dimension - 2 { i += 1 }
        let a = anchor(i), b = anchor(i + 1)
        return (i, min(1, max(0, (x - a) / (b - a))))
    }
    static func sample(_ encoded: SIMD3<Double>, row: Row) -> SIMD3<Double> {
        let (r, u) = axis(encoded.x, power: row.axisPower)
        let (g, v) = axis(encoded.y, power: row.axisPower)
        let (b, w) = axis(encoded.z, power: row.axisPower)
        return row.values.withUnsafeBytes { bytes in
            var result = SIMD3<Double>.zero
            for z in 0...1 { for y in 0...1 { for x in 0...1 {
                let i = ((b + z) * dimension * dimension + (g + y) * dimension + r + x) * 16
                let c = bytes.loadUnaligned(fromByteOffset: i, as: SIMD4<Float>.self)
                let weight = (x == 0 ? 1 - u : u) * (y == 0 ? 1 - v : v) * (z == 0 ? 1 - w : w)
                result += SIMD3(Double(c.x), Double(c.y), Double(c.z)) * weight
            } } }
            return result
        }
    }
    static func correction(_ encoded: SIMD3<Double>, ev: Double) throws -> SIMD3<Double> {
        let p = position(ev), low = try row(p.lo)
        let a = sample(encoded, row: low)
        guard p.weight != 0 else { return a }
        let b = sample(encoded, row: try row(p.hi))
        return a + (b - a) * p.weight
    }
    static func apply(_ input: CIImage, base: CIImage, ev: Double) throws -> CIImage {
        let p = position(ev), low = try row(p.lo), high = try row(p.weight == 0 ? p.lo : p.hi)
        return try SpatialDevelopPipeline.rasterColour(input, base: base, low: low.image, high: high.image,
            powers: CIVector(x: Double(low.axisPower), y: Double(high.axisPower)), weight: p.weight)
    }
}
