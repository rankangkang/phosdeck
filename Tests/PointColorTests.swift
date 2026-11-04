import XCTest
import CoreImage
import ImageIO
import GRDB
@testable import Phosdeck

final class PointColorTests:XCTestCase {
    private let linear = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAf])
    private func image(_ colors:[SIMD3<Double>],alpha:Float = 1) -> CIImage {
        let rgba = colors.flatMap { [Float($0.x)*alpha,Float($0.y)*alpha,Float($0.z)*alpha,alpha] }
        return CIImage(bitmapData:rgba.withUnsafeBytes { Data($0) },bytesPerRow:colors.count*16,size:CGSize(width:colors.count,height:1),format:.RGBAf,colorSpace:linear)
    }
    private func pixels(_ image:CIImage) -> [Float] {
        var p = [Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
        context.render(image,toBitmap:&p,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:linear); return p
    }
    private func recipe() -> EditRecipe { EditRecipe(sourceDigest:String(repeating:"a",count:64),decoderVersion:EditRecipe.rasterDecoderVersion,baselineExposure:0,baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0) }
    private func picked(_ rgb:SIMD3<Double>) -> PointColor {
        let l = PerceptualColor.lab(rgb)
        return PointColor(lightness:l.x,chroma:hypot(l.y,l.z),hue:(atan2(l.z,l.y)*180 / .pi+360).truncatingRemainder(dividingBy:360),hueShift:60,saturationShift:-35,luminanceShift:25,variance:-40,range:100)
    }
    private func references() throws -> Data {
        try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/point-color-vectors.json"))
    }
    func testIndependentUpstreamLChAndNativeRGBVectorsThenMetal() throws {
        struct Raw:Decodable { let sample:PointColor; let input:[Double]; let weight:Double; let output:[Double] }
        struct Color:Decodable { let samples:[PointColor]; let rgb:[Double]; let linear:[Double] }
        struct Reference:Decodable { let rawLCh:[Raw]; let linearSRGB:[Color] }
        let reference = try JSONDecoder().decode(Reference.self,from:references())
        XCTAssertEqual(reference.rawLCh.count,112); XCTAssertEqual(reference.linearSRGB.count,24)
        for v in reference.rawLCh {
            let input = SIMD3(v.input[0],v.input[1],v.input[2]), result = v.sample.apply(input)
            XCTAssertEqual(v.sample.weight(input),v.weight,accuracy:2e-13)
            for j in 0..<3 { XCTAssertEqual(result[j],v.output[j],accuracy:2e-13) }
        }
        var worst = 0.0
        for v in reference.linearSRGB {
            let rgb = SIMD3(v.rgb[0],v.rgb[1],v.rgb[2])
            var a = DevelopAdjustments(); a.pointColors = v.samples
            let native = PerceptualColor.linear(PerceptualColor.transform(PerceptualColor.encoded(rgb),adjustments:a))
            let gpu = pixels(try PerceptualColor.apply(image([rgb]),adjustments:a,saturation:1))
            for j in 0..<3 {
                XCTAssertEqual(native[j],v.linear[j],accuracy:2e-12)
                worst = max(worst,abs(Double(gpu[j])-v.linear[j]))
                XCTAssertEqual(Double(gpu[j]),v.linear[j],accuracy:0.000012)
            }
        }
        print("POINT_INDEPENDENT_METAL_MAX_LINEAR_ERROR=\(worst)")
    }
    func testNeutralExactBypassAlphaGrayAndOrderedOverlap() throws {
        let colors = [SIMD3<Double>(0.42,0.18,0.09),SIMD3(0.2,0.2,0.2),SIMD3(0.1,0.3,0.6)]
        let original = image(colors), expected = pixels(original)
        var a = DevelopAdjustments(); a.pointColors = [PointColor()]
        XCTAssertTrue(try PerceptualColor.apply(original,adjustments:a,saturation:1) === original)
        XCTAssertEqual(pixels(try PerceptualColor.apply(original,adjustments:a,saturation:1)),expected)
        var r = recipe(); r.develop.pointColors = a.pointColors; XCTAssertTrue(r.isUnadjustedRaster)
        let p = picked(colors[0]), q = PointColor(lightness:p.lightness,chroma:p.chroma,hue:p.hue,saturationShift:70,luminanceShift:-40,variance:70,range:100)
        let lab = PerceptualColor.lab(colors[0]), lch = SIMD3(lab.x,hypot(lab.y,lab.z),atan2(lab.z,lab.y))
        XCTAssertGreaterThan(simdLength(p.apply(q.apply(lch))-q.apply(p.apply(lch))),0.001)
        XCTAssertEqual(p.weight(SIMD3(0.6,0,0)),0)
        let gray = PointColor(lightness:0.6,chroma:0.001,hue:180,luminanceShift:50)
        XCTAssertEqual(gray.weight(SIMD3(0.6,0.001,0)),gray.weight(SIMD3(0.6,0.001,.pi)),accuracy:1e-15)
        a.pointColors = [p,q]
        for alpha in [Float(0),Float(1)/65535,Float(0.5),Float(1)] {
            let result = pixels(try PerceptualColor.apply(image(colors,alpha:alpha),adjustments:a,saturation:1))
            for i in colors.indices { XCTAssertEqual(result[i*4+3],alpha,accuracy:1e-7) }
            XCTAssertTrue(result.allSatisfy(\.isFinite))
        }
        let invalidPixels = image([SIMD3(.infinity,0.2,.nan)],alpha:1)
        XCTAssertTrue(pixels(try PerceptualColor.apply(invalidPixels,adjustments:a,saturation:1)).allSatisfy(\.isFinite))
        a.blackAndWhite = true
        let withPoints = pixels(try PerceptualColor.apply(original,adjustments:a,saturation:1))
        a.pointColors = []
        XCTAssertEqual(withPoints,pixels(try PerceptualColor.apply(original,adjustments:a,saturation:1)))
    }
    private func simdLength(_ v:SIMD3<Double>) -> Double { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
    func testValidationColorGroupAndIdentityAwarePresetStrength() throws {
        var r = recipe(), sample = picked(SIMD3(0.42,0.18,0.09)); r.develop.pointColors = [sample]
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:JSONEncoder().encode(r)),r)
        for invalid in [Double.nan,Double.infinity,101] { sample.hueShift = invalid; XCTAssertThrowsError(try sample.validate()) }
        sample = r.develop.pointColors[0]
        var bad = r; bad.develop.pointColors = Array(repeating:sample,count:9); XCTAssertThrowsError(try bad.validate())
        bad = r; bad.develop.pointColorVersion = "unsupported"; XCTAssertThrowsError(try bad.validate())
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(r.develop)) as? [String:Any])
        data.removeValue(forKey:"pointColors"); XCTAssertThrowsError(try JSONDecoder().decode(DevelopAdjustments.self,from:JSONSerialization.data(withJSONObject:data)))
        let base = recipe()
        XCTAssertEqual(try base.pasting(r,options:RecipePasteOptions()).develop.pointColors,[sample])
        XCTAssertTrue(try base.pasting(r,options:RecipePasteOptions(color:false)).develop.pointColors.isEmpty)
        XCTAssertEqual(try base.applyingPreset(r,options:RecipePasteOptions(),amount:0.25).develop.pointColors[0].hueShift,15)
        var related = sample; related.hueShift = -60
        XCTAssertEqual(PointColor.mixing([sample],[related],amount:0.5)[0].hueShift,0)
        var unrelated = related; unrelated.id = UUID(); unrelated.hue = 220
        XCTAssertEqual(PointColor.mixing([sample],[unrelated],amount:0.49),[sample])
        XCTAssertEqual(PointColor.mixing([sample],[unrelated],amount:0.5),[unrelated])
        var local = LocalDevelopSettings(); local.develop.pointColors = [sample]; XCTAssertThrowsError(try local.validate())
        r.pipelineVersion = 1; XCTAssertThrowsError(try r.validate())
    }
    func testFloatSamplingTransparentCenterNearGrayAndSoftEdges() throws {
        let rgb = SIMD3<Double>(0.42,0.18,0.09)
        let ref = PointColorReference(width:3,height:3,rgba:Array(repeating:[Float(rgb.x)*0.5,Float(rgb.y)*0.5,Float(rgb.z)*0.5,0.5],count:9).flatMap{$0})
        let sample = try XCTUnwrap(ref.sample(at:CGPoint(x:0.5,y:0.5))), lab = PerceptualColor.lab(rgb)
        XCTAssertEqual(sample.lightness,lab.x,accuracy:1e-7)
        var transparent = ref.rgba; transparent[4*4+3] = 0
        XCTAssertNil(PointColorReference(width:3,height:3,rgba:transparent).sample(at:CGPoint(x:0.5,y:0.5)))
        transparent = ref.rgba; transparent[0] = .infinity
        XCTAssertNotNil(PointColorReference(width:3,height:3,rgba:transparent).sample(at:CGPoint(x:0.5,y:0.5)),"Invalid neighbors are skipped")
        transparent = ref.rgba; transparent[4*4] = .infinity
        XCTAssertNil(PointColorReference(width:3,height:3,rgba:transparent).sample(at:CGPoint(x:0.5,y:0.5)),"Invalid center is not replaced by valid neighbors")
        let gray = try XCTUnwrap(PointColorReference(width:1,height:1,rgba:[0.2,0.2,0.2,1]).sample(at:.zero))
        XCTAssertEqual(gray.hue,0); XCTAssertEqual(gray.chroma,0)
        let point = picked(rgb), w = point.widths
        let center = SIMD3(point.lightness,point.chroma,point.hue * .pi/180)
        XCTAssertEqual(point.weight(center),1,accuracy:1e-12)
        XCTAssertEqual(point.weight(center+SIMD3(w.z,0,0)),0,accuracy:1e-12)
        let middle = point.weight(center+SIMD3(w.z*0.75,0,0)); XCTAssertGreaterThan(middle,0); XCTAssertLessThan(middle,1)
        XCTAssertEqual(point.weight(SIMD3(.nan,0.1,0)),0)
    }
    func testSamplingPrefixGeometryAndDisplayRangeDoNotAffectOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:folder) }
        let file = folder.appendingPathComponent("sample.png"); try PNGFixture.data(depth:16).write(to:file)
        let source = try PNGFixture.request(file), pipeline = ImagePipeline()
        var r = try await pipeline.baseline(source)
        r.quarterTurns = 1; r.crop = Crop(x:0.1,y:0.1,width:0.8,height:0.8); r.flipHorizontal = true; r.flipVertical = true
        r.straightenDegrees = 5; r.perspective = PerspectiveSettings(horizontal:15,vertical:-12,aspect:5,constrainCrop:true)
        r.develop.mixer[0].hue = 50
        func request(_ recipe:EditRecipe) -> ImageRequest { ImageRequest(photo:source.photo,root:source.root,recipe:recipe) }
        let before = try await pipeline.pointColorReference(request(r))
        let chosen = try XCTUnwrap(before.sample(at:CGPoint(x:0.5,y:0.5)))
        r.develop.pointColors = [chosen]; r.develop.pointColors[0].hueShift = 80
        r.develop.vibrance = 100; r.saturation = 0.4; r.develop.grading.global.saturation = 80
        r.localAdjustments = [LocalAdjustment(components:[MaskComponent(tool:.radial)],exposure:1)]
        r.schemaVersion = 3; r.maskVersion = 2
        r.vignette.amount = -40; r.grain.amount = 30; r.grain.ensureSeed()
        let after = try await pipeline.pointColorReference(request(r))
        XCTAssertEqual(before.width,after.width); XCTAssertEqual(before.height,after.height)
        XCTAssertEqual(before.rgba,after.rgba,"No own adjustment, grading, local effects or finish enters sampling")
        let output = try await pipeline.render(request(r),longEdge:nil,pixelFormat:.RGBA16)
        let range = try await pipeline.pointColorRange(after,samples:r.develop.pointColors,selected:chosen.id)
        XCTAssertNotNil(range)
        let again = try await pipeline.render(request(r),longEdge:nil,pixelFormat:.RGBA16)
        XCTAssertEqual(output.image.dataProvider?.data as Data?,again.image.dataProvider?.data as Data?)
        r.develop.blackAndWhite = true
        let bwReference = try await pipeline.pointColorReference(request(r))
        XCTAssertEqual(bwReference.rgba,before.rgba)
    }
}

