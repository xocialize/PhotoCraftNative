// Minimal ZIP container: STORE entries are written (`.pcraft` payloads are already compressed;
// OpenRaster's `mimetype` must be stored); STORE or DEFLATE entries are read, so a bundle that was
// unzipped and re-zipped by another tool still loads, and OpenRaster/Krita archives open.
//
// ZIP64 (APPNOTE 6.3.10 §4.3.14–4.3.16, §4.5.3) is written only when an archive outgrows the
// classic fields: 65,535 entries, or 4 GiB for an entry, an offset or the central directory. An
// archive that fits is byte for byte the classic layout photocraft writes, so readers without
// ZIP64 still open it. ZIP64 from any writer is read. No encryption, no multi-disk archives.
// Port of photocraft-format (crates/format/src/zip.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors; ZIP64 is this port's (`.pcraft` format 2). DEFLATE through Apple's
// Compression framework (`Deflate`).

import Foundation

private let localSignature: UInt32 = 0x0403_4B50
private let centralSignature: UInt32 = 0x0201_4B50
private let endSignature: UInt32 = 0x0605_4B50
private let zip64EndSignature: UInt32 = 0x0606_4B50
private let zip64LocatorSignature: UInt32 = 0x0706_4B50
/// Header id of the ZIP64 extended information extra field.
private let zip64ExtraId = 1
/// Classic field values that mean "see the ZIP64 record". A value equal to one is ambiguous, so
/// it, too, goes to ZIP64.
private let max16 = 0xFFFF
private let max32 = 0xFFFF_FFFF
/// "Version needed to extract": 2.0 classic, 4.5 for ZIP64 records.
private let versionClassic: UInt16 = 20
private let versionZip64: UInt16 = 45

/// Writer for STORE entries (and optionally DEFLATE ones), as classic ZIP or, when the archive
/// needs it, ZIP64.
public struct ZipWriter: Sendable {
    private var out: [UInt8] = []
    private var central: [UInt8] = []
    private var count = 0
    private var entryUsedZip64 = false
    private let forceZip64: Bool

    /// `forceZip64` writes every ZIP64 field (each size and offset, and the ZIP64 end records) even
    /// where the classic one fits: for tests and interop checks of small archives.
    public init(forceZip64: Bool = false) { self.forceZip64 = forceZip64 }

    /// Bytes written so far (local headers and data).
    public var size: Int { out.count }

    /// Whether the archive, if finished now, has ZIP64 records.
    public var usesZip64: Bool {
        forceZip64 || entryUsedZip64 || count >= max16 || out.count >= max32 || central.count >= max32
    }

    /// Reserves room for `bytes` of local headers and data (an archive's expected size), so a
    /// multi-gigabyte archive isn't regrown and copied as it is written.
    public mutating func reserveCapacity(_ bytes: Int) { out.reserveCapacity(bytes) }

    /// Whether STORE entries with these name lengths (UTF-8 bytes) and sizes, in this order, make a
    /// classic archive: `usesZip64` is false after adding exactly them (without `forceZip64`).
    public static func fitsClassic(_ entries: some Sequence<(nameLength: Int, size: Int)>) -> Bool {
        var count = 0, local = 0, cd = 0
        for e in entries {
            if e.size >= max32 || local >= max32 { return false }
            local += 30 + e.nameLength + e.size
            cd += 46 + e.nameLength
            count += 1
        }
        return count < max16 && local < max32 && cd < max32
    }

    /// Adds a STORE entry.
    public mutating func add(_ name: String, _ data: [UInt8]) throws {
        try add(name, data, compress: false)
    }

    /// Adds an entry, DEFLATE-compressed when `compress` and it saves space.
    public mutating func add(_ name: String, _ data: [UInt8], compress: Bool) throws {
        let crc = CRC32.checksum(data)
        if compress, let d = try? Deflate.deflate(data), d.count < data.count {
            try append(name, d, method: 8, crc: crc, uncompressedSize: data.count)
        } else {
            try append(name, data, method: 0, crc: crc, uncompressedSize: data.count)
        }
    }

