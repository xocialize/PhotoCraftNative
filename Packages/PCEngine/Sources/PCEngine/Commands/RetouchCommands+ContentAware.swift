// Port of photocraft-engine (crates/engine/src/retouch_cmds.rs Spot Healing: `dilate`, `proximity_source_patch`, `spot_heal_surface`, `spot_healing`; crates/engine/src/retouch_cmds/content_aware_move.rs; retouch_cmds/patch.rs `patch_content_aware`; crates/engine/src/transform_cmds.rs `warp_gray`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Part of the retouch_cmds port: the tools that synthesise pixels with PCAlgo's inpainting —
// the Spot Healing Brush (content-aware completion, Create Texture, Proximity Match), the
// Content-Aware Move Tool (move / extend, Transform On Drop) and the Patch Tool's Content-Aware
// mode, which lands its content the way the move does (`land`) — plus `Kernels`, the thin
// PCAlgo-backed pixel kernels (Poisson solver, Dodge/Burn/Sponge/Blur/Sharpen) the other
// retouching tools call. The content-aware commands run as background jobs.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCPaint

extension RetouchCommands {
    /// Tonal range targeted by Dodge/Burn.
    typealias ToneRange = PCAlgo.ToneRange

    // MARK: - Kernels (photocraft-algo poisson.rs, retouch.rs)

    /// photocraft-algo's per-pixel retouching kernels and Poisson solvers, from PCAlgo (`Poisson`,
    /// `Retouch`), with the engine's guards: malformed buffers give the input back instead of
    /// trapping.
    enum Kernels {
        /// Rec. 601 luma of a straight RGB triple.
        static func luma(_ c: SIMD3<Float>) -> Float { PCAlgo.Retouch.luma(c) }

        /// The dodge/burn transfer for one value `v` (0…1) with strength `e` (0…1).
        static func toneCurve(_ v: Float, _ e: Float, _ range: ToneRange, _ burn: Bool) -> Float {
            PCAlgo.Retouch.toneCurve(v, e, range, burn: burn)
        }

        /// Dodge (`burn` false) or Burn one straight-RGB colour with strength `e` (0…1).
        static func dodgeBurn(_ c: SIMD3<Float>, _ e: Float, _ range: ToneRange, _ burn: Bool, _ protectTones: Bool) -> SIMD3<Float> {
            PCAlgo.Retouch.dodgeBurn(c, e, range, burn: burn, protectTones: protectTones)
        }

        /// HSV-style saturation (chroma / max) of an RGB triple.
        static func saturation(_ c: SIMD3<Float>) -> Float { PCAlgo.Retouch.saturation(c) }

        /// Sponge: move a colour away from (`saturate`) or toward its luma grey by `amount` (0…1).
        static func sponge(_ c: SIMD3<Float>, _ amount: Float, _ saturate: Bool, _ vibrance: Bool) -> SIMD3<Float> {
            PCAlgo.Retouch.sponge(c, amount, saturate: saturate, vibrance: vibrance)
        }

        static func validWindow(_ data: [Float], _ w: Int, _ h: Int, _ ch: Int, _ win: (Int, Int, Int, Int)) -> Bool {
            let (x0, y0, x1, y1) = win
            return x1 > x0 && y1 > y0 && w > 0 && h > 0 && ch > 0 && data.count >= w * h * ch && x0 >= 0 && y0 >= 0 && x1 <= w && y1 <= h
        }

        /// Gaussian blur of the window `[x0, x1) × [y0, y1)` of an interleaved `w × h × ch` buffer
        /// (edges clamped; colour premultiplied by the `alpha` channel when given). Empty for a
        /// malformed buffer or window.
        static func localBlur(_ data: [Float], _ w: Int, _ h: Int, _ ch: Int, _ alpha: Int?, _ win: (Int, Int, Int, Int), _ sigma: Float) -> [Float] {
            guard validWindow(data, w, h, ch, win) else { return [] }
            return PCAlgo.Retouch.localBlur(data, width: w, height: h, channels: ch, alpha: alpha.flatMap { $0 < ch ? $0 : nil }, window: win,
                                            sigma: sigma)
        }

        /// Unsharp-mask sharpen of a window (as `localBlur`); with `protectDetail` each result is
        /// clamped to its 3×3 neighbourhood's range. Alpha is left unchanged.
        static func localSharpen(_ data: [Float], _ w: Int, _ h: Int, _ ch: Int, _ alpha: Int?, _ win: (Int, Int, Int, Int), _ amount: Float,
                                 _ protectDetail: Bool) -> [Float] {
            guard validWindow(data, w, h, ch, win) else { return [] }
            return PCAlgo.Retouch.localSharpen(data, width: w, height: h, channels: ch, alpha: alpha.flatMap { $0 < ch ? $0 : nil }, window: win,
                                               amount: amount, protectDetail: protectDetail)
        }

