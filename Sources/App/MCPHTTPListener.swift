import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import Security

struct MCPHTTPListener: Sendable {
    static let host = "127.0.0.1"
    static let path = "/mcp"

    let port: Int
    let token: String
    var endpoint: String { "http://\(Self.host):\(port)\(Self.path)" }
    private let channel: any Channel
    private let eventLoop: MultiThreadedEventLoopGroup
    private let sessions: MCPHTTPSessions
    private let cleanup: Task<Void, Never>

    static func start(name: String, version: String, tools: AppMCPTools) async throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        let generated = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard generated == errSecSuccess else { throw StartError.credentials }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let sessions = MCPHTTPSessions(name: name, version: version, tools: tools)
        let eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connections = MCPHTTPConnections(sessions: sessions, token: token)
        do {
            let channel = try await ServerBootstrap(group: eventLoop)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .childChannelInitializer { connections.install(on: $0) }
                .bind(host: host, port: 0).get()
            guard let port = channel.localAddress?.port else { throw StartError.bind }
            let cleanup = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await sessions.expireIdle()
                }
            }
            return Self(port: port, token: token, channel: channel, eventLoop: eventLoop, sessions: sessions, cleanup: cleanup)
        } catch {
            try? await eventLoop.shutdownGracefully()
            throw error
        }
    }

    func stop() async {
        cleanup.cancel()
        try? await channel.close().get()
        await sessions.stop()
        try? await eventLoop.shutdownGracefully()
        await cleanup.value
    }

    private enum StartError: Error { case credentials, bind }
}

/// All accepted connections use the same event loop.
private final class MCPHTTPConnections: @unchecked Sendable {
    private let sessions: MCPHTTPSessions
    private let token: String
    private var count = 0

    init(sessions: MCPHTTPSessions, token: String) {
        self.sessions = sessions
        self.token = token
    }

    func install(on channel: any Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.preconditionInEventLoop()
        guard count < 16 else { return channel.eventLoop.makeFailedFuture(ConnectionLimit()) }
        count += 1
        channel.closeFuture.whenComplete { [self] _ in count -= 1 }
        return channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
            try channel.pipeline.syncOperations.addHandler(MCPHTTPHandler(sessions: sessions, token: token))
        }
    }

    private struct ConnectionLimit: Error {}
}