extension PointColorTests {
    @MainActor private func wait(_ predicate:() -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("异步工作流未在 5 秒内完成")
    }
    @MainActor func testCopiesSmartRulesPointEditsSnapshotsUndoAndFrozenExportTogether() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url:f.source,bookmark:AccessLease.bookmark(f.source,readOnly:true))
        let file = f.source.appendingPathComponent("shared.png"); try PNGFixture.data(depth:16).write(to:file)
        let original = try ReferenceImporter.inspect(url:file,root:root,rootURL:f.source); try f.catalog.index(original)
        let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(ImageRequest(photo:original,root:root,recipe:nil))
        try f.catalog.saveRecipe(id:original.id,recipe:baseline)
        let copies = try f.catalog.createVirtualCopies(ids:[original.id])+f.catalog.createVirtualCopies(ids:[original.id])
        let rules = SmartRules(conditions:[SmartRule(field:.virtualCopy,op:.equal,value:"true"),SmartRule(field:.copyName,op:.contains,value:"副本")])
        let collection = try PhotoCollection(id:"versions",name:"副本",rules:JSONEncoder().encode(rules))
        _ = try f.catalog.replaceSmartCollection(id:collection.id,with:collection)
        XCTAssertEqual(try f.catalog.members("versions").count,2)
        let model = AppModel(); model.catalog = f.catalog; try model.reload(); model.editMode = true
        model.choose([copies[0].id],active:copies[0].id); try await wait { model.canEdit && model.previewCurrent }
        model.togglePointColorSampling(); try await wait { model.pointReferenceReady }
        let reference = try XCTUnwrap(model.pointReference)
        let positions = (0..<reference.height).lazy.flatMap { y -> [CGPoint] in
            (0..<reference.width).map { x -> CGPoint in
                let px = (Double(x) + 0.5) / Double(reference.width)
                let py = (Double(y) + 0.5) / Double(reference.height)
                return CGPoint(x: px, y: py)
            }
        }
        let point = try XCTUnwrap(positions.first { reference.sample(at: $0) != nil })
        model.undo.groupsByEvent = false; model.undo.beginUndoGrouping()
        model.samplePointColor(at:point); model.undo.endUndoGrouping()
        let id = try XCTUnwrap(model.recipe?.develop.pointColors.first?.id)
        let historyCount = try f.catalog.editHistory(photoID:copies[0].id).count
        model.undo.beginUndoGrouping()
        model.updatePointColor(id:id,key:\.hueShift,value:15,commit:false)
        model.updatePointColor(id:id,key:\.hueShift,value:65,commit:false)
        XCTAssertTrue(model.commitRecipe()); model.undo.endUndoGrouping()
        XCTAssertEqual(try f.catalog.editHistory(photoID:copies[0].id).count,historyCount+1,"Drag creates one saved step")
        model.undo.undo(); XCTAssertEqual(model.recipe?.develop.pointColors.first?.hueShift,0)
        model.undo.redo(); XCTAssertEqual(model.recipe?.develop.pointColors.first?.hueShift,65)
        model.selectedPointColorID = nil; model.before = true
        model.showPointColorRange = true
        XCTAssertEqual(model.selectedPointColorID,id,"A mounted panel must resolve a restored sample before rendering its range")
        XCTAssertFalse(model.before); XCTAssertEqual(model.beforeAfter,.off)
        try await wait { model.pointRangeImage != nil }
        model.showPointColorRange = false
        XCTAssertTrue(model.saveSnapshot(name:"副本点颜色"))
        let first = try XCTUnwrap(model.recipe)
        var second = first; second.develop.pointColors[0].hueShift = -70; second.develop.pointColors[0].luminanceShift = 30
        try f.catalog.saveRecipe(id:copies[1].id,recipe:second)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(f.catalog.photo(copies[0].id)?.recipe)),first)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(f.catalog.photo(original.id)?.recipe)),baseline)
        XCTAssertTrue(try f.catalog.snapshots(photoID:copies[1].id).isEmpty)
        // Mirror the production batch path after the direct fixture write.
        try model.reload()
        model.choose([copies[1].id],active:copies[1].id); try await wait { model.canEdit && model.previewCurrent }
        XCTAssertNil(model.selectedPointColorID)
        model.showPointColorRange = true
        try await wait { model.pointRangeImage != nil }
        XCTAssertEqual(model.selectedPointColorID,second.develop.pointColors.first?.id)
        model.cancelPointColorTools()
        let one = try XCTUnwrap(f.catalog.photo(copies[0].id)), two = try XCTUnwrap(f.catalog.photo(copies[1].id))
        let thumbs = ThumbnailService()
        let thumbA = try await thumbs.image(photo:one,root:root), thumbB = try await thumbs.image(photo:two,root:root)
        XCTAssertNotEqual(pixels(CIImage(cgImage:thumbA)),pixels(CIImage(cgImage:thumbB)))
        model.selection = Set(copies.map(\.id)); model.scope = "all"
        let photos = try model.exportSelection(), options = ExportOptions(format:.tiff)
        let names = try ExportNamingPlanner.preview(photos:photos,options:options,directory:f.target)
        let plans = try model.prepareExport(options:options,photos:photos,names:names,directory:f.target)
        var frozen = [ExportSnapshot]()
        for plan in plans { frozen.append(try await pipeline.freezeExport(plan)) }
        _ = try f.catalog.renameVersion(id:copies[0].id,name:"之后改名")
        _ = try f.catalog.setVersionDeletion([original.id:true,copies[1].id:true])
        XCTAssertTrue(try f.catalog.members("versions").isEmpty)
        let reports = await ExportService(pipeline:pipeline).run(frozen,catalog:f.catalog,progress:{_ in})
        XCTAssertEqual(reports.filter{$0.hasPrefix("成功")}.count,2,"\(reports)")
        XCTAssertTrue(frozen.allSatisfy{FileManager.default.fileExists(atPath:$0.destination.path)})
        let backup = f.target.appendingPathComponent("all.sqlite"); try f.catalog.backup(to:backup)
        let restored = try CatalogStore.restore(from:backup,to:f.target.appendingPathComponent("restore"))
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(restored.photo(copies[0].id)?.recipe)),first)
        XCTAssertEqual(try restored.snapshots(photoID:copies[0].id).count,1)
        model.cancelPointColorTools(); model.choose([],active:nil); model.catalog = nil
    }
    @MainActor func testLatePreviewAndThumbnailCannotCrossSharedSourceVersions() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url:f.source,bookmark:AccessLease.bookmark(f.source,readOnly:true))
        let file = f.source.appendingPathComponent("same.jpg"); try f.image(file)
        let original = try ReferenceImporter.inspect(url:file,root:root,rootURL:f.source); try f.catalog.index(original)
        let baseline = try await ImagePipeline().baseline(ImageRequest(photo:original,root:root,recipe:nil)); try f.catalog.saveRecipe(id:original.id,recipe:baseline)
        let copy = try XCTUnwrap(f.catalog.createVirtualCopies(ids:[original.id]).first)
        let red = try XCTUnwrap(context.createCGImage(image([SIMD3(0.8,0,0)]),from:CGRect(x:0,y:0,width:1,height:1)))
        let blue = try XCTUnwrap(context.createCGImage(image([SIMD3(0,0,0.8)]),from:CGRect(x:0,y:0,width:1,height:1)))
        var began = false
        let model = AppModel(previewRenderer:{ request,_,_ in
            let first = request.photo.id == original.id
            if first { began = true; try? await Task.sleep(for:.milliseconds(140)) }
            return RenderedImage(image:first ? red : blue,fullSize:CGSize(width:1,height:1),orientedSourceSize:CGSize(width:20,height:10),histogram:nil,elapsed:0)
        })
        model.catalog = f.catalog; try model.reload(); model.choose([original.id],active:original.id)
        try await wait { began }
        model.choose([copy.id],active:copy.id); try await wait { model.previewCurrent && model.image === blue }
        try await Task.sleep(for:.milliseconds(180)); XCTAssertTrue(model.image === blue)
        XCTAssertEqual(model.activeID,copy.id)
        let service = ThumbnailService { request,_ in
            if request.photo.id == original.id { try? await Task.sleep(for:.milliseconds(140)); return red }
            return blue
        }
        let item = PhotoItem(); _ = item.view
        item.configure(photo:try XCTUnwrap(f.catalog.photo(original.id)),root:root,service:service,film:false)
        try await Task.sleep(for:.milliseconds(30))
        item.configure(photo:copy,root:root,service:service,film:false)
        try await wait { item.displayedImage != nil }; try await Task.sleep(for:.milliseconds(180))
        let displayed = pixels(CIImage(cgImage:try XCTUnwrap(item.displayedImage?.cgImage(forProposedRect:nil,context:nil,hints:nil))))
        XCTAssertGreaterThan(displayed[2],displayed[0]+0.5,"The late original must not replace the copy thumbnail")
        item.prepareForReuse(); model.choose([],active:nil); model.catalog = nil
    }
    func testPublicRAWJPEGPNGAndTIFFPointColorQualityExports() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:folder) }
        let png = folder.appendingPathComponent("alpha16.png"); try PNGFixture.data(depth:16).write(to:png)
        let tiff = folder.appendingPathComponent("alpha16.tif")
        try context.writeTIFFRepresentation(of:try XCTUnwrap(CIImage(contentsOf:png)),to:tiff,format:.RGBA16,colorSpace:ImagePipeline.outputSpace,options:[:])
        let jpeg = folder.appendingPathComponent("opaque.jpg"); try ImportTests().image(jpeg)
        let sources = [try MoreRAWTests.request("a7iii_12bit_compressed.ARW"),try PNGFixture.request(png),try PNGFixture.request(tiff),try PNGFixture.request(jpeg)]
        let pipeline = ImagePipeline()
        for (i,source) in sources.enumerated() {
            var recipe = try await pipeline.baseline(source)
            let reference = try await pipeline.pointColorReference(ImageRequest(photo:source.photo,root:source.root,recipe:recipe),longEdge:96)
            let positions = (0..<reference.height).lazy.flatMap { y -> [CGPoint] in
                (0..<reference.width).map { x -> CGPoint in
                    let px = (Double(x) + 0.5) / Double(reference.width)
                    let py = (Double(y) + 0.5) / Double(reference.height)
                    return CGPoint(x: px, y: py)
                }
            }
            let sample = try XCTUnwrap(positions.compactMap { reference.sample(at: $0) }.first)
            recipe.develop.pointColors = [sample]; recipe.develop.pointColors[0].luminanceShift = 35; recipe.develop.pointColors[0].variance = -40
            let request = ImageRequest(photo:source.photo,root:source.root,recipe:recipe)
            let quality = try await pipeline.render(request,longEdge:64,pixelFormat:.RGBA16)
            if i == 0 {
                let full = try await pipeline.render(request,longEdge:nil,reuseDecoded:true)
                XCTAssertGreaterThan(full.image.width,1000)
                let bytes = await pipeline.qualityCacheBytes
                XCTAssertEqual(bytes,0,"New per-pixel point colour must retain the uncached quality graph")
            }
            for (j,format) in [ExportFormat.png,.tiff,.jpeg].enumerated() {
                let file = folder.appendingPathComponent("output-\(i)-\(j)."+format.fileExtension)
                let options = ExportOptions(format:format,longEdge:64,jpegMatte:.white)
                _ = try await pipeline.export(request,staging:file,options:options)
                let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL,nil)), output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
                XCTAssertEqual(output.width,quality.image.width); XCTAssertEqual(output.height,quality.image.height)
                if format == .tiff { XCTAssertEqual(output.bitsPerComponent,16) }
                if (i == 1 || i == 2) && format != .jpeg { XCTAssertTrue(ImagePipeline.hasTransparency(CIImage(cgImage:output),context:context)) }
                if format == .jpeg { XCTAssertFalse(ImagePipeline.hasTransparency(CIImage(cgImage:output),context:context)) }
                if format == .tiff {
                    let expected = pixels(CIImage(cgImage:quality.image)), actual = pixels(CIImage(cgImage:output))
                    XCTAssertEqual(expected.count,actual.count)
                    XCTAssertLessThanOrEqual(zip(expected,actual).map{abs($0-$1)}.max() ?? .infinity,4/65535)
                }
            }
        }
    }
}

