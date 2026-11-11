import Foundation
import GRDB

/// Pure calendar-day planning. No fallback to mtime, import time, locale, or time zone.
enum DateLayout: String, Codable, CaseIterable {
    case yearMonthDay, compact, full, flat
    var title: String { switch self { case .yearMonthDay: return L10n.text("app.yearMonthDay", defaultValue: "Year / Month-Day"); case .compact: return L10n.text("app.yearMonthDay_983", defaultValue: "Year / MonthDay"); case .full: return L10n.text("app.yearYearMonthDay", defaultValue: "Year / Year-Month-Day"); case .flat: return L10n.text("app.specifiedFolder", defaultValue: "Specified Folder") } }
    func directory(date: String?) throws -> String {
        if self == .flat { return "" }
        guard let date else { throw LRCError(L10n.text("app.dateConfirmationRequiredEnterAnArchiveDate", defaultValue: "Date confirmation required: enter an archive date")) }
        let fields = date.prefix(10).replacingOccurrences(of: ":", with: "-").split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { throw LRCError(L10n.text("app.theDateFormatMustBeYyyyMMDd", defaultValue: "The date format must be yyyy-MM-dd")) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: fields[0], month: fields[1], day: fields[2])
        guard (1...9999).contains(fields[0]), let value = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: value) == components else { throw LRCError(L10n.text("app.invalidCaptureDate", defaultValue: "Invalid capture date")) }
        let year = String(format: "%04d", fields[0]), month = String(format: "%02d", fields[1]), day = String(format: "%02d", fields[2])
        switch self { case .yearMonthDay: return "\(year)/\(month)-\(day)"; case .compact: return "\(year)/\(month)\(day)"; case .full: return "\(year)/\(year)-\(month)-\(day)"; case .flat: return "" }
    }
}
enum ConflictPolicy: String, Codable, CaseIterable { case uniqueName, skip, overwrite
    var title: String { switch self { case .uniqueName: return L10n.text("app.useUniqueNames", defaultValue: "Use Unique Names"); case .skip: return L10n.text("app.skipFilenameConflicts", defaultValue: "Skip Filename Conflicts"); case .overwrite: return L10n.text("app.restrictedOverwriteKeepPreviousFiles", defaultValue: "Restricted Overwrite (Keep Previous Files)") } }
}
struct CopyMember: Codable, Identifiable {
    var id = UUID().uuidString
    var source: URL
    var destination: URL
    var sourceIdentity: FileIdentity
    var digest: String
    var targetIdentity: FileIdentity?
    var targetDigest: String?
    var staging: URL?
    var stagingCreatedIdentity: FileIdentity?
    var stagedIdentity: FileIdentity?
    var reusedIdentity: FileIdentity?
    var recovery: URL?
    var state = "planned"
    var recoveryState: String?
    var isImage: Bool
}
struct CopyGroup: Codable, Identifiable {
    var id = UUID().uuidString
    var sourceKey: String?
    var members: [CopyMember]
    var policy: ConflictPolicy
    var selected = true
    var diagnostic: String?
    var state = "planned"
    var requiresConflictCheck: Bool?
    var allowsRename: Bool?
    var allowsOverwrite: Bool?
}
struct CopyPlan: Codable, Identifiable {
    var id = UUID().uuidString
    var version = 2
    var sourceRoot: URL
    var sourceBookmark: Data
    var targetRoot: URL
    var targetBookmark: Data
    var layout: DateLayout
    var skipIdentical: Bool
    var groups: [CopyGroup]
    var omitted: [String]
    var attachmentCandidates: [URL]?
    var pairAfterImport = false
    var collectionID: String?
    var state = "planned"

    var canResume: Bool {
        state != "completed" && groups.contains {
            $0.selected && !$0.members.isEmpty && !["completed", "skippedConflict"].contains($0.state)
        }
    }
    var resuming: CopyPlan {
        var plan = self
        for index in plan.groups.indices where ["cancelled", "needsReview"].contains(plan.groups[index].state) && !plan.groups[index].members.isEmpty {
            plan.groups[index].state = "planned"
            plan.groups[index].diagnostic = nil
        }
        return plan
    }
}

