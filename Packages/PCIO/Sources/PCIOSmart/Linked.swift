// Port of photocraft-io (crates/io/src/linked.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Embedded smart-object files from the PSD global `lnk2`/`lnk3`/`lnkD` blocks.
//
// PSD import keeps a placed layer's source as `SmartSource.linked(path: <Idnt uuid>)` and the file
// bytes stay inside the preserved global block (so PSD export stays byte-stable). This module finds
// the bytes for a uuid when the engine needs to re-render the smart object from its source.
//
// Layout (Adobe PSD spec, "Linked Layer"): a sequence of items, each `u64 length` + item data,
// padded to 4 bytes. Item: type (`liFD` data / `liFE` external / `liFA` alias), version (1–7),
// Pascal uuid, Unicode file name, file type, creator, `u64` data length, open-descriptor flag (+
// versioned descriptor), then for `liFD` the raw file bytes.
//
// PCPSD's `PSDLinkedFiles` reads the same blocks more leniently (items without the open-descriptor
// flag, liFE payloads) and writes the file name without photocraft's counted NUL, so this module
// keeps photocraft's own strict reader and writer; the corpus test cross-checks the two.

import Foundation
import PCDocument
import PCIOCore
import PCPSD

public enum Linked {
    /// An embedded file found in a linked-layer block.
    public struct LinkedFile: Equatable, Sendable {
        public var uuid: String
        public var fileName: String
        public var bytes: [UInt8]

        public init(uuid: String, fileName: String, bytes: [UInt8]) {
            self.uuid = uuid
            self.fileName = fileName
            self.bytes = bytes
        }
    }

    /// photocraft's `Rd`: a cursor whose position may run past the end (every read then fails).
    struct Rd {
        let d: [UInt8]
        var p: Int

        mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, p <= d.count else { return nil }
            let (end, o) = p.addingReportingOverflow(n)
            guard !o, end <= d.count else { return nil }
            defer { p = end }
            return d[p ..< end]
        }

        mutating func u8() -> UInt8? { take(1)?.first }

