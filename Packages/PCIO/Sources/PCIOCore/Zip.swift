// Minimal ZIP container: STORE entries are written (`.pcraft` payloads are already compressed;
// OpenRaster's `mimetype` must be stored); STORE or DEFLATE entries are read, so a bundle that was
// unzipped and re-zipped by another tool still loads, and OpenRaster/Krita archives open. No
// ZIP64, no encryption, no multi-disk archives.
// Port of photocraft-format (crates/format/src/zip.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors. DEFLATE through Apple's Compression framework (`Deflate`).

import Foundation

private let localSignature: UInt32 = 0x0403_4B50
private let centralSignature: UInt32 = 0x0201_4B50
private let endSignature: UInt32 = 0x0605_4B50

/// Writer for STORE entries (and optionally DEFLATE ones).
public struct ZipWriter: Sendable {
    private var out: [UInt8] = []
    private var central: [UInt8] = []
    private var count: UInt16 = 0

    public init() {}

    /// Bytes written so far (local headers and data).
    public var size: Int { out.count }

    /// Adds a STORE entry.
    public mutating func add(_ name: String, _ data: [UInt8]) throws {
        try add(name, data, compress: false)
    }

    /// Adds an entry, DEFLATE-compressed when `compress` and it saves space.
    public mutating func add(_ name: String, _ data: [UInt8], compress: Bool) throws {
        guard count < UInt16.max else { throw PCIOError.unsupported("more than 65535 zip entries (ZIP64 not supported)") }
        guard data.count <= Int(UInt32.max) else { throw PCIOError.unsupported("zip entry over 4 GiB") }
        guard out.count <= Int(UInt32.max) else { throw PCIOError.unsupported("zip over 4 GiB") }
        let offset = UInt32(out.count)
        let crc = CRC32.checksum(data)
        let nameBytes = Array(name.utf8)
        guard nameBytes.count <= Int(UInt16.max) else { throw PCIOError.unsupported("zip entry name too long") }
        var method: UInt16 = 0
        var payload = data
        if compress, let d = try? Deflate.deflate(data), d.count < data.count {
            method = 8
            payload = d
        }
        let usize = UInt32(data.count), csize = UInt32(payload.count)
        // Local file header.
        le32(&out, localSignature)
        le16(&out, 20) // version needed
        le16(&out, 0x0800) // flags: UTF-8 names
        le16(&out, method)
        le16(&out, 0) // time
        le16(&out, 0x21) // date: 1980-01-01
        le32(&out, crc)
        le32(&out, csize)
        le32(&out, usize)
        le16(&out, UInt16(nameBytes.count))
        le16(&out, 0)
        out += nameBytes
        out += payload
        // Central directory entry.
        le32(&central, centralSignature)
        le16(&central, 20) // made by
        le16(&central, 20) // needed
        le16(&central, 0x0800)
        le16(&central, method)
        le16(&central, 0)
        le16(&central, 0x21)
        le32(&central, crc)
        le32(&central, csize)
        le32(&central, usize)
        le16(&central, UInt16(nameBytes.count))
        central += [UInt8](repeating: 0, count: 8) // extra len, comment len, disk, internal attrs
        le32(&central, 0) // external attrs
        le32(&central, offset)
        central += nameBytes
        count += 1
    }

    /// The finished archive.
    public consuming func finish() throws -> [UInt8] {
        guard out.count <= Int(UInt32.max), central.count <= Int(UInt32.max) else { throw PCIOError.unsupported("zip over 4 GiB") }
        let cdOffset = UInt32(out.count)
        let cdSize = UInt32(central.count)
        var o = out
        o += central
        le32(&o, endSignature)
        o += [0, 0, 0, 0] // disk numbers
        le16(&o, count)
        le16(&o, count)
        le32(&o, cdSize)
        le32(&o, cdOffset)
        le16(&o, 0)
        return o
    }
}

private func le16(_ o: inout [UInt8], _ v: UInt16) { o += [UInt8(v & 0xFF), UInt8(v >> 8)] }
private func le32(_ o: inout [UInt8], _ v: UInt32) { o += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

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
        let count = try ZipReader.u16(bytes, eocd + 10)
        let cdSize = try ZipReader.u32(bytes, eocd + 12)
        let cdOffset = try ZipReader.u32(bytes, eocd + 16)
        let (cdEnd, overflow) = cdOffset.addingReportingOverflow(cdSize)
        guard !overflow, cdEnd <= eocd else { throw PCIOError.corrupt("zip central directory out of range") }
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
            let compressed = try ZipReader.u32(bytes, p + 20)
            let uncompressed = try ZipReader.u32(bytes, p + 24)
            let nlen = try ZipReader.u16(bytes, p + 28)
            let elen = try ZipReader.u16(bytes, p + 30)
            let clen = try ZipReader.u16(bytes, p + 32)
            let local = try ZipReader.u32(bytes, p + 42)
            let nameEnd = headerEnd + nlen
            guard nameEnd <= cdEnd else { throw PCIOError.corrupt("zip entry name out of range") }
            let name = String(decoding: bytes[headerEnd ..< nameEnd], as: UTF8.self)
            if flags & 1 != 0 { throw PCIOError.unsupported("encrypted zip entries") }
            let entryEnd = nameEnd + elen + clen
            guard entryEnd <= cdEnd else { throw PCIOError.corrupt("zip central directory entry out of range") }
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
