import AppKit
import Foundation
import GRDB
import ImageIO
import MCP
import UniformTypeIdentifiers

struct MCPOutputSources {
    private struct Source {
        let id: String
        let version: PhotoVersionRevision
        let identity: Data
        let root: StorageRoot
        let relativePath: String
    }
    typealias Row = (photo: Photo, root: StorageRoot)
    private let sources: [Source]

    static func capture(_ arguments: [String: Value], catalog: CatalogStore) throws -> (Self, [Row]) {
        let ids = arguments["photo_ids"]!.arrayValue!.compactMap(\.stringValue)
        let revisions = arguments["expected_revisions"]!.objectValue!
        guard Set(ids) == Set(revisions.keys) else { throw MCPToolProblem.invalid("Supply expected_revisions for exactly the requested photo IDs.") }
        let rows = try read(ids, catalog: catalog)
        let sources = try rows.map { photo, root in
            let revision = revisions[photo.id]!.objectValue!
            let version = PhotoVersionRevision(source: revision["source_revision"]!.intValue!, recipe: revision["recipe_revision"]!.intValue!)
            guard version.matches(photo) else { throw MCPToolProblem.stalePhoto }
            return Source(id: photo.id, version: version, identity: photo.identity, root: root, relativePath: photo.relativePath)
        }
        return (Self(sources: sources), rows)
    }

    func resolve(_ catalog: CatalogStore, only id: String? = nil) throws -> [Row] {
        let targets = id.map { id in sources.filter { $0.id == id } } ?? sources
        guard !targets.isEmpty else { throw MCPToolProblem.photoUnavailable }
        let rows = try Self.read(targets.map(\.id), catalog: catalog)
        for (expected, row) in zip(targets, rows) {
            guard expected.version.matches(row.photo), expected.identity == row.photo.identity,
                  expected.relativePath == row.photo.relativePath, expected.root.id == row.root.id,
                  expected.root.path == row.root.path, expected.root.bookmark == row.root.bookmark else {
                throw MCPToolProblem.stalePhoto
            }
        }
        return rows
    }

    private static func read(_ ids: [String], catalog: CatalogStore) throws -> [Row] {
        try catalog.database.read { db in
            let photos = Dictionary(uniqueKeysWithValues: try CatalogStore.photos(ids: Set(ids), in: db).map { ($0.id, $0) })
            let roots = Dictionary(uniqueKeysWithValues: try StorageRoot.fetchAll(db).map { ($0.id, $0) })
            return try ids.map { id in
                guard let photo = photos[id] else { throw MCPToolProblem.photoUnavailable }
                guard photo.availability == "available", let root = roots[photo.rootID] else { throw MCPToolProblem.fileAccess }
                return (photo, root)
            }
        }
    }

    static func request(_ row: Row) throws -> ImageRequest {
        let recipe = try row.photo.recipe.map { try MCPDevelopPhoto.decode($0, for: row.photo) }
        return ImageRequest(photo: row.photo, root: row.root, recipe: recipe)
    }
}

enum MCPOutputSchema {
    static let boolean: Value = ["type": "boolean"]
    static func choice(_ choices: [String]) -> Value { ["type": "string", "enum": .array(choices.map(Value.string))] }
    static func integer(_ range: ClosedRange<Int>) -> Value {
        ["type": "integer", "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound)]
    }
    static func string(_ maximum: Int, minimum: Int = 1) -> Value {
        ["type": "string", "minLength": .int(minimum), "maxLength": .int(maximum)]
    }
}

enum MCPOutputImage {
    static func png(_ image: CGImage) throws -> String {
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw MCPToolProblem.failed }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw MCPToolProblem.failed }
        return bytes.base64EncodedString()
    }
}

extension MCPToolProblem {
    static let outputPlanExpired = Self(code: "output_plan_expired", summary: "The requested output plan is no longer available.",
                                        next: "Create a new plan using the current photo versions and authorized destination.")
    static let outputConflict = Self(code: "output_conflict", summary: "An output name or destination conflicts with an existing item.",
                                     next: "Review the names, then choose another name or authorize another destination.")
}

