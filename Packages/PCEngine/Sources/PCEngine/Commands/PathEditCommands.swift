// Port of photocraft-engine (crates/engine/src/path_edit_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Point-level path edits, what Photoshop's Direct Selection, Convert Point and Add / Delete Anchor
// Point tools do on the canvas: move anchors, drag direction handles, bend segments, convert
// points, insert or remove anchors. The geometry is photocraft-vector's edit.rs (ported in
// `VectorCommands+Geometry.swift`); the canvas previews a drag with it and commits the whole drag
// as one command (one history step, or one per drag with `"coalesce"`).
//
// Every command targets a path like `path.transform`: `"name":"work"` (default), a saved path's
// name, or `"layer"` with `"layer":id?` for a shape layer's path (re-rendered; it stops being a
// live shape) or a layer's vector mask. Knots are addressed by `subpath` and `knot` index, as
// `path.info` lists them; the result is `{name, path}` in the compact JSON form.

import Foundation
import PCDocument
import PCFoundation

enum PathEditCommands: CommandModule {
    static let name = "path_edit_cmds"
    static let m = "path_edit_cmds"

    /// Coordinates and offsets beyond this are mistakes (the same bound as `path.transform`).
    static let maxCoordinate = 1_000_000.0

    static func finite(_ v: SIMD2<Double>) -> Bool { v.x.isFinite && v.y.isFinite && abs(v.x) <= maxCoordinate && abs(v.y) <= maxCoordinate }

    static func offset(_ cmd: String, _ p: JSONValue) throws -> SIMD2<Double> {
        guard let d = VectorCommands.nums(p, "move", 2).map({ SIMD2($0[0], $0[1]) }), finite(d) else {
            throw EngineError.bad(cmd, "`move` must be [dx, dy] with finite numbers of magnitude at most 1000000")
        }
        return d
    }

    static func point(_ cmd: String, _ p: JSONValue, _ key: String) throws -> PCPoint? {
        guard let v = p[key] else { return nil }
        guard let q = VectorCommands.pt(v), finite(q.simd) else {
            throw EngineError.bad(cmd, "`\(key)` must be [x, y] with finite numbers of magnitude at most 1000000")
        }
        return q
    }

    static func index(_ cmd: String, _ p: JSONValue, _ key: String) throws -> Int {
        guard let v = p[key]?.uint64Value, let i = Int(exactly: v) else { throw EngineError.bad(cmd, "missing `\(key)` index") }
        return i
    }

    static func knot(_ cmd: String, _ p: JSONValue) throws -> (Int, Int) {
        (try index(cmd, p, "subpath"), try index(cmd, p, "knot"))
    }

    /// Applies `f` to the targeted path in one undoable step labelled `label`.
    static func editPath(_ s: Session, _ cmd: String, _ p: JSONValue, _ label: String,
                         _ f: (inout VectorPath) throws(VectorCommands.GeometryError) -> Void) throws -> JSONValue {
        let name = p["name"]?.stringValue ?? "work"
        let layer: LayerId? = try name == "layer" ? s.layerParam(p) : nil
        let shape = layer.flatMap { id -> LayerId? in
            if let l = s.active?.doc.layer(id), case .shape = l.content { return id }
            return nil
        }
        let path: JSONValue
        if let id = shape {
            path = try VectorCommands.withShape(s, id, label) { sh, _ in
                do { try f(&sh.path) } catch { throw VectorCommands.bad(cmd, error) }
                sh.live = nil
                sh.psdRaw = nil
                return VectorCommands.pathJSON(sh.path)
            }
        } else {
            path = try s.edit(label) { doc, _ in
                try VectorCommands.withPath(&doc, name, layer) { path in
                    do { try f(&path) } catch { throw VectorCommands.bad(cmd, error) }
                    return VectorCommands.pathJSON(path)
                }
            }
        }
        return ["name": .string(name), "path": path]
    }

    static func moveAnchors(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.moveAnchors"
        guard let list = p["anchors"]?.arrayValue, !list.isEmpty else { throw EngineError.bad(cmd, "`anchors` must list [subpath, knot] pairs") }
        let anchors: [(Int, Int)] = try list.map { a in
            func n(_ i: Int) -> Int? { a[i]?.uint64Value.flatMap { Int(exactly: $0) } }
            guard let sp = n(0), let k = n(1) else { throw EngineError.bad(cmd, "each anchor is [subpath, knot]") }
            return (sp, k)
        }
        let d = try offset(cmd, p)
        return try editPath(s, cmd, p, "Drag Anchor Points") { path throws(VectorCommands.GeometryError) in
            try VectorCommands.moveAnchors(&path, anchors, d)
        }
    }

