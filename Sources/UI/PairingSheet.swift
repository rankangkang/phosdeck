import SwiftUI
import GRDB

struct PairMenu: View {
    @Bindable var model: AppModel
    var body: some View {
        Button(L10n.text("app.detectManageRAWJPEGPairs", defaultValue: "Detect / Manage RAW/JPEG Pairs…")) { model.openPairing() }.disabled(model.catalog == nil)
        if let pair = model.activePair {
            let versions = model.partnerVersions
            if versions.isEmpty { Text(L10n.text("app.thePartnerSourceHasNoActiveVersionThePair", defaultValue: "The partner source has no active version. The pair is retained and can be removed")) }
            Menu(L10n.text("app.goToPartnerVersionShowEntireCatalog", defaultValue: "Go to Partner Version (Show Entire Catalog)")) { ForEach(versions) { p in Button(p.displayName) { model.openVersion(p.id) } } }.disabled(versions.isEmpty)
            Menu(L10n.text("app.compareRAWJPEGSideBySide", defaultValue: "Compare RAW ↔ JPEG Side by Side")) { ForEach(versions) { p in Button(p.displayName) { model.comparePartner(p.id) } } }.disabled(versions.isEmpty)
            Menu(L10n.text("app.addPairedVersionsToStackMergeExistingStacks", defaultValue: "Add Paired Versions to Stack (Merge Existing Stacks)")) { ForEach(versions) { p in Button(p.displayName) { model.stackPartner(p.id) } } }.disabled(versions.isEmpty)
            Button(L10n.text("app.unpairCurrentSourceKeepBothVersions", defaultValue: "Unpair Current Source (Keep Both Versions)")) { model.unlinkPair(pair.id) }
        }
    }
}
struct PairingSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var candidates: [PairCandidate] = []
    @State private var selected: Set<String> = []
    @State private var proposals: [PairProposal] = []
    @State private var sources: [CatalogSource] = []
    @State private var pairs: [RawJpegPair] = []
    @State private var counts: [String:Int] = [:]
    @State private var availability: [String:String] = [:]
    @State private var rawID = ""
    @State private var jpegID = ""
    @State private var manualConfirmed = false
    @State private var working = false
    @State private var job: Task<Void,Never>?
    @State private var error: String?
    private var conflict: String? {
        guard let a = sources.first(where: { $0.id == rawID }), let b = sources.first(where: { $0.id == jpegID }) else { return nil }
        return RawJpegPairing.metadataConflict(a,b)
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L10n.text("app.rawJPEGSourcePairing", defaultValue: "RAW/JPEG Source Pairing")).font(.headline)
            Text(L10n.text("app.twoIndependentSourcesRetainTheirOwnRecipesHistorySnapshots", defaultValue: "Two independent sources retain their own recipes, history, snapshots, ratings, and keywords. Pairing preserves stacks and does not read or write XMP.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            HStack {
                Button(L10n.text("app.rescanCurrentScope", defaultValue: "Rescan Current Scope")) { load() }.buttonStyle(.key).disabled(working)
                Text(model.pairingScope == nil ? L10n.text("app.allCatalogSources", defaultValue: "All Catalog Sources") : L10n.text("app.sourcesImportedSuccessfullyThisTimeAndCatalogedPartners", defaultValue: "Sources Imported Successfully This Time and Cataloged Partners")).foregroundStyle(Theme.textSecondary)
                if working { ProgressView().controlSize(.small) }
            }
            KeyRow(title:L10n.text("app.pairingView", defaultValue: "Pairing View"),options:[KeyOption(0,L10n.text("app.candidatesAndConfirmation", defaultValue: "Candidates and Confirmation")),KeyOption(1,L10n.text("app.manualSelection", defaultValue: "Manual Selection")),KeyOption(2,L10n.text("app.existingPairs", defaultValue: "Existing Pairs (\(pairs.count))"))],selection:$tab,expand:false).disabled(working)
            Group {
                if tab == 0 { candidateView }
                else if tab == 1 { manualView }
                else { existingView }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).disabled(working)
            if let error { Text(error).foregroundStyle(Theme.warning).textSelection(.enabled).lineLimit(3) }
            HStack {
                if !proposals.isEmpty { Text(L10n.text("app.verificationFrozenForPairsIdentityLocationAndDigestAre", defaultValue: "Verification frozen for \(proposals.count) pairs. Identity, location, and digest are checked again on confirmation")).font(.caption11) }
                Spacer()
                Button(working ? L10n.text("app.cancelVerification", defaultValue: "Cancel Verification") : L10n.text("app.close", defaultValue: "Close")) { if working { job?.cancel() } else { dismiss() } }.keyboardShortcut(.cancelAction)
                Button(L10n.text("app.createPairs", defaultValue: "Create \(proposals.count) Pairs")) {
                    let frozen = proposals
                    working = true
                    job = Task {
                        let applied = await model.applyPairs(frozen)
                        working = false
                        if applied { proposals = []; load() }
                        else { error = model.error ?? L10n.text("app.pairingWasNotCreatedVerifyAgain", defaultValue: "Pairing was not created. Verify again"); model.error = nil }
                    }
                }.disabled(working || proposals.isEmpty).buttonStyle(.key).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:900,height:620).instrumentForm()
        .task { load() }.onDisappear { job?.cancel() }
    }
    private var candidateView: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(L10n.text("app.automaticCandidatesNeedTheSameRootAndParentFolder", defaultValue: "Automatic candidates need the same root and parent folder, a matching basename under filesystem rules, and exactly one RAW and one JPEG. Review ambiguity in Manual Selection. Missing metadata is never fabricated; different pre-copy folders are also marked ambiguous.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            List(candidates) { candidate in
                HStack {
                    Toggle(isOn:Binding(get:{ selected.contains(candidate.id) },set:{ checked in
                        if checked { selected.insert(candidate.id) } else { selected.remove(candidate.id) }; proposals = []
                    })) { VStack(alignment:.leading,spacing:4) { Text(candidate.title).lineLimit(2); Text(candidate.issue ?? L10n.text("app.candidateFileContentsNotYetVerified", defaultValue: "Candidate: file contents not yet verified")).font(.caption11).foregroundStyle(candidate.issue == nil ? Theme.textSecondary : Theme.warning) } }.disabled(candidate.issue != nil || working)
                }.padding(.vertical,4)
            }.scrollContentBackground(.hidden).background(Theme.inset).overlay { if candidates.isEmpty { Text(L10n.text("app.noCandidatesInThisScopeRescanAfterImportingMore", defaultValue: "No candidates in this scope. Rescan after importing more photos")).foregroundStyle(Theme.textSecondary) } }
            Button(L10n.text("app.verifyAndPreviewSelectedPairs", defaultValue: "Verify and Preview \(selected.count) Selected Pairs")) { prepareCandidates() }.buttonStyle(.key).disabled(working || selected.isEmpty)
            if !proposals.isEmpty { Text(proposals.map { "RAW \($0.raw.source.relativePath) ↔ JPEG \($0.jpeg.source.relativePath)" }.joined(separator:"\n")).font(.caption11).lineLimit(4).textSelection(.enabled) }
        }.padding(12)
    }
    private var manualView: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(L10n.text("app.filenamesIdentifyCandidatesOnlyManualPairsMaySpanFolders", defaultValue: "Filenames identify candidates only. Manual pairs may span folders. Choose a verified RAW source and JPEG source; each source supports one pair."))
            Picker(L10n.text("app.rawSource", defaultValue: "RAW Source"),selection:$rawID) { Text(L10n.text("app.choose", defaultValue: "Choose")).tag(""); ForEach(sources.filter { $0.kind == "RAW" }) { Text(L10n.text("app.versions", defaultValue: "\($0.relativePath) · \(counts[$0.id] ?? 0) versions · \(String($0.id.prefix(8)))")).tag($0.id) } }
            Picker(L10n.text("app.jpegSource", defaultValue: "JPEG Source"),selection:$jpegID) { Text(L10n.text("app.choose", defaultValue: "Choose")).tag(""); ForEach(sources.filter { $0.kind == "JPEG" }) { Text(L10n.text("app.versions", defaultValue: "\($0.relativePath) · \(counts[$0.id] ?? 0) versions · \(String($0.id.prefix(8)))")).tag($0.id) } }
            if let conflict { Text(conflict).foregroundStyle(Theme.warning) }
            Toggle(L10n.text("app.iVerifiedTheseSourcesAreFromTheSameCapture", defaultValue: "I verified these sources are from the same capture; retain their independent edits"),isOn:$manualConfirmed)
            Button(L10n.text("app.verifyAndPreviewManualPair", defaultValue: "Verify and Preview Manual Pair")) { prepareManual() }.buttonStyle(.key).disabled(working || rawID.isEmpty || jpegID.isEmpty || !manualConfirmed)
            Spacer()
        }.padding(16).onChange(of:rawID) { proposals = []; manualConfirmed = false }.onChange(of:jpegID) { proposals = []; manualConfirmed = false }
    }
    private var existingView: some View {
        List(pairs) { pair in
            HStack {
                VStack(alignment:.leading,spacing:5) {
                    ForEach([pair.rawSourceID,pair.jpegSourceID],id:\.self) { id in
                        if let source = sources.first(where: { $0.id == id }) {
                            Text(L10n.text("app.activeVersions", defaultValue: "\(source.kind ?? L10n.text("app.source", defaultValue: "Source")) · \(source.relativePath) · \(counts[id] ?? 0) active versions · \(availability[id] ?? L10n.text("app.notVerified", defaultValue: "Not Verified"))"))
                            if counts[id] == 0 { Text(L10n.text("app.thisSourceHasNoActiveVersionsPairingIsRetained", defaultValue: "This source has no active versions. Pairing is retained; unpair it or undo version removal to navigate again.")).font(.caption11).foregroundStyle(Theme.textSecondary) }
                        }
                    }
                }
                Spacer()
                Button(L10n.text("app.unpair", defaultValue: "Unpair")) { model.unlinkPair(pair.id); load() }.disabled(working)
            }.padding(.vertical,6)
        }.scrollContentBackground(.hidden).background(Theme.inset)
            .overlay { if pairs.isEmpty { Text(L10n.text("app.noRAWJPEGPairsYet", defaultValue: "No RAW/JPEG pairs yet")).foregroundStyle(Theme.textSecondary) } }.padding(12)
    }
    private func load() {
        guard let catalog = model.catalog else { return }
        job?.cancel(); working = true; error = nil; proposals = []
        job = Task {
            do {
                let found = try await model.pairing.detect(catalog:catalog,within:model.pairingScope)
                try Task.checkCancellation()
                sources = try catalog.sources(); pairs = try catalog.pairs(); candidates = found
                selected = Set(found.filter { $0.issue == nil }.map(\.id))
                let photos = try catalog.photos(ids:model.selection)
                if let p = photos.first(where: { $0.isRAW }) { rawID = p.sourceKey }
                if let p = photos.first(where: { $0.relativePath.lowercased().hasSuffix(".jpg") || $0.relativePath.lowercased().hasSuffix(".jpeg") }) { jpegID = p.sourceKey }
                counts = try await catalog.database.read { db in Dictionary(uniqueKeysWithValues:try Row.fetchAll(db,sql:"SELECT sourceID,count(*) AS n FROM photo WHERE deleted=0 GROUP BY sourceID").map { row in let id: String = row["sourceID"]; let n: Int = row["n"]; return (id,n) }) }
                availability = try await model.pairing.availability(catalog:catalog)
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            working = false
        }
    }
    private func prepareCandidates() {
        guard let catalog = model.catalog else { return }
        let chosen = candidates.filter { selected.contains($0.id) && $0.issue == nil }
        working = true; proposals = []; error = nil
        job = Task {
            do {
                var frozen = [PairProposal]()
                for c in chosen {
                    try Task.checkCancellation()
                    let proposal: PairProposal
                    do { proposal = try await model.pairing.prepare(c, catalog: catalog) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        if let i = candidates.firstIndex(where: { $0.id == c.id }) { candidates[i].issue = L10n.text("app.ambiguityContentVerificationFailed", defaultValue: "Ambiguity / content verification failed: ") + error.localizedDescription }
                        selected.remove(c.id); throw error
                    }
                    frozen.append(proposal)
                }
                try Task.checkCancellation(); proposals = frozen
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            working = false
        }
    }
    private func prepareManual() {
        guard let catalog = model.catalog else { return }
        let requestedRaw = rawID, requestedJPEG = jpegID
        working = true; proposals = []; error = nil
        job = Task {
            do {
                let proposal = try await model.pairing.prepare(rawID:requestedRaw,jpegID:requestedJPEG,catalog:catalog)
                try Task.checkCancellation()
                guard rawID == requestedRaw, jpegID == requestedJPEG else { throw LRCError(L10n.text("app.manualSelectionsChangedVerifyAgain", defaultValue: "Manual selections changed. Verify again")) }
                proposals = [proposal]
            }
            catch is CancellationError { proposals = [] } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
