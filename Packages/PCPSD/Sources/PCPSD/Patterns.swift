// Patterns: the global `Patt` / `Pat2` / `Pat3` blocks (8/16/32-bit documents) and `.pat` files.
// Port of photocraft-psd (crates/psd/src/patterns.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// pattern  := u32 version 1, u32 image mode, i16 height, i16 width, Unicode name, Pascal id
//             (unpadded), [indexed: 768-byte palette, 4 bytes (Photoshop: 01 00 00 ff)],
//             virtual memory array list
// VMA list := u32 version 3, u32 length, rect, u32 channel count (Photoshop: 24), then count + 2
//             arrays: the channel slots, the user mask (slot count) and the sheet mask (count + 1)
// array    := u32 written, u32 length, u32 depth, rect, u16 depth, u8 compression (0 raw, 1 RLE), data
// Blocks prefix each pattern with a u32 length and pad it to 4; `.pat` is `8BPT`, u16 1, u32 count.
//
// Photoshop keeps transparency in the sheet mask array and never writes the user mask (all 23
// transparent patterns of the 312 Photoshop 2026 ships). Photoshop 27.11 refused all 40 PCIO
// exports that had it in the user mask and opened all 27 that had it in the sheet mask.
// photocraft writes the user mask (patterns.rs:383); this writer follows Photoshop. The reader
// takes the first written array after the colour channels as transparency (photocraft, ag-psd),
// so both layouts read the same.

import Foundation

public struct PSDPattern: Equatable, Sendable {
    /// PSD colour mode code (1 gray, 2 indexed, 3 RGB, 4 CMYK, 7 multichannel, 8 duotone, 9 Lab).
    public var mode: UInt32
    public var width: Int
    public var height: Int
    public var name: String
    public var id: String
    /// Indexed palette (768 bytes, planar triplets as stored).
    public var palette: [UInt8]?
    public var depth: UInt16
    /// Decoded colour planes (big-endian samples).
    public var channels: [[UInt8]]
    public var alpha: [UInt8]?
    /// The 4 bytes after an indexed pattern's palette, kept as read and written back. Photoshop
    /// always writes them: `01 00 00 ff` in 25 of the 26 indexed patterns it ships and in the
    /// ps-corpus pattern, `00 83 00 82` in one (likely the colour count and the last index).
    /// `nil` when the pattern has none (some third-party writers); then nothing is written.
    /// Only indexed patterns (mode 2) carry it.
    public var paletteTrailer: [UInt8]?
    /// How the arrays were stored when read; not part of equality (see `Stored`).
    var stored: Stored?

    /// Photoshop's bytes after an indexed pattern's palette, the default for a new indexed pattern.
    public static let photoshopPaletteTrailer: [UInt8] = [0x01, 0x00, 0x00, 0xFF]

    /// `paletteTrailer` applies to indexed patterns only (ignored otherwise); a new indexed pattern
    /// gets Photoshop's bytes unless `nil` is passed.
    public init(mode: UInt32, width: Int, height: Int, name: String, id: String, palette: [UInt8]? = nil, depth: UInt16, channels: [[UInt8]], alpha: [UInt8]? = nil,
                paletteTrailer: [UInt8]? = PSDPattern.photoshopPaletteTrailer) {
        self.mode = mode
        self.width = width
        self.height = height
        self.name = name
        self.id = id
        self.palette = palette
        self.depth = depth
        self.channels = channels
        self.alpha = alpha
        self.paletteTrailer = mode == 2 ? paletteTrailer : nil
    }

    public static func == (a: PSDPattern, b: PSDPattern) -> Bool {
        a.mode == b.mode && a.width == b.width && a.height == b.height && a.name == b.name && a.id == b.id && a.palette == b.palette
            && a.paletteTrailer == b.paletteTrailer && a.depth == b.depth && a.channels == b.channels && a.alpha == b.alpha
    }

    /// The virtual memory array list as read. `write` gives back each array's stored bytes while
    /// its plane is unchanged: Photoshop's PackBits runs differ from `PackBits.encode` (every row
    /// of the ps-corpus pattern does) and it stores most 8-bit colour channels raw, so re-encoding
    /// would not reproduce its patterns.
    struct Stored: Sendable {
        /// The list's channel count (Photoshop: 24); the user mask is slot `slotCount`, the sheet
        /// mask `slotCount + 1`.
        var slotCount: Int
        /// The slots holding a written array, in order.
        var writtenSlots: [Int]
        /// The slot transparency was read from.
        var transparencySlot: Int?
        /// The colour channels' and transparency's arrays (`nil` for one that did not cover the
        /// whole pattern rectangle).
        var channels: [StoredArray?]
        var alpha: StoredArray?

