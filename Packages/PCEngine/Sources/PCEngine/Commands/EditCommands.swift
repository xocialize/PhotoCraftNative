// Port of photocraft-engine (crates/engine/src/edit_cmds.rs, with its helpers channel_clip.rs and layer_copy_cmds.rs `layered`/`adapt_copies`/`translate_copies`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Everyday Photoshop commands: the clipboard (Cut / Copy / Copy Merged / Paste / Paste in Place /
// New from Clipboard), Layer via Copy / Cut, Merge Visible, Auto Tone / Contrast / Color, Toggle
// Last State, Transform Again, and the guide commands (New / Move / Delete / Clear Guides). The
// clipboard is session state (`ClipboardKey`): it is shared by every open document, so a copy in
// one tab pastes into another. Copy and Paste follow the Channels panel: a targeted colour or
// alpha channel copies as grayscale, and a paste into a colour channel, a layer mask, an alpha
// channel or the Quick Mask writes the clip's luminosity there (photocraft channel_clip.rs).
//
// Transform Again (and on a Copy) re-run `edit.transform` (EditCommands+Transform.swift).
// Deviations: pasting whole layers into a document of another colour mode
// converts their pixels through RGBA (photocraft converts the copies with color_cmds' managed ICC
// conversion, which is another module's); a profile-only difference is not converted.

import Foundation
import PCDocument
import PCFoundation
import PCHistory
import PCRender

enum EditCommands: CommandModule {
    static let name = "edit_cmds"
    static let m = name

    // MARK: Clipboard state

    /// Pixels on the session clipboard, with where they came from (for Paste in Place).
    struct Clip: Sendable, Equatable {
        var surface: Surface
        var bounds: PixelRect
        /// The copied layers themselves, when Copy took whole layers that Paste should recreate
        /// rather than rasterize: a scratch document in the source's colour holding them.
        /// `surface` still holds their pixels, for Paste Into, masks, channels and other apps.
        var layers: Document?
    }

    /// The session clipboard (photocraft `Session::clipboard`).
    enum ClipboardKey: StateKey { static let defaultValue: Clip? = nil }

    static func clipboard(_ s: Session) -> Clip? { s.state[ClipboardKey.self] }

    /// The paste commands' `"target"` param.
    static let pasteTarget = #""target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target (not pixels: the luminosity pasted into that mask or channel)"#

    // MARK: Whole-layer copies (layer-based copy, Photoshop CC 2018 on)

    /// photocraft `layer_copy_cmds::layered`: modes that keep layers.
    static func layered(_ mode: ColorMode) -> Bool { LayerCopyCommands.layered(mode) }

    /// With no selection, Copy takes the active layer whole when it is a smart object (#2428), a
    /// type or shape layer, or a group (#2670), so Paste recreates it instead of its pixels.
    static func takesWhole(_ d: DocState, _ id: LayerId) -> Bool {
        guard d.doc.selection == nil, d.selectedLayers.count <= 1, layered(d.doc.mode), let l = d.doc.layer(id) else { return false }
        switch l.content {
        case .smart, .text, .shape, .group: return true
        default: return false
        }
    }

    /// A scratch document in the source's colour, to hold copied layers.
    static func scratchDoc(_ doc: Document) -> Document {
        var copies = Document(name: "", size: doc.size, mode: doc.mode, depth: doc.depth)
        copies.iccProfile = doc.iccProfile
        copies.resolutionDpi = doc.resolutionDpi
        copies.patterns = doc.patterns
        return copies
    }

    /// The layer Copy takes whole (`takesWhole`), in a scratch document.
    static func wholeLayer(_ d: DocState, _ id: LayerId) -> Document? {
        guard takesWhole(d, id), let l = d.doc.layer(id) else { return nil }
        var copies = scratchDoc(d.doc)
        copies.layers.append(l)
        return copies
    }

    /// The layers Copy takes when several are selected and nothing is selected in the pixels
    /// (#2478): the selected layers no selected group already carries, bottom-to-top.
    static func multiCopyIds(_ d: DocState) -> [LayerId] {
        if d.doc.selection != nil || !layered(d.doc.mode) { return [] }
        let selected = d.selectedLayers
        if selected.count < 2 { return [] }
        return LayerOps.topLevel(d.doc, selected)
    }

    /// Every selected layer, whole, in a scratch document; the Background becomes an ordinary layer.
    static func wholeLayers(_ d: DocState, _ ids: [LayerId]) -> Document? {
        var copies = scratchDoc(d.doc)
        for id in ids {
            guard var l = d.doc.layer(id) else { return nil }
            if d.doc.isBackground(id) {
                l.name = "Layer 0"
                l.locks = Locks()
            }
            copies.layers.append(l)
        }
        return copies
    }

    /// Every pixel surface of a layer tree (photocraft `image_cmds::for_each_surface`); the flag
    /// says whether it is a mask.
    static func forEachSurface(_ layers: inout [Layer], masks: Bool, _ f: (inout Surface, Bool) -> Void) {
        for i in layers.indices {
            if masks, var mk = layers[i].mask { f(&mk.surface, true); layers[i].mask = mk }
            if var fc = layers[i].fillCache { f(&fc.surface, false); layers[i].fillCache = fc }
            switch layers[i].content {
            case .raster: layers[i].withRaster { f(&$0, false) }
            case .text: layers[i].withText { t in if var c = t.cache { f(&c, false); t.cache = c } }
            case .shape: layers[i].withShape { sh in if var c = sh.cache { f(&c, false); sh.cache = c } }
            case .smart:
                layers[i].withSmartObject { sm in
                    if var c = sm.cache { f(&c, false); sm.cache = c }
                    if masks, var fm = sm.filterMask { f(&fm.surface, true); sm.filterMask = fm }
                }
            case .group: layers[i].withChildren { forEachSurface(&$0, masks: masks, f) }
            default: break
            }
        }
    }

