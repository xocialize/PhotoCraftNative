// The XMP and EXIF written next to a saved image: Orientation reset to 1 (the pixels are saved as
// they are shown), no stale EXIF thumbnail, and the resolution set to the one the file is written
// at, so no copy contradicts the ResolutionInfo resource (#1691, #2147, #2373).
// Port of photocraft-codecs (crates/codecs/src/resolution.rs: exif_resolution,
// exif_with_resolution, xmp_resolution, xmp_with_resolution, exif_without_thumbnail, export_exif,
// export_xmp; crates/codecs/src/orientation.rs: tiff_body, ifd0_entries, upright_exif,
// upright_xmp), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors. Everything
// read here is untrusted: offsets and counts are bounds-checked, both byte orders and BigTIFF-style
// EXIF are handled, and anything malformed reads as "nothing to change".

import Foundation
import PCIOCore

public enum MetadataExport {
    static let tagXResolution: UInt16 = 282, tagYResolution: UInt16 = 283, tagResolutionUnit: UInt16 = 296, tagOrientation: UInt16 = 274
    static let typeShort: UInt16 = 3, typeLong: UInt16 = 4, typeRational: UInt16 = 5
    static let cmPerInch = 2.54
    static let maxPPI = 1_000_000.0
    static let samePPI = 1e-3

