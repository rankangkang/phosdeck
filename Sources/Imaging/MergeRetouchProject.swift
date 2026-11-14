import Foundation
import CryptoKit
import simd

/// Current editable merge format. The payload travels inside the master; only
/// its bounded reference is stored in catalog metadata. No legacy conversion.
struct MergeRetouchProject: Codable, Equatable {
    static let algorithm = "phosdeck-merge-retouch-v2"
    static let maximumBytes = 16 * 1024 * 1024
    var version = algorithm
    var kind: PhotoMergeKind
    var sources: [MergeProvenance.Source]
    var decoders: [Decoder]
    var temperature: Double
    var tint: Double
    var snapshot: Snapshot
    var settings = MergeRetouchSettings()
    var width: Int { snapshot.size.0 }
    var height: Int { snapshot.size.1 }
    var sourceCount: Int { snapshot.sourceCount }

    struct Decoder: Codable, Equatable {
        var version: String
        var lensCorrection: Bool?
    }
    struct Reference: Codable, Equatable {
        var bytes: Int
        var sha256: String
        func validate() throws {
            guard (1...MergeRetouchProject.maximumBytes).contains(bytes),sha256.count == 64,
                  sha256.allSatisfy(\.isHexDigit) else { throw MergeRetouchProject.invalid }
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    func encoded() throws -> (Data,Reference) {
        try validate()
        let data = try JSONEncoder().encode(self)
        let ref = Reference(bytes:data.count,sha256:Self.digest(data))
        try ref.validate(); return (data,ref)
    }
    static func read(from url: URL,reference: Reference) throws -> Self {
        try reference.validate()
        let handle = try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > UInt64(reference.bytes) else { throw invalid }
        try handle.seek(toOffset:size-UInt64(reference.bytes))
        guard let data = try handle.read(upToCount:reference.bytes),data.count == reference.bytes,
              digest(data) == reference.sha256,
              let project = try? JSONDecoder().decode(Self.self,from:data) else { throw invalid }
        try project.validate(); return project
    }
    func validate() throws {
        let n = sources.count
        guard version == Self.algorithm,kind.supportsRetouch,(2...kind.sourceLimit).contains(n),decoders.count == n,
              Set(sources.map(\.photoID)).count == n,
              sources.allSatisfy({ !$0.photoID.isEmpty && $0.digest.count == 64 && $0.digest.allSatisfy(\.isHexDigit) }),
              decoders.allSatisfy({ !$0.version.isEmpty && $0.version.utf8.count <= 256 }),
              temperature.isFinite,(2000...50000).contains(temperature),tint.isFinite,(-150...150).contains(tint) else { throw Self.invalid }
        try snapshot.validate(kind:kind,count:n)
        try settings.validate(count:sourceCount,kind:kind)
    }
    init(plan: PhotoMergeEngine.Plan,requests: [ImageRequest],frames: [MergeFrame],whiteBalance: WhiteBalanceValue,kind: PhotoMergeKind) throws {
        self.kind = kind
        sources = requests.map { .init(photoID:$0.photo.id,digest:$0.recipe!.sourceDigest,recipeRevision:$0.photo.recipeRevision) }
        decoders = requests.indices.map { Decoder(version:requests[$0].recipe!.decoderVersion,lensCorrection:frames[$0].resolvedLensCorrection) }
        temperature = whiteBalance.temperature; tint = whiteBalance.tint
        switch plan {
        case .fusion(let p): snapshot = .fusion(Fusion(p))
        case .panorama(let p): snapshot = .panorama(Panorama(p))
        case .hdrPanorama(let groups,let p): snapshot = .hdrPanorama(groups.map(Fusion.init),Panorama(p))
        }
        try validate()
    }
    static func rows(_ matrix: MergeMatrix) -> [Double] {
        (0..<3).flatMap { row in (0..<3).map { column in matrix.m[column,row] } }
    }
    static func sizes(_ frames: [MergeFrame]) -> [[Int]] { frames.map { [$0.image.width,$0.image.height,$0.fullWidth,$0.fullHeight] } }
    static func validateSizes(_ sizes: [[Int]],count: Int) throws {
        guard sizes.count == count else { throw invalid }
        for s in sizes {
            guard s.count == 4,(1...1000).contains(s[0]),(1...1000).contains(s[1]),s[2] > 0,s[3] > 0 else { throw invalid }
            try PhotoGeometry.checkSize(CGSize(width:s[2],height:s[3]))
        }
    }
    static func validateMatrices(_ matrices: [[Double]],count: Int,affine: Bool) throws {
        guard matrices.count == count else { throw invalid }
        for m in matrices {
            guard m.count == 9,m.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }),
                  !affine || (m[6] == 0 && m[7] == 0 && m[8] == 1),
                  abs(MergeMatrix(m).m.determinant) > 1e-12 else { throw invalid }
        }
    }
    struct Depth: Codable,Equatable {
        var width: Int
        var height: Int
        var values: [Float]
    }
    struct Fusion: Codable,Equatable {
        var sizes: [[Int]]
        var reference: Int
        var order: [Int]
        var transforms: [[Double]]
        var gains: [[Float]]
        var ratios: [Float]
        var clips: [Float]
        var depth: Depth?
        init(_ p: MergeFusionPlan) {
            sizes = MergeRetouchProject.sizes(p.frames); reference = p.reference; order = p.order
            transforms = p.transforms.map(MergeRetouchProject.rows)
            gains = p.gains.map { [$0.x,$0.y,$0.z] }; ratios = p.exposureRatios; clips = p.frames.map(\.clip)
            depth = p.depth.map { Depth(width:$0.width,height:$0.height,values:$0.depth) }
        }
        func validate(kind: PhotoMergeKind,count: Int) throws {
            try MergeRetouchProject.validateSizes(sizes,count:count)
            try MergeRetouchProject.validateMatrices(transforms,count:count,affine:true)
            guard sizes.allSatisfy({ $0 == sizes[0] }),(0..<count).contains(reference),Set(order) == Set(0..<count),order.count == count,
                  gains.count == count,gains.allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100 }) }),
                  ratios.count == count,ratios.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1e8 }),
                  clips.count == count,clips.allSatisfy({ $0.isFinite && $0 > 0 }),
                  (kind == .focus) == (depth != nil) else { throw MergeRetouchProject.invalid }
            if let d = depth {
                guard (1...1000).contains(d.width),(1...1000).contains(d.height),d.values.count == d.width*d.height,
                      d.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Float(count-1) }) else { throw MergeRetouchProject.invalid }
            }
        }
        func restore(_ frames: [MergeFrame],options: PhotoMergeOptions) throws -> MergeFusionPlan {
            try validate(kind:options.kind,count:frames.count)
            guard MergeRetouchProject.sizes(frames) == sizes else { throw MergeRetouchProject.invalid }
            var frames = frames
            for i in frames.indices { frames[i].clip = clips[i] }
            let matrices = transforms.map(MergeMatrix.init)
            var ghosts = [MergePlane]()
            // Regenerate deterministic automatic ghost masks from frozen aligned
            // samples/ratios; never solve exposures or geometry again on reopen.
            if options.kind == .hdr,options.deghost > 0 {
                let aligned = try frames.indices.map { try MergeRegistration.warp(frames[$0].image,to:(sizes[0][0],sizes[0][1]),transform:matrices[$0]) }
                ghosts = try MergeFusionPlan.ghostMaps(aligned,clips:clips,floors:frames.map(\.exposureFloor),ratios:ratios,reference:reference,order:order,strength:options.deghost)
            }
            return MergeFusionPlan(options:options,frames:frames,reference:reference,order:order,transforms:matrices,
                gains:gains.map { SIMD3($0[0],$0[1],$0[2]) },exposureRatios:ratios,ghosts:ghosts,
                depth:depth.map { StackDepthMap(width:$0.width,height:$0.height,depth:$0.values,confident:.init(repeating:false,count:$0.values.count)) })
        }
    }
    struct Panorama: Codable,Equatable {
        var sizes: [[Int]]
        var reference: Int
        var cameras: [[Double]]
        var gains: [Float]
        var focal: Double
        var origin: [Double]
        var width: Int
        var height: Int
        init(_ p: MergePanoramaPlan) {
            sizes = MergeRetouchProject.sizes(p.frames); reference = p.reference; cameras = p.cameras.map(MergeRetouchProject.rows)
            gains = p.gains; focal = p.focal; origin = [p.origin.x,p.origin.y]; width = p.width; height = p.height
        }
        func validate(count: Int) throws {
            try MergeRetouchProject.validateSizes(sizes,count:count)
            try MergeRetouchProject.validateMatrices(cameras,count:count,affine:false)
            guard (0..<count).contains(reference),gains.count == count,gains.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 100 }),
                  focal.isFinite,focal > 0,focal <= 1e9,origin.count == 2,origin.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }),
                  width > 0,height > 0 else { throw MergeRetouchProject.invalid }
            try PhotoGeometry.checkSize(CGSize(width:width,height:height))
        }
        func restore(_ frames: [MergeFrame],options: PhotoMergeOptions) throws -> MergePanoramaPlan {
            try validate(count:frames.count)
            guard MergeRetouchProject.sizes(frames) == sizes else { throw MergeRetouchProject.invalid }
            return MergePanoramaPlan(options:options,frames:frames,reference:reference,cameras:cameras.map(MergeMatrix.init),gains:gains,
                focal:focal,origin:SIMD2(origin[0],origin[1]),width:width,height:height)
        }
    }
    enum Snapshot: Codable,Equatable {
        case fusion(Fusion)
        case panorama(Panorama)
        case hdrPanorama([Fusion],Panorama)
        var size: (Int,Int) {
            switch self {
            case .fusion(let f): return (f.sizes[f.reference][2],f.sizes[f.reference][3])
            case .panorama(let p),.hdrPanorama(_,let p): return (p.width,p.height)
            }
        }
        var sourceCount: Int {
            switch self { case .fusion(let f): f.sizes.count; case .panorama(let p),.hdrPanorama(_,let p): p.sizes.count }
        }
        func validate(kind: PhotoMergeKind,count: Int) throws {
            switch self {
            case .fusion(let f):
                guard [.focus,.hdr,.lighten].contains(kind) else { throw MergeRetouchProject.invalid }
                try f.validate(kind:kind,count:count)
            case .panorama(let p):
                guard kind == .panorama else { throw MergeRetouchProject.invalid }; try p.validate(count:count)
            case .hdrPanorama(let groups,let p):
                guard kind == .hdrPanorama,(2...64).contains(groups.count),groups.reduce(0,{ $0+$1.sizes.count }) == count,
                      groups.allSatisfy({ (2...9).contains($0.sizes.count) && $0.sizes.count == groups[0].sizes.count }) else { throw MergeRetouchProject.invalid }
                for group in groups { try group.validate(kind:.hdr,count:group.sizes.count) }
                try p.validate(count:groups.count)
            }
        }
    }
    static var invalid: LRCError { LRCError(L10n.text("merge.retouch.invalid",defaultValue:"The editable merge is invalid or uses an unavailable processing version.")) }
}