extension PointColorTests {
    func testActivePointPreservesNativeHSLVibranceGradingOrderAndPerformance() throws {
        let colors = [SIMD3<Double>(0.42,0.18,0.09),SIMD3(0.1,0.3,0.6),SIMD3(0.6,0.3,0.1),SIMD3(0.2,0.2,0.2)]
        var a = DevelopAdjustments()
        for i in 0..<8 { a.mixer[i] = HSLBand(hue:Double(i*9-28),saturation:Double(40-i*11),luminance:Double(i*6-24)) }
        let lab = PerceptualColor.mixerLab(colors[0],adjustments:a)
        a.pointColors = [PointColor(lightness:lab.x,chroma:hypot(lab.y,lab.z),hue:(atan2(lab.z,lab.y)*180 / .pi+360).truncatingRemainder(dividingBy:360),hueShift:35,saturationShift:-40,luminanceShift:30,variance:-60,range:100)]
        a.vibrance = -25; a.grading.shadows = GradingTone(hue:220,saturation:35,luminance:-12)
        a.grading.global = GradingTone(hue:46,saturation:20,luminance:8); a.grading.balance = -20; a.grading.blending = 64
        let actual = pixels(try PerceptualColor.apply(image(colors),adjustments:a,saturation:1.25))
        for (i,c) in colors.enumerated() {
            let expected = PerceptualColor.linear(PerceptualColor.transform(PerceptualColor.encoded(c),adjustments:a,saturation:1.25))
            for j in 0..<3 { XCTAssertEqual(Double(actual[4*i+j]),expected[j],accuracy:0.000015) }
        }
        // Cold graph compilation is above; measure a materialized 1 MP, eight-point
        // colour stage with real readback, without decode or unrelated spatial work.
        let sample = a.pointColors[0]
        a.pointColors = (0..<8).map { i in var p = sample; p.id = UUID(); p.hueShift += Double(i); return p }
        let large = CIImage(color:CIColor(red:0.42,green:0.18,blue:0.09)).cropped(to:CGRect(x:0,y:0,width:1024,height:1024))
        let start = Date()
        let result = pixels(try PerceptualColor.apply(large,adjustments:a,saturation:1.25))
        XCTAssertEqual(result.count,1024*1024*4); XCTAssertTrue(result.allSatisfy(\.isFinite))
        print("POINT_EIGHT_1MP_MATERIALIZE_SECONDS=\(Date().timeIntervalSince(start))")
    }
}
