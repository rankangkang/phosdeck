import XCTest
import AppKit
import SwiftUI
import CoreImage
import ImageIO
import GRDB
@testable import Phosdeck

final class AlphaTests: XCTestCase {
    var folder: URL!
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("alpha-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:folder) }
    func fixture(_ name: String = "alpha", depth: Int = 16, icc: CGColorSpace? = nil) throws -> ImageRequest {
        let url = folder.appendingPathComponent(name+".png")
        try PNGFixture.data(depth:depth,icc:icc).write(to:url)
        return try PNGFixture.request(url)
    }
    func request(_ source: ImageRequest, _ recipe: EditRecipe) -> ImageRequest { ImageRequest(photo:source.photo,root:source.root,recipe:recipe) }
    @nonobjc func floats(_ image: CIImage) -> [Float] {
        let bounds = image.extent.integral, width = Int(bounds.width), height = Int(bounds.height)
        var result = [Float](repeating:0,count:width*height*4)
        do {
            try result.withUnsafeMutableBytes { bytes in
                let destination = CIRenderDestination(bitmapData:bytes.baseAddress!,width:width,height:height,bytesPerRow:width*16,format:.RGBAf)
                destination.colorSpace = linear; destination.alphaMode = .premultiplied
                _ = try context.startTask(toRender:image,from:bounds,to:destination,at:.zero).waitUntilCompleted()
            }
        } catch { XCTFail("Float readback failed: \(error)") }
        return result
    }
    @nonobjc func floats(_ image: CGImage) -> [Float] {
        var result = [Float](repeating:0,count:image.width*image.height*4)
        result.withUnsafeMutableBytes { bytes in
            let info = CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue).union(.floatComponents).union(.byteOrder32Little)
            guard let destination = CGContext(data:bytes.baseAddress!,width:image.width,height:image.height,bitsPerComponent:32,
                bytesPerRow:image.width*16,space:linear,bitmapInfo:info.rawValue) else { XCTFail("Float Quartz readback failed"); return }
            destination.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return result
    }
    func read(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src,0,nil))
    }
    func straight16(_ image: CIImage) throws -> [UInt16] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var result = [UInt16](repeating:0,count:width*height*4)
        try result.withUnsafeMutableBytes { bytes in
            let dst = CIRenderDestination(bitmapData:bytes.baseAddress!,width:width,height:height,bytesPerRow:width*8,format:.RGBA16)
            dst.colorSpace = ImagePipeline.outputSpace; dst.alphaMode = .unpremultiplied; dst.isFlipped = true; dst.isDithered = false
            _ = try context.startTask(toRender:image,from:image.extent,to:dst,at:.zero).waitUntilCompleted()
        }
        for i in stride(from:0,to:result.count,by:4) where result[i+3] == 0 { result[i] = 0; result[i+1] = 0; result[i+2] = 0 }
        return result
    }
    func storage16(_ image: CGImage) throws -> [UInt16] {
        XCTAssertEqual(image.bitsPerComponent,16); XCTAssertEqual(image.alphaInfo,.last)
        return try XCTUnwrap(image.dataProvider?.data as Data?).withUnsafeBytes { raw in
            let values = raw.bindMemory(to:UInt16.self)
            return (0..<image.height).flatMap { row in Array(values[(row*image.bytesPerRow/2)..<(row*image.bytesPerRow/2+image.width*4)]) }
        }
    }

    func testInputPrecisionProfilesAndTransparentHiddenRGBConvention() async throws {
        let pipeline = ImagePipeline()
        for depth in [8,16] { for profile in [nil,CGColorSpace(name:CGColorSpace.sRGB),CGColorSpace(name:CGColorSpace.displayP3)] {
            let source = try fixture(UUID().uuidString,depth:depth,icc:profile)
            let baseline = try await pipeline.baseline(source), job = request(source,baseline)
            let actual = try await pipeline.render(job,longEdge:nil,pixelFormat:.RGBA16)
            let url = folder.appendingPathComponent(source.photo.relativePath)
            let input = try XCTUnwrap(CIImage(contentsOf:url,options:profile == nil ? [.colorSpace:ImagePipeline.outputSpace] : [:]))
            let reference = try XCTUnwrap(context.createCGImage(input,from:input.extent,format:.RGBAf,colorSpace:linear,deferred:false))
            let expected = try straight16(CIImage(cgImage:reference)), stored = try storage16(actual.image)
            let direct = try straight16(input)
            let delta = zip(direct,expected).map { abs(Int($0)-Int($1)) }.max() ?? 0
            print("ALPHA_ICC depth=\(depth) profile=\(profile?.name as String? ?? "untagged") direct_conversion_max_u16=\(delta)")
            XCTAssertTrue(stored == expected,"Neutral source/quality comparison uses the same 16-bit, sRGB and straight-alpha quantization")
            if depth == 16 {
                let partial = stride(from:0,to:stored.count,by:4).filter { stored[$0+3] > 0 && stored[$0+3] < 40000 }
                XCTAssertGreaterThan(Set(partial.map { stored[$0] }).count,1000,"Fractional and near-zero alpha must not collapse straight color to 8-bit or premultiplied 16-bit codes")
            }
            let values = floats(actual.image)
            XCTAssertTrue(values.allSatisfy(\.isFinite))
            for i in stride(from:0,to:stored.count,by:4) where stored[i+3] == 0 {
                XCTAssertEqual(stored[i],0); XCTAssertEqual(stored[i+1],0); XCTAssertEqual(stored[i+2],0)
            }
        } }
    }

    func testNeutralPNG8CodesAndNearOpaqueJPEGRequireExplicitChoice() async throws {
        let source = try fixture("neutral-eight",depth:8), pipeline = ImagePipeline()
        let recipe = try await pipeline.baseline(source)
        let rendered = try await pipeline.render(request(source,recipe),longEdge:nil)
        XCTAssertEqual(rendered.image.alphaInfo,.last)
        let data = try XCTUnwrap(rendered.image.dataProvider?.data as Data?)
        var expected = Data()
        let alphas = [0,1,1,63,127,255]
        for y in 0..<96 { for x in 0..<128 {
            let alpha = alphas[min(5,x*6/128)]
            let colors = [x == 0 ? 0 : (x*317+y*53)%255,x == 0 ? 0 : (x*101+y*271)%255,x == 0 ? 0 : (x*197+y*137)%255]
            expected.append(contentsOf:(alpha == 0 ? [0,0,0] : colors).map { UInt8($0) }+[UInt8(alpha)])
        } }
        XCTAssertTrue(data == expected,"Neutral 8-bit sRGB/untagged PNG preserves visible straight codes; alpha=0 hidden RGB normalizes to zero")
        for alpha in [65534,65535] {
            let header = PNGFixture.word(1)+PNGFixture.word(1)+Data([16,6,0,0,0])
            var scanline = Data([0])
            for n in [12345,23456,34567,alpha] { scanline.append(contentsOf:[UInt8(n>>8),UInt8(n&255)]) }
            let url = folder.appendingPathComponent("near-\(alpha).png")
            let bytes = Data([137,80,78,71,13,10,26,10])+PNGFixture.chunk("IHDR",header)
                + PNGFixture.chunk("IDAT",try PNGFixture.compress(scanline))+PNGFixture.chunk("IEND",Data())
            try bytes.write(to:url)
            let source = try PNGFixture.request(url)
            let baseline = try await pipeline.baseline(source)
            do {
                _ = try await pipeline.export(request(source,baseline),staging:folder.appendingPathComponent("near-\(alpha).jpg"),options:ExportOptions())
                XCTAssertEqual(alpha,65535,"16-bit alpha must be tested before 8-bit rounding")
            } catch { XCTAssertEqual(alpha,65534); XCTAssertTrue(error.localizedDescription.contains("铺底")) }
        }
    }

    func testAdjustmentsMasksAndAllRepairModesPreserveTargetAlpha() async throws {
        let source = try fixture(), pipeline = ImagePipeline(), baseline = try await pipeline.baseline(source)
        let original = try await pipeline.render(request(source,baseline),longEdge:nil,pixelFormat:.RGBA16)
        let originalBytes = try storage16(original.image)
        let originalAlpha = stride(from:3,to:originalBytes.count,by:4).map { originalBytes[$0] }
        var variants = [(String,EditRecipe)]()
        for (name,edit) in [
            ("exposure", { (r: inout EditRecipe) in r.exposure = 0.4 }),
            ("white-balance", { (r: inout EditRecipe) in r.asShotWhiteBalance = false; r.temperature = 7000; r.tint = 10 }),
            ("color", { (r: inout EditRecipe) in r.contrast = 1.2; r.saturation = 0.8; r.develop.vibrance = 25; r.develop.mixer[0].hue = 20 }),
            ("curve", { (r: inout EditRecipe) in r.develop.curves = ToneCurves(); r.develop.curves?.channels[0][2].y = 0.65 }),
            ("spatial", { (r: inout EditRecipe) in r.develop.shadows = 35; r.develop.texture = 25; r.develop.clarity = -15 }),
            ("dehaze", { (r: inout EditRecipe) in r.develop.dehaze = 25 }),
            ("zones", { (r: inout EditRecipe) in r.develop.zones = ToneZones(); r.develop.zones?.gains[2] = 0.5 }),
            ("black-white", { (r: inout EditRecipe) in r.develop.blackAndWhite = true; r.develop.blackWhiteMixer[0] = 30 }),
            ("finish", { (r: inout EditRecipe) in r.vignette.amount = 30; r.grain = FilmGrain(amount:30,size:35,roughness:50,seed:123) })
        ] { var recipe = baseline; edit(&recipe); variants.append((name,recipe)) }
        for tool in MaskTool.allCases {
            var component = MaskComponent(tool:tool)
            component.strokes = [MaskStroke(points:[MaskPoint(0.65,0.5)],radius:0.25,autoMask:true)]
            component.samples = [MaskSample(point:MaskPoint(0.65,0.5),red:0.2,green:0.2,blue:0.2)]
            component.tolerance = 0.8
            if tool == .object {
                component.raster = SmartMaskRaster(source: SmartMaskSource(recipe: baseline, size: original.orientedSourceSize), model: "synthetic-alpha-test",
                    base: try SmartMaskTile(values: [0,1,0.5,1], width: 2, height: 2, region: CGRect(x: 0, y: 0, width: 1, height: 1)))
            }
            var group = LocalAdjustment(components:[component]); group.exposure = 0.8
            group.settings = LocalDevelopSettings(); group.settings?.develop.clarity = 20
            var recipe = baseline; recipe.schemaVersion = 3; recipe.maskVersion = tool == .object ? 3 : 2; recipe.localAdjustments = [group]; variants.append(("mask-"+tool.rawValue,recipe))
        }
        for mode in SpotRepairMode.allCases {
            var recipe = baseline
            recipe.repairs = [SpotRepair(mode:mode,points:[MaskPoint(0.65,0.5)],radius:0.25,feather:0.4,opacity:1,
                sourceOffset:mode == .remove ? nil : MaskPoint(0.23,0))]
            variants.append(("repair-"+mode.rawValue,recipe))
        }
        for (name,recipe) in variants {
            let result = try await pipeline.render(request(source,recipe),longEdge:nil,pixelFormat:.RGBA16)
            let data = try storage16(result.image)
            XCTAssertTrue(stride(from:3,to:data.count,by:4).map { data[$0] } == originalAlpha,name+" target coverage")
            XCTAssertTrue(floats(result.image).allSatisfy(\.isFinite),name)
            XCTAssertTrue(data != originalBytes,name+" must actually edit visible colors")
            let draft = try await pipeline.renderInteractive(request(source,recipe),longEdge:64)
            XCTAssertTrue(floats(draft.image).allSatisfy(\.isFinite),name+" interactive")
        }
    }

    func constant(_ name: String, alpha: (Int,Int) -> UInt8) throws -> ImageRequest {
        let w = 96, h = 64
        var raw = Data()
        for y in 0..<h { raw.append(0); for x in 0..<w {
            let a = alpha(x,y)
            raw.append(contentsOf:a == 0 ? [255,0,255,0] : [180,100,60,a])
        } }
        let header = PNGFixture.word(w)+PNGFixture.word(h)+Data([8,6,0,0,0])
        let data = Data([137,80,78,71,13,10,26,10])+PNGFixture.chunk("IHDR",header)
            + PNGFixture.chunk("IDAT",try PNGFixture.compress(raw))+PNGFixture.chunk("IEND",Data())
        let url = folder.appendingPathComponent(name+".png"); try data.write(to:url); return try PNGFixture.request(url)
    }

    func testPremultipliedSamplingAndAlphaWeightedSpatialEdgesHaveNoColorFringe() async throws {
        let source = try constant("edge") { x,y in x > 20 && x < 80 && y > 10 && y < 55 ? (x < 45 ? 128 : 255) : 0 }
        let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(source)
        let original = try await pipeline.render(request(source,baseline),longEdge:nil,pixelFormat:.RGBA16)
        let center = floats(original.image), index = (32*96+60)*4
        let color = SIMD3(center[index],center[index+1],center[index+2])
        for spatial in [false,true] {
            var recipe = baseline
            if spatial {
                recipe.develop.texture = 70; recipe.develop.clarity = 60
                let decoded = try XCTUnwrap(CIImage(contentsOf:folder.appendingPathComponent(source.photo.relativePath),options:[.colorSpace:ImagePipeline.outputSpace]))
                let bitmap = try XCTUnwrap(context.createCGImage(decoded,from:decoded.extent,format:.RGBAf,colorSpace:linear,deferred:false))
                let input = CIImage(cgImage:bitmap)
                let guide = try SpatialDevelopPipeline.run("logLuminance",extent:input.extent,[input])
                let base = try SpatialDevelopPipeline.guided(guide,guide:guide,radius:2,epsilon:0.04,coverage:input)
                let g = floats(guide), b = floats(base)
                var rows = [[Float]]()
                for x in [20,21,22,30,44,45,79,80] { let offset = (30*96+x)*4; rows.append([Float(x),g[offset],b[offset]]) }
                let guideError = rows.filter { $0[0] >= 21 && $0[0] <= 79 }.map { abs($0[1]-$0[2]) }.max() ?? 0
                XCTAssertLessThan(guideError,0.00001,"Coverage-weighted analysis excludes invisible guide samples")
            }
            recipe.perspective = PerspectiveSettings(horizontal:35,vertical:-25,aspect:8,constrainCrop:false)
            recipe.flipHorizontal = true; recipe.quarterTurns = 1; recipe.straightenDegrees = 3
            recipe.crop = Crop(x:0.05,y:0.05,width:0.9,height:0.9)
            let result = try await pipeline.render(request(source,recipe),longEdge:61,pixelFormat:.RGBA16)
            let values = floats(result.image)
            XCTAssertTrue(values.allSatisfy(\.isFinite))
            var partialCount = 0
            var maxError: Float = 0
            for i in stride(from:0,to:values.count,by:4) {
                let a = values[i+3]
                if a > 0.02 && a < 0.98 {
                    partialCount += 1
                    let c = SIMD3(values[i],values[i+1],values[i+2])/a
                    maxError = max(maxError,max(abs(c.x-color.x),max(abs(c.y-color.y),abs(c.z-color.z))))
                }
                if a == 0 { XCTAssertEqual(values[i],0); XCTAssertEqual(values[i+1],0); XCTAssertEqual(values[i+2],0) }
            }
            XCTAssertGreaterThan(partialCount,20)
            XCTAssertLessThan(maxError,0.002,"Constant color across premultiplied resampling; spatial=\(spatial)")
        }
        for (name,alpha) in [("empty",UInt8(0)),("semi",UInt8(1)),("half",UInt8(128))] {
            let source = try constant(name) { _,_ in alpha }
            var r = try await pipeline.baseline(source); r.develop.dehaze = 40; r.develop.shadows = 35; r.develop.clarity = 40
            r.develop.zones = ToneZones(); r.develop.zones?.gains[1] = 0.5
            let result = try await pipeline.render(request(source,r),longEdge:48,pixelFormat:.RGBA16)
            XCTAssertTrue(floats(result.image).allSatisfy(\.isFinite))
            if alpha == 0 { XCTAssertTrue(floats(result.image).allSatisfy { $0 == 0 }) }
        }
    }

    func testThreeFormatOutputsExplicitMattePreviewAndFloatTIFF16() async throws {
        let source = try fixture(), pipeline = ImagePipeline()
        var r = try await pipeline.baseline(source); r.exposure = 0.35
        r.perspective = PerspectiveSettings(horizontal:40,vertical:-30,aspect:0,constrainCrop:false)
        let job = request(source,r)
        do { _ = try await pipeline.export(job,staging:folder.appendingPathComponent("missing.jpg"),options:ExportOptions()); XCTFail("JPEG must require explicit matte") }
        catch { XCTAssertTrue(error.localizedDescription.contains("铺底")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("missing.jpg").path))
        for edge in [nil,Optional(61)] {
            for format in [ExportFormat.png,.tiff] {
                let preview = try await pipeline.render(job,longEdge:edge,pixelFormat:format == .tiff ? .RGBA16 : .RGBA8)
                let out = folder.appendingPathComponent(UUID().uuidString+"."+format.fileExtension)
                _ = try await pipeline.export(job,staging:out,options:ExportOptions(format:format,longEdge:edge))
                let decoded = try read(out)
                XCTAssertEqual(decoded.bitsPerComponent,format.bitDepth)
                let a = try straight16(CIImage(cgImage:preview.image)), b = try straight16(CIImage(cgImage:decoded))
                XCTAssertTrue(a == b,"Lossless export and equal-size quality preview: same depth/color/alpha convention")
                XCTAssertTrue(ImagePipeline.hasTransparency(CIImage(cgImage:decoded),context:context))
                if format == .tiff { XCTAssertGreaterThan(Set(stride(from:0,to:b.count,by:4).map { b[$0] }).count,1000) }
            }
            for matte in [JPEGMatte.black,.white] {
                let preview = try await pipeline.render(job,longEdge:edge,jpegMatte:matte)
                let out = folder.appendingPathComponent(UUID().uuidString+".jpg")
                _ = try await pipeline.export(job,staging:out,options:ExportOptions(longEdge:edge,quality:1,jpegMatte:matte))
                let result = try read(out)
                XCTAssertFalse(ImagePipeline.hasTransparency(CIImage(cgImage:result),context:context))
                print("ALPHA_JPEG edge=\(edge ?? 0) matte=\(matte) output=\(result.width)x\(result.height) bpc=\(result.bitsPerComponent) row=\(result.bytesPerRow) preview=\(preview.image.width)x\(preview.image.height)")
                let actual = floats(result), expected = floats(preview.image)
                let mae = zip(actual,expected).reduce(0.0) { $0+Double(abs($1.0-$1.1)) }/Double(actual.count)
                XCTAssertLessThan(mae,0.02,"JPEG lossy error is separate from PNG8 and TIFF16 quantization")
                let raw = try await pipeline.render(job,longEdge:edge,pixelFormat:.RGBA16)
                let input = floats(raw.image), presented = floats(preview.image)
                for i in stride(from:0,to:input.count,by:4) where input[i+3] == 0 {
                    let color: Float = matte == .white ? 1 : 0
                    XCTAssertEqual(presented[i],color); XCTAssertEqual(presented[i+1],color); XCTAssertEqual(presented[i+2],color)
                }
            }
        }
    }

    func testMattePreferencesFrozenQueueCancellationRecoveryAndNoOverwrite() async throws {
        let source = try fixture(), pipeline = ImagePipeline()
        var catalog: CatalogStore? = try CatalogStore(directory:folder.appendingPathComponent("catalog"))
        let root = try catalog!.addRoot(url:folder,bookmark:source.root.bookmark)
        var photo = source.photo; photo.rootID = root.id; try catalog!.index(photo)
        let recipe = try await pipeline.baseline(source)
        let job = ImageRequest(photo:photo,root:root,recipe:recipe)
        let options = ExportOptions(longEdge:64,quality:1,naming:ExportNaming(prefix:"Frozen-",sequence:true,start:9,digits:3),jpegMatte:.white)
        let name = try XCTUnwrap(ExportNamingPlanner.preview(photos:[photo],options:options).first)
        let destination = folder.appendingPathComponent(name.filename)
        let snapshot = try await pipeline.freezeExport(ExportSnapshot(id:UUID().uuidString,request:job,destination:destination,
            targetBookmark:try AccessLease.bookmark(folder,readOnly:false),options:options))
        let reports = await Task { [store = catalog!] in await ExportService(pipeline:pipeline,checkpoint: { if $0 == "verified" { withUnsafeCurrentTask { $0?.cancel() } } }).run([snapshot],catalog:store) { _ in } }.value
        XCTAssertFalse(reports[0].hasPrefix("成功")); XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        XCTAssertEqual(try ExportService.logs(catalog:catalog!).first?.state,"cancelled")
        let suite = "alpha-preferences-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        var prefs = ExportPreferences(); prefs.lastOptions = options
        let id = try prefs.storePreset(name:"白底分享",options:options); try prefs.save(to:defaults)
        XCTAssertEqual(try ExportPreferences.load(from:defaults).lastOptions.jpegMatte,.white)
        XCTAssertEqual(try ExportPreferences.load(from:defaults).presets.first { $0.id == id }?.options.jpegMatte,.white)
        prefs.lastOptions.jpegMatte = .black; prefs.lastOptions.naming.prefix = "Later-"; try prefs.save(to:defaults)
        let file = catalog!.fileURL
        catalog = nil
        let reopened = try CatalogStore(fileURL:file)
        let saved = try XCTUnwrap(ExportService.logs(catalog:reopened).first)
        XCTAssertEqual(saved.snapshot.options,options)
        // A caller supplying changed options/target cannot mutate an existing task.
        let changed = ExportSnapshot(id:snapshot.id,request:job,destination:folder.appendingPathComponent("wrong.jpg"),
            targetBookmark:snapshot.targetBookmark,options:prefs.lastOptions)
        let result = await ExportService(pipeline:ImagePipeline()).run([changed],catalog:reopened) { _ in }
        XCTAssertTrue(result[0].hasPrefix("成功"),result.joined(separator:";"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:changed.destination.path))
        let output = try read(destination), pixels = floats(output)
        XCTAssertGreaterThan(pixels[0],0.95,"Recovered task must retain white matte")
        let digest = try SafeFileWriter.sha256(destination)
        let conflict = ExportSnapshot(id:UUID().uuidString,request:job,destination:destination,targetBookmark:snapshot.targetBookmark,options:prefs.lastOptions)
        let failed = await ExportService(pipeline:pipeline).run([conflict],catalog:reopened) { _ in }
        XCTAssertFalse(failed[0].hasPrefix("成功")); XCTAssertEqual(try SafeFileWriter.sha256(destination),digest)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(snapshot)) as? [String:Any])
        var oldOptions = try XCTUnwrap(legacy["options"] as? [String:Any]); oldOptions.removeValue(forKey:"jpegMatte"); legacy["options"] = oldOptions
        XCTAssertThrowsError(try JSONDecoder().decode(ExportSnapshot.self,from:JSONSerialization.data(withJSONObject:legacy)))
    }

    func testTransparentLosslessQueueCancellationReopenAndRetryFreezeSettings() async throws {
        for format in [ExportFormat.png,.tiff] {
            let source = try fixture("queue-"+format.rawValue), pipeline = ImagePipeline()
            var catalog: CatalogStore? = try CatalogStore(directory:folder.appendingPathComponent("queue-"+format.rawValue))
            let root = try catalog!.addRoot(url:folder,bookmark:source.root.bookmark)
            var photo = source.photo; photo.rootID = root.id; try catalog!.index(photo)
            var recipe = try await pipeline.baseline(source); recipe.exposure = 0.35
            let job = ImageRequest(photo:photo,root:root,recipe:recipe)
            let options = ExportOptions(format:format,longEdge:61,jpegMatte:.white)
            let destination = folder.appendingPathComponent("Frozen-"+format.rawValue+"."+format.fileExtension)
            let plan = try await pipeline.freezeExport(ExportSnapshot(id:UUID().uuidString,request:job,destination:destination,
                targetBookmark:try AccessLease.bookmark(folder,readOnly:false),options:options))
            _ = await Task { [store = catalog!] in await ExportService(pipeline:pipeline,checkpoint: { if $0 == "verified" { withUnsafeCurrentTask { $0?.cancel() } } }).run([plan],catalog:store) { _ in } }.value
            XCTAssertEqual(try ExportService.logs(catalog:catalog!).first?.state,"cancelled")
            let file = catalog!.fileURL; catalog = nil
            let reopened = try CatalogStore(fileURL:file)
            var later = recipe; later.exposure = 1.5; try reopened.saveRecipe(id:photo.id,recipe:later)
            let changed = ExportSnapshot(id:plan.id,request:request(source,later),destination:folder.appendingPathComponent("wrong-"+format.rawValue+".jpg"),
                targetBookmark:plan.targetBookmark,options:ExportOptions(longEdge:20,jpegMatte:.black))
            let reports = await ExportService(pipeline:ImagePipeline()).run([changed],catalog:reopened) { _ in }
            XCTAssertTrue(reports[0].hasPrefix("成功"),reports.joined(separator:";"))
            let saved = try XCTUnwrap(ExportService.logs(catalog:reopened).first)
            XCTAssertEqual(saved.snapshot.options,options); XCTAssertEqual(saved.snapshot.request.recipe,recipe)
            XCTAssertFalse(FileManager.default.fileExists(atPath:changed.destination.path))
            let output = try read(destination)
            let expected = try await pipeline.render(job,longEdge:61,pixelFormat:format == .tiff ? .RGBA16 : .RGBA8)
            XCTAssertTrue(try straight16(CIImage(cgImage:output)) == straight16(CIImage(cgImage:expected.image)))
            XCTAssertTrue(ImagePipeline.hasTransparency(CIImage(cgImage:output),context:context))
        }
    }

    @MainActor func testTransparentModelUndoSnapshotsBatchAndSaveReopen() async throws {
        let a = try fixture("workflow-a"), b = try fixture("workflow-b",depth:8)
        @MainActor func exercise() async throws -> (URL,StorageRoot,Photo,EditRecipe) {
            let catalog = try CatalogStore(directory:folder.appendingPathComponent("workflow"))
            let root = try catalog.addRoot(url:folder,bookmark:a.root.bookmark)
            var photos = [Photo]()
            for source in [a,b] { var photo = source.photo; photo.rootID = root.id; try catalog.index(photo); photos.append(photo) }
            let model = AppModel(); model.catalog = catalog; try model.reload(); model.editMode = true
            model.choose([photos[0].id],active:photos[0].id)
            try await wait { model.canEdit && model.previewCurrent }
            XCTAssertNil(model.rawDefaults)
            let baseline = try XCTUnwrap(model.recipe)
            model.undo.groupsByEvent = false; model.undo.beginUndoGrouping()
            model.changeRecipe({ r in
                r.exposure = 0.4; r.flipHorizontal = true; r.crop = Crop(x:0.1,y:0.1,width:0.8,height:0.8)
                r.perspective = PerspectiveSettings(horizontal:30,vertical:-20,aspect:5,constrainCrop:false)
                r.develop.blackAndWhite = true; r.develop.blackWhiteMixer = [80,-40,30,-20,50,-60,70,-30]
                r.develop.mixer[0].hue = 45; r.develop.vibrance = 30
                var group = LocalAdjustment(components:[MaskComponent(tool:.radial)]); group.exposure = 0.5
                r.schemaVersion = 3; r.maskVersion = 2; r.localAdjustments = [group]
                r.repairs = [SpotRepair(mode:.heal,points:[MaskPoint(0.65,0.5)],radius:0.2,sourceOffset:MaskPoint(0.25,0))]
            },commit:false)
            XCTAssertTrue(model.commitRecipe()); model.undo.endUndoGrouping()
            let edited = try XCTUnwrap(model.recipe)
            model.undo.undo(); XCTAssertEqual(model.recipe,baseline)
            model.undo.redo(); XCTAssertEqual(model.recipe,edited)
            XCTAssertTrue(model.saveSnapshot(name:"PNG 透明编辑"))
            let stored = try XCTUnwrap(catalog.photo(photos[0].id))
            let thumbnail = try await ThumbnailService().image(photo:stored,root:root)
            XCTAssertTrue(ImagePipeline.hasTransparency(CIImage(cgImage:thumbnail),context:context))
            XCTAssertTrue(model.applyAdjustments(source:edited,options:RecipePasteOptions(geometry:true),ids:[photos[1].id],title:"PNG 透明同步"))
            try await wait { !model.busy }; XCTAssertNil(model.error)
            let target = try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(catalog.photo(photos[1].id)?.recipe))
            XCTAssertEqual(target.exposure,edited.exposure); XCTAssertEqual(target.perspective,edited.perspective)
            XCTAssertEqual(target.crop,edited.crop); XCTAssertTrue(target.flipHorizontal); XCTAssertTrue(target.isRaster)
            XCTAssertEqual(target.develop.blackWhiteMixer,edited.develop.blackWhiteMixer)
            XCTAssertEqual(target.develop.blackWhiteMixVersion,"oklch-bw-v2")
            XCTAssertTrue(target.localAdjustments.isEmpty); XCTAssertTrue(target.repairs.isEmpty)
            XCTAssertNotEqual(target.sourceDigest,edited.sourceDigest)
            model.undo.undo(); XCTAssertNil(try catalog.photo(photos[1].id)?.recipe)
            model.undo.redo(); XCTAssertNotNil(try catalog.photo(photos[1].id)?.recipe)
            try await wait { model.previewCurrent }
            let file = catalog.fileURL
            model.choose([],active:nil); model.catalog = nil
            return (file,root,stored,edited)
        }
        let (file,root,stored,edited) = try await exercise()
        let reopened = try CatalogStore(fileURL:file)
        let photo = try XCTUnwrap(reopened.photo(stored.id))
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(photo.recipe)),edited)
        XCTAssertEqual(try reopened.snapshots(photoID:photo.id).count,1)
        XCTAssertGreaterThan(try reopened.editHistory(photoID:photo.id).count,1)
        let pipeline = ImagePipeline()
        let before = try await pipeline.render(ImageRequest(photo:stored,root:root,recipe:edited),longEdge:nil,pixelFormat:.RGBA16)
        let after = try await pipeline.render(ImageRequest(photo:photo,root:root,recipe:edited),longEdge:nil,pixelFormat:.RGBA16)
        XCTAssertTrue(try storage16(before.image) == storage16(after.image))
        XCTAssertTrue(ImagePipeline.hasTransparency(CIImage(cgImage:after.image),context:context))
        XCTAssertEqual(try SafeFileWriter.sha256(folder.appendingPathComponent(a.photo.relativePath)),edited.sourceDigest)
    }
    @MainActor func testColorZoneSamplingHistogramAndClippingRespectCoverage() async throws {
        let source = try constant("sampling") { x,_ in x < 32 ? 0 : x < 64 ? 128 : 255 }
        let catalog = try CatalogStore(directory:folder.appendingPathComponent("sampling-catalog"))
        let root = try catalog.addRoot(url:folder,bookmark:source.root.bookmark)
        var photo = source.photo; photo.rootID = root.id; try catalog.index(photo)
        let model = AppModel(); model.catalog = catalog; try model.reload()
        model.choose([photo.id],active:photo.id)
        defer { model.choose([],active:nil); model.catalog = nil }
        try await wait { model.canEdit && model.previewCurrent }
        model.addMask(.color)
        try await wait { model.maskReference != nil && model.previewCurrent && model.canvasCoordinatesCurrent }
        model.sampleMaskColor(at:MaskPoint(0.5,0.5)); model.sampleMaskColor(at:MaskPoint(0.83,0.5))
        let samples = try XCTUnwrap(model.selectedMaskComponent?.samples)
        XCTAssertEqual(samples.count,2)
        let expected = PerceptualColor.linear(SIMD3(180.0/255,100.0/255,60.0/255))
        for sample in samples {
            XCTAssertEqual(sample.red,expected.x,accuracy:0.001)
            XCTAssertEqual(sample.green,expected.y,accuracy:0.001)
            XCTAssertEqual(sample.blue,expected.z,accuracy:0.001)
        }
        model.sampleMaskColor(at:MaskPoint(0.05,0.5)); XCTAssertEqual(model.selectedMaskComponent?.samples.count,2)
        model.setMaskMode(false); model.toggleZoneSampling()
        try await wait { model.zoneReference != nil && model.canvasCoordinatesCurrent }
        model.sampleZone(at:CGPoint(x:0.05,y:0.5)); XCTAssertNil(model.sampledZoneEV)
        model.sampleZone(at:CGPoint(x:0.5,y:0.5)); let partialEV = try XCTUnwrap(model.sampledZoneEV)
        model.toggleZoneSampling(); try await wait { model.zoneReference != nil && model.canvasCoordinatesCurrent }
        model.sampleZone(at:CGPoint(x:0.83,y:0.5))
        XCTAssertEqual(try XCTUnwrap(model.sampledZoneEV),partialEV,accuracy:0.001)
        let pipeline = ImagePipeline(), recipe = try await pipeline.baseline(source)
        let image = try await pipeline.render(request(source,recipe),longEdge:nil).image
        let histogram = try XCTUnwrap(ImageHistogram.calculate(image))
        XCTAssertEqual(histogram.channels[0][0],0)
        let mass = histogram.channels[0].reduce(0,+)
        XCTAssertGreaterThan(mass,30000); XCTAssertLessThan(mass,35000)
        XCTAssertGreaterThan(histogram.channels[0][178...182].reduce(0,+),mass*0.9)
        let normal = floats(CIImage(cgImage:image)), clipped = floats(DisplayOverlay.clipping(CIImage(cgImage:image)))
        let alpha = stride(from:3,to:normal.count,by:4).map { normal[$0] }
        XCTAssertTrue(stride(from:3,to:clipped.count,by:4).map { clipped[$0] } == alpha)
    }
    /// Same production workspace/sheets in a retained native app window. An
    /// opt-in bounded hold allows pointer QA without any production debug hook.
    @MainActor func testNativeWindowLayoutAndMattePreviews() async throws {
        let directory = folder.appendingPathComponent("native-ui")
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        for depth in [8,16] {
            let width = 640, height = 400, maximum = (1 << depth)-1
            var raw = Data()
            for y in 0..<height { raw.append(0); for x in 0..<width {
                let distance = hypot(Double(x-320)/1.5,Double(y-200))
                var alpha = max(0,min(1,(140-distance)/26))
                if x > 130 && x < 215 && y > 115 && y < 285 { alpha = 0.5 }
                if x > 290 && x < 355 && y > 145 && y < 255 { alpha = 0 }
                let red = Int((0.12+0.76*Double(x)/640)*Double(maximum))
                let green = Int((0.15+0.7*Double(y)/400)*Double(maximum))
                let blue = Int((0.82-0.56*Double(x)/640)*Double(maximum))
                let values = alpha == 0 ? [maximum,0,maximum,0] : [red,green,blue,Int(alpha*Double(maximum))]
                for value in values { if depth == 16 { raw.append(UInt8(value>>8)) }; raw.append(UInt8(value&255)) }
            } }
            let header = PNGFixture.word(width)+PNGFixture.word(height)+Data([UInt8(depth),6,0,0,0])
            let data = Data([137,80,78,71,13,10,26,10])+PNGFixture.chunk("IHDR",header)
                + PNGFixture.chunk("IDAT",try PNGFixture.compress(raw))+PNGFixture.chunk("IEND",Data())
            try data.write(to:source.appendingPathComponent("Alpha-\(depth).png"))
        }
        try Data([137,80,78,71]).write(to:source.appendingPathComponent("Broken.png"))
        for name in ["copy","png","tiff","black","white"] {
            try FileManager.default.createDirectory(at:directory.appendingPathComponent(name),withIntermediateDirectories:true)
        }
        let catalog = try CatalogStore(fileURL:directory.appendingPathComponent("PNGValidation.phoscat"),create:true)
        let model = AppModel(); model.catalog = catalog; try model.reload()
        let uiSize = ProcessInfo.processInfo.environment["PHOSDECK_UI_LARGE"] == "1" ? CGSize(width:1440,height:900) : CGSize(width:1280,height:800)
        let window = NSWindow(contentRect:CGRect(origin:.zero,size:uiSize),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.title = "PNG 原生窗口验证"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.setFrame(CGRect(origin:CGPoint(x:100,y:80),size:uiSize),display:false)
        let suite = "alpha-layout-"+UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        if ProcessInfo.processInfo.environment["PHOSDECK_POINT_UI"] == "1" { defaults.set(false,forKey:"developBasicOpen"); defaults.set(true,forKey:"developPointColorOpen") }
        let workspace = NSHostingView(rootView:WorkspaceView(model:model).defaultAppStorage(defaults))
        window.contentView = workspace; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; model.choose([],active:nil); model.catalog = nil }
        let hold = min(600,max(0,Double(ProcessInfo.processInfo.environment["PHOSDECK_ALPHA_UI_SECONDS"] ?? "0") ?? 0))
        let importer = ReferenceImporter()
        let candidates = try await importer.preview(source:source,includeSubfolders:false,catalog:catalog)
        let report = await importer.add(source:source,candidates:candidates,collection:nil,catalog:catalog)
        XCTAssertEqual(report.indexed,2); XCTAssertEqual(report.errors.count,1)
        try model.reload()
        let photo = try XCTUnwrap(model.photos.first)
        model.choose([photo.id],active:photo.id); model.editMode = true
        try await wait { model.canEdit && model.previewCurrent }
        XCTAssertEqual(workspace.bounds.size,uiSize)
        if hold > 0 {
            if ProcessInfo.processInfo.environment["PHOSDECK_VERSIONS_UI"] == "1" {
                model.createVirtualCopies()
                try await wait { model.canEdit && model.previewCurrent }
                if let copy = model.active { model.renameVirtualCopy(id:copy.id,name:"暖调方案") }
            }
            model.changeRecipe {
                $0.perspective = PerspectiveSettings(horizontal:35,vertical:-25,aspect:15,constrainCrop:false)
                $0.develop.blackAndWhite = true; $0.develop.blackWhiteMixer = [60,-40,30,-20,50,-70,40,-30]
                var curve = ToneCurves(); curve.channels[0] = [CurvePoint(x:0,y:0),CurvePoint(x:0.2,y:0.12),CurvePoint(x:0.65,y:0.8),CurvePoint(x:1,y:1)]
                $0.develop.curves = curve
            }
            try await wait { model.previewCurrent }
            if ProcessInfo.processInfo.environment["PHOSDECK_POINT_UI"] == "1" {
                model.changeRecipe { $0.develop.blackAndWhite = false }
                try await wait { model.previewCurrent }
                model.togglePointColorSampling(); try await wait { model.pointReferenceReady }
                for p in [CGPoint(x:0.35,y:0.5),CGPoint(x:0.65,y:0.5),CGPoint(x:0.4,y:0.35)] where model.pointSampling { model.samplePointColor(at:p) }
                let id = try XCTUnwrap(model.recipe?.develop.pointColors.first?.id)
                model.updatePointColor(id:id,key:\.hueShift,value:45,commit:true)
                model.updatePointColor(id:id,key:\.variance,value:-35,commit:true)
                try await wait { model.previewCurrent }
            }
            if ProcessInfo.processInfo.environment["PHOSDECK_SMART_UI"] == "1" {
                XCTAssertTrue(model.saveSmartCollection(id:"ui-smart",name:"所有虚拟副本",rules:SmartRules(conditions:[SmartRule(field:.virtualCopy,op:.equal,value:"true")])))
                model.editMode = false; model.singleView = false
            }
            print("ALPHA_NATIVE_ROOT=\(directory.path)")
            let started = Date(), deadline = Date().addingTimeInterval(hold)
            var resized = false
            while window.isVisible && Date() < deadline {
                if !resized, ProcessInfo.processInfo.environment["PHOSDECK_UI_RESIZE"] == "1", Date().timeIntervalSince(started) > 60 {
                    window.setContentSize(CGSize(width:1440,height:900)); workspace.layoutSubtreeIfNeeded(); resized = true
                    print("POINT_NATIVE_SIZE=1440x900")
                }
                try await Task.sleep(for:.milliseconds(100))
            }
        } else {
            for matte in [JPEGMatte.black,.white] {
                var preferences = ExportPreferences(); preferences.lastOptions.jpegMatte = matte; try preferences.save(to:defaults)
                let sheet = NSHostingView(rootView:ExportSheet(model:model,defaults:defaults))
                window.contentView = sheet; window.setContentSize(CGSize(width:640,height:720))
                try await Task.sleep(for:.milliseconds(300)); sheet.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(sheet.bitmapImageRepForCachingDisplay(in:sheet.bounds))
                sheet.cacheDisplay(in:sheet.bounds,to:bitmap)
                let attachment = XCTAttachment(data:try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),uniformTypeIdentifier:"public.png")
                attachment.name = "PNG-JPEG-\(matte)-native-form"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        // Export the same selected recipe through the production frozen queue.
        // Attach artifacts so native-window QA does not need access to the app's container.
        XCTAssertTrue(model.commitRecipe())
        let selected = try model.exportSelection()
        for (name,format,matte) in [("png",ExportFormat.png,JPEGMatte.unselected),("tiff",ExportFormat.tiff,JPEGMatte.unselected),("black",ExportFormat.jpeg,JPEGMatte.black),("white",ExportFormat.jpeg,JPEGMatte.white)] {
            let target = directory.appendingPathComponent(name)
            let options = ExportOptions(format:format,jpegMatte:matte)
            let names = try ExportNamingPlanner.preview(photos:selected,options:options,directory:target)
            let plans = try model.prepareExport(options:options,photos:selected,names:names,directory:target)
            var frozen = [ExportSnapshot]()
            for plan in plans { frozen.append(try await model.pipeline.freezeExport(plan)) }
            let reports = await ExportService(pipeline:model.pipeline).run(frozen,catalog:catalog) { _ in }
            XCTAssertEqual(reports.filter { $0.hasPrefix("成功") }.count,selected.count,reports.joined(separator:";"))
            for snapshot in frozen {
                let image = try read(snapshot.destination)
                XCTAssertEqual(image.bitsPerComponent,format.bitDepth)
                XCTAssertEqual(ImagePipeline.hasTransparency(CIImage(cgImage:image),context:context),format != .jpeg)
                let attachment = XCTAttachment(data:try Data(contentsOf:snapshot.destination),uniformTypeIdentifier:format.type.identifier)
                attachment.name = "PNG-native-"+name+"-"+snapshot.destination.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("PNG model did not settle")
    }
}
