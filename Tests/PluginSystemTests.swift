import CoreImage
import GRDB
import ImageIO
import PhosdeckPluginKit
import UniformTypeIdentifiers
import XCTest
@testable import Phosdeck

final class PluginSystemTests: XCTestCase {
    func testFloatStagePreservesRowOrderAndStraightAlpha() throws {
        let frame = try PluginFrame(width: 2, height: 2)
        let colors: [SIMD4<Float>] = [SIMD4(1.4, 0.2, -0.1, 0.5), .zero, SIMD4(0.2, 0.4, 0.8, 1), SIMD4(0.8, 0.4, 0.2, 1)]
        let input = try PluginImage(frame: frame, pixels: colors.withUnsafeBytes { Data($0) })
        try frame.verify(input.pixels)
        let singlePixel = try PluginFrame(width: 1, height: 1)
        for pixel in [SIMD4<Float>(.nan, 0, 0, 1), SIMD4(0, .infinity, 0, 1), SIMD4(0, 0, 0, .nan),
                      SIMD4(0, 0, 0, 1.01), SIMD4(0.001, 0, 0, 0)] {
            XCTAssertThrowsError(try singlePixel.verify(withUnsafeBytes(of: pixel) { Data($0) })) { error in
                XCTAssertEqual(error as? PluginFailure, .invalidImage)
            }
        }
        let stage = ImagePipeline.pluginImage(input)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        var received = [SIMD4<Float>](repeating: .zero, count: frame.count)
        try received.withUnsafeMutableBytes { buffer in
            let destination = CIRenderDestination(bitmapData: buffer.baseAddress!, width: frame.width, height: frame.height,
                                                  bytesPerRow: frame.rowBytes, format: .RGBAf)
            destination.colorSpace = space
            destination.alphaMode = .unpremultiplied
            destination.isFlipped = true
            _ = try context.startTask(toRender: stage, from: stage.extent, to: destination, at: .zero).waitUntilCompleted()
        }
        for (actual, expected) in zip(received, colors) {
            for i in 0..<4 { XCTAssertEqual(actual[i], expected[i], accuracy: 0.0005) }
        }
    }

    func testBundledToolsDeclareTheHostsExtensionPoint() throws {
        let host = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let point = host + ".PhotoTool"
        let extensions = Bundle.main.bundleURL.appending(path: "Contents/Extensions")
        let declarations = try Data(contentsOf: extensions.appending(path: "Phosdeck.appexpt"))
        let plist = try PropertyListSerialization.propertyList(from: declarations, format: nil)
        let bindings = try XCTUnwrap(plist as? [String: Any])
        XCTAssertEqual((bindings[point] as? [String: String])?["EXExtensionPointName"], "PhotoTool")

        for (name, key) in [("PhosdeckSoftProof", "soft-proof"), ("PhosdeckHighlights", "select-highlights"),
                            ("PhosdeckWarmPrint", "warm-print")] {
            let bundle = try XCTUnwrap(Bundle(url: extensions.appending(path: name + ".appex")), name)
            XCTAssertEqual(bundle.bundleIdentifier, host + "." + key, name)
            XCTAssertEqual(bundle.object(forInfoDictionaryKey: "PhosdeckPluginHost") as? String, host, name)
            let attributes = bundle.object(forInfoDictionaryKey: "EXAppExtensionAttributes") as? [String: Any]
            XCTAssertEqual(attributes?["EXExtensionPointIdentifier"] as? String, point, name)
        }
    }

    func testPluginPixelsNormalizeAlphaAndPreserveExtendedColor() async throws {
        let colors: [SIMD4<Float>] = [SIMD4(-0.25, 1.5, 0.125, Float(1).nextUp),
                                      SIMD4(1.25, 0.25, -0.125, 0.5), SIMD4(1, 0, 0, 0),
                                      SIMD4(0.25, 0.5, 1, -Float.ulpOfOne)]
        let frame = try PluginFrame(width: colors.count, height: 1)
        let input = try PluginImage(frame: frame, pixels: colors.withUnsafeBytes { Data($0) })
        let image = ImagePipeline.pluginImage(input)
        let output = try await ImagePipeline().pluginPixels(image)
        try output.frame.verify(output.pixels)
        let actual = output.pixels.withUnsafeBytes { Array($0.bindMemory(to: SIMD4<Float>.self)) }
        let expected: [SIMD4<Float>] = [SIMD4(-0.25, 1.5, 0.125, 1), colors[1], .zero, .zero]
        XCTAssertEqual(output.frame, frame)
        XCTAssertEqual(actual, expected)
    }

