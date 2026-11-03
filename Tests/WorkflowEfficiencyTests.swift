import XCTest
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import GRDB
import SwiftUI
@testable import Phosdeck

final class WorkflowEfficiencyTests: XCTestCase {
    private var folder: URL!
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: linear])
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func request(color: CIColor = CIColor(red: 0.18, green: 0.24, blue: 0.18), patches: Bool = false) throws -> ImageRequest {
        let bounds = CGRect(x: 0, y: 0, width: 120, height: 80)
        var image = CIImage(color: color).cropped(to: bounds)
        if patches {
            image = CIImage(color: CIColor(red: 0.24, green: 0.18, blue: 0.24)).cropped(to: CGRect(x: 60, y: 0, width: 60, height: 80)).composited(over: image)
        }
        let url = folder.appendingPathComponent(UUID().uuidString + ".tiff")
        let cg = try XCTUnwrap(context.createCGImage(image, from: bounds, format: .RGBA16, colorSpace: linear))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let root = StorageRoot(id: "test", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "Synthetic")
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: folder)
        return ImageRequest(photo: photo, root: root, recipe: nil)
    }
    @MainActor private func model(_ source: ImageRequest, recipe: EditRecipe) throws -> AppModel {
        let catalog = try CatalogStore(directory: folder.appendingPathComponent(UUID().uuidString))
        try catalog.database.write { try source.root.insert($0) }; try catalog.index(source.photo)
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.roots = [source.root]; model.photos = [source.photo]
        model.activeID = source.photo.id; model.activePhoto = source.photo; model.selection = [source.photo.id]
        model.recipe = recipe; model.canEdit = true; model.dirty = true; XCTAssertTrue(model.commitRecipe())
        model.undo.removeAllActions(); model.editMode = true
        return model
    }
    @MainActor private func key(_ text: String, code: UInt16, model: AppModel, window: NSWindow) throws -> NSEvent? {
        WorkspaceKeyboard.handle(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)), model: model)
    }
    @MainActor func testViewPositionReturnsAndLockClampsAcrossAspectRatios() {
        let model = AppModel(); model.activeID = "a"; model.fullResolution = true
        model.viewport.update(image: CGSize(width: 4000, height: 3000), canvas: CGSize(width: 800, height: 600), zoomed: true)
        model.viewport.move(to: CGPoint(x: 0.7, y: 0.3)); model.activeID = "b"
        model.viewport.update(image: CGSize(width: 3000, height: 4000), canvas: CGSize(width: 800, height: 600), zoomed: true)
        XCTAssertEqual(model.viewport.center, CGPoint(x: 0.5, y: 0.5))
        model.viewport.move(to: CGPoint(x: 0.2, y: 0.8)); model.activeID = "a"
        model.viewport.update(image: CGSize(width: 4000, height: 3000), canvas: CGSize(width: 800, height: 600), zoomed: true)
        XCTAssertEqual(model.viewport.center.x, 0.7, accuracy: 0.0001); XCTAssertEqual(model.viewport.center.y, 0.3, accuracy: 0.0001)
        model.lockViewPosition = true; model.activeID = "b"
        model.viewport.update(image: CGSize(width: 300, height: 4000), canvas: CGSize(width: 800, height: 600), zoomed: true)
        XCTAssertEqual(model.viewport.center.x, 0.5); XCTAssertEqual(model.viewport.center.y, 0.3, accuracy: 0.0001)
        model.lockViewPosition = false; model.activeID = "a"
        model.viewport.update(image: CGSize(width: 4000, height: 3000), canvas: CGSize(width: 800, height: 600), zoomed: true)
        XCTAssertEqual(model.viewport.center, CGPoint(x: 0.7, y: 0.3))
    }
    @MainActor func testToolGuideKeysDeleteAndTextFocusAreIndependentOfPixels() async throws {
        let source = try request(), baseline = try await ImagePipeline().baseline(source)
        let model = try model(source, recipe: baseline)
        model.addMask(.linear); model.addMask(.brush, operation: .subtract)
        let selected = try XCTUnwrap(model.selectedComponentID), original = model.recipe
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Synthetic — Phosdeck"; defer { window.contentView = nil }
        XCTAssertNil(try key("h", code: 4, model: model, window: window)); XCTAssertFalse(model.showMaskGuides)
        XCTAssertNil(try key("o", code: 31, model: model, window: window)); XCTAssertFalse(model.showMaskOverlay)
        XCTAssertEqual(model.recipe, original)
        let text = NSTextView(); window.contentView = text; window.makeFirstResponder(text)
        XCTAssertNotNil(try key("", code: 51, model: model, window: window)); XCTAssertEqual(model.selectedComponentID, selected)
        window.makeFirstResponder(nil)
        model.undo.removeAllActions()
        model.undo.beginUndoGrouping(); XCTAssertNil(try key("", code: 51, model: model, window: window)); model.undo.endUndoGrouping()
        XCTAssertEqual(model.selectedMask?.components.count, 1); XCTAssertNil(model.selectedComponentID)
        let after = model.recipe
        XCTAssertNil(try key("", code: 51, model: model, window: window)); XCTAssertEqual(model.recipe, after, "No selection must never delete the group or photo")
        model.undo.undo(); XCTAssertEqual(model.recipe, original)
        model.setMaskMode(false); model.setSpotMode(true)
        let spotState = model.recipe
        XCTAssertNil(try key("h", code: 4, model: model, window: window)); XCTAssertFalse(model.showSpotGuides)
        XCTAssertEqual(model.recipe, spotState)
        model.setSpotMode(false)
        XCTAssertNil(try key("w", code: 13, model: model, window: window)); XCTAssertTrue(model.whiteBalanceSampling)
        XCTAssertNil(try key("", code: 53, model: model, window: window)); XCTAssertFalse(model.whiteBalanceSampling)
    }
    @MainActor func testKeywordDraftAtomicBatchMixedStateRecentAndOneUndo() async throws {
        XCTAssertEqual(try KeywordSummary.terms(" A, B，a； 上海 摄影 ;"), ["A", "B", "上海 摄影"])
        XCTAssertThrowsError(try KeywordSummary.terms("good," + String(repeating: "x", count: 101)))
        let source = try request(), baseline = try await ImagePipeline().baseline(source), model = try model(source, recipe: baseline)
        let second = Photo(id: "second", rootID: source.root.id, relativePath: "missing.jpg", identity: Data(), identityKey: "second", width: 80, height: 40)
        try model.catalog!.index(second); model.selection.insert(second.id)
        _ = try model.catalog!.changeKeyword("A", ids: [source.photo.id], adding: true); try model.reloadKeywords()
        XCTAssertEqual(model.keywords.first?.selected, 1)
        model.undo.beginUndoGrouping(); XCTAssertTrue(model.changeKeywords(try KeywordSummary.terms("A, B"), adding: true)); model.undo.endUndoGrouping()
        XCTAssertEqual(model.keywords.map(\.selected), [2, 2]); XCTAssertEqual(model.recentKeywords, ["A", "B"])
        model.undo.undo(); XCTAssertEqual(model.keywords.count, 1); XCTAssertEqual(model.keywords.first?.selected, 1)
        model.undo.redo(); XCTAssertEqual(model.keywords.map(\.selected), [2, 2])
        let previous = model.keywords
        XCTAssertThrowsError(try model.catalog!.changeKeywords(["good", "bad\nterm"], ids: model.selection, adding: true))
        XCTAssertEqual(try model.catalog!.keywordSummary(selected: model.selection), previous)
    }
    func testAlternateSpotSourceChangesLocationRejectsTransparentAndHonorsCancellation() async throws {
        let size = 100, gray = SIMD3<Float>(repeating: 0.3)
        let image = SpotBuffer(width: size, height: size, pixels: Array(repeating: gray, count: size*size))
        let repair = SpotRepair(points: [MaskPoint(0.5, 0.5), MaskPoint(0.5, 0.55)], radius: 0.04)
        let initial = SpotRepairMath.pickOffset(in: image, repair: repair)
        let next = try XCTUnwrap(try SpotRepairMath.alternateSource(in: image, repairs: [repair], selected: repair.id, avoiding: initial))
        XCTAssertGreaterThan(hypot((next.x-initial.x)*100, (next.y-initial.y)*100), 4)
        var transparent = image; transparent.alpha = Array(repeating: 0, count: 10000)
        XCTAssertNil(try SpotRepairMath.alternateSource(in: transparent, repairs: [repair], selected: repair.id, avoiding: initial))
        // Source annuli can be opaque while the center contains a transparent hole.
        var holes = image; holes.alpha = Array(repeating: 1, count: size*size)
        for ring in [2.4, 3.2, 4.2] {
            for n in 0..<16 {
                let angle = Double(n) / 16 * 2 * Double.pi
                let x = 50 + cos(angle) * 4 * ring, y = 50 + sin(angle) * 4 * ring
                for yy in Int(floor(y))-1...Int(ceil(y))+1 {
                    for xx in Int(floor(x))-1...Int(ceil(x))+1 { holes.alpha![yy*size+xx] = 0 }
                }
            }
        }
        XCTAssertNil(try SpotRepairMath.alternateSource(in: holes, repairs: [repair], selected: repair.id, avoiding: initial), "A transparent hole inside the source footprint must be rejected")
        let task = Task { try Task.checkCancellation(); return try SpotRepairMath.alternateSource(in: image, repairs: [repair], selected: repair.id, avoiding: initial) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled source search must throw") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
    func testWhiteBalanceNeutralizesRasterAndIgnoresCreativeEditsThroughGeometry() async throws {
        let source = try request(patches: true), pipeline = ImagePipeline()
        let baseline = try await pipeline.baseline(source), point = CGPoint(x: 0.25, y: 0.5)
        let expected = try await pipeline.sampledWhiteBalance(ImageRequest(photo: source.photo, root: source.root, recipe: baseline), at: point)
        var geometry = baseline; geometry.quarterTurns = 1; geometry.flipHorizontal = true; geometry.flipVertical = true
        geometry.straightenDegrees = 3; geometry.perspective = PerspectiveSettings(horizontal: 8, vertical: -5, aspect: 2)
        geometry.crop = Crop(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        geometry.exposure = 4; geometry.saturation = 0; geometry.develop.blackAndWhite = true; geometry.develop.grading.highlights.saturation = 30
        let mapping = MaskGeometry.mapping(size: CGSize(width: 120, height: 80), recipe: geometry)
        let out = try XCTUnwrap(mapping.transform.point(CGPoint(x: 30, y: 40)))
        let sampled = try await pipeline.sampledWhiteBalance(ImageRequest(photo: source.photo, root: source.root, recipe: geometry), at: CGPoint(x: out.x/mapping.output.width, y: out.y/mapping.output.height))
        XCTAssertEqual(expected.temperature, sampled.temperature, accuracy: 1); XCTAssertEqual(expected.tint, sampled.tint, accuracy: 0.1)
        var adjusted = baseline; adjusted.asShotWhiteBalance = false; adjusted.temperature = sampled.temperature; adjusted.tint = sampled.tint
        let rank = try await pipeline.linearRank(ImageRequest(photo: source.photo, root: source.root, recipe: adjusted), longEdge: 1024)
        let color = try WhiteBalanceSampling.mean(SpotRepairPipeline.image(rank), at: MaskPoint(point.x, point.y), context: context, rejectClipped: false)
        XCTAssertLessThan(abs(log(color.x/color.y)), 0.015); XCTAssertLessThan(abs(log(color.z/color.y)), 0.015)
    }
    func testWhiteBalanceRejectsTransparentClippedDarkAndUnreachableSamples() async throws {
        for color in [CIColor.clear, CIColor.white, CIColor.black, CIColor.red] {
            let source = try request(color: color), pipeline = ImagePipeline(), baseline = try await pipeline.baseline(source)
            do { _ = try await pipeline.sampledWhiteBalance(ImageRequest(photo: source.photo, root: source.root, recipe: baseline), at: CGPoint(x: 0.5, y: 0.5)); XCTFail("Unsuitable sample \(color)") } catch {}
        }
    }
}

extension WorkflowEfficiencyTests {
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("工作流任务未完成"); throw LRCError("工作流任务未完成")
    }
    @MainActor func testWhiteBalanceSingleContinuousUndoAndCancelOnPhotoChange() async throws {
        let source = try request(patches: true), baseline = try await ImagePipeline().baseline(source), model = try model(source, recipe: baseline)
        model.toggleWhiteBalanceSampling(); XCTAssertTrue(model.whiteBalanceSampling)
        model.sampleWhiteBalance(at: CGPoint(x: 0.25, y: 0.5))
        try await waitUntil { !model.whiteBalanceSamplingBusy }
        XCTAssertFalse(model.whiteBalanceSampling); XCTAssertFalse(try XCTUnwrap(model.recipe).asShotWhiteBalance)
        XCTAssertNotEqual(model.recipe?.tint, baseline.tint)
        model.undo.undo(); XCTAssertEqual(model.recipe, baseline)
        model.whiteBalanceContinuous = true; model.toggleWhiteBalanceSampling()
        model.sampleWhiteBalance(at: CGPoint(x: 0.75, y: 0.5))
        try await waitUntil { !model.whiteBalanceSamplingBusy }
        XCTAssertTrue(model.whiteBalanceSampling)
        let saved = model.recipe
        model.sampleWhiteBalance(at: CGPoint(x: 0.25, y: 0.5)); XCTAssertTrue(model.whiteBalanceSamplingBusy)
        model.activeID = "another-photo"
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(model.whiteBalanceSampling); XCTAssertEqual(model.recipe, saved, "A late result must never write onto another photo")
    }
    @MainActor func testRefreshSourceCommitsOneUndoAndDiscardsChangedRecipe() async throws {
        let source = try request(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
        var baseline = try await ImagePipeline().baseline(source)
        let spot = SpotRepair(points: [MaskPoint(0.5, 0.5)], radius: 0.04, sourceOffset: MaskPoint(0.12, 0))
        baseline.repairs = [spot]
        let model = try model(source, recipe: baseline)
        model.spotMode = true; model.selectSpot(spot.id); model.refreshSpotSource()
        try await waitUntil { !model.refreshingSpotSource }
        let next = try XCTUnwrap(model.recipe?.repairs.first)
        XCTAssertNotEqual(next.sourceOffset, spot.sourceOffset); XCTAssertEqual(next.points, spot.points)
        model.undo.undo(); XCTAssertEqual(model.recipe, baseline)
        model.undo.redo(); XCTAssertEqual(model.recipe?.repairs.first, next)
        model.refreshSpotSource()
        model.changeRecipe({ $0.exposure = 0.5 }, title: "曝光")
        let changed = model.recipe
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(model.recipe, changed); XCTAssertFalse(model.refreshingSpotSource)
        model.setSpotMode(false)
    }
    func testPublicRAWWhiteBalanceMatchesItsOwnForwardDecode() async throws {
        let pipeline = ImagePipeline()
        for name in ["a7iii_12bit_compressed.ARW", "canon_m50_craw.CR3", "fuji_xt20_14bit_lossless.RAF"] {
            let source = try MoreRAWTests.request(name), baseline = try await pipeline.baseline(source)
            var succeeded = false
            for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.75, y: 0.5), CGPoint(x: 0.5, y: 0.25), CGPoint(x: 0.5, y: 0.75)] {
                let value: WhiteBalanceValue
                do { value = try await pipeline.sampledWhiteBalance(ImageRequest(photo: source.photo, root: source.root, recipe: baseline), at: point) }
                catch { continue }
                var adjusted = baseline; adjusted.asShotWhiteBalance = false; adjusted.temperature = value.temperature; adjusted.tint = value.tint
                let rank = try await pipeline.linearRank(ImageRequest(photo: source.photo, root: source.root, recipe: adjusted), longEdge: 1024)
                let c = try WhiteBalanceSampling.mean(SpotRepairPipeline.image(rank), at: MaskPoint(point.x, point.y), context: context, rejectClipped: false)
                XCTAssertLessThan(abs(log(c.x/c.y)), 0.02, name); XCTAssertLessThan(abs(log(c.z/c.y)), 0.02, name)
                XCTAssertEqual(try SafeFileWriter.sha256(MoreRAWTests.sample(name)), baseline.sourceDigest)
                print("WB_RAW sample=\(name) point=\(point) temperature=\(value.temperature) tint=\(value.tint) residual=\(c)")
                succeeded = true; break
            }
            XCTAssertTrue(succeeded, "No usable WB sample on \(name)")
        }
    }
}

