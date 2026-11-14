import CoreGraphics
import Foundation
import GRDB
import MCP

struct MCPCullingReport {
    static let maximumPhotos = 1000
    static let defaultInterval = 10.0

    struct Request {
        let ids: [String]?
        let query: MCPIndependentPhotoQuery?
        let reference: String?
        let interval: Double
        let minimum: Double

        @MainActor init(_ args: [String: Value], model: AppModel) throws {
            ids = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue)
            reference = args["reference_photo_id"]?.stringValue
            guard (ids == nil) != (args["query"] == nil) else {
                throw MCPToolProblem.invalid("Supply exactly one of photo_ids or query to define the analysis range.")
            }
            guard reference == nil || args["interval_seconds"] == nil else {
                throw MCPToolProblem.invalid("interval_seconds is used for burst grouping. Omit it for a reference search.")
            }
            query = try args["query"]?.objectValue.map(MCPIndependentPhotoQuery.init)
            if let query { try MCPLibraryCriteria.validateSource(query.source, model: model) }
            interval = args["interval_seconds"]?.number ?? MCPCullingReport.defaultInterval
            minimum = args["minimum_similarity"]?.number ?? (reference == nil ? 0.93 : 0.8)
        }
    }

    struct Input: Sendable {
        let id: String
        let photo: Photo?
        let root: StorageRoot?
    }

    struct Snapshot: Sendable {
        let targets: [Input]
        let reference: Input?
        let revision: UInt64
    }

    final class CachedMetrics: NSObject, Sendable {
        let value: CullingMetrics
        init(_ value: CullingMetrics) { self.value = value }
    }

    enum Measurement {
        case scored(CullingMetrics)
        case unavailable(String)
    }

    let summary: [String: Value]
    let items: [Value]

    static func snapshot(_ request: Request, in catalog: CatalogStore) throws -> Snapshot {
        try catalog.database.read { db in
            try Task.checkCancellation()
            let ids: [String]
            if let query = try request.query?.resolve(in: db) {
                let (predicate, arguments) = query.predicate
                ids = try String.fetchAll(db, sql: "SELECT photo.id FROM " + query.relation + " WHERE " + predicate +
                                          " ORDER BY " + query.order + " LIMIT ?", arguments: arguments + [maximumPhotos + 1])
            } else {
                ids = request.ids ?? []
            }
            guard ids.count <= maximumPhotos else {
                throw MCPToolProblem(code: "culling_scope_too_large", summary: "The query matches more than \(maximumPhotos) versions.",
                                     next: "Narrow the date range or pass a smaller set of photo_ids.")
            }
            let allIDs = Set(ids + [request.reference].compactMap { $0 })
            let columns: [any SQLSelectable] = [.allColumns(excluding: ["recipe", "metadata"])]
            // Load only analysis/response metadata. Saved recipes can contain
            // large masks that have no bearing on the original's appearance.
            let photos = try Photo.filter(allIDs.contains(Column("id")) && Column("deleted") == false).select(columns).fetchAll(db)
            let roots = try StorageRoot.filter(Set(photos.map(\.rootID)).contains(Column("id"))).fetchAll(db)
            let photosByID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
            let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
            func input(_ id: String) -> Input {
                let photo = photosByID[id]
                return Input(id: id, photo: photo, root: photo.flatMap { rootsByID[$0.rootID] })
            }
            let reference = request.reference.map(input)
            let targets = ids.map(input).filter { target in
                guard let reference else { return true }
                return target.id != reference.id && (target.photo == nil || target.photo?.sourceKey != reference.photo?.sourceKey)
            }
            return Snapshot(targets: targets, reference: reference, revision: catalog.browseRevision)
        }
    }

    static func measure(_ input: Input, cache: NSCache<NSString, CachedMetrics>, pipeline: ImagePipeline) async throws -> Measurement {
        try Task.checkCancellation()
        guard let photo = input.photo else { return .unavailable(MCPToolProblem.photoUnavailable.code) }
        guard photo.availability == "available", let root = input.root else { return .unavailable(MCPToolProblem.fileAccess.code) }
        guard photo.supportsEditing else { return .unavailable(MCPToolProblem.unsupportedEdit.code) }
        let key = "\(photo.sourceKey):\(photo.revision):\(photo.identity.base64EncodedString()):\(photo.digest ?? "")" as NSString
        let request = ImageRequest(photo: photo, root: root, recipe: nil)
        do {
            if let existing = cache.object(forKey: key) {
                try pipeline.verifySource(request)
                return .scored(existing.value)
            }
            let image = try await pipeline.cullingThumbnail(request)
            guard let metrics = try CullingMetrics.measure(image) else { return .unavailable("no_visible_pixels") }
            cache.setObject(CachedMetrics(metrics), forKey: key)
            return .scored(metrics)
        } catch is CancellationError { throw CancellationError() }
        catch { return .unavailable((error as? MCPToolProblem)?.code ?? "culling_thumbnail_unavailable") }
    }

    private struct Timed {
        let photo: Photo
        let time: CaptureTime
        let metrics: CullingMetrics
        var domain: String { time.hasOffset ? "" : photo.rootID }
    }

    private static func burstGroups(_ targets: [Input], metrics: [String: CullingMetrics], request: Request) throws -> [[Timed]] {
        let timed = targets.compactMap { input -> Timed? in
            guard let photo = input.photo, let time = CaptureTime.parse(photo.captureDate), let value = metrics[input.id] else { return nil }
            return Timed(photo: photo, time: time, metrics: value)
        }.sorted {
            ($0.domain, $0.time.seconds, $0.photo.sourceKey, $0.photo.isVirtualCopy ? 1 : 0, $0.photo.id)
                < ($1.domain, $1.time.seconds, $1.photo.sourceKey, $1.photo.isVirtualCopy ? 1 : 0, $1.photo.id)
        }
        var seen = Set<String>()
        var groups: [[Timed]] = []
        var group: [Timed] = []
        for next in timed where seen.insert(next.photo.sourceKey).inserted {
            try Task.checkCancellation()
            if let first = group.first, let last = group.last, last.domain == next.domain,
               next.time.seconds - last.time.seconds <= request.interval,
               let similarity = first.metrics.similarity(to: next.metrics), similarity >= request.minimum {
                group.append(next)
            } else {
                if group.count > 1 { groups.append(group) }
                group = [next]
            }
        }
        if group.count > 1 { groups.append(group) }
        return groups
    }

    static func report(_ input: Snapshot, request: Request, metrics: [String: CullingMetrics],
                       failures: [String: String], reference: CullingMetrics?) throws -> Self {
        var base: [String: [String: Value]] = [:], unavailable: [Value] = []
        for target in input.targets {
            var row = target.photo.map(MCPDevelopPhoto.revisions) ?? ["photo_id": .string(target.id)]
            if let photo = target.photo {
                row["name"] = .string(photo.name)
                row["version_name"] = .string(photo.versionName)
                row["source_id"] = .string(photo.sourceKey)
                row["flag"] = .int(photo.flag)
                row["capture_time"] = photo.captureDate.map(Value.string) ?? .null
            }
            if let error = failures[target.id] {
                row["state"] = "unavailable"
                row["error_code"] = .string(error)
                unavailable.append(.object(row))
                continue
            }
            let value = metrics[target.id]!
            row["state"] = "analyzed"
            row["sharpness"] = value.sharpness.map(Value.double) ?? .null
            row["highlight_clip_fraction"] = .double(value.highlightClipFraction)
            row["shadow_clip_fraction"] = .double(value.shadowClipFraction)
            base[target.id] = row
        }
        var summary: [String: Value] = [
            "mode": reference == nil ? "bursts" : "similar",
            "analysis_basis": "original_thumbnail", "thumbnail_long_edge": .int(CullingMetrics.longEdge),
            "minimum_similarity": .double(request.minimum), "analyzed_count": .int(metrics.count),
            "unavailable_count": .int(failures.count), "candidate_count": .int(input.targets.count)
        ]
        if let reference {
            let matches = metrics.compactMap { id, candidate -> (String, Double)? in
                guard let similarity = reference.similarity(to: candidate), similarity >= request.minimum else { return nil }
                return (id, similarity)
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            summary["reference_photo"] = input.reference?.photo.map { .object(MCPDevelopPhoto.revisions($0)) } ?? .null
            summary["match_count"] = .int(matches.count)
            let items = matches.map { id, score in
                var row = base[id]!
                row["similarity"] = .double(score)
                return Value.object(row)
            }
            return Self(summary: summary, items: items + unavailable)
        }

        let groups = try burstGroups(input.targets, metrics: metrics, request: request)
        var groupedIDs = Set<String>()
        var items: [Value] = []
        for (index, group) in groups.enumerated() {
            let ranked = group.sorted {
                let first = $0.metrics.sharpness ?? -1, second = $1.metrics.sharpness ?? -1
                if first != second { return first > second }
                return ($0.time.seconds, $0.photo.id) < ($1.time.seconds, $1.photo.id)
            }
            let recommendation = ranked.first.flatMap { $0.metrics.sharpness == nil ? nil : $0.photo.id }
            for (rank, member) in ranked.enumerated() {
                var row = base[member.photo.id]!
                row["group_number"] = .int(1 + index)
                row["rank"] = member.metrics.sharpness == nil ? .null : .int(1 + rank)
                row["recommended"] = .bool(member.photo.id == recommendation)
                row["group_similarity"] = group[0].metrics.similarity(to: member.metrics).map(Value.double) ?? .null
                items.append(.object(row))
                groupedIDs.insert(member.photo.id)
            }
        }
        for target in input.targets where !groupedIDs.contains(target.id) {
            guard var row = base[target.id] else { continue }
            row["group_number"] = .null
            row["rank"] = .null
            row["recommended"] = false
            items.append(.object(row))
        }
        summary["group_count"] = .int(groups.count)
        summary["grouped_count"] = .int(groupedIDs.count)
        summary["interval_seconds"] = .double(request.interval)
        return Self(summary: summary, items: items + unavailable)
    }
}

