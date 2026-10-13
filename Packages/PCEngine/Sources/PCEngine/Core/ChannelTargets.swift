// Port of photocraft-engine (crates/engine/src/channel_cmds.rs view state and pixel-command targeting: `ChannelTarget`, `ChannelView`, `QuickMaskOptions`, `fix_view`, `target_of`, `inject_target`, `color_restriction`, `restrict_to_color`, `edits_channel`, `mask_target_enabled`, `targeted_channel`/`clear_channel`, `targeted_color`/`clear_color_channel`; mask_view_cmds.rs `LayerMaskView`, `current`, `fix`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The Channels panel decides what pixel commands edit: the layers (composite), one colour channel,
// an alpha channel, the layer mask, or the Quick Mask. photocraft's dispatch consults it on every
// command; here it is core state plus hooks (`ChannelTargetHooks`), so the channel commands, the
// fills, filters, adjustments and paint commands all share one implementation.

import PCDocument
import PCFoundation

/// What pixel commands edit (Channels panel click / ⌘2…⌘9).
public enum ChannelTarget: Hashable, Sendable {
    /// The layers (all colour channels). In Quick Mask mode this edits the Quick Mask.
    case composite
    /// One colour channel of the active layer.
    case color(Int)
    /// An alpha or spot channel (index into `Document.channels`).
    case alpha(Int)
    case layerMask
    case vectorMask

    public var json: JSONValue {
        switch self {
        case .composite: ["kind": "composite"]
        case .color(let k): ["kind": "color", "index": .int(k)]
        case .alpha(let i): ["kind": "alpha", "index": .int(i)]
        case .layerMask: ["kind": "layerMask"]
        case .vectorMask: ["kind": "vectorMask"]
        }
    }
}

/// How the ⌥-clicked layer mask shows on the canvas.
public enum MaskViewMode: String, Hashable, Sendable { case gray, overlay }

/// Which layer's mask is shown, and how.
public struct LayerMaskView: Hashable, Sendable {
    public var layer: LayerId
    public var mode: MaskViewMode
    public init(layer: LayerId, mode: MaskViewMode) { self.layer = layer; self.mode = mode }
}

/// Per-document Channels panel state: the target and the eyes. Not part of history.
public struct ChannelView: Hashable, Sendable {
    public var target: ChannelTarget = .composite
    /// Hidden colour channels (missing entries are visible).
    public var colorHidden: [Bool] = []
    /// Visible alpha channels (missing entries are hidden).
    public var alphaVisible: [Bool] = []
    public var quickMaskHidden = false
    /// ⌥-click view of the active layer's mask.
    public var layerMask: LayerMaskView?

    public init() {}

    public func colorVisible(_ k: Int) -> Bool { !(k < colorHidden.count ? colorHidden[k] : false) }
    public func alphaShown(_ i: Int) -> Bool { i < alphaVisible.count ? alphaVisible[i] : false }
    public mutating func setColorVisible(_ k: Int, _ v: Bool) {
        if colorHidden.count <= k { colorHidden += [Bool](repeating: false, count: k + 1 - colorHidden.count) }
        colorHidden[k] = !v
    }
    public mutating func setAlphaVisible(_ i: Int, _ v: Bool) {
        if alphaVisible.count <= i { alphaVisible += [Bool](repeating: false, count: i + 1 - alphaVisible.count) }
        alphaVisible[i] = v
    }
    public func visibleColors(_ colors: Int) -> Int { (0..<colors).filter(colorVisible).count }
}

public enum ChannelViewKey: StateKey { public static let defaultValue = ChannelView() }

/// Session-wide Quick Mask Options.
public struct QuickMaskOptions: Hashable, Sendable {
    public var color: PCColor = AlphaChannel.defaultColor
    public var opacity: Float = 0.5
    public var indicates: ColorIndicates = .maskedAreas
    public init() {}
}

public enum QuickMaskOptionsKey: StateKey { public static let defaultValue = QuickMaskOptions() }

extension DocState {
    /// The Channels panel state.
    public var channelView: ChannelView {
        get { view[ChannelViewKey.self] }
        set { view[ChannelViewKey.self] = newValue }
    }

    /// The live mask view: its layer is active and still has a mask (photocraft
    /// `mask_view_cmds::current`).
    public var currentMaskView: LayerMaskView? {
        guard let v = channelView.layerMask, activeLayer == v.layer, doc.layer(v.layer)?.mask != nil else { return nil }
        return v
    }

