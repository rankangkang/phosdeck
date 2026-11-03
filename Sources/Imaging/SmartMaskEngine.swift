import Foundation
import CoreML
import CoreImage
import CoreVideo
import Vision
import Accelerate

struct SmartMaskPrompt: Equatable {
    var point: MaskPoint
    var label: Int // SAM: 0 exclude, 1 include, 2 top-left box, 3 bottom-right box.
}
struct SmartMaskCandidate {
    var raster: SmartMaskRaster
    var score: Float
    var selectedPixels: Int
    var thumbnail: CGImage? = nil
}
struct SmartMaskPerson {
    var raster: SmartMaskRaster
    var bounds: CGRect
    var thumbnail: CGImage?
}

struct SmartMaskBaseline: Equatable {
    let exposure: Double
    let temperature: Double
    let tint: Double
    init(_ recipe: EditRecipe) {
        exposure = recipe.baselineExposure; temperature = recipe.baselineTemperature; tint = recipe.baselineTint
    }
}

struct SmartMaskPersonAnalysis {
    var parts: [SmartMaskPart: SmartMaskRaster]
    var faces: [CGRect]
    var faceRefined: Bool
    var faceFailure: String? = nil
    var cost: Int { parts.values.reduce(0) { $0 + $1.pixelCount * 2 + $1.byteCount } }
}

/// Current-source results only; include decoded storage in the conservative budget.
struct SmartMaskPartCache {
    struct Key: Equatable {
        let selection: SmartMaskRaster
        let baseline: SmartMaskBaseline
        let inputSize: CGSize
        let face: CGRect?
    }
    private struct Entry { let key: Key; let value: SmartMaskPersonAnalysis }
    private var entries: [Entry] = []
    private var source: SmartMaskSource?
    private var baseline: SmartMaskBaseline?
    let limit: Int
    let byteLimit: Int
    init(limit: Int = 16, byteLimit: Int = 32 * 1024 * 1024) { self.limit = limit; self.byteLimit = byteLimit }
    var count: Int { entries.count }
    var cost: Int { entries.reduce(0) { $0 + $1.value.cost } }
    mutating func value(for key: Key) -> SmartMaskPersonAnalysis? {
        if source != key.selection.source || baseline != key.baseline {
            entries.removeAll(); source = key.selection.source; baseline = key.baseline
        }
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index); entries.append(entry)
        return entry.value
    }
    mutating func insert(_ value: SmartMaskPersonAnalysis, for key: Key) {
        guard source == key.selection.source, baseline == key.baseline, value.cost <= byteLimit, limit > 0 else { return }
        entries.removeAll { $0.key == key }
        while !entries.isEmpty && (entries.count >= limit || cost + value.cost > byteLimit) { entries.removeFirst() }
        entries.append(Entry(key: key, value: value))
    }
}

/// Optional research resources are independent of system Vision person selection.
struct SmartMaskModels: Equatable, Sendable {
    static let objectNames = ["SAM2_1TinyImageEncoderFLOAT16", "SAM2_1TinyPromptEncoderFLOAT16", "SAM2_1TinyMaskDecoderFLOAT16"]
    let objectDirectory: URL?
    let bodyURL: URL?
    let faceURL: URL?

    init(directory: URL?) {
        func resource(_ name: String, directory expectedDirectory: Bool) -> URL? {
            guard let url = directory?.appendingPathComponent(name) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            return (expectedDirectory ? values?.isDirectory == true : values?.isRegularFile == true) ? url : nil
        }
        objectDirectory = Self.objectNames.allSatisfy { resource($0 + ".mlmodelc", directory: true) != nil } ? directory : nil
        bodyURL = resource("selfie_multiclass_256x256.tflite", directory: false)
        faceURL = resource("FaceParsing.mlmodelc", directory: true)
    }
    var hasParts: Bool { bodyURL != nil || faceURL != nil }
    func supports(_ part: SmartMaskPart) -> Bool {
        switch part {
        case .faceSkin: bodyURL != nil || faceURL != nil
        case .bodySkin, .hair, .clothes: bodyURL != nil
        case .brows, .eyes, .lips: faceURL != nil
        }
    }
}

