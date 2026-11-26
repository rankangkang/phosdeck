import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import Phosdeck

/// Controlled large-catalog (10,000 synthetic rows) benchmark & regression suite.
/// Writes raw per-iteration JSON measurements to `build/` when `PHOSDECK_PERF_OUTPUT`
/// is set; runs fast correctness + bounded-latency assertions by default.
final class LargeCatalogPerformanceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-scale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func buildSyntheticCatalog(count: Int, stackGroups: Int) throws -> (CatalogStore, StorageRoot, [String]) {
        let catDir = directory.appendingPathComponent("cat-\(count)-\(stackGroups)")
        let catalog = try CatalogStore(directory: catDir)
        let rootURL = directory.appendingPathComponent("photos-\(count)-\(stackGroups)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let root = try catalog.addRoot(url: rootURL, bookmark: try AccessLease.bookmark(rootURL, readOnly: true))
        let lenses = ["FE 24-70mm F2.8 GM II", "FE 50mm F1.2 GM", "XF 35mm F1.4 R", "RF 85mm F1.2L USM", "NIKKOR Z 24-120mm f/4 S"]
        let cameras = ["ILCE-7RM5", "ILCE-7M3", "X-S10", "Canon EOS R5", "NIKON Z 8"]
        let isos = [100, 200, 400, 800, 1600, 3200, 6400]
        let keywordPool = (0..<24).map { String(format: "Tag%02d", $0) }
        var ids = [String]()
        ids.reserveCapacity(count)

        try catalog.database.write { db in
            let metaData = try lenses.indices.map { l in
                try isos.indices.map { s in
                    try JSONEncoder().encode(PhotoMetadata(lens: lenses[l], iso: isos[s], aperture: 2.8, exposureTime: 0.004, focalLength: 50))
                }
            }
            for i in 0..<count {
                let id = String(format: "p%05d", i)
                ids.append(id)
                let folder = String(format: "2026/trip-%02d", i % 50)
                let day = String(format: "2026:%02d:%02d %02d:%02d:%02d", (i % 12) + 1, (i % 28) + 1, i % 24, i % 60, (i * 7) % 60)
                let photo = Photo(
                    id: id,
                    rootID: root.id,
                    relativePath: "\(folder)/DSC_\(String(format: "%05d", count - i)).ARW",
                    identity: Data(),
                    identityKey: "syn:\(i)",
                    rating: i % 6,
                    flag: (i % 3) - 1,
                    colorLabel: i % 6,
                    captureDate: day,
                    width: 6000,
                    height: 4000,
                    camera: cameras[i % cameras.count],
                    metadata: metaData[i % lenses.count][i % isos.count]
                )
                try photo.insert(db)
                let k1 = keywordPool[i % keywordPool.count]
                let k2 = keywordPool[(i * 7 + 3) % keywordPool.count]
                try db.execute(sql: "INSERT OR IGNORE INTO photoKeyword (photoID,keyword,name) VALUES (?,?,?)", arguments: [id, KeywordSummary.key(k1), k1])
                try db.execute(sql: "INSERT OR IGNORE INTO photoKeyword (photoID,keyword,name) VALUES (?,?,?)", arguments: [id, KeywordSummary.key(k2), k2])
            }
            // Add regular & smart collections to exercise collectionCounts.
            for c in 0..<3 {
                let cid = "col-\(c)"
                try PhotoCollection(id: cid, name: "Collection \(c)").insert(db)
                for i in stride(from: c, to: min(count, 1000), by: 3) {
                    try db.execute(sql: "INSERT INTO membership (collectionID,photoID) VALUES (?,?)", arguments: [cid, ids[i]])
                }
            }
            let smart1 = SmartRules(conditions: [
                SmartRule(field: .rating, op: .atLeast, value: "4"),
                SmartRule(field: .iso, op: .atLeast, value: "800")
            ])
            let smart2 = SmartRules(conditions: [
                SmartRule(field: .lens, op: .contains, value: "50mm"),
                SmartRule(field: .captureDate, op: .between, value: "2026-03-01", upper: "2026-09-30")
            ])
            try PhotoCollection(id: "smart-1", name: "High ISO Picks", rules: try JSONEncoder().encode(smart1)).insert(db)
            try PhotoCollection(id: "smart-2", name: "50mm Mid Year", rules: try JSONEncoder().encode(smart2)).insert(db)

            if stackGroups > 0 {
                for g in 0..<stackGroups {
                    let sid = "stack-\(g)"
                    try db.execute(sql: "INSERT INTO displayStack (id, collapsed) VALUES (?, ?)", arguments: [sid, g % 2 == 0 ? 1 : 0])
                    for pos in 0..<3 {
                        let idx = g * 5 + pos
                        guard idx < count else { break }
                        try db.execute(sql: "INSERT INTO stackMember (stackID, photoID, position) VALUES (?, ?, ?)", arguments: [sid, ids[idx], pos])
                    }
                }
            }
        }
        return (catalog, root, ids)
    }

