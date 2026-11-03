// Stage A research runner. Model files and photographs stay in ignored build/.
import Foundation
import CoreML
import CoreGraphics
import CoreVideo
import ImageIO
import Darwin
import LiteRT

enum ProbeError: Error { case invalid(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeError.invalid(message) }
}
let clock = { ProcessInfo.processInfo.systemUptime }

struct Sample: Decodable {
    let id: String
    let group: String
    let category: String
    let file: String
    let box: [Double] // Normalized top-left xyxy, including model outputs.
    let faces: [Face]
    let positive: [Double]?
    let negative: [Double]?
    struct Face: Decodable { let box: [Double] }
}

func image(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let value = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
          ] as CFDictionary) else { throw ProbeError.invalid("Cannot decode \(url.lastPathComponent)") }
    return value
}

func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    try require(ok, "Cannot create sRGB input")
    return bytes
}

func pixelBuffer(_ image: CGImage, side: Int) throws -> CVPixelBuffer {
    let bytes = try rgba(image, width: side, height: side)
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    try require(status == kCVReturnSuccess && buffer != nil, "Cannot allocate pixel buffer")
    let value = buffer!
    CVPixelBufferLockBaseAddress(value, []); defer { CVPixelBufferUnlockBaseAddress(value, []) }
    let target = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(value)
    for y in 0..<side { for x in 0..<side {
        let src = (y * side + x) * 4, dst = y * stride + x * 4
        target[dst] = bytes[src + 2]; target[dst + 1] = bytes[src + 1]
        target[dst + 2] = bytes[src]; target[dst + 3] = bytes[src + 3]
    } }
    return value
}

func crop(_ image: CGImage, box: [Double], square: Bool, margin: Double) throws -> (CGImage, [Double]) {
    try require(box.count == 4 && box.allSatisfy(\.isFinite), "Invalid ROI")
    let w = Double(image.width), h = Double(image.height)
    let cx = (box[0] + box[2]) * w / 2, cy = (box[1] + box[3]) * h / 2
    var rw = (box[2] - box[0]) * w * margin, rh = (box[3] - box[1]) * h * margin
    if square { rw = max(rw, rh); rh = rw }
    let rect = CGRect(x: cx - rw / 2, y: cy - rh / 2, width: rw, height: rh)
        .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
    guard !rect.isEmpty, let result = image.cropping(to: rect) else { throw ProbeError.invalid("Empty ROI") }
    return (result, [rect.minX / w, rect.minY / h, rect.maxX / w, rect.maxY / h])
}

func load(_ root: URL, _ name: String, cpu: Bool) throws -> (MLModel, Double) {
    let cfg = MLModelConfiguration(); cfg.computeUnits = cpu ? .cpuOnly : .all
    let start = clock()
    let model = try MLModel(contentsOf: root.appendingPathComponent(name + ".mlmodelc"), configuration: cfg)
    return (model, clock() - start)
}
func predict(_ model: MLModel, _ values: [String: MLFeatureValue]) throws -> MLFeatureProvider {
    try model.prediction(from: MLDictionaryFeatureProvider(dictionary: values))
}
func array(_ provider: MLFeatureProvider, _ key: String) throws -> MLMultiArray {
    guard let result = provider.featureValue(for: key)?.multiArrayValue else {
        throw ProbeError.invalid("Missing tensor \(key)")
    }
    return result
}
func floats(_ array: MLMultiArray) -> [Float] {
    // ShapedArray preserves logical order even when Core ML returns noncontiguous strides.
    MLShapedArray<Float>(converting: array).scalars
}
func saveFloats(_ values: [Float], _ path: URL) throws {
    try require(values.allSatisfy(\.isFinite), "Non-finite model output")
    try values.withUnsafeBytes { try Data($0).write(to: path, options: .atomic) }
}
func saveJSON(_ value: Any, _ path: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: path, options: .atomic)
}
func memory() -> Int64 {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss) // macOS reports bytes; process high-water mark, not GPU allocation.
}