    /// Keep the view valid after the document changed (photocraft `fix_view`).
    mutating func fixChannelView() {
        let n = doc.channels.count
        let colors = Channels.colorCount(doc)
        let quick = doc.quickMask != nil
        var v = channelView
        if v.alphaVisible.count > n { v.alphaVisible.removeLast(v.alphaVisible.count - n) }
        if v.colorHidden.count > colors { v.colorHidden.removeLast(v.colorHidden.count - colors) }
        let activeL = activeLayer.flatMap { doc.layer($0) }
        switch v.target {
        case .alpha(let i) where i >= n: v.target = .composite
        case .color(let k) where k >= colors || colors < 2: v.target = .composite
        case .layerMask where activeL?.mask == nil: v.target = .composite
        case .vectorMask where activeL?.vectorMask == nil: v.target = .composite
        default: break
        }
        if v.layerMask != nil {
            let live = v.layerMask.map { activeLayer == $0.layer && doc.layer($0.layer)?.mask != nil } ?? false
            if !live { v.layerMask = nil }
        }
        let shown = (0..<n).contains(where: v.alphaShown) || (quick && !v.quickMaskHidden) || activeL?.mask != nil
        if v.visibleColors(colors) == 0 && !shown { v.colorHidden.removeAll() }
        if v != channelView { channelView = v }
    }
}

/// Channel naming, formats and pixel-command targets.
public enum Channels {
    public static func colorNames(_ mode: ColorMode) -> [String] {
        switch mode {
        case .cmyk: ["Cyan", "Magenta", "Yellow", "Black"]
        case .lab: ["Lightness", "a", "b"]
        case .grayscale: ["Gray"]
        default: ["Red", "Green", "Blue"]
        }
    }

    public static func compositeName(_ mode: ColorMode) -> String {
        switch mode {
        case .cmyk: "CMYK"
        case .lab: "Lab"
        case .grayscale: "Gray"
        default: "RGB"
        }
    }

    public static func colorCount(_ doc: Document) -> Int { doc.pixelFormat.mode.colorChannels }

    /// Alpha channels: grayscale at the document depth, no transparency.
    public static func channelFormat(_ doc: Document) -> PixelFormat { PixelFormat(mode: .grayscale, sample: doc.depth, alpha: false) }

    /// Where a pixel command writes, from its `"target"` param.
    public enum Target: Hashable, Sendable { case pixels, mask, alpha(Int), quickMask }

    public static func targetOf(_ p: JSONValue) -> Target {
        switch p["target"] {
        case .string("mask"): return .mask
        case .string("quickMask"): return .quickMask
        case .object(let o): return o["channel"]?.uint64Value.map { .alpha(Int($0)) } ?? .pixels
        default: return .pixels
        }
    }

    /// The target is an alpha channel or the Quick Mask (no layer involved).
    public static func isChannelTarget(_ p: JSONValue) -> Bool {
        switch targetOf(p) {
        case .alpha, .quickMask: true
        default: false
        }
    }

    /// Mutates the surface a pixel command writes to; `lockTransparency` tells the body whether
    /// the layer's transparency is locked (photocraft `target_surface`).
    @discardableResult
    public static func withTargetSurface<R>(_ doc: inout Document, layer: LayerId?, _ p: JSONValue,
                                            _ body: (inout Surface, _ lockTransparency: Bool) throws -> R) throws -> R {
        switch targetOf(p) {
        case .alpha(let i):
            guard i < doc.channels.count else { throw EngineError.other("no alpha channel \(i) (document has \(doc.channels.count))") }
            return try body(&doc.channels[i].surface, false)
        case .quickMask:
            guard var q = doc.quickMask else { throw EngineError.other("not in Quick Mask mode") }
            defer { doc.quickMask = q }
            return try body(&q.surface, false)
        case let t:
            guard let id = layer else { throw EngineError.other("no active layer") }
            let lock = doc.effectiveLocks(id).transparency && t == .pixels
            return try LayerOps.withPaintSurface(&doc, id, p) { try body(&$0, lock) }
        }
    }

    /// The surface a pixel command reads (photocraft `read_target_surface`).
    public static func readTargetSurface(_ doc: Document, layer: LayerId?, _ p: JSONValue) throws -> Surface {
        switch targetOf(p) {
        case .alpha(let i):
            guard i < doc.channels.count else { throw EngineError.other("no alpha channel \(i) (document has \(doc.channels.count))") }
            return doc.channels[i].surface
        case .quickMask:
            guard let q = doc.quickMask else { throw EngineError.other("not in Quick Mask mode") }
            return q.surface
        case .pixels:
            guard let id = layer else { throw EngineError.other("no active layer") }
            guard let s = doc.layer(id)?.surface else { throw EngineError.noLayer(id) }
            return s
        case .mask:
            guard let id = layer else { throw EngineError.other("no active layer") }
            guard let m = doc.layer(id)?.mask else { throw EngineError.noLayer(id) }
            return m.surface
        }
    }

