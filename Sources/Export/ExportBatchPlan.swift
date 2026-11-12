import Foundation

/// One immutable output specification selected for a multi-spec export.
///
/// A specification intentionally contains output options only. It never stores a target
/// directory, a security-scoped bookmark, or any other authorization state. The directory is
/// supplied to `ExportBatchPlanner` at preview time and is frozen by the caller at submission.
struct ExportSpecification: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var subfolder: String
    var options: ExportOptions

    init(id: String = UUID().uuidString, title: String, subfolder: String, options: ExportOptions) {
        self.id = id
        self.title = title
        self.subfolder = subfolder
        self.options = options
    }

    func validate(allowParent: Bool = false) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LRCError(L10n.text("app.anOutputVariantIdentifierIsMissing", defaultValue: "An output variant identifier is missing"))
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.precomposedStringWithCanonicalMapping.utf8.count <= 100 else {
            throw LRCError(L10n.text("app.variantNamesMustContain1100Characters", defaultValue: "Variant names must contain 1–100 characters"))
        }
        if !allowParent || !subfolder.isEmpty { try ExportBatchPlanner.validateSubfolder(subfolder) }
        try options.validate()
        if options.format == .jpeg && options.jpegMatte == .unselected {
            throw LRCError(L10n.text("app.chooseAJPEGMatteColorForVariant", defaultValue: "Choose a JPEG matte color for variant “\(title)”"))
        }
    }
}

/// A single frozen destination from a multi-spec plan. The caller can turn these values into
/// existing `ExportSnapshot` values after re-reading the selected photos; the planner itself has
/// no file-writing or catalog side effects.
struct ExportPlanRequest: Identifiable, Equatable {
    let id: String
    let specificationID: String
    let specificationTitle: String
    let subfolder: String
    let photo: Photo
    let name: ExportName
    let destination: URL
    let options: ExportOptions

    var errors: [String] { name.errors }
    var warnings: [String] { name.warnings }
}

struct ExportSpecificationPlan: Identifiable, Equatable {
    let specification: ExportSpecification
    let names: [ExportName]
    let requests: [ExportPlanRequest]
    let issues: [String]

    var id: String { specification.id }
    var outputCount: Int { requests.count }
    var summary: String {
        L10n.text("app.subfolderFiles", defaultValue: "\(specification.title) · \(specification.options.summary) · Subfolder: \(specification.subfolder) · \(outputCount) files")
    }
}

/// A complete, ordered, side-effect-free preview of a multi-spec export.
///
/// `requests` is deliberately a value snapshot. It preserves the photo order and the exact
/// names/URLs shown to the user, while the AppModel remains responsible for re-reading catalog
/// recipes, obtaining an `AccessLease`, freezing `ExportSnapshot`s, and enqueueing the existing
/// `ExportService` task queue.
struct ExportBatchPlan: Equatable {
    let directory: URL
    let protectedOriginals: [URL]
    let specifications: [ExportSpecification]
    let groups: [ExportSpecificationPlan]
    let requests: [ExportPlanRequest]
    let issues: [String]

    var isReady: Bool { issues.isEmpty && requests.allSatisfy { $0.errors.isEmpty } }
    var outputCount: Int { requests.count }
    var summary: String {
        L10n.text("app.variantsFiles", defaultValue: "\(specifications.count) variants · \(outputCount) files")
    }
}

/// UI-only draft for one row in the multi-spec picker. It keeps the selected preset's options in
/// the draft so changing a JPEG matte or another per-spec value never mutates the saved preset.
struct ExportBatchDraft: Identifiable, Equatable {
    let id: String
    var presetID: String
    var title: String
    var subfolder: String
    var options: ExportOptions

    init(id: String = UUID().uuidString, preset: ExportPreset, subfolder: String) {
        self.id = id
        self.presetID = preset.id
        self.title = preset.name
        self.subfolder = subfolder
        self.options = preset.options
    }
}

enum ExportBatchPlanner {
    private static let forbiddenSubfolderCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        .union(.controlCharacters)

