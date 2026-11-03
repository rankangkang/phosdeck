import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import zlib
@testable import Phosdeck

/// Direct PNG encoding makes bit depth, color type, hidden RGB, tRNS and ICC
/// independent of ImageIO's encoder heuristics. Only temporary synthetic data.
enum PNGFixture {
    static func word(_ n: Int) -> Data { Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) }
    static func chunk(_ name: String, _ payload: Data) -> Data {
        let body = Data(name.utf8) + payload
        let crc = body.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(body.count)) }
        return word(payload.count) + body + word(Int(crc))
    }
    static func compress(_ bytes: Data) throws -> Data {
        var size = compressBound(uLong(bytes.count)), output = Data(count: Int(compressBound(uLong(bytes.count))))
        let code = output.withUnsafeMutableBytes { dst in bytes.withUnsafeBytes { src in
            compress2(dst.bindMemory(to: Bytef.self).baseAddress!, &size, src.bindMemory(to: Bytef.self).baseAddress!, uLong(bytes.count), 6)
        } }
        guard code == Z_OK else { throw LRCError("Synthetic compression failed") }
        output.count = Int(size); return output
    }
    static func data(depth: Int = 8, color: Int = 6, icc: CGColorSpace? = nil, interlace: Bool = false,
                     width: Int = 128, height: Int = 96, transparency: Bool = true) throws -> Data {
        let maximum = (1 << depth) - 1
        var header = word(width) + word(height)
        header += Data([UInt8(depth), UInt8(color), 0, 0, interlace ? 1 : 0])
        var output = Data([137,80,78,71,13,10,26,10]) + chunk("IHDR", header)
        if let icc {
            output += chunk("iCCP", Data("Synthetic ICC".utf8) + Data([0,0]) + (try compress(icc.copyICCData()! as Data)))
        }
        if color == 3 {
            var palette = Data()
            for index in 0..<256 { palette.append(contentsOf: [UInt8(index),UInt8(255-index),UInt8(index/2)]) }
            output += chunk("PLTE", palette)
            if transparency { output += chunk("tRNS", Data((0..<256).map { UInt8($0) })) }
        } else if transparency && [0,2].contains(color) {
            output += chunk("tRNS", Data(repeating: 0, count: color == 0 ? 2 : 6))
        }
        var raw = Data()
        let passes = interlace ? [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)] : [(0,0,1,1)]
        for (x0,y0,dx,dy) in passes where x0 < width && y0 < height {
            for y in stride(from: y0, to: height, by: dy) {
                raw.append(0)
                for x in stride(from: x0, to: width, by: dx) {
                    let red = x == 0 ? 0 : (x * 317 + y * 53) % maximum
                    let green = x == 0 ? 0 : (x * 101 + y * 271) % maximum
                    let blue = x == 0 ? 0 : (x * 197 + y * 137) % maximum
                    let alphas = [0, 1, max(1, maximum/1000), maximum/4, maximum/2, maximum]
                    let alpha = transparency ? alphas[min(5, x * 6 / width)] : maximum
                    let values: [Int]
                    switch color {
                    case 0: values = [red]
                    case 2: values = [red, green, blue]
                    case 3: values = [x * 255 / max(1,width-1)]
                    case 4: values = [red, alpha]
                    default: values = [red, green, blue, alpha]
                    }
                    for value in values {
                        if depth == 16 { raw.append(UInt8(value >> 8)) }
                        raw.append(UInt8(value & 255))
                    }
                }
            }
        }
        return output + chunk("IDAT", try compress(raw)) + chunk("IEND", Data())
    }
    static func request(_ url: URL) throws -> ImageRequest {
        let folder = url.deletingLastPathComponent()
        let root = StorageRoot(id: UUID().uuidString, path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "Synthetic PNG")
        return ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: folder), root: root, recipe: nil)
    }
}

