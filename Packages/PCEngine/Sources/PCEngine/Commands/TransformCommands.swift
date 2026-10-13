// Port of photocraft-engine (crates/engine/src/transform_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Free Transform as data (`edit.transform`): a projective map, given as where the frame's
// corners go (`quad`) or as an affine `matrix`, applied to a layer — its pixels (only the selected
// ones with a selection), linked masks and vector masks, type and shapes as vectors, groups
// recursively, smart objects by their placement — or, when the params (or the Channels panel)
// target one, to an unlinked layer mask, an alpha channel or the Quick Mask alone. The selection
// outline moves with the pixels. Resampling is PCAlgo's (`Transform.warpSurface`).
//
// Smart objects: the transform goes into the placement and the object re-renders from its source
// (`SmartCommands.refreshLayer`, with the session's services), so repeated transforms don't
// degrade the pixels; a source that can't be rendered keeps the warped cache (and filter mask).
// The helpers here are shared with the warp, distort and preset commands.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

enum TransformCommands: CommandModule {
    static let name = "transform_cmds"
    static let m = name

    /// photocraft `has_layer`.
    static let hasLayer: CommandEnabled = { s, _ in s.active?.activeLayer == nil ? "no active layer" : nil }

    static func bad(_ msg: String) -> EngineError { .bad("edit.transform", msg) }

    /// Rust's saturating `f64 as i32` (NaN → 0).
    static func i32(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(Swift.max(Swift.min(v, 2_147_483_647), -2_147_483_648))
    }

    /// `s` unless it selects nothing (photocraft `.filter(|s| !s.content_bounds().is_empty())`).
    static func nonEmpty(_ s: Surface) -> Surface? { s.contentBounds.isEmpty ? nil : s }

    // MARK: Frames

    /// Layers a transform moves as a whole, even with a selection: groups, and the kinds that keep
    /// the transform instead of pixels (type, shapes, smart objects). Only pixel layers move just
    /// the selected pixels (photocraft `moves_whole`).
    static func movesWhole(_ l: Layer) -> Bool {
        switch l.content {
        case .group, .text, .shape, .smart: true
        default: false
        }
    }

    /// Document-space bounds a transform of `l` starts from (what Free Transform frames): the
    /// content within the selection, or all of it for a layer that `movesWhole` (photocraft
    /// `transform_bounds`, #2630).
    static func transformBounds(_ doc: Document, _ l: Layer) -> PixelRect {
        var content: PixelRect
        if case .group(let g) = l.content {
            content = g.children.reduce(PixelRect.empty) { $0.union(transformBounds(doc, $1)) }
        } else {
            content = l.surface?.contentBounds ?? .empty
        }
        if content.isEmpty { content = l.mask?.surface.contentBounds ?? .empty }
        if let sel = doc.selection, !movesWhole(l) { return content.intersect(sel.contentBounds) }
        return content
    }

    /// The frame Free Transform starts from on a lone target: its painted content (the whole
    /// canvas when nothing is painted), within the selection (photocraft `target_bounds`).
    static func targetBounds(_ doc: Document, _ surf: Surface) -> PixelRect {
        var content = surf.contentBounds
        if content.isEmpty { content = doc.bounds }
        if let sel = doc.selection { return content.intersect(sel.contentBounds) }
        return content
    }

    // MARK: Resampling