        /// Whether the user mask array is written (Photoshop never writes it).
        var writesUserMask: Bool { writtenSlots.contains(slotCount) }
    }

    struct StoredArray: Sendable {
        /// The decoded plane (shares storage with the model's plane until that is replaced).
        var plane: [UInt8]
        var width: Int
        var height: Int
        var depth: UInt16
        var compression: UInt8
        var payload: Data
    }

    /// Channel slots in the array list Photoshop writes (the colour channels first).
    static let channelSlots = 24
    static let maxEdge = 30_000
    /// Budget for zero padding of channels smaller than the pattern rectangle.
    static let maxPaddedBytes: UInt64 = 512 << 20

    public static func modeChannels(_ mode: UInt32) -> Int {
        switch mode {
        case 3, 9: 3
        case 4: 4
        default: 1
        }
    }

    public static func blockKey(depth: UInt16) -> FourCC { depth == 16 ? "Pat2" : depth == 32 ? "Pat3" : "Patt" }
    static let blockKeys: Set<FourCC> = ["Patt", "Pat2", "Pat3"]

    static func read(_ r: inout ByteReader) throws -> PSDPattern {
        let version = try r.u32()
        guard version == 1 else { throw PSDError.invalid("pattern version \(version)") }
        let mode = try r.u32()
        _ = try r.u16(); _ = try r.u16()
        let n = Int(try r.u32())
        guard n <= 65_536 else { throw PSDError.limitExceeded("pattern name length") }
        let units = try (0 ..< n).map { _ in try r.u16() }
        var name = String(decoding: units, as: UTF16.self)
        while name.hasSuffix("\0") { name.removeLast() }
        let id = String(decoding: try r.bytes(Int(try r.u8())), as: UTF8.self)
        var palette: [UInt8]?
        var trailer: [UInt8]?
        if mode == 2 {
            palette = try r.bytes(768)
            // Photoshop follows the palette with 4 bytes; some writers do not (ag-psd skips them).
            if r.remaining >= 4, Array(r.rest.prefix(4)) != [0, 0, 0, 3] { trailer = try r.bytes(4) }
        }
        let vver = try r.u32()
        guard vver == 3 else { throw PSDError.invalid("virtual memory array list version \(vver)") }
        var v = try r.sub(Int(try r.u32()))
        let top = try v.i32(), left = try v.i32(), bottom = try v.i32(), right = try v.i32()
        let (w64, h64) = (Int64(right) - Int64(left), Int64(bottom) - Int64(top))
        guard w64 > 0, h64 > 0, w64 <= Int64(maxEdge), h64 <= Int64(maxEdge) else { throw PSDError.limitExceeded("pattern size") }
        let (w, h) = (Int(w64), Int(h64))
        let count = try v.u32()
        guard count <= 64 else { throw PSDError.limitExceeded("pattern channel count") }
        struct Pending { var data: Data; var code: UInt8; var compression: PSDCompression; var source: PlaneLayout; var x: Int; var y: Int }
        var pending: [Pending] = []
        var slots: [Int] = []
        var depth: UInt16 = 8
        var decoded: UInt64 = 0, padded: UInt64 = 0
        for slot in 0 ..< Int(count) + 2 {
            if v.isAtEnd { break }
            if try v.u32() == 0 { continue }
            let alen = Int(try v.u32())
            if alen == 0 { continue }
            guard alen >= 23 else { throw PSDError.invalid("short virtual memory array") }
            let d32 = try v.u32()
            let ct = try v.i32(), cl = try v.i32(), cb = try v.i32(), cr = try v.i32()
            let d16 = try v.u16()
            let comp = try v.u8()
            let data = try v.data(alen - 23)
            let d = [1, 8, 16, 32].contains(d16) ? d16 : UInt16(truncatingIfNeeded: d32)
            guard [1, 8, 16, 32].contains(d) else { throw PSDError.invalid("pattern depth \(d)") }
            depth = d
            guard ct >= top, cl >= left, cb <= bottom, cr <= right, cb >= ct, cr >= cl else {
                throw PSDError.invalid("pattern channel rectangle falls outside pattern rectangle")
            }
            let source = PlaneLayout(planes: 1, width: Int(Int64(cr) - Int64(cl)), height: Int(Int64(cb) - Int64(ct)), depth: d, version: .psd)
            let dest = PlaneLayout(planes: 1, width: w, height: h, depth: d, version: .psd)
            let planeBytes = try dest.totalBytes()
            decoded += planeBytes
            guard decoded <= PSDLimits.maxDecodedBytes else { throw PSDError.limitExceeded("pattern data exceeds maxDecodedBytes") }
            if source.width != w || source.height != h {
                padded += planeBytes
                guard padded <= maxPaddedBytes else { throw PSDError.limitExceeded("padded pattern channels exceed the pattern budget") }
            }
            let compression: PSDCompression = comp == 1 ? .rle : comp == 0 ? .raw : .unknown(UInt16(comp))
            let expansion: UInt64? = compression == .raw ? 1 : compression == .rle ? 64 : nil
            if let e = expansion, try source.totalBytes() > UInt64(data.count) * e {
                throw PSDError.limitExceeded("pattern channel exceeds its input-derived size limit")
            }
            pending.append(Pending(data: data, code: comp, compression: compression, source: source, x: Int(Int64(cl) - Int64(left)), y: Int(Int64(ct) - Int64(top))))
            slots.append(slot)
        }
        let nc = modeChannels(mode)
        guard pending.count >= nc else { throw PSDError.invalid("pattern has fewer channels than its colour mode") }
        var planes: [[UInt8]] = []
        var arrays: [StoredArray?] = []
        for p in pending {
            let plane = try PlaneCodec.decode(p.compression, p.data, layout: p.source)
            let placed = try place(plane, source: p.source, x: p.x, y: p.y,
                                   destination: PlaneLayout(planes: 1, width: w, height: h, depth: p.source.depth, version: .psd))
            planes.append(placed)
            let whole = p.x == 0 && p.y == 0 && p.source.width == w && p.source.height == h
            arrays.append(whole ? StoredArray(plane: placed, width: w, height: h, depth: p.source.depth, compression: p.code, payload: p.data) : nil)
        }
        // The first nc written arrays are the colour channels, the next one transparency (user
        // mask or sheet mask alike); any further arrays are dropped.
        let hasAlpha = planes.count > nc
        var pattern = PSDPattern(mode: mode, width: w, height: h, name: name, id: id, palette: palette, depth: depth,
                                 channels: Array(planes.prefix(nc)), alpha: hasAlpha ? planes[nc] : nil, paletteTrailer: trailer)
        pattern.stored = Stored(slotCount: Int(count), writtenSlots: slots, transparencySlot: hasAlpha ? slots[nc] : nil,
                                channels: Array(arrays.prefix(nc)), alpha: hasAlpha ? arrays[nc] : nil)
        return pattern
    }

