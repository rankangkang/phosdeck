import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd
import Accelerate

enum PhotoMergeKind: String, Codable, CaseIterable, Identifiable {
    case panorama, hdr, hdrPanorama, focus, average, median, additive, lighten, darken, screen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .panorama: L10n.text("merge.kind.panorama", defaultValue: "Panorama")
        case .hdr: L10n.text("merge.kind.hdr", defaultValue: "HDR")
        case .hdrPanorama: L10n.text("merge.kind.hdrPanorama", defaultValue: "HDR Panorama")
        case .focus: L10n.text("merge.kind.focus", defaultValue: "Focus Stack")
        case .average: L10n.text("merge.kind.average", defaultValue: "Average · Noise Reduction")
        case .median: L10n.text("merge.kind.median", defaultValue: "Median · Remove Transients")
        case .additive: L10n.text("merge.kind.additive", defaultValue: "Multiple Exposure · Add")
        case .lighten: L10n.text("merge.kind.lighten", defaultValue: "Lighten · Star Trails")
        case .darken: L10n.text("merge.kind.darken", defaultValue: "Darken")
        case .screen: L10n.text("merge.kind.screen", defaultValue: "Multiple Exposure · Screen")
        }
    }
    var isPanorama: Bool { self == .panorama || self == .hdrPanorama }
    var isHDR: Bool { self == .hdr || self == .hdrPanorama }
    var defaultAlignment: Bool {
        switch self {
        case .additive,.lighten,.darken,.screen: false
        default: true
        }
    }
    var suffix: String {
        switch self {
        case .panorama: "Pano"; case .hdr: "HDR"; case .hdrPanorama: "HDR-Pano"; case .focus: "Focus"
        default: "Stack-" + rawValue
        }
    }
}

enum MergeProjection: String, Codable, CaseIterable, Identifiable {
    case perspective, cylindrical, spherical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .perspective: L10n.text("merge.projection.perspective", defaultValue: "Perspective")
        case .cylindrical: L10n.text("merge.projection.cylindrical", defaultValue: "Cylindrical")
        case .spherical: L10n.text("merge.projection.spherical", defaultValue: "Spherical")
        }
    }
}

enum MergeMasterFormat: String, Codable, CaseIterable, Identifiable {
    case tiff, dng
    var id: String { rawValue }
    var title: String { self == .tiff ? "TIFF · Float32" : "DNG · Float32" }
    var fileExtension: String { self == .tiff ? "tif" : "dng" }
}

struct PhotoMergeOptions: Codable, Equatable {
    var kind: PhotoMergeKind = .hdr
    var align = true
    var deghost = 1
    var projection = MergeProjection.cylindrical
    var autoCrop = true
    var autoLevel = false
    var boundaryWarp = 0.0
    var fillEdges = false
    var masterFormat = MergeMasterFormat.tiff
    var bracketSize = 3
    /// Explicit source resolution, never an automatic reduction on memory failure. Zero means original.
    var sourceLongEdge = 0
    func validate(count: Int) throws {
        guard (2...128).contains(count), (0...3).contains(deghost), (2...9).contains(bracketSize),
              boundaryWarp.isFinite, (0...100).contains(boundaryWarp),
              [0,2000,4000,6000].contains(sourceLongEdge),
              kind != .hdrPanorama || (count >= bracketSize * 2 && count.isMultiple(of: bracketSize)) else {
            throw LRCError(L10n.text("merge.invalidInputs", defaultValue: "Select 2–128 photos; HDR panoramas need at least two complete exposure brackets"))
        }
    }
}

