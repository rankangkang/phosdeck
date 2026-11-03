// Freeze the authorized Canon CC0 source for ordinary-image comparison only.
// macOS SDK only; this does not compare the applications' RAW pipelines.
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func sha(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func failure(_ message: String) -> NSError {
  NSError(domain: "ExposurePublicFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
    throw failure(
      "Usage: swift scripts/lightroom-exposure-colour-public.swift AUTHORIZED_CANON_CR3 NEW_DIRECTORY"
    )
  }
  let source = URL(fileURLWithPath: CommandLine.arguments[1])
  let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
  let before = try Data(contentsOf: source)
  guard sha(before) == "1ba9ad6b51b315b88820eb0fe5fd7f52bc136ba37b1a5ca76825ebfe25b18058",
    !FileManager.default.fileExists(atPath: output.path),
    let raw = CIRAWFilter(imageURL: source)
  else { throw failure("Expected the recorded CC0 Canon source and a new directory") }
  raw.isDraftModeEnabled = false
  raw.extendedDynamicRangeAmount = 0
  guard let original = raw.outputImage else { throw failure("RAW derivative decode failed") }
  let scale = 960 / original.extent.width
  let small = original.clampedToExtent().applyingFilter(
    "CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
  let extent = CGRect(x: 0, y: 0, width: 960, height: floor(original.extent.height * scale))
  let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CIContext(options: [
    .workingFormat: CIFormat.RGBAf,
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
  ])
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
  var records = [[String: Any]]()
  for (name, type, format) in [
    ("k-cc0-canon-raster.tif", UTType.tiff, CIFormat.RGBA16),
    ("l-cc0-canon-raster.jpg", UTType.jpeg, CIFormat.RGBA8),
  ] {
    let path = output.appendingPathComponent(name)
    guard let image = context.createCGImage(small, from: extent, format: format, colorSpace: srgb),
      let destination = CGImageDestinationCreateWithURL(
        path as CFURL, type.identifier as CFString, 1, nil)
    else { throw failure("Derivative render/encoder failed") }
    CGImageDestinationAddImage(
      destination, image,
      [
        kCGImageDestinationLossyCompressionQuality: 1, kCGImagePropertyOrientation: 1,
      ] as CFDictionary)
    guard CGImageDestinationFinalize(destination),
      let readback = CGImageSourceCreateWithURL(path as CFURL, nil),
      let decoded = CGImageSourceCreateImageAtIndex(readback, 0, nil),
      decoded.width == image.width, decoded.height == image.height,
      decoded.bitsPerComponent == image.bitsPerComponent
    else { throw failure("Derivative encoding/readback failed") }
    let data = try Data(contentsOf: path)
    records.append([
      "path": name, "sha256": sha(data), "bytes": data.count,
      "width": image.width, "height": image.height, "bitsPerComponent": image.bitsPerComponent,
    ])
  }
  guard try sha(Data(contentsOf: source)) == sha(before) else { throw failure("Source changed") }
  let manifest: [String: Any] = [
    "source": relativePath(source.path, to: output), "source_sha256": sha(before),
    "authorization": "Tests/Fixtures/public-raw-samples.json CC0", "decoder": raw.decoderVersion.rawValue,
    "kind": "frozen ordinary sRGB TIFF/JPEG derivative; not a RAW comparison", "outputs": records,
  ]
  let data = try JSONSerialization.data(
    withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
  print(String(data: data, encoding: .utf8)!)
} catch {
  fputs("Exposure public fixture: \(error.localizedDescription)\n", stderr)
  exit(1)
}