    /// Plans all names and destinations without creating a directory or touching a file.
    /// `originalURLs` is optional because the sheet may not know the source roots. AppModel should
    /// pass the resolved original URLs when it submits the plan so the planner can flag an output
    /// that would point at a managed original before any snapshot is frozen.
    static func plan(photos: [Photo], specifications: [ExportSpecification], directory: URL,
                     originalURLs: [URL] = [], singleDestination: Bool = false) throws -> ExportBatchPlan {
        guard !photos.isEmpty else { throw LRCError(L10n.text("app.noPhotosToExport", defaultValue: "No photos to export")) }
        guard !specifications.isEmpty else { throw LRCError(L10n.text("app.selectAtLeastOneExportVariant", defaultValue: "Select at least one export variant")) }
        guard Set(specifications.map(\.id)).count == specifications.count else {
            throw LRCError(L10n.text("app.duplicateOutputVariantIdentifiers", defaultValue: "Duplicate output variant identifiers"))
        }
        if singleDestination, specifications.count != 1 || specifications.first?.subfolder != "" {
            throw LRCError(L10n.text("app.selectAtLeastOneExportVariant", defaultValue: "Choose one specification for a single destination"))
        }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LRCError(L10n.text("app.chooseAnExistingParentDestinationFolder", defaultValue: "Choose an existing parent destination folder"))
        }

        let originalKeys = Set(originalURLs.map(canonicalKey))
        let parentKey = canonicalKey(directory)
        var groups = [ExportSpecificationPlan]()
        var allRequests = [ExportPlanRequest]()
        var issues = [String]()
        var usedSubfolders = [String: ExportSpecification]()

        for specification in specifications {
            try specification.validate(allowParent: singleDestination)
            let folder = specification.subfolder.precomposedStringWithCanonicalMapping
            let folderKey = ExportNamingPlanner.collisionKey(folder)
            if let previous = usedSubfolders[folderKey] {
                issues.append(L10n.text("app.variantsAndUseTheSameSubfolderChooseSeparateDestinations", defaultValue: "Variants “\(specification.title)” and “\(previous.title)” use the same subfolder. Choose separate destinations"))
            } else {
                usedSubfolders[folderKey] = specification
            }

            let destinationFolder = singleDestination ? directory : directory.appendingPathComponent(folder, isDirectory: true)
            let resolvedFolderKey = canonicalKey(destinationFolder)
            guard singleDestination || isStrictDescendant(resolvedFolderKey, of: parentKey) else {
                throw LRCError(L10n.text("app.theSubfolderForResolvesOutsideTheSelectedParentSymbolic", defaultValue: "The subfolder for “\(specification.title)” resolves outside the selected parent. Symbolic links are not allowed"))
            }
            var names: [ExportName]
            if FileManager.default.fileExists(atPath: destinationFolder.path) {
                guard try destinationFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw LRCError(L10n.text("app.theSubfolderForIsNotAFolder", defaultValue: "The subfolder for “\(specification.title)” is not a folder: \(folder)"))
                }
                names = try ExportNamingPlanner.preview(photos: photos, options: specification.options, directory: destinationFolder)
            } else {
                // The AppModel creates subfolders only after this preview is accepted. An absent
                // folder has no existing file conflicts, so preview against a nil directory.
                names = try ExportNamingPlanner.preview(photos: photos, options: specification.options)
            }

