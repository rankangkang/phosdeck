import SwiftUI

struct KeywordEditor: View {
    @Bindable var model: AppModel
    @State private var input = ""
    @State private var captionMode = false
    @State private var renameState: KeywordNameState?
    @State private var renameCatalogPath = ""
    private var matches: [KeywordSummary] {
        let search = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.keywords.filter { search.isEmpty || terms.count > 1 || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.selected > 0) != ($1.selected > 0) ? $0.selected > 0 : $0.keyword < $1.keyword }
    }
    private var terms: [String] { (try? KeywordSummary.terms(input)) ?? [] }
    private var canAdd: Bool { !model.selection.isEmpty && !terms.isEmpty }
    private func addKeyword() {
        guard canAdd else { return }
        if model.changeKeywords(terms, adding: true) { input = "" }
    }
    private func beginRename(_ keyword: KeywordSummary) {
        do {
            guard let catalog = model.catalog else { return }
            renameCatalogPath = catalog.fileURL.path
            renameState = try catalog.keywordNameState(keyword.keyword)
        } catch { model.error = error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                Button(L10n.text("app.keywords", defaultValue: "Keywords")) { captionMode = false; renameState = nil }.buttonStyle(.key(selected: !captionMode))
                Button(L10n.text("app.caption", defaultValue: "Caption")) { captionMode = true; renameState = nil }.buttonStyle(.key(selected: captionMode)).accessibilityIdentifier("caption-tab")
                Spacer(minLength: 8)
                Text(L10n.text("app.photosSelected", defaultValue: "\(model.selection.count) photos selected")).font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            if let renameState {
                KeywordRenameEditor(model: model, original: renameState, catalogPath: renameCatalogPath) { replacement in
                    if let replacement, !input.isEmpty, terms.count <= 1 { input = replacement }
                    self.renameState = nil
                }
            } else if captionMode {
                CaptionEditor(model: model)
            } else {
                HStack {
                    TextField(L10n.text("app.enterOrFindKeywords", defaultValue: "Enter or find keywords"), text: $input).textFieldStyle(.instrument)
                        .onSubmit(addKeyword).accessibilityIdentifier("keyword-input")
                    Button(L10n.text("app.added", defaultValue: "Added"), action: addKeyword).buttonStyle(.key).disabled(!canAdd).accessibilityIdentifier("keyword-add")
                }
                if terms.count > 1 {
                    Text(terms.joined(separator: " · ")).font(.caption11).foregroundStyle(Theme.text)
                        .lineLimit(2).truncationMode(.tail).help(terms.joined(separator: "、"))
                        .accessibilityLabel(L10n.text("app.addSeparateKeywords", defaultValue: "Add \(terms.count) separate keywords: ") + terms.joined(separator: "、"))
                }
                Text(L10n.text("app.separateKeywordsWithCommasAndPressReturnToAdd", defaultValue: "Separate keywords with commas and press Return to add them together. Up to 100 characters each."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
                if !model.recentKeywords.isEmpty {
                    Text(L10n.text("app.recent", defaultValue: "Recent")).font(.caption11).foregroundStyle(Theme.textSecondary)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(model.recentKeywords, id: \.self) { name in
                                Button(name) { model.changeKeyword(name, adding: true) }
                                    .buttonStyle(.key(height: 24, padding: 8))
                                    .disabled(model.selection.isEmpty)
                                    .accessibilityLabel(L10n.text("app.addRecentKeyword", defaultValue: "Add recent keyword \(name)"))
                            }
                        }.padding(.bottom, 3)
                    }
                }
                Seam()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if matches.isEmpty {
                            Text(input.isEmpty ? L10n.text("app.noKeywordsYet", defaultValue: "No keywords yet") : L10n.text("app.noMatchingKeywordAddItAsANewKeyword", defaultValue: "No matching keyword. Add it as a new keyword"))
                                .foregroundStyle(Theme.textSecondary).padding(.vertical, 12)
                        }
                        ForEach(matches) { keyword in
                            HStack(spacing: 8) {
                                Image(systemName: keyword.selected == 0 ? "circle" : keyword.selected == model.selection.count ? "checkmark.circle.fill" : "minus.circle")
                                    .foregroundStyle(keyword.selected > 0 ? Theme.accentText : Theme.textSecondary).accessibilityHidden(true)
                                Text(keyword.name).lineLimit(1).truncationMode(.middle)
                                    .help(L10n.text("app.photosInCatalog", defaultValue: "\(keyword.name) · \(keyword.total) photos in catalog"))
                                Spacer(minLength: 8)
                                Text("\(keyword.selected)/\(model.selection.count)").font(.caption11).monospacedDigit().foregroundStyle(Theme.textSecondary)
                                    .accessibilityLabel(L10n.text("app.ofSelectedPhotosHaveThisKeyword", defaultValue: "\(keyword.selected) of \(model.selection.count) selected photos have this keyword"))
                                HStack(spacing: -1) {
                                Button { model.changeKeyword(keyword.name, adding: true) } label: { Image(systemName: "plus") }
                                    .buttonStyle(.key(position: .leading, height: 24, padding: 6))
                                    .disabled(model.selection.isEmpty || keyword.selected == model.selection.count)
                                    .help(L10n.text("app.addToAllSelectedPhotos", defaultValue: "Add to All Selected Photos")).accessibilityLabel(L10n.text("app.addKeyword", defaultValue: "Add keyword \(keyword.name)"))
                                Button { model.changeKeyword(keyword.name, adding: false) } label: { Image(systemName: "minus") }
                                    .buttonStyle(.key(position: .trailing, height: 24, padding: 6))
                                    .disabled(keyword.selected == 0)
                                    .help(L10n.text("app.removeFromSelectedPhotos", defaultValue: "Remove from Selected Photos")).accessibilityLabel(L10n.text("app.removeKeyword", defaultValue: "Remove keyword \(keyword.name)"))
                                }
                                Button { beginRename(keyword) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.key(height: 24, padding: 6)).disabled(!model.workspaceAvailable)
                                    .help(L10n.text("app.renameThroughoutTheCatalogForAllAssociatedVersions", defaultValue: "Rename throughout the catalog for all associated versions")).accessibilityLabel(L10n.text("app.renameThroughoutCatalog", defaultValue: "Rename \(keyword.name) Throughout Catalog"))
                            }.contentShape(Rectangle()).contextMenu {
                                Button(L10n.text("app.renameThroughoutCatalog_1431", defaultValue: "Rename Throughout Catalog…")) { beginRename(keyword) }.disabled(!model.workspaceAvailable)
                            }
                        }
                    }.padding(.vertical, 4)
                }.frame(height: 240)
                Text(L10n.text("app.allSelectedPhotosHaveItSomePhotosHaveIt", defaultValue: "✓ All selected photos have it　⊖ Some photos have it"))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }
        }.padding(16).frame(width: 390).instrumentForm()
            .disabled(model.applyingAdjustments)
            .onChange(of: model.catalog?.fileURL.path) { _, _ in renameState = nil }
    }
}

