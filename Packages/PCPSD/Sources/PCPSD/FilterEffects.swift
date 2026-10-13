// Smart-filter caches: the global `FEid` / `FXid` ("Filter Effects") block.
// Port of photocraft-psd (crates/psd/src/filter_effects.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// u32 version (1...3), then one section per smart object, each zero-padded to 4 bytes outside its
// length: u64 length, then items: Pascal id (the smart object's `placed` id, unpadded), u32 item
// version, u64 item length, then rect, u32 depth, u32 max channels, `max channels + 2` slots (u32
// written flag; if set u64 length, u16 compression, data); after the item a u8 flag and, if set, the
// filter mask (rect, u64 length, u16 compression, data). RLE counts are 4 bytes in every version.

import Foundation

public struct PSDEffectsPlane: Equatable, Sendable {
    public var compression: PSDCompression
    public var data: Data

    public init(compression: PSDCompression, data: Data) {
        self.compression = compression
        self.data = data
    }

    public static func encode(_ compression: PSDCompression, decoded: [UInt8], width: Int, height: Int, depth: UInt16) throws -> PSDEffectsPlane {
        let layout = PlaneLayout(planes: 1, width: width, height: height, depth: depth, version: .psb)
        return PSDEffectsPlane(compression: compression, data: Data(try PlaneCodec.encode(compression, decoded, layout: layout)))
    }

    /// Decodes `width × height` samples; sizes the data cannot possibly hold are refused first.
    public func decode(width: Int, height: Int, depth: UInt16) throws -> [UInt8] {
        let layout = PlaneLayout(planes: 1, width: width, height: height, depth: depth, version: .psb)
        let n = UInt64(data.count)
        let most: UInt64 = switch compression {
        case .raw: n
        case .rle: n.multipliedReportingOverflow(by: 64).partialValue
        default: n.multipliedReportingOverflow(by: 1032).partialValue &+ 64
        }
        guard try layout.totalBytes() <= most else { throw PSDError.invalid("filter effects: plane larger than its data can hold") }
        return try PlaneCodec.decode(compression, data, layout: layout)
    }
}

public struct PSDFilterEffectsItem: Equatable, Sendable {
    public var id: String
    public var version: UInt32
    public var rect: PSDRect
    public var depth: UInt32
    public var maxChannels: UInt32
    /// `maxChannels + 2` slots (`nil` = not written): colour channels from 0, transparency last.
    public var slots: [PSDEffectsPlane?]
    /// The filter mask, in document coordinates.
    public var mask: (rect: PSDRect, plane: PSDEffectsPlane)?

    public init(id: String, version: UInt32 = 1, rect: PSDRect, depth: UInt32, maxChannels: UInt32, slots: [PSDEffectsPlane?], mask: (rect: PSDRect, plane: PSDEffectsPlane)?) {
        self.id = id
        self.version = version
        self.rect = rect
        self.depth = depth
        self.maxChannels = maxChannels
        self.slots = slots
        self.mask = mask
    }

    public static func == (a: PSDFilterEffectsItem, b: PSDFilterEffectsItem) -> Bool {
        a.id == b.id && a.version == b.version && a.rect == b.rect && a.depth == b.depth && a.maxChannels == b.maxChannels
            && a.slots == b.slots && a.mask?.rect == b.mask?.rect && a.mask?.plane == b.mask?.plane
    }

    public func decodedMask() -> (PSDRect, [UInt8])? {
        guard let (r, p) = mask, let (w, h) = try? r.size(), let d = UInt16(exactly: depth), let v = try? p.decode(width: w, height: h, depth: d) else { return nil }
        return (r, v)
    }
}

public struct PSDFilterEffects: Equatable, Sendable {
    static let maxSlots: UInt32 = 64
    public var version: UInt32
    public var items: [PSDFilterEffectsItem]

    public init(version: UInt32 = 3, items: [PSDFilterEffectsItem] = []) {
        self.version = version
        self.items = items
    }

    static func readPlane(_ r: inout ByteReader) throws -> PSDEffectsPlane {
        let len = try r.u64()
        guard len >= 2 else { throw PSDError.invalid("filter effects: plane shorter than its compression field") }
        var sub = try r.sub(u64: len)
        let c = PSDCompression(code: try sub.u16())
        return PSDEffectsPlane(compression: c, data: try sub.data(sub.remaining))
    }

    static func readItem(_ body: inout ByteReader) throws -> PSDFilterEffectsItem {
        let id = String(decoding: try body.pascal(align: 1), as: UTF8.self)
        let version = try body.u32()
        var it = try body.sub(u64: try body.u64())
        let rect = try PSDRect.read(&it)
        let depth = try it.u32()
        let maxCh = try it.u32()
        guard maxCh <= maxSlots else { throw PSDError.limitExceeded("filter effects: too many channels") }
        var slots: [PSDEffectsPlane?] = []
        for _ in 0 ..< maxCh + 2 { slots.append(try it.u32() != 0 ? try readPlane(&it) : nil) }
        guard it.isAtEnd else { throw PSDError.invalid("filter effects item \(id): \(it.remaining) unexpected bytes") }
        var mask: (rect: PSDRect, plane: PSDEffectsPlane)?
        if !body.isAtEnd, try body.u8() != 0 { mask = (try PSDRect.read(&body), try readPlane(&body)) }
        return PSDFilterEffectsItem(id: id, version: version, rect: rect, depth: depth, maxChannels: maxCh, slots: slots, mask: mask)
    }

    /// Parses block data; trailing zero padding is allowed.
    public init(bytes: Data) throws {
        self = try bytes.withByteReader { r in
            let version = try r.u32()
            guard (1 ... 3).contains(version) else { throw PSDError.invalid("filter effects version \(version)") }
            var items: [PSDFilterEffectsItem] = []
            while true {
                let len = try r.u64()
                var body = try r.sub(u64: len)
                while !body.isAtEnd { items.append(try PSDFilterEffects.readItem(&body)) }
                try r.skip(min(Int((4 - len % 4) % 4), r.remaining))
                let rest = r.rest
                if rest.count <= 3, rest.allSatisfy({ $0 == 0 }) { break }
                if rest.count < 8 { throw PSDError.invalid("filter effects: \(rest.count) unexpected bytes after the data") }
            }
            return PSDFilterEffects(version: version, items: items)
        }
    }

    /// One section per item, each padded to 4 bytes, as Photoshop writes it.
    public func serialized() -> Data {
        var w = ByteWriter()
        w.u32(version)
        func plane(_ b: inout ByteWriter, _ p: PSDEffectsPlane) {
            b.u64(UInt64(p.data.count + 2))
            b.u16(p.compression.code)
            b.put(p.data)
        }
        for it in items {
            var b = ByteWriter()
            b.pascal(Array(it.id.utf8), align: 1)
            b.u32(it.version)
            let at = b.beginLength(long: true)
            it.rect.write(&b)
            b.u32(it.depth)
            b.u32(it.maxChannels)
            for i in 0 ..< Int(it.maxChannels) + 2 {
                if i < it.slots.count, let p = it.slots[i] {
                    b.u32(1)
                    plane(&b, p)
                } else {
                    b.u32(0)
                }
            }
            try? b.endLength(at, long: true)
            if let (r, p) = it.mask {
                b.u8(1)
                r.write(&b)
                plane(&b, p)
            } else {
                b.u8(0)
            }
            w.u64(UInt64(b.count))
            w.put(b.bytes)
            w.zeros((4 - w.count % 4) % 4)
        }
        if items.isEmpty { w.u64(0) }
        return w.data
    }
}