final class PNGTests: XCTestCase {
    var directory: URL!
    let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("png-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func fixture(_ name: String, depth: Int = 8, color: Int = 6, icc: CGColorSpace? = nil, interlace: Bool = false) throws -> ImageRequest {
        let url = directory.appendingPathComponent(name + ".png")
        try PNGFixture.data(depth: depth, color: color, icc: icc, interlace: interlace).write(to: url)
        return try PNGFixture.request(url)
    }
    func pixels(_ image: CGImage, format: CIFormat = .RGBAf) -> [Float] {
        var values = [Float](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 16,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: format,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return values
    }

    func testStaticColorTypesDepthICCAndNeutralBaseline() async throws {
        let pipeline = ImagePipeline()
        for color in [0,2,3,4,6] { for depth in (color == 3 ? [8] : [8,16]) { for interlace in [false,true] {
            let source = try fixture("mode-\(color)-\(depth)-\(interlace)", depth: depth, color: color, interlace: interlace)
            XCTAssertTrue(source.photo.supportsEditing); XCTAssertFalse(source.photo.isRAW)
            let baseline = try await pipeline.baseline(source)
            XCTAssertTrue(baseline.isRaster); XCTAssertTrue(baseline.isUnadjustedRaster); XCTAssertTrue(baseline.rawDetails.isDefault)
            XCTAssertEqual(baseline.baselineExposure,0); XCTAssertEqual(baseline.baselineTemperature,5500)
            let neutral = try await pipeline.render(ImageRequest(photo: source.photo, root: source.root, recipe: baseline), longEdge: nil, pixelFormat: .RGBA16)
            let original = try await pipeline.render(source, longEdge: nil, pixelFormat: .RGBA16)
            XCTAssertEqual(pixels(neutral.image),pixels(original.image), "Same depth, space and premultiplied alpha; hidden RGB at alpha=0 is zero")
            XCTAssertTrue(pixels(neutral.image).allSatisfy(\.isFinite))
            if depth == 16 && color == 6 {
                let raw = neutral.image.dataProvider!.data! as Data
                let levels = raw.withUnsafeBytes { Set($0.bindMemory(to: UInt16.self).enumerated().filter { $0.offset % 4 == 0 }.map(\.element)) }
                XCTAssertGreaterThan(levels.count, 256)
            }
        } } }
        for profile in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let source = try fixture("icc-" + (profile as String), depth: 16, icc: XCTUnwrap(CGColorSpace(name: profile)))
            let recipe = try await pipeline.baseline(source)
            let neutral = try await pipeline.render(ImageRequest(photo: source.photo, root: source.root, recipe: recipe), longEdge: nil, pixelFormat: .RGBA16)
            let reference = try await pipeline.render(source, longEdge: nil, pixelFormat: .RGBA16)
            XCTAssertEqual(pixels(neutral.image),pixels(reference.image))
            XCTAssertEqual(neutral.image.colorSpace?.name,CGColorSpace.sRGB)
        }
        for color in [3,4] {
            let space = try XCTUnwrap(CGColorSpace(name:color == 3 ? CGColorSpace.sRGB : CGColorSpace.genericGrayGamma2_2))
            let source = try fixture("icc-mode-\(color)",depth:color == 3 ? 8 : 16,color:color,icc:space)
            let baseline = try await pipeline.baseline(source)
            let result = try await pipeline.render(ImageRequest(photo:source.photo,root:source.root,recipe:baseline),longEdge:nil,pixelFormat:.RGBA16)
            XCTAssertTrue(pixels(result.image).allSatisfy(\.isFinite))
            XCTAssertEqual(result.image.colorSpace?.name,CGColorSpace.sRGB)
        }
        let original = try PNGFixture.data(depth:16)
        let gammaURL = directory.appendingPathComponent("gamma-without-icc.png")
        try (Data(original.prefix(33))+PNGFixture.chunk("gAMA",PNGFixture.word(50000))+original.dropFirst(33)).write(to:gammaURL)
        XCTAssertEqual(try PhotoFileType.inspectSource(gammaURL).pngICC,false)
        let gamma = try PNGFixture.request(gammaURL)
        XCTAssertNil(gamma.photo.details?.profile,"An inferred calibrated profile is not an embedded ICC")
        let baseline = try await pipeline.baseline(gamma)
        let rendered = try await pipeline.render(ImageRequest(photo:gamma.photo,root:gamma.root,recipe:baseline),longEdge:nil,pixelFormat:.RGBA16)
        let plain = try fixture("plain-without-icc",depth:16)
        let reference = try await pipeline.render(plain,longEdge:nil,pixelFormat:.RGBA16)
        XCTAssertTrue(pixels(rendered.image) == pixels(reference.image),"No ICC always means sRGB, including a gAMA-only file")
    }

