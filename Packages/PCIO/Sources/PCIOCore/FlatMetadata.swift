// The metadata of a flat image file, read from its container as photocraft-codecs reads it: EXIF
// (TIFF structure, without the JPEG `Exif\0\0` prefix), the XMP packet, and free-form text
// (PNG tEXt/zTXt/iTXt, TIFF ASCII tags). ImageIO re-serialises XMP and has no raw EXIF, so
// `ImageIOCodec` takes them from the file itself.
// Port of photocraft-codecs (crates/codecs/src/codecs/png.rs `read_text_metadata`, jpeg.rs
// segments, webp.rs chunks, tiff.rs `metadata`), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.

import Foundation
import PCDocument

public enum FlatMetadata {
    public struct Metadata: Sendable, Equatable {
        public var exif: [UInt8]?
        public var xmp: String?
        public var text: [MetadataText] = []
        /// The embedded ICC profile as stored (decode only).
        public var icc: [UInt8]?
        /// Whether the container was recognised (PNG, JPEG, WebP, TIFF): then a missing `icc`
        /// means the file is untagged.
        public var container = false
        /// The container's own resolution (PNG `pHYs`), pixels per inch, rounded to whole ppi on
        /// each axis as Photoshop reads it (AB-D-0156).
        public var dpi: SIMD2<Double>?
        /// The data ends before the container's end marker (PNG `IEND`, JPEG EOI after the scan).
        public var truncated = false
        public init(exif: [UInt8]? = nil, xmp: String? = nil, text: [MetadataText] = []) {
            self.exif = exif; self.xmp = xmp; self.text = text
        }
    }

    /// The PNG keyword XMP is stored under.
    public static let xmpKeyword = "XML:com.adobe.xmp"
    public static let exifHeader: [UInt8] = Array("Exif\0\0".utf8)
    public static let xmpHeader: [UInt8] = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    /// Decoded text budget (photocraft's default `max_alloc` share for metadata).
    static let textLimit = 64 << 20

