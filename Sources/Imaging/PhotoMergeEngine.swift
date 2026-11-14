import Foundation
import CoreImage
import ImageIO

struct MergePreview {
    let id: UUID
    let image: CGImage
    let width: Int
    let height: Int
}
struct MergeRetouchPreview {
    let source: CGImage
    let result: CGImage
    let width: Int
    let height: Int
    var overlay: CGImage? = nil
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
        let darkRequests: [ImageRequest]
        let darkMaster: MergeImage?
        let darkCalibration: MergeDarkCalibration?
        let options: PhotoMergeOptions
        let whiteBalance: WhiteBalanceValue
        let frames: [MergeFrame]
        let plan: Plan
        let preview: MergeImage
        var retouchProject: MergeRetouchProject?
    }
    private lazy var pipeline = ImagePipeline(cacheIntermediates:false)
    private lazy var context = MergeMasterCodec.context()
    private let checkpoint: @Sendable (String) throws -> Void
    private var prepared: Prepared?
    private var retouchBase: (excluded: Set<Int>,cometHalfLife: Int,image: MergeImage)?
    private var retouchResult: (settings: MergeRetouchSettings, image: MergeImage)?
    private var retouchSource: (index: Int,image: MergeImage)?
    private var retouchMasksCache: (strokes: [MergeRetouchStroke],masks: [MergeBrushMask])?
    private var sourceThumbnails: (offset: Int,count: Int,ev: Double,images: [Int:CGImage])?
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

    func prepare(_ inputs: [ImageRequest],options: PhotoMergeOptions,darkInputs: [ImageRequest] = [],project: MergeRetouchProject? = nil,progress: Progress) async throws -> MergePreview {
        prepared = nil; retouchBase = nil; retouchResult = nil; retouchSource = nil; retouchMasksCache = nil; sourceThumbnails = nil
        try project?.validate()
        guard project == nil || project?.kind == options.kind else { throw MergeRetouchProject.invalid }
        try options.validate(count:inputs.count)
        try Self.validateSources(inputs.map(\.photo))
        try MergeDarkCalibration.validate(lights:inputs.map(\.photo),darks:darkInputs.map(\.photo),kind:options.kind)
        guard project == nil || (project?.darkCalibration?.sources.count ?? 0) == darkInputs.count else { throw MergeDarkCalibration.invalid }
        if !darkInputs.isEmpty {
            try PhotoGeometry.checkSize(CGSize(width:inputs[0].photo.width,height:inputs[0].photo.height))
            let pixels = UInt64(inputs[0].photo.width)*UInt64(inputs[0].photo.height)
            guard pixels*128 <= ProcessInfo.processInfo.physicalMemory/3 else { throw Self.memoryBudget }
        }
        var darkRequests = [ImageRequest](),darkMaster: MergeImage?,darkCalibration: MergeDarkCalibration?
        let analysisCount = inputs.count + darkInputs.count
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
            if !darkInputs.isEmpty,input.photo.isRAW { recipe.rawDetails.lensCorrection = false }
            if index == 0,!darkInputs.isEmpty {
                let dark = try await prepareDarks(darkInputs,whiteBalance:whiteBalance,frozen:project?.darkCalibration) { completed in
                    await progress(Double(completed)/Double(analysisCount)*0.45,L10n.text("merge.dark.analyzing",defaultValue:"Averaging dark frames…"))
                }
                darkRequests = dark.requests; darkMaster = dark.image; darkCalibration = dark.calibration
            }
            let request = ImageRequest(photo:input.photo,root:input.root,recipe:recipe)
            var frame = try await decode(request,longEdge:options.kind == .lighten && !options.align ? 32 : 1000,whiteBalance:whiteBalance,dark:darkMaster)
            let scale = options.sourceLongEdge == 0 ? 1 : min(1,Double(options.sourceLongEdge)/Double(max(frame.fullWidth,frame.fullHeight)))
            frame.nativeWidth = max(1,Int((Double(frame.fullWidth)*scale).rounded()))
            frame.nativeHeight = max(1,Int((Double(frame.fullHeight)*scale).rounded()))
            frame.sourceIndex = index
            // A linear composite has no sensor clipping at 1. Its finite ceiling is
            // estimated only for HDR weights; stored samples are never clamped.
            if input.photo.details?.composite != nil { frame.clip = max(1,frame.image.pixels.map(MergeImage.peak).max() ?? 1) }
            frames.append(frame); requests.append(request)
            await progress(Double(index+1+darkInputs.count)/Double(analysisCount)*0.45,L10n.text("merge.analyzing", defaultValue:"Analyzing originals…"))
        }
        let plan: Plan = try project.map { try restorePlan($0.snapshot,frames:frames,options:options) } ?? makePlan(frames,options:options)
        await progress(0.65,L10n.text("merge.previewing", defaultValue:"Building merge preview…"))
        let preview: MergeImage
        if options.kind == .lighten,!options.align,case .fusion(let fusionPlan) = plan {
            // The tiny retained analyses bound long-sequence memory. Decode
            // preview pixels separately, retaining only one source at a time.
            var accumulator: MergeFusionAccumulator?
            for (index,request) in requests.enumerated() {
                try Task.checkCancellation()
                let image = try await decode(request,longEdge:1000,whiteBalance:whiteBalance,dark:darkMaster).image
                if accumulator == nil {
                    accumulator = try MergeFusionAccumulator(plan:fusionPlan,width:image.width,height:image.height)
                }
                try accumulator!.add(image,index:index)
                await progress(0.65+Double(index+1)/Double(requests.count)*0.3,L10n.text("merge.previewing", defaultValue:"Building merge preview…"))
            }
            let result = try accumulator!.finish()
            preview = options.autoCrop ? try MergeCrop.crop(result) : result
        } else { preview = try smallResult(plan,frames:frames) }
        var retouchProject = project
        if retouchProject == nil, options.kind.supportsRetouch {
            retouchProject = try MergeRetouchProject(plan:plan,requests:requests,frames:frames,whiteBalance:whiteBalance,kind:options.kind,darkCalibration:darkCalibration)
        }
        let value = Prepared(id:UUID(),requests:requests,darkRequests:darkRequests,darkMaster:darkMaster,darkCalibration:darkCalibration,options:options,whiteBalance:whiteBalance,frames:frames,plan:plan,preview:preview,retouchProject:retouchProject)
        try Task.checkCancellation()
        prepared = value
        return try display(value,ev:0)
    }
    private func prepareDarks(_ inputs: [ImageRequest],whiteBalance: WhiteBalanceValue,frozen: MergeDarkCalibration?,progress: (Int) async -> Void) async throws
        -> (requests: [ImageRequest],image: MergeImage,calibration: MergeDarkCalibration) {
        var requests = [ImageRequest](),mean: MergeImage?,decoders = [MergeRetouchProject.Decoder]()
        for (index,input) in inputs.enumerated() {
            try Task.checkCancellation()
            var recipe: EditRecipe
            if let saved = input.recipe { recipe = saved } else { recipe = try await pipeline.baseline(input) }
            if let frozen {
                guard frozen.sources.count == inputs.count,frozen.sources[index].photoID == input.photo.id,
                      frozen.sources[index].digest == recipe.sourceDigest else { throw Self.sourceChanged }
                recipe.decoderVersion = frozen.decoders[index].version
            }
            if input.photo.isRAW { recipe.rawDetails.lensCorrection = false }
            let request = ImageRequest(photo:input.photo,root:input.root,recipe:recipe)
            let frame = try await pipeline.mergeDecode(request,longEdge:nil,whiteBalance:whiteBalance)
            try MergeDarkCalibration.accumulate(frame.image,into:&mean,count:index+1)
            requests.append(request)
            decoders.append(.init(version:recipe.decoderVersion,lensCorrection:frame.resolvedLensCorrection))
            await progress(index+1)
        }
        guard let mean else { throw MergeDarkCalibration.invalid }
        let calibration = MergeDarkCalibration(sources:requests.map {
            .init(photoID:$0.photo.id,digest:$0.recipe!.sourceDigest,recipeRevision:$0.photo.recipeRevision)
        },decoders:decoders,width:mean.width,height:mean.height)
        if let frozen {
            guard frozen.width == mean.width,frozen.height == mean.height,frozen.decoders == decoders else { throw MergeDarkCalibration.invalid }
            return (requests,mean,frozen)
        }
        return (requests,mean,calibration)
    }
    private func decode(_ request: ImageRequest,longEdge: Int?,whiteBalance: WhiteBalanceValue,dark: MergeImage?) async throws -> MergeFrame {
        var frame = try await pipeline.mergeDecode(request,longEdge:dark == nil ? longEdge : nil,whiteBalance:whiteBalance)
        if let dark {
            try MergeDarkCalibration.subtract(dark,from:&frame.image)
            if let longEdge { frame.image = try frame.image.resized(longEdge:longEdge) }
        }
        return frame
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

    static func validSequenceName(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
            name.utf8.count <= 240 && !name.contains("/") && !name.contains(":") &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    func exportStarSequence(_ id: UUID,settings: MergeRetouchSettings,to bookmark: Data,folderName: String,
                            catalog: CatalogStore,progress: Progress) async throws -> MergeSequenceResult {
        guard let value = prepared,value.id == id,value.options.kind == .lighten,case .fusion(let plan) = value.plan else { throw stale }
        guard Self.validSequenceName(folderName) else { throw MergeSequenceResult.invalidName }
        try settings.validate(count:value.requests.count,kind:.lighten)
        let requests = value.requests + value.darkRequests
        try catalog.validateMergeInputs(requests)
        let lease = try AccessLease(bookmark:bookmark)
        defer { withExtendedLifetime(lease) {} }
        let directory = lease.url.resolvingSymlinksInPath().standardizedFileURL
        let destination = directory.appendingPathComponent(folderName,isDirectory:true)
        guard !ProjectCopy.contains(catalog.directory,destination),
              !(try catalog.protectedPaths()).contains(where:{ ProjectCopy.contains(destination,URL(fileURLWithPath:$0)) }) else {
            throw MergeSequenceResult.invalidName
        }
        let included = value.requests.indices.filter { !settings.excludedSources.contains($0) }
        guard let lastSource = included.last else { throw MergeSequenceResult.invalid }
        let pixels = UInt64(plan.width)*UInt64(plan.height)
        // Accumulator, snapshot, corrected/cropped output, PNG buffers, source
        // decoding and any resident retouch caches can coexist during writing.
        guard pixels*320+UInt64(value.darkMaster?.pixels.count ?? 0)*96 <= ProcessInfo.processInfo.physicalMemory/3 else {
            throw Self.memoryBudget
        }
        try SafeFileWriter.requireCapacity(in:directory,bytes:Int64(pixels*5+65_536)*Int64(included.count))
        let folder = try ProjectCopy(destination:destination)
        defer { folder.discard() }

        let fusion = try MergeFusionAccumulator(plan:plan,width:plan.width,height:plan.height,trails:settings.trails)
        let masks = try await retouchMasks(settings,value:value)
        let local = masks.isEmpty ? nil : try MergeConstrainedRegion(width:plan.width,height:plan.height,settings:settings,masks:masks,kind:.lighten)
        let edge: Int? = value.options.sourceLongEdge == 0 ? nil : value.options.sourceLongEdge
        var entries = [MergeSequenceResult.Frame]()
        func writeFrame(_ image: MergeImage,sourceIndex: Int) throws {
            let name = String(format:"frame-%04d.png",entries.count+1)
            let file = folder.staging.appendingPathComponent(name)
            entries.append(try MergeSequenceResult.write(image,to:file,sourceIndex:sourceIndex,context:context))
        }
        func currentFrame() throws -> MergeImage {
            let merged = try StarTrailFusion.fillGaps(fusion.finish(),settings:settings.trails)
            return try local?.finish(over:merged) ?? merged
        }
        // A fixed crop is derived from final coverage, including explicit brush
        // restores and holes. Prior frames are cropped once after the pass.
        for index in value.requests.indices {
            try Task.checkCancellation()
            let isLight = !settings.excludedSources.contains(index)
            guard isLight || (local != nil && StarTrailFusion.participates(index,settings:settings)) else { continue }
            if isLight {
                await progress(Double(entries.count)/Double(included.count)*0.8,
                    L10n.text("merge.sequence.progress",defaultValue:"Building cumulative frame \(entries.count+1) of \(included.count)…"))
            }
            let source = try await decode(value.requests[index],longEdge:edge,whiteBalance:value.whiteBalance,dark:value.darkMaster).image
            if isLight { try fusion.add(source,index:index) }
            if let local {
                let sample = try await sourcePixels(index,value:value,region:local.region,decoded:source)
                try local.add(sample.image,weights:sample.mask,index:index)
            }
            if isLight,index != lastSource { try writeFrame(currentFrame(),sourceIndex:index) }
        }
        var last = try currentFrame()
        if value.options.autoCrop {
            let cropRect = try MergeCrop.rectangle(last)
            last = try MergeCrop.extract(last,rect:cropRect)
            if last.width != plan.width || last.height != plan.height {
                for i in entries.indices {
                    let file = folder.staging.appendingPathComponent(entries[i].name)
                    entries[i] = try MergeSequenceResult.crop(entries[i],at:file,to:cropRect)
                }
            }
        }
        try writeFrame(last,sourceIndex:lastSource)
        guard entries.count == included.count,entries.map(\.sourceIndex) == included else { throw MergeSequenceResult.invalid }
        await progress(0.9,L10n.text("merge.sequence.verifying",defaultValue:"Verifying the PNG sequence…"))
        try verifySequenceInputs(value,catalog:catalog)
        try checkpoint("sequence-staged")
        guard prepared?.id == id else { throw stale }
        try Task.checkCancellation()

        let stagedResult = MergeSequenceResult(url:destination,frames:entries,width:last.width,height:last.height,
                                               identity:try ProjectCopy.directoryIdentity(folder.staging))
        var published = false
        do {
            try folder.publish { published = true }
            try checkpoint("sequence-published")
            try stagedResult.verify()
        } catch {
            if published { throw MergeSequencePublicationError(result:stagedResult,cause:error) }
            throw error
        }
        return stagedResult
    }

    private func verifySequenceInputs(_ value: Prepared,catalog: CatalogStore) throws {
        let requests = value.requests + value.darkRequests
        for request in requests { try pipeline.verifySource(request) }
        try catalog.validateMergeInputs(requests)
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
        try catalog.validateMergeInputs(value.requests+value.darkRequests)
        let maxSource = value.frames.map { UInt64($0.fullWidth)*UInt64($0.fullHeight) }.max() ?? 0
        let canvas = UInt64(value.plan.size.0)*UInt64(value.plan.size.1)
        let consensusBytes = value.options.kind.isPanorama ? MergePyramid.consensusBytesPerPixel : 0
        guard maxSource*64+canvas*UInt64(160+consensusBytes)+UInt64(value.darkMaster?.pixels.count ?? 0)*96 <= ProcessInfo.processInfo.physicalMemory/3 else {
            throw Self.memoryBudget
        }
        let encodedProject = try value.retouchProject?.encoded()
        try SafeFileWriter.requireCapacity(in:directory,bytes:Int64(canvas)*16+Int64(encodedProject?.0.count ?? 0)+1_048_576)
        let image = try await fullResult(value,progress:progress)
        await progress(0.86,L10n.text("merge.writing", defaultValue:"Writing and verifying float master…"))
        let provenance = MergeProvenance(options:options,sources:value.retouchProject?.sources ?? value.requests.map {
            MergeProvenance.Source(photoID:$0.photo.id,digest:$0.recipe!.sourceDigest,recipeRevision:$0.photo.recipeRevision)
        },darkCalibration:value.darkCalibration,retouchProject:encodedProject?.1)
        let staging = try SafeFileWriter.stage(in:directory)
        let stagingIdentity = try FileIdentity.read(staging),stagingKey = stagingIdentity.key
        var ownsStaging = true
        defer { if ownsStaging,(try? FileIdentity.read(staging).key) == stagingKey { try? FileManager.default.removeItem(at:staging) } }
        try MergeMasterCodec.write(image,to:staging,provenance:provenance,context:context,stagingIdentity:stagingIdentity,retouchProject:encodedProject?.0)
        try checkpoint("staged")
        guard try FileIdentity.read(staging).key == stagingKey else { throw MergeMasterCodec.invalid }
        for request in value.requests+value.darkRequests { try pipeline.verifySource(request) }
        try catalog.validateMergeInputs(value.requests+value.darkRequests)
        let identity = try FileIdentity.read(staging),digest = try SafeFileWriter.sha256(staging)
        var recipe = EditRecipe(sourceDigest:digest,decoderVersion:EditRecipe.linearCompositeDecoderVersion,
            baselineExposure:0,baselineTemperature:5500,baselineTint:0,temperature:5500,tint:0)
        recipe.grain.ensureSeed()
        let metadata = PhotoMetadata(orientation:1,profile:"sRGB IEC61966-2.1 Linear",composite:provenance.catalogSummary)
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
            registered = try catalog.registerMergedPhoto(photo,root:root,inputs:value.requests,calibrationInputs:value.darkRequests,stackWithSources:stackWithSources,collectionID:collectionID)
        } catch {
            throw MergePublicationError(url: destination, identity: identity, verified: verified, cause: error)
        }
        prepared = nil; retouchBase = nil; retouchResult = nil; retouchSource = nil; retouchMasksCache = nil; sourceThumbnails = nil
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
        if retouch,prepared?.id == value.id,let project = value.retouchProject,
           let cached = retouchResult,cached.settings == project.settings {
            return try finished(cached.image,options:value.options)
        }
        let edge: Int? = value.options.sourceLongEdge == 0 ? nil : value.options.sourceLongEdge
        func decode(_ index: Int) async throws -> MergeImage {
            try Task.checkCancellation()
            await progress(Double(index)/Double(value.requests.count)*0.8,L10n.text("merge.fusing", defaultValue:"Merging full-size originals…"))
            return try await self.decode(value.requests[index],longEdge:edge,whiteBalance:value.whiteBalance,dark:value.darkMaster).image
        }
        switch value.plan {
        case .fusion(let plan):
            let trails = value.retouchProject?.settings.trails ?? StarTrailSettings()
            let fusion = try MergeFusionAccumulator(plan:plan,width:plan.width,height:plan.height,trails:trails)
            for index in value.requests.indices where value.options.kind != .lighten || value.retouchProject?.settings.excludedSources.contains(index) != true {
                try fusion.add(try await decode(index),index:index)
            }
            var image = try fusion.finish()
            if retouch, let project = value.retouchProject {
                image = try await corrected(image,settings:project.settings,value:value)
            }
            return retouch ? try finished(image,options:value.options) : image
        case .panorama(let plan):
            let fusion = MergePanoramaAccumulator(plan)
            for index in value.requests.indices { try fusion.add(try await decode(index),index:index) }
            var image = try fusion.finish(applyFinishing:false)
            if retouch,let project = value.retouchProject { image = try await corrected(image,settings:project.settings,value:value) }
            return retouch ? try finished(image,options:value.options) : image
        case .hdrPanorama(let groups,let plan):
            let panorama = MergePanoramaAccumulator(plan)
            var offset = 0
            for (number,group) in groups.enumerated() {
                let fusion = try MergeFusionAccumulator(plan:group,width:group.width,height:group.height)
                for index in group.frames.indices { try fusion.add(try await decode(offset+index),index:index) }
                try panorama.add(try fusion.finish(),index:number); offset += group.frames.count
            }
            var image = try panorama.finish(applyFinishing:false)
            if retouch,let project = value.retouchProject { image = try await corrected(image,settings:project.settings,value:value) }
            return retouch ? try finished(image,options:value.options) : image
        }
    }
    private func finished(_ image: MergeImage,options: PhotoMergeOptions) throws -> MergeImage {
        if options.kind.isPanorama { return try MergePanoramaFinish.apply(image,options:options) }
        return options.autoCrop ? try MergeCrop.crop(image) : image
    }
    private func restorePlan(_ snapshot: MergeRetouchProject.Snapshot,frames: [MergeFrame],options: PhotoMergeOptions) throws -> Plan {
        switch snapshot {
        case .fusion(let f): return .fusion(try f.restore(frames,options:options))
        case .panorama(let p): return .panorama(try p.restore(frames,options:options))
        case .hdrPanorama(let frozen,let panorama):
            var groups = [MergeFusionPlan](),hdrFrames = [MergeFrame]()
            var hdrOptions = options; hdrOptions.kind = .hdr; hdrOptions.autoCrop = false
            guard frozen.count*options.bracketSize == frames.count else { throw MergeRetouchProject.invalid }
            for (number,snapshot) in frozen.enumerated() {
                let start = number*options.bracketSize
                let group = try snapshot.restore(Array(frames[start..<start+options.bracketSize]),options:hdrOptions)
                let merged = try fuseSmall(group),reference = group.frames[group.reference]
                groups.append(group)
                hdrFrames.append(MergeFrame(image:merged,clip:max(1,merged.pixels.map(MergeImage.peak).max() ?? 1),sourceIndex:number,
                    focal35mm:reference.focal35mm,nativeWidth:reference.fullWidth,nativeHeight:reference.fullHeight,
                    registrationImage:reference.image,focalLength:reference.focalLength,cameraModel:reference.cameraModel))
            }
            return .hdrPanorama(groups,try panorama.restore(hdrFrames,options:options))
        }
    }
    func reopenMerge(_ photo: Photo,catalog: CatalogStore,progress: Progress) async throws -> (inputs: [ImageRequest],darkInputs: [ImageRequest],options: PhotoMergeOptions,project: MergeRetouchProject,preview: MergePreview) {
        guard let summary = photo.details?.composite, let reference = summary.retouchProject,
              summary.options.kind.supportsRetouch else { throw MergeRetouchProject.invalid }
        guard let master = try loadInputs(catalog:catalog,ids:[photo.id]).first else { throw Self.sourceChanged }
        let lease = try AccessLease(bookmark:master.root.bookmark)
        let url = lease.url.appendingPathComponent(master.photo.relativePath)
        try pipeline.verifySource(master)
        defer { withExtendedLifetime(lease) {} }
        guard let provenance = try PhotoFileType.inspectSource(url).composite,
              provenance.retouchProject == reference,provenance.options == summary.options,
              provenance.sources.count == summary.sourceCount else { throw MergeRetouchProject.invalid }
        let project = try MergeRetouchProject.read(from:url,reference:reference)
        guard project.sources == provenance.sources,project.darkCalibration == provenance.darkCalibration else { throw MergeRetouchProject.invalid }
        let loaded = try loadInputs(catalog:catalog,ids:Set((project.sources+(project.darkCalibration?.sources ?? [])).map(\.photoID)))
        let byID = Dictionary(uniqueKeysWithValues:loaded.map { ($0.photo.id,$0) })
        let inputs = try project.sources.map { source -> ImageRequest in
            guard let input = byID[source.photoID] else { throw Self.sourceChanged }
            return input
        }
        let darkInputs = try (project.darkCalibration?.sources ?? []).map { source -> ImageRequest in
            guard let input = byID[source.photoID] else { throw Self.sourceChanged }
            return input
        }
        let preview = try await prepare(inputs,options:provenance.options,darkInputs:darkInputs,project:project,progress:progress)
        return (inputs,darkInputs,provenance.options,project,preview)
    }

    func setRetouchSettings(_ id: UUID,settings: MergeRetouchSettings) throws {
        guard var value = prepared,value.id == id,var project = value.retouchProject else { throw stale }
        project.settings = settings; try project.validate()
        value.retouchProject = project; prepared = value
    }
    private func sourcePixels(_ index: Int,value: Prepared,region: CGRect? = nil,decoded: MergeImage? = nil) async throws -> (image: MergeImage,mask: MergePlane) {
        guard let project = value.retouchProject,(0..<project.sourceCount).contains(index) else { throw stale }
        let edge = value.options.sourceLongEdge == 0 ? nil : value.options.sourceLongEdge
        func decode(_ i: Int) async throws -> MergeImage {
            try await self.decode(value.requests[i],longEdge:edge,whiteBalance:value.whiteBalance,dark:value.darkMaster).image
        }
        switch value.plan {
        case .fusion(let plan):
            let frame: MergeImage
            if let decoded { frame = decoded } else { frame = try await decode(index) }
            var image = try MergeFusionAccumulator.aligned(frame,index:index,plan:plan,width:plan.width,height:plan.height,region:region)
            let gain: SIMD3<Float> = value.options.kind == .hdr ? SIMD3(repeating:1/plan.exposureRatios[index]) : plan.gains[index]
            for i in image.pixels.indices {
                if i.isMultiple(of:65536) { try Task.checkCancellation() }
                let p = image.pixels[i]; image.pixels[i] = SIMD4(p.x*gain.x,p.y*gain.y,p.z*gain.z,p.w)
            }
            return (image,MergePlane(width:image.width,height:image.height,values:image.pixels.map(\.w)))
        case .panorama(let plan):
            return try MergePanoramaAccumulator.projected(try await decode(index),index:index,plan:plan,region:region)
        case .hdrPanorama(let groups,let plan):
            let group = groups[index],fusion = try MergeFusionAccumulator(plan:group,width:group.width,height:group.height)
            let offset = groups.prefix(index).reduce(0,{ $0+$1.frames.count })
            for i in group.frames.indices { try fusion.add(try await decode(offset+i),index:i) }
            return try MergePanoramaAccumulator.projected(fusion.finish(),index:index,plan:plan,region:region)
        }
    }
    private func alignedRetouchSource(_ index: Int,value: Prepared) async throws -> MergeImage {
        if prepared?.id == value.id,let cached = retouchSource,cached.index == index { return cached.image }
        let image = try await sourcePixels(index,value:value).image
        try Task.checkCancellation()
        guard prepared?.id == value.id else { throw stale }
        retouchSource = (index,image); return image
    }
    private func corrected(_ base: MergeImage,settings: MergeRetouchSettings,value: Prepared) async throws -> MergeImage {
        if value.options.kind == .focus || value.options.kind == .hdr {
            var result = base
            for stroke in settings.strokes {
                try Task.checkCancellation()
                let source = stroke.restore ? base : try await alignedRetouchSource(stroke.source,value:value)
                try stroke.apply(to:&result,from:source)
            }
            return result
        }
        let initial = value.options.kind == .lighten ? try StarTrailFusion.fillGaps(base,settings:settings.trails) : base
        guard !settings.strokes.isEmpty,let project = value.retouchProject else { return initial }
        let masks = try await retouchMasks(settings,value:value,base:base)
        let local = try MergeConstrainedRegion(width:initial.width,height:initial.height,settings:settings,masks:masks,kind:value.options.kind)
        for i in 0..<project.sourceCount {
            try Task.checkCancellation()
            if !StarTrailFusion.participates(i,settings:settings) { continue }
            let pixels = try await sourcePixels(i,value:value,region:local.region)
            try local.add(pixels.image,weights:pixels.mask,index:i)
        }
        return try local.finish(over:initial)
    }
    private func retouchMasks(_ settings: MergeRetouchSettings,value: Prepared,base: MergeImage? = nil) async throws -> [MergeBrushMask] {
        if let cached = retouchMasksCache,cached.strokes == settings.strokes { return cached.masks }
        let (width,height) = value.plan.size
        var masks = [MergeBrushMask](),maskBytes = 0
        for stroke in settings.strokes {
            var mask = try stroke.mask(width:width,height:height)
            if !stroke.restore && !stroke.exclude {
                let pixels = try await sourcePixels(stroke.source,value:value,region:mask.rect).image
                for y in 0..<mask.height { for x in 0..<mask.width {
                    let p = y*mask.width+x,s = pixels.pixels[p].w
                    if let base,value.options.kind == .focus || value.options.kind == .hdr {
                        let a = base.pixels[(y+mask.y)*width+x+mask.x].w
                        mask.values[p] *= a > 0 ? min(1,max(0,s/a)) : 0
                    } else { mask.values[p] *= s > 0 ? 1 : 0 }
                } }
            }
            maskBytes += mask.values.count*4
            guard maskBytes <= min(256*1024*1024,Int(ProcessInfo.processInfo.physicalMemory/12)) else {
                throw LRCError(L10n.text("merge.memoryBudget",defaultValue:"The full-size merge exceeds the memory budget. Choose a smaller source size"))
            }
            masks.append(mask)
        }
        try Task.checkCancellation(); guard prepared?.id == value.id else { throw stale }
        retouchMasksCache = (settings.strokes,masks); return masks
    }

    func retouchSettings(_ id: UUID) throws -> MergeRetouchSettings {
        guard let value = prepared,value.id == id,let project = value.retouchProject else { throw stale }
        return project.settings
    }

    /// Paged thumbnails are bounded to twelve. Point coverage is estimated from
    /// frozen geometry and retained analysis alpha; the full-resolution overlay
    /// uses decoded source alpha. Neither describes automatic fusion weights.
    func retouchSources(_ id: UUID,offset: Int,count: Int,point: MaskPoint? = nil,ev: Double = 0,thumbnails: Bool = true) async throws -> MergeSourcePage {
        guard let value = prepared,value.id == id,let project = value.retouchProject,
              (0...project.sourceCount).contains(offset),(1...12).contains(count),point?.valid != false,
              ev.isFinite,(-5...5).contains(ev) else { throw stale }
        let width = value.plan.size.0,height = value.plan.size.1
        var items = [MergeSourcePreview]()
        var thumbnailsByIndex = sourceThumbnails.flatMap { $0.offset == offset && $0.count == count && $0.ev == ev ? $0.images : nil } ?? [:]
        for index in offset..<min(project.sourceCount,offset+count) {
            try Task.checkCancellation()
            let frame: MergeFrame,members: [Int],gain: SIMD3<Float>
            let q: SIMD2<Double>?
            let x = point.map { min(width-1,Int($0.x*Double(width))) } ?? 0
            let y = point.map { min(height-1,Int($0.y*Double(height))) } ?? 0
            switch value.plan {
            case .fusion(let p):
                frame = p.frames[index]; members = [index]
                gain = value.options.kind == .hdr ? SIMD3(repeating:1/p.exposureRatios[index]) : p.gains[index]
                let reference = p.frames[p.reference].image
                let small = p.transforms[index].point(Double(x)*Double(reference.width)/Double(width),Double(y)*Double(reference.height)/Double(height))
                q = small.map { SIMD2($0.x*Double(frame.fullWidth)/Double(frame.image.width),$0.y*Double(frame.fullHeight)/Double(frame.image.height)) }
            case .panorama(let p):
                frame = p.frames[index]; members = [index]; gain = SIMD3(repeating:p.gains[index])
                q = p.sourcePoint(x,y,index:index).map { SIMD2(($0.x+0.5)*Double(frame.fullWidth)/Double(frame.image.width)-0.5,($0.y+0.5)*Double(frame.fullHeight)/Double(frame.image.height)-0.5) }
            case .hdrPanorama(let groups,let p):
                frame = p.frames[index]; gain = SIMD3(repeating:p.gains[index])
                let start = groups.prefix(index).reduce(0,{ $0+$1.frames.count })
                members = Array(start..<start+groups[index].frames.count)
                q = p.sourcePoint(x,y,index:index).map { SIMD2(($0.x+0.5)*Double(frame.fullWidth)/Double(frame.image.width)-0.5,($0.y+0.5)*Double(frame.fullHeight)/Double(frame.image.height)-0.5) }
            }
            let coverage: Float?
            if point == nil { coverage = nil }
            else if let q,q.x >= 0,q.y >= 0,q.x <= Double(frame.fullWidth-1),q.y <= Double(frame.fullHeight-1) {
                let sx = min(Double(frame.image.width-1),max(0,(q.x+0.5)*Double(frame.image.width)/Double(frame.fullWidth)-0.5))
                let sy = min(Double(frame.image.height-1),max(0,(q.y+0.5)*Double(frame.image.height)/Double(frame.fullHeight)-0.5))
                coverage = frame.image.sample(sx,sy)?.w ?? 0
            } else { coverage = 0 }
            var thumbnail: CGImage? = thumbnails ? thumbnailsByIndex[index] : nil
            if thumbnails,thumbnail == nil {
                var small: MergeImage
                if value.options.kind == .lighten,!value.options.align {
                    small = try await decode(value.requests[index],longEdge:160,whiteBalance:value.whiteBalance,dark:value.darkMaster).image
                } else { small = try frame.image.resized(longEdge:160) }
                for p in small.pixels.indices { small.pixels[p] *= SIMD4(gain.x,gain.y,gain.z,1) }
                let ci = small.ciImage().applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:ev])
                thumbnail = context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                thumbnailsByIndex[index] = thumbnail
            }
            items.append(MergeSourcePreview(index:index,name:value.requests[members[0]].photo.name,
                         memberIDs:members.map { value.requests[$0].photo.id },coverage:coverage,thumbnail:thumbnail))
        }
        try Task.checkCancellation(); guard prepared?.id == id else { throw stale }
        if thumbnails { sourceThumbnails = (offset,count,ev,thumbnailsByIndex) }
        return MergeSourcePage(total:project.sourceCount,width:width,height:height,items:items)
    }

    func retouchPreview(_ id: UUID,settings: MergeRetouchSettings,source: Int,ev: Double,overlay: MergeRetouchOverlay = .none,updateSettings: Bool = true,progress: Progress) async throws -> MergeRetouchPreview {
        if updateSettings { try setRetouchSettings(id,settings:settings); try checkpoint("retouch-settings") }
        guard var value = prepared,value.id == id,let project = value.retouchProject,
              (0..<project.sourceCount).contains(source),ev.isFinite,(-5...5).contains(ev) else { throw stale }
        try settings.validate(count:project.sourceCount,kind:value.options.kind)
        value.retouchProject?.settings = settings
        let pixels = UInt64(value.plan.size.0)*UInt64(value.plan.size.1)
        guard pixels*256+UInt64(value.darkMaster?.pixels.count ?? 0)*96 <= ProcessInfo.processInfo.physicalMemory/3 else {
            throw Self.memoryBudget
        }
        let base: MergeImage
        if let cached = retouchBase,cached.excluded == settings.excludedSources,cached.cometHalfLife == settings.trails.cometHalfLife {
            base = cached.image
        }
        else {
            base = try await fullResult(value,retouch:false,progress:progress)
            try Task.checkCancellation(); guard prepared?.id == id else { throw stale }
            retouchBase = (settings.excludedSources,settings.trails.cometHalfLife,base)
        }
        let result: MergeImage
        if let cached = retouchResult,cached.settings == settings { result = cached.image }
        else {
            if [.focus,.hdr].contains(value.options.kind),let cached = retouchResult,
               settings.strokes.count == cached.settings.strokes.count+1,
               settings.strokes.dropLast().elementsEqual(cached.settings.strokes),let last = settings.strokes.last {
                var incremental = cached.image
                let image = last.restore ? base : try await alignedRetouchSource(last.source,value:value)
                try last.apply(to:&incremental,from:image); result = incremental
            } else { result = try await corrected(base,settings:settings,value:value) }
            try Task.checkCancellation(); guard prepared?.id == id else { throw stale }
            retouchResult = (settings,result)
        }
        let selected = try await alignedRetouchSource(source,value:value)
        func display(_ image: MergeImage) throws -> CGImage {
            let ci = image.ciImage().applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:ev])
            guard let output = context.createCGImage(ci,from:ci.extent,format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!) else { throw MergeMasterCodec.invalid }
            return output
        }
        let masks = overlay == .constraints ? try await retouchMasks(settings,value:value,base:base) : []
        let mask = try MergeRetouchOverlayMask.image(source:selected,settings:settings,masks:masks,index:source,kind:value.options.kind,mode:overlay)
        let pair = try MergeRetouchPreview(source:display(selected),result:display(result),width:base.width,height:base.height,overlay:mask)
        try Task.checkCancellation(); guard prepared?.id == id else { throw stale }
        return pair
    }

    static var memoryBudget: LRCError { LRCError(L10n.text("merge.memoryBudget",defaultValue:"The full-size merge exceeds the memory budget. Choose a smaller source size")) }
    static var sourceChanged: LRCError { LRCError(L10n.text("merge.sourceChanged", defaultValue:"A source changed during the merge. Reopen the merge window")) }
    private var stale: LRCError { LRCError(L10n.text("merge.previewStale", defaultValue:"Settings changed. Build a new preview before saving")) }
}
