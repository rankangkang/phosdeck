import XCTest
import CoreImage
import ImageIO
import LibRawRuntime
@testable import Phosdeck

final class LibRawRuntimeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("libraw-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLibraryVersionAndInvalidFilesFailSafely() throws {
        XCTAssertTrue(LibRawRuntime.libraryVersion.hasPrefix("0.22"), "Expected LibRaw 0.22.x, got \(LibRawRuntime.libraryVersion)")
        let garbage = directory.appendingPathComponent("not-a-raw.ARW")
        try Data("plain text not a raw file".utf8).write(to: garbage)
        let probe = try LibRawRuntime.probe(url: garbage, verifyBitstream: true)
        XCTAssertFalse(probe.succeeded)
        XCTAssertThrowsError(try LibRawRuntime.decodeLinear(url: garbage, halfSize: true))
    }

    func testPublicCC0SensorMeasurementsMakerNoteAndLibRawFallbackChannel() async throws {
        let samples = ["a7iii_12bit_compressed.ARW", "leica_m8_8bit_uncompressed.DNG", "fuji_xs10_14bit_lossless.RAF"]
        var checked = 0
        for name in samples {
            let url: URL
            do { url = try MoreRAWTests.sample(name) }
            catch is XCTSkip { continue }
            checked += 1

            let probe = try LibRawRuntime.probe(url: url, verifyBitstream: true)
            XCTAssertTrue(probe.succeeded, "\(name): \(probe.errorMessage)")
            XCTAssertFalse(probe.isBitStreamCorrupted, name)
            XCTAssertGreaterThan(probe.orientedWidth, 0, name)
            XCTAssertGreaterThan(probe.orientedHeight, 0, name)
            XCTAssertGreaterThan(probe.whiteLevel, 0, name)
            XCTAssertNotNil(probe.sensorBits, name)
            XCTAssertNotEqual(probe.compression, "unknown", name)
            if name.hasSuffix(".RAF") {
                XCTAssertTrue(probe.isXTrans, "X-S10 RAF must be identified as X-Trans")
                XCTAssertNotNil(probe.cameraLookHint, "Fujifilm X-S10 RAF should report FilmMode look hint")
                XCTAssertEqual(probe.cameraLookHint?.brand, "fujifilm")
            } else {
                XCTAssertFalse(probe.isXTrans, name)
            }

            // Exercise the explicit libraw-0.22-v1 decoder channel end-to-end through ImagePipeline + TIFF16 export.
            let folder = url.deletingLastPathComponent()
            let root = StorageRoot(id: "libraw-cc0", path: folder.path, bookmark: try AccessLease.bookmark(folder, readOnly: true), label: "CC0")
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: folder)
            let digest = try SafeFileWriter.sha256(url)
            var recipe = EditRecipe(
                sourceDigest: digest,
                decoderVersion: LibRawRuntime.decoderVersionIdentifier,
                baselineExposure: 0,
                baselineTemperature: 5500,
                baselineTint: 0,
                temperature: 5800,
                tint: 4,
                asShotWhiteBalance: false
            )
            recipe.exposure = 0.25
            let pipeline = ImagePipeline()
            let req = ImageRequest(photo: photo, root: root, recipe: recipe)
            let preview = try await pipeline.render(req, longEdge: 256)
            XCTAssertGreaterThan(preview.image.width, 0)
            XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 257)

            let outURL = directory.appendingPathComponent(name + "-libraw.tif")
            let size = try await pipeline.export(req, staging: outURL, options: ExportOptions(format: .tiff, longEdge: 256))
            try ImagePipeline.verifyExport(outURL, width: size.0, height: size.1, format: .tiff)
        }
        if checked == 0 {
            throw XCTSkip("No staged CC0 RAW samples available for LibRaw sensor and fallback checks")
        }
    }

    func testCorruptedCompressedRAWBitstreamIsDetectedEvenWithIntactContainerSize() throws {
        // Fujifilm X-S10 lossless compressed RAF has an entropy-coded CFA payload.
        // Flipping bytes deep inside the CFA payload keeps the container header and length intact,
        // exercising LibRaw's bitstream corruption gate.
        let source = try MoreRAWTests.sample("fuji_xs10_14bit_lossless.RAF")
        var bytes = try Data(contentsOf: source)
        let mid = bytes.count * 3 / 4
        for offset in 0..<4096 where mid + offset < bytes.count {
            bytes[mid + offset] ^= 0xFF
        }
        let corrupted = directory.appendingPathComponent("corrupted-bitstream.RAF")
        try bytes.write(to: corrupted)

        let probe = try LibRawRuntime.probe(url: corrupted, verifyBitstream: true)
        XCTAssertTrue(probe.isBitStreamCorrupted || !probe.succeeded, "LibRaw must detect corrupted compressed CFA bitstream")
        if probe.isBitStreamCorrupted {
            let root = StorageRoot(id: "corrupt", path: directory.path, bookmark: try AccessLease.bookmark(directory, readOnly: true), label: "corrupt")
            XCTAssertThrowsError(try ReferenceImporter.inspect(url: corrupted, root: root, rootURL: directory))
        }
    }
}