func sam(root: URL, samples: [Sample], sampleRoot: URL, out: URL, cpu: Bool) throws -> [String: Any] {
    let (encoder, encLoad) = try load(root, "SAM2_1TinyImageEncoderFLOAT16", cpu: cpu)
    let (prompt, promptLoad) = try load(root, "SAM2_1TinyPromptEncoderFLOAT16", cpu: cpu)
    let (decoder, decLoad) = try load(root, "SAM2_1TinyMaskDecoderFLOAT16", cpu: cpu)
    var results = [[String: Any]]()
    for sample in samples {
        try autoreleasepool {
            let original = try image(sampleRoot.appendingPathComponent(sample.file))
            let prepStart = clock(), pixels = try pixelBuffer(original, side: 1024)
            let prepSeconds = clock() - prepStart, encStart = clock()
            let encoded = try predict(encoder, ["image": MLFeatureValue(pixelBuffer: pixels)])
            let encodeSeconds = clock() - encStart
            let b = sample.box, cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2
            let negative = (b[0] > 0.05 ? b[0] / 2 : min(0.999, b[2] + (1 - b[2]) / 2), cy)
            let positive = sample.positive ?? [cx, cy]
            let excluded = sample.negative ?? [negative.0, negative.1]
            try require(positive.count == 2 && excluded.count == 2 && (positive + excluded).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "Invalid correction points")
            // First two prompts are annotation-derived; explicit correction points are frozen in the fixture.
            let variants: [(String, [[Double]])] = [
                ("point", [[cx, cy, 1]]),
                ("box", [[b[0], b[1], 2], [b[2], b[3], 3]]),
                ("refined", [[b[0], b[1], 2], [b[2], b[3], 3], [positive[0], positive[1], 1], [excluded[0], excluded[1], 0]])
            ]
            var outputs = [[String: Any]]()
            for (name, points) in variants {
                let coords = try MLMultiArray(shape: [1, NSNumber(value: points.count), 2], dataType: .float32)
                let labels = try MLMultiArray(shape: [1, NSNumber(value: points.count)], dataType: .int32)
                for (i, p) in points.enumerated() {
                    coords[[0, NSNumber(value: i), 0]] = NSNumber(value: p[0] * 1024)
                    coords[[0, NSNumber(value: i), 1]] = NSNumber(value: p[1] * 1024)
                    labels[i] = NSNumber(value: Int(p[2]))
                }
                var durations = [Double](), chosen = [Float](), scores = [Float]()
                var allMasks = [Float]()
                for _ in 0..<3 {
                    let begin = clock()
                    let p = try predict(prompt, ["points": MLFeatureValue(multiArray: coords), "labels": MLFeatureValue(multiArray: labels)])
                    var inputs = [String: MLFeatureValue]()
                    for key in ["image_embedding", "feats_s0", "feats_s1"] { inputs[key] = encoded.featureValue(for: key) }
                    inputs["sparse_embedding"] = p.featureValue(for: "sparse_embeddings")
                    inputs["dense_embedding"] = p.featureValue(for: "dense_embeddings")
                    let result = try predict(decoder, inputs)
                    durations.append(clock() - begin)
                    scores = floats(try array(result, "scores"))
                    try require(scores.count == 3 && scores.allSatisfy(\.isFinite), "Invalid SAM scores")
                    let masks = try array(result, "low_res_masks")
                    try require(masks.shape.map(\.intValue) == [1, 3, 256, 256], "Unexpected SAM dimensions")
                    let best = scores.indices.max(by: { scores[$0] < scores[$1] })!
                    let values = floats(masks)
                    allMasks = values
                    chosen = Array(values[(best * 65536)..<((best + 1) * 65536)])
                }
                let file = sample.id + "-sam-" + name + ".f32"
                try saveFloats(chosen, out.appendingPathComponent(file))
                if name == "refined" {
                    for candidate in 0..<3 {
                        try saveFloats(Array(allMasks[(candidate * 65536)..<((candidate + 1) * 65536)]),
                            out.appendingPathComponent(sample.id + "-candidate-\(candidate).f32"))
                    }
                }
                outputs.append(["variant": name, "points": points, "scores": scores,
                    "promptSeconds": durations, "file": file, "width": 256, "height": 256])
            }
            results.append(["id": sample.id, "width": original.width, "height": original.height,
                "preprocessSeconds": prepSeconds, "encodeSeconds": encodeSeconds, "outputs": outputs])
            print("sam", sample.id, String(format: "encode %.3fs", encodeSeconds)); fflush(stdout)
        }
    }
    return ["loadSeconds": [encLoad, promptLoad, decLoad], "results": results,
        "computeUnits": cpu ? "cpuOnly" : "all"]
}

