import AppKit
import GRDB
import MCP

struct MCPImportPlan {
    struct Candidate {
        let id = UUID().uuidString
        let file: ImportCandidate
        let eligible: Bool
    }
    let source: AppMCPWorkflows.Grant
    let candidates: [Candidate]
    let copy: CopyPlan?
    let attachments: [String: URL]
    let collection: String?
    let pair: Bool
}

extension AppMCPWorkflows {
    func writeImport(_ tool: AppMCPTool, catalog: CatalogStore, arguments: Arguments) throws -> MCPToolResult {
        switch tool {
        case .planImport: return try planImport(catalog: catalog, arguments: arguments)
        case .startImport: return try startImport(catalog: catalog, arguments: arguments)
        case .resumeImport, .restoreBackup, .cleanBackup:
            let record = arguments["record_id"]!.stringValue!
            let memberID = arguments["member_id"]?.stringValue
            let access = tool == .restoreBackup ? try grant(arguments["access_id"], purpose: .restoreBackup) : nil
            return start(tool) { job in
                self.running(job, phase: "reading_import_record")
                guard let plan = try await Task.detached(operation: { try CopyImporter.savedPlan(record, catalog: catalog) }).value,
                      !plan.isArchived else { throw Self.missingRecord }
                try Task.checkCancellation()
                job.data["record_id"] = .string(record)
                if tool == .resumeImport {
                    guard plan.canResume else { throw Self.missingRecord }
                    await self.copy(plan.resuming, catalog: catalog, job: job)
                } else {
                    guard let member = plan.groups.lazy.flatMap(\.members).first(where: { $0.id == memberID && $0.recovery != nil && $0.recoveryState != "deleted" }) else {
                        throw Self.missingRecord
                    }
                    job.data["member_id"] = .string(member.id)
                    if let access {
                        try await self.restore(member, from: plan, to: access, name: arguments["name"]?.stringValue, job: job)
                    } else {
                        guard plan.state == "completed" else { throw Self.missingRecord }
                        try await self.clean(member, plan: plan, catalog: catalog, job: job)
                    }
                }
            }
        default: throw MCPToolProblem.failed
        }
    }

