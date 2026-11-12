import Foundation
import MCP

struct MCPCameraReport {
    let id: String
    let report: CameraDiagnosticReport
    let results: [CameraDiagnosticResult]
}

extension AppMCPWorkflows {
    func runCameraDiagnostics(_ args: Arguments) throws -> MCPToolResult {
        let grant = try self.grant(args["access_id"], purpose: .cameraSamples)
        return start(.runCameraDiagnostics) { job in
            defer { withExtendedLifetime(grant) {} }
            self.cameraReport = nil
            self.running(job, phase: "finding_raw_samples")
            var report = CameraDiagnosticReport.empty()
            var results: [CameraDiagnosticResult] = []
            var candidateCount = 0
            do {
                let files = try await CameraDiagnostics.files(in: grant.url)
                try Task.checkCancellation()
                candidateCount = files.count
                report.requestedFiles = min(candidateCount, CameraDiagnostics.maximumSamples)
                if !files.isEmpty {
                    let service = CameraDiagnostics()
                    self.running(job, phase: "checking_raw_samples")
                    for (index, file) in files.prefix(report.requestedFiles).enumerated() {
                        self.progress(job, title: "Checking RAW samples", done: index, total: report.requestedFiles)
                        let result = try await service.inspect(file, index: index + 1)
                        try Task.checkCancellation()
                        results.append(result)
                        report.photos.append(result.photo)
                        job.items.append(Self.cameraRow(result))
                    }
                    self.progress(job, title: "Checking RAW samples", done: results.count, total: report.requestedFiles)
                    report.completed = true
                }
                self.recordCameraCheck(report, results: results, candidates: candidateCount, job: job)
                job.finish(.succeeded, files.isEmpty ? "No supported RAW files were found in this folder." : "Finished checking the selected RAW samples.")
            } catch is CancellationError {
                self.recordCameraCheck(report, results: results, candidates: candidateCount, job: job)
                job.finish(.cancelled, "Stopped checking RAW samples.")
            }
        }
    }

    private func recordCameraCheck(_ report: CameraDiagnosticReport, results: [CameraDiagnosticResult], candidates: Int, job: Job) {
        if !results.isEmpty { cameraReport = MCPCameraReport(id: job.id, report: report, results: results) }
        var counts = [String: Value]()
        for verdict in ["passed", "warning", "failed", "skipped"] {
            counts[verdict] = .int(report.photos.filter { $0.outcome.rawValue == verdict }.count)
        }
        job.data.merge(["report_id": results.isEmpty ? .null : .string(job.id), "candidate_count": .int(candidates),
                        "requested_count": .int(report.requestedFiles), "checked_count": .int(results.count),
                        "completed": .bool(report.completed), "app_version": .string(report.appVersion),
                        "system": .string(report.system), "outcomes": .object(counts)]) { _, new in new }
    }

    func readCameraDiagnosticPreview(_ args: Arguments) async throws -> MCPToolResult {
        let report = try currentCameraReport(args["report_id"])
        let index = args["sample_index"]!.intValue!
        let kind = args["preview_kind"]?.stringValue ?? "rendered"
        guard let row = report.results.first(where: { $0.photo.id == index }) else {
            throw MCPToolProblem.invalid("Use a sample_index from the diagnostic report.")
        }
        guard let image = kind == "embedded" ? row.embedded : row.rendered else {
            throw MCPToolProblem(code: "diagnostic_preview_unavailable", summary: "This sample did not produce the requested preview.",
                                 next: "Read the sample checks and preview availability in get_job.")
        }
        let png = try await Task.detached { try MCPOutputImage.png(image) }.value
        try Task.checkCancellation()
        _ = try currentCameraReport(args["report_id"])
        return .init("Read a camera diagnostic preview.", data: [
            "report_id": .string(report.id), "sample_index": .int(index), "preview_kind": .string(kind),
            "width": .int(image.width), "height": .int(image.height)
        ], image: png)
    }

    func saveCameraDiagnosticReport(_ args: Arguments) throws -> MCPToolResult {
        let report = try currentCameraReport(args["report_id"])
        let grant = try self.grant(args["destination_access_id"], purpose: .cameraReportDestination)
        return start(.saveCameraDiagnosticReport) { job in
            defer { withExtendedLifetime(grant) {} }
            self.running(job, phase: "writing_camera_report")
            job.data.merge(["report_id": .string(report.id), "published": false, "verified": false,
                            "completed": .bool(report.report.completed), "checked_count": .int(report.report.photos.count),
                            "destination_name": .string(grant.url.lastPathComponent)]) { _, new in new }
            do {
                let filename = try await CameraDiagnostics.save(report.report, in: grant.url)
                job.data.merge(["filename": .string(filename), "published": true, "verified": true]) { _, new in new }
                job.finish(.succeeded, "Wrote and verified the local camera report.", committed: "committed")
            } catch let published as CameraDiagnosticPublicationError {
                self.model.error = published.localizedDescription
                job.data.merge(["filename": .string(published.filename), "published": true]) { _, new in new }
                job.data["follow_up"] = "Inspect the saved report in the selected folder."
                job.finish(.partial, "The camera report was published and needs verification.",
                           committed: "committed", error: "camera_report_verification_failed")
            }
        }
    }

    private func currentCameraReport(_ id: Value?) throws -> MCPCameraReport {
        guard let report = cameraReport, id == .string(report.id) else {
            throw MCPToolProblem(code: "camera_report_unavailable", summary: "The requested camera report is no longer available.",
                                 next: "Use the report_id from the latest camera diagnostic job.")
        }
        return report
    }

    private static func cameraRow(_ result: CameraDiagnosticResult) -> Value {
        let photo = result.photo
        return ["sample_index": .int(photo.id), "filename": .string(result.filename),
                "outcome": .string(photo.outcome.rawValue), "camera": .string(photo.camera),
                "format": .string(photo.format), "decoder": .string(photo.decoder),
                "pipeline_version": photo.pipelineVersion.map(Value.int) ?? .null,
                "width": .int(photo.width), "height": .int(photo.height), "compression": .string(photo.compression),
                "sensor_bits": photo.sensorBits.map(Value.int) ?? .null,
                "rendered_preview_available": .bool(result.rendered != nil), "embedded_preview_available": .bool(result.embedded != nil),
                "checks": .array(photo.checks.map { ["id": .string($0.id), "verdict": .string($0.verdict.rawValue), "detail": .string($0.detail)] })]
    }
}
