// Port of photocraft-engine (crates/engine/src/distort_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Liquify, Edit › Puppet Warp and Edit › Perspective Warp (plus their Layer › Smart
// Objects twins). Each takes its whole edit as data, so it is one replayable command and one
// history step: Liquify the brush strokes (replayed onto a fresh displacement field, PCAlgo's
// `Liquify`), Puppet Warp the pins (PCAlgo's `Puppet`, as-rigid-as-possible on a mesh of the
// opaque region), Perspective Warp the planes (PCAlgo's `PerspectiveMap` through `MeshWarp`). On
// a smart object each becomes a smart filter, recorded with its params; `applyToSurface` is the
// smart-filter re-render hook: `FilterCommands.addSmartFilter` re-renders the object from its
// source with the session's services (or, for a source it can't render, runs the filter on the
// cached pixels), and records it.

import Foundation
import PCAlgo
import PCDocument
import PCFoundation

enum DistortCommands: CommandModule {
    static let name = "distort_cmds"
    static let m = name

    static let liquifyId = "filter.liquify"
    static let puppetId = "edit.puppetWarp"
    static let puppetSmartId = "layer.smartObjects.puppetWarp"
    static let perspectiveId = "edit.perspectiveWarp"
    static let perspectiveSmartId = "layer.smartObjects.perspectiveWarp"

    typealias Plane = PerspectiveMap.Plane

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// A params shape error (photocraft's serde message).
    struct ShapeError: Error, CustomStringConvertible { var description: String }

    // MARK: Params

    /// Liquify params: the strokes and the field resolution (`meshSize`, px per field node).
    static func liquifyParams(_ cmd: String, _ p: JSONValue, _ canvas: PixelRect) throws -> ([LiquifyStroke], Double) {
        var strokes: [LiquifyStroke] = []
        if let v = p["strokes"] {
            do { strokes = try v.decode(as: [LiquifyStroke].self) } catch { throw bad(cmd, "bad `strokes`: \(error)") }
        }
        for s in strokes {
            do { try s.validate() } catch FilterError.invalidInput(let msg) { throw bad(cmd, msg) } catch { throw bad(cmd, "\(error)") }
        }
        let cell: Double
        switch p["meshSize"] {
        case nil, .null?:
            cell = Liquify.autoCell(canvas)
        case let v?:
            guard let c = v.doubleValue else { throw bad(cmd, "`meshSize` is px per field node (1..64)") }
            guard (1.0...64.0).contains(c) else { throw bad(cmd, "`meshSize` must be 1..64") }
            cell = c
        }
        return (strokes, cell)
    }

