import Foundation
import Security

public enum PluginSignature {
    public static func ownTeam() throws -> String {
        var code: SecCode?
        var executable: SecStaticCode?
        var details: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &executable) == errSecSuccess, let executable,
              SecCodeCopySigningInformation(executable, SecCSFlags(rawValue: kSecCSSigningInformation), &details) == errSecSuccess,
              let team = (details as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              validTeam(team) else { throw PluginFailure.unavailable }
        return team
    }

    static func requirement(identifier: String, team: String) throws -> String {
        guard validTeam(team), identifier.utf8.count <= 255,
              identifier.range(of: #"\A[A-Za-z0-9][A-Za-z0-9.-]+\z"#, options: .regularExpression) != nil else {
            throw PluginFailure.invalidControl
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static func validTeam(_ team: String) -> Bool {
        team.range(of: #"\A[A-Z0-9]{10}\z"#, options: .regularExpression) != nil
    }
}

@objc(PhosdeckPluginBootstrapV1)
protocol PluginBootstrapRPC {
    func endpoint(reply: @escaping (String, NSXPCListenerEndpoint) -> Void)
}

@objc(PhosdeckPluginWorkV1)
protocol PluginWorkRPC {
    func describe(reply: @escaping (Int, String) -> Void)
    func open(session: NSUUID, key: String, reply: @escaping (Bool) -> Void)
    func evaluate(session: NSUUID, control: String, input: FileHandle, resource: FileHandle?,
                  reply: @escaping (String, FileHandle?, FileHandle?) -> Void)
    func cancel(session: NSUUID, request: NSUUID)
    func close(session: NSUUID)
}

struct Evaluation: Codable {
    let request: ToolRequest
    let width: Int
    let height: Int
    let bytes: Int
    let resourceBytes: Int
}

struct EvaluationResponse: Codable {
    let id: UUID
    let range: LuminanceSuggestion?
    let warningBytes: Int
    let error: String?
}

enum PluginControl {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 4096 else { throw PluginFailure.invalidControl }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ value: T.Type, from input: String) throws -> T {
        guard input.utf8.count <= 4096 else { throw PluginFailure.invalidControl }
        return try JSONDecoder().decode(T.self, from: Data(input.utf8))
    }
}

private final class PendingReply<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var sent = false
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func didSend() {
        let wasCancelled = lock.withLock {
            sent = true
            return cancelled
        }
        if wasCancelled { _ = finish(.failure(AbandonedPluginWork.cancelled)) }
    }

    func cancel() {
        let wasSent = lock.withLock {
            cancelled = true
            return sent
        }
        if wasSent { _ = finish(.failure(AbandonedPluginWork.cancelled)) }
    }

    func finish(_ result: Result<T, Error>) -> Bool {
        let completion = lock.withLock {
            let saved = continuation
            continuation = nil
            return saved
        }
        completion?.resume(with: result)
        return completion != nil
    }
}

/// The worker may still hold the request's resources after this error.
public enum AbandonedPluginWork: Error, Equatable, Sendable {
    case cancelled, timeout, interrupted
}

private func call<Interface, Response>(_ connection: NSXPCConnection, seconds: Int,
                                       discard: (@Sendable (Response) -> Void)? = nil,
                                       send: (Interface, @escaping (Response) -> Void) -> Void) async throws -> Response {
    let pending = PendingReply<Response>()
    let timeout: any Error = discard == nil ? PluginFailure.timeout : AbandonedPluginWork.timeout
    let interrupted: any Error = discard == nil ? PluginFailure.interrupted : AbandonedPluginWork.interrupted
    let deadline = DispatchWorkItem { _ = pending.finish(.failure(timeout)) }
    defer { deadline.cancel() }
    return try await withTaskCancellationHandler {
        if discard != nil { try Task.checkCancellation() }
        return try await withCheckedThrowingContinuation { continuation in
            pending.install(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                _ = pending.finish(.failure(interrupted))
            }) as? Interface else {
                _ = pending.finish(.failure(PluginFailure.incompatible))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds), execute: deadline)
            send(proxy) { response in
                if !pending.finish(.success(response)) { discard?(response) }
            }
            pending.didSend()
        }
    } onCancel: {
        if discard != nil { pending.cancel() }
    }
}

public final class PluginChannel: @unchecked Sendable {
    public let descriptor: ToolDescriptor
    public let team: String
    private let bootstrap: NSXPCConnection
    private let work: NSXPCConnection

    private init(bootstrap: NSXPCConnection, work: NSXPCConnection, team: String, descriptor: ToolDescriptor) {
        self.bootstrap = bootstrap
        self.work = work
        self.team = team
        self.descriptor = descriptor
    }

