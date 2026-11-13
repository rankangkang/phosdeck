import Foundation
import GRDB

enum LightroomImporter {
    struct Result: Sendable {
        let catalog: URL
        let imported: Int
        let converted: Int
        let warnings: [String]
    }
    private struct Root {
        let input: URL
        let staging: URL
        let final: URL
        let record: StorageRoot
        let relative: String?
    }

    static func run(_ preview: LightroomCatalog, locations: [Int64: URL], destination: URL, copying: Bool,
                    pipeline: ImagePipeline, progress: (Int, Int) async -> Void = { _, _ in }) async throws -> Result {
        try preview.requireUnchanged()
        let rootsByID = Dictionary(uniqueKeysWithValues: preview.roots.map { ($0.id, $0) })
        let grants = locations.values.map { AccessLease(url: $0) }
        defer { withExtendedLifetime(grants) {} }
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let destination = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        let inputs = locations.mapValues { $0.resolvingSymlinksInPath().standardizedFileURL }
        guard !copying || !inputs.values.contains(where: { ProjectCopy.contains($0, destination) }) else {
            throw LRCError(L10n.text("archive.destinationInsideSource", defaultValue: "Choose a destination outside the project folders."))
        }
        let project = try ProjectCopy(destination: destination)
        defer { project.discard() }
        let file = project.staging.appendingPathComponent(CatalogFile.filename(destination.lastPathComponent))
        let catalog = try CatalogStore(fileURL: file, create: true)
        let catalogID = try await catalog.database.read { try String.fetchOne($0, sql: "SELECT id FROM catalogMeta") ?? "" }
        let sourceArchive = project.staging.appendingPathComponent("Lightroom", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceArchive, withIntermediateDirectories: false)
        try preserveSource(preview, in: sourceArchive)
        var roots: [Int64: Root] = [:]
        var labels = Set<String>()
        for id in inputs.keys.sorted() {
            guard let input = inputs[id], let lr = rootsByID[id] else { continue }
            _ = try ProjectCopy.directoryIdentity(input)
            let name = input.lastPathComponent.isEmpty ? "Photos" : input.lastPathComponent
            var label = name
            var suffix = 2
            while !labels.insert(ExportNamingPlanner.collisionKey(label)).inserted { label = "\(name) \(suffix)"; suffix += 1 }
            let relative = copying ? "Files/" + label : nil
            let staging = try relative.map { try ProjectCopy.child($0, of: project.staging) } ?? input
            let final = try relative.map { try ProjectCopy.child($0, of: destination) } ?? input
            if copying { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) }
            let bookmark = try AccessLease.bookmark(copying ? staging : locations[id]!, readOnly: true)
            let record = StorageRoot(id: UUID().uuidString, path: staging.path, bookmark: bookmark, label: lr.name.isEmpty ? label : lr.name)
            roots[id] = Root(input: input, staging: staging, final: final, record: record, relative: relative)
        }

