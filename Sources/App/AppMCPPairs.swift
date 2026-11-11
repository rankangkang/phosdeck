import Foundation
import GRDB
import MCP

enum MCPPairPlan {
    case detected([String: PairCandidate])
    case verified([String: PairProposal])
}

extension AppMCPWorkflows {
    nonisolated static func listPairs(catalog: CatalogStore, args: Arguments) throws -> MCPToolResult {
        let selected = try physicalSourceID(args, catalog: catalog)
        let listing = args["listing"]?.stringValue ?? "pairs"
        return try catalog.database.read { db in
            let sources = try CatalogSource.order(Column("relativePath"), Column("id")).fetchAll(db)
            if let selected, !sources.contains(where: { $0.id == selected }) { throw MCPToolProblem.photoUnavailable }
            let counts = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT sourceID,count(*) AS n FROM photo WHERE deleted=0 GROUP BY sourceID").compactMap { row -> (String, Int)? in
                guard let id: String = row["sourceID"] else { return nil }
                return (id, row["n"])
            })
            let pairs = try RawJpegPair.order(Column("id")).fetchAll(db)
            var pairsBySource = [String: RawJpegPair]()
            for pair in pairs {
                pairsBySource[pair.rawSourceID] = pair
                pairsBySource[pair.jpegSourceID] = pair
            }
            func endpoint(_ source: CatalogSource) -> Value {
                var value = Self.pairSource(source)
                value["active_version_count"] = .int(counts[source.id, default: 0])
                value["pair_id"] = pairsBySource[source.id].map { .string($0.id) } ?? .null
                return .object(value)
            }
            let items: [Value]
            if listing == "sources" {
                items = sources.lazy.filter { $0.kind != nil && (selected == nil || selected == $0.id) }.map(endpoint)
            } else {
                let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                items = pairs.filter { pair in
                    selected == nil || selected == pair.rawSourceID || selected == pair.jpegSourceID
                }.map { pair in
                    ["pair_id": .string(pair.id), "raw": byID[pair.rawSourceID].map(endpoint) ?? .null,
                     "jpeg": byID[pair.jpegSourceID].map(endpoint) ?? .null]
                }
            }
            var data = page(items, arguments: args)
            data["listing"] = .string(listing)
            return .init("Read RAW/JPEG sources or saved pairs.", data: data)
        }
    }

    nonisolated static func pairSource(_ source: CatalogSource) -> Arguments {
        ["source_id": .string(source.id), "root_id": .string(source.rootID), "name": .string(source.name),
         "relative_name": .string(source.relativePath), "format": source.kind.map(Value.string) ?? .null,
         "source_revision": .int(source.revision), "source_status": .string(source.availability)]
    }

    nonisolated static func pairRow(_ pair: RawJpegPair) -> Value {
        ["pair_id": .string(pair.id), "raw_source_id": .string(pair.rawSourceID), "jpeg_source_id": .string(pair.jpegSourceID)]
    }
}

extension AppMCPTools {
    func writePairs(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        switch tool {
        case .planPairs: return try planPairs(args, model: model, catalog: catalog)
        case .applyPairs:
            let planID = args["plan_id"]!.stringValue!
            let ids = args["candidate_ids"]!.arrayValue!.compactMap(\.stringValue)
            guard case let .verified(verified)? = workflows.pairPlans[planID],
                  ids.allSatisfy({ verified[$0] != nil }) else { throw MCPToolProblem.staleOrganizationPlan }
            let proposals = ids.compactMap { verified[$0] }
            let endpoints = proposals.flatMap { [$0.raw.source.id, $0.jpeg.source.id] }
            guard Set(endpoints).count == endpoints.count else {
                throw MCPToolProblem.invalid("Each source can occur only once in the selected pairs.")
            }
            return workflows.start(tool) { [weak self, workflows] job in
                guard job.session == model.catalogSessionID, model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
                workflows.running(job, phase: "verifying_and_saving_pairs")
                let saved: (change: PairChange, refreshed: Bool)
                do { saved = try await model.savePairs(proposals, catalog: catalog, closedUndo: true) }
                catch is PairStateChanged { throw MCPToolProblem.staleOrganizationPlan }
                if workflows.pairPlans[planID] != nil {
                    var remaining = verified
                    for id in ids { remaining[id] = nil }
                    workflows.pairPlans[planID] = remaining.isEmpty ? nil : .verified(remaining)
                }
                let pairsByRaw = Dictionary(uniqueKeysWithValues: saved.change.current.map { ($0.rawSourceID, $0) })
                let pairs = proposals.compactMap { pairsByRaw[$0.raw.source.id] }
                let changed = saved.change.previous != saved.change.current
                let operation = model.catalog === catalog ? self?.pairUndo(saved.change) : nil
                job.items = zip(ids, pairs).map { id, pair in
                    .object((AppMCPWorkflows.pairRow(pair).objectValue ?? [:]).merging(["candidate_id": .string(id)]) { _, value in value })
                }
                job.data["operation_id"] = operation ?? .null
                job.data["changed_count"] = .int(saved.change.current.count - saved.change.previous.count)
                job.data["workspace_refreshed"] = .bool(saved.refreshed)
                job.finish(.succeeded, changed ? "Saved the verified RAW/JPEG pairs." : "The requested pairs were already present.",
                           committed: changed ? "committed" : "not_committed")
            }
        case .unlinkPair:
            let id = args["pair_id"]!.stringValue!
            let removed = try model.removePair(id, closedUndo: true)
            guard removed.change.previous != removed.change.current else {
                throw MCPToolProblem(code: "pair_unavailable", summary: "This pair is no longer saved.", next: "Read list_raw_jpeg_pairs.")
            }
            return .init("Removed the RAW/JPEG relationship and kept both sources.", data: [
                "pair_id": .string(id), "removed": true, "commit_state": "committed",
                "operation_id": pairUndo(removed.change), "workspace_refreshed": .bool(removed.refreshed)
            ], warning: !removed.refreshed)
        default: throw MCPToolProblem.failed
        }
    }

