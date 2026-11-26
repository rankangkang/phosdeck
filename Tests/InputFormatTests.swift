import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Phosdeck

final class InputFormatTests: XCTestCase {
    private var directory: URL!
    private let context = CIContext(options: [
        .workingFormat: CIFormat.RGBAf,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    ])

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("input-formats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testFormatRegistryCoversExpandedRAWAndHEIFTypes() {
        let expectedRAW: Set<String> = ["arw", "sr2", "dng", "nef", "nrw", "cr2", "cr3", "raf", "orf", "rw2", "rwl", "pef", "3fr", "fff", "srw"]
        let expectedRaster: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png", "heic", "heif", "hif"]
        XCTAssertEqual(Set(PhotoFileType.rawTypes.keys), expectedRAW)
        XCTAssertEqual(PhotoFileType.editableExtensions, expectedRAW.union(expectedRaster))

        for ext in expectedRAW {
            let url = directory.appendingPathComponent("sample." + ext)
            XCTAssertTrue(PhotoFileType.isRAW(url), ext)
            XCTAssertFalse(PhotoFileType.isHEIF(url), ext)
        }
        for ext in ["heic", "heif", "hif"] {
            let url = directory.appendingPathComponent("sample." + ext)
            XCTAssertFalse(PhotoFileType.isRAW(url), ext)
            XCTAssertTrue(PhotoFileType.isHEIF(url), ext)
            XCTAssertTrue(PhotoFileType.usesPipelineThumbnail(url), ext)
        }
        XCTAssertTrue(PhotoFileType.isSupportedRasterUTI(UTType.heic.identifier))
        XCTAssertTrue(PhotoFileType.isSupportedRasterUTI(UTType.heif.identifier))
        XCTAssertFalse(PhotoFileType.isSupportedRasterUTI("public.heics"))

        let orf = PhotoFileType.descriptor(for: directory.appendingPathComponent("a.orf"))
        XCTAssertEqual(orf?.acceptedUTIs, ["com.olympus.raw-image", "com.olympus.or-raw-image"])
        let rw2 = PhotoFileType.descriptor(for: directory.appendingPathComponent("a.rw2"))
        XCTAssertEqual(rw2?.acceptedUTIs, ["com.panasonic.rw2-raw-image", "com.panasonic.raw-image"])
        let rwl = PhotoFileType.descriptor(for: directory.appendingPathComponent("a.rwl"))
        XCTAssertEqual(rwl?.acceptedUTIs, ["com.leica.rwl-raw-image", "com.leica.raw-image"])
    }