        /// Solve `Δv = 0` on `unknown` pixels with Dirichlet values from the known pixels of `v`
        /// (cascadic multigrid + SOR).
        static func solveMembrane(_ w: Int, _ h: Int, _ unknown: [Bool], _ v: inout [Float]) {
            guard w > 0, h > 0, unknown.count == w * h, v.count == w * h else { return }
            Poisson.solveMembrane(width: w, height: h, unknown: unknown, values: &v)
        }

        /// Seamless cloning (guidance field ∇src): `dst` outside `mask`, inside `src` plus the
        /// membrane that removes the boundary mismatch.
        static func seamlessClone(_ w: Int, _ h: Int, _ ch: Int, _ src: [Float], _ dst: [Float], _ mask: [Bool]) -> [Float] {
            guard w > 0, h > 0, ch > 0, src.count == w * h * ch, dst.count == w * h * ch, mask.count == w * h else { return dst }
            return Poisson.seamlessClone(width: w, height: h, channels: ch, source: src, destination: dst, mask: mask)
        }

        /// Membrane fill (no source texture): harmonic interpolation of the known pixels into `hole`.
        static func membraneFill(_ w: Int, _ h: Int, _ ch: Int, _ img: [Float], _ hole: [Bool]) -> [Float] {
            guard w > 0, h > 0, ch > 0, img.count == w * h * ch, hole.count == w * h else { return img }
            return Poisson.membraneFill(width: w, height: h, channels: ch, image: img, hole: hole)
        }
    }

    // MARK: - Spot Healing

    /// Copy a translated Proximity Match patch from the *pre-healing* pixels (reading the output
    /// would make overlapping offsets repeatedly copy the pixels just written). nil for a
    /// malformed buffer or a translation leaving the grid.
    static func proximitySourcePatch(_ img: [Float], _ w: Int, _ h: Int, _ ch: Int, _ mask: [Bool], _ dx: Int32, _ dy: Int32) -> [Float]? {
        if w <= 0 || h <= 0 || ch <= 0 { return nil }
        let (wh, o1) = w.multipliedReportingOverflow(by: h)
        if o1 || mask.count != wh { return nil }
        let (n, o2) = mask.count.multipliedReportingOverflow(by: ch)
        if o2 || img.count != n { return nil }
        var out = img
        for p in 0..<mask.count where mask[p] {
            guard let px = Int32(exactly: p % w), let py = Int32(exactly: p / w), let wi = Int32(exactly: w), let hi = Int32(exactly: h) else { return nil }
            let (x, ox) = px.addingReportingOverflow(dx), (y, oy) = py.addingReportingOverflow(dy)
            if ox || oy || x < 0 || y < 0 || x >= wi || y >= hi { return nil }
            let src = (Int(y) * w + Int(x)) * ch, dst = p * ch
            for c in 0..<ch { out[dst + c] = img[src + c] }
        }
        return out
    }

    enum SpotType: Sendable { case contentAware, createTexture, proximityMatch }

    /// Fill the stroke area with no source, then gradient-domain blend it into its surroundings.
    /// With `all` (Sample All Layers) it heals what is visible, so it works on an empty layer
    /// above the image. A dab changes exactly the brush's footprint; Content-Aware takes its
    /// texture from around it, as Edit › Fill does from its sampling window of the stroke's bounds.
    static func spotHealSurface(_ surf: inout Surface, _ pre: Document, _ stroke: Stroke, _ kind: SpotType, _ all: Bool, _ sel: Surface?,
                                _ lock: Bool, _ renderer: EngineRenderer) throws -> PixelRect {
        let (bounds, cov) = PCPaint.Retouch.strokeCoverage(stroke)
        let size = stroke.brush.size
        let regionRect = FillCommands.samplingWindow(bounds, pre.bounds)
        if regionRect.isEmpty { return .empty }
        // Proximity Match looks for its source anywhere in that window.
        let margin = Int32(clamping: max(regionRect.width, regionRect.height) / 2)
        let fmt = surf.format
        let img = all ? try compositeRegion(renderer, pre, nil, .all, regionRect, fmt) : Region.read(surf, regionRect)
        let (w, h, ch) = (img.width, img.height, img.ch)
        let bw = bounds.width
        var strokeCov = [Float](repeating: 0, count: w * h)
        if bw > 0 {
            for (i, c) in cov.enumerated() {
                let x = bounds.x0 + Int32(i % bw), y = bounds.y0 + Int32(i / bw)
                if regionRect.contains(x: x, y: y) { strokeCov[img.index(x, y)] = c }
            }
        }
        let hole = strokeCov.map { $0 > 0 }
        if !hole.contains(true) { return .empty }
        // Synthesise over a slightly larger domain than the Poisson region, so the solve's
        // boundary pixels carry synthesised values that differ from the untouched surroundings:
        // that mismatch is what the membrane corrects.
        let domain = InpaintKit.dilate(width: w, height: h, mask: hole, radius: 2)
        let healMask = InpaintKit.dilate(width: w, height: h, mask: hole, radius: 1)
        func contentAware(_ data: [Float]) -> [Float] {
            InpaintKit.complete(width: w, height: h, channels: ch, image: data, hole: domain) ?? Kernels.membraneFill(w, h, ch, data, domain)
        }
        let filled: [Float]
        switch kind {
        case .contentAware:
            filled = contentAware(img.data)
        case .createTexture:
            filled = InpaintKit.synthesize(width: w, height: h, channels: ch, image: img.data, hole: domain, block: Int(clampR(size / 4, 6, 32)),
                                           seed: 0x5eed)
        case .proximityMatch:
            let ring = Int(clampR(size / 8, 3, 16))
            if let off = (try? InpaintKit.bestOffset(width: w, height: h, channels: ch, image: img.data, hole: domain, ring: ring, maxRadius: margin)) ?? nil {
                filled = proximitySourcePatch(img.data, w, h, ch, domain, off.0, off.1) ?? contentAware(img.data)
            } else {
                filled = contentAware(img.data)
            }
        }
        let src = Region(rect: regionRect, ch: ch, data: filled)
        let healed = healRegion(fmt, src, img, healMask)
        let dmg = bounds.intersect(regionRect)
        var dmgCov: [Float] = []
        dmgCov.reserveCapacity(dmg.area)
        if !dmg.isEmpty {
            for y in dmg.y0..<dmg.y1 { for x in dmg.x0..<dmg.x1 { dmgCov.append(strokeCov[img.index(x, y)]) } }
        }
        return PCPaint.Retouch.applyCoverage(&surf, rect: dmg, cov: dmgCov, opacity: stroke.brush.opacity, selection: sel, lockTransparency: lock,
                                             paint: healed, blend: .normal)
    }

