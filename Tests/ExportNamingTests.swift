import XCTest
import GRDB
@testable import Phosdeck

final class ExportNamingTests: XCTestCase {
    private func photo(_ id: String = "a", path: String = "IMG_001.ARW", date: String? = "2024:02:29 12:34:56") -> Photo {
        Photo(id: id, rootID: "root", relativePath: path, identity: Data(), identityKey: id, captureDate: date, width: 20, height: 10)
    }
    func testPreviewCombinesDateOriginalAffixesAndPaddedSequence() throws {
        let options = ExportOptions(format: .tiff, naming: ExportNaming(captureDate: true, prefix: "旅途-", suffix: "-成片", sequence: true, start: 98, digits: 3))
        let preview = try ExportNamingPlanner.preview(photos: [photo(), photo("b", date: nil), photo("c", date: "2025:02:29")], options: options)
        XCTAssertEqual(preview.map(\.filename), ["旅途-20240229_IMG_001_098-成片.tif", "旅途-undated_IMG_001_099-成片.tif", "旅途-undated_IMG_001_100-成片.tif"])
        XCTAssertEqual(preview.map(\.sequence), [98, 99, 100])
        XCTAssertTrue(preview[0].warnings.isEmpty)
        XCTAssertTrue(preview[1].warnings[0].contains("undated"))
        XCTAssertTrue(preview.allSatisfy { $0.errors.isEmpty })
        XCTAssertEqual(try ExportNamingPlanner.preview(photos: [photo()], options: ExportOptions())[0].filename, "IMG_001.jpg")
        for malformed in ["+123:02:28 12:00:00", "2024:+2:29 12:00:00", "2024:02:+1 12:00:00"] {
            XCTAssertEqual(try ExportNamingPlanner.preview(photos: [photo(date: malformed)], options: ExportOptions(naming: ExportNaming(originalName: false, captureDate: true)))[0].filename, "undated.jpg")
        }
    }
    func testSpecialCharactersUnicodeLengthAndInvalidTemplates() throws {
        let options = ExportOptions(naming: ExportNaming(prefix: " ../", suffix: "\\:*?\"<>|\n. "))
        let name = try ExportNamingPlanner.preview(photos: [photo(path: "中:e\u{301}.ARW")], options: options)[0]
        XCTAssertEqual(name.filename, "_中_é_________.jpg")
        XCTAssertFalse(name.warnings.isEmpty)
        XCTAssertTrue(name.errors.isEmpty)
        let long = try ExportNamingPlanner.preview(photos: [photo(path: String(repeating: "图", count: 80) + ".ARW")], options: ExportOptions())[0]
        XCTAssertTrue(long.errors.contains { $0.contains("240") })
        let valid = try ExportNamingPlanner.preview(photos: [photo(path: String(repeating: "a", count: 236) + ".ARW")], options: ExportOptions())[0]
        XCTAssertTrue(valid.errors.isEmpty)
        for naming in [ExportNaming(originalName: false), ExportNaming(start: -1), ExportNaming(digits: 0), ExportNaming(digits: 10)] {
            XCTAssertThrowsError(try ExportNamingPlanner.preview(photos: [photo()], options: ExportOptions(naming: naming)))
        }
        XCTAssertThrowsError(try ExportNamingPlanner.preview(photos: [photo(), photo("b")], options: ExportOptions(naming: ExportNaming(sequence: true, start: 999_999_999))))
        XCTAssertFalse(try ExportNamingPlanner.preview(photos: [photo(path: "NUL.ARW")], options: ExportOptions())[0].errors.isEmpty)
    }
    func testDuplicateAndExistingConflictsIncludeCaseUnicodeAndBrokenLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photos = [photo(path: "one/É.ARW"), photo("b", path: "two/e\u{301}.tif")]
        let duplicates = try ExportNamingPlanner.preview(photos: photos, options: ExportOptions())
        XCTAssertTrue(duplicates.allSatisfy { $0.errors.contains { $0.contains("同批重名") } })
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("é.JPG").path, withDestinationPath: "/missing-naming-test-file")
        let existing = try ExportNamingPlanner.preview(photos: [photos[0]], options: ExportOptions(), directory: folder)
        XCTAssertTrue(existing[0].errors.contains { $0.contains("已有") })
        let numbered = try ExportNamingPlanner.preview(photos: photos, options: ExportOptions(naming: ExportNaming(sequence: true)), directory: folder)
        XCTAssertTrue(numbered.allSatisfy { $0.errors.isEmpty })
    }
    func testFullSelectionUsesBrowseOrderAcrossPagesAndHeldResults() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let root = try catalog.addRoot(url: folder, bookmark: Data())
        try catalog.database.write { db in
            for i in 0..<1205 {
                var row = photo(String(format: "%04d", i), path: String(format: "IMG_%04d.ARW", i)); row.rootID = root.id
                try row.insert(db)
            }
        }
        let ids = Set(try catalog.photos().map(\.id))
        let query = PhotoQuery(sort: .filename, descending: true)
        let ordered = try catalog.exportPhotos(ids: ids, query: query)
        XCTAssertEqual(ordered.count, 1205)
        XCTAssertEqual(ordered.map(\.id), ids.sorted().reversed())
        let names = try ExportNamingPlanner.preview(photos: ordered, options: ExportOptions(naming: ExportNaming(sequence: true, start: 7)))
        XCTAssertEqual(names.first?.filename, "IMG_1204_0007.jpg")
        XCTAssertEqual(names.last?.filename, "IMG_0000_1211.jpg")
        let held = try catalog.holdResults(query, replacing: nil)
        var heldQuery = query; heldQuery.snapshotID = held; heldQuery.sort = .rating; heldQuery.descending = false
        try catalog.setOrganization(ids: ["0000"], rating: 5, flag: nil)
        XCTAssertEqual(try catalog.exportPhotos(ids: ids, query: heldQuery).map(\.id), ordered.map(\.id))
        XCTAssertThrowsError(try catalog.exportPhotos(ids: ids.union(["missing"]), query: query))
    }
    @MainActor func testSubmissionCancellationReopenRetryKeepsPreviewNamesAndOrder() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        for name in ["A.jpg", "B.jpg", "C.jpg"] {
            let source = fixture.source.appendingPathComponent(name); try fixture.image(source)
            try fixture.catalog.index(ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source))
        }
        let model = AppModel(); model.catalog = fixture.catalog; model.roots = [root]; model.photoSort = .filename; model.sortDescending = true
        model.selection = Set(try fixture.catalog.photos().map(\.id))
        let photos = try model.exportSelection(), options = ExportOptions(format: .png, naming: ExportNaming(sequence: true, start: 40, digits: 5))
        let preview = try ExportNamingPlanner.preview(photos: photos, options: options, directory: fixture.target)
        let snapshots = try model.prepareExport(options: options, photos: photos, names: preview, directory: fixture.target)
        XCTAssertEqual(snapshots.map { $0.destination.lastPathComponent }, ["C_00040.png", "B_00041.png", "A_00042.png"])
        model.sortDescending = false
        XCTAssertEqual(try model.prepareExport(options: options, photos: photos, names: preview, directory: fixture.target).map { $0.destination }, snapshots.map(\.destination))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ExportService(pipeline: ImagePipeline()).run(snapshots, catalog: fixture.catalog) { _ in }
        }
        _ = await cancelled.value
        let cancelledLogs = try ExportService.logs(catalog: fixture.catalog)
        XCTAssertEqual(cancelledLogs.count, 3)
        XCTAssertTrue(cancelledLogs.allSatisfy { $0.state == "cancelled" })
        let catalogURL = fixture.catalog.fileURL
        model.catalog = nil; fixture.catalog = nil
        fixture.catalog = try CatalogStore(fileURL: catalogURL)
        let restored = try ExportService.logs(catalog: fixture.catalog).map { log in
            ExportSnapshot(id: log.id, request: log.snapshot.request, destination: fixture.target.appendingPathComponent("changed-" + log.id + ".jpg"), targetBookmark: log.snapshot.targetBookmark, options: ExportOptions(naming: ExportNaming(sequence: true, start: 999)))
        }
        let reports = await ExportService(pipeline: ImagePipeline()).run(restored, catalog: fixture.catalog) { _ in }
        XCTAssertEqual(reports.filter { $0.hasPrefix("成功") }.count, 3, reports.joined(separator: ";"))
        for snapshot in snapshots {
            let log = try XCTUnwrap(ExportService.logs(catalog: fixture.catalog).first { $0.id == snapshot.id })
            XCTAssertEqual(log.snapshot.destination, snapshot.destination)
            XCTAssertEqual(log.snapshot.options, options)
            try ImagePipeline.verifyExport(snapshot.destination, width: 20, height: 10, format: .png)
        }
    }
    func testOldOptionsAreRejectedWithoutChangingStoredBytes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportOptions())) as? [String: Any])
        object.removeValue(forKey: "naming")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ExportOptions.self, from: old))
        let suite = "naming-options-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = try JSONSerialization.data(withJSONObject: ["lastOptions": object, "presets": []])
        defaults.set(preferences, forKey: ExportPreferences.key)
        XCTAssertThrowsError(try ExportPreferences.load(from: defaults))
        XCTAssertEqual(defaults.data(forKey: ExportPreferences.key), preferences)
    }
    func testConflictCreatedAfterPreviewFailsWithoutRenamingOrOverwriting() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let source = fixture.source.appendingPathComponent("A.jpg"); try fixture.image(source)
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: source, root: root, rootURL: fixture.source)
        let name = try ExportNamingPlanner.preview(photos: [photo], options: ExportOptions(), directory: fixture.target)[0]
        XCTAssertTrue(name.errors.isEmpty)
        let target = fixture.target.appendingPathComponent(name.filename)
        let snapshot = ExportSnapshot(id: UUID().uuidString, request: ImageRequest(photo: photo, root: root, recipe: nil), destination: target, targetBookmark: try AccessLease.bookmark(fixture.target, readOnly: false), options: ExportOptions())
        let reports = await ExportService(pipeline: ImagePipeline(), checkpoint: { point in
            if point == "verified" { try Data("late conflict".utf8).write(to: target) }
        }).run([snapshot], catalog: fixture.catalog) { _ in }
        XCTAssertFalse(reports[0].hasPrefix("成功"))
        XCTAssertEqual(try Data(contentsOf: target), Data("late conflict".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).filter { !$0.hasPrefix(".phosdeck-") }, ["A.jpg"])
        XCTAssertEqual(try ExportService.logs(catalog: fixture.catalog)[0].state, "failed")
    }
}
