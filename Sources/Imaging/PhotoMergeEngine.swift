import Foundation
import CoreImage
import ImageIO

struct MergePreview {
    let id: UUID
    let image: CGImage
    let width: Int
    let height: Int
}
struct FocusRetouchPreview {
    let source: CGImage
    let result: CGImage
    let width: Int
    let height: Int
}
struct MergeSaved {
    let photo: Photo
    let url: URL
    let previousStacks: [PhotoStack]?
}

struct MergePublicationError: LocalizedError {
    let url: URL
    let identity: FileIdentity
    let verified: Bool
    let cause: Error

    var errorDescription: String? {
        L10n.text("merge.savedButNotIndexed", defaultValue:"The master was preserved at \(url.path). Catalog registration or final verification failed: \(cause.localizedDescription)")
    }
}

/// Serialized, separate from interactive previews. Analysis is bounded to 1000 px;
/// full-size fusion reads one source (or one HDR bracket) at a time.
actor PhotoMergeEngine {
    typealias Progress = @Sendable (Double,String) async -> Void
    enum Plan {
        case fusion(MergeFusionPlan)
        case panorama(MergePanoramaPlan)
        case hdrPanorama([MergeFusionPlan],MergePanoramaPlan)
        var size: (Int,Int) {
            switch self {
            case .fusion(let p): return (p.width,p.height)
            case .panorama(let p),.hdrPanorama(_,let p): return (p.width,p.height)
            }
        }
    }
    struct Prepared {
        let id: UUID
        let requests: [ImageRequest]
        let options: PhotoMergeOptions
        let whiteBalance: WhiteBalanceValue
        let frames: [MergeFrame]
        let plan: Plan
        let preview: MergeImage
        var focusProject: FocusMergeProject?
    }
    private lazy var pipeline = ImagePipeline(cacheIntermediates:false)
    private lazy var context = MergeMasterCodec.context()
    private let checkpoint: @Sendable (String) throws -> Void
    private var prepared: Prepared?
    private var focusBase: MergeImage?
    private var focusResult: (strokes: [FocusRetouchStroke], image: MergeImage)?
    private var focusSource: (index: Int,image: MergeImage)?
    init(checkpoint: @escaping @Sendable (String) throws -> Void = { _ in }) { self.checkpoint = checkpoint }

    func loadInputs(catalog: CatalogStore,ids: Set<String>) throws -> [ImageRequest] {
        let photos = try catalog.photos(ids:ids).sorted {
            ($0.captureDate ?? "",$0.relativePath,$0.id) < ($1.captureDate ?? "",$1.relativePath,$1.id)
        }
        guard photos.count == ids.count else { throw Self.sourceChanged }
        let roots = Dictionary(uniqueKeysWithValues:try catalog.roots().map { ($0.id,$0) })
        return try photos.map { photo in
            try Task.checkCancellation()
            guard let root = roots[photo.rootID] else { throw Self.sourceChanged }
            let recipe = try photo.recipe.map { try JSONDecoder().decode(EditRecipe.self,from:$0) }
            try recipe?.validate(for:photo)
            return ImageRequest(photo:photo,root:root,recipe:recipe)
        }
    }

    func prepare(_ inputs: [ImageRequest],options: PhotoMergeOptions,project: FocusMergeProject? = nil,progress: Progress) async throws -> MergePreview {
        prepared = nil; focusBase = nil; focusResult = nil; focusSource = nil
        try project?.validate()
        try options.validate(count:inputs.count)
        try Self.validateSources(inputs.map(\.photo))
        var requests = [ImageRequest](),frames = [MergeFrame]()
        var whiteBalance = WhiteBalanceValue(temperature:5500,tint:0)
        for (index,input) in inputs.enumerated() {
            try Task.checkCancellation()
            var recipe: EditRecipe
            if let saved = input.recipe { recipe = saved }
            else { recipe = try await pipeline.baseline(input) }
            if let project {
                guard project.sources.count == inputs.count, project.sources[index].photoID == input.photo.id,
                      project.sources[index].digest == recipe.sourceDigest else { throw Self.sourceChanged }
                recipe.decoderVersion = project.decoders[index].version
                recipe.rawDetails.lensCorrection = project.decoders[index].lensCorrection
            }
            if index == 0 { whiteBalance = WhiteBalanceValue(temperature:recipe.temperature,tint:recipe.tint) }
            if let project { whiteBalance = WhiteBalanceValue(temperature:project.temperature,tint:project.tint) }
            let request = ImageRequest(photo:input.photo,root:input.root,recipe:recipe)
            var frame = try await pipeline.mergeDecode(request,longEdge:1000,whiteBalance:whiteBalance)
            let scale = options.sourceLongEdge == 0 ? 1 : min(1,Double(options.sourceLongEdge)/Double(max(frame.fullWidth,frame.fullHeight)))
            frame.nativeWidth = max(1,Int((Double(frame.fullWidth)*scale).rounded()))
            frame.nativeHeight = max(1,Int((Double(frame.fullHeight)*scale).rounded()))
            frame.sourceIndex = index
            // A linear composite has no sensor clipping at 1. Its finite ceiling is
            // estimated only for HDR weights; stored samples are never clamped.
            if input.photo.details?.composite != nil { frame.clip = max(1,frame.image.pixels.map(MergeImage.peak).max() ?? 1) }
            frames.append(frame); requests.append(request)
            await progress(Double(index+1)/Double(inputs.count)*0.45,L10n.text("merge.analyzing", defaultValue:"Analyzing originals…"))
        }
        let plan: Plan = try project.map { .fusion(try $0.plan(frames:frames,options:options)) } ?? makePlan(frames,options:options)
        await progress(0.65,L10n.text("merge.previewing", defaultValue:"Building merge preview…"))
        let preview = try smallResult(plan,frames:frames)
        var focusProject = project
        if focusProject == nil, options.kind == .focus, case .fusion(let fusion) = plan {
            focusProject = try FocusMergeProject(plan:fusion,requests:requests,whiteBalance:whiteBalance)
        }
        let value = Prepared(id:UUID(),requests:requests,options:options,whiteBalance:whiteBalance,frames:frames,plan:plan,preview:preview,focusProject:focusProject)
        try Task.checkCancellation()
        prepared = value
        return try display(value,ev:0)
    }
    static func validateSources(_ photos: [Photo]) throws {
        guard let first = photos.first, Set(photos.map(\.sourceKey)).count == photos.count,
              Set(photos.map(\.identityKey)).count == photos.count,
              photos.allSatisfy({ $0.supportsEditing && $0.isRAW == first.isRAW }) else {
            throw LRCError(L10n.text("merge.distinctSources", defaultValue:"Choose distinct originals, using either all RAW or all JPEG/TIFF/PNG sources"))
        }
    }

    func display(_ id: UUID,ev: Double,longEdge: Int = 1400) throws -> MergePreview {
        guard let value = prepared,value.id == id else { throw stale }
        return try display(value,ev:ev,longEdge:longEdge)
    }
    private func display(_ value: Prepared,ev: Double,longEdge: Int = 1400) throws -> MergePreview {
        try Task.checkCancellation()
        guard ev.isFinite,(-5...5).contains(ev),(1...1400).contains(longEdge) else { throw stale }
        let small = try value.preview.resized(longEdge:longEdge)
        let ci = small.ciImage().applyingFilter("CIExposureAdjust",parameters:["inputEV":ev])
        guard let image = context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:ImagePipeline.outputSpace) else { throw MergeMasterCodec.invalid }
        return MergePreview(id:value.id,image:image,width:value.plan.size.0,height:value.plan.size.1)
    }
    static func validFilename(_ filename: String, format: MergeMasterFormat) -> Bool {
        filename == URL(fileURLWithPath:filename).lastPathComponent && !filename.hasPrefix(".") &&
        !filename.contains(":") && filename.rangeOfCharacter(from:.controlCharacters) == nil &&
        (format == .tiff ? ["tif","tiff"] : ["dng"]).contains(URL(fileURLWithPath:filename).pathExtension.lowercased()) && filename.utf8.count <= 240
    }

    func save(_ id: UUID,to directoryBookmark: Data,filename: String,catalog: CatalogStore,stackWithSources: Bool = false,collectionID: String? = nil,
              masterFormat: MergeMasterFormat? = nil,progress: Progress) async throws -> MergeSaved {
        guard let value = prepared,value.id == id else { throw stale }
        var options = value.options
        if let masterFormat { options.masterFormat = masterFormat }
        guard Self.validFilename(filename, format: options.masterFormat) else {
            throw LRCError(L10n.text("merge.invalidFilename", defaultValue:"Enter a filename matching the master format, without folder separators"))
        }
        let lease = try AccessLease(bookmark:directoryBookmark)
        defer { withExtendedLifetime(lease) {} }
        let directory = lease.url.resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(filename)
        guard !FileManager.default.fileExists(atPath:destination.path),try !catalog.protectedPaths().contains(destination.path) else { throw LRCError(L10n.text("merge.destinationExists", defaultValue:"The destination already exists. Choose another filename")) }
        let root = try catalog.mergeDestinationRoot(directory:directory,bookmark:directoryBookmark)
        try catalog.validateMergeInputs(value.requests)
        let maxSource = value.frames.map { UInt64($0.fullWidth)*UInt64($0.fullHeight) }.max() ?? 0
        let canvas = UInt64(value.plan.size.0)*UInt64(value.plan.size.1)
        let consensusBytes = value.options.kind.isPanorama ? MergePyramid.consensusBytesPerPixel : 0
        guard maxSource*64+canvas*UInt64(160+consensusBytes) <= ProcessInfo.processInfo.physicalMemory/3 else {
            throw LRCError(L10n.text("merge.memoryBudget", defaultValue:"The full-size merge exceeds the memory budget. Choose a smaller source size"))
        }
        let encodedProject = try value.focusProject?.encoded()
        try SafeFileWriter.requireCapacity(in:directory,bytes:Int64(canvas)*16+Int64(encodedProject?.0.count ?? 0)+1_048_576)
        let image = try await fullResult(value,progress:progress)
        await progress(0.86,L10n.text("merge.writing", defaultValue:"Writing and verifying float master…"))
        let provenance = MergeProvenance(options:options,sources:value.focusProject?.sources ?? value.requests.map {
            MergeProvenance.Source(photoID:$0.photo.id,digest:$0.recipe!.sourceDigest,recipeRevision:$0.photo.recipeRevision)
        },focusProject:encodedProject?.1)
        let staging = try SafeFileWriter.stage(in:directory)
        let stagingIdentity = try FileIdentity.read(staging),stagingKey = stagingIdentity.key
        var ownsStaging = true
        defer { if ownsStaging,(try? FileIdentity.read(staging).key) == stagingKey { try? FileManager.default.removeItem(at:staging) } }
        try MergeMasterCodec.write(image,to:staging,provenance:provenance,context:context,stagingIdentity:stagingIdentity,focusProject:encodedProject?.0)
        try checkpoint("staged")
        guard try FileIdentity.read(staging).key == stagingKey else { throw MergeMasterCodec.invalid }
        for request in value.requests { try pipeline.verifySource(request) }
        try catalog.validateMergeInputs(value.requests)
        let identity = try FileIdentity.read(staging),digest = try SafeFileWriter.sha256(staging)
        var recipe = EditRecipe(sourceDigest:digest,decoderVersion:EditRecipe.linearCompositeDecoderVersion,
            baselineExposure:0,baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
        recipe.grain.ensureSeed()
        let metadata = PhotoMetadata(orientation:1,profile:"sRGB IEC61966-2.1 Linear",composite:provenance)
        let photoID = UUID().uuidString
        let photo = Photo(id:photoID,rootID:root.id,relativePath:String(destination.path.dropFirst(root.path.count+1)),
            identity:try JSONEncoder().encode(identity),identityKey:identity.key,digest:digest,captureDate:value.requests.first?.photo.captureDate,
            width:image.width,height:image.height,recipe:try JSONEncoder().encode(recipe),recipeRevision:1,metadata:try JSONEncoder().encode(metadata))
        try Task.checkCancellation()
        try SafeFileWriter.publish(staging,to:destination)
        ownsStaging = false
        // Publication is the commit point. Cancellation after it must not strand an
        // unreported file or delete a master that another process could already see.
        let registered: (photo: Photo,previousStacks: [PhotoStack]?)
        var verified = false
        do {
            try checkpoint("published")
            guard try FileIdentity.read(destination) == identity else { throw MergeMasterCodec.invalid }
            let readback = try MergeMasterCodec.read(destination,context:context,honorCancellation:false)
            guard readback.provenance == provenance,readback.image.width == image.width,readback.image.height == image.height else { throw MergeMasterCodec.invalid }
            verified = true
            registered = try catalog.registerMergedPhoto(photo,root:root,inputs:value.requests,stackWithSources:stackWithSources,collectionID:collectionID)
        } catch {
            throw MergePublicationError(url: destination, identity: identity, verified: verified, cause: error)
        }
        prepared = nil; focusBase = nil; focusResult = nil; focusSource = nil
        return MergeSaved(photo:registered.photo,url:destination,previousStacks:registered.previousStacks)
    }
    private func makePlan(_ frames: [MergeFrame],options: PhotoMergeOptions) throws -> Plan {
        switch options.kind {
        case .panorama: return .panorama(try MergePanoramaPlan.prepare(frames,options:options))
        case .hdrPanorama:
            var groups = [MergeFusionPlan](),hdrFrames = [MergeFrame]()
            var hdrOptions = options; hdrOptions.kind = .hdr; hdrOptions.autoCrop = false
            for start in stride(from:0,to:frames.count,by:options.bracketSize) {
                let group = try MergeFusionPlan.prepare(Array(frames[start..<start+options.bracketSize]),options:hdrOptions)
                let merged = try fuseSmall(group)
                let reference = group.frames[group.reference]
                groups.append(group)
                hdrFrames.append(MergeFrame(image:merged,clip:max(1,merged.pixels.map(MergeImage.peak).max() ?? 1),sourceIndex:groups.count-1,focal35mm:reference.focal35mm,nativeWidth:reference.fullWidth,nativeHeight:reference.fullHeight,registrationImage:reference.image,focalLength:reference.focalLength,cameraModel:reference.cameraModel))
            }
            return .hdrPanorama(groups,try MergePanoramaPlan.prepare(hdrFrames,options:options))
        default: return .fusion(try MergeFusionPlan.prepare(frames,options:options))
        }
    }
    private func fuseSmall(_ plan: MergeFusionPlan) throws -> MergeImage {
        let image = plan.frames[plan.reference].image
        let fusion = try MergeFusionAccumulator(plan:plan,width:image.width,height:image.height)
        for i in plan.frames.indices { try fusion.add(plan.frames[i].image,index:i) }
        return try fusion.finish()
    }
    private func smallResult(_ plan: Plan,frames: [MergeFrame]) throws -> MergeImage {
        switch plan {
        case .fusion(let p):
            let result = try fuseSmall(p)
            return p.options.autoCrop && p.options.kind != .focus ? try MergeCrop.crop(result) : result
        case .panorama(let p),.hdrPanorama(_,let p):
            // Reuse registrations at analysis scale. There is no second feature solve.
            let scale = min(1,1400.0/Double(max(p.width,p.height)))
            let small = MergePanoramaPlan(options:p.options,frames:p.frames,reference:p.reference,cameras:p.cameras,gains:p.gains,
                focal:p.focal*scale,origin:p.origin*scale,width:max(1,Int(Double(p.width)*scale)),height:max(1,Int(Double(p.height)*scale)))
            let fusion = MergePanoramaAccumulator(small)
            for i in p.frames.indices { try fusion.add(p.frames[i].image,index:i) }
            return try fusion.finish()
        }
    }
    private func fullResult(_ value: Prepared,retouch: Bool = true,progress: Progress) async throws -> MergeImage {
        if retouch,prepared?.id == value.id,let project = value.focusProject,
           let cached = focusResult,cached.strokes == project.strokes {
            return value.options.autoCrop ? try MergeCrop.crop(cached.image) : cached.image
        }
        let edge: Int? = value.options.sourceLongEdge == 0 ? nil : value.options.sourceLongEdge
        func decode(_ index: Int) async throws -> MergeImage {
            try Task.checkCancellation()
            await progress(Double(index)/Double(value.requests.count)*0.8,L10n.text("merge.fusing", defaultValue:"Merging full-size originals…"))
            return try await pipeline.mergeDecode(value.requests[index],longEdge:edge,whiteBalance:value.whiteBalance).image
        }
        switch value.plan {
        case .fusion(let plan):
            let fusion = try MergeFusionAccumulator(plan:plan,width:plan.width,height:plan.height)
            for index in value.requests.indices { try fusion.add(try await decode(index),index:index) }
            var image = try fusion.finish()
            if retouch, let project = value.focusProject {
                image = try await corrected(image,strokes:project.strokes,value:value)
            }
            return retouch && value.options.autoCrop ? try MergeCrop.crop(image) : image
        case .panorama(let plan):
            let fusion = MergePanoramaAccumulator(plan)
            for index in value.requests.indices { try fusion.add(try await decode(index),index:index) }
            return try fusion.finish()
        case .hdrPanorama(let groups,let plan):
            let panorama = MergePanoramaAccumulator(plan)
            var offset = 0
            for (number,group) in groups.enumerated() {
                let fusion = try MergeFusionAccumulator(plan:group,width:group.width,height:group.height)
                for index in group.frames.indices { try fusion.add(try await decode(offset+index),index:index) }
                try panorama.add(try fusion.finish(),index:number); offset += group.frames.count
            }
            return try panorama.finish()
        }
    }
    func reopenFocus(_ photo: Photo,catalog: CatalogStore,progress: Progress) async throws -> (inputs: [ImageRequest],options: PhotoMergeOptions,project: FocusMergeProject,preview: MergePreview) {
        guard let provenance = photo.details?.composite, let reference = provenance.focusProject,
              provenance.options.kind == .focus else { throw FocusMergeProject.invalid }
        guard let master = try loadInputs(catalog:catalog,ids:[photo.id]).first else { throw Self.sourceChanged }
        let lease = try AccessLease(bookmark:master.root.bookmark)
        let url = lease.url.appendingPathComponent(master.photo.relativePath)
        try pipeline.verifySource(master)
        defer { withExtendedLifetime(lease) {} }
        let project = try FocusMergeProject.read(from:url,reference:reference)
        guard project.sources == provenance.sources else { throw FocusMergeProject.invalid }
        let loaded = try loadInputs(catalog:catalog,ids:Set(project.sources.map(\.photoID)))
        let byID = Dictionary(uniqueKeysWithValues:loaded.map { ($0.photo.id,$0) })
        let inputs = try project.sources.map { source -> ImageRequest in
            guard let input = byID[source.photoID] else { throw Self.sourceChanged }
            return input
        }
        let preview = try await prepare(inputs,options:provenance.options,project:project,progress:progress)
        return (inputs,provenance.options,project,preview)
    }

    func setFocusStrokes(_ id: UUID,strokes: [FocusRetouchStroke]) throws {
        guard var value = prepared, value.id == id, var project = value.focusProject else { throw stale }
        project.strokes = strokes
        try project.validate()
        value.focusProject = project; prepared = value
    }

    private func alignedFocusSource(_ index: Int,value: Prepared) async throws -> MergeImage {
        guard case .fusion(let plan) = value.plan, value.options.kind == .focus,
              value.requests.indices.contains(index) else { throw stale }
        if prepared?.id == value.id, let cached = focusSource, cached.index == index { return cached.image }
        let edge = value.options.sourceLongEdge == 0 ? nil : value.options.sourceLongEdge
        let frame = try await pipeline.mergeDecode(value.requests[index],longEdge:edge,whiteBalance:value.whiteBalance).image
        var image = try MergeFusionAccumulator.aligned(frame,index:index,plan:plan,width:plan.width,height:plan.height)
        let gain = plan.gains[index]
        for i in image.pixels.indices {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            let p = image.pixels[i]; image.pixels[i] = SIMD4(p.x*gain.x,p.y*gain.y,p.z*gain.z,p.w)
        }
        guard prepared?.id == value.id else { throw stale }
        focusSource = (index,image)
        return image
    }

    private func corrected(_ base: MergeImage,strokes: [FocusRetouchStroke],value: Prepared) async throws -> MergeImage {
        var result = base
        for stroke in strokes {
            try Task.checkCancellation()
            let source = stroke.restore ? base : try await alignedFocusSource(stroke.source,value:value)
            try stroke.apply(to:&result,from:source)
        }
        return result
    }

    func focusPreview(_ id: UUID,strokes: [FocusRetouchStroke],source: Int,ev: Double,progress: Progress) async throws -> FocusRetouchPreview {
        guard let value = prepared,value.id == id,value.focusProject != nil,
              ev.isFinite,(-5...5).contains(ev) else { throw stale }
        try setFocusStrokes(id,strokes:strokes)
        let pixels = UInt64(value.plan.size.0)*UInt64(value.plan.size.1)
        guard pixels*256 <= ProcessInfo.processInfo.physicalMemory/3 else {
            throw LRCError(L10n.text("merge.memoryBudget",defaultValue:"The full-size merge exceeds the memory budget. Choose a smaller source size"))
        }
        let base: MergeImage
        if let cached = focusBase { base = cached }
        else {
            base = try await fullResult(value,retouch:false,progress:progress)
            try Task.checkCancellation()
            guard prepared?.id == id else { throw stale }
            focusBase = base
        }
        let result: MergeImage
        if let cached = focusResult, cached.strokes == strokes { result = cached.image }
        else {
            if let cached = focusResult, strokes.count == cached.strokes.count+1,
               strokes.dropLast().elementsEqual(cached.strokes),let last = strokes.last {
                var incremental = cached.image
                let image = last.restore ? base : try await alignedFocusSource(last.source,value:value)
                try last.apply(to:&incremental,from:image)
                result = incremental
            } else {
                result = try await corrected(base,strokes:strokes,value:value)
            }
            try Task.checkCancellation()
            guard prepared?.id == id else { throw stale }
            focusResult = (strokes,result)
        }
        let selected = try await alignedFocusSource(source,value:value)
        func display(_ image: MergeImage) throws -> CGImage {
            let ci = image.ciImage().applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:ev])
            guard let output = context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else { throw MergeMasterCodec.invalid }
            return output
        }
        let pair = try FocusRetouchPreview(source:display(selected),result:display(result),width:base.width,height:base.height)
        try Task.checkCancellation()
        guard prepared?.id == id else { throw stale }
        return pair
    }

    static var sourceChanged: LRCError { LRCError(L10n.text("merge.sourceChanged", defaultValue:"A source changed during the merge. Reopen the merge window")) }
    private var stale: LRCError { LRCError(L10n.text("merge.previewStale", defaultValue:"Settings changed. Build a new preview before saving")) }
}