    static func moveHandle(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.moveHandle"
        let (sp, k) = try knot(cmd, p)
        guard let h = p["handle"]?.stringValue.flatMap(VectorCommands.Handle.parse) else {
            throw EngineError.bad(cmd, "`handle` must be \"in\" or \"out\"")
        }
        guard let to = try point(cmd, p, "to") else { throw EngineError.bad(cmd, "missing `to`") }
        let independent = p["independent"]?.boolValue ?? false
        return try editPath(s, cmd, p, "Drag Direction Point") { path throws(VectorCommands.GeometryError) in
            try VectorCommands.moveHandle(&path, sp, k, h, to, independent: independent)
        }
    }

    static func bendSegment(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.bendSegment"
        let (sp, k) = try knot(cmd, p)
        var t = 0.5
        if let v = p["t"] {
            guard let x = v.doubleValue, x >= 0, x <= 1 else { throw EngineError.bad(cmd, "`t` must be between 0 and 1") }
            t = x
        }
        let d = try offset(cmd, p)
        return try editPath(s, cmd, p, "Drag Segment") { path throws(VectorCommands.GeometryError) in
            try VectorCommands.bendSegment(&path, sp, k, t, d)
        }
    }

    static func convertPoint(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.convertPoint"
        let (sp, k) = try knot(cmd, p)
        let out = try point(cmd, p, "out")
        return try editPath(s, cmd, p, "Convert Point") { path throws(VectorCommands.GeometryError) in
            try VectorCommands.convertPoint(&path, sp, k, out)
        }
    }

    static func addAnchor(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.addAnchor"
        let (sp, k) = try knot(cmd, p)
        var t = 0.5
        if let v = p["t"] {
            guard let x = v.doubleValue, x > 0, x < 1 else { throw EngineError.bad(cmd, "`t` must be strictly between 0 and 1") }
            t = x
        }
        var added: (Int, Int)?
        var r = try editPath(s, cmd, p, "Add Anchor Point") { path throws(VectorCommands.GeometryError) in
            added = try VectorCommands.addAnchor(&path, sp, k, t)
        }
        if let a = added { r = r.setting("anchor", ["subpath": .int(a.0), "knot": .int(a.1)]) }
        return r
    }

    static func deleteAnchor(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "path.deleteAnchor"
        let (sp, k) = try knot(cmd, p)
        var removed = false
        let r = try editPath(s, cmd, p, "Delete Anchor Point") { path throws(VectorCommands.GeometryError) in
            removed = try VectorCommands.deleteAnchor(&path, sp, k)
        }
        return r.setting("subpathRemoved", .bool(removed))
    }

    static let target = ##""name":str|"work"|"layer"="work","layer":id? (with "layer": a shape layer's path or a vector mask)"##

    static func spec(_ id: String, _ label: String, _ params: String, _ run: @escaping CommandRun) -> CommandSpec {
        CommandSpec(id, label, params: "{" + target + "," + params + "} → {name,path}", module: m, enabled: VectorCommands.hasDoc, run: run)
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            spec("path.moveAnchors", "Drag Anchor Points",
                 ##""anchors":[[subpath,knot],…],"move":[dx,dy] (anchors move with their handles; Direct Selection drag)"##, moveAnchors),
            spec("path.moveHandle", "Drag Direction Point",
                 ##""subpath":i,"knot":j,"handle":"in|out","to":[x,y],"independent":bool=false (a smooth point turns its other handle to stay collinear; independent = ⌥ / Convert Point, makes a corner)"##,
                 moveHandle),
            spec("path.bendSegment", "Drag Segment",
                 ##""subpath":i,"knot":j (the segment leaving it),"t":0..1=0.5 (where it was grabbed),"move":[dx,dy] (a straight segment moves with its anchors; a curve reshapes through the dragged point)"##,
                 bendSegment),
            spec("path.convertPoint", "Convert Point",
                 ##""subpath":i,"knot":j,"out":[x,y]? (none: corner with retracted handles; given: smooth with this out handle and its mirror)"##, convertPoint),
            spec("path.addAnchor", "Add Anchor Point",
                 ##""subpath":i,"knot":j (the segment leaving it),"t":0<t<1=0.5 (where on the segment) (a curve is split there without changing its shape and gets a smooth anchor; a straight segment gets a corner) (the result also has anchor:{subpath,knot})"##,
                 addAnchor),
            spec("path.deleteAnchor", "Delete Anchor Point",
                 ##""subpath":i,"knot":j (its neighbours are joined, keeping their handles; a subpath's last anchor removes the subpath; the path's only anchor is refused) (the result also has subpathRemoved:bool)"##,
                 deleteAnchor),
        ])
    }
}