/// Accept one request per connection so pipelining cannot queue extra bodies behind a tool call.
private final class MCPHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    private static let maximumBodyBytes = 64 * 1024
    private let sessions: MCPHTTPSessions
    private let token: String
    private var head: HTTPRequestHead?
    private var body = Data()
    private var task: Task<Void, Never>?
    private var deadline: Scheduled<Void>?
    private var finishedReading = false

    init(sessions: MCPHTTPSessions, token: String) {
        self.sessions = sessions
        self.token = token
    }

    func handlerAdded(context: ChannelHandlerContext) { setDeadline(context.channel, seconds: 10) }

    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel()
        task?.cancel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finishedReading else { return }
        let channel = context.channel
        switch unwrapInboundIn(data) {
        case .head(let head):
            if let rejection = reject(head, port: channel.localAddress?.port) {
                respond(rejection, on: channel)
            } else { self.head = head }
        case .body(let bytes):
            guard head != nil else { return }
            guard bytes.readableBytes <= Self.maximumBodyBytes - body.count else {
                respond(.error(statusCode: 413, .invalidRequest("Request body exceeds 64 KiB")), on: channel)
                return
            }
            body.append(contentsOf: bytes.readableBytesView)
        case .end:
            guard let head else { return }
            var headers: [String: String] = [:]
            for (name, value) in head.headers where name.lowercased() != "authorization" {
                let key = name.lowercased()
                headers[key] = headers[key].map { $0 + ", " + value } ?? value
            }
            let request = HTTPRequest(method: head.method.rawValue, headers: headers, body: body, path: head.uri)
            body = Data()
            finishedReading = true
            setDeadline(channel, seconds: 90)
            task = Task { [sessions] in
                await sessions.respond(to: request) { try await Self.write($0, to: channel) }
                channel.close(promise: nil)
            }
        }
    }

    private func setDeadline(_ channel: any Channel, seconds: Int64) {
        deadline?.cancel()
        deadline = channel.eventLoop.scheduleTask(in: .seconds(seconds)) { channel.close(promise: nil) }
    }

    private func reject(_ head: HTTPRequestHead, port: Int?) -> HTTPResponse? {
        let origin = head.headers["origin"]
        guard let port, head.headers["host"] == ["\(MCPHTTPListener.host):\(port)"],
              origin.isEmpty || origin == ["http://\(MCPHTTPListener.host):\(port)"] else {
            return .error(statusCode: 403, .invalidRequest("Loopback Host and Origin required"))
        }
        let authorization = head.headers["authorization"]
        let expected = "Bearer " + token
        guard authorization.count == 1, let value = authorization.first, value.utf8.count == expected.utf8.count,
              zip(value.utf8, expected.utf8).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .error(statusCode: 401, .invalidRequest("Bearer token required"), extraHeaders: ["WWW-Authenticate": "Bearer"])
        }
        guard head.uri == MCPHTTPListener.path else { return .error(statusCode: 404, .invalidRequest("Unknown endpoint")) }
        // This server sends SSE responses to POST. Standalone streams and replay are optional.
        guard head.method == .POST || head.method == .DELETE else {
            return .error(statusCode: 405, .invalidRequest("Method not allowed"), extraHeaders: ["Allow": "POST, DELETE"])
        }
        for header in ["mcp-session-id", "mcp-protocol-version", "content-type"] where head.headers[header].count > 1 {
            return .error(statusCode: 400, .invalidRequest("Repeated request header"))
        }
        if let raw = head.headers.first(name: "content-length"), let size = Int(raw), size > Self.maximumBodyBytes {
            return .error(statusCode: 413, .invalidRequest("Request body exceeds 64 KiB"))
        }
        if head.headers.contains(name: "expect") {
            return .error(statusCode: 417, .invalidRequest("Unsupported Expect header"))
        }
        return nil
    }

    private func respond(_ response: HTTPResponse, on channel: any Channel) {
        finishedReading = true
        task = Task {
            _ = try? await Self.write(response, to: channel)
            channel.close(promise: nil)
        }
    }

    private static func write(_ response: HTTPResponse, to channel: any Channel) async throws -> Int {
        try Task.checkCancellation()
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        headers.replaceOrAdd(name: "Connection", value: "close")
        headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        let body = response.bodyData
        if case .stream = response { headers.add(name: "Transfer-Encoding", value: "chunked") }
        else { headers.add(name: "Content-Length", value: String(body?.count ?? 0)) }
        let head = HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.statusCode), headers: headers)
        try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
        var bytes = 0
        if case .stream(let stream, _) = response {
            for try await event in stream {
                try Task.checkCancellation()
                bytes += event.count
                try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: event)))).get()
            }
        } else if let body, !body.isEmpty {
            bytes = body.count
            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body)))).get()
        }
        _ = try? await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        return bytes
    }
}

