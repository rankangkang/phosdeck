import XCTest
import AppKit
import CoreImage
@testable import Phosdeck

final class DirectAdjustmentTests: XCTestCase {
    func testHistogramRegionsUseFiveNonuniformZonesAndParameterBounds() {
        for (x, region) in [(-0.1, HistogramRegion.blacks), (0.099, .blacks), (0.1, .shadows),
                            (0.299, .shadows), (0.3, .exposure), (0.699, .exposure),
                            (0.7, .highlights), (0.899, .highlights), (0.9, .whites), (1, .whites)] {
            XCTAssertEqual(HistogramRegion.at(x), region)
        }
        XCTAssertEqual(HistogramRegion.at(.nan), .exposure)
    }

    @MainActor func testHistogramDragPublishesDraftThenSavesOnceAndUndoRedo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await makeModel(folder)
        defer { model.choose([], active: nil) }
        model.undo.groupsByEvent = false
        let original = try XCTUnwrap(model.recipe), catalog = try XCTUnwrap(model.catalog)
        let count = try catalog.editHistory(photoID: "a").count
        XCTAssertTrue(model.beginHistogramAdjustment(.exposure))
        for delta in [0.1, 0.8, 1.25] { model.updateHistogramAdjustment(delta: delta) }
        XCTAssertEqual(model.recipe?.exposure, 1.25)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, count)
        XCTAssertTrue(model.finishDirectAdjustment())
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, count + 1)
        XCTAssertFalse(model.finishDirectAdjustment(), "A second mouse-up must not save twice")
        model.undo.undo(); XCTAssertEqual(model.recipe, original)
        model.undo.redo(); XCTAssertEqual(model.recipe?.exposure, 1.25)
        for region in HistogramRegion.allCases {
            XCTAssertTrue(model.beginHistogramAdjustment(region)); model.updateHistogramAdjustment(delta: 1000)
            XCTAssertEqual(region.value(in: try XCTUnwrap(model.recipe)), region.range.upperBound)
            model.cancelDirectAdjustment()
        }
        XCTAssertEqual(model.recipe?.exposure, 1.25)
        XCTAssertFalse(model.dirty)
    }

    @MainActor func testHistogramCancelSwitchAndUnrelatedEditDiscardDraft() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = try await makeModel(folder)
        defer { model.choose([], active: nil) }
        let catalog = try XCTUnwrap(model.catalog), original = model.recipe
        XCTAssertTrue(model.beginHistogramAdjustment(.shadows)); model.updateHistogramAdjustment(delta: 20)
        model.cancelDirectAdjustment(); XCTAssertEqual(model.recipe, original); XCTAssertFalse(model.dirty)
        XCTAssertTrue(model.beginHistogramAdjustment(.shadows)); model.updateHistogramAdjustment(delta: 20)
        model.changeRecipe { $0.contrast = 1.2 }
        XCTAssertEqual(model.recipe?.develop.shadows, 0)
        XCTAssertEqual(model.recipe?.contrast, 1.2)
        let history = try catalog.editHistory(photoID: "a").count
        XCTAssertTrue(model.beginHistogramAdjustment(.blacks)); model.updateHistogramAdjustment(delta: -30)
        model.choose(["b"], active: "b")
        model.updateHistogramAdjustment(delta: 50); XCTAssertFalse(model.finishDirectAdjustment())
        try await waitUntil { model.canEdit && model.activeID == "b" }
        XCTAssertEqual(model.recipe?.develop.blacks, 0)
        XCTAssertEqual(try catalog.editHistory(photoID: "a").count, history)
        let saved = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(catalog.photo("a")?.recipe))
        XCTAssertEqual(saved.develop.blacks, 0)
    }

    @MainActor func testNativeHistogramFineDragEscapePhotoChangeAndDetach() throws {
        let view = HistogramAdjustmentView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        var changes = [Double](), ends = [Bool](), begins = [HistogramRegion]()
        view.synchronize(photoID: "a", enabled: true)
        view.begin = { begins.append($0); return true }; view.change = { changes.append($0) }; view.end = { ends.append($0) }
        func event(_ type: NSEvent.EventType, _ x: Double, fine: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: x, y: 40), to: nil), modifierFlags: fine ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, 50))
        view.mouseDragged(with: try event(.leftMouseDragged, 70))
        view.mouseDragged(with: try event(.leftMouseDragged, 80, fine: true))
        XCTAssertEqual(try XCTUnwrap(changes.last), 2.1, accuracy: 1e-10)
        view.mouseUp(with: try event(.leftMouseUp, 80, fine: true))
        XCTAssertEqual(begins, [.exposure]); XCTAssertEqual(ends, [false])
        view.mouseDown(with: try event(.leftMouseDown, 5)); view.cancelOperation(nil)
        XCTAssertEqual(ends, [false, true])
        view.mouseDown(with: try event(.leftMouseDown, 20)); view.synchronize(photoID: "b", enabled: true)
        view.mouseUp(with: try event(.leftMouseUp, 60)); XCTAssertEqual(ends, [false, true, true])
        view.mouseDown(with: try event(.leftMouseDown, 95)); window.contentView = nil
        XCTAssertEqual(ends, [false, true, true, true])
    }

    @MainActor func makeModel(_ folder: URL) async throws -> AppModel {
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40))
        let cg = try XCTUnwrap(CIContext().createCGImage(ci, from: ci.extent))
        let rendered = RenderedImage(image: cg, fullSize: ci.extent.size, orientedSourceSize: ci.extent.size, histogram: nil, elapsed: 0)
        let model = AppModel(previewRenderer: { _, _, _ in rendered })
        let catalog = try CatalogStore(directory: folder), root = try catalog.addRoot(url: folder, bookmark: Data())
        let recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
            baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        for id in ["a", "b"] {
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".png", identity: Data(), identityKey: id,
                width: 80, height: 40, recipe: JSONEncoder().encode(recipe), metadata: JSONEncoder().encode(PhotoMetadata())))
        }
        model.catalog = catalog; try model.reload(); model.selectWorkspace(.develop); model.choose(["a"], active: "a")
        try await waitUntil { model.canEdit }
        return model
    }
    @MainActor private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}