    func testTIFFVariantContainerValidationForStandardORFRW2AndRWL() throws {
        func makeTIFF(littleEndian: Bool, magic: UInt16, entries: [(tag: UInt16, type: UInt16, count: UInt32, value: UInt32)], payloadBytes: Int) -> Data {
            var data = Data()
            func append16(_ v: UInt16) {
                var value = littleEndian ? v.littleEndian : v.bigEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            func append32(_ v: UInt32) {
                var value = littleEndian ? v.littleEndian : v.bigEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: littleEndian ? [0x49, 0x49] : [0x4d, 0x4d])
            append16(magic)
            append32(8) // first IFD offset
            append16(UInt16(entries.count))
            for entry in entries {
                append16(entry.tag)
                append16(entry.type)
                append32(entry.count)
                append32(entry.value)
            }
            append32(0) // next IFD offset
            if payloadBytes > 0 { data.append(Data(repeating: 0xAA, count: payloadBytes)) }
            return data
        }

        // Standard TIFF (CR2 / PEF / 3FR / FFF / NRW / SRW / SR2): magic 42.
        let standardHeaderLen = 8 + 2 + 2 * 12 + 4
        let validStandard = makeTIFF(littleEndian: true, magic: 42, entries: [
            (273, 4, 1, UInt32(standardHeaderLen)),
            (279, 4, 1, 64)
        ], payloadBytes: 64)
        XCTAssertNoThrow(try PhotoFileType.validateTIFFRanges(validStandard, acceptedMagics: [42]))
        XCTAssertThrowsError(try PhotoFileType.validateTIFFRanges(validStandard.prefix(validStandard.count - 1), acceptedMagics: [42]))

        // Olympus ORF: magic 0x4F52 ("RO") and 0x5352 ("RS"), both endiannesses.
        for magic: UInt16 in [0x4F52, 0x5352] {
            for little in [true, false] {
                let validORF = makeTIFF(littleEndian: little, magic: magic, entries: [
                    (273, 4, 1, UInt32(standardHeaderLen)),
                    (279, 4, 1, 32)
                ], payloadBytes: 32)
                XCTAssertNoThrow(try PhotoFileType.validateTIFFRanges(validORF, acceptedMagics: [0x4F52, 0x5352, 42]))
                XCTAssertThrowsError(try PhotoFileType.validateTIFFRanges(validORF, acceptedMagics: [42]), "Standard TIFF gate must reject ORF magic")
                XCTAssertThrowsError(try PhotoFileType.validateTIFFRanges(validORF.prefix(validORF.count - 4), acceptedMagics: [0x4F52, 0x5352, 42]))
            }
        }

        // Panasonic RW2 / Leica RWL: magic 0x0055 and private RawDataOffset tag 0x0118.
        let rw2HeaderLen = 8 + 2 + 1 * 12 + 4
        let validRW2 = makeTIFF(littleEndian: true, magic: 0x0055, entries: [
            (0x0118, 4, 1, UInt32(rw2HeaderLen))
        ], payloadBytes: 16)
        XCTAssertNoThrow(try PhotoFileType.validateTIFFRanges(validRW2, acceptedMagics: [0x0055], extraOffsetTags: [0x0118]))
        XCTAssertThrowsError(try PhotoFileType.validateTIFFRanges(validRW2, acceptedMagics: [42]))
        let truncatedRW2 = makeTIFF(littleEndian: true, magic: 0x0055, entries: [
            (0x0118, 4, 1, UInt32(rw2HeaderLen + 100))
        ], payloadBytes: 16)
        XCTAssertThrowsError(try PhotoFileType.validateTIFFRanges(truncatedRW2, acceptedMagics: [0x0055], extraOffsetTags: [0x0118]))
    }

    func testISOBMFFContainerValidationRejectsInvalidHeaderTruncationAndSequences() {
        func box(_ type: String, payload: Data, extended: Bool = false) -> Data {
            var data = Data()
            if extended {
                var one = UInt32(1).bigEndian
                withUnsafeBytes(of: &one) { data.append(contentsOf: $0) }
                data.append(Data(type.utf8))
                var size64 = UInt64(16 + payload.count).bigEndian
                withUnsafeBytes(of: &size64) { data.append(contentsOf: $0) }
            } else {
                var size32 = UInt32(8 + payload.count).bigEndian
                withUnsafeBytes(of: &size32) { data.append(contentsOf: $0) }
                data.append(Data(type.utf8))
            }
            data.append(payload)
            return data
        }

        let ftyp = box("ftyp", payload: Data("heic".utf8) + Data(repeating: 0, count: 4))
        let meta = box("meta", payload: Data(repeating: 0, count: 12))
        let mdat64 = box("mdat", payload: Data(repeating: 7, count: 24), extended: true)
        let validHEIF = ftyp + meta + mdat64
        XCTAssertNoThrow(try PhotoFileType.validateISOBMFFRanges(validHEIF, requireMeta: true, forbidMovie: true))

        // Truncated 64-bit mdat box must fail.
        XCTAssertThrowsError(try PhotoFileType.validateISOBMFFRanges(validHEIF.prefix(validHEIF.count - 5), requireMeta: true, forbidMovie: true))
        // Missing ftyp first box must fail.
        XCTAssertThrowsError(try PhotoFileType.validateISOBMFFRanges(meta + mdat64, requireMeta: true, forbidMovie: true))
        // Missing meta for HEIF must fail; CR3 does not require top-level meta.
        XCTAssertThrowsError(try PhotoFileType.validateISOBMFFRanges(ftyp + mdat64, requireMeta: true, forbidMovie: true))
        XCTAssertNoThrow(try PhotoFileType.validateISOBMFFRanges(ftyp + mdat64, requireMeta: false, forbidMovie: false))
        // Movie / sequence box in HEIF must fail.
        let withMoov = ftyp + meta + box("moov", payload: Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try PhotoFileType.validateISOBMFFRanges(withMoov, requireMeta: true, forbidMovie: true))
        // Sequence major brand in ftyp must fail for HEIF.
        let seqFtyp = box("ftyp", payload: Data("msf1".utf8) + Data(repeating: 0, count: 4))
        XCTAssertThrowsError(try PhotoFileType.validateISOBMFFRanges(seqFtyp + meta + mdat64, requireMeta: true, forbidMovie: true))
    }

    func testSDRHEICAndHIFImportEditExportAndThumbnails() async throws {
        let pipeline = ImagePipeline()
        let thumbnails = ThumbnailService()
        let root = StorageRoot(id: "heif-root", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "HEIF")

        // 1. 8-bit sRGB .heic, 8-bit Display P3 rotated .heif, 10-bit SDR Display P3 .hif
        for (name, spaceName, bitDepth, orientation) in [
            ("srgb.heic", CGColorSpace.sRGB, 8, 1),
            ("p3-rotated.heif", CGColorSpace.displayP3, 8, 6),
            ("tenbit-p3.hif", CGColorSpace.displayP3, 10, 1)
        ] {
            let url = try writeHEIC(named: name, width: 96, height: 64, spaceName: spaceName, bitDepth: bitDepth, hasAlpha: false, orientation: orientation)
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: directory)
            XCTAssertFalse(photo.isRAW)
            XCTAssertTrue(photo.supportsEditing)
            XCTAssertEqual(photo.width, 96)
            XCTAssertEqual(photo.height, 64)

            let source = ImageRequest(photo: photo, root: root, recipe: nil)
            let baseline = try await pipeline.baseline(source)
            XCTAssertTrue(baseline.isRaster)
            XCTAssertTrue(baseline.isUnadjustedRaster)
            XCTAssertEqual(baseline.baselineTemperature, 5500)
            XCTAssertEqual(baseline.baselineExposure, 0)

            let original = try await pipeline.render(source, longEdge: nil)
            let neutral = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: baseline), longEdge: nil)
            let expectedSize = orientation >= 5 ? CGSize(width: 64, height: 96) : CGSize(width: 96, height: 64)
            XCTAssertEqual(neutral.orientedSourceSize, expectedSize)
            XCTAssertEqual(neutral.fullSize, expectedSize)
            XCTAssertEqual(pixels8(neutral.image), pixels8(original.image))

