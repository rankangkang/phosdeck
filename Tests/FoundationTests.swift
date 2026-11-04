import XCTest
import GRDB
@testable import Phosdeck

final class FoundationTests: XCTestCase {
    func testBuiltAppContainsReleaseVersion() throws {
        let info = try XCTUnwrap(Bundle(for: AppDelegate.self).infoDictionary)
        let version = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
        XCTAssertNotNil(build.range(of: #"^[1-9]\d*$"#, options: .regularExpression))
        XCTAssertEqual(info["PhosdeckReleaseVersion"] as? String, "\(version)-alpha.\(build)")
    }

    func testReleasePackagingRejectsDevelopmentApp() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appendingPathComponent("scripts/package-release.sh").path,
                             Bundle(for: AppDelegate.self).bundleURL.path]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(message.contains("Developer ID Application"), message)
    }

    func testReleaseVerificationRejectsMismatchedVersion() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repository.appendingPathComponent("scripts/verify-release.sh").path,
                             Bundle(for: AppDelegate.self).bundleURL.path, "999.0.0-alpha.1"]
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(message.contains("Release version does not match"), message)
    }

    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func testPublicationNeverReplacesExistingFile() throws {
        let target = folder.appendingPathComponent("original")
        try SafeFileWriter.write(Data("original".utf8), to: target)
        XCTAssertThrowsError(try SafeFileWriter.write(Data("replacement".utf8), to: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }
    func testRaceAtPublicationPreservesBothFiles() throws {
        let staged = try SafeFileWriter.stage(in: folder)
        try Data("ours".utf8).write(to: staged)
        let target = folder.appendingPathComponent("raced")
        try Data("theirs".utf8).write(to: target)
        XCTAssertThrowsError(try SafeFileWriter.publish(staged, to: target))
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "ours")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "theirs")
    }
    func testCatalogLockPersistenceAndRestore() throws {
        let location = folder.appendingPathComponent("catalog")
        var catalog: CatalogStore? = try CatalogStore(directory: location)
        XCTAssertThrowsError(try CatalogStore(directory: location))
        let root = try catalog!.addRoot(url: folder.appendingPathComponent("photos"), bookmark: Data())
        let photo = Photo(id: "p", rootID: root.id, relativePath: "A.ARW", identity: Data(), identityKey: "1:2", width: 10, height: 20)
        try catalog!.index(photo)
        try catalog!.setOrganization(ids: ["p"], rating: 5, flag: -1)
        try catalog!.collection(name: "精选", id: "c")
        try catalog!.membership(ids: ["p"], collection: "c", add: true)
        try catalog!.index(photo)
        XCTAssertThrowsError(try catalog!.setOrganization(ids: ["p"], rating: 6))
        let backup = folder.appendingPathComponent("backup.sqlite")
        try catalog!.backup(to: backup)
        print(try catalog!.diagnostics())
        catalog = nil
        catalog = try CatalogStore(directory: location)
        XCTAssertEqual(try catalog!.photos().first?.rating, 5)
        XCTAssertEqual(try catalog!.photos().count, 1)
        let recovered = try CatalogStore.restore(from: backup, to: folder.appendingPathComponent("recovered"))
        XCTAssertEqual(try recovered.photos().first?.flag, -1)
        XCTAssertEqual(try recovered.members("c"), ["p"])
        try recovered.deleteCollection("c")
        XCTAssertEqual(try recovered.photos().count, 1)
    }
    func testOverlappingRootRejected() throws {
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
        _ = try catalog.addRoot(url: folder.appendingPathComponent("photos"), bookmark: Data())
        XCTAssertThrowsError(try catalog.addRoot(url: folder.appendingPathComponent("photos/child"), bookmark: Data()))
        XCTAssertThrowsError(try catalog.addRoot(url: folder, bookmark: Data()))
    }
    func testUnknownSchemaRefusesOpen() throws {
        let location = folder.appendingPathComponent("future")
        var catalog: CatalogStore? = try CatalogStore(directory: location)
        try catalog!.database.write { try $0.execute(sql: "PRAGMA user_version = 99") }
        catalog = nil
        XCTAssertThrowsError(try CatalogStore(directory: location))
    }
}