    /// Adds a STORE entry whose CRC-32 the caller already has (computed in parallel, or kept from
    /// an earlier save). `crc` must be `CRC32.checksum(data)`.
    public mutating func addStored(_ name: String, _ data: [UInt8], crc: UInt32) throws {
        try append(name, data, method: 0, crc: crc, uncompressedSize: data.count)
    }

    private mutating func append(_ name: String, _ payload: [UInt8], method: UInt16, crc: UInt32, uncompressedSize usize: Int) throws {
        let nameBytes = Array(name.utf8)
        guard nameBytes.count <= max16 else { throw PCIOError.unsupported("zip entry name too long") }
        let offset = out.count, csize = payload.count
        // The local header carries both sizes in its ZIP64 field or neither (§4.5.3); the central
        // one carries the sizes and the offset that overflow, in that order.
        let sizes64 = forceZip64 || usize >= max32 || csize >= max32
        let offset64 = forceZip64 || offset >= max32
        let needed = sizes64 || offset64 ? versionZip64 : versionClassic
        if sizes64 || offset64 { entryUsedZip64 = true }
        // Local file header.
        le32(&out, localSignature)
        le16(&out, sizes64 ? versionZip64 : versionClassic) // version needed
        le16(&out, 0x0800) // flags: UTF-8 names
        le16(&out, method)
        le16(&out, 0) // time
        le16(&out, 0x21) // date: 1980-01-01
        le32(&out, crc)
        le32(&out, sizes64 ? UInt32(max32) : UInt32(csize))
        le32(&out, sizes64 ? UInt32(max32) : UInt32(usize))
        le16(&out, UInt16(nameBytes.count))
        le16(&out, sizes64 ? 20 : 0) // extra length
        out += nameBytes
        if sizes64 {
            le16(&out, UInt16(zip64ExtraId))
            le16(&out, 16)
            le64(&out, UInt64(usize))
            le64(&out, UInt64(csize))
        }
        out += payload
        // Central directory entry.
        let extraLength = (sizes64 ? 16 : 0) + (offset64 ? 8 : 0)
        le32(&central, centralSignature)
        le16(&central, needed) // made by (MS-DOS attributes, this spec version)
        le16(&central, needed)
        le16(&central, 0x0800)
        le16(&central, method)
        le16(&central, 0)
        le16(&central, 0x21)
        le32(&central, crc)
        le32(&central, sizes64 ? UInt32(max32) : UInt32(csize))
        le32(&central, sizes64 ? UInt32(max32) : UInt32(usize))
        le16(&central, UInt16(nameBytes.count))
        le16(&central, extraLength == 0 ? 0 : UInt16(4 + extraLength))
        central += [UInt8](repeating: 0, count: 6) // comment len, disk, internal attrs
        le32(&central, 0) // external attrs
        le32(&central, offset64 ? UInt32(max32) : UInt32(offset))
        central += nameBytes
        if extraLength > 0 {
            le16(&central, UInt16(zip64ExtraId))
            le16(&central, UInt16(extraLength))
            if sizes64 {
                le64(&central, UInt64(usize))
                le64(&central, UInt64(csize))
            }
            if offset64 { le64(&central, UInt64(offset)) }
        }
        count += 1
    }

