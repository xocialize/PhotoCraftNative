// The codecs ImageIO lacks, ported because they are small and photocraft supports them:
//   • QOI read/write — from the QOI specification (photocraft uses the `image` crate for it).
//   • PCX read — port of photocraft-codecs crates/codecs/src/codecs/pcx.rs.
//   • Netpbm: binary PBM (P4) read, which ImageIO refuses, and a binary writer for P5/P6/P7 (PAM,
//     with alpha) and PF/Pf (32-bit float) — ImageIO writes only ASCII P2 for gray and P6, no alpha
//     and no float. Port of photocraft-codecs crates/codecs/src/codecs/pnm.rs's write side.
//   • Radiance RGBE write (flat scanlines) — ImageIO reads .hdr but cannot write it.
//   • FITS read/write — port of photocraft-codecs crates/codecs/src/codecs/fits.rs (the image in the
//     primary HDU; BITPIX 8/16/32/−32/−64 with BSCALE/BZERO; NAXIS3 = 3 as RGB; bottom-up rows).
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCFoundation

enum PortedCodecs {
    static func bad(_ f: String, _ m: String) -> PlatformError { .decodeFailed("\(f): \(m)") }

    // MARK: QOI

    static func decodeQOI(_ d: Data) throws -> RasterBuffer {
        let b = [UInt8](d)
        guard b.count >= 22, Array(b[0..<4]) == Array("qoif".utf8) else { throw bad("QOI", "missing qoif header") }
        func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        let w = be32(4), h = be32(8), ch = Int(b[12])
        guard w > 0, h > 0, ch == 3 || ch == 4, w * h <= 1 << 30 else { throw bad("QOI", "bad header \(w)×\(h)×\(ch)") }
        let format = PixelFormat(mode: .rgb, sample: .u8, alpha: ch == 4)
        var out = [UInt8](repeating: 0, count: w * h * ch)
        var index = [[UInt8]](repeating: [0, 0, 0, 0], count: 64)
        var px: [UInt8] = [0, 0, 0, 255]
        var p = 14, run = 0
        for i in 0..<(w * h) {
            if run > 0 { run -= 1 } else if p < b.count - 8 {
                let b1 = b[p]; p += 1
                if b1 == 0xFE { px[0] = b[p]; px[1] = b[p + 1]; px[2] = b[p + 2]; p += 3 }
                else if b1 == 0xFF { px = [b[p], b[p + 1], b[p + 2], b[p + 3]]; p += 4 }
                else {
                    switch b1 >> 6 {
                    case 0: px = index[Int(b1)]
                    case 1:
                        px[0] = px[0] &+ ((b1 >> 4) & 3) &- 2
                        px[1] = px[1] &+ ((b1 >> 2) & 3) &- 2
                        px[2] = px[2] &+ (b1 & 3) &- 2
                    case 2:
                        let b2 = b[p]; p += 1
                        let vg = (b1 & 0x3F) &- 32
                        px[0] = px[0] &+ vg &- 8 &+ ((b2 >> 4) & 0x0F)
                        px[1] = px[1] &+ vg
                        px[2] = px[2] &+ vg &- 8 &+ (b2 & 0x0F)
                    default: run = Int(b1 & 0x3F)
                    }
                }
                let hsh = (Int(px[0]) * 3 + Int(px[1]) * 5 + Int(px[2]) * 7 + Int(px[3]) * 11) % 64
                index[hsh] = px
            }
            for k in 0..<ch { out[i * ch + k] = px[k] }
        }
        return RasterBuffer(width: w, height: h, format: format, bytes: out)
    }