    private func planImport(catalog: CatalogStore, arguments: Arguments) throws -> MCPToolResult {
        let source = try grant(arguments["source_access_id"], purpose: .importSource)
        let copying = arguments["mode"]?.stringValue == "copy"
        if !copying, ["destination_access_id", "date_layout", "archive_date", "include_sidecars", "policy", "attachment_assignments"].contains(where: { arguments[$0] != nil }) {
            throw MCPToolProblem.invalid("Use the copy options only in copy mode.")
        }
        let target = copying ? try grant(arguments["destination_access_id"], purpose: .importDestination) : nil
        let recursive = arguments["include_subfolders"]?.boolValue ?? true
        let skipCataloged = arguments["skip_cataloged"]?.boolValue ?? true
        let collection = arguments["collection_id"]?.stringValue
        try checkCollection(collection)
        let pair = arguments["detect_pairs"]?.boolValue ?? false
        let policy = arguments["policy"]?.stringValue.flatMap(ConflictPolicy.init(rawValue:))
        let layout = arguments["date_layout"]?.stringValue.flatMap(DateLayout.init(rawValue:))
            ?? UserDefaults.standard.string(forKey: "copyDateLayout").flatMap(DateLayout.init(rawValue:)) ?? .yearMonthDay
        let archiveDate = arguments["archive_date"]?.stringValue
        if let archiveDate, LibraryMetadataFilter.day(archiveDate) != archiveDate { throw MCPToolProblem.invalid("Use an archive date in yyyy-MM-dd format.") }
        let sidecars = arguments["include_sidecars"]?.boolValue ?? true
        let base: MCPImportPlan?
        if let id = arguments["base_plan_id"]?.stringValue {
            guard let plan = importPlans[id], plan.source.url == source.url, (plan.copy != nil) == copying else { throw Self.stalePlan }
            base = plan
        } else {
            guard arguments["candidate_ids"] == nil, arguments["attachment_assignments"] == nil else {
                throw MCPToolProblem.invalid("Use base_plan_id when choosing candidates or assigning attachments.")
            }
            base = nil
        }
        let ids = arguments["candidate_ids"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
        let priorCandidates = base?.candidates.filter { ids?.contains($0.id) ?? true }
        if let ids, ids.count != priorCandidates?.count { throw MCPToolProblem.invalid("Select candidate IDs from the base plan.") }
        var choices = ImportChoices()
        for (attachmentID, groupID) in arguments["attachment_assignments"]?.objectValue ?? [:] {
            guard let attachment = base?.attachments[attachmentID],
                  let key = base?.copy?.groups.first(where: { $0.id == groupID.stringValue })?.sourceKey else {
                throw MCPToolProblem.invalid("Assign each attachment to a copy group in the base plan.")
            }
            choices.attachments[attachment.path] = key
        }

        return start(.planImport) { job in
            self.running(job, phase: "inspecting_sources")
            let read = try await self.model.importer.preview(source: source.url, includeSubfolders: recursive, catalog: catalog)
            let files: [ImportCandidate]
            if let priorCandidates {
                let current = Dictionary(uniqueKeysWithValues: read.map { ($0.id, $0) })
                files = try priorCandidates.map { previous in
                    guard let file = current[previous.file.id], file.identity == previous.file.identity else { throw Self.stalePlan }
                    return file
                }
            } else { files = read }
            let candidates = files.map { MCPImportPlan.Candidate(file: $0, eligible: $0.problem == nil && (!skipCataloged || !$0.alreadyImported)) }
            let selected = candidates.filter(\.eligible)
            var copy: CopyPlan?
            if let target {
                self.running(job, phase: "planning_copies")
                var planned = try await ImportPlanner().plan(source: source.url, target: target.url, layout: layout, policy: policy ?? .skip,
                    skipIdentical: true, dateOverride: archiveDate, confirmSidecars: sidecars, catalog: catalog, choices: choices,
                    selectedPaths: Set(selected.map(\.file.id)), includeSubfolders: recursive, deferConflicts: policy == nil, includeSidecars: sidecars)
                let identities = Dictionary(uniqueKeysWithValues: selected.map { ($0.file.id, $0.file.identity) })
                guard planned.groups.flatMap(\.members).allSatisfy({ !$0.isImage || identities[$0.source.path] == $0.sourceIdentity }) else { throw Self.stalePlan }
                planned.collectionID = collection; planned.pairAfterImport = pair
                copy = planned
            }
            try Task.checkCancellation()
            let attachmentEntries = (copy?.attachmentCandidates ?? []).map { (UUID().uuidString, $0) }
            self.importPlans[job.id] = MCPImportPlan(source: source, candidates: candidates, copy: copy,
                attachments: Dictionary(uniqueKeysWithValues: attachmentEntries), collection: collection, pair: pair)
            job.data["plan_id"] = .string(job.id)
            job.data["mode"] = copying ? "copy" : "reference"
            job.data["candidate_count"] = .int(candidates.count)
            job.data["eligible_count"] = .int(selected.count)
            let sourceRoot = source.url.resolvingSymlinksInPath().standardizedFileURL
            job.items = candidates.map { candidate in
                ["kind": "candidate", "candidate_id": .string(candidate.id), "name": .string(Self.relative(candidate.file.url, in: sourceRoot)),
                 "eligible": .bool(candidate.eligible), "already_cataloged": .bool(candidate.file.alreadyImported),
                 "error_code": candidate.file.problem == nil ? .null : "image_unreadable"]
            }
            if let copy {
                job.data["group_count"] = .int(copy.groups.count)
                job.data["eligible_group_count"] = .int(copy.groups.filter(\.selected).count)
                job.data["blocked_group_count"] = .int(copy.groups.filter { !$0.selected }.count)
                job.data["omitted_count"] = .int(copy.omitted.count)
                job.items += copy.groups.map { group in
                    let name = group.members.first?.source.lastPathComponent ?? group.sourceKey.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
                    return ["kind": "group", "group_id": .string(group.id), "name": .string(name), "eligible": .bool(group.selected),
                            "state": .string(group.state), "file_count": .int(group.members.count),
                            "known_conflict": .bool(group.diagnostic != nil && group.selected),
                            "error_code": group.selected ? .null : "copy_plan_blocked",
                            "destination_names": .array(group.members.prefix(25).map { .string(Self.relative($0.destination, in: copy.targetRoot)) })]
                }
                job.items += attachmentEntries.map { id, file in
                    ["kind": "attachment", "attachment_id": .string(id), "name": .string(Self.relative(file, in: sourceRoot))]
                }
                self.model.reports = copy.groups.filter { !$0.selected }.compactMap(\.diagnostic) + copy.omitted
            }
            job.finish(.succeeded, "Prepared the import plan.")
        }
    }

    private func startImport(catalog: CatalogStore, arguments: Arguments) throws -> MCPToolResult {
        let id = arguments["plan_id"]!.stringValue!
        guard let plan = importPlans[id] else { throw Self.stalePlan }
        try checkCollection(plan.collection)
        let ids = arguments["candidate_ids"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
        let all = arguments["select_all"]?.boolValue == true
        guard all != (ids != nil) else { throw MCPToolProblem.invalid("Provide candidate_ids or select_all=true.") }
        if var copy = plan.copy {
            for index in copy.groups.indices {
                let group = copy.groups[index]
                copy.groups[index].selected = group.selected && (ids?.contains(group.id) ?? true)
            }
            let count = copy.groups.filter(\.selected).count
            guard count > 0, ids == nil || ids?.count == count else { throw MCPToolProblem.invalid("Select eligible group IDs from this copy plan.") }
            importPlans[id] = nil
            return start(.startImport) { job in
                var copy = copy
                copy.id = job.id
                await self.copy(copy, catalog: catalog, job: job)
            }
        }
        let candidates = plan.candidates.filter { $0.eligible && (ids?.contains($0.id) ?? true) }
        guard !candidates.isEmpty, ids == nil || ids?.count == candidates.count else { throw MCPToolProblem.invalid("Select eligible candidate IDs from this reference plan.") }
        importPlans[id] = nil
        return start(.startImport) { job in
            self.running(job, phase: "indexing")
            let title = L10n.text("app.import", defaultValue: "Import")
            self.progress(job, title: title, done: 0, total: candidates.count)
            let (report, refreshed) = await self.model.performReferenceImport(source: plan.source.url, candidates: candidates.map(\.file),
                collection: plan.collection, catalog: catalog, pairAfterImport: plan.pair, recordItems: true) { done in
                await MainActor.run { self.progress(job, title: title, done: done, total: candidates.count) }
            }
            self.progress(job, title: title, done: report.items.count, total: candidates.count)
            self.finishScan(job, report: report, refreshed: refreshed, planned: candidates)
            job.data["pair_review_open"] = .bool(self.model.showPairing)
        }
    }

    func finishScan(_ job: Job, report: ScanReport, refreshed: Bool, planned: [MCPImportPlan.Candidate] = []) {
        let state: Job.State
        if report.cancelled { state = .cancelled }
        else if report.errors.isEmpty { state = .succeeded }
        else { state = report.wroteCatalog ? .partial : .failed }
        job.data["indexed_count"] = .int(report.importedPhotoIDs.count)
        job.data["checked_count"] = .int(report.indexed)
        job.data["ignored_count"] = .int(report.ignored)
        job.data["error_count"] = .int(report.errors.count)
        job.data["workspace_refreshed"] = .bool(refreshed)
        let ids = Dictionary(uniqueKeysWithValues: planned.map { ($0.file.id, $0.id) })
        job.items = report.items.map { item in
            ["name": .string(item.url.lastPathComponent), "state": .string(item.state),
             "candidate_id": ids[item.url.path].map(Value.string) ?? .null, "photo_id": item.photoID.map(Value.string) ?? .null,
             "error_code": item.errorCode.map(Value.string) ?? .null]
        }
        let processed = Set(report.items.map(\.url.path))
        job.items += planned.filter { !processed.contains($0.file.id) }.map {
            ["name": .string($0.file.url.lastPathComponent), "candidate_id": .string($0.id), "state": "not_processed"]
        }
        job.finish(state, "Indexed \(report.importedPhotoIDs.count) new photos.", committed: report.wroteCatalog ? "committed" : "not_committed",
                   error: report.errors.isEmpty ? nil : "indexing_incomplete")
    }

    private func copy(_ plan: CopyPlan, catalog: CatalogStore, job: Job) async {
        running(job, phase: "copying")
        job.data["record_id"] = .string(plan.id)
        let title = L10n.text("app.import", defaultValue: "Import")
        progress(job, title: title, done: 0, total: plan.groups.count)
        let (result, imported, refreshed) = await model.performCopyImport(plan, catalog: catalog, showError: false) { done, total in
            await MainActor.run { self.progress(job, title: title, done: done, total: total) }
        }
        let recordSaved = await Task.detached { (try? CopyImporter.savedPlan(plan.id, catalog: catalog)) != nil }.value
        let details = await Task.detached { Self.copyItems(result, catalog: catalog) }.value
        job.items = details.items
        job.data.merge(Self.record(result, running: false)) { _, new in new }
        job.data["record_saved"] = .bool(recordSaved)
        job.data["can_resume"] = .bool(recordSaved && result.canResume)
        job.data["indexed_count"] = .int(imported.count)
        job.data["workspace_refreshed"] = .bool(refreshed)
        job.data["pair_review_open"] = .bool(model.showPairing)
        let state = Self.copyState(result, publicationCount: details.published)
        if state == .succeeded { progress(job, title: title, done: plan.groups.count, total: plan.groups.count) }
        job.finish(state, "Copy import reported \(details.published) files at their published locations and \(imported.count) new photos.",
                   committed: recordSaved || details.published > 0 || !imported.isEmpty ? "committed" : "unknown",
                   error: result.state == "needsReview" ? "copy_incomplete" : nil)
    }

    private func restore(_ member: CopyMember, from plan: CopyPlan, to access: Grant, name: String?, job: Job) async throws {
        let name = name ?? ("recovered-" + member.destination.lastPathComponent)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw MCPToolProblem.invalid("Use a new filename without any folder components.")
        }
        let source = try AccessLease(bookmark: plan.targetBookmark)
        defer { withExtendedLifetime(source) {} }
        guard let recovery = member.recovery,
              source.url.resolvingSymlinksInPath().standardizedFileURL.path == plan.targetRoot.path,
              recovery.deletingLastPathComponent().path == plan.targetRoot.appendingPathComponent("ImportRecovery/\(plan.id)").path,
              recovery.resolvingSymlinksInPath() == recovery.standardizedFileURL else { throw Self.accessExpired }
        running(job, phase: "restoring")
        let destination = access.url.appendingPathComponent(name)
        job.data["commit_state"] = "unknown"
        try await CopyImporter().restoreOld(member, to: destination)
        job.data["name"] = .string(name)
        job.data["publication"] = "verified"
        job.finish(.succeeded, "Restored the previous file to a new location.", committed: "committed")
    }

    private func clean(_ member: CopyMember, plan: CopyPlan, catalog: CatalogStore, job: Job) async throws {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("app.permanentlyRemoveThisPreviousFile", defaultValue: "Permanently remove this previous file?")
        alert.informativeText = L10n.text("app.previousVersionWillNoLongerBeRecoverableFromImportRecovery", defaultValue: "Previous version \(member.destination.lastPathComponent) will no longer be recoverable from ImportRecovery. Confirm a backup or recovery copy first.")
        alert.addButton(withTitle: L10n.text("app.cancel", defaultValue: "Cancel")).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: L10n.text("app.cleanUpPreviousFile_1351", defaultValue: "Clean Up Previous File")).keyEquivalent = ""
        guard try await confirm(alert, job: job, action: "confirm_import_backup_cleanup") == .alertSecondButtonReturn else { throw CancellationError() }
        running(job, phase: "cleaning_up")
        job.data["commit_state"] = "unknown"
        try await CopyImporter().cleanupOld(planID: plan.id, memberID: member.id, catalog: catalog)
        job.data["recovery_state"] = "deleted"
        job.finish(.succeeded, "Removed the confirmed previous file.", committed: "committed")
    }

