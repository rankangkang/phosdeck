import Foundation
import GRDB

/// Physical source identity, independent of all edit versions and their lifecycle.
struct CatalogSource: Codable, FetchableRecord, TableRecord, Equatable, Identifiable {
    static let databaseTableName = "photoSource"
    var id: String
    var rootID: String
    var relativePath: String
    var identity: Data
    var identityKey: String
    var digest: String?
    var revision: Int
    var captureDate: String?
    var width: Int
    var height: Int
    var camera: String?
    var availability: String
    var metadata: Data?
    var name: String { URL(fileURLWithPath:relativePath).lastPathComponent }
    var kind: String? {
        let url = URL(fileURLWithPath:relativePath)
        if url.pathExtension.lowercased() == "dng",let metadata,let details = try? JSONDecoder().decode(PhotoMetadata.self,from:metadata),details.composite != nil { return nil }
        if PhotoFileType.isRAW(url) { return "RAW" }
        return ["jpg","jpeg"].contains(url.pathExtension.lowercased()) ? "JPEG" : nil
    }
}
struct RawJpegPair: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "rawJpegPair"
    var id = UUID().uuidString
    var rawSourceID: String
    var jpegSourceID: String
    func partner(of source: String) -> String? { source == rawSourceID ? jpegSourceID : source == jpegSourceID ? rawSourceID : nil }
}
struct PairCandidate: Identifiable {
    var id: String { sources.map(\.id).sorted().joined(separator:":") }
    var sources: [CatalogSource]
    var issue: String?
    var title: String { sources.map(\.relativePath).joined(separator:" ↔ ") }
}
struct PairEndpoint: Codable, Equatable {
    var source: CatalogSource
    var rootPath: String
    var rootBookmark: Data
    var digest: String
}
struct PairProposal: Identifiable, Codable, Equatable {
    var id: String { raw.source.id + ":" + jpeg.source.id }
    var raw: PairEndpoint
    var jpeg: PairEndpoint
}

