// Port of photocraft-engine (crates/engine/src/smart_cmds.rs, smart_cmds/{stack_cache.rs, unpack.rs}), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Smart Objects and Smart Filters: Layer › Smart Objects, Layer › Smart Filter and Filter ›
// Convert for Smart Filters. A smart object keeps its source (embedded file bytes, or a linked
// path) plus a transform and a stack of smart filters; its `cache` is the rendered appearance the
// compositors draw, re-rendered from the source after every change (`SmartCommands+Render.swift`:
// PCIO decodes the contents through the engine's glue, PCAlgo places them and runs the filters).
//
// Converting a layer embeds it as an in-memory `.pcraft` bundle of a nested document (exactly
// lossless, layered, any depth/model). PSD placed layers keep their source in the preserved
// global `lnk2` block (found by uuid), and keep Photoshop's rendering until something changes,
// so an unedited PSD still round-trips byte for byte. Edit Contents opens the contents as a
// document whose save (or close) updates every instance (`SmartCommands+Contents.swift`, with
// photocraft's link_watch `updateChanged`); Convert to Layers unpacks them
// (`SmartCommands+Unpack.swift`).

import Foundation
import PCDocument
import PCFoundation
import PCIOSmart

enum SmartCommands: CommandModule {
    static let name = "smart_cmds"
    static let m = name

    /// PSD placed-layer keys that describe the smart object's source; stale once it changes.
    static let placedKeys: [PSDKey] = ["SoLd", "PlLd", "SoLE"]

    /// Command id of a Photoshop smart filter PhotoCraft does not implement (kept verbatim from PSD).
    static let unsupportedFilter = SmartMap.unsupportedFilter

    static func other(_ msg: String) -> EngineError { .other(msg) }

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    static func baseName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    static func smart(_ doc: Document, _ id: LayerId) throws -> SmartObject {
        guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .smart(let sm) = l.content else { throw other("the layer is not a smart object") }
        return sm
    }

    /// Forgets PSD placed-layer data that no longer describes the smart object (its source
    /// changed): PSD export then writes fresh placed-layer blocks and embeds the new source.
    static func detachPSD(_ l: inout Layer) {
        l.withSmartObject { $0.psdRaw = nil }
        l.psdBlocks.removeAll { placedKeys.contains($0.key) }
    }

    /// Instances sharing contents in this document, including those inside groups.
    static func instances(_ doc: Document, _ contentsId: SmartContentsId) -> [LayerId] {
        doc.walk().compactMap { e in
            if case .smart(let sm) = e.layer.content, sm.contentsId == contentsId { return e.layer.id }
            return nil
        }
    }

    static func pathParam(_ cmd: String, _ p: JSONValue) throws -> String {
        guard let path = p["path"]?.stringValue, !path.isEmpty else { throw bad(cmd, "pass `path`") }
        return path
    }

    // MARK: Conversion

    static func convert(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let ids: [LayerId] = p["layer"]?.uint64Value.map { [LayerId($0)] } ?? LayerMulti.selected(s)
        let services = s.services
        let newId = try s.edit("Convert to Smart Object") { doc, active -> LayerId in
            let ids = LayerOps.topLevel(doc, ids)
            guard let top = ids.last else { throw other("no layer selected") }
            guard let l = doc.layer(top) else { throw EngineError.noLayer(top) }
            let so: Layer
            if ids.count == 1 {
                so = try layerToSmart(doc, l, services: services)
            } else {
                let children = try ids.map { id -> Layer in
                    guard let c = doc.layer(id) else { throw EngineError.noLayer(id) }
                    return c
                }
                so = try layersToSmart(doc, l.name, children, services: services)
            }
            let newId = so.id
            // As with Group Layers, place the result in the top selected root's parent. Insert
            // before removal so paths shifting in other parents cannot discard unselected content.
            doc.insertAbove(top, so)
            for id in ids where doc.remove(id) == nil { throw EngineError.noLayer(id) }
            active = newId
            return newId
        }
        LayerMulti.reselect(s, [newId], active: newId)
        return ["layer": .id(newId)]
    }

    // MARK: Contents

