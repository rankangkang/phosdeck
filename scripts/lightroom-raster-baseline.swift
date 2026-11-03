// Synthetic, opaque sRGB fixtures and stored-code / ICC-normalized comparators.
// macOS SDK only. No application launch, catalog access or source modification.
// CLI paths are relative to the working directory; JSON paths are relative to that JSON file.
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> NSError {
  NSError(domain: "RasterBaseline", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func sha(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func relativePath(_ path: String, to directory: URL) -> String {
  let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
  let base = directory.standardizedFileURL.pathComponents
  let common = zip(target, base).prefix { $0.0 == $0.1 }.count
  let parts = Array(repeating: "..", count: base.count - common) + target.dropFirst(common)
  return parts.isEmpty ? "." : parts.joined(separator: "/")
}
func resolvedPath(_ path: String, relativeTo directory: URL) -> String {
  URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL.path
}
func json(_ value: Any, to path: String) throws {
  let data = try JSONSerialization.data(
    withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
}
func load(_ path: String) throws -> CGImage {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    CGImageSourceGetCount(source) == 1,
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
    (properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1,
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { throw fail("Expected one orientation-1 image: \(path)") }
  return image
}
func tiffICC(_ data: Data) throws -> Range<Int>? {
  guard data.count >= 8 else { return nil }
  let little = data[0] == 73 && data[1] == 73
  guard little || (data[0] == 77 && data[1] == 77) else { return nil }
  func value(_ p: Int, _ n: Int) throws -> Int {
    guard p >= 0, n <= data.count, p <= data.count - n else { throw fail("Invalid TIFF offset") }
    return (little ? Array(data[p..<p + n].reversed()) : Array(data[p..<p + n])).reduce(0) {
      $0 * 256 + Int($1)
    }
  }
  guard try value(2, 2) == 42 else { throw fail("Only classic TIFF is supported") }
  let ifd = try value(4, 4)
  let count = try value(ifd, 2)
  guard count <= (data.count - min(data.count, ifd + 2)) / 12 else {
    throw fail("Invalid TIFF IFD")
  }
  for i in 0..<count {
    let p = ifd + 2 + i * 12
    if try value(p, 2) == 34675 {
      let length = try value(p + 4, 4)
      let offset = try value(p + 8, 4)
      guard length > 4, offset <= data.count, length <= data.count - offset else {
        throw fail("Invalid TIFF ICC")
      }
      return offset..<offset + length
    }
  }
  return nil
}
func metadata(_ path: String, _ image: CGImage, relativeTo directory: URL) throws -> [String: Any] {
  let file = try Data(contentsOf: URL(fileURLWithPath: path))
  let iccRange = try tiffICC(file)
  let profile = iccRange.map { file.subdata(in: $0) } ?? (image.colorSpace?.copyICCData() as Data?)
  var tags = [String: String]()
  func u32(_ data: Data, _ offset: Int) -> Int {
    data[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }
  }
  if let profile, profile.count >= 132 {
    let count = u32(profile, 128)
    guard count <= (profile.count - 132) / 12 else { throw fail("Invalid ICC tag table") }
    for n in 0..<count {
      let p = 132 + n * 12
      let start = u32(profile, p + 4)
      let size = u32(profile, p + 8)
      guard start <= profile.count, size <= profile.count - start else {
        throw fail("Invalid ICC tag")
      }
      tags[String(decoding: profile[p..<p + 4], as: UTF8.self)] = sha(
        profile.subdata(in: start..<start + size))
    }
  }
  return [
    "path": relativePath(path, to: directory), "sha256": sha(file),
    "icc_source": iccRange != nil ? "TIFF tag 34675" : "ImageIO CGColorSpace copy",
    "width": image.width, "height": image.height, "bits_per_component": image.bitsPerComponent,
    "bits_per_pixel": image.bitsPerPixel, "row_bytes": image.bytesPerRow,
    "bitmap_info": image.bitmapInfo.rawValue, "alpha_info": image.alphaInfo.rawValue,
    "icc_sha256": profile.map(sha) as Any? ?? NSNull(), "icc_bytes": profile?.count ?? 0,
    "icc_rendering_intent": profile.flatMap { $0.count >= 68 ? u32($0, 64) : nil } as Any?
      ?? NSNull(),
    "icc_tag_payload_sha256": tags,
  ]
}
// Read RGB integer storage directly, without CGContext/CIImage or an ICC transform.
// Restrict layouts to the generated fixtures and the two applications' opaque TIFFs.
func codes(_ image: CGImage) throws -> [UInt16] {
  let bits = image.bitsPerComponent
  let channels = image.bitsPerPixel / bits
  guard [8, 16].contains(bits), [3, 4].contains(channels),
    image.colorSpace?.model == .rgb, !image.bitmapInfo.contains(.floatComponents),
    image.decode == nil,
    [.none, .noneSkipLast, .last, .premultipliedLast].contains(image.alphaInfo),
    let raw = image.dataProvider?.data as Data?
  else { throw fail("Unsupported stored RGB layout") }
  let bytes = bits / 8
  guard bits != 8 || image.byteOrderInfo.rawValue == 0 else {
    throw fail("Unsupported 8-bit byte order")
  }
  let little = image.byteOrderInfo.rawValue == CGBitmapInfo.byteOrder16Little.rawValue
  guard bits == 8 || little || image.byteOrderInfo.rawValue == CGBitmapInfo.byteOrder16Big.rawValue,
    raw.count >= image.bytesPerRow * image.height
  else { throw fail("Unsupported byte order or incomplete bitmap") }
  func sample(_ p: Int) -> UInt16 {
    if bits == 8 { return UInt16(raw[p]) * 257 }
    return little
      ? UInt16(raw[p]) | UInt16(raw[p + 1]) << 8 : UInt16(raw[p]) << 8 | UInt16(raw[p + 1])
  }
  var result = [UInt16]()
  result.reserveCapacity(image.width * image.height * 3)
  for y in 0..<image.height {
    for x in 0..<image.width {
      let p = y * image.bytesPerRow + x * channels * bytes
      if [.last, .premultipliedLast].contains(image.alphaInfo), sample(p + 3 * bytes) != 65535 {
        throw fail("Only opaque RGB comparisons are supported")
      }
      for c in 0..<3 { result.append(sample(p + c * bytes)) }
    }
  }
  return result
}
func encode(_ image: CGImage, path: String, type: UTType = .tiff, iccOverride: Data? = nil) throws {
  let data = NSMutableData()
  guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
  else { throw fail("encoder") }
  CGImageDestinationAddImage(
    dest, image,
    [
      kCGImagePropertyOrientation: 1,
      kCGImageDestinationLossyCompressionQuality: 1.0,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1],
    ] as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { throw fail("encode failed") }
  var encoded = data as Data
  if let iccOverride {
    guard type == .tiff, let range = try tiffICC(encoded), range.count == iccOverride.count
    else { throw fail("Cannot isolate embedded TIFF ICC payload") }
    encoded.replaceSubrange(range, with: iccOverride)
  }
  try encoded.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
}
func bitmap(
  _ data: Data, bits: Int, width: Int, height: Int, space: CGColorSpace,
  intent: CGColorRenderingIntent
) throws -> CGImage {
  var info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
  if bits == 16 { info.insert(.byteOrder16Little) }
  guard let provider = CGDataProvider(data: data as CFData),
    let image = CGImage(
      width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
      bytesPerRow: width * 4 * bits / 8, space: space, bitmapInfo: info, provider: provider,
      decode: nil, shouldInterpolate: false, intent: intent)
  else { throw fail("bitmap") }
  return image
}
func generate(_ path: String) throws {
  let dir = URL(fileURLWithPath: path, isDirectory: true)
  guard !FileManager.default.fileExists(atPath: path) else {
    throw fail("Fixture directory must be new")
  }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  let w = 640
  let h = 480
  let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
  var bytes = [UInt8](repeating: 255, count: w * h * 4)
  var wide = [UInt16](repeating: 65535, count: w * h * 4)
  for y in 0..<h {
    for x in 0..<w {
      let p = (y * w + x) * 4
      bytes[p] = UInt8(x * 255 / (w - 1))
      bytes[p + 1] = UInt8(y * 255 / (h - 1))
      bytes[p + 2] = (x / 40 + y / 40) % 2 == 0 ? 48 : 208
      wide[p] = UInt16(x * 65535 / (w - 1))
      wide[p + 1] = UInt16(y * 65535 / (h - 1))
      wide[p + 2] = UInt16((x * 73 + y * 137) % 65536)
      if y < 80 {
        bytes[p + 1] = bytes[p]
        bytes[p + 2] = bytes[p]
        wide[p + 1] = wide[p]
        wide[p + 2] = wide[p]
      }
    }
  }
  let base = try bitmap(
    Data(bytes), bits: 8, width: w, height: h, space: srgb, intent: .relativeColorimetric)
  let deep = try wide.withUnsafeBytes {
    try bitmap(Data($0), bits: 16, width: w, height: h, space: srgb, intent: .relativeColorimetric)
  }
  func file(_ name: String) -> String { dir.appendingPathComponent(name).path }
  var relativeProfile = srgb.copyICCData()! as Data
  relativeProfile.replaceSubrange(64..<68, with: [0, 0, 0, 1])
  try encode(base, path: file("a-rgb8-relative.tif"), iccOverride: relativeProfile)
  try encode(deep, path: file("b-rgb16-relative.tif"), iccOverride: relativeProfile)
  var profile = relativeProfile
  profile.replaceSubrange(64..<68, with: [0, 0, 0, 0])
  // ImageIO canonicalizes the sRGB header on encode. Patch only its embedded
  // intent field afterwards; the self-check verifies pixel and tag identity.
  try encode(base, path: file("c-rgb8-perceptual.tif"), iccOverride: profile)
  try encode(base, path: file("d-color-jpeg.jpg"), type: .jpeg)
  try encode(load(file("d-color-jpeg.jpg")), path: file("e-jpeg-imageio8.tif"))
  let source = CIImage(
    contentsOf: URL(fileURLWithPath: file("d-color-jpeg.jpg")),
    options: [.applyOrientationProperty: true])!
  let options: [CIContextOption: Any] = [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .workingFormat: CIFormat.RGBAh,
  ]
  let context = CIContext(options: options)
  guard
    let ci8 = context.createCGImage(
      source, from: source.extent, format: .RGBA8, colorSpace: srgb, deferred: false)
  else { throw fail("CI decode") }
  try encode(ci8, path: file("f-jpeg-coreimage8.tif"))
  let floatContext = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .workingFormat: CIFormat.RGBAf,
  ])
  var samples = Data(count: w * h * 8)
  try samples.withUnsafeMutableBytes { p in
    let dest = CIRenderDestination(
      bitmapData: p.baseAddress!, width: w, height: h, bytesPerRow: w * 8, format: .RGBA16)
    dest.colorSpace = srgb
    dest.alphaMode = .unpremultiplied
    dest.isFlipped = true
    dest.isDithered = false
    try floatContext.startTask(toRender: source, from: source.extent, to: dest, at: .zero)
      .waitUntilCompleted()
  }
  try encode(
    bitmap(samples, bits: 16, width: w, height: h, space: srgb, intent: .relativeColorimetric),
    path: file("g-jpeg-coreimage16.tif"))
  let names = [
    "a-rgb8-relative.tif", "b-rgb16-relative.tif", "c-rgb8-perceptual.tif", "d-color-jpeg.jpg",
    "e-jpeg-imageio8.tif", "f-jpeg-coreimage8.tif", "g-jpeg-coreimage16.tif",
  ]
  let records = try names.map { try metadata(file($0), load(file($0)), relativeTo: dir) }
  let baseCodes = try codes(base)
  let deepCodes = try codes(deep)
  guard try codes(load(file(names[0]))) == baseCodes,
    try codes(load(file(names[1]))) == deepCodes,
    try codes(load(file(names[2]))) == baseCodes
  else { throw fail("Lossless fixture self-check failed") }
  guard records[0]["icc_rendering_intent"] as? Int == 1,
    records[2]["icc_rendering_intent"] as? Int == 0,
    (records[0]["icc_tag_payload_sha256"] as? [String: String])
      == (records[2]["icc_tag_payload_sha256"] as? [String: String])
  else { throw fail("ICC pair self-check failed") }
  try json(
    [
      "generator":
        "lightroom-raster-baseline.swift; generated opaque sRGB RGB; orientation 1; JPEG quality 1; TIFF uncompressed; no metadata",
      "files": records,
    ], to: file("manifest.json"))
  print("Generated and self-checked \(names.count) fixtures at \(path)")
}
func normalizedDifference(_ a: CGImage, _ b: CGImage) -> [String: Any] {
  let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
  let context = CIContext(options: [
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    .workingFormat: CIFormat.RGBAf, .outputColorSpace: srgb,
  ])
  func read(_ image: CGImage) -> [Float] {
    var pixels = [Float](repeating: 0, count: image.width * image.height * 4)
    context.render(
      CIImage(cgImage: image), toBitmap: &pixels, rowBytes: image.width * 16,
      bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height),
      format: .RGBAf, colorSpace: srgb)
    return pixels
  }
  let ac = read(a)
  let bc = read(b)
  var errors = [Double]()
  var sum = 0.0
  var squares = 0.0
  errors.reserveCapacity(a.width * a.height * 3)
  for i in 0..<a.width * a.height {
    for c in 0..<3 {
      let error = abs(Double(ac[i * 4 + c]) - Double(bc[i * 4 + c]))
      errors.append(error)
      sum += error
      squares += error * error
    }
  }
  errors.sort()
  let mse = squares / Double(errors.count)
  return [
    "measurement":
      "ImageIO CGImage embedded ICC -> extendedLinearSRGB RGBAf working -> encoded sRGB RGBAf; RGB only; no resizing",
    "mae_code8": sum / Double(errors.count) * 255, "rmse_code8": sqrt(mse) * 255,
    "max_code8": (errors.last ?? 0) * 255,
    "p99_code8": errors[Int(ceil(Double(errors.count) * 0.99)) - 1] * 255,
    "psnr_db": mse > 0 ? -10 * log10(mse) as Any : NSNull(),
  ]
}
func compare(_ left: String, _ right: String, _ prefix: String) throws {
  guard !FileManager.default.fileExists(atPath: prefix + ".json"),
    !FileManager.default.fileExists(atPath: prefix + "-diff-x16.png")
  else { throw fail("Refusing to overwrite measurement output") }
  let a = try load(left)
  let b = try load(right)
  guard a.width == b.width, a.height == b.height else { throw fail("Size mismatch") }
  let ac = try codes(a)
  let bc = try codes(b)
  var histogram = [Int](repeating: 0, count: 65536)
  var sum = 0.0
  var squares = 0.0
  var nonzero = 0
  var signed = [Double](repeating: 0, count: 3)
  var diff = [UInt8](repeating: 255, count: a.width * a.height * 4)
  for i in ac.indices {
    let delta = Int(bc[i]) - Int(ac[i])
    let e = abs(delta)
    histogram[e] += 1
    sum += Double(e)
    squares += Double(e * e)
    signed[i % 3] += Double(delta)
    if e != 0 { nonzero += 1 }
    diff[i / 3 * 4 + i % 3] = UInt8(min(255, (Double(e) / 257 * 16).rounded()))
  }
  var cumulative = 0
  var p99 = 0
  for i in histogram.indices {
    cumulative += histogram[i]
    if cumulative >= Int(ceil(Double(ac.count) * 0.99)) {
      p99 = i
      break
    }
  }
  let mse = squares / Double(ac.count)
  let maximum = histogram.lastIndex(where: { $0 > 0 }) ?? 0
  let outputDirectory = URL(fileURLWithPath: prefix).deletingLastPathComponent()
  let result: [String: Any] = [
    "left": try metadata(left, a, relativeTo: outputDirectory),
    "right": try metadata(right, b, relativeTo: outputDirectory),
    "measurement":
      "ImageIO decoded dataProvider integer RGB, no ICC transform; 8-bit expanded x257; opaque orientation-1 inputs only; errors in code16 and code8 equivalents",
    "rgb_samples": ac.count, "nonzero_samples": nonzero, "identical_rgb": nonzero == 0,
    "mae_code16": sum / Double(ac.count), "max_code16": maximum, "p99_code16": p99,
    "mae_code8": sum / Double(ac.count) / 257, "max_code8": Double(maximum) / 257,
    "p99_code8": Double(p99) / 257, "rmse_code8": sqrt(mse) / 257,
    "mean_signed_rgb_code8": signed.map { $0 / Double(a.width * a.height) / 257 },
    "psnr_db": mse > 0 ? 10 * log10(65535.0 * 65535 / mse) as Any : NSNull(),
    "icc_normalized_rgba_float": normalizedDifference(a, b),
  ]
  try json(result, to: prefix + ".json")
  try encode(
    bitmap(
      Data(diff), bits: 8, width: a.width, height: a.height,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric),
    path: prefix + "-diff-x16.png", type: .png)
  print(
    "MAE8=\(sum / Double(ac.count) / 257) max8=\(Double(maximum) / 257) nonzero=\(nonzero)/\(ac.count)"
  )
}
// Controlled exposure investigation for the generated 640 x 480 TIFF16 ramp.
// The first 80 rows are neutral grey. Keep the measurement model separate from
// observations: analytic sRGB gain is a hypothesis, never an Adobe algorithm.
func exposure(_ paths: [String], _ prefix: String) throws {
  guard paths.count == 7,
    !FileManager.default.fileExists(atPath: prefix + ".json"),
    !FileManager.default.fileExists(atPath: prefix + ".csv")
  else { throw fail("Expected seven images and a new exposure output prefix") }
  let names = [
    "source", "lr_zero", "lr_plus1", "lr_minus1", "native_zero", "native_plus1", "native_minus1",
  ]
  let images = try paths.map(load)
  guard images.allSatisfy({ $0.width == 640 && $0.height == 480 && $0.bitsPerComponent == 16 })
  else { throw fail("Exposure analysis requires the 640 x 480 TIFF16 fixtures and exports") }
  let sourceFile = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
  guard let range = try tiffICC(sourceFile),
    let sdkProfile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?
  else { throw fail("Expected the SDK sRGB profile embedded by the fixture generator") }
  var sourceProfile = sourceFile.subdata(in: range)
  guard sourceProfile.count == sdkProfile.count, sourceProfile.count >= 128 else {
    throw fail("Unexpected source ICC profile")
  }
  sourceProfile.replaceSubrange(64..<68, with: sdkProfile[64..<68])
  guard sourceProfile == sdkProfile else {
    throw fail("Source is not the generated SDK sRGB profile")
  }
  let values = try images.map(codes)
  let source = values[0]
  for y in 0..<80 {
    for x in 0..<640 {
      let p = (y * 640 + x) * 3
      guard source[p] == source[x * 3], source[p] == source[p + 1], source[p] == source[p + 2]
      else { throw fail("Expected the generated repeated neutral ramp in the first 80 rows") }
    }
  }
  guard source[0] == 0, source[639 * 3] == 65535,
    (1..<640).allSatisfy({ source[$0 * 3] > source[($0 - 1) * 3] })
  else { throw fail("Expected a monotonic full-range grey ramp") }
  let outputDirectory = URL(fileURLWithPath: prefix).deletingLastPathComponent()
  let details = try zip(paths, images).map { try metadata($0.0, $0.1, relativeTo: outputDirectory) }
  let tags = details[0]["icc_tag_payload_sha256"] as? [String: String]
  guard tags?.isEmpty == false,
    details.allSatisfy({ $0["icc_tag_payload_sha256"] as? [String: String] == tags })
  else { throw fail("ICC tag contents differ; the analytic sRGB model needs separate validation") }
  func linear(_ encoded: Double) -> Double {
    encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
  }
  func encoded(_ linear: Double) -> Double {
    let v = min(1, max(0, linear))
    return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
  }
  func gain(_ input: UInt16, _ ev: Double) -> Double {
    encoded(linear(Double(input) / 65535) * pow(2, ev)) * 65535
  }
  func errors(_ a: [Double], _ b: [Double], _ range: Range<Int>) -> [String: Any] {
    var e = range.map { abs(a[$0] - b[$0]) }
    e.sort()
    return [
      "samples": e.count, "mae_code8": e.reduce(0, +) / Double(e.count) / 257,
      "max_code8": (e.last ?? 0) / 257, "p99_code8": e[Int(ceil(Double(e.count) * 0.99)) - 1] / 257,
    ]
  }
  let regions = [
    "whole": 0..<source.count, "grey": 0..<(640 * 80 * 3), "colour": (640 * 80 * 3)..<source.count,
  ]
  var comparisons = [String: Any]()
  for (label, left, right) in [("zero", 1, 4), ("plus1", 2, 5), ("minus1", 3, 6)] {
    let a = values[left].map(Double.init)
    let b = values[right].map(Double.init)
    comparisons[label] = regions.mapValues { errors(a, b, $0) }
  }
  var model = [String: Any]()
  for (name, index, ev) in [
    ("lr_plus1", 2, 1.0), ("lr_minus1", 3, -1.0),
    ("native_plus1", 5, 1.0), ("native_minus1", 6, -1.0),
  ] {
    let expected = source.map { gain($0, ev) }
    let actual = values[index].map(Double.init)
    model[name] = regions.mapValues { errors(expected, actual, $0) }
  }
  var fits = [String: Any]()
  for (name, index) in [("lr_plus1", 2), ("lr_minus1", 3)] {
    // Exhaustive scalar search, explicitly bounded and sampled. No fitted curve
    // is installed in the application or claimed to reproduce Lightroom.
    var bestEV = 0.0
    var best = Double.infinity
    for step in -5000...5000 {
      let ev = Double(step) / 1000
      let error = (0..<640).reduce(0.0) {
        $0 + abs(gain(source[$1 * 3], ev) - Double(values[index][$1 * 3]))
      }
      if error < best {
        best = error
        bestEV = ev
      }
    }
    fits[name] = [
      "ev": bestEV, "grey_red_mae_code8": best / 640 / 257,
      "search": "[-5,5] EV in 0.001 EV steps; unweighted red channel, row 0; analytic sRGB model",
    ]
  }
  var ramps = [String: Any]()
  for (name, pixels) in zip(names, values) {
    var spread = 0
    var rowVariation = 0
    for x in 0..<640 {
      for y in 0..<80 {
        let p = (y * 640 + x) * 3
        spread = max(
          spread,
          Int(max(pixels[p], pixels[p + 1], pixels[p + 2]))
            - Int(min(pixels[p], pixels[p + 1], pixels[p + 2])))
        for c in 0..<3 {
          rowVariation = max(rowVariation, abs(Int(pixels[p + c]) - Int(pixels[x * 3 + c])))
        }
      }
    }
    ramps[name] = [
      "row0_red_code16": (0..<640).map { Int(pixels[$0 * 3]) },
      "grey_max_rgb_spread_code16": spread, "grey_max_row_variation_code16": rowVariation,
      "row0_red_decreasing_steps": (1..<640).filter { pixels[$0 * 3] < pixels[($0 - 1) * 3] }.count,
      "grey_columns_clipped_below_source_white": (0..<639).filter { pixels[$0 * 3] == 65535 }.count,
    ]
  }
  let selected = [0, 20, 40, 80, 160, 240, 320, 400, 480, 560, 600, 639].map { x -> [String: Any] in
    var row: [String: Any] = ["x": x]
    for (name, pixels) in zip(names, values) {
      row[name] = (0..<3).map { Double(pixels[x * 3 + $0]) / 257 }
    }
    return row
  }
  try json(
    [
      "scenario": "LR-EXPOSURE-001", "files": Dictionary(uniqueKeysWithValues: zip(names, details)),
      "measurement":
        "Decoded integer RGB, no colour conversion; code8 equivalents = code16 / 257. Grey ROI: first 80 rows. Row variation and neutrality are observed, not assumed.",
      "cross_application": comparisons, "grey_response": ramps, "selected_row0_rgb_code8": selected,
      "analytic_model":
        "IEC sRGB EOTF -> multiply by 2^EV -> clamp to [0,1] -> sRGB OETF; evaluated on stored source codes, not an Adobe algorithm or an exact ICC TRC interpolation",
      "analytic_model_residuals": model, "best_single_gain_fit": fits,
      "limitations": [
        "One synthetic opaque sRGB TIFF16; no RAW or camera coverage",
        "Scalar fit minimizes mean absolute code error only; it is not a perceptual acceptance threshold",
        "Supplied exports are observations, not proof of Adobe internals or a product acceptance threshold",
      ],
    ], to: prefix + ".json")
  var csv = "x," + names.map { $0 + "_red_code16" }.joined(separator: ",") + "\n"
  for x in 0..<640 {
    csv += ([String(x)] + values.map { String($0[x * 3]) }).joined(separator: ",") + "\n"
  }
  try Data(csv.utf8).write(to: URL(fileURLWithPath: prefix + ".csv"), options: .withoutOverwriting)
  print("Exposure observations and analytic-model residuals: \(prefix).json / .csv")
}
// Independent hold-out chart: 256 neutral patches plus an 8^3 RGB cube.
func generatePatches(_ path: String) throws {
  let dir = URL(fileURLWithPath: path, isDirectory: true)
  guard !FileManager.default.fileExists(atPath: path) else {
    throw fail("Fixture directory must be new")
  }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  let w = 640
  let h = 480
  var pixels = [UInt16](repeating: 65535, count: w * h * 4)
  for y in 0..<h {
    for x in 0..<w {
      let i = (y / 20) * 32 + x / 20
      let p = (y * w + x) * 4
      if i < 256 {
        let q = UInt16(i * 257)
        pixels[p] = q
        pixels[p + 1] = q
        pixels[p + 2] = q
      } else {
        let j = i - 256
        pixels[p] = UInt16((j % 8) * 65535 / 7)
        pixels[p + 1] = UInt16(((j / 8) % 8) * 65535 / 7)
        pixels[p + 2] = UInt16((j / 64) * 65535 / 7)
      }
    }
  }
  let data = pixels.withUnsafeBytes { Data($0) }
  let image = try bitmap(
    data, bits: 16, width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    intent: .relativeColorimetric)
  try encode(image, path: dir.appendingPathComponent("c-rgb16-patches.tif").path)
  print("Generated 256 gray and 512 colour patches at \(path)")
}
// Fixed linear-sRGB luminance, with saturation measured from gray to the
// sRGB gamut boundary in a declared RGB hue direction. The second chart uses
// disjoint hues/luminances/saturations; it is reserved for validation.
func generateColourSweeps(_ path: String) throws {
  let dir = URL(fileURLWithPath: path, isDirectory: true)
  guard !FileManager.default.fileExists(atPath: path) else {
    throw fail("Fixture directory must be new")
  }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  func encoded(_ x: Double) -> Double {
    x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
  }
  func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
  let specs: [(String, [Double], [Double], [Double])] = [
    (
      "a-luminance-sweep.tif", (0..<12).map { Double($0) * 30 }, [0.01, 0.05, 0.18, 0.4, 0.7],
      [0.1, 0.3, 0.5, 0.7, 0.9, 1]
    ),
    (
      "b-luminance-holdout.tif", (0..<24).map { 7.5 + Double($0) * 15 }, [0.02, 0.09, 0.27, 0.52],
      [0.15, 0.45, 0.8, 0.95]
    ),
  ]
  var charts = [[String: Any]]()
  for (name, hues, luminances, saturations) in specs {
    var patches = [[String: Any]]()
    for i in 0...64 {
      let q = Int((Double(i) / 64 * 65535).rounded(.toNearestOrEven))
      patches.append(["kind": "gray", "rgb16": [q, q, q], "gray_encoded": Double(i) / 64])
    }
    for hue in hues {
      for y in luminances {
        for saturation in saturations {
          let h = hue / 60
          let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
          let bases = [[1.0, x, 0], [x, 1, 0], [0, 1, x], [0, x, 1], [x, 0, 1], [1, 0, x]]
          let base = bases[Int(h)].map(linear)
          let l = base[0] * 0.2126 + base[1] * 0.7152 + base[2] * 0.0722
          let direction = base.map { $0 - l }
          let edge = direction.map { $0 > 0 ? (1 - y) / $0 : ($0 < 0 ? y / -$0 : Double.infinity) }
            .min()!
          let rgb = direction.map { min(1, max(0, y + saturation * edge * $0)) }
          let values = rgb.map { Int((encoded($0) * 65535).rounded(.toNearestOrEven)) }
          let quantized = values.map { linear(Double($0) / 65535) }
          let measuredY = quantized[0] * 0.2126 + quantized[1] * 0.7152 + quantized[2] * 0.0722
          guard abs(measuredY - y) < 0.000025 else {
            throw fail("Luminance fixture quantization exceeded its declared bound")
          }
          patches.append([
            "kind": "color", "hue_direction_degrees": hue, "linear_srgb_luminance": y,
            "saturation_to_gamut_edge": saturation, "rgb16": values,
            "quantized_linear_luminance": measuredY,
          ])
        }
      }
    }
    let columns = 32
    let side = 20
    let w = columns * side
    let h = ((patches.count + columns - 1) / columns) * side
    var pixels = [UInt16](repeating: 65535, count: w * h * 4)
    for i in patches.indices {
      let values = patches[i]["rgb16"] as! [Int]
      let px = (i % columns) * side
      let py = (i / columns) * side
      patches[i]["index"] = i
      patches[i]["roi"] = [px + 4, py + 4, 12, 12]
      for y in py..<py + side {
        for x in px..<px + side {
          for c in 0..<3 { pixels[(y * w + x) * 4 + c] = UInt16(values[c]) }
        }
      }
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    let image = try bitmap(
      data, bits: 16, width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      intent: .relativeColorimetric)
    let target = dir.appendingPathComponent(name).path
    try encode(image, path: target)
    let readback = try codes(load(target))
    for patch in patches {
      let roi = patch["roi"] as! [Int]
      let values = patch["rgb16"] as! [Int]
      for c in 0..<3 where Int(readback[(roi[1] * w + roi[0]) * 3 + c]) != values[c] {
        throw fail("Fixture RGB16 readback mismatch")
      }
    }
    charts.append([
      "name": name, "metadata": try metadata(target, load(target), relativeTo: dir), "patches": patches,
    ])
  }
  try json(
    [
      "generator": "fixed-linear-srgb-luminance-v1", "patch_side": 20,
      "color_condition":
        "opaque sRGB16; RGB hue direction from encoded HSV unit vector, then linearized; luminance is linear-sRGB Y, saturation is distance to sRGB boundary, not HSV S or perceptual chroma",
      "charts": charts,
    ], to: dir.appendingPathComponent("colour-manifest.json").path)
  print("Generated and readback-verified two independent luminance/color sweeps at \(path)")
}
// Dense encoded-sRGB rays isolate brightness thresholds without changing hue.
// Near-primary rays include the largest residuals from the separate 8^3 cube.
func generatePrimaryRamps(_ path: String) throws {
  let dir = URL(fileURLWithPath: path, isDirectory: true)
  guard !FileManager.default.fileExists(atPath: path) else {
    throw fail("Fixture directory must be new")
  }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  let rays: [[Double]] = [
    [1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 1, 1], [1, 0, 1], [1, 1, 0],
    [1, 2.0 / 7, 0], [2.0 / 7, 2.0 / 7, 1], [5.0 / 7, 3.0 / 7, 1], [1, 0, 6.0 / 7],
  ]
  var patches = [[String: Any]]()
  for i in 0...64 {
    let q = Int((Double(i) / 64 * 65535).rounded(.toNearestOrEven))
    patches.append(["kind": "gray", "rgb16": [q, q, q], "gray_encoded": Double(i) / 64])
  }
  for (ray, direction) in rays.enumerated() {
    for i in 0...64 {
      let level = Double(i) / 64
      patches.append([
        "kind": "color", "ray": ray, "encoded_rgb_direction": direction,
        "encoded_level": level,
        "rgb16": direction.map { Int(($0 * level * 65535).rounded(.toNearestOrEven)) },
      ])
    }
  }
  let columns = 32
  let side = 20
  let w = columns * side
  let h = ((patches.count + columns - 1) / columns) * side
  var pixels = [UInt16](repeating: 65535, count: w * h * 4)
  for i in patches.indices {
    let values = patches[i]["rgb16"] as! [Int]
    let px = (i % columns) * side
    let py = (i / columns) * side
    patches[i]["index"] = i
    patches[i]["roi"] = [px + 4, py + 4, 12, 12]
    for y in py..<py + side {
      for x in px..<px + side {
        for c in 0..<3 {
          pixels[(y * w + x) * 4 + c] = UInt16(values[c])
        }
      }
    }
  }
  let image = try bitmap(
    pixels.withUnsafeBytes { Data($0) }, bits: 16, width: w, height: h,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric)
  let name = "e-primary-ramps.tif"
  let target = dir.appendingPathComponent(name).path
  try encode(image, path: target)
  let readback = try codes(load(target))
  for patch in patches {
    let roi = patch["roi"] as! [Int]
    let values = patch["rgb16"] as! [Int]
    for c in 0..<3 where Int(readback[(roi[1] * w + roi[0]) * 3 + c]) != values[c] {
      throw fail("Fixture RGB16 readback mismatch")
    }
  }
  try json(
    [
      "generator": "encoded-srgb-primary-ramps-v1", "patch_side": side,
      "color_condition":
        "opaque sRGB16; each ray is an encoded-RGB direction times 65 levels, not a fixed-luminance or RAW comparison",
      "charts": [
        ["name": name, "metadata": try metadata(target, load(target), relativeTo: dir), "patches": patches]
      ],
    ],
    to: dir.appendingPathComponent("colour-manifest.json").path)
  print("Generated and readback-verified \(patches.count) gray/primary ramp patches at \(path)")
}
// Same working-space extrema with varied middle components separate endpoint
// response from hue interpolation. Only in-gamut linear-sRGB inputs are kept.
func generateMiddleSweeps(_ path: String) throws {
  let dir = URL(fileURLWithPath: path, isDirectory: true)
  guard !FileManager.default.fileExists(atPath: path) else {
    throw fail("Fixture directory must be new")
  }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  let inverse = [
    [2.0343104306914266, -0.7276094363341301, -0.30670099435729664],
    [-0.22880499207676658, 1.2317141502386277, -0.00290915816186133],
    [-0.008539365225714066, -0.1532636513148021, 1.1618030165405162],
  ]
  let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
  func encoded(_ x: Double) -> Double {
    x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
  }
  var patches = [[String: Any]]()
  for i in 0...64 {
    let q = Int((Double(i) / 64 * 65535).rounded(.toNearestOrEven))
    patches.append(["kind": "gray", "rgb16": [q, q, q], "gray_encoded": Double(i) / 64])
  }
  for low in [0.002, 0.01, 0.05, 0.18, 0.4, 0.7] {
    for high in [0.1, 0.35, 0.7, 0.95] where high > low {
      for (order, channels) in permutations.enumerated() {
        for step in 0...8 {
          let ratio = Double(step) / 8
          var wide = [Double](repeating: low, count: 3)
          wide[channels[1]] = low + (high - low) * ratio
          wide[channels[2]] = high
          let rgb = inverse.map { row in zip(row, wide).reduce(0.0) { $0 + $1.0 * $1.1 } }
          guard rgb.allSatisfy({ $0 >= 0 && $0 <= 1 }) else { continue }
          patches.append([
            "kind": "color", "working_basis": "linear-ROMM-v1", "working_low": low,
            "working_high": high, "middle_ratio": ratio, "permutation": order, "working_rgb": wide,
            "rgb16": rgb.map { Int((encoded($0) * 65535).rounded(.toNearestOrEven)) },
          ])
        }
      }
    }
  }
  let columns = 32
  let side = 20
  let w = columns * side
  let h = ((patches.count + columns - 1) / columns) * side
  var pixels = [UInt16](repeating: 65535, count: w * h * 4)
  for i in patches.indices {
    let values = patches[i]["rgb16"] as! [Int]
    let px = (i % columns) * side
    let py = (i / columns) * side
    patches[i]["index"] = i
    patches[i]["roi"] = [px + 4, py + 4, 12, 12]
    for y in py..<py + side {
      for x in px..<px + side {
        for c in 0..<3 {
          pixels[(y * w + x) * 4 + c] = UInt16(values[c])
        }
      }
    }
  }
  let image = try bitmap(
    pixels.withUnsafeBytes { Data($0) }, bits: 16, width: w, height: h,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric)
  let name = "f-romm-middle.tif"
  let target = dir.appendingPathComponent(name).path
  try encode(image, path: target)
  let readback = try codes(load(target))
  for patch in patches {
    let roi = patch["roi"] as! [Int]
    let values = patch["rgb16"] as! [Int]
    for c in 0..<3 where Int(readback[(roi[1] * w + roi[0]) * 3 + c]) != values[c] {
      throw fail("Fixture RGB16 readback mismatch")
    }
  }
  try json(
    [
      "generator": "linear-romm-fixed-extrema-v1", "patch_side": side,
      "color_condition":
        "opaque sRGB16; declared linear-ROMM extrema fixed before RGB16 quantization, 9 middle-component ratios and 6 channel permutations, out-of-sRGB colors excluded; not evidence of Adobe's internal working space",
      "working_to_linear_srgb": inverse,
      "charts": [
        ["name": name, "metadata": try metadata(target, load(target), relativeTo: dir), "patches": patches]
      ],
    ],
    to: dir.appendingPathComponent("colour-manifest.json").path)
  print("Generated and readback-verified \(patches.count) fixed-extrema patches at \(path)")
}
func colourPatches(
  _ manifestPath: String, _ name: String, _ left: String, _ right: String, _ prefix: String
) throws {
  let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
  let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
  guard let charts = manifest?["charts"] as? [[String: Any]],
    let chart = charts.first(where: { $0["name"] as? String == name }),
    let sourceMeta = chart["metadata"] as? [String: Any],
    let source = sourceMeta["path"] as? String,
    let patches = chart["patches"] as? [[String: Any]]
  else { throw fail("Expected an unchanged generated color chart") }
  let sourcePath = resolvedPath(source, relativeTo: manifestURL.deletingLastPathComponent())
  guard try sha(Data(contentsOf: URL(fileURLWithPath: sourcePath))) == sourceMeta["sha256"] as? String
  else { throw fail("Expected an unchanged generated color chart") }
  let a = try load(left)
  let b = try load(right)
  guard a.width == b.width, a.height == b.height, a.width == sourceMeta["width"] as? Int,
    a.height == sourceMeta["height"] as? Int
  else { throw fail("Patch comparison dimensions differ") }
  let ac = try codes(a)
  let bc = try codes(b)
  var rows = [[String: Any]]()
  for patch in patches {
    guard let roi = patch["roi"] as? [Int], roi.count == 4, roi[0] >= 0, roi[1] >= 0, roi[2] > 0,
      roi[3] > 0,
      roi[0] <= a.width - roi[2], roi[1] <= a.height - roi[3]
    else { throw fail("Invalid patch ROI") }
    var sumsA = [Double](repeating: 0, count: 3)
    var sumsB = sumsA
    var error = 0.0
    var peak = 0
    for y in roi[1]..<roi[1] + roi[3] {
      for x in roi[0]..<roi[0] + roi[2] {
        for c in 0..<3 {
          let i = (y * a.width + x) * 3 + c
          let delta = abs(Int(ac[i]) - Int(bc[i]))
          sumsA[c] += Double(ac[i])
          sumsB[c] += Double(bc[i])
          error += Double(delta)
          peak = max(peak, delta)
        }
      }
    }
    let count = Double(roi[2] * roi[3])
    var row = patch
    row["left_mean_rgb16"] = sumsA.map { $0 / count }
    row["right_mean_rgb16"] = sumsB.map { $0 / count }
    row["mae_code8"] = error / (count * 3 * 257)
    row["max_code8"] = Double(peak) / 257
    rows.append(row)
  }
  let outputDirectory = URL(fileURLWithPath: prefix).deletingLastPathComponent()
  var reportSource = sourceMeta
  reportSource["path"] = relativePath(sourcePath, to: outputDirectory)
  try json(
    [
      "manifest_sha256": sha(Data(contentsOf: URL(fileURLWithPath: manifestPath))),
      "source": reportSource,
      "left": try metadata(left, a, relativeTo: outputDirectory),
      "right": try metadata(right, b, relativeTo: outputDirectory),
      "measurement":
        "ROI stored RGB16, no ICC transform, code16/257 errors; gray and color kept separate",
      "patches": rows,
    ], to: prefix + ".json")
  print("Measured \(rows.count) color/gray ROIs: \(prefix).json")
}
// An authorized CC0 source derivative tests ordinary-image response only. Its
// SDK RAW rendering is frozen into one TIFF; this never compares RAW pipelines.
func publicDerivative(_ sourcePath: String, _ path: String) throws {
  let url = URL(fileURLWithPath: sourcePath)
  let before = try Data(contentsOf: url)
  guard sha(before) == "0831d8103a2f2275e479095a75a1217b49e1d415ced439f43c331eb3927f2675",
    let raw = CIRAWFilter(imageURL: url)
  else { throw fail("Expected authorized CC0 Nikon source") }
  let dir = URL(fileURLWithPath: path, isDirectory: true)
  guard !FileManager.default.fileExists(atPath: path) else {
    throw fail("Derivative directory must be new")
  }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  raw.isDraftModeEnabled = false
  raw.extendedDynamicRangeAmount = 0
  guard let original = raw.outputImage else { throw fail("Public derivative decode failed") }
  let scale = 960 / original.extent.width
  let small = original.clampedToExtent().applyingFilter(
    "CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
  let extent = CGRect(x: 0, y: 0, width: 960, height: floor(original.extent.height * scale))
  let ctx = CIContext(options: [
    .workingFormat: CIFormat.RGBAf,
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
  ])
  guard
    let image = ctx.createCGImage(
      small, from: extent, format: .RGBA16, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  else { throw fail("Public derivative render failed") }
  let target = dir.appendingPathComponent("d-cc0-nikon-raster.tif").path
  try encode(image, path: target)
  guard try sha(Data(contentsOf: url)) == sha(before) else { throw fail("Public source changed") }
  try json(
    [
      "source": relativePath(sourcePath, to: dir), "source_sha256": sha(before), "decoder": raw.decoderVersion.rawValue,
      "kind": "ordinary TIFF derivative, not a RAW comparison",
      "output": try metadata(target, image, relativeTo: dir),
    ], to: dir.appendingPathComponent("generation.json").path)
}
// Manifest: {"source":PATH,"exports":[{"ev":-5,"path":PATH}, ... +5]}.
// This reads supplied exports only, never an application's catalog or UI.
func calibrate(_ manifestPath: String, _ output: String) throws {
  let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
  let outputDirectory = URL(fileURLWithPath: output).deletingLastPathComponent()
  guard !FileManager.default.fileExists(atPath: output),
    let manifest = try JSONSerialization.jsonObject(
      with: Data(contentsOf: manifestURL)) as? [String: Any],
    let sourceReference = manifest["source"] as? String,
    let exports = manifest["exports"] as? [[String: Any]], exports.count == 21
  else { throw fail("Expected a new output and 21-export manifest") }
  let sourcePath = resolvedPath(sourceReference, relativeTo: manifestURL.deletingLastPathComponent())
  let source = try load(sourcePath)
  let original = try codes(source)
  let sourceMeta = try metadata(sourcePath, source, relativeTo: outputDirectory)
  guard source.width == 640, source.height == 480, source.bitsPerComponent == 16 else {
    throw fail("Expected opaque TIFF16 patch chart")
  }
  for i in 0..<256 {
    let offset = ((i / 32 * 20 + 10) * 640 + i % 32 * 20 + 10) * 3
    guard Array(original[offset..<offset + 3]) == Array(repeating: UInt16(i * 257), count: 3) else {
      throw fail("Expected all 256 neutral input patches")
    }
  }
  var rows = [[Int]]()
  var records = [[String: Any]]()
  for (row, item) in exports.enumerated() {
    let ev = Double(row) / 2 - 5
    guard (item["ev"] as? NSNumber)?.doubleValue == ev, let reference = item["path"] as? String else {
      throw fail("EV rows must be -5...5 at half-stop intervals")
    }
    let path = resolvedPath(reference, relativeTo: manifestURL.deletingLastPathComponent())
    let image = try load(path)
    let values = try codes(image)
    let info = try metadata(path, image, relativeTo: outputDirectory)
    guard image.width == 640, image.height == 480, image.bitsPerComponent == 16,
      NSDictionary(dictionary: info["icc_tag_payload_sha256"] as! [String: String]).isEqual(
        to: sourceMeta["icc_tag_payload_sha256"] as! [String: String])
    else { throw fail("Patch dimensions, depth or ICC payload differ") }
    let gray = (0..<256).map { i -> Double in
      let offset = ((i / 32 * 20 + 10) * 640 + i % 32 * 20 + 10) * 3
      return values[offset..<offset + 3].reduce(0.0) { $0 + Double($1) } / 3
    }
    guard zip(gray, gray.dropFirst()).allSatisfy({ $0 <= $1 }) else {
      throw fail("Observed gray response is not monotone")
    }
    let samples = (0..<65).map { i -> Int in
      if row == 10 { return Int((Double(i) * 65535 / 64).rounded(.toNearestOrEven)) }
      let x = Double(i) * 255 / 64
      let a = min(254, Int(x))
      let t = x - Double(a)
      return Int((gray[a] * (1 - t) + gray[a + 1] * t).rounded(.toNearestOrEven))
    }
    rows.append(samples)
    records.append(["ev": ev, "file": info, "gray_code16_mean": gray])
  }
  guard zip(rows, rows.dropFirst()).allSatisfy({ a, b in zip(a, b).allSatisfy({ $0 <= $1 }) })
  else { throw fail("Response is not monotone over EV") }
  try json(
    [
      "source": sourceMeta,
      "grid": "65 uniform encoded sRGB knots, RGB-mean neutral samples only; zero forced identity",
      "ev_grid": "-5...5, step 0.5; convex interpolation", "table_code16": rows, "exports": records,
    ], to: output)
  print("Rebuilt 21 x 65 raster response anchors at \(output)")
}
do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first {
  case "generate" where args.count == 2: try generate(args[1])
  case "generate-patches" where args.count == 2: try generatePatches(args[1])
  case "generate-colour-sweeps" where args.count == 2: try generateColourSweeps(args[1])
  case "generate-primary-ramps" where args.count == 2: try generatePrimaryRamps(args[1])
  case "generate-middle-sweeps" where args.count == 2: try generateMiddleSweeps(args[1])
  case "colour-patches" where args.count == 6:
    try colourPatches(args[1], args[2], args[3], args[4], args[5])
  case "public-derivative" where args.count == 3: try publicDerivative(args[1], args[2])
  case "calibrate" where args.count == 3: try calibrate(args[1], args[2])
  case "compare" where args.count == 4: try compare(args[1], args[2], args[3])
  case "exposure" where args.count == 9: try exposure(Array(args[1...7]), args[8])
  default:
    throw fail(
      "Usage: swift scripts/lightroom-raster-baseline.swift generate NEW_DIRECTORY | generate-patches NEW_DIRECTORY | generate-colour-sweeps NEW_DIRECTORY | generate-primary-ramps NEW_DIRECTORY | generate-middle-sweeps NEW_DIRECTORY | colour-patches MANIFEST CHART_NAME LEFT RIGHT NEW_PREFIX | public-derivative AUTHORIZED_NIKON_SOURCE NEW_DIRECTORY | calibrate MANIFEST NEW_JSON | compare LEFT RIGHT NEW_PREFIX | exposure SOURCE LR_ZERO LR_PLUS1 LR_MINUS1 NATIVE_ZERO NATIVE_PLUS1 NATIVE_MINUS1 NEW_PREFIX"
    )
  }
} catch {
  fputs("Raster baseline: \(error.localizedDescription)\n", stderr)
  exit(1)
}
