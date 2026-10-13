// Layer records, layer masks, blending ranges and per-layer channel data.
// Port of photocraft-psd (crates/psd/src/layer.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. Mask record parsing cross-checked against PhotoDemon pdPSDLayer.cls
// (ParseLayerMaskAdjustmentData: the real-mask fields come before the parameters in Photoshop's
// files, and the spec's listed sizes are wrong), BSD-2-Clause, © Tanner Helland and contributors.
//
// Beyond photocraft: a channel whose stored length is 1 (no room for the compression field) is kept
// raw instead of failing the whole file; channel payloads are zero-copy slices of the file buffer.

import Foundation

/// A rectangle as stored in PSD files (top, left, bottom, right); bottom/right exclusive.
public struct PSDRect: Hashable, Sendable, CustomStringConvertible {
    public var top: Int32
    public var left: Int32
    public var bottom: Int32
    public var right: Int32

    public init(top: Int32 = 0, left: Int32 = 0, bottom: Int32 = 0, right: Int32 = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public init(x: Int32, y: Int32, width: UInt32, height: UInt32) {
        top = y
        left = x
        bottom = Int32(clamping: Int64(y) + Int64(min(height, UInt32(Int32.max))))
        right = Int32(clamping: Int64(x) + Int64(min(width, UInt32(Int32.max))))
    }

    public static let zero = PSDRect()

    /// Width (negative for malformed data).
    public var width: Int64 { Int64(right) - Int64(left) }
    public var height: Int64 { Int64(bottom) - Int64(top) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Validated size.
    public func size() throws -> (width: Int, height: Int) {
        let w = width, h = height
        guard w >= 0, h >= 0 else { throw PSDError.invalid("rectangle has negative size") }
        guard w <= Int64(PSDHeader.maxDimension), h <= Int64(PSDHeader.maxDimension) else {
            throw PSDError.limitExceeded("layer dimensions exceed 300000")
        }
        return (Int(w), Int(h))
    }

    public var description: String { "(\(left),\(top))-(\(right),\(bottom))" }

    static func read(_ r: inout ByteReader) throws -> PSDRect {
        PSDRect(top: try r.i32(), left: try r.i32(), bottom: try r.i32(), right: try r.i32())
    }

    func write(_ w: inout ByteWriter) {
        w.i32(top); w.i32(left); w.i32(bottom); w.i32(right)
    }
}

/// Layer record flag byte.
public struct PSDLayerFlags: OptionSet, Hashable, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let transparencyProtected = PSDLayerFlags(rawValue: 1 << 0)
    /// Set = hidden (the spec calls it "visible"; the bit really stores invisibility).
    public static let hidden = PSDLayerFlags(rawValue: 1 << 1)
    public static let obsolete = PSDLayerFlags(rawValue: 1 << 2)
    /// Bit 4 carries useful information.
    public static let bit4Useful = PSDLayerFlags(rawValue: 1 << 3)
    /// Pixel data irrelevant to the appearance of the document.
    public static let pixelDataIrrelevant = PSDLayerFlags(rawValue: 1 << 4)

    public var isHidden: Bool {
        get { contains(.hidden) }
        set { if newValue { insert(.hidden) } else { remove(.hidden) } }
    }

    /// Sets pixel-data-irrelevant (and bit 3).
    public mutating func setPixelDataIrrelevant(_ v: Bool) {
        insert(.bit4Useful)
        if v { insert(.pixelDataIrrelevant) } else { remove(.pixelDataIrrelevant) }
    }
}

/// Optional mask parameters (present when mask flag bit 4 is set).
public struct PSDMaskParameters: Equatable, Sendable {
    /// Bit 0 user density, 1 user feather, 2 vector density, 3 vector feather.
    public var flags: UInt8
    public var userDensity: UInt8?
    public var userFeather: Double?
    public var vectorDensity: UInt8?
    public var vectorFeather: Double?