    /// The finished archive.
    public consuming func finish() throws -> [UInt8] {
        let zip64 = usesZip64
        let cdOffset = out.count, cdSize = central.count
        // Appended in place: copying a multi-gigabyte archive here would double its memory.
        var o: [UInt8] = []
        swap(&o, &out)
        o.reserveCapacity(o.count + central.count + 56 + 20 + 22)
        o += central
        central = []
        if zip64 {
            // ZIP64 end of central directory record and its locator (§4.3.14, §4.3.15).
            let record = o.count
            le32(&o, zip64EndSignature)
            le64(&o, 44) // size of the rest of the record
            le16(&o, versionZip64) // made by
            le16(&o, versionZip64) // needed
            le32(&o, 0) // this disk
            le32(&o, 0) // disk with the central directory
            le64(&o, UInt64(count)) // entries on this disk
            le64(&o, UInt64(count))
            le64(&o, UInt64(cdSize))
            le64(&o, UInt64(cdOffset))
            le32(&o, zip64LocatorSignature)
            le32(&o, 0) // disk with the ZIP64 end record
            le64(&o, UInt64(record))
            le32(&o, 1) // total disks
        }
        // The classic end record; a field that doesn't fit (or every field, when forced) says
        // "see ZIP64" (§4.4.1.4).
        let entries16 = forceZip64 || count >= max16 ? UInt16(max16) : UInt16(count)
        le32(&o, endSignature)
        o += [0, 0, 0, 0] // disk numbers
        le16(&o, entries16)
        le16(&o, entries16)
        le32(&o, forceZip64 || cdSize >= max32 ? UInt32(max32) : UInt32(cdSize))
        le32(&o, forceZip64 || cdOffset >= max32 ? UInt32(max32) : UInt32(cdOffset))
        le16(&o, 0)
        return o
    }
}

