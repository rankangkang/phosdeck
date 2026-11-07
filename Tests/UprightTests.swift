import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
@testable import Phosdeck

final class UprightTests: XCTestCase {
    private let size = CGSize(width: 900, height: 600)
    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
                   baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func lines(_ truth: EditRecipe, verticalOnly: Bool = false) throws -> [PerspectiveLine] {
        var reference = truth; reference.crop = Crop(); reference.perspective.constrainCrop = false
        let g = try PhotoGeometry(size: size, recipe: reference), inverse = g.transform.inverted()
        func line(_ a: CGPoint, _ b: CGPoint, vertical: Bool) throws -> PerspectiveLine {
            let p = try XCTUnwrap(inverse.point(CGPoint(x: a.x*g.output.width, y: a.y*g.output.height)))
            let q = try XCTUnwrap(inverse.point(CGPoint(x: b.x*g.output.width, y: b.y*g.output.height)))
            return PerspectiveLine(start: MaskPoint(p.x/size.width, p.y/size.height),
                                   end: MaskPoint(q.x/size.width, q.y/size.height), vertical: vertical, weight: 200)
        }
        var result = try [0.2,0.5,0.8].map { x in try line(CGPoint(x: x,y: 0.2),CGPoint(x: x,y: 0.8),vertical: true) }
        if !verticalOnly { result += try [0.2,0.5,0.8].map { y in try line(CGPoint(x: 0.2,y: y),CGPoint(x: 0.8,y: y),vertical: false) } }
        return result
    }
    func testGuidedRecoversOurCameraModelAndPreservesCropAndAdjustments() throws {
        var truth = recipe(); truth.perspective.vertical = -32; truth.perspective.horizontal = 23; truth.straightenDegrees = 3
        var base = recipe(); base.crop = Crop(x: 0.1,y: 0.1,width: 0.8,height: 0.8); base.exposure = 0.4
        let solved = try XCTUnwrap(UprightCorrection.guided(try lines(truth), size: size, recipe: base))
        XCTAssertEqual(solved.perspective.vertical, truth.perspective.vertical, accuracy: 0.1)
        XCTAssertEqual(solved.perspective.horizontal, truth.perspective.horizontal, accuracy: 0.1)
        XCTAssertEqual(solved.straightenDegrees, truth.straightenDegrees, accuracy: 0.01)
        XCTAssertEqual(solved.crop,base.crop); XCTAssertEqual(solved.exposure,base.exposure)
    }
    func testOneLineStraightensWithoutInventingPerspective() throws {
        var truth = recipe(); truth.straightenDegrees = -6
        let guide = try lines(truth).last!
        let solved = try XCTUnwrap(UprightCorrection.guided([guide],size: size,recipe: recipe(),straightenOnly: true))
        XCTAssertEqual(solved.straightenDegrees,-6,accuracy: 0.01)
        XCTAssertEqual(solved.perspective,PerspectiveSettings())
        XCTAssertNil(UprightCorrection.guided([guide],size: size,recipe: recipe()))
    }
    func testAutomaticVerticalAndFullWithQuarterTurnAndReflection() throws {
        for turns in [0,1] { for flip in [false,true] {
            var truth = recipe(); truth.quarterTurns = turns; truth.flipHorizontal = flip
            truth.perspective.vertical = -20; truth.perspective.horizontal = 0; truth.straightenDegrees = 3
            var base = recipe(); base.quarterTurns = turns; base.flipHorizontal = flip
            let input = try lines(truth)
            let result = try XCTUnwrap(UprightCorrection.automatic(.full,lines: input,size: size,recipe: base))
            XCTAssertEqual(result.perspective.vertical,-20,accuracy: 0.3)
            XCTAssertEqual(result.straightenDegrees,3,accuracy: 0.05)
        } }
    }
    func testInsufficientConflictingAndInvalidLinesLeaveExistingEditAlone() throws {
        var base = recipe(); base.straightenDegrees = 7; base.perspective.horizontal = 15
        XCTAssertNil(UprightCorrection.automatic(.auto,lines: [],size: size,recipe: base))
        let invalid = PerspectiveLine(start: MaskPoint(.nan, 0.1),end: MaskPoint(0.8, 0.8),vertical: true)
        XCTAssertNil(UprightCorrection.guided([invalid,invalid],size: size,recipe: base))
        let coincident = PerspectiveLine(start: MaskPoint(0.2, 0.2),end: MaskPoint(0.2, 0.2),vertical: true)
        XCTAssertNil(UprightCorrection.guided([coincident,coincident],size: size,recipe: base))
        let weak = PerspectiveLine(start: MaskPoint(0.3, 0.2),end: MaskPoint(0.3, 0.8),vertical: true,weight: 2)
        XCTAssertNil(UprightCorrection.automatic(.full,lines: [weak],size: size,recipe: base))
        var clockwise = recipe(); clockwise.straightenDegrees = 7
        var anticlockwise = recipe(); anticlockwise.straightenDegrees = -7
        XCTAssertNil(UprightCorrection.automatic(.level,lines: try lines(clockwise)+lines(anticlockwise),size: size,recipe: base))
        XCTAssertEqual(base.straightenDegrees,7)
    }
    func testDominantEdgesRejectOutliersAndFullFallsBackToVerticalEvidence() throws {
        var truth = recipe(); truth.straightenDegrees = 4
        var outlier = recipe(); outlier.straightenDegrees = -12
        var input = try lines(truth)
        input += try lines(outlier).prefix(2).map { var line = $0; line.weight = 40; return line }
        let result = try XCTUnwrap(UprightCorrection.automatic(.level,lines: input,size: size,recipe: recipe()))
        XCTAssertEqual(result.straightenDegrees,4,accuracy: 0.1)
        truth.perspective.vertical = -20
        let fallback = try XCTUnwrap(UprightCorrection.automatic(.full,lines: lines(truth,verticalOnly: true),size: size,recipe: recipe()))
        XCTAssertEqual(fallback.perspective.vertical,-20,accuracy: 0.3)
        XCTAssertEqual(fallback.perspective.horizontal,0,accuracy: 0.01)
        XCTAssertEqual(fallback.straightenDegrees,4,accuracy: 0.05)
    }
    func testGuideFrameRoundTripsCropPreviewRotationPerspectiveAndFlip() throws {
        for tilted in [false,true] { for flip in [false,true] { for turns in [0,1,2,3] {
            var r = recipe(); r.straightenDegrees = 8; r.quarterTurns = turns; r.flipVertical = flip
            if tilted { r.perspective.vertical = -30; r.perspective.horizontal = 15 }
            r.crop = Crop(x: 0.1,y: 0.2,width: 0.7,height: 0.6)
            let image = turns%2 == 0 ? CGSize(width: 600,height: 400) : CGSize(width: 400,height: 600)
            let frame = try PerspectiveGuideFrame(sourceSize: size,imageSize: image,canvas: CGSize(width: 800,height: 500),recipe: r)
            for p in [MaskPoint(0.3, 0.4),MaskPoint(0.7, 0.6)] {
                let q = try XCTUnwrap(frame.source(try XCTUnwrap(frame.view(p))))
                XCTAssertEqual(q.x,p.x,accuracy: 1e-9); XCTAssertEqual(q.y,p.y,accuracy: 1e-9)
            }
        } } }
    }
    func testDetectorAndLevelCorrectionUseImageCoordinatesAndIgnoreNoise() throws {
        let bounds = CGRect(x: 0,y: 0,width: 640,height: 480)
        let ground = CIImage(color: CIColor(red: 0.1,green: 0.1,blue: 0.1)).cropped(to: bounds)
        let shape = CIImage(color: CIColor(red: 0.7,green: 0.7,blue: 0.7)).cropped(to: CGRect(x: 140,y: 120,width: 360,height: 240))
        let rotate = CGAffineTransform(translationX: -320,y: -240).concatenating(CGAffineTransform(rotationAngle: 4 * .pi/180)).concatenating(CGAffineTransform(translationX: 320,y: 240))
        let image = shape.transformed(by: rotate).composited(over: ground).cropped(to: bounds)
        let cg = try XCTUnwrap(CIContext().createCGImage(image,from: bounds))
        let detected = try UprightLineDetector.lines(in: cg)
        XCTAssertGreaterThanOrEqual(detected.count,4)
        let imageSize = CGSize(width: 640,height: 480)
        let result = try XCTUnwrap(UprightCorrection.automatic(.level,lines: detected,size: imageSize,recipe: recipe()))
        XCTAssertEqual(result.straightenDegrees,-4,accuracy: 0.3)
        XCTAssertTrue(UprightLineDetector.lines(in: .init(width: 64,height: 64,values: Array(repeating: 0.5,count: 4096))).isEmpty)
    }

