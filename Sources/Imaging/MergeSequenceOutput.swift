import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MergeSequenceResult: Sendable {
    struct Frame: Sendable {
        let name: String
        let sourceIndex: Int
        let identity: FileIdentity
        let digest: String
    }
    let url: URL
    let frames: [Frame]
    let width: Int
    let height: Int
    let identity: FileIdentity

    static func write(_ image: MergeImage,to url: URL,sourceIndex: Int,context: CIContext) throws -> Frame {
        try autoreleasepool {
            try Task.checkCancellation()
            let bitmap = try ImagePipeline.materialize8(image.ciImage(),context:context)
            return try write(bitmap,to:url,sourceIndex:sourceIndex)
        }
    }

    private static func write(_ bitmap: CGImage,to url: URL,sourceIndex: Int) throws -> Frame {
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw invalid }
        CGImageDestinationAddImage(encoder,bitmap,nil)
        guard CGImageDestinationFinalize(encoder) else { throw invalid }
        try Task.checkCancellation()
        try SafeFileWriter.write(data as Data,to:url)
        let identity = try FileIdentity.read(url)
        let digest = try SafeFileWriter.sha256(url)
        let readback = try read(url)
        guard readback.width == bitmap.width,readback.height == bitmap.height,
              try FileIdentity.read(url) == identity else { throw invalid }
        return Frame(name:url.lastPathComponent,sourceIndex:sourceIndex,identity:identity,digest:digest)
    }

    static func crop(_ frame: Frame,at url: URL,to rect: CGRect) throws -> Frame {
        try autoreleasepool {
            try Task.checkCancellation()
            guard try FileIdentity.read(url) == frame.identity,try SafeFileWriter.sha256(url) == frame.digest else { throw invalid }
            guard let trimmed = try read(url).cropping(to:rect) else { throw invalid }
            // The directory is still private staging; remove only our original
            // file after the replacement has been written and verified.
            let replacement = url.deletingLastPathComponent().appendingPathComponent(".crop-"+frame.name)
            let written = try write(trimmed,to:replacement,sourceIndex:frame.sourceIndex)
            guard try FileIdentity.read(url) == frame.identity else { throw invalid }
            try FileManager.default.removeItem(at:url)
            try SafeFileWriter.publish(replacement,to:url)
            return Frame(name:frame.name,sourceIndex:frame.sourceIndex,identity:written.identity,digest:written.digest)
        }
    }

    private static func read(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else { throw invalid }
        return image
    }

    func verify() throws {
        guard try ProjectCopy.directoryIdentity(url).key == identity.key,
              Set(try FileManager.default.contentsOfDirectory(atPath:url.path)) == Set(frames.map(\.name)) else { throw Self.invalid }
        for frame in frames {
            try autoreleasepool {
                let file = url.appendingPathComponent(frame.name)
                guard try FileIdentity.read(file) == frame.identity,
                      try SafeFileWriter.sha256(file,honorCancellation:false) == frame.digest else { throw Self.invalid }
                let image = try Self.read(file)
                guard image.width == width,image.height == height,
                      try FileIdentity.read(file) == frame.identity else { throw Self.invalid }
            }
        }
        guard try ProjectCopy.directoryIdentity(url).key == identity.key else { throw Self.invalid }
    }

    static var invalid: LRCError {
        LRCError(L10n.text("merge.sequence.invalid",defaultValue:"The cumulative PNG sequence failed verification."))
    }
    static var invalidName: LRCError {
        LRCError(L10n.text("merge.sequence.invalidName",defaultValue:"Use a new sequence folder name without a path or a protected catalog location."))
    }
}

struct MergeSequencePublicationError: LocalizedError {
    let result: MergeSequenceResult
    let cause: Error
    var errorDescription: String? {
        L10n.text("merge.sequence.published",defaultValue:"The sequence folder was published at \(result.url.path). Verification could not finish: \(cause.localizedDescription)")
    }
}
