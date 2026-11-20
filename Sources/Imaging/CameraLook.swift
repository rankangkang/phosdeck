import CoreImage
import CryptoKit
import Foundation
import simd

/// Versioned camera look identifier stored independently on a RAW `EditRecipe`.
/// `nil` on `EditRecipe.cameraLook` represents the default native RAW rendering.
struct CameraLookSelection: Codable, Equatable, Hashable, Sendable {
    var id: String
    var version: Int

    func validateSyntax() throws {
        guard Self.isValidIdentifier(id), (1...9999).contains(version) else {
            throw LRCError(L10n.text("cameraLook.invalidSelection", defaultValue: "Invalid camera look identifier or version"))
        }
    }

    static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...80).contains(value.utf8.count),
              value.first != ".", value.last != ".", !value.contains("..") else { return false }
        return value.utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }
}

struct CameraLookGroup: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let localizedTitles: [String: String]

    func displayTitle(language: String = L10n.current.language) -> String {
        localizedTitles[language] ?? localizedTitles["en"] ?? title
    }
}

struct CameraLookEntry: Equatable, Identifiable, Sendable {
    let selection: CameraLookSelection
    let group: String
    let title: String
    let localizedTitles: [String: String]
    let diagnostic: Bool
    let selectable: Bool
    let file: String
    let dimension: Int
    let upperBound: Float
    let sha256: String

    var id: CameraLookSelection { selection }

    func displayTitle(language: String = L10n.current.language) -> String {
        localizedTitles[language] ?? localizedTitles["en"] ?? title
    }
}

/// Verified floating-point 3D lookup table backed by an immutable `.RGBAh` 2D atlas.
struct CameraLookTable: @unchecked Sendable {
    static let magic = Data("PHOSLK01".utf8)
    static let dimensionRange = 17...65
    static let upperBoundRange: ClosedRange<Float> = 0.5...16.0

    let selection: CameraLookSelection
    let dimension: Int
    let upperBound: Float
    let texels: [SIMD4<Float16>]
    let atlas: CIImage

    init(selection: CameraLookSelection, dimension: Int, upperBound: Float, rgbTriplets: [Float16]) throws {
        guard Self.dimensionRange.contains(dimension),
              upperBound.isFinite, Self.upperBoundRange.contains(upperBound) else {
            throw LRCError(L10n.text("cameraLook.corruptResource", defaultValue: "Camera look resource has unsupported table geometry"))
        }
        let nodeCount = dimension * dimension * dimension
        guard rgbTriplets.count == nodeCount * 3 else {
            throw LRCError(L10n.text("cameraLook.corruptResource", defaultValue: "Camera look resource has unsupported table geometry"))
        }
        let minAllowed: Float = -1.0
        let maxAllowed: Float = upperBound + 1.0
        var texels = [SIMD4<Float16>]()
        texels.reserveCapacity(nodeCount)
        for index in 0..<nodeCount {
            let r = rgbTriplets[index * 3]
            let g = rgbTriplets[index * 3 + 1]
            let b = rgbTriplets[index * 3 + 2]
            guard r.isFinite, g.isFinite, b.isFinite,
                  (minAllowed...maxAllowed).contains(Float(r)),
                  (minAllowed...maxAllowed).contains(Float(g)),
                  (minAllowed...maxAllowed).contains(Float(b)) else {
                throw LRCError(L10n.text("cameraLook.corruptValues", defaultValue: "Camera look resource contains out-of-range or non-finite values"))
            }
            texels.append(SIMD4(r, g, b, 1))
        }
        self.selection = selection
        self.dimension = dimension
        self.upperBound = upperBound
        self.texels = texels
        let width = dimension * dimension
        self.atlas = CIImage(
            bitmapData: texels.withUnsafeBytes { Data($0) },
            bytesPerRow: width * MemoryLayout<SIMD4<Float16>>.stride,
            size: CGSize(width: width, height: dimension),
            format: .RGBAh,
            colorSpace: nil
        ).samplingNearest()
    }

    static func encode(_ value: Float, upperBound: Float) -> Float {
        log2(1 + value / 0.18) / log2(1 + upperBound / 0.18)
    }

    static func decode(_ coordinate: Float, upperBound: Float) -> Float {
        0.18 * (exp2(coordinate * log2(1 + upperBound / 0.18)) - 1)
    }

