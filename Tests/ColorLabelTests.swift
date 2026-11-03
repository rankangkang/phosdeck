import XCTest
import AppKit
import GRDB
@testable import Phosdeck

final class ColorLabelTests: XCTestCase {
    private func fixture() throws -> (URL, CatalogStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("color-label-" + UUID().uuidString)
        let catalog = try CatalogStore(directory: folder), root = try catalog.addRoot(url: folder, bookmark: Data())
        try catalog.database.write { db in
            for n in 0..<6 {
                try Photo(id: String(n), rootID: root.id, relativePath: "photo-\(n).jpg", identity: Data(), identityKey: "color-\(n)",
                          colorLabel: n, width: 1, height: 1).insert(db)
            }
        }
        return (folder, catalog)
    }
    func testLabelsPersistPerVersionAndBackupManifestIncludeThem() throws {
        let (folder, catalog) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let copy = try XCTUnwrap(catalog.createVirtualCopies(ids: ["1"]).first)
        XCTAssertEqual(copy.colorLabel, 1)
        try catalog.setOrganization(ids: [copy.id], colorLabel: 5)
        XCTAssertEqual(try catalog.photo("1")?.colorLabel, 1)
        XCTAssertEqual(try catalog.photo(copy.id)?.colorLabel, 5)
        XCTAssertEqual(try catalog.versions(sourceID: "1").count, 2)
        let backup = folder.appendingPathComponent("backup.sqlite")
        try catalog.backup(to: backup)
        let restored = try CatalogStore.restore(from: backup, to: folder.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.photo(copy.id)?.colorLabel, 5)
        let manifest = folder.appendingPathComponent("manifest.json"); try restored.exportManifest(to: manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let rows = try XCTUnwrap(object["photos"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["id"] as? String == copy.id }?["colorLabel"] as? Int, 5)
        XCTAssertNotNil(object["localParameterPresets"])
        XCTAssertThrowsError(try catalog.setOrganization(ids: [copy.id], colorLabel: 6))
    }
    func testColorFilterSmartSaveAndHeldResultsHaveIdenticalMembership() throws {
        let (folder, catalog) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        var query = PhotoQuery(colorLabels: [0, 2, 5])
        XCTAssertEqual(Set(try catalog.allResultIDs(query)), ["0", "2", "5"])
        let rules = try SmartRules.from(query)
        var smart = PhotoQuery(); smart.smart = rules
        XCTAssertEqual(try catalog.allResultIDs(query), try catalog.allResultIDs(smart))
        let held = try catalog.holdResults(query, replacing: nil)
        query.snapshotID = held
        try catalog.setOrganization(ids: ["0"], colorLabel: 1)
        XCTAssertTrue(try catalog.allResultIDs(query).contains("0"), "Held results freeze membership, not the color state")
        XCTAssertFalse(try catalog.allResultIDs(smart).contains("0"))
        XCTAssertNotEqual(PhotoQuery(colorLabels: [1]).orderingQuerySignature, PhotoQuery(colorLabels: [2]).orderingQuerySignature)
        XCTAssertThrowsError(try SmartRule(field: .colorLabel, op: .oneOf, value: "1,1").validate())
        XCTAssertThrowsError(try SmartRule(field: .colorLabel, op: .equal, value: "9").validate())
        XCTAssertEqual(try catalog.allResultIDs(PhotoQuery()).count, 6)
    }
    @MainActor func testBatchToggleUndoRedoAndMixedSelection() throws {
        let (folder, catalog) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.undo.groupsByEvent = false; try model.reload()
        model.choose(["1", "2"], active: "1")
        XCTAssertNil(model.selectedColorLabel)
        model.undo.beginUndoGrouping(); model.toggleColorLabel(4); model.undo.endUndoGrouping()
        XCTAssertEqual(try catalog.photo("1")?.colorLabel, 4)
        XCTAssertEqual(try catalog.photo("2")?.colorLabel, 4)
        model.undo.undo()
        XCTAssertEqual(try catalog.photo("1")?.colorLabel, 1)
        XCTAssertEqual(try catalog.photo("2")?.colorLabel, 2)
        model.undo.redo()
        XCTAssertEqual(try catalog.photo("1")?.colorLabel, 4)
        model.undo.beginUndoGrouping(); model.toggleColorLabel(4); model.undo.endUndoGrouping()
        XCTAssertEqual(try catalog.photo("1")?.colorLabel, 0)
        XCTAssertEqual(try catalog.photo("2")?.colorLabel, 0)
    }
    @MainActor func testNumericKeysShiftRepeatAndTextEditingGuard() throws {
        let (folder, catalog) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.undo.groupsByEvent = false; model.photoSort = .filename
        try model.reload(); model.choose(["0"], active: "0"); model.singleView = true
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"; defer { window.contentView = nil }
        func event(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code))
        }
        model.undo.beginUndoGrouping()
        XCTAssertNil(WorkspaceKeyboard.handle(try event("6", code: 22), model: model))
        model.undo.endUndoGrouping()
        XCTAssertEqual(try catalog.photo("0")?.colorLabel, 1)
        XCTAssertNil(WorkspaceKeyboard.handle(try event("6", code: 22, repeatKey: true), model: model))
        XCTAssertEqual(try catalog.photo("0")?.colorLabel, 1, "Key repeat must not clear a toggled label")
        model.undo.beginUndoGrouping()
        XCTAssertNil(WorkspaceKeyboard.handle(try event("&", code: 26, flags: .shift), model: model))
        model.undo.endUndoGrouping()
        XCTAssertEqual(try catalog.photo("0")?.colorLabel, 2)
        XCTAssertEqual(model.activeID, "1")
        let text = NSTextView(); window.contentView = text; window.makeFirstResponder(text)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try event("8", code: 28), model: model))
        XCTAssertEqual(try catalog.photo("1")?.colorLabel, 1)
    }
    @MainActor func testFilterRestoreAcrossImportAndCatalogSwitchClearsClipboard() throws {
        let (folder, catalog) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.colorLabelFilter = [1, 2]; try model.reload()
        let query = model.query
        try model.completeImport(ids: ["0"], cancelled: false)
        model.showLastImport(startCulling: true); model.returnFromImport()
        XCTAssertEqual(model.query, query)
        model.copiedLocalParameters = LocalParameterValues(group: LocalAdjustment(components: [MaskComponent(tool: .linear)]))
        try model.activateCatalog(CatalogStore(directory: folder.appendingPathComponent("next")))
        XCTAssertNil(model.copiedLocalParameters)
        XCTAssertTrue(model.colorLabelFilter.isEmpty)
    }
    func testOlderSchemaIsRejectedWithoutMutatingIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("strict-schema-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Catalog.sqlite")
        do {
            let catalog = try CatalogStore(directory: folder)
            try catalog.database.write { try $0.execute(sql: "PRAGMA user_version=11; UPDATE catalogMeta SET schemaVersion=11") }
        } // Release the actual writer lock before testing schema validation.
        let before = try SafeFileWriter.sha256(file)
        XCTAssertThrowsError(try CatalogStore(fileURL: file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("版本不受支持"))
            XCTAssertFalse(error.localizedDescription.contains("另一个实例"), "A writer lock must not mask the schema rejection")
        }
        XCTAssertEqual(try SafeFileWriter.sha256(file), before)
        var config = Configuration(); config.readonly = true
        let queue = try DatabaseQueue(path: file.path, configuration: config)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }, 11)
        try queue.close()
    }
}
