import XCTest
import GRDB
import SwiftUI
import CoreImage
@testable import Phosdeck

final class StackTests: XCTestCase {
    func fixture(_ count: Int = 8) throws -> (CatalogStore,URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-stack-" + UUID().uuidString)
        let c = try CatalogStore(directory:dir), root = try c.addRoot(url:dir.appendingPathComponent("source"),bookmark:Data())
        try c.database.write { db in
            for i in 0..<count { try Photo(id:String(format:"%04d",i),rootID:root.id,relativePath:String(format:"%04d.jpg",i),identity:Data(),identityKey:"fixture:\(i)",captureDate:String(format:"2026:10:18 12:%02d:%02d",i/60%60,i%60),width:100,height:80).insert(db) }
        }
        return (c,dir)
    }
    private func registerMaster(_ catalog: CatalogStore,ids: [String],stacked: Bool = true,collection: String? = nil,root: StorageRoot? = nil) throws -> MergeSaved {
        let sourceRoot = try XCTUnwrap(catalog.roots().first),destination = root ?? sourceRoot
        let inputs = try ids.map { ImageRequest(photo:try XCTUnwrap(catalog.photo($0)),root:sourceRoot,recipe:nil) }
        let photo = Photo(id:"merged",rootID:destination.id,relativePath:"zz-merged.tif",identity:Data(),identityKey:"fixture:merged",width:100,height:80)
        let registered = try catalog.registerMergedPhoto(photo,root:destination,inputs:inputs,stackWithSources:stacked,collectionID:collection)
        return MergeSaved(photo:registered.photo,url:URL(fileURLWithPath:destination.path).appendingPathComponent(photo.relativePath),previousStacks:registered.previousStacks)
    }
    @MainActor func testMergedStackMovesOnlyParticipantsAndUndoKeepsMasterAndCollection() throws {
        let (c,dir) = try fixture(); defer { try? FileManager.default.removeItem(at:dir) }
        _ = try c.restoreStacks([PhotoStack(id:"remaining",members:["0000","0001","0002","0003"],collapsed:false),
                                 PhotoStack(id:"singleton",members:["0004","0005"]),
                                 PhotoStack(id:"untouched",members:["0006","0007"],collapsed:false)])
        try c.collection(name:"Merge",id:"c"); try c.membership(ids:["0004","0001"],collection:"c",add:true)
        let before = try c.stacks(),originals = try c.photos()
        let m = AppModel(previewRenderer:{ _,_,_ in throw LRCError("synthetic") })
        m.catalog = c; m.scope = "collection:c"; m.manualOrderEnabled = true; try m.reload()
        try m.completeImport(ids:["0007"],cancelled:false)
        m.choose(["0004","0001"],active:"0004")
        let saved = try registerMaster(c,ids:["0004","0001"],collection:"c")
        XCTAssertEqual(saved.previousStacks,before)
        XCTAssertEqual(try c.stacks().first { $0.id == "remaining" },PhotoStack(id:"remaining",members:["0000","0002","0003"],collapsed:false))
        XCTAssertNil(try c.stacks().first { $0.id == "singleton" })
        XCTAssertEqual(try c.stacks().first { $0.id == "untouched" },before.first { $0.id == "untouched" })
        XCTAssertEqual(try c.photos(ids:Set(originals.map(\.id))),originals)
        m.undo.beginUndoGrouping(); m.completePhotoMerge(saved); m.undo.endUndoGrouping()
        XCTAssertNil(m.error); XCTAssertEqual(m.scope,"collection:c"); XCTAssertTrue(m.manualOrderEnabled)
        XCTAssertEqual(m.activeID,saved.photo.id); XCTAssertEqual(m.selection,[saved.photo.id])
        XCTAssertEqual(m.resultCount,3); XCTAssertEqual(m.visibleCount,1)
        XCTAssertEqual(m.lastImport?.photoIDs,["0007"],"merging must not replace the last import")
        let merged = try XCTUnwrap(m.activeStack)
        XCTAssertEqual(merged.members,[saved.photo.id,"0004","0001"]); XCTAssertTrue(merged.collapsed)
        _ = try c.changeStacks(.collapse([merged.id],false))
        XCTAssertEqual(try c.page(m.query,offset:0).photos.map(\.id),[saved.photo.id,"0004","0001"])
        _ = try c.changeStacks(.collapse([merged.id],true))
        m.undo.undo()
        XCTAssertEqual(try c.stacks(),before); XCTAssertNotNil(try c.photo(saved.photo.id))
        XCTAssertEqual(Set(try c.allResultIDs(PhotoQuery(scope:"collection:c"))),[saved.photo.id,"0004","0001"])
        XCTAssertEqual(m.selection,["0004","0001"])
        m.undo.redo()
        XCTAssertEqual(m.activeStack,merged); XCTAssertEqual(m.selection,[saved.photo.id]); XCTAssertEqual(m.visibleCount,1)
    }
    @MainActor func testUnstackedMergeKeepsExistingStacksAndCurrentList() throws {
        let (c,dir) = try fixture(); defer { try? FileManager.default.removeItem(at:dir) }
        _ = try c.changeStacks(.group(top:"0000",members:["0001"]))
        let before = try c.stacks(),root = try XCTUnwrap(c.roots().first)
        let m = AppModel(previewRenderer:{ _,_,_ in throw LRCError("synthetic") })
        m.catalog = c; m.scope = root.id; try m.reload(); m.choose(["0001","0002"],active:"0002")
        let visible = m.visibleCount,saved = try registerMaster(c,ids:["0001","0002"],stacked:false)
        m.completePhotoMerge(saved)
        XCTAssertNil(m.error); XCTAssertNil(saved.previousStacks); XCTAssertEqual(try c.stacks(),before)
        XCTAssertEqual(m.scope,root.id); XCTAssertEqual(m.activeID,saved.photo.id); XCTAssertEqual(m.visibleCount,visible+1)
        XCTAssertFalse(m.undo.canUndo)
    }
    @MainActor func testMergeOutsideHeldFilteredSourceRevealsCorrectPageAndRetainsBrowseBack() throws {
        let (c,dir) = try fixture(405); defer { try? FileManager.default.removeItem(at:dir) }
        let root = try XCTUnwrap(c.roots().first)
        try c.setOrganization(ids:["0202","0203"],rating:5)
        let m = AppModel(previewRenderer:{ _,_,_ in throw LRCError("synthetic") })
        m.catalog = c; m.scope = root.id; m.photoSort = .filename
        m.ratingThreshold = 5; m.filterSections = [.attribute]; m.holdFilterResults = true
        try m.reload(); m.choose(["0202","0203"],active:"0203")
        let saved = try registerMaster(c,ids:["0203","0202"],root:StorageRoot(id:"masters",path:dir.appendingPathComponent("masters").path,bookmark:Data(),label:"Masters"))
        m.completePhotoMerge(saved)
        XCTAssertNil(m.error); XCTAssertEqual(m.scope,"all"); XCTAssertFalse(m.filtersEnabled); XCTAssertFalse(m.holdFilterResults)
        XCTAssertNil(m.query.snapshotID); XCTAssertEqual(m.pageOffset,200); XCTAssertTrue(m.photos.contains { $0.id == saved.photo.id })
        XCTAssertEqual(m.activeID,saved.photo.id); XCTAssertEqual(m.selection,[saved.photo.id]); XCTAssertTrue(m.canBrowseBack)
        XCTAssertEqual(m.visibleCount,404)
        m.navigateBrowse(-1)
        XCTAssertEqual(m.scope,root.id); XCTAssertTrue(m.filtersEnabled); XCTAssertTrue(m.holdFilterResults)
        XCTAssertNotNil(m.query.snapshotID); XCTAssertEqual(m.ratingThreshold,5); XCTAssertEqual(m.photoSort,.filename)
        XCTAssertEqual(m.resultCount,2)
        m.navigateBrowse(1)
        XCTAssertEqual(m.scope,"all"); XCTAssertEqual(m.pageOffset,200); XCTAssertEqual(m.activeID,saved.photo.id)
    }
    func testMergeRegistrationRollsBackIndexRootCollectionAndStacksOnFailure() throws {
        let (c,dir) = try fixture(); defer { try? FileManager.default.removeItem(at:dir) }
        _ = try c.changeStacks(.group(top:"0000",members:["0001","0002"]))
        try c.collection(name:"Merge",id:"c"); try c.membership(ids:["0000","0001"],collection:"c",add:true)
        let before = try c.stacks(),rootIDs = try c.roots().map(\.id),photos = try c.photos()
        let destination = StorageRoot(id:"masters",path:dir.appendingPathComponent("masters").path,bookmark:Data(),label:"Masters")
        try c.database.write { try $0.execute(sql:"CREATE TRIGGER fail_merge_stack BEFORE INSERT ON stackMember WHEN NEW.photoID='merged' BEGIN SELECT RAISE(ABORT,'injected stack failure'); END") }
        XCTAssertThrowsError(try registerMaster(c,ids:["0001","0000"],collection:"c",root:destination))
        XCTAssertEqual(try c.photos(),photos); XCTAssertEqual(try c.roots().map(\.id),rootIDs); XCTAssertEqual(try c.stacks(),before)
        XCTAssertEqual(Set(try c.allResultIDs(PhotoQuery(scope:"collection:c"))),["0000","0001"])
        try c.database.write { try $0.execute(sql:"DROP TRIGGER fail_merge_stack") }
        XCTAssertThrowsError(try registerMaster(c,ids:["0001","0000"],stacked:false,collection:"missing",root:destination))
        XCTAssertEqual(try c.photos(),photos); XCTAssertEqual(try c.roots().map(\.id),rootIDs); XCTAssertEqual(try c.stacks(),before)
    }
    func testMergeSplitMoveCoverRemoveAtomicAndBackup() throws {
        let (c,dir) = try fixture(); defer { try? FileManager.default.removeItem(at:dir) }
        _ = try c.changeStacks(.group(top:"0001",members:["0000","0002"]))
        _ = try c.changeStacks(.group(top:"0004",members:["0003"]))
        let inverse = try c.changeStacks(.group(top:"0005",members:["0000","0003","0005"]))
        let merged = try XCTUnwrap(c.stacks().first)
        XCTAssertEqual(merged.members,["0005","0000","0003","0001","0002","0004"])
        XCTAssertEqual(try c.stacks().count,1)
        let before = try c.stacks()
        XCTAssertThrowsError(try c.changeStacks(.group(top:"missing",members:["0005"])))
        XCTAssertEqual(try c.stacks(),before)
        _ = try c.changeStacks(.cover("0001")); XCTAssertEqual(try XCTUnwrap(c.stacks().first).members.first,"0001")
        _ = try c.changeStacks(.move("0002",-1)); XCTAssertEqual(try XCTUnwrap(c.stacks().first).members,["0001","0005","0000","0002","0003","0004"])
        _ = try c.changeStacks(.split("0002")); XCTAssertEqual(try c.stacks().count,2)
        _ = try c.changeStacks(.remove(["0000","0005"])); XCTAssertNil(try c.stacks().first { $0.members.contains("0001") })
        _ = try c.restoreStacks(inverse); XCTAssertEqual(try c.stacks(),inverse)
        let backup = dir.appendingPathComponent("backup.sqlite"); try c.backup(to:backup)
        let restored = try CatalogStore.restore(from:backup,to:dir.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.stacks(),inverse)
        _ = try restored.changeStacks(.ungroup(["0000"])); XCTAssertEqual(try restored.stacks().count,1)
    }
    func testWholeResultArrangementBeforePagingFilterFallbackAndHeldMembership() throws {
        let (c,dir) = try fixture(405); defer { try? FileManager.default.removeItem(at:dir) }
        let query = PhotoQuery(sort:.filename)
        _ = try c.changeStacks(.group(top:"0404",members:["0001","0200"]))
        var page = try c.page(query,offset:0)
        XCTAssertEqual(page.total,405); XCTAssertEqual(page.visibleTotal,403)
        XCTAssertEqual(Array(page.photos.prefix(3).map(\.id)),["0000","0404","0002"])
        XCTAssertEqual(try c.offset(of:"0404",query:query),1); XCTAssertNil(try c.offset(of:"0200",query:query))
        _ = try c.changeStacks(.collapse(Set(try c.stacks().map(\.id)),false))
        let expanded = try c.allResultIDs(query,visibleOnly:true)
        XCTAssertEqual(Array(expanded[1...3]),["0404","0001","0200"])
        let pages = try stride(from:0,to:405,by:200).flatMap { try c.page(query,offset:$0).photos.map(\.id) }
        XCTAssertEqual(pages,expanded); XCTAssertEqual(Set(pages).count,405)
        try c.collection(name:"Narrow",id:"c"); try c.membership(ids:["0200"],collection:"c",add:true)
        let narrowed = PhotoQuery(scope:"collection:c",sort:.filename)
        _ = try c.changeStacks(.collapse(Set(try c.stacks().map(\.id)),true))
        page = try c.page(narrowed,offset:0)
        XCTAssertEqual(page.photos.map(\.id),["0200"]); XCTAssertEqual(page.badges["0200"]?.matching,1)
        XCTAssertEqual(try XCTUnwrap(c.stacks().first).members.first,"0404","temporary representative never overwrites cover")
        var held = narrowed; held.snapshotID = try c.holdResults(narrowed,replacing:nil)
        _ = try c.createVirtualCopies(ids:["0200"])
        XCTAssertEqual(try c.page(held,offset:0).total,1,"new versions never enter held base")
        try c.membership(ids:["0200"],collection:"c",add:false)
        XCTAssertEqual(try c.page(held,offset:0).visibleTotal,0,"source removal wins over hold")
        XCTAssertEqual(try c.page(PhotoQuery(search:"no-match"),offset:2000).photos.count,0)
        XCTAssertEqual(try c.page(query,offset:99999).offset,400)
    }
    func testStrictCaptureTimeAndAdjacentGapPreviewRevalidation() throws {
        for bad in ["2025-02-29T10:00:00","2026-01-01T24:00:00","2026-01-01T01:60:00","2026-01-01","2026-01-01T10:00:00+14:30","2026-01-01T10:00:00Z\n","garbage"] { XCTAssertNil(CaptureTime.parse(bad),bad) }
        let a = try XCTUnwrap(CaptureTime.parse("2026:10:18 10:00:00.250+02:00")), b = try XCTUnwrap(CaptureTime.parse("2026-10-18T08:00:00.750Z"))
        XCTAssertEqual(b.seconds-a.seconds,0.5,accuracy:0.000001)
        XCTAssertNotEqual(a.hasOffset,CaptureTime.parse("2026:10:18 10:00:00")?.hasOffset)
        let (c,dir) = try fixture(); defer { try? FileManager.default.removeItem(at:dir) }
        _ = try c.changeStacks(.group(top:"0006",members:["0007"]))
        try c.database.write { try $0.execute(sql:"UPDATE photo SET captureDate=NULL WHERE id='0005'") }
        let preview = try CatalogStore.previewAutoStacks(c.stackInputs(query:PhotoQuery()),gap:1)
        XCTAssertEqual(preview.groups,[Array(0...4).map { String(format:"%04d",$0) }],"adjacent gap chains, not total duration")
        XCTAssertEqual(preview.skippedStacked,2); XCTAssertEqual(preview.skippedTime,1)
        let before = try c.applyAutoStacks(preview); XCTAssertEqual(try c.stacks().count,2)
        _ = try c.restoreStacks(before)
        try c.database.write { try $0.execute(sql:"UPDATE photo SET captureDate='2026:10:18 14:00:00' WHERE id='0000'") }
        XCTAssertThrowsError(try c.applyAutoStacks(preview)); XCTAssertEqual(try c.stacks(),before)
    }
    @MainActor func testSelectionDeletionVirtualCopyUndoAndExactOperationTargets() throws {
        let (c,dir) = try fixture(); defer { try? FileManager.default.removeItem(at:dir) }
        let m = AppModel(); m.catalog = c; m.photoSort = .filename; try m.reload()
        m.choose(["0001","0002","0003"],active:"0002")
        m.undo.beginUndoGrouping(); m.groupSelection(); m.undo.endUndoGrouping()
        XCTAssertEqual(m.selection,["0002"]); XCTAssertEqual(m.visibleCount,6)
        m.organize(rating:4); XCTAssertEqual(try c.photos(ids:["0001","0003"]).map(\.rating),[0,0])
        XCTAssertEqual(try m.exportSelection().map(\.id),["0002"])
        m.selectStackMembers(); XCTAssertEqual(m.selection,["0001","0002","0003"])
        m.choose(["0002"],active:"0002"); m.undo.removeAllActions()
        m.undo.beginUndoGrouping(); m.createVirtualCopies(); m.undo.endUndoGrouping()
        let copy = try XCTUnwrap(c.photos().first(where:\.isVirtualCopy))
        XCTAssertEqual(try XCTUnwrap(c.stacks().first).members,["0002",copy.id,"0001","0003"]); XCTAssertFalse(try XCTUnwrap(c.stacks().first).collapsed)
        m.undo.undo(); XCTAssertEqual(try XCTUnwrap(c.stacks().first).members,["0002","0001","0003"]); XCTAssertTrue(try XCTUnwrap(c.stacks().first).collapsed)
        m.undo.redo(); XCTAssertEqual(try XCTUnwrap(c.stacks().first).members.count,4)
        m.choose(["0002"],active:"0002"); m.undo.removeAllActions()
        let previous = try c.stacks()
        m.undo.beginUndoGrouping(); m.deleteSelectedVersions(); m.undo.endUndoGrouping()
        XCTAssertNil(try c.photo("0002")); XCTAssertEqual(try XCTUnwrap(c.stacks().first).members.first,copy.id)
        m.undo.undo(); XCTAssertEqual(try c.stacks(),previous); XCTAssertEqual(m.activeID,"0002")
        m.undo.redo(); XCTAssertNil(try c.photo("0002"))
    }

