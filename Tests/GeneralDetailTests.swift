import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit
import SwiftUI
@testable import Phosdeck

final class GeneralDetailTests: XCTestCase {
    typealias P = GeneralDetailReference.Pixel
    private let linear = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options:[.workingFormat:CIFormat.RGBAf,.workingColorSpace:linear,.cacheIntermediates:false])
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("general-detail-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    private func recipe(raster: Bool = true) -> EditRecipe {
        EditRecipe(sourceDigest:String(repeating:"a",count:64),decoderVersion:raster ? EditRecipe.rasterDecoderVersion : "8",
            baselineExposure:0,baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
    }
    private func image(_ values: [P], _ w: Int, _ h: Int) -> CIImage {
        let data = values.flatMap { [Float($0.x),Float($0.y),Float($0.z),Float($0.w)] }.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData:data,bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:linear)
    }
    private func pixels(_ image: CIImage) -> [P] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var data = [Float](repeating:0,count:w*h*4)
        context.render(image,toBitmap:&data,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:linear)
        return stride(from:0,to:data.count,by:4).map { P(Double(data[$0]),Double(data[$0+1]),Double(data[$0+2]),Double(data[$0+3])) }
    }
    private func displayBytes(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating:0,count:image.width*image.height*4)
        try data.withUnsafeMutableBytes { bytes in
            let c = try XCTUnwrap(CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                space:ImagePipeline.outputSpace,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue))
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return data
    }
    private func scene(_ w: Int = 64, _ h: Int = 32, alpha: Bool = false) -> [P] {
        (0..<w*h).map { i in
            let x = i%w, y = i/w
            let a = alpha ? (x < 4 || (x > w/2 && x < w/2+4) ? 0 : (x < 12 ? Double(x-3)/9 : 1)) : 1
            let l = 0.16+0.12*exp(-pow((Double(x)-Double(w)*0.4)/1.1,2))
            let c = y < h/2 ? SIMD3<Double>(repeating:l) : SIMD3(l*1.7,l*0.7,l*0.9)
            return P(c.x*a,c.y*a,c.z*a,a)
        }
    }
    private func check(_ a: [P], _ b: [P], accuracy: Double = 0.00001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count,b.count,file:file,line:line)
        var error = 0.0
        for (p,q) in zip(a,b) { for k in 0..<4 { XCTAssertTrue(p[k].isFinite,file:file,line:line); error = max(error,abs(p[k]-q[k])) } }
        XCTAssertLessThanOrEqual(error,accuracy,"max component error \(error)",file:file,line:line)
    }
    func testNeutralBypassValidationAndStructure() throws {
        let source = scene(alpha:true), input = image(source,64,32)
        var off = GeneralSharpening(); off.radius = 3; off.protection = 100
        XCTAssertTrue(try GeneralDetailPipeline.sharpen(input,off,sourceSize:input.extent.size) === input)
        check(GeneralDetailReference.sharpen(source,width:64,height:32,settings:off),source,accuracy:0)
        var r = recipe(); r.sharpening = off; XCTAssertTrue(r.isUnadjustedRaster)
        for value in [Double.nan,.infinity,-1,151] { var bad = r; bad.sharpening.amount = value; XCTAssertThrowsError(try bad.validate()) }
        r.sharpening.radius = 0; XCTAssertThrowsError(try r.validate())
        r = recipe(); var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(r)) as? [String:Any]); json.removeValue(forKey:"sharpening")
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self,from:JSONSerialization.data(withJSONObject:json)))
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:JSONEncoder().encode(r)),r)
    }
    func testMetalMatchesIndependentDoubleAtExtremesAndFractionalScales() throws {
        for alpha in [false,true] {
            let source = scene(alpha:alpha), input = image(source,64,32)
            for settings in [GeneralSharpening(amount:1,radius:0.5,protection:100),GeneralSharpening(amount:80,radius:1.2,protection:25),GeneralSharpening(amount:150,radius:3,protection:0)] {
                for scale in [1.0,0.43,0.1] {
                    let actual = try GeneralDetailPipeline.sharpen(input,settings,sourceSize:CGSize(width:64/scale,height:32/scale))
                    let expected = GeneralDetailReference.sharpen(source,width:64,height:32,settings:settings,scale:scale)
                    check(pixels(actual),expected)
                }
            }
        }
    }
    func testFineLinesNoiseOvershootHaloGrayAndColorEdges() throws {
        let w = 128, h = 32
        var source = scene(w,h), noisy = source
        for i in noisy.indices where i%w > 80 { let n = Double((i*7919)%257)/256-0.5; noisy[i] += P(n*0.003,n*0.003,n*0.003,0) }
        let s = GeneralSharpening(amount:100,radius:1,protection:50)
        let output = GeneralDetailReference.sharpen(noisy,width:w,height:h,settings:s)
        let unprotected = GeneralDetailReference.sharpen(noisy,width:w,height:h,settings:GeneralSharpening(amount:100,radius:1,protection:0))
        let region = source.indices.filter { $0%w > 85 && $0/w < h/2 }
        func rms(_ pixels: [P]) -> Double { sqrt(region.reduce(0) { $0+pow(pixels[$1].x-source[$1].x,2) }/Double(region.count)) }
        let inputNoise = rms(noisy), protectedNoise = rms(output), amplifiedNoise = rms(unprotected)
        XCTAssertLessThanOrEqual(protectedNoise,inputNoise*1.01); XCTAssertGreaterThan(amplifiedNoise,protectedNoise)
        print("GENERAL_SHARP_NOISE rms_input=\(inputNoise) rms_protected=\(protectedNoise) rms_unprotected=\(amplifiedNoise)")
        let center = Int((Double(w)*0.4).rounded()), line = output[center].x-source[center].x
        XCTAssertGreaterThan(line,0.005)
        var noiseGain = 0.0, flatChange = 0.0
        for i in source.indices where i%w > 85 && i/w < h/2 { noiseGain = max(noiseGain,abs(output[i].x-noisy[i].x)) }
        for i in source.indices where i%w < 30 { flatChange = max(flatChange,abs(output[i].x-source[i].x)) }
        XCTAssertLessThan(noiseGain,0.00001); XCTAssertLessThan(flatChange,0.00001)
        source = (0..<w*h).map { i in let c = i%w < 64 ? 0.02 : 0.9; return P(c,c,c,1) }
        let step = GeneralDetailReference.sharpen(source,width:w,height:h,settings:GeneralSharpening(amount:150,radius:3,protection:0))
        let overshoot = step.map { max(0,$0.x-0.9,0.02-$0.x) }.max()!
        XCTAssertLessThan(overshoot,0.001)
        for p in step { XCTAssertEqual(p.x,p.y,accuracy:1e-12); XCTAssertEqual(p.y,p.z,accuracy:1e-12) }
        let colors: [P] = (0..<w*h).map { i in i%w < 64 ? P(0.6,0.15,0.1,1) : P(0.1,0.15,0.6,1) }
        let colorResult = try GeneralDetailPipeline.sharpen(image(colors,w,h),s,sourceSize:CGSize(width:w,height:h))
        for (a,b) in zip(pixels(colorResult),colors) { XCTAssertEqual(a.x/a.z,b.x/b.z,accuracy:0.00002) }
        print("GENERAL_SHARP line_peak_gain=\(line) flat_noise_added_max=\(noiseGain) flat_change=\(flatChange) step_overshoot=\(overshoot)")
    }
    func testAlphaAndExtendedLinearValues() throws {
        let w = 48, h = 24
        for color in [SIMD3<Double>(0.2,0.4,0.1),SIMD3(-0.1,1.3,0.5)] {
            let source: [P] = (0..<w*h).map { i in
                let a = [0.0,1.0/65535,0.25,0.7,1][min(4,(i%w)/10)]
                return P(color.x*a,color.y*a,color.z*a,a)
            }
            let result = pixels(try GeneralDetailPipeline.sharpen(image(source,w,h),GeneralSharpening(amount:150,radius:3,protection:0),sourceSize:CGSize(width:w,height:h)))
            check(result,source,accuracy:0.000003)
        }
    }
    func testCrossFormatSelectionPresetIntensityAndLocalExclusion() throws {
        var raw = recipe(raster:false), raster = recipe()
        raw.noiseReduction = GeneralNoiseReduction(luminance:60,color:80)
        raw.rawDetails.sharpness = 0.8; raw.sharpening = GeneralSharpening(amount:80,radius:2,protection:60)
        var options = RecipePasteOptions(tone:false,whiteBalance:false,color:false,geometry:false,details:true,generalDetails:true,curves:false,zones:false)
        let copied = try raster.pasting(raw,options:options)
        XCTAssertEqual(copied.noiseReduction,raw.noiseReduction)
        XCTAssertEqual(copied.sharpening,raw.sharpening); XCTAssertTrue(copied.rawDetails.isDefault)
        raster.sharpening = GeneralSharpening(amount:20,radius:1,protection:20)
        let mixed = try raster.applyingPreset(raw,options:options,amount:0.5)
        XCTAssertEqual(mixed.noiseReduction,GeneralNoiseReduction(luminance:30,color:40))
        XCTAssertEqual(mixed.sharpening,GeneralSharpening(amount:50,radius:1.5,protection:40))
        XCTAssertEqual(try raster.applyingPreset(raw,options:options,amount:0).sharpening,raster.sharpening)
        XCTAssertEqual(try raster.applyingPreset(raw,options:options,amount:2).sharpening.amount,140)
        options.generalDetails = false
        XCTAssertEqual(try raster.pasting(raw,options:options).sharpening,raster.sharpening)
        XCTAssertFalse(try raster.pasting(raw,options:options).noiseReduction.isActive)
        XCTAssertFalse(options.generalDetails)
        let local = LocalAdjustment(components:[MaskComponent(tool:.radial)])
        XCTAssertFalse(local.editingRecipe(from:raw).sharpening.isActive)
        XCTAssertFalse(raw.baseline().sharpening.isActive)
    }
    @MainActor func testNativeFaderDragAndKeyboardUseFractionalSourcePixelStep() throws {
        let slider = AdjustmentNSSlider(frame:CGRect(x:0,y:0,width:200,height:28))
        slider.minValue = 0.5; slider.maxValue = 3; slider.step = 0.1; slider.resetValue = 1; slider.doubleValue = 1
        var changes = [Double](), commits = 0
        slider.change = { changes.append($0) }; slider.commit = { commits += 1 }
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:28),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = slider
        defer { window.contentView = nil }
        func mouse(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:x,y:14),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        slider.mouseDown(with:try mouse(.leftMouseDown,43))
        slider.mouseDragged(with:try mouse(.leftMouseDragged,119))
        XCTAssertTrue(slider.trackingMouse); XCTAssertEqual(commits,0)
        slider.mouseUp(with:try mouse(.leftMouseUp,119))
        XCTAssertFalse(slider.trackingMouse); XCTAssertEqual(commits,1); XCTAssertEqual(slider.doubleValue,2,accuracy:0.000001)
        let key = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:124))
        slider.keyDown(with:key); XCTAssertEqual(slider.doubleValue,2.1,accuracy:0.000001); XCTAssertEqual(commits,2)
        XCTAssertFalse(changes.isEmpty)
    }
    private func fixture(_ name: String, type: UTType = .png, width w: Int = 128, height h: Int = 96, noisy: Bool = false) throws -> ImageRequest {
        let values = scene(w,h,alpha:type != .jpeg).enumerated().map { i, p -> P in
            let factor = 0.8+0.4*Double(i/w)/Double(h)
            func noise(_ channel: UInt32) -> Double {
                var h = UInt32(i) &+ channel &* 0x9e3779b9
                h ^= h >> 16; h = h &* 0x7feb352d; h ^= h >> 15; h = h &* 0x846ca68b; h ^= h >> 16
                return (Double(h & 65535)/65535-0.5) * (noisy ? 0.025 : 0)*p.w
            }
            return P(p.x*factor+noise(1),p.y*factor+noise(2),p.z*factor+noise(3),p.w)
        }
        let source = image(values,w,h)
        let cg = try XCTUnwrap(context.createCGImage(source,from:source.extent,format:type == .jpeg ? .RGBA8 : .RGBA16,colorSpace:ImagePipeline.outputSpace))
        let url = directory.appendingPathComponent(name+"."+type.preferredFilenameExtension!)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,cg,nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let root = StorageRoot(id:"synthetic",path:directory.path,bookmark:try AccessLease.bookmark(directory,readOnly:true),label:"synthetic")
        return ImageRequest(photo:try ReferenceImporter.inspect(url:url,root:root,rootURL:directory),root:root,recipe:nil)
    }
    private func publicRAWFixture() throws -> ImageRequest {
        let original = try MoreRAWTests.sample("a7iii_12bit_compressed.ARW"), url = directory.appendingPathComponent("Detail-RAW.ARW")
        try FileManager.default.copyItem(at:original,to:url)
        let root = StorageRoot(id:"synthetic",path:directory.path,bookmark:try AccessLease.bookmark(directory,readOnly:true),label:"synthetic and CC0 only")
        return ImageRequest(photo:try ReferenceImporter.inspect(url:url,root:root,rootURL:directory),root:root,recipe:nil)
    }
    private func request(_ s: ImageRequest, _ r: EditRecipe) -> ImageRequest { ImageRequest(photo:s.photo,root:s.root,recipe:r) }
    func testAllRasterInputsQualityExportPrecisionAndGrainOrder() async throws {
        for type in [UTType.jpeg,.tiff,.png] {
            let s = try fixture(type.identifier,type:type), pipeline = ImagePipeline()
            var r = try await pipeline.baseline(s); r.noiseReduction = GeneralNoiseReduction(luminance:60,color:70); r.sharpening = GeneralSharpening(amount:100,radius:1,protection:20)
            let neutral = try await pipeline.render(request(s,r.baseline()),longEdge:nil,pixelFormat:.RGBA16)
            for edge: Int? in [nil,61] {
                let job = request(s,r), preview = try await pipeline.render(job,longEdge:edge,pixelFormat:.RGBA16)
                let url = directory.appendingPathComponent(type.identifier+"-\(edge ?? 0).tif")
                _ = try await pipeline.export(job,staging:url,options:ExportOptions(format:.tiff,longEdge:edge))
                let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil)), out = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded,0,nil))
                XCTAssertEqual(out.bitsPerComponent,16)
                let a = pixels(CIImage(cgImage:preview.image)), b = pixels(CIImage(cgImage:out))
                check(a,b,accuracy:0.000001)
                let pngPreview = try await pipeline.render(job,longEdge:edge)
                let pngURL = directory.appendingPathComponent(type.identifier+"-\(edge ?? 0)-out.png")
                _ = try await pipeline.export(job,staging:pngURL,options:ExportOptions(format:.png,longEdge:edge))
                let pngReader = try XCTUnwrap(CGImageSourceCreateWithURL(pngURL as CFURL,nil)), png = try XCTUnwrap(CGImageSourceCreateImageAtIndex(pngReader,0,nil))
                XCTAssertEqual(try displayBytes(png),try displayBytes(pngPreview.image),"PNG8 and same-size quality preview")
                for matte in [JPEGMatte.black,.white] {
                    let mattePreview = try await pipeline.render(job,longEdge:edge,jpegMatte:matte)
                    let jpegURL = directory.appendingPathComponent(type.identifier+"-\(edge ?? 0)-\(matte).jpg")
                    _ = try await pipeline.export(job,staging:jpegURL,options:ExportOptions(longEdge:edge,quality:1,jpegMatte:matte))
                    let reader = try XCTUnwrap(CGImageSourceCreateWithURL(jpegURL as CFURL,nil)), jpeg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader,0,nil))
                    let bytes = try displayBytes(jpeg), reference = try displayBytes(mattePreview.image)
                    let mae = zip(bytes,reference).reduce(0.0) { $0+abs(Double($1.0)-Double($1.1))/255 }/Double(bytes.count)
                    XCTAssertLessThan(mae,0.02,"JPEG lossy error stays separate from lossless depth/alpha checks")
                }
                if edge == nil {
                    let n = pixels(CIImage(cgImage:neutral.image))
                    XCTAssertNotEqual(a,n)
                    for (v,q) in zip(a,n) { XCTAssertEqual(v.w,q.w,accuracy:0) }
                    let codes = (preview.image.dataProvider!.data! as Data).withUnsafeBytes { Array($0.bindMemory(to:UInt16.self)) }
                    XCTAssertGreaterThan(Set(codes).count,256)
                }
            }
            r.grain = FilmGrain(amount:50,size:25,roughness:40,seed:42)
            let grain = try await pipeline.render(request(s,r),longEdge:nil,pixelFormat:.RGBA16)
            XCTAssertNotEqual(pixels(CIImage(cgImage:grain.image)),pixels(CIImage(cgImage:neutral.image)))
        }
    }
    func testNoiseChangesInvalidateDraftStagesAndResetMatchesFresh() async throws {
        for source in [try fixture("draft"),try MoreRAWTests.request("a7iii_12bit_compressed.ARW")] {
            let cached = ImagePipeline()
            var r = try await cached.baseline(source)
            let neutral = try await cached.renderInteractive(request(source,r),longEdge:128)
            for settings in [GeneralNoiseReduction(luminance:70,color:30),GeneralNoiseReduction(luminance:20,color:90),GeneralNoiseReduction()] {
                r.noiseReduction = settings
                let actual = try await cached.renderInteractive(request(source,r),longEdge:128)
                let fresh = try await ImagePipeline().renderInteractive(request(source,r),longEdge:128)
                XCTAssertEqual(try displayBytes(actual.image),try displayBytes(fresh.image),"A noise edit cannot reuse pre-denoise spatial pixels")
                if !settings.isActive { XCTAssertEqual(try displayBytes(actual.image),try displayBytes(neutral.image)) }
            }
        }
    }
    func testFullPipelineOrderDenoiseDevelopSharpenGeometryResizeGrain() async throws {
        let source = try fixture("order",type:.jpeg), pipeline = ImagePipeline()
        var r = try await pipeline.baseline(source)
        r.noiseReduction = GeneralNoiseReduction(luminance:70,color:60)
        r.sharpening = GeneralSharpening(amount:120,radius:1.5,protection:20)
        r.exposure = 0.2; r.contrast = 1.1; r.crop = Crop(x:0.1,y:0.1,width:0.8,height:0.8); r.flipHorizontal = true
        r.vignette.amount = -12; r.grain = FilmGrain(amount:60,size:25,roughness:50,seed:21)
        let decoded = try RasterExposure.apply(XCTUnwrap(CIImage(contentsOf:directory.appendingPathComponent(source.photo.relativePath),options:[.applyOrientationProperty:true])),ev:r.exposure)
        let size = decoded.extent.size
        let noise = try GeneralDetailPipeline.denoise(decoded,r.noiseReduction,sourceSize:size)
        let developed = try ImagePipeline.develop(noise,recipe:r,context:context)
        let sharp = try GeneralDetailPipeline.sharpen(developed,r.sharpening,sourceSize:size)
        let geometry = try ImagePipeline.geometry(sharp,recipe:r)
        let vignette = try CreativeVignettePipeline.apply(geometry,r.vignette)
        let resized = ImagePipeline.resized(vignette,longEdge:61)
        let expected = try FilmGrainPipeline.apply(resized,r.grain)
        let actual = try await pipeline.render(request(source,r),longEdge:61,pixelFormat:.RGBA16)
        check(pixels(CIImage(cgImage:actual.image)),pixels(expected),accuracy:0.00005)
        let wrong = try GeneralDetailPipeline.denoise(try FilmGrainPipeline.apply(decoded,r.grain),r.noiseReduction,sourceSize:size)
        let right = try FilmGrainPipeline.apply(noise,r.grain)
        let difference = zip(pixels(wrong),pixels(right)).map { abs($0.x-$1.x) }.max()!
        XCTAssertGreaterThan(difference,0.001,"The fixture must detect denoising after creative grain")
    }
    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Native model did not settle"); throw LRCError("模型超时")
    }
    @MainActor func testNativeWorkflowWindowUndoSnapshotsSyncReopenAndFrozenExport() async throws {
        let sources = try [fixture("Detail-PNG",width:640,height:400,noisy:true),fixture("Detail-TIFF",type:.tiff,width:640,height:400,noisy:true),fixture("Detail-JPEG",type:.jpeg,width:640,height:400,noisy:true),publicRAWFixture()]
        var catalog: CatalogStore! = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:sources[0].root.bookmark)
        var photos = [Photo]()
        for s in sources { var p = s.photo; p.rootID = root.id; try catalog.index(p); photos.append(p) }
        let model = AppModel(); model.catalog = catalog; try model.reload(); model.editMode = true
        model.choose([photos[0].id],active:photos[0].id)
        try await waitFor { model.canEdit && model.previewCurrent }
        let baseline = try XCTUnwrap(model.recipe)
        model.undo.groupsByEvent = false; model.undo.beginUndoGrouping()
        model.changeRecipe({ $0.sharpening = GeneralSharpening(amount:80,radius:1.4,protection:35); $0.noiseReduction = GeneralNoiseReduction(luminance:55,color:65) },commit:false)
        XCTAssertTrue(model.commitRecipe()); model.undo.endUndoGrouping()
        let edited = try XCTUnwrap(model.recipe)
        model.undo.undo(); XCTAssertEqual(model.recipe,baseline)
        model.undo.redo(); XCTAssertEqual(model.recipe,edited)
        XCTAssertTrue(model.saveSnapshot(name:"通用细节"))
        XCTAssertTrue(model.editHistory.contains { $0.title.contains("通用锐化") })
        let options = RecipePasteOptions(tone:false,whiteBalance:false,color:false,geometry:false,details:false,generalDetails:true,curves:false,zones:false)
        XCTAssertTrue(model.savePreset(name:"细节",source:edited,options:options))
        let preset = try XCTUnwrap(catalog.presets().first)
        let selected = try JSONDecoder().decode(EditRecipe.self,from:preset.recipe)
        XCTAssertEqual(selected.sharpening,edited.sharpening)
        XCTAssertTrue(model.applyAdjustments(source:selected,options:options,ids:Set(photos.dropFirst().map(\.id)),title:"同步通用细节",amount:0.5))
        try await waitFor { !model.busy }; XCTAssertNil(model.error)
        for p in photos.dropFirst() {
            let r = try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(catalog.photo(p.id)?.recipe))
            XCTAssertEqual(r.noiseReduction,GeneralNoiseReduction(luminance:27.5,color:32.5))
            XCTAssertEqual(r.sharpening.amount,40); XCTAssertTrue(r.rawDetails.isDefault)
        }
        model.undo.undo(); XCTAssertNil(try catalog.photo(photos[1].id)?.recipe)
        model.undo.redo(); XCTAssertNotNil(try catalog.photo(photos[1].id)?.recipe)
        let stored = try XCTUnwrap(catalog.photo(photos[0].id))
        let thumb = try await ThumbnailService().image(photo:stored,root:root)
        let expected = try await model.pipeline.render(ImageRequest(photo:stored,root:root,recipe:edited),longEdge:320)
        check(pixels(CIImage(cgImage:thumb)),pixels(CIImage(cgImage:expected.image)),accuracy:0.00001)
        let suite = "general-detail-ui-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:"developNoiseOpen"); defaults.set(true,forKey:"developSharpenOpen"); defaults.set(false,forKey:"developBasicOpen")
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:1280,height:800),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.title = "通用细节原生验证"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        let workspace = NSHostingView(rootView:WorkspaceView(model:model).defaultAppStorage(defaults))
        window.contentView = workspace; window.setContentSize(CGSize(width:1280,height:800)); window.makeKeyAndOrderFront(nil); NSApp.activate()
        let keyboard = WorkspaceKeyboard(model:model)
        defer { withExtendedLifetime(keyboard) {}; window.orderOut(nil); window.contentView = nil; model.choose([],active:nil); model.catalog = nil }
        model.selectZoom(1); try await waitFor { model.previewCurrent }
        try await Task.sleep(for:.milliseconds(200)); workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.bounds.size,CGSize(width:1280,height:800))
        let bitmap = try XCTUnwrap(workspace.bitmapImageRepForCachingDisplay(in:workspace.bounds))
        workspace.cacheDisplay(in:workspace.bounds,to:bitmap)
        let attachment = XCTAttachment(data:try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),uniformTypeIdentifier:"public.png")
        attachment.name = "General-detail-1280x800"; attachment.lifetime = .keepAlways; add(attachment)
        model.undo.groupsByEvent = true
        let hold = min(600,max(0,Double(ProcessInfo.processInfo.environment["PHOSDECK_DETAIL_UI_SECONDS"] ?? "0") ?? 0))
        if hold > 0 {
            print("GENERAL_DETAIL_UI_ROOT=\(directory.path)")
            let until = Date().addingTimeInterval(hold)
            while window.isVisible && Date() < until { try await Task.sleep(for:.milliseconds(100)) }
        }
        XCTAssertTrue(model.commitRecipe())
        let reopeningRecipe = try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(catalog.photo(stored.id)?.recipe))
        // A frozen task survives later edits, cancellation and a new CatalogStore.
        let job = ImageRequest(photo:stored,root:root,recipe:edited), target = directory.appendingPathComponent("frozen.tif")
        let snapshot = try await model.pipeline.freezeExport(ExportSnapshot(id:UUID().uuidString,request:job,destination:target,
            targetBookmark:try AccessLease.bookmark(directory,readOnly:false),options:ExportOptions(format:.tiff)))
        let cancel = Task { await ExportService(pipeline:ImagePipeline(),checkpoint:{ if $0 == "verified" { withUnsafeCurrentTask { $0?.cancel() } } }).run([snapshot],catalog:catalog) { _ in } }
        _ = await cancel.value
        XCTAssertEqual(try ExportService.logs(catalog:catalog).first?.state,"cancelled")
        let file = catalog.fileURL
        model.choose([],active:nil); model.catalog = nil; catalog = nil
        try await Task.sleep(for:.milliseconds(50))
        let reopened = try CatalogStore(fileURL:file)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(reopened.photo(stored.id)?.recipe)),reopeningRecipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(reopened.snapshots(photoID:stored.id).first?.recipe)),edited)
        if hold > 0 {
            model.catalog = reopened; try model.reload(); model.choose([stored.id],active:stored.id)
            try await waitFor { model.canEdit && model.previewCurrent }
            window.makeKeyAndOrderFront(nil); NSApp.activate()
            print("GENERAL_DETAIL_UI_REOPENED")
            let until = Date().addingTimeInterval(45)
            while window.isVisible && Date() < until { try await Task.sleep(for:.milliseconds(100)) }
        }
        var later = edited; later.sharpening.amount = 0; later.noiseReduction = GeneralNoiseReduction(); try reopened.saveRecipe(id:stored.id,recipe:later)
        let reports = await ExportService(pipeline:ImagePipeline()).run([snapshot],catalog:reopened) { _ in }
        XCTAssertTrue(reports[0].hasPrefix("成功"),reports.joined(separator:";"))
        XCTAssertEqual(try ExportService.logs(catalog:reopened).first?.snapshot.request.recipe,edited)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL,nil)), out = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader,0,nil))
        let quality = try await model.pipeline.render(job,longEdge:nil,pixelFormat:.RGBA16)
        check(pixels(CIImage(cgImage:out)),pixels(CIImage(cgImage:quality.image)),accuracy:0.000001)
    }
    @MainActor func testRapidNoiseEditsAndPhotoSwitchPublishLatestQuality() async throws {
        let sources = try [fixture("rapid-a",width:640,height:400),fixture("rapid-b",type:.jpeg,width:320,height:200)]
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("rapid-catalog"))
        let root = try catalog.addRoot(url:directory,bookmark:sources[0].root.bookmark)
        var photos = [Photo]()
        for s in sources { var p = s.photo; p.rootID = root.id; try catalog.index(p); photos.append(p) }
        let model = AppModel(); model.catalog = catalog; try model.reload()
        defer { model.choose([],active:nil); model.catalog = nil }
        model.choose([photos[0].id],active:photos[0].id)
        try await waitFor { model.canEdit && model.previewCurrent }
        for value in [90.0,15,80,35] {
            model.changeRecipe({ $0.noiseReduction = GeneralNoiseReduction(luminance:value,color:100-value) },commit:false)
            try await Task.sleep(for:.milliseconds(15))
        }
        XCTAssertTrue(model.commitRecipe())
        model.choose([photos[1].id],active:photos[1].id)
        try await waitFor { model.canEdit && model.previewCurrent && model.image?.width == 320 }
        let current = try XCTUnwrap(model.recipe), visible = try XCTUnwrap(model.image)
        let expected = try await ImagePipeline().render(ImageRequest(photo:photos[1],root:root,recipe:current),longEdge:2400)
        XCTAssertEqual(try displayBytes(visible),try displayBytes(expected.image))
        try await Task.sleep(for:.milliseconds(250))
        XCTAssertEqual(model.activeID,photos[1].id)
        XCTAssertEqual(try displayBytes(XCTUnwrap(model.image)),try displayBytes(expected.image),"A late noise frame cannot overwrite the selected photo")
    }
    private func residentBytes() -> UInt64? {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
    func testPublicRAWScalePerformanceAndCacheBoundary() async throws {
        let source = try MoreRAWTests.request("a7iii_12bit_compressed.ARW")
        for combined in [false,true] {
            let pipeline = ImagePipeline()
            var r = try await pipeline.baseline(source); let defaults = try await pipeline.rawDefaults(request(source,r))
            r.noiseReduction = GeneralNoiseReduction(luminance:60,color:60)
            if combined { r.sharpening = GeneralSharpening(amount:80,radius:1.2,protection:35) }
            for (mode,edge) in [("draft",960),("fit-quality",1600),("100-percent",0)] {
                let start = Date(), beforeRSS = residentBytes()
                let result = mode == "draft" ? try await pipeline.renderInteractive(request(source,r),longEdge:edge)
                    : try await pipeline.render(request(source,r),longEdge:edge == 0 ? nil : edge,reuseDecoded:true)
                var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
                print("GENERAL_DETAIL_PERF combined=\(combined) mode=\(mode) dimensions=\(result.image.width)x\(result.image.height) seconds=\(Date().timeIntervalSince(start)) rss_before=\(beforeRSS ?? 0) rss_after=\(residentBytes() ?? 0) process_peak_rss_bytes=\(usage.ru_maxrss)")
                let cache = await pipeline.qualityCacheBytes; XCTAssertEqual(cache,0,"General details cannot extend the verified RAW cache subset")
            }
            let start = Date(), beforeRSS = residentBytes(), url = directory.appendingPathComponent("raw-detail-\(combined).tif")
            _ = try await pipeline.export(request(source,r),staging:url,options:ExportOptions(format:.tiff))
            var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
            print("GENERAL_DETAIL_PERF combined=\(combined) mode=full-tiff16 seconds=\(Date().timeIntervalSince(start)) rss_before=\(beforeRSS ?? 0) rss_after=\(residentBytes() ?? 0) process_peak_rss_bytes=\(usage.ru_maxrss)")
            let after = try await pipeline.rawDefaults(request(source,r)); XCTAssertEqual(after,defaults)
            XCTAssertTrue(r.rawDetails.isDefault)
            let task = Task { try await ImagePipeline().render(request(source,r),longEdge:nil) }; task.cancel()
            do { _ = try await task.value; XCTFail("Pre-cancelled render must stop") } catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
        }
    }
}
