// The encoder settings a lossy file was written with, read back from its own data, so a save can
// write it again the way it came (File › Save keeps a JPEG's quality and a WebP's lossy or lossless
// encoding). Port of photocraft-io (crates/io/src/flat.rs `file_encoding`) and photocraft-codecs
// (crates/codecs/src/source_settings.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.
//
// * JPEG: the quality is estimated from the quantisation tables (DQT). Most encoders scale the
//   example tables of ITU-T T.81 Annex K (K.1 luminance, K.2 chrominance) by the Independent JPEG
//   Group's quality curve, so the quality whose scaled tables match the file's best is the one it
//   was saved at (exact for such tables; the closest fit for others).
// * WebP: a `VP8L` image is lossless, a `VP8 ` image lossy. photocraft maps a lossy file's base
//   quantiser back onto its own encoder's quality scale; the platform encoder here is not that
//   encoder, so a lossy WebP gets photocraft's `DEFAULT_LOSSY_WEBP_QUALITY` (75), as the engine
//   did before this moved here.
//
// Everything here reads hostile bytes: every index is checked and a malformed file gives nil.

import PCDocument

public enum SourceEncoding {
    /// The quality a lossy WebP is saved at when its own isn't known (photocraft
    /// `DEFAULT_LOSSY_WEBP_QUALITY`).
    public static let defaultLossyWebPQuality: UInt8 = 75

    /// The lossy settings `bytes` were encoded with (photocraft `file_encoding`): a JPEG's quality,
    /// a WebP's lossless or lossy encoding; empty for anything else.
    public static func fileEncoding(_ bytes: [UInt8]) -> FileEncoding {
        var e = FileEncoding()
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            e.jpegQuality = jpegQuality(bytes)
        } else if let lossless = webpIsLossless(bytes) {
            e.webpLossless = lossless
            if !lossless { e.webpQuality = defaultLossyWebPQuality }
        }
        return e
    }

    // MARK: JPEG

    /// ITU-T T.81 Annex K.1, the example luminance quantisation table, in natural (row) order.
    static let annexKLuma: [UInt16] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]

    /// ITU-T T.81 Annex K.2, the example chrominance quantisation table, in natural order.
    static let annexKChroma: [UInt16] = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
                                         47, 66, 99, 99, 99, 99, 99, 99] + [UInt16](repeating: 99, count: 32)

    /// The natural-order index of the k-th coefficient in zig-zag order (T.81 Figure A.6): DQT
    /// stores its 64 values in this order.
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50,
        43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    /// One quantisation table, in natural order, with its precision (16-bit entries when `wide`).
    struct Table {
        var values: [UInt16]
        var wide: Bool
    }

    /// The quality (1–100, the IJG scale) a JPEG was most likely saved at, from its quantisation
    /// tables; nil when it has no usable luminance table (or isn't a JPEG).
    public static func jpegQuality(_ bytes: [UInt8]) -> UInt8? {
        let tables = jpegTables(bytes)
        guard let luma = tables[0] else { return nil }
        var best: (err: UInt64, q: UInt8)?
        for q in UInt8(1) ... 100 {
            var err = tableError(luma, annexKLuma, q)
            if let c = tables[1] {
                let (s, o) = err.addingReportingOverflow(tableError(c, annexKChroma, q))
                err = o ? .max : s
            }
            if best == nil || err < best!.err { best = (err, q) }
        }
        return best?.q
    }

    /// libjpeg's `jpeg_quality_scaling` + `jpeg_add_quant_table`: a percentage scale of 5000 / q
    /// below quality 50 and 200 − 2q from it, rounded, kept within 1...255 (8-bit) or 1...32767.
    static func scaled(_ base: UInt16, _ q: UInt8, wide: Bool) -> UInt32 {
        let q = UInt32(min(max(q, 1), 100))
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        let v = (UInt32(base) * scale + 50) / 100
        return min(max(v, 1), wide ? 32767 : 255)
    }

    /// The summed absolute difference of `t` from `base` scaled to quality `q`.
    static func tableError(_ t: Table, _ base: [UInt16], _ q: UInt8) -> UInt64 {
        var sum: UInt64 = 0
        for (v, b) in zip(t.values, base) {
            let s = scaled(b, q, wide: t.wide)
            sum += UInt64(UInt32(v) > s ? UInt32(v) - s : s - UInt32(v))
        }
        return sum
    }

    /// Quantisation tables 0...3 defined before the first scan (a later definition of the same
    /// slot replaces an earlier one).
    static func jpegTables(_ b: [UInt8]) -> [Table?] {
        var tables = [Table?](repeating: nil, count: 4)
        guard b.count >= 2, b[0] == 0xFF, b[1] == 0xD8 else { return tables }
        var i = 2
        while i + 1 < b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xFF {
                i += 1
                continue
            }
            if marker == 0xD8 || (0xD0 ... 0xD7).contains(marker) || marker == 0x01 {
                i += 2
                continue
            }
            if marker == 0xDA || marker == 0xD9 { break }
            guard i + 4 <= b.count else { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { break }
            if marker == 0xDB { readDQT(Array(b[i + 4 ..< i + 2 + len]), &tables) }
            i += 2 + len
        }
        return tables
    }

    /// The tables of one DQT segment; a truncated or malformed table ends the segment.
    static func readDQT(_ seg: [UInt8], _ tables: inout [Table?]) {
        var at = 0
        while at < seg.count {
            let pqTq = seg[at]
            guard pqTq >> 4 <= 1 else { return }
            let wide = pqTq >> 4 == 1
            let slot = Int(pqTq & 0x0F)
            let n = wide ? 128 : 64
            guard at + 1 + n <= seg.count else { return }
            let data = seg[at + 1 ..< at + 1 + n]
            var values = [UInt16](repeating: 0, count: 64)
            for (k, natural) in zigzag.enumerated() {
                let o = data.startIndex
                values[natural] = wide ? UInt16(data[o + 2 * k]) << 8 | UInt16(data[o + 2 * k + 1]) : UInt16(data[o + k])
            }
            if slot < tables.count { tables[slot] = Table(values: values, wide: wide) }
            at += 1 + n
        }
    }

    // MARK: WebP

    /// Whether a WebP file's (first) image is lossless (`VP8L`) or lossy (`VP8 `), looking inside
    /// animation frames; nil when it isn't a WebP or holds no image chunk.
    public static func webpIsLossless(_ bytes: [UInt8]) -> Bool? {
        guard bytes.count >= 12, bytes[0 ..< 4].elementsEqual("RIFF".utf8), bytes[8 ..< 12].elementsEqual("WEBP".utf8) else { return nil }
        return imageChunk(bytes, from: 12, to: bytes.count, depth: 0)
    }

    static func imageChunk(_ b: [UInt8], from start: Int, to end: Int, depth: Int) -> Bool? {
        var o = start
        while o + 8 <= end {
            let fourcc = String(decoding: b[o ..< o + 4], as: UTF8.self)
            let size = Int(b[o + 4]) | Int(b[o + 5]) << 8 | Int(b[o + 6]) << 16 | Int(b[o + 7]) << 24
            // A truncated last chunk still holds its header.
            let payloadEnd = min(o + 8 + size, end)
            switch fourcc {
            case "VP8L": return true
            case "VP8 ": return false
            case "ANMF" where depth == 0:
                // An animation frame: a 16-byte header, then the frame's own chunks.
                if o + 24 <= payloadEnd, let found = imageChunk(b, from: o + 24, to: payloadEnd, depth: 1) { return found }
            default: break
            }
            o += 8 + size + size % 2
        }
        return nil
    }
}
