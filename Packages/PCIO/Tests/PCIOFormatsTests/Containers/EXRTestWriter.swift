// A small OpenEXR writer for the multi-part EXR tests: scan-line and tiled (one level or
// mipmapped) parts, single- and multi-part files, every channel type and sampling, and the
// NONE, RLE, ZIPS, ZIP, PIZ, PXR24 and B44/B44A encoders, written from the OpenEXR file layout
// and the reference library's algorithms. It stands in for the `exr` crate photocraft's tests
// write fixtures with. Fixtures are built in memory, never committed.
// Test support for the port of photocraft-io (crates/io/src/exr_parts.rs), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCIOCore
@testable import PCIOFormats

extension ContainerTestKit {
    struct EXRChannel {
        var name: String
        var type: EXRParts.PixelType
        var xSampling = 1
        var ySampling = 1
        var linear = false
        /// Plane of samples (numSamples(xSampling) × numSamples(ySampling) over the data window);
        /// half channels are rounded to half, uint ones truncated.
        var values: [Float]
    }

    struct EXRPart {
        var name: String?
        var view: String?
        var x0 = 0, y0 = 0
        var width: Int
        var height: Int
        var compression: EXRParts.Compression = .none
        var channels: [EXRChannel]
        /// Tile size, for a tiled part.
        var tile: (Int, Int)?
        /// Writes mip levels below level 0 (filled with zeros) too.
        var mipmap = false
        /// 1 = decreasing y: chunks in reverse order.
        var lineOrder: UInt8 = 0
        var strings: [(String, String)] = []
        /// Overrides the `type` attribute.
        var type: String?
    }