private func le16(_ o: inout [UInt8], _ v: UInt16) { o += [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func le32(_ o: inout [UInt8], _ v: UInt32) { o += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
private func le64(_ o: inout [UInt8], _ v: UInt64) { le32(&o, UInt32(v & 0xFFFF_FFFF)); le32(&o, UInt32(v >> 32)) }

/// One entry of a `ZipReader`.
public struct ZipEntry: Hashable, Sendable {
    public var name: String
    public var method: UInt16
    public var crc: UInt32
    public var compressedSize: Int
    public var uncompressedSize: Int
    public var dataOffset: Int
}

/// Read-only view of an archive in memory.
public struct ZipReader: Sendable {
    public let bytes: [UInt8]
    /// All entries, in central-directory order.
    public let entries: [ZipEntry]
    /// Whether the archive has a ZIP64 end of central directory record.
    public let isZip64: Bool
    /// Name → index of the first entry with that name (duplicates: the first wins).
    private let byName: [String: Int]

    static func u16(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o <= b.count - 2 else { throw PCIOError.corrupt("truncated zip") }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }

    static func u32(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o <= b.count - 4 else { throw PCIOError.corrupt("truncated zip") }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// A ZIP64 count, size or offset; one beyond `Int.max` is corrupt.
    static func u64(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o <= b.count - 8 else { throw PCIOError.corrupt("truncated zip") }
        var v: UInt64 = 0
        for k in 0 ..< 8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
        guard let i = Int(exactly: v) else { throw PCIOError.corrupt("zip64 value \(v) out of range") }
        return i
    }

    /// The ZIP64 end record's (entries, central directory size, central directory offset, record
    /// offset), when a valid locator precedes the end record at `eocd`.
    static func zip64End(_ bytes: [UInt8], eocd: Int) throws -> (count: Int, cdSize: Int, cdOffset: Int, record: Int)? {
        let locator = eocd - 20
        guard locator >= 0, (try? u32(bytes, locator)) == Int(zip64LocatorSignature) else { return nil }
        let record = try u64(bytes, locator + 8)
        guard record <= locator - 56, try u32(bytes, record) == Int(zip64EndSignature) else {
            throw PCIOError.corrupt("zip64 end of central directory out of range")
        }
        // Total entries, central directory size and offset.
        return (try u64(bytes, record + 32), try u64(bytes, record + 40), try u64(bytes, record + 48), record)
    }

    /// The bounds of the ZIP64 extended information field among the extra fields in `range`.
    static func zip64Extra(_ bytes: [UInt8], _ range: Range<Int>) throws -> Range<Int>? {
        var q = range.lowerBound
        while q + 4 <= range.upperBound {
            let id = try u16(bytes, q), size = try u16(bytes, q + 2)
            let end = q + 4 + size
            guard end <= range.upperBound else { throw PCIOError.corrupt("zip extra field out of range") }
            if id == zip64ExtraId { return q + 4 ..< end }
            q = end
        }
        return nil
    }

    public init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 22 else { throw PCIOError.corrupt("not a zip archive (too short)") }
        // End of central directory: scan back over a possible comment.
        let minimum = max(0, bytes.count - 22 - 65535)
        var eocd: Int?
        var i = bytes.count - 22
        while i >= minimum {
            if (try? ZipReader.u32(bytes, i)) == Int(endSignature) { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw PCIOError.corrupt("zip end-of-central-directory not found") }
        var count = try ZipReader.u16(bytes, eocd + 10)
        var cdSize = try ZipReader.u32(bytes, eocd + 12)
        var cdOffset = try ZipReader.u32(bytes, eocd + 16)
        var cdLimit = eocd
        var zip64 = false
        // ZIP64: the record the locator points at replaces the classic counts. A damaged one is
        // an error only when the classic end record defers to it; otherwise the four bytes before
        // the end record merely happened to match the locator's signature.
        let defers = count == max16 || cdSize == max32 || cdOffset == max32
        do {
            if let z = try ZipReader.zip64End(bytes, eocd: eocd) {
                (count, cdSize, cdOffset, cdLimit) = (z.count, z.cdSize, z.cdOffset, z.record)
                zip64 = true
            } else if defers {
                throw PCIOError.corrupt("zip64 end of central directory not found")
            }
        } catch {
            if defers { throw error }
        }
        let (cdEnd, overflow) = cdOffset.addingReportingOverflow(cdSize)
        guard !overflow, cdEnd <= cdLimit else { throw PCIOError.corrupt("zip central directory out of range") }
        var entries: [ZipEntry] = []
        entries.reserveCapacity(min(count, bytes.count / 46))
        var p = cdOffset
        for _ in 0 ..< count {
            let headerEnd = p + 46
            guard headerEnd <= cdEnd else { throw PCIOError.corrupt("truncated zip central directory entry") }
            guard try ZipReader.u32(bytes, p) == Int(centralSignature) else { throw PCIOError.corrupt("bad zip central directory entry") }
            let flags = try ZipReader.u16(bytes, p + 8)
            let method = try ZipReader.u16(bytes, p + 10)
            let crc = try ZipReader.u32(bytes, p + 16)
            var compressed = try ZipReader.u32(bytes, p + 20)
            var uncompressed = try ZipReader.u32(bytes, p + 24)
            let nlen = try ZipReader.u16(bytes, p + 28)
            let elen = try ZipReader.u16(bytes, p + 30)
            let clen = try ZipReader.u16(bytes, p + 32)
            var local = try ZipReader.u32(bytes, p + 42)
            let nameEnd = headerEnd + nlen
            guard nameEnd <= cdEnd else { throw PCIOError.corrupt("zip entry name out of range") }
            let name = String(decoding: bytes[headerEnd ..< nameEnd], as: UTF8.self)
            if flags & 1 != 0 { throw PCIOError.unsupported("encrypted zip entries") }
            let entryEnd = nameEnd + elen + clen
            guard entryEnd <= cdEnd else { throw PCIOError.corrupt("zip central directory entry out of range") }
            // ZIP64 extended information: the fields set to 0xFFFFFFFF, in this order (§4.5.3).
            // Without one, a field means its classic value (as Info-ZIP and Python read it); the
            // range checks below bound it either way.
            if uncompressed == max32 || compressed == max32 || local == max32,
               let z = try ZipReader.zip64Extra(bytes, nameEnd ..< nameEnd + elen) {
                var q = z.lowerBound
                func next() throws -> Int {
                    guard q + 8 <= z.upperBound else { throw PCIOError.corrupt("zip entry `\(name)`: truncated zip64 field") }
                    defer { q += 8 }
                    return try ZipReader.u64(bytes, q)
                }
                if uncompressed == max32 { uncompressed = try next() }
                if compressed == max32 { compressed = try next() }
                if local == max32 { local = try next() }
            }
            // The local header gives the real data offset.
            guard try ZipReader.u32(bytes, local) == Int(localSignature) else { throw PCIOError.corrupt("bad zip local header") }
            let lnlen = try ZipReader.u16(bytes, local + 26)
            let lelen = try ZipReader.u16(bytes, local + 28)
            let dataOffset = local + 30 + lnlen + lelen
            let (end, o2) = dataOffset.addingReportingOverflow(compressed)
            guard !o2, end <= bytes.count else { throw PCIOError.corrupt("zip entry `\(name)` out of range") }
            entries.append(ZipEntry(name: name, method: UInt16(method), crc: UInt32(crc), compressedSize: compressed,
                                    uncompressedSize: uncompressed, dataOffset: dataOffset))
            p = entryEnd
        }
        var byName: [String: Int] = [:]
        byName.reserveCapacity(entries.count)
        for (k, e) in entries.enumerated() where byName[e.name] == nil { byName[e.name] = k }
        self.bytes = bytes
        self.entries = entries
        self.isZip64 = zip64
        self.byName = byName
    }

    public func find(_ name: String) -> ZipEntry? { byName[name].map { entries[$0] } }

    /// Entry payload (decompressed), at most `max` bytes, CRC-checked.
    public func read(_ e: ZipEntry, max: Int) throws -> [UInt8] {
        if e.uncompressedSize > max {
            throw PCIOError.limitExceeded("zip entry `\(e.name)` is \(e.uncompressedSize) bytes (max \(max))")
        }
        // An entry from another archive must not index out of range.
        let (end, overflow) = e.dataOffset.addingReportingOverflow(e.compressedSize)
        guard !overflow, e.dataOffset >= 0, end <= bytes.count else { throw PCIOError.corrupt("zip entry `\(e.name)` out of range") }
        let raw = Array(bytes[e.dataOffset ..< end])
        let data: [UInt8]
        switch e.method {
        case 0: data = raw
        case 8:
            do {
                data = try Deflate.inflate(raw, limit: max == .max ? .max : max + 1)
            } catch PCIOError.limitExceeded(_) {
                throw PCIOError.corrupt("zip entry `\(e.name)` has wrong size")
            } catch {
                throw PCIOError.corrupt("zip entry `\(e.name)`: \(error)")
            }
        default:
            throw PCIOError.unsupported("zip compression method \(e.method) for `\(e.name)`")
        }
        if data.count != e.uncompressedSize || data.count > max { throw PCIOError.corrupt("zip entry `\(e.name)` has wrong size") }
        if CRC32.checksum(data) != e.crc { throw PCIOError.corrupt("zip entry `\(e.name)` failed its CRC check") }
        return data
    }

    public func read(named name: String, max: Int) throws -> [UInt8] {
        guard let e = find(name) else { throw PCIOError.corrupt("missing `\(name)`") }
        return try read(e, max: max)
    }

    /// The payload of a ZIP's first entry when it is a stored file named `mimetype` (how
    /// OpenRaster and Krita mark their archives, readable without unzipping) (photocraft
    /// `ora::zip_mimetype`).
    public static func mimetype(_ bytes: [UInt8]) -> [UInt8]? {
        guard (try? u32(bytes, 0)) == Int(localSignature), (try? u16(bytes, 8)) == 0,
              let size = try? u32(bytes, 18), let nameLen = try? u16(bytes, 26), let extraLen = try? u16(bytes, 28),
              bytes.count >= 30 + nameLen, Array(bytes[30 ..< 30 + nameLen]) == Array("mimetype".utf8), size <= 256 else { return nil }
        let start = 30 + nameLen + extraLen
        guard start + size <= bytes.count else { return nil }
        return Array(bytes[start ..< start + size])
    }
}
