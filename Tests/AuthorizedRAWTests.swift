import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import Phosdeck

/// Opt-in, private real-camera regression. A local request must contain a user-granted
/// security-scoped root bookmark. No samples, bookmarks or generated photos are bundled.
final class AuthorizedRAWTests: XCTestCase {
    struct Request: Codable { let root: StorageRoot; let maxSamples: Int }
    func testAuthorizedRAWWorkflow() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OhMyLRC/RawValidation")
        let requestURL = support.appendingPathComponent("request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else { throw XCTSkip("No explicitly authorized private RAW validation request") }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        let lease = try AccessLease(bookmark: request.root.bookmark)
        defer { withExtendedLifetime(lease) {} }
        let output = support.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Consume the opt-in request, so the normal test suite never repeatedly scans private samples.
        try FileManager.default.moveItem(at: requestURL, to: output.appendingPathComponent("private-request.json"))
        guard let enumerator = FileManager.default.enumerator(at: lease.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { throw LRCError("Sample directory unavailable") }
        var urls = [URL]()
        while let url = enumerator.nextObject() as? URL { if url.pathExtension.lowercased() == "arw" { urls.append(url) } }
        urls.sort { $0.path < $1.path }
        XCTAssertFalse(urls.isEmpty)
        let pipeline = ImagePipeline()
        let interactivePipeline = ImagePipeline(cacheIntermediates: true)
        var rows = [[String: Any]]()
        var catalog: CatalogStore? = try CatalogStore(directory: output.appendingPathComponent("test-catalog"))
        let root = try catalog!.addRoot(url: lease.url, bookmark: request.root.bookmark)
        for (index, url) in urls.prefix(request.maxSamples).enumerated() {
            let label = String(format: "S%02d", index + 1)
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: lease.url)
            XCTAssertEqual(photo.camera, "ILCE-7RM5")
            try catalog!.index(photo)
            let initial = ImageRequest(photo: photo, root: root, recipe: nil)
            let baseline = try await pipeline.baseline(initial)
            try baseline.validate()
            let base = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: baseline), longEdge: 1024)
            let info = try metadata(url)
            let orientation = info["orientation"] as! Int
            XCTAssertEqual(Int(base.fullSize.width), orientation >= 5 ? photo.height : photo.width, label + " oriented width")
            XCTAssertEqual(Int(base.fullSize.height), orientation >= 5 ? photo.width : photo.height, label + " oriented height")
            try save(base.image, to: output.appendingPathComponent(label + "-baseline.jpg"))
            var edited = baseline
            edited.exposure = 0.5; edited.asShotWhiteBalance = false
            edited.temperature = min(15000, baseline.temperature + 500); edited.tint += 5
            edited.contrast = 1.1; edited.saturation = 0.9
            edited.develop.highlights = -45; edited.develop.shadows = 35
            edited.develop.whites = 12; edited.develop.blacks = -8
            edited.develop.texture = 20; edited.develop.clarity = 12
            edited.develop.dehaze = 10; edited.develop.vibrance = 20
            edited.develop.mixer[5] = HSLBand(hue: -20, saturation: 15, luminance: -10)
            edited.develop.grading.shadows = GradingTone(hue: 220, saturation: 20, luminance: 5)
            edited.develop.grading.midtones = GradingTone(hue: 35, saturation: 8)
            edited.develop.grading.highlights = GradingTone(hue: 45, saturation: 15)
            edited.develop.grading.blending = 65; edited.develop.grading.balance = 10
            edited.straightenDegrees = 3.5
            edited.quarterTurns = index % 2
            edited.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            let editedRequest = ImageRequest(photo: photo, root: root, recipe: edited)
            let draft = try await interactivePipeline.renderInteractive(editedRequest)
            XCTAssertLessThanOrEqual(max(draft.image.width, draft.image.height), 961)
            XCTAssertEqual(draft.orientedSourceSize, base.orientedSourceSize)
            var moving = edited
            var draftTimes: [Double] = []
            for value in [-20.0, 0, 20] {
                moving.develop.mixer[5].hue = value
                let frame = try await interactivePipeline.renderInteractive(ImageRequest(photo: photo, root: root, recipe: moving))
                draftTimes.append(frame.elapsed)
            }
            moving.temperature = min(50000, moving.temperature + 1000)
            let whiteBalanceFrame = try await interactivePipeline.renderInteractive(ImageRequest(photo: photo, root: root, recipe: moving))
            print("INTERACTIVE \(label) cold=\(draft.elapsed) cached=\(draftTimes) whiteBalance=\(whiteBalanceFrame.elapsed)")
            moving.develop.shadows = -45
            let changedSpatialRequest = ImageRequest(photo: photo, root: root, recipe: moving)
            let changedSpatial = try await interactivePipeline.renderInteractive(changedSpatialRequest)
            let freshSpatial = try await ImagePipeline().renderInteractive(changedSpatialRequest)
            XCTAssertLessThan(mae(changedSpatial.image, freshSpatial.image), 0.001, "Changing tone must invalidate the spatial preview cache")
            if index == 0 {
                let controls: [(String, WritableKeyPath<EditRecipe, Double>, [Double])] = [
                    ("exposure", \.exposure, [-0.2, 0.1, 0.3]),
                    ("temperature", \.temperature, [baseline.temperature + 100, baseline.temperature + 200, baseline.temperature + 300]),
                    ("tint", \.tint, [3, 6, 9]),
                    ("contrast", \.contrast, [0.9, 1, 1.1]),
                    ("highlights", \.develop.highlights, [-20, 0, 20]),
                    ("shadows", \.develop.shadows, [-20, 0, 20]),
                    ("whites", \.develop.whites, [-20, 0, 20]),
                    ("blacks", \.develop.blacks, [-20, 0, 20]),
                    ("texture", \.develop.texture, [-20, 0, 20]),
                    ("clarity", \.develop.clarity, [-20, 0, 20]),
                    ("dehaze", \.develop.dehaze, [-20, 0, 20]),
                    ("vibrance", \.develop.vibrance, [-20, 0, 20]),
                    ("saturation", \.saturation, [0.9, 1, 1.1])
                ]
                for (mode, baseRecipe) in [("isolated", baseline), ("stacked", edited)] {
                    for (name, key, values) in controls {
                        var variant = baseRecipe
                        if name == "temperature" || name == "tint" { variant.asShotWhiteBalance = false }
                        _ = try await interactivePipeline.renderInteractive(ImageRequest(photo: photo, root: root, recipe: variant))
                        var times: [Double] = []
                        for value in values {
                            variant[keyPath: key] = value
                            let frame = try await interactivePipeline.renderInteractive(ImageRequest(photo: photo, root: root, recipe: variant))
                            times.append(frame.elapsed)
                        }
                        print("BASIC_LATENCY \(mode) \(name) \(times)")
                    }
                }
            }
            // Same settings under the frozen legacy algorithm, for visual comparison.
            var legacy = edited; legacy.pipelineVersion = 1
            let legacyPreview = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: legacy), longEdge: 1024)
            try save(legacyPreview.image, to: output.appendingPathComponent(label + "-legacy-same-settings.jpg"))
            let preview = try await pipeline.render(editedRequest, longEdge: 1024)
            let destination = output.appendingPathComponent(label + "-edited.jpg")
            let staging = try SafeFileWriter.stage(in: output)
            let exportStart = Date()
            let size = try await pipeline.export(editedRequest, staging: staging, options: ExportOptions(longEdge: 1024, quality: 0.95))
            let exportSeconds = Date().timeIntervalSince(exportStart)
            try SafeFileWriter.publish(staging, to: destination)
            XCTAssertLessThanOrEqual(max(size.0, size.1), 1024)
            XCTAssertEqual(size.0, preview.image.width); XCTAssertEqual(size.1, preview.image.height)
            let jpeg = try decode(destination)
            let difference = mae(preview.image, jpeg)
            XCTAssertLessThan(difference, 0.035, label + " preview/JPEG difference")
            try catalog!.setOrganization(ids: [photo.id], rating: 4, flag: 1)
            try catalog!.saveRecipe(id: photo.id, recipe: edited)
            XCTAssertEqual(try SafeFileWriter.sha256(url), baseline.sourceDigest)
            var row = info
            row["pipelineVersion"] = baseline.pipelineVersion
            row["recipeSchemaVersion"] = edited.schemaVersion
            row["developControlsApplied"] = true
            row["legacySameSettingsMAE"] = mae(preview.image, legacyPreview.image)
            row["sample"] = label; row["decoder"] = baseline.decoderVersion
            row["temperature"] = baseline.baselineTemperature; row["tint"] = baseline.baselineTint
            row["baselineSeconds"] = base.elapsed; row["editedPreviewSeconds"] = preview.elapsed
            row["exportSeconds"] = exportSeconds; row["jpegMAE"] = difference
            row["baselineWidth"] = Int(base.fullSize.width); row["baselineHeight"] = Int(base.fullSize.height)
            row["exportWidth"] = size.0; row["exportHeight"] = size.1
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage); row["processPeakRSSBytes"] = usage.ru_maxrss
            if index < 3 { row["toneControlCandidates"] = try probeToneControls(url, label: label, output: output) }
            if index == 0 {
                var effects = [String: Double]()
                for control in ["exposure", "temperature", "tint", "contrast", "saturation"] {
                    var variant = baseline
                    switch control {
                    case "exposure": variant.exposure = 1
                    case "temperature": variant.asShotWhiteBalance = false; variant.temperature += 1500
                    case "tint": variant.asShotWhiteBalance = false; variant.tint += 25
                    case "contrast": variant.contrast = 1.4
                    default: variant.saturation = 0
                    }
                    let result = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: variant), longEdge: 1024)
                    effects[control] = mae(base.image, result.image)
                    XCTAssertGreaterThan(effects[control]!, 0.001, control + " should alter real RAW pixels")
                }
                row["controlPixelDifferences"] = effects
                let full = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: baseline), longEdge: nil)
                XCTAssertEqual(full.image.width, Int(base.fullSize.width)); XCTAssertEqual(full.image.height, Int(base.fullSize.height))
                row["fullResolutionSeconds"] = full.elapsed
                let fullDestination = try SafeFileWriter.stage(in: output)
                let fullSize = try await pipeline.export(editedRequest, staging: fullDestination, options: ExportOptions(longEdge: nil, quality: 0.9))
                XCTAssertEqual(fullSize.0, Int(preview.fullSize.width)); XCTAssertEqual(fullSize.1, Int(preview.fullSize.height))
                let publishedFull = output.appendingPathComponent(label + "-edited-full.jpg")
                try SafeFileWriter.publish(fullDestination, to: publishedFull)
                row["editedFullExportWidth"] = fullSize.0; row["editedFullExportHeight"] = fullSize.1
                let fullPreviewDifference = mae(preview.image, try decode(publishedFull))
                XCTAssertLessThan(fullPreviewDifference, 0.04, "full-size export must agree with the downscaled preview")
                row["fullExportPreviewMAE"] = fullPreviewDifference
            }
            rows.append(row)
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("metrics.json"), options: .atomic)
            print("RAW \(label): decoder=\(baseline.decoderVersion) orientation=\(orientation) preview=\(String(format: "%.3f", base.elapsed))s export=\(String(format: "%.3f", exportSeconds))s JPEG-MAE=\(difference)")
        }
        let before = try catalog!.photos()
        catalog = nil
        catalog = try CatalogStore(directory: output.appendingPathComponent("test-catalog"))
        XCTAssertEqual(try catalog!.photos(), before, "ratings, flags and recipes must survive reopening")
        print("REAL_RAW_REPORT_DIRECTORY=\(output.path)")
    }
    private func metadata(_ url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        return ["orientation": properties[kCGImagePropertyOrientation as String] as? Int ?? 1,
                "iso": exif[kCGImagePropertyExifISOSpeedRatings as String] ?? [],
                "highlightRecoverySupported": raw.isHighlightRecoverySupported,
                "highlightRecoveryDefault": raw.isHighlightRecoveryEnabled,
                "boostShadowDefault": raw.boostShadowAmount,
                "availableDecoders": raw.supportedDecoderVersions.map(\.rawValue)]
    }
    private func probeToneControls(_ url: URL, label: String, output: URL) throws -> [String: Any] {
        try autoreleasepool {
            let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
            var images = [CGImage]()
            for name in ["system-default", "highlight-recovery-off", "boost-shadow-1.5"] {
                let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
                raw.extendedDynamicRangeAmount = 0
                raw.scaleFactor = 0.125 // Exploratory comparison only; not production export.
                if name == "highlight-recovery-off" { raw.isHighlightRecoveryEnabled = false }
                if name == "boost-shadow-1.5" { raw.boostShadowAmount = 1.5 }
                let graph = ImagePipeline.resized(try XCTUnwrap(raw.outputImage), longEdge: 1024)
                let image = try XCTUnwrap(context.createCGImage(graph, from: graph.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
                try save(image, to: output.appendingPathComponent(label + "-" + name + ".jpg"))
                images.append(image)
            }
            return ["highlightRecoveryOffMAE": mae(images[0], images[1]), "boostShadow1_5MAE": mae(images[0], images[2]),
                    "note": "Exploratory 1/8 RAW scale; user acceptance and production mapping not frozen"]
        }
    }
    private func save(_ image: CGImage, to url: URL) throws {
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
    }
    private func decode(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: ImagePipeline.outputSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return bytes
    }
    private func mae(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        let a = pixels(lhs), b = pixels(rhs)
        var sum = 0.0
        for i in a.indices where i % 4 != 3 { sum += abs(Double(a[i]) - Double(b[i])) / 255 }
        return sum / (64 * 64 * 3)
    }
}