    /// An EXR file of `parts` (multi-part when more than one, or when `multipart` is set).
    static func exr(_ parts: [EXRPart], multipart forced: Bool = false) -> [UInt8] {
        let multipart = forced || parts.count > 1
        var w = LE()
        w.u32(20_000_630)
        var version: UInt32 = 2
        if multipart { version |= 0x1000 } else if parts.first?.tile != nil { version |= 0x200 }
        let names = parts.flatMap { p in p.channels.map(\.name) + [p.name ?? ""] + p.strings.map(\.0) }
        if names.contains(where: { $0.utf8.count > 31 }) { version |= 0x400 }
        w.u32(version)
        var chunkCounts: [Int] = []
        for p in parts {
            let channels = sorted(p.channels)
            var chunks = 0
            if let (tx, ty) = p.tile {
                for (lw, lh) in levels(p) { chunks += ((lw + tx - 1) / tx) * ((lh + ty - 1) / ty) }
            } else {
                chunks = (p.height + p.compression.linesPerBlock - 1) / p.compression.linesPerBlock
            }
            chunkCounts.append(chunks)
            var chlist = LE()
            for c in channels {
                chlist.cString(c.name)
                chlist.i32(c.type.rawValue)
                chlist.b += [c.linear ? 1 : 0, 0, 0, 0]
                chlist.i32(Int32(c.xSampling))
                chlist.i32(Int32(c.ySampling))
            }
            chlist.b.append(0)
            w.attribute("channels", "chlist", chlist.b)
            w.attribute("compression", "compression", [p.compression.rawValue])
            var box = LE()
            for v in [p.x0, p.y0, p.x0 + p.width - 1, p.y0 + p.height - 1] { box.i32(Int32(v)) }
            w.attribute("dataWindow", "box2i", box.b)
            w.attribute("displayWindow", "box2i", box.b)
            w.attribute("lineOrder", "lineOrder", [p.lineOrder])
            w.attribute("pixelAspectRatio", "float", LE.f32(1))
            w.attribute("screenWindowCenter", "v2f", LE.f32(0) + LE.f32(0))
            w.attribute("screenWindowWidth", "float", LE.f32(1))
            if let (tx, ty) = p.tile {
                var t = LE()
                t.u32(UInt32(tx)); t.u32(UInt32(ty))
                t.b.append(p.mipmap ? 1 : 0)
                w.attribute("tiles", "tiledesc", t.b)
            }
            if let n = p.name { w.attribute("name", "string", Array(n.utf8)) }
            if let v = p.view { w.attribute("view", "string", Array(v.utf8)) }
            if multipart || p.type != nil {
                w.attribute("type", "string", Array((p.type ?? (p.tile != nil ? "tiledimage" : "scanlineimage")).utf8))
            }
            if multipart {
                var c = LE()
                c.i32(Int32(chunks))
                w.attribute("chunkCount", "int", c.b)
            }
            for (k, v) in p.strings { w.attribute(k, "string", Array(v.utf8)) }
            w.b.append(0)
        }
        if multipart { w.b.append(0) }
        // Offset tables, patched below.
        var tableAt: [Int] = []
        for n in chunkCounts {
            tableAt.append(w.b.count)
            w.b += [UInt8](repeating: 0, count: 8 * n)
        }
        for (pi, p) in parts.enumerated() {
            let channels = sorted(p.channels)
            var entries: [(index: Int, header: [Int32], data: [UInt8])] = []
            if let (tx, ty) = p.tile {
                var index = 0
                for (level, (lw, lh)) in levels(p).enumerated() {
                    let nx = (lw + tx - 1) / tx, ny = (lh + ty - 1) / ty
                    for j in 0 ..< ny {
                        for i in 0 ..< nx {
                            let bx0 = p.x0 + i * tx, by0 = p.y0 + j * ty
                            let bx1 = min(bx0 + tx, p.x0 + lw) - 1, by1 = min(by0 + ty, p.y0 + lh) - 1
                            let raw = level == 0 ? rawBlock(p, channels, bx0, by0, bx1, by1)
                                : [UInt8](repeating: 0, count: (bx1 - bx0 + 1) * (by1 - by0 + 1) * channels.reduce(0) { $0 + $1.type.bytes })
                            let data = compress(raw, p.compression, channels, bx0, by0, bx1, by1)
                            entries.append((index, [Int32(i), Int32(j), Int32(level), Int32(level)], data))
                            index += 1
                        }
                    }
                }
            } else {
                let lpb = p.compression.linesPerBlock
                for (k, y) in stride(from: p.y0, through: p.y0 + p.height - 1, by: lpb).enumerated() {
                    let y1 = min(y + lpb, p.y0 + p.height) - 1
                    let raw = rawBlock(p, channels, p.x0, y, p.x0 + p.width - 1, y1)
                    entries.append((k, [Int32(y)], compress(raw, p.compression, channels, p.x0, y, p.x0 + p.width - 1, y1)))
                }
            }
            if p.lineOrder == 1 { entries.reverse() }
            for e in entries {
                let offset = UInt64(w.b.count)
                for k in 0 ..< 8 { w.b[tableAt[pi] + 8 * e.index + k] = UInt8(truncatingIfNeeded: offset >> (8 * k)) }
                if multipart { w.i32(Int32(pi)) }
                for v in e.header { w.i32(v) }
                w.i32(Int32(e.data.count))
                w.b += e.data
            }
        }
        return w.b
    }

    /// Channels in the header's (byte-wise alphabetical) order.
    static func sorted(_ c: [EXRChannel]) -> [EXRChannel] {
        c.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
    }

    /// Mip level sizes (round down), level 0 only without `mipmap`.
    static func levels(_ p: EXRPart) -> [(Int, Int)] {
        guard p.mipmap else { return [(p.width, p.height)] }
        var out: [(Int, Int)] = []
        var n = 0
        var m = max(p.width, p.height)
        while m > 1 { m >>= 1; n += 1 }
        for l in 0 ... n { out.append((max(1, p.width >> l), max(1, p.height >> l))) }
        return out
    }

