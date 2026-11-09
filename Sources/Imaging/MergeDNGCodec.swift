// Native DNG 1.4 float32 writer/reader. Tag layout and linear-RGB colour metadata reference
// LightCraft 2f4d095 (2026-11-09), merge/src/output.rs and raw/src/dngwrite.rs, MIT.
// Adobe DNG 1.7.1: LinearRaw, IEEE float samples, and a separate transparency-mask SubIFD.
// Keep signed source samples exact; WhiteLevel/BaselineExposure describe highlight headroom.
import Foundation

enum MergeDNGCodec {
    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let bytes: Data
        static func shorts(_ tag: UInt16,_ values: [UInt16]) -> Self { Self(tag:tag,type:3,count:values.count,bytes:packed(values)) }
        static func longs(_ tag: UInt16,_ values: [UInt32]) -> Self { Self(tag:tag,type:4,count:values.count,bytes:packed(values)) }
        static func bytes(_ tag: UInt16,_ values: [UInt8]) -> Self { Self(tag:tag,type:1,count:values.count,bytes:Data(values)) }
        static func text(_ tag: UInt16,_ value: String) -> Self { let data = Data(value.utf8)+Data([0]);return Self(tag:tag,type:2,count:data.count,bytes:data) }
        static func rationals(_ tag: UInt16,_ values: [Double],signed: Bool = false) -> Self {
            let denominator: Double = 1_000_000
            let words = values.flatMap { value -> [UInt32] in
                let numerator = (value*denominator).rounded()
                return [signed ? UInt32(bitPattern:Int32(numerator)) : UInt32(numerator),UInt32(denominator)]
            }
            return Self(tag:tag,type:signed ? 10 : 5,count:values.count,bytes:packed(words))
        }
    }
    private static let colorMatrix = [3.2404542,-1.5371385,-0.4985314,-0.9692660,1.8760108,0.0415560,0.0556434,-0.2040259,1.0572252]
    private static let forwardMatrix = [0.4360747,0.3850649,0.1430804,0.2225045,0.7168786,0.0606169,0.0139322,0.0971045,0.7141733]
    private static let model = "Phosdeck Linear sRGB"
    private static func packed<T: FixedWidthInteger>(_ values: [T]) -> Data {
        values.map(\.littleEndian).withUnsafeBytes { Data($0) }
    }
    private static func base(width: Int,height: Int,channels: Int,offset: Int,mask: Bool) -> [Entry] {
        [.longs(254,[mask ? 4 : 0]),.longs(256,[UInt32(width)]),.longs(257,[UInt32(height)]),
         .shorts(258,.init(repeating:32,count:channels)),.shorts(259,[1]),.shorts(262,[mask ? 4 : 34892]),
         .longs(273,[UInt32(offset)]),.shorts(274,[1]),.shorts(277,[UInt16(channels)]),
         .longs(278,[UInt32(height)]),.longs(279,[UInt32(width*height*channels*4)]),.shorts(284,[1]),
         .shorts(339,.init(repeating:3,count:channels))]
    }
    private static func directory(_ entries: [Entry],at offset: Int,into data: inout Data) {
        let sorted = entries.sorted { $0.tag < $1.tag }
        data.replaceSubrange(offset..<offset+2,with:packed([UInt16(sorted.count)]))
        for (index,entry) in sorted.enumerated() {
            let position = offset+2+index*12
            var record = packed([entry.tag,entry.type])+packed([UInt32(entry.count)])
            if entry.bytes.count <= 4 { record += entry.bytes+Data(repeating:0,count:4-entry.bytes.count) }
            else {
                while !data.count.isMultiple(of:4) { data.append(0) }
                record += packed([UInt32(data.count)]);data.append(entry.bytes)
            }
            data.replaceSubrange(position..<position+12,with:record)
        }
    }
    static func write(_ image: MergeImage,provenance: MergeProvenance,write: (Data) throws -> Void) throws {
        try PhotoGeometry.checkSize(CGSize(width:image.width,height:image.height))
        var peak: Float = 1,hasMask = false
        for (i,pixel) in image.pixels.enumerated() {
            if i.isMultiple(of:65536) { try Task.checkCancellation() }
            guard (0..<4).allSatisfy({ pixel[$0].isFinite }),(0...1).contains(pixel.w) else { throw MergeMasterCodec.invalid }
            peak = max(peak,MergeImage.peak(pixel));hasMask = hasMask || pixel.w < 1
        }
        // A rational WhiteLevel must fit TIFF's 32-bit numerator. Store a whole-number
        // ceiling, so there is no sample scaling, rounding, clipping or half-float conversion.
        let white = Double(peak).rounded(.up)
        guard white <= Double(UInt32.max),UInt64(image.width)*UInt64(image.height)*16+1_048_576 <= UInt64(UInt32.max) else { throw MergeMasterCodec.invalid }
        var root = base(width:image.width,height:image.height,channels:3,offset:0,mask:false)
        root += [.text(270,try provenance.description),.text(271,"Phosdeck"),.text(272,model),.text(305,"Phosdeck"),
                 .bytes(50706,[1,4,0,0]),.bytes(50707,[1,4,0,0]),.text(50708,model),
                 .shorts(50713,[1,1]),.rationals(50714,[0,0,0]),
                 .longs(50717,[UInt32(white),UInt32(white),UInt32(white)]),
                 .longs(50719,[0,0]),.longs(50720,[UInt32(image.width),UInt32(image.height)]),
                 .rationals(50721,colorMatrix,signed:true),.rationals(50728,[1,1,1]),
                 .rationals(50730,[log2(white)],signed:true),.rationals(50732,[0]),.shorts(50778,[21]),
                 .longs(50829,[0,0,UInt32(image.height),UInt32(image.width)]),
                 .text(50936,model),.rationals(50964,forwardMatrix,signed:true),.shorts(51110,[1])]
        if hasMask { root.append(.longs(330,[0])) }
        let maskOffset = 8+2+root.count*12+4
        let mask = hasMask ? base(width:image.width,height:image.height,channels:1,offset:0,mask:true) : []
        var header = Data(repeating:0,count:maskOffset+(hasMask ? 2+mask.count*12+4 : 0))
        header.replaceSubrange(0..<8,with:Data([0x49,0x49,42,0])+packed([UInt32(8)]))
        if hasMask { root[root.firstIndex(where:{ $0.tag == 330 })!] = .longs(330,[UInt32(maskOffset)]) }
        directory(root,at:8,into:&header)
        if hasMask { directory(mask,at:maskOffset,into:&header) }
        while !header.count.isMultiple(of:4) { header.append(0) }
        let rgbOffset = header.count,maskPixels = rgbOffset+image.width*image.height*12
        let total = UInt64(maskPixels)+UInt64(hasMask ? image.width*image.height*4 : 0)
        guard total <= UInt64(UInt32.max) else { throw MergeMasterCodec.invalid }
        // Only replace the inline strip offsets; metadata payload offsets stay stable.
        func setStrip(_ entries: [Entry],_ ifd: Int,_ value: Int) {
            let index = entries.sorted { $0.tag < $1.tag }.firstIndex { $0.tag == 273 }!
            let position = ifd+2+index*12+8
            header.replaceSubrange(position..<position+4,with:packed([UInt32(value)]))
        }
        setStrip(root,8,rgbOffset)
        if hasMask { setStrip(mask,maskOffset,maskPixels) }
        try write(header)
        var row = [UInt32](repeating:0,count:image.width*3)
        for y in 0..<image.height {
            if y.isMultiple(of:32) { try Task.checkCancellation() }
            for x in 0..<image.width { for c in 0..<3 { row[x*3+c] = image.pixels[y*image.width+x][c].bitPattern } }
            try write(packed(row))
        }
        if hasMask {
            row = .init(repeating:0,count:image.width)
            for y in 0..<image.height {
                if y.isMultiple(of:32) { try Task.checkCancellation() }
                for x in 0..<image.width { row[x] = image.pixels[y*image.width+x].w.bitPattern }
                try write(packed(row))
            }
        }
    }

    struct File {
        let width: Int
        let height: Int
        let provenance: MergeProvenance
        private let data: Data
        private let rgb: Int
        private let mask: Int?
        fileprivate init(width: Int,height: Int,provenance: MergeProvenance,data: Data,rgb: Int,mask: Int?) {
            self.width = width;self.height = height;self.provenance = provenance;self.data = data;self.rgb = rgb;self.mask = mask
        }
        func image(honorCancellation: Bool = true) throws -> MergeImage {
            var image = MergeImage(width:width,height:height)
            try data.withUnsafeBytes { bytes in
                func sample(_ offset: Int) -> Float { Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self))) }
                for i in image.pixels.indices {
                    if honorCancellation && i.isMultiple(of:65536) { try Task.checkCancellation() }
                    let p = SIMD4(sample(rgb+i*12),sample(rgb+i*12+4),sample(rgb+i*12+8),mask.map { sample($0+i*4) } ?? 1)
                    guard (0..<4).allSatisfy({ p[$0].isFinite }),(0...1).contains(p.w) else { throw MergeMasterCodec.invalid }
                    image.pixels[i] = p.w == 0 ? .zero : p
                }
            }
            return image
        }
    }
    /// Recognise only our current masters. Camera DNGs continue through the existing RAW decoder.
    static func open(_ url: URL) throws -> File? {
        let data = try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count >= 8,data.prefix(4) == Data([0x49,0x49,42,0]) else { return nil }
        let reader = Reader(data:data)
        let rootOffset = try reader.number(4,4),probe = try reader.directory(rootOffset,probe:true)
        guard probe[50706] != nil,let description = probe[270],description.type == 2,description.bytes.count <= 65536,
              let text = String(data:description.bytes.dropLast(),encoding:.utf8),text.hasPrefix(MergeProvenance.marker) else { return nil }
        let root = try reader.directory(rootOffset)
        guard let provenance = try MergeProvenance.decode(text),provenance.options.masterFormat == .dng,
              root[50706]?.bytes == Data([1,4,0,0]),root[50707]?.bytes == Data([1,4,0,0]),
              root[50721]?.bytes == Entry.rationals(50721,colorMatrix,signed:true).bytes,
              root[50964]?.bytes == Entry.rationals(50964,forwardMatrix,signed:true).bytes else { throw MergeMasterCodec.invalid }
        for entry in [Entry.text(50708,model),.rationals(50714,[0,0,0]),.rationals(50728,[1,1,1]),.shorts(50778,[21])] {
            guard root[Int(entry.tag)]?.type == Int(entry.type),root[Int(entry.tag)]?.bytes == entry.bytes else { throw MergeMasterCodec.invalid }
        }
        let width = try reader.scalar(root,256,type:4),height = try reader.scalar(root,257,type:4)
        try PhotoGeometry.checkSize(CGSize(width:width,height:height))
        func pixels(_ fields: [Int:Field],channels: Int,isMask: Bool) throws -> Int {
            for entry in base(width:width,height:height,channels:channels,offset:0,mask:isMask) where entry.tag != 273 {
                guard let field = fields[Int(entry.tag)],field.type == Int(entry.type),field.bytes == entry.bytes else { throw MergeMasterCodec.invalid }
            }
            let offset = try reader.scalar(fields,273,type:4),length = width*height*channels*4
            guard offset >= reader.headerEnd,offset <= data.count,length <= data.count-offset else { throw MergeMasterCodec.invalid }
            return offset
        }
        let rgb = try pixels(root,channels:3,isMask:false)
        var mask: Int?
        if root[330] != nil {
            let offset = try reader.scalar(root,330,type:4)
            guard offset != rootOffset else { throw MergeMasterCodec.invalid }
            let fields = try reader.directory(offset)
            mask = try pixels(fields,channels:1,isMask:true)
            guard mask! >= rgb+width*height*12 else { throw MergeMasterCodec.invalid }
        }
        guard rgb >= reader.headerEnd,(mask.map { $0+width*height*4 } ?? rgb+width*height*12) == data.count else { throw MergeMasterCodec.invalid }
        return File(width:width,height:height,provenance:provenance,data:data,rgb:rgb,mask:mask)
    }
    private struct Field { let type: Int;let bytes: Data }
    private final class Reader {
        let data: Data
        var headerEnd = 8
        init(data: Data) { self.data = data }
        func number(_ offset: Int,_ size: Int) throws -> Int {
            guard offset >= 0,offset <= data.count,size <= data.count-offset else { throw MergeMasterCodec.invalid }
            return (0..<size).reduce(0) { $0 | Int(data[offset+$1]) << ($1*8) }
        }
        func directory(_ offset: Int,probe: Bool = false) throws -> [Int:Field] {
            let count = try number(offset,2)
            guard offset >= 8,count <= 4096,offset <= data.count-6,count <= (data.count-offset-6)/12 else { throw MergeMasterCodec.invalid }
            if !probe { guard try number(offset+2+count*12,4) == 0 else { throw MergeMasterCodec.invalid } }
            headerEnd = max(headerEnd,offset+2+count*12+4)
            var result = [Int:Field]()
            for i in 0..<count {
                let p = offset+2+i*12,tag = try number(p,2),type = try number(p+2,2),n = try number(p+4,4)
                if probe && tag != 270 && tag != 50706 { continue }
                guard let size = [1:1,2:1,3:2,4:4,5:8,7:1,10:8,11:4,12:8][type],n <= data.count/size else { throw MergeMasterCodec.invalid }
                let length = n*size,location = try length <= 4 ? p+8 : number(p+8,4)
                guard length <= 1_048_576,location <= data.count,length <= data.count-location,result[tag] == nil else { throw MergeMasterCodec.invalid }
                headerEnd = max(headerEnd,location+length)
                result[tag] = Field(type:type,bytes:Data(data[location..<location+length]))
            }
            return result
        }
        func scalar(_ fields: [Int:Field],_ tag: Int,type: Int) throws -> Int {
            guard let field = fields[tag],field.type == type,field.bytes.count == 4 else { throw MergeMasterCodec.invalid }
            return field.bytes.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset*8) }
        }
    }
}
