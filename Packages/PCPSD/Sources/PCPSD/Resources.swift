// Image resources section (`8BIM` resource blocks): every resource is kept raw, with typed views of
// the well-known ids.
// Port of photocraft-psd (crates/psd/src/resources.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Errata from PhotoDemon pdPSD.cls (Step3_GatherImageResources),
// BSD-2-Clause, © Tanner Helland and contributors: zero-length resource blocks (Photopea) are
// accepted, and a resource section that stops parsing part-way is kept raw instead of failing the
// file; the transparent index (1047) and colour count (1046) of indexed files are read.

import Foundation

/// Well-known resource ids.
public enum PSDResourceID {
    public static let alphaNames: UInt16 = 1006
    public static let displayInfoLegacy: UInt16 = 1007
    public static let backgroundColor: UInt16 = 1010
    public static let resolutionInfo: UInt16 = 1005
    public static let layerState: UInt16 = 1024
    public static let workPath: UInt16 = 1025
    public static let layerGroupInfo: UInt16 = 1026
    public static let iptc: UInt16 = 1028
    public static let gridAndGuides: UInt16 = 1032
    public static let thumbnailPS4: UInt16 = 1033
    public static let thumbnail: UInt16 = 1036
    public static let globalAngle: UInt16 = 1037
    public static let iccProfile: UInt16 = 1039
    public static let iccUntagged: UInt16 = 1041
    public static let unicodeAlphaNames: UInt16 = 1045
    public static let indexedColorCount: UInt16 = 1046
    public static let transparentIndex: UInt16 = 1047
    public static let globalAltitude: UInt16 = 1049
    public static let slices: UInt16 = 1050
    public static let alphaIdentifiers: UInt16 = 1053
    public static let versionInfo: UInt16 = 1057
    public static let exif: UInt16 = 1058
    public static let exif3: UInt16 = 1059
    public static let xmp: UInt16 = 1060
    public static let pixelAspectRatio: UInt16 = 1064
    public static let layerComps: UInt16 = 1065
    public static let layerSelectionIDs: UInt16 = 1069
    public static let layerGroupsEnabled: UInt16 = 1072
    public static let displayInfo: UInt16 = 1077
    public static let printInformation: UInt16 = 1082
    public static let printStyle: UInt16 = 1083
    public static let pathSelectionState: UInt16 = 1088
    public static let pathFirst: UInt16 = 2000
    public static let pathLast: UInt16 = 2997
    public static let clippingPathName: UInt16 = 2999
}

/// One image resource block.
public struct PSDImageResource: Equatable, Sendable {
    /// Normally `8BIM` (also `MeSa`, `AgHg`, `PHUT`, `DCSR` in the wild).
    public var signature: FourCC
    public var id: UInt16
    /// Pascal name bytes (usually empty; path resources carry the path name).
    public var name: [UInt8]
    /// Resource data, without the even padding.
    public var data: Data

    public init(id: UInt16, data: Data, name: [UInt8] = [], signature: FourCC = "8BIM") {
        self.signature = signature
        self.id = id
        self.name = name
        self.data = data
    }

    static let signatures: Set<FourCC> = ["8BIM", "MeSa", "AgHg", "PHUT", "DCSR"]

    static func read(_ r: inout ByteReader) throws -> PSDImageResource {
        let sig = try r.fourCC()
        guard signatures.contains(sig) else { throw PSDError.invalidSignature(expected: "8BIM resource", found: sig) }
        let id = try r.u16()
        let name = try r.pascal(align: 2)
        let len = try r.u32()
        let data = try r.data(Int(len))
        if len % 2 == 1 { try r.skip(1) }
        return PSDImageResource(id: id, data: data, name: name, signature: sig)
    }

    func write(_ w: inout ByteWriter) throws {
        w.fourCC(signature)
        w.u16(id)
        w.pascal(name, align: 2)
        try w.length(UInt64(data.count), long: false)
        w.put(data)
        if data.count % 2 == 1 { w.u8(0) }
    }