    /// The uncompressed block (lines of channels, little-endian) of [x0, x1] × [y0, y1].
    static func rawBlock(_ p: EXRPart, _ channels: [EXRChannel], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [UInt8] {
        var w = LE()
        for y in y0 ... y1 {
            for c in channels {
                if EXRParts.modp(y, c.ySampling) != 0 { continue }
                let row = EXRParts.numSamples(c.ySampling, p.y0, y) - 1
                let pw = EXRParts.numSamples(c.xSampling, p.x0, p.x0 + p.width - 1)
                let col0 = EXRParts.numSamples(c.xSampling, p.x0, x0 - 1)
                for i in 0 ..< EXRParts.numSamples(c.xSampling, x0, x1) {
                    let v = c.values[row * pw + col0 + i]
                    switch c.type {
                    case .half: w.u16(floatToHalf(v))
                    case .float: w.u32(v.bitPattern)
                    case .uint: w.u32(UInt32(v))
                    }
                }
            }
        }
        return w.b
    }

    /// Float to half, round to nearest even (enough for test values).
    static func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16(bits >> 16 & 0x8000)
        let exp = Int(bits >> 23 & 0xFF)
        var mant = bits & 0x7F_FFFF
        if exp == 255 { return sign | 0x7C00 | (mant != 0 ? 0x200 : 0) }
        let e = exp - 127 + 15
        if e >= 31 { return sign | 0x7C00 }
        if e <= 0 {
            if e < -10 { return sign }
            mant |= 0x80_0000
            let shift = UInt32(14 - e)
            var h = mant >> shift
            let rem = mant & ((1 << shift) - 1), half = UInt32(1) << (shift - 1)
            if rem > half || (rem == half && h & 1 != 0) { h += 1 }
            return sign | UInt16(h)
        }
        var h = UInt32(e) << 10 | mant >> 13
        let rem = mant & 0x1FFF
        if rem > 0x1000 || (rem == 0x1000 && h & 1 != 0) { h += 1 }
        return sign | UInt16(h)
    }

    // MARK: - Encoders

