import CryptoKit
import Darwin
import Foundation

/// A sibling staging folder keeps an incomplete project out of its final location.
struct ProjectCopy {
    let staging: URL
    let destination: URL
    private let identity: FileIdentity
    private let parentIdentity: FileIdentity

    init(destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == parent.path else { throw Self.changed(parent) }
        self.destination = destination
        parentIdentity = try Self.directoryIdentity(parent)
        var occupied = stat()
        guard lstat(destination.path, &occupied) != 0, errno == ENOENT else {
            throw LRCError(L10n.text("project.destinationExists", defaultValue: "Choose a new project name or destination:") + "\n" + destination.path)
        }
        staging = parent.appendingPathComponent(".phosdeck-\(UUID().uuidString).partial", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw SafeFileWriter.posix(staging.path) }
        identity = try Self.directoryIdentity(staging)
    }

    func publish() throws {
        let parent = destination.deletingLastPathComponent()
        guard try Self.directoryIdentity(parent).key == parentIdentity.key,
              try Self.directoryIdentity(staging).key == identity.key else { throw Self.changed(staging) }
        try SafeFileWriter.flush(staging)
        try Task.checkCancellation()
        try SafeFileWriter.publish(staging, to: destination)
        do {
            guard try Self.directoryIdentity(destination).key == identity.key else { throw Self.changed(destination) }
            try SafeFileWriter.flush(parent)
        } catch {
            throw LRCError(L10n.text("project.publishedNeedsVerification", defaultValue: "The project was published but needs verification:") + "\n" + destination.path + "\n" + error.localizedDescription)
        }
    }

    func discard() {
        guard (try? Self.directoryIdentity(staging).key) == identity.key else { return }
        try? FileManager.default.removeItem(at: staging)
    }

    func flushDirectories() throws {
        var folders: [URL] = []
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isDirectoryKey],
            errorHandler: { _, error in failure = error; return false }) else { throw Self.changed(staging) }
        for case let item as URL in enumerator {
            if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { folders.append(item) }
        }
        if let failure { throw failure }
        for folder in folders.reversed() { try SafeFileWriter.flush(folder) }
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let prefix = parent.path == "/" ? "/" : parent.path + "/"
        return parent.path == child.path || child.path.hasPrefix(prefix)
    }

    static func directoryIdentity(_ directory: URL) throws -> FileIdentity {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw changed(directory) }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, size: Int64(info.st_size),
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    static func child(_ relative: String, of directory: URL) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LRCError(L10n.text("project.invalidRelativePath", defaultValue: "Invalid relative path in the catalog.") + "\n" + relative)
        }
        return directory.appendingPathComponent(relative)
    }

    /// Hash the bytes read from the original and independently read back the published copy.
    @discardableResult
    static func copy(_ source: URL, to destination: URL, expected: FileIdentity? = nil,
                     digest expectedDigest: String? = nil) throws -> (identity: FileIdentity, digest: String) {
        try Task.checkCancellation()
        guard source.resolvingSymlinksInPath().path == source.path else { throw changed(source) }
        let original = try FileIdentity.read(source)
        if let expected, original != expected, expectedDigest == nil { throw changed(source) }
        let inputFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw SafeFileWriter.posix(source.path) }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(inputFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == original.device, info.st_ino == original.inode else { throw changed(source) }

        let staging = try SafeFileWriter.stage(in: destination.deletingLastPathComponent())
        let created = try FileIdentity.read(staging)
        defer { if (try? FileIdentity.read(staging).key) == created.key { try? FileManager.default.removeItem(at: staging) } }
        let outputFD = Darwin.open(staging.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK)
        guard outputFD >= 0 else { throw SafeFileWriter.posix(staging.path) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var staged = stat()
        guard fstat(outputFD, &staged) == 0, staged.st_mode & S_IFMT == S_IFREG,
              staged.st_dev == created.device, staged.st_ino == created.inode else { throw changed(staging) }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
            try output.write(contentsOf: bytes)
        }
        let times = [info.st_atimespec, info.st_mtimespec]
        guard futimens(output.fileDescriptor, times) == 0 else { throw SafeFileWriter.posix(staging.path) }
        try output.synchronize()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard (expectedDigest == nil || expectedDigest == digest),
              try FileIdentity.read(source) == original else { throw changed(source) }
        let copied = try FileIdentity.read(staging)
        guard copied.key == created.key, copied.size == original.size else { throw changed(staging) }
        try Task.checkCancellation()
        try SafeFileWriter.publish(staging, to: destination)
        guard try FileIdentity.read(destination) == copied,
              try SafeFileWriter.sha256(destination) == digest,
              try FileIdentity.read(destination) == copied else { throw changed(destination) }
        return (copied, digest)
    }

    static func changed(_ url: URL) -> LRCError {
        LRCError(L10n.text("project.fileChanged", defaultValue: "The file or folder could not be verified:") + "\n" + url.path)
    }
}
