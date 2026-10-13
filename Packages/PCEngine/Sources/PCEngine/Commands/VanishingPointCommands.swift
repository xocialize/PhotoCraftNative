// Port of photocraft-engine (crates/engine/src/vp_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Vanishing Point: perspective planes (drawn, or torn off an edge of another plane),
// pasting an image onto a plane and the perspective clone stamp, as one replayable command
// (PCAlgo `VanishingPoint`). The edit lands on the active pixel layer, or on a new layer with
// `"newLayer": true` (Photoshop's advice for non-destructive Vanishing Point work).

import PCAlgo
import PCDocument
import PCFoundation

enum VanishingPointCommands: CommandModule {
    static let name = "vp_cmds"

    static let vp = "filter.vanishingPoint"

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    static func bad(_ msg: String) -> EngineError { .bad(vp, msg) }

    static func pt(_ v: JSONValue?) -> SIMD2<Double>? {
        guard let a = v?.arrayValue, a.count >= 2, case .number(let x) = a[0], case .number(let y) = a[1] else { return nil }
        return SIMD2(x, y)
    }

    /// Builds the scene from `"planes"` (photocraft `scene`).
    static func scene(_ p: JSONValue, canvas: PixelRect) throws -> VanishingPoint.Scene {
        guard let planes = p["planes"]?.arrayValue, !planes.isEmpty else {
            throw bad(#"pass `planes`: [{"corners":[[x,y]×4]}, {"from":0,"edge":"top","angle":90}]"#)
        }
        let center = SIMD2(Double(canvas.x0 + canvas.x1) / 2, Double(canvas.y0 + canvas.y1) / 2)
        func corners(_ v: JSONValue) -> [SIMD2<Double>]? {
            guard let a = v["corners"]?.arrayValue, a.count >= 4 else { return nil }
            var out: [SIMD2<Double>] = []
            for k in 0..<4 {
                guard let q = pt(a[k]) else { return nil }
                out.append(q)
            }
            return out
        }
        // A drawn quad must be convex (Photoshop's red plane): a bow-tie or dented quad has no
        // perspective to paste or clone along.
        func drawn(_ i: Int, _ c: [SIMD2<Double>]) throws -> VpPlane {
            let pl = VpPlane(corners: c)
            if pl.check(center) == .invalid { throw bad("plane \(i): the four corners must form a convex quad") }
            return pl
        }
        guard let c0 = corners(planes[0]) else { throw bad("the first plane needs four `corners`") }
        let first = try drawn(0, c0)
        let focal = p["focalLength"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
        var sc = VanishingPoint.Scene(first: first, center: center, focal: focal, fallback: Double(max(canvas.width, canvas.height)))
        for (i, pl) in planes.enumerated().dropFirst() {
            if let c = corners(pl) {
                sc.planes.append(try drawn(i, c))
                continue
            }
            guard let f = pl["from"]?.uint64Value, f < UInt64(sc.planes.count) else {
                throw bad("plane \(i): `corners` or `from` (an earlier plane)")
            }
            let edge: VanishingPoint.Edge
            switch pl["edge"]?.stringValue ?? "top" {
            case "top": edge = .top
            case "right": edge = .right
            case "bottom": edge = .bottom
            case "left": edge = .left
            case let e: throw bad("plane \(i): unknown edge `\(e)`")
            }
            let angle = pl["angle"]?.doubleValue ?? 90
            let depth = pl["depth"]?.doubleValue ?? 1
            if sc.tearOff(from: Int(f), edge: edge, angle: angle, depth: depth) == nil { throw bad("plane \(i) would lie behind the camera") }
        }
        if sc.planes.contains(where: { $0.homography() == nil }) { throw bad("a plane is degenerate") }
        return sc
    }

    static let hasLayer: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return "no active layer" }
        if case .raster = l.content { return nil }
        return "Vanishing Point needs a pixel layer (active layer is \(l.content.article) \(l.content.kindName) layer)"
    }

    /// Composites `top` over `dst` (premultiplied source-over), same format (photocraft `over`).
    static func over(_ dst: inout Surface, _ top0: Surface) {
        let b = top0.contentBounds
        if b.isEmpty { return }
        let fmt = dst.format
        let top = top0.format == fmt ? top0 : top0.convertedAny(to: fmt)
        let n = fmt.channels
        let t = top.readRegion(b)
        var d = dst.readRegion(b)
        var i = 0
        while i + n <= t.count && i + n <= d.count {
            if !fmt.alpha {
                for c in 0..<n { d[i + c] = t[i + c] }
            } else {
                let ta = t[i + n - 1], da = d[i + n - 1]
                let oa = ta + da * (1 - ta)
                for c in 0..<(n - 1) { d[i + c] = oa > 0 ? (t[i + c] * ta + d[i + c] * da * (1 - ta)) / oa : 0 }
                d[i + n - 1] = oa
            }
            i += n
        }
        dst.writeRegion(b, d)
    }

    /// A paste item resolved up front: plane, source pixels, their bounds, top-left and width.
    struct Paste {
        var plane: Int
        var surface: Surface
        var rect: PixelRect
        var at: SIMD2<Double>
        var width: Double
    }