struct KeywordRenameEditor: View {
    @Bindable var model: AppModel
    let original: KeywordNameState
    let catalogPath: String
    let done: (String?) -> Void
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool
    init(model: AppModel, original: KeywordNameState, catalogPath: String, done: @escaping (String?) -> Void) {
        self.model = model; self.original = original; self.catalogPath = catalogPath; self.done = done
        _name = State(initialValue: original.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("app.renameKeywordInCatalog", defaultValue: "Rename Keyword in Catalog")).font(.headline)
            Text(L10n.text("app.photoVersions", defaultValue: "“\(original.name)” · \(original.names.count) photo versions")).lineLimit(3).textSelection(.enabled)
            Text(L10n.text("app.appliesThroughoutTheCatalogIncludingUnselectedCollapsedAndRemoved", defaultValue: "Applies throughout the catalog, including unselected, collapsed, and removed versions. Undo as one action."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            TextField(L10n.text("app.newKeyword", defaultValue: "New Keyword"), text: $name).textFieldStyle(.instrument).focused($focused)
                .accessibilityIdentifier("keyword-rename-input")
            Text(L10n.text("app.theCurrentKeywordFilterAndRecentKeywordsFollowThe", defaultValue: "The current keyword filter and recent keywords follow the rename. Smart collection text conditions are preserved."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            if let error { Text(error).foregroundStyle(Theme.error).font(.caption11).accessibilityIdentifier("keyword-rename-error") }
            HStack {
                Spacer()
                Button(L10n.text("app.cancelRename", defaultValue: "Cancel Rename")) { done(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.key)
                    .accessibilityIdentifier("keyword-rename-cancel")
                Button(L10n.text("app.renameThroughoutCatalog_1438", defaultValue: "Rename Throughout Catalog")) {
                    do { try model.renameKeyword(original, to: name, catalogPath: catalogPath); done(try KeywordSummary.name(name)) }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryKeyStyle())
                    .disabled(!model.workspaceAvailable || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("keyword-rename-apply")
            }
        }.onAppear { focused = true }.onChange(of: name) { _, _ in error = nil }
    }
}


struct CaptionEditor: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @State private var original: [String: String] = [:]
    @State private var catalogPath = ""
    @State private var edited = false
    @State private var failure: String?
    private var mixed: Bool { Set(original.values).count > 1 }
    private var valid: Bool { (try? PhotoCaption.normalized(text)) != nil }
    private var dirty: Bool { edited && (mixed || original.values.contains { $0 != text }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mixed ? L10n.text("app.selectedPhotosHaveDifferentCaptionsEnteringTextReplacesAll", defaultValue: "Selected photos have different captions. Entering text replaces all captions; leaving it untouched preserves them.") : L10n.text("app.captionsAreSavedPerPhotoVersionOriginalsArePreserved", defaultValue: "Captions are saved per photo version. Originals are preserved."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            TextEditor(text: Binding(get: { text }, set: { text = $0; edited = true }))
                .font(.body).scrollContentBackground(.hidden).padding(6)
                .background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 3))
                .frame(height: 160).accessibilityLabel(L10n.text("app.captionText", defaultValue: "Caption Text")).accessibilityIdentifier("caption-input")
            Text(L10n.text("app.2000Characters", defaultValue: "\(text.count) / 2000 characters")).font(.caption11).foregroundStyle(valid ? Theme.textSecondary : Theme.error)
            if let failure { Text(failure).font(.caption11).foregroundStyle(Theme.error) }
            HStack {
                Button(L10n.text("app.clearCaption", defaultValue: "Clear Caption")) { text = ""; edited = true }.buttonStyle(.key).accessibilityIdentifier("caption-clear")
                Spacer()
                Button(L10n.text("app.cancelEditing", defaultValue: "Cancel Editing"), action: load).buttonStyle(.key).accessibilityIdentifier("caption-cancel")
                Button(L10n.text("app.apply", defaultValue: "Apply")) {
                    if model.changeCaption(text, ids: Set(original.keys), catalogPath: catalogPath) { load() }
                    else { failure = model.error ?? L10n.text("app.theSelectionOrTaskStateChangedReopenCaption", defaultValue: "The selection or task state changed. Reopen Caption."); model.error = nil }
                }.buttonStyle(PrimaryKeyStyle()).disabled(!dirty || !valid || original.isEmpty || !model.workspaceAvailable)
                    .accessibilityIdentifier("caption-apply")
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.selection) { load() }
        .onChange(of: model.catalog?.fileURL.path) { load() }
    }
    private func load() {
        failure = nil; edited = false
        do {
            original = try model.catalog?.captions(ids: model.selection) ?? [:]
            catalogPath = model.catalog?.fileURL.path ?? ""
            text = Set(original.values).count == 1 ? original.values.first ?? "" : ""
        } catch { original = [:]; text = ""; failure = error.localizedDescription }
    }
}
