import XCTest
import GRDB
import CoreImage
import ImageIO
import SwiftUI
@testable import Phosdeck

final class RawJpegPairTests: XCTestCase {
    func makeFixture() throws -> (ImportTests,StorageRoot,Photo,Photo) {
        let f = ImportTests(); try f.setUpWithError()
        do {
            let sample = try MoreRAWTests.sample("leica_m8_8bit_uncompressed.DNG")
            let rawURL = f.source.appendingPathComponent("拍摄-A.DNG"), jpegURL = f.source.appendingPathComponent("拍摄-A.jpg")
            try FileManager.default.copyItem(at:sample,to:rawURL); try f.image(jpegURL,color:.blue)
            let root = try f.catalog.addRoot(url:f.source,bookmark:AccessLease.bookmark(f.source,readOnly:true))
            let raw = try ReferenceImporter.inspect(url:rawURL,root:root,rootURL:f.source), jpeg = try ReferenceImporter.inspect(url:jpegURL,root:root,rootURL:f.source)
            try f.catalog.index(raw); try f.catalog.index(jpeg)
            return (f,root,try XCTUnwrap(f.catalog.photo(raw.id)),try XCTUnwrap(f.catalog.photo(jpeg.id)))
        } catch { try? f.tearDownWithError(); throw error }
    }
    func source(_ id:String,_ path:String,_ root:String = "r") -> CatalogSource {
        CatalogSource(id:id,rootID:root,relativePath:path,identity:Data(),identityKey:id,digest:nil,revision:1,captureDate:nil,width:10,height:10,camera:nil,availability:"available",metadata:nil)
    }
    func testMissingCurrentRelationshipTableIsRefusedWithoutRebuilding() throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let file = f.catalog.fileURL
        try f.catalog.database.write { try $0.execute(sql:"DROP TABLE sourceCopyOrigin") }
        f.catalog = nil
        let before = try Data(contentsOf:file)
        XCTAssertThrowsError(try CatalogStore(fileURL:file))
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testCandidatesFilesystemCaseUnicodeAmbiguityRootsDirectoriesAndConflicts() throws {
        let a = source("r1","folder/Ä.DNG"), b = source("j1","folder/a\u{308}.JpEg")
        func detect(_ values:[CatalogSource],_ sensitive:Bool = false) -> [PairCandidate] {
            RawJpegPairing.candidates(sources:values,paired:[],active:Set(values.map(\.id)),caseSensitive:["r":sensitive,"other":sensitive])
        }
        XCTAssertEqual(detect([a,b]).count,1)
        XCTAssertTrue(detect([a,b])[0].issue == nil)
        XCTAssertTrue(detect([a,b],true).isEmpty,"case-sensitive FS keeps Ä and ä distinct")
        var same = b; same.relativePath = "folder/A\u{308}.jpg"; XCTAssertEqual(detect([a,same],true).count,1)
        var directory = b; directory.relativePath = "another/ä.jpg"; XCTAssertTrue(detect([a,directory]).isEmpty)
        var root = b; root.rootID = "other"; XCTAssertTrue(detect([a,root]).isEmpty)
        var duplicate = a; duplicate.id = "r2"; duplicate.relativePath = "folder/ä.ARW"
        XCTAssertNotNil(detect([a,b,duplicate])[0].issue)
        var camera = b; camera.camera = "Different"; var original = a; original.camera = "Camera"
        XCTAssertNotNil(detect([original,camera])[0].issue)
        original.camera = nil; original.captureDate = "2026:10:18 10:00:00.250+02:00"; camera.camera = nil; camera.captureDate = "2026-10-18T08:00:03Z"
        XCTAssertNotNil(detect([original,camera])[0].issue)
        var exposureRaw = a, exposureJPEG = b
        let sameMetadata = PhotoMetadata(iso:100,aperture:4,exposureTime:1.0/125)
        exposureRaw.metadata = try JSONEncoder().encode(sameMetadata); exposureJPEG.metadata = exposureRaw.metadata
        XCTAssertNil(detect([exposureRaw,exposureJPEG])[0].issue)
        var changed = sameMetadata; changed.iso = 6400
        exposureJPEG.metadata = try JSONEncoder().encode(changed); XCTAssertNotNil(detect([exposureRaw,exposureJPEG])[0].issue)
        changed = sameMetadata; changed.exposureTime = 1.0/1000
        exposureJPEG.metadata = try JSONEncoder().encode(changed); XCTAssertNotNil(detect([exposureRaw,exposureJPEG])[0].issue)
        XCTAssertTrue(RawJpegPairing.candidates(sources:[a,b],paired:[a.id],active:[a.id,b.id],caseSensitive:["r":false]).isEmpty)
        XCTAssertNotNil(RawJpegPairing.candidates(sources:[a,b],paired:[],active:[a.id],caseSensitive:["r":false])[0].issue)
        XCTAssertTrue(RawJpegPairing.candidates(sources:[a,b],paired:[],active:[a.id,b.id],caseSensitive:["r":false],within:["unrelated"]).isEmpty)
    }
    func testIndependentSourcesVersionsStacksRecipesHistorySnapshotsBackupAndRelocation() async throws {
        let (f,root,raw,jpeg) = try makeFixture(); defer { try? f.tearDownWithError() }
        let pairing = RawJpegPairing(), pipeline = ImagePipeline()
        let detected = try await pairing.detect(catalog:f.catalog)
        XCTAssertEqual(detected.count,1); XCTAssertNil(detected[0].issue)
        var rawRecipe = try await pipeline.baseline(ImageRequest(photo:raw,root:root,recipe:nil))
        var jpegRecipe = try await pipeline.baseline(ImageRequest(photo:jpeg,root:root,recipe:nil))
        rawRecipe.exposure = 0.7; jpegRecipe.exposure = -0.3
        jpegRecipe.develop.pointColors = [PointColor(lightness:0.5,chroma:0.1,hue:0.4,hueShift:12)]
        try f.catalog.saveRecipe(id:raw.id,recipe:rawRecipe); try f.catalog.saveRecipe(id:jpeg.id,recipe:jpegRecipe)
        try f.catalog.createSnapshot(photoID:raw.id,title:"RAW history"); try f.catalog.createSnapshot(photoID:jpeg.id,title:"JPEG history")
        try f.catalog.collection(name:"Both",id:"c"); try f.catalog.membership(ids:[raw.id,jpeg.id],collection:"c",add:true)
        let copies = try f.catalog.createVirtualCopies(ids:[raw.id,jpeg.id]), rc = try XCTUnwrap(copies.first { $0.sourceKey == raw.sourceKey }), jc = try XCTUnwrap(copies.first { $0.sourceKey == jpeg.sourceKey })
        _ = try f.catalog.changeStacks(.group(top:raw.id,members:[rc.id,jpeg.id,jc.id]))
        let originalStacks = try f.catalog.stacks()
        let frozen = try await pairing.prepare(rawID:raw.sourceKey,jpegID:jpeg.sourceKey,catalog:f.catalog)
        _ = try await pairing.apply([frozen],catalog:f.catalog)
        XCTAssertEqual(try f.catalog.stacks(),originalStacks)
        let pair = try XCTUnwrap(f.catalog.pair(sourceID:rc.sourceKey))
        XCTAssertEqual(pair.partner(of:jc.sourceKey),raw.sourceKey); XCTAssertEqual(try f.catalog.pairs().count,1)
        _ = try await pairing.apply([frozen],catalog:f.catalog); XCTAssertEqual(try f.catalog.pairs().count,1,"idempotent confirmation")
        try f.catalog.setOrganization(ids:[raw.id],rating:5)
        XCTAssertEqual(try f.catalog.photo(jpeg.id)?.rating,0); XCTAssertEqual(try f.catalog.photo(rc.id)?.rating,0)
        XCTAssertNotEqual(try f.catalog.photo(raw.id)?.recipe,try f.catalog.photo(jpeg.id)?.recipe)
        XCTAssertTrue(try f.catalog.snapshots(photoID:rc.id).isEmpty); XCTAssertEqual(try f.catalog.snapshots(photoID:jpeg.id).count,1)
        _ = try f.catalog.changeStacks(.ungroup([raw.id])); XCTAssertEqual(try f.catalog.pairs().count,1)
        _ = try f.catalog.setVersionDeletion([raw.id:true,rc.id:true])
        XCTAssertTrue(try f.catalog.versions(sourceID:raw.sourceKey).isEmpty); XCTAssertNotNil(try f.catalog.pair(sourceID:jpeg.sourceKey))
        XCTAssertNotNil(try f.catalog.photo(jc.id)); XCTAssertTrue(FileManager.default.fileExists(atPath:f.source.appendingPathComponent(raw.relativePath).path))
        let backup = f.target.appendingPathComponent("backup.sqlite"); try f.catalog.backup(to:backup)
        let restored = try CatalogStore.restore(from:backup,to:f.target.appendingPathComponent("restore"))
        XCTAssertEqual(try restored.pairs(),[pair])
        let moved = f.target.appendingPathComponent("moved"); try FileManager.default.copyItem(at:f.source,to:moved)
        let report = try await RootRelocator().relocate(root,to:moved,catalog:restored)
        XCTAssertTrue(report.isEmpty,"\(report)"); XCTAssertEqual(try restored.pairs(),[pair])
        let statuses = try await pairing.availability(catalog:restored)
        XCTAssertEqual(statuses[raw.sourceKey],"在线","zero-active source is still relocated and verified")
        _ = try restored.setVersionDeletion([raw.id:false,rc.id:false])
        let relocatedRaw = try XCTUnwrap(restored.photo(raw.id)), relocatedRoot = try XCTUnwrap(restored.roots().first)
        let rendered = try await pipeline.render(ImageRequest(photo:relocatedRaw,root:relocatedRoot,recipe:rawRecipe),longEdge:80)
        XCTAssertGreaterThan(rendered.image.width,0)
        let manifest = f.target.appendingPathComponent("manifest.json"); try restored.exportManifest(to:manifest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifest)) as? [String:Any])
        XCTAssertEqual((json["rawJpegPairs"] as? [[String:Any]])?.count,1)
    }
    func testStalePreviewWrongTypeAtomicPairUniquenessCancellationAndOffline() async throws {
        let (f,_,raw,jpeg) = try makeFixture(); defer { try? f.tearDownWithError() }
        let service = RawJpegPairing()
        let frozen = try await service.prepare(rawID:raw.sourceKey,jpegID:jpeg.sourceKey,catalog:f.catalog)
        let file = f.source.appendingPathComponent(jpeg.relativePath)
        let bytes = try Data(contentsOf:file)
        try f.image(file,color:.green)
        do { _ = try await service.apply([frozen],catalog:f.catalog); XCTFail("stale file") } catch { }
        XCTAssertTrue(try f.catalog.pairs().isEmpty)
        // Reinspect explicitly, do not reuse the old identity to accept a changed file.
        try bytes.write(to:file)
        let root = try XCTUnwrap(f.catalog.roots().first)
        let current = try ReferenceImporter.inspect(url:file,root:root,rootURL:f.source)
        try await f.catalog.database.write { try $0.execute(sql:"UPDATE photo SET identity=?,identityKey=? WHERE id=?",arguments:[current.identity,current.identityKey,jpeg.id]) }
        let updated = try await service.prepare(rawID:raw.sourceKey,jpegID:jpeg.sourceKey,catalog:f.catalog)
        let cancel = Task { try Task.checkCancellation(); return try await service.apply([updated],catalog:f.catalog) }; cancel.cancel()
        do { _ = try await cancel.value; XCTFail("cancelled") } catch { }
        XCTAssertTrue(try f.catalog.pairs().isEmpty)
        var bad = updated; bad.jpeg = updated.raw
        do { _ = try await service.apply([updated,bad],catalog:f.catalog); XCTFail("invalid second proposal must roll back whole batch") } catch { }
        XCTAssertTrue(try f.catalog.pairs().isEmpty)
        _ = try await service.apply([updated],catalog:f.catalog)
        let pair = try XCTUnwrap(f.catalog.pairs().first)
        let other = f.source.appendingPathComponent("other.jpg"); try f.image(other)
        let otherPhoto = try ReferenceImporter.inspect(url:other,root:root,rootURL:f.source); try f.catalog.index(otherPhoto)
        let occupied = try await service.prepare(rawID:raw.sourceKey,jpegID:otherPhoto.id,catalog:f.catalog)
        do { _ = try await service.apply([occupied],catalog:f.catalog); XCTFail("one source one pair") } catch { }
        XCTAssertEqual(try f.catalog.pairs(),[pair])
        let offline = f.source.appendingPathComponent("offline.DNG"); try FileManager.default.moveItem(at:f.source.appendingPathComponent(raw.relativePath),to:offline)
        let status = try await service.availability(catalog:f.catalog)
        XCTAssertTrue(status[raw.sourceKey]?.contains("离线") == true); XCTAssertEqual(status[jpeg.sourceKey],"在线")
        XCTAssertEqual(try f.catalog.pairs(),[pair])
        do { _ = try await ImagePipeline().render(ImageRequest(photo:raw,root:root,recipe:nil),longEdge:30); XCTFail("Offline RAW must fail instead of substituting JPEG") } catch { }
        let online = try XCTUnwrap(f.catalog.photo(jpeg.id))
        let rendered = try await ImagePipeline().render(ImageRequest(photo:online,root:root,recipe:nil),longEdge:30)
        XCTAssertGreaterThan(rendered.image.width,0)
        let previous = try f.catalog.restorePairs([]); XCTAssertTrue(try f.catalog.pairs().isEmpty)
        _ = try f.catalog.restorePairs(previous); XCTAssertEqual(try f.catalog.pairs(),[pair],"offline undo keeps relation")
        // A JPEG renamed to .DNG must never be accepted as a RAW endpoint.
        let wrong = f.source.appendingPathComponent("wrong.DNG"); try FileManager.default.copyItem(at:file,to:wrong)
        let identity = try FileIdentity.read(wrong)
        let bogus = Photo(id:"bogus",rootID:root.id,relativePath:"wrong.DNG",identity:try JSONEncoder().encode(identity),identityKey:identity.key,width:20,height:10)
        try f.catalog.index(bogus)
        do { _ = try await service.prepare(rawID:bogus.id,jpegID:otherPhoto.id,catalog:f.catalog); XCTFail("JPEG is not RAW") } catch { }
    }
    func testPreviewBeforeRelocationIsRejectedAndCatalogReopens() async throws {
        let (f,root,raw,jpeg) = try makeFixture(); defer { try? f.tearDownWithError() }
        let service = RawJpegPairing(), frozen = try await service.prepare(rawID:raw.id,jpegID:jpeg.id,catalog:f.catalog)
        let moved = f.target.appendingPathComponent("relocated"); try FileManager.default.moveItem(at:f.source,to:moved)
        _ = try await RootRelocator().relocate(root,to:moved,catalog:f.catalog)
        do { _ = try await service.apply([frozen],catalog:f.catalog); XCTFail("root moved after preview") } catch { }
        XCTAssertTrue(try f.catalog.pairs().isEmpty)
        let fresh = try await service.prepare(rawID:raw.id,jpegID:jpeg.id,catalog:f.catalog)
        _ = try await service.apply([fresh],catalog:f.catalog)
        let expected = try f.catalog.pairs(), file = f.catalog.fileURL
        f.catalog = nil; f.catalog = try CatalogStore(fileURL:file)
        XCTAssertEqual(try f.catalog.pairs(),expected)
    }
    func testFlatCopyDoesNotCreatePairCandidatesAcrossOriginalDirectories() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let a = f.source.appendingPathComponent("a"), b = f.source.appendingPathComponent("b")
        try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true); try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:MoreRAWTests.sample("leica_m8_8bit_uncompressed.DNG"),to:a.appendingPathComponent("A.DNG"))
        try f.image(b.appendingPathComponent("A.jpg"))
        let plan = try await f.plan(), completed = await CopyImporter().run(plan,catalog:f.catalog) { _ in }
        XCTAssertEqual(completed.state,"completed")
        let found = try await RawJpegPairing().detect(catalog:f.catalog)
        XCTAssertEqual(found.count,1); XCTAssertTrue(found.first?.issue?.contains("复制前") == true)
        XCTAssertTrue(try f.catalog.pairs().isEmpty)
        let backup = f.target.appendingPathComponent("origin.sqlite"); try f.catalog.backup(to:backup)
        let restored = try CatalogStore.restore(from:backup,to:f.target.appendingPathComponent("origin-restore"))
        let again = try await RawJpegPairing().detect(catalog:restored)
        XCTAssertEqual(again.first?.issue,found.first?.issue)
    }
    func testTwoReferenceImportsDuplicateAndCopyFailureRecoveryRequireExplicitPairConfirmation() async throws {
        let f = ImportTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let sample = try MoreRAWTests.sample("leica_m8_8bit_uncompressed.DNG")
        try FileManager.default.copyItem(at:sample,to:f.source.appendingPathComponent("A.DNG")); try f.image(f.source.appendingPathComponent("A.jpg"))
        let importer = ReferenceImporter(), service = RawJpegPairing()
        let preview = try await importer.preview(source:f.source,includeSubfolders:false,catalog:f.catalog)
        let first = await importer.add(source:f.source,candidates:preview.filter { $0.url.pathExtension == "DNG" },collection:nil,catalog:f.catalog)
        let noPair = try await service.detect(catalog:f.catalog)
        XCTAssertEqual(first.indexed,1); XCTAssertTrue(noPair.isEmpty)
        let second = await importer.add(source:f.source,candidates:preview.filter { $0.url.pathExtension == "jpg" },collection:nil,catalog:f.catalog)
        XCTAssertEqual(second.indexed,1)
        let found = try await service.detect(catalog:f.catalog,within:second.sourceIDs)
        XCTAssertEqual(found.count,1); XCTAssertTrue(try f.catalog.pairs().isEmpty,"import grouping is not association")
        let duplicate = await importer.add(source:f.source,candidates:preview,collection:nil,catalog:f.catalog)
        XCTAssertEqual(duplicate.indexed,0); XCTAssertEqual(duplicate.sourceIDs.count,2)
        // Independent copy target, same confirmed companion rule, interrupted after first index.
        var plan = try await f.plan(); plan.pairAfterImport = true
        let interrupted = await CopyImporter(checkpoint: { if $0 == "indexed" { throw LRCError("injected after index") } }).run(plan,catalog:f.catalog) { _ in }
        XCTAssertEqual(interrupted.state,"needsReview"); XCTAssertTrue(try f.catalog.pairs().isEmpty)
        var saved = try XCTUnwrap(CopyImporter.savedPlans(catalog:f.catalog).first); XCTAssertTrue(saved.pairAfterImport)
        for i in saved.groups.indices where saved.groups[i].state == "needsReview" { saved.groups[i].state = "planned" }
        let resumed = await CopyImporter().run(saved,catalog:f.catalog) { _ in }
        XCTAssertEqual(resumed.state,"completed",resumed.groups.compactMap(\.diagnostic).joined(separator:";"))
        XCTAssertTrue(try f.catalog.pairs().isEmpty)
        let all = try await service.detect(catalog:f.catalog); XCTAssertEqual(all.count,2,"no cross-root pair")
        let copied = try XCTUnwrap(all.first { $0.sources[0].rootID != found[0].sources[0].rootID })
        let raw = try XCTUnwrap(copied.sources.first { $0.kind == "RAW" }), jpeg = try XCTUnwrap(copied.sources.first { $0.kind == "JPEG" })
        let proposal = try await service.prepare(rawID:raw.id,jpegID:jpeg.id,catalog:f.catalog)
        _ = try await service.apply([proposal],catalog:f.catalog)
        XCTAssertEqual(try f.catalog.pairs().count,1)
        _ = await CopyImporter().run(resumed,catalog:f.catalog) { _ in }; XCTAssertEqual(try f.catalog.pairs().count,1)
        let data = try await f.catalog.database.read { try Data.fetchOne($0,sql:"SELECT payload FROM importPlan WHERE id=?",arguments:[saved.id]) }
        var unsupported = saved; unsupported.version = 99
        _ = await CopyImporter().run(unsupported,catalog:f.catalog) { _ in }
        let preserved = try await f.catalog.database.read { try Data.fetchOne($0,sql:"SELECT payload FROM importPlan WHERE id=?",arguments:[saved.id]) }
        XCTAssertEqual(preserved,data,"old plans refused without rewriting")
    }
}

