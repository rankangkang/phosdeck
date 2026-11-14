import Darwin
import Foundation

/// Median absolute deviation in linear RGB. One decision per RGB sample keeps
/// its channels together. Surviving samples are weighted by source coverage.
enum MergeRobustAverage {
    static let minimumSamples = 5
    private static let threshold = 3.5
    private static let normalMADScale = 1.4826

    static func combine(_ sources: [[SIMD4<Float>]],into result: inout [SIMD4<Float>],offset: Int) throws {
        enum Channel: Int, CaseIterable { case red, green, blue }
        var samples = [SIMD4<Float>](),values = [Double]()
        samples.reserveCapacity(sources.count)
        values.reserveCapacity(sources.count)
        let count = sources[0].count
        func median(_ sorted: [Double]) -> Double {
            (sorted[(sorted.count-1)/2]+sorted[sorted.count/2])*0.5
        }
        for pixel in 0..<count {
            if pixel.isMultiple(of:256) { try Task.checkCancellation() }
            samples.removeAll(keepingCapacity:true)
            for source in sources {
                let sample = source[pixel]
                if sample.w > 0 { samples.append(sample) }
            }
            guard !samples.isEmpty else { continue }

            var center = SIMD3<Double>.zero, limit = SIMD3<Double>.zero
            if samples.count >= minimumSamples {
                for channel in Channel.allCases {
                    let c = channel.rawValue
                    values.removeAll(keepingCapacity:true)
                    for sample in samples { values.append(Double(sample[c])) }
                    values.sort()
                    let middle = median(values)
                    center[c] = middle
                    for i in values.indices { values[i] = abs(values[i]-middle) }
                    values.sort()
                    // Avoid a zero cutoff for quantized or identical samples.
                    limit[c] = max(threshold*normalMADScale*median(values),1e-6,abs(middle)*1e-6)
                }
            }

            var sum = SIMD3<Double>.zero, weight = 0.0, coverage: Float = 0
            // The channel acceptance intersection can be empty. Choose the
            // nearest actual RGB sample in that case, without inventing color.
            var nearest = samples[0], nearestDistance = Double.infinity
            for sample in samples {
                let rgb = SIMD3(Double(sample.x),Double(sample.y),Double(sample.z))
                if samples.count >= minimumSamples {
                    let delta = rgb-center
                    let distance = max(abs(delta.x)/limit.x,abs(delta.y)/limit.y,abs(delta.z)/limit.z)
                    if distance < nearestDistance || (distance == nearestDistance && earlier(sample,than:nearest)) {
                        nearest = sample; nearestDistance = distance
                    }
                    if distance > 1 { continue }
                }
                let alpha = Double(sample.w)
                sum += rgb*alpha; weight += alpha; coverage = max(coverage,sample.w)
            }
            if weight > 0 {
                let rgb = sum/weight
                result[offset+pixel] = SIMD4(Float(rgb.x),Float(rgb.y),Float(rgb.z),coverage)
            } else { result[offset+pixel] = nearest }
        }
    }

    private static func earlier(_ a: SIMD4<Float>,than b: SIMD4<Float>) -> Bool {
        (-a.w,a.x,a.y,a.z) < (-b.w,b.x,b.y,b.z)
    }

    static func tileSize(frameCount: Int) -> Int {
        (16*1024*1024)/(frameCount*MemoryLayout<SIMD4<Float>>.stride)
    }

    /// Full-size sources are decoded/registered one at a time. The app keeps a
    /// single anonymous scratch file of frame-major float pixels, and reads
    /// bounded strips into memory for the reducer. No source file is a scratch
    /// destination and closing the handle releases the unlinked file.
    static func render(width: Int,height: Int,count: Int,temporaryDirectory: URL,
                       source: (Int) async throws -> MergeImage,progress: (Int,Int) async -> Void) async throws -> MergeImage {
        try Task.checkCancellation()
        try PhotoGeometry.checkSize(CGSize(width:width,height:height))
        guard (minimumSamples...PhotoMergeKind.robustAverage.sourceLimit).contains(count) else { throw MergeMasterCodec.invalid }
        let pixelCount = width*height
        let bytesPerPixel = MemoryLayout<SIMD4<Float>>.stride, frameBytes = pixelCount*bytesPerPixel
        do { try SafeFileWriter.requireCapacity(in:temporaryDirectory,bytes:Int64(frameBytes)*Int64(count)) }
        catch { throw LRCError(L10n.text("merge.robust.space",defaultValue:"The temporary stack needs more disk space. Free space or select a smaller source size.")+"\n"+error.localizedDescription) }
        let scratchPath = temporaryDirectory.appendingPathComponent(".phosdeck-stack-\(UUID().uuidString)").path
        let descriptor = Darwin.open(scratchPath,O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW,S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SafeFileWriter.posix(L10n.text("app.createTemporaryFile",defaultValue:"Create Temporary File")) }
        let file = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? file.close() }
        // Unlink while the handle owns the inode. Cancellation, app exit and a
        // failed decode free scratch blocks as soon as the descriptor closes.
        guard unlink(scratchPath) == 0 else { throw SafeFileWriter.posix(L10n.text("merge.robust.scratch",defaultValue:"Prepare Temporary Stack")) }
        for index in 0..<count {
            try Task.checkCancellation()
            let image = try await source(index)
            guard image.width == width,image.height == height else { throw MergeMasterCodec.invalid }
            try image.pixels.withUnsafeBytes { bytes in
                for start in stride(from:0,to:bytes.count,by:1_048_576) {
                    try Task.checkCancellation()
                    let size = min(1_048_576,bytes.count-start)
                    let chunk = Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:bytes.baseAddress!.advanced(by:start)),count:size,deallocator:.none)
                    try file.write(contentsOf:chunk)
                }
            }
        }
        let tile = tileSize(frameCount:count)
        var result = MergeImage(width:width,height:height)
        for start in stride(from:0,to:pixelCount,by:tile) {
            try Task.checkCancellation()
            let length = min(tile,pixelCount-start)
            let sources: [[SIMD4<Float>]] = try (0..<count).map { i in
                try Task.checkCancellation()
                try file.seek(toOffset:UInt64(i*frameBytes+start*bytesPerPixel))
                let needed = length*bytesPerPixel
                guard let bytes = try file.read(upToCount:needed),bytes.count == needed else { throw MergeMasterCodec.invalid }
                var samples = [SIMD4<Float>](repeating:.zero,count:length)
                samples.withUnsafeMutableBytes { _ = bytes.copyBytes(to:$0) }
                return samples
            }
            try combine(sources,into:&result.pixels,offset:start)
            await progress(start+length,pixelCount)
        }
        try Task.checkCancellation()
        return result
    }
}
