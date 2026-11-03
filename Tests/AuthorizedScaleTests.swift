import XCTest
import GRDB
import Darwin
@testable import Phosdeck

/// Opt-in only: use app-authorized real-photo COPIES, never discover a private library.
final class AuthorizedScaleTests: XCTestCase {
    struct Request: Codable { let library: StorageRoot; let imported: StorageRoot }
    func testRealLibraryAndBatch() async throws {
        do { try await runAuthorizedBatch() }
        catch let skipped as XCTSkip { throw skipped }
        catch { XCTFail("Real batch failed: " + error.localizedDescription) }
    }
    private func runAuthorizedBatch() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OhMyLRC/ScaleValidation")
        let requestURL = support.appendingPathComponent("request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else { throw XCTSkip("No authorized one-shot large-library request") }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        let run = support.appendingPathComponent("run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: requestURL, to: run.appendingPathComponent("private-request.json"))
        let sourceLease = try AccessLease(bookmark: request.library.bookmark), targetLease = try AccessLease(bookmark: request.imported.bookmark)
        defer { withExtendedLifetime([sourceLease, targetLease]) {} }
        let destination = targetLease.url.appendingPathComponent(".validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let catalog = try CatalogStore(directory: run.appendingPathComponent("catalog"))
        let library = try catalog.addRoot(url: sourceLease.url, bookmark: request.library.bookmark)
        let imported = try catalog.addRoot(url: targetLease.url, bookmark: request.imported.bookmark)
        var metrics: [String: Any] = [:]
        let scanStart = Date()
        let scan = await ReferenceImporter().scan(root: library, catalog: catalog) { _ in }
        metrics["scanSeconds"] = Date().timeIntervalSince(scanStart)
        XCTAssertEqual(scan.indexed, 3000); XCTAssertTrue(scan.errors.isEmpty, scan.errors.joined(separator: ";"))
        print("SCALE first scan complete: \(scan.indexed)")
        let second = await ReferenceImporter().scan(root: library, catalog: catalog) { _ in }
        XCTAssertEqual(second.indexed, 3000); XCTAssertEqual(try catalog.photoCount(), 3000)
        XCTAssertTrue(try catalog.photos().allSatisfy { $0.availability == "available" })
        var pageTimes = [Double](), ids = Set<String>()
        for offset in stride(from: 0, to: 3000, by: 200) {
            let start = Date(), page = try catalog.page(PhotoQuery(scope: library.id), offset: offset)
            pageTimes.append(Date().timeIntervalSince(start)); ids.formUnion(page.photos.map(\.id))
        }
        XCTAssertEqual(ids.count, 3000); metrics["pageSeconds"] = pageTimes
        print("SCALE rescan and 15 pages complete")
        let thumbnails = ThumbnailService()
        try await thumbnails.configure(catalogID: UUID().uuidString, gigabytes: 1)
        let all = try catalog.photos()
        let thumbnailStart = Date()
        for index in stride(from: 0, to: all.count, by: 50) { _ = try await thumbnails.image(photo: all[index], root: library) }
        metrics["sixtyThumbnailsSeconds"] = Date().timeIntervalSince(thumbnailStart)
        metrics["cacheBytes"] = try await thumbnails.usage()
        print("SCALE 60 real thumbnails complete")
        let copyScan = await ReferenceImporter().scan(root: imported, catalog: catalog) { _ in }
        XCTAssertEqual(copyScan.indexed, 301); XCTAssertTrue(copyScan.errors.isEmpty)
        let batch = try catalog.photos().filter { $0.rootID == imported.id }
        try catalog.collection(name: "实拍验证", id: "batch")
        try catalog.membership(ids: batch.map(\.id), collection: "batch", add: true)
        try catalog.setOrganization(ids: batch.map(\.id), rating: 4, flag: 1)
        XCTAssertEqual(try catalog.members("batch").count, 301)
        let pipeline = ImagePipeline()
        var snapshots = [ExportSnapshot](), rss = [UInt64](), previewTimes = [Double]()
        for (index, photo) in batch.enumerated() {
            var recipe: EditRecipe?
            if index < 24 {
                var value = try await pipeline.baseline(ImageRequest(photo: photo, root: imported, recipe: nil))
                value.exposure = 0.5; value.contrast = 1.1; value.saturation = 0.95
                value.quarterTurns = index % 4; value.crop = Crop(x: 0.05, y: 0.1, width: 0.9, height: 0.8)
                try catalog.saveRecipe(id: photo.id, recipe: value); recipe = value
                let preview = try await pipeline.render(ImageRequest(photo: photo, root: imported, recipe: value), longEdge: 2400)
                previewTimes.append(preview.elapsed); rss.append(Self.residentBytes())
            }
            snapshots.append(ExportSnapshot(id: UUID().uuidString, request: ImageRequest(photo: photo, root: imported, recipe: recipe), destination: destination.appendingPathComponent(String(format: "B%03d.jpg", index + 1)), targetBookmark: request.imported.bookmark, options: ExportOptions(longEdge: index < 12 ? nil : 2048, quality: 0.9)))
        }
        metrics["previewSeconds"] = previewTimes; metrics["previewResidentBytes"] = rss
        let exportStart = Date()
        let reports = await ExportService(pipeline: pipeline).run(snapshots, catalog: catalog) { text in print("SCALE " + text) }
        metrics["batchExportSeconds"] = Date().timeIntervalSince(exportStart)
        XCTAssertEqual(reports.filter { $0.hasPrefix("成功：") }.count, 301, reports.filter { !$0.hasPrefix("成功：") }.joined(separator: ";"))
        XCTAssertEqual(try ExportService.logs(catalog: catalog).filter { $0.state == "completed" }.count, 301)
        let outputHashes = try snapshots.map { try SafeFileWriter.sha256($0.destination) }
        let rerun = await ExportService(pipeline: pipeline).run(snapshots, catalog: catalog) { _ in }
        XCTAssertEqual(rerun.filter { $0.hasPrefix("已完成") }.count, 301)
        XCTAssertEqual(try snapshots.map { try SafeFileWriter.sha256($0.destination) }, outputHashes)
        // Later catalog changes do not modify the already frozen output requests.
        if var changed = snapshots[0].request.recipe { changed.exposure = -1; try catalog.saveRecipe(id: batch[0].id, recipe: changed) }
        XCTAssertEqual(try ExportService.logs(catalog: catalog).first { $0.id == snapshots[0].id }?.snapshot.request.recipe?.exposure, 0.5)
        let backup = run.appendingPathComponent("backup.sqlite")
        try catalog.backup(to: backup)
        let restored = try CatalogStore.restore(from: backup, to: run.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.members("batch").count, 301)
        XCTAssertEqual(try restored.photos(ids: Set(batch.map(\.id))).filter { $0.rating == 4 }.count, 301)
        try await thumbnails.clear(); XCTAssertEqual(try restored.photoCount(), 3301)
        metrics["libraryCount"] = 3000; metrics["batchCount"] = 301; metrics["fullSizeExports"] = 12
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        metrics["peakRSSBytes"] = usage.ru_maxrss; metrics["finalResidentBytes"] = Self.residentBytes()
        try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]).write(to: run.appendingPathComponent("metrics.json"))
        print("SCALE_REPORT " + run.path)
    }
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
}
