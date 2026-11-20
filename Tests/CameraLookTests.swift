import XCTest
import CoreImage
import ImageIO
import AppKit
import SwiftUI
import simd
@testable import Phosdeck

final class CameraLookTests: XCTestCase {
    private let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var linearContext = CIContext(options: [
        .workingFormat: CIFormat.RGBAf,
        .workingColorSpace: linearSpace,
        .cacheIntermediates: false
    ])
    private lazy var outputContext = CIContext(options: [
        .workingFormat: CIFormat.RGBAf,
        .workingColorSpace: linearSpace,
        .cacheIntermediates: false
    ])

    private func makeLinearImage(_ rgba: [Float], width: Int, height: Int) -> CIImage {
        rgba.withUnsafeBytes { raw in
            CIImage(bitmapData: Data(raw),
                    bytesPerRow: width * 16,
                    size: CGSize(width: width, height: height),
                    format: .RGBAf,
                    colorSpace: linearSpace)
        }
    }

    private func renderLinearPixels(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var out = Array(repeating: Float(0), count: width * height * 4)
        linearContext.render(image,
                             toBitmap: &out,
                             rowBytes: width * 16,
                             bounds: image.extent,
                             format: .RGBAf,
                             colorSpace: linearSpace)
        return out
    }

    private func renderOutputPixels(_ cgImage: CGImage) -> [Float] {
        let image = CIImage(cgImage: cgImage)
        let width = cgImage.width, height = cgImage.height
        var out = Array(repeating: Float(0), count: width * height * 4)
        outputContext.render(image,
                             toBitmap: &out,
                             rowBytes: width * 16,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             format: .RGBAf,
                             colorSpace: ImagePipeline.outputSpace)
        return out
    }

    private func bytes(_ rendered: RenderedImage) throws -> Data {
        try XCTUnwrap(rendered.image.dataProvider?.data) as Data
    }

    func testTetrahedralShaderMatchesCPUReferencePreservesAlphaAndUnclampedDomain() throws {
        let selection = CameraLookSelection(id: "diagnostic.test-table", version: 1)
        let library = CameraLookLibrary(includesDiagnosticLooks: true)
        let table = try library.table(for: selection)

        // Verify gray-axis neutrality and strict monotonicity on the bundled diagnostic table.
        var previousGray: Float = -1
        for step in 0...64 {
            let v = Float(step) / 16.0 // 0.0 ... 4.0
            let mapped = table.referenceSample(SIMD3<Float>(v, v, v))
            XCTAssertEqual(mapped.x, mapped.y, accuracy: 1e-4)
            XCTAssertEqual(mapped.y, mapped.z, accuracy: 1e-4)
            XCTAssertGreaterThanOrEqual(mapped.x, previousGray - 1e-6)
            previousGray = mapped.x
        }

        // Cover all 6 tetrahedral sub-simplices, negative wide-gamut primaries, > upperBound highlights, and alpha extremes.
        let straightSamples: [SIMD3<Float>] = [
            SIMD3(0, 0, 0),
            SIMD3(0.18, 0.18, 0.18),
            SIMD3(0.62, 0.31, 0.11), // r >= g >= b
            SIMD3(0.62, 0.11, 0.31), // r >= b > g
            SIMD3(0.31, 0.11, 0.62), // b > r >= g
            SIMD3(0.31, 0.62, 0.11), // g > r >= b
            SIMD3(0.11, 0.62, 0.31), // g >= b > r
            SIMD3(0.11, 0.31, 0.62), // b > g > r
            SIMD3(-0.24, 0.45, 1.15), // negative wide-gamut channel + >1 highlight
            SIMD3(3.95, 2.20, 0.80),  // near upperBound
            SIMD3(6.50, 4.75, -0.12)  // above upperBound + negative channel
        ]
        let alphas: [Float] = [0, 1.0 / 65535.0, 0.35, 1.0]
        var inputPixels: [Float] = []
        for alpha in alphas {
            for rgb in straightSamples {
                inputPixels.append(contentsOf: [rgb.x * alpha, rgb.y * alpha, rgb.z * alpha, alpha])
            }
        }
        let width = straightSamples.count, height = alphas.count
        let inputImage = makeLinearImage(inputPixels, width: width, height: height)
        let outputImage = try CameraLookPipeline.apply(inputImage, selection: selection, library: library)
        let actual = renderLinearPixels(outputImage)

        for row in 0..<height {
            let alpha = alphas[row]
            for col in 0..<width {
                let idx = (row * width + col) * 4
                XCTAssertEqual(actual[idx + 3], alpha, accuracy: 1e-7, "Alpha coverage must remain exact")
                if alpha == 0 {
                    XCTAssertEqual(actual[idx], 0, accuracy: 1e-7)
                    XCTAssertEqual(actual[idx + 1], 0, accuracy: 1e-7)
                    XCTAssertEqual(actual[idx + 2], 0, accuracy: 1e-7)
                } else {
                    let expectedStraight = table.referenceSample(straightSamples[col])
                    let actualStraight = SIMD3<Float>(actual[idx] / alpha, actual[idx + 1] / alpha, actual[idx + 2] / alpha)
                    // Relax slightly only for 1/65535 premultiplied precision round-trip.
                    let tolerance: Float = alpha < 1e-3 ? 2e-3 : 2e-5
                    XCTAssertEqual(actualStraight.x, expectedStraight.x, accuracy: tolerance)
                    XCTAssertEqual(actualStraight.y, expectedStraight.y, accuracy: tolerance)
                    XCTAssertEqual(actualStraight.z, expectedStraight.z, accuracy: tolerance)
                }
            }
        }

        // Verify a 33^3 identity table preserves negative and super-white linear values across the entire domain.
        let dim = 33
        let upper: Float = 4.0
        var identityGrid: [Float16] = []
        identityGrid.reserveCapacity(dim * dim * dim * 3)
        for b in 0..<dim {
            let bv = CameraLookTable.decode(Float(b) / Float(dim - 1), upperBound: upper)
            for g in 0..<dim {
                let gv = CameraLookTable.decode(Float(g) / Float(dim - 1), upperBound: upper)
                for r in 0..<dim {
                    let rv = CameraLookTable.decode(Float(r) / Float(dim - 1), upperBound: upper)
                    identityGrid.append(Float16(rv))
                    identityGrid.append(Float16(gv))
                    identityGrid.append(Float16(bv))
                }
            }
        }
        let identityTable = try CameraLookTable(selection: CameraLookSelection(id: "identity", version: 1),
                                                dimension: dim,
                                                upperBound: upper,
                                                rgbTriplets: identityGrid)
        let identityOutput = try SpatialDevelopPipeline.cameraLook(inputImage,
                                                                   atlas: identityTable.atlas,
                                                                   dimension: identityTable.dimension,
                                                                   upperBound: identityTable.upperBound)
        let identityActual = renderLinearPixels(identityOutput)
        for row in 0..<height {
            let alpha = alphas[row]
            for col in 0..<width {
                let idx = (row * width + col) * 4
                XCTAssertEqual(identityActual[idx + 3], alpha, accuracy: 1e-7)
                if alpha > 0 {
                    let expectedRef = identityTable.referenceSample(straightSamples[col])
                    let actualStraight = SIMD3<Float>(identityActual[idx] / alpha,
                                                      identityActual[idx + 1] / alpha,
                                                      identityActual[idx + 2] / alpha)
                    let refTol: Float = alpha < 1e-3 ? 2e-3 : 2e-5
                    XCTAssertEqual(actualStraight.x, expectedRef.x, accuracy: refTol)
                    XCTAssertEqual(actualStraight.y, expectedRef.y, accuracy: refTol)
                    XCTAssertEqual(actualStraight.z, expectedRef.z, accuracy: refTol)
                }
            }
        }
        for i in inputPixels.indices {
            // Log-spaced piecewise-linear chord error on 33^3 is <= 0.15% relative in highlights while preserving negative and >upperBound channels.
            XCTAssertEqual(identityActual[i], inputPixels[i], accuracy: max(1.5e-3, abs(inputPixels[i]) * 2e-3))
        }
    }

