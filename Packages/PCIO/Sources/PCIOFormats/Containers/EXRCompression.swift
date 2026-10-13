// OpenEXR block decompression: NONE, RLE, ZIPS, ZIP, PIZ (wavelet + Huffman), PXR24 and
// B44/B44A. photocraft decodes through the pure-Rust `exr` crate (MIT OR Apache-2.0), which
// handles the same set; this is written from the OpenEXR file-layout documentation and the
// algorithms of the OpenEXR reference library (BSD-3-Clause, © Contributors to the OpenEXR
// Project), whose bit layouts every reader must reproduce. Part of the port of photocraft-io
// (crates/io/src/exr_parts.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.
//
// DWAA, DWAB and HTJ2K blocks are refused (the `exr` crate refuses DWA as well).
// Every decoder works into buffers sized from the header and fails, never traps, on bad data.

import PCIOCore

extension EXRParts {
    /// Decompresses the blocks of one part into the uncompressed block layout (for each line,
    /// for each channel in header order, its samples, little-endian). Holds the PIZ tables so a
    /// part's blocks reuse them.
    final class BlockDecoder {
        let compression: Compression
        let channels: [ChannelInfo]
        private lazy var huffman = Huffman()
        private lazy var lut = [UInt16](repeating: 0, count: 65536)

        init(compression: Compression, channels: [ChannelInfo]) {
            self.compression = compression
            self.channels = channels
        }

        /// Uncompressed size of the block covering [x0, x1] × [y0, y1].
        func expectedSize(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            var n = 0
            for c in channels {
                let lines = numSamples(c.ySampling, y0, y1)
                n += lines * numSamples(c.xSampling, x0, x1) * c.type.bytes
            }
            return n
        }

        func decode(_ packed: ArraySlice<UInt8>, x0: Int, y0: Int, x1: Int, y1: Int) throws -> [UInt8] {
            let expected = expectedSize(x0, y0, x1, y1)
            // A block that did not compress is stored as it is, whatever the compression.
            if packed.count == expected { return Array(packed) }
            switch compression {
            case .none:
                throw malformed("uncompressed block of \(packed.count) bytes, expected \(expected)")
            case .rle:
                var t = try rleDecode(packed, expected)
                return predictorInterleave(&t)
            case .zips, .zip:
                var t: [UInt8]
                do { t = try Deflate.zlibInflate(Array(packed), limit: expected) } catch { throw malformed("zip block: \(OpenRaster.errorText(error))") }
                guard t.count == expected else { throw malformed("zip block decompressed to \(t.count) bytes, expected \(expected)") }
                return predictorInterleave(&t)
            case .piz:
                return try piz(packed, x0, y0, x1, y1, expected)
            case .pxr24:
                return try pxr24(packed, x0, y0, x1, y1, expected)
            case .b44, .b44a:
                return try b44(packed, x0, y0, x1, y1, expected)
            case .dwaa, .dwab, .htj2k256, .htj2k32:
                throw codecUnsupported("not supported: \(compression.name) compression")
            }
        }

        // MARK: RLE / ZIP

        /// OpenEXR run-length decoding: a negative count byte -n is followed by n literal bytes, a
        /// non-negative count n by one byte repeated n + 1 times.
        private func rleDecode(_ src: ArraySlice<UInt8>, _ expected: Int) throws -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(expected)
            var i = src.startIndex
            while i < src.endIndex {
                let count = Int(Int8(bitPattern: src[i]))
                i += 1
                if count < 0 {
                    let n = -count
                    guard src.endIndex - i >= n, out.count + n <= expected else { throw malformed("rle block overruns its data") }
                    out += src[i ..< i + n]
                    i += n
                } else {
                    guard i < src.endIndex, out.count + count + 1 <= expected else { throw malformed("rle block overruns its data") }
                    out += repeatElement(src[i], count: count + 1)
                    i += 1
                }
            }
            guard out.count == expected else { throw malformed("rle block decompressed to \(out.count) bytes, expected \(expected)") }
            return out
        }

