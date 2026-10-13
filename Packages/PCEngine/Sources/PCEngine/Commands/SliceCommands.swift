// Port of photocraft-engine (crates/engine/src/slice_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Web slices: the Slice tool (`slice.new`, Slices From Guides), the Slice Select tool (`slice.set`
// = Slice Options, promote, divide, delete), Layer › New Layer Based Slice, View › Lock Slices and
// View › Clear Slices.
//
// The document stores user and layer-based slices (`Document.slices`); auto slices are derived
// (`Document.resolvedSlices()`). Layer-based slices follow their layer: after every command
// `refresh` re-fits them to the layer's bounds including layer effects, plus outsets, without a
// history step of their own (the change is implied by the edit that moved the layer). Slices are
// addressed by stored id (`"slice"`) or by their displayed number (`"number"`).

import Foundation
import PCDocument
import PCFoundation
import PCRender

enum SliceCommands: CommandModule {
    static let name = "slice_cmds"
    static let m = "slice_cmds"

    /// View › Lock Slices (photocraft `FileMenuState::slices_locked`): session-wide, not saved.
    enum LockKey: StateKey { static let defaultValue = false }

    static func exhaustedId() -> EngineError { .other("slice id space exhausted") }

    // MARK: Preconditions

    static let hasDoc: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    static let unlocked: CommandEnabled = { s, _ in
        if s.active == nil { return "no document open" }
        return s.state[LockKey.self] ? "slices are locked (View › Lock Slices)" : nil
    }

    static let hasSlices: CommandEnabled = { s, p in
        if let why = unlocked(s, p) { return why }
        return (s.active.map { !$0.doc.slices.isEmpty } ?? false) ? nil : "the document has no user or layer-based slices"
    }

    static let hasLayerForSlice: CommandEnabled = { s, p in
        if let why = unlocked(s, p) { return why }
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer else { return "no active layer" }
        guard let l = d.doc.layer(id) else { return "no active layer" }
        if case .adjustment = l.content { return "adjustment layers have no bounds to slice" }
        if d.doc.isBackground(id) { return "the Background layer can't have a layer-based slice" }
        if d.doc.slices.list.contains(where: { $0.layer == id }) { return "the layer already has a layer-based slice" }
        return nil
    }

    // MARK: Geometry

    /// Bounds of a layer's pixels plus its layer effects (groups: the union of their visible
    /// children; artboards: the board).
    static func layerBounds(_ l: Layer) -> PixelRect {
        let own: PixelRect
        if case .group(let g) = l.content {
            if let a = g.artboard {
                own = a.rect
            } else {
                own = g.children.filter(\.visible).map(layerBounds).reduce(PixelRect.empty) { a, b in a.isEmpty ? b : (b.isEmpty ? a : a.union(b)) }
            }
        } else {
            own = l.positionBounds
        }
        if own.isEmpty || !LayerGeometry.hasEffects(l) { return own }
        return own.outset(by: LayerGeometry.margin(l))
    }

    static func layerSliceRect(_ doc: Document, _ s: Slice) -> PixelRect? {
        guard let lid = s.layer, let l = doc.layer(lid) else { return nil }
        let b = layerBounds(l)
        if b.isEmpty { return b }
        let (t, le, bo, r) = (s.outsets.x, s.outsets.y, s.outsets.z, s.outsets.w)
        func sat(_ v: Int64) -> Int32 { Int32(clamping: v) }
        return PixelRect(x0: sat(Int64(b.x0) - Int64(le)), y0: sat(Int64(b.y0) - Int64(t)), x1: sat(Int64(b.x1) + Int64(r)), y1: sat(Int64(b.y1) + Int64(bo)))
    }

