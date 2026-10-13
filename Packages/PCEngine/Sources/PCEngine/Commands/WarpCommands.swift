// Port of photocraft-engine (crates/engine/src/warp_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Transform › Warp, Layer › Smart Objects › Warp and the split warps. A warp is PCDocument's
// `Warp` (a preset style with bend and distortions, or a custom bicubic Bezier mesh) over a source
// box in document space. Pixel layers are resampled once (PCAlgo's `MeshWarp`); type takes the
// style as its Warp Text and stays editable; shapes have their path bent; smart objects store the
// warp in their source space. The split and grid commands edit a mesh: one passed in (`"warp"`,
// returned edited — what the Free Transform warp UI uses) or the active smart object's stored
// warp (a history step).
//
// Smart objects: the warp is stored in source space and the object re-renders from its source
// (with the session's services); a source that can't be rendered keeps the cached pixels (and the
// filter mask) warped once.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

enum WarpCommands: CommandModule {
    static let name = "warp_cmds"
    static let m = name

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    static let hasLayer: CommandEnabled = TransformCommands.hasLayer

    /// photocraft `active_smart`.
    static let activeSmart: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document" }
        if let id = d.activeLayer, let l = d.doc.layer(id), case .smart = l.content { return nil }
        return "the active layer is not a smart object"
    }

    static func rectF(_ r: PixelRect) -> SIMD4<Double> { SIMD4(Double(r.x0), Double(r.y0), Double(r.x1), Double(r.y1)) }

    /// `p` through a projective map: a smart object's placement (affine, or Distort / Perspective).
    static func homApply(_ h: Homography, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let (x, y) = h.apply(p.x, p.y)
        return SIMD2(x, y)
    }

    /// The corners of box `b` (`[x0, y0, x1, y1]`), clockwise from top-left.
    static func corners(_ b: SIMD4<Double>) -> [SIMD2<Double>] {
        [SIMD2(b.x, b.y), SIMD2(b.z, b.y), SIMD2(b.z, b.w), SIMD2(b.x, b.w)]
    }

    /// Bounding box `[x0, y0, x1, y1]` of points (photocraft's `fold` of min / max).
    static func bbox(_ pts: [SIMD2<Double>]) -> SIMD4<Double> {
        pts.reduce(SIMD4(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)) { b, p in
            SIMD4(Swift.min(b.x, p.x), Swift.min(b.y, p.y), Swift.max(b.z, p.x), Swift.max(b.w, p.y))
        }
    }

    /// `w.map` as the resamplers take it (a preset prepared once rather than per point).
    static func mapper(_ w: Warp) -> @Sendable (Double, Double) -> (Double, Double) {
        if w.style.isPreset {
            guard let sw = w.styleWarp else { return { ($0, $1) } }
            return { x, y in
                let p = sw.apply(x, y)
                return (p.x, p.y)
            }
        }
        return { x, y in
            let p = w.map(x, y)
            return (p.x, p.y)
        }
    }

    /// The box a warp of `l` starts from (Free Transform's frame). For a warped smart object that
    /// is its (unwarped) source box, so re-warping replaces the warp over the same frame
    /// (photocraft `warp_bounds`).
    static func warpBounds(_ doc: Document, _ l: Layer) -> PixelRect {
        if case .smart(let sm) = l.content, let w = sm.warp {
            let t = TransformCommands.placement(sm)
            let b = bbox(corners(w.bounds).map { homApply(t, $0) })
            let i32 = TransformCommands.i32
            return PixelRect(x0: i32(b.x.rounded()), y0: i32(b.y.rounded()), x1: i32(b.z.rounded()), y1: i32(b.w.rounded()))
        }
        return TransformCommands.transformBounds(doc, l)
    }

    /// A smart object's stored warp expressed in document space (for editing), if it has one
    /// (photocraft `smart_warp_doc_space`).
    static func smartWarpDocSpace(_ l: Layer) -> Warp? {
        guard case .smart(let sm) = l.content, let w = sm.warp else { return nil }
        let t = TransformCommands.placement(sm)
        let mesh = w.toMesh(cols: 1, rows: 1).mapPoints { homApply(t, $0) }
        return Warp.custom(mesh, bounds: bbox(corners(w.bounds).map { homApply(t, $0) }))
    }

    /// Parses the warp params (photocraft `warp_from_params`; the shared parser lives with the
    /// vector commands, which bend paths with it).
    static func warpFromParams(_ cmd: String, _ p: JSONValue, _ rect: SIMD4<Double>) throws -> Warp {
        try VectorCommands.warpFromParams(cmd, p, rect)
    }

    /// Warps one layer. A Background is turned into a normal layer by the caller first
    /// (photocraft `warp_layer`).
    static func warpLayer(_ docSel: Surface?, _ group: Locks, _ l: inout Layer, _ w: Warp, _ rect: PixelRect, _ interp: Interp) throws {
        let locks = l.locks.union(group)
        if locks.position || locks.all { throw EngineError.other("layer \"\(l.name)\" is locked") }
        let map = mapper(w)
        switch l.content {
        case .group:
            try l.withChildren { cs in for i in cs.indices { try warpLayer(nil, locks, &cs[i], w, rect, interp) } }
        case .text:
            throw EngineError.other("Warp needs rasterized type (or use Type › Warp Text)")
        case .shape:
            // The path is warped and the shape stays a shape (#3009).
            try l.withShape { sh in try VectorCommands.mapShape(&sh, homography: nil, warp: w) }
        case .smart:
            try l.withSmartObject { sm in
                // Store in source space: undo the placement (affine, or Distort / Perspective)
                // around the warp.
                guard let inv = TransformCommands.placement(sm).inverse() else {
                    throw EngineError.other("the smart object's transform is degenerate")
                }
                let sb = bbox(corners(w.bounds).map { homApply(inv, $0) })
                let srcWarp: Warp?
                switch w.style {
                case .none:
                    srcWarp = nil
                case .custom:
                    srcWarp = Warp.custom(w.toMesh(cols: 1, rows: 1).mapPoints { homApply(inv, $0) }, bounds: sb)
                default:
                    var c = w
                    c.bounds = sb
                    c.mesh = nil
                    srcWarp = c
                }
                sm.warp = srcWarp.flatMap { $0.isIdentity ? nil : $0 }
                // Fallback appearance for sources that can't be re-rendered.
                if let c = sm.cache { sm.cache = MeshWarp.warpMeshSurface(c, srcRect: rect, map: map, interp: interp) }
                if var fm = sm.filterMask {
                    fm.surface = MeshWarp.warpMeshGray(fm.surface, map: map, interp: interp)
                    sm.filterMask = fm
                }
            }
        default:
            l.withRaster { surf in
                if let sel = docSel {
                    let parts = TransformCommands.splitSelected(surf, sel)
                    var rest = parts.rest
                    let moved = MeshWarp.warpMeshSurface(parts.lifted, srcRect: rect, map: map, interp: interp)
                    FloatCommands.compositeOver(&rest, moved)
                    rest.prune()
                    surf = rest
                } else {
                    // Content outside the warp box stays where it is.
                    let fmt = surf.format
                    let warped = MeshWarp.warpMeshSurface(surf, srcRect: rect, map: map, interp: interp)
                    var rest = surf.convertedAny(to: PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true))
                    Pixels.clearSurface(&rest, rect, selection: nil)
                    FloatCommands.compositeOver(&rest, warped)
                    rest.prune()
                    surf = rest
                }
            }
        }
        if var mk = l.mask, mk.linked {
            mk.surface = MeshWarp.warpMeshGray(mk.surface, map: map, interp: interp)
            l.mask = mk
        }
        if var vm = l.vectorMask, vm.linked {
            vm.path = try VectorCommands.mapPath(vm.path, homography: nil, warp: w)
            l.vectorMask = vm
        }
    }

    /// Largest warp frame side: far above any real layer, far below what would exhaust memory.
    static let maxWarpSide = 100_000

    static func target(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> (LayerId, PixelRect) {
        guard let st = s.active else { throw EngineError.noDocument }
        let id: LayerId
        if let v = p["layer"]?.uint64Value {
            id = LayerId(v)
        } else {
            guard let a = st.activeLayer else { throw EngineError.other("no active layer") }
            id = a
        }
        guard let layer = st.doc.layer(id) else { throw EngineError.noLayer(id) }
        let rect: PixelRect
        if let r = p["rect"]?.arrayValue, r.count == 4 {
            let v = r.map { TransformCommands.i32(($0.doubleValue ?? 0).rounded()) }
            rect = PixelRect(x0: v[0], y0: v[1], x1: v[2], y1: v[3])
        } else {
            rect = warpBounds(st.doc, layer)
        }
        if rect.isEmpty { throw bad(cmd, "nothing to warp") }
        let (w, h) = (rect.width, rect.height)
        if w > maxWarpSide || h > maxWarpSide {
            throw bad(cmd, "rect too large for warp: \(w) x \(h) (max \(maxWarpSide) per side)")
        }
        return (id, rect)
    }

    /// The Warp Text settings a transform warp gives a type layer: a preset style (or none) keeps
    /// the type editable, as Photoshop's Edit › Transform › Warp on type does (#3004).
    static func typeWarp(_ cmd: String, _ w: Warp) throws -> TextWarp? {
        func clamp(_ v: Double) -> Float { v.isFinite ? Float(Swift.min(Swift.max(v, -100), 100)) : 0 }
        switch w.style {
        case .none:
            return nil
        case .custom where w.isIdentity:
            return nil
        case .custom:
            throw bad(cmd, "type can only take a warp style (arc, flag, …); a custom mesh needs rasterized type")
        default:
            return TextWarp(style: w.style.psdName, value: clamp(w.bend), horizontalDistortion: clamp(w.hDistort),
                            verticalDistortion: clamp(w.vDistort), horizontal: !w.vertical)
        }
    }

    /// Warp on a type layer sets its Warp Text style: one history step, and the type stays
    /// editable (photocraft `warp_type_layer`).
    static func warpTypeLayer(_ s: Session, _ cmd: String, _ id: LayerId, _ w: Warp) throws -> JSONValue {
        let tw = try typeWarp(cmd, w)
        if let l = s.active?.doc.layer(id), case .text(let t) = l.content, t.warp == tw {
            return ["layer": .id(id), "changed": false]
        }
        try s.edit("Warp") { doc, _ in
            let group = TransformCommands.groupLocks(doc, id)
            let snapshot = doc
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            let locks = l.locks.union(group)
            if locks.position || locks.all { throw EngineError.other("layer \"\(l.name)\" is locked") }
            guard case .text = l.content else { throw EngineError.other("not a type layer") }
            doc.updateLayer(id) { l in
                l.withText { t in
                    t.warp = tw
                    TypeCommands.refresh(snapshot, &t)
                }
            }
        }
        return ["layer": .id(id), "changed": true, "warp": tw.map { .encoded($0) } ?? .null]
    }

    static func apply(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> JSONValue {
        let (id, rect) = try target(s, cmd, p)
        let w = try warpFromParams(cmd, p, rectF(rect))
        let content = s.active?.doc.layer(id)?.content
        if case .text? = content { return try warpTypeLayer(s, cmd, id, w) }
        var isSmart = false
        if case .smart? = content { isSmart = true }
        if w.isIdentity && !isSmart { return ["layer": .id(id), "changed": false] }
        let interp = Interp(parsing: p["interpolation"]?.stringValue ?? "bicubic")
        let services = s.services
        try s.edit("Warp") { doc, _ in
            let sel = doc.selection
            let isGroup = doc.layer(id)?.isGroup ?? false
            let group = TransformCommands.groupLocks(doc, id)
            LayerOps.backgroundToLayer(&doc, id)
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            try doc.updateLayer(id) { l in try warpLayer(isGroup ? nil : sel, group, &l, w, rect, interp) }
            let snapshot = doc
            doc.updateLayer(id) { l in TransformCommands.refreshText(snapshot, &l, services: services) }
            if let cur = doc.selection {
                doc.selection = TransformCommands.nonEmpty(MeshWarp.warpMeshGray(cur, map: mapper(w), interp: .bilinear))
            }
        }
        return ["layer": .id(id), "changed": true, "rect": [.int(Int(rect.x0)), .int(Int(rect.y0)), .int(Int(rect.x1)), .int(Int(rect.y1))]]
    }

    // MARK: Splits

    enum Split: Sendable { case crosswise, horizontal, vertical, remove }

    /// The default warp draws rule-of-thirds guides on its single patch. Make those real sections
    /// before a split, so the cut divides the grid on screen instead of replacing it.
    static func commitDefaultSections(_ mesh: inout BezierMesh) {
        _ = mesh.splitU(1.0 / 3.0)
        _ = mesh.splitU(2.0 / 3.0)
        _ = mesh.splitV(1.0 / 3.0)
        _ = mesh.splitV(2.0 / 3.0)
    }

    /// Applies a split (or removes the split nearest `at`) on `w`'s mesh (presets become custom)
    /// (photocraft `split_warp`).
    static func splitWarp(_ w: Warp, at: SIMD2<Double>?, _ how: Split) -> Warp? {
        var mesh = w.toMesh(cols: 1, rows: 1)
        guard mesh.isWellFormed else { return nil }
        if how != .remove && w.style == .custom && mesh.us.count == 2 && mesh.vs.count == 2 {
            commitDefaultSections(&mesh)
        }
        var s = 0.5, t = 0.5
        if let p = at {
            let st = mesh.paramAt(p)
            (s, t) = (st.x, st.y)
        }
        // Split inside the patch: the middle of the patch containing (s, t) when no point is given.
        func mid(_ k: [Double], _ v: Double) -> Double {
            let i = (0..<(k.count - 1)).first { v <= k[$0 + 1] } ?? (k.count - 2)
            return (k[i] + k[i + 1]) / 2
        }
        if at == nil { (s, t) = (mid(mesh.us, s), mid(mesh.vs, t)) }
        let ok: Bool
        switch how {
        case .crosswise:
            let a = mesh.splitU(s)
            let b = mesh.splitV(t)
            ok = a || b
        // A horizontal split line divides rows; a vertical one divides columns.
        case .horizontal:
            ok = mesh.splitV(t)
        case .vertical:
            ok = mesh.splitU(s)
        case .remove:
            func near(_ k: [Double], _ v: Double) -> Int? {
                k.count > 2 ? (1..<(k.count - 1)).min { abs(k[$0] - v) < abs(k[$1] - v) } : nil
            }
            let (iu, iv) = (near(mesh.us, s), near(mesh.vs, t))
            let du = iu.map { abs(mesh.us[$0] - s) } ?? Double.greatestFiniteMagnitude
            let dv = iv.map { abs(mesh.vs[$0] - t) } ?? Double.greatestFiniteMagnitude
            switch (iu, iv) {
            case (let i?, _) where du <= dv: ok = mesh.removeSplitU(i)
            case (_, let i?): ok = mesh.removeSplitV(i)
            case (let i?, nil): ok = mesh.removeSplitU(i)
            default: ok = false
            }
        }
        return ok ? Warp.custom(mesh, bounds: w.bounds) : nil
    }

    static func paramRect(_ p: JSONValue) -> SIMD4<Double> {
        guard let r = p["rect"]?.arrayValue else { return SIMD4(0, 0, 1, 1) }
        func at(_ i: Int, _ d: Double) -> Double { i < r.count ? r[i].doubleValue ?? d : d }
        return SIMD4(at(0, 0), at(1, 0), at(2, 1), at(3, 1))
    }

    /// A warp passed inline (`warp`, `mesh` or `style`). nil means "use the active smart object".
    static func inlineWarp(_ cmd: String, _ p: JSONValue) throws -> Warp? {
        if p["warp"] == nil && p["mesh"] == nil && p["style"] == nil { return nil }
        return try warpFromParams(cmd, p, paramRect(p))
    }

    /// The active smart object's stored warp, or none over its pixels in source space.
    static func storedWarp(_ layer: Layer, _ sm: SmartObject) -> Warp {
        if let w = sm.warp { return w }
        let b = layer.surface?.contentBounds ?? .empty
        // The layer's pixels back in source space, through the full placement (affine, or
        // Distort / Perspective).
        let c = corners(rectF(b))
        let back = TransformCommands.placement(sm).inverse().map { inv in c.map { homApply(inv, $0) } } ?? c
        return Warp.none(bbox(back))
    }

    static func split(_ s: Session, _ p: JSONValue, _ cmd: String, _ how: Split) throws -> JSONValue {
        var at: SIMD2<Double>?
        if let a = p["at"]?.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue { at = SIMD2(x, y) }
        if let w = try inlineWarp(cmd, p) {
            guard let out = splitWarp(w, at: at, how) else { throw bad(cmd, "nothing to split or remove there") }
            return ["warp": .encoded(out)]
        }
        // The active smart object's stored warp.
        guard let st = s.active else { throw EngineError.noDocument }
        guard let id = st.activeLayer else { throw EngineError.other("no active layer") }
        guard let layer = st.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .smart(let sm) = layer.content else {
            throw bad(cmd, "pass the warp being edited (`warp`), or select a warped smart object")
        }
        let w: Warp
        if let stored = sm.warp {
            w = stored
        } else {
            // The box spanned by the content's top-left and bottom-right corners in source space.
            let b = layer.surface?.contentBounds ?? .empty
            let inv = TransformCommands.placement(sm).inverse() ?? .identity
            let c0 = homApply(inv, SIMD2(Double(b.x0), Double(b.y0))), c1 = homApply(inv, SIMD2(Double(b.x1), Double(b.y1)))
            w = Warp.none(SIMD4(Swift.min(c0.x, c1.x), Swift.min(c0.y, c1.y), Swift.max(c0.x, c1.x), Swift.max(c0.y, c1.y)))
        }
        let t = TransformCommands.placement(sm)
        let atSrc = at.flatMap { a in t.inverse().map { homApply($0, a) } }
        guard let out = splitWarp(w, at: atSrc, how) else { throw bad(cmd, "nothing to split or remove there") }
        let services = s.services
        try s.edit(how == .remove ? "Remove Warp Split" : "Split Warp") { doc, _ in
            doc.updateLayer(id) { l in l.withSmartObject { $0.warp = out } }
            try TransformCommands.refreshSmart(&doc, id, services: services)
        }
        return ["layer": .id(id), "warp": .encoded(out)]
    }

    // MARK: Grid

    /// Square preset size. `"default"` is 1. Numbers outside 1...64 are rejected, not clamped.
    static func gridSize(_ cmd: String, _ p: JSONValue) throws -> Int {
        guard let v = p["size"] ?? p["grid"] else { throw bad(cmd, #"pass `size` (1, 3, 4, 5 or "default")"#) }
        if v.arrayValue != nil { throw bad(cmd, #"pass `size` as a number or "default", "3", "4" or "5""#) }
        let n: UInt64
        switch v {
        case .string(let s):
            switch s {
            case "default": n = 1
            case "3", "3x3": n = 3
            case "4", "4x4": n = 4
            case "5", "5x5": n = 5
            default: throw bad(cmd, "grid size must be default, 3, 4 or 5")
            }
        case .number:
            guard let u = v.uint64Value else { throw bad(cmd, "grid size must be a whole number from 1 to 64") }
            n = u
        default:
            throw bad(cmd, "grid size must be a number or default, 3, 4 or 5")
        }
        if !(1...64).contains(n) { throw bad(cmd, "grid size must be from 1 to 64") }
        return Int(n)
    }

    /// Even `n`×`n` patches fitted to `w`. The surface stays; knots sit at `i/n`.
    static func resizeWarp(_ w: Warp, _ n: Int) -> Warp {
        let mesh = w.toMesh(cols: 1, rows: 1)
        let knots = (0...n).map { Double($0) / Double(n) }
        return Warp.custom(BezierMesh.fit({ s, t in mesh.eval(s, t) }, us: knots, vs: knots), bounds: w.bounds)
    }

    static func grid(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.transform.warpGrid"
        let n = try gridSize(cmd, p)
        if let w = try inlineWarp(cmd, p) {
            guard w.toMesh(cols: 1, rows: 1).isWellFormed else { throw bad(cmd, "malformed warp mesh") }
            return ["warp": .encoded(resizeWarp(w, n))]
        }
        guard let st = s.active else { throw EngineError.noDocument }
        guard let id = st.activeLayer else { throw EngineError.other("no active layer") }
        guard let layer = st.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .smart(let sm) = layer.content else {
            throw bad(cmd, "pass the warp being edited (`warp`), or select a smart object")
        }
        let out = resizeWarp(storedWarp(layer, sm), n)
        let services = s.services
        try s.edit("Warp Grid") { doc, _ in
            doc.updateLayer(id) { l in l.withSmartObject { $0.warp = out } }
            try TransformCommands.refreshSmart(&doc, id, services: services)
        }
        return ["layer": .id(id), "warp": .encoded(out)]
    }

    // MARK: Registry

    static let warpParams = #"{"layer":id?,"rect":[x0,y0,x1,y1]? (warp box; default = layer content ∩ selection),"style":"custom|none|arc|arcLower|arcUpper|arch|bulge|shellLower|shellUpper|flag|wave|fish|rise|fisheye|inflate|squeeze|twist","bend":%=50,"hDistort":%,"vDistort":%,"vertical":bool,"mesh":{"us":[0,…,1],"vs":[0,…,1],"points":[[x,y]…]} ((3c+1)×(3r+1) control points, row-major, document px),"grid":[cols,rows]?,"warp":{full warp object}?,"interpolation":"bicubic|bilinear|nearest"} — on a type layer a style (or none) sets its Warp Text and the type stays editable"#
    static let splitParams = #"{"warp":{…}? (the warp being edited; returned split),"rect":[x0,y0,x1,y1]?,"at":[x,y]? (document point; default = middle of the patch)} — without `warp`, edits the active smart object's warp. A 1×1 custom mesh is divided at the thirds first (the guides drawn on the default grid), so splitWarpCrosswise on an identity custom warp returns a 4×4 mesh (knots at 0, 1/3, 1/2, 2/3 and 1), not a 2×2. A preset is fitted as one patch and split without that step."#
    static let gridParams = #"{"warp":{…}? (the warp being edited; returned with the new mesh),"rect":[x0,y0,x1,y1]?,"size":n|"default"|"3"|"4"|"5" (square patches, 1..=64; 1 and "default" are the single-patch grid)} — without `warp`/`style`/`mesh`, edits the active smart object's warp. The surface is kept and the new lines are real splits at i/n."#

    static func register(into r: inout CommandRegistry) {
        let tr = ["Edit", "Transform"]
        r.add(CommandSpec("edit.transform.warp", "Warp", menu: tr, params: warpParams, module: m, enabled: hasLayer) { s, p in
            try apply(s, p, "edit.transform.warp")
        })
        r.add(CommandSpec("layer.smartObjects.warp", "Warp", menu: ["Layer", "Smart Objects"], params: warpParams, module: m, enabled: activeSmart) { s, p in
            try apply(s, p, "layer.smartObjects.warp")
        })
        for (id, label, how) in [("edit.transform.splitWarpCrosswise", "Split Warp Crosswise", Split.crosswise),
                                 ("edit.transform.splitWarpHorizontally", "Split Warp Horizontally", .horizontal),
                                 ("edit.transform.splitWarpVertically", "Split Warp Vertically", .vertical),
                                 ("edit.transform.removeWarpSplit", "Remove Warp Split", .remove)] {
            r.add(CommandSpec(id, label, menu: tr, params: splitParams, module: m, enabled: hasLayer) { s, p in try split(s, p, id, how) })
        }
        r.add(CommandSpec("edit.transform.warpGrid", "Warp Grid", params: gridParams, module: m, enabled: hasLayer) { s, p in try grid(s, p) })
    }
}
