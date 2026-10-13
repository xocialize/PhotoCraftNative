// The encoder settings a lossy file was written with, read back from its own bytes, so Save can
// write it again the way it came (photocraft #2399).
// Port of photocraft-codecs (crates/codecs/src/source_settings.rs), MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors. The DQT parser and IJG-curve fit are ported as written (they
// read bytes; no framework does this). New here: the calibration from ImageIO's
// `kCGImageDestinationLossyCompressionQuality` (0…1) to the IJG quality its tables match, measured at
// first use, so "keep the file's quality" round-trips through ImageIO's JPEG writer.

import CoreGraphics
import Foundation
import ImageIO
import Synchronization

public enum SourceSettings {
    /// ITU-T T.81 Annex K.1 luminance table, natural order.
    static let annexKLuma: [UInt16] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]
    /// ITU-T T.81 Annex K.2 chrominance table, natural order.
    static let annexKChroma: [UInt16] = [
        17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
    ] + [UInt16](repeating: 99, count: 32)
    /// Natural-order index of the k-th zig-zag coefficient (T.81 Figure A.6).
    static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]

    struct Table { var values: [UInt16]; var wide: Bool }

    /// The IJG quality (1–100) a JPEG was most likely saved at, from its quantisation tables; nil
    /// without a usable luminance table (photocraft `jpeg_quality`).
    public static func jpegQuality(_ data: Data) -> Int? {
        let tables = jpegTables([UInt8](data))
        guard let luma = tables[0] else { return nil }
        var best: (UInt64, Int)?
        for q in 1...100 {
            var err = tableError(luma, annexKLuma, q)
            if let c = tables[1] { err &+= tableError(c, annexKChroma, q) }
            if best == nil || err < best!.0 { best = (err, q) }
        }
        return best?.1
    }

    /// libjpeg's quality scaling of `base` (photocraft `scaled`).
    static func scaled(_ base: UInt16, _ q: Int, wide: Bool) -> UInt32 {
        let q = UInt32(min(max(q, 1), 100))
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        let v = (UInt32(base) * scale + 50) / 100
        return min(max(v, 1), wide ? 32767 : 255)
    }

    static func tableError(_ t: Table, _ base: [UInt16], _ q: Int) -> UInt64 {
        var e: UInt64 = 0
        for i in 0..<64 {
            let a = UInt32(t.values[i]), b = scaled(base[i], q, wide: t.wide)
            e += UInt64(a > b ? a - b : b - a)
        }
        return e
    }

    /// Quantisation tables 0…3 defined before the first scan.
    static func jpegTables(_ b: [UInt8]) -> [Table?] {
        var tables: [Table?] = [nil, nil, nil, nil]
        guard b.count >= 2, b[0] == 0xFF, b[1] == 0xD8 else { return tables }
        var i = 2
        while i + 1 < b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD8 || (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
            if marker == 0xDA || marker == 0xD9 { break }
            guard i + 4 <= b.count else { break }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { break }
            if marker == 0xDB { readDQT(Array(b[(i + 4)..<(i + 2 + len)]), &tables) }
            i += 2 + len
        }
        return tables
    }

    static func readDQT(_ seg: [UInt8], _ tables: inout [Table?]) {
        var p = 0
        while p < seg.count {
            let pq = seg[p] >> 4, slot = Int(seg[p] & 0x0F)
            if pq > 1 { return }
            let wide = pq == 1, n = wide ? 128 : 64
            guard p + 1 + n <= seg.count else { return }
            var values = [UInt16](repeating: 0, count: 64)
            for k in 0..<64 {
                let v: UInt16 = wide ? UInt16(seg[p + 1 + 2 * k]) << 8 | UInt16(seg[p + 2 + 2 * k]) : UInt16(seg[p + 1 + k])
                values[zigzag[k]] = v
            }
            if slot < 4 { tables[slot] = Table(values: values, wide: wide) }
            p += 1 + n
        }
    }

    /// How a WebP file's first image is compressed (photocraft `webp_encoding`).
    public enum WebPEncoding: Sendable, Equatable {
        case lossless
        /// VP8 lossy, with the frame's base quantiser index (0–127). photocraft maps it to its own
        /// encoder's quality scale; `webpQuality(_:)` maps it to libwebp's (webp-swift's writer).
        case lossy(baseQuantizer: Int?)
    }

    public static func webpEncoding(_ data: Data) -> WebPEncoding? {
        let b = [UInt8](data)
        guard let c = webpImageChunk(b) else { return nil }
        return c.lossless ? .lossless : .lossy(baseQuantizer: vp8Quantizers(Array(b[c.payload])).map(\.baseIndex))
    }

    /// A lossy WebP's quality on libwebp's 0–100 scale — the scale webp-swift's
    /// `WebPStillEncoder.encode(_:quality:)` takes (× 1/100), so a reopened file saves the way it
    /// came — read from its VP8 frame header with libwebp's quality → quantiser mapping inverted
    /// (`libwebpQuantizer(quality:)`). Nil for lossless or unreadable images. Measured within ±1 of
    /// the quality written, 10…100 (`CodecTests`).
    ///
    /// libwebp quantises each of up to four segments at cᵢ = c_base^(1 − amp·αᵢ)
    /// (src/enc/quant_enc.c `VP8SetSegmentParams`), with αᵢ = 255·(centreᵢ − mid)/(max − min)
    /// clipped to ±127, `mid` the macroblock-weighted mean centre (src/enc/analysis_enc.c
    /// `SetSegmentAlphas`). So, with L = ln c_base and K = L·amp, ln cᵢ = L − K·αᵢ, the unclipped
    /// αᵢ have a macroblock-weighted mean of 0 and span exactly 255. Without clipping that makes L
    /// the weighted mean of ln cᵢ; when one extreme segment is clipped (common when most
    /// macroblocks are alike) the two constraints still fix L and K. No SNS strength is assumed.
    /// The weights come from the header's segment-map probabilities (src/enc/frame_enc.c
    /// `SetSegmentProbas`); each cᵢ is the middle of its quantiser's truncation interval.
    public static func webpQuality(_ data: Data) -> Int? {
        let b = [UInt8](data)
        guard let chunk = webpImageChunk(b), !chunk.lossless, let h = vp8Quantizers(Array(b[chunk.payload])) else { return nil }
        let segments = (h.segments ?? [(h.baseIndex, 1)]).filter { $0.weight > 0 }
        let total = segments.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        let lnC = segments.map { log(max(1 - (Double(min(max($0.index, 0), 127)) + 0.5) / 127, 1e-9)) }
        let w = segments.map(\.weight)
        var l = zip(w, lnC).reduce(0) { $0 + $1.0 * $1.1 } / total
        // Segments are in centre order, so among tied extremes the outermost is the true one.
        if let low = lnC.min(), let high = lnC.max(), high > low, let lo = lnC.firstIndex(of: low), let hi = lnC.lastIndex(of: high) {
            // Unclipped, the extremes span 255: K = −(ln c_max − ln c_min) / 255.
            let k0 = -(lnC[hi] - lnC[lo]) / 255
            let alpha = lnC.map { (l - $0) / k0 }
            // One extreme clipped at ∓127: its ln c = L ± 127·K, and its unclipped α is the other
            // extreme's ∓ 255; the weighted mean of the unclipped α is 0.
            func solve(_ clipped: Int, _ other: Int, _ sign: Double) -> Double? {
                var s = 0.0
                for i in lnC.indices { s += w[i] * (lnC[clipped] - lnC[i == clipped ? other : i]) }
                let k = -sign * s / (127 * total + 255 * w[clipped])
                return k < 0 ? lnC[clipped] + sign * 127 * k : nil
            }
            if alpha[lo] < -127.5, let solved = solve(lo, hi, -1) { l = solved }
            else if alpha[hi] > 127.5, let solved = solve(hi, lo, 1) { l = solved }
        }
        return Int(min(max(libwebpQuality(compression: exp(l)), 0), 100).rounded())
    }

    /// libwebp's quality (0–100) → base quantiser index for a segment of average susceptibility
    /// (libwebp 1.6.0 src/enc/quant_enc.c `QualityToCompression` / `VP8SetSegmentParams`):
    /// c = linear^(1/3), linear = ⅔·q below q = 0.75 and 2q − 1 above; index = ⌊127·(1 − c)⌋.
    public static func libwebpQuantizer(quality: Double) -> Int {
        let q = min(max(quality, 0), 100) / 100
        let c = pow(q < 0.75 ? q * (2.0 / 3.0) : 2 * q - 1, 1.0 / 3.0)
        return min(max(Int(127 * (1 - c)), 0), 127)
    }

    /// The inverse of `QualityToCompression`: the quality (0–100) whose compression factor is `c`.
    static func libwebpQuality(compression c: Double) -> Double {
        let linear = c * c * c
        return (linear < 0.5 ? linear * 1.5 : (linear + 1) / 2) * 100
    }

    /// The first `VP8 ` or `VP8L` chunk of a WebP (looking inside animation frames): whether it is
    /// lossless, and its payload's byte range.
    static func webpImageChunk(_ b: [UInt8]) -> (lossless: Bool, payload: Range<Int>)? {
        guard b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8) else { return nil }
        return findImageChunk(b, from: 12, depth: 0)
    }

    private static func findImageChunk(_ b: [UInt8], from start: Int, depth: Int) -> (lossless: Bool, payload: Range<Int>)? {
        var i = start
        while i + 8 <= b.count {
            let fourcc = String(decoding: b[i..<i + 4], as: UTF8.self)
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            let payload = (i + 8)..<min(i + 8 + size, b.count)
            switch fourcc {
            case "VP8L": return (true, payload)
            case "VP8 ": return (false, payload)
            case "ANMF" where depth == 0:
                if payload.count > 16, let f = findImageChunk(b, from: payload.lowerBound + 16, depth: 1) { return f }
            default: break
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    /// The base quantiser index of a VP8 key frame (RFC 6386 §9.2–9.6; photocraft
    /// `vp8_base_quantizer`).
    static func vp8BaseQuantizer(_ frame: [UInt8]) -> Int? { vp8Quantizers(frame)?.baseIndex }

    /// A VP8 key frame's quantiser fields (RFC 6386 §9.3, §9.6, §19.2).
    struct VP8Quantizers {
        /// `y_ac_qi`, averaged over the segments when segmentation sets absolute quantisers or
        /// adjusted by their mean delta otherwise (photocraft `vp8_base_quantizer`).
        var baseIndex: Int
        /// Per segment: its quantiser index and its share of the macroblocks, from the segment-map
        /// tree probabilities (all in segment 0 when the frame sends no map). Nil without
        /// segment quantisers.
        var segments: [(index: Int, weight: Double)]?
    }

    static func vp8Quantizers(_ frame: [UInt8]) -> VP8Quantizers? {
        guard frame.count >= 10, frame[0] & 1 == 0, Array(frame[3..<6]) == [0x9D, 0x01, 0x2A] else { return nil }
        var d = BoolDecoder(Array(frame[10...]))
        _ = d.literal(1); _ = d.literal(1)
        var segments: (absolute: Bool, q: [Int], probabilities: [Int]?)?
        if d.flag() {
            let updateMap = d.flag()
            var data: (Bool, [Int])?
            if d.flag() {
                let absolute = d.flag()
                var q = [0, 0, 0, 0]
                for k in 0..<4 { q[k] = d.flag() ? d.signed(7) : 0 }
                for _ in 0..<4 where d.flag() { _ = d.signed(6) }
                data = (absolute, q)
            }
            var probabilities = [255, 255, 255]
            if updateMap { for k in 0..<3 { probabilities[k] = d.flag() ? d.literal(8) : 255 } }
            if let (absolute, q) = data { segments = (absolute, q, updateMap ? probabilities : nil) }
        }
        _ = d.literal(1); _ = d.literal(6); _ = d.literal(3)
        if d.flag() && d.flag() { for _ in 0..<8 where d.flag() { _ = d.signed(6) } }
        _ = d.literal(2)
        if d.overrun > 2 { return nil }
        let base = d.literal(7)
        guard let seg = segments else { return VP8Quantizers(baseIndex: min(max(base, 0), 127), segments: nil) }
        let qi = seg.absolute ? seg.q.reduce(0, +) / 4 : base + seg.q.reduce(0, +) / 4
        let indices = seg.q.map { min(max(seg.absolute ? $0 : base + $0, 0), 127) }
        // P(bit 0) at each node of the segment tree: {0, 1} vs {2, 3}, then 0 vs 1 and 2 vs 3.
        var weights = [1.0, 0, 0, 0]
        if let p = seg.probabilities?.map({ Double($0) / 255 }) {
            weights = [p[0] * p[1], p[0] * (1 - p[1]), (1 - p[0]) * p[2], (1 - p[0]) * (1 - p[2])]
        }
        return VP8Quantizers(baseIndex: min(max(qi, 0), 127), segments: Array(zip(indices, weights)).map { (index: $0.0, weight: $0.1) })
    }

    /// RFC 6386 §7 boolean decoder (photocraft `BoolDecoder`).
    struct BoolDecoder {
        let data: [UInt8]
        var pos = 0, value: UInt32 = 0, range: UInt32 = 255, bitCount = 0, overrun = 0
        init(_ data: [UInt8]) {
            self.data = data
            value = (nextByte() << 8) | nextByte()
        }
        mutating func nextByte() -> UInt32 {
            if pos < data.count { pos += 1; return UInt32(data[pos - 1]) }
            overrun += 1; return 0
        }
        mutating func bool(_ prob: UInt32) -> Bool {
            let split = 1 + (((range - 1) * prob) >> 8)
            let big = split << 8
            let bit: Bool
            if value >= big { range -= split; value -= big; bit = true } else { range = split; bit = false }
            while range < 128 {
                value <<= 1; range <<= 1; bitCount += 1
                if bitCount == 8 { bitCount = 0; value |= nextByte() }
            }
            return bit
        }
        mutating func flag() -> Bool { bool(128) }
        mutating func literal(_ bits: Int) -> Int { (0..<bits).reduce(0) { v, _ in (v << 1) | (flag() ? 1 : 0) } }
        mutating func signed(_ bits: Int) -> Int { let v = literal(bits); return flag() ? -v : v }
    }

    // MARK: ImageIO JPEG quality calibration

    private static let calibration = Mutex<[Int]?>(nil)

    /// For each ImageIO lossy quality 0.00…1.00 (index × 0.01), the IJG quality its JPEG tables
    /// match — measured once by encoding a 16×16 image at every step.
    public static func imageIOJPEGCalibration() -> [Int] {
        if let c = calibration.withLock({ $0 }) { return c }
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 3)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 97 &+ 13) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let img = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 48, space: space,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                          provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var table: [Int] = []
        for step in 0...100 {
            let d = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(d, "public.jpeg" as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: Double(step) / 100] as CFDictionary)
            CGImageDestinationFinalize(dst)
            table.append(jpegQuality(d as Data) ?? 0)
        }
        calibration.withLock { $0 = table }
        return table
    }

    /// The ImageIO lossy quality whose JPEG tables best match IJG quality `q` (1–100).
    public static func imageIOQuality(forIJG q: Int) -> Double {
        let t = imageIOJPEGCalibration()
        var best = (Int.max, 0.9)
        for (i, v) in t.enumerated() {
            let e = abs(v - q)
            if e < best.0 { best = (e, Double(i) / 100) }
        }
        return best.1
    }
}