    func testPluginPixelsConvertOpaqueEightBitSRGBToTopDownFloat() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 48)
        let lower = CIImage(color: .black).cropped(to: bounds)
        let upper = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 24, width: 64, height: 24))
        let bitmap = try XCTUnwrap(CIContext().createCGImage(upper.composited(over: lower), from: bounds,
                                                            format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
        let output = try await ImagePipeline().pluginPixels(CIImage(cgImage: bitmap))
        try output.frame.verify(output.pixels)
        output.pixels.withUnsafeBytes { bytes in
            let pixels = bytes.bindMemory(to: SIMD4<Float>.self)
            XCTAssertEqual(pixels.first, SIMD4(1, 1, 1, 1))
            XCTAssertEqual(pixels.last, SIMD4(0, 0, 0, 1))
        }
    }

    func testBundledToolsUseVerifiedWorkConnections() async throws {
        try requireDevelopmentSignature()
        let frame = try PluginFrame(width: 5, height: 1)
        let colors: [SIMD4<Float>] = [SIMD4(0.18, 0.18, 0.18, 1), SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1),
                                      SIMD4(0, 0.5, 0.45, 1)]
        let bytes = colors.withUnsafeBytes { Data($0) }
        let input = try PluginImage(frame: frame, pixels: bytes)
        let host = PhotoToolHost.shared
        let monitor = try await host.availabilityMonitor()
        let prefix = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let available = Set(monitor.identities.map(\.bundleIdentifier))
        XCTAssertTrue(["soft-proof", "select-highlights", "warm-print"].allSatisfy { available.contains(prefix + "." + $0) })

        let warm = try await host.evaluate(key: "warm-print", request: .init(revision: 5, purpose: .draft, parameters: .developEffect(strength: 0)), input: input)
        guard case .developEffect(let unchanged) = warm else { return XCTFail("Expected warm pixels") }
        XCTAssertEqual(unchanged.pixels, bytes)
        let stronger = try await host.evaluate(key: "warm-print", request: .init(revision: 6, purpose: .draft, parameters: .developEffect(strength: 0.5)), input: input)
        guard case .developEffect(let adjusted) = stronger else { return XCTFail("Expected warm pixels") }
        let expected = colors.map { $0 * SIMD4<Float>(1.06, 1.01, 0.94, 1) }.withUnsafeBytes { Data($0) }
        XCTAssertEqual(adjusted.pixels, expected)

        let profileURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")
        XCTAssertTrue(PrintProfileChoice.installed().contains { $0.url == profileURL })
        let profile = try Data(contentsOf: profileURL)
        let proofRequest = ToolRequest(revision: 7, purpose: .quality, parameters: .proof(intent: .relativeColorimetric, gamutWarning: true))
        let proof = try await host.evaluate(key: "soft-proof", request: proofRequest, input: input, profile: profile)
        guard case .proof(let simulation, let warning) = proof else { return XCTFail("Expected a proof") }
        XCTAssertNotEqual(simulation.pixels, bytes)
        XCTAssertEqual(warning?.count, frame.count)
        XCTAssertEqual(warning?.first, 0)
        // Generic CMYK returns a fractional positive gamut score for this cyan.
        XCTAssertEqual(warning?.last, 255)
        do {
            _ = try await host.evaluate(key: "soft-proof", request: proofRequest, input: input, profile: Data(repeating: 0, count: 132))
            XCTFail("Accepted a malformed ICC profile")
        } catch let error as PluginFailure { XCTAssertEqual(error, .invalidProfile) }
    }

    #if DEBUG
    @MainActor func testWarmConnectionIsReleasedAfterItsLastRequest() async throws {
        try requireDevelopmentSignature()
        let host = PhotoToolHost.shared
        let identifier = try XCTUnwrap(Bundle.main.bundleIdentifier) + ".warm-print"
        let frame = try PluginFrame(width: 1, height: 1)
        let color = SIMD4<Float>(0.2, 0.3, 0.4, 1)
        let input = try PluginImage(frame: frame, pixels: withUnsafeBytes(of: color) { Data($0) })
        let request = ToolRequest(revision: 0, purpose: .draft, parameters: .developEffect(strength: 0))
        _ = try await host.evaluate(key: "warm-print", request: request, input: input)
        let initialConnection = await host.connectionGeneration(for: identifier)
        let generation = try XCTUnwrap(initialConnection)
        _ = try await host.evaluate(key: "warm-print", request: request, input: input)
        let reusedConnection = await host.connectionGeneration(for: identifier)
        XCTAssertEqual(reusedConnection, generation)

        let deadline = ContinuousClock.now + .seconds(3)
        while await host.connectionGeneration(for: identifier) != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let disconnected = await host.connectionGeneration(for: identifier)
        XCTAssertNil(disconnected)
        _ = try await host.evaluate(key: "warm-print", request: request, input: input)
        let reconnected = await host.connectionGeneration(for: identifier)
        XCTAssertNotNil(reconnected)
        XCTAssertNotEqual(reconnected, generation)
    }
    #endif

    @MainActor func testHighlightsUseTheOrientedCropAndSaveANativeRange() async throws {
        try requireDevelopmentSignature()
        let fixture = ImportTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let catalog = try XCTUnwrap(fixture.catalog)
        let (root, a, b) = try pictures(fixture, catalog: catalog)
        let pipeline = ImagePipeline()
        var ranges: [LuminanceSuggestion] = []
        var aRecipe: EditRecipe?
        for photo in [a, b] {
            var recipe = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
            recipe.quarterTurns = 1
            recipe.crop = Crop(x: 0, y: 0, width: 0.45, height: 1)
            let request = ImageRequest(photo: photo, root: root, recipe: recipe)
            let oriented = try await pipeline.geometrySourceSize(request)
            let (_, frame) = try await pipeline.highlightPluginSource(request, orientedSize: oriented)
            let result = try await PhotoToolHost.shared.evaluate(key: "select-highlights",
                request: .init(revision: 1, purpose: .quality, parameters: .luminanceRange), input: frame)
            guard case .luminanceRange(let range) = result else { return XCTFail("Expected a native range") }
            ranges.append(range)
            if photo.id == a.id { aRecipe = recipe }
        }
        XCTAssertEqual(ranges[0], ranges[1])
        XCTAssertLessThan(ranges[0].lower, 0.6)
        try catalog.saveRecipe(id: a.id, recipe: XCTUnwrap(aRecipe))
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        model.editMode = true
        model.choose([a.id], active: a.id)
        try await waitUntil { model.activeID == a.id && model.canEdit && model.previewCurrent }
        let original = try XCTUnwrap(catalog.photo(a.id))
        model.previewHighlights()
        try await waitUntil { model.currentHighlightDraft != nil }
        let component = try XCTUnwrap(model.currentHighlightDraft?.group.components.first)
        XCTAssertEqual(component.lower, ranges[0].lower)
        XCTAssertEqual(component.upper, ranges[0].upper)
        XCTAssertEqual(component.smoothness, ranges[0].feather)
        model.applyHighlightPreview()
        let saved = try XCTUnwrap(catalog.photo(a.id))
        XCTAssertEqual(saved.recipeRevision, original.recipeRevision + 1)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(saved.recipe)).localAdjustments.first?.components, [component])
        model.undo.undo()
        XCTAssertTrue(model.recipe?.localAdjustments.isEmpty == true)
    }

    func testPublishedWarmStageRecoversOnceAndTravelsWithArchive() async throws {
        try requireDevelopmentSignature()
        let fixture = ImportTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        var catalog: CatalogStore? = try XCTUnwrap(fixture.catalog)
        fixture.catalog = nil
        let originalURL = try XCTUnwrap(catalog?.fileURL)
        let (root, a, _) = try pictures(fixture, catalog: XCTUnwrap(catalog))
        let pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(ImageRequest(photo: a, root: root, recipe: nil))
        recipe.warmPrint = WarmPrintEffect(strength: 0.6)
        let prepared = try await PluginStageCommit.prepare(catalog: XCTUnwrap(catalog), changes: [(photo: a, recipe: recipe)], title: "Warm Print")
        let receipt = try XCTUnwrap(prepared)
        let stage = try XCTUnwrap(receipt.files.first?.stage)
        let stageURL = try PluginStageFiles.url(stage)
        defer { try? FileManager.default.removeItem(at: stageURL) }
        try await receipt.publish()
        XCTAssertEqual(try catalog?.photo(a.id)?.recipeRevision, a.recipeRevision)
        catalog = nil
        catalog = try CatalogStore(fileURL: originalURL)
        let saved = try XCTUnwrap(catalog?.photo(a.id))
        XCTAssertEqual(saved.recipeRevision, a.recipeRevision + 1)
        let savedRecipe = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(saved.recipe))
        XCTAssertEqual(savedRecipe.warmPrint?.frozen, stage)
        XCTAssertEqual(try PluginStageCommit.recover(in: XCTUnwrap(catalog)), [])
        XCTAssertEqual(try catalog?.photo(a.id)?.recipeRevision, saved.recipeRevision)
        var grain = savedRecipe
        grain.grain.amount = 10
        XCTAssertEqual(try grain.matchingFrozenStage(), stage)
        var upstream = savedRecipe
        upstream.exposure += 0.2
        XCTAssertNil(try upstream.matchingFrozenStage())

        let before = try await pipeline.render(ImageRequest(photo: saved, root: root, recipe: savedRecipe), longEdge: nil)
        let delivery = fixture.target.appendingPathComponent("Warm.tiff")
        let options = ExportOptions(format: .tiff)
        _ = try await pipeline.export(ImageRequest(photo: saved, root: root, recipe: savedRecipe), staging: delivery, options: options)
        // Keep only history as a reference to the stage while writing the archive.
        try catalog?.saveRecipe(id: a.id, recipe: savedRecipe.baseline())
        let backup = fixture.target.appendingPathComponent("Database.sqlite")
        try catalog?.backup(to: backup)
        let archive = try await CatalogArchive.create(catalog: XCTUnwrap(catalog),
            destination: fixture.target.appendingPathComponent("Project"), extras: [])
        try FileManager.default.removeItem(at: stageURL)
        let restored = try CatalogStore.restore(from: backup, to: fixture.target.appendingPathComponent("Database only"))
        XCTAssertEqual(restored.pluginStageWarnings.count, 1)
        let reopened = try CatalogStore(fileURL: archive)
        XCTAssertTrue(reopened.pluginStageWarnings.isEmpty)
        let copied = try XCTUnwrap(reopened.photo(a.id))
        let copiedRoot = try XCTUnwrap(reopened.roots().first)
        let after = try await pipeline.render(ImageRequest(photo: copied, root: copiedRoot, recipe: savedRecipe), longEdge: nil)
        let deliveredCopy = fixture.target.appendingPathComponent("Archived Warm.tiff")
        _ = try await pipeline.export(ImageRequest(photo: copied, root: copiedRoot, recipe: savedRecipe), staging: deliveredCopy, options: options)
        XCTAssertEqual(before.image.dataProvider?.data, after.image.dataProvider?.data)
        let exported = try XCTUnwrap(CGImageSourceCreateWithURL(delivery as CFURL, nil))
        let exportedCopy = try XCTUnwrap(CGImageSourceCreateWithURL(deliveredCopy as CFURL, nil))
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(exported, 0, nil)?.dataProvider?.data,
                       CGImageSourceCreateImageAtIndex(exportedCopy, 0, nil)?.dataProvider?.data)
        XCTAssertEqual(try SafeFileWriter.sha256(stageURL), stage.digest)
    }

    @MainActor func testWarmDraftIsSavedBeforeDeferredExportAndCanBeUndone() async throws {
        try requireDevelopmentSignature()
        let fixture = ImportTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let catalog = try XCTUnwrap(fixture.catalog)
        let (_, a, b) = try pictures(fixture, catalog: catalog)
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        model.choose([a.id], active: a.id)
        try await waitUntil { model.activeID == a.id && model.canEdit && model.recipe != nil }
        model.setWarmPrintStrength(0.5)
        XCTAssertTrue(model.hasWarmPrintDraft)
        model.requestExport()
        XCTAssertTrue(model.savingWarmPrint)
        XCTAssertFalse(model.showExport)
        try await waitUntil { !model.savingWarmPrint }
        XCTAssertTrue(model.showExport)
        XCTAssertFalse(model.dirty)
        let stage = try XCTUnwrap(model.recipe?.warmPrint?.frozen)
        defer { if let url = try? PluginStageFiles.url(stage, create: false) { try? FileManager.default.removeItem(at: url) } }
        model.showExport = false
        let saved = try XCTUnwrap(catalog.photo(a.id))
        var edited = try XCTUnwrap(model.recipe)
        edited.exposure += 0.1
        var unavailable = b
        unavailable.availability = "missing"
        do {
            _ = try await model.publishRecipeBatch([(photo: saved, recipe: edited), (photo: unavailable, recipe: edited)], title: "Batch", catalog: catalog)
            XCTFail("A failed target must reject the batch")
        } catch {
            XCTAssertEqual(try catalog.photo(a.id)?.recipeRevision, saved.recipeRevision)
            XCTAssertEqual(try catalog.photo(b.id)?.recipeRevision, b.recipeRevision)
        }
        model.undo.undo()
        XCTAssertNil(model.recipe?.warmPrint)
        model.undo.redo()
        XCTAssertEqual(model.recipe?.warmPrint?.frozen, stage)
    }

    @MainActor func testWarmPrintSettlesOnTheLatestStrengthAfterDrafts() async throws {
        try requireDevelopmentSignature()
        let fixture = ImportTests()
        try fixture.setUpWithError()
        defer { try? fixture.tearDownWithError() }
        let catalog = try XCTUnwrap(fixture.catalog)
        let (root, photo, _) = try pictures(fixture, catalog: catalog, width: 3600, height: 2400)
        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        model.choose([photo.id], active: photo.id)
        try await waitUntil { model.activeID == photo.id && model.canEdit && model.previewCurrent }

        for step in 1...24 {
            let previous = model.image
            let started = DispatchTime.now().uptimeNanoseconds
            model.setWarmPrintStrength(Double(step) / 30)
            try await waitUntil(every: .milliseconds(2)) { model.image !== previous && model.interactivePreview }
            print("PLUGIN_PREVIEW draft step=\(step) edge=\(model.image?.width ?? 0) publish-ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
        }
        for step in 1...12 {
            let strength = Double(step) / 20
            model.setWarmPrintStrength(strength + 0.005)
            model.setWarmPrintStrength(strength)
            let started = DispatchTime.now().uptimeNanoseconds
            model.requestPreview()
            try await waitUntil(every: .milliseconds(2)) { model.previewCurrent }
            print("PLUGIN_PREVIEW quality step=\(step) edge=\(model.image?.width ?? 0) publish-ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
        }
        let request = ImageRequest(photo: try XCTUnwrap(model.active), root: root, recipe: model.recipe)
        let expected = try await ImagePipeline().renderDisplay(request, edge: 2400, canvas: true)
        XCTAssertEqual(model.recipe?.warmPrint?.strength, 0.6)
        XCTAssertEqual(model.image?.width, 2400)
        XCTAssertFalse(model.interactivePreview)
        XCTAssertEqual(model.image?.dataProvider?.data, expected.image.dataProvider?.data)
    }

    private func requireDevelopmentSignature() throws {
        if (try? PluginSignature.ownTeam()) == nil { throw XCTSkip("PhotoTool connections need an Apple-issued signing identity") }
    }

    private func pictures(_ fixture: ImportTests, catalog: CatalogStore, width: Int = 64, height: Int = 48) throws -> (StorageRoot, Photo, Photo) {
        let root = try catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let folder = URL(fileURLWithPath: root.path, isDirectory: true)
        let context = CIContext()
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let highlight = CGRect(x: 0, y: bounds.height * 0.625, width: bounds.width, height: bounds.height * 0.375)
        let photos = try [CGFloat(1), 0.75].enumerated().map { index, light in
            let url = folder.appendingPathComponent("Photo \(index).png")
            let base = CIImage(color: CIColor(red: 0.20, green: 0.19, blue: 0.17)).cropped(to: bounds)
            let bright = CIImage(color: CIColor(red: light, green: light, blue: light)).cropped(to: highlight)
            let image = try XCTUnwrap(context.createCGImage(bright.composited(over: base), from: bounds, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: folder)
            try catalog.index(photo)
            return photo
        }
        return (root, photos[0], photos[1])
    }

    @MainActor private func waitUntil(every interval: Duration = .milliseconds(100), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: interval)
        }
        throw LRCError("Timed out waiting for the plugin workflow")
    }
}
