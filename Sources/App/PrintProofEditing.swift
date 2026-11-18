import ColorSync
import CoreGraphics
import CryptoKit
import Foundation
import Observation
import PhosdeckPluginKit

struct PrintProfileChoice: Identifiable, Sendable {
    let url: URL
    let title: String
    var id: URL { url }

    static func installed() -> [Self] {
        var profiles: [Self] = []
        withUnsafeMutablePointer(to: &profiles) { output in
            ColorSyncIterateInstalledProfilesWithOptions({ dictionary, context in
                guard let dictionary, let context,
                      let info = dictionary as? [String: Any],
                      info[kColorSyncProfileClass.takeUnretainedValue() as String] as? String == "prtr",
                      let url = info[kColorSyncProfileURL.takeUnretainedValue() as String] as? URL else { return true }
                let title = info[kColorSyncProfileDescription.takeUnretainedValue() as String] as? String
                context.assumingMemoryBound(to: [PrintProfileChoice].self).pointee.append(Self(url: url, title: title ?? url.lastPathComponent))
                return true
            }, nil, output, [kColorSyncWaitForCacheReply.takeUnretainedValue() as String: true] as CFDictionary, nil)
        }
        var seen = Set<URL>()
        return profiles.filter { seen.insert($0.url).inserted }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct PrintProfile: Sendable {
    let title: String
    let data: Data
    let digest: SHA256.Digest

    nonisolated init(_ choice: PrintProfileChoice) throws {
        let access = choice.url.startAccessingSecurityScopedResource()
        defer { if access { choice.url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: choice.url)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0, (132...Int64(PluginFile.maxProfileBytes)).contains(status.st_size) else {
            throw PluginFailure.invalidProfile
        }
        let data = try PluginFile.copy(handle, size: Int(status.st_size))
        guard data[12..<16].elementsEqual("prtr".utf8), data[36..<40].elementsEqual("acsp".utf8) else { throw PluginFailure.invalidProfile }
        self.title = choice.title
        self.data = data
        self.digest = SHA256.hash(data: data)
    }
}

struct PrintProofDisplay {
    let image: CGImage
    let gamut: CGImage?
}

@Observable @MainActor
final class PrintProofEditing {
    private struct Source {
        let request: ImageRequest
        let normal: CGImage
        let revision: UInt64
        let edge: Int?
        let interactive: Bool
    }

    private struct Output {
        let source: Source
        let sendToPrinter: CGImage
        let proof: PrintProofDisplay
    }

    var enabled = false {
        didSet { if oldValue != enabled { refresh() } }
    }
    var extensionAvailable = true {
        didSet {
            if !extensionAvailable {
                if enabled { enabled = false }
                message = L10n.text("plugins.softProofUnavailable", defaultValue: "The Soft Proof extension is unavailable. Check Plugins in Settings.")
            } else if !oldValue { message = "" }
        }
    }
    var showsSendingColors = false
    var intent: ToolRequest.PrintIntent = .relativeColorimetric {
        didSet { if oldValue != intent { refresh() } }
    }
    var warning = false {
        didSet { if oldValue != warning { refresh() } }
    }
    private(set) var profile: PrintProfile?
    private(set) var message = ""
    private(set) var processing = false
    private var output: Output?
    @ObservationIgnored private var input: Source?
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var profileGeneration = UUID()
    @ObservationIgnored private var pipeline: ImagePipeline?

    func setProfile(_ choice: PrintProfileChoice) {
        let generation = UUID()
        profileGeneration = generation
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try PrintProfile(choice) }.value
                guard profileGeneration == generation else { return }
                profile = loaded
                if enabled { refresh() } else if extensionAvailable { enabled = true }
            } catch {
                guard profileGeneration == generation else { return }
                enabled = false
                message = L10n.text("plugins.invalidPrintProfile", defaultValue: "Choose a valid printer and paper ICC profile.")
            }
        }
    }

    func setSource(_ request: ImageRequest, normal: CGImage, revision: UInt64, edge: Int?, interactive: Bool) {
        input = Source(request: request, normal: normal, revision: revision, edge: edge, interactive: interactive)
        if enabled { refresh() }
    }

    func clearSource() {
        input = nil
        if enabled { refresh() }
    }

    func leaveDevelop() {
        profileGeneration = UUID()
        showsSendingColors = false
        input = nil
        enabled = false
        pipeline = nil
    }

    func display(for reference: CGImage?) -> PrintProofDisplay? {
        guard enabled, let output, output.source.normal === reference else { return nil }
        return showsSendingColors ? PrintProofDisplay(image: output.sendToPrinter, gamut: nil) : output.proof
    }

    private func refresh() {
        generation = UUID()
        message = ""
        output = nil
        pending = enabled && input != nil && profile != nil
        processing = pending
        worker?.cancel()
        start()
    }

    private func start() {
        guard worker == nil, pending, let input, let profile else { return }
        pending = false
        let token = generation
        let parameters: ToolRequest.Parameters = .proof(intent: intent, gamutWarning: warning)
        let request = ToolRequest(revision: input.revision, purpose: input.interactive ? .draft : .quality, parameters: parameters)
        let render = pipeline ?? ImagePipeline()
        pipeline = render
        worker = Task {
            defer {
                worker = nil
                if generation == token { processing = false }
                start()
            }
            do {
                let (sending, frame) = try await render.printProofSource(input.request, longEdge: input.edge, interactive: input.interactive)
                let result = try await PhotoToolHost.shared.evaluate(key: "soft-proof", request: request, input: frame, profile: profile.data)
                guard case .proof(let image, let gamut) = result else { throw PluginFailure.invalidResult }
                let (photo, overlay) = try await render.printProofDisplay(image, gamut: gamut)
                guard !Task.isCancelled, generation == token, self.profile?.digest == profile.digest else { return }
                output = Output(source: input, sendToPrinter: sending, proof: PrintProofDisplay(image: photo, gamut: overlay))
                if warning, overlay == nil {
                    message = L10n.text("plugins.gamutUnavailable", defaultValue: "The selected profile could not check its target gamut.")
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                switch error as? PluginFailure {
                case .invalidProfile:
                    message = L10n.text("plugins.invalidPrintProfile", defaultValue: "Choose a valid printer and paper ICC profile.")
                case .unavailable:
                    message = L10n.text("plugins.softProofUnavailable", defaultValue: "The Soft Proof extension is unavailable. Check Plugins in Settings.")
                case .busy:
                    message = L10n.text("plugins.busy", defaultValue: "The extension is still processing a request. Try again shortly.")
                default:
                    message = L10n.text("plugins.proofFailed", defaultValue: "Soft proofing could not render this photo.")
                }
            }
        }
    }
}
