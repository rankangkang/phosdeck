#!/usr/bin/env swift
import CoreGraphics
import CoreImage
import CryptoKit
// Controlled synthetic JPEG fixture and ICC-normalized output comparison.
// Uses only the installed macOS SDK. It never launches either application.
import Foundation
import ImageIO
import UniformTypeIdentifiers

func relativePath(_ path: String, to directory: URL) -> String {
  let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
  let base = directory.standardizedFileURL.pathComponents
  let common = zip(target, base).prefix { $0.0 == $0.1 }.count
  let parts = Array(repeating: "..", count: base.count - common) + target.dropFirst(common)
  return parts.isEmpty ? "." : parts.joined(separator: "/")
}

func generate(_ path: String) throws {
  let root = URL(fileURLWithPath: path, isDirectory: true)
  guard !FileManager.default.fileExists(atPath: root.path) else {
    throw NSError(
      domain: "LightroomBaseline", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Fixture directory must be new"])
  }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let w = 640
  let h = 480
  var manifest = [[String: Any]]()
  for i in 0..<3 {
    var bytes = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h {
      for x in 0..<w {
        let j = (y * w + x) * 4
        if i == 0 {
          let v = UInt8(x * 255 / (w - 1))
          bytes[j] = v
          bytes[j + 1] = v
          bytes[j + 2] = v
        } else if i == 1 {
          bytes[j] = UInt8(x * 255 / (w - 1))
          bytes[j + 1] = UInt8(y * 255 / (h - 1))
          bytes[j + 2] = UInt8((x / 40 + y / 40) % 2 == 0 ? 48 : 208)
        } else {
          let colors: [[UInt8]] = [
            [0, 0, 0], [255, 255, 255], [230, 38, 38], [38, 230, 38], [38, 38, 230],
            [230, 230, 38], [38, 230, 230], [230, 38, 230], [128, 128, 128], [64, 64, 64],
            [192, 192, 192], [150, 105, 82],
          ]
          let c = colors[min(11, (y / 160) * 4 + x / 160)]
          bytes[j] = c[0]
          bytes[j + 1] = c[1]
          bytes[j + 2] = c[2]
        }
      }
    }
    let data = Data(bytes)
    let image = CGImage(
      width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
      intent: .relativeColorimetric)!
    let url = root.appendingPathComponent("workflow-\(["a","b","c"][i]).jpg")
    let encodedData = NSMutableData()
    let dest = CGImageDestinationCreateWithData(
      encodedData, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
      dest, image,
      [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: 1]
        as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("encode") }
    let encoded = encodedData as Data
    try encoded.write(to: url, options: .withoutOverwriting)
    manifest.append([
      "path": url.lastPathComponent,
      "sha256": SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(), "width": w,
      "height": h, "bytes": encoded.count,
      "source":
        "CoreGraphics sRGB RGB8; JPEG quality 1.0; orientation 1; lightroom-export-baseline.swift",
    ])
  }
  let out = try JSONSerialization.data(
    withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
  try out.write(to: root.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
  print(String(decoding: out, as: UTF8.self))
}

func compare(left: String, right: String, output: String) throws {
  let leftURL = URL(fileURLWithPath: left)
  let rightURL = URL(fileURLWithPath: right)
  let outputDirectory = URL(fileURLWithPath: output).deletingLastPathComponent()
  guard !FileManager.default.fileExists(atPath: output + ".json"),
    !FileManager.default.fileExists(atPath: output + "-diff-x16.png")
  else {
    throw NSError(
      domain: "LightroomBaseline", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Refusing to overwrite measurement output"])
  }
  let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .outputColorSpace: srgb,
  ])
  func read(_ url: URL) throws -> (CGImage, [Float], [String: Any]) {
    let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let cg = CGImageSourceCreateImageAtIndex(s, 0, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [String: Any]
    var data = [Float](repeating: 0, count: cg.width * cg.height * 4)
    context.render(
      CIImage(cgImage: cg), toBitmap: &data, rowBytes: cg.width * 16,
      bounds: CGRect(x: 0, y: 0, width: cg.width, height: cg.height), format: .RGBAf,
      colorSpace: srgb)
    return (
      cg, data,
      [
        "path": relativePath(url.path, to: outputDirectory), "width": cg.width, "height": cg.height,
        "bitsPerComponent": cg.bitsPerComponent, "bitsPerPixel": cg.bitsPerPixel,
        "profile": props[kCGImagePropertyProfileName as String] ?? NSNull(),
        "orientation": props[kCGImagePropertyOrientation as String] ?? NSNull(),
        "sha256": SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }
          .joined(),
      ]
    )
  }
  let (a, ad, am) = try read(leftURL)
  let (b, bd, bm) = try read(rightURL)
  guard a.width == b.width && a.height == b.height else { fatalError("size mismatch") }
  var errors = [Double]()
  var squares = 0.0
  var sum = 0.0
  var diff = [UInt8](repeating: 255, count: a.width * a.height * 4)
  for i in 0..<a.width * a.height {
    for c in 0..<3 {
      let e = abs(Double(ad[i * 4 + c] - bd[i * 4 + c]))
      errors.append(e)
      sum += e
      squares += e * e
      diff[i * 4 + c] = UInt8(min(255, (e * 16 * 255).rounded()))
    }
  }
  errors.sort()
  let mean = sum / Double(errors.count)
  let mse = squares / Double(errors.count)
  let result: [String: Any] = [
    "left": am, "right": bm,
    "measurement":
      "Core Image embedded ICC -> extended-linear-sRGB working -> encoded sRGB RGBAf, all RGB samples; errors reported in 8-bit code equivalents; diff abs x16",
    "samples": errors.count, "mae_code8": mean * 255, "rmse_code8": sqrt(mse) * 255,
    "max_code8": (errors.last ?? 0) * 255,
    "p99_code8": errors[Int(Double(errors.count - 1) * 0.99)] * 255,
    "psnr_db": mse > 0 ? -10 * log10(mse) as Any : NSNull(),
    "identical_rgb": errors.last == 0,
  ]
  let json = try JSONSerialization.data(
    withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
  try json.write(to: URL(fileURLWithPath: output + ".json"), options: .withoutOverwriting)
  let encodedDiff = NSMutableData()
  let d = CGImageDestinationCreateWithData(encodedDiff, UTType.png.identifier as CFString, 1, nil)!
  let image = CGImage(
    width: a.width, height: a.height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: a.width * 4, space: srgb,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
    provider: CGDataProvider(data: Data(diff) as CFData)!, decode: nil, shouldInterpolate: false,
    intent: .relativeColorimetric)!
  CGImageDestinationAddImage(d, image, nil)
  guard CGImageDestinationFinalize(d) else { fatalError("diff encode") }
  try (encodedDiff as Data).write(
    to: URL(fileURLWithPath: output + "-diff-x16.png"), options: .withoutOverwriting)
  print(String(decoding: json, as: UTF8.self))
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first {
  case "generate" where args.count == 2: try generate(args[1])
  case "compare" where args.count == 4: try compare(left: args[1], right: args[2], output: args[3])
  default:
    fputs(
      "Usage: swift scripts/lightroom-export-baseline.swift generate NEW_DIRECTORY\n       swift scripts/lightroom-export-baseline.swift compare LEFT_IMAGE RIGHT_IMAGE NEW_OUTPUT_PREFIX\n",
      stderr)
    exit(2)
  }

} catch {
  fputs("Baseline: \(error.localizedDescription)\n", stderr)
  exit(1)
}
