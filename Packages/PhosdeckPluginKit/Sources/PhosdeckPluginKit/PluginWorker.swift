import ExtensionFoundation
import Foundation

@MainActor
public func photoToolConfiguration(_ tool: some PhotoTool) -> ConnectionHandler {
    ConnectionHandler(onConnection: { bootstrap in
        guard let host = Bundle.main.object(forInfoDictionaryKey: "PhosdeckPluginHost") as? String,
              let team = try? PluginSignature.ownTeam(),
              let requirement = try? PluginSignature.requirement(identifier: host, team: team) else { return false }
        // The ExtensionFoundation bootstrap connection is used only to vend the signed listener's endpoint.
        bootstrap.exportedInterface = NSXPCInterface(with: PluginBootstrapRPC.self)
        bootstrap.exportedObject = PluginBootstrap(tool: tool, team: team, requirement: requirement)
        bootstrap.resume()
        return true
    })
}

private final class PluginBootstrap: NSObject, PluginBootstrapRPC, NSXPCListenerDelegate {
    let tool: any PhotoTool
    let team: String
    private let listener = NSXPCListener.anonymous()

    init(tool: any PhotoTool, team: String, requirement: String) {
        self.tool = tool
        self.team = team
        super.init()
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = self
        listener.activate()
    }

    deinit { listener.invalidate() }

    func endpoint(reply: @escaping (String, NSXPCListenerEndpoint) -> Void) {
        reply(team, listener.endpoint)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let worker = PluginWorker(tool: tool)
        connection.exportedInterface = NSXPCInterface(with: PluginWorkRPC.self)
        connection.exportedObject = worker
        connection.invalidationHandler = { [weak worker] in worker?.stop() }
        connection.interruptionHandler = { [weak worker] in worker?.stop() }
        connection.resume()
        return true
    }
}

private final class PluginWorker: NSObject, PluginWorkRPC, @unchecked Sendable {
    typealias Completion = (String, FileHandle?, FileHandle?) -> Void
    private let tool: any PhotoTool
    private let lock = NSLock()
    private var session: UUID?
    private var running: (id: UUID, task: Task<Void, Never>)?

    init(tool: any PhotoTool) { self.tool = tool }

    func describe(reply: @escaping (Int, String) -> Void) {
        reply(1, (try? PluginControl.encode(tool.descriptor)) ?? "")
    }

    func open(session: NSUUID, key: String, reply: @escaping (Bool) -> Void) {
        let accepted = lock.withLock {
            let id = session as UUID
            guard key == tool.descriptor.key, self.session == nil || self.session == id else { return false }
            self.session = id
            return true
        }
        reply(accepted)
    }

    func evaluate(session: NSUUID, control: String, input: FileHandle, resource: FileHandle?, reply: @escaping Completion) {
        guard let evaluation = try? PluginControl.decode(Evaluation.self, from: control) else {
            try? input.close(); try? resource?.close()
            finish(id: UUID(), error: PluginFailure.invalidControl, reply: reply)
            return
        }
        let id = evaluation.request.id
        let accepted = lock.withLock {
            guard self.session == session as UUID, running == nil else { return false }
            let task = Task.detached(priority: evaluation.request.purpose == .final ? .utility : .userInitiated) { [self] in
                let result = await process(evaluation, input: input, resource: resource)
                try? input.close(); try? resource?.close()
                lock.withLock { running = nil }
                switch result {
                case .success(let value):
                    reply(value.0, value.1, value.2)
                case .failure(let error):
                    finish(id: id, error: error, reply: reply)
                }
            }
            running = (id, task)
            return true
        }
        if !accepted {
            try? input.close(); try? resource?.close()
            finish(id: id, error: PluginFailure.busy, reply: reply)
        }
    }

    private func process(_ evaluation: Evaluation, input: FileHandle, resource: FileHandle?)
        async -> Result<(String, FileHandle?, FileHandle?), Error> {
        do {
            let frame = try PluginFrame(width: evaluation.width, height: evaluation.height)
            guard frame.byteCount == evaluation.bytes, (0...PluginFile.maxProfileBytes).contains(evaluation.resourceBytes),
                  (evaluation.resourceBytes > 0) == (resource != nil) else { throw PluginFailure.invalidImage }
            let pixels = try PluginFile.copy(input, size: frame.byteCount)
            try frame.verify(pixels)
            let image = try PluginImage(frame: frame, pixels: pixels)
            let profile = try resource.map { try PluginFile.copy($0, size: evaluation.resourceBytes) }
            let result = try await tool.evaluate(evaluation.request, input: image, profile: profile)
            try Task.checkCancellation()
            let id = evaluation.request.id
            switch result {
            case .proof(let image, let warning):
                guard tool.descriptor.kind == .proof, image.frame == frame,
                      warning == nil || warning?.count == frame.count else { throw PluginFailure.invalidResult }
                return .success((try PluginControl.encode(EvaluationResponse(id: id, range: nil, warningBytes: warning?.count ?? 0, error: nil)),
                                 try PluginFile.stage(image.pixels), try warning.map(PluginFile.stage)))
            case .luminanceRange(let range):
                guard tool.descriptor.kind == .luminanceRange else { throw PluginFailure.invalidResult }
                return .success((try PluginControl.encode(EvaluationResponse(id: id, range: range, warningBytes: 0, error: nil)), nil, nil))
            case .developEffect(let image):
                guard tool.descriptor.kind == .developEffect, image.frame == frame else { throw PluginFailure.invalidResult }
                return .success((try PluginControl.encode(EvaluationResponse(id: id, range: nil, warningBytes: 0, error: nil)),
                                 try PluginFile.stage(image.pixels), nil))
            }
        } catch {
            return .failure(error)
        }
    }

    private func finish(id: UUID, error: Error, reply: Completion) {
        let code = error is CancellationError ? "cancelled" : ((error as? PluginFailure) ?? .rejected).rawValue
        reply((try? PluginControl.encode(EvaluationResponse(id: id, range: nil, warningBytes: 0, error: code))) ?? "", nil, nil)
    }

    func cancel(session: NSUUID, request: NSUUID) {
        lock.withLock {
            if self.session == session as UUID, running?.id == request as UUID { running?.task.cancel() }
        }
    }

    func close(session: NSUUID) {
        lock.withLock {
            guard self.session == session as UUID else { return }
            self.session = nil
            running?.task.cancel()
        }
    }

    func stop() {
        lock.withLock {
            session = nil
            running?.task.cancel()
        }
    }
}
