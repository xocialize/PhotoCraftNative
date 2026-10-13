// Port of photocraft-codecs (crates/codecs/src/web.rs `lzw_encode`, `encode_gif_indexed`, `encode_gif_animated`, `encode_wbmp`, `decode_wbmp`; crates/codecs/src/codecs/png.rs `encode_indexed`), as used by photocraft-engine's web_cmds.rs and video_cmds.rs, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Web-optimised writers for Save for Web and Render Video: indexed GIF89a (our own LZW encoder,
// GIF89a spec), animated GIF, WBMP (WAP Wireless Bitmap, type 0) and indexed PNG with an exact
// palette. PCPlatform's ImageIO-backed codecs quantise GIFs themselves and write neither WBMP nor
// palette PNGs, so these writers live here; PCIOCore supplies zlib and CRC-32.

import Foundation
import PCIOCore

extension WebCommands {
    enum Codec {
        struct Failure: Error, CustomStringConvertible {
            var description: String
        }

        /// Packs variable-length LZW codes LSB-first.
        struct BitSink {
            var bytes: [UInt8] = []
            var acc: UInt32 = 0
            var nbits: UInt32 = 0

            mutating func put(_ code: UInt16, _ size: UInt32) {
                acc |= UInt32(code) << nbits
                nbits += size
                while nbits >= 8 {
                    bytes.append(UInt8(truncatingIfNeeded: acc))
                    acc >>= 8
                    nbits -= 8
                }
            }

            mutating func finish() -> [UInt8] {
                if nbits > 0 { bytes.append(UInt8(truncatingIfNeeded: acc)) }
                return bytes
            }
        }

        /// GIF variable-code-length LZW compression of `indices` (each < 2^`minCodeSize`).
        static func lzwEncode(_ indices: [UInt8], minCodeSize: UInt8) -> [UInt8] {
            let minBits = UInt32(min(max(minCodeSize, 2), 8))
            let clear = UInt16(1) << minBits
            let eoi = clear + 1
            var size = minBits + 1
            var next = eoi + 1
            var dict: [UInt32: UInt16] = [:]
            dict.reserveCapacity(4096)
            var out = BitSink()
            out.bytes.reserveCapacity(indices.count / 2 + 16)
            out.put(clear, size)
            guard let first = indices.first else {
                out.put(eoi, size)
                return out.finish()
            }
            var prefix = UInt16(first)
            for k in indices.dropFirst() {
                let key = UInt32(prefix) << 8 | UInt32(k)
                if let c = dict[key] {
                    prefix = c
                    continue
                }
                out.put(prefix, size)
                // The decoder adds its entries one code late, so widen once the next free code no
                // longer fits (before assigning it), like the classic compress-based encoders.
                if UInt32(next) >= 1 << size && size < 12 { size += 1 }
                if next < 4096 {
                    dict[key] = next
                    next += 1
                } else {
                    out.put(clear, size)
                    dict.removeAll(keepingCapacity: true)
                    size = minBits + 1
                    next = eoi + 1
                }
                prefix = UInt16(k)
            }
            out.put(prefix, size)
            if UInt32(next) >= 1 << size && size < 12 { size += 1 }
            out.put(eoi, size)
            return out.finish()
        }

        /// Rows in GIF interlaced order (every 8th from 0, every 8th from 4, every 4th from 2,
        /// every 2nd from 1).
        static func interlacedRows(_ h: Int) -> [Int] {
            var v: [Int] = []
            v.reserveCapacity(h)
            for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] where start < h {
                v.append(contentsOf: stride(from: start, to: h, by: step))
            }
            return v
        }