    enum Order { case little, big
        func u16(_ b: [UInt8], _ at: Int) -> UInt16? {
            guard at >= 0, at <= b.count - 2 else { return nil }
            return self == .little ? UInt16(b[at]) | UInt16(b[at + 1]) << 8 : UInt16(b[at]) << 8 | UInt16(b[at + 1])
        }
        func u32(_ b: [UInt8], _ at: Int) -> UInt32? {
            guard at >= 0, at <= b.count - 4 else { return nil }
            let v = (0 ..< 4).map { UInt32(b[at + $0]) }
            return self == .little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
        }
        func u64(_ b: [UInt8], _ at: Int) -> UInt64? {
            guard let a = u32(b, at), let c = u32(b, at + 4) else { return nil }
            return self == .little ? UInt64(a) | UInt64(c) << 32 : UInt64(a) << 32 | UInt64(c)
        }
        func put16(_ v: UInt16) -> [UInt8] { self == .little ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)] }
        func put32(_ v: UInt32) -> [UInt8] {
            let b = [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
            return self == .little ? b.reversed() : b
        }
        func put64(_ v: UInt64) -> [UInt8] {
            self == .little ? put32(UInt32(v & 0xFFFF_FFFF)) + put32(UInt32(v >> 32)) : put32(UInt32(v >> 32)) + put32(UInt32(v & 0xFFFF_FFFF))
        }
    }

    /// The body after an optional `Exif\0\0` prefix.
    static func tiffBodyOffset(_ b: [UInt8]) -> Int { b.count >= 6 && Array(b[0 ..< 6]) == [0x45, 0x78, 0x69, 0x66, 0, 0] ? 6 : 0 }

    /// (order, first entry offset, count, entry size, BigTIFF) of IFD0 of a TIFF structure.
    static func ifd0Entries(_ b: [UInt8]) -> (Order, Int, Int, Int, Bool)? {
        guard b.count >= 4 else { return nil }
        let order: Order, big: Bool
        switch (b[0], b[1], b[2], b[3]) {
        case (0x49, 0x49, 42, 0): (order, big) = (.little, false)
        case (0x4D, 0x4D, 0, 42): (order, big) = (.big, false)
        case (0x49, 0x49, 43, 0): (order, big) = (.little, true)
        case (0x4D, 0x4D, 0, 43): (order, big) = (.big, true)
        default: return nil
        }
        let ifd: Int, countBytes: Int, entryBytes: Int, nextBytes: Int, header: Int
        if big {
            guard order.u16(b, 4) == 8, order.u16(b, 6) == 0, let v = order.u64(b, 8), v <= UInt64(Int.max) else { return nil }
            (ifd, countBytes, entryBytes, nextBytes, header) = (Int(v), 8, 20, 8, 16)
        } else {
            guard let v = order.u32(b, 4) else { return nil }
            (ifd, countBytes, entryBytes, nextBytes, header) = (Int(v), 2, 12, 4, 8)
        }
        guard ifd >= header else { return nil }
        let count: Int
        if big {
            guard let c = order.u64(b, ifd), c <= UInt64(Int.max / 32) else { return nil }
            count = Int(c)
        } else {
            guard let c = order.u16(b, ifd) else { return nil }
            count = Int(c)
        }
        let first = ifd + countBytes
        let (n, o) = count.multipliedReportingOverflow(by: entryBytes)
        guard !o, first + n + nextBytes <= b.count else { return nil }
        return (order, first, count, entryBytes, big)
    }

    struct Field { var entry: Int; var tag: UInt16; var ty: UInt16; var count: UInt64; var value: Int? }

    static func valueAt(_ order: Order, _ b: [UInt8], _ e: Int, _ big: Bool, _ ty: UInt16, _ count: UInt64) -> Int? {
        let unit: UInt64
        switch ty {
        case typeShort: unit = 2
        case typeRational: unit = 8
        default: return nil
        }
        let (size, o) = unit.multipliedReportingOverflow(by: count)
        guard !o, size <= UInt64(Int.max) else { return nil }
        let (field, inline) = big ? (e + 12, 8) : (e + 8, 4)
        let at: Int
        if Int(size) <= inline {
            at = field
        } else if big {
            guard let v = order.u64(b, field), v <= UInt64(Int.max) else { return nil }
            at = Int(v)
        } else {
            guard let v = order.u32(b, field) else { return nil }
            at = Int(v)
        }
        return at + Int(size) <= b.count ? at : nil
    }

    struct Ifd0 {
        var order: Order, big: Bool, first: Int, count: Int, entryBytes: Int, fields: [Field]
        func firstOf(_ tag: UInt16) -> Field? { fields.first { $0.tag == tag } }
    }

    static func parseIfd0(_ b: [UInt8]) -> Ifd0? {
        guard let (order, first, count, eb, big) = ifd0Entries(b) else { return nil }
        var fields: [Field] = []
        for i in 0 ..< count {
            let e = first + i * eb
            guard let tag = order.u16(b, e), [tagXResolution, tagYResolution, tagResolutionUnit].contains(tag),
                  let ty = order.u16(b, e + 2) else { continue }
            let cnt: UInt64? = big ? order.u64(b, e + 4) : order.u32(b, e + 4).map(UInt64.init)
            guard let c = cnt else { continue }
            fields.append(Field(entry: e, tag: tag, ty: ty, count: c, value: valueAt(order, b, e, big, ty, c)))
        }
        return Ifd0(order: order, big: big, first: first, count: count, entryBytes: eb, fields: fields)
    }

    static func short(_ f: Field, _ order: Order, _ b: [UInt8]) -> UInt16? {
        guard f.ty == typeShort, f.count == 1, let at = f.value else { return nil }
        return order.u16(b, at)
    }

    static func rational(_ f: Field, _ order: Order, _ b: [UInt8]) -> Double? {
        guard f.ty == typeRational, f.count == 1, let at = f.value, let n = order.u32(b, at), let d = order.u32(b, at + 4), d != 0 else { return nil }
        return Double(n) / Double(d)
    }

    static func ppiPair(_ x: Double, _ y: Double) -> (Float, Float)? {
        func ok(_ v: Double) -> Bool { v.isFinite && v > 0 && v <= maxPPI }
        return ok(x) && ok(y) ? (Float(x), Float(y)) : nil
    }

    static func same(_ a: (Float, Float), _ b: (Float, Float)) -> Bool {
        abs(Double(a.0) - Double(b.0)) < samePPI && abs(Double(a.1) - Double(b.1)) < samePPI
    }

    /// `ppi` as a TIFF RATIONAL: a whole number over 1 when it is one, else over 1000.
    static func rationalOf(_ ppi: Float) -> (UInt32, UInt32) {
        let p = Double(ppi)
        return abs(p - p.rounded()) < samePPI ? (satCast(p.rounded()), 1) : (satCast((p * 1000).rounded()), 1000)
    }

    /// The resolution (pixels per inch) recorded in IFD0 of an EXIF block or TIFF structure.
    public static func exifResolution(_ exif: [UInt8]) -> (Float, Float)? {
        let b = Array(exif[tiffBodyOffset(exif)...])
        guard let ifd = parseIfd0(b) else { return nil }
        let unit: UInt16
        if let f = ifd.firstOf(tagResolutionUnit) { guard let u = short(f, ifd.order, b) else { return nil }; unit = u } else { unit = 2 }
        let scale: Double
        switch unit {
        case 2: scale = 1
        case 3: scale = cmPerInch
        default: return nil
        }
        guard let xf = ifd.firstOf(tagXResolution), let x = rational(xf, ifd.order, b),
              let yf = ifd.firstOf(tagYResolution), let y = rational(yf, ifd.order, b) else { return nil }
        return ppiPair(x * scale, y * scale)
    }

    /// `exif` with its IFD0 resolution set to `ppi`; nil when there is nothing to change.
    public static func exifWithResolution(_ exif: [UInt8], _ ppi: (Float, Float)) -> [UInt8]? {
        guard ppiPair(Double(ppi.0), Double(ppi.1)) != nil else { return nil }
        let prefix = tiffBodyOffset(exif)
        let body = Array(exif[prefix...])
        guard let ifd = parseIfd0(body), !ifd.fields.isEmpty else { return nil }
        if let r = exifResolution(body), same(r, ppi) { return nil }
        let order = ifd.order
        var out = body
        var removed: [Int] = []
        for f in ifd.fields {
            let bytes: [UInt8]
            switch f.tag {
            case tagResolutionUnit where short(f, order, body) != nil:
                bytes = order.put16(2)
            case tagXResolution where rational(f, order, body) != nil, tagYResolution where rational(f, order, body) != nil:
                let (n, d) = rationalOf(f.tag == tagXResolution ? ppi.0 : ppi.1)
                bytes = order.put32(n) + order.put32(d)
            default:
                removed.append(f.entry)
                continue
            }
            if let at = f.value, at + bytes.count <= out.count {
                out.replaceSubrange(at ..< at + bytes.count, with: bytes)
            } else {
                removed.append(f.entry)
            }
        }
        if !removed.isEmpty { removeEntries(&out, ifd, removed) }
        let full = Array(exif[..<prefix]) + out
        return full == exif ? nil : full
    }

    static func removeEntries(_ b: inout [UInt8], _ ifd: Ifd0, _ removed: [Int]) {
        let eb = ifd.entryBytes
        let nextBytes = ifd.big ? 8 : 4
        let countBytes = ifd.big ? 8 : 2
        let tableEnd = ifd.first + ifd.count * eb
        guard tableEnd + nextBytes <= b.count else { return }
        let old = Array(b[ifd.first ..< tableEnd + nextBytes])
        var table: [UInt8] = []
        var kept = 0
        for i in 0 ..< ifd.count where !removed.contains(ifd.first + i * eb) {
            table += old[i * eb ..< (i + 1) * eb]
            kept += 1
        }
        table += old[(ifd.count * eb)...]
        table += [UInt8](repeating: 0, count: max(0, old.count - table.count))
        let count = ifd.big ? ifd.order.put64(UInt64(kept)) : ifd.order.put16(UInt16(kept))
        let countAt = ifd.first - countBytes
        guard countAt >= 0 else { return }
        b.replaceSubrange(countAt ..< ifd.first, with: count)
        b.replaceSubrange(ifd.first ..< ifd.first + table.count, with: table)
    }

    /// The text ranges of every value of XMP property `key` (`key="v"`, `key='v'` or `<key>v</key>`).
    static func xmpValues(_ xmp: [UInt8], _ key: [UInt8]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var from = 0
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
        while from + key.count <= xmp.count {
            guard let k = (from ... xmp.count - key.count).first(where: { Array(xmp[$0 ..< $0 + key.count]) == key }) else { break }
            from = k + key.count
            // An attribute or an opening tag of exactly this name.
            guard k > 0, xmp[k - 1] == UInt8(ascii: "<") || isSpace(xmp[k - 1]) else { continue }
            var i = from
            while i < xmp.count, isSpace(xmp[i]) { i += 1 }
            var start: Int, close: UInt8
            if i < xmp.count, xmp[i] == UInt8(ascii: "=") {
                i += 1
                while i < xmp.count, isSpace(xmp[i]) { i += 1 }
                guard i < xmp.count, xmp[i] == UInt8(ascii: "\"") || xmp[i] == UInt8(ascii: "'") else { continue }
                close = xmp[i]
                start = i + 1
            } else if from < xmp.count, xmp[from] == UInt8(ascii: ">") {
                close = UInt8(ascii: "<")
                start = from + 1
            } else {
                continue
            }
            guard let end = (start ..< xmp.count).first(where: { xmp[$0] == close }) else { continue }
            out.append(start ..< end)
        }
        return out
    }

    static func xmpNumber(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let slash = t.firstIndex(of: "/") {
            guard let n = Double(t[..<slash].trimmingCharacters(in: .whitespaces)),
                  let d = Double(t[t.index(after: slash)...].trimmingCharacters(in: .whitespaces)), d != 0 else { return nil }
            return n / d
        }
        return Double(t)
    }

    /// The resolution in an XMP packet's `tiff:` properties.
    public static func xmpResolution(_ xmp: String) -> (Float, Float)? {
        let b = Array(xmp.utf8)
        func first(_ key: String) -> String? { xmpValues(b, Array(key.utf8)).first.map { String(decoding: b[$0], as: UTF8.self) } }
        let unit: Double
        if let u = first("tiff:ResolutionUnit") { guard let v = xmpNumber(u) else { return nil }; unit = v } else { unit = 2 }
        let scale: Double
        if unit == 2 { scale = 1 } else if unit == 3 { scale = cmPerInch } else { return nil }
        guard let xs = first("tiff:XResolution"), let x = xmpNumber(xs), let ys = first("tiff:YResolution"), let y = xmpNumber(ys) else { return nil }
        return ppiPair(x * scale, y * scale)
    }

    /// `xmp` with its `tiff:` resolution set to `ppi` (unit 2); nil when nothing changes.
    public static func xmpWithResolution(_ xmp: String, _ ppi: (Float, Float)) -> String? {
        guard ppiPair(Double(ppi.0), Double(ppi.1)) != nil else { return nil }
        if let r = xmpResolution(xmp), same(r, ppi) { return nil }
        let b = Array(xmp.utf8)
        func text(_ v: Float) -> String { let (n, d) = rationalOf(v); return "\(n)/\(d)" }
        var edits: [(Range<Int>, String)] = []
        for (key, value) in [("tiff:XResolution", text(ppi.0)), ("tiff:YResolution", text(ppi.1)), ("tiff:ResolutionUnit", "2")] {
            edits += xmpValues(b, Array(key.utf8)).map { ($0, value) }
        }
        if edits.isEmpty { return nil }
        edits.sort { $0.0.lowerBound < $1.0.lowerBound }
        var out: [UInt8] = []
        var at = 0
        for (r, v) in edits where r.lowerBound >= at {
            out += b[at ..< r.lowerBound]
            out += Array(v.utf8)
            at = r.upperBound
        }
        out += b[at...]
        return out == b ? nil : String(decoding: out, as: UTF8.self)
    }

    /// `exif` without its embedded thumbnail (IFD0's next-IFD pointer cleared); nil when none.
    static func exifWithoutThumbnail(_ exif: [UInt8]) -> [UInt8]? {
        let prefix = tiffBodyOffset(exif)
        let body = Array(exif[prefix...])
        guard let (_, first, count, eb, big) = ifd0Entries(body) else { return nil }
        let next = prefix + first + count * eb
        let width = big ? 8 : 4
        guard next + width <= exif.count else { return nil }
        if exif[next ..< next + width].allSatisfy({ $0 == 0 }) { return nil }
        var out = exif
        for i in next ..< next + width { out[i] = 0 }
        return out
    }

    /// `exif` with every well-formed Orientation entry set to 1; nil when nothing changes.
    static func uprightExif(_ exif: [UInt8]) -> [UInt8]? {
        let prefix = tiffBodyOffset(exif)
        let body = Array(exif[prefix...])
        guard let (order, first, count, eb, big) = ifd0Entries(body) else { return nil }
        var values: [(at: Int, ty: UInt16)] = []
        for i in 0 ..< count {
            let e = first + i * eb
            guard order.u16(body, e) == tagOrientation else { continue }
            let cnt: UInt64? = big ? order.u64(body, e + 4) : order.u32(body, e + 4).map(UInt64.init)
            guard cnt == 1, let ty = order.u16(body, e + 2), ty == typeShort || ty == typeLong else { continue }
            values.append((e + (big ? 12 : 8), ty))
        }
        func read(_ v: (at: Int, ty: UInt16)) -> UInt32? { v.ty == typeShort ? order.u16(body, v.at).map(UInt32.init) : order.u32(body, v.at) }
        if values.allSatisfy({ read($0) == 1 }) { return nil }
        var out = exif
        for v in values {
            let one = v.ty == typeShort ? order.put16(1) : order.put32(1)
            let at = prefix + v.at
            if at + one.count <= out.count { out.replaceSubrange(at ..< at + one.count, with: one) }
        }
        return out
    }

    /// `xmp` with any `tiff:Orientation` set to 1; nil when nothing changes.
    static func uprightXmp(_ xmp: String) -> String? {
        let key = Array("tiff:Orientation".utf8)
        var b = Array(xmp.utf8)
        var changed = false
        var from = 0
        while from + key.count <= b.count, let i = (from ... b.count - key.count).first(where: { Array(b[$0 ..< $0 + key.count]) == key }) {
            var j = i + key.count
            from = j
            // `tiff:Orientation="6"`, `='6'` or `>6<`.
            var lastOpen: (Int, UInt8)?
            while j < b.count, b[j] == 0x20 || b[j] == 0x09 || b[j] == 0x0A || b[j] == 0x0D || [UInt8(ascii: "="), UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: ">")].contains(b[j]) {
                lastOpen = (j, b[j])
                j += 1
            }
            guard let (at, c) = lastOpen, c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") || c == UInt8(ascii: ">") else { continue }
            let start = at + 1
            var digits = 0
            while start + digits < b.count, (0x30 ... 0x39).contains(b[start + digits]) { digits += 1 }
            if digits == 0 || (digits == 1 && b[start] == UInt8(ascii: "1")) { continue }
            b.replaceSubrange(start ..< start + digits, with: [UInt8(ascii: "1")])
            from = start + 1
            changed = true
        }
        return changed ? String(decoding: b, as: UTF8.self) : nil
    }

    /// The EXIF to write next to upright pixels at `ppi`: Orientation 1, no source thumbnail,
    /// and the resolution when known (photocraft `export_exif`).
    public static func exportExif(_ exif: [UInt8], _ ppi: (Float, Float)?) -> [UInt8] {
        var up = uprightExif(exif) ?? exif
        up = exifWithoutThumbnail(up) ?? up
        guard let ppi else { return up }
        return exifWithResolution(up, ppi) ?? up
    }

    /// The XMP to write next to upright pixels at `ppi` (photocraft `export_xmp`).
    public static func exportXmp(_ xmp: String, _ ppi: (Float, Float)?) -> String {
        let up = uprightXmp(xmp) ?? xmp
        guard let ppi else { return up }
        return xmpWithResolution(up, ppi) ?? up
    }
}