    /// Re-fits layer-based slices of the active document to their layers; drops slices whose
    /// layer was deleted (as Photoshop does). Not a history step.
    static func refresh(_ s: Session) {
        guard let st = s.active, st.doc.slices.list.contains(where: { $0.origin == .layer }) else { return }
        var changes: [(UInt32, PixelRect?)] = []
        for sl in st.doc.slices.list where sl.origin == .layer {
            let r = layerSliceRect(st.doc, sl)
            if r != sl.rect { changes.append((sl.id, r)) }
        }
        if changes.isEmpty { return }
        try? s.updateActive { st in
            for (id, r) in changes {
                if let r {
                    if let i = st.doc.slices.list.firstIndex(where: { $0.id == id }) { st.doc.slices.list[i].rect = r }
                } else {
                    st.doc.slices.list.removeAll { $0.id == id }
                }
            }
        }
    }

    // MARK: Params

    /// Rust `f64 as i32`: saturating.
    static func i32(_ v: Double) -> Int32 { Int32(max(min(v, Double(Int32.max)), Double(Int32.min))) }

    static func rectParam(_ p: JSONValue) -> PixelRect? {
        func f(_ v: JSONValue?) -> Int32? {
            guard let d = v?.doubleValue, d.isFinite else { return nil }
            return i32(d.rounded())
        }
        func rect(_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) -> PixelRect? {
            if w <= 0 || h <= 0 { return nil }
            let (x1, ox) = x.addingReportingOverflow(w), (y1, oy) = y.addingReportingOverflow(h)
            if ox || oy { return nil }
            return PixelRect(x0: x, y0: y, x1: x1, y1: y1)
        }
        if let a = p["rect"]?.arrayValue, a.count == 4 {
            let v = a.compactMap { f($0) }
            return v.count == 4 ? rect(v[0], v[1], v[2], v[3]) : nil
        }
        guard let x = f(p["x"]), let y = f(p["y"]), let w = f(p["width"]), let h = f(p["height"]) else { return nil }
        return rect(x, y, w, h)
    }

    /// `#rrggbb` as ARGB bytes (opaque).
    static func hexColor(_ s: String) -> SIMD4<UInt8>? {
        let b = Array(s.drop { $0 == "#" }.utf8)
        guard b.count == 6 else { return nil }
        func byte(_ i: Int) -> UInt8? {
            let t = String(decoding: b[i..<(i + 2)], as: UTF8.self)
            guard !t.hasPrefix("-") else { return nil }
            return UInt8(t, radix: 16)
        }
        guard let r = byte(0), let g = byte(2), let bl = byte(4) else { return nil }
        return SIMD4(255, r, g, bl)
    }

    /// photocraft `commands::int`.
    static func int(_ p: JSONValue, _ key: String) -> Int64? { ArtboardCommands.int(p[key]) }