            var requestItems = [ExportPlanRequest]()
            for (photo, name) in zip(photos, names) {
                let destination = destinationFolder.appendingPathComponent(name.filename, isDirectory: false)
                var frozenName = name
                if originalKeys.contains(canonicalKey(destination)) {
                    frozenName.errors.append(L10n.text("app.theDestinationIsACatalogOriginalAndCannotBe", defaultValue: "The destination is a catalog original and cannot be overwritten"))
                }
                requestItems.append(ExportPlanRequest(id: "\(specification.id):\(photo.id)",
                                                      specificationID: specification.id,
                                                      specificationTitle: specification.title,
                                                      subfolder: folder,
                                                      photo: photo,
                                                      name: frozenName,
                                                      destination: destination,
                                                      options: specification.options))
            }
            let groupIssues = requestItems.flatMap { item in
                item.errors.map { "\(specification.title) · \(item.name.filename)：\($0)" }
            }
            issues.append(contentsOf: groupIssues)
            let group = ExportSpecificationPlan(specification: specification, names: requestItems.map(\.name), requests: requestItems,
                                                issues: groupIssues)
            groups.append(group)
            allRequests.append(contentsOf: requestItems)
        }

        // The destination path, rather than the bare filename, is the collision domain. This
        // catches same-name files across two specifications that accidentally share a subfolder,
        // while allowing identical filenames in intentionally separate subfolders.
        let collisions = Dictionary(grouping: allRequests, by: { canonicalKey($0.destination) })
            .filter { $0.value.count > 1 }
        for (_, colliding) in collisions {
            issues.append(L10n.text("app.multipleVariantsProduceTheSameDestinationChangeTheirSubfolders", defaultValue: "Multiple variants produce the same destination: \(colliding[0].destination.path). Change their subfolders or naming"))
        }

        return ExportBatchPlan(directory: directory, protectedOriginals: originalURLs, specifications: specifications, groups: groups,
                               requests: allRequests, issues: issues)
    }

    /// Check the frozen names before and after creating any requested subfolders.
    static func prepareDestinations(_ plan: ExportBatchPlan) throws {
        let photos = plan.groups[0].requests.map(\.photo)
        let single = plan.specifications.count == 1 && plan.specifications[0].subfolder.isEmpty
        func recheck() throws {
            try Task.checkCancellation()
            let checked = try Self.plan(photos: photos, specifications: plan.specifications, directory: plan.directory,
                                        originalURLs: plan.protectedOriginals, singleDestination: single)
            guard checked.isReady, checked.requests.map(\.destination) == plan.requests.map(\.destination) else {
                throw LRCError(L10n.text("app.aDestinationConflictAroseDuringPreparationReopenExportTo", defaultValue: "A destination conflict arose during preparation. Reopen Export to review it"))
            }
        }
        try recheck()
        if single { return }
        for group in plan.groups {
            try Task.checkCancellation()
            let folder = plan.directory.appendingPathComponent(group.specification.subfolder.precomposedStringWithCanonicalMapping, isDirectory: true)
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw LRCError(L10n.text("app.theDestinationSubfolderIsUnavailable", defaultValue: "The destination subfolder is unavailable"))
            }
        }
        try recheck()
    }

    static func validateSubfolder(_ value: String) throws {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard normalized == normalized.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LRCError(L10n.text("app.subfolderNamesCannotStartOrEndWithWhitespace", defaultValue: "Subfolder names cannot start or end with whitespace"))
        }
        guard !normalized.isEmpty else { throw LRCError(L10n.text("app.subfolderNamesCannotBeEmpty", defaultValue: "Subfolder names cannot be empty")) }
        guard normalized.utf8.count <= 120 else { throw LRCError(L10n.text("app.subfolderNamesCannotExceed120UTF8Bytes", defaultValue: "Subfolder names cannot exceed 120 UTF-8 bytes")) }
        guard !normalized.unicodeScalars.contains(where: forbiddenSubfolderCharacters.contains) else {
            throw LRCError(L10n.text("app.invalidSubfolderNameAndControlCharactersAreNotAllowed", defaultValue: "Invalid subfolder name: / \\ : * ? \" < > | and control characters are not allowed"))
        }
        guard normalized != ".", normalized != ".." else { throw LRCError(L10n.text("app.subfolderNamesCannotBeOr", defaultValue: "Subfolder names cannot be . or ..")) }
        guard !normalized.hasPrefix("."), !normalized.hasSuffix("."), !normalized.hasSuffix(" ") else {
            throw LRCError(L10n.text("app.subfolderNamesCannotStartWithADotOrEnd", defaultValue: "Subfolder names cannot start with a dot or end with a dot or space"))
        }
        let device = normalized.split(separator: ".", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        if ["CON", "PRN", "AUX", "NUL"].contains(device) || (1...9).contains(where: { device == "COM\($0)" || device == "LPT\($0)" }) {
            throw LRCError(L10n.text("app.thisSubfolderNameIsReservedByTheSystem", defaultValue: "This subfolder name is reserved by the system"))
        }
    }

    static func canonicalKey(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func isStrictDescendant(_ candidate: String, of parent: String) -> Bool {
        guard candidate != parent else { return false }
        if parent == "/" { return candidate.hasPrefix("/") }
        return candidate.hasPrefix(parent + "/")
    }
}
