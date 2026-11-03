import XCTest
import GRDB
import CoreImage
@testable import Phosdeck

final class CatalogQueryTests: XCTestCase {
    func testRatingComparisonsAndSavedSmartRulesAtEveryBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        try catalog.database.write { db in
            for rating in 0...5 {
                try Photo(id: "r\(rating)", rootID: root.id, relativePath: "\(rating).jpg", identity: Data(), identityKey: "rating:\(rating)", rating: rating, width: 1, height: 1).insert(db)
            }
        }
        for comparison in RatingComparison.allCases {
            for threshold in 0...5 {
                let expected = (0...5).filter { rating in
                    switch comparison {
                    case .atLeast: rating >= threshold
                    case .atMost: rating <= threshold
                    case .equal: rating == threshold
                    case .greaterThan: rating > threshold
                    case .lessThan: rating < threshold
                    }
                }.map { "r\($0)" }
                let query = PhotoQuery(ratingThreshold: threshold, ratingComparison: comparison)
                XCTAssertEqual(try catalog.page(query, offset: 0).photos.map(\.id), expected, "\(comparison) \(threshold)")
                let rules = try SmartRules.from(query)
                let decoded = try JSONDecoder().decode(SmartRules.self, from: JSONEncoder().encode(rules))
                try decoded.validate()
                XCTAssertEqual(try catalog.page(PhotoQuery(smart: decoded), offset: 0).photos.map(\.id), expected)
            }
        }
    }

    func testPagedFilteringStableOrderAndCrossPageSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        try catalog.collection(name: "selection", id: "c")
        try catalog.database.write { db in
            for i in 0..<1205 {
                let photo = Photo(id: String(format: "%04d", i), rootID: root.id, relativePath: "folder/IMG_\(String(format: "%04d", i)).ARW", identity: Data(), identityKey: "fixture:\(i)", rating: i % 6, flag: i % 3 - 1, captureDate: "2026:09:26", width: 9504, height: 6336)
                try photo.insert(db)
            }
        }
        var seen = [String]()
        for offset in stride(from: 0, to: 1205, by: 200) {
            let page = try catalog.page(PhotoQuery(), offset: offset)
            XCTAssertEqual(page.total, 1205)
            XCTAssertLessThanOrEqual(page.photos.count, 200)
            seen += page.photos.map(\.id)
        }
        XCTAssertEqual(Set(seen).count, 1205)
        XCTAssertEqual(seen, seen.sorted())
        XCTAssertEqual(try catalog.page(PhotoQuery(), offset: 99999).offset, 1200)
        XCTAssertEqual(try catalog.offset(of: "0401", query: PhotoQuery()), 401)
        XCTAssertEqual(try catalog.page(PhotoQuery(search: "IMG_000%"), offset: 0).total, 0, "LIKE wildcards are literal")
        XCTAssertEqual(try catalog.page(PhotoQuery(search: "folder"), offset: 0).total, 0, "name filter excludes parent folders")
        XCTAssertEqual(try catalog.page(PhotoQuery(scope: "folder:\(root.id):folder"), offset: 0).total, 1205)
        try catalog.membership(ids: ["0001", "0401", "1204"], collection: "c", add: true)
        XCTAssertEqual(try catalog.page(PhotoQuery(scope: "collection:c"), offset: 0).photos.map(\.id), ["0001", "0401", "1204"])
        try catalog.setOrganization(ids: ["0001", "0401", "1204"], rating: 5, flag: 1)
        XCTAssertEqual(try catalog.photos(ids: ["0001", "0401", "1204"]).map(\.rating), [5, 5, 5])
        XCTAssertTrue(try catalog.page(PhotoQuery(ratingThreshold: 5, flags: [1]), offset: 0).photos.allSatisfy { $0.rating == 5 && $0.flag == 1 })
    }
    func testCropDragClampsAndUsesBottomLeftCoordinates() {
        let crop = PhotoCanvas.rectangle(from: CGPoint(x: 80, y: 10), to: CGPoint(x: 20, y: 60), size: CGSize(width: 100, height: 100))
        XCTAssertEqual(crop.x, 0.2, accuracy: 0.00001)
        XCTAssertEqual(crop.y, 0.4, accuracy: 0.00001)
        XCTAssertEqual(crop.width, 0.6, accuracy: 0.00001)
        XCTAssertEqual(crop.height, 0.5, accuracy: 0.00001)
        let outside = PhotoCanvas.rectangle(from: .zero, to: CGPoint(x: 999, y: 999), size: CGSize(width: 100, height: 100))
        XCTAssertEqual(outside, Crop())
    }
    func testHistogramReflectsRenderedPixels() throws {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let white = CIImage(color: .white).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64)).composited(over: black)
        let image = try XCTUnwrap(CIContext().createCGImage(white, from: white.extent))
        let histogram = try XCTUnwrap(ImageHistogram.calculate(image))
        for channel in histogram.channels {
            XCTAssertEqual(channel.reduce(0, +), 65536)
            XCTAssertGreaterThan(channel[0], 30000); XCTAssertGreaterThan(channel[255], 30000)
        }
    }
    func testFailedOrganizationTransactionKeepsAllConfirmedValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        for id in ["a", "b"] { try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".ARW", identity: Data(), identityKey: id, width: 1, height: 1)) }
        try catalog.setOrganization(ids: ["a", "b"], rating: 4)
        try catalog.database.write { try $0.execute(sql: "CREATE TRIGGER fail_organization BEFORE UPDATE ON photo WHEN NEW.id='b' BEGIN SELECT RAISE(ABORT,'injected save failure'); END") }
        XCTAssertThrowsError(try catalog.setOrganization(ids: ["a", "b"], rating: 1))
        XCTAssertEqual(try catalog.photos().map(\.rating), [4, 4])
    }
}