    public init(flags: UInt8 = 0, userDensity: UInt8? = nil, userFeather: Double? = nil, vectorDensity: UInt8? = nil, vectorFeather: Double? = nil) {
        self.flags = flags
        self.userDensity = userDensity
        self.userFeather = userFeather
        self.vectorDensity = vectorDensity
        self.vectorFeather = vectorFeather
    }

    static func byteCount(flags pf: UInt8) -> Int {
        (pf & 1 != 0 ? 1 : 0) + (pf & 2 != 0 ? 8 : 0) + (pf & 4 != 0 ? 1 : 0) + (pf & 8 != 0 ? 8 : 0)
    }
}

/// "Real" user mask fields (36+-byte mask records): the user mask when a vector mask is also present.
public struct PSDRealMask: Hashable, Sendable {
    public var flags: UInt8
    /// Real user mask background (0 or 255).
    public var background: UInt8
    public var rect: PSDRect
    public init(flags: UInt8 = 0, background: UInt8 = 0, rect: PSDRect = .zero) {
        self.flags = flags
        self.background = background
        self.rect = rect
    }
}

/// Layer mask / adjustment layer data.
public struct PSDLayerMask: Equatable, Sendable {
    public static let flagRelative: UInt8 = 1 << 0
    public static let flagDisabled: UInt8 = 1 << 1
    public static let flagInvert: UInt8 = 1 << 2
    /// The user mask came from rendering other data (e.g. a vector mask).
    public static let flagFromRendering: UInt8 = 1 << 3
    public static let flagParameters: UInt8 = 1 << 4

    public var rect: PSDRect
    /// Value outside the rectangle (0 or 255).
    public var defaultColor: UInt8
    public var flags: UInt8
    public var parameters: PSDMaskParameters?
    public var real: PSDRealMask?
    /// Remaining bytes (the 2 padding bytes of the 20-byte form, etc.).
    public var trailing: [UInt8]
    /// When both are present, the real-mask fields come before the parameters (Photoshop's order;
    /// the spec lists parameters first). `false` keeps a spec-order file byte-stable.
    public var realFirst: Bool

    /// The simple 20-byte form.
    public init(rect: PSDRect, defaultColor: UInt8, flags: UInt8) {
        self.rect = rect
        self.defaultColor = defaultColor
        self.flags = flags & ~PSDLayerMask.flagParameters
        parameters = nil
        real = nil
        trailing = [0, 0]
        realFirst = true
    }

    public init(rect: PSDRect, defaultColor: UInt8, flags: UInt8, parameters: PSDMaskParameters?, real: PSDRealMask?, trailing: [UInt8], realFirst: Bool) {
        self.rect = rect
        self.defaultColor = defaultColor
        self.flags = flags
        self.parameters = parameters
        self.real = real
        self.trailing = trailing
        self.realFirst = realFirst
    }

    public var isDisabled: Bool { flags & PSDLayerMask.flagDisabled != 0 }
    /// Position relative to the layer (the "unlinked" state in Photoshop's UI is bit 0 clear).
    public var isRelative: Bool { flags & PSDLayerMask.flagRelative != 0 }
    public var isInverted: Bool { flags & PSDLayerMask.flagInvert != 0 }
    public var cameFromRendering: Bool { flags & PSDLayerMask.flagFromRendering != 0 }