    static func encodeQOI(_ r: RasterBuffer) throws -> Data {
        var r = r.converted(to: .u8)
        if !r.format.mode.isRGBLike {
            throw PlatformError.invalidArgument("QOI stores RGB(A); convert the model first")
        }
        let ch = r.format.alpha ? 4 : 3
        if r.format.channels != ch { r = RasterBuffer(width: r.width, height: r.height, format: r.format, bytes: r.bytes) }
        var o: [UInt8] = Array("qoif".utf8)
        for v in [UInt32(r.width), UInt32(r.height)] { withUnsafeBytes(of: v.bigEndian) { o += $0 } }
        o += [UInt8(ch), 0]
        var index = [[UInt8]](repeating: [0, 0, 0, 0], count: 64)
        var prev: [UInt8] = [0, 0, 0, 255]
        var run = 0
        let n = r.width * r.height
        for i in 0..<n {
            let px: [UInt8] = ch == 4 ? Array(r.bytes[(i * 4)..<(i * 4 + 4)]) : Array(r.bytes[(i * 3)..<(i * 3 + 3)]) + [255]
            if px == prev {
                run += 1
                if run == 62 || i == n - 1 { o.append(0xC0 | UInt8(run - 1)); run = 0 }
                continue
            }
            if run > 0 { o.append(0xC0 | UInt8(run - 1)); run = 0 }
            let hsh = (Int(px[0]) * 3 + Int(px[1]) * 5 + Int(px[2]) * 7 + Int(px[3]) * 11) % 64
            if index[hsh] == px { o.append(UInt8(hsh)) } else {
                index[hsh] = px
                if px[3] == prev[3] {
                    let vr = Int(Int8(bitPattern: px[0] &- prev[0])), vg = Int(Int8(bitPattern: px[1] &- prev[1])), vb = Int(Int8(bitPattern: px[2] &- prev[2]))
                    let vgr = vr - vg, vgb = vb - vg
                    if (-2...1).contains(vr), (-2...1).contains(vg), (-2...1).contains(vb) {
                        o.append(0x40 | UInt8(vr + 2) << 4 | UInt8(vg + 2) << 2 | UInt8(vb + 2))
                    } else if (-8...7).contains(vgr), (-32...31).contains(vg), (-8...7).contains(vgb) {
                        o.append(0x80 | UInt8(vg + 32)); o.append(UInt8(vgr + 8) << 4 | UInt8(vgb + 8))
                    } else { o += [0xFE, px[0], px[1], px[2]] }
                } else { o += [0xFF] + px }
            }
            prev = px
        }
        o += [0, 0, 0, 0, 0, 0, 0, 1]
        return Data(o)
    }

    // MARK: PCX (photocraft pcx.rs)

