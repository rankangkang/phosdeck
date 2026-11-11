import CryptoKit
import Foundation
import GRDB
import MCP

extension AppMCPTool {
    var organizationDescription: (String, String)? {
        switch self {
        case .getCollection:
            ("Read the collection's saved rules or regular member order, and page its live versions. Pass collection_revision from an earlier page to detect structural changes.", "collection_id, source_id, name, kind, collection_revision, rules, items, total and next_offset")
        case .saveCollection:
            ("Create a regular collection with name, or rename an existing regular collection by collection_id. Optionally check its observed collection_revision.", "collection_id, source_id, name, photo_count and commit_state")
        case .deleteCollection, .deleteSmartCollection:
            ("Remove the specified collection of this type and keep its photos. Optionally check the collection_revision from get_collection.", "collection_id, removed, operation_id and commit_state")
        case .collectionMembers:
            ("Add or remove explicit photo_ids in a regular collection, or collect_results from the entire current query including folded and held matches. For collect_results supply an existing collection_id or a new name.", "collection_id, actual changed photo IDs and count, operation_id and commit_state")
        case .targetCollection:
            ("Set the regular collection used by Quick Collection. Omit collection_id to select the default Quick Collection.", "target_collection_id and quick_collection_id")
        case .quickCollection:
            ("Add or remove explicit photo_ids in the current Quick Collection target. Pass its collection_id from get_workspace, or omit it if no target exists. Adding to an unset target creates the default Quick Collection.", "target_collection_id, changed photo IDs and count, operation_id and commit_state")
        case .reorderCollection:
            ("Use set_manual_order with manual_order=true or false for the active regular collection. Use move with photo_ids and optional before_photo_id to move live members in their existing relative order, appending if the anchor is omitted.", "collection_id, manual_order, ordered member IDs or get_collection readback, operation_id and commit_state")
        case .saveSmartCollection:
            ("Create or edit a smart collection's name and rules. Provide rules with source_id, match (all or any), and conditions, or set from_current_query=true. For edits, omitted name or rules are retained.", "collection_id, source_id, name, rules, photo_count, operation_id and commit_state")
        case .listVersions:
            ("List saved versions of the same physical original. Pass a photo_id or a physical source_id from list_photos or list_raw_jpeg_pairs.", "source_id, name, items with version IDs and revisions, total and next_offset")
        case .listEditRecords:
            ("List saved history or snapshots of an explicit photo. Use a returned history_id or snapshot_id to create a virtual copy from that edit.", "photo_id, source_revision, recipe_revision, record_type, items and next_offset")
        case .createCopies:
            ("Create independent virtual copies of explicit photo_ids. With one target, pass either history_id or snapshot_id to use its saved edit. Optional expected_revisions must cover every target.", "items with new photo_id, copied_from_photo_id and shared source_id, operation_id and commit_state")
        case .renameVersion:
            ("Rename a virtual copy by photo_id. Optionally check expected_name. Use list_photo_versions to read its current name.", "photo_id, previous_name, version_name, operation_id and commit_state")
        case .removeVersions:
            ("Remove explicit edit versions from the catalog, retaining originals, edits, and related versions for undo. Optional expected_revisions must cover every target.", "affected_photo_ids, active_photo_ids, operation_id and commit_state")
        case .listStacks:
            ("List stack summaries and matching counts in the current query. Specify stack_id or a member photo_id to page the stack's full ordered membership.", "items, stack_revision, query_revision, and the selected stack if requested")
        case .editStack:
            ("Edit a display stack. group uses the cover photo_id and photo_ids, merging any existing groups. remove and ungroup take photo_ids; cover, split and move take one photo_id (move also takes direction). collapse and expand take stack_ids or select_all=true for current query stacks.", "changed_stack_ids, removed_stack_ids, stack_revision, operation_id and commit_state")
        case .planStacks:
            ("Preview automatic stacks by adjacent capture time. Choose the current query or selection, or pass explicit photo_ids within the query. Poll get_job to read ordered groups and skip counts.", "job_id, then plan_id, group and version counts and paged proposed members")
        case .applyStacks:
            ("Apply the reviewed plan_id from plan_auto_stacks after rechecking its query and inputs.", "created group IDs, stack_revision, operation_id and commit_state")
        case .listPairs:
            ("List existing RAW/JPEG pairs, or use listing=sources for physical endpoints. Pass photo_id or source_id to inspect that source's pair and get the partner's source_id for list_photo_versions.", "items with pair IDs or source IDs, formats, active version counts and next_offset")
        case .planPairs:
            ("Detect candidates in the catalog, query, selection or explicit photo_ids. Use action=verify with a detection plan_id and candidate_ids to verify selected files. Use action=manual with raw_source_id, jpeg_source_id and same_capture=true for an explicitly identified same-capture pair. Poll get_job for results.", "job_id, then plan_id and candidate or verified pair rows")
        case .applyPairs:
            ("Apply explicit candidate_ids from a verified plan_id. Rechecks RAW and JPEG identities, contents, and exclusive pairing before one catalog commit. Poll get_job.", "job_id, then pair IDs, operation_id and commit_state")
        case .unlinkPair:
            ("Unlink an existing RAW/JPEG pair by pair_id, preserving both sources and all edit versions.", "pair_id, removed, operation_id and commit_state")
        default: nil
        }
    }
}