    /// Typed view of well-known ids: `nil` for others, a thrown error for malformed data.
    public func parsed() throws -> PSDResourceData? {
        let d = data
        switch id {
        case PSDResourceID.resolutionInfo: return .resolutionInfo(try PSDResolutionInfo(bytes: d))
        case PSDResourceID.layerState: return .layerState(try d.withByteReader { try $0.u16() })
        case PSDResourceID.layerGroupInfo:
            guard d.count % 2 == 0 else { throw PSDError.invalid("layer group info has odd length") }
            return .layerGroupInfo(try d.withByteReader { r in try (0 ..< d.count / 2).map { _ in try r.u16() } })
        case PSDResourceID.thumbnail, PSDResourceID.thumbnailPS4: return .thumbnail(try PSDThumbnail(bytes: d, legacyBGR: id == PSDResourceID.thumbnailPS4))
        case PSDResourceID.globalAngle: return .globalAngle(try d.withByteReader { try $0.i32() })
        case PSDResourceID.globalAltitude: return .globalAltitude(try d.withByteReader { try $0.i32() })
        case PSDResourceID.iccProfile: return .iccProfile(d)
        case PSDResourceID.iccUntagged: return .iccUntagged((d.first ?? 0) != 0)
        case PSDResourceID.versionInfo: return .versionInfo(try PSDVersionInfo(bytes: d))
        case PSDResourceID.exif: return .exif(d)
        case PSDResourceID.exif3: return .exif3(d)
        case PSDResourceID.xmp: return .xmp(String(decoding: d, as: UTF8.self))
        case PSDResourceID.iptc: return .iptc(d)
        case PSDResourceID.gridAndGuides: return .gridAndGuides(try PSDGridAndGuides(bytes: d))
        case PSDResourceID.slices: return .slices(try PSDSlices(bytes: d))
        case PSDResourceID.layerComps, PSDResourceID.printInformation, PSDResourceID.printStyle, PSDResourceID.pathSelectionState:
            return .descriptor(try PSDVersionedDescriptor(bytes: d))
        case PSDResourceID.layerSelectionIDs:
            return .layerSelectionIDs(try d.withByteReader { r in
                let n = try r.u16()
                try r.checkCount(UInt64(n), minItemSize: 4)
                return try (0 ..< n).map { _ in try r.u32() }
            })
        case PSDResourceID.layerGroupsEnabled: return .layerGroupsEnabled(d.byteArray)
        case PSDResourceID.alphaNames:
            return .alphaNames(try d.withByteReader { r in
                var names: [String] = []
                while !r.isAtEnd { names.append(decodeLegacyName(try r.pascal(align: 1))) }
                return names
            })
        case PSDResourceID.unicodeAlphaNames:
            return .unicodeAlphaNames(try d.withByteReader { r in
                var names: [String] = []
                while r.remaining >= 4 { names.append(try PSDUnicodeString.read(&r).string) }
                return names
            })
        case PSDResourceID.alphaIdentifiers:
            return .alphaIdentifiers(try d.withByteReader { r in try (0 ..< d.count / 4).map { _ in try r.u32() } })
        case PSDResourceID.indexedColorCount: return .indexedColorCount(try d.withByteReader { try $0.u16() })
        case PSDResourceID.transparentIndex: return .transparentIndex(try d.withByteReader { try $0.u16() })
        case PSDResourceID.pixelAspectRatio:
            return .pixelAspectRatio(try d.withByteReader { r in _ = try r.u32(); return try r.f64() })
        case PSDResourceID.displayInfo: return .displayInfo(try PSDDisplayInfo(bytes: d))
        case PSDResourceID.workPath, PSDResourceID.pathFirst ... PSDResourceID.pathLast: return .path(try PSDPathData(bytes: d))
        case PSDResourceID.clippingPathName:
            return .clippingPathName(try d.withByteReader { r in decodeLegacyName(try r.pascal(align: 1)) })
        case PSDResourceID.backgroundColor: return .backgroundColor(try PSDColorRecord(bytes: d))
        default: return nil
        }
    }

    public var typed: PSDResourceData? { (try? parsed()) ?? nil }
}

/// Typed view of a known resource.
public enum PSDResourceData: Equatable, Sendable {
    case resolutionInfo(PSDResolutionInfo)
    /// 1024: index of the target layer.
    case layerState(UInt16)
    /// 1026: group id per layer.
    case layerGroupInfo([UInt16])
    case thumbnail(PSDThumbnail)
    case globalAngle(Int32)
    case globalAltitude(Int32)
    case iccProfile(Data)
    case iccUntagged(Bool)
    case versionInfo(PSDVersionInfo)
    case exif(Data)
    case exif3(Data)
    case xmp(String)
    case iptc(Data)
    case gridAndGuides(PSDGridAndGuides)
    case slices(PSDSlices)
    /// 1065 layer comps, 1082/1083 print settings, 1088 path selection state.
    case descriptor(PSDVersionedDescriptor)
    case layerSelectionIDs([UInt32])
    case layerGroupsEnabled([UInt8])
    case alphaNames([String])
    case unicodeAlphaNames([String])
    case alphaIdentifiers([UInt32])
    case indexedColorCount(UInt16)
    case transparentIndex(UInt16)
    case pixelAspectRatio(Double)
    case displayInfo(PSDDisplayInfo)
    case path(PSDPathData)
    case clippingPathName(String)
    case backgroundColor(PSDColorRecord)
}

