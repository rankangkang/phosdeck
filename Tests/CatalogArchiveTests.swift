import XCTest
import GRDB
@testable import Phosdeck

final class CatalogArchiveTests: XCTestCase {
    func testArchiveAcrossAuthorizedDisposableVolumes() async throws {
        let fm = FileManager.default
        let target = fm.temporaryDirectory.appendingPathComponent("PhosdeckArchiveTestTarget", isDirectory: true)
        let source = fm.temporaryDirectory.appendingPathComponent("PhosdeckArchiveTestSource", isDirectory: true)
        guard let sourceDevice = try? ProjectCopy.directoryIdentity(source).device,
              let targetDevice = try? ProjectCopy.directoryIdentity(target).device, sourceDevice != targetDevice,
              sourceDevice != (try? ProjectCopy.directoryIdentity(fm.temporaryDirectory).device),
              targetDevice != (try? ProjectCopy.directoryIdentity(fm.temporaryDirectory).device),
              let capacity = try? source.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity, capacity < 256 * 1_024 * 1_024,
              let targetCapacity = try? target.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity, targetCapacity < 256 * 1_024 * 1_024 else {
            throw XCTSkip("Two named disposable test volumes are required")
        }
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let run = UUID().uuidString
        let sourceRoot = source.appendingPathComponent(run, isDirectory: true)
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        let destination = target.appendingPathComponent(run, isDirectory: true)
        defer { try? fm.removeItem(at: sourceRoot); try? fm.removeItem(at: destination) }
        let image = sourceRoot.appendingPathComponent("A.jpg")
        try fixture.image(image)
        let original = try XCTUnwrap(fixture.catalog)
        let root = try original.addRoot(url: sourceRoot, bookmark: AccessLease.bookmark(sourceRoot, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: image.resolvingSymlinksInPath(), root: root, rootURL: URL(fileURLWithPath: root.path))
        try original.index(photo)
        let pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        recipe.exposure = 0.25
        try original.saveRecipe(id: photo.id, recipe: recipe)
        let exported = try await CatalogArchive.create(catalog: original, destination: destination, extras: [])
        let hidden = sourceRoot.appendingPathComponent("Disconnected.jpg")
        try fm.moveItem(at: image, to: hidden)
        XCTAssertFalse(fm.fileExists(atPath: image.path))
        try await verifyCopy(exported, photoID: photo.id, recipe: recipe, original: original, targetDevice: targetDevice, pipeline: pipeline)
    }

    private func verifyCopy(_ file: URL, photoID: String, recipe: EditRecipe, original: CatalogStore, targetDevice: Int32,
                            pipeline: ImagePipeline) async throws {
        let archived = try CatalogStore(fileURL: file)
        let copied = try XCTUnwrap(archived.photo(photoID))
        let copiedRoot = try XCTUnwrap(archived.roots().first)
        XCTAssertEqual(try JSONDecoder().decode(FileIdentity.self, from: copied.identity).device, targetDevice)
        let rendered = try await pipeline.render(ImageRequest(photo: copied, root: copiedRoot, recipe: recipe), longEdge: 40)
        XCTAssertEqual(rendered.image.width, 20)
        var edited = recipe
        edited.exposure = 0.5
        try archived.saveRecipe(id: photoID, recipe: edited)
        XCTAssertNotEqual(try archived.photo(photoID)?.recipe, try original.photo(photoID)?.recipe)
    }

    func testIndependentProjectReopensWithEditsAfterCopyToAnotherLocation() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let fm = FileManager.default
        let shoot = fixture.source.appendingPathComponent("2026/拍摄")
        try fm.createDirectory(at: shoot.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let image = shoot.appendingPathComponent("A.jpg")
        let sidecar = shoot.appendingPathComponent("A.xmp")
        try fixture.image(image)
        try Data("sidecar".utf8).write(to: sidecar)
        let extra = fixture.directory.appendingPathComponent("Delivery")
        try fm.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: extra.appendingPathComponent("Notes.txt"))
        let original = try XCTUnwrap(fixture.catalog)
        let root = try original.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: image.resolvingSymlinksInPath(), root: root, rootURL: URL(fileURLWithPath: root.path))
        try original.index(photo)
        try await original.database.write { db in
            try db.execute(sql: "INSERT INTO attachment VALUES (?,?,?)", arguments: [photo.id, "2026/拍摄/A.xmp", try SafeFileWriter.sha256(sidecar)])
        }
        let pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        recipe.exposure = 0.75
        try original.saveRecipe(id: photo.id, recipe: recipe)
        let oldOutput = fixture.target.appendingPathComponent("Original Delivery.jpg")
        let outputBookmark = try AccessLease.bookmark(fixture.target, readOnly: false)
        let oldJob = ExportSnapshot(id: "original-delivery", request: ImageRequest(photo: photo, root: root, recipe: recipe),
                                    destination: oldOutput, targetBookmark: outputBookmark, options: ExportOptions())
        try await original.database.write { db in
            try db.execute(sql: "INSERT INTO exportItem(id,snapshot,state,destination) VALUES (?,?,'failed',?)",
                           arguments: [oldJob.id, try JSONEncoder().encode(oldJob), oldOutput.path])
        }
        try original.setRatings([photo.id: 5])
        let copies = try original.createVirtualCopies(ids: [photo.id])
        let copy = try XCTUnwrap(copies.first)
        _ = try original.changeStacks(.group(top: photo.id, members: [copy.id]))
        try original.collection(name: "Keepers", id: "album")
        try original.membership(ids: [copy.id, photo.id], collection: "album", add: true)
        _ = try original.createSnapshot(photoID: photo.id, title: "Before delivery")