    /// Makes every canvas pixel of `s` explicit (filters and adjustments on a channel see the
    /// untouched parts too).
    public static func materialize(_ s: inout Surface, _ r: PixelRect) {
        let v = s.readRegion(r)
        s.writeRegion(r, v)
    }

    /// Commands whose target follows the Channels panel.
    public static func routed(_ id: String) -> Bool {
        if id.hasPrefix("filter.") || id == "plugin.run" || id.hasPrefix("image.adjustments.") { return true }
        return routedIds.contains(id)
    }

    static let routedIds: Set<String> = [
        "paint.stroke", "paint.pencil", "paint.bucket", "paint.gradient", "paint.mixerBrush", "edit.fill", "image.applyImage",
        "edit.fillForeground", "edit.fillBackground", "edit.fillForegroundPreserve", "edit.fillBackgroundPreserve", "edit.fillHistory",
        "edit.copy", "edit.paste", "edit.pasteSpecial.pasteInPlace", "edit.pasteSpecial.pasteInto", "edit.pasteSpecial.pasteOutside",
        "edit.transform.rotate180", "edit.transform.rotate90Cw", "edit.transform.rotate90Ccw", "edit.transform.flipHorizontal",
        "edit.transform.flipVertical", "paint.cloneStamp", "paint.patternStamp", "paint.healingBrush", "paint.spotHealing", "paint.dodge",
        "paint.burn", "paint.sponge", "paint.blur", "paint.sharpen", "paint.smudge", "paint.historyBrush", "paint.redEye", "paint.remove",
    ]

    /// Whether `id` edits the targeted channel or mask when its params name no target.
    public static func followsTarget(_ id: String) -> Bool { routed(id) || id == "select.float" || id == "layer.translate" }

    /// Commands a targeted layer mask enables on any layer with a mask (photocraft `edits_mask`).
    static func editsMask(_ id: String) -> Bool {
        if id.hasPrefix("image.adjustments."), id != "image.adjustments.colorLookup.list" { return true }
        if id.hasPrefix("filter.") { return true }
        return ["edit.fill", "edit.copy", "edit.fillForeground", "edit.fillBackground", "edit.fillForegroundPreserve",
                "edit.fillBackgroundPreserve", "edit.fillHistory"].contains(id)
    }

    /// Fills in `"target"` from the Channels panel when the caller gave none.
    static func injectTarget(_ s: Session, _ id: String, _ params: JSONValue) -> JSONValue {
        guard routed(id), !params.has("target"), let st = s.active else { return params }
        let t: JSONValue
        switch st.channelView.target {
        case .alpha(let i) where i < st.doc.channels.count: t = ["channel": .int(i)]
        case .composite where st.doc.quickMask != nil: t = "quickMask"
        case .layerMask: t = "mask"
        case .composite where st.currentMaskView != nil: t = "mask"
        default: return params
        }
        return params.setting("target", t)
    }

    /// The colour channel pixel commands are limited to.
    static func colorRestriction(_ s: Session, _ id: String, _ params: JSONValue) -> Int? {
        guard routed(id), !isChannelTarget(params), !LayerOps.isMaskTarget(params), case .color(let k)? = s.active?.channelView.target else { return nil }
        return k
    }

    /// After a pixel edit with colour channel `k` targeted, put the other channels (and the
    /// transparency) of layer `id` back (photocraft `restrict_to_color`).
    static func restrictToColor(_ before: Document, _ after: inout Document, _ id: LayerId, _ k: Int) {
        guard let old = before.layer(id)?.surface, let new0 = after.layer(id)?.rasterSurface, old.format == new0.format else { return }
        after.withRaster(of: id) { new in
            var coords = Set<TileCoord>()
            new.forEachTile { c, t in if old.tile(c)?.generation != t.generation { coords.insert(c) } }
            old.forEachTile { c, _ in if new.tile(c) == nil { coords.insert(c) } }
            let n = new.channels
            for c in coords {
                let r = c.rect
                let o = old.readRegion(r)
                var v = new.readRegion(r)
                for i in stride(from: 0, to: v.count, by: n) { for ch in 0..<n where ch != k { v[i + ch] = o[i + ch] } }
                new.writeRegion(r, v)
            }
            new.prune()
        }
    }

    /// The targeted colour channel (Clear limits itself to it).
    public static func targetedColor(_ s: Session) -> Int? {
        if case .color(let k)? = s.active?.channelView.target { return k }
        return nil
    }

