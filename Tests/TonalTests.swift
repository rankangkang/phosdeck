import XCTest
import CoreImage
import SwiftUI
@testable import Phosdeck

final class TonalTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
    private func image(_ values: [SIMD4<Float>]) -> CIImage {
        values.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: values.count*16,
            size: CGSize(width: values.count, height: 1), format: .RGBAf, colorSpace: linear) }
    }
    private func pixels(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        context.render(image, toBitmap: &values, rowBytes: Int(image.extent.width)*16, bounds: image.extent, format: .RGBAf, colorSpace: linear)
        return values
    }
    func testCurvesGPUIdentityChannelsLuminanceAndBlackLift() throws {
        func decode(_ x: Double) -> Double { x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
        let ramp = image((0...256).map { let x = Float(decode(Double($0)/256)); return SIMD4(x,x,x,1) })
        XCTAssertEqual(pixels(try TonalPipeline.curves(ramp, ToneCurves())), pixels(ramp))
        var c = ToneCurves(); c.channels[1] = zip(ToneCurves.grid, [0.05,0.12,0.65,0.9,1]).map { CurvePoint(x: $0, y: $1) }
        let actual = pixels(try TonalPipeline.curves(ramp,c)), original = pixels(ramp)
        for i in 0...256 {
            XCTAssertEqual(Double(actual[i*4]), decode(TonalPipeline.evaluate(c.channels[1], at: Double(i)/256)), accuracy: 0.00003)
            XCTAssertEqual(actual[i*4+1], original[i*4+1], accuracy: 0.000001)
            XCTAssertEqual(actual[i*4+2], original[i*4+2], accuracy: 0.000001)
        }
        c = ToneCurves(); c.channels[0] = zip(ToneCurves.grid, [0.1,0.32,0.62,0.84,1]).map { CurvePoint(x: $0, y: $1) }
        let color = image([SIMD4(0.12,0.06,0.03,0.5), SIMD4(0,0,0,1)])
        let result = pixels(try TonalPipeline.curves(color,c))
        XCTAssertEqual(result[0]/result[1],2,accuracy:0.00001)
        XCTAssertEqual(result[1]/result[2],2,accuracy:0.00001)
        XCTAssertEqual(result[3],0.5)
        XCTAssertEqual(Double(result[4]),decode(0.1),accuracy:0.00001)
        XCTAssertEqual(result[4],result[5]); XCTAssertEqual(result[5],result[6])
        // Inactive channels retain extended values, even when another channel changes.
        c = ToneCurves(); c.channels[1][2].y = 0.7
        let extended = pixels(try TonalPipeline.curves(image([SIMD4(0.2,-0.1,1.4,1)]),c))
        XCTAssertEqual(extended[1],-0.1,accuracy:0.00001); XCTAssertEqual(extended[2],1.4,accuracy:0.00001)
    }
    func testZoneExposureMonotonicAndPreservesColorAndAlpha() throws {
        let evs = (0...256).map { -10 + Double($0)/256*12 }
        let source = image(evs.map { let x = Float(exp2($0)); return SIMD4(x,x*0.5,x*0.25,0.5) })
        let guide = image(evs.map { SIMD4(repeating: Float($0)) })
        // All extreme gain combinations: never reverse brightness or exceed ±1 EV.
        for bits in 0..<32 {
            let zones = ToneZones(gains: (0..<5).map { bits & (1 << $0) == 0 ? -1 : 1 })
            let g = zones.gains
            let result = pixels(try SpatialDevelopPipeline.run("zoneExposure", extent: source.extent,
                [source,guide,CIVector(x:g[0],y:g[1],z:g[2],w:g[3]),g[4]]))
            var previous = -Double.infinity
            for (i,ev) in evs.enumerated() {
                let gain = zones.gain(at:ev), output = ev+gain
                XCTAssertGreaterThanOrEqual(output+0.0000001,previous); previous = output
                XCTAssertLessThanOrEqual(abs(gain),1.000001)
                XCTAssertEqual(Double(result[i*4])/exp2(ev),exp2(gain),accuracy:0.00002)
                XCTAssertEqual(result[i*4]/result[i*4+1],2,accuracy:0.00001)
                XCTAssertEqual(result[i*4+3],0.5)
            }
        }
        let constant = image(Array(repeating: SIMD4<Float>(0.0625,0.0625,0.0625,1),count:32))
        let result = pixels(try TonalPipeline.zones(constant,ToneZones(gains:[0,0,1,0,0])))
        XCTAssertEqual(result[16*4],0.125,accuracy:0.00005)
        let guideImage = try TonalPipeline.zoneGuide(constant)
        let raster = try XCTUnwrap(context.createCGImage(guideImage,from:guideImage.extent,format:.RGBAf,colorSpace:linear))
        XCTAssertEqual(pixels(CIImage(cgImage:raster))[16*4],-4,accuracy:0.0001,"Signed EV survives CGImage sampling")
    }
    func testTonalValidationRoundTripAndSelectivePaste() throws {
        var source = EditRecipe(sourceDigest:String(repeating:"a",count:64),decoderVersion:"test",
            baselineExposure:0,baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
        source.develop.curves = ToneCurves(); source.develop.curves?.channels[0][2].y = 0.65
        source.develop.zones = ToneZones(gains:[0,0.25,0.75,-0.25,0])
        let decoded = try JSONDecoder().decode(EditRecipe.self,from:JSONEncoder().encode(source))
        XCTAssertEqual(source,decoded)
        let baseline = source.baseline()
        let pasted = try baseline.pasting(source,options:RecipePasteOptions(tone:false,whiteBalance:false,color:false,curves:true,zones:false))
        XCTAssertEqual(pasted.develop.curves,source.develop.curves); XCTAssertNil(pasted.develop.zones)
        XCTAssertFalse(RecipePasteOptions(tone:false,whiteBalance:false,color:false,curves:false,zones:false).hasSelection)
        var bad = source
        bad.develop.curves?.channels.removeLast(); XCTAssertThrowsError(try bad.validate())
        bad = source; bad.develop.curves?.channels[0][0].y = .nan; XCTAssertThrowsError(try bad.validate())
        bad = source; bad.develop.zones?.gains[2] = 1.1; XCTAssertThrowsError(try bad.validate())
        // Deliberately non-monotone curves must stay inside each segment's endpoints.
        let points:[Double] = [0.1,0.9,0.2,0.7,0.3]
        for i in 0..<400 {
            let j = i/100, value = TonalPipeline.interpolate(points,at:Double(i)/100)
            XCTAssertGreaterThanOrEqual(value,min(points[j],points[j+1])-1e-12)
            XCTAssertLessThanOrEqual(value,max(points[j],points[j+1])+1e-12)
        }
    }
    @MainActor func testNativeTonalPanelAndSamplerState() async throws {
        let suite = "tonal-layout-"+UUID().uuidString
        // A dedicated suite prevents the layout check from changing real panel preferences.
        let settings = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { settings.removePersistentDomain(forName:suite) }
        for key in ["developBasicOpen","developMixerOpen","developGradingOpen","developDetailsOpen","developSoloMode", "developBlackWhiteMixerOpen"] { settings.set(false,forKey:key) }
        settings.set(true,forKey:"developCurvesOpen"); settings.set(true,forKey:"developZonesOpen")
        let model = AppModel(); model.canEdit = true
        model.recipe = EditRecipe(sourceDigest:String(repeating:"a",count:64),decoderVersion:"test",baselineExposure:0,baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
        let host = NSHostingView(rootView:DevelopPanel(model:model).defaultAppStorage(settings)
            .font(.system(size:12)).buttonStyle(.borderless).controlSize(.small).background(Theme.panel).preferredColorScheme(.dark))
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:300,height:780),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = host
        defer { window.contentView = nil }
        func sliders(_ view:NSView)->[AdjustmentNSSlider] { (view as? AdjustmentNSSlider).map { [$0] } ?? view.subviews.flatMap(sliders) }
        for _ in 0..<100 { if sliders(host).count == 7 { break }; try await Task.sleep(for:.milliseconds(15)) }
        XCTAssertEqual(sliders(host).count,7)
        host.layoutSubtreeIfNeeded()
        let middle = try XCTUnwrap(sliders(host).first { $0.accessibilityLabel() == "中间调" })
        XCTAssertGreaterThan(middle.visibleRect.width,40)
        middle.doubleValue = 0.45; middle.sendAction(middle.action,to:middle.target)
        XCTAssertEqual(try XCTUnwrap(model.recipe?.develop.zones?.gains[2]),0.45,accuracy:0.000001)
        let curve = try XCTUnwrap(sliders(host).first { $0.accessibilityLabel() == "输出 %" })
        curve.doubleValue = 65; curve.sendAction(curve.action,to:curve.target)
        XCTAssertEqual(model.recipe?.develop.curves?.channels[0][2].y,0.65)
        model.zoneSampling = true
        model.orientedSourceSize = CGSize(width: 2, height: 1)
        model.zoneReference = try XCTUnwrap(context.createCGImage(image([SIMD4(-6,-6,-6,1),SIMD4(-2,-2,-2,1)]),from:CGRect(x:0,y:0,width:2,height:1),format:.RGBAf,colorSpace:linear))
        model.sampleZone(at:CGPoint(x:-0.1,y:0.5)); XCTAssertTrue(model.zoneSampling)
        model.sampleZone(at:CGPoint(x:0.1,y:0.5)); XCTAssertEqual(model.selectedZone,1); XCTAssertEqual(model.sampledZoneEV!,-6,accuracy:0.0001)
        XCTAssertFalse(model.zoneSampling); XCTAssertNil(model.zoneReference)
        model.zoneSampling = true; model.before = true; XCTAssertFalse(model.zoneSampling)
        model.zoneSampling = true; model.recipe?.exposure = 1; XCTAssertFalse(model.zoneSampling)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds)); host.cacheDisplay(in:host.bounds,to:bitmap)
        let attachment = XCTAttachment(data:try XCTUnwrap(bitmap.representation(using:.png,properties:[:])),uniformTypeIdentifier:"public.png")
        attachment.name = "tonal-panel"; attachment.lifetime = .keepAlways; add(attachment)
        // The picker uses the actual fitted/zoomed image rect and does not trigger zoom.
        let canvas = PhotoMetalCanvas(); window.contentView = canvas
        let cg = try XCTUnwrap(context.createCGImage(image([SIMD4(0.2,0.2,0.2,1)]),from:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:linear))
        canvas.source = cg; canvas.nativeSize = CGSize(width:800,height:500)
        var picked: CGPoint?, clicks = 0
        canvas.onZoneSample = { picked = $0 }; canvas.onClick = { _ in clicks += 1 }
        canvas.layoutSubtreeIfNeeded()
        for zoomed in [false,true] {
            canvas.actualPixels = zoomed
            let displayed = canvas.presentationSize(source:cg,canvas:canvas.drawableSize)
            let local = CGPoint(x:(canvas.drawableSize.width/2 - displayed.width*0.2)/window.backingScaleFactor,
                                y:(canvas.drawableSize.height/2 + displayed.height*0.2)/window.backingScaleFactor)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(local,to:nil),modifierFlags:[],timestamp:0,
                    windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
                if type == .leftMouseDown { canvas.mouseDown(with:event) } else { canvas.mouseUp(with:event) }
            }
            XCTAssertEqual(try XCTUnwrap(picked).x,0.3,accuracy:0.00001)
            XCTAssertEqual(try XCTUnwrap(picked).y,0.7,accuracy:0.00001)
            XCTAssertTrue(canvas.accessibilityPerformPress())
            XCTAssertEqual(try XCTUnwrap(picked).x,0.5,accuracy:0.00001)
            XCTAssertEqual(try XCTUnwrap(picked).y,0.5,accuracy:0.00001)
        }
        XCTAssertEqual(clicks,0)
    }
}