        /// Undoes the RLE/ZIP preprocessing: the delta predictor, then the split of even and odd
        /// bytes into two halves.
        private func predictorInterleave(_ t: inout [UInt8]) -> [UInt8] {
            let n = t.count
            guard n > 0 else { return t }
            var out = [UInt8](repeating: 0, count: n)
            t.withUnsafeMutableBufferPointer { b in
                for i in 1 ..< n { b[i] = b[i - 1] &+ b[i] &- 128 }
                out.withUnsafeMutableBufferPointer { o in
                    var a = 0, h = (n + 1) / 2, s = 0
                    while s < n {
                        o[s] = b[a]; a += 1; s += 1
                        if s < n { o[s] = b[h]; h += 1; s += 1 }
                    }
                }
            }
            return out
        }

        // MARK: PIZ

        private struct ChannelData {
            var start: Int
            var end: Int
            var nx: Int
            var ny: Int
            var ys: Int
            var size: Int
        }

        private func piz(_ packed: ArraySlice<UInt8>, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ expected: Int) throws -> [UInt8] {
            var cds: [ChannelData] = []
            var total = 0
            for c in channels {
                let nx = numSamples(c.xSampling, x0, x1), ny = numSamples(c.ySampling, y0, y1)
                let size = c.type.bytes / 2
                cds.append(ChannelData(start: total, end: total, nx: nx, ny: ny, ys: c.ySampling, size: size))
                total += nx * ny * size
            }
            guard total * 2 == expected else { throw malformed("piz block layout mismatch") }
            let src = Array(packed)
            var r = LEReader(src)
            let minNonZero = Int(try r.u8()) | Int(try r.u8()) << 8
            let maxNonZero = Int(try r.u8()) | Int(try r.u8()) << 8
            guard maxNonZero < pizBitmapSize else { throw malformed("piz bitmap out of range") }
            var bitmap = [UInt8](repeating: 0, count: pizBitmapSize)
            if minNonZero <= maxNonZero {
                let b = try r.bytes(maxNonZero - minNonZero + 1)
                bitmap.replaceSubrange(minNonZero ... maxNonZero, with: b)
            }
            let maxValue = reverseLut(bitmap, &lut)
            let length = Int(try r.i32())
            guard length >= 0, length <= r.remaining else { throw malformed("piz huffman data out of range") }
            var tmp = [UInt16](repeating: 0, count: total)
            try src.withUnsafeBufferPointer { s in
                try tmp.withUnsafeMutableBufferPointer { t in
                    try huffman.uncompress(UnsafeBufferPointer(rebasing: s[r.pos ..< r.pos + length]), t)
                }
            }
            tmp.withUnsafeMutableBufferPointer { t in
                guard let base = t.baseAddress else { return }
                for cd in cds where cd.nx > 0 && cd.ny > 0 {
                    for j in 0 ..< cd.size {
                        wav2Decode(base + cd.start + j, cd.nx, cd.size, cd.ny, cd.nx * cd.size, maxValue)
                    }
                }
                lut.withUnsafeBufferPointer { l in
                    for i in 0 ..< t.count { t[i] = l[Int(t[i])] }
                }
            }
            var out = [UInt8](repeating: 0, count: expected)
            var o = 0
            tmp.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in y0 ... y1 {
                        for k in cds.indices {
                            if modp(y, cds[k].ys) != 0 { continue }
                            let n = cds[k].nx * cds[k].size
                            let e = cds[k].end
                            for i in 0 ..< n {
                                let v = t[e + i]
                                dst[o] = UInt8(truncatingIfNeeded: v)
                                dst[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                                o += 2
                            }
                            cds[k].end += n
                        }
                    }
                }
            }
            return out
        }

        private let pizBitmapSize = 65536 >> 3

        /// The table from compacted values back to the 16-bit values present in the block; returns
        /// the largest compacted value.
        private func reverseLut(_ bitmap: [UInt8], _ lut: inout [UInt16]) -> UInt16 {
            var k = 0
            lut.withUnsafeMutableBufferPointer { l in
                bitmap.withUnsafeBufferPointer { b in
                    for byte in 0 ..< b.count {
                        // Value 0 is always present; other bytes only when they have bits set.
                        let bits = byte == 0 ? b[0] | 1 : b[byte]
                        if bits == 0 { continue }
                        for bit in 0 ..< 8 where bits & (1 << bit) != 0 {
                            l[k] = UInt16(byte << 3 | bit)
                            k += 1
                        }
                    }
                    if k < l.count { UnsafeMutableBufferPointer(rebasing: l[k...]).update(repeating: 0) }
                }
            }
            return UInt16(clamping: max(0, k - 1))
        }

        /// The 2D Haar-like wavelet decoding of OpenEXR's PIZ, in place over `nx`×`ny` values at
        /// strides `ox` / `oy`; 14-bit arithmetic when every value is below 2^14.
        private func wav2Decode(_ p: UnsafeMutablePointer<UInt16>, _ nx: Int, _ ox: Int, _ ny: Int, _ oy: Int, _ mx: UInt16) {
            let w14 = mx < (1 << 14)
            let n = min(nx, ny)
            var lv = 1
            while lv <= n { lv <<= 1 }
            lv >>= 1
            var lv2 = lv
            lv >>= 1
            @inline(__always) func dec(_ l: UInt16, _ h: UInt16) -> (UInt16, UInt16) {
                if w14 {
                    let ls = Int(Int16(bitPattern: l)), hs = Int(Int16(bitPattern: h))
                    let ai = ls + (hs & 1) + (hs >> 1)
                    return (UInt16(truncatingIfNeeded: ai), UInt16(truncatingIfNeeded: ai - hs))
                }
                let m = Int(l), d = Int(h)
                let bb = (m - (d >> 1)) & 0xFFFF
                let aa = (d + bb - 0x8000) & 0xFFFF
                return (UInt16(aa), UInt16(bb))
            }
            while lv >= 1 {
                var py = 0
                let ey = oy * (ny - lv2)
                let oy1 = oy * lv, oy2 = oy * lv2, ox1 = ox * lv, ox2 = ox * lv2
                while py <= ey {
                    var px = py
                    let ex = py + ox * (nx - lv2)
                    while px <= ex {
                        let p01 = px + ox1, p10 = px + oy1, p11 = p10 + ox1
                        let (i00, i10) = dec(p[px], p[p10])
                        let (i01, i11) = dec(p[p01], p[p11])
                        (p[px], p[p01]) = dec(i00, i01)
                        (p[p10], p[p11]) = dec(i10, i11)
                        px += ox2
                    }
                    // Odd column.
                    if nx & lv != 0 {
                        let p10 = px + oy1
                        let (i00, v) = dec(p[px], p[p10])
                        p[p10] = v
                        p[px] = i00
                    }
                    py += oy2
                }
                // Odd line.
                if ny & lv != 0 {
                    var px = py
                    let ex = py + ox * (nx - lv2)
                    while px <= ex {
                        let p01 = px + ox1
                        let (i00, v) = dec(p[px], p[p01])
                        p[p01] = v
                        p[px] = i00
                        px += ox2
                    }
                }
                lv2 = lv
                lv >>= 1
            }
        }

        // MARK: PXR24

        private func pxr24(_ packed: ArraySlice<UInt8>, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ expected: Int) throws -> [UInt8] {
            var tmpSize = 0
            for c in channels {
                let bytes = c.type == .float ? 3 : c.type.bytes
                tmpSize += numSamples(c.ySampling, y0, y1) * numSamples(c.xSampling, x0, x1) * bytes
            }
            let tmp: [UInt8]
            do { tmp = try Deflate.zlibInflate(Array(packed), limit: tmpSize) } catch { throw malformed("pxr24 block: \(OpenRaster.errorText(error))") }
            guard tmp.count == tmpSize else { throw malformed("pxr24 block decompressed to \(tmp.count) bytes, expected \(tmpSize)") }
            var out = [UInt8](repeating: 0, count: expected)
            var at = 0, o = 0
            tmp.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in y0 ... y1 {
                        for c in channels {
                            if modp(y, c.ySampling) != 0 { continue }
                            let n = numSamples(c.xSampling, x0, x1)
                            switch c.type {
                            case .uint:
                                var pixel: UInt32 = 0
                                for j in 0 ..< n {
                                    let diff = UInt32(t[at + j]) << 24 | UInt32(t[at + n + j]) << 16 | UInt32(t[at + 2 * n + j]) << 8 | UInt32(t[at + 3 * n + j])
                                    pixel &+= diff
                                    for b in 0 ..< 4 { dst[o + b] = UInt8(truncatingIfNeeded: pixel >> (8 * b)) }
                                    o += 4
                                }
                                at += 4 * n
                            case .half:
                                var pixel: UInt32 = 0
                                for j in 0 ..< n {
                                    let diff = UInt32(t[at + j]) << 8 | UInt32(t[at + n + j])
                                    pixel &+= diff
                                    dst[o] = UInt8(truncatingIfNeeded: pixel)
                                    dst[o + 1] = UInt8(truncatingIfNeeded: pixel >> 8)
                                    o += 2
                                }
                                at += 2 * n
                            case .float:
                                var pixel: UInt32 = 0
                                for j in 0 ..< n {
                                    let diff = UInt32(t[at + j]) << 24 | UInt32(t[at + n + j]) << 16 | UInt32(t[at + 2 * n + j]) << 8
                                    pixel &+= diff
                                    for b in 0 ..< 4 { dst[o + b] = UInt8(truncatingIfNeeded: pixel >> (8 * b)) }
                                    o += 4
                                }
                                at += 3 * n
                            }
                        }
                    }
                }
            }
            return out
        }

        // MARK: B44 / B44A

        private func b44(_ packed: ArraySlice<UInt8>, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ expected: Int) throws -> [UInt8] {
            if channels.contains(where: { $0.type == .half && $0.perceptuallyLinear }) {
                throw codecUnsupported("not supported: B44 with perceptually linear channels")
            }
            var cds: [ChannelData] = []
            var total = 0
            for c in channels {
                let nx = numSamples(c.xSampling, x0, x1), ny = numSamples(c.ySampling, y0, y1)
                let size = c.type.bytes / 2
                cds.append(ChannelData(start: total, end: total, nx: nx, ny: ny, ys: c.ySampling, size: size))
                total += nx * ny * size
            }
            guard total * 2 == expected else { throw malformed("b44 block layout mismatch") }
            var tmp = [UInt16](repeating: 0, count: total)
            var i = packed.startIndex
            let end = packed.endIndex
            for (k, c) in channels.enumerated() {
                let cd = cds[k]
                if c.type != .half {
                    // UINT and FLOAT channels are stored as they are.
                    let n = cd.nx * cd.ny * cd.size
                    guard end - i >= 2 * n else { throw malformed("b44 block too short") }
                    for j in 0 ..< n { tmp[cd.start + j] = UInt16(packed[i + 2 * j]) | UInt16(packed[i + 2 * j + 1]) << 8 }
                    i += 2 * n
                    continue
                }
                var s = [UInt16](repeating: 0, count: 16)
                var y = 0
                while y < cd.ny {
                    var x = 0
                    while x < cd.nx {
                        guard end - i >= 3 else { throw malformed("b44 block too short") }
                        if packed[i + 2] >= 13 << 2 {
                            b44Unpack3(packed, i, &s)
                            i += 3
                        } else {
                            guard end - i >= 14 else { throw malformed("b44 block too short") }
                            b44Unpack14(packed, i, &s)
                            i += 14
                        }
                        let n = x + 3 < cd.nx ? 4 : cd.nx - x
                        for row in 0 ..< 4 where y + row < cd.ny {
                            let at = cd.start + (y + row) * cd.nx + x
                            for col in 0 ..< n { tmp[at + col] = s[row * 4 + col] }
                        }
                        x += 4
                    }
                    y += 4
                }
            }
            var out = [UInt8](repeating: 0, count: expected)
            var o = 0
            for y in y0 ... y1 {
                for k in cds.indices {
                    if modp(y, cds[k].ys) != 0 { continue }
                    let n = cds[k].nx * cds[k].size
                    for j in 0 ..< n {
                        let v = tmp[cds[k].end + j]
                        out[o] = UInt8(truncatingIfNeeded: v)
                        out[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                        o += 2
                    }
                    cds[k].end += n
                }
            }
            return out
        }

        /// A 4×4 block of 14 bytes: the first value, a shift and fifteen 6-bit differences.
        private func b44Unpack14(_ p: ArraySlice<UInt8>, _ at: Int, _ s: inout [UInt16]) {
            func b(_ k: Int) -> Int { Int(p[at + k]) }
            var v = [Int](repeating: 0, count: 16)
            v[0] = b(0) << 8 | b(1)
            let shift = b(2) >> 2
            let bias = 0x20 << shift
            v[4] = v[0] + ((((b(2) << 4) | (b(3) >> 4)) & 0x3F) << shift) - bias
            v[8] = v[4] + ((((b(3) << 2) | (b(4) >> 6)) & 0x3F) << shift) - bias
            v[12] = v[8] + ((b(4) & 0x3F) << shift) - bias
            v[1] = v[0] + ((b(5) >> 2) << shift) - bias
            v[5] = v[4] + ((((b(5) << 4) | (b(6) >> 4)) & 0x3F) << shift) - bias
            v[9] = v[8] + ((((b(6) << 2) | (b(7) >> 6)) & 0x3F) << shift) - bias
            v[13] = v[12] + ((b(7) & 0x3F) << shift) - bias
            v[2] = v[1] + ((b(8) >> 2) << shift) - bias
            v[6] = v[5] + ((((b(8) << 4) | (b(9) >> 4)) & 0x3F) << shift) - bias
            v[10] = v[9] + ((((b(9) << 2) | (b(10) >> 6)) & 0x3F) << shift) - bias
            v[14] = v[13] + ((b(10) & 0x3F) << shift) - bias
            v[3] = v[2] + ((b(11) >> 2) << shift) - bias
            v[7] = v[6] + ((((b(11) << 4) | (b(12) >> 4)) & 0x3F) << shift) - bias
            v[11] = v[10] + ((((b(12) << 2) | (b(13) >> 6)) & 0x3F) << shift) - bias
            v[15] = v[14] + ((b(13) & 0x3F) << shift) - bias
            for k in 0 ..< 16 {
                // The values are 16-bit (unsigned short) in the reference: wrap like it.
                v[k] &= 0xFFFF
                let t = UInt16(v[k])
                s[k] = t & 0x8000 != 0 ? t & 0x7FFF : ~t
            }
        }

        /// A flat 4×4 block of 3 bytes (B44A): one value everywhere.
        private func b44Unpack3(_ p: ArraySlice<UInt8>, _ at: Int, _ s: inout [UInt16]) {
            var t = UInt16(p[at]) << 8 | UInt16(p[at + 1])
            t = t & 0x8000 != 0 ? t & 0x7FFF : ~t
            for k in 0 ..< 16 { s[k] = t }
        }
    }

    // MARK: - PIZ Huffman decoding

    /// OpenEXR's PIZ Huffman decoder (16-bit symbols plus a run-length code, canonical codes,
    /// a 14-bit primary decoding table with chained long codes).
    final class Huffman {
        static let encSize = (1 << 16) + 1
        static let decBits = 14
        static let decSize = 1 << 14
        static let decMask = decSize - 1
        static let shortZeroRun = 59
        static let longZeroRun = 63
        static let shortestLongRun = 2 + longZeroRun - shortZeroRun
        static let longestLongRun = 255 + shortestLongRun

        private var hcode = [UInt64](repeating: 0, count: encSize)
        private var lens = [UInt8](repeating: 0, count: decSize)
        private var lits = [Int32](repeating: 0, count: decSize)
        private var longs = [[Int32]](repeating: [], count: decSize)
        private var touchedLongs: [Int] = []

        static func huffmanError(_ what: String) -> PCIOError { malformed("piz huffman data: \(what)") }

        /// Decodes `c` into exactly `out.count` 16-bit values.
        func uncompress(_ c: UnsafeBufferPointer<UInt8>, _ out: UnsafeMutableBufferPointer<UInt16>) throws {
            if c.isEmpty {
                if !out.isEmpty { throw Huffman.huffmanError("not enough data") }
                return
            }
            guard c.count >= 20 else { throw Huffman.huffmanError("not enough data") }
            func u32(_ o: Int) -> Int { Int(c[o]) | Int(c[o + 1]) << 8 | Int(c[o + 2]) << 16 | Int(c[o + 3]) << 24 }
            let im = u32(0), iM = u32(4), nBits = u32(12)
            guard im < Huffman.encSize, iM < Huffman.encSize, im <= iM else { throw Huffman.huffmanError("invalid table size") }
            var ptr = 20
            guard (nBits + 7) / 8 <= c.count - ptr else { throw Huffman.huffmanError("not enough data") }
            hcode.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            try unpackEncTable(c, &ptr, c.count - ptr, im, iM)
            guard nBits <= 8 * (c.count - ptr) else { throw Huffman.huffmanError("invalid bit count") }
            try buildDecTable(im, iM)
            defer { resetDecTable() }
            try decode(c, ptr, nBits, iM, out)
        }

        /// Code lengths (6 bits each, with zero runs), then canonical codes.
        private func unpackEncTable(_ c: UnsafeBufferPointer<UInt8>, _ ptr: inout Int, _ ni: Int, _ imIn: Int, _ iM: Int) throws {
            let start = ptr
            var bits: UInt64 = 0, lc = 0
            func getBits(_ n: Int) throws -> UInt64 {
                while lc < n {
                    guard ptr < c.count else { throw Huffman.huffmanError("not enough data") }
                    bits = bits << 8 | UInt64(c[ptr])
                    ptr += 1
                    lc += 8
                }
                lc -= n
                return (bits >> UInt64(lc)) & ((1 << UInt64(n)) - 1)
            }
            var im = imIn
            while im <= iM {
                guard ptr - start < ni else { throw Huffman.huffmanError("not enough data") }
                let l = try getBits(6)
                hcode[im] = l
                if l == UInt64(Huffman.longZeroRun) {
                    guard ptr - start <= ni else { throw Huffman.huffmanError("not enough data") }
                    let run = Int(try getBits(8)) + Huffman.shortestLongRun
                    guard im + run <= iM + 1 else { throw Huffman.huffmanError("code table overrun") }
                    for _ in 0 ..< run { hcode[im] = 0; im += 1 }
                    continue
                } else if l >= UInt64(Huffman.shortZeroRun) {
                    let run = Int(l) - Huffman.shortZeroRun + 2
                    guard im + run <= iM + 1 else { throw Huffman.huffmanError("code table overrun") }
                    for _ in 0 ..< run { hcode[im] = 0; im += 1 }
                    continue
                }
                im += 1
            }
            canonicalCodeTable(imIn, iM)
        }

        /// Assigns canonical codes to the code lengths in `hcode` (length in the low 6 bits, code
        /// above). Only symbols in [im, iM] can have a length (the reference walks the whole
        /// table; the codes are the same).
        private func canonicalCodeTable(_ im: Int, _ iM: Int) {
            var n = [UInt64](repeating: 0, count: 59)
            hcode.withUnsafeMutableBufferPointer { h in
                for i in im ... iM where h[i] < 59 { n[Int(h[i])] += 1 }
                var code: UInt64 = 0
                for i in stride(from: 58, to: 0, by: -1) {
                    let nc = (code + n[i]) >> 1
                    n[i] = code
                    code = nc
                }
                for i in im ... iM {
                    let l = h[i]
                    if l > 0 && l < 59 {
                        h[i] = l | n[Int(l)] << 6
                        n[Int(l)] += 1
                    }
                }
            }
        }

        private func buildDecTable(_ im: Int, _ iM: Int) throws {
            try hcode.withUnsafeBufferPointer { h in
                try lens.withUnsafeMutableBufferPointer { lens in
                    try lits.withUnsafeMutableBufferPointer { lits in
                        for i in im ... iM {
                            let code = h[i] >> 6
                            let l = Int(h[i] & 63)
                            if l > 0 && code >> UInt64(l) != 0 { throw Huffman.huffmanError("invalid code table entry") }
                            if l > Huffman.decBits {
                                let idx = Int(code >> UInt64(l - Huffman.decBits))
                                guard idx < Huffman.decSize, lens[idx] == 0 else { throw Huffman.huffmanError("invalid code table entry") }
                                if longs[idx].isEmpty { touchedLongs.append(idx) }
                                longs[idx].append(Int32(i))
                            } else if l > 0 {
                                let base = Int(code << UInt64(Huffman.decBits - l))
                                for k in 0 ..< 1 << (Huffman.decBits - l) {
                                    let idx = base + k
                                    guard idx < Huffman.decSize, lens[idx] == 0, longs[idx].isEmpty else {
                                        throw Huffman.huffmanError("invalid code table entry")
                                    }
                                    lens[idx] = UInt8(l)
                                    lits[idx] = Int32(i)
                                }
                            }
                        }
                    }
                }
            }
        }

        private func resetDecTable() {
            lens.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            for i in touchedLongs { longs[i] = [] }
            touchedLongs.removeAll(keepingCapacity: true)
        }

        private func decode(_ c: UnsafeBufferPointer<UInt8>, _ start: Int, _ nBits: Int, _ rlc: Int, _ out: UnsafeMutableBufferPointer<UInt16>) throws {
            try hcode.withUnsafeBufferPointer { hcode in
                try lens.withUnsafeBufferPointer { lens in
                    try lits.withUnsafeBufferPointer { lits in
                        try decode(c, start, nBits, rlc, out, hcode, lens, lits)
                    }
                }
            }
        }

        private func decode(_ c: UnsafeBufferPointer<UInt8>, _ start: Int, _ nBits: Int, _ rlc: Int, _ out: UnsafeMutableBufferPointer<UInt16>,
                            _ hcode: UnsafeBufferPointer<UInt64>, _ lens: UnsafeBufferPointer<UInt8>, _ lits: UnsafeBufferPointer<Int32>) throws {
            var bits: UInt64 = 0, lc = 0
            var inPos = start
            let ie = start + (nBits + 7) / 8
            let no = out.count
            var o = 0
            func getCode(_ po: Int) throws {
                if po == rlc {
                    if lc < 8 {
                        guard inPos < c.count else { throw Huffman.huffmanError("not enough data") }
                        bits = bits << 8 | UInt64(c[inPos])
                        inPos += 1
                        lc += 8
                    }
                    lc -= 8
                    let cs = Int((bits >> UInt64(lc)) & 0xFF)
                    guard o + cs <= no, o >= 1 else { throw Huffman.huffmanError("run overflows the block") }
                    let s = out[o - 1]
                    for _ in 0 ..< cs { out[o] = s; o += 1 }
                } else if o < no {
                    out[o] = UInt16(truncatingIfNeeded: po)
                    o += 1
                } else {
                    throw Huffman.huffmanError("too much data")
                }
            }
            while inPos < ie {
                bits = bits << 8 | UInt64(c[inPos])
                inPos += 1
                lc += 8
                while lc >= Huffman.decBits {
                    let idx = Int((bits >> UInt64(lc - Huffman.decBits)) & UInt64(Huffman.decMask))
                    let len = Int(lens[idx])
                    if len != 0 {
                        lc -= len
                        try getCode(Int(lits[idx]))
                    } else {
                        let list = longs[idx]
                        guard !list.isEmpty else { throw Huffman.huffmanError("invalid code") }
                        var found = false
                        for sym in list {
                            let l = Int(hcode[Int(sym)] & 63)
                            while lc < l && inPos < ie {
                                bits = bits << 8 | UInt64(c[inPos])
                                inPos += 1
                                lc += 8
                            }
                            if lc >= l && hcode[Int(sym)] >> 6 == (bits >> UInt64(lc - l)) & ((1 << UInt64(l)) - 1) {
                                lc -= l
                                try getCode(Int(sym))
                                found = true
                                break
                            }
                        }
                        if !found { throw Huffman.huffmanError("invalid code") }
                    }
                }
            }
            // The remaining (short) codes.
            let pad = (8 - nBits) & 7
            bits >>= UInt64(pad)
            lc -= pad
            while lc > 0 {
                let idx = Int((bits << UInt64(Huffman.decBits - lc)) & UInt64(Huffman.decMask))
                let len = Int(lens[idx])
                guard len != 0 else { throw Huffman.huffmanError("invalid code") }
                lc -= len
                guard lc >= 0 else { throw Huffman.huffmanError("invalid code") }
                try getCode(Int(lits[idx]))
            }
            guard o == no else { throw Huffman.huffmanError("not enough data") }
        }
    }
}