    static func viaCopy(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let current = s.active?.doc else { throw EngineError.noDocument }
        // Resolved before the edit: a linked file is read through the session's file service.
        var resolved: (String, [UInt8])?
        if case .smart(let sm)? = current.layer(id)?.content { resolved = sourceBytes(current.metadata, sm.source, fs: s.services.fileSystem) }
        let source = resolved
        return try s.edit("New Smart Object via Copy") { doc, active -> JSONValue in
            guard let src = doc.layer(id) else { throw EngineError.noLayer(id) }
            var copy = src.duplicate()
            copy.name = doc.copyName(src.name)
            let isSmart: Bool? = copy.withSmartObject { (sm: inout SmartObject) -> Bool in
                // Independent contents: resolve to embedded bytes and drop the shared PSD uuid.
                sm.contentsId = .fresh()
                if let r = source { sm.source = .embedded(fileName: r.0, bytes: r.1) }
                return true
            }
            guard isSmart != nil else { throw other("the layer is not a smart object") }
            detachPSD(&copy)
            let newId = doc.insertAbove(id, copy)
            active = newId
            return ["layer": .id(newId)]
        }
    }

    /// Swaps shared contents, keeping each instance's transform and filters, and re-renders
    /// (photocraft `set_source`).
    static func setSource(_ s: Session, _ p: JSONValue, _ label: String, keepPSD: Bool,
                          _ make: (Metadata, SmartSource) throws -> SmartSource) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let new = try make(doc.metadata, try smart(doc, id).source)
        return try setSharedSource(s, id, label, keepPSD: keepPSD, new)
    }

    static func setSharedSource(_ s: Session, _ id: LayerId, _ label: String, keepPSD: Bool, _ new: SmartSource) throws -> JSONValue {
        let services = s.services
        let (parent, contentsId) = try s.edit(label) { doc, _ -> (DocId, SmartContentsId) in
            let contentsId = try smart(doc, id).contentsId
            for instance in instances(doc, contentsId) {
                try updateSmart(&doc, instance) { $0.source = new }
                if !keepPSD { doc.updateLayer(instance) { detachPSD(&$0) } }
                try refreshOrFail(&doc, instance, services: services)
            }
            return (doc.id, contentsId)
        }
        // An old editor must not overwrite newly replaced/relinked contents on close. Keep its
        // document open, but the next Edit Contents opens the replacement source.
        s.state[SmartLinksKey.self].removeAll { $0.parent == parent && $0.contentsId == contentsId }
        return ["layer": .id(id)]
    }

    static func replaceContents(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try pathParam("layer.smartObjects.replaceContents", p)
        let bytes: [UInt8]
        do { bytes = try FileCommands.readFile(s, path) } catch { throw other("can't read \(path): \(EngineError.wrap(error))") }
        let id = try s.layerParam(p)
        return try replaceContentsBytes(s, id, baseName(path), bytes)
    }

    /// Replace Contents from a file's name and bytes: what the file pickers hand over
    /// (photocraft `replace_contents_bytes`).
    static func replaceContentsBytes(_ s: Session, _ id: LayerId, _ fileName: String, _ bytes: [UInt8]) throws -> JSONValue {
        _ = try decodeSource(fileName, bytes, services: s.services) // fail before touching the document
        return try setSharedSource(s, id, "Replace Contents", keepPSD: false, .embedded(fileName: fileName, bytes: bytes))
    }

    static func exportContents(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let path = try pathParam("layer.smartObjects.exportContents", p)
        let id = try s.layerParam(p)
        guard let doc = s.active?.doc else { throw EngineError.noDocument }
        let (name, bytes) = try contentsOf(doc, id, fs: s.services.fileSystem)
        try FileCommands.writeFile(s, path, bytes)
        return ["path": .string(path), "fileName": .string(name), "bytes": .int(bytes.count)]
    }

    static func updateAll(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let ids = d.doc.walk().compactMap { e -> LayerId? in
            if case .smart(let sm) = e.layer.content, case .linked = sm.source { return e.layer.id }
            return nil
        }
        let services = s.services
        var updated: [LayerId] = []
        try s.edit("Update All Modified Content") { doc, _ in
            for id in ids where try refresh(&doc, id, services: services) { updated.append(id) }
        }
        return ["updated": .ids(updated)]
    }

    // MARK: Smart filter editing

    /// Edits the smart filters of a smart object and re-renders it. The edit itself is instant,
    /// so its errors (a bad index, say) are reported at once; the re-render runs as a background
    /// job when started with `Session.start`, so the window keeps drawing (with progress,
    /// cancellable) while a long filter stack recomputes (photocraft `edit_filters`).
    static func editFilters(_ s: Session, _ p: JSONValue, _ label: String, _ f: (inout SmartObject) throws -> Void) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        var edited = try smart(d.doc, id)
        try f(&edited)
        let ready = edited
        let services = s.services
        return try s.editJob(label, { doc, _, ctx in
            try updateSmart(&doc, id) { $0 = ready }
            try refreshOrFail(&doc, id, services: services, ctx: ctx)
        }, finish: { _ in ["layer": .id(id)] })
    }

    static func filterIndex(_ cmd: String, _ p: JSONValue, _ sm: SmartObject) throws -> Int {
        let n = sm.smartFilters.count
        if n == 0 { throw other("the smart object has no smart filters") }
        guard let v = p["index"] else { return n - 1 }
        guard let i = v.uint64Value, i < UInt64(n) else { throw bad(cmd, "`index` must be 0..\(n) (0 = bottom filter)") }
        return Int(i)
    }

    static func setFilterVisible(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.smartFilter.setVisible"
        return try editFilters(s, p, "Smart Filter Visibility") { sm in
            let i = try filterIndex(cmd, p, sm)
            sm.smartFilters[i].visible = p["visible"]?.boolValue ?? !sm.smartFilters[i].visible
        }
    }

    static func setFilterParams(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.smartFilter.setParams"
        guard let new = p["params"] else { throw bad(cmd, "pass `params` (merged into the filter's parameters)") }
        return try editFilters(s, p, "Edit Smart Filter") { sm in
            let i = try filterIndex(cmd, p, sm)
            if sm.smartFilters[i].command == unsupportedFilter {
                throw bad(cmd, "this smart filter isn't implemented in PhotoCraft: it is kept as is (it can be hidden, moved or deleted)")
            }
            if case .object(var old) = sm.smartFilters[i].params, case .object(let n) = new {
                old.merge(n) { $1 }
                sm.smartFilters[i].params = .object(old)
            } else {
                sm.smartFilters[i].params = new
            }
        }
    }

    static func blendingOptions(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.smartFilter.blendingOptions"
        var blend: BlendMode?
        if let b = p["blend"]?.stringValue {
            guard let mode = Params.blendMode(b), mode != .passThrough else { throw bad(cmd, "unknown blend mode `\(b)`") }
            blend = mode
        }
        let opacity: Float? = p["opacity"]?.doubleValue.map { Float($0 > 1 ? $0 / 100 : $0) }
        let mode = blend
        return try editFilters(s, p, "Smart Filter Blending Options") { sm in
            let i = try filterIndex(cmd, p, sm)
            if let b = mode { sm.smartFilters[i].blend = b }
            if let o = opacity { sm.smartFilters[i].opacity = Swift.min(Swift.max(o, 0), 1) }
        }
    }

    static func deleteFilter(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try editFilters(s, p, "Delete Smart Filter") { sm in
            sm.smartFilters.remove(at: try filterIndex("layer.smartFilter.delete", p, sm))
        }
    }

    static func moveFilter(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.smartFilter.move"
        return try editFilters(s, p, "Move Smart Filter") { sm in
            let i = try filterIndex(cmd, p, sm)
            let n = sm.smartFilters.count
            guard let t = p["to"]?.uint64Value, t < UInt64(n) else { throw bad(cmd, "`to` must be 0..\(n)") }
            let f = sm.smartFilters.remove(at: i)
            sm.smartFilters.insert(f, at: Int(t))
        }
    }

    // MARK: Enablement

    /// The active layer's smart object, or why there is none (photocraft `active_smart`).
    static func activeSmart(_ s: Session) -> Result<SmartObject, EnablementReason> {
        guard let d = s.active else { return .failure(EnablementReason("no document open")) }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return .failure(EnablementReason("no active layer")) }
        guard case .smart(let sm) = l.content else {
            return .failure(EnablementReason("the active layer is \(l.content.article) \(l.content.kindName) layer, not a smart object"))
        }
        return .success(sm)
    }

    struct EnablementReason: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    static func reason(_ r: Result<SmartObject, EnablementReason>, _ check: (SmartObject) -> String?) -> String? {
        switch r {
        case .failure(let e): e.text
        case .success(let sm): check(sm)
        }
    }

    /// photocraft `has_smart`: the active layer is a smart object.
    static let hasSmart: CommandEnabled = { s, _ in reason(activeSmart(s)) { _ in nil } }

    static let hasLinked: CommandEnabled = { s, _ in
        reason(activeSmart(s)) { sm in if case .linked = sm.source { nil } else { "the smart object is embedded" } }
    }

    static let hasSmartFilters: CommandEnabled = { s, _ in
        reason(activeSmart(s)) { $0.smartFilters.isEmpty ? "the smart object has no smart filters" : nil }
    }

    static let hasFilterMask: CommandEnabled = { s, _ in
        reason(activeSmart(s)) { $0.filterMask == nil ? "the smart object has no filter mask" : nil }
    }

    static let convertible: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer, d.doc.layer(id) != nil else { return "no active layer" }
        return nil
    }

    static let notSmart: CommandEnabled = { s, p in
        if let why = convertible(s, p) { return why }
        if case .success = activeSmart(s) { return "the layer is already a smart object" }
        return nil
    }

    static let hasDocument: CommandEnabled = { s, _ in s.active == nil ? "no document open" : nil }

    // MARK: Registration

    static let so = ["Layer", "Smart Objects"]
    static let sf = ["Layer", "Smart Filter"]

    static func register(into r: inout CommandRegistry) {
        r.hooks.onClose.append { s, index in onClose(s, index) }
        r.add([
            CommandSpec("layer.smartObjects.convertToSmartObject", "Convert to Smart Object", menu: so,
                        params: #"{"layer":id?} (default: combine selected layers)"#, module: m, enabled: convertible, run: convert),
            CommandSpec("filter.convertForSmartFilters", "Convert for Smart Filters", menu: ["Filter"],
                        params: #"{"layer":id?} (default: combine selected layers)"#, module: m, enabled: notSmart, run: convert),
            CommandSpec("layer.smartObjects.newSmartObjectViaCopy", "New Smart Object via Copy", menu: so, params: #"{"layer":id?}"#,
                        module: m, enabled: hasSmart, run: viaCopy),
            CommandSpec("layer.smartObjects.rasterize", "Rasterize", menu: so, params: #"{"layer":id?}"#, module: m, enabled: hasSmart) { s, p in
                try s.execute("layer.rasterize.smartObject", p)
            },
            CommandSpec("layer.smartObjects.editContents", "Edit Contents", menu: so,
                        params: #"{"layer":id?} → opens the contents as a new document; saving (layer.smartObjects.saveContents) or closing it updates the smart object"#,
                        module: m, enabled: hasSmart, run: editContents),
            CommandSpec("layer.smartObjects.saveContents", "Save Contents", params: "{} (in an Edit Contents document)", module: m,
                        enabled: isSmartChild) { s, _ in
                guard let i = s.activeIndex else { throw EngineError.noDocument }
                return ["updated": .bool(try commitChild(s, i))]
            },
            CommandSpec("layer.smartObjects.replaceContents", "Replace Contents…", menu: so, params: #"{"layer":id?,"path":str}"#, module: m,
                        enabled: hasSmart, run: replaceContents),
            CommandSpec("layer.smartObjects.exportContents", "Export Contents…", menu: so, params: #"{"layer":id?,"path":str}"#,
                        module: m, enabled: hasSmart, run: exportContents),
            CommandSpec("layer.smartObjects.relinkToFile", "Relink to File…", menu: so, params: #"{"layer":id?,"path":str}"#, module: m,
                        enabled: hasSmart) { s, p in
                let path = try pathParam("layer.smartObjects.relinkToFile", p)
                return try setSource(s, p, "Relink to File", keepPSD: false) { _, _ in .linked(path: path) }
            },
            CommandSpec("layer.smartObjects.updateModifiedContent", "Update Modified Content", menu: so, params: #"{"layer":id?}"#, module: m,
                        enabled: hasLinked) { s, p in
                let id = try s.layerParam(p)
                let services = s.services
                try s.edit("Update Modified Content") { doc, _ in try refreshOrFail(&doc, id, services: services) }
                return ["layer": .id(id)]
            },
            CommandSpec("layer.smartObjects.updateChanged", "Update Changed Linked Content",
                        params: #"{} — re-render the active document's linked smart objects whose files changed on disk since they were last seen (size or modification time); the desktop app does this by itself every two seconds, as Photoshop does while a document is open. Files seen for the first time are only remembered. One Update Modified Content undo step per file → {updated: [layer ids]}"#,
                        module: m, enabled: hasDocument) { s, _ in try updateChanged(s) },
            CommandSpec("layer.smartObjects.updateAllModifiedContent", "Update All Modified Content", menu: so, params: "{}", module: m,
                        enabled: hasDocument) { s, _ in try updateAll(s) },
            CommandSpec("layer.smartObjects.convertToLayers", "Convert to Layers", menu: so,
                        params: #"{"layer":id?} (contents unpacked at the placement: one layer, or a group named after the smart object; smart filters are discarded)"#,
                        module: m, enabled: hasSmart, run: convertToLayers),
            CommandSpec("layer.smartObjects.convertToEmbedded", "Convert to Embedded", menu: so, params: #"{"layer":id?}"#, module: m,
                        enabled: hasLinked) { s, p in
                let fs = s.services.fileSystem
                return try setSource(s, p, "Convert to Embedded", keepPSD: true) { meta, src in
                    guard let (name, bytes) = sourceBytes(meta, src, fs: fs) else { throw other("the linked file can't be read") }
                    return .embedded(fileName: name, bytes: bytes)
                }
            },
            CommandSpec("layer.smartObjects.convertToLinked", "Convert to Linked…", menu: so, params: #"{"layer":id?,"path":str} (writes the contents there)"#,
                        module: m, enabled: hasSmart) { s, p in
                let path = try pathParam("layer.smartObjects.convertToLinked", p)
                return try setSource(s, p, "Convert to Linked", keepPSD: false) { meta, src in
                    guard let (_, bytes) = sourceBytes(meta, src, fs: s.services.fileSystem) else { throw other("the smart object's contents are unavailable") }
                    try FileCommands.writeFile(s, path, bytes)
                    return .linked(path: path)
                }
            },
            // Smart filters
            CommandSpec("layer.smartFilter.disableSmartFilters", "Disable Smart Filters", menu: sf,
                        params: #"{"layer":id?,"enabled":bool? (default: toggle)}"#, module: m, enabled: hasSmartFilters) { s, p in
                try editFilters(s, p, "Disable Smart Filters") { sm in sm.filtersEnabled = p["enabled"]?.boolValue ?? !sm.filtersEnabled }
            },
            CommandSpec("layer.smartFilter.deleteFilterMask", "Delete Filter Mask", menu: sf, params: #"{"layer":id?}"#, module: m,
                        enabled: hasFilterMask) { s, p in
                try editFilters(s, p, "Delete Filter Mask") { $0.filterMask = nil }
            },
            CommandSpec("layer.smartFilter.disableFilterMask", "Disable Filter Mask", menu: sf,
                        params: #"{"layer":id?,"enabled":bool? (default: toggle)}"#, module: m, enabled: hasFilterMask) { s, p in
                try editFilters(s, p, "Disable Filter Mask") { sm in
                    if var mk = sm.filterMask {
                        mk.enabled = p["enabled"]?.boolValue ?? !mk.enabled
                        sm.filterMask = mk
                    }
                }
            },
            CommandSpec("layer.smartFilter.blendingOptions", "Blending Options…", menu: sf,
                        params: #"{"layer":id?,"index":u32? (0 = bottom; default top),"blend":str?,"opacity":0..1?}"#, module: m,
                        enabled: hasSmartFilters, run: blendingOptions),
            CommandSpec("layer.smartFilter.clearSmartFilters", "Clear Smart Filters", menu: sf, params: #"{"layer":id?}"#, module: m,
                        enabled: hasSmartFilters) { s, p in
                try editFilters(s, p, "Clear Smart Filters") { sm in
                    sm.smartFilters.removeAll()
                    sm.filterMask = nil
                }
            },
            CommandSpec("layer.smartFilter.setVisible", "Show/Hide Smart Filter", params: #"{"layer":id?,"index":u32?,"visible":bool? (default: toggle)}"#,
                        module: m, enabled: hasSmartFilters, run: setFilterVisible),
            CommandSpec("layer.smartFilter.setParams", "Edit Smart Filter", params: #"{"layer":id?,"index":u32?,"params":{…} (merged)}"#,
                        module: m, enabled: hasSmartFilters, run: setFilterParams),
            CommandSpec("layer.smartFilter.delete", "Delete Smart Filter", params: #"{"layer":id?,"index":u32?}"#, module: m,
                        enabled: hasSmartFilters, run: deleteFilter),
            CommandSpec("layer.smartFilter.move", "Move Smart Filter", params: #"{"layer":id?,"index":u32?,"to":u32}"#, module: m,
                        enabled: hasSmartFilters, run: moveFilter),
        ])
    }
}
