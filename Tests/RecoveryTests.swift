import XCTest
import GRDB
@testable import Phosdeck

final class RecoveryTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func testCacheQuotaAndClearCannotDeleteUserFiles() throws {
        let original = directory.appendingPathComponent("original.ARW")
        try Data("original".utf8).write(to: original)
        let cache = try PreviewDiskCache(directory: directory.appendingPathComponent("cache"), limit: 5)
        try cache.store(Data("first".utf8), key: "a")
        try cache.store(Data("second".utf8), key: "b")
        XCTAssertLessThanOrEqual(try cache.usage(), 5)
        let unrelated = cache.directory.appendingPathComponent("not-cache.jpg")
        try Data("user".utf8).write(to: unrelated)
        try cache.clear()
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("user".utf8))
    }
    func testRelocationPreservesRatingsAndRejectsChangedContent() async throws {
        let old = directory.appendingPathComponent("old"), new = directory.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        let file = old.appendingPathComponent("A.ARW")
        try Data("identity fixture, not RAW".utf8).write(to: file)
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url: old, bookmark: AccessLease.bookmark(old, readOnly: true))
        let identity = try FileIdentity.read(file)
        var photo = Photo(id: "p", rootID: root.id, relativePath: "A.ARW", identity: try JSONEncoder().encode(identity), identityKey: identity.key, width: 0, height: 0)
        photo.digest = try SafeFileWriter.sha256(file)
        try catalog.index(photo); try catalog.setOrganization(ids: ["p"], rating: 4)
        try FileManager.default.copyItem(at: file, to: new.appendingPathComponent("A.ARW"))
        let report = try await RootRelocator().relocate(root, to: new, catalog: catalog)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try catalog.photos()[0].rating, 4)
        try Data("different".utf8).write(to: new.appendingPathComponent("A.ARW"))
        let changed = try await RootRelocator().relocate(try catalog.roots()[0], to: new, catalog: catalog)
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(try catalog.photos()[0].availability, "changed")
        XCTAssertEqual(try catalog.photos()[0].rating, 4)
    }
    func testSingleOriginalLocationPreservesVersionsAndFrozenExports() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let file = fixture.source.appendingPathComponent("A.jpg")
        try fixture.image(file)
        let catalog = try XCTUnwrap(fixture.catalog)
        let root = try catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: file, root: root, rootURL: fixture.source)
        try catalog.index(photo)
        let pipeline = ImagePipeline()
        let recipe = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        try catalog.saveRecipe(id: photo.id, recipe: recipe)
        try catalog.setOrganization(ids: [photo.id], rating: 4, flag: 1, colorLabel: 2)
        _ = try catalog.setCaptions([photo.id: "保留题注"])
        _ = try catalog.changeKeyword("保留词", ids: [photo.id], adding: true)
        try catalog.createSnapshot(photoID: photo.id, title: "定位前")
        let copy = try XCTUnwrap(catalog.createVirtualCopies(ids: [photo.id]).first)
        let collection = PhotoCollection(id: "keep", name: "保留集合")
        try await catalog.database.write { try collection.insert($0) }
        try catalog.membership(ids: [photo.id, copy.id], collection: collection.id, add: true)
        let before = Dictionary(uniqueKeysWithValues: try catalog.photos().map { ($0.id, $0) })
        let retainedTables = ["editHistory", "editSnapshot", "photoKeyword", "collection", "membership", "attachment", "rawJpegPair"]
        func retained() throws -> [String: [Row]] { try catalog.database.read { db in try Dictionary(uniqueKeysWithValues: retainedTables.map { ($0, try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid")) }) } }
        let retainedBefore = try retained()
        let oldRequest = ImageRequest(photo: try XCTUnwrap(catalog.photo(photo.id)), root: root, recipe: recipe)
        let options = ExportOptions(format: .png)
        let targetBookmark = try AccessLease.bookmark(fixture.target, readOnly: false)
        let old = ExportSnapshot(id: "old-frozen", request: oldRequest, destination: fixture.target.appendingPathComponent("old.png"), targetBookmark: targetBookmark, options: options)
        let frozenBytes = try JSONEncoder().encode(old)
        try await catalog.database.write { try $0.execute(sql: "INSERT INTO exportItem(id,snapshot,state,destination) VALUES (?,?,'failed',?)", arguments: [old.id, frozenBytes, old.destination.path]) }
        let sub = fixture.source.appendingPathComponent("moved"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let moved = sub.appendingPathComponent("renamed.jpg"); try FileManager.default.moveItem(at: file, to: moved)
        let service = RootRelocator(), source = try XCTUnwrap(catalog.source(photo.sourceKey))
        let plan = try await service.prepare(source, file: moved, catalog: catalog)
        XCTAssertEqual(try catalog.source(source.id), source, "Preparing/canceling a chooser must not mutate a catalog")
        try await service.commit(plan, catalog: catalog)
        for current in try catalog.versions(sourceID: source.id) {
            var expected = try XCTUnwrap(before[current.id]); expected.relativePath = "moved/renamed.jpg"
            XCTAssertEqual(current, expected, "Source mapping changes must preserve every version's exact edits and organization")
        }
        XCTAssertEqual(try retained(), retainedBefore)
        let afterLocationBytes = try await catalog.database.read { try Data.fetchOne($0, sql: "SELECT snapshot FROM exportItem WHERE id=?", arguments: [old.id]) }
        XCTAssertEqual(afterLocationBytes, frozenBytes, "Relocation itself must preserve the exact frozen BLOB")
        let current = try XCTUnwrap(catalog.photo(photo.id))
        let request = ImageRequest(photo: current, root: root, recipe: recipe)
        let new = ExportSnapshot(id: "new-frozen", request: request, destination: fixture.target.appendingPathComponent("new.png"), targetBookmark: targetBookmark, options: options)
        let reports = await ExportService(pipeline: pipeline).run([old, new], catalog: catalog) { _ in }
        XCTAssertTrue(reports.contains { $0.contains("原片缺失") }, "Old frozen requests retain the old path and fail safely")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.destination.path))
        let storedBytes = try await catalog.database.read { try Data.fetchOne($0, sql: "SELECT snapshot FROM exportItem WHERE id=?", arguments: [old.id]) }
        let retried = try JSONDecoder().decode(ExportSnapshot.self, from: XCTUnwrap(storedBytes))
        XCTAssertEqual(retried.request.photo, old.request.photo)
        XCTAssertEqual(retried.request.root.path, old.request.root.path)
        XCTAssertEqual(retried.request.root.bookmark, old.request.root.bookmark)
        XCTAssertEqual(retried.request.recipe, old.request.recipe)
        let backup = fixture.directory.appendingPathComponent("location-backup.sqlite"); try catalog.backup(to: backup)
        let reopened = try CatalogStore.restore(from: backup, to: fixture.directory.appendingPathComponent("restored-location"))
        XCTAssertEqual(try reopened.photo(copy.id)?.relativePath, "moved/renamed.jpg")
        XCTAssertEqual(try SafeFileWriter.sha256(moved), recipe.sourceDigest)
        try FileManager.default.moveItem(at: moved, to: file)
        let restored = try await service.prepare(try XCTUnwrap(catalog.source(source.id)), file: file, catalog: catalog)
        try await service.commit(restored, catalog: catalog)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try catalog.photos().map { ($0.id, $0) }), before)
    }
    func testSingleOriginalLocationRejectsWrongOccupiedStaleAndCancelledCandidates() async throws {
        let folder = directory.appendingPathComponent("source"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let a = folder.appendingPathComponent("A.jpg"), candidate = folder.appendingPathComponent("renamed.jpg")
        try Data("original".utf8).write(to: a)
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url: folder, bookmark: AccessLease.bookmark(folder, readOnly: true))
        let identity = try FileIdentity.read(a)
        var photo = Photo(id: "a", rootID: root.id, relativePath: "A.jpg", identity: try JSONEncoder().encode(identity), identityKey: identity.key, width: 1, height: 1)
        photo.digest = try SafeFileWriter.sha256(a); try catalog.index(photo)
        try FileManager.default.moveItem(at: a, to: candidate)
        let service = RootRelocator(), original = try XCTUnwrap(catalog.source("a"))
        let wrong = folder.appendingPathComponent("wrong.jpg"); try Data("different".utf8).write(to: wrong)
        do { _ = try await service.prepare(original, file: wrong, catalog: catalog); XCTFail("Wrong bytes accepted") } catch {}
        let link = folder.appendingPathComponent("link.jpg"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: candidate)
        do { _ = try await service.prepare(original, file: link, catalog: catalog); XCTFail("Symlink accepted") } catch {}
        let differentType = folder.appendingPathComponent("renamed.png"); try FileManager.default.copyItem(at: candidate, to: differentType)
        do { _ = try await service.prepare(original, file: differentType, catalog: catalog); XCTFail("Changed format accepted") } catch {}
        let plan = try await service.prepare(original, file: candidate, catalog: catalog)
        try Data("changed after verification".utf8).write(to: candidate)
        do { try await service.commit(plan, catalog: catalog); XCTFail("Stale file accepted") } catch {}
        try Data("original".utf8).write(to: candidate)
        let checked = try await service.prepare(original, file: candidate, catalog: catalog)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.commit(checked, catalog: catalog)
        }
        do { try await cancelled.value; XCTFail("Cancelled write accepted") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let occupied = folder.appendingPathComponent("B.jpg"); try FileManager.default.copyItem(at: candidate, to: occupied)
        let pending = try await service.prepare(original, file: occupied, catalog: catalog)
        var other = photo; other.id = "b"; other.relativePath = "B.jpg"
        other.identity = try JSONEncoder().encode(pending.identity); other.identityKey = pending.identity.key
        try catalog.index(other)
        do { try await service.commit(pending, catalog: catalog); XCTFail("File already owned by another source accepted") } catch {}
        XCTAssertEqual(try catalog.source("a"), original)
        XCTAssertEqual(try catalog.roots().count, 1)
        try await catalog.database.write { try $0.execute(sql: "DELETE FROM photo WHERE id='b'"); try $0.execute(sql: "DELETE FROM photoSource WHERE id='b'") }
        let fresh = try await service.prepare(original, file: candidate, catalog: catalog)
        try await catalog.database.write { try $0.execute(sql: "UPDATE photoSource SET availability='changed' WHERE id='a'") }
        do { try await service.commit(fresh, catalog: catalog); XCTFail("Stale catalog source accepted") } catch {}
        XCTAssertEqual(try catalog.photo("a")?.relativePath, "A.jpg")
        XCTAssertEqual(try SafeFileWriter.sha256(candidate), photo.digest)
    }
    func testSingleOriginalLocationNewRootVerifiesAttachmentsAndUnknownDigest() async throws {
        let old = directory.appendingPathComponent("old"), new = directory.appendingPathComponent("new")
        for path in [old, new] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let file = old.appendingPathComponent("A.jpg"), moved = new.appendingPathComponent("B.jpg")
        try Data("original".utf8).write(to: file); try FileManager.default.copyItem(at: file, to: moved)
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url: old, bookmark: AccessLease.bookmark(old, readOnly: true))
        let identity = try FileIdentity.read(file)
        let photo = Photo(id: "a", rootID: root.id, relativePath: "A.jpg", identity: try JSONEncoder().encode(identity), identityKey: identity.key, width: 1, height: 1)
        try catalog.index(photo)
        let service = RootRelocator()
        do { _ = try await service.prepare(try XCTUnwrap(catalog.source("a")), file: moved, directory: new, catalog: catalog); XCTFail("A new identity without a known digest was accepted") } catch {}
        let sameFile = old.appendingPathComponent("same-identity.jpg")
        try FileManager.default.moveItem(at: file, to: sameFile)
        let identityOnly = try await service.prepare(try XCTUnwrap(catalog.source("a")), file: sameFile, catalog: catalog)
        try await service.commit(identityOnly, catalog: catalog)
        XCTAssertNil(try catalog.source("a")?.digest, "Identity-only verification does not invent a previously known digest")
        try FileManager.default.moveItem(at: sameFile, to: file)
        let back = try await service.prepare(try XCTUnwrap(catalog.source("a")), file: file, catalog: catalog)
        try await service.commit(back, catalog: catalog)
        let digest = try SafeFileWriter.sha256(file)
        try await catalog.database.write { try $0.execute(sql: "UPDATE photoSource SET digest=? WHERE id='a'", arguments: [digest]) }
        let copy = try XCTUnwrap(catalog.createVirtualCopies(ids: ["a"]).first)
        let sidecar = Data("retained attachment".utf8), sidePath = old.appendingPathComponent("A.xmp")
        try sidecar.write(to: sidePath)
        let sideDigest = try SafeFileWriter.sha256(sidePath)
        try await catalog.database.write { db in for id in ["a", copy.id] { try db.execute(sql: "INSERT INTO attachment VALUES (?,'A.xmp',?)", arguments: [id, sideDigest]) } }
        let source = try XCTUnwrap(catalog.source("a"))
        do { _ = try await service.prepare(source, file: moved, directory: new, catalog: catalog); XCTFail("Missing attachments silently rebound") } catch {}
        XCTAssertEqual(try catalog.roots().count, 1, "Failed preflight must not register a root")
        let newSide = new.appendingPathComponent("A.xmp"); try sidecar.write(to: newSide)
        let plan = try await service.prepare(source, file: moved, directory: new, catalog: catalog)
        try Data("changed".utf8).write(to: newSide)
        do { try await service.commit(plan, catalog: catalog); XCTFail("Changed attachment accepted") } catch {}
        XCTAssertEqual(try catalog.roots().count, 1)
        try sidecar.write(to: newSide)
        try await service.commit(plan, catalog: catalog)
        XCTAssertEqual(try catalog.roots().count, 2)
        for current in try catalog.versions(sourceID: source.id) {
            XCTAssertEqual(current.rootID, plan.root.id); XCTAssertEqual(current.relativePath, "B.jpg")
            XCTAssertEqual(current.sourceKey, source.id); XCTAssertEqual(current.digest, digest)
        }
        XCTAssertTrue(try catalog.protectedPaths().contains(newSide.resolvingSymlinksInPath().path))
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8), "Location changes do not move or delete originals")
        XCTAssertEqual(try Data(contentsOf: sidePath), sidecar)
    }
    func testInterruptedPublicationCanBeIndexedWithoutSecondCopy() async throws {
        // Exercise the actual copy boundary using generated JPEG fixture from the import test helper.
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        try fixture.image(fixture.source.appendingPathComponent("A.jpg"))
        var plan = try await fixture.plan()
        var member = plan.groups[0].members[0]
        let staging = try SafeFileWriter.stage(in: fixture.target)
        try Data(contentsOf: member.source).write(to: staging)
        member.staging = staging; member.stagedIdentity = try FileIdentity.read(staging); member.state = "verified"
        try SafeFileWriter.publish(staging, to: member.destination)
        // Simulate process stopping immediately before the 'published' database update.
        plan.groups[0].members[0] = member
        let result = await CopyImporter().run(plan, catalog: fixture.catalog) { _ in }
        XCTAssertEqual(result.groups[0].state, "completed")
        XCTAssertEqual(try fixture.catalog.photos().count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.target.path).filter { $0.hasSuffix("jpg") }.count, 1)
    }
    func testPublishedTargetRacePreservesRecoveryAndThirdPartyFile() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        try fixture.image(fixture.source.appendingPathComponent("A.jpg"))
        try fixture.image(fixture.target.appendingPathComponent("A.jpg"), color: .blue)
        var plan = try await fixture.plan(.overwrite)
        var member = plan.groups[0].members[0]
        let recovery = fixture.target.appendingPathComponent("retained-old.jpg")
        try FileManager.default.moveItem(at: member.destination, to: recovery)
        member.recovery = recovery
        let staging = try SafeFileWriter.stage(in: fixture.target)
        try Data(contentsOf: member.source).write(to: staging)
        member.staging = staging; member.stagedIdentity = try FileIdentity.read(staging); member.state = "oldTargetPreserved"
        try Data("external".utf8).write(to: member.destination)
        plan.groups[0].members[0] = member
        let stopped = await CopyImporter().run(plan, catalog: fixture.catalog) { _ in }
        XCTAssertEqual(stopped.groups[0].state, "needsReview")
        XCTAssertEqual(try SafeFileWriter.sha256(recovery), member.targetDigest)
        XCTAssertEqual(try String(contentsOf: member.destination, encoding: .utf8), "external")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }
    func testRescanComparesIdentityValuesNotJSONKeyOrder() throws {
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
        let root = try catalog.addRoot(url: directory.appendingPathComponent("photos"), bookmark: Data())
        let first = Data(#"{"device":1,"inode":2,"size":3,"modifiedSeconds":4,"modifiedNanoseconds":5}"#.utf8)
        let second = Data(#"{"inode":2,"modifiedNanoseconds":5,"device":1,"modifiedSeconds":4,"size":3}"#.utf8)
        var photo = Photo(id: "identity", rootID: root.id, relativePath: "A.ARW", identity: first, identityKey: "1:2", width: 10, height: 20)
        try catalog.index(photo); try catalog.setOrganization(ids: [photo.id], rating: 4)
        photo.identity = second; try catalog.index(photo)
        XCTAssertEqual(try catalog.photo(photo.id)?.availability, "available")
        XCTAssertEqual(try catalog.photo(photo.id)?.rating, 4)
    }

    func testUnavailableSourcePreservesOrganizationAndReturnsAfterReauthorization() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let url = fixture.source.appendingPathComponent("A.jpg"); try fixture.image(url)
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        var photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source)
        photo.digest = try SafeFileWriter.sha256(url)
        try fixture.catalog.index(photo); try fixture.catalog.setOrganization(ids: [photo.id], rating: 5)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try SourceAvailability.check(root: fixture.source, file: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let offline = fixture.directory.appendingPathComponent("disconnected")
        try FileManager.default.moveItem(at: fixture.source, to: offline)
        XCTAssertThrowsError(try SourceAvailability.check(root: fixture.source, file: url))
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.rating, 5)
        try FileManager.default.moveItem(at: offline, to: fixture.source)
        let report = try await RootRelocator().relocate(root, to: fixture.source, catalog: fixture.catalog)
        XCTAssertTrue(report.isEmpty)
        _ = try await ImagePipeline().render(ImageRequest(photo: try XCTUnwrap(fixture.catalog.photo(photo.id)), root: root, recipe: nil), longEdge: 20)
        XCTAssertEqual(try fixture.catalog.photo(photo.id)?.rating, 5)
    }
    @MainActor func testFailedRecipeSaveRetainsDraftAndBlocksNavigation() throws {
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("draft-catalog"))
        let root = try catalog.addRoot(url: directory.appendingPathComponent("photos"), bookmark: Data())
        let photo = Photo(id: "draft", rootID: root.id, relativePath: "A.ARW", identity: Data(), identityKey: "draft", width: 10, height: 20)
        try catalog.index(photo)
        let model = AppModel(); model.catalog = catalog; model.activeID = photo.id
        let recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, exposure: 1, temperature: 5500, tint: 0)
        model.recipe = recipe; model.dirty = true
        try catalog.database.write { try $0.execute(sql: "CREATE TRIGGER fail_save BEFORE UPDATE ON photo BEGIN SELECT RAISE(ABORT,'injected storage failure'); END") }
        XCTAssertFalse(model.commitRecipe()); XCTAssertTrue(model.dirty); XCTAssertEqual(model.recipe, recipe)
        model.choose([], active: nil)
        XCTAssertEqual(model.activeID, photo.id); XCTAssertNotNil(model.error)
        try catalog.database.write { try $0.execute(sql: "DROP TRIGGER fail_save") }
        XCTAssertTrue(model.commitRecipe()); XCTAssertFalse(model.dirty)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photo.id)?.recipe)), recipe)
    }

    @MainActor func testRapidSelectionCannotInstallAnOlderPreview() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        for name in ["first", "last"] {
            let url = fixture.source.appendingPathComponent(name + ".jpg"); try fixture.image(url)
            try fixture.catalog.index(ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source))
        }
        let photos = try fixture.catalog.photos()
        let model = AppModel(); model.catalog = fixture.catalog; try model.reload()
        model.choose([photos[0].id], active: photos[0].id)
        try await Task.sleep(for: .milliseconds(110))
        model.choose([photos[1].id], active: photos[1].id)
        for _ in 0..<100 where model.image == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.active?.id, photos[1].id)
        XCTAssertNotNil(model.image)
        XCTAssertFalse(model.imageStatus.contains("正在"))
    }

}