func organizationRevision(_ value: some Encodable) -> Value {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let bytes = try? encoder.encode(value) else { return .null }
    return .string(Data(SHA256.hash(data: bytes)).base64EncodedString())
}

struct MCPCollectionState: Equatable, Encodable {
    let row: PhotoCollection
    let order: [String]?
    var revision: Value { organizationRevision(self) }

    static let unavailable = MCPToolProblem(code: "collection_unavailable", summary: "This collection no longer exists or has a different type.",
                                            next: "Read list_library_sources and get_collection.")
    static let stale = MCPToolProblem(code: "stale_collection", summary: "The collection changed.", next: "Read get_collection again before modifying it.")

    static func read(_ db: Database, id: String) throws -> Self? {
        guard let row = try PhotoCollection.fetchOne(db, key: id) else { return nil }
        let order = row.isSmart ? nil : try CatalogStore.readManualCollectionOrder(db, id: id)
        return Self(row: row, order: order)
    }
    static func read(_ catalog: CatalogStore, id: String) throws -> Self? {
        try catalog.database.read { try read($0, id: id) }
    }

    var info: [String: Value] {
        let rules = try? row.decodedRules()
        return ["collection_id": .string(row.id), "source_id": .string("collection:" + row.id), "name": .string(row.name),
                "kind": row.isSmart ? "smart_collection" : "collection", "collection_revision": revision,
                "rules": rules.map(Self.rulesValue) ?? .null, "rules_valid": .bool(!row.isSmart || rules != nil)]
    }

    static let rulesSchema: Value = [
        "type": "object", "additionalProperties": false, "required": ["conditions"],
        "properties": [
            "source_id": ["type": "string", "minLength": 1, "maxLength": 2048, "default": "all"],
            "match": ["enum": ["all", "any"], "default": "all"],
            "conditions": ["type": "array", "minItems": 1, "maxItems": 32, "items": [
                "type": "object", "additionalProperties": false, "required": ["field", "operator"],
                "properties": [
                    "field": ["enum": .array(SmartField.allCases.map { .string($0.rawValue) })],
                    "operator": ["enum": .array(Set(SmartField.allCases.flatMap { $0.operators.map(\.rawValue) }).sorted().map(Value.string))],
                    "value": ["type": "string", "maxLength": 512], "upper": ["type": "string", "maxLength": 512]
                ]
            ]]
        ]
    ]

    static func parseRules(_ value: Value) throws -> SmartRules {
        guard let values = value.objectValue, Set(values.keys).isSubset(of: ["source_id", "match", "conditions"]),
              let conditions = values["conditions"]?.arrayValue, (1...32).contains(conditions.count) else {
            throw MCPToolProblem.invalid("Provide a smart rule object with 1 to 32 conditions.")
        }
        let source = values["source_id"] ?? "all", match = values["match"] ?? "all"
        guard let id = source.stringValue, (1...2048).contains(id.count), !id.contains("\0"), match == "all" || match == "any" else {
            throw MCPToolProblem.invalid("Specify a source_id and match all or any.")
        }
        let rules = try conditions.map { condition -> SmartRule in
            guard let fields = condition.objectValue, Set(fields.keys).isSubset(of: ["field", "operator", "value", "upper"]),
                  let field = fields["field"]?.stringValue.flatMap(SmartField.init(rawValue:)),
                  let op = fields["operator"]?.stringValue.flatMap(SmartOperator.init(rawValue:)),
                  let text = (fields["value"] ?? "").stringValue, text.count <= 512, !text.contains("\0"),
                  let upper = (fields["upper"] ?? "").stringValue, upper.count <= 512, !upper.contains("\0") else {
                throw MCPToolProblem.invalid("Each condition needs a supported field and operator and values up to 512 characters.")
            }
            return SmartRule(field: field, op: op, value: text, upper: upper)
        }
        let result = SmartRules(all: match == "all", source: id, conditions: rules)
        try result.validate()
        return result
    }