extension CatalogStore {
    /// Preserve pre-copy parent/stem semantics: flattening two unrelated source
    /// folders must not manufacture an automatic pair at the destination.
    func recordCopyOrigin(_ member: CopyMember) throws {
        guard member.isImage else { return }
        let parent = member.source.deletingLastPathComponent()
        let sensitive = try parent.resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        let stem = member.source.deletingPathExtension().path
        let key = sensitive.map { "\(member.sourceIdentity.device):" + RawJpegPairing.nameKey(stem,caseSensitive:$0) } ?? "unknown:" + member.id
        let identity = try FileIdentity.read(member.destination)
        try database.write { db in
            guard let id = try String.fetchOne(db,sql:"SELECT id FROM photoSource WHERE identityKey=?",arguments:[identity.key]) else { throw LRCError(L10n.text("app.theCopiedSourceIsNotInTheCatalogGrouping", defaultValue: "The copied source is not in the catalog. Grouping provenance cannot be recorded")) }
            try db.execute(sql:"INSERT OR IGNORE INTO sourceCopyOrigin VALUES (?,?)",arguments:[id,key])
        }
    }
    func sources() throws -> [CatalogSource] { try database.read { try CatalogSource.fetchAll($0,sql:"SELECT * FROM photoSource ORDER BY rootID,relativePath,id") } }
    func source(_ id: String) throws -> CatalogSource? { try database.read { try CatalogSource.fetchOne($0,key:id) } }
    func pairedSources(within ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            var result = Set<String>()
            let values = Array(ids)
            for start in stride(from:0,to:values.count,by:250) {
                let chunk = Array(values[start..<min(start+250,values.count)]), placeholders = Array(repeating:"?",count:min(250,values.count-start)).joined(separator:",")
                let pairs = try RawJpegPair.fetchAll(db,sql:"SELECT * FROM rawJpegPair WHERE rawSourceID IN ("+placeholders+") OR jpegSourceID IN ("+placeholders+")",arguments:StatementArguments(chunk+chunk))
                result.formUnion(pairs.flatMap { [$0.rawSourceID,$0.jpegSourceID] })
            }
            return result.intersection(ids)
        }
    }
    func pairs() throws -> [RawJpegPair] { try database.read { try RawJpegPair.order(Column("id")).fetchAll($0) } }
    func pair(sourceID: String) throws -> RawJpegPair? { try database.read { try RawJpegPair.fetchOne($0,sql:"SELECT * FROM rawJpegPair WHERE rawSourceID=? OR jpegSourceID=?",arguments:[sourceID,sourceID]) } }
    /// Restore catalog relationships without requiring online originals. Previously verified
    /// pair IDs survive source relocation and an endpoint with zero active versions.
    @discardableResult func restorePairs(_ values: [RawJpegPair]) throws -> [RawJpegPair] {
        try database.write { db in
            let old = try RawJpegPair.order(Column("id")).fetchAll(db)
            try db.execute(sql:"DELETE FROM rawJpegPair")
            for pair in values { try pair.insert(db) }
            return old
        }
    }
    /// Only accepts frozen, file-verified proposals. Called after re-hashing by the service;
    /// final source/root/identity checks run inside the SAME transaction as both endpoints.
    @discardableResult func establishPairs(_ proposals: [PairProposal]) throws -> [RawJpegPair] {
        try database.write { db in
            let previous = try RawJpegPair.order(Column("id")).fetchAll(db)
            for proposal in proposals {
                guard proposal.raw.source.kind == "RAW", proposal.jpeg.source.kind == "JPEG", proposal.raw.source.id != proposal.jpeg.source.id else { throw LRCError(L10n.text("app.aPairMustContainOneRAWSourceAndOne", defaultValue: "A pair must contain one RAW source and one JPEG source")) }
                for endpoint in [proposal.raw,proposal.jpeg] {
                    guard let current = try CatalogSource.fetchOne(db,key:endpoint.source.id) else { throw LRCError(L10n.text("app.thePairedSourceDoesNotExist", defaultValue: "The paired source does not exist")) }
                    var expected = endpoint.source
                    if expected.digest == nil, current.digest == endpoint.digest { expected.digest = endpoint.digest }
                    guard current == expected,
                          let root = try StorageRoot.fetchOne(db,key:current.rootID), root.path == endpoint.rootPath, root.bookmark == endpoint.rootBookmark,
                          try FileIdentity.read(URL(fileURLWithPath:root.path).appendingPathComponent(current.relativePath)) == JSONDecoder().decode(FileIdentity.self,from:current.identity) else { throw LRCError(L10n.text("app.thePairingPreviewExpiredBecauseSourcesOrLocationsChanged", defaultValue: "The pairing preview expired because sources or locations changed. No pairing was created")) }
                    if let digest = current.digest, digest != endpoint.digest { throw LRCError(L10n.text("app.theSourceDigestDiffersFromSavedEdits", defaultValue: "The source digest differs from saved edits")) }
                }
                let pair = RawJpegPair(rawSourceID:proposal.raw.source.id,jpegSourceID:proposal.jpeg.source.id)
                // Idempotent retry of the same relationship; a different partner is always refused.
                if previous.contains(where: { $0.rawSourceID == pair.rawSourceID && $0.jpegSourceID == pair.jpegSourceID }) { continue }
                try pair.insert(db)
                for endpoint in [proposal.raw,proposal.jpeg] { try db.execute(sql:"UPDATE photoSource SET digest=? WHERE id=?",arguments:[endpoint.digest,endpoint.source.id]) }
            }
            return previous
        }
    }
}

