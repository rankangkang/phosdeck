import XCTest
import CoreImage
import GRDB
@testable import Phosdeck

final class VirtualCopyTests: XCTestCase {
    func testSourceIdentityIndependentHistoryMetadataAndDeletion() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url:f.source,bookmark:AccessLease.bookmark(f.source,readOnly:true))
        let file = f.source.appendingPathComponent("one.jpg"); try f.image(file)
        let initial = try ReferenceImporter.inspect(url:file,root:root,rootURL:f.source)
        try f.catalog.index(initial)
        let pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(ImageRequest(photo:initial,root:root,recipe:nil))
        recipe.exposure = 0.75
        try f.catalog.saveRecipe(id:initial.id,recipe:recipe)
        try f.catalog.setOrganization(ids:[initial.id],rating:4,flag:1)
        _ = try f.catalog.changeKeyword("Travel",ids:[initial.id],adding:true)
        try f.catalog.collection(name:"Keep",id:"c"); try f.catalog.membership(ids:[initial.id],collection:"c",add:true)
        try f.catalog.createSnapshot(photoID:initial.id,title:"Original snapshot")
        let asset = f.source.appendingPathComponent("one.xmp"); try Data("retained".utf8).write(to:asset)
        try await f.catalog.database.write { try $0.execute(sql:"INSERT INTO attachment VALUES (?,?,?)",arguments:[initial.id,"one.xmp","asset-hash"]) }
        let copy = try XCTUnwrap(f.catalog.createVirtualCopies(ids:[initial.id]).first)
        let next = try XCTUnwrap(f.catalog.createVirtualCopies(ids:[copy.id]).first)
        XCTAssertEqual(copy.sourceKey,next.sourceKey); XCTAssertEqual(copy.sourceKey,initial.id)
        XCTAssertEqual(copy.recipe,try f.catalog.photo(initial.id)?.recipe)
        XCTAssertEqual(copy.rating,4); XCTAssertEqual(copy.flag,1)
        XCTAssertTrue(try f.catalog.members("c").contains(copy.id))
        XCTAssertEqual(try f.catalog.editHistory(photoID:copy.id).count,1)
        XCTAssertTrue(try f.catalog.snapshots(photoID:copy.id).isEmpty)
        recipe.exposure = -1; try f.catalog.saveRecipe(id:copy.id,recipe:recipe)
        _ = try f.catalog.changeKeyword("Travel",ids:[copy.id],adding:false)
        XCTAssertEqual(try f.catalog.keywordSummary(selected:[initial.id]).first?.selected,1)
        XCTAssertEqual(try f.catalog.editHistory(photoID:next.id).count,1)
        XCTAssertNotEqual(try f.catalog.photo(initial.id)?.recipe,try f.catalog.photo(copy.id)?.recipe)
        _ = try f.catalog.renameVersion(id:copy.id,name:"黑白方案")
        let inverse = try f.catalog.setVersionDeletion([initial.id:true])
        XCTAssertNil(try f.catalog.photo(initial.id)); XCTAssertEqual(try f.catalog.versions(sourceID:initial.id).count,2)
        XCTAssertTrue(FileManager.default.fileExists(atPath:asset.path)); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        // Reimport/hard-link identity must not allocate a fresh physical source.
        try f.catalog.index(initial)
        XCTAssertEqual(try f.catalog.photoCount(),2)
        let backup = f.target.appendingPathComponent("backup.sqlite"); try f.catalog.backup(to:backup)
        let restored = try CatalogStore.restore(from:backup,to:f.target.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.photo(copy.id)?.copyName,"黑白方案")
        XCTAssertEqual(try restored.photo(next.id)?.sourceKey,initial.id)
        let moved = f.target.appendingPathComponent("moved"); try FileManager.default.copyItem(at:f.source,to:moved)
        let relocation = try await RootRelocator().relocate(root,to:moved,catalog:restored)
        XCTAssertTrue(relocation.isEmpty)
        let updated = try XCTUnwrap(restored.photo(copy.id)), movedRoot = try XCTUnwrap(restored.roots().first)
        let output = try await pipeline.render(ImageRequest(photo:updated,root:movedRoot,recipe:JSONDecoder().decode(EditRecipe.self,from:try XCTUnwrap(updated.recipe))),longEdge:80)
        XCTAssertGreaterThan(output.image.width,0)
        _ = try f.catalog.setVersionDeletion(inverse); XCTAssertNotNil(try f.catalog.photo(initial.id))
        try await f.catalog.database.write { db in
            try db.execute(sql:"UPDATE photo SET camera='shared' WHERE id=?",arguments:[copy.id])
        }
        XCTAssertEqual(try f.catalog.photo(next.id)?.camera,"shared")
    }
    @MainActor func testBatchUndoRedoNamingAndFrozenExport() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url:f.source,bookmark:AccessLease.bookmark(f.source,readOnly:true))
        for name in ["a.jpg","b.jpg"] { let file = f.source.appendingPathComponent(name); try f.image(file); try f.catalog.index(ReferenceImporter.inspect(url:file,root:root,rootURL:f.source)) }
        let model = AppModel(); model.catalog = f.catalog; try model.reload()
        let originals = Set(model.photos.map(\.id)); model.selection = originals
        model.createVirtualCopies()
        let copies = try f.catalog.photos().filter(\.isVirtualCopy)
        XCTAssertEqual(copies.count,2); model.undo.undo(); XCTAssertEqual(try f.catalog.photoCount(),2)
        model.undo.redo(); XCTAssertEqual(try f.catalog.photoCount(),4)
        let c = try XCTUnwrap(copies.first)
        model.renameVirtualCopy(id:c.id,name:"Proof"); model.undo.undo()
        XCTAssertEqual(try f.catalog.photo(c.id)?.copyName,c.copyName); model.undo.redo()
        let all = try f.catalog.photos(), names = try ExportNamingPlanner.preview(photos:all,options:ExportOptions())
        XCTAssertTrue(names.allSatisfy { $0.errors.isEmpty }); XCTAssertEqual(Set(names.map(\.filename)).count,4)
        _ = try f.catalog.renameVersion(id:copies[1].id,name:"Proof")
        var collision = try XCTUnwrap(f.catalog.photo(c.id)); collision.id = "collision"; collision.copyName = "Proof"
        let conflicts = try ExportNamingPlanner.preview(photos:[try XCTUnwrap(f.catalog.photo(c.id)),collision],options:ExportOptions())
        XCTAssertTrue(conflicts.allSatisfy { !$0.errors.isEmpty })
        let current = try XCTUnwrap(f.catalog.photo(c.id)); model.selection = [c.id]
        let preview = try ExportNamingPlanner.preview(photos:[current],options:ExportOptions(format:.png))
        let frozen = try XCTUnwrap(model.prepareExport(options:ExportOptions(format:.png),photos:[current],names:preview,directory:f.target).first)
        _ = try f.catalog.renameVersion(id:c.id,name:"Later")
        _ = try f.catalog.setVersionDeletion([c.id:true])
        let reports = await ExportService(pipeline:ImagePipeline()).run([frozen],catalog:f.catalog,progress:{ _ in })
        XCTAssertTrue(reports.allSatisfy { $0.hasPrefix("成功：") },"\(reports)"); XCTAssertEqual(frozen.request.photo.copyName,"Proof")
        XCTAssertTrue(FileManager.default.fileExists(atPath:frozen.destination.path))
        XCTAssertThrowsError(try f.catalog.renameVersion(id:copies[1].id,name:"\n"))
    }
    func testStrictCatalogVersionRefusalPreservesBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        var catalog: CatalogStore? = try CatalogStore(directory:folder)
        let file = try XCTUnwrap(catalog?.fileURL)
        try catalog?.database.write { try $0.execute(sql:"PRAGMA user_version=6") }
        catalog = nil
        let before = try Data(contentsOf:file)
        XCTAssertThrowsError(try CatalogStore(fileURL:file))
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
}
