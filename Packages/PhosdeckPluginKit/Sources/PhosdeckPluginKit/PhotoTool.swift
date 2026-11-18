import CPhosdeckPluginPixels
import Darwin
import Foundation

public struct ToolDescriptor: Codable, Equatable, Sendable {
    public enum ResultKind: String, Codable, Sendable {
        case proof, luminanceRange, developEffect
    }

    public let key: String
    public let name: String
    public let kind: ResultKind
    public let algorithm: Int

    public init(key: String, name: String, kind: ResultKind, algorithm: Int) {
        self.key = key
        self.name = name
        self.kind = kind
        self.algorithm = algorithm
    }
}

public struct ToolRequest: Codable, Sendable {
    public enum Purpose: String, Codable, Sendable {
        case draft, quality, final
    }
    public enum Parameters: Codable, Equatable, Sendable {
        case proof(intent: PrintIntent, gamutWarning: Bool)
        case luminanceRange
        case developEffect(strength: Double)
    }
    public enum PrintIntent: String, CaseIterable, Codable, Sendable {
        case relativeColorimetric, perceptual
    }

    public let id: UUID
    public let revision: UInt64
    public let purpose: Purpose
    public let parameters: Parameters

    public init(id: UUID = UUID(), revision: UInt64, purpose: Purpose, parameters: Parameters) {
        self.id = id
        self.revision = revision
        self.purpose = purpose
        self.parameters = parameters
    }
}

public struct LuminanceSuggestion: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double
    public let feather: Double

    public init(lower: Double, upper: Double, feather: Double) throws {
        guard lower.isFinite, upper.isFinite, feather.isFinite,
              0 <= lower, lower < upper, upper <= 1, (0...1).contains(feather) else {
            throw PluginFailure.invalidResult
        }
        self.lower = lower
        self.upper = upper
        self.feather = feather
    }
}

/// Tight RGBA32F, little-endian straight alpha, top-to-bottom, extended linear sRGB.
public struct PluginFrame: Equatable, Sendable {
    public static let maxPixels = 60_000_000
    public let width: Int
    public let height: Int
    public var rowBytes: Int { width * 16 }
    public var count: Int { width * height }
    public var byteCount: Int { count * 16 }

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= Self.maxPixels / height else {
            throw PluginFailure.invalidImage
        }
        self.width = width
        self.height = height
    }

    public func verify(_ data: Data) throws {
        guard data.count == byteCount else { throw PluginFailure.invalidImage }
        try data.withUnsafeBytes { raw in
            let chunkSize = 16_384
            for offset in stride(from: 0, to: count, by: chunkSize) {
                try Task.checkCancellation()
                let pixels = raw.baseAddress!.advanced(by: offset * 16)
                guard PhosdeckValidatePluginRGBA32F(pixels, min(chunkSize, count - offset)) else {
                    throw PluginFailure.invalidImage
                }
            }
        }
    }
}

public struct PluginImage: Sendable {
    public let frame: PluginFrame
    public let pixels: Data

    public init(frame: PluginFrame, pixels: Data) throws {
        guard frame.byteCount == pixels.count else { throw PluginFailure.invalidImage }
        self.frame = frame
        self.pixels = pixels
    }
}

public enum ToolResult: Sendable {
    case proof(PluginImage, gamut: Data?)
    case luminanceRange(LuminanceSuggestion)
    case developEffect(PluginImage)
}

public protocol PhotoTool: Sendable {
    var descriptor: ToolDescriptor { get }
    func evaluate(_ request: ToolRequest, input: PluginImage, profile: Data?) async throws -> ToolResult
}

public enum PluginFailure: String, Error, Sendable {
    case unavailable, incompatible, invalidControl, invalidImage, invalidProfile, invalidResult, busy, timeout, interrupted, rejected
}

public enum PluginFile {
    public static let maxProfileBytes = 8 * 1024 * 1024

    /// The producer closes its write end before transferring the read descriptor.
    public static func stage(_ data: Data) throws -> FileHandle {
        var path = URL.temporaryDirectory.appendingPathComponent("phosdeck-tool.XXXXXXXX").path.utf8CString
        let descriptor = path.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { _ = unlink(file) }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? writer.close() }
        try writer.write(contentsOf: data)
        try writer.close()
        let reader = Darwin.open(file, O_RDONLY | O_CLOEXEC)
        guard reader >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: reader, closeOnDealloc: true)
    }

    public static func copy(_ handle: FileHandle, size: Int) throws -> Data {
        guard (1...(PluginFrame.maxPixels * 16)).contains(size) else { throw PluginFailure.invalidImage }
        let fd = handle.fileDescriptor
        func check() throws {
            var status = stat()
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, flags & O_ACCMODE == O_RDONLY, fstat(fd, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG, status.st_size == size else {
                throw PluginFailure.invalidImage
            }
        }
        try check()
        var result = Data(count: size)
        try result.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                let bytes = pread(fd, buffer.baseAddress!.advanced(by: offset), min(size - offset, 4 * 1024 * 1024), off_t(offset))
                if bytes < 0, errno == EINTR { continue }
                guard bytes > 0 else { throw PluginFailure.invalidImage }
                offset += bytes
            }
        }
        try check()
        return result
    }
}
