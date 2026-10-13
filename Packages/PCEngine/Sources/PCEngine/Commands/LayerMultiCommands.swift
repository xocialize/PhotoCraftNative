// Port of photocraft-engine (crates/engine/src/layer_multi_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Multi-layer selection and the commands that act on it: ⌘/⇧-click selection, Select › All /
// Deselect / Find Layers, Layer › Align and Distribute, Link Layers, Merge Layers, Group from
// Layers, Arrange › Reverse, Lock Layers and Rename Layer. The selection itself lives in
// `DocState.selectedLayerIds` (UI state, like the active layer): changing it never adds a history
// step. Every structural change is one history step.

import Foundation
import PCDocument
import PCFoundation
import PCHistory

enum LayerMulti: CommandModule {
    static let name = "layer_multi_cmds"
    static let m = name

    // MARK: Selection state

    /// Selected layers of the active document, bottom-to-top.
    static func selected(_ s: Session) -> [LayerId] { s.active?.selectedLayers ?? [] }

    /// The layers a command acts on: the `layer` param, else every selected layer, else the active
    /// layer (photocraft `targets`).
    static func targets(_ s: Session, _ p: JSONValue) throws -> [LayerId] {
        if p.has("layer") { return [try s.layerParam(p)] }
        let sel = selected(s)
        return sel.isEmpty ? [try s.layerParam(p)] : sel
    }

    /// `targets` for a command adding a layer mask: with several selected, those that can take one.
    static func maskTargets(_ s: Session, _ p: JSONValue) throws -> [LayerId] {
        let ids = try targets(s, p)
        if ids.count < 2 { return ids }
        guard let d = s.active else { throw EngineError.noDocument }
        let ok = ids.filter { id in d.doc.layer(id).map { $0.mask == nil && !d.doc.isBackground(id) } ?? false }
        if ok.isEmpty { throw EngineError.other("none of the selected layers can take a layer mask") }
        return ok
    }

    /// Replaces the layer selection without a history step.
    static func setSelection(_ s: Session, _ ids: [LayerId], active: LayerId?, anchor: LayerId?) throws {
        try s.updateActive { st in
            if let bad = (ids + (active.map { [$0] } ?? [])).first(where: { st.doc.layer($0) == nil }) { throw EngineError.noLayer(bad) }
            let a = active ?? ids.last
            st.selectedLayerIds = ids
            if let a, !st.selectedLayerIds.contains(a) { st.selectedLayerIds.append(a) }
            st.activeLayer = a
            st.layerAnchor = anchor ?? a
            st.fixSelection()
            Session.noEditRevision(&st)
        }
        s.runViewFixups()
        if let id = s.active?.id { s.emit(.layerTargetChanged(id)) }
    }

    /// After a structural edit, make `ids` the selection (what the edit's state targets).
    static func reselect(_ s: Session, _ ids: [LayerId], active: LayerId?) {
        try? s.updateActive { st in
            st.selectedLayerIds = ids
            if let a = active {
                st.activeLayer = a
                st.layerAnchor = a
            }
            st.fixSelection()
            st.history.setCurrentLayers(st.layerTarget)
        }
    }

    /// Layers panel rows, top first; closed groups hide their children unless `includeCollapsed`.
    static func rangeOrder(_ layers: [Layer], includeCollapsed: Bool, _ out: inout [LayerId]) {
        for l in layers.reversed() {
            out.append(l.id)
            if let g = l.group, g.expanded || includeCollapsed { rangeOrder(g.children, includeCollapsed: includeCollapsed, &out) }
        }
    }

    /// `layer.select`: `{"layer": id, "mode": "replace|toggle|range|add"}`.
    @Sendable static func select(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let id = Params.layerId(p) else { throw EngineError.bad("layer.select", "missing `layer`") }
        let mode = p["mode"]?.stringValue ?? "replace"
        guard let st = s.active else { throw EngineError.noDocument }
        guard st.doc.layer(id) != nil else { throw EngineError.noLayer(id) }
        var sel = st.selectedLayers
        switch mode {
        case "replace":
            try s.selectLayer(id)
        case "add":
            if !sel.contains(id) { sel.append(id) }
            try setSelection(s, sel, active: id, anchor: id)
        case "toggle":
            if sel.contains(id) {
                if sel.count == 1 { return ["selected": .ids([id])] }
                sel.removeAll { $0 == id }
                let a = st.activeLayer == id ? sel.last : st.activeLayer
                try setSelection(s, sel, active: a, anchor: a)
            } else {
                sel.append(id)
                try setSelection(s, sel, active: id, anchor: id)
            }
        case "range":
            let anchor = st.layerAnchor.flatMap { st.doc.layer($0) != nil ? $0 : nil } ?? st.activeLayer ?? id
            var order: [LayerId] = []
            rangeOrder(st.doc.layers, includeCollapsed: false, &order)
            if !order.contains(anchor) || !order.contains(id) {
                order.removeAll()
                rangeOrder(st.doc.layers, includeCollapsed: true, &order)
            }
            let a = order.firstIndex(of: anchor) ?? 0, b = order.firstIndex(of: id) ?? 0
            try setSelection(s, Array(order[min(a, b)...max(a, b)]), active: id, anchor: anchor)
        default:
            throw EngineError.bad("layer.select", "unknown mode `\(mode)`")
        }
        return ["selected": .ids(selected(s))]
    }

