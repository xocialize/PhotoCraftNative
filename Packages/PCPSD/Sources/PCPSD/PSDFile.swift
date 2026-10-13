// The top-level PSD/PSB model, its parser and writer, the merged image data and the global layer
// mask.
// Port of photocraft-psd (crates/psd/src/file.rs, image_data.rs), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors. The 16/32-bit layer info redirection (`Lr16`/`Lr32` when
// the section's layer info is empty) cross-checked against PhotoDemon pdPSD.cls
// (Step4_GatherLayersAndMasks), BSD-2-Clause, © Tanner Helland and contributors.
//
// Native substitutions: `PSDFile(contentsOf:)` memory-maps the file and every channel stays a
// zero-copy slice until decoded (lazy decode); `write(to:)` streams through a `ByteSink`, measuring
// each section first so nothing is back-patched and a > 4 GB PSB never sits in memory twice.

import Foundation

/// Where the layer info was stored.
public enum PSDLayerInfoPlacement: Equatable, Sendable {
    /// In the layer info field of the layer and mask section (8-bit files).
    case section
    /// In a global `Lr16` / `Lr32` / `Layr` tagged block (16/32-bit files), re-inserted at `index`
    /// among the global blocks on write.
    case globalBlock(index: Int, signature: FourCC, key: FourCC, padding: [UInt8]?, longLengthOverride: Bool?)
}

/// Global layer mask info, stored raw with typed accessors.
public struct PSDGlobalLayerMask: Hashable, Sendable {
    public var data: [UInt8]
    public init(data: [UInt8] = []) { self.data = data }

    private func be16(_ at: Int) -> UInt16? { at + 1 < data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : nil }
    public var overlayColorSpace: UInt16? { be16(0) }
    public var colorComponents: [UInt16]? {
        guard let a = be16(2), let b = be16(4), let c = be16(6), let d = be16(8) else { return nil }
        return [a, b, c, d]
    }
    /// 0...100.
    public var opacity: UInt16? { be16(10) }
    /// 0 colour selected, 1 colour protected, 128 per layer.
    public var kind: UInt8? { data.count > 12 ? data[12] : nil }
}

/// The merged image: compression plus the encoded bytes of all channels to the end of the file.
public struct PSDImageData: Equatable, Sendable {
    public var compression: PSDCompression
    /// Encoded data. RLE: the byte-count table for every row of every channel, then the rows. ZIP:
    /// one zlib stream over all planes.
    public var data: Data

    public init(compression: PSDCompression, data: Data) {
        self.compression = compression
        self.data = data
    }

    public static func layout(_ h: PSDHeader) -> PlaneLayout {
        PlaneLayout(planes: Int(h.channels), width: Int(h.width), height: Int(h.height), depth: h.depth, version: h.version)
    }

    /// Encodes planar data (`channels × height × rowBytes`).
    public static func encode(_ compression: PSDCompression, decoded: [UInt8], header: PSDHeader) throws -> PSDImageData {
        var c = compression
        if c == .zip, header.depth == 32 { c = .zipPrediction }
        return PSDImageData(compression: c, data: Data(try PlaneCodec.encode(c, decoded, layout: layout(header))))
    }

    /// All channels, planar big-endian samples.
    public func decode(_ header: PSDHeader, lenient: Bool = false) throws -> [UInt8] {
        try PlaneCodec.decode(compression, data, layout: PSDImageData.layout(header), lenient: lenient)
    }

    /// One channel plane.
    public func decodeChannel(_ header: PSDHeader, index: Int) throws -> [UInt8] {
        let all = try decode(header)
        let plane = header.rowBytes * Int(header.height)
        guard index >= 0, (index + 1) * plane <= all.count else { throw PSDError.invalid("no merged channel \(index)") }
        return Array(all[index * plane ..< (index + 1) * plane])
    }

    static func read(_ r: inout ByteReader, header: PSDHeader) throws -> PSDImageData {
        let c = PSDCompression(code: try r.u16())
        try PlaneCodec.validate(c, r.rest, layout: layout(header))
        return PSDImageData(compression: c, data: try r.data(r.remaining))
    }
}

