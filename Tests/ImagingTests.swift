import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import GRDB
import Darwin
import AppKit
import SwiftUI
import Observation
import os
import MetalKit
@testable import Phosdeck

final class ImagingTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(orientation: Int = 1) throws -> URL {
        let url = directory.appendingPathComponent("fixture-\(orientation).jpg")
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40))
        let cg = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: orientation, kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.0]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    func testPublicRAWRepeatedQualityRendering() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("OhMyLRC/FeatureValidation")
        let url = folder.appendingPathComponent("public.ARW")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Public CC0 RAW not prepared") }
        print("NATIVE_PERF quality fixture ready")
        let root = StorageRoot(id: "public", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "CC0")
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: folder)
        let pipeline = ImagePipeline(), cached = ImagePipeline()
        var recipe = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        print("NATIVE_PERF quality baseline ready")
        print("NATIVE_PERF quality source=\(recipe.sourceDigest) decoder=\(recipe.decoderVersion) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        for edge: Int? in [2400, nil] {
            var times: [Double] = [], cachedTimes: [Double] = []
            for frame in 0..<4 {
                recipe.saturation = 1 + Double(frame) * 0.03
                // Prime the shared LUT so its construction is not attributed to
                // the first (uncached) renderer in this comparison.
                _ = try PerceptualColor.apply(CIImage(color: .gray), adjustments: recipe.develop, saturation: recipe.saturation)
                let request = ImageRequest(photo: photo, root: root, recipe: recipe)
                let reference = try await pipeline.render(request, longEdge: edge)
                let result = try await cached.render(request, longEdge: edge, reuseDecoded: true)
                print("NATIVE_PERF quality frame=\(frame) edge=\(edge ?? 0) equal=\(reference.image.dataProvider?.data == result.image.dataProvider?.data)")
                times.append(reference.elapsed * 1000); cachedTimes.append(result.elapsed * 1000)
                XCTAssertEqual(max(result.image.width, result.image.height), edge ?? max(photo.width, photo.height))
                XCTAssertTrue(reference.image.dataProvider?.data == result.image.dataProvider?.data, "Full-float decode reuse must preserve quality pixels; \(qualityDifference(reference.image, result.image))")
            }
            let bytes = await cached.qualityCacheBytes
            if edge == nil { XCTAssertGreaterThan(bytes, 0) } else { XCTAssertEqual(bytes, 0) }
            XCTAssertLessThanOrEqual(bytes, 512 * 1024 * 1024)
            print("NATIVE_PERF quality edge=\(edge ?? 0) uncached_ms=\(times) cached_ms=\(cachedTimes) bytes=\(bytes)")
        }
        for change in 0..<15 {
            switch change {
            case 0: recipe.exposure = 0.5
            case 1: recipe.asShotWhiteBalance = false; recipe.temperature += 600; recipe.tint += 5
            case 2:
                if let sharpness = try await pipeline.rawDefaults(ImageRequest(photo: photo, root: root, recipe: recipe)).sharpness {
                    recipe.rawDetails.sharpness = sharpness > 0.5 ? 0.2 : 0.8
                }
            case 3: recipe.quarterTurns = 1; recipe.crop.width = 0.7
            case 4:
                recipe.develop.clarity = 15; recipe.develop.texture = -10; recipe.develop.dehaze = 20
            case 5:
                recipe.develop = DevelopAdjustments()
                recipe.schemaVersion = 3; recipe.maskVersion = 2
                var range = MaskComponent(tool: .luminance)
                range.lower = 0.2; range.upper = 0.8
                var local = LocalAdjustment(components: [range])
                local.exposure = 0.3; local.settings = LocalDevelopSettings()
                local.settings?.develop.texture = 12
                local.refinement = MaskRefinement(edgeRadius: 0.1, blurRadius: 0.05)
                var radial = LocalAdjustment(components: [MaskComponent(tool: .radial)])
                radial.contrast = 1.1; radial.saturation = 0.8
                recipe.localAdjustments = [local, radial]
            case 6:
                recipe.localAdjustments[0].exposure = -0.2
                recipe.localAdjustments[0].components[0].upper = 0.6
                recipe.localAdjustments.reverse()
            case 7:
                for index in recipe.localAdjustments.indices { recipe.localAdjustments[index].settings?.develop.texture = 0 }
            case 8: recipe.straightenDegrees = 1.5
            case 9:
                recipe.straightenDegrees = 0
                recipe.localAdjustments = []
                recipe.develop.mixer[0].hue = 10
            case 10:
                recipe.develop.curves = ToneCurves(); recipe.develop.curves?.channels[0][2].y = 0.6
            case 11:
                recipe.develop.curves = nil
                recipe.develop.grading.midtones = GradingTone(hue: 220, saturation: 20, luminance: 5)
            case 12: recipe.vignette.amount = -20; recipe.grain.amount = 15
            case 13:
                recipe.vignette = CreativeVignette(); recipe.grain.amount = 0
                recipe.develop.blackAndWhite = true; recipe.develop.vibrance = 20
            default: recipe.develop = DevelopAdjustments(); recipe.contrast = 1.2
            }
            let request = ImageRequest(photo: photo, root: root, recipe: recipe)
            let reference = try await pipeline.render(request, longEdge: nil)
            let result = try await cached.render(request, longEdge: nil, reuseDecoded: true)
            print("NATIVE_PERF quality invalidation=\(change) equal=\(reference.image.dataProvider?.data == result.image.dataProvider?.data)")
            XCTAssertTrue(reference.image.dataProvider?.data == result.image.dataProvider?.data, "Screen optimization must preserve the uncached quality pixels; change=\(change) \(qualityDifference(reference.image, result.image))")
            let bytes = await cached.qualityCacheBytes
            XCTAssertEqual(bytes > 0, change < 3, "Cropped RAW and unverified operations must keep the full quality graph")
        }
        recipe.contrast = 1
        // Exercise budget, depth and source invalidation with an eligible full-frame request.
        recipe.crop = Crop()
        let limited = ImagePipeline(qualityCacheLimit: 1)
        let request = ImageRequest(photo: photo, root: root, recipe: recipe)
        let reference = try await pipeline.render(request, longEdge: nil)
        let result = try await limited.render(request, longEdge: nil, reuseDecoded: true)
        XCTAssertTrue(reference.image.dataProvider?.data == result.image.dataProvider?.data)
        let limitedBytes = await limited.qualityCacheBytes
        XCTAssertEqual(limitedBytes, 0)
        let deepReference = try await pipeline.render(request, longEdge: 480, pixelFormat: .RGBA16)
        let deepResult = try await cached.render(request, longEdge: 480, pixelFormat: .RGBA16, reuseDecoded: true)
        XCTAssertTrue(deepReference.image.dataProvider?.data == deepResult.image.dataProvider?.data, "High-depth output keeps its existing graph")
        let clone = directory.appendingPathComponent("copy.ARW")
        try FileManager.default.copyItem(at: url, to: clone)
        let cloneRoot = StorageRoot(id: "copy", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "CC0 copy")
        let clonePhoto = try ReferenceImporter.inspect(url: clone, root: cloneRoot, rootURL: directory)
        let cloneRequest = ImageRequest(photo: clonePhoto, root: cloneRoot, recipe: recipe)
        _ = try await cached.render(cloneRequest, longEdge: nil, reuseDecoded: true)
        let primedBytes = await cached.qualityCacheBytes
        XCTAssertGreaterThan(primedBytes, 0, "The digest check must exercise a populated cache")
        let identity = try FileIdentity.read(clone), handle = try FileHandle(forUpdating: clone)
        try handle.seek(toOffset: UInt64(identity.size - 1))
        let last = try XCTUnwrap(handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: UInt64(identity.size - 1)); try handle.write(contentsOf: Data([last ^ 1])); try handle.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(identity.modifiedSeconds), tv_nsec: Int(identity.modifiedNanoseconds))]
        XCTAssertEqual(utimensat(AT_FDCWD, clone.path, &times, 0), 0)
        XCTAssertEqual(try FileIdentity.read(clone), identity)
        do { _ = try await cached.render(cloneRequest, longEdge: nil, reuseDecoded: true); XCTFail("Cached pixels must not bypass digest validation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("摘要")) }
        let failedBytes = await cached.qualityCacheBytes
        XCTAssertEqual(failedBytes, 0, "A failed render releases its cached input")
        _ = try await cached.render(request, longEdge: nil, reuseDecoded: true)
        let beforeRasterBytes = await cached.qualityCacheBytes
        XCTAssertGreaterThan(beforeRasterBytes, 0)
        let raster = try fixture()
        let rasterRoot = StorageRoot(id: "raster", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "synthetic")
        _ = try await cached.render(ImageRequest(photo: ReferenceImporter.inspect(url: raster, root: rasterRoot, rootURL: directory), root: rasterRoot, recipe: nil), longEdge: 80, reuseDecoded: true)
        let clearedBytes = await cached.qualityCacheBytes
        XCTAssertEqual(clearedBytes, 0, "Changing to a raster photo releases the old RAW")
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 { print("NATIVE_PERF quality test_host_peak_rss_bytes=\(usage.ru_maxrss)") }
    }
    /// Keep the strict whole-provider assertion, but distinguish real samples
    /// from row padding if a different CI / GPU environment fails it.
    func testPublicRAWQualityReusePreservesGeometryPixels() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let folder = support.appendingPathComponent("OhMyLRC/FeatureValidation")
        let url = folder.appendingPathComponent("public.ARW")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Public CC0 RAW not prepared") }
        let digest = try SafeFileWriter.sha256(url)
        let root = StorageRoot(id: "public", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "CC0")
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: folder)
        let fresh = ImagePipeline(), cached = ImagePipeline()
        var base = try await fresh.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
        base.exposure = 0.5; base.saturation = 1.09; base.asShotWhiteBalance = false
        base.temperature += 600; base.tint += 5
        if let sharpness = try await fresh.rawDefaults(ImageRequest(photo: photo, root: root, recipe: base)).sharpness {
            base.rawDetails.sharpness = sharpness > 0.5 ? 0.2 : 0.8
        }
        let cases: [(String, Int, Crop, Bool, Bool)] = [
            ("full", 0, Crop(), false, false),
            ("rotate90", 1, Crop(), false, false),
            ("crop", 0, Crop(width: 0.7), false, false),
            ("rotate90-crop", 1, Crop(width: 0.7), false, false),
            ("offset-crop", 0, Crop(x: 0.1, y: 0.2, width: 0.7, height: 0.6), false, false),
            ("mirror", 0, Crop(), true, false),
            ("rotate270-both-mirrors", 3, Crop(), true, true),
            ("full-again", 0, Crop(), false, false)
        ]
        for (name, turns, crop, horizontal, vertical) in cases {
            var recipe = base
            recipe.quarterTurns = turns; recipe.crop = crop
            recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
            let request = ImageRequest(photo: photo, root: root, recipe: recipe)
            let reference = try await fresh.render(request, longEdge: nil)
            for frame in 0..<2 {
                let result = try await cached.render(request, longEdge: nil, reuseDecoded: true)
                let equal = reference.image.dataProvider?.data == result.image.dataProvider?.data
                let bytes = await cached.qualityCacheBytes
                print("RAW_QUALITY_GEOMETRY name=\(name) frame=\(frame) equal=\(equal) cacheBytes=\(bytes) \(qualityDifference(reference.image, result.image))")
                XCTAssertTrue(equal, "RAW geometry must preserve the full quality graph: \(name), frame=\(frame); \(qualityDifference(reference.image, result.image))")
                XCTAssertEqual(bytes > 0, crop == Crop(), "A crop clears decoded RAW; returning to the full frame restores reuse")
            }
        }
        XCTAssertEqual(try SafeFileWriter.sha256(url), digest)
    }

    private func qualityDifference(_ reference: CGImage, _ result: CGImage) -> String {
        let layout = "reference=\(reference.width)×\(reference.height)/\(reference.bitsPerPixel)bpp/row\(reference.bytesPerRow)/info\(reference.bitmapInfo.rawValue) result=\(result.width)×\(result.height)/\(result.bitsPerPixel)bpp/row\(result.bytesPerRow)/info\(result.bitmapInfo.rawValue)"
        guard reference.width == result.width, reference.height == result.height,
              reference.bitsPerPixel == 32, result.bitsPerPixel == 32,
              let a = reference.dataProvider?.data as Data?, let b = result.dataProvider?.data as Data?, a != b else { return layout }
        var changed = 0, maxDelta = 0, first: [String] = []
        for y in 0..<reference.height {
            for x in 0..<reference.width {
                for channel in 0..<4 {
                    let i = y * reference.bytesPerRow + x * 4 + channel
                    let j = y * result.bytesPerRow + x * 4 + channel
                    guard i < a.count, j < b.count else { return layout + " truncated provider" }
                    let delta = abs(Int(a[i]) - Int(b[j]))
                    if delta > 0 {
                        changed += 1; maxDelta = max(maxDelta, delta)
                        if first.count < 8 { first.append("(\(x),\(y),c\(channel)):\(a[i])→\(b[j])") }
                    }
                }
            }
        }
        return layout + " activeBytesChanged=\(changed) maxDelta=\(maxDelta) first=\(first) providerBytes=\(a.count)/\(b.count)"
    }
    func testAllEXIFOrientationsAndJPEGReadback() async throws {
        let pipeline = ImagePipeline()
        let bookmark = try AccessLease.bookmark(directory, readOnly: true)
        let root = StorageRoot(id: "r", path: directory.path, bookmark: bookmark, label: "synthetic only")
        for orientation in 1...8 {
            let url = try fixture(orientation: orientation)
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
            let staging = try SafeFileWriter.stage(in: directory)
            let size = try await pipeline.export(ImageRequest(photo: photo, root: root, recipe: nil), staging: staging, options: ExportOptions(longEdge: 40, quality: 0.9))
            XCTAssertEqual(size.0, orientation >= 5 ? 20 : 40)
            XCTAssertEqual(size.1, orientation >= 5 ? 40 : 20)
            try ImagePipeline.verifyExport(staging, width: size.0, height: size.1)
        }
    }
    func testChangedSourceRefusesRendering() async throws {
        let url = try fixture()
        let root = StorageRoot(id: "r", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "test")
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
        try Data("changed".utf8).write(to: url)
        do { _ = try await ImagePipeline().render(ImageRequest(photo: photo, root: root, recipe: nil), longEdge: 100); XCTFail("must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("来源")) }
    }
    func testDigestRejectsChangesWithUnchangedFileIdentity() async throws {
        let url = try fixture()
        let root = StorageRoot(id: "r", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "test")
        var photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
        photo.digest = try SafeFileWriter.sha256(url)
        let identity = try FileIdentity.read(url)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 12); try handle.write(contentsOf: Data([42])); try handle.close()
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(identity.modifiedSeconds), tv_nsec: Int(identity.modifiedNanoseconds))]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        XCTAssertEqual(try FileIdentity.read(url), identity)
        do { _ = try await ImagePipeline().render(ImageRequest(photo: photo, root: root, recipe: nil), longEdge: 100); XCTFail("digest must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("摘要"), error.localizedDescription) }
    }
    func testGeometryRotationThenCropAndInvalidRecipe() throws {
        let image = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40))
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        recipe.quarterTurns = 1
        recipe.crop = Crop(x: 0, y: 0.25, width: 1, height: 0.5)
        try recipe.validate()
        let output = try ImagePipeline.geometry(image, recipe: recipe)
        XCTAssertEqual(output.extent.width, 40, accuracy: 0.001)
        XCTAssertEqual(output.extent.height, 40, accuracy: 0.001)
        recipe.exposure = .nan; XCTAssertThrowsError(try recipe.validate())
        recipe.exposure = 0; recipe.pipelineVersion = 999; XCTAssertThrowsError(try recipe.validate())
    }
    func testPerceptualContrastRetainsOrdinaryShadowsAndLegacyRecipe() throws {
        let patch = CIImage(color: CIColor(red: 0.03, green: 0.03, blue: 0.03, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        recipe.contrast = 1.1
        func pixel(_ value: EditRecipe) -> Float {
            var rgba = [Float](repeating: 0, count: 4)
            context.render(ImagePipeline.colorControls(patch, recipe: value), toBitmap: &rgba, rowBytes: 16, bounds: patch.extent, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return rgba[0]
        }
        XCTAssertGreaterThan(pixel(recipe), 0.005)
        recipe.pipelineVersion = 0
        XCTAssertLessThan(pixel(recipe), 0.001)
        XCTAssertEqual(recipe.baseline().pipelineVersion, 0)
        XCTAssertEqual(recipe.resetForCurrentPipeline().pipelineVersion, 2)
    }
    func testPresetCropUsesOrientedPortraitCanvas() {
        let canvas = CGSize(width: 6336, height: 9504)
        for turns in 0...3 {
            let crop = Crop.centered(aspectRatio: 1.5, orientedCanvas: canvas, quarterTurns: turns)
            let width = turns % 2 == 0 ? canvas.width : canvas.height
            let height = turns % 2 == 0 ? canvas.height : canvas.width
            XCTAssertEqual(width * crop.width / (height * crop.height), 1.5, accuracy: 0.000001)
        }
    }
    func testMigrationFailureRollsBack() throws {
        let catalog = try CatalogStore(directory: directory.appendingPathComponent("catalog"))
        let backup = directory.appendingPathComponent("before.sqlite")
        try catalog.backup(to: backup)
        var migration = DatabaseMigrator()
        migration.registerMigration("intentional-failure") { db in
            try db.execute(sql: "CREATE TABLE shouldRollback(id INTEGER)")
            throw LRCError("injected migration failure")
        }
        XCTAssertThrowsError(try migration.migrate(catalog.database))
        let exists = try catalog.database.read { try $0.tableExists("shouldRollback") }
        XCTAssertFalse(exists)
        let restored = try CatalogStore.restore(from: backup, to: directory.appendingPathComponent("restored"))
        XCTAssertEqual(try restored.photos().count, 0)
    }
    func testThumbnailSurvivesMetadataChangesAndServiceRestartOffline() async throws {
        let url = try fixture(orientation: 6)
        let root = StorageRoot(id: "r", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "test")
        var photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
        let catalogID = UUID().uuidString
        let first = ThumbnailService()
        try await first.configure(catalogID: catalogID, gigabytes: 1)
        let original = try await first.image(photo: photo, root: root)
        XCTAssertEqual(original.width, 40); XCTAssertEqual(original.height, 80)
        try FileManager.default.removeItem(at: url)
        photo.rating = 5; photo.flag = -1; photo.recipeRevision = 8; photo.metadata = Data()
        let second = ThumbnailService()
        try await second.configure(catalogID: catalogID, gigabytes: 1)
        let cached = try await second.image(photo: photo, root: root)
        XCTAssertEqual(cached.width, original.width); XCTAssertEqual(cached.height, original.height)
        try await second.clear()
    }

    @MainActor func testPhotoItemKeepsImageDuringOrganizationAndMetadataChanges() async throws {
        let url = try fixture()
        let root = StorageRoot(id: "r", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "test")
        var photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
        let item = PhotoItem(); _ = item.view
        let service = ThumbnailService()
        item.configure(photo: photo, root: root, service: service, film: false)
        try await waitUntil { item.displayedImage != nil }
        let original = item.displayedImage
        for flag in [-1, 1, 0] {
            photo.flag = flag; photo.rating = 4; photo.metadata = Data(); photo.recipeRevision += 1
            item.configure(photo: photo, root: root, service: service, film: false)
            XCTAssertTrue(item.displayedImage === original, "P/X/U must preserve the visible image")
        }
        photo.identity = Data("different source".utf8)
        item.configure(photo: photo, root: root, service: service, film: false)
        XCTAssertNil(item.displayedImage, "A different source must never keep the old photo")
        item.prepareForReuse()
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for preview")
        throw LRCError("Test preview timed out")
    }

    @MainActor private final class PreviewProbe {
        var requests: [(ImageRequest, Bool)] = []
        var completion: CheckedContinuation<RenderedImage, Error>?
        func render(_ request: ImageRequest, _ interactive: Bool) async throws -> RenderedImage {
            requests.append((request, interactive))
            return try await withCheckedThrowingContinuation { completion = $0 }
        }
        func finish(width: Int) throws {
            let input = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width, height: 4))
            let image = try XCTUnwrap(CIContext().createCGImage(input, from: input.extent))
            let callback = try XCTUnwrap(completion); completion = nil
            callback.resume(returning: RenderedImage(image: image, fullSize: input.extent.size, orientedSourceSize: input.extent.size, histogram: nil, elapsed: 0.01))
        }
    }

    @MainActor func testContinuousPreviewCoalescesInputAndPublishesBeforeRelease() async throws {
        let probe = PreviewProbe(), quality = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in
            try await (interactive ? probe : quality).render(request, interactive)
        })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        model.requestPreview(interactive: true)
        try await waitUntil { probe.completion != nil }
        for value in 1...3 { model.recipe?.exposure = Double(value); model.requestPreview(interactive: true) }
        XCTAssertEqual(probe.requests.count, 1, "Only one in-flight render")
        try probe.finish(width: 10)
        try await waitUntil { probe.requests.count == 2 && probe.completion != nil }
        XCTAssertEqual(model.image?.width, 10, "Dragging must produce a visible frame before release")
        XCTAssertEqual(probe.requests[1].0.recipe?.exposure, 3, "Intermediate queued values are discarded")
        model.recipe?.exposure = 4; model.requestPreview()
        try await waitUntil { quality.completion != nil }
        try probe.finish(width: 13)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.image?.width, 10, "A draft superseded by release must not be published")
        XCTAssertEqual(probe.requests.count, 2)
        XCTAssertEqual(quality.requests.count, 1)
        XCTAssertFalse(quality.requests[0].1)
        XCTAssertEqual(quality.requests[0].0.recipe?.exposure, 4)
        try quality.finish(width: 14)
        try await waitUntil { model.image?.width == 14 }
        XCTAssertFalse(model.interactivePreview)
    }

    @MainActor func testCanvasKeepsPublishingWhileDrawableAcquisitionIsBlocked() async throws {
        let entered = XCTestExpectation(description: "background drawable acquisition")
        let release = DispatchSemaphore(value: 0)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let canvas = PhotoMetalCanvas(acquireDrawable: { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            finished.withLock { $0 = true }
            return nil
        })
        guard canvas.device != nil else { throw XCTSkip("Metal unavailable") }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        defer { window.orderOut(nil); window.contentView = nil; release.signal() }
        canvas.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        canvas.drawableSize = CGSize(width: 64, height: 64)
        let started = CACurrentMediaTime()
        canvas.draw()
        let elapsed = (CACurrentMediaTime() - started) * 1000
        print("NATIVE_PERF blocked-drawable main-ms=\(elapsed)")
        XCTAssertLessThan(elapsed, 100, "Display-buffer acquisition must not block native input")
        await fulfillment(of: [entered], timeout: 2)
        let model = AppModel(previewRenderer: Self.trackingModeRenderer())
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.jpg", identity: Data(), identityKey: "a", width: 12, height: 4)
        model.activeID = "a"; model.requestPreview()
        try await waitUntil { model.previewCurrent }
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(finished.withLock { $0 }, "Quality publication must finish while the display worker is still waiting")
    }

    @MainActor func testCanvasCoalescesFramesRetriesAndRejectsInvalidatedWork() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        for mode in 0..<4 {
            let commands = try XCTUnwrap(device.makeCommandQueue())
            let layer = CAMetalLayer(); layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.framebufferOnly = false
            layer.drawableSize = CGSize(width: 64, height: 64)
            let entered = XCTestExpectation(description: "first acquire")
            let release = DispatchSemaphore(value: 0)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let captured = OSAllocatedUnfairLock(uncheckedState: [CAMetalDrawable]())
            let renderer = CanvasFrameRenderer(commands: commands, acquire: { layer in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == 1 {
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 2)
                    if mode == 2 { return nil }
                }
                let drawable = layer.nextDrawable()
                if let drawable { captured.withLock { $0.append(drawable) } }
                return drawable
            })
            defer { renderer.invalidate(); release.signal() }
            let bounds = CGRect(x: 0, y: 0, width: mode == 3 ? 63.5 : 64, height: 64)
            renderer.submit(CIImage(color: .red).cropped(to: bounds), bounds: bounds, layer: layer, attempt: 1)
            await fulfillment(of: [entered], timeout: 2)
            if mode == 1 { renderer.invalidate() }
            for attempt in 2...101 {
                renderer.submit(CIImage(color: .blue).cropped(to: bounds), bounds: bounds, layer: layer, attempt: attempt)
            }
            release.signal()
            try await waitUntil { renderer.isIdle }
            XCTAssertEqual(calls.withLock { $0 }, mode == 0 || mode == 3 ? 1 : 2, "Only the latest pending frame should acquire another buffer")
            let drawable = try XCTUnwrap(captured.withLock { $0.last })
            let bytes = try XCTUnwrap(device.makeBuffer(length: 64 * 64 * 4, options: .storageModeShared))
            let command = try XCTUnwrap(commands.makeCommandBuffer()), blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.copy(from: drawable.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: 64, height: 64, depth: 1), to: bytes, destinationOffset: 0,
                      destinationBytesPerRow: 64 * 4, destinationBytesPerImage: 64 * 64 * 4)
            blit.endEncoding()
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            XCTAssertEqual(command.status, .completed)
            let pixels = bytes.contents().assumingMemoryBound(to: UInt8.self)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: pixels, count: 4)), [255, 0, 0, 255], "GPU output must contain the latest blue frame, including after cancellation or a nil drawable")
        }
    }

    @MainActor func testSettledQualityStartsWhileMainActorIsBusy() async throws {
        let started = DispatchSemaphore(value: 0)
        let input = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 12, height: 4))
        let image = try XCTUnwrap(CIContext().createCGImage(input, from: input.extent))
        let renderer: @Sendable (ImageRequest, Bool, Int?) async throws -> RenderedImage = { _, interactive, _ in
            if !interactive { started.signal() }
            return RenderedImage(image: image, fullSize: input.extent.size, orientedSourceSize: input.extent.size,
                                 histogram: nil, elapsed: 0.01)
        }
        let model = AppModel(previewRenderer: renderer)
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.jpg", identity: Data(), identityKey: "a", width: 12, height: 4)
        model.activeID = "a"
        model.requestPreview()
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success, "Quality rendering must start without waiting for MainActor")
        try await waitUntil { model.previewCurrent }
        XCTAssertTrue(model.image === image)
    }

    @MainActor func testInteractivePreviewBypassesBlockedQualityAndRejectsItsLateFrame() async throws {
        let quality = PreviewProbe(), draft = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in
            try await (interactive ? draft : quality).render(request, interactive)
        })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        model.requestPreview()
        try await waitUntil { quality.completion != nil }
        model.requestPreview(interactive: true)
        try await waitUntil { draft.completion != nil }
        XCTAssertNotNil(quality.completion, "Full-quality rendering is deliberately still blocked")
        try draft.finish(width: 10)
        try await waitUntil { model.image?.width == 10 }
        XCTAssertTrue(model.interactivePreview)
        try quality.finish(width: 90)
        model.requestPreview(interactive: true)
        try await waitUntil { draft.completion != nil }
        try draft.finish(width: 12)
        try await waitUntil { model.image?.width == 12 }
        XCTAssertTrue(model.interactivePreview, "Old full-quality result must not overwrite a newer drag")
        model.requestPreview()
        try await waitUntil { quality.completion != nil }
        try quality.finish(width: 20)
        try await waitUntil { model.image?.width == 20 }
        XCTAssertFalse(model.interactivePreview)
    }

    @MainActor func testWarmDraftCannotReplaceAlreadyPublishedQuality() async throws {
        let quality = PreviewProbe(), draft = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in
            try await (interactive ? draft : quality).render(request, interactive)
        })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        model.requestPreview(prepareInteractive: true)
        try await waitUntil { quality.completion != nil && draft.completion != nil }
        try quality.finish(width: 30)
        try await waitUntil { model.image?.width == 30 }
        try draft.finish(width: 10)
        model.requestPreview(interactive: true)
        try await waitUntil { draft.requests.count == 2 && draft.completion != nil }
        XCTAssertEqual(model.image?.width, 30)
        try draft.finish(width: 12)
        try await waitUntil { model.image?.width == 12 }
    }

    @MainActor func testCommitReusesInFlightDraftWithTheSameRenderInputs() async throws {
        let draft = PreviewProbe(), quality = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in
            try await (interactive ? draft : quality).render(request, interactive)
        })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        model.requestPreview(interactive: true)
        try await waitUntil { draft.completion != nil }
        model.activePhoto?.recipe = try JSONEncoder().encode(model.recipe)
        model.activePhoto?.recipeRevision += 1
        model.requestPreview(prepareInteractive: true)
        try draft.finish(width: 10)
        try await waitUntil { model.image?.width == 10 && quality.completion != nil }
        XCTAssertEqual(draft.requests.count, 1, "Saving identical inputs must reuse the in-flight frame")
        XCTAssertTrue(model.interactivePreview)
        try quality.finish(width: 20)
        try await waitUntil { model.image?.width == 20 }
        XCTAssertFalse(model.interactivePreview)
    }

    @MainActor func testEditorObservationKeepsPreviewAndRecipeAvailabilityIndependent() async throws {
        let model = AppModel()
        model.canEdit = true
        model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        XCTAssertTrue(model.hasRecipe)
        let availability = expectation(description: "A parameter or frame must not invalidate editor availability")
        availability.isInverted = true
        let scrollCache = expectation(description: "Native scroll bookkeeping must not schedule another view update")
        scrollCache.isInverted = true
        let recipe = expectation(description: "Parameter readers are notified")
        let frame = expectation(description: "Preview readers are notified")
        withObservationTracking {
            _ = model.hasRecipe; _ = model.canEdit
        } onChange: { availability.fulfill() }
        withObservationTracking { _ = model.recipe } onChange: { recipe.fulfill() }
        withObservationTracking { _ = model.image } onChange: { frame.fulfill() }
        withObservationTracking {
            _ = model.scrollPositions["grid"]; _ = model.scrollActiveIDs["grid"]
        } onChange: { scrollCache.fulfill() }
        model.scrollPositions["grid"] = CGPoint(x: 0, y: 120)
        model.scrollActiveIDs["grid"] = "photo"
        model.changeRecipe({ $0.exposure = 1 }, commit: false, preview: false)
        model.image = CIContext().createCGImage(CIImage(color: .red), from: CGRect(x: 0, y: 0, width: 12, height: 4))
        model.imageStatus = "updated frame"
        await fulfillment(of: [recipe, frame, availability, scrollCache], timeout: 0.1)
        XCTAssertEqual(model.recipe?.exposure, 1)
    }

    @MainActor func testRecipeCommitRefreshesPhotoAndHistoryWithoutReloadingTheLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        let baseline = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
                                  baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        for id in ["a", "b"] {
            try catalog.index(Photo(id: id, rootID: root.id, relativePath: id + ".jpg", identity: Data(), identityKey: id, width: 80, height: 40))
            try catalog.saveRecipe(id: id, recipe: baseline)
        }
        let quality = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in
            if interactive { throw CancellationError() }
            return try await quality.render(request, false)
        })
        model.catalog = catalog; model.roots = [root]
        model.activeID = "a"; model.activePhoto = try catalog.photo("a")
        model.photos = try catalog.photos(ids: ["a", "b"])
        model.recipe = baseline; model.canEdit = true; model.dirty = true
        XCTAssertTrue(model.commitRecipe())
        try await waitUntil { quality.completion != nil }
        try quality.finish(width: 10)
        try await waitUntil { model.previewCurrent }
        XCTAssertEqual(quality.requests.count, 1)
        let other = try XCTUnwrap(model.photos.first { $0.id == "b" })
        let order = model.photos.map(\.id)
        let queries = OSAllocatedUnfairLock(initialState: [String]())
        try await catalog.database.writeWithoutTransaction { db in
            db.trace { if case let .statement(statement) = $0 {
                let sql = statement.sql
                queries.withLock { $0.append(sql) }
            } }
        }
        defer { catalog.database.writeWithoutTransaction { $0.trace(options: []) { _ in } } }
        model.undo.groupsByEvent = false
        model.undo.beginUndoGrouping()
        model.changeRecipe { $0.exposure = 1 }
        XCTAssertFalse(model.dirty)
        model.undo.endUndoGrouping()
        try await waitUntil { quality.completion != nil }
        try quality.finish(width: 12)
        try await waitUntil { model.previewCurrent || quality.requests.count > 2 }
        XCTAssertEqual(quality.requests.count, 2, "A committed value must not render once before saving and again after saving")
        if quality.completion != nil { try quality.finish(width: 12) }
        try await waitUntil { model.previewCurrent }
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(model.activePhoto?.recipe)).exposure, 1)
        XCTAssertEqual(model.editHistory.first?.photoID, "a")
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(model.editHistory.first?.recipe)).exposure, 1)
        model.undo.undo()
        XCTAssertEqual(model.recipe?.exposure, 0)
        try await waitUntil { quality.completion != nil }
        try quality.finish(width: 14)
        try await waitUntil { model.previewCurrent }
        model.undo.redo()
        XCTAssertEqual(model.recipe?.exposure, 1)
        try await waitUntil { quality.completion != nil }
        try quality.finish(width: 16)
        try await waitUntil { model.previewCurrent }
        XCTAssertEqual(model.photos.map(\.id), order)
        XCTAssertEqual(model.photos.first { $0.id == "b" }, other)
        XCTAssertEqual(model.photos.first { $0.id == "a" }?.recipe, model.activePhoto?.recipe)
        let selects = queries.withLock { $0.filter { $0.uppercased().hasPrefix("SELECT") } }
        XCTAssertFalse(selects.contains { $0.lowercased().contains("count(") || $0.contains("editSnapshot") || $0.contains("membership") },
                       "Saving and undoing a recipe must not repeat library counts, membership or snapshot queries")
        print("NATIVE_PERF recipe commit/undo/redo selects=\(selects.count)")
    }

    @MainActor func testIncrementalHistoryKeepsPaginationUndoAndPhotoSwitches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try CatalogStore(directory: directory)
        let root = try catalog.addRoot(url: directory, bookmark: Data())
        let photo = Photo(id: "a", rootID: root.id, relativePath: "a.jpg", identity: Data(), identityKey: "a", width: 80, height: 40)
        try catalog.index(photo)
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
                                baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        for value in 0..<105 { recipe.exposure = Double(value) / 100; try catalog.saveRecipe(id: "a", recipe: recipe) }
        let model = AppModel(previewRenderer: { _, _, _ in throw CancellationError() })
        model.catalog = catalog; model.roots = [root]; model.activeID = "a"; model.activePhoto = try catalog.photo("a")
        model.recipe = recipe; model.canEdit = true; model.dirty = true
        XCTAssertTrue(model.commitRecipe())
        XCTAssertEqual(model.editHistory.count, 100); XCTAssertTrue(model.hasMoreHistory)
        let previous = Dictionary(uniqueKeysWithValues: model.editHistory.map { ($0.id, $0.recipe) })
        model.undo.groupsByEvent = false; model.undo.beginUndoGrouping()
        model.changeRecipe({ $0.exposure = 2 }, title: "new adjustment")
        model.undo.endUndoGrouping()
        let expected = try catalog.editHistory(photoID: "a", limit: 101)
        XCTAssertEqual(model.editHistory.map(\.id), expected.prefix(100).map(\.id))
        XCTAssertTrue(model.hasMoreHistory)
        for entry in model.editHistory.dropFirst() { XCTAssertEqual(entry.recipe, previous[entry.id]) }
        model.loadMoreHistory()
        XCTAssertEqual(model.editHistory.count, 106); XCTAssertFalse(model.hasMoreHistory)
        model.undo.undo()
        XCTAssertEqual(model.editHistory.count, 107); XCTAssertEqual(model.editHistory.first?.title, "撤销调整")
        XCTAssertFalse(model.hasMoreHistory)
        model.undo.redo()
        XCTAssertEqual(model.editHistory.count, 108); XCTAssertEqual(model.editHistory.first?.title, "重做调整")
        model.activeID = "b"; try model.reloadEditContext()
        XCTAssertTrue(model.editHistory.isEmpty); XCTAssertFalse(model.hasMoreHistory)
        model.activeID = "a"; try model.reloadEditContext()
        XCTAssertEqual(model.editHistory.map(\.id), try catalog.editHistory(photoID: "a", limit: 200).map(\.id))
    }

    @MainActor func testCollapsedPanelBuildsContentOnlyWhenExpanded() async throws {
        var builds = 0
        func section(_ expanded: Bool) -> some View {
            PanelSection("Deferred controls", isExpanded: .constant(expanded)) {
                builds += 1
                return Text("Expanded controls")
            }
        }
        let host = NSHostingView(rootView: section(false))
        host.frame = CGRect(x: 0, y: 0, width: 336, height: 180)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(builds, 0, "Collapsed sections must not construct parameter controls")
        host.rootView = section(true)
        try await waitUntil { host.layoutSubtreeIfNeeded(); return builds > 0 }
        let expandedBuilds = builds
        host.rootView = section(false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(builds, expandedBuilds)
    }

    @MainActor func testDevelopParameterRowsRetargetTheirActionsAcrossModelsAndLocalMode() async throws {
        func model() -> AppModel {
            let model = AppModel(); model.canEdit = true
            model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: EditRecipe.rasterDecoderVersion,
                                      baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
            return model
        }
        let first = model(), second = model()
        let suite = "develop-row-retarget-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(true, forKey: "developBasicOpen")
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: DevelopPanel(model: first).defaultAppStorage(preferences))
        host.frame = CGRect(x: 0, y: 0, width: 336, height: 900)
        func exposure(_ view: NSView) -> AdjustmentNSSlider? {
            if let slider = view as? AdjustmentNSSlider, slider.accessibilityLabel() == "曝光度" { return slider }
            return view.subviews.compactMap(exposure).first
        }
        host.layoutSubtreeIfNeeded()
        first.recipe?.tint = 10
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try XCTUnwrap(exposure(host)).accessibilityPerformIncrement())
        XCTAssertEqual(try XCTUnwrap(first.recipe?.exposure), 0.05, accuracy: 1e-12)
        host.rootView = DevelopPanel(model: second).defaultAppStorage(preferences)
        try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try XCTUnwrap(exposure(host)).accessibilityPerformIncrement())
        XCTAssertEqual(try XCTUnwrap(second.recipe?.exposure), 0.05, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(first.recipe?.exposure), 0.05, accuracy: 1e-12, "An equal row must not retain the previous model's action")
        let group = LocalAdjustment(components: [MaskComponent(tool: .brush)])
        second.recipe?.localAdjustments = [group]; second.selectedMaskID = group.id
        host.rootView = DevelopPanel(model: second, local: true).defaultAppStorage(preferences)
        try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(try XCTUnwrap(exposure(host)).accessibilityPerformIncrement())
        XCTAssertEqual(try XCTUnwrap(second.recipe?.localAdjustments[0].exposure), 0.05, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(second.recipe?.exposure), 0.05, accuracy: 1e-12, "Switching to local controls must preserve global exposure")
    }

    @MainActor func testPublishedDraftReuseRequiresUnchangedSource() async throws {
        let draft = PreviewProbe(), quality = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in
            try await (interactive ? draft : quality).render(request, interactive)
        })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        model.requestPreview(interactive: true)
        try await waitUntil { draft.completion != nil }
        try draft.finish(width: 10)
        try await waitUntil { model.image?.width == 10 }
        model.requestPreview(prepareInteractive: true)
        try await waitUntil { quality.completion != nil }
        XCTAssertEqual(draft.requests.count, 1, "The already visible draft remains valid on release")
        try quality.finish(width: 20)
        try await waitUntil { model.image?.width == 20 }
        model.requestPreview(interactive: true)
        try await waitUntil { draft.completion != nil }
        try draft.finish(width: 12)
        try await waitUntil { model.image?.width == 12 }
        model.activePhoto?.identity = Data("different-source".utf8)
        model.requestPreview(prepareInteractive: true)
        try await waitUntil { draft.requests.count == 3 && draft.completion != nil }
        try draft.finish(width: 14)
        try await waitUntil { model.image?.width == 14 && quality.completion != nil }
        try quality.finish(width: 24)
        try await waitUntil { model.image?.width == 24 }
    }

    nonisolated private static func trackingModeRenderer() -> (ImageRequest, Bool, Int?) async throws -> RenderedImage {
        { _, _, _ in
            try await Task.sleep(for: .milliseconds(20))
            let input = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 12, height: 4))
            guard let image = CIContext().createCGImage(input, from: input.extent) else { throw LRCError("Test image unavailable") }
            return RenderedImage(image: image, fullSize: input.extent.size, orientedSourceSize: input.extent.size, histogram: nil, elapsed: 0.02)
        }
    }

    @MainActor func testPreviewPublishesWhileOnlyEventTrackingModeRuns() throws {
        let model = AppModel(previewRenderer: Self.trackingModeRenderer())
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        model.requestPreview(interactive: true)
        let deadline = Date().addingTimeInterval(2)
        // Unlike an async wait, this deliberately does not let the default-mode
        // MainActor task queue drive the render's start or completion.
        while model.image == nil && Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.image?.width, 12)
        XCTAssertTrue(model.interactivePreview)
    }

    @MainActor func testQualityPreviewPublishesWhileOnlyEventTrackingModeRuns() throws {
        let model = AppModel(previewRenderer: Self.trackingModeRenderer())
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.jpg", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        model.requestPreview()
        let deadline = Date().addingTimeInterval(2)
        while !model.previewCurrent && Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.image?.width, 12)
        XCTAssertTrue(model.previewCurrent, "A completed quality frame must not wait for tracking mode to end")
    }

    @MainActor func testSwitchingPhotosRejectsInFlightPreview() async throws {
        let probe = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in try await probe.render(request, interactive) })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.jpg", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"; model.requestPreview()
        try await waitUntil { probe.completion != nil }
        model.choose([], active: nil)
        model.activePhoto = Photo(id: "b", rootID: "r", relativePath: "b.jpg", identity: Data(), identityKey: "b", width: 80, height: 40)
        model.activeID = "b"; model.requestPreview()
        try probe.finish(width: 10)
        try await waitUntil { probe.requests.count == 2 && probe.completion != nil }
        XCTAssertNil(model.image)
        try probe.finish(width: 20)
        try await waitUntil { model.image?.width == 20 }
    }

    func testCropPreviewShowsRotatedEdgesAndKeepsExportTransform() throws {
        let size = CGSize(width: 400, height: 600)
        for degrees in [-45.0, -12, 0, 23, 45] {
            let extent = CropPreviewGeometry.bounds(size: size, degrees: degrees)
            if degrees != 0 {
                XCTAssertGreaterThan(extent.width, size.width)
                XCTAssertGreaterThan(extent.height, size.height)
                XCTAssertLessThan(extent.minX, 0)
            }
            let frame = CropPreviewGeometry.outputFrame(size: size, canvas: CGSize(width: 1000, height: 800), degrees: degrees)
            XCTAssertEqual(frame.midX, 500, accuracy: 0.00001)
            XCTAssertEqual(frame.midY, 400, accuracy: 0.00001)
            XCTAssertEqual(frame.width / frame.height, size.width / size.height, accuracy: 0.00001)
            // Match the existing saved-recipe transform, including its anti-blank-edge zoom.
            let angle = degrees * .pi / 180
            let zoom = max(abs(cos(angle)) + abs(sin(angle)) * 1.5, abs(cos(angle)) + abs(sin(angle)) / 1.5)
            let legacy = CGAffineTransform(translationX: -200, y: -300)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                .concatenating(CGAffineTransform(translationX: 200, y: 300))
            let current = CropPreviewGeometry.transform(size: size, degrees: degrees)
            for point in [CGPoint.zero, CGPoint(x: 400, y: 600), CGPoint(x: 120, y: 210)] {
                XCTAssertEqual(point.applying(current).x, point.applying(legacy).x, accuracy: 0.00001)
                XCTAssertEqual(point.applying(current).y, point.applying(legacy).y, accuracy: 0.00001)
            }
        }
    }

    @MainActor func testCanvasClickZoomAndDragDoNotConflict() throws {
        let canvas = PhotoMetalCanvas()
        canvas.source = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .red), from: CGRect(x: 0, y: 0, width: 40, height: 60)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        var clicks = 0
        canvas.onClick = { _ in clicks += 1 }
        func event(_ type: NSEvent.EventType, _ x: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 60), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, 100)); canvas.mouseUp(with: try event(.leftMouseUp, 100))
        XCTAssertEqual(clicks, 1)
        canvas.actualPixels = true
        canvas.mouseDown(with: try event(.leftMouseDown, 100))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 125)); canvas.mouseUp(with: try event(.leftMouseUp, 125))
        XCTAssertEqual(clicks, 1, "Releasing a pan must not toggle back to Fit")
        canvas.cropAngle = 15
        canvas.mouseDown(with: try event(.leftMouseDown, 100)); canvas.mouseUp(with: try event(.leftMouseUp, 100))
        XCTAssertEqual(clicks, 1, "Crop gestures must not toggle zoom")
        withExtendedLifetime(window) {}
    }

    @MainActor func testZoomRatiosAndFocalPointSurviveGeometryUpdate() throws {
        let canvas = PhotoMetalCanvas()
        let image = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .red), from: CGRect(x: 0, y: 0, width: 40, height: 60)))
        canvas.nativeSize = CGSize(width: 4000, height: 6000); canvas.actualPixels = true; canvas.zoomScale = 2
        XCTAssertEqual(canvas.presentationSize(source: image, canvas: CGSize(width: 1000, height: 800)), CGSize(width: 8000, height: 12000))
        canvas.actualPixels = false; canvas.fill = true
        XCTAssertEqual(canvas.presentationSize(source: image, canvas: CGSize(width: 1000, height: 800)), CGSize(width: 1000, height: 1500))
        let viewport = PhotoViewport()
        viewport.focusOnNextGeometry(CGPoint(x: 0.7, y: 0.3))
        viewport.update(image: CGSize(width: 40, height: 60), canvas: CGSize(width: 1000, height: 800), zoomed: false)
        viewport.update(image: CGSize(width: 8000, height: 12000), canvas: CGSize(width: 1000, height: 800), zoomed: true)
        XCTAssertEqual(viewport.center, CGPoint(x: 0.7, y: 0.3))
        let point = PhotoMetalCanvas.imagePoint(CGPoint(x: 700, y: 300), center: CGPoint(x: 0.5, y: 0.5), displayed: CGSize(width: 1000, height: 1000), canvas: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(point, CGPoint(x: 0.7, y: 0.3))
    }

    @MainActor func testCropPreviewDecodesUnstraightenedSourceAndReusesItForAngleChanges() async throws {
        let probe = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in try await probe.render(request, interactive) })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"
        var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        recipe.straightenDegrees = 30; recipe.quarterTurns = 1
        recipe.crop = Crop(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        model.recipe = recipe; model.cropMode = true
        model.requestPreview()
        try await waitUntil { probe.completion != nil }
        let requested = try XCTUnwrap(probe.requests.last?.0.recipe)
        XCTAssertEqual(requested.straightenDegrees, 0)
        XCTAssertEqual(requested.crop, Crop())
        XCTAssertEqual(requested.quarterTurns, 1)
        try probe.finish(width: 10)
        try await waitUntil { model.previewIsCrop && model.image != nil }
        let image = model.image
        model.changeRecipe({ $0.straightenDegrees = -45 }, commit: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.requests.count, 1, "Rotation is a display transform during crop editing")
        XCTAssertTrue(model.image === image)
        XCTAssertEqual(model.recipe?.crop, recipe.crop)
    }

    @MainActor func testNavigatorClampsPortraitViewportAndResizesWithoutBlankEdges() {
        let viewport = PhotoViewport()
        viewport.update(image: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 1000, height: 1200), zoomed: true)
        viewport.move(to: CGPoint(x: 0, y: 1))
        XCTAssertEqual(viewport.visibleRect.minX, 0, accuracy: 0.00001)
        XCTAssertEqual(viewport.visibleRect.maxY, 1, accuracy: 0.00001)
        XCTAssertEqual(viewport.visibleRect.width, 0.25, accuracy: 0.00001)
        XCTAssertEqual(viewport.visibleRect.height, 0.2, accuracy: 0.00001)
        // A wider window fits the full short axis; vertical navigation remains available.
        viewport.update(image: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 5000, height: 3000), zoomed: true)
        XCTAssertEqual(viewport.center.x, 0.5)
        XCTAssertEqual(viewport.visibleRect.maxY, 1, accuracy: 0.00001)
        viewport.update(image: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 5000, height: 3000), zoomed: false)
        XCTAssertEqual(viewport.visibleRect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @MainActor func testCanvasPanPublishesNavigatorPositionInNativePixels() throws {
        let viewport = PhotoViewport()
        viewport.update(image: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 1000, height: 1200), zoomed: true)
        let canvas = PhotoMetalCanvas()
        canvas.viewport = viewport; canvas.actualPixels = true
        canvas.nativeSize = CGSize(width: 4000, height: 6000)
        canvas.source = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .red), from: CGRect(x: 0, y: 0, width: 40, height: 60)))
        canvas.panBy(CGSize(width: 200, height: 300), backingScale: 2)
        XCTAssertEqual(viewport.center.x, 0.4, accuracy: 0.00001)
        XCTAssertEqual(viewport.center.y, 0.4, accuracy: 0.00001)
        XCTAssertEqual(canvas.displayCenter, viewport.center)
        canvas.panBy(CGSize(width: 10000, height: -10000), backingScale: 2)
        XCTAssertEqual(viewport.visibleRect.minX, 0, accuracy: 0.00001)
        XCTAssertEqual(viewport.visibleRect.maxY, 1, accuracy: 0.00001)
        canvas.actualPixels = false
        let previous = viewport.center
        canvas.panBy(CGSize(width: 200, height: 300), backingScale: 2)
        XCTAssertEqual(viewport.center, previous)
    }

    @MainActor func testNavigationResetsOnPhotoOrZoomChangeOnly() {
        let model = AppModel()
        model.activeID = "first"; model.fullResolution = true
        model.viewport.update(image: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 1000, height: 1000), zoomed: true)
        model.viewport.move(to: CGPoint(x: 0.7, y: 0.3))
        model.activeID = "first"; model.fullResolution = true
        XCTAssertEqual(model.viewport.center, CGPoint(x: 0.7, y: 0.3))
        model.activeID = "second"
        XCTAssertEqual(model.viewport.center, CGPoint(x: 0.5, y: 0.5))
        model.viewport.move(to: CGPoint(x: 0.7, y: 0.3))
        model.fullResolution = false
        XCTAssertEqual(model.viewport.center, CGPoint(x: 0.5, y: 0.5))
    }

    func testResizablePanelsReserveCanvasAtMinimumWindowWidth() {
        let widths = WorkspaceDimensions.widths(available: 1000, left: 300, right: 400, showLeft: true, showRight: true)
        XCTAssertGreaterThanOrEqual(widths.left, 200)
        XCTAssertGreaterThanOrEqual(widths.right, 304)
        XCTAssertGreaterThanOrEqual(1000 - widths.left - widths.right - 2, 480)
        let hidden = WorkspaceDimensions.widths(available: 1000, left: 300, right: 360, showLeft: false, showRight: true)
        XCTAssertEqual(hidden.left, 0)
        XCTAssertEqual(hidden.right, 360)
        let narrow = WorkspaceDimensions.widths(available: 960, left: 232, right: 336, showLeft: true, showRight: true)
        XCTAssertEqual(narrow.left, 0, "The optional left panel yields before the photo drops below its minimum")
        XCTAssertGreaterThanOrEqual(960 - narrow.right - 1, 480)
    }

    @MainActor func testWorkspaceKeysRespectEditorsAndSliderFocus() throws {
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Phosdeck"
        func key(_ text: String, code: UInt16 = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        XCTAssertNil(WorkspaceKeyboard.handle(try key("d"), model: model))
        XCTAssertTrue(model.editMode)
        XCTAssertNil(WorkspaceKeyboard.handle(try key("e"), model: model))
        XCTAssertFalse(model.editMode); XCTAssertTrue(model.singleView)
        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView = editor; window.makeFirstResponder(editor)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("g"), model: model))
        XCTAssertTrue(model.singleView)
        let slider = NSSlider(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        window.contentView = slider; window.makeFirstResponder(slider)
        XCTAssertNotNil(WorkspaceKeyboard.handle(try key("\u{F703}", code: 124), model: model))
        withExtendedLifetime(window) {}
    }

    @MainActor func testNativeAdjustmentSliderKeepsSteppingAndAccessibility() throws {
        let slider = AdjustmentNSSlider()
        slider.minValue = -5; slider.maxValue = 5; slider.step = 0.05
        slider.setAccessibilityLabel("曝光度")
        var changes: [Double] = []; var commits = 0
        slider.change = { changes.append($0) }; slider.commit = { commits += 1 }
        slider.doubleValue = 0.123; slider.changed()
        XCTAssertEqual(try XCTUnwrap(changes.last), 0.1, accuracy: 0.00001)
        XCTAssertEqual(commits, 1, "Keyboard/accessibility changes commit without a mouse-up")
        XCTAssertEqual(slider.accessibilityLabel(), "曝光度")
        slider.doubleValue = 50; slider.changed()
        XCTAssertEqual(changes.last, 5)
    }

    @MainActor func testDisabledAdjustmentPropagatesToNativeSliderAndAccessibility() async throws {
        var changes = 0
        func control(enabled: Bool) -> some View {
            GradientAdjustmentSlider(value: 0, range: -100...100, step: 1, neutral: 0, track: .tonal,
                                     label: "禁用态回归", change: { _ in changes += 1 }, commit: {})
                .disabled(!enabled).frame(width: 180, height: 28)
        }
        let host = NSHostingView(rootView: control(enabled: false))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 180, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func find(_ view: NSView) -> AdjustmentNSSlider? {
            (view as? AdjustmentNSSlider) ?? view.subviews.compactMap(find).first
        }
        host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(find(host))
        XCTAssertFalse(slider.isEnabled)
        XCTAssertFalse(slider.accessibilityPerformIncrement())
        XCTAssertEqual(changes, 0, "旁路或不适用的参数不能通过读屏操作改变")
        host.rootView = control(enabled: true)
        try await waitUntil { slider.isEnabled }
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertEqual(changes, 1)
        host.rootView = control(enabled: false)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(slider.isEnabled)
        XCTAssertFalse(slider.accessibilityPerformDecrement())
        XCTAssertEqual(changes, 1)
    }

    @MainActor func testPointColorControlsFitMinimumInspectorAndRespectBlackWhiteBypass() async throws {
        let model = AppModel()
        model.canEdit = true
        model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0,
                                  baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        model.recipe?.develop.pointColors = (0..<8).map { PointColor(hue: Double($0) * 45) }
        func sliders(_ view: NSView) -> [AdjustmentNSSlider] {
            (view as? AdjustmentNSSlider).map { [$0] } ?? view.subviews.flatMap(sliders)
        }
        for width in [304.0, 400.0] {
            for theme in [ChromeTheme.ivory, .graphite] {
                model.recipe?.develop.blackAndWhite = false
                let host = NSHostingView(rootView: ScrollView { PointColorPanel(model: model).sectionContent() }
                    .instrumentForm().preferredColorScheme(theme.colorScheme))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try await waitUntil { sliders(host).count == 8 }
                for slider in sliders(host) {
                    XCTAssertGreaterThan(slider.bounds.width, 50)
                    let rect = slider.convert(slider.bounds, to: host)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, width)
                    XCTAssertTrue(slider.isEnabled)
                }
                try attachUISnapshot(host, name: "point-color-\(Int(width))-\(theme.rawValue)")
                model.recipe?.develop.blackAndWhite = true
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertTrue(sliders(host).allSatisfy { !$0.isEnabled }, "黑白模式保留取样，禁用颜色推子")
            }
        }
    }

    @MainActor func testFilmstripCellsFitWhenSystemScrollbarsAreAlwaysVisible() async throws {
        let model = AppModel()
        model.photos = (0..<20).map { Photo(id: "film-\($0)", rootID: "test", relativePath: "\($0).jpg", identity: Data(), identityKey: "film-\($0)", width: 100, height: 80) }
        func find(_ view: NSView) -> NSScrollView? { (view as? NSScrollView) ?? view.subviews.compactMap(find).first }
        for height in [Metrics.filmstrip.range.lowerBound, Metrics.filmstrip.initial, Metrics.filmstrip.range.upperBound] {
            let host = NSHostingView(rootView: PhotoGrid(model: model, film: true, filmHeight: height).frame(height: height))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(find(host))
            scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false; scroll.tile()
            let collection = try XCTUnwrap(scroll.documentView as? NSCollectionView)
            let delegate = try XCTUnwrap(collection.delegate as? NSCollectionViewDelegateFlowLayout)
            let layout = try XCTUnwrap(collection.collectionViewLayout as? NSCollectionViewFlowLayout)
            layout.invalidateLayout(); collection.layoutSubtreeIfNeeded()
            let size = try XCTUnwrap(delegate.collectionView?(collection, layout: layout, sizeForItemAt: IndexPath(item: 0, section: 0)))
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertLessThan(size.height + layout.sectionInset.top + layout.sectionInset.bottom, scroll.contentSize.height,
                              "胶片带 \(height) pt 必须容纳系统滚动条和上下边距")
            let item = try XCTUnwrap(collection.item(at: IndexPath(item: 0, section: 0)))
            item.view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(item.view.subviews.compactMap { $0 as? NSImageView }.first)
            XCTAssertGreaterThan(image.bounds.height, 0, "最矮胶片带仍需留出照片空间")
        }
    }

    @MainActor func testSliderDoubleClickRestoresWhiteBalanceBaseline() throws {
        let slider = AdjustmentNSSlider(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        slider.minValue = 2000; slider.maxValue = 50000; slider.step = 50
        slider.resetValue = 5372; slider.doubleValue = 9000
        var restored: Double?; var commits = 0
        slider.change = { restored = $0 }; slider.commit = { commits += 1 }
        let window = NSWindow(contentRect: slider.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = slider
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 120, y: 11),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 2, pressure: 1))
        slider.mouseDown(with: event)
        XCTAssertEqual(restored, 5372, "Restore the actual baseline, not zero or a rounded drag step")
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(slider.trackingMouse)
        withExtendedLifetime(window) {}
    }

    @MainActor func testSliderMouseDownReturnsAndPreviewPublishesBeforeMouseUp() async throws {
        let probe = PreviewProbe()
        let model = AppModel(previewRenderer: { request, interactive, _ in try await probe.render(request, interactive) })
        model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
        model.activePhoto = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
        model.activeID = "a"; model.canEdit = true
        model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
        let slider = AdjustmentNSSlider(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        slider.minValue = -5; slider.maxValue = 5; slider.step = 0.05
        var commits = 0
        slider.change = { value in model.changeRecipe({ $0.exposure = value }, commit: false) }
        slider.commit = { commits += 1; model.requestPreview() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let canvas = NSHostingView(rootView: PhotoCanvas(model: model))
        canvas.frame = NSRect(x: 0, y: 24, width: 240, height: 136)
        content.addSubview(canvas); content.addSubview(slider)
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = content
        canvas.layoutSubtreeIfNeeded(); slider.cell?.calcDrawInfo(slider.bounds)
        func findMetal(_ view: NSView) -> PhotoMetalCanvas? {
            if let metal = view as? PhotoMetalCanvas { return metal }
            return view.subviews.compactMap { findMetal($0) }.first
        }
        let metal = try XCTUnwrap(findMetal(canvas))
        // Direct handler calls on an isolated control: no global event posting,
        // no native event-tracking loop, and no changes to the user's catalog.
        func event(_ type: NSEvent.EventType, x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 12), modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        slider.mouseDown(with: try event(.leftMouseDown, x: 175))
        XCTAssertTrue(slider.trackingMouse)
        XCTAssertEqual(commits, 0)
        try await waitUntil { probe.completion != nil }
        try probe.finish(width: 10)
        try await waitUntil { model.image?.width == 10 && metal.source?.width == 10 }
        XCTAssertTrue(slider.trackingMouse, "A preview must reach the model while the mouse is still pressed")
        slider.mouseDragged(with: try event(.leftMouseDragged, x: 205))
        try await waitUntil { probe.completion != nil }
        try probe.finish(width: 12)
        try await waitUntil { model.image?.width == 12 && metal.source?.width == 12 }
        XCTAssertEqual(commits, 0)
        slider.mouseUp(with: try event(.leftMouseUp, x: 205))
        XCTAssertFalse(slider.trackingMouse)
        XCTAssertEqual(commits, 1, "One undo/save boundary per gesture")
        try await waitUntil { probe.completion != nil }
        XCTAssertFalse(try XCTUnwrap(probe.requests.last).1)
        try probe.finish(width: 14)
        try await waitUntil { model.image?.width == 14 }
        withExtendedLifetime(window) {}
    }

    @MainActor func testMaskWorkspaceKeepsCanvasBoundsDuringSliderPreviewAndResize() async throws {
        let suite = "mask-workspace-preview-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "developBasicOpen")
        preferences.set(false, forKey: "maskRefinementOpen")
        preferences.set(true, forKey: "maskListExpanded")
        preferences.set(true, forKey: "showLeftPanel")
        preferences.set(true, forKey: "showRightPanel")
        preferences.set(true, forKey: "showFilmstrip")
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            let probe = PreviewProbe()
            let model = AppModel(previewRenderer: { request, interactive, _ in try await probe.render(request, interactive) })
            model.roots = [StorageRoot(id: "r", path: "", bookmark: Data(), label: "test")]
            let photo = Photo(id: "a", rootID: "r", relativePath: "a.ARW", identity: Data(), identityKey: "a", width: 80, height: 40)
            model.activePhoto = photo; model.activeID = photo.id; model.photos = [photo]; model.selection = [photo.id]
            model.editMode = true; model.singleView = true; model.canEdit = true
            var recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
            recipe.schemaVersion = 3
            recipe.localAdjustments = (0..<2).map { _ in LocalAdjustment(components: [MaskComponent(tool: .radial)]) }
            model.recipe = recipe; model.selectedMaskID = recipe.localAdjustments[1].id
            model.selectedComponentID = recipe.localAdjustments[1].components[0].id
            model.showMaskOverlay = false; model.showMaskGuides = false
            let size = CGSize(width: 80, height: 40)
            model.image = CIContext().createCGImage(CIImage(color: .gray), from: CGRect(origin: .zero, size: size))
            model.orientedSourceSize = size; model.renderedNativeSize = size; model.maskMode = true
            let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1770, height: 850), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            var updateTimes: [Double] = []
            for value in 1...15 {
                let started = CFAbsoluteTimeGetCurrent()
                model.changeRecipe({ $0.localAdjustments[1].exposure = Double(value) / 100 }, commit: false, preview: false)
                host.layoutSubtreeIfNeeded()
                updateTimes.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                try await Task.sleep(for: .milliseconds(1))
            }
            print("NATIVE_PERF workspace-update theme=\(theme.rawValue) ms=\(Array(updateTimes.dropFirst()))")
            model.recipe = recipe
            host.layoutSubtreeIfNeeded()
            let slider = try XCTUnwrap(descendants(host, AdjustmentNSSlider.self).first { $0.accessibilityLabel() == "曝光度" })
            let canvas = try XCTUnwrap(descendants(host, PhotoMetalCanvas.self).first)
            let initialBounds = canvas.convert(canvas.bounds, to: host)
            func event(_ type: NSEvent.EventType, fraction: CGFloat) throws -> NSEvent {
                let point = slider.convert(CGPoint(x: slider.bounds.width * fraction, y: slider.bounds.midY), to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            // Exercise the actual inspector control inside the complete workspace.
            slider.mouseDown(with: try event(.leftMouseDown, fraction: 0.5))
            for frame in 0..<12 {
                slider.mouseDragged(with: try event(.leftMouseDragged, fraction: 0.52 + Double(frame) * 0.015))
                try await waitUntil { probe.completion != nil }
                try probe.finish(width: 10 + frame)
                try await waitUntil { host.layoutSubtreeIfNeeded(); return canvas.source?.width == 10 + frame }
                XCTAssertTrue(slider.trackingMouse, "Frames must reach the canvas before this single gesture ends")
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertTrue(slider.trackingMouse)
            XCTAssertTrue(model.dirty)
            XCTAssertGreaterThan(try XCTUnwrap(model.recipe).localAdjustments[1].exposure, 0)
            XCTAssertEqual(model.recipe?.localAdjustments[0], recipe.localAdjustments[0])
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(canvas.convert(canvas.bounds, to: host), initialBounds, "Draft publication must not move the canvas")
            slider.mouseUp(with: try event(.leftMouseUp, fraction: 0.7))
            XCTAssertFalse(slider.trackingMouse)
            model.requestPreview() // The isolated fixture has no catalog to commit into.
            try await waitUntil { probe.completion != nil }
            try probe.finish(width: 14)
            try await waitUntil { host.layoutSubtreeIfNeeded(); return canvas.source?.width == 14 }
            window.setContentSize(CGSize(width: 1000, height: 640))
            host.layoutSubtreeIfNeeded()
            let frame = canvas.convert(canvas.bounds, to: host)
            XCTAssertGreaterThan(frame.width, 200)
            XCTAssertGreaterThan(frame.height, 200)
            XCTAssertTrue(host.bounds.contains(frame), "The bounded center must still resize with the window")
            XCTAssertLessThanOrEqual(host.fittingSize.width, host.bounds.width + 1)
            XCTAssertLessThanOrEqual(host.fittingSize.height, host.bounds.height + 1)
        }
    }

    @MainActor func testGridPreservesSurvivingItemsForFlagsAndFilteredRemoval() async throws {
        let root = StorageRoot(id: "r", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "test")
        let model = AppModel(); model.roots = [root]
        model.photos = try (1...4).map { try ReferenceImporter.inspect(url: fixture(orientation: $0), root: root, rootURL: directory) }
        model.selection = [model.photos[1].id]; model.activeID = model.photos[1].id
        let selectedID = model.activeID
        let host = NSHostingView(rootView: PhotoGrid(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findCollection(_ view: NSView) -> NSCollectionView? {
            if let collection = view as? NSCollectionView { return collection }
            return view.subviews.compactMap { findCollection($0) }.first
        }
        let collection = try XCTUnwrap(findCollection(host))
        try await waitUntil { (collection.item(at: IndexPath(item: 1, section: 0)) as? PhotoItem)?.displayedImage != nil }
        let survivor = try XCTUnwrap(collection.item(at: IndexPath(item: 1, section: 0)) as? PhotoItem)
        let original = survivor.displayedImage
        model.photos[1].flag = -1; model.photos[1].rating = 5
        try await waitUntil { survivor.view.accessibilityLabel()?.contains("5 星") == true }
        XCTAssertTrue(survivor.displayedImage === original)
        model.photos.removeFirst()
        try await waitUntil { collection.numberOfItems(inSection: 0) == 3 }
        let shifted = collection.item(at: IndexPath(item: 0, section: 0)) as? PhotoItem
        XCTAssertTrue(shifted === survivor, "Filtering must retain the surviving item view")
        XCTAssertTrue(shifted?.displayedImage === original)
        XCTAssertEqual(model.activeID, selectedID)
        XCTAssertEqual(collection.selectionIndexPaths, [IndexPath(item: 0, section: 0)])
        withExtendedLifetime(window) {}
    }


}

extension ImagingTests {
    func testZoomMotionInterpolatesAndRetargetsWithoutJump() {
        let start = CGRect(x: 100, y: 50, width: 400, height: 600)
        let end = CGRect(x: -1000, y: -1400, width: 3000, height: 4500)
        let motion = CanvasZoomMotion(from: start, to: end, start: 10)
        XCTAssertEqual(motion.rect(at: 9), start)
        XCTAssertEqual(motion.rect(at: 10.5), end)
        let midway = motion.rect(at: 10.12)
        XCTAssertGreaterThan(midway.width, start.width); XCTAssertLessThan(midway.width, end.width)
        let reverse = CanvasZoomMotion(from: midway, to: start, start: 10.12)
        XCTAssertEqual(reverse.rect(at: 10.12), midway)
        XCTAssertEqual(reverse.rect(at: 11), start)
    }
}

extension ImagingTests {
    @MainActor func testFaderHorizontalDragFineStepResetAndDisabledState() throws {
        let slider = AdjustmentNSSlider(frame: NSRect(x: 0, y: 0, width: 211, height: 28))
        slider.minValue = -5; slider.maxValue = 5; slider.step = 0.05
        slider.doubleValue = 0; slider.resetValue = 0.35
        var commits = 0
        slider.commit = { commits += 1 }
        let window = NSWindow(contentRect: slider.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = slider
        defer { window.contentView = nil }
        func event(_ type: NSEvent.EventType, x: CGFloat, shift: Bool = false, count: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 14), modifierFlags: shift ? [.shift] : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        slider.mouseDown(with: try event(.leftMouseDown, x: 105.5))
        XCTAssertEqual(slider.doubleValue, 0, "抓住窄推子帽不跳值")
        slider.mouseDragged(with: try event(.leftMouseDragged, x: 145.5))
        XCTAssertEqual(slider.doubleValue, 2, accuracy: 0.00001, "向右拖动增大")
        slider.synchronizeValue(0)
        XCTAssertEqual(slider.doubleValue, 2, accuracy: 0.00001, "A delayed SwiftUI update must not pull the tracking cap back")
        slider.mouseDragged(with: try event(.leftMouseDragged, x: 145.5, shift: true))
        XCTAssertEqual(slider.doubleValue, 2, accuracy: 0.00001, "切换精调重新锚定")
        slider.mouseDragged(with: try event(.leftMouseDragged, x: 155.5, shift: true))
        XCTAssertEqual(slider.doubleValue, 2.05, accuracy: 0.00001)
        XCTAssertEqual(commits, 0)
        slider.mouseUp(with: try event(.leftMouseUp, x: 155.5, shift: true))
        XCTAssertEqual(commits, 1, "整次推子手势只提交一次")
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertEqual(slider.doubleValue, 2.1, accuracy: 0.00001)
        slider.mouseDown(with: try event(.leftMouseDown, x: 105.5, count: 2))
        XCTAssertEqual(slider.doubleValue, 0.35, accuracy: 0.00001)
        slider.synchronizeValue(0.7)
        XCTAssertEqual(slider.doubleValue, 0.7, accuracy: 0.00001, "External values apply again after tracking ends")
        slider.isEnabled = false
        XCTAssertFalse(slider.accessibilityPerformDecrement())
        slider.mouseDown(with: try event(.leftMouseDown, x: 105.5))
        XCTAssertFalse(slider.trackingMouse)
        XCTAssertEqual(slider.doubleValue, 0.7, accuracy: 0.00001)
    }

    @MainActor private final class InstrumentFormFixture: ObservableObject {
        @Published var slide = false
        @Published var lever = true
        @Published var latch = false
        @Published var quota = 5
        @Published var digits = 4
        @Published var digitsValid = true
        @Published var naming = ExportNaming(captureDate: false, sequence: true)
    }

    @MainActor private struct InstrumentFormFixtureView: View {
        @ObservedObject var fixture: InstrumentFormFixture
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("显示选区", isOn: $fixture.slide).toggleStyle(.instrument)
                Toggle("限制长边", isOn: $fixture.lever).toggleStyle(.instrumentLever)
                Toggle("原文件名", isOn: $fixture.latch)
                DetentSlider(title: "磁盘缩略图额度", options: [1, 5, 10].map { KeyOption($0, "\($0) GiB") }, selection: $fixture.quota, reset: 5)
                InstrumentIntegerStepper(title: "补零位数", value: $fixture.digits, range: 1...9,
                                         validationChanged: { fixture.digitsValid = $0 })
            }.padding(24).instrumentForm().frame(width: 520, height: 350)
        }
    }

    @MainActor func testFixedQuotaFaderKeepsBoundsAndNativeAccessibility() async throws {
        let fixture = InstrumentFormFixture()
        let host = NSHostingView(rootView: InstrumentFormFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 350), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> AdjustmentNSSlider? { (view as? AdjustmentNSSlider) ?? view.subviews.compactMap(find).first }
        let slider = try XCTUnwrap(find(host))
        XCTAssertEqual(slider.tickCount, 3); XCTAssertEqual(slider.step, 1)
        XCTAssertEqual(slider.accessibilityValueDescription(), "5 GiB")
        XCTAssertTrue(slider.accessibilityPerformIncrement()); XCTAssertEqual(fixture.quota, 10)
        try await waitUntil { slider.accessibilityValueDescription() == "10 GiB" }
        XCTAssertTrue(slider.accessibilityPerformIncrement()); XCTAssertEqual(fixture.quota, 10)
        XCTAssertTrue(slider.accessibilityPerformDecrement()); XCTAssertEqual(fixture.quota, 5)
        slider.doubleValue = 0.7; slider.changed()
        XCTAssertEqual(fixture.quota, 5, "Dragging snaps to a fixed option, never an intermediate byte quota")
        let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
        slider.keyDown(with: left); XCTAssertEqual(fixture.quota, 1)
        try await Task.sleep(for: .milliseconds(80))
        slider.isEnabled = false
        XCTAssertFalse(slider.accessibilityPerformIncrement())
        XCTAssertFalse(slider.accessibilityPerformDecrement())
        XCTAssertEqual(fixture.quota, 1)
    }

    @MainActor func testIntegerWindowRejectsInvalidDraftAndReportsValidityToTheForm() async throws {
        let fixture = InstrumentFormFixture()
        let host = NSHostingView(rootView: InstrumentFormFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        let field = try XCTUnwrap(fields(host).first { $0.isEditable })
        window.makeFirstResponder(field); field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        func type(_ text: String) { editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count)) }
        type("0")
        try await waitUntil { !fixture.digitsValid }
        XCTAssertEqual(fixture.digits, 4, "Invalid drafts must not enter the export options")
        type("9")
        try await waitUntil { fixture.digitsValid && fixture.digits == 9 }
        type("10")
        try await waitUntil { !fixture.digitsValid }
        XCTAssertEqual(fixture.digits, 9)
        type("3")
        try await waitUntil { fixture.digitsValid && fixture.digits == 3 }
        window.makeFirstResponder(nil)
    }

    @MainActor func testNamingWorkbenchFitsActualPhotoValuesAndLongNames() async throws {
        let fixture = InstrumentFormFixture()
        let photo = Photo(id: "form", rootID: "synthetic", relativePath: String(repeating: "合成照片", count: 15) + ".ARW", identity: Data(), identityKey: "form", captureDate: "2026:10:19 12:34:56", width: 20, height: 10)
        for theme in [ChromeTheme.ivory, .graphite] {
            fixture.naming = ExportNaming(captureDate: true, sequence: true)
            let host = NSHostingView(rootView: NamingComponentFixture(fixture: fixture, photo: photo).preferredColorScheme(theme.colorScheme))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertLessThanOrEqual(host.fittingSize.width, 640)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 420)
            try attachUISnapshot(host, name: "naming-components-\(theme.rawValue)")
            window.orderOut(nil); window.contentView = nil
        }
    }

    @MainActor private struct NamingComponentFixture: View {
        @ObservedObject var fixture: InstrumentFormFixture
        let photo: Photo
        var body: some View {
            let preview = try? ExportNamingPlanner.preview(photos: [photo], options: ExportOptions(format: .png, naming: fixture.naming)).first?.filename
            ExportNamingForm(naming: $fixture.naming, photo: photo, preview: preview).padding(24).instrumentForm().frame(width: 640, height: 420)
        }
    }

    func testDetentLeadersStayAlignedAndSeparateAcrossLayouts() {
        let layouts: [DetentLabelLayout] = [.right, .top, .bottom, .left, [.top, .right, .bottom], [.top, .right, .bottom, .left], []]
        func crosses(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
            func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
                (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            }
            return side(a, b, c) * side(a, b, d) < -0.001 && side(c, d, a) * side(c, d, b) < -0.001
        }
        for layout in layouts {
            for count in [0, 1, 3, 4, 5, 8, 12] {
                let sizes = (0..<count).map { CGSize(width: [24, 60, 110][$0 % 3], height: 18) }
                let geometry = DetentSelectorGeometry(labelSizes: sizes, layout: layout)
                let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: -0.01, dy: -0.01)
                let knob = CGRect(x: geometry.center.x - 22, y: geometry.center.y - 22, width: 44, height: 44)
                XCTAssertEqual(geometry.entries.count, count)
                for (i, entry) in geometry.entries.enumerated() {
                    XCTAssertTrue(bounds.contains(entry.label), "Labels must fit without clipping: \(layout), \(count)")
                    XCTAssertFalse(knob.intersects(entry.label))
                    let dx = entry.start.x - geometry.center.x, dy = entry.start.y - geometry.center.y
                    XCTAssertEqual(atan2(dy, dx), entry.angle, accuracy: 0.0001, "Pointer and leader share one radial direction")
                    let vertical = entry.side == .right || entry.side == .left
                    XCTAssertEqual(vertical ? entry.bend.y : entry.bend.x, vertical ? entry.end.y : entry.end.x, accuracy: 0.0001)
                    for other in geometry.entries.prefix(i) {
                        XCTAssertFalse(entry.label.intersects(other.label), "Mixed sectors must reserve the full label widths")
                        for (a, b) in [(entry.start, entry.bend), (entry.bend, entry.end)] {
                            for (c, d) in [(other.start, other.bend), (other.bend, other.end)] {
                                XCTAssertFalse(crosses(a, b, c, d), "Leader lines must not cross")
                            }
                        }
                        if entry.side == other.side {
                            let edge = entry.side == .right ? entry.label.minX : entry.side == .left ? entry.label.maxX :
                                       entry.side == .top ? entry.label.maxY : entry.label.minY
                            let otherEdge = other.side == .right ? other.label.minX : other.side == .left ? other.label.maxX :
                                            other.side == .top ? other.label.maxY : other.label.minY
                            XCTAssertEqual(edge, otherEdge, accuracy: 0.0001)
                        }
                    }
                }
            }
        }
    }

    @MainActor func testDetentLayoutsInBothThemes() async throws {
        for theme in [ChromeTheme.ivory, .graphite] {
            let content = VStack(alignment: .leading, spacing: 30) {
                Text("档位旋钮 · 折线布局").font(.system(size: 21, weight: .medium))
                HStack(alignment: .top, spacing: 48) {
                    VStack(alignment: .leading, spacing: 18) {
                        SilkText("向右 · 观片底")
                        DetentSelector(title: "观片底", options: PhotoMat.allCases.map { KeyOption($0, $0.title) }, selection: .constant(.medium))
                    }.frame(width: 190, alignment: .leading)
                    VStack(spacing: 18) {
                        SilkText("向上")
                        DetentSelector(title: "向上", options: (1...3).map { KeyOption($0, "档位 \($0)") }, selection: .constant(2), labelLayout: .top)
                    }.frame(width: 190)
                    VStack(spacing: 18) {
                        SilkText("向下")
                        DetentSelector(title: "向下", options: (1...3).map { KeyOption($0, "档位 \($0)") }, selection: .constant(2), labelLayout: .bottom)
                    }.frame(width: 190)
                }
                Seam()
                HStack(alignment: .top, spacing: 60) {
                    VStack(spacing: 18) {
                        SilkText("上 / 右 / 下 · 九档")
                        DetentSelector(title: "三向组合", options: (1...9).map { KeyOption($0, "档位 \($0)") },
                                       selection: .constant(5), labelLayout: [.top, .right, .bottom])
                    }.frame(width: 280)
                    VStack(spacing: 18) {
                        SilkText("四向组合 · 十二档")
                        DetentSelector(title: "四向组合", options: (1...12).map { KeyOption($0, "档位 \($0)") },
                                       selection: .constant(11), labelLayout: [.top, .right, .bottom, .left])
                    }.frame(width: 330)
                }
                Spacer(minLength: 0)
            }.padding(32).frame(width: 760, height: 650).foregroundStyle(Theme.text).background(InstrumentPlate())
                .preferredColorScheme(theme.colorScheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertLessThanOrEqual(host.fittingSize.width, 761)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 651)
            try attachUISnapshot(host, name: "detent-layouts-\(theme.rawValue)")
            window.contentView = nil
        }
    }

    @MainActor func testPhysicalControlMaterialsInBothThemes() async throws {
        for theme in [ChromeTheme.ivory, .graphite] {
            let content = VStack(alignment: .leading, spacing: 28) {
                HStack { Text("暗房仪表 · 材质实装").font(.system(size: 21, weight: .medium)); Spacer(); SilkText("MATERIAL / 03") }
                SubgroupLabel("琴键 · 抬起 / 锁定 / 按住 / 禁用")
                HStack(spacing: 16) {
                    Button("默认"){ }.buttonStyle(.key)
                    Button("已选择"){ }.buttonStyle(.key(selected: true))
                    Text("按住").font(.body13).frame(width: 76, height: 28).background(KeySurface(pressed: true))
                    Button("禁用"){ }.buttonStyle(.key).disabled(true)
                    Spacer()
                    Button("导出"){ }.buttonStyle(PrimaryKeyStyle())
                }
                KeyRow(title: "工具", options: [KeyOption(0, "调整"), KeyOption(1, "裁剪"), KeyOption(2, "污点"), KeyOption(3, "蒙版")], selection: .constant(0), expand: true)
                HStack(alignment: .center, spacing: 50) {
                    VStack(spacing: 8) {
                        AdjustmentRow(label: "曝光度", value: 0.75, range: -5...5, step: 0.05, digits: 2, unit: "EV", change: { _,_ in }, commit: {})
                        AdjustmentRow(label: "对比度", value: 0, change: { _,_ in }, commit: {})
                    }
                    DetentSelector(title: "观片底", options: PhotoMat.allCases.map { KeyOption($0, $0.title) }, selection: .constant(.medium))
                }
                VStack(spacing: 8) {
                    AdjustmentRow(label: "高光", value: -32, change: { _,_ in }, commit: {})
                    AdjustmentRow(label: "色温", value: 5500, range: 2000...25000, step: 50, reset: 5500, track: .basic("色温"), unit: "K", change: { _,_ in }, commit: {})
                    AdjustmentRow(label: "禁用", value: 0, change: { _,_ in }, commit: {}).disabled(true)
                }
                HStack(spacing: 32) {
                    Toggle("显示剪切", isOn: .constant(true)).toggleStyle(.instrument)
                    Toggle("显示叠加", isOn: .constant(false)).toggleStyle(.instrument)
                    LampSwitch(title: "面板启用", isOn: .constant(true))
                    Text("面板启用").font(.body13)
                }
                HStack(spacing: 32) {
                    Toggle("长边限制", isOn: .constant(true)).toggleStyle(.instrumentLever)
                    Toggle("长边限制", isOn: .constant(false)).toggleStyle(.instrumentLever)
                    Toggle("禁用", isOn: .constant(true)).toggleStyle(.instrumentLever).disabled(true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SubgroupLabel("禁用操作键")
                    HStack(spacing: Metrics.gap) {
                        Button { } label: { Text("导入…").frame(width: 160) }.buttonStyle(.key)
                        Button("撤销") { }.buttonStyle(.key)
                        Button("重做") { }.buttonStyle(.key)
                        Spacer()
                        Button("复位") { }.buttonStyle(.key)
                        Button("导出") { }.buttonStyle(PrimaryKeyStyle())
                    }.disabled(true)
                }
                Text("真实 SwiftUI / AppKit 控件 · 无照片材质叠加").font(.caption11).foregroundStyle(Theme.textSecondary)
            }.padding(36).frame(width: 760, height: 860).foregroundStyle(Theme.text).background(InstrumentPlate())
                .preferredColorScheme(theme.colorScheme)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            try attachUISnapshot(host, name: "materials-v3-\(theme.rawValue)")
            window.contentView = nil
        }
    }

    @MainActor private func attachUISnapshot(_ host: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["PHOSDECK_UI_SNAPSHOT_DIRECTORY"] {
            try png.write(to: URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name + ".png"), options: .withoutOverwriting)
        }
    }

    @MainActor func testWorkflowSheetsFitValidationWindowWithLongContent() async throws {
        let f = ImportTests(); try f.setUpWithError()
        defer { try? f.tearDownWithError() }
        let root = try f.catalog.addRoot(url: f.source, bookmark: AccessLease.bookmark(f.source, readOnly: true))
        let url = f.source.appendingPathComponent("合成样片.jpg"); try f.image(url)
        let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: f.source)
        try f.catalog.index(photo)
        let model = AppModel(); model.catalog = f.catalog; try model.reload(); model.choose([photo.id], active: photo.id)
        defer { model.choose([], active: nil); model.catalog = nil }
        let suite = "ui-forms-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let collection = PhotoCollection(id: "ui-rules", name: String(repeating: "长集合名", count: 20),
                                         rules: try JSONEncoder().encode(SmartRules(conditions: (0..<32).map { _ in SmartRule() })))
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            let forms: [(String, AnyView, CGSize)] = [
                ("smart-collection", AnyView(SmartCollectionSheet(model: model, collection: collection)), CGSize(width: 570, height: 740)),
                ("auto-stack", AnyView(AutoStackSheet(model: model)), CGSize(width: 720, height: 560)),
                ("pairing", AnyView(PairingSheet(model: model)), CGSize(width: 900, height: 620)),
                ("import", AnyView(ImportSheet(model: model)), CGSize(width: 1100, height: 700)),
                ("export", AnyView(ExportSheet(model: model, defaults: preferences)), CGSize(width: 860, height: 580)),
                ("settings", AnyView(SettingsSheet(model: model)), CGSize(width: 660, height: 500)),
                ("export-recovery", AnyView(ExportRecoverySheet(model: model)), CGSize(width: 680, height: 440)),
                ("import-recovery", AnyView(ImportRecoverySheet(model: model)), CGSize(width: 740, height: 500)),
                ("keywords", AnyView(KeywordEditor(model: model)), CGSize(width: 390, height: 450))
            ]
            for (name, form, size) in forms {
                let host = NSHostingView(rootView: form.defaultAppStorage(preferences).preferredColorScheme(theme.colorScheme))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, name)
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1, name)
                XCTAssertLessThanOrEqual(size.height, 740, "1280×800 窗口保留标题栏与边界")
                try attachUISnapshot(host, name: "form-\(name)-\(theme.rawValue)")
                window.contentView = nil
            }
        }
    }

    @MainActor func testMainWorkflowLayoutsAndSyntheticReviewFixture() async throws {
        let f = ImportTests(); try f.setUpWithError()
        let keepFixture = ProcessInfo.processInfo.environment["PHOSDECK_KEEP_WORKFLOW_FIXTURE"] == "1"
        defer {
            if keepFixture { print("WORKFLOW_REVIEW_CATALOG \(f.catalog.fileURL.path)") }
            else { try? f.tearDownWithError() }
        }
        let root = try f.catalog.addRoot(url: f.source, bookmark: AccessLease.bookmark(f.source, readOnly: true))
        for index in 0..<3 {
            let url = f.source.appendingPathComponent("Workflow-\(index + 1).jpg")
            let cg = try XCTUnwrap(CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 3600,
                space: ImagePipeline.outputSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for x in 0..<900 {
                let t = Double(x) / 899
                cg.setFillColor(CGColor(srgbRed: index == 0 ? t : 0.18 + t * 0.6,
                    green: index == 0 ? t : index == 1 ? 0.22 + t * 0.5 : 0.5 - t * 0.2,
                    blue: index == 0 ? t : 0.6 - t * 0.3, alpha: 1))
                cg.fill(CGRect(x: x, y: 0, width: 1, height: 600))
            }
            let image = try XCTUnwrap(cg.makeImage())
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            try f.catalog.index(ReferenceImporter.inspect(url: url, root: root, rootURL: f.source))
            if keepFixture {
                let attachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: UTType.jpeg.identifier)
                attachment.name = url.lastPathComponent; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        let model = AppModel(); model.catalog = f.catalog; try model.reload()
        model.choose(Set(model.photos.map(\.id)), active: model.photos.first?.id)
        defer { model.choose([], active: nil); model.catalog = nil }
        try await waitUntil { model.canEdit && model.image != nil }
        let suite = "main-workflow-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "libraryFiltersOpen")
        func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
        }
        for theme in [ChromeTheme.ivory, .graphite] {
            preferences.set(theme.rawValue, forKey: "chromeTheme")
            for size in [CGSize(width: 1440, height: 900), CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 640)] {
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua); window.contentView = host
                model.selectWorkspace(.grid); model.search = "Workflow"; model.filterChanged()
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
                XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
                try attachUISnapshot(host, name: "main-library-\(Int(size.width))-\(theme.rawValue)")
                if size.width == 1000 {
                    let sections = model.filterSections
                    model.filterSections = Set(LibraryFilterSection.allCases)
                    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
                    XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1, "All filter groups fit the compact workspace")
                    XCTAssertLessThanOrEqual(host.fittingSize.height, size.height + 1)
                    try attachUISnapshot(host, name: "library-filters-combined-\(theme.rawValue)")
                    model.filterSections = sections
                }
                model.selectWorkspace(.develop); model.selectDevelopTool(.crop)
                try await waitUntil { descendants(host, AdjustmentNSSlider.self).contains { $0.accessibilityLabel() == "角度" } }
                host.layoutSubtreeIfNeeded()
                XCTAssertFalse(descendants(host, AdjustmentNSSlider.self).contains { $0.accessibilityLabel() == "曝光度" }, "Crop shows geometry controls only")
                XCTAssertLessThanOrEqual(host.fittingSize.width, size.width + 1)
                try attachUISnapshot(host, name: "main-crop-\(Int(size.width))-\(theme.rawValue)")
                model.selectDevelopTool(.adjust)
                try await waitUntil { descendants(host, AdjustmentNSSlider.self).contains { $0.accessibilityLabel() == "曝光度" } }
                window.contentView = nil
            }
        }
        model.selectWorkspace(.single); model.search = "no-such-photo"; model.filterChanged()
        XCTAssertTrue(model.photos.isEmpty)
        let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
        host.frame = CGRect(x: 0, y: 0, width: 1280, height: 800); host.layoutSubtreeIfNeeded()
        try attachUISnapshot(host, name: "main-empty-filter")
        model.clearFilters(); model.filterChanged()
        XCTAssertEqual(model.resultCount, 3)
        XCTAssertEqual(model.workspaceMode, .single, "Recovering an empty single-photo view preserves the view")
    }

    @MainActor func testWorkspaceFitsPlannedWindowSizesAndBothOrientations() async throws {
        let suite = "layout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "developBasicOpen")
        preferences.set(false, forKey: "developMixerOpen")
        preferences.set(false, forKey: "developGradingOpen")
        preferences.set(true, forKey: "showLeftPanel")
        preferences.set(true, forKey: "showRightPanel")
        preferences.set(true, forKey: "showFilmstrip")
        func descendants<T: NSView>(_ root: NSView, type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type: type) }
        }
        for windowSize in [CGSize(width: 1440, height: 900), CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 640)] {
            for portrait in [false, true] {
                preferences.set(portrait ? Metrics.leftPanel.range.upperBound : Metrics.leftPanel.initial, forKey: "workspaceLeftWidth")
                preferences.set(portrait ? Metrics.rightPanel.range.upperBound : Metrics.rightPanel.initial, forKey: "workspaceRightWidth")
                let model = AppModel()
                model.editMode = true; model.singleView = true; model.canEdit = true
                let source = portrait ? CGSize(width: 80, height: 120) : CGSize(width: 120, height: 80)
                model.activePhoto = Photo(id: "layout", rootID: "test", relativePath: "layout.ARW", identity: Data(), identityKey: "layout", width: Int(source.width), height: Int(source.height))
                model.activeID = "layout"; model.selection = ["layout"]; model.photos = [try XCTUnwrap(model.activePhoto)]
                model.recipe = EditRecipe(sourceDigest: String(repeating: "a", count: 64), decoderVersion: "test", baselineExposure: 0, baselineTemperature: 5500, baselineTint: 0, temperature: 5500, tint: 0)
                model.image = CIContext().createCGImage(CIImage(color: CIColor(red: 0.25, green: 0.4, blue: 0.5)), from: CGRect(origin: .zero, size: source))
                model.renderedNativeSize = source; model.orientedSourceSize = source
                let theme = portrait ? ChromeTheme.graphite : .ivory
                preferences.set(theme.rawValue, forKey: "chromeTheme")
                let host = NSHostingView(rootView: WorkspaceView(model: model).defaultAppStorage(preferences))
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: windowSize), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: portrait ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await waitUntil { descendants(host, type: AdjustmentNSSlider.self).count >= 13 }
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.size, windowSize)
                let sliders = descendants(host, type: AdjustmentNSSlider.self)
                let exposure = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "曝光度" })
                let contrast = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "对比度" })
                let highlights = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "高光" })
                let faderFrames = [exposure, contrast, highlights].map { $0.convert($0.bounds, to: host) }
                for frame in faderFrames {
                    XCTAssertGreaterThan(frame.width, frame.height * 2, "数值参数保持水平推子")
                    XCTAssertEqual(frame.minX, faderFrames[0].minX, accuracy: 1, "曝光、对比度与其他参数逐行对齐")
                }
                XCTAssertGreaterThan(abs(faderFrames[0].midY - faderFrames[1].midY), 28, "曝光与对比度各占一行")
                let saturation = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "饱和度" })
                XCTAssertGreaterThan(saturation.visibleRect.height, 0, "Basic controls remain reachable at \(windowSize)")
                XCTAssertGreaterThan(saturation.visibleRect.width, 40)
                let metal = try XCTUnwrap(descendants(host, type: PhotoMetalCanvas.self).first)
                XCTAssertGreaterThan(metal.bounds.width, 400)
                let frame = metal.convert(metal.bounds, to: host)
                XCTAssertTrue(host.bounds.contains(frame))
                let size = metal.presentationSize(source: try XCTUnwrap(model.image), canvas: metal.drawableSize)
                XCTAssertLessThanOrEqual(size.width, metal.drawableSize.width + 0.001)
                XCTAssertLessThanOrEqual(size.height, metal.drawableSize.height + 0.001)
                try attachUISnapshot(host, name: "workspace-\(Int(windowSize.width))x\(Int(windowSize.height))-\(portrait ? "portrait" : "landscape")-\(theme.rawValue)")
                window.contentView = nil
            }
        }
    }

    func testKeyTravelLatchesUntilReleasedAndBottomsOutOnlyWhileHeld() {
        XCTAssertEqual(KeyTravel(pressed: false, selected: false), .raised)
        XCTAssertEqual(KeyTravel(pressed: false, selected: true), .latched)
        XCTAssertEqual(KeyTravel(pressed: true, selected: false), .held)
        XCTAssertEqual(KeyTravel(pressed: true, selected: true), .held)
        for height in [16.0, 22.0, 28.0, 72.0] {
            XCTAssertGreaterThan(KeyTravel.raised.lip(height: height), KeyTravel.latched.lip(height: height))
            XCTAssertGreaterThan(KeyTravel.latched.lip(height: height), KeyTravel.held.lip(height: height))
            XCTAssertEqual(KeyTravel.held.lip(height: height), 0)
            XCTAssertLessThan(KeyTravel.raised.labelOffset(height: height), KeyTravel.held.labelOffset(height: height))
            for selected in [false, true] {
                let rest = KeyTravel(pressed: false, selected: selected, enabled: false)
                let limited = KeyTravel(pressed: true, selected: selected, enabled: false)
                XCTAssertGreaterThan(limited.lip(height: height), 0, "禁用键不能按到底")
                XCTAssertLessThan(limited.lip(height: height), rest.lip(height: height), "禁用键保留短行程")
            }
        }
    }

    @MainActor private final class LockedKeysFixture: ObservableObject {
        @Published var enabled = false
        @Published var actions = 0
    }
    private struct LockedKeysFixtureView: View {
        @ObservedObject var state: LockedKeysFixture
        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 20) {
                    Text("可用键 · 按到底").font(.body13).foregroundStyle(Theme.textSecondary)
                    Text("撤销").font(.system(size: 12)).frame(width: 44, height: 28).background(KeySurface(pressed: true))
                    Spacer()
                    Text("禁用键 · 短行程机械限位").font(.body13).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: Metrics.gap) {
                    Button { state.actions += 1 } label: { Text("导入…").frame(width: 160) }.buttonStyle(.key)
                    Button("撤销") { state.actions += 1 }.buttonStyle(.key)
                    Button("重做") { state.actions += 1 }.buttonStyle(.key)
                    Spacer()
                    Button("复位") { state.actions += 1 }.buttonStyle(.key)
                    Button("导出") { state.actions += 1 }.buttonStyle(PrimaryKeyStyle())
                }.disabled(!state.enabled)
            }.padding(24).frame(width: 760, height: 150).foregroundStyle(Theme.text).background(InstrumentPlate())
        }
    }

    @MainActor func testDisabledKeysReceiveLimitedPressureWithoutActivatingAndReleaseOnCancel() async throws {
        func feedbackViews(_ view: NSView) -> [LockedKeyFeedbackView] {
            (view as? LockedKeyFeedbackView).map { [$0] } ?? view.subviews.flatMap(feedbackViews)
        }
        func pixels(_ host: NSView) throws -> Data {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        for theme in [ChromeTheme.ivory, .graphite] {
            let state = LockedKeysFixture()
            let host = NSHostingView(rootView: LockedKeysFixtureView(state: state).preferredColorScheme(theme.colorScheme))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 150), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: theme == .ivory ? .aqua : .darkAqua)
            window.contentView = host
            defer { window.orderOut(nil); window.contentView = nil }
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await waitUntil { feedbackViews(host).count == 5 }
            try await Task.sleep(for: .milliseconds(200))
            let rest = try pixels(host)
            try attachUISnapshot(host, name: "locked-keys-rest-\(theme.rawValue)")
            let views = feedbackViews(host).sorted { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x }
            for (index, view) in views.enumerated() {
                let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                func event(_ type: NSEvent.EventType, at location: CGPoint) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
                }
                let hit = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
                XCTAssertTrue(hit === view, "禁用键的指针命中受限反馈层：\(String(describing: hit))，反馈层 \(view)，窗口坐标 \(point)")
                view.mouseDown(with: try event(.leftMouseDown, at: point))
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertNotEqual(try pixels(host), rest, "受压时出现短行程反馈")
                XCTAssertEqual(state.actions, 0, "禁用动作始终不触发")
                if index == 0 { try attachUISnapshot(host, name: "locked-keys-limited-\(theme.rawValue)") }
                let outside = view.convert(CGPoint(x: -20, y: -20), to: nil)
                view.mouseDragged(with: try event(.leftMouseDragged, at: outside))
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(try pixels(host), rest, "拖出按钮后取消受压")
                view.mouseDragged(with: try event(.leftMouseDragged, at: point))
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertNotEqual(try pixels(host), rest, "仍按住时拖回按钮可再次碰到限位")
                view.mouseUp(with: try event(.leftMouseUp, at: point))
                try await Task.sleep(for: .milliseconds(150))
                if index == 0 { try attachUISnapshot(host, name: "locked-keys-returned-\(theme.rawValue)") }
                XCTAssertEqual(try pixels(host), rest, "松开后回到原始位置")
                view.mouseDown(with: try event(.leftMouseDown, at: point))
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(try pixels(host), rest, "窗口失焦取消受压，不留下卡住状态")
            }
            state.enabled = true
            try await waitUntil { feedbackViews(host).isEmpty }
            XCTAssertEqual(state.actions, 0, "恢复可用性不触发按钮")
        }
    }

    @MainActor private final class PanelScrollFixture: ObservableObject {
        @Published var shown = true
        @Published var offset = 420.0
    }
    private struct PanelScrollFixtureView: View {
        @ObservedObject var state: PanelScrollFixture
        var body: some View {
            if state.shown {
                RememberedPanelScroll(offset: $state.offset) {
                    VStack(spacing: 0) {
                        ForEach(0..<50) { row in Text("Row \(row)").frame(height: 24) }
                    }.frame(maxWidth: .infinity)
                }
            } else { Text("Library mode") }
        }
    }
    @MainActor func testDevelopScrollOffsetRestoresAfterUnmountAndClampsToShorterViewport() async throws {
        let state = PanelScrollFixture()
        let host = NSHostingView(rootView: PanelScrollFixtureView(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func scroll(_ view: NSView) -> NSScrollView? {
            if let result = view as? NSScrollView { return result }
            return view.subviews.compactMap { scroll($0) }.first
        }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { abs((scroll(host)?.contentView.bounds.minY ?? -1) - 420) < 1 }
        state.shown = false
        try await waitUntil { scroll(host) == nil }
        XCTAssertEqual(state.offset, 420)
        state.shown = true
        try await waitUntil { abs((scroll(host)?.contentView.bounds.minY ?? -1) - 420) < 1 }
        state.shown = false
        try await waitUntil { scroll(host) == nil }
        window.setContentSize(CGSize(width: 300, height: 1100))
        state.shown = true
        try await waitUntil { abs((scroll(host)?.contentView.bounds.minY ?? -1) - 100) < 1 }
        XCTAssertEqual(state.offset, 420, "Programmatic clamping must not overwrite the user's remembered offset")
        window.contentView = nil
    }
}

extension ImagingTests {
    @MainActor func testCanvasContinuousDragUsesPositionsEvenWithZeroEventDeltas() throws {
        let canvas = PhotoMetalCanvas()
        let viewport = PhotoViewport()
        canvas.viewport = viewport; canvas.actualPixels = true
        canvas.nativeSize = CGSize(width: 4000, height: 6000)
        viewport.update(image: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 400, height: 240), zoomed: true)
        canvas.source = try XCTUnwrap(CIContext().createCGImage(CIImage(color: .red), from: CGRect(x: 0, y: 0, width: 40, height: 60)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        var clicks = 0
        canvas.onClick = { _ in clicks += 1 }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, 30, 30))
        for step in 1...20 {
            let drag = try event(.leftMouseDragged, 30 + CGFloat(step) * 5, 30 + CGFloat(step) * 2)
            XCTAssertEqual(drag.deltaX, 0)
            canvas.mouseDragged(with: drag)
            XCTAssertEqual(viewport.center.x, 0.5 - CGFloat(step) * 5 * window.backingScaleFactor / 4000, accuracy: 0.00001)
            XCTAssertEqual(viewport.center.y, 0.5 + CGFloat(step) * 2 * window.backingScaleFactor / 6000, accuracy: 0.00001)
        }
        canvas.mouseUp(with: try event(.leftMouseUp, 130, 70))
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(canvas.displayCenter, viewport.center)
        window.contentView = nil
    }

    func testClipWarningMarksOnlyThePreviewEndCodes() throws {
        XCTAssertTrue(DisplayOverlay.available)
        let input: [UInt8] = [255, 10, 10, 255, 254, 254, 254, 255, 0, 128, 128, 255, 1, 1, 1, 255, 128, 128, 128, 255]
        let width = input.count / 4, space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(input) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                                          decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        // Same working format as the Metal canvas.
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        var output = [UInt8](repeating: 0, count: input.count)
        context.render(DisplayOverlay.clipping(CIImage(cgImage: image)), toBitmap: &output, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: 1), format: .RGBA8, colorSpace: space)
        let pixels = stride(from: 0, to: output.count, by: 4).map { Array(output[$0..<$0 + 3]) }
        func near(_ pixel: [UInt8], _ token: UInt32, _ message: String = "") {
            let expected = [Int(token >> 16 & 0xFF), Int(token >> 8 & 0xFF), Int(token & 0xFF)]
            XCTAssertTrue(zip(pixel, expected).allSatisfy { abs(Int($0) - $1) <= 1 }, "\(pixel) ≠ \(expected) \(message)")
        }
        near(pixels[0], 0xC2187F, "Highlight wins when one channel is at 255; token photoOverlay.clipHighlight")
        XCTAssertEqual(pixels[1], [254, 254, 254])
        near(pixels[2], 0x3FA9FF, "token photoOverlay.clipShadow")
        XCTAssertEqual(pixels[3], [1, 1, 1])
        XCTAssertEqual(pixels[4], [128, 128, 128])
    }

    func testMaskViewsStayOnTheDisplayLayer() throws {
        XCTAssertTrue(DisplayOverlay.available)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func image(_ pixels: [Float], width: Int) -> CIImage {
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: 1), format: .RGBAf, colorSpace: space)
        }
        let photo = image([0.2, 0.4, 0.6, 1, 0.2, 0.4, 0.6, 1, 0.2, 0.4, 0.6, 1], width: 3)
        let coverage = image([1, 1, 1, 1, 0, 0, 0, 1, 0.5, 0.5, 0.5, 1], width: 3)
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        func rendered(_ style: MaskOverlayStyle) -> [[Float]] {
            var output = [Float](repeating: 0, count: 12)
            let viewed = DisplayOverlay.maskView(photo, coverage: coverage, style: style, tint: DisplayOverlay.maskTint(0))
            context.render(viewed, toBitmap: &output, rowBytes: 48, bounds: viewed.extent, format: .RGBAf, colorSpace: space)
            return stride(from: 0, to: output.count, by: 4).map { Array(output[$0..<$0 + 3]) }
        }
        func near(_ pixel: [Float], _ expected: [Float], _ message: String) {
            XCTAssertEqual(pixel.count, expected.count)
            for (got, want) in zip(pixel, expected) {
                XCTAssertEqual(got, want, accuracy: 0.01, message)
            }
        }
        let color = rendered(.color)
        near(color[0], [0.56, 0.22, 0.33], "Full coverage tints at 0.45")
        near(color[1], [0.2, 0.4, 0.6], "Zero coverage leaves the photo")
        near(color[2], [0.38, 0.31, 0.465], "Half coverage")
        let gray = rendered(.colorOnGray)
        near(gray[0], [0.6546, 0.2046, 0.2046], "Gray photo plus the same tint")
        near(gray[1], [0.3719, 0.3719, 0.3719], "Unselected gray uses Rec.709 luminance")
        let onBlack = rendered(.onBlack)
        near(onBlack[0], [0.2, 0.4, 0.6], "Selected photo on black")
        near(onBlack[1], [0, 0, 0], "token photoOverlay.dark")
        near(onBlack[2], [0.1, 0.2, 0.3], "Partial coverage darkens the photo")
        let onWhite = rendered(.onWhite)
        near(onWhite[1], [1, 1, 1], "token photoOverlay.light")
        near(onWhite[2], [0.6, 0.7, 0.8], "Partial coverage toward white")
        let mono = rendered(.monochrome)
        near(mono[0], [1, 1, 1], "Selected")
        near(mono[1], [0, 0, 0], "Unselected")
        near(mono[2], [0.5, 0.5, 0.5], "Partial")
        let shifted = coverage.transformed(by: CGAffineTransform(translationX: 5, y: 6))
        let placed = photo.transformed(by: CGAffineTransform(translationX: 10, y: 20))
        let fitted = PhotoMetalCanvas.fitted(shifted, to: placed.extent)
        XCTAssertEqual(fitted.extent, placed.extent)
        var aligned = [Float](repeating: 0, count: 12)
        context.render(DisplayOverlay.maskView(placed, coverage: fitted, style: .monochrome, tint: DisplayOverlay.maskTint(0)),
                       toBitmap: &aligned, rowBytes: 48, bounds: placed.extent, format: .RGBAf, colorSpace: space)
        XCTAssertEqual(aligned[0], 1, accuracy: 0.01)
        XCTAssertEqual(aligned[4], 0, accuracy: 0.01)
    }
}