/// No corresponding persisted RAW/JPEG relation was found in LightCraft 4f0b110.
/// import_move.rs/sidecar.rs only guide filename/attachment boundaries. This is native.
actor RawJpegPairing {
    static func nameKey(_ path: String, caseSensitive: Bool) -> String {
        let canonical = path.precomposedStringWithCanonicalMapping
        return caseSensitive ? canonical : canonical.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
    }
    static func metadataConflict(_ a: CatalogSource, _ b: CatalogSource) -> String? {
        if let x = a.camera?.trimmingCharacters(in:.whitespacesAndNewlines), !x.isEmpty,
           let y = b.camera?.trimmingCharacters(in:.whitespacesAndNewlines), !y.isEmpty,
           nameKey(x,caseSensitive:false) != nameKey(y,caseSensitive:false) { return L10n.text("app.cameraMetadataConflictsManualConfirmationRequired", defaultValue: "Camera metadata conflicts. Manual confirmation required") }
        if let x = CaptureTime.parse(a.captureDate), let y = CaptureTime.parse(b.captureDate), x.hasOffset == y.hasOffset, abs(x.seconds-y.seconds) > 2 { return L10n.text("app.captureTimesDifferByMoreThan2SecondsManual", defaultValue: "Capture times differ by more than 2 seconds. Manual confirmation required") }
        let left = a.metadata.flatMap { try? JSONDecoder().decode(PhotoMetadata.self,from:$0) }
        let right = b.metadata.flatMap { try? JSONDecoder().decode(PhotoMetadata.self,from:$0) }
        func differs(_ x: Double?, _ y: Double?, factor: Double = 1) -> Bool {
            guard let x, let y, x.isFinite, y.isFinite, x > 0, y > 0 else { return false }
            // Tolerate small EXIF rounding; this only marks a candidate for manual review.
            return abs(log2(x)-log2(y))*factor > 0.25
        }
        if differs(left?.iso.map { Double($0) },right?.iso.map { Double($0) }) ||
            differs(left?.exposureTime,right?.exposureTime) || differs(left?.aperture,right?.aperture,factor:2) {
            return L10n.text("app.isoShutterOrApertureDiffersByMoreThan1", defaultValue: "ISO, shutter, or aperture differs by more than 1/4 EV. Manual confirmation required")
        }
        return nil
    }
    /// Pure matching: same registered root, exact parent under filesystem semantics,
    /// canonical basename and exactly one source of each type. Copies never multiply candidates.
    static func candidates(sources: [CatalogSource], paired: Set<String>, active: Set<String>, caseSensitive: [String:Bool], within: Set<String>? = nil) -> [PairCandidate] {
        let groups = Dictionary(grouping:sources.filter { $0.kind != nil }) { source -> String in
            let path = URL(fileURLWithPath:"/" + source.relativePath).deletingPathExtension().path
            return source.rootID + ":" + nameKey(path,caseSensitive:caseSensitive[source.rootID] ?? true)
        }
        return groups.values.compactMap { values in
            guard values.contains(where: { $0.kind == "RAW" }), values.contains(where: { $0.kind == "JPEG" }), within == nil || !Set(values.map(\.id)).isDisjoint(with:within!) else { return nil }
            let values = values.sorted { $0.relativePath < $1.relativePath }
            var issue: String?
            if values.count != 2 { issue = L10n.text("app.multipleRAWOrJPEGFilesShareAFolderAnd", defaultValue: "Multiple RAW or JPEG files share a folder and basename. Select two explicit sources for manual pairing") }
            else if caseSensitive[values[0].rootID] == nil { issue = L10n.text("app.sourceOfflineOrFilesystemCaseSensitivityUnknownAutomaticCandidate", defaultValue: "Source offline or filesystem case sensitivity unknown. Automatic candidate skipped") }
            else if values.contains(where: { paired.contains($0.id) }) { return nil }
            else if values.contains(where: { !active.contains($0.id) }) { issue = L10n.text("app.oneSideHasNoActiveEditVersionExistingPairing", defaultValue: "One side has no active edit version. Existing pairing is preserved") }
            else { issue = metadataConflict(values[0],values[1]) }
            return PairCandidate(sources:values,issue:issue)
        }.sorted { $0.title < $1.title }
    }
    func availability(catalog: CatalogStore) throws -> [String:String] {
        let pairs = try catalog.pairs(), wanted = Set(pairs.flatMap { [$0.rawSourceID,$0.jpegSourceID] })
        let roots = try catalog.roots(); var result = [String:String]()
        for source in try catalog.sources() where wanted.contains(source.id) {
            try Task.checkCancellation()
            do {
                guard let root = roots.first(where: { $0.id == source.rootID }) else { throw LRCError(L10n.text("app.theRootRecordDoesNotExist", defaultValue: "The root record does not exist")) }
                let lease = try AccessLease(bookmark:root.bookmark); defer { withExtendedLifetime(lease) {} }
                let url = lease.url.appendingPathComponent(source.relativePath)
                try SourceAvailability.check(root:lease.url,file:url)
                guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self,from:source.identity), source.availability == "available" else { throw LRCError(L10n.text("app.sourceIdentityNeedsVerification", defaultValue: "Source identity needs verification")) }
                result[source.id] = L10n.text("app.online", defaultValue: "Online")
            } catch { result[source.id] = L10n.text("app.offlineUnavailable", defaultValue: "Offline / unavailable: ") + error.localizedDescription }
        }
        return result
    }
    func detect(catalog: CatalogStore, within: Set<String>? = nil) throws -> [PairCandidate] {
        let sources = try catalog.sources(), pairs = try catalog.pairs()
        let active = try catalog.database.read { Set(try String.fetchAll($0,sql:"SELECT DISTINCT sourceID FROM photo WHERE deleted=0")) }
        var semantics = [String:Bool]()
        for root in try catalog.roots() {
            try Task.checkCancellation()
            do {
                let lease = try AccessLease(bookmark:root.bookmark); defer { withExtendedLifetime(lease) {} }
                semantics[root.id] = try lease.url.resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            } catch { /* unknown is reported on candidates, never assumed insensitive */ }
        }
        let origins = try catalog.database.read { db in Dictionary(uniqueKeysWithValues:try Row.fetchAll(db,sql:"SELECT * FROM sourceCopyOrigin").map { row in let id: String = row["sourceID"], key: String = row["originKey"]; return (id,key) }) }
        return Self.candidates(sources:sources,paired:Set(pairs.flatMap { [$0.rawSourceID,$0.jpegSourceID] }),active:active,caseSensitive:semantics,within:within).map { candidate in
            var value = candidate
            let known = candidate.sources.compactMap { origins[$0.id] }
            if candidate.issue == nil, (Set(known).count > 1 || known.contains(where: { $0.hasPrefix("unknown:") })) {
                value.issue = L10n.text("app.originalFoldersOrBasenamesDifferOrFilesystemSemanticsAre", defaultValue: "Original folders or basenames differ, or filesystem semantics are unknown. Matching flat destination names do not imply a pair; review manually")
            }
            return value
        }
    }
    /// Freeze only sources already admitted to the catalog. inspect evaluates an actual
    /// RAW decode and checks actual ImageIO type; JPEG content is never accepted as RAW.
    func prepare(rawID: String, jpegID: String, catalog: CatalogStore) throws -> PairProposal {
        guard let raw = try catalog.source(rawID), let jpeg = try catalog.source(jpegID), raw.kind == "RAW", jpeg.kind == "JPEG" else { throw LRCError(L10n.text("app.selectOnePhysicalRAWSourceAndOnePhysicalJPEG", defaultValue: "Select one physical RAW source and one physical JPEG source")) }
        let roots = try catalog.roots()
        func freeze(_ source: CatalogSource) throws -> PairEndpoint {
            try Task.checkCancellation()
            guard let root = roots.first(where: { $0.id == source.rootID }), source.availability == "available" else { throw LRCError(L10n.text("app.sourceUnavailableExistingPairingPreserved", defaultValue: "Source unavailable; existing pairing preserved")) }
            let lease = try AccessLease(bookmark:root.bookmark); defer { withExtendedLifetime(lease) {} }
            guard lease.url.resolvingSymlinksInPath().path == root.path else { throw LRCError(L10n.text("app.theSourceRootChangedRelocateItBeforePreviewing", defaultValue: "The source root changed. Relocate it before previewing")) }
            let url = lease.url.appendingPathComponent(source.relativePath)
            try SourceAvailability.check(root:lease.url,file:url)
            let inspected = try ReferenceImporter.inspect(url:url,root:root,rootURL:lease.url)
            guard try JSONDecoder().decode(FileIdentity.self,from:inspected.identity) == JSONDecoder().decode(FileIdentity.self,from:source.identity), inspected.identityKey == source.identityKey else { throw LRCError(L10n.text("app.theSourceIdentityChangedRescanToVerifyIt", defaultValue: "The source identity changed. Rescan to verify it")) }
            let digest = try SafeFileWriter.sha256(url)
            guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self,from:source.identity), source.digest == nil || source.digest == digest else { throw LRCError(L10n.text("app.theSourceChangedDuringPairingVerification", defaultValue: "The source changed during pairing verification")) }
            return PairEndpoint(source:source,rootPath:root.path,rootBookmark:root.bookmark,digest:digest)
        }
        return try PairProposal(raw:freeze(raw),jpeg:freeze(jpeg))
    }
    @discardableResult func apply(_ proposals: [PairProposal], catalog: CatalogStore) throws -> [RawJpegPair] {
        var leases = [AccessLease]()
        defer { withExtendedLifetime(leases) {} }
        for proposal in proposals {
            for endpoint in [proposal.raw,proposal.jpeg] {
                try Task.checkCancellation()
                let lease = try AccessLease(bookmark:endpoint.rootBookmark); leases.append(lease)
                guard lease.url.resolvingSymlinksInPath().path == endpoint.rootPath else { throw LRCError(L10n.text("app.thePairingLocationChangedPreviewAgain", defaultValue: "The pairing location changed. Preview again")) }
                let url = lease.url.appendingPathComponent(endpoint.source.relativePath)
                try SourceAvailability.check(root:lease.url,file:url)
                let identity = try JSONDecoder().decode(FileIdentity.self,from:endpoint.source.identity)
                guard try FileIdentity.read(url) == identity, try SafeFileWriter.sha256(url) == endpoint.digest, try FileIdentity.read(url) == identity else { throw LRCError(L10n.text("app.pairedFilesChangedAfterPreviewNoPairingChangesWere", defaultValue: "Paired files changed after preview. No pairing changes were applied")) }
            }
        }
        try Task.checkCancellation()
        return try catalog.establishPairs(proposals)
    }
}