    static func spotHealing(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.spotHealing"
        let (stroke, id) = try parseBrush(s, p, cmd)
        let kind: SpotType
        switch string(p, "type", "contentAware") {
        case "contentAware": kind = .contentAware
        case "createTexture": kind = .createTexture
        case "proximityMatch": kind = .proximityMatch
        case let o: throw bad(cmd, "unknown type `\(o)` (contentAware|createTexture|proximityMatch)")
        }
        let all = sampleAllLayers(p)
        let renderer = s.services.renderer
        let dmg = try runStroke(s, "Spot Healing Brush", id, p) { pre, surf, sel, lock in
            try spotHealSurface(&surf, pre, stroke, kind, all, sel, lock, renderer)
        }
        return ["damage": .rect(dmg)]
    }

    // MARK: - Content-Aware Move (retouch_cmds/content_aware_move.rs)

    static let camCmd = "paint.contentAwareMove"

    /// Largest selection, in pixels of its bounding box (as the Patch Tool's).
    static let camMaxPixels: UInt64 = 16 << 20

    /// Cap on the sampling margin around the content (the window grows with the selection).
    static let camMaxMargin: Int32 = 512

    /// A pixel target and a selection to move.
    static let contentAwareMoveEnabled: CommandEnabled = { s, p in
        if let why = hasPixelLayer(s, p) { return why }
        guard let d = s.active else { return "no document open" }
        return d.doc.selection != nil ? nil : "select the area to move first"
    }

    /// Optional whole-number param in `lo…hi`; absent or null gives `fallback`.
    static func camLevel(_ p: JSONValue, _ k: String, _ fallback: UInt8, _ lo: UInt8, _ hi: UInt8) throws -> UInt8 {
        guard let v = p[k], v != .null else { return fallback }
        guard let x = v.doubleValue, x.isFinite, x >= Double(lo), x <= Double(hi) else { throw bad(camCmd, "`\(k)` must be a number \(lo)..\(hi)") }
        return UInt8(x.rounded())
    }

    /// The pixels a step reads and writes: a layer (or, with nil, the channel `p` targets), and
    /// whether reading samples the visible composite (Sample All Layers).
    struct CATarget: Sendable {
        var id: LayerId?
        var allLayers: Bool
    }

    enum CAMMode: Sendable {
        /// The content leaves its place, which is filled from the surroundings.
        case move
        /// The content is duplicated; its place stays.
        case extend
    }

    /// What a move does, checked before any work starts.
    struct CAMPlan: Sendable {
        var target: CATarget
        var canvas: PixelRect
        /// The selected area (where the content comes from).
        var area: PixelRect
        var offset: (Int32, Int32)
        /// Transform On Drop: where a source point lands; nil for a plain move by `offset`.
        var map: Homography?
        /// Where the content lands (the moved area, or the transformed one's bounds), on the canvas.
        var dest: PixelRect
        var mode: CAMMode
        var structure: UInt8
        var color: UInt8
    }