    static func vanishingPoint(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let canvas = st.doc.bounds
        let sc = try scene(p, canvas: canvas)
        // Paste sources resolved up front (layer pixels or the clipboard).
        var pastes: [Paste] = []
        for (k, item) in (p["paste"]?.arrayValue ?? []).enumerated() {
            let plane = Int(clamping: item["plane"]?.uint64Value ?? 0)
            if plane >= sc.planes.count { throw bad("paste \(k): no plane \(plane)") }
            let surf: Surface
            if let l = item["layer"]?.uint64Value {
                guard let sf = st.doc.layer(LayerId(l))?.surface else { throw EngineError.noLayer(LayerId(l)) }
                surf = sf
            } else {
                guard let clip = EditCommands.clipboard(s) else { throw bad("paste \(k): nothing on the clipboard (or pass `layer`)") }
                surf = clip.surface
            }
            let at = pt(item["at"]) ?? SIMD2(0.25, 0.25)
            let width = min(max(item["width"]?.doubleValue ?? 0.5, 0.01), 10)
            pastes.append(Paste(plane: plane, surface: surf, rect: surf.contentBounds, at: at, width: width))
        }
        let clones = p["clone"]?.arrayValue ?? []
        let newLayer = p["newLayer"]?.boolValue ?? false
        let renderer = s.services.renderer
        let (target, dabs) = try s.edit("Vanishing Point") { doc, active -> (LayerId, Int) in
            let id: LayerId
            if newLayer {
                let nid = doc.insertAbove(active, Layer.raster(doc.nextLayerName("Vanishing Point"), format: doc.pixelFormat))
                active = nid
                id = nid
            } else {
                guard let a = active else { throw EngineError.other("no active layer") }
                id = a
            }
            // A new layer clones from the visible image; otherwise from the layer itself.
            var base: Surface?
            if newLayer { base = try renderer.compositeToSurface(doc, rect: doc.bounds, format: doc.pixelFormat) }
            let locks = doc.effectiveLocks(id)
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if locks.all || locks.pixels { throw EngineError.other("layer \"\(l.name)\" is locked") }
            var dabs = 0
            let done: Void? = try doc.withRaster(of: id) { surf in
                for ps in pastes {
                    if let out = VanishingPoint.paste(sc, plane: ps.plane, ps.surface, srcRect: ps.rect, at: ps.at, width: ps.width) {
                        over(&surf, out)
                    }
                }
                for (k, c) in clones.enumerated() {
                    guard let source = pt(c["source"]) else { throw bad("clone \(k): `source` [x,y]") }
                    let points = (c["points"]?.arrayValue ?? []).compactMap { pt($0) }
                    let size = min(max(c["size"]?.doubleValue ?? 40, 1), 2000)
                    let hardness = min(max(c["hardness"]?.doubleValue ?? 50, 0), 100) / 100
                    let opacity = Float(min(max(c["opacity"]?.doubleValue ?? 100, 0), 100) / 100)
                    // Sample from the original pixels (merged with what's been pasted).
                    var work: Surface
                    if let base {
                        work = base
                        over(&work, surf)
                    } else {
                        work = surf
                    }
                    let before = work
                    dabs += VanishingPoint.cloneStroke(sc, &work, source: source, points: points, size: size, hardness: hardness, opacity: opacity)
                    // Copy back only what the stroke changed.
                    let b = work.contentBounds.union(before.contentBounds)
                    if !b.isEmpty {
                        let nw = work.readRegion(b), ow = before.readRegion(b)
                        let n = surf.format.channels
                        var cur = surf.readRegion(b)
                        if nw.count == cur.count && ow.count == cur.count && work.format.channels == n {
                            var i = 0
                            while i + n <= cur.count {
                                if nw[i..<i + n] != ow[i..<i + n] { for j in i..<i + n { cur[j] = nw[j] } }
                                i += n
                            }
                            surf.writeRegion(b, cur)
                        }
                    }
                }
                surf.prune()
            }
            if done == nil { throw EngineError.other("Vanishing Point needs a pixel layer") }
            return (id, dabs)
        }
        let planes: [JSONValue] = sc.planes.indices.map { i in
            let (lu, lv) = sc.lifted(i).lengths()
            return ["corners": .array(sc.planes[i].corners.map { JSONValue.array([.number($0.x), .number($0.y)]) }), "aspect": .number(lu / lv)]
        }
        return ["layer": .id(target), "focal": .number(sc.focal), "planes": .array(planes), "pasted": .int(pastes.count), "dabs": .int(dabs)]
    }

    static func specs() -> [CommandSpec] {
        [
            CommandSpec(vp, "Vanishing Point…", menu: ["Filter"], shortcut: "Cmd+Alt+V",
                        params: ##"{"planes":[{"corners":[[x,y]×4]} | {"from":plane,"edge":"top|right|bottom|left","angle":deg=90,"depth":1}],"focalLength":px=0,"paste":[{"plane":0,"layer":id? (else the clipboard),"at":[u,v]=[0.25,0.25],"width":0..1=0.5}],"clone":[{"source":[x,y],"points":[[x,y]],"size":px=40,"hardness":0..100=50,"opacity":0..100=100}],"newLayer":bool=false}"##,
                        module: name, enabled: hasLayer, run: vanishingPoint),
        ]
    }
}
