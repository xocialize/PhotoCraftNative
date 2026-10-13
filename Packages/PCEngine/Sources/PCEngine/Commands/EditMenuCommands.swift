// Port of photocraft-engine (crates/engine/src/edit_menu_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The rest of Photoshop's Edit menu: Fade, Purge, Delete and Fill Selection, Content-Aware Scale,
// Define Brush Preset / Custom Shape, Find and Replace Text, the Preset Manager and preset
// export/import. Content-Aware Fill itself is registered by the engine's PCIntelligence glue
// (`edit.contentAwareFill`); Delete and Fill Selection runs it with its own defaults. Fade's source
// (the last filter, adjustment or paint step) is recorded by an `after` dispatch hook, as
// photocraft's `after_command` does.

import Foundation
import PCDocument
import PCFoundation
import PCPaint
import PCPlatform
import PCRender

enum EditMenuCommands: CommandModule {
    static let name = "edit_menu_cmds"
    static let m = "edit_menu_cmds"

    // MARK: - State

    /// What Edit › Fade would fade: the result of the last filter, adjustment or paint command.
    struct FadeSource: Sendable, Equatable {
        var doc: DocId
        /// Document revision right after the command; any later change disables Fade.
        var revision: UInt64
        var layer: LayerId
        var mask: Bool
        var label: String
    }

    /// A custom shape (Edit › Define Custom Shape), usable by the Custom Shape tool.
    struct CustomShape: Sendable, Hashable, Codable {
        var name: String
        var path: VectorPath
    }

    /// Find and Replace Text position: the layer and the byte range of the current match.
    struct FindCursor: Sendable, Equatable {
        var layer: LayerId
        var start: Int
        var end: Int
    }

    /// Edit-menu state kept by the session (photocraft `EditState`).
    struct EditState: Sendable {
        var fade: FadeSource?
        /// Custom shape library (the vector tools read it).
        var customShapes: [CustomShape] = []
        var findCursor: FindCursor?
    }

    enum EditStateKey: StateKey { static let defaultValue = EditState() }

    /// The custom shape library (for the Custom Shape tool).
    static func customShapes(_ s: Session) -> [CustomShape] { s.state[EditStateKey.self].customShapes }

    /// Commands whose result Edit › Fade can blend back against the previous state.
    static func fadeable(_ id: String) -> Bool {
        id.hasPrefix("filter.") || id.hasPrefix("image.adjustments.") || id.hasPrefix("paint.")
            || ["edit.fill", "edit.stroke", "edit.contentAwareFill", "image.autoTone", "image.autoContrast", "image.autoColor"].contains(id)
    }

    /// Tile identity of a surface (photocraft's COW-tile pointer fingerprint): coordinates and
    /// generations, which change exactly when a tile's bytes do.
    static func fingerprint(_ s: Surface) -> [UInt64] {
        var out: [UInt64] = [UInt64(s.tileCount)]
        s.forEachTile { c, t in out.append(UInt64(UInt32(bitPattern: c.tx)) << 32 | UInt64(UInt32(bitPattern: c.ty))); out.append(t.generation) }
        return out
    }

    /// After every successful command: remember a fadeable result (photocraft `after_command`).
    static func afterCommand(_ s: Session, _ id: String) {
        guard fadeable(id), let st = s.active, let layer = st.activeLayer else { return }
        let label = st.history.undoLabel ?? id
        var mask = false
        if let now = st.doc.layer(layer), now.mask != nil, let prev = st.history.state(st.history.pastCount - 1) {
            // The mask changed and the pixels didn't: the command painted the mask.
            let was = prev.layer(layer)
            func same(_ a: Surface?, _ b: Surface?) -> Bool {
                switch (a, b) {
                case (let a?, let b?): return fingerprint(a) == fingerprint(b)
                case (nil, nil): return true
                default: return false
                }
            }
            mask = same(now.surface, was?.surface) && !same(now.mask?.surface, was?.mask?.surface)
        }
        s.state[EditStateKey.self].fade = FadeSource(doc: st.doc.id, revision: st.revision, layer: layer, mask: mask, label: label)
    }

    // MARK: - Helpers

