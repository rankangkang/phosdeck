import CoreImage
import Foundation
import ImageIO

struct CameraDiagnosticCheck: Codable, Equatable, Identifiable {
    enum Verdict: String, Codable { case passed, warning, failed, skipped }
    let id: String
    let verdict: Verdict
    let detail: String
}

/// Portable evidence; excludes source paths, filenames, owner/GPS/serial fields and pixels.
struct CameraDiagnosticReport: Codable {
    var version = 1
    let appVersion: String
    let system: String
    var requestedFiles = 0
    var completed = false
    var photos: [Photo] = []
    struct Photo: Codable, Identifiable {
        let id: Int
        var camera = ""
        var format = ""
        var decoder = ""
        var pipelineVersion: Int?
        var sourceDigest = ""
        var width = 0
        var height = 0
        // ImageIO's displayed pixel depth is not the sensor's bit depth or RAW compression.
        var compression: String = "unknown"
        var sensorBits: Int? = nil
        var checks: [CameraDiagnosticCheck] = []
        /// A completed inspection is file-specific evidence; skipped measurements stay unverified.
        var outcome: CameraDiagnosticCheck.Verdict {
            if checks.contains(where: { $0.verdict == .failed }) { return .failed }
            if checks.contains(where: { $0.verdict == .warning }) { return .warning }
            if checks.contains(where: { $0.verdict == .passed }) { return .passed }
            return .skipped
        }
    }
    static func empty() -> Self {
        let bundle = Bundle.main
        return Self(appVersion: "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"))",
                    system: ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

struct CameraDiagnosticResult {
    let photo: CameraDiagnosticReport.Photo
    let filename: String
    let rendered: CGImage?
    let embedded: CGImage?
}

struct CameraDiagnosticPublicationError: LocalizedError {
    let filename: String
    var errorDescription: String? {
        L10n.text("camera.reportReadback", defaultValue: "Report read-back verification failed.")
    }
}

/// A dedicated actor keeps full RAW validation, file hashing and pixel comparisons off MainActor.
/// Camera Bench's evidence/check separation is inspired by Redlamp 21ff73eb (2026-11-01);
/// this is a native implementation of our Apple RAW and current rendering contract.
actor CameraDiagnostics {
    static let maximumSamples = 32

    static func files(in folder: URL) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            return try urls.filter { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true && PhotoFileType.isRAW(url)
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }.value
    }

