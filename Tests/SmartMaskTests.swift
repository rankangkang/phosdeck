import XCTest
import CoreImage
import ImageIO
import SwiftUI
@testable import Phosdeck

final class SmartMaskTests: XCTestCase {
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0,
            baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func raster(_ recipe: EditRecipe, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> SmartMaskRaster {
        SmartMaskRaster(source: SmartMaskSource(recipe: recipe, size: CGSize(width: 4, height: 4)), model: "synthetic-test",
            base: try SmartMaskTile(values: [1,0,0.25,0.75], width: 2, height: 2, region: region))
    }
    func testLogitResamplingKeepsZeroCrossingsAndReplicatesBorders() throws {
        let region = CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        let logits = SmartMaskField(values: [-8, 2, -8, 2], width: 2, height: 2, region: region)
        let resized = try logits.resampled(width: 8, height: 4)
        XCTAssertEqual(resized.region, region)
        let expected: [Float] = [-8, -8, -6.75, -4.25, -1.75, 0.75, 2, 2]
        for y in 0..<4 { for x in 0..<8 { XCTAssertEqual(resized.values[y * 8 + x], expected[x], accuracy: 0.00001) } }
        XCTAssertLessThan(resized.values[4], 0, "early binarization would incorrectly select this side of the signed zero crossing")
        let single = SmartMaskField(values: [0.25], width: 1, height: 1, region: region)
        XCTAssertEqual(try single.resampled(width: 3, height: 5).values, [Float](repeating: 0.25, count: 15))
        XCTAssertThrowsError(try logits.resampled(width: 1025, height: 1025))
        XCTAssertThrowsError(try logits.resampled(width: 0, height: 1))
        let tall = SmartMaskField(values: [Float](repeating: 1, count: 2048), width: 1, height: 2048, region: region)
        XCTAssertThrowsError(try tall.resampled(width: 1024, height: 1), "the intermediate horizontal plane must also stay within the pixel budget")
        XCTAssertThrowsError(try SmartMaskField(values: [.nan], width: 1, height: 1, region: region).resampled(width: 1, height: 1))
    }
    func testUInt16CoverageRoundTripOrientationPatchAndCorruption() throws {
        var value = try raster(recipe(), region: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        func pixel(_ x: Int, _ y: Int) throws -> Float {
            let image = try value.image(extent: CGRect(x: 0, y: 0, width: 4, height: 4))
            var rgba = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &rgba, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return rgba[0]
        }
        XCTAssertEqual(try pixel(0, 3), 1, accuracy: 0.00002, "top row maps into the upper source ROI")
        XCTAssertEqual(try pixel(0, 2), 0.25, accuracy: 0.00002)
        XCTAssertEqual(try pixel(0, 0), 0, accuracy: 0.00002)
        value.facePatch = try SmartMaskTile(values: [0], width: 1, height: 1, region: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(try pixel(0, 3), 0, accuracy: 0.00002, "zero patch replaces, rather than adds to, coarse coverage")
        let encoded = try JSONEncoder().encode(value)
        let reopened = try JSONDecoder().decode(SmartMaskRaster.self, from: encoded)
        XCTAssertEqual(value, reopened)
        try reopened.validate()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var base = try XCTUnwrap(json["base"] as? [String: Any])
        base["payload"] = Data([1,2,3,4]).base64EncodedString(); json["base"] = base
        let corrupt = try JSONDecoder().decode(SmartMaskRaster.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try corrupt.validate(), "cached pixels must not hide a corrupt compressed payload")
        base["width"] = Int.max; base["height"] = Int.max; json["base"] = base
        let oversize = try JSONDecoder().decode(SmartMaskRaster.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try oversize.validate(), "reject decompression dimensions before allocating")
    }
    func testRecipeSourceBoundaryPresetAndSavedCoverage() throws {
        var original = recipe(), component = MaskComponent(tool: .object)
        component.raster = try raster(original)
        original.localAdjustments = [LocalAdjustment(components: [component])]
        original.schemaVersion = 3; original.maskVersion = 3
        try original.validate()
        let saved = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: saved), original)
        var mismatch = original; mismatch.sourceDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try mismatch.validate())
        mismatch = original; mismatch.rawDetails.lensCorrection = true
        XCTAssertThrowsError(try mismatch.validate())
        var target = recipe(); target.sourceDigest = String(repeating: "b", count: 64)
        let result = try target.applyingPreset(original, options: RecipePasteOptions(), amount: 1)
        XCTAssertTrue(result.localAdjustments.isEmpty, "AI coverage cannot be applied to another source")
        let sameSource = try recipe().applyingPreset(original, options: RecipePasteOptions(), amount: 1)
        XCTAssertEqual(sameSource.localAdjustments.count, 1, "same-source versions can reuse fixed results")
        XCTAssertEqual(sameSource.maskVersion, 3)
    }
    func testCachedTileKeepsSerializedIdentityAndRejectsChangedDimensions() throws {
        let tile = try raster(recipe()).base
        let bytes = try tile.pixels()
        let encoded = try JSONEncoder().encode(tile)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["width", "height", "region", "checksum", "payload"])
        let reopened = try JSONDecoder().decode(SmartMaskTile.self, from: encoded)
        XCTAssertEqual(tile, reopened)
        XCTAssertEqual(try reopened.pixels(), bytes)
        json["width"] = 1; json["height"] = 1
        let wrongSize = try JSONDecoder().decode(SmartMaskTile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try wrongSize.validate(), "A cached payload must still match its decoded dimensions")
        XCTAssertEqual(try tile.pixels(), bytes)
    }
    func testFieldSamplingAndRasterGeometryAcrossRotationsAndFlips() throws {
        let field = SmartMaskField(values: [1,0,0.25,0.75], width: 2, height: 2, region: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertEqual(field.sample(field.point(x: 0, y: 0)), 1, accuracy: 0.00001)
        XCTAssertEqual(field.sample(field.point(x: 0, y: 1)), 0.25, accuracy: 0.00001)
        XCTAssertEqual(field.sample(CGPoint(x: 0.1, y: 0.5)), 0)
        let size = CGSize(width: 100, height: 80), context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        let tile = try SmartMaskTile(values: [1], width: 1, height: 1, region: CGRect(x: 0.3, y: 0.4, width: 0.3, height: 0.3))
        let raster = SmartMaskRaster(source: SmartMaskSource(recipe: recipe(), size: size), model: "synthetic-geometry", base: tile)
        for turns in 0...3 { for flip in [(false,false),(true,false),(false,true),(true,true)] {
            var r = recipe(); r.quarterTurns = turns; r.straightenDegrees = 9; r.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            r.flipHorizontal = flip.0; r.flipVertical = flip.1
            let mapping = MaskGeometry.mapping(size: size, recipe: r)
            let image = try ImagePipeline.geometry(raster.image(extent: CGRect(origin: .zero, size: size)), recipe: r)
            let p = CGPoint(x: 45, y: 44).applying(mapping.transform)
            var pixel = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: Int(p.x), y: Int(p.y), width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            XCTAssertEqual(pixel[0], 1, accuracy: 0.0001)
        } }
    }
    @MainActor func testCreationOneUndoReopenBackupFrozenDataAndCancellation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-mask-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        defer { try? catalog.database.close() }
        let root = try catalog.addRoot(url: directory.appendingPathComponent("synthetic"), bookmark: Data())
        let photo = Photo(id: "smart", rootID: root.id, relativePath: "synthetic.ARW", identity: Data(), identityKey: "smart-test", width: 4, height: 4)
        try catalog.index(photo)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        model.catalog = catalog; model.activeID = photo.id; model.activePhoto = photo; model.roots = [root]
        model.recipe = recipe(); model.canEdit = true; model.dirty = true; XCTAssertTrue(model.commitRecipe())
        model.editMode = true; model.maskMode = true; model.undo.removeAllActions(); model.undo.groupsByEvent = false
        var first = try raster(model.recipe!), second = first
        first.parts = [.faceSkin]; first.instance = first.base
        second.parts = [.bodySkin]; second.instance = second.base
        let request = ImageRequest(photo: photo, root: root, recipe: model.recipe)
        var session = SmartMaskSession(photoID: photo.id, catalogPath: catalog.fileURL.path, request: request, source: first.source, target: .newMask)
        session.parts = [.faceSkin:first, .bodySkin:second]; session.preview = try SmartMaskEngine.union([first,second])
        var inspected = first
        inspected.parts = [.hair]
        inspected.base = try SmartMaskTile(values: [0,1,1,0], width: 2, height: 2, region: first.base.region)
        session.parts?[.hair] = inspected; session.ready = true; session.workflow = .people
        model.smartMaskSession = session
        let savedBeforeInspection = try XCTUnwrap(catalog.photo(photo.id)?.recipe)
        model.inspectSmartMask(.part(.hair), hovering: true, sessionID: session.id)
        XCTAssertEqual(model.smartMaskSession?.displayedRaster, inspected)
        XCTAssertEqual(model.smartMaskPreviewGroup?.components.last?.raster, inspected)
        XCTAssertEqual(model.smartMaskSession?.selectedParts, [.faceSkin, .bodySkin])
        XCTAssertEqual(model.smartMaskSession?.creationCount, 1)
        XCTAssertFalse(model.dirty)
        XCTAssertFalse(model.undo.canUndo, "inspection does not create an undo step")
        XCTAssertEqual(try catalog.photo(photo.id)?.recipe, savedBeforeInspection)
        model.undo.beginUndoGrouping(); model.createSmartMask(); model.undo.endUndoGrouping()
        let edited = try XCTUnwrap(model.recipe)
        XCTAssertEqual(edited.localAdjustments.count, 1); XCTAssertEqual(edited.localAdjustments[0].components.count, 2)
        XCTAssertEqual(edited.localAdjustments[0].components.map(\.operation), [.replace,.add])
        XCTAssertEqual(edited.localAdjustments[0].components.flatMap { $0.raster?.parts ?? [] }, [.faceSkin, .bodySkin], "creation uses selected parts while another part is inspected")
        XCTAssertNil(session.inspection.target)
        XCTAssertNil(model.smartMaskSession)
        model.undo.undo(); XCTAssertTrue(model.recipe!.localAdjustments.isEmpty)
        model.undo.redo(); XCTAssertEqual(model.recipe, edited)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo(photo.id)?.recipe)), edited)
        try catalog.createSnapshot(photoID: photo.id, title: "smart coverage")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.snapshots(photoID: photo.id).first).recipe), edited)
        let manifest = directory.appendingPathComponent("manifest.json"); try catalog.exportManifest(to: manifest)
        let manifestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String:Any])
        let record = try XCTUnwrap((manifestObject["photos"] as? [[String:Any]])?.first)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(record["recipe"]))), edited)
        let backup = directory.appendingPathComponent("backup.sqlite"); try catalog.backup(to: backup)
        let restored = try CatalogStore.restore(from: backup, to: directory.appendingPathComponent("restored"))
        defer { try? restored.database.close() }
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(restored.photo(photo.id)?.recipe)), edited)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(restored.snapshots(photoID: photo.id).first).recipe), edited)
        let frozen = ExportSnapshot(id: "frozen-smart", request: ImageRequest(photo: photo, root: root, recipe: edited),
            destination: directory.appendingPathComponent("out.tif"), targetBookmark: Data(), options: ExportOptions())
        let frozenData = try JSONEncoder().encode(frozen)
        model.smartMaskSession = session
        let generation = model.smartMaskGeneration
        XCTAssertTrue(model.acceptSmartMask(id: session.id, token: generation))
        model.cancelSmartMask()
        XCTAssertFalse(model.acceptSmartMask(id: session.id, token: generation), "late results cannot write after cancellation")
        model.smartMaskSession = session; model.activeID = "another-photo"
        XCTAssertNil(model.smartMaskSession, "changing photos cancels pending analysis")
        let decoded = try JSONDecoder().decode(ExportSnapshot.self, from: frozenData)
        XCTAssertEqual(decoded.request.recipe, edited, "frozen coverage survives subsequent editor changes")
        let missing = SmartMaskSession(photoID: photo.id, catalogPath: catalog.fileURL.path, request: request, source: first.source,
            target: .replace(UUID(), UUID()))
        XCTAssertFalse(missing.acceptsRecipe(edited), "a deleted target cannot accept a late result")
        model.activeID = photo.id; model.activePhoto = photo; model.recipe = edited; model.canEdit = true
        var whole = first; whole.parts = []; whole.instance = nil
        session.workflow = .people; session.wholePerson = true; session.analyzingParts = true
        session.preview = whole; session.instance = whole; session.separate = true
        XCTAssertEqual(session.creationCount, 1)
        model.smartMaskSession = session
        model.undo.beginUndoGrouping(); model.createSmartMask(); model.undo.endUndoGrouping()
        XCTAssertEqual(model.recipe?.localAdjustments.count, edited.localAdjustments.count + 1)
        XCTAssertEqual(model.recipe?.localAdjustments.last?.components.count, 1, "whole person does not save the previously selected parts separately")
        XCTAssertEqual(model.recipe?.localAdjustments.last?.components.first?.raster, whole)
        model.undo.undo(); XCTAssertEqual(model.recipe, edited)
    }
    func testOptionalModelCapabilitiesAndPartialBundleCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-model-resources-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source"), target = directory.appendingPathComponent("target")
        let models = source.appendingPathComponent("build/smart-mask-validation/models")
        let resources = target.appendingPathComponent("Review.app/Contents/Resources")
        let destination = resources.appendingPathComponent("SmartMaskModels")
        for folder in [models, source.appendingPathComponent("Packages/SmartMaskRuntime"), source.appendingPathComponent("docs/references"), destination] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("runtime license".utf8).write(to: source.appendingPathComponent("Packages/SmartMaskRuntime/LICENSE"))
        try Data("research notice".utf8).write(to: source.appendingPathComponent("docs/references/smart-mask-research-NOTICE.txt"))
        let sentinel = destination.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sentinel)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func copy(_ configuration: String = "Debug") throws -> SmartMaskModels {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [repository.appendingPathComponent("scripts/copy-smart-mask-models.sh").path]
            process.environment = ProcessInfo.processInfo.environment.merging(["SRCROOT": source.path, "TARGET_BUILD_DIR": target.path,
                "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Review.app/Contents/Resources", "CONFIGURATION": configuration]) { _, new in new }
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            XCTAssertEqual(try Data(contentsOf: resources.appendingPathComponent("SmartMaskRuntime-LICENSE.txt")), Data("runtime license".utf8))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
            return SmartMaskModels(directory: destination)
        }
        let empty = try copy()
        XCTAssertFalse(empty.hasParts); XCTAssertNil(empty.objectDirectory)
        for name in SmartMaskModels.objectNames {
            try FileManager.default.createDirectory(at: models.appendingPathComponent(name + ".mlmodelc"), withIntermediateDirectories: true)
        }
        let sam = try copy()
        XCTAssertNotNil(sam.objectDirectory); XCTAssertNil(sam.bodyURL); XCTAssertNil(sam.faceURL)
        try FileManager.default.removeItem(at: models.appendingPathComponent(SmartMaskModels.objectNames[1] + ".mlmodelc"))
        try Data("selfie".utf8).write(to: models.appendingPathComponent("selfie_multiclass_256x256.tflite"))
        let body = try copy()
        XCTAssertNil(body.objectDirectory, "partial SAM removes the previously copied whole SAM group")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SmartMaskModels.objectNames[0] + ".mlmodelc").path))
        XCTAssertTrue(body.supports(.faceSkin)); XCTAssertTrue(body.supports(.bodySkin)); XCTAssertFalse(body.supports(.eyes))
        try FileManager.default.removeItem(at: models.appendingPathComponent("selfie_multiclass_256x256.tflite"))
        try FileManager.default.createDirectory(at: models.appendingPathComponent("FaceParsing.mlmodelc"), withIntermediateDirectories: true)
        let face = try copy()
        XCTAssertNotNil(face.faceURL); XCTAssertNil(face.bodyURL)
        XCTAssertTrue(face.supports(.faceSkin)); XCTAssertTrue(face.supports(.eyes)); XCTAssertFalse(face.supports(.bodySkin))
        let release = try copy("Release")
        XCTAssertFalse(release.hasParts); XCTAssertNil(release.objectDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("NOTICE.txt").path))
        try Data("wrong kind".utf8).write(to: destination.appendingPathComponent("FaceParsing.mlmodelc"))
        XCTAssertNil(SmartMaskModels(directory: destination).faceURL, "a regular file is not a compiled model directory")
    }
    @MainActor func testTransientInspectionOwnershipFocusCancellationAndCount() throws {
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        let root = StorageRoot(id: "root", path: "/synthetic", bookmark: Data(), label: "synthetic")
        let photo = Photo(id: "smart", rootID: root.id, relativePath: "synthetic.png", identity: Data(), identityKey: "smart-test", width: 4, height: 4)
        let recipe = recipe(), draft = try raster(recipe)
        var other = draft; other.base = try SmartMaskTile(values: [0,1,1,0], width: 2, height: 2, region: draft.base.region)
        var session = SmartMaskSession(photoID: photo.id, catalogPath: "/synthetic", request: ImageRequest(photo: photo, root: root, recipe: recipe), source: draft.source, target: .newMask)
        session.ready = true; session.workflow = .people; session.preview = draft; session.instance = draft
        session.people = [SmartMaskPerson(raster: draft, bounds: draft.base.region, thumbnail: nil), SmartMaskPerson(raster: other, bounds: other.base.region, thumbnail: nil)]
        session.parts = [.faceSkin: draft, .bodySkin: other]; session.selectedPeople = [0]
        model.activeID = photo.id; model.smartMaskSession = session
        model.focusSmartMask(.part(.bodySkin), sessionID: session.id)
        model.inspectSmartMask(.person(0), hovering: true, sessionID: session.id)
        model.inspectSmartMask(.person(1), hovering: true, sessionID: session.id)
        model.inspectSmartMask(.person(0), hovering: false, sessionID: session.id)
        XCTAssertEqual(session.inspection.target, .person(1), "a late exit does not clear the next hovered target")
        XCTAssertEqual(model.smartMaskSession?.displayedRaster, other)
        XCTAssertEqual(model.smartMaskSession?.selectedPeople, [0])
        XCTAssertEqual(model.smartMaskSession?.preview, draft)
        XCTAssertTrue(model.smartMaskSession!.canCreate)
        model.inspectSmartMask(.person(1), hovering: false, sessionID: session.id)
        XCTAssertEqual(session.inspection.target, .part(.bodySkin), "leaving pointer inspection restores focused inspection")
        model.focusSmartMask(nil, sessionID: session.id)
        XCTAssertEqual(model.smartMaskSession?.displayedRaster, draft)
        session.separate = true; model.smartMaskSession = session
        XCTAssertEqual(session.creationCount, 2)
        session.wholePerson = true; XCTAssertEqual(session.creationCount, 1)
        model.inspectSmartMask(.person(1), hovering: true, sessionID: session.id)
        model.activeID = "different-photo"
        XCTAssertNil(model.smartMaskSession); XCTAssertNil(session.inspection.target)
        model.smartMaskSession = SmartMaskSession(photoID: photo.id, catalogPath: "/synthetic", request: session.request, source: draft.source, target: .newMask)
        model.inspectSmartMask(.person(1), hovering: true, sessionID: session.id)
        XCTAssertNil(model.smartMaskSession?.inspection.target, "stale session events cannot inspect the next session")
    }
    func testCandidateThumbnailUsesCoverageWithoutModels() async throws {
        let engine = SmartMaskEngine()
        let raster = try raster(recipe())
        let image = try await engine.previewThumbnail(raster)
        let thumbnail = try XCTUnwrap(image)
        XCTAssertEqual(thumbnail.width, 120); XCTAssertEqual(thumbnail.height, 120)
        let values = try SmartMaskInput.rgba(thumbnail, side: 2)
        XCTAssertGreaterThan(values[0], values[4], "actual coverage differences remain visible in the thumbnail")
    }
    @MainActor func testKeyboardInspectionSelectsCandidateBeforeCreatingAndKeepsNavigationLocal() throws {
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        let root = StorageRoot(id: "root", path: "/synthetic", bookmark: Data(), label: "synthetic")
        let photo = Photo(id: "smart", rootID: root.id, relativePath: "synthetic.png", identity: Data(), identityKey: "smart-test", width: 4, height: 4)
        let recipe = recipe(), draft = try raster(recipe)
        var other = draft; other.base = try SmartMaskTile(values: [0,1,1,0], width: 2, height: 2, region: draft.base.region)
        var session = SmartMaskSession(photoID: photo.id, catalogPath: "/synthetic", request: ImageRequest(photo: photo, root: root, recipe: recipe), source: draft.source, target: .newMask)
        session.ready = true; session.preview = draft
        session.candidates = [SmartMaskCandidate(raster: draft, score: 1, selectedPixels: 3), SmartMaskCandidate(raster: other, score: 0.9, selectedPixels: 2)]
        model.activeID = photo.id; model.smartMaskSession = session
        model.focusSmartMask(.candidate(1), sessionID: session.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Phosdeck"
        func key(_ text: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("\u{F703}", code: 124), model: model), "focused inspection receives the arrow key before photo navigation")
        XCTAssertEqual(model.activeID, photo.id)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\r", code: 36), model: model))
        XCTAssertEqual(model.smartMaskSession?.candidate, 1)
        XCTAssertEqual(model.smartMaskSession?.inspection.focused, .candidate(1), "selection preserves the control's keyboard focus")
        XCTAssertEqual(model.smartMaskSession?.preview, other)
        XCTAssertNotNil(model.smartMaskSession, "Return selects the focused candidate before submitting the draft")
        model.inspectSmartMask(.candidate(0), hovering: true, sessionID: session.id)
        model.smartMaskSession?.busy = true
        XCTAssertNil(model.smartMaskSession?.inspectedRaster, "old candidates are not inspectable during a new prediction")
        withExtendedLifetime(window) {}
    }
    @MainActor func testPeopleWorkflowPublishesDetectionWithoutOverlappingSessionAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-people-publish-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.png")
        try PNGFixture.data().write(to: url)
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
        defer { try? catalog.database.close() }
        let root = try catalog.addRoot(url: directory, bookmark: AccessLease.bookmark(directory, readOnly: true))
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
        try catalog.index(photo)
        let pipeline = ImagePipeline()
        let baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        model.catalog = catalog; model.activeID = photo.id; model.activePhoto = photo; model.roots = [root]
        model.recipe = baseline; model.canEdit = true; model.orientedSourceSize = CGSize(width: photo.width, height: photo.height)
        model.editMode = true; model.dirty = true; XCTAssertTrue(model.commitRecipe())
        model.undo.removeAllActions()
        let saved = try XCTUnwrap(catalog.photo(photo.id)?.recipe)
        model.beginSmartMask(workflow: .people)
        let task = try XCTUnwrap(model.smartMaskTask)
        await task.value
        let session = try XCTUnwrap(model.smartMaskSession)
        XCTAssertTrue(session.ready); XCTAssertFalse(session.busy)
        XCTAssertTrue(session.people.isEmpty); XCTAssertFalse(session.message.isEmpty)
        XCTAssertNil(model.error); XCTAssertFalse(model.undo.canUndo)
        XCTAssertEqual(try catalog.photo(photo.id)?.recipe, saved, "publishing detection does not save a mask")
        model.cancelSmartMask()
    }
    @MainActor func testPreparedPersonSwitchingReusesPartPredictions() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let models = SmartMaskModels(directory: repository.appendingPathComponent("build/smart-mask-validation/models"))
        let sample = repository.appendingPathComponent("build/smart-mask-validation/samples/02177c7b318e1d5c.jpg")
        guard models.bodyURL != nil, FileManager.default.fileExists(atPath: sample.path) else { throw XCTSkip("Prepare pinned Selfie and public two-person fixture") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-people-reuse-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        defer { try? catalog.database.close() }
        let root = try catalog.addRoot(url: sample.deletingLastPathComponent(), bookmark: AccessLease.bookmark(sample.deletingLastPathComponent(), readOnly: true))
        let photo = try ReferenceImporter.inspect(url: sample, root: root, rootURL: sample.deletingLastPathComponent())
        try catalog.index(photo)
        let pipeline = ImagePipeline(), engine = SmartMaskEngine(models: models)
        let baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        model.catalog = catalog; model.activeID = photo.id; model.activePhoto = photo; model.roots = [root]
        model.recipe = baseline; model.canEdit = true; model.orientedSourceSize = CGSize(width: photo.width, height: photo.height)
        model.editMode = true; model.dirty = true; XCTAssertTrue(model.commitRecipe())
        model.smartMaskEngine = engine; model.smartMaskPipeline = pipeline
        model.beginSmartMask(workflow: .people)
        await model.smartMaskTask?.value
        XCTAssertEqual(model.smartMaskSession?.people.count, 2)
        for index in [0, 1, 0, 1, 0] {
            let start = ContinuousClock.now
            model.selectSmartPeople([index])
            await model.smartMaskTask?.value
            XCTAssertFalse(model.smartMaskSession?.analyzingParts ?? true)
            XCTAssertNotNil(model.smartMaskSession?.parts?[.faceSkin]); XCTAssertNil(model.error)
            print("SMART-PART-SWITCH person=\(index) duration=\(start.duration(to: .now)) predictions=\(await engine.bodyPredictionCount)")
        }
        let predictions = await engine.bodyPredictionCount
        XCTAssertEqual(predictions, 2)
        model.selectAllSmartPeople()
        await model.smartMaskTask?.value
        XCTAssertEqual(model.smartMaskSession?.selectedPeople, [0, 1])
        let combined = try XCTUnwrap(model.smartMaskSession?.instance)
        for part in try XCTUnwrap(model.smartMaskSession?.parts).values { XCTAssertEqual(part.instance, combined.base) }
        model.chooseSmartPerson(0)
        await model.smartMaskTask?.value
        XCTAssertEqual(model.smartMaskSession?.selectedPeople, [1])
        model.selectAllSmartPeople()
        await model.smartMaskTask?.value
        model.selectAllSmartPeople()
        XCTAssertEqual(model.smartMaskSession?.selectedPeople, [])
        XCTAssertNil(model.smartMaskSession?.preview); XCTAssertFalse(model.smartMaskSession?.canCreate ?? true)
        let finalPredictions = await engine.bodyPredictionCount, hits = await engine.partCacheHits
        XCTAssertEqual(finalPredictions, 2); XCTAssertGreaterThanOrEqual(hits, 5)
        model.cancelSmartMask()
    }
    func testCachedPersonAnalysisRejectsChangedOriginal() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let models = SmartMaskModels(directory: repository.appendingPathComponent("build/smart-mask-validation/models"))
        guard models.bodyURL != nil else { throw XCTSkip("Prepare pinned Selfie model") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-cache-source-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.png")
        let data = try PNGFixture.data(); try data.write(to: url)
        let original = try PNGFixture.request(url), pipeline = ImagePipeline()
        let baseline = try await pipeline.baseline(original)
        let request = ImageRequest(photo: original.photo, root: original.root, recipe: baseline)
        let input = try await pipeline.smartMaskInput(request), engine = SmartMaskEngine(models: models)
        let selection = SmartMaskRaster(source: SmartMaskSource(recipe: baseline, size: CGSize(width: input.image.width, height: input.image.height)),
            model: "synthetic-person", base: try SmartMaskTile(values: [1], width: 1, height: 1, region: CGRect(x: 0, y: 0, width: 1, height: 1)))
        _ = try await engine.analyzePerson(image: input.image, selection: selection, request: request, pipeline: pipeline)
        let entries = await engine.cachedPartCount
        XCTAssertEqual(entries, 1)
        try (data + Data([0])).write(to: url)
        do {
            _ = try await engine.analyzePerson(image: input.image, selection: selection, request: request, pipeline: pipeline)
            XCTFail("a cache hit must still reject a changed source file")
        } catch is LRCError {}
        let predictions = await engine.bodyPredictionCount, hits = await engine.partCacheHits
        XCTAssertEqual(predictions, 1); XCTAssertEqual(hits, 0)
    }
    func testPartCacheSeparatesPeopleFacesInputBaselineAndSourceAndStaysBounded() throws {
        let recipe = recipe(), original = try raster(recipe)
        var other = original; other.base = try SmartMaskTile(values: [0, 1, 1, 0], width: 2, height: 2, region: original.base.region)
        let baseline = SmartMaskBaseline(recipe)
        let a = SmartMaskPartCache.Key(selection: original, baseline: baseline, inputSize: CGSize(width: 4, height: 4), face: nil)
        let b = SmartMaskPartCache.Key(selection: other, baseline: baseline, inputSize: a.inputSize, face: nil)
        let manual = SmartMaskPartCache.Key(selection: original, baseline: baseline, inputSize: a.inputSize, face: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let resized = SmartMaskPartCache.Key(selection: original, baseline: baseline, inputSize: CGSize(width: 8, height: 4), face: nil)
        let valueA = SmartMaskPersonAnalysis(parts: [.hair: original], faces: [], faceRefined: false)
        let valueB = SmartMaskPersonAnalysis(parts: [.hair: other], faces: [], faceRefined: false)
        var cache = SmartMaskPartCache(limit: 2, byteLimit: valueA.cost + valueB.cost)
        XCTAssertNil(cache.value(for: a)); cache.insert(valueA, for: a)
        XCTAssertNil(cache.value(for: b)); cache.insert(valueB, for: b)
        XCTAssertEqual(cache.value(for: a)?.parts[.hair], original)
        XCTAssertNil(cache.value(for: manual), "automatic face results cannot answer a manual face crop")
        XCTAssertNil(cache.value(for: resized), "a different model input size cannot reuse the result")
        cache.insert(valueA, for: manual)
        XCTAssertNil(cache.value(for: b), "evict the least recently used person rather than growing without limit")
        XCTAssertEqual(cache.count, 2); XCTAssertLessThanOrEqual(cache.cost, cache.byteLimit)
        var changedRecipe = recipe; changedRecipe.baselineTemperature += 1
        let changedBaseline = SmartMaskPartCache.Key(selection: original, baseline: SmartMaskBaseline(changedRecipe), inputSize: a.inputSize, face: nil)
        XCTAssertNil(cache.value(for: changedBaseline)); XCTAssertEqual(cache.count, 0)
        cache.insert(valueA, for: changedBaseline)
        var changedSource = original; changedSource.source.digest = String(repeating: "b", count: 64)
        let next = SmartMaskPartCache.Key(selection: changedSource, baseline: baseline, inputSize: a.inputSize, face: nil)
        XCTAssertNil(cache.value(for: next)); XCTAssertEqual(cache.count, 0)
        cache.insert(valueA, for: a)
        XCTAssertEqual(cache.count, 0, "a late result from an older source cannot populate the active source cache")
        var small = SmartMaskPartCache(byteLimit: valueA.cost - 1)
        XCTAssertNil(small.value(for: a)); small.insert(valueA, for: a)
        XCTAssertEqual(small.count, 0)
    }
    @MainActor func testPeopleUnionKeepsInstanceBoundaryAndIndependentFacePatches() async throws {
        let source = SmartMaskSource(recipe: recipe(), size: CGSize(width: 4, height: 4))
        let left = try SmartMaskTile(values: [1, 0, 1, 0], width: 2, height: 2, region: CGRect(x: 0, y: 0, width: 1, height: 1))
        let right = try SmartMaskTile(values: [0, 1, 0, 1], width: 2, height: 2, region: left.region)
        var a = SmartMaskRaster(source: source, model: "synthetic-person", base: try SmartMaskTile(values: [1], width: 1, height: 1, region: CGRect(x: 0, y: 0, width: 0.5, height: 1)))
        a.parts = [.faceSkin]; a.instance = left
        a.facePatch = try SmartMaskTile(values: [0], width: 1, height: 1, region: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        var b = a; b.instance = right
        b.base = try SmartMaskTile(values: [1], width: 1, height: 1, region: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        b.facePatch = try SmartMaskTile(values: [0.25], width: 1, height: 1, region: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertThrowsError(try SmartMaskEngine.union([a, b]), "the existing same-person refinement contract remains enforced")
        let engine = SmartMaskEngine(), merged = try await engine.combinePeople([a, b])
        try merged.validate()
        let patch = try SmartMaskField(XCTUnwrap(merged.facePatch))
        XCTAssertEqual(patch.sample(CGPoint(x: 0.25, y: 0.75)), 0, accuracy: 0.00003)
        XCTAssertEqual(patch.sample(CGPoint(x: 0.75, y: 0.75)), 0.25, accuracy: 0.00003, "one person's zero patch cannot erase the other person's patch")
        XCTAssertEqual(try SmartMaskField(merged.base).sample(CGPoint(x: 0.25, y: 0.25)), 1, accuracy: 0.00003)
        XCTAssertEqual(merged.parts, [.faceSkin]); XCTAssertNotNil(merged.instance)
        var wrong = b; wrong.source.size.width += 1
        do { _ = try await engine.combinePeople([a, wrong]); XCTFail("different source dimensions must be rejected") } catch {}
        let cancelled = Task { try await engine.combinePeople([a, b]) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("cancelled unions must not return a result") } catch is CancellationError {}
    }
    @MainActor func testMultiplePeopleToggleCreateByPartAndCancelAsOneEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-multiple-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        defer { try? catalog.database.close() }
        let root = try catalog.addRoot(url: directory.appendingPathComponent("synthetic"), bookmark: Data())
        let photo = Photo(id: "multiple", rootID: root.id, relativePath: "synthetic.ARW", identity: Data(), identityKey: "multiple-test", width: 4, height: 4)
        try catalog.index(photo)
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        model.catalog = catalog; model.activeID = photo.id; model.activePhoto = photo; model.roots = [root]
        model.recipe = recipe(); model.canEdit = true; model.dirty = true; XCTAssertTrue(model.commitRecipe())
        model.editMode = true; model.maskMode = true; model.undo.removeAllActions(); model.undo.groupsByEvent = false
        var a = try raster(model.recipe!), b = a
        a.model = "vision-person-instance-r1"
        b.model = a.model; b.base = try SmartMaskTile(values: [0, 1, 1, 0], width: 2, height: 2, region: a.base.region)
        let engine = SmartMaskEngine(), whole = try await engine.combinePeople([a, b])
        var session = SmartMaskSession(photoID: photo.id, catalogPath: catalog.fileURL.path,
            request: ImageRequest(photo: photo, root: root, recipe: model.recipe), source: a.source, target: .newMask)
        session.ready = true; session.workflow = .people; session.models = SmartMaskModels(directory: nil)
        session.people = [SmartMaskPerson(raster: a, bounds: a.base.region, thumbnail: nil), SmartMaskPerson(raster: b, bounds: b.base.region, thumbnail: nil)]
        session.allPeople = whole
        session.image = CIContext().createCGImage(CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4)), from: CGRect(x: 0, y: 0, width: 4, height: 4))
        model.smartMaskSession = session; model.smartMaskEngine = engine; model.smartMaskPipeline = ImagePipeline()
        model.chooseSmartPerson(0); model.chooseSmartPerson(1)
        await model.smartMaskTask?.value
        session = try XCTUnwrap(model.smartMaskSession)
        XCTAssertEqual(session.selectedPeople, [0, 1]); XCTAssertEqual(session.preview, whole)
        XCTAssertTrue(session.canCreate)
        var face = whole, body = whole
        face.parts = [.faceSkin]; face.instance = whole.base
        body.parts = [.bodySkin]; body.instance = whole.base
        session.parts = [.faceSkin: face, .bodySkin: body]; session.selectedParts = [.faceSkin, .bodySkin]
        session.wholePerson = false; session.preview = try SmartMaskEngine.union([face, body])
        model.smartMaskSession = session
        model.inspectSmartMask(.person(1), hovering: true, sessionID: session.id)
        XCTAssertEqual(model.smartMaskSession?.creationCount, 1)
        model.undo.beginUndoGrouping(); model.createSmartMask(); model.undo.endUndoGrouping()
        XCTAssertEqual(model.recipe?.localAdjustments.count, 1)
        XCTAssertEqual(model.recipe?.localAdjustments.first?.components.count, 2)
        model.undo.undo(); XCTAssertTrue(model.recipe!.localAdjustments.isEmpty)
        session.separate = true; model.smartMaskSession = session
        XCTAssertEqual(session.creationCount, 2)
        model.undo.beginUndoGrouping(); model.createSmartMask(); model.undo.endUndoGrouping()
        let created = try XCTUnwrap(model.recipe)
        XCTAssertEqual(created.localAdjustments.count, 2)
        XCTAssertEqual(created.localAdjustments.flatMap(\.components).compactMap { $0.raster?.instance }, [whole.base, whole.base])
        model.undo.undo(); XCTAssertTrue(model.recipe!.localAdjustments.isEmpty)
        model.undo.redo(); XCTAssertEqual(model.recipe, created)
        model.undo.undo()
        model.smartMaskSession = session
        model.selectSmartPeople([0]); let pending = model.smartMaskTask
        model.activeID = "another-photo"
        await pending?.value
        XCTAssertNil(model.smartMaskSession, "a late selection result cannot restore a cancelled photo session")
    }
    func testPreparedObjectAndBodyCapabilities() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/smart-mask-validation/models")
        let models = SmartMaskModels(directory: directory)
        let photo = repository.appendingPathComponent("build/smart-mask-validation/samples/02177c7b318e1d5c.jpg")
        guard models.objectDirectory != nil, models.bodyURL != nil, FileManager.default.fileExists(atPath: photo.path) else {
            throw XCTSkip("Prepare pinned SAM, Selfie and public fixtures; no FaceParsing prerequisite")
        }
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil)), 0, nil))
        var recipe = recipe(); recipe.sourceDigest = try SafeFileWriter.sha256(photo)
        let source = SmartMaskSource(recipe: recipe, size: CGSize(width: image.width, height: image.height))
        let engine = SmartMaskEngine(models: models)
        let detected = try await engine.people(image: image, source: source)
        let person = try XCTUnwrap(detected.first)
        let candidates = try await engine.select(image: image, source: source, prompts: [SmartMaskPrompt(point: MaskPoint(person.bounds.midX, person.bounds.midY), label: 1)])
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(candidates.contains { $0.selectedPixels > 0 })
        for candidate in candidates { try candidate.raster.validate(); XCTAssertNotNil(candidate.thumbnail) }
        let parts = try await engine.body(image: image, region: CGRect(x: 0, y: 0, width: 1, height: 1), selection: person.raster)
        XCTAssertFalse(parts.isEmpty)
        XCTAssertTrue(Set(parts.keys).isSubset(of: [.faceSkin, .bodySkin, .hair, .clothes]))
        for part in parts.values { try part.validate(); XCTAssertEqual(part.source, source); XCTAssertEqual(part.instance, person.raster.base) }
    }
    func testPreparedOcclusionAndFineEdgeFixtures() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent("build/smart-mask-validation/models")
        let sampleDirectory = repository.appendingPathComponent("build/smart-mask-validation/samples")
        let models = SmartMaskModels(directory: directory)
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/smart-mask-fixture.json"))) as? [String: Any])
        let samples = try XCTUnwrap(fixture["samples"] as? [[String: Any]])
        let quality = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/smart-mask-edge-checks.json"))) as? [String: Any])
        let checks = try XCTUnwrap(quality["checks"] as? [[String: Any]])
        let regions = try XCTUnwrap(quality["regions"] as? [[String: Any]])
        var measurements = [[String: Any]]()
        let ids = ["000ccf1d00f7f1cd", "003c2b6816ba9d22", "00777bbaa18dbb08", "00cd932265611688", "0c3228734c66d31b", "012fe322a5fd004c", "02177c7b318e1d5c"]
        guard models.objectDirectory != nil, models.bodyURL != nil, models.faceURL != nil,
              ids.allSatisfy({ FileManager.default.fileExists(atPath: sampleDirectory.appendingPathComponent($0 + ".jpg").path) }) else {
            throw XCTSkip("Prepare pinned models and the seven public occlusion/fine-edge fixtures")
        }
        let engine = SmartMaskEngine(models: models), pipeline = ImagePipeline()
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        func attach(_ raster: SmartMaskRaster, name: String) throws {
            try raster.validate()
            let encoded = XCTAttachment(data: try JSONEncoder().encode(raster), uniformTypeIdentifier: "public.json")
            encoded.name = name; encoded.lifetime = .keepAlways; add(encoded)
            let extent = CGRect(origin: .zero, size: raster.source.size)
            let image = try XCTUnwrap(context.createCGImage(try raster.image(extent: extent), from: extent, format: .RGBA8, colorSpace: nil))
            let png = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            let attachment = XCTAttachment(data: png as Data, uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        for id in ids {
            let sample = try XCTUnwrap(samples.first { $0["id"] as? String == id })
            let url = sampleDirectory.appendingPathComponent(id + ".jpg")
            XCTAssertEqual(try SafeFileWriter.sha256(url), sample["sha256"] as? String)
            let root = StorageRoot(id: id, path: sampleDirectory.path, bookmark: try AccessLease.bookmark(sampleDirectory, readOnly: true), label: "public-edge-fixtures")
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: sampleDirectory)
            let baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
            let request = ImageRequest(photo: photo, root: root, recipe: baseline)
            let input = try await pipeline.smartMaskInput(request)
            let source = SmartMaskSource(recipe: baseline, size: CGSize(width: photo.width, height: photo.height))
            let box = try XCTUnwrap(sample["box"] as? [Double])
            var prompts = [SmartMaskPrompt(point: MaskPoint(box[0], 1 - box[1]), label: 2), SmartMaskPrompt(point: MaskPoint(box[2], 1 - box[3]), label: 3)]
            if let positive = sample["positive"] as? [Double], let negative = sample["negative"] as? [Double] {
                prompts += [SmartMaskPrompt(point: MaskPoint(positive[0], 1 - positive[1]), label: 1), SmartMaskPrompt(point: MaskPoint(negative[0], 1 - negative[1]), label: 0)]
            }
            let candidates = try await engine.select(image: input.image, source: source, prompts: prompts)
            XCTAssertEqual(candidates.count, 3)
            var selections = ["object": try XCTUnwrap(candidates.first).raster]
            XCTAssertLessThanOrEqual(candidates[0].raster.base.pixelCount, SmartMaskTile.maxPixels)
            XCTAssertEqual(Double(candidates[0].raster.base.width) / Double(candidates[0].raster.base.height), Double(photo.width) / Double(photo.height), accuracy: 0.01)
            for (index, candidate) in candidates.enumerated() { try attach(candidate.raster, name: id + "-object-\(index)") }
            if sample["category"] as? String == "Person" {
                let people = try await engine.people(image: input.image, source: source, baseline: SmartMaskBaseline(baseline))
                let target = CGRect(x: box[0], y: 1 - box[3], width: box[2] - box[0], height: box[3] - box[1])
                let person = try XCTUnwrap(people.max { $0.bounds.intersection(target).width * $0.bounds.intersection(target).height < $1.bounds.intersection(target).width * $1.bounds.intersection(target).height })
                try attach(person.raster, name: id + "-person")
                let region = person.bounds.insetBy(dx: -person.bounds.width * 0.04, dy: -person.bounds.height * 0.04).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let coarseInput = try await pipeline.smartMaskInput(request, region: region, longEdge: 1024)
                let coarse = try await engine.body(image: coarseInput.image, region: coarseInput.region, selection: person.raster)
                for part in SmartMaskPart.allCases {
                    if let raster = coarse[part] { try attach(raster, name: id + "-coarse-" + part.rawValue) }
                }
                let result = try await engine.analyzePerson(image: input.image, selection: person.raster, request: request, pipeline: pipeline)
                for part in SmartMaskPart.allCases {
                    if let raster = result.parts[part] { selections[part.rawValue] = raster; try attach(raster, name: id + "-" + part.rawValue) }
                }
                if id == "02177c7b318e1d5c", let other = people.first(where: { $0.raster != person.raster }) {
                    let otherResult = try await engine.analyzePerson(image: input.image, selection: other.raster, request: request, pipeline: pipeline)
                    let skin = try XCTUnwrap(otherResult.parts[.faceSkin]); selections["faceSkin-other"] = skin
                    try attach(skin, name: id + "-faceSkin-other")
                }
                print("SMART-EDGE id=\(id) people=\(people.count) refined=\(result.faceRefined) parts=\(result.parts.keys.map(\.rawValue).sorted())")
            }
            for check in (checks + regions).filter({ $0["sample"] as? String == id }) {
                let selection = try XCTUnwrap(check["selection"] as? String), label = try XCTUnwrap(check["label"] as? String)
                let raster = try XCTUnwrap(selections[selection]), field = try SmartMaskField(raster.base), patch = try raster.facePatch.map(SmartMaskField.init)
                func coverage(_ x: Double, _ y: Double) -> Float {
                    let point = CGPoint(x: (x + 0.5) / Double(photo.width), y: 1 - (y + 0.5) / Double(photo.height))
                    return patch.flatMap { $0.region.contains(point) ? $0.sample(point) : nil } ?? field.sample(point)
                }
                let value: Float
                if let pixel = check["pixel"] as? [Double] { value = coverage(pixel[0], pixel[1]) }
                else {
                    let rect = try XCTUnwrap(check["rect"] as? [Int]); var sum: Float = 0
                    for y in rect[1]..<(rect[1] + rect[3]) { for x in rect[0]..<(rect[0] + rect[2]) { sum += coverage(Double(x), Double(y)) } }
                    value = sum / Float(rect[2] * rect[3])
                }
                let selected = try XCTUnwrap(check["selected"] as? Bool)
                if selected { XCTAssertGreaterThan(value, 0.9, label) } else { XCTAssertLessThan(value, 0.1, label) }
                measurements.append(["sample": id, "selection": selection, "label": label, "coverage": value, "selected": selected])
                print("SMART-EDGE-CHECK \(id) \(label) coverage=\(value)")
            }
        }
        let measured = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
        measured.name = "smart-edge-checks"; measured.lifetime = .keepAlways; add(measured)
    }
    func testPreparedNativeModelsAndFineSkinExclusion() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let models = repository.appendingPathComponent("build/smart-mask-validation/models")
        let photograph = repository.appendingPathComponent("build/smart-mask-validation/samples/02177c7b318e1d5c.jpg")
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent("FaceParsing.mlmodelc").path),
              FileManager.default.fileExists(atPath: photograph.path) else { throw XCTSkip("Prepare the pinned public smart-mask fixtures first") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photograph as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try Data(contentsOf: repository.appendingPathComponent("Tests/Fixtures/smart-mask-fixture.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        let sample = try XCTUnwrap((fixture["samples"] as? [[String:Any]])?.first { $0["id"] as? String == "02177c7b318e1d5c" })
        let box = try XCTUnwrap(sample["box"] as? [Double])
        let engine = SmartMaskEngine(directory: models), identity = SmartMaskSource(recipe: recipe(), size: CGSize(width: image.width, height: image.height))
        let candidates = try await engine.select(image: image, source: identity,
            prompts: [SmartMaskPrompt(point: MaskPoint(box[0], 1-box[1]), label: 2), SmartMaskPrompt(point: MaskPoint(box[2], 1-box[3]), label: 3)])
        XCTAssertEqual(candidates.count, 3)
        let selected = try XCTUnwrap(candidates.first); XCTAssertGreaterThan(selected.selectedPixels, 0)
        func cropped(_ region: CGRect) throws -> (CGImage,CGRect) {
            let pixels = CGRect(x: region.minX * Double(image.width), y: (1-region.maxY) * Double(image.height),
                width: region.width * Double(image.width), height: region.height * Double(image.height)).integral
                .intersection(CGRect(x: 0,y: 0,width: image.width,height: image.height))
            return (try XCTUnwrap(image.cropping(to: pixels)), CGRect(x: pixels.minX / Double(image.width), y: 1-pixels.maxY / Double(image.height),
                width: pixels.width / Double(image.width), height: pixels.height / Double(image.height)))
        }
        let object = try XCTUnwrap(SmartMaskField(selected.raster.base).boundingRegion())
        let (bodyImage,bodyRegion) = try cropped(object)
        let body = try await engine.body(image: bodyImage, region: bodyRegion, selection: selected.raster)
        XCTAssertNotNil(body[.clothes]); XCTAssertNotNil(body[.faceSkin])
        let face = try XCTUnwrap((sample["faces"] as? [[String:Any]])?.first?["box"] as? [Double])
        let faceBox = CGRect(x: face[0],y: 1-face[3],width: face[2]-face[0],height: face[3]-face[1])
        let (faceImage,faceRegion) = try cropped(SmartMaskField.faceRegion(faceBox, size: identity.size))
        let parts = try await engine.face(image: faceImage, region: faceRegion, body: body, selection: selected.raster)
        let skin = try await engine.combine([try XCTUnwrap(parts[.faceSkin]), try XCTUnwrap(parts[.bodySkin])])
        try skin.validate()
        let coarse = try SmartMaskField(skin.base), patch = try XCTUnwrap(skin.facePatch).pixels()
        XCTAssertFalse(patch.isEmpty)
        let fine = try SmartMaskField(XCTUnwrap(skin.facePatch))
        for feature in [SmartMaskPart.brows, .eyes, .lips] {
            let field = try SmartMaskField(XCTUnwrap(parts[feature]).base)
            XCTAssertTrue(field.values.contains { $0 > 0.5 })
            for i in field.values.indices where field.values[i] > 0.5 {
                let p = field.point(x: i % field.width, y: i / field.width)
                XCTAssertEqual(fine.region.contains(p) ? fine.sample(p) : coarse.sample(p), 0, accuracy: 0.00003, feature.rawValue)
            }
        }
    }
    @MainActor func testPreparedFineFaceOnlyMultiplePeopleManualBoxAndAutomaticReset() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let prepared = repository.appendingPathComponent("build/smart-mask-validation/models/FaceParsing.mlmodelc")
        let sample = repository.appendingPathComponent("build/smart-mask-validation/samples/02177c7b318e1d5c.jpg")
        guard FileManager.default.fileExists(atPath: prepared.path), FileManager.default.fileExists(atPath: sample.path) else {
            throw XCTSkip("Prepare pinned FaceParsing and the public two-person fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-fine-only-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        defer { try? catalog.database.close() }
        let modelDirectory = directory.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: prepared, to: modelDirectory.appendingPathComponent(prepared.lastPathComponent))
        let models = SmartMaskModels(directory: modelDirectory), engine = SmartMaskEngine(models: models), pipeline = ImagePipeline()
        XCTAssertNil(models.objectDirectory); XCTAssertNil(models.bodyURL); XCTAssertNotNil(models.faceURL)
        let root = try catalog.addRoot(url: sample.deletingLastPathComponent(), bookmark: AccessLease.bookmark(sample.deletingLastPathComponent(), readOnly: true))
        let photo = try ReferenceImporter.inspect(url: sample, root: root, rootURL: sample.deletingLastPathComponent())
        try catalog.index(photo)
        let baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        model.catalog = catalog; model.activeID = photo.id; model.activePhoto = photo; model.roots = [root]
        model.recipe = baseline; model.canEdit = true; model.orientedSourceSize = CGSize(width: photo.width, height: photo.height)
        model.editMode = true; model.dirty = true; XCTAssertTrue(model.commitRecipe())
        model.smartMaskEngine = engine; model.smartMaskPipeline = pipeline
        model.undo.removeAllActions(); model.undo.groupsByEvent = false
        let saved = try catalog.photo(photo.id)?.recipe
        model.beginSmartMask(workflow: .people)
        model.smartMaskSession?.models = models
        func settle() async {
            while let task = model.smartMaskTask { await task.value }
            await model.smartMaskPreviewTask?.value
        }
        await settle()
        XCTAssertEqual(model.smartMaskSession?.people.count, 2)
        for index in [0, 1] {
            model.selectSmartPeople([index]); await settle()
            let session = try XCTUnwrap(model.smartMaskSession)
            XCTAssertTrue(session.faceRefined); XCTAssertNil(session.faceFailure); XCTAssertEqual(session.faces.count, 1)
            for part in [SmartMaskPart.faceSkin, .brows, .eyes, .lips] { try XCTUnwrap(session.parts?[part]).validate() }
            XCTAssertNil(session.parts?[.bodySkin]); XCTAssertNil(session.parts?[.clothes])
        }
        model.selectAllSmartPeople(); await settle()
        XCTAssertEqual(model.smartMaskSession?.selectedPeople, [0, 1]); XCTAssertTrue(model.smartMaskSession?.faceRefined ?? false)
        let combined = try XCTUnwrap(model.smartMaskSession?.instance)
        for raster in try XCTUnwrap(model.smartMaskSession?.parts).values { XCTAssertEqual(raster.instance, combined.base) }
        let predictions = await engine.facePredictionCount
        XCTAssertEqual(predictions, 2, "adding a cached second person must not repeat facial inference")

        model.selectSmartPeople([0]); await settle()
        let automatic = try XCTUnwrap(model.smartMaskSession)
        let face = try XCTUnwrap(automatic.faces.first)
        model.smartMaskSession?.mode = .face
        model.smartMaskPointer(MaskPoint(face.minX, face.maxY), phase: .down, modifiers: [])
        model.smartMaskPointer(MaskPoint(face.maxX, face.minY), phase: .up, modifiers: [])
        await settle()
        XCTAssertNotNil(model.smartMaskSession?.faceRegions[0]); XCTAssertTrue(model.smartMaskSession?.canResetFace ?? false)
        XCTAssertTrue(model.smartMaskSession?.faceRefined ?? false)
        let manualPredictions = await engine.facePredictionCount
        XCTAssertEqual(manualPredictions, 3)
        model.resetSmartFace(); await settle()
        XCTAssertNil(model.smartMaskSession?.faceRegions[0]); XCTAssertNil(model.smartMaskSession?.selectedFace)
        XCTAssertFalse(model.smartMaskSession?.canResetFace ?? true)
        XCTAssertEqual(model.smartMaskSession?.parts, automatic.parts)
        let resetPredictions = await engine.facePredictionCount, bodyPredictions = await engine.bodyPredictionCount
        XCTAssertEqual(resetPredictions, manualPredictions); XCTAssertEqual(bodyPredictions, 0)

        // A valid crop outside this person's instance must not replace good skin
        // with an empty fine patch. It remains a retryable draft, with no saved edit.
        model.analyzeSmartParts(face: CGRect(x: 0.9, y: 0, width: 0.08, height: 0.08)); await settle()
        XCTAssertFalse(model.smartMaskSession?.faceRefined ?? true); XCTAssertNotNil(model.smartMaskSession?.faceFailure)
        XCTAssertTrue(model.smartMaskSession?.parts?.isEmpty ?? false); XCTAssertNil(model.error)
        model.resetSmartFace(); await settle()
        XCTAssertTrue(model.smartMaskSession?.faceRefined ?? false); XCTAssertNil(model.smartMaskSession?.faceFailure)
        XCTAssertEqual(model.smartMaskSession?.parts, automatic.parts)
        XCTAssertEqual(try catalog.photo(photo.id)?.recipe, saved); XCTAssertFalse(model.undo.canUndo)

        for part in [SmartMaskPart.brows, .eyes, .lips] { model.toggleSmartPart(part) }
        await settle(); model.smartMaskSession?.separate = true
        XCTAssertEqual(model.smartMaskSession?.creationCount, 3)
        model.undo.beginUndoGrouping(); model.createSmartMask(); model.undo.endUndoGrouping()
        let created = try XCTUnwrap(model.recipe)
        XCTAssertEqual(created.localAdjustments.count, 3)
        XCTAssertEqual(created.localAdjustments.flatMap(\.components).compactMap { $0.raster?.parts.first }, [.brows, .eyes, .lips])
        let reopened = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(created))
        try reopened.validate(); XCTAssertEqual(reopened, created)
        model.undo.undo(); XCTAssertTrue(model.recipe!.localAdjustments.isEmpty)
        model.undo.redo(); XCTAssertEqual(model.recipe, created)
        model.undo.undo(); model.cancelSmartMask()
        print("SMART-FINE face-only automatic=2 manual=1 reset-reused=true parts=brows,eyes,lips undo-redo=true")
    }
    func testFineFaceFailureKeepsCoarsePartsWithoutCachingFailureOrAcceptingChangedSource() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let prepared = repository.appendingPathComponent("build/smart-mask-validation/models/selfie_multiclass_256x256.tflite")
        let sample = repository.appendingPathComponent("build/smart-mask-validation/samples/02177c7b318e1d5c.jpg")
        guard FileManager.default.fileExists(atPath: prepared.path), FileManager.default.fileExists(atPath: sample.path) else {
            throw XCTSkip("Prepare pinned Selfie and the public two-person fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-fine-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: prepared, to: directory.appendingPathComponent(prepared.lastPathComponent))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("FaceParsing.mlmodelc"), withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("public-copy.jpg")
        try FileManager.default.copyItem(at: sample, to: copy)
        let root = StorageRoot(id: "fine-source", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "fine-source")
        let photo = try ReferenceImporter.inspect(url: copy, root: root, rootURL: directory)
        let pipeline = ImagePipeline(), engine = SmartMaskEngine(directory: directory)
        let baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        let request = ImageRequest(photo: photo, root: root, recipe: baseline), input = try await pipeline.smartMaskInput(request)
        let people = try await engine.people(image: input.image, source: SmartMaskSource(recipe: baseline, size: CGSize(width: photo.width, height: photo.height)))
        let person = try XCTUnwrap(people.first)
        for _ in 0..<2 {
            let result = try await engine.analyzePerson(image: input.image, selection: person.raster, request: request, pipeline: pipeline)
            XCTAssertFalse(result.faceRefined); XCTAssertNotNil(result.faceFailure)
            XCTAssertNotNil(result.parts[.faceSkin]); XCTAssertNotNil(result.parts[.clothes]); XCTAssertNil(result.parts[.eyes])
            for raster in result.parts.values { try raster.validate() }
        }
        let predictions = await engine.bodyPredictionCount, entries = await engine.cachedPartCount, hits = await engine.partCacheHits
        XCTAssertEqual(predictions, 2); XCTAssertEqual(entries, 0); XCTAssertEqual(hits, 0)
        try (Data(contentsOf: copy) + Data([0])).write(to: copy)
        do {
            _ = try await engine.analyzePerson(image: input.image, selection: person.raster, request: request, pipeline: pipeline)
            XCTFail("source identity failures must not become optional face fallbacks")
        } catch is LRCError {}
    }
    @MainActor func testFinePeopleInspectorLeavesPortraitsReachableInShortWindows() async throws {
        let suite = "smart-short-layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        for key in ["showLeftPanel", "showRightPanel", "showFilmstrip"] { preferences.set(true, forKey: key) }
        preferences.set(Metrics.rightPanel.initial, forKey: "workspaceRightWidth")
        let size = CGSize(width: 160, height: 120), r = recipe()
        let photo = Photo(id: "short-layout", rootID: "synthetic", relativePath: "synthetic.ARW", identity: Data(), identityKey: "short-layout", width: 160, height: 120)
        let root = StorageRoot(id: photo.rootID, path: "", bookmark: Data(), label: "synthetic")
        let model = AppModel()
        model.activePhoto = photo; model.activeID = photo.id; model.photos = [photo]; model.selection = [photo.id]
        model.recipe = r; model.canEdit = true; model.singleView = true; model.editMode = true; model.maskMode = true
        model.image = CIContext().createCGImage(CIImage(color: .gray), from: CGRect(origin: .zero, size: size))
        model.orientedSourceSize = size; model.renderedNativeSize = size
        let whole = SmartMaskRaster(source: SmartMaskSource(recipe: r, size: size), model: "synthetic-layout",
            base: try SmartMaskTile(values: [1], width: 1, height: 1, region: CGRect(x: 0, y: 0, width: 1, height: 1)))
        var session = SmartMaskSession(photoID: photo.id, catalogPath: "/synthetic", request: ImageRequest(photo: photo, root: root, recipe: r), source: whole.source, target: .newMask)
        session.workflow = .people; session.ready = true; session.faceRefined = true; session.instance = whole; session.allPeople = whole
        session.people = [SmartMaskPerson(raster: whole, bounds: whole.base.region, thumbnail: nil), SmartMaskPerson(raster: whole, bounds: whole.base.region, thumbnail: nil)]
        session.selectedPeople = [0, 1]; session.preview = whole; session.selectedParts = [.eyes, .lips]
        session.parts = Dictionary(uniqueKeysWithValues: SmartMaskPart.allCases.map { part in
            var raster = whole; raster.instance = whole.base; raster.parts = [part]; return (part, raster)
        })
        session.message = L10n.text("smartMask.someFacesUnresolved", defaultValue: "Some faces could not be located. Select one person to refine their face region; existing parts remain available.")
        model.smartMaskSession = session
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for windowSize in [CGSize(width: 1000, height: 640), CGSize(width: 1280, height: 673), CGSize(width: 1280, height: 800)] {
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: windowSize), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua); window.contentView = host
                defer { window.contentView = nil }
                try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, windowSize.width + 1)
                XCTAssertLessThanOrEqual(host.fittingSize.height, windowSize.height + 1)
                let inspector = try XCTUnwrap(scrollViews(host).filter {
                    let rect = $0.convert($0.bounds, to: host)
                    return rect.midX > host.bounds.midX && rect.width > 250
                }.max { $0.convert($0.bounds, to: host).maxX < $1.convert($1.bounds, to: host).maxX })
                let viewport = inspector.convert(inspector.bounds, to: host)
                let usableHeight = min(inspector.contentView.bounds.height, viewport.height - inspector.contentInsets.top - inspector.contentInsets.bottom)
                XCTAssertTrue(host.bounds.contains(viewport))
                XCTAssertGreaterThanOrEqual(usableHeight, 160, "The initial portrait controls need a usable viewport, rather than only their title")
                print("SMART-SHORT size=\(windowSize) theme=\(theme.rawValue) inspector=\(viewport) usableHeight=\(usableHeight)")
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "smart-short-\(Int(windowSize.width))x\(Int(windowSize.height))-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        model.cancelSmartMask()
    }
    func testDirectPeopleInstancesAndNonPersonImage() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let engine = SmartMaskEngine(directory: repository.appendingPathComponent("build/smart-mask-validation/models"))
        for (name, count) in [("02177c7b318e1d5c", 2), ("012fe322a5fd004c", 1), ("000ccf1d00f7f1cd", 0)] {
            let url = repository.appendingPathComponent("build/smart-mask-validation/samples/\(name).jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Prepare pinned public smart-mask fixtures") }
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)), 0, nil))
            var recipe = recipe(); recipe.sourceDigest = try SafeFileWriter.sha256(url)
            let source = SmartMaskSource(recipe: recipe, size: CGSize(width: image.width, height: image.height))
            let start = CFAbsoluteTimeGetCurrent()
            let people = try await engine.people(image: image, source: source)
            print("SMART-PEOPLE \(name) count=\(people.count) seconds=\(CFAbsoluteTimeGetCurrent()-start)")
            XCTAssertEqual(people.count, count)
            let cached = try await engine.people(image: image, source: source)
            XCTAssertEqual(cached.map(\.raster), people.map(\.raster))
            for person in people {
                try person.raster.validate(); XCTAssertNotNil(person.thumbnail)
                XCTAssertLessThanOrEqual(person.thumbnail?.width ?? 0, 120)
                XCTAssertLessThanOrEqual(person.thumbnail?.height ?? 0, 120)
                XCTAssertEqual(person.bounds, try SmartMaskField(person.raster.base).boundingRegion())
            }
            if people.count == 2 {
                XCTAssertLessThan(people[0].bounds.midX, people[1].bounds.midX)
                let a = try SmartMaskField(people[0].raster.base), b = try SmartMaskField(people[1].raster.base)
                // Instance mattes have soft boundaries; check distinct person cores, not disjoint edge probabilities.
                XCTAssertTrue(a.values.indices.contains { a.values[$0] > 0.9 && b.values[$0] < 0.1 })
                XCTAssertTrue(a.values.indices.contains { b.values[$0] > 0.9 && a.values[$0] < 0.1 })
            }
        }
    }
    @MainActor func testStablePointerModesWholePersonAndOverlayInvalidation() throws {
        let model = AppModel(previewRenderer: { _, _, _ in throw LRCError("synthetic preview") })
        let root = StorageRoot(id: "root", path: "/synthetic", bookmark: Data(), label: "synthetic")
        let photo = Photo(id: "smart", rootID: root.id, relativePath: "synthetic.png", identity: Data(), identityKey: "smart-test", width: 4, height: 4)
        let recipe = recipe(), raster = try raster(recipe)
        var session = SmartMaskSession(photoID: photo.id, catalogPath: "/synthetic", request: ImageRequest(photo: photo, root: root, recipe: recipe), source: raster.source, target: .newMask)
        session.ready = true; session.preview = raster; session.instance = raster
        model.smartMaskSession = session
        model.smartMaskPointer(MaskPoint(0.1, 0.1), phase: .down, modifiers: [])
        model.smartMaskPointer(MaskPoint(0.8, 0.8), phase: .up, modifiers: [])
        XCTAssertTrue(model.smartMaskSession!.prompts.isEmpty, "a drag in click mode must not silently become a point")
        model.smartMaskSession?.busy = true
        model.smartMaskPointer(MaskPoint(0.2, 0.3), phase: .down, modifiers: [])
        model.smartMaskPointer(MaskPoint(0.2, 0.3), phase: .up, modifiers: [])
        XCTAssertEqual(model.smartMaskSession?.prompts.count, 1, "ready input can accept a newer click while an older prediction runs")
        XCTAssertEqual(model.smartMaskSession?.preview, raster, "previous overlay remains visible during prediction")
        session.workflow = .people; session.analyzingParts = true; session.wholePerson = true
        model.smartMaskSession = session
        XCTAssertTrue(session.canCreate, "whole person is available before body-part analysis finishes")
        model.smartMaskPointer(MaskPoint(0.2, 0.3), phase: .down, modifiers: [])
        model.smartMaskPointer(MaskPoint(0.2, 0.3), phase: .up, modifiers: [])
        XCTAssertTrue(model.smartMaskSession!.prompts.isEmpty, "person workflow does not secretly use object clicks")
        var edit = MaskCanvasEditing(group: LocalAdjustment(components: [MaskComponent(tool: .object)]), component: nil,
            recipe: recipe, sourceSize: raster.source.size, reference: nil, showOverlay: true, color: 0)
        let original = edit
        edit.smartBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertNotEqual(edit, original); XCTAssertTrue(edit.hasSameCoverage(as: original))
        edit.showOverlay = false; XCTAssertFalse(edit.hasSameCoverage(as: original))
    }
    func testFrozenRasterTIFF16AlphaAndSeparateModelInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.png")
        try PNGFixture.data(depth: 16, color: 6).write(to: url)
        let originalDigest = try SafeFileWriter.sha256(url), source = try PNGFixture.request(url), pipeline = ImagePipeline()
        var current = try await pipeline.baseline(source)
        let original = try await pipeline.render(ImageRequest(photo: source.photo, root: source.root, recipe: current), longEdge: nil, pixelFormat: .RGBA16)
        var component = MaskComponent(tool: .object)
        let firstPerson = SmartMaskRaster(source: SmartMaskSource(recipe: current, size: original.orientedSourceSize), model: "vision-person-instance-r1/synthetic-export",
            base: try SmartMaskTile(values: [0,1,0.5,1], width: 2, height: 2, region: CGRect(x: 0,y: 0,width: 1,height: 1)))
        var secondPerson = firstPerson
        secondPerson.base = try SmartMaskTile(values: [0.3,0,0,0.7], width: 2, height: 2, region: firstPerson.base.region)
        let mergedPeople = try await SmartMaskEngine().combinePeople([firstPerson, secondPerson])
        XCTAssertEqual(try SmartMaskField(mergedPeople.base).values[0], 0.3, accuracy: 0.00003)
        component.raster = mergedPeople
        var group = LocalAdjustment(components: [component]); group.exposure = 0.8
        current.schemaVersion = 3; current.maskVersion = 3; current.localAdjustments = [group]
        let editedRequest = ImageRequest(photo: source.photo, root: source.root, recipe: current)
        let input = try await pipeline.smartMaskInput(editedRequest)
        var brighter = current; brighter.exposure = 1
        let sameInput = try await pipeline.smartMaskInput(ImageRequest(photo: source.photo, root: source.root, recipe: brighter))
        XCTAssertEqual(input.image.dataProvider?.data, sameInput.image.dataProvider?.data, "creative adjustments do not change the model's baseline")
        let rgba = try SmartMaskInput.rgba(input.image, side: 64)
        XCTAssertTrue(stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == 255 }, "only the model input gets a neutral opaque background")
        let snapshot = ExportSnapshot(id: "smart-tiff", request: editedRequest, destination: directory.appendingPathComponent("out.tif"),
            targetBookmark: Data(), options: ExportOptions(format: .tiff))
        let frozenData = try JSONEncoder().encode(snapshot)
        current.localAdjustments = []
        let frozen = try JSONDecoder().decode(ExportSnapshot.self, from: frozenData)
        let expected = try await pipeline.render(frozen.request, longEdge: nil, pixelFormat: .RGBA16)
        _ = try await pipeline.export(frozen.request, staging: snapshot.destination, options: snapshot.options)
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithURL(snapshot.destination as CFURL, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        XCTAssertEqual(output.bitsPerComponent, 16)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        func pixels(_ image: CGImage) -> [Float] {
            var values = [Float](repeating: 0, count: image.width * image.height * 4)
            context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 16,
                bounds: CGRect(x: 0,y: 0,width: image.width,height: image.height), format: .RGBAf, colorSpace: ImagePipeline.outputSpace)
            return values
        }
        let actual = pixels(output), reference = pixels(expected.image), initial = pixels(original.image)
        XCTAssertLessThan(zip(actual, reference).map { abs($0-$1) }.max()!, 0.0001)
        XCTAssertTrue(stride(from: 3,to: actual.count,by: 4).allSatisfy { abs(actual[$0]-initial[$0]) < 1.0/65535 }, "mask coverage must not replace image alpha")
        XCTAssertNotEqual(actual, initial, "frozen local adjustment was actually rendered")
        XCTAssertEqual(try SafeFileWriter.sha256(url), originalDigest)
    }
}