    /// Whether `d` (a whole record with parameters) stores the real-mask fields before the
    /// parameters, as Photoshop does. The spec's order wins when it reads as parameters followed
    /// by padding alone; when both orders fit, Photoshop's is taken unless its reading is
    /// implausible (a background other than 0/255, or undefined parameter bits) while the spec's
    /// reading with a real mask is sound (photocraft #949).
    static func realBeforeParameters(_ d: [UInt8]) -> Bool {
        func fits(_ at: Int) -> Bool {
            guard at < d.count else { return false }
            let n = PSDMaskParameters.byteCount(flags: d[at])
            return (at + 1 + n ... at + 4 + n).contains(d.count)
        }
        if fits(18) { return false }
        if !fits(36) { return false }
        let knownFlags = { (pf: UInt8) in pf & 0xF0 == 0 }
        let backgroundOK = { (at: Int) in at + 1 < d.count && (d[at + 1] == 0 || d[at + 1] == 255) }
        let photoshopPlausible = backgroundOK(18) && d.count > 36 && knownFlags(d[36])
        var specPlausible = false
        if d.count > 18 {
            let pf = d[18]
            let realAt = 19 + PSDMaskParameters.byteCount(flags: pf)
            specPlausible = knownFlags(pf) && (realAt + 18 ... realAt + 21).contains(d.count) && backgroundOK(realAt)
        }
        return photoshopPlausible || !specPlausible
    }

    static func parse(_ d: [UInt8]) throws -> PSDLayerMask {
        try d.withByteReader { r in
            let rect = try PSDRect.read(&r)
            let defaultColor = try r.u8()
            let flags = try r.u8()
            func readReal(_ r: inout ByteReader) throws -> PSDRealMask? {
                r.remaining >= 18 ? PSDRealMask(flags: try r.u8(), background: try r.u8(), rect: try PSDRect.read(&r)) : nil
            }
            let hasParameters = flags & flagParameters != 0
            var realFirst = hasParameters && realBeforeParameters(d)
            var real = realFirst ? try readReal(&r) : nil
            var parameters: PSDMaskParameters?
            if hasParameters {
                let pf = try r.u8()
                var p = PSDMaskParameters(flags: pf)
                if pf & 1 != 0 { p.userDensity = try r.u8() }
                if pf & 2 != 0 { p.userFeather = try r.f64() }
                if pf & 4 != 0 { p.vectorDensity = try r.u8() }
                if pf & 8 != 0 { p.vectorFeather = try r.f64() }
                parameters = p
            }
            if !realFirst { real = try readReal(&r) }
            // The order only matters when both are present; otherwise default to Photoshop's.
            realFirst = realFirst || real == nil || parameters == nil
            return PSDLayerMask(rect: rect, defaultColor: defaultColor, flags: flags, parameters: parameters, real: real,
                                trailing: Array(r.rest), realFirst: realFirst)
        }
    }

    func write(_ w: inout ByteWriter) {
        rect.write(&w)
        w.u8(defaultColor)
        w.u8(flags)
        func writeReal(_ w: inout ByteWriter) {
            if let real {
                w.u8(real.flags)
                w.u8(real.background)
                real.rect.write(&w)
            }
        }
        if realFirst { writeReal(&w) }
        if let p = parameters {
            w.u8(p.flags)
            if let v = p.userDensity { w.u8(v) }
            if let v = p.userFeather { w.f64(v) }
            if let v = p.vectorDensity { w.u8(v) }
            if let v = p.vectorFeather { w.f64(v) }
        }
        if !realFirst { writeReal(&w) }
        w.put(trailing)
    }
}

/// The layer mask data field of a layer record.
public enum PSDMaskData: Equatable, Sendable {
    /// Length 0.
    case none
    case mask(PSDLayerMask)
    /// Unparseable mask data, preserved.
    case raw([UInt8])
}

/// Layer blending ranges ("Blend If"), stored raw: 8-byte entries, composite gray first, then one
/// per channel; each is source (black lo, black hi, white lo, white hi) then destination.
public struct PSDBlendingRanges: Hashable, Sendable {
    public var data: [UInt8]
    public init(data: [UInt8] = []) { self.data = data }

    /// Default "full" ranges for composite + `channels` channels.
    public static func full(channels: Int) -> PSDBlendingRanges {
        PSDBlendingRanges(data: Array(repeating: [0, 0, 255, 255, 0, 0, 255, 255] as [UInt8], count: channels + 1).flatMap { $0 })
    }