actor MCPHTTPSessions {
    private struct SessionID: SessionIDGenerator {
        let value: String
        func generateSessionID() -> String { value }
    }

    private final class Session {
        let id = UUID().uuidString
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccess = ContinuousClock.now
        var requestIDs: Set<String> = []
        var posts = 0
        var responseBytes = 0
        var inFlight = 0

        init(name: String, version: String) {
            server = Server(name: name, version: version, capabilities: .init(tools: .init(listChanged: false)), configuration: .strict)
            transport = StatefulHTTPServerTransport(sessionIDGenerator: SessionID(value: id))
        }
    }

    private let name: String
    private let version: String
    private let tools: AppMCPTools
    private var sessions: [String: Session] = [:]
    private var stopping = false

    init(name: String, version: String, tools: AppMCPTools) {
        self.name = name
        self.version = version
        self.tools = tools
    }

    func respond(to request: HTTPRequest, send: @Sendable (HTTPResponse) async throws -> Int) async {
        guard !stopping, !Task.isCancelled else { return }
        let sessionID = request.header(HTTPHeaderName.sessionID)
        var rpcID: String?
        var initializing = false
        if request.method == "POST" {
            guard let data = request.body, let json = try? JSONDecoder().decode([String: Value].self, from: data),
                  json["jsonrpc"] == "2.0" else {
                _ = try? await send(.error(statusCode: 400, .parseError("Expected a JSON-RPC 2.0 message")))
                return
            }
            if let id = json["id"] {
                let value = id.stringValue ?? id.intValue.map(String.init)
                guard let value, !value.isEmpty, value.utf8.count <= 128, value.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }) else {
                    _ = try? await send(.error(statusCode: 400, .invalidRequest("Invalid JSON-RPC request ID")))
                    return
                }
                rpcID = value
            }
            initializing = rpcID != nil && json["method"] == "initialize"
        }

        let session: Session
        if let sessionID {
            guard let current = sessions[sessionID] else {
                _ = try? await send(.error(statusCode: 404, .invalidRequest("Session expired; initialize a new session")))
                return
            }
            // The SDK retains SSE events for a session. Bound the bytes and message count even without replay.
            if current.posts >= 256 || current.responseBytes >= 12 * 1024 * 1024 {
                if current.inFlight == 0 { await remove(current.id) }
                _ = try? await send(.error(statusCode: 404, .invalidRequest("Session expired; initialize a new session")))
                return
            }
            guard current.inFlight < 4 else {
                _ = try? await send(.error(statusCode: 429, .invalidRequest("Too many concurrent session requests")))
                return
            }
            session = current
        } else {
            guard initializing else {
                _ = try? await send(.error(statusCode: 400, .invalidRequest("Missing MCP session ID")))
                return
            }
            guard sessions.count < 8 else {
                _ = try? await send(.error(statusCode: 429, .invalidRequest("Too many MCP sessions")))
                return
            }
            session = Session(name: name, version: version)
            sessions[session.id] = session
            do {
                let tools = self.tools
                await session.server.withMethodHandler(ListTools.self) { _ in .init(tools: AppMCPTool.allCases.map(\.definition)) }
                await session.server.withMethodHandler(CallTool.self) { await tools.call($0) }
                try await session.server.start(transport: session.transport)
                guard !stopping, sessions[session.id] != nil, !Task.isCancelled else {
                    await session.server.stop()
                    await remove(session.id)
                    return
                }
            } catch {
                await remove(session.id)
                _ = try? await send(.error(statusCode: 500, .internalError("Could not start MCP session")))
                return
            }
        }

        if request.method == "POST" {
            session.posts += 1
            if let rpcID, !session.requestIDs.insert(rpcID).inserted {
                _ = try? await send(.error(statusCode: 400, .invalidRequest("JSON-RPC request ID already used in this session")))
                return
            }
        }
        session.inFlight += 1
        session.lastAccess = .now
        defer { session.inFlight -= 1; session.lastAccess = .now }
        let response = await session.transport.handleRequest(request)
        do {
            session.responseBytes += try await send(response)
        } catch {
            // The peer may close an individual HTTP connection as soon as it has a reply.
            // Charge an interrupted stream for the largest preview the SDK can retain.
            if case .stream = response { session.responseBytes += 6 * 1024 * 1024 }
        }
        if (request.method == "DELETE" && response.statusCode == 200) || (initializing && sessionID == nil && response.statusCode != 200) {
            await remove(session.id)
        }
    }

    func expireIdle() async {
        for id in Array(sessions.keys) {
            if let session = sessions[id], session.inFlight == 0, session.lastAccess.duration(to: .now) >= .seconds(900) {
                await remove(id)
            }
        }
    }

    func stop() async {
        stopping = true
        for id in Array(sessions.keys) { await remove(id) }
    }

    private func remove(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.server.stop()
    }
}
