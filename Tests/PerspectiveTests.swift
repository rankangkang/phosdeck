import XCTest
import CoreImage
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Phosdeck

final class PerspectiveTests: XCTestCase {
    private var folder: URL!
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAf,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
                   baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func grid(size: CGSize = CGSize(width: 160, height: 120)) -> CIImage {
        let w = Int(size.width), h = Int(size.height)
        var p = [Float](repeating: 1, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let i = (y*w+x)*4
            p[i] = Float(x+1)/Float(w+1); p[i+1] = Float(y+1)/Float(h+1)
            p[i+2] = x % 16 < 2 || y % 16 < 2 ? 0.9 : 0.05
        } }
        return CIImage(bitmapData: p.withUnsafeBytes { Data($0) }, bytesPerRow: w*16, size: size, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
    }
    private func fixture(_ name: String, orientation: Int = 1, type: UTType = .tiff) throws -> ImageRequest {
        let cg = try XCTUnwrap(context.createCGImage(grid(), from: grid().extent, format: .RGBA16, colorSpace: ImagePipeline.outputSpace))
        let url = folder.appendingPathComponent(name + (type == .jpeg ? ".jpg" : ".tif"))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, cg, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let root = StorageRoot(id: "grid", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "synthetic")
        return ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: folder), root: root, recipe: nil)
    }
    private func floats(_ image: CIImage) -> [Float] {
        let b = image.extent.integral
        var p = [Float](repeating: 0, count: Int(b.width*b.height)*4)
        context.render(image, toBitmap: &p, rowBytes: Int(b.width)*16, bounds: b, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return p
    }
    private func bytes(_ image: CGImage) -> Data {
        var p = Data(count: image.width*image.height*4)
        p.withUnsafeMutableBytes { context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: image.width*4,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace) }
        return p
    }
    private func point(_ p: MaskPoint, size: CGSize, recipe: EditRecipe) throws -> CGPoint {
        let g = try PhotoGeometry(size: size, recipe: recipe)
        let q = try XCTUnwrap(g.transform.point(CGPoint(x: p.x*size.width, y: p.y*size.height)))
        return CGPoint(x: q.x/g.output.width, y: q.y/g.output.height)
    }

    /// Independent camera-ray projection (not the production homography).
    private func cameraReference(_ p: CGPoint, size: CGSize, settings: PerspectiveSettings, inverse: Bool = false) -> CGPoint {
        let edge = max(size.width,size.height)/2, focal = 1.5
        let ax = -settings.vertical*0.005, ay = settings.horizontal*0.005
        func project(_ x: Double, _ y: Double, backward: Bool = false) -> CGPoint {
            let ray = SIMD3(x/focal,y/focal,1)
            let a: SIMD3<Double>, b: SIMD3<Double>
            if backward {
                a = SIMD3(cos(ay)*ray.x-sin(ay)*ray.z,ray.y,sin(ay)*ray.x+cos(ay)*ray.z)
                b = SIMD3(a.x,cos(ax)*a.y+sin(ax)*a.z,-sin(ax)*a.y+cos(ax)*a.z)
            } else {
                a = SIMD3(ray.x,cos(ax)*ray.y-sin(ax)*ray.z,sin(ax)*ray.y+cos(ax)*ray.z)
                b = SIMD3(cos(ay)*a.x+sin(ay)*a.z,a.y,-sin(ay)*a.x+cos(ay)*a.z)
            }
            return CGPoint(x:focal*b.x/b.z,y:focal*b.y/b.z)
        }
        let o = project(0,0), px = project(1e-4,0), py = project(0,1e-4)
        let determinant = abs(((px.x-o.x)*(py.y-o.y)-(px.y-o.y)*(py.x-o.x))/1e-8)
        let scale = 1/sqrt(determinant), aspect = pow(2,settings.aspect/200)
        var q = CGPoint(x:(p.x-size.width/2)/edge,y:(size.height/2-p.y)/edge)
        if inverse { q = project(q.x/scale*aspect+o.x,q.y/scale/aspect+o.y,backward:true) }
        else { let v = project(q.x,q.y); q = CGPoint(x:(v.x-o.x)*scale/aspect,y:(v.y-o.y)*scale*aspect) }
        return CGPoint(x:size.width/2+q.x*edge,y:size.height/2-q.y*edge)
    }

    func testPinnedUpstreamMatricesSignsCenterAndAspect() throws {
        XCTAssertEqual(PhotoGeometry.pixelIndex(0.45-Double.ulpOfOne,dimension:160),72)
        XCTAssertEqual(PhotoGeometry.pixelIndex(0.45-1e-8,dimension:160),71)
        XCTAssertEqual(PhotoGeometry.pixelIndex(1,dimension:160),159)
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/lightcraft-adaptation-vectors.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        for row in try XCTUnwrap(json["perspective"] as? [[String:Any]]) {
            let p = try XCTUnwrap(row["parameters"] as? [Double]), m = try XCTUnwrap(row["matrix"] as? [Double])
            let s = PerspectiveSettings(horizontal:p[0],vertical:p[1],aspect:p[2],constrainCrop:false)
            for size in [CGSize(width:6000,height:4000),CGSize(width:300,height:500)] {
                let e = max(size.width,size.height)/2
                for v in [CGPoint(x:-0.8,y:-0.6),.zero,CGPoint(x:0.3,y:0.5)] {
                    let w = m[6]*v.x+m[7]*v.y+m[8]
                    let expected = CGPoint(x:size.width/2+e*(m[0]*v.x+m[1]*v.y+m[2])/w,
                        y:size.height/2-e*(m[3]*v.x+m[4]*v.y+m[5])/w)
                    let source = CGPoint(x:size.width/2+e*v.x,y:size.height/2-e*v.y)
                    let actual = try XCTUnwrap(s.transform(canvas:size).point(source))
                    XCTAssertEqual(actual.x,expected.x,accuracy:1e-8); XCTAssertEqual(actual.y,expected.y,accuracy:1e-8)
                }
            }
        }
        let size = CGSize(width:600,height:400)
        let vertical = PerspectiveSettings(vertical:-50,constrainCrop:false).transform(canvas:size)
        let top = try XCTUnwrap(vertical.point(CGPoint(x:600,y:400)))
        let bottom = try XCTUnwrap(vertical.point(CGPoint(x:600,y:0)))
        XCTAssertGreaterThan(top.x-300,bottom.x-300,"负垂直扩大上方")
        let horizontal = PerspectiveSettings(horizontal:-50,constrainCrop:false).transform(canvas:size)
        XCTAssertGreaterThan(try XCTUnwrap(horizontal.point(CGPoint(x:0,y:400))).y-200,
                             try XCTUnwrap(horizontal.point(CGPoint(x:600,y:400))).y-200,"负水平扩大左侧")
        let aspect = PerspectiveSettings(aspect:100,constrainCrop:false).transform(canvas:size)
        XCTAssertEqual(try XCTUnwrap(aspect.point(CGPoint(x:400,y:300))).x,300+100/sqrt(2),accuracy:1e-10)
        XCTAssertEqual(try XCTUnwrap(aspect.point(CGPoint(x:400,y:300))).y,200+100*sqrt(2),accuracy:1e-10)
    }

    func testStrictRecipeValidationResetPasteAndPreset() throws {
        let base = recipe()
        var r = base; r.perspective = PerspectiveSettings(horizontal: 40, vertical: -60, aspect: 20, constrainCrop: false)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(r)), r)
        XCTAssertEqual(r.baseline().perspective, PerspectiveSettings())
        XCTAssertEqual(r.alignedBaseline().perspective, r.perspective)
        XCTAssertTrue(r.changeTitle(from: base).contains("手动透视"))
        XCTAssertEqual(try base.pasting(r, options: RecipePasteOptions()).perspective, base.perspective)
        let onlyGeometry = RecipePasteOptions(tone: false, whiteBalance: false, color: false, geometry: true, curves: false, zones: false)
        XCTAssertEqual(try base.pasting(r, options: onlyGeometry).perspective, r.perspective)
        let half = try base.applyingPreset(r, options: onlyGeometry, amount: 0.5)
        XCTAssertEqual(half.perspective.horizontal, 20); XCTAssertEqual(half.perspective.vertical, -30)
        XCTAssertEqual(half.perspective.aspect, 10); XCTAssertFalse(half.perspective.constrainCrop)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        json.removeValue(forKey: "perspective")
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: json)))
        var old = r.perspective; old.model = "projective-v1"; XCTAssertThrowsError(try old.validate())
        var oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(r.perspective)) as? [String:Any])
        oldJSON.removeValue(forKey:"model")
        XCTAssertThrowsError(try JSONDecoder().decode(PerspectiveSettings.self,from:JSONSerialization.data(withJSONObject:oldJSON)))
        for invalid in [Double.nan, .infinity, -.infinity, -100.001, 100.001] {
            for key in [\PerspectiveSettings.horizontal, \.vertical, \.aspect] {
                var bad = r; bad.perspective[keyPath: key] = invalid; XCTAssertThrowsError(try bad.validate())
            }
        }
        r = base; r.perspective.constrainCrop = false
        XCTAssertTrue(r.isUnadjustedRaster, "中性透视的约束开关不能改变 JPEG/TIFF 中性像素路径")
    }

    func testNeutralIsExactlyThePreviousGeometryIncludingFractionalCrop() throws {
        let image = grid(), size = image.extent.size
        // Independent copy of the pre-perspective renderer, including all original sampling nodes.
        func previous(_ r: EditRecipe) -> CIImage {
            var i = ImagePipeline.originZero(image.oriented([.up, .right, .down, .left][r.quarterTurns]))
            let s = i.extent.size
            if r.straightenDegrees != 0 { i = i.transformed(by: CropPreviewGeometry.transform(size: s, degrees: r.straightenDegrees)).cropped(to: CGRect(origin: .zero, size: s)) }
            let c = r.crop
            i = ImagePipeline.originZero(i.cropped(to: CGRect(x: c.x*s.width, y: c.y*s.height, width: c.width*s.width, height: c.height*s.height).integral.intersection(i.extent)))
            if r.flipHorizontal || r.flipVertical { i = ImagePipeline.originZero(i.oriented(r.flipHorizontal && r.flipVertical ? .down : r.flipHorizontal ? .upMirrored : .downMirrored)) }
            return i
        }
        for turn in 0...3 { for angle in [-45.0, -7.3, 0, 11, 45] { for flip in 0...3 {
            var r = recipe(); r.quarterTurns = turn; r.straightenDegrees = angle
            r.flipHorizontal = flip&1 != 0; r.flipVertical = flip&2 != 0
            r.crop = Crop(x: 0.103, y: 0.217, width: 0.621, height: 0.579)
            let expected = previous(r), actual = try ImagePipeline.geometry(image, recipe: r)
            XCTAssertEqual(actual.extent, expected.extent)
            XCTAssertEqual(floats(actual), floats(expected), "中性几何逐浮点值相同")
            XCTAssertEqual(try PhotoGeometry(size: size, recipe: r).output, actual.extent.size)
        } } }
    }

    func testForwardInverseExtremeParametersAndInvalidCoordinates() throws {
        let size = CGSize(width: 6000, height: 4000)
        for horizontal in [-100.0, 0, 100] { for vertical in [-100.0, 0, 100] { for aspect in [-100.0, 0, 100] {
            for turn in 0...3 { for flip in 0...3 { for angle in [-45.0, 0, 45] {
                var r = recipe(); r.quarterTurns = turn; r.straightenDegrees = angle
                r.flipHorizontal = flip&1 != 0; r.flipVertical = flip&2 != 0
                r.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                r.perspective = PerspectiveSettings(horizontal: horizontal, vertical: vertical, aspect: aspect)
                let g = try PhotoGeometry(size: size, recipe: r)
                XCTAssertGreaterThan(g.output.width, 0); XCTAssertGreaterThan(g.output.height, 0)
                for p in [MaskPoint(0.4, 0.6), MaskPoint(0.5, 0.5), MaskPoint(0.6, 0.4)] {
                    let output = try point(p, size: size, recipe: r)
                    let inverse = try XCTUnwrap(MaskGeometry.sourcePoint(output, size: size, recipe: r, allowOutside: true))
                    XCTAssertEqual(inverse.x, p.x, accuracy: 1e-10); XCTAssertEqual(inverse.y, p.y, accuracy: 1e-10)
                }
            } } }
        } } }
        for s in [CGSize.zero, CGSize(width: CGFloat.nan, height: 10), CGSize(width: 1e100, height: 1e100), CGSize(width: -10, height: 20)] {
            XCTAssertThrowsError(try PhotoGeometry(size: s, recipe: recipe()))
            XCTAssertNil(MaskGeometry.sourcePoint(CGPoint(x: 0.5, y: 0.5), size: s, recipe: recipe()))
        }
        for p in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: .infinity, y: 0.5), CGPoint(x: -0.01, y: 0.5)] {
            XCTAssertNil(MaskGeometry.sourcePoint(p, size: size, recipe: recipe()))
        }
        XCTAssertNil(PhotoTransform(values: Array(repeating: 0, count: 9)).inverted().point(.zero))
        var r = recipe(); r.crop.width = 0; XCTAssertThrowsError(try PhotoGeometry(size: size, recipe: r))
        r = recipe(); r.perspective.horizontal = 100; r.crop = Crop(x: 0.0, y: 0.95, width: 0.05, height: 0.05)
        XCTAssertThrowsError(try PhotoGeometry(size: size, recipe: r), "空白中心不能静默移动取景")
    }

    func testRenderMatchesIndependentProjectionAndBlankBoundaryContract() throws {
        let size = CGSize(width: 160, height: 120)
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        let marker = CIImage(color: .white).cropped(to: CGRect(x: 70, y: 66, width: 5, height: 5)).composited(over: black)
        for turn in 0...3 { for angle in [-9.0, 0, 12] { for flip in 0...3 {
            var r = recipe(); r.quarterTurns = turn; r.straightenDegrees = angle
            r.flipHorizontal = flip&1 != 0; r.flipVertical = flip&2 != 0
            r.perspective = PerspectiveSettings(horizontal: 65, vertical: -45, aspect: 18, constrainCrop: false)
            r.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            let g = try PhotoGeometry(size: size, recipe: r)
            var p = CGPoint(x: 72.5, y: 68.5)
            switch turn { case 1: p = CGPoint(x: p.y, y: size.width-p.x); case 2: p = CGPoint(x: size.width-p.x, y: size.height-p.y); case 3: p = CGPoint(x: size.height-p.y, y: p.x); default: break }
            p = p.applying(CropPreviewGeometry.transform(size: g.canvas, degrees: angle))
            p = cameraReference(p,size:g.canvas,settings:r.perspective)
            p.x -= g.cropRect.minX; p.y -= g.cropRect.minY
            if r.flipHorizontal { p.x = g.output.width-p.x }; if r.flipVertical { p.y = g.output.height-p.y }
            let actualPoint = try XCTUnwrap(g.transform.point(CGPoint(x: 72.5, y: 68.5)))
            XCTAssertEqual(actualPoint.x, p.x, accuracy: 1e-9); XCTAssertEqual(actualPoint.y, p.y, accuracy: 1e-9)
            let rendered = try ImagePipeline.geometry(marker, recipe: r)
            var pixel = [Float](repeating: 0, count: 4)
            context.render(rendered, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: floor(p.x), y: floor(p.y), width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            XCTAssertGreaterThan(pixel[0], 0.8, "旋转/拉直/透视/裁剪/翻转后的标记贴合")
        } } }
        for h in [-100.0, 100] { for v in [-100.0, 100] { for a in [-100.0, 100] {
            var r = recipe(); r.perspective = PerspectiveSettings(horizontal: h, vertical: v, aspect: a, constrainCrop: false)
            let free = try ImagePipeline.geometry(grid(), recipe: r), values = floats(free)
            XCTAssertEqual(free.extent.size, size)
            XCTAssertTrue(stride(from: 3, to: values.count, by: 4).contains { values[$0] == 0 }, "无约束必须保留真实透明边界")
            for i in stride(from: 0, to: values.count, by: 4) where values[i+3] == 0 { XCTAssertEqual(values[i], 0); XCTAssertEqual(values[i+1], 0); XCTAssertEqual(values[i+2], 0) }
            r.perspective.constrainCrop = true
            let constrained = try ImagePipeline.geometry(grid(), recipe: r), opaque = floats(constrained)
            XCTAssertTrue(stride(from: 3, to: opaque.count, by: 4).allSatisfy { abs(opaque[$0]-1) < 1e-5 }, "约束后没有透明边界，不能复制源边缘")
        } } }
    }

    func testEXIFIsAppliedOnceAndCropEditorUsesTheSameContent() async throws {
        let pipeline = ImagePipeline()
        for type in [UTType.tiff, .jpeg] { for exif in 1...8 {
            let source = try fixture("exif-\(type.identifier)-\(exif)", orientation: exif, type: type)
            var r = try await pipeline.baseline(source)
            r.quarterTurns = exif%4; r.straightenDegrees = 7
            r.flipHorizontal = exif&1 != 0; r.flipVertical = exif&2 != 0
            r.perspective = PerspectiveSettings(horizontal: -35, vertical: 42, aspect: 12)
            r.crop = Crop(x: 0.15, y: 0.12, width: 0.7, height: 0.72)
            let job = ImageRequest(photo: source.photo, root: source.root, recipe: r)
            let result = try await pipeline.render(job, longEdge: nil)
            let decoded = try XCTUnwrap(CIImage(contentsOf: folder.appendingPathComponent(source.photo.name), options: [.applyOrientationProperty: true]))
            let expected = try ImagePipeline.geometry(decoded, recipe: r)
            let bitmap = try XCTUnwrap(context.createCGImage(expected, from: expected.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
            XCTAssertEqual(bytes(result.image), bytes(bitmap))
            XCTAssertEqual(result.orientedSourceSize, ImagePipeline.originZero(decoded).extent.size)
            XCTAssertEqual(r.cropPreviewAngle, 0)
            let preview = try ImagePipeline.geometry(decoded, recipe: r.cropRenderRecipe)
            let crop = try XCTUnwrap(r.effectiveCropInDisplay(size: result.orientedSourceSize))
            let rect = CGRect(x: (crop.x*preview.extent.width).rounded(), y: (crop.y*preview.extent.height).rounded(),
                              width: (crop.width*preview.extent.width).rounded(), height: (crop.height*preview.extent.height).rounded())
            let croppedPreview = ImagePipeline.originZero(preview.cropped(to: rect))
            XCTAssertEqual(croppedPreview.extent.width, expected.extent.width, accuracy: 1e-9)
            let shown = try XCTUnwrap(context.createCGImage(croppedPreview, from: croppedPreview.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
            XCTAssertEqual(bytes(shown), bytes(bitmap))
            XCTAssertEqual(r.cropFromDisplay(r.cropInDisplay), r.crop)
        } }
    }

    func testFloatSamplingAgainstIndependentBilinearReference() throws {
        let input = grid(), source = floats(input), w = 160, h = 120
        var r = recipe(); r.perspective = PerspectiveSettings(horizontal: 61, vertical: -47, aspect: 21, constrainCrop: false)
        let rendered = floats(try ImagePipeline.geometry(input, recipe: r))
        var count = 0
        for y in stride(from: 20, through: 100, by: 9) { for x in stride(from: 25, through: 135, by: 11) {
            // Bitmap readback rows are top-first; geometry uses bottom-left pixels.
            let p = cameraReference(CGPoint(x:Double(x)+0.5,y:Double(h-y)-0.5),size:input.extent.size,settings:r.perspective,inverse:true)
            let sx = p.x-0.5, sy = p.y-0.5
            guard sx >= 1, sx < Double(w-2), sy >= 1, sy < Double(h-2) else { continue }
            let ix = Int(floor(sx)), iy = Int(floor(sy)), fx = Float(sx-Double(ix)), fy = Float(sy-Double(iy))
            for c in 0..<4 {
                let bottom = source[((h-1-iy)*w+ix)*4+c]*(1-fx)+source[((h-1-iy)*w+ix+1)*4+c]*fx
                let top = source[((h-2-iy)*w+ix)*4+c]*(1-fx)+source[((h-2-iy)*w+ix+1)*4+c]*fx
                XCTAssertEqual(rendered[(y*w+x)*4+c], bottom*(1-fy)+top*fy, accuracy: 0.00005)
            }
            count += 1
        } }
        XCTAssertGreaterThan(count, 50)
    }

    func testMaskAndRepairSourceCoordinatesAndScaledCoverage() throws {
        var r = recipe(); r.quarterTurns = 1; r.straightenDegrees = -8; r.flipHorizontal = true
        r.perspective = PerspectiveSettings(horizontal: 60, vertical: -40, aspect: -15)
        r.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let size = CGSize(width: 160, height: 120), p = MaskPoint(0.45, 0.55)
        for tool in [MaskTool.brush, .linear, .radial, .color, .luminance] {
            let output = try point(p, size: size, recipe: r)
            let source = try XCTUnwrap(MaskGeometry.sourcePoint(output, size: size, recipe: r))
            XCTAssertEqual(source.x, p.x, accuracy: 1e-10); XCTAssertEqual(source.y, p.y, accuracy: 1e-10)
            var c = MaskComponent(tool: tool); c.start = p; c.end = MaskPoint(0.65, 0.55); c.radiusX = 0.1; c.radiusY = 0.12
            if tool.isGradient {
                for handle in MaskEditGesture.handles(c, size: size) {
                    let q = try point(handle.point, size: size, recipe: r)
                    let back = try XCTUnwrap(MaskGeometry.sourcePoint(q, size: size, recipe: r, allowOutside: true))
                    XCTAssertEqual(back.x, handle.point.x, accuracy: 1e-9); XCTAssertEqual(back.y, handle.point.y, accuracy: 1e-9)
                }
            }
        }
        let repair = SpotRepair(mode: .clone, points: [p], radius: 0.06, feather: 0, sourceOffset: MaskPoint(0.15, 0))
        var buffer = SpotBuffer(width: 160, height: 120, pixels: Array(repeating: SIMD3<Float>(repeating: 0.2), count: 160*120))
        for y in 60..<72 { for x in 90..<104 { buffer.set(x, y, SIMD3(repeating: 0.9)) } }
        let repaired = SpotRepairMath.render(buffer, repairs: [repair]).buffer
        let image = try ImagePipeline.geometry(SpotRepairPipeline.image(repaired), recipe: r)
        let target = try point(p, size: size, recipe: r)
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: floor(target.x*image.extent.width), y: floor(target.y*image.extent.height), width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        XCTAssertGreaterThan(pixel[0], 0.75)
        let source = MaskPoint(p.x+0.15, p.y), sourceOutput = try point(source, size: size, recipe: r)
        let sourceBack = try XCTUnwrap(MaskGeometry.sourcePoint(sourceOutput, size: size, recipe: r))
        XCTAssertEqual(sourceBack.x, source.x, accuracy: 1e-9)
        let small = grid(size: CGSize(width: 80, height: 60))
        let coverage = try ImagePipeline.geometry(small, recipe: r, referenceSize: size)
        let g = try PhotoGeometry(size: size, recipe: r)
        XCTAssertEqual(coverage.extent.width, g.output.width/2, accuracy: 1e-10)
        XCTAssertEqual(coverage.extent.height, g.output.height/2, accuracy: 1e-10)
        let path = CGPath(ellipseIn: CGRect(x: 64, y: 52, width: 16, height: 16), transform: nil)
        let projected = g.transform.path(path)
        XCTAssertTrue(projected.boundingBoxOfPath.contains(CGPoint(x: target.x*g.output.width, y: target.y*g.output.height)))
    }

    func testSourceInverseReadsActualPixelsWithOddQuarterTurns() throws {
        let input = grid()
        let size = input.extent.size
        func pixel(_ image: CIImage, x: Int, y: Int) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return values
        }
        for turn in [1, 3] {
            for flip in 0...3 {
                var r = recipe()
                r.quarterTurns = turn
                r.crop = Crop(x: 0.11, y: 0.24, width: 0.69, height: 0.63)
                r.flipHorizontal = flip & 1 != 0
                r.flipVertical = flip & 2 != 0
                let output = try ImagePipeline.geometry(input, recipe: r)
                for (x, y) in [(5, 17), (24, 35), (59, 68)] {
                    let displayed = CGPoint(x: (Double(x) + 0.5) / output.extent.width,
                                            y: (Double(y) + 0.5) / output.extent.height)
                    let mapped = try XCTUnwrap(MaskGeometry.sourcePoint(displayed, size: size, recipe: r))
                    let source = pixel(input, x: PhotoGeometry.pixelIndex(mapped.x, dimension: Int(size.width)),
                                       y: PhotoGeometry.pixelIndex(mapped.y, dimension: Int(size.height)))
                    for (actual, expected) in zip(pixel(output, x: x, y: y), source) {
                        XCTAssertEqual(actual, expected, accuracy: 0.00001, "turn=\(turn) flip=\(flip) at \(x),\(y)")
                    }
                }
            }
        }
    }

    func testSameSizePreviewExportAlphaAndTIFF16Precision() async throws {
        let source = try fixture("export"), pipeline = ImagePipeline()
        var r = try await pipeline.baseline(source)
        r.perspective = PerspectiveSettings(horizontal: 70, vertical: -55, aspect: 30)
        r.quarterTurns = 1; r.straightenDegrees = 6; r.flipVertical = true
        r.develop.blackAndWhite = true; r.develop.blackWhiteMixer = [80,-60,40,-20,50,-70,90,-30]
        r.develop.mixer[0].hue = 45; r.develop.vibrance = 30
        for constrained in [true, false] {
            r.perspective.constrainCrop = constrained
            let job = ImageRequest(photo: source.photo, root: source.root, recipe: r)
            let preview = try await pipeline.render(job, longEdge: 100)
            let png = folder.appendingPathComponent("output-\(constrained).png")
            _ = try await pipeline.export(job, staging: png, options: ExportOptions(format: .png, longEdge: 100))
            let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
            XCTAssertEqual(bytes(preview.image), bytes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))))
            let deep = try await pipeline.render(job, longEdge: 100, pixelFormat: .RGBA16)
            let tiff = folder.appendingPathComponent("output-\(constrained).tif")
            _ = try await pipeline.export(job, staging: tiff, options: ExportOptions(format: .tiff, longEdge: 100))
            let tiffSource = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
            let high = try XCTUnwrap(CGImageSourceCreateImageAtIndex(tiffSource, 0, nil))
            XCTAssertEqual(high.bitsPerComponent, 16)
            var a = [UInt16](repeating: 0, count: high.width*high.height*4), b = a
            let bounds = CGRect(x: 0, y: 0, width: high.width, height: high.height)
            context.render(CIImage(cgImage: high), toBitmap: &a, rowBytes: high.width*8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
            context.render(CIImage(cgImage: deep.image), toBitmap: &b, rowBytes: high.width*8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
            XCTAssertEqual(a, b); XCTAssertGreaterThan(Set(stride(from: 0, to: a.count, by: 4).map { a[$0] }).count, 256)
            if !constrained {
                let jpeg = folder.appendingPathComponent("black.jpg")
                _ = try await pipeline.export(job, staging: jpeg, options: ExportOptions(format: .jpeg, longEdge: 100, quality: 1, jpegMatte: .black))
                let jpg = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
                let jpgBytes = bytes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(jpg, 0, nil)))
                XCTAssertTrue(stride(from: 3, to: jpgBytes.count, by: 4).allSatisfy { jpgBytes[$0] == 255 })
                let rgba = bytes(preview.image)
                XCTAssertTrue(stride(from: 0, to: rgba.count, by: 4).contains { rgba[$0+3] == 0 && jpgBytes[$0] < 3 && jpgBytes[$0+1] < 3 && jpgBytes[$0+2] < 3 })
            }
        }
    }
    func testPublicRAWKeepsFloatGeometryAndSameSizeExport() async throws {
        let source = try MoreRAWTests.request("a7iii_12bit_compressed.ARW"), pipeline = ImagePipeline()
        var r = try await pipeline.baseline(source)
        r.perspective = PerspectiveSettings(horizontal: 35, vertical: -22, aspect: 8)
        r.flipHorizontal = true
        let job = ImageRequest(photo: source.photo, root: source.root, recipe: r)
        let preview = try await pipeline.render(job, longEdge: 160)
        let png = folder.appendingPathComponent("raw.png")
        _ = try await pipeline.export(job, staging: png, options: ExportOptions(format: .png, longEdge: 160))
        let pngSource = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        XCTAssertEqual(bytes(preview.image), bytes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(pngSource, 0, nil))))
        let tiff = folder.appendingPathComponent("raw.tif")
        _ = try await pipeline.export(job, staging: tiff, options: ExportOptions(format: .tiff, longEdge: 160))
        let highSource = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil))
        XCTAssertEqual(try XCTUnwrap(CGImageSourceCreateImageAtIndex(highSource, 0, nil)).bitsPerComponent, 16)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        XCTFail("等待透视工作流超时"); throw LRCError("透视工作流超时")
    }
    @MainActor func testSliderKeyboardAndAccessibilityUseDeclaredStep() throws {
        let slider = AdjustmentNSSlider(); slider.minValue = -100; slider.maxValue = 100; slider.step = 0.1; slider.doubleValue = 35
        var changes: [Double] = []; var commits = 0
        slider.change = { changes.append($0) }; slider.commit = { commits += 1 }
        func key(_ code: UInt16) throws {
            slider.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
        }
        try key(124); XCTAssertEqual(slider.doubleValue, 35.1, accuracy: 1e-10)
        try key(126); XCTAssertEqual(slider.doubleValue, 35.2, accuracy: 1e-10)
        try key(123); try key(125); XCTAssertEqual(slider.doubleValue, 35, accuracy: 1e-10)
        XCTAssertTrue(slider.accessibilityPerformIncrement()); XCTAssertEqual(slider.doubleValue, 35.1, accuracy: 1e-10)
        XCTAssertTrue(slider.accessibilityPerformDecrement()); XCTAssertEqual(slider.doubleValue, 35, accuracy: 1e-10)
        XCTAssertEqual(changes.count, 6); XCTAssertEqual(commits, 6)
        slider.doubleValue = 100; try key(124); XCTAssertEqual(slider.doubleValue, 100)
        slider.isEnabled = false; XCTAssertFalse(slider.accessibilityPerformDecrement()); try key(123); XCTAssertEqual(slider.doubleValue, 100)
        slider.isEnabled = true; slider.minValue = 2000; slider.maxValue = 50000; slider.step = 50; slider.doubleValue = 5500
        try key(124); XCTAssertEqual(slider.doubleValue, 5550, "白平衡也应使用自己的声明步进")
    }
    @MainActor func testWorkflowPointersUndoSnapshotThumbnailBatchAndReopen() async throws {
        let fixture = try fixture("workflow"), original = folder.appendingPathComponent(fixture.photo.name)
        let digest = try SafeFileWriter.sha256(original)
        var catalog: CatalogStore? = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        let root = try catalog!.addRoot(url: folder, bookmark: AccessLease.bookmark(folder, readOnly: true))
        var photo = fixture.photo; photo.rootID = root.id; try catalog!.index(photo)
        let model = AppModel(); model.catalog = catalog; model.undo.groupsByEvent = false; try model.reload()
        model.choose([photo.id], active: photo.id); try await wait { model.canEdit && model.previewCurrent }
        let baseline = try XCTUnwrap(model.recipe)
        model.undo.beginUndoGrouping()
        model.changeRecipe { $0.perspective = PerspectiveSettings(horizontal: 40, vertical: -25, aspect: 10); $0.flipHorizontal = true; $0.quarterTurns = 1; $0.straightenDegrees = 7 }
        model.undo.endUndoGrouping()
        XCTAssertFalse(model.canvasCoordinatesCurrent)
        model.undo.undo(); XCTAssertEqual(model.recipe, baseline)
        model.undo.redo(); XCTAssertEqual(model.recipe?.perspective.horizontal, 40)
        try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }
        let size = try XCTUnwrap(model.orientedSourceSize), source = MaskPoint(0.45, 0.55)
        model.undo.beginUndoGrouping(); model.addMask(.brush); model.undo.endUndoGrouping()
        try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }
        let output = try point(source, size: size, recipe: XCTUnwrap(model.recipe))
        model.undo.beginUndoGrouping(); model.maskPointer(output, phase: .down); model.maskPointer(output, phase: .up); model.undo.endUndoGrouping()
        let brush = try XCTUnwrap(model.selectedMaskComponent?.strokes.first?.points.first)
        XCTAssertEqual(brush.x, source.x, accuracy: 1e-9); XCTAssertEqual(brush.y, source.y, accuracy: 1e-9)
        model.undo.beginUndoGrouping(); model.addMask(.color); model.undo.endUndoGrouping()
        try await wait { model.maskReference != nil && model.previewCurrent }
        model.undo.beginUndoGrouping(); model.maskPointer(output, phase: .down); model.maskPointer(output, phase: .up); model.undo.endUndoGrouping()
        let sample = try XCTUnwrap(model.selectedMaskComponent?.samples.first)
        XCTAssertEqual(sample.point.x, source.x, accuracy: 1e-9); XCTAssertEqual(sample.point.y, source.y, accuracy: 1e-9)
        let referenceImage = try XCTUnwrap(model.maskReference)
        var rgb = [Float](repeating: 0, count: 4)
        context.render(CIImage(cgImage: referenceImage), toBitmap: &rgb, rowBytes: 16,
                       bounds: CGRect(x: floor(source.x*Double(referenceImage.width)), y: floor(source.y*Double(referenceImage.height)), width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        XCTAssertEqual(sample.red, Double(rgb[0]), accuracy: 1e-6); XCTAssertEqual(sample.green, Double(rgb[1]), accuracy: 1e-6)
        for tool in [MaskTool.linear, .radial] {
            model.undo.beginUndoGrouping(); model.addMask(tool); model.undo.endUndoGrouping()
            try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }
            let end = MaskPoint(0.6, 0.65), endOutput = try point(end, size: size, recipe: XCTUnwrap(model.recipe))
            model.undo.beginUndoGrouping(); model.maskPointer(output, phase: .down); model.maskPointer(endOutput, phase: .drag); model.maskPointer(endOutput, phase: .up); model.undo.endUndoGrouping()
            let c = try XCTUnwrap(model.selectedMaskComponent)
            XCTAssertEqual(c.start.x, tool == .linear ? end.x : source.x, accuracy: 1e-9)
            XCTAssertEqual(c.start.y, tool == .linear ? end.y : source.y, accuracy: 1e-9)
        }
        model.setSpotMode(true); try await wait { model.spotRank != nil && model.previewCurrent && model.canvasCoordinatesCurrent }
        model.spotKind = .clone
        model.undo.beginUndoGrouping(); model.spotPointer(output, phase: .down); model.spotPointer(output, phase: .up); model.undo.endUndoGrouping()
        let target = try XCTUnwrap(model.recipe?.repairs.first?.points.first)
        XCTAssertEqual(target.x, source.x, accuracy: 1e-9); XCTAssertEqual(target.y, source.y, accuracy: 1e-9)
        let oldToken = model.spotRankToken
        model.undo.beginUndoGrouping(); model.changeRecipe { $0.perspective.vertical = 30 }; model.undo.endUndoGrouping()
        XCTAssertFalse(model.canvasCoordinatesCurrent); XCTAssertNil(model.spotGesture); XCTAssertNotEqual(model.spotRankToken, oldToken)
        let count = model.recipe?.repairs.count
        model.spotPointer(output, phase: .down); model.spotPointer(output, phase: .up); XCTAssertEqual(model.recipe?.repairs.count, count)
        try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }
        model.setSpotMode(false); model.toggleZoneSampling()
        try await wait { model.zoneReference != nil && model.canvasCoordinatesCurrent && model.previewCurrent }
        let zoneToken = model.zoneReferenceToken
        model.undo.beginUndoGrouping(); model.changeRecipe { $0.perspective.horizontal = 41 }; model.undo.endUndoGrouping()
        XCTAssertFalse(model.zoneSampling); XCTAssertNil(model.zoneReference); XCTAssertNotEqual(model.zoneReferenceToken, zoneToken)
        try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }
        XCTAssertTrue(model.saveSnapshot(name: "透视与翻转"))
        model.setSpotMode(false); model.copyAdjustments()
        var sourceRecipe = try XCTUnwrap(model.recipe)
        let another = try self.fixture("batch-target")
        var targetPhoto = another.photo; targetPhoto.rootID = root.id; try catalog!.index(targetPhoto); try model.reload()
        model.choose([targetPhoto.id], active: targetPhoto.id); try await wait { model.previewCurrent && model.activeID == targetPhoto.id }
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.pasteAdjustments(options: RecipePasteOptions(tone: false, whiteBalance: false, color: false, geometry: true, curves: false, zones: false)))
        model.undo.endUndoGrouping()
        try await wait { !model.applyingAdjustments && model.recipe?.perspective == sourceRecipe.perspective }
        model.undo.undo(); XCTAssertEqual(model.recipe?.perspective, PerspectiveSettings())
        model.undo.redo(); XCTAssertEqual(model.recipe?.perspective, sourceRecipe.perspective)
        var synced = sourceRecipe; synced.perspective.aspect = 12
        let geometry = RecipePasteOptions(tone: false, whiteBalance: false, color: false, geometry: true, curves: false, zones: false)
        XCTAssertTrue(model.applyAdjustments(source: synced, options: geometry, ids: [photo.id, targetPhoto.id], title: "同步手动透视"))
        await model.task?.value
        XCTAssertEqual(model.reports.filter { $0.hasPrefix("成功：") }.count, 2)
        for id in [photo.id, targetPhoto.id] {
            XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog!.photo(id)?.recipe)).perspective, synced.perspective)
        }
        model.undo.undo()
        for id in [photo.id, targetPhoto.id] {
            XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog!.photo(id)?.recipe)).perspective, sourceRecipe.perspective)
        }
        model.undo.redo()
        sourceRecipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog!.photo(photo.id)?.recipe))
        XCTAssertEqual(sourceRecipe.perspective, synced.perspective)
        let current = try XCTUnwrap(catalog!.photo(photo.id)), thumbnails = ThumbnailService()
        let thumb = try await thumbnails.image(photo: current, root: root, edge: 80)
        let reference = try await model.pipeline.render(ImageRequest(photo: current, root: root, recipe: sourceRecipe), longEdge: 80)
        XCTAssertEqual(bytes(thumb), bytes(reference.image)); XCTAssertNotEqual(ThumbnailService.key(photo: photo, edge: 80), ThumbnailService.key(photo: current, edge: 80))
        model.catalog = nil; model.undo.removeAllActions(); catalog = nil
        let reopened = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        let saved = try XCTUnwrap(reopened.photo(photo.id)?.recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: saved), sourceRecipe)
        XCTAssertEqual(try reopened.snapshots(photoID: photo.id).first?.title, "透视与翻转")
        XCTAssertTrue(try reopened.editHistory(photoID: photo.id).contains { $0.title.contains("手动透视") })
        XCTAssertEqual(try SafeFileWriter.sha256(original), digest)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any]); old.removeValue(forKey: "perspective")
        let oldBytes = try JSONSerialization.data(withJSONObject: old)
        try await reopened.database.write { try $0.execute(sql: "UPDATE photo SET recipe=? WHERE id=?", arguments: [oldBytes, photo.id]) }
        let second = AppModel(); second.catalog = reopened; try second.reload(); second.choose([photo.id], active: photo.id)
        try await wait { second.imageStatus.contains("缺少透视参数") }
        XCTAssertFalse(second.canEdit); XCTAssertNil(second.recipe); XCTAssertEqual(try reopened.photo(photo.id)?.recipe, oldBytes)
        for (group,key,value) in [("perspective","model","projective-v1"),("develop","blackWhiteMixVersion","original-hue-v1")] {
            var stale = try XCTUnwrap(JSONSerialization.jsonObject(with:saved) as? [String:Any])
            var settings = try XCTUnwrap(stale[group] as? [String:Any]); settings[key] = value; stale[group] = settings
            let bytes = try JSONSerialization.data(withJSONObject:stale)
            try await reopened.database.write { try $0.execute(sql:"UPDATE photo SET recipe=? WHERE id=?",arguments:[bytes,photo.id]) }
            let refused = AppModel(); refused.catalog = reopened; try refused.reload(); refused.choose([photo.id],active:photo.id)
            try await wait { refused.imageStatus.contains("不支持的") }
            XCTAssertFalse(refused.canEdit); XCTAssertNil(refused.recipe)
            XCTAssertEqual(try reopened.photo(photo.id)?.recipe,bytes,"Unsupported processing IDs are never silently reinterpreted or overwritten")
        }
        XCTAssertEqual(try SafeFileWriter.sha256(original),digest)
    }

    @MainActor func testLateInteractiveGeometryFrameIsDiscarded() async throws {
        let source = try fixture("late"), pipeline = ImagePipeline(), base = try await pipeline.baseline(source)
        let initial = try await pipeline.render(ImageRequest(photo: source.photo, root: source.root, recipe: base), longEdge: 160)
        let gate = PerspectiveRenderGate()
        let model = AppModel(previewRenderer: { request, interactive, _ in
            let value = Int(request.recipe?.perspective.horizontal ?? 0)
            if interactive && (value == 20 || value == 40) { await gate.wait(value) }
            return initial
        })
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("late-catalog"))
        let root = try catalog.addRoot(url: folder, bookmark: AccessLease.bookmark(folder, readOnly: true))
        var photo = source.photo; photo.rootID = root.id; photo.recipe = try JSONEncoder().encode(base); try catalog.index(photo)
        model.catalog = catalog; try model.reload(); model.choose([photo.id], active: photo.id)
        try await wait { model.previewCurrent && model.recipe != nil }
        model.changeRecipe({ $0.perspective.horizontal = 20 }, commit: false)
        for _ in 0..<600 { if await gate.waiting(20) { break }; try await Task.sleep(for: .milliseconds(10)) }
        let blocked20 = await gate.waiting(20); XCTAssertTrue(blocked20)
        model.changeRecipe({ $0.perspective.horizontal = 40 }, commit: false)
        await gate.release(20)
        for _ in 0..<600 { if await gate.waiting(40) { break }; try await Task.sleep(for: .milliseconds(10)) }
        let blocked40 = await gate.waiting(40); XCTAssertTrue(blocked40)
        XCTAssertFalse(model.canvasCoordinatesCurrent, "20 的迟到帧不能发布为 40 的几何")
        XCTAssertFalse(model.interactivePreview, "丢弃过期草稿后应仍显示原质量帧")
        await gate.release(40)
        try await wait { model.interactivePreview && model.canvasCoordinatesCurrent }
        _ = model.commitRecipe()
    }
}

private actor PerspectiveRenderGate {
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    func wait(_ key: Int) async { await withCheckedContinuation { pending[key] = $0 } }
    func waiting(_ key: Int) -> Bool { pending[key] != nil }
    func release(_ key: Int) { pending.removeValue(forKey: key)?.resume() }
}