            let thumb = try await thumbnails.image(photo: photo, root: root, edge: 64)
            let expectedThumb = try await pipeline.render(source, longEdge: 64)
            XCTAssertEqual(pixels8(thumb), pixels8(expectedThumb.image))

            if bitDepth == 10 {
                let deep = try await pipeline.render(ImageRequest(photo: photo, root: root, recipe: baseline), longEdge: nil, pixelFormat: .RGBA16)
                let levels = Set(stride(from: 0, to: pixels16(deep.image).count, by: 4).map { pixels16(deep.image)[$0] })
                XCTAssertGreaterThan(levels.count, 256, "10-bit SDR HIF must retain > 8-bit precision in float/16-bit rendering")
            }

            var edited = baseline
            edited.exposure = 0.35
            edited.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            let editedRequest = ImageRequest(photo: photo, root: root, recipe: edited)
            let draft = try await pipeline.renderInteractive(editedRequest, longEdge: 64)
            XCTAssertLessThanOrEqual(max(draft.image.width, draft.image.height), 65)

            let tiffOut = directory.appendingPathComponent(name + "-out.tif")
            let size = try await pipeline.export(editedRequest, staging: tiffOut, options: ExportOptions(format: .tiff))
            try ImagePipeline.verifyExport(tiffOut, width: size.0, height: size.1, format: .tiff)
        }

        // 2. Static HEIC with alpha channel preserves transparency and requires JPEG matte.
        let alphaURL = try writeHEIC(named: "transparent.heic", width: 80, height: 60, spaceName: CGColorSpace.sRGB, bitDepth: 8, hasAlpha: true, orientation: 1)
        let alphaPhoto = try ReferenceImporter.inspect(url: alphaURL, root: root, rootURL: directory)
        let alphaRequest = ImageRequest(photo: alphaPhoto, root: root, recipe: nil)
        let alphaBaseline = try await pipeline.baseline(alphaRequest)
        let alphaJob = ImageRequest(photo: alphaPhoto, root: root, recipe: alphaBaseline)
        let jpegFail = directory.appendingPathComponent("alpha-no-matte.jpg")
        do {
            _ = try await pipeline.export(alphaJob, staging: jpegFail, options: ExportOptions(format: .jpeg, jpegMatte: .unselected))
            XCTFail("Transparent HEIC must require an explicit JPEG matte")
        } catch {}
        let pngOut = directory.appendingPathComponent("alpha-out.png")
        let pngSize = try await pipeline.export(alphaJob, staging: pngOut, options: ExportOptions(format: .png))
        try ImagePipeline.verifyExport(pngOut, width: pngSize.0, height: pngSize.1, format: .png)
    }

    func testDamagedMultiFrameDisguisedAndHDRHEIFAreRejected() async throws {
        let root = StorageRoot(id: "heif-reject", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "HEIF Reject")
        let pipeline = ImagePipeline()

        // 1. Truncated HEIC must fail even if ImageIO tolerates missing trailing bytes.
        let validURL = try writeHEIC(named: "base.heic", width: 64, height: 48, spaceName: CGColorSpace.sRGB, bitDepth: 8, hasAlpha: false, orientation: 1)
        let validBytes = try Data(contentsOf: validURL)
        let truncatedURL = directory.appendingPathComponent("truncated.heic")
        try validBytes.prefix(validBytes.count - 20).write(to: truncatedURL)
        XCTAssertThrowsError(try ReferenceImporter.inspect(url: truncatedURL, root: root, rootURL: directory))

        // 2. Multi-image / sequence HEIC (count > 1) must be rejected.
        let multiURL = directory.appendingPathComponent("multi.heic")
        let cg = try makeCGImage(width: 64, height: 48, spaceName: CGColorSpace.sRGB, bitDepth: 8, hasAlpha: false)
        let multiDest = try XCTUnwrap(CGImageDestinationCreateWithURL(multiURL as CFURL, UTType.heic.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(multiDest, cg, nil)
        CGImageDestinationAddImage(multiDest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(multiDest))
        XCTAssertThrowsError(try ReferenceImporter.inspect(url: multiURL, root: root, rootURL: directory))

        // 3. JPEG disguised as .heic / .heif / .hif must be rejected.
        for ext in ["heic", "heif", "hif"] {
            let fake = directory.appendingPathComponent("disguised." + ext)
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(fake as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, cg, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            XCTAssertThrowsError(try ReferenceImporter.inspect(url: fake, root: root, rootURL: directory))
        }

        // 4. HDR PQ and HLG HEIF must be explicitly rejected.
        for (name, space) in [("hdr-pq.heic", CGColorSpace.itur_2100_PQ), ("hdr-hlg.heif", CGColorSpace.itur_2100_HLG)] {
            let hdrURL = try writeHEIC(named: name, width: 64, height: 48, spaceName: space, bitDepth: 10, hasAlpha: false, orientation: 1)
            XCTAssertThrowsError(try ReferenceImporter.inspect(url: hdrURL, root: root, rootURL: directory)) { error in
                XCTAssertTrue(error.localizedDescription.contains("HDR") || error.localizedDescription.contains("PQ"))
            }
            let identity = try FileIdentity.read(hdrURL)
            let photo = Photo(id: name, rootID: root.id, relativePath: name, identity: try JSONEncoder().encode(identity), identityKey: identity.key, width: 64, height: 48)
            do {
                _ = try await pipeline.baseline(ImageRequest(photo: photo, root: root, recipe: nil))
                XCTFail("HDR HEIF must not create an SDR raster baseline")
            } catch {}
        }
    }

    func testRAWDecoderSessionMatchesDirectAppleRAWOnPublicCC0Samples() async throws {
        let candidates = ["a7iii_12bit_compressed.ARW", "leica_m8_8bit_uncompressed.DNG", "fuji_xs10_14bit_lossless.RAF"]
        var checked = 0
        for name in candidates {
            let url: URL
            do { url = try MoreRAWTests.sample(name) }
            catch is XCTSkip { continue }
            checked += 1

            let session = try RAWDecoderSession(url: url)
            try session.validateDecode()
            let direct = try XCTUnwrap(CIRAWFilter(imageURL: url))
            direct.extendedDynamicRangeAmount = 0
            let expectedSize = direct.orientation.rawValue >= 5
                ? CGSize(width: direct.nativeSize.height, height: direct.nativeSize.width)
                : direct.nativeSize
            XCTAssertEqual(session.orientedNativeSize, expectedSize, name)
            XCTAssertEqual(session.baselineMetrics.decoderVersion, direct.decoderVersion.rawValue, name)

            let rendered = try session.renderDevelop(
                previewEdge: 256, draft: false,
                baselineExposure: session.baselineMetrics.exposure, exposure: 0,
                temperature: session.baselineMetrics.temperature, tint: session.baselineMetrics.tint,
                details: RAWDetailSettings()
            ).image
            direct.scaleFactor = Float(min(1, 256 / max(direct.nativeSize.width, direct.nativeSize.height)))
            direct.isDraftModeEnabled = false
            let directImage = try XCTUnwrap(direct.outputImage)

            let a = try XCTUnwrap(context.createCGImage(rendered, from: rendered.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace, deferred: false))
            let b = try XCTUnwrap(context.createCGImage(directImage, from: directImage.extent.integral, format: .RGBA8, colorSpace: ImagePipeline.outputSpace, deferred: false))
            XCTAssertEqual(pixels8(a), pixels8(b), "RAWDecoderSession must match direct CIRAWFilter pixel for pixel: \(name)")
        }
        if checked == 0 {
            throw XCTSkip("No staged CC0 RAW samples available for RAWDecoderSession parity check")
        }
    }

    // MARK: - Helpers

    private func makeCGImage(width: Int, height: Int, spaceName: CFString, bitDepth: Int, hasAlpha: Bool) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: spaceName))
        if bitDepth > 8 {
            var values = [UInt16](repeating: 65535, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    values[i] = UInt16(1200 + x * 620)
                    values[i + 1] = UInt16(1800 + y * 860)
                    values[i + 2] = UInt16(3000 + ((x + y) % 80) * 650)
                    values[i + 3] = hasAlpha && x < width / 4 ? 0 : 65535
                }
            }
            let data = values.withUnsafeBytes { Data($0) }
            let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
            let alpha = hasAlpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast
            return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                                         space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(.byteOrder16Little),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
        }
        var values = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                values[i] = UInt8(min(255, x * 255 / max(1, width - 1)))
                values[i + 1] = UInt8(min(255, y * 255 / max(1, height - 1)))
                values[i + 2] = 128
                values[i + 3] = hasAlpha ? (x < width / 4 ? 0 : (x < width / 2 ? 128 : 255)) : 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(values) as CFData))
        let alpha = hasAlpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.noneSkipLast
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
    }

    private func writeHEIC(named name: String, width: Int, height: Int, spaceName: CFString, bitDepth: Int, hasAlpha: Bool, orientation: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let cg = try makeCGImage(width: width, height: height, spaceName: spaceName, bitDepth: bitDepth, hasAlpha: hasAlpha)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.98
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func pixels8(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &bytes, rowBytes: image.width * 4,
                       bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                       format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        return bytes
    }

    private func pixels16(_ image: CGImage) -> [UInt16] {
        var values = [UInt16](repeating: 0, count: image.width * image.height * 4)
        context.render(CIImage(cgImage: image), toBitmap: &values, rowBytes: image.width * 8,
                       bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                       format: .RGBA16, colorSpace: ImagePipeline.outputSpace)
        return values
    }
}
