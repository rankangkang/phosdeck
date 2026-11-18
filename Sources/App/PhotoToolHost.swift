import ExtensionFoundation
import Foundation
import Observation
import PhosdeckPluginKit

extension AppExtensionPoint {
    @Definition
    static var phosdeckPhotoTool: AppExtensionPoint {
        Name("PhotoTool")
        UserInterface(false)
    }
}

/// Availability and work reservations are shared by all windows and render lanes.
actor PhotoToolHost {
    static let shared = PhotoToolHost()

    private init() {}

    private struct Connection {
        let generation: UUID
        let process: AppExtensionProcess
        let channel: PluginChannel
        var idleRelease: Task<Void, Never>?
    }
    private struct Flight {
        let id: UUID
        let bytes: Int
        var generation: UUID?
        var workerDone = false
        var abandonment: AbandonedPluginWork?
    }

    private var monitoring: Task<AppExtensionPoint.Monitor, Error>?
    private var connected: [String: Connection] = [:]
    private var flights: [String: Flight] = [:]
    private var waiting: Set<String> = []

    func availabilityMonitor() async throws -> AppExtensionPoint.Monitor {
        if let monitoring { return try await monitoring.value }
        let task = Task { try await AppExtensionPoint.Monitor(appExtensionPoint: .phosdeckPhotoTool) }
        monitoring = task
        do { return try await task.value }
        catch { monitoring = nil; throw error }
    }

    #if DEBUG
    func connectionGeneration(for identifier: String) -> UUID? { connected[identifier]?.generation }
    #endif

    func evaluate(key: String, request: ToolRequest, input: PluginImage, stagedInput: FileHandle? = nil, profile: Data? = nil, algorithm: Int? = nil) async throws -> ToolResult {
        guard let identifier = Bundle.main.bundleIdentifier.map({ $0 + "." + key }) else { throw PluginFailure.unavailable }
        let bytes = input.frame.byteCount * 2 + input.frame.count + (profile?.count ?? 0)
        guard !waiting.contains(identifier) else { throw PluginFailure.busy }
        if let preceding = flights[identifier],
           preceding.abandonment == .cancelled || (request.purpose != .draft && preceding.abandonment == nil) {
            // Let a replacement wait for a cancelled draft or the last frame of a drag.
            waiting.insert(identifier)
            defer { waiting.remove(identifier) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while let flight = flights[identifier], flight.abandonment == nil || flight.abandonment == .cancelled,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        try Task.checkCancellation()
        guard flights[identifier] == nil,
              flights.values.reduce(bytes, { $0 + $1.bytes }) <= 2 * 1024 * 1024 * 1024 else { throw PluginFailure.busy }
        let id = UUID()
        connected[identifier]?.idleRelease?.cancel()
        connected[identifier]?.idleRelease = nil
        flights[identifier] = Flight(id: id, bytes: bytes)
        var abandonment: AbandonedPluginWork?
        defer { callerEnded(identifier, id: id, abandonment: abandonment) }

        let connection = try await connection(for: identifier)
        guard connection.channel.descriptor.key == key,
              algorithm == nil || connection.channel.descriptor.algorithm == algorithm else { throw PluginFailure.incompatible }
        try Task.checkCancellation()
        let session: UUID
        do {
            session = try await connection.channel.open()
        } catch {
            disconnect(identifier, generation: connection.generation)
            throw error
        }
        defer { connection.channel.close(session) }
        do {
            return try await connection.channel.evaluate(request, session: session, input: input, stagedInput: stagedInput, profile: profile) {
                Task { await self.workReturned(identifier, id: id) }
            }
        } catch let abandoned as AbandonedPluginWork {
            abandonment = abandoned
            connection.channel.cancel(session, request.id)
            switch abandoned {
            case .cancelled: throw CancellationError()
            case .timeout: throw PluginFailure.timeout
            case .interrupted: throw PluginFailure.interrupted
            }
        }
    }

    private func connection(for identifier: String) async throws -> Connection {
        let monitor = try await availabilityMonitor()
        guard let identity = monitor.identities.first(where: { $0.bundleIdentifier == identifier }) else {
            disconnect(identifier)
            throw PluginFailure.unavailable
        }
        if let connection = connected[identifier] {
            flights[identifier]?.generation = connection.generation
            return connection
        }
        let team = try PluginSignature.ownTeam()
        let generation = UUID()
        flights[identifier]?.generation = generation
        let process = try await AppExtensionProcess(configuration: .init(appExtensionIdentity: identity, onInterruption: {
            Task { self.interrupted(identifier, generation: generation) }
        }))
        do {
            let channel = try await PluginChannel.connect(bootstrap: process.makeXPCConnection(), identifier: identifier, expectedTeam: team)
            guard flights[identifier]?.workerDone == false else { throw PluginFailure.interrupted }
            let connection = Connection(generation: generation, process: process, channel: channel)
            connected[identifier] = connection
            return connection
        } catch {
            process.invalidate()
            throw error
        }
    }

    private func callerEnded(_ identifier: String, id: UUID, abandonment: AbandonedPluginWork?) {
        guard var flight = flights[identifier], flight.id == id else { return }
        if let abandonment, !flight.workerDone {
            flight.abandonment = abandonment
            flights[identifier] = flight
            return
        }
        releaseFlight(identifier, abandonment: abandonment)
    }

    private func workReturned(_ identifier: String, id: UUID) {
        guard var flight = flights[identifier], flight.id == id else { return }
        if let abandonment = flight.abandonment {
            releaseFlight(identifier, abandonment: abandonment)
        } else {
            flight.workerDone = true
            flights[identifier] = flight
        }
    }

    private func interrupted(_ identifier: String, generation: UUID) {
        disconnect(identifier, generation: generation)
        if let flight = flights[identifier], flight.generation == generation {
            workReturned(identifier, id: flight.id)
        }
    }

    private func releaseFlight(_ identifier: String, abandonment: AbandonedPluginWork?) {
        flights.removeValue(forKey: identifier)
        if abandonment == .timeout || abandonment == .interrupted { disconnect(identifier) }
        else { releaseWhenIdle(identifier) }
    }

    private func releaseWhenIdle(_ identifier: String) {
        guard let generation = connected[identifier]?.generation else { return }
        // Keep a short gap between slider frames from forcing a new handshake.
        connected[identifier]?.idleRelease = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, flights[identifier] == nil else { return }
            disconnect(identifier, generation: generation)
        }
    }

    private func disconnect(_ identifier: String, generation: UUID? = nil) {
        guard let connection = connected[identifier],
              generation == nil || generation == connection.generation else { return }
        connected.removeValue(forKey: identifier)
        connection.idleRelease?.cancel()
        connection.process.invalidate()
    }
}

@MainActor
extension AppModel {
    func watchPluginAvailability() async {
        guard let host = Bundle.main.bundleIdentifier,
              let monitor = try? await PhotoToolHost.shared.availabilityMonitor() else { return }
        for await identities in Observations({ monitor.identities }) {
            let available = Set(identities.map(\.bundleIdentifier))
            printProof.extensionAvailable = available.contains(host + ".soft-proof")
            if !available.contains(host + ".select-highlights") { cancelHighlightPreview() }
        }
    }
}
