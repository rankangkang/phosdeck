import XCTest
import GRDB
@testable import Phosdeck

final class CatalogFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phoscat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    private func fixture(_ filename: String = "暗房.omlcat") throws -> URL {
        let url = folder.appendingPathComponent(filename)
        let catalog = try CatalogStore(fileURL: url, create: true)
        let root = try catalog.addRoot(url: folder.appendingPathComponent("originals"), bookmark: Data())
        try catalog.index(Photo(id: "p", rootID: root.id, relativePath: "synthetic.ARW", identity: Data(), identityKey: "1:2", width: 80, height: 120))
        try catalog.setOrganization(ids: ["p"], rating: 5, flag: 1, colorLabel: 2)
        try catalog.collection(name: "精选", id: "c")
        try catalog.membership(ids: ["p"], collection: "c", add: true)
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        try catalog.saveRecipe(id: "p", recipe: recipe)
        recipe.exposure = 1
        try catalog.saveRecipe(id: "p", recipe: recipe)
        try catalog.createSnapshot(photoID: "p", title: "亮一点")
        return url
    }

    func testNewCatalogNamesUsePhoscatWithoutDuplicatingExtensions() {
        for name in ["旅行", "旅行.omlcat", "旅行.OMLRCAT", "旅行.phoscat", "旅行.PHOSCAT"] {
            XCTAssertEqual(CatalogFile.filename(name), "旅行.phoscat")
        }
        XCTAssertEqual(CatalogFile.filename("旅行.2026"), "旅行.2026.phoscat")
        XCTAssertFalse(CatalogFile.isLegacy(folder.appendingPathComponent("旅行.phoscat")))
    }

    func testCreationRefusesANameOccupiedByASymlink() throws {
        let link = folder.appendingPathComponent("Occupied.phoscat")
        let target = folder.appendingPathComponent("DoesNotExist.phoscat")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CatalogStore(fileURL: link, create: true))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testBothLegacyExtensionsRenameWithoutChangingDatabaseBytesOrIdentity() throws {
        for filename in ["用户目录.omlcat", "旧目录.omlrcat"] {
            let source = try fixture(filename)
            let bytes = try Data(contentsOf: source), identity = try FileIdentity.read(source)
            let destination = try CatalogExtensionChange(source: source).perform()
            XCTAssertEqual(destination.pathExtension, "phoscat")
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(try FileIdentity.read(destination), identity)
            let reopened = try CatalogStore(fileURL: destination)
            XCTAssertEqual(try reopened.photo("p")?.rating, 5)
            XCTAssertEqual(try reopened.photo("p")?.flag, 1)
            XCTAssertEqual(try reopened.photo("p")?.colorLabel, 2)
            XCTAssertEqual(try reopened.members("c"), ["p"])
            XCTAssertEqual(try reopened.editHistory(photoID: "p").count, 2)
            XCTAssertEqual(try reopened.snapshots(photoID: "p").first?.title, "亮一点")
            let recipe = try XCTUnwrap(reopened.photo("p")?.recipe)
            XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: recipe).exposure, 1)
        }
    }

    @MainActor func testCatalogFileBookmarkOpensWritesAndReopensTheSameCatalog() async throws {
        let file = try fixture("测试.phoscat")
        let bookmark = try AccessLease.bookmark(file, readOnly: false)
        let recent = RecentCatalog(path: file.path, filename: file.lastPathComponent, bookmark: bookmark)
        let request = try recent.openRequest()
        XCTAssertTrue(request.fileAccessOnly)
        XCTAssertEqual(request.url.standardizedFileURL, file.standardizedFileURL)

        let model = AppModel()
        let opened = try XCTUnwrap(model.requestCatalogOpen(request))
        await opened.value
        await model.cacheConfigurationTask?.value
        do {
            let catalog = try XCTUnwrap(model.catalog, model.error ?? "")
            XCTAssertThrowsError(try CatalogStore(fileURL: file))
            try catalog.setOrganization(ids: ["p"], rating: 3)
            try catalog.setOrganization(ids: ["p"], rating: 4)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + "-journal"))
        model.catalog = nil

        let reopened = try XCTUnwrap(model.requestCatalogOpen(try recent.openRequest(restoringWorkspace: true)))
        await reopened.value
        await model.cacheConfigurationTask?.value
        let catalog = try XCTUnwrap(model.catalog, model.error ?? "")
        XCTAssertEqual(try catalog.photo("p")?.rating, 4)
    }

    @MainActor func testFinderOpenKeepsLatestFileWhileThePreviousCatalogConfiguresItsCache() async throws {
        let previous = try fixture("Previous.phoscat")
        let first = try fixture("First.phoscat")
        let latest = try fixture("Latest.phoscat")
        let model = AppModel()
        model.catalog = try CatalogStore(fileURL: previous)
        model.configureCache()
        let cache = try XCTUnwrap(model.cacheConfigurationTask)

        model.openCatalog(url: first)
        model.openCatalog(url: latest)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.catalog?.fileURL, previous.resolvingSymlinksInPath())

        await cache.value
        await model.catalogTransfer?.value
        await model.cacheConfigurationTask?.value
        XCTAssertEqual(model.catalog?.fileURL, latest.resolvingSymlinksInPath())
        XCTAssertNil(model.error)
        model.catalog = nil
    }

    func testCatalogRecoveryAccessPreservesAnExistingJournal() throws {
        let file = try fixture("恢复.phoscat")
        let journal = URL(fileURLWithPath: file.path + "-journal")
        let payload = Data("Existing recovery file".utf8)
        try payload.write(to: journal)
        let access = try CatalogRelatedFile.recoveryAccess(beside: file)
        defer { withExtendedLifetime(access) {} }
        XCTAssertEqual(try Data(contentsOf: journal), payload)
    }

    func testFileBookmarkPreparesMissingWALFilesForValidation() throws {
        let file = try fixture("WAL.phoscat")
        let database = try DatabaseQueue(path: file.path)
        XCTAssertEqual(try database.writeWithoutTransaction { try String.fetchOne($0, sql: "PRAGMA journal_mode=WAL") }, "wal")
        try database.close()
        let companions = ["-wal", "-shm"].map { file.path + $0 }
        XCTAssertTrue(companions.allSatisfy { !FileManager.default.fileExists(atPath: $0) })

        let catalog = try CatalogStore(fileURL: file, access: AccessLease(url: file))
        XCTAssertTrue(companions.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        try catalog.setOrganization(ids: ["p"], rating: 2)
        XCTAssertEqual(try catalog.photo("p")?.rating, 2)
    }

    func testDestinationCollisionPreservesBothFiles() throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let change = try CatalogExtensionChange(source: source)
        let other = Data("existing destination".utf8)
        try other.write(to: change.destination)
        XCTAssertThrowsError(try change.perform())
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try Data(contentsOf: change.destination), other)
    }

    func testOpenCatalogCannotBeRenamed() throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let opened = try CatalogStore(fileURL: source)
        let change = try CatalogExtensionChange(source: source)
        XCTAssertThrowsError(try change.perform())
        XCTAssertEqual(opened.fileURL, source.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: change.destination.path))
    }

    func testRecoveryFilesBesideEitherNameArePreservedAndBlockRename() throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let change = try CatalogExtensionChange(source: source)
        for url in [source, change.destination] {
            for suffix in ["-journal", "-wal", "-shm"] {
                let recovery = URL(fileURLWithPath: url.path + suffix), bytes = Data("recover me".utf8)
                try bytes.write(to: recovery)
                XCTAssertThrowsError(try change.perform())
                XCTAssertEqual(try Data(contentsOf: recovery), bytes)
                XCTAssertEqual(try Data(contentsOf: source), before)
                XCTAssertFalse(FileManager.default.fileExists(atPath: change.destination.path))
                try FileManager.default.removeItem(at: recovery)
            }
        }
    }

    func testConfirmationCannotRenameAReplacedSource() throws {
        let source = try fixture(), change = try CatalogExtensionChange(source: source)
        let replacement = Data("replacement at the old path".utf8)
        try replacement.write(to: source, options: .atomic)
        XCTAssertThrowsError(try change.perform())
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: change.destination.path))
    }

    func testInvalidAndOldSchemaCatalogsAreRejectedWithoutChanges() throws {
        let invalid = folder.appendingPathComponent("invalid.omlcat")
        try Data("not a catalog".utf8).write(to: invalid)
        let old = try fixture("old.omlrcat")
        let db = try DatabaseQueue(path: old.path)
        try db.write { try $0.execute(sql: "PRAGMA user_version = 12") }
        try db.close()
        for source in [invalid, old] {
            let before = try Data(contentsOf: source), change = try CatalogExtensionChange(source: source)
            XCTAssertThrowsError(try change.perform())
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: change.destination.path))
        }
    }

    func testVerificationFailureRestoresOriginalNameAndBytes() throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let change = try CatalogExtensionChange(source: source)
        XCTAssertThrowsError(try change.perform { throw LRCError("verification failed") })
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: change.destination.path))
        XCTAssertNoThrow(try CatalogStore(fileURL: source))
    }

    func testRollbackCollisionPreservesNewSourceAndRenamedCatalog() throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let change = try CatalogExtensionChange(source: source), other = Data("new occupant".utf8)
        XCTAssertThrowsError(try change.perform {
            try other.write(to: source, options: .withoutOverwriting)
            throw LRCError("verification failed")
        })
        XCTAssertEqual(try Data(contentsOf: source), other)
        XCTAssertEqual(try Data(contentsOf: change.destination), before)
        XCTAssertNoThrow(try CatalogStore(fileURL: change.destination))
    }

    @MainActor func testCancelLeavesCurrentCatalogAndLegacyFileUntouched() throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let current = try CatalogStore(fileURL: folder.appendingPathComponent("current.phoscat"), create: true)
        let model = AppModel(); model.catalog = current
        let request = CatalogOpenRequest(url: source, access: AccessLease(url: folder), bookmark: nil)
        XCTAssertNil(model.requestCatalogOpen(request, choice: .cancel))
        XCTAssertTrue(model.catalog === current)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.deletingPathExtension().appendingPathExtension("phoscat").path))
    }

    @MainActor func testKeepOriginalOpensLegacyCatalogWithoutRenaming() throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let model = AppModel()
        let request = CatalogOpenRequest(url: source, access: AccessLease(url: folder), bookmark: nil)
        XCTAssertNil(model.requestCatalogOpen(request, choice: .keepOriginal))
        XCTAssertNil(model.error)
        XCTAssertEqual(model.catalog?.fileURL, source.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(model.totalCount, 1)
    }

    @MainActor func testConfirmedChangeOpensNewNameAndBlocksSwitchingUntilFinished() async throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let model = AppModel()
        let request = CatalogOpenRequest(url: source, access: AccessLease(url: folder), bookmark: nil)
        let task = try XCTUnwrap(model.requestCatalogOpen(request, choice: .change))
        XCTAssertTrue(model.busy); XCTAssertTrue(model.changingCatalogExtension)
        XCTAssertFalse(model.canSwitchCatalog)
        await task.value
        XCTAssertNil(model.error)
        XCTAssertFalse(model.busy); XCTAssertFalse(model.changingCatalogExtension)
        let destination = try XCTUnwrap(model.catalog?.fileURL)
        XCTAssertEqual(destination.pathExtension, "phoscat")
        XCTAssertEqual(try Data(contentsOf: destination), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(model.totalCount, 1)
    }

    @MainActor func testFailedChangeKeepsPreviousWorkspaceAndReportsError() async throws {
        let source = try fixture(), before = try Data(contentsOf: source)
        let destination = source.deletingPathExtension().appendingPathExtension("phoscat")
        try Data("do not replace".utf8).write(to: destination)
        let model = AppModel()
        let current = try CatalogStore(fileURL: folder.appendingPathComponent("current.phoscat"), create: true)
        model.catalog = current; model.status = "previous workspace"
        let task = try XCTUnwrap(model.requestCatalogOpen(CatalogOpenRequest(url: source, access: AccessLease(url: folder), bookmark: nil), choice: .change))
        await task.value
        XCTAssertTrue(model.catalog === current)
        XCTAssertEqual(model.status, "previous workspace")
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.busy); XCTAssertFalse(model.changingCatalogExtension)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "do not replace")
    }

    @MainActor func testWorkspacePreferenceKeysFollowNewFilenameWithoutRemovingOriginals() throws {
        let suite = "phoscat-preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = folder.appendingPathComponent("one.omlcat"), destination = folder.appendingPathComponent("one.phoscat")
        defaults.set("p", forKey: source.path + ":activePhoto")
        defaults.set(4, forKey: source.path + ":lastRatingFilter")
        defaults.set("other", forKey: source.path + "2:activePhoto")
        AppModel.transferCatalogPreferences(from: source, to: destination, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: destination.path + ":activePhoto"), "p")
        XCTAssertEqual(defaults.integer(forKey: destination.path + ":lastRatingFilter"), 4)
        XCTAssertEqual(defaults.string(forKey: source.path + ":activePhoto"), "p")
        XCTAssertEqual(defaults.string(forKey: source.path + "2:activePhoto"), "other")
    }
}