    func readImportRecords(catalog: CatalogStore, tool: AppMCPTool, arguments: Arguments) async throws -> MCPToolResult {
        let active = model.activeCopyPlanID
        return try await Task.detached {
            if tool == .job {
                let id = arguments["job_id"]!.stringValue!
                guard let plan = try CopyImporter.savedPlan(id, catalog: catalog) else { throw Self.missingJob }
                let details = Self.copyItems(plan, catalog: catalog)
                let running = id == active
                var data = Self.record(plan, running: running)
                data.merge(Self.page(details.items, arguments: arguments)) { _, new in new }
                data["job_id"] = .string(id)
                data["state"] = .string(running ? "running" : Self.copyState(plan, publicationCount: details.published).rawValue)
                data["phase"] = running ? "copying" : "journal"
                data["commit_state"] = "committed"
                return .init("Read the saved copy import record.", data: data)
            }
            let offset = arguments["offset"]?.intValue ?? 0
            let limit = arguments["page_size"]?.intValue ?? 50
            let (plans, count) = try CopyImporter.savedPlans(catalog: catalog, offset: offset, limit: limit)
            let end = min(offset, count) + plans.count
            return .init("Read copy import records.", data: ["items": .array(plans.map { .object(Self.record($0, running: $0.id == active)) }),
                "total": .int(count), "next_offset": end < count ? .int(end) : .null])
        }.value
    }