extension AppMCPWorkflows {
    func revealFile(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        let kind = args["kind"]!.stringValue!
        let fields = Set(["record_ids", "record_id", "member_id", "file_id", "photo_id"].filter { args[$0] != nil })
        let valid: Bool = switch kind {
        case "catalog": fields.isEmpty
        case "export": fields == ["record_ids"]
        case "merge": fields == ["file_id"] || fields == ["photo_id"]
        default: fields == ["record_id", "member_id"]
        }
        guard valid else { throw MCPToolProblem.invalid("Supply the IDs for the selected type of file.") }
        let master = args["file_id"]?.stringValue.flatMap { mergeFiles[$0] }
        if args["file_id"] != nil, master == nil { throw Self.missingOutput }
        return start(.revealFile) { job in
            let worker = Task.detached { try Self.finderTargets(args, kind: kind, master: master, catalog: catalog) }
            let (targets, requested) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard self.model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            guard !targets.isEmpty else { throw Self.missingOutput }
            self.activateFilesInFinder(targets.map(\.url))
            withExtendedLifetime(targets) {}
            job.data["revealed_count"] = .int(targets.count)
            job.data["unavailable_count"] = .int(requested - targets.count)
            job.items = targets.map { ["name": .string($0.url.lastPathComponent)] }
            job.finish(targets.count == requested ? .succeeded : .partial, "Revealed the available files in Finder.")
        }
    }

    private struct FinderTarget {
        let url: URL
        let lease: AccessLease?
    }

    nonisolated private static func finderTargets(_ args: Arguments, kind: String, master: MCPPublishedMerge?,
                                                  catalog: CatalogStore) throws -> ([FinderTarget], Int) {
        switch kind {
        case "catalog":
            guard FileManager.default.fileExists(atPath: catalog.fileURL.path) else { throw Self.missingOutput }
            return ([FinderTarget(url: catalog.fileURL, lease: nil)], 1)
        case "export":
            let ids = Set(args["record_ids"]!.arrayValue!.compactMap(\.stringValue))
            let history = try ExportService.history(catalog: catalog, ids: ids)
            let targets = history.logs.filter { $0.state == "completed" }.compactMap { log -> FinderTarget? in
                let destination = log.snapshot.destination
                guard let lease = try? AccessLease(bookmark: log.snapshot.targetBookmark),
                      (try? ExportService.authorizedFolder(for: destination, scope: lease.url)) != nil,
                      (try? FileIdentity.read(destination)) != nil else { return nil }
                return FinderTarget(url: destination, lease: lease)
            }
            return (targets, ids.count)
        case "merge":
            if let master {
                let lease = try AccessLease(bookmark: master.bookmark)
                guard try ExportService.authorizedFolder(for: master.url, scope: lease.url).path ==
                        lease.url.resolvingSymlinksInPath().standardizedFileURL.path,
                      try FileIdentity.read(master.url) == master.identity else { throw Self.missingOutput }
                return ([FinderTarget(url: master.url, lease: lease)], 1)
            }
            guard let id = args["photo_id"]?.stringValue, let photo = try catalog.photo(id), photo.details?.composite != nil,
                  photo.availability == "available", let root = try catalog.roots().first(where: { $0.id == photo.rootID }) else {
                throw Self.missingOutput
            }
            let lease = try AccessLease(bookmark: root.bookmark)
            let destination = lease.url.appendingPathComponent(photo.relativePath)
            guard (try? ExportService.authorizedFolder(for: destination, scope: lease.url)) != nil,
                  try FileIdentity.read(destination) == JSONDecoder().decode(FileIdentity.self, from: photo.identity) else {
                throw Self.missingOutput
            }
            return ([FinderTarget(url: destination, lease: lease)], 1)
        default:
            let recordID = args["record_id"]!.stringValue!, memberID = args["member_id"]!.stringValue!
            guard let plan = try CopyImporter.savedPlan(recordID, catalog: catalog),
                  let member = plan.groups.lazy.flatMap(\.members).first(where: { $0.id == memberID }),
                  let recovery = member.recovery, member.recoveryState != "deleted", let identity = member.targetIdentity else { throw Self.missingRecord }
            let lease = try AccessLease(bookmark: plan.targetBookmark)
            guard lease.url.resolvingSymlinksInPath() == plan.targetRoot,
                  recovery.deletingLastPathComponent() == plan.targetRoot.appendingPathComponent("ImportRecovery/\(plan.id)"),
                  recovery.resolvingSymlinksInPath() == recovery.standardizedFileURL,
                  try FileIdentity.read(recovery) == identity, try SafeFileWriter.sha256(recovery) == member.targetDigest else { throw Self.missingRecord }
            return ([FinderTarget(url: recovery, lease: lease)], 1)
        }
    }
}
