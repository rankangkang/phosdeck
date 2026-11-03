import SwiftUI

struct SmartCollectionSheet:View {
    @Bindable var model: AppModel
    let collection:PhotoCollection
    @Environment(\.dismiss) private var dismiss
    @State private var name:String
    @State private var rules:SmartRules
    @State private var error:String?
    private let folders:[String:[String]]
    init(model:AppModel,collection:PhotoCollection) {
        self.model = model; self.collection = collection
        _name = State(initialValue:collection.name)
        do { _rules = State(initialValue:try collection.decodedRules() ?? SmartRules()) }
        catch { _rules = State(initialValue:SmartRules()); _error = State(initialValue:L10n.text("app.cannotReadTheOriginalRulesOnlyExplicitlySavingNew", defaultValue: "Cannot read the original rules. Only explicitly saving new rules replaces the original payload: ")+error.localizedDescription) }
        folders = (try? model.catalog?.folderPaths()) ?? [:]
    }
    private var validation:String? {
        do {
            guard (1...100).contains(name.trimmingCharacters(in:.whitespacesAndNewlines).count) else { return L10n.text("app.collectionNamesMustContain1100Characters", defaultValue: "Collection names must contain 1–100 characters") }
            try model.catalog?.checkSmartSource(rules); return nil
        } catch { return error.localizedDescription }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.text("app.smartCollection", defaultValue: "Smart Collection")).font(.headline)
            LabeledContent(L10n.text("app.collectionName", defaultValue: "Collection Name")) { TextField(L10n.text("app.1100Characters", defaultValue: "1–100 characters"),text:$name).accessibilityIdentifier("smart-name") }
            Picker(L10n.text("app.source", defaultValue: "Source"),selection:$rules.source) {
                Text(L10n.text("app.entireCatalog", defaultValue: "Entire Catalog")).tag("all")
                ForEach(model.roots) { root in
                    Text(root.label).tag(root.id)
                    ForEach(folders[root.id] ?? [],id:\.self) { path in Text(root.label+" / "+path).tag("folder:"+root.id+":"+path) }
                }
                ForEach(model.collections.filter { !$0.isSmart }) { Text(L10n.text("app.collection", defaultValue: "Collection · ")+$0.name).tag("collection:"+$0.id) }
            }.accessibilityIdentifier("smart-source")
            KeyRow(title:L10n.text("app.match", defaultValue: "Match"),options:[KeyOption(true,L10n.text("app.allConditions", defaultValue: "All Conditions")),KeyOption(false,L10n.text("app.anyCondition", defaultValue: "Any Condition"))],selection:$rules.all,expand:true)
                .accessibilityIdentifier("smart-match")
            SubgroupLabel(L10n.text("app.conditions", defaultValue: "Conditions"))
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    ForEach($rules.conditions) { $rule in
                        VStack(alignment:.leading,spacing:6) {
                            HStack {
                                Picker(L10n.text("app.field", defaultValue: "Field"),selection:$rule.field) { ForEach(SmartField.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width:150)
                                    .onChange(of:rule.field) { _,field in
                                        rule.op = field.operators[0]
                                        rule.value = field == .virtualCopy ? "true" : field == .flag ? "1" : field == .colorLabel ? "0" : field == .rating ? "3" : field == .iso ? "100" : field == .captureDate ? "2026-01-01" : ""
                                        rule.upper = field == .captureDate ? "2026-12-31" : "5"
                                    }
                                Picker(L10n.text("app.operator", defaultValue: "Operator"),selection:$rule.op) { ForEach(rule.field.operators) { Text($0.title).tag($0) } }.labelsHidden().frame(width:170)
                                    .onChange(of: rule.op) { _, _ in
                                        if rule.field == .colorLabel, rule.op != .oneOf { rule.value = rule.value.split(separator: ",").first.map(String.init) ?? "0" }
                                    }
                                Spacer()
                                Button { rules.conditions.removeAll { $0.id == rule.id } } label:{ Image(systemName:"minus") }
                                    .buttonStyle(.iconKey).help(L10n.text("app.deleteCondition", defaultValue: "Delete Condition")).accessibilityLabel(L10n.text("app.deleteCondition_1886", defaultValue: "Delete \(rule.field.title) Condition"))
                            }
                            if !rule.op.unary {
                                if rule.field == .virtualCopy {
                                    KeyRow(title: L10n.text("app.virtualCopy", defaultValue: "Virtual Copy"), options: [KeyOption("true", L10n.text("app.yes", defaultValue: "Yes")), KeyOption("false", L10n.text("app.no", defaultValue: "No"))], selection: $rule.value, lampsInside: true)
                                } else if rule.field == .flag {
                                    KeyRow(title: L10n.text("app.flag_1890", defaultValue: "Flag"), options: [KeyOption("1", L10n.text("app.pick", defaultValue: "Pick")), KeyOption("0", L10n.text("app.unflagged", defaultValue: "Unflagged")), KeyOption("-1", L10n.text("app.reject", defaultValue: "Reject"))], selection: $rule.value, lampsInside: true)
                                }
                                else if rule.field == .colorLabel {
                                    ColorLabelKeys(selected: Set(rule.value.split(separator: ",").compactMap { Int($0) }), prefix: "smart-color") { label in
                                        if rule.op == .oneOf {
                                            var values = Set(rule.value.split(separator: ",").compactMap { Int($0) })
                                            if values.contains(label) { values.remove(label) } else { values.insert(label) }
                                            rule.value = values.sorted().map(String.init).joined(separator: ",")
                                        } else { rule.value = String(label) }
                                    }
                                }
                                else {
                                    HStack {
                                        TextField(rule.field == .captureDate ? "YYYY-MM-DD" : L10n.text("app.value_1891", defaultValue: "Value"),text:$rule.value)
                                        if rule.op == .between { Text(L10n.text("app.to", defaultValue: "to")); TextField(rule.field == .captureDate ? "YYYY-MM-DD" : L10n.text("app.maximum", defaultValue: "Maximum"),text:$rule.upper) }
                                    }
                                }
                            }
                        }.padding(.vertical,4)
                        Seam()
                    }
                }
            }.frame(minHeight:150,maxHeight:340)
            HStack { Button(L10n.text("app.addCondition", defaultValue: "Add Condition")) { rules.conditions.append(SmartRule()) }.buttonStyle(.key).disabled(rules.conditions.count >= 32); Text("\(rules.conditions.count) / 32").foregroundStyle(Theme.textSecondary) }
            Text(L10n.text("app.membershipIsCalculatedFromRulesAndCannotBeChanged", defaultValue: "Membership is calculated from rules and cannot be changed manually. In Hold mode, changing rules or sources rebuilds all results.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            if let message = error ?? validation { Text(message).foregroundStyle(Theme.error).font(.caption11) }
            HStack {
                Spacer(); Button(L10n.text("app.cancel", defaultValue: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("app.save", defaultValue: "Save")) {
                    if model.saveSmartCollection(id:collection.id,name:name,rules:rules) { dismiss() }
                    else { error = model.error; model.error = nil }
                }.buttonStyle(.key).disabled(validation != nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:570).instrumentForm()
    }
}
