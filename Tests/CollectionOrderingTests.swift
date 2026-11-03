import XCTest
import GRDB
@testable import Phosdeck

final class CollectionOrderingTests: XCTestCase {
    private func fixture() throws -> (CatalogStore, URL, StorageRoot, [String]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        let ids = (0..<6).map { "p\($0)" }
        try catalog.database.write { db in
            for (index, id) in ids.enumerated() {
                try Photo(id: id, rootID: root.id, relativePath: "IMG_\(index).jpg",
                          identity: Data([UInt8(index + 1)]), identityKey: "identity-\(index)",
                          rating: index % 2 == 0 ? 5 : 1, width: 10, height: 10).insert(db)
            }
        }
        try catalog.collection(name: "Manual", id: "manual")
        try catalog.membership(ids: ids, collection: "manual", add: true)
        return (catalog, directory, root, ids)
    }

    func testManualOrderPersistsAcrossReopenWithoutSchemaChange() throws {
        var catalog: CatalogStore?
        var directory: URL!
        var ids: [String]!
        do {
            let value = try fixture()
            catalog = value.0; directory = value.1; ids = value.3
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = [ids[0], ids[2], ids[1], ids[3], ids[4], ids[5]]
        XCTAssertEqual(try catalog!.reorderCollection("manual", moving: [ids[1]], before: ids[3]), ids)
        XCTAssertEqual(try catalog!.collectionOrder("manual"), expected)
        XCTAssertEqual(try catalog!.database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, CatalogStore.schemaVersion)
        catalog = nil

        let reopened = try CatalogStore(directory: directory)
        XCTAssertEqual(try reopened.collectionOrder("manual"), expected)
        let page = try reopened.page(PhotoQuery(scope: "collection:manual", manualCollectionOrder: true), offset: 0)
        XCTAssertEqual(page.photos.map(\.id), expected)
    }

    func testDeletedCollectionRestoresCompleteOrderAndRefusesChangedOrConflictingState() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try catalog.reorderCollection("manual", moving: [ids[4]], before: ids[0])
        _ = try catalog.setVersionDeletion([ids[2]: true])
        try catalog.collection(name: "Other", id: "other")
        try catalog.membership(ids: [ids[5]], collection: "other", add: true)
        let original = try catalog.collectionContents("manual")
        let photos = try catalog.database.read { try Photo.fetchAll($0) }
        XCTAssertEqual(try catalog.deleteCollection("manual", expecting: original), original)
        XCTAssertFalse(try catalog.collections().contains { $0.id == "manual" })
        try catalog.restoreCollection(original)
        XCTAssertEqual(try catalog.collectionContents("manual"), original)
        XCTAssertEqual(try catalog.database.read { try Photo.fetchAll($0) }, photos)
        XCTAssertEqual(try catalog.collectionOrder("other"), [ids[5]])
        try catalog.collection(name: "Changed after undo", id: "manual")
        XCTAssertThrowsError(try catalog.deleteCollection("manual", expecting: original))
        XCTAssertEqual(try catalog.members("manual"), Set(ids))
        _ = try catalog.deleteCollection("manual")
        try catalog.collection(name: "A newer collection", id: "manual")
        XCTAssertThrowsError(try catalog.restoreCollection(original))
        XCTAssertEqual(try catalog.collectionContents("manual").collection.name, "A newer collection")
        XCTAssertTrue(try catalog.members("manual").isEmpty)
        let invalid = CollectionContents(collection: PhotoCollection(id: "invalid", name: "Invalid"), members: ["missing-photo"])
        XCTAssertThrowsError(try catalog.restoreCollection(invalid))
        XCTAssertFalse(try catalog.collections().contains { $0.id == "invalid" }, "A member failure rolls back the whole restoration")
        let smart = PhotoCollection(id: "smart", name: "Smart", rules: try JSONEncoder().encode(SmartRules()))
        try catalog.database.write { try smart.insert($0) }
        XCTAssertThrowsError(try catalog.collectionContents("smart"))
        XCTAssertThrowsError(try catalog.deleteCollection("smart"))
        XCTAssertTrue(try catalog.collections().contains { $0.id == "smart" })
    }

