// OpenEXR headers, parts and flat block decoding for multi-part import: the parts of
// photocraft-codecs (crates/codecs/src/codecs/exr.rs: `info`, `decode_part`, `decode_channels`,
// `read_meta`) that photocraft-io's exr_parts.rs calls, MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors. photocraft reads the file with the pure-Rust `exr` crate; ImageIO
// opens only the first part of a file, so the container layout (OpenEXR file layout 2.0: version
// flags, multi-part headers, offset tables, scan-line and tiled chunks) is read here, from the
// public OpenEXR specification. Compressed blocks are decoded in `EXRCompression.swift`.
//
// Pixel data is taken from the data window (the display window is ignored), level 0 of mip- and
// rip-mapped tiled parts only, as photocraft does (`largest_resolution_level`). Deep parts are
// listed but never decoded (a file holding any is refused by the part decoders).

import PCIOCore

extension EXRParts {
    /// The sample type of an EXR channel.
    public enum PixelType: Int32, Sendable, Hashable {
        case uint = 0, half = 1, float = 2

        /// Bytes per stored sample.
        public var bytes: Int { self == .half ? 2 : 4 }
    }

    /// One channel of a part, as the header lists it (alphabetical by name).
    public struct ChannelInfo: Equatable, Sendable {
        public var name: String
        public var type: PixelType
        public var xSampling: Int
        public var ySampling: Int
        public var perceptuallyLinear: Bool

        public init(name: String, type: PixelType, xSampling: Int = 1, ySampling: Int = 1, perceptuallyLinear: Bool = false) {
            self.name = name; self.type = type; self.xSampling = xSampling; self.ySampling = ySampling
            self.perceptuallyLinear = perceptuallyLinear
        }

        /// photocraft lists half channels as F16 and float and uint ones (Arnold ID buffers) as
        /// F32, exact up to 2^24.
        public var isHalf: Bool { type == .half }
    }

    /// OpenEXR block compressions.
    public enum Compression: UInt8, Sendable, CaseIterable, Hashable {
        case none = 0, rle, zips, zip, piz, pxr24, b44, b44a, dwaa, dwab, htj2k256, htj2k32

        public var name: String {
            switch self {
            case .none: "NONE"
            case .rle: "RLE"
            case .zips: "ZIPS"
            case .zip: "ZIP"
            case .piz: "PIZ"
            case .pxr24: "PXR24"
            case .b44: "B44"
            case .b44a: "B44A"
            case .dwaa: "DWAA"
            case .dwab: "DWAB"
            case .htj2k256: "HTJ2K256"
            case .htj2k32: "HTJ2K32"
            }
        }

        /// Scan lines per block of a scan-line part.
        public var linesPerBlock: Int {
            switch self {
            case .none, .rle, .zips: 1
            case .zip, .pxr24: 16
            case .piz, .b44, .b44a, .dwaa, .htj2k32: 32
            case .dwab, .htj2k256: 256
            }
        }

        /// Whether this reader decodes blocks of this compression.
        public var isDecodable: Bool { EXRParts.decodableCompressions.contains(self) }
    }

    /// The compressions whose blocks decode here (the others list but refuse to decode).
    public static let decodableCompressions: Set<Compression> = [.none, .rle, .zips, .zip, .piz, .pxr24, .b44, .b44a]

    /// One part of a (multi-part) OpenEXR file: header facts only, no pixel data (photocraft
    /// `ExrPartInfo`). The index is what `decodePart` takes.
    public struct PartInfo: Equatable, Sendable {
        /// Index into the part list, in file order.
        public var index: Int
        /// The part `name` attribute, when the file records one (Arnold names parts after AOVs).
        public var name: String?
        /// The part `view` attribute for stereo files (`left`/`right`).
        public var view: String?
        /// The data window's size.
        public var width: UInt32
        public var height: UInt32
        /// `deepscanline`/`deeptile` parts are listed but not decoded.
        public var deep: Bool
        /// Stored as tiles instead of scan lines.
        public var tiled: Bool
        /// The part's channels in file order.
        public var channels: [ChannelInfo]
        public var compression: Compression