    static func compress(_ raw: [UInt8], _ c: EXRParts.Compression, _ channels: [EXRChannel], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [UInt8] {
        let packed: [UInt8]
        switch c {
        case .none: return raw
        case .rle: packed = rle(preprocess(raw))
        case .zips, .zip: packed = (try? Deflate.zlibDeflate(preprocess(raw))) ?? []
        case .piz: packed = piz(raw, channels, x0, y0, x1, y1)
        case .pxr24: packed = pxr24(raw, channels, x0, y0, x1, y1)
        case .b44, .b44a: packed = b44(raw, channels, x0, y0, x1, y1, flat: c == .b44a)
        default: return raw
        }
        // As OpenEXR: data that does not shrink is stored as it is.
        return packed.count < raw.count ? packed : raw
    }

    /// Splits even and odd bytes into two halves, then applies the delta predictor.
    static func preprocess(_ raw: [UInt8]) -> [UInt8] {
        let n = raw.count
        var t = [UInt8](repeating: 0, count: n)
        var a = 0, b = (n + 1) / 2
        var i = 0
        while i < n {
            t[a] = raw[i]; a += 1
            if i + 1 < n { t[b] = raw[i + 1]; b += 1 }
            i += 2
        }
        var p = n > 0 ? Int(t[0]) : 0
        for k in 1 ..< max(1, n) {
            let d = Int(t[k]) - p + 128 + 256
            p = Int(t[k])
            t[k] = UInt8(truncatingIfNeeded: d)
        }
        return t
    }

    static func rle(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        let n = src.count
        while i < n {
            var r = 1
            while i + r < n && src[i + r] == src[i] && r < 128 { r += 1 }
            if r >= 3 {
                out.append(UInt8(r - 1))
                out.append(src[i])
                i += r
            } else {
                var j = i
                while j < n && j - i < 127 {
                    if j + 2 < n && src[j] == src[j + 1] && src[j] == src[j + 2] { break }
                    j += 1
                }
                if j == i { j = i + 1 }
                out.append(UInt8(bitPattern: Int8(-(j - i))))
                out += src[i ..< j]
                i = j
            }
        }
        return out
    }

    static func pxr24(_ raw: [UInt8], _ channels: [EXRChannel], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [UInt8] {
        var tmp: [UInt8] = []
        var at = 0
        for y in y0 ... y1 {
            for c in channels {
                if EXRParts.modp(y, c.ySampling) != 0 { continue }
                let n = EXRParts.numSamples(c.xSampling, x0, x1)
                var planes = [[UInt8]](repeating: [], count: c.type == .half ? 2 : c.type == .float ? 3 : 4)
                var prev: UInt32 = 0
                for _ in 0 ..< n {
                    var v: UInt32 = 0
                    for k in 0 ..< c.type.bytes { v |= UInt32(raw[at + k]) << (8 * k) }
                    at += c.type.bytes
                    switch c.type {
                    case .half:
                        let d = v &- prev
                        prev = v
                        planes[0].append(UInt8(truncatingIfNeeded: d >> 8)); planes[1].append(UInt8(truncatingIfNeeded: d))
                    case .uint:
                        let d = v &- prev
                        prev = v
                        for k in 0 ..< 4 { planes[k].append(UInt8(truncatingIfNeeded: d >> (24 - 8 * k))) }
                    case .float:
                        let f24 = float24(v)
                        let d = f24 &- prev
                        prev = f24
                        for k in 0 ..< 3 { planes[k].append(UInt8(truncatingIfNeeded: d >> (16 - 8 * k))) }
                    }
                }
                for plane in planes { tmp += plane }
            }
        }
        return (try? Deflate.zlibDeflate(tmp)) ?? []
    }

    static func float24(_ u: UInt32) -> UInt32 {
        let s = u & 0x8000_0000, e = u & 0x7F80_0000
        var m = u & 0x007F_FFFF
        var i: UInt32
        if e == 0x7F80_0000 {
            if m != 0 {
                m >>= 8
                i = (e >> 8) | m | (m == 0 ? 1 : 0)
            } else {
                i = e >> 8
            }
        } else {
            i = ((e | m) + (m & 0x80)) >> 8
            if i >= 0x7F_8000 { i = (e | m) >> 8 }
        }
        return (s >> 8) | i
    }

    // MARK: B44

    static func b44(_ raw: [UInt8], _ channels: [EXRChannel], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, flat: Bool) -> [UInt8] {
        // Planar channel data, as the compressor's buffer.
        var planes: [[UInt16]] = channels.map { _ in [] }
        var at = 0
        for y in y0 ... y1 {
            for (k, c) in channels.enumerated() {
                if EXRParts.modp(y, c.ySampling) != 0 { continue }
                let n = EXRParts.numSamples(c.xSampling, x0, x1) * c.type.bytes / 2
                for _ in 0 ..< n {
                    planes[k].append(UInt16(raw[at]) | UInt16(raw[at + 1]) << 8)
                    at += 2
                }
            }
        }
        var out: [UInt8] = []
        for (k, c) in channels.enumerated() {
            if c.type != .half {
                for v in planes[k] { out += [UInt8(v & 0xFF), UInt8(v >> 8)] }
                continue
            }
            let nx = EXRParts.numSamples(c.xSampling, x0, x1), ny = EXRParts.numSamples(c.ySampling, y0, y1)
            var y = 0
            while y < ny {
                var x = 0
                while x < nx {
                    var s = [UInt16](repeating: 0, count: 16)
                    for r in 0 ..< 4 {
                        let yy = min(y + r, ny - 1)
                        for q in 0 ..< 4 { s[r * 4 + q] = planes[k][yy * nx + min(x + q, nx - 1)] }
                    }
                    out += b44Pack(s, flat: flat, exactMax: !c.linear)
                    x += 4
                }
                y += 4
            }
        }
        return out
    }

    static func b44Pack(_ s: [UInt16], flat: Bool, exactMax: Bool) -> [UInt8] {
        func shiftAndRound(_ xIn: Int, _ shiftIn: Int) -> Int {
            let x = xIn << 1
            let a = (1 << shiftIn) - 1
            let shift = shiftIn + 1
            let b = (x >> shift) & 1
            return (x + a + b) >> shift
        }
        var t = s.map { v -> UInt16 in
            if v & 0x7C00 == 0x7C00 { return 0x8000 }
            return v & 0x8000 != 0 ? ~v : v | 0x8000
        }
        let tMax = t.max() ?? 0
        var shift = -1
        var d = [Int](repeating: 0, count: 16), r = [Int](repeating: 0, count: 15)
        repeat {
            shift += 1
            for i in 0 ..< 16 { d[i] = shiftAndRound(Int(tMax) - Int(t[i]), shift) }
            let bias = 0x20
            let pairs = [(0, 4), (4, 8), (8, 12), (0, 1), (4, 5), (8, 9), (12, 13), (1, 2), (5, 6), (9, 10), (13, 14), (2, 3), (6, 7), (10, 11), (14, 15)]
            for (i, (a, b)) in pairs.enumerated() { r[i] = d[a] - d[b] + bias }
        } while (r.min() ?? 0) < 0 || (r.max() ?? 0) > 0x3F
        if r.allSatisfy({ $0 == 0x20 }) && flat {
            return [UInt8(t[0] >> 8), UInt8(t[0] & 0xFF), 0xFC]
        }
        if exactMax { t[0] = UInt16(truncatingIfNeeded: Int(tMax) - (d[0] << shift)) }
        func u8(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }
        return [u8(Int(t[0]) >> 8), u8(Int(t[0])), u8((shift << 2) | (r[0] >> 4)), u8((r[0] << 4) | (r[1] >> 2)), u8((r[1] << 6) | r[2]),
                u8((r[3] << 2) | (r[4] >> 4)), u8((r[4] << 4) | (r[5] >> 2)), u8((r[5] << 6) | r[6]),
                u8((r[7] << 2) | (r[8] >> 4)), u8((r[8] << 4) | (r[9] >> 2)), u8((r[9] << 6) | r[10]),
                u8((r[11] << 2) | (r[12] >> 4)), u8((r[12] << 4) | (r[13] >> 2)), u8((r[13] << 6) | r[14])]
    }

    // MARK: PIZ

    static func piz(_ raw: [UInt8], _ channels: [EXRChannel], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> [UInt8] {
        struct CD { var start: Int; var end: Int; var nx: Int; var ny: Int; var size: Int }
        var cds: [CD] = []
        var total = 0
        for c in channels {
            let nx = EXRParts.numSamples(c.xSampling, x0, x1), ny = EXRParts.numSamples(c.ySampling, y0, y1)
            let size = c.type.bytes / 2
            cds.append(CD(start: total, end: total, nx: nx, ny: ny, size: size))
            total += nx * ny * size
        }
        var tmp = [UInt16](repeating: 0, count: total)
        var at = 0
        for y in y0 ... y1 {
            for (k, c) in channels.enumerated() {
                if EXRParts.modp(y, c.ySampling) != 0 { continue }
                let n = cds[k].nx * cds[k].size
                for i in 0 ..< n { tmp[cds[k].end + i] = UInt16(raw[at + 2 * i]) | UInt16(raw[at + 2 * i + 1]) << 8 }
                at += 2 * n
                cds[k].end += n
            }
        }
        var bitmap = [UInt8](repeating: 0, count: 8192)
        for v in tmp { bitmap[Int(v >> 3)] |= 1 << (v & 7) }
        bitmap[0] &= ~1
        var minNZ = 8191, maxNZ = 0
        for i in 0 ..< 8192 where bitmap[i] != 0 { minNZ = min(minNZ, i); maxNZ = max(maxNZ, i) }
        var lut = [UInt16](repeating: 0, count: 65536)
        var k = 0
        for i in 0 ..< 65536 {
            if i == 0 || bitmap[i >> 3] & (1 << (i & 7)) != 0 {
                lut[i] = UInt16(k)
                k += 1
            }
        }
        let maxValue = UInt16(k - 1)
        for i in tmp.indices { tmp[i] = lut[Int(tmp[i])] }
        var out = LE()
        out.u16(UInt16(minNZ))
        out.u16(UInt16(maxNZ))
        if minNZ <= maxNZ { out.b += bitmap[minNZ ... maxNZ] }
        tmp.withUnsafeMutableBufferPointer { t in
            for cd in cds where cd.nx > 0 && cd.ny > 0 {
                for j in 0 ..< cd.size { wav2Encode(t.baseAddress! + cd.start + j, cd.nx, cd.size, cd.ny, cd.nx * cd.size, maxValue) }
            }
        }
        let huff = hufCompress(tmp)
        out.i32(Int32(huff.count))
        out.b += huff
        return out.b
    }

    static func wav2Encode(_ p: UnsafeMutablePointer<UInt16>, _ nx: Int, _ ox: Int, _ ny: Int, _ oy: Int, _ mx: UInt16) {
        let w14 = mx < (1 << 14)
        func enc(_ a: UInt16, _ b: UInt16) -> (UInt16, UInt16) {
            if w14 {
                let as_ = Int(Int16(bitPattern: a)), bs = Int(Int16(bitPattern: b))
                return (UInt16(truncatingIfNeeded: (as_ + bs) >> 1), UInt16(truncatingIfNeeded: as_ - bs))
            }
            let ao = (Int(a) + 0x8000) & 0xFFFF
            var m = (ao + Int(b)) >> 1
            var d = ao - Int(b)
            if d < 0 { m = (m + 0x8000) & 0xFFFF }
            d &= 0xFFFF
            return (UInt16(m), UInt16(d))
        }
        let n = min(nx, ny)
        var lv = 1, lv2 = 2
        while lv2 <= n {
            var py = 0
            let ey = oy * (ny - lv2)
            let oy1 = oy * lv, oy2 = oy * lv2, ox1 = ox * lv, ox2 = ox * lv2
            while py <= ey {
                var px = py
                let ex = py + ox * (nx - lv2)
                while px <= ex {
                    let p01 = px + ox1, p10 = px + oy1, p11 = p10 + ox1
                    let (i00, i01) = enc(p[px], p[p01])
                    let (i10, i11) = enc(p[p10], p[p11])
                    (p[px], p[p10]) = enc(i00, i10)
                    (p[p01], p[p11]) = enc(i01, i11)
                    px += ox2
                }
                if nx & lv != 0 {
                    let p10 = px + oy1
                    let (i00, v) = enc(p[px], p[p10])
                    p[p10] = v
                    p[px] = i00
                }
                py += oy2
            }
            if ny & lv != 0 {
                var px = py
                let ex = py + ox * (nx - lv2)
                while px <= ex {
                    let p01 = px + ox1
                    let (i00, v) = enc(p[px], p[p01])
                    p[p01] = v
                    p[px] = i00
                    px += ox2
                }
            }
            lv = lv2
            lv2 <<= 1
        }
    }

    /// OpenEXR's Huffman encoder: code lengths from the frequencies (plus a run-length symbol),
    /// canonical codes, the packed length table, then the codes with run-length coding.
    static func hufCompress(_ raw: [UInt16]) -> [UInt8] {
        if raw.isEmpty { return [] }
        let encSize = 65537
        var freq = [Int64](repeating: 0, count: encSize)
        for v in raw { freq[Int(v)] += 1 }
        var im = 0
        while freq[im] == 0 { im += 1 }
        var iM = 0
        var hlink = Array(0 ..< encSize)
        var live: [Int] = []
        for i in im ..< encSize where freq[i] != 0 { live.append(i); iM = i }
        iM += 1
        freq[iM] = 1
        live.append(iM)
        var scode = [UInt64](repeating: 0, count: encSize)
        while live.count > 1 {
            live.sort { freq[$0] != freq[$1] ? freq[$0] < freq[$1] : $0 < $1 }
            let mm = live.removeFirst()
            let m = live[0]
            freq[m] += freq[mm]
            var j = m
            while true {
                scode[j] += 1
                if hlink[j] == j { hlink[j] = mm; break }
                j = hlink[j]
            }
            j = mm
            while true {
                scode[j] += 1
                if hlink[j] == j { break }
                j = hlink[j]
            }
        }
        // Canonical codes.
        var n = [UInt64](repeating: 0, count: 59)
        for l in scode { n[Int(l)] += 1 }
        var c: UInt64 = 0
        for i in stride(from: 58, to: 0, by: -1) {
            let nc = (c + n[i]) >> 1
            n[i] = c
            c = nc
        }
        for i in 0 ..< encSize where scode[i] > 0 {
            let l = scode[i]
            scode[i] = l | n[Int(l)] << 6
            n[Int(l)] += 1
        }
        var bits = BitWriter()
        // Packed table.
        var i = im
        while i <= iM {
            let l = scode[i] & 63
            if l == 0 {
                var zerun = 1
                while i < iM && zerun < 261 {
                    if scode[i + 1] & 63 > 0 { break }
                    i += 1
                    zerun += 1
                }
                if zerun >= 2 {
                    if zerun >= 6 {
                        bits.put(6, 63)
                        bits.put(8, UInt64(zerun - 6))
                    } else {
                        bits.put(6, UInt64(59 + zerun - 2))
                    }
                    i += 1
                    continue
                }
            }
            bits.put(6, l)
            i += 1
        }
        let table = bits.finish()
        // Data.
        var data = BitWriter()
        func code(_ h: UInt64) { data.put(Int(h & 63), h >> 6) }
        func send(_ s: Int, _ run: Int) {
            let sc = scode[s], rc = scode[iM]
            if Int(sc & 63) + Int(rc & 63) + 8 < Int(sc & 63) * run {
                code(sc); code(rc); data.put(8, UInt64(run))
            } else {
                for _ in 0 ... run { code(sc) }
            }
        }
        var s = Int(raw[0]), cs = 0
        for k in 1 ..< raw.count {
            if s == Int(raw[k]) && cs < 255 {
                cs += 1
            } else {
                send(s, cs)
                cs = 0
            }
            s = Int(raw[k])
        }
        send(s, cs)
        let nBits = data.count
        let payload = data.finish()
        var out = LE()
        out.u32(UInt32(im)); out.u32(UInt32(iM)); out.u32(UInt32(table.count)); out.u32(UInt32(nBits)); out.u32(0)
        return out.b + table + payload
    }

    struct BitWriter {
        var out: [UInt8] = []
        var c: UInt64 = 0
        var lc = 0
        var count = 0

        mutating func put(_ n: Int, _ v: UInt64) {
            c = c << UInt64(n) | v
            lc += n
            count += n
            while lc >= 8 {
                lc -= 8
                out.append(UInt8(truncatingIfNeeded: c >> UInt64(lc)))
            }
        }

        func finish() -> [UInt8] {
            lc > 0 ? out + [UInt8(truncatingIfNeeded: c << UInt64(8 - lc))] : out
        }
    }

    struct LE {
        var b: [UInt8] = []
        mutating func u16(_ v: UInt16) { b += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        mutating func u32(_ v: UInt32) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        mutating func cString(_ s: String) { b += Array(s.utf8) + [0] }
        mutating func attribute(_ name: String, _ type: String, _ value: [UInt8]) {
            cString(name)
            cString(type)
            i32(Int32(value.count))
            b += value
        }
        static func f32(_ v: Float) -> [UInt8] { var w = LE(); w.u32(v.bitPattern); return w.b }
    }
}
