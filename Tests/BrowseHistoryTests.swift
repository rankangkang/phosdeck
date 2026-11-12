import Foundation
import XCTest
import GRDB
import SwiftUI
@testable import Phosdeck

final class BrowseHistoryTests: XCTestCase {
    private struct Fixture {
        let catalog: CatalogStore
        let directory: URL
        let first: StorageRoot
        let second: StorageRoot
        let firstIDs: [String]
        let secondIDs: [String]
    }

    private func fixture(firstCount: Int = 405, secondCount: Int = 4) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browse-history-" + UUID().uuidString)
        let catalog = try CatalogStore(directory: directory)
        let first = try catalog.addRoot(url: directory.appendingPathComponent("source-a"), bookmark: Data())
        let second = try catalog.addRoot(url: directory.appendingPathComponent("source-b"), bookmark: Data())
        let firstIDs = (0..<firstCount).map { String(format: "a%03d", $0) }
        let secondIDs = (0..<secondCount).map { String(format: "b%03d", $0) }
        try catalog.database.write { db in
            for (index, id) in firstIDs.enumerated() {
                let metadata = try JSONEncoder().encode(PhotoMetadata(lens: "Prime", iso: 100 + index))
                try Photo(id: id, rootID: first.id, relativePath: "A/\(id).jpg", identity: Data(), identityKey: "history-a-\(index)",
                          rating: 5, captureDate: String(format: "2026:10:18 12:%02d:00", index % 60), width: 1, height: 1,
                          camera: "Alpha", metadata: metadata).insert(db)
            }
            for (index, id) in secondIDs.enumerated() {
                let metadata = try JSONEncoder().encode(PhotoMetadata(lens: "Zoom", iso: 800 + index))
                try Photo(id: id, rootID: second.id, relativePath: "B/\(id).jpg", identity: Data(), identityKey: "history-b-\(index)",
                          rating: 4, captureDate: String(format: "2026:10:19 12:%02d:00", index % 60), width: 1, height: 1,
                          camera: "Beta", metadata: metadata).insert(db)
            }
        }
        return Fixture(catalog: catalog, directory: directory, first: first, second: second,
                       firstIDs: firstIDs, secondIDs: secondIDs)
    }

    @MainActor private func makeModel(for catalog: CatalogStore) throws -> AppModel {
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog
        try model.reload()
        return model
    }

    private func snapshotCount(_ catalog: CatalogStore, id: String) throws -> Int {
        try catalog.database.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM temp.browseSnapshot WHERE snapshotID=?", arguments: [id]) ?? 0
        }
    }

    private func versions(in fixture: Fixture) throws -> (original: String, first: Photo, second: Photo) {
        let original = fixture.firstIDs[0]
        let first = try XCTUnwrap(fixture.catalog.createVirtualCopies(ids: [original]).first)
        let second = try XCTUnwrap(fixture.catalog.createVirtualCopies(ids: [original]).first)
        return (original, first, second)
    }

    @MainActor func testSourceHistoryRestoresFiltersPageSelectionAndHeldSnapshotAfterAnotherSourceRefresh() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let model = try makeModel(for: f.catalog)
        model.scope = f.first.id
        model.ratingComparison = .atLeast
        model.ratingThreshold = 5
        model.metadataFilter = LibraryMetadataFilter(camera: "Alpha")
        model.filterSections = [.attribute, .metadata]
        model.photoSort = .filename
        model.sortDescending = true
        model.holdFilterResults = true
        try model.reload()
        model.pageOffset = 200
        try model.reloadPhotos()
        model.choose([f.firstIDs[200], f.firstIDs[201]], active: f.firstIDs[201])

        let originalQuery = model.query
        let originalHeld = try XCTUnwrap(originalQuery.snapshotID)
        XCTAssertEqual(model.resultCount, f.firstIDs.count)
        XCTAssertEqual(try snapshotCount(f.catalog, id: originalHeld), f.firstIDs.count)

        // A source change owns a copied held snapshot in history. Refreshing
        // the new source must not release the old source's held result.
        model.setScope(f.second.id)
        model.ratingThreshold = 0
        model.metadataFilter = LibraryMetadataFilter(camera: "Beta")
        model.filterSections = [.metadata]
        model.photoSort = .rating
        model.sortDescending = false
        model.filterChanged()
        try f.catalog.setOrganization(ids: [f.firstIDs[201]], rating: 0)
        XCTAssertEqual(try snapshotCount(f.catalog, id: originalHeld), 0, "当前视图可释放自己的 snapshot")

        model.navigateBrowse(-1)
        XCTAssertEqual(model.scope, f.first.id)
        XCTAssertEqual(model.ratingThreshold, 5)
        XCTAssertEqual(model.metadataFilter, LibraryMetadataFilter(camera: "Alpha"))
        XCTAssertEqual(model.filterSections, [.attribute, .metadata])
        XCTAssertEqual(model.photoSort, .filename)
        XCTAssertTrue(model.sortDescending)
        XCTAssertTrue(model.holdFilterResults)
        XCTAssertEqual(model.pageOffset, 200)
        XCTAssertEqual(model.selection, Set([f.firstIDs[200], f.firstIDs[201]]))
        XCTAssertEqual(model.activeID, f.firstIDs[201])
        XCTAssertEqual(model.resultCount, f.firstIDs.count, "历史 held snapshot 保留离开时的匹配集合")
        let restoredHeld = try XCTUnwrap(model.query.snapshotID)
        XCTAssertNotEqual(restoredHeld, originalHeld)
        XCTAssertEqual(try snapshotCount(f.catalog, id: restoredHeld), f.firstIDs.count)
    }

    @MainActor func testRecentJumpBranchClearsForwardAndDeletedCollectionIsSkipped() throws {
        let f = try fixture(firstCount: 3, secondCount: 2)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let third = try f.catalog.addRoot(url: f.directory.appendingPathComponent("source-c"), bookmark: Data())
        try f.catalog.index(Photo(id: "c000", rootID: third.id, relativePath: "C/c000.jpg", identity: Data(), identityKey: "history-c-0", width: 1, height: 1))
        let model = try makeModel(for: f.catalog)
        model.scope = f.first.id
        try model.reload()
        model.setScope(f.second.id)
        model.setScope(third.id)
        XCTAssertEqual(model.recentBrowseLocations.map(\.title), [f.second.label, f.first.label])

        let firstLocation = try XCTUnwrap(model.recentBrowseLocations.first { $0.title == f.first.label })
        model.navigateBrowse(to: firstLocation.id)
        XCTAssertEqual(model.scope, f.first.id)
        XCTAssertTrue(model.canBrowseForward)

        // Starting a new branch from the jumped location discards forward.
        model.setScope(third.id)
        XCTAssertFalse(model.canBrowseForward)

        let deleted = try makeModel(for: f.catalog)
        try f.catalog.collection(name: "稍后删除", id: "gone")
        try f.catalog.membership(ids: [f.firstIDs[0]], collection: "gone", add: true)
        deleted.scope = f.first.id
        try deleted.reload()
        deleted.setScope("collection:gone")
        deleted.setScope(f.first.id)
        try f.catalog.deleteCollection("gone")
        try deleted.reload()
        deleted.navigateBrowse(-1)
        XCTAssertEqual(deleted.scope, f.first.id, "不存在的历史来源应被跳过")
        XCTAssertFalse(deleted.canBrowseBack)
    }

    @MainActor func testRepeatedSourceVisitsRestoreEachLocationsOwnScrollOrigin() throws {
        let f = try fixture(firstCount: 3, secondCount: 2)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let model = try makeModel(for: f.catalog)
        model.setScope(f.first.id)
        model.scrollPositions[model.browseScrollKey(film: false)] = CGPoint(x: 0, y: 12)
        model.scrollPositions[model.browseScrollKey(film: true)] = CGPoint(x: 8, y: 0)
        model.setScope(f.second.id)
        model.scrollPositions[model.browseScrollKey(film: false)] = CGPoint(x: 0, y: 20)
        model.setScope(f.first.id)
        model.scrollPositions[model.browseScrollKey(film: false)] = CGPoint(x: 0, y: 44)
        model.setScope("all")
        for origin in [CGFloat(44), 20, 12] {
            model.navigateBrowse(-1)
            XCTAssertEqual(model.scrollPositions[model.browseScrollKey(film: false)], CGPoint(x: 0, y: origin))
        }
        XCTAssertEqual(model.scrollPositions[model.browseScrollKey(film: true)], CGPoint(x: 8, y: 0))
    }

    @MainActor func testExistingGridAndFilmViewRestoreHistoryOriginWithoutScrollingToActive() async throws {
        let f = try fixture(firstCount: 30, secondCount: 3)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(condition())
        }
        for film in [false, true] {
            let model = try makeModel(for: f.catalog)
            model.thumbnailSize = 100; model.setScope(f.first.id)
            let host = NSHostingView(rootView: PhotoGrid(model: model, film: film))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: film ? 84 : 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
            let collection = try XCTUnwrap(scroll.documentView as? NSCollectionView)
            try await wait { collection.numberOfItems(inSection: 0) == 30 }
            host.layoutSubtreeIfNeeded()
            let origin = film ? CGPoint(x: 180, y: 0) : CGPoint(x: 0, y: 140)
            scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
            try await wait { model.scrollPositions[model.browseScrollKey(film: film)] == origin }
            model.setScope(f.second.id)
            try await wait { collection.numberOfItems(inSection: 0) == 3 }
            model.navigateBrowse(-1)
            try await wait { collection.numberOfItems(inSection: 0) == 30 }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1,
                           "来源往返应保留用户滚动位置，不能被活动照片自动定位覆盖")
        }
    }

    @MainActor func testImportBorrowedReturnKeepsAutomaticSourceHistory() throws {
        let f = try fixture(firstCount: 2, secondCount: 2)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let model = try makeModel(for: f.catalog)
        model.scope = f.first.id
        model.holdFilterResults = true
        try model.reload()
        model.setScope(f.second.id)
        try model.completeImport(ids: Set([f.secondIDs[0]]), cancelled: false)
        model.showLastImport()
        XCTAssertTrue(model.isViewingImport)
        model.returnFromImport()
        XCTAssertFalse(model.isViewingImport)
        XCTAssertEqual(model.scope, f.second.id)
        XCTAssertTrue(model.canBrowseBack, "导入借用返回后仍可沿用 A 的来源历史")
        model.navigateBrowse(-1)
        XCTAssertEqual(model.scope, f.first.id)
    }

    @MainActor func testOpenVersionKeepsSameQueryAndRelatedBackRestoresFilters() throws {
        let f = try fixture(firstCount: 2, secondCount: 1)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let group = try versions(in: f)
        try f.catalog.setOrganization(ids: [group.first.id, group.second.id], rating: 5)
        let model = try makeModel(for: f.catalog)
        model.scope = f.first.id
        model.ratingThreshold = 5
        model.metadataFilter = LibraryMetadataFilter(camera: "Alpha")
        model.filterSections = [.attribute, .metadata]
        model.photoSort = .filename
        model.sortDescending = true
        try model.reload()
        model.choose([group.original], active: group.original)
        let sourceQuery = model.query

        model.openVersion(group.first.id)
        XCTAssertFalse(model.isViewingRelated)
        XCTAssertEqual(model.scope, sourceQuery.scope)
        XCTAssertEqual(model.ratingThreshold, sourceQuery.ratingThreshold)
        XCTAssertEqual(model.metadataFilter, sourceQuery.metadata)
        XCTAssertEqual(model.photoSort, sourceQuery.sort)
        XCTAssertTrue(model.sortDescending)
        XCTAssertEqual(model.activeID, group.first.id)
        XCTAssertTrue(model.canBrowseBack)
        model.navigateBrowse(-1)
        XCTAssertEqual(model.activeID, group.original)

        // The target remains in the catalog but falls out of the current
        // result. Opening it borrows a related source and pauses filters while
        // retaining their values for the return path.
        try f.catalog.setOrganization(ids: [group.first.id], rating: 0)
        model.refreshResults()
        model.choose([group.original], active: group.original)
        model.openVersion(group.first.id)
        XCTAssertTrue(model.isViewingRelated)
        let relatedID = try XCTUnwrap(model.scope.split(separator: ":", maxSplits: 1).last).description
        XCTAssertFalse(model.filtersEnabled)
        XCTAssertEqual(model.ratingThreshold, 5)
        XCTAssertEqual(model.metadataFilter, LibraryMetadataFilter(camera: "Alpha"))
        XCTAssertNotNil(model.relatedBrowseTitle)
        XCTAssertEqual(model.activeID, group.first.id)
        XCTAssertEqual(model.resultCount, 3)

        model.navigateBrowse(-1)
        XCTAssertFalse(model.isViewingRelated)
        XCTAssertTrue(model.filtersEnabled)
        XCTAssertEqual(model.ratingThreshold, 5)
        XCTAssertEqual(model.metadataFilter, LibraryMetadataFilter(camera: "Alpha"))
        XCTAssertEqual(model.scope, f.first.id)
        XCTAssertEqual(model.activeID, group.original)
        XCTAssertEqual(try snapshotCount(f.catalog, id: relatedID), 0)
    }

    @MainActor func testRelatedComparisonStaysWithinGroupAndDoesNotExpandCollapsedStackOnDisk() throws {
        let f = try fixture(firstCount: 1, secondCount: 1)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let group = try versions(in: f)
        try f.catalog.restoreStacks([PhotoStack(members: [group.original, group.first.id, group.second.id], collapsed: true)])
        let model = try makeModel(for: f.catalog)
        model.scope = f.first.id
        try model.reload()
        model.choose([group.original], active: group.original)

        model.compareRelatedVersions(inStack: true)
        XCTAssertTrue(model.isViewingRelated)
        XCTAssertFalse(model.filtersEnabled)
        XCTAssertEqual(model.resultCount, 3)
        XCTAssertEqual(model.visibleCount, 3, "related 查询应旁路折叠状态")
        XCTAssertEqual(Set(model.comparison?.groupIDs ?? []), Set([group.original, group.first.id, group.second.id]))
        XCTAssertTrue(model.comparison?.restrictToGroup == true)
        XCTAssertTrue(try XCTUnwrap(f.catalog.stacks().first).collapsed, "查询展开不能写回堆叠状态")

        let firstCandidate = try XCTUnwrap(model.comparison?.candidate.photo?.id)
        model.move(1)
        XCTAssertNotEqual(model.comparison?.candidate.photo?.id, firstCandidate)
        XCTAssertTrue([group.first.id, group.second.id].contains(model.comparison?.candidate.photo?.id ?? ""))
        model.move(-1)
        XCTAssertEqual(model.comparison?.candidate.photo?.id, firstCandidate)

        model.navigateBrowse(-1)
        XCTAssertFalse(model.isViewingRelated)
        XCTAssertNil(model.comparison)
        XCTAssertTrue(try XCTUnwrap(f.catalog.stacks().first).collapsed)
    }

    @MainActor func testContinuousStackComparisonFollowsFilteredOrderAndReturnsToTheLastStackPage() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = PhotoStack(members: [f.firstIDs[402], f.firstIDs[400], f.firstIDs[401]])
        let partial = PhotoStack(members: [f.firstIDs[351], f.firstIDs[350]])
        let second = PhotoStack(members: [f.firstIDs[190], f.firstIDs[189]], collapsed: false)
        let last = PhotoStack(members: [f.firstIDs[6], f.firstIDs[5]])
        let outside = PhotoStack(members: Array(f.secondIDs.prefix(2)))
        try f.catalog.restoreStacks([last, second, partial, outside, first])
        try f.catalog.setOrganization(ids: [partial.members[1]], flag: 1)
        let model = try makeModel(for: f.catalog)
        model.scope = f.first.id
        model.photoSort = .filename
        model.sortDescending = true
        model.flagFilter = [0]
        try model.reload()
        let source = model.query
        model.choose([partial.members[0]], active: partial.members[0])
        XCTAssertFalse(model.canCompareStack, "A single matching member cannot be compared")
        model.choose([first.members[0]], active: first.members[0])
        XCTAssertTrue(model.canCompareStack)

        model.beginStackComparison()
        XCTAssertEqual(model.workspaceMode, .compare)
        XCTAssertEqual(model.stackComparisonProgress?.current, 1)
        XCTAssertEqual(model.stackComparisonProgress?.total, 3)
        XCTAssertEqual(model.photos.map(\.id), first.members)
        let oldSnapshot = String(model.query.scope.dropFirst(8))
        XCTAssertEqual(try snapshotCount(f.catalog, id: oldSnapshot), 3)
        let pair = try XCTUnwrap(model.comparison)
        XCTAssertEqual(pair.reference.photo?.id, first.members[0])
        XCTAssertEqual(model.activeID, first.members[1])
        model.organize(flag: 1, advance: false)
        XCTAssertEqual(model.activeID, first.members[1], "Marking a frame must not remove it during this comparison")
        model.move(1)
        model.move(1)
        XCTAssertEqual(model.activeID, first.members[2], "Candidate navigation stops at the group boundary")
        pair.setLinked(false)
        pair.selectZoom(1, in: pair.candidate)

        model.compareNextStack()
        XCTAssertEqual(model.stackComparisonProgress?.current, 2)
        XCTAssertEqual(model.comparison?.reference.photo?.id, second.members[0])
        XCTAssertEqual(model.activeID, second.members[1])
        XCTAssertEqual(model.comparison?.linked, false)
        XCTAssertNil(model.comparison?.candidate.zoom)
        XCTAssertEqual(try snapshotCount(f.catalog, id: oldSnapshot), 0)
        model.compareNextStack()
        XCTAssertEqual(model.stackComparisonProgress?.current, 3)
        XCTAssertEqual(model.comparison?.reference.photo?.id, last.members[0])
        XCTAssertEqual(model.activeID, last.members[1])
        let finalSnapshot = String(model.query.scope.dropFirst(8))
        model.compareNextStack()
        XCTAssertEqual(model.stackComparisonProgress?.current, 3)
        model.stackAction(.cover(last.members[1]), title: "Cover")
        XCTAssertEqual(model.activeID, last.members[1])

        model.endComparison()
        XCTAssertEqual(model.workspaceMode, .grid)
        XCTAssertNil(model.stackComparisonProgress)
        XCTAssertEqual(model.query, source)
        XCTAssertEqual(model.selection, [last.members[1]])
        XCTAssertEqual(model.activeID, last.members[1])
        XCTAssertEqual(model.pageOffset, 200)
        XCTAssertTrue(model.photos.contains { $0.id == last.members[1] })
        XCTAssertFalse(model.canBrowseBack)
        XCTAssertEqual(try snapshotCount(f.catalog, id: finalSnapshot), 0)
        XCTAssertEqual(try f.catalog.photo(first.members[1])?.flag, 1)
        XCTAssertEqual(try f.catalog.photo(last.members[1])?.flag, 0)
        let saved = try f.catalog.stacks()
        XCTAssertEqual(saved.first { $0.id == first.id }, first)
        XCTAssertEqual(saved.first { $0.id == second.id }, second)
        XCTAssertEqual(saved.first { $0.id == last.id }?.members, last.members.reversed().map { $0 })
    }

    @MainActor func testContinuousStackComparisonSkipsDissolvedStackAndPreservesTheHeldImport() throws {
        let f = try fixture(firstCount: 7, secondCount: 2)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = PhotoStack(members: Array(f.firstIDs[0...1]))
        let removed = PhotoStack(members: Array(f.firstIDs[2...3]))
        let last = PhotoStack(members: Array(f.firstIDs[4...6]))
        try f.catalog.restoreStacks([removed, first, last])
        let model = try makeModel(for: f.catalog)
        model.setScope(f.second.id)
        try model.completeImport(ids: Set(f.firstIDs), cancelled: false)
        model.showLastImport()
        model.holdFilterResults = true
        try model.reloadPhotos()
        let source = model.query
        let held = try XCTUnwrap(source.snapshotID)
        model.beginStackComparison()
        XCTAssertEqual(model.stackComparisonProgress?.total, 3)
        var updatedFirst = first, updatedLast = last
        updatedFirst.members.append(updatedLast.members.removeFirst())
        try f.catalog.restoreStacks([updatedFirst, updatedLast])
        model.compareNextStack()
        XCTAssertEqual(model.stackComparisonProgress?.current, 2)
        XCTAssertEqual(model.stackComparisonProgress?.total, 2)
        XCTAssertEqual(model.comparison?.reference.photo?.id, updatedLast.members[0])
        model.selectWorkspace(.grid)
        XCTAssertEqual(model.query, source)
        XCTAssertEqual(model.activeID, updatedLast.members[0])
        XCTAssertEqual(try snapshotCount(f.catalog, id: held), 7)
        XCTAssertTrue(model.isViewingImport)
        model.returnFromImport()
        XCTAssertEqual(model.scope, f.second.id)
        XCTAssertEqual(try snapshotCount(f.catalog, id: held), 0)
    }

    @MainActor func testSwitchingCatalogReleasesHeldHistoryAndRelatedSnapshots() throws {
        let f = try fixture(firstCount: 3, secondCount: 2)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let model = try makeModel(for: f.catalog)
        model.scope = f.first.id
        model.holdFilterResults = true
        try model.reload()
        let firstHeld = try XCTUnwrap(model.query.snapshotID)
        model.setScope(f.second.id)
        let secondHeld = try XCTUnwrap(model.query.snapshotID)
        let nextDirectory = f.directory.appendingPathComponent("next-catalog")
        let next = try CatalogStore(directory: nextDirectory)
        try model.activateCatalog(next)
        XCTAssertEqual(try snapshotCount(f.catalog, id: firstHeld), 0)
        XCTAssertEqual(try snapshotCount(f.catalog, id: secondHeld), 0)

        // A current related snapshot is also owned by the active catalog and
        // must not survive a catalog switch.
        let f2 = try fixture(firstCount: 1, secondCount: 1)
        defer { try? FileManager.default.removeItem(at: f2.directory) }
        let group = try versions(in: f2)
        let related = try makeModel(for: f2.catalog)
        related.scope = f2.first.id
        related.ratingThreshold = 5
        related.filterSections = [.attribute]
        try related.reload()
        related.choose([group.original], active: group.original)
        try f2.catalog.setOrganization(ids: [group.first.id], rating: 0)
        related.refreshResults()
        related.openVersion(group.first.id)
        let relatedID = try XCTUnwrap(related.scope.split(separator: ":", maxSplits: 1).last).description
        let another = try CatalogStore(directory: f2.directory.appendingPathComponent("next-catalog"))
        try related.activateCatalog(another)
        XCTAssertEqual(try snapshotCount(f2.catalog, id: relatedID), 0)
    }
}
