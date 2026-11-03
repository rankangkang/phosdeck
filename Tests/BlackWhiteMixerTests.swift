import XCTest
import SwiftUI
import CoreImage
@testable import Phosdeck

final class BlackWhiteMixerTests: XCTestCase {
    private let linear = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAf])
    private let controls: [Double] = [100,-100,80,-80,60,-60,40,-40]
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest:String(repeating:"b",count:64),decoderVersion:"test",baselineExposure:0,
            baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
    }
    private func image(_ colors:[SIMD3<Double>]) -> CIImage {
        let floats: [Float] = colors.flatMap { [Float($0.x),Float($0.y),Float($0.z),Float(1)] }
        return floats.withUnsafeBytes {
            precondition($0.count == colors.count*16)
            return CIImage(bitmapData:Data($0),bytesPerRow:colors.count*16,
                size:CGSize(width:colors.count,height:1),format:.RGBAf,colorSpace:linear)
        }
    }
    private func pixels(_ image:CIImage) -> [Float] {
        XCTAssertGreaterThan(image.extent.width,0,"A missing test image must never pass an empty comparison")
        var values = [Float](repeating:0,count:Int(image.extent.width*image.extent.height)*4)
        context.render(image,toBitmap:&values,rowBytes:Int(image.extent.width)*16,bounds:image.extent,format:.RGBAf,colorSpace:linear)
        return values
    }
    func testRequiredStorageValidationAndColorGroupPasteAmount() throws {
        var a = recipe(), b = recipe(); b.develop.blackAndWhite = true; b.develop.blackWhiteMixer = controls
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:JSONEncoder().encode(b)),b)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(b.develop)) as? [String:Any])
        json.removeValue(forKey:"blackWhiteMixer")
        XCTAssertThrowsError(try JSONDecoder().decode(DevelopAdjustments.self,from:JSONSerialization.data(withJSONObject:json)))
        var unsupported = b.develop; unsupported.blackWhiteMixVersion = "original-hue-v1"
        XCTAssertThrowsError(try unsupported.validate())
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(b.develop)) as? [String:Any])
        old.removeValue(forKey:"blackWhiteMixVersion")
        XCTAssertThrowsError(try JSONDecoder().decode(DevelopAdjustments.self,from:JSONSerialization.data(withJSONObject:old)))
        for bad in [[0],Array(repeating:Double.nan,count:8),Array(repeating:Double.infinity,count:8),Array(repeating:100.1,count:8)] {
            a.develop.blackWhiteMixer = bad; XCTAssertThrowsError(try a.validate())
        }
        a = recipe()
        XCTAssertEqual(try a.pasting(b,options:RecipePasteOptions()).develop.blackWhiteMixer,controls)
        XCTAssertEqual(try a.pasting(b,options:RecipePasteOptions(color:false)).develop.blackWhiteMixer,Array(repeating:0,count:8))
        for amount in [0.25,0.5,1.5,2] {
            let mixed = try a.applyingPreset(b,options:RecipePasteOptions(),amount:amount)
            XCTAssertEqual(mixed.develop.blackWhiteMixer,controls.map { min(100,max(-100,$0*amount)) })
            XCTAssertEqual(mixed.develop.blackAndWhite,amount >= 0.5)
        }
        XCTAssertTrue(b.baseline().develop.blackWhiteMixer.allSatisfy { $0 == 0 })
        b.pipelineVersion = 1; XCTAssertThrowsError(try b.validate())
    }
    func testIndependentUpstreamFormulaVectorsAndLinearSRGBAdaptation() throws {
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/lightcraft-adaptation-vectors.json")
        let reference = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
        let hues = try XCTUnwrap(reference["linearSRGB2021BandHues"] as? [Double])
        for i in 0..<8 { XCTAssertEqual(PerceptualColor.blackWhiteHues[i],hues[i],accuracy:1e-14) }
        for row in try XCTUnwrap(reference["bw"] as? [[String:Any]]) {
            let h = try XCTUnwrap(row["h"] as? Double), c = try XCTUnwrap(row["c"] as? Double)
            let expected = try XCTUnwrap(row["linearSRGB2021"] as? [String:Any])
            let result = max(0,0.6+PerceptualColor.blackWhiteShift(hue:h,values:controls)/100*min(c/0.2,1)*0.25)
            XCTAssertEqual(result,try XCTUnwrap(expected["l"] as? Double),accuracy:1e-13)
        }
        let rows = try XCTUnwrap(reference["rgbBW"] as? [[String:Any]])
        let colors = try rows.map { row -> SIMD3<Double> in
            let p = try XCTUnwrap(row["rgb"] as? [Double]); return SIMD3(p[0],p[1],p[2])
        }
        var a = DevelopAdjustments(); a.blackAndWhite = true; a.blackWhiteMixer = controls
        let metal = pixels(try PerceptualColor.apply(image(colors),adjustments:a,saturation:1))
        for i in colors.indices {
            let expected = try XCTUnwrap(rows[i]["linear"] as? [Double])
            let native = PerceptualColor.linear(PerceptualColor.transform(PerceptualColor.encoded(colors[i]),adjustments:a))
            for j in 0..<3 {
                XCTAssertEqual(native[j],expected[j],accuracy:2e-7)
                XCTAssertEqual(Double(metal[4*i+j]),expected[j],accuracy:0.00001)
            }
        }
    }
    /// Frozen before the mixer was implemented, using ec32f9b's Double reference.
    func testZeroControlsKeepPreviousBlackWhiteReferenceAppearance() throws {
        let colors = [SIMD3<Double>(0,0,0),SIMD3(1,1,1),SIMD3(0.4,0.4,0.4),SIMD3(0.8,0.2,0.1),SIMD3(0.1,0.7,0.4),SIMD3(0.15,0.1,0.9)]
        let gray = [0.0,0.999999991393239,0.39999999628807936,0.4526707291862258,0.5892313060616589,0.322106481847914]
        let graded = [SIMD3<Double>(0,0,0),SIMD3(repeating:0.999999991393239),SIMD3(0.3708713545637607,0.4286657552263924,0.5075060434961151),
            SIMD3(0.4988374544645639,0.5352345234112588,0.5850370056934946),SIMD3(0.5790619532764392,0.6003344627685112,0.6295034176699282),
            SIMD3(0.2259497358043453,0.25867809015790894,0.31131476539093117)]
        var a = DevelopAdjustments(); a.blackAndWhite = true
        for i in colors.indices { for j in 0..<3 { XCTAssertEqual(PerceptualColor.transform(colors[i],adjustments:a)[j],gray[i],accuracy:2e-14) } }
        a.mixer[0].luminance = 35; a.mixer[5].luminance = -40
        a.grading.midtones = GradingTone(hue:210,saturation:35,luminance:12)
        a.grading.shadows = GradingTone(hue:30,saturation:15,luminance:-8)
        a.grading.balance = 17; a.grading.blending = 68
        for i in colors.indices { for j in 0..<3 { XCTAssertEqual(PerceptualColor.transform(colors[i],adjustments:a)[j],graded[i][j],accuracy:2e-14) } }
    }
    func testColorModeIgnoresStoredMixerExactlyIncludingZeroSaturation() throws {
        let source = image((0...128).map { SIMD3(Double($0)/128,0.3,0.7) })
        var a = DevelopAdjustments(); a.mixer[3].hue = 30; a.grading.midtones.saturation = 15
        for saturation in [0.0,0.7,1.0] {
            let normal = pixels(try PerceptualColor.apply(source,adjustments:a,saturation:saturation))
            var stored = a; stored.blackWhiteMixer = controls
            XCTAssertEqual(pixels(try PerceptualColor.apply(source,adjustments:stored,saturation:saturation)),normal)
            XCTAssertEqual(pixels(DevelopPipeline.apply(source,adjustments:stored)),pixels(DevelopPipeline.apply(source,adjustments:a)))
        }
    }
    func testBandBoundariesAndNearNeutralsAreContinuous() throws {
        var a = DevelopAdjustments(); a.blackAndWhite = true; a.blackWhiteMixer = controls
        let zero = { (h:Double,s:Double) in DevelopPipeline.rgb(SIMD3(h,s,0.48)) }
        var maximumJump = 0.0
        for center in HSLBand.centers + [360] {
            for saturation in [0.001,0.01,0.2,0.9] {
                let left = PerceptualColor.transform(zero(center-0.0001,saturation),adjustments:a)
                let right = PerceptualColor.transform(zero(center+0.0001,saturation),adjustments:a)
                maximumJump = max(maximumJump,abs(right.x-left.x))
            }
        }
        XCTAssertLessThan(maximumJump,0.00001)
        var baseline = a; baseline.blackWhiteMixer = Array(repeating:0,count:8)
        for light in [0.0,0.00001,0.01,0.2,0.5,0.99,1] {
            let gray = SIMD3(repeating:light), normal = PerceptualColor.transform(gray,adjustments:baseline)
            let actual = PerceptualColor.transform(gray,adjustments:a)
            XCTAssertEqual(actual.x,normal.x,accuracy:1e-12)
            for hue in stride(from:0.0,to:360,by:15) {
                let near = PerceptualColor.transform(DevelopPipeline.rgb(SIMD3(hue,0.00001,light)),adjustments:a)
                XCTAssertTrue(near.x.isFinite && near.y.isFinite && near.z.isFinite)
                XCTAssertEqual(near.x,actual.x,accuracy:0.00002)
            }
        }
        print("BW_BOUNDARY_MAX_ENCODED_JUMP \(maximumJump)")
    }
    func testMetalMatchesReferenceForHueRampExtremesGrayAndGrading() throws {
        var encoded = [SIMD3<Double>]()
        for saturation in [0.0,0.00001,0.01,0.2,1] {
            for light in [0.001,0.1,0.5,0.9,0.999] {
                for hue in stride(from:0.0,through:360,by:3) { encoded.append(DevelopPipeline.rgb(SIMD3(hue,saturation,light))) }
            }
        }
        encoded += [.zero,SIMD3(repeating:1)]
        let linearColors = encoded.map { color -> SIMD3<Double> in
            let c = PerceptualColor.linear(color)
            return SIMD3(Double(Float(c.x)),Double(Float(c.y)),Double(Float(c.z)))
        }
        let source = image(linearColors)
        var a = DevelopAdjustments(); a.blackAndWhite = true; a.blackWhiteMixer = controls
        a.mixer[0].luminance = 80; a.mixer[5].luminance = -100
        a.mixer[0].hue = 100; a.mixer[5].hue = -60
        a.mixer[1].saturation = 70; a.mixer[4].saturation = -80; a.vibrance = 40
        var maximum = 0.0
        for graded in [false,true] {
            if graded {
                a.grading.shadows = GradingTone(hue:30,saturation:75,luminance:-30)
                a.grading.midtones = GradingTone(hue:210,saturation:80,luminance:15)
                a.grading.highlights = GradingTone(hue:295,saturation:45,luminance:20)
                a.grading.global = GradingTone(hue:55,saturation:10,luminance:-5)
                a.grading.blending = 73; a.grading.balance = -23
            }
            let actual = pixels(try PerceptualColor.apply(source,adjustments:a,saturation:0.4))
            guard actual.count == linearColors.count*4 else { return XCTFail("Incomplete Metal image") }
            XCTAssertTrue(actual.allSatisfy(\.isFinite))
            for i in linearColors.indices {
                let expected = PerceptualColor.linear(PerceptualColor.transform(PerceptualColor.encoded(linearColors[i]),adjustments:a,saturation:0.4))
                for j in 0..<3 { maximum = max(maximum,abs(Double(actual[4*i+j])-expected[j])) }
                XCTAssertEqual(actual[4*i+3],1)
            }
        }
        XCTAssertLessThan(maximum,0.00008)
        print("BW_REFERENCE_METAL_MAX_LINEAR_ERROR \(maximum)")
    }
    func testCurvesBeforeMixerAndBlackWhiteSelectionAfterHSL() throws {
        let source = image([SIMD3(0.3,0.08,0.02),SIMD3(0.05,0.12,0.65)])
        var r = recipe(); r.develop.blackAndWhite = true; r.develop.blackWhiteMixer = controls
        var curve = ToneCurves(); curve.channels[1][2] = CurvePoint(x:0.42,y:0.65); r.develop.curves = curve
        let full = pixels(try ImagePipeline.develop(source,recipe:r,context:context))
        let expected = pixels(try PerceptualColor.apply(TonalPipeline.curves(source,curve),adjustments:r.develop,saturation:1))
        XCTAssertEqual(full,expected)
        let wrongOrder = pixels(try TonalPipeline.curves(PerceptualColor.apply(source,adjustments:r.develop,saturation:1),curve))
        XCTAssertNotEqual(full,wrongOrder)
        var changed = r.develop; changed.mixer[0].hue = 100; changed.mixer[0].saturation = -100; changed.vibrance = 100
        let color = SIMD3<Double>(0.8,0.12,0.03)
        XCTAssertNotEqual(PerceptualColor.transform(color,adjustments:r.develop),PerceptualColor.transform(color,adjustments:changed),
            "ColorOps applies HSL before black/white selection")
        for i in changed.mixer.indices { changed.mixer[i].saturation = -100 }
        var zero = changed; zero.blackWhiteMixer = Array(repeating:0,count:8)
        XCTAssertEqual(PerceptualColor.transform(color,adjustments:zero),PerceptualColor.transform(color,adjustments:changed),
            "HSL -100 saturation removes chroma and therefore the black/white contribution")
    }
    @MainActor func testNativeEightBandPanelFieldsKeyboardAndDisabledState() async throws {
        let suite = "bw-panel-"+UUID().uuidString
        let settings = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { settings.removePersistentDomain(forName:suite) }
        for key in ["developBasicOpen","developMixerOpen","developGradingOpen","developDetailsOpen","developCurvesOpen","developZonesOpen","developVignetteOpen","developGrainOpen","developSoloMode"] { settings.set(false,forKey:key) }
        settings.set(true,forKey:"developBlackWhiteMixerOpen")
        let model = AppModel(); model.canEdit = true; model.recipe = recipe(); model.recipe?.develop.blackAndWhite = true
        let host = NSHostingView(rootView:DevelopPanel(model:model).defaultAppStorage(settings).font(.system(size:13)).background(Theme.panel))
        let window = NSWindow(contentRect:CGRect(x:0,y:0,width:304,height:650),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = host; defer { window.contentView = nil }
        func descendants<T:NSView>(_ view:NSView,_ type:T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0,type) } }
        for _ in 0..<100 { if descendants(host,AdjustmentNSSlider.self).count == 8 { break }; try await Task.sleep(for:.milliseconds(15)) }
        XCTAssertEqual(descendants(host,AdjustmentNSSlider.self).count,8)
        let orange = try XCTUnwrap(descendants(host,AdjustmentNSSlider.self).first { $0.accessibilityLabel() == "橙色" })
        XCTAssertGreaterThan(orange.bounds.width,40); orange.doubleValue = 37; orange.changed()
        XCTAssertEqual(model.recipe?.develop.blackWhiteMixer[1],37)
        for _ in 0..<100 { if descendants(host,NSTextField.self).contains(where: { $0.stringValue == "+37" }) { break }; try await Task.sleep(for:.milliseconds(15)) }
        let field = try XCTUnwrap(descendants(host,NSTextField.self).first { $0.stringValue == "+37" })
        XCTAssertGreaterThan(field.bounds.width,30); XCTAssertTrue(window.makeFirstResponder(field))
        let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
            context:nil,characters:"g",charactersIgnoringModifiers:"g",isARepeat:false,keyCode:5))
        XCTAssertNotNil(WorkspaceKeyboard.handle(event,model:model))
        model.recipe?.develop.blackAndWhite = false
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertTrue(descendants(host,AdjustmentNSSlider.self).allSatisfy { !$0.isEnabled })
    }
}
