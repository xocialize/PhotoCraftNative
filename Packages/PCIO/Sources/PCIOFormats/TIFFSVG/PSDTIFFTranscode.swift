// Port of photocraft-psd (crates/psd/src/tiff.rs, `pub mod transcode`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Field-by-field byte-order conversion of Photoshop structures.
//
// Every function reads one structure in the source order and writes it in the target order, so
// output lengths equal input lengths and every length field stays valid. Layouts follow the Adobe
// PSD specification; the walker only needs to know where the integers, doubles and four-character
// keys are, not what they mean.
//
// Native substitution: photocraft's walker creates a child walker (own input slice and output
// vector) per nested region. Here one walker narrows its input window (`r.end`) for the region and
// writes into the shared output, rolling back output, warnings, depth and version where photocraft
// would discard a child. The bytes produced are the same.

import Foundation
import PCPSD

extension PSDTIFF {
    /// Byte-order conversion of the Photoshop structures in a layered TIFF (photocraft
    /// `tiff::transcode`).
    public enum Transcode {
        /// Converts the tagged blocks after the 37724 header string from `from` to `to`.
        public static func transcodeBlocks(_ data: [UInt8], _ version: PSDVersion, _ from: ByteOrder, _ to: ByteOrder) throws -> (bytes: [UInt8], warnings: [String]) {
            var t = Tx(data, version, from, to)
            try t.blocks()
            return (t.out, t.warnings)
        }

        /// Converts a layer-info body (the data of a `Layr` / `Lr16` / `Lr32` block) between orders.
        public static func transcodeLayerInfo(_ data: [UInt8], _ version: PSDVersion, _ from: ByteOrder, _ to: ByteOrder) throws -> (bytes: [UInt8], warnings: [String]) {
            var t = Tx(data, version, from, to)
            try t.layerInfo()
            return (t.out, t.warnings)
        }

        /// Converts image-resource blocks (a 34377 tag) between orders.
        public static func transcodeResources(_ data: [UInt8], _ from: ByteOrder, _ to: ByteOrder) throws -> (bytes: [UInt8], warnings: [String]) {
            var t = Tx(data, .psd, from, to)
            try t.resources()
            return (t.out, t.warnings)
        }

        /// photocraft `descriptor::MAX_DEPTH`.
        static let maxDepth = 64
        /// photocraft `layer::MAX_LAYER_CHANNELS`.
        static let maxLayerChannels: UInt16 = 64
        /// photocraft `filter_effects::MAX_SLOTS`.
        static let maxSlots: UInt32 = 64

        /// A block signature as stored in `little` or big-endian data. Big-endian data (the model)
        /// also carries the `MIB8` / `46B8` markers of blocks kept from a little-endian file.
        static func isSig(_ b: ArraySlice<UInt8>, _ little: Bool) -> Bool {
            guard b.count >= 4 else { return false }
            let v = FourCC(bytes: b.prefix(4)).rawValue
            if little { return Records.isForeignMarker(v) }
            return v == FourCC("8BIM").rawValue || v == FourCC("8B64").rawValue || Records.isForeignMarker(v)
        }

        static func height(_ top: Int32, _ bottom: Int32) -> Int {
            let (d, o) = bottom.subtractingReportingOverflow(top)
            let v = o ? (bottom < top ? Int32.min : Int32.max) : d
            return max(0, Int(v))
        }

        static func keyString(_ k: FourCC) -> String { String(decoding: k.bytes, as: UTF8.self) }

        // MARK: - Walker

        struct Tx {
            var r: Records.Cursor
            var out: [UInt8]
            let from: ByteOrder
            let to: ByteOrder
            var version: PSDVersion
            var warnings: [String] = []
            var depth = 0

            init(_ data: [UInt8], _ version: PSDVersion, _ from: ByteOrder, _ to: ByteOrder) {
                r = Records.Cursor(data, little: from.isLittle)
                out = []
                out.reserveCapacity(data.count)
                self.from = from
                self.to = to
                self.version = version
            }

            var sameOrder: Bool { from == to }
            var remaining: Int { r.remaining }

            /// Saved walker state for a rollback.
            struct Mark {
                let pos: Int
                let end: Int
                let out: Int
                let warnings: Int
                let depth: Int
                let version: PSDVersion
            }

            func mark() -> Mark { Mark(pos: r.pos, end: r.end, out: out.count, warnings: warnings.count, depth: depth, version: version) }

            mutating func restore(_ m: Mark) {
                r.pos = m.pos
                r.end = m.end
                out.removeSubrange(m.out...)
                warnings.removeSubrange(m.warnings...)
                depth = m.depth
                version = m.version
            }

            // MARK: Primitive copies

            mutating func put16(_ v: UInt16) { put(UInt64(v), 2) }
            mutating func put32(_ v: UInt32) { put(UInt64(v), 4) }
            mutating func put64(_ v: UInt64) { put(v, 8) }