    /// Rust `f64::clamp` (NaN stays NaN).
    static func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : (v > hi ? hi : v) }

    /// Rust `f64::rem_euclid`.
    static func remEuclid(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + abs(m) : r
    }

    /// Transform On Drop's `scaleX` / `scaleY` (%) and `rotate` (degrees): the map from a source
    /// point to where it lands, about the centre of `area` and then moved by `offset`. nil when
    /// the params leave the content as it is (a plain move).
    static func camPlacement(_ p: JSONValue, _ area: PixelRect, _ off: (Int32, Int32)) throws -> Homography? {
        func num(_ k: String, _ fallback: Double) throws -> Double {
            guard let v = p[k], v != .null else { return fallback }
            guard let x = v.doubleValue, x.isFinite else { throw bad(camCmd, "`\(k)` must be a finite number") }
            return x
        }
        func scale(_ k: String) throws -> Double {
            let v = try num(k, 100)
            // 1% to 10000% either way (a negative scale flips).
            if abs(v) >= 1 && abs(v) <= 10_000 { return v / 100 }
            throw bad(camCmd, "`\(k)` must be 1..10000 % (or -10000..-1 to flip)")
        }
        let sx = try scale("scaleX"), sy = try scale("scaleY")
        var deg = try num("rotate", 0)
        if abs(deg) > 36_000 { throw bad(camCmd, "`rotate` must be -36000..36000 degrees") }
        deg = remEuclid(deg, 360)
        if sx == 1 && sy == 1 && deg == 0 { return nil }
        let cx = (Double(area.x0) + Double(area.x1)) / 2, cy = (Double(area.y0) + Double(area.y1)) / 2
        func t(_ x: Double, _ y: Double) -> Homography { Homography([1, 0, x, 0, 1, y, 0, 0, 1]) }
        let rad = deg * (Double.pi / 180)
        let (sa, ca) = (sin(rad), cos(rad))
        let rot = Homography([ca, -sa, 0, sa, ca, 0, 0, 0, 1])
        let sc = Homography([sx, 0, 0, 0, sy, 0, 0, 0, 1])
        return t(cx + Double(off.0), cy + Double(off.1)).mul(rot).mul(sc).mul(t(-cx, -cy))
    }

    /// The pixel bounds of `r` mapped by `h` (rounded inwards by a hair so an exact scale doesn't
    /// grow the bounds by a pixel).
    static func mappedBounds(_ h: Homography, _ r: PixelRect) -> PixelRect {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for (cx, cy) in [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)] {
            let (x, y) = h.apply(Double(cx), Double(cy))
            x0 = Double.minimum(x0, x); y0 = Double.minimum(y0, y)
            x1 = Double.maximum(x1, x); y1 = Double.maximum(y1, y)
        }
        if !(x0.isFinite && y0.isFinite && x1.isFinite && y1.isFinite) { return .empty }
        func clamp(_ v: Double) -> Int32 { Int32(clampD(v, -1e8, 1e8)) }
        return PixelRect(x0: clamp((x0 + 1e-6).rounded(.down)), y0: clamp((y0 + 1e-6).rounded(.down)),
                         x1: clamp((x1 - 1e-6).rounded(.up)), y1: clamp((y1 - 1e-6).rounded(.up)))
    }

    /// `src` resampled (bilinear, edges clamped) through `inv` (destination → source) over `rect`:
    /// the content as it lands. Works on float samples, so at any depth.
    static func camResample(_ src: Region, _ inv: Homography, _ rect: PixelRect) -> Region {
        let (sw, sh, n) = (src.rect.width, src.rect.height, src.ch)
        var out = Region(rect: rect, ch: n, data: [Float](repeating: 0, count: rect.area * n))
        if sw == 0 || sh == 0 || n == 0 { return out }
        let data = src.data
        func px(_ x: Int, _ y: Int, _ c: Int) -> Float {
            let i = (y * sw + x) * n + c
            return i < data.count ? data[i] : 0
        }
        let rw = rect.width
        for i in 0..<rect.area {
            let qx = rect.x0 + Int32(i % rw), qy = rect.y0 + Int32(i / rw)
            let (sx, sy) = inv.apply(Double(qx) + 0.5, Double(qy) + 0.5)
            let fx = clampD(sx - 0.5 - Double(src.rect.x0), 0, Double(sw - 1))
            let fy = clampD(sy - 0.5 - Double(src.rect.y0), 0, Double(sh - 1))
            if !(fx.isFinite && fy.isFinite) { continue }
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            let x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1)
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            for c in 0..<n {
                let top = px(x0, y0, c) * (1 - tx) + px(x1, y0, c) * tx
                let bottom = px(x0, y1, c) * (1 - tx) + px(x1, y1, c) * tx
                out.data[i * n + c] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }

    /// The selection's shape as it lands over `rect`: `cov` (coverage over `area`) sampled through
    /// `inv` (destination → source), nearest, set wherever it is above zero.
    static func landedMask(_ cov: [Float], _ area: PixelRect, _ inv: Homography, _ rect: PixelRect) -> [Bool] {
        let w = rect.width
        return (0..<rect.area).map { i in
            let qx = rect.x0 + Int32(i % w), qy = rect.y0 + Int32(i / w)
            let (sx, sy) = inv.apply(Double(qx) + 0.5, Double(qy) + 0.5)
            let x = sx.rounded(.down), y = sy.rounded(.down)
            if !(x >= Double(area.x0) && x < Double(area.x1)) || !(y >= Double(area.y0) && y < Double(area.y1)) { return false }
            let j = Int(Int32(y) - area.y0) * area.width + Int(Int32(x) - area.x0)
            return j < cov.count && cov[j] > 0
        }
    }

    static func camPlan(_ s: Session, _ p: JSONValue) throws -> CAMPlan {
        let mode: CAMMode
        switch string(p, "mode", "move") {
        case "move": mode = .move
        case "extend": mode = .extend
        case let o: throw bad(camCmd, "unknown mode `\(o)` (move|extend)")
        }
        let structure = try camLevel(p, "structure", 4, 1, 7)
        let color = try camLevel(p, "color", 0, 0, 10)
        let (dx, dy) = try patchOffset(camCmd, p)
        let id = try targetLayer(s, p)
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        guard let sel = d.doc.selection else { throw bad(camCmd, "select the area to move first") }
        let area = selectionArea(sel, canvas)
        if area.isEmpty { throw bad(camCmd, "the selection is empty") }
        let pixels = UInt64(area.width) * UInt64(area.height)
        if pixels > camMaxPixels { throw bad(camCmd, "the selection is too large to move (\(pixels) pixels, at most \(camMaxPixels))") }
        let map = try camPlacement(p, area, (dx, dy))
        let dest: PixelRect
        if let h = map {
            let landed = mappedBounds(h, area)
            let pixels = UInt64(landed.width) * UInt64(landed.height)
            if pixels > camMaxPixels {
                throw bad(camCmd, "the transformed selection is too large to move (\(pixels) pixels, at most \(camMaxPixels))")
            }
            dest = landed.intersect(canvas)
            if dest.isEmpty { throw bad(camCmd, "the transformed selection must land on the canvas") }
        } else {
            if dx == 0 && dy == 0 { throw bad(camCmd, "drag the selection to where the content should go") }
            // Content dropped beyond the edge would be lost: keep it on the canvas, as the Patch
            // Tool does.
            dest = area.offsetBy(dx: dx, dy: dy)
            if !canvas.contains(dest) { throw bad(camCmd, "the moved selection must stay inside the canvas") }
        }
        let allLayers = flag(p, "sampleAllLayers", false) && targetsPixels(p)
        return CAMPlan(target: CATarget(id: id, allLayers: allLayers), canvas: canvas, area: area, offset: (dx, dy), map: map, dest: dest,
                       mode: mode, structure: structure, color: color)
    }

    /// Width in pixels of the edge band re-synthesised at the new place, for Structure 1…7 and
    /// content `minSide` pixels across: about a patch wide for 3…7; 2 and 1 widen it (1 so far
    /// that the content itself is re-synthesised).
    static func bandWidth(_ structure: UInt8, _ minSide: UInt32) -> Int {
        let side = Float(minSide)
        let w: Float
        switch structure {
        case 0, 1: w = Float.maximum(side * 0.3, 12)
        case 2: w = Float.maximum(side * 0.18, 9)
        default: w = 6
        }
        return min(Int(w.rounded()), 128)
    }

    /// The cells of a `w × h` mask whose whole `(2r+1)²` neighbourhood, as far as it lies on the
    /// grid, is set (a square erosion through a summed-area table). The grid's border doesn't
    /// erode: a selection reaching the canvas edge keeps its content there.
    static func erode(_ w: Int, _ h: Int, _ m: [Bool], _ r: Int) -> [Bool] {
        if r == 0 { return m }
        let w1 = w + 1
        var sat = [UInt32](repeating: 0, count: w1 * (h + 1))
        for y in 0..<h {
            var row: UInt32 = 0
            for x in 0..<w {
                let i = y * w + x
                row += (i < m.count && m[i]) ? 1 : 0
                sat[(y + 1) * w1 + x + 1] = sat[y * w1 + x + 1] + row
            }
        }
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let (y0, y1) = (max(y - r, 0), min(y + r + 1, h))
            for x in 0..<w {
                let i = y * w + x
                if !(i < m.count && m[i]) { continue }
                let (x0, x1) = (max(x - r, 0), min(x + r + 1, w))
                let set = sat[y1 * w1 + x1] &+ sat[y0 * w1 + x0] &- sat[y0 * w1 + x1] &- sat[y1 * w1 + x0]
                out[i] = Int(set) == (x1 - x0) * (y1 - y0)
            }
        }
        return out
    }

    /// Where a fill samples from around `r`: Photoshop's Content-Aware window, at most
    /// `camMaxMargin` pixels around `r`.
    static func camWindow(_ r: PixelRect, _ canvas: PixelRect) -> PixelRect {
        FillCommands.samplingWindow(r, canvas).intersect(r.outset(by: camMaxMargin))
    }

    /// The pixels a step works on: the targeted surface, or with Sample All Layers the visible
    /// composite (encoded in the target's format).
    static func caRead(_ doc: inout Document, _ t: CATarget, _ p: JSONValue, _ rect: PixelRect, _ renderer: EngineRenderer) throws -> Region {
        let (fmt, region) = try Channels.withTargetSurface(&doc, layer: t.id, p) { surf, _ -> (PixelFormat, Region?) in
            (surf.format, t.allLayers ? nil : Region.read(surf, rect))
        }
        if let region { return region }
        return try compositeRegion(renderer, doc, nil, .all, rect, fmt)
    }

    /// A copy of the targeted surface.
    static func caSurface(_ doc: inout Document, _ t: CATarget, _ p: JSONValue) throws -> Surface {
        try Channels.withTargetSurface(&doc, layer: t.id, p) { surf, _ in surf }
    }

    /// Write `out` over `mask` into the target, replacing the pixels (the result already holds
    /// what should show there). With the transparency lock, alpha is kept and transparent pixels
    /// stay as they are. Returns the written rectangle.
    static func caReplace(_ doc: inout Document, _ t: CATarget, _ p: JSONValue, _ out: Region, _ mask: [Bool]) throws -> PixelRect {
        try Channels.withTargetSurface(&doc, layer: t.id, p) { surf, lock in
            let fmt = surf.format
            let a = lock ? alphaIndex(fmt) : nil
            let rect = out.rect
            var px = surf.readRegion(rect)
            let n = out.ch
            if px.count != out.data.count || mask.count * n != px.count {
                throw EngineError.other("internal error: fill buffers disagree in size")
            }
            for (i, m) in mask.enumerated() where m {
                let o = i * n
                if let ai = a {
                    if px[o + ai] > 0 {
                        for c in 0..<n where c != ai { px[o + c] = out.data[o + c] }
                    }
                } else {
                    for c in 0..<n { px[o + c] = out.data[o + c] }
                }
            }
            surf.writeRegion(rect, px)
            return rect
        }
    }

    /// Selection coverage over `rect` as a mask (set wherever it is above zero).
    static func caMask(_ sel: Surface, _ rect: PixelRect) -> [Bool] { selectionCoverage(sel, rect).map { $0 > 0 } }

    /// Fill options: the fill's own colour adaptation (Edit › Content-Aware Fill's default), seeded
    /// so the result is reproducible.
    static func caFillOptions() -> InpaintKit.FillOptions { InpaintKit.FillOptions(seed: 0x00ca_4e00) }

    /// A ring of `w` pixels just outside `m` (within the grid).
    static func outerRing(_ gw: Int, _ gh: Int, _ m: [Bool], _ w: Int) -> [Bool] {
        let keep = erode(gw, gh, m.map { !$0 }, w)
        return zip(keep, m).map { !$0 && !$1 }
    }

    /// Runs one stage of a job's work (`a…b` of its progress) with PCAlgo's interrupt; any
    /// failure of the stage is a cancellation (photocraft `JobCtx::stage`).
    static func caStage<T>(_ ctx: JobContext, _ a: Float, _ b: Float, _ label: String, _ f: (InpaintKit.Interrupt) throws -> T) throws -> T {
        let ctl = InpaintKit.Interrupt(cancel: { ctx.isCancelled }, progress: { v in ctx.progress(a + (b - a) * v, label) })
        do { return try f(ctl) } catch { throw EngineError.cancelled }
    }

    /// Content landing at `win`: the pixels of the window, with `selected` (the selection's shape
    /// there) to be replaced by `content` (the content laid over the window). The content's middle
    /// is copied, its level fitted to the new surroundings by `color`; a `bandWidth(structure)`
    /// band inside the selection's edge is re-synthesised from the surroundings and that middle,
    /// never sampling `avoid`. Writes the result into the target and returns the rectangle it
    /// changed.
    static func land(_ doc: inout Document, _ t: CATarget, _ p: JSONValue, _ win: PixelRect, _ selected: [Bool], _ content: Region, _ avoid: [Bool],
                     _ structure: UInt8, _ color: UInt8, _ stage: (Float, Float), _ ctx: JobContext, _ label: String,
                     _ renderer: EngineRenderer) throws -> PixelRect {
        let (w, h) = (win.width, win.height)
        let here = try caRead(&doc, t, p, win, renderer)
        let n = here.ch
        guard selected.count == w * h, avoid.count == w * h, here.data.count == w * h * n, content.data.count == w * h * n else {
            throw EngineError.other("internal error: fill buffers disagree in size")
        }
        var (sx0, sy0, sx1, sy1) = (w, h, 0, 0)
        for (i, s) in selected.enumerated() where s {
            let (x, y) = (i % w, i / w)
            sx0 = min(sx0, x); sy0 = min(sy0, y); sx1 = max(sx1, x + 1); sy1 = max(sy1, y + 1)
        }
        let side = UInt32(clamping: min(max(sx1 - sx0, 0), max(sy1 - sy0, 0)))
        let core = erode(w, h, selected, bandWidth(structure, side))
        try ctx.check()
        // Colour: the content's surroundings (where it came from) against the new ones, both just
        // outside the selection's shape.
        let ring = outerRing(w, h, selected, 6)
        func pick(_ r: Region) -> [Float] {
            var v: [Float] = []
            for (i, k) in ring.enumerated() where k { v.append(contentsOf: r.data[(i * n)..<((i + 1) * n)]) }
            return v
        }
        let gb = InpaintKit.levelTransform(channels: n, from: pick(content), to: pick(here), adapt: InpaintKit.colorAmount(color))
        let fmt = try caSurface(&doc, t, p).format
        let alpha = alphaIndex(fmt)
        var buf = here
        for (i, c) in core.enumerated() where c {
            for (k, g) in gb.enumerated() where k < n {
                let v = content.data[i * n + k]
                // Colour channels are fitted; alpha is copied.
                buf.data[i * n + k] = k == alpha ? v : g.x * v + g.y
            }
        }
        PCPaint.Retouch.clampSamples(fmt, &buf.data)
        // Structure: the band between the kept core and the selection's edge comes from the
        // surroundings and the kept core, never from what `avoid` marks.
        let band = zip(selected, core).map { $0 && !$1 }
        if band.contains(true) {
            let allowed = avoid.map { !$0 }
            var opts = caFillOptions()
            opts.colorAdaptation = color == 0 ? InpaintKit.colorLevel("default") : InpaintKit.colorAmount(color)
            let data = buf.data
            buf.data = try caStage(ctx, stage.0, stage.1, label) { ctl in
                try InpaintKit.fillWith(width: w, height: h, channels: n, image: data, hole: band, source: allowed, options: opts, interrupt: ctl)
            }
        }
        return try caReplace(&doc, t, p, buf, selected)
    }

    /// Warp a surface whose pixels outside the content read as its default (a selection): warp
    /// the content with alpha, then flatten back onto the default value (photocraft
    /// `transform_cmds::warp_gray`, bilinear).
    static func warpGray(_ s: Surface, _ h: Homography) -> Surface {
        let def = s.defaultPixelValue.first ?? 0
        let fmt = s.format
        let src = s.contentBounds
        var out = Surface(format: fmt, defaultPixel: [def])
        if src.isEmpty || fmt.channels != 1 { return out }
        var tmp = Surface(format: fmt.with(alpha: true))
        let v = s.readRegion(src)
        var lifted = [Float](repeating: 1, count: v.count * 2)
        for (i, g) in v.enumerated() { lifted[i * 2] = g }
        tmp.writeRegion(src, lifted)
        let warped = Transform.warpSurface(tmp, srcRect: src, h: h, interp: .bilinear)
        // Clear the old content region, then composite the warped content over it.
        out.writeRegion(src, [Float](repeating: def, count: src.area))
        let b = warped.contentBounds
        if !b.isEmpty, warped.format.channels == 2 {
            let px = warped.readRegion(b)
            var flat = [Float](repeating: 0, count: px.count / 2)
            for i in flat.indices { flat[i] = px[i * 2] * px[i * 2 + 1] + def * (1 - px[i * 2 + 1]) }
            out.writeRegion(b, flat)
        }
        out.prune()
        return out
    }

    /// The new target surface, the rectangle it changed and (Transform On Drop) the transformed
    /// selection: the content pasted at the offset, then (`move`) its old place filled. Works on
    /// `doc`, a copy of the document.
    static func runMove(_ doc: inout Document, _ sel: Surface, _ plan: CAMPlan, _ p: JSONValue, _ ctx: JobContext, _ label: String,
                        _ renderer: EngineRenderer) throws -> (Surface, PixelRect, Surface?) {
        let (dx, dy) = plan.offset
        let opts = caFillOptions()
        let split: Float = plan.mode == .move ? 0.4 : 1
        var inv: Homography?
        if let h = plan.map {
            guard let i = h.inverse() else { throw bad(camCmd, "the transform collapses the selection") }
            inv = i
        }
        // The selection's coverage over the area, which the transformed shape is sampled from.
        let cov = inv != nil ? selectionCoverage(sel, plan.area) : []

        // 1. The content at its new place: the content with its original surroundings laid over
        // the window there; never sampling the content's old place.
        let win = camWindow(plan.dest, plan.canvas)
        let content: Region
        let moved: [Bool]
        if let inv {
            // Only the content and a ring around it (the colour fit's reference) matter: read the
            // source behind that, a few pixels past the area, and resample it.
            let behind = mappedBounds(inv, plan.dest.outset(by: 8)).intersect(plan.area.outset(by: camMaxMargin)).intersect(plan.canvas)
            let srcRect = behind.isEmpty ? plan.area : behind
            content = camResample(try caRead(&doc, plan.target, p, srcRect, renderer), inv, win)
            moved = landedMask(cov, plan.area, inv, win)
        } else {
            var c = try caRead(&doc, plan.target, p, win.offsetBy(dx: -dx, dy: -dy), renderer)
            c.rect = win
            content = c
            moved = caMask(sel, win.offsetBy(dx: -dx, dy: -dy))
        }
        let oldPlace = caMask(sel, win)
        var damage = try land(&doc, plan.target, p, win, moved, content, oldPlace, plan.structure, plan.color, (0, split), ctx, label, renderer)

        // 2. Move: fill the place the content left (where the content didn't land on it).
        if plan.mode == .move {
            try ctx.check()
            let win = camWindow(plan.area, plan.canvas)
            let (w, h) = (win.width, win.height)
            let img = try caRead(&doc, plan.target, p, win, renderer)
            let landed = inv.map { landedMask(cov, plan.area, $0, win) } ?? caMask(sel, win.offsetBy(dx: -dx, dy: -dy))
            let hole = zip(caMask(sel, win), landed).map { $0 && !$1 }
            if hole.contains(true) {
                let allowed = landed.map { !$0 }
                let data = try caStage(ctx, split, 1, label) { ctl in
                    try InpaintKit.fillWith(width: w, height: h, channels: img.ch, image: img.data, hole: hole, source: allowed, options: opts,
                                            interrupt: ctl)
                }
                damage = damage.union(try caReplace(&doc, plan.target, p, Region(rect: win, ch: img.ch, data: data), hole))
            }
        }
        let surf = try caSurface(&doc, plan.target, p)
        // The selection follows the transformed content, as Select › Transform Selection moves it.
        let movedSel = plan.map.map { warpGray(sel, $0) }
        return (surf, damage, movedSel)
    }

    /// The Content-Aware Move Tool: move (or, in `extend` mode, duplicate) the selected pixels by
    /// `offset`, blending them in and filling the place they left content-aware. A background
    /// job; the selection moves, and is transformed, with the content.
    static func contentAwareMove(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let plan = try camPlan(s, p)
        let label = plan.mode == .move ? "Content-Aware Move" : "Content-Aware Extend"
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let renderer = s.services.renderer
        return try s.runJob(label, lockDocument: true, work: { ctx in
            ctx.progress(0, label)
            var work = doc
            guard let sel = doc.selection else { throw bad(camCmd, "select the area to move first") }
            return try runMove(&work, sel, plan, p, ctx, label, renderer)
        }, apply: { s, out, _ in
            let (surf, damage, movedSel) = out
            let (dx, dy) = plan.offset
            try s.edit(label) { doc, _ in
                try Channels.withTargetSurface(&doc, layer: plan.target.id, p) { t, _ in t = surf }
                // The selection follows the content, ready for another drag.
                if let moved = movedSel {
                    doc.selection = moved.contentBounds.isEmpty ? nil : moved
                } else if let sel = doc.selection {
                    doc.selection = sel.shifted(dx: dx, dy: dy)
                }
            }
            s.noteDamage(damage)
            var o: JSONValue = ["damage": .rect(damage), "offset": [.int(Int(dx)), .int(Int(dy))],
                                "mode": .string(plan.mode == .move ? "move" : "extend")]
            if plan.map != nil { o = o.setting("transformed", true) }
            return o
        })
    }

    // MARK: - Patch: Content-Aware (retouch_cmds/patch.rs)

    /// Patch: Content-Aware. The selection is filled from the place it was dragged to, as the
    /// Content-Aware Move Tool lands its content: only the selection changes; its middle is the
    /// dragged-to content (fitted by `color`), a `structure` band along its edge is re-synthesised.
    /// A background job.
    static func patchContentAware(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let label = "Patch (Content-Aware)"
        let plan = try patchPlan(s, p)
        let structure = UInt8(try patchLevel(p, "structure", 4, 1, 7))
        let color = UInt8(try patchLevel(p, "color", 0, 0, 10))
        let target = CATarget(id: plan.id, allLayers: flag(p, "sampleAllLayers", false) && targetsPixels(p))
        guard let d = s.active else { throw EngineError.noDocument }
        let doc = d.doc
        let (dx, dy) = plan.offset
        let (area, canvas) = (plan.area, plan.canvas)
        let renderer = s.services.renderer
        return try s.runJob(label, lockDocument: true, work: { ctx in
            ctx.progress(0, label)
            var work = doc
            guard let sel = doc.selection else { throw bad("paint.patch", "select the area to patch first") }
            let win = camWindow(area, canvas)
            var content = try caRead(&work, target, p, win.offsetBy(dx: dx, dy: dy), renderer)
            content.rect = win
            let selected = caMask(sel, win)
            let avoid = [Bool](repeating: false, count: selected.count)
            let damage = try land(&work, target, p, win, selected, content, avoid, structure, color, (0, 1), ctx, label, renderer)
            return (try caSurface(&work, target, p), damage)
        }, apply: { s, out, _ in
            let (surf, damage) = out
            try s.edit(label) { doc, _ in
                try Channels.withTargetSurface(&doc, layer: target.id, p) { t, _ in t = surf }
            }
            s.noteDamage(damage)
            return ["damage": .rect(damage), "offset": [.int(Int(dx)), .int(Int(dy))], "contentAware": true]
        })
    }
}
