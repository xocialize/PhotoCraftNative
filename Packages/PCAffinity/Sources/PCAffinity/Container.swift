// Port of photocraft-affinity (crates/affinity/src/container.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
// The Affinity archive: header, the chain of file allocation tables (one per save) and bounded,
// CRC-checked extraction of named entries such as `doc.dat` and raster tiles.

extension Affinity {
    /// The container signature `00 FF 4B 41` (documents and libraries share it).
    public static let magic: [UInt8] = [0x00, 0xFF, 0x4B, 0x41]
    /// Oldest and newest container versions seen in real documents (Affinity 1.x writes 8,
    /// Affinity 3 writes 12). Version 7 is described by afread but no sample exists.
    public static let versions: ClosedRange<UInt16> = 8...12
    /// `Prsn` (stored byte-reversed): documents. Asset, brush and style libraries share the magic.
    static let documentKind: [UInt8] = Array("nsrP".utf8)

    /// A save appends one table; real files have one to a few hundred.
    static let maxTables = 4096
    /// zstd window ceiling: real documents use a few MiB; this stops a header from reserving gigabytes.
    static let maxZstdWindow: UInt64 = 64 << 20

    /// Decompression budget for one import. Every entry declares its size, which is checked against
    /// these limits before anything is allocated, and the decoded length must match it exactly.
    public struct Limits: Hashable, Sendable {
        /// Largest single entry (`doc.dat` or one tile).
        public var maxEntry: Int
        /// Total bytes extracted over the whole import.
        public var maxTotal: Int

        public init(maxEntry: Int = 256 << 20, maxTotal: Int = 1 << 30) {
            self.maxEntry = maxEntry
            self.maxTotal = maxTotal
        }

        public static let `default` = Limits()
    }

    /// The container header, all integers little-endian.
    public struct Header: Hashable, Sendable {
        public var version: UInt16
        /// Seen as 0, 4 or 8 in real files; bits 0 and 1 mark container variants that are rejected.
        public var flags: UInt16
        package var fatOffset: UInt64
        package var thumbnailOffset: UInt64
        /// Save time in Unix seconds, as written by the application.
        public var saved: UInt32
    }

    /// One FAT record, as of the newest table that mentions its id.
    public struct Entry: Hashable, Sendable {
        public var id: UInt32
        public var name: String
        var offset: UInt64
        var storedSize: UInt64
        var compressed: UInt64
        var crc: UInt32
        var compression: UInt8

        /// Decompressed size declared by the table.
        public var size: UInt64 { storedSize }
    }