        /// How much this part looks like a colour image the plain decode can show: 4 RGBA, 3 RGB,
        /// 2 YA, 1 any-single-channel, 0 anything else (photocraft `color_rank`).
        public var colorRank: UInt8 {
            func has(_ n: String) -> Bool { channels.contains { EXRParts.channelBase($0.name) == n } }
            if has("R") && has("G") && has("B") { return has("A") ? 4 : 3 }
            if has("Y") { return has("A") ? 2 : 1 }
            return channels.count == 1 ? 1 : 0
        }
    }

    /// Channel layout of a decoded image.
    public enum Layout: Sendable, Equatable {
        case gray, grayAlpha, rgb, rgba

        public var channels: Int {
            switch self {
            case .gray: 1
            case .grayAlpha: 2
            case .rgb: 3
            case .rgba: 4
            }
        }
    }

    /// A decoded part or channel set (photocraft-codecs `Image` from the EXR decoder).
    public struct Image: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var layout: Layout
        /// Every colour channel was stored as half floats (photocraft `SampleType::F16`).
        public var half: Bool
        /// Interleaved samples, values as stored (EXR is linear light; nothing is premultiplied
        /// or straightened), uint channels converted to float.
        public var samples: [Float]

        public init(width: Int, height: Int, layout: Layout, half: Bool, samples: [Float]) {
            self.width = width; self.height = height; self.layout = layout; self.half = half; self.samples = samples
        }
    }

    // MARK: - Errors (photocraft-codecs `CodecError` texts, wrapped as `IoError::Codec`)

    static func malformed(_ message: String) -> PCIOError { .codec("OpenExr: malformed data: \(message)") }
    static func codecUnsupported(_ reason: String) -> PCIOError { .codec("OpenExr: \(reason)") }
    static func limitExceeded(_ message: String) -> PCIOError { .codec("limit exceeded: \(message)") }

    // MARK: - Limits (photocraft-codecs `Limits::default()` on 64-bit targets)

    static let maxDimension = 1 << 18
    static let maxPixels = 1 << 30
    static let maxAlloc = 8 << 30

    /// photocraft-codecs `Limits::check_bytes`.
    static func checkBytes(_ w: UInt32, _ h: UInt32, _ bytesPerPixel: Int) throws {
        if w == 0 || h == 0 { throw PCIOError.codec("invalid image: zero-sized image \(w)x\(h)") }
        if Int(w) > maxDimension || Int(h) > maxDimension {
            throw limitExceeded("dimensions \(w)x\(h) exceed max \(maxDimension)x\(maxDimension)")
        }
        let pixels = Int(w) * Int(h)
        if pixels > maxPixels { throw limitExceeded("\(pixels) pixels exceed max \(maxPixels)") }
        let (bytes, overflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        if overflow || bytes > maxAlloc { throw limitExceeded("\(overflow ? Int.max : bytes) bytes exceed max_alloc \(maxAlloc)") }
    }

    // MARK: - Headers

    /// Level structure of a tiled part.
    struct TileDescription {
        var xSize: Int
        var ySize: Int
        /// 0 one level, 1 mipmap, 2 ripmap.
        var levelMode: UInt8
        /// 0 round down, 1 round up.
        var roundingMode: UInt8
    }

    /// One part's header.
    struct Header {
        var channels: [ChannelInfo] = []
        var compression: Compression = .none
        /// Inclusive data window.
        var x0 = 0, y0 = 0, x1 = -1, y1 = -1
        var lineOrder: UInt8 = 0
        var tiles: TileDescription?
        var name: String?
        var view: String?
        var type: String?
        var chunkCount: Int?
        /// Text attributes not modelled above, in file order (Cryptomatte metadata).
        var texts: [(name: String, value: String)] = []
        var deep = false
        var tiled = false

        var width: Int { x1 - x0 + 1 }
        var height: Int { y1 - y0 + 1 }
        /// The data window size as photocraft lists it (saturating to u32).
        var size: (UInt32, UInt32) { (UInt32(clamping: max(0, width)), UInt32(clamping: max(0, height))) }

        func info(_ index: Int) -> PartInfo {
            PartInfo(index: index, name: name, view: view, width: size.0, height: size.1, deep: deep, tiled: tiled, channels: channels,
                     compression: compression)
        }

        func text(_ key: String) -> String? { texts.first { $0.name == key }?.value }
    }

    /// Little-endian cursor that throws on truncation.
    struct LEReader {
        let bytes: [UInt8]
        var pos: Int

        init(_ bytes: [UInt8], at pos: Int = 0) { self.bytes = bytes; self.pos = pos }

        var remaining: Int { bytes.count - pos }

        mutating func u8() throws -> UInt8 {
            guard pos < bytes.count else { throw malformed("unexpected end of file") }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func u32() throws -> UInt32 {
            guard pos >= 0, remaining >= 4 else { throw malformed("unexpected end of file") }
            defer { pos += 4 }
            return UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16 | UInt32(bytes[pos + 3]) << 24
        }

        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

        mutating func u64() throws -> UInt64 {
            let lo = UInt64(try u32()), hi = UInt64(try u32())
            return hi << 32 | lo
        }

        /// A NUL-terminated name of at most `max` bytes.
        mutating func cString(max: Int) throws -> [UInt8] {
            var out: [UInt8] = []
            while true {
                let b = try u8()
                if b == 0 { return out }
                out.append(b)
                if out.count > max { throw malformed("attribute name too long") }
            }
        }

        mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, n <= remaining else { throw malformed("unexpected end of file") }
            defer { pos += n }
            return bytes[pos ..< pos + n]
        }
    }

    /// UTF-8 text, or Latin-1 when the bytes are not UTF-8 (the `exr` crate's `Text`).
    static func text<S: Collection>(_ b: S) -> String where S.Element == UInt8 {
        if let s = String(validating: b, as: UTF8.self) { return s }
        return String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
    }

    /// A parsed file: headers and where the offset tables start.
    struct File {
        let bytes: [UInt8]
        let headers: [Header]
        let multipart: Bool
        /// Byte offset of the first part's offset table.
        let tablesStart: Int
        /// Any part holds deep data (photocraft `requirements.has_deep_data`).
        var hasDeepData: Bool { headers.contains { $0.deep } }

        static func parse(_ bytes: [UInt8]) throws -> File {
            var r = LEReader(bytes)
            guard try r.u32() == 20_000_630 else { throw malformed("not an OpenEXR file (bad magic number)") }
            let version = try r.u32()
            guard version & 0xFF == 2 else { throw codecUnsupported("not supported: OpenEXR file format version \(version & 0xFF)") }
            let singleTiled = version & 0x200 != 0
            let nonImage = version & 0x800 != 0
            let multipart = version & 0x1000 != 0
            // Names are at most 31 bytes, or 255 with the long-names flag (0x400); both read up to 255.
            let maxName = 255
            var headers: [Header] = []
            if multipart {
                while true {
                    guard r.pos < bytes.count else { throw malformed("unexpected end of file") }
                    if bytes[r.pos] == 0 {
                        r.pos += 1
                        break
                    }
                    headers.append(try parseHeader(&r, maxName: maxName, multipart: true, singleTiled: false, nonImage: nonImage))
                    if headers.count > 1 << 16 { throw malformed("too many parts") }
                }
                if headers.isEmpty { throw malformed("a multi-part file without parts") }
            } else {
                headers.append(try parseHeader(&r, maxName: maxName, multipart: false, singleTiled: singleTiled, nonImage: nonImage))
            }
            return File(bytes: bytes, headers: headers, multipart: multipart, tablesStart: r.pos)
        }

        private static func parseHeader(_ r: inout LEReader, maxName: Int, multipart: Bool, singleTiled: Bool, nonImage: Bool) throws -> Header {
            var h = Header()
            var haveChannels = false, haveCompression = false, haveWindow = false
            while true {
                let nameBytes = try r.cString(max: maxName)
                if nameBytes.isEmpty { break }
                let name = text(nameBytes)
                let type = text(try r.cString(max: maxName))
                let size = try r.i32()
                guard size >= 0 else { throw malformed("negative attribute size for \(name)") }
                let value = try r.bytes(Int(size))
                var v = LEReader(Array(value))
                func expect(_ t: String) throws {
                    if type != t { throw malformed("attribute \(name) has type \(type), expected \(t)") }
                }
                switch name {
                case "channels":
                    try expect("chlist")
                    h.channels = try parseChannels(&v, maxName: maxName)
                    haveChannels = true
                case "compression":
                    try expect("compression")
                    let c = try v.u8()
                    guard let comp = Compression(rawValue: c) else { throw malformed("unknown compression method \(c)") }
                    h.compression = comp
                    haveCompression = true
                case "dataWindow":
                    try expect("box2i")
                    h.x0 = Int(try v.i32()); h.y0 = Int(try v.i32()); h.x1 = Int(try v.i32()); h.y1 = Int(try v.i32())
                    haveWindow = true
                case "lineOrder":
                    try expect("lineOrder")
                    h.lineOrder = try v.u8()
                    if h.lineOrder > 2 { throw malformed("unknown line order \(h.lineOrder)") }
                case "tiles":
                    try expect("tiledesc")
                    let xs = try v.u32(), ys = try v.u32(), mode = try v.u8()
                    guard xs >= 1, ys >= 1, xs <= 1 << 30, ys <= 1 << 30 else { throw malformed("invalid tile size \(xs)x\(ys)") }
                    guard mode & 0xF <= 2, mode >> 4 <= 1 else { throw malformed("invalid tile level mode \(mode)") }
                    h.tiles = TileDescription(xSize: Int(xs), ySize: Int(ys), levelMode: mode & 0xF, roundingMode: mode >> 4)
                case "name":
                    try expect("string")
                    h.name = text(value)
                case "view":
                    try expect("string")
                    h.view = text(value)
                case "type":
                    try expect("string")
                    h.type = text(value)
                case "chunkCount":
                    try expect("int")
                    let n = try v.i32()
                    guard n >= 0 else { throw malformed("negative chunk count") }
                    h.chunkCount = Int(n)
                default:
                    if type == "string" { h.texts.append((name, text(value))) }
                }
            }
            guard haveChannels else { throw malformed("missing required attribute channels") }
            guard haveCompression else { throw malformed("missing required attribute compression") }
            guard haveWindow else { throw malformed("missing required attribute dataWindow") }
            guard h.x1 >= h.x0 - 1, h.y1 >= h.y0 - 1 else { throw malformed("invalid data window") }
            switch h.type {
            case nil:
                h.deep = nonImage
                h.tiled = multipart ? h.tiles != nil : singleTiled
            case "scanlineimage": h.tiled = false
            case "tiledimage": h.tiled = true
            case "deepscanline": h.deep = true
            case "deeptile":
                h.deep = true
                h.tiled = true
            case let t?: throw malformed("unknown part type \(t)")
            }
            if h.tiled {
                guard h.tiles != nil else { throw malformed("a tiled part without a tiles attribute") }
                if h.channels.contains(where: { $0.xSampling != 1 || $0.ySampling != 1 }) {
                    throw malformed("tiled parts cannot have subsampled channels")
                }
            }
            return h
        }

        private static func parseChannels(_ v: inout LEReader, maxName: Int) throws -> [ChannelInfo] {
            var out: [ChannelInfo] = []
            while true {
                let name = try v.cString(max: maxName)
                if name.isEmpty { break }
                let t = try v.i32()
                guard let type = PixelType(rawValue: t) else { throw malformed("unknown pixel type \(t)") }
                let linear = try v.u8()
                _ = try v.bytes(3)
                let xs = try v.i32(), ys = try v.i32()
                guard xs >= 1, ys >= 1 else { throw malformed("invalid channel sampling \(xs)x\(ys)") }
                out.append(ChannelInfo(name: text(name), type: type, xSampling: Int(xs), ySampling: Int(ys), perceptuallyLinear: linear != 0))
            }
            return out
        }

        // MARK: Chunk layout

        static func roundLog2(_ x: Int, _ up: Bool) -> Int {
            var n = 0, y = x
            if up {
                var rem = false
                while y > 1 { if y & 1 != 0 { rem = true }; y >>= 1; n += 1 }
                return n + (rem ? 1 : 0)
            }
            while y > 1 { y >>= 1; n += 1 }
            return n
        }

        static func levelSize(_ size: Int, _ level: Int, _ up: Bool) -> Int {
            guard level < 62 else { return 1 }
            let d = 1 << level
            return max(1, up ? (size + d - 1) / d : size / d)
        }

        /// Blocks in the part's offset table: from `chunkCount`, else computed from the header.
        func chunkCount(_ p: Int) -> Int {
            let h = headers[p]
            if let n = h.chunkCount { return n }
            return Self.computedChunks(h)
        }

        static func computedChunks(_ h: Header) -> Int {
            let w = max(0, h.width), ht = max(0, h.height)
            if h.tiled, let t = h.tiles {
                let up = t.roundingMode == 1
                func tiles(_ lw: Int, _ lh: Int) -> Int { ((lw + t.xSize - 1) / t.xSize) * ((lh + t.ySize - 1) / t.ySize) }
                switch t.levelMode {
                case 1:
                    let levels = roundLog2(max(w, ht), up) + 1
                    var n = 0
                    for l in 0 ..< min(levels, 64) { n += tiles(levelSize(w, l, up), levelSize(ht, l, up)) }
                    return n
                case 2:
                    let lx = roundLog2(w, up) + 1, ly = roundLog2(ht, up) + 1
                    var n = 0
                    for y in 0 ..< min(ly, 64) { for x in 0 ..< min(lx, 64) { n += tiles(levelSize(w, x, up), levelSize(ht, y, up)) } }
                    return n
                default:
                    return tiles(w, ht)
                }
            }
            let lpb = h.compression.linesPerBlock
            return (ht + lpb - 1) / lpb
        }

        /// Byte offset of part `p`'s offset table.
        func tableOffset(_ p: Int) throws -> Int {
            var at = tablesStart
            for q in 0 ..< p {
                let (n, o1) = chunkCount(q).multipliedReportingOverflow(by: 8)
                let (s, o2) = at.addingReportingOverflow(n)
                guard !o1, !o2, s <= bytes.count else { throw malformed("offset table out of range") }
                at = s
            }
            return at
        }

        // MARK: Decoding

        /// Decodes level 0 of flat part `p`: one plane per channel in `wanted` (channel indices),
        /// each `numSamples(xSampling)` × `numSamples(ySampling)` floats over the data window.
        func decodePlanes(_ p: Int, _ wanted: [Int]) throws -> [[Float]] {
            let h = headers[p]
            guard !h.deep else { throw codecUnsupported("deep parts are decoded by the deep decoder") }
            guard h.compression.isDecodable else {
                throw codecUnsupported("not supported: \(h.compression.name) compression")
            }
            let channels = h.channels
            let w = h.width, ht = h.height
            guard w > 0, ht > 0 else { throw malformed("empty data window") }
            // Level-0 blocks: the first entries of the part's offset table.
            let blocksX: Int, blocksY: Int, bw: Int, bh: Int
            if h.tiled, let t = h.tiles {
                bw = t.xSize; bh = t.ySize
                blocksX = (w + bw - 1) / bw; blocksY = (ht + bh - 1) / bh
            } else {
                bw = w; bh = h.compression.linesPerBlock
                blocksX = 1; blocksY = (ht + bh - 1) / bh
            }
            let blocks = blocksX * blocksY
            let table = try tableOffset(p)
            guard blocks <= chunkCount(p), table + blocks * 8 <= bytes.count else {
                throw malformed("offset table out of range")
            }
            var filled = [Bool](repeating: false, count: blocks)
            var r = LEReader(bytes, at: table)
            var offsets: [Int] = []
            offsets.reserveCapacity(blocks)
            for _ in 0 ..< blocks {
                let o = try r.u64()
                guard o >= UInt64(tablesStart), o < UInt64(bytes.count) else { throw malformed("chunk offset \(o) out of range") }
                offsets.append(Int(o))
            }
            // Every chunk header is checked, and every block found, before any plane is allocated.
            var chunks: [(x0: Int, y0: Int, data: ArraySlice<UInt8>)] = []
            chunks.reserveCapacity(blocks)
            for o in offsets {
                var c = LEReader(bytes, at: o)
                if multipart {
                    let part = try c.i32()
                    guard Int(part) == p else { throw malformed("chunk of part \(part) in the offset table of part \(p)") }
                }
                let bx0: Int, by0: Int, index: Int
                if h.tiled {
                    let tx = Int(try c.i32()), ty = Int(try c.i32()), lx = try c.i32(), ly = try c.i32()
                    guard lx == 0, ly == 0, tx >= 0, ty >= 0, tx < blocksX, ty < blocksY else {
                        throw malformed("invalid tile coordinates (\(tx), \(ty), level \(lx), \(ly))")
                    }
                    bx0 = h.x0 + tx * bw; by0 = h.y0 + ty * bh
                    index = ty * blocksX + tx
                } else {
                    let y = Int(try c.i32())
                    guard y >= h.y0, y <= h.y1, (y - h.y0) % bh == 0 else { throw malformed("invalid scan line block start \(y)") }
                    bx0 = h.x0; by0 = y
                    index = (y - h.y0) / bh
                }
                let size = try c.i32()
                guard size >= 0 else { throw malformed("negative chunk size") }
                chunks.append((bx0, by0, try c.bytes(Int(size))))
                filled[index] = true
            }
            guard filled.allSatisfy({ $0 }) else { throw malformed("the part is missing blocks") }
            // Plane geometry and the slot of each channel (nil = not wanted).
            var slot = [Int?](repeating: nil, count: channels.count)
            var planes: [[Float]] = []
            var planeWidth: [Int] = []
            for (k, ci) in wanted.enumerated() {
                guard ci >= 0, ci < channels.count else { throw malformed("channel index out of range") }
                slot[ci] = k
                let c = channels[ci]
                let pw = numSamples(c.xSampling, h.x0, h.x1), ph = numSamples(c.ySampling, h.y0, h.y1)
                planes.append([Float](repeating: 0, count: pw * ph))
                planeWidth.append(pw)
            }
            let decoder = BlockDecoder(compression: h.compression, channels: channels)
            for (bx0, by0, packed) in chunks {
                let bx1 = min(bx0 + bw, h.x1 + 1) - 1, by1 = min(by0 + bh, h.y1 + 1) - 1
                let raw = try decoder.decode(packed, x0: bx0, y0: by0, x1: bx1, y1: by1)
                try scatter(raw, h, bx0, by0, bx1, by1, slot, &planes, planeWidth)
            }
            return planes
        }

        /// Writes the samples of one uncompressed block (lines of channels, little-endian) into
        /// the wanted planes.
        private func scatter(_ raw: [UInt8], _ h: Header, _ bx0: Int, _ by0: Int, _ bx1: Int, _ by1: Int, _ slot: [Int?],
                             _ planes: inout [[Float]], _ planeWidth: [Int]) throws {
            var at = 0
            let table = EXRParts.halfTable
            try raw.withUnsafeBufferPointer { src in
                for y in by0 ... by1 {
                    for (ci, c) in h.channels.enumerated() {
                        if modp(y, c.ySampling) != 0 { continue }
                        let n = numSamples(c.xSampling, bx0, bx1)
                        let len = n * c.type.bytes
                        guard at + len <= src.count else { throw malformed("block data too short") }
                        if let k = slot[ci] {
                            let row = numSamples(c.ySampling, h.y0, y) - 1
                            let col = numSamples(c.xSampling, h.x0, bx0 - 1)
                            let base = row * planeWidth[k] + col
                            guard row >= 0, col >= 0, base + n <= planes[k].count else { throw malformed("block outside the data window") }
                            planes[k].withUnsafeMutableBufferPointer { dst in
                                switch c.type {
                                case .half:
                                    for i in 0 ..< n {
                                        let v = UInt16(src[at + 2 * i]) | UInt16(src[at + 2 * i + 1]) << 8
                                        dst[base + i] = table[Int(v)]
                                    }
                                case .float:
                                    for i in 0 ..< n {
                                        let o = at + 4 * i
                                        let v = UInt32(src[o]) | UInt32(src[o + 1]) << 8 | UInt32(src[o + 2]) << 16 | UInt32(src[o + 3]) << 24
                                        dst[base + i] = Float(bitPattern: v)
                                    }
                                case .uint:
                                    for i in 0 ..< n {
                                        let o = at + 4 * i
                                        let v = UInt32(src[o]) | UInt32(src[o + 1]) << 8 | UInt32(src[o + 2]) << 16 | UInt32(src[o + 3]) << 24
                                        dst[base + i] = Float(v)
                                    }
                                }
                            }
                        }
                        at += len
                    }
                }
            }
            guard at == raw.count else { throw malformed("block data size mismatch") }
        }
    }

    // MARK: - Sampling arithmetic (OpenEXR ImfMisc)

    /// Floor division for a positive divisor.
    @inline(__always) static func divp(_ x: Int, _ y: Int) -> Int { x >= 0 ? x / y : -((y - 1 - x) / y) }

    /// Mathematical modulo for a positive divisor.
    @inline(__always) static func modp(_ x: Int, _ y: Int) -> Int { x - y * divp(x, y) }

    /// Samples of a channel with sampling `s` in [a, b].
    @inline(__always) static func numSamples(_ s: Int, _ a: Int, _ b: Int) -> Int {
        let n = divp(b, s) - divp(a - 1, s)
        return max(0, n)
    }

    /// Half floats to floats, every bit pattern (NaNs quieted, as the `half` crate does).
    static let halfTable: [Float] = (0 ..< 65536).map { halfToFloat(UInt16($0)) }

    static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = Int(h >> 10 & 0x1F)
        let mant = UInt32(h & 0x3FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            let v = Float(mant) * (1.0 / 16_777_216.0)
            return sign != 0 ? -v : v
        }
        if exp == 31 {
            return Float(bitPattern: sign | 0x7F80_0000 | (mant == 0 ? 0 : 0x0040_0000 | mant << 13))
        }
        return Float(bitPattern: sign | UInt32(exp - 15 + 127) << 23 | mant << 13)
    }

    // MARK: - Codec-level API (photocraft-codecs `exr_info`, `decode_exr_part`, `decode_exr_channels`)

    /// The headers after photocraft's `read_meta` checks: every part's declared size against the
    /// limits, and all parts together (flat decoding may read every part).
    static func readMeta(_ bytes: [UInt8]) throws -> File {
        let file = try File.parse(bytes)
        var total = 0
        for h in file.headers {
            let (w, ht) = h.size
            let bpp = max(1, h.channels.count) * 4
            try checkBytes(w, ht, bpp)
            total = total.addingReportingOverflow(Int(w) * Int(ht) * bpp).overflow ? Int.max : total + Int(w) * Int(ht) * bpp
        }
        if total > maxAlloc {
            throw limitExceeded("\(total) bytes across \(file.headers.count) parts exceed max_alloc \(maxAlloc)")
        }
        return file
    }

    /// Lists every part of an OpenEXR file (header facts only, no pixel data).
    public static func info(_ bytes: [UInt8]) throws -> [PartInfo] {
        let file = try readMeta(bytes)
        return file.headers.enumerated().map { $1.info($0) }
    }

    /// Decodes part `index` (into `info`'s list): R/G/B(/A) as RGB(A), else Y(/A) or a single
    /// channel as gray (photocraft `decode_exr_part`). Files with deep parts are refused.
    public static func decodePart(_ bytes: [UInt8], _ index: Int) throws -> Image {
        let file = try readMeta(bytes)
        if file.hasDeepData {
            throw codecUnsupported("this file has deep parts; the deep decoder composites those (mixing flat and deep parts is not supported)")
        }
        guard index >= 0, index < file.headers.count else {
            throw malformed("part index \(index) is out of range (\(file.headers.count) parts)")
        }
        let h = file.headers[index]
        let channels = h.channels
        func find(_ n: String) -> Int? { channels.firstIndex { channelBase($0.name) == n } }
        let picks: [Int], layout: Layout
        if let r = find("R"), let g = find("G"), let b = find("B") {
            if let a = find("A") { picks = [r, g, b, a]; layout = .rgba } else { picks = [r, g, b]; layout = .rgb }
        } else if let y = find("Y") ?? (channels.count == 1 ? 0 : nil) {
            if let a = find("A") { picks = [y, a]; layout = .grayAlpha } else { picks = [y]; layout = .gray }
        } else {
            throw codecUnsupported("no R/G/B or Y channels")
        }
        return try image(file, index, picks, layout)
    }

    /// Decodes the named channels of one flat part (exact names as stored, e.g. `diffuse.R`):
    /// R/G/B (plus A when named) give RGB(A), a Y gives gray (photocraft `decode_exr_channels`).
    public static func decodeChannels(_ bytes: [UInt8], _ index: Int, _ names: [String]) throws -> Image {
        let file = try readMeta(bytes)
        if file.hasDeepData {
            throw codecUnsupported("this file has deep parts; the deep decoder composites those (mixing flat and deep parts is not supported)")
        }
        guard index >= 0, index < file.headers.count else {
            throw malformed("part index \(index) is out of range (\(file.headers.count) parts)")
        }
        let channels = file.headers[index].channels
        var picked: [Int] = []
        for name in names {
            guard let i = channels.firstIndex(where: { $0.name == name }) else { throw malformed("the part has no channel \(name)") }
            picked.append(i)
        }
        func at(_ n: String) -> Int? { picked.first { channelBase(channels[$0].name) == n } }
        let picks: [Int], layout: Layout
        if let r = at("R"), let g = at("G"), let b = at("B") {
            if let a = at("A") { picks = [r, g, b, a]; layout = .rgba } else { picks = [r, g, b]; layout = .rgb }
        } else if let y = at("Y") {
            if let a = at("A") { picks = [y, a]; layout = .grayAlpha } else { picks = [y]; layout = .gray }
        } else if picked.count == 1 {
            picks = [picked[0]]; layout = .gray
        } else {
            throw codecUnsupported("the named channels are no R/G/B or Y set")
        }
        // Every named channel must hold one sample per pixel, used or not.
        for i in picked where channels[i].xSampling != 1 || channels[i].ySampling != 1 {
            throw malformed("channel sample count mismatch (subsampled channels are unsupported)")
        }
        return try image(file, index, picks, layout)
    }

    /// Interleaves the decoded planes of `picks` (one sample per pixel each).
    private static func image(_ file: File, _ index: Int, _ picks: [Int], _ layout: Layout) throws -> Image {
        let h = file.headers[index]
        for i in picks where h.channels[i].xSampling != 1 || h.channels[i].ySampling != 1 {
            throw malformed("channel sample count mismatch (subsampled channels are unsupported)")
        }
        let unique = Array(Set(picks)).sorted()
        let planes = try file.decodePlanes(index, unique)
        let w = h.width, ht = h.height
        let n = w * ht
        let nc = picks.count
        var out = [Float](repeating: 0, count: n * nc)
        out.withUnsafeMutableBufferPointer { o in
            for (k, ci) in picks.enumerated() {
                guard let u = unique.firstIndex(of: ci) else { continue }
                planes[u].withUnsafeBufferPointer { src in
                    for i in 0 ..< n { o[i * nc + k] = src[i] }
                }
            }
        }
        let half = picks.allSatisfy { h.channels[$0].type == .half }
        return Image(width: w, height: ht, layout: layout, half: half, samples: out)
    }

    /// The base channel name (`R` of `diffuse.R`, `R` of `R`).
    static func channelBase(_ name: String) -> Substring {
        if let dot = name.lastIndex(of: ".") { return name[name.index(after: dot)...] }
        return name[...]
    }
}