        mutating func u32() -> UInt32? {
            guard let b = take(4) else { return nil }
            return b.reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func u64() -> UInt64? {
            guard let b = take(8) else { return nil }
            return b.reduce(0) { $0 << 8 | UInt64($1) }
        }

        mutating func unicode() -> String? {
            guard let n = u32() else { return nil }
            let (bytes, o) = Int(n).multipliedReportingOverflow(by: 2)
            guard !o, let raw = take(bytes) else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(Int(n))
            var i = raw.startIndex
            while i + 1 < raw.endIndex {
                units.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))
                i += 2
            }
            var s = String(decoding: units, as: UTF16.self)
            while s.hasSuffix("\0") { s.removeLast() }
            return s
        }
    }

    /// Parses one item; nil for malformed data or non-`liFD` items.
    static func parseItem(_ item: [UInt8]) -> LinkedFile? {
        var r = Rd(d: item, p: 0)
        guard let kind = r.take(4), r.u32() != nil, let n = r.u8(), let id = r.take(Int(n)) else { return nil }
        let uuid = String(decoding: id, as: UTF8.self)
        guard let fileName = r.unicode(), r.take(8) != nil, let len64 = r.u64(), let len = Int(exactly: len64), let flag = r.u8() else { return nil }
        if flag != 0 {
            guard r.p <= item.count, let (_, used) = try? PSDVersionedDescriptor.parsePrefix(Data(item[r.p...])) else { return nil }
            r.p += used
        }
        guard kind.elementsEqual("liFD".utf8), let bytes = r.take(len) else { return nil }
        return LinkedFile(uuid: uuid, fileName: fileName, bytes: Array(bytes))
    }

    /// Every embedded (`liFD`) file in one linked-layer block's data.
    public static func parseLinkedFiles(_ data: [UInt8]) -> [LinkedFile] {
        var out: [LinkedFile] = []
        var r = Rd(d: data, p: 0)
        while let len64 = r.u64() {
            guard let len = Int(exactly: len64), let item = r.take(len) else { break }
            if let f = parseItem(Array(item)) { out.append(f) }
            r.p = (r.p + 3) / 4 * 4
        }
        return out
    }

    static let linkedKeys: [PSDKey] = ["lnk2", "lnk3", "lnkD"]

    /// The embedded file for smart-object `uuid` among the document's preserved PSD global blocks.
    public static func findLinkedFile(_ meta: Metadata, _ uuid: String) -> LinkedFile? {
        if uuid.isEmpty { return nil }
        for b in meta.psdGlobalBlocks where linkedKeys.contains(b.key) {
            if let f = parseLinkedFiles(b.data).first(where: { $0.uuid == uuid }) { return f }
        }
        return nil
    }

    /// The four-character file type Photoshop records for an embedded file, from its contents.
    public static func fileType(_ bytes: [UInt8]) -> FourCC {
        func starts(_ p: [UInt8]) -> Bool { bytes.count >= p.count && bytes.prefix(p.count).elementsEqual(p) }
        if starts(Array("8BPS".utf8) + [0, 2]) { return "8BPB" }
        if starts(Array("8BPS".utf8)) { return "8BPS" }
        if starts([0x89] + Array("PNG".utf8)) { return "PNGf" }
        if starts([0xFF, 0xD8]) { return "JPEG" }
        if starts([0x49, 0x49, 42, 0]) || starts([0x4D, 0x4D, 0, 42]) { return "TIFF" }
        if starts(Array("GIF".utf8)) { return "GIFf" }
        return "    "
    }

    /// Encodes one `liFD` item (version 7: no open descriptor, empty child document id, no
    /// modification time, unlocked), length-prefixed and padded to 4 bytes.
    public static func encodeLinkedFile(_ f: LinkedFile) -> [UInt8] {
        var item = BEWriter()
        item.fourCC("liFD")
        item.u32(7)
        let id = Array(f.uuid.utf8.prefix(255))
        item.u8(UInt8(id.count))
        item.put(id)
        // NUL-terminated, the terminator counted (as Photoshop writes and reads it).
        item.unicodeUnits(Array(f.fileName.utf16) + [0])
        item.fourCC(fileType(f.bytes))
        item.fourCC("8BIM")
        item.u64(UInt64(f.bytes.count))
        item.u8(0)
        item.put(f.bytes)
        item.u32(0) // child document id (version 5)
        item.f64(0) // asset modification time (version 6)
        item.u8(0) // asset locked (version 7)
        var out = BEWriter()
        out.u64(UInt64(item.count))
        out.put(item.bytes)
        out.zeros((4 - out.count % 4) % 4)
        return out.bytes
    }

    /// The uuid of one linked-layer item (any type), if its header is readable.
    static func itemUuid(_ item: ArraySlice<UInt8>) -> String? {
        let base = item.startIndex
        guard item.count > 8 else { return nil }
        let n = Int(item[base + 8])
        guard 9 + n <= item.count else { return nil }
        return String(decoding: item[(base + 9) ..< (base + 9 + n)], as: UTF8.self)
    }

    /// The items of a linked-layer block: each item's uuid (when readable) and its bytes including
    /// the length prefix and padding. A malformed tail is returned as one unnamed piece.
    static func splitItems(_ data: [UInt8]) -> [(uuid: String?, bytes: ArraySlice<UInt8>)] {
        var out: [(uuid: String?, bytes: ArraySlice<UInt8>)] = []
        var at = 0
        while at < data.count {
            let rest = data[at...]
            var end: Int?
            if rest.count >= 8 {
                let len = rest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                if let l = Int(exactly: len) {
                    let (e, o) = l.addingReportingOverflow(8)
                    if !o, e <= rest.count { end = e }
                }
            }
            guard let end else {
                out.append((nil, rest))
                break
            }
            let item = rest[(at + 8) ..< (at + end)]
            let padded = min((end + 3) / 4 * 4, rest.count)
            out.append((itemUuid(item), rest[at ..< (at + padded)]))
            at += padded
        }
        return out
    }

    /// Rewrites a linked-layer block: keeps the items `keep` accepts (and anything unreadable), then
    /// appends `add`. nil when nothing would change.
    public static func rebuildBlock(_ data: [UInt8], _ keep: (String) -> Bool, _ add: [LinkedFile]) -> [UInt8]? {
        let items = splitItems(data)
        let dropped = items.contains { $0.uuid.map { !keep($0) } ?? false }
        if !dropped && add.isEmpty { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for (u, bytes) in items where u.map(keep) ?? true {
            out += bytes
        }
        for f in add { out += encodeLinkedFile(f) }
        return out
    }

    /// The uuids of every item in a linked-layer block.
    public static func blockUuids(_ data: [UInt8]) -> [String] {
        splitItems(data).compactMap(\.uuid)
    }

    /// Copies one linked item under a new uuid, preserving its embedded, external or alias payload.
    public static func copyItem(_ data: [UInt8], _ uuid: String, _ newUuid: String) -> [UInt8]? {
        guard let raw = splitItems(data).first(where: { $0.uuid == uuid })?.bytes, raw.count >= 8 else { return nil }
        let b = raw.startIndex
        let len64 = raw.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let len = Int(exactly: len64), len <= raw.count - 8 else { return nil }
        let item = raw[(b + 8) ..< (b + 8 + len)]
        guard item.count > 8 else { return nil }
        let oldEnd = 9 + Int(item[item.startIndex + 8])
        let newID = Array(newUuid.utf8)
        guard newID.count <= 255, oldEnd <= item.count else { return nil }
        var copy = Array(item.prefix(8))
        copy.append(UInt8(newID.count))
        copy += newID
        copy += item.dropFirst(oldEnd)
        var out = BEWriter()
        out.u64(UInt64(copy.count))
        out.put(copy)
        out.zeros((4 - out.count % 4) % 4)
        return out.bytes
    }
}