/// Straight linear sRGB, top-left origin, pixel centres at integer coordinates.
/// Alpha is coverage. Sampling premultiplies before interpolation; hidden RGB is zero.
struct MergeImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [SIMD4<Float>]
    init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }
    init(width: Int, height: Int) { self.init(width: width, height: height, pixels: .init(repeating: .zero, count: width * height)) }
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static func luma(_ p: SIMD4<Float>) -> Float { p.x * 0.2126 + p.y * 0.7152 + p.z * 0.0722 }
    static func peak(_ p: SIMD4<Float>) -> Float { max(p.x, max(p.y, p.z)) }
    func sample(_ x: Double, _ y: Double) -> SIMD4<Float>? {
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x <= Double(width - 1), y <= Double(height - 1) else { return nil }
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        func pm(_ p: SIMD4<Float>) -> SIMD4<Float> { SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w) }
        let a = pm(pixels[y0 * width + x0]), b = pm(pixels[y0 * width + x1])
        let c = pm(pixels[y1 * width + x0]), d = pm(pixels[y1 * width + x1])
        let p = (a * (1-fx) + b * fx) * (1-fy) + (c * (1-fx) + d * fx) * fy
        return p.w > 1e-8 ? SIMD4(p.x/p.w, p.y/p.w, p.z/p.w, p.w) : .zero
    }
    func resized(longEdge: Int) throws -> Self {
        let scale = min(1, Double(longEdge) / Double(max(width, height)))
        if scale == 1 { return self }
        let w = max(1, Int((Double(width)*scale).rounded())), h = max(1, Int((Double(height)*scale).rounded()))
        var out = Self(width: w, height: h)
        for y in 0..<h {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<w {
                let u = min(Double(width-1), max(0, (Double(x)+0.5)*Double(width)/Double(w)-0.5))
                let v = min(Double(height-1), max(0, (Double(y)+0.5)*Double(height)/Double(h)-0.5))
                out.pixels[y*w+x] = sample(u,v) ?? .zero
            }
        }
        return out
    }
    func ciImage() -> CIImage {
        let premultiplied = pixels.map { SIMD4($0.x*$0.w,$0.y*$0.w,$0.z*$0.w,$0.w) }
        let data = premultiplied.withUnsafeBytes { Data($0) }
        // bitmapData and CGImage retain top-down storage. The flipped render
        // destination in read() gives the same row order; no extra reflection.
        return CIImage(bitmapData: data, bytesPerRow: width*16, size: CGSize(width: width,height: height), format: .RGBAf, colorSpace: Self.space)
    }
    static func read(_ image: CIImage, context: CIContext,honorCancellation: Bool = true) throws -> Self {
        let bounds = image.extent.integral, w = Int(bounds.width), h = Int(bounds.height)
        try PhotoGeometry.checkSize(bounds.size)
        var out = Self(width: w,height: h)
        try out.pixels.withUnsafeMutableBytes { bytes in
            let target = CIRenderDestination(bitmapData: bytes.baseAddress!, width: w,height: h,bytesPerRow: w*16,format: .RGBAf)
            target.colorSpace = space; target.alphaMode = .unpremultiplied; target.isFlipped = true
            _ = try context.startTask(toRender: image, from: bounds, to: target, at: .zero).waitUntilCompleted()
        }
        for i in out.pixels.indices {
            if honorCancellation,i.isMultiple(of:65536) { try Task.checkCancellation() }
            let p = out.pixels[i]
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.w.isFinite else { throw LRCError(L10n.text("merge.nonfinite", defaultValue: "A source contains non-finite image values")) }
            out.pixels[i].w = min(1,max(0,p.w))
            if out.pixels[i].w == 0 { out.pixels[i] = .zero }
        }
        return out
    }
    func medianLuma() -> Float {
        let values = stride(from: 0, to: pixels.count, by: max(1,pixels.count/60000))
            .compactMap { pixels[$0].w > 0.99 ? max(0,Self.luma(pixels[$0])) : nil }.sorted()
        return values.isEmpty ? 0.18 : max(1e-6,values[values.count/2])
    }
    func grey(normalize: Bool = true) -> MergePlane {
        let gain: Float = normalize ? 0.18/medianLuma() : 1
        return MergePlane(width: width,height: height,values: pixels.map { sqrt(max(0,Self.luma($0)*gain)) })
    }
}