    /// The metadata of a PNG, JPEG, WebP or TIFF file; empty for anything else.
    public static func read(_ b: [UInt8]) -> Metadata {
        var m: Metadata
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            m = png(b)
        } else if b.starts(with: [0xFF, 0xD8]) {
            m = jpeg(b)
        } else if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8 ..< 12]) == Array("WEBP".utf8) {
            m = webp(b)
        } else if b.starts(with: [0x49, 0x49, 42, 0]) || b.starts(with: [0x4D, 0x4D, 0, 42]) || b.starts(with: [0x49, 0x49, 43, 0]) || b.starts(with: [0x4D, 0x4D, 0, 43]) {
            m = tiff(b)
        } else {
            return Metadata()
        }
        m.container = true
        return m
    }

    /// The container's name for messages (photocraft-codecs `Format::name`), nil when unknown.
    public static func formatName(_ b: [UInt8]) -> String? {
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "JPEG" }
        if b.starts(with: [0x49, 0x49, 42, 0]) || b.starts(with: [0x4D, 0x4D, 0, 42]) || b.starts(with: [0x49, 0x49, 43, 0]) || b.starts(with: [0x4D, 0x4D, 0, 43]) { return "TIFF" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8 ..< 12]) == Array("WEBP".utf8) { return "WebP" }
        if b.starts(with: Array("GIF8".utf8)) { return "GIF" }
        if b.count >= 12, Array(b[4 ..< 8]) == Array("ftyp".utf8) { return "HEIF" }
        return nil
    }

    static func be32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    static func latin1(_ bytes: ArraySlice<UInt8>) -> String { String(bytes.map { Character(Unicode.Scalar($0)) }) }

    // MARK: PNG

    /// A `pHYs` axis (pixels per metre) in ppi, rounded to the nearest whole ppi as Photoshop
    /// 27.11 opens it (AB-D-0156, measured in AB-L-0305: 2835 → 72, 2900 → 74, 11811 → 300).
    /// PNG can't store 72 ppi exactly (2835 px/m is 72.009), so the exact value would show 72.009
    /// where Photoshop shows 72. Below half a ppi it stays exact rather than reading as 0.
    public static func pngPPI(_ pixelsPerMetre: Double) -> Double {
        let ppi = pixelsPerMetre * 0.0254
        let whole = ppi.rounded()
        return whole >= 1 ? whole : ppi
    }

    /// `eXIf` (before or after IDAT), then the CRC-valid text chunks: XMP from the reserved
    /// keyword, the rest in tEXt, zTXt, iTXt groups (the order photocraft's decoder gives).
    static func png(_ b: [UInt8]) -> Metadata {
        var m = Metadata()
        var plain: [MetadataText] = [], compressed: [MetadataText] = [], international: [MetadataText] = []
        var remaining = textLimit
        var sawEnd = false
        var at = 8
        while at + 8 <= b.count {
            let length = be32(b, at)
            guard length <= UInt32(Int32.max) else { break }
            let n = Int(length)
            let kind = String(decoding: b[at + 4 ..< at + 8], as: UTF8.self)
            let start = at + 8
            guard start <= b.count - n, start + n <= b.count - 4 else { break }
            let data = b[start ..< start + n]
            let crc = be32(b, start + n)
            at = start + n + 4
            if kind == "IEND" { sawEnd = true; break }
            if kind == "pHYs", n == 9, data[data.startIndex + 8] == 1 {
                let x = Double(be32(b, start)), y = Double(be32(b, start + 4))
                if x > 0, y > 0 { m.dpi = SIMD2(pngPPI(x), pngPPI(y)) }
            }
            if kind == "eXIf", m.exif == nil {
                m.exif = Array(data)
                continue
            }
            if kind == "iCCP", m.icc == nil {
                // Profile name, NUL, compression method 0, zlib stream.
                if let nul = data.firstIndex(of: 0), nul + 1 < data.endIndex, data[nul + 1] == 0 {
                    m.icc = try? Deflate.zlibInflate(Array(data[(nul + 2)...]), limit: 64 << 20)
                }
                continue
            }
            guard kind == "tEXt" || kind == "zTXt" || kind == "iTXt" else { continue }
            guard CRC32.checksum(Array(b[start - 4 ..< start + n])) == crc else { continue }
            guard let nul = data.firstIndex(of: 0) else { continue }
            let keyword = data[data.startIndex ..< nul]
            guard !keyword.isEmpty, keyword.count <= 79 else { continue }
            var value = data[(nul + 1)...]
            var deflated = false
            var isLatin1 = true
            switch kind {
            case "tEXt": break
            case "zTXt":
                guard value.first == 0 else { continue }
                value = value.dropFirst()
                deflated = true
            default:
                guard value.count >= 2 else { continue }
                let flag = value[value.startIndex], method = value[value.startIndex + 1]
                guard flag <= 1, flag == 0 || method == 0 else { continue }
                value = value.dropFirst(2)
                guard let l = value.firstIndex(of: 0) else { continue }
                guard value[value.startIndex ..< l].allSatisfy({ $0 < 128 }) else { continue }
                value = value[(l + 1)...]
                guard let t = value.firstIndex(of: 0) else { continue }
                guard String(validating: value[value.startIndex ..< t], as: UTF8.self) != nil else { continue }
                value = value[(t + 1)...]
                deflated = flag == 1
                isLatin1 = false
            }
            let key = latin1(keyword)
            let keyBytes = key.utf8.count
            guard remaining >= keyBytes else { break }
            guard let text = decodedText(value, deflated: deflated, latin1: isLatin1, limit: remaining - keyBytes) else { continue }
            remaining -= keyBytes + text.utf8.count
            // Some writers put XMP in Latin-1 text chunks instead of the usual iTXt.
            if key == xmpKeyword {
                m.xmp = text
            } else if kind == "tEXt" {
                plain.append(MetadataText(key, text))
            } else if kind == "zTXt" {
                compressed.append(MetadataText(key, text))
            } else {
                international.append(MetadataText(key, text))
            }
        }
        m.text = plain + compressed + international
        m.truncated = !sawEnd
        return m
    }

    /// A text chunk's value: Latin-1 or UTF-8, zlib-compressed or not; nil when it is invalid,
    /// truncated or over `limit` UTF-8 bytes.
    static func decodedText(_ input: ArraySlice<UInt8>, deflated: Bool, latin1 isLatin1: Bool, limit: Int) -> String? {
        var bytes = Array(input)
        if deflated {
            guard let inflated = try? Deflate.zlibInflate(bytes, limit: limit) else { return nil }
            bytes = inflated
        }
        let text: String
        if isLatin1 {
            text = latin1(bytes[...])
        } else {
            guard let s = String(validating: bytes, as: UTF8.self) else { return nil }
            text = s
        }
        return text.utf8.count <= limit ? text : nil
    }

    // MARK: JPEG

    /// The first APP1 `Exif` and APP1 XMP segments.
    public static let iccHeader: [UInt8] = Array("ICC_PROFILE\0".utf8)

    static func jpeg(_ b: [UInt8]) -> Metadata {
        var m = Metadata()
        var iccParts: [(Int, [UInt8])] = []
        var scanStart: Int?
        var at = 2
        while at + 4 <= b.count {
            guard b[at] == 0xFF else { break }
            let marker = b[at + 1]
            if marker == 0xFF { at += 1; continue }
            // Start of scan or end of image: no more metadata segments.
            if marker == 0xDA { scanStart = at; break }
            if marker == 0xD9 { break }
            if (0xD0 ... 0xD7).contains(marker) || marker == 0x01 { at += 2; continue }
            let length = Int(b[at + 2]) << 8 | Int(b[at + 3])
            guard length >= 2, at + 2 + length <= b.count else { break }
            let seg = b[(at + 4) ..< (at + 2 + length)]
            if marker == 0xE2, seg.starts(with: iccHeader), seg.count >= iccHeader.count + 2 {
                // ICC_PROFILE, sequence number (1-based), count, data.
                let seq = Int(seg[seg.startIndex + iccHeader.count])
                iccParts.append((seq, Array(seg.dropFirst(iccHeader.count + 2))))
            }
            if marker == 0xE1 {
                if m.exif == nil, seg.starts(with: exifHeader) {
                    m.exif = Array(seg.dropFirst(exifHeader.count))
                } else if m.xmp == nil, seg.starts(with: xmpHeader) {
                    m.xmp = String(validating: seg.dropFirst(xmpHeader.count), as: UTF8.self).map { s in
                        var t = Substring(s)
                        while t.hasSuffix("\0") { t = t.dropLast() }
                        return String(t)
                    }
                }
            }
            at += 2 + length
        }
        if !iccParts.isEmpty { m.icc = iccParts.sorted { $0.0 < $1.0 }.flatMap(\.1) }
        // The entropy-coded data after the first scan header must end in EOI (FF D9).
        if let sos = scanStart {
            var end = false
            var i = b.count - 2
            while i >= sos {
                if b[i] == 0xFF, b[i + 1] == 0xD9 { end = true; break }
                i -= 1
            }
            m.truncated = !end
        }
        return m
    }

    // MARK: WebP

    /// The `EXIF` and `XMP ` chunks.
    static func webp(_ b: [UInt8]) -> Metadata {
        var m = Metadata()
        var at = 12
        while at + 8 <= b.count {
            let kind = String(decoding: b[at ..< at + 4], as: UTF8.self)
            let n = Int(UInt32(b[at + 4]) | UInt32(b[at + 5]) << 8 | UInt32(b[at + 6]) << 16 | UInt32(b[at + 7]) << 24)
            let start = at + 8
            guard n <= b.count - start else { break }
            let data = b[start ..< start + n]
            if kind == "EXIF", m.exif == nil {
                // Some writers keep the JPEG prefix.
                m.exif = Array(data.starts(with: exifHeader) ? data.dropFirst(exifHeader.count) : data)
            } else if kind == "XMP ", m.xmp == nil {
                m.xmp = String(validating: data, as: UTF8.self)
            } else if kind == "ICCP", m.icc == nil {
                m.icc = Array(data)
            }
            at = start + n + (n & 1)
        }
        return m
    }

    // MARK: Writing

    /// XMP properties (local names, any prefix) that only describe the layered document; a flat
    /// JPEG whose packet outgrows its segment drops them (photocraft-codecs jpeg.rs).
    public static let layeredOnlyXMP = ["DocumentAncestors", "TextLayers"]

    /// `xmp` without its `<prefix:name …>…</prefix:name>` and `<prefix:name …/>` elements;
    /// unbalanced markup is kept as is (photocraft-codecs jpeg.rs `remove_element`).
    public static func removingXMPElement(_ xmp: String, _ name: String) -> String {
        let local = Array(":\(name)".utf8)
        let b = Array(xmp.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var rest = 0
        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard needle.count <= b.count - from else { return nil }
            var i = from
            while i + needle.count <= b.count {
                if b[i] == needle[0], Array(b[i ..< i + needle.count]) == needle { return i }
                i += 1
            }
            return nil
        }
        func isPrefixByte(_ c: UInt8) -> Bool {
            (0x30 ... 0x39).contains(c) || (0x41 ... 0x5A).contains(c) || (0x61 ... 0x7A).contains(c) || c == 0x5F || c == 0x2D || c == 0x2E
        }
        while let j = find(local, from: rest) {
            var prefixLen = 0
            while j - prefixLen - 1 >= rest, isPrefixByte(b[j - prefixLen - 1]) { prefixLen += 1 }
            let lt = j - prefixLen
            let afterStart = j + local.count
            let opening = prefixLen > 0 && lt > rest && b[lt - 1] == 0x3C
            let next: UInt8? = afterStart < b.count ? b[afterStart] : nil
            guard opening, let n = next, [0x3E, 0x2F, 0x20, 0x09, 0x0D, 0x0A].contains(n) else {
                out += b[rest ..< afterStart]
                rest = afterStart
                continue
            }
            guard let gt = find([0x3E], from: afterStart) else { break }
            let end: Int
            if gt > afterStart, b[gt - 1] == 0x2F {
                end = gt + 1
            } else {
                let close = Array("</".utf8) + Array(b[lt ..< j]) + local + [0x3E]
                guard let c = find(close, from: afterStart) else { break }
                end = c + close.count
            }
            out += b[rest ..< lt - 1]
            rest = end
        }
        out += b[rest...]
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: TIFF

    /// The text tags photocraft-codecs reads, with its keys.
    public static let tiffTextTags: [(tag: UInt16, key: String)] = [
        (270, "Description"), (271, "Make"), (272, "Model"), (305, "Software"), (306, "DateTime"), (315, "Artist"), (33432, "Copyright"),
    ]

    /// XMP (tag 700) and the ASCII text tags of the first directory.
    static func tiff(_ b: [UInt8]) -> Metadata {
        var m = Metadata()
        guard let entries = tiffFirstIFD(b) else { return m }
        func text(_ tag: UInt16) -> String? {
            guard let bytes = entries[tag] else { return nil }
            guard var s = String(validating: bytes, as: UTF8.self) else { return nil }
            while s.hasSuffix("\0") { s.removeLast() }
            return s.isEmpty ? nil : s
        }
        m.xmp = text(700)
        m.icc = entries[34675].flatMap { $0.isEmpty ? nil : $0 }
        for (tag, key) in tiffTextTags {
            if let s = text(tag) { m.text.append(MetadataText(key, s)) }
        }
        return m
    }

    /// The byte values of IFD0's BYTE/ASCII/UNDEFINED entries, classic or BigTIFF.
    static func tiffFirstIFD(_ b: [UInt8]) -> [UInt16: [UInt8]]? {
        guard b.count >= 8 else { return nil }
        let little = b[0] == 0x49
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= b.count else { return nil }
            return little ? Int(b[at]) | Int(b[at + 1]) << 8 : Int(b[at]) << 8 | Int(b[at + 1])
        }
        func uint(_ at: Int, _ n: Int) -> UInt64? {
            guard at >= 0, at + n <= b.count else { return nil }
            var v: UInt64 = 0
            for i in 0 ..< n { v |= UInt64(b[at + (little ? i : n - 1 - i)]) << (8 * UInt64(i)) }
            return v
        }
        guard let magic = u16(2) else { return nil }
        let big = magic == 43
        let offsetSize = big ? 8 : 4
        guard let first = uint(big ? 8 : 4, offsetSize), first < UInt64(b.count) else { return nil }
        var at = Int(first)
        guard let count = big ? uint(at, 8).map(Int.init(clamping:)) : u16(at) else { return nil }
        at += big ? 8 : 2
        let entrySize = big ? 20 : 12
        var out: [UInt16: [UInt8]] = [:]
        for i in 0 ..< min(count, 4096) {
            let e = at + i * entrySize
            guard let tag = u16(e), let type = u16(e + 2), let n = uint(e + 4, offsetSize) else { break }
            // BYTE, ASCII, UNDEFINED: one byte per value.
            guard type == 1 || type == 2 || type == 7, n <= UInt64(b.count) else { continue }
            let len = Int(n)
            let valueAt: Int
            if len <= offsetSize {
                valueAt = e + 4 + offsetSize
            } else {
                guard let off = uint(e + 4 + offsetSize, offsetSize), off <= UInt64(b.count) else { continue }
                valueAt = Int(off)
            }
            guard valueAt + len <= b.count else { continue }
            out[UInt16(tag)] = Array(b[valueAt ..< valueAt + len])
        }
        return out
    }
}