    @MainActor func testFilteredStackExpansionKeepsQueryAndExplainsHiddenMembers() throws {
        let (catalog, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try catalog.restoreStacks([PhotoStack(id: "partial", members: ["0000", "0001", "0002"])])
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic") })
        model.catalog = catalog; try model.reload()
        try model.completeImport(ids: ["0001"], cancelled: false)
        model.showLastImport()
        model.choose(["0001"], active: "0001")
        let query = model.query
        XCTAssertEqual(model.stackBadges["0001"]?.text, "▸ 1/3")
        let message = try XCTUnwrap(model.stackBadges["0001"]?.scopeNotice)
        model.toggleStack("0001")
        XCTAssertEqual(model.query, query)
        XCTAssertEqual(model.photos.map(\.id), ["0001"])
        XCTAssertEqual(model.stackBadges["0001"]?.text, "▾ 1/3")
        XCTAssertTrue(model.status.hasPrefix(message))
        XCTAssertEqual(model.notice?.text, message)
        XCTAssertTrue(try XCTUnwrap(model.stackBadges["0001"]?.description).contains(message))
        XCTAssertFalse(try XCTUnwrap(catalog.stacks().first).collapsed)
        model.toggleActiveStack(); model.toggleActiveStack()
        XCTAssertEqual(model.query, query, "Keyboard expansion must keep the same source and filters")
        XCTAssertEqual(model.stackBadges["0001"]?.text, "▾ 1/3")
        XCTAssertTrue(model.status.hasPrefix(message))
        model.setScope("all")
        XCTAssertNil(model.stackBadges["0001"]?.scopeNotice)
        XCTAssertEqual(model.stackBadges["0001"]?.text, "▾ 3/3")
        XCTAssertEqual(model.photos.count, 8)
        model.choose([], active: nil); model.catalog = nil
    }

    @MainActor func testNativeStackWindowAtBothSizes() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url:f.source,bookmark:AccessLease.bookmark(f.source,readOnly:true))
        for i in 0..<9 {
            let url = f.source.appendingPathComponent("连拍-\(i).jpg"); try f.image(url,color:i%2 == 0 ? .red : .blue)
            var photo = try ReferenceImporter.inspect(url:url,root:root,rootURL:f.source)
            photo.captureDate = String(format:"2026:10:18 12:00:%02d",i); try f.catalog.index(photo)
        }
        let m = AppModel(); m.catalog = f.catalog; m.photoSort = .filename; try m.reload()
        let ids = m.photos.map(\.id); m.choose(Set(ids.prefix(3)),active:ids[0]); m.groupSelection()
        let suite = "stacks-ui-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let workspace = NSHostingView(rootView:WorkspaceView(model:m).defaultAppStorage(defaults))
        let w = NSWindow(contentRect:CGRect(x:80,y:60,width:1280,height:800),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        w.isReleasedWhenClosed = false; w.title = "完整堆叠验证 — Phosdeck"; w.contentView = workspace; w.makeKeyAndOrderFront(nil)
        defer { w.orderOut(nil); w.contentView = nil; m.choose([],active:nil); m.catalog = nil }
        print("STACK_UI_SYNTHETIC_CATALOG=\(f.catalog.fileURL.path)")
        func collections(_ view: NSView) -> [NSCollectionView] {
            (view as? NSCollectionView).map { [$0] } ?? view.subviews.flatMap(collections)
        }
        for size in [CGSize(width:1440,height:900),CGSize(width:1280,height:800)] {
            w.setContentSize(size); try await Task.sleep(for:.milliseconds(300)); workspace.layoutSubtreeIfNeeded()
            XCTAssertEqual(workspace.bounds.size,size)
            XCTAssertEqual(m.stackBadges[ids[0]]?.count,3)
            m.toggleActiveStack(); XCTAssertEqual(m.visibleCount,9)
            let deadline = Date().addingTimeInterval(5)
            func expandedImagesVisible() -> Bool {
                workspace.layoutSubtreeIfNeeded()
                let grids = collections(workspace)
                guard grids.count == 2 else { return false }
                return grids.allSatisfy { grid in
                    guard let coordinator = grid.dataSource as? PhotoGrid.Coordinator, coordinator.photos.count == 9 else { return false }
                    return ids.prefix(3).allSatisfy { id in
                        guard let index = coordinator.photos.firstIndex(where: { $0.id == id }),
                              let item = grid.item(at: IndexPath(item: index, section: 0)) as? PhotoItem else { return false }
                        return item.displayedImage != nil && grid.visibleItems().contains(item) && item.view.bounds.height > 0
                    }
                }
            }
            while !expandedImagesVisible(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(expandedImagesVisible(), "Expanded members must have visible thumbnails in the grid and filmstrip")
            m.move(1); XCTAssertEqual(m.activeID,ids[1])
            m.toggleActiveStack(); XCTAssertEqual(m.visibleCount,7); XCTAssertEqual(m.selection.count,1)
            if let bitmap = workspace.bitmapImageRepForCachingDisplay(in:workspace.bounds) {
                workspace.cacheDisplay(in:workspace.bounds,to:bitmap)
                if let data = bitmap.representation(using:.png,properties:[:]) { let attachment = XCTAttachment(data:data,uniformTypeIdentifier:"public.png"); attachment.name = "stacks-\(Int(size.width))"; attachment.lifetime = .keepAlways; add(attachment) }
            }
        }
        let seconds = min(300,Double(ProcessInfo.processInfo.environment["PHOSDECK_STACK_UI_SECONDS"] ?? "0") ?? 0)
        if seconds > 0 { m.undo.removeAllActions(); m.showAutoStacks = true }
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { try await Task.sleep(for:.milliseconds(200)) }
        m.showAutoStacks = false
    }
    func testThousandsOfRecordsCountingPagingNoRecipeDecodes() throws {
        let (c,dir) = try fixture(5000); defer { try? FileManager.default.removeItem(at:dir) }
        let stacks = stride(from:0,to:3000,by:3).map { i in PhotoStack(members:(i..<i+3).map { String(format:"%04d",$0) }) }
        _ = try c.restoreStacks(stacks)
        // Invalid recipe bytes prove browse does not parse/decode every photo.
        try c.database.write { try $0.execute(sql:"UPDATE photo SET recipe=x'ff'") }
        let start = Date()
        var seen = [String]()
        for offset in stride(from:0,to:3000,by:200) {
            let page = try c.page(PhotoQuery(sort:.filename),offset:offset)
            XCTAssertEqual(page.total,5000); XCTAssertEqual(page.visibleTotal,3000)
            seen += page.photos.map(\.id)
        }
        XCTAssertEqual(Set(seen).count,3000); XCTAssertEqual(seen.count,3000)
        print("STACK_PERF_5000_1000_STACKS_15_PAGES_SECONDS=\(Date().timeIntervalSince(start))")
    }
}
