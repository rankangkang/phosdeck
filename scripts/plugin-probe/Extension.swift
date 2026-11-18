import Darwin
import ExtensionFoundation
import Foundation

@main
struct ToneExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "dev.cmkk.phosdeck.pluginprobe", name: "PhotoTool")
    }

    var configuration: ConnectionHandler {
        ConnectionHandler(onConnection: { connection in
            guard let team = try? ownTeam(),
                  let hostTeam = Bundle.main.object(forInfoDictionaryKey: "ProbeHostTeam") as? String else { return false }
            // Setting a requirement on this ExtensionFoundation connection
            // crashes on macOS 26.6.2. Limit it to exchanging a work endpoint.
            connection.exportedInterface = NSXPCInterface(with: ProbeBootstrap.self)
            connection.exportedObject = ToneBootstrap(team: team, hostTeam: hostTeam)
            connection.resume()
            return true
        })
    }
}

private final class ToneBootstrap: NSObject, ProbeBootstrap, NSXPCListenerDelegate {
    let team: String
    let hostTeam: String
    private var listeners: [Int: NSXPCListener] = [:]

    init(team: String, hostTeam: String) { self.team = team; self.hostTeam = hostTeam }

    deinit { for listener in listeners.values { listener.invalidate() } }

    func endpoint(mode: Int, reply: @escaping (String, NSXPCListenerEndpoint?) -> Void) {
        guard (0...2).contains(mode),
              let expected = try? requirement(id: hostID, team: mode == 1 ? otherTeam(hostTeam) : hostTeam) else {
            reply(team, nil)
            return
        }
        if let existing = listeners[mode] {
            reply(team, existing.endpoint)
            return
        }
        let listener = NSXPCListener.anonymous()
        listener.setConnectionCodeSigningRequirement(expected)
        listener.delegate = mode == 2 ? InlineFixture.shared : self
        listeners[mode] = listener
        listener.activate()
        reply(team, listener.endpoint)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ProbeRPC.self)
        connection.exportedObject = ToneService(team: team)
        connection.resume()
        return true
    }
}

@objc(PhosdeckPluginProbeInlineSender)
private protocol InlineSender {
    func fixture(reply: @escaping (Data) -> Void)
}

private final class InlineFixture: NSObject, NSXPCListenerDelegate, InlineSender {
    static let shared = InlineFixture()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: InlineSender.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func fixture(reply: @escaping (Data) -> Void) { reply(Data(count: 32 * 1024 * 1024)) }
}

private final class ToneService: NSObject, ProbeRPC {
    let team: String
    private let compute = DispatchQueue(label: "dev.cmkk.phosdeck.pluginprobe.compute", qos: .userInitiated)
    private var heldReply: ((Int32) -> Void)?

    init(team: String) { self.team = team }

    func describe(reply: @escaping (String, Int, Int32) -> Void) {
        reply(team, 1, getpid())
    }

    func evaluate(width: Int, height: Int, bytes: Int, revision: Int, strength: Float, input: FileHandle,
                  reply: @escaping (Int, FileHandle?, Double, Double, Double, Int64, String) -> Void) {
        compute.async {
            defer { try? input.close() }
            do {
                let frame = try Frame(width, height)
                try require(bytes == frame.bytes && (0...1).contains(strength), "invalid pixel count or strength")
                if revision == -1 {
                    let oversized = try readOnlyFile { handle in
                        try require(ftruncate(handle.fileDescriptor, off_t(bytes + 32 * 1024 * 1024)) == 0,
                                    "create oversized test fixture")
                    }
                    reply(revision, oversized, 0, 0, 0, peakRSS(), "")
                    return
                }
                let readStart = now()
                var pixels = try frame.read(input)
                let readMs = elapsed(readStart)
                let toneStart = now()
                warm(&pixels, strength: strength)
                let toneMs = elapsed(toneStart)
                let writeStart = now()
                let output = try readOnlyFile(pixels)
                reply(revision, output, readMs, toneMs, elapsed(writeStart), peakRSS(), "")
            } catch {
                reply(revision, nil, 0, 0, 0, peakRSS(), error.localizedDescription)
            }
        }
    }

    func readHostFile(path: String, reply: @escaping (Int32) -> Void) {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        if fd >= 0 {
            _ = close(fd)
            reply(0)
        } else {
            reply(errno)
        }
    }

    func fault(_ mode: String, reply: @escaping (Int32) -> Void) {
        switch mode {
        case "late":
            compute.asyncAfter(deadline: .now() + .milliseconds(200)) { reply(getpid()) }
        case "hold":
            heldReply = reply
        case "exit":
            _exit(73)
        default:
            reply(getpid())
        }
    }
}
