import ExtensionFoundation
import Foundation

/// XPC failure, timeout and the reply all compete to resolve one RPC.
private final class Reply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    @discardableResult
    func complete(_ result: Result<Value, Error>) -> Bool {
        let saved = lock.withLock {
            let saved = continuation
            continuation = nil
            return saved
        }
        saved?.resume(with: result)
        return saved != nil
    }
}

private func callXPC<Interface, Value>(_ connection: NSXPCConnection, timeout: Int,
                                       late: (@Sendable () -> Void)? = nil,
                                       send: (Interface, @escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let reply = Reply(continuation)
        let deadline = DispatchWorkItem { reply.complete(.failure(ProbeError("deadline exceeded"))) }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeout), execute: deadline)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            if reply.complete(.failure(error)) { deadline.cancel() }
        }) as? Interface else {
            reply.complete(.failure(ProbeError("XPC proxy unavailable")))
            deadline.cancel()
            return
        }
        send(proxy) { result in
            if reply.complete(result) { deadline.cancel() } else { late?() }
        }
    }
}

final class Bootstrap {
    private let connection: NSXPCConnection

    init(_ process: AppExtensionProcess) throws {
        connection = try process.makeXPCConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: ProbeBootstrap.self)
        connection.resume()
    }

    func endpoint(mode: Int = 0) async throws -> (String, NSXPCListenerEndpoint) {
        try await callXPC(connection, timeout: 5_000) { (proxy: ProbeBootstrap, finish) in
            proxy.endpoint(mode: mode) { team, endpoint in
                if let endpoint { finish(.success((team, endpoint))) }
                else { finish(.failure(ProbeError("no endpoint for probe mode"))) }
            }
        }
    }

    func invalidate() { connection.invalidate() }
    deinit { connection.invalidate() }
}

func receiveInlineFixture(_ endpoint: NSXPCListenerEndpoint, requirement: String) async throws -> FileHandle? {
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.setCodeSigningRequirement(requirement)
    connection.remoteObjectInterface = NSXPCInterface(with: InlineReceiver.self)
    connection.resume()
    defer { connection.invalidate() }
    return try await callXPC(connection, timeout: 5_000) { (proxy: InlineReceiver, finish) in
        proxy.fixture { finish(.success($0)) }
    }
}

final class Peer: @unchecked Sendable {
    struct Identity: Equatable {
        let team: String
        let version: Int
        let pid: Int32
    }

    private let connection: NSXPCConnection

    init(_ endpoint: NSXPCListenerEndpoint, requirement: String) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: ProbeRPC.self)
        connection.resume()
    }

    func invalidate() { connection.invalidate() }

    private func call<Value>(timeout: Int = 20_000, late: (@Sendable () -> Void)? = nil,
                             send: (ProbeRPC, @escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await callXPC(connection, timeout: timeout, late: late, send: send)
    }

    func describe() async throws -> Identity {
        try await call(timeout: 5_000) { proxy, finish in
            proxy.describe { team, version, pid in finish(.success(Identity(team: team, version: version, pid: pid))) }
        }
    }

    func evaluate(_ frame: Frame, revision: Int, strength: Float, input: FileHandle) async throws -> ToneReply {
        try await call { proxy, finish in
            proxy.evaluate(width: frame.width, height: frame.height, bytes: frame.bytes, revision: revision, strength: strength,
                           input: input) { returned, output, read, calculate, write, peak, error in
                guard returned == revision, error.isEmpty, let output else {
                    finish(.failure(ProbeError(error.isEmpty ? "response identity or handle mismatch" : error)))
                    return
                }
                finish(.success(ToneReply(handle: output, read: read, calculate: calculate, write: write, peak: peak)))
            }
        }
    }

    func readHostFile(_ path: String) async throws -> Int32 {
        try await call { proxy, finish in proxy.readHostFile(path: path) { finish(.success($0)) } }
    }

    func fault(_ mode: String, timeout: Int = 5_000, late: (@Sendable () -> Void)? = nil) async throws -> Int32 {
        try await call(timeout: timeout, late: late) { proxy, finish in proxy.fault(mode) { finish(.success($0)) } }
    }
}
