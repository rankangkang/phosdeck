import XCTest
@testable import Phosdeck

final class CameraDiagnosticsTests: XCTestCase {
    func testPublicRAWIsCheckedWithoutChangingSourceOrLeakingPath() async throws {
        let url = try MoreRAWTests.sample("a7iii_12bit_compressed.ARW")
        let before = try SafeFileWriter.sha256(url)
        let result = try await CameraDiagnostics().inspect(url,index: 1)
        XCTAssertEqual(result.photo.checks.first?.verdict,.passed)
        XCTAssertEqual(result.photo.checks.first { $0.id == "repeat" }?.verdict,.passed)
        XCTAssertEqual(result.photo.checks.first { $0.id == "afterDraft" }?.verdict,.passed)
        XCTAssertEqual(result.photo.checks.first { $0.id == "sixteenBit" }?.verdict,.passed)
        XCTAssertEqual(result.photo.sourceDigest,before)
        XCTAssertEqual(try SafeFileWriter.sha256(url),before)
        var report = CameraDiagnosticReport.empty(); report.photos = [result.photo]
        let json = String(decoding: try JSONEncoder().encode(report),as: UTF8.self)
        XCTAssertFalse(json.contains(url.path)); XCTAssertFalse(json.contains(url.lastPathComponent))
        XCTAssertEqual(result.photo.compression,"unknown"); XCTAssertNil(result.photo.sensorBits)
    }
    func testAppleDNGRefusalIsPreserved() async throws {
        let url = try MoreRAWTests.sample("iphone12pro_8bit_ljpeg.DNG")
        let result = try await CameraDiagnostics().inspect(url,index: 1)
        XCTAssertEqual(result.photo.checks.first?.verdict,.failed)
        XCTAssertTrue(result.photo.checks.first?.detail.contains("Apple DNG") == true)
        XCTAssertNil(result.rendered)
    }
    func testCorruptFileReportsFailureAndSelectionDoesNotRecurseOrFollowLinks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("private-name.ARW")
        try Data([0,1,2]).write(to: file)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("alias.ARW"),withDestinationURL: file)
        let child = folder.appendingPathComponent("child"); try FileManager.default.createDirectory(at: child,withIntermediateDirectories: false)
        try Data([0]).write(to: child.appendingPathComponent("nested.ARW"))
        let files = try await CameraDiagnostics.files(in: folder)
        XCTAssertEqual(files,[file])
        let result = try await CameraDiagnostics().inspect(file,index: 1)
        XCTAssertEqual(result.photo.checks.first?.verdict,.failed)
        XCTAssertFalse(result.photo.checks.first?.detail.contains("private-name") == true)
        XCTAssertNil(result.rendered)
        var report = CameraDiagnosticReport.empty(); report.photos = [result.photo]
        let name = try await CameraDiagnostics.save(report,in: folder)
        let saved = try Data(contentsOf: folder.appendingPathComponent(name))
        XCTAssertEqual(try JSONDecoder().decode(CameraDiagnosticReport.self,from: saved).photos.count,1)
        XCTAssertEqual(try Data(contentsOf: file),Data([0,1,2]))
    }
}
