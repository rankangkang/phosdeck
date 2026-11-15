import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import GRDB
@testable import Phosdeck

final class LightroomImportTests: XCTestCase {
    private func source(_ fixture: ImportTests, wal: Bool = false) throws -> URL {
        let fm = FileManager.default
        let directory = fixture.source.appendingPathComponent("2026/拍摄")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixture.image(directory.appendingPathComponent("A.jpg"))
        try fixture.image(directory.appendingPathComponent("B.jpg"), color: .blue)
        try Data("sidecar".utf8).write(to: directory.appendingPathComponent("A.xmp"))
        let file = fixture.directory.appendingPathComponent("Source.lrcat")
        var configuration = Configuration()
        if wal { configuration.journalMode = .wal }
        let database = try DatabaseQueue(path: file.path, configuration: configuration)
        let sql = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/lightroom-catalog.sql")
        try database.write { db in
            try db.execute(sql: String(contentsOf: sql, encoding: .utf8))
            try db.execute(sql: "INSERT INTO AgLibraryRootFolder VALUES (1,?,?,'Photos')", arguments: [fixture.source.path, "source"])
        }
        if wal { try database.writeWithoutTransaction { _ = try $0.checkpoint(.truncate) } }
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

    func testReadsClosedWALCatalogInReadOnlyDirectory() throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let fm = FileManager.default
        let sourceFile = try source(fixture, wal: true)
        let parent = fixture.directory.appendingPathComponent("Closed")
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        let file = parent.appendingPathComponent("Catalog #%.lrcat")
        try fm.copyItem(at: sourceFile, to: file)
        let digest = try SafeFileWriter.sha256(file)
        let sidecars = ["-wal", "-shm"].map { file.path + $0 }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

        let preview = try LightroomCatalog.preview(file)

        XCTAssertEqual(preview.versions.count, 5)
        XCTAssertEqual(try SafeFileWriter.sha256(file), digest)
        XCTAssertTrue(sidecars.allSatisfy { !fm.fileExists(atPath: $0) })
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

    func testMultipageTIFFPreviewsFirstPageAndVerifiesUnidentifiedReferenceInPlace() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let file = try source(fixture)
        let database = try DatabaseQueue(path: file.path)
        try await database.write { db in
            try db.execute(sql: "UPDATE AgLibraryFile SET idx_filename = 'Layered.tiff' WHERE id_local = 1")
        }
        try database.close()
        let preview = try LightroomCatalog.preview(file)
        let pipeline = ImagePipeline()
        let missingImport = try await LightroomImporter.run(preview, locations: [1: fixture.source],
            destination: fixture.target.appendingPathComponent("Unverified"), copying: false, pipeline: pipeline)
        let catalog = try CatalogStore(fileURL: missingImport.catalog)
        let missing = try XCTUnwrap(try catalog.photos().first { $0.name == "Layered.tiff" && !$0.isVirtualCopy })
        let root = try XCTUnwrap(try catalog.roots().first)
        let album = try XCTUnwrap(try catalog.collections().first)
        let members = try catalog.collectionContents(album.id).members
        let source = try XCTUnwrap(try catalog.source(missing.sourceKey))
        XCTAssertEqual(missing.availability, "missing")

        let url = URL(fileURLWithPath: root.path).appendingPathComponent(missing.relativePath)
        let context = CIContext()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 24))
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 20))
        for page in [red, green] {
            let image = try XCTUnwrap(context.createCGImage(page, from: page.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let digest = try SafeFileWriter.sha256(url)

        let sibling = url.deletingLastPathComponent().appendingPathComponent("Other.tiff")
        try FileManager.default.copyItem(at: url, to: sibling)
        let relocator = RootRelocator()
        do {
            _ = try await relocator.prepare(source, file: sibling, catalog: catalog)
            XCTFail("The unidentified reference accepted a different path")
        } catch {
            XCTAssertEqual(try catalog.source(source.id), source)
        }
        let proposal = try await relocator.prepare(source, file: url, catalog: catalog)
        try await relocator.commit(proposal, catalog: catalog)
        let restored = try XCTUnwrap(try catalog.photos().first { $0.id == missing.id })
        let versions = try catalog.photos().filter { $0.sourceKey == source.id }
        XCTAssertEqual(versions.count, 2)
        for version in versions {
            XCTAssertEqual(version.relativePath, missing.relativePath)
            XCTAssertEqual(version.availability, "available")
            XCTAssertEqual(version.revision, missing.revision + 1)
            XCTAssertEqual(version.details?.tiffPageCount, 2)
            XCTAssertEqual(version.width, 40)
            XCTAssertEqual(version.height, 24)
            XCTAssertFalse(version.supportsEditing)
            XCTAssertNil(version.recipe)
        }
        XCTAssertEqual(restored.rating, missing.rating)
        XCTAssertEqual(restored.captureDate, missing.captureDate)
        XCTAssertEqual(try catalog.collectionContents(album.id).members, members)

        let freshImport = try await LightroomImporter.run(preview, locations: [1: fixture.source],
            destination: fixture.target.appendingPathComponent("Referenced TIFF"), copying: false, pipeline: pipeline)
        let freshCatalog = try CatalogStore(fileURL: freshImport.catalog)
        let fresh = try XCTUnwrap(try freshCatalog.photos().first { $0.name == "Layered.tiff" && !$0.isVirtualCopy })
        XCTAssertEqual(fresh.availability, "available")
        XCTAssertEqual(fresh.details, restored.details)
        XCTAssertNil(fresh.recipe)
        let label = try XCTUnwrap(fresh.tiffPreviewLabel)
        XCTAssertTrue(freshImport.warnings.contains { $0.contains("Layered.tiff") && $0.hasSuffix(label) })

        func pixel(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: bytes.count,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
            return bytes
        }
        let request = ImageRequest(photo: restored, root: root, recipe: nil)
        let rendered = try await pipeline.render(request, longEdge: nil)
        XCTAssertEqual(rendered.fullSize, CGSize(width: 40, height: 24))
        XCTAssertEqual(pixel(rendered.image), [255, 0, 0, 255])
        let thumbnail = try await ThumbnailService().image(photo: restored, root: root, edge: 20)
        XCTAssertEqual(thumbnail.width, 20)
        XCTAssertEqual(thumbnail.height, 12)
        XCTAssertEqual(pixel(thumbnail), [255, 0, 0, 255])

        let output = fixture.target.appendingPathComponent("Output.tif")
        let options = ExportOptions(format: .tiff)
        let names = try ExportNamingPlanner.preview(photos: [restored], options: options)
        XCTAssertEqual(names.first?.errors, [PhotoFileType.multipageTIFFPreviewOnly])
        do {
            _ = try await pipeline.export(request, staging: output, options: options)
            XCTFail("Export silently flattened a multi-page TIFF")
        } catch {
            XCTAssertEqual(error.localizedDescription, PhotoFileType.multipageTIFFPreviewOnly)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertEqual(try SafeFileWriter.sha256(url), digest)
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(original), 2)
        let secondPage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(original, 1, nil))
        XCTAssertEqual(secondPage.width, 16)
        XCTAssertEqual(secondPage.height, 20)
        XCTAssertEqual(pixel(secondPage), [0, 255, 0, 255])
    }

    func testStraightenedCropKeepsSourceScaleWithRotatedMirroredOrientation() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let file = try source(fixture)
        let database = try DatabaseQueue(path: file.path)
        // These corners describe the 20 × 10 source rectangle whose rotated
        // edges are x = 4.3…14.7 and y = 2.3…7.4 in top-left pixels.
        let settings = """
        s = { Exposure2012 = 0.25, CropAngle = 22.5, CropLeft = 0.2883565966035704,
              CropTop = 0.032422969773851396, CropRight = 0.6711896782563416,
              CropBottom = 0.9015923010143011 }
        """
        try await database.write { db in
            try db.execute(sql: "UPDATE Adobe_images SET orientation = 'AD' WHERE id_local = 1")
            try db.execute(sql: "UPDATE Adobe_imageDevelopSettings SET text = ? WHERE image = 1", arguments: [settings])
        }
        try database.close()
        let sourceCatalog = try LightroomCatalog.preview(file)
        let pipeline = ImagePipeline()
        let imported = try await LightroomImporter.run(sourceCatalog, locations: [1: fixture.source],
            destination: fixture.target.appendingPathComponent("Straightened"), copying: false, pipeline: pipeline)
        let catalog = try CatalogStore(fileURL: imported.catalog)
        let photo = try XCTUnwrap(try catalog.photos().first { $0.name == "A.jpg" && !$0.isVirtualCopy })
        let root = try XCTUnwrap(try catalog.roots().first)
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(photo.recipe))
        XCTAssertEqual(recipe.exposure, 0.25)
        XCTAssertEqual(recipe.straightenDegrees, 22.5)
        XCTAssertEqual(recipe.quarterTurns, 1)
        XCTAssertTrue(recipe.flipHorizontal)
        XCTAssertFalse(recipe.straightenAutoZoom)
        XCTAssertTrue(recipe.alignedBaseline().hasSameGeometry(as: recipe))
        XCTAssertTrue(recipe.baseline().straightenAutoZoom)
        XCTAssertFalse(imported.warnings.contains { $0.contains("CropAngle / Crop") })

        let geometry = try PhotoGeometry(size: CGSize(width: 20, height: 10), recipe: recipe)
        XCTAssertEqual(geometry.cropRect, CGRect(x: 2, y: 5, width: 6, height: 11))
        let corner = try XCTUnwrap(geometry.transform.point(CGPoint(x: 5.767131932071408, y: 9.675770302261486)))
        XCTAssertEqual(corner.x, 0.3, accuracy: 1e-8)
        XCTAssertEqual(corner.y, 10.7, accuracy: 1e-8)
        let image = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: recipe), longEdge: nil)
        XCTAssertEqual(image.image.width, 6)
        XCTAssertEqual(image.image.height, 11)
    }

    func testCameraLensSwitchAppliesOnlyToUnscaledCameraSettings() {
        let standard = ["LensProfileName": ["Camera Settings"], "LensProfileSetup": ["LensDefaults"],
                        "LensProfileDistortionScale": ["100"], "LensProfileEnable": ["0"]]
        XCTAssertEqual(LightroomSettings.cameraLensCorrection(in: standard), false)
        var edits = standard
        edits["LensProfileEnable"] = ["1"]
        XCTAssertEqual(LightroomSettings.cameraLensCorrection(in: edits), true)
        edits["LensProfileDistortionScale"] = ["75"]
        XCTAssertNil(LightroomSettings.cameraLensCorrection(in: edits))
        edits = standard
        edits["LensProfileName"] = ["Custom correction"]
        XCTAssertNil(LightroomSettings.cameraLensCorrection(in: edits))
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
