// Port of photocraft-engine (crates/engine/src/render_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Render › Flame…, Picture Frame… and Tree…: procedural renderers (PCAlgo `RenderProc`,
// photocraft `render2`). They draw onto the active pixel layer (or a new layer with
// `newLayer: true`, or when the active layer has no pixels), inside the selection, in any colour
// mode and depth, as one undo step. Results report what was drawn (`layer`, `bounds`,
// `primitives`) so agents can verify them without screenshots.

import PCAlgo
import PCDocument
import PCFoundation

enum RenderCommands: CommandModule {
    static let name = "render_cmds"

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    // MARK: Params

    /// `[r, g, b(, a)]` (0–1) or `#rrggbb` → `[r, g, b, a]` (photocraft `parse_colour`).
    static func parseColour(_ v: JSONValue) -> SIMD4<Float>? { GalleryCommands.colour(v) }

    /// Params as an object with the named colour keys normalized to arrays (invalid ones dropped).
    static func normalized(_ p: JSONValue, _ colours: [String]) -> [String: JSONValue] {
        var m = p.objectValue ?? [:]
        m["layer"] = nil
        m["newLayer"] = nil
        m["path"] = nil
        for k in colours {
            if let v = m.removeValue(forKey: k), let c = parseColour(v) { m[k] = .rgba(c) }
        }
        return m
    }

    /// Integer fields of a spec given as JSON floats: dialogs send every number as a float (`1.0`)
    /// and agents may too (photocraft #2501). Finite numbers round to the nearest integer; a
    /// negative or too-large result is then still refused by `specFrom`. Strings (names) and
    /// other types are left alone.
    static func wholeNumbers(_ m: inout [String: JSONValue], _ keys: [String]) {
        for k in keys {
            if case .number(let f)? = m[k], f.isFinite { m[k] = .number(f.rounded() + 0) }
        }
    }

    static func specFrom<T: Decodable>(_ m: [String: JSONValue], _ type: T.Type) throws -> T {
        do { return try JSONValue.object(m).decode(as: T.self) } catch {
            throw EngineError.other("invalid parameters: \(describe(error))")
        }
    }

    /// A decoding error in a few words (serde-style: what was wrong, at which field).
    static func describe(_ e: any Error) -> String {
        guard let e = e as? DecodingError else { return "\(e)" }
        func at(_ path: [any CodingKey]) -> String { path.isEmpty ? "" : " at `\(path.map(\.stringValue).joined(separator: "."))`" }
        switch e {
        case .typeMismatch(let t, let c): return "invalid type, expected \(t)\(at(c.codingPath))"
        case .valueNotFound(let t, let c): return "missing value, expected \(t)\(at(c.codingPath))"
        case .keyNotFound(let k, let c): return "missing field `\(k.stringValue)`\(at(c.codingPath))"
        case .dataCorrupted(let c): return "\(c.debugDescription)\(at(c.codingPath))"
        @unknown default: return "\(e)"
        }
    }

    /// Accepts a 1-based number or a name (camelCase) for an enumerated option.
    static func indexParam(_ m: inout [String: JSONValue], _ k: String, _ names: [String]) {
        guard case .string(let n)? = m[k] else { return }
        func norm(_ s: String) -> String { String(s.lowercased().filter { $0 != " " && $0 != "-" && $0 != "_" }) }
        let lower = norm(n)
        let i = names.firstIndex { norm($0) == lower }.map { $0 + 1 } ?? 1
        m[k] = .int(i)
    }

