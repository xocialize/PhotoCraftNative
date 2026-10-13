// Port of photocraft-algo (crates/algo/src/lens.rs: remap; photo_util.rs: catmull_rom), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The shared machinery of the Geometry area: photocraft's `remap` (an inverse map resampled per
// 128-px output tile, the tile's source window spanning its samples and clamped to the frame,
// premultiplied Catmull-Rom in f32, edge modes, lateral CA, vignette gain in the document's
// model) on the CPU, and the same as two Metal kernels for Lens Correction's map.

import Foundation
import Metal
import PCFoundation

enum GeometryKit {
    /// Output tile edge of photocraft's `remap`.
    static let tile: Int32 = 128

    /// Rust `f64::clamp` (NaN stays NaN).
    @inline(__always)
    static func clampR(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : (v > hi ? hi : v) }

    /// photocraft `photo_util::catmull_rom` (f32).
    @inline(__always)
    static func catmullRom(_ t: Float) -> SIMD4<Float> {
        let t2 = t * t, t3 = t2 * t
        return SIMD4(-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1.0, -1.5 * t3 + 2.0 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
    }

    /// `r` of `s` as floats (the default pixel where nothing is stored), alpha 1 appended when asked.
    static func read(_ s: Surface, _ r: PixelRect, addAlpha: Bool) -> FloatImage {
        let n = s.channels
        let raw = s.readRegion(r)
        if !addAlpha { return FloatImage(rect: r, channels: n, data: raw) }
        var out = [Float](repeating: 1, count: r.area * (n + 1))
        for i in 0..<r.area { for c in 0..<n { out[i * (n + 1) + c] = raw[i * n + c] } }
        return FloatImage(rect: r, channels: n + 1, data: out)
    }

    /// `img` with an alpha channel of 1 appended.
    static func appendAlpha(_ img: FloatImage) -> FloatImage {
        let n = img.channels
        var out = [Float](repeating: 1, count: img.rect.area * (n + 1))
        for i in 0..<img.rect.area { for c in 0..<n { out[i * (n + 1) + c] = img.data[i * n + c] } }
        return FloatImage(rect: img.rect, channels: n + 1, data: out)
    }

    /// Copies interleaved `data` covering `r` into `img` (inside its rectangle).
    static func paste(_ img: inout FloatImage, _ r: PixelRect, _ data: [Float]) {
        let inner = r.intersect(img.rect)
        if inner.isEmpty { return }
        let n = img.channels
        for y in inner.y0..<inner.y1 {
            let si = (Int(y - r.y0) * r.width + Int(inner.x0 - r.x0)) * n
            let di = img.index(x: inner.x0, y: y)
            for i in 0..<(inner.width * n) { img.data[di + i] = data[si + i] }
        }
    }

    /// Whether a source and output fit one GPU pass.
    static func fits(_ src: PixelRect, _ out: PixelRect) -> Bool {
        let m = FilterEngine.maxGPUSize
        return max(src.width, src.height, out.width, out.height) <= m && out.area <= 1 << 26
    }

    /// The engine backend for a dense call: `.auto` picks the CPU when the job is too large.
    static func backend(_ b: Backend, fits: Bool) -> Backend {
        b == .auto && !fits ? .cpu : b
    }

    /// Everything `remap` needs besides the map and the pixels.
    struct RemapSpec: Sendable, Codable, Equatable {
        var frame: PixelRect
        /// Channels per pixel, in and out (with `outAlpha` and not `srcAlpha`, the input's last
        /// channel is ignored: the source has no alpha and the output gains one).
        var n: Int
        /// Colour channels.
        var cc: Int
        var srcAlpha: Bool
        var outAlpha: Bool
        /// 0 other, 1 RGB (lateral CA on red and blue), 2 subtractive (CMYK), 3 Lab (gain on L).
        var mode: Int32
        /// Integer storage: colour clipped to 0…1 before the edge-colour blend.
        var clip: Bool
        var edge: LensEdgeMode
        /// The edge colour in the output's model and layout (zeros unless `.color`).
        var edgePx: [Float]
        /// Tile grid origin and the rectangle tiles are clipped to.
        var tileOrigin: SIMD2<Int32>
        var tileClip: PixelRect

        init(ctx: FilterContext, channels n: Int, srcAlpha: Bool, edge: LensEdgeMode, clip: Bool, frame: PixelRect,
             tileOrigin: SIMD2<Int32>, tileClip: PixelRect) {
            self.frame = frame; self.n = n; self.srcAlpha = srcAlpha; self.outAlpha = ctx.alpha; self.edge = edge; self.clip = clip
            self.tileOrigin = tileOrigin; self.tileClip = tileClip
            cc = ctx.colorChannels(n)
            if (ctx.mode == .rgb || ctx.mode == .indexed) && cc == 3 { mode = 1 } else if ctx.mode == .cmyk { mode = 2 } else if ctx.mode == .lab { mode = 3 } else { mode = 0 }
            if case .color(let c) = edge { edgePx = ctx.native(c, channels: n) } else { edgePx = [Float](repeating: 0, count: n) }
        }
    }

    /// The tiles of the grid that meet `out` (clipped to `spec.tileClip`).
    static func tiles(_ spec: RemapSpec, out: PixelRect) -> [PixelRect] {
        let o = spec.tileOrigin, t = tile
        if out.isEmpty { return [] }
        let cx0 = ResampleKit.floorDiv(out.x0 - o.x, t), cx1 = ResampleKit.floorDiv(out.x1 - 1 - o.x, t)
        let cy0 = ResampleKit.floorDiv(out.y0 - o.y, t), cy1 = ResampleKit.floorDiv(out.y1 - 1 - o.y, t)
        var res: [PixelRect] = []
        for cy in cy0...cy1 {
            for cx in cx0...cx1 {
                let r = PixelRect(x0: o.x + cx * t, y0: o.y + cy * t, x1: o.x + (cx + 1) * t, y1: o.y + (cy + 1) * t).intersect(spec.tileClip)
                if !r.isEmpty && !r.intersect(out).isEmpty { res.append(r) }
            }
        }
        return res
    }

    /// photocraft `remap_impl` on the CPU: per tile (in parallel) the samples, the window, then the
    /// pixels of the tile inside `out`. `read` returns the source over a rectangle (`spec.n`
    /// channels, interleaved). Returns each tile's part of `out` with its pixels.
    static func remapTiles(_ spec: RemapSpec, out: PixelRect, map: (Double, Double) -> LensSample?,
                           read: (PixelRect) -> [Float]) -> [(PixelRect, [Float])] {
        let ts = tiles(spec, out: out)
        var results = [(PixelRect, [Float])](repeating: (.empty, []), count: ts.count)
        results.withUnsafeMutableBufferPointer { rb in
            let r = UnsafeSendable(rb)
            parallelFor(ts.count) { k in r.value[k] = remapTile(spec, ts[k], out: out, map: map, read: read) }
        }
        return results
    }

    static func remapTile(_ spec: RemapSpec, _ t: PixelRect, out: PixelRect, map: (Double, Double) -> LensSample?,
                          read: (PixelRect) -> [Float]) -> (PixelRect, [Float]) {
        let frame = spec.frame, n = spec.n, cc = spec.cc
        let tw = t.width, th = t.height
        var samples = [LensSample?](repeating: nil, count: tw * th)
        for i in 0..<(tw * th) { samples[i] = map(Double(t.x0) + Double(i % tw) + 0.5, Double(t.y0) + Double(i / tw) + 0.5) }
        // Source window: bbox of every sample, clamped to the frame.
        var (bx0, by0, bx1, by1) = (Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for case let s? in samples {
            for p in [s.p, s.pr, s.pb] { bx0 = fmin(bx0, p.x); by0 = fmin(by0, p.y); bx1 = fmax(bx1, p.x); by1 = fmax(by1, p.y) }
        }
        let win: PixelRect
        if bx0 > bx1 {
            win = .empty
        } else {
            func cx(_ v: Double) -> Int32 { min(max(ResampleKit.i32(v), frame.x0), frame.x1) }
            func cy(_ v: Double) -> Int32 { min(max(ResampleKit.i32(v), frame.y0), frame.y1) }
            win = PixelRect(x0: cx(bx0.rounded(.down) - 3), y0: cy(by0.rounded(.down) - 3), x1: cx(bx1.rounded(.up) + 4), y1: cy(by1.rounded(.up) + 4))
        }
        let ww = win.width, wh = win.height
        var buf = win.isEmpty ? [] : read(win)
        // Premultiply colour by alpha so transparent pixels don't bleed.
        if spec.srcAlpha { premultiply(&buf, n, true) }
        let (fx0, fy0, fx1, fy1) = (Double(frame.x0), Double(frame.y0), Double(frame.x1), Double(frame.y1))
        let region = t.intersect(out)
        var data = [Float](repeating: 0, count: region.area * n)
        buf.withUnsafeBufferPointer { bp in
            func bicubic(_ c: Int, _ p: SIMD2<Double>) -> Float {
                // Pixel centres at +0.5; clamp to the frame (edge extension).
                let x = clampR(p.x - 0.5, fx0, fx1 - 1), y = clampR(p.y - 0.5, fy0, fy1 - 1)
                let xi = x.rounded(.down), yi = y.rounded(.down)
                let wx = catmullRom(Float(x - xi)), wy = catmullRom(Float(y - yi))
                var acc: Float = 0
                for j in 0..<4 {
                    let yy = Int(min(max(ResampleKit.i32(yi) &+ Int32(j) &- 1, win.y0), win.y1 - 1) - win.y0)
                    for i in 0..<4 {
                        let xx = Int(min(max(ResampleKit.i32(xi) &+ Int32(i) &- 1, win.x0), win.x1 - 1) - win.x0)
                        acc += wx[i] * wy[j] * bp[(yy * ww + xx) * n + c]
                    }
                }
                return acc
            }
            var col = [Float](repeating: 0, count: max(cc, 1))
            for y in region.y0..<region.y1 {
                for x in region.x0..<region.x1 {
                    let o = (Int(y - region.y0) * region.width + Int(x - region.x0)) * n
                    guard let s = samples[Int(y - t.y0) * tw + Int(x - t.x0)], ww > 0, wh > 0 else {
                        for c in 0..<n { data[o + c] = spec.edgePx[c] }
                        continue
                    }
                    // Inside-frame weight (1 px soft edge) unless edges extend.
                    let inside: Float
                    if spec.edge == .edgeExtension {
                        inside = 1
                    } else {
                        let fx = clampR(fmin(s.p.x - fx0, fx1 - s.p.x) + 0.5, 0, 1)
                        let fy = clampR(fmin(s.p.y - fy0, fy1 - s.p.y) + 0.5, 0, 1)
                        inside = Float(fx * fy)
                    }
                    let alpha: Float = spec.srcAlpha ? min(max(bicubic(n - 1, s.p), 0), 1) : 1
                    for c in 0..<cc {
                        let p = spec.mode == 1 && c == 0 ? s.pr : (spec.mode == 1 && c == 2 ? s.pb : s.p)
                        let pm = bicubic(c, p)
                        let straight = spec.srcAlpha ? (alpha > 1e-6 ? pm / alpha : 0) : pm
                        let g = s.gain
                        var v: Float
                        switch spec.mode {
                        case 2: v = 1 - (1 - straight) * g
                        case 3: v = c == 0 ? straight * g : straight
                        default: v = straight * g
                        }
                        if spec.clip { v = min(max(v, 0), 1) }
                        col[c] = v
                    }
                    let aOut = alpha * inside
                    if case .color = spec.edge, inside < 1 {
                        // Blend towards the edge colour by the outside share.
                        let ea: Float = spec.outAlpha ? spec.edgePx[n - 1] : 1
                        let oa = alpha * inside + ea * (1 - inside)
                        for c in 0..<cc {
                            let mixed = col[c] * alpha * inside + spec.edgePx[c] * ea * (1 - inside)
                            data[o + c] = oa > 1e-6 ? mixed / oa : 0
                        }
                        if spec.outAlpha { data[o + n - 1] = oa }
                    } else {
                        for c in 0..<cc { data[o + c] = col[c] }
                        if spec.outAlpha { data[o + n - 1] = aOut }
                    }
                }
            }
        }
        return (region, data)
    }
}

// MARK: - Lens Correction on the GPU

extension GeometryKit {
    /// MSL `pca_geo_lens_params`.
    struct LensParams: BitwiseCopyable {
        var c: SIMD2<Float>
        var r: Float
        var scale: Float
        var rotS: Float
        var rotC: Float
        var m6: Float
        var m7: Float
        var m8: Float
        var k1: Float
        var k2: Float
        var p1: Float
        var p2: Float
        var caR: Float
        var caB: Float
        var vigAmount: Float
        /// v1, v2, v3, midpoint.
        var vig: SIMD4<Float>
        /// The edge colour in this plane's layout.
        var edgePx: SIMD4<Float>
        var coverOrigin: SIMD2<Int32>
        var coverSize: SIMD2<Int32>
        var cellOrigin: SIMD2<Int32>
        var tilesX: Int32
        var mode: Int32
        var frameLo: SIMD2<Int32>
        var frameHi: SIMD2<Int32>
        var srcAlpha: UInt32
        var outAlpha: UInt32
        var clip: UInt32
        /// 0 extension, 1 transparency, 2 colour.
        var edgeKind: UInt32
    }

    /// Lens Correction (or any `LensMap`) as a filter over the output rectangle: CPU `remapTiles`;
    /// Metal: the map per pixel of the covering tiles (marking each tile's sample bounds), then
    /// the sampling.
    struct LensFilter: Filter {
        var map: LensMap
        var spec: RemapSpec
        var label: String { "Lens Correction" }
        func halo(bounds: PixelRect) -> Halo { .bounds }

        func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
            var res = FloatImage(rect: out, channels: src.channels)
            let m = map
            for (t, d) in GeometryKit.remapTiles(spec, out: out, map: { m.sample($0, $1) }, read: { src.crop($0).data }) {
                GeometryKit.paste(&res, t, d)
            }
            return res
        }

        func encodeGPU(_ pass: GPUPass) throws {
            let out = pass.out
            let o = spec.tileOrigin, t = GeometryKit.tile
            let cx0 = ResampleKit.floorDiv(out.x0 - o.x, t), cx1 = ResampleKit.floorDiv(out.x1 - 1 - o.x, t)
            let cy0 = ResampleKit.floorDiv(out.y0 - o.y, t), cy1 = ResampleKit.floorDiv(out.y1 - 1 - o.y, t)
            let cellOrigin = SIMD2(o.x + cx0 * t, o.y + cy0 * t)
            let cover = PixelRect(x0: cellOrigin.x, y0: cellOrigin.y, x1: o.x + (cx1 + 1) * t, y1: o.y + (cy1 + 1) * t).intersect(spec.tileClip)
            let tilesX = Int(cx1 - cx0) + 1, tilesY = Int(cy1 - cy0) + 1
            var bbox = [Int32](repeating: 0, count: tilesX * tilesY * 4)
            for i in 0..<(tilesX * tilesY) { bbox[i * 4] = .max; bbox[i * 4 + 1] = .max; bbox[i * 4 + 2] = .min; bbox[i * 4 + 3] = .min }
            var edge = SIMD4<Float>(repeating: 0)
            for (k, c) in pass.planeChannels.enumerated() where c < spec.edgePx.count { edge[k] = spec.edgePx[c] }
            if spec.outAlpha { edge[3] = spec.edgePx[spec.n - 1] }
            let edgeKind: UInt32
            switch spec.edge { case .edgeExtension: edgeKind = 0; case .transparency: edgeKind = 1; case .color: edgeKind = 2 }
            let m = map
            let p = LensParams(c: SIMD2(Float(m.c.x), Float(m.c.y)), r: Float(m.r), scale: Float(m.scale), rotS: Float(m.rotS), rotC: Float(m.rotC),
                               m6: Float(m.hinv[6]), m7: Float(m.hinv[7]), m8: Float(m.hinv[8]), k1: Float(m.k1), k2: Float(m.k2),
                               p1: Float(m.p1), p2: Float(m.p2), caR: Float(m.caR), caB: Float(m.caB), vigAmount: Float(m.vigAmount),
                               vig: SIMD4(Float(m.vigProfile.x), Float(m.vigProfile.y), Float(m.vigProfile.z), Float(m.vigMid)), edgePx: edge,
                               coverOrigin: SIMD2(cover.x0, cover.y0), coverSize: SIMD2(Int32(cover.width), Int32(cover.height)),
                               cellOrigin: cellOrigin, tilesX: Int32(tilesX), mode: spec.mode,
                               frameLo: SIMD2(spec.frame.x0, spec.frame.y0), frameHi: SIMD2(spec.frame.x1, spec.frame.y1),
                               srcAlpha: spec.srcAlpha ? 1 : 0, outAlpha: spec.outAlpha ? 1 : 0, clip: spec.clip ? 1 : 0, edgeKind: edgeKind)
            let bb = try pass.buffer(bbox)
            let t1 = try pass.texture(cover), t2 = try pass.texture(cover)
            try pass.dispatch("pca_geo_lens_map", params: p, textures: [t1, t2], buffers: [bb], width: cover.width, height: cover.height)
            try pass.dispatchOut("pca_geo_lens", params: p, textures: [pass.src, t1, t2, pass.dst], buffers: [bb])
        }
    }
}