    /// The backend for a `Transform` warp of `srcRect` through `h` (within `clip`): PCAlgo's GPU
    /// path works on a dense image spanning the source and the destination, so its cost grows
    /// with how far the warp moves the content (a 6×5 px selection moved 10⁵ px took seconds); such
    /// warps take the tiled CPU path, which gives the same pixels.
    static func backend(_ srcRect: PixelRect, _ h: Homography, clip: PixelRect? = nil) -> Backend {
        let pts = [(srcRect.x0, srcRect.y0), (srcRect.x1, srcRect.y0), (srcRect.x1, srcRect.y1), (srcRect.x0, srcRect.y1)]
            .map { h.apply(Double($0.0), Double($0.1)) }
        guard pts.allSatisfy({ $0.0.isFinite && $0.1.isFinite }) else { return .cpu }
        var d = (pts.map(\.0).min() ?? 0, pts.map(\.1).min() ?? 0, pts.map(\.0).max() ?? 0, pts.map(\.1).max() ?? 0)
        if let c = clip {
            d = (Swift.max(d.0, Double(c.x0)), Swift.max(d.1, Double(c.y0)), Swift.min(d.2, Double(c.x1)), Swift.min(d.3, Double(c.y1)))
            if d.2 <= d.0 || d.3 <= d.1 { return .cpu }
        }
        let s = (Double(srcRect.x0), Double(srcRect.y0), Double(srcRect.x1), Double(srcRect.y1))
        let union = (Swift.max(s.2, d.2) - Swift.min(s.0, d.0)) * (Swift.max(s.3, d.3) - Swift.min(s.1, d.1))
        let sum = Double(srcRect.area) + Swift.max(d.2 - d.0, 0) * Swift.max(d.3 - d.1, 0)
        return union <= 4 * sum + 65_536 ? .auto : .cpu
    }

    /// `Transform.warpSurface` on the backend `backend` picks.
    static func warp(_ src: Surface, _ srcRect: PixelRect, _ h: Homography, _ interp: Interp) -> Surface {
        Transform.warpSurface(src, srcRect: srcRect, h: h, interp: interp, on: backend(srcRect, h))
    }

    // MARK: Masks and channels

    /// Warps a surface whose pixels outside the content read as its default (masks, selections,
    /// channels): the content is warped with alpha, then flattened back onto the default
    /// (photocraft `warp_gray`). The old content region and the warped one are written
    /// separately, so a far move costs only their own tiles.
    static func warpGray(_ s: Surface, _ h: Homography, _ interp: Interp) -> Surface {
        let def = s.defaultPixelValue
        let fmt = s.format
        let src = s.contentBounds
        var out = Surface(format: fmt, defaultPixel: def)
        if src.isEmpty { return out }
        // Content-only copy (transparent outside) so the "outside" stays out of the warp.
        let (lifted, n) = withOpaqueAlpha(s, src)
        let w = warp(lifted, src, h, interp)
        var old = [Float](repeating: def.first ?? 0, count: src.area * def.count)
        if def.count > 1 { for i in 0..<src.area { for c in def.indices { old[i * def.count + c] = def[c] } } }
        out.writeRegion(src, old)
        flatten(w, onto: &out, def: def, n: n)
        out.prune()
        return out
    }