    public struct Range: Hashable, Sendable {
        public var source: [UInt8]
        public var destination: [UInt8]
    }

    /// Parsed entries (an incomplete tail is ignored).
    public var ranges: [Range] {
        stride(from: 0, to: data.count - data.count % 8, by: 8).map { i in
            Range(source: Array(data[i ..< i + 4]), destination: Array(data[i + 4 ..< i + 8]))
        }
    }
}

/// Channel ids with special meaning.
public enum PSDChannelID {
    public static let transparency: Int16 = -1
    public static let userMask: Int16 = -2
    public static let realUserMask: Int16 = -3
}

/// Encoded image data of one layer channel, kept verbatim (lazy decode).
public struct PSDChannel: Equatable, Sendable {
    /// 0... colour channels, -1 transparency, -2 user mask, -3 real user mask.
    public var id: Int16
    /// `nil` when the stored length had no room for a compression field (0 or 1 byte).
    public var compression: PSDCompression?
    /// Encoded bytes after the compression field (or the whole stored bytes when `compression` is nil).
    public var data: Data

    public init(id: Int16, compression: PSDCompression?, data: Data) {
        self.id = id
        self.compression = compression
        self.data = data
    }

    /// Encodes planar samples (`height × rowBytes`). Empty planes are stored raw (length 2, as
    /// Photoshop writes group dividers); ZIP at 32 bits is stored as ZIP with prediction.
    public static func encode(id: Int16, compression: PSDCompression, decoded: [UInt8], width: Int, height: Int, depth: UInt16, version: PSDVersion) throws -> PSDChannel {
        let layout = PlaneLayout(planes: 1, width: width, height: height, depth: depth, version: version)
        var c = compression
        if try layout.decodedLength() == 0 { c = .raw }
        if c == .zip, depth == 32 { c = .zipPrediction }
        return PSDChannel(id: id, compression: c, data: Data(try PlaneCodec.encode(c, decoded, layout: layout)))
    }

    /// Decodes into planar big-endian samples.
    public func decode(width: Int, height: Int, depth: UInt16, version: PSDVersion, lenient: Bool = false) throws -> [UInt8] {
        let layout = PlaneLayout(planes: 1, width: width, height: height, depth: depth, version: version)
        guard let c = compression else {
            if try layout.decodedLength() == 0 { return [] }
            throw PSDError.invalid("channel \(id) has no data")
        }
        return try PlaneCodec.decode(c, data, layout: layout, lenient: lenient)
    }

    /// Replaces the contents, re-encoding with `compression`.
    public mutating func setDecoded(_ decoded: [UInt8], compression: PSDCompression, width: Int, height: Int, depth: UInt16, version: PSDVersion) throws {
        self = try PSDChannel.encode(id: id, compression: compression, decoded: decoded, width: width, height: height, depth: depth, version: version)
    }

    var storedLength: UInt64 { UInt64(data.count) + (compression == nil ? 0 : 2) }
}

/// A layer record together with its channel image data.
public struct PSDLayerRecord: Equatable, Sendable {
    public var rect: PSDRect
    /// Channels in stored order, with their encoded data.
    public var channels: [PSDChannel]
    public var blendMode: PSDBlendMode
    /// 0...255.
    public var opacity: UInt8
    /// 0 base, 1 non-base (clipped to the layer below).
    public var clipping: UInt8
    public var flags: PSDLayerFlags
    /// Filler byte (zero), preserved.
    public var filler: UInt8
    public var mask: PSDMaskData
    public var blendingRanges: PSDBlendingRanges
    /// Legacy Pascal name bytes (padded to 4 in the file).
    public var name: [UInt8]
    /// Additional layer information.
    public var blocks: [PSDTaggedBlock]
    /// Bytes at the end of the extra-data field that do not form a block.
    public var extraTrailing: [UInt8]

