import XCTest
import CoreImage
import ImageIO
import GRDB
@testable import Phosdeck

final class ExportMetadataTests: XCTestCase {
    /// Inspect the encoded container, without asking ImageIO to generate a
    /// thumbnail (that API returns full images on the tested OS).
    private func hasEmbeddedThumbnail(_ data: Data, format: ExportFormat) throws -> Bool {
        let bytes = [UInt8](data)
        var tiffs = [[UInt8]]()
        if format == .tiff { tiffs.append(bytes) }
        if format == .jpeg {
            var cursor = 2
            while cursor + 4 <= bytes.count {
                guard bytes[cursor] == 255 else { throw LRCError("Malformed JPEG fixture") }
                let marker = bytes[cursor + 1]
                if marker == 0xda || marker == 0xd9 { break }
                let length = Int(bytes[cursor + 2]) * 256 + Int(bytes[cursor + 3])
                guard length >= 2, cursor + 2 + length <= bytes.count else { throw LRCError("Malformed JPEG segment") }
                let payload = Array(bytes[(cursor + 4)..<(cursor + 2 + length)])
                if marker == 0xe1, payload.starts(with: [69, 120, 105, 102, 0, 0]) { tiffs.append(Array(payload.dropFirst(6))) }
                cursor += length + 2
            }
        }
        if format == .png {
            var cursor = 8
            while cursor + 12 <= bytes.count {
                let length = bytes[cursor..<(cursor + 4)].reduce(0) { $0 * 256 + Int($1) }
                guard length <= bytes.count - cursor - 12 else { throw LRCError("Malformed PNG chunk") }
                if Array(bytes[(cursor + 4)..<(cursor + 8)]) == [101, 88, 73, 102] { tiffs.append(Array(bytes[(cursor + 8)..<(cursor + 8 + length)])) }
                cursor += length + 12
            }
        }
        for tiff in tiffs {
            guard tiff.count >= 8, Array(tiff.prefix(2)) == [73, 73] || Array(tiff.prefix(2)) == [77, 77] else { throw LRCError("Malformed TIFF header") }
            let little = tiff[0] == 73
            func integer(_ offset: Int, _ count: Int) throws -> Int {
                guard offset >= 0, offset <= tiff.count - count else { throw LRCError("Truncated TIFF directory") }
                let parts = Array(tiff[offset..<(offset + count)])
                return (little ? Array(parts.reversed()) : parts).reduce(0) { $0 * 256 + Int($1) }
            }
            XCTAssertEqual(try integer(2, 2), 42)
            let offset = try integer(4, 4), entries = try integer(offset, 2)
            for index in 0..<entries {
                let tag = try integer(offset + 2 + index * 12, 2)
                if [330, 513, 514].contains(tag) { return true }
            }
            if try integer(offset + 2 + entries * 12, 4) != 0 { return true }
        }
        return false
    }
    private func source(_ fixture: ImportTests) throws -> (Photo, StorageRoot, URL) {
        let url = fixture.source.appendingPathComponent("metadata.tif")
        var values = [UInt16]()
        for _ in 0..<16 { for x in 0..<1024 { let v = UInt16(4000 + x * 55); values.append(contentsOf: [v, v, v, 65535]) } }
        let ci = values.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: 1024*8, size: CGSize(width: 1024, height: 16), format: .RGBA16, colorSpace: ImagePipeline.outputSpace) }
        let cg = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent, format: .RGBA16, colorSpace: ImagePipeline.outputSpace))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, ExportFormat.tiff.type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test Make", kCGImagePropertyTIFFModel: "Test Model", kCGImagePropertyTIFFArtist: "PRIVATE-ARTIST"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensMake: "Test Lens Make", kCGImagePropertyExifLensModel: "Test Lens Model", kCGImagePropertyExifDateTimeOriginal: "2024:02:29 23:58:59",
                kCGImagePropertyExifISOSpeedRatings: [640], kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 1.0/125, kCGImagePropertyExifFocalLength: 50.5,
                kCGImagePropertyExifPixelXDimension: 9999, kCGImagePropertyExifPixelYDimension: 8888, kCGImagePropertyExifColorSpace: 65535,
                kCGImagePropertyExifBodySerialNumber: "PRIVATE-BODY-SERIAL", kCGImagePropertyExifLensSerialNumber: "PRIVATE-LENS-SERIAL",
                kCGImagePropertyExifUserComment: "PRIVATE-SOURCE-PATH-RECIPE", kCGImagePropertyExifMakerNote: Data("PRIVATE-MAKER-NOTES".utf8)],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 120.0, kCGImagePropertyGPSLongitudeRef: "E"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source)
        try fixture.catalog.index(photo)
        return (photo, root, url)
    }
    private func snapshot(_ photo: Photo, _ root: StorageRoot, _ fixture: ImportTests, format: ExportFormat, policy: ExportMetadataPolicy) throws -> ExportSnapshot {
        ExportSnapshot(id: UUID().uuidString, request: ImageRequest(photo: photo, root: root, recipe: nil), destination: fixture.target.appendingPathComponent(UUID().uuidString + "." + format.fileExtension),
                       targetBookmark: try AccessLease.bookmark(fixture.target, readOnly: false), options: ExportOptions(format: format, metadataPolicy: policy))
    }
    func testAllFormatsReadBackAllowedFieldsAndOutputGeometryWithoutPrivateMetadata() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let (photo, root, url) = try source(fixture), digest = try SafeFileWriter.sha256(url), pipeline = ImagePipeline()
        let input = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let inputProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [String: Any])
        XCTAssertNotNil(inputProps[kCGImagePropertyGPSDictionary as String])
        XCTAssertNotNil((inputProps[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifBodySerialNumber as String])
        for format in ExportFormat.allCases { for policy in ExportMetadataPolicy.allCases {
            var plan = try snapshot(photo, root, fixture, format: format, policy: policy)
            plan = try await pipeline.freezeExport(plan)
            XCTAssertEqual(plan.request.photo.digest, digest)
            let reports = await ExportService(pipeline: pipeline).run([plan], catalog: fixture.catalog) { _ in }
            XCTAssertTrue(reports[0].hasPrefix("成功"), "\(format)/\(policy): \(reports)")
            try ImagePipeline.verifyExport(plan.destination, width: 16, height: 1024, format: format, metadata: plan.metadata)
            let output = try XCTUnwrap(CGImageSourceCreateWithURL(plan.destination as CFURL, nil))
            XCTAssertFalse(try hasEmbeddedThumbnail(Data(contentsOf: plan.destination), format: format))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [String: Any])
            let actual = ExportMetadata.capture(from: props)
            if policy.includesCapture {
                XCTAssertEqual(actual, plan.metadata)
                XCTAssertEqual(actual.cameraMake, "Test Make"); XCTAssertEqual(actual.cameraModel, "Test Model")
                XCTAssertEqual(actual.lensModel, "Test Lens Model"); XCTAssertEqual(actual.capturedAt, "2024:02:29 23:58:59")
                XCTAssertEqual(actual.iso, 640); XCTAssertEqual(try XCTUnwrap(actual.aperture), 2.8, accuracy: 0.000001)
                XCTAssertEqual(actual.exposureTime, 1.0/125); XCTAssertEqual(actual.focalLength, 50.5)
                let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
                XCTAssertEqual(exif[kCGImagePropertyExifPixelXDimension as String] as? Int, 16)
                XCTAssertEqual(exif[kCGImagePropertyExifPixelYDimension as String] as? Int, 1024)
                XCTAssertEqual(exif[kCGImagePropertyExifColorSpace as String] as? Int, 1)
            } else {
                XCTAssertNil(actual.cameraModel); XCTAssertNil(actual.lensModel); XCTAssertNil(actual.capturedAt); XCTAssertNil(actual.iso)
                XCTAssertEqual(plan.metadata, ExportMetadata())
            }
            let data = try Data(contentsOf: plan.destination)
            for marker in ["PRIVATE-", "http://ns.adobe.com/xap/", fixture.source.path] {
                XCTAssertNil(data.range(of: Data(marker.utf8)), "Source metadata must never be bulk copied")
            }
            if format == .tiff {
                let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(output, 0, nil))
                var pixels = [UInt16](repeating: 0, count: cg.width * cg.height * 4)
                CIContext().render(CIImage(cgImage: cg), toBitmap: &pixels, rowBytes: cg.width * 8, bounds: CGRect(x: 0, y: 0, width: cg.width, height: cg.height), format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
                XCTAssertGreaterThan(Set(stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }).count, 1000)
            }
        } }
        for format in ExportFormat.allCases {
            var plan = try snapshot(photo, root, fixture, format: format, policy: .capture)
            let options = ExportOptions(format: format, longEdge: 512, metadataPolicy: .capture)
            plan = ExportSnapshot(id: plan.id, request: plan.request, destination: plan.destination, targetBookmark: plan.targetBookmark, options: options)
            plan = try await pipeline.freezeExport(plan)
            _ = try await pipeline.export(plan.request, staging: plan.destination, options: plan.options, metadata: plan.metadata)
            try ImagePipeline.verifyExport(plan.destination, width: 8, height: 512, format: format, metadata: plan.metadata)
        }
        XCTAssertEqual(try SafeFileWriter.sha256(url), digest)
    }
    func testSourceChangedAfterFreezeIsRejectedWithoutRecapturingMetadata() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let (photo, root, url) = try source(fixture), pipeline = ImagePipeline()
        let plan = try await pipeline.freezeExport(snapshot(photo, root, fixture, format: .tiff, policy: .capture))
        try Data("changed synthetic source".utf8).write(to: url)
        let reports = await ExportService(pipeline: pipeline).run([plan], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(reports[0].contains("来源被替换或修改"), reports.joined())
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        XCTAssertEqual(try ExportService.logs(catalog: fixture.catalog)[0].snapshot.metadata, plan.metadata)
    }
    func testEmbeddedSourceThumbnailAndXMPAreExcludedFromAllFormats() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let (_, root, _) = try source(fixture)
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 640))
        let image = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
        let sourceURL = fixture.source.appendingPathComponent("thumbnail-xmp.jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(sourceURL as CFURL, ExportFormat.jpeg.type.identifier as CFString, 1, nil))
        CGImageDestinationSetProperties(dest, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, "PRIVATE-XMP-RECIPE" as CFString))
        CGImageDestinationAddImageAndMetadata(dest, image, metadata, [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        // This ImageIO encoder ignores the embedding request above. Construct a
        // minimal EXIF IFD1 with a real JPEG thumbnail, retaining the source XMP.
        let thumbData = NSMutableData()
        let thumbDest = try XCTUnwrap(CGImageDestinationCreateWithData(thumbData, ExportFormat.jpeg.type.identifier as CFString, 1, nil))
        let small = ci.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
        let smallImage = try XCTUnwrap(CIContext().createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
        CGImageDestinationAddImage(thumbDest, smallImage, nil); XCTAssertTrue(CGImageDestinationFinalize(thumbDest))
        var tiff = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0, 0, 0, 14, 0, 0, 0, 2, 0])
        func append16(_ value: UInt16) { tiff.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)]) }
        func append32(_ value: UInt32) { tiff.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
        append16(0x0201); append16(4); append32(1); append32(44)
        append16(0x0202); append16(4); append32(1); append32(UInt32(thumbData.length)); append32(0)
        XCTAssertEqual(tiff.count, 44)
        var payload = Data("Exif\0\0".utf8); payload.append(tiff); payload.append(thumbData as Data)
        let length = payload.count + 2
        var jpeg = Data([0xff, 0xd8, 0xff, 0xe1, UInt8(length >> 8), UInt8(length & 255)])
        jpeg.append(payload); jpeg.append(try Data(contentsOf: sourceURL).dropFirst(2))
        try jpeg.write(to: sourceURL)
        XCTAssertNotNil(try Data(contentsOf: sourceURL).range(of: Data("PRIVATE-XMP-RECIPE".utf8)))
        XCTAssertTrue(try hasEmbeddedThumbnail(Data(contentsOf: sourceURL), format: .jpeg), "Fixture must actually embed a thumbnail")
        let photo = try ReferenceImporter.inspect(url: sourceURL, root: root, rootURL: fixture.source), pipeline = ImagePipeline()
        let digest = try SafeFileWriter.sha256(sourceURL)
        for format in ExportFormat.allCases { for policy in [ExportMetadataPolicy.capture, .captureAndDescription] {
            var draft = try snapshot(photo, root, fixture, format: format, policy: policy)
            if policy.includesDescription { draft.metadata.descriptive = ExportDescription(caption: "只保留本机题注", keywords: ["本机关键词"]) }
            let plan = try await pipeline.freezeExport(draft)
            _ = try await pipeline.export(plan.request, staging: plan.destination, options: plan.options, metadata: plan.metadata)
            XCTAssertFalse(try hasEmbeddedThumbnail(Data(contentsOf: plan.destination), format: format))
            XCTAssertNil(try Data(contentsOf: plan.destination).range(of: Data("PRIVATE-XMP-RECIPE".utf8)))
            XCTAssertEqual(plan.metadata.omitted.count, 7)
        } }
        XCTAssertEqual(try SafeFileWriter.sha256(sourceURL), digest)
    }
    func testMissingInvalidAndNonfiniteFieldsAreOmittedWithoutInventingDates() throws {
        let metadata = ExportMetadata.capture(from: [kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "bad\nmodel"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2025:02:29 25:00:00", kCGImagePropertyExifFNumber as String: Double.nan,
                kCGImagePropertyExifISOSpeedRatings as String: [640.5], kCGImagePropertyExifExposureTime as String: -1, kCGImagePropertyExifFocalLength as String: Double.infinity]])
        XCTAssertNil(metadata.cameraModel); XCTAssertNil(metadata.capturedAt); XCTAssertNil(metadata.iso)
        XCTAssertNil(metadata.aperture); XCTAssertNil(metadata.exposureTime); XCTAssertNil(metadata.focalLength)
        XCTAssertEqual(metadata.omitted.count, 7)
        XCTAssertTrue(metadata.summary.contains("无有效拍摄字段"))
        XCTAssertThrowsError(try metadata.validate(policy: .none))
        XCTAssertThrowsError(try ExportMetadata(aperture: .nan).validate(policy: .capture))
    }
    func testCancelledReopenAndRetryUseFrozenMetadataAndPolicyForEveryFormat() async throws {
        for format in ExportFormat.allCases {
            let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
            let (photo, root, _) = try source(fixture), pipeline = ImagePipeline()
            let plan = try await pipeline.freezeExport(snapshot(photo, root, fixture, format: format, policy: .capture))
            let cancelled = await Task { await ExportService(pipeline: pipeline, checkpoint: { boundary in
                if boundary == "verified" { withUnsafeCurrentTask { $0?.cancel() } }
            }).run([plan], catalog: fixture.catalog) { _ in } }.value
            XCTAssertFalse(cancelled[0].hasPrefix("成功"))
            XCTAssertEqual(try ExportService.logs(catalog: fixture.catalog)[0].state, "cancelled")
            let file = fixture.catalog.fileURL; fixture.catalog = nil; fixture.catalog = try CatalogStore(fileURL: file)
            try await fixture.catalog.database.write { db in
                try db.execute(sql: "UPDATE photo SET camera='changed', captureDate=NULL, metadata=NULL")
            }
            let changed = try snapshot(photo, root, fixture, format: .jpeg, policy: .none)
            let tampered = ExportSnapshot(id: plan.id, request: changed.request, destination: changed.destination, targetBookmark: changed.targetBookmark, options: changed.options)
            let reports = await ExportService(pipeline: pipeline).run([tampered], catalog: fixture.catalog) { _ in }
            XCTAssertTrue(reports[0].hasPrefix("成功"), reports.joined())
            let saved = try XCTUnwrap(ExportService.logs(catalog: fixture.catalog).first)
            XCTAssertEqual(saved.snapshot.metadata, plan.metadata); XCTAssertEqual(saved.snapshot.options, plan.options)
            try ImagePipeline.verifyExport(plan.destination, width: 16, height: 1024, format: format, metadata: plan.metadata)
            XCTAssertFalse(FileManager.default.fileExists(atPath: changed.destination.path))
        }
    }
    func testPolicySettingsPersistAndUnsupportedSnapshotsStayUntouched() throws {
        let suite = "export-metadata-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ExportPreferences(); preferences.lastOptions.metadataPolicy = .capture
        try preferences.save(to: defaults)
        XCTAssertEqual(try ExportPreferences.load(from: defaults), preferences)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportOptions())) as? [String: Any])
        old.removeValue(forKey: "metadataPolicy")
        XCTAssertThrowsError(try JSONDecoder().decode(ExportOptions.self, from: JSONSerialization.data(withJSONObject: old)))
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let bytes = Data("{\"oldTask\":true}".utf8)
        try fixture.catalog.database.write { db in try db.execute(sql: "INSERT INTO exportItem (id,snapshot,state,destination) VALUES ('unsupported',?,'cancelled','unused')", arguments: [bytes]) }
        let history = try ExportService.history(catalog: fixture.catalog)
        XCTAssertTrue(history.logs.isEmpty); XCTAssertEqual(history.rejected.count, 1)
        XCTAssertEqual(try fixture.catalog.database.read { try Data.fetchOne($0, sql: "SELECT snapshot FROM exportItem WHERE id='unsupported'") }, bytes)
    }
    func testMetadataReadBackRejectsUnexpectedFieldsAndStaleStructuralValues() throws {
        let tinyExposure = ExportMetadata.capture(from: [kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifExposureTime as String: 1e-8]])
        XCTAssertThrowsError(try ExportMetadata.verify([kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifExposureTime as String: 0.0,
            kCGImagePropertyExifPixelXDimension as String: 20, kCGImagePropertyExifPixelYDimension as String: 10, kCGImagePropertyExifColorSpace as String: 1]], width: 20, height: 10, expected: tinyExposure), "An unrepresentable positive value must not silently round to zero within the absolute tolerance")
        XCTAssertThrowsError(try ExportMetadata.verify([kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifBodySerialNumber as String: "serial"]], width: 20, height: 10, expected: nil))
        XCTAssertThrowsError(try ExportMetadata.verify([kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifPixelXDimension as String: 999]], width: 20, height: 10, expected: nil))
        XCTAssertThrowsError(try ExportMetadata.verify([:], width: 20, height: 10, expected: ExportMetadata(cameraModel: "missing")))
        XCTAssertThrowsError(try ExportMetadata.verify([kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFModel as String: "unselected"]], width: 20, height: 10, expected: ExportMetadata()))
    }
}

