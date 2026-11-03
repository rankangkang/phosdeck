import Foundation

/// A drag is valid only in the catalog/query context in which it started.
/// The path is the catalog identity; the query signature covers the source,
/// filters, held-result snapshot, sort and manual-order mode.
struct CollectionOrderingToken: Codable, Equatable, Hashable {
    let catalogPath: String
    let querySignature: String

    init(catalogPath: String, querySignature: String) {
        self.catalogPath = URL(fileURLWithPath: catalogPath).standardizedFileURL.path
        self.querySignature = querySignature
    }
}

private struct OrderingSmartRuleSignature: Codable, Equatable {
    let field: String
    let op: String
    let value: String
    let upper: String
}

private struct OrderingSmartSignature: Codable, Equatable {
    let all: Bool
    let source: String
    let conditions: [OrderingSmartRuleSignature]

    init(_ smart: SmartRules) {
        all = smart.all
        source = smart.source
        conditions = smart.conditions.map {
            OrderingSmartRuleSignature(field: $0.field.rawValue, op: $0.op.rawValue, value: $0.value, upper: $0.upper)
        }
    }
}

private struct OrderingQuerySignature: Codable {
    let scope: String
    let search: String
    let ratingThreshold: Int
    let ratingComparison: String
    let flags: [Int]
    let colorLabels: [Int]
    let keyword: String
    let metadata: LibraryMetadataFilter
    let sort: String
    let descending: Bool
    let snapshotID: String?
    let smart: OrderingSmartSignature?
    let invalidSmart: Bool
    let manualCollectionOrder: Bool
}

extension PhotoQuery {
    /// Stable semantic identity for scroll restoration and drag expiry. It
    /// deliberately excludes live object identity and UI-only filter section
    /// state while retaining every condition that changes query results/order.
    var orderingQuerySignature: String {
        let value = OrderingQuerySignature(scope: scope, search: search, ratingThreshold: ratingThreshold,
                                            ratingComparison: ratingComparison.rawValue, flags: flags.sorted(), colorLabels: colorLabels.sorted(), keyword: keyword,
                                            metadata: metadata, sort: sort.rawValue, descending: descending,
                                            snapshotID: snapshotID, smart: smart.map(OrderingSmartSignature.init),
                                            invalidSmart: invalidSmart, manualCollectionOrder: isManualCollectionOrder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let result = String(data: data, encoding: .utf8) else {
            // All fields above are Codable and this is unreachable in normal
            // operation; retain a deterministic fallback if that changes.
            return "invalid-query"
        }
        return result
    }

    /// Scroll restoration follows the logical browse query. Held snapshot IDs
    /// are session-owned temporary rows and are cloned when a history entry is
    /// preserved, so they must not split one source's scroll position into a
    /// new key. Drag expiry continues to use the full signature above.
    var scrollQuerySignature: String {
        var value = self
        value.snapshotID = nil
        return value.orderingQuerySignature
    }
}

struct CollectionOrderingDragPayload: Codable, Equatable {
    let ids: [String]
    let token: CollectionOrderingToken
}

/// UI bridge for the optional manual order of a regular collection.
///
/// The catalog owns the order and the undo transaction. The grid only reports
/// which real members are being moved and the real member they should precede;
/// this keeps filtered/virtualized pages from inventing a second order model.
struct CollectionOrdering {
    var enabled: Bool
    /// The current context token supplied by AppModel. An enabled bridge
    /// without a token rejects all drops because it cannot prove freshness.
    var token: CollectionOrderingToken?
    var reorder: (_ moving: [String], _ before: String?) -> Bool

    init(enabled: Bool = false, token: CollectionOrderingToken? = nil,
         reorder: @escaping (_ moving: [String], _ before: String?) -> Bool = { _, _ in false }) {
        self.enabled = enabled
        self.token = token
        self.reorder = reorder
    }
}
