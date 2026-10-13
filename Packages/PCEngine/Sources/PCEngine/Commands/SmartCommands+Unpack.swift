// Port of photocraft-engine (crates/engine/src/smart_cmds/unpack.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer › Smart Objects › Convert to Layers: unpacks a smart object's contents back into layers
// at its placement, as Photoshop does. Several layers land in a group named after the smart
// object, which carries its opacity, blend mode, masks and style; a single layer replaces the
// smart object directly when those fold into it without changing the look. Smart filters are
// discarded (the result reports how many).

import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCIOSmart
import PCPlatform

extension SmartCommands {
    /// The smart object's contents as layers in `doc`'s colour model, profile and depth, still in
    /// source pixel coordinates. A Background becomes a normal layer (it can't sit above others).
    static func unpackContents(_ s: Session, _ doc: Document, _ sm: SmartObject, intent: RenderingIntent, bpc: Bool) throws -> [Layer] {
        guard let (name, bytes) = try authorizedSourceBytes(s, "layer.smartObjects.convertToLayers", doc.metadata, sm.source) else {
            throw other("the smart object's contents are unavailable (missing linked file?)")
        }
        var src = try decodeSource(name, bytes, services: s.services)
        let mode = doc.pixelFormat.mode
        if src.pixelFormat.mode != mode || src.iccProfile != doc.iccProfile {
            try ColorCommands.convertDocument(&src, to: ColorCommands.documentProfile(doc), intent: intent, bpc: bpc)
            if src.pixelFormat.mode != mode {
                throw other("can't convert the smart object's contents to the document's \(doc.mode) mode")
            }
        }
        if src.depth != doc.depth {
            var layers = src.layers
            ImageCommands.convertLayersDepth(&layers, doc.depth)
            src.layers = layers
        }
        let backgroundId = src.background?.id
        var layers = src.layers
        for i in layers.indices {
            if layers[i].id == backgroundId {
                layers[i].name = "Layer 0"
                layers[i].locks = Locks()
            }
            embedNested(src.metadata, &layers[i])
        }
        return layers
    }

    /// Nested PSD placed layers find their files in the contents' own global blocks, which stay
    /// behind: embed those sources so the nested smart objects keep rendering in the document.
    static func embedNested(_ meta: Metadata, _ l: inout Layer) {
        if case .smart(let sm) = l.content, case .linked(let path) = sm.source, let f = Linked.findLinkedFile(meta, path) {
            l.withSmartObject { $0.source = .embedded(fileName: f.fileName, bytes: f.bytes) }
            detachPSD(&l)
        }
        l.withChildren { cs in for i in cs.indices { embedNested(meta, &cs[i]) } }
    }

    /// Moves unpacked layers from source pixels to where the smart object placed them: an exact
    /// shift for whole-pixel moves, else its transform (type, shapes and nested smart objects
    /// stay live; Distort and Perspective need them rasterized, as Free Transform does).
    static func unpackPlace(_ s: Session, _ doc: Document, _ sm: SmartObject, _ layers: inout [Layer]) throws {
        if let w = sm.warp, !w.isIdentity {
            throw other("a warped smart object can't be converted to layers; rasterize it instead (Layer › Smart Objects › Rasterize)")
        }
        let t = sm.transform
        func whole(_ v: Double) -> Bool { abs(v - v.rounded()) < 1e-9 }
        if sm.perspective == nil && [t.a - 1, t.b, t.c, t.d - 1].allSatisfy({ abs($0) < 1e-9 }) && whole(t.e) && whole(t.f) {
            // Saturating: a placement that far out moves the layers off any canvas either way.
            let (dx, dy) = (TransformCommands.i32(t.e.rounded()), TransformCommands.i32(t.f.rounded()))
            for i in layers.indices { shiftLayer(&layers[i], dx, dy) }
            return
        }
        // Unlike a whole-pixel shift, this path re-renders nested smart objects from their
        // sources. Check every read before transforming anything.
        if s.authorize != nil {
            var pending = layers
            while let l = pending.popLast() {
                if case .smart(let nested) = l.content { try authorizeSource(s, "layer.smartObjects.convertToLayers", doc, nested.source) }
                pending += l.children ?? []
            }
        }
        let h = TransformCommands.placement(sm)
        let affine: PCAffine? = sm.perspective == nil ? sm.transform : nil
        for i in layers.indices {
            try released(&layers[i]) { l in try TransformCommands.transformLayer(nil, Locks(), &l, h, affine, .bicubic) }
            TransformCommands.refreshText(doc, &layers[i], services: s.services)
        }
    }