            /// The low `n` bytes of `v` in the target order.
            mutating func put(_ v: UInt64, _ n: Int) {
                if to.isLittle {
                    for i in 0 ..< n { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
                } else {
                    for i in (0 ..< n).reversed() { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
                }
            }

            @discardableResult mutating func u16() throws -> UInt16 {
                let v = try r.u16()
                put16(v)
                return v
            }

            @discardableResult mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

            @discardableResult mutating func u32() throws -> UInt32 {
                let v = try r.u32()
                put32(v)
                return v
            }

            @discardableResult mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

            @discardableResult mutating func u64() throws -> UInt64 {
                let v = try r.u64()
                put64(v)
                return v
            }

            mutating func i64() throws { try u64() }
            mutating func f64() throws { try u64() }
            mutating func f32() throws { try u32() }

            @discardableResult mutating func u8() throws -> UInt8 {
                let v = try r.u8()
                out.append(v)
                return v
            }

            /// Bytes copied as they are.
            mutating func raw(_ n: Int) throws {
                let b = try r.bytes(n)
                out += b
            }

            mutating func rest() throws { try raw(remaining) }

            /// A four-character signature or key: stored reversed in little-endian data. Returns
            /// the canonical (big-endian) spelling.
            @discardableResult mutating func key() throws -> FourCC {
                var k = Array(try r.bytes(4))
                if from.isLittle { k.reverse() }
                let canonical = FourCC(bytes: k)
                out += to.isLittle ? k.reversed() : k
                return canonical
            }

            mutating func len(_ long: Bool) throws -> UInt64 { long ? try u64() : UInt64(try u32()) }

            mutating func u16s(_ n: Int) throws { for _ in 0 ..< n { try u16() } }

            /// Up to `n` `u16`s: a block shorter than its full layout keeps what it has.
            mutating func u16sUpto(_ n: Int) throws {
                for _ in 0 ..< n {
                    if remaining < 2 { break }
                    try u16()
                }
            }

            mutating func i32s(_ n: Int) throws { for _ in 0 ..< n { try i32() } }
            mutating func f64s(_ n: Int) throws { for _ in 0 ..< n { try f64() } }

            /// `u16`s to the end (a lone odd byte is copied).
            mutating func u16sToEnd() throws {
                while remaining >= 2 { try u16() }
                try rest()
            }

            mutating func u32sToEnd() throws {
                while remaining >= 4 { try u32() }
                try rest()
            }

            /// A Photoshop Unicode string: u32 count + UTF-16 units.
            mutating func unicode() throws {
                let n = try u32()
                try r.checkCount(UInt64(n), 2)
                try u16s(Int(n))
            }

            /// A Pascal string padded to `align`.
            mutating func pascal(_ align: Int) throws {
                let n = Int(try u8())
                try raw(n)
                let total = 1 + n
                try raw((align - total % align) % align)
            }

            /// The next u32 in the source order, without consuming it (photocraft `r.clone().u32()`).
            func peekU32() throws -> UInt32 {
                var c = r
                return try c.u32()
            }

            func peekU64() throws -> UInt64 {
                var c = r
                return try c.u64()
            }

            // MARK: Regions

            /// Transcodes the next `len` bytes with `f`; whatever `f` leaves is copied verbatim.
            mutating func region(_ len: UInt64, _ f: (inout Tx) throws -> Void) throws {
                let n = try r.count(len)
                let saveEnd = r.end, saveDepth = depth
                let start = out.count
                r.end = r.pos + n
                defer { r.end = saveEnd; depth = saveDepth }
                try f(&self)
                try rest()
                if out.count - start != n {
                    throw PSDError.invalid("byte-order conversion changed a structure's length")
                }
            }

            /// Reads a length field (4 bytes, or 8 when `long`), transcodes that many bytes with
            /// `f` and writes the length of the result: blocks dropped inside shrink the field.
            mutating func sizedRegion(_ long: Bool, _ f: (inout Tx) throws -> Void) throws {
                try sizedRegionCounting(long, false, f)
            }

            /// `sizedRegion` for a u32 length that counts its own 4 bytes.
            mutating func sizedRegionInclusive(_ f: (inout Tx) throws -> Void) throws {
                try sizedRegionCounting(false, true, f)
            }

            mutating func sizedRegionCounting(_ long: Bool, _ inclusive: Bool, _ f: (inout Tx) throws -> Void) throws {
                var len = try r.lengthField(long: long)
                let at = out.count
                out += [UInt8](repeating: 0, count: long ? 8 : 4)
                if inclusive {
                    guard len >= 4 else { throw PSDError.invalid("length shorter than its own field") }
                    len -= 4
                }
                let n = try r.count(len)
                let saveEnd = r.end, saveDepth = depth
                let start = out.count
                r.end = r.pos + n
                defer { r.end = saveEnd; depth = saveDepth }
                try f(&self)
                try rest()
                try patchLen(at, long, UInt64(out.count - start) + (inclusive ? 4 : 0))
            }

            /// Tries `f` on the rest of the data; it counts as a match only when at most three
            /// trailing zero bytes are left. On a miss nothing is consumed or written.
            mutating func attempt(_ f: (inout Tx) throws -> Void) -> Bool {
                let m = mark()
                let ok = (try? f(&self)) != nil && remaining <= 3 && r.rest.allSatisfy { $0 == 0 }
                if !ok { restore(m) }
                return ok
            }

            /// Blocks whose layout is not known by key are very often a versioned descriptor,
            /// optionally behind a u32 version (every Photoshop block introduced since CS6 is):
            /// recognized by parsing to the end.
            mutating func descriptorShaped() -> Bool {
                attempt { try $0.versionedDescriptor() } || attempt { t in
                    try t.u32()
                    try t.versionedDescriptor()
                }
            }

            /// Writes `n` into the length placeholder at `at`.
            mutating func patchLen(_ at: Int, _ long: Bool, _ n: UInt64) throws {
                var b: [UInt8]
                if long {
                    b = (0 ..< 8).map { UInt8(n >> (56 - 8 * UInt64($0)) & 0xFF) }
                } else {
                    guard n <= UInt64(UInt32.max) else { throw PSDError.limitExceeded("structure too large for a 32-bit length") }
                    b = (0 ..< 4).map { UInt8(n >> (24 - 8 * UInt64($0)) & 0xFF) }
                }
                if to.isLittle { b.reverse() }
                if at >= 0, at + b.count <= out.count { out.replaceSubrange(at ..< at + b.count, with: b) }
            }

            /// An RLE row-count table (`rows` entries of 2 bytes, 4 in PSB data).
            mutating func rleCounts(_ rows: Int) throws {
                for _ in 0 ..< rows {
                    if version.isPSB {
                        if remaining < 4 { break }
                        try u32()
                    } else {
                        if remaining < 2 { break }
                        try u16()
                    }
                }
            }

            /// Encoded channel data for a plane of `rows` rows: the compression field, then the RLE
            /// row counts (container order) and the samples (always big-endian: copied).
            mutating func channelData(_ rows: Int, _ longCounts: Bool) throws {
                let saved = version
                if longCounts { version = .psb }
                defer { version = saved }
                let compression = try u16()
                if compression == 1 { try rleCounts(rows) }
                version = saved
                try rest()
            }

            // MARK: Image resources (34377)

            mutating func resources() throws {
                while remaining >= 12, Transcode.isSig(r.rest, from.isLittle) {
                    try key()
                    let id = try u16()
                    try pascal(2)
                    let odd = try peekU32() % 2 == 1
                    try sizedRegion(false) { try $0.resourceData(id) }
                    if odd, remaining > 0 { try raw(1) }
                }
                try rest()
            }

            /// Typed numeric resources; every other payload is a byte blob (ICC, XMP, EXIF, …) or
            /// unknown and is copied as stored.
            mutating func resourceData(_ id: UInt16) throws {
                switch id {
                // Resolution info: fixed 16.16 h res, u16 unit, u16 width unit, then the same for v.
                case 1005:
                    try u32(); try u16(); try u16()
                    try u32(); try u16(); try u16()
                // Layer state (u16 target), layer group info (u16 per layer).
                case 1024, 1026: try u16sToEnd()
                // Global angle / altitude.
                case 1037, 1049: try u32()
                // Layer selection ids: u16 count + u32 ids.
                case 1069:
                    try u16()
                    try u32sToEnd()
                // Version info: u32 version, u8 has real merged data, two Unicode strings, u32.
                case 1057:
                    try u32(); try u8(); try unicode(); try unicode(); try u32()
                // Grid and guides: u32 version, 2 × u32 grid, u32 count, (u32 location, u8 direction)…
                case 1032:
                    try u32(); try u32(); try u32()
                    let n = try u32()
                    for _ in 0 ..< n {
                        if remaining < 5 { break }
                        try u32()
                        try u8()
                    }
                // Path resources: 26-byte records.
                case 2000 ... 2997, 2999: try pathRecords()
                default: break
                }
            }

            // MARK: Tagged blocks

            /// Tagged blocks to the end; bytes that do not form a block are copied.
            mutating func blocks() throws {
                while true {
                    let rest = r.rest
                    if rest.count < 12 || !Transcode.isSig(rest, from.isLittle) {
                        return try self.rest()
                    }
                    try block()
                }
            }

            /// Padding after a block: the smallest k in 0...3 after which the next block (or the
            /// end) starts.
            func blockPadding() -> Int {
                let rest = r.rest
                for k in 0 ... 3 {
                    if k == rest.count || (k < rest.count && Transcode.isSig(rest.dropFirst(k), from.isLittle)) { return k }
                }
                return 0
            }

            mutating func block() throws {
                let before = out.count
                // A `MIB8` / `46B8` marker in big-endian data: a block kept verbatim from a
                // little-endian file. Written back as it was into little-endian output (its `8BIM`
                // signature reversed, as every signature there), copied as is otherwise.
                if !from.isLittle, r.rest.count >= 4, Records.isForeignMarker(FourCC(bytes: r.rest.prefix(4)).rawValue) {
                    let sig = Array(try r.bytes(4))
                    var key = Array(try r.bytes(4))
                    // photocraft looks the length width up with the key as it will be written
                    // (reversed for little-endian output), as here.
                    let long = usesLongLength(version, FourCC(bytes: to.isLittle ? key.reversed() : key))
                    let len = try r.lengthField(long: long)
                    let data = try r.bytes(u64: len)
                    if to.isLittle { key.reverse() }
                    out += sig
                    out += key
                    let n = out.count
                    out += [UInt8](repeating: 0, count: long ? 8 : 4)
                    try patchLen(n, long, len)
                    out += data
                    try raw(blockPadding())
                    return
                }
                let sigAt = out.count
                let sig = try key()
                let key = try key()
                let long = usesLongLength(version, key)
                let len = try r.lengthField(long: long)
                let lenAt = out.count
                out += [UInt8](repeating: 0, count: long ? 8 : 4)
                let n = try r.count(len)
                let dataStart = r.pos, dataEnd = r.pos + n
                let saveEnd = r.end
                let childOut = out.count, childWarnings = warnings.count
                let saveDepth = depth, saveVersion = version
                var handled: Result<Bool, Error>
                r.end = dataEnd
                depth += 1
                if depth > Transcode.maxDepth {
                    handled = .failure(PSDError.limitExceeded("tagged block nesting too deep"))
                } else if n == 0 {
                    handled = .success(true)
                } else {
                    do { handled = .success(try blockBody(key)) } catch { handled = .failure(error) }
                }
                if case .success(true) = handled { try rest() }
                r.end = saveEnd
                r.pos = dataEnd
                depth = saveDepth
                version = saveVersion
                let pad = blockPadding()
                let padBytes = try r.bytes(pad)
                let data = r.data[dataStart ..< dataEnd]
                let keyName = Transcode.keyString(key)
                let marker: [UInt8] = Array((sig == "8B64" ? "46B8" : "MIB8").utf8)
                /// Discards whatever the body wrote.
                func dropChild(_ t: inout Tx) {
                    t.out.removeSubrange(childOut...)
                    t.warnings.removeSubrange(childWarnings...)
                }
                switch handled {
                case .success(true):
                    try patchLen(lenAt, long, UInt64(out.count - childOut))
                    out += padBytes
                case .success(false) where sameOrder:
                    dropChild(&self)
                    try patchLen(lenAt, long, UInt64(n))
                    out += data
                    out += padBytes
                case .success(false) where from.isLittle:
                    // Little-endian in, big-endian model: keep the bytes as they are, marked.
                    dropChild(&self)
                    out.replaceSubrange(sigAt ..< sigAt + 4, with: marker)
                    try patchLen(lenAt, long, UInt64(n))
                    out += data
                    out += padBytes
                case .success(false):
                    out.removeSubrange(before...)
                    warnings.removeSubrange(childWarnings...)
                    warnings.append("\(keyName) block (\(n) bytes) dropped: its layout is unknown and cannot be converted to the file's byte order")
                case let .failure(e) where sameOrder:
                    throw PSDError.invalid("\(keyName) block: \(e)")
                case let .failure(e) where from.isLittle:
                    dropChild(&self)
                    out.replaceSubrange(sigAt ..< sigAt + 4, with: marker)
                    try patchLen(lenAt, long, UInt64(n))
                    out += data
                    out += padBytes
                    warnings.append("\(keyName) block (\(n) bytes) kept as stored, in little-endian layout: \(e)")
                case let .failure(e):
                    out.removeSubrange(before...)
                    warnings.removeSubrange(childWarnings...)
                    warnings.append("\(keyName) block (\(n) bytes) dropped: \(e)")
                }
            }

            /// Transcodes a block's data by key. `false` for keys without a known layout.
            mutating func blockBody(_ key: FourCC) throws -> Bool {
                switch key {
                case "Layr", "Lr16", "Lr32": try layerInfo()
                case "luni": try unicode()
                case "lsct", "lsdk":
                    try u32()
                    if remaining >= 8 {
                        try self.key()
                        try self.key()
                    }
                    if remaining >= 4 { try u32() }
                // lyvr layer version, sn2P and vowv (shape and vector flags).
                case "lyid", "lspf", "lyvr", "sn2P", "vowv": try u32()
                // Text-engine global data: a textual structure, no byte order.
                case "Txt2": try rest()
                case "lnsr": try self.key()
                // Advanced Blending flags and fill opacity: one byte, then padding (Adobe spec,
                // "Additional Layer Information"; `lmgm`/`vmgm` = layer/vector mask hides effects).
                case "clbl", "infx", "knko", "tsly", "lmgm", "vmgm", "iOpa": try u8()
                case "lclr": try u16sUpto(4)
                case "fxrp":
                    while remaining >= 8 { try f64() }
                case "brst": try u32sToEnd()
                case "LMsk": try u16sUpto(6)
                case "FMsk": try u16sToEnd()
                case "shmd": try metadataSetting()
                // Effects (lfxs: the effects as applied to a group), content credentials (CAI).
                case "lfx2", "lmfx", "lfxs", "CAI ":
                    try u32()
                    try versionedDescriptor()
                case "SoCo", "GdFl", "PtFl", "vstk", "blwh", "vibA", "CgEd", "artb", "artd", "cinf", "cust", "PxSD", "GenI", "OCIO", "extn", "pths":
                    try versionedDescriptor()
                // Color Lookup: u16 version, then the descriptor.
                case "clrL":
                    try u16()
                    try versionedDescriptor()
                case "lnk2", "lnk3", "lnkD", "lnkE": try linkedLayers()
                case "Anno": try annotations()
                case "vogk":
                    try u32()
                    try versionedDescriptor()
                case "vscg":
                    try self.key()
                    try versionedDescriptor()
                case "SoLd", "SoLE":
                    try self.key()
                    try u32()
                    try versionedDescriptor()
                case "PlLd":
                    try self.key()
                    try u32()
                    try pascal(1)
                    for _ in 0 ..< 4 { try u32() }
                    try f64s(8)
                    try u32()
                    try versionedDescriptor()
                // Type: version, transform, text version + descriptor, warp version + descriptor,
                // and the bounds as four 32-bit values (the specification says doubles; Photoshop
                // writes 16 bytes).
                case "TySh":
                    try u16()
                    try f64s(6)
                    try u16()
                    try versionedDescriptor()
                    try u16()
                    try versionedDescriptor()
                    try i32s(4)
                case "vmsk", "vsms":
                    try u32()
                    try u32()
                    try pathRecords()
                case "Patt", "Pat2", "Pat3":
                    while remaining >= 4 {
                        let len = try peekU32()
                        if len == 0 {
                            try u32()
                            continue
                        }
                        try sizedRegion(false) { try $0.pattern() }
                        // Each pattern is padded to a multiple of 4.
                        let pad = Int((4 - len % 4) % 4)
                        try raw(min(pad, remaining))
                    }
                case "FEid", "FXid": try filterEffects()
                case "lrFX": try legacyEffects()
                case "levl":
                    try u16()
                    for _ in 0 ..< 29 * 5 {
                        if remaining < 2 { break }
                        try u16()
                    }
                    if remaining >= 4 { try self.key() }
                    try u16sToEnd()
                case "curv": try curves()
                case "hue2":
                    try u16()
                    try u8()
                    try u8()
                    try u16sToEnd()
                case "brit": try u16sUpto(3)
                case "thrs", "post": try u16()
                case "nvrt": break
                case "expA":
                    try u16()
                    for _ in 0 ..< 3 { try f32() }
                case "blnc": try u16sUpto(9)
                case "mixr", "selc": try u16sToEnd()
                case "phfl":
                    switch try u16() {
                    case 2:
                        try u16s(5)
                        try u32()
                        try u8()
                    case 3:
                        for _ in 0 ..< 4 { try u32() }
                        try u8()
                    case let v:
                        throw PSDError.unsupported("photo filter version \(v)")
                    }
                case "grdm": try gradientMap()
                default:
                    if !sameOrder { return descriptorShaped() }
                    return false
                }
                return true
            }

            /// `lnk2` / `lnk3` / `lnkD` / `lnkE` (linked and embedded smart-object files): items of
            /// u64 length + data, each padded to 4. Item: type (`liFD` embedded, `liFE` external,
            /// `liFA` alias), version 1–7, Pascal uuid, Unicode name, file type and creator keys,
            /// u64 data length, open-descriptor flag (+ descriptor), per-type fields, the file
            /// bytes for `liFD`, then the fields later versions added.
            mutating func linkedLayers() throws {
                while remaining >= 8 {
                    let len = try peekU64()
                    try sizedRegion(true) { t in
                        let kind = try t.key()
                        let version = try t.u32()
                        try t.pascal(1)
                        try t.unicode()
                        try t.key()
                        try t.key()
                        let dataLen = try t.u64()
                        if try t.u8() != 0 { try t.versionedDescriptor() }
                        if kind == "liFE", version > 3 {
                            try t.i32()
                            for _ in 0 ..< 4 { try t.u8() }
                            try t.f64()
                        }
                        if kind == "liFE" { try t.u64() }
                        if kind == "liFA" { try t.raw(8) }
                        guard dataLen <= UInt64(Int.max) else { throw PSDError.limitExceeded("linked file length") }
                        let n = Int(dataLen)
                        if kind == "liFD" { try t.raw(n) }
                        if version >= 5 { try t.unicode() }
                        if version >= 6 { try t.f64() }
                        if version >= 7 { try t.u8() }
                        if kind == "liFE", version == 2 { try t.raw(n) }
                    }
                    let pad = Int((4 - len % 4) % 4)
                    try raw(min(pad, remaining))
                }
            }

            /// `Anno`: u16 major, u16 minor, u32 count, then per annotation a self-counting u32
            /// length, type key, open and flags bytes, u16 optional blocks, icon and popup rects, a
            /// colour, three even-padded Pascal strings, and a self-counting data block (key, u32
            /// size, text with its own byte-order mark).
            mutating func annotations() throws {
                try u16()
                try u16()
                let n = try u32()
                for _ in 0 ..< n {
                    if remaining < 4 { break }
                    try sizedRegionInclusive { t in
                        try t.key()
                        try t.u8()
                        try t.u8()
                        try t.u16()
                        try t.i32s(8)
                        try t.u16s(5)
                        try t.pascal(2)
                        try t.pascal(2)
                        try t.pascal(2)
                        try t.sizedRegionInclusive { d in
                            try d.key()
                            try d.u32()
                        }
                    }
                }
            }

            // MARK: Layer info

            mutating func layerInfo() throws {
                let count = try i16()
                let n = Int(count.magnitude)
                try r.checkCount(UInt64(n), 34)
                // Per layer: the channel ids and lengths, and the heights of the layer, mask and
                // real-mask rects (what each channel's RLE count table spans).
                var records: [(chans: [(id: Int16, len: UInt64)], heights: [Int])] = []
                records.reserveCapacity(n)
                for _ in 0 ..< n {
                    let top = try i32()
                    try i32()
                    let bottom = try i32()
                    try i32()
                    let nch = try u16()
                    if nch > Transcode.maxLayerChannels { throw PSDError.limitExceeded("too many channels in layer") }
                    var chans: [(id: Int16, len: UInt64)] = []
                    let psb = version.isPSB
                    for _ in 0 ..< nch {
                        let id = try i16()
                        let len = try self.len(psb)
                        chans.append((id, len))
                    }
                    let sig = try key()
                    if sig != "8BIM" { throw PSDError.invalidSignature(expected: "8BIM (layer blend mode)", found: sig) }
                    try key()
                    for _ in 0 ..< 4 { try u8() }
                    var heights = [Transcode.height(top, bottom), 0, 0]
                    var maskHeights = (0, 0)
                    try sizedRegion(false) { t in
                        try t.sizedRegion(false) { m in maskHeights = try m.mask() }
                        // Blending ranges are bytes (black low/high, white low/high per channel),
                        // so Photoshop stores them in the same order in either byte order: an
                        // Intel-order layered TIFF holds the default ranges as `00 00 ff ff`.
                        // Swapping them as u32s turned every range into `ff ff 00 00`, which hides
                        // every pixel of the layer.
                        try t.sizedRegion(false) { x in try x.rest() }
                        try t.pascal(4)
                        try t.blocks()
                    }
                    heights[1] = maskHeights.0
                    heights[2] = maskHeights.1
                    records.append((chans, heights))
                }
                for (chans, heights) in records {
                    for (id, len) in chans {
                        if len == 0 { continue }
                        if len == 1 { throw PSDError.invalid("channel data length 1") }
                        let rows = id == -2 ? heights[1] : id == -3 ? heights[2] : heights[0]
                        try region(len) { try $0.channelData(rows, false) }
                    }
                }
                try rest()
            }

            /// A layer mask record. Returns the heights of the mask and real-mask rects.
            mutating func mask() throws -> (Int, Int) {
                let whole = r.rest
                if whole.isEmpty { return (0, 0) }
                let top = try i32()
                try i32()
                let bottom = try i32()
                try i32()
                try u8()
                let flags = try u8()
                var realH = 0
                if remaining <= 2 { return (Transcode.height(top, bottom), 0) }
                let hasParameters = flags & PSDLayerMask.flagParameters != 0
                // The helper only looks at lengths and the parameter-flags byte, so it reads the
                // same in either order.
                let realFirst = hasParameters && Records.realBeforeParameters(whole)
                func readReal(_ t: inout Tx) throws {
                    if t.remaining >= 18 {
                        try t.u8()
                        try t.u8()
                        let rt = try t.i32()
                        try t.i32()
                        let rb = try t.i32()
                        try t.i32()
                        realH = Transcode.height(rt, rb)
                    }
                }
                if realFirst { try readReal(&self) }
                if hasParameters {
                    let pf = try u8()
                    let need = Records.maskParameterBytes(pf)
                    if need > remaining { throw PSDError.unexpectedEOF(offset: r.pos, needed: need - remaining) }
                    if pf & 1 != 0 { try u8() }
                    if pf & 2 != 0 { try f64() }
                    if pf & 4 != 0 { try u8() }
                    if pf & 8 != 0 { try f64() }
                }
                if !realFirst { try readReal(&self) }
                return (Transcode.height(top, bottom), realH)
            }

            // MARK: Descriptors

            mutating func versionedDescriptor() throws {
                try u32()
                try descriptor()
            }

            mutating func descriptor() throws {
                if depth > Transcode.maxDepth { throw PSDError.limitExceeded("descriptor nesting too deep") }
                depth += 1
                try unicode()
                try id()
                let n = try u32()
                try r.checkCount(UInt64(n), 10)
                for _ in 0 ..< n {
                    try id()
                    try value()
                }
                depth -= 1
            }

            mutating func id() throws {
                let n = try u32()
                if n == 0 {
                    try key()
                } else {
                    guard UInt64(n) <= UInt64(Int.max) else { throw PSDError.limitExceeded("id length") }
                    try raw(Int(n))
                }
            }

            mutating func classRef() throws {
                try unicode()
                try id()
            }

            mutating func value() throws {
                if depth > Transcode.maxDepth { throw PSDError.limitExceeded("descriptor nesting too deep") }
                let ty = try key()
                switch ty {
                case "obj ":
                    let n = try u32()
                    try r.checkCount(UInt64(n), 8)
                    for _ in 0 ..< n { try referenceItem() }
                case "Objc", "GlbO": try descriptor()
                case "VlLs":
                    let n = try u32()
                    try r.checkCount(UInt64(n), 4)
                    depth += 1
                    for _ in 0 ..< n { try value() }
                    depth -= 1
                case "doub": try f64()
                case "UntF":
                    try key()
                    try f64()
                case "UnFl":
                    try key()
                    let n = try u32()
                    try r.checkCount(UInt64(n), 8)
                    try f64s(Int(n))
                case "TEXT": try unicode()
                case "enum":
                    try id()
                    try id()
                case "long": try i32()
                case "comp": try i64()
                case "bool": try u8()
                case "type", "GlbC": try classRef()
                case "alis", "Pth ", "tdta":
                    let n = try u32()
                    try raw(Int(n))
                case "ObAr":
                    try u32()
                    try descriptor()
                default:
                    throw PSDError.unsupported("descriptor OSType \"\(Transcode.keyString(ty))\"")
                }
            }

            mutating func referenceItem() throws {
                let ty = try key()
                switch ty {
                case "prop":
                    try classRef()
                    try id()
                case "Clss": try classRef()
                case "Enmr":
                    try classRef()
                    try id()
                    try id()
                case "rele":
                    try classRef()
                    try i32()
                case "Idnt", "indx": try u32()
                case "name":
                    try classRef()
                    try unicode()
                default:
                    throw PSDError.unsupported("reference item type \"\(Transcode.keyString(ty))\"")
                }
            }

            // MARK: Other block layouts

            /// `shmd`: u32 count, then per item signature, key, copy flag, 3 bytes, u32 length,
            /// data. An item whose layout is unknown is dropped on its own (and the count patched)
            /// rather than taking the whole block with it.
            mutating func metadataSetting() throws {
                let n = try r.u32()
                try r.checkCount(UInt64(n), 16)
                let countAt = out.count
                out += [0, 0, 0, 0]
                var kept: UInt32 = 0
                for _ in 0 ..< n {
                    let m = mark()
                    try key()
                    let key = try self.key()
                    try u8()
                    try raw(3)
                    let same = sameOrder
                    do {
                        try sizedRegion(false) { t in
                            switch key {
                            case "cmls", "mlst", "cust", "tmln", "sgrp", "cinf": try t.versionedDescriptor()
                            // mdyn (dynamic metadata) is one u32.
                            case "mdyn": try t.u32sToEnd()
                            default:
                                if same || t.descriptorShaped() { return }
                                throw PSDError.unsupported("metadata item \"\(Transcode.keyString(key))\"")
                            }
                        }
                        kept += 1
                    } catch {
                        if same { throw error }
                        // Drop the item: back to where it started, then past its data.
                        restore(m)
                        try skipItem()
                        warnings.append("shmd item \(Transcode.keyString(key)) dropped: \(error)")
                    }
                }
                try patchLen(countAt, false, UInt64(kept))
            }

            /// Skips one `shmd` item in the source (signature, key, flag, 3 bytes, u32 length,
            /// data) without writing it.
            mutating func skipItem() throws {
                try r.skip(12)
                let len = try r.u32()
                try r.skip(try r.count(UInt64(len)))
            }

            /// 26-byte path records: a u16 selector then, for knots, six fixed-point coordinates.
            mutating func pathRecords() throws {
                while remaining >= 26 {
                    let selector = try u16()
                    switch selector {
                    case 1, 2, 4, 5: try i32s(6)
                    // Length records: knot count, path operation, then fields Photoshop writes as
                    // 16-bit values (zero in practice).
                    case 0, 3: try u16s(12)
                    // Clipboard: four fixed-point coordinates and a resolution.
                    case 7:
                        try i32s(5)
                        try raw(4)
                    case 8:
                        try u16()
                        try raw(22)
                    default: try raw(24)
                    }
                }
            }

            /// One pattern of a `Patt` block (the data after its u32 length).
            mutating func pattern() throws {
                try u32()
                let mode = try u32()
                try u16()
                try u16()
                try unicode()
                try pascal(1)
                if mode == 2 {
                    try raw(768)
                    // Some writers follow the palette with 4 extra bytes before the array list version.
                    let nextIsVersion = (try? peekU32()) == 3
                    if !nextIsVersion, remaining >= 4 { try raw(4) }
                }
                try u32()
                try sizedRegion(false) { v in
                    try v.i32s(4)
                    let count = try v.u32()
                    for _ in 0 ..< UInt64(count) + 2 {
                        if v.remaining < 4 { break }
                        if try v.u32() == 0 { continue }
                        if try v.peekU32() == 0 {
                            try v.u32()
                            continue
                        }
                        try v.sizedRegion(false) { c in
                            try c.u32()
                            let ct = try c.i32()
                            try c.i32()
                            let cb = try c.i32()
                            try c.i32()
                            try c.u16()
                            let comp = try c.u8()
                            if comp == 1 {
                                let saved = c.version
                                c.version = .psd
                                defer { c.version = saved }
                                try c.rleCounts(Transcode.height(ct, cb))
                            }
                        }
                    }
                }
            }

            /// `FEid` / `FXid`: version, u64 length, items with per-channel planes (4-byte RLE counts).
            mutating func filterEffects() throws {
                try u32()
                try sizedRegion(true) { t in
                    while !t.r.isEmpty {
                        try t.pascal(1)
                        try t.u32()
                        try t.sizedRegion(true) { it in
                            let top = try it.i32()
                            try it.i32()
                            let bottom = try it.i32()
                            try it.i32()
                            let rectH = Transcode.height(top, bottom)
                            try it.u32()
                            let max = try it.u32()
                            if max > Transcode.maxSlots { throw PSDError.limitExceeded("filter effects: too many channels") }
                            for _ in 0 ..< max + 2 {
                                if try it.u32() != 0 { try it.effectsPlane(rectH) }
                            }
                        }
                        if !t.r.isEmpty, try t.u8() != 0 {
                            let top = try t.i32()
                            try t.i32()
                            let bottom = try t.i32()
                            try t.i32()
                            try t.effectsPlane(Transcode.height(top, bottom))
                        }
                    }
                }
            }

            mutating func effectsPlane(_ rows: Int) throws {
                try sizedRegion(true) { try $0.channelData(rows, true) }
            }

            /// `lrFX`: version, count, then effects (`cmnS`, `dsdw`, `isdw`, `oglw`, `iglw`,
            /// `bevl`, `sofi`), each a signature, key, u32 size and fixed fields.
            mutating func legacyEffects() throws {
                try u16()
                let n = try u16()
                for _ in 0 ..< n {
                    if remaining < 12 { break }
                    try key()
                    let key = try self.key()
                    try sizedRegion(false) { t in
                        // A colour: u16 space + 4 × u16 components.
                        func colour(_ t: inout Tx) throws { try t.u16s(5) }
                        func blend(_ t: inout Tx) throws {
                            try t.key()
                            try t.key()
                        }
                        switch key {
                        case "cmnS":
                            try t.u32()
                            try t.u8()
                            try t.u16()
                        case "dsdw", "isdw":
                            try t.u32()
                            try t.i32s(4)
                            try colour(&t)
                            try blend(&t)
                            try t.u8()
                            try t.u8()
                            try t.u8()
                            if t.remaining >= 10 { try colour(&t) }
                        case "oglw":
                            try t.u32()
                            try t.i32s(2)
                            try colour(&t)
                            try blend(&t)
                            try t.u8()
                            try t.u8()
                            if t.remaining >= 10 { try colour(&t) }
                        case "iglw":
                            try t.u32()
                            try t.i32s(2)
                            try colour(&t)
                            try blend(&t)
                            try t.u8()
                            try t.u8()
                            if t.remaining >= 11 {
                                try t.u8()
                                try colour(&t)
                            }
                        case "bevl":
                            try t.u32()
                            try t.i32s(3)
                            try blend(&t)
                            try blend(&t)
                            try colour(&t)
                            try colour(&t)
                            for _ in 0 ..< 6 { try t.u8() }
                            if t.remaining >= 20 {
                                try colour(&t)
                                try colour(&t)
                            }
                        case "sofi":
                            try t.u32()
                            try blend(&t)
                            try colour(&t)
                            try t.u8()
                            try t.u8()
                            if t.remaining >= 10 { try colour(&t) }
                        default: break
                        }
                    }
                }
            }

            /// `curv`: pad byte, version, channel bitmap, per set bit a point list; then an
            /// optional `Crv ` extension with per-channel point lists.
            mutating func curves() throws {
                try u8()
                try u16()
                let bits = try u32()
                for bit in 0 ..< 32 {
                    if bits & (1 << UInt32(bit)) == 0 { continue }
                    if remaining < 2 { break }
                    let n = try u16()
                    try u16s(Int(n) * 2)
                }
                if remaining >= 10 {
                    try key()
                    try u16()
                    let n = try u32()
                    for _ in 0 ..< n {
                        if remaining < 4 { break }
                        try u16()
                        let pts = try u16()
                        try u16s(Int(pts) * 2)
                    }
                }
            }

            /// `grdm`: version, reverse, dither, [method key], name, colour stops, transparency
            /// stops, then the noise-gradient fields (a u32 seed among u16s).
            mutating func gradientMap() throws {
                let version = try u16()
                try u8()
                try u8()
                if version == 3 { try key() }
                try unicode()
                let n = try u16()
                for _ in 0 ..< n {
                    if remaining < 20 { break }
                    try u32()
                    try u32()
                    try u16s(6)
                }
                let nt = try u16()
                for _ in 0 ..< nt {
                    if remaining < 10 { break }
                    try u32()
                    try u32()
                    try u16()
                }
                // expansion, interpolation, length, mode, u32 seed, then u16 fields.
                for _ in 0 ..< 4 {
                    if remaining < 2 { return }
                    try u16()
                }
                if remaining >= 4 { try u32() }
                try u16sToEnd()
            }
        }
    }
}