    /// Places a channel's plane at (x, y) in a zero-filled pattern plane.
    static func place(_ plane: [UInt8], source: PlaneLayout, x: Int, y: Int, destination: PlaneLayout) throws -> [UInt8] {
        guard x + source.width <= destination.width, y + source.height <= destination.height else {
            throw PSDError.invalid("pattern channel rectangle falls outside pattern rectangle")
        }
        guard plane.count == (try source.decodedLength()) else { throw PSDError.invalid("pattern channel payload does not match its rectangle") }
        if x == 0, y == 0, source.width == destination.width, source.height == destination.height {
            var p = plane
            if source.depth == 1, source.width % 8 != 0 {
                let mask = UInt8.max << UInt8(8 - source.width % 8)
                let rb = source.rowBytes
                for r in 0 ..< source.height where rb > 0 { p[r * rb + rb - 1] &= mask }
            }
            return p
        }
        var out = [UInt8](repeating: 0, count: try destination.decodedLength())
        if source.depth == 1 {
            let srb = source.rowBytes, drb = destination.rowBytes
            for row in 0 ..< source.height {
                for col in 0 ..< source.width {
                    let bit = (plane[row * srb + col / 8] >> UInt8(7 - col % 8)) & 1
                    let dc = x + col
                    out[(y + row) * drb + dc / 8] |= bit << UInt8(7 - dc % 8)
                }
            }
        } else {
            let bps = Int(source.depth / 8)
            let rowBytes = source.width * bps
            for row in 0 ..< source.height {
                let s = row * source.rowBytes, d = (y + row) * destination.rowBytes + x * bps
                out.replaceSubrange(d ..< d + rowBytes, with: plane[s ..< s + rowBytes])
            }
        }
        return out
    }