/// Preview-only choices. Execution uses the fully resolved, persisted CopyPlan.
struct ImportChoices {
    var policies: [String: ConflictPolicy] = [:]
    var dates: [String: String] = [:]
    var directories: [String: String] = [:]
    var attachments: [String: String] = [:] // source path -> explicitly selected group key
}

actor ImportPlanner {
    static let images = PhotoFileType.editableExtensions
    func plan(source: URL, target: URL, layout: DateLayout, policy: ConflictPolicy, skipIdentical: Bool,
              dateOverride: String?, confirmSidecars: Bool, catalog: CatalogStore, choices: ImportChoices = ImportChoices(), selectedPaths: Set<String>? = nil, includeSubfolders: Bool = true, deferConflicts: Bool = false, includeSidecars: Bool = true) throws -> CopyPlan {
        let sourceLease = AccessLease(url: source), targetLease = AccessLease(url: target)
        defer { withExtendedLifetime([sourceLease, targetLease]) {} }
        let src = source.resolvingSymlinksInPath().standardizedFileURL
        let dst = target.resolvingSymlinksInPath().standardizedFileURL
        guard src != dst, !dst.path.hasPrefix(src.path + "/") else { throw LRCError(L10n.text("app.theDestinationCannotEqualOrBeInsideTheSource", defaultValue: "The destination cannot equal or be inside the source. Use reference import or choose another folder")) }
        try SourceAvailability.check(root: src, file: src)
        let files = try Self.sourceFiles(src, includeSubfolders: includeSubfolders)
        let all = files.filter { url in
            guard let selectedPaths else { return true }
            return Self.images.contains(url.pathExtension.lowercased()) ? selectedPaths.contains(url.path) : true
        }
        var omitted = [String]()
        let grouped = Dictionary(grouping: all, by: { $0.deletingPathExtension().path })
        let groupKeys = Set(grouped.filter { $0.value.contains { Self.images.contains($0.pathExtension.lowercased()) } }.keys)
        let nonImages = all.filter { !Self.images.contains($0.pathExtension.lowercased()) }
        for (path, key) in choices.attachments {
            guard nonImages.contains(where: { $0.path == path }), (key.isEmpty || groupKeys.contains(key)) else {
                throw LRCError(L10n.text("app.attachmentsOrAssociatedGroupsChangedSelectThemAgain", defaultValue: "Attachments or associated groups changed. Select them again"))
            }
        }
        let managed = try catalog.photos()
        let protectedPaths = try catalog.protectedPaths()
        let sourceIDs = Set(try all.map { try FileIdentity.read($0).key })
        let activeTargets = try catalog.database.read { try String.fetchAll($0, sql: "SELECT destination FROM exportItem WHERE state NOT IN ('completed','cancelled','failed')") }
        let activeImports = try CopyImporter.savedPlans(catalog: catalog).filter { $0.state != "completed" }
            .flatMap { $0.groups.flatMap(\.members).map { $0.destination.path } }
        var reserved = Set<String>()
        var groups = [CopyGroup]()
        let temporaryRoot = StorageRoot(id: "preview", path: src.path, bookmark: Data(), label: "preview")
        for (key, candidates) in grouped.sorted(by: { $0.key < $1.key }) {
            let photos = candidates.filter { Self.images.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            guard let primary = photos.first else { omitted += candidates.filter { (choices.attachments[$0.path] ?? "").isEmpty }.map { $0.lastPathComponent + L10n.text("app.noAssociatedImageOmitted", defaultValue: ": no associated image; omitted") }; continue }
            let groupPolicy = choices.policies[key] ?? policy
            let sidecars = candidates.filter { includeSidecars && ["xmp", "acr"].contains($0.pathExtension.lowercased()) && choices.attachments[$0.path] == nil }
            let explicit = nonImages.filter { choices.attachments[$0.path] == key }.sorted { $0.path < $1.path }
            let unknown = candidates.filter { !Self.images.contains($0.pathExtension.lowercased()) && !["xmp", "acr"].contains($0.pathExtension.lowercased()) }
            omitted += unknown.filter { (choices.attachments[$0.path] ?? "").isEmpty }.map { $0.lastPathComponent + L10n.text("app.unknownAttachmentOmitted", defaultValue: ": unknown attachment; omitted") }
            do {
                if !sidecars.isEmpty && !confirmSidecars { throw LRCError(L10n.text("app.attachmentAssociationNeedsConfirmationXMPACRFilesCanBe", defaultValue: "Attachment association needs confirmation. XMP/ACR files can be copied / renamed together only when matched by filename")) }
                let metadata = try ReferenceImporter.inspect(url: primary, root: temporaryRoot, rootURL: src)
                for photo in photos.dropFirst() { _ = try ReferenceImporter.inspect(url: photo, root: temporaryRoot, rootURL: src) }
                let subdir = try choices.directories[key].flatMap { $0.isEmpty ? nil : $0 } ?? layout.directory(date: choices.dates[key].flatMap { $0.isEmpty ? nil : $0 } ?? dateOverride ?? metadata.captureDate)
                guard !subdir.hasPrefix("/"), !subdir.split(separator: "/").contains(".."),
                      subdir.split(separator: "/").first?.lowercased() != "importrecovery" else { throw LRCError(L10n.text("app.groupFoldersMustBeInsideTheSelectedDestinationAnd", defaultValue: "Group folders must be inside the selected destination and outside recovery folders")) }
                let directory = subdir.isEmpty ? dst : dst.appendingPathComponent(subdir)
                let sources = photos + sidecars + explicit
                guard Set(sources.map { $0.lastPathComponent.lowercased() }).count == sources.count else { throw LRCError(L10n.text("app.selectedAttachmentNamesConflictAdjustTheGroupsOrFolders", defaultValue: "Selected attachment names conflict. Adjust the groups or folders")) }
                var members = try sources.map { url in
                    CopyMember(source: url, destination: directory.appendingPathComponent(url.lastPathComponent), sourceIdentity: try FileIdentity.read(url), digest: try SafeFileWriter.sha256(url), isImage: Self.images.contains(url.pathExtension.lowercased()))
                }
                let initial = members.map(\.destination)
                let exists = initial.map { FileManager.default.fileExists(atPath: $0.path) }
                let batchConflict = initial.contains { reserved.contains(Self.nameKey($0)) }
                var group = CopyGroup(sourceKey: key, members: members, policy: groupPolicy)
                if deferConflicts {
                    group.requiresConflictCheck = true
                    group.allowsRename = unknown.isEmpty && explicit.isEmpty
                    group.allowsOverwrite = sources.count == 1 && unknown.isEmpty && explicit.isEmpty
                    if exists.contains(true) || batchConflict {
                        group.diagnostic = L10n.text("app.chooseHowToHandleTheFilenameConflict", defaultValue: "Choose how to handle the filename conflict")
                    }
                    for member in members { reserved.insert(Self.nameKey(member.destination)) }
                    groups.append(group)
                    continue
                }
                let identical = try skipIdentical && !batchConflict && exists.allSatisfy { $0 } && (members.allSatisfy { try SafeFileWriter.sha256($0.destination) == $0.digest })
                if identical {
                    group.state = "skippedVerified"; group.diagnostic = L10n.text("app.contentsAndSelectedAttachmentsMatchReuseTheDestination", defaultValue: "Contents and selected attachments match. Reuse the destination")
                } else if exists.contains(true) || batchConflict {
                    switch groupPolicy {
                    case .skip: group.state = "skippedConflict"; group.diagnostic = L10n.text("app.skipTheEntireFilenameConflictGroup", defaultValue: "Skip the entire filename conflict group")
                    case .uniqueName:
                        guard unknown.isEmpty && explicit.isEmpty else { throw LRCError(L10n.text("app.unknownAttachmentsPreventAutomaticRenamingChooseAnotherFolder", defaultValue: "Unknown attachments prevent automatic renaming. Choose another folder")) }
                        let destinations = try Self.uniqueDestinations(members: members, reserved: reserved)
                        for i in members.indices { members[i].destination = destinations[i] }
                        group.members = members; group.diagnostic = L10n.text("app.useUniqueNames", defaultValue: "Use Unique Names")
                    case .overwrite:
                        guard !batchConflict, sources.count == 1, unknown.isEmpty, explicit.isEmpty, let destination = initial.first,
                              !activeTargets.contains(destination.path), !activeImports.contains(destination.path) else { throw LRCError(L10n.text("app.overwriteRequiresAnIndependentImageWithoutAttachmentsBatchConflicts", defaultValue: "Overwrite requires an independent image without attachments, batch conflicts, or active references")) }
                        let targetIdentity = try FileIdentity.read(destination)
                        guard !sourceIDs.contains(targetIdentity.key), !managed.contains(where: { $0.identityKey == targetIdentity.key }), !protectedPaths.contains(destination.resolvingSymlinksInPath().path) else { throw LRCError(L10n.text("app.theDestinationIsASourceOrACatalogManaged", defaultValue: "The destination is a source or a catalog-managed original and cannot be overwritten")) }
                        let targetSiblings = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        guard !targetSiblings.contains(where: { $0 != destination && $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(destination.deletingPathExtension().lastPathComponent) == .orderedSame }) else { throw LRCError(L10n.text("app.theDestinationHasRelatedFilesAndCannotBeOverwritten", defaultValue: "The destination has related files and cannot be overwritten")) }
                        group.members[0].targetIdentity = targetIdentity
                        group.members[0].targetDigest = try SafeFileWriter.sha256(destination)
                        group.diagnostic = L10n.text("app.thisDestinationWillBeReplacedItsPreviousBytesWill", defaultValue: "This destination will be replaced. Its previous \(targetIdentity.size) bytes will be preserved in ImportRecovery")
                    }
                }
                for member in group.members { reserved.insert(Self.nameKey(member.destination)) }
                groups.append(group)
            } catch is CancellationError { throw CancellationError() }
            catch {
                groups.append(CopyGroup(sourceKey: key, members: [], policy: groupPolicy, selected: false, diagnostic: "\(primary.lastPathComponent)：\(error.localizedDescription)", state: "needsReview"))
            }
        }
        return CopyPlan(sourceRoot: src, sourceBookmark: try AccessLease.bookmark(source, readOnly: true), targetRoot: dst,
                        targetBookmark: try AccessLease.bookmark(target, readOnly: false), layout: layout, skipIdentical: skipIdentical,
                        groups: groups, omitted: omitted, attachmentCandidates: nonImages.sorted { $0.path < $1.path })
    }
    nonisolated static func sourceFiles(_ source: URL, includeSubfolders: Bool) throws -> [URL] {
        var errors = [String]()
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey], options: options, errorHandler: { url, error in
            errors.append("\(url.lastPathComponent)：\(error.localizedDescription)"); return true
        }) else { throw LRCError(L10n.text("app.cannotReadTheSource", defaultValue: "Cannot read the source")) }
        var files = [URL]()
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .isUbiquitousItemKey])
            if url.lastPathComponent == "ImportRecovery" || values.isSymbolicLink == true || values.isPackage == true || values.isUbiquitousItem == true {
                // Calling skipDescendants on a leaf can skip the next directory
                // on macOS. A linked file has no descendants to skip.
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true { files.append(url) }
        }
        guard errors.isEmpty else { throw LRCError(L10n.text("app.incompleteSourceRead", defaultValue: "Incomplete source read: ") + errors.joined(separator: "; ")) }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    nonisolated static func uniqueDestinations(members: [CopyMember], reserved: Set<String>) throws -> [URL] {
        guard let primary = members.first else { return [] }
        let directory = primary.destination.deletingLastPathComponent()
        let stem = primary.source.deletingPathExtension().lastPathComponent
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let destinations = members.map { directory.appendingPathComponent("\(stem)-\(suffix).\($0.source.pathExtension)") }
            if !destinations.contains(where: { FileManager.default.fileExists(atPath: $0.path) || reserved.contains(nameKey($0)) }) { return destinations }
            suffix += 1
        }
    }
    nonisolated static func nameKey(_ url: URL) -> String { url.path.precomposedStringWithCanonicalMapping.lowercased() }
}
