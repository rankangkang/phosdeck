import Foundation
import ImageIO
import GRDB

struct ScanReport {
    struct Item {
        let url: URL
        var state: String
        var photoID: String? = nil
        var errorCode: String? = nil
    }
    var indexed = 0
    var ignored = 0
    var errors: [String] = []
    var cancelled = false
    var sourceIDs: Set<String> = []
    var importedPhotoIDs: Set<String> = []
    var items: [Item] = []
    var wroteCatalog = false
}

struct ImportCandidate: Identifiable, Sendable {
    let url: URL
    let identity: FileIdentity
    let alreadyImported: Bool
    let problem: String?
    var id: String { url.path }
}

actor ReferenceImporter {
    func scan(root: StorageRoot, catalog: CatalogStore, directory: String = "", includeSubfolders: Bool = true,
              recordItems: Bool = false, progress: @escaping @Sendable (Int) async -> Void) async -> ScanReport {
        var report = ScanReport()
        do {
            let scope = FolderReviewScope(root: root, directory: directory)
            let lease = try FolderReviewService.access(scope, catalog: catalog)
            defer { withExtendedLifetime(lease) {} }
            var enumerationErrors = [String]()
            defer { report.errors += enumerationErrors }
            let outputs = try await catalog.database.read { db in Set(try String.fetchAll(db, sql: "SELECT destination FROM exportItem")) }
            var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if !includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
            guard let enumerator = FileManager.default.enumerator(at: scope.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey],
                options: options, errorHandler: { url, error in enumerationErrors.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true }) else { throw LRCError(L10n.text("app.cannotReadTheFolder", defaultValue: "Cannot read the folder")) }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey])
                if url.lastPathComponent == "ImportRecovery" || values.isSymbolicLink == true || values.isPackage == true || values.isUbiquitousItem == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    report.ignored += 1; continue
                }
                guard values.isRegularFile == true, !outputs.contains(url.path) else { continue }
                guard ImportPlanner.images.contains(url.pathExtension.lowercased()) else { report.ignored += 1; continue }
                do {
                    let photo = try Self.inspect(url: url, root: root, rootURL: URL(fileURLWithPath: root.path))
                    let added = try catalog.index(photo)
                    report.wroteCatalog = true
                    if added { report.importedPhotoIDs.insert(photo.id) }
                    if recordItems { report.items.append(.init(url: url, state: added ? "indexed" : "already_indexed", photoID: added ? photo.id : nil)) }
                    report.indexed += 1
                } catch is CancellationError { throw CancellationError() }
                catch {
                    report.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    if recordItems { report.items.append(.init(url: url, state: "failed", errorCode: "scan_failed")) }
                }
                if report.indexed % 25 == 0 { await progress(report.indexed) }
            }
        } catch is CancellationError { report.cancelled = true }
        catch { report.errors.append(error.localizedDescription) }
        return report
    }

    func preview(source: URL, includeSubfolders: Bool, catalog: CatalogStore) throws -> [ImportCandidate] {
        let lease = AccessLease(url: source)
        defer { withExtendedLifetime(lease) {} }
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        try SourceAvailability.check(root: source, file: source)
        let photos = try catalog.photos()
        let identities = Set(photos.map(\.identityKey))
        let paths = try catalog.protectedPaths()
        let outputs = try catalog.database.read { Set(try String.fetchAll($0, sql: "SELECT destination FROM exportItem")) }
        let root = StorageRoot(id: "preview", path: source.path, bookmark: Data(), label: "preview")
        return try ImportPlanner.sourceFiles(source, includeSubfolders: includeSubfolders)
            .filter { ImportPlanner.images.contains($0.pathExtension.lowercased()) && !outputs.contains($0.path) }
            .map { url in
                try Task.checkCancellation()
                let identity = try FileIdentity.read(url)
                var problem: String?
                do { _ = try Self.inspect(url: url, root: root, rootURL: source) }
                catch is CancellationError { throw CancellationError() }
                catch { problem = error.localizedDescription }
                return ImportCandidate(url: url, identity: identity, alreadyImported: identities.contains(identity.key) || paths.contains(url.path), problem: problem)
            }
    }

    func add(source: URL, candidates: [ImportCandidate], collection: String?, catalog: CatalogStore, recordItems: Bool = false,
             progress: @escaping @Sendable (Int) async -> Void = { _ in }) async -> ScanReport {
        var report = ScanReport()
        do {
            let lease = AccessLease(url: source)
            defer { withExtendedLifetime(lease) {} }
            let source = source.resolvingSymlinksInPath().standardizedFileURL
            try SourceAvailability.check(root: source, file: source)
            try Task.checkCancellation()
            let existing = try catalog.roots()
            let root: StorageRoot
            if let parent = existing.first(where: { source.path == $0.path || source.path.hasPrefix($0.path + "/") }) {
                root = parent
            } else {
                root = try catalog.addRoot(url: source, bookmark: AccessLease.bookmark(lease.url, readOnly: true))
                report.wroteCatalog = true
            }
            let rootURL = URL(fileURLWithPath: root.path)
            for (index, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                if recordItems && index % 16 == 0 { await progress(index) }
                var item = ScanReport.Item(url: candidate.url, state: "pending")
                var failure = "source_changed"
                do {
                    guard candidate.problem == nil else { throw LRCError(candidate.problem!) }
                    guard candidate.url.resolvingSymlinksInPath().standardizedFileURL == candidate.url.standardizedFileURL,
                          try FileIdentity.read(candidate.url) == candidate.identity else { throw LRCError(L10n.text("app.theFileChangedAfterPreviewImportItAgain", defaultValue: "The file changed after preview. Import it again")) }
                    failure = "index_failed"
                    let photo = try Self.inspect(url: candidate.url, root: root, rootURL: rootURL)
                    guard try JSONDecoder().decode(FileIdentity.self, from: photo.identity) == candidate.identity else {
                        failure = "source_changed"
                        throw LRCError(L10n.text("app.theFileChangedAfterPreviewImportItAgain", defaultValue: "The file changed after preview. Import it again"))
                    }
                    let previous = try await catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM photo WHERE identityKey=?", arguments: [photo.identityKey]) }
                    try Task.checkCancellation()
                    item.state = "already_indexed"
                    item.photoID = previous
                    if previous == nil {
                        let added = try catalog.index(photo)
                        report.wroteCatalog = true
                        if added {
                            report.indexed += 1
                            report.importedPhotoIDs.insert(photo.id)
                            item.state = "indexed"
                            item.photoID = photo.id
                        } else {
                            report.ignored += 1
                            item.state = "needs_review"
                        }
                    }
                    else { report.ignored += 1 }
                    if let actualSource = try await catalog.database.read({ try String.fetchOne($0,sql:"SELECT id FROM photoSource WHERE identityKey=?",arguments:[photo.identityKey]) }) { report.sourceIDs.insert(actualSource) }
                    if let collection {
                        failure = "collection_update_failed"
                        if let actual = item.photoID {
                            try catalog.membership(ids: [actual], collection: collection, add: true)
                            report.wroteCatalog = true
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    report.errors.append("\(candidate.url.lastPathComponent)：\(error.localizedDescription)")
                    item.state = item.photoID == nil ? "failed" : "partially_indexed"
                    item.errorCode = failure
                }
                if recordItems { report.items.append(item) }
            }
        } catch is CancellationError { report.cancelled = true }
        catch { report.errors.append(error.localizedDescription) }
        return report
    }

    func refreshMetadata(photo: Photo, root: StorageRoot, catalog: CatalogStore) throws {
        let lease = try AccessLease(bookmark: root.bookmark)
        defer { withExtendedLifetime(lease) {} }
        let url = lease.url.appendingPathComponent(photo.relativePath)
        try SourceAvailability.check(root: lease.url, file: url)
        try catalog.index(Self.inspect(url: url, root: root, rootURL: lease.url))
    }

    static func inspect(url: URL, root: StorageRoot, rootURL: URL) throws -> Photo {
        let identity = try FileIdentity.read(url)
        let inspected = try PhotoFileType.inspectSource(url),props = inspected.properties
        if PhotoFileType.isRAW(url) && inspected.composite == nil { try PhotoFileType.validateRAWDecode(PhotoFileType.rawFilter(url)) }
        if url.pathExtension.lowercased() == "dng",inspected.composite != nil { _ = try MergeDNGCodec.open(url)?.image() }
        guard try FileIdentity.read(url) == identity else { throw LRCError(L10n.text("app.theSourceChangedDuringImportVerification", defaultValue: "The source changed during import verification")) }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let prefix = rootURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { throw LRCError(L10n.text("app.theFileIsOutsideTheAuthorizedRootFolder", defaultValue: "The file is outside the authorized root folder")) }
        let details = PhotoMetadata(lens: exif?[kCGImagePropertyExifLensModel as String] as? String,
            iso: (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first,
            aperture: exif?[kCGImagePropertyExifFNumber as String] as? Double,
            exposureTime: exif?[kCGImagePropertyExifExposureTime as String] as? Double,
            focalLength: exif?[kCGImagePropertyExifFocalLength as String] as? Double,
            orientation: props[kCGImagePropertyOrientation as String] as? Int,
            profile: inspected.composite != nil ? "sRGB IEC61966-2.1 Linear" : inspected.pngICC == false ? nil : props[kCGImagePropertyProfileName as String] as? String,
            focal35mm: (exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue,
            composite: inspected.composite?.catalogSummary)
        var captured = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
        if let original = captured {
            var precise = original
            if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal as String] as? String, !sub.isEmpty { precise += "." + sub }
            if let zone = exif?["OffsetTimeOriginal"] as? String, !zone.isEmpty { precise += zone }
            captured = precise
        }
        return Photo(id: UUID().uuidString, rootID: root.id, relativePath: String(url.standardizedFileURL.path.dropFirst(prefix.count)),
                     identity: try JSONEncoder().encode(identity), identityKey: identity.key,
                     captureDate: captured,
                     width: props[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                     height: props[kCGImagePropertyPixelHeight as String] as? Int ?? 0,
                     camera: tiff?[kCGImagePropertyTIFFModel as String] as? String, metadata: try JSONEncoder().encode(details))
    }
}