    func testDamagedDisguisedAnimatedAndUnsupportedPNGsAreRejected() throws {
        let valid = try PNGFixture.data()
        var badCRC = valid; badCRC[29] ^= 1
        let header = valid.prefix(33)
        let animation = Data(header) + PNGFixture.chunk("acTL", PNGFixture.word(1)+PNGFixture.word(0)) + valid.dropFirst(33)
        let corruptZlib = Data(header) + PNGFixture.chunk("IDAT",Data([1,2,3,4,5])) + PNGFixture.chunk("IEND",Data())
        let shortRows = Data(header) + PNGFixture.chunk("IDAT",try PNGFixture.compress(Data([0,255]))) + PNGFixture.chunk("IEND",Data())
        let badFilter = Data(header) + PNGFixture.chunk("IDAT",try PNGFixture.compress(Data([5])+Data(repeating:0,count:128*96*4+95))) + PNGFixture.chunk("IEND",Data())
        let invalidICC = Data(header) + PNGFixture.chunk("iCCP",Data([65,0,0])+(try PNGFixture.compress(Data([1,2,3])))) + valid.dropFirst(33)
        for (i,data) in [Data(valid.dropLast(8)),badCRC,animation,corruptZlib,shortRows,badFilter,invalidICC,valid+Data([0])].enumerated() {
            let url = directory.appendingPathComponent("bad-\(i).png"); try data.write(to:url)
            XCTAssertThrowsError(try PNGFixture.request(url),"bad-\(i)")
        }
        let disguised = directory.appendingPathComponent("disguised.jpg"); try valid.write(to:disguised)
        XCTAssertThrowsError(try PNGFixture.request(disguised))
        let low = directory.appendingPathComponent("low.png")
        let lowHeader = PNGFixture.word(1)+PNGFixture.word(1)+Data([4,0,0,0,0])
        try (Data(valid.prefix(8))+PNGFixture.chunk("IHDR",lowHeader)+PNGFixture.chunk("IDAT",PNGFixture.compress(Data([0,0])))+PNGFixture.chunk("IEND",Data())).write(to:low)
        XCTAssertThrowsError(try PNGFixture.request(low))
    }
    func testOversizedSourceIsRejectedBeforeInflatingOrAllocatingPixels() throws {
        for (width,height) in [(131_073,1),(16_385,16_384),(2_147_483_647,2_147_483_647)] {
            let header = PNGFixture.word(width)+PNGFixture.word(height)+Data([16,6,0,0,0])
            let url = directory.appendingPathComponent("oversized-\(width).png")
            // Deliberately no image data: the size error must precede zlib/pixels.
            try (Data([137,80,78,71,13,10,26,10])+PNGFixture.chunk("IHDR",header)).write(to:url)
            XCTAssertThrowsError(try PNGValidation.validate(url)) { error in
                XCTAssertTrue(error.localizedDescription.contains("尺寸无效或过大"))
            }
        }
    }

    func testReferenceScanCopyAndTransparentThumbnailCache() async throws {
        _ = try fixture("alpha16",depth:16); _ = try fixture("palette",color:3)
        let invalid = directory.appendingPathComponent("bad.png"); try Data([137,80,78,71]).write(to:invalid)
        let sourceFolder = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:sourceFolder,withIntermediateDirectories:true)
        for name in ["alpha16.png","palette.png","bad.png"] {
            try FileManager.default.moveItem(at:directory.appendingPathComponent(name),to:sourceFolder.appendingPathComponent(name))
        }
        let catalog = try CatalogStore(directory:directory.appendingPathComponent("catalog"))
        let importer = ReferenceImporter()
        let candidates = try await importer.preview(source:sourceFolder,includeSubfolders:false,catalog:catalog)
        XCTAssertEqual(candidates.count,3); XCTAssertEqual(candidates.filter { $0.problem != nil }.count,1)
        let report = await importer.add(source:sourceFolder,candidates:candidates,collection:nil,catalog:catalog)
        XCTAssertEqual(report.indexed,2); XCTAssertEqual(report.errors.count,1)
        let root = try XCTUnwrap(catalog.roots().first)
        let scanned = await importer.scan(root:root,catalog:catalog) { _ in }
        XCTAssertEqual(scanned.indexed,2); XCTAssertEqual(scanned.errors.count,1)
        let target = directory.appendingPathComponent("copy"); try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let copiedCatalog = try CatalogStore(directory:directory.appendingPathComponent("copied-catalog"))
        let plan = try await ImportPlanner().plan(source:sourceFolder,target:target,layout:.flat,policy:.uniqueName,skipIdentical:true,dateOverride:nil,confirmSidecars:false,catalog:copiedCatalog,includeSubfolders:false)
        let copied = await CopyImporter().run(plan,catalog:copiedCatalog) { _ in }
        XCTAssertEqual(copied.groups.filter { $0.state == "completed" }.count,2)
        XCTAssertEqual(try copiedCatalog.photos().count,2)
        for photo in try copiedCatalog.photos() {
            XCTAssertEqual(try SafeFileWriter.sha256(target.appendingPathComponent(photo.relativePath)),try SafeFileWriter.sha256(sourceFolder.appendingPathComponent(photo.relativePath)))
        }
        let photo = try XCTUnwrap(catalog.photos().first)
        let id = UUID().uuidString
        let firstService = ThumbnailService(); try await firstService.configure(catalogID:id,gigabytes:1)
        let first = try await firstService.image(photo:photo,root:root)
        let secondService = ThumbnailService(); try await secondService.configure(catalogID:id,gigabytes:1)
        let cached = try await secondService.image(photo:photo,root:root)
        let cachedPixels = pixels(cached)
        XCTAssertTrue(pixels(first) == cachedPixels, "Cold and warm transparent thumbnails must match exactly"); XCTAssertTrue(stride(from:3,to:cachedPixels.count,by:4).contains { cachedPixels[$0] < 0.9 })
        try await firstService.clear()
    }
}