/// A complete PSD/PSB file. `PSDFile(data: b).serialized() == b` for unmodified well-formed files,
/// and parsing a written model gives the model back.
public struct PSDFile: Equatable, Sendable {
    public var header: PSDHeader
    /// Colour mode data (indexed palette, duotone specification, 32-bit HDR toning, …).
    public var colorModeData: Data
    /// Image resources in stored order.
    public var resources: [PSDImageResource]
    /// Bytes of the resource section that did not parse as resources (kept verbatim).
    public var resourcesTrailing: [UInt8]
    /// Layer info (`nil` when absent and no `Lr16`/`Lr32` block holds layers).
    public var layerInfo: PSDLayerInfo?
    public var layerInfoPlacement: PSDLayerInfoPlacement
    /// Global layer mask (`nil` when the field is absent).
    public var globalLayerMask: PSDGlobalLayerMask?
    /// Document-level additional layer information (Patt, Txt2, FMsk, lnk2, FEid, Mt16, …).
    public var globalBlocks: [PSDTaggedBlock]
    /// Bytes at the end of the layer and mask section that do not form a block.
    public var layerMaskTrailing: [UInt8]
    /// The merged composite.
    public var imageData: PSDImageData
    /// Problems the parser worked around (not part of equality).
    public var warnings: [String] = []

    public init(header: PSDHeader, colorModeData: Data = Data(), resources: [PSDImageResource] = [], resourcesTrailing: [UInt8] = [],
                layerInfo: PSDLayerInfo? = nil, layerInfoPlacement: PSDLayerInfoPlacement = .section,
                globalLayerMask: PSDGlobalLayerMask? = nil, globalBlocks: [PSDTaggedBlock] = [], layerMaskTrailing: [UInt8] = [],
                imageData: PSDImageData) {
        self.header = header
        self.colorModeData = colorModeData
        self.resources = resources
        self.resourcesTrailing = resourcesTrailing
        self.layerInfo = layerInfo
        self.layerInfoPlacement = layerInfoPlacement
        self.globalLayerMask = globalLayerMask
        self.globalBlocks = globalBlocks
        self.layerMaskTrailing = layerMaskTrailing
        self.imageData = imageData
    }

    public static func == (a: PSDFile, b: PSDFile) -> Bool {
        a.header == b.header && a.colorModeData == b.colorModeData && a.resources == b.resources
            && a.resourcesTrailing == b.resourcesTrailing && a.layerInfo == b.layerInfo && a.layerInfoPlacement == b.layerInfoPlacement
            && a.globalLayerMask == b.globalLayerMask && a.globalBlocks == b.globalBlocks && a.layerMaskTrailing == b.layerMaskTrailing
            && a.imageData == b.imageData
    }

    static let layerInfoKeys: Set<FourCC> = ["Lr16", "Lr32", "Layr"]

    // MARK: Parse

    /// Parses a PSD or PSB. Payloads are zero-copy slices of `data`; channels decode on request.
    public init(data: Data) throws {
        self = try data.withByteReader { r in try PSDFile.parse(&r) }
    }

    public init(bytes: [UInt8]) throws { try self.init(data: Data(bytes)) }