    static func serializedData(dimension: Int, upperBound: Float, transform: (SIMD3<Float>) -> SIMD3<Float>) throws -> Data {
        guard dimensionRange.contains(dimension), upperBound.isFinite, upperBoundRange.contains(upperBound) else {
            throw LRCError(L10n.text("cameraLook.corruptResource", defaultValue: "Camera look resource has unsupported table geometry"))
        }
        var data = Data()
        data.reserveCapacity(16 + dimension * dimension * dimension * 6)
        data.append(magic)
        withUnsafeBytes(of: UInt32(dimension).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: upperBound.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        let step = 1 / Float(dimension - 1)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let input = SIMD3(
                        decode(Float(r) * step, upperBound: upperBound),
                        decode(Float(g) * step, upperBound: upperBound),
                        decode(Float(b) * step, upperBound: upperBound)
                    )
                    let out = transform(input)
                    for channel in [Float16(out.x), Float16(out.y), Float16(out.z)] {
                        withUnsafeBytes(of: channel.bitPattern.littleEndian) { data.append(contentsOf: $0) }
                    }
                }
            }
        }
        return data
    }

    /// CPU tetrahedral reference matching `cameraLook` in `DevelopKernels.metal`.
    func referenceSample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let bounded = simd_clamp(rgb, .zero, SIMD3(repeating: upperBound))
        let coordinate = SIMD3(
            Self.encode(bounded.x, upperBound: upperBound),
            Self.encode(bounded.y, upperBound: upperBound),
            Self.encode(bounded.z, upperBound: upperBound)
        ) * Float(dimension - 1)
        var corner = SIMD3<Int>(
            min(max(Int(floor(coordinate.x)), 0), dimension - 2),
            min(max(Int(floor(coordinate.y)), 0), dimension - 2),
            min(max(Int(floor(coordinate.z)), 0), dimension - 2)
        )
        let offset = simd_clamp(coordinate - SIMD3(Float(corner.x), Float(corner.y), Float(corner.z)), .zero, SIMD3(repeating: 1))
        let axes = [0, 1, 2].sorted { offset[$0] > offset[$1] }
        func node(_ p: SIMD3<Int>) -> SIMD3<Float> {
            let value = texels[(p.z * dimension + p.y) * dimension + p.x]
            return SIMD3(Float(value.x), Float(value.y), Float(value.z))
        }
        var previous = node(corner)
        var output = previous
        for axis in axes {
            corner[axis] += 1
            let next = node(corner)
            output += (next - previous) * offset[axis]
            previous = next
        }
        return output + (rgb - bounded)
    }
}

/// Manifest-backed catalog of versioned camera look tables.
final class CameraLookLibrary: @unchecked Sendable {
    private final class Resources {}

    private struct ManifestPayload: Decodable {
        struct GroupRecord: Decodable {
            let id: String
            let title: String
            let localizedTitles: [String: String]?
        }
        struct LookRecord: Decodable {
            let id: String
            let version: Int
            let group: String
            let title: String
            let localizedTitles: [String: String]?
            let diagnostic: Bool?
            let selectable: Bool?
            let file: String
            let dimension: Int
            let upperBound: Float
            let sha256: String
        }
        let formatVersion: Int
        let groups: [GroupRecord]?
        let looks: [LookRecord]
    }

    private struct CatalogData {
        let directory: URL
        let groups: [CameraLookGroup]
        let orderedEntries: [CameraLookEntry]
        let entriesBySelection: [CameraLookSelection: CameraLookEntry]
    }

