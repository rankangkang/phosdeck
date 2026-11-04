import AppKit
import SwiftUI

@MainActor
struct CameraDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report = CameraDiagnosticReport.empty()
    @State private var results: [CameraDiagnosticResult] = []
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var running = false
    @State private var saving = false
    @State private var total = 0
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("camera.title", defaultValue: "Camera Compatibility…")).font(.title2)
            Text(L10n.text("camera.help", defaultValue: "Check up to 32 RAW files directly inside a folder you choose. Originals and catalog edits are preserved. No data is uploaded."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            HStack {
                Button(L10n.text("camera.choose", defaultValue: "Choose Sample Folder…"), action: choose).buttonStyle(.key).disabled(running || saving)
                if running {
                    ProgressView(value: Double(results.count), total: Double(max(total,1))).frame(width: 160)
                    Text("\(results.count)/\(total)").monospacedDigit()
                    Button(L10n.text("app.cancel", defaultValue: "Cancel"), action: cancel).buttonStyle(.key)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(results, id: \.photo.id) { result in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(result.photo.id) · \(result.filename)").font(.headline).textSelection(.enabled)
                            Text("\(result.photo.camera) · \(result.photo.format)").font(.caption11)
                            if let image = result.rendered {
                                HStack(alignment: .top, spacing: 12) {
                                    preview(image, title: L10n.text("camera.rendered", defaultValue: "Phosdeck default"))
                                    if let embedded = result.embedded { preview(embedded, title: L10n.text("camera.reference", defaultValue: "Embedded preview · reference only")) }
                                }
                            }
                            Text("\(result.photo.width) × \(result.photo.height) · RAW \(result.photo.decoder)").font(.caption11).foregroundStyle(Theme.textSecondary)
                            ForEach(result.photo.checks) { check in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: symbol(check.verdict)).frame(width: 16).accessibilityLabel(check.verdict.rawValue)
                                    Text(check.detail).textSelection(.enabled)
                                }.font(.caption11).foregroundStyle(check.verdict == .failed ? Theme.warning : Theme.textSecondary)
                            }
                            Seam()
                        }
                    }
                }.padding(.trailing, 8)
            }
            if !message.isEmpty { Text(message).font(.caption11).textSelection(.enabled) }
            Text(L10n.text("camera.evidence", defaultValue: "A successful check is evidence for these files on this macOS and RAW decoder version. It does not certify every compression mode or color accuracy."))
                .font(.caption11).foregroundStyle(Theme.textSecondary)
            HStack {
                Button(L10n.text("camera.save", defaultValue: "Save Local Report…"), action: save).buttonStyle(.key).disabled(running || saving || results.isEmpty)
                Spacer()
                Button(L10n.text("app.done", defaultValue: "Done")) { cancel(); dismiss() }.buttonStyle(.key).keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 820, height: 620)
        .onDisappear(perform: cancel)
        .accessibilityIdentifier("camera-diagnostics")
    }
    private func preview(_ image: CGImage, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 240, height: 180).background(Color.black)
            Text(title).font(.caption11)
        }
    }
    private func symbol(_ verdict: CameraDiagnosticCheck.Verdict) -> String {
        switch verdict { case .passed: "checkmark.circle"; case .warning: "exclamationmark.triangle"; case .failed: "xmark.circle"; case .skipped: "minus.circle" }
    }
    private func cancel() {
        task?.cancel(); task = nil; running = false; generation = UUID()
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        cancel(); results = []; report = .empty(); message = ""
        let token = UUID(); generation = token; running = true
        task = Task {
            let lease = AccessLease(url: folder)
            defer { withExtendedLifetime(lease) {}; if generation == token { running = false; task = nil } }
            do {
                let files = try await CameraDiagnostics.files(in: folder)
                guard !Task.isCancelled, generation == token else { return }
                total = min(files.count,32)
                report.requestedFiles = total
                if files.isEmpty { message = L10n.text("camera.noSamples", defaultValue: "No supported RAW candidates in this folder."); return }
                let service = CameraDiagnostics()
                for (index, url) in files.prefix(32).enumerated() {
                    let result = try await service.inspect(url, index: index+1)
                    guard !Task.isCancelled, generation == token else { return }
                    results.append(result); report.photos.append(result.photo)
                }
                report.completed = true
            } catch {
                if generation == token, !(error is CancellationError) { message = error.localizedDescription }
            }
        }
    }
    private func save() {
        guard !running, !saving else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let snapshot = report
        saving = true
        task = Task {
            defer { saving = false; task = nil }
            do {
                let name = try await CameraDiagnostics.save(snapshot, in: folder)
                message = L10n.text("camera.saved", defaultValue: "Report saved: ") + name
            } catch { message = error.localizedDescription }
        }
    }
}
