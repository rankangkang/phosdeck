import Foundation
import ImageIO
import GRDB

struct ScanReport {
    var indexed = 0
    var ignored = 0
    var errors: [String] = []
    var cancelled = false
    var sourceIDs: Set<String> = []
    var importedPhotoIDs: Set<String> = []
}

struct ImportCandidate: Identifiable, Sendable {
    let url: URL
    let identity: FileIdentity
    let alreadyImported: Bool
    let problem: String?
    var id: String { url.path }
}

actor ReferenceImporter {
    func scan(root: StorageRoot, catalog: CatalogStore, progress: @escaping @Sendable (Int) async -> Void) async -> ScanReport {
        var report = ScanReport()
        do {
            let lease = try AccessLease(bookmark: root.bookmark)
            defer { withExtendedLifetime(lease) {} }
            try SourceAvailability.check(root: lease.url, file: lease.url)
            var enumerationErrors = [String]()
            defer { report.errors += enumerationErrors }
            let outputs = try await catalog.database.read { db in Set(try String.fetchAll(db, sql: "SELECT destination FROM exportItem")) }
            guard let enumerator = FileManager.default.enumerator(at: lease.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in enumerationErrors.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true }) else { throw LRCError(L10n.text("app.cannotReadTheFolder", defaultValue: "Cannot read the folder")) }
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
                    let photo = try Self.inspect(url: url, root: root, rootURL: lease.url)
                    try catalog.index(photo)
                    report.indexed += 1
                } catch is CancellationError { throw CancellationError() }
                catch { report.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
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

    func add(source: URL, candidates: [ImportCandidate], collection: String?, catalog: CatalogStore) async -> ScanReport {
        var report = ScanReport()
        do {
            let lease = AccessLease(url: source)
            defer { withExtendedLifetime(lease) {} }
            let source = source.resolvingSymlinksInPath().standardizedFileURL
            try SourceAvailability.check(root: source, file: source)
            let existing = try catalog.roots()
            let root: StorageRoot
            if let parent = existing.first(where: { source.path == $0.path || source.path.hasPrefix($0.path + "/") }) {
                root = parent
            } else {
                root = try catalog.addRoot(url: source, bookmark: AccessLease.bookmark(lease.url, readOnly: true))
            }
            let rootURL = URL(fileURLWithPath: root.path)
            for candidate in candidates {
                try Task.checkCancellation()
                do {
                    guard candidate.problem == nil else { throw LRCError(candidate.problem!) }
                    guard try FileIdentity.read(candidate.url) == candidate.identity else { throw LRCError(L10n.text("app.theFileChangedAfterPreviewImportItAgain", defaultValue: "The file changed after preview. Import it again")) }
                    let photo = try Self.inspect(url: candidate.url, root: root, rootURL: rootURL)
                    let previous = try await catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM photo WHERE identityKey=?", arguments: [photo.identityKey]) }
                    if previous == nil, try catalog.index(photo) {
                        report.indexed += 1
                        report.importedPhotoIDs.insert(photo.id)
                    }
                    else { report.ignored += 1 }
                    if let actualSource = try await catalog.database.read({ try String.fetchOne($0,sql:"SELECT id FROM photoSource WHERE identityKey=?",arguments:[photo.identityKey]) }) { report.sourceIDs.insert(actualSource) }
                    if let collection {
                        let actual = try await catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM photo WHERE identityKey=?", arguments: [photo.identityKey]) }
                        if let actual { try catalog.membership(ids: [actual], collection: collection, add: true) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { report.errors.append("\(candidate.url.lastPathComponent)：\(error.localizedDescription)") }
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
        let inspected = try PhotoFileType.inspectSource(url), source = inspected.source
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { throw LRCError(L10n.text("app.cannotReadImageMetadata", defaultValue: "Cannot read image metadata")) }
        if PhotoFileType.isRAW(url) { try PhotoFileType.validateRAWDecode(PhotoFileType.rawFilter(url)) }
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
            profile: inspected.pngICC == false ? nil : props[kCGImagePropertyProfileName as String] as? String,
            focal35mm: (exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue,
            composite: try MergeProvenance.read(props))
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