    /// Readies copied layers for `dest` (photocraft `adapt_copies`, shared with Layer › Duplicate
    /// to another document): link groups and smart-object contents get ids of their own there, and
    /// the pixels convert to `dest`'s profile (through colour management) and depth.
    static func adaptCopies(_ s: Session, _ copies: inout Document, dest: Document) throws {
        try LayerCopyCommands.adaptCopies(s, &copies, dest)
        copies.mode = dest.mode
        copies.iccProfile = dest.iccProfile
        copies.depth = dest.depth
    }

    /// Moves every copied layer by whole pixels (content, masks, vectors and smart placement).
    static func translateCopies(_ copies: inout Document, _ dx: Int32, _ dy: Int32) {
        LayerCopyCommands.translateCopies(&copies, dx, dy)
    }

    // MARK: Preconditions

    static func activeLayer(_ s: Session) -> Result<Layer, EngineError> {
        guard let d = s.active else { return .failure(.other("no document open")) }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return .failure(.other("no active layer")) }
        return .success(l)
    }

    /// Paste and New from Clipboard need only a clipboard: with no document open, they make one.
    static let hasClipOnly: CommandEnabled = { s, _ in clipboard(s) == nil ? "the clipboard is empty" : nil }

    /// Cut and Layer via Cut edit the pixels, so they need a pixel layer.
    static let hasPixels: CommandEnabled = { s, _ in
        switch activeLayer(s) {
        case .failure(let e): return e.description
        case .success(let l):
            switch l.content {
            case .raster: return nil
            case .smart: return "the smart object is not directly editable"
            default: return "the active layer has no pixels"
            }
        }
    }

    /// Copy only reads: any layer that shows pixels will do.
    static func hasLayerPixels(_ s: Session) -> String? {
        switch activeLayer(s) {
        case .failure(let e): return e.description
        case .success(let l): return l.surface == nil ? "the active layer has no pixels" : nil
        }
    }

    /// Copy: a targeted alpha channel (#2307), a layer with pixels, or one taken whole (#2670).
    static let canCopy: CommandEnabled = { s, _ in
        if copiesAlphaChannel(s) || (s.active.map { !multiCopyIds($0).isEmpty } ?? false) { return nil }
        guard let e = hasLayerPixels(s) else { return nil }
        if let d = s.active, let id = d.activeLayer, takesWhole(d, id) { return nil }
        return e
    }

    static let hasClip: CommandEnabled = { s, p in
        if let e = Pre.hasDoc(s, p) { return e }
        return clipboard(s) == nil ? "the clipboard is empty" : nil
    }

    static func activeId(_ s: Session) throws -> LayerId {
        guard let id = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    // MARK: Copy

    /// The pixels of `src` inside the selection (or all of them), as a straight-alpha surface.
    static func lift(_ src: Surface, _ sel: Surface?, _ canvas: PixelRect) -> Clip {
        let fmt = src.format
        let withAlpha = PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true)
        let area = (sel?.contentBounds ?? src.contentBounds).intersect(canvas)
        var out = Surface(format: withAlpha)
        if area.isEmpty { return Clip(surface: out, bounds: .empty, layers: nil) }
        // Only the selected area is read (#668).
        let n = withAlpha.channels
        var px: [Float]
        if fmt.alpha {
            px = src.readRegion(area)
        } else {
            let opaque = src.readRegion(area)
            let k = max(fmt.channels, 1)
            px = [Float](repeating: 0, count: area.area * n)
            for i in 0..<area.area {
                for c in 0..<min(k, n - 1) where i * k + c < opaque.count { px[i * n + c] = opaque[i * k + c] }
                px[i * n + n - 1] = 1
            }
        }
        if let m = sel {
            let mask = m.coverage(area)
            for i in 0..<min(area.area, mask.count) { px[i * n + n - 1] *= mask[i] }
        }
        out.writeRegion(area, px)
        out.prune()
        return Clip(surface: out, bounds: out.contentBounds, layers: nil)
    }

    /// Merged composite of the visible document as a surface in the document's format.
    static func mergedSurface(_ s: Session, _ doc: Document) throws -> Surface {
        let fmt = doc.pixelFormat
        return try s.services.renderer.compositeToSurface(doc, rect: doc.bounds, format: PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true))
    }

    static func copy(_ s: Session, merged: Bool) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        var clip: Clip
        if merged {
            clip = lift(try mergedSurface(s, d.doc), d.doc.selection, canvas)
        } else {
            guard let id = d.activeLayer else { throw EngineError.other("no active layer") }
            let several = multiCopyIds(d)
            let layers = several.isEmpty ? wholeLayer(d, id) : wholeLayers(d, several)
            if several.isEmpty, let surf = d.doc.layer(id)?.surface {
                clip = lift(surf, d.doc.selection, canvas)
                clip.layers = layers
            } else if let copies = layers {
                // A group has no pixels of its own: the clipboard pixels are what it shows.
                var shown = copies
                for i in shown.layers.indices { shown.layers[i].visible = true }
                clip = lift(try mergedSurface(s, shown), nil, canvas)
                clip.layers = layers
            } else {
                throw EngineError.other("the active layer has no pixels")
            }
        }
        if clip.bounds.isEmpty { throw EngineError.other("Could not copy: the selected area is empty") }
        let b = clip.bounds
        s.state[ClipboardKey.self] = clip
        return ["bounds": .rect(b)]
    }

    /// Copy with the layer mask targeted (#2928): the mask's values as a grayscale clip, inside the
    /// selection or the whole canvas; an untouched mask copies at its default value.
    static func copyMask(_ s: Session) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        guard let id = d.activeLayer else { throw EngineError.other("no active layer") }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard let mask = l.mask else { throw EngineError.other("the active layer has no layer mask") }
        let sel = d.doc.selection
        let area = sel.map { $0.contentBounds.intersect(canvas) } ?? canvas
        if area.isEmpty { throw EngineError.other("Could not copy: the selected area is empty") }
        let values = mask.surface.coverage(area)
        let cover = sel?.coverage(area)
        var px = [Float](repeating: 0, count: area.area * 2)
        for i in 0..<area.area {
            px[i * 2] = i < values.count ? values[i] : 0
            px[i * 2 + 1] = cover.map { i < $0.count ? $0[i] : 0 } ?? 1
        }
        var surface = Surface(format: PixelFormat(mode: .grayscale, sample: mask.surface.format.sample, alpha: true))
        surface.writeRegion(area, px)
        surface.prune()
        let b = surface.contentBounds
        if b.isEmpty { throw EngineError.other("Could not copy: the selected area is empty") }
        s.state[ClipboardKey.self] = Clip(surface: surface, bounds: b, layers: nil)
        return ["bounds": .rect(b), "target": "mask"]
    }

    static func clearSelected(_ doc: inout Document, _ id: LayerId, _ background: SIMD4<Float>) throws {
        let sel = doc.selection
        let canvas = doc.bounds
        let area = sel.map { $0.contentBounds.intersect(canvas) } ?? canvas
        guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
        try CoreCommands.clearArea(&doc, id, area, sel, background: background)
    }

    // MARK: Paste

    /// Paste as a new layer (or into the targeted mask or channel). `inPlace` keeps the original
    /// position; otherwise the pixels are centred on `center` or the canvas, unless they already
    /// overlap the canvas.
    static func paste(_ s: Session, _ p: JSONValue, inPlace: Bool) throws -> JSONValue {
        guard let clip = clipboard(s) else { throw EngineError.other("the clipboard is empty") }
        // Nothing open to paste into: the clipboard becomes a document of its own (#368).
        guard let d = s.active else { return try newFromClipboard(s) }
        if Channels.targetOf(p) != .pixels { return try pasteToTarget(s, p, inPlace: inPlace, limit: nil, label: "Paste") }
        // A targeted colour channel takes the paste instead of a new layer (#2307).
        if let k = pasteColorTarget(s, p) { return try channelPaste(s, p, k, inPlace: inPlace, limit: nil, label: "Paste") }
        let canvas = d.doc.bounds
        let fmt = d.doc.pixelFormat
        let (dx, dy) = pasteOffset(clip, canvas, p, inPlace: inPlace)
        if let layers = clip.layers, layered(d.doc.mode) { return try pasteLayers(s, layers, dx, dy) }
        let moved = clip.surface.shifted(dx: dx, dy: dy)
        let target = PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true)
        let surf = moved.format == target ? moved : moved.convertedAny(to: target)
        let id = try s.edit("Paste") { doc, active -> LayerId in
            let id = doc.insertAbove(active, Layer.raster(doc.nextLayerName("Layer"), surface: surf))
            active = id
            doc.selection = nil
            return id
        }
        return ["layer": .id(id), "offset": [.int(Int(dx)), .int(Int(dy))]]
    }

    /// Paste of whole copied layers: fresh copies, converted to the document's colour, moved as the
    /// pixels would be, above the active layer.
    static func pasteLayers(_ s: Session, _ layers: Document, _ dx: Int32, _ dy: Int32) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        var copies = layers
        copies.layers = copies.layers.map { $0.duplicate() }
        try adaptCopies(s, &copies, dest: d.doc)
        translateCopies(&copies, dx, dy)
        let patterns = copies.patterns.filter { pat in !d.doc.patterns.contains { $0.id == pat.id } }
        let pasted = copies.layers
        let id = try s.edit("Paste") { doc, active -> LayerId in
            doc.patterns += patterns
            for l in pasted { active = doc.insertAbove(active, l) }
            doc.selection = nil
            guard let a = active else { throw EngineError.other("nothing to paste") }
            return a
        }
        return ["layer": .id(id), "offset": [.int(Int(dx)), .int(Int(dy))]]
    }

    /// A Double as Int32, saturating (NaN → 0), as Rust's `as i32`.
    static func sat(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        if v >= Double(Int32.max) { return .max }
        if v <= Double(Int32.min) { return .min }
        return Int32(v)
    }

    /// How far a paste moves the clipboard pixels: not at all in place (or when they lie on the
    /// canvas and no `center` is given), else onto `center` or the canvas centre.
    static func pasteOffset(_ clip: Clip, _ canvas: PixelRect, _ p: JSONValue, inPlace: Bool) -> (Int32, Int32) {
        if inPlace || (clip.bounds.intersect(canvas) == clip.bounds && p["center"] == nil) { return (0, 0) }
        var c = ((Double(canvas.x0) + Double(canvas.x1)) / 2, (Double(canvas.y0) + Double(canvas.y1)) / 2)
        if let a = p["center"]?.arrayValue, a.count >= 2 { c = (a[0].doubleValue ?? 0, a[1].doubleValue ?? 0) }
        let b = clip.bounds
        return (sat((c.0 - (Double(b.x0) + Double(b.x1)) / 2).rounded()), sat((c.1 - (Double(b.y0) + Double(b.y1)) / 2).rounded()))
    }

    /// Paste into the targeted layer mask, alpha channel or Quick Mask instead of as a new layer
    /// (#1035): the pasted pixels' luminosity over what was there; their transparency and `limit`
    /// (Paste Into / Outside) let it show through. One history step.
    static func pasteToTarget(_ s: Session, _ p: JSONValue, inPlace: Bool, limit: Surface?, label: String) throws -> JSONValue {
        guard let clip = clipboard(s) else { throw EngineError.other("the clipboard is empty") }
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        let layer = d.activeLayer
        let (dx, dy) = pasteOffset(clip, canvas, p, inPlace: inPlace)
        let src = clip.surface.shifted(dx: dx, dy: dy)
        let area = src.contentBounds.intersect(canvas)
        try s.edit(label) { doc, _ in
            try Channels.withTargetSurface(&doc, layer: layer, p) { surf, _ in
                FillCommands.compositeOver(&surf, src, area, limit: limit)
                surf.prune()
            }
            doc.selection = nil
        }
        return ["target": p["target"] ?? .null, "offset": [.int(Int(dx)), .int(Int(dy))]]
    }

    /// A new document the size of the clipboard image, holding it as its one layer, in the pixel
    /// format it was copied in (#368).
    static func newFromClipboard(_ s: Session) throws -> JSONValue {
        guard let clip = clipboard(s) else { throw EngineError.other("the clipboard is empty") }
        let b = clip.bounds
        let (w, h) = (b.width, b.height)
        if w == 0 || h == 0 { throw EngineError.other("the clipboard image has no size") }
        let fmt = clip.surface.format
        let target = PixelFormat(mode: fmt.mode, sample: fmt.sample, alpha: true)
        let moved = b.x0 == 0 && b.y0 == 0 ? clip.surface : clip.surface.shifted(dx: Int32(clamping: -Int64(b.x0)), dy: Int32(clamping: -Int64(b.y0)))
        var doc = Document(name: "Untitled", size: PixelSize(width: w, height: h), mode: fmt.mode, depth: fmt.sample)
        let surf = moved.format == target ? moved : moved.convertedAny(to: target)
        doc.layers.append(Layer.raster(doc.nextLayerName("Layer"), surface: surf))
        let i = s.addDocument(doc)
        return ["document": .int(i), "width": .int(w), "height": .int(h)]
    }

    // MARK: Channel clipboard (photocraft channel_clip.rs)

    /// The colour channel a paste writes into: the Channels panel targets one and the params name
    /// no other target.
    static func pasteColorTarget(_ s: Session, _ p: JSONValue) -> Int? {
        if p["target"] != nil { return nil }
        if case .color(let k)? = s.active?.channelView.target { return k }
        return nil
    }

    /// Copy the targeted colour or alpha channel as a grayscale clip, inside the selection (or the
    /// whole canvas). nil when no single channel is targeted: Copy copies the layer.
    static func channelCopy(_ s: Session) throws -> JSONValue? {
        guard let d = s.active else { return nil }
        let doc = d.doc
        let canvas = doc.bounds
        let src: Surface, k: Int
        switch d.channelView.target {
        case .composite, .layerMask, .vectorMask: return nil
        case .color(let c):
            guard let id = d.activeLayer else { throw EngineError.other("no active layer") }
            guard let surf = doc.layer(id)?.surface else { throw EngineError.other("the active layer has no pixels") }
            (src, k) = (surf, c)
        case .alpha(let i):
            guard i < doc.channels.count else { throw EngineError.other("no alpha channel \(i) (document has \(doc.channels.count))") }
            (src, k) = (doc.channels[i].surface, 0)
        }
        let n = src.format.channels
        if k >= n { throw EngineError.other("no colour channel \(k) in this layer") }
        let sel = doc.selection
        let area = sel.map { $0.contentBounds.intersect(canvas) } ?? canvas
        if area.isEmpty { throw EngineError.other("Could not copy: the selected area is empty") }
        let values = src.readRegion(area)
        let cover = sel?.coverage(area)
        var px = [Float](repeating: 0, count: area.area * 2)
        for i in 0..<area.area {
            px[i * 2] = i * n + k < values.count ? values[i * n + k] : 0
            px[i * 2 + 1] = cover.map { i < $0.count ? $0[i] : 0 } ?? 1
        }
        var surface = Surface(format: PixelFormat(mode: .grayscale, sample: doc.pixelFormat.sample, alpha: true))
        surface.writeRegion(area, px)
        surface.prune()
        let b = surface.contentBounds
        if b.isEmpty { throw EngineError.other("Could not copy: the selected area is empty") }
        s.state[ClipboardKey.self] = Clip(surface: surface, bounds: b, layers: nil)
        return ["bounds": .rect(b), "channel": .int(k)]
    }

    /// Paste the clip's luminosity into colour channel `k` of the active layer, placed as a paste
    /// places it; the clip's transparency and `limit` let the old values show through.
    static func channelPaste(_ s: Session, _ p: JSONValue, _ k: Int, inPlace: Bool, limit: Surface?, label: String) throws -> JSONValue {
        guard let clip = clipboard(s) else { throw EngineError.other("the clipboard is empty") }
        guard let d = s.active else { throw EngineError.noDocument }
        let canvas = d.doc.bounds
        guard let id = d.activeLayer else { throw EngineError.other("no active layer") }
        let (dx, dy) = pasteOffset(clip, canvas, p, inPlace: inPlace)
        let src = clip.surface.shifted(dx: dx, dy: dy)
        let area = src.contentBounds.intersect(canvas)
        try s.edit(label) { doc, _ in
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in
                let n = surf.format.channels
                if k >= n { throw EngineError.other("no colour channel \(k) in this layer") }
                if !area.isEmpty {
                    let rgba = src.readRGBA(area)
                    let weight = limit?.coverage(area)
                    var px = surf.readRegion(area)
                    for i in 0..<min(area.area, rgba.count) {
                        let q = rgba[i]
                        let w = q.w * (weight.map { i < $0.count ? $0[i] : 0 } ?? 1)
                        let v = ColorConvert.rgbToGray(SIMD3(q.x, q.y, q.z))
                        let j = i * n + k
                        if j < px.count { px[j] += (v - px[j]) * min(max(w, 0), 1) }
                    }
                    surf.writeRegion(area, px)
                    surf.prune()
                }
            }
            doc.selection = nil
        }
        return ["layer": .id(id), "channel": .int(k), "offset": [.int(Int(dx)), .int(Int(dy))]]
    }

    /// Cut with colour channel `k` targeted (#2698): copy the channel, then fill the cut area of
    /// that channel only with the background colour's value for it.
    static func channelCut(_ s: Session, _ id: LayerId, _ k: Int) throws -> JSONValue {
        guard let r = try channelCopy(s) else { throw EngineError.other("no colour channel is targeted") }
        let bg = s.tools.background
        try s.edit("Cut Pixels") { doc, _ in try Channels.clearColorChannel(&doc, id, k, background: bg) }
        return r
    }

    /// Copy reads only: with an alpha channel targeted it needs no pixel layer.
    static func copiesAlphaChannel(_ s: Session) -> Bool {
        guard let st = s.active, case .alpha(let i) = st.channelView.target else { return false }
        return i < st.doc.channels.count
    }

    // MARK: Layer via Copy / Cut, Merge Visible

    static func layerVia(_ s: Session, cut: Bool) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let id = try activeId(s)
        let hasSel = d.doc.selection != nil
        if !hasSel && !cut && LayerMulti.multi(s, .null) {
            // No selection, several layers selected: copy every one of them (#2777).
            return try LayerMulti.duplicateSelected(s, inPlace: true, label: "Layer Via Copy")
        }
        if !hasSel && !cut {
            // No selection: Layer via Copy duplicates the whole layer (Photoshop).
            let nid = try s.edit("Layer Via Copy") { doc, active -> LayerId in
                guard let src = doc.layer(id) else { throw EngineError.noLayer(id) }
                var dup = src.duplicate()
                dup.name = doc.copyName(src.name)
                dup.locks = Locks()
                let nid = doc.insertAbove(id, dup)
                active = nid
                return nid
            }
            return ["layer": .id(nid)]
        }
        guard let surf = d.doc.layer(id)?.surface else { throw EngineError.other("the active layer has no pixels") }
        let clip = lift(surf, d.doc.selection, d.doc.bounds)
        if clip.bounds.isEmpty { throw EngineError.other("Could not complete the command: the selected area is empty") }
        let bg = s.tools.background
        let nid = try s.edit(cut ? "Layer Via Cut" : "Layer Via Copy") { doc, active -> LayerId in
            if cut { try clearSelected(&doc, id, bg) }
            let nid = doc.insertAbove(id, Layer.raster(doc.nextLayerName("Layer"), surface: clip.surface))
            active = nid
            // Photoshop deselects: a following Free Transform moves the whole new layer (#1096).
            doc.selection = nil
            return nid
        }
        return ["layer": .id(nid)]
    }

    /// What Merge Visible keeps and where the merged layer goes, as Photoshop 27.11 has it (measured by script,
    /// AB-T-0342, AB-T-0343): every shown layer merges into the active one, which gives the result its name and its
    /// place among the layers that stay. Hidden layers stay in their order, those inside shown folders too, lifted out
    /// of them. A shown Background takes the merge instead, whichever layer is active.
    struct VisibleMerge {
        /// The layers that stay, bottom to top.
        var rest: [Layer] = []
        /// Where the merged layer goes in `rest`.
        var place = 0
        var name = ""
        var locks = Locks()
        var intoBackground = false
    }

    /// The plan, or why Photoshop's Merge Visible "is not currently available": the active layer is hidden, or fewer
    /// than two layers are shown.
    static func visibleMerge(_ doc: Document, active: LayerId?) -> Result<VisibleMerge, EngineError> {
        var plan = VisibleMerge()
        var shown = 0
        var activeShown = false
        // Bottom to top, a folder after what it holds (it sits above its layers in the panel).
        func visit(_ l: Layer) {
            guard l.visible else { plan.rest.append(l); return }
            if let children = l.children { children.forEach(visit) } else { shown += 1 }
            if l.id == active {
                activeShown = true
                plan.place = plan.rest.count
                plan.name = l.name
                plan.locks = l.isGroup ? Locks() : l.locks
            }
        }
        doc.layers.forEach(visit)
        if !activeShown { return .failure(.other("the active layer is hidden")) }
        if shown < 2 { return .failure(.other("there are not enough visible layers to merge")) }
        if let background = doc.background, background.visible {
            plan.intoBackground = true
            plan.place = 0
            plan.name = background.name
            plan.locks = background.locks
        }
        return .success(plan)
    }

    static func mergeVisible(_ s: Session) throws -> JSONValue {
        let renderer = s.services.renderer
        try s.edit("Merge Visible") { doc, active in
            let plan = try visibleMerge(doc, active: active).get()
            // Composite of the shown layers only: a hidden layer is not drawn wherever it sits.
            var solo = doc
            solo.layers = solo.layers.filter(\.visible)
            let fmt = doc.pixelFormat
            let pixels = try Pixels.compositeLayers(solo, format: fmt, background: plan.intoBackground ? SIMD3(1, 1, 1) : nil, renderer: renderer)
            var merged = Layer.raster(plan.name, surface: pixels)
            merged.locks = plan.locks
            var out = plan.rest
            out.insert(merged, at: plan.place)
            doc.layers = out
            active = merged.id
        }
        return .null
    }

    // MARK: Auto Tone / Contrast / Color

    static func isqrt(_ n: Int) -> Int {
        var r = Int(Double(max(n, 0)).squareRoot())
        while r * r > n { r -= 1 }
        while (r + 1) * (r + 1) <= n { r += 1 }
        return r
    }

    /// Histogram of a pixel layer (8-bit bins per channel: R, G, B) inside `area`.
    static func histograms(_ surf: Surface, _ area: PixelRect) -> [[UInt64]] {
        var h = [[UInt64]](repeating: [UInt64](repeating: 0, count: 256), count: 3)
        if area.isEmpty { return h }
        let step = max((area.width * area.height) / 4_000_000, 1) // sample big images
        let stride = max(isqrt(step), 1)
        func q(_ v: Float) -> Int { v.isNaN ? 0 : Int(min(max(v, 0), 1) * 255 + 0.5) }
        var y = area.y0
        while y < area.y1 {
            let row = surf.readRGBA(PixelRect(x0: area.x0, y0: y, x1: area.x1, y1: y + 1))
            var x = 0
            while x < row.count {
                let p = row[x]
                if q(p.w) != 0 {
                    h[0][q(p.x)] += 1
                    h[1][q(p.y)] += 1
                    h[2][q(p.z)] += 1
                }
                x += stride
            }
            let (next, overflow) = y.addingReportingOverflow(Int32(clamping: stride))
            if overflow { break }
            y = next
        }
        return h
    }

    /// Black and white points with `clip` (fraction) clipped at each end.
    static func clipPoints(_ h: [UInt64], _ clip: Double) -> (Float, Float) {
        let total = h.reduce(0, +)
        if total == 0 { return (0, 1) }
        let lim = UInt64(Double(total) * clip)
        var acc: UInt64 = 0, lo = 0
        while lo < 254 && acc + h[lo] <= lim {
            acc += h[lo]
            lo += 1
        }
        acc = 0
        var hi = 255
        while hi > lo + 1 && acc + h[hi] <= lim {
            acc += h[hi]
            hi -= 1
        }
        return (Float(lo) / 255, Float(hi) / 255)
    }

    static func median(_ h: [UInt64]) -> Float {
        let total = h.reduce(0, +)
        var acc: UInt64 = 0
        for (i, v) in h.enumerated() {
            acc += v
            if acc * 2 >= total { return Float(i) / 255 }
        }
        return 0.5
    }

    /// Image › Auto Tone / Auto Contrast / Auto Color (0.1 % clipping, Photoshop's defaults).
    static func autoAdjust(_ s: Session, _ kind: String) throws -> JSONValue {
        let id = try activeId(s)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let surf = d.doc.layer(id)?.surface else { throw EngineError.other("the active layer has no pixels") }
        let area = (d.doc.selection?.contentBounds ?? d.doc.bounds).intersect(d.doc.bounds)
        let h = histograms(surf, area)
        let clip = 0.001
        var per = [LevelsChannel(), LevelsChannel(), LevelsChannel()]
        switch kind {
        case "contrast":
            // Same points for all channels (preserves colour), from the combined histogram.
            var all = [UInt64](repeating: 0, count: 256)
            for c in h { for i in 0..<256 { all[i] += c[i] } }
            let (lo, hi) = clipPoints(all, clip)
            for i in per.indices { (per[i].inBlack, per[i].inWhite) = (lo, hi) }
        default:
            for c in 0..<3 { (per[c].inBlack, per[c].inWhite) = clipPoints(h[c], clip) }
            if kind == "color" {
                // Neutralise midtones: move each channel's median onto the average median.
                let meds = (0..<3).map { median(h[$0]) }
                let target = meds.reduce(0, +) / 3
                for c in 0..<3 {
                    let span = max(per[c].inWhite - per[c].inBlack, 1e-3)
                    let t = min(max((meds[c] - per[c].inBlack) / span, 0.02), 0.98)
                    let want = min(max((target - per[c].inBlack) / span, 0.02), 0.98)
                    // out = t^(1/g) = want  →  g = ln t / ln want
                    per[c].gamma = min(max(log(t) / log(want), 0.1), 9.99)
                }
            }
        }
        let adj = Adjustment.levels(.init(master: LevelsChannel(), perChannel: per, black: LevelsChannel()))
        let label = kind == "contrast" ? "Auto Contrast" : kind == "color" ? "Auto Color" : "Auto Tone"
        try s.edit(label) { doc, _ in
            let sel = doc.selection, mode = doc.mode
            try LayerOps.withPaintSurface(&doc, id, .null) { Pixels.adjustSurface(&$0, adj, selection: sel, mode: mode) }
        }
        return .null
    }

    // MARK: Guides

    /// Guides further than this from the canvas origin are refused.
    static let maxGuidePx = 1_000_000.0

    /// Rust's `{:?}` of a string.
    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// photocraft `prefs::Unit`.
    enum Unit { case pixels, inches, centimeters, millimeters, points, picas, percent }

    static func unit(fromSuffix s: String) -> Unit? {
        switch s.lowercased() {
        case "px", "pixel", "pixels": .pixels
        case "in", "inch", "inches", "\"": .inches
        case "cm", "centimeter", "centimeters", "centimetre", "centimetres": .centimeters
        case "mm", "millimeter", "millimeters", "millimetre", "millimetres": .millimeters
        case "pt", "point", "points": .points
        case "pc", "pica", "picas": .picas
        case "%", "percent": .percent
        default: nil
        }
    }

    /// photocraft `Unit::parse_length`: a number with an optional unit suffix.
    static func parseLength(_ text: String) -> (Double, Unit?)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberChars = Set("0123456789.,-+")
        let end = t.firstIndex { !numberChars.contains($0) } ?? t.endIndex
        let number = t[..<end].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !number.isEmpty, let v = Double(number), v.isFinite else { return nil }
        let suffix = t[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.isEmpty { return (v, nil) }
        guard let u = unit(fromSuffix: suffix) else { return nil }
        return (v, u)
    }

    /// photocraft `Unit::to_px`.
    static func toPx(_ u: Unit, _ v: Double, dpi d: Double, extent: Double, ppi: Double) -> Double {
        let dpi = max(d, 1e-6)
        switch u {
        case .pixels: return v
        case .inches: return v * dpi
        case .centimeters: return v / 2.54 * dpi
        case .millimeters: return v / 25.4 * dpi
        case .points: return v / max(ppi, 1e-6) * dpi
        case .picas: return v * 12 / max(ppi, 1e-6) * dpi
        case .percent: return v * extent / 100
        }
    }

    /// A guide `position` in document pixels: a number of pixels, or text with a unit as in
    /// Photoshop's New Guide dialog. nil when there is no `position`.
    static func guidePosition(_ s: Session, _ p: JSONValue, vertical: Bool) throws -> Double? {
        guard let v = p["position"] else { return nil }
        let px: Double
        switch v {
        case .number(let n): px = n
        case .string(let text):
            guard let (n, unit) = parseLength(text) else {
                throw EngineError.other("`position` \(quoted(text)) is not a length: give a number of pixels, or a number with px, in, cm, mm, pt, pc or %")
            }
            guard let doc = s.active?.doc else { throw EngineError.noDocument }
            let extent = vertical ? doc.size.width : doc.size.height
            let ppi = s.preferences["unitsAndRulers.pointSize"]?.stringValue == "traditional" ? 72.27 : 72.0
            px = toPx(unit ?? .pixels, n, dpi: Double(doc.resolutionDpi), extent: Double(extent), ppi: ppi)
        default:
            throw EngineError.other("`position` must be a number of pixels or text with a unit")
        }
        if !px.isFinite || abs(px) > maxGuidePx {
            throw EngineError.other("`position` is out of range (at most 1000000 px from the canvas origin)")
        }
        return px
    }

    /// Photoshop's guide colours, in its order, by the names `view.newGuide` takes.
    static let guideColors: [(String, SIMD3<UInt8>)] = [
        ("lightBlue", SIMD3(0x33, 0x66, 0xff)), ("lightRed", SIMD3(0xff, 0x33, 0x33)), ("green", SIMD3(0x33, 0xff, 0x33)),
        ("mediumBlue", SIMD3(0x33, 0x33, 0xff)), ("yellow", SIMD3(0xff, 0xcc, 0x00)), ("magenta", SIMD3(0xff, 0x00, 0xff)),
        ("cyan", SIMD3(0x4a, 0xff, 0xff)), ("lightGray", SIMD3(0xe7, 0xe7, 0xe7)), ("black", SIMD3(0x00, 0x00, 0x00)),
    ]

    /// photocraft `prefs::parse_hex`: `#rrggbb` (leading `#`s optional).
    static func parseHexRGB(_ s: String) -> SIMD3<UInt8>? {
        var t = Substring(s.trimmingCharacters(in: .whitespacesAndNewlines))
        while t.hasPrefix("#") { t = t.dropFirst() }
        let b = Array(t.utf8)
        guard b.count == 6 else { return nil }
        func byte(_ i: Int) -> UInt8? { UInt8(String(decoding: b[i..<i + 2], as: UTF8.self), radix: 16) }
        guard let r = byte(0), let g = byte(2), let bl = byte(4) else { return nil }
        return SIMD3(r, g, bl)
    }

    /// A guide `color`: one of `guideColors`' names or `"#rrggbb"`. nil when there is no `color`.
    static func guideColor(_ p: JSONValue) throws -> SIMD3<UInt8>? {
        guard let v = p["color"] else { return nil }
        guard let text = v.stringValue else { throw EngineError.other("`color` must be a colour name or \"#rrggbb\"") }
        if let c = guideColors.first(where: { $0.0.lowercased() == text.lowercased() }) { return c.1 }
        if let c = parseHexRGB(text) { return c }
        throw EngineError.other("`color` \(quoted(text)) is not a guide colour: use \"#rrggbb\" or one of \(guideColors.map(\.0).joined(separator: ", "))")
    }

    /// View › New Guide / guide moves (undoable, like Photoshop's "New Guide"/"Move Guide" states).
    static func guideCmd(_ s: Session, _ p: JSONValue, _ op: String) throws -> JSONValue {
        let vertical = (p["orientation"]?.stringValue ?? "horizontal") == "vertical"
        let pos = try guidePosition(s, p, vertical: vertical)
        let color = op == "new" ? try guideColor(p) : nil
        let index = p["index"]?.uint64Value.map { $0 > UInt64(Int.max) ? Int.max : Int($0) }
        let label = switch op {
        case "new": "New Guide"
        case "move": "Move Guide"
        case "delete": "Delete Guide"
        default: "Clear Guides"
        }
        try s.edit(label) { doc, _ in
            var guides = doc.guides
            var g = vertical ? guides.vertical : guides.horizontal
            switch op {
            case "new":
                guard let at = pos else { throw EngineError.other("missing `position`") }
                g.append(at)
                if vertical { guides.vertical = g } else { guides.horizontal = g }
                if let color { guides.setColor(vertical: vertical, position: at, rgb: color) }
            case "move":
                guard let i = index, i < g.count else { throw EngineError.other("no such guide") }
                guard let to = pos else { throw EngineError.other("missing `position`") }
                let from = g[i]
                g[i] = to
                if vertical { guides.vertical = g } else { guides.horizontal = g }
                // The guide takes its colour along; another guide left at the old position keeps it.
                if let rgb = guides.color(vertical: vertical, position: from) { guides.setColor(vertical: vertical, position: to, rgb: rgb) }
                guides.pruneColors()
            case "delete":
                guard let i = index, i < g.count else { throw EngineError.other("no such guide") }
                g.remove(at: i)
                if vertical { guides.vertical = g } else { guides.horizontal = g }
                guides.pruneColors()
            default:
                guides.horizontal.removeAll()
                guides.vertical.removeAll()
                guides.colors.removeAll()
            }
            doc.guides = guides
        }
        return .null
    }

    // MARK: Registry

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("edit.cut", "Cut", menu: ["Edit"], shortcut: "Cmd+X", params: "{} (a targeted colour channel cuts that channel only)",
                          module: m, enabled: hasPixels) { s, p in
            // Refuse a locked layer before copying, so a refused Cut leaves the clipboard alone.
            let id = try activeId(s)
            guard let doc = s.active?.doc else { throw EngineError.noDocument }
            try LayerOps.checkPixelsUnlocked(doc, id)
            // A targeted colour channel cuts that channel only (#2698).
            if let k = pasteColorTarget(s, p) { return try channelCut(s, id, k) }
            let r = try copy(s, merged: false)
            let bg = s.tools.background
            try s.edit("Cut Pixels") { doc, _ in try clearSelected(&doc, id, bg) }
            return r
        })
        r.add(CommandSpec("edit.copy", "Copy", menu: ["Edit"], shortcut: "Cmd+C",
                          params: ##"{"target":"mask"? = the targeted mask, copied as grayscale (#2928)} (a targeted colour or alpha channel copies that channel, as grayscale)"##,
                          module: m, enabled: canCopy) { s, p in
            if LayerOps.isMaskTarget(p) { return try copyMask(s) }
            if let r = try channelCopy(s) { return r }
            return try copy(s, merged: false)
        })
        r.add(CommandSpec("edit.copyMerged", "Copy Merged", menu: ["Edit"], shortcut: "Cmd+Shift+C", module: m, enabled: Pre.hasDoc) { s, _ in
            try copy(s, merged: true)
        })
        r.add(CommandSpec("edit.paste", "Paste", menu: ["Edit"], shortcut: "Cmd+V",
                          params: #"{"center":[x,y]? (view centre; default keeps the position when it overlaps the canvas),"# + pasteTarget + "} (with no document open: a new document from the clipboard)",
                          module: m, enabled: hasClipOnly) { s, p in try paste(s, p, inPlace: false) })
        r.add(CommandSpec("file.newFromClipboard", "New from Clipboard", menu: ["File"],
                          params: "{} (a new document the size of the clipboard image, holding it as one layer)", module: m, enabled: hasClipOnly) { s, _ in
            try newFromClipboard(s)
        })
        r.add(CommandSpec("edit.pasteSpecial.pasteInPlace", "Paste in Place", menu: ["Edit", "Paste Special"], shortcut: "Cmd+Shift+V",
                          params: "{" + pasteTarget + "}", module: m, enabled: hasClip) { s, p in try paste(s, p, inPlace: true) })
        r.add(CommandSpec("layer.new.layerViaCopy", "Layer via Copy", menu: ["Layer", "New"], shortcut: "Cmd+J", module: m, enabled: Pre.hasDoc) { s, _ in
            try layerVia(s, cut: false)
        })
        r.add(CommandSpec("layer.new.layerViaCut", "Layer via Cut", menu: ["Layer", "New"], shortcut: "Cmd+Shift+J", module: m, enabled: hasPixels) { s, _ in
            try layerVia(s, cut: true)
        })
        let canMergeVisible: CommandEnabled = { s, _ in
            guard let d = s.active else { return "no document open" }
            if case .failure(let e) = visibleMerge(d.doc, active: d.activeLayer) { return "\(e)" }
            return nil
        }
        r.add(CommandSpec("layer.mergeVisible", "Merge Visible", menu: ["Layer"], shortcut: "Cmd+Shift+E", module: m, enabled: canMergeVisible) { s, _ in
            try mergeVisible(s)
        })
        for (id, label, shortcut, kind) in [("image.autoTone", "Auto Tone", "Cmd+Shift+L", "tone"), ("image.autoContrast", "Auto Contrast", "Cmd+Alt+Shift+L", "contrast"),
                                            ("image.autoColor", "Auto Color", "Cmd+Shift+B", "color")] {
            r.add(CommandSpec(id, label, menu: ["Image"], shortcut: shortcut, module: m, enabled: hasPixels) { s, _ in try autoAdjust(s, kind) })
        }
        r.add(CommandSpec("edit.toggleLastState", "Toggle Last State", menu: ["Edit"], shortcut: "Cmd+Alt+Z", module: m, enabled: Pre.hasDoc) { s, _ in
            guard let st = s.active else { throw EngineError.noDocument }
            return .bool(st.history.canRedo ? s.redo() : s.undo())
        })
        r.add(CommandSpec("edit.transform.again", "Again", menu: ["Edit", "Transform"], shortcut: "Cmd+Shift+T", module: m, enabled: Pre.hasDoc) { s, _ in
            try transformAgain(s)
        })
        r.add(CommandSpec("edit.transform.againCopy", "Transform Again on a Copy", shortcut: "Cmd+Alt+Shift+T",
                          params: "{} (duplicates the active layer and repeats the last transform on the copy: step and repeat)", module: m,
                          enabled: Pre.hasDoc) { s, _ in try transformAgainCopy(s) })
        r.add(CommandSpec("view.newGuide", "New Guide…", menu: ["View"],
                          params: ##"{"orientation":"horizontal|vertical","position":px or "<number><unit>","color":"lightBlue|lightRed|green|mediumBlue|yellow|magenta|cyan|lightGray|black" or "#rrggbb"?} (units px, in, cm, mm, pt, pc or %; % is of the width for a vertical guide, the height for a horizontal one; without a color the guide uses the guide colour in Preferences)"##,
                          module: m, enabled: Pre.hasDoc) { s, p in try guideCmd(s, p, "new") })
        r.add(CommandSpec("view.moveGuide", "Move Guide",
                          params: ##"{"orientation":"horizontal|vertical","index":n,"position":px or "<number><unit>"} (units as for view.newGuide)"##,
                          module: m, enabled: Pre.hasDoc) { s, p in try guideCmd(s, p, "move") })
        r.add(CommandSpec("view.deleteGuide", "Delete Guide", params: ##"{"orientation":"horizontal|vertical","index":n}"##, module: m, enabled: Pre.hasDoc) { s, p in
            try guideCmd(s, p, "delete")
        })
        r.add(CommandSpec("view.clearGuides", "Clear Guides", menu: ["View"], module: m, enabled: Pre.hasDoc) { s, p in try guideCmd(s, p, "clear") })
    }
}