    public init(rect: PSDRect = .zero, channels: [PSDChannel] = [], blendMode: PSDBlendMode = .normal, opacity: UInt8 = 255,
                clipping: UInt8 = 0, flags: PSDLayerFlags = [], filler: UInt8 = 0, mask: PSDMaskData = .none,
                blendingRanges: PSDBlendingRanges = PSDBlendingRanges(), name: [UInt8] = [], blocks: [PSDTaggedBlock] = [],
                extraTrailing: [UInt8] = []) {
        self.rect = rect
        self.channels = channels
        self.blendMode = blendMode
        self.opacity = opacity
        self.clipping = clipping
        self.flags = flags
        self.filler = filler
        self.mask = mask
        self.blendingRanges = blendingRanges
        self.name = name
        self.blocks = blocks
        self.extraTrailing = extraTrailing
    }

    /// Layer name, preferring the Unicode `luni` block over the legacy Pascal name.
    public var displayName: String {
        for b in blocks where b.key == "luni" {
            if case let .unicodeName(n)? = b.typed { return n }
        }
        return decodeLegacyName(name)
    }

    public func block(_ key: FourCC) -> PSDTaggedBlock? { blocks.first { $0.key == key } }
    public func blockIndex(_ key: FourCC) -> Int? { blocks.firstIndex { $0.key == key } }

    /// Replaces the first block with the same key, or appends it.
    public mutating func setBlock(_ block: PSDTaggedBlock) {
        if let i = blockIndex(block.key) { blocks[i] = block } else { blocks.append(block) }
    }

    /// Section divider (`lsct`, falling back to `lsdk`), when present and valid.
    public var sectionDivider: PSDSectionDivider? {
        for key: FourCC in ["lsct", "lsdk"] {
            if case let .sectionDivider(s)? = block(key)?.typed { return s }
        }
        return nil
    }

    public var sectionType: PSDSectionType { sectionDivider?.kind ?? .other }
    public var isVisible: Bool { !flags.isHidden }

    /// `lyid`.
    public var layerID: UInt32? {
        if case let .layerID(v)? = block("lyid")?.typed { return v }
        return nil
    }

    /// `iOpa` (255 when absent).
    public var fillOpacity: UInt8 {
        if case let .fillOpacity(v)? = block("iOpa")?.typed { return v }
        return 255
    }

    public var layerMask: PSDLayerMask? {
        if case let .mask(m) = mask { return m }
        return nil
    }

    public func channel(_ id: Int16) -> PSDChannel? { channels.first { $0.id == id } }

    /// The rectangle a channel covers: the layer rect for colour and transparency, the mask rect for
    /// -2, the real mask rect for -3.
    public func channelRect(_ id: Int16) -> PSDRect {
        switch (id, mask) {
        case let (PSDChannelID.userMask, .mask(m)): m.rect
        case let (PSDChannelID.realUserMask, .mask(m)): m.real?.rect ?? m.rect
        default: rect
        }
    }

    /// Decodes a channel (planar big-endian samples).
    public func decodeChannel(_ id: Int16, depth: UInt16, version: PSDVersion, lenient: Bool = false) throws -> [UInt8] {
        guard let ch = channel(id) else { throw PSDError.invalid("layer has no channel \(id)") }
        let (w, h) = try channelRect(id).size()
        return try ch.decode(width: w, height: h, depth: depth, version: version, lenient: lenient)
    }

    /// Decodes several channels concurrently (missing ids fail).
    public func decodeChannels(_ ids: [Int16], depth: UInt16, version: PSDVersion, lenient: Bool = false) throws -> [Int16: [UInt8]] {
        let results = ResultsBox<[UInt8]>(count: ids.count)
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            results.set(i, Result { try decodeChannel(ids[i], depth: depth, version: version, lenient: lenient) })
        }
        var out: [Int16: [UInt8]] = [:]
        for (i, id) in ids.enumerated() { out[id] = try results.get(i) }
        return out
    }

    // MARK: IO