extension WorkflowEfficiencyTests {
    @MainActor func testNewControlSnapshotsAndBoundLongKeywordDraft() async throws {
        let source = try request(), baseline = try await ImagePipeline().baseline(source), model = try model(source, recipe: baseline)
        let suite = "workflow4-layout-" + UUID().uuidString, prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        model.recentKeywords = (1...12).map { "最近使用的长关键词 \($0)" }
        var r = baseline; r.localAdjustments = [LocalAdjustment(components: [MaskComponent(tool: .linear), MaskComponent(tool: .brush, operation: .subtract)])]
        r.repairs = [SpotRepair(points: [MaskPoint(0.5, 0.5)], sourceOffset: MaskPoint(0.1, 0))]
        model.recipe = r; model.selectedMaskID = r.localAdjustments[0].id; model.selectedComponentID = r.localAdjustments[0].components[1].id
        model.selectedSpotID = r.repairs[0].id; model.whiteBalanceSampling = true
        prefs.set(true, forKey: "developBasicOpen")
        for theme in [ChromeTheme.ivory, .graphite] {
            prefs.set(theme.rawValue, forKey: "chromeTheme")
            let forms: [(String, AnyView, CGSize)] = [
                ("white-balance", AnyView(ScrollView { DevelopPanel(model: model) }), CGSize(width: 260, height: 536)),
                ("mask-actions", AnyView(MaskPanel(model: model)), CGSize(width: 260, height: 536)),
                ("repair-actions", AnyView(SpotPanel(model: model)), CGSize(width: 260, height: 536)),
                ("keyword-draft", AnyView(KeywordEditor(model: model)), CGSize(width: 390, height: 560))]
            for (name, form, size) in forms {
                // The workspace proposes a fixed inspector width. An unconstrained
                // fittingSize instead measures the full scroll content's ideal size.
                let proposed = name == "keyword-draft" ? form : AnyView(form.frame(width: size.width, height: size.height))
                let host = NSHostingView(rootView: proposed.background(Theme.panel).defaultAppStorage(prefs).preferredColorScheme(theme.colorScheme))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua); window.contentView = host
                try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
                if name == "keyword-draft" {
                    func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
                    let field = try XCTUnwrap(fields(host).first { $0.placeholderString == "输入或查找关键词" })
                    XCTAssertTrue(window.makeFirstResponder(field))
                    let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                    editor.insertText((1...64).map { String(repeating: "长", count: 97) + String($0) }.joined(separator: ", "), replacementRange: NSRange(location: 0, length: 0))
                    try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
                }
                XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, name)
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1, name)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "workflow4-\(name)-\(theme.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
                window.contentView = nil
            }
        }
    }
}
