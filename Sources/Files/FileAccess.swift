import Foundation

final class AccessLease: Sendable, Identifiable {
    let url: URL
    private let scoped: Bool
    private let parent: AccessLease?
    convenience init(url: URL) { self.init(url: url, retaining: nil) }
    init(url: URL, retaining parent: AccessLease?) {
        self.url = url
        self.parent = parent
        scoped = url.startAccessingSecurityScopedResource()
    }
    convenience init(bookmark: Data) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw LRCError(L10n.text("app.folderAuthorizationExpiredSelectTheFolderAgain", defaultValue: "Folder authorization expired. Select the folder again")) }
        self.init(url: url)
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
    static func bookmark(_ url: URL, readOnly: Bool) throws -> Data {
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

struct FileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    static func read(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw SafeFileWriter.posix(L10n.text("app.readFileIdentity", defaultValue: "Read File Identity")) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LRCError(L10n.text("app.onlyLocalRegularFilesAreSupportedSymbolicLinksAre", defaultValue: "Only local regular files are supported. Symbolic links are not followed")) }
        return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
    var key: String { "\(device):\(inode)" }
}