    public static func connect(bootstrap: NSXPCConnection, identifier: String, expectedTeam: String) async throws -> PluginChannel {
        bootstrap.remoteObjectInterface = NSXPCInterface(with: PluginBootstrapRPC.self)
        bootstrap.resume()
        do {
            let (claim, endpoint): (String, NSXPCListenerEndpoint) = try await call(bootstrap, seconds: 3) { (proxy: PluginBootstrapRPC, finish) in
                proxy.endpoint { finish(($0, $1)) }
            }
            guard claim == expectedTeam else { throw PluginFailure.incompatible }
            let signingRequirement = try PluginSignature.requirement(identifier: identifier, team: claim)
            let work = NSXPCConnection(listenerEndpoint: endpoint)
            work.setCodeSigningRequirement(signingRequirement)
            work.remoteObjectInterface = NSXPCInterface(with: PluginWorkRPC.self)
            work.resume()
            do {
                let (version, description): (Int, String) = try await call(work, seconds: 3) { (proxy: PluginWorkRPC, finish) in
                    proxy.describe { finish(($0, $1)) }
                }
                guard version == 1 else { throw PluginFailure.incompatible }
                let descriptor = try PluginControl.decode(ToolDescriptor.self, from: description)
                guard (1...128).contains(descriptor.key.utf8.count), (1...256).contains(descriptor.name.utf8.count),
                      descriptor.algorithm > 0 else { throw PluginFailure.incompatible }
                return PluginChannel(bootstrap: bootstrap, work: work, team: claim, descriptor: descriptor)
            } catch {
                work.invalidate()
                throw error
            }
        } catch {
            bootstrap.invalidate()
            throw error
        }
    }

    deinit {
        work.invalidate()
        bootstrap.invalidate()
    }

    public func open() async throws -> UUID {
        let session = UUID()
        let accepted: Bool = try await call(work, seconds: 3) { (proxy: PluginWorkRPC, finish) in
            proxy.open(session: session as NSUUID, key: descriptor.key, reply: finish)
        }
        guard accepted else { throw PluginFailure.rejected }
        return session
    }

    public func close(_ session: UUID) {
        (work.remoteObjectProxy as? PluginWorkRPC)?.close(session: session as NSUUID)
    }

    public func evaluate(_ request: ToolRequest, session: UUID, input: PluginImage, stagedInput: FileHandle? = nil, profile: Data?,
                         lateCompletion: @escaping @Sendable () -> Void) async throws -> ToolResult {
        try Task.checkCancellation()
        let frame = input.frame
        let resourceBytes = profile?.count ?? 0
        guard resourceBytes <= PluginFile.maxProfileBytes else { throw PluginFailure.invalidProfile }
        let control = try PluginControl.encode(Evaluation(request: request, width: frame.width, height: frame.height,
                                                          bytes: frame.byteCount, resourceBytes: resourceBytes))
        let handle = try stagedInput ?? PluginFile.stage(input.pixels)
        defer { if stagedInput == nil { try? handle.close() } }
        let resource = try profile.map(PluginFile.stage)
        defer { try? resource?.close() }
        let (response, output, mask): (String, FileHandle?, FileHandle?) = try await call(
            work, seconds: request.purpose == .final ? 30 : 8,
            discard: { (_, output, mask) in
                try? output?.close()
                try? mask?.close()
                lateCompletion()
            }
        ) { (proxy: PluginWorkRPC, finish) in
            proxy.evaluate(session: session as NSUUID, control: control, input: handle, resource: resource) { finish(($0, $1, $2)) }
        }
        defer { try? output?.close(); try? mask?.close() }
        try Task.checkCancellation()
        let value = try PluginControl.decode(EvaluationResponse.self, from: response)
        guard value.id == request.id else { throw PluginFailure.invalidResult }
        if let failure = value.error {
            if failure == "cancelled" { throw CancellationError() }
            throw PluginFailure(rawValue: failure) ?? .rejected
        }
        switch descriptor.kind {
        case .luminanceRange:
            guard output == nil, mask == nil, value.warningBytes == 0, let range = value.range else { throw PluginFailure.invalidResult }
            return .luminanceRange(try LuminanceSuggestion(lower: range.lower, upper: range.upper, feather: range.feather))
        case .proof, .developEffect:
            guard value.range == nil, let output else { throw PluginFailure.invalidResult }
            let pixels = try PluginFile.copy(output, size: frame.byteCount)
            try frame.verify(pixels)
            let image = try PluginImage(frame: frame, pixels: pixels)
            if descriptor.kind == .developEffect {
                guard mask == nil, value.warningBytes == 0 else { throw PluginFailure.invalidResult }
                return .developEffect(image)
            }
            guard value.warningBytes == (mask == nil ? 0 : frame.count) else { throw PluginFailure.invalidResult }
            let warning = try mask.map { try PluginFile.copy($0, size: frame.count) }
            return .proof(image, gamut: warning)
        }
    }

    public func cancel(_ session: UUID, _ request: UUID) {
        (work.remoteObjectProxy as? PluginWorkRPC)?.cancel(session: session as NSUUID, request: request as NSUUID)
    }
}
