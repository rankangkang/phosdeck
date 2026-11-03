import Foundation
import CryptoKit
import Darwin

struct LRCError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// All publications are exclusive, including races after planning. Never use rename() here.
enum SafeFileWriter {
    static func stage(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(".phosdeck-\(UUID().uuidString).partial")
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw posix(L10n.text("app.createTemporaryFile", defaultValue: "Create Temporary File")) }
        close(fd)
        return url
    }

    static func publish(_ staging: URL, to destination: URL) throws {
        guard staging.deletingLastPathComponent().resolvingSymlinksInPath() == destination.deletingLastPathComponent().resolvingSymlinksInPath() else {
            throw LRCError(L10n.text("app.temporaryFilesMustBeInTheDestinationFolderCross", defaultValue: "Temporary files must be in the destination folder; cross-volume publication is not allowed"))
        }
        let fd = Darwin.open(staging.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posix(L10n.text("app.openTemporaryFile", defaultValue: "Open Temporary File")) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posix(L10n.text("app.flushTemporaryFile", defaultValue: "Flush Temporary File")) }
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw posix(L10n.text("app.theDestinationExistsOrTheVolumeDoesNotSupport", defaultValue: "The destination exists or the volume does not support safe publication. Temporary file preserved"))
        }
    }

    static func write(_ data: Data, to destination: URL) throws {
        let staging = try stage(in: destination.deletingLastPathComponent())
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try publish(staging, to: destination)
        } catch {
            // The caller still owns its input data. This staging has never been published.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func requireCapacity(in directory: URL, bytes: Int64) throws {
        // Use real writable blocks. Purgeable-capacity APIs can report an invalid zero
        // for otherwise writable disk images/removable filesystems.
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else { throw posix(L10n.text("app.readAvailableDestinationSpace", defaultValue: "Read Available Destination Space")) }
        let product = info.f_bavail.multipliedReportingOverflow(by: UInt64(info.f_bsize))
        let available = product.overflow ? Int64.max : Int64(clamping: product.partialValue)
        if available < bytes { throw LRCError(L10n.text("app.insufficientDestinationSpaceAtLeastBytesRequiredSavedData", defaultValue: "Insufficient destination space. At least \(bytes) bytes required; saved data preserved")) }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func posix(_ action: String) -> Error {
        let code = errno
        return LRCError("\(action)：\(String(cString: strerror(code))) (\(code))")
    }
}

final class CatalogLock {
    private let descriptor: Int32
    init(fileURL: URL) throws {
        let lockPath = fileURL.lastPathComponent == "Catalog.sqlite" ? fileURL.deletingLastPathComponent().appendingPathComponent("Catalog.lock").path : fileURL.path + ".lock"
        descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SafeFileWriter.posix(L10n.text("app.openCatalogLock", defaultValue: "Open Catalog Lock")) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LRCError(L10n.text("app.theCatalogIsInUseByAnotherInstanceAnd", defaultValue: "The catalog is in use by another instance and cannot be written concurrently"))
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
