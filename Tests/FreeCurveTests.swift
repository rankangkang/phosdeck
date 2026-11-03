import XCTest
import AppKit
import CoreImage
@testable import Phosdeck

final class FreeCurveTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private func points(_ values: [(Double, Double)]) -> [CurvePoint] { values.map { CurvePoint(x:$0.0,y:$0.1) } }
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest:String(repeating:"a",count:64),decoderVersion:"test",baselineExposure:0,
            baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
    }
    func testPointRulesRejectMalformedPayloadAndBoundInteractiveEdits() throws {
        var c = ToneCurves()
        XCTAssertEqual(c.insert(channel:0,x:0.5,y:0.9),2)
        XCTAssertEqual(c.channels[0][2].y,0.5,"Duplicate input does not replace the existing output")
        XCTAssertNil(c.insert(channel:0,x:.nan,y:0.2))
        XCTAssertNil(c.insert(channel:0,x:0.3,y:.infinity))
        c.move(channel:0,point:2,x:1,y:2)
        XCTAssertEqual(c.channels[0][2].x,0.749,accuracy:1e-12); XCTAssertEqual(c.channels[0][2].y,1)
        c.move(channel:0,point:0,x:0.4,y:0.1); c.move(channel:0,point:4,x:0.4,y:0.9)
        XCTAssertEqual(c.channels[0].first?.x,0); XCTAssertEqual(c.channels[0].last?.x,1)
        XCTAssertFalse(c.remove(channel:0,point:0)); XCTAssertFalse(c.remove(channel:0,point:4))
        XCTAssertTrue(c.remove(channel:0,point:2)); try c.validate()
        c.channels[0] = points([(0,0),(1,1)])
        for i in 1...14 { XCTAssertNotNil(c.insert(channel:0,x:Double(i)/15,y:0.5)) }
        XCTAssertNil(c.insert(channel:0,x:0.95,y:0.5)); try c.validate()
        for invalid in [points([(0,0),(0.5,0.3),(0.5,0.8),(1,1)]), points([(0,0),(0.4,0.3),(0.2,0.8),(1,1)]),
                        points([(0.1,0),(1,1)]), points([(0,0),(1,1.01)]), points([(0,0),(.infinity,1)]),
                        points([(0,0),(0.0001,0.2),(1,1)]), points([(0,0)])] {
            var bad = ToneCurves(); bad.channels[0] = invalid; XCTAssertThrowsError(try bad.validate())
        }
        let old = Data("{\"channels\":[[0,0.25,0.5,0.75,1],[0,0.25,0.5,0.75,1],[0,0.25,0.5,0.75,1],[0,0.25,0.5,0.75,1]]}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ToneCurves.self,from:old),"Old fixed-point payloads are rejected, not migrated")
    }
    func testFivePointReferenceAndIrregularSegmentsNeverOvershoot() throws {
        for outputs in [[0.0,0.1,0.6,0.85,1], [0.1,0.9,0.2,0.7,0.3]] {
            let p = zip(ToneCurves.grid,outputs).map { CurvePoint(x:$0,y:$1) }
            for i in 0...1000 {
                let x = Double(i)/1000
                XCTAssertEqual(TonalPipeline.evaluate(p,at:x),TonalPipeline.interpolate(outputs,at:x*4),accuracy:2e-15)
            }
        }
        for p in [points([(0,0.1),(0.001,0.9),(0.002,0.2),(0.9,0.2),(1,0.8)]),
                  points([(0,1),(0.03,0.5),(0.82,0.5),(0.999,0),(1,0.2)])] {
            for i in 0..<p.count-1 { for j in 0...1000 {
                let x = p[i].x + (p[i+1].x-p[i].x)*Double(j)/1000
                let y = TonalPipeline.evaluate(p,at:x)
                XCTAssertTrue(y.isFinite)
                XCTAssertGreaterThanOrEqual(y,min(p[i].y,p[i+1].y)-1e-14)
                XCTAssertLessThanOrEqual(y,max(p[i].y,p[i+1].y)+1e-14)
            } }
        }
    }
    func testNeutralAnyLayoutIsExactIdentityAndMetalMatchesReference() throws {
        let context = CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAf])
        let colors = (0...256).map { i -> SIMD4<Float> in
            let x = Double(i)/256
            let c = PerceptualColor.linear(SIMD3(x,1-x,0.05+x*0.8))
            return SIMD4(Float(c.x),Float(c.y),Float(c.z),1)
        } + [SIMD4<Float>(0,0,0,1)]
        let image = colors.withUnsafeBytes { CIImage(bitmapData:Data($0),bytesPerRow:colors.count*16,
            size:CGSize(width:colors.count,height:1),format:.RGBAf,colorSpace:linear) }
        func render(_ source: CIImage) -> [Float] {
            var pixels = [Float](repeating:0,count:colors.count*4)
            context.render(source,toBitmap:&pixels,rowBytes:colors.count*16,bounds:image.extent,format:.RGBAf,colorSpace:linear)
            return pixels
        }
        var neutral = ToneCurves(); neutral.channels[0] = points([(0,0),(0.123,0.123),(1,1)])
        XCTAssertTrue(neutral.isNeutral)
        XCTAssertEqual(render(try TonalPipeline.curves(image,neutral)),render(image))
        var c = ToneCurves()
        c.channels[0] = points([(0,0.04),(0.21,0.18),(0.46,0.62),(0.9,0.96),(1,1)])
        c.channels[1] = points([(0,0),(0.06,0.1),(0.38,0.5),(0.68,0.48),(1,0.96)])
        c.channels[2] = (0..<16).map { CurvePoint(x:Double($0)/15,y:Double($0)/15*0.95) }
        c.channels[3] = points([(0,0.03),(0.499,0.2),(0.5,0.7),(0.501,0.3),(1,1)])
        try c.validate()
        let actual = render(try TonalPipeline.curves(image,c))
        var maxError = 0.0
        for i in colors.indices {
            let source = colors[i], expected = TonalPipeline.transform(SIMD3(Double(source.x),Double(source.y),Double(source.z)),curves:c)
            for j in 0..<3 { maxError = max(maxError,abs(Double(actual[4*i+j])-expected[j])) }
            XCTAssertEqual(actual[4*i+3],1)
        }
        XCTAssertLessThan(maxError,0.00008)
        print("FREE_CURVE_REFERENCE_METAL_MAX_ERROR \(maxError)")
    }
    func testPresetAmountEvaluatesFunctionsAtCommonInputsAndTreatsNilAsIdentity() throws {
        var a = recipe(), b = recipe()
        var ca = ToneCurves(), cb = ToneCurves()
        ca.channels[0] = points([(0,0),(0.2,0.3),(0.7,0.8),(1,1)])
        cb.channels[0] = points([(0,0.1),(0.4,0.2),(0.9,0.7),(1,0.9)])
        a.develop.curves = ca; b.develop.curves = cb
        for amount in [0.25,0.5,1.5,2] {
            let output = try XCTUnwrap(a.applyingPreset(b,options:RecipePasteOptions(),amount:amount).develop.curves)
            try output.validate()
            for p in output.channels[0] {
                let y0 = TonalPipeline.evaluate(ca.channels[0],at:p.x), y1 = TonalPipeline.evaluate(cb.channels[0],at:p.x)
                XCTAssertEqual(p.y,min(1,max(0,y0+(y1-y0)*amount)),accuracy:1e-12)
            }
        }
        XCTAssertEqual(try a.applyingPreset(b,options:RecipePasteOptions(),amount:0).develop.curves,ca)
        XCTAssertEqual(try a.applyingPreset(b,options:RecipePasteOptions(),amount:1).develop.curves,cb)
        let half = try XCTUnwrap(recipe().applyingPreset(b,options:RecipePasteOptions(),amount:0.25).develop.curves)
        XCTAssertNotEqual(half,cb); XCTAssertFalse(half.isNeutral)
        ca.channels[0] = (0..<16).map { CurvePoint(x:Double($0)/15,y:Double($0)/15) }
        cb.channels[0] = (0..<16).map { i in let x = pow(Double(i)/15,1.1); return CurvePoint(x:x,y:x*0.8) }
        let capped = try XCTUnwrap(ToneCurves.mixing(ca,cb,amount:0.5)); try capped.validate()
        XCTAssertEqual(capped.channels[0].count,16)
    }
    func testIdentityFunctionMixingIsExactAndIndependentUpstreamCurvesAreSegmentMonotone() throws {
        var neutral = ToneCurves()
        neutral.channels[0] = points([(0,0),(0.123,0.123),(0.773,0.773),(1,1)])
        for i in 0...1000 { let x = Double(i)/1000; XCTAssertEqual(TonalPipeline.evaluate(neutral.channels[0],at:x),x) }
        for amount in [0.25,0.5,1.5,2] {
            XCTAssertTrue(try XCTUnwrap(ToneCurves.mixing(nil,neutral,amount:amount)).isNeutral)
            XCTAssertTrue(try XCTUnwrap(ToneCurves.mixing(neutral,nil,amount:amount)).isNeutral)
        }
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/lightcraft-adaptation-vectors.json")
        let reference = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        var differences = [Double]()
        for row in try XCTUnwrap(reference["curves"] as? [[String:Any]]) {
            let anchors = try XCTUnwrap(row["points"] as? [[Double]]).map { CurvePoint(x:$0[0],y:$0[1]) }
            let upstream = try XCTUnwrap(row["direct"] as? [Double]), lut = try XCTUnwrap(row["lut"] as? [Double])
            var maximum = 0.0, tableError = 0.0
            for i in upstream.indices {
                let x = Double(i)/Double(upstream.count-1), value = TonalPipeline.evaluate(anchors,at:x)
                let j = min(anchors.count-2,anchors.lastIndex { $0.x <= x } ?? 0)
                XCTAssertGreaterThanOrEqual(upstream[i],min(anchors[j].y,anchors[j+1].y)-1e-12)
                XCTAssertLessThanOrEqual(upstream[i],max(anchors[j].y,anchors[j+1].y)+1e-12)
                maximum = max(maximum,abs(value-upstream[i])); tableError = max(tableError,abs(value-lut[i]))
            }
            differences.append(maximum)
            print("CURVE_UPSTREAM_DIRECT_LUT_DIFFERENCE \(maximum) \(tableError)")
        }
        XCTAssertEqual(differences[0],0.008229378785798103,accuracy:0.000001)
        XCTAssertLessThan(differences[1],1e-14,"Both algorithms allow explicitly descending segments")
        XCTAssertLessThan(differences[2],1e-14)
    }
    @MainActor func testNativeGraphDragKeyboardInsertionDeletionAndFocus() throws {
        let view = CurveNSView(frame:CGRect(x:0,y:0,width:260,height:185))
        let window = NSWindow(contentRect:view.bounds,styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = view
        defer { window.contentView = nil }
        var changes = 0, commits = 0
        view.change = { _,save in changes += 1; if save { commits += 1 } }
        view.commit = { commits += 1 }
        func mouse(_ type:NSEvent.EventType,_ x:Double,_ y:Double,_ clicks:Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with:type,location:view.convert(CGPoint(x:10+x*240,y:10+y*165),to:nil),modifierFlags:[],timestamp:0,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:clicks,pressure:1))
        }
        func key(_ code:UInt16,_ chars:String,shift:Bool = false) throws {
            view.keyDown(with:try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:shift ? [.shift] : [],timestamp:0,
                windowNumber:window.windowNumber,context:nil,characters:chars,charactersIgnoringModifiers:chars,isARepeat:false,keyCode:code)))
        }
        view.mouseDown(with:try mouse(.leftMouseDown,0.5,0.5))
        view.mouseDragged(with:try mouse(.leftMouseDragged,0.62,0.76)); view.mouseUp(with:try mouse(.leftMouseUp,0.62,0.76))
        XCTAssertEqual(view.curves.channels[0][2].x,0.62,accuracy:1e-12)
        XCTAssertEqual(view.curves.channels[0][2].y,0.76,accuracy:1e-12); XCTAssertEqual(commits,1)
        try key(123,"\u{f702}"); try key(125,"\u{f701}",shift:true)
        XCTAssertEqual(view.curves.channels[0][2].x,0.619,accuracy:1e-12)
        XCTAssertEqual(view.curves.channels[0][2].y,0.75,accuracy:1e-12)
        view.mouseDown(with:try mouse(.leftMouseDown,0.37,0.25,2)); view.mouseUp(with:try mouse(.leftMouseUp,0.37,0.25,2))
        XCTAssertEqual(view.curves.channels[0].count,6)
        try key(51,"\u{7f}"); XCTAssertEqual(view.curves.channels[0].count,5)
        try key(115,""); try key(51,"\u{7f}"); XCTAssertEqual(view.curves.channels[0].count,5)
        XCTAssertGreaterThan(changes,3)
        let model = AppModel()
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
            context:nil,characters:"\u{f702}",charactersIgnoringModifiers:"\u{f702}",isARepeat:false,keyCode:123))
        window.title = "test — Phosdeck"; window.makeFirstResponder(view)
        XCTAssertNotNil(WorkspaceKeyboard.handle(event,model:model),"Curve arrows reach the graph, not photo navigation")
    }
}