/// Fixed-point resolution info (resource 1005).
public struct PSDResolutionInfo: Hashable, Sendable {
    /// Horizontal resolution, 16.16 fixed point, pixels per inch (unit 1) or per cm (unit 2).
    public var hResFixed: UInt32
    public var hResUnit: UInt16
    /// Display unit for width (1 in, 2 cm, 3 pt, 4 pica, 5 column).
    public var widthUnit: UInt16
    public var vResFixed: UInt32
    public var vResUnit: UInt16
    public var heightUnit: UInt16

    public init(dpi: Double) {
        let f = dpi.isNaN ? 0 : UInt32(max(0, min(Double(UInt32.max), (dpi * 65536).rounded())))
        hResFixed = f; hResUnit = 1; widthUnit = 1
        vResFixed = f; vResUnit = 1; heightUnit = 1
    }

    public var hRes: Double { Double(hResFixed) / 65536 }
    public var vRes: Double { Double(vResFixed) / 65536 }

    public init(bytes: Data) throws {
        (hResFixed, hResUnit, widthUnit, vResFixed, vResUnit, heightUnit) = try bytes.withByteReader { r in
            (try r.u32(), try r.u16(), try r.u16(), try r.u32(), try r.u16(), try r.u16())
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u32(hResFixed); w.u16(hResUnit); w.u16(widthUnit)
        w.u32(vResFixed); w.u16(vResUnit); w.u16(heightUnit)
        return w.data
    }
}

/// Version info (resource 1057).
public struct PSDVersionInfo: Hashable, Sendable {
    public var version: UInt32
    /// `false` when the merged image is a placeholder.
    public var hasRealMergedData: Bool
    public var writer: PSDUnicodeString
    public var reader: PSDUnicodeString
    public var fileVersion: UInt32

    public init(version: UInt32 = 1, hasRealMergedData: Bool, writer: PSDUnicodeString, reader: PSDUnicodeString, fileVersion: UInt32 = 1) {
        self.version = version
        self.hasRealMergedData = hasRealMergedData
        self.writer = writer
        self.reader = reader
        self.fileVersion = fileVersion
    }

    public init(bytes: Data) throws {
        (version, hasRealMergedData, writer, reader, fileVersion) = try bytes.withByteReader { r in
            (try r.u32(), try r.u8() != 0, try PSDUnicodeString.read(&r), try PSDUnicodeString.read(&r), try r.u32())
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u32(version)
        w.u8(hasRealMergedData ? 1 : 0)
        writer.write(&w)
        reader.write(&w)
        w.u32(fileVersion)
        return w.data
    }

    /// The 1057 resource Photoshop 2026 writes ("Adobe Photoshop" / "Adobe Photoshop 2026", no NUL).
    public static func resource(hasRealMergedData: Bool) -> PSDImageResource {
        PSDImageResource(id: PSDResourceID.versionInfo,
                         data: PSDVersionInfo(hasRealMergedData: hasRealMergedData, writer: "Adobe Photoshop", reader: "Adobe Photoshop 2026").serialized())
    }
}

/// Thumbnail resource (1036 JFIF, 1033 legacy BGR JFIF).
public struct PSDThumbnail: Equatable, Sendable {
    /// 1 = kJpegRGB, 0 = kRawRGB.
    public var format: UInt32
    public var width: UInt32
    public var height: UInt32
    public var widthBytes: UInt32
    public var totalSize: UInt32
    public var compressedSize: UInt32
    public var bitsPerPixel: UInt16
    public var planes: UInt16
    /// The image data after the 28-byte header (JFIF for format 1).
    public var imageData: Data
    /// Resource 1033 stores BGR instead of RGB.
    public var legacyBGR: Bool

    public init(bytes: Data, legacyBGR: Bool = false) throws {
        self.legacyBGR = legacyBGR
        (format, width, height, widthBytes, totalSize, compressedSize, bitsPerPixel, planes, imageData) = try bytes.withByteReader { r in
            (try r.u32(), try r.u32(), try r.u32(), try r.u32(), try r.u32(), try r.u32(), try r.u16(), try r.u16(), try r.data(r.remaining))
        }
    }