extension RawJpegPairTests {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<240 { if condition() { return }; try await Task.sleep(for:.milliseconds(25)) }
        XCTFail("timed out waiting for paired preview")
    }
    @MainActor func testJointPairStacksSmartCollectionsFrozenExportsAndCaches() async throws {
        let (f,root,raw,jpeg) = try makeFixture(); defer { try? f.tearDownWithError() }
        let pipeline = ImagePipeline()
        var a = try await pipeline.baseline(ImageRequest(photo:raw,root:root,recipe:nil))
        var b = try await pipeline.baseline(ImageRequest(photo:jpeg,root:root,recipe:nil))
        a.exposure = 0.6; b.exposure = -0.4
        a.develop.pointColors = [PointColor(lightness:0.5,chroma:0.1,hue:40,hueShift:20)]
        try f.catalog.saveRecipe(id:raw.id,recipe:a); try f.catalog.saveRecipe(id:jpeg.id,recipe:b)
        try f.catalog.collection(name:"同次拍摄",id:"c"); try f.catalog.membership(ids:[raw.id,jpeg.id],collection:"c",add:true)
        let copies = try f.catalog.createVirtualCopies(ids:[raw.id,jpeg.id]), ids = Set([raw.id,jpeg.id]+copies.map(\.id))
        let rules = SmartRules(source:"collection:c",conditions:[SmartRule(field:.rating,op:.atLeast,value:"0")])
        let smart = try PhotoCollection(id:"smart",name:"配对智能集合",rules:JSONEncoder().encode(rules))
        _ = try f.catalog.replaceSmartCollection(id:smart.id,with:smart)
        _ = try f.catalog.changeStacks(.group(top:raw.id,members:[jpeg.id]+copies.map(\.id)))
        let model = AppModel(); model.catalog = f.catalog; try model.reload()
        model.setScope("collection:smart"); model.choose([raw.id],active:raw.id)
        let proposal = try await model.pairing.prepare(rawID:raw.sourceKey,jpegID:jpeg.sourceKey,catalog:f.catalog)
        let applied = await model.applyPairs([proposal]); XCTAssertTrue(applied)
        model.undo.removeAllActions()
        XCTAssertEqual(model.resultCount,4); XCTAssertEqual(model.visibleCount,1); XCTAssertEqual(model.selection,[raw.id])
        model.selectStackMembers(); XCTAssertEqual(model.selection,ids)
        let before = try f.catalog.stacks(), pair = try XCTUnwrap(f.catalog.pairs().first)
        model.undo.beginUndoGrouping(); model.unlinkPair(pair.id); model.undo.endUndoGrouping()
        XCTAssertTrue(try f.catalog.pairs().isEmpty); XCTAssertEqual(try f.catalog.stacks(),before)
        model.undo.undo(); XCTAssertEqual(try f.catalog.pairs(),[pair]); model.undo.redo(); XCTAssertTrue(try f.catalog.pairs().isEmpty)
        _ = try f.catalog.restorePairs([pair]); try model.reload()
        model.selectAllResults(); XCTAssertEqual(model.selection,ids)
        let photos = try model.exportSelection()
        let collisions = try ExportNamingPlanner.preview(photos:photos,options:ExportOptions(format:.png),directory:f.target)
        XCTAssertTrue(collisions.allSatisfy { !$0.errors.isEmpty },"RAW/JPEG same basename must report conflicts BEFORE enqueue")
        var options = ExportOptions(format:.tiff,longEdge:128); options.naming.sequence = true
        let names = try ExportNamingPlanner.preview(photos:photos,options:options,directory:f.target)
        let plans = try model.prepareExport(options:options,photos:photos,names:names,directory:f.target)
        var frozen = [ExportSnapshot]()
        for plan in plans { frozen.append(try await pipeline.freezeExport(plan)) }
        XCTAssertEqual(Set(frozen.map { $0.request.photo.id }),ids)
        _ = try f.catalog.restorePairs([]); _ = try f.catalog.changeStacks(.ungroup(ids))
        _ = try f.catalog.setVersionDeletion([jpeg.id:true])
        let reports = await ExportService(pipeline:pipeline).run(frozen,catalog:f.catalog,progress:{_ in})
        XCTAssertEqual(reports.filter { $0.hasPrefix("成功") }.count,4,"\(reports)")
        let current = try XCTUnwrap(f.catalog.photo(raw.id))
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self,from:XCTUnwrap(current.recipe)),a)
        let thumb = ThumbnailService(), rawThumb = try await thumb.image(photo:current,root:root)
        let jpegCopy = try XCTUnwrap(copies.first { $0.sourceKey == jpeg.sourceKey })
        let jpegThumb = try await thumb.image(photo:jpegCopy,root:root)
        XCTAssertNotEqual(rawThumb.width,jpegThumb.width,"separate physical formats and native dimensions")
        XCTAssertNotEqual(ThumbnailService.key(photo:current,edge:320),ThumbnailService.key(photo:jpegCopy,edge:320))
        // Underlying collection removal still excludes a held stack member.
        model.scope = "collection:smart"; model.holdFilterResults = true; model.filterChanged()
        try f.catalog.membership(ids:[jpegCopy.id],collection:"c",add:false); try model.reload()
        XCTAssertFalse(try f.catalog.allResultIDs(model.query).contains(jpegCopy.id))
        model.choose([],active:nil); model.catalog = nil
    }
    @MainActor func testLateResultsCannotCrossRawJpegPartnerSources() async throws {
        let (f,root,raw,jpeg) = try makeFixture(); defer { try? f.tearDownWithError() }
        let service = RawJpegPairing(), proposal = try await service.prepare(rawID:raw.id,jpegID:jpeg.id,catalog:f.catalog)
        _ = try await service.apply([proposal],catalog:f.catalog)
        let context = CIContext(), bounds = CGRect(x:0,y:0,width:2,height:2)
        let red = try XCTUnwrap(context.createCGImage(CIImage(color:.red).cropped(to:bounds),from:bounds))
        let blue = try XCTUnwrap(context.createCGImage(CIImage(color:.blue).cropped(to:bounds),from:bounds))
        var began = false
        let m = AppModel(previewRenderer:{ request,_,_ in
            let first = request.photo.sourceKey == raw.sourceKey
            if first { began = true; try? await Task.sleep(for:.milliseconds(160)) }
            return RenderedImage(image:first ? red : blue,fullSize:bounds.size,orientedSourceSize:bounds.size,histogram:nil,elapsed:0)
        })
        m.catalog = f.catalog; try m.reload(); m.choose([raw.id],active:raw.id)
        try await wait { began }; m.choose([jpeg.id],active:jpeg.id)
        try await wait { m.previewCurrent && m.image === blue }
        try await Task.sleep(for:.milliseconds(200)); XCTAssertTrue(m.image === blue); XCTAssertEqual(m.activeID,jpeg.id)
        let thumbs = ThumbnailService { request,_ in if request.photo.sourceKey == raw.sourceKey { try? await Task.sleep(for:.milliseconds(160)); return red }; return blue }
        let item = PhotoItem(); _ = item.view
        item.configure(photo:raw,root:root,service:thumbs,film:false,paired:true)
        try await Task.sleep(for:.milliseconds(25)); item.configure(photo:jpeg,root:root,service:thumbs,film:false,paired:true)
        try await wait { item.displayedImage != nil }; try await Task.sleep(for:.milliseconds(200))
        let image = try XCTUnwrap(item.displayedImage?.cgImage(forProposedRect:nil,context:nil,hints:nil))
        var pixel = [UInt8](repeating:0,count:16)
        context.render(CIImage(cgImage:image),toBitmap:&pixel,rowBytes:8,bounds:bounds,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        XCTAssertGreaterThan(pixel[2],pixel[0])
        item.prepareForReuse(); m.choose([],active:nil); m.catalog = nil
    }
    @MainActor func testNativePairWindowAndCompareAtBothSizes() async throws {
        let (f,root,raw,jpeg) = try makeFixture()
        let keep = ProcessInfo.processInfo.environment["PHOSDECK_PAIR_UI_KEEP"] == "1"
        defer { if keep { f.catalog = nil } else { try? f.tearDownWithError() } }
        let pipeline = ImagePipeline()
        try f.catalog.saveRecipe(id:raw.id,recipe:await pipeline.baseline(ImageRequest(photo:raw,root:root,recipe:nil)))
        try f.catalog.saveRecipe(id:jpeg.id,recipe:await pipeline.baseline(ImageRequest(photo:jpeg,root:root,recipe:nil)))
        _ = try f.catalog.createVirtualCopies(ids:[raw.id,jpeg.id])
        let m = AppModel(); m.catalog = f.catalog; try m.reload(); m.choose([raw.id],active:raw.id)
        let proposal = try await m.pairing.prepare(rawID:raw.id,jpegID:jpeg.id,catalog:f.catalog)
        let applied = await m.applyPairs([proposal]); XCTAssertTrue(applied)
        m.comparePartner(jpeg.id)
        try await wait { m.comparison?.reference.image != nil && m.comparison?.candidate.image != nil }
        XCTAssertEqual(m.comparison?.reference.photo?.sourceKey,raw.id); XCTAssertEqual(m.comparison?.candidate.photo?.sourceKey,jpeg.id)
        let defaultsName = "pairs-ui-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName:defaultsName))
        defer { defaults.removePersistentDomain(forName:defaultsName) }
        let workspace = NSHostingView(rootView:WorkspaceView(model:m).defaultAppStorage(defaults))
        let w = NSWindow(contentRect:CGRect(x:80,y:60,width:1280,height:800),styleMask:[.titled,.closable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        w.isReleasedWhenClosed = false; w.title = "RAW JPEG 合成验证 — Phosdeck"; w.contentView = workspace; w.makeKeyAndOrderFront(nil)
        defer { w.orderOut(nil); w.contentView = nil; m.choose([],active:nil); m.catalog = nil }
        for size in [CGSize(width:1440,height:900),CGSize(width:1280,height:800)] {
            w.setContentSize(size); try await Task.sleep(for:.milliseconds(350)); workspace.layoutSubtreeIfNeeded()
            XCTAssertEqual(workspace.bounds.size,size)
            if let bitmap = workspace.bitmapImageRepForCachingDisplay(in:workspace.bounds) {
                workspace.cacheDisplay(in:workspace.bounds,to:bitmap)
                if let data = bitmap.representation(using:.png,properties:[:]) { let a = XCTAttachment(data:data,uniformTypeIdentifier:"public.png"); a.name = "paired-compare-\(Int(size.width))"; a.lifetime = .keepAlways; add(a) }
            }
        }
        m.endComparison(); m.editMode = false; m.singleView = false; m.undo.removeAllActions()
        let pair = try XCTUnwrap(f.catalog.pairs().first); m.unlinkPair(pair.id); m.undo.removeAllActions()
        if keep { print("PAIR_UI_SYNTHETIC_CATALOG=\(f.catalog.fileURL.path)") }
    }
}
