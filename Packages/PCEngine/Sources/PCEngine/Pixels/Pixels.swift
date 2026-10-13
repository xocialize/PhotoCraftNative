// Port of photocraft-engine (crates/engine/src/pixels.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Destructive pixel operations on layers: Image › Adjustments through PCRender's adjustment kernels
// (the same `PreparedAdjustment` adjustment layers composite with), fills and clears through the
// selection, pixel remaps (flips, rotations), and merging layers through the compositor.
// Untouched pixels are never re-encoded (a CMYK pixel round-tripped through RGB would drift), and
// work runs tile by tile in parallel.

import Dispatch
import Foundation
import PCDocument
import PCFoundation
import PCRender
import Synchronization

public enum Pixels {
    /// Composite `solo`'s visible layers inside their composite bounds (effects included) into a
    /// surface of `format` (photocraft `composite_layers`).
    public static func compositeLayers(_ solo: Document, format: PixelFormat, background: SIMD3<Float>? = nil,
                                       renderer: EngineRenderer = .shared) throws -> Surface {
        let canvas = solo.bounds
        var area = PixelRect.empty
        for l in solo.layers where l.visible {
            let b = LayerGeometry.compositeBounds(l, canvas: canvas, pixels: { renderer.rasterizer.surfaceFor($0, solo) }) ?? canvas
            if !b.isEmpty { area = area.isEmpty ? b : area.union(b) }
        }
        area = area.intersect(canvas)
        if area.isEmpty { return Surface(format: format) }
        return try renderer.compositeToSurface(solo, rect: area, format: format, background: background)
    }

