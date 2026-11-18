import AppKit
import ExtensionFoundation
import ExtensionKit

extension AppExtensionPoint {
    @Definition
    static var photoTool: AppExtensionPoint {
        Name("PhotoTool")
        UserInterface(false)
        Scope(restriction: .none)
    }
}

func log(_ fields: [String: Any]) {
    guard let line = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    var output = line
    output.append(10)
    FileHandle.standardOutput.write(output)
}

@main
@MainActor
final class ProbeHost: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var displayed: CGImage?

    static func main() {
        let app = NSApplication.shared
        let host = ProbeHost()
        app.delegate = host
        withExtendedLifetime(host) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--manage") {
            showExtensionBrowser()
            return
        }
        Task {
            do {
                try await run(arguments: CommandLine.arguments)
                exit(0)
            } catch {
                log(["event": "error", "detail": String(reflecting: error)])
                exit(1)
            }
        }
    }

    private func showExtensionBrowser() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Phosdeck Plugin Probe"
        let browser = EXAppExtensionBrowserViewController()
        let container = NSViewController()
        container.view = NSView(frame: CGRect(x: 0, y: 0, width: 540, height: 360))
        container.addChild(browser)
        browser.view.frame = container.view.bounds
        browser.view.autoresizingMask = [.width, .height]
        container.view.addSubview(browser.view)
        window.contentViewController = container
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func run(arguments: [String]) async throws {
        let monitorStarted = now()
        let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: .photoTool)
        let state = monitor.state
        let team = try ownTeam()
        log(["event": "discovery", "hostTeam": team, "hostPID": getpid(), "point": AppExtensionPoint.photoTool.id,
             "available": state.identities.map(\.bundleIdentifier), "unapproved": state.unapprovedCount,
             "disabled": state.disabledCount, "ms": elapsed(monitorStarted)])
        if arguments.contains("--snapshot") { return }

        let preview = try Preview()
        let selected = arguments.contains("--vendor") ? vendorID : bundledID
        guard let identity = state.identities.first(where: { $0.bundleIdentifier == selected }) else {
            throw ProbeError("selected extension unavailable: \(selected)")
        }
        let launch = now()
        let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {
            log(["event": "process_interruption", "id": selected])
        }))
        defer { process.invalidate() }
        log(["event": "launch", "id": selected, "ms": elapsed(launch)])
        let boot = try Bootstrap(process)
        defer { withExtendedLifetime(boot) {} }
        if arguments.contains("--inline") {
            let (claim, inline) = try await boot.endpoint(mode: 2)
            let rss = peakRSS()
            do {
                _ = try await receiveInlineFixture(inline, requirement: requirement(id: selected, team: claim))
                throw ProbeError("inline fixture was accepted")
            } catch {
                let failure = error as NSError
                try require(failure.domain == NSCocoaErrorDomain, "expected XPC inline rejection: \(failure)")
                log(["event": "inline_rejected", "code": failure.code, "description": failure.localizedDescription,
                     "peakBefore": rss, "peakAfter": peakRSS()])
            }
            return
        }
        let (teamClaim, endpoint) = try await boot.endpoint()
        let peer = try await connect(endpoint, id: selected, team: teamClaim)
        defer { peer.invalidate() }
        if arguments.contains("--final") {
            let frame = try Frame(10_000, 6_000)
            for revision in 1...3 {
                let result = try await preview.render(frame, remote: peer, revision: revision, strength: Float(revision) / 4, final: true)
                publish(result, mode: "remote_final", frame: frame, revision: revision)
            }
        } else if arguments.contains("--measure") {
            for edge in [960, 2400] {
                try await measure(try Frame(edge, edge * 2 / 3), preview: preview, peer: peer)
            }
        } else {
            let (_, denied) = try await boot.endpoint(mode: 1)
            let exitedPID = try await checkIsolation(endpoint, denied: denied, peer: peer, id: selected, preview: preview)
            peer.invalidate()
            boot.invalidate()
            process.invalidate()
            try await verifyRecovery(identity, exitedPID: exitedPID, preview: preview)
        }
    }

    private func connect(_ endpoint: NSXPCListenerEndpoint, id: String, team: String) async throws -> Peer {
        let start = now()
        let peer = try Peer(endpoint, requirement: requirement(id: id, team: team))
        do {
            let verified = try await peer.describe()
            try require(verified.team == team && verified.version == 1 && verified.pid != getpid(),
                        "inconsistent signing or protocol handshake")
            log(["event": "verified", "id": id, "team": verified.team, "pid": verified.pid, "ms": elapsed(start)])
            return peer
        } catch {
            peer.invalidate()
            throw error
        }
    }

    private func checkIsolation(_ endpoint: NSXPCListenerEndpoint, denied: NSXPCListenerEndpoint, peer: Peer, id: String,
                                preview: Preview) async throws -> Int32 {
        let remote = try await peer.describe()
        let wrong = try Peer(endpoint, requirement: requirement(id: id, team: otherTeam(remote.team)))
        do {
            _ = try await wrong.describe()
            wrong.invalidate()
            throw ProbeError("wrong team accepted")
        } catch {
            wrong.invalidate()
            let failure = error as NSError
            try require(failure.domain == NSCocoaErrorDomain && failure.code == 4102, "expected peer signing failure: \(failure)")
            log(["event": "wrong_team_rejected", "code": failure.code])
        }
        let deniedHost = try Peer(denied, requirement: requirement(id: id, team: remote.team))
        do {
            _ = try await deniedHost.describe()
            deniedHost.invalidate()
            throw ProbeError("incoming host with wrong team accepted")
        } catch {
            deniedHost.invalidate()
            let failure = error as NSError
            try require(failure.domain == NSCocoaErrorDomain && [4097, 4099, 4102].contains(failure.code),
                        "expected incoming signing failure: \(failure)")
            log(["event": "wrong_host_rejected", "code": failure.code])
        }

        let marker = URL.temporaryDirectory.appendingPathComponent("phosdeck-host-\(UUID().uuidString)")
        let challenge = Data("synthetic host test".utf8)
        try challenge.write(to: marker, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: marker) }
        let ownRead = try Data(contentsOf: marker)
        try require(ownRead == challenge, "host could not read its own test data")
        let denial = try await peer.readHostFile(marker.path)
        try require(denial == EPERM || denial == EACCES, "sandbox did not deny synthetic host file: errno \(denial)")
        log(["event": "sandbox_denied", "errno": denial, "hostPID": getpid(), "pluginPID": remote.pid])

        let frame = try Frame(48, 32)
        let original = try await preview.stage(frame)
        try frame.validate(original)
        try original.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: SIMD4<Float>.self)
            try require(p[0].w == 1 && p[frame.width * (frame.height - 1)] == .zero &&
                        p.last!.x > 1 && p.last!.z < 0 && p.last!.w == 0.5, "probe orientation or extended-range alpha fixture changed")
        }
        let input = try readOnlyFile(original)
        defer { try? input.close() }
        for strength: Float in [0, 0.625] {
            let result = try await peer.evaluate(frame, revision: 1, strength: strength, input: input)
            defer { try? result.handle.close() }
            var expected = original
            warm(&expected, strength: strength)
            let actual = try frame.read(result.handle)
            try require(actual == expected, "cross-process pixels differ")
        }
        log(["event": "pixels_match", "bytes": frame.bytes, "strengths": [0, 0.625]])

        let rssBefore = peakRSS()
        let large = try await peer.evaluate(frame, revision: -1, strength: 0, input: input)
        defer { try? large.handle.close() }
        do {
            _ = try frame.read(large.handle)
            throw ProbeError("oversized file accepted")
        } catch {
            try require(error.localizedDescription.hasPrefix("frame length"), "wrong oversize rejection: \(error)")
            log(["event": "oversize_rejected", "peakBefore": rssBefore, "peakAfter": peakRSS()])
        }

        let start = now()
        do {
            _ = try await peer.fault("late", timeout: 40, late: {
                log(["event": "late_reply_discarded", "ms": elapsed(start)])
            })
            throw ProbeError("late reply accepted")
        } catch {
            try require(error.localizedDescription == "deadline exceeded", "wrong timeout error: \(error)")
            log(["event": "timeout", "ms": elapsed(start)])
        }
        try await Task.sleep(for: .milliseconds(260))
        let hold = try Peer(endpoint, requirement: requirement(id: id, team: remote.team))
        do {
            _ = try await hold.fault("hold", timeout: 60)
            throw ProbeError("held request resolved")
        } catch {
            hold.invalidate()
            try require(error.localizedDescription == "deadline exceeded", "wrong hold error: \(error)")
            let responding = try await peer.describe()
            try require(responding == remote, "held call affected other connection")
            log(["event": "held_request_disconnected", "processStillAlive": true, "pid": remote.pid])
        }

        let crashStart = now()
        do {
            _ = try await peer.fault("exit")
            throw ProbeError("exit returned a reply")
        } catch {
            let error = error as NSError
            try require(error.domain == NSCocoaErrorDomain && (error.code == 4097 || error.code == 4099), "expected XPC loss: \(error)")
            log(["event": "worker_exited", "ms": elapsed(crashStart), "code": error.code, "hostPID": getpid()])
        }
        let unchanged = try await preview.render(frame, remote: nil, revision: 2, strength: 0)
        try require(unchanged.image?.width == frame.width, "host render failed after worker exit")
        return remote.pid
    }

    private func verifyRecovery(_ identity: AppExtensionIdentity, exitedPID: Int32, preview: Preview) async throws {
        let start = now()
        for attempt in 1...2 {
            // AppExtensionProcess can briefly return the just-exited process.
            try await Task.sleep(for: .milliseconds(100))
            do {
                let replacement = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity))
                defer { replacement.invalidate() }
                let boot = try Bootstrap(replacement)
                defer { withExtendedLifetime(boot) {} }
                let (team, endpoint) = try await boot.endpoint()
                let peer = try await connect(endpoint, id: identity.bundleIdentifier, team: team)
                defer { peer.invalidate() }
                let new = try await peer.describe()
                try require(new.pid != exitedPID, "worker exit did not restart process")
                let frame = try Frame(48, 32)
                let original = try await preview.stage(frame)
                let input = try readOnlyFile(original)
                defer { try? input.close() }
                let again = try await peer.evaluate(frame, revision: 2, strength: 0, input: input)
                defer { try? again.handle.close() }
                let recovered = try frame.read(again.handle)
                try require(recovered == original, "pixels differ after reconnect")
                log(["event": "recovered", "beforePID": exitedPID, "afterPID": new.pid, "attempt": attempt, "ms": elapsed(start)])
                return
            } catch {
                if attempt == 2 { throw error }
                log(["event": "retry_reconnect", "detail": error.localizedDescription, "ms": elapsed(start)])
            }
        }
    }

    private func measure(_ frame: Frame, preview: Preview, peer: Peer) async throws {
        let cache = try readOnlyFile(await preview.stage(frame))
        defer { try? cache.close() }
        for (mode, remote, cached) in [("in_process", nil, nil), ("remote_fresh", peer, nil), ("remote_cached", peer, cache)] {
            for revision in -2...24 {
                let result = try await preview.render(frame, remote: remote, revision: revision + 10,
                                                      strength: Float(max(0, revision)) / 24, cached: cached)
                if revision > 0 { publish(result, mode: mode, frame: frame, revision: revision) }
            }
        }
        let drag = Drag(host: self, preview: preview, peer: peer, input: cache, frame: frame)
        let start = ContinuousClock.now
        for revision in 1...60 {
            try await Task.sleep(until: start.advanced(by: .nanoseconds(Int64(revision) * 16_666_667)), clock: .continuous)
            drag.update(revision)
        }
        try await drag.finish()
    }

    fileprivate func publish(_ result: ProbeFrame, mode: String, frame: Frame, revision: Int, renderAt: UInt64? = nil) {
        displayed = result.image
        var fields: [String: Any] = result.rows
        fields["event"] = "sample"; fields["mode"] = mode; fields["width"] = frame.width
        fields["height"] = frame.height; fields["revision"] = revision; fields["total"] = elapsed(result.started)
        fields["publish_hop"] = elapsed(result.ready)
        if let renderAt { fields["queue"] = Double(renderAt - result.started) / 1_000_000 }
        log(fields)
    }
}