extension FoundationTests {
    private func editFixture(_ catalog: CatalogStore) throws -> EditRecipe {
        let root = try catalog.addRoot(url: folder.appendingPathComponent("originals"), bookmark: Data())
        for id in ["a", "b"] {
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".ARW", identity: Data(), identityKey: id, width: 80, height: 120))
        }
        return EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    func testHistorySnapshotPersistenceAndRestoreDoesNotDiscardFuture() throws {
        let location = folder.appendingPathComponent("edits")
        var catalog: CatalogStore? = try CatalogStore(directory: location)
        var recipe = try editFixture(catalog!)
        try catalog!.saveRecipe(id: "a", recipe: recipe)
        try catalog!.saveRecipe(id: "a", recipe: recipe) // No-op must not add an undo/history row.
        recipe.exposure = 1
        try catalog!.saveRecipe(id: "a", recipe: recipe)
        try catalog!.createSnapshot(photoID: "a", title: "  明亮  ")
        recipe.exposure = -1
        try catalog!.saveRecipe(id: "a", recipe: recipe)
        let snapshot = try XCTUnwrap(catalog!.snapshots(photoID: "a").first)
        let restored = try JSONDecoder().decode(EditRecipe.self, from: snapshot.recipe)
        try catalog!.saveRecipe(id: "a", recipe: restored, title: "恢复快照：明亮")
        XCTAssertEqual(try catalog!.editHistory(photoID: "a").count, 4)
        XCTAssertEqual(try catalog!.editHistory(photoID: "a", limit: 1, offset: 1).first?.title, "曝光 -1.00")
        XCTAssertTrue(try catalog!.editHistory(photoID: "b").isEmpty)
        XCTAssertThrowsError(try catalog!.createSnapshot(photoID: "a", title: "   "))
        let revision = try catalog!.photo("a")?.recipeRevision
        var wrongSource = recipe; wrongSource.sourceDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try catalog!.saveRecipe(id: "a", recipe: wrongSource))
        XCTAssertEqual(try catalog!.photo("a")?.recipeRevision, revision)
        XCTAssertEqual(try catalog!.editHistory(photoID: "a").count, 4)
        try catalog!.renameSnapshot(id: snapshot.id, photoID: "b", title: "不应修改")
        XCTAssertEqual(try catalog!.snapshots(photoID: "a").first?.title, "明亮")
        let backup = folder.appendingPathComponent("edits-backup.sqlite")
        try catalog!.backup(to: backup)
        catalog = nil
        catalog = try CatalogStore(directory: location)
        XCTAssertEqual(try catalog!.snapshots(photoID: "a").count, 1)
        XCTAssertEqual(try catalog!.editHistory(photoID: "a").first?.title, "恢复快照：明亮")
        let recovered = try CatalogStore.restore(from: backup, to: folder.appendingPathComponent("restored-edits"))
        XCTAssertEqual(try recovered.editHistory(photoID: "a").count, 4)
        XCTAssertEqual(try recovered.snapshots(photoID: "a").first?.recipe, snapshot.recipe)
        let manifest = folder.appendingPathComponent("manifest.json")
        try catalog!.exportManifest(to: manifest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let photos = try XCTUnwrap(json["photos"] as? [[String: Any]])
        XCTAssertEqual((photos.first { $0["id"] as? String == "a" }?["editHistory"] as? [Any])?.count, 4)
    }
    func testSnapshotDeletionRestoresExactRowAndRejectsStaleOrConflictingState() throws {
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("snapshot-delete"))
        let recipe = try editFixture(catalog)
        for id in ["a", "b"] { try catalog.saveRecipe(id: id, recipe: recipe); try catalog.createSnapshot(photoID: id, title: "保留 " + id) }
        var snapshot = try XCTUnwrap(catalog.snapshots(photoID: "a").first)
        // Deliberately noncanonical JSON proves Undo preserves the original BLOB.
        snapshot.recipe = Data("\n".utf8) + snapshot.recipe + Data("\n".utf8)
        try catalog.database.write { try $0.execute(sql: "UPDATE editSnapshot SET recipe=? WHERE id=?", arguments: [snapshot.recipe, snapshot.id]) }
        let photo = try catalog.photo("a"), history = try catalog.editHistory(photoID: "a").map(\.recipe)
        let other = try catalog.snapshots(photoID: "b")
        var stale = snapshot; stale.photoID = "b"
        XCTAssertThrowsError(try catalog.deleteSnapshot(stale))
        stale = snapshot; stale.title = "过期名称"
        XCTAssertThrowsError(try catalog.deleteSnapshot(stale))
        try catalog.deleteSnapshot(snapshot)
        XCTAssertTrue(try catalog.snapshots(photoID: "a").isEmpty)
        XCTAssertThrowsError(try catalog.deleteSnapshot(snapshot))
        try catalog.restoreSnapshot(snapshot)
        XCTAssertEqual(try catalog.snapshots(photoID: "a"), [snapshot])
        XCTAssertThrowsError(try catalog.restoreSnapshot(snapshot))
        try catalog.renameSnapshot(id: snapshot.id, photoID: "a", title: "后来改名")
        XCTAssertThrowsError(try catalog.deleteSnapshot(snapshot))
        XCTAssertThrowsError(try catalog.restoreSnapshot(snapshot))
        XCTAssertEqual(try catalog.snapshots(photoID: "a").first?.title, "后来改名")
        XCTAssertEqual(try catalog.photo("a"), photo)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").map(\.recipe), history)
        XCTAssertEqual(try catalog.snapshots(photoID: "b"), other)
        let renamed = try XCTUnwrap(catalog.snapshots(photoID: "a").first)
        try catalog.deleteSnapshot(renamed)
        try catalog.database.write { try $0.execute(sql: "UPDATE photo SET deleted=1 WHERE id='a'") }
        XCTAssertThrowsError(try catalog.restoreSnapshot(renamed))
        try catalog.database.write { try $0.execute(sql: "UPDATE photo SET deleted=0 WHERE id='a'") }
        try catalog.restoreSnapshot(renamed)
        let backup = folder.appendingPathComponent("snapshot-reopen.phoscat")
        try catalog.backup(to: backup)
        let reopened = try CatalogStore(fileURL: backup)
        XCTAssertEqual(try reopened.snapshots(photoID: "a"), [renamed])
        XCTAssertEqual(try reopened.snapshots(photoID: "b"), other)
    }
    func testOldV3CatalogAndRestoreAreRefusedWithoutChangingBytes() throws {
        let location = folder.appendingPathComponent("old-catalog")
        try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true)
        let file = location.appendingPathComponent("Catalog.sqlite")
        let original = Data("unsupported old recipe; keep exactly".utf8)
        let old = try DatabaseQueue(path:file.path)
        try old.write { db in
            try db.execute(sql:"CREATE TABLE catalogMeta(id TEXT PRIMARY KEY,schemaVersion INTEGER); INSERT INTO catalogMeta VALUES ('old',3); CREATE TABLE photo(id TEXT PRIMARY KEY,recipe BLOB); PRAGMA user_version=3")
            try db.execute(sql:"INSERT INTO photo VALUES ('a',?)",arguments:[original])
        }
        try old.close()
        let before = try Data(contentsOf:file)
        XCTAssertThrowsError(try CatalogStore(directory:location))
        XCTAssertEqual(try Data(contentsOf:file),before)
        let recovery = folder.appendingPathComponent("unsupported-restore")
        XCTAssertThrowsError(try CatalogStore.restore(from:file,to:recovery))
        XCTAssertFalse(FileManager.default.fileExists(atPath:recovery.path))
        XCTAssertEqual(try Data(contentsOf:file),before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:location.path).contains { $0.hasPrefix("BeforeMigration-") })
        var config = Configuration(); config.readonly = true
        let verify = try DatabaseQueue(path:file.path,configuration:config)
        XCTAssertEqual(try verify.read { try Data.fetchOne($0,sql:"SELECT recipe FROM photo WHERE id='a'") },original)
        XCTAssertEqual(try verify.read { try Int.fetchOne($0,sql:"PRAGMA user_version") },3)
    }
}

