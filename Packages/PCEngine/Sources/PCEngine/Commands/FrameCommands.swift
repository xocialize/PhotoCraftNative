// Port of photocraft-engine (crates/engine/src/frame_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer › New › Frame from Layers and the Frame tool (K). A frame clips its contents to a shape,
// so a template can hold an image (or placeholder) cropped to the frame. It is built from existing
// primitives: a group clipped with a layer mask (a rectangle the size of the grouped layers'
// bounds, or the drawn rectangle / ellipse), the same visual result Photoshop's frames give.

import PCDocument
import PCFoundation

enum FrameCommands: CommandModule {
    static let name = "frame_cmds"
    static let m = name

    static let hasLayer: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document" }
        return !d.selectedLayerIds.isEmpty || d.activeLayer != nil ? nil : "select a layer"
    }

    /// A reveal mask that is on inside `rect` and off (hidden) everywhere else (GRAY8, like the
    /// other mask constructors).
    static func clipMask(_ rect: PixelRect) -> LayerMask {
        var mask = LayerMask.hideAll()
        let (w, h) = (rect.width, rect.height)
        if w > 0 && h > 0 {
            mask.surface.writeRegion(rect, [Float](repeating: 1, count: w * h))
            mask.surface.prune()
        }
        return mask
    }

    /// Groups the selected layers, then turns the group into a frame, as one history step: one
    /// undo takes the whole command back (#496).
    static func frameFromLayers(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var gp: [String: JSONValue] = [:]
        if let name = p["name"] { gp["name"] = name }
        let journal = s.journal.count
        let grouped = try s.execute("layer.new.groupFromLayers", .object(gp))
        do {
            let r = try frameGroup(s, grouped)
            // Fold the grouping step into the frame step.
            try? s.updateActive { _ = $0.history.purgeLast() }
            return r
        } catch {
            // The group couldn't be framed: take the grouping back, leaving nothing to redo and no
            // grouping step to record.
            _ = s.undo()
            if s.journal.count > journal { s.journal.removeSubrange(journal...) }
            try? s.updateActive { $0.history.clearRedo() }
            throw error
        }
    }

    /// Clips the group `layer.new.groupFromLayers` returned (`grouped`) to its contents' bounds.
    static func frameGroup(_ s: Session, _ grouped: JSONValue) throws -> JSONValue {
        guard let raw = grouped["layer"]?.uint64Value else { throw EngineError.other("grouping did not return a layer") }
        let gid = LayerId(raw)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let g = d.doc.layer(gid) else { throw EngineError.noLayer(gid) }
        let rect = LayerOps.layerBounds(g).flatMap { $0.isEmpty ? nil : $0 } ?? d.doc.bounds
        try s.edit("Frame from Layers") { doc, _ in
            guard doc.updateLayer(gid, { $0.mask = clipMask(rect) }) != nil else { throw EngineError.noLayer(gid) }
        }
        return ["layer": .id(gid), "frame": .rect(rect)]
    }

    /// The largest frame side (px) `layer.new.frame` accepts, as Photoshop's canvas limit.
    static let maxFrameSide: Int32 = 300_000

    /// A reveal mask that is on inside the ellipse inscribed in `rect` and off everywhere else,
    /// with 4×4-supersampled edges (as the Elliptical Marquee). Only pixels inside `area` are
    /// written.
    static func ellipseMask(_ rect: PixelRect, _ area: PixelRect) -> LayerMask {
        var mask = LayerMask.hideAll()
        let (cx, cy) = ((Double(rect.x0) + Double(rect.x1)) / 2, (Double(rect.y0) + Double(rect.y1)) / 2)
        let (rx, ry) = (Double(max(rect.width, 1)) / 2, Double(max(rect.height, 1)) / 2)
        func inside(_ x: Double, _ y: Double) -> Bool {
            let (dx, dy) = ((x - cx) / rx, (y - cy) / ry)
            return dx * dx + dy * dy <= 1
        }
        let cut = rect.intersect(area)
        if !cut.isEmpty {
            // Row by row: a pixel no sample hits keeps the hidden default.
            var row = [Float](repeating: 0, count: cut.width)
            for y in cut.y0..<cut.y1 {
                var any = false
                for x in cut.x0..<cut.x1 {
                    let (fx, fy) = (Double(x), Double(y))
                    var n = 0
                    for i in 0..<16 where inside(fx + (Double(i % 4) + 0.5) / 4, fy + (Double(i / 4) + 0.5) / 4) { n += 1 }
                    row[Int(x - cut.x0)] = Float(n) / 16
                    if n > 0 { any = true }
                }
                if any { mask.surface.writeRegion(PixelRect(x0: cut.x0, y0: y, x1: cut.x1, y1: y + 1), row) }
            }
        }
        mask.surface.prune()
        return mask
    }

    /// Frame tool (K): a new frame — a group clipped to the drawn rectangle or ellipse — as one
    /// history step. With `layer` (a pixel layer, not the Background), that layer becomes the
    /// frame's content, as when a frame is drawn over a selected pixel layer in Photoshop; else it
    /// is empty.
    static func newFrame(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.new.frame"
        func bad(_ msg: String) -> EngineError { .bad(cmd, msg) }
        func get(_ k: String) throws -> Int32 {
            guard let v = try Params.i32(cmd, p, k) else { throw bad("missing `\(k)`") }
            return v
        }
        let (x, y, w, h) = (try get("x"), try get("y"), try get("width"), try get("height"))
        if !(1...maxFrameSide).contains(w) || !(1...maxFrameSide).contains(h) {
            throw bad("`width` and `height` must be 1..=\(maxFrameSide)")
        }
        let (x1, ox) = x.addingReportingOverflow(w), (y1, oy) = y.addingReportingOverflow(h)
        if ox || oy { throw bad("the frame is outside the 32-bit coordinate range") }
        let rect = PixelRect(x0: x, y0: y, x1: x1, y1: y1)
        let ellipse: Bool
        switch p["shape"] {
        case nil: ellipse = false
        case .some(let v):
            switch v.stringValue {
            case "rectangle": ellipse = false
            case "ellipse": ellipse = true
            default: throw bad(#"`shape` must be "rectangle" or "ellipse""#)
            }
        }
        let content: LayerId?
        switch p["layer"] {
        case nil, .some(.null): content = nil
        case .some(let v):
            guard let raw = v.uint64Value else { throw bad("`layer` = \(v.serialized()) is not a layer id") }
            content = LayerId(raw)
        }
        let name = p["name"]?.stringValue
        let gid = try s.edit("New Frame") { doc, active -> LayerId in
            let mask = ellipse ? ellipseMask(rect, doc.bounds) : clipMask(rect.intersect(doc.bounds))
            let groupName = name ?? doc.nextLayerName("Frame")
            let gid: LayerId
            if let id = content {
                guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
                guard case .raster = l.content, !doc.isBackground(id) else {
                    throw bad("only a pixel layer (not the Background) can go in a frame")
                }
                gid = doc.insertAbove(id, Layer.group(groupName, []))
                guard let child = doc.remove(id) else { throw EngineError.noLayer(id) }
                guard (doc.updateLayer(gid, { $0.withChildren { $0.append(child) } }) ?? nil) != nil else { throw EngineError.noLayer(gid) }
                try LayerOps.checkGroupDepth(doc, "New Frame")
            } else {
                gid = doc.insertAbove(active, Layer.group(groupName, []))
            }
            guard doc.updateLayer(gid, { $0.mask = mask }) != nil else { throw EngineError.noLayer(gid) }
            active = gid
            return gid
        }
        LayerMulti.reselect(s, [gid], active: gid)
        return ["layer": .id(gid), "frame": [.int(Int(x)), .int(Int(y)), .int(Int(w)), .int(Int(h))],
                "shape": .string(ellipse ? "ellipse" : "rectangle")]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("layer.new.frame", "New Frame",
                          params: #"{"x":i32,"y":i32,"width":u32,"height":u32,"shape":"rectangle|ellipse"="rectangle","layer":id?,"name":str?} → {layer, frame:[x,y,w,h], shape}: Frame tool; a group clipped to the shape, holding pixel layer `layer` if given"#,
                          module: m, enabled: Pre.hasDoc, run: newFrame))
        r.add(CommandSpec("layer.new.frameFromLayers", "Frame from Layers", menu: ["Layer", "New"],
                          params: #"{"name":str?} → {layer, frame:[x,y,w,h]}: groups the selected layers and clips them to a frame rect"#,
                          module: m, enabled: hasLayer, run: frameFromLayers))
    }
}
