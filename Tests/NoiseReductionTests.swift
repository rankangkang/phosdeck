import XCTest
import CoreImage
@testable import Phosdeck

final class NoiseReductionTests: XCTestCase {
    typealias P = GeneralDetailReference.Pixel
    private let linear = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options:[.workingFormat:CIFormat.RGBAf,.workingColorSpace:linear,.cacheIntermediates:false])
    private func image(_ pixels: [P], width: Int, height: Int) -> CIImage {
        let data = pixels.flatMap { [Float($0.x),Float($0.y),Float($0.z),Float($0.w)] }.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData:data,bytesPerRow:width*16,size:CGSize(width:width,height:height),format:.RGBAf,colorSpace:linear)
    }
    private func read(_ image: CIImage) -> [P] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var data = [Float](repeating:0,count:w*h*4)
        context.render(image,toBitmap:&data,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:linear)
        return stride(from:0,to:data.count,by:4).map { P(Double(data[$0]),Double(data[$0+1]),Double(data[$0+2]),Double(data[$0+3])) }
    }
    private func compare(_ a: [P], _ b: [P], tolerance: Double = 0.00002, file: StaticString = #filePath, line: UInt = #line) {
        var error = 0.0
        for (p,q) in zip(a,b) { for k in 0..<4 { XCTAssertTrue(p[k].isFinite,file:file,line:line); error = max(error,abs(p[k]-q[k])) } }
        XCTAssertEqual(a.count,b.count,file:file,line:line); XCTAssertLessThanOrEqual(error,tolerance,file:file,line:line)
    }
    private struct RNG {
        var state: UInt64 = 0x123456789abcdef
        mutating func uniform() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return (Double(state >> 11)+0.5)/9007199254740992 }
        mutating func normal() -> Double { sqrt(-2*log(uniform()))*cos(2*Double.pi*uniform()) }
    }
    private func scene(width w: Int, height h: Int) -> (clean: [P], noisy: [P]) {
        var rng = RNG(), clean = [P](), noisy = [P]()
        for y in 0..<h { for x in 0..<w {
            var ev = x > w/3 ? 1.0 : 0
            if x == w/2 { ev += 0.7 }
            if y > h/2 && x > w*2/3 { ev += 0.12*sin(Double(x)*2*Double.pi/7) }
            let l = 0.18*exp2(ev), c = SIMD3<Double>(repeating:l)
            var chroma = SIMD3(rng.normal(),rng.normal(),rng.normal())*0.012
            chroma -= SIMD3(repeating:GeneralDetailReference.luma(chroma))
            let n = c*exp2(rng.normal()*0.14)+chroma
            clean.append(P(c.x,c.y,c.z,1)); noisy.append(P(n.x,n.y,n.z,1))
        } }
        return (clean,noisy)
    }
    func testZeroBypassRangesAndRequiredRecipeField() throws {
        let input = image([P(0.1,0.2,0.3,1)],width:1,height:1)
        XCTAssertTrue(try GeneralDetailPipeline.denoise(input,GeneralNoiseReduction(),sourceSize:CGSize(width:1,height:1)) === input)
        for bad in [Double.nan,.infinity,-1,101] {
            XCTAssertThrowsError(try GeneralNoiseReduction(luminance:bad).validate())
            XCTAssertThrowsError(try GeneralNoiseReduction(color:bad).validate())
        }
        var recipe = EditRecipe(sourceDigest:String(repeating:"a",count:64),decoderVersion:EditRecipe.rasterDecoderVersion,
            baselineExposure:0,baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
        recipe.noiseReduction = GeneralNoiseReduction(luminance:60,color:45)
        let data = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:data),recipe)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]); json.removeValue(forKey:"noiseReduction")
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self,from:JSONSerialization.data(withJSONObject:json)))
        XCTAssertFalse(recipe.baseline().noiseReduction.isActive)
        let local = LocalAdjustment(components:[MaskComponent(tool:.radial)])
        XCTAssertFalse(local.editingRecipe(from:recipe).noiseReduction.isActive)
    }
    func testMetalMatchesDoubleForChannelsExtremesAlphaAndScales() throws {
        let w = 32, h = 24, data = scene(width:w,height:h)
        for alpha in [false,true] {
            let source = data.noisy.enumerated().map { i,v -> P in
                let a = alpha ? [0.0,1.0/65535,0.3,1][min(3,(i%w)/8)] : 1
                return P(v.x*a,v.y*a,v.z*a,a)
            }
            for settings in [GeneralNoiseReduction(luminance:1),GeneralNoiseReduction(luminance:100),GeneralNoiseReduction(color:100),GeneralNoiseReduction(luminance:60,color:70)] {
                for scale in [1.0,0.37,0.07] {
                    let actual = try GeneralDetailPipeline.denoise(image(source,width:w,height:h),settings,sourceSize:CGSize(width:Double(w)/scale,height:Double(h)/scale))
                    let expected = GeneralDetailReference.denoise(source,width:w,height:h,settings:settings,scale:scale)
                    compare(read(actual),expected)
                    for (a,b) in zip(read(actual),source) { XCTAssertEqual(a.w,b.w,accuracy:0.00000003) }
                }
            }
        }
    }
    func testKnownCleanImageReproducibleNoiseErrorFlatNoiseEdgesLinesAndTexture() throws {
        let w = 128, h = 64, data = scene(width:w,height:h)
        XCTAssertEqual(data.noisy,scene(width:w,height:h).noisy)
        let settings = GeneralNoiseReduction(luminance:70,color:70)
        let result = read(try GeneralDetailPipeline.denoise(image(data.noisy,width:w,height:h),settings,sourceSize:CGSize(width:w,height:h)))
        let lum = GeneralDetailReference.logLuma, straight = GeneralDetailReference.straight
        func logRMS(_ a: [P], _ indices: [Int]) -> Double {
            sqrt(indices.reduce(0) { $0+pow(lum(straight(a[$1]))-lum(straight(data.clean[$1])),2) }/Double(indices.count))
        }
        func chromaRMS(_ a: [P]) -> Double {
            sqrt(a.reduce(0) { sum,p in let c = straight(p), y = GeneralDetailReference.luma(c), d = c-SIMD3(repeating:y); return sum+d.x*d.x+d.y*d.y+d.z*d.z }/Double(a.count*3))
        }
        let all = Array(data.clean.indices), flat = all.filter { $0%w > 8 && $0%w < 30 && $0/w > 8 && $0/w < 28 }
        let before = logRMS(data.noisy,all), after = logRMS(result,all)
        let flatBefore = logRMS(data.noisy,flat), flatAfter = logRMS(result,flat)
        XCTAssertLessThan(after,before); XCTAssertLessThan(flatAfter,flatBefore*0.85)
        XCTAssertLessThan(chromaRMS(result),chromaRMS(data.noisy)*0.65)
        func meanEV(_ a: [P], x: Int) -> Double { (8..<24).reduce(0) { $0+lum(straight(a[$1*w+x])) }/16 }
        func edge(_ a: [P]) -> Double { meanEV(a,x:w/3+6)-meanEV(a,x:w/3-6) }
        func line(_ a: [P]) -> Double { meanEV(a,x:w/2)-(meanEV(a,x:w/2-3)+meanEV(a,x:w/2+3))/2 }
        let edgeRatio = edge(result)/edge(data.clean), lineRatio = line(result)/line(data.clean)
        XCTAssertGreaterThan(edgeRatio,0.9); XCTAssertLessThan(edgeRatio,1.12); XCTAssertGreaterThan(lineRatio,0.8)
        func texture(_ a: [P]) -> Double {
            let ids = all.filter { $0%w > 90 && $0%w < 120 && $0/w > 40 && $0/w < 60 }
            let signal = ids.reduce(0) { $0+(lum(straight(a[$1]))-1)*sin(Double($1%w)*2*Double.pi/7) }
            return 2*signal/Double(ids.count)
        }
        let textureRatio = texture(result)/texture(data.clean)
        XCTAssertGreaterThan(textureRatio,0.65)
        print("GENERAL_NR_QUALITY log_rms_before=\(before) after=\(after) flat_before=\(flatBefore) after=\(flatAfter) chroma_before=\(chromaRMS(data.noisy)) after=\(chromaRMS(result)) edge_ratio=\(edgeRatio) line_ratio=\(lineRatio) texture_ratio=\(textureRatio)")
    }
    func testColorOnlyPreservesLuminanceAndProtectsIsoluminantEdgesGrayAndThinLines() throws {
        let w = 64, h = 24
        let source: [P] = (0..<w*h).map { i in
            let x = i%w
            let c = x < 22 || x == 40 || (x == 32 && i/w == 12) ? SIMD3<Double>(0.75,0.09,0.05) : SIMD3<Double>(repeating:0.227)
            let y = GeneralDetailReference.luma(c), corrected = c*(0.227/y)
            return P(corrected.x,corrected.y,corrected.z,1)
        }
        let result = read(try GeneralDetailPipeline.denoise(image(source,width:w,height:h),GeneralNoiseReduction(color:100),sourceSize:CGSize(width:w,height:h)))
        for (a,b) in zip(result,source) { XCTAssertEqual(GeneralDetailReference.luma(SIMD3(a.x,a.y,a.z)),GeneralDetailReference.luma(SIMD3(b.x,b.y,b.z)),accuracy:0.000001) }
        for i in source.indices where i%w == 22 || i%w == 39 { XCTAssertEqual(result[i].x,result[i].y,accuracy:0.00002) }
        for x in [31,33] { let p = result[12*w+x]; XCTAssertEqual(p.x,p.y,accuracy:0.00002,"An isolated saturated speck cannot spread into gray") }
        let i = 12*w+40; XCTAssertEqual(result[i].x,source[i].x,accuracy:0.00005)
        let gray = Array(repeating:P(0.2,0.2,0.2,1),count:w*h)
        let out = read(try GeneralDetailPipeline.denoise(image(gray,width:w,height:h),GeneralNoiseReduction(luminance:100,color:100),sourceSize:CGSize(width:w,height:h)))
        compare(out,gray,tolerance:0.000001)
    }
    func testTransparentHolesPartialCoverageEmptyAndTinyImagesKeepAlphaAndColor() throws {
        for (w,h) in [(1,1),(1,9),(17,1),(32,16)] {
            let input: [P] = (0..<w*h).map { i in
                let a = [0.0,1.0/65535,0.25,1][i%4]; return P(0.2*a,0.4*a,0.1*a,a)
            }
            let output = read(try GeneralDetailPipeline.denoise(image(input,width:w,height:h),GeneralNoiseReduction(luminance:100,color:100),sourceSize:CGSize(width:w,height:h)))
            compare(output,input,tolerance:0.000003)
        }
    }
    func testVarianceMappingAndExtendedLinearConstants() throws {
        let n = GeneralNoiseReduction(luminance:70,color:70)
        let p = GeneralDetailReference.noiseParameters(n,scale:1)
        XCTAssertEqual(p.sigma,2.75,accuracy:1e-12); XCTAssertEqual(p.epsilon,0.0081625,accuracy:1e-12)
        XCTAssertEqual(p.blend,sqrt(0.7),accuracy:1e-12); XCTAssertEqual(p.colorSigma,1.7,accuracy:1e-12)
        let quarter = GeneralDetailReference.noiseParameters(n,scale:0.25)
        XCTAssertEqual(quarter.epsilon,p.epsilon/16,accuracy:1e-12)
        XCTAssertEqual(quarter.colorBlend,0.50575,accuracy:1e-12)
        for alpha in [0.0,1.0/65535,0.5,1] {
            let v = P(-0.1*alpha,1.3*alpha,0.5*alpha,alpha), input = Array(repeating:v,count:16*8)
            let out = read(try GeneralDetailPipeline.denoise(image(input,width:16,height:8),GeneralNoiseReduction(luminance:100,color:100),sourceSize:CGSize(width:16,height:8)))
            compare(out,input,tolerance:0.000003)
        }
        var holes = Array(repeating:P(0.2,0.4,0.1,1),count:16*8)
        for y in 0..<8 { for x in 6..<10 { holes[y*16+x] = P(8,0,8,0) } }
        let actual = read(try GeneralDetailPipeline.denoise(image(holes,width:16,height:8),GeneralNoiseReduction(luminance:100,color:100),sourceSize:CGSize(width:16,height:8)))
        compare(actual,holes.map { $0.w > 0 ? $0 : .zero },tolerance:0.000003)
    }

    func testPreviewScaleFadesComparedWithFullRenderDownsample() throws {
        let w = 256, h = 128, data = scene(width:w,height:h), n = GeneralNoiseReduction(luminance:70,color:70)
        let input = image(data.noisy,width:w,height:h)
        let full = try GeneralDetailPipeline.denoise(input,n,sourceSize:input.extent.size)
        func down(_ input: CIImage, _ scale: Double) -> CIImage {
            input.clampedToExtent().applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:scale,kCIInputAspectRatioKey:1])
                .cropped(to:CGRect(x:0,y:0,width:Double(w)*scale,height:Double(h)*scale))
        }
        for scale in [0.5,0.25,0.125] {
            let small = down(input,scale), reference = read(down(full,scale))
            let preview = read(try GeneralDetailPipeline.denoise(small,n,sourceSize:input.extent.size))
            let off = read(small)
            let unscaled = read(try GeneralDetailPipeline.denoise(small,n,sourceSize:small.extent.size))
            func rms(_ values: [P]) -> Double { sqrt(zip(values,reference).reduce(0) { $0+pow($1.0.x-$1.1.x,2) }/Double(values.count)) }
            let error = rms(preview), disabled = rms(off)
            XCTAssertLessThan(error,0.003)
            XCTAssertLessThan(error,rms(unscaled),"Source-pixel scaling improves the draft over treating preview pixels as originals")
            print("GENERAL_NR_SCALE scale=\(scale) rms_vs_full_downsample=\(error) off_error=\(disabled) unscaled_error=\(rms(unscaled))")
        }
    }

}