    private func pairUndo(_ change: PairChange) -> Value {
        let old = Dictionary(uniqueKeysWithValues: change.previous.map { ($0.id, $0) })
        let current = Dictionary(uniqueKeysWithValues: change.current.map { ($0.id, $0) })
        let affected = Set(old.keys).union(current.keys).filter { old[$0] != current[$0] }
        guard !affected.isEmpty else { return .null }
        return recordUndo(before: change.previous, after: change.current, describe: { pairs in
            let live = Set(pairs.map(\.id))
            return ["items": .array(pairs.filter { affected.contains($0.id) }.map(AppMCPWorkflows.pairRow)),
                    "removed_pair_ids": .array(affected.subtracting(live).sorted().map(Value.string))]
        }, read: { try $0.pairs() })
    }

    private func planPairs(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        switch args["action"]!.stringValue! {
        case "detect":
            guard args["plan_id"] == nil, args["candidate_ids"] == nil, args["raw_source_id"] == nil,
                  args["jpeg_source_id"] == nil, args["same_capture"] == nil else {
                throw MCPToolProblem.invalid("Use scope or explicit photo_ids to detect pair candidates.")
            }
            return try detectPairs(args, model: model, catalog: catalog)
        case "verify":
            guard args["scope"] == nil, args["photo_ids"] == nil, args["raw_source_id"] == nil, args["jpeg_source_id"] == nil,
                  args["same_capture"] == nil, args["query_revision"] == nil, args["selection_revision"] == nil,
                  let planID = args["plan_id"]?.stringValue, let ids = args["candidate_ids"]?.arrayValue?.compactMap(\.stringValue) else {
                throw MCPToolProblem.invalid("Use a detection plan_id and its selected candidate_ids.")
            }
            guard case let .detected(candidates)? = workflows.pairPlans[planID],
                  ids.allSatisfy({ candidates[$0].map { $0.issue == nil } ?? false }) else { throw MCPToolProblem.staleOrganizationPlan }
            return verifyPairs(ids.map { ($0, candidates[$0]!) }, model: model, catalog: catalog)
        default:
            guard args["plan_id"] == nil, args["candidate_ids"] == nil, args["scope"] == nil, args["photo_ids"] == nil,
                  args["query_revision"] == nil, args["selection_revision"] == nil, args["same_capture"] == true,
                  let raw = args["raw_source_id"]?.stringValue, let jpeg = args["jpeg_source_id"]?.stringValue, raw != jpeg else {
                throw MCPToolProblem.invalid("Specify one RAW source, one JPEG source and same_capture=true for a manual pair.")
            }
            return workflows.start(.planPairs) { [workflows] job in
                workflows.running(job, phase: "verifying_pair_files")
                let proposal = try await model.pairing.prepare(rawID: raw, jpegID: jpeg, catalog: catalog)
                try Task.checkCancellation()
                guard job.session == model.catalogSessionID, model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
                let verifiedID = UUID().uuidString
                workflows.pairPlans[job.id] = .verified([verifiedID: proposal])
                job.data["plan_id"] = .string(job.id)
                job.data["verified_count"] = 1
                job.items = [Self.verifiedPair(id: verifiedID, proposal: proposal,
                                              issue: RawJpegPairing.metadataConflict(proposal.raw.source, proposal.jpeg.source))]
                job.finish(.succeeded, "Verified the manual RAW/JPEG proposal.")
            }
        }
    }