@MainActor
private final class Drag {
    unowned let host: ProbeHost
    let preview: Preview
    let peer: Peer
    let input: FileHandle
    let frame: Frame
    private var pending: (revision: Int, time: UInt64)?
    private var worker: Task<Void, Error>?
    private var latest = 0
    private var last = 0
    private var applied = 0
    private var maxGap = 0.0
    private var previousPublish: UInt64?

    init(host: ProbeHost, preview: Preview, peer: Peer, input: FileHandle, frame: Frame) {
        self.host = host; self.preview = preview; self.peer = peer; self.input = input; self.frame = frame
    }

    func update(_ revision: Int) {
        pending = (revision, now())
        latest = revision
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while let next = pending {
                pending = nil
                let renderAt = now()
                let result = try await preview.render(frame, remote: peer, revision: next.revision,
                                                      strength: Float(next.revision) / 60, cached: input, started: next.time)
                // Mirrors the current draft lane: progression is allowed during tracking.
                if latest < 60 || next.revision == latest {
                    host.publish(result, mode: "remote_drag", frame: frame, revision: next.revision, renderAt: renderAt)
                    if let previousPublish { maxGap = max(maxGap, elapsed(previousPublish)) }
                    previousPublish = now()
                    last = next.revision
                    applied += 1
                }
            }
        }
    }

    func finish() async throws {
        try await worker?.value
        try require(last == 60, "slider's final revision was not published")
        log(["event": "drag", "width": frame.width, "height": frame.height, "inputs": latest,
             "published": applied, "last": last, "maxPublishGap": maxGap])
    }
}