extension AppMCPWorkflows {
    func startCulling(_ args: Arguments, catalog: CatalogStore) throws -> MCPToolResult {
        guard cullingJob == nil else { throw MCPToolProblem.busy }
        let request = try MCPCullingReport.Request(args, model: model)
        let job = Job(tool: .cullPhotos, session: model.catalogSessionID)
        let pipeline = cullingPipeline, cache = cullingCache
        cache.countLimit = 2000
        remember(job)
        cullingJob = job
        cullingTask = Task { [self, model] in
            defer { cullingTask = nil; cullingJob = nil }
            running(job, phase: "analyzing_original_thumbnails")
            let worker = Task.detached(priority: .utility) {
                let input = try MCPCullingReport.snapshot(request, in: catalog)
                let total = input.targets.count + (input.reference == nil ? 0 : 1)
                func progress(_ done: Int) async {
                    await MainActor.run { job.progress = TaskProgress(title: "Analyze Photo Culling", done: done, total: total) }
                }
                var reference: CullingMetrics?
                if let seed = input.reference {
                    switch try await MCPCullingReport.measure(seed, cache: cache, pipeline: pipeline) {
                    case .scored(let value) where value.hasSignature: reference = value
                    default:
                        throw MCPToolProblem(code: "culling_reference_unavailable", summary: "The reference has no usable visual signature.",
                                             next: "Check the original or choose a different reference.").forPhoto(seed.id)
                    }
                }
                var metrics: [String: CullingMetrics] = [:], failures: [String: String] = [:]
                for (index, target) in input.targets.enumerated() {
                    await progress(index + (reference == nil ? 0 : 1))
                    switch try await MCPCullingReport.measure(target, cache: cache, pipeline: pipeline) {
                    case .scored(let value): metrics[target.id] = value
                    case .unavailable(let code): failures[target.id] = code
                    }
                }
                try Task.checkCancellation()
                let report = try MCPCullingReport.report(input, request: request, metrics: metrics, failures: failures, reference: reference)
                await progress(total)
                return (report, input.revision)
            }
            do {
                let (report, revision) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                let current = try await catalog.database.read { _ in catalog.browseRevision }
                try Task.checkCancellation()
                guard model.catalog === catalog, model.catalogSessionID == job.session else { throw MCPToolProblem.catalogChanged }
                guard current == revision, request.query?.isCurrent(in: model) != false else {
                    throw MCPToolProblem(code: "stale_culling_report", summary: "Catalog rows changed during analysis.",
                                         next: "Run the analysis again to obtain current results.")
                }
                job.data.merge(report.summary) { _, value in value }
                job.items = report.items
                let failed = report.summary["unavailable_count"]?.intValue ?? 0
                let analyzed = report.summary["analyzed_count"]?.intValue ?? 0
                if failed == 0 {
                    job.finish(.succeeded, "Analyzed the requested photos.")
                } else if analyzed > 0 {
                    job.finish(.partial, "Some photos could not be analyzed.")
                } else {
                    job.finish(.failed, "No photos could be analyzed.", error: "culling_unavailable")
                }
            } catch is CancellationError {
                job.finish(.cancelled, "The photo analysis was cancelled.")
            } catch let problem as MCPToolProblem {
                fail(job, with: problem)
            } catch {
                job.finish(.failed, MCPToolProblem.failed.summary, error: MCPToolProblem.failed.code)
            }
        }
        return result(job)
    }
}