struct SmartMaskField {
    var values: [Float]
    var width: Int
    var height: Int
    var region: CGRect
    init(values: [Float], width: Int, height: Int, region: CGRect) {
        self.values = values; self.width = width; self.height = height; self.region = region
    }
    init(_ tile: SmartMaskTile) throws {
        let data = try tile.pixels()
        values = data.withUnsafeBytes { bytes in bytes.bindMemory(to: UInt16.self).map { Float(UInt16(littleEndian: $0)) / 65535 } }
        width = tile.width; height = tile.height; region = tile.region
    }
    func point(x: Int, y: Int) -> CGPoint {
        CGPoint(x: region.minX + (Double(x) + 0.5) / Double(width) * region.width,
            y: region.maxY - (Double(y) + 0.5) / Double(height) * region.height)
    }
    func sample(_ point: CGPoint) -> Float {
        guard point.x >= region.minX, point.x <= region.maxX, point.y >= region.minY, point.y <= region.maxY else { return 0 }
        let x = min(Double(width - 1), max(0, (point.x - region.minX) / region.width * Double(width) - 0.5))
        let y = min(Double(height - 1), max(0, (region.maxY - point.y) / region.height * Double(height) - 0.5))
        let x0 = Int(x), y0 = Int(y), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let dx = Float(x - Double(x0)), dy = Float(y - Double(y0))
        return (values[y0 * width + x0] * (1 - dx) + values[y0 * width + x1] * dx) * (1 - dy)
            + (values[y1 * width + x0] * (1 - dx) + values[y1 * width + x1] * dx) * dy
    }
    func tile() throws -> SmartMaskTile { try SmartMaskTile(values: values, width: width, height: height, region: region) }
    /// Half-pixel bilinear coordinates, with replicated borders. Keep signed
    /// logits here: thresholding before resizing loses their zero crossings.
    func resampled(width targetWidth: Int, height targetHeight: Int) throws -> SmartMaskField {
        guard width > 0, height > 0, width <= SmartMaskTile.maxPixels / height, values.count == width * height,
              targetWidth > 0, targetHeight > 0, targetWidth <= SmartMaskTile.maxPixels / targetHeight,
              targetWidth <= SmartMaskTile.maxPixels / height,
              values.allSatisfy(\.isFinite) else {
            throw LRCError(L10n.text("app.smartMaskPixelsAreInvalidOrExceedTheLimit", defaultValue: "Smart mask pixels are invalid or exceed the limit"))
        }
        try Task.checkCancellation()
        if width == targetWidth, height == targetHeight { return self }
        let coordinates = (0..<targetWidth).map { Float(min(Double(width - 1), max(0, (Double($0) + 0.5) * Double(width) / Double(targetWidth) - 0.5))) }
        var horizontal = [Float](repeating: 0, count: targetWidth * height)
        // vDSP_vlint reads both adjacent samples even when their fraction is zero.
        // Pad each row explicitly instead of reading into the next row or beyond it.
        var row = [Float](repeating: 0, count: width + 1)
        try values.withUnsafeBufferPointer { source in
            try horizontal.withUnsafeMutableBufferPointer { output in
                try row.withUnsafeMutableBufferPointer { padded in
                    for y in 0..<height {
                        if y.isMultiple(of: 16) { try Task.checkCancellation() }
                        padded.baseAddress!.update(from: source.baseAddress! + y * width, count: width)
                        padded[width] = padded[width - 1]
                        vDSP_vlint(padded.baseAddress!, coordinates, 1, output.baseAddress! + y * targetWidth, 1, vDSP_Length(targetWidth), vDSP_Length(width + 1))
                    }
                }
            }
        }
        var result = [Float](repeating: 0, count: targetWidth * targetHeight)
        try horizontal.withUnsafeBufferPointer { source in
            try result.withUnsafeMutableBufferPointer { output in
                for y in 0..<targetHeight {
                    if y.isMultiple(of: 16) { try Task.checkCancellation() }
                    let coordinate = min(Double(height - 1), max(0, (Double(y) + 0.5) * Double(height) / Double(targetHeight) - 0.5))
                    let top = Int(coordinate), bottom = min(height - 1, top + 1)
                    var fraction = Float(coordinate - Double(top))
                    vDSP_vintb(source.baseAddress! + top * targetWidth, 1, source.baseAddress! + bottom * targetWidth, 1,
                        &fraction, output.baseAddress! + y * targetWidth, 1, vDSP_Length(targetWidth))
                }
            }
        }
        return SmartMaskField(values: result, width: targetWidth, height: targetHeight, region: region)
    }
    func boundingRegion() -> CGRect? {
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height { for x in 0..<width where values[y * width + x] > 0.5 {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
        } }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: region.minX + Double(left) / Double(width) * region.width,
            y: region.maxY - Double(bottom + 1) / Double(height) * region.height,
            width: Double(right - left + 1) / Double(width) * region.width,
            height: Double(bottom - top + 1) / Double(height) * region.height)
    }
    static func region(_ a: MaskPoint, _ b: MaskPoint) -> CGRect? {
        guard a.valid, b.valid, abs(a.x - b.x) > 0.00001, abs(a.y - b.y) > 0.00001 else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func faceRegion(_ box: CGRect, size: CGSize) -> CGRect {
        let side = max(box.width * size.width, box.height * size.height) * 1.6
        return CGRect(x: box.midX - side / size.width / 2, y: box.midY - side / size.height / 2,
            width: side / size.width, height: side / size.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

enum SmartMaskInput {
    static func rgba(_ image: CGImage, side: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(data: ptr.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: ImagePipeline.outputSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side)); return true
        }
        guard ok else { throw LRCError(L10n.text("app.smartMaskInputConversionFailed", defaultValue: "Smart mask input conversion failed")) }
        return bytes
    }
    static func buffer(_ image: CGImage, side: Int) throws -> CVPixelBuffer {
        let rgba = try rgba(image, side: side)
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess, let result else {
            throw LRCError(L10n.text("app.couldNotCreateTheSmartMaskInputBuffer", defaultValue: "Could not create the smart mask input buffer"))
        }
        CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<side { for x in 0..<side {
            let i = (y * side + x) * 4, j = y * stride + x * 4
            bytes[j] = rgba[i + 2]; bytes[j + 1] = rgba[i + 1]; bytes[j + 2] = rgba[i]; bytes[j + 3] = rgba[i + 3]
        } }
        return result
    }
}

actor SmartMaskEngine {
    private final class Resources {}
    static let bundledModels = SmartMaskModels(directory: Bundle(for: Resources.self).resourceURL?.appendingPathComponent("SmartMaskModels"))
    private let models: SmartMaskModels
    private let thumbnailContext = CIContext(options: [.workingFormat: CIFormat.RGBAf])
    private var encoder: MLModel?
    private var prompt: MLModel?
    private var decoder: MLModel?
    private var encoding: MLFeatureProvider?
    private var encodingSource: SmartMaskSource?
    private var peopleSource: SmartMaskSource?
    private var peopleBaseline: SmartMaskBaseline?
    private var peopleCache: [SmartMaskPerson] = []
    private var partCache = SmartMaskPartCache()
    private var bodyModel: SelfieMaskModel?
    private var faceModel: MLModel?
    private(set) var bodyPredictionCount = 0
    private(set) var facePredictionCount = 0
    private(set) var partCacheHits = 0
    var cachedPartCount: Int { partCache.count }
    var cachedPartCost: Int { partCache.cost }
    init(directory: URL? = nil) { models = SmartMaskModels(directory: directory) }
    init(models: SmartMaskModels) { self.models = models }
    private func model(at url: URL, cpu: Bool = false) throws -> MLModel {
        let configuration = MLModelConfiguration(); configuration.computeUnits = cpu ? .cpuOnly : .all
        return try MLModel(contentsOf: url, configuration: configuration)
    }
    private func predict(_ model: MLModel, _ input: [String: MLFeatureValue]) throws -> MLFeatureProvider {
        try Task.checkCancellation()
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: input))
        try Task.checkCancellation(); return output
    }
    private func values(_ output: MLFeatureProvider, _ key: String, count: Int) throws -> [Float] {
        guard let array = output.featureValue(for: key)?.multiArrayValue, array.count == count else { throw LRCError(L10n.text("app.smartMaskOutputDimensionsMismatch", defaultValue: "Smart mask output dimensions mismatch")) }
        let result = MLShapedArray<Float>(converting: array).scalars
        guard result.allSatisfy(\.isFinite) else { throw LRCError(L10n.text("app.smartMaskOutputContainsInvalidNumbers", defaultValue: "Smart mask output contains invalid numbers")) }
        return result
    }
    func prepare(image: CGImage, source: SmartMaskSource) throws {
        try Task.checkCancellation()
        guard let directory = models.objectDirectory else { throw LRCError(L10n.text("smartMask.objectUnavailable", defaultValue: "Object selection is not included in this build")) }
        if encoder == nil { encoder = try model(at: directory.appendingPathComponent("SAM2_1TinyImageEncoderFLOAT16.mlmodelc")) }
        if prompt == nil { prompt = try model(at: directory.appendingPathComponent("SAM2_1TinyPromptEncoderFLOAT16.mlmodelc")) }
        if decoder == nil { decoder = try model(at: directory.appendingPathComponent("SAM2_1TinyMaskDecoderFLOAT16.mlmodelc")) }
        if encodingSource != source || encoding == nil {
            encoding = try predict(encoder!, ["image": MLFeatureValue(pixelBuffer: SmartMaskInput.buffer(image, side: 1024))])
            encodingSource = source
        }
    }
    func select(image: CGImage, source: SmartMaskSource, prompts: [SmartMaskPrompt]) throws -> [SmartMaskCandidate] {
        guard !prompts.isEmpty, prompts.count <= 64,
              prompts.allSatisfy({ $0.point.valid && (0...3).contains($0.label) }) else { throw LRCError(L10n.text("app.objectPromptsAreInvalidOrExceedTheLimit", defaultValue: "Object prompts are invalid or exceed the limit")) }
        try prepare(image: image, source: source)
        let coordinates = try MLMultiArray(shape: [1, NSNumber(value: prompts.count), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: prompts.count)], dataType: .int32)
        for (i, p) in prompts.enumerated() {
            coordinates[[0, NSNumber(value: i), 0]] = NSNumber(value: p.point.x * 1024)
            coordinates[[0, NSNumber(value: i), 1]] = NSNumber(value: (1 - p.point.y) * 1024)
            labels[i] = NSNumber(value: p.label)
        }
        let encodedPrompt = try predict(prompt!, ["points": MLFeatureValue(multiArray: coordinates), "labels": MLFeatureValue(multiArray: labels)])
        var input = [String: MLFeatureValue]()
        for key in ["image_embedding", "feats_s0", "feats_s1"] { input[key] = encoding!.featureValue(for: key) }
        input["sparse_embedding"] = encodedPrompt.featureValue(for: "sparse_embeddings")
        input["dense_embedding"] = encodedPrompt.featureValue(for: "dense_embeddings")
        let output = try predict(decoder!, input)
        let scores = try values(output, "scores", count: 3), masks = try values(output, "low_res_masks", count: 3 * 256 * 256)
        try source.validate()
        let scale = min(1, 1024 / max(source.size.width, source.size.height))
        let width = max(1, Int((source.size.width * scale).rounded())), height = max(1, Int((source.size.height * scale).rounded()))
        return try (0..<3).map { index in
            let logits = SmartMaskField(values: Array(masks[(index * 65536)..<((index + 1) * 65536)]), width: 256, height: 256, region: CGRect(x: 0, y: 0, width: 1, height: 1))
            let binary = try logits.resampled(width: width, height: height).values.map { Float($0 > 0 ? 1 : 0) }
            let tile = try SmartMaskTile(values: binary, width: width, height: height, region: logits.region)
            let raster = SmartMaskRaster(source: source, model: "sam2.1-tiny@39ae0a8/upsample-r1", base: tile)
            return SmartMaskCandidate(raster: raster, score: scores[index], selectedPixels: binary.filter { $0 > 0 }.count,
                thumbnail: try previewThumbnail(raster))
        }.sorted { $0.score > $1.score }
    }
    func previewThumbnail(_ raster: SmartMaskRaster) throws -> CGImage? {
        try Task.checkCancellation()
        let scale = 120 / max(raster.source.size.width, raster.source.size.height)
        let extent = CGRect(x: 0, y: 0, width: max(1, (raster.source.size.width * scale).rounded()), height: max(1, (raster.source.size.height * scale).rounded()))
        return thumbnailContext.createCGImage(try raster.image(extent: extent), from: extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    func people(image: CGImage, source: SmartMaskSource, baseline: SmartMaskBaseline? = nil) throws -> [SmartMaskPerson] {
        try Task.checkCancellation()
        if peopleSource == source && peopleBaseline == baseline { return peopleCache }
        let request = VNGeneratePersonInstanceMaskRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request, faceRequest])
        var people: [SmartMaskPerson] = []
        if let observation = request.results?.first {
            for index in observation.allInstances {
                try Task.checkCancellation()
                let buffer = try observation.generateMask(forInstances: IndexSet(integer: index))
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
                      width > 0, height > 0, width <= SmartMaskTile.maxPixels / height else { throw LRCError(L10n.text("app.personDetectionOutputDimensionsOrFormatMismatch", defaultValue: "Person detection output dimensions or format mismatch")) }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw LRCError(L10n.text("app.personDetectionOutputIsEmpty", defaultValue: "Person detection output is empty")) }
                let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.stride
                let pixels = address.assumingMemoryBound(to: Float.self)
                var values = [Float](); values.reserveCapacity(width * height)
                for y in 0..<height { values.append(contentsOf: UnsafeBufferPointer(start: pixels + y * stride, count: width)) }
                let field = SmartMaskField(values: values, width: width, height: height, region: CGRect(x: 0, y: 0, width: 1, height: 1))
                guard let bounds = field.boundingRegion() else { continue }
                let raster = SmartMaskRaster(source: source, model: "vision-person-instance-r1", base: try field.tile())
                let face = (faceRequest.results ?? []).map(\.boundingBox)
                    .filter { field.sample(CGPoint(x: $0.midX, y: $0.midY)) > 0.5 }
                    .max { $0.width * $0.height < $1.width * $1.height }
                let avatar = face.map { SmartMaskField.faceRegion($0, size: CGSize(width: image.width, height: image.height)) } ?? bounds
                let crop = CGRect(x: avatar.minX * Double(image.width), y: (1 - avatar.maxY) * Double(image.height),
                    width: avatar.width * Double(image.width), height: avatar.height * Double(image.height)).integral
                var thumbnail: CGImage?
                if let cropped = image.cropping(to: crop) {
                    let scale = min(1, 120 / Double(max(cropped.width, cropped.height)))
                    let small = CIImage(cgImage: cropped).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    thumbnail = thumbnailContext.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: ImagePipeline.outputSpace)
                }
                people.append(SmartMaskPerson(raster: raster, bounds: bounds, thumbnail: thumbnail))
            }
        }
        try Task.checkCancellation()
        people.sort { $0.bounds.midX < $1.bounds.midX }
        peopleSource = source; peopleBaseline = baseline; peopleCache = people
        return people
    }
    func bounds(of raster: SmartMaskRaster) throws -> CGRect? { try SmartMaskField(raster.base).boundingRegion() }
    func analyzePerson(image: CGImage, selection: SmartMaskRaster, request: ImageRequest,
                       pipeline: ImagePipeline, face manual: CGRect? = nil) async throws -> SmartMaskPersonAnalysis {
        try Task.checkCancellation()
        try selection.validate()
        guard let recipe = request.recipe, selection.source.matches(recipe) else { throw LRCError(L10n.text("app.smartMaskInputFailedOrItsSourceChanged", defaultValue: "Smart mask input failed or its source changed")) }
        let key = SmartMaskPartCache.Key(selection: selection, baseline: SmartMaskBaseline(recipe),
            inputSize: CGSize(width: image.width, height: image.height), face: manual)
        if let cached = partCache.value(for: key) {
            try await pipeline.validateSmartMaskSource(request)
            try Task.checkCancellation()
            partCacheHits += 1; return cached
        }
        guard let bounds = try bounds(of: selection) else { throw LRCError(L10n.text("app.theCurrentPersonSelectionIsEmpty", defaultValue: "The current person selection is empty")) }
        var parts: [SmartMaskPart: SmartMaskRaster] = [:]
        if models.bodyURL != nil {
            let region = bounds.insetBy(dx: -bounds.width * 0.04, dy: -bounds.height * 0.04).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let input = try await pipeline.smartMaskInput(request, region: region, longEdge: 1024)
            try Task.checkCancellation()
            parts = try body(image: input.image, region: input.region, selection: selection)
        }
        var faces: [CGRect] = [], faceFailure: String?
        if models.faceURL != nil {
            do { faces = try self.faces(image: image, selection: selection) }
            catch is CancellationError { throw CancellationError() }
            catch { faceFailure = error.localizedDescription }
        }
        let chosen = manual ?? (faces.count == 1 ? SmartMaskField.faceRegion(faces[0], size: selection.source.size) : nil)
        var faceRefined = false
        if models.faceURL != nil, let chosen {
            // Source/crop failures must still fail the request. Only optional face
            // inference may fall back to the body parts already computed above.
            let input = try await pipeline.smartMaskInput(request, region: chosen, longEdge: 1024)
            try Task.checkCancellation()
            do {
                parts = try face(image: input.image, region: input.region, body: parts, selection: selection)
                faceRefined = true; faceFailure = nil
            } catch is CancellationError { throw CancellationError() }
            catch { faceFailure = error.localizedDescription }
        }
        try Task.checkCancellation()
        let result = SmartMaskPersonAnalysis(parts: parts, faces: faces, faceRefined: faceRefined, faceFailure: faceFailure)
        // A retry must attempt a failed model again, rather than cache its absence.
        if faceFailure == nil { partCache.insert(result, for: key) }
        return result
    }
    func faces(image: CGImage, selection: SmartMaskRaster) throws -> [CGRect] {
        let instance = try SmartMaskField(selection.base), request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).map(\.boundingBox).filter { instance.sample(CGPoint(x: $0.midX, y: $0.midY)) > 0.5 }
            .sorted { $0.width * $0.height > $1.width * $1.height }
    }
    func body(image: CGImage, region: CGRect, selection: SmartMaskRaster) throws -> [SmartMaskPart: SmartMaskRaster] {
        guard let url = models.bodyURL else { throw LRCError(L10n.text("smartMask.bodyUnavailable", defaultValue: "Body-part selection is not included in this build")) }
        let instance = try SmartMaskField(selection.base), pixels = try SmartMaskInput.rgba(image, side: 256)
        var rgb = [Float](); rgb.reserveCapacity(256 * 256 * 3)
        for i in stride(from: 0, to: pixels.count, by: 4) { rgb += [Float(pixels[i])/255, Float(pixels[i+1])/255, Float(pixels[i+2])/255] }
        if bodyModel == nil { bodyModel = try SelfieMaskModel(url: url) }
        bodyPredictionCount += 1
        let logits = try bodyModel!.predict(rgb: rgb)
        let types: [(SmartMaskPart, Int)] = [(.faceSkin, 3), (.bodySkin, 2), (.hair, 1), (.clothes, 4)]
        var fields = types.map { _ in SmartMaskField(values: [Float](repeating: 0, count: 65536), width: 256, height: 256, region: region) }
        var present = Set<Int>()
        for i in 0..<65536 {
            let p = fields[0].point(x: i % 256, y: i / 256)
            guard instance.sample(p) > 0.5 else { continue }
            let pixel = Array(logits[(i * 6)..<(i * 6 + 6)]), peak = pixel.max()!
            let exp = pixel.map { Foundation.exp($0 - peak) }, sum = exp.reduce(0, +)
            present.insert(pixel.indices.max(by: { pixel[$0] < pixel[$1] })!)
            for j in types.indices { fields[j].values[i] = exp[types[j].1] / sum }
        }
        var result = [SmartMaskPart: SmartMaskRaster]()
        for j in types.indices where present.contains(types[j].1) {
            var raster = SmartMaskRaster(source: selection.source, model: selection.model + "+selfie256@c6748b1", base: try fields[j].tile())
            raster.instance = selection.base; raster.parts = [types[j].0]; result[types[j].0] = raster
        }
        return result
    }
    func face(image: CGImage, region: CGRect, body: [SmartMaskPart: SmartMaskRaster], selection: SmartMaskRaster) throws -> [SmartMaskPart: SmartMaskRaster] {
        guard let url = models.faceURL else { throw LRCError(L10n.text("smartMask.faceUnavailable", defaultValue: "Fine facial selection is not included in this build")) }
        if faceModel == nil { faceModel = try model(at: url, cpu: true) }
        facePredictionCount += 1
        let instance = try SmartMaskField(selection.base)
        let output = try predict(faceModel!, ["input": MLFeatureValue(pixelBuffer: SmartMaskInput.buffer(image, side: 512))])
        let labels = try values(output, "argmax_out", count: 512 * 512)
        guard labels.allSatisfy({ $0 >= 0 && $0 <= 18 && $0.rounded() == $0 }) else { throw LRCError(L10n.text("app.invalidFaceClassificationOutput", defaultValue: "Invalid face classification output")) }
        let coarseBody = try body[.bodySkin].map { try SmartMaskField($0.base) }
        let coarseFace = try body[.faceSkin].map { try SmartMaskField($0.base) }
        var result = body
        let modelIdentity = (body.values.first?.model ?? selection.model) + "+bisenet@289c64b-cpu/skin-support-r1"
        let classes: [(SmartMaskPart, Set<Int>)] = [(.faceSkin, [1,10]), (.brows, [2,3]), (.eyes, [4,5]), (.lips, [12,13])]
        var patches = classes.map { _ in SmartMaskField(values: [Float](repeating: 0, count: labels.count), width: 512, height: 512, region: region) }
        var bodyPatch = patches[0]
        for i in labels.indices {
            let p = patches[0].point(x: i % 512, y: i / 512), label = Int(labels[i])
            guard instance.sample(p) > 0.5 else { continue }
            for j in classes.indices { patches[j].values[i] = classes[j].1.contains(label) ? 1 : 0 }
            if patches[0].values[i] > 0, let coarseFace {
                // The face parser can hallucinate cheeks on a foreground glove.
                // A clear coarse non-skin prediction vetoes that replacement;
                // uncertain borders fade in, while face-only builds stay independent.
                let support = coarseFace.sample(p) + (coarseBody?.sample(p) ?? 0)
                let t = min(1, max(0, (support - 0.05) / 0.2))
                patches[0].values[i] *= t * t * (3 - 2 * t)
            }
            bodyPatch.values[i] = (1...13).contains(label) ? 0 : (coarseBody?.sample(p) ?? 0)
        }
        guard patches.contains(where: { $0.values.contains(where: { $0 > 0 }) }) else {
            throw LRCError(L10n.text("smartMask.noFacePartsInRegion", defaultValue: "No facial features were found in this person's face region"))
        }
        for j in classes.indices {
            let part = classes[j].0
            guard patches[j].values.contains(where: { $0 > 0 }) else { result[part] = nil; continue }
            var raster = SmartMaskRaster(source: selection.source, model: modelIdentity, base: try patches[j].tile())
            if part == .faceSkin, let coarse = body[.faceSkin] { raster.base = coarse.base; raster.facePatch = try patches[j].tile() }
            raster.instance = selection.base; raster.parts = [part]; result[part] = raster
        }
        if var skin = body[.bodySkin] { skin.facePatch = try bodyPatch.tile(); skin.model = modelIdentity; result[.bodySkin] = skin }
        return result
    }
    /// Compose already clipped instances in the same source plane. Keep `union`'s
    /// same-instance contract for body-part refinement; this is the explicit people union.
    func combinePeople(_ rasters: [SmartMaskRaster]) throws -> SmartMaskRaster {
        try Task.checkCancellation()
        guard let first = rasters.first else { throw LRCError(L10n.text("app.selectAPersonToAdjust", defaultValue: "Select a person to adjust")) }
        for raster in rasters { try raster.validate() }
        guard rasters.allSatisfy({ $0.source == first.source }) else { throw LRCError(L10n.text("app.smartMaskInputFailedOrItsSourceChanged", defaultValue: "Smart mask input failed or its source changed")) }
        if rasters.count == 1 { return first }
        let planes = try rasters.map { (try SmartMaskField($0.base), try $0.facePatch.map(SmartMaskField.init)) }
        func merged(_ planes: [(SmartMaskField, SmartMaskField?)], region: CGRect) throws -> SmartMaskTile {
            let fields = planes.flatMap { [$0.0] + ($0.1.map { [$0] } ?? []) }
            let densityX = fields.map { Double($0.width) / $0.region.width }.max() ?? 1
            let densityY = fields.map { Double($0.height) / $0.region.height }.max() ?? 1
            let width = Int(min(1024, max(1, ceil(region.width * densityX))))
            let height = Int(min(1024, max(1, ceil(region.height * densityY))))
            var result = SmartMaskField(values: [Float](repeating: 0, count: width * height), width: width, height: height, region: region)
            for y in 0..<height {
                if y.isMultiple(of: 16) { try Task.checkCancellation() }
                for x in 0..<width {
                    let point = result.point(x: x, y: y)
                    var value: Float = 0
                    for (base, patch) in planes {
                        value = max(value, patch.flatMap { $0.region.contains(point) ? $0.sample(point) : nil } ?? base.sample(point))
                    }
                    result.values[y * width + x] = value
                }
            }
            return try result.tile()
        }
        let region = rasters.reduce(CGRect.null) { $0.union($1.base.region) }
        var result = SmartMaskRaster(source: first.source,
            model: Set(rasters.map(\.model)).sorted().joined(separator: ";") + "/people-union-v1",
            base: try merged(planes, region: region))
        let fineRegion = rasters.reduce(CGRect.null) { area, raster in
            if let patch = raster.facePatch { return area.union(patch.region) }
            if raster.parts.contains(where: { [.brows, .eyes, .lips].contains($0) }) { return area.union(raster.base.region) }
            return area
        }
        if !fineRegion.isNull { result.facePatch = try merged(planes, region: fineRegion) }
        result.parts = SmartMaskPart.allCases.filter { part in rasters.contains { $0.parts.contains(part) } }
        if !result.parts.isEmpty {
            let instances = try rasters.map { (try SmartMaskField($0.instance ?? $0.base), Optional<SmartMaskField>.none) }
            result.instance = try merged(instances, region: instances.reduce(CGRect.null) { $0.union($1.0.region) })
        }
        try result.validate()
        return result
    }
    static func union(_ rasters: [SmartMaskRaster]) throws -> SmartMaskRaster {
        guard let first = rasters.first else { throw LRCError(L10n.text("app.selectBodyPartsFirst", defaultValue: "Select body parts first")) }
        if rasters.count == 1 { return first }
        guard rasters.allSatisfy({ $0.source == first.source && $0.instance == first.instance }) else { throw LRCError(L10n.text("app.partsFromDifferentPeopleCannotBeCombined", defaultValue: "Parts from different people cannot be combined")) }
        let planes = try rasters.map { (try SmartMaskField($0.base), try $0.facePatch.map(SmartMaskField.init)) }
        let region = rasters.reduce(CGRect.null) { $0.union($1.base.region) }
        let fineRegion = rasters.reduce(CGRect.null) { result, raster in
            if let patch = raster.facePatch { return result.union(patch.region) }
            if raster.parts.contains(where: { [.brows,.eyes,.lips].contains($0) }) { return result.union(raster.base.region) }
            return result
        }
        func field(region: CGRect, side: Int) throws -> SmartMaskField {
            var field = SmartMaskField(values: [Float](repeating: 0, count: side * side), width: side, height: side, region: region)
            for y in 0..<side {
                if y.isMultiple(of: 16) { try Task.checkCancellation() }
                for x in 0..<side {
                let p = field.point(x: x, y: y)
                field.values[y * side + x] = planes.map { base, patch in
                    if let patch, patch.region.contains(p) { return patch.sample(p) }
                    return base.sample(p)
                }.max() ?? 0
            } }
            return field
        }
        let models = Set(rasters.map(\.model)).sorted().joined(separator: ";") + "/union-v1"
        var result = SmartMaskRaster(source: first.source, model: models, base: try field(region: region, side: 256).tile())
        if !fineRegion.isNull { result.facePatch = try field(region: fineRegion, side: 512).tile() }
        result.instance = first.instance; result.parts = SmartMaskPart.allCases.filter { part in rasters.contains { $0.parts.contains(part) } }
        return result
    }
    func combine(_ rasters: [SmartMaskRaster]) throws -> SmartMaskRaster {
        try Task.checkCancellation()
        let result = try Self.union(rasters)
        try Task.checkCancellation(); return result
    }
}