    func testBundledManifestLocalizationAndReleaseVisibility() throws {
        let selection = CameraLookSelection(id: "diagnostic.test-table", version: 1)
        let previewLibrary = CameraLookLibrary(includesDiagnosticLooks: true)
        let releaseLibrary = CameraLookLibrary(includesDiagnosticLooks: false)

        try previewLibrary.validate(selection)
        try releaseLibrary.validate(selection)

        let previewSections = previewLibrary.menuSections()
        XCTAssertEqual(previewSections.map(\.group.id), ["fujifilm", "sony", "diagnostic"])
        XCTAssertEqual(previewSections.last?.entries.map(\.selection), [selection])
        let releaseSections = releaseLibrary.menuSections()
        XCTAssertEqual(releaseSections.map(\.group.id), ["fujifilm", "sony"])
        let fujiLooks = ["provia", "velvia", "astia", "classic-chrome", "pro-neg-hi", "pro-neg-std",
                         "classic-neg", "nostalgic-neg", "reala-ace", "eterna", "eterna-bleach-bypass",
                         "acros", "acros-ye", "acros-r", "acros-g", "monochrome", "monochrome-ye",
                         "monochrome-r", "monochrome-g", "sepia"]
        XCTAssertEqual(releaseSections.first?.entries.map(\.selection.id), fujiLooks.map { "fujifilm.\($0)" })
        XCTAssertEqual(releaseSections.last?.entries.map(\.selection.id), ["sony.st"])

        XCTAssertEqual(previewLibrary.title(for: selection, language: "en"), "Test Lookup Table")
        XCTAssertEqual(previewLibrary.title(for: selection, language: "zh-Hans"), "测试色表")
        XCTAssertEqual(previewSections.last?.group.displayTitle(language: "en"), "Pipeline Verification")
        XCTAssertEqual(previewSections.last?.group.displayTitle(language: "zh-Hans"), "测试验证")
        XCTAssertEqual(releaseSections.first?.group.displayTitle(language: "zh-Hans"), "富士（近似）")
        XCTAssertEqual(releaseLibrary.title(for: CameraLookSelection(id: "sony.st", version: 1), language: "zh-Hans"),
                       "ST 标准色彩")
    }