    /// True when `bytes` start with the Affinity container signature (documents and libraries).
    public static func isAffinity(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0..<4].elementsEqual(magic)
    }

    /// Check the signature, version and document kind.
    public static func header(_ bytes: [UInt8]) throws(AffinityError) -> Header {
        guard isAffinity(bytes) else { throw .malformed("missing container signature") }
        var c = ByteCursor(bytes, at: 4)
        let version = try c.u16()
        let flags = try c.u16()
        guard versions.contains(version) else { throw .unsupported("unknown container version") }
        guard flags & 3 == 0 else { throw .unsupported("container variant") }
        guard try c.take(4).elementsEqual(documentKind) else {
            throw .unsupported("this Affinity file is a library (assets, brushes or styles), not a document")
        }
        guard try c.take(4).elementsEqual("#Inf".utf8) else { throw .malformed("missing information header") }
        let fatOffset = try c.u64()
        let thumbnailOffset = try c.u64()
        _ = try c.take(16)
        let saved = UInt32(exactly: try c.u64()) ?? 0
        _ = try c.take(8)
        guard try c.take(4).elementsEqual("Prot".utf8) else { throw .malformed("missing protocol header") }
        return Header(version: version, flags: flags, fatOffset: fatOffset, thumbnailOffset: thumbnailOffset, saved: saved)
    }

    /// An opened container: the head revision of every named entry, extracted on demand within
    /// `Limits`.
    public struct Archive: Sendable {
        let bytes: [UInt8]
        public let header: Header
        /// Head revision of every named, non-deleted entry.
        var entries: [String: Entry]
        /// Number of tables (saves) in the chain.
        public let revisions: Int
        /// Bytes extracted so far, counted against `Limits.maxTotal`.
        public private(set) var extracted: Int = 0
        let limits: Limits

        public init(_ bytes: [UInt8], limits: Limits = .default) throws(AffinityError) {
            let header = try Affinity.header(bytes)
            // Newest record per id: (table date, record).
            var latest: [UInt32: (date: UInt64, record: Entry?)] = [:]
            var names: [UInt32: String] = [:]
            var seen = Set<UInt64>()
            var next = header.fatOffset
            var tables = 0
            while next != 0 {
                guard seen.insert(next).inserted else { throw .malformed("allocation tables form a cycle") }
                tables += 1
                guard tables <= maxTables else { throw .limit("too many saved revisions") }
                var c = ByteCursor(bytes, at: try offset(next))
                let level: Int
                switch Array(try c.take(4)) {
                case Array("#FAT".utf8): level = 1
                case Array("#FT2".utf8): level = 2
                case Array("#FT3".utf8): level = 3
                case Array("#FT4".utf8): level = 4
                default: throw .malformed("missing allocation table")
                }
                next = try c.u64()
                let date = try c.u64()
                _ = try c.take(24)
                let files = try c.u32()
                _ = try c.take(8)
                let dirs = try c.u16()
                _ = try c.take(1)
                for _ in 0..<files {
                    let id = try c.u32()
                    let flag = try c.u8()
                    var record: Entry?
                    switch flag {
                    case 0, 1:
                        let offset = try c.u64()
                        let size = try c.u64()
                        let compressed = try c.u64()
                        let crc = try c.u32()
                        let stored = try c.u8()
                        if level >= 2 { _ = try c.take(4) }
                        if level >= 4 { _ = try c.take(4) }
                        // Old tables number the methods; newer ones store the method byte itself.
                        let compression: UInt8
                        if level <= 2 {
                            switch stored {
                            case 1: compression = 0x01
                            case 2: compression = 0x41
                            case 3: compression = 0x81
                            case 4: compression = 0xC1
                            default: compression = 0
                            }
                        } else {
                            compression = stored
                        }
                        record = Entry(id: id, name: "", offset: offset, storedSize: size, compressed: compressed, crc: crc, compression: compression)
                    case 2:
                        break
                    default:
                        throw .malformed("unknown allocation record")
                    }
                    if flag == 0 {
                        let len = Int(try c.u16())
                        let name = Affinity.lossy(try c.take(len))
                        if names[id] == nil { names[id] = name }
                    }
                    // Equal dates: the first table in the chain (the newest) wins, as in afread.
                    if let current = latest[id], date <= current.date {
                        // keep the newer record
                    } else {
                        latest[id] = (date, record)
                    }
                }
                for _ in 0..<dirs {
                    let len = Int(try c.u16())
                    _ = try c.take(10)
                    _ = try c.take(len)
                }
            }
            var entries: [String: Entry] = [:]
            // photocraft iterates a hash map here; ids are visited in ascending order so that two ids
            // sharing a name resolve the same way on every run (the higher id wins).
            for id in latest.keys.sorted() {
                if let rec = latest[id]?.record, let name = names[id] {
                    var e = rec
                    e.name = name
                    entries[name] = e
                }
            }
            self.bytes = bytes
            self.header = header
            self.entries = entries
            self.revisions = tables
            self.limits = limits
        }

        public func entry(_ name: String) -> Entry? {
            entries[name]
        }

        /// Names of every entry, sorted.
        public var entryNames: [String] {
            entries.keys.sorted()
        }

        /// Extract an entry by name: decompress, undo the byte predictor and verify the CRC.
        public mutating func read(_ name: String) throws(AffinityError) -> [UInt8] {
            guard let e = entries[name] else { throw .malformed("missing archive entry") }
            guard let size = Int(exactly: e.storedSize), size <= limits.maxEntry else {
                throw .limit("archive entry too large")
            }
            let (total, overflow) = extracted.addingReportingOverflow(size)
            guard !overflow, total <= limits.maxTotal else { throw .limit("document too large") }
            var c = ByteCursor(bytes, at: try offset(e.offset))
            guard try c.take(4).elementsEqual("#Fil".utf8) else { throw .malformed("archive entry has no data block") }
            let method = e.compression & 3
            let storedLength = method == 1 || method == 2 ? e.compressed : e.storedSize
            let data = try c.take(try offset(storedLength))
            var out: [UInt8]
            switch method {
            case 1: out = try Zlib.inflate(data, size: size)
            case 2: out = try Zstd.decompress(data, size: size, maxWindow: maxZstdWindow)
            default: out = Array(data)
            }
            guard out.count == size else { throw .malformed("archive entry size mismatch") }
            try unpredict(&out, e.compression)
            guard Checksum.crc32(out) == e.crc else { throw .malformed("archive entry checksum mismatch") }
            extracted = total
            return out
        }
    }

    static func offset(_ v: UInt64) throws(AffinityError) -> Int {
        guard let o = Int(exactly: v) else { throw .malformed("offset beyond addressable memory") }
        return o
    }

    /// Undo the byte predictor selected by the high bits of the compression byte.
    static func unpredict(_ b: inout [UInt8], _ compression: UInt8) throws(AffinityError) {
        switch (compression & 0xC0, compression & 0x20 != 0) {
        case (0x00, _):
            break
        case (0x40, _):
            byteDelta(&b)
        case (0x80, false):
            var prev: UInt16 = 0
            var i = 0
            while i + 1 < b.count {
                let v = (UInt16(b[i]) | UInt16(b[i + 1]) << 8) &+ prev
                b[i] = UInt8(truncatingIfNeeded: v)
                b[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                prev = v
                i += 2
            }
        case (0x80, true):
            byteDelta(&b)
            // A 64 KiB tile of 16-bit samples is stored as all high bytes, then all low bytes.
            if b.count == 0x10000 {
                let planes = b
                for i in 0..<0x4000 {
                    let (h0, h1) = (planes[2 * i], planes[2 * i + 1])
                    let (l0, l1) = (planes[0x8000 + 2 * i], planes[0x8000 + 2 * i + 1])
                    b[4 * i] = l0
                    b[4 * i + 1] = h0
                    b[4 * i + 2] = l1
                    b[4 * i + 3] = h1
                }
            }
        default:
            throw .unsupported("archive entry predictor")
        }
    }

    static func byteDelta(_ b: inout [UInt8]) {
        var prev: UInt8 = 0
        for i in b.indices {
            b[i] = b[i] &+ prev
            prev = b[i]
        }
    }
}

