// Port of photocraft-raster helpers the engine leans on (`to_rgba`/`from_rgba_into`, `fill_rect`, `sample_channel`, `with_default`, `try_convert`, `shift_surface`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Per-pixel colour conversion between a surface's stored model and straight RGBA, and small
// surface utilities PCFoundation's `Surface` doesn't have.

import Foundation
import PCDocument
import PCFoundation

/// photocraft `to_rgba` / `from_rgba`: one pixel between a format's channels and straight RGBA
/// (sRGB-encoded; CMYK through the managed converter, Lab through D50).
public enum PixelCodec {
    /// Straight RGBA of one pixel's normalised channels.
    @inline(__always)
    public static func toRGBA(_ f: PixelFormat, _ px: UnsafeBufferPointer<Float>, _ o: Int) -> SIMD4<Float> {
        let ch = f.channels
        let a: Float = f.alpha ? px[o + ch - 1] : 1
        switch f.mode {
        case .rgb, .indexed, .multichannel: return SIMD4(px[o], px[o + 1], px[o + 2], a)
        case .grayscale, .bitmap, .duotone: return SIMD4(px[o], px[o], px[o], a)
        case .cmyk: return SIMD4(ColorConvert.cmykToRGB(SIMD4(px[o], px[o + 1], px[o + 2], px[o + 3])), a)
        case .lab: return SIMD4(ColorConvert.labToSRGB(SIMD3(px[o] * 100, px[o + 1] * 255 - 128, px[o + 2] * 255 - 128)), a)
        }
    }

    public static func toRGBA(_ f: PixelFormat, _ px: [Float]) -> SIMD4<Float> {
        px.withUnsafeBufferPointer { toRGBA(f, $0, 0) }
    }

    /// The channels of `rgba` in `f` (photocraft `from_rgba_into`).
    public static func fromRGBA(_ f: PixelFormat, _ rgba: SIMD4<Float>) -> [Float] { f.components(fromRGBA: rgba) }

    /// Straight RGBA of every pixel of `raw` (interleaved `f` channels), CMYK in one batch.
    public static func toRGBA(_ f: PixelFormat, raw: [Float]) -> [SIMD4<Float>] {
        let ch = f.channels, n = raw.count / max(ch, 1)
        if f.mode == .cmyk {
            let cmyk = (0..<n).map { i in SIMD4(raw[i * ch], raw[i * ch + 1], raw[i * ch + 2], raw[i * ch + 3]) }
            let rgb = ColorConvert.cmykToRGB(batch: cmyk)
            return (0..<n).map { i in SIMD4(rgb[i], f.alpha ? raw[i * ch + ch - 1] : 1) }
        }
        return raw.withUnsafeBufferPointer { p in (0..<n).map { toRGBA(f, p, $0 * ch) } }
    }

    /// Interleaved `f` channels of straight RGBA pixels, CMYK in one batch.
    public static func fromRGBA(_ f: PixelFormat, rgba: [SIMD4<Float>]) -> [Float] {
        let ch = f.channels
        var out = [Float](repeating: 0, count: rgba.count * ch)
        if f.mode == .cmyk {
            let cmyk = ColorConvert.rgbToCMYK(batch: rgba.map { SIMD3($0.x, $0.y, $0.z) })
            for i in rgba.indices {
                let c = cmyk[i]
                out[i * ch] = c.x; out[i * ch + 1] = c.y; out[i * ch + 2] = c.z; out[i * ch + 3] = c.w
                if f.alpha { out[i * ch + 4] = rgba[i].w }
            }
            return out
        }
        for i in rgba.indices {
            let c = f.components(fromRGBA: rgba[i])
            for k in 0..<ch { out[i * ch + k] = c[k] }
        }
        return out
    }
}

extension Surface {
    /// A surface whose missing tiles read as `pixel` (photocraft `with_default`).
    public static func withDefault(_ format: PixelFormat, _ pixel: [Float]) -> Surface { Surface(format: format, defaultPixel: pixel) }

    /// Channel `c` at a pixel (photocraft `sample_channel`).
    public func sampleChannel(x: Int32, y: Int32, _ c: Int) -> Float {
        let p = pixel(x: x, y: y)
        return c < p.count ? p[c] : 0
    }

    /// Channel 0 over `r`, row-major (a selection's or mask's coverage).
    public func coverage(_ r: PixelRect) -> [Float] {
        let raw = readRegion(r)
        let ch = channels
        if ch == 1 { return raw }
        return stride(from: 0, to: raw.count, by: ch).map { raw[$0] }
    }

    /// The same pixels in another format: depth, alpha and colour model. photocraft `try_convert`:
    /// within one model PCFoundation's `converted(to:)` copies the channels (an added alpha is
    /// opaque); across models through RGBA (CMYK in one managed batch).
    public func convertedAny(to target: PixelFormat) -> Surface {
        if target == format { return self }
        if target.mode == format.mode { return converted(to: target) }
        let defRGBA = PixelCodec.toRGBA(format, defaultPixelValue)
        var out = Surface(format: target, defaultPixel: PixelCodec.fromRGBA(target, defRGBA))
        forEachTile { c, _ in
            let r = c.rect
            let rgba = PixelCodec.toRGBA(format, raw: readRegion(r))
            out.writeRegion(r, PixelCodec.fromRGBA(target, rgba: rgba))
        }
        return out
    }

    /// The pixels moved by (dx, dy), default pixel kept (photocraft `shift_surface`).
    public func shifted(dx: Int32, dy: Int32) -> Surface {
        if dx == 0 && dy == 0 { return self }
        // Pixels shifted past the 32-bit coordinate space are dropped (never wrapped or trapped).
        let lo = Int64(Int32.min), hi = Int64(Int32.max)
        func inRange(_ v: Int64, _ d: Int32) -> Int32 { Int32(clamping: min(max(v, lo - Int64(d)), hi - Int64(d))) }
        // Whole-tile moves keep the tiles (and their sharing with history).
        if dx % tileSize == 0 && dy % tileSize == 0 {
            var out = Surface.withDefault(format, defaultPixelValue)
            var moved: [(TileCoord, Tile)] = []
            let (tdx, tdy) = (Int64(dx / tileSize), Int64(dy / tileSize))
            let ts = Int64(tileSize)
            let tmin = -((-lo + ts - 1) / ts), tmax = hi / ts
            forEachTile { c, t in
                let (tx, ty) = (Int64(c.tx) + tdx, Int64(c.ty) + tdy)
                if tx >= tmin && tx <= tmax && ty >= tmin && ty <= tmax { moved.append((TileCoord(tx: Int32(tx), ty: Int32(ty)), t)) }
            }
            out.putTiles(moved)
            return out
        }
        var out = Surface.withDefault(format, defaultPixelValue)
        let t = tileBounds
        if t.isEmpty { return out }
        let b = PixelRect(x0: inRange(Int64(t.x0), dx), y0: inRange(Int64(t.y0), dy), x1: inRange(Int64(t.x1), dx), y1: inRange(Int64(t.y1), dy))
        if !b.isEmpty { out.writeInterleaved(b.offsetBy(dx: dx, dy: dy), readInterleaved(b)) }
        out.prune()
        return out
    }

    /// Whether every pixel is the default (no content).
    public var isBlank: Bool { contentBounds.isEmpty }
}

extension PixelFormat {
    /// The same layout at another sample type.
    public func withSample(_ s: SampleType) -> PixelFormat { with(sample: s) }
}