    /// Runs `f` with every lock and mask link in `l`'s tree released, so a transform moves all of
    /// it (the contents move as one, whatever their locks), then restores them.
    static func released(_ l: inout Layer, _ f: (inout Layer) throws -> Void) throws {
        var saved: [(Locks, Bool?, Bool?)] = []
        var tree = [l]
        ImageCommands.forEachLayer(&tree) { x in
            saved.append((x.locks, x.mask?.linked, x.vectorMask?.linked))
            x.locks = Locks()
            if x.mask != nil { x.mask?.linked = true }
            if x.vectorMask != nil { x.vectorMask?.linked = true }
        }
        l = tree[0]
        var failure: (any Error)?
        do { try f(&l) } catch { failure = error }
        // A transform keeps the tree's shape, so the walk meets the layers in the same order.
        var it = saved.makeIterator()
        tree = [l]
        ImageCommands.forEachLayer(&tree) { x in
            guard let (locks, mask, vector) = it.next() else { return }
            x.locks = locks
            if let m = mask, x.mask != nil { x.mask?.linked = m }
            if let v = vector, x.vectorMask != nil { x.vectorMask?.linked = v }
        }
        l = tree[0]
        if let failure { throw failure }
    }

    /// Whether the smart layer's own properties fold into its one unpacked layer `c` without
    /// changing the look: nothing on the smart layer acts on `c`'s composite (masks, style, fill
    /// opacity, Blend If, channel exclusions), and `c` blends normally and doesn't look at what's
    /// beneath it (alone in the smart object, it lands on transparency).
    static func foldable(_ so: Layer, _ c: Layer) -> Bool {
        so.mask == nil && so.vectorMask == nil && (!so.effects.enabled || so.effects.items.isEmpty) && so.fillOpacity >= 1
            && so.blendIf.isDefault && so.excludedChannels == 0 && !c.clipped && (c.blend == .normal || c.blend == .passThrough)
            && c.blendIf.isDefault && c.excludedChannels == 0
    }

    /// What replaces smart layer `so`: its one unpacked layer with `so`'s properties folded in,
    /// or a group named after it that carries them (isolated like the smart object, never
    /// pass-through).
    static func unpacked(_ so: Layer, _ layers: [Layer]) -> Layer {
        let blend: BlendMode = so.blend == .passThrough ? .normal : so.blend
        if layers.count == 1, var l = layers.first, foldable(so, l) {
            l.name = so.name
            l.visible = l.visible && so.visible
            l.opacity *= so.opacity
            l.blend = blend
            l.clipped = so.clipped
            l.locks = so.locks
            l.label = so.label
            l.linkGroup = so.linkGroup
            return l
        }
        var g = so
        g.id = .fresh()
        g.psdId = nil
        g.blend = blend
        g.content = .group(LayerGroup(children: layers, expanded: true, artboard: nil))
        detachPSD(&g)
        return g
    }

    /// Gives `l` and its descendants fresh ids where `taken` already holds theirs.
    static func freshenTaken(_ l: inout Layer, _ taken: inout Set<LayerId>) {
        if taken.contains(l.id) { l.id = .fresh() }
        taken.insert(l.id)
        l.withChildren { cs in for i in cs.indices { freshenTaken(&cs[i], &taken) } }
    }

    static func convertToLayers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let c = ColorCommands.settings(s)
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        guard let so = doc.layer(id) else { throw EngineError.noLayer(id) }
        let sm = try smart(doc, id)
        var layers = try unpackContents(s, doc, sm, intent: c.renderingIntent, bpc: c.bpc)
        try unpackPlace(s, doc, sm, &layers)
        let discarded = sm.smartFilters.count
        var out = unpacked(so, layers)
        // Contents keep their layer ids; a second instance unpacked in the same document (or a
        // layer since added with a reused id) must not share them.
        var taken = Set(doc.allLayerIds)
        freshenTaken(&out, &taken)
        let (newId, group) = (out.id, out.isGroup)
        try s.edit("Convert to Layers") { doc, active in
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            doc.insertAbove(id, out)
            doc.remove(id)
            active = newId
        }
        return ["layer": .id(newId), "group": .bool(group), "discardedSmartFilters": .int(discarded)]
    }
}