struct MergePlane {
    let width: Int
    let height: Int
    var values: [Float]
    init(width: Int,height: Int,values: [Float]? = nil) {
        self.width = width; self.height = height; self.values = values ?? .init(repeating:0,count:width*height)
    }
    func at(_ x: Int,_ y: Int) -> Float { values[min(height-1,max(0,y))*width+min(width-1,max(0,x))] }
    func sample(_ x: Double,_ y: Double) -> Float {
        let u = min(Double(width-1),max(0,x)), v = min(Double(height-1),max(0,y))
        let a = Int(u), b = Int(v), fx = Float(u-Double(a)), fy = Float(v-Double(b))
        return (at(a,b)*(1-fx)+at(a+1,b)*fx)*(1-fy)+(at(a,b+1)*(1-fx)+at(a+1,b+1)*fx)*fy
    }
    func blurred(_ sigma: Float) -> Self {
        guard sigma > 0 else { return self }
        let radius = max(1,Int(ceil(sigma*3)))
        let raw = (-radius...radius).map { exp(-Float($0*$0)/(2*sigma*sigma)) }, sum = raw.reduce(0,+)
        let kernel = raw.map { $0/sum }
        var temp = Self(width:width,height:height), result = temp
        // The same separable float kernel and replicated borders. Real 1000px
        // sequences otherwise spend minutes in scalar Gaussian loops in Debug.
        let horizontal = Self.convolve(values,into:&temp.values,width:width,height:height,kernel:kernel,vertical:false)
        if horizontal,Self.convolve(temp.values,into:&result.values,width:width,height:height,kernel:kernel,vertical:true) { return result }
        for y in 0..<height { for x in 0..<width {
            var value: Float = 0
            for k in -radius...radius { value += at(x+k,y)*kernel[k+radius] }
            temp.values[y*width+x] = value
        } }
        for y in 0..<height { for x in 0..<width {
            var value: Float = 0
            for k in -radius...radius { value += temp.at(x,y+k)*kernel[k+radius] }
            result.values[y*width+x] = value
        } }
        return result
    }
    private static func convolve(_ input: [Float],into output: inout [Float],width: Int,height: Int,kernel: [Float],vertical: Bool) -> Bool {
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                kernel.withUnsafeBufferPointer { coefficients in
                    var a = vImage_Buffer(data:UnsafeMutableRawPointer(mutating:source.baseAddress!),height:vImagePixelCount(height),width:vImagePixelCount(width),rowBytes:width*4)
                    var b = vImage_Buffer(data:destination.baseAddress!,height:vImagePixelCount(height),width:vImagePixelCount(width),rowBytes:width*4)
                    return vImageConvolve_PlanarF(&a,&b,nil,0,0,coefficients.baseAddress!,vertical ? UInt32(kernel.count) : 1,vertical ? 1 : UInt32(kernel.count),0,vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
                }
            }
        }
    }
    func resized(_ w: Int,_ h: Int) -> Self {
        var out = Self(width:w,height:h)
        for y in 0..<h { for x in 0..<w {
            out.values[y*w+x] = sample((Double(x)+0.5)*Double(width)/Double(w)-0.5,(Double(y)+0.5)*Double(height)/Double(h)-0.5)
        } }
        return out
    }
}

struct MergeFrame {
    var image: MergeImage
    var exposure: Double?
    var clip: Float = 1
    var sourceIndex: Int = 0
    var focal35mm: Double?
    var nativeWidth: Int?
    var nativeHeight: Int?
    /// HDR bracket reference, on the same grid as the fused image. Registration
    /// uses the captured detail; gains and blending still use float radiance.
    var registrationImage: MergeImage?
    var raw = false
    var focalLength: Double?
    var cameraModel: String?
    var exposureFloor: Float { raw ? 0.01 : 0.04 }
    var fullWidth: Int { nativeWidth ?? image.width }
    var fullHeight: Int { nativeHeight ?? image.height }
}

struct MergeProvenance: Codable, Equatable {
    static let marker = "Phosdeck linear composite "
    static let prefix = marker + "v2\n"
    var version = 2
    var options: PhotoMergeOptions
    var sources: [Source]
    struct Source: Codable, Equatable {
        let photoID: String
        let digest: String
        let recipeRevision: Int
    }
    var description: String { get throws { Self.prefix + String(decoding: try JSONEncoder().encode(self),as:UTF8.self) } }
    static func read(_ properties: [String:Any]) throws -> Self? {
        guard let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String:Any],
              let text = tiff[kCGImagePropertyTIFFImageDescription as String] as? String,
              let value = try decode(text) else { return nil }
        guard value.options.masterFormat == .tiff,
              properties[kCGImagePropertyIsFloat as String] as? Bool == true,
              properties[kCGImagePropertyDepth as String] as? Int == 32,
              properties[kCGImagePropertyProfileName as String] as? String == "sRGB IEC61966-2.1 Linear" else {
            throw LRCError(L10n.text("merge.invalidMaster", defaultValue: "The linear composite master is invalid"))
        }
        return value
    }
    static func decode(_ text: String) throws -> Self? {
        guard text.hasPrefix(marker) else { return nil }
        guard text.hasPrefix(prefix) else { throw MergeMasterCodec.invalid }
        let value = try JSONDecoder().decode(Self.self,from:Data(text.dropFirst(prefix.count).utf8))
        try value.options.validate(count:value.sources.count)
        guard value.version == 2,value.sources.allSatisfy({ !$0.photoID.isEmpty && $0.digest.count == 64 && $0.digest.allSatisfy(\.isHexDigit) }) else { throw MergeMasterCodec.invalid }
        return value
    }
}