    static func read(_ r: inout ByteReader, version: PSDVersion) throws -> (PSDLayerRecord, [UInt64]) {
        var rec = PSDLayerRecord()
        rec.rect = try PSDRect.read(&r)
        let nch = try r.u16()
        guard nch <= PSDLimits.maxLayerChannels else { throw PSDError.limitExceeded("too many channels in layer") }
        var lens: [UInt64] = []
        for _ in 0 ..< nch {
            let id = try r.i16()
            let len = try r.lengthField(long: version.isPSB)
            rec.channels.append(PSDChannel(id: id, compression: nil, data: Data()))
            lens.append(len)
        }
        let sig = try r.fourCC()
        guard sig == "8BIM" else { throw PSDError.invalidSignature(expected: "8BIM (layer blend mode)", found: sig) }
        rec.blendMode = PSDBlendMode(key: try r.fourCC())
        rec.opacity = try r.u8()
        rec.clipping = try r.u8()
        rec.flags = PSDLayerFlags(rawValue: try r.u8())
        rec.filler = try r.u8()
        let extraLen = try r.u32()
        var x = try r.sub(Int(extraLen))
        let maskLen = try x.u32()
        let maskBytes = try x.bytes(Int(maskLen))
        if maskBytes.isEmpty {
            rec.mask = .none
        } else if let m = try? PSDLayerMask.parse(maskBytes) {
            rec.mask = .mask(m)
        } else {
            rec.mask = .raw(maskBytes)
        }
        let brLen = try x.u32()
        rec.blendingRanges = PSDBlendingRanges(data: try x.bytes(Int(brLen)))
        rec.name = try x.pascal(align: 4)
        let (blocks, trailing) = try readBlocks(&x, version: version, alignment: 2)
        rec.blocks = blocks
        rec.extraTrailing = trailing
        return (rec, lens)
    }

    func writeRecord(_ w: inout ByteWriter, version: PSDVersion) throws {
        rect.write(&w)
        guard channels.count <= Int(UInt16.max) else { throw PSDError.limitExceeded("too many channels") }
        w.u16(UInt16(channels.count))
        for c in channels {
            w.i16(c.id)
            try w.length(c.storedLength, long: version.isPSB)
        }
        w.fourCC("8BIM")
        w.fourCC(blendMode.key)
        w.u8(opacity)
        w.u8(clipping)
        w.u8(flags.rawValue)
        w.u8(filler)
        let at = w.beginLength(long: false)
        let m = w.beginLength(long: false)
        switch mask {
        case .none: break
        case let .mask(mk): mk.write(&w)
        case let .raw(b): w.put(b)
        }
        try w.endLength(m, long: false)
        try w.length(UInt64(blendingRanges.data.count), long: false)
        w.put(blendingRanges.data)
        w.pascal(name, align: 4)
        var s = MemorySink()
        try writeBlocks(blocks, to: &s, version: version, alignment: 2)
        w.put(s.data)
        w.put(extraTrailing)
        try w.endLength(at, long: false)
    }
}

/// Layer info: layer records plus their channel image data.
public struct PSDLayerInfo: Equatable, Sendable {
    /// The layer count was stored negative: the first alpha channel of the merged image holds the
    /// transparency of the merged result.
    public var mergedAlpha: Bool
    /// Records bottom-most first (file order).
    public var layers: [PSDLayerRecord]
    /// Bytes after the channel data; `nil` = default (zero pad to even).
    public var padding: [UInt8]?

    public init(mergedAlpha: Bool = false, layers: [PSDLayerRecord] = [], padding: [UInt8]? = nil) {
        self.mergedAlpha = mergedAlpha
        self.layers = layers
        self.padding = padding
    }