    /// Writes the pattern in Photoshop's layout: 24 channel slots, the user mask array empty and
    /// transparency in the sheet mask array. Arrays read from data keep their stored bytes while
    /// their plane is unchanged; others are encoded (RLE at 8 bits, raw otherwise).
    func write(_ w: inout ByteWriter) throws {
        guard width <= PSDPattern.maxEdge, height <= PSDPattern.maxEdge, width <= Int(Int16.max), height <= Int(Int16.max) else {
            throw PSDError.limitExceeded("pattern size")
        }
        w.u32(1); w.u32(mode); w.u16(UInt16(height)); w.u16(UInt16(width))
        w.unicodeUnits(Array(name.utf16) + [0])
        let idb = Array(id.utf8.prefix(255))
        w.u8(UInt8(idb.count)); w.put(idb)
        if mode == 2 {
            w.put(Array(((palette ?? []) + [UInt8](repeating: 0, count: 768)).prefix(768)))
            if let t = paletteTrailer {
                // 00 00 00 03 would read as the array list's version (no trailer).
                guard t.count == 4, t != [0, 0, 0, 3] else { throw PSDError.invalid("palette trailer must be 4 bytes other than 00 00 00 03") }
                w.put(t)
            }
        }
        var body = ByteWriter()
        let rect: [Int32] = [0, 0, Int32(height), Int32(width)]
        for v in rect { body.i32(v) }
        let slots = PSDPattern.channelSlots
        body.u32(UInt32(slots))
        let layout = PlaneLayout(planes: 1, width: width, height: height, depth: depth, version: .psd)
        func array(_ plane: [UInt8], _ kept: StoredArray?) throws {
            body.u32(1)
            if let k = kept, k.depth == depth, k.width == width, k.height == height, k.plane == plane {
                body.u32(UInt32(23 + k.payload.count)); body.u32(UInt32(depth))
                for v in rect { body.i32(v) }
                body.u16(depth); body.u8(k.compression); body.put(k.payload)
                return
            }
            let data = try PlaneCodec.encode(depth == 8 ? .rle : .raw, plane, layout: layout)
            body.u32(UInt32(23 + data.count)); body.u32(UInt32(depth))
            for v in rect { body.i32(v) }
            body.u16(depth); body.u8(depth == 8 ? 1 : 0); body.put(data)
        }
        let nc = min(channels.count, slots)
        for (k, c) in channels.prefix(nc).enumerated() { try array(c, stored.flatMap { k < $0.channels.count ? $0.channels[k] : nil }) }
        for _ in nc ..< slots { body.u32(0) }
        body.u32(0) // the user mask: never written
        if let a = alpha { try array(a, stored?.alpha) } else { body.u32(0) } // the sheet mask: transparency
        w.u32(3); w.u32(UInt32(body.count)); w.put(body.bytes)
    }

    /// Parses `Patt` / `Pat2` / `Pat3` block data.
    public static func parseBlock(_ data: Data) throws -> [PSDPattern] { try parseBlockAndTail(data).patterns }

    /// The patterns, and how many bytes follow the last one when they are not all zero (padding).
    /// The reader stops quietly before a tail shorter than a length word, as Photoshop does: it
    /// opened PCIO's files whose `Patt` was the 2-byte test placeholder `01 02`.
    static func parseBlockAndTail(_ data: Data) throws -> (patterns: [PSDPattern], strayTail: Int) {
        try data.withByteReader { r in
            var out: [PSDPattern] = []
            while r.remaining >= 4 {
                let len = Int(try r.u32())
                if len == 0 { break }
                var body = try r.sub(len)
                out.append(try read(&body))
                try r.skip(min((4 - len % 4) % 4, r.remaining))
            }
            return (out, r.rest.contains { $0 != 0 } ? r.remaining : 0)
        }
    }

    public static func writeBlock(_ patterns: [PSDPattern]) throws -> Data {
        var w = ByteWriter()
        for p in patterns {
            var one = ByteWriter()
            try p.write(&one)
            w.u32(UInt32(one.count))
            w.put(one.bytes)
            w.zeros((4 - one.count % 4) % 4)
        }
        return w.data
    }

    /// Parses a `.pat` file.
    public static func parsePatFile(_ data: Data) throws -> [PSDPattern] {
        try data.withByteReader { r in
            let sig = try r.fourCC()
            guard sig == "8BPT" else { throw PSDError.invalidSignature(expected: "8BPT", found: sig) }
            _ = try r.u16()
            let count = try r.u32()
            return try (0 ..< min(count, 100_000)).map { _ in try read(&r) }
        }
    }

    public static func writePatFile(_ patterns: [PSDPattern]) throws -> Data {
        var w = ByteWriter()
        w.fourCC("8BPT"); w.u16(1); w.u32(UInt32(patterns.count))
        for p in patterns { try p.write(&w) }
        return w.data
    }
}

extension PSDFile {
    /// The document's patterns (`Patt`, `Pat2`, `Pat3`).
    public var patterns: [PSDPattern] {
        globalBlocks.filter { PSDPattern.blockKeys.contains($0.key) }.flatMap { (try? PSDPattern.parseBlock($0.data)) ?? [] }
    }
}
