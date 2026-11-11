import Foundation
import GRDB

// Field/operator semantics adapted from LightCraft 4f0b110 catalog/rules.rs,
// cmd/library.rs and the rules editor (MIT; see third-party notice).
enum SmartField: String, Codable, CaseIterable, Identifiable {
    case filename, rating, flag, colorLabel, keyword, camera, lens, iso, captureDate, virtualCopy, copyName
    var id:String { rawValue }
    var title:String {
        switch self {
        case .filename:return L10n.text("app.filename", defaultValue: "Filename"); case .rating:return L10n.text("app.rating_415", defaultValue: "Rating"); case .flag:return L10n.text("app.pickFlag", defaultValue: "Pick Flag")
        case .colorLabel:return L10n.text("app.colorLabel", defaultValue: "Color Label")
        case .keyword:return L10n.text("app.keywords", defaultValue: "Keywords"); case .camera:return L10n.text("app.camera", defaultValue: "Camera"); case .lens:return L10n.text("app.lens", defaultValue: "Lens")
        case .iso:return "ISO"; case .captureDate:return L10n.text("app.captureDate", defaultValue: "Capture Date"); case .virtualCopy:return L10n.text("app.isVirtualCopy", defaultValue: "Is Virtual Copy"); case .copyName:return L10n.text("app.copyName", defaultValue: "Copy Name")
        }
    }
    var numeric:Bool { self == .rating || self == .flag || self == .colorLabel || self == .iso }
    var operators:[SmartOperator] {
        if self == .virtualCopy { return [.equal] }
        if self == .rating { return [.equal,.notEqual,.atLeast,.atMost,.greaterThan,.lessThan,.between,.empty,.notEmpty] }
        if self == .colorLabel { return [.equal,.notEqual,.oneOf] }
        if self == .flag { return [.equal,.notEqual] }
        if numeric || self == .captureDate { return [.equal,.notEqual,.atLeast,.atMost,.between,.empty,.notEmpty] }
        return [.contains,.notContains,.equal,.notEqual,.empty,.notEmpty]
    }
    var column:String {
        switch self {
        case .filename:return "photo_filename(photo.relativePath)"; case .rating:return "photo.rating"; case .flag:return "photo.flag"
        case .colorLabel:return "photo.colorLabel"
        case .keyword:return "keyword"; case .camera:return "photo.camera"; case .lens:return "photo_lens(photo.metadata)"
        case .iso:return "photo_iso(photo.metadata)"; case .captureDate:return "photo_day(photo.captureDate)"
        case .virtualCopy:return "(photo.copyName IS NOT NULL)"; case .copyName:return "photo.copyName"
        }
    }
}
enum SmartOperator:String,Codable,Identifiable {
    case contains,notContains,oneOf,equal,notEqual,atLeast,atMost,greaterThan,lessThan,between,empty,notEmpty
    var id:String { rawValue }
    var title:String {
        switch self { case .oneOf:return L10n.text("app.hasAnyColor", defaultValue: "Has Any Color"); case .contains:return L10n.text("app.contains", defaultValue: "Contains"); case .notContains:return L10n.text("app.doesNotContain", defaultValue: "Does Not Contain"); case .equal:return L10n.text("app.equals", defaultValue: "Equals"); case .notEqual:return L10n.text("app.doesNotEqual", defaultValue: "Does Not Equal"); case .atLeast:return L10n.text("app.atLeast", defaultValue: "At Least"); case .atMost:return L10n.text("app.atMost", defaultValue: "At Most"); case .greaterThan:return L10n.text("app.greaterThan", defaultValue: "Greater Than"); case .lessThan:return L10n.text("app.lessThan", defaultValue: "Less Than"); case .between:return L10n.text("app.betweenInclusive", defaultValue: "Between (Inclusive)"); case .empty:return L10n.text("app.isEmpty", defaultValue: "Is Empty"); case .notEmpty:return L10n.text("app.isNotEmpty", defaultValue: "Is Not Empty") }
    }
    var unary:Bool { self == .empty || self == .notEmpty }
}
struct SmartRule:Codable,Equatable,Hashable,Identifiable {
    var id = UUID()
    var field = SmartField.rating
    var op = SmartOperator.atLeast
    var value = "3"
    var upper = "5"
    func validate() throws {
        guard field.operators.contains(op), value.utf8.count <= 512, upper.utf8.count <= 512 else { throw LRCError(L10n.text("app.invalidRuleFieldOperatorOrLength", defaultValue: "Invalid rule field, operator, or length")) }
        if op.unary { return }
        if op == .oneOf {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let labels = parts.compactMap { Int($0) }
            guard !parts.isEmpty, parts.count <= 6, labels.count == parts.count,
                  Set(labels).count == labels.count, labels.allSatisfy({ PhotoColorLabel(rawValue: $0) != nil }) else { throw LRCError(L10n.text("app.chooseAValidColorLabel", defaultValue: "Choose a valid color label")) }
            return
        }
        let values = op == .between ? [value,upper] : [value]
        if field.numeric {
            for text in values {
                guard let number = Int(text), (field == .rating || field == .colorLabel) ? (0...5).contains(number) : field == .flag ? (-1...1).contains(number) : (1...Int(Int32.max)).contains(number) else { throw LRCError(L10n.text("app.ratingsAndColorLabelsMustBe05Flags", defaultValue: "Ratings and color labels must be 0–5; flags must be -1/0/1; ISO must be a positive integer up to 2147483647")) }
            }
            if op == .between, Int(value)! > Int(upper)! { throw LRCError(L10n.text("app.theLowerBoundCannotExceedTheUpperBound", defaultValue: "The lower bound cannot exceed the upper bound")) }
        } else if field == .virtualCopy {
            guard ["true","false"].contains(value) else { throw LRCError(L10n.text("app.theVirtualCopyConditionMustBeYesOrNo", defaultValue: "The virtual copy condition must be Yes or No")) }
        } else if field == .captureDate {
            guard values.allSatisfy({ LibraryMetadataFilter.day($0) == $0 }) else { throw LRCError(L10n.text("app.enterAValidYYYYMMDDDate", defaultValue: "Enter a valid YYYY-MM-DD date")) }
            if op == .between, value > upper { throw LRCError(L10n.text("app.theStartDateCannotBeLaterThanTheEnd", defaultValue: "The start date cannot be later than the end date")) }
        } else {
            guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, value.rangeOfCharacter(from:.controlCharacters) == nil else { throw LRCError(L10n.text("app.enterTextToFindUseIsEmptyToMatch", defaultValue: "Enter text to find. Use Is Empty to match empty values")) }
        }
    }
    var sql:(String,StatementArguments) {
        guard (try? validate()) != nil else { return ("0",[]) }
        let column = field.column
        if op == .oneOf {
            let labels = value.split(separator: ",").compactMap { Int($0) }
            return (column + " IN (" + labels.map { _ in "?" }.joined(separator: ",") + ")", StatementArguments(labels))
        }
        if field == .keyword {
            let base = "SELECT 1 FROM photoKeyword k WHERE k.photoID=photo.id"
            if op.unary { return ((op == .empty ? "NOT " : "") + "EXISTS(" + base + ")",[]) }
            let key = KeywordSummary.key(value), negative = op == .notContains || op == .notEqual
            let test = op == .contains || op == .notContains ? "k.keyword LIKE ? ESCAPE '\\'" : "k.keyword=?"
            let operand = op == .contains || op == .notContains ? "%"+PhotoQuery.escape(key)+"%" : key
            return ((negative ? "NOT " : "")+"EXISTS("+base+" AND "+test+")",[operand])
        }
        if op.unary {
            let empty = field.numeric ? column+" IS NULL" : "("+column+" IS NULL OR "+column+"='')"
            return (op == .empty ? empty : "NOT ("+empty+")",[])
        }
        let operand:DatabaseValueConvertible
        if field == .virtualCopy { operand = value == "true" ? 1 : 0 }
        else if field.numeric { operand = Int(value)! }
        else { operand = value }
        switch op {
        case .contains,.notContains:
            return ("COALESCE("+column+",'') "+(op == .notContains ? "NOT LIKE" : "LIKE")+" ? ESCAPE '\\' COLLATE NOCASE",["%"+PhotoQuery.escape(value)+"%"])
        case .between:
            let high:DatabaseValueConvertible
            if field.numeric { high = Int(upper)! } else { high = upper }
            return (column+" BETWEEN ? AND ?",StatementArguments([operand,high]))
        default:
            let symbol = op == .equal ? "=" : op == .notEqual ? "<>" : op == .atLeast ? ">=" : op == .greaterThan ? ">" : op == .lessThan ? "<" : "<="
            // Null has no numeric/date value. Explicit empty conditions find it.
            // Text empty is the same value as the upstream optional text fields.
            let lhs = field.numeric || field == .captureDate || field == .virtualCopy ? column : "COALESCE("+column+",'')"
            return (lhs+" "+symbol+" ? COLLATE NOCASE",StatementArguments([operand]))
        }
    }
}
struct SmartRules:Codable,Equatable,Hashable {
    var all = true
    var source = "all"
    var conditions = [SmartRule()]
    func validate() throws {
        guard (1...32).contains(conditions.count), source.utf8.count <= 2048, Set(conditions.map(\.id)).count == conditions.count else { throw LRCError(L10n.text("app.aSmartCollectionNeeds132DistinctConditions", defaultValue: "A smart collection needs 1–32 distinct conditions")) }
        for rule in conditions { try rule.validate() }
        guard source == "all" || source.hasPrefix("collection:") || source.hasPrefix("folder:") || UUID(uuidString:source) != nil else { throw LRCError(L10n.text("app.invalidSmartCollectionSource", defaultValue: "Invalid smart collection source")) }
    }
    var sql:(String,StatementArguments) {
        guard (try? validate()) != nil else { return ("0",[]) }
        let clauses = conditions.map(\.sql)
        return ("("+clauses.map { "("+$0.0+")" }.joined(separator:all ? " AND " : " OR ")+")",clauses.reduce(StatementArguments()) { $0+$1.1 })
    }
    static func from(_ query:PhotoQuery) throws -> Self {
        if let base = query.smart {
            var view = query; view.smart = nil; view.scope = base.source
            let extra = try Self.from(view).conditions.filter { !($0.field == .rating && $0.op == .atLeast && $0.value == "0") }
            if extra.isEmpty { return base }
            guard base.all else { throw LRCError(L10n.text("app.addingFiltersToAnyRulesCreatesNestedConditionsWhich", defaultValue: "Adding filters to Any rules creates nested conditions, which cannot be saved in this version. Edit the original rules or save from a regular source")) }
            let result = Self(source:base.source,conditions:base.conditions+extra); try result.validate(); return result
        }
        guard query.metadata.validationMessage == nil else { throw LRCError(query.metadata.validationMessage!) }
        var rules = [SmartRule(field:.rating,op:query.ratingComparison.smartOperator,value:String(query.ratingThreshold))]
        if !query.search.isEmpty { rules.append(SmartRule(field:.filename,op:.contains,value:query.search)) }
        if query.flags.count == 1, let flag = query.flags.first { rules.append(SmartRule(field:.flag,op:.equal,value:String(flag))) }
        else if query.flags.count == 2, let excluded = Set([-1,0,1]).subtracting(query.flags).first {
            rules.append(SmartRule(field:.flag,op:.notEqual,value:String(excluded)))
        }
        if !query.colorLabels.isEmpty {
            rules.append(SmartRule(field: .colorLabel, op: .oneOf, value: query.colorLabels.sorted().map(String.init).joined(separator: ",")))
        }
        if !query.keyword.isEmpty { rules.append(SmartRule(field:.keyword,op:.equal,value:query.keyword)) }
        for (field,text) in [(SmartField.camera,query.metadata.camera),(.lens,query.metadata.lens)] where !text.isEmpty { rules.append(SmartRule(field:field,op:.contains,value:text)) }
        for (field,op,text) in [(SmartField.iso,SmartOperator.atLeast,query.metadata.minimumISO),(.iso,.atMost,query.metadata.maximumISO),(.captureDate,.atLeast,query.metadata.dateFrom),(.captureDate,.atMost,query.metadata.dateThrough)] where !text.isEmpty { rules.append(SmartRule(field:field,op:op,value:text)) }
        let result = Self(source:query.scope,conditions:rules); try result.validate(); return result
    }
}
extension PhotoCollection {
    var isSmart:Bool { rules != nil }
    func decodedRules() throws -> SmartRules? {
        guard let rules else { return nil }
        let decoded = try JSONDecoder().decode(SmartRules.self,from:rules); try decoded.validate(); return decoded
    }
    func resultQuery(manualOrder: Bool = false) throws -> PhotoQuery {
        if let rules = try decodedRules() { return PhotoQuery(scope: rules.source, smart: rules) }
        var query = PhotoQuery(scope: "collection:" + id)
        query.manualCollectionOrder = manualOrder
        return query
    }
}
extension CatalogStore {
    func checkSmartSource(_ rules:SmartRules) throws {
        try rules.validate()
        if rules.source.hasPrefix("collection:") {
            let id = String(rules.source.dropFirst(11))
            guard let collection = try collections().first(where: { $0.id == id }), !collection.isSmart else { throw LRCError(L10n.text("app.theSourceMustBeAnExistingRegularCollectionRecursive", defaultValue: "The source must be an existing regular collection. Recursive smart collections are unsupported")) }
        } else if rules.source != "all" {
            let parts = rules.source.split(separator:":",maxSplits:2).map(String.init)
            let rootID = rules.source.hasPrefix("folder:") && parts.count == 3 ? parts[1] : rules.source
            guard try roots().contains(where: { $0.id == rootID }) else { throw LRCError(L10n.text("app.theSourceFolderDoesNotExist", defaultValue: "The source folder does not exist")) }
            if rules.source.hasPrefix("folder:"), (parts.count != 3 || parts[2].split(separator:"/").contains("..")) { throw LRCError(L10n.text("app.invalidSourceSubfolder", defaultValue: "Invalid source subfolder")) }
        }
    }
    /// Replacement is atomic. No smart collection has stored member rows.
    func replaceSmartCollection(id:String,with value:PhotoCollection?, restoring: Bool = false) throws -> PhotoCollection? {
        if let value {
            guard value.id == id, value.isSmart else { throw LRCError(L10n.text("app.invalidSmartCollectionData", defaultValue: "Invalid smart collection data")) }
            if !restoring {
                guard let rules = try value.decodedRules() else { throw LRCError(L10n.text("app.invalidSmartCollectionData", defaultValue: "Invalid smart collection data")) }
                try checkSmartSource(rules)
                guard (1...100).contains(value.name.trimmingCharacters(in:.whitespacesAndNewlines).count),
                      value.name.rangeOfCharacter(from:.controlCharacters) == nil else { throw LRCError(L10n.text("app.collectionNamesMustContain1100CharactersWithoutControl", defaultValue: "Collection names must contain 1–100 characters without control characters")) }
            }
        }
        return try database.write { db in
            let old = try PhotoCollection.fetchOne(db,key:id)
            if let old, !old.isSmart { throw LRCError(L10n.text("app.aRegularCollectionCannotBeOverwrittenWithASmart", defaultValue: "A regular collection cannot be overwritten with a smart collection")) }
            guard old != value else { return old }
            if let value { try value.save(db) }
            else { try db.execute(sql:"DELETE FROM collection WHERE id=?",arguments:[id]) }
            return old
        }
    }
    func requireManualCollection(_ db:Database,id:String) throws {
        guard let collection = try PhotoCollection.fetchOne(db,key:id), !collection.isSmart else { throw LRCError(L10n.text("app.smartCollectionMembershipIsDeterminedByRulesMembersCannot", defaultValue: "Smart collection membership is determined by rules. Members cannot be added or removed manually")) }
    }
    func collectionCount(_ collection:PhotoCollection) throws -> Int {
        let query = try collection.resultQuery()
        let (predicate,args) = query.predicate
        return try database.read { try Int.fetchOne($0,sql:"SELECT count(*) FROM photo WHERE "+predicate,arguments:args) ?? 0 }
    }
}