    /// Flattened polylines of the path Flame follows: `path` (a saved path name, `"work"`), else
    /// the work path, else the first saved path. nil when the document has no path.
    static func flamePaths(_ s: Session, _ p: JSONValue) -> [[SIMD2<Float>]]? {
        guard let doc = s.active?.doc else { return nil }
        let path: VectorPath?
        if let n = p["path"]?.stringValue, !n.isEmpty, !GalleryCommands.asciiCaseless(n, "work") {
            path = doc.paths.first { $0.name == n }?.path
        } else {
            path = doc.workPath ?? doc.paths.first?.path
        }
        guard let path else { return nil }
        let polys: [[SIMD2<Float>]] = VectorCommands.flattenPath(path, 0.5).map { pl in
            var v = pl.pts.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
            if pl.closed, let f = v.first { v.append(f) }
            return v
        }.filter { !$0.isEmpty }
        return polys.isEmpty ? nil : polys
    }

    // MARK: Drawing

    /// Draws `prims` onto the target layer as one undo step.
    static func draw(_ s: Session, _ label: String, _ p: JSONValue, _ prims: [RenderProc.Prim], _ extra: [String: JSONValue]) throws -> JSONValue {
        let wantNew = p["newLayer"]?.boolValue ?? false
        let target = Params.layerId(p)
        let count = prims.count
        let (layer, created, used) = try s.edit(label) { doc, active -> (LayerId, Bool, PixelRect) in
            let id0 = target ?? active
            var raster = false
            if let i = id0, let l = doc.layer(i), case .raster = l.content { raster = true }
            let id: LayerId
            let created: Bool
            if wantNew || !raster {
                let name = label.hasSuffix("…") ? String(label.dropLast()) : label
                let nid = doc.insertAbove(active, Layer.raster(name, format: doc.pixelFormat))
                active = nid
                (id, created) = (nid, true)
            } else {
                guard let i = id0 else { throw EngineError.other("no active layer") }
                (id, created) = (i, false)
            }
            let selection = doc.selection
            var clip = doc.bounds
            if let sel = selection { clip = clip.intersect(sel.contentBounds) }
            let used = try LayerOps.withPaintSurface(&doc, id, .null) { surf -> PixelRect in
                let u: PixelRect
                do { u = try RenderProc.composite(&surf, prims, clip: clip, selection: selection) } catch { throw EngineError.wrap(error) }
                surf.prune()
                return u
            }
            return (id, created, used)
        }
        var r: [String: JSONValue] = [
            "layer": .id(layer),
            "newLayer": .bool(created),
            "bounds": used.isEmpty ? .null : [.int(Int(used.x0)), .int(Int(used.y0)), .int(Int(used.x1)), .int(Int(used.y1))],
            "primitives": .int(count),
        ]
        r.merge(extra) { _, b in b }
        return .object(r)
    }

    static func canvas(_ s: Session) throws -> PixelRect {
        guard let d = s.active else { throw EngineError.noDocument }
        return d.doc.bounds
    }