        let output = fixture.target.appendingPathComponent("Archive")
        let exported = try await CatalogArchive.create(catalog: original, destination: output, extras: [extra])
        XCTAssertEqual(exported.lastPathComponent, "Archive.phoscat")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Files/source/2026/拍摄/Empty").path))
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("Files/Delivery/Notes.txt"), encoding: .utf8), "notes")
        XCTAssertEqual(try SafeFileWriter.sha256(output.appendingPathComponent("Files/source/2026/拍摄/A.xmp")), try SafeFileWriter.sha256(sidecar))
        XCTAssertEqual(try original.roots().first?.path, root.path)

        let relocated = fixture.target.appendingPathComponent("Relocated")
        try fm.copyItem(at: output, to: relocated)
        try fm.removeItem(at: output)
        try fm.moveItem(at: fixture.source, to: fixture.directory.appendingPathComponent("Disconnected"))
        let reopened = try CatalogStore(fileURL: relocated.appendingPathComponent(exported.lastPathComponent))
        let reopenedPhoto = try XCTUnwrap(reopened.photo(photo.id))
        let reopenedRoot = try XCTUnwrap(reopened.roots().first)
        XCTAssertEqual(reopenedPhoto.rating, 5)
        XCTAssertEqual(try reopened.stacks(), try original.stacks())
        XCTAssertEqual(try reopened.snapshots(photoID: photo.id), try original.snapshots(photoID: photo.id))
        XCTAssertEqual(try reopened.collections(), try original.collections())
        XCTAssertEqual(try reopened.photo(copy.id)?.sourceKey, photo.sourceKey)
        let oldRecord = try XCTUnwrap(ExportService.history(catalog: reopened).logs.first)
        XCTAssertTrue(oldRecord.isArchived)
        XCTAssertFalse(oldRecord.canRetryInBatch)
        XCTAssertThrowsError(try ExportService.reauthorizeTarget(id: oldJob.id, directory: fixture.target, catalog: reopened))
        XCTAssertFalse(fm.fileExists(atPath: oldOutput.path))
        XCTAssertEqual(try ExportService.history(catalog: original).logs.first?.state, "failed")
        XCTAssertTrue(reopenedRoot.path.contains("/Relocated/Files/source"))
        XCTAssertNotEqual(reopenedPhoto.identityKey, photo.identityKey)
        let rendered = try await pipeline.render(ImageRequest(photo: reopenedPhoto, root: reopenedRoot, recipe: recipe), longEdge: 40)
        XCTAssertEqual(rendered.image.width, 20)
        recipe.exposure = 1
        try reopened.saveRecipe(id: photo.id, recipe: recipe)
        XCTAssertNotEqual(try reopened.photo(photo.id)?.recipe, try original.photo(photo.id)?.recipe)

        let second = try await CatalogArchive.create(catalog: reopened, destination: fixture.target.appendingPathComponent("Second"), extras: [])
        XCTAssertTrue(fm.fileExists(atPath: second.deletingLastPathComponent().appendingPathComponent("Files/Delivery/Notes.txt").path))
    }

    func testMissingFileCancellationAndLateDestinationRaceDoNotPublish() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let fm = FileManager.default
        let image = fixture.source.appendingPathComponent("A.jpg")
        try fixture.image(image)
        let catalog = try XCTUnwrap(fixture.catalog)
        let root = try catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        try catalog.index(ReferenceImporter.inspect(url: image.resolvingSymlinksInPath(), root: root, rootURL: URL(fileURLWithPath: root.path)))
        let target = fixture.target.appendingPathComponent("Archive")
        let inside = fixture.source.appendingPathComponent("Recursive")
        do { _ = try await CatalogArchive.create(catalog: catalog, destination: inside, extras: []); XCTFail("Recursive destination") }
        catch { XCTAssertFalse(fm.fileExists(atPath: inside.path)) }

        let job = Task {
            try await CatalogArchive.create(catalog: catalog, destination: target, extras: []) { done, _ in
                if done == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await job.value; XCTFail("Cancelled archive") }
        catch is CancellationError { XCTAssertFalse(fm.fileExists(atPath: target.path)) }

        do {
            _ = try await CatalogArchive.create(catalog: catalog, destination: target, extras: []) { done, _ in
                if done == 0 { try? Data("existing".utf8).write(to: target) }
            }
            XCTFail("Late destination must survive")
        } catch { XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "existing") }
        try fm.removeItem(at: target)
        try fm.removeItem(at: image)
        do { _ = try await CatalogArchive.create(catalog: catalog, destination: target, extras: []); XCTFail("Missing original") }
        catch { XCTAssertEqual(try fm.contentsOfDirectory(atPath: fixture.target.path), []) }
    }
}