extension ExportMetadataTests {
    func testDescriptiveMetadataUnicodeAllFormatsPoliciesAndPixelIdentity() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let (photo, root, sourceURL) = try source(fixture), pipeline = ImagePipeline()
        let digest = try SafeFileWriter.sha256(sourceURL)
        let description = ExportDescription(caption: "中文 café & <夕阳> 🌅\n第二行\t末尾", keywords: ["旅行", "海 & 山", "café", "🌅"])
        for format in ExportFormat.allCases {
            var originalPixels: Data?
            for policy in ExportMetadataPolicy.allCases {
                var plan = try snapshot(photo, root, fixture, format: format, policy: policy)
                if policy.includesDescription { plan.metadata.descriptive = description }
                plan = try await pipeline.freezeExport(plan)
                let result = await ExportService(pipeline: pipeline).run([plan], catalog: fixture.catalog) { _ in }
                XCTAssertTrue(result.first?.hasPrefix("成功") == true, result.joined())
                guard FileManager.default.fileExists(atPath: plan.destination.path) else { continue }
                try ImagePipeline.verifyExport(plan.destination, width: 16, height: 1024, format: format, metadata: plan.metadata)
                let src = try XCTUnwrap(CGImageSourceCreateWithURL(plan.destination as CFURL, nil))
                let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
                let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
                XCTAssertEqual(iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String ?? "", policy.includesDescription ? description.caption : "")
                XCTAssertEqual(iptc[kCGImagePropertyIPTCKeywords as String] as? [String] ?? [], policy.includesDescription ? description.keywords : [])
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
                var pixels = [UInt16](repeating: 0, count: image.width * image.height * 4)
                CIContext().render(CIImage(cgImage: image), toBitmap: &pixels, rowBytes: image.width * 8,
                    bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
                let bytes = pixels.withUnsafeBytes { Data($0) }
                if let originalPixels { XCTAssertEqual(bytes, originalPixels, "Description must not change \(format) pixels") }
                else { originalPixels = bytes }
                XCTAssertNil(try Data(contentsOf: plan.destination).range(of: Data("PRIVATE-".utf8)))
            }
        }
        XCTAssertEqual(try SafeFileWriter.sha256(sourceURL), digest)
    }
    @MainActor func testDescriptionsFrozenAtSubmissionForSingleMultiAndRetry() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let (photo, _, _) = try source(fixture), pipeline = ImagePipeline()
        let model = AppModel(); model.catalog = fixture.catalog; try model.reload(); model.selection = [photo.id]
        _ = try fixture.catalog.setCaptions([photo.id: "提交时的题注"])
        _ = try fixture.catalog.changeKeywords(["冻结关键词"], ids: [photo.id], adding: true)
        let options = ExportOptions(format: .tiff, metadataPolicy: .description)
        let names = try ExportNamingPlanner.preview(photos: [photo], options: options, directory: fixture.target)
        let prepared = try XCTUnwrap(model.prepareExport(options: options, photos: [photo], names: names, directory: fixture.target).first)
        let specs = [ExportSpecification(id: "info", title: "描述", subfolder: "info", options: options),
                     ExportSpecification(id: "clean", title: "干净", subfolder: "clean", options: ExportOptions(format: .png))]
        let (_, multiple) = try model.prepareMultiExport(specifications: specs, directory: fixture.target, photos: [photo])
        XCTAssertEqual(multiple[0].metadata.descriptive, prepared.metadata.descriptive)
        XCTAssertTrue(multiple[1].metadata.descriptive.isEmpty)
        _ = try fixture.catalog.setCaptions([photo.id: "之后改的题注"])
        _ = try fixture.catalog.changeKeywords(["新关键词"], ids: [photo.id], adding: true)
        let frozen = try await pipeline.freezeExport(prepared)
        XCTAssertEqual(frozen.metadata.descriptive.caption, "提交时的题注")
        XCTAssertEqual(frozen.metadata.descriptive.keywords, ["冻结关键词"])
        _ = await Task { await ExportService(pipeline: pipeline, checkpoint: { phase in
            if phase == "verified" { withUnsafeCurrentTask { $0?.cancel() } }
        }).run([frozen], catalog: fixture.catalog) { _ in } }.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: frozen.destination.path))
        let log = try XCTUnwrap(ExportService.logs(catalog: fixture.catalog).first)
        XCTAssertEqual(log.state, "cancelled")
        var tampered = frozen; tampered.metadata.descriptive = ExportDescription(caption: "不能替换冻结值", keywords: [])
        let result = await ExportService(pipeline: pipeline).run([tampered], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(result[0].hasPrefix("成功"), result.joined())
        try ImagePipeline.verifyExport(frozen.destination, width: 16, height: 1024, format: .tiff, metadata: frozen.metadata)
        XCTAssertEqual(try ExportService.logs(catalog: fixture.catalog).first?.snapshot.metadata.descriptive, frozen.metadata.descriptive)
    }
    func testDescriptiveVerificationRejectsExtraOrMissingFieldsAndOldFrozenStructure() throws {
        let expected = ExportMetadata(descriptive: ExportDescription(caption: "描述", keywords: ["关键词"]))
        XCTAssertThrowsError(try ExportMetadata.verify([:], width: 1, height: 1, expected: expected))
        XCTAssertThrowsError(try ExportMetadata.verify([kCGImagePropertyIPTCDictionary as String: [kCGImagePropertyIPTCCaptionAbstract as String: "描述", kCGImagePropertyIPTCKeywords as String: ["关键词"], kCGImagePropertyIPTCByline as String: "PRIVATE"]], width: 1, height: 1, expected: expected))
        XCTAssertThrowsError(try expected.validate(policy: .none))
        XCTAssertThrowsError(try expected.validate(policy: .capture))
        XCTAssertNoThrow(try expected.validate(policy: .description))
        XCTAssertThrowsError(try ExportDescription(caption: "bad\0", keywords: []).validate())
        XCTAssertThrowsError(try ExportDescription(caption: "", keywords: ["Cafe", "CAFE"]).validate())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportMetadata())) as? [String: Any])
        json.removeValue(forKey: "descriptive")
        XCTAssertThrowsError(try JSONDecoder().decode(ExportMetadata.self, from: JSONSerialization.data(withJSONObject: json)), "Do not upgrade old frozen tasks")
    }
}

