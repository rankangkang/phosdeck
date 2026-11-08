import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum MergeMasterCodec {
    static func context() -> CIContext {
        CIContext(options:[.workingColorSpace:MergeImage.space,.workingFormat:CIFormat.RGBAf,.cacheIntermediates:false])
    }
    /// The caller owns this unpublished file and publishes only after a successful readback.
    static func write(_ image: MergeImage,to url: URL,provenance: MergeProvenance,context: CIContext,stagingIdentity: FileIdentity? = nil) throws {
        try provenance.options.validate(count:provenance.sources.count)
        try Task.checkCancellation()
        // ImageIO's URL destination atomically replaces the file. A data consumer
        // keeps the O_EXCL staging inode owned by SafeFileWriter throughout.
        let flags = O_WRONLY | O_NOFOLLOW | (stagingIdentity == nil ? O_CREAT | O_EXCL : 0)
        let descriptor = Darwin.open(url.path,flags,S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SafeFileWriter.posix(L10n.text("app.openTemporaryFile", defaultValue:"Open Temporary File")) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size == 0 else { throw invalid }
        if let expected = stagingIdentity {
            guard info.st_dev == expected.device,info.st_ino == expected.inode,expected.size == 0 else { throw invalid }
        }
        let sink = TIFFSink(descriptor)
        let retained = Unmanaged.passRetained(sink)
        var callbacks = CGDataConsumerCallbacks(putBytes:{ pointer,bytes,count in
            let buffer = UnsafeRawBufferPointer(start:bytes,count:count)
            guard let pointer,let base = buffer.baseAddress else { return 0 }
            return Unmanaged<TIFFSink>.fromOpaque(pointer).takeUnretainedValue().write(base,count:count)
        },releaseConsumer:{ pointer in if let pointer { Unmanaged<TIFFSink>.fromOpaque(pointer).release() } })
        guard let consumer = CGDataConsumer(info:retained.toOpaque(),cbks:&callbacks) else { retained.release(); throw invalid }
        guard let bitmap = context.createCGImage(image.ciImage(),from:CGRect(x:0,y:0,width:image.width,height:image.height),format:.RGBAf,colorSpace:MergeImage.space,deferred:false),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer,UTType.tiff.identifier as CFString,1,nil) else { throw invalid }
        let properties: [String:Any] = [kCGImagePropertyOrientation as String:1,
            kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFImageDescription as String:try provenance.description,kCGImagePropertyTIFFSoftware as String:"Phosdeck"]]
        CGImageDestinationAddImage(destination,bitmap,properties as CFDictionary)
        let finalized = CGImageDestinationFinalize(destination)
        if let failure = sink.failure { throw NSError(domain:NSPOSIXErrorDomain,code:Int(failure)) }
        guard finalized else { throw invalid }
        guard fsync(descriptor) == 0 else { throw SafeFileWriter.posix(L10n.text("app.flushTemporaryFile", defaultValue:"Flush Temporary File")) }
        let back = try read(url,context:context)
        guard back.provenance == provenance,back.image.width == image.width,back.image.height == image.height else { throw invalid }
        // Compare every value, including out-of-range highlights and alpha. A sampled check
        // could miss a damaged tile or a precision/alpha regression in one small region.
        for i in image.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            for c in 0..<4 {
                let expected = image.pixels[i][c],actual = back.image.pixels[i][c]
                guard actual.isFinite,abs(expected-actual) <= max(2e-5,abs(expected)*2e-5) else { throw invalid }
            }
        }
    }
    static func read(_ url: URL,context: CIContext,honorCancellation: Bool = true) throws -> (image: MergeImage,provenance: MergeProvenance) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.tiff.identifier,CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],
              let provenance = try MergeProvenance.read(properties),
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { throw invalid }
        try PhotoGeometry.checkSize(CGSize(width:width,height:height))
        guard let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldAllowFloat:true] as CFDictionary),
              image.bitsPerComponent == 32,image.bitmapInfo.contains(.floatComponents),CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else { throw invalid }
        return (try MergeImage.read(CIImage(cgImage:image),context:context,honorCancellation:honorCancellation),provenance)
    }
    static var invalid: LRCError { LRCError(L10n.text("merge.invalidMaster", defaultValue:"The linear composite master is invalid")) }

    private final class TIFFSink {
        let descriptor: Int32
        var failure: Int32?
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        func write(_ bytes: UnsafeRawPointer,count: Int) -> Int {
            var offset = 0
            while offset < count {
                let written = Darwin.write(descriptor,bytes.advanced(by:offset),count-offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { failure = written < 0 ? errno : EIO; break }
                offset += written
            }
            return offset
        }
    }
}