    static func rulesValue(_ rules: SmartRules) -> Value {
        let conditions = rules.conditions.map { rule -> Value in
            var fields: [String: Value] = ["field": .string(rule.field.rawValue), "operator": .string(rule.op.rawValue)]
            if rule.op != .empty && rule.op != .notEmpty { fields["value"] = .string(rule.value) }
            if rule.op == .between { fields["upper"] = .string(rule.upper) }
            return .object(fields)
        }
        return ["source_id": .string(rules.source), "match": rules.all ? "all" : "any", "conditions": .array(conditions)]
    }
}

extension AppMCPWorkflows {
    nonisolated func getCollection(catalog: CatalogStore, args: Arguments) throws -> MCPToolResult {
        let id = args["collection_id"]!.stringValue!
        return try catalog.database.read { db in
            guard let collection = try MCPCollectionState.read(db, id: id) else { throw MCPCollectionState.unavailable }
            if let revision = args["collection_revision"], revision != collection.revision { throw MCPCollectionState.stale }
            var data = collection.info
            guard let query = try? collection.row.resultQuery(manualOrder: true) else {
                data.merge(Self.page([], arguments: args)) { _, new in new }
                return .init("The saved smart rules need review.", data: data, warning: true)
            }
            let (predicate, parameters) = query.predicate
            let from = " FROM " + query.relation + " WHERE " + predicate
            let count = try Int.fetchOne(db, sql: "SELECT count(*)" + from, arguments: parameters) ?? 0
            let offset = min(args["offset"]?.intValue ?? 0, count)
            let limit = args["page_size"]?.intValue ?? 50
            let ids = try String.fetchAll(db, sql: "SELECT photo.id" + from + " ORDER BY " + query.order + " LIMIT ? OFFSET ?",
                                          arguments: parameters + [limit, offset])
            data["items"] = .array(ids.map { ["photo_id": .string($0)] })
            data["total"] = .int(count)
            data["photo_count"] = .int(count)
            data["next_offset"] = offset + ids.count < count ? .int(offset + ids.count) : .null
            return .init("Read the collection and its current members.", data: data)
        }
    }
}

extension AppMCPTools {
    func writeCollections(_ tool: AppMCPTool, args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        if let revision = args["query_revision"]?.stringValue, revision != model.browseGeneration.uuidString {
            throw MCPToolProblem.staleQuery
        }
        let requestedID = args["collection_id"]?.stringValue
        let existing = try requestedID.map { id in
            guard let state = try MCPCollectionState.read(catalog, id: id) else { throw MCPCollectionState.unavailable }
            return state
        }
        if let expected = args["collection_revision"], expected != existing?.revision { throw MCPCollectionState.stale }
        if let existing, existing.row.isSmart != (tool == .saveSmartCollection || tool == .deleteSmartCollection) {
            throw MCPCollectionState.unavailable
        }
        let id = requestedID ?? UUID().uuidString
        let name = try args["name"]?.stringValue.map { value -> String in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw MCPToolProblem.invalid("Enter a nonempty collection name without control characters.")
            }
            return trimmed
        }