    @MainActor private func model(in folder: URL) async throws -> AppModel {
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        let image = CIImage(color: CIColor(red: 0.3,green: 0.3,blue: 0.3)).cropped(to: CGRect(origin: .zero,size: size))
        let cg = try XCTUnwrap(CIContext().createCGImage(image,from: image.extent))
        let url = folder.appendingPathComponent("synthetic.tif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.tiff.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,cg,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let catalog = try CatalogStore(directory: folder.appendingPathComponent("Test.phoscat"))
        let root = try catalog.addRoot(url: folder,bookmark: AccessLease.bookmark(folder,readOnly: true))
        let photo = try ReferenceImporter.inspect(url: url,root: root,rootURL: folder); try catalog.index(photo)
        let model = AppModel(); model.catalog = catalog; model.undo.groupsByEvent = false; try model.reload()
        model.choose([photo.id],active: photo.id)
        for _ in 0..<500 {
            if model.canEdit && model.previewCurrent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canEdit)
        model.editMode = true; XCTAssertTrue(model.selectDevelopTool(.crop))
        for _ in 0..<500 {
            if model.previewIsCrop && model.canvasCoordinatesCurrent && model.previewCurrent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canvasCoordinatesCurrent)
        return model
    }

    @MainActor func testGuidesCommitOneCorrectionAndUndoClearsTransientGuides() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        let base = try XCTUnwrap(model.recipe)
        var truth = base; truth.perspective.vertical = -20
        let guides = try lines(truth,verticalOnly: true)
        model.beginPerspectiveGuides(.perspective)
        model.addPerspectiveGuide(start: guides[0].start,end: guides[0].end)
        XCTAssertEqual(model.recipe,base)
        model.undo.beginUndoGrouping()
        model.addPerspectiveGuide(start: guides[2].start,end: guides[2].end)
        model.undo.endUndoGrouping()
        XCTAssertEqual(try XCTUnwrap(model.recipe).perspective.vertical,-20,accuracy: 0.2)
        XCTAssertEqual(model.perspectiveGuides.count,2)
        model.undo.undo()
        XCTAssertEqual(model.recipe,base)
        XCTAssertNil(model.perspectiveGuideTool)
        model.undo.redo()
        XCTAssertEqual(try XCTUnwrap(model.recipe).perspective.vertical,-20,accuracy: 0.2)
    }