extension ExportMetadataTests {
    func testExtraXMPFieldsCannotPassDescriptionVerification() throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 4)
        let image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .blue), from: bounds))
        let wanted = ExportDescription(caption: "已选择的题注", keywords: ["关键词"])
        for path in ["xmp:Label", "dc:rights", "exif:BodySerialNumber"] {
            let metadata = CGImageMetadataCreateMutableCopy(try XCTUnwrap(wanted.imageMetadata()))!
            XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, "PRIVATE" as CFString))
            let file = fixture.target.appendingPathComponent(UUID().uuidString + ".png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, ExportFormat.png.type.identifier as CFString, 1, nil))
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertThrowsError(try wanted.verifyEmbedded(in: source), "Must reject \(path), even when caption and keywords match")
        }
    }
}

extension ExportMetadataTests {
    func testLongCaptionAndEmptyDescriptionRoundTripWithoutTruncation() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let (photo, root, _) = try source(fixture), pipeline = ImagePipeline()
        for format in ExportFormat.allCases {
            for description in [ExportDescription(), ExportDescription(caption: String(repeating: "字", count: 2000), keywords: [String(repeating: "词", count: 100)])] {
                var plan = try snapshot(photo, root, fixture, format: format, policy: .description)
                plan.metadata.descriptive = description
                plan = try await pipeline.freezeExport(plan)
                let result = await ExportService(pipeline: pipeline).run([plan], catalog: fixture.catalog) { _ in }
                XCTAssertTrue(result[0].hasPrefix("成功"), "\(format): \(result)")
                if FileManager.default.fileExists(atPath: plan.destination.path) {
                    try ImagePipeline.verifyExport(plan.destination, width: 16, height: 1024, format: format, metadata: plan.metadata)
                }
            }
        }
    }
}
