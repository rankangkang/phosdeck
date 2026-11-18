import Darwin
import Foundation
import Security

let hostID = "dev.cmkk.phosdeck.pluginprobe"
let bundledID = "dev.cmkk.phosdeck.pluginprobe.tone"
let vendorID = "dev.cmkk.phosdeck.probevendor.tone"

@objc(PhosdeckPluginProbeBootstrap)
protocol ProbeBootstrap {
    func endpoint(mode: Int, reply: @escaping (String, NSXPCListenerEndpoint?) -> Void)
}

@objc(PhosdeckPluginProbeInlineReceiver)
protocol InlineReceiver {
    func fixture(reply: @escaping (FileHandle?) -> Void)
}

@objc(PhosdeckPluginProbeRPC)
protocol ProbeRPC {
    func describe(reply: @escaping (String, Int, Int32) -> Void)
    func evaluate(width: Int, height: Int, bytes: Int, revision: Int, strength: Float, input: FileHandle,
                  reply: @escaping (Int, FileHandle?, Double, Double, Double, Int64, String) -> Void)
    func readHostFile(path: String, reply: @escaping (Int32) -> Void)
    func fault(_ mode: String, reply: @escaping (Int32) -> Void)
}

struct ProbeError: LocalizedError {
    var errorDescription: String?
    init(_ detail: String) { errorDescription = detail }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProbeError(message) }
}

func ownTeam() throws -> String {
    var code: SecCode?
    try require(SecCodeCopySelf([], &code) == errSecSuccess, "SecCodeCopySelf")
    var staticCode: SecStaticCode?
    try require(SecCodeCopyStaticCode(code!, [], &staticCode) == errSecSuccess, "SecCodeCopyStaticCode")
    var info: CFDictionary?
    try require(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                "SecCodeCopySigningInformation")
    guard let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else {
        throw ProbeError("Apple-issued code signing identity required")
    }
    return team
}

func requirement(id: String, team: String) throws -> String {
    try require(id == hostID || id == bundledID || id == vendorID, "unexpected peer bundle ID")
    try require(team.range(of: #"\A[A-Z0-9]{10}\z"#, options: .regularExpression) != nil, "invalid Team ID")
    return "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
}

func otherTeam(_ team: String) -> String { team == "AAAAAAAAAA" ? "BBBBBBBBBB" : "AAAAAAAAAA" }

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func elapsed(_ start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

struct Frame {
    let width: Int
    let height: Int
    let bytes: Int
    var rowBytes: Int { width * 16 }

    init(_ width: Int, _ height: Int) throws {
        try require((1...12_000).contains(width) && (1...12_000).contains(height), "invalid frame dimensions")
        try require(width * height <= 60_000_000, "frame exceeds probe byte budget")
        self.width = width
        self.height = height
        bytes = width * height * 16
    }

    func check(_ handle: FileHandle) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        try require(flags >= 0 && flags & O_ACCMODE == O_RDONLY, "expected a read-only descriptor")
        var status = stat()
        try require(fstat(fd, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG, "expected a regular file")
        try require(status.st_size == bytes, "frame length \(status.st_size) differs from \(bytes)")
    }

    func read(_ handle: FileHandle) throws -> Data {
        try check(handle)
        var copy = Data(count: bytes)
        try copy.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < bytes {
                let count = pread(handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset), bytes - offset, off_t(offset))
                if count == -1 && errno == EINTR { continue }
                try require(count > 0, "frame read ended early")
                offset += count
            }
        }
        try check(handle)
        return copy
    }

    func validate(_ data: Data) throws {
        try require(data.count == bytes, "invalid pixel count")
        try data.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: SIMD4<Float>.self)
            for p in pixels {
                if !(p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite && (0...1).contains(p.w))
                    || (p.w == 0 && p != .zero) {
                    throw ProbeError("invalid float pixel or alpha")
                }
            }
        }
    }
}

// Unlink only this process's own temporary file after opening the read end.
func readOnlyFile(_ write: (FileHandle) throws -> Void) throws -> FileHandle {
    var path = URL.temporaryDirectory.appendingPathComponent("phosdeck-probe.XXXXXXXX").path.utf8CString
    let fd = path.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
    try require(fd >= 0, "mkstemp: errno \(errno)")
    let file = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    defer { _ = unlink(file) }
    let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? writer.close() }
    try write(writer)
    try writer.close()
    let reader = open(file, O_RDONLY | O_CLOEXEC)
    try require(reader >= 0, "open output: errno \(errno)")
    return FileHandle(fileDescriptor: reader, closeOnDealloc: true)
}

func readOnlyFile(_ pixels: Data) throws -> FileHandle {
    try readOnlyFile { try $0.write(contentsOf: pixels) }
}

func warm(_ data: inout Data, strength: Float) {
    let gain = SIMD4<Float>(1 + 0.12 * strength, 1 + 0.02 * strength, 1 - 0.12 * strength, 1)
    data.withUnsafeMutableBytes { raw in
        let pixels = raw.bindMemory(to: SIMD4<Float>.self)
        for i in pixels.indices { pixels[i] *= gain }
    }
}
