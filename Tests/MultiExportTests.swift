import XCTest
@testable import Phosdeck

final class MultiExportTests: XCTestCase {
    private func photo(_ id: String, name: String = "IMG_001.ARW") -> Photo {
        Photo(id: id, rootID: "root", relativePath: name, identity: Data(), identityKey: id,
              captureDate: "2025:01:02 03:04:05", width: 40, height: 20)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multi-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func spec(_ id: String, title: String, subfolder: String, format: ExportFormat = .tiff,
                      naming: ExportNaming = ExportNaming(originalName: true)) -> ExportSpecification {
        ExportSpecification(id: id, title: title, subfolder: subfolder,
                            options: ExportOptions(format: format, naming: naming))
    }

    func testSingleAndBatchPlanFreezesOrderAndUsesIndependentFolders() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let photos = [photo("a", name: "A.ARW"), photo("b", name: "B.ARW")]
        let plan = try ExportBatchPlanner.plan(photos: photos,
                                               specifications: [spec("tiff", title: "留档", subfolder: "留档")],
                                               directory: root)
        XCTAssertTrue(plan.isReady)
        XCTAssertEqual(plan.requests.map(\.photo.id), ["a", "b"])
        XCTAssertEqual(plan.requests.map { $0.destination.lastPathComponent }, ["A.tif", "B.tif"])
        XCTAssertEqual(plan.requests.map { $0.destination.deletingLastPathComponent().lastPathComponent }, ["留档", "留档"])

        let two = try ExportBatchPlanner.plan(photos: photos, specifications: [
            spec("web", title: "网页", subfolder: "网页", format: .png),
            spec("archive", title: "归档", subfolder: "归档")
        ], directory: root)
        XCTAssertTrue(two.isReady)
        XCTAssertEqual(two.requests.count, 4)
        XCTAssertEqual(two.requests.map(\.specificationID), ["web", "web", "archive", "archive"])
        XCTAssertEqual(Set(two.requests.map { $0.destination.deletingLastPathComponent().lastPathComponent }), ["网页", "归档"])
    }

    func testSameNamesInSeparateFoldersAreAllowedButCrossSpecPathConflictsBlock() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let photos = [photo("a")]
        let separate = try ExportBatchPlanner.plan(photos: photos, specifications: [
            spec("one", title: "第一套", subfolder: "一"),
            spec("two", title: "第二套", subfolder: "二")
        ], directory: root)
        XCTAssertTrue(separate.issues.isEmpty)

        let conflict = try ExportBatchPlanner.plan(photos: photos, specifications: [
            spec("one", title: "第一套", subfolder: "同名"),
            spec("two", title: "第二套", subfolder: "同名")
        ], directory: root)
        XCTAssertTrue(conflict.issues.contains { $0.contains("相同子目录") })
        XCTAssertTrue(conflict.issues.contains { $0.contains("同一目标") })
        XCTAssertFalse(conflict.isReady)
    }

    func testExistingAndLateConflictsAreShownWithoutRenaming() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("网页")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: sub.appendingPathComponent("IMG_001.png"))
        let photos = [photo("a")]
        let first = try ExportBatchPlanner.plan(photos: photos,
                                                specifications: [spec("web", title: "网页", subfolder: "网页", format: .png)],
                                                directory: root)
        XCTAssertFalse(first.isReady)
        XCTAssertEqual(first.requests.first?.name.filename, "IMG_001.png")
        XCTAssertTrue(first.requests.first?.errors.contains { $0.contains("已有同名") } == true)

        let clean = try ExportBatchPlanner.plan(photos: photos,
                                                specifications: [spec("late", title: "稍后", subfolder: "稍后", format: .png)],
                                                directory: root)
        XCTAssertTrue(clean.isReady)
        try FileManager.default.createDirectory(at: clean.requests[0].destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("late conflict".utf8).write(to: clean.requests[0].destination)
        let rechecked = try ExportBatchPlanner.plan(photos: photos,
                                                    specifications: [spec("late", title: "稍后", subfolder: "稍后", format: .png)],
                                                    directory: root)
        XCTAssertFalse(rechecked.isReady)
        XCTAssertEqual(rechecked.requests[0].name.filename, clean.requests[0].name.filename)
        XCTAssertTrue(rechecked.requests[0].errors.contains { $0.contains("已有同名") })
    }

    func testUnicodeAndIllegalSubfoldersAreValidatedConservatively() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let photos = [photo("a")]
        let decomposed = "e\u{301}"
        let plan = try ExportBatchPlanner.plan(photos: photos, specifications: [
            spec("one", title: "一", subfolder: decomposed),
            spec("two", title: "二", subfolder: "é")
        ], directory: root)
        XCTAssertTrue(plan.issues.contains { $0.contains("相同子目录") })
        for invalid in ["", ".", "..", "a/b", "a:b", "CON", "name.", " name"] {
            XCTAssertThrowsError(try ExportBatchPlanner.plan(photos: photos,
                                                              specifications: [spec("invalid", title: "无效", subfolder: invalid)],
                                                              directory: root), invalid)
        }
    }

    func testSymlinkedSubfolderCannotEscapeAuthorizedParent() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let outside = try folder(); defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("越界")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ExportBatchPlanner.plan(photos: [photo("a")],
                                                          specifications: [spec("escape", title: "越界", subfolder: "越界")],
                                                          directory: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("超出所选父目标"))
        }
    }

    func testOriginalProtectionAndRetryIsolationUseFrozenRequests() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let photos = [photo("a", name: "IMG_001.ARW"), photo("b", name: "IMG_002.ARW")]
        let originalTarget = root.appendingPathComponent("保护").appendingPathComponent("IMG_001.tif")
        let plan = try ExportBatchPlanner.plan(photos: photos, specifications: [
            spec("one", title: "一", subfolder: "保护"),
            spec("two", title: "二", subfolder: "隔离", format: .png)
        ], directory: root, originalURLs: [originalTarget])
        XCTAssertFalse(plan.isReady)
        XCTAssertTrue(plan.requests[0].errors.contains { $0.contains("图库原片") })
        XCTAssertTrue(plan.requests[2].errors.isEmpty)
        XCTAssertEqual(plan.requests.map(\.id).count, Set(plan.requests.map(\.id)).count)
        XCTAssertEqual(plan.groups.map(\.requests.count), [2, 2])
        XCTAssertTrue(plan.groups[1].issues.isEmpty, "one spec's retry or conflict state must not leak into another")
    }
}
