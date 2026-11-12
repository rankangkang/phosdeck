import AppKit
import SwiftUI

@MainActor
struct CameraDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: CameraDiagnosticReport
    @State private var results: [CameraDiagnosticResult]
    @State private var selectedID: Int?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var running = false
    @State private var saving = false
    @State private var total = 0
    @State private var folderName = ""
    @State private var currentFile = ""
    @State private var stopped = false
    @State private var message = ""
    @State private var messageIsError = false

    init(report: CameraDiagnosticReport = .empty(), results: [CameraDiagnosticResult] = []) {
        _report = State(initialValue: report)
        _results = State(initialValue: results)
        _selectedID = State(initialValue: results.first?.photo.id)
        _total = State(initialValue: report.requestedFiles)
    }

    private var selected: CameraDiagnosticResult? { results.first { $0.photo.id == selectedID } }
    private var status: String {
        if running { return L10n.text("camera.ui.running", defaultValue: "Checking samples") }
        if stopped { return L10n.text("camera.ui.stopped", defaultValue: "Check stopped") }
        if report.completed { return L10n.text("camera.ui.complete", defaultValue: "Check complete") }
        return L10n.text("camera.ui.localCheck", defaultValue: "Local check")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Seam()
            if running || stopped || !results.isEmpty { summary; Seam() }
            if results.isEmpty { emptyState.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                HStack(spacing: 0) {
                    sampleList.frame(width: 224)
                    Seam(axis: .vertical)
                    if let selected {
                        ScrollView {
                            CameraDiagnosticDetail(result: selected, report: report).padding(20)
                        }.id(selected.photo.id).accessibilityIdentifier("camera-sample-detail")
                    } else { Color.clear.frame(maxWidth: .infinity) }
                }
            }
            Seam()
            footer
        }
        .frame(width: 920, height: 600).instrumentForm()
        .onDisappear(perform: cancel)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.aperture").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("camera.ui.title", defaultValue: "Camera Compatibility Check")).font(.system(size: 16, weight: .semibold))
                Text(L10n.text("camera.ui.subtitle", defaultValue: "Check RAW decoding and rendering on this Mac.")).font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 16)
            if results.isEmpty { chooseButton.buttonStyle(PrimaryKeyStyle()) }
            else { chooseButton.buttonStyle(.key) }
        }.padding(20)
    }

    private var chooseButton: some View {
        Button(action: choose) {
            Label(results.isEmpty ? L10n.text("camera.choose", defaultValue: "Choose Sample Folder…") : L10n.text("camera.ui.changeFolder", defaultValue: "Change Folder…"), systemImage: "folder")
        }.disabled(running || saving).accessibilityIdentifier("camera-choose-folder")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                readout("\(results.count) / \(total)", L10n.text("camera.ui.checked", defaultValue: "Checked"))
                readout(String(results.filter { $0.photo.checks.contains { $0.id == "decode" && $0.verdict == .passed } }.count), L10n.text("camera.ui.decodable", defaultValue: "Decoded"))
                readout(String(results.filter { $0.photo.outcome == .warning }.count), L10n.text("camera.ui.attention", defaultValue: "Needs attention"))
                readout(String(results.filter { $0.photo.outcome == .failed }.count), L10n.text("camera.ui.failed", defaultValue: "Failed"))
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) { Lamp(on: running); Text(status).font(.section) }
                    if !folderName.isEmpty { Label(folderName, systemImage: "folder").font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(1).help(folderName) }
                }
                if running { Button(L10n.text("camera.ui.stop", defaultValue: "Stop"), action: cancel).accessibilityIdentifier("camera-stop") }
            }
            if running {
                ProgressView(value: Double(results.count), total: Double(max(total, 1))).progressViewStyle(.linear)
                Text(currentFile.isEmpty ? L10n.text("camera.ui.readingFolder", defaultValue: "Reading the sample folder…") : currentFile)
                    .font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12).background(Theme.inset)
        .accessibilityIdentifier("camera-check-summary")
    }

    private func readout(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 20, weight: .medium, design: .monospaced))
            Text(title).font(.caption11).foregroundStyle(Theme.textSecondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(value)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: running ? "waveform.path" : "camera.viewfinder")
                .font(.system(size: 42, weight: .ultraLight)).foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(running ? L10n.text("camera.ui.firstSample", defaultValue: "Checking the first sample…") : L10n.text("camera.ui.emptyTitle", defaultValue: "Start with your camera’s RAW files"))
                    .font(.system(size: 20, weight: .medium))
                Text(L10n.text("camera.ui.emptyHelp", defaultValue: "Choose a folder of samples. Review decoding, rendering consistency and embedded previews, one file at a time."))
                    .foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Seam()
            HStack(alignment: .top, spacing: 24) {
                step("01", L10n.text("camera.ui.stepChoose", defaultValue: "Choose samples"), L10n.text("camera.ui.stepChooseHelp", defaultValue: "Up to 32 RAW files; no subfolders."))
                step("02", L10n.text("camera.ui.stepInspect", defaultValue: "Inspect results"), L10n.text("camera.ui.stepInspectHelp", defaultValue: "See previews and individual checks."))
                step("03", L10n.text("camera.ui.stepSave", defaultValue: "Keep a report"), L10n.text("camera.ui.stepSaveHelp", defaultValue: "Save local evidence as JSON."))
            }
        }.frame(width: 632, alignment: .leading).padding(24)
        .accessibilityIdentifier("camera-empty-state")
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number).font(.value).foregroundStyle(Theme.accentText)
            Text(title).font(.section)
            Text(detail).font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private var sampleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { SilkText(L10n.text("camera.ui.samples", defaultValue: "Samples")); Spacer(); Text(String(results.count)).font(.value) }.padding(12)
            Seam()
            List(selection: $selectedID) {
                ForEach(results, id: \.photo.id) { result in
                    HStack(alignment: .top, spacing: 8) {
                        CameraDiagnosticBadge(verdict: result.photo.outcome, sample: true, iconOnly: true).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.filename).font(.section).lineLimit(1).truncationMode(.middle)
                            Text(result.photo.camera.isEmpty ? result.photo.format : result.photo.camera).font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            CameraDiagnosticBadge(verdict: result.photo.outcome, sample: true)
                        }
                    }.padding(.vertical, 4).tag(result.photo.id).help(result.filename)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).tint(Theme.selected)
                .accessibilityLabel(L10n.text("camera.ui.samples", defaultValue: "Samples")).accessibilityIdentifier("camera-sample-list")
            Seam()
            Text(L10n.text("camera.ui.evidenceLimit", defaultValue: "Evidence for these files and this Mac. Other camera modes remain unverified."))
                .font(.caption11).foregroundStyle(Theme.textSecondary).padding(12)
        }.background(Theme.inset)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.text("camera.ui.private", defaultValue: "Local only · Originals preserved"), systemImage: "lock")
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
                if !message.isEmpty {
                    Text(message).font(.caption11).foregroundStyle(messageIsError ? Theme.error : Theme.textSecondary)
                        .lineLimit(2).textSelection(.enabled).accessibilityIdentifier("camera-message")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(saving ? L10n.text("camera.ui.saving", defaultValue: "Saving…") : L10n.text("camera.save", defaultValue: "Save Local Report…"), action: save)
                .buttonStyle(PrimaryKeyStyle()).disabled(running || saving || results.isEmpty).accessibilityIdentifier("camera-save-report")
            Button(L10n.text("app.done", defaultValue: "Done")) { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                .disabled(saving).accessibilityIdentifier("camera-done")
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func cancel() {
        if running { stopped = true }
        task?.cancel(); task = nil; running = false; currentFile = ""; generation = UUID()
    }
    private func choose() {
        let panel = AppModel.directoryPanel(title: L10n.text("camera.choose", defaultValue: "Choose Sample Folder…"))
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        cancel(); results = []; selectedID = nil; report = .empty(); message = ""; messageIsError = false
        total = 0; folderName = folder.lastPathComponent; stopped = false
        let token = UUID(); generation = token; running = true
        task = Task {
            let lease = AccessLease(url: folder)
            defer { withExtendedLifetime(lease) {}; if generation == token { running = false; currentFile = ""; task = nil } }
            do {
                let files = try await CameraDiagnostics.files(in: folder)
                guard !Task.isCancelled, generation == token else { return }
                total = min(files.count, CameraDiagnostics.maximumSamples); report.requestedFiles = total
                if files.isEmpty { message = L10n.text("camera.noSamples", defaultValue: "No supported RAW candidates in this folder."); return }
                let service = CameraDiagnostics()
                for (index, url) in files.prefix(CameraDiagnostics.maximumSamples).enumerated() {
                    currentFile = url.lastPathComponent
                    let result = try await service.inspect(url, index: index+1)
                    guard !Task.isCancelled, generation == token else { return }
                    results.append(result); report.photos.append(result.photo)
                    if selectedID == nil { selectedID = result.photo.id }
                }
                report.completed = true
            } catch {
                if generation == token, !(error is CancellationError) { message = error.localizedDescription; messageIsError = true }
            }
        }
    }
    private func save() {
        guard !running, !saving else { return }
        let panel = AppModel.directoryPanel(title: L10n.text("camera.save", defaultValue: "Save Local Report…"))
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let snapshot = report
        saving = true; message = ""; messageIsError = false
        task = Task {
            defer { saving = false; task = nil }
            do {
                let name = try await CameraDiagnostics.save(snapshot, in: folder)
                message = L10n.text("camera.saved", defaultValue: "Report saved: ") + name
            } catch { message = error.localizedDescription; messageIsError = true }
        }
    }
}

private struct CameraDiagnosticBadge: View {
    let verdict: CameraDiagnosticCheck.Verdict
    var sample = false
    var iconOnly = false
    private var title: String {
        switch verdict {
        case .passed: sample ? L10n.text("camera.ui.inspected", defaultValue: "Checked") : L10n.text("camera.ui.passed", defaultValue: "Passed")
        case .warning: L10n.text("camera.ui.attention", defaultValue: "Needs attention")
        case .failed: L10n.text("camera.ui.failed", defaultValue: "Failed")
        case .skipped: L10n.text("camera.ui.unverified", defaultValue: "Unverified")
        }
    }
    private var symbol: String {
        switch verdict { case .passed: "checkmark.circle"; case .warning: "exclamationmark.triangle"; case .failed: "xmark.circle"; case .skipped: "minus.circle" }
    }
    private var color: Color {
        switch verdict { case .passed: Theme.success; case .warning: Theme.warning; case .failed: Theme.error; case .skipped: Theme.textSecondary }
    }
    var body: some View {
        HStack(spacing: 5) {
            if iconOnly || !sample { Image(systemName: symbol).accessibilityHidden(true) }
            if !iconOnly { Text(title) }
        }.font(.caption11).foregroundStyle(color).accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
}

private struct CameraDiagnosticDetail: View {
    let result: CameraDiagnosticResult
    let report: CameraDiagnosticReport
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.filename).font(.system(size: 14, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text([result.photo.camera, result.photo.format, result.photo.width > 0 ? "\(result.photo.width) × \(result.photo.height)" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    CameraDiagnosticBadge(verdict: result.photo.outcome, sample: true)
                    if result.photo.checks.contains(where: { $0.verdict == .skipped }) {
                        Text(L10n.text("camera.ui.hasUnverified", defaultValue: "Includes unverified checks"))
                            .font(.caption11).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if result.rendered == nil && result.embedded == nil {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("camera.ui.noPreview", defaultValue: "No preview available")).font(.section)
                        Text(L10n.text("camera.ui.noPreviewHelp", defaultValue: "Review the failed checks below. You can choose another sample folder or save this result for troubleshooting."))
                            .font(.caption11).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.inset)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    preview(result.rendered, title: L10n.text("camera.rendered", defaultValue: "Phosdeck default"), missing: L10n.text("camera.ui.noRendering", defaultValue: "No rendered image"))
                    preview(result.embedded, title: L10n.text("camera.ui.embeddedTitle", defaultValue: "Embedded preview"), missing: result.photo.checks.contains(where: { $0.id == "embeddedReference" }) ? L10n.text("camera.noEmbedded", defaultValue: "No readable embedded preview. Reference comparison skipped.") : L10n.text("camera.ui.previewNotChecked", defaultValue: "Embedded preview was not checked."))
                }
                Text(L10n.text("camera.ui.previewNote", defaultValue: "The embedded preview is a visual reference, not a color-accuracy target."))
                    .font(.caption11).foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                SilkText(L10n.text("camera.ui.checks", defaultValue: "Individual checks")).padding(.bottom, 10)
                ForEach(result.photo.checks) { check in
                    Seam()
                    HStack(alignment: .top, spacing: 12) {
                        Text(checkTitle(check.id)).font(.section).frame(width: 112, alignment: .leading)
                        Text(check.detail).font(.caption11).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        CameraDiagnosticBadge(verdict: check.verdict).frame(width: 86, alignment: .trailing)
                    }.padding(.vertical, 10)
                }
            }
            DisclosureGroup(L10n.text("camera.ui.environment", defaultValue: "Check environment")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.system)
                    Text("Phosdeck " + report.appVersion)
                    if !result.photo.decoder.isEmpty { Text("RAW " + result.photo.decoder) }
                }.font(.caption11).foregroundStyle(Theme.textSecondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.caption11)
        }
    }
    private func preview(_ image: CGImage?, title: String, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8) }
                else {
                    VStack(spacing: 8) { Image(systemName: "photo").font(.system(size: 22, weight: .light)).accessibilityHidden(true); Text(missing).font(.caption11).multilineTextAlignment(.center) }
                        .foregroundStyle(Theme.scopeText).padding(16)
                }
            }.frame(height: 164).clipped()
            Text(title).font(.section)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func checkTitle(_ id: String) -> String {
        switch id {
        case "decode": L10n.text("camera.ui.checkDecode", defaultValue: "RAW decoding")
        case "repeat": L10n.text("camera.ui.checkRepeat", defaultValue: "Repeat rendering")
        case "afterDraft": L10n.text("camera.ui.checkDraft", defaultValue: "Quality after draft")
        case "thumbnail": L10n.text("camera.ui.checkThumbnail", defaultValue: "Thumbnail")
        case "sixteenBit": L10n.text("camera.ui.checkDepth", defaultValue: "16-bit rendering")
        case "embeddedReference": L10n.text("camera.ui.checkEmbedded", defaultValue: "Embedded preview")
        case "sensorMeasurements": L10n.text("camera.ui.checkSensor", defaultValue: "Sensor information")
        case "sourceIdentity": L10n.text("camera.ui.checkSource", defaultValue: "Source integrity")
        default: L10n.text("camera.ui.checkOther", defaultValue: "Check result")
        }
    }
}
