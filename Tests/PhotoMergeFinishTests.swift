import XCTest
import CoreImage
import ImageIO
import simd
@testable import Phosdeck

final class PhotoMergeFinishTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("merge-finish-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    private func provenance(_ format: MergeMasterFormat = .dng) -> MergeProvenance {
        var options = PhotoMergeOptions();options.masterFormat = format;options.kind = .average;options.align = false;options.autoCrop = false
        return MergeProvenance(options:options,sources:(0..<2).map { .init(photoID:"source-\($0)",digest:String(repeating:"a",count:64),recipeRevision:1) })
    }
    private func image(width: Int = 31,height: Int = 17) -> MergeImage {
        var image = MergeImage(width:width,height:height)
        for y in 0..<image.height { for x in 0..<image.width {
            let alpha: Float = x == 0 ? 0 : x == 1 ? 0.25 : 1
            image.pixels[y*image.width+x] = alpha == 0 ? .zero : SIMD4(Float(x)/7-0.7,Float(y)/5,Float(x+y)+0.1234567,alpha)
        } }
        return image
    }
    func testLevelUsesCommonCameraAxesAndPreservesRelativeGeometry() {
        let tilt = simd_double3x3(simd_quatd(angle:0.17,axis:SIMD3(0,0,1)))*simd_double3x3(simd_quatd(angle:-0.24,axis:SIMD3(1,0,0)))
        let cameras = [-0.35,0,0.35].map { angle in
            MergeCameraRefinement.Camera(f:420,r:simd_double3x3(simd_quatd(angle:angle,axis:SIMD3(0,1,0)))*tilt,center:SIMD2(159.5,99.5))
        }
        let leveled = MergeCameraRefinement.leveled(cameras)
        var forward = SIMD3<Double>.zero
        for i in cameras.indices {
            XCTAssertEqual(leveled[i].r.transpose[0].y,0,accuracy:1e-9)
            XCTAssertEqual(leveled[i].r.determinant,1,accuracy:1e-9)
            let before = cameras[i].r*cameras[1].r.transpose,after = leveled[i].r*leveled[1].r.transpose
            for c in 0..<3 { XCTAssertLessThan(simd_distance(before[c],after[c]),1e-9) }
            forward += leveled[i].r.transpose[2]
        }
        XCTAssertEqual(forward.x,0,accuracy:1e-9);XCTAssertEqual(forward.y,0,accuracy:1e-9);XCTAssertGreaterThan(forward.z,0)
    }
    func testLevelHandlesVerticalSweepAndEmptyInput() {
        XCTAssertTrue(MergeCameraRefinement.leveled([]).isEmpty)
        let cameras = [-0.2,0.1,0.4].map { angle in
            MergeCameraRefinement.Camera(f:300,r:simd_double3x3(simd_quatd(angle:angle,axis:SIMD3(1,0,0))),center:.zero)
        }
        let result = MergeCameraRefinement.leveled(cameras)
        for camera in result { XCTAssertEqual(camera.r.determinant,1,accuracy:1e-9);XCTAssertEqual(camera.r.transpose[0].y,0,accuracy:1e-9) }
    }
    func testBoundaryWarpIncreasesCoverageWithoutClippingSignedRadiance() throws {
        var source = MergeImage(width:200,height:100)
        for x in 0..<source.width {
            let dip = Int(10*(1-pow((Double(x)-100)/100,2)))
            for y in dip..<source.height-dip { source.pixels[y*source.width+x] = SIMD4(-0.25,2.3,0.4,0.6) }
        }
        XCTAssertEqual(try MergePanoramaFinish.warp(source,amount:0).pixels,source.pixels)
        let result = try MergePanoramaFinish.warp(source,amount:1)
        XCTAssertGreaterThan(result.pixels.filter { $0.w > 0.3 }.count,Int(Double(source.pixels.count)*0.97))
        for pixel in result.pixels where pixel.w > 1e-6 {
            XCTAssertEqual(pixel.x,-0.25,accuracy:1e-6);XCTAssertEqual(pixel.y,2.3,accuracy:1e-6)
        }
        XCTAssertThrowsError(try MergePanoramaFinish.warp(source,amount:.nan))
    }
    func testFillRetainsCapturedPixelsAndCompletesBeforeCrop() throws {
        var source = MergeImage(width:35,height:23)
        for y in 4..<19 { for x in 6..<29 { source.pixels[y*35+x] = SIMD4(-0.2,3.7,Float(x)/10,1) } }
        source.pixels[5*35+5] = SIMD4(-0.1,2,0.4,0.25)
        var options = PhotoMergeOptions();options.kind = .panorama;options.fillEdges = true;options.autoCrop = true
        let result = try MergePanoramaFinish.apply(source,options:options)
        XCTAssertEqual(result.width,source.width);XCTAssertEqual(result.height,source.height)
        for i in source.pixels.indices {
            XCTAssertEqual(result.pixels[i].w,1)
            if source.pixels[i].w == 1 { XCTAssertEqual(result.pixels[i],source.pixels[i]) }
        }
        XCTAssertEqual(result.pixels[0].x,-0.2,accuracy:1e-6);XCTAssertEqual(result.pixels[0].y,3.7,accuracy:1e-5)
        XCTAssertThrowsError(try MergePanoramaFinish.fill(MergeImage(width:1,height:1)))
        let one = MergeImage(width:1,height:1,pixels:[SIMD4(-0.2,3,0.4,0.25)])
        XCTAssertEqual(try MergePanoramaFinish.fill(one).pixels[0],SIMD4(-0.2,3,0.4,1))
        XCTAssertEqual(try MergePanoramaFinish.warp(one,amount:1).pixels,one.pixels)
    }
    func testFloatDNGPreservesEverySampleAndImageIORecognisesLinearRawMetadata() throws {
        let source = image(width:128,height:96),url = directory.appendingPathComponent("signed.dng"),context = MergeMasterCodec.context(),provenance = provenance()
        try MergeMasterCodec.write(source,to:url,provenance:provenance,context:context)
        let back = try MergeMasterCodec.read(url,context:context)
        XCTAssertEqual(back.provenance,provenance);XCTAssertEqual(back.image.pixels,source.pixels)
        let container = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        XCTAssertEqual(CGImageSourceGetType(container) as String?,"com.adobe.raw-image")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(container,0,nil) as? [String:Any])
        let dng = try XCTUnwrap(props[kCGImagePropertyDNGDictionary as String] as? [String:Any])
        XCTAssertEqual((dng["DefaultCropSize"] as? [NSNumber])?.map(\.intValue),[source.width,source.height])
        XCTAssertEqual((dng["DNGBackwardVersion"] as? [NSNumber])?.prefix(2).map(\.intValue),[1,4])
        let attachment = XCTAttachment(contentsOfFile:url);attachment.lifetime = .keepAlways;add(attachment)
        let digest = try SafeFileWriter.sha256(url)
        XCTAssertThrowsError(try MergeMasterCodec.write(source,to:url,provenance:provenance,context:context))
        XCTAssertEqual(try SafeFileWriter.sha256(url),digest)
    }
    func testDNGReimportDevelopmentAndMergeDecodeKeepNativeLinearSemantics() async throws {
        let source = image(),url = directory.appendingPathComponent("editable.dng"),context = MergeMasterCodec.context()
        try MergeMasterCodec.write(source,to:url,provenance:provenance(),context:context)
        let request = try PNGFixture.request(url),pipeline = ImagePipeline()
        XCTAssertFalse(request.photo.isRAW);XCTAssertNotNil(request.photo.details?.composite)
        var recipe = try await pipeline.baseline(request);XCTAssertTrue(recipe.isLinearComposite)
        recipe.exposure = -2
        let rendered = try await pipeline.render(ImageRequest(photo:request.photo,root:request.root,recipe:recipe),longEdge:nil,pixelFormat:.RGBAf)
        let back = try MergeImage.read(CIImage(cgImage:rendered.image),context:context)
        let index = 5*source.width+10
        for c in 0..<3 { XCTAssertEqual(back.pixels[index][c],source.pixels[index][c]/4,accuracy:1e-4) }
        let decoded = try await pipeline.mergeDecode(ImageRequest(photo:request.photo,root:request.root,recipe:recipe),longEdge:nil,whiteBalance:.init(temperature:5500,tint:0))
        for i in source.pixels.indices { for c in 0..<4 { XCTAssertEqual(decoded.image.pixels[i][c],source.pixels[i][c],accuracy:1e-5) } }
        let thumbnails = ThumbnailService()
        let thumbnail = try await thumbnails.image(photo:request.photo,root:request.root,edge:16)
        XCTAssertEqual(max(thumbnail.width,thumbnail.height),16)
    }
    func testDNGRejectsTruncationNonfinitePixelsAndOldCompositeVersions() throws {
        let url = directory.appendingPathComponent("damaged.dng"),context = MergeMasterCodec.context()
        try MergeMasterCodec.write(image(),to:url,provenance:provenance(),context:context)
        var data = try Data(contentsOf:url);data.removeLast()
        try data.write(to:url)
        XCTAssertThrowsError(try MergeMasterCodec.read(url,context:context))
        var bad = image();bad.pixels[5].x = .infinity
        XCTAssertThrowsError(try MergeMasterCodec.write(bad,to:directory.appendingPathComponent("nonfinite.dng"),provenance:provenance(),context:context))
        XCTAssertThrowsError(try MergeProvenance.decode("Phosdeck linear composite v1\n{}"))
    }
    func testDNGEnginePublishesAndReimportsWithoutChangingSources() async throws {
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false)),context = MergeMasterCodec.context()
        for i in 0..<2 {
            let url = directory.appendingPathComponent("input-\(i).tif")
            try MergeMasterCodec.write(image(),to:url,provenance:provenance(.tiff),context:context)
            try catalog.index(ReferenceImporter.inspect(url:url,root:root,rootURL:directory))
        }
        let sources = try catalog.photos(),engine = PhotoMergeEngine()
        let requests = try await engine.loadInputs(catalog:catalog,ids:Set(sources.map(\.id)))
        let options = provenance().options
        let preview = try await engine.prepare(requests,options:options,progress:{ _,_ in })
        let bookmark = try AccessLease.bookmark(directory,readOnly:false)
        do { _ = try await engine.save(preview.id,to:bookmark,filename:"wrong.tif",catalog:catalog,progress:{ _,_ in });XCTFail("format mismatch") } catch { }
        let saved = try await engine.save(preview.id,to:bookmark,filename:"master.dng",catalog:catalog,progress:{ _,_ in })
        XCTAssertFalse(saved.photo.isRAW);XCTAssertEqual(try catalog.photoCount(),3)
        XCTAssertNil(try catalog.sources().first(where:{ $0.relativePath == saved.photo.relativePath })?.kind)
        XCTAssertEqual(try MergeMasterCodec.read(saved.url,context:context).image.pixels.count,image().pixels.count)
        let reimport = try ReferenceImporter.inspect(url:saved.url,root:root,rootURL:directory)
        XCTAssertEqual(reimport.details?.composite,saved.photo.details?.composite)
        for photo in sources { XCTAssertEqual(try catalog.photo(photo.id),photo) }
    }
    func testNewOptionsRoundTripAndRejectInvalidBoundaryAmounts() throws {
        var options = PhotoMergeOptions();options.kind = .hdrPanorama;options.autoLevel = true;options.fillEdges = true;options.boundaryWarp = 43;options.masterFormat = .dng
        XCTAssertEqual(try JSONDecoder().decode(PhotoMergeOptions.self,from:JSONEncoder().encode(options)),options)
        XCTAssertNoThrow(try options.validate(count:6))
        options.boundaryWarp = 101;XCTAssertThrowsError(try options.validate(count:6))
        options.boundaryWarp = .nan;XCTAssertThrowsError(try options.validate(count:6))
    }
    func testPanoramaFinishingMatchesPreviewCanvasAndPublishesOpaqueDNG() async throws {
        let w = 400,h = 160
        var seed: UInt64 = 71,noise = [Float]()
        for _ in 0..<w*h { seed = seed &* 6364136223846793005 &+ 1;noise.append(Float((seed >> 32)&65535)/65535) }
        let values = MergePlane(width:w,height:h,values:noise).blurred(0.7)
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false)),context = MergeMasterCodec.context()
        for (index,start) in [0,144].enumerated() {
            var view = MergeImage(width:256,height:h)
            for y in 0..<h { for x in 0..<256 {
                let v = 0.08+values.values[y*w+x+start]*0.7
                view.pixels[y*256+x] = SIMD4(v,v*0.85,v*0.65,1)
            } }
            let url = directory.appendingPathComponent("view-\(index).tif")
            try MergeMasterCodec.write(view,to:url,provenance:provenance(.tiff),context:context)
            try catalog.index(ReferenceImporter.inspect(url:url,root:root,rootURL:directory))
        }
        let engine = PhotoMergeEngine(),sources = try catalog.photos()
        let inputs = try await engine.loadInputs(catalog:catalog,ids:Set(sources.map(\.id)))
        var options = PhotoMergeOptions();options.kind = .panorama;options.autoLevel = true;options.boundaryWarp = 50;options.fillEdges = true;options.masterFormat = .dng
        let preview = try await engine.prepare(inputs,options:options,progress:{ _,_ in })
        let saved = try await engine.save(preview.id,to:root.bookmark,filename:"finished.dng",catalog:catalog,progress:{ _,_ in })
        let output = try MergeMasterCodec.read(saved.url,context:context)
        XCTAssertEqual(output.provenance.options,options)
        XCTAssertEqual(output.image.width,preview.width);XCTAssertEqual(output.image.height,preview.height)
        XCTAssertTrue(output.image.pixels.allSatisfy { $0.w == 1 })
        XCTAssertEqual(try catalog.photoCount(),3)
    }
}
