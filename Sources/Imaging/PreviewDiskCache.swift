import Foundation
import CryptoKit

/// Own directory only. Never enumerate staging, ImportRecovery, the catalog, or originals.
final class PreviewDiskCache {
    let directory: URL
    var limit: Int64
    private var knownBytes: Int64?
    init(directory: URL, limit: Int64 = 5 * 1024 * 1024 * 1024) throws {
        self.directory = directory; self.limit = limit
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".jpg")
    }
    func read(key: String) throws -> Data? {
        let file = url(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        _ = try FileIdentity.read(file)
        let data = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }
    func store(_ data: Data, key: String) throws {
        let file = url(for: key)
        if knownBytes == nil { try trim() }
        if !FileManager.default.fileExists(atPath: file.path) {
            try SafeFileWriter.write(data, to: file)
            knownBytes = (knownBytes ?? 0) + Int64(data.count)
        }
        // Avoid an O(n) directory scan for every generated thumbnail.
        if (knownBytes ?? 0) > limit { try trim() }
    }
    func files() throws -> [(URL, Int64, Date)] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]).compactMap { url in
            guard url.pathExtension == "jpg", url.deletingPathExtension().lastPathComponent.count == 64,
                  url.deletingPathExtension().lastPathComponent.allSatisfy({ $0.isHexDigit }) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
    func usage() throws -> Int64 {
        let bytes = try files().reduce(Int64(0)) { $0 + $1.1 }
        knownBytes = bytes
        return bytes
    }
    func trim() throws {
        let values = try files().sorted { $0.2 < $1.2 }
        var total = values.reduce(Int64(0)) { $0 + $1.1 }
        for (url, bytes, _) in values where total > limit { try FileManager.default.removeItem(at: url); total -= bytes }
        knownBytes = total
    }
    @discardableResult func clear() throws -> Int64 {
        let entries = try files()
        // Recompute usage if removal fails after deleting only part of the cache.
        knownBytes = nil
        for (url, _, _) in entries { try FileManager.default.removeItem(at: url) }
        knownBytes = 0
        return entries.reduce(0) { $0 + $1.1 }
    }
}
