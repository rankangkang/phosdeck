import XCTest
import AppKit
import SwiftUI
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import Phosdeck

final class FlipTests: XCTestCase {
    private var folder: URL!
    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAf,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    private func fixture(_ name: String, type: UTType = .tiff, orientation: Int = 1) throws -> ImageRequest {
        let width = 80, height = 64
        var values = [UInt16](repeating: 65535, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            values[i] = UInt16(2000 + x * 450 + y * 31)
            values[i + 1] = UInt16(4000 + y * 500 + x * 67)
            values[i + 2] = UInt16(3000 + ((x / 5 + y / 7) % 2) * 28000 + x * 110)
        } }
        let data = values.withUnsafeBytes { Data($0) }
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
            space: ImagePipeline.outputSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little),
            provider: XCTUnwrap(CGDataProvider(data: data as CFData)), decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        let url = folder.appendingPathComponent(name + "." + (type == .jpeg ? "jpg" : "tif"))
        let output = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        let root = StorageRoot(id: "synthetic", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "synthetic")
        return ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: folder), root: root, recipe: nil)
    }
    private func request(_ source: ImageRequest, _ recipe: EditRecipe) -> ImageRequest {
        ImageRequest(photo: source.photo, root: source.root, recipe: recipe)
    }
    private func pixels(_ image: CGImage) -> Data {
        var data = Data(count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { bytes in
            context.render(CIImage(cgImage: image), toBitmap: bytes.baseAddress!, rowBytes: image.width * 4,
                bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        }
        return data
    }
    private func mirrored(_ data: Data, width: Int, height: Int, horizontal: Bool, vertical: Bool) -> Data {
        var result = Data(count: data.count)
        result.withUnsafeMutableBytes { destination in data.withUnsafeBytes { source in
            let src = source.bindMemory(to: UInt32.self), dst = destination.bindMemory(to: UInt32.self)
            for y in 0..<height { for x in 0..<width {
                dst[y * width + x] = src[(vertical ? height - 1 - y : y) * width + (horizontal ? width - 1 - x : x)]
            } }
        } }
        return result
    }
    private func bitmap(_ image: CIImage) throws -> CGImage {
        try XCTUnwrap(context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace, deferred: false))
    }

    func testRecipeRequiresFlagsAndTreatsThemAsDiscreteGeometry() async throws {
        let source = try fixture("recipe"), pipeline = ImagePipeline()
        let baseline = try await pipeline.baseline(source)
        var recipe = baseline; recipe.flipHorizontal = true; recipe.flipVertical = true
        recipe.quarterTurns = 1; recipe.straightenDegrees = 7; recipe.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
        XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
        XCTAssertFalse(recipe.baseline().flipHorizontal); XCTAssertFalse(recipe.resetForCurrentPipeline().flipVertical)
        XCTAssertTrue(recipe.alignedBaseline().flipHorizontal); XCTAssertTrue(recipe.alignedBaseline().flipVertical)
        XCTAssertTrue(recipe.changeTitle(from: baseline).contains("水平翻转")); XCTAssertTrue(recipe.changeTitle(from: baseline).contains("垂直翻转"))
        XCTAssertFalse(try baseline.pasting(recipe, options: RecipePasteOptions()).flipHorizontal)
        let options = RecipePasteOptions(tone: false, whiteBalance: false, color: false, geometry: true, curves: false, zones: false)
        XCTAssertTrue(try baseline.pasting(recipe, options: options).flipHorizontal)
        XCTAssertFalse(try baseline.applyingPreset(recipe, options: options, amount: 0.3).flipHorizontal)
        XCTAssertTrue(try baseline.applyingPreset(recipe, options: options, amount: 0.5).flipHorizontal)
        XCTAssertTrue(try baseline.applyingPreset(recipe, options: options, amount: 2).flipVertical)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
        json.removeValue(forKey: "flipHorizontal")
        XCTAssertThrowsError(try JSONDecoder().decode(EditRecipe.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testAllEXIFRotationsStraightenAndFlipsPreserveCroppedPixels() async throws {
        let pipeline = ImagePipeline()
        for type in [UTType.jpeg, .tiff] { for orientation in 1...8 {
            let source = try fixture("exif-\(type.identifier)-\(orientation)", type: type, orientation: orientation)
            let baseline = try await pipeline.baseline(source)
            let decoded = try XCTUnwrap(CIImage(contentsOf: folder.appendingPathComponent(source.photo.name), options: [.applyOrientationProperty: true]))
            for turn in 0...3 { for angle in [-7.0, 0, 11] {
                var recipe = baseline; recipe.quarterTurns = turn; recipe.straightenDegrees = angle
                recipe.crop = Crop(x: 0.125, y: 0.125, width: 0.625, height: 0.5)
                let reference = try await pipeline.render(request(source, recipe), longEdge: nil)
                let data = pixels(reference.image)
                let unreflected = try ImagePipeline.geometry(decoded, recipe: recipe)
                for (horizontal, vertical) in [(true, false), (false, true), (true, true)] {
                    recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
                    let actual = try await pipeline.render(request(source, recipe), longEdge: nil)
                    XCTAssertEqual(actual.fullSize, reference.fullSize); XCTAssertEqual(actual.orientedSourceSize, reference.orientedSourceSize)
                    let expected = mirrored(data, width: reference.image.width, height: reference.image.height, horizontal: horizontal, vertical: vertical)
                    let actualPixels = pixels(actual.image)
                    if actualPixels != expected {
                        let differences = zip(actualPixels, expected).map { abs(Int($0) - Int($1)) }
                        print("FLIP_DIFF type=\(type.identifier) exif=\(orientation) turn=\(turn) angle=\(angle) H=\(horizontal) V=\(vertical) max=\(differences.max() ?? 0) channels=\(differences.filter { $0 != 0 }.count)")
                    }
                    // Reflect the floating graph before output quantization. A
                    // straighten may fuse into this sample; mirroring an already
                    // quantized 8-bit bitmap is only an exact oracle at angle 0.
                    let transform = CGAffineTransform(a: horizontal ? -1 : 1, b: 0, c: 0, d: vertical ? -1 : 1,
                        tx: horizontal ? unreflected.extent.width : 0, ty: vertical ? unreflected.extent.height : 0)
                    let expectedFloat = pixels(try bitmap(unreflected.transformed(by: transform)))
                    XCTAssertTrue(actualPixels == expectedFloat, "浮点图翻转：\(type.identifier) EXIF=\(orientation) turn=\(turn) angle=\(angle) H=\(horizontal) V=\(vertical)")
                    if angle == 0 { XCTAssertTrue(actualPixels == expected, "整数旋转/翻转必须逐字节相同") }
                }
            } }
        } }
    }

    func testCropEditorReflectsRectangleAndStraightenWithoutChangingSelectedContent() async throws {
        let source = try fixture("crop"), pipeline = ImagePipeline()
        let baseline = try await pipeline.baseline(source)
        let image = CIImage(cgImage: try await pipeline.render(request(source, baseline), longEdge: nil).image)
        for turn in 0...3 { for angle in [-11.0, 0, 8] { for (horizontal, vertical) in [(false, false), (true, false), (false, true), (true, true)] {
            var recipe = baseline; recipe.quarterTurns = turn; recipe.straightenDegrees = angle
            recipe.crop = Crop(x: 0.13, y: 0.17, width: 0.61, height: 0.57)
            recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
            let quality = try ImagePipeline.geometry(image, recipe: recipe)
            var full = recipe; full.crop = Crop(); full.straightenDegrees = 0
            let preview = try ImagePipeline.geometry(image, recipe: full)
            var screen = baseline; screen.crop = recipe.cropInDisplay; screen.straightenDegrees = recipe.cropPreviewAngle
            let displayed = try ImagePipeline.geometry(preview, recipe: screen)
            XCTAssertEqual(displayed.extent.size, quality.extent.size, "裁剪预览与输出尺寸一致")
            if displayed.extent.size == quality.extent.size {
                XCTAssertTrue(pixels(try bitmap(displayed)) == pixels(try bitmap(quality)), "live crop turn=\(turn) angle=\(angle) H=\(horizontal) V=\(vertical)")
            }
            let roundtrip = recipe.cropInDisplay.flipped(horizontal: horizontal, vertical: vertical)
            XCTAssertEqual(roundtrip.x, recipe.crop.x, accuracy: 1e-12); XCTAssertEqual(roundtrip.y, recipe.crop.y, accuracy: 1e-12)
            let displayedCrop = recipe.cropInDisplay
            let moved = CropInteraction.drag(displayedCrop, handle: .move, from: .zero, to: CGPoint(x: 2, y: -2), size: preview.extent.size, aspectRatio: nil)
            let stored = recipe.cropFromDisplay(moved)
            XCTAssertEqual(stored.width, recipe.crop.width); XCTAssertEqual(stored.height, recipe.crop.height)
        } } }
        for (horizontal, vertical) in [(false, false), (true, false), (false, true), (true, true)] {
            var recipe = baseline; recipe.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
            let size = CGSize(width: 6000, height: 4000), original = recipe.crop
            let moved = CropInteraction.drag(recipe.cropInDisplay, handle: .move, from: .zero, to: CGPoint(x: 0, y: 2), size: size, aspectRatio: nil)
            let before = MaskGeometry.mapping(size: size, recipe: recipe)
            recipe.crop = recipe.cropFromDisplay(moved)
            XCTAssertEqual(recipe.crop.x, original.x, "纵向拖动不能让未动的 x 轴发生浮点往返偏移")
            XCTAssertEqual(recipe.crop.width, original.width)
            XCTAssertEqual(MaskGeometry.mapping(size: size, recipe: recipe).output.width, before.output.width)
            XCTAssertNotEqual(recipe.crop.y, original.y)
        }
    }

    func testRotationCommandFollowsDisplayedDirectionWithReflections() async throws {
        let source = try fixture("rotate"), baseline = try await ImagePipeline().baseline(source)
        let size = CGSize(width: 80, height: 64)
        for turn in 0...3 { for angle in [-11.0, 0, 8] { for (horizontal, vertical) in [(false, false), (true, false), (false, true), (true, true)] { for steps in [1, 3] {
            var recipe = baseline; recipe.quarterTurns = turn; recipe.straightenDegrees = angle
            recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
            let before = MaskGeometry.mapping(size: size, recipe: recipe)
            let rotation = steps == 1
                ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: before.output.width)
                : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: before.output.height, ty: 0)
            let expected = before.transform.concatenating(rotation)
            recipe.rotateCanvas(by: steps)
            let after = MaskGeometry.mapping(size: size, recipe: recipe)
            XCTAssertEqual(after.output, CGSize(width: before.output.height, height: before.output.width))
            for (a, b) in zip(after.transform.values, expected.values) {
                XCTAssertEqual(a, b, accuracy: 1e-9)
            }
            XCTAssertEqual(recipe.flipHorizontal, horizontal); XCTAssertEqual(recipe.flipVertical, vertical)
        } } } }
    }

    func testMasksAndRepairsReflectInPreviewAndHighDepthExport() async throws {
        let source = try fixture("local"), pipeline = ImagePipeline()
        var recipe = try await pipeline.baseline(source)
        recipe.schemaVersion = 3
        var radial = MaskComponent(tool: .radial); radial.start = MaskPoint(0.3, 0.6); radial.radiusX = 0.2; radial.radiusY = 0.25
        var mask = LocalAdjustment(components: [radial]); mask.exposure = 0.6
        recipe.localAdjustments = [mask]
        recipe.repairs = [SpotRepair(mode: .clone, points: [MaskPoint(0.35, 0.5)], radius: 0.1, sourceOffset: MaskPoint(0.3, 0))]
        recipe.quarterTurns = 1; recipe.straightenDegrees = 5; recipe.crop = Crop(x: 0.125, y: 0.125, width: 0.75, height: 0.75)
        let reference = try await pipeline.render(request(source, recipe), longEdge: nil)
        for (horizontal, vertical) in [(true, false), (false, true), (true, true)] {
            recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
            let job = request(source, recipe), actual = try await pipeline.render(job, longEdge: nil)
            XCTAssertTrue(pixels(actual.image) == mirrored(pixels(reference.image), width: reference.image.width, height: reference.image.height, horizontal: horizontal, vertical: vertical))
            let png = folder.appendingPathComponent("flip-\(horizontal)-\(vertical).png")
            _ = try await pipeline.export(job, staging: png, options: ExportOptions(format: .png))
            let read = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
            XCTAssertEqual(pixels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(read, 0, nil))), pixels(actual.image))
            let deep = try await pipeline.render(job, longEdge: 32, pixelFormat: .RGBA16)
            let tiff = folder.appendingPathComponent("flip-\(horizontal)-\(vertical).tif")
            _ = try await pipeline.export(job, staging: tiff, options: ExportOptions(format: .tiff, longEdge: 32))
            let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(tiff as CFURL, nil)), high = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
            XCTAssertEqual(high.bitsPerComponent, 16)
            var a = [UInt16](repeating: 0, count: high.width * high.height * 4), b = a
            let bounds = CGRect(x: 0, y: 0, width: high.width, height: high.height)
            context.render(CIImage(cgImage: deep.image), toBitmap: &a, rowBytes: high.width * 8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
            context.render(CIImage(cgImage: high), toBitmap: &b, rowBytes: high.width * 8, bounds: bounds, format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
            XCTAssertTrue(a == b, "翻转的 TIFF16 仍来自完整浮点质量管线")
            XCTAssertGreaterThan(Set(stride(from: 0, to: a.count, by: 4).map { a[$0] }).count, 256)
        }
    }

    func testRAWOrientationAndReflectionsUseDecodedFrameOnce() async throws {
        let original = try MoreRAWTests.sample("leica_m8_8bit_uncompressed.DNG")
        var bytes = try Data(contentsOf: original)
        let little = bytes[0] == 0x49
        func number(_ p: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 | (Int(bytes[p + $1]) << ((little ? $1 : n - 1 - $1) * 8)) } }
        let ifd = number(4, 4), count = number(ifd, 2)
        let entry = try XCTUnwrap((0..<count).map { ifd + 2 + $0 * 12 }.first { number($0, 2) == 274 })
        XCTAssertEqual(number(entry + 2, 2), 3); XCTAssertEqual(number(entry + 4, 4), 1)
        bytes[entry + 8] = little ? 6 : 0; bytes[entry + 9] = little ? 0 : 6
        let url = folder.appendingPathComponent("synthetic-orientation6.DNG"); try bytes.write(to: url)
        let root = StorageRoot(id: "derived-cc0", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "CC0 derivative, orientation only")
        let source = ImageRequest(photo: try ReferenceImporter.inspect(url: url, root: root, rootURL: folder), root: root, recipe: nil)
        let pipeline = ImagePipeline(), baseline = try await pipeline.baseline(source)
        let normal = try await pipeline.render(request(source, baseline), longEdge: nil)
        XCTAssertEqual(normal.orientedSourceSize, CGSize(width: 2634, height: 3916))
        for (horizontal, vertical) in [(true, false), (false, true), (true, true)] {
            var recipe = baseline; recipe.flipHorizontal = horizontal; recipe.flipVertical = vertical
            let output = try await pipeline.render(request(source, recipe), longEdge: nil)
            XCTAssertEqual(output.fullSize, normal.fullSize)
            XCTAssertTrue(pixels(output.image) == mirrored(pixels(normal.image), width: normal.image.width, height: normal.image.height, horizontal: horizontal, vertical: vertical))
        }
        XCTAssertEqual(try SafeFileWriter.sha256(original), "7fdcca2371bb07fbf9483fcb08e3b5ab093eca1ca3924cbc86d6863736c31153")
    }

    func testFullResolutionRAWReusePreservesEachFormatWithReflections() async throws {
        let fresh = ImagePipeline(), cached = ImagePipeline()
        for name in MoreRAWTests.supportedFiles {
            let source = try MoreRAWTests.request(name)
            var recipe = try await fresh.baseline(source)
            recipe.saturation = 1.1; recipe.develop.vibrance = 8
            for horizontal in [false, true] {
                recipe.flipHorizontal = horizontal
                let job = request(source, recipe)
                let reference = try await fresh.render(job, longEdge: nil)
                let reused = try await cached.render(job, longEdge: nil, reuseDecoded: true)
                XCTAssertTrue(pixels(reference.image) == pixels(reused.image), "100% 缓存不能改变 \(name)，flip=\(horizontal)")
                let bytes = await cached.qualityCacheBytes
                XCTAssertLessThanOrEqual(bytes, 512 * 1024 * 1024)
                XCTAssertEqual(bytes > 0, recipe.decoderVersion == "8", "仅复用已验证的解码器；其他版本走完整质量图")
                print("RAW_FLIP_CACHE file=\(name) horizontal=\(horizontal) bytes=\(bytes)")
            }
        }
    }

    @MainActor func testNativeFlipControlsFitPanel() async throws {
        let source = try fixture("panel"), model = AppModel()
        var recipe = try await model.pipeline.baseline(source)
        recipe.flipHorizontal = true
        model.recipe = recipe; model.canEdit = true; model.cropMode = true
        let preferences = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        for key in ["developBasicOpen", "developMixerOpen", "developGradingOpen", "developCurvesOpen", "developZonesOpen", "developDetailsOpen", "developVignetteOpen", "developGrainOpen", "developBlackWhiteMixerOpen"] { preferences.set(false, forKey: key) }
        preferences.set(true, forKey: "developCropOpen")
        let host = NSHostingView(rootView: DevelopPanel(model: model).defaultAppStorage(preferences).background(Theme.panel))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 336, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let snapshot = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: snapshot)
        let attachment = XCTAttachment(data: try XCTUnwrap(snapshot.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
        attachment.name = "crop-and-flip-native-336pt"; attachment.lifetime = .keepAlways; add(attachment)

    }

    @MainActor func testNativeWorkflowHistoryUndoPointersThumbnailsAndReopen() async throws {
        func mark(_ text: String) { print("FLIP_WORKFLOW " + text); fflush(stdout) }
        do {
            mark("start")
            let fixture = try fixture("workflow"), original = folder.appendingPathComponent(fixture.photo.name)
            let digest = try SafeFileWriter.sha256(original)
            var catalog: CatalogStore? = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
            let root = try catalog!.addRoot(url: folder, bookmark: AccessLease.bookmark(folder, readOnly: true))
            var photo = fixture.photo; photo.rootID = root.id; try catalog!.index(photo)
            let model = AppModel(); model.catalog = catalog; model.undo.groupsByEvent = false; try model.reload()
            model.choose([photo.id], active: photo.id)
            try await wait { model.canEdit && model.previewCurrent }
            mark("baseline-ready")
            let baseline = try XCTUnwrap(model.recipe)
            model.undo.beginUndoGrouping(); model.changeRecipe { $0.flipHorizontal = true }; model.undo.endUndoGrouping()
            XCTAssertFalse(model.canvasCoordinatesCurrent)
            XCTAssertTrue(model.editHistory.first?.title.contains("水平翻转") == true)
            model.undo.undo(); XCTAssertFalse(try XCTUnwrap(model.recipe).flipHorizontal)
            model.undo.redo(); XCTAssertTrue(try XCTUnwrap(model.recipe).flipHorizontal)
            try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }

            mark("undo-redo-ready")
            model.undo.beginUndoGrouping(); model.addMask(.brush); model.undo.endUndoGrouping()
            try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }
            func outputPoint(_ point: MaskPoint, recipe: EditRecipe) -> CGPoint {
                let size = CGSize(width: 80, height: 64), m = MaskGeometry.mapping(size: size, recipe: recipe)
                let p = CGPoint(x: point.x * size.width, y: point.y * size.height).applying(m.transform)
                return CGPoint(x: p.x / m.output.width, y: p.y / m.output.height)
            }
            let sourcePoint = MaskPoint(0.3, 0.6), maskRecipe = try XCTUnwrap(model.recipe)
            let output = outputPoint(sourcePoint, recipe: maskRecipe)
            model.undo.beginUndoGrouping(); model.maskPointer(output, phase: .down); model.maskPointer(output, phase: .up); model.undo.endUndoGrouping()
            let brushPoint = try XCTUnwrap(model.selectedMaskComponent?.strokes.first?.points.first)
            XCTAssertEqual(brushPoint.x, sourcePoint.x, accuracy: 1e-9); XCTAssertEqual(brushPoint.y, sourcePoint.y, accuracy: 1e-9)
            mark("mask-ready")
            model.setSpotMode(true)
            try await wait { model.spotRank != nil && model.previewCurrent && model.canvasCoordinatesCurrent }
            model.spotKind = .clone
            let spotPoint = MaskPoint(0.35, 0.5), spotRecipe = try XCTUnwrap(model.recipe)
            let spotOutput = outputPoint(spotPoint, recipe: spotRecipe)
            model.undo.beginUndoGrouping(); model.spotPointer(spotOutput, phase: .down); model.spotPointer(spotOutput, phase: .up); model.undo.endUndoGrouping()
            let savedSpot = try XCTUnwrap(model.recipe?.repairs.first?.points.first)
            XCTAssertEqual(savedSpot.x, spotPoint.x, accuracy: 1e-9); XCTAssertEqual(savedSpot.y, spotPoint.y, accuracy: 1e-9)
            mark("spot-ready")
            model.setSpotMode(false)
            model.setMaskMode(true)
            let strokeCount = model.selectedMaskComponent?.strokes.count
            model.undo.beginUndoGrouping(); model.changeRecipe { $0.flipVertical = true }; model.undo.endUndoGrouping()
            XCTAssertFalse(model.canvasCoordinatesCurrent)
            model.maskPointer(output, phase: .down); model.maskPointer(output, phase: .up)
            XCTAssertEqual(model.selectedMaskComponent?.strokes.count, strokeCount, "几何旧帧不能接收新笔触")
            XCTAssertTrue(model.editHistory.first?.title.contains("垂直翻转") == true)
            try await wait { model.previewCurrent && model.canvasCoordinatesCurrent }
            XCTAssertTrue(model.saveSnapshot(name: "双向翻转"))
            model.setMaskMode(false)
            let saved = try XCTUnwrap(model.recipe), currentPhoto = try XCTUnwrap(catalog!.photo(photo.id))
            let thumbnails = ThumbnailService(), before = ThumbnailService.key(photo: photo, edge: 80)
            XCTAssertNotEqual(before, ThumbnailService.key(photo: currentPhoto, edge: 80))
            let thumbnail = try await thumbnails.image(photo: currentPhoto, root: root, edge: 80)
            let reference = try await model.pipeline.render(ImageRequest(photo: currentPhoto, root: root, recipe: saved), longEdge: 80)
            XCTAssertEqual(pixels(thumbnail), pixels(reference.image))
            XCTAssertEqual(saved.sourceDigest, baseline.sourceDigest)
            mark("thumbnail-ready")
            model.catalog = nil; model.undo.removeAllActions(); catalog = nil
            let reopened = try CatalogStore(directory: folder.appendingPathComponent("catalog"))
            let reopenedPhoto = try XCTUnwrap(reopened.photo(photo.id))
            XCTAssertEqual(try JSONDecoder().decode(EditRecipe.self, from: XCTUnwrap(reopenedPhoto.recipe)), saved)
            XCTAssertTrue(try reopened.editHistory(photoID: photo.id).contains { $0.title.contains("水平翻转") })
            XCTAssertEqual(try reopened.snapshots(photoID: photo.id).first?.title, "双向翻转")
            mark("reopen-ready")
            var unsupported = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            unsupported.removeValue(forKey: "flipVertical")
            let oldData = try JSONSerialization.data(withJSONObject: unsupported)
            try await reopened.database.write { try $0.execute(sql: "UPDATE photo SET recipe=? WHERE id=?", arguments: [oldData, photo.id]) }
            let second = AppModel(); second.catalog = reopened; try second.reload(); second.choose([photo.id], active: photo.id)
            try await wait { second.imageStatus.contains("缺少翻转状态") }
            XCTAssertFalse(second.canEdit); XCTAssertNil(second.recipe)
            XCTAssertEqual(try reopened.photo(photo.id)?.recipe, oldData, "旧配方拒绝后保留原字节，不自动重建基线")
            XCTAssertEqual(try SafeFileWriter.sha256(original), digest)
            mark("finished")
        } catch { mark(error.localizedDescription); XCTFail("Native flip workflow: \(error.localizedDescription)") }
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(15)) }
        throw LRCError("Timed out waiting for native flip state")
    }
}
