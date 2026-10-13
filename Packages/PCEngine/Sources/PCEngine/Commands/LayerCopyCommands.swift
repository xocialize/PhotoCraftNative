// Port of photocraft-engine (crates/engine/src/layer_copy_cmds.rs, with image_cmds.rs `for_each_surface`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Copy layers into another open document (#589): what Photoshop does when layers are dragged from
// the Layers panel, or with the Move tool from the canvas, onto another document's tab or window.
// Photoshop has no menu item for it; `layer.copyToDocument` is the command the drag dispatches and
// agents call. The copies keep their names, content, masks, styles and blending; they land above
// the destination's active layer as one history step there, and the destination becomes the
// active document. Pixels are converted to the destination's bit depth. Converting between colour
// models or profiles is color_cmds' `convert_document`, which this build doesn't have yet: such a
// copy is refused with a message saying so (same mode and equivalent profiles copy as is).

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

enum LayerCopyCommands: CommandModule {
    static let name = "layer_copy_cmds"
    static let cmd = "layer.copyToDocument"

    static func bad(_ msg: String) -> EngineError { .bad(cmd, msg) }

    static let enabled: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        guard d.activeLayer != nil else { return "no active layer" }
        return s.documents.count < 2 ? "no other document is open" : nil
    }

    /// A document index param (nil when absent), checked against the open documents.
    static func docIndex(_ s: Session, _ p: JSONValue, _ key: String) throws -> Int? {
        guard let v = p[key] else { return nil }
        guard let i = v.uint64Value.flatMap({ Int(exactly: $0) }) else { throw bad("`\(key)` must be a document index") }
        if i >= s.documents.count { throw bad("no document \(i) (there are \(s.documents.count))") }
        return i
    }

    /// An `[x, y]` param of finite numbers within ±10⁷ pixels.
    static func point(_ p: JSONValue, _ key: String) throws -> SIMD2<Double>? {
        guard let v = p[key] else { return nil }
        if let a = v.arrayValue, a.count == 2, let x = a[0].doubleValue, let y = a[1].doubleValue,
           x.isFinite, y.isFinite, abs(x) <= 1e7, abs(y) <= 1e7 {
            return SIMD2(x, y)
        }
        throw bad("`\(key)` must be [x, y] (pixels)")
    }

    /// Modes whose layers convert through the colour engine (photocraft `layered`).
    static func layered(_ mode: ColorMode) -> Bool {
        switch mode {
        case .rgb, .grayscale, .cmyk, .lab: true
        default: false
        }
    }

    /// Rust's `{:?}` of a colour mode, as photocraft's messages print it.
    static func modeDebugName(_ m: ColorMode) -> String {
        switch m {
        case .bitmap: "Bitmap"
        case .grayscale: "Grayscale"
        case .indexed: "Indexed"
        case .rgb: "Rgb"
        case .cmyk: "Cmyk"
        case .lab: "Lab"
        case .multichannel: "Multichannel"
        case .duotone: "Duotone"
        }
    }

    static func center(_ r: PixelRect) -> SIMD2<Double> {
        SIMD2((Double(r.x0) + Double(r.x1)) / 2, (Double(r.y0) + Double(r.y1)) / 2)
    }

    /// photocraft `image_cmds::for_each_surface`: every pixel surface of a layer tree (masks
    /// when `masks`; the flag passed to `f` says the surface is a mask).
    static func eachSurface(_ layers: inout [Layer], masks: Bool, _ f: (inout Surface, Bool) -> Void) {
        for i in layers.indices {
            if masks, var m = layers[i].mask {
                f(&m.surface, true)
                layers[i].mask = m
            }
            if var fc = layers[i].fillCache {
                f(&fc.surface, false)
                layers[i].fillCache = fc
            }
            switch layers[i].content {
            case .raster: layers[i].withRaster { f(&$0, false) }
            case .text: layers[i].withText { t in if var c = t.cache { f(&c, false); t.cache = c } }
            case .shape: layers[i].withShape { sh in if var c = sh.cache { f(&c, false); sh.cache = c } }
            case .smart:
                layers[i].withSmartObject { sm in
                    if var c = sm.cache { f(&c, false); sm.cache = c }
                    // Selection-derived smart-filter masks live in document coordinates (#3077).
                    if masks, var m = sm.filterMask { f(&m.surface, true); sm.filterMask = m }
                }
            case .group: layers[i].withChildren { eachSurface(&$0, masks: masks, f) }
            default: break
            }
        }
    }

    /// The working profile of a colour mode: the session's Color Settings when they name a
    /// built-in profile, else the mode's default.
    static func workingProfile(_ s: Session, _ mode: ColorMode) -> ICCProfile {
        let key: String? = switch mode {
        case .rgb, .indexed, .multichannel: "colorSettings.workingRgb"
        case .cmyk: "colorSettings.workingCmyk"
        case .grayscale, .bitmap, .duotone: "colorSettings.workingGray"
        case .lab: nil
        }
        if let key, let id = s.preferences[key]?.stringValue, let b = BuiltinProfile.from(id: id), b.profile.colorMode?.colorChannels == mode.colorChannels {
            return b.profile
        }
        return BuiltinProfile.defaultProfile(for: mode)
    }

    /// photocraft `color_cmds::document_profile`: the embedded profile when it fits the mode, else
    /// the working profile.
    static func documentProfile(_ s: Session, _ doc: Document) -> ICCProfile {
        if let bytes = doc.iccProfile, let p = try? ICCProfile(data: Data(bytes)), p.colorMode?.colorChannels == doc.mode.colorChannels,
           (p.colorMode == .lab) == (doc.mode == .lab) {
            return p
        }
        return workingProfile(s, doc.mode)
    }

    /// Readies `copies` (a scratch document of the source's colour holding duplicated layers) for
    /// landing in `dest`: link groups and smart-object contents ids are remapped so the copies
    /// never join groups or objects already in `dest` (keeping only the sharing within the
    /// batch), and the pixels convert to `dest`'s bit depth (photocraft `adapt_copies`).
    static func adaptCopies(_ s: Session, _ copies: inout Document, _ dest: Document) throws {
        // Link-group IDs are scoped to a document (#3045): remap each imported group once.
        var used = Set(dest.walk().compactMap(\.layer.linkGroup))
        guard var nextGroup = dest.unusedLinkGroup() else { throw EngineError.other("no free linked-layer group id") }
        let groups = copies.walk().compactMap { e in e.layer.linkGroup.map { (e.layer.id, $0) } }
        var remapped: [UInt64: UInt64] = [:]
        for (_, group) in groups where remapped[group] == nil {
            while used.contains(nextGroup) { nextGroup = nextGroup == .max ? 1 : nextGroup + 1 }
            remapped[group] = nextGroup
            used.insert(nextGroup)
            nextGroup = nextGroup == .max ? 1 : nextGroup + 1
        }
        for (id, group) in groups { copies.updateLayer(id) { $0.linkGroup = remapped[group] } }
        var contents: [SmartContentsId: SmartContentsId] = [:]
        let smartIds = copies.walk().filter { if case .smart = $0.layer.content { true } else { false } }.map(\.layer.id)
        for id in smartIds {
            copies.updateLayer(id) { l in
                l.withSmartObject { sm in
                    let fresh = contents[sm.contentsId] ?? SmartContentsId.fresh()
                    contents[sm.contentsId] = fresh
                    sm.contentsId = fresh
                }
            }
        }
        if copies.mode != dest.mode || copies.iccProfile != dest.iccProfile {
            let same = copies.mode == dest.mode && documentProfile(s, copies).sameColors(as: documentProfile(s, dest))
            if !same {
                let c = ColorCommands.settings(s)
                try ColorCommands.convertDocument(&copies, to: ColorCommands.documentProfile(dest), intent: c.renderingIntent, bpc: c.bpc)
            }
        }
        if copies.depth != dest.depth {
            let depth = dest.depth
            eachSurface(&copies.layers, masks: true) { surf, _ in
                surf = surf.convertedAny(to: surf.format.withSample(depth))
            }
        }
    }

    /// Moves every layer of `copies` by whole pixels (content, masks, vectors and smart placement).
    static func translateCopies(_ copies: inout Document, _ dx: Int32, _ dy: Int32) {
        if dx == 0 && dy == 0 { return }
        let snapshot = copies
        for i in copies.layers.indices {
            copies.updateLayer(at: [i]) { LayerOps.translateLayer(snapshot, &$0, dx, dy) }
        }
    }

    static func clampedInt32(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        return Int32(min(max(v, Double(Int32.min)), Double(Int32.max)))
    }

    /// `layer.copyToDocument`.
    static func copyToDocument(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let dest = try docIndex(s, p, "document") else { throw bad("missing `document` (the destination's index)") }
        let src: Int
        if let i = try docIndex(s, p, "source") {
            src = i
        } else {
            guard let a = s.activeIndex else { throw EngineError.noDocument }
            src = a
        }
        if src == dest { throw bad("the destination is the source document (use layer.duplicate)") }
        let from = s.documents[src], to = s.documents[dest]
        let sdoc = from.doc, ddoc = to.doc
        var ids: [LayerId]
        if let v = p["layers"] {
            guard let a = v.arrayValue else { throw bad("`layers` must be an array of layer ids") }
            ids = []
            for x in a {
                guard let n = x.uint64Value else { throw bad("`layers` must be an array of layer ids") }
                ids.append(LayerId(n))
            }
        } else {
            ids = from.selectedLayers
        }
        if let missing = ids.first(where: { sdoc.layer($0) == nil }) { throw EngineError.noLayer(missing) }
        ids = LayerOps.topLevel(sdoc, ids)
        if ids.isEmpty { throw bad("no layers to copy") }
        for (doc, role) in [(sdoc, "source"), (ddoc, "destination")] where !layered(doc.mode) {
            throw EngineError.other("layers can't be copied with a \(modeDebugName(doc.mode)) \(role) document")
        }
        // The copies, bottom to top, in a scratch document of the source's colour.
        var copies = Document(name: "", size: sdoc.size, mode: sdoc.mode, depth: sdoc.depth)
        copies.iccProfile = sdoc.iccProfile
        // Type re-lays out at the source's resolution, so it keeps its size in pixels.
        copies.resolutionDpi = sdoc.resolutionDpi
        var layers: [Layer] = []
        for id in ids {
            guard let srcLayer = sdoc.layer(id) else { throw EngineError.noLayer(id) }
            var l = srcLayer.duplicate()
            // A dragged Background arrives as an ordinary layer (the destination keeps its own).
            if sdoc.isBackground(id) {
                l.name = ddoc.nextLayerName("Layer")
                l.locks = Locks()
            }
            layers.append(l)
        }
        if let name = p["name"]?.stringValue, !name.isEmpty, layers.count == 1 { layers[0].name = name }
        copies.layers = layers
        try adaptCopies(s, &copies, ddoc)
        // Placement: centred on the destination's canvas, centred on a point, or offset from where
        // the layers are in the source (default: the same canvas position).
        let bounds = copies.layers.compactMap(LayerOps.layerBounds).reduce(PixelRect.empty) { $0.union($1) }
        let content = bounds.isEmpty ? sdoc.bounds : bounds
        let delta: SIMD2<Double>
        if p["center"]?.boolValue ?? false {
            delta = center(ddoc.bounds) - center(content)
        } else if let at = try point(p, "at") {
            delta = at - center(content)
        } else {
            delta = try point(p, "offset") ?? .zero
        }
        let dx = clampedInt32(delta.x.rounded()), dy = clampedInt32(delta.y.rounded())
        translateCopies(&copies, dx, dy)
        let patterns = sdoc.patterns.filter { pat in !ddoc.patterns.contains { $0.id == pat.id } }
        _ = s.setActive(dest)
        let label = ids.count == 1 ? "Duplicate Layer" : "Duplicate Layers"
        let landing = copies.layers
        let new: [LayerId]
        do {
            new = try s.edit(label) { doc, active -> [LayerId] in
                doc.patterns += patterns
                var above = active
                var new: [LayerId] = []
                for l in landing {
                    let id = doc.insertAbove(above, l)
                    above = id
                    new.append(id)
                }
                active = above
                return new
            }
        } catch {
            // Nothing changed: the source stays the active document.
            _ = s.setActive(src)
            throw error
        }
        LayerMulti.reselect(s, new, active: new.last)
        return ["document": .int(dest), "layers": .ids(new), "offset": [.int(Int(dx)), .int(Int(dy))]]
    }

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(cmd, "Copy Layers to Document",
                          params: ##"{"document":index (destination),"layers":[id,…]?=the source's selected layers,"source":index?=active,"center":bool=false (centre on the destination's canvas),"at":[x,y]? (centre the copies on this point),"offset":[dx,dy]?=[0,0] (from their place in the source),"name":str? (one layer: the copy's name)}"##,
                          module: name, enabled: enabled, run: copyToDocument))
    }
}