        static func le16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }

        /// Colour table bits: 2^bits entries ≥ the palette, bits ≥ 1.
        static func tableBits(_ n: Int) -> UInt8 { (1...8).first { (1 << $0) >= n }.map(UInt8.init) ?? 8 }

        static func subBlocks(_ data: [UInt8], into out: inout [UInt8]) {
            var i = 0
            while i < data.count {
                let n = min(255, data.count - i)
                out.append(UInt8(n))
                out.append(contentsOf: data[i..<i + n])
                i += n
            }
            out.append(0)
        }

        /// An indexed GIF89a: `palette` (1…256 entries), one index per pixel, optional
        /// transparent index (Graphic Control Extension) and interlacing.
        static func encodeGifIndexed(_ width: Int, _ height: Int, _ indices: [UInt8], _ palette: [SIMD3<UInt8>], transparent: UInt8?,
                                     interlaced: Bool) throws(Failure) -> [UInt8] {
            let (w, h) = (width, height)
            if w <= 0 || h <= 0 || w > 65535 || h > 65535 || indices.count != w * h {
                throw Failure(description: "GIF size must be 1..=65535 and match the index data")
            }
            if palette.isEmpty || palette.count > 256 || indices.contains(where: { Int($0) >= palette.count }) {
                throw Failure(description: "palette must have 1..=256 entries covering every index")
            }
            let bits = tableBits(palette.count)
            var out = Array("GIF89a".utf8)
            out += le16(w) + le16(h)
            out.append(0x80 | ((bits - 1) << 4) | (bits - 1))
            out.append(transparent ?? 0)
            out.append(0)
            for i in 0..<(1 << Int(bits)) {
                let c = i < palette.count ? palette[i] : .zero
                out += [c.x, c.y, c.z]
            }
            if let t = transparent { out += [0x21, 0xF9, 0x04, 0x01, 0, 0, t, 0] }
            out.append(0x2C)
            out += [0, 0, 0, 0]
            out += le16(w) + le16(h)
            out.append(interlaced ? 0x40 : 0)
            let minCode = max(bits, 2)
            out.append(minCode)
            let data: [UInt8]
            if interlaced {
                var v: [UInt8] = []
                v.reserveCapacity(indices.count)
                for y in interlacedRows(h) { v.append(contentsOf: indices[y * w..<(y + 1) * w]) }
                data = lzwEncode(v, minCodeSize: minCode)
            } else {
                data = lzwEncode(indices, minCodeSize: minCode)
            }
            subBlocks(data, into: &out)
            out.append(0x3B)
            return out
        }

        /// One frame of an animated GIF: palette indices, its (local) palette, an optional
        /// transparent index and the delay in centiseconds.
        struct GifFrame: Sendable {
            var indices: [UInt8]
            var palette: [SIMD3<UInt8>]
            var transparent: UInt8?
            var delayCs: UInt16
        }

        /// An animated GIF89a: each frame carries its own local colour table; `loopForever` adds
        /// the NETSCAPE2.0 looping extension.
        static func encodeGifAnimated(_ width: Int, _ height: Int, _ frames: [GifFrame], loopForever: Bool) throws(Failure) -> [UInt8] {
            let (w, h) = (width, height)
            if w <= 0 || h <= 0 || w > 65535 || h > 65535 { throw Failure(description: "GIF size must be 1..=65535") }
            if frames.isEmpty { throw Failure(description: "an animated GIF needs at least one frame") }
            var out = Array("GIF89a".utf8)
            out += le16(w) + le16(h)
            out.append(0x70) // no global colour table, 8-bit colour resolution
            out.append(0) // background colour index
            out.append(0) // pixel aspect ratio
            if loopForever {
                out += [0x21, 0xFF, 0x0B]
                out += Array("NETSCAPE2.0".utf8)
                out += [0x03, 0x01, 0x00, 0x00, 0x00] // loop count 0 = forever
            }
            for f in frames {
                if f.palette.isEmpty || f.palette.count > 256 || f.indices.count != w * h || f.indices.contains(where: { Int($0) >= f.palette.count }) {
                    throw Failure(description: "every frame's palette must have 1..=256 entries covering its indices")
                }
                let bits = tableBits(f.palette.count)
                // Graphic Control Extension: delay and optional transparency. Every frame covers
                // the whole image, so an opaque one is left in place (disposal 1), while one with a
                // transparent index is cleared afterwards (disposal 2).
                out += [0x21, 0xF9, 0x04, f.transparent != nil ? 0x09 : 0x04]
                out += le16(Int(f.delayCs))
                out.append(f.transparent ?? 0)
                out.append(0)
                // Image Descriptor with a Local Colour Table.
                out.append(0x2C)
                out += [0, 0, 0, 0]
                out += le16(w) + le16(h)
                out.append(0x80 | (bits - 1))
                for i in 0..<(1 << Int(bits)) {
                    let c = i < f.palette.count ? f.palette[i] : .zero
                    out += [c.x, c.y, c.z]
                }
                let minCode = max(bits, 2)
                out.append(minCode)
                subBlocks(lzwEncode(f.indices, minCodeSize: minCode), into: &out)
            }
            out.append(0x3B)
            return out
        }

        static func putMultibyte(_ out: inout [UInt8], _ v: Int) {
            var groups = [UInt8(v & 0x7f)]
            var v = v >> 7
            while v > 0 {
                groups.append(UInt8(v & 0x7f) | 0x80)
                v >>= 7
            }
            out.append(contentsOf: groups.reversed())
        }

        /// WBMP type 0 (1 bit per pixel, rows padded to bytes, 1 = white). `white[i]` per pixel.
        static func encodeWbmp(_ width: Int, _ height: Int, _ white: [Bool]) throws(Failure) -> [UInt8] {
            let (w, h) = (width, height)
            if w <= 0 || h <= 0 || white.count != w * h { throw Failure(description: "WBMP size must match the pixel data") }
            var out: [UInt8] = [0, 0]
            putMultibyte(&out, w)
            putMultibyte(&out, h)
            let stride = (w + 7) / 8
            for y in 0..<h {
                var row = [UInt8](repeating: 0, count: stride)
                for x in 0..<w where white[y * w + x] { row[x / 8] |= 0x80 >> UInt8(x % 8) }
                out.append(contentsOf: row)
            }
            return out
        }

        /// Reads a WBMP type 0 image: (width, height, white per pixel).
        static func decodeWbmp(_ bytes: [UInt8]) throws(Failure) -> (Int, Int, [Bool]) {
            let bad = Failure(description: "not a type 0 WBMP")
            var i = 0
            func next() throws(Failure) -> UInt8 {
                guard i < bytes.count else { throw bad }
                defer { i += 1 }
                return bytes[i]
            }
            if try next() != 0 { throw bad }
            if try next() & 0x9f != 0 { throw bad }
            func mb() throws(Failure) -> Int {
                var v = 0
                for _ in 0..<5 {
                    let b = try next()
                    let (m, o) = v.multipliedReportingOverflow(by: 128)
                    if o || m > Int(UInt32.max) { throw bad }
                    v = m | Int(b & 0x7f)
                    if b & 0x80 == 0 { return v }
                }
                throw bad
            }
            let (w, h) = (try mb(), try mb())
            if w == 0 || h == 0 || w * h > 1 << 28 { throw bad }
            let stride = (w + 7) / 8
            guard i + stride * h <= bytes.count else { throw bad }
            var px: [Bool] = []
            px.reserveCapacity(w * h)
            for y in 0..<h {
                for x in 0..<w { px.append(bytes[i + y * stride + x / 8] & (0x80 >> UInt8(x % 8)) != 0) }
            }
            return (w, h, px)
        }

        static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }

        static func chunk(_ out: inout [UInt8], _ type: String, _ data: [UInt8]) {
            let t = Array(type.utf8)
            out += be32(UInt32(data.count))
            out += t
            out += data
            out += be32(CRC32.checksum(t + data))
        }

        /// An 8-bit indexed PNG: `palette` (1…256 entries), one index per pixel, the transparent
        /// entry (if any) marked in `tRNS`, the resolution in `pHYs` (photocraft
        /// `encode_png_indexed`).
        static func encodePngIndexed(_ width: Int, _ height: Int, _ indices: [UInt8], _ palette: [SIMD3<UInt8>], transparent: UInt8?,
                                     dpi: (Float, Float)? = nil) throws(Failure) -> [UInt8] {
            if width <= 0 || height <= 0 || indices.count != width * height { throw Failure(description: "index data does not match the size") }
            if palette.isEmpty || palette.count > 256 || indices.contains(where: { Int($0) >= palette.count }) {
                throw Failure(description: "palette must have 1..=256 entries covering every index")
            }
            var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            chunk(&out, "IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [8, 3, 0, 0, 0])
            chunk(&out, "PLTE", palette.flatMap { [$0.x, $0.y, $0.z] })
            if let t = transparent, Int(t) < palette.count {
                var trns = [UInt8](repeating: 255, count: Int(t) + 1)
                trns[Int(t)] = 0
                chunk(&out, "tRNS", trns)
            }
            if let d = dpi, d.0.isFinite, d.1.isFinite, d.0 > 0, d.1 > 0 {
                func ppm(_ v: Float) -> UInt32 { UInt32(min((v / 0.0254).rounded(), Float(UInt32.max >> 1))) }
                chunk(&out, "pHYs", be32(ppm(d.0)) + be32(ppm(d.1)) + [1])
            }
            var raw: [UInt8] = []
            raw.reserveCapacity((width + 1) * height)
            for y in 0..<height {
                raw.append(0)
                raw.append(contentsOf: indices[y * width..<(y + 1) * width])
            }
            let z: [UInt8]
            do { z = try Deflate.zlibDeflate(raw) } catch { throw Failure(description: "PNG: \(error)") }
            chunk(&out, "IDAT", z)
            chunk(&out, "IEND", [])
            return out
        }
    }
}
