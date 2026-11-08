import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import Phosdeck

final class PhotoMergeTests: XCTestCase {
    var directory: URL!
    let context = MergeMasterCodec.context()
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("merge-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func constant(_ value: SIMD4<Float>,w: Int = 8,h: Int = 6) -> MergeImage {
        MergeImage(width:w,height:h,pixels:.init(repeating:value,count:w*h))
    }
    func texture(w: Int = 320,h: Int = 192) -> MergeImage {
        var seed: UInt64 = 932867
        var values = [Float]()
        for _ in 0..<w*h { seed = seed &* 6364136223846793005 &+ 1442695040888963407; values.append(Float((seed >> 32)&65535)/65535) }
        let fine = MergePlane(width:w,height:h,values:values).blurred(0.7)
        let coarse = MergePlane(width:w,height:h,values:values).blurred(4)
        return MergeImage(width:w,height:h,pixels:fine.values.indices.map {
            let v = 0.08+fine.values[$0]*0.6+coarse.values[$0]*0.15
            return SIMD4(v,v*0.87,v*0.73,1)
        })
    }
    func crop(_ image: MergeImage,x: Int,w: Int) -> MergeImage {
        var out = MergeImage(width:w,height:image.height)
        for y in 0..<image.height { for xx in 0..<w { out.pixels[y*w+xx] = image.pixels[y*image.width+xx+x] } }
        return out
    }
    func fusion(_ images: [MergeImage],kind: PhotoMergeKind,exposures: [Double]? = nil) throws -> MergeImage {
        var options = PhotoMergeOptions(); options.kind = kind; options.align = false; options.autoCrop = false; options.deghost = 0
        let frames = images.enumerated().map { MergeFrame(image:$0.element,exposure:exposures?[$0.offset],sourceIndex:$0.offset) }
        let plan = try MergeFusionPlan.prepare(frames,options:options)
        let accumulator = try MergeFusionAccumulator(plan:plan,width:images[0].width,height:images[0].height)
        for i in images.indices { try accumulator.add(images[i],index:i) }
        return try accumulator.finish()
    }
    func provenance(kind: PhotoMergeKind = .hdr) -> MergeProvenance {
        var options = PhotoMergeOptions(); options.kind = kind
        return MergeProvenance(options:options,sources:(0..<2).map { .init(photoID:"synthetic-\($0)",digest:String(repeating:"a",count:64),recipeRevision:$0) })
    }
    func writeSource(_ image: MergeImage,name: String) throws -> URL {
        let url = directory.appendingPathComponent(name+".tif")
        let ci = image.ciImage(),cg = try XCTUnwrap(context.createCGImage(ci,from:ci.extent,format:.RGBAf,colorSpace:MergeImage.space))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(output,cg,nil); XCTAssertTrue(CGImageDestinationFinalize(output)); return url
    }
    func testFloatMasterPreservesTopLeftCoordinatesAlphaNegativeAndExtendedHighlights() throws {
        var image = constant(.zero,w:7,h:5)
        for y in 0..<5 { for x in 0..<7 {
            let alpha: Float = x == 0 ? 0 : x == 1 ? 0.25 : 1
            image.pixels[y*7+x] = alpha == 0 ? .zero : SIMD4(Float(x)/13,Float(y)/7-0.2,Float(x+y)+0.1234567,alpha)
        } }
        let url = directory.appendingPathComponent("float.tif"),provenance = provenance()
        try MergeMasterCodec.write(image,to:url,provenance:provenance,context:context)
        let result = try MergeMasterCodec.read(url,context:context)
        XCTAssertEqual(result.provenance,provenance)
        for i in image.pixels.indices { for c in 0..<4 { XCTAssertEqual(result.image.pixels[i][c],image.pixels[i][c],accuracy:2e-5,"pixel \(i), channel \(c)") } }
        let digest = try SafeFileWriter.sha256(url)
        XCTAssertThrowsError(try MergeMasterCodec.write(image,to:url,provenance:provenance,context:context))
        XCTAssertEqual(try SafeFileWriter.sha256(url),digest)
    }
    func testCompositeImportBaselineAndDevelopUseLinearEVInFullFloat() async throws {
        let image = constant(SIMD4(3.2,1.2,0.4,1)),url = directory.appendingPathComponent("hdr.tif")
        try MergeMasterCodec.write(image,to:url,provenance:provenance(),context:context)
        let request = try PNGFixture.request(url),pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(request)
        XCTAssertTrue(recipe.isLinearComposite); XCTAssertFalse(recipe.isUnadjustedRaster)
        XCTAssertNotNil(request.photo.details?.composite)
        recipe.exposure = -2
        let result = try await pipeline.render(ImageRequest(photo:request.photo,root:request.root,recipe:recipe),longEdge:nil,pixelFormat:.RGBAf)
        let back = try MergeImage.read(CIImage(cgImage:result.image),context:context).pixels[0]
        XCTAssertEqual(back.x,0.8,accuracy:1e-4); XCTAssertEqual(back.y,0.3,accuracy:1e-4); XCTAssertEqual(back.z,0.1,accuracy:1e-4)
        var wrong = recipe; wrong.decoderVersion = EditRecipe.rasterDecoderVersion
        XCTAssertThrowsError(try wrong.validate(for:request.photo))
    }
    func testInvalidCompositeMarkerCannotEnterOrdinaryRasterPath() throws {
        let url = directory.appendingPathComponent("bad.tif"),ci = constant(SIMD4(0.2,0.3,0.4,1)).ciImage()
        let cg = try XCTUnwrap(context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:ImagePipeline.outputSpace))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(output,cg,[kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFImageDescription:try provenance().description]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output)); XCTAssertThrowsError(try PhotoFileType.inspectSource(url))
    }
    func testHDRRecoversClippedHighlightsWithoutToneMappingOrEightBitQuantization() throws {
        var scene = constant(SIMD4(0,0,0,1),w:128,h:96)
        for i in scene.pixels.indices { let v = 0.03+Float(i%128)/127*2.4; scene.pixels[i] = SIMD4(v,v,v,1) }
        let factors: [Float] = [0.25,1,4]
        let frames = factors.map { f in MergeImage(width:scene.width,height:scene.height,pixels:scene.pixels.map { SIMD4(min(1,$0.x*f),min(1,$0.y*f),min(1,$0.z*f),1) }) }
        let result = try fusion(frames,kind:.hdr,exposures:[-2,0,2])
        XCTAssertGreaterThan(result.pixels[120].x,2)
        for i in stride(from:0,to:result.pixels.count,by:113) { XCTAssertEqual(result.pixels[i].x,scene.pixels[i].x,accuracy:1e-4) }
    }
    func testHDRDeghostMaskRejectsMovingNonReferenceDetail() throws {
        let w = 128,h = 96
        var frames = [MergeFrame]()
        for (i,f) in [Float(0.25),1,4].enumerated() {
            var image = constant(SIMD4(0.12*f,0.12*f,0.12*f,1),w:w,h:h)
            for y in 28..<62 { for x in (i == 1 ? 45 : 70)..<(i == 1 ? 64 : 89) { image.pixels[y*w+x] = SIMD4(min(1,0.75*f),min(1,0.4*f),min(1,0.2*f),1) } }
            frames.append(MergeFrame(image:image,exposure:log2(Double(f)),sourceIndex:i))
        }
        var options = PhotoMergeOptions(); options.align = false; options.deghost = 3
        let plan = try MergeFusionPlan.prepare(frames,options:options)
        XCTAssertEqual(plan.reference,1)
        XCTAssertGreaterThan(plan.ghosts[0].values[44*w+78],0.85)
        XCTAssertEqual(plan.ghosts[1].values.max(),0)
        XCTAssertLessThan(plan.ghosts[0].values[10*w+10],0.01)
    }
    func testCreativeModesHaveDefinedChannelOperatorsAndPreserveCoverage() throws {
        let a = constant(SIMD4(0.2,0.8,0.4,1)),b = constant(SIMD4(0.6,0.1,0.7,1))
        let expected: [(PhotoMergeKind,SIMD3<Float>)] = [(.average,SIMD3(0.4,0.45,0.55)),(.median,SIMD3(0.4,0.45,0.55)),(.additive,SIMD3(0.8,0.9,1.1)),(.lighten,SIMD3(0.6,0.8,0.7)),(.darken,SIMD3(0.2,0.1,0.4)),(.screen,SIMD3(0.68,0.82,0.82))]
        for (kind,want) in expected {
            let value = try fusion([a,b],kind:kind).pixels[0]
            for c in 0..<3 { XCTAssertEqual(value[c],want[c],accuracy:1e-6,kind.rawValue) }; XCTAssertEqual(value.w,1)
            let reversed = try fusion([b,a],kind:kind).pixels[0]
            XCTAssertLessThan(simd_length(value-reversed),1e-6)
        }
        for kind in [PhotoMergeKind.average,.median,.additive,.lighten,.darken,.screen] {
            let image = try fusion([constant(SIMD4(0.4,0.5,0.6,0.25)),constant(.zero)],kind:kind)
            XCTAssertEqual(image.pixels[0].x,0.4,accuracy:1e-6,kind.rawValue); XCTAssertEqual(image.pixels[0].w,0.25)
        }
        let hdr = try fusion([constant(SIMD4(2,2,2,1)),constant(SIMD4(2,0.5,1,1))],kind:.screen).pixels[0]
        XCTAssertEqual(hdr.x,3,accuracy:1e-6); XCTAssertEqual(hdr.y,2,accuracy:1e-6); XCTAssertEqual(hdr.z,2,accuracy:1e-6)
    }
    func testPremultipliedSamplingCannotLeakHiddenRGB() throws {
        let image = MergeImage(width:2,height:1,pixels:[SIMD4(0.2,0.4,0.6,1),SIMD4(100,0,100,0)])
        let value = try XCTUnwrap(image.sample(0.5,0))
        XCTAssertEqual(value.x,0.2,accuracy:1e-6); XCTAssertEqual(value.w,0.5,accuracy:1e-6)
        XCTAssertNil(image.sample(.nan,0)); XCTAssertNil(image.sample(-0.01,0))
    }
    func testFeatureRegistrationFindsOverlapWithOutliers() throws {
        let world = texture(w:360,h:192),a = crop(world,x:0,w:260),b = crop(world,x:100,w:260)
        let matches = try MergeRegistration.matches(MergeRegistration.features(a.grey()),MergeRegistration.features(b.grey()))
        let fit = try XCTUnwrap(MergeRegistration.ransac(matches))
        let p = try XCTUnwrap(fit.transform.point(150,80))
        XCTAssertEqual(p.x,50,accuracy:0.5); XCTAssertEqual(p.y,80,accuracy:0.5); XCTAssertGreaterThan(fit.matches.count,10)
        let pairs = (0..<24).map { i -> MergeRegistration.Match in
            let p = SIMD2(Double((i%6)*23),Double((i/6)*27))
            return .init(a:p,b:i < 18 ? p+SIMD2(3.5,-2.25) : p+SIMD2(Double(i*10),20))
        }
        let robust = try XCTUnwrap(MergeRegistration.ransac(pairs,similarity:true))
        let q = try XCTUnwrap(robust.transform.point(10,20)); XCTAssertEqual(q.x,13.5,accuracy:1e-6); XCTAssertEqual(q.y,17.75,accuracy:1e-6)
    }
    func testPanoramaProjectionsAndMultibandSeamRetainSceneValues() throws {
        let world = texture(w:360,h:192),a = crop(world,x:0,w:260),b = crop(world,x:100,w:260)
        for projection in MergeProjection.allCases {
            var options = PhotoMergeOptions(); options.kind = .panorama; options.projection = projection
            let plan = try MergePanoramaPlan.prepare([MergeFrame(image:a),MergeFrame(image:b)],options:options)
            let accumulator = MergePanoramaAccumulator(plan)
            try accumulator.add(a,index:0); try accumulator.add(b,index:1)
            let result = try accumulator.finish()
            XCTAssertGreaterThan(result.width,260,projection.rawValue)
            if projection == .perspective { XCTAssertLessThanOrEqual(abs(result.width-360),2); XCTAssertLessThanOrEqual(abs(result.height-192),2) }
            XCTAssertTrue(result.pixels.allSatisfy { $0.w >= 0.999 && $0.x.isFinite && $0.x > 0.05 && $0.x < 0.95 })
            for d in [SIMD3(0.1,-0.2,1.0),SIMD3(-0.7,0.3,0.8)] {
                let p = try XCTUnwrap(projection.forward(d,f:1000)),back = projection.inverse(p.x,p.y,f:1000)
                XCTAssertLessThan(simd_distance(simd_normalize(d),simd_normalize(back)),1e-8)
            }
        }
    }
    func testPanoramaRejectsDisconnectedPhotosAndInvalidGrouping() throws {
        var options = PhotoMergeOptions(); options.kind = .panorama
        XCTAssertThrowsError(try MergePanoramaPlan.prepare([MergeFrame(image:constant(SIMD4(0.2,0.2,0.2,1))),MergeFrame(image:constant(SIMD4(0.7,0.7,0.7,1)))],options:options))
        options.kind = .hdrPanorama; options.bracketSize = 3
        XCTAssertThrowsError(try options.validate(count:5)); XCTAssertThrowsError(try options.validate(count:3)); XCTAssertNoThrow(try options.validate(count:6))
    }
    func testPanoramaRecoversRotatingCameraGeometry() throws {
        let environment = texture(w:800,h:500),w = 260,h = 180,f = 280.0,yaws = [-0.14,0.14]
        func rotate(_ d: SIMD3<Double>,yaw: Double) -> SIMD3<Double> { SIMD3(cos(yaw)*d.x+sin(yaw)*d.z,d.y,-sin(yaw)*d.x+cos(yaw)*d.z) }
        let frames = yaws.map { yaw -> MergeFrame in
            var image = MergeImage(width:w,height:h)
            for y in 0..<h { for x in 0..<w {
                let ray = rotate(SIMD3((Double(x)-129.5)/f,(Double(y)-89.5)/f,1),yaw:yaw)
                image.pixels[y*w+x] = environment.sample(ray.x/ray.z*420+399.5,ray.y/ray.z*420+249.5) ?? .zero
            } }
            return MergeFrame(image:image,focal35mm:f/hypot(Double(w),Double(h))*hypot(36,24))
        }
        var options = PhotoMergeOptions(); options.kind = .panorama; options.projection = .spherical
        let plan = try MergePanoramaPlan.prepare(frames,options:options)
        XCTAssertEqual(plan.focal,f,accuracy:1e-6)
        var compared = 0
        for index in frames.indices where index != plan.reference {
            for x in [80.0,130,180] { for y in [50.0,90,130] {
                let ray = SIMD3((x-129.5)/f,(y-89.5)/f,1)
                let target = rotate(rotate(ray,yaw:yaws[plan.reference]),yaw:-yaws[index])
                let expected = SIMD2(f*target.x/target.z+129.5,f*target.y/target.z+89.5)
                guard expected.x > 10,expected.x < Double(w-10) else { continue }
                let mapped = plan.cameras[index].m*ray,actual = SIMD2(mapped.x/mapped.z,mapped.y/mapped.z)
                XCTAssertLessThan(simd_distance(expected,actual),1.2); compared += 1
            } }
        }
        XCTAssertGreaterThanOrEqual(compared,3)
    }
    func testFocusDepthAndPyramidPreferSharpRegions() throws {
        let sharp = texture(),w = sharp.width,h = sharp.height
        let blurred = MergePlane(width:w,height:h,values:sharp.pixels.map(\.x)).blurred(2.5)
        var a = sharp,b = sharp
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x,v = blurred.values[i]
            let soft = SIMD4(v,v*0.87,v*0.73,1)
            if x > w/2 { a.pixels[i] = soft } else { b.pixels[i] = soft }
        } }
        var options = PhotoMergeOptions(); options.kind = .focus; options.align = false
        let plan = try MergeFusionPlan.prepare([MergeFrame(image:a),MergeFrame(image:b)],options:options)
        let depth = try XCTUnwrap(plan.depth),left = depth.depth[(depth.height/2)*depth.width+depth.width/4],right = depth.depth[(depth.height/2)*depth.width+depth.width*3/4]
        XCTAssertLessThan(left,0.3); XCTAssertGreaterThan(right,0.7)
        let accumulator = try MergeFusionAccumulator(plan:plan,width:w,height:h)
        try accumulator.add(a,index:0); try accumulator.add(b,index:1)
        let result = try accumulator.finish()
        var resultError: Double = 0,meanError: Double = 0
        for y in 30..<h-30 { for x in 30..<w-30 where abs(x-w/2) > 35 {
            let i = y*w+x
            resultError += pow(Double(result.pixels[i].x-sharp.pixels[i].x),2)
            meanError += pow(Double((a.pixels[i].x+b.pixels[i].x)/2-sharp.pixels[i].x),2)
        } }
        XCTAssertLessThan(resultError,meanError*0.4)
    }
    func testFlatFocusDepthIsFiniteAndClippedEdgesDoNotWin() throws {
        let flat = constant(SIMD4(0.4,0.4,0.4,1),w:64,h:48)
        let result = try fusion([flat,flat],kind:.focus)
        XCTAssertTrue(result.pixels.allSatisfy { $0.x.isFinite && abs($0.x-0.4) < 1e-5 })
        let sharp = texture(w:256,h:192)
        var clipped = sharp
        for y in 50..<140 { for x in 90..<170 { clipped.pixels[y*256+x] = SIMD4(1.2,1.2,1.2,1) } }
        var options = PhotoMergeOptions(); options.kind = .focus; options.align = false
        let plan = try MergeFusionPlan.prepare([MergeFrame(image:clipped),MergeFrame(image:sharp)],options:options)
        let depth = try XCTUnwrap(plan.depth)
        XCTAssertGreaterThan(depth.depth[(depth.height/2)*depth.width+45],0.7)
    }
    func testECCRecoversSmallMotionAndHandlesSinglePixelInput() throws {
        let image = texture(w:192,h:128),transform = MergeMatrix.translation(-2,1)
        let shifted = try MergeRegistration.warp(image,to:(192,128),transform:transform)
        let a = image.grey(),b = shifted.grey()
        let fit = ECCAligner.align(template:LumaImage(width:a.width,height:a.height,pixels:a.values),image:LumaImage(width:b.width,height:b.height,pixels:b.values))
        XCTAssertGreaterThan(fit.correlation,0.9); XCTAssertEqual(fit.transform.tx,2,accuracy:0.25); XCTAssertEqual(fit.transform.ty,-1,accuracy:0.25)
        let one = LumaImage(width:1,height:1,pixels:[1])
        XCTAssertEqual(ECCAligner.align(template:one,image:one).correlation,0)
    }
    func testCropFindsLargestCoveredRectangleAndPreservesPixels() throws {
        var image = constant(.zero,w:9,h:7)
        for y in 1..<6 { for x in 2..<8 { image.pixels[y*9+x] = SIMD4(Float(x),Float(y),2,1) } }
        let result = try MergeCrop.crop(image)
        XCTAssertEqual(result.width,6); XCTAssertEqual(result.height,5); XCTAssertEqual(result.pixels[0],SIMD4(2,1,2,1))
        XCTAssertThrowsError(try MergeCrop.crop(constant(.zero)))
        let translucent = constant(SIMD4(0.2,0.3,0.4,0.25))
        let preserved = try MergeCrop.crop(translucent)
        XCTAssertEqual(preserved.width,translucent.width); XCTAssertEqual(preserved.pixels,translucent.pixels)
    }
    func testEnginePublishesExclusiveFloatMasterAndPreservesSources() async throws {
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false))
        var sourceDigests = [String]()
        for (i,value) in [Float(0.2),0.6].enumerated() {
            let url = try writeSource(constant(SIMD4(value,value,value,1)),name:"source-\(i)")
            sourceDigests.append(try SafeFileWriter.sha256(url)); try catalog.index(ReferenceImporter.inspect(url:url,root:root,rootURL:directory))
        }
        let sources = try catalog.photos(),engine = PhotoMergeEngine()
        let inputs = try await engine.loadInputs(catalog:catalog,ids:Set(sources.map(\.id)))
        var options = PhotoMergeOptions(); options.kind = .average; options.align = false; options.autoCrop = false
        let preview = try await engine.prepare(inputs,options:options,progress:{ _,_ in })
        let saved = try await engine.save(preview.id,to:root.bookmark,filename:"merged.tif",catalog:catalog,progress:{ _,_ in })
        XCTAssertEqual(try catalog.photoCount(),3); XCTAssertEqual(try catalog.photo(saved.photo.id),saved.photo)
        let result = try MergeMasterCodec.read(saved.url,context:context)
        XCTAssertEqual(result.image.pixels[0].x,0.4,accuracy:1e-5)
        XCTAssertEqual(Set(result.provenance.sources.map(\.photoID)),Set(sources.map(\.id)))
        for (i,photo) in sources.enumerated() { XCTAssertEqual(try SafeFileWriter.sha256(directory.appendingPathComponent(photo.relativePath)),sourceDigests[i]) }
        let next = try await engine.prepare(inputs,options:options,progress:{ _,_ in })
        do { _ = try await engine.save(next.id,to:root.bookmark,filename:"merged.tif",catalog:catalog,progress:{ _,_ in }); XCTFail("must not overwrite") } catch { }
        XCTAssertEqual(try SafeFileWriter.sha256(saved.url),saved.photo.digest)
        // Frozen catalog changes stop before publication, even when source files are unchanged.
        try await catalog.database.write { db in try db.execute(sql:"UPDATE photo SET rating=3 WHERE id=?",arguments:[sources[0].id]) }
        do { _ = try await engine.save(next.id,to:root.bookmark,filename:"stale.tif",catalog:catalog,progress:{ _,_ in }); XCTFail("stale selection") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("stale.tif").path))
    }
    func testCancelledAnalysisDoesNotPublishFilesOrImportAnything() async throws {
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false))
        for i in 0..<2 { try catalog.index(ReferenceImporter.inspect(url:writeSource(texture(w:128,h:96),name:"source-\(i)"),root:root,rootURL:directory)) }
        let engine = PhotoMergeEngine(),inputs = try await engine.loadInputs(catalog:catalog,ids:Set(try catalog.photos().map(\.id)))
        let job = Task { try await engine.prepare(inputs,options:PhotoMergeOptions(),progress:{ _,_ in }) }; job.cancel()
        do { _ = try await job.value; XCTFail("cancelled") } catch is CancellationError { }
        XCTAssertEqual(try catalog.photoCount(),2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains { $0.hasPrefix(".phosdeck-") })
    }
    func testHDRPanoramaEngineGroupsBracketsAndSavesExtendedRange() async throws {
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false))
        var world = texture(w:360,h:192)
        for y in 50..<110 { for x in 130..<190 { world.pixels[y*360+x] *= 4; world.pixels[y*360+x].w = 1 } }
        for position in 0..<2 {
            let source = crop(world,x:position*100,w:260)
            for (bracket,factor) in [Float(0.25),1,4].enumerated() {
                let image = MergeImage(width:source.width,height:source.height,pixels:source.pixels.map { SIMD4(min(1,$0.x*factor),min(1,$0.y*factor),min(1,$0.z*factor),1) })
                let url = try writeSource(image,name:"position-\(position)-bracket-\(bracket)")
                try catalog.index(ReferenceImporter.inspect(url:url,root:root,rootURL:directory))
            }
        }
        let sources = try catalog.photos(),engine = PhotoMergeEngine()
        let inputs = try await engine.loadInputs(catalog:catalog,ids:Set(sources.map(\.id)))
        var options = PhotoMergeOptions(); options.kind = .hdrPanorama; options.align = false; options.deghost = 0; options.projection = .perspective
        let preview = try await engine.prepare(inputs,options:options,progress:{ _,_ in })
        let saved = try await engine.save(preview.id,to:root.bookmark,filename:"hdr-pano.tif",catalog:catalog,progress:{ _,_ in })
        let output = try MergeMasterCodec.read(saved.url,context:context)
        XCTAssertEqual(output.provenance.sources.count,6); XCTAssertEqual(output.provenance.options.kind,.hdrPanorama)
        XCTAssertGreaterThan(output.image.width,350); XCTAssertGreaterThan(output.image.pixels.map(\.x).max() ?? 0,1.3)
        XCTAssertTrue(output.image.pixels.allSatisfy { $0.w >= 0.999 && $0.x.isFinite })
        XCTAssertEqual(try catalog.photoCount(),7)
    }
    func testPublicationCommitPointAndRegistrationFailurePreserveMasters() async throws {
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false))
        for i in 0..<2 { try catalog.index(ReferenceImporter.inspect(url:writeSource(constant(SIMD4(0.2,0.3,0.4,1)),name:"input-\(i)"),root:root,rootURL:directory)) }
        let ids = Set(try catalog.photos().map(\.id))
        var options = PhotoMergeOptions(); options.kind = .average; options.align = false
        let before = PhotoMergeEngine(checkpoint:{ phase in if phase == "staged" { withUnsafeCurrentTask { $0?.cancel() } } })
        let beforeInputs = try await before.loadInputs(catalog:catalog,ids:ids)
        let first = try await before.prepare(beforeInputs,options:options,progress:{ _,_ in })
        let cancelBefore = Task { try await before.save(first.id,to:root.bookmark,filename:"cancel-before.tif",catalog:catalog,progress:{ _,_ in }) }
        do { _ = try await cancelBefore.value; XCTFail("must cancel before publish") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("cancel-before.tif").path)); XCTAssertEqual(try catalog.photoCount(),2)

        let failed = PhotoMergeEngine(checkpoint:{ phase in if phase == "published" { throw LRCError("synthetic registration failure") } })
        let failedInputs = try await failed.loadInputs(catalog:catalog,ids:ids)
        let second = try await failed.prepare(failedInputs,options:options,progress:{ _,_ in })
        do { _ = try await failed.save(second.id,to:root.bookmark,filename:"preserved.tif",catalog:catalog,progress:{ _,_ in }); XCTFail("injected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("preserved.tif")) }
        let preserved = directory.appendingPathComponent("preserved.tif")
        XCTAssertNoThrow(try MergeMasterCodec.read(preserved,context:context)); XCTAssertEqual(try catalog.photoCount(),2)

        let after = PhotoMergeEngine(checkpoint:{ phase in if phase == "published" { withUnsafeCurrentTask { $0?.cancel() } } })
        let afterInputs = try await after.loadInputs(catalog:catalog,ids:ids)
        let third = try await after.prepare(afterInputs,options:options,progress:{ _,_ in })
        let cancelAfter = Task { try await after.save(third.id,to:root.bookmark,filename:"cancel-after.tif",catalog:catalog,progress:{ _,_ in }) }
        let committed = try await cancelAfter.value
        XCTAssertNotNil(try catalog.photo(committed.photo.id)); XCTAssertEqual(try catalog.photoCount(),3)
        XCTAssertNoThrow(try MergeMasterCodec.read(committed.url,context:context))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:directory.path).contains { $0.hasPrefix(".phosdeck-") })
    }
    func testPublicSonyRAWMergeDecodeIsLinearSeparateAndRepeatable() async throws {
        try await checkPublicRAW("a7iii_12bit_compressed.ARW")
    }
    func testPublicLeicaRAWMergeDecodeIsLinearSeparateAndRepeatable() async throws {
        try await checkPublicRAW("leica_m8_8bit_uncompressed.DNG")
    }
    private func checkPublicRAW(_ name: String) async throws {
        let source = try MoreRAWTests.request(name),pipeline = ImagePipeline(cacheIntermediates:true)
        let recipe = try await pipeline.baseline(source)
        let wb = WhiteBalanceValue(temperature:recipe.temperature,tint:recipe.tint)
        let first = try await pipeline.mergeDecode(ImageRequest(photo:source.photo,root:source.root,recipe:recipe),longEdge:256,whiteBalance:wb)
        var changed = recipe; changed.exposure = 3; changed.contrast = 1.6; changed.crop = Crop(x:0.2,y:0.2,width:0.6,height:0.6); changed.quarterTurns = 1
        let next = try await pipeline.mergeDecode(ImageRequest(photo:source.photo,root:source.root,recipe:changed),longEdge:256,whiteBalance:wb)
        XCTAssertEqual(first.image.width,next.image.width); XCTAssertEqual(first.image.height,next.image.height)
        XCTAssertLessThanOrEqual(max(first.image.width,first.image.height),256)
        XCTAssertTrue(first.image.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite && (0...1).contains($0.w) })
        XCTAssertGreaterThan(first.image.pixels.map(\.w).max() ?? 0,0.999)
        XCTAssertGreaterThan(first.image.pixels.map(MergeImage.peak).max() ?? 0,0.01)
        for i in first.image.pixels.indices { XCTAssertLessThan(simd_distance(first.image.pixels[i],next.image.pixels[i]),1e-5) }
        let url = directory.appendingPathComponent("raw-merge.tif")
        try MergeMasterCodec.write(first.image,to:url,provenance:provenance(),context:context)
        // Creating and editing a composite must not change the normal RAW graph or its cache.
        let request = ImageRequest(photo:source.photo,root:source.root,recipe:recipe)
        let ordinary = try await pipeline.renderInteractive(request,longEdge:256),fresh = try await ImagePipeline().renderInteractive(request,longEdge:256)
        XCTAssertEqual(ordinary.image.dataProvider?.data as Data?,fresh.image.dataProvider?.data as Data?)
        XCTAssertEqual(try SafeFileWriter.sha256(MoreRAWTests.sample(name)),recipe.sourceDigest)
    }
    @MainActor func testSessionBlocksCatalogChangesAndDrainsCancellation() async throws {
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false))
        for i in 0..<2 { try catalog.index(ReferenceImporter.inspect(url:writeSource(constant(SIMD4(0.2,0.3,0.4,1)),name:"input-\(i)"),root:root,rootURL:directory)) }
        let session = PhotoMergeSession(catalog:catalog,ids:Set(try catalog.photos().map(\.id)),kind:.additive)
        let model = AppModel(previewRenderer:{ _,_,_ in throw LRCError("synthetic") })
        model.catalog = catalog; model.mergeSession = session
        XCTAssertTrue(model.presentingSheet); XCTAssertFalse(model.canSwitchCatalog); XCTAssertFalse(model.workspaceAvailable)
        XCTAssertFalse(session.options.align); XCTAssertFalse(session.options.autoCrop)
        await session.cancelAndWait()
        XCTAssertFalse(session.working); XCTAssertNil(session.preview)
        session.options.kind = .focus; session.applyModeDefaults(); XCTAssertTrue(session.options.align)
        model.mergeSession = nil; XCTAssertTrue(model.canSwitchCatalog)
    }
}