        var warnings = preview.warnings
        var versions: [(photo: Photo, keywords: [String], original: Int64, master: Int64)] = []
        var masters: [Int64: Photo] = [:]
        var originalIDs = Set<String>()
        var stagedPaths = Set<String>()
        var sidecars: [String: (FileIdentity, String, String)] = [:]
        var attachments: [(String, String, String)] = []
        var converted = 0
        let sorted = preview.versions.sorted { ($0.master == 0 ? 0 : 1, $0.id) < ($1.master == 0 ? 0 : 1, $1.id) }
        await progress(0, sorted.count)
        for (offset, version) in sorted.enumerated() {
            try Task.checkCancellation()
            if offset > 0, offset % 16 == 0 { await progress(offset, sorted.count) }
            guard let root = roots[version.root] else {
                warnings.append(version.path + " · " + L10n.text("lightroom.unlinked", defaultValue: "Source folder was not located")); continue
            }
            let source = try ProjectCopy.child(version.path, of: root.input)
            var photo: Photo
            var fileAvailable = true
            var copiedSidecars: [(String, String)] = []
            if version.master == 0 {
                guard PhotoFileType.editableExtensions.contains(source.pathExtension.lowercased()) else {
                    warnings.append(version.path + " · " + L10n.text("lightroom.unsupportedFile", defaultValue: "File type is retained in the Lightroom catalog")); continue
                }
                do {
                    guard source.resolvingSymlinksInPath().path == source.path else { throw ProjectCopy.changed(source) }
                    photo = try ReferenceImporter.inspect(url: source, root: root.record, rootURL: root.input)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    warnings.append(version.path + " · " + error.localizedDescription)
                    if copying { continue }
                    // A unique placeholder retains organization without treating the path as a verified original.
                    let id = UUID().uuidString
                    let placeholder = FileIdentity(device: 0, inode: 0, size: 0, modifiedSeconds: 0, modifiedNanoseconds: 0)
                    photo = Photo(id: id, rootID: root.record.id, relativePath: version.path, identity: try JSONEncoder().encode(placeholder),
                                  identityKey: "missing:" + id, captureDate: version.captureDate, width: max(0, version.width),
                                  height: max(0, version.height), availability: "missing")
                    fileAvailable = false
                }
                guard originalIDs.insert(photo.identityKey).inserted else {
                    warnings.append(version.path + " · " + L10n.text("lightroom.duplicateFile", defaultValue: "Duplicate physical original; see the Lightroom catalog")); continue
                }
                if copying {
                    let target = try ProjectCopy.child(version.path, of: root.staging)
                    let key = ExportNamingPlanner.collisionKey(target.path)
                    guard stagedPaths.insert(key).inserted else { throw ProjectCopy.changed(target) }
                    let directory = target.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let expected = try JSONDecoder().decode(FileIdentity.self, from: photo.identity)
                    let (identity, digest) = try ProjectCopy.copy(source, to: target, expected: expected)
                    photo.identity = try JSONEncoder().encode(identity); photo.identityKey = identity.key; photo.digest = digest
                }
                if fileAvailable {
                    let stem = source.deletingPathExtension()
                    let target = try ProjectCopy.child(version.path, of: root.staging)
                    for ext in ["xmp", "XMP", "acr", "ACR"] {
                        let sidecar = stem.appendingPathExtension(ext)
                        guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
                        let identity = try FileIdentity.read(sidecar)
                        let canonical = sidecar.resolvingSymlinksInPath()
                        guard canonical.deletingLastPathComponent().path == sidecar.deletingLastPathComponent().path else { throw ProjectCopy.changed(sidecar) }
                        let output = target.deletingLastPathComponent().appendingPathComponent(canonical.lastPathComponent)
                        let key = ExportNamingPlanner.collisionKey(output.path)
                        if let (previous, relative, digest) = sidecars[key] {
                            guard previous == identity else { throw ProjectCopy.changed(sidecar) }
                            if !copiedSidecars.contains(where: { $0.0 == relative }) { copiedSidecars.append((relative, digest)) }
                            continue
                        }
                        let digest = try copying ? ProjectCopy.copy(canonical, to: output, expected: identity).digest : SafeFileWriter.sha256(canonical)
                        guard try FileIdentity.read(sidecar) == identity else { throw ProjectCopy.changed(sidecar) }
                        let relative = String(output.path.dropFirst(root.staging.path.count + 1))
                        sidecars[key] = (identity, relative, digest)
                        copiedSidecars.append((relative, digest))
                    }
                }
            } else {
                guard let master = masters[version.master], master.rootID == root.record.id, master.relativePath == version.path else {
                    warnings.append(version.path + " · " + L10n.text("lightroom.copyWithoutMaster", defaultValue: "Virtual copy has no imported original")); continue
                }
                photo = master
                photo.id = UUID().uuidString
                photo.sourceID = master.id
                let name = version.name.trimmingCharacters(in: .whitespacesAndNewlines)
                photo.copyName = name.isEmpty ? L10n.text("lightroom.virtualCopy", defaultValue: "Lightroom Copy") : String(name.prefix(100))
                photo.recipe = nil; photo.recipeRevision = 0
                fileAvailable = photo.availability == "available"
            }
            photo.rating = min(5, max(0, version.rating))
            photo.flag = min(1, max(-1, version.flag))
            photo.colorLabel = color(version.label)
            if photo.colorLabel == 0, !version.label.isEmpty { warnings.append(version.path + " · " + version.label) }
            if let captured = version.captureDate, !captured.isEmpty { photo.captureDate = captured }
            photo.caption = (try? PhotoCaption.normalized(version.caption)) ?? ""
            if photo.caption.isEmpty, !version.caption.isEmpty { warnings.append(version.path + " · " + L10n.text("lightroom.captionRetained", defaultValue: "Caption retained in the source catalog")) }
            if version.master != 0, let master = masters[version.master] { photo.captureDate = master.captureDate }

            if fileAvailable, !version.settings.isEmpty || !version.orientation.isEmpty {
                do {
                    var properties = version.settings.isEmpty ? [:] : try LightroomSettings.properties(version.settings)
                    let orientation = version.orientation
                    let requiresRecipe = !properties.isEmpty || !orientation.isEmpty && orientation != "AB"
                    if requiresRecipe {
                        let baseline = try await pipeline.baseline(ImageRequest(photo: photo, root: root.record, recipe: nil))
                        var recipe = baseline
                        let geometry = LightroomSettings.applyGeometry(&properties, orientation: orientation, photo: photo, recipe: &recipe)
                        if !properties.isEmpty {
                            let draft = try XMPPresetReader.convert(properties, filename: "Lightroom")
                            recipe = try draft.settings.resolved(on: recipe, options: draft.settings.options)
                            warnings.append(contentsOf: draft.settings.warnings.map { version.path + " · " + $0 })
                        }
                        warnings.append(contentsOf: geometry.map { version.path + " · " + $0 })
                        if recipe != baseline {
                            photo.recipe = try JSONEncoder().encode(recipe)
                            photo.recipeRevision = 1
                            photo.digest = recipe.sourceDigest
                            converted += 1
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { warnings.append(version.path + " · " + error.localizedDescription) }
            }
            if version.master == 0 { masters[version.id] = photo }
            attachments.append(contentsOf: copiedSidecars.map { (photo.id, $0.0, $0.1) })
            for keyword in version.keywords where (try? KeywordSummary.name(keyword)) == nil {
                warnings.append(version.path + " · " + keyword)
            }
            versions.append((photo, version.keywords, version.id, version.master))
        }
        await progress(sorted.count, sorted.count)
        try Task.checkCancellation()
        let mastersByID = masters
        let rootRecords = Array(roots.values)
        let idByVersion = Dictionary(versions.map { ($0.original, $0.photo.id) }, uniquingKeysWith: { first, _ in first })
        let digestBySource = Dictionary(versions.compactMap { entry in entry.photo.digest.map { (entry.photo.sourceKey, $0) } },
                                        uniquingKeysWith: { first, _ in first })
        let importTime = Date().timeIntervalSince1970
        try await catalog.database.write { [versions, attachments] db in
            for root in rootRecords { try root.record.insert(db) }
            for entry in versions {
                try Task.checkCancellation()
                var photo = entry.photo
                photo.digest = digestBySource[photo.sourceKey]
                if let master = mastersByID[entry.master] { photo.captureDate = master.captureDate }
                try photo.insert(db)
                if let recipe = photo.recipe {
                    try db.execute(sql: "INSERT INTO editHistory(photoID,title,createdAt,recipe) VALUES (?,?,?,?)",
                                   arguments: [photo.id, L10n.text("lightroom.historyTitle", defaultValue: "Imported from Lightroom Classic"), importTime, recipe])
                }
                for keyword in entry.keywords {
                    guard let name = try? KeywordSummary.name(keyword) else { continue }
                    try db.execute(sql: "INSERT OR IGNORE INTO photoKeyword VALUES (?,?,?)", arguments: [photo.id, KeywordSummary.key(name), name])
                }
            }
            for (id, path, digest) in attachments {
                try db.execute(sql: "INSERT INTO attachment VALUES (?,?,?)", arguments: [id, path, digest])
                try db.execute(sql: "INSERT OR IGNORE INTO attachment SELECT id,?,? FROM photo WHERE sourceID=?", arguments: [path, digest, id])
            }
            for album in preview.albums {
                let collection = PhotoCollection(id: UUID().uuidString, name: album.name)
                try collection.insert(db)
                for image in album.members {
                    guard let photo = idByVersion[image] else { continue }
                    try db.execute(sql: "INSERT OR IGNORE INTO membership VALUES (?,?)", arguments: [collection.id, photo])
                }
            }
            for root in rootRecords where root.relative != nil {
                try db.execute(sql: "UPDATE storageRoot SET path=?,bookmark=? WHERE id=?", arguments: [root.final.path, Data(), root.record.id])
            }
        }
        warnings.append(contentsOf: try importPresets(in: sourceArchive, catalog: catalog))
        try CatalogStore.validate(catalog.database)
        try catalog.database.close()
        let lock = URL(fileURLWithPath: file.path + ".lock")
        if FileManager.default.fileExists(atPath: lock.path) { try FileManager.default.removeItem(at: lock) }
        if preview.versions.count != idByVersion.count {
            warnings.append(L10n.text("lightroom.unimported", defaultValue: "\(preview.versions.count - idByVersion.count) Lightroom versions were not added to the Phosdeck catalog."))
        }
        let summary = L10n.text("lightroom.summary", defaultValue: "Imported \(idByVersion.count) versions · \(converted) with converted edits")
        try SafeFileWriter.write(Data(([summary] + warnings).joined(separator: "\n").utf8), to: sourceArchive.appendingPathComponent("Import.txt"))
        let pairs = try rootRecords.compactMap { root -> (String, CatalogArchive.Location)? in
            guard let relative = root.relative else { return nil }
            return (root.record.id, .init(path: relative, directoryIdentity: try ProjectCopy.directoryIdentity(root.staging).key))
        }
        let mappings = Dictionary(uniqueKeysWithValues: pairs)
        try CatalogArchive.writeIndex(.init(catalogID: catalogID, roots: mappings, folders: mappings.values.map(\.path).sorted() + ["Lightroom"]), in: project.staging)
        try preview.requireUnchanged()
        try SafeFileWriter.flush(file)
        try project.flushDirectories()
        let identity = try FileIdentity.read(file)
        try project.publish()
        let published = destination.appendingPathComponent(file.lastPathComponent)
        do { try CatalogStore.verifyBackup(published, identity: identity) }
        catch { throw LRCError(L10n.text("project.publishedNeedsVerification", defaultValue: "The project was published but needs verification:") + "\n" + published.path + "\n" + error.localizedDescription) }
        return Result(catalog: published, imported: idByVersion.count, converted: converted, warnings: warnings)
    }

    private static func color(_ label: String) -> Int {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "red", "红色", "红": 1
        case "yellow", "黄色", "黄": 2
        case "green", "绿色", "绿": 3
        case "blue", "蓝色", "蓝": 4
        case "purple", "紫色", "紫": 5
        default: 0
        }
    }

    private static func preserveSource(_ preview: LightroomCatalog, in archive: URL) throws {
        try ProjectCopy.copy(preview.file, to: archive.appendingPathComponent(preview.file.lastPathComponent), expected: preview.identity)
        let source = URL(fileURLWithPath: preview.file.path + "-data")
        if FileManager.default.fileExists(atPath: source.path) {
            try copyItems(source, to: archive.appendingPathComponent(source.lastPathComponent))
        }
        let presets = preview.file.deletingLastPathComponent().appendingPathComponent("Lightroom Settings", isDirectory: true)
        if FileManager.default.fileExists(atPath: presets.path) { try copyItems(presets, to: archive.appendingPathComponent(presets.lastPathComponent)) }
    }

    private static func importPresets(in archive: URL, catalog: CatalogStore) throws -> [String] {
        let settings = archive.appendingPathComponent("Lightroom Settings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: settings.path) else { return [] }
        var warnings: [String] = []
        var drafts: [XMPPresetDraft] = []
        guard let entries = FileManager.default.enumerator(at: settings, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw ProjectCopy.changed(settings)
        }
        for case let url as URL in entries {
            try Task.checkCancellation()
            guard url.pathExtension.lowercased() == "xmp", try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let item = XMPPresetReader.read(url)
            warnings.append(contentsOf: item.issues.map { url.lastPathComponent + " · " + $0 })
            if item.canImport, let draft = item.draft { drafts.append(draft) }
        }
        for start in stride(from: 0, to: drafts.count, by: XMPPresetReader.maximumFiles) {
            try Task.checkCancellation()
            let end = min(start + XMPPresetReader.maximumFiles, drafts.count)
            _ = try catalog.importXMPPresets(Array(drafts[start..<end]))
        }
        return warnings
    }

    private static func copyItems(_ source: URL, to target: URL) throws {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw ProjectCopy.changed(source) }
        if values.isDirectory == true {
            let identity = try ProjectCopy.directoryIdentity(source)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyItems(item, to: target.appendingPathComponent(item.lastPathComponent))
            }
            guard try ProjectCopy.directoryIdentity(source) == identity else { throw ProjectCopy.changed(source) }
        } else { try ProjectCopy.copy(source, to: target) }
    }
}