    nonisolated private static func record(_ plan: CopyPlan, running: Bool) -> Arguments {
        ["record_id": .string(plan.id), "journal_state": .string(plan.state), "source_name": .string(plan.sourceRoot.lastPathComponent),
         "destination_name": .string(plan.targetRoot.lastPathComponent), "can_resume": .bool(!running && plan.canResume),
         "interrupted": .bool(!running && plan.state == "running"), "completed_groups": .int(plan.groups.filter { $0.state == "completed" }.count),
         "error_count": .int(plan.groups.filter { $0.selected && $0.state == "needsReview" }.count),
         "skipped_groups": .int(plan.groups.filter { $0.selected && $0.state == "skippedConflict" }.count), "omitted_count": .int(plan.omitted.count)]
    }

    nonisolated private static func copyState(_ plan: CopyPlan, publicationCount: Int) -> Job.State {
        if plan.state == "completed" { return .succeeded }
        if plan.state == "cancelled" { return .cancelled }
        return publicationCount > 0 || plan.groups.contains(where: { $0.state == "completed" }) ? .partial : .failed
    }

    nonisolated private static func copyItems(_ plan: CopyPlan, catalog: CatalogStore) -> (items: [Value], published: Int) {
        let target = try? AccessLease(bookmark: plan.targetBookmark)
        defer { withExtendedLifetime(target) {} }
        let accessible = target?.url.resolvingSymlinksInPath().standardizedFileURL.path == plan.targetRoot.path
        var identities: [String: FileIdentity] = [:]
        if accessible {
            for member in plan.groups.filter(\.selected).flatMap(\.members) where member.state != "planned" || member.stagedIdentity != nil {
                if member.destination.path.hasPrefix(plan.targetRoot.path + "/"), member.destination.resolvingSymlinksInPath() == member.destination.standardizedFileURL {
                    identities[member.id] = try? FileIdentity.read(member.destination)
                }
            }
        }
        let versions: [String: String] = (try? catalog.database.read { db in
            var ids = [String: String]()
            for member in plan.groups.filter(\.selected).flatMap(\.members) where member.isImage {
                let identity = member.stagedIdentity ?? member.reusedIdentity
                if let identity {
                    ids[member.id] = try String.fetchOne(db, sql: "SELECT id FROM photo WHERE identityKey=? AND deleted=0 ORDER BY copyName IS NOT NULL, id LIMIT 1", arguments: [identity.key])
                }
            }
            return ids
        }) ?? [:]
        var items: [Value] = [], published = 0
        for group in plan.groups {
            items.append(["kind": "group", "group_id": .string(group.id), "state": group.selected ? .string(group.state) : "unselected",
                          "name": .string(group.members.first?.source.lastPathComponent ?? ""),
                          "error_code": group.state == "needsReview" ? "copy_group_incomplete" : .null])
            for member in group.members {
                let logged = ["published", "completed"].contains(member.state)
                let publication: String
                if let staged = member.stagedIdentity, identities[member.id] == staged {
                    publication = logged ? "verified" : "present_at_staged_identity"
                    published += 1
                } else if let reused = member.reusedIdentity, identities[member.id] == reused {
                    publication = "reused"
                    published += 1
                } else if logged {
                    let recordedIdentity = member.stagedIdentity ?? member.reusedIdentity
                    publication = accessible && recordedIdentity != nil ? "changed_or_missing" : "published_in_journal"
                } else {
                    publication = member.stagedIdentity != nil && !accessible ? "unknown" : "not_published"
                }
                let recovery = member.recovery == nil ? "none" : member.recoveryState ?? "recorded"
                items.append(["kind": "file", "group_id": .string(group.id), "member_id": .string(member.id),
                              "name": .string(member.source.lastPathComponent), "destination_name": .string(Self.relative(member.destination, in: plan.targetRoot)),
                              "journal_state": .string(member.state), "publication": .string(publication), "is_photo": .bool(member.isImage),
                              "photo_id": versions[member.id].map(Value.string) ?? .null, "recovery_state": .string(recovery)])
            }
        }
        return (items, published)
    }

    private func checkCollection(_ id: String?) throws {
        if let id, !model.collections.contains(where: { $0.id == id && !$0.isSmart }) {
            throw MCPToolProblem.invalid("Use the ID of a regular collection from list_library_sources.")
        }
    }
    nonisolated private static func relative(_ url: URL, in root: URL) -> String {
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }
    static let missingRecord = MCPToolProblem(code: "import_record_unavailable", summary: "The import record or requested recovery action is unavailable.", next: "Read list_import_records and get_job for current recovery options.")
}