func body(root: URL, samples: [Sample], sampleRoot: URL, out: URL) throws -> [String: Any] {
    let environment = try Environment(), options = try Options()
    try options.setHardwareAccelerators([.cpu])
    let cpu = try CpuOptions(); try cpu.setNumThreads(4); try options.addConcreteOptions(cpu)
    let start = clock()
    let model = try CompiledModel(filePath: root.appendingPathComponent("selfie_multiclass_256x256.tflite").path,
        environment: environment, options: options)
    let loadSeconds = clock() - start
    let inputType = try model.inputTensorType(inputIndex: 0)
    let outputType = try model.outputTensorType(outputIndex: 0)
    try require(inputType.layout.dimensions == [1, 256, 256, 3] && inputType.elementType == .float32, "Unexpected Selfie input")
    try require(outputType.layout.dimensions == [1, 256, 256, 6] && outputType.elementType == .float32, "Unexpected Selfie output")
    let inputs = try model.createInputBuffers(), outputs = try model.createOutputBuffers()
    var results = [[String: Any]]()
    for sample in samples where sample.category == "Person" {
        try autoreleasepool {
            let original = try image(sampleRoot.appendingPathComponent(sample.file))
            let (person, roi) = try crop(original, box: sample.box, square: false, margin: 1.08)
            let start = clock(), pixels = try rgba(person, width: 256, height: 256)
            var rgb = [Float](); rgb.reserveCapacity(256 * 256 * 3)
            // Official Selfie metadata uses mean=0, std=255 (RGB [0,1]).
            for i in stride(from: 0, to: pixels.count, by: 4) {
                rgb.append(Float(pixels[i]) / 255); rgb.append(Float(pixels[i + 1]) / 255); rgb.append(Float(pixels[i + 2]) / 255)
            }
            try inputs[0].write(rgb)
            let prepSeconds = clock() - start
            var durations = [Double](), values = [Float]()
            for _ in 0..<3 {
                let t = clock(); try model.run(inputs: inputs, outputs: outputs); durations.append(clock() - t)
                values = try outputs[0].read()
            }
            try require(values.count == 256 * 256 * 6, "Selfie output length mismatch")
            let file = sample.id + "-body.f32"
            try saveFloats(values, out.appendingPathComponent(file))
            results.append(["id": sample.id, "roi": roi, "file": file, "width": 256, "height": 256,
                "preprocessSeconds": prepSeconds, "inferenceSeconds": durations,
                "min": values.min()!, "max": values.max()!])
            print("body", sample.id, durations); fflush(stdout)
        }
    }
    return ["loadSeconds": loadSeconds, "computeUnits": "LiteRT CPU 4 threads", "results": results]
}

func face(root: URL, samples: [Sample], sampleRoot: URL, out: URL, cpu: Bool) throws -> [String: Any] {
    let (model, loadSeconds) = try load(root, "FaceParsing", cpu: cpu)
    var results = [[String: Any]]()
    for sample in samples where sample.category == "Person" {
        try autoreleasepool {
            let original = try image(sampleRoot.appendingPathComponent(sample.file))
            let b = sample.box
            let faces = sample.faces.filter {
                let f = $0.box, x = (f[0] + f[2]) / 2, y = (f[1] + f[3]) / 2
                return x >= b[0] && x <= b[2] && y >= b[1] && y <= b[3]
            }
            guard let target = faces.max(by: { ($0.box[2]-$0.box[0])*($0.box[3]-$0.box[1]) < ($1.box[2]-$1.box[0])*($1.box[3]-$1.box[1]) }) else {
                results.append(["id": sample.id, "error": "No annotated face in target box"]); return
            }
            let (face, roi) = try crop(original, box: target.box, square: true, margin: 1.6)
            let t = clock(), pixels = try pixelBuffer(face, side: 512), prepSeconds = clock() - t
            var durations = [Double](), labels = [UInt8](), shape = [Int]()
            for _ in 0..<3 {
                let start = clock()
                let result = try predict(model, ["input": MLFeatureValue(pixelBuffer: pixels)])
                durations.append(clock() - start)
                let tensor = try array(result, "argmax_out")
                shape = tensor.shape.map(\.intValue)
                let values = floats(tensor)
                try require(values.count == 512 * 512 && values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 18 && $0.rounded() == $0 }, "Invalid face labels")
                labels = values.map { UInt8($0) }
            }
            let file = sample.id + "-face.u8"
            try Data(labels).write(to: out.appendingPathComponent(file), options: .atomic)
            results.append(["id": sample.id, "roi": roi, "file": file, "width": 512, "height": 512,
                "roiSource": "fixed Open Images human-face annotation; manual ROI equivalent",
                "preprocessSeconds": prepSeconds, "inferenceSeconds": durations, "shape": shape,
                "labelsPresent": Array(Set(labels)).sorted()])
            print("face", sample.id, durations); fflush(stdout)
        }
    }
    return ["loadSeconds": loadSeconds, "computeUnits": cpu ? "cpuOnly" : "all", "results": results]
}