    /// Runs `body` over the tiles of `r` in parallel and writes each tile's output back.
    static func perTile(_ s: inout Surface, _ r: PixelRect, _ body: @Sendable (PixelRect, [Float]) -> [Float]?) {
        let tiles = r.tiles
        let src = s
        let results = Mutex<[(PixelRect, [Float])]>([])
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            let tr = tiles[i].rect.intersect(r)
            if tr.isEmpty { return }
            if let out = body(tr, src.readRegion(tr)) { results.withLock { $0.append((tr, out)) } }
        }
        for (tr, out) in results.withLock({ $0 }) { s.writeRegion(tr, out) }
    }

    /// Applies `adj` destructively to a surface (any model and depth, via straight RGBA) through
    /// the selection; `mode` is the document's (photocraft `adjust_surface`).
    public static func adjustSurface(_ s: inout Surface, _ adj: Adjustment, selection: Surface?, mode: ColorMode) {
        var r = s.contentBounds
        // Pixels outside the selection keep their tiles (shared with history).
        if let sel = selection { r = r.intersect(sel.contentBounds) }
        if r.isEmpty { return }
        let fmt = s.format
        let prepared = prepare(adj, fmt, mode)
        perTile(&s, r) { tr, raw in
            let out = adjusted(raw, tr, fmt, prepared, selection)
            return out == raw ? nil : out
        }
    }

    /// Applies `adj` to a layer mask through the selection. Without a selection the default pixel
    /// changes too (a mask reaches past the canvas): Invert turns reveal-all into hide-all (#780).
    public static func adjustMask(_ s: inout Surface, _ adj: Adjustment, selection: Surface?) {
        let fmt = s.format
        let prepared = prepare(adj, fmt, .grayscale)
        if let sel = selection {
            let r = sel.contentBounds
            if !r.isEmpty {
                s.writeRegion(r, adjusted(s.readRegion(r), r, fmt, prepared, sel))
                s.prune()
            }
            return
        }
        let unit = PixelRect(x: 0, y: 0, width: 1, height: 1)
        let def = adjusted(s.defaultPixelValue, unit, fmt, prepared, nil)
        var out = Surface.withDefault(fmt, def)
        let r = s.tileBounds
        if !r.isEmpty { out.writeRegion(r, adjusted(s.readRegion(r), r, fmt, prepared, nil)) }
        out.prune()
        s = out
    }

    static func prepare(_ adj: Adjustment, _ fmt: PixelFormat, _ mode: ColorMode) -> PreparedAdjustment {
        // 32-bit documents get the float behaviour of an adjustment layer there (Levels doesn't
        // clip); integer depths keep the unrounded, clipped curves.
        let depth: SampleType? = fmt.sample == .f32 ? .f32 : nil
        return PreparedAdjustment(adj, transfer: Transfer.forDocument(mode: mode, depth: fmt.sample), depth: depth, mode: mode)
    }

    /// `raw` (pixels of `r` in `fmt`) with the adjustment applied through the selection, encoded.
    static func adjusted(_ raw: [Float], _ r: PixelRect, _ fmt: PixelFormat, _ adj: PreparedAdjustment, _ selection: Surface?) -> [Float] {
        let orig = PixelCodec.toRGBA(fmt, raw: raw)
        var buf = RGBABuffer(rect: r, px: orig)
        adj.apply(to: &buf)
        let cov = selection.map { $0.coverage(r) }
        var mixed = buf.px
        if let cov {
            for i in mixed.indices {
                let k = cov[i]
                mixed[i] = orig[i] + (buf.px[i] - orig[i]) * k
            }
        }
        // Pixels the adjustment left alone keep their exact encoding.
        var out = PixelCodec.fromRGBA(fmt, rgba: mixed)
        let ch = fmt.channels
        for i in mixed.indices where mixed[i] == orig[i] {
            for k in 0..<ch { out[i * ch + k] = raw[i * ch + k] }
        }
        return out
    }

    /// Fills `area` with a straight RGBA colour through the selection's coverage (photocraft
    /// `try_fill_surface`); `lockTransparency` keeps alpha.
    public static func fillSurface(_ s: inout Surface, _ area: PixelRect, color: SIMD4<Float>, selection: Surface?, lockTransparency: Bool) {
        let fmt = s.format
        let r = area
        if r.isEmpty { return }
        perTile(&s, r) { tr, raw in
            let cov = selection.map { $0.coverage(tr) }
            var out = raw
            var changed = false
            let ch = fmt.channels
            raw.withUnsafeBufferPointer { p in
                for i in 0..<tr.area {
                    let k = cov?[i] ?? 1
                    if k <= 0 { continue }
                    let d = PixelCodec.toRGBA(fmt, p, i * ch)
                    let sa = color.w * k
                    let oa = sa + d.w * (1 - sa)
                    var o = SIMD4<Float>(0, 0, 0, 0)
                    if oa > 0 {
                        let rgb = (SIMD3(color.x, color.y, color.z) * sa + SIMD3(d.x, d.y, d.z) * d.w * (1 - sa)) / oa
                        o = SIMD4(rgb, 0)
                    }
                    o.w = lockTransparency ? d.w : oa
                    let enc = fmt.components(fromRGBA: o)
                    for c in 0..<ch { out[i * ch + c] = enc[c] }
                    changed = true
                }
            }
            return changed ? out : nil
        }
    }

    /// Clears pixels (makes them transparent) within the selection (photocraft `try_clear_surface`).
    public static func clearSurface(_ s: inout Surface, _ area: PixelRect, selection: Surface?) {
        let fmt = s.format
        guard fmt.alpha, !area.isEmpty else { return }
        let ch = fmt.channels
        perTile(&s, area) { tr, raw in
            let cov = selection.map { $0.coverage(tr) }
            var out = raw
            var changed = false
            for i in 0..<tr.area {
                let k = cov?[i] ?? 1
                if k <= 0 { continue }
                let a = raw[i * ch + ch - 1] * (1 - k)
                if a <= 0 {
                    for c in 0..<ch { out[i * ch + c] = 0 }
                } else {
                    out[i * ch + ch - 1] = a
                }
                changed = true
            }
            return changed ? out : nil
        }
        s.prune()
    }

    /// Remaps a surface through a pixel-coordinate permutation (flips, right-angle rotations):
    /// the content rectangle's image is computed from its corners (photocraft `remap_surface`).
    public static func remapSurface(_ s: Surface, _ map: (Int32, Int32) -> (Int32, Int32)) -> Surface {
        var out = Surface.withDefault(s.format, s.defaultPixelValue)
        let r = s.contentBounds
        if r.isEmpty { return out }
        let corners = [map(r.x0, r.y0), map(r.x1 - 1, r.y0), map(r.x0, r.y1 - 1), map(r.x1 - 1, r.y1 - 1)]
        let dst = PixelRect(x0: corners.map(\.0).min()!, y0: corners.map(\.1).min()!, x1: corners.map(\.0).max()! + 1, y1: corners.map(\.1).max()! + 1)
        guard dst.area == r.area else {
            // Not a permutation of the rectangle: fall back to pixel writes.
            let n = s.channels, raw = s.readRegion(r), w = r.width
            for i in 0..<r.area {
                let (x, y) = (r.x0 + Int32(i % w), r.y0 + Int32(i / w))
                let (nx, ny) = map(x, y)
                out.setPixel(x: nx, y: ny, Array(raw[(i * n)..<(i * n + n)]))
            }
            out.prune()
            return out
        }
        let bpp = s.format.bytesPerPixel
        let src = s.readInterleaved(r)
        var bytes = [UInt8](repeating: 0, count: dst.area * bpp)
        let w = r.width, dw = dst.width
        src.withUnsafeBytes { sp in
            bytes.withUnsafeMutableBytes { dp in
                for i in 0..<r.area {
                    let (x, y) = (r.x0 + Int32(i % w), r.y0 + Int32(i / w))
                    let (nx, ny) = map(x, y)
                    let o = (Int(ny - dst.y0) * dw + Int(nx - dst.x0)) * bpp
                    dp.baseAddress!.advanced(by: o).copyMemory(from: sp.baseAddress!.advanced(by: i * bpp), byteCount: bpp)
                }
            }
        }
        out.writeInterleaved(dst, bytes)
        out.prune()
        return out
    }

    /// Merge `upper` onto `lower`, producing a pixel layer that keeps `lower`'s id, name, blend
    /// mode and locks (Layer › Merge Down).
    public static func mergeDown(_ doc: Document, lower: Layer, upper: Layer, renderer: EngineRenderer = .shared) throws -> Layer {
        let format = doc.pixelFormat
        var tmp = Document(name: "merge", size: doc.size, mode: format.mode, depth: format.sample)
        tmp.iccProfile = doc.iccProfile
        tmp.layers = [lower, upper]
        let s = try compositeLayers(tmp, format: format, renderer: renderer)
        var merged = Layer(name: lower.name, content: .raster(s))
        merged.id = lower.id
        merged.blend = lower.blend
        merged.opacity = 1
        merged.locks = lower.locks
        return merged
    }

    /// `color` (straight RGBA) converted to a format's channels.
    public static func encoded(_ fmt: PixelFormat, _ color: SIMD4<Float>) -> [Float] { fmt.components(fromRGBA: color) }
}

extension PlatformRasterizer {
    /// A layer's pixels for bounds computations: stored, else rendered (type, shapes).
    func surfaceFor(_ l: Layer, _ doc: Document) -> Surface? {
        if let s = l.surface { return s }
        switch l.content {
        case .text, .shape, .smart: return rasterize(l, in: doc)
        default: return nil
        }
    }
}
