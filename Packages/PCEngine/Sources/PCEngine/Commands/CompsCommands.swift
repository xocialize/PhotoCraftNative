// Port of photocraft-engine (crates/engine/src/comps_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Window › Layer Comps: capture, apply and manage layer comps (`layerComp.*`), plus File › Export ›
// Layer Comps to Files (each comp saved through PCIO's exporters).
//
// A comp records every layer's visibility, position and appearance; its three options choose which
// of them applying restores (PCDocument's Comps.swift). Comps live in the document, so every change
// here is one undoable history step. Commands that act on "the" comp take `"comp": id | name` and
// default to the comp applied (or created) last.

import Foundation
import PCDocument
import PCFoundation

enum CompsCommands: CommandModule {
    static let name = "comps_cmds"
    static let m = name

    static let hasComps: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.layerComps.isEmpty ? "the document has no layer comps" : nil
    }

    static let hasLastState: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.lastDocumentState != nil ? nil : "no comp has been applied over the document state"
    }

    /// The comp a command acts on: `"comp"` as an id or a name, else the last applied comp.
    static func compParam(_ doc: Document, _ p: JSONValue, _ cmd: String) throws -> UInt32 {
        switch p["comp"] {
        case .number?:
            let id = try Params.u32Id(cmd, "comp", p["comp"] ?? .null)
            guard let c = doc.comp(id) else { throw EngineError.bad(cmd, "no layer comp with id \(id)") }
            return c.id
        case .string(let name)?:
            guard let c = doc.layerComps.first(where: { $0.name == name }) else { throw EngineError.bad(cmd, "no layer comp named \"\(name)\"") }
            return c.id
        case _?:
            throw EngineError.bad(cmd, "\"comp\" must be a comp id or name")
        case nil:
            if let id = doc.lastAppliedComp, doc.comp(id) != nil { return id }
            guard let first = doc.layerComps.first else { throw EngineError.bad(cmd, "the document has no layer comps") }
            return first.id
        }
    }

    static func indexOf(_ doc: Document, _ id: UInt32) -> Int { doc.layerComps.firstIndex { $0.id == id } ?? 0 }

    static func flag(_ p: JSONValue, _ key: String, _ def: Bool) -> Bool { p[key]?.boolValue ?? def }

    /// Restores `comp`'s recorded state (only what its options select; `all` forces everything).
    /// Layers deleted since the capture are skipped. Position-locked layers still move, as in
    /// Photoshop, because the comp is not a user drag.
    static func applyComp(_ doc: inout Document, _ comp: LayerComp, all: Bool) {
        let (vis, pos, app) = all ? (true, true, true) : (comp.applyVisibility, comp.applyPosition, comp.applyAppearance)
        // Walk order (parents before children): a moved artboard carries its children, which are
        // then placed absolutely, so the result does not depend on how far the parent moved.
        let order = doc.walk().map(\.layer.id)
        for id in order {
            guard let st = comp.state(id) else { continue }
            if pos, let target = st.position, let current = doc.layer(id)?.compPosition, target != current {
                // Recorded positions can come from files; a move that does not fit an Int32 is
                // skipped rather than wrapped onto some other position (#1017).
                let (dx, ox) = target.x.subtractingReportingOverflow(current.x)
                let (dy, oy) = target.y.subtractingReportingOverflow(current.y)
                if !ox && !oy {
                    let snapshot = doc
                    doc.updateLayer(id) { LayerOps.translateLayer(snapshot, &$0, dx, dy) }
                }
            }
            doc.updateLayer(id) { l in
                if vis, let v = st.visible { l.visible = v }
                if app, let a = st.appearance {
                    l.blend = a.blend
                    l.opacity = a.opacity
                    l.fillOpacity = a.fillOpacity
                    l.effects = a.effects
                }
            }
        }
    }

    static func newComp(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let name = p["name"]?.stringValue ?? {
            let names = d.doc.layerComps.map(\.name)
            // `names.count + 1` candidates always include a free one.
            return (1...(names.count + 1)).map { "Layer Comp \($0)" }.first { !names.contains($0) } ?? "Layer Comp"
        }()
        let comment = p["comment"]?.stringValue ?? ""
        let (v, pos, a) = (flag(p, "visibility", true), flag(p, "position", true), flag(p, "appearance", true))
        let id = try s.edit("New Layer Comp") { doc, _ -> UInt32 in
            let id = doc.nextCompId()
            doc.layerComps.append(LayerComp(id: id, name: name, comment: comment, applyVisibility: v, applyPosition: pos,
                                            applyAppearance: a, states: doc.captureCompStates()))
            doc.lastAppliedComp = id
            return id
        }
        return ["comp": .int(Int(id))]
    }

    static func updateComp(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layerComp.update"
        guard let d = s.active else { throw EngineError.noDocument }
        let what = p["what"]?.stringValue ?? "all"
        guard ["all", "visibility", "position", "appearance"].contains(what) else {
            throw EngineError.bad(cmd, "unknown \"what\" `\(what)` (all|visibility|position|appearance)")
        }
        let every = p["comp"]?.stringValue == "*"
        let ids = every ? d.doc.layerComps.map(\.id) : [try compParam(d.doc, p, cmd)]
        let label = switch what {
        case "visibility": "Update Layer Comp Visibility"
        case "position": "Update Layer Comp Position"
        case "appearance": "Update Layer Comp Appearance"
        default: "Update Layer Comp"
        }
        try s.edit(label) { doc, _ in
            let now = doc.captureCompStates()
            for id in ids {
                guard let i = doc.layerComps.firstIndex(where: { $0.id == id }) else { continue }
                if what == "all" {
                    doc.layerComps[i].states = now
                    continue
                }
                // One property: refresh it on every live layer, keep the others as recorded.
                let c = doc.layerComps[i]
                doc.layerComps[i].states = now.map { n in
                    var st = c.state(n.layer) ?? CompLayerState(layer: n.layer)
                    switch what {
                    case "visibility": st.visible = n.visible
                    case "position": st.position = n.position
                    default: st.appearance = n.appearance
                    }
                    return st
                }
            }
        }
        return ["updated": .array(ids.map { .int(Int($0)) })]
    }

    /// Whether the live layout still matches the properties the last applied comp restores. Compare
    /// only on comp application: ordinary edits must not scan pixel bounds each frame.
    static func matchesLastComp(_ doc: Document, _ now: [CompLayerState]) -> Bool {
        guard let id = doc.lastAppliedComp, let comp = doc.comp(id) else { return false }
        let saved = Dictionary(comp.states.map { ($0.layer, $0) }, uniquingKeysWith: { _, b in b })
        return now.count == saved.count && now.allSatisfy { live in
            guard let s = saved[live.layer] else { return false }
            return (!comp.applyVisibility || s.visible == nil || s.visible == live.visible)
                && (!comp.applyPosition || s.position == nil || s.position == live.position)
                && (!comp.applyAppearance || s.appearance == nil || s.appearance == live.appearance)
        }
    }

    static func apply(_ s: Session, _ id: UInt32, _ label: String) throws -> JSONValue {
        try s.edit(label) { doc, _ in
            guard let comp = doc.comp(id) else { throw EngineError.other("no layer comp with id \(id)") }
            // Ordinary edits can leave lastAppliedComp pointing at an outdated layout (#919).
            // Preserve the edited layout, but keep the original backup while cycling unedited comps.
            let states = doc.captureCompStates()
            if !matchesLastComp(doc, states) {
                doc.lastDocumentState = LayerComp(id: 0, name: "Last Document State", comment: "", applyVisibility: true,
                                                  applyPosition: true, applyAppearance: true, states: states)
            }
            applyComp(&doc, comp, all: false)
            doc.lastAppliedComp = id
        }
        guard let d = s.active else { throw EngineError.noDocument }
        let missing = d.doc.comp(id)?.missingLayers(in: d.doc).count ?? 0
        return ["comp": .int(Int(id)), "missingLayers": .int(missing)]
    }

    static func applyCmd(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        return try apply(s, try compParam(d.doc, p, "layerComp.apply"), "Apply Layer Comp")
    }

    static func step(_ s: Session, _ delta: Int) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let n = d.doc.layerComps.count
        guard n > 0 else { throw EngineError.other("the document has no layer comps") }
        let cur = d.doc.lastAppliedComp.flatMap { id in d.doc.layerComps.firstIndex { $0.id == id } }
        let next: Int
        if let i = cur {
            let r = (i + delta) % n
            next = r < 0 ? r + n : r
        } else {
            next = delta > 0 ? 0 : n - 1
        }
        return try apply(s, d.doc.layerComps[next].id, "Apply Layer Comp")
    }

    static func delete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let id = try compParam(d.doc, p, "layerComp.delete")
        try s.edit("Delete Layer Comp") { doc, _ in
            doc.layerComps.removeAll { $0.id == id }
            if doc.lastAppliedComp == id { doc.lastAppliedComp = nil }
        }
        return ["deleted": .int(Int(id))]
    }

    static func duplicate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let id = try compParam(d.doc, p, "layerComp.duplicate")
        let new = try s.edit("Duplicate Layer Comp") { doc, _ -> UInt32 in
            let i = indexOf(doc, id)
            guard i < doc.layerComps.count else { throw EngineError.other("no layer comp with id \(id)") }
            var c = doc.layerComps[i]
            c.id = doc.nextCompId()
            c.name = "\(c.name) copy"
            doc.layerComps.insert(c, at: i + 1)
            return c.id
        }
        return ["comp": .int(Int(new))]
    }

    /// A non-empty string param (photocraft `file_cmds::str_param`).
    static func strParam(_ p: JSONValue, _ key: String, _ cmd: String) throws -> String {
        guard let v = p[key]?.stringValue, !v.isEmpty else { throw EngineError.bad(cmd, "missing \"\(key)\"") }
        return v
    }

    /// Edits comp `id` of the active document in one step named `label`.
    static func editComp(_ s: Session, _ label: String, _ id: UInt32, _ body: @escaping (inout LayerComp) -> Void) throws {
        try s.edit(label) { doc, _ in
            let i = indexOf(doc, id)
            guard i < doc.layerComps.count else { throw EngineError.other("no layer comp with id \(id)") }
            body(&doc.layerComps[i])
        }
    }

    static func rename(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layerComp.rename"
        let name = try strParam(p, "name", cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let id = try compParam(d.doc, p, cmd)
        try editComp(s, "Rename Layer Comp", id) { $0.name = name }
        return ["comp": .int(Int(id))]
    }

    static func setComment(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layerComp.setComment"
        guard let comment = p["comment"]?.stringValue else { throw EngineError.bad(cmd, "missing \"comment\"") }
        guard let d = s.active else { throw EngineError.noDocument }
        let id = try compParam(d.doc, p, cmd)
        try editComp(s, "Layer Comp Options", id) { $0.comment = comment }
        return ["comp": .int(Int(id))]
    }

    static func setOptions(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layerComp.setOptions"
        guard let d = s.active else { throw EngineError.noDocument }
        let id = try compParam(d.doc, p, cmd)
        let (v, pos, a, name) = (p["visibility"]?.boolValue, p["position"]?.boolValue, p["appearance"]?.boolValue, p["name"]?.stringValue)
        if v == nil && pos == nil && a == nil && name == nil && p["comment"] == nil {
            throw EngineError.bad(cmd, "give \"visibility\", \"position\", \"appearance\", \"name\" or \"comment\"")
        }
        let comment = p["comment"]?.stringValue
        try editComp(s, "Layer Comp Options", id) { c in
            if let v { c.applyVisibility = v }
            if let pos { c.applyPosition = pos }
            if let a { c.applyAppearance = a }
            if let name { c.name = name }
            if let comment { c.comment = comment }
        }
        return ["comp": .int(Int(id))]
    }

    static func restoreLast(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try s.edit("Restore Last Document State") { doc, _ in
            guard let last = doc.lastDocumentState else { throw EngineError.other("no Last Document State") }
            applyComp(&doc, last, all: true)
            doc.lastAppliedComp = nil
        }
        return .null
    }

    /// Comps that refer to deleted layers (Photoshop's warning triangle). `"clear": true` drops
    /// those stale states (Clear Layer Comp Warning) as one history step.
    static func updateWarnings(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let warnings: [JSONValue] = d.doc.layerComps.compactMap { c in
            let missing = c.missingLayers(in: d.doc)
            if missing.isEmpty { return nil }
            return ["comp": .int(Int(c.id)), "name": .string(c.name), "missingLayers": .ids(missing)]
        }
        let n = warnings.count
        if flag(p, "clear", false) && n > 0 {
            try s.edit("Clear Layer Comp Warnings") { doc, _ in
                let live = Set(doc.allLayerIds)
                for i in doc.layerComps.indices { doc.layerComps[i].states.removeAll { !live.contains($0.layer) } }
            }
        }
        return ["warnings": .array(warnings), "count": .int(n)]
    }

    static func list(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let comps: [JSONValue] = d.doc.layerComps.map { c in
            ["id": .int(Int(c.id)), "name": .string(c.name), "comment": .string(c.comment),
             "visibility": .bool(c.applyVisibility), "position": .bool(c.applyPosition), "appearance": .bool(c.applyAppearance),
             "layers": .int(c.states.count), "missingLayers": .int(c.missingLayers(in: d.doc).count)]
        }
        return ["comps": .array(comps), "lastApplied": d.doc.lastAppliedComp.map { .int(Int($0)) } ?? .null,
                "hasLastDocumentState": .bool(d.doc.lastDocumentState != nil)]
    }

    /// File › Export › Layer Comps to Files: one file per comp, named
    /// `<prefix>_<index>_<comp name>.<format>` (photocraft `comps_to_files`).
    static func compsToFiles(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "file.export.layerCompsToFiles"
        let dir: String
        do { dir = try strParam(p, "dir", cmd) } catch { dir = try strParam(p, "output", cmd) }
        var format = Substring(p["format"]?.stringValue ?? "png")
        while format.hasPrefix(".") { format = format.dropFirst() }
        let ext = format.lowercased()
        let save = try FileCommands.SaveOpts.from(s, p, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let prefix = p["prefix"]?.stringValue ?? FileCommands.stem(d.doc.name)
        let doc = d.doc
        let chosen: [UInt32]
        if case .array(let a)? = p["comps"] {
            chosen = try a.map { v throws(EngineError) in try Params.u32Id(cmd, "comps", v) }
        } else if flag(p, "selectedOnly", false) {
            chosen = [try compParam(doc, [:], cmd)]
        } else {
            chosen = doc.layerComps.map(\.id)
        }
        var files: [JSONValue] = []
        for (i, c) in doc.layerComps.enumerated() where chosen.contains(c.id) {
            var one = doc
            applyComp(&one, c, all: false)
            one.lastAppliedComp = c.id
            let path = FileCommands.join(dir, "\(FileCommands.sanitize(prefix))_\(String(format: "%04d", i))_\(FileCommands.sanitize(c.name)).\(ext)")
            try FileCommands.saveDoc(s, one, path, save)
            files.append(.string(path))
        }
        if files.isEmpty { throw EngineError.bad(cmd, "no matching layer comps") }
        return ["files": .array(files)]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("layerComp.new", "New Layer Comp…",
                          params: #"{"name":str="Layer Comp N","comment":str="","visibility":bool=true,"position":bool=true,"appearance":bool=true} → {comp}"#,
                          module: m, enabled: Pre.hasDoc, run: newComp))
        r.add(CommandSpec("layerComp.update", "Update Layer Comp",
                          params: #"{"comp":id|name|"*"? (default: last applied; "*" = all),"what":"all|visibility|position|appearance"="all"}"#,
                          module: m, enabled: hasComps, run: updateComp))
        r.add(CommandSpec("layerComp.apply", "Apply Layer Comp", params: #"{"comp":id|name? (default: last applied)} → {comp, missingLayers}"#,
                          module: m, enabled: hasComps, run: applyCmd))
        r.add(CommandSpec("layerComp.previous", "Apply Previous Layer Comp", params: "{}", module: m, enabled: hasComps) { s, _ in try step(s, -1) })
        r.add(CommandSpec("layerComp.next", "Apply Next Layer Comp", params: "{}", module: m, enabled: hasComps) { s, _ in try step(s, 1) })
        r.add(CommandSpec("layerComp.delete", "Delete Layer Comp", params: #"{"comp":id|name?}"#, module: m, enabled: hasComps, run: delete))
        r.add(CommandSpec("layerComp.duplicate", "Duplicate Layer Comp", params: #"{"comp":id|name?} → {comp}"#, module: m, enabled: hasComps, run: duplicate))
        r.add(CommandSpec("layerComp.rename", "Rename Layer Comp", params: #"{"comp":id|name?,"name":str}"#, module: m, enabled: hasComps, run: rename))
        r.add(CommandSpec("layerComp.setComment", "Layer Comp Comment", params: #"{"comp":id|name?,"comment":str}"#, module: m, enabled: hasComps, run: setComment))
        r.add(CommandSpec("layerComp.setOptions", "Layer Comp Options…",
                          params: #"{"comp":id|name?,"visibility":bool?,"position":bool?,"appearance":bool?,"name":str?,"comment":str?}"#,
                          module: m, enabled: hasComps, run: setOptions))
        r.add(CommandSpec("layerComp.restoreLastDocumentState", "Restore Last Document State", params: "{}", module: m, enabled: hasLastState, run: restoreLast))
        r.add(CommandSpec("layerComp.updateWarnings", "Layer Comp Warnings",
                          params: #"{"clear":bool=false (drop states of deleted layers)} → {warnings:[{comp,name,missingLayers}],count}"#,
                          module: m, enabled: Pre.hasDoc, run: updateWarnings))
        r.add(CommandSpec("layerComp.list", "List Layer Comps",
                          params: "{} → {comps:[{id,name,comment,visibility,position,appearance,layers,missingLayers}],lastApplied,hasLastDocumentState}",
                          module: m, journal: false, enabled: Pre.hasDoc, run: list))
        r.add(CommandSpec("file.export.layerCompsToFiles", "Layer Comps to Files…", menu: ["File", "Export"],
                          params: #"{"dir":folder,"format":"png|jpg|psd|tiff|…"="png","prefix":str=document name,"selectedOnly":bool=false (only the last applied comp),"comps":[id]?,"quality":0..12?} → {files}"#,
                          module: m, enabled: hasComps, run: compsToFiles))
    }
}