func selfTest() throws {
    let source: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255]
    func makeImage(_ bytes: [UInt8]) -> CGImage {
        CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    let original = makeImage(source)
    try require(try rgba(original, width: 2, height: 2) == source, "RGB row orientation changed")
    let (topLeft, roi) = try crop(original, box: [0,0,0.5,0.5], square: false, margin: 1)
    try require(try rgba(topLeft, width: 1, height: 1) == [255,0,0,255] && roi == [0,0,0.5,0.5], "ROI origin changed")
    let buffer = try pixelBuffer(original, side: 2)
    CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    try require(Array(UnsafeBufferPointer(start: bytes, count: 4)) == [0,0,255,255], "RGB/BGRA conversion changed")
    let transparent: [UInt8] = [128,0,0,128, 0,0,0,0, 0,0,255,255, 255,255,255,255]
    try require(try rgba(makeImage(transparent), width: 2, height: 2) == transparent, "Input alpha pass-through changed")
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("phosdeck-mask-orientation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let fixture = temporary.appendingPathComponent("orientation.tiff")
    guard let destination = CGImageDestinationCreateWithURL(fixture as CFURL, "public.tiff" as CFString, 1, nil) else {
        throw ProbeError.invalid("Cannot create EXIF fixture")
    }
    CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary)
    try require(CGImageDestinationFinalize(destination), "Cannot save EXIF fixture")
    let oriented = try image(fixture)
    let rotated = Array(source[8..<12]) + Array(source[0..<4]) + Array(source[12..<16]) + Array(source[4..<8])
    try require(try rgba(oriented, width: 2, height: 2) == rotated, "EXIF orientation was not applied exactly once")
    let a = try MLMultiArray(shape: [2,2], dataType: .float16)
    for i in 0..<4 { a[i] = NSNumber(value: i) }
    try require(floats(a) == [0,1,2,3], "Float16 conversion changed")
    print("smart-mask-probe self-test passed (rows, ROI, color order, alpha pass-through, EXIF, float16)")
}

do {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "self-test" { try selfTest(); exit(0) }
    if args.count == 3 && args[1] == "compile" {
        let root = URL(fileURLWithPath: args[2])
        var results = [[String: Any]]()
        for name in ["SAM2_1TinyImageEncoderFLOAT16", "SAM2_1TinyPromptEncoderFLOAT16", "SAM2_1TinyMaskDecoderFLOAT16", "FaceParsing"] {
            let start = clock(), compiled = try MLModel.compileModel(at: root.appendingPathComponent(name + ".mlpackage"))
            let seconds = clock() - start, destination = root.appendingPathComponent(name + ".mlmodelc")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: compiled, to: destination)
            }
            results.append(["model": name, "compileSeconds": seconds])
        }
        try saveJSON(results, root.appendingPathComponent("compile-report.json")); exit(0)
    }
    try require(args.count >= 6, "Usage: smart-mask-probe <sam|body|face> <models> <sample-manifest.json> <sample-dir> <output-dir> [cpu]")
    let mode = args[1], root = URL(fileURLWithPath: args[2]), manifest = URL(fileURLWithPath: args[3])
    let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: manifest))
    let sampleRoot = URL(fileURLWithPath: args[4]), output = URL(fileURLWithPath: args[5])
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let before = memory(), start = clock(), cpu = args.dropFirst(6).contains("cpu")
    var report: [String: Any]
    switch mode {
    case "sam": report = try sam(root: root, samples: samples, sampleRoot: sampleRoot, out: output, cpu: cpu)
    case "body": report = try body(root: root, samples: samples, sampleRoot: sampleRoot, out: output)
    case "face": report = try face(root: root, samples: samples, sampleRoot: sampleRoot, out: output, cpu: cpu)
    default: throw ProbeError.invalid("Unknown mode \(mode)")
    }
    report["mode"] = mode; report["elapsedSeconds"] = clock() - start
    report["processPeakBytes"] = memory(); report["baselinePeakBytes"] = before
    report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    try saveJSON(report, output.appendingPathComponent(mode + "-report.json"))
} catch {
    fputs("smart-mask-probe: \(error)\n", stderr); exit(1)
}
