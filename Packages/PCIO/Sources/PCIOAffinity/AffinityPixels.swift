// Port of photocraft-io (crates/io/src/affinity.rs: `Builder::pixels`, `image`, `mask`, `resample`;
// the straight-RGBA8 conversion of photocraft-codecs `Image::to_rgba8`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// Pixel layers, placed images (embedded smart objects) and pixel masks: decoded, then resampled onto
// the canvas by their transform.

import CoreGraphics
import Foundation
import ImageIO
import PCAffinity
import PCDocument
import PCFoundation
import PCIOCore

extension AffinityBuilder {
    /// Straight RGBA8 pixels of an image (decoding an embedded file), with its size.
    func pixels(_ img: Affinity.Image) -> (width: UInt32, height: UInt32, rgba: [UInt8])? {
        switch img.pixels {
        case .rgba8(let v):
            return (img.width, img.height, v)
        case .encoded(let bytes):
            guard let d = decodeEmbedded(bytes) else {
                warn("an embedded image that could not be decoded was left out")
                return nil
            }
            return d
        }
    }

    /// An embedded file decoded by the injected codec within photocraft's limits (65 535 px a side,
    /// 64 megapixels). The header's size is checked before any pixel is decoded.
    func decodeEmbedded(_ bytes: [UInt8]) -> (width: UInt32, height: UInt32, rgba: [UInt8])? {
        func fits(_ w: Int, _ h: Int) -> Bool {
            w > 0 && h > 0 && w <= AffinityImport.maxEmbeddedSide && h <= AffinityImport.maxEmbeddedSide
                && UInt64(w) * UInt64(h) <= AffinityImport.maxPixels
        }
        if let (w, h) = Self.headerSize(bytes), !fits(w, h) { return nil }
        guard let img = try? codec.decode(bytes), fits(img.width, img.height) else { return nil }
        return (UInt32(img.width), UInt32(img.height), Self.rgba8(img.surface, img.width, img.height))
    }

    /// The pixel size an image file declares, without decoding it (nil when ImageIO can't tell).
    static func headerSize(_ bytes: [UInt8]) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    /// A decoded image as straight RGBA8, converted as photocraft-codecs' `to_rgba8` does (grey
    /// replicated, naive CMYK, rounded to nearest), a band of rows at a time.
    static func rgba8(_ s: Surface, _ w: Int, _ h: Int) -> [UInt8] {
        let fmt = s.format
        let ch = fmt.channels
        var out = [UInt8](repeating: 0, count: w * h * 4)
        func q(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8((min(max(v, 0), 1) * 255).rounded()) }
        let band = max(1, (1 << 18) / max(w, 1))
        var y = 0
        while y < h {
            let n = min(band, h - y)
            let r = PixelRect(x0: 0, y0: Int32(y), x1: Int32(w), y1: Int32(y + n))
            let v = s.readRegion(r)
            for i in 0..<(w * n) {
                let p = i * ch
                let a: Float = fmt.alpha ? v[p + ch - 1] : 1
                let rgb: SIMD3<Float>
                switch fmt.mode {
                case .grayscale, .bitmap, .duotone:
                    rgb = SIMD3(repeating: v[p])
                case .cmyk:
                    let k = 1 - v[p + 3]
                    rgb = SIMD3((1 - v[p]) * k, (1 - v[p + 1]) * k, (1 - v[p + 2]) * k)
                case .lab:
                    rgb = ColorConvert.labToSRGB(SIMD3(v[p] * 100, v[p + 1] * 255 - 128, v[p + 2] * 255 - 128))
                case .rgb, .indexed, .multichannel:
                    rgb = SIMD3(v[p], v[p + 1], v[p + 2])
                }
                let o = (y * w + i) * 4
                out[o] = q(rgb.x)
                out[o + 1] = q(rgb.y)
                out[o + 2] = q(rgb.z)
                out[o + 3] = q(a)
            }
            y += n
        }
        return out
    }

    func image(_ img: Affinity.Image, _ toDoc: PCAffine) -> LayerContent? {
        guard let (w, h, rgba) = pixels(img) else { return nil }
        // The pixel grid maps onto the Affinity image's own size, whatever the stored file's.
        let m = toDoc.mul(Self.affine(img.transform))
            .mul(PCAffine(a: Double(img.width) / Double(max(w, 1)), b: 0, c: 0, d: Double(img.height) / Double(max(h, 1)), e: 0, f: 0))
        guard let surface = resample(w, h, rgba, m, channels: 4) else { return nil }
        switch img.pixels {
        case .encoded(let bytes):
            // A placed image keeps its file, as a smart object placed by the same transform.
            return .smart(SmartObject(source: .embedded(fileName: "Affinity image", bytes: bytes), transform: m, cache: surface))
        case .rgba8:
            return .raster(surface)
        }
    }

