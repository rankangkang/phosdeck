import AppKit
import GRDB
import MCP

struct MCPFolderPlan {
    struct Entry {
        let id = UUID().uuidString
        let difference: FolderDifference
        let locations: [String: FolderReviewFile]

        init(_ difference: FolderDifference) {
            self.difference = difference
            locations = Dictionary(uniqueKeysWithValues: difference.candidates.map { (UUID().uuidString, $0) })
        }
        var item: Value {
            let kind: String
            switch difference.kind {
            case .added: kind = "added"
            case .missing: kind = "missing"
            case .changed: kind = "changed"
            case .moved: kind = "moved"
            case .issue: kind = "issue"
            }
            return ["difference_id": .string(id), "kind": .string(kind), "name": .string(difference.path),
                    "can_apply": .bool(difference.kind != .issue), "restores_availability": .bool(difference.restoresAvailability),
                    "source_id": difference.source.map { .string($0.id) } ?? .null,
                    "location_count": .int(locations.count)]
        }
        var locationItems: [Value] {
            locations.sorted { $0.value.relativePath < $1.value.relativePath }.map {
                ["kind": "location", "difference_id": .string(id), "location_id": .string($0.key), "name": .string($0.value.relativePath)]
            }
        }
    }
    let preview: FolderReviewPreview
    let entries: [Entry]
}

extension AppMCPWorkflows {
    func librarySources(catalog: CatalogStore, session: String, arguments: Arguments) async throws -> MCPToolResult {
        let roots = model.roots, folders = model.folders, collections = model.collections
        let counts = model.collectionCounts, total = model.totalCount
        var special: [Value] = [["source_id": "all", "kind": "all", "name": .string(L10n.text("app.allPhotos", defaultValue: "All Photos")),
                                 "photo_count": .int(total), "available": true]]
        if let recent = model.lastImport {
            special.append(["source_id": .string(recent.scope), "kind": "recent_import",
                            "name": .string(L10n.text("app.lastImport", defaultValue: "Last Import")),
                            "photo_count": .int(recent.photoIDs.count), "available": true])
        }
        if model.isViewingRelated {
            special.append(["source_id": .string(model.scope), "kind": "related", "name": .string(model.browseSourceName),
                            "photo_count": .int(model.resultCount), "available": true])
        }
        let specialSources = special
        let data = try await Task.detached {
            let folderCounts = try catalog.database.read { db in
                var counts: [String: Int] = [:]
                let paths = try Row.fetchCursor(db, sql: "SELECT rootID, relativePath, count(*) AS count FROM photo WHERE deleted=0 GROUP BY rootID, relativePath")
                while let row = try paths.next() {
                    let root: String = row["rootID"], path: String = row["relativePath"], count: Int = row["count"]
                    counts[root, default: 0] += count
                    var key = "folder:" + root + ":"
                    for (index, part) in path.split(separator: "/").dropLast().enumerated() {
                        key += (index == 0 ? "" : "/") + part
                        counts[key, default: 0] += count
                    }
                }
                return counts
            }
            var items = specialSources
            for root in roots {
                let lease = try? FolderReviewService.access(FolderReviewScope(root: root), catalog: catalog)
                let available = lease != nil
                items.append(["source_id": .string(root.id), "root_id": .string(root.id), "kind": "root", "name": .string(root.label),
                              "photo_count": .int(folderCounts[root.id, default: 0]), "available": .bool(available)])
                for node in Self.flatten(folders[root.id] ?? []) {
                    items.append(["source_id": .string(node.id), "root_id": .string(root.id), "folder_id": .string(node.id),
                                  "kind": "folder", "name": .string(node.name), "relative_name": .string(node.relativePath),
                                  "photo_count": .int(folderCounts[node.id, default: 0]), "root_available": .bool(available)])
                }
            }
            items += collections.map { collection in
                let count = counts[collection.id] ?? -1
                return ["source_id": .string("collection:" + collection.id), "collection_id": .string(collection.id),
                        "name": .string(collection.name), "kind": collection.isSmart ? "smart_collection" : "collection",
                        "available": .bool(count >= 0), "photo_count": count < 0 ? .null : .int(count)]
            }
            return Self.page(items, arguments: arguments)
        }.value
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        return .init("Read the library sources.", data: data)
    }