    /// Parses a layer info body (the bytes its length field covers).
    static func readBody(_ r: inout ByteReader, version: PSDVersion) throws -> PSDLayerInfo {
        let count = try r.i16()
        let n = Int(count.magnitude)
        // Minimum record size: 16 rect + 2 + 4 sig + 4 key + 4 + 4 extra length.
        try r.checkCount(UInt64(n), minItemSize: 34)
        var layers: [PSDLayerRecord] = []
        var allLens: [[UInt64]] = []
        layers.reserveCapacity(n)
        for _ in 0 ..< n {
            let (rec, lens) = try PSDLayerRecord.read(&r, version: version)
            layers.append(rec)
            allLens.append(lens)
        }
        for i in 0 ..< n {
            for (k, len) in allLens[i].enumerated() {
                if len == 0 { continue }
                if len == 1 {
                    // No room for a compression field: keep the byte raw (PhotoDemon skips it).
                    layers[i].channels[k].data = try r.data(1)
                    continue
                }
                layers[i].channels[k].compression = PSDCompression(code: try r.u16())
                layers[i].channels[k].data = try r.data(u64: len - 2)
            }
        }
        let bodyLen = r.pos
        let rest = Array(r.rest)
        try r.skip(rest.count)
        let padding: [UInt8]? = (rest.count == bodyLen % 2 && rest.allSatisfy { $0 == 0 }) ? nil : rest
        return PSDLayerInfo(mergedAlpha: count < 0, layers: layers, padding: padding)
    }

    /// Body length (count, records and channel data) without padding.
    public func unpaddedLength(_ version: PSDVersion) throws -> UInt64 {
        var w = ByteWriter()
        w.i16(0)
        for l in layers { try l.writeRecord(&w, version: version) }
        var n = UInt64(w.count)
        for c in layers.flatMap(\.channels) { n += c.storedLength }
        return n
    }

    /// Sets the padding so the body length is a multiple of `align`, as Photoshop writes it (4).
    /// Readers that step over a global `Lr16`/`Lr32` block in 4-byte units (psd-tools) misread the
    /// blocks after a body only padded to even.
    public mutating func pad(to align: UInt64, version: PSDVersion) throws {
        let n = try padLength(version, align: align)
        let even = Int(try unpaddedLength(version) % 2)
        // Canonical model: the default (zero pad to even) is `nil`.
        padding = n == even ? nil : [UInt8](repeating: 0, count: n)
    }

    func padLength(_ version: PSDVersion, align: UInt64) throws -> Int {
        let a = max(1, align)
        let len = try unpaddedLength(version)
        return Int((a - len % a) % a)
    }

    var channelDataLength: Int {
        layers.flatMap(\.channels).reduce(0) { $0 &+ Int($1.storedLength) }
    }

    /// Writes the body without trailing padding.
    func writeUnpadded<S: ByteSink>(to s: inout S, version: PSDVersion) throws {
        guard layers.count <= Int(Int16.max) else { throw PSDError.limitExceeded("more than 32767 layers") }
        let n = Int16(layers.count)
        var w = ByteWriter()
        w.i16(mergedAlpha ? -n : n)
        for l in layers { try l.writeRecord(&w, version: version) }
        try s.write(w.bytes)
        for l in layers {
            for c in l.channels {
                if let comp = c.compression { try s.u16(comp.code) }
                try s.write(c.data)
            }
        }
    }

    /// Writes the body (no length field).
    func writeBody<S: ByteSink>(to s: inout S, version: PSDVersion) throws {
        let start = s.written
        try writeUnpadded(to: &s, version: version)
        if let p = padding {
            try s.write(p)
        } else if (s.written - start) % 2 == 1 {
            try s.u8(0)
        }
    }

    func bodyBytes(_ version: PSDVersion) throws -> Data {
        var s = MemorySink()
        try writeBody(to: &s, version: version)
        return s.data
    }
}

/// Per-index results of concurrent work.
final class ResultsBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Result<T, Error>?]
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ r: Result<T, Error>) { lock.withLock { items[i] = r } }
    func get(_ i: Int) throws -> T {
        guard let r = lock.withLock({ items[i] }) else { throw PSDError.invalid("missing result") }
        return try r.get()
    }
}