    /// Clear with colour channel `k` targeted: that channel takes the background colour's value.
    public static func clearColorChannel(_ doc: inout Document, _ id: LayerId, _ k: Int, background: SIMD4<Float>) throws {
        let canvas = doc.bounds
        let sel = doc.selection
        let area = sel.map { $0.contentBounds.intersect(canvas) } ?? canvas
        try LayerOps.withPaintSurface(&doc, id, .null) { surf in
            let fmt = surf.format, n = fmt.channels
            let comps = fmt.components(fromRGBA: SIMD4(background.x, background.y, background.z, 1))
            guard k < n, k < comps.count else { throw EngineError.other("no colour channel \(k) in this layer") }
            if area.isEmpty { return }
            let v = comps[k]
            let cover = sel?.coverage(area)
            var px = surf.readRegion(area)
            for i in 0..<area.area {
                let w = min(max(cover?[i] ?? 1, 0), 1)
                px[i * n + k] += (v - px[i * n + k]) * w
            }
            surf.writeRegion(area, px)
            surf.prune()
        }
    }

    /// The alpha channel or Quick Mask the panel targets, as `"target"` params.
    public static func targetedChannel(_ s: Session) -> JSONValue? {
        guard let st = s.active else { return nil }
        switch st.channelView.target {
        case .alpha(let i) where i < st.doc.channels.count: return ["target": ["channel": .int(i)]]
        case .composite where st.doc.quickMask != nil: return ["target": "quickMask"]
        default: return nil
        }
    }

    /// Clear with an alpha channel or the Quick Mask targeted: the area takes the background
    /// colour, as gray.
    public static func clearChannel(_ doc: inout Document, _ target: JSONValue, background: SIMD4<Float>) throws {
        let canvas = doc.bounds
        let sel = doc.selection
        let area = sel.map { $0.contentBounds.intersect(canvas) } ?? canvas
        if area.isEmpty { return }
        try withTargetSurface(&doc, layer: nil, target) { surf, _ in
            Pixels.fillSurface(&surf, area, color: SIMD4(background.x, background.y, background.z, 1), selection: sel, lockTransparency: false)
        }
    }

    /// The active document targets an alpha channel or is in Quick Mask mode.
    public static func editsChannel(_ s: Session) -> Bool {
        guard let st = s.active else { return false }
        if st.doc.quickMask != nil && st.channelView.target == .composite { return true }
        if case .alpha(let i) = st.channelView.target, i < st.doc.channels.count { return true }
        return false
    }

    /// The precondition when the params target the active layer's mask.
    static func maskTargetEnabled(_ s: Session, _ id: String, _ p: JSONValue) -> Precondition? {
        guard targetOf(p) == .mask, editsMask(id) else { return nil }
        switch s.activeLayer() {
        case .failure(let e): return .some(e.description)
        case .success(let l): return .some(l.mask == nil ? "the active layer has no layer mask" : nil)
        }
    }

    /// JSON of the Channels panel (photocraft `channels_json`).
    public static func json(_ st: DocState) -> JSONValue {
        let doc = st.doc, v = st.channelView
        let names = colorNames(doc.pixelFormat.mode)
        return [
            "target": v.target.json,
            "composite": ["name": .string(compositeName(doc.pixelFormat.mode)), "visible": .bool(v.visibleColors(names.count) == names.count)],
            "colors": .array(names.enumerated().map { ["name": .string($1), "visible": .bool(v.colorVisible($0))] }),
            "alphas": .array(doc.channels.enumerated().map { i, c in
                ["name": .string(c.name), "visible": .bool(v.alphaShown(i)), "spot": .bool(c.spot != nil), "opacity": .float(c.opacity),
                 "indicates": .string(c.indicates.rawValue)]
            }),
            "quickMask": doc.quickMask == nil ? .null : ["visible": .bool(!v.quickMaskHidden)],
        ]
    }

    /// Installs the targeting hooks on a registry (the core does this for every session).
    static func installHooks(_ r: inout CommandRegistry) {
        r.hooks.prepareParams.append { s, id, p in injectTarget(s, id, p) }
        r.hooks.enabledOverride.append { s, id, p in maskTargetEnabled(s, id, p) }
        r.hooks.colorRestriction = { s, id, p in colorRestriction(s, id, p) }
        r.hooks.afterEdit.append { s, st, before in
            if let k = s.colorRestrict, let id = st.activeLayer { restrictToColor(before, &st.doc, id, k) }
            st.fixChannelView()
        }
        r.hooks.viewFixups.append { _, st in st.fixChannelView() }
        r.hooks.maskTargeted = { s in s.active?.channelView.target == .layerMask }
        // `channels` itself is reported by ChannelCommands (photocraft `channels_json`).
        r.hooks.documentInspectors.append { st, o in
            o["layerMaskView"] = st.currentMaskView.map { ["layer": .id($0.layer), "mode": .string($0.mode.rawValue)] } ?? .null
        }
    }
}