/// An 8-bit palette PNG: the indices, the palette, one transparent entry (`tRNS`) and the
/// resolution (`pHYs`). Port of photocraft-codecs (crates/codecs/src/codecs/png.rs
/// `encode_indexed`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
public enum IndexedPNG {
    public static func encode(width: Int, height: Int, indices: [UInt8], palette: [SIMD3<UInt8>], transparent: UInt8?, dpi: Double?) throws -> [UInt8] {
        guard width > 0, height > 0, indices.count == width * height else { throw PCIOError.codec("index data does not match the size") }
        guard !palette.isEmpty, palette.count <= 256, indices.allSatisfy({ Int($0) < palette.count }) else {
            throw PCIOError.codec("palette must have 1...256 entries covering every index")
        }
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func chunk(_ kind: String, _ data: [UInt8]) -> [UInt8] {
            let body = Array(kind.utf8) + data
            return be32(UInt32(data.count)) + body + be32(CRC32.checksum(body))
        }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [8, 3, 0, 0, 0])
        if let d = dpi, d > 0, d.isFinite {
            let ppm = be32(UInt32(clamping: Int((d / 0.0254).rounded())))
            out += chunk("pHYs", ppm + ppm + [1])
        }
        out += chunk("PLTE", palette.flatMap { [$0.x, $0.y, $0.z] })
        if let t = transparent, Int(t) < palette.count {
            var trns = [UInt8](repeating: 255, count: Int(t) + 1)
            trns[Int(t)] = 0
            out += chunk("tRNS", trns)
        }
        var raw: [UInt8] = []
        raw.reserveCapacity((width + 1) * height)
        for y in 0 ..< height {
            raw.append(0)
            raw += indices[y * width ..< (y + 1) * width]
        }
        out += chunk("IDAT", try Deflate.zlibDeflate(raw))
        out += chunk("IEND", [])
        return out
    }
}
