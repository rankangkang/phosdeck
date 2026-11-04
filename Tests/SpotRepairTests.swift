import XCTest
import CoreImage
import AppKit
@testable import Phosdeck

final class SpotRepairTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
    private var linear: CGColorSpace { CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! }

    private func recipe() -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }
    private func buffer(width: Int, height: Int, _ fill: (Int, Int) -> Float) -> SpotBuffer {
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value = fill(x, y)
                pixels.append(SIMD3(value, value, value))
            }
        }
        return SpotBuffer(width: width, height: height, pixels: pixels)
    }
    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> Float {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return data[0]
    }

    func testCoverageWeightedBilinearSamplingIgnoresTransparentColors() {
        let image = SpotBuffer(width: 2, height: 2,
            pixels: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(repeating: 9)],
            alpha: [1, 0.5, 0.25, 0])
        let sampled = image.sample(0.25, 0.5)
        XCTAssertEqual(sampled.x, 12.0 / 17.0, accuracy: 1e-6)
        XCTAssertEqual(sampled.y, 2.0 / 17.0, accuracy: 1e-6)
        XCTAssertEqual(sampled.z, 3.0 / 17.0, accuracy: 1e-6)
        XCTAssertEqual(image.sample(1, 1), .zero)
        var opaque = image
        opaque.alpha = nil
        var covered = opaque
        covered.alpha = [1, 1, 1, 1]
        XCTAssertEqual(covered.sample(0.25, 0.5), opaque.sample(0.25, 0.5))
    }

    func testBitmapKeepsBottomLeft() throws {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = red.composited(over: black)
        let buffer = try SpotRepairPipeline.buffer(image, context: context)
        XCTAssertEqual(buffer.pixels[0].x, 1, accuracy: 0.01, "CI y=0 is the bottom row of the buffer")
        XCTAssertEqual(buffer.pixels[3 * 4].x, 0, accuracy: 0.01)
        let back = try SpotRepairPipeline.image(buffer)
        XCTAssertEqual(pixel(back, 0, 0), 1, accuracy: 0.01)
        XCTAssertEqual(pixel(back, 0, 3), 0, accuracy: 0.01)
    }

    func testRemoveErasesADotWithoutTouchingTheFile() throws {
        let image = buffer(width: 120, height: 80) { x, y in
            (56..<64).contains(x) && (36..<44).contains(y) ? 0 : 0.2 + Float(x) * 0.001
        }
        let repair = SpotRepair(mode: .remove, points: [MaskPoint(0.5, 0.5)], radius: 0.1, feather: 0.3)
        let rendered = SpotRepairMath.render(image, repairs: [repair])
        let center = rendered.buffer.pixels[40 * 120 + 60].x
        XCTAssertEqual(center, 0.26, accuracy: 0.03, "center \(center)")
        var hidden = repair
        hidden.enabled = false
        XCTAssertEqual(SpotRepairMath.render(image, repairs: [hidden]).buffer.pixels[40 * 120 + 60].x, 0, accuracy: 0.001)
        XCTAssertEqual(SpotRepairMath.render(image, repairs: []).buffer.pixels[40 * 120 + 60].x, 0, accuracy: 0.001)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try SpotRepairPipeline.image(image)
        try context.writeTIFFRepresentation(of: source, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
        let before = try Data(contentsOf: url)
        _ = try SpotRepairPipeline.apply(CIImage(contentsOf: url)!, repairs: [repair], context: context)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testCloneCopiesSourceAndHealKeepsSurroundings() {
        let cloneSource = buffer(width: 100, height: 100) { x, _ in x < 50 ? 0.1 : 0.9 }
        let clone = SpotRepair(mode: .clone, points: [MaskPoint(0.25, 0.5)], radius: 0.05, feather: 0, sourceOffset: MaskPoint(0.5, 0))
        let copied = SpotRepairMath.render(cloneSource, repairs: [clone]).buffer
        XCTAssertGreaterThan(copied.pixels[50 * 100 + 25].x, 0.8)
        XCTAssertLessThan(copied.pixels[50 * 100 + 5].x, 0.2)

        let scene = buffer(width: 100, height: 100) { x, y in
            if x >= 50 {
                return x == 77 && (47..<53).contains(y) ? 1 : 0.8
            }
            return (22..<28).contains(x) && (47..<53).contains(y) ? 0 : 0.35
        }
        let heal = SpotRepair(mode: .heal, points: [MaskPoint(0.25, 0.5)], radius: 0.08, feather: 0, sourceOffset: MaskPoint(0.5, 0))
        var cloned = heal
        cloned.mode = .clone
        let healed = SpotRepairMath.render(scene, repairs: [heal]).buffer.pixels
        let clonedPixels = SpotRepairMath.render(scene, repairs: [cloned]).buffer.pixels
        let healCenter = healed[50 * 100 + 25].x
        XCTAssertEqual(healCenter, 0.35, accuracy: 0.08)
        XCTAssertGreaterThan(healed[50 * 100 + 27].x, healCenter + 0.08, "the source stripe stays visible")
        XCTAssertGreaterThan(clonedPixels[50 * 100 + 25].x, 0.7)
    }

    func testOrderChangesOverlappingRepairs() {
        var image = buffer(width: 40, height: 40) { _, _ in 0.2 }
        for y in 18...22 {
            for x in 8...12 { image.set(x, y, SIMD3(repeating: 1)) }
            for x in 28...32 { image.set(x, y, SIMD3(repeating: 0)) }
        }
        let target = MaskPoint(0.5, 0.5)
        let fromLeft = SpotRepair(mode: .clone, points: [target], radius: 0.05, feather: 0, sourceOffset: MaskPoint(-0.25, 0))
        let fromRight = SpotRepair(mode: .clone, points: [target], radius: 0.05, feather: 0, sourceOffset: MaskPoint(0.25, 0))
        let leftThenRight = SpotRepairMath.render(image, repairs: [fromLeft, fromRight]).buffer.pixels[20 * 40 + 20].x
        let rightThenLeft = SpotRepairMath.render(image, repairs: [fromRight, fromLeft]).buffer.pixels[20 * 40 + 20].x
        XCTAssertLessThan(leftThenRight, 0.05)
        XCTAssertGreaterThan(rightThenLeft, 0.9)
    }

    func testRepairSurvivesCropAndQuarterTurn() throws {
        var pixels = buffer(width: 40, height: 40) { _, _ in 0.2 }
        for y in 18..<22 { for x in 18..<22 { pixels.set(x, y, .zero) } }
        let repair = SpotRepair(mode: .remove, points: [MaskPoint(0.5, 0.5)], radius: 0.15, feather: 0.3)
        let rendered = SpotRepairMath.render(pixels, repairs: [repair])
        XCTAssertGreaterThan(rendered.buffer.pixels[20 * 40 + 20].x, 0.1)
        XCTAssertEqual(repair.points, [MaskPoint(0.5, 0.5)])
        XCTAssertNil(repair.sourceOffset)
        var recipe = recipe()
        recipe.quarterTurns = 1
        recipe.crop = Crop(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let mapping = MaskGeometry.mapping(size: CGSize(width: 40, height: 40), recipe: recipe)
        let mapped = CGPoint(x: 20.5, y: 20.5).applying(mapping.transform)
        let x = Int(mapped.x.rounded(.down)), y = Int(mapped.y.rounded(.down))
        let repaired = try ImagePipeline.geometry(try SpotRepairPipeline.image(rendered.buffer), recipe: recipe)
        let original = try ImagePipeline.geometry(try SpotRepairPipeline.image(pixels), recipe: recipe)
        func darkest(_ image: CIImage) -> Float {
            (0...2).flatMap { dy in (0...2).map { dx in pixel(image, x + dx - 1, y + dy - 1) } }.min() ?? 1
        }
        XCTAssertLessThan(darkest(original), 0.05, "mapped \(x),\(y)")
        XCTAssertGreaterThan(darkest(repaired), 0.1, "mapped \(x),\(y)")
    }

    func testTwoSizesShareTheNormalizedOffset() {
        let width = 512, height = 384
        var small = buffer(width: width, height: height) { x, _ in 0.2 + Float(x) * 0.0002 }
        for y in (height / 2 - 8)..<(height / 2 + 8) {
            for x in (width / 2 - 8)..<(width / 2 + 8) { small.set(x, y, .zero) }
        }
        var largePixels = [SIMD3<Float>](repeating: .zero, count: width * 2 * height * 2)
        for y in 0..<(height * 2) {
            for x in 0..<(width * 2) {
                largePixels[y * width * 2 + x] = small.pixels[(y / 2) * width + x / 2]
            }
        }
        let large = SpotBuffer(width: width * 2, height: height * 2, pixels: largePixels)
        let smallRepair = SpotRepair(mode: .remove, points: [MaskPoint(0.5, 0.5)], radius: 0.05, feather: 0.3)
        var largeRepair = smallRepair
        largeRepair.id = UUID()
        let smallRendered = SpotRepairMath.render(small, repairs: [smallRepair])
        let largeRendered = SpotRepairMath.render(large, repairs: [largeRepair])
        let smallOffset = smallRendered.offsets[smallRepair.id]!
        let largeOffset = largeRendered.offsets[largeRepair.id]!
        let smallCenter = smallRendered.buffer.pixels[(height / 2) * width + width / 2].x
        let largeCenter = largeRendered.buffer.pixels[height * width * 2 + width].x
        let delta = abs(smallCenter - largeCenter)
        print(String(format: "spot-repair two-size center delta %.6f offset (%.6f, %.6f)", delta, smallOffset.x, smallOffset.y))
        XCTAssertEqual(smallOffset.x, largeOffset.x, accuracy: 0.0001)
        XCTAssertEqual(smallOffset.y, largeOffset.y, accuracy: 0.0001)
        XCTAssertGreaterThan(smallCenter, 0.1)
        XCTAssertGreaterThan(largeCenter, 0.1)
    }

    @MainActor func testRecipeRoundTripUndoAndPaste() throws {
        var value = recipe()
        let repair = SpotRepair(points: [MaskPoint(0.2, 0.4), MaskPoint(0.3, 0.4)], radius: 0.05, feather: 0.2, opacity: 0.8, sourceOffset: MaskPoint(0.1, -0.05))
        value.repairs = [repair]
        let encoded = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["repairs"])
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: encoded).repairs, [repair])
        var legacy = object
        legacy.removeValue(forKey: "repairs")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: legacy)).repairs, [])
        XCTAssertEqual(value.pipelineVersion, 2)
        XCTAssertTrue(value.baseline().repairs.isEmpty)
        XCTAssertTrue(value.resetForCurrentPipeline().repairs.isEmpty)
        XCTAssertTrue(value.alignedBaseline().repairs.isEmpty)
        XCTAssertTrue(value.changeTitle(from: recipe()).contains("污点修复"))
        var target = recipe()
        target.repairs = [SpotRepair(points: [MaskPoint(0.8, 0.8)])]
        XCTAssertEqual(try target.pasting(value, options: RecipePasteOptions()).repairs, target.repairs)
        var invalid = repair
        invalid.feather = .nan
        XCTAssertThrowsError(try invalid.validate())
        value.repairs = [invalid]
        XCTAssertThrowsError(try value.validate())
        value.repairs = (0..<129).map { _ in SpotRepair(points: [MaskPoint(0.2, 0.2)]) }
        XCTAssertThrowsError(try value.validate())
        let shared = UUID()
        value.repairs = [SpotRepair(id: shared, points: [MaskPoint(0.2, 0.2)]), SpotRepair(id: shared, points: [MaskPoint(0.4, 0.4)])]
        XCTAssertThrowsError(try value.validate())

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory.appendingPathComponent("source"), bookmark: Data())
        let photo = Photo(id: "spot", rootID: root.id, relativePath: "sample.ARW", identity: Data(), identityKey: "spot-fixture", width: 80, height: 80)
        try catalog.index(photo)
        let model = AppModel(previewRenderer: { _, _, _ in
            throw CancellationError()
        })
        model.catalog = catalog
        model.activeID = photo.id
        model.recipe = recipe()
        model.canEdit = true
        model.dirty = true
        model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.commitRecipe())
        model.undo.endUndoGrouping()
        let original = try XCTUnwrap(model.recipe)
        let rank = buffer(width: 80, height: 80) { x, _ in 0.2 + Float(x) * 0.002 }
        model.spotMode = true
        model.spotRank = rank
        model.orientedSourceSize = CGSize(width: 80, height: 80)
        model.undo.beginUndoGrouping()
        model.spotPointer(CGPoint(x: 0.5, y: 0.5), phase: .down)
        model.spotPointer(CGPoint(x: 0.58, y: 0.5), phase: .drag)
        model.spotPointer(CGPoint(x: 0.58, y: 0.5), phase: .up)
        model.undo.endUndoGrouping()
        let painted = try XCTUnwrap(model.recipe?.repairs.first)
        XCTAssertEqual(painted.mode, .heal)
        XCTAssertGreaterThan(painted.points.count, 1)
        XCTAssertNotNil(painted.sourceOffset)
        model.undo.undo()
        XCTAssertEqual(model.recipe?.repairs, original.repairs)
        model.undo.redo()
        let redone = try XCTUnwrap(model.recipe?.repairs.first)
        model.undo.beginUndoGrouping()
        model.toggleSpot(redone.id)
        model.undo.endUndoGrouping()
        XCTAssertEqual(model.recipe?.repairs.first?.enabled, false)
        model.undo.beginUndoGrouping()
        model.deleteSpot(redone.id)
        model.undo.endUndoGrouping()
        XCTAssertEqual(model.recipe?.repairs, [])
        model.undo.undo()
        XCTAssertEqual(model.recipe?.repairs.count, 1)
    }

    @MainActor func testSpotKeysResizeTheSpotNotTheMaskBrush() throws {
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Phosdeck"
        func key(_ text: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        model.editMode = true
        model.canEdit = true
        model.spotMode = true
        model.spotRadius = 0.04
        model.brushRadius = 0.04
        XCTAssertNil(WorkspaceKeyboard.handle(try key("]", code: 30), model: model))
        XCTAssertEqual(model.spotRadius, 0.048, accuracy: 0.0001)
        XCTAssertEqual(model.brushRadius, 0.04)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("\u{1b}", code: 53), model: model))
        XCTAssertFalse(model.spotMode)
        withExtendedLifetime(window) {}
    }

    func testSpotOutlineFollowsTheOuterEdgeAndTheSourceMatches() throws {
        let radius: CGFloat = 10
        let spine = [CGPoint(x: 20, y: 30), CGPoint(x: 70, y: 30), CGPoint(x: 50, y: 32), CGPoint(x: 90, y: 36)]
        let outline = SpotOutline.make(points: spine, radius: radius)
        XCTAssertEqual(outline.loops.count, 1)
        XCTAssertTrue(outline.contains(CGPoint(x: 20, y: 30)))
        XCTAssertFalse(outline.contains(CGPoint(x: 20, y: 30 + radius + 6)))
        for point in outline.loops[0] {
            let distance = spineDistance(point, spine)
            XCTAssertGreaterThan(distance, radius * 0.55)
            XCTAssertLessThan(distance, radius * 1.45)
        }
        let shifted = outline.translated(dx: 40, dy: -15)
        for (point, moved) in zip(outline.loops[0], shifted.loops[0]) {
            XCTAssertEqual(moved.x, point.x + 40, accuracy: 0.01)
            XCTAssertEqual(moved.y, point.y - 15, accuracy: 0.01)
        }
        let dot = SpotOutline.make(points: [CGPoint(x: 5, y: 5)], radius: 8)
        let ends = dot.bridge(from: CGPoint(x: 5, y: 5), dx: 30, dy: 0)
        let bridge = try XCTUnwrap(ends)
        XCTAssertEqual(bridge.0.x, 13, accuracy: 1)
        XCTAssertEqual(bridge.1.x, 27, accuracy: 1)
        let arrow = try XCTUnwrap(SpotArrow.make(from: bridge.1, to: bridge.0, length: 6))
        XCTAssertEqual(arrow.tail.x, bridge.1.x, accuracy: 0.01)
        XCTAssertEqual(arrow.tip.x, bridge.0.x, accuracy: 0.01)
        XCTAssertGreaterThan(arrow.left.x, arrow.tip.x)
        XCTAssertGreaterThan(arrow.right.x, arrow.tip.x)
        XCTAssertNotEqual(arrow.left.y, arrow.right.y)
        XCTAssertNil(SpotArrow.make(from: .zero, to: CGPoint(x: 0.2, y: 0), length: 6))
    }

    @MainActor func testSpotStrokeReachesTheRecipeOnlyOnRelease() throws {
        let model = AppModel()
        model.canEdit = true
        model.spotMode = true
        model.recipe = recipe()
        model.orientedSourceSize = CGSize(width: 80, height: 80)
        model.spotRank = buffer(width: 80, height: 80) { x, _ in 0.2 + Float(x) * 0.002 }
        model.spotPointer(CGPoint(x: 0.5, y: 0.5), phase: .down)
        model.spotPointer(CGPoint(x: 0.58, y: 0.5), phase: .drag)
        XCTAssertEqual(model.recipe?.repairs.count, 0)
        XCTAssertGreaterThan(model.spotCanvasDraft?.points.count ?? 0, 1)
        model.spotPointer(CGPoint(x: 0.58, y: 0.5), phase: .up)
        let painted = try XCTUnwrap(model.recipe?.repairs.first)
        XCTAssertGreaterThan(painted.points.count, 1)
        XCTAssertNotNil(painted.sourceOffset)
        model.dirty = false
        let snapshot = model.recipe
        model.spotPointer(CGPoint(x: 0.5, y: 0.5), phase: .down)
        model.spotPointer(CGPoint(x: 0.62, y: 0.5), phase: .drag)
        XCTAssertEqual(model.recipe, snapshot)
        XCTAssertNotNil(model.spotCanvasDraft)
        model.spotPointer(CGPoint(x: 0.62, y: 0.5), phase: .up)
        XCTAssertNotEqual(model.recipe, snapshot)
    }

    private func spineDistance(_ point: CGPoint, _ spine: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for index in spine.indices.dropLast() {
            let start = spine[index], end = spine[index + 1]
            let dx = end.x - start.x, dy = end.y - start.y
            let length = dx * dx + dy * dy
            let t = length < 1e-8 ? 0 : min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
            best = min(best, hypot(point.x - (start.x + dx * t), point.y - (start.y + dy * t)))
        }
        return best
    }

    func testSpotMarkerHitDoesNotUseTheBrushRadius() {
        let marker = SpotRepair(points: [MaskPoint(0.2, 0.2)], radius: 0.2)
        let selected = SpotRepair(points: [MaskPoint(0.8, 0.8)], radius: 0.05, sourceOffset: MaskPoint(0.1, 0))
        let size = CGSize(width: 100, height: 100)
        let offsets = [selected.id: MaskPoint(0.1, 0)]
        let besideDot = MaskPoint(0.35, 0.2)
        XCTAssertNil(SpotPlacement.hit(point: besideDot, size: size, repairs: [marker, selected], selectedID: selected.id, offsets: offsets, markerRadius: 8))
        let onDot = SpotPlacement.hit(point: MaskPoint(0.24, 0.2), size: size, repairs: [marker, selected], selectedID: selected.id, offsets: offsets, markerRadius: 8)
        XCTAssertEqual(onDot?.id, marker.id)
        XCTAssertEqual(onDot?.action, .move)
        let onBody = SpotPlacement.hit(point: MaskPoint(0.8, 0.8), size: size, repairs: [marker, selected], selectedID: selected.id, offsets: offsets, markerRadius: 8)
        XCTAssertEqual(onBody?.id, selected.id)
        XCTAssertEqual(onBody?.action, .move)
        let onSource = SpotPlacement.hit(point: MaskPoint(0.9, 0.8), size: size, repairs: [marker, selected], selectedID: selected.id, offsets: offsets, markerRadius: 8)
        XCTAssertEqual(onSource?.id, selected.id)
        XCTAssertEqual(onSource?.action, .source)
    }

    func testSpotSourceHitUsesTheWholeStrokeAndRemoveUsesThePin() {
        let repair = SpotRepair(mode: .clone, points: [MaskPoint(0.2, 0.5), MaskPoint(0.6, 0.5)], radius: 0.05, sourceOffset: MaskPoint(0, 0.2))
        let size = CGSize(width: 100, height: 100)
        let offsets = [repair.id: MaskPoint(0, 0.2)]
        let laterSource = SpotPlacement.hit(point: MaskPoint(0.6, 0.7), size: size, repairs: [repair], selectedID: repair.id, offsets: offsets, markerRadius: 8)
        XCTAssertEqual(laterSource?.action, .source)
        let onTarget = SpotPlacement.hit(point: MaskPoint(0.6, 0.5), size: size, repairs: [repair], selectedID: repair.id, offsets: offsets, markerRadius: 8)
        XCTAssertEqual(onTarget?.action, .move)

        var remove = repair
        remove.mode = .remove
        let removeSource = SpotPlacement.hit(point: MaskPoint(0.6, 0.7), size: size, repairs: [remove], selectedID: remove.id, offsets: offsets, markerRadius: 8)
        XCTAssertEqual(removeSource?.action, .source)
        let onRemoveTarget = SpotPlacement.hit(point: MaskPoint(0.6, 0.5), size: size, repairs: [remove], selectedID: remove.id, offsets: offsets, markerRadius: 8)
        XCTAssertEqual(onRemoveTarget?.action, .move)
    }

    func testSpotMoveKeepsTheOffsetForEveryMode() {
        let points = [MaskPoint(0.4, 0.4), MaskPoint(0.5, 0.4)]
        let delta = MaskPoint(0.1, 0)
        let offset = MaskPoint(0.2, 0.1)
        for mode in [SpotRepairMode.clone, .heal, .remove] {
            let moved = SpotPlacement.moved(originalPoints: points, delta: delta, pinnedOffset: mode == .remove ? nil : offset)
            XCTAssertEqual(moved.points[0].x, 0.5, accuracy: 1e-9)
            if mode == .remove { XCTAssertNil(moved.offset) }
            else { XCTAssertEqual(moved.offset?.x ?? -1, 0.2, accuracy: 1e-9) }
        }
        let dragged = SpotPlacement.sourced(displayedOffset: offset, from: MaskPoint(0.6, 0.5), to: MaskPoint(0.7, 0.55))
        XCTAssertEqual(dragged.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(dragged.y, 0.15, accuracy: 1e-9)
    }

    func testPinnedTailMatchesRenderingTheWholeList() throws {
        let image = buffer(width: 80, height: 40) { x, _ in x < 40 ? 0.2 : 0.8 }
        let first = SpotRepair(mode: .clone, points: [MaskPoint(0.25, 0.5)], radius: 0.08, feather: 0, sourceOffset: MaskPoint(0.5, 0))
        let second = SpotRepair(mode: .heal, points: [MaskPoint(0.75, 0.5)], radius: 0.08, feather: 0, sourceOffset: MaskPoint(-0.5, 0))
        let full = SpotRepairMath.render(image, repairs: [first, second])
        let head = SpotRepairMath.render(image, repairs: [first])
        let tail = SpotRepairMath.renderPinned(from: head.buffer, repairs: [second])
        let resumed = try XCTUnwrap(tail)
        XCTAssertEqual(resumed.buffer.pixels[20 * 80 + 60].x, full.buffer.pixels[20 * 80 + 60].x, accuracy: 0.0001)
        XCTAssertEqual(resumed.buffer.pixels[20 * 80 + 20].x, full.buffer.pixels[20 * 80 + 20].x, accuracy: 0.0001)
    }

    func testSpotSampleLinkStopsAtThePin() throws {
        let circle = SpotOutline.make(points: [CGPoint(x: 20, y: 20)], radius: 10)
        let link = try XCTUnwrap(circle.link(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 60, y: 20), clearance: 5))
        XCTAssertEqual(link.0.x, 30, accuracy: 1)
        XCTAssertEqual(link.1.x, 55, accuracy: 0.01)
        XCTAssertNil(circle.link(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 24, y: 20), clearance: 4))
    }
}
