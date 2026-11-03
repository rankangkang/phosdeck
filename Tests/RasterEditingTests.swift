import XCTest
import AppKit
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Phosdeck

final class RasterEditingTests: XCTestCase {
    func testJPEGEndMarkerWalkRejectsTruncatedDataAndMetadataFalsePositives() throws {
        let soi = Data([0xff,0xd8]), eoi = Data([0xff,0xd9])
        let app = Data([0xff,0xe1,0,6,0xff,0xd9,0,0])
        let scan = Data([0xff,0xda,0,2,10,0xff,0,20,0xff,0xd0,30,0xff,0xff,0xd1,40])
        XCTAssertFalse(PhotoFileType.reachesJPEGEnd(soi+app+scan))
        XCTAssertTrue(PhotoFileType.reachesJPEGEnd(soi+app+scan+eoi))
        XCTAssertTrue(PhotoFileType.reachesJPEGEnd(soi+scan+eoi+Data([1,2,3])),"MPF trailing data follows the primary EOI")
        for data in [Data(),Data([0xff]),soi+Data([0xff]),soi+Data([0xff,0xe1,0,1])+eoi,
                     soi+Data([0xff,0xe1,0xff,0xff])+eoi] {
            XCTAssertFalse(PhotoFileType.reachesJPEGEnd(data))
        }
    }
    private var directory: URL!
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAf,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String, type: UTType = .tiff, depth: Int = 16,
                         space: CGColorSpace = ImagePipeline.outputSpace, orientation: Int = 1, tagged: Bool = true) throws -> ImageRequest {
        let w = 128, h = 96
        var values = [UInt16](repeating: 65535, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let texture = ((x / 4 + y / 4) % 2) * 1200
            values[i] = UInt16(1500 + x * 350 + texture)
            values[i + 1] = UInt16(2000 + y * 500 + texture)
            values[i + 2] = UInt16(3000 + ((x + y) % 96) * 450)
        } }
        let data = values.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let url = directory.appendingPathComponent(name + "." + (type == .jpeg ? "jpg" : type.preferredFilenameExtension!))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let encoded: CGImage
        if depth == 8 {
            encoded = try XCTUnwrap(context.createCGImage(CIImage(cgImage: image), from: CGRect(x: 0, y: 0, width: w, height: h),
                format: .RGBA8, colorSpace: space))
        } else { encoded = image }
        let props: [CFString: Any] = [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0]
        let output = tagged ? encoded : try XCTUnwrap(encoded.copy(colorSpace: CGColorSpaceCreateDeviceRGB()))
        CGImageDestinationAddImage(destination, output, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        if !tagged {
            // ImageIO writes sRGB even for a device-RGB CGImage. Remove the ICC
            // APP2 segment from this synthetic JPEG to exercise a genuinely untagged file.
            let bytes = [UInt8](try Data(contentsOf: url))
            var stripped = Array(bytes.prefix(2)), offset = 2
            while offset + 4 <= bytes.count {
                guard bytes[offset] == 0xff else { throw LRCError("Invalid synthetic JPEG segment") }
                let marker = bytes[offset + 1]
                if marker == 0xda { stripped += bytes[offset...]; break }
                let length = Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3])
                guard length >= 2, offset + 2 + length <= bytes.count else { throw LRCError("Invalid synthetic JPEG length") }
                let end = offset + 2 + length
                if marker != 0xe2 { stripped += bytes[offset..<end] }
                offset = end
            }
            try Data(stripped).write(to: url)
        }
        let root = StorageRoot(id: "synthetic", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "synthetic only")
        return ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: directory), root: root, recipe: nil)
    }
    private func request(_ source: ImageRequest, _ recipe: EditRecipe) -> ImageRequest {
        ImageRequest(photo: source.photo, root: source.root, recipe: recipe)
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: image.width * 4,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        return bytes
    }
    private func pixels16(_ image: CGImage) -> [UInt16] {
        // Read the actual 16-bit storage; avoid a second colour conversion in precision assertions.
        precondition(image.bitsPerComponent == 16 && image.bitsPerPixel == 64)
        let data = image.dataProvider!.data! as Data
        return data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: UInt16.self)
            return (0..<image.height).flatMap { row in
                Array(values[(row * image.bytesPerRow / 2)..<(row * image.bytesPerRow / 2 + image.width * 4)])
            }
        }
    }
    private func read(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testICCOrientationAndNeutralRecipe() async throws {
        let pipeline = ImagePipeline()
        for type in [UTType.jpeg, .tiff, .png] {
            for profile in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
                let source = try fixture(type.identifier + (profile as String), type: type, depth: type == .jpeg ? 8 : 16,
                    space: XCTUnwrap(CGColorSpace(name: profile)), orientation: 6)
                let baseline = try await pipeline.baseline(source)
                XCTAssertTrue(baseline.isUnadjustedRaster)
                XCTAssertEqual(baseline.baselineExposure, 0)
                XCTAssertEqual(baseline.baselineTemperature, 5500)
                XCTAssertTrue(baseline.rawDetails.isDefault)
                let original = try await pipeline.render(source, longEdge: nil)
                let neutral = try await pipeline.render(request(source, baseline), longEdge: nil, reuseDecoded: true)
                XCTAssertEqual(neutral.orientedSourceSize, CGSize(width: 96, height: 128))
                XCTAssertEqual(pixels(neutral.image), pixels(original.image), "A recipe must not introduce a RAW look or a second orientation")
                let cacheBytes = await pipeline.qualityCacheBytes
                XCTAssertEqual(cacheBytes, 0)
                let deepOriginal = try await pipeline.render(source, longEdge: nil, pixelFormat: .RGBA16)
                let deepNeutral = try await pipeline.render(request(source, baseline), longEdge: nil, pixelFormat: .RGBA16)
                XCTAssertEqual(pixels16(deepNeutral.image), pixels16(deepOriginal.image))
                var neutralLayout = baseline
                var curve = ToneCurves()
                curve.channels[0] = [CurvePoint(x:0,y:0),CurvePoint(x:0.37,y:0.37),CurvePoint(x:1,y:1)]
                neutralLayout.develop.curves = curve
                neutralLayout.develop.blackWhiteMixer = [100,-100,75,-75,50,-50,25,-25]
                XCTAssertTrue(neutralLayout.isUnadjustedRaster)
                let layoutPreview = try await pipeline.render(request(source,neutralLayout),longEdge:nil)
                let layoutDeep = try await pipeline.render(request(source,neutralLayout),longEdge:nil,pixelFormat:.RGBA16)
                XCTAssertEqual(pixels(layoutPreview.image),pixels(original.image))
                XCTAssertEqual(pixels16(layoutDeep.image),pixels16(deepOriginal.image))
                var edited = baseline; edited.exposure = 0.4
                let actual = try await pipeline.render(request(source, edited), longEdge: nil, pixelFormat: .RGBA16)
                let url = directory.appendingPathComponent(source.photo.relativePath)
                let decoded = try RasterExposure.apply(XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true])), ev: 0.4)
                var expected = [UInt16](repeating: 0, count: actual.image.width * actual.image.height * 4)
                context.render(decoded, toBitmap: &expected, rowBytes: actual.image.width * 8, bounds: decoded.extent,
                    format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
                XCTAssertEqual(pixels16(actual.image), expected, "ICC conversion and exposure stay in the float quality graph")
            }
        }
        let untagged = try fixture("untagged", type: .jpeg, depth: 8, tagged: false)
        let untaggedURL = directory.appendingPathComponent(untagged.photo.relativePath)
        XCTAssertNil(try Data(contentsOf: untaggedURL).range(of: Data("ICC_PROFILE".utf8)), "The file contains no embedded ICC; ImageIO may still report inferred sRGB")
        let baseline = try await pipeline.baseline(untagged)
        let original = try await pipeline.render(untagged, longEdge: nil)
        let neutral = try await pipeline.render(request(untagged, baseline), longEdge: nil)
        XCTAssertEqual(pixels(original.image), pixels(neutral.image))
        let explicit = try XCTUnwrap(CIImage(contentsOf: untaggedURL, options: [.colorSpace: ImagePipeline.outputSpace, .applyOrientationProperty: true]))
        let expected = try XCTUnwrap(context.createCGImage(explicit, from: explicit.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
        XCTAssertEqual(pixels(neutral.image), pixels(expected), "Untagged RGB is interpreted as sRGB")
    }

    // LR-EXPOSURE-001: measured TIFF16 neutral highlights must retain gradation at +1.
    // Bounds isolate the confirmed clipping defect; they are not a Lightroom acceptance threshold.
    func testRasterPositiveExposurePreservesMeasuredHighlightGradation() async throws {
        let levels = [320, 560, 600, 639].map { UInt16($0 * 65535 / 639) }
        let values = levels.flatMap { [$0, $0, $0, UInt16.max] }
        let data = values.withUnsafeBytes { Data($0) }
        let image = try XCTUnwrap(CGImage(width: levels.count, height: 1, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: levels.count * 8, space: ImagePipeline.outputSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little),
            provider: XCTUnwrap(CGDataProvider(data: data as CFData)), decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let url = directory.appendingPathComponent("exposure-highlight.tif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let before = try SafeFileWriter.sha256(url)
        let root = StorageRoot(id: "exposure", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "synthetic")
        let source = ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: directory), root: root, recipe: nil)
        let pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(source)
        for version in ["imageio-raster-v1", "imageio-raster-response-v2", "imageio-raster-response-v3"] {
            var obsolete = recipe; obsolete.decoderVersion = version
            XCTAssertThrowsError(try obsolete.validate(),"Old raster response must be rejected before paste or rendering")
            XCTAssertThrowsError(try obsolete.validate(for:source.photo),"Old raster response must be rejected, not silently reinterpreted")
        }
        recipe.exposure = 1
        let rendered = try await pipeline.render(request(source, recipe), longEdge: nil, pixelFormat: .RGBA16)
        let output = pixels16(rendered.image)
        let lightroom = [180.45525291828795, 244.92996108949416, 251.01556420233464, 255.0]
        for i in levels.indices { XCTAssertEqual(Double(output[i * 4]) / 257, lightroom[i], accuracy: 0.5) }
        XCTAssertLessThan(output[4], output[8]); XCTAssertLessThan(output[8], output[12])
        XCTAssertEqual(try SafeFileWriter.sha256(url), before)
    }

    func testRasterExposureFloatKernelReferenceAlphaAndNeutralBypass() throws {
        let colors: [SIMD3<Double>] = [.zero,SIMD3(repeating:1),SIMD3(repeating:0.18),SIMD3(0.9,0.2,0.001),SIMD3(0.02,0.8,0.4),SIMD3(-0.1,0.4,1.2)]
        let alphas = [0.0,1.0/65535,0.4,1.0]
        let samples = alphas.flatMap { a in colors.map { (color:$0,alpha:a) } }
        let bytes: [Float] = samples.flatMap { [Float($0.color.x*$0.alpha),Float($0.color.y*$0.alpha),Float($0.color.z*$0.alpha),Float($0.alpha)] }
        let data = bytes.withUnsafeBytes { Data($0) }, linear = try XCTUnwrap(CGColorSpace(name:CGColorSpace.extendedLinearSRGB))
        let input = CIImage(bitmapData:data,bytesPerRow:samples.count*16,size:CGSize(width:samples.count,height:1),format:.RGBAf,colorSpace:linear)
        XCTAssertTrue(try RasterExposure.apply(input,ev:0) === input)
        let stops = (0...40).map { Double($0) / 4 - 5 }.filter { $0 != 0 } + [-1.13,-0.13,0.13,0.37,1.13]
        for ev in stops {
            let output = try RasterExposure.apply(input,ev:ev)
            var pixels = [Float](repeating:0,count:samples.count*4)
            context.render(output,toBitmap:&pixels,rowBytes:samples.count*16,bounds:input.extent,format:.RGBAf,colorSpace:linear)
            for (i,sample) in samples.enumerated() {
                let reference = try RasterExposure.transform(sample.color,ev:ev)*sample.alpha
                for channel in 0..<3 {
                    XCTAssertEqual(Double(pixels[i*4+channel]),reference[channel],accuracy:0.00005,"EV \(ev), sample \(i), channel \(channel)")
                }
                XCTAssertEqual(Double(pixels[i*4+3]),sample.alpha,accuracy:0.0000001)
            }
        }
        var previous = RasterExposure.response(-5)
        for step in 0...200 {
            let curve = RasterExposure.response(-5+Double(step)*0.05)
            XCTAssertEqual(curve.first,0)
            XCTAssertTrue(zip(curve,curve.dropFirst()).allSatisfy { $0 <= $1 })
            XCTAssertTrue(zip(previous,curve).allSatisfy { $0 <= $1+1e-12 })
            previous = curve
        }
        XCTAssertThrowsError(try RasterExposure.apply(input,ev:.nan))
        XCTAssertThrowsError(try RasterExposure.apply(input,ev:5.01))
    }

    func testRasterExposureSaturatedColourLightroomOracle() throws {
        // LR 15.2.1 / PV15.4, sRGB TIFF16, J seed 2026102001. These eight
        // independent inputs were selected by the old model's largest errors,
        // before evaluating this correction; no calibration node is fitted here.
        // Full-image/region/max-error results remain in the validation report.
        let cases: [(Double, [Double], [Double])] = [
            (-5,[55972,65520,26751],[8609,11081,0]),
            (-5,[64083,64972,5429],[10901,11109,0]),
            (-1,[22950,19883,65359],[9917,0,58039]),
            (-1,[29433,65239,29700],[0,58608,0]),
            (1,[65136,214,218],[65535,16167,16154]),
            (1,[63923,143,108],[65535,15696,15667]),
            (5,[24168,243,64],[65535,40492,40359]),
            (5,[24953,14,11],[65535,41214,41206]),
        ]
        func decode(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        func encode(_ x: Double) -> Double { min(1,max(0,x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055)) }
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        for (ev, input16, expected16) in cases {
            let c = SIMD3(decode(input16[0]/65535),decode(input16[1]/65535),decode(input16[2]/65535))
            let values: [Float] = [Float(c.x),Float(c.y),Float(c.z),1]
            let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            var output = [Float](repeating: 0, count: 4)
            context.render(try RasterExposure.apply(image,ev:ev), toBitmap: &output, rowBytes: 16,
                bounds: image.extent, format: .RGBAf, colorSpace: linear)
            let old = RasterExposure.baseTransform(c,ev:ev)
            let before = (0..<3).map { abs(encode(old[$0])-expected16[$0]/65535) }.reduce(0,+)
            let after = (0..<3).map { abs(encode(Double(output[$0]))-expected16[$0]/65535) }.reduce(0,+)
            XCTAssertLessThan(after,before/8,"Saturated-colour regression, EV \(ev), input \(input16)")
        }
    }

    func testRasterExposureIntermediateEVLightroomOracle() throws {
        // LR 15.2.1 / PV15.4, direct sRGB TIFF16. Existing J regression
        // colours isolate the grey-response interpolation error; the new M
        // holdout remains outside calibration and regression-point selection.
        // These local guards do not stand in for whole-image/user acceptance.
        let cases: [(Double, [Double], [Double], Double)] = [
            (-1.25, [34809,60576,42589], [660,47387,24069], 1),
            (-0.25, [20778,64209,55066], [6099,62260,52547], 3),
            (0.25, [230,35293,33082], [3978,38914,36534], 1),
        ]
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func decode(_ x: Double) -> Float {
            Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
        }
        func encode(_ x: Float) -> Double {
            let v = min(1,max(0,Double(x)))
            return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        for (ev, input16, expected16, tolerance8) in cases {
            let values = input16.map { decode($0 / 65535) } + [1]
            let image = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            var output = [Float](repeating: 0, count: 4)
            context.render(try RasterExposure.apply(image,ev:ev), toBitmap: &output, rowBytes: 16,
                bounds: image.extent, format: .RGBAf, colorSpace: linear)
            for channel in 0..<3 {
                XCTAssertEqual(encode(output[channel]) * 255, expected16[channel] / 257,
                    accuracy: tolerance8, "Intermediate EV \(ev), channel \(channel)")
            }
        }
    }

    func testRasterExposureColourContinuityAndZeroIdentity() throws {
        for ev in [-5.0,-1.25,0.25,1,5] {
            for edge in [0.0,1.0] {
                let a = SIMD3(edge-1e-8,0.18,0.7), b = SIMD3(edge+1e-8,0.18,0.7)
                let x = try RasterExposure.transform(a,ev:ev), y = try RasterExposure.transform(b,ev:ev)
                for c in 0..<3 { XCTAssertEqual(x[c],y[c],accuracy:1e-5) }
            }
        }
        let colour = SIMD3(-0.1,0.18,1.2)
        XCTAssertEqual(try RasterExposure.transform(colour,ev:0),colour)
        for ev in [-1e-8,1e-8] {
            let result = try RasterExposure.transform(colour,ev:ev)
            for c in 0..<3 { XCTAssertEqual(result[c],colour[c],accuracy:1e-5) }
        }
    }

    func testRasterExposureDraftAndQualityAtSameSize() async throws {
        let w=64,h=32
        var values=[UInt16](repeating:65535,count:w*h*4)
        for y in 0..<h { for x in 0..<w {
            let level: UInt16 = (x+y)%2 == 0 ? 0 : 65535
            for c in 0..<3 { values[(y*w+x)*4+c]=level }
        } }
        let data=values.withUnsafeBytes{Data($0)}
        let image=try XCTUnwrap(CGImage(width:w,height:h,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:w*8,
            space:ImagePipeline.outputSpace,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little),
            provider:XCTUnwrap(CGDataProvider(data:data as CFData)),decode:nil,shouldInterpolate:false,intent:.relativeColorimetric))
        let url=directory.appendingPathComponent("exposure-resampling.tif")
        let dest=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,image,nil);XCTAssertTrue(CGImageDestinationFinalize(dest))
        let root=StorageRoot(id:"order",path:directory.path,bookmark:try AccessLease.bookmark(directory,readOnly:true),label:"synthetic")
        let source=ImageRequest(photo:try ReferenceImporter.inspect(url:url,root:root,rootURL:directory),root:root,recipe:nil)
        let pipeline=ImagePipeline()
        var recipe=try await pipeline.baseline(source)
        for ev in [-1.0,1] {
            recipe.exposure=ev
            let quality=try await pipeline.render(request(source,recipe),longEdge:16)
            let draft=try await pipeline.renderInteractive(request(source,recipe),longEdge:16)
            let a=pixels(quality.image),b=pixels(draft.image)
            XCTAssertEqual(a.count,b.count)
            let largest=zip(a,b).map{abs(Int($0)-Int($1))}.max() ?? 0
            XCTAssertLessThanOrEqual(largest,1,"Draft and quality exposure must agree at the same output size; EV \(ev)")
        }
    }

    func testEverySharedAdjustmentChangesJPEGAndTIFFPixels() async throws {
        let edits: [(String, (inout EditRecipe) -> Void)] = [
            ("exposure", { $0.exposure = 0.7 }),
            ("white balance", { $0.asShotWhiteBalance = false; $0.temperature = 7200; $0.tint = 15 }),
            ("contrast", { $0.contrast = 1.3 }), ("saturation", { $0.saturation = 0.6 }),
            ("highlights", { $0.develop.highlights = -60 }), ("shadows", { $0.develop.shadows = 50 }),
            ("whites", { $0.develop.whites = 40 }), ("blacks", { $0.develop.blacks = -40 }),
            ("texture", { $0.develop.texture = 80 }), ("clarity", { $0.develop.clarity = 60 }),
            ("dehaze", { $0.develop.dehaze = 40 }), ("vibrance", { $0.develop.vibrance = 50 }),
            ("HSL", { $0.develop.mixer[0].hue = 70; $0.develop.mixer[4].saturation = -70 }),
            ("grading", { $0.develop.grading.midtones = GradingTone(hue: 220, saturation: 35, luminance: 5) }),
            ("curves", { $0.develop.curves = ToneCurves(); $0.develop.curves?.channels[0][2].y = 0.65 }),
            ("zones", { $0.develop.zones = ToneZones(gains: [0, 0.4, 0.5, 0.2, 0]) }),
            ("black and white", { $0.develop.blackAndWhite = true }),
            ("geometry", { $0.quarterTurns = 1; $0.crop.width = 0.6; $0.straightenDegrees = 3 }),
            ("vignette", { $0.vignette.amount = -45 }),
            ("grain", { $0.grain = FilmGrain(amount: 50, size: 50, roughness: 50, seed: 123) })
        ]
        for type in [UTType.jpeg, .tiff, .png] {
            let source = try fixture("controls-" + type.identifier, type: type, depth: type == .jpeg ? 8 : 16)
            let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(source)
            let original = try await pipeline.render(request(source, baseline), longEdge: nil)
            for (label, edit) in edits {
                var value = baseline; edit(&value)
                let output = try await pipeline.render(request(source, value), longEdge: nil)
                XCTAssertNotEqual(pixels(output.image), pixels(original.image), type.identifier + " " + label)
                let draft = try await pipeline.renderInteractive(request(source, value), longEdge: 128)
                XCTAssertEqual(draft.orientedSourceSize, original.orientedSourceSize)
                XCTAssertEqual(draft.image.width, output.image.width)
                XCTAssertEqual(draft.image.height, output.image.height)
            }
        }
    }

    func testMaskReferencesToolsAndRepairModes() async throws {
        for type in [UTType.jpeg, .tiff, .png] {
            let source = try fixture("local-" + type.identifier, type: type, depth: type == .jpeg ? 8 : 16)
            let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(source)
            let original = try await pipeline.render(request(source, baseline), longEdge: nil)
            let reference = try await pipeline.maskReference(request(source, baseline))
            var changed = baseline; changed.exposure = 1; changed.asShotWhiteBalance = false; changed.temperature = 7000
            let otherReference = try await pipeline.maskReference(request(source, changed))
            XCTAssertEqual(pixels(reference), pixels(otherReference), "Range and auto-brush selections use the unedited ICC-managed baseline")
            _ = try await pipeline.zoneReference(request(source, changed))
            let rank = try await pipeline.linearRank(request(source, baseline))
            XCTAssertEqual(rank.width, 128)
            for tool in MaskTool.allCases {
                var component = MaskComponent(tool: tool)
                component.strokes = [MaskStroke(points: [MaskPoint(0.5, 0.5)], radius: 0.2, autoMask: true)]
                component.samples = [MaskSample(point: MaskPoint(0.5, 0.5), red: 0.2, green: 0.2, blue: 0.2)]
                if tool == .color { component.tolerance = 0.8; component.smoothness = 0.1 }
                if tool == .object {
                    component.raster = SmartMaskRaster(source: SmartMaskSource(recipe: baseline, size: original.orientedSourceSize), model: "synthetic-raster-test",
                        base: try SmartMaskTile(values: [0,1,0.5,1], width: 2, height: 2, region: CGRect(x: 0, y: 0, width: 1, height: 1)))
                }
                var group = LocalAdjustment(components: [component]); group.exposure = 0.8
                group.settings = LocalDevelopSettings(); group.settings?.develop.vibrance = 20
                group.refinement = MaskRefinement(edgeRadius: 0.05, blurRadius: 0.02)
                var value = baseline; value.schemaVersion = 3; value.maskVersion = tool == .object ? 3 : 2; value.localAdjustments = [group]
                let output = try await pipeline.render(request(source, value), longEdge: nil)
                XCTAssertNotEqual(pixels(output.image), pixels(original.image), tool.rawValue)
                let draft = try await pipeline.renderInteractive(request(source, value), longEdge: 128)
                let repeated = try await pipeline.renderInteractive(request(source, value), longEdge: 128)
                XCTAssertEqual(pixels(draft.image), pixels(repeated.image), "Cached coverage must preserve pixels")
            }
            for mode in SpotRepairMode.allCases {
                var value = baseline
                value.repairs = [SpotRepair(mode: mode, points: [MaskPoint(0.5, 0.5)], radius: 0.12,
                    feather: 0.5, opacity: 1, sourceOffset: mode == .remove ? nil : MaskPoint(0.25, 0))]
                let output = try await pipeline.render(request(source, value), longEdge: nil)
                XCTAssertNotEqual(pixels(output.image), pixels(original.image), mode.rawValue)
                XCTAssertNotNil(output.spotOffsets[value.repairs[0].id])
            }
        }
    }

    func testEditedPreviewExportAndPrecision() async throws {
        for type in [UTType.jpeg, .tiff, .png] {
            let source = try fixture("export-" + type.identifier, type: type, depth: type == .jpeg ? 8 : 16)
            let pipeline = ImagePipeline()
            var value = try await pipeline.baseline(source)
            value.exposure = 0.23; value.contrast = 1.1; value.crop.width = 0.75; value.quarterTurns = 1
            value.develop.curves = ToneCurves(); value.develop.curves?.channels[0][2] = CurvePoint(x:0.43,y:0.58)
            value.develop.curves?.insert(channel:1,x:0.36,y:0.42)
            value.develop.blackAndWhite = true; value.develop.blackWhiteMixer = [35,-20,15,-30,10,25,-15,40]
            value.schemaVersion = 3
            var mask = LocalAdjustment(components: [MaskComponent(tool: .radial)]); mask.exposure = 0.3
            value.localAdjustments = [mask]
            value.repairs = [SpotRepair(mode: .clone, points: [MaskPoint(0.4, 0.5)], radius: 0.08, sourceOffset: MaskPoint(0.2, 0))]
            value.vignette.amount = -10
            let edited = request(source, value)
            for edge: Int? in [nil, 64] {
                let preview = try await pipeline.render(edited, longEdge: edge)
                let deep = try await pipeline.render(edited, longEdge: edge, pixelFormat: .RGBA16)
                let samples = pixels16(deep.image)
                let levels = Set(stride(from: 0, to: samples.count, by: 4).map { samples[$0] })
                XCTAssertGreaterThan(levels.count, 256, "Edited JPEG and TIFF both retain float processing beyond 8-bit output")
                let url = directory.appendingPathComponent("edited-\(type.identifier)-\(edge ?? 0).tif")
                _ = try await pipeline.export(edited, staging: url, options: ExportOptions(format: .tiff, longEdge: edge))
                let roundtrip = try read(url)
                // ImageIO may change TIFF storage layout; compare through the same float context.
                var expected = [UInt16](repeating: 0, count: deep.image.width * deep.image.height * 4)
                var actual = expected
                let bounds = CGRect(x: 0, y: 0, width: deep.image.width, height: deep.image.height)
                context.render(CIImage(cgImage: deep.image), toBitmap: &expected, rowBytes: deep.image.width * 8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
                context.render(CIImage(cgImage: roundtrip), toBitmap: &actual, rowBytes: deep.image.width * 8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
                XCTAssertEqual(actual, expected, "TIFF16 export uses the full quality graph")
                let png = directory.appendingPathComponent("edited-\(type.identifier)-\(edge ?? 0).png")
                _ = try await pipeline.export(edited, staging: png, options: ExportOptions(format: .png, longEdge: edge))
                XCTAssertEqual(pixels(try read(png)), pixels(preview.image), "Equal-size preview and lossless export match")
            }
        }
    }

    func testCrossTypePresetsKeepIdentityAndCapabilities() throws {
        var raster = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
            baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 6100, tint: 4)
        raster.asShotWhiteBalance = false
        var raw = EditRecipe(sourceDigest: String(repeating: "b", count: 64), decoderVersion: "raw-test",
            baselineExposure: 0.3, baselineTemperature: 4200, baselineTint: 12, temperature: 7200, tint: 20)
        raw.exposure = 1; raw.asShotWhiteBalance = false; raw.rawDetails.sharpness = 0.7
        let options = RecipePasteOptions(details: true)
        for (target, source) in [(raster, raw), (raw, raster)] {
            for amount in [0.0, 0.5, 1.0, 2.0] {
                let result = try target.applyingPreset(source, options: options, amount: amount)
                XCTAssertEqual(result.sourceDigest, target.sourceDigest); XCTAssertEqual(result.decoderVersion, target.decoderVersion)
                XCTAssertEqual(result.baselineExposure, target.baselineExposure)
                XCTAssertEqual(result.temperature, target.temperature); XCTAssertEqual(result.tint, target.tint)
                XCTAssertEqual(result.rawDetails, target.rawDetails)
                XCTAssertEqual(result.exposure, target.exposure + (source.exposure - target.exposure) * amount)
            }
            XCTAssertEqual(target.transferNotes(from: source, options: options).count, 2)
        }
        let pasted = try raster.pasting(raw, options: options)
        XCTAssertEqual(pasted.exposure, 1); XCTAssertTrue(pasted.rawDetails.isDefault)
        let rasterNeutral = raster.baseline()
        let sameType = try rasterNeutral.applyingPreset(raster, options: options, amount: 0.5)
        XCTAssertEqual(sameType.temperature, 5800); XCTAssertEqual(sameType.tint, 2)
        XCTAssertFalse(sameType.asShotWhiteBalance)
        var invalid = raster; invalid.rawDetails.sharpness = 0.1
        XCTAssertThrowsError(try invalid.validate())
        invalid = raster; invalid.baselineExposure = 1; XCTAssertThrowsError(try invalid.validate())
        invalid = raster; invalid.pipelineVersion = 1; XCTAssertThrowsError(try invalid.validate())
        XCTAssertTrue(Photo(id: "p", rootID: "r", relativePath: "a.png", identity: Data(), identityKey: "p", width: 1, height: 1).supportsEditing)
        XCTAssertTrue(ImportPlanner.images.contains("png"))
    }

    func testRasterExportSnapshotsFreezeEditedAndNeutralRecipes() async throws {
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("export-catalog"))
        let pipeline = ImagePipeline()
        for type in [UTType.jpeg, .tiff, .png] {
            let source = try fixture("frozen-" + type.identifier, type: type, depth: type == .jpeg ? 8 : 16)
            let root = try catalog.addRoot(url: directory, bookmark: source.root.bookmark)
            var photo = source.photo; photo.rootID = root.id; try catalog.index(photo)
            var frozen = try await pipeline.baseline(source)
            frozen.exposure = 0.35; frozen.crop.width = 0.75
            var later = frozen; later.exposure = 1.5
            try catalog.saveRecipe(id: photo.id, recipe: later)
            for recipe in [Optional(frozen), nil] {
                let id = UUID().uuidString, destination = directory.appendingPathComponent(UUID().uuidString + ".tif")
                let request = ImageRequest(photo: photo, root: root, recipe: recipe)
                let snapshot = ExportSnapshot(id: id, request: request, destination: destination,
                    targetBookmark: try AccessLease.bookmark(directory, readOnly: false), options: ExportOptions(format: .tiff, longEdge: 64))
                let results = await ExportService(pipeline: pipeline).run([snapshot], catalog: catalog) { _ in }
                XCTAssertTrue(results.first?.hasPrefix("成功：") == true, results.joined(separator: "; "))
                let expected = try await pipeline.render(request, longEdge: 64, pixelFormat: .RGBA16)
                XCTAssertEqual(pixels(try read(destination)), pixels(expected.image), "Queue snapshots ignore later catalog edits")
                let saved = try XCTUnwrap(ExportService.logs(catalog: catalog).first { $0.id == id }?.snapshot.request.recipe)
                XCTAssertTrue(saved.isRaster)
                XCTAssertEqual(saved.exposure, recipe?.exposure ?? 0)
            }
        }
    }

    @MainActor func testRasterPanelKeepsKeyboardFieldsAndHidesRAWDetails() async throws {
        let source = try fixture("panel", type: .jpeg, depth: 8)
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("panel-catalog"))
        let root = try catalog.addRoot(url: directory, bookmark: source.root.bookmark)
        var photo = source.photo; photo.rootID = root.id; try catalog.index(photo)
        let model = AppModel(); model.catalog = catalog; try model.reload()
        model.choose([photo.id], active: photo.id)
        try await waitUntil { model.canEdit && model.previewCurrent }
        model.editMode = true
        let suite = "raster-panel-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "developBasicOpen"); preferences.set(true, forKey: "developDetailsOpen")
        preferences.set(false, forKey: "developSoloMode")
        for key in ["developCropOpen", "developMixerOpen", "developGradingOpen", "developCurvesOpen", "developZonesOpen", "developVignetteOpen", "developGrainOpen", "developBlackWhiteMixerOpen"] {
            preferences.set(false, forKey: key)
        }
        let host = NSHostingView(rootView: DevelopPanel(model: model).defaultAppStorage(preferences)
            .font(.system(size: 13)).background(Theme.panel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 336, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; model.choose([], active: nil) }
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
        try await waitUntil { descendants(host, AdjustmentNSSlider.self).count == 13 }
        XCTAssertFalse(descendants(host, AdjustmentNSSlider.self).contains { $0.accessibilityLabel() == "锐化" })
        let exposure = try XCTUnwrap(descendants(host, AdjustmentNSSlider.self).first { $0.accessibilityLabel() == "曝光度" })
        model.undo.groupsByEvent = false; model.undo.beginUndoGrouping()
        exposure.doubleValue = 0.35; exposure.changed()
        model.undo.endUndoGrouping()
        XCTAssertEqual(try XCTUnwrap(model.recipe?.exposure), 0.35, accuracy: 0.000001)
        try await waitUntil { descendants(host, NSTextField.self).contains { $0.stringValue.contains("0.35") } }
        let field = try XCTUnwrap(descendants(host, NSTextField.self).first { $0.stringValue.contains("0.35") })
        XCTAssertGreaterThan(field.bounds.width, 30)
        XCTAssertTrue(window.makeFirstResponder(field))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "g", charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
        XCTAssertNotNil(WorkspaceKeyboard.handle(key, model: model), "Typing inside a numeric field keeps its focus")
        XCTAssertTrue(model.editMode)
        model.undo.undo(); XCTAssertEqual(model.recipe?.exposure, 0)
        model.undo.redo(); XCTAssertEqual(try XCTUnwrap(model.recipe?.exposure), 0.35, accuracy: 0.000001)
        try await waitUntil { model.previewCurrent }
        for size in [CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900)] {
            let workspace = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
            window.setContentSize(size); window.contentView = workspace
            workspace.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let bitmap = try XCTUnwrap(workspace.bitmapImageRepForCachingDisplay(in: workspace.bounds))
            workspace.cacheDisplay(in: workspace.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "JPEG-workspace-\(Int(size.width))x\(Int(size.height))"; attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testModelSaveReopenUndoPresetBatchAndThumbnails() async throws {
        let jpeg = try fixture("workflow-a", type: .jpeg, depth: 8), tiff = try fixture("workflow-b"), png = try fixture("workflow-c", type: .png)
        @MainActor func exercise() async throws -> (URL, StorageRoot, Photo, EditRecipe, [Photo], [String]) {
            let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
            let root = try catalog.addRoot(url: directory, bookmark: jpeg.root.bookmark)
            var photos = [Photo]()
            for item in [jpeg, tiff, png] {
                var photo = item.photo; photo.rootID = root.id; try catalog.index(photo); photos.append(photo)
            }
            let sourceDigests = try photos.map { try SafeFileWriter.sha256(directory.appendingPathComponent($0.relativePath)) }
            let model = AppModel(); model.catalog = catalog; try model.reload(); model.editMode = true
            model.choose([photos[0].id], active: photos[0].id)
            try await waitUntil { model.canEdit && model.previewCurrent }
            let baseline = try XCTUnwrap(model.recipe)
            XCTAssertTrue(baseline.isRaster); XCTAssertNil(model.rawDefaults)
            model.undo.groupsByEvent = false
            model.undo.beginUndoGrouping()
            model.changeRecipe({ $0.exposure = 0.2 }, commit: false)
            model.changeRecipe({ r in
                r.exposure = 0.6; r.crop.width = 0.75
                r.develop.curves = ToneCurves()
                r.develop.curves?.channels[0][2] = CurvePoint(x:0.43,y:0.62)
                r.develop.curves?.insert(channel:1,x:0.36,y:0.42)
                r.develop.blackAndWhite = true; r.develop.blackWhiteMixer = [35,-20,15,-30,10,25,-15,40]
            }, commit: false)
            model.addMask(.radial)
            model.changeMask { $0.exposure = 0.5 }
            model.setMaskMode(false); model.setSpotMode(true)
            try await waitUntil { model.spotRank != nil && model.canvasCoordinatesCurrent && model.previewCurrent }
            model.spotPointer(CGPoint(x: 0.5, y: 0.5), phase: .down)
            model.spotPointer(CGPoint(x: 0.55, y: 0.5), phase: .up)
            model.setSpotMode(false)
            XCTAssertTrue(model.commitRecipe())
            model.undo.endUndoGrouping()
            let edited = try XCTUnwrap(model.recipe)
            XCTAssertFalse(edited.localAdjustments.isEmpty); XCTAssertFalse(edited.repairs.isEmpty)
            model.undo.undo(); XCTAssertEqual(model.recipe, baseline)
            model.undo.redo(); XCTAssertEqual(model.recipe, edited)
            XCTAssertTrue(model.saveSnapshot(name: "JPEG 编辑"))
            let stored = try XCTUnwrap(catalog.photo(photos[0].id))
            let thumbnail = try await ThumbnailService().image(photo: stored, root: root)
            XCTAssertEqual(thumbnail.width, 96, "The edited crop reaches thumbnails")
            var newRevision = stored; newRevision.recipeRevision += 1
            XCTAssertNotEqual(ThumbnailService.key(photo: stored, edge: 320), ThumbnailService.key(photo: newRevision, edge: 320))
            model.copyAdjustments()
            let options = RecipePasteOptions()
            XCTAssertTrue(model.savePreset(name: "成片", source: edited, options: options))
            let preset = try XCTUnwrap(catalog.presets().first)
            let presetRecipe = try JSONDecoder().decode(EditRecipe.self, from: preset.recipe)
            XCTAssertTrue(presetRecipe.isRaster); XCTAssertTrue(presetRecipe.repairs.isEmpty); XCTAssertTrue(presetRecipe.localAdjustments.isEmpty)
            XCTAssertTrue(model.applyAdjustments(source: presetRecipe, options: options, ids: [photos[1].id], title: "成片预设", amount: 0.5))
            try await waitUntil { !model.busy }
            XCTAssertNil(model.error)
            var applied = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photos[1].id)?.recipe))
            XCTAssertEqual(applied.develop.blackWhiteMixer,edited.develop.blackWhiteMixer.map { $0*0.5 })
            XCTAssertTrue(applied.develop.blackAndWhite)
            XCTAssertEqual(applied.exposure, 0.3, accuracy: 0.0001); XCTAssertEqual(applied.crop, Crop())
            XCTAssertTrue(applied.localAdjustments.isEmpty); XCTAssertTrue(applied.repairs.isEmpty)
            model.undo.undo(); XCTAssertNil(try catalog.photo(photos[1].id)?.recipe)
            model.undo.redo(); XCTAssertNotNil(try catalog.photo(photos[1].id)?.recipe)
            model.choose([photos[1].id], active: photos[1].id)
            try await waitUntil { model.canEdit && model.previewCurrent }
            model.undo.beginUndoGrouping()
            XCTAssertTrue(model.pasteAdjustments(options: options))
            model.undo.endUndoGrouping()
            XCTAssertEqual(model.recipe?.exposure, 0.6)
            XCTAssertEqual(model.recipe?.develop.curves,edited.develop.curves)
            XCTAssertEqual(model.recipe?.develop.blackWhiteMixer,edited.develop.blackWhiteMixer)
            var sync = edited; sync.exposure = 1.2
            XCTAssertTrue(model.applyAdjustments(source: sync, options: options, ids: Set(photos.map(\.id)), title: "同步"))
            try await waitUntil { !model.busy }
            applied = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photos[1].id)?.recipe))
            XCTAssertEqual(applied.exposure, 1.2)
            XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photos[0].id)?.recipe)).exposure, 1.2)
            model.undo.undo()
            XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photos[0].id)?.recipe)), edited)
            XCTAssertEqual(model.recipe?.exposure, 0.6)
            XCTAssertEqual(model.recipe?.develop.curves,edited.develop.curves)
            XCTAssertEqual(model.recipe?.develop.blackWhiteMixer,edited.develop.blackWhiteMixer)
            model.undo.redo(); XCTAssertEqual(model.recipe?.exposure, 1.2)
            model.undo.undo()
            model.choose([], active: nil); model.catalog = nil
            return (catalog.fileURL, root, stored, edited, photos, sourceDigests)
        }
        let (file, root, stored, edited, photos, sourceDigests) = try await exercise()
        let reopened = try CatalogStore(fileURL: file)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(reopened.photo(photos[0].id)?.recipe)), edited)
        XCTAssertEqual(try reopened.snapshots(photoID: photos[0].id).count, 1)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(reopened.snapshots(photoID:photos[0].id).first?.recipe)),edited)
        XCTAssertGreaterThan(try reopened.editHistory(photoID: photos[0].id).count, 2)
        let pipeline = ImagePipeline()
        let reread = try XCTUnwrap(reopened.photo(photos[0].id))
        let beforeClose = try await pipeline.render(ImageRequest(photo: stored, root: root, recipe: edited), longEdge: nil)
        let afterOpen = try await pipeline.render(ImageRequest(photo: reread, root: root, recipe: edited), longEdge: nil)
        XCTAssertEqual(pixels(beforeClose.image), pixels(afterOpen.image))
        for (index, photo) in photos.enumerated() {
            XCTAssertEqual(try SafeFileWriter.sha256(directory.appendingPathComponent(photo.relativePath)), sourceDigests[index])
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for raster editing")
        if !condition() { throw LRCError("Raster workflow timed out") }
    }
}