    func testBundledLooksChangeColorAndPreserveHighlightHeadroom() throws {
        let library = CameraLookLibrary(includesDiagnosticLooks: false)
        let patches: [SIMD3<Float>] = [SIMD3(0.15, 0.48, 0.29), SIMD3(0.72, 0.14, 0.03), SIMD3(0.16, 0.04, 0.62)]
        let high = SIMD3<Float>(-0.075, 2.2, 5.5)
        let nearWhite: [SIMD3<Float>] = [SIMD3(repeating: 0.9999), SIMD3(0.9999, 0, 0.23),
                                       SIMD3(0.10, 0.9999, 0.61), SIMD3(0.19, 0.44, 0.9999)]
        var swatches = Set<[SIMD3<Float>]>()
        for entry in library.menuSections().flatMap(\.entries) {
            let table = try library.table(for: entry.selection)
            let colors = patches.map(table.referenceSample)
            XCTAssertTrue(swatches.insert(colors).inserted, entry.selection.id)
            XCTAssertGreaterThan(simd_length(colors[0] - patches[0]), 0.001, entry.selection.id)
            if table.headroomWeights == nil {
                let highlight = table.referenceSample(high)
                XCTAssertEqual(highlight.x, high.x, accuracy: 0.0001)
                XCTAssertEqual(highlight.y, high.y, accuracy: 0.004)
                XCTAssertEqual(highlight.z, high.z, accuracy: 0.0001)
            }
            for point in nearWhite {
                XCTAssertLessThan(simd_reduce_max(table.referenceSample(point)), 1, entry.selection.id)
            }
        }
    }

    func testMonochromeAndSepiaKeepTheirTreatmentThroughExtendedHighlights() throws {
        let library = CameraLookLibrary(includesDiagnosticLooks: false)
        let samples: [SIMD3<Float>] = [SIMD3(0.25, 0.25, 0.25), SIMD3(0.99, 0.66, 0.41),
                                      SIMD3(1.3, 1.8, 0.4), SIMD3(-0.075, 4.3, 5.5)]
        let alpha: Float = 0.35
        let input = makeLinearImage(samples.flatMap { [$0.x * alpha, $0.y * alpha, $0.z * alpha, alpha] },
                                    width: samples.count, height: 1)
        let monochrome = ["acros", "acros-ye", "acros-r", "acros-g", "monochrome", "monochrome-ye",
                          "monochrome-r", "monochrome-g"]
        for look in monochrome + ["sepia"] {
            let selection = CameraLookSelection(id: "fujifilm.\(look)", version: 1)
            let table = try library.table(for: selection)
            _ = try XCTUnwrap(table.headroomWeights)
            let pixels = renderLinearPixels(try CameraLookPipeline.apply(input, selection: selection, library: library))
            for (index, sample) in samples.enumerated() {
                let offset = index * 4
                let actual = SIMD3(pixels[offset], pixels[offset + 1], pixels[offset + 2]) / alpha
                let expected = table.referenceSample(sample)
                XCTAssertEqual(pixels[offset + 3], alpha, accuracy: 1e-7, look)
                XCTAssertLessThan(simd_length(actual - expected), 0.00002, look)
                if look == "sepia" {
                    XCTAssertGreaterThan(actual.x, actual.y, look)
                    XCTAssertGreaterThan(actual.y, actual.z, look)
                } else {
                    XCTAssertEqual(actual.x, actual.y, accuracy: 1e-6, look)
                    XCTAssertEqual(actual.y, actual.z, accuracy: 1e-6, look)
                }
            }
            XCTAssertGreaterThan(pixels[12] / alpha, 1, look)
        }
    }

