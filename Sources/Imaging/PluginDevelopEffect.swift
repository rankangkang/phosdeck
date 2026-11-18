import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PhosdeckPluginKit

struct WarmPrintEffect: Codable, Equatable {
    var strength: Double
    var frozen: FrozenPluginStage?
}

struct FrozenPluginStage: Codable, Equatable {
    let key: String
    let digest: String
    let team: String
    let bundle: String
    let algorithm: Int
    let operation: UUID
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let spotOffsets: [UUID: MaskPoint]

    var fileName: String { key + "-" + digest + ".rgba32f" }

    func validate() throws {
        guard Self.identifiedDigest(key), Self.identifiedDigest(digest), algorithm == 1,
              (1...65535).contains(sourceWidth), (1...65535).contains(sourceHeight),
              team.utf8.count == 10, bundle.hasSuffix(".warm-print") else { throw PluginFailure.invalidResult }
        _ = try PluginFrame(width: width, height: height)
    }

    static func identifiedDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct PluginRenderStage {
    let pixels: PluginImage
    let orientedSize: CGSize
    let offsets: [UUID: MaskPoint]
}

extension EditRecipe {
    private struct EffectIdentity: Encodable {
        let upstream: EditRecipe
        let strength: Double
        let team: String
        let bundle: String
        let algorithm: Int
        let pixelFormat = "RGBA32F-extendedLinearSRGB-straight-top"
    }

    func warmPrintKey(team: String, bundle: String, algorithm: Int) throws -> String {
        guard let warmPrint else { throw PluginFailure.invalidControl }
        var upstream = self
        upstream.warmPrint = nil
        upstream.grain = FilmGrain()
        let input = EffectIdentity(upstream: upstream, strength: warmPrint.strength, team: team, bundle: bundle, algorithm: algorithm)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return PluginStageFiles.digest(try encoder.encode(input))
    }

    func matchingFrozenStage() throws -> FrozenPluginStage? {
        guard let stage = warmPrint?.frozen else { return nil }
        try stage.validate()
        return try warmPrintKey(team: stage.team, bundle: stage.bundle, algorithm: stage.algorithm) == stage.key ? stage : nil
    }

    func requiresWarmPrintStage() throws -> Bool {
        guard let effect = warmPrint, effect.strength > 0 else { return false }
        return try matchingFrozenStage() == nil
    }
}

enum PluginStageFiles {
    private static let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-stages-\(UUID().uuidString)")

    static func directory(create: Bool = true) throws -> URL {
        let dir: URL
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            dir = testDirectory
        } else if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dir = support.appendingPathComponent("Phosdeck/Plugin Stages", isDirectory: true)
        } else {
            throw PluginFailure.unavailable
        }
        if create {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try ProjectCopy.directoryIdentity(dir)
        }
        return dir.resolvingSymlinksInPath().standardizedFileURL
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func url(_ stage: FrozenPluginStage, create: Bool = true) throws -> URL {
        try stage.validate()
        return try directory(create: create).appendingPathComponent(stage.fileName)
    }

    static func check(_ stage: FrozenPluginStage, at url: URL) throws {
        let frame = try PluginFrame(width: stage.width, height: stage.height)
        let identity = try FileIdentity.read(url)
        guard identity.size == frame.byteCount, try SafeFileWriter.sha256(url) == stage.digest,
              try FileIdentity.read(url) == identity else { throw PluginFailure.invalidResult }
    }

    static func read(_ stage: FrozenPluginStage) throws -> PluginRenderStage {
        let source = try url(stage, create: false)
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw LRCError(L10n.text("plugins.frozenStageMissing", defaultValue: "The saved Warm Print image is missing. Restore its stage file from the archived catalog."))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let frame = try PluginFrame(width: stage.width, height: stage.height)
        let bytes = try PluginFile.copy(handle, size: frame.byteCount)
        guard digest(bytes) == stage.digest else { throw PluginFailure.invalidResult }
        return try PluginRenderStage(pixels: PluginImage(frame: frame, pixels: bytes),
                                     orientedSize: CGSize(width: stage.sourceWidth, height: stage.sourceHeight),
                                     offsets: stage.spotOffsets)
    }
}
