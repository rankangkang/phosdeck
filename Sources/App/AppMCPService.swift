import Foundation
import Observation

/// The App owns the listener. Settings can close without affecting active connections.
@MainActor
@Observable
final class AppMCPService {
    enum Status { case off, starting, listening, stopping, failed }

    private(set) var enabled: Bool
    private(set) var sharesImages: Bool
    private(set) var status = Status.off
    private(set) var endpoint: String?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var listener: MCPHTTPListener?
    @ObservationIgnored private var tools: AppMCPTools?
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private var stoppingJob: Task<Void, Never>?
    @ObservationIgnored private var terminating = false
    private let preferences: UserDefaults?
    private let appName: String
    private let bundleID: String
    private let version: String
    private let serverName: String
    private let configurationName: String
    private let tokenVariable: String

    init(preferences: UserDefaults? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? .standard : nil,
         bundle: Bundle = .main) {
        self.preferences = preferences
        enabled = preferences?.bool(forKey: "mcpEnabled") ?? false
        sharesImages = preferences?.bool(forKey: "mcpSharesImages") ?? false
        bundleID = bundle.bundleIdentifier ?? "dev.cmkk.oh-my-lrc"
        appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "Phosdeck"
        version = (bundle.object(forInfoDictionaryKey: "PhosdeckReleaseVersion") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
        let preview = bundleID == "dev.cmkk.oh-my-lrc.unratedstars20261021"
        serverName = preview ? "phosdeck-preview" : "phosdeck"
        configurationName = preview ? "phosdeck_preview" : "phosdeck"
        tokenVariable = preview ? "PHOSDECK_PREVIEW_MCP_TOKEN" : "PHOSDECK_MCP_TOKEN"
    }

    var clientConfiguration: String? {
        endpoint.map {
            "[mcp_servers.\(configurationName)]\nurl = \"\($0)\"\nbearer_token_env_var = \"\(tokenVariable)\""
        }
    }

    var jsonClientConfiguration: String? {
        guard let endpoint, let token = connectionToken else { return nil }
        let entry: [String: Any] = ["type": "http", "url": endpoint, "headers": ["Authorization": "Bearer \(token)"]]
        let configuration = ["mcpServers": [configurationName: entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    var connectionToken: String? { endpoint == nil ? nil : listener?.token }
    var needsShutdown: Bool { listener != nil || transition != nil || stoppingJob != nil }

    func attach(to model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        if enabled { updateListener() }
    }
    func setEnabled(_ value: Bool) {
        guard !terminating, enabled != value else { return }
        enabled = value
        preferences?.set(value, forKey: "mcpEnabled")
        if !value { invalidateConnection() }
        updateListener()
    }
    func setSharesImages(_ value: Bool) {
        guard !terminating else { return }
        sharesImages = value
        preferences?.set(value, forKey: "mcpSharesImages")
        tools?.setSharesImages(value)
    }
    func retry() {
        if status == .failed { updateListener() }
    }
    func shutdownForQuit() async {
        terminating = true
        invalidateConnection()
        updateListener()
        await transition?.value
    }

    private func invalidateConnection() {
        if let job = tools?.stop() { stoppingJob = job }
        tools = nil
        endpoint = nil
    }
    private func updateListener() {
        guard transition == nil else { return }
        transition = Task { await reconcile() }
    }
    private func reconcile() async {
        defer { transition = nil }
        while true {
            if let listener {
                guard tools == nil else { return }
                status = .stopping
                await listener.stop()
                self.listener = nil
            }
            if let job = stoppingJob {
                status = .stopping
                await job.value
                stoppingJob = nil
            }
            guard enabled, !terminating, let model else { status = .off; return }
            status = .starting
            let tools = AppMCPTools(model: model, appName: appName, version: version, bundleID: bundleID, sharesImages: sharesImages)
            self.tools = tools
            do {
                let listener = try await MCPHTTPListener.start(name: serverName, version: version, tools: tools)
                self.listener = listener
                guard self.tools === tools else { continue }
                endpoint = listener.endpoint
                status = .listening
                return
            } catch {
                guard self.tools === tools else { continue }
                invalidateConnection()
                status = .failed
                return
            }
        }
    }
}
