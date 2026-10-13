// Port of photocraft-engine (crates/engine/src/retouch_cmds/patch.rs, retouch_cmds/pattern_stamp.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Patch Tool and the Pattern Stamp as commands. Patch's Content-Aware mode (which lands its
// content as the Content-Aware Move Tool does) is in RetouchCommands+ContentAware.swift; the
// photocraft-algo kernels (the seamless-clone Poisson solver, inpainting) are PCAlgo's.

import Foundation
import PCDocument
import PCFoundation
import PCPaint
import PCRender
import Synchronization

extension RetouchCommands {
    // MARK: - Patch (retouch_cmds/patch.rs)

    /// Largest patch, in pixels of the selection's bounding box.
    static let patchMaxPixels: UInt64 = 16 << 20

    /// A pixel target and a selection to patch with.
    static let patchEnabled: CommandEnabled = { s, p in
        if let why = hasPixelLayer(s, p) { return why }
        guard let d = s.active else { return "no document open" }
        return d.doc.selection != nil ? nil : "select the area to patch first"
    }

    /// The layer `p` targets (nil for an alpha channel or the Quick Mask), as `parseBrush`.
    static func targetLayer(_ s: Session, _ p: JSONValue) throws -> LayerId? {
        if Channels.isChannelTarget(p) { return nil }
        guard let id = Params.layerId(p) ?? s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    /// Integer drag offset, rejecting non-finite and absurd values.
    static func patchOffset(_ cmd: String, _ p: JSONValue) throws -> (Int32, Int32) {
        guard let o = point(p, "offset") else { throw bad(cmd, "missing `offset` ([dx, dy])") }
        let ok = { (v: Double) in v.isFinite && abs(v) < 1e7 }
        if !ok(o.x) || !ok(o.y) { throw bad(cmd, "`offset` must be two finite numbers") }
        return (Int32(o.x.rounded()), Int32(o.y.rounded()))
    }

    /// Selected area within the canvas: the selection's content bounds, or the whole canvas when
    /// the selection covers everything outside its tiles (an inverted selection).
    static func selectionArea(_ sel: Surface, _ canvas: PixelRect) -> PixelRect {
        let outside = sel.defaultPixelValue.first ?? 0
        return (outside > 0 ? canvas : sel.contentBounds).intersect(canvas)
    }

    /// Selection coverage over `rect` (row-major, 0…1).
    static func selectionCoverage(_ sel: Surface, _ rect: PixelRect) -> [Float] {
        sel.coverage(rect).map { min(max($0, 0), 1) }
    }

    /// Seamless clone with the membrane solved `step` times coarser: the Poisson result is the
    /// source plus a harmonic correction `h` of the boundary mismatch, so `h` is solved on a grid of
    /// `step`×`step` cells and interpolated back, while the texture stays the full-resolution
    /// source. The live preview's approximation of `healRegion` (`step` 1 is exactly it).
    static func healRegionCoarse(_ fmt: PixelFormat, _ src: Region, _ dst: Region, _ mask: [Bool], _ step: Int) -> Region {
        if step <= 1 { return healRegion(fmt, src, dst, mask) }
        let (w, h, n) = (dst.width, dst.height, dst.ch)
        let (cw, chh) = ((w + step - 1) / step, (h + step - 1) / step)
        // A cell is unknown when every pixel in it is patched; otherwise it holds the mean mismatch
        // `dst - src` of its unpatched pixels (the Dirichlet data of the coarse problem).
        var diff = [Float](repeating: 0, count: cw * chh * n)
        var hole = [Bool](repeating: true, count: cw * chh)
        var count = [UInt32](repeating: 0, count: cw * chh)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if mask[i] { continue }
                let c = (y / step) * cw + x / step
                hole[c] = false
                count[c] += 1
                for k in 0..<n { diff[c * n + k] += dst.data[i * n + k] - src.data[i * n + k] }
            }
        }
        for (c, m) in count.enumerated() where m > 0 {
            for k in 0..<n { diff[c * n + k] /= Float(m) }
        }
        let membrane = Kernels.membraneFill(cw, chh, n, diff, hole)
        // Bilinear lookup of the membrane (cell centres at (c + 0.5) · step).
        func lerpAt(_ p: Int, _ cells: Int) -> (Int, Int, Float) {
            let f = min(max((Float(p) + 0.5) / Float(step) - 0.5, 0), Float(cells - 1))
            let c0 = Int(f.rounded(.down))
            return (c0, min(c0 + 1, cells - 1), f - Float(c0))
        }
        let xs = (0..<w).map { lerpAt($0, cw) }
        var out = dst
        for y in 0..<h {
            let (y0, y1, ty) = lerpAt(y, chh)
            for (x, (x0, x1, tx)) in xs.enumerated() {
                let i = y * w + x
                if !mask[i] { continue }
                for k in 0..<n {
                    func v(_ cx: Int, _ cy: Int) -> Float { membrane[(cy * cw + cx) * n + k] }
                    let mv = (v(x0, y0) * (1 - tx) + v(x1, y0) * tx) * (1 - ty) + (v(x0, y1) * (1 - tx) + v(x1, y1) * tx) * ty
                    out.data[i * n + k] = src.data[i * n + k] + mv
                }
            }
        }
        Retouch.clampSamples(fmt, &out.data)
        return out
    }

    /// What a patch does, checked: the target layer, the selected area, and where it heals from
    /// and to.
    struct PatchPlan {
        var id: LayerId?
        var canvas: PixelRect
        var area: PixelRect
        /// Shift of the repaired area from the selection, and of the texture from the repaired area.
        var dstShift: (Int32, Int32)
        var srcShift: (Int32, Int32)
        var destination: Bool
        var offset: (Int32, Int32)
    }

    static func patchPlan(_ s: Session, _ p: JSONValue) throws -> PatchPlan {
        let cmd = "paint.patch"
        let destination: Bool
        switch string(p, "mode", "source") {
        case "source": destination = false
        case "destination": destination = true
        case let o: throw bad(cmd, "unknown mode `\(o)` (source|destination)")
        }
        let (dx, dy) = try patchOffset(cmd, p)
        let id = try targetLayer(s, p)
        guard let d = s.active else { throw EngineError.other("no document open") }
        let canvas = d.doc.bounds
        guard let sel = d.doc.selection else { throw bad(cmd, "select the area to patch first") }
        let area = selectionArea(sel, canvas)
        if area.isEmpty { throw bad(cmd, "the selection is empty") }
        let pixels = UInt64(area.width) * UInt64(area.height)
        if pixels > patchMaxPixels { throw bad(cmd, "the selection is too large to patch (\(pixels) pixels, at most \(patchMaxPixels))") }
        if dx == 0 && dy == 0 { throw bad(cmd, "drag the selection to the area to sample from") }
        // Both the texture and the repaired area must lie on the canvas: off-canvas pixels are empty.
        if !canvas.contains(area.offsetBy(dx: dx, dy: dy)) { throw bad(cmd, "the dragged patch must stay inside the canvas") }
        return PatchPlan(id: id, canvas: canvas, area: area, dstShift: destination ? (dx, dy) : (0, 0), srcShift: destination ? (-dx, -dy) : (dx, dy),
                         destination: destination, offset: (dx, dy))
    }

    /// Heal `surf` at the selection (shifted by `dstShift`) with texture read `srcShift` away, the
    /// membrane solved `step` times coarser (1 = exact). Returns the damaged rectangle.
    static func patchSurface(_ surf: inout Surface, _ sel: Surface, _ plan: PatchPlan, _ lock: Bool, _ step: Int) -> PixelRect {
        let (canvas, area, ds, ss) = (plan.canvas, plan.area, plan.dstShift, plan.srcShift)
        // The repaired area plus a two-pixel ring: the ring is the Dirichlet boundary of the solve,
        // clipped to where both the repaired and the sampled pixels lie on the canvas, so a patch
        // at the canvas edge sees a free (Neumann) boundary there.
        let dstArea = area.offsetBy(dx: ds.0, dy: ds.1)
        let g = dstArea.outset(by: 2).intersect(canvas).intersect(canvas.offsetBy(dx: -ss.0, dy: -ss.1))
        if g.isEmpty { return .empty }
        let fmt = surf.format
        let dst = Region.read(surf, g)
        var src = Region.read(surf, g.offsetBy(dx: ss.0, dy: ss.1))
        src.rect = g
        // Selection coverage moved to the repaired place.
        let cov = selectionCoverage(sel, g.offsetBy(dx: -ds.0, dy: -ds.1))
        let healed = healRegionCoarse(fmt, src, dst, cov.map { $0 > 0 }, step)
        return Retouch.applyCoverage(&surf, rect: g, cov: cov, opacity: 1, selection: nil, lockTransparency: lock, paint: healed, blend: .normal)
    }

    static func patch(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.patch"
        if flag(p, "contentAware", false) { return try patchContentAware(s, p) }
        let plan = try patchPlan(s, p)
        let dmg = try runStroke(s, plan.destination ? "Patch (Destination)" : "Patch", plan.id, p) { pre, surf, _, lock in
            guard let sel = pre.selection else { throw bad(cmd, "select the area to patch first") }
            return patchSurface(&surf, sel, plan, lock, 1)
        }
        return ["damage": .rect(dmg), "offset": [.int(Int(plan.offset.0)), .int(Int(plan.offset.1))]]
    }

    /// The live preview of `paint.patch` with params `p`: the active document with the patch
    /// applied (nothing is recorded), and the rectangle it changed. For large patches the membrane
    /// is solved coarser: the texture is exact, the colour fit approximate. `maxCells` caps the
    /// coarse grid, `minStep` sets a floor on the coarsening (the view's zoom-out factor).
    static func patchPreview(_ s: Session, _ p: JSONValue, maxCells: UInt64, minStep: UInt32) throws -> (Document, PixelRect) {
        let plan = try patchPlan(s, p)
        guard let d = s.active else { throw EngineError.other("no document open") }
        let pixels = UInt64(plan.area.width + 4) * UInt64(plan.area.height + 4)
        // Smallest step whose grid fits `maxCells`: step² · cells ≥ pixels.
        let need = Int((Double(pixels) / Double(max(maxCells, 1))).squareRoot().rounded(.up))
        let step = min(max(max(need, Int(minStep)), 1), 64)
        var doc = d.doc
        guard let sel = d.doc.selection else { throw bad("paint.patch", "select the area to patch first") }
        let dmg = try Channels.withTargetSurface(&doc, layer: plan.id, p) { surf, lock in patchSurface(&surf, sel, plan, lock, step) }
        return (doc, dmg)
    }

    /// Optional whole-number param in `lo…hi`; absent or null gives `fallback`.
    static func patchLevel(_ p: JSONValue, _ k: String, _ fallback: Int, _ lo: Int, _ hi: Int) throws -> Int {
        guard let v = p[k], v != .null else { return fallback }
        guard let x = v.doubleValue, x.isFinite, x >= Double(lo), x <= Double(hi) else {
            throw bad("paint.patch", "`\(k)` must be a number \(lo)..\(hi)")
        }
        return Int(x.rounded())
    }

    // MARK: - Pattern Stamp (retouch_cmds/pattern_stamp.rs)

    /// A single stroke's accumulated coverage must stay at or under this many pixels (8192²).
    static let maxStrokePixels: UInt64 = 67_108_864
    static let streamPhaseX: UInt64 = 101
    static let streamPhaseY: UInt64 = 102

    /// The pattern library Pattern Stamp resolves from (photocraft `s.patterns.items` and the
    /// Patterns panel's selection, `presets::patterns::current`).
    struct PatternLibraryView: Sendable {
        var current: PCDocument.Pattern?
        var items: [PCDocument.Pattern]
    }

    typealias PatternLibraryProvider = @Sendable (Session) -> PatternLibraryView

    /// A replacement for the Patterns panel's library (pattern_cmds / presets::patterns), for
    /// tests. Without one, Pattern Stamp paints from the session's library and panel selection.
    static let patternLibraryProvider = Mutex<PatternLibraryProvider?>(nil)

    /// Installs the session pattern library lookup (`replace: false` keeps an installed one).
    static func installPatternLibrary(replace: Bool = true, _ f: @escaping PatternLibraryProvider) {
        patternLibraryProvider.withLock { if replace || $0 == nil { $0 = f } }
    }

    static func patternLibrary(_ s: Session) -> PatternLibraryView {
        if let f = patternLibraryProvider.withLock({ $0 }) { return f(s) }
        // The Patterns panel's library and selection (pattern_cmds / presets).
        return PatternLibraryView(current: PresetCommands.currentPattern(s), items: PatternCommands.library(s))
    }

    /// photocraft `pattern_cmds::resolve`: by id or name, the active document's first, then the
    /// library; an empty key picks the Patterns panel's selection, else the first library pattern.
    static func resolvePattern(_ s: Session, _ key: String) -> PCDocument.Pattern? {
        let lib = patternLibrary(s)
        if key.isEmpty { return lib.current ?? lib.items.first }
        if let d = s.active, let p = PCDocument.Pattern.find(d.doc.patterns, id: key, name: key) { return p }
        return PCDocument.Pattern.find(lib.items, id: key, name: key)
    }

    static let patternStampEnabled: CommandEnabled = { s, p in
        if let why = hasPixelLayer(s, p) { return why }
        return resolvePattern(s, "") == nil ? "no pattern selected" : nil
    }

    static func patternStamp(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.patternStamp"
        var (stroke, id) = try parseBrush(s, p, cmd)
        let mode = try blendParam(p, cmd)
        let aligned = flag(p, "aligned", true)
        let impressionist = flag(p, "impressionist", false)
        let key = p["pattern"]?.stringValue ?? ""
        guard let pat = resolvePattern(s, key) else { throw bad(cmd, "no pattern \"\(key)\" (see pattern.list)") }
        if pat.isEmpty { throw bad(cmd, "the pattern is empty") }
        let scale = try stampScale(p, cmd)
        let angle = try stampAngle(p, cmd)
        guard let first = stroke.points.first else { throw bad(cmd, "`points` is empty") }
        let phase = try stampPhase(p, cmd, aligned, first)
        // compose::pattern::Tile::new: the pattern painted into RGB.
        guard pat.isPaintable else { throw bad(cmd, "the pattern is empty or too large to paint") }
        let tile = PatternTile(id: pat.id, name: pat.name, width: Int(pat.width), height: Int(pat.height), straight: pat.surface.readRGBA(pat.rect))
        try rejectHugeStroke(cmd, stroke)
        let seed = p["seed"]?.uint64Value ?? PaintRNG.seed(fromBytes: Array((p["points"].map { $0.serialized() } ?? "").utf8))
        stroke.brush.seed = seed
        let dmg = try s.edit("Pattern Stamp") { doc, _ in
            if !doc.patterns.contains(where: { $0.id == pat.id }) { doc.patterns.append(pat) }
            let pre = doc
            return try Channels.withTargetSurface(&doc, layer: id, p) { surf, lock in
                if impressionist {
                    return paintImpressionist(&surf, stroke, pre.selection, lock, tile, pat, phase, scale, angle, seed, mode)
                }
                return try paintAligned(&surf, stroke, pre.selection, lock, tile, phase, scale, angle, mode, cmd)
            }
        }
        s.noteDamage(dmg)
        return ["damage": .rect(dmg), "phase": [.float(phase.x), .float(phase.y)], "aligned": .bool(aligned), "pattern": .string(pat.id)]
    }

    static func stampScale(_ p: JSONValue, _ cmd: String) throws -> Float {
        guard let v = p["scale"] else { return 1 }
        guard let x = v.doubleValue else { throw bad(cmd, "`scale` must be a number (1..1000 %)") }
        if !x.isFinite || x < 1 || x > 1000 { throw bad(cmd, "scale must be 1..1000 %") }
        return Float(x) / 100
    }

    static func stampAngle(_ p: JSONValue, _ cmd: String) throws -> Float {
        guard let v = p["angle"] else { return 0 }
        guard let a = v.doubleValue else { throw bad(cmd, "`angle` must be a number (degrees)") }
        if !a.isFinite { throw bad(cmd, "`angle` must be finite") }
        return Float(a)
    }

    static func stampPhase(_ p: JSONValue, _ cmd: String, _ aligned: Bool, _ first: StrokePoint) throws -> SIMD2<Float> {
        guard let v = p["phase"] else { return aligned ? .zero : SIMD2(Float(first.x), Float(first.y)) }
        guard let a = v.arrayValue, let x = a.first?.doubleValue, a.count > 1, let y = a[1].doubleValue else { throw bad(cmd, "`phase` must be [px, py]") }
        if !x.isFinite || !y.isFinite { throw bad(cmd, "`phase` coordinates must be finite") }
        return SIMD2(Float(x), Float(y))
    }

    static func rejectHugeStroke(_ cmd: String, _ stroke: Stroke) throws {
        let pad = Double(Float.maximum(stroke.brush.size, 1)) * 0.5 + 4
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for q in stroke.points {
            minX = Double.minimum(minX, q.x); minY = Double.minimum(minY, q.y)
            maxX = Double.maximum(maxX, q.x); maxY = Double.maximum(maxY, q.y)
        }
        if !minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite { throw bad(cmd, "point coordinates must be finite") }
        let w = Double.maximum((maxX - minX + pad * 2).rounded(.up), 1)
        let h = Double.maximum((maxY - minY + pad * 2).rounded(.up), 1)
        if !w.isFinite || !h.isFinite || w > 1e9 || h > 1e9 { throw bad(cmd, "stroke too large (at most \(maxStrokePixels) px)") }
        let area = UInt64(w).multipliedReportingOverflow(by: UInt64(h))
        if area.overflow || area.partialValue > maxStrokePixels {
            throw bad(cmd, "stroke too large (\(Int64(w))×\(Int64(h)) px, at most \(maxStrokePixels))")
        }
    }

    static func rejectBounds(_ cmd: String, _ bounds: PixelRect) throws {
        if bounds.isEmpty { return }
        let (w, h) = (UInt64(bounds.width), UInt64(bounds.height))
        if w * h > maxStrokePixels { throw bad(cmd, "stroke too large (\(w)×\(h) px, at most \(maxStrokePixels))") }
    }

    static func placement(_ phase: SIMD2<Float>, _ scale: Float, _ angle: Float) -> PatternPlacement {
        PatternPlacement(frame: .empty, link: false, phase: phase, scale: scale, angle: angle)
    }

    /// photocraft `compose::pattern::render`: the tile through the placement over `rect`.
    static func renderPattern(_ tile: PatternTile, _ place: PatternPlacement, _ rect: PixelRect) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(rect.area)
        if rect.isEmpty { return out }
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let (u, v) = place.map(Double(x) + 0.5, Double(y) + 0.5)
                out.append(tile.sample(u, v))
            }
        }
        return out
    }

    static func rgbaToRegion(_ fmt: PixelFormat, _ rect: PixelRect, _ rgba: [SIMD4<Float>]) -> Region {
        let n = fmt.channels
        var paint = Region(rect: rect, ch: n)
        var enc = [Float](repeating: 0, count: 8)
        enc.withUnsafeMutableBufferPointer { e in
            for (i, px) in rgba.enumerated() where (i + 1) * n <= paint.data.count {
                _ = fromRGBA(fmt, px, into: e.baseAddress!)
                for c in 0..<n { paint.data[i * n + c] = e[c] }
            }
        }
        return paint
    }

    static func paintAligned(_ surf: inout Surface, _ stroke: Stroke, _ sel: Surface?, _ lock: Bool, _ tile: PatternTile, _ phase: SIMD2<Float>,
                             _ scale: Float, _ angle: Float, _ mode: BlendMode, _ cmd: String) throws -> PixelRect {
        let (bounds, cov) = Retouch.strokeCoverage(stroke)
        try rejectBounds(cmd, bounds)
        if bounds.isEmpty { return .empty }
        let rgba = renderPattern(tile, placement(phase, scale, angle), bounds)
        let paint = rgbaToRegion(surf.format, bounds, rgba)
        return Retouch.applyCoverage(&surf, rect: bounds, cov: cov, opacity: stroke.brush.opacity, selection: sel, lockTransparency: lock,
                                     paint: paint, blend: mode)
    }

    static func paintImpressionist(_ surf: inout Surface, _ stroke: Stroke, _ sel: Surface?, _ lock: Bool, _ tile: PatternTile, _ pat: PCDocument.Pattern,
                                   _ phase: SIMD2<Float>, _ scale: Float, _ angle: Float, _ seed: UInt64, _ mode: BlendMode) -> PixelRect {
        let fmt = surf.format
        let tw = Float(pat.width) * scale, th = Float(pat.height) * scale
        // Halo is the dab footprint only: Impressionist jitters phase, it does not blur.
        return Retouch.applyDabStroke(&surf, stroke, selection: sel, lockTransparency: lock, halo: 0) { work, fp in
            stampDab(&work, fmt, tile, fp, phase, scale, angle, seed, tw, th, mode)
        }
    }

    static func footprintCoverage(_ fp: Footprint, _ x: Int32, _ y: Int32) -> Float {
        if x < fp.rect.x0 || y < fp.rect.y0 { return 0 }
        let dx = Int(x) - Int(fp.rect.x0), dy = Int(y) - Int(fp.rect.y0)
        let i = dy * fp.rect.width + dx
        return i < fp.cov.count ? fp.cov[i] : 0
    }

    static func stampDab(_ work: inout Region, _ fmt: PixelFormat, _ tile: PatternTile, _ fp: Footprint, _ phase: SIMD2<Float>, _ scale: Float,
                         _ angle: Float, _ seed: UInt64, _ tw: Float, _ th: Float, _ mode: BlendMode) {
        let r = fp.rect.intersect(work.rect)
        if r.isEmpty { return }
        let i = UInt64(fp.index)
        let jx = PaintRNG.randSigned(seed, i, streamPhaseX) * tw
        let jy = PaintRNG.randSigned(seed, i, streamPhaseY) * th
        let rgba = renderPattern(tile, placement(SIMD2(phase.x + jx, phase.y + jy), scale, angle), r)
        let rw = r.width, n = work.ch
        var enc = [Float](repeating: 0, count: 8)
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                let k = footprintCoverage(fp, x, y)
                if k <= 0 { continue }
                let q = Int(y - r.y0) * rw + Int(x - r.x0)
                guard q < rgba.count else { continue }
                let px = rgba[q]
                enc.withUnsafeMutableBufferPointer { e in
                    _ = fromRGBA(fmt, px, into: e.baseAddress!)
                    work.withPixel(x, y) { dst in
                        if mode == .normal {
                            overNative(fmt, dst.baseAddress!, UnsafePointer(e.baseAddress!), k, false)
                        } else {
                            let d = toRGBA(fmt, UnsafePointer(dst.baseAddress!))
                            let o = Blend.composite(mode, backdrop: d, source: px, opacity: k)
                            _ = fromRGBA(fmt, o, into: e.baseAddress!)
                            for c in 0..<n { dst[c] = e[c] }
                        }
                    }
                }
            }
        }
    }
}
