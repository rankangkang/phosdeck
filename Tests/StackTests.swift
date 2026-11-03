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
        for size in [CGSize(width:1440,height:900),CGSize(width:1280,height:800)] {
            w.setContentSize(size); try await Task.sleep(for:.milliseconds(300)); workspace.layoutSubtreeIfNeeded()
            XCTAssertEqual(workspace.bounds.size,size)
            XCTAssertEqual(m.stackBadges[ids[0]]?.count,3)
            m.toggleActiveStack(); XCTAssertEqual(m.visibleCount,9)
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