    /// Memory-maps and parses a file (opening a multi-gigabyte PSB reads only its structure).
    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: [.alwaysMapped]))
    }

    static func parse(_ r: inout ByteReader) throws -> PSDFile {
        let header = try PSDHeader.read(&r)
        let psb = header.version.isPSB
        let colorModeData = try r.data(Int(try r.u32()))
        let (resources, resourcesTrailing, warnings) = try readResourceSection(&r)

        let lmLen = try r.lengthField(long: psb)
        var s = try r.sub(u64: lmLen)
        var layerInfo: PSDLayerInfo?
        var placement = PSDLayerInfoPlacement.section
        var globalLayerMask: PSDGlobalLayerMask?
        var globalBlocks: [PSDTaggedBlock] = []
        var trailing: [UInt8] = []
        if !s.isAtEnd {
            let liLen = try s.lengthField(long: psb)
            if liLen > 0 {
                var lr = try s.sub(u64: liLen)
                layerInfo = try PSDLayerInfo.readBody(&lr, version: header.version)
            }
            if s.remaining >= 4 {
                let n = try s.u32()
                globalLayerMask = PSDGlobalLayerMask(data: try s.bytes(Int(n)))
                var candidateSeen = layerInfo != nil
                var found: PSDLayerInfo?
                (globalBlocks, trailing) = try readBlocks(&s, version: header.version, alignment: 4) { index, block in
                    if candidateSeen || !layerInfoKeys.contains(block.key) { return false }
                    candidateSeen = true
                    guard let info = try? block.data.withByteReader({ try PSDLayerInfo.readBody(&$0, version: header.version) }) else { return false }
                    found = info
                    placement = .globalBlock(index: index, signature: block.signature, key: block.key, padding: block.padding,
                                             longLengthOverride: block.longLengthOverride)
                    return true
                }
                if let found { layerInfo = found }
            } else {
                trailing = Array(s.rest)
                try s.skip(s.remaining)
            }
        }
        let imageData = try PSDImageData.read(&r, header: header)
        var f = PSDFile(header: header, colorModeData: colorModeData, resources: resources, resourcesTrailing: resourcesTrailing,
                        layerInfo: layerInfo, layerInfoPlacement: placement, globalLayerMask: globalLayerMask,
                        globalBlocks: globalBlocks, layerMaskTrailing: trailing, imageData: imageData)
        f.warnings = warnings
        return f
    }

    // MARK: Write

    /// Writes the file to `sink`.
    public func write<S: ByteSink>(to sink: inout S) throws {
        let v = header.version
        let psb = v.isPSB
        try header.write(to: &sink)
        // At 32 bits Photoshop requires HDR toning colour-mode data (#291); no other colour-mode
        // data is meaningful there (32-bit exists only for RGB and Grayscale). A model without it
        // (built by hand, or a lower depth raised to 32) gets the default toning data.
        let modeData = header.depth == 32 && !PSDHDRToning.isToningData(colorModeData) ? PSDHDRToning.defaultData() : colorModeData
        try sink.length(UInt64(modeData.count), long: false)
        try sink.write(modeData)
        var rw = ByteWriter()
        try writeResourceSection(&rw, resources, trailing: resourcesTrailing)
        try sink.write(rw.bytes)
        let lmLen = try measure { try writeLayerMaskBody(to: &$0) }
        try sink.length(UInt64(lmLen), long: psb)
        try writeLayerMaskBody(to: &sink)
        try sink.u16(imageData.compression.code)
        try sink.write(imageData.data)
    }

    private func writeLayerMaskBody<S: ByteSink>(to s: inout S) throws {
        let v = header.version
        let psb = v.isPSB
        var inBlock = false
        if case .globalBlock = layerInfoPlacement { inBlock = true }
        // An entirely empty section is written as a zero length (a section holding only a zero
        // layer-info length normalises to this form).
        let empty = layerInfo == nil && globalLayerMask == nil && globalBlocks.isEmpty && layerMaskTrailing.isEmpty
        if empty { return }
        if let info = layerInfo, !inBlock {
            let n = try measure { try info.writeBody(to: &$0, version: v) }
            try s.length(UInt64(n), long: psb)
            try info.writeBody(to: &s, version: v)
        } else {
            try s.length(0, long: psb)
        }
        let needMask = globalLayerMask != nil || !globalBlocks.isEmpty || (inBlock && layerInfo != nil)
        if needMask {
            let gm = globalLayerMask?.data ?? []
            try s.length(UInt64(gm.count), long: false)
            try s.write(gm)
        }
        if case let .globalBlock(index, signature, key, padding, override) = layerInfoPlacement, let info = layerInfo {
            let split = min(max(0, index), globalBlocks.count)
            try writeBlocks(Array(globalBlocks[..<split]), to: &s, version: v, alignment: 4)
            try s.fourCC(signature)
            try s.fourCC(key)
            let long = psb && (override ?? psbLongKeys.contains(key))
            let n = try measure { try info.writeBody(to: &$0, version: v) }
            try s.length(UInt64(n), long: long)
            try info.writeBody(to: &s, version: v)
            if let p = padding { try s.write(p) } else { try s.zeros((4 - n % 4) % 4) }
            try writeBlocks(Array(globalBlocks[split...]), to: &s, version: v, alignment: 4)
        } else {
            try writeBlocks(globalBlocks, to: &s, version: v, alignment: 4)
        }
        try s.write(layerMaskTrailing)
    }

    /// The whole file in memory.
    public func serialized() throws -> Data {
        var s = MemorySink(capacity: (layerInfo?.channelDataLength ?? 0) + imageData.data.count + 4096)
        try write(to: &s)
        return s.data
    }

    /// Streams the file to disk.
    public func write(to url: URL) throws {
        let sink = try FileSink(url: url)
        var s = sink
        try write(to: &s)
        try sink.close()
    }

    // MARK: Accessors

    /// Layer records in file order (bottom-most first).
    public var layers: [PSDLayerRecord] {
        get { layerInfo?.layers ?? [] }
        set {
            if layerInfo == nil { layerInfo = PSDLayerInfo() }
            layerInfo?.layers = newValue
        }
    }

    public func resource(_ id: UInt16) -> PSDImageResource? { resources.first { $0.id == id } }

    /// Replaces the first resource with the same id, or appends.
    public mutating func setResource(_ res: PSDImageResource) {
        if let i = resources.firstIndex(where: { $0.id == res.id }) { resources[i] = res } else { resources.append(res) }
    }

    public func globalBlock(_ key: FourCC) -> PSDTaggedBlock? { globalBlocks.first { $0.key == key } }

    /// The global `Lr16`/`Lr32`/`Layr` block that should have held the layers but did not parse,
    /// with the error: the file reads as flattened although it has layers.
    public func unreadableLayerBlock() -> (PSDTaggedBlock, Error)? {
        guard layerInfo == nil, let b = globalBlocks.first(where: { PSDFile.layerInfoKeys.contains($0.key) }) else { return nil }
        do {
            _ = try b.data.withByteReader { try PSDLayerInfo.readBody(&$0, version: header.version) }
            return nil
        } catch {
            return (b, error)
        }
    }

    /// ICC profile bytes (1039).
    public var iccProfile: Data? { resource(PSDResourceID.iccProfile)?.data }

    /// Resolution (1005).
    public var resolution: PSDResolutionInfo? {
        if case let .resolutionInfo(r)? = resource(PSDResourceID.resolutionInfo)?.typed { return r }
        return nil
    }

    /// The "has real merged data" flag of 1057.
    public var hasRealMergedData: Bool? {
        if case let .versionInfo(v)? = resource(PSDResourceID.versionInfo)?.typed { return v.hasRealMergedData }
        return nil
    }

    /// Whether the merged image carries a transparency channel (the first extra channel; for
    /// layered files only when the layer count was stored negative).
    /// `Mtrn`/`Mt16`/`Mt32` global blocks ("merged transparency", the spec's saving-merged-
    /// transparency keys) also mark it: ImageIO writes a positive layer count plus `Mt16`.
    public var mergedHasAlpha: Bool {
        guard let cc = colorChannelCount, Int(header.channels) > cc else { return false }
        if globalBlocks.contains(where: { PSDFile.mergedTransparencyKeys.contains($0.key) }) { return true }
        return layerInfo?.mergedAlpha ?? true
    }

    static let mergedTransparencyKeys: Set<FourCC> = ["Mtrn", "Mt16", "Mt32"]

    /// Colour channels of the merged image (multichannel: every channel).
    public var colorChannelCount: Int? {
        if header.colorMode == .multichannel { return Int(header.channels) }
        return header.colorMode.colorChannels
    }

    /// The merged image as planar big-endian samples.
    public func decodeMerged(lenient: Bool = false) throws -> [UInt8] { try imageData.decode(header, lenient: lenient) }

    /// Checks invariants the writer and Photoshop rely on.
    public func validate() throws {
        try header.validate()
        if header.version == .psd, header.width > PSDHeader.maxPSDDimension || header.height > PSDHeader.maxPSDDimension {
            throw PSDError.limitExceeded("PSD dimensions exceed 30000; use PSB")
        }
        if header.colorMode == .indexed, colorModeData.count != 768 {
            throw PSDError.invalid("indexed colour mode requires a 768-byte palette")
        }
    }
}
