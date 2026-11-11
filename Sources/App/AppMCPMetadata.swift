import Foundation
import MCP

extension AppMCPWorkflows {
    func listKeywords(catalog: CatalogStore, session: String, arguments: Arguments) async throws -> MCPToolResult {
        let selected = model.selection
        let recent = model.recentKeywords
        let photoID = arguments["photo_id"]?.stringValue
        let search = KeywordSummary.key(arguments["search"]?.stringValue ?? "")
        let result = try await Task.detached {
            let observation = try catalog.keywordBrowser(selected: selected, photoID: photoID)
            let rows: [Value] = observation.keywords.filter { search.isEmpty || $0.keyword.contains(search) }.map {
                ["keyword_id": .string($0.keyword), "name": .string($0.name), "photo_count": .int($0.total), "selected_count": .int($0.selected)]
            }
            var data = Self.page(rows, arguments: arguments)
            data["recent_keywords"] = .array(recent.map(Value.string))
            if let photoID, let terms = observation.terms, let caption = observation.caption {
                data["photo_id"] = .string(photoID)
                data["photo_keywords"] = .array(terms.map(Value.string))
                data["caption"] = .string(caption)
            }
            return data
        }.value
        guard session == model.catalogSessionID else { throw MCPToolProblem.catalogChanged }
        return .init("Read the catalog keywords.", data: result)
    }
}

extension AppMCPTools {
    func editMetadata(_ tool: AppMCPTool, arguments args: [String: Value], model: AppModel, catalog: CatalogStore) throws -> MCPToolResult {
        let previousError = model.error
        switch tool {
        case .editKeywords:
            let ids = Set(args["photo_ids"]!.arrayValue!.compactMap(\.stringValue))
            guard ids.count <= 200 else { throw MCPToolProblem.invalid("Edit keywords on up to 200 photo versions per call.") }
            let names = try args["keywords"]!.arrayValue!.compactMap(\.stringValue).map(KeywordSummary.name)
            let previous = try model.savePhotoKeywords(names, ids: ids, adding: args["action"] == "add", closedUndo: true)
            let affected = Set(previous.keys)
            let read = { (catalog: CatalogStore) in try catalog.photoKeywords(ids: affected) }
            let after = try? read(catalog)
            let operation = after.flatMap { current in
                previous.isEmpty ? nil : recordUndo(before: previous, after: current, describe: { state in
                    ["affected_photo_ids": .array(state.keys.sorted().map(Value.string))]
                }, read: read)
            } ?? .null
            return Self.metadataResult("Saved photo keywords.", affected: affected, operation: operation,
                                       warning: after == nil || model.error != previousError)
        case .renameKeyword:
            let id = args["keyword_id"]!.stringValue!
            let previous = try catalog.keywordNameState(id)
            guard !previous.names.isEmpty else { throw MCPToolProblem.invalid("Use a current keyword_id from list_keywords.") }
            let replacement = try model.renameKeyword(previous, to: args["name"]!.stringValue!, catalogPath: catalog.fileURL.path, closedUndo: true)
            let keys = Set([previous.key, replacement.key])
            let read = { (catalog: CatalogStore) in
                try keys.map { try catalog.keywordNameState($0) }.filter { !$0.names.isEmpty }
            }
            func describe(_ states: [KeywordNameState]) -> [String: Value] {
                guard let state = states.first else { return [:] }
                return ["keyword_id": .string(state.key), "name": .string(state.name), "affected_version_count": .int(state.names.count)]
            }
            let changed = previous != replacement
            let operation = changed ? recordUndo(before: [previous], after: [replacement], describe: describe, read: read) : .null
            var data = describe([replacement])
            data["operation_id"] = operation
            data["commit_state"] = changed ? "committed" : "not_committed"
            return .init(changed ? "Renamed the keyword throughout the catalog." : "The keyword already has that name.", data: data,
                         warning: (try? read(catalog)) != [replacement] || model.error != previousError)
        case .caption:
            let expecting = args["expected_captions"]!.objectValue!.compactMapValues(\.stringValue)
            let text = try PhotoCaption.normalized(args["caption"]!.stringValue!)
            let previous = try model.savePhotoCaptions(text, ids: Set(expecting.keys), expecting: expecting, closedUndo: true)
            let affected = Set(previous.keys)
            let expected = previous.mapValues { _ in text }
            let read = { (catalog: CatalogStore) in try catalog.captions(ids: affected) }
            let operation = previous.isEmpty ? .null : recordUndo(before: previous, after: expected, describe: { state in
                ["affected_photo_ids": .array(state.keys.sorted().map(Value.string))]
            }, read: read)
            return Self.metadataResult("Saved photo captions.", affected: affected, operation: operation,
                                       warning: (try? read(catalog)) != expected || model.error != previousError,
                                       extra: ["caption": .string(text)])
        default: throw MCPToolProblem.failed
        }
    }

    private static func metadataResult(_ summary: String, affected: Set<String>, operation: Value,
                                       warning: Bool, extra: [String: Value] = [:]) -> MCPToolResult {
        var data = extra
        data["affected_photo_ids"] = .array(affected.sorted().map(Value.string))
        data["changed_count"] = .int(affected.count)
        data["commit_state"] = affected.isEmpty ? "not_committed" : "committed"
        data["operation_id"] = operation
        return .init(affected.isEmpty ? "The requested photo metadata is already saved." : summary, data: data, warning: warning)
    }
}
