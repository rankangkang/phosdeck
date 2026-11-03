import Foundation
import GRDB
import UniformTypeIdentifiers

enum CatalogFile {
    static let pathExtension = "phoscat"
    static let legacyExtensions: Set<String> = ["omlcat", "omlrcat"]
    static let contentType = UTType(exportedAs: "dev.cmkk.oh-my-lrc.catalog", conformingTo: .data)

    static func isLegacy(_ url: URL) -> Bool { legacyExtensions.contains(url.pathExtension.lowercased()) }

    static func filename(_ name: String) -> String {
        let url = URL(fileURLWithPath: name)
        if isLegacy(url) || url.pathExtension.lowercased() == pathExtension {
            return url.deletingPathExtension().lastPathComponent + "." + pathExtension
        }
        return name + "." + pathExtension
    }
}

enum CatalogExtensionChoice { case change, keepOriginal, cancel }

/// A confirmation applies to this exact file, not a replacement at the same path.
struct CatalogExtensionChange: Sendable {
    let source: URL
    let destination: URL
    let identity: FileIdentity

    init(source: URL) throws {
        guard CatalogFile.isLegacy(source) else {
            throw LRCError(L10n.text("catalogExtension.notLegacy", defaultValue: "This catalog already uses the current file extension."))
        }
        self.source = source.standardizedFileURL
        destination = self.source.deletingPathExtension().appendingPathExtension(CatalogFile.pathExtension)
        identity = try FileIdentity.read(self.source)
    }

    /// The checkpoint permits deterministic failure coverage after the exclusive rename.
    func perform(afterRename: () throws -> Void = {}) throws -> URL {
        let sourceLock = try CatalogLock(fileURL: source)
        let destinationLock = try CatalogLock(fileURL: destination)
        defer { withExtendedLifetime((sourceLock, destinationLock)) {} }
        guard try FileIdentity.read(source) == identity else {
            throw LRCError(L10n.text("catalogExtension.sourceChanged", defaultValue: "The catalog changed after confirmation. Its name was not changed. Open it again to retry."))
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LRCError(L10n.text("catalogExtension.destinationExists", defaultValue: "A .phoscat file with the same name already exists. Neither catalog was changed."))
        }
        try requireNoRecoveryFiles()
        var configuration = Configuration(); configuration.readonly = true
        let database = try DatabaseQueue(path: source.path, configuration: configuration)
        do { try CatalogStore.validate(database); try database.close() }
        catch { try? database.close(); throw error }
        let digest = try SafeFileWriter.sha256(source)
        try requireNoRecoveryFiles()
        guard try FileIdentity.read(source) == identity else {
            throw LRCError(L10n.text("catalogExtension.sourceChanged", defaultValue: "The catalog changed after confirmation. Its name was not changed. Open it again to retry."))
        }
        // Same folder, fsync and RENAME_EXCL: a late destination race can never overwrite a file.
        try SafeFileWriter.publish(source, to: destination)
        do {
            try afterRename()
            guard try FileIdentity.read(destination) == identity,
                  try SafeFileWriter.sha256(destination) == digest else {
                throw LRCError(L10n.text("catalogExtension.verificationFailed", defaultValue: "The renamed catalog could not be verified."))
            }
        } catch {
            // Restore the source name only while we still own the renamed file; never overwrite a raced source.
            do {
                guard (try? FileIdentity.read(destination).key) == identity.key else { throw error }
                try SafeFileWriter.publish(destination, to: source)
            } catch {
                throw LRCError(L10n.text("catalogExtension.rollbackFailed", defaultValue: "The name change could not be verified or reversed. All remaining files were preserved. Check the catalog folder before continuing.") + "\n" + source.path + "\n" + destination.path)
            }
            throw error
        }
        return destination
    }

    private func requireNoRecoveryFiles() throws {
        guard [source, destination].allSatisfy({ file in
            ["-journal", "-wal", "-shm"].allSatisfy { !FileManager.default.fileExists(atPath: file.path + $0) }
        }) else {
            throw LRCError(L10n.text("catalogExtension.recoveryFilesPresent", defaultValue: "Recovery files exist beside the original or target filename. The name was not changed. Recover the corresponding catalog before retrying."))
        }
    }
}