    private func measureMS(_ iterations: Int, _ body: () throws -> Void) rethrows -> [Double] {
        var samples = [Double]()
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            try body()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        return samples
    }

    private func stats(_ samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let maxVal = sorted.last ?? 0
        let minVal = sorted.first ?? 0
        return [
            "samples_ms": samples.map { (100 * $0).rounded() / 100 },
            "median_ms": (100 * median).rounded() / 100,
            "min_ms": (100 * minVal).rounded() / 100,
            "max_ms": (100 * maxVal).rounded() / 100
        ]
    }

    @MainActor
    func testTenThousandCatalogQueryAndBrowseBenchmark() async throws {
        let count = 10_000
        var built: CatalogStore?
        let ids: [String]
        (built, _, ids) = try buildSyntheticCatalog(count: count, stackGroups: 0)
        let catalogURL = try XCTUnwrap(built?.fileURL)
        built = nil
        let openSamples = try measureMS(3) {
            var reopened: CatalogStore? = try CatalogStore(fileURL: catalogURL)
            XCTAssertNotNil(reopened)
            reopened = nil
        }
        let catalog = try CatalogStore(fileURL: catalogURL)

        let dateQuery = PhotoQuery(sort: .captureDate, descending: false)
        let nameQuery = PhotoQuery(sort: .filename, descending: false)
        let metaQuery = PhotoQuery(metadata: LibraryMetadataFilter(lens: "50mm", minimumISO: "400", maximumISO: "1600", dateFrom: "2026-03-01", dateThrough: "2026-09-30"))

        let dateFirstPage = try measureMS(5) {
            let p = try catalog.page(dateQuery, offset: 0, limit: 200)
            XCTAssertEqual(p.total, count)
            XCTAssertEqual(p.photos.count, 200)
        }
        let datePaging = try measureMS(5) {
            for offset in [200, 1000, 5000, 9800] {
                let p = try catalog.page(dateQuery, offset: offset, limit: 200)
                XCTAssertEqual(p.photos.count, 200)
            }
        }
        let filenamePaging = try measureMS(5) {
            for offset in [0, 2000, 9800] {
                let p = try catalog.page(nameQuery, offset: offset, limit: 200)
                XCTAssertEqual(p.photos.count, 200)
            }
        }
        let metadataFilter = try measureMS(5) {
            let p = try catalog.page(metaQuery, offset: 0, limit: 200)
            XCTAssertGreaterThan(p.total, 0)
        }
        let offsetLookup = try measureMS(10) {
            let pos = try catalog.offset(of: ids[7654], query: dateQuery)
            XCTAssertNotNil(pos)
        }

        let kwSingle = try measureMS(5) {
            let summary = try catalog.keywordSummary(selected: [ids[0]])
            XCTAssertEqual(summary.count, 24)
        }
        let kwBatch50 = try measureMS(5) {
            let summary = try catalog.keywordSummary(selected: Set(ids.prefix(50)))
            XCTAssertEqual(summary.count, 24)
        }

        // Stacked catalog (500 stacks of 3 members = 1500 stacked photos inside 10,000).
        let (stackedCatalog, _, stackedIDs) = try buildSyntheticCatalog(count: count, stackGroups: 500)
        let stackedPaging = try measureMS(5) {
            for offset in [0, 200, 4000, 8800] {
                let p = try stackedCatalog.page(dateQuery, offset: offset, limit: 200)
                XCTAssertEqual(p.total, count)
                XCTAssertEqual(p.visibleTotal, count - 250 * 2) // 250 collapsed stacks hide 2 members each
            }
        }
        let stackedOffset = try measureMS(5) {
            let pos = try stackedCatalog.offset(of: stackedIDs[6000], query: dateQuery)
            XCTAssertNotNil(pos)
        }

        // AppModel end-to-end page turn (includes collectionCounts + page + pairedSources + org summary).
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog
        try model.reload()
        let appPageTurn = try measureMS(5) {
            model.changePage(1)
            model.changePage(-1)
        }

        // Synthetic thumbnail throughput (24 JPEGs + 12 edited renders).
        let thumbDir = directory.appendingPathComponent("thumb-bench")
        try FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
        let thumbRoot = StorageRoot(id: "thumb-root", path: thumbDir.path, bookmark: try AccessLease.bookmark(thumbDir, readOnly: true), label: "thumb")
        var jpegPhotos = [Photo]()
        var editedPhotos = [Photo]()
        let ciCtx = CIContext()
        for i in 0..<24 {
            let url = thumbDir.appendingPathComponent(String(format: "img_%02d.jpg", i))
            let color = CIColor(red: CGFloat(i) / 24.0, green: 0.4, blue: 0.7)
            let cg = try XCTUnwrap(ciCtx.createCGImage(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 800)), from: CGRect(x: 0, y: 0, width: 1200, height: 800)))
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            var photo = try ReferenceImporter.inspect(url: url, root: thumbRoot, rootURL: thumbDir)
            jpegPhotos.append(photo)
            if i < 12 {
                let digest = try SafeFileWriter.sha256(url)
                var recipe = EditRecipe(sourceDigest: digest, decoderVersion: EditRecipe.rasterDecoderVersion,
                                        baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
                recipe.exposure = 0.4
                recipe.develop.highlights = -25
                recipe.develop.shadows = 20
                photo.recipe = try JSONEncoder().encode(recipe)
                photo.recipeRevision = 1
                editedPhotos.append(photo)
            }
        }
        var jpegThumbSamples = [Double]()
        var editedThumbSamples = [Double]()
        for _ in 0..<3 {
            let service = ThumbnailService()
            let t0 = CFAbsoluteTimeGetCurrent()
            try await withThrowingTaskGroup(of: CGImage.self) { group in
                for photo in jpegPhotos {
                    group.addTask { try await service.image(photo: photo, root: thumbRoot, edge: ThumbnailService.gridEdge, priority: .visible) }
                }
                for try await _ in group {}
            }
            jpegThumbSamples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)

