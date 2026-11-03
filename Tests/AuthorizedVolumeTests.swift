import XCTest
import Darwin
@testable import Phosdeck

/// Real ENOSPC on an explicitly authorized small disposable disk IMAGE only.
final class AuthorizedVolumeTests: XCTestCase {
    struct Request: Codable { let bookmark: Data; let path: String }
    func testDiskFullDuringCopyCanResume() async throws {
        do { try await runDiskFullTest() }
        catch let skipped as XCTSkip { throw skipped }
        catch { XCTFail("Disk image validation: " + error.localizedDescription) }
    }
    private func runDiskFullTest() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OhMyLRC/VolumeValidation")
        let requestURL = support.appendingPathComponent("request.json")
        guard FileManager.default.fileExists(atPath: requestURL.path) else { throw XCTSkip("No authorized disposable disk-image request") }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestURL))
        let lease = try AccessLease(bookmark: request.bookmark)
        defer { withExtendedLifetime(lease) {} }
        guard lease.url.path == request.path, lease.url.lastPathComponent == "OMLRC-Fault-Test",
              let capacity = try lease.url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity,
              capacity <= 256 * 1024 * 1024 else { throw LRCError("Fault test refuses any volume except the small named disk image") }
        let run = support.appendingPathComponent("run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: requestURL, to: run.appendingPathComponent("private-request.json"))
        let fixture = ImportTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let image = fixture.source.appendingPathComponent("A.jpg"); try fixture.image(image)
        let digest = try SafeFileWriter.sha256(image)
        let target = lease.url.appendingPathComponent("fault-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let canary = target.appendingPathComponent("existing.txt")
        try SafeFileWriter.write(Data("must survive full volume".utf8), to: canary)
        let filler = target.appendingPathComponent("disposable-fill.bin")
        defer { try? FileManager.default.removeItem(at: filler) }
        let plan = try await ImportPlanner().plan(source: fixture.source, target: target, layout: .flat, policy: .uniqueName, skipIdentical: true, dateOverride: nil, confirmSidecars: false, catalog: fixture.catalog)
        let stopped = await CopyImporter(checkpoint: { point in
            if point == "stagingCreated" { try Self.fillUntilENOSPC(filler) }
        }).run(plan, catalog: fixture.catalog) { _ in }
        print("VOLUME stopped: \(stopped.state) \(stopped.omitted) \(stopped.groups.first?.diagnostic ?? "")")
        XCTAssertEqual(stopped.state, "needsReview")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("A.jpg").path))
        XCTAssertEqual(try fixture.catalog.photoCount(), 0)
        XCTAssertEqual(try SafeFileWriter.sha256(image), digest)
        XCTAssertEqual(try String(contentsOf: canary, encoding: .utf8), "must survive full volume")
        let failure = stopped.groups.first?.diagnostic ?? stopped.omitted.joined(separator: ";")
        XCTAssertTrue(failure.contains("space") || failure.contains("空间") || failure.contains("full"), failure)
        try FileManager.default.removeItem(at: filler)
        var resumed = try XCTUnwrap(CopyImporter.savedPlans(catalog: fixture.catalog).first)
        resumed.groups[0].state = "planned"
        let completed = await CopyImporter().run(resumed, catalog: fixture.catalog) { _ in }
        XCTAssertEqual(completed.state, "completed", completed.groups[0].diagnostic ?? "")
        XCTAssertEqual(try SafeFileWriter.sha256(target.appendingPathComponent("A.jpg")), digest)
        XCTAssertEqual(try fixture.catalog.photoCount(), 1)
        let report: [String: Any] = ["volumeCapacity": capacity, "failure": failure, "resumed": completed.state, "sourceUnchanged": true, "canaryUnchanged": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: run.appendingPathComponent("report.json"))
        print("VOLUME_REPORT " + run.path)
    }
    static func fillUntilENOSPC(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw SafeFileWriter.posix("create disposable filler") }
        defer { close(fd) }
        let data = [UInt8](repeating: 0x55, count: 4096)
        while true {
            let result = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
            if result < 0 {
                guard errno == ENOSPC else { throw SafeFileWriter.posix("fill disposable image") }
                return
            }
        }
    }
}
