import XCTest
import AppKit
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
    private func scalarDescriptorMatches(_ a: [MergeFeature],_ b: [MergeFeature]) -> [[SIMD2<Double>]] {
        guard a.count > 1,b.count > 1 else { return [] }
        func nearest(_ x: [MergeFeature],_ y: [MergeFeature]) -> [(Int,Float,Float)] {
            x.map { f in
                var best = (-1,Float.infinity,Float.infinity)
                for (j,g) in y.enumerated() {
                    var distance: Float = 0
                    for k in 0..<64 { let delta = f.descriptor[k]-g.descriptor[k]; distance += delta*delta }
                    if distance < best.1 { best = (j,distance,best.1) } else if distance < best.2 { best.2 = distance }
                }
                return best
            }
        }
        let forward = nearest(a,b),reverse = nearest(b,a)
        return forward.enumerated().compactMap { i,best in
            best.0 >= 0 && best.1 < 0.64*best.2 && reverse[best.0].0 == i ? [a[i].p,b[best.0].p] : nil
        }
    }
    func testVectorDescriptorMatchingRetainsScalarResultsAcrossBatchTails() throws {
        var seed: UInt64 = 0x4d4f5053
        func next() -> Float { seed = seed &* 6364136223846793005 &+ 1; return Float((seed >> 32)&65535)/8192-4 }
        func features(_ count: Int) -> [MergeFeature] {
            (0..<count).map { MergeFeature(p:SIMD2(Double($0),Double($0*3)),strength:1,descriptor:(0..<64).map { _ in next() }) }
        }
        for (n,m) in [(0,3),(1,2),(2,1),(2,3),(7,9),(16,17),(31,33),(73,129)] {
            let a = features(n);var b = features(m)
            for j in 0..<min(n,m) where j%3 != 0 { b[j].descriptor = a[(j*17)%n].descriptor.map { $0+next()*0.01 } }
            let result = try MergeRegistration.matches(a,b).map { [$0.a,$0.b] }
            XCTAssertEqual(result,scalarDescriptorMatches(a,b),"\(n) × \(m)")
        }
    }
    func testDescriptorMatchingPreservesFirstTiesAndStrictRatioBoundary() throws {
        func features(_ values: [Float]) -> [MergeFeature] {
            values.enumerated().map { i,value in
                var descriptor = [Float](repeating:0,count:64);descriptor[63] = value
                return MergeFeature(p:SIMD2(Double(i),0),strength:1,descriptor:descriptor)
            }
        }
        let a = features([0,0,10]),b = features([0,10,20])
        XCTAssertEqual(try MergeRegistration.matches(a,b).map { [$0.a.x,$0.b.x] },[[0,0],[2,1]])
        XCTAssertEqual(try MergeRegistration.matches(features([0,10]),features([0,0,10])).map { [$0.a.x,$0.b.x] },[[1,2]])
        let boundary: Float = 0.8
        for value in [boundary.nextDown,boundary,boundary.nextUp] {
            let a = features([0,10]),b = features([value,1,10])
            let result = try MergeRegistration.matches(a,b).map { [$0.a,$0.b] }
            XCTAssertEqual(result,scalarDescriptorMatches(a,b))
            XCTAssertEqual(result.count,value < boundary ? 2 : 1)
        }
    }
    func testDescriptorMatchingHonorsCancellation() async throws {
        let features = (0..<3).map { MergeFeature(p:SIMD2(Double($0),0),strength:1,descriptor:.init(repeating:Float($0),count:64)) }
        let job = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try MergeRegistration.matches(features,features)
        }
        job.cancel()
        do { _ = try await job.value;XCTFail("Cancelled matching must stop") } catch is CancellationError { }
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
    func testPanoramaLaplacianCannotReverseTheChannelOrderOfEverySource() throws {
        let w = 64,h = 48
        var a = constant(SIMD4(0.4,0.4,0.1,1),w:w,h:h)
        let b = a
        var left = MergePlane(width:w,height:h),right = left
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x
            if (16..<48).contains(x),(12..<36).contains(y) { a.pixels[i].x = 0.9 }
            left.values[i] = Float(x+1)/Float(w+1);right.values[i] = 1-left.values[i]
        } }
        let pyramid = MergePyramid(width:w,height:h)
        try pyramid.add(a,mask:left);try pyramid.add(b,mask:right)
        let image = try pyramid.finish(coverage:.init(repeating:1,count:w*h))
        // Both captures have R >= G >= B everywhere. The unguarded Laplacian
        // invents G > R outside the red patch (minimum R-G is about -0.0066).
        XCTAssertTrue(image.pixels.allSatisfy { $0.x+1e-6 >= $0.y && $0.y+1e-6 >= $0.z })
    }
    func testPanoramaChannelConsensusIsSymmetricAndPreservesLuminance() {
        for channels in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
            var source = SIMD4<Float>(0,0,0,1),value = SIMD4<Float>(0,0,0,0.25)
            for (index,channel) in channels.enumerated() {
                source[channel] = [Float(4),2,1][index]
                value[channel] = [Float(0.1),1.2,-0.3][index]
            }
            let order = MergePyramid.channelOrder(source)
            let projected = MergePyramid.preservingChannelOrder(value,order:order)
            XCTAssertGreaterThanOrEqual(projected[channels[0]],projected[channels[1]])
            XCTAssertGreaterThanOrEqual(projected[channels[1]],projected[channels[2]])
            XCTAssertEqual(MergeImage.luma(projected),MergeImage.luma(value),accuracy:2e-7)
            XCTAssertEqual(projected.w,value.w)
        }
        let order = MergePyramid.channelOrder(SIMD4(3,2,1,1))
        let signed = MergePyramid.preservingChannelOrder(SIMD4(-0.5,0.2,-0.1,1),order:order)
        XCTAssertLessThan(signed.z,0)
        let hdr = MergePyramid.preservingChannelOrder(SIMD4(2,5,1,1),order:order)
        XCTAssertGreaterThan(hdr.x,4)
    }
    func testPanoramaChannelConsensusAllowsPartialOrdersAndDifferentSourceHues() {
        let partial = MergePyramid.channelOrder(SIMD4(2,1,3,1)) & MergePyramid.channelOrder(SIMD4(3,2,1,1))
        let value = SIMD4<Float>(1,3,0,0.4)
        let projected = MergePyramid.preservingChannelOrder(value,order:partial)
        XCTAssertEqual(projected.x,projected.y)
        XCTAssertEqual(projected.z,value.z)
        XCTAssertEqual(MergeImage.luma(projected),MergeImage.luma(value),accuracy:2e-7)
        let mixed = MergePyramid.channelOrder(SIMD4(3,2,1,1)) & MergePyramid.channelOrder(SIMD4(1,2,3,1))
        XCTAssertEqual(mixed,0)
        XCTAssertEqual(MergePyramid.preservingChannelOrder(value,order:mixed),value)
    }
    func testSingleSourcePanoramaKeepsSignedHighlightsAndOpacity() throws {
        let source = constant(SIMD4(-0.125,2,4,0.25),w:32,h:24)
        let pyramid = MergePyramid(width:source.width,height:source.height)
        try pyramid.add(source,mask:MergePlane(width:source.width,height:source.height,values:.init(repeating:0.25,count:source.pixels.count)))
        let output = try pyramid.finish(coverage:.init(repeating:0.25,count:source.pixels.count))
        for pixel in output.pixels { for channel in 0..<4 {
            XCTAssertEqual(pixel[channel],source.pixels[0][channel],accuracy:1e-6)
        } }
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
    func testFocusFusionKeepsFineDetailWhenDepthFallsBetweenFrames() throws {
        let w = 128,h = 96
        let soft = constant(SIMD4(0.4,0.4,0.4,1),w:w,h:h)
        var sharp = soft
        for y in 0..<h { for x in 0..<w {
            let v: Float = (x+y).isMultiple(of:2) ? 0.55 : 0.25
            sharp.pixels[y*w+x] = SIMD4(v,v,v,1)
        } }
        let depth = StackDepthMap(width:32,height:24,depth:.init(repeating:0.5,count:768),confident:.init(repeating:false,count:768))
        let fusion = FocusStackFusion(width:w,height:h,depth:depth,reference:0)
        let valid = MergePlane(width:w,height:h,values:.init(repeating:1,count:w*h))
        try fusion.add(soft,validity:valid,index:0);try fusion.add(sharp,validity:valid,index:1)
        let output = try fusion.finish(coverage:valid.values)
        // Averaging the two image-domain/Gaussian masks halves this contrast.
        var contrast: Float = 0
        for y in 16..<h-16 { for x in 16..<w-17 { contrast += abs(output.pixels[y*w+x].x-output.pixels[y*w+x+1].x) } }
        XCTAssertGreaterThan(contrast/Float((h-32)*(w-33)),0.27)
        XCTAssertTrue(output.pixels.allSatisfy { $0.w == 1 && $0.x.isFinite })
    }
    func testFloatGaussianMatchesSeparableReplicatedBordersWithoutClipping() {
        for (w,h) in [(1,1),(2,7),(31,25)] {
            let image = MergePlane(width:w,height:h,values:(0..<w*h).map { Float(($0*37)%41)/4-2 })
            let sigma: Float = 2,radius = 6
            let raw = (-radius...radius).map { exp(-Float($0*$0)/(2*sigma*sigma)) },sum = raw.reduce(0,+),kernel = raw.map { $0/sum }
            var temp = MergePlane(width:w,height:h),expected = temp
            for y in 0..<h { for x in 0..<w { for k in -radius...radius { temp.values[y*w+x] += image.at(x+k,y)*kernel[k+radius] } } }
            for y in 0..<h { for x in 0..<w { for k in -radius...radius { expected.values[y*w+x] += temp.at(x,y+k)*kernel[k+radius] } } }
            let actual = image.blurred(sigma)
            for p in actual.values.indices { XCTAssertEqual(actual.values[p],expected.values[p],accuracy:3e-6) }
        }
    }
    func testHDRDeghostRetainsShortestCaptureWhenEveryExposureClips() throws {
        let w = 192,h = 128,scene = texture(w:w,h:h)
        let frames = [Float(0.25),1,4].enumerated().map { index,factor in
            var image = scene
            for p in image.pixels.indices { let v = image.pixels[p]*factor;image.pixels[p] = SIMD4(min(1,v.x),min(1,v.y),min(1,v.z),1) }
            for y in 40..<90 { for x in 60..<130 { image.pixels[y*w+x] = SIMD4(1,1,1,1) } }
            return MergeFrame(image:image,exposure:log2(Double(factor)),sourceIndex:index)
        }
        var options = PhotoMergeOptions();options.kind = .hdr;options.align = false;options.deghost = 3
        let plan = try MergeFusionPlan.prepare(frames,options:options)
        let fusion = try MergeFusionAccumulator(plan:plan,width:w,height:h)
        for i in frames.indices { try fusion.add(frames[i].image,index:i) }
        let output = try fusion.finish(),center = 65*w+95
        XCTAssertLessThan(plan.ghosts[0].values[center],1e-5)
        XCTAssertGreaterThan(output.pixels[center].x,3.9)
        XCTAssertEqual(output.pixels[center].x,output.pixels[center].z,accuracy:1e-5)
    }
    func testHDRExposureRatioIgnoresBakedRasterShadowPedestal() throws {
        var a = constant(SIMD4(0.006,0.006,0.006,1),w:128,h:96),b = a
        for y in 20..<50 { for x in 30..<70 {
            let v = Float(x-30)/40
            a.pixels[y*128+x] = SIMD4(0.6+v*0.1,0.4+v*0.1,0.2+v*0.1,1)
            b.pixels[y*128+x] = a.pixels[y*128+x]*0.25;b.pixels[y*128+x].w = 1
        } }
        XCTAssertEqual(try XCTUnwrap(MergeFusionPlan.logRatio(a,b,clips:(1,1))),log(0.25),accuracy:1e-6)
    }
    func testPanoramaFindsLowContrastOverlapBesideSharpHighlights() throws {
        var world = texture(w:800,h:240)
        for p in world.pixels.indices { world.pixels[p] *= 0.004;world.pixels[p].w = 1 }
        for y in 45..<75 { for x in 45..<75 { world.pixels[y*800+x] = SIMD4(1,1,1,1) } }
        for y in 160..<190 { for x in 720..<750 { world.pixels[y*800+x] = SIMD4(1,1,1,1) } }
        let a = crop(world,x:0,w:520),b = crop(world,x:280,w:520)
        var options = PhotoMergeOptions();options.kind = .panorama;options.projection = .perspective
        let plan = try MergePanoramaPlan.prepare([MergeFrame(image:a),MergeFrame(image:b)],options:options)
        XCTAssertEqual(plan.frames.count,2);XCTAssertGreaterThan(plan.width,790)
    }
    func testHDRPanoramaUsesCapturedRegistrationDetailWithoutChangingRadiance() throws {
        let world = texture(w:520,h:192),a = crop(world,x:0,w:320),b = crop(world,x:200,w:320)
        let flat = constant(SIMD4(3,2,1,1),w:320,h:192)
        var options = PhotoMergeOptions();options.kind = .hdrPanorama;options.projection = .perspective;options.autoCrop = true
        let frames = [MergeFrame(image:flat,registrationImage:a),MergeFrame(image:flat,registrationImage:b)]
        let plan = try MergePanoramaPlan.prepare(frames,options:options),fusion = MergePanoramaAccumulator(plan)
        try fusion.add(flat,index:0);try fusion.add(flat,index:1)
        let output = try fusion.finish()
        XCTAssertGreaterThan(output.width,510)
        XCTAssertEqual(output.pixels[output.width*output.height/2].x,3,accuracy:1e-4)
    }
    func testCameraRefinementRemovesProjectiveStretchBeyondMatchedStrip() throws {
        let w = 320,h = 200,f = 420.0
        let k = MergeMatrix([f,0,159.5,0,f,99.5,0,0,1])
        let trueCameras = [-0.15,0,0.15].map { angle in
            MergeMatrix(m:k.m*simd_double3x3(simd_quatd(angle:angle,axis:SIMD3(0,1,0))))
        }
        let frames = (0..<3).map { _ in MergeFrame(image:constant(SIMD4(0.2,0.2,0.2,1),w:w,h:h),focal35mm:f*hypot(36,24)/hypot(Double(w),Double(h))) }
        var edges = [MergePanoramaPlan.Edge]()
        for i in 0..<2 {
            var pairs = [MergeRegistration.Match]()
            for y in stride(from:70.0,through:130,by:15) { for x in stride(from:110.0,through:210,by:20) {
                let ray = k.inverse.m*SIMD3(x,y,1)
                let a = trueCameras[i].m*ray,b = trueCameras[i+1].m*ray
                pairs.append(.init(a:SIMD2(a.x/a.z,a.y/a.z),b:SIMD2(b.x/b.z,b.y/b.z)))
            } }
            let transform = MergeMatrix(m:trueCameras[i+1].m*trueCameras[i].m.inverse)
            edges.append(.init(i:i,j:i+1,fit:.init(transform:transform,matches:pairs,rms:0)))
        }
        let stretch = MergeMatrix([1,0,0,0,1.08,-8,0,0.00015,1])
        let initial = trueCameras.enumerated().map { i,c in i == 1 ? MergeMatrix.identity : MergeMatrix(m:c.m*k.m.inverse).followed(by:stretch) }
        let result = try XCTUnwrap(MergeCameraRefinement.refine(frames,homographies:initial,edges:edges,reference:1,focal:f*1.15))
        XCTAssertLessThan(result.rms,0.01)
        for i in [0,2] { for p in [SIMD2(20.0,20),SIMD2(290.0,180)] {
            let expected = try XCTUnwrap(MergeMatrix(m:trueCameras[i].m*k.m.inverse).point(p.x,p.y))
            let actual = try XCTUnwrap(MergeMatrix(m:result.cameras[i].m*result.cameras[1].m.inverse).point(p.x,p.y))
            XCTAssertLessThan(simd_distance(actual,expected),0.15)
        } }
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
        let saved = try await engine.save(preview.id,to:root.bookmark,filename:"merged.tif",catalog:catalog,stackWithSources:true,progress:{ _,_ in })
        XCTAssertEqual(try catalog.photoCount(),3); XCTAssertEqual(try catalog.photo(saved.photo.id),saved.photo)
        XCTAssertEqual(saved.previousStacks,[])
        let stack = try XCTUnwrap(catalog.stacks().first)
        XCTAssertEqual(stack.members,[saved.photo.id]+inputs.map { $0.photo.id }); XCTAssertTrue(stack.collapsed)
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
    func testMergeDecodePreservesRasterOrientationProfileAndFloatSamples() async throws {
        let image = texture(w:128,h:96),ci = image.ciImage()
        let cg = try XCTUnwrap(context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!))
        let url = directory.appendingPathComponent("oriented.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil))
        let properties: [CFString:Any] = [kCGImagePropertyOrientation:6,kCGImageDestinationLossyCompressionQuality:0.95]
        CGImageDestinationAddImage(destination,cg,properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pipeline = ImagePipeline(),request = try PNGFixture.request(url),wb = WhiteBalanceValue(temperature:5500,tint:0)
        XCTAssertEqual(request.photo.details?.orientation,6)
        let decoded = try await pipeline.mergeDecode(request,longEdge:nil,whiteBalance:wb)
        XCTAssertEqual(decoded.image.width,96);XCTAssertEqual(decoded.image.height,128)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let expected = try MergeImage.read(CIImage(cgImage:bitmap).oriented(forExifOrientation:6),context:context)
        for p in stride(from:0,to:expected.pixels.count,by:37) { XCTAssertLessThan(simd_distance(decoded.image.pixels[p],expected.pixels[p]),2e-4) }
        let resized = try await pipeline.mergeDecode(request,longEdge:57,whiteBalance:wb)
        XCTAssertEqual(resized.image.width,43);XCTAssertEqual(resized.image.height,57)
        XCTAssertTrue(resized.image.pixels.allSatisfy { $0.w > 0.99999 })

        let float = constant(SIMD4(-0.1,0.8,3.5,0.25),w:32,h:24),floatURL = try writeSource(float,name:"float-input")
        let floatDecoded = try await pipeline.mergeDecode(PNGFixture.request(floatURL),longEdge:nil,whiteBalance:wb)
        for c in 0..<4 { XCTAssertEqual(floatDecoded.image.pixels[0][c],float.pixels[0][c],accuracy:2e-5) }
    }

    private struct PublicMergeManifest: Decodable {
        struct Dataset: Decodable {
            struct File: Decodable { let file: String;let sha256: String }
            let id: String;let files: [File]
        }
        let datasets: [Dataset]
    }
    private func publicMergeFiles(_ id: String) throws -> [URL] {
        let root = try XCTUnwrap(Bundle(for:Self.self).resourceURL).appendingPathComponent("PublicMergeFixtures")
        guard let data = try? Data(contentsOf:root.appendingPathComponent("manifest.json")),
              let dataset = try JSONDecoder().decode(PublicMergeManifest.self,from:data).datasets.first(where:{ $0.id == id }) else {
            throw XCTSkip("Optional public merge sequence not prepared: \(id); see Tests/Fixtures/public-merge-samples.json")
        }
        return try dataset.files.map { item in
            let url = root.appendingPathComponent(id).appendingPathComponent(item.file)
            XCTAssertEqual(try SafeFileWriter.sha256(url),item.sha256)
            return url
        }
    }
    private func publicMerge(_ files: [URL],kind: PhotoMergeKind,sourceLongEdge: Int = 0) async throws -> (MergeImage,MergeProvenance) {
        let originalDigests = try Dictionary(uniqueKeysWithValues:files.map { ($0.path,try SafeFileWriter.sha256($0)) })
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let sourceDirectory = files[0].deletingLastPathComponent()
        let root = try catalog.addRoot(url:sourceDirectory,bookmark:AccessLease.bookmark(sourceDirectory,readOnly:true))
        for url in files { try catalog.index(ReferenceImporter.inspect(url:url,root:root,rootURL:sourceDirectory)) }
        let engine = PhotoMergeEngine(),inputs = try await engine.loadInputs(catalog:catalog,ids:Set(try catalog.photos().map(\.id)))
        var options = PhotoMergeOptions();options.kind = kind;options.autoCrop = kind != .focus;options.sourceLongEdge = sourceLongEdge
        let preview = try await engine.prepare(inputs,options:options,progress:{ _,_ in })
        let saved = try await engine.save(preview.id,to:AccessLease.bookmark(directory,readOnly:false),filename:"real-\(kind.rawValue).tif",catalog:catalog,progress:{ _,_ in })
        let output = try MergeMasterCodec.read(saved.url,context:context)
        XCTAssertEqual(output.provenance.sources.count,files.count)
        XCTAssertEqual(try catalog.photoCount(),files.count+1)
        XCTAssertTrue(output.image.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        for request in inputs {
            let url = sourceDirectory.appendingPathComponent(request.photo.relativePath)
            XCTAssertEqual(try SafeFileWriter.sha256(url),originalDigests[url.path])
        }
        return (output.image,output.provenance)
    }
    func testPublicRiverPanoramaKeepsAllSixCaptures() async throws {
        let (image,_) = try await publicMerge(publicMergeFiles("boat"),kind:.panorama,sourceLongEdge:2000)
        XCTAssertGreaterThan(image.width,4500);XCTAssertGreaterThan(image.height,900)
        XCTAssertTrue(image.pixels.allSatisfy { $0.w > 0.99 })
    }
    func testPublicSunrisePanoramaConnectsLowContrastOverlaps() async throws {
        let files = try publicMergeFiles("kimo").filter { ["IMG_6763.jpg","IMG_6766.jpg","IMG_6769.jpg"].contains($0.lastPathComponent) }
        let (image,_) = try await publicMerge(files,kind:.panorama)
        XCTAssertGreaterThan(image.width,2000);XCTAssertGreaterThan(image.height,600)
    }
    func testPublicSunriseHDRPanoramaKeepsAllThreeBracketsAndHeadroom() async throws {
        let (image,provenance) = try await publicMerge(publicMergeFiles("kimo"),kind:.hdrPanorama)
        XCTAssertGreaterThan(image.width,2000);XCTAssertGreaterThan(image.height,600)
        XCTAssertGreaterThan(image.pixels.map(MergeImage.peak).max() ?? 0,2)
        XCTAssertEqual(provenance.options.bracketSize,3)
    }
    func testPublicMemorialHDRKeepsWindowRadiance() async throws {
        let (image,_) = try await publicMerge(publicMergeFiles("memorial"),kind:.hdr)
        XCTAssertEqual(image.width,484);XCTAssertEqual(image.height,714)
        XCTAssertGreaterThan(image.pixels.map(MergeImage.peak).max() ?? 0,2)
    }
    func testPublicNEFBracketSavesFloatRadianceAndSourceProvenance() async throws {
        let files = try publicMergeFiles("fairchild-kitchen")
        XCTAssertEqual(files.count,9)
        for file in files {
            let source = try PNGFixture.request(file)
            XCTAssertTrue(source.photo.isRAW)
            XCTAssertEqual(source.photo.details?.iso,100)
            XCTAssertEqual(source.photo.details?.aperture,8)
        }
        let (image,provenance) = try await publicMerge(files,kind:.hdr,sourceLongEdge:2000)
        XCTAssertGreaterThan(image.width,1900);XCTAssertGreaterThan(image.height,1200)
        XCTAssertLessThanOrEqual(image.width,2000)
        XCTAssertGreaterThan(image.pixels.map(MergeImage.peak).max() ?? 0,4)
        XCTAssertEqual(provenance.options.kind,.hdr)
        XCTAssertEqual(provenance.sources.count,9)
    }
    func testPublicSevenFrameFocusMacroDecodesAndFusesAtOriginalSize() async throws {
        let files = try publicMergeFiles("focus-pcb")
        let (image,_) = try await publicMerge(files,kind:.focus)
        XCTAssertEqual(image.width,2048);XCTAssertEqual(image.height,1536)
        try await assertFocusBrightness(image,reference:files[0])
    }
    func testPublicTenFrameFocusMacroDecodesAndFusesAtOriginalSize() async throws {
        let files = try publicMergeFiles("focus-depth")
        let (image,_) = try await publicMerge(files,kind:.focus)
        XCTAssertEqual(image.width,2048);XCTAssertEqual(image.height,1536)
        try await assertFocusBrightness(image,reference:files[9])
    }
    private func assertFocusBrightness(_ image: MergeImage,reference: URL) async throws {
        let input = try PNGFixture.request(reference)
        // Use the app's explicit sRGB interpretation for untagged JPEGs, rather
        // than ImageIO's inferred Generic RGB profile in an independent reader.
        let sourceImage = try await ImagePipeline().mergeDecode(input,longEdge:nil,whiteBalance:WhiteBalanceValue(temperature:5500,tint:0)).image
        let captured = sourceImage.medianLuma()
        func mean(_ image: MergeImage) -> Double {
            var sum = 0.0,weight = 0.0
            for p in image.pixels { sum += Double(MergeImage.luma(p)*p.w);weight += Double(p.w) }
            return sum/max(weight,1e-9)
        }
        print("PUBLIC_FOCUS_BRIGHTNESS",reference.lastPathComponent,"sourceMean",mean(sourceImage),"mergedMean",mean(image),"sourceMedian",captured,"mergedMedian",image.medianLuma())
        // Sharp speculars occupy less area than blurred ones, changing the
        // median without an exposure shift. Check mean captured light instead.
        XCTAssertGreaterThan(mean(image),mean(sourceImage)*0.95)
        XCTAssertLessThan(mean(image),mean(sourceImage)*1.05)
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
    func testFocusRetouchStrokePreservesHDRAlphaAndRestoresAutomaticPixels() throws {
        let base = constant(SIMD4(-0.2,0.1,3,0.5),w:40,h:20)
        var source = constant(SIMD4(2,-0.4,0.2,1),w:40,h:20)
        source.pixels[4*40+10] = .zero
        var result = base
        let stroke = FocusRetouchStroke(source:1,points:[MaskPoint(0.25,0.25),MaskPoint(0.75,0.25)],radius:0.12,hardness:1,opacity:0.5)
        try stroke.validate(count:2)
        try stroke.apply(to:&result,from:source)
        XCTAssertEqual(result.pixels[5*40+20].x,0.9,accuracy:1e-6)
        XCTAssertEqual(result.pixels[5*40+20].z,1.6,accuracy:1e-6)
        XCTAssertEqual(result.pixels[5*40+20].w,0.5)
        XCTAssertEqual(result.pixels[4*40+10],base.pixels[4*40+10],"transparent source cannot erase coverage")
        XCTAssertEqual(result.pixels[15*40+20],base.pixels[15*40+20],"top-left stroke must not flip vertically")
        var restore = stroke; restore.restore = true; restore.opacity = 1
        try restore.apply(to:&result,from:base)
        for i in result.pixels.indices { XCTAssertEqual(result.pixels[i],base.pixels[i],"pixel \(i)") }
        var invalid = stroke; invalid.radius = .nan
        XCTAssertThrowsError(try invalid.validate(count:2))
    }

    func testFocusRetouchSelfIntersectionDoesNotAccumulateOpacity() throws {
        let base = constant(SIMD4(0,0,0,1),w:64,h:64), source = constant(SIMD4(1,1,1,1),w:64,h:64)
        var once = base, twice = base
        let stroke = FocusRetouchStroke(source:0,points:[MaskPoint(0.2,0.5),MaskPoint(0.8,0.5)],radius:0.1,hardness:0.5,opacity:0.3)
        var repeated = stroke; repeated.points += stroke.points.reversed()
        try stroke.apply(to:&once,from:source); try repeated.apply(to:&twice,from:source)
        XCTAssertEqual(once.pixels,twice.pixels)
    }

    func testFocusRetouchMastersReopenWithFrozenSolveAndRejectDamagedProject() async throws {
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("focus-catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:AccessLease.bookmark(directory,readOnly:false))
        for i in 0..<2 {
            var image = texture(w:48,h:32)
            for p in image.pixels.indices { image.pixels[p].x += Float(i)*0.2 }
            let url = try writeSource(image,name:"focus-source-\(i)")
            try catalog.index(ReferenceImporter.inspect(url:url,root:root,rootURL:directory))
        }
        let engine = PhotoMergeEngine(), photos = try catalog.photos()
        let inputs = try await engine.loadInputs(catalog:catalog,ids:Set(photos.map(\.id)))
        var options = PhotoMergeOptions.defaults(for:.focus); options.align = false
        let preview = try await engine.prepare(inputs,options:options,progress:{ _,_ in })
        let stroke = FocusRetouchStroke(source:1,points:[MaskPoint(0.25,0.25)],radius:0.2,hardness:1,opacity:1)
        let detailed = try await engine.focusPreview(preview.id,strokes:[stroke],source:1,ev:0,progress:{ _,_ in })
        XCTAssertEqual(detailed.width,48); XCTAssertEqual(detailed.height,32)
        // Appended-stroke previews and full replay after undo must use the same base.
        var restore = stroke; restore.restore = true; restore.opacity = 0.6
        _ = try await engine.focusPreview(preview.id,strokes:[stroke,restore],source:0,ev:0,progress:{ _,_ in })
        let replay = try await engine.focusPreview(preview.id,strokes:[stroke],source:1,ev:0,progress:{ _,_ in })
        let a = try MergeImage.read(CIImage(cgImage:detailed.result),context:context)
        let b = try MergeImage.read(CIImage(cgImage:replay.result),context:context)
        XCTAssertEqual(a.pixels,b.pixels)
        let first = try await engine.save(preview.id,to:root.bookmark,filename:"focus-edit.tif",catalog:catalog,progress:{ _,_ in })
        let original = try MergeMasterCodec.read(first.url,context:context)
        let ref = try XCTUnwrap(original.provenance.focusProject)
        let frozen = try FocusMergeProject.read(from:first.url,reference:ref)
        XCTAssertEqual(frozen.strokes,[stroke]); XCTAssertEqual(frozen.sources.map(\.photoID),inputs.map { $0.photo.id })
        XCTAssertLessThan(try JSONEncoder().encode(original.provenance).count,65536,"catalog stores only a bounded reference")
        let raw = try await ImagePipeline().mergeDecode(inputs[1],longEdge:nil,whiteBalance:WhiteBalanceValue(temperature:frozen.temperature,tint:frozen.tint))
        XCTAssertEqual(original.image.pixels[8*48+12].x,raw.image.pixels[8*48+12].x,accuracy:2e-5)
        let digest = try SafeFileWriter.sha256(first.url)
        // Current source edits must not reinterpret the saved solve or white balance.
        var changed = try await ImagePipeline().baseline(inputs[0]); changed.temperature = 9000; changed.exposure = 2
        let recipe = try JSONEncoder().encode(changed)
        try await catalog.database.write { db in
            try db.execute(sql:"UPDATE photo SET recipe=?, recipeRevision=recipeRevision+1 WHERE id=?",arguments:[recipe,inputs[0].photo.id])
        }
        let reopened = try await engine.reopenFocus(first.photo,catalog:catalog,progress:{ _,_ in })
        XCTAssertEqual(reopened.project,frozen)
        do {
            _ = try await engine.save(reopened.preview.id,to:root.bookmark,filename:"focus-edit.tif",catalog:catalog,progress:{ _,_ in })
            XCTFail("re-edit must never overwrite a master")
        } catch { }
        let second = try await engine.save(reopened.preview.id,to:root.bookmark,filename:"focus-edit.dng",catalog:catalog,masterFormat:.dng,progress:{ _,_ in })
        let roundtrip = try MergeMasterCodec.read(second.url,context:context)
        for i in original.image.pixels.indices { for c in 0..<4 {
            XCTAssertEqual(roundtrip.image.pixels[i][c],original.image.pixels[i][c],accuracy:2e-5)
        } }
        XCTAssertEqual(try SafeFileWriter.sha256(first.url),digest,"re-edit must preserve the previous master")
        let dngProject = try FocusMergeProject.read(from:second.url,reference:XCTUnwrap(roundtrip.provenance.focusProject))
        XCTAssertEqual(dngProject,frozen)
        let copied = directory.appendingPathComponent("damaged-project.tif")
        try FileManager.default.copyItem(at:first.url,to:copied)
        let handle = try FileHandle(forWritingTo:copied)
        let end = try handle.seekToEnd(); try handle.seek(toOffset:end-1); try handle.write(contentsOf:Data([0])); try handle.close()
        XCTAssertThrowsError(try FocusMergeProject.read(from:copied,reference:ref))
        var malformed = frozen; malformed.transforms[0] = [0]
        XCTAssertThrowsError(try malformed.validate())
        malformed = frozen; malformed.strokes[0].source = 200
        XCTAssertThrowsError(try malformed.validate())
        let sourceURL = directory.appendingPathComponent(inputs[0].photo.relativePath)
        try Data("synthetic changed source".utf8).write(to:sourceURL)
        do {
            _ = try await engine.reopenFocus(first.photo,catalog:catalog,progress:{ _,_ in })
            XCTFail("changed source must not be used to reconstruct a saved merge")
        } catch { }
        XCTAssertEqual(try SafeFileWriter.sha256(first.url),digest)

    }

    @MainActor func testFocusRetouchHistoryAndPendingStrokeIsolation() throws {
        let state = FocusRetouchState(); state.undo.groupsByEvent = false
        state.undo.beginUndoGrouping(); state.add([MaskPoint(0.2,0.3)],sourceCount:2); state.undo.endUndoGrouping()
        XCTAssertEqual(state.strokes.count,1)
        state.undo.undo(); XCTAssertTrue(state.strokes.isEmpty)
        state.undo.redo(); XCTAssertEqual(state.strokes.count,1)
        state.pending = true; state.add([MaskPoint(0.7,0.7)],sourceCount:2)
        XCTAssertEqual(state.strokes.count,1)
        state.load([]); XCTAssertFalse(state.undo.canUndo)
        state.pending = false
        let cg = try XCTUnwrap(context.createCGImage(constant(SIMD4(0.2,0.3,0.4,1),w:16,h:16).ciImage(),from:CGRect(x:0,y:0,width:16,height:16)))
        state.preview = FocusRetouchPreview(source:cg,result:cg,width:16,height:16)
        let view = FocusRetouchNSView(frame:CGRect(x:0,y:0,width:400,height:300))
        view.state = state; view.sourceCount = 2
        let down = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:CGPoint(x:300,y:150),modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:CGPoint(x:300,y:150),modifierFlags:[],timestamp:1,windowNumber:0,context:nil,eventNumber:2,clickCount:1,pressure:0))
        view.interactionEnabled = false
        view.mouseDown(with:down); view.mouseUp(with:up)
        XCTAssertTrue(state.strokes.isEmpty,"saving locks the native canvas, not just SwiftUI controls")
        view.interactionEnabled = true
        state.undo.beginUndoGrouping(); view.mouseDown(with:down); view.mouseUp(with:up); state.undo.endUndoGrouping()
        XCTAssertEqual(state.strokes.count,1)

    }

}