extension FoundationTests {
    @MainActor func testSnapshotDeleteUndoKeepsDraftHistoryPreviewAndFrozenReference() throws {
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("snapshot-model"))
        let baseline = try editFixture(catalog)
        for id in ["a", "b"] { try catalog.saveRecipe(id: id, recipe: baseline) }
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic renderer") })
        model.catalog = catalog; model.activeID = "a"; try model.reload()
        model.recipe = baseline; model.canEdit = true; model.editMode = true
        XCTAssertTrue(model.saveSnapshot(name: "基准"))
        let snapshot = try XCTUnwrap(model.editSnapshots.first)
        model.setBeforeReference(data: snapshot.recipe, photoID: "a", title: snapshot.title)
        XCTAssertEqual(model.beforeReference?.recipe, baseline)
        model.changeRecipe({ $0.exposure = 2 }, commit: false, preview: false)
        model.previewSavedEdit(data: snapshot.recipe, photoID: "a", key: "snapshot:" + snapshot.id, title: snapshot.title)
        XCTAssertNotNil(model.savedEditPreview)
        let photo = try catalog.photo("a"), history = try catalog.editHistory(photoID: "a").map(\.recipe)
        model.undo.removeAllActions(); model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping(); model.deleteSnapshot(snapshot); model.undo.endUndoGrouping()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.editSnapshots.isEmpty)
        XCTAssertNil(model.savedEditPreview)
        XCTAssertEqual(model.recipe?.exposure, 2); XCTAssertTrue(model.dirty)
        XCTAssertEqual(model.beforeReference?.recipe, baseline)
        XCTAssertEqual(try catalog.photo("a"), photo)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").map(\.recipe), history)
        XCTAssertEqual(model.undo.undoActionName, "删除快照")
        model.undo.undo()
        XCTAssertEqual(model.editSnapshots, [snapshot])
        XCTAssertFalse(model.undo.canUndo); XCTAssertTrue(model.undo.canRedo)
        XCTAssertEqual(model.recipe?.exposure, 2); XCTAssertTrue(model.dirty)
        model.undo.redo()
        XCTAssertTrue(model.editSnapshots.isEmpty)
        XCTAssertTrue(model.undo.canUndo); XCTAssertFalse(model.undo.canRedo)
        // Undo may affect the former photo while the current photo keeps its own draft.
        model.activeID = "b"; model.recipe = baseline; try model.reloadEditContext()
        model.changeRecipe({ $0.exposure = -1 }, commit: false, preview: false)
        model.undo.undo()
        XCTAssertEqual(try catalog.snapshots(photoID: "a"), [snapshot])
        XCTAssertTrue(model.editSnapshots.isEmpty)
        model.deleteSnapshot(snapshot) // Cannot directly delete another photo's snapshot.
        XCTAssertEqual(try catalog.snapshots(photoID: "a"), [snapshot])
        model.undo.redo()
        XCTAssertTrue(try catalog.snapshots(photoID: "a").isEmpty)
        XCTAssertEqual(model.recipe?.exposure, -1); XCTAssertTrue(model.dirty)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").map(\.recipe), history)
    }
    @MainActor func testSnapshotUndoIsBoundToCatalogSessionAndSwitchClearsIt() throws {
        let first = try CatalogStore(directory: folder.appendingPathComponent("snapshot-first"))
        let second = try CatalogStore(directory: folder.appendingPathComponent("snapshot-second"))
        let baseline = try editFixture(first)
        _ = try editFixture(second)
        for catalog in [first, second] { try catalog.saveRecipe(id: "a", recipe: baseline) }
        try first.createSnapshot(photoID: "a", title: "相同 ID 不能串库")
        let snapshot = try XCTUnwrap(first.snapshots(photoID: "a").first)
        try second.restoreSnapshot(snapshot)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic renderer") })
        model.catalog = first; model.activeID = "a"; try model.reload()
        model.recipe = baseline; model.canEdit = true
        model.undo.groupsByEvent = false
        model.busy = true; model.deleteSnapshot(snapshot); model.busy = false
        XCTAssertFalse(model.undo.canUndo)
        model.undo.beginUndoGrouping(); model.deleteSnapshot(snapshot); model.undo.endUndoGrouping()
        model.catalog = second // Also protect a stale callback before normal switch cleanup.
        model.undo.undo()
        XCTAssertTrue(try first.snapshots(photoID: "a").isEmpty)
        XCTAssertEqual(try second.snapshots(photoID: "a"), [snapshot])
        model.catalog = first; try first.restoreSnapshot(snapshot); try model.reloadEditContext()
        model.undo.beginUndoGrouping(); model.deleteSnapshot(snapshot); model.undo.endUndoGrouping()
        XCTAssertTrue(model.undo.canUndo)
        try model.activateCatalog(second)
        XCTAssertFalse(model.undo.canUndo); XCTAssertFalse(model.undo.canRedo)
        XCTAssertEqual(try second.snapshots(photoID: "a"), [snapshot])
    }
    @MainActor func testModelHistoryRestoreSnapshotsAndPasteUndo() throws {
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("model-edits"))
        var recipe = try editFixture(catalog)
        try catalog.saveRecipe(id: "a", recipe: recipe)
        recipe.sourceDigest = String(repeating: "b", count: 64)
        try catalog.saveRecipe(id: "b", recipe: recipe)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic renderer") })
        model.catalog = catalog; model.activeID = "a"; try model.reload()
        model.recipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(model.active?.recipe)); model.canEdit = true
        model.changeRecipe { $0.exposure = 1 }
        XCTAssertEqual(model.editHistory.count, 2)
        XCTAssertTrue(model.saveSnapshot(name: "一档"))
        model.copyAdjustments()
        let saved = try XCTUnwrap(model.editSnapshots.first)
        model.changeRecipe { $0.exposure = -2 }
        model.applySavedEdit(data: saved.recipe, photoID: saved.photoID, title: "恢复快照")
        XCTAssertEqual(model.recipe?.exposure, 1)
        XCTAssertEqual(model.editHistory.first?.title, "恢复快照")
        model.undo.removeAllActions()
        model.activeID = "b"; try model.reload()
        model.recipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(model.active?.recipe))
        // Establish savedRecipe through a real commit before exercising undo.
        model.changeRecipe { $0.exposure = 0.5 }
        model.undo.removeAllActions(); model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.pasteAdjustments(options: RecipePasteOptions()))
        model.undo.endUndoGrouping()
        XCTAssertEqual(model.recipe?.exposure, 1)
        XCTAssertEqual(model.recipe?.sourceDigest, String(repeating: "b", count: 64))
        XCTAssertEqual(model.editHistory.first?.title, "粘贴调整")
        model.undo.undo()
        XCTAssertEqual(model.recipe?.exposure, 0.5)
        XCTAssertEqual(model.editHistory.first?.title, "撤销调整")
        model.applySavedEdit(data: saved.recipe, photoID: saved.photoID, title: "不可跨照片恢复")
        XCTAssertEqual(model.recipe?.exposure, 0.5)
    }
}