        switch tool {
        case .saveCollection:
            let changed = existing?.row.name != name!
            let refreshed = changed ? try model.saveRegularCollection(name: name!, id: id) : true
            let current = MCPCollectionState(row: PhotoCollection(id: id, name: name!), order: existing?.order ?? [])
            return collectionResult("Saved the regular collection.", catalog: catalog, before: existing, after: current,
                                    changed: changed, undoable: false, refreshed: refreshed)
        case .deleteCollection:
            let previous = existing!
            let refreshed = try model.setCollectionPresence(CollectionContents(collection: previous.row, members: previous.order!),
                                                            present: false, catalog: catalog, closedUndo: true)
            return collectionResult("Removed the collection and kept its photos.", catalog: catalog, before: previous, after: nil,
                                    changed: true, undoable: true, refreshed: refreshed, extra: ["removed": true])
        case .collectionMembers:
            let action = args["action"]!.stringValue!
            if action == "collect_results" {
                guard args["photo_ids"] == nil, (existing == nil) != (name == nil) else {
                    throw MCPToolProblem.invalid("Collect results into an existing collection_id or a new name.")
                }
                let (count, refreshed) = try model.saveResultsCollection(id, newName: name)
                let current = try? MCPCollectionState.read(catalog, id: id)
                let oldIDs = Set(existing?.order ?? [])
                let added = current?.order?.filter { !oldIDs.contains($0) }
                return collectionResult("Added the current query results to the collection.", catalog: catalog, before: existing, after: current,
                                        changed: count > 0 || existing == nil, undoable: false, refreshed: refreshed && current != nil,
                                        extra: ["collection_id": .string(id), "changed_count": .int(count),
                                                "changed_photo_ids": .array((added ?? []).prefix(200).map(Value.string)),
                                                "changed_ids_truncated": .bool(count > min(200, added?.count ?? 0))])
            }
            guard let previous = existing, name == nil, let ids = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue) else {
                throw MCPToolProblem.invalid("Specify a regular collection_id and explicit photo_ids.")
            }
            let (change, refreshed) = try model.saveCollectionMembership(Dictionary(uniqueKeysWithValues: ids.map { ($0, action == "add") }),
                                                                       collection: id, closedUndo: true)
            return membershipResult(catalog, row: previous.row, change: change, refreshed: refreshed)
        case .targetCollection:
            model.setTargetCollection(requestedID)
            return .init("Set the Quick Collection target.", data: Self.collectionTargets(model))
        case .quickCollection:
            guard requestedID == model.targetCollectionID else {
                throw MCPToolProblem(code: "stale_collection", summary: "The Quick Collection target changed.",
                                     next: "Use the current target_collection_id from get_workspace.", details: Self.collectionTargets(model))
            }
            let ids = Set(args["photo_ids"]!.arrayValue!.compactMap(\.stringValue))
            guard let (targetID, change, refreshed) = try model.changeQuickCollection(ids, add: args["action"] == "add", closedUndo: true) else {
                return .init("There is no membership to remove.", data: Self.collectionTargets(model).merging([
                    "changed_count": 0, "changed_photo_ids": [], "operation_id": .null, "commit_state": "not_committed"
                ]) { _, new in new })
            }
            let row = existing?.row ?? PhotoCollection(id: targetID, name: L10n.text("app.quickCollection", defaultValue: "Quick Collection"))
            return membershipResult(catalog, row: row, change: change, refreshed: refreshed, extra: Self.collectionTargets(model))
        case .reorderCollection:
            if args["action"] == "set_manual_order" {
                guard let enabled = args["manual_order"]?.boolValue, model.regularCollectionID == id,
                      args["photo_ids"] == nil, args["before_photo_id"] == nil else {
                    throw MCPToolProblem.invalid("Open the regular collection and specify manual_order.")
                }
                model.setManualCollectionOrder(enabled)
                return .init("Set the current collection's sort mode.", data: ["collection_id": .string(id), "manual_order": .bool(model.manualOrderEnabled)])
            }
            guard let ids = args["photo_ids"]?.arrayValue?.compactMap(\.stringValue), args["manual_order"] == nil else {
                throw MCPToolProblem.invalid("Specify the photo_ids to move.")
            }
            let anchor = args["before_photo_id"]?.stringValue
            let requested = Set(ids + (anchor.map { [$0] } ?? []))
            guard anchor.map({ !ids.contains($0) }) ?? true, requested.isSubset(of: Set(existing!.order!)) else {
                throw MCPToolProblem.invalid("Move existing members before a distinct member of the same collection.")
            }
            let query = model.regularCollectionID == id && model.manualOrderEnabled ? model.query : try existing!.row.resultQuery()
            guard try catalog.resultIDs(query, within: requested) == requested else { throw MCPToolProblem.staleQuery }
            let move = try model.moveCollectionMembers(id, moving: ids, before: anchor, closedUndo: true)
            return collectionResult("Reordered the regular collection.", catalog: catalog,
                                    before: .init(row: existing!.row, order: move.previous), after: .init(row: existing!.row, order: move.current),
                                    changed: move.previous != move.current, undoable: true, refreshed: move.refreshed,
                                    extra: ["ordered_photo_ids": .array(move.current.prefix(200).map(Value.string)), "order_truncated": .bool(move.current.count > 200)])
        case .saveSmartCollection:
            let fromQuery = args["from_current_query"]?.boolValue == true
            guard !fromQuery || args["rules"] == nil else { throw MCPToolProblem.invalid("Choose explicit rules or the current query.") }
            guard let title = name ?? existing?.row.name else { throw MCPToolProblem.invalid("Give the smart collection a name.") }
            let rules: SmartRules?
            do {
                if fromQuery { rules = try SmartRules.from(model.query) }
                else if let explicit = args["rules"] { rules = try MCPCollectionState.parseRules(explicit) }
                else { rules = nil }
                if let rules { try catalog.checkSmartSource(rules) }
            } catch let problem as MCPToolProblem { throw problem }
            catch { throw MCPToolProblem.invalid(error.localizedDescription) }
            let payload: Data?
            if let rules, (try? existing?.row.decodedRules()).map(MCPCollectionState.rulesValue) != MCPCollectionState.rulesValue(rules) {
                payload = try JSONEncoder().encode(rules)
            } else {
                payload = existing?.row.rules
            }
            guard let payload else {
                throw MCPToolProblem.invalid("Provide smart rules or use from_current_query.")
            }
            let current = PhotoCollection(id: id, name: title, rules: payload)
            let change = try model.changeSmartCollection(id: id, to: current, closedUndo: true)
            return collectionResult("Saved the smart collection.", catalog: catalog, before: existing, after: .init(row: current, order: nil),
                                    changed: change.previous != current, undoable: true, refreshed: change.refreshed)
        case .deleteSmartCollection:
            let change = try model.changeSmartCollection(id: id, to: nil, closedUndo: true)
            return collectionResult("Removed the smart collection and kept its photos.", catalog: catalog, before: existing, after: nil,
                                    changed: change.previous != nil, undoable: true, refreshed: change.refreshed, extra: ["removed": .bool(change.previous != nil)])
        default: throw MCPToolProblem.failed
        }
    }

    private static func collectionTargets(_ model: AppModel) -> [String: Value] {
        ["target_collection_id": model.targetCollectionID.map(Value.string) ?? .null,
         "quick_collection_id": model.quickCollectionID.map(Value.string) ?? .null]
    }

    private func membershipResult(_ catalog: CatalogStore, row: PhotoCollection, change: OrderedMembershipChange,
                                  refreshed: Bool, extra: [String: Value] = [:]) -> MCPToolResult {
        let data = extra.merging(["changed_count": .int(change.inverse.count),
                                  "changed_photo_ids": .array(change.inverse.keys.sorted().map(Value.string))]) { _, new in new }
        return collectionResult("Saved the collection membership.", catalog: catalog,
                                before: .init(row: row, order: change.previousOrder), after: .init(row: row, order: change.order),
                                changed: change.changed, undoable: true, refreshed: refreshed, extra: data)
    }

    private func collectionResult(_ summary: String, catalog: CatalogStore, before: MCPCollectionState?, after: MCPCollectionState?,
                                  changed: Bool, undoable: Bool, refreshed: Bool, extra: [String: Value] = [:]) -> MCPToolResult {
        let id = after?.row.id ?? before?.row.id ?? extra["collection_id"]!.stringValue!
        func describe(_ state: MCPCollectionState?) -> [String: Value] {
            var data = state?.info ?? ["collection_id": .string(id)]
            data["present"] = .bool(state != nil)
            return data
        }
        let operation = changed && undoable ? recordUndo(before: before, after: after, describe: describe) { try MCPCollectionState.read($0, id: id) } : .null
        var data = describe(after).merging(extra) { _, new in new }
        if let after, let count = try? catalog.collectionCount(after.row) { data["photo_count"] = .int(count) }
        data["operation_id"] = operation
        data["commit_state"] = changed ? "committed" : "not_committed"
        data["workspace_refreshed"] = .bool(refreshed)
        return .init(summary, data: data, warning: !refreshed)
    }
}
