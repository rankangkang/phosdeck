import CoreGraphics

/// Display-referred RGB histogram of the current rendered preview, not sensor RAW values.
struct ImageHistogram {
    let channels: [[Double]]
    static func calculate(_ image: CGImage) -> Self? {
        let side = 256
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)); return true
        }
        guard rendered else { return nil }
        var values = Array(repeating: [Double](repeating: 0, count: 256), count: 3)
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[pixel+3])
            if alpha == 0 { continue }
            // Covered color contributes in proportion to its visible area;
            // transparent black is not a photographic shadow sample.
            for channel in 0..<3 {
                let value = min(255,(Int(pixels[pixel+channel])*255+alpha/2)/alpha)
                values[channel][value] += Double(alpha)/255
            }
        }
        return Self(channels: values)
    }
}