    /// The content of `s` over `src` with an opaque alpha channel appended (a surface whose
    /// outside is transparent) and its colour channel count.
    static func withOpaqueAlpha(_ s: Surface, _ src: PixelRect) -> (Surface, Int) {
        let fmt = s.format
        let n = fmt.channels
        let v = s.readRegion(src)
        var lifted = [Float](repeating: 1, count: src.area * (n + 1))
        for i in 0..<src.area { for c in 0..<n { lifted[i * (n + 1) + c] = v[i * n + c] } }
        var tmp = Surface(format: PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true))
        if tmp.channels == n + 1 { tmp.writeRegion(src, lifted) }
        return (tmp, n)
    }

    /// Writes the warped content `w` (`n` channels + alpha) over `out`, blended onto `def`.
    static func flatten(_ w: Surface, onto out: inout Surface, def: [Float], n: Int, clip: PixelRect? = nil) {
        var b = w.contentBounds
        if let clip { b = b.intersect(clip) }
        guard !b.isEmpty, w.channels == n + 1, out.channels == n else { return }
        let px = w.readRegion(b)
        var flat = [Float](repeating: 0, count: b.area * n)
        for i in 0..<b.area {
            let a = px[i * (n + 1) + n]
            for c in 0..<n { flat[i * n + c] = px[i * (n + 1) + c] * a + (c < def.count ? def[c] : 0) * (1 - a) }
        }
        out.writeRegion(b, flat)
    }

    /// Splits a single-channel surface whose outside reads as its default (a mask, a channel) by
    /// a selection: (the selected values as grey + alpha = selection, the surface with the
    /// selected values replaced by the default). nil for surfaces that aren't one grey channel
    /// (photocraft `split_gray_selected`).
    static func splitGraySelected(_ s: Surface, _ sel: Surface) -> (lifted: Surface, rest: Surface)? {
        let fmt = s.format
        if fmt.alpha || fmt.channels != 1 { return nil }
        let def = s.defaultPixelValue.first ?? 0
        var rest = s
        var lifted = Surface(format: PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true))
        // Everything selected moves, including default-valued parts outside the painted content,
        // so the moved region stays aligned with the moved pixels.
        let area = sel.contentBounds
        if area.isEmpty { return (lifted, rest) }
        let v = s.readRegion(area)
        let cov = sel.coverage(area)
        var lp = [Float](repeating: 0, count: v.count * 2)
        var rp = [Float](repeating: 0, count: v.count)
        for i in v.indices {
            let k = i < cov.count ? cov[i] : 0
            lp[2 * i] = v[i]
            lp[2 * i + 1] = k
            rp[i] = v[i] * (1 - k) + def * k
        }
        lifted.writeRegion(area, lp)
        lifted.prune()
        rest.writeRegion(area, rp)
        rest.prune()
        return (lifted, rest)
    }

    /// `warpGray` limited to a selection: only the selected values move (the vacated area reads
    /// as the default), as the selected pixels of the layer do (photocraft `warp_gray_selected`).
    static func warpGraySelected(_ s: Surface, _ sel: Surface, _ h: Homography, _ interp: Interp) -> Surface {
        moveGraySelected(s, sel, warp: { lifted, src in warp(lifted, src, h, interp) },
                         whole: { warpGray($0, h, interp) })
    }

    /// `warpGraySelected` with any geometric warp: `warp` moves the lifted grey + alpha values
    /// (given their bounds), `whole` moves `s` when it isn't a single grey channel (photocraft
    /// `move_gray_selected`).
    static func moveGraySelected(_ s: Surface, _ sel: Surface, warp: (Surface, PixelRect) throws -> Surface,
                                 whole: (Surface) throws -> Surface) rethrows -> Surface {
        guard let parts = splitGraySelected(s, sel) else { return try whole(s) }
        let lifted = parts.lifted
        var out = parts.rest
        let src = lifted.contentBounds
        if src.isEmpty { return out }
        let w = try warp(lifted, src)
        let b = w.contentBounds
        if !b.isEmpty, w.channels == 2, out.channels == 1 {
            let moved = w.readRegion(b)
            let under = out.readRegion(b)
            var flat = [Float](repeating: 0, count: under.count)
            for i in under.indices { flat[i] = moved[2 * i] * moved[2 * i + 1] + under[i] * (1 - moved[2 * i + 1]) }
            out.writeRegion(b, flat)
        }
        out.prune()
        return out
    }

    /// The surface Free Transform moves by itself when the params target one (`"target"`): an
    /// unlinked layer mask, an alpha channel or the Quick Mask. nil means the layer, with its
    /// linked masks (a targeted *linked* mask moves together with its layer, as in Photoshop)
    /// (photocraft `lone_target`).
    static func loneTarget(_ doc: Document, _ layer: LayerId?, _ p: JSONValue) throws -> Surface? {
        switch Channels.targetOf(p) {
        case .pixels:
            return nil
        case .mask:
            guard let id = layer else { throw EngineError.other("no active layer") }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard let m = l.mask else { throw EngineError.other("layer has no mask") }
            return m.linked ? nil : m.surface
        case .alpha(let i):
            guard i >= 0, i < doc.channels.count else { throw EngineError.other("no alpha channel \(i) (document has \(doc.channels.count))") }
            return doc.channels[i].surface
        case .quickMask:
            guard let q = doc.quickMask else { throw EngineError.other("not in Quick Mask mode") }
            return q.surface
        }
    }

    // MARK: Locks

    /// The locks `id` inherits from the groups around it (photocraft `group_locks`).
    static func groupLocks(_ doc: Document, _ id: LayerId) -> Locks {
        guard let p = doc.path(of: id), !p.isEmpty else { return Locks() }
        return doc.locks(at: Array(p.dropLast()))
    }

    /// The locks a transform of `l` meets: its own and `group`'s. The Background's position lock
    /// doesn't count: Photoshop turns it into a normal layer first (photocraft `transform_locks`).
    static func transformLocks(_ l: Layer, _ group: Locks, background: Bool) -> Locks {
        var own = l.locks
        if background {
            own.position = false
            own.transparency = false
        }
        return own.union(group)
    }

    /// Would a transform of layer `id` be refused because it, a group around it, or (for a group)
    /// a layer inside it is locked in place? The rule `transformLayer` applies at commit, so Free
    /// Transform can refuse before its box opens (photocraft `locked_for_transform`).
    static func lockedForTransform(_ doc: Document, _ id: LayerId) -> Bool {
        guard let l = doc.layer(id) else { return false }
        // An explicit stack rather than recursion: documents can nest deeply.
        var stack: [(Layer, Locks, Bool)] = [(l, groupLocks(doc, id), doc.isBackground(id))]
        while let item = stack.popLast() {
            let (l, group, background) = item
            let locks = transformLocks(l, group, background: background)
            if locks.position || locks.all { return true }
            if case .group(let g) = l.content { stack.append(contentsOf: g.children.map { ($0, locks, false) }) }
        }
        return false
    }

    // MARK: Smart object placement (photocraft smart_cmds `placement` / `set_placement` / `transform_placement`)

    /// Rounds float noise off a composed transform, so repeated transforms land back on exact,
    /// lossless placements (photocraft `snap_affine`).
    static func snapAffine(_ a: PCAffine) -> PCAffine {
        PCAffine(m: a.m.map { abs($0 - $0.rounded()) < 1e-9 ? $0.rounded() : $0 })
    }

    static func affineHomography(_ a: PCAffine) -> Homography { Homography([a.a, a.c, a.e, a.b, a.d, a.f, 0, 0, 1]) }

    /// Where the smart object's source pixels land in the document: its projective map (Distort,
    /// Perspective) or its affine transform.
    static func placement(_ sm: SmartObject) -> Homography {
        if let p = sm.perspective, p.count == 9 { return Homography(p) }
        return affineHomography(sm.transform)
    }

    /// Sets where the source lands: an affine map exactly in `transform` (no `perspective`); a
    /// projective one in `perspective`, with `transform` its affine approximation at the origin.
    static func setPlacement(_ sm: inout SmartObject, _ h: Homography) {
        let m = h.m
        let n = abs(m[8]) > 1e-12 ? m.map { $0 / m[8] } : m
        if abs(n[6]) < 1e-12 && abs(n[7]) < 1e-12 {
            sm.transform = snapAffine(PCAffine(a: n[0], b: n[3], c: n[1], d: n[4], e: n[2], f: n[5]))
            sm.perspective = nil
            return
        }
        let hh = Homography(n)
        let o = hh.apply(0, 0), x = hh.apply(1, 0), y = hh.apply(0, 1)
        sm.transform = PCAffine(a: x.0 - o.0, b: x.1 - o.1, c: y.0 - o.0, d: y.1 - o.1, e: o.0, f: o.1)
        sm.perspective = n
    }

    /// Composes `a` (document → document) onto the smart object's placement.
    static func transformPlacement(_ sm: inout SmartObject, _ a: PCAffine) {
        if sm.perspective == nil {
            sm.transform = snapAffine(a.mul(sm.transform))
        } else {
            setPlacement(&sm, affineHomography(a).mul(placement(sm)))
        }
    }

    /// photocraft `smart_cmds::refresh`: re-renders smart object `id` from its source; for a source
    /// it can't render the cache stays and the result is `false`.
    @discardableResult
    static func refreshSmart(_ doc: inout Document, _ id: LayerId, services: EngineServices? = nil) throws -> Bool {
        try SmartCommands.refresh(&doc, id, services: services)
    }

    // MARK: Transforming a layer

    /// Transforms one layer. `group` holds the locks it inherits; a Background is turned into a
    /// normal layer by the caller first (photocraft `transform_layer`).
    static func transformLayer(_ docSel: Surface?, _ group: Locks, _ l: inout Layer, _ h: Homography, _ affine: PCAffine?,
                               _ interp: Interp) throws {
        let locks = transformLocks(l, group, background: false)
        if locks.position || locks.all { throw EngineError.other("layer \"\(l.name)\" is locked") }
        if h.isIdentity {
            try l.withChildren { cs in for i in cs.indices { try transformLayer(nil, locks, &cs[i], h, affine, interp) } }
            return
        }
        // With a selection only the selected pixels move, and so only the same region of a linked
        // mask (#205). Groups, type, shapes and smart objects move whole.
        let maskSel = movesWhole(l) ? nil : docSel
        switch l.content {
        case .group:
            try l.withChildren { cs in for i in cs.indices { try transformLayer(nil, locks, &cs[i], h, affine, interp) } }
        case .text:
            guard let a = affine else {
                throw EngineError.other("Distort and Perspective need rasterized type (Type › Rasterize Type Layer)")
            }
            l.withText { t in t.transform = a.mul(t.transform) }
        case .shape:
            try l.withShape { sh in
                if let a = affine {
                    VectorCommands.transformShape(&sh, a)
                } else {
                    // Distort and Perspective map the path and keep the shape (#3009).
                    try VectorCommands.mapShape(&sh, homography: VectorCommands.Homography(m: h.m), warp: nil)
                }
            }
        case .smart:
            l.withSmartObject { sm in
                // Distort and Perspective keep the full projective map, so the fourth corner
                // survives re-renders.
                if let a = affine { transformPlacement(&sm, a) } else { setPlacement(&sm, h.mul(placement(sm))) }
                // Fallback appearance for sources that can't be re-rendered (`refreshText`
                // re-renders the others afterwards, so repeated transforms don't degrade them).
                if let c = sm.cache { sm.cache = warp(c, c.contentBounds, h, interp) }
                if var fm = sm.filterMask {
                    fm.surface = warpGray(fm.surface, h, interp)
                    sm.filterMask = fm
                }
            }
        default:
            l.withRaster { surf in
                let src = surf.contentBounds
                if let sel = docSel {
                    // Only the selected pixels move: lift them, clear them, warp and paste back.
                    let parts = splitSelected(surf, sel)
                    var rest = parts.rest
                    let moved = warp(parts.lifted, src, h, interp)
                    FloatCommands.compositeOver(&rest, moved)
                    rest.prune()
                    surf = rest
                } else {
                    surf = warp(surf, src, h, interp)
                }
            }
        }
        if var mk = l.mask, mk.linked {
            mk.surface = maskSel.map { warpGraySelected(mk.surface, $0, h, interp) } ?? warpGray(mk.surface, h, interp)
            l.mask = mk
        }
        if var vm = l.vectorMask, vm.linked {
            if let a = affine {
                vm.path = vm.path.transform(a)
            } else {
                vm.path = try VectorCommands.mapPath(vm.path, homography: VectorCommands.Homography(m: h.m), warp: nil)
            }
            l.vectorMask = vm
        }
    }

    /// Splits a layer surface by a selection: (selected pixels, everything else), both with alpha
    /// (photocraft `split_selected`).
    static func splitSelected(_ surf: Surface, _ sel: Surface) -> (lifted: Surface, rest: Surface) {
        let fmt = surf.format
        let withAlpha = PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true)
        var lifted = Surface(format: withAlpha)
        var rest = surf.convertedAny(to: withAlpha)
        let src = surf.contentBounds
        if src.isEmpty { return (lifted, rest) }
        let n = withAlpha.channels
        let px = rest.readRegion(src)
        var lp = px
        var rp = px
        // A pixel the selection fully lifts out is reset to the surface's (transparent) default;
        // keeping its colour would make `contentBounds` still count it, so the layer's bounds
        // would include the area the pixels were moved from.
        var restClear = rest.defaultPixelValue
        if let a = restClear.last, a > 0 { restClear = Array(repeating: 0, count: restClear.count) }
        let cov = sel.coverage(src)
        for i in 0..<src.area {
            let k = i < cov.count ? cov[i] : 0
            let o = i * n
            lp[o + n - 1] *= k
            rp[o + n - 1] *= 1 - k
            if rp[o + n - 1] <= 0 { for c in 0..<min(n, restClear.count) { rp[o + c] = restClear[c] } }
        }
        lifted.writeRegion(src, lp)
        lifted.prune()
        rest.writeRegion(src, rp)
        return (lifted, rest)
    }

    /// Re-renders type, shapes and smart objects after a transform (photocraft `refresh_text`).
    /// Smart objects read linked files through `services` (none without it).
    static func refreshText(_ doc: Document, _ l: inout Layer, services: EngineServices? = nil) {
        switch l.content {
        case .text: l.withText { TypeCommands.refresh(doc, &$0) }
        case .shape: l.withShape { VectorCommands.refreshShape(doc, &$0) }
        // Unavailable sources keep the warped cache.
        case .smart: _ = try? SmartCommands.refreshLayer(doc, &l, services: services)
        case .group: l.withChildren { cs in for i in cs.indices { refreshText(doc, &cs[i], services: services) } }
        default: break
        }
    }

    // MARK: The command

    static func quadParam(_ p: JSONValue, key: String = "quad") -> [SIMD2<Double>]? {
        guard let a = p[key]?.arrayValue, a.count == 4 else { return nil }
        var q: [SIMD2<Double>] = []
        for v in a {
            guard let c = v.arrayValue, c.count >= 2, let x = c[0].doubleValue, let y = c[1].doubleValue else { return nil }
            q.append(SIMD2(x, y))
        }
        return q
    }

    /// `p`, with the Channels panel's targeted alpha channel or Quick Mask as its `"target"` when
    /// it names neither a target nor a layer (#2835).
    static func withPanelTarget(_ s: Session, _ p: JSONValue) -> JSONValue {
        var p = p.objectValue != nil ? p : .object([:])
        if p["target"] == nil, p["layer"] == nil, let t = Channels.targetedChannel(s), t.objectValue != nil {
            p = p.merging(t)
        }
        return p
    }

    /// An affine `[a, b, c, d, e, f]` (x' = a·x + c·y + e, y' = b·x + d·y + f) as a homography.
    static func matrixHomography(_ v: [Double]) -> Homography { Homography([v[0], v[2], v[4], v[1], v[3], v[5], 0, 0, 1]) }

    static func transform(_ s: Session, _ p0: JSONValue) throws -> JSONValue {
        let p = withPanelTarget(s, p0)
        guard let st = s.active else { throw EngineError.noDocument }
        let id0: LayerId? = p["layer"]?.uint64Value.map { LayerId($0) } ?? st.activeLayer
        let lone = try loneTarget(st.doc, id0, p)
        let id: LayerId?
        if lone != nil && Channels.isChannelTarget(p) {
            id = nil
        } else if let i = id0 {
            id = i
        } else {
            throw EngineError.other("no active layer")
        }
        let rect: [Double]
        if let r = p["rect"]?.arrayValue, r.count == 4 {
            rect = r.map { $0.doubleValue ?? 0 }
        } else {
            let b: PixelRect
            if let surf = lone {
                b = targetBounds(st.doc, surf)
            } else if let id {
                guard let l = st.doc.layer(id) else { throw EngineError.noLayer(id) }
                b = transformBounds(st.doc, l)
            } else {
                b = .empty
            }
            if b.isEmpty { throw EngineError.other("nothing to transform") }
            rect = [Double(b.x0), Double(b.y0), Double(b.x1), Double(b.y1)]
        }
        let h: Homography
        if let q = quadParam(p) {
            guard let hh = Homography.rectToQuad(rect, q) else { throw bad("degenerate quad") }
            h = hh
        } else if let mv = p["matrix"]?.arrayValue {
            let v = mv.compactMap(\.doubleValue)
            guard v.count == 6 else { throw bad("matrix must be [a, b, c, d, e, f]") }
            h = matrixHomography(v)
        } else {
            throw bad("pass `quad` (where the rect's corners go) or `matrix`")
        }
        if h.inverse() == nil { throw bad("the transform collapses the layer") }
        let mm = h.m
        let affine: PCAffine? = abs(mm[6]) < 1e-12 && abs(mm[7]) < 1e-12
            ? PCAffine(a: mm[0] / mm[8], b: mm[3] / mm[8], c: mm[1] / mm[8], d: mm[4] / mm[8], e: mm[2] / mm[8], f: mm[5] / mm[8]) : nil
        let interp = Interp(parsing: p["interpolation"]?.stringValue ?? "bicubic")
        let isLone = lone != nil
        let services = s.services
        try s.edit("Free Transform") { doc, _ in
            let sel = doc.selection
            if isLone {
                // A targeted unlinked mask, alpha channel or Quick Mask transforms by itself.
                if !h.isIdentity {
                    try Channels.withTargetSurface(&doc, layer: id, p) { surf, _ in
                        surf = sel.map { warpGraySelected(surf, $0, h, interp) } ?? warpGray(surf, h, interp)
                    }
                    if let cur = doc.selection { doc.selection = nonEmpty(warpGray(cur, h, .bilinear)) }
                }
                return
            }
            guard let id else { throw EngineError.other("no active layer") }
            let isGroup = doc.layer(id)?.isGroup ?? false
            let group = groupLocks(doc, id)
            // Photoshop turns the Background into a normal layer before transforming it.
            LayerOps.backgroundToLayer(&doc, id)
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            try doc.updateLayer(id) { l in try transformLayer(isGroup ? nil : sel, group, &l, h, affine, interp) }
            if !h.isIdentity {
                // Type layers re-render from their new transform.
                let snapshot = doc
                doc.updateLayer(id) { l in refreshText(snapshot, &l, services: services) }
                // The selection outline moves with the pixels.
                if let cur = doc.selection { doc.selection = nonEmpty(warpGray(cur, h, .bilinear)) }
            }
        }
        return ["rect": .doubles(rect)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("edit.transform", "Free Transform",
                          params: #"{"layer":id?,"rect":[x0,y0,x1,y1]? (source frame; default = layer content ∩ selection),"quad":[[x,y]×4]? (where the frame's corners go, clockwise from top-left),"matrix":[a,b,c,d,e,f]? (affine alternative),"interpolation":"bicubic|bilinear|nearest"="bicubic","target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target (an unlinked mask, an alpha channel or the Quick Mask transforms alone; a linked mask moves with its layer)}"#,
                          module: m, enabled: hasLayer, run: transform))
    }
}