extension CatalogQueryTests {
    func testFlagSetFilterUsesAnySelectedStateAndEmptyMeansAll() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        try catalog.database.write { db in
            for (index, flag) in [-1, 0, 1, -1, 0, 1].enumerated() {
                try Photo(id: String(index), rootID: root.id, relativePath: "\(index).jpg",
                          identity: Data(), identityKey: "flag-\(index)", rating: 0, flag: flag,
                          width: 1, height: 1).insert(db)
            }
        }
        func ids(_ flags: Set<Int>) throws -> Set<String> {
            Set(try catalog.page(PhotoQuery(flags: flags), offset: 0, limit: 100).photos.map(\.id))
        }
        XCTAssertEqual(try ids([]), Set((0..<6).map(String.init)), "Empty flag selection must not constrain the query")
        XCTAssertEqual(try ids([1]), ["2", "5"])
        XCTAssertEqual(try ids([0, -1]), ["0", "1", "3", "4"], "Multiple flag states use OR/IN semantics")
        XCTAssertEqual(try ids([-1, 0, 1]), Set((0..<6).map(String.init)), "All three states are equivalent to no flag filter")
    }

    func testUnicodeFilenameOrderFollowsUpstreamScalarLowercase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let catalog = try CatalogStore(directory:directory), root = try catalog.addRoot(url:directory,bookmark:Data())
        for (i,name) in ["ÄZ.jpg","äa.jpg","Z.jpg","az.jpg"].enumerated() {
            try catalog.index(Photo(id:String(i),rootID:root.id,relativePath:name,identity:Data(),identityKey:String(i),width:1,height:1))
        }
        let expected = ["az.jpg","Z.jpg","äa.jpg","ÄZ.jpg"]
        for descending in [false,true] {
            let query = PhotoQuery(sort:.filename,descending:descending)
            XCTAssertEqual(try catalog.page(query,offset:0).photos.map(\.name),descending ? Array(expected.reversed()) : expected)
        }
        try catalog.database.read { db in
            let a = try String.fetchOne(db,sql:"SELECT photo_filename_key(?)",arguments:["Ärger.jpg"])
            let b = try String.fetchOne(db,sql:"SELECT photo_filename_key(?)",arguments:["ärger.jpg"])
            XCTAssertEqual(a,b,"Pinned upstream cmp_name_ignores_case_without_allocating vector")
        }
    }
    @MainActor func testHeldSnapshotSourceRemovalUndoNewMatchesAndLastPage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let catalog = try CatalogStore(directory:directory), root = try catalog.addRoot(url:directory.appendingPathComponent("source"),bookmark:Data())
        let other = try catalog.addRoot(url:directory.appendingPathComponent("other"),bookmark:Data())
        try catalog.collection(name:"held",id:"held"); try catalog.collection(name:"copy",id:"copy")
        try catalog.database.write { db in
            for i in 0..<406 {
                let id = String(format:"%04d",i)
                try Photo(id:id,rootID:root.id,relativePath:"folder/\(id).jpg",identity:Data(),identityKey:id,
                    rating:i == 405 ? 0 : 5,width:1,height:1,metadata:Data("{}".utf8)).insert(db)
            }
        }
        try catalog.membership(ids:(0..<406).map { String(format:"%04d",$0) },collection:"held",add:true)
        let model = AppModel(previewRenderer: { _,_,_ in throw LRCError("synthetic") })
        model.catalog = catalog; model.scope = "collection:held"; model.ratingThreshold = 5
        model.photoSort = .rating; model.sortDescending = true; model.holdFilterResults = true
        model.undo.groupsByEvent = false; try model.reload()
        let held = try catalog.page(model.query,offset:0,limit:1000).photos.map(\.id)
        try catalog.setOrganization(ids:["0000"],rating:0)
        try catalog.setOrganization(ids:["0405"],rating:5)
        XCTAssertEqual(try catalog.page(model.query,offset:0,limit:1000).photos.map(\.id),held,
            "Freeze members AND order; later matches are admitted only on refresh")
        model.choose(["0199","0404"],active:"0199")
        model.undo.beginUndoGrouping(); model.membership("held",add:false); model.undo.endUndoGrouping()
        XCTAssertEqual(model.resultCount,403); XCTAssertFalse(model.selection.contains("0199"))
        XCTAssertTrue(model.photos.contains { $0.id == model.activeID })
        XCTAssertEqual(try catalog.resultIDs(model.query,within:["0199","0404"]),[])
        XCTAssertThrowsError(try catalog.exportPhotos(ids:["0199"],query:model.query))
        XCTAssertEqual(try catalog.collectResults(model.query,collection:"copy"),403)
        XCTAssertEqual(try catalog.page(model.query,offset:99999).offset,400)
        model.undo.undo()
        XCTAssertEqual(try catalog.page(model.query,offset:0,limit:1000).photos.map(\.id),held)
        XCTAssertEqual(try catalog.offset(of:"0404",query:model.query),404)
        model.undo.redo(); XCTAssertNil(try catalog.offset(of:"0404",query:model.query))
        model.undo.undo()
        var folder = PhotoQuery(scope:"folder:\(root.id):folder",ratingThreshold:5)
        folder.snapshotID = try catalog.holdResults(folder,replacing:nil)
        var source = PhotoQuery(scope:root.id,ratingThreshold:5)
        source.snapshotID = try catalog.holdResults(source,replacing:nil)
        try catalog.database.write { db in
            try db.execute(sql:"UPDATE photo SET relativePath='elsewhere/a.jpg' WHERE id='0001'")
            try db.execute(sql:"UPDATE photo SET rootID=? WHERE id='0002'",arguments:[other.id])
            try db.execute(sql:"DELETE FROM membership WHERE photoID='0003'")
            try db.execute(sql:"DELETE FROM photo WHERE id='0003'")
        }
        XCTAssertEqual(try catalog.resultIDs(folder,within:["0001","0002","0003"]),[])
        XCTAssertEqual(try catalog.resultIDs(source,within:["0001","0002","0003"]),["0001"])
        model.refreshResults()
        XCTAssertNil(try catalog.offset(of:"0000",query:model.query))
        XCTAssertNotNil(try catalog.offset(of:"0405",query:model.query))
        model.photoSort = .filename; model.sortDescending = true; model.filterChanged()
        let order = try catalog.page(model.query,offset:0,limit:1000).photos.map(\.name)
        XCTAssertEqual(order,order.sorted(by:>))
        model.search = "0405"; model.filterChanged(); XCTAssertEqual(model.resultCount,1)
        model.setScope(other.id); XCTAssertEqual(model.resultCount,0); XCTAssertNil(model.activeID)
    }
    func testSelectableSortsUseTheSameOrderForEveryPageAndOffset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        try catalog.database.write { db in
            for i in 0..<407 {
                try Photo(id: String(format: "%04d", i), rootID: root.id, relativePath: "folder\(i % 3)/IMG_\(String(format: "%04d", 406 - i)).jpg", identity: Data(), identityKey: "sort:\(i)", rating: i % 6,
                          captureDate: i % 17 == 0 ? nil : "2026:10:\(String(format: "%02d", i % 28 + 1)) 12:00:00", width: 1, height: 1).insert(db)
            }
        }
        for sort in PhotoSort.allCases {
            for descending in [false, true] {
                let query = PhotoQuery(sort: sort, descending: descending)
                let all = try catalog.page(query, offset: 0, limit: 1000).photos
                let pages = try stride(from: 0, to: all.count, by: 200).flatMap { try catalog.page(query, offset: $0).photos }
                XCTAssertEqual(pages.map(\.id), all.map(\.id)); XCTAssertEqual(Set(pages.map(\.id)).count, 407)
                for index in [0, 199, 200, 399, 406] { XCTAssertEqual(try catalog.offset(of: all[index].id, query: query), index) }
                switch sort {
                case .filename:
                    XCTAssertEqual(all.map(\.name), all.map(\.name).sorted(by: descending ? (>) : (<)))
                case .rating: XCTAssertEqual(all.map(\.rating), all.map(\.rating).sorted(by: descending ? (>) : (<)))
                case .captureDate:
                    XCTAssertNil(all.last?.captureDate, "Missing capture times sort last in both directions")
                    let dates = all.compactMap(\.captureDate)
                    XCTAssertEqual(dates, dates.sorted(by: descending ? (>) : (<)))
                }
            }
        }
    }
    func testMetadataIntersectionMissingFieldsAndWholeCalendarDays() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory), root = try catalog.addRoot(url: directory, bookmark: Data())
        for (id, camera, date, details) in [
            ("a", "Synthetic 100%_", "2026:10:18 23:59:59", PhotoMetadata(lens: "Prime 50", iso: 400)),
            ("b", "Synthetic 100%_", "2026:10:19 00:00:00", PhotoMetadata(lens: "Prime 50", iso: 800)),
            ("c", "Other", "2026:10:18 00:00:00", PhotoMetadata(lens: "Zoom", iso: 100)),
            ("d", "", "2026:02:30 12:00:00", PhotoMetadata())
        ] {
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id, rating: 5, flag: 1,
                                    captureDate: date, width: 1, height: 1, camera: camera, metadata: try JSONEncoder().encode(details)))
        }
        try catalog.index(Photo(id: "missing", rootID: root.id, relativePath: "missing.jpg", identity: Data(), identityKey: "missing", width: 1, height: 1))
        _ = try catalog.changeKeyword("test", ids: ["a", "b"], adding: true)
        var filters = LibraryMetadataFilter(camera: "100%_", lens: "prime", minimumISO: "200", maximumISO: "400", dateFrom: "2026-10-18", dateThrough: "2026-10-18")
        XCTAssertEqual(try catalog.page(PhotoQuery(ratingThreshold: 5, flags: [1], keyword: "test", metadata: filters), offset: 0).photos.map(\.id), ["a"])
        XCTAssertEqual(try catalog.page(PhotoQuery(metadata: LibraryMetadataFilter()), offset: 0).total, 5)
        XCTAssertEqual(try catalog.page(PhotoQuery(metadata: LibraryMetadataFilter(minimumISO: "1")), offset: 0).total, 3)
        XCTAssertEqual(try catalog.page(PhotoQuery(metadata: LibraryMetadataFilter(dateFrom: "2026-01-01")), offset: 0).total, 3)
        filters.maximumISO = "wrong"
        XCTAssertNotNil(filters.validationMessage); XCTAssertEqual(try catalog.page(PhotoQuery(metadata: filters), offset: 0).total, 0)
        XCTAssertNil(LibraryMetadataFilter.day("2025:02:29")); XCTAssertEqual(LibraryMetadataFilter.day("2024:02:29"), "2024-02-29")
    }
    @MainActor func testHeldResultsKeepAllPagesStateUndoAndCollectionScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory), root = try catalog.addRoot(url: directory, bookmark: Data())
        try catalog.database.write { db in
            for i in 0..<405 {
                let id = String(format: "%04d", i)
                try Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id, rating: 5, width: 1, height: 1, metadata: Data("{}".utf8)).insert(db)
            }
        }
        _ = try catalog.changeKeyword("keep", ids: Set(try catalog.photos().map(\.id)), adding: true)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; model.ratingThreshold = 5; model.keywordFilter = "keep"; model.photoSort = .rating; model.sortDescending = true
        model.holdFilterResults = true; try model.reload(); model.choose(["0199", "0200"], active: "0199")
        model.undo.groupsByEvent = false; model.undo.beginUndoGrouping(); model.organize(rating: 0); model.undo.endUndoGrouping()
        XCTAssertEqual(model.activeID, "0199"); XCTAssertEqual(model.resultCount, 405); XCTAssertEqual(model.active?.rating, 0)
        XCTAssertEqual(model.selection, ["0199", "0200"], "Batch marking must retain selections on other pages")
        model.undo.undo(); XCTAssertEqual(model.active?.rating, 5); model.undo.redo(); XCTAssertEqual(model.active?.rating, 0)
        model.move(1); XCTAssertEqual(model.activeID, "0200"); XCTAssertEqual(model.pageOffset, 200)
        model.undo.beginUndoGrouping(); model.changeKeyword("keep", adding: false); model.undo.endUndoGrouping()
        XCTAssertEqual(model.activeID, "0200"); XCTAssertEqual(model.resultCount, 405)
        try catalog.collection(name: "All held", id: "all")
        model.collectResults(collection: "all"); XCTAssertEqual(try catalog.members("all").count, 405, "Must include every held page and changed members")
        XCTAssertThrowsError(try catalog.collectResults(model.query, collection: "bad", newName: " "))
        XCTAssertFalse(try catalog.collections().contains { $0.id == "bad" })
        try catalog.database.write { try $0.execute(sql: "DELETE FROM membership WHERE photoID='0404'; DELETE FROM photo WHERE id='0404'") }
        try model.reload(); XCTAssertEqual(model.resultCount, 404, "Deleted rows cannot survive a held view")
        model.refreshResults(); XCTAssertEqual(model.resultCount, 402); XCTAssertNotEqual(model.activeID, "0200")
        model.search = "0001"; model.filterChanged(); XCTAssertEqual(model.photos.map(\.id), ["0001"])
        model.setScope("collection:all"); XCTAssertEqual(model.resultCount, 1)
        model.holdFilterResults = false; model.filterChanged(); model.search = ""; model.ratingThreshold = 0; model.keywordFilter = ""; model.filterChanged()
        XCTAssertEqual(model.resultCount, 404)
        model.photoSort = .filename; model.sortDescending = true; model.filterChanged()
        let active = try XCTUnwrap(model.activeID)
        XCTAssertEqual(model.pageOffset, try XCTUnwrap(catalog.offset(of: active, query: model.query)) / 200 * 200)
        model.choose([active], active: active); model.beginComparison()
        XCTAssertEqual(model.comparison?.reference.photo?.id, active)
        model.move(1); XCTAssertNotEqual(model.activeID, active); XCTAssertEqual(model.comparison?.reference.photo?.id, active)
        model.endComparison()
    }
    @MainActor func testWorkspacePaginationAndFiltersKeepCanvasInVisibleResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("photos"), bookmark: Data())
        try catalog.database.write { db in
            for number in 0..<405 {
                let id = String(format: "%04d", number)
                try Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id,
                          rating: number % 2 == 0 ? 5 : 0, width: 120, height: 80, metadata: Data("{}".utf8)).insert(db)
            }
        }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; try model.reload()
        model.choose(["0199"], active: "0199")
        model.move(1)
        XCTAssertEqual(model.pageOffset, 200); XCTAssertEqual(model.activeID, "0200")
        XCTAssertEqual(model.selection, ["0200"])
        model.move(-1)
        XCTAssertEqual(model.pageOffset, 0); XCTAssertEqual(model.activeID, "0199")
        model.changePage(-1)
        XCTAssertEqual(model.activeID, "0199", "First-page boundary must not jump to another photo")
        model.changePage(100)
        XCTAssertEqual(model.pageOffset, 400); XCTAssertEqual(model.activeID, "0400")
        model.choose(["0404"], active: "0404"); model.move(1)
        XCTAssertEqual(model.activeID, "0404"); XCTAssertEqual(model.pageOffset, 400)
        model.ratingThreshold = 5; model.filterChanged()
        XCTAssertEqual(model.activeID, "0404"); XCTAssertEqual(model.pageOffset, 200)
        XCTAssertTrue(model.photos.contains { $0.id == model.activeID })
        model.organize(rating: 0)
        XCTAssertEqual(model.activeID, "0402", "Removing the active result selects the nearest surviving row")
        XCTAssertEqual(model.selection, ["0402"])
        model.search = "nothing-matches"; model.filterChanged()
        XCTAssertNil(model.activeID); XCTAssertNil(model.activePhoto); XCTAssertNil(model.recipe)
        XCTAssertNil(model.image); XCTAssertTrue(model.selection.isEmpty)
        model.search = ""; model.filterChanged()
        XCTAssertEqual(model.activeID, "0000"); XCTAssertEqual(model.selection, ["0000"])
        model.choose(["0000", "0002"], active: "0002")
        model.editMode = false; model.singleView = false
        model.editMode = true; model.singleView = true
        XCTAssertEqual(model.selection, ["0000", "0002"])
        XCTAssertEqual(model.activeID, "0002")
        model.search = "0000"; model.filterChanged()
        model.undo.removeAllActions(); model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping()
        model.organize(rating: 0)
        model.undo.endUndoGrouping()
        XCTAssertNil(model.activeID)
        model.undo.undo()
        XCTAssertEqual(model.activeID, "0000", "Undo restores a selectable photo after the last result was removed")
        XCTAssertEqual(model.selection, ["0000"])
    }
}