    static func save(_ report: CameraDiagnosticReport, in folder: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            let lease = AccessLease(url: folder)
            defer { withExtendedLifetime(lease) {} }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report), name = "Phosdeck-camera-check-\(UUID().uuidString).json"
            let destination = folder.appendingPathComponent(name)
            try Task.checkCancellation()
            try SafeFileWriter.write(data, to: destination)
            guard (try? Data(contentsOf: destination)) == data else { throw CameraDiagnosticPublicationError(filename: name) }
            return name
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func inspect(_ url: URL, index: Int) async throws -> CameraDiagnosticResult {
        let lease = AccessLease(url: url)
        defer { withExtendedLifetime(lease) {} }
        var row = CameraDiagnosticReport.Photo(id: index, format: url.pathExtension.uppercased())
        var rendered: CGImage?, embedded: CGImage?
        var stage = "decode"
        func check(_ id: String, _ verdict: CameraDiagnosticCheck.Verdict, _ detail: String) {
            row.checks.append(CameraDiagnosticCheck(id: id, verdict: verdict, detail: detail))
        }
        do {
            try Task.checkCancellation()
            guard PhotoFileType.isRAW(url) else { throw LRCError(L10n.text("camera.rawOnly", defaultValue: "Choose a RAW format currently supported by Phosdeck.")) }
            let source = try PhotoFileType.imageSource(url)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            let tiff = properties?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            row.camera = tiff?[kCGImagePropertyTIFFModel as String] as? String ?? ""
            row.sourceDigest = try SafeFileWriter.sha256(url)
            let parent = url.deletingLastPathComponent()
            let root = StorageRoot(id: UUID().uuidString, path: parent.path, bookmark: try AccessLease.bookmark(parent, readOnly: true), label: "diagnostic")
            let photo = try ReferenceImporter.inspect(url: url, root: root, rootURL: parent)
            let pipeline = ImagePipeline(), request = ImageRequest(photo: photo, root: root, recipe: nil)
            let recipe = try await pipeline.baseline(request)
            row.decoder = recipe.decoderVersion
            row.pipelineVersion = recipe.pipelineVersion
            let job = ImageRequest(photo: photo, root: root, recipe: recipe)
            let quality = try await pipeline.render(job, longEdge: 256)
            rendered = quality.image
            row.width = Int(quality.orientedSourceSize.width); row.height = Int(quality.orientedSourceSize.height)
            check("decode", .passed, L10n.text("camera.decoded", defaultValue: "The full RAW data was evaluated and a default rendering was produced."))
            let reference = Self.pixels(quality.image)
            stage = "repeat"
            let repeated = try await ImagePipeline().render(job, longEdge: 256)
            let delta = Self.maximumDifference(reference, Self.pixels(repeated.image))
            check("repeat", delta == 0 ? .passed : .warning,
                  L10n.text("camera.repeat", defaultValue: "Fresh-pipeline repeat, maximum 8-bit channel difference: ") + String(delta))
            stage = "afterDraft"
            _ = try await pipeline.renderInteractive(job, longEdge: 256)
            let afterDraft = try await pipeline.render(job, longEdge: 256)
            let draftDelta = Self.maximumDifference(reference, Self.pixels(afterDraft.image))
            check("afterDraft", draftDelta == 0 ? .passed : .warning,
                  L10n.text("camera.afterDraft", defaultValue: "Quality rendering after draft, maximum channel difference: ") + String(draftDelta))
            stage = "thumbnail"
            let thumbnail = try await ThumbnailService().image(photo: photo, root: root, edge: 256)
            let thumbDelta = Self.maximumDifference(reference, Self.pixels(thumbnail))
            check("thumbnail", thumbDelta == 0 ? .passed : .warning,
                  L10n.text("camera.thumbnail", defaultValue: "Default thumbnail, maximum channel difference: ") + String(thumbDelta))
            stage = "sixteenBit"
            let deep = try await pipeline.render(job, longEdge: 256, pixelFormat: .RGBA16)
            check("sixteenBit", deep.image.bitsPerComponent == 16 ? .passed : .failed,
                  L10n.text("camera.sixteenBit", defaultValue: "16-bit rendering, bits per channel: ") + String(deep.image.bitsPerComponent))
            // Never generate a substitute when no embedded thumbnail exists.
            embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary)
            check("embeddedReference", embedded == nil ? .skipped : .passed,
                  embedded == nil ? L10n.text("camera.noEmbedded", defaultValue: "No readable embedded preview. Reference comparison skipped.")
                  : L10n.text("camera.embedded", defaultValue: "Embedded preview available for visual reference. Its camera style is not a color-accuracy target."))
            check("sensorMeasurements", .skipped, L10n.text("camera.sensorUnavailable", defaultValue: "Sensor black/white levels, bit depth and compression are not verified by the Apple RAW path."))
            try Task.checkCancellation()
            stage = "sourceIdentity"
            guard try FileIdentity.read(url) == JSONDecoder().decode(FileIdentity.self, from: photo.identity),
                  try SafeFileWriter.sha256(url) == row.sourceDigest else {
                throw LRCError(L10n.text("camera.changed", defaultValue: "The source changed during the check. Results are invalid."))
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // An error may contain a source path. Portable reports must not carry it.
            let message = error.localizedDescription.replacingOccurrences(of: url.path, with: "<source>")
                .replacingOccurrences(of: url.absoluteString, with: "<source>")
                .replacingOccurrences(of: url.lastPathComponent, with: "<source>")
                .replacingOccurrences(of: url.deletingLastPathComponent().path, with: "<folder>")
            if stage == "sourceIdentity" { row.checks = []; rendered = nil; embedded = nil }
            row.checks.append(CameraDiagnosticCheck(id: stage, verdict: .failed, detail: message))
        }
        return CameraDiagnosticResult(photo: row, filename: url.lastPathComponent, rendered: rendered, embedded: embedded)
    }

    static func maximumDifference(_ a: Data, _ b: Data) -> Int {
        guard a.count == b.count else { return 255 }
        return zip(a, b).reduce(0) { max($0, abs(Int($1.0)-Int($1.1))) }
    }
    private static func pixels(_ image: CGImage) -> Data {
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        var data = Data(count: image.width*image.height*4)
        data.withUnsafeMutableBytes {
            context.render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: image.width*4,
                           bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
        }
        return data
    }
}