    /// A 1036 resource around JPEG data.
    public static func resource(jpeg: Data, width: Int, height: Int) -> PSDImageResource {
        var w = ByteWriter()
        let wb = UInt32((width * 24 + 31) / 32 * 4)
        w.u32(1); w.u32(UInt32(width)); w.u32(UInt32(height)); w.u32(wb)
        w.u32(wb * UInt32(height)); w.u32(UInt32(jpeg.count)); w.u16(24); w.u16(1)
        w.put(jpeg)
        return PSDImageResource(id: PSDResourceID.thumbnail, data: w.data)
    }
}

/// Grid and guides (resource 1032). Guide locations are stored in 1/32 pixel.
public struct PSDGridAndGuides: Hashable, Sendable {
    public struct Guide: Hashable, Sendable {
        /// Location in 1/32 pixel.
        public var location: Int32
        /// 0 vertical, 1 horizontal.
        public var direction: UInt8
        public var pixels: Double { Double(location) / 32 }
        public init(location: Int32, direction: UInt8) {
            self.location = location
            self.direction = direction
        }
    }

    public var version: UInt32
    public var gridHorizontal: UInt32
    public var gridVertical: UInt32
    public var guides: [Guide]
    /// Bytes after the guides, kept.
    public var trailing: [UInt8]

    public init(version: UInt32 = 1, gridHorizontal: UInt32 = 576, gridVertical: UInt32 = 576, guides: [Guide] = [], trailing: [UInt8] = []) {
        self.version = version
        self.gridHorizontal = gridHorizontal
        self.gridVertical = gridVertical
        self.guides = guides
        self.trailing = trailing
    }

    public init(bytes: Data) throws {
        (version, gridHorizontal, gridVertical, guides, trailing) = try bytes.withByteReader { r in
            let v = try r.u32(), h = try r.u32(), vv = try r.u32()
            let n = try r.u32()
            try r.checkCount(UInt64(n), minItemSize: 5)
            let g = try (0 ..< n).map { _ in Guide(location: try r.i32(), direction: try r.u8()) }
            return (v, h, vv, g, Array(r.rest))
        }
    }

    public func serialized() -> Data {
        var w = ByteWriter()
        w.u32(version); w.u32(gridHorizontal); w.u32(gridVertical)
        w.u32(UInt32(guides.count))
        for g in guides { w.i32(g.location); w.u8(g.direction) }
        w.put(trailing)
        return w.data
    }
}

/// A colour as stored in resources and legacy effects: colour space + four u16 components.
public struct PSDColorRecord: Hashable, Sendable {
    /// 0 RGB, 1 HSB, 2 CMYK, 7 Lab, 8 Gray, others (Pantone etc.) kept.
    public var space: UInt16
    public var components: [UInt16]
    public init(space: UInt16, components: [UInt16]) {
        self.space = space
        self.components = components
    }

    public init(bytes: Data) throws {
        (space, components) = try bytes.withByteReader { r in (try r.u16(), [try r.u16(), try r.u16(), try r.u16(), try r.u16()]) }
    }

    static func read(_ r: inout ByteReader) throws -> PSDColorRecord {
        PSDColorRecord(space: try r.u16(), components: [try r.u16(), try r.u16(), try r.u16(), try r.u16()])
    }

    func write(_ w: inout ByteWriter) {
        w.u16(space)
        for i in 0 ..< 4 { w.u16(i < components.count ? components[i] : 0) }
    }
}

/// Alpha channel display info (resource 1077).
public struct PSDDisplayInfo: Equatable, Sendable {
    public struct Channel: Equatable, Sendable {
        public var color: PSDColorRecord
        public var opacity: UInt16
        /// 0 alpha, 1 inverted alpha, 2 spot.
        public var kind: UInt8
    }

    public var version: UInt32
    public var channels: [Channel]

    public init(bytes: Data) throws {
        (version, channels) = try bytes.withByteReader { r in
            let v = try r.u32()
            var ch: [Channel] = []
            while r.remaining >= 13 { ch.append(Channel(color: try .read(&r), opacity: try r.u16(), kind: try r.u8())) }
            return (v, ch)
        }
    }
}

func readResourceSection(_ r: inout ByteReader) throws -> ([PSDImageResource], [UInt8], [String]) {
    let len = try r.u32()
    var s = try r.sub(Int(len))
    var out: [PSDImageResource] = []
    var warnings: [String] = []
    while !s.isAtEnd {
        let mark = s
        do {
            out.append(try PSDImageResource.read(&s))
        } catch {
            // Keep what follows verbatim (PhotoDemon realigns to the section end the same way).
            s = mark
            let rest = Array(s.rest)
            warnings.append("image resources: \(error); \(rest.count) bytes kept raw")
            return (out, rest, warnings)
        }
    }
    return (out, [], warnings)
}

func writeResourceSection(_ w: inout ByteWriter, _ res: [PSDImageResource], trailing: [UInt8]) throws {
    let at = w.beginLength(long: false)
    for r in res { try r.write(&w) }
    w.put(trailing)
    try w.endLength(at, long: false)
}