    /// Puppet Warp params.
    static func puppetParams(_ cmd: String, _ p: JSONValue) throws -> PuppetWarp {
        var pins: [PuppetPin] = []
        if let v = p["pins"] {
            do { pins = try v.decode(as: [PuppetPin].self) } catch {
                throw bad(cmd, #"bad `pins` (each {"src":[x,y],"dst":[x,y],"rotate":deg?,"depth":n?}): "# + "\(error)")
            }
        }
        if pins.contains(where: { q in
            ![q.src.x, q.src.y, q.dst.x, q.dst.y].allSatisfy(\.isFinite) || (q.rotate.map { !$0.isFinite } ?? false)
        }) {
            throw bad(cmd, "pin coordinates must be finite")
        }
        var mode = PuppetMode.normal
        if let s = p["mode"]?.stringValue {
            guard let pm = PuppetMode(parsing: s) else { throw bad(cmd, "unknown mode \"\(s)\" (rigid|normal|distort)") }
            mode = pm
        }
        var density = PuppetDensity.normal
        if let s = p["density"]?.stringValue {
            guard let d = PuppetDensity(parsing: s) else { throw bad(cmd, "unknown density \"\(s)\" (fewer|normal|more)") }
            density = d
        }
        let expansion = p["expansion"]?.doubleValue ?? 2
        if !expansion.isFinite || abs(expansion) > 200 { throw bad(cmd, "`expansion` must be -200..200 px") }
        return PuppetWarp(pins: pins, mode: mode, density: density, expansion: expansion)
    }

    /// Four `[x, y]` corners (photocraft's `[[f64; 2]; 4]`).
    static func corners4(_ v: JSONValue?, _ key: String) throws -> [SIMD2<Double>] {
        guard let a = v?.arrayValue else { throw ShapeError(description: "`\(key)` must be an array of 4 [x, y] points") }
        guard a.count == 4 else { throw ShapeError(description: "invalid length \(a.count), expected an array of length 4") }
        return try a.map { c in
            guard let xy = c.arrayValue, xy.count == 2, let x = xy[0].doubleValue, let y = xy[1].doubleValue else {
                throw ShapeError(description: "each corner of `\(key)` must be [x, y]")
            }
            return SIMD2(x, y)
        }
    }

    static func parsePlanes(_ v: JSONValue) throws -> [Plane] {
        guard let a = v.arrayValue else { throw ShapeError(description: "expected an array of planes") }
        return try a.map { pv in
            guard pv.objectValue != nil else { throw ShapeError(description: "each plane must be an object") }
            return Plane(src: try corners4(pv["src"], "src"), dst: try corners4(pv["dst"], "dst"))
        }
    }

    /// Perspective Warp params (planes, after the optional straighten).
    static func perspectiveParams(_ cmd: String, _ p: JSONValue) throws -> [Plane] {
        guard let v = p["planes"] else { throw bad(cmd, #"pass `planes`: [{"src":[[x,y]×4],"dst":[[x,y]×4]}]"#) }
        var planes: [Plane]
        do { planes = try parsePlanes(v) } catch {
            throw bad(cmd, #"bad `planes` (each {"src":[4×[x,y]],"dst":[4×[x,y]]}): "# + "\(error)")
        }
        if planes.isEmpty { throw bad(cmd, "`planes` is empty") }
        if planes.contains(where: { ($0.src + $0.dst).contains { !$0.x.isFinite || !$0.y.isFinite } }) {
            throw bad(cmd, "plane corners must be finite")
        }
        if let s = p["straighten"]?.stringValue {
            guard let mode = PerspectiveMap.Straighten(parsing: s) else {
                throw bad(cmd, "unknown straighten \"\(s)\" (horizontal|vertical|auto)")
            }
            PerspectiveMap.straighten(&planes, mode: mode)
        }
        if PerspectiveMap(planes: planes) == nil { throw bad(cmd, "a plane is degenerate (its corners must form a quad)") }
        return planes
    }

    static func interp(_ p: JSONValue) -> Interp { Interp(parsing: p["interpolation"]?.stringValue ?? "bicubic") }

    // MARK: Pixel operations

    /// Mixes `new` over `old` by the selection's coverage (premultiplied when there is alpha).
    static func mixBySelection(_ old: Surface, _ new: Surface, _ sel: Surface) -> Surface {
        let fmt = old.format
        let newer = new.format == fmt ? new : new.convertedAny(to: fmt)
        let area = old.contentBounds.union(newer.contentBounds)
        var out = newer
        if area.isEmpty { return out }
        let n = fmt.channels
        let o = old.readRegion(area), w = newer.readRegion(area)
        let cov = sel.coverage(area)
        var r = [Float](repeating: 0, count: o.count)
        for i in 0..<area.area {
            let k = Swift.min(Swift.max(i < cov.count ? cov[i] : 0, 0), 1)
            let b = i * n
            if !fmt.alpha {
                for c in 0..<n { r[b + c] = o[b + c] + (w[b + c] - o[b + c]) * k }
                continue
            }
            let a = n - 1
            let oa = o[b + a] + (w[b + a] - o[b + a]) * k
            r[b + a] = oa
            for c in 0..<a {
                let pm = o[b + c] * o[b + a] + (w[b + c] * w[b + a] - o[b + c] * o[b + a]) * k
                r[b + c] = oa > 0 ? Swift.min(Swift.max(pm / oa, 0), 1) : 0
            }
        }
        out.writeRegion(area, r)
        out.prune()
        return out
    }

    /// Liquifies a surface over `canvas` (the field's extent).
    static func liquifySurface(_ surf: Surface, _ strokes: [LiquifyStroke], _ cell: Double, _ canvas: PixelRect) -> Surface {
        Liquify.apply(surf, field: LiquifyField.fromStrokes(bounds: canvas, cell: cell, strokes: strokes))
    }

    /// Puppet-warps a surface's content; nil when the result would span more than
    /// `Puppet.maxWarpPixels`.
    static func puppetSurface(_ surf: Surface, _ w: PuppetWarp, _ interp: Interp) -> Surface? {
        let b = surf.contentBounds
        if w.isIdentity || b.isEmpty { return surf }
        return Puppet.warp(surf, bounds: b, w, interp: interp)
    }

    /// Perspective-warps a surface's content.
    static func perspectiveSurface(_ surf: Surface, _ planes: [Plane], _ interp: Interp) -> Surface {
        let b = surf.contentBounds
        if PerspectiveMap.isIdentity(planes) || b.isEmpty { return surf }
        guard let pm = PerspectiveMap(planes: planes) else { return surf }
        return MeshWarp.warpMeshSurface(surf, srcRect: b, map: { pm.map($0, $1) }, interp: interp)
    }

    /// photocraft `distort_cmds::apply_to_surface`: Liquify / Puppet / Perspective Warp smart
    /// filters re-applied to a rendered smart object (nil for other ids).
    static func applyToSurface(_ id: String, _ p: JSONValue, _ surf: Surface, canvas: PixelRect) -> Surface? {
        switch id {
        case liquifyId:
            guard let lp = try? liquifyParams(id, p, canvas) else { return nil }
            return liquifySurface(surf, lp.0, lp.1, canvas)
        case puppetId, puppetSmartId:
            // A stored warp too far to render leaves the smart object as it is (#1019).
            guard let w = try? puppetParams(id, p) else { return nil }
            return puppetSurface(surf, w, interp(p)) ?? surf
        case perspectiveId, perspectiveSmartId:
            guard let planes = try? perspectiveParams(id, p) else { return nil }
            return perspectiveSurface(surf, planes, interp(p))
        default:
            return nil
        }
    }

    // MARK: Commands

    static func target(_ s: Session, _ p: JSONValue) throws -> LayerId {
        if let v = p["layer"]?.uint64Value { return LayerId(v) }
        guard let id = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    static func isSmart(_ s: Session, _ id: LayerId) -> Bool {
        if let l = s.active?.doc.layer(id), case .smart = l.content { return true }
        return false
    }

    /// photocraft `pixel_layer`.
    static let pixelLayer: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer else { return "no active layer" }
        guard let l = d.doc.layer(id) else { return "no active layer" }
        switch l.content {
        case .raster: return nil
        case .smart(let sm) where sm.cache != nil: return nil
        default: return "needs a pixel layer or smart object (active layer is \(l.content.article) \(l.content.kindName) layer)"
        }
    }

    /// photocraft `smart_layer`.
    static let smartLayer: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        if let id = d.activeLayer, let l = d.doc.layer(id), case .smart = l.content { return nil }
        return "the active layer is not a smart object"
    }

    static func checkLocks(_ l: Layer, _ group: Locks, _ position: Bool) throws {
        let locks = l.locks.union(group)
        if locks.all || locks.pixels || (position && locks.position) { throw EngineError.other("layer \"\(l.name)\" is locked") }
    }

    /// Deforms a layer's pixels (with the selection and canvas); a throw leaves the layer as it was.
    typealias LayerFn = (Surface, Surface?, PixelRect) throws -> Surface
    /// Deforms a linked layer mask the same way, limited to the selection when there is one.
    typealias MaskFn = (Surface, Surface?) throws -> Surface

    /// Shared driver: a smart object records `cmd` as a smart filter; a pixel layer is edited in
    /// place by `f(surface, selection, canvas)` (photocraft `run_on_layer`).
    static func runOnLayer(_ s: Session, _ cmd: String, _ label: String, _ p: JSONValue, moves: Bool, _ f: LayerFn,
                           mask: MaskFn? = nil) throws -> JSONValue {
        let id = try target(s, p)
        let params = p.objectValue != nil ? p.removing("layer") : p
        let services = s.services
        try s.edit(label) { doc, _ in
            let canvas = doc.bounds
            let selection = doc.selection
            let group = TransformCommands.groupLocks(doc, id)
            // A Background gains transparency when the distortion moves pixels (as in Photoshop).
            if moves { LayerOps.backgroundToLayer(&doc, id) }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if case .smart = l.content {
                let sf = SmartFilter(command: cmd, params: params, blend: .normal, opacity: 1, visible: true)
                try FilterCommands.addSmartFilter(&doc, id, sf, selection: selection, services: services)
                return
            }
            try checkLocks(l, group, moves)
            guard case .raster(let surf) = l.content else { throw EngineError.other("\(label) needs a pixel layer (rasterize it first)") }
            let out = try f(surf, selection, canvas)
            // A linked layer mask follows a geometric warp, only where the pixels moved (#3083).
            var newMask: Surface?
            if let mf = mask, let mk = l.mask, mk.linked { newMask = try mf(mk.surface, selection) }
            doc.updateLayer(id) { l in
                l.content = .raster(out)
                if let nm = newMask { l.mask?.surface = nm }
            }
        }
        return ["layer": .id(id), "changed": true]
    }

    static func liquify(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        let (strokes, cell) = try liquifyParams(liquifyId, p, canvas)
        let id = try target(s, p)
        if strokes.isEmpty { return ["layer": .id(id), "changed": false] }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let field = LiquifyField.fromStrokes(bounds: canvas, cell: cell, strokes: strokes)
        if field.isIdentity && !isSmart(s, id) { return ["layer": .id(id), "changed": false] }
        let r = try runOnLayer(s, liquifyId, "Liquify", p, moves: false) { surf, sel, _ in
            let out = Liquify.apply(surf, field: field)
            return sel.map { mixBySelection(surf, out, $0) } ?? out
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
        return r.setting("ms", .number(ms)).setting("maxDisplacement", .float(field.maxDisplacement))
    }

    /// Lifts the selected pixels (when there is a selection), deforms them with `f` and puts them
    /// back over the rest; without a selection deforms the whole surface.
    static func deformSelected(_ surf: Surface, _ sel: Surface?, _ f: (Surface) throws -> Surface) rethrows -> Surface {
        if let sel {
            let parts = TransformCommands.splitSelected(surf, sel)
            var rest = parts.rest
            let moved = try f(parts.lifted)
            FloatCommands.compositeOver(&rest, moved)
            rest.prune()
            return rest
        }
        let fmt = surf.format
        return try f(fmt.alpha ? surf : surf.convertedAny(to: PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true)))
    }

    static func puppet(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> JSONValue {
        let w = try puppetParams(cmd, p)
        let id = try target(s, p)
        if w.isIdentity && !isSmart(s, id) { return ["layer": .id(id), "changed": false] }
        let it = interp(p)
        return try runOnLayer(s, cmd, "Puppet Warp", p, moves: true) { surf, sel, _ in
            try deformSelected(surf, sel) { x in
                guard let out = puppetSurface(x, w, it) else {
                    throw bad(cmd, "the pins stretch the content too far: the result would cover more than 2^30 pixels")
                }
                return out
            }
        }
    }

    static func perspective(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> JSONValue {
        let planes = try perspectiveParams(cmd, p)
        let id = try target(s, p)
        if PerspectiveMap.isIdentity(planes) && !isSmart(s, id) {
            return ["layer": .id(id), "changed": false, "planes": .encoded(planes)]
        }
        let it = interp(p)
        let pm = PerspectiveMap(planes: planes)
        let maskFn: MaskFn = { mk, sel in
            guard let pm else { return mk }
            let f: (Double, Double) -> (Double, Double) = { pm.map($0, $1) }
            let whole: (Surface) -> Surface = { MeshWarp.warpMeshGray($0, map: f, interp: .bilinear) }
            guard let sel else { return whole(mk) }
            return TransformCommands.moveGraySelected(mk, sel, warp: { lifted, src in
                MeshWarp.warpMeshSurface(lifted, srcRect: src, map: f, interp: .bilinear)
            }, whole: whole)
        }
        let r = try runOnLayer(s, cmd, "Perspective Warp", p, moves: true, { surf, sel, _ in
            deformSelected(surf, sel) { x in perspectiveSurface(x, planes, it) }
        }, mask: maskFn)
        return r.setting("planes", .encoded(planes))
    }

    // MARK: Registry

    static let liquifyParamsText = #"{"strokes":[{"tool":"forwardWarp|reconstruct|smooth|twirlCw|twirlCcw|pucker|bloat|pushLeft|freeze|thaw|lassoMask|reconstructAll","size":px=100,"density":0-100=50,"pressure":0-100=100,"rate":0-100=80,"points":[[x,y,pressure?]…],"amount":%? (reconstructAll; lassoMask: 1 freezes the polygon in points, 0 thaws it)}…],"meshSize":px? (field resolution, px per node; default 2, or 4 above 4 MP),"layer":id?} — strokes replay in order on a fresh field; a selection limits the effect; on a smart object it becomes a smart filter"#
    static let puppetParamsText = #"{"pins":[{"src":[x,y],"dst":[x,y],"rotate":deg?,"depth":n?}…],"mode":"rigid|normal|distort"="normal","density":"fewer|normal|more"="normal","expansion":px=2,"interpolation":"bicubic|bilinear|nearest","layer":id?} — mesh over the opaque region, as-rigid-as-possible; on a smart object it becomes a smart filter"#
    static let perspectiveParamsText = #"{"planes":[{"src":[[x,y]×4],"dst":[[x,y]×4]}…] (corners clockwise from top-left; corners that coincide in src are linked),"straighten":"horizontal|vertical|auto"?,"interpolation":"bicubic|bilinear|nearest","layer":id?}"#

    static func register(into r: inout CommandRegistry) {
        let so = ["Layer", "Smart Objects"]
        r.add(CommandSpec(liquifyId, "Liquify…", menu: ["Filter"], shortcut: "Cmd+Shift+X", params: liquifyParamsText, module: m,
                          enabled: FilterCommands.hasFilterableLayer, run: liquify))
        r.add(CommandSpec(puppetId, "Puppet Warp", menu: ["Edit"], params: puppetParamsText, module: m, enabled: pixelLayer) { s, p in
            try puppet(s, p, puppetId)
        })
        r.add(CommandSpec(puppetSmartId, "Puppet Warp", menu: so, params: puppetParamsText, module: m, enabled: smartLayer) { s, p in
            try puppet(s, p, puppetSmartId)
        })
        r.add(CommandSpec(perspectiveId, "Perspective Warp", menu: ["Edit"], params: perspectiveParamsText, module: m, enabled: pixelLayer) { s, p in
            try perspective(s, p, perspectiveId)
        })
        r.add(CommandSpec(perspectiveSmartId, "Perspective Warp", menu: so, params: perspectiveParamsText, module: m, enabled: smartLayer) { s, p in
            try perspective(s, p, perspectiveSmartId)
        })
    }
}
