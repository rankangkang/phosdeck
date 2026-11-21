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
    enum Match: Sendable { case cataloged, suspectedDuplicate }

    let url: URL
    let identity: FileIdentity
    let match: Match?
    let problem: String?
    fileprivate(set) var inspectedPhoto: Photo? = nil
    var id: String { url.path }
    var alreadyImported: Bool { match == .cataloged }
    var isDuplicate: Bool { match != nil }

    func canCheck(skippingDuplicates: Bool) -> Bool {
        problem == nil && (!skippingDuplicates || !isDuplicate)
    }
}

/// Browsing filters and rescans don't overwrite choices made on individual photos.
struct ImportSelection {
    var skipDuplicates = true
    private var choices: [String: Bool] = [:]

    func isChecked(_ item: ImportCandidate) -> Bool {
        item.canCheck(skippingDuplicates: skipDuplicates) && (choices[item.id] ?? !item.isDuplicate)
    }

    mutating func setChecked(_ checked: Bool, for items: some Sequence<ImportCandidate>) {
        for item in items where item.canCheck(skippingDuplicates: skipDuplicates) {
            let checkedByDefault = !item.isDuplicate
            choices[item.id] = checked == checkedByDefault ? nil : checked
        }
    }

    mutating func resetChoices() { choices.removeAll() }
}

private struct ImportCatalogMatches: Sendable {
    private struct Signature: Hashable {
        let size: Int64
        let captureDate: String?
    }

    private struct Original {
        let name: String
        let relativePath: String
        let rootID: String
        let identity: FileIdentity
        let digest: String?
    }

    private var identities = Set<String>()
    private var originals: [Signature: [Original]] = [:]
    private var checkedDigests: [String: String?] = [:]
    private let bookmarks: [String: Data]