    private func detectPairs(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let scope = args["scope"]?.stringValue ?? "catalog"
        let explicit = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue)
        guard explicit == nil || args["scope"] == nil else { throw MCPToolProblem.invalid("Use scope or explicit photo_ids.") }
        let revision = model.browseGeneration, query = model.query
        if let expected = args["query_revision"]?.stringValue, expected != revision.uuidString { throw MCPToolProblem.staleQuery }
        if let expected = args["selection_revision"]?.stringValue, expected != model.selectionGeneration.uuidString { throw MCPToolProblem.staleSelection }
        let ids = explicit ?? (scope == "selection" ? model.selection.sorted() : nil)
        return workflows.start(.planPairs) { [workflows] job in
            workflows.running(job, phase: "detecting_pairs")
            let sourceScope: Set<String>?
            if scope == "catalog", ids == nil { sourceScope = nil }
            else {
                let filter = scope == "query" ? query : PhotoQuery()
                let worker = Task.detached { try Self.pairSourceScope(catalog, query: filter, ids: ids) }
                let (sources, count) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                if let explicit, count != explicit.count { throw MCPToolProblem.photoUnavailable }
                sourceScope = sources
            }
            let candidates = try await model.pairing.detect(catalog: catalog, within: sourceScope)
            try Task.checkCancellation()
            guard job.session == model.catalogSessionID, model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            if scope == "query", model.query != query || model.browseGeneration != revision { throw MCPToolProblem.staleQuery }
            let entries = candidates.map { (UUID().uuidString, $0) }
            workflows.pairPlans[job.id] = .detected(Dictionary(uniqueKeysWithValues: entries))
            job.items = entries.map { id, candidate in
                ["candidate_id": .string(id), "can_verify": .bool(candidate.issue == nil),
                 "issue": candidate.issue.map(Value.string) ?? .null,
                 "sources": .array(candidate.sources.map { .object(AppMCPWorkflows.pairSource($0)) })]
            }
            job.data["plan_id"] = .string(job.id)
            job.data["eligible_count"] = .int(candidates.filter { $0.issue == nil }.count)
            job.finish(.succeeded, "Detected RAW/JPEG candidates for review.")
        }
    }

    nonisolated private static func pairSourceScope(_ catalog: CatalogStore, query: PhotoQuery, ids: [String]?) throws -> (Set<String>, Int) {
        let (predicate, bindings) = query.predicate
        var sql = "SELECT COALESCE(photo.sourceID,photo.id) FROM " + query.relation + " WHERE " + predicate
        var args = bindings
        if let ids {
            sql += " AND photo.id IN (SELECT value FROM json_each(?))"
            args += [String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)]
        }
        let rows = try catalog.database.read { try String.fetchAll($0, sql: sql, arguments: args) }
        return (Set(rows), rows.count)
    }

    private func verifyPairs(_ chosen: [(String, PairCandidate)], model: AppModel, catalog: CatalogStore) -> MCPToolResult {
        workflows.start(.planPairs) { [workflows] job in
            workflows.running(job, phase: "verifying_pair_files")
            var verified = [String: PairProposal]()
            let title = L10n.text("app.rawJPEGSourcePairing", defaultValue: "RAW/JPEG Source Pairing")
            workflows.progress(job, title: title, done: 0, total: chosen.count)
            for (index, entry) in chosen.enumerated() {
                try Task.checkCancellation()
                let (id, candidate) = entry
                do {
                    let proposal = try await model.pairing.prepare(candidate, catalog: catalog)
                    verified[id] = proposal
                    job.items.append(Self.verifiedPair(id: id, proposal: proposal))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    job.items.append(["candidate_id": .string(id), "state": "failed",
                                      "error_code": error is PairStateChanged ? "stale_plan" : "file_verification_failed"])
                }
                workflows.progress(job, title: title, done: index + 1, total: chosen.count)
            }
            try Task.checkCancellation()
            guard job.session == model.catalogSessionID, model.catalog === catalog else { throw MCPToolProblem.catalogChanged }
            job.data["verified_count"] = .int(verified.count)
            guard !verified.isEmpty else {
                job.finish(.failed, "None of the selected candidates could be verified.", error: "file_verification_failed")
                job.data["follow_up"] = "Read the candidate results and detect again after checking the originals."
                return
            }
            workflows.pairPlans[job.id] = .verified(verified)
            job.data["plan_id"] = .string(job.id)
            job.finish(verified.count == chosen.count ? .succeeded : .partial, "Verified the selected RAW/JPEG proposals.")
        }
    }

    private static func verifiedPair(id: String, proposal: PairProposal, issue: String? = nil) -> Value {
        ["candidate_id": .string(id), "state": "verified", "raw": .object(AppMCPWorkflows.pairSource(proposal.raw.source)),
         "jpeg": .object(AppMCPWorkflows.pairSource(proposal.jpeg.source)), "issue": issue.map(Value.string) ?? .null]
    }
}
