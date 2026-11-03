import XCTest
import GRDB
import CoreImage
import ImageIO
import SwiftUI
@testable import Phosdeck

final class ExportTests: XCTestCase {
    @MainActor func testBatchRetryUsesRenewedJournalPermissionAndLeavesCompletedOutputsUntouched() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let bookmark = try AccessLease.bookmark(fixture.target, readOnly: false)
        let pipeline = ImagePipeline()
        var snapshots: [ExportSnapshot] = []
        for name in ["completed", "permission", "collision"] {
            let url = fixture.source.appendingPathComponent(name + ".jpg"); try fixture.image(url)
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source)
            try fixture.catalog.index(photo)
            let neutral = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
            let input = ExportSnapshot(id: name, request: ImageRequest(photo: photo, root: root, recipe: neutral),
                destination: fixture.target.appendingPathComponent(name + ".tif"),
                targetBookmark: name == "permission" ? Data("invalid permission".utf8) : bookmark, options: ExportOptions(format: .tiff))
            snapshots.append(try await pipeline.freezeExport(input))
        }
        let foreign = snapshots[2].destination
        try Data("foreign file".utf8).write(to: foreign)
        let service = ExportService(pipeline: pipeline)
        let model = AppModel(); model.catalog = fixture.catalog
        model.reports = await service.run(snapshots, catalog: fixture.catalog, outcome: { model.exportOperationCounts.record($0) }) { _ in }
        let ids = Set(snapshots.map(\.id))
        try model.recordExportResult(ids: ids)
        XCTAssertEqual(model.lastExportResult?.completed, 1)
        XCTAssertEqual(model.lastExportResult?.operationCounts.published, 1)
        XCTAssertEqual(model.lastExportResult?.operationCounts.verified, 0)
        XCTAssertEqual(model.lastExportResult?.retryableIDs, ["permission", "collision"])
        let digest = try SafeFileWriter.sha256(snapshots[0].destination)
        let identity = try FileIdentity.read(snapshots[0].destination)
        var laterEdit = try XCTUnwrap(snapshots[1].request.recipe); laterEdit.exposure = 2
        try fixture.catalog.saveRecipe(id: snapshots[1].request.photo.id, recipe: laterEdit)
        _ = try ExportService.reauthorizeTarget(id: "permission", directory: fixture.target, catalog: fixture.catalog)
        // The result model still holds the old invalid bookmark. Retry must reread the journal.
        model.retryExports(ids: try XCTUnwrap(model.lastExportResult?.retryableIDs))
        await model.task?.value
        XCTAssertNil(model.error); XCTAssertFalse(model.busy)
        XCTAssertEqual(model.lastExportResult?.completed, 2)
        XCTAssertEqual(model.lastExportResult?.retryableIDs, ["collision"])
        XCTAssertEqual(try SafeFileWriter.sha256(snapshots[0].destination), digest)
        XCTAssertEqual(try FileIdentity.read(snapshots[0].destination), identity, "Completed output must not be rewritten or retried")
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "foreign file")
        let recovered = try XCTUnwrap(ExportService.history(catalog: fixture.catalog, ids: ["permission"]).logs.first)
        XCTAssertEqual(recovered.snapshot.destination, snapshots[1].destination)
        XCTAssertEqual(recovered.snapshot.request.recipe, snapshots[1].request.recipe)
        XCTAssertEqual(recovered.snapshot.options, snapshots[1].options)
        model.retryExports(ids: ids)
        await model.task?.value
        XCTAssertEqual(model.reports.count, 1, "Only the still-unfinished collision is retried")
        XCTAssertEqual(model.lastExportResult?.completed, 2)
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE exportItem SET destination='unrelated' WHERE id='collision'") }
        let rejected = try ExportService.history(catalog: fixture.catalog, ids: ["collision"])
        XCTAssertEqual(rejected.rejected.count, 1); XCTAssertTrue(rejected.logs.isEmpty)
        model.retryExports(ids: ["collision"])
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.error)
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "foreign file")
    }
    /// Lightroom's explicit Skip preserves both an intact output and a foreign
    /// collision while still rendering missing members. Native recovery also
    /// verifies content, so the foreign member must be reported as needsReview.
    func testMixedCompletedBatchAfterReopenPreservesConflictsAndContinues() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let bookmark = try AccessLease.bookmark(fixture.target, readOnly: false)
        var snapshots = [ExportSnapshot]()
        for (index, name) in ["workflow-a.jpg", "workflow-b.jpg", "workflow-c.jpg"].enumerated() {
            let source = fixture.source.appendingPathComponent(name)
            try workflowImage(source, index: index)
            let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
            try fixture.catalog.index(photo)
            snapshots.append(ExportSnapshot(id: name, request: ImageRequest(photo: photo, root: root, recipe: nil),
                destination: fixture.target.appendingPathComponent("workflow-\(["a", "b", "c"][index]).tif"),
                targetBookmark: bookmark, options: ExportOptions(format: .tiff)))
        }
        let sourceDigests = try snapshots.map { try SafeFileWriter.sha256(fixture.source.appendingPathComponent($0.request.photo.relativePath)) }
        let service = ExportService(pipeline: ImagePipeline())
        let first = await service.run(snapshots, catalog: fixture.catalog) { _ in }
        XCTAssertEqual(first.filter { $0.hasPrefix("成功：") }.count, 3, "\(first)")
        let original = try Data(contentsOf: snapshots[0].destination)
        let intact = try FileIdentity.read(snapshots[2].destination)
        let intactDigest = try SafeFileWriter.sha256(snapshots[2].destination)
        let foreign = Data("PHOSDECK_R25_FOREIGN_CONFLICT_DO_NOT_OVERWRITE\n".utf8)
        try FileManager.default.removeItem(at: snapshots[0].destination)
        try foreign.write(to: snapshots[1].destination)
        let foreignIdentity = try FileIdentity.read(snapshots[1].destination)
        let catalogURL = fixture.catalog.fileURL
        fixture.catalog = nil
        fixture.catalog = try CatalogStore(fileURL: catalogURL)

        // Put the conflict first: it must not prevent either later member.
        let results = await service.run([snapshots[1], snapshots[0], snapshots[2]], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(results[0].contains("禁止覆盖"), "\(results)")
        XCTAssertTrue(results[1].hasPrefix("成功："), "\(results)")
        XCTAssertTrue(results[2].contains("已核验"), "\(results)")
        XCTAssertEqual(try Data(contentsOf: snapshots[0].destination), original)
        XCTAssertEqual(try Data(contentsOf: snapshots[1].destination), foreign)
        XCTAssertEqual(try FileIdentity.read(snapshots[1].destination), foreignIdentity)
        XCTAssertEqual(try FileIdentity.read(snapshots[2].destination), intact)
        XCTAssertEqual(try SafeFileWriter.sha256(snapshots[2].destination), intactDigest)
        XCTAssertEqual(try snapshots.map { try SafeFileWriter.sha256(fixture.source.appendingPathComponent($0.request.photo.relativePath)) }, sourceDigests)
        let logs = try ExportService.logs(catalog: fixture.catalog)
        XCTAssertEqual(logs.first { $0.id == snapshots[1].id }?.state, "needsReview")
        for index in [0, 2] {
            XCTAssertEqual(logs.first { $0.id == snapshots[index].id }?.state, "completed")
            try ImagePipeline.verifyExport(snapshots[index].destination, width: 640, height: 480, format: .tiff)
        }
    }

    /// Completed output is still an external file: deletion must regenerate it,
    /// replacement must be rejected without overwriting the foreign bytes, and
    /// an intact target must be verifiable after its source goes offline.
    ///
    /// The catalog is closed and reopened at every recovery boundary so this
    /// covers the persisted completed state rather than an in-memory retry.
    func testCompletedExportRecoveryAfterCatalogReopenAcrossFormats() async throws {
        var failures = [String]()
        for format in ExportFormat.allCases {
            let fixture = ImportTests(); try fixture.setUpWithError()
            defer { try? fixture.tearDownWithError() }
            do {
                let source = fixture.source.appendingPathComponent("A.jpg")
                try fixture.image(source)
                let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
                let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
                try fixture.catalog.index(photo)
                let output = fixture.target.appendingPathComponent("completed-" + format.fileExtension)
                let snapshot = ExportSnapshot(
                    id: "completed-" + format.rawValue,
                    request: ImageRequest(photo: photo, root: root, recipe: nil),
                    destination: output,
                    targetBookmark: try AccessLease.bookmark(fixture.target, readOnly: false),
                    options: ExportOptions(format: format, longEdge: 10, quality: 0.9)
                )
                let service = ExportService(pipeline: ImagePipeline())
                let first = await service.run([snapshot], catalog: fixture.catalog) { _ in }
                if !first[0].hasPrefix("成功") { failures.append("\(format) first export: \(first)") }
                guard FileManager.default.fileExists(atPath: output.path) else {
                    failures.append("\(format) first export did not create a target")
                    continue
                }
                let published = try Data(contentsOf: output)
                let publishedDigest = try SafeFileWriter.sha256(output)
                let catalogURL = fixture.catalog.fileURL

                func reopenCatalog() throws {
                    fixture.catalog = nil
                    fixture.catalog = try CatalogStore(fileURL: catalogURL)
                }

                // A completed row must not hide a deleted target after reopening.
                try reopenCatalog()
                try FileManager.default.removeItem(at: output)
                let changed = ExportSnapshot(id: snapshot.id, request: snapshot.request,
                    destination: fixture.target.appendingPathComponent("caller-changed.jpg"),
                    targetBookmark: snapshot.targetBookmark, options: ExportOptions(longEdge: 5, quality: 0.1))
                let regenerated = await service.run([changed], catalog: fixture.catalog) { _ in }
                if !regenerated[0].hasPrefix("成功") { failures.append("\(format) deleted target: \(regenerated)") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: changed.destination.path), "Retry must use the journal's frozen destination")
                if FileManager.default.fileExists(atPath: output.path) {
                    try ImagePipeline.verifyExport(output, width: 10, height: 5, format: format)
                } else {
                    failures.append("\(format) did not regenerate the deleted target")
                    try published.write(to: output)
                }

                // Verify an intact completed target without the source being
                // available. This must remain a completed-row check, before
                // any later conflict can move the task into needsReview.
                try published.write(to: output)
                if try SafeFileWriter.sha256(output) != publishedDigest { failures.append("\(format) fixture digest changed before offline verification") }
                try reopenCatalog()
                try FileManager.default.removeItem(at: source)
                try reopenCatalog()
                let identity = try FileIdentity.read(output)
                let verified = await service.run([snapshot], catalog: fixture.catalog) { _ in }
                if !verified[0].contains("已核验") { failures.append("\(format) offline verification: \(verified)") }
                if try SafeFileWriter.sha256(output) != publishedDigest { failures.append("\(format) verification rewrote output") }
                XCTAssertEqual(try FileIdentity.read(output), identity, "Verification must not rewrite even identical bytes")

                // A completed row must detect a foreign replacement and preserve it.
                try reopenCatalog()
                let foreign = Data("foreign-\(format.rawValue)".utf8)
                try foreign.write(to: output)
                let replaced = await service.run([snapshot], catalog: fixture.catalog) { _ in }
                if !(replaced[0].contains("冲突") || replaced[0].contains("禁止覆盖")) { failures.append("\(format) replacement: \(replaced)") }
                if try Data(contentsOf: output) != foreign { failures.append("\(format) foreign bytes were changed") }
                let log = try XCTUnwrap(ExportService.logs(catalog: fixture.catalog).first)
                XCTAssertEqual(log.state, "needsReview")
                XCTAssertEqual(log.snapshot.destination, output)
                XCTAssertEqual(log.snapshot.options, snapshot.options)
            } catch {
                failures.append("\(format) threw: \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Set PHOSDECK_EXPORT_UI_KEEP=1 to leave one synthetic catalog and three
    /// source photos on disk for a parent-agent native-window inspection.
    func testExportUIFixtureCanBeKeptForNativeInspection() throws {
        let fixture = ImportTests(); try fixture.setUpWithError()
        let keep = ProcessInfo.processInfo.environment["PHOSDECK_EXPORT_UI_KEEP"] == "1"
        defer { if !keep { try? fixture.tearDownWithError() } }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        for (index, name) in ["fixture-a.jpg", "fixture-b.jpg", "fixture-c.jpg"].enumerated() {
            let url = fixture.source.appendingPathComponent(name)
            try workflowImage(url, index: index)
            try fixture.catalog.index(ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source))
        }
        XCTAssertEqual(try fixture.catalog.photos().count, 3)
        if keep {
            fixture.catalog = nil
            print("PHOSDECK_EXPORT_UI_FIXTURE=\(fixture.directory.path)")
        }
    }

    /// Deterministic sRGB JPEG inputs shared with the controlled Lightroom
    /// baseline: gray ramp, colored checks and color patches.
    private func workflowImage(_ url: URL, index: Int) throws {
        let width = 640, height = 480
        let colors: [[UInt8]] = [[0,0,0],[255,255,255],[230,38,38],[38,230,38],
            [38,38,230],[230,230,38],[38,230,230],[230,38,230],
            [128,128,128],[64,64,64],[192,192,192],[150,105,82]]
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            let rgb: [UInt8]
            if index == 0 { let value = UInt8(x * 255 / (width - 1)); rgb = [value, value, value] }
            else if index == 1 { rgb = [UInt8(x * 255 / (width - 1)), UInt8(y * 255 / (height - 1)), (x / 40 + y / 40) % 2 == 0 ? 48 : 208] }
            else { rgb = colors[min(11, (y / 160) * 4 + x / 160)] }
            bytes.replaceSubrange(offset..<(offset + 3), with: rgb)
        }}
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, ExportFormat.jpeg.type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testFrozenExportRetryAndCollision() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let source = fixture.source.appendingPathComponent("A.jpg")
        try fixture.image(source)
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
        try fixture.catalog.index(photo)
        let output = fixture.target.appendingPathComponent("A.jpg")
        let snapshot = ExportSnapshot(id: "e", request: ImageRequest(photo: photo, root: root, recipe: nil), destination: output,
                                      targetBookmark: try AccessLease.bookmark(fixture.target, readOnly: false), options: ExportOptions(longEdge: 10, quality: 0.9))
        let service = ExportService(pipeline: ImagePipeline())
        let reports = await service.run([snapshot], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(reports[0].hasPrefix("成功"), reports[0])
        try ImagePipeline.verifyExport(output, width: 10, height: 5)
        let digest = try SafeFileWriter.sha256(output)
        let retries = await service.run([snapshot], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(retries[0].contains("未重复"))
        XCTAssertEqual(try SafeFileWriter.sha256(output), digest)
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE exportItem SET state='interrupted' WHERE id='e'") }
        let recovered = await service.run([snapshot], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(recovered[0].contains("已核验"))
        try Data("foreign".utf8).write(to: output)
        try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE exportItem SET state='interrupted' WHERE id='e'") }
        let refused = await service.run([snapshot], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(refused[0].contains("禁止覆盖"))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "foreign")
    }
    func testManifestIsReadableAndDoesNotContainBookmarks() throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let source = fixture.source.appendingPathComponent("A.jpg"); try fixture.image(source)
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: Data("secret-bookmark".utf8))
        let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
        try fixture.catalog.index(photo)
        let recipe = EditRecipe(sourceDigest: try SafeFileWriter.sha256(source), decoderVersion: EditRecipe.rasterDecoderVersion, baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        try fixture.catalog.saveRecipe(id: photo.id, recipe: recipe)
        let url = fixture.target.appendingPathComponent("manifest.json")
        try fixture.catalog.exportManifest(to: url)
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let photos = try XCTUnwrap(object["photos"] as? [[String: Any]])
        let jsonRecipe = try XCTUnwrap(photos[0]["recipe"] as? [String: Any])
        XCTAssertEqual(jsonRecipe["temperature"] as? Double, 5500)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("bookmark"))
    }
    func testExportInterruptionsRecoverAndNeverOverwrite() async throws {
        for format in ExportFormat.allCases { for boundary in ["rendering", "verified", "publishedBeforeJournal"] {
            let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
            let source = fixture.source.appendingPathComponent("A.jpg"); try fixture.image(source)
            let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
            let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
            let snapshot = ExportSnapshot(id: "interrupted", request: ImageRequest(photo: photo, root: root, recipe: nil), destination: fixture.target.appendingPathComponent("out." + format.fileExtension), targetBookmark: try AccessLease.bookmark(fixture.target, readOnly: false), options: ExportOptions(format: format, longEdge: 10, quality: 0.9))
            let failed = await ExportService(pipeline: ImagePipeline(), checkpoint: { point in if point == boundary { throw LRCError("injected export interruption") } }).run([snapshot], catalog: fixture.catalog) { _ in }
            XCTAssertFalse(failed[0].hasPrefix("成功"))
            let changed = ExportSnapshot(id: snapshot.id, request: snapshot.request, destination: snapshot.destination,
                targetBookmark: snapshot.targetBookmark, options: ExportOptions(format: .jpeg, longEdge: 5, quality: 0.1))
            let retry = await ExportService(pipeline: ImagePipeline()).run([changed], catalog: fixture.catalog) { _ in }
            XCTAssertTrue(retry[0].hasPrefix("成功") || retry[0].hasPrefix("已核验"), retry[0])
            try ImagePipeline.verifyExport(snapshot.destination, width: 10, height: 5, format: format)
            let log = try ExportService.logs(catalog: fixture.catalog)[0]
            XCTAssertEqual(log.state, "completed")
            XCTAssertEqual(log.snapshot.options, snapshot.options, "Retry uses frozen settings even when the caller changes them")
            if boundary != "publishedBeforeJournal" {
                XCTAssertEqual(log.snapshot.retainedStaging?.count, 1)
                XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(log.snapshot.retainedStaging?.first).path))
            }
            try Data("foreign".utf8).write(to: snapshot.destination)
            try await fixture.catalog.database.write { try $0.execute(sql: "UPDATE exportItem SET state='interrupted' WHERE id='interrupted'") }
            let collision = await ExportService(pipeline: ImagePipeline()).run([snapshot], catalog: fixture.catalog) { _ in }
            XCTAssertTrue(collision[0].contains("禁止覆盖"))
            XCTAssertEqual(try String(contentsOf: snapshot.destination, encoding: .utf8), "foreign")
        } }
    }

    func testLosslessFormatsPreserveDepthOrientationColorAndPrivacy() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let space = ImagePipeline.outputSpace
        var values = [UInt16]()
        for _ in 0..<4 { for x in 0..<1024 {
            let v = UInt16(4000 + x * 55)
            values.append(contentsOf: [v, v, v, 65535])
        } }
        let ci = values.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: 1024*8,
            size: CGSize(width: 1024, height: 4), format: .RGBA16, colorSpace: space) }
        let input = try XCTUnwrap(context.createCGImage(ci, from: ci.extent, format: .RGBA16, colorSpace: space))
        let sourceURL = fixture.source.appendingPathComponent("ramp.tif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(sourceURL as CFURL, ExportFormat.tiff.type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, input, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 120.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fixture", kCGImagePropertyTIFFModel: "Test"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let sourceProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary as String])
        let digest = try SafeFileWriter.sha256(sourceURL)
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: sourceURL, root: root, rootURL: fixture.source)
        let request = ImageRequest(photo: photo, root: root, recipe: nil), pipeline = ImagePipeline()
        for format in ExportFormat.allCases {
            let options = ExportOptions(format: format)
            let output = fixture.target.appendingPathComponent("out." + format.fileExtension)
            let dimensions = try await pipeline.export(request, staging: output, options: options)
            XCTAssertEqual(dimensions.0, 4); XCTAssertEqual(dimensions.1, 1024)
            try ImagePipeline.verifyExport(output, width: 4, height: 1024, format: format)
            XCTAssertThrowsError(try ImagePipeline.verifyExport(output, width: 4, height: 1024, format: format == .jpeg ? .png : .jpeg))
            let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [String: Any])
            XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
            let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFMake as String])
            var data = [UInt16](repeating: 0, count: cg.width*cg.height*4)
            context.render(CIImage(cgImage: cg), toBitmap: &data, rowBytes: cg.width*8,
                bounds: CGRect(x: 0, y: 0, width: cg.width, height: cg.height), format: .RGBA16, colorSpace: space)
            let levels = Set(stride(from: 0, to: data.count, by: 4).map { data[$0] })
            if format == .tiff {
                XCTAssertGreaterThan(levels.count, 1000, "An 8-bit intermediate cannot preserve this ramp")
                XCTAssertEqual(tiff?[kCGImagePropertyTIFFCompression as String] as? Int, 5)
            } else { XCTAssertLessThanOrEqual(levels.count, 256) }
            if format == .png {
                let expected = try await pipeline.render(request, longEdge: nil)
                var original = [UInt16](repeating: 0, count: data.count)
                context.render(CIImage(cgImage: expected.image), toBitmap: &original, rowBytes: cg.width*8,
                    bounds: CGRect(x: 0, y: 0, width: cg.width, height: cg.height), format: .RGBA16, colorSpace: space)
                XCTAssertEqual(data, original, "PNG round-trip is lossless")
            }
        }
        let resized = fixture.target.appendingPathComponent("small.tif")
        let size = try await pipeline.export(request, staging: resized, options: ExportOptions(format: .tiff, longEdge: 512))
        XCTAssertEqual(size.0, 2); XCTAssertEqual(size.1, 512)
        XCTAssertEqual(try SafeFileWriter.sha256(sourceURL), digest)
    }

    func testExportPresetsPersistValidateRenameAndDelete() throws {
        let suite = "export-presets-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = try ExportPreferences.load(from: defaults)
        let options = ExportOptions(format: .tiff, longEdge: 4096, naming: ExportNaming(captureDate: true, prefix: "出片-", sequence: true, start: 42, digits: 6))
        let id = try preferences.storePreset(name: "  精修交接  ", options: options)
        preferences.lastOptions = options
        try preferences.save(to: defaults)
        preferences = try ExportPreferences.load(from: defaults)
        XCTAssertEqual(preferences.lastOptions, options)
        XCTAssertEqual(preferences.presets.first?.name, "精修交接")
        XCTAssertThrowsError(try preferences.storePreset(name: "精修交接", options: options))
        XCTAssertEqual(preferences.presets.count, 1)
        _ = try preferences.storePreset(name: "高质量", options: options, id: id)
        try preferences.save(to: defaults)
        XCTAssertEqual(try ExportPreferences.load(from: defaults).presets.first?.name, "高质量")
        let snapshot = preferences
        for invalid in [ExportOptions(longEdge: 0), ExportOptions(longEdge: 30001), ExportOptions(quality: .nan)] {
            XCTAssertThrowsError(try preferences.storePreset(name: "无效", options: invalid))
            XCTAssertEqual(preferences, snapshot)
        }
        preferences.presets.removeAll { $0.id == id }; try preferences.save(to: defaults)
        XCTAssertTrue(try ExportPreferences.load(from: defaults).presets.isEmpty)
        defaults.set(Data("invalid".utf8), forKey: ExportPreferences.key)
        XCTAssertThrowsError(try ExportPreferences.load(from: defaults))
    }

    @MainActor func testNativeExportSheetsForEachFormat() async throws {
        let suite = "export-ui-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(); model.selection = ["a", "b"]
        for format in ExportFormat.allCases {
            var settings = ExportPreferences(); settings.lastOptions = ExportOptions(format: format, longEdge: 2048)
            _ = try settings.storePreset(name: "我的导出", options: settings.lastOptions)
            try settings.save(to: defaults)
            let host = NSHostingView(rootView: ExportSheet(model: model, defaults: defaults).background(Theme.panel).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
            func sliders(_ view: NSView) -> [NSSlider] { (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap(sliders) }
            XCTAssertEqual(sliders(host).count, format == .jpeg ? 1 : 0, "Lossless exports have no JPEG quality slider")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "export-" + format.rawValue; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testExportReadinessGuidesMissingInputsAndRechecksDestinationConflicts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = Photo(id: "draft", rootID: "root", relativePath: "sample.jpg", identity: Data(), identityKey: "draft", width: 10, height: 10)
        var state = ExportReadiness(loaded: true, photoCount: 1, options: ExportOptions(), namingInputValid: true,
                                    sizeInputValid: true, directory: nil, names: [], previewError: nil,
                                    matteReady: false, matteError: nil, busy: false)
        XCTAssertEqual(state.presetIssue?.section, .image, "Incomplete JPEG presets must not be silently saved")
        state.options.jpegMatte = .white
        XCTAssertNil(state.presetIssue, "Presets contain options, not directory permissions or preview state")
        XCTAssertEqual(state.issue?.section, .destination)
        state.directory = directory
        state.names = try ExportNamingPlanner.preview(photos: [photo], options: state.options, directory: directory)
        XCTAssertEqual(state.issue?.section, .image, "JPEG waits for its actual matte preview")
        state.matteReady = true
        XCTAssertNil(state.issue)
        state.sizeInputValid = false
        XCTAssertEqual(state.issue?.section, .image)
        XCTAssertNotNil(state.presetIssue)
        state.sizeInputValid = true; state.namingInputValid = false
        XCTAssertEqual(state.issue?.section, .naming)
        state.namingInputValid = true
        let existing = directory.appendingPathComponent("sample.jpg")
        try Data("keep existing".utf8).write(to: existing)
        state.names = try ExportNamingPlanner.preview(photos: [photo], options: state.options, directory: directory)
        XCTAssertEqual(state.issue?.section, .review)
        XCTAssertTrue(state.issue?.message.contains("禁止覆盖") == true)
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep existing".utf8))
        state.options.format = .tiff
        state.matteReady = false
        state.names = try ExportNamingPlanner.preview(photos: [photo], options: state.options, directory: directory)
        XCTAssertNil(state.issue, "Lossless formats must not wait for a hidden JPEG preview")
        state.busy = true
        XCTAssertNotNil(state.issue)
    }

    func testReauthorizeExportTargetKeepsFrozenJobAndRejectsRelocation() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let source = fixture.source.appendingPathComponent("authorization.jpg"); try fixture.image(source)
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
        let destination = fixture.target.appendingPathComponent("frozen-0042.tif")
        let snapshot = ExportSnapshot(id: UUID().uuidString, request: ImageRequest(photo: photo, root: root, recipe: nil),
            destination: destination, targetBookmark: Data("unresolvable permission".utf8),
            options: ExportOptions(format: .tiff, naming: ExportNaming(sequence: true, start: 42)))
        let service = ExportService(pipeline: ImagePipeline())
        let failed = await service.run([snapshot], catalog: fixture.catalog) { _ in }
        XCTAssertFalse(failed[0].hasPrefix("成功"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let before = try JSONEncoder().encode(XCTUnwrap(ExportService.logs(catalog: fixture.catalog).first).snapshot)
        XCTAssertThrowsError(try ExportService.reauthorizeTarget(id: snapshot.id, directory: fixture.source, catalog: fixture.catalog))
        let unchanged = try XCTUnwrap(ExportService.logs(catalog: fixture.catalog).first)
        XCTAssertEqual(unchanged.snapshot.targetBookmark, snapshot.targetBookmark)
        XCTAssertEqual(unchanged.state, "failed")
        let renewed = try ExportService.reauthorizeTarget(id: snapshot.id, directory: fixture.target, catalog: fixture.catalog)
        func contentWithoutPermission(_ data: Data) throws -> NSDictionary {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: "targetBookmark")
            return object as NSDictionary
        }
        XCTAssertEqual(try contentWithoutPermission(before), try contentWithoutPermission(JSONEncoder().encode(renewed)))
        XCTAssertEqual(try ExportService.logs(catalog: fixture.catalog).first?.state, "failed", "Renewing permission must not imply successful output")
        let reports = await service.run([renewed], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(reports[0].hasPrefix("成功"), reports.joined(separator: ";"))
        let digest = try SafeFileWriter.sha256(destination)
        let reopened = try ExportService.reauthorizeTarget(id: snapshot.id, directory: fixture.target, catalog: fixture.catalog)
        let verified = await service.run([reopened], catalog: fixture.catalog) { _ in }
        XCTAssertTrue(verified[0].contains("未重复输出"))
        XCTAssertEqual(try SafeFileWriter.sha256(destination), digest)
    }

}