    init(_ db: Database) throws {
        bookmarks = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT id, bookmark FROM storageRoot").map {
            ($0["id"], $0["bookmark"])
        })
        let rows = try Row.fetchCursor(db, sql: """
            SELECT source.rootID, source.relativePath, source.identity, source.identityKey, source.captureDate,
                   source.digest, origin.originKey
            FROM photoSource source LEFT JOIN sourceCopyOrigin origin ON origin.sourceID = source.id
            WHERE EXISTS (SELECT 1 FROM photo WHERE sourceID = source.id AND deleted = 0)
            """)
        let decoder = JSONDecoder()
        while let row = try rows.next() {
            identities.insert(row["identityKey"])
            guard let identity = try? decoder.decode(FileIdentity.self, from: row["identity"]), identity.size > 0 else { continue }
            let path: String = row["relativePath"]
            let name = Self.originalName(path: path, origin: row["originKey"])
            let key = Signature(size: identity.size, captureDate: row["captureDate"])
            originals[key, default: []].append(Original(name: Self.filenameKey(name), relativePath: path,
                rootID: row["rootID"], identity: identity, digest: row["digest"]))
        }
    }

    mutating func match(url: URL, identity: FileIdentity, inspected: Photo?, protectedPaths: Set<String>) throws -> ImportCandidate.Match? {
        if identities.contains(identity.key) || protectedPaths.contains(url.path) { return .cataloged }
        guard let inspected else { return nil }
        let key = Signature(size: identity.size, captureDate: inspected.captureDate)
        guard let peers = originals[key] else { return nil }
        let name = Self.filenameKey(url.lastPathComponent)
        if key.captureDate != nil, peers.contains(where: { $0.name == name }) { return .suspectedDuplicate }

        // Only compare bytes in a plausible group. Undated references require the same name;
        // a saved copy digest can identify identical bytes even after a rename.
        var digest: String?
        for original in peers where key.captureDate != nil || original.digest != nil || original.name == name {
            guard let existing = try originalDigest(original) else { continue }
            if digest == nil { digest = try Self.verifiedDigest(url, identity: identity) }
            guard let digest else { return nil }
            if digest == existing { return .suspectedDuplicate }
        }
        return nil
    }

    private mutating func originalDigest(_ original: Original) throws -> String? {
        if let digest = original.digest { return digest }
        if let cached = checkedDigests[original.identity.key] { return cached }
        let digest: String?
        if let bookmark = bookmarks[original.rootID], let lease = try? AccessLease(bookmark: bookmark),
           let url = try? ProjectCopy.child(original.relativePath, of: lease.url.resolvingSymlinksInPath().standardizedFileURL),
           url.resolvingSymlinksInPath().path == url.path {
            digest = try withExtendedLifetime(lease) { try Self.verifiedDigest(url, identity: original.identity) }
        } else {
            digest = nil
        }
        checkedDigests[original.identity.key] = .some(digest)
        return digest
    }

    private static func verifiedDigest(_ url: URL, identity: FileIdentity) throws -> String? {
        try Task.checkCancellation()
        guard (try? FileIdentity.read(url)) == identity else { return nil }
        let digest = try? SafeFileWriter.sha256(url)
        try Task.checkCancellation()
        return (try? FileIdentity.read(url)) == identity ? digest : nil
    }

    private static func filenameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func originalName(path: String, origin: String?) -> String {
        let file = URL(fileURLWithPath: path)
        // Copy provenance stores a volume and the pre-copy path without its extension.
        // Conflict renames keep the original extension.
        let parts = origin?.split(separator: ":", maxSplits: 1)
        guard let parts, parts.count == 2, parts[1].hasPrefix("/") else { return file.lastPathComponent }
        return URL(fileURLWithPath: String(parts[1])).lastPathComponent + "." + file.pathExtension
    }
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

    func preview(source: URL, includeSubfolders: Bool, catalog: CatalogStore,
                 onBatch: (@MainActor @Sendable ([ImportCandidate]) -> Void)? = nil) async throws -> [ImportCandidate] {
        defer { PhotoFileType.releaseValidationCaches() }
        let lease = AccessLease(url: source)
        defer { withExtendedLifetime(lease) {} }
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        try SourceAvailability.check(root: source, file: source)
        var catalogMatches = try await catalog.database.read { try ImportCatalogMatches($0) }
        let paths = try catalog.protectedPaths()
        let outputs = try await catalog.database.read { Set(try String.fetchAll($0, sql: "SELECT destination FROM exportItem")) }
        let root = StorageRoot(id: "preview", path: source.path, bookmark: Data(), label: "preview")
        let next = try ImportPlanner.sourceFileIterator(source, includeSubfolders: includeSubfolders)
        var result = [ImportCandidate]()
        var batch = [ImportCandidate]()
        var lastUpdate = ContinuousClock.now
        while let url = try next() {
            guard ImportPlanner.images.contains(url.pathExtension.lowercased()), !outputs.contains(url.path) else { continue }
            let identity = try FileIdentity.read(url)
            var problem: String?
            var inspected: Photo?
            do { inspected = try autoreleasepool { try Self.inspect(url: url, root: root, rootURL: source) } }
            catch is CancellationError { throw CancellationError() }
            catch { problem = error.localizedDescription }
            let match = try catalogMatches.match(url: url, identity: identity, inspected: inspected, protectedPaths: paths)
            var candidate = ImportCandidate(url: url, identity: identity, match: match, problem: problem)
            candidate.inspectedPhoto = inspected
            result.append(candidate)
            if let onBatch {
                batch.append(candidate)
                if result.count == 1 || lastUpdate.duration(to: .now) >= .milliseconds(150) {
                    await onBatch(batch)
                    batch.removeAll(keepingCapacity: true)
                    lastUpdate = .now
                }
            }
        }
        if !batch.isEmpty { await onBatch?(batch) }
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
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
            var lastProgress = ContinuousClock.now
            for (index, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                var item = ScanReport.Item(url: candidate.url, state: "pending")
                var failure = "source_changed"
                do {
                    guard candidate.problem == nil else { throw LRCError(candidate.problem!) }
                    guard candidate.url.resolvingSymlinksInPath().standardizedFileURL == candidate.url.standardizedFileURL,
                          try FileIdentity.read(candidate.url) == candidate.identity else { throw LRCError(L10n.text("app.theFileChangedAfterPreviewImportItAgain", defaultValue: "The file changed after preview. Import it again")) }
                    failure = "index_failed"
                    let photo: Photo
                    if var inspected = candidate.inspectedPhoto {
                        let prefix = rootURL.standardizedFileURL.path + "/"
                        guard candidate.url.path.hasPrefix(prefix) else { throw LRCError(L10n.text("app.theFileIsOutsideTheAuthorizedRootFolder", defaultValue: "The file is outside the authorized root folder")) }
                        inspected.rootID = root.id
                        inspected.relativePath = String(candidate.url.path.dropFirst(prefix.count))
                        photo = inspected
                    } else {
                        photo = try Self.inspect(url: candidate.url, root: root, rootURL: rootURL)
                    }
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
                if index == 0 || index + 1 == candidates.count || lastProgress.duration(to: .now) >= .milliseconds(500) {
                    await progress(index + 1)
                    lastProgress = .now
                }
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
        if inspected.tiffPageCount != nil {
            guard CGImageSourceCreateThumbnailAtIndex(inspected.source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) != nil, CGImageSourceGetStatusAtIndex(inspected.source, 0) == .statusComplete else {
                throw LRCError(L10n.text("app.cannotDecodeTheImageOrColorProfile", defaultValue: "Cannot decode the image or color profile"))
            }
        }
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
            composite: inspected.composite?.catalogSummary, tiffPageCount: inspected.tiffPageCount)
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