    static var defaultIncludesDiagnosticLooks: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.bundleIdentifier == "dev.cmkk.oh-my-lrc.unratedstars20261021"
        #endif
    }

    static let shared = CameraLookLibrary()

    let includesDiagnosticLooks: Bool
    private let catalog: Result<CatalogData, Error>
    private let lock = NSLock()
    private var cache: [CameraLookSelection: CameraLookTable] = [:]
    private var recent: [CameraLookSelection] = []
    private let cacheLimit = 8

    init(directory: URL? = nil, includesDiagnosticLooks: Bool = CameraLookLibrary.defaultIncludesDiagnosticLooks) {
        self.includesDiagnosticLooks = includesDiagnosticLooks
        self.catalog = Result {
            let folder: URL
            if let directory {
                folder = directory
            } else if let bundled = Bundle(for: Resources.self).url(forResource: "CameraLooks", withExtension: nil) {
                folder = bundled
            } else {
                throw LRCError(L10n.text("cameraLook.missingManifest", defaultValue: "Camera look resources are missing from the app bundle"))
            }
            return try Self.loadCatalog(at: folder)
        }
    }

    /// Selectable entries grouped in manifest order for the Develop menu.
    func menuSections() -> [(group: CameraLookGroup, entries: [CameraLookEntry])] {
        guard let state = try? catalog.get() else { return [] }
        let visible = state.orderedEntries.filter { $0.selectable && (!($0.diagnostic) || includesDiagnosticLooks) }
        guard !visible.isEmpty else { return [] }
        var sections = [(group: CameraLookGroup, entries: [CameraLookEntry])]()
        var seenGroups = Set<String>()
        for group in state.groups {
            let matching = visible.filter { $0.group == group.id }
            if !matching.isEmpty {
                sections.append((group, matching))
                seenGroups.insert(group.id)
            }
        }
        for entry in visible where !seenGroups.contains(entry.group) {
            let group = CameraLookGroup(id: entry.group, title: entry.group, localizedTitles: [:])
            sections.append((group, visible.filter { $0.group == entry.group }))
            seenGroups.insert(entry.group)
        }
        return sections
    }

    func entry(for selection: CameraLookSelection) -> CameraLookEntry? {
        (try? catalog.get())?.entriesBySelection[selection]
    }

    func title(for selection: CameraLookSelection, language: String = L10n.current.language) -> String {
        guard let state = try? catalog.get(), let item = state.entriesBySelection[selection] else {
            return "\(selection.id) (v\(selection.version))"
        }
        let base = item.displayTitle(language: language)
        let selectableVersions = state.orderedEntries.filter {
            $0.selection.id == selection.id && $0.selectable && (!$0.diagnostic || includesDiagnosticLooks)
        }
        if selectableVersions.contains(where: { $0.selection.version != selection.version }) || !item.selectable {
            return "\(base) (v\(selection.version))"
        }
        return base
    }

    func validate(_ selection: CameraLookSelection) throws {
        _ = try table(for: selection)
    }

    func table(for selection: CameraLookSelection) throws -> CameraLookTable {
        try selection.validateSyntax()
        let state = try catalog.get()
        guard let item = state.entriesBySelection[selection] else {
            throw LRCError(L10n.text("cameraLook.unavailableSelection", defaultValue: "Camera look “\(selection.id)” (v\(selection.version)) is unavailable in this build. Original data preserved"))
        }
        lock.lock()
        if let cached = cache[selection] {
            recent.removeAll { $0 == selection }
            recent.append(selection)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = try Self.loadTable(entry: item, in: state.directory)
        lock.lock()
        cache[selection] = loaded
        recent.removeAll { $0 == selection }
        recent.append(selection)
        while recent.count > cacheLimit {
            cache.removeValue(forKey: recent.removeFirst())
        }
        lock.unlock()
        return loaded
    }

    private static func loadCatalog(at directory: URL) throws -> CatalogData {
        let dirValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard dirValues.isDirectory == true, dirValues.isSymbolicLink != true else {
            throw LRCError(L10n.text("cameraLook.missingManifest", defaultValue: "Camera look resources are missing from the app bundle"))
        }
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        let manifestData = try readRegularFile(manifestURL, maxBytes: 1024 * 1024)
        let payload: ManifestPayload
        do {
            payload = try JSONDecoder().decode(ManifestPayload.self, from: manifestData)
        } catch {
            throw LRCError(L10n.text("cameraLook.invalidManifest", defaultValue: "Camera look manifest is unreadable or invalid"))
        }
        guard payload.formatVersion == 1 else {
            throw LRCError(L10n.text("cameraLook.invalidManifest", defaultValue: "Camera look manifest is unreadable or invalid"))
        }
        var groups = [CameraLookGroup]()
        var groupIDs = Set<String>()
        for group in payload.groups ?? [] {
            guard CameraLookSelection.isValidIdentifier(group.id),
                  !group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  groupIDs.insert(group.id).inserted else {
                throw LRCError(L10n.text("cameraLook.invalidManifest", defaultValue: "Camera look manifest is unreadable or invalid"))
            }
            groups.append(CameraLookGroup(id: group.id, title: group.title, localizedTitles: group.localizedTitles ?? [:]))
        }

        var ordered = [CameraLookEntry]()
        var bySelection = [CameraLookSelection: CameraLookEntry]()
        for item in payload.looks {
            let selection = CameraLookSelection(id: item.id, version: item.version)
            try selection.validateSyntax()
            guard CameraLookSelection.isValidIdentifier(item.group),
                  !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isSafeFileName(item.file),
                  CameraLookTable.dimensionRange.contains(item.dimension),
                  item.upperBound.isFinite, CameraLookTable.upperBoundRange.contains(item.upperBound),
                  item.sha256.utf8.count == 64,
                  item.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  bySelection[selection] == nil else {
                throw LRCError(L10n.text("cameraLook.invalidManifest", defaultValue: "Camera look manifest is unreadable or invalid"))
            }
            let entry = CameraLookEntry(
                selection: selection,
                group: item.group,
                title: item.title,
                localizedTitles: item.localizedTitles ?? [:],
                diagnostic: item.diagnostic ?? false,
                selectable: item.selectable ?? true,
                file: item.file,
                dimension: item.dimension,
                upperBound: item.upperBound,
                sha256: item.sha256
            )
            ordered.append(entry)
            bySelection[selection] = entry
        }
        return CatalogData(directory: directory, groups: groups, orderedEntries: ordered, entriesBySelection: bySelection)
    }

    private static func loadTable(entry: CameraLookEntry, in directory: URL) throws -> CameraLookTable {
        let fileURL = directory.appendingPathComponent(entry.file, isDirectory: false)
        let expectedPayloadBytes = entry.dimension * entry.dimension * entry.dimension * 6
        let expectedTotalBytes = 16 + expectedPayloadBytes
        let data = try readRegularFile(fileURL, maxBytes: 16 * 1024 * 1024)
        guard data.count == expectedTotalBytes else {
            throw LRCError(L10n.text("cameraLook.corruptResource", defaultValue: "Camera look resource has unsupported table geometry"))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            throw LRCError(L10n.text("cameraLook.verificationFailed", defaultValue: "Camera look resource checksum verification failed"))
        }
        guard data.prefix(8) == CameraLookTable.magic else {
            throw LRCError(L10n.text("cameraLook.corruptResource", defaultValue: "Camera look resource has unsupported table geometry"))
        }
        let headerDimension = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
        let headerUpperBits = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) }
        let headerUpper = Float(bitPattern: headerUpperBits)
        guard headerDimension == entry.dimension, headerUpper == entry.upperBound else {
            throw LRCError(L10n.text("cameraLook.corruptResource", defaultValue: "Camera look resource has unsupported table geometry"))
        }
        let scalarCount = entry.dimension * entry.dimension * entry.dimension * 3
        var triplets = [Float16]()
        triplets.reserveCapacity(scalarCount)
        data.withUnsafeBytes { raw in
            for index in 0..<scalarCount {
                let bits = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 16 + index * 2, as: UInt16.self))
                triplets.append(Float16(bitPattern: bits))
            }
        }
        return try CameraLookTable(selection: entry.selection, dimension: entry.dimension, upperBound: entry.upperBound, rgbTriplets: triplets)
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 120,
              !name.contains("/"), !name.contains("\\"), !name.contains(".."), !name.contains("\0"),
              name.first != "." else { return false }
        return true
    }

    private static func readRegularFile(_ url: URL, maxBytes: Int) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw LRCError(L10n.text("cameraLook.missingResourceFile", defaultValue: "Camera look resource file is missing"))
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= maxBytes else {
            throw LRCError(L10n.text("cameraLook.corruptResource", defaultValue: "Camera look resource has unsupported table geometry"))
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

enum CameraLookPipeline {
    static func apply(_ input: CIImage, selection: CameraLookSelection?, library: CameraLookLibrary = .shared) throws -> CIImage {
        guard let selection else { return input }
        let table = try library.table(for: selection)
        return try SpatialDevelopPipeline.cameraLook(input, atlas: table.atlas, dimension: table.dimension, upperBound: table.upperBound)
    }
}