    /// Slice Options fields present in `p` applied to `sl`.
    static func applyOptions(_ sl: inout Slice, _ p: JSONValue, _ cmd: String) throws {
        func text(_ k: String) -> String? { p[k]?.stringValue }
        if let v = text("name") { sl.name = v }
        if let v = text("kind") ?? text("type") {
            guard let k = SliceKind(id: v) else { throw EngineError.bad(cmd, "unknown slice type `\(v)` (image|noImage|table)") }
            sl.kind = k
        }
        if let v = text("url") { sl.url = v }
        if let v = text("target") { sl.target = v }
        if let v = text("message") { sl.message = v }
        if let v = text("alt") { sl.alt = v }
        if let v = text("cellText") { sl.cellText = v }
        if let b = p["cellTextIsHtml"]?.boolValue { sl.cellTextIsHtml = b }
        if let v = int(p, "horizontalAlign"), v >= 0 { sl.horizontalAlign = UInt32(min(v, 4)) }
        if let v = int(p, "verticalAlign"), v >= 0 { sl.verticalAlign = UInt32(min(v, 4)) }
        switch p["background"]?.stringValue {
        case "none", "": sl.background = nil
        case let c?:
            guard let rgb = hexColor(c) else { throw EngineError.bad(cmd, ##"background is "none" or "#rrggbb""##) }
            sl.background = rgb
        case nil: break
        }
        if let a = p["outsets"]?.arrayValue, a.count == 4 {
            for (i, v) in a.enumerated() {
                // serde's `as_i64`: whole numbers only, anything else reads as 0.
                let n: Int64 = v.doubleValue.flatMap { $0 == $0.rounded() && abs($0) < 9.2e18 ? Int64($0) : nil } ?? 0
                sl.outsets[i] = Int32(min(max(n, -10_000), 10_000))
            }
        }
        if let r = rectParam(p) {
            if sl.origin == .layer {
                // Editing a layer-based slice's geometry promotes it to a user slice.
                sl.origin = .user
                sl.layer = nil
            }
            sl.rect = r
        }
    }

    /// What `"slice"` (id) or `"number"` addresses: a stored slice, or an auto slice that isn't
    /// stored yet (its rectangle).
    enum Target: Sendable {
        case stored(UInt32)
        case auto(PixelRect)
    }

    static func find(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> Target {
        guard let d = s.active else { throw EngineError.noDocument }
        if let id = try Params.u32Id(cmd, p, "slice") {
            guard let sl = d.doc.slices.get(id) else { throw EngineError.bad(cmd, "no slice with id \(id)") }
            return .stored(sl.id)
        }
        guard let n = int(p, "number"), n > 0 else { throw EngineError.bad(cmd, #"give "slice" (id) or "number""#) }
        guard let r = d.doc.resolvedSlices().first(where: { Int64($0.number) == n }) else { throw EngineError.bad(cmd, "no slice number \(n)") }
        if let id = r.id { return .stored(id) }
        return .auto(r.rect)
    }

    /// The stored slice's id; an auto slice is promoted to a user slice in `doc` first. Call it
    /// inside the command's own edit, so promoting and the rest of the command are one history
    /// step and a rejected command changes nothing.
    static func store(_ doc: inout Document, _ t: Target) throws -> UInt32 {
        switch t {
        case .stored(let id): return id
        case .auto(let rect):
            guard let id = doc.slices.nextId else { throw exhaustedId() }
            doc.slices.list.append(Slice(id: id, rect: rect))
            return id
        }
    }

    /// The stored slice addressed by `p`; an auto slice is an error.
    static func stored(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> UInt32 {
        switch try find(s, p, cmd) {
        case .stored(let id): return id
        case .auto: throw EngineError.bad(cmd, "that is an auto slice")
        }
    }

    static func resolvedJSON(_ doc: Document, _ r: ResolvedSlice, stored: [UInt32: Slice]? = nil) -> JSONValue {
        let s = r.id.flatMap { id in stored.map { $0[id] } ?? doc.slices.get(id) }
        return [
            "number": .int(r.number),
            "id": r.id.map { .int($0) } ?? .null,
            "origin": .string(r.origin.id),
            "name": .string(r.name),
            "rect": .rect(r.rect),
            "kind": .string(r.kind.id),
            "layer": s?.layer.map { .id($0) } ?? .null,
            "url": .string(s?.url ?? ""),
            "target": .string(s?.target ?? ""),
            "message": .string(s?.message ?? ""),
            "alt": .string(s?.alt ?? ""),
            "cellText": .string(s?.cellText ?? ""),
            "background": s?.background.map { .string(String(format: "#%02x%02x%02x", $0.y, $0.z, $0.w)) } ?? .null,
        ]
    }

    // MARK: Commands

    static func newSlice(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "slice.new"
        guard let d = s.active else { throw EngineError.noDocument }
        guard let r0 = rectParam(p) else { throw EngineError.bad(cmd, #"give "rect":[x,y,w,h] (or x, y, width, height)"#) }
        let rect = r0.intersect(d.doc.bounds)
        if rect.isEmpty { throw EngineError.bad(cmd, "the slice is outside the canvas") }
        let id = try s.edit("Slice") { doc, _ -> UInt32 in
            guard let id = doc.slices.nextId else { throw exhaustedId() }
            var sl = Slice(id: id, rect: rect)
            try applyOptions(&sl, p, cmd)
            sl.rect = rect
            doc.slices.list.append(sl)
            return id
        }
        guard let after = s.active else { throw EngineError.noDocument }
        let number = after.doc.resolvedSlices().first { $0.id == id }.map { JSONValue.int($0.number) } ?? .null
        return ["slice": .int(id), "number": number]
    }

    static func fromGuides(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let b = d.doc.bounds
        var xs: [Int32] = [b.x0, b.x1], ys: [Int32] = [b.y0, b.y1]
        xs += d.doc.guides.vertical.map { i32($0.rounded()) }.filter { $0 > b.x0 && $0 < b.x1 }
        ys += d.doc.guides.horizontal.map { i32($0.rounded()) }.filter { $0 > b.y0 && $0 < b.y1 }
        if xs.count == 2 && ys.count == 2 { throw EngineError.other("the document has no guides inside the canvas") }
        xs = Array(Set(xs)).sorted()
        ys = Array(Set(ys)).sorted()
        var rects: [PixelRect] = []
        for j in 0..<(ys.count - 1) {
            for i in 0..<(xs.count - 1) { rects.append(PixelRect(x0: xs[i], y0: ys[j], x1: xs[i + 1], y1: ys[j + 1])) }
        }
        let n = rects.count
        try s.edit("Slices From Guides") { doc, _ in
            // Photoshop replaces every existing slice.
            doc.slices.list.removeAll()
            for r in rects {
                guard let id = doc.slices.nextId else { throw exhaustedId() }
                doc.slices.list.append(Slice(id: id, rect: r))
            }
        }
        return ["slices": .int(n)]
    }

    static func setSlice(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "slice.set"
        if ["rect", "x", "y", "width", "height"].contains(where: { p[$0] != nil }) && rectParam(p) == nil {
            throw EngineError.bad(cmd, "give a finite rectangle with positive dimensions and representable corners")
        }
        let t = try find(s, p, cmd)
        // Promoting an auto slice and its options are one user action (one history step), and
        // nothing is committed unless every option is valid and the slice stays on the canvas.
        let id = try s.edit("Slice Options") { doc, _ -> UInt32 in
            let id = try store(&doc, t)
            guard var sl = doc.slices.get(id) else { throw EngineError.bad(cmd, "slice vanished") }
            try applyOptions(&sl, p, cmd)
            doc.slices[id: id] = sl
            if !doc.resolvedSlices().contains(where: { $0.id == id }) { throw EngineError.bad(cmd, "slice is off the canvas") }
            return id
        }
        guard let d = s.active else { throw EngineError.noDocument }
        guard let r = d.doc.resolvedSlices().first(where: { $0.id == id }) else { throw EngineError.bad(cmd, "slice is off the canvas") }
        return resolvedJSON(d.doc, r)
    }

    static func promote(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let t = try find(s, p, "slice.promote")
        // Layer-based slices promote too: they stop following their layer.
        let promotes: Bool
        switch t {
        case .auto: promotes = true
        case .stored(let id): promotes = s.active?.doc.slices.get(id)?.origin == .layer
        }
        if case .stored(let id) = t, !promotes { return ["slice": .int(id)] }
        let id = try s.edit("Promote to User Slice") { doc, _ -> UInt32 in
            let id = try store(&doc, t)
            if var sl = doc.slices.get(id) {
                sl.origin = .user
                sl.layer = nil
                doc.slices[id: id] = sl
            }
            return id
        }
        return ["slice": .int(id)]
    }

    static func idsParam(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> [UInt32] {
        if let a = p["slices"]?.arrayValue {
            guard let d = s.active else { throw EngineError.noDocument }
            let ids = try a.map { try Params.u32Id(cmd, "slices", $0) }.filter { d.doc.slices.get($0) != nil }
            if ids.isEmpty { throw EngineError.bad(cmd, "none of the slices exist") }
            return ids
        }
        return [try stored(s, p, cmd)]
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let ids = try idsParam(s, p, "slice.delete")
        try s.edit("Delete Slice") { doc, _ in doc.slices.list.removeAll { ids.contains($0.id) } }
        return ["deleted": .int(ids.count)]
    }

    /// The most parts one Divide Slice makes: resolving the slice list is quadratic in the slice
    /// count, so a million slices left every later list or export stuck (#1020).
    static let maxDivideParts: Int32 = 10_000

    static func divide(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "slice.divide"
        let t = try find(s, p, cmd)
        let down = Int32(min(max(int(p, "horizontal") ?? 1, 1), 1000))
        let across = Int32(min(max(int(p, "vertical") ?? 1, 1), 1000))
        if down == 1 && across == 1 { throw EngineError.bad(cmd, #"give "horizontal" (slices down) and/or "vertical" (slices across) > 1"#) }
        if down * across > maxDivideParts {
            throw EngineError.bad(cmd, "\(down) x \(across) = \(down * across) parts is more than one division makes (\(maxDivideParts))")
        }
        let r: PixelRect
        switch t {
        case .auto(let a): r = a
        case .stored(let id):
            guard let sl = s.active?.doc.slices.get(id) else { throw EngineError.bad(cmd, "no such slice") }
            r = sl.rect
        }
        if r.width < Int(across) || r.height < Int(down) { throw EngineError.bad(cmd, "the slice is too small to divide that many times") }
        let n = Int(down * across)
        // An auto slice is promoted inside the same step: one undo restores it.
        let ids = try s.edit("Divide Slice") { doc, _ -> [UInt32] in
            let id = try store(&doc, t)
            guard let src = doc.slices.get(id) else { throw EngineError.bad(cmd, "no such slice") }
            let pos = doc.slices.list.firstIndex { $0.id == id } ?? 0
            doc.slices.list.removeAll { $0.id == id }
            var ids: [UInt32] = []
            var parts: [Slice] = []
            var nextId = doc.slices.nextId
            // Products can exceed Int32 even when every interpolated edge fits the rect.
            func x(_ k: Int32) -> Int32 { Int32(truncatingIfNeeded: Int64(r.x0) + Int64(r.width) * Int64(k) / Int64(across)) }
            func y(_ k: Int32) -> Int32 { Int32(truncatingIfNeeded: Int64(r.y0) + Int64(r.height) * Int64(k) / Int64(down)) }
            for j in 0..<down {
                for i in 0..<across {
                    let nid: UInt32
                    if ids.isEmpty {
                        nid = id
                    } else {
                        guard var candidate = nextId else { throw exhaustedId() }
                        if candidate == id {
                            guard candidate < .max else { throw exhaustedId() }
                            candidate += 1
                        }
                        nextId = candidate < .max ? candidate + 1 : nil
                        nid = candidate
                    }
                    ids.append(nid)
                    // The first part keeps the original's options; the others start fresh.
                    var part: Slice
                    if parts.isEmpty {
                        part = src
                        part.origin = .user
                        part.layer = nil
                    } else {
                        part = Slice()
                    }
                    part.id = nid
                    part.rect = PixelRect(x0: x(i), y0: y(j), x1: x(i + 1), y1: y(j + 1))
                    parts.append(part)
                }
            }
            for (k, sl) in parts.enumerated() { doc.slices.list.insert(sl, at: min(pos + k, doc.slices.list.count)) }
            return ids
        }
        return ["slices": .array(ids.map { .int($0) }), "count": .int(n)]
    }

    static func list(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        // One lookup table for the stored slices, so listing many slices stays linear in them.
        let stored = Dictionary(d.doc.slices.list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ["slices": .array(d.doc.resolvedSlices().map { resolvedJSON(d.doc, $0, stored: stored) }), "locked": .bool(s.state[LockKey.self])]
    }

    static func layerBased(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.newLayerBasedSlice"
        let layer = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(layer) else { throw EngineError.noLayer(layer) }
        if d.doc.slices.list.contains(where: { $0.layer == layer }) { throw EngineError.bad(cmd, "the layer already has a layer-based slice") }
        let rect = layerBounds(l)
        if rect.isEmpty { throw EngineError.other("Could not create a layer based slice because the layer is empty") }
        let id = try s.edit("New Layer Based Slice") { doc, _ -> UInt32 in
            guard let id = doc.slices.nextId else { throw exhaustedId() }
            var sl = Slice(id: id, origin: .layer, rect: rect, name: p["name"]?.stringValue ?? "")
            sl.layer = layer
            sl.url = p["url"]?.stringValue ?? ""
            sl.alt = p["alt"]?.stringValue ?? ""
            doc.slices.list.append(sl)
            return id
        }
        return ["slice": .int(id), "rect": .rect(rect)]
    }

    static func lock(_ s: Session, _ p: JSONValue) -> JSONValue {
        let on = p["on"]?.boolValue ?? !s.state[LockKey.self]
        s.state[LockKey.self] = on
        return ["locked": .bool(on)]
    }

    static func clear(_ s: Session) throws -> JSONValue {
        let n = s.active?.doc.slices.list.count ?? 0
        try s.edit("Clear Slices") { doc, _ in doc.slices.list.removeAll() }
        return ["cleared": .int(n)]
    }

    static func register(into r: inout CommandRegistry) {
        // photocraft `automate_cmds::after_command`: keep layer-based slices on their layers.
        r.hooks.after.append { s, _, _ in refresh(s) }
        r.add([
            CommandSpec("slice.new", "Slice Tool",
                        params: ##"{"rect":[x,y,w,h] | "x","y","width","height", plus Slice Options ("name","kind":"image|noImage|table","url","target","message","alt","cellText","cellTextIsHtml","background":"none|#rrggbb")?} → {slice, number}"##,
                        module: m, enabled: unlocked) { s, p in try newSlice(s, p) },
            CommandSpec("slice.fromGuides", "Slices From Guides", params: "{} (replaces every slice by the grid of the canvas guides) → {slices}",
                        module: m, enabled: unlocked) { s, _ in try fromGuides(s) },
            CommandSpec("slice.set", "Slice Options…",
                        params: ##"{"slice":id | "number":n (an auto slice is promoted), "name"?,"kind":"image|noImage|table"?,"url"?,"target"?,"message"?,"alt"?,"cellText"?,"cellTextIsHtml"?,"horizontalAlign":0..4?,"verticalAlign":0..4?,"background":"none|#rrggbb"?,"outsets":[t,l,b,r]? (layer slices),"rect":[x,y,w,h]? (move/resize; a layer slice becomes a user slice)} → the slice"##,
                        module: m, enabled: unlocked) { s, p in try setSlice(s, p) },
            CommandSpec("slice.promote", "Promote", params: #"{"slice":id | "number":n} (auto or layer-based → user slice) → {slice}"#,
                        module: m, enabled: unlocked) { s, p in try promote(s, p) },
            CommandSpec("slice.delete", "Delete Slice", params: #"{"slice":id | "number":n | "slices":[id…]} → {deleted}"#,
                        module: m, enabled: hasSlices) { s, p in try delete(s, p) },
            CommandSpec("slice.divide", "Divide Slice…",
                        params: #"{"slice":id | "number":n,"horizontal":n=1 (slices down),"vertical":n=1 (slices across); at most 10000 parts} → {slices}"#,
                        module: m, enabled: unlocked) { s, p in try divide(s, p) },
            CommandSpec("slice.list", "List Slices",
                        params: "{} → {slices:[{number,id,origin:auto|layer|user,name,rect:[x,y,w,h],kind,layer,url,alt,…}], locked}",
                        module: m, journal: false, enabled: hasDoc) { s, _ in try list(s) },
            CommandSpec("layer.newLayerBasedSlice", "New Layer Based Slice", menu: ["Layer"],
                        params: #"{"layer":id?,"name":str?,"url":str?,"alt":str?} (follows the layer's bounds with effects) → {slice, rect}"#,
                        module: m, enabled: hasLayerForSlice) { s, p in try layerBased(s, p) },
            CommandSpec("view.lockSlices", "Lock Slices", menu: ["View"], params: #"{"on":bool? (default: toggle)} → {locked}"#,
                        module: m, enabled: hasDoc) { s, p in lock(s, p) },
            CommandSpec("view.clearSlices", "Clear Slices", menu: ["View"], params: "{} (deletes every user and layer-based slice) → {cleared}",
                        module: m, enabled: hasSlices) { s, _ in try clear(s) },
        ])
    }
}