    static func runFlame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var m = normalized(p, ["color"])
        if !(m["useCustomColor"]?.boolValue ?? (m["color"] != nil)) { m["color"] = nil }
        m["useCustomColor"] = nil
        switch m["quality"] {
        case .number(let q)?:
            m["quality"] = .int(Int(min(max(q, 0), 4)))
        case .string(let q)?:
            m["quality"] = .int(["draft", "low", "medium", "high", "fine"].firstIndex(of: q) ?? 2)
        default:
            break
        }
        wholeNumbers(&m, ["seed"])
        let spec = try specFrom(m, FlameSpec.self)
        let found = flamePaths(s, p)
        let paths: [[SIMD2<Float>]]
        if let found {
            paths = found
        } else {
            let c = (try? canvas(s)) ?? PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)
            if spec.flameType == .candleLight {
                paths = [[SIMD2(Float(c.x0) + Float(c.width) * 0.5, Float(c.y0) + Float(c.height) * 0.75)]]
            } else {
                paths = [RenderProc.defaultFlamePath(c)]
            }
        }
        let prims = RenderProc.flame(spec, paths: paths)
        return try draw(s, "Flame…", p, prims, ["usedPath": .bool(found != nil)])
    }

    static func runTree(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var m = normalized(p, ["leavesColor", "branchesColor"])
        let names = RenderProc.treeTypeNames
        indexParam(&m, "baseTreeType", names)
        if m["leavesColor"] != nil && m["defaultLeaves"] == nil { m["defaultLeaves"] = .bool(false) }
        if m["branchesColor"] != nil && m["customBranchColor"] == nil { m["customBranchColor"] = .bool(true) }
        wholeNumbers(&m, ["baseTreeType", "lightDirection", "seed"])
        let spec = try specFrom(m, TreeSpec.self)
        let prims = RenderProc.tree(spec, canvas: try canvas(s))
        let k = Int(min(max(spec.baseTreeType, 1), 34)) - 1
        let name = k < names.count ? names[k] : ""
        return try draw(s, "Tree…", p, prims, ["treeType": .string(name)])
    }

    static func runFrame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var m = normalized(p, ["vineColor", "flowerColor", "leafColor"])
        let styles = RenderProc.frameStyles
        indexParam(&m, "frame", styles)
        wholeNumbers(&m, ["frame", "lines", "seed"])
        let spec = try specFrom(m, FrameSpec.self)
        let prims = RenderProc.pictureFrame(spec, canvas: try canvas(s))
        let name = styles[Int(min(max(spec.frame, 1), UInt32(styles.count))) - 1]
        return try draw(s, "Picture Frame…", p, prims, ["frame": .string(name)])
    }

    // MARK: Specs

    static func specs() -> [CommandSpec] {
        [
            CommandSpec("filter.render.flame", "Flame…", menu: ["Filter", "Render"],
                        params: ##"{"flameType":"oneFlameAlongPath|multipleFlamesAlongPath|multipleFlamesPathDirections|multipleFlamesVariousLength|candleLight|multipleFlamesOneDirection","length":1..1000=150,"randomizeLength":bool,"width":1..1000=40,"angle":-180..180=0,"interval":1..1000=60,"adjustIntervalForLoops":bool=true,"useCustomColor":bool,"color":color,"turbulent":0..100=25,"jag":0..100=25,"opacity":0..100=75,"flameLines":1..100=20,"flameBottomAlignment":0..100=20,"flameStyle":"normal|violent|flat","flameShape":"parallel|toCenter|spread|oval|pointed","randomizeShapes":bool,"seed":u32=0,"quality":"draft|low|medium|high|fine","path":text,"newLayer":bool} → {layer,newLayer,bounds,primitives,usedPath}"##,
                        module: name, enabled: Pre.hasDoc, run: runFlame),
            CommandSpec("filter.render.pictureFrame", "Picture Frame…", menu: ["Filter", "Render"],
                        params: ##"{"frame":"vineWithFlowers|vineWithLeaves|ivy|roses|daisies|berries|bamboo|waves|zigzag|dots|rope|scallops|doubleLine|snowflakes|stars|hearts","margin":0..30=4,"size":1..100=50,"arrangement":1..100=50,"lines":1..5=1,"thickness":1..100=30,"fade":0..100=0,"vineColor":color,"flowerColor":color,"leafColor":color,"seed":u32=0,"newLayer":bool} → {layer,newLayer,bounds,primitives,frame}"##,
                        module: name, enabled: Pre.hasDoc, run: runFrame),
            CommandSpec("filter.render.tree", "Tree…", menu: ["Filter", "Render"],
                        params: ##"{"baseTreeType":1..34=1,"lightDirection":1..5=3,"leavesAmount":0..100=50,"leavesSize":0..200=100,"branchesHeight":50..300=100,"branchesThickness":50..200=100,"defaultLeaves":bool=true,"leavesColor":color,"customBranchColor":bool,"branchesColor":color,"flatShading":bool,"seed":u32=0,"x":0..1=0.5,"y":0..1=0.95,"size":0.05..2=0.8,"newLayer":bool} → {layer,newLayer,bounds,primitives,treeType}"##,
                        module: name, enabled: Pre.hasDoc, run: runTree),
        ]
    }
}
