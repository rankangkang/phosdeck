import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Phosdeck

/// Measures whether an ordinary JPEG / TIFF / PNG, with no edits applied, stays
/// pixel-identical to the file through preview and export, including a saved
/// neutral JPEG/TIFF recipe. PNG remains a decoder-only regression fixture.
final class RasterIdentityTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testZeroParamPreviewAndExportVersusSource() async throws {
        let pipeline = ImagePipeline()
        let bookmark = try AccessLease.bookmark(directory, readOnly: false)
        let root = StorageRoot(id: "raster-identity", path: directory.path, bookmark: bookmark, label: "synthetic only")
        var lines = ["ordinary-image zero-param identity"]

        for spec in try fixtures() {
            let photo = try ReferenceImporter.inspect(url: spec.url, root: root, rootURL: directory)
            XCTAssertFalse(photo.isRAW, spec.name)
            let sourceRequest = ImageRequest(photo: photo, root: root, recipe: nil)
            let baseline = photo.supportsEditing ? try await pipeline.baseline(sourceRequest) : nil
            let request = ImageRequest(photo: photo, root: root, recipe: baseline)
            let fileImage = try imageIO(spec.url)
            let file8 = try rgba8(fileImage)
            let ci8 = try rgba8(try coreImageDecode(spec.url))
            let roundtrip8 = try rgba8(try coreImageRoundtrip(fileImage))
            let preview = try await pipeline.render(request, longEdge: nil)
            let preview8 = try rgba8(preview.image)
            let unedited = try await pipeline.render(sourceRequest, longEdge: nil)
            XCTAssertEqual(preview8, try rgba8(unedited.image), "A neutral recipe preserves the existing decode")
            XCTAssertEqual(preview.image.width, spec.width, spec.name)
            XCTAssertEqual(preview.image.height, spec.height, spec.name)

            let decodeVsFile = diff8(file8, ci8)
            let roundtripVsFile = diff8(file8, roundtrip8)
            let previewVsFile = diff8(file8, preview8)
            let previewVsDecode = diff8(ci8, preview8)
            XCTAssertEqual(previewVsDecode.max, 0, "\(spec.name) neutral recipe must match CI decode")
            if spec.fileExact {
                XCTAssertEqual(previewVsFile.max, 0, "\(spec.name) preview must match the file")
            }
            lines.append(contentsOf: [
                "",
                "\(spec.name) \(spec.width)×\(spec.height) profile=\(spec.profile)",
                "  ImageIO→CI decode  \(decodeVsFile.line)",
                "  ImageIO→CI wrap    \(roundtripVsFile.line)",
                "  preview vs file    \(previewVsFile.line)  first=\(previewVsFile.samples)",
                "  preview vs decode  \(previewVsDecode.line)"
            ])

            for format in ExportFormat.allCases {
                let quality = format == .jpeg ? 1.0 : 0.9
                let staging = directory.appendingPathComponent("\(spec.name)-out.\(format.fileExtension)")
                _ = try await pipeline.export(request, staging: staging, options: ExportOptions(format: format, quality: quality))
                if format == .tiff {
                    let exported = try rgba16(try imageIO(staging))
                    let file16: [UInt16]
                    if spec.bits == 16 {
                        file16 = try rgba16(try imageIO(spec.url))
                    } else {
                        file16 = file8.map { UInt16($0) * 257 }
                    }
                    let vsFile = diff16(file16, exported)
                    let preview16 = file8.map { UInt16($0) * 257 }
                    let vsPreview = spec.bits == 8 ? diff16(preview16, exported) : vsFile
                    lines.append("  TIFF16 vs file     \(vsFile.line)  first=\(vsFile.samples)")
                    if spec.bits == 8 {
                        lines.append("  TIFF16 vs 8×257    \(vsPreview.line)")
                    }
                    if spec.fileExact { XCTAssertEqual(vsFile.max, 0, "\(spec.name) TIFF16") }
                } else {
                    let exported = try rgba8(try imageIO(staging))
                    let vsFile = diff8(file8, exported)
                    lines.append("  \(format.title) vs file   \(vsFile.line)  first=\(vsFile.samples)")
                    if spec.fileExact, format == .png { XCTAssertEqual(vsFile.max, 0, "\(spec.name) PNG") }
                }
            }

            if spec.name.hasPrefix("jpeg") {
                let lossy = directory.appendingPathComponent("\(spec.name)-q90.jpg")
                _ = try await pipeline.export(request, staging: lossy, options: ExportOptions(quality: 0.9))
                let vsFile = diff8(file8, try rgba8(try imageIO(lossy)))
                lines.append("  JPEG q0.9 vs file  \(vsFile.line)")
            }
            if spec.name == "jpeg8-flat" || spec.bits == 16 {
                if spec.name == "jpeg8-flat" {
                    let native = try await pipeline.render(request, longEdge: spec.width * 2, pixelFormat: .RGBA16)
                    XCTAssertEqual(try rgba16(native.image), file8.map { UInt16($0) * 257 }, "A size limit above native dimensions does not resample the source")
                }
                let resized = try await pipeline.render(request, longEdge: 32, pixelFormat: .RGBA16)
                let graph = ImagePipeline.resized(try XCTUnwrap(CIImage(contentsOf: spec.url)), longEdge: 32)
                let context = CIContext(options: [.workingFormat: CIFormat.RGBAf,
                    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
                var expected = [UInt16](repeating: 0, count: resized.image.width * resized.image.height * 4)
                context.render(graph, toBitmap: &expected, rowBytes: resized.image.width * 8,
                    bounds: graph.extent.integral, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
                XCTAssertEqual(try rgba16(resized.image), expected, "Resized TIFF16 retains the float quality result")
                // A constant 8-bit JPEG can remain on 8-bit codes after resize.
                // Its rounding depends on the system's CI decoder, so establish
                // high-depth coverage with the actual 16-bit gradient instead.
                let non8 = expected.filter { $0 % 257 != 0 }.count
                lines.append("  resized TIFF16      \(resized.image.width)×\(resized.image.height) non8=\(non8)")
                if spec.bits == 16 {
                    XCTAssertTrue(try rgba16(fileImage).contains { $0 % 257 != 0 }, "The source fixture contains true 16-bit codes")
                    XCTAssertGreaterThan(non8, 0, "The resized 16-bit reference exercises precision beyond 8-bit codes")
                }
            }
        }

        let report = lines.joined(separator: "\n")
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "raster-zero-param-identity.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct Fixture {
        let name: String
        let url: URL
        let width: Int
        let height: Int
        let bits: Int
        let profile: String
        let fileExact: Bool
    }

    private func fixtures() throws -> [Fixture] {
        let width = 256, height = 64
        let bytes = pattern8(width: width, height: height)
        let gray = grayRamp(width: width, height: height)
        let flat = flatColor(width: 64, height: 32, red: 128, green: 96, blue: 64)
        return [
            try write(name: "png8-srgb", type: .png, bytes: bytes, width: width, height: height, bits: 8, fileExact: true),
            try write(name: "jpeg8-srgb", type: .jpeg, bytes: bytes, width: width, height: height, bits: 8, fileExact: false),
            try write(name: "jpeg8-gray", type: .jpeg, bytes: gray, width: width, height: height, bits: 8, fileExact: true),
            try write(name: "jpeg8-flat", type: .jpeg, bytes: flat, width: 64, height: 32, bits: 8, fileExact: true),
            try write(name: "tiff8-srgb", type: .tiff, bytes: bytes, width: width, height: height, bits: 8, fileExact: true),
            try write16(name: "tiff16-srgb", width: width, height: 8)
        ]
    }

    private func pattern8(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x)
                bytes[i + 1] = UInt8(min(255, y * 4))
                bytes[i + 2] = UInt8((x + y * 3) % 256)
                bytes[i + 3] = 255
            }
        }
        bytes[0] = 0; bytes[1] = 0; bytes[2] = 0
        let last = (width * height - 1) * 4
        bytes[last] = 255; bytes[last + 1] = 255; bytes[last + 2] = 255
        return bytes
    }

    private func grayRamp(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let value = UInt8(x)
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
            }
        }
        return bytes
    }

    private func flatColor(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = red
            bytes[i + 1] = green
            bytes[i + 2] = blue
        }
        return bytes
    }

    private func write(name: String, type: UTType, bytes: [UInt8], width: Int, height: Int, bits: Int, fileExact: Bool) throws -> Fixture {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let url = directory.appendingPathComponent(name + "." + (type == .jpeg ? "jpg" : type.preferredFilenameExtension ?? "img"))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), name)
        let profile = try profileName(url)
        return Fixture(name: name, url: url, width: width, height: height, bits: bits, profile: profile, fileExact: fileExact)
    }

    private func write16(name: String, width: Int, height: Int) throws -> Fixture {
        var values = [UInt16]()
        values.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                values.append(UInt16(x * 257))
                values.append(UInt16(1000 + y * 400))
                values.append(UInt16(4000 + x * 55))
                values.append(65535)
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ci = values.withUnsafeBytes {
            CIImage(bitmapData: Data($0), bytesPerRow: width * 8, size: CGSize(width: width, height: height), format: .RGBA16, colorSpace: space)
        }
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let image = try XCTUnwrap(context.createCGImage(ci, from: ci.extent, format: .RGBA16, colorSpace: space))
        let url = directory.appendingPathComponent(name + ".tif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), name)
        return Fixture(name: name, url: url, width: width, height: height, bits: 16, profile: try profileName(url), fileExact: true)
    }

    private func profileName(_ url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        return (props[kCGImagePropertyProfileName as String] as? String) ?? "none"
    }

    private func imageIO(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    private func coreImageDecode(_ url: URL) throws -> CGImage {
        var options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        if properties[kCGImagePropertyProfileName as String] == nil { options[.colorSpace] = ImagePipeline.outputSpace }
        let decoded = try XCTUnwrap(CIImage(contentsOf: url, options: options))
        let image = ImagePipeline.originZero(decoded)
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ])
        return try XCTUnwrap(context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace, deferred: false))
    }

    private func coreImageRoundtrip(_ image: CGImage) throws -> CGImage {
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ])
        return try XCTUnwrap(context.createCGImage(CIImage(cgImage: image), from: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                                   format: .RGBA8, colorSpace: ImagePipeline.outputSpace, deferred: false))
    }

    private func rgba8(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: ImagePipeline.outputSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func rgba16(_ image: CGImage) throws -> [UInt16] {
        var values = [UInt16](repeating: 0, count: image.width * image.height * 4)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 8,
                       bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                       format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
        return values
    }

    private struct Diff {
        let max: Int
        let mae: Double
        let changed: Int
        let total: Int
        let samples: String
        var line: String {
            String(format: "max=%d  mae=%.4f  changed=%d/%d", max, mae, changed, total)
        }
    }

    private func diff8(_ a: [UInt8], _ b: [UInt8]) -> Diff {
        precondition(a.count == b.count)
        var maxDiff = 0, sum = 0.0, changed = 0
        var samples = [String]()
        let pixels = a.count / 4
        for i in 0..<pixels {
            let base = i * 4
            var pixel = 0
            for c in 0..<3 {
                let d = abs(Int(a[base + c]) - Int(b[base + c]))
                pixel = max(pixel, d)
                sum += Double(d)
            }
            if pixel > 0 {
                changed += 1
                if samples.count < 4 {
                    samples.append("p\(i)(\(a[base]),\(a[base + 1]),\(a[base + 2]))→(\(b[base]),\(b[base + 1]),\(b[base + 2]))")
                }
            }
            maxDiff = max(maxDiff, pixel)
        }
        return Diff(max: maxDiff, mae: sum / Double(pixels * 3), changed: changed, total: pixels, samples: samples.joined(separator: "; "))
    }

    private func diff16(_ a: [UInt16], _ b: [UInt16]) -> Diff {
        precondition(a.count == b.count)
        var maxDiff = 0, sum = 0.0, changed = 0
        var samples = [String]()
        let pixels = a.count / 4
        for i in 0..<pixels {
            let base = i * 4
            var pixel = 0
            for c in 0..<3 {
                let d = abs(Int(a[base + c]) - Int(b[base + c]))
                pixel = max(pixel, d)
                sum += Double(d)
            }
            if pixel > 0 {
                changed += 1
                if samples.count < 4 {
                    samples.append("p\(i)(\(a[base]),\(a[base + 1]),\(a[base + 2]))→(\(b[base]),\(b[base + 1]),\(b[base + 2]))")
                }
            }
            maxDiff = max(maxDiff, pixel)
        }
        return Diff(max: maxDiff, mae: sum / Double(pixels * 3), changed: changed, total: pixels, samples: samples.joined(separator: "; "))
    }
}