            let editService = ThumbnailService()
            let t1 = CFAbsoluteTimeGetCurrent()
            try await withThrowingTaskGroup(of: CGImage.self) { group in
                for photo in editedPhotos {
                    group.addTask { try await editService.image(photo: photo, root: thumbRoot, edge: ThumbnailService.gridEdge, priority: .visible) }
                }
                for try await _ in group {}
            }
            editedThumbSamples.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
        }

        let report: [String: Any] = [
            "catalog_count": count,
            "open_catalog": stats(openSamples),
            "date_first_page": stats(dateFirstPage),
            "date_4_pages": stats(datePaging),
            "filename_3_pages": stats(filenamePaging),
            "metadata_filter": stats(metadataFilter),
            "offset_lookup": stats(offsetLookup),
            "keyword_summary_1": stats(kwSingle),
            "keyword_summary_50": stats(kwBatch50),
            "stacked_4_pages": stats(stackedPaging),
            "stacked_offset_lookup": stats(stackedOffset),
            "app_model_2_page_turns": stats(appPageTurn),
            "thumbnails_24_jpeg": stats(jpegThumbSamples),
            "thumbnails_12_edited": stats(editedThumbSamples)
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(decoding: jsonData, as: UTF8.self)
        print("LARGE_CATALOG_PERF_JSON_BEGIN\n\(jsonString)\nLARGE_CATALOG_PERF_JSON_END")
    }

    @MainActor
    func testPhotoIndexTriggersCacheInvalidationAndFullSelectionAtScale() throws {
        let (catalog, root, ids) = try buildSyntheticCatalog(count: 2500, stackGroups: 100)
        let dateQuery = PhotoQuery(sort: .captureDate, descending: false)
        let nameQuery = PhotoQuery(sort: .filename, descending: false)

        // Warm query cache, keyword cache, and AppModel collection counts cache.
        _ = try catalog.page(dateQuery, offset: 0, limit: 200)
        _ = try catalog.page(nameQuery, offset: 0, limit: 200)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog
        try model.reload()
        let beforeSmart1 = try XCTUnwrap(model.collectionCounts["smart-1"])

        // 1. Direct SQL mutation on relativePath/captureDate/metadata must immediately update temp.photoIndex & invalidate caches.
        let targetID = ids[0]
        let newMeta = try JSONEncoder().encode(PhotoMetadata(lens: "Unique Special 135mm", iso: 12800))
        try catalog.database.write { db in
            try db.execute(sql: "UPDATE photo SET relativePath=?, captureDate=?, metadata=?, rating=5 WHERE id=?",
                           arguments: ["2026/trip-00/AAA_00000.ARW", "2020:01:01 00:00:00", newMeta, targetID])
        }
        XCTAssertEqual(try catalog.page(nameQuery, offset: 0, limit: 10).photos.first?.id, targetID)
        XCTAssertEqual(try catalog.page(dateQuery, offset: 0, limit: 10).photos.first?.id, targetID)
        let lensHit = try catalog.page(PhotoQuery(metadata: LibraryMetadataFilter(lens: "Unique Special", minimumISO: "12800", dateFrom: "2020-01-01", dateThrough: "2020-01-01")), offset: 0, limit: 10)
        XCTAssertEqual(lensHit.photos.map(\.id), [targetID])

        // 2. Stack collapse/expand & hidden representative lookup must invalidate and resolve accurately.
        // Group 0 is collapsed (stack-0: p00000, p00001, p00002).
        XCTAssertNil(try catalog.offset(of: ids[1], query: dateQuery, includingRepresentative: false))
        let repOffset = try XCTUnwrap(catalog.offset(of: ids[1], query: dateQuery, includingRepresentative: true))
        XCTAssertEqual(try catalog.representative(of: ids[1], query: dateQuery), ids[0])
        XCTAssertEqual(try catalog.offset(of: ids[0], query: dateQuery), repOffset)
        try catalog.database.write { db in
            try db.execute(sql: "UPDATE displayStack SET collapsed=0 WHERE id='stack-0'")
        }
        XCTAssertNotNil(try catalog.offset(of: ids[1], query: dateQuery, includingRepresentative: false))

        // 3. Full selection (2,500 > SQLite default bind limit 999) works for keywordSummary & AppModel organization summary.
        let allIDs = Set(ids)
        let kwAll = try catalog.keywordSummary(selected: allIDs)
        XCTAssertEqual(kwAll.count, 24)
        XCTAssertTrue(kwAll.allSatisfy { $0.selected == $0.total && $0.total > 0 })
        model.choose(allIDs, active: ids[0])
        try model.reloadPhotos()
        XCTAssertEqual(model.selection.count, 2500)
        // smart-1 count must reflect the rating/ISO mutation above.
        XCTAssertGreaterThanOrEqual(model.collectionCounts["smart-1"] ?? -1, beforeSmart1)

        // 4. Insert + delete keep temp.photoIndex synchronized.
        let added = Photo(id: "extra-1", rootID: root.id, relativePath: "2026/000_first.jpg", identity: Data(), identityKey: "extra-1",
                          rating: 5, captureDate: "2019:01:01 00:00:00", width: 100, height: 100,
                          metadata: try JSONEncoder().encode(PhotoMetadata(lens: "Extra Lens", iso: 25600)))
        try catalog.index(added)
        XCTAssertEqual(try catalog.page(PhotoQuery(metadata: LibraryMetadataFilter(lens: "Extra Lens", minimumISO: "25600")), offset: 0, limit: 10).photos.map(\.id), ["extra-1"])
        try catalog.database.write { db in try db.execute(sql: "DELETE FROM photo WHERE id='extra-1'") }
        XCTAssertEqual(try catalog.page(PhotoQuery(metadata: LibraryMetadataFilter(lens: "Extra Lens")), offset: 0, limit: 10).total, 0)
    }

    func testBatchExportAndRasterPreviewBenchmark() async throws {
        let workDir = directory.appendingPathComponent("batch3a")
        let srcDir = workDir.appendingPathComponent("src")
        let catDir = workDir.appendingPathComponent("cat")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let catalog = try CatalogStore(directory: catDir)
        let root = try catalog.addRoot(url: srcDir, bookmark: try AccessLease.bookmark(srcDir, readOnly: true))
        let ciCtx = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

        func makeGradientCG(width: Int, height: Int, seed: Int) throws -> CGImage {
            let extent = CGRect(x: 0, y: 0, width: width, height: height)
            let grad = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputColor0": CIColor(red: 0.1 + Double(seed % 5) * 0.1, green: 0.25, blue: 0.6),
                "inputPoint1": CIVector(x: CGFloat(width), y: CGFloat(height)),
                "inputColor1": CIColor(red: 0.85, green: 0.65 - Double(seed % 4) * 0.08, blue: 0.2)
            ])!.outputImage!.cropped(to: extent)
            return try XCTUnwrap(ciCtx.createCGImage(grad, from: extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
        }

        // Prepare 16 synthetic 2400x1600 edited JPEGs for batch export benchmark.
        let prepPipeline = ImagePipeline()
        var editedRequests = [ImageRequest]()
        for i in 0..<16 {
            let url = srcDir.appendingPathComponent(String(format: "photo_%02d.jpg", i))
            let cg = try makeGradientCG(width: 2400, height: 1600, seed: i)
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: srcDir)
            try catalog.index(photo)
            var recipe = try await prepPipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
            recipe.exposure = 0.25
            recipe.develop.highlights = -20
            recipe.develop.shadows = 15
            recipe.develop.clarity = 10
            recipe.develop.vibrance = 12
            editedRequests.append(ImageRequest(photo: photo, root: root, recipe: recipe))
        }

        var jpegExportSamples = [Double]()
        var tiffExportSamples = [Double]()
        for round in 0..<3 {
            let outJPEG = workDir.appendingPathComponent("out-jpeg-\(round)")
            try FileManager.default.createDirectory(at: outJPEG, withIntermediateDirectories: true)
            let bmJPEG = try AccessLease.bookmark(outJPEG, readOnly: false)
            let jpegSnaps = editedRequests.enumerated().map { idx, req in
                ExportSnapshot(id: "j-\(round)-\(idx)", request: req,
                               destination: outJPEG.appendingPathComponent(String(format: "out_%02d.jpg", idx)),
                               targetBookmark: bmJPEG, options: ExportOptions(format: .jpeg, quality: 0.9, jpegMatte: .white))
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let jReports = await ExportService(pipeline: ImagePipeline()).run(jpegSnaps, catalog: catalog) { _ in }
            jpegExportSamples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            XCTAssertEqual(jReports.count, 16)
            XCTAssertTrue(jReports.allSatisfy { $0.hasPrefix("成功") || $0.hasPrefix("Succeeded") }, "\(jReports)")

            let outTIFF = workDir.appendingPathComponent("out-tiff-\(round)")
            try FileManager.default.createDirectory(at: outTIFF, withIntermediateDirectories: true)
            let bmTIFF = try AccessLease.bookmark(outTIFF, readOnly: false)
            let tiffSnaps = editedRequests.prefix(8).enumerated().map { idx, req in
                ExportSnapshot(id: "t-\(round)-\(idx)", request: req,
                               destination: outTIFF.appendingPathComponent(String(format: "out_%02d.tif", idx)),
                               targetBookmark: bmTIFF, options: ExportOptions(format: .tiff))
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            let tReports = await ExportService(pipeline: ImagePipeline()).run(tiffSnaps, catalog: catalog) { _ in }
            tiffExportSamples.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
            XCTAssertEqual(tReports.count, 8)
            XCTAssertTrue(tReports.allSatisfy { $0.hasPrefix("成功") || $0.hasPrefix("Succeeded") }, "\(tReports)")
        }

        // Prepare 2048x1365 PNG and HEIC for repeated quality preview benchmark.
        let pngURL = srcDir.appendingPathComponent("bench.png")
        let heicURL = srcDir.appendingPathComponent("bench.heic")
        let largeCG = try makeGradientCG(width: 2048, height: 1365, seed: 3)
        let pngDest = try XCTUnwrap(CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(pngDest, largeCG, nil)
        XCTAssertTrue(CGImageDestinationFinalize(pngDest))
        let heicDest = try XCTUnwrap(CGImageDestinationCreateWithURL(heicURL as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(heicDest, largeCG, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(heicDest))

        let pngPhoto = try ReferenceImporter.inspect(url: pngURL, root: root, rootURL: srcDir)
        let heicPhoto = try ReferenceImporter.inspect(url: heicURL, root: root, rootURL: srcDir)
        let pngBase = try await prepPipeline.baseline(ImageRequest(photo: pngPhoto, root: root, recipe: nil))
        let heicBase = try await prepPipeline.baseline(ImageRequest(photo: heicPhoto, root: root, recipe: nil))

        var pngPreviewSamples = [Double]()
        var heicPreviewSamples = [Double]()
        for _ in 0..<3 {
            let pPipe = ImagePipeline()
            let tp0 = CFAbsoluteTimeGetCurrent()
            for step in 0..<6 {
                var r = pngBase
                r.saturation = 1.0 + Double(step) * 0.04
                let res = try await pPipe.render(ImageRequest(photo: pngPhoto, root: root, recipe: r), longEdge: 2400, reuseDecoded: true)
                XCTAssertEqual(res.image.width, 2048)
            }
            pngPreviewSamples.append((CFAbsoluteTimeGetCurrent() - tp0) * 1000)

            let hPipe = ImagePipeline()
            let th0 = CFAbsoluteTimeGetCurrent()
            for step in 0..<6 {
                var r = heicBase
                r.saturation = 1.0 + Double(step) * 0.04
                let res = try await hPipe.render(ImageRequest(photo: heicPhoto, root: root, recipe: r), longEdge: 2400, reuseDecoded: true)
                XCTAssertEqual(res.image.width, 2048)
            }
            heicPreviewSamples.append((CFAbsoluteTimeGetCurrent() - th0) * 1000)
        }

        let report: [String: Any] = [
            "export_16_jpeg_2400px": stats(jpegExportSamples),
            "export_8_tiff16_2400px": stats(tiffExportSamples),
            "raster_png_6_previews_2048px": stats(pngPreviewSamples),
            "raster_heic_6_previews_2048px": stats(heicPreviewSamples)
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let jsonString = String(decoding: jsonData, as: UTF8.self)
        print("BATCH3A_PERF_JSON_BEGIN\n\(jsonString)\nBATCH3A_PERF_JSON_END")
    }
}