/// A bounds-checked little-endian reader over a byte array (photocraft's `Cursor`). The position may
/// start beyond the end; every read then fails as truncated.
package struct ByteCursor {
    package let bytes: [UInt8]
    package var pos: Int

    package init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    package var remaining: Int { max(0, bytes.count - pos) }

    package mutating func take(_ n: Int) throws(AffinityError) -> ArraySlice<UInt8> {
        let (end, overflow) = pos.addingReportingOverflow(n)
        guard !overflow, n >= 0 else { throw .malformed("length overflow") }
        guard pos >= 0, pos <= bytes.count, end <= bytes.count else { throw .malformed("truncated data") }
        defer { pos = end }
        return bytes[pos..<end]
    }

    package mutating func u8() throws(AffinityError) -> UInt8 {
        guard pos >= 0, pos < bytes.count else { throw .malformed("truncated data") }
        defer { pos += 1 }
        return bytes[pos]
    }

    package mutating func u16() throws(AffinityError) -> UInt16 {
        UInt16(truncatingIfNeeded: try le(2))
    }

    package mutating func u32() throws(AffinityError) -> UInt32 {
        UInt32(truncatingIfNeeded: try le(4))
    }

    package mutating func u64() throws(AffinityError) -> UInt64 {
        try le(8)
    }

    private mutating func le(_ n: Int) throws(AffinityError) -> UInt64 {
        let s = try take(n)
        var v: UInt64 = 0
        var shift: UInt64 = 0
        for b in s {
            v |= UInt64(b) << shift
            shift += 8
        }
        return v
    }
}