    // MARK: Preconditions

    static let hasSelectedLayer: CommandEnabled = { s, _ in selected(s).isEmpty ? "no layer selected" : nil }
    static let twoPlus: CommandEnabled = { s, _ in selected(s).count >= 2 ? nil : "select two or more layers" }
    static let canAlign: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.selectedLayers.isEmpty ? "no layer selected" : nil
    }
    static let canDistribute: CommandEnabled = { s, _ in selected(s).count >= 3 ? nil : "select three or more layers to distribute" }
    static let canLink: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        let sel = d.selectedLayers
        if sel.isEmpty { return "no layer selected" }
        if sel.count == 1, d.doc.layer(sel[0])?.linkGroup == nil { return "select two or more layers to link" }
        return nil
    }
    static let hasLinked: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return linkGroups(d.doc, d.selectedLayers).isEmpty ? "the selected layers are not linked" : nil
    }

    // MARK: Moving

    static func linkGroups(_ doc: Document, _ ids: [LayerId]) -> [UInt64] {
        Array(Set(ids.compactMap { doc.layer($0)?.linkGroup })).sorted()
    }

    /// `ids` plus every layer linked to one of them.
    static func withLinks(_ doc: Document, _ ids: [LayerId]) -> [LayerId] {
        let groups = Set(linkGroups(doc, ids))
        var out = ids
        if !groups.isEmpty {
            doc.forEachLayer { _, _, l in
                if let g = l.linkGroup, groups.contains(g), !out.contains(l.id) { out.append(l.id) }
            }
        }
        return out
    }

    /// Moves layers by whole pixels as the Move tool does (photocraft `move_layers`).
    static func moveLayers(_ doc: inout Document, _ moves: [(LayerId, Int32, Int32)]) throws {
        let snapshot = doc
        for (id, dx, dy) in moves where dx != 0 || dy != 0 {
            let locks = doc.effectiveLocks(id)
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            if locks.position || locks.all { throw EngineError.other("layer \"\(l.name)\" is position-locked") }
            doc.updateLayer(id) { LayerOps.translateLayer(snapshot, &$0, dx, dy) }
        }
    }

    /// Does a move aimed at the layer mask move `l`'s mask alone? Only an unlinked mask does.
    static func movesMaskAlone(_ l: Layer) -> Bool { l.mask.map { !$0.linked } ?? false }

    /// The layers a move of `roots` takes along.
    static func moveTargets(_ doc: Document, _ roots: [LayerId]) -> [LayerId] { LayerOps.topLevel(doc, withLinks(doc, roots)) }

    /// `doc` with the layers `ids` (`moveTargets`) moved by whole pixels, as `layer.translate`
    /// leaves them: the Move tool's live preview while it drags. Type, shape and smart-object
    /// pixels shift as they are instead of re-rendering (the commit re-renders them).
    static func moved(_ doc: Document, _ ids: [LayerId], _ dx: Int32, _ dy: Int32) throws -> Document {
        try movedTarget(doc, ids, dx, dy, maskTarget: false)
    }

    /// `moved` for a drag aimed at the layer mask (`maskTarget`): unlinked masks move alone.
    static func movedTarget(_ doc: Document, _ ids: [LayerId], _ dx: Int32, _ dy: Int32, maskTarget: Bool) throws -> Document {
        var out = doc
        for id in ids {
            let locks = doc.effectiveLocks(id)
            guard let l = out.layer(id) else { throw EngineError.noLayer(id) }
            if locks.position || locks.all { throw EngineError.other("layer \"\(l.name)\" is position-locked") }
            out.updateLayer(id) { l in
                if maskTarget && movesMaskAlone(l) {
                    if var m = l.mask { m.surface = m.surface.shifted(dx: dx, dy: dy); l.mask = m }
                } else {
                    shiftShown(doc, &l, dx, dy)
                }
            }
        }
        return out
    }

    /// `LayerOps.translateLayer` plus the vector side, without re-rendering anything (photocraft
    /// `shift_shown`).
    static func shiftShown(_ doc: Document, _ l: inout Layer, _ dx: Int32, _ dy: Int32) {
        let a = PCAffine.translate(Double(dx), Double(dy))
        if let r = l.effects.reference { l.effects.reference = r + SIMD2(Double(dx), Double(dy)) }
        if var m = l.mask, m.linked { m.surface = m.surface.shifted(dx: dx, dy: dy); l.mask = m }
        if var vm = l.vectorMask, vm.linked { vm.path = vm.path.transform(a); l.vectorMask = vm }
        switch l.content {
        case .raster: l.withRaster { $0 = $0.shifted(dx: dx, dy: dy) }
        case .text:
            l.withText { t in
                t.transform = a.mul(t.transform)
                if let c = t.cache { t.cache = c.shifted(dx: dx, dy: dy) }
            }
        case .shape:
            // The rendered shape is cut at the canvas: one that reaches past it renders again.
            let canvas = doc.bounds
            l.withShape { sh in
                let inside = sh.cache.map { c in
                    let b = c.contentBounds
                    return b.isEmpty || (b.x0 > canvas.x0 && b.y0 > canvas.y0 && b.x1 < canvas.x1 && b.y1 < canvas.y1)
                } ?? false
                VectorCommands.transformShape(&sh, a)
                if inside, let c = sh.cache { sh.cache = c.shifted(dx: dx, dy: dy) } else { VectorCommands.refreshShape(doc, &sh) }
            }
        case .smart:
            l.withSmartObject { sm in
                CanvasGeometry.transformPlacement(&sm, a)
                if let c = sm.cache { sm.cache = c.shifted(dx: dx, dy: dy) }
                if var m = sm.filterMask { m.surface = m.surface.shifted(dx: dx, dy: dy); sm.filterMask = m }
            }
        case .group:
            l.withGroup { g in
                if var ab = g.artboard { ab.rect = ab.rect.offsetBy(dx: dx, dy: dy); g.artboard = ab }
                for i in g.children.indices { shiftShown(doc, &g.children[i], dx, dy) }
            }
        case .adjustment, .fill:
            break
        }
    }

    /// `layer.translate`: the explicit layer, or every selected layer, plus their linked layers.
    @Sendable static func translate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let dx = try Params.i32("layer.translate", p, "dx") ?? 0, dy = try Params.i32("layer.translate", p, "dy") ?? 0
        if dx == 0 && dy == 0 { return .null }
        let roots = Params.layerId(p).map { [$0] } ?? selected(s)
        if roots.isEmpty { throw EngineError.other("no active layer") }
        let maskTarget = p["target"]?.stringValue == "mask"
        try s.edit("Move") { doc, _ in
            let alone = roots.filter { id in maskTarget && (doc.layer(id).map(movesMaskAlone) ?? false) }
            let rest = roots.filter { !alone.contains($0) }
            var ids = moveTargets(doc, rest)
            if ids.isEmpty && alone.isEmpty { throw EngineError.noLayer(roots[0]) }
            try moveLayers(&doc, ids.map { ($0, dx, dy) })
            for id in alone {
                let locks = doc.effectiveLocks(id)
                guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
                if locks.position || locks.all { throw EngineError.other("layer \"\(l.name)\" is position-locked") }
                doc.updateLayer(id) { l in if var m = l.mask { m.surface = m.surface.shifted(dx: dx, dy: dy); l.mask = m } }
                ids.append(id)
            }
            if ids.contains(where: { doc.layer($0)?.artboard != nil }) { LayerOps.fitCanvas(&doc) }
        }
        return .null
    }

    // MARK: Align and distribute

    enum Edge: String {
        case top = "topEdges", vCenter = "verticalCenters", bottom = "bottomEdges"
        case left = "leftEdges", hCenter = "horizontalCenters", right = "rightEdges"

        var vertical: Bool { self == .top || self == .vCenter || self == .bottom }

        /// The edge coordinate, doubled so centres stay integral.
        func value2(_ r: PixelRect) -> Int64 {
            let (a, b) = vertical ? (Int64(r.y0), Int64(r.y1)) : (Int64(r.x0), Int64(r.x1))
            switch self {
            case .top, .left: return 2 * a
            case .bottom, .right: return 2 * b
            case .vCenter, .hCenter: return a + b
            }
        }

        func delta(_ d: Int32) -> (Int32, Int32) { vertical ? (0, d) : (d, 0) }
    }

    static func boundedSelection(_ doc: Document, _ sel: [LayerId]) -> [(LayerId, PixelRect)] {
        LayerOps.topLevel(doc, sel).compactMap { id in doc.layer(id).flatMap(LayerOps.layerBounds).map { (id, $0) } }
    }

    /// Floor division (Rust `div_euclid` for a positive divisor).
    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

    static func align(_ s: Session, _ p: JSONValue, _ kind: String) throws -> JSONValue {
        let cmd = "layer.align.\(kind)"
        guard let edge = Edge(rawValue: kind) else { throw EngineError.bad(cmd, "unknown edge") }
        let sel = selected(s)
        let to = p["to"]?.stringValue ?? "auto"
        let moved = try s.edit("Align") { doc, _ -> Int in
            let items = boundedSelection(doc, sel)
            if items.isEmpty { throw EngineError.other("the selected layers have no content to align") }
            let target: PixelRect
            switch to {
            case "canvas": target = doc.bounds
            case "selection":
                guard let m = doc.selection else { throw EngineError.other("there is no selection to align to") }
                target = m.contentBounds
            case "auto", "layers":
                if to == "auto", sel.count == 1 {
                    target = doc.selection?.contentBounds ?? doc.bounds
                } else {
                    target = items.reduce(PixelRect.empty) { $0.isEmpty ? $1.1 : $0.union($1.1) }
                }
            default: throw EngineError.bad(cmd, "`to` must be auto|layers|selection|canvas, not `\(to)`")
            }
            if target.isEmpty { throw EngineError.other("nothing to align to") }
            let t2 = edge.value2(target)
            var moves: [(LayerId, Int32, Int32)] = []
            for (id, r) in items {
                let d = Int32(clamping: floorDiv(t2 - edge.value2(r), 2))
                let (dx, dy) = edge.delta(d)
                for l in withLinks(doc, [id]) { moves.append((l, dx, dy)) }
            }
            moves = dedupMoves(doc, moves)
            try moveLayers(&doc, moves)
            return moves.filter { $0.1 != 0 || $0.2 != 0 }.count
        }
        return ["moved": .int(moved)]
    }

    /// One move per layer (first wins), skipping layers nested in another moved layer.
    static func dedupMoves(_ doc: Document, _ moves: [(LayerId, Int32, Int32)]) -> [(LayerId, Int32, Int32)] {
        var out: [(LayerId, Int32, Int32)] = []
        for mv in moves where !out.contains(where: { $0.0 == mv.0 }) { out.append(mv) }
        let keep = Set(LayerOps.topLevel(doc, out.map(\.0)))
        return out.filter { keep.contains($0.0) }
    }

    static func distribute(_ s: Session, _ kind: String) throws -> JSONValue {
        let sel = selected(s)
        let moved = try s.edit("Distribute") { doc, _ -> Int in
            var items = boundedSelection(doc, sel)
            if items.count < 3 { throw EngineError.other("distributing needs three or more layers with content") }
            let n = items.count
            var moves: [(LayerId, Int32, Int32)] = []
            if kind == "horizontally" || kind == "vertically" {
                let v = kind == "vertically"
                func lo(_ r: PixelRect) -> Int64 { Int64(v ? r.y0 : r.x0) }
                func hi(_ r: PixelRect) -> Int64 { Int64(v ? r.y1 : r.x1) }
                items.sort { (lo($0.1) + hi($0.1), lo($0.1)) < (lo($1.1) + hi($1.1), lo($1.1)) }
                let span = hi(items[n - 1].1) - lo(items[0].1)
                let total = items.reduce(Int64(0)) { $0 + hi($1.1) - lo($1.1) }
                let gap = Double(span - total) / Double(n - 1)
                var cursor = Double(lo(items[0].1))
                for (id, r) in items {
                    let want = Int64(cursor.rounded())
                    let d = Int32(clamping: want - lo(r))
                    moves.append(v ? (id, 0, d) : (id, d, 0))
                    cursor += Double(hi(r) - lo(r)) + gap
                }
            } else {
                guard let edge = Edge(rawValue: kind) else { throw EngineError.bad("layer.distribute", "unknown kind `\(kind)`") }
                items.sort { edge.value2($0.1) < edge.value2($1.1) }
                let first = Double(edge.value2(items[0].1)), last = Double(edge.value2(items[n - 1].1))
                for (i, (id, r)) in items.enumerated() {
                    let want2 = first + (last - first) * Double(i) / Double(n - 1)
                    let d = Int32(clamping: Int64(((want2 - Double(edge.value2(r))) / 2).rounded()))
                    let (dx, dy) = edge.delta(d)
                    moves.append((id, dx, dy))
                }
            }
            moves = moves.flatMap { mv in withLinks(doc, [mv.0]).map { ($0, mv.1, mv.2) } }
            moves = dedupMoves(doc, moves)
            try moveLayers(&doc, moves)
            return moves.filter { $0.1 != 0 || $0.2 != 0 }.count
        }
        return ["moved": .int(moved)]
    }

    // MARK: Reorder

    /// Reorder one or several layers to one destination in one undoable edit (photocraft `move_to`).
    @Sendable static func moveTo(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.moveTo"
        guard let target = Params.layerId(p, "target") else { throw EngineError.bad(cmd, "missing `target`") }
        let pos = p["position"]?.stringValue ?? "above"
        guard ["above", "below", "into"].contains(pos) else { throw EngineError.bad(cmd, "position must be above, below, or into") }
        let copy = p["copy"]?.boolValue ?? false
        let batch = p["layers"]
        if batch != nil && p.has("layer") { throw EngineError.bad(cmd, "give either `layer` or `layers`, not both") }
        var requested: [LayerId] = []
        if let raw = batch {
            guard let arr = raw.arrayValue, !arr.isEmpty else { throw EngineError.bad(cmd, "`layers` must be a nonempty array of ids") }
            for item in arr {
                guard let n = item.uint64Value else { throw EngineError.bad(cmd, "every layer id must be an unsigned integer") }
                let id = LayerId(n)
                if requested.contains(id) { throw EngineError.bad(cmd, "duplicate layer id") }
                requested.append(id)
            }
        } else {
            requested = [try s.layerParam(p)]
        }
        guard let st = s.active else { throw EngineError.noDocument }
        let doc0 = st.doc
        guard let targetPath = doc0.path(of: target) else { throw EngineError.noLayer(target) }
        for id in requested where doc0.layer(id) == nil { throw EngineError.noLayer(id) }
        let movedIds = LayerOps.topLevel(doc0, requested)
        if movedIds.count == 1, movedIds[0] == target, batch == nil, !copy { return .null }
        for id in movedIds {
            guard let path = doc0.path(of: id) else { throw EngineError.noLayer(id) }
            let besideItself = copy && id == target && pos != "into"
            if targetPath.starts(with: path) && !besideItself { throw EngineError.bad(cmd, "target cannot be one of the moved layers or its descendant") }
        }
        if pos == "into", doc0.layer(target)?.isGroup != true { throw EngineError.bad(cmd, "target is not a group") }
        let originalActive = st.activeLayer
        let background = LayerOps.backgroundId(doc0)
        let (count, copies) = try s.edit(copy ? "Duplicate Layer" : "Reorder Layers") { doc, active -> (Int, [LayerId]) in
            let before = copy ? ClipGroup.Before() : ClipGroup.Before.read(doc, movedIds)
            var moved: [Layer] = []
            for id in movedIds {
                if copy {
                    moved.append(try LayerOps.layerCopy(doc, id))
                } else {
                    guard let l = doc.remove(id) else { throw EngineError.noLayer(id) }
                    moved.append(l)
                }
            }
            let copies = copy ? moved.map(\.id) : []
            for (i, l) in moved.enumerated() {
                let place: LayerPlacement
                switch pos {
                case "into": place = .top(of: target)
                case "below": place = i == 0 ? .below(target) : .above(moved[i - 1].id)
                default: place = i == 0 ? .above(target) : .above(moved[i - 1].id)
                }
                try LayerOps.insert(&doc, l, at: place, what: "Reorder Layer")
            }
            try LayerOps.checkGroupDepth(doc, "Reorder Layer")
            try LayerOps.keepBackgroundAtBottom(background, doc)
            ClipGroup.settle(&doc, placed: copy ? copies : movedIds, before: before)
            if copy {
                active = copies.last
            } else if batch != nil {
                active = originalActive.flatMap { requested.contains($0) ? $0 : nil } ?? requested.last
            } else {
                active = movedIds.first
            }
            return (movedIds.count, copies)
        }
        if copy {
            if batch != nil {
                reselect(s, copies, active: copies.last)
                return ["moved": .int(count), "layers": .ids(copies)]
            }
            return ["layer": copies.first.map { .id($0) } ?? .null]
        }
        if batch != nil {
            reselect(s, requested, active: originalActive.flatMap { requested.contains($0) ? $0 : nil } ?? requested.last)
            return ["moved": .int(count)]
        }
        return .null
    }

    // MARK: Structural commands

    static func linkLayers(_ s: Session) throws -> JSONValue {
        let sel = selected(s)
        let linked = try s.edit("Link Layers") { doc, _ -> Bool in
            let groups = sel.map { doc.layer($0)?.linkGroup }
            let first = groups.first ?? nil
            let unlink = first != nil && groups.allSatisfy { $0 == first }
            var next: UInt64?
            if !unlink {
                guard let g = doc.unusedLinkGroup() else { throw EngineError.bad("layer.linkLayers", "no free link group id is left") }
                next = g
            }
            for id in sel { guard doc.updateLayer(id, { $0.linkGroup = next }) != nil else { throw EngineError.noLayer(id) } }
            var counts: [UInt64: Int] = [:]
            doc.forEachLayer { _, _, l in if let g = l.linkGroup { counts[g, default: 0] += 1 } }
            var lonely: [LayerId] = []
            doc.forEachLayer { _, _, l in if let g = l.linkGroup, (counts[g] ?? 0) < 2 { lonely.append(l.id) } }
            for id in lonely { doc.updateLayer(id) { $0.linkGroup = nil } }
            return !unlink
        }
        return ["linked": .bool(linked)]
    }

    static func lockLayers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let sel = selected(s)
        let keys = ["transparency", "pixels", "position", "artboard", "all"]
        let given: [(String, Bool)] = keys.compactMap { k in p[k]?.boolValue.map { (k, $0) } }
        try s.edit("Lock Layers") { doc, _ in
            let allLocked = sel.allSatisfy { doc.layer($0)?.locks.all ?? false }
            let g = given.isEmpty ? [("all", !allLocked)] : given
            for id in sel {
                guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                    for (k, v) in g {
                        switch k {
                        case "transparency": l.locks.transparency = v
                        case "pixels": l.locks.pixels = v
                        case "position": l.locks.position = v
                        case "artboard": l.locks.artboard = v
                        default: l.locks.all = v
                        }
                    }
                }) != nil else { throw EngineError.noLayer(id) }
            }
        }
        return ["layers": .int(sel.count)]
    }

    static func renameLayer(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let name = p["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngineError.bad("layer.renameLayer", "missing `name`")
        }
        let id = try s.layerParam(p)
        try s.edit("Rename Layer") { doc, _ in
            guard doc.updateLayer(id, { $0.name = name }) != nil else { throw EngineError.noLayer(id) }
        }
        return .null
    }

    static func reverse(_ s: Session) throws -> JSONValue {
        let sel = selected(s)
        try s.edit("Reverse") { doc, _ in
            let background = LayerOps.backgroundId(doc)
            let ids = LayerOps.topLevel(doc, sel)
            if ids.count < 2 { throw EngineError.other("select two or more layers to reverse") }
            var paths: [LayerPath] = []
            var layers: [Layer] = []
            for id in ids {
                guard let p = doc.path(of: id), let l = doc.layer(id) else { throw EngineError.noLayer(id) }
                paths.append(p)
                layers.append(l)
            }
            var tree = doc.layers
            for (path, l) in zip(paths, layers.reversed()) { setLayer(&tree, path[...], l) }
            doc.layers = tree
            try LayerOps.keepBackgroundAtBottom(background, doc)
        }
        return .null
    }

    static func setLayer(_ ls: inout [Layer], _ path: ArraySlice<Int>, _ l: Layer) {
        guard let i = path.first, i < ls.count else { return }
        if path.count == 1 { ls[i] = l; return }
        ls[i].withChildren { setLayer(&$0, path.dropFirst(), l) }
    }

    /// Group Layers (⌘G) / Group from Layers.
    @Sendable static func groupLayers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let ids = Params.layerId(p).map { [$0] } ?? selected(s)
        if ids.isEmpty { throw EngineError.other("no layer selected") }
        let name = p["name"]?.stringValue
        let gid = try s.edit("Group Layers") { doc, active -> LayerId in
            let top = LayerOps.topLevel(doc, ids)
            guard let topmost = top.last else { throw EngineError.noLayer(LayerId(0)) }
            let gid = doc.insertAbove(topmost, .group(name ?? doc.nextLayerName("Group"), []))
            var children: [Layer] = []
            for id in top {
                guard let l = doc.remove(id) else { throw EngineError.noLayer(id) }
                children.append(l)
            }
            doc.updateLayer(gid) { $0.withChildren { $0 = children } }
            try LayerOps.checkGroupDepth(doc, "Group Layers")
            active = gid
            return gid
        }
        reselect(s, [gid], active: gid)
        return ["layer": .id(gid)]
    }

    static func mergeLayers(_ s: Session) throws -> JSONValue {
        let sel = selected(s)
        if sel.count < 2 {
            if let id = sel.first, s.active?.doc.layer(id)?.isGroup == true { return try s.execute("layer.mergeGroup", ["layer": .id(id)]) }
            return try s.execute("layer.mergeDown", .object([:]))
        }
        let renderer = s.services.renderer
        let mid = try s.edit("Merge Layers") { doc, active -> LayerId in
            let ids = LayerOps.topLevel(doc, sel)
            guard let topId = ids.last, let top = doc.layer(topId) else { throw EngineError.other("Merge Layers needs two or more layers") }
            var solo = doc
            solo.layers = ids.compactMap { doc.layer($0) }.filter(\.visible)
            if solo.layers.isEmpty { throw EngineError.other("the selected layers are all hidden") }
            let fmt = doc.pixelFormat.with(alpha: true)
            var merged = Layer.raster(top.name, format: fmt)
            merged.locks = top.locks
            let px = try Pixels.compositeLayers(solo, format: fmt, renderer: renderer)
            merged.withRaster { $0 = px }
            for id in ids.dropLast() { doc.remove(id) }
            doc.updateLayer(topId) { $0 = merged }
            active = merged.id
            return merged.id
        }
        reselect(s, [mid], active: mid)
        return ["layer": .id(mid)]
    }

    /// The next layer row below the deleted target, then the rows above it in reverse.
    static func deletionNeighbours(_ doc: Document, _ target: LayerId) -> [LayerId] {
        func rows(_ expandAll: Bool) -> [LayerId] {
            var stack = Array(doc.layers)
            var order: [LayerId] = []
            while let l = stack.popLast() {
                order.append(l.id)
                if let g = l.group, expandAll || g.expanded { stack.append(contentsOf: g.children) }
            }
            return order
        }
        var order = rows(false)
        if !order.contains(target) { order = rows(true) }
        guard let i = order.firstIndex(of: target) else { return [] }
        return Array(order[(i + 1)...]) + order[..<i].reversed()
    }

    /// Delete Layer with several layers selected.
    static func deleteSelected(_ s: Session) throws -> JSONValue {
        let sel = selected(s)
        try s.edit("Delete Layers") { doc, active in
            let ids = LayerOps.topLevel(doc, sel)
            let neighbours = active.map { deletionNeighbours(doc, $0) } ?? []
            let before = ClipGroup.Before.read(doc, ids)
            for id in ids { guard doc.remove(id) != nil else { throw EngineError.noLayer(id) } }
            ClipGroup.settle(&doc, placed: [], before: before)
            if doc.layers.isEmpty { throw EngineError.other("a document must keep at least one layer") }
            active = neighbours.first { doc.layer($0) != nil }
        }
        return ["deleted": .int(sel.count)]
    }

    /// Duplicate Layer with several layers selected: each copy goes above its original.
    static func duplicateSelected(_ s: Session, inPlace: Bool, label: String) throws -> JSONValue {
        let sel = selected(s)
        let oldActive = s.active?.activeLayer
        let (copies, a) = try s.edit(label) { doc, active -> ([LayerId], LayerId?) in
            var copies: [LayerId] = []
            var newActive: LayerId?
            for id in LayerOps.topLevel(doc, sel) {
                let dup = try LayerOps.layerCopy(doc, id)
                let nid = doc.insertAbove(id, dup)
                if !inPlace { try LayerOps.placeCopy(&doc, nid) }
                if id == oldActive { newActive = nid }
                copies.append(nid)
            }
            let a = newActive ?? copies.last
            active = a
            return (copies, a)
        }
        reselect(s, copies, active: a)
        return ["layers": .ids(copies), "layer": a.map { .id($0) } ?? .null]
    }

    /// Show/hide every selected layer in one step.
    static func setVisibleSelected(_ s: Session, _ visible: Bool) throws -> JSONValue {
        let sel = selected(s)
        try s.edit(visible ? "Show Layers" : "Hide Layers") { doc, _ in
            for id in sel { guard doc.updateLayer(id, { $0.visible = visible }) != nil else { throw EngineError.noLayer(id) } }
        }
        return .null
    }

    /// More than one layer selected (single-layer commands act on the whole set).
    static func multi(_ s: Session, _ p: JSONValue) -> Bool { !p.has("layer") && selected(s).count > 1 }

    // MARK: Registry

    static func register(into r: inout CommandRegistry) {
        let alignParams = #"{"to":"auto|layers|selection|canvas"="auto"} (auto: the selection bounds with one layer and an active selection, else the selected layers' bounds)"#
        r.add(CommandSpec("select.allLayers", "All Layers", menu: ["Select"], shortcut: "Cmd+Alt+A", module: m, enabled: Pre.hasDoc) { s, _ in
            guard let d = s.active else { throw EngineError.noDocument }
            let ids = d.doc.allLayerIds.filter { !d.doc.isBackground($0) }
            if ids.isEmpty { throw EngineError.other("there are no layers to select") }
            let a = d.activeLayer.flatMap { ids.contains($0) ? $0 : nil } ?? ids.last
            try setSelection(s, ids, active: a, anchor: nil)
            return ["selected": .int(ids.count)]
        })
        r.add(CommandSpec("select.deselectLayers", "Deselect Layers", menu: ["Select"], module: m, enabled: Pre.hasDoc) { s, _ in
            try setSelection(s, [], active: nil, anchor: nil)
            try s.updateActive { st in
                st.activeLayer = nil
                st.selectedLayerIds.removeAll()
            }
            return .null
        })
        r.add(CommandSpec("select.findLayers", "Find Layers", menu: ["Select"], shortcut: "Cmd+Alt+Shift+F", params: #"{"name":str (case-insensitive substring)}"#,
                          module: m, enabled: Pre.hasDoc) { s, p in
            guard let needle = p["name"]?.stringValue?.lowercased() else { throw EngineError.bad("select.findLayers", "missing `name`") }
            guard let d = s.active else { throw EngineError.noDocument }
            var ids: [LayerId] = []
            d.doc.forEachLayer { _, _, l in if l.name.lowercased().contains(needle) { ids.append(l.id) } }
            if ids.isEmpty { throw EngineError.other("no layer name contains \"\(needle)\"") }
            try setSelection(s, ids, active: nil, anchor: nil)
            return ["selected": .ids(ids)]
        })
        r.add(CommandSpec("layer.selectLinkedLayers", "Select Linked Layers", menu: ["Layer"], module: m, enabled: hasLinked) { s, _ in
            guard let d = s.active else { throw EngineError.noDocument }
            let groups = Set(linkGroups(d.doc, d.selectedLayers))
            var ids: [LayerId] = []
            d.doc.forEachLayer { _, _, l in if let g = l.linkGroup, groups.contains(g) { ids.append(l.id) } }
            let a = d.activeLayer.flatMap { ids.contains($0) ? $0 : nil } ?? ids.last
            try setSelection(s, ids, active: a, anchor: a)
            return ["selected": .int(ids.count)]
        })
        for (kind, label) in [("topEdges", "Top Edges"), ("verticalCenters", "Vertical Centers"), ("bottomEdges", "Bottom Edges"),
                              ("leftEdges", "Left Edges"), ("horizontalCenters", "Horizontal Centers"), ("rightEdges", "Right Edges")] {
            r.add(CommandSpec("layer.align.\(kind)", label, menu: ["Layer", "Align"], params: alignParams, module: m, enabled: canAlign) { s, p in
                try align(s, p, kind)
            })
        }
        for (kind, label) in [("topEdges", "Top Edges"), ("verticalCenters", "Vertical Centers"), ("bottomEdges", "Bottom Edges"),
                              ("leftEdges", "Left Edges"), ("horizontalCenters", "Horizontal Centers"), ("rightEdges", "Right Edges")] {
            r.add(CommandSpec("layer.distribute.\(kind)", label, menu: ["Layer", "Distribute"], module: m, enabled: canDistribute) { s, _ in
                try distribute(s, kind)
            })
        }
        r.add(CommandSpec("layer.distribute.horizontally", "Horizontally", menu: ["Layer", "Distribute"], params: "{} (equal horizontal gaps)",
                          module: m, enabled: canDistribute) { s, _ in try distribute(s, "horizontally") })
        r.add(CommandSpec("layer.distribute.vertically", "Vertically", menu: ["Layer", "Distribute"], params: "{} (equal vertical gaps)",
                          module: m, enabled: canDistribute) { s, _ in try distribute(s, "vertically") })
        r.add(CommandSpec("layer.linkLayers", "Link Layers", menu: ["Layer"], params: "{} (toggles: unlinks when the selection is already one link group)",
                          module: m, enabled: canLink) { s, _ in try linkLayers(s) })
        r.add(CommandSpec("layer.mergeLayers", "Merge Layers", menu: ["Layer"], shortcut: "Cmd+E", params: "{} (one layer selected: Merge Down)",
                          module: m, enabled: hasSelectedLayer) { s, _ in try mergeLayers(s) })
        r.add(CommandSpec("layer.new.groupFromLayers", "Group from Layers…", menu: ["Layer", "New"], params: #"{"name":str?}"#,
                          module: m, enabled: hasSelectedLayer, run: groupLayers))
        r.add(CommandSpec("layer.arrange.reverse", "Reverse", menu: ["Layer", "Arrange"], module: m, enabled: twoPlus) { s, _ in try reverse(s) })
        r.add(CommandSpec("layer.lockLayers", "Lock Layers…", menu: ["Layer"],
                          params: #"{"transparency":bool?,"pixels":bool?,"position":bool?,"artboard":bool?,"all":bool?} (none given: toggle lock all)"#,
                          module: m, enabled: hasSelectedLayer, run: lockLayers))
        r.add(CommandSpec("layer.renameLayer", "Rename Layer", menu: ["Layer"], params: #"{"layer":id?,"name":str}"#, module: m, enabled: hasSelectedLayer,
                          run: renameLayer))
    }
}