    nonisolated static func flatten(_ nodes: [FolderNode]) -> [FolderNode] {
        nodes.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private func folderScope(_ arguments: Arguments) throws -> FolderReviewScope {
        guard let root = model.roots.first(where: { $0.id == arguments["root_id"]?.stringValue }) else {
            throw MCPToolProblem(code: "root_unavailable", summary: "The library root is no longer listed.", next: "Call list_library_sources.")
        }
        guard let folder = arguments["folder_id"]?.stringValue else { return FolderReviewScope(root: root) }
        guard let node = Self.flatten(model.folders[root.id] ?? []).first(where: { $0.id == folder }) else {
            throw MCPToolProblem.invalid("Use a folder_id listed under this root.")
        }
        return FolderReviewScope(root: root, directory: node.relativePath)
    }

    func writeLibrary(_ tool: AppMCPTool, catalog: CatalogStore, arguments: Arguments) throws -> MCPToolResult {
        switch tool {
        case .relocateRoot:
            let scope = try folderScope(arguments)
            let access = try grant(arguments["access_id"], purpose: .relocateRoot)
            return start(tool) { job in
                let (issues, refreshed) = try await self.model.performRootRelocation(scope.root, to: access.url, catalog: catalog)
                job.data["root_id"] = .string(scope.root.id)
                job.data["unverified_count"] = .int(issues.count)
                job.data["workspace_refreshed"] = .bool(refreshed)
                job.items = issues.map { ["source_id": .string($0.sourceID), "name": .string($0.name), "state": "identity_unverified"] }
                job.finish(issues.isEmpty ? .succeeded : .partial, "Verified the library at the selected location.", committed: "committed")
            }
        case .locateOriginal:
            let access = try grant(arguments["access_id"], purpose: .locateOriginal)
            let id = arguments["photo_id"]!.stringValue!
            let revision = arguments["source_revision"]!.intValue!
            return start(tool) { job in
                guard let photo = try catalog.photo(id), let source = try catalog.source(photo.sourceKey) else { throw MCPToolProblem.photoUnavailable }
                guard photo.revision == revision else { throw MCPToolProblem.stalePhoto }
                guard try FileIdentity.read(access.url) == access.identity else { throw Self.accessExpired }
                let (root, refreshed) = try await self.model.performOriginalRelocation(source, file: access.url, directory: access.directory?.url, catalog: catalog)
                job.data["photo_id"] = .string(id)
                job.data["source_id"] = .string(source.id)
                job.data["root_id"] = .string(root)
                job.data["workspace_refreshed"] = .bool(refreshed)
                job.finish(.succeeded, "Verified and relinked the original.", committed: "committed")
            }
        case .recentImport:
            let action = arguments["action"]!.stringValue!
            if action == "return" {
                model.returnFromImport()
            } else {
                guard model.lastImport != nil else {
                    throw MCPToolProblem(code: "recent_import_unavailable", summary: "This catalog has no recent import.", next: "Import photos first.")
                }
                model.showLastImport(startCulling: action == "start_culling")
                guard model.isViewingImport else { throw MCPToolProblem.failed }
            }
            return .init("Read the resulting browse position.", data: [
                "source_id": .string(model.scope), "result_count": .int(model.resultCount),
                "active_photo_id": model.activeID.map(Value.string) ?? .null, "selection_count": .int(model.selection.count)
            ])
        case .scanFolder:
            let scope = try folderScope(arguments)
            let recursive = arguments["include_subfolders"]?.boolValue ?? true
            return start(tool) { job in
                self.running(job, phase: "scanning")
                let (report, refreshed) = await self.model.performFolderScan(scope, includeSubfolders: recursive, catalog: catalog, recordItems: true)
                self.finishScan(job, report: report, refreshed: refreshed)
            }
        case .planFolder:
            let scope = try folderScope(arguments)
            let recursive = arguments["include_subfolders"]?.boolValue ?? true
            return start(tool) { job in
                self.running(job, phase: "scanning")
                let preview = try await FolderReviewService().preview(scope: scope, includeSubfolders: recursive, catalog: catalog)
                try Task.checkCancellation()
                let plan = MCPFolderPlan(preview: preview, entries: preview.entries.map(MCPFolderPlan.Entry.init))
                self.folderPlans[job.id] = plan
                job.data["plan_id"] = .string(job.id)
                job.data["checked_count"] = .int(preview.checkedCount)
                job.items = plan.entries.flatMap { [$0.item] + $0.locationItems }
                job.finish(.succeeded, "Prepared the folder review.")
            }
        case .applyFolder:
            guard let id = arguments["plan_id"]?.stringValue, let plan = folderPlans[id] else { throw Self.stalePlan }
            let ids = Set(arguments["difference_ids"]!.arrayValue!.compactMap(\.stringValue))
            let entries = plan.entries.filter { ids.contains($0.id) }
            guard ids.count == entries.count else { throw MCPToolProblem.invalid("Select differences from this plan.") }
            var locations: [String: String] = [:]
            for (differenceID, locationID) in arguments["locations"]?.objectValue ?? [:] {
                guard let entry = entries.first(where: { $0.id == differenceID }), let locationID = locationID.stringValue,
                      let file = entry.locations[locationID] else { throw MCPToolProblem.invalid("Use a location listed for the selected difference.") }
                locations[entry.difference.id] = file.relativePath
            }
            let selected = Set(entries.map(\.difference.id))
            if let issue = FolderReviewService.selectionIssue(plan.preview, selected: selected, locations: locations) {
                throw MCPToolProblem.invalid(issue)
            }
            return start(tool) { job in
                self.running(job, phase: "verifying")
                let result: FolderReviewResult
                do { result = try await FolderReviewService().apply(plan.preview, selected: selected, locations: locations, catalog: catalog) }
                catch is StaleFolderReview { throw Self.stalePlan }
                self.folderPlans[id] = nil
                var refreshed = true
                do { try self.model.completedFolderReview(result, catalog: catalog) }
                catch { self.model.error = error.localizedDescription; refreshed = false }
                job.data["applied_count"] = .int(result.appliedCount)
                job.data["relinked"] = .int(result.relinked)
                job.data["marked"] = .int(result.marked)
                job.data["workspace_refreshed"] = .bool(refreshed)
                job.items = entries.map { ["difference_id": .string($0.id), "state": "applied"] }
                job.items += result.importedPhotoIDs.sorted().map { ["photo_id": .string($0), "state": "indexed"] }
                job.finish(.succeeded, "Applied the selected folder changes.", committed: "committed")
            }
        default:
            return try writeImport(tool, catalog: catalog, arguments: arguments)
        }
    }

    static let stalePlan = MCPToolProblem(code: "stale_plan", summary: "This plan expired or its inputs changed.", next: "Refresh the source or folder review and select items again.")
}
