import XCTest
import GRDB
@testable import Phosdeck

final class LightroomImportTests: XCTestCase {
    private func source(_ fixture: ImportTests) throws -> URL {
        let fm = FileManager.default
        let directory = fixture.source.appendingPathComponent("2026/拍摄")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture.image(directory.appendingPathComponent("A.jpg"))
        try fixture.image(directory.appendingPathComponent("B.jpg"), color: .blue)
        try Data("sidecar".utf8).write(to: directory.appendingPathComponent("A.xmp"))
        let file = fixture.directory.appendingPathComponent("Source.lrcat")
        let database = try DatabaseQueue(path: file.path)
        let sql = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lightroom-catalog.sql")
        try database.write { db in
            try db.execute(sql: String(contentsOf: sql, encoding: .utf8))
            try db.execute(sql: "INSERT INTO AgLibraryRootFolder VALUES (1,?,?,'Photos')", arguments: [fixture.source.path, "source"])
        }
        try database.close()
        try Data("AI settings".utf8).write(to: URL(fileURLWithPath: file.path + "-data"))
        let settings = fixture.directory.appendingPathComponent("Lightroom Settings")
        try fm.createDirectory(at: settings, withIntermediateDirectories: false)
        let preset = """
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure2012="0.5"/>
        </rdf:RDF>
        """
        try Data(preset.utf8).write(to: settings.appendingPathComponent("Preset.xmp"))
        return file.resolvingSymlinksInPath()
    }

    func testReferenceAndCopyKeepVersionsCollectionsEditsAndSourceData() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let source = try source(fixture)
        let digest = try SafeFileWriter.sha256(source)
        let preview = try LightroomCatalog.preview(source)
        XCTAssertEqual(preview.originalCount, 4)
        XCTAssertEqual(preview.versions.count, 5)
        XCTAssertEqual(preview.albums.first?.name, "2026 / Keepers")
        let pipeline = ImagePipeline()
        let locations = [Int64(1): fixture.source!]
        let reference = try await LightroomImporter.run(preview, locations: locations, destination: fixture.target.appendingPathComponent("Referenced"), copying: false, pipeline: pipeline)
        XCTAssertEqual(reference.imported, 4)
        XCTAssertEqual(reference.converted, 2)
        XCTAssertTrue(reference.warnings.contains { $0.contains("CameraProfile") })
        let referenced = try CatalogStore(fileURL: reference.catalog)
        let importedPresets = try await referenced.database.read { try String.fetchAll($0, sql: "SELECT name FROM adjustmentPreset") }
        XCTAssertEqual(importedPresets, ["Preset"])
        XCTAssertEqual(try referenced.roots().first?.path, fixture.source.resolvingSymlinksInPath().path)
        let photos = try referenced.photos()
        let original = try XCTUnwrap(photos.first { $0.name == "A.jpg" && !$0.isVirtualCopy })
        let copy = try XCTUnwrap(photos.first { $0.isVirtualCopy })
        XCTAssertEqual(copy.sourceKey, original.id)
        XCTAssertEqual(original.rating, 5); XCTAssertEqual(original.flag, 1); XCTAssertEqual(original.colorLabel, 3)
        XCTAssertEqual(original.caption, "Mountains")
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(original.recipe))
        XCTAssertEqual(recipe.exposure, 0.75); XCTAssertEqual(recipe.crop.width, 0.5)
        XCTAssertEqual(recipe.crop.y, 0.3, accuracy: 1e-12)
        let mono = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(copy.recipe))
        XCTAssertTrue(mono.develop.blackAndWhite); XCTAssertEqual(mono.exposure, -0.5); XCTAssertEqual(mono.quarterTurns, 1)
        XCTAssertEqual(try referenced.editHistory(photoID: original.id).count, 1)
        let album = try XCTUnwrap(referenced.collections().first)
        let missing = try XCTUnwrap(photos.first { $0.name == "Missing.jpg" })
        XCTAssertEqual(missing.availability, "missing")
        XCTAssertEqual(try referenced.collectionContents(album.id).members, [copy.id, original.id, missing.id])
        let keywords = try await referenced.database.read { try String.fetchAll($0, sql: "SELECT name FROM photoKeyword") }
        XCTAssertEqual(keywords, ["旅行 | 云南"])

        let copied = try await LightroomImporter.run(preview, locations: locations, destination: fixture.target.appendingPathComponent("Copied"), copying: true, pipeline: pipeline)
        XCTAssertEqual(copied.imported, 3); XCTAssertEqual(copied.converted, 2)
        let project = copied.catalog.deletingLastPathComponent()
        let preserved = project.appendingPathComponent("Lightroom")
        XCTAssertEqual(try SafeFileWriter.sha256(preserved.appendingPathComponent("Source.lrcat")), digest)
        XCTAssertEqual(try SafeFileWriter.sha256(source), digest)
        XCTAssertEqual(try String(contentsOf: preserved.appendingPathComponent("Source.lrcat-data"), encoding: .utf8), "AI settings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.appendingPathComponent("Lightroom Settings/Preset.xmp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.appendingPathComponent("Files/source/2026/拍摄/A.xmp").path))
        try FileManager.default.moveItem(at: fixture.source, to: fixture.directory.appendingPathComponent("Offline"))
        let reopened = try CatalogStore(fileURL: copied.catalog)
        let photo = try XCTUnwrap(reopened.photos().first { $0.name == "A.jpg" && !$0.isVirtualCopy })
        let root = try XCTUnwrap(reopened.roots().first)
        let rendered = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: recipe), longEdge: 100)
        XCTAssertEqual(rendered.image.width, 10)
    }

    func testCatalogChangesAndInvalidSettingsAreRejectedWithoutWritingSource() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let file = try source(fixture)
        let lock = URL(fileURLWithPath: file.path + ".lock")
        try Data().write(to: lock)
        XCTAssertThrowsError(try LightroomCatalog.preview(file))
        try FileManager.default.removeItem(at: lock)
        let preview = try LightroomCatalog.preview(file)
        let fileHandle = try FileHandle(forWritingTo: file)
        try fileHandle.seekToEnd(); try fileHandle.write(contentsOf: Data([0])); try fileHandle.close()
        let target = fixture.target.appendingPathComponent("Stale")
        do {
            _ = try await LightroomImporter.run(preview, locations: [1: fixture.source], destination: target, copying: false, pipeline: ImagePipeline())
            XCTFail("Stale source was imported")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
        XCTAssertThrowsError(try LightroomSettings.properties("return { Exposure2012 = 1 } call()"))
        let deferred = try LightroomSettings.properties("s={ Exposure2012 = -999999, ToneCurvePV2012={0,0,128,100,255,255}, Local={ Nested = { x = 1 } } }")
        XCTAssertNil(deferred["Exposure2012"])
        XCTAssertEqual(deferred["ToneCurvePV2012"], ["0, 0", "128, 100", "255, 255"])
        XCTAssertEqual(deferred["Local"], [])
    }
}