    func mask(_ img: Affinity.Image, _ toDoc: PCAffine) -> Surface? {
        guard let (w, h, rgba) = pixels(img) else { return nil }
        let grey = stride(from: 0, to: rgba.count - rgba.count % 4, by: 4).map { rgba[$0] }
        let m = toDoc.mul(Self.affine(img.transform))
        return resample(w, h, grey, m, channels: 1)
    }

    /// Bilinear resampling of `src` (`w`×`h`, `channels` 4 = straight RGBA8 or 1 = grey) mapped by
    /// `m` (source pixels to canvas pixels) into a surface; exact copy when `m` is an integer
    /// translation. Pixels outside the source are transparent (grey: 0, hidden).
    func resample(_ w: UInt32, _ h: UInt32, _ src: [UInt8], _ m: PCAffine, channels: Int) -> Surface? {
        let fmt: PixelFormat = channels == 1 ? .gray8 : format
        var out = channels == 1 ? Surface(format: fmt, defaultPixel: [0]) : Surface(format: fmt)
        let r = bbox(m, Affinity.Rect(x0: 0, y0: 0, x1: Double(w), y1: Double(h)))
        if r.width == 0 || r.height == 0 {
            return out
        }
        if UInt64(r.width) * UInt64(r.height) > AffinityImport.maxPixels {
            warn("images larger than 64 megapixels on the canvas were left out")
            return nil
        }
        let exact = m.a == 1 && m.d == 1 && m.b == 0 && m.c == 0 && Self.fract(m.e) == 0 && Self.fract(m.f) == 0
        guard let inv = m.inverse else { return nil }
        let (rw, rh) = (r.width, r.height)
        let (sw, sh) = (Int64(w), Int64(h))
        var buf = [UInt8](repeating: 0, count: rw * rh * channels)
        src.withUnsafeBufferPointer { s in
            buf.withUnsafeMutableBufferPointer { o in
                @inline(__always) func at(_ x: Int64, _ y: Int64, _ ch: Int) -> Double {
                    if x < 0 || y < 0 || x >= sw || y >= sh { return 0 }
                    let i = (Int(y) * Int(sw) + Int(x)) * channels + ch
                    return i < s.count ? Double(s[i]) : 0
                }
                for row in 0..<rh {
                    for col in 0..<rw {
                        let px = (row * rw + col) * channels
                        let p = inv.apply(PCPoint(Double(r.x0) + Double(col) + 0.5, Double(r.y0) + Double(row) + 0.5))
                        if exact {
                            let x: Int64 = satCast(p.x.rounded(.down)), y: Int64 = satCast(p.y.rounded(.down))
                            for ch in 0..<channels {
                                o[px + ch] = UInt8(at(x, y, ch))
                            }
                            continue
                        }
                        let (fx, fy) = (p.x - 0.5, p.y - 0.5)
                        let x0: Int64 = satCast(fx.rounded(.down)), y0: Int64 = satCast(fy.rounded(.down))
                        let (tx, ty) = (fx - Double(x0), fy - Double(y0))
                        let (x1, y1) = (x0 &+ 1, y0 &+ 1)
                        let (w00, w10, w01, w11) = ((1 - tx) * (1 - ty), tx * (1 - ty), (1 - tx) * ty, tx * ty)
                        if channels == 1 {
                            let v = at(x0, y0, 0) * w00 + at(x1, y0, 0) * w10 + at(x0, y1, 0) * w01 + at(x1, y1, 0) * w11
                            o[px] = Self.byte(v)
                        } else {
                            // Interpolate premultiplied colour so transparent pixels don't bleed.
                            let (a00, a10, a01, a11) = (at(x0, y0, 3), at(x1, y0, 3), at(x0, y1, 3), at(x1, y1, 3))
                            let alpha = a00 * w00 + a10 * w10 + a01 * w01 + a11 * w11
                            for ch in 0..<3 {
                                let pm = at(x0, y0, ch) * a00 / 255 * w00 + at(x1, y0, ch) * a10 / 255 * w10
                                    + at(x0, y1, ch) * a01 / 255 * w01 + at(x1, y1, ch) * a11 / 255 * w11
                                o[px + ch] = alpha > 0 ? Self.byte(pm * 255 / alpha) : 0
                            }
                            o[px + 3] = Self.byte(alpha)
                        }
                    }
                }
            }
        }
        out.writeInterleaved(r, buf)
        out.prune()
        return out
    }

    /// Rust's `v.round().clamp(0.0, 255.0) as u8` (NaN becomes 0).
    @inline(__always) static func byte(_ v: Double) -> UInt8 {
        satCast(rclamp(v.rounded(.toNearestOrAwayFromZero), 0, 255))
    }

    /// Rust's `f64::fract`.
    @inline(__always) static func fract(_ v: Double) -> Double {
        v - v.rounded(.towardZero)
    }
}
