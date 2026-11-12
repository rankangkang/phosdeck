import Foundation
import GRDB
import MCP

struct MCPAutoStackPlan {
    let query: PhotoQuery
    let queryRevision: UUID
    let ids: Set<String>?
    let preview: AutoStackPreview
}

extension AppMCPWorkflows {
    func readOrganization(_ tool: AppMCPTool, catalog: CatalogStore, session: String, args: Arguments) async throws -> MCPToolResult {
        let query = model.query
        let revision = model.browseGeneration
        let worker = Task.detached {
            switch tool {
            case .getCollection: return try self.getCollection(catalog: catalog, args: args)
            case .listVersions: return try Self.listVersions(catalog: catalog, args: args)
            case .listEditRecords: return try Self.listEditRecords(catalog: catalog, args: args)
            case .listStacks: return try Self.listStacks(catalog: catalog, query: query, queryRevision: revision, args: args)
            case .listPairs: return try Self.listPairs(catalog: catalog, args: args)
            default: throw MCPToolProblem.failed
            }
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        guard model.catalogSessionID == session else { throw MCPToolProblem.catalogChanged }
        if tool == .listStacks, model.browseGeneration != revision || model.query != query { throw MCPToolProblem.staleQuery }
        return result
    }

    nonisolated static func physicalSourceID(_ args: Arguments, catalog: CatalogStore) throws -> String? {
        let id = args["source_id"]?.stringValue
        guard let photo = args["photo_id"]?.stringValue else { return id }
        guard id == nil else { throw MCPToolProblem.invalid("Use a photo_id or a source_id.") }
        guard let version = try catalog.photo(photo) else { throw MCPToolProblem.photoUnavailable }
        return version.sourceKey
    }

    nonisolated private static func listVersions(catalog: CatalogStore, args: Arguments) throws -> MCPToolResult {
        guard let id = try physicalSourceID(args, catalog: catalog) else {
            throw MCPToolProblem.invalid("Specify a photo_id or a physical source_id.")
        }
        guard let source = try catalog.source(id) else { throw MCPToolProblem.photoUnavailable }
        let versions = try catalog.versions(sourceID: id)
        var data = Self.page(versions.map { AppMCPTools.photo($0, badge: nil) }, arguments: args)
        data["source_id"] = .string(id)
        data["name"] = .string(source.name)
        data["source_status"] = .string(source.availability)
        data["pair_id"] = try catalog.pair(sourceID: id).map { .string($0.id) } ?? .null
        return .init("Read the original's edit versions.", data: data)
    }

    nonisolated private static func listEditRecords(catalog: CatalogStore, args: Arguments) throws -> MCPToolResult {
        let id = args["photo_id"]!.stringValue!
        let type = args["record_type"]?.stringValue ?? "history"
        let offset = args["offset"]?.intValue ?? 0, size = args["page_size"]?.intValue ?? 50
        return try catalog.database.read { db in
            guard let photo = try Row.fetchOne(db, sql: "SELECT revision, recipeRevision FROM photo WHERE id=? AND deleted=0", arguments: [id]) else {
                throw MCPToolProblem.photoUnavailable
            }
            var data: Arguments = ["photo_id": .string(id), "record_type": .string(type),
                                   "source_revision": .int(photo["revision"]), "recipe_revision": .int(photo["recipeRevision"])]
            let records: [Row], items: [Value]
            if type == "snapshots" {
                records = try Row.fetchAll(db, sql: "SELECT id,title,createdAt FROM editSnapshot WHERE photoID=? ORDER BY createdAt DESC,id LIMIT ? OFFSET ?",
                                           arguments: [id, size + 1, offset])
                items = records.prefix(size).map { snapshotRow(id: $0["id"], title: $0["title"], createdAt: $0["createdAt"]) }
                data["total"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM editSnapshot WHERE photoID=?", arguments: [id]).map(Value.int)
            } else {
                records = try Row.fetchAll(db, sql: "SELECT id,title,createdAt FROM editHistory WHERE photoID=? ORDER BY id DESC LIMIT ? OFFSET ?",
                                           arguments: [id, size + 1, offset])
                items = records.prefix(size).map {
                    ["history_id": .int($0["id"]), "title": .string($0["title"]), "created_at": .double($0["createdAt"])]
                }
            }
            data["items"] = .array(items)
            data["next_offset"] = records.count > size ? .int(offset + size) : .null
            return .init("Read saved edit records.", data: data)
        }
    }

    nonisolated private static func listStacks(catalog: CatalogStore, query: PhotoQuery, queryRevision: UUID, args: Arguments) throws -> MCPToolResult {
        let stackID = args["stack_id"]?.stringValue, photoID = args["photo_id"]?.stringValue
        guard stackID == nil || photoID == nil else { throw MCPToolProblem.invalid("Use a stack_id or a photo_id.") }
        return try catalog.database.read { db in
            let stacks = try CatalogStore.readStacks(db)
            let revision = organizationRevision(stacks)
            if let expected = args["stack_revision"], expected != revision { throw MCPToolProblem.staleStack }
            let selected = stackID.flatMap { id in stacks.first { $0.id == id } }
                ?? photoID.flatMap { id in stacks.first { $0.members.contains(id) } }
            if stackID != nil, selected == nil { throw MCPToolProblem.staleStack }
            let listed = (stackID == nil && photoID == nil) ? stacks : selected.map { [$0] } ?? []
            let matches = Set(try CatalogStore.resultIDs(db, query: query, within: listed.flatMap(\.members)))
            func summary(_ stack: PhotoStack) -> Value {
                ["stack_id": .string(stack.id), "cover_photo_id": .string(stack.members[0]), "member_count": .int(stack.members.count),
                 "matched_count": .int(stack.members.lazy.filter(matches.contains).count), "collapsed": .bool(stack.collapsed)]
            }
            var data = page(selected.map { stack in
                stack.members.enumerated().map { index, id in
                    ["photo_id": .string(id), "position": .int(index), "in_query": .bool(matches.contains(id))]
                }
            } ?? listed.map(summary), arguments: args)
            data["stack"] = selected.map(summary) ?? .null
            data["stack_revision"] = revision
            data["query_revision"] = .string(queryRevision.uuidString)
            return .init("Read the stack membership and scope.", data: data)
        }
    }
}

extension MCPToolProblem {
    static let staleStack = Self(code: "stale_stack", summary: "The stack membership or order changed.", next: "Read list_photo_stacks again.")
    static let staleOrganizationPlan = Self(code: "stale_plan", summary: "The reviewed plan is no longer current.", next: "Preview or verify the requested organization again.")
}

extension AppMCPTools {
    func writeVersions(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        if tool == .renameVersion {
            let id = args["photo_id"]!.stringValue!
            guard try catalog.photo(id)?.isVirtualCopy == true else { throw MCPToolProblem.invalid("Choose a live virtual copy.") }
            let change = try model.renamePhotoVersion(id: id, name: args["name"]!.stringValue!,
                                                      expecting: args["expected_name"]?.stringValue, closedUndo: true)
            let changed = change.previous != change.current
            func describe(_ name: String?) -> [String: Value] {
                ["photo_id": .string(id), "version_name": name.map(Value.string) ?? .null]
            }
            let operation = changed ? recordUndo(before: Optional(change.previous), after: Optional(change.current), describe: describe) {
                try $0.photo(id)?.copyName
            } : .null
            var data = describe(change.current)
            data["previous_name"] = .string(change.previous)
            data["operation_id"] = operation
            data["commit_state"] = changed ? "committed" : "not_committed"
            data["workspace_refreshed"] = .bool(change.refreshed)
            return .init("Saved the virtual copy name.", data: data, warning: !change.refreshed)
        }

        let ids = Set(args["photo_ids"]!.arrayValue!.compactMap(\.stringValue))
        guard try catalog.resultIDs(PhotoQuery(), within: ids) == ids else { throw MCPToolProblem.photoUnavailable }
        let revisions = args["expected_revisions"]?.objectValue?.mapValues { value -> PhotoVersionRevision in
            let fields = value.objectValue!
            return .init(source: fields["source_revision"]!.intValue!, recipe: fields["recipe_revision"]!.intValue!)
        }
        guard revisions.map({ Set($0.keys) == ids }) ?? true else {
            throw MCPToolProblem.invalid("Provide expected revisions for every requested photo_id.")
        }
        if tool == .removeVersions {
            let removed = try model.removePhotoVersions(ids, expecting: revisions ?? [:], closedUndo: true)
            return versionResult("Removed the selected edit versions from the catalog.", catalog: catalog, ids: ids, creating: false,
                                 previousStacks: removed.previousStacks, refreshed: removed.refreshed)
        }
        let history = args["history_id"]?.intValue.map(Int64.init), snapshot = args["snapshot_id"]?.stringValue
        guard history == nil || snapshot == nil else { throw MCPToolProblem.invalid("Use one history_id or snapshot_id.") }
        var saved: (recipe: EditRecipe, title: String)?
        if history != nil || snapshot != nil {
            guard ids.count == 1, let id = ids.first else { throw MCPToolProblem.invalid("A saved edit belongs to one photo version.") }
            guard let edit = try catalog.savedEdit(photoID: id, historyID: history, snapshotID: snapshot) else {
                throw MCPToolProblem.invalid("Select an edit record from this photo using list_edit_records.")
            }
            saved = (try JSONDecoder().decode(EditRecipe.self, from: edit.data), edit.title)
        }
        let created = try model.saveVirtualCopies(ids, savedEdit: saved, expecting: revisions ?? [:], closedUndo: true)
        // Copies are created in source-version ID order by CatalogStore.
        let items: [Value] = zip(ids.sorted(), created.copies).map { original, copy in
            ["photo_id": .string(copy.id), "copied_from_photo_id": .string(original), "source_id": .string(copy.sourceKey),
             "version_name": .string(copy.versionName), "source_revision": .int(copy.revision), "recipe_revision": .int(copy.recipeRevision)]
        }
        return versionResult("Created virtual copies.", catalog: catalog, ids: Set(created.copies.map(\.id)), creating: true,
                             previousStacks: created.previousStacks, refreshed: created.refreshed, extra: ["items": .array(items)])
    }

    private struct VersionPresence: Equatable {
        let active: Set<String>
        let stacks: [PhotoStack]
    }
    private func versionResult(_ summary: String, catalog: CatalogStore, ids: Set<String>, creating: Bool,
                               previousStacks: [PhotoStack], refreshed: Bool, extra: [String: Value] = [:]) -> MCPToolResult {
        let before = VersionPresence(active: creating ? [] : ids, stacks: previousStacks)
        func read(_ catalog: CatalogStore) throws -> VersionPresence {
            try catalog.database.read { db in
                let active = try CatalogStore.resultIDs(db, query: PhotoQuery(), within: ids.sorted())
                return VersionPresence(active: Set(active), stacks: try CatalogStore.readStacks(db))
            }
        }
        func describe(_ state: VersionPresence) -> [String: Value] {
            ["affected_photo_ids": .array(ids.sorted().map(Value.string)), "active_photo_ids": .array(state.active.sorted().map(Value.string))]
        }
        let after = try? read(catalog)
        let expected = creating ? ids : []
        let verified = after?.active == expected
        let operation = verified && after != nil ? recordUndo(before: before, after: after!, describe: describe, read: read) : .null
        var data = describe(after ?? VersionPresence(active: expected, stacks: [])).merging(extra) { _, new in new }
        data["operation_id"] = operation
        data["commit_state"] = "committed"
        data["workspace_refreshed"] = .bool(refreshed)
        return .init(summary, data: data, warning: !refreshed || !verified)
    }

    func writeStacks(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        if let revision = args["query_revision"]?.stringValue, revision != model.browseGeneration.uuidString {
            throw MCPToolProblem.staleQuery
        }
        if let revision = args["selection_revision"]?.stringValue, revision != model.selectionGeneration.uuidString {
            throw MCPToolProblem.staleSelection
        }
        if tool == .planStacks { return try planStacks(args, model: model, catalog: catalog) }
        if tool == .applyStacks {
            let id = args["plan_id"]!.stringValue!
            guard let plan = workflows.stackPlans[id], plan.queryRevision == model.browseGeneration, plan.query == model.query else {
                throw MCPToolProblem.staleOrganizationPlan
            }
            do {
                let result = try model.saveAutoStacks(plan.preview, query: plan.query, ids: plan.ids, closedUndo: true)
                workflows.stackPlans[id] = nil
                return stackResult("Applied the capture-time grouping plan.", result.change, refreshed: result.refreshed)
            } catch is StackStateChanged { throw MCPToolProblem.staleOrganizationPlan }
        }
        let stacks = try catalog.stacks()
        if let revision = args["stack_revision"], revision != organizationRevision(stacks) { throw MCPToolProblem.staleStack }
        let (action, title) = try stackAction(args, stacks: stacks, model: model, catalog: catalog)
        do {
            let result = try model.saveStackAction(action, title: title, expecting: stacks, closedUndo: true)
            return stackResult("Updated the display stacks.", result.change, refreshed: result.refreshed)
        } catch is StackStateChanged { throw MCPToolProblem.staleStack }
    }

    private func stackAction(_ args: [String: Value], stacks: [PhotoStack], model: AppModel, catalog: CatalogStore) throws -> (StackAction, String) {
        let action = args["action"]!.stringValue!
        let photo = args["photo_id"]?.stringValue
        let photos = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue)
        let stackIDs = args["stack_ids"]?.arrayValue?.compactMap(\.stringValue)
        let all = args["select_all"]?.boolValue == true
        let direction = args["direction"]?.stringValue
        if action == "collapse" || action == "expand" {
            guard photo == nil, photos == nil, direction == nil, all != (stackIDs != nil) else {
                throw MCPToolProblem.invalid("Specify stack_ids or select_all=true for stacks in the current query.")
            }
            let ids: Set<String>
            if let stackIDs {
                ids = Set(stackIDs)
                guard ids.isSubset(of: Set(stacks.map(\.id))) else { throw MCPToolProblem.staleStack }
            } else {
                let members = Set(try catalog.allResultIDs(model.query))
                ids = Set(stacks.filter { !members.isDisjoint(with: $0.members) }.map(\.id))
            }
            let collapse = action == "collapse"
            return (.collapse(ids, collapse), collapse ? L10n.text("app.collapseStack", defaultValue: "Collapse Stack")
                : L10n.text("app.expandStack", defaultValue: "Expand Stack"))
        }
        guard stackIDs == nil, args["select_all"] == nil, (action == "move") == (direction != nil) else {
            throw MCPToolProblem.invalid("Use direction with move and stack_ids only with collapse or expand.")
        }
        let targets = Set((photos ?? []) + (photo.map { [$0] } ?? []))
        guard !targets.isEmpty, try catalog.resultIDs(PhotoQuery(), within: targets) == targets else { throw MCPToolProblem.photoUnavailable }
        switch action {
        case "group":
            guard let photo, let photos, targets.count >= 2 else { throw MCPToolProblem.invalid("Group at least two versions and specify the cover photo_id.") }
            return (.group(top: photo, members: photos), L10n.text("app.createMergeStack", defaultValue: "Create / Merge Stack"))
        case "remove", "ungroup":
            guard photo == nil, photos != nil else { throw MCPToolProblem.invalid("Specify the photo_ids for this action.") }
            return action == "remove" ? (.remove(targets), L10n.text("app.removeStackMembers", defaultValue: "Remove Stack Members"))
                : (.ungroup(targets), L10n.text("app.unstack", defaultValue: "Unstack"))
        default:
            guard let photo, photos == nil, let stack = stacks.first(where: { $0.members.contains(photo) }) else {
                throw MCPToolProblem.invalid("Specify one stacked member by photo_id.")
            }
            switch action {
            case "cover": return (.cover(photo), L10n.text("app.setStackCover", defaultValue: "Set Stack Cover"))
            case "split":
                guard stack.members.first != photo else { throw MCPToolProblem.invalid("Split at a member after the cover.") }
                return (.split(photo), L10n.text("app.splitStack", defaultValue: "Split Stack"))
            default: return (.move(photo, direction == "earlier" ? -1 : 1), L10n.text("app.reorderStack", defaultValue: "Reorder Stack"))
            }
        }
    }

    private func planStacks(_ args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let query = model.query, revision = model.browseGeneration
        let explicit = args["photo_ids"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
        guard explicit == nil || args["scope"] == nil else { throw MCPToolProblem.invalid("Use scope or explicit photo_ids.") }
        let ids = explicit ?? (args["scope"] == "selection" ? model.selection : nil)
        let interval = args["interval_seconds"]!.number!
        return workflows.start(.planStacks) { [workflows] job in
            workflows.running(job, phase: "checking_capture_times")
            let worker = Task.detached {
                let inputs = try catalog.stackInputs(query: query, ids: ids)
                if let explicit, Set(inputs.map(\.id)) != explicit { throw MCPToolProblem.staleQuery }
                try Task.checkCancellation()
                return try CatalogStore.previewAutoStacks(inputs, gap: interval)
            }
            let preview = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard model.catalog === catalog, model.browseGeneration == revision, model.query == query else { throw MCPToolProblem.staleOrganizationPlan }
            workflows.stackPlans[job.id] = MCPAutoStackPlan(query: query, queryRevision: revision, ids: ids, preview: preview)
            let inputs = Dictionary(uniqueKeysWithValues: preview.inputs.map { ($0.id, $0) })
            job.items = preview.groups.enumerated().flatMap { groupIndex, group in
                group.enumerated().map { position, id in
                    ["group": .int(groupIndex + 1), "photo_id": .string(id), "position": .int(position), "group_size": .int(group.count),
                     "name": .string(URL(fileURLWithPath: inputs[id]!.name).lastPathComponent)]
                }
            }
            job.data["plan_id"] = .string(job.id)
            job.data["group_count"] = .int(preview.groups.count)
            job.data["photo_count"] = .int(preview.photoCount)
            job.data["skipped_existing_stack_count"] = .int(preview.skippedStacked)
            job.data["skipped_capture_time_count"] = .int(preview.skippedTime)
            job.finish(.succeeded, "Previewed automatic display stacks.")
        }
    }

    private func stackResult(_ summary: String, _ change: StackChange, refreshed: Bool) -> MCPToolResult {
        let before = Dictionary(uniqueKeysWithValues: change.previous.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: change.current.map { ($0.id, $0) })
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        let affected = changed.sorted()
        func describe(_ stacks: [PhotoStack]) -> [String: Value] {
            let live = Set(stacks.map(\.id))
            return ["changed_stack_ids": .array(affected.lazy.filter(live.contains).prefix(200).map(Value.string)),
                    "removed_stack_ids": .array(affected.lazy.filter { !live.contains($0) }.prefix(200).map(Value.string)),
                    "affected_count": .int(affected.count), "ids_truncated": .bool(affected.count > 200),
                    "stack_revision": organizationRevision(stacks)]
        }
        let operation = affected.isEmpty ? .null : recordUndo(before: change.previous, after: change.current, describe: describe) { try $0.stacks() }
        var data = describe(change.current)
        data["operation_id"] = operation
        data["commit_state"] = affected.isEmpty ? "not_committed" : "committed"
        data["workspace_refreshed"] = .bool(refreshed)
        return .init(summary, data: data, warning: !refreshed)
    }
}