extension FoundationTests {
    @MainActor func testIndependentCatalogFilesAndSwitchProtection() throws {
        let first = folder.appendingPathComponent("Travel.phoscat")
        let second = folder.appendingPathComponent("Work.phoscat")
        var a: CatalogStore? = try CatalogStore(fileURL: first, create: true)
        let b = try CatalogStore(fileURL: second, create: true)
        try a!.collection(name: "旅行", id: "travel")
        XCTAssertTrue(try b.collections().isEmpty)
        XCTAssertThrowsError(try CatalogStore(fileURL: first))
        XCTAssertThrowsError(try CatalogStore(fileURL: first, create: true))
        a = nil
        a = try CatalogStore(fileURL: first)
        XCTAssertEqual(try a!.collections().first?.name, "旅行")
        let model = AppModel()
        try model.activateCatalog(a!)
        model.selection = ["old"]; model.scope = "collection:travel"; model.search = "old"
        model.copiedPhotoName = "old"; model.maskMode = true
        model.busy = true
        XCTAssertThrowsError(try model.activateCatalog(b))
        XCTAssertTrue(model.catalog === a)
        model.busy = false
        try model.activateCatalog(b)
        XCTAssertTrue(model.catalog === b)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.scope, "all"); XCTAssertEqual(model.search, "")
        XCTAssertFalse(model.maskMode); XCTAssertEqual(model.copiedPhotoName, "")
        XCTAssertTrue(model.collections.isEmpty)
        let missing = folder.appendingPathComponent("missing.phoscat")
        XCTAssertThrowsError(try CatalogStore(fileURL: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let alien = folder.appendingPathComponent("alien.phoscat")
        let queue = try DatabaseQueue(path: alien.path)
        try queue.write { try $0.execute(sql: "CREATE TABLE unrelated (id INTEGER)") }
        try queue.close()
        let bytes = try Data(contentsOf: alien)
        XCTAssertThrowsError(try CatalogStore(fileURL: alien))
        XCTAssertEqual(try Data(contentsOf: alien), bytes)
        XCTAssertTrue(model.catalog === b)
        model.catalog = nil
    }
}


extension FoundationTests {
    @MainActor func testNamedCatalogCreationAndFileRestore() throws {
        let model = AppModel()
        XCTAssertThrowsError(try model.createCatalog(name: "../outside", directory: folder))
        try model.createCatalog(name: "个人摄影", directory: folder)
        let original = try XCTUnwrap(model.catalog)
        XCTAssertEqual(original.fileURL.lastPathComponent, "个人摄影.phoscat")
        try original.collection(name: "精选", id: "favorite")
        XCTAssertThrowsError(try model.createCatalog(name: "个人摄影", directory: folder))
        XCTAssertTrue(model.catalog === original)
        let backup = folder.appendingPathComponent("backup.sqlite")
        try original.backup(to: backup)
        let restored = try CatalogStore.restore(from: backup, toFile: folder.appendingPathComponent("恢复.phoscat"))
        XCTAssertEqual(try restored.collections().first?.id, "favorite")
        XCTAssertThrowsError(try CatalogStore.restore(from: backup, toFile: original.fileURL))
        XCTAssertEqual(try original.collections().count, 1)
        model.catalog = nil
    }
    @MainActor func testCatalogCommandsLiveInSystemMenuBar() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
        let top = menu.items.map(\.title)
        func submenu(_ title: String) throws -> [String] { try titles(XCTUnwrap(menu.items.first { $0.title == title }?.submenu)) }
        XCTAssertTrue(["文件", "编辑", "显示", "窗口"].allSatisfy(top.contains), "\(top)")
        XCTAssertTrue(top.contains("照片"))
        XCTAssertFalse(top.contains("RAW/JPEG"))
        XCTAssertFalse(top.contains("堆叠"))
        XCTAssertFalse(top.contains("工作区"))
        let file = try submenu("文件")
        for item in ["新建目录…", "打开目录…", "打开最近使用的目录", "在 Finder 中显示目录文件", "备份图库…", "从备份恢复…",
                     "迁出 JSON 管理清单…", "输出记录与重试…", "复制导入日志与恢复…"] {
            XCTAssertTrue(file.contains(item), "\(item) missing from \(file)")
        }
        XCTAssertTrue(try submenu("显示").contains("界面主题"))
        XCTAssertTrue(try submenu("显示").contains("观片底"))
        XCTAssertTrue(try submenu("文件").contains("使用预设导出"))
        XCTAssertTrue(try submenu("照片").contains("RAW/JPEG 关联"))
        XCTAssertTrue(try submenu("照片").contains("堆叠"))
        XCTAssertTrue(try submenu("帮助").contains("键盘快捷键…"))
        XCTAssertTrue(titles(try XCTUnwrap(menu.items.first?.submenu)).contains("设置…"))
    }
    @MainActor func testWordmarkAssetsRenderInBothThemes() throws {
        let images = [try XCTUnwrap(Wordmark.image(for: .light)), try XCTUnwrap(Wordmark.image(for: .dark))]
        for image in images {
            XCTAssertTrue(image.isValid)
            XCTAssertEqual(image.size, Wordmark.artworkSize)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
            // The e crossbar stays thicker while remaining separate from its left bowl.
            XCTAssertGreaterThan(alpha(1363, 176), 0.9)
            XCTAssertGreaterThan(alpha(1363, 223), 0.9)
            XCTAssertLessThan(alpha(1363, 173), 0.1)
            XCTAssertLessThan(alpha(1363, 227), 0.1)
            XCTAssertLessThan(alpha(1265, 200), 0.1)
            let lamp = try XCTUnwrap(bitmap.colorAt(x: 600, y: 200)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(lamp.redComponent, lamp.greenComponent)
            XCTAssertGreaterThan(lamp.greenComponent, lamp.blueComponent)
        }
    }
    @MainActor func testFullScreenReaderFollowsOnlyItsOwnWindow() async throws {
        var reported: [Bool] = []
        let probe = FullScreenReader.Probe { reported.append($0) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = probe
        defer { window.contentView = nil }
        func post(_ name: Notification.Name, _ object: NSWindow) async throws {
            NotificationCenter.default.post(name: name, object: object)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await post(NSWindow.willEnterFullScreenNotification, other)
        XCTAssertEqual(reported, [false])
        try await post(NSWindow.willEnterFullScreenNotification, window)
        try await post(NSWindow.willExitFullScreenNotification, other)
        XCTAssertEqual(reported, [false, true])
        try await post(NSWindow.willExitFullScreenNotification, window)
        XCTAssertEqual(reported, [false, true, false])
    }
}
