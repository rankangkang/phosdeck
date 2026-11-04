import XCTest
import AppKit
import SwiftUI
@testable import Phosdeck

final class CameraDiagnosticsTests: XCTestCase {
    func testSampleOutcomeKeepsUnverifiedSeparateAndPrioritizesFailures() throws {
        var photo = CameraDiagnosticReport.Photo(id: 1)
        XCTAssertEqual(photo.outcome, .skipped)
        photo.checks = [.init(id: "sensorMeasurements", verdict: .skipped, detail: "unverified")]
        XCTAssertEqual(photo.outcome, .skipped)
        photo.checks.append(.init(id: "decode", verdict: .passed, detail: "decoded"))
        XCTAssertEqual(photo.outcome, .passed)
        XCTAssertEqual(photo.checks.first?.verdict, .skipped)
        photo.checks.append(.init(id: "repeat", verdict: .warning, detail: "different"))
        XCTAssertEqual(photo.outcome, .warning)
        photo.checks.append(.init(id: "sourceIdentity", verdict: .failed, detail: "changed"))
        XCTAssertEqual(photo.outcome, .failed)
        let data = try JSONEncoder().encode(photo)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("outcome"))
    }

    @MainActor func testNativeDiagnosticEmptyResultAndFailureLayoutsInBothThemes() async throws {
        let url = try MoreRAWTests.sample("a7iii_12bit_compressed.ARW")
        let result = try await CameraDiagnostics().inspect(url, index: 1)
        XCTAssertEqual(result.photo.checks.first { $0.id == "decode" }?.verdict, .passed)
        var failure = CameraDiagnosticReport.Photo(id: 2, format: "ARW")
        failure.checks = [.init(id: "decode", verdict: .failed, detail: "Synthetic corrupt RAW fixture: no image data could be decoded.")]
        let failed = CameraDiagnosticResult(photo: failure, filename: "synthetic-corrupt-sample.ARW", rendered: nil, embedded: nil)
        for theme in [ColorScheme.light, .dark] {
            for (name, samples) in [("empty", [CameraDiagnosticResult]()), ("result", [result]), ("failed", [failed])] {
                var report = CameraDiagnosticReport.empty()
                report.photos = samples.map(\.photo); report.requestedFiles = samples.count; report.completed = !samples.isEmpty
                let host = NSHostingView(rootView: CameraDiagnosticsView(report: report, results: samples).preferredColorScheme(theme))
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, 920, accuracy: 1)
                XCTAssertEqual(host.fittingSize.height, 600, accuracy: 1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
                attachment.name = "camera-\(name)-\(theme == .dark ? "graphite" : "ivory")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

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
