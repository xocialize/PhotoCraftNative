// Shared test support for the OpenRaster, Krita, Paint.NET and multi-part EXR tests: a lossless
// stand-in flat image codec, a stand-in compositor, and fixture writers.
// Port support for photocraft-io's tests (crates/io/src/{ora,pdn}/tests.rs, kra.rs), MIT OR
// Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import PCDocument
import PCFoundation
import PCIOCore
import Synchronization
@testable import PCIOFormats

enum ContainerTestKit {
    /// A lossless stand-in for the PNG codec: a PNG signature and IHDR (so the containers see a
    /// PNG of the right size), then the surface's raw samples. ImageIO's decoder premultiplies,
    /// which loses straight-alpha 8-bit values, so exact round trips use this one.
    struct RawCodec: FlatImageCodec {
        static let magic: [UInt8] = Array("RAW!".utf8)

        func decode(_ data: [UInt8]) throws -> DecodedImage {
            guard data.count >= 40, OpenRaster.isPNG(data), Array(data[33 ..< 37]) == RawCodec.magic else {
                throw PCIOError.codec("not a raw test image")
            }
            func be32(_ o: Int) -> Int { Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3]) }
            let w = be32(16), h = be32(20)
            guard let mode = ColorMode(rawValue: data[37]), let sample = SampleType(rawValue: data[38]) else {
                throw PCIOError.codec("bad raw format")
            }
            let alpha = data[39] != 0
            let fmt = PixelFormat(mode: mode, sample: sample, alpha: alpha)
            let rect = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
            guard data.count == 40 + rect.area * fmt.bytesPerPixel else { throw PCIOError.codec("truncated raw image") }
            let src = Surface(format: fmt, rect: rect, interleaved: Array(data[40...]))
            var out: Surface
            if alpha {
                out = src
            } else {
                out = Surface(format: fmt.with(alpha: true))
                let v = src.readRegion(rect)
                let ch = fmt.channels
                var withAlpha = [Float](repeating: 1, count: rect.area * (ch + 1))
                for i in 0 ..< rect.area { for c in 0 ..< ch { withAlpha[i * (ch + 1) + c] = v[i * ch + c] } }
                out.writeRegion(rect, withAlpha)
            }
            out.prune()
            return DecodedImage(surface: out, width: w, height: h, hasAlpha: alpha)
        }

        func encode(_ surface: Surface, rect: PixelRect, as type: FlatImageType, quality: Double?, iccProfile: [UInt8]?) throws -> [UInt8] {
            let fmt = surface.format
            var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
            out += Array("IHDR".utf8)
            for v in [UInt32(rect.width), UInt32(rect.height)] { out += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            out += [UInt8(fmt.sample.bits == 16 ? 16 : 8), fmt.alpha ? 6 : 2, 0, 0, 0, 0, 0, 0, 0]
            out += RawCodec.magic
            out += [fmt.mode.rawValue, fmt.sample.rawValue, fmt.alpha ? 1 : 0]
            out += surface.readInterleaved(rect)
            return out
        }
    }

    /// A stand-in for PCRender (what `StoredPixelsCompositor` does, plus what these tests need):
    /// visible raster-like layers and solid-colour fill layers with Normal blending, layer opacity,
    /// fill opacity, enabled pixel masks, and groups (opacity, and fill opacity unless pass-through).
    struct Compositor: DocumentCompositor {
        func composite(_ document: Document, rect: PixelRect) throws -> [Float] {
            let fmt = document.pixelFormat
            let ch = fmt.channels
            let cc = ch - 1
            var out = [Float](repeating: 0, count: rect.area * ch)
            func visit(_ layers: [Layer], _ opacity: Float) {
                for l in layers where l.visible {
                    if let g = l.group {
                        visit(g.children, opacity * l.opacity * (l.blend == .passThrough ? 1 : l.fillOpacity))
                        continue
                    }
                    var vals: [Float]
                    if case .fill(.solid(let c)) = l.content {
                        let p = fmt.components(fromRGBA: SIMD4(c.rgb, c.alpha))
                        vals = Array([[Float]](repeating: p, count: rect.area).joined())
                    } else if let s = l.surface ?? l.fillCache?.surface, s.format == fmt {
                        vals = s.readRegion(rect)
                    } else {
                        continue
                    }
                    var mask = [Float](repeating: 1, count: rect.area)
                    if let m = l.mask, m.enabled { m.values(rect, into: &mask) }
                    let a0 = opacity * l.opacity * l.fillOpacity
                    for i in 0 ..< rect.area {
                        let sa = vals[i * ch + cc] * a0 * mask[i]
                        if sa <= 0 { continue }
                        let da = out[i * ch + cc]
                        let oa = sa + da * (1 - sa)
                        for c in 0 ..< cc {
                            out[i * ch + c] = oa > 0 ? (vals[i * ch + c] * sa + out[i * ch + c] * da * (1 - sa)) / oa : 0
                        }
                        out[i * ch + cc] = oa
                    }
                }
            }
            visit(document.layers, 1)
            return out
        }
    }

    /// Encoded bytes of one pixel.
    static func px(_ fmt: PixelFormat, _ v: [Float]) -> [UInt8] { encodePixel(fmt, v) }

    /// A raster layer holding a `w`×`h` block at (`x`, `y`) of a colour ramp in `fmt`.
    static func block(_ name: String, _ fmt: PixelFormat, _ x: Int32, _ y: Int32, _ w: Int, _ h: Int, _ seed: Int) -> Layer {
        var data: [UInt8] = []
        for j in 0 ..< h {
            for i in 0 ..< w {
                func v(_ k: Int) -> Float { Float((i * 7 + j * 13 + k * 29 + seed * 31) % 256) / 255 }
                let rgba: [Float] = [v(0), v(1), v(2), 0.25 + 0.75 * v(3)]
                let comps: [Float] = fmt.mode == .grayscale ? [rgba[0], rgba[3]] : rgba
                data += px(fmt, comps)
            }
        }
        let s = Surface(format: fmt, rect: PixelRect(x: Int(x), y: Int(y), width: w, height: h), interleaved: data)
        return Layer(name: name, content: .raster(s))
    }

    /// A ZIP archive with a stored `mimetype` first, then the named entries.
    static func archive(_ mime: [UInt8], _ entries: [(String, [UInt8])]) -> [UInt8] {
        var z = ZipWriter()
        try? z.add("mimetype", mime)
        for (n, d) in entries { try? z.add(n, d) }
        return (try? z.finish()) ?? []
    }

    /// A PNG through ImageIO of `w`×`h` copies of one RGBA8 pixel.
    static func solidPNG(_ w: Int, _ h: Int, _ rgba: [UInt8], codec: any FlatImageCodec = ImageIOCodec()) -> [UInt8] {
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        let s = Surface(format: .rgba8, rect: rect, interleaved: Array([[UInt8]](repeating: rgba, count: w * h).joined()))
        return (try? codec.encode(s, rect: rect, as: .png, quality: nil, iccProfile: nil)) ?? []
    }

    /// A 16-bit gray PNG of a ramp (value i·1000 at pixel i).
    static func gray16PNG(_ w: Int, _ h: Int, codec: any FlatImageCodec = ImageIOCodec()) -> [UInt8] {
        let rect = PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h))
        var bytes: [UInt8] = []
        for i in 0 ..< w * h { let v = UInt16(truncatingIfNeeded: i * 1000); bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let s = Surface(format: .gray16, rect: rect, interleaved: bytes)
        return (try? codec.encode(s, rect: rect, as: .png, quality: nil, iccProfile: nil)) ?? []
    }

    /// The straight RGBA composite of `doc` through the stand-in compositor.
    static func flatten(_ doc: Document) -> [Float] {
        (try? OpenRaster.compositeRGBA(Compositor(), doc, doc.bounds)) ?? []
    }

    /// A thread-safe counter for interrupt closures.
    final class Counter: Sendable {
        let value = Mutex(0)

        /// Increments and returns the value before the increment.
        func next() -> Int { value.withLock { v in defer { v += 1 }; return v } }
        func get() -> Int { value.withLock { $0 } }
        func set(_ n: Int) { value.withLock { $0 = n } }
    }

    /// The error `body` throws, if any.
    static func error<T>(_ body: () throws -> T) -> (any Error)? {
        do {
            _ = try body()
            return nil
        } catch {
            return error
        }
    }

    static func isUnsupported(_ e: (any Error)?) -> Bool {
        if case .unsupported? = e as? PCIOError { return true }
        return false
    }

    /// xorshift32, for deterministic fuzzing.
    struct XorShift {
        var state: UInt32
        mutating func next() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }
    }
}
