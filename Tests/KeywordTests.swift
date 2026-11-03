import XCTest
import SwiftUI
import CoreImage
import GRDB
@testable import Phosdeck

final class KeywordTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func catalog(count: Int = 3) throws -> CatalogStore {
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url: folder.appendingPathComponent("source"), bookmark: Data())
        for n in 0..<count {
            let id = String(format: "%03d", n)
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id,
                                    width: 80, height: 40, metadata: JSONEncoder().encode(PhotoMetadata())))
        }
        return catalog
    }
    @MainActor private func model(_ catalog: CatalogStore) throws -> AppModel {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 40)
        let image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .blue), from: bounds))
        let model = AppModel(previewRenderer: { _, _, _ in
            RenderedImage(image: image, fullSize: bounds.size, orientedSourceSize: bounds.size, histogram: nil, elapsed: 0)
        })
        model.catalog = catalog; try model.reload()
        model.choose(["000", "001"], active: "000")
        return model
    }
    @MainActor func testOrganizationRefreshQueryCost() throws {
        let catalog = try catalog(count: 1)
        try catalog.database.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<9999)
                INSERT INTO photo (id,rootID,relativePath,identity,identityKey,width,height,availability)
                SELECT printf('%05d',i),rootID,printf('%05d.jpg',i),identity,printf('%05d',i),80,40,'available' FROM n,photo WHERE photo.id='000';
                INSERT INTO photoKeyword SELECT id,'travel','Travel' FROM photo;
                """)
        }
        let model = try model(catalog)
        model.selection = ["000"]
        var queries: [String] = []
        try catalog.database.writeWithoutTransaction { db in
            db.trace { if case let .statement(statement) = $0 { queries.append(statement.sql) } }
        }
        defer { try? catalog.database.writeWithoutTransaction { $0.trace(options: []) { _ in } } }
        var times: [Double] = []
        for rating in 1...5 {
            let started = Date(); model.organize(rating: rating)
            times.append(Date().timeIntervalSince(started) * 1000)
        }
        XCTAssertEqual(model.active?.rating, 5)
        XCTAssertEqual(model.totalCount, 10000)
        let selects = queries.filter { $0.uppercased().hasPrefix("SELECT") }
        print("NATIVE_PERF organization ms=\(times) selects=\(selects.count / 5)")
        XCTAssertFalse(selects.contains { $0.contains("photoKeyword") }, "Unchanged selection and ratings do not change keyword totals")
        XCTAssertFalse(selects.contains { $0.contains("storageRoot") || $0.contains("adjustmentPreset") || $0.contains("editHistory") || $0.contains("editSnapshot") })
        queries.removeAll(); model.undo.removeAllActions()
        model.changeKeyword("新关键词", adding: true)
        XCTAssertEqual(model.keywords.first { $0.name == "新关键词" }?.selected, 1)
        XCTAssertEqual(model.activeID, "000")
        XCTAssertFalse(queries.contains { $0.contains("storageRoot") || $0.contains("adjustmentPreset") || $0.contains("editHistory") || $0.contains("editSnapshot") })
        model.undo.undo()
        XCTAssertNil(model.keywords.first { $0.name == "新关键词" })
        XCTAssertEqual(model.activeID, "000")
    }

    func testKeywordBatchesNormalizationAtomicUndoAndSourceIsolation() throws {
        let catalog = try catalog(), ids: Set<String> = ["000", "001"]
        let originals = try catalog.photos()
        XCTAssertEqual(try catalog.changeKeyword("  Café  ", ids: ids, adding: true), ["000": [], "001": []])
        XCTAssertTrue(try catalog.changeKeyword("CAFE\u{301}", ids: ids, adding: true).isEmpty)
        XCTAssertEqual(try catalog.keywordSummary(selected: ["000"]), [KeywordSummary(keyword: "café", name: "Café", total: 2, selected: 1)])
        XCTAssertEqual(try catalog.keywordSummary(selected: []).first?.selected, 0)
        _ = try catalog.changeKeyword("私人", ids: ["000"], adding: true)
        let removed = try catalog.changeKeyword("café", ids: ids, adding: false)
        XCTAssertEqual(Set(try XCTUnwrap(removed["000"])), ["Café", "私人"])
        let inverse = try catalog.restoreKeywords(removed)
        XCTAssertEqual(try catalog.keywordSummary(selected: ids).first?.selected, 2)
        _ = try catalog.restoreKeywords(inverse)
        XCTAssertEqual(try catalog.keywordSummary(selected: ids).map(\.name), ["私人"])
        let before = try catalog.keywordSummary(selected: ids)
        XCTAssertThrowsError(try catalog.changeKeyword("无效照片", ids: ["000", "missing"], adding: true))
        for invalid in [" \n ", "x\ny", "x\u{0}y", String(repeating: "长", count: 101)] {
            XCTAssertThrowsError(try catalog.changeKeyword(invalid, ids: ids, adding: true))
        }
        XCTAssertThrowsError(try catalog.restoreKeywords(["000": ["新词"], "001": ["不\n合法"]]))
        XCTAssertEqual(try catalog.keywordSummary(selected: ids), before, "An invalid batch must roll back every photo")
        XCTAssertEqual(try catalog.photos(), originals, "Keywords must not change source identities, recipes or image revisions")
        try catalog.index(originals[0])
        XCTAssertEqual(try catalog.keywordSummary(selected: ids), before, "Rescanning must preserve local keywords")
        try catalog.database.write { try $0.execute(sql: "UPDATE photo SET availability='missing' WHERE id='002'") }
        _ = try catalog.changeKeyword("离线整理", ids: ["002"], adding: true)
        XCTAssertEqual(try catalog.page(PhotoQuery(keyword: "离线整理"), offset: 0).photos.map(\.id), ["002"])
        try catalog.database.write { try $0.execute(sql: "DELETE FROM photo WHERE id='002'") }
        XCTAssertFalse(try catalog.keywordSummary(selected: []).contains { $0.name == "离线整理" })
        let emoji = String(repeating: "👍🏽", count: 100)
        _ = try catalog.changeKeyword(emoji, ids: ["000"], adding: true)
        XCTAssertEqual(try catalog.page(PhotoQuery(keyword: emoji), offset: 0).total, 1, "Count user-visible characters, not SQLite Unicode scalars")
        XCTAssertThrowsError(try catalog.changeKeyword(emoji + "👍🏽", ids: ["000"], adding: true))
    }

    func testKeywordSQLPaginationCombinedFiltersBackupAndManifest() throws {
        var catalog: CatalogStore? = try catalog(count: 203)
        let ids = Set((0..<203).map { String(format: "%03d", $0) })
        let literal = "100%_' OR 1=1 --"
        _ = try catalog!.changeKeyword(literal, ids: ids, adding: true)
        _ = try catalog!.changeKeyword("精选", ids: ["201", "202"], adding: true)
        try catalog!.setOrganization(ids: ["201"], rating: 5, flag: 1)
        try catalog!.collection(name: "小集合", id: "c")
        try catalog!.membership(ids: ["201"], collection: "c", add: true)
        let page = try catalog!.page(PhotoQuery(keyword: literal), offset: 200)
        XCTAssertEqual(page.total, 203); XCTAssertEqual(page.photos.map(\.id), ["200", "201", "202"])
        XCTAssertEqual(try catalog!.offset(of: "201", query: PhotoQuery(keyword: literal)), 201)
        XCTAssertEqual(try catalog!.page(PhotoQuery(keyword: "%"), offset: 0).total, 0, "Keyword filtering is exact, with bound SQL arguments")
        let query = PhotoQuery(scope: "collection:c", search: "201", ratingThreshold: 5, flags: [1], keyword: "精选")
        XCTAssertEqual(try catalog!.page(query, offset: 0).photos.map(\.id), ["201"])
        let backup = folder.appendingPathComponent("backup.sqlite"), manifest = folder.appendingPathComponent("manifest.json")
        try catalog!.backup(to: backup); try catalog!.exportManifest(to: manifest)
        let expected = try catalog!.keywordSummary(selected: ids)
        catalog = nil
        catalog = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        XCTAssertEqual(try catalog!.keywordSummary(selected: ids), expected)
        let restored = try CatalogStore.restore(from: backup, to: folder.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.keywordSummary(selected: ids), expected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let photos = try XCTUnwrap(json["photos"] as? [[String: Any]])
        let exported = try XCTUnwrap(photos.first { $0["id"] as? String == "201" }?["keywords"] as? [String])
        XCTAssertEqual(Set(exported), [literal, "精选"])
    }

    @MainActor func testModelMixedKeywordsUndoFilteredSelectionAndComparison() throws {
        let catalog = try catalog()
        _ = try catalog.changeKeyword("旅行", ids: ["000"], adding: true)
        _ = try catalog.changeKeyword("专属", ids: ["001"], adding: true)
        let model = try model(catalog)
        XCTAssertEqual(model.keywords.first { $0.name == "旅行" }?.selected, 1)
        model.changeKeyword("旅行", adding: true)
        model.changeKeyword("旅行", adding: true) // A no-op must not add another undo step.
        XCTAssertEqual(model.keywords.first { $0.name == "旅行" }?.selected, 2)
        model.undo.undo()
        XCTAssertEqual(try catalog.page(PhotoQuery(keyword: "旅行"), offset: 0).photos.map(\.id), ["000"])
        XCTAssertEqual(try catalog.page(PhotoQuery(keyword: "专属"), offset: 0).photos.map(\.id), ["001"])
        model.undo.redo()
        model.keywordFilter = "旅行"; model.filterChanged()
        XCTAssertEqual(model.resultCount, 2)
        model.beginComparison()
        let comparison = try XCTUnwrap(model.comparison)
        defer { comparison.cancel() }
        XCTAssertEqual(comparison.reference.photo?.id, "000"); XCTAssertEqual(model.activeID, "001")
        model.changeKeyword("旅行", adding: false)
        XCTAssertEqual(comparison.reference.photo?.id, "000"); XCTAssertNil(comparison.candidate.photo)
        XCTAssertEqual(try catalog.page(PhotoQuery(keyword: "旅行"), offset: 0).photos.map(\.id), ["000"])
        model.undo.undo()
        XCTAssertEqual(model.activeID, "001"); XCTAssertEqual(model.keywordFilter, "旅行")
        XCTAssertEqual(model.keywords.first { $0.name == "专属" }?.selected, 1)
        model.undo.redo(); XCTAssertNil(model.activeID)
        model.endComparison(); model.keywordFilter = ""; model.filterChanged()
        model.choose(["000"], active: "000"); model.changeKeyword("旅行", adding: false)
        XCTAssertFalse(model.keywords.contains { $0.name == "旅行" })
        model.undo.undo(); XCTAssertTrue(model.keywords.contains { $0.name == "旅行" })
        try model.activateCatalog(CatalogStore(directory: folder.appendingPathComponent("next")))
        XCTAssertTrue(model.keywords.isEmpty); XCTAssertEqual(model.keywordFilter, "")
    }

    @MainActor func testNativeKeywordEditorAndNarrowWorkspaceLayout() async throws {
        let catalog = try catalog()
        _ = try catalog.changeKeyword("旅行", ids: ["000", "001"], adding: true)
        _ = try catalog.changeKeyword("部分照片已有的关键词", ids: ["001"], adding: true)
        _ = try catalog.changeKeyword("尚未添加到所选照片", ids: ["002"], adding: true)
        let model = try model(catalog)
        let host = NSHostingView(rootView: KeywordEditor(model: model).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 422, height: 405), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        XCTAssertTrue(fields(host).contains { $0.placeholderString == "输入或查找关键词" })
        func snapshot(_ view: NSView, name: String) throws {
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: image)
            let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try snapshot(host, name: "keyword-editor-mixed-selection")
        let field = try XCTUnwrap(fields(host).first { $0.placeholderString == "输入或查找关键词" })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("新关键词", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(50))
        editor.insertNewline(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.keywords.first { $0.name == "新关键词" }?.selected, 2, "Return in the native field must apply the keyword")
        let workspace = NSHostingView(rootView: WorkspaceView(model: model))
        let workspaceWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        workspaceWindow.contentView = workspace
        defer { workspaceWindow.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        model.keywordFilter = "旅行"
        try await Task.sleep(for: .milliseconds(120)); workspace.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.resultCount, 2)
        XCTAssertEqual(workspace.frame.width, 1000)
        try snapshot(workspace, name: "keyword-filter-1000x640")
    }
}

extension KeywordTests {
    @MainActor func testCaptionsMixedBatchUndoVersionIsolationAndSelectionGuard() throws {
        let catalog = try catalog(), model = try model(catalog)
        _ = try catalog.setCaptions(["000": "原题注", "001": "另一张\n第二行"])
        let before = try catalog.photos()
        model.undo.removeAllActions(); model.undo.beginUndoGrouping()
        XCTAssertTrue(model.changeCaption("中文 café & <夕阳> 🌅\n第二行", ids: ["000", "001"], catalogPath: catalog.fileURL.path))
        model.undo.endUndoGrouping()
        XCTAssertEqual(Set(try catalog.captions(ids: ["000", "001"]).values).count, 1)
        model.undo.undo()
        XCTAssertEqual(try catalog.captions(ids: ["000", "001"]), ["000": "原题注", "001": "另一张\n第二行"])
        model.undo.redo()
        XCTAssertEqual(try catalog.photo("000")?.caption, "中文 café & <夕阳> 🌅\n第二行")
        XCTAssertFalse(model.changeCaption("wrong", ids: ["000"], catalogPath: catalog.fileURL.path))
        XCTAssertFalse(model.changeCaption("wrong", ids: ["000", "001"], catalogPath: "different catalog"))
        model.busy = true
        XCTAssertFalse(model.changeCaption("wrong", ids: ["000", "001"], catalogPath: catalog.fileURL.path)); model.busy = false
        let copy = try XCTUnwrap(catalog.createVirtualCopies(ids: ["000"]).first)
        XCTAssertEqual(copy.caption, try catalog.photo("000")?.caption)
        _ = try catalog.setCaptions([copy.id: "仅副本"])
        XCTAssertNotEqual(try catalog.photo("000")?.caption, try catalog.photo(copy.id)?.caption)
        _ = try catalog.setCaptions(["000": ""])
        XCTAssertEqual(try catalog.photo("000")?.caption, "")
        let after = try catalog.photos(ids: Set(before.map(\.id)))
        for original in before {
            let current = try XCTUnwrap(after.first { $0.id == original.id })
            XCTAssertEqual(current.recipe, original.recipe); XCTAssertEqual(current.recipeRevision, original.recipeRevision)
            XCTAssertEqual(current.identity, original.identity); XCTAssertEqual(current.metadata, original.metadata)
            XCTAssertEqual(current.rating, original.rating); XCTAssertEqual(current.colorLabel, original.colorLabel)
        }
        _ = try catalog.setCaptions(["000": "重扫保留"])
        _ = try catalog.index(before[0])
        XCTAssertEqual(try catalog.photo("000")?.caption, "重扫保留")
        XCTAssertTrue(try catalog.editHistory(photoID: "000").isEmpty)
    }
    func testCaptionAtomicValidationClearAndManagementManifest() throws {
        let catalog = try catalog()
        _ = try catalog.setCaptions(["000": "保留"])
        XCTAssertThrowsError(try catalog.setCaptions(["000": "不得部分写入", "missing": "x"]))
        XCTAssertEqual(try catalog.photo("000")?.caption, "保留")
        for invalid in ["bad\0text", "bad\u{1}text", String(repeating: "字", count: 2001)] {
            XCTAssertThrowsError(try catalog.setCaptions(["000": invalid]))
        }
        XCTAssertEqual(try PhotoCaption.normalized("第一行\r\n第二行"), "第一行\n第二行")
        XCTAssertEqual(try PhotoCaption.normalized(" \n\t"), "")
        let manifest = folder.appendingPathComponent("caption-manifest.json")
        try catalog.exportManifest(to: manifest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let photos = try XCTUnwrap(json["photos"] as? [[String: Any]])
        XCTAssertEqual(photos.first { $0["id"] as? String == "000" }?["caption"] as? String, "保留")
        let copy = folder.appendingPathComponent("backup.sqlite"); try catalog.backup(to: copy)
        let restored = try CatalogStore.restore(from: copy, to: folder.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.photo("000")?.caption, "保留")
    }
    func testGlobalKeywordRenameAllVersionsConflictStalenessAndExactRestoration() throws {
        let catalog = try catalog(count: 205)
        let copy = try XCTUnwrap(catalog.createVirtualCopies(ids: ["001"]).first)
        let all = Set(try catalog.photos().map(\.id))
        _ = try catalog.changeKeyword("Travel", ids: all, adding: true)
        _ = try catalog.changeKeyword("保留", ids: ["001"], adding: true)
        _ = try catalog.changeKeyword("Existing", ids: ["000"], adding: true)
        _ = try catalog.changeKeyword("Hidden", ids: ["003"], adding: true)
        _ = try catalog.setCaptions(["001": "保留题注"])
        try catalog.database.write { db in
            try db.execute(sql: "UPDATE photoKeyword SET name='TRAVEL' WHERE photoID='003' AND keyword='travel'")
            try db.execute(sql: "UPDATE photo SET deleted=1 WHERE id='003'")
        }
        let before = try catalog.database.read { try Dictionary(uniqueKeysWithValues: Photo.fetchAll($0).map { ($0.id, $0) }) }
        let state = try catalog.keywordNameState("TRAVEL")
        XCTAssertEqual(state.names.count, 206, "Include unselected, off-page, virtual and retained/deleted versions")
        let frozen = try catalog.exportDescriptions(ids: ["001"])
        for invalid in ["", " ", "a\nb", "a\0b", "two,words", String(repeating: "长", count: 101), "EXISTING", "hidden"] {
            XCTAssertThrowsError(try catalog.renameKeyword(state, to: invalid))
            XCTAssertEqual(try catalog.keywordNameState("travel"), state)
        }
        let caseChanged = try catalog.renameKeyword(state, to: "travel")
        XCTAssertTrue(caseChanged.names.values.allSatisfy { $0 == "travel" }, "Case-only changes update spelling without colliding with themselves")
        try catalog.restoreKeywordName(from: caseChanged, to: state)
        XCTAssertEqual(try catalog.keywordNameState("travel"), state, "Undo restores each original spelling")
        let renamed = try catalog.renameKeyword(state, to: "旅行")
        XCTAssertEqual(try catalog.page(PhotoQuery(keyword: "旅行"), offset: 100).total, 205)
        XCTAssertFalse(try catalog.page(PhotoQuery(keyword: "旅行"), offset: 100).photos.isEmpty)
        XCTAssertEqual(try catalog.page(PhotoQuery(keyword: "travel"), offset: 0).total, 0)
        XCTAssertEqual(renamed.names[copy.id], "旅行")
        XCTAssertEqual(try catalog.exportDescriptions(ids: ["001"])["001"]?.keywords.sorted(), ["保留", "旅行"].sorted())
        XCTAssertEqual(frozen["001"]?.keywords.sorted(), ["Travel", "保留"].sorted(), "Previously frozen descriptions remain value snapshots")
        XCTAssertEqual(try catalog.database.read { try Dictionary(uniqueKeysWithValues: Photo.fetchAll($0).map { ($0.id, $0) }) }, before)
        let backup = folder.appendingPathComponent("rename-backup.sqlite"); try catalog.backup(to: backup)
        let reopened = try CatalogStore.restore(from: backup, to: folder.appendingPathComponent("renamed-copy"))
        XCTAssertEqual(try reopened.keywordNameState("旅行"), renamed)
        try catalog.restoreKeywordName(from: renamed, to: state)
        XCTAssertEqual(try catalog.keywordNameState("travel"), state)
        _ = try catalog.changeKeyword("travel", ids: ["000"], adding: false)
        let changed = try catalog.keywordNameState("travel")
        XCTAssertThrowsError(try catalog.renameKeyword(state, to: "过期草稿"))
        XCTAssertEqual(try catalog.keywordNameState("travel"), changed)
        XCTAssertTrue(try catalog.keywordNameState("过期草稿").names.isEmpty)
    }
    @MainActor func testGlobalKeywordRenameOneUndoFilterRecentAndCatalogGuards() throws {
        let catalog = try catalog(count: 205)
        _ = try catalog.changeKeyword("Travel", ids: Set(try catalog.photos().map(\.id)), adding: true)
        let model = try model(catalog)
        model.choose(["000"], active: "000")
        model.keywordFilter = "TRAVEL"; model.filterCriteriaChanged()
        model.recentKeywords = ["Travel", "其他"]
        model.undo.removeAllActions()
        let state = try catalog.keywordNameState("travel")
        try model.renameKeyword(state, to: "旅行", catalogPath: catalog.fileURL.path)
        XCTAssertEqual(model.keywordFilter, "旅行"); XCTAssertEqual(model.resultCount, 205)
        XCTAssertEqual(model.selection, ["000"]); XCTAssertEqual(model.activeID, "000")
        XCTAssertEqual(model.recentKeywords, ["旅行", "其他"])
        XCTAssertTrue(try catalog.keywordNameState("travel").names.isEmpty)
        model.undo.undo()
        XCTAssertEqual(try catalog.keywordNameState("travel"), state)
        XCTAssertEqual(model.keywordFilter, "travel"); XCTAssertEqual(model.recentKeywords, ["Travel", "其他"])
        XCTAssertFalse(model.undo.canUndo, "One undo restores the entire rename")
        model.undo.redo()
        XCTAssertEqual(try catalog.keywordNameState("旅行").names.count, 205)
        model.undo.undo()
        XCTAssertThrowsError(try model.renameKeyword(state, to: "错误目录", catalogPath: catalog.fileURL.path + "-other"))
        model.busy = true
        XCTAssertThrowsError(try model.renameKeyword(state, to: "忙碌", catalogPath: catalog.fileURL.path))
        model.busy = false
        XCTAssertEqual(try catalog.keywordNameState("travel"), state)
        XCTAssertTrue(model.canLocateOriginal, "Unavailable preview does not hide the source-location command")
    }
    @MainActor func testGlobalKeywordRenameEditorLongNameLayoutsAndDraft() async throws {
        let catalog = try catalog(), model = try model(catalog)
        let name = String(repeating: "长", count: 100)
        _ = try catalog.changeKeyword(name, ids: ["000", "001"], adding: true)
        let state = try catalog.keywordNameState(name)
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: KeywordRenameEditor(model: model, original: state, catalogPath: catalog.fileURL.path, done: { _ in }).padding(16).frame(width: 390).instrumentForm().preferredColorScheme(scheme))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 390, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.height, 560)
            XCTAssertEqual(try catalog.keywordNameState(name), state, "Opening the form does not apply a rename")
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: image)
            let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "keyword-rename-\(scheme)"; attachment.lifetime = .keepAlways; add(attachment)
            window.contentView = nil
        }
    }
    @MainActor func testCaptionNativeEditorLayoutsAndSelectionReset() async throws {
        let catalog = try catalog(), model = try model(catalog)
        _ = try catalog.setCaptions(["000": "初始题注", "001": "不同题注"])
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: CaptionEditor(model: model).padding(16).frame(width: 390).instrumentForm().preferredColorScheme(scheme))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 390, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
            func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
            let editor = try XCTUnwrap(editors(host).first)
            XCTAssertEqual(editor.string, "", "Mixed values must not masquerade as a shared caption")
            XCTAssertTrue(window.makeFirstResponder(editor)); editor.insertText("未提交草稿", replacementRange: NSRange(location: 0, length: 0))
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(try catalog.photo("000")?.caption, "初始题注", "Typing does not save")
            model.selection = ["000"]
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editor.string, "初始题注", "Selection changes discard the previous selection's draft")
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: image)
            let attachment = XCTAttachment(data: try XCTUnwrap(image.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "caption-\(scheme)"; attachment.lifetime = .keepAlways; add(attachment)
            window.contentView = nil; model.selection = ["000", "001"]
        }
    }
}
