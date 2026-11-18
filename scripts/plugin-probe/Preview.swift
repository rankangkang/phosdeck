import CoreImage
import Metal
import CryptoKit

struct ToneReply {
    let handle: FileHandle
    let read: Double
    let calculate: Double
    let write: Double
    let peak: Int64
}

struct ProbeFrame {
    let image: CGImage?
    let started: UInt64
    let ready: UInt64
    let rows: [String: Double]
}

actor Preview {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context: CIContext

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ProbeError("Metal device unavailable") }
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
        ])
    }

    // Two different rows, extended-range values and straight alpha are observable
    // in the small round-trip fixture and exercise the same format at large sizes.
    func stage(_ frame: Frame, exposure: Float = 1) throws -> Data {
        let w = frame.width, h = frame.height
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let background = CIImage(color: CIColor(red: CGFloat(exposure) * 1.25, green: 0.4, blue: -0.125,
                                                alpha: 0.5, colorSpace: space)!).cropped(to: bounds)
        let opaque = CIImage(color: CIColor(red: 0.25, green: 0.6, blue: 0.95, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: h / 2, width: w, height: h - h / 2))
        let clear = CGRect(x: 0, y: 0, width: w / 4, height: h / 4)
        let image = opaque.composited(over: background)
            .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: .white).cropped(to: clear)])
            .cropped(to: bounds)
        var pixels = Data(count: frame.bytes)
        try pixels.withUnsafeMutableBytes { buffer in
            let destination = CIRenderDestination(bitmapData: buffer.baseAddress!, width: w, height: h,
                                                  bytesPerRow: frame.rowBytes, format: .RGBAf)
            destination.colorSpace = space
            destination.alphaMode = .unpremultiplied
            destination.isFlipped = true
            destination.isDithered = false
            let task = try context.startTask(toRender: image, from: bounds, to: destination, at: .zero)
            _ = try task.waitUntilCompleted()
        }
        return pixels
    }

    func display(_ pixels: Data, frame: Frame) throws -> CGImage {
        let image = CIImage(bitmapData: pixels, bytesPerRow: frame.rowBytes,
                            size: CGSize(width: frame.width, height: frame.height), format: .RGBAf, colorSpace: space)
            .premultiplyingAlpha()
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(frame.height)))
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                 colorSpace: displaySpace, deferred: false) else {
            throw ProbeError("display conversion failed")
        }
        return result
    }

    func render(_ frame: Frame, remote: Peer?, revision: Int, strength: Float, cached: FileHandle? = nil,
                final: Bool = false, started: UInt64 = now()) async throws -> ProbeFrame {
        let prepStart = now()
        var pixels = cached == nil ? try stage(frame, exposure: 1 + strength / 10) : Data()
        var rows = ["prepare": elapsed(prepStart)]
        if let remote {
            let stageStart = now()
            let input = try cached ?? readOnlyFile(pixels)
            if cached == nil { pixels = Data() }
            defer { if cached == nil { try? input.close() } }
            rows["input_file"] = elapsed(stageStart)
            let rpcStart = now()
            let reply = try await remote.evaluate(frame, revision: revision, strength: strength, input: input)
            defer { try? reply.handle.close() }
            rows["rpc"] = elapsed(rpcStart)
            rows["plugin_read"] = reply.read
            rows["calculate"] = reply.calculate
            rows["plugin_write"] = reply.write
            rows["plugin_peak_rss"] = Double(reply.peak)
            let readStart = now()
            pixels = try frame.read(reply.handle)
            rows["host_read"] = elapsed(readStart)
        } else {
            let calculateStart = now()
            warm(&pixels, strength: strength)
            rows["calculate"] = elapsed(calculateStart)
        }
        let verifyStart = now()
        try frame.validate(pixels)
        rows["verify"] = elapsed(verifyStart)
        let finishStart = now()
        let image: CGImage?
        if final {
            let digest = SHA256.hash(data: pixels)
            let saved = try readOnlyFile {
                try $0.write(contentsOf: pixels)
                try $0.synchronize()
            }
            defer { try? saved.close() }
            pixels = Data()
            let readback = try SHA256.hash(data: frame.read(saved))
            try require(readback == digest, "frozen frame readback mismatch")
            image = nil
        } else {
            image = try display(pixels, frame: frame)
        }
        rows[final ? "freeze_write_verify" : "display_bitmap"] = elapsed(finishStart)
        rows["host_peak_rss"] = Double(peakRSS())
        return ProbeFrame(image: image, started: started, ready: now(), rows: rows)
    }
}
