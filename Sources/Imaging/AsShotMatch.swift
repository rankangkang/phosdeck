import CoreImage
import ImageIO
import simd

/// Version 1 derives a bounded per-channel curve from the capture preview and a
/// pristine RAW decode. The recipe stores the mode so pasted edits fit the destination.
struct AsShotMatch {
    let base: CameraLookSelection?
    var bend = SIMD3<Float>.zero

    static func resolve(url: URL, decoder: String, library: CameraLookLibrary, context: CIContext) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Self(base: nil) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        var metadata = props
        if let style = sonyStyle(url: url) { metadata["{PictureStyle}"] = ["CreativeLook": style] }
        let identified = fujiLook(url: url) ?? baseLook(properties: metadata)
        let base = identified.flatMap { library.entry(for: $0)?.selection }
        var result = Self(base: base)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256]
        guard let jpeg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              min(jpeg.width, jpeg.height) >= 64 else { return result }
        let raw = try PhotoFileType.rawFilter(url)
        raw.decoderVersion = CIRAWDecoderVersion(rawValue: decoder)
        raw.scaleFactor = Float(min(1, 256 / max(raw.nativeSize.width, raw.nativeSize.height)))
        raw.isDraftModeEnabled = false
        raw.extendedDynamicRangeAmount = 0
        raw.exposure = 0
        guard let neutral = raw.outputImage else { return result }
        let ratio = neutral.extent.width / neutral.extent.height
        guard abs(log(ratio / (Double(jpeg.width) / Double(jpeg.height)))) < 0.035 else { return result }
        let baseline = try CameraLookPipeline.apply(neutral, selection: base, library: library)
        result.bend = fit(grid(baseline, context), grid(CIImage(cgImage: jpeg), context))
        return result
    }

    static func baseLook(properties: [String: Any]) -> CameraLookSelection? {
        let tiff = properties["{TIFF}"] as? [String: Any]
        let make = (tiff?["Make"] as? String ?? "").lowercased()
        let style = properties["{PictureStyle}"] as? [String: Any] ?? [:]
        func name(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        for key in ["FilmSimulation", "FilmMode", "CreativeLook", "CreativeStyle", "ColorMode", "PictureStyle"] {
            guard let text = (style[key] as? [Any])?.first as? String ?? style[key] as? String else { continue }
            let label = name(text)
            if make.contains("sony") {
                let names = ["standard":"st","portrait":"pt","neutral":"nt","vivid":"vv","vivid2":"vv2",
                             "film":"fl","instant":"in","softhighkey":"sh","blackwhite":"bw","blackandwhite":"bw","bw":"bw","sepia":"se"]
                if let code = names[label] ?? names.values.first(where: { $0 == label }) {
                    return CameraLookSelection(id: code == "st" ? "sony.st" : "sony-look-bridge.a7rv." + code, version: 1)
                }
            } else if make.contains("fuji") {
                for id in ["provia","velvia","astia","classic-chrome","classic-neg","nostalgic-neg","reala-ace",
                           "pro-neg-hi","pro-neg-std","eterna","eterna-bleach-bypass","acros","acros-r","acros-g",
                           "acros-ye","monochrome","monochrome-r","monochrome-g","monochrome-ye","sepia"] where name(id) == label {
                    return CameraLookSelection(id: "fujifilm." + id, version: 1)
                }
            }
        }
        return nil
    }

    // ARW stores its English style name at Sony MakerNote tag 0xb020.
    private static func sonyStyle(url: URL) -> String? {
        guard url.pathExtension.lowercased() == "arw", let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 1024 * 1024), data.count >= 8 else { return nil }
        guard let tiff = TIFFDirectory(data), let maker = tiff.makerNote else { return nil }
        let makerOffset = tiff.number(maker+8,4)
        guard let style = tiff.entry(makerOffset,0xb020), tiff.number(style+2,2) == 2 else { return nil }
        let size = tiff.number(style+4,4)
        guard (1...64).contains(size) else { return nil }
        let offset = size <= 4 ? style+8 : tiff.number(style+8,4)
        guard offset <= data.count-size else { return nil }
        return String(bytes: data[offset..<offset+size].prefix { $0 != 0 }, encoding: .ascii)
    }

    private struct TIFFDirectory {
        let data: Data
        let little: Bool

        init?(_ data: Data) {
            guard data.count >= 8 else { return nil }
            little = data.starts(with: [73, 73, 42, 0])
            guard little || data.starts(with: [77, 77, 0, 42]) else { return nil }
            self.data = data
        }

        func number(_ offset: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(data[offset + $1]) << (8 * (little ? $1 : size - 1 - $1)) }
        }

        func entry(_ directory: Int, _ tag: Int) -> Int? {
            guard directory >= 8, directory <= data.count - 2 else { return nil }
            let count = number(directory, 2)
            guard count <= (data.count - directory - 2) / 12 else { return nil }
            for index in 0..<count {
                let offset = directory + 2 + index * 12
                if number(offset, 2) == tag { return offset }
            }
            return nil
        }

        var makerNote: Int? {
            guard let exif = entry(number(4, 4), 0x8769),
                  number(exif + 2, 2) == 4, number(exif + 4, 4) == 1 else { return nil }
            return entry(number(exif + 8, 4), 0x927c)
        }
    }

    static func fujiExifLook(_ data: Data) -> CameraLookSelection? {
        guard let tiff = TIFFDirectory(data), let maker = tiff.makerNote,
              tiff.number(maker + 2, 2) == 7 else { return nil }
        let count = tiff.number(maker + 4, 4)
        let offset = tiff.number(maker + 8, 4)
        guard count >= 14, count <= data.count, offset <= data.count - count else { return nil }
        return fujiMakerLook(Data(data[offset..<offset + count]))
    }

    // RAF locates its camera JPEG at offset 84. Read only its bounded header.
    private static func fujiLook(url: URL) -> CameraLookSelection? {
        guard url.pathExtension.lowercased() == "raf", let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 92), header.count == 92,
              header.starts(with: "FUJIFILMCCD-RAW ".utf8) else { return nil }
        func number(_ offset: Int) -> UInt64 {
            header[offset..<offset+4].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        guard (try? file.seek(toOffset: number(84))) != nil,
              let bytes = try? file.read(upToCount: Int(min(number(88), 262144))),
              bytes.starts(with: [0xff, 0xd8]) else { return nil }
        var pos = 2
        while pos + 4 <= bytes.count, bytes[pos] == 0xff {
            let marker = bytes[pos+1]
            let length = Int(bytes[pos+2])*256 + Int(bytes[pos+3])
            guard marker != 0xda, length >= 2, pos+2+length <= bytes.count else { return nil }
            let segment = bytes[(pos+4)..<(pos+2+length)]
            if marker == 0xe1, segment.starts(with: [69,120,105,102,0,0]),
               let look = fujiExifLook(Data(segment.dropFirst(6))) {
                return look
            }
            pos += 2 + length
        }
        return nil
    }

    static func fujiMakerLook(_ data: Data) -> CameraLookSelection? {
        guard data.count >= 14, data.starts(with: "FUJIFILM".utf8) else { return nil }
        func word(_ i: Int) -> Int { Int(data[i]) + Int(data[i+1])*256 }
        let offset = word(8) + word(10)*65536
        guard offset >= 12, offset <= data.count-2 else { return nil }
        let count = word(offset)
        guard count <= (data.count-offset-2)/12 else { return nil }
        var film: String?
        let modes = [0:"provia", 0x120:"astia", 0x200:"velvia", 0x400:"velvia", 0x500:"pro-neg-std",
                     0x501:"pro-neg-hi", 0x600:"classic-chrome", 0x700:"eterna", 0x800:"classic-neg",
                     0x900:"eterna-bleach-bypass", 0xa00:"nostalgic-neg", 0xb00:"reala-ace"]
        let mono = [0x300:"monochrome", 0x301:"monochrome-r", 0x302:"monochrome-ye", 0x303:"monochrome-g",
                    0x310:"sepia", 0x500:"acros", 0x501:"acros-r", 0x502:"acros-ye", 0x503:"acros-g"]
        for n in 0..<count {
            let i = offset+2+n*12
            guard word(i+2) == 3, word(i+4) == 1, word(i+6) == 0 else { continue }
            if word(i) == 0x1003, let id = mono[word(i+8)] { return .init(id: "fujifilm." + id, version: 1) }
            if word(i) == 0x1401 { film = modes[word(i+8)] }
        }
        return film.map { .init(id: "fujifilm." + $0, version: 1) }
    }

    private static let side = 48
    private static func grid(_ image: CIImage, _ context: CIContext) -> [SIMD4<Float>] {
        let extent = image.extent
        let proxy = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .samplingLinear().transformed(by: CGAffineTransform(scaleX: CGFloat(side)/extent.width, y: CGFloat(side)/extent.height))
        var pixels = [SIMD4<Float>](repeating: .zero, count: side * side)
        pixels.withUnsafeMutableBytes {
            context.render(proxy, toBitmap: $0.baseAddress!, rowBytes: side * 16,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        }
        return pixels
    }

    /// Align small crop/offset differences by luminance correlation. Reject unrelated
    /// or flat previews, and retain a correction only if independent blocks improve.
    static func fit(_ input: [SIMD4<Float>], _ target: [SIMD4<Float>]) -> SIMD3<Float> {
        guard input.count == side * side, target.count == input.count else { return .zero }
        func luminance(_ p: SIMD4<Float>) -> Float { sqrt(max(0, p.x * 0.2126 + p.y * 0.7152 + p.z * 0.0722)) }
        let a = input.map(luminance), b = target.map(luminance)
        var best: Float = 0.82
        var alignment: (Float, Int, Int)?
        func index(_ x: Int, _ y: Int, _ scale: Float, _ dx: Int, _ dy: Int) -> Int {
            let center = Float(side - 1) / 2
            let col = Int(((Float(x) - center) * scale + center).rounded()) + dx
            let row = Int(((Float(y) - center) * scale + center).rounded()) + dy
            return row * side + col
        }
        for scale: Float in [1, 0.96, 1.04, 0.92, 1.08] {
            for dy in [0, -1, 1, -2, 2] {
                for dx in [0, -1, 1, -2, 2] {
                    var xSum: Float = 0, ySum: Float = 0, xx: Float = 0, yy: Float = 0, xy: Float = 0
                    var n: Float = 0
                    for y in stride(from: 5, to: side-5, by: 2) {
                        for x in stride(from: 5, to: side-5, by: 2) {
                            let v = a[y * side + x], w = b[index(x,y,scale,dx,dy)]
                            xSum += v; ySum += w; xx += v*v; yy += w*w; xy += v*w; n += 1
                        }
                    }
                    let vx = xx - xSum*xSum/n, vy = yy - ySum*ySum/n
                    guard min(vx,vy) > n * 0.001 else { continue }
                    let score = (xy - xSum*ySum/n) / sqrt(vx*vy)
                    // Prefer the unshifted frame when the scene cannot distinguish alignments.
                    if score > best + 0.003 { best = score; alignment = (scale,dx,dy) }
                }
            }
        }
        guard let (scale,dx,dy) = alignment else { return .zero }
        var numerator = SIMD3<Float>.zero, denominator = SIMD3<Float>.zero
        var liftNumerator = SIMD3<Float>.zero, liftDenominator = SIMD3<Float>.zero
        var validation: [(SIMD3<Float>, SIMD3<Float>)] = []
        var count = 0
        for y in 5..<side-5 {
            for x in 5..<side-5 {
                let i = y*side+x, j = index(x,y,scale,dx,dy)
                guard abs(a[i+1]-a[i-1]) + abs(a[i+side]-a[i-side]) < 0.16,
                      abs(b[j+1]-b[j-1]) + abs(b[j+side]-b[j-side]) < 0.16 else { continue }
                let p = input[i], q = target[j]
                let v = SIMD3(p.x,p.y,p.z), w = SIMD3(q.x,q.y,q.z)
                guard min(v.min(),w.min()) > 0.005, max(v.max(),w.max()) < 0.97 else { continue }
                let basis = v * (1-v)
                if (x/4 + y/4).isMultiple(of: 3) { validation.append((v,w)); continue }
                numerator += basis * (w-v); denominator += basis*basis
                // Solve the highlight-preserving branch of corrected(_:bend:)
                // for bend by least squares, using only the training blocks.
                let liftBasis = v * (1-w)
                liftNumerator += liftBasis * (w-v) * (1-0.8*v)
                liftDenominator += liftBasis * liftBasis
                count += 1
            }
        }
        guard count >= 64, validation.count >= 32, denominator.min() > 0.1 else { return .zero }
        let curve = simd_clamp(numerator/denominator, SIMD3(repeating: -0.8), SIMD3(repeating: 0.8))
        var lifted = curve
        for channel in 0..<3 where curve[channel] >= 0.8 && liftDenominator[channel] > 0.1 {
            lifted[channel] = min(3, max(0.8, liftNumerator[channel] / liftDenominator[channel]))
        }
        func error(_ bend: SIMD3<Float>) -> Float {
            validation.reduce(0) { total, pair in total + simd_length(corrected(pair.0, bend: bend) - pair.1) }
        }
        let baselineError = error(.zero)
        let curveError = error(curve)
        if lifted != curve, error(lifted) < 0.97 * min(curveError, baselineError) { return lifted }
        return curveError < baselineError * 0.97 ? curve : .zero
    }

    /// Above the quadratic's positive limit, roll the additional lift off
    /// toward white. Black and white stay fixed and the slope stays positive.
    static func corrected(_ rgb: SIMD3<Float>, bend: SIMD3<Float>) -> SIMD3<Float> {
        let v = simd_clamp(rgb, .zero, SIMD3(repeating: 1))
        return rgb + bend*v*(1-v) / (1 + simd_max(bend - 0.8, .zero)*v)
    }

    func apply(_ image: CIImage) throws -> CIImage {
        guard bend != .zero else { return image }
        return try SpatialDevelopPipeline.run("asShotCurve", extent: image.extent, [image,
            CIVector(x: CGFloat(bend.x), y: CGFloat(bend.y), z: CGFloat(bend.z))])
    }
}
