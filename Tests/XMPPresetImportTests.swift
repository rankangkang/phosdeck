import XCTest
import GRDB
@testable import Phosdeck

final class XMPPresetImportTests: XCTestCase {
    private func packet(_ attributes: String = "", _ elements: String = "", prefix: String = "crs") -> Data {
        Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(XMPPresetReader.rdfURI)">
        <rdf:Description xmlns:\(prefix)="\(XMPPresetReader.crsURI)" \(attributes)>\(elements)</rdf:Description>
        </rdf:RDF></x:xmpmeta>
        """.utf8)
    }
    private func parse(_ attributes: String = "", _ elements: String = "") throws -> XMPPresetDraft {
        try XMPPresetReader.parse(packet(attributes, elements), filename: "测试.xmp")
    }
    private func recipe(raster: Bool = false) -> EditRecipe {
        EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: raster ? EditRecipe.rasterDecoderVersion : "synthetic-raw",
                   baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
    }

    func testNamespacesLocalizedNamesElementsAndUnknownStructures() throws {
        let data = packet("a:Exposure2012='0.75' a:ProcessVersion='15.4'", """
        <a:Name><rdf:Alt><rdf:li xml:lang="fr">Français</rdf:li><rdf:li xml:lang="x-default">夜景 &amp; 胶片</rdf:li></rdf:Alt></a:Name>
        <a:Group><rdf:Alt><rdf:li xml:lang="x-default">我的分组</rdf:li></rdf:Alt></a:Group>
        <a:Vibrance>20</a:Vibrance><a:Look><rdf:Description a:Name="Portra 400" a:Amount="1"/></a:Look>
        <a:FutureSlider>7</a:FutureSlider><fake:Exposure2012 xmlns:fake="urn:foreign">-4</fake:Exposure2012>
        """, prefix: "a")
        let draft = try XMPPresetReader.parse(data, filename: "fallback.xmp")
        XCTAssertEqual(draft.name, "夜景 & 胶片"); XCTAssertEqual(draft.group, "我的分组")
        XCTAssertEqual(draft.settings.values["Exposure2012"], 0.75)
        XCTAssertEqual(draft.settings.values["Vibrance"], 20)
        XCTAssertTrue(draft.settings.unsupported.contains { $0.contains("crs:Look") && $0.contains("Portra 400") })
        XCTAssertTrue(draft.settings.unsupported.contains { $0.contains("FutureSlider") })
        XCTAssertFalse(draft.settings.warnings.contains { $0.contains("ProcessVersion") })
        XCTAssertThrowsError(try XMPPresetReader.parse(packet("crs:Exposure2012='1'", "<crs:Exposure2012>2</crs:Exposure2012>"), filename: "bad.xmp"))
        let foreign = Data("<rdf:RDF xmlns:rdf='\(XMPPresetReader.rdfURI)'><rdf:Description xmlns:crs='urn:foreign' crs:Exposure2012='1'/></rdf:RDF>".utf8)
        XCTAssertThrowsError(try XMPPresetReader.parse(foreign, filename: "spoof.xmp"))
    }

    func testUnsupportedFieldsAndInvalidNumbersNeverPretendToApply() throws {
        let draft = try parse("crs:Exposure2012='NaN' crs:Highlights2012='oops' crs:Contrast2012='250' crs:Sharpness='45' crs:SharpenDetail='25' crs:CameraProfile='Adobe Color' crs:ParametricDarks='10' crs:IncrementalTint='10'", """
        <crs:MaskGroupBasedCorrections><rdf:Seq><rdf:li><rdf:Description crs:LocalExposure2012="1"/></rdf:li></rdf:Seq></crs:MaskGroupBasedCorrections>
        """)
        XCTAssertNil(draft.settings.values["Exposure2012"])
        XCTAssertNil(draft.settings.values["Highlights2012"])
        XCTAssertEqual(draft.settings.values["Contrast2012"], 100)
        XCTAssertEqual(draft.settings.values["Sharpness"], 45)
        for field in ["Exposure2012", "Highlights2012", "SharpenDetail", "CameraProfile", "ParametricDarks", "IncrementalTint", "MaskGroupBasedCorrections"] {
            XCTAssertTrue(draft.settings.unsupported.contains { $0.contains("crs:" + field) }, field)
        }
        XCTAssertTrue(draft.settings.notes.contains { $0.contains("Contrast2012") && $0.contains("限制") })
        let record = try draft.record()
        let restored = try JSONDecoder().decode(RecipePasteOptions.self, from: record.options)
        XCTAssertEqual(restored.importedXMP, draft.settings, "The limitations survive catalog storage and restart")
    }

    func testSparseApplicationAndAmountPreserveAllUnstatedSettings() throws {
        let draft = try parse("crs:Exposure2012='1.5'")
        let preset = try draft.record()
        var target = recipe(raster: true)
        target.exposure = 0.5; target.contrast = 1.3; target.saturation = 0.7
        target.develop.shadows = 42; target.develop.mixer[2].hue = 18
        target.grain = FilmGrain(amount: 30, size: 60, roughness: 70, seed: 123)
        target.sharpening.amount = 30; target.crop = Crop(x: 0.1, y: 0.2, width: 0.8, height: 0.7)
        target.flipHorizontal = true; target.develop.curves = ToneCurves()
        let zero = try preset.previewRecipe(on: target, amount: 0)
        XCTAssertEqual(zero, target)
        for (amount, expected) in [(0.5, 1.0), (1.0, 1.5), (2.0, 2.5)] {
            var reference = target; reference.exposure = expected
            XCTAssertEqual(try preset.previewRecipe(on: target, amount: amount), reference)
        }
        XCTAssertEqual(try parse("crs:Exposure2012='5'").record().previewRecipe(on: target, amount: 2).exposure, 5)
    }

    func testColorDetailAndVignetteMapToNativeRanges() throws {
        let preset = try parse("""
        crs:Contrast2012='-20' crs:Saturation='30' crs:HueAdjustmentOrange='-8' crs:GrayMixerBlue='40'
        crs:ConvertToGrayscale='True' crs:ColorGradeMidtoneHue='210' crs:ColorGradeMidtoneSat='15'
        crs:SplitToningShadowSaturation='20' crs:GrainAmount='30' crs:GrainFrequency='65'
        crs:PostCropVignetteAmount='-25' crs:PostCropVignetteStyle='2' crs:Sharpness='60' crs:SharpenRadius='1.8'
        crs:LuminanceSmoothing='20' crs:ColorNoiseReduction='25'
        """).record()
        let result = try preset.previewRecipe(on: recipe())
        XCTAssertEqual(result.contrast, 0.8); XCTAssertEqual(result.saturation, 1.3)
        XCTAssertTrue(result.develop.blackAndWhite); XCTAssertEqual(result.develop.mixer[1].hue, -8)
        XCTAssertEqual(result.develop.blackWhiteMixer[5], 40)
        XCTAssertEqual(result.develop.grading.midtones.hue, 210); XCTAssertEqual(result.develop.grading.midtones.saturation, 15)
        XCTAssertEqual(result.develop.grading.shadows.saturation, 20)
        XCTAssertEqual(result.grain.amount, 30); XCTAssertEqual(result.grain.roughness, 65)
        XCTAssertEqual(result.vignette.amount, -25); XCTAssertEqual(result.vignette.style, .colorPriority)
        XCTAssertEqual(result.sharpening.amount, 60); XCTAssertEqual(result.sharpening.radius, 1.8)
        XCTAssertEqual(result.noiseReduction, GeneralNoiseReduction(luminance: 20, color: 25))
        XCTAssertTrue(result.rawDetails.isDefault)
    }

    func testWhiteBalanceUsesEachRawBaselineAndKeepsRenderedWhiteBalance() throws {
        let asShot = try parse("crs:WhiteBalance='As Shot' crs:Temperature='6000' crs:Tint='15'").record()
        var raw = recipe(); raw.baselineTemperature = 4800; raw.baselineTint = 4
        raw.temperature = 6200; raw.tint = 20; raw.asShotWhiteBalance = false
        let result = try asShot.previewRecipe(on: raw)
        XCTAssertEqual(result.temperature, 4800); XCTAssertEqual(result.tint, 4); XCTAssertTrue(result.asShotWhiteBalance)
        let custom = try parse("crs:WhiteBalance='Custom' crs:Temperature='6000'").record()
        XCTAssertEqual(try custom.previewRecipe(on: raw).tint, 20, "Missing tint must not become zero")
        var rendered = recipe(raster: true); rendered.asShotWhiteBalance = false; rendered.temperature = 5800; rendered.tint = 10
        XCTAssertEqual(try custom.previewRecipe(on: rendered), rendered)
        let options = try JSONDecoder().decode(RecipePasteOptions.self, from: custom.options)
        XCTAssertTrue(rendered.transferNotes(from: raw, options: options).contains { $0.contains("已保留") })
        let auto = try parse("crs:WhiteBalance='Auto' crs:Temperature='6000'")
        XCTAssertFalse(auto.settings.hasContent); XCTAssertTrue(auto.settings.unsupported.contains { $0.contains("WhiteBalance") })
    }

    func testCurvesRequireValidPointsAndCompleteRGBSet() throws {
        func curve(_ name: String, _ values: [String]) -> String { "<crs:\(name)><rdf:Seq>" + values.map { "<rdf:li>\($0)</rdf:li>" }.joined() + "</rdf:Seq></crs:\(name)>" }
        let master = curve("ToneCurvePV2012", ["0, 15", "128, 140", "255, 240"])
        let red = curve("ToneCurvePV2012Red", ["0, 0", "255, 220"])
        let partial = try parse("", master + red)
        XCTAssertEqual(partial.settings.curves.count, 1)
        XCTAssertTrue(partial.settings.unsupported.contains { $0.contains("ToneCurvePV2012Red") })
        let full = try parse("", master + red + curve("ToneCurvePV2012Green", ["0, 0", "255, 255"]) + curve("ToneCurvePV2012Blue", ["0, 10", "255, 255"]))
        let result = try full.record().previewRecipe(on: recipe())
        XCTAssertEqual(result.develop.curves?.channels[0][0].y, 15.0 / 255)
        XCTAssertEqual(result.develop.curves?.channels[1].last?.y, 220.0 / 255)
        XCTAssertEqual(full.settings.curves.count, 4)
        let invalid = try parse("crs:Exposure2012='1'", curve("ToneCurvePV2012", ["0, 0", "128, NaN", "255, 255"]))
        XCTAssertTrue(invalid.settings.curves.isEmpty); XCTAssertFalse(invalid.settings.unsupported.isEmpty)
        let tooMany = try parse("", curve("ToneCurvePV2012", (0...16).map { "\(Double($0) * 255 / 16), 0" }))
        XCTAssertFalse(tooMany.settings.hasContent)
    }

    func testUnsafeMalformedAppliedAndLocalPacketsAreRejected() throws {
        for text in ["<broken>", "<!DOCTYPE x [<!ENTITY e '1'>]><x>&e;</x>", "<x/>" ] {
            XCTAssertThrowsError(try XMPPresetReader.parse(Data(text.utf8), filename: "bad.xmp"))
        }
        XCTAssertThrowsError(try parse("crs:Exposure2012='1' crs:AlreadyApplied='True'"))
        XCTAssertThrowsError(try parse("crs:Exposure2012='1' crs:AlreadyApplied='maybe'"))
        XCTAssertThrowsError(try parse("crs:PresetType='Local' crs:Exposure2012='1'"))
        XCTAssertThrowsError(try XMPPresetReader.parse(Data(repeating: 32, count: XMPPresetReader.maximumBytes + 1), filename: "large.xmp"))
        let nested = String(repeating: "<a>", count: 40) + String(repeating: "</a>", count: 40)
        XCTAssertThrowsError(try XMPPresetReader.parse(Data(nested.utf8), filename: "deep.xmp"))
        let noAdjustments = try parse("crs:CameraProfile='Camera Standard' crs:FutureSlider='1'")
        XCTAssertFalse(noAdjustments.settings.hasContent); XCTAssertEqual(noAdjustments.settings.unsupported.count, 2)
    }

    func testFileFailuresAreIndependentAndSourcesStayUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let good = folder.appendingPathComponent("good.XMP"), bad = folder.appendingPathComponent("bad.xmp")
        let bytes = packet("crs:Exposure2012='1' crs:CameraProfile='Adobe Color'")
        try bytes.write(to: good); try Data("broken".utf8).write(to: bad)
        let items = [good, bad, folder.appendingPathComponent("missing.xmp")].map(XMPPresetReader.read)
        XCTAssertEqual(items.filter(\.canImport).count, 1)
        XCTAssertEqual(items.filter { $0.error != nil }.count, 2)
        XCTAssertTrue(items[0].issues.contains { $0.contains("CameraProfile") })
        XCTAssertEqual(try Data(contentsOf: good), bytes)
    }

    @MainActor func testCatalogDeduplicatesBatchAndUndoRedoRetainsNotices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try CatalogStore(directory: folder)
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.undo.groupsByEvent = false
        let a = try parse("crs:Name='胶片' crs:Exposure2012='1' crs:CameraProfile='Adobe Color'")
        let b = try parse("crs:Name='黑白' crs:ConvertToGrayscale='True'")
        model.showXMPPresetImport = true
        XCTAssertFalse(model.canSwitchCatalog)
        model.undo.beginUndoGrouping()
        XCTAssertTrue(model.importXMPPresets([a, a, b], expectedCatalog: catalog), model.error ?? "")
        model.undo.endUndoGrouping()
        let imported = try catalog.presets()
        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(model.reports.contains { $0.contains("CameraProfile") })
        model.undo.undo(); XCTAssertTrue(try catalog.presets().isEmpty)
        model.undo.redo(); XCTAssertEqual(try catalog.presets(), imported)
        XCTAssertEqual(try catalog.importXMPPresets([a, b]).count, 0)
        let broken = XMPPresetDraft(name: "", group: "", settings: a.settings)
        XCTAssertThrowsError(try catalog.importXMPPresets([a, broken]))
        XCTAssertEqual(try catalog.presets(), imported)
        let other = try CatalogStore(directory: folder.appendingPathComponent("other"))
        XCTAssertFalse(model.importXMPPresets([a], expectedCatalog: other))
        XCTAssertTrue(try other.presets().isEmpty)
        let first = try XCTUnwrap(imported.first)
        let oldOptions = try JSONDecoder().decode(RecipePasteOptions.self, from: first.options)
        let old = try catalog.updatePreset(id: first.id, recipe: recipe(), options: oldOptions)
        XCTAssertEqual(old, first)
        let updated = try XCTUnwrap(catalog.presets().first { $0.id == first.id })
        XCTAssertNil(try JSONDecoder().decode(RecipePasteOptions.self, from: updated.options).importedXMP)
        try catalog.restorePreset(old); XCTAssertEqual(try catalog.presets(), imported)
    }

    func testImportedSparsePayloadSurvivesCatalogReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let draft = try parse("crs:Name='重开' crs:Exposure2012='1.25' crs:PointColors='0.5,0.2,0.1,10'")
        var saved: [AdjustmentPreset] = []
        do {
            let catalog = try CatalogStore(directory: folder)
            saved = try catalog.importXMPPresets([draft])
        }
        let catalog = try CatalogStore(directory: folder)
        XCTAssertEqual(try catalog.presets(), saved)
        XCTAssertEqual(try XCTUnwrap(catalog.presets().first).previewRecipe(on: recipe()).exposure, 1.25)
    }

    @MainActor func testBatchApplicationUsesRealSaveHistoryAndUndoWithoutTouchingSource() async throws {
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let root = try fixture.catalog.addRoot(url: fixture.source, bookmark: AccessLease.bookmark(fixture.source, readOnly: true))
        let url = fixture.source.appendingPathComponent("synthetic.jpg"); try fixture.image(url)
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: fixture.source)
        try fixture.catalog.index(photo)
        let digest = try SafeFileWriter.sha256(url)
        var initial = recipe(raster: true); initial.sourceDigest = digest
        initial.exposure = 0.25; initial.contrast = 1.4; initial.develop.shadows = 35
        try fixture.catalog.saveRecipe(id: photo.id, recipe: initial, title: "合成初始调整")
        let original = try XCTUnwrap(fixture.catalog.photo(photo.id))
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = fixture.catalog; model.undo.groupsByEvent = false; try model.reload()
        let draft = try parse("crs:Exposure2012='1.25' crs:CameraProfile='Adobe Color'")
        let record = try draft.record()
        let source = try JSONDecoder().decode(EditRecipe.self, from: record.recipe)
        let options = try JSONDecoder().decode(RecipePasteOptions.self, from: record.options)
        XCTAssertTrue(model.applyAdjustments(source: source, options: options, ids: [photo.id], title: "应用合成 XMP", amount: 1))
        await model.task?.value
        let applied = try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(fixture.catalog.photo(photo.id)?.recipe))
        var expected = initial; expected.exposure = 1.25
        XCTAssertEqual(applied, expected)
        XCTAssertTrue(model.reports.contains { $0.contains("CameraProfile") })
        model.undo.undo(); XCTAssertEqual(try fixture.catalog.photo(photo.id)?.recipe, original.recipe)
        model.undo.redo(); XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(fixture.catalog.photo(photo.id)?.recipe)), expected)
        XCTAssertEqual(try SafeFileWriter.sha256(url), digest)
    }
}