    @MainActor
    func testPublicRAWLookPreviewAndCommitKeepTheExistingRecipe() async throws {
        let sample = try MoreRAWTests.request("a7iii_12bit_compressed.ARW")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let catalog = try CatalogStore(fileURL: workspace.appendingPathComponent("LookPreview.phoscat"), create: true)
        let rootURL = URL(fileURLWithPath: sample.root.path)
        let root = try catalog.addRoot(url: rootURL, bookmark: AccessLease.bookmark(rootURL, readOnly: true))
        var photo = sample.photo
        photo.rootID = root.id
        try catalog.index(photo)

        let model = AppModel()
        model.catalog = catalog
        try model.reload()
        defer { model.choose([], active: nil); model.catalog = nil }
        model.choose([photo.id], active: photo.id)
        model.selectWorkspace(.develop)
        for _ in 0..<120 where !model.canEdit || model.image == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(model.canEdit)
        _ = try XCTUnwrap(model.image)

        model.changeRecipe {
            $0.exposure = 0.65
            $0.localAdjustments = [LocalAdjustment(name: "Test Radial",
                components: [MaskComponent(tool: .radial)], exposure: 0.45)]
        }
        let original = try XCTUnwrap(model.recipe)
        let saved = try XCTUnwrap(catalog.photo(photo.id)?.recipe)
        let history = model.editHistory.count
        let eterna = CameraLookSelection(id: "fujifilm.eterna", version: 1)
        let acros = CameraLookSelection(id: "fujifilm.acros-r", version: 1)
        model.previewCameraLook(eterna)
        XCTAssertEqual(model.displayPreviewRecipe?.cameraLook, eterna)
        XCTAssertEqual(model.recipe, original)
        XCTAssertEqual(try catalog.photo(photo.id)?.recipe, saved)
        XCTAssertEqual(model.editHistory.count, history)
        model.endCameraLookPreview()
        XCTAssertFalse(model.isPreviewingAdjustment)
        XCTAssertEqual(model.recipe, original)

        model.previewCameraLook(acros)
        model.selectCameraLook(acros)
        XCTAssertFalse(model.isPreviewingAdjustment)
        var expected = original
        expected.cameraLook = acros
        XCTAssertEqual(model.recipe, expected)
        XCTAssertEqual(model.editHistory.count, history + 1)
        let data = try XCTUnwrap(catalog.photo(photo.id)?.recipe)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: data), expected)

        let pipeline = ImagePipeline()
        let initial = ImageRequest(photo: photo, root: root, recipe: original)
        let edited = ImageRequest(photo: photo, root: root, recipe: expected)
        let initialFrame = try await pipeline.render(initial, longEdge: 320)
        let editedFrame = try await pipeline.render(edited, longEdge: 320)
        XCTAssertNotEqual(try bytes(initialFrame), try bytes(editedFrame))
        let output = workspace.appendingPathComponent("ACROS.png")
        _ = try await pipeline.export(edited, staging: output, options: ExportOptions(format: .png, longEdge: 320))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(exported.width, editedFrame.image.width)
    }

    func testVersionCoexistenceAndExplicitCorruptionOrMissingRejection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-cameralooks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func makeTableFile(name: String, gain: SIMD3<Float>, injectNaN: Bool = false) throws -> String {
            let rawData = try CameraLookTable.serializedData(dimension: 17, upperBound: 4.0) { input in
                input * gain
            }
            var data = rawData
            if injectNaN {
                let nanBits = Float16.nan.bitPattern.littleEndian
                withUnsafeBytes(of: nanBits) { data.replaceSubrange(16..<18, with: $0) }
            }
            let fileURL = dir.appendingPathComponent(name)
            try data.write(to: fileURL)
            return try SafeFileWriter.sha256(fileURL)
        }

        let v1Hash = try makeTableFile(name: "film-classic-v1.bin", gain: SIMD3(0.80, 1.0, 1.15))
        let v2Hash = try makeTableFile(name: "film-classic-v2.bin", gain: SIMD3(1.20, 0.95, 0.75))
        let corruptHash = try makeTableFile(name: "corrupt-nan.bin", gain: SIMD3(1, 1, 1), injectNaN: true)

        let manifest: [String: Any] = [
            "formatVersion": 1,
            "groups": [
                ["id": "brand-a", "title": "Brand A", "localizedTitles": ["zh-Hans": "品牌 A"]]
            ],
            "looks": [
                [
                    "id": "brand-a.classic",
                    "version": 1,
                    "group": "brand-a",
                    "title": "Classic v1",
                    "file": "film-classic-v1.bin",
                    "sha256": v1Hash,
                    "dimension": 17,
                    "upperBound": 4.0,
                    "diagnostic": false,
                    "selectable": false
                ],
                [
                    "id": "brand-a.classic",
                    "version": 2,
                    "group": "brand-a",
                    "title": "Classic",
                    "file": "film-classic-v2.bin",
                    "sha256": v2Hash,
                    "dimension": 17,
                    "upperBound": 4.0,
                    "diagnostic": false,
                    "selectable": true
                ],
                [
                    "id": "brand-a.bad-checksum",
                    "version": 1,
                    "group": "brand-a",
                    "title": "Bad Checksum",
                    "file": "film-classic-v2.bin",
                    "sha256": String(repeating: "0", count: 64),
                    "dimension": 17,
                    "upperBound": 4.0,
                    "diagnostic": false,
                    "selectable": false
                ],
                [
                    "id": "brand-a.missing-file",
                    "version": 1,
                    "group": "brand-a",
                    "title": "Missing File",
                    "file": "does-not-exist.bin",
                    "sha256": v1Hash,
                    "dimension": 17,
                    "upperBound": 4.0,
                    "diagnostic": false,
                    "selectable": false
                ],
                [
                    "id": "brand-a.corrupt-nan",
                    "version": 1,
                    "group": "brand-a",
                    "title": "Corrupt NaN",
                    "file": "corrupt-nan.bin",
                    "sha256": corruptHash,
                    "dimension": 17,
                    "upperBound": 4.0,
                    "diagnostic": false,
                    "selectable": false
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            .write(to: dir.appendingPathComponent("manifest.json"))

        let library = CameraLookLibrary(directory: dir, includesDiagnosticLooks: false)
        let sections = library.menuSections()
        XCTAssertEqual(sections.flatMap(\.entries).map(\.selection),
                       [CameraLookSelection(id: "brand-a.classic", version: 2)],
                       "Only selectable versions appear in the picker for new selections")

        // Saved v1 and v2 must each render their own exact version without silent substitution.
        let selV1 = CameraLookSelection(id: "brand-a.classic", version: 1)
        let selV2 = CameraLookSelection(id: "brand-a.classic", version: 2)
        let expectedV1 = try library.table(for: selV1).referenceSample(SIMD3(0.5, 0.5, 0.5))
        let expectedV2 = try library.table(for: selV2).referenceSample(SIMD3(0.5, 0.5, 0.5))
        let sample = makeLinearImage([0.5, 0.5, 0.5, 1.0], width: 1, height: 1)
        let outV1 = renderLinearPixels(try CameraLookPipeline.apply(sample, selection: selV1, library: library))
        let outV2 = renderLinearPixels(try CameraLookPipeline.apply(sample, selection: selV2, library: library))
        XCTAssertEqual(outV1[0], expectedV1.x, accuracy: 2e-5)
        XCTAssertEqual(outV1[2], expectedV1.z, accuracy: 2e-5)
        XCTAssertEqual(outV2[0], expectedV2.x, accuracy: 2e-5)
        XCTAssertEqual(outV2[2], expectedV2.z, accuracy: 2e-5)
        XCTAssertNotEqual(outV1[0], outV2[0], accuracy: 0.15)

        // Unknown ID, unknown version, checksum mismatch, missing file, and NaN values must all fail explicitly.
        XCTAssertThrowsError(try library.validate(CameraLookSelection(id: "unknown.look", version: 1)))
        XCTAssertThrowsError(try library.validate(CameraLookSelection(id: "brand-a.classic", version: 99)))
        XCTAssertThrowsError(try library.table(for: CameraLookSelection(id: "brand-a.bad-checksum", version: 1)))
        XCTAssertThrowsError(try library.table(for: CameraLookSelection(id: "brand-a.missing-file", version: 1)))
        XCTAssertThrowsError(try library.table(for: CameraLookSelection(id: "brand-a.corrupt-nan", version: 1)))
    }

    func testRasterAndLinearMasterRejectCameraLookWhileCrossBrandRAWPasteTransfers() throws {
        let look = CameraLookSelection(id: "diagnostic.test-table", version: 1)
        let library = CameraLookLibrary(includesDiagnosticLooks: true)
        let digest = String(repeating: "b", count: 64)

        let rawSource = EditRecipe(sourceDigest: digest, decoderVersion: "8",
                                   baselineExposure: -0.3, baselineTemperature: 5100, baselineTint: 4,
                                   exposure: 0.5, temperature: 5100, tint: 4, cameraLook: look)
        try rawSource.validate(lookLibrary: library)
        XCTAssertTrue(rawSource.modifiedDevelopGroups.contains(.basic))
        XCTAssertNil(DevelopGroup.basic.previewRecipe(in: rawSource).cameraLook)
        XCTAssertNil(rawSource.baseline().cameraLook)

        let otherBrandRAW = EditRecipe(sourceDigest: String(repeating: "c", count: 64), decoderVersion: "8",
                                       baselineExposure: 0.15, baselineTemperature: 6200, baselineTint: -6,
                                       exposure: -0.2, temperature: 6200, tint: -6)
        var options = RecipePasteOptions()
        options.tone = false; options.whiteBalance = false; options.color = false
        options.curves = false; options.zones = false
        XCTAssertFalse(options.hasSelection, "Camera Look defaults to false in ordinary paste until explicitly selected")
        options.cameraLook = true
        XCTAssertTrue(options.hasSelection)

        let pastedRAW = try otherBrandRAW.pasting(rawSource, options: options)
        XCTAssertEqual(pastedRAW.cameraLook, look)
        XCTAssertEqual(pastedRAW.exposure, -0.2, "Pasting only Camera Look must preserve target exposure")

        // Ordinary raster (JPEG/PNG/TIFF) and linear merge masters must reject non-nil cameraLook and skip paste cleanly.
        for decoder in [EditRecipe.rasterDecoderVersion, EditRecipe.linearCompositeDecoderVersion] {
            var raster = EditRecipe(sourceDigest: digest, decoderVersion: decoder,
                                    baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0,
                                    temperature: 5500, tint: 0)
            let skipped = try raster.pasting(rawSource, options: options)
            XCTAssertNil(skipped.cameraLook)
            XCTAssertFalse(raster.transferNotes(from: rawSource, options: options).isEmpty)

            raster.cameraLook = look
            XCTAssertThrowsError(try raster.validate(lookLibrary: library))

            var mcpRaster = raster
            mcpRaster.cameraLook = nil
            XCTAssertThrowsError(try MCPDevelopParameters.change(
                .globalAdjustments,
                args: ["adjustments": ["camera_look": ["id": .string(look.id), "version": .int(look.version)]]],
                recipe: &mcpRaster
            ))
        }

        // MCP globalAdjustments reads/writes camera_look on RAW while localAdjustments omits it.
        var mcpRAW = otherBrandRAW
        try MCPDevelopParameters.change(
            .globalAdjustments,
            args: ["adjustments": ["camera_look": ["id": .string(look.id), "version": .int(look.version)]]],
            recipe: &mcpRAW
        )
        XCTAssertEqual(mcpRAW.cameraLook, look)
        XCTAssertEqual(MCPDevelopParameters.describe(mcpRAW)["camera_look"],
                       ["id": .string(look.id), "version": .int(look.version)])
        let localBasicProps = MCPDevelopParameters.schema(.localAdjustments)
            .objectValue?["properties"]?.objectValue?["basic"]?.objectValue?["properties"]?.objectValue
        XCTAssertNil(localBasicProps?["camera_look"])
    }

    func testPublicFujiXS10AndSonyA7RVEndToEndWorkflowPersistenceAndExports() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-cameralook-e2e-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fujiInput = try MoreRAWTests.request("fuji_xs10_14bit_lossless.RAF")
        let sonyInput = try MoreRAWTests.request("a7rv_61mp_compressed.ARW")
        let look = CameraLookSelection(id: "diagnostic.test-table", version: 1)
        let library = CameraLookLibrary(includesDiagnosticLooks: true)

        let catalogURL = workspace.appendingPathComponent("CameraLookE2E.phoscat")
        var store: CatalogStore? = try CatalogStore(fileURL: catalogURL, create: true)

        for (label, input) in [("Fuji X-S10", fujiInput), ("Sony A7R V", sonyInput)] {
            let sourceFile = URL(fileURLWithPath: input.root.path).appendingPathComponent(input.photo.relativePath)
            let originalSHA = try SafeFileWriter.sha256(sourceFile)

            let rootURL = URL(fileURLWithPath: input.root.path)
            let savedRoot = try store!.addRoot(url: rootURL, bookmark: AccessLease.bookmark(rootURL, readOnly: true))
            var photo = input.photo
            photo.rootID = savedRoot.id
            try store!.index(photo)

            let pipeline = ImagePipeline(cameraLooks: library)
            let baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: savedRoot, recipe: nil))
            XCTAssertNil(baseline.cameraLook)

            // 1. Default Rendering (nil) matches a fresh pipeline byte-for-byte.
            let defaultReq = ImageRequest(photo: photo, root: savedRoot, recipe: baseline)
            let defaultInteractive = try await pipeline.renderInteractive(defaultReq, longEdge: 512)
            let freshDefaultInteractive = try await ImagePipeline(cameraLooks: library).renderInteractive(defaultReq, longEdge: 512)
            XCTAssertEqual(try bytes(defaultInteractive), try bytes(freshDefaultInteractive), "\(label): Default rendering must be deterministic")

            // 2. Adjust Exposure (+0.65 EV) and add a local Radial Gradient mask before touching Camera Look.
            var maskSettings = LocalDevelopSettings()
            maskSettings.asShotWhiteBalance = false
            maskSettings.temperature = 6100
            maskSettings.develop.shadows = 45
            let maskID = UUID(uuidString: "00000000-0000-0000-0000-00000000CA11")!
            let radialMask = LocalAdjustment(
                id: maskID,
                name: "Test Radial",
                components: [MaskComponent(tool: .radial)],
                exposure: 0.45,
                settings: maskSettings
            )
            var editedDefault = baseline
            editedDefault.schemaVersion = 3
            editedDefault.maskVersion = 3
            editedDefault.exposure = 0.65
            editedDefault.localAdjustments = [radialMask]

            let editedDefaultReq = ImageRequest(photo: photo, root: savedRoot, recipe: editedDefault)
            let beforeLookInteractive = try await pipeline.renderInteractive(editedDefaultReq, longEdge: 512)
            let beforeLookQuality = try await pipeline.render(editedDefaultReq, longEdge: 320, pixelFormat: .RGBA16)

            // 3. Apply the same Test Lookup Table to both cameras; exposure & mask remain intact and pixels update immediately.
            var withLook = editedDefault
            withLook.cameraLook = look
            let withLookReq = ImageRequest(photo: photo, root: savedRoot, recipe: withLook)
            let lookInteractive = try await pipeline.renderInteractive(withLookReq, longEdge: 512)
            let freshLookInteractive = try await ImagePipeline(cameraLooks: library).renderInteractive(withLookReq, longEdge: 512)

            XCTAssertEqual(withLook.exposure, 0.65)
            XCTAssertEqual(withLook.localAdjustments, [radialMask])
            XCTAssertNotEqual(try bytes(lookInteractive), try bytes(beforeLookInteractive),
                              "\(label): Applying Test Lookup Table must invalidate cached spatial preview and change output")
            XCTAssertEqual(try bytes(lookInteractive), try bytes(freshLookInteractive),
                           "\(label): Cached interactive pipeline must match a cold pipeline when switching looks")

            // 4. Switch back to Default Rendering: exposure & mask are still intact and pixels match step 2 byte-for-byte.
            var revertedDefault = withLook
            revertedDefault.cameraLook = nil
            XCTAssertEqual(revertedDefault.exposure, 0.65)
            XCTAssertEqual(revertedDefault.localAdjustments, [radialMask])
            let revertedReq = ImageRequest(photo: photo, root: savedRoot, recipe: revertedDefault)
            let revertedInteractive = try await pipeline.renderInteractive(revertedReq, longEdge: 512)
            let revertedQuality = try await pipeline.render(revertedReq, longEdge: 320, pixelFormat: .RGBA16)
            XCTAssertEqual(try bytes(revertedInteractive), try bytes(beforeLookInteractive),
                           "\(label): Switching back to Default Rendering must restore exact interactive pixels")
            XCTAssertEqual(try bytes(revertedQuality), try bytes(beforeLookQuality),
                           "\(label): Switching back to Default Rendering must restore exact quality pixels")

            // 5. Select Test Lookup Table, persist to CatalogStore, close and reopen catalog, and verify preview + 1:1 tile + exports.
            try store!.saveRecipe(id: photo.id, recipe: withLook, title: "Camera Look: Test Lookup Table")
            store = nil
            store = try CatalogStore(fileURL: catalogURL, create: false)

            let savedPhoto = try XCTUnwrap(try store!.photos().first(where: { $0.id == photo.id }))
            let reopenedRecipe = try XCTUnwrap(try savedPhoto.recipe.map { try JSONDecoder().decode(EditRecipe.self, from: $0) })
            XCTAssertEqual(reopenedRecipe.cameraLook, look, "\(label): Camera look selection must persist across catalog reopen")
            XCTAssertEqual(reopenedRecipe.exposure, 0.65, "\(label): Exposure must persist alongside camera look")
            XCTAssertEqual(reopenedRecipe.localAdjustments, [radialMask], "\(label): Local masks must persist alongside camera look")

            let reopenedPipeline = ImagePipeline(cameraLooks: library)
            let reopenedReq = ImageRequest(photo: savedPhoto, root: savedRoot, recipe: reopenedRecipe)
            let quality = try await reopenedPipeline.render(reopenedReq, longEdge: 320, pixelFormat: .RGBA16)
            XCTAssertNotEqual(try bytes(quality), try bytes(beforeLookQuality))

            let tileRegion = CGRect(x: 120, y: 120, width: 160, height: 160)
            let tile = try await reopenedPipeline.render(reopenedReq, longEdge: nil, nativePixelRegion: { _ in tileRegion })
            XCTAssertEqual(tile.image.width, 160)
            XCTAssertEqual(tile.image.height, 160)

            for format in [ExportFormat.tiff, .png, .jpeg] {
                let outURL = workspace.appendingPathComponent("\(photo.id).\(format.fileExtension)")
                _ = try await reopenedPipeline.export(reopenedReq,
                                                      staging: outURL,
                                                      options: ExportOptions(format: format, longEdge: 320, jpegMatte: .white))
                let imgSource = try XCTUnwrap(CGImageSourceCreateWithURL(outURL as CFURL, nil))
                let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imgSource, 0, nil))
                XCTAssertEqual(exported.width, quality.image.width)
                XCTAssertEqual(exported.height, quality.image.height)
                if format == .tiff {
                    XCTAssertEqual(exported.bitsPerComponent, 16)
                    let expectedPixels = renderOutputPixels(quality.image)
                    let exportedPixels = renderOutputPixels(exported)
                    let maxDiff = zip(expectedPixels, exportedPixels).map { abs($0 - $1) }.max() ?? .infinity
                    XCTAssertLessThanOrEqual(maxDiff, 4.0 / 65535.0,
                                             "\(label): 16-bit TIFF export must match quality preview within 16-bit quantization")
                } else if format == .png {
                    let expectedPixels = renderOutputPixels(quality.image)
                    let exportedPixels = renderOutputPixels(exported)
                    let maxDiff = zip(expectedPixels, exportedPixels).map { abs($0 - $1) }.max() ?? .infinity
                    XCTAssertLessThanOrEqual(maxDiff, 2.0 / 255.0,
                                             "\(label): PNG export must match quality preview within 8-bit quantization")
                }
            }

            XCTAssertEqual(try SafeFileWriter.sha256(sourceFile), originalSHA, "\(label): Original RAW file must remain untouched")
        }
    }

    @MainActor func testDevelopPanelLayoutIvoryAndGraphiteThemesAndRasterLocalHiding() async throws {
        let look = CameraLookSelection(id: "diagnostic.test-table", version: 1)
        let digest = String(repeating: "d", count: 64)
        var rawRecipe = EditRecipe(sourceDigest: digest, decoderVersion: "8",
                                   baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0,
                                   exposure: 0.65, temperature: 5500, tint: 0, cameraLook: look)
        rawRecipe.schemaVersion = 3
        rawRecipe.maskVersion = 3
        rawRecipe.localAdjustments = [LocalAdjustment(name: "Radial 1", components: [MaskComponent(tool: .radial)], exposure: 0.45)]

        let model = AppModel()
        model.recipe = rawRecipe
        model.canEdit = true
        model.editMode = true

        let suite = "camera-look-layout-" + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(true, forKey: "developBasicOpen")

        let expectedLabel = L10n.text("cameraLook.label", defaultValue: "Camera Look")
        let expectedValue = CameraLookLibrary.shared.title(for: look)
        func hasCameraLookControl(_ element: Any) -> Bool {
            if let popup = element as? NSPopUpButton {
                if popup.accessibilityIdentifier() == "camera-look-menu"
                    || popup.accessibilityLabel() == expectedLabel
                    || popup.title.contains(expectedValue)
                    || popup.itemTitles.contains(expectedValue) {
                    return true
                }
            }
            if let ax = element as? NSAccessibilityProtocol {
                if ax.accessibilityIdentifier() == "camera-look-menu" || ax.accessibilityLabel() == expectedLabel {
                    return true
                }
                if let children = ax.accessibilityChildren(), children.contains(where: { hasCameraLookControl($0) }) {
                    return true
                }
            }
            if let view = element as? NSView, view.subviews.contains(where: { hasCameraLookControl($0) }) {
                return true
            }
            return false
        }

        for theme in [ChromeTheme.ivory, .graphite] {
            prefs.set(theme.rawValue, forKey: "chromeTheme")
            for width in [304.0, 336.0, 400.0] {
                let size = CGSize(width: width, height: 680)
                let host = NSHostingView(
                    rootView: ScrollView { DevelopPanel(model: model) }
                        .frame(width: width, height: size.height)
                        .background(Theme.panel)
                        .defaultAppStorage(prefs)
                        .preferredColorScheme(theme.colorScheme)
                )
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                window.contentView = host
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1, "Panel must not overflow horizontally at \(width)pt")
                XCTAssertTrue(hasCameraLookControl(host), "RAW global Basic panel must expose Camera Look control")

                if width == 336 {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                    attachment.name = "camera-look-panel-\(theme.rawValue)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                window.contentView = nil
            }
        }

        // Local mask adjustment panel must hide Camera Look.
        let localHost = NSHostingView(
            rootView: ScrollView { DevelopPanel(model: model, local: true) }
                .frame(width: 336, height: 520)
                .background(Theme.panel)
                .defaultAppStorage(prefs)
        )
        let localWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 336, height: 520),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        localWindow.contentView = localHost
        try await Task.sleep(for: .milliseconds(60))
        localHost.layoutSubtreeIfNeeded()
        XCTAssertFalse(hasCameraLookControl(localHost), "Local mask panel must not expose Camera Look")
        localWindow.contentView = nil

        // Ordinary raster / linear composite recipes must hide Camera Look.
        for decoder in [EditRecipe.rasterDecoderVersion, EditRecipe.linearCompositeDecoderVersion] {
            model.recipe = EditRecipe(sourceDigest: digest, decoderVersion: decoder,
                                      baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0,
                                      temperature: 5500, tint: 0)
            let rasterHost = NSHostingView(
                rootView: ScrollView { DevelopPanel(model: model) }
                    .frame(width: 336, height: 520)
                    .background(Theme.panel)
                    .defaultAppStorage(prefs)
            )
            let rasterWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 336, height: 520),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            rasterWindow.contentView = rasterHost
            try await Task.sleep(for: .milliseconds(60))
            rasterHost.layoutSubtreeIfNeeded()
            XCTAssertFalse(hasCameraLookControl(rasterHost),
                           "Raster decoder \(decoder) must not expose Camera Look")
            rasterWindow.contentView = nil
        }

        // Capture full-window WorkspaceView screenshots in Ivory and Graphite with Fuji X-S10 RAF and Sony A7R V ARW.
        let workspaceFolder = FileManager.default.temporaryDirectory.appendingPathComponent("camera-look-ws-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceFolder) }

        let fujiInput = try MoreRAWTests.request("fuji_xs10_14bit_lossless.RAF")
        let sonyInput = try MoreRAWTests.request("a7rv_61mp_compressed.ARW")
        let catURL = workspaceFolder.appendingPathComponent("WS.phoscat")
        let wsStore = try CatalogStore(fileURL: catURL, create: true)
        let rootURL = URL(fileURLWithPath: fujiInput.root.path)
        let wsRoot = try wsStore.addRoot(url: rootURL, bookmark: AccessLease.bookmark(rootURL, readOnly: true))

        var fujiPhoto = fujiInput.photo; fujiPhoto.rootID = wsRoot.id; try wsStore.index(fujiPhoto)
        var sonyPhoto = sonyInput.photo; sonyPhoto.rootID = wsRoot.id; try wsStore.index(sonyPhoto)

        let pipeline = ImagePipeline(cameraLooks: CameraLookLibrary(includesDiagnosticLooks: true))
        for p in [fujiPhoto, sonyPhoto] {
            var r = try await pipeline.baseline(ImageRequest(photo: p, root: wsRoot, recipe: nil))
            r.schemaVersion = 3
            r.maskVersion = 3
            r.exposure = 0.65
            r.cameraLook = look
            r.localAdjustments = [LocalAdjustment(name: "Radial 1", components: [MaskComponent(tool: .radial)], exposure: 0.45)]
            try wsStore.saveRecipe(id: p.id, recipe: r, title: "Camera Look: Test Lookup Table")
        }

        let wsModel = AppModel()
        wsModel.catalog = wsStore
        try wsModel.reload()
        defer { wsModel.choose([], active: nil); wsModel.catalog = nil }
        wsModel.editMode = true

        for (theme, targetPhoto, tag) in [(ChromeTheme.ivory, fujiPhoto, "workspace-ivory-fuji-xs10"),
                                          (ChromeTheme.graphite, sonyPhoto, "workspace-graphite-sony-a7rv")] {
            prefs.set(theme.rawValue, forKey: "chromeTheme")
            wsModel.choose([targetPhoto.id], active: targetPhoto.id)
            for _ in 0..<120 where wsModel.image == nil || wsModel.recipe?.cameraLook != look {
                try await Task.sleep(for: .milliseconds(100))
            }
            let size = CGSize(width: 1280, height: 820)
            let host = NSHostingView(
                rootView: WorkspaceView(model: wsModel)
                    .defaultAppStorage(prefs)
                    .preferredColorScheme(theme.colorScheme)
            )
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            host.frame = container.bounds
            container.addSubview(host)
            window.contentView = container
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = tag
            attachment.lifetime = .keepAlways
            add(attachment)
            window.contentView = nil
        }
    }
}
