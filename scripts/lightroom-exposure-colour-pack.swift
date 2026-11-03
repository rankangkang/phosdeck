// macOS SDK only. Pack independently measured signed residuals, never Adobe code
// or profiles. Input is the checked calibration manifest, output must be new.
// CLI paths are relative to the working directory; row files are relative to the manifest.
import CryptoKit
import Darwin
import Foundation

func sha(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func fail(_ text: String) -> NSError {
  NSError(domain: "ExposureColourPack", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}
func relativePath(_ path: String, to directory: URL) -> String {
  let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
  let base = directory.standardizedFileURL.pathComponents
  let common = zip(target, base).prefix { $0.0 == $0.1 }.count
  let parts = Array(repeating: "..", count: base.count - common) + target.dropFirst(common)
  return parts.isEmpty ? "." : parts.joined(separator: "/")
}
do {
  guard CommandLine.arguments.count == 3 else {
    throw fail("Usage: swift scripts/lightroom-exposure-colour-pack.swift MANIFEST NEW_BIN")
  }
  let input = URL(fileURLWithPath: CommandLine.arguments[1])
  let output = URL(fileURLWithPath: CommandLine.arguments[2])
  guard !FileManager.default.fileExists(atPath: output.path) else {
    throw fail("Output already exists")
  }
  let source = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any]
  guard source?["version"] as? Int == 2, source?["dimension"] as? Int == 65,
    let entries = source?["rows"] as? [[String: Any]], entries.count == 41
  else { throw fail("Expected 41 measured 65-cubed rows") }
  var rows = [[String: Any]]()
  var payload = Data()
  for (index, entry) in entries.enumerated() {
    guard entry["index"] as? Int == index, entry["ev"] as? Double == Double(index) / 4 - 5,
      let power = entry["axis_power"] as? Int, power == (index > 20 ? 2 : 1),
      let path = entry["file"] as? String, let digest = entry["payload_sha256"] as? String
    else { throw fail("Invalid calibration row") }
    let rawURL = URL(fileURLWithPath: path, relativeTo: input.deletingLastPathComponent())
      .standardizedFileURL
    let raw = try Data(contentsOf: rawURL)
    guard raw.count == 65 * 65 * 65 * 6, sha(raw) == digest,
      index != 20 || raw.allSatisfy({ $0 == 0 })
    else { throw fail("Calibration payload mismatch") }
    let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
    guard try (compressed as NSData).decompressed(using: .lzfse) as Data == raw else {
      throw fail("Compression readback mismatch")
    }
    rows.append([
      "index": index, "axisPower": power, "offset": payload.count,
      "compressedBytes": compressed.count, "rawBytes": raw.count, "sha256": digest,
      "sourceExportSHA256": entry["source_output_sha256"] ?? "",
    ])
    payload.append(compressed)
  }
  let header = try JSONSerialization.data(
    withJSONObject: ["version": 4, "dimension": 65, "denominator": 65535, "rows": rows],
    options: [.sortedKeys])
  guard header.count <= 65536 else { throw fail("Header too large") }
  var archive = Data("OMLRCEX4".utf8)
  var length = UInt32(header.count).littleEndian
  withUnsafeBytes(of: &length) { archive.append(contentsOf: $0) }
  archive.append(header)
  archive.append(payload)
  // Same-volume staging, flush, exclusive hard-link publication, then readback.
  let temporary = output.deletingLastPathComponent().appendingPathComponent(
    ".exposure-pack-\(UUID().uuidString).tmp")
  let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
  guard fd >= 0 else { throw fail("Could not create owned staging file: \(errno)") }
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  defer {
    try? handle.close()
    unlink(temporary.path)
  }
  try handle.write(contentsOf: archive)
  try handle.synchronize()
  try handle.close()
  guard link(temporary.path, output.path) == 0 else {
    throw fail("Exclusive publication failed: \(errno)")
  }
  let directoryFD = open(output.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
  guard directoryFD >= 0 else { throw fail("Could not open output directory") }
  let flushed = fsync(directoryFD)
  close(directoryFD)
  guard flushed == 0, try Data(contentsOf: output) == archive else {
    throw fail("Published archive readback mismatch")
  }
  let summary: [String: Any] = [
    "path": relativePath(output.path, to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
    "bytes": archive.count, "sha256": sha(archive),
    "rawBytes": 41 * 65 * 65 * 65 * 6, "manifestSHA256": sha(try Data(contentsOf: input)),
  ]
  print(
    String(
      data: try JSONSerialization.data(
        withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
} catch {
  fputs("Exposure colour pack: \(error.localizedDescription)\n", stderr)
  exit(1)
}