    func testGuideClassificationIsStableWhenEndpointsAreReversed() throws {
        let forward = try XCTUnwrap(UprightCorrection.classified(start: MaskPoint(0.2, 0.2), end: MaskPoint(0.2, 0.8), size: size, recipe: recipe()))
        let reversed = try XCTUnwrap(UprightCorrection.classified(start: MaskPoint(0.2, 0.8), end: MaskPoint(0.2, 0.2), size: size, recipe: recipe()))
        XCTAssertTrue(forward.vertical)
        XCTAssertTrue(reversed.vertical)
        XCTAssertNil(UprightCorrection.classified(start: MaskPoint(0.2, 0.2), end: MaskPoint(0.2, 0.2), size: size, recipe: recipe()))
    }

    @MainActor func testInvalidGuideEndpointMovePreservesRecipeAndDeleteRemovesOnlySelectedGuide() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        let base = try XCTUnwrap(model.recipe)
        var truth = base; truth.perspective.vertical = -20
        let guides = try lines(truth, verticalOnly: true)
        model.beginPerspectiveGuides(.perspective)
        model.addPerspectiveGuide(start: guides[0].start, end: guides[0].end)
        model.undo.beginUndoGrouping()
        model.addPerspectiveGuide(start: guides[2].start, end: guides[2].end)
        model.undo.endUndoGrouping()
        let solved = try XCTUnwrap(model.recipe)
        XCTAssertTrue(model.beginPerspectiveGuideDrag(index: 0, endpoint: .start))
        XCTAssertFalse(model.updatePerspectiveGuide(index: 0, endpoint: .start, point: MaskPoint(.nan, .nan)))
        XCTAssertEqual(model.recipe, solved)
        XCTAssertEqual(model.perspectiveGuides.count, 2)
        XCTAssertTrue(model.endPerspectiveGuideDrag())
        XCTAssertTrue(model.selectPerspectiveGuide(index: 0))
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.deleteSelectedPerspectiveGuide())
        model.undo.endUndoGrouping()
        XCTAssertEqual(model.perspectiveGuides.count, 1)
        XCTAssertEqual(try XCTUnwrap(model.recipe).perspective, base.perspective)
        XCTAssertEqual(try XCTUnwrap(model.recipe).straightenDegrees, base.straightenDegrees)
        XCTAssertNil(model.selectedPerspectiveGuideIndex)
    }

    @MainActor func testGuideEndpointMoveCommitsOnceAndUndoRedoRestoresIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        let base = try XCTUnwrap(model.recipe)
        var truth = base; truth.perspective.vertical = -20
        let guides = try lines(truth, verticalOnly: true)
        model.beginPerspectiveGuides(.perspective)
        model.addPerspectiveGuide(start: guides[0].start, end: guides[0].end)
        model.undo.beginUndoGrouping()
        model.addPerspectiveGuide(start: guides[2].start, end: guides[2].end)
        model.undo.endUndoGrouping()
        let before = try XCTUnwrap(model.recipe), historyBefore = model.editHistory.count
        let moved = MaskPoint(guides[0].start.x + 0.002, guides[0].start.y)
        XCTAssertTrue(model.beginPerspectiveGuideDrag(index: 0, endpoint: .start))
        XCTAssertTrue(model.updatePerspectiveGuide(index: 0, endpoint: .start, point: moved))
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.endPerspectiveGuideDrag())
        model.undo.endUndoGrouping()
        XCTAssertEqual(model.editHistory.count, historyBefore + 1)
        let after = try XCTUnwrap(model.recipe)
        XCTAssertNotEqual(after, before)
        model.undo.undo()
        XCTAssertEqual(model.recipe, before)
        model.undo.redo()
        XCTAssertEqual(model.recipe, after)
    }

    @MainActor func testEscapeCancelsGuideEndpointDragAndPhotoSwitchDiscardsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        let base = try XCTUnwrap(model.recipe)
        var truth = base; truth.perspective.vertical = -20
        let guides = try lines(truth, verticalOnly: true)
        model.beginPerspectiveGuides(.perspective)
        model.addPerspectiveGuide(start: guides[0].start, end: guides[0].end)
        model.undo.beginUndoGrouping()
        model.addPerspectiveGuide(start: guides[2].start, end: guides[2].end)
        model.undo.endUndoGrouping()
        var committed = try XCTUnwrap(model.recipe)
        let moved = MaskPoint(guides[0].start.x + 0.002, guides[0].start.y)
        XCTAssertTrue(model.beginPerspectiveGuideDrag(index: 0, endpoint: .start))
        XCTAssertTrue(model.updatePerspectiveGuide(index: 0, endpoint: .start, point: moved))
        model.changeRecipe({ $0.exposure = 0.6 }, commit: false)
        committed.exposure = 0.6
        model.cancelPerspectiveGuideInteraction()
        XCTAssertEqual(model.recipe, committed)
        XCTAssertTrue(model.dirty, "Cancelling a geometric drag preserves an unrelated exposure draft")
        XCTAssertNil(model.perspectiveGuideTool)

        for _ in 0..<500 {
            if model.canvasCoordinatesCurrent && model.previewCurrent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canvasCoordinatesCurrent)
        model.undo.beginUndoGrouping()
        model.beginPerspectiveGuides(.perspective)
        model.undo.endUndoGrouping()
        model.addPerspectiveGuide(start: guides[0].start, end: guides[0].end)
        XCTAssertTrue(model.beginPerspectiveGuideDrag(index: 0, endpoint: .start))
        XCTAssertTrue(model.updatePerspectiveGuide(index: 0, endpoint: .start, point: moved))
        XCTAssertEqual(model.recipe, committed, "A single perspective guide can be edited before the second guide is drawn")
        model.activeID = "another-photo"
        XCTAssertNil(model.perspectiveGuideTool)
        XCTAssertFalse(model.updatePerspectiveGuide(index: 0, endpoint: .start, point: moved))
        XCTAssertEqual(model.recipe, committed)
    }

    @MainActor func testReturnPreservesGuideDragAfterSaveFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        let base = try XCTUnwrap(model.recipe)
        var truth = base; truth.perspective.vertical = -20
        let guides = try lines(truth, verticalOnly: true)
        model.beginPerspectiveGuides(.perspective)
        model.addPerspectiveGuide(start: guides[0].start, end: guides[0].end)
        model.undo.beginUndoGrouping()
        model.addPerspectiveGuide(start: guides[2].start, end: guides[2].end)
        model.undo.endUndoGrouping()
        let committed = try XCTUnwrap(model.recipe)
        XCTAssertTrue(model.beginPerspectiveGuideDrag(index: 0, endpoint: .start))
        XCTAssertTrue(model.updatePerspectiveGuide(index: 0, endpoint: .start, point: MaskPoint(guides[0].start.x + 0.002, guides[0].start.y)))
        let draft = model.recipe
        let catalog = try XCTUnwrap(model.catalog)
        try await catalog.database.write { try $0.execute(sql: "CREATE TRIGGER fail_guide_save BEFORE UPDATE ON photo BEGIN SELECT RAISE(ABORT,'injected storage failure'); END") }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        defer { window.orderOut(nil); window.contentView = nil }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertNil(WorkspaceKeyboard.handle(key, model: model))
        XCTAssertNotNil(model.perspectiveGuideTool)
        XCTAssertNotNil(model.perspectiveGuideDragOriginal)
        XCTAssertEqual(model.recipe, draft)
        XCTAssertTrue(model.dirty)
        model.cancelPerspectiveGuideInteraction()
        XCTAssertEqual(model.recipe, committed)
        XCTAssertFalse(model.dirty)
    }

    @MainActor func testDeleteGuideKeyIsConsumedButTextFocusStillReceivesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        let base = try XCTUnwrap(model.recipe)
        let line = try XCTUnwrap(UprightCorrection.classified(start: MaskPoint(0.2, 0.2), end: MaskPoint(0.2, 0.8), size: size, recipe: base))
        model.perspectiveGuideTool = .perspective; model.perspectiveGuideBase = base; model.perspectiveGuides = [line]; model.selectedPerspectiveGuideIndex = 0
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"
        defer { window.orderOut(nil); window.contentView = nil }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51))
        XCTAssertNil(WorkspaceKeyboard.handle(key, model: model))
        XCTAssertTrue(model.perspectiveGuides.isEmpty)
        model.perspectiveGuideTool = .perspective; model.perspectiveGuideBase = base; model.perspectiveGuides = [line]; model.selectedPerspectiveGuideIndex = 0
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        window.contentView = editor; window.makeFirstResponder(editor)
        XCTAssertNotNil(WorkspaceKeyboard.handle(key, model: model))
        XCTAssertEqual(model.perspectiveGuides.count, 1)
    }

    @MainActor func testPerspectiveGuideCanvasStaysMountedDuringEndpointPreviewUpdate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        let base = try XCTUnwrap(model.recipe)
        var truth = base; truth.perspective.vertical = -20
        let guides = try lines(truth, verticalOnly: true)
        model.beginPerspectiveGuides(.perspective)
        model.addPerspectiveGuide(start: guides[0].start, end: guides[0].end)
        model.undo.beginUndoGrouping()
        model.addPerspectiveGuide(start: guides[2].start, end: guides[2].end)
        model.undo.endUndoGrouping()
        for _ in 0..<500 {
            if model.canvasCoordinatesCurrent && model.previewCurrent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canvasCoordinatesCurrent)

        let host = NSHostingView(rootView: PhotoCanvas(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let context = CIContext()
        func selectedGuidePixels(_ name: String) throws -> Int {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let image = try XCTUnwrap(bitmap.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: image.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            // The synthetic photo, mat and crop marks are neutral. Only the
            // selected guide contributes orange pixels to the rendered view.
            return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, index in
                let red = Int(bytes[index]), green = Int(bytes[index + 1]), blue = Int(bytes[index + 2])
                return count + (red > 100 && red > green + 30 && green > blue + 20 ? 1 : 0)
            }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(try selectedGuidePixels("guides-before-drag"), 0)

        let moved = MaskPoint(guides[0].start.x + 0.002, guides[0].start.y)
        XCTAssertTrue(model.beginPerspectiveGuideDrag(index: 0, endpoint: .start))
        XCTAssertTrue(model.updatePerspectiveGuide(index: 0, endpoint: .start, point: moved))
        XCTAssertFalse(model.canvasCoordinatesCurrent, "The interactive recipe changes before its new preview is published")
        // Keep this turn on MainActor so the queued preview cannot publish
        // before the mounted canvas has consumed the changed recipe.
        host.rootView = PhotoCanvas(model: model)
        XCTAssertGreaterThan(try selectedGuidePixels("guides-during-stale-preview"), 0,
                             "The guide must remain visible while its endpoint drag owns a frozen frame")
        XCTAssertNotNil(model.perspectiveGuideDragOriginal)
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.endPerspectiveGuideDrag())
        model.undo.endUndoGrouping()
        model.finishPerspectiveGuides()
        host.rootView = PhotoCanvas(model: model)
        XCTAssertEqual(try selectedGuidePixels("guides-after-finish"), 0,
                       "Leaving the perspective tool still removes its guides")
    }

    private actor Gate {
        var open = false
        var entered = false
        var continuation: CheckedContinuation<Void,Never>?
        func wait() async {
            entered = true
            if !open { await withCheckedContinuation { continuation = $0 } }
        }
        func release() { open = true; continuation?.resume(); continuation = nil }
    }

    @MainActor func testLateAutomaticResultCannotOverwriteNewInputOrAnotherPhoto() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await model(in: folder)
        defer { model.finishPerspectiveGuides(); model.activeID = nil; model.catalog = nil }
        var truth = try XCTUnwrap(model.recipe); truth.straightenDegrees = 4
        let detected = try lines(truth)
        for switchPhoto in [false, true] {
            let gate = Gate()
            model.detectPerspectiveLines = { _ in await gate.wait(); return detected }
            model.applyUpright(.level)
            let pending = try XCTUnwrap(model.uprightTask)
            for _ in 0..<500 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
            let entered = await gate.entered; XCTAssertTrue(entered)
            if switchPhoto { model.activeID = "another-photo" }
            else {
                model.undo.beginUndoGrouping()
                model.changeRecipe { $0.exposure = 0.7 }
                model.undo.endUndoGrouping()
            }
            let changed = model.recipe
            await gate.release()
            await pending.value
            XCTAssertEqual(model.recipe,changed)
            XCTAssertFalse(model.uprightAnalyzing)
        }
    }
}