    static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }

    static func looksLikePCX(_ b: [UInt8]) -> Bool {
        guard b.count >= 128, b[0] == 0x0A, [0, 2, 3, 5].contains(b[1]), b[2] == 1 else { return false }
        let bits = Int(b[3]), planes = Int(b[65]), stride = le16(b, 66)
        let (x0, y0, x1, y1) = (le16(b, 4), le16(b, 6), le16(b, 8), le16(b, 10))
        guard x1 >= x0, y1 >= y0, [1, 2, 4, 8].contains(bits), (1...4).contains(planes) else { return false }
        let minStride = ((x1 - x0 + 1) * bits + 7) / 8
        return stride >= minStride && stride > 0 && (bits != 8 || planes == 1 || planes == 3) && (bits == 8 || bits * planes <= 4)
    }

    static func decodePCX(_ d: Data) throws -> (RasterBuffer, Resolution?) {
        let b = [UInt8](d)
        guard looksLikePCX(b) else { throw bad("PCX", "invalid header or unsupported layout") }
        let w = le16(b, 8) - le16(b, 4) + 1, h = le16(b, 10) - le16(b, 6) + 1
        let bits = Int(b[3]), planes = Int(b[65]), stride = le16(b, 66)
        let vga = bits == 8 && planes == 1 && b.count >= 128 + 769 && b[b.count - 769] == 0x0C
        if bits == 8 && planes == 1 && !vga && le16(b, 68) != 2 { throw bad("PCX", "8-bit indexed PCX has no 256-colour palette") }
        let end = vga ? b.count - 769 : b.count
        var row = [UInt8](repeating: 0, count: stride * planes)
        var px = [UInt8](repeating: 0, count: w * h * 3)
        var p = 128
        for y in 0..<h {
            for plane in 0..<planes {
                var n = 0
                while n < stride {
                    guard p < end else { throw bad("PCX", "truncated pixel RLE") }
                    let code = b[p]; p += 1
                    var count = 1, value = code
                    if code >= 0xC0 {
                        count = Int(code & 0x3F)
                        guard p < end else { throw bad("PCX", "truncated RLE packet") }
                        value = b[p]; p += 1
                    }
                    guard count > 0, count <= stride - n else { throw bad("PCX", "RLE packet crosses a scanline") }
                    for k in 0..<count { row[plane * stride + n + k] = value }
                    n += count
                }
            }
            for x in 0..<w {
                let rgb: [UInt8]
                if bits == 8 && planes == 3 { rgb = [row[x], row[stride + x], row[2 * stride + x]] } else {
                    let idx: Int
                    if bits == 8 { idx = Int(row[x]) } else {
                        let bit = x * bits, shift = 8 - bits - bit % 8, mask = (1 << bits) - 1
                        idx = (0..<planes).reduce(0) { v, pl in v | ((Int(row[pl * stride + bit / 8]) >> shift) & mask) << (pl * bits) }
                    }
                    if vga { let o = end + 1 + idx * 3; rgb = [b[o], b[o + 1], b[o + 2]] }
                    else if bits == 8 { rgb = [UInt8(idx), UInt8(idx), UInt8(idx)] }
                    else { let o = 16 + idx * 3; rgb = [b[o], b[o + 1], b[o + 2]] }
                }
                px[(y * w + x) * 3] = rgb[0]; px[(y * w + x) * 3 + 1] = rgb[1]; px[(y * w + x) * 3 + 2] = rgb[2]
            }
        }
        let (xd, yd) = (le16(b, 12), le16(b, 14))
        return (RasterBuffer(width: w, height: h, format: PixelFormat(mode: .rgb, sample: .u8, alpha: false), bytes: px),
                xd > 0 && yd > 0 ? Resolution(x: Double(xd), y: Double(yd)) : nil)
    }

    // MARK: Netpbm

    /// Header tokens of a Netpbm file (comments skipped), and the offset after the single
    /// whitespace that ends the header.
    static func pnmHeader(_ b: [UInt8], tokens n: Int) -> ([String], Int)? {
        var toks: [String] = [], i = 2
        while toks.count < n {
            while i < b.count, [9, 10, 13, 32].contains(b[i]) { i += 1 }
            if i < b.count, b[i] == UInt8(ascii: "#") { while i < b.count, b[i] != 10 { i += 1 }; continue }
            var t = ""
            while i < b.count, ![9, 10, 13, 32].contains(b[i]) { t.append(Character(UnicodeScalar(b[i]))); i += 1 }
            if t.isEmpty { return nil }
            toks.append(t)
        }
        return i < b.count ? (toks, i + 1) : nil
    }

    /// Binary PBM (P4): 1 = black, rows padded to a byte. Gray 8-bit out.
    static func decodePBM4(_ d: Data) throws -> RasterBuffer {
        let b = [UInt8](d)
        guard b.count > 3, b[0] == UInt8(ascii: "P"), b[1] == UInt8(ascii: "4"),
              let (t, off) = pnmHeader(b, tokens: 2), let w = Int(t[0]), let h = Int(t[1]), w > 0, h > 0 else { throw bad("PBM", "bad P4 header") }
        let stride = (w + 7) / 8
        guard off + stride * h <= b.count else { throw bad("PBM", "truncated P4 data") }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let bit = (b[off + y * stride + x / 8] >> (7 - UInt8(x % 8))) & 1
            out[y * w + x] = bit == 1 ? 0 : 255
        } }
        return RasterBuffer(width: w, height: h, format: .gray8, bytes: out)
    }

    /// Binary Netpbm: P5/P6 (8/16-bit gray/RGB), P7 PAM when there is alpha, PF/Pf for f32.
    static func encodePNM(_ r: RasterBuffer) throws -> Data {
        let gray = r.format.mode.isGrayLike
        guard gray || r.format.mode.isRGBLike else { throw PlatformError.invalidArgument("Netpbm stores gray or RGB") }
        let w = r.width, h = r.height, ch = r.format.channels
        var o: [UInt8] = []
        if r.format.sample == .f32 && !r.format.alpha {
            o = Array("\(gray ? "Pf" : "PF")\n\(w) \(h)\n-1.0\n".utf8)
            let f = r.floats()
            for y in stride(from: h - 1, through: 0, by: -1) {          // PFM rows are bottom-to-top
                for i in (y * w * ch)..<((y + 1) * w * ch) { withUnsafeBytes(of: f[i].bitPattern.littleEndian) { o += $0 } }
            }
            return Data(o)
        }
        let r2 = r.format.sample == .f32 ? r.converted(to: .u16) : r
        let maxval = r2.format.sample == .u8 ? 255 : 65535
        if r2.format.alpha {
            let tupl = gray ? "GRAYSCALE_ALPHA" : "RGB_ALPHA"
            o = Array("P7\nWIDTH \(w)\nHEIGHT \(h)\nDEPTH \(ch)\nMAXVAL \(maxval)\nTUPLTYPE \(tupl)\nENDHDR\n".utf8)
        } else {
            o = Array("\(gray ? "P5" : "P6")\n\(w) \(h)\n\(maxval)\n".utf8)
        }
        if r2.format.sample == .u8 { o += r2.bytes } else {
            for i in stride(from: 0, to: r2.bytes.count, by: 2) { o += [r2.bytes[i + 1], r2.bytes[i]] }   // big-endian
        }
        return Data(o)
    }

    // MARK: Radiance RGBE

    /// Flat (uncompressed) RGBE scanlines, a valid Radiance picture every reader accepts.
    static func encodeRadiance(_ r: RasterBuffer) throws -> Data {
        guard r.format.mode.isRGBLike || r.format.mode.isGrayLike else { throw PlatformError.invalidArgument("Radiance stores RGB") }
        let f = r.floats(), ch = r.format.channels, gray = r.format.mode.isGrayLike
        var o = Array("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(r.height) +X \(r.width)\n".utf8)
        o.reserveCapacity(o.count + r.width * r.height * 4)
        for i in 0..<(r.width * r.height) {
            let rv = max(f[i * ch], 0), gv = max(gray ? f[i * ch] : f[i * ch + 1], 0), bv = max(gray ? f[i * ch] : f[i * ch + 2], 0)
            let v = max(rv, gv, bv)
            if v < 1e-32 { o += [0, 0, 0, 0]; continue }
            let e = Int(frexp(v).1)
            let scale = Float(256) / Float(sign: .plus, exponent: e, significand: 1)
            o += [UInt8(min(rv * scale, 255)), UInt8(min(gv * scale, 255)), UInt8(min(bv * scale, 255)), UInt8(e + 128)]
        }
        return Data(o)
    }

    // MARK: FITS (photocraft fits.rs)

    static let fitsStructural: Set<String> = ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "EXTEND", "BZERO", "BSCALE",
                                              "BLANK", "END", "XTENSION", "PCOUNT", "GCOUNT", "ROWORDER", "CHECKSUM", "DATASUM", "DATAMIN", "DATAMAX", "ZIMAGE"]

    static func decodeFITS(_ d: Data) throws -> (RasterBuffer, [TextEntry], [DecodeWarning]) {
        let b = [UInt8](d)
        var cards: [(String, String)] = []
        var p = 0, ended = false
        while !ended {
            guard p + 2880 <= b.count else { throw bad("FITS", "truncated header") }
            for c in 0..<36 {
                let card = String(decoding: b[(p + c * 80)..<(p + c * 80 + 80)], as: UTF8.self)
                let key = card.prefix(8).trimmingCharacters(in: .whitespaces)
                if key == "END" { ended = true; break }
                if card.dropFirst(8).hasPrefix("= ") {
                    var v = String(card.dropFirst(10))
                    if let q = v.firstIndex(of: "'"), let q2 = v[v.index(after: q)...].firstIndex(of: "'") {
                        v = String(v[v.index(after: q)..<q2]).trimmingCharacters(in: .whitespaces)
                    } else if let slash = v.firstIndex(of: "/") { v = String(v[..<slash]).trimmingCharacters(in: .whitespaces) }
                    else { v = v.trimmingCharacters(in: .whitespaces) }
                    cards.append((key, v))
                } else if key == "COMMENT" || key == "HISTORY" {
                    cards.append((key, String(card.dropFirst(8)).trimmingCharacters(in: .whitespaces)))
                }
            }
            p += 2880
        }
        func val(_ k: String) -> String? { cards.first { $0.0 == k }?.1 }
        func num(_ k: String) -> Double? { val(k).flatMap { Double($0.replacingOccurrences(of: "D", with: "E")) } }
        if val("ZIMAGE") == "T" { throw PlatformError.unsupported("FITS tile compression (fpack)") }
        guard let bitpix = num("BITPIX").map(Int.init), let naxis = num("NAXIS").map(Int.init), naxis >= 2,
              let w = num("NAXIS1").map(Int.init), let h = num("NAXIS2").map(Int.init), w > 0, h > 0 else { throw bad("FITS", "no image in the primary HDU") }
        let planes = naxis >= 3 ? Int(num("NAXIS3") ?? 1) : 1
        var warnings: [DecodeWarning] = []
        let rgb = planes == 3
        if planes > 1 && !rgb { warnings.append(.morePages(total: planes)) }
        let bs = num("BSCALE") ?? 1, bz = num("BZERO") ?? 0, blank = num("BLANK")
        let bytes = abs(bitpix) / 8
        let n = w * h, ch = rgb ? 3 : 1
        guard [8, 16, 32, 64, -32, -64].contains(bitpix), p + n * ch * bytes <= b.count else { throw bad("FITS", "data truncated or BITPIX \(bitpix)") }
        let topDown = (val("ROWORDER") ?? "").uppercased().hasPrefix("TOP")
        var phys = [Double](repeating: 0, count: n * ch)
        for plane in 0..<ch {
            for y in 0..<h {
                let dy = topDown ? y : h - 1 - y
                for x in 0..<w {
                    let o = p + ((plane * h + y) * w + x) * bytes
                    var v: Double
                    switch bitpix {
                    case 8: v = Double(b[o])
                    case 16: v = Double(Int16(bitPattern: UInt16(b[o]) << 8 | UInt16(b[o + 1])))
                    case 32: v = Double(Int32(bitPattern: (0..<4).reduce(0) { $0 << 8 | UInt32(b[o + $1]) }))
                    case 64: v = Double(Int64(bitPattern: (0..<8).reduce(0) { $0 << 8 | UInt64(b[o + $1]) }))
                    case -32: v = Double(Float(bitPattern: (0..<4).reduce(0) { $0 << 8 | UInt32(b[o + $1]) }))
                    default: v = Double(bitPattern: (0..<8).reduce(0) { $0 << 8 | UInt64(b[o + $1]) })
                    }
                    if let blank, bitpix > 0, v == blank { v = .nan }
                    else if bitpix > 0 { v = v * bs + bz } else { v = v * bs + bz }
                    phys[(dy * w + x) * ch + plane] = v.isFinite ? v : 0
                }
            }
        }
        let integral = bitpix > 0 && bs == 1 && bz == bz.rounded()
        let lo = phys.min() ?? 0, hi = phys.max() ?? 0
        let format: PixelFormat
        var floats: [Float]
        if integral && lo >= 0 && hi <= 255 && bitpix == 8 {
            format = PixelFormat(mode: rgb ? .rgb : .grayscale, sample: .u8, alpha: false)
            floats = phys.map { Float($0 / 255) }
        } else if integral && lo >= 0 && hi <= 65535 {
            format = PixelFormat(mode: rgb ? .rgb : .grayscale, sample: .u16, alpha: false)
            floats = phys.map { Float($0 / 65535) }
        } else {
            format = PixelFormat(mode: rgb ? .rgb : .grayscale, sample: .f32, alpha: false)
            // photocraft's normalisation: ≤ 2 already normalised; ≤ 65535 → /65535; else /max.
            let div: Double = hi <= 2 ? 1 : (hi <= 65535 ? 65535 : hi)
            floats = phys.map { Float($0 / div) }
        }
        let text = cards.filter { !fitsStructural.contains($0.0) }.map { TextEntry(key: $0.0, value: $0.1) }
        return (RasterBuffer(width: w, height: h, format: format, floats: floats), text, warnings)
    }

    static func encodeFITS(_ r: RasterBuffer, text: [TextEntry]) throws -> Data {
        let gray = r.format.mode.isGrayLike
        guard gray || r.format.mode.isRGBLike else { throw PlatformError.invalidArgument("FITS stores gray or RGB") }
        let ch = gray ? 1 : 3, w = r.width, h = r.height, src = r.format.channels
        let f = r.floats()
        var cards: [String] = []
        func card(_ k: String, _ v: String) { cards.append(k.padding(toLength: 8, withPad: " ", startingAt: 0) + "= " + String(repeating: " ", count: max(0, 20 - v.count)) + v) }
        func str(_ k: String, _ v: String) { cards.append(k.padding(toLength: 8, withPad: " ", startingAt: 0) + "= '" + v.replacingOccurrences(of: "'", with: "''").padding(toLength: max(8, v.count), withPad: " ", startingAt: 0) + "'") }
        let bitpix = r.format.sample == .u8 ? 8 : (r.format.sample == .u16 ? 16 : -32)
        card("SIMPLE", "T"); card("BITPIX", "\(bitpix)"); card("NAXIS", ch == 3 ? "3" : "2")
        card("NAXIS1", "\(w)"); card("NAXIS2", "\(h)")
        if ch == 3 { card("NAXIS3", "3") }
        if bitpix == 16 { card("BZERO", "32768"); card("BSCALE", "1") }
        str("ROWORDER", "BOTTOM-UP")
        for t in text where !fitsStructural.contains(t.key.uppercased()) && t.key.count <= 8 {
            if t.key == "COMMENT" || t.key == "HISTORY" { cards.append(t.key.padding(toLength: 8, withPad: " ", startingAt: 0) + t.value) }
            else { str(t.key.uppercased(), t.value) }
        }
        cards.append("END")
        var o: [UInt8] = []
        for c in cards { o += Array(c.prefix(80).padding(toLength: 80, withPad: " ", startingAt: 0).utf8) }
        while o.count % 2880 != 0 { o.append(32) }
        for plane in 0..<ch {
            for y in stride(from: h - 1, through: 0, by: -1) {
                for x in 0..<w {
                    let v = f[(y * w + x) * src + (gray ? 0 : plane)]
                    switch bitpix {
                    case 8: o.append(UInt8(min(max(v, 0), 1) * 255 + 0.5))
                    case 16:
                        let u = Int(min(max(v, 0), 1) * 65535 + 0.5) - 32768
                        withUnsafeBytes(of: Int16(u).bigEndian) { o += $0 }
                    default: withUnsafeBytes(of: v.bitPattern.bigEndian) { o += $0 }
                    }
                }
            }
        }
        while o.count % 2880 != 0 { o.append(0) }
        return Data(o)
    }
}
