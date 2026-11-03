import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Phosdeck

final class MoreRAWTests: XCTestCase {
    static let files = ["a7iii_12bit_compressed.ARW", "leica_m8_8bit_uncompressed.DNG", "iphone12pro_8bit_ljpeg.DNG",
        "nikon_d700_14bit_lossless.NEF", "nikon_d700_12bit_uncompressed.NEF", "canon_m50_craw.CR3", "canon_m50_raw.CR3",
        "fuji_xt20_14bit_uncompressed.RAF", "fuji_xt20_14bit_lossless.RAF"]
    static var supportedFiles: [String] { files.filter { $0 != "iphone12pro_8bit_ljpeg.DNG" } }
    static func sample(_ name: String) throws -> URL {
        let folder = try XCTUnwrap(Bundle(for: MoreRAWTests.self).resourceURL).appendingPathComponent("CC0RAWFixtures")
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("公开 CC0 样片未准备：\(name)；仅从 Tests/Fixtures/public-raw-samples.json 获取，不搜索私人照片") }
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [[String: Any]])
        let expected = try XCTUnwrap(manifest.first { $0["file"] as? String == name }?["sha256"] as? String)
        XCTAssertEqual(try SafeFileWriter.sha256(url), expected, "样片必须匹配公开清单")
        return url
    }
    static func request(_ name: String) throws -> ImageRequest {
        let url = try sample(name), folder = url.deletingLastPathComponent()
        let root = StorageRoot(id: "public-raw", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "CC0")
        return ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: folder), root: root, recipe: nil)
    }
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testARWInput() async throws { try await exercise([Self.files[0]]) }
    func testDNGInputs() async throws { try await exercise([Self.files[1]]) }
    func testNEFInputs() async throws { try await exercise(Array(Self.files[3...4])) }
    func testCR3Inputs() async throws { try await exercise(Array(Self.files[5...6])) }
    func testRAFInputs() async throws { try await exercise(Array(Self.files[7...8])) }

    func testAppleDNGIsExplicitlyUnavailable() async throws {
        let url = try Self.sample(Self.files[2]), parent = url.deletingLastPathComponent()
        let root = StorageRoot(id: "apple-dng", path: parent.path, bookmark: try AccessLease.bookmark(parent, readOnly: true), label: "CC0")
        XCTAssertThrowsError(try ReferenceImporter.inspect(url: url, root: root, rootURL: parent)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Apple DNG"))
        }
        let identity = try FileIdentity.read(url)
        let photo = Photo(id: "apple-dng", rootID: root.id, relativePath: url.lastPathComponent, identity: try JSONEncoder().encode(identity), identityKey: identity.key, width: 4032, height: 3024)
        let pipeline = ImagePipeline()
        do { _ = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil)); XCTFail("不能建立未通过验证的 Apple DNG 基线") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Apple DNG")) }
        do { _ = try await ThumbnailService().image(photo: photo, root: root); XCTFail("不能回退为内嵌 JPEG") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Apple DNG")) }
    }

    private func exercise(_ names: [String]) async throws {
        let pipeline = ImagePipeline(), thumbnails = ThumbnailService()
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        func pixels(_ image: CGImage) -> Data {
            var data = Data(count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { bytes in
                context.render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: image.width * 4,
                    bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
            }
            return data
        }
        for name in names {
            let source = try Self.request(name), url = try Self.sample(name)
            let digest = try SafeFileWriter.sha256(url)
            XCTAssertTrue(source.photo.isRAW); XCTAssertTrue(source.photo.supportsEditing)
            let baseline = try await pipeline.baseline(source)
            XCTAssertEqual(baseline.sourceDigest, digest); XCTAssertFalse(baseline.isRaster)
            XCTAssertEqual(baseline, try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(baseline)))
            let request = ImageRequest(photo: source.photo, root: source.root, recipe: baseline)
            let result = try await pipeline.render(request, longEdge: 256)
            let deliveredPixels = pixels(result.image)
            let raw = try XCTUnwrap(CIRAWFilter(imageURL: url)); raw.extendedDynamicRangeAmount = 0
            let expectedSize = raw.orientation.rawValue >= 5 ? CGSize(width: raw.nativeSize.height, height: raw.nativeSize.width) : raw.nativeSize
            XCTAssertEqual(result.orientedSourceSize, expectedSize); XCTAssertEqual(result.fullSize, expectedSize)
            let direct = ImagePipeline.resized(try XCTUnwrap(raw.outputImage), longEdge: 256)
            let bitmap = try XCTUnwrap(context.createCGImage(direct, from: direct.extent.integral, format: .RGBA8,
                colorSpace: ImagePipeline.outputSpace, deferred: false))
            XCTAssertEqual(pixels(result.image), pixels(bitmap), "零参数必须保留既有 Apple RAW 外观：\(name)")
            let draft = try await pipeline.renderInteractive(request, longEdge: 256)
            XCTAssertEqual(deliveredPixels, pixels(result.image), "生成交互预览不能修改已交付的质量图：\(name)")
            XCTAssertEqual(draft.orientedSourceSize, expectedSize)
            XCTAssertLessThanOrEqual(max(draft.image.width, draft.image.height), 257)
            let thumbnail = try await thumbnails.image(photo: source.photo, root: source.root, edge: 256)
            let a = pixels(thumbnail), b = pixels(result.image)
            if a != b {
                let differences = zip(a, b).map { abs(Int($0) - Int($1)) }
                print("RAW_THUMB_DIFF file=\(name) max=\(differences.max() ?? 0) count=\(differences.filter { $0 != 0 }.count) mean=\(Double(differences.reduce(0,+)) / Double(differences.count))")
                let second = ImagePipeline(), again = try await second.baseline(source)
                let repeatImage = try await second.render(ImageRequest(photo: source.photo, root: source.root, recipe: again), longEdge: 256)
                print("RAW_THUMB_DIAG baseline=\(baseline.baselineExposure),\(baseline.baselineTemperature),\(baseline.baselineTint) again=\(again.baselineExposure),\(again.baselineTemperature),\(again.baselineTint) thumbEqualsFresh=\(a == pixels(repeatImage.image)) a=\(Array(a.prefix(20))) b=\(Array(b.prefix(20)))")
                for (label, cg) in [("quality", result.image), ("thumbnail", thumbnail)] {
                    let image = NSMutableData(), dest = try XCTUnwrap(CGImageDestinationCreateWithData(image, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
                    let attachment = XCTAttachment(data: image as Data, uniformTypeIdentifier: UTType.png.identifier)
                    attachment.name = name + "-" + label; attachment.lifetime = .keepAlways; add(attachment)
                }
            }
            XCTAssertEqual(a, b, "未建配方的 RAW 缩略图也必须实际显影")
            var edited = baseline; edited.exposure = 0.35; edited.quarterTurns = 1; edited.crop = Crop(x: 0.1, y: 0.15, width: 0.8, height: 0.7)
            let editedRequest = ImageRequest(photo: source.photo, root: source.root, recipe: edited)
            let high = try await pipeline.render(editedRequest, longEdge: 256, pixelFormat: .RGBA16)
            let output = folder.appendingPathComponent(name + ".tif")
            let size = try await pipeline.export(editedRequest, staging: output, options: ExportOptions(format: .tiff, longEdge: 256))
            try ImagePipeline.verifyExport(output, width: size.0, height: size.1, format: .tiff)
            let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let readback = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
            XCTAssertEqual(readback.width, high.image.width); XCTAssertEqual(readback.height, high.image.height)
            let bounds = CGRect(x: 0, y: 0, width: high.image.width, height: high.image.height)
            var expected16 = [UInt16](repeating: 0, count: high.image.width * high.image.height * 4), actual16 = expected16
            context.render(CIImage(cgImage: high.image), toBitmap: &expected16, rowBytes: high.image.width * 8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
            context.render(CIImage(cgImage: readback), toBitmap: &actual16, rowBytes: high.image.width * 8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
            XCTAssertEqual(expected16, actual16, "TIFF16 无损回读必须匹配质量图")
            XCTAssertGreaterThan(Set(stride(from: 0, to: actual16.count, by: 4).map { actual16[$0] }).count, 256)
            XCTAssertEqual(try SafeFileWriter.sha256(url), digest)
            print("RAW_INPUT file=\(name) decoder=\(baseline.decoderVersion) native=\(result.fullSize) orientation=\(raw.orientation.rawValue) draft=\(draft.image.width)x\(draft.image.height) tiff16=\(size) sha256=\(digest)")
        }
    }

    func testReferenceAndCopyImportsUseTheSameRAWGate() async throws {
        let input = folder.appendingPathComponent("source"), output = folder.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for name in Self.files { try FileManager.default.copyItem(at: Self.sample(name), to: input.appendingPathComponent(name)) }
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("reference-catalog")), importer = ReferenceImporter()
        let candidates = try await importer.preview(source: input, includeSubfolders: true, catalog: catalog)
        XCTAssertEqual(candidates.count, Self.files.count)
        XCTAssertEqual(candidates.filter { $0.problem != nil }.count, 1)
        XCTAssertTrue(candidates.first { $0.problem != nil }?.problem?.contains("Apple DNG") == true)
        let report = await importer.add(source: input, candidates: candidates, collection: nil, catalog: catalog)
        XCTAssertEqual(report.indexed, Self.supportedFiles.count); XCTAssertEqual(report.errors.count, 1)
        let copyCatalog = try CatalogStore(directory: folder.appendingPathComponent("copy-catalog"))
        let plan = try await ImportPlanner().plan(source: input, target: output, layout: .flat, policy: .skip, skipIdentical: true,
            dateOverride: nil, confirmSidecars: false, catalog: copyCatalog)
        XCTAssertEqual(plan.groups.count, Self.files.count)
        let completed = await CopyImporter().run(plan, catalog: copyCatalog, progress: { _ in })
        XCTAssertEqual(completed.state, "completed"); XCTAssertEqual(completed.groups.filter { $0.state == "completed" }.count, Self.supportedFiles.count)
        XCTAssertEqual(completed.groups.filter { $0.state == "needsReview" && !$0.selected }.count, 1)
        XCTAssertEqual(try copyCatalog.photos().count, Self.supportedFiles.count)
        for name in Self.files {
            XCTAssertEqual(try SafeFileWriter.sha256(input.appendingPathComponent(name)), try SafeFileWriter.sha256(Self.sample(name)))
            if Self.supportedFiles.contains(name) { XCTAssertEqual(try SafeFileWriter.sha256(output.appendingPathComponent(name)), try SafeFileWriter.sha256(Self.sample(name))) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path)) }
        }
        let cancelled = Task { () throws -> [ImportCandidate] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.preview(source: input, includeSubfolders: true, catalog: catalog)
        }
        do { _ = try await cancelled.value; XCTFail("取消不能返回可导入结果") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testDisguisedAndDamagedFilesFailBeforeIndexingOrBaseline() async throws {
        let root = StorageRoot(id: "synthetic", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "synthetic")
        let pipeline = ImagePipeline()
        let image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 20, height: 10)), from: CGRect(x: 0, y: 0, width: 20, height: 10)))
        for ext in PhotoFileType.rawTypes.keys.sorted() {
            let url = folder.appendingPathComponent("jpeg-disguised." + ext)
            let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
            XCTAssertThrowsError(try ReferenceImporter.inspect(url: url, root: root, rootURL: folder))
            let identity = try FileIdentity.read(url)
            let photo = Photo(id: ext, rootID: root.id, relativePath: url.lastPathComponent, identity: try JSONEncoder().encode(identity), identityKey: identity.key, width: 20, height: 10)
            do { _ = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil)); XCTFail("伪装文件不能建立 RAW 基线") } catch {}
            try Data("broken raw".utf8).write(to: url)
            XCTAssertThrowsError(try ReferenceImporter.inspect(url: url, root: root, rootURL: folder))
        }
        for name in [Self.files[1], Self.files[3], Self.files[5], Self.files[7]] {
            let bytes = try Data(contentsOf: Self.sample(name))
            let url = folder.appendingPathComponent("truncated-" + name)
            try bytes.prefix(bytes.count / 2).write(to: url)
            XCTAssertThrowsError(try ReferenceImporter.inspect(url: url, root: root, rootURL: folder), "损坏 \(name) 不能退回内嵌 JPEG")
        }
        let renamed = folder.appendingPathComponent("wrong-raw-family.NEF")
        try FileManager.default.copyItem(at: Self.sample(Self.files[1]), to: renamed)
        XCTAssertThrowsError(try ReferenceImporter.inspect(url: renamed, root: root, rootURL: folder))
    }
}