    @MainActor func testCollectionDeleteUndoPreservesUnrelatedDraftAndRestoresTargetAndOrder() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try catalog.reorderCollection("manual", moving: [ids[4]], before: ids[0])
        let original = try catalog.collectionContents("manual")
        try catalog.collection(name: "Other", id: "other")
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; model.activeID = ids[0]; try model.reload()
        model.setTargetCollection("manual")
        model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0,
                                  baselineTemperature: 5500, baselineTint: 0, exposure: 2, temperature: 5500, tint: 0)
        model.canEdit = true; model.dirty = true; model.undo.groupsByEvent = false
        let photo = try catalog.photo(ids[0])
        model.undo.beginUndoGrouping(); model.deleteCollection("manual"); model.undo.endUndoGrouping()
        XCTAssertNil(model.error); XCTAssertEqual(model.scope, "all"); XCTAssertEqual(model.activeID, ids[0])
        XCTAssertNil(model.targetCollectionID)
        XCTAssertEqual(model.recipe?.exposure, 2); XCTAssertTrue(model.dirty)
        XCTAssertEqual(try catalog.photo(ids[0]), photo)
        XCTAssertEqual(model.undo.undoActionName, "删除集合")
        model.undo.undo()
        XCTAssertEqual(try catalog.collectionContents("manual"), original)
        XCTAssertEqual(model.targetCollectionID, "manual")
        XCTAssertFalse(model.undo.canUndo); XCTAssertTrue(model.undo.canRedo)
        model.undo.redo()
        XCTAssertFalse(try catalog.collections().contains { $0.id == "manual" })
        model.setTargetCollection("other")
        model.undo.undo()
        XCTAssertEqual(try catalog.collectionContents("manual"), original)
        XCTAssertEqual(model.targetCollectionID, "other", "Undo cannot replace a target the user chose after deletion")
        XCTAssertEqual(model.recipe?.exposure, 2); XCTAssertTrue(model.dirty)
        XCTAssertEqual(try catalog.photo(ids[0]), photo)
        model.busy = true; model.deleteCollection("other")
        XCTAssertTrue(try catalog.collections().contains { $0.id == "other" })
    }

    @MainActor func testDeletingCurrentCollectionFallsBackAndOldUndoCannotWriteAnotherCatalog() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; model.scope = "collection:manual"; try model.reload()
        model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping(); model.deleteCollection("manual"); model.undo.endUndoGrouping()
        XCTAssertEqual(model.scope, "all"); XCTAssertEqual(model.resultCount, ids.count)
        XCTAssertNil(model.error)
        let next = try CatalogStore(directory: directory.appendingPathComponent("next"))
        try next.collection(name: "Same ID, different catalog", id: "manual")
        // Deliberately retain an old callback to verify the identity check as well as the normal clear-on-switch path.
        model.catalog = next; try model.reload(); model.undo.undo()
        XCTAssertEqual(try next.collectionContents("manual").collection.name, "Same ID, different catalog")
        XCTAssertTrue(try next.members("manual").isEmpty)
        XCTAssertFalse(try catalog.collections().contains { $0.id == "manual" })
        try model.activateCatalog(catalog)
        XCTAssertFalse(model.undo.canUndo); XCTAssertFalse(model.undo.canRedo)
    }

    func testOrderedMembershipUndoRestoresMembersAndOrderAtomically() throws {
        let (catalog, directory, root, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try catalog.database.write { db in
            try Photo(id: "p6", rootID: root.id, relativePath: "IMG_6.jpg", identity: Data([7]), identityKey: "identity-6",
                      rating: 5, width: 10, height: 10).insert(db)
        }
        try catalog.collection(name: "Other", id: "other")
        try catalog.membership(ids: [ids[5], ids[4]], collection: "other", add: true)
        let before = try catalog.collectionOrder("manual")
        let desired = [ids[0], ids[2], ids[3], ids[4], ids[5], "p6"]
        let change = try catalog.restoreOrderedMembership([ids[1]: false, "p6": true], collection: "manual", order: desired)
        XCTAssertEqual(try catalog.collectionOrder("manual"), desired)
        XCTAssertEqual(change.inverse[ids[1]], true)
        XCTAssertEqual(change.inverse["p6"], false)
        XCTAssertEqual(change.previousOrder, before)
        XCTAssertTrue(change.changed)
        XCTAssertEqual(try catalog.collectionOrder("other"), [ids[5], ids[4]], "另一个集合的相对顺序不应被重排")

        let inverse = try catalog.restoreOrderedMembership(change.inverse, collection: "manual", order: change.previousOrder)
        XCTAssertEqual(try catalog.collectionOrder("manual"), before)
        XCTAssertEqual(try catalog.members("manual"), Set(ids))
        XCTAssertEqual(inverse.previousOrder, desired)
    }

    func testBackupRestoreAndVacuumKeepRelativeOrderWithoutUsingRowidAsIdentity() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Create a rowid gap before adding the member back. VACUUM may rewrite
        // those hidden rowids; the photo IDs and their relative order remain
        // the only durable contract.
        try catalog.membership(ids: [ids[2]], collection: "manual", add: false)
        try catalog.membership(ids: [ids[2]], collection: "manual", add: true)
        let expected = [ids[0], ids[1], ids[3], ids[4], ids[5], ids[2]]
        XCTAssertEqual(try catalog.collectionOrder("manual"), expected)
        try catalog.database.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
        XCTAssertEqual(try catalog.collectionOrder("manual"), expected)

        let backup = directory.appendingPathComponent("ordered-backup.sqlite")
        try catalog.backup(to: backup)
        let restored = try CatalogStore.restore(from: backup, to: directory.appendingPathComponent("ordered-restored"))
        XCTAssertEqual(try restored.collectionOrder("manual"), expected)
    }

    func testDragTokenChangesWithCatalogAndFullQueryContext() throws {
        var query = PhotoQuery(scope: "collection:manual", manualCollectionOrder: true)
        let base = query.orderingQuerySignature
        var held = query
        held.snapshotID = "old-held"
        var cloned = query
        cloned.snapshotID = "cloned-held"
        XCTAssertNotEqual(held.orderingQuerySignature, cloned.orderingQuerySignature)
        XCTAssertEqual(held.scrollQuerySignature, cloned.scrollQuerySignature, "历史克隆 held snapshot 不应丢失同一来源的滚动位置")
        query.metadata.camera = "相机"
        XCTAssertNotEqual(base, query.orderingQuerySignature)
        let first = CollectionOrderingToken(catalogPath: "/tmp/one/Catalog.sqlite", querySignature: base)
        let second = CollectionOrderingToken(catalogPath: "/tmp/two/Catalog.sqlite", querySignature: base)
        XCTAssertNotEqual(first, second)
        let payload = CollectionOrderingDragPayload(ids: ["p0", "p1"], token: first)
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(CollectionOrderingDragPayload.self, from: data), payload)
    }

    func testFilteredPageAndExportUseSameManualOrderAndKeepHiddenMembersRelative() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let query = PhotoQuery(scope: "collection:manual", ratingThreshold: 5, ratingComparison: .atLeast, manualCollectionOrder: true)
        XCTAssertEqual(try catalog.page(query, offset: 0).photos.map(\.id), [ids[0], ids[2], ids[4]])

        // Only visible members move. p1/p3 are hidden by the filter and keep
        // their relative order in the complete collection.
        _ = try catalog.reorderCollection("manual", moving: [ids[4]], before: ids[0])
        XCTAssertEqual(try catalog.collectionOrder("manual"), [ids[4], ids[0], ids[1], ids[2], ids[3], ids[5]])
        XCTAssertEqual(try catalog.page(query, offset: 0).photos.map(\.id), [ids[4], ids[0], ids[2]])
        XCTAssertEqual(try catalog.page(query, offset: 0, limit: 2).photos.map(\.id), [ids[4], ids[0]])
        XCTAssertEqual(try catalog.page(query, offset: 2, limit: 2).photos.map(\.id), [ids[2]])

        let selected = Set([ids[4], ids[2]])
        XCTAssertEqual(try catalog.exportPhotos(ids: selected, query: query).map(\.id), [ids[4], ids[2]])

        let heldID = try catalog.holdResults(query, replacing: nil)
        defer { try? catalog.releaseResults(heldID) }
        var heldQuery = query
        heldQuery.snapshotID = heldID
        XCTAssertEqual(try catalog.page(heldQuery, offset: 0).photos.map(\.id), [ids[4], ids[0], ids[2]])
    }

    @MainActor func testModelDropUndoRedoKeepsHeldMembershipAndRejectsOldQuery() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; model.scope = "collection:manual"
        model.ratingThreshold = 5; model.filterSections = [.attribute]; model.holdFilterResults = true
        model.undo.groupsByEvent = false
        try model.reload(); model.setManualCollectionOrder(true)
        model.choose([ids[4]], active: ids[4])
        let oldBridge = try XCTUnwrap(model.collectionOrdering)
        model.refreshResults()
        XCTAssertFalse(oldBridge.reorder([ids[4]], ids[0]), "刷新后的旧拖动不能继续写集合")
        let bridge = try XCTUnwrap(model.collectionOrdering)
        try catalog.setOrganization(ids: [ids[2]], rating: 0)
        model.undo.beginUndoGrouping()
        XCTAssertTrue(bridge.reorder([ids[4]], ids[0]))
        model.undo.endUndoGrouping()
        XCTAssertEqual(model.photos.map(\.id), [ids[4], ids[0], ids[2]], "重排保持结果不能剔除刚取消评级的成员")
        XCTAssertEqual(model.activeID, ids[4]); XCTAssertEqual(model.selection, [ids[4]])
        XCTAssertEqual(try catalog.collectionOrder("manual"), [ids[4], ids[0], ids[1], ids[2], ids[3], ids[5]])
        model.undo.undo()
        XCTAssertEqual(try catalog.collectionOrder("manual"), ids)
        XCTAssertEqual(model.photos.map(\.id), [ids[0], ids[2], ids[4]])
        model.undo.redo()
        XCTAssertEqual(model.photos.map(\.id), [ids[4], ids[0], ids[2]])
    }

    func testMultiMoveAndRestoreOrderAreOneLogicalOrderAndRejectSmartCollections() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try catalog.collectionOrder("manual")
        XCTAssertEqual(try catalog.reorderCollection("manual", moving: [ids[3], ids[1]], before: ids[5]), before)
        // Multi-selection keeps the members' original relative order; the
        // unselected p4 remains before the insertion target p5.
        let moved = [ids[0], ids[2], ids[4], ids[1], ids[3], ids[5]]
        XCTAssertEqual(try catalog.collectionOrder("manual"), moved)
        XCTAssertEqual(try catalog.restoreCollectionOrder("manual", order: before), moved)
        XCTAssertEqual(try catalog.collectionOrder("manual"), before)
        XCTAssertThrowsError(try catalog.restoreCollectionOrder("manual", order: [ids[0], ids[1]]))

        let smartRules = try JSONEncoder().encode(SmartRules())
        try catalog.database.write { try PhotoCollection(id: "smart", name: "Smart", rules: smartRules).save($0) }
        XCTAssertThrowsError(try catalog.collectionOrder("smart"))
        XCTAssertThrowsError(try catalog.reorderCollection("smart", moving: [ids[0]], before: nil))
    }

    func testRelatedSourceExpandsCollapsedStackForPagingOffsetsAndExport() throws {
        let (catalog, directory, _, ids) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stack = PhotoStack(members: [ids[0], ids[1]], collapsed: true)
        _ = try catalog.restoreStacks([stack])
        let relatedOrder = [ids[1], ids[2], ids[0]]
        let snapshot = try catalog.snapshotPhotos(relatedOrder)
        defer { try? catalog.releaseResults(snapshot) }
        let query = PhotoQuery(scope: "related:\(snapshot)")
        let page = try catalog.page(query, offset: 0, limit: 10)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.visibleTotal, 3, "related context expands a persisted collapsed stack only for this query")
        XCTAssertEqual(page.photos.map(\.id), relatedOrder, "related temporary source keeps caller group order")
        XCTAssertEqual(Set(page.photos.map(\.id)), Set([ids[0], ids[1], ids[2]]))
        XCTAssertNotNil(try catalog.offset(of: ids[1], query: query))
        XCTAssertEqual(try catalog.resultIDs(query, within: Set([ids[0], ids[1], ids[2]])).count, 3)
        XCTAssertEqual(try catalog.exportPhotos(ids: Set([ids[0], ids[1], ids[2]]), query: query).count, 3)
        XCTAssertTrue(try XCTUnwrap(catalog.stacks().first).collapsed, "query expansion never changes persisted stack state")
    }
}