    static func pixelLayer(_ s: Session) -> Result<LayerId, EngineError> {
        guard let d = s.active else { return .failure(.other("no document open")) }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return .failure(.other("no active layer")) }
        guard case .raster = l.content else {
            return .failure(.other("active layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer"))
        }
        let locks = d.doc.effectiveLocks(id)
        if locks.all || locks.pixels { return .failure(.other("the layer \"\(l.name)\" is locked")) }
        return .success(id)
    }

    static func reason<T>(_ r: Result<T, EngineError>) -> String? {
        if case .failure(let e) = r { return e.description }
        return nil
    }

    // MARK: - Fade

    static let canFade: CommandEnabled = { s, _ in
        guard let st = s.active else { return "no document open" }
        guard let f = s.state[EditStateKey.self].fade else { return "nothing to fade" }
        if f.doc != st.doc.id || f.revision != st.revision || !st.history.canUndo {
            return "Fade is only available right after a filter, adjustment or painting step"
        }
        if st.doc.layer(f.layer) == nil { return "the faded layer no longer exists" }
        return nil
    }

    static func surfaceOf(_ doc: Document, _ id: LayerId, mask: Bool) -> Surface? {
        guard let l = doc.layer(id) else { return nil }
        return mask ? l.mask?.surface : l.surface
    }

    /// Blends `after` back towards `before` over `area`: `before + opacity × (B(before, after) −
    /// before)` with blend mode `mode`, premultiplied so alpha changes fade too (photocraft
    /// `fade_surface`).
    static func fadeSurface(_ before: Surface, _ after: inout Surface, _ area: PixelRect, _ mode: BlendMode, _ opacity: Float) {
        let fmt = after.format
        let n = fmt.channels
        if area.isEmpty || n == 0 { return }
        let b = before.readRegion(area)
        var a = after.readRegion(area)
        guard a.count == b.count else { return }
        let k = min(max(opacity, 0), 1)
        /// Lerps `pb` towards `pa` (`m` values each) into `out`.
        func lerpPremul(_ pb: [Float], _ pa: [Float], _ alpha: Bool) -> [Float] {
            let m = pb.count
            var out = [Float](repeating: 0, count: m)
            if !alpha {
                for c in 0..<m { out[c] = pb[c] + (pa[c] - pb[c]) * k }
                return out
            }
            let ab = pb[m - 1], aa = pa[m - 1]
            let ao = ab + (aa - ab) * k
            for c in 0..<(m - 1) {
                let pm = pb[c] * ab + (pa[c] * aa - pb[c] * ab) * k
                out[c] = ao > 1e-9 ? pm / ao : 0
            }
            out[m - 1] = ao
            return out
        }
        for i in 0..<(a.count / n) {
            let r = (i * n)..<(i * n + n)
            let pb = Array(b[r]), pa = Array(a[r])
            if mode == .normal || n == 1 {
                let o = lerpPremul(pb, pa, fmt.alpha)
                a.replaceSubrange(r, with: o)
            } else {
                let rb = PixelCodec.toRGBA(fmt, pb), ra = PixelCodec.toRGBA(fmt, pa)
                let blended = Blend.composite(mode, backdrop: rb, source: ra, opacity: 1)
                let o = lerpPremul([rb.x, rb.y, rb.z, rb.w], [blended.x, blended.y, blended.z, blended.w], true)
                let enc = PixelCodec.fromRGBA(fmt, SIMD4(o[0], o[1], o[2], o[3]))
                if enc.count >= n { a.replaceSubrange(r, with: enc[0..<n]) }
            }
        }
        after.writeRegion(area, a)
    }

    static func fade(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.fade"
        guard let src = s.state[EditStateKey.self].fade else { throw EngineError.bad(cmd, "nothing to fade") }
        let opacity = min(max(Params.float(p, "opacity", 100), 0), 100) / 100
        guard let mode = Params.blendMode(p["mode"]?.stringValue ?? "normal") else { throw EngineError.bad(cmd, "unknown blend mode") }
        guard let st = s.active else { throw EngineError.noDocument }
        guard let prev = st.history.state(st.history.pastCount - 1) else { throw EngineError.bad(cmd, "no previous state") }
        guard let before = surfaceOf(prev, src.layer, mask: src.mask) else { throw EngineError.other("the layer did not exist before this step") }
        guard let now = surfaceOf(st.doc, src.layer, mask: src.mask) else { throw EngineError.noLayer(src.layer) }
        if now.format != before.format { throw EngineError.other("can't fade a step that changed the layer's pixel format") }
        let area = before.contentBounds.union(now.contentBounds)
        try s.edit("Fade \(src.label)") { doc, _ in
            let done: Bool? = doc.updateLayer(src.layer) { l -> Bool in
                if src.mask {
                    guard var mk = l.mask else { return false }
                    fadeSurface(before, &mk.surface, area, mode, opacity)
                    mk.surface.prune()
                    l.mask = mk
                    return true
                }
                let painted: Void? = l.withRaster { (surf: inout Surface) -> Void in
                    fadeSurface(before, &surf, area, mode, opacity)
                    surf.prune()
                }
                return painted != nil
            }
            if done != true { throw EngineError.noLayer(src.layer) }
        }
        return ["faded": .string(src.label), "opacity": .float(opacity * 100), "mode": .string(mode.label)]
    }

    // MARK: - Purge

    static func historyBytes(_ s: Session, all: Bool) -> Int {
        let docs = all ? s.documents : (s.active.map { [$0] } ?? [])
        return docs.reduce(0) { $0 + $1.history.uniqueBytes($1.doc) }
    }

    /// The session's clipboards: Edit › Copy's pixels (EditCommands) and Copy Layer Style's
    /// (ExtraCommands). nil when both are empty; else the pixel clipboard's tile bytes (photocraft
    /// counts those).
    static func clipboardBytes(_ s: Session) -> Int? {
        let clip = s.state[EditCommands.ClipboardKey.self]
        if clip == nil && s.state[ExtraCommands.StyleClipboardKey.self] == nil { return nil }
        var n = 0
        clip?.surface.forEachTile { _, t in n += t.bytes.count }
        return n
    }

    static func clearClipboards(_ s: Session) {
        s.state[EditCommands.ClipboardKey.self] = nil
        s.state[ExtraCommands.StyleClipboardKey.self] = nil
    }

    /// Bytes held by the renderer's caches (effect maps and masks).
    static func cacheBytes(_ s: Session) -> Int { s.services.renderer.compositor.cpu.cacheBytes }

    static func purge(_ s: Session, _ what: String) -> JSONValue {
        var freed = 0
        var items: [String] = []
        if ["undo", "all"].contains(what), s.active?.history.canUndo == true {
            let before = historyBytes(s, all: false)
            try? s.updateActive { _ = $0.history.purgeLast() }
            freed += max(before - historyBytes(s, all: false), 0)
            items.append("undo")
        }
        if ["clipboard", "all"].contains(what), let bytes = clipboardBytes(s) {
            freed += bytes
            clearClipboards(s)
            items.append("clipboard")
        }
        if ["histories", "all"].contains(what) {
            let b = historyBytes(s, all: true)
            if s.documents.contains(where: { $0.history.canUndo || $0.history.canRedo }) {
                for i in s.documents.indices {
                    try? s.updateDocument(at: i) { st in
                        st.history.clear()
                        st.coalesce = nil
                    }
                }
                freed += b
                items.append("histories")
            }
        }
        if what == "all" {
            let fx = cacheBytes(s)
            s.services.renderer.purge()
            if fx > 0 {
                freed += fx
                items.append("render cache")
            }
            let stages = SmartCommands.purgeStackCache()
            if stages > 0 {
                freed += stages
                items.append("smart filter cache")
            }
        }
        s.state[EditStateKey.self].fade = nil
        let msg = items.isEmpty ? "nothing to purge" : "purged \(items.joined(separator: ", "))"
        return ["purged": .strings(items), "bytes": .int(freed), "message": .string(msg)]
    }

    static let canPurgeUndo: CommandEnabled = { s, _ in s.active?.history.canUndo == true ? nil : "nothing to purge" }
    static let canPurgeClipboard: CommandEnabled = { s, _ in clipboardBytes(s) != nil ? nil : "the clipboard is empty" }
    static let canPurgeHistories: CommandEnabled = { s, _ in
        s.documents.contains(where: { $0.history.canUndo || $0.history.canRedo }) ? nil : "no history to purge"
    }
    static let canPurgeAll: CommandEnabled = { s, p in
        if canPurgeHistories(s, p) == nil || canPurgeClipboard(s, p) == nil || cacheBytes(s) > 0 || SmartCommands.stackCacheBytes() > 0 { return nil }
        return "nothing to purge"
    }

    // MARK: - Delete and Fill Selection

    static let canDeleteAndFill: CommandEnabled = { s, _ in
        if let why = reason(pixelLayer(s)) { return why }
        guard let d = s.active else { return "no document open" }
        if d.doc.selection.map({ $0.contentBounds.isEmpty }) ?? true { return "make a selection around what to remove" }
        guard let caf = s.registry.spec("edit.contentAwareFill") else { return "Content-Aware Fill is not available in this build" }
        return caf.availability.reason
    }

    /// Delete and Fill Selection (#1286): Content-Aware Fill into the layer with its defaults and
    /// rectangular sampling (the whole window, as Edit › Fill does), no dialog, one history step
    /// named for this command. Runs the engine's `edit.contentAwareFill`.
    static func deleteAndFill(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let label = "Delete and Fill Selection"
        let fade = s.state[EditStateKey.self].fade
        let revision = s.active?.revision
        let r = try s.execute("edit.contentAwareFill", ["sampling": "rectangular"])
        // Fade stays with what it faded before: this command isn't fadeable.
        s.state[EditStateKey.self].fade = fade
        if s.active?.revision != revision, s.active?.history.canUndo == true {
            try s.updateActive { $0.history.setCurrentLabel(label) }
        }
        return r
    }

    // MARK: - Define Brush Preset / Custom Shape

    static func defineBrushPreset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let name: String
        if let n = p["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
            name = n
        } else {
            name = "Sampled Brush \(s.tools.presets.filter { $0.name.hasPrefix("Sampled Brush") }.count + 1)"
        }
        return try s.execute("brush.defineFromSelection", ["name": .string(name)])
    }

    /// The path Define Custom Shape uses: `"work"`, a saved path name, else the work path, the
    /// active shape layer, the active layer's vector mask, or the last saved path.
    static func currentPath(_ doc: Document, _ active: LayerId?, _ spec: String?) -> VectorPath? {
        func ok(_ p: VectorPath) -> Bool { !p.subpaths.isEmpty }
        switch spec {
        case "work"?: return doc.workPath.flatMap { ok($0) ? $0 : nil }
        case let name?: return doc.paths.first(where: { $0.name == name }).map(\.path).flatMap { ok($0) ? $0 : nil }
        case nil: break
        }
        if let p = doc.workPath, ok(p) { return p }
        if let id = active, let l = doc.layer(id) {
            if case .shape(let sh) = l.content, ok(sh.path) { return sh.path }
            if let vm = l.vectorMask, ok(vm.path) { return vm.path }
        }
        return doc.paths.last.map(\.path).flatMap { ok($0) ? $0 : nil }
    }

    static let canDefineShape: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return currentPath(d.doc, d.activeLayer, nil) == nil ? "select a path or shape layer first" : nil
    }

    static func defineCustomShape(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        guard let path = currentPath(st.doc, st.activeLayer, p["path"]?.stringValue) else { throw EngineError.bad("edit.defineCustomShape", "no such path") }
        var state = s.state[EditStateKey.self]
        let name: String
        if let n = p["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
            name = n
        } else {
            name = "Shape \(state.customShapes.count + 1)"
        }
        if let i = state.customShapes.firstIndex(where: { $0.name == name }) {
            state.customShapes[i].path = path
        } else {
            state.customShapes.append(CustomShape(name: name, path: path))
        }
        s.state[EditStateKey.self] = state
        return ["name": .string(name), "count": .int(state.customShapes.count)]
    }

    // MARK: - Find and Replace Text

    /// Unicode alphanumeric (Rust `char::is_alphanumeric`) or `_`.
    static func isWord(_ c: Unicode.Scalar?) -> Bool {
        guard let c else { return false }
        return c == "_" || c.properties.isAlphabetic || c.properties.numericType != nil
    }

    /// Byte ranges of `find` in `text` (case-insensitive unless `caseSensitive`; whole words only
    /// with `wholeWord`) (photocraft `find_matches`).
    static func findMatches(_ text: String, _ find: String, caseSensitive: Bool, wholeWord: Bool) -> [(Int, Int)] {
        if find.isEmpty { return [] }
        func norm(_ c: Unicode.Scalar) -> [UInt8] { Array((caseSensitive ? String(c) : String(c).lowercased()).utf8) }
        let needle = find.unicodeScalars.flatMap(norm)
        let scalars = Array(text.unicodeScalars)
        var offs: [Int] = []
        offs.reserveCapacity(scalars.count + 1)
        var o = 0
        for sc in scalars {
            offs.append(o)
            o += String(sc).utf8.count
        }
        offs.append(o)
        var out: [(Int, Int)] = []
        var i = 0
        while i < scalars.count {
            // Compare char by char so case folding that changes byte lengths stays aligned.
            var hay: [UInt8] = []
            var j = i
            while j < scalars.count && hay.count < needle.count {
                hay += norm(scalars[j])
                j += 1
            }
            if hay == needle {
                let before = i > 0 ? scalars[i - 1] : nil
                let after = j < scalars.count ? scalars[j] : nil
                if !wholeWord || (!isWord(before) && !isWord(after)) {
                    out.append((offs[i], offs[j]))
                    i = j
                    continue
                }
            }
            i += 1
        }
        return out
    }

    /// Type layers in Layers panel order (top first), or bottom first when searching backwards.
    static func typeLayers(_ doc: Document, forward: Bool) -> [LayerId] {
        var ids: [LayerId] = doc.walk().reversed().compactMap { e in
            if case .text = e.layer.content, !doc.locks(at: e.path).all { return e.layer.id }
            return nil
        }
        if !forward { ids.reverse() }
        return ids
    }

    static let hasTypeLayer: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return typeLayers(d.doc, forward: true).isEmpty ? "the document has no type layers" : nil
    }

    static func normText(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func pushMerge<S: Equatable>(_ out: inout [(Int, S)], _ len: Int, _ st: S) {
        if len == 0 { return }
        if let last = out.last, last.1 == st {
            out[out.count - 1].0 += len
        } else {
            out.append((len, st))
        }
    }

    /// Replaces bytes `a..<b` of a type layer's text with `new`, keeping the styles around the
    /// edit (photocraft `type_cmds::replace_text`).
    static func replaceText(_ t: inout TextLayer, _ a0: Int, _ b0: Int, _ new0: String) {
        func adjust<S: Equatable>(_ runs: [(Int, S)], _ a: Int, _ b: Int, _ ins: Int, trailingParagraph: Bool) -> [(Int, S)] {
            var out: [(Int, S)] = []
            var at = 0
            let total = runs.reduce(0) { $0 + $1.0 }
            let host: Int
            if trailingParagraph && a == b && runs.last?.0 == 0 && a == total {
                // Inserted text belongs to a styled final empty paragraph.
                host = runs.count - 1
            } else {
                var acc = 0
                var found: Int?
                for (i, r) in runs.enumerated() {
                    let (s, e) = (acc, acc + r.0)
                    acc = e
                    if a == 0 ? (e > 0 || s == 0) : (a > s && a <= e) {
                        found = i
                        break
                    }
                }
                host = found ?? 0
            }
            for (i, r) in runs.enumerated() {
                let (rs, re) = (at, at + r.0)
                at = re
                let keep = (min(max(a, rs), re) - rs) + (re - min(max(b, rs), re))
                pushMerge(&out, keep + (i == host ? ins : 0), r.1)
            }
            return out
        }
        var bytes = Array(t.text.utf8)
        let a = min(a0, bytes.count), b = max(min(b0, bytes.count), a)
        let new = normText(new0)
        var cr = t.charRuns().map { ($0.len, $0.style) }
        var pr = t.paragraphRuns().map { ($0.len, $0.style) }
        let firstC = cr.first?.1 ?? CharStyle()
        let firstP = pr.first?.1 ?? ParagraphStyle()
        let endsWithBreak = { (s: [UInt8]) in s.last == 0x0D || s.last == 0x0A }
        let trailingStyle = endsWithBreak(bytes) ? pr.last.flatMap { $0.0 == 0 ? $0.1 : nil } : nil
        let ins = Array(new.utf8)
        cr = adjust(cr, a, b, ins.count, trailingParagraph: false)
        pr = adjust(pr, a, b, ins.count, trailingParagraph: true)
        bytes.replaceSubrange(a..<b, with: ins)
        t.text = String(decoding: bytes, as: UTF8.self)
        if endsWithBreak(bytes), let style = trailingStyle { pr.append((0, style)) }
        if cr.isEmpty { cr = [(bytes.count, firstC)] }
        if pr.isEmpty { pr = [(bytes.count, firstP)] }
        t.runs = cr.map { TextRun(len: $0.0, style: $0.1) }
        t.paragraphs = pr.map { ParagraphRun(len: $0.0, style: $0.1) }
        t.syncSummary()
    }

    /// Re-renders a type layer's pixels (photocraft `type_cmds::refresh`). The PSD `TySh` data
    /// can't be regenerated without PCIO, so the stale copy is dropped (the exporter rebuilds it).
    static func refreshText(_ doc: Document, _ t: inout TextLayer) {
        TextEngine.renderLayer(&t, dpi: Double(doc.resolutionDpi), format: doc.pixelFormat)
        t.psdRaw = nil
    }

    static func textOf(_ doc: Document, _ id: LayerId) -> String? {
        guard let l = doc.layer(id), case .text(let t) = l.content else { return nil }
        return t.text
    }

    static func cursorJSON(_ id: LayerId, _ a: Int, _ b: Int) -> JSONValue { ["layer": .id(id), "start": .int(a), "end": .int(b)] }

    static func findReplace(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.findAndReplaceText"
        guard let find = p["find"]?.stringValue, !find.isEmpty else { throw EngineError.bad(cmd, "missing `find`") }
        let replace = p["replace"]?.stringValue ?? ""
        let caseSensitive = Params.bool(p, "caseSensitive", false), whole = Params.bool(p, "wholeWord", false)
        let forward = Params.bool(p, "forward", true), allLayers = Params.bool(p, "allLayers", true)
        let action = p["action"]?.stringValue ?? "changeAll"
        guard let st = s.active else { throw EngineError.noDocument }
        var layers = typeLayers(st.doc, forward: forward)
        if !allLayers {
            let active = try? s.layerParam(p)
            layers = layers.filter { $0 == active }
        }
        switch action {
        case "changeAll":
            let doc = st.doc
            let plan: [(LayerId, [(Int, Int)])] = layers.compactMap { id in
                guard let text = textOf(doc, id) else { return nil }
                let ms = findMatches(text, find, caseSensitive: caseSensitive, wholeWord: whole)
                return ms.isEmpty ? nil : (id, ms)
            }
            let count = plan.reduce(0) { $0 + $1.1.count }
            if count == 0 { return ["count": 0, "layers": 0] }
            try s.edit("Replace All Text") { doc, _ in
                let snapshot = doc
                for (id, matches) in plan {
                    doc.updateLayer(id) { l in
                        l.withText { t in
                            for (a, b) in matches.reversed() { replaceText(&t, a, b, replace) }
                            refreshText(snapshot, &t)
                        }
                    }
                }
            }
            s.state[EditStateKey.self].findCursor = nil
            return ["count": .int(count), "layers": .int(plan.count)]
        case "find", "change", "changeFind":
            let doc0 = st.doc
            var changed: (LayerId, Int, Int)?
            if action != "find", let c = s.state[EditStateKey.self].findCursor,
               let text = textOf(doc0, c.layer), findMatches(text, find, caseSensitive: caseSensitive, wholeWord: whole).contains(where: { $0 == (c.start, c.end) }) {
                try s.edit("Replace Text") { doc, _ in
                    let snapshot = doc
                    doc.updateLayer(c.layer) { l in
                        l.withText { t in
                            replaceText(&t, c.start, c.end, replace)
                            refreshText(snapshot, &t)
                        }
                    }
                }
                let end = c.start + replace.utf8.count
                s.state[EditStateKey.self].findCursor = FindCursor(layer: c.layer, start: end, end: end)
                changed = (c.layer, c.start, end)
                if action == "change" { return ["changed": cursorJSON(c.layer, c.start, end)] }
            }
            let changedJSON: JSONValue = changed.map { cursorJSON($0.0, $0.1, $0.2) } ?? .null
            // Find the next match after the cursor (wrapping through the layers).
            guard let doc = s.active?.doc else { throw EngineError.noDocument }
            let cursor = s.state[EditStateKey.self].findCursor
            let start = cursor.flatMap { c in layers.firstIndex(of: c.layer) } ?? 0
            for k in 0...layers.count {
                // `allLayers: false` with a non-type layer active leaves no layers to search (#703).
                let i = (start + k) % max(layers.count, 1)
                guard i < layers.count else { break }
                let id = layers[i]
                guard let text = textOf(doc, id) else { continue }
                let ms = findMatches(text, find, caseSensitive: caseSensitive, wholeWord: whole)
                let hit: (Int, Int)?
                if k == 0, let c = cursor, c.layer == id {
                    hit = forward ? ms.first(where: { $0.0 >= c.end }) : ms.last(where: { $0.1 <= c.start })
                } else {
                    hit = forward ? ms.first : ms.last
                }
                if let h = hit {
                    let (a, b) = h
                    s.state[EditStateKey.self].findCursor = FindCursor(layer: id, start: a, end: b)
                    try? s.selectLayer(id)
                    let bytes = Array(text.utf8)
                    let found = String(decoding: bytes[a..<b], as: UTF8.self)
                    return ["found": ["layer": .id(id), "start": .int(a), "end": .int(b), "text": .string(found)], "changed": changedJSON]
                }
            }
            s.state[EditStateKey.self].findCursor = nil
            return ["found": .null, "changed": changedJSON]
        default:
            throw EngineError.bad(cmd, "unknown action `\(action)` (find|change|changeFind|changeAll)")
        }
    }

    // MARK: - Presets

    /// Libraries the Preset Manager edits.
    static let presetKinds = ["brushes", "customShapes", "patterns"]

    /// The session pattern library, through the pattern module's `pattern.list` (empty when it
    /// isn't available in this build).
    static func libraryPatterns(_ s: Session) -> [(id: String, name: String)] {
        guard s.registry.spec("pattern.list")?.isAvailable == true, let list = (try? s.execute("pattern.list"))?.arrayValue else { return [] }
        return list.compactMap { v in
            guard v["inLibrary"]?.boolValue == true, let name = v["name"]?.stringValue else { return nil }
            return (v["id"]?.stringValue ?? name, name)
        }
    }

    static func presetNames(_ s: Session, _ kind: String) -> [String]? {
        switch kind {
        case "brushes": s.tools.presets.map(\.name)
        case "customShapes": s.state[EditStateKey.self].customShapes.map(\.name)
        case "patterns": libraryPatterns(s).map(\.name)
        default: nil
        }
    }

    static func presetIndex(_ s: Session, _ kind: String, _ p: JSONValue) throws -> Int {
        let cmd = "edit.presets.presetManager"
        guard let names = presetNames(s, kind) else {
            throw EngineError.bad(cmd, "unknown preset kind `\(kind)` (\(presetKinds.joined(separator: "|")))")
        }
        if let i = p["index"]?.uint64Value {
            guard i < UInt64(names.count) else { throw EngineError.bad(cmd, "no preset \(i)") }
            return Int(i)
        }
        guard let name = p["name"]?.stringValue else { throw EngineError.bad(cmd, "give `index` or `name`") }
        guard let i = names.firstIndex(of: name) else { throw EngineError.bad(cmd, "no preset named `\(name)`") }
        return i
    }

    /// photocraft `move_item`.
    static func moveItem<T>(_ v: inout [T], _ i: Int, _ to: Int) {
        guard i >= 0, i < v.count else { return }
        let x = v.remove(at: i)
        v.insert(x, at: min(max(to, 0), v.count))
    }

    static func presetManager(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.presets.presetManager"
        let action = p["action"]?.stringValue ?? "list"
        if action == "list" {
            let kinds = p["kind"]?.stringValue.map { [$0] } ?? presetKinds
            var out: [String: JSONValue] = [:]
            for k in kinds {
                guard let names = presetNames(s, k) else { throw EngineError.bad(cmd, "unknown preset kind `\(k)`") }
                out[k] = .strings(names)
            }
            return .object(out)
        }
        guard let kind = p["kind"]?.stringValue else { throw EngineError.bad(cmd, "missing `kind`") }
        let i = try presetIndex(s, kind, p)
        switch action {
        case "rename":
            guard let new = p["newName"]?.stringValue?.trimmingCharacters(in: .whitespaces), !new.isEmpty else { throw EngineError.bad(cmd, "missing `newName`") }
            switch kind {
            case "brushes":
                // A renamed built-in is the user's preset now.
                s.tools.presets[i].name = new
                s.tools.presets[i].builtin = false
            case "patterns":
                let pats = libraryPatterns(s)
                guard i < pats.count else { throw EngineError.bad(cmd, "no preset \(i)") }
                try s.execute("pattern.rename", ["pattern": .string(pats[i].id), "name": .string(new)])
            default:
                s.state[EditStateKey.self].customShapes[i].name = new
            }
        case "delete":
            switch kind {
            case "brushes": s.tools.presets.remove(at: i)
            case "patterns":
                let pats = libraryPatterns(s)
                guard i < pats.count else { throw EngineError.bad(cmd, "no preset \(i)") }
                try s.execute("pattern.delete", ["pattern": .string(pats[i].id)])
            default: s.state[EditStateKey.self].customShapes.remove(at: i)
            }
        case "move":
            guard let to = p["to"]?.uint64Value else { throw EngineError.bad(cmd, "missing `to`") }
            let t = Int(clamping: to)
            switch kind {
            case "brushes": moveItem(&s.tools.presets, i, t)
            case "patterns": throw EngineError.other("moving patterns needs the pattern library's own order (pattern_cmds has no move command)")
            default: moveItem(&s.state[EditStateKey.self].customShapes, i, t)
            }
        default:
            throw EngineError.bad(cmd, "unknown action `\(action)` (list|rename|delete|move)")
        }
        if kind == "brushes" { s.tools.presetsRevision += 1 }
        return [kind: .strings(presetNames(s, kind) ?? [])]
    }

    /// The `.pcpresets` file format tag.
    static let presetFormat = "photocraft-presets"

    /// photocraft `Session::load_brush_tips` without a preset store: a stored tip whose bitmap
    /// isn't loaded can't be exported.
    static func checkTips(_ b: BrushSettings) -> String? {
        for tip in [b.tip, b.dualBrush.tip] {
            if case .stored(let r) = tip, r.full == nil { return "brush tip \(r.key) is not available: no preset store is attached" }
        }
        return nil
    }

    static func exportImport(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "edit.presets.exportImportPresets"
        let kinds = p["kinds"]?.arrayValue.map { $0.compactMap(\.stringValue) } ?? ["brushes", "customShapes"]
        func want(_ k: String) -> Bool { kinds.contains(k) }
        switch p["action"]?.stringValue ?? "export" {
        case "export":
            var brushes: [BrushPreset] = []
            if want("brushes") {
                let all = Params.bool(p, "includeBuiltins", false)
                brushes = s.tools.presets.filter { !$0.builtin || all }
                for b in brushes {
                    if let e = checkTips(b.brush) { throw EngineError.bad(cmd, "brush preset `\(b.name)`: \(e)") }
                }
            }
            let shapes = want("customShapes") ? s.state[EditStateKey.self].customShapes : []
            let file: JSONValue = [
                "format": .string(presetFormat), "version": 1, "brushes": .encoded(brushes), "customShapes": .encoded(shapes),
            ]
            return ["data": file, "brushes": .int(brushes.count), "customShapes": .int(shapes.count)]
        case "import":
            guard var data = p["data"] else { throw EngineError.bad(cmd, "missing `data` (an exported preset file)") }
            if case .string(let text) = data {
                do { data = try JSONValue.parse(text) } catch { throw EngineError.bad(cmd, "not a preset file: \(error)") }
            }
            guard data.objectValue != nil else { throw EngineError.bad(cmd, "not a preset file: expected a JSON object") }
            let format: String
            switch data["format"] {
            case nil, .null?: format = ""
            case .string(let f)?: format = f
            default: throw EngineError.bad(cmd, "not a preset file: `format` must be a string")
            }
            let brushes: [BrushPreset]
            let shapes: [CustomShape]
            do {
                brushes = try data["brushes"].map { $0 == .null ? [] : try $0.decode(as: [BrushPreset].self) } ?? []
                shapes = try data["customShapes"].map { $0 == .null ? [] : try $0.decode(as: [CustomShape].self) } ?? []
            } catch { throw EngineError.bad(cmd, "not a preset file: \(error)") }
            if format != presetFormat { throw EngineError.bad(cmd, "not a preset file (format `\(format)`)") }
            var nb = 0, ns = 0
            if want("brushes") {
                for var b in brushes {
                    // Nested folders as the commands bound them.
                    b.folder = Array(b.folder.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(32))
                    if let i = s.tools.presets.firstIndex(where: { $0.name == b.name }) { s.tools.presets[i] = b } else { s.tools.presets.append(b) }
                    nb += 1
                }
                s.tools.presetsRevision += 1
            }
            if want("customShapes") {
                var st = s.state[EditStateKey.self]
                for c in shapes {
                    if let i = st.customShapes.firstIndex(where: { $0.name == c.name }) { st.customShapes[i] = c } else { st.customShapes.append(c) }
                    ns += 1
                }
                s.state[EditStateKey.self] = st
            }
            return ["brushes": .int(nb), "customShapes": .int(ns)]
        case let other:
            throw EngineError.bad(cmd, "unknown action `\(other)` (export|import)")
        }
    }

    // MARK: - Specs

    static func register(into r: inout CommandRegistry) {
        r.hooks.after.append { s, id, _ in afterCommand(s, id) }
        r.add([
            CommandSpec("edit.fade", "Fade…", menu: ["Edit"], shortcut: "Cmd+Shift+F",
                        params: ##"{"opacity":0..100=100,"mode":"normal|multiply|screen|overlay|softLight|hardLight|darken|lighten|difference|color|luminosity"}"##,
                        module: m, enabled: canFade, run: fade),
            CommandSpec("edit.purge.undo", "Undo", menu: ["Edit", "Purge"], params: "{}", module: m, enabled: canPurgeUndo) { s, _ in purge(s, "undo") },
            CommandSpec("edit.purge.clipboard", "Clipboard", menu: ["Edit", "Purge"], params: "{}", module: m, enabled: canPurgeClipboard) { s, _ in purge(s, "clipboard") },
            CommandSpec("edit.purge.histories", "Histories", menu: ["Edit", "Purge"], params: "{}", module: m, enabled: canPurgeHistories) { s, _ in
                purge(s, "histories")
            },
            CommandSpec("edit.purge.videoCache", "Video Cache", menu: ["Edit", "Purge"], params: "{}", module: m) { _, _ in
                ["purged": .array([]), "bytes": 0, "message": "nothing to purge (no video layers)"]
            },
            CommandSpec("edit.purge.all", "All", menu: ["Edit", "Purge"], params: "{}", module: m, enabled: canPurgeAll) { s, _ in purge(s, "all") },
            CommandSpec("edit.deleteAndFillSelection", "Delete and Fill Selection", params: "{}", module: m, enabled: canDeleteAndFill, run: deleteAndFill),
            CommandSpec("edit.contentAwareScale", "Content-Aware Scale", menu: ["Edit"], shortcut: "Cmd+Alt+Shift+C",
                        params: ##"{"width":px?,"height":px?,"scaleX":1..400=100,"scaleY":1..400=100,"x":px?,"y":px?,"amount":0..100=100,"protect":"none"|channel index|name,"protectSkinTones":bool=false}"##,
                        module: m, enabled: { s, _ in reason(pixelLayer(s)) }, run: contentAwareScale),
            CommandSpec("edit.defineBrushPreset", "Define Brush Preset…", menu: ["Edit"], params: ##"{"name":text}"##, module: m,
                        enabled: { s, _ in s.isEnabled("brush.defineFromSelection") ? nil : "select pixels to define a brush from" }, run: defineBrushPreset),
            CommandSpec("edit.defineCustomShape", "Define Custom Shape…", menu: ["Edit"], params: ##"{"name":text,"path":"work|<saved path name>"?}"##,
                        module: m, enabled: canDefineShape, run: defineCustomShape),
            CommandSpec("edit.findAndReplaceText", "Find and Replace Text…", menu: ["Edit"],
                        params: ##"{"find":text,"replace":text,"action":"changeAll|find|change|changeFind","caseSensitive":bool=false,"wholeWord":bool=false,"forward":bool=true,"allLayers":bool=true}"##,
                        module: m, enabled: hasTypeLayer, run: findReplace),
            CommandSpec("edit.presets.presetManager", "Preset Manager…", menu: ["Edit", "Presets"],
                        params: ##"{"action":"list|rename|delete|move","kind":"brushes|customShapes|patterns","index":n?,"name":str?,"newName":str?,"to":n?}"##,
                        module: m, run: presetManager),
            CommandSpec("edit.presets.exportImportPresets", "Export/Import Presets…", menu: ["Edit", "Presets"],
                        params: ##"{"action":"export|import","kinds":["brushes","customShapes"]?,"data":json (import),"includeBuiltins":bool=false}"##,
                        module: m, run: exportImport),
        ])
    }
}
