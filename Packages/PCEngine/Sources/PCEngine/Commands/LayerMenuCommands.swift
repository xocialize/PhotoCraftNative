// Port of photocraft-engine (crates/engine/src/layer_menu_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Layer menu remnants: Layer Mask › Apply / From Transparency / Hide Selection, Mask All Objects,
// Matting, Smart Objects › Stack Mode and Reveal in Finder, Layer Style › Blending Options /
// Global Light / Create Layer / Scale Effects / transferring effects between layers, Layer Content
// Options, and exporting just the active layer (Quick Export as PNG, Export As). Mask All
// Objects (Select › Subject segmentation) and the matting decontamination are PCAlgo's
// (`LayerMenuCommands+Segment.swift`); the Euclidean distance transform for Defringe and the
// feathered-mask math of photocraft-compose are ported here as CPU references
// (`LayerMenuCommands+Algo.swift`). Smart Objects › Stack Mode re-renders the smart object from
// its source (`SmartCommands.refresh`); Export As encodes through `FileCommands.encode`.

import Foundation
import PCDocument
import PCFoundation
import PCPlatform
import PCRender

enum LayerMenuCommands: CommandModule {
    static let name = "layer_menu_cmds"

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// photocraft `num`: a number param as f32, else `fallback`.
    static func num(_ p: JSONValue, _ key: String, _ fallback: Float) -> Float { p[key]?.doubleValue.map { Float($0) } ?? fallback }

    static func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

    // MARK: Preconditions

    /// The active layer, or why there is none (photocraft `active_layer`).
    enum Active {
        case success(Layer)
        case failure(String)
    }

    static func activeLayer(_ s: Session) -> Active {
        guard let d = s.active else { return .failure("no document open") }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return .failure("no active layer") }
        return .success(l)
    }

    static let hasLayer: CommandEnabled = { s, _ in
        if case .failure(let why) = activeLayer(s) { return why }
        return nil
    }

    static let hasRaster: CommandEnabled = { s, _ in
        switch activeLayer(s) {
        case .failure(let why): return why
        case .success(let l):
            if case .raster = l.content { return nil }
            return "active layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer"
        }
    }

    static let hasRasterWithMask: CommandEnabled = { s, p in
        if let why = hasRaster(s, p) { return why }
        if case .success(let l) = activeLayer(s), l.mask != nil { return nil }
        return "the layer has no layer mask"
    }

    static let hasSelectionLayer: CommandEnabled = { s, p in
        if let why = hasLayer(s, p) { return why }
        return s.active?.doc.selection != nil ? nil : "no selection"
    }

    static let hasSmart: CommandEnabled = { s, _ in
        switch activeLayer(s) {
        case .failure(let why): return why
        case .success(let l):
            if case .smart = l.content { return nil }
            return "the active layer is not a smart object"
        }
    }

    static let hasLinkedSmart: CommandEnabled = { s, _ in
        switch activeLayer(s) {
        case .failure(let why): return why
        case .success(let l):
            if case .smart(let sm) = l.content, case .linked = sm.source { return nil }
            return "the active layer is not a linked smart object"
        }
    }

    /// The layer a command taking `{"layer":id?}` acts on: the one `"layer"` names (as `Session.layerParam`
    /// resolves it), else the active layer.
    static func targetLayer(_ s: Session, _ p: JSONValue) -> Active {
        guard let d = s.active else { return .failure("no document open") }
        guard let id = Params.layerId(p) else { return activeLayer(s) }
        guard let l = d.doc.layer(id) else { return .failure("no layer \(id)") }
        return .success(l)
    }

    /// Create Layer: the target layer shows an effect (its effects are on, and one of them is), which is what
    /// it makes layers from (AB-T-0300: it read the active layer whatever `"layer"` named).
    static let hasEffects: CommandEnabled = { s, p in
        switch targetLayer(s, p) {
        case .failure(let why): return why
        case .success(let l): return l.effects.enabled && l.effects.items.contains(where: \.isEnabled) ? nil : "the layer has no layer effects"
        }
    }

    /// Scale Effects: the target layer has effects, shown or hidden; Photoshop's Scale Effects scales hidden ones
    /// too (AB-T-0300).
    static let hasScalableEffects: CommandEnabled = { s, p in
        switch targetLayer(s, p) {
        case .failure(let why): return why
        case .success(let l): return l.effects.items.isEmpty ? "the layer has no layer effects" : nil
        }
    }

    static let hasContentOptions: CommandEnabled = { s, _ in
        switch activeLayer(s) {
        case .failure(let why): return why
        case .success(let l):
            switch l.content {
            case .adjustment, .fill, .text, .smart, .shape: return nil
            default: return "\(l.content.kindName) layers have no content options"
            }
        }
    }

    // MARK: RGBA helpers

    /// Straight RGBA of `surf` over `r` (row-major).
    static func readRGBA(_ surf: Surface, _ r: PixelRect) -> [SIMD4<Float>] { PixelCodec.toRGBA(surf.format, raw: surf.readRegion(r)) }

    static func writeRGBA(_ surf: inout Surface, _ r: PixelRect, _ px: [SIMD4<Float>]) {
        surf.writeRegion(r, PixelCodec.fromRGBA(surf.format, rgba: px))
    }

    /// photocraft `Rect::inflate`: grown by `d` on every side; empty stays empty.
    static func inflate(_ r: PixelRect, _ d: Int32) -> PixelRect { r.isEmpty ? r : r.outset(by: d) }

    /// One history step editing the active raster layer's RGBA (content bounds grown by `grow`).
    static func editRGBA(_ s: Session, _ label: String, grow: Int32, _ f: (inout [SIMD4<Float>], PixelRect) -> Void) throws -> JSONValue {
        let id = try s.layerParam(.null)
        try s.edit(label) { doc, _ in
            let bounds = doc.bounds
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in
                let r = inflate(surf.contentBounds, grow).intersect(inflate(bounds, grow))
                if r.isEmpty { return }
                var px = readRGBA(surf, r)
                f(&px, r)
                writeRGBA(&surf, r, px)
                surf.prune()
            }
        }
        return .null
    }

    // MARK: Layer masks

    /// Layer › Layer Mask › Apply: multiply the pixels' alpha by the mask, then delete the mask.
    static func applyMask(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        try s.edit("Apply Layer Mask") { doc, _ in
            guard let layer = doc.layer(id) else { throw EngineError.noLayer(id) }
            // Applying a feathered mask must bake the same softened coverage the compositor
            // displays; `LayerMask.values` accounts for density but not feather (#3044). An
            // independent vector mask stays attached and is not baked. Off-canvas pixels are
            // covered too: outside its area the combined mask is only the mask's default (#3043).
            var feathered: Algo.FeatheredMask?
            if let m = layer.mask, m.enabled, Algo.featherSigma(m.feather) > 0 {
                let area = layer.surface.map { doc.bounds.union($0.contentBounds) } ?? doc.bounds
                feathered = Algo.featheredMask(m, canvas: area)
            }
            guard let mask = layer.mask else { throw EngineError.other("the layer has no layer mask") }
            doc.updateLayer(id) { $0.mask = nil }
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in
                let r = surf.contentBounds
                if r.isEmpty { return }
                var px = readRGBA(surf, r)
                var m: [Float] = []
                if let feathered { m = feathered.read(r) } else { mask.values(r, into: &m) }
                for i in px.indices where i < m.count { px[i].w *= m[i] }
                writeRGBA(&surf, r, px)
                surf.prune()
            }
        }
        return .null
    }

    /// Layer › Layer Mask › From Transparency: the alpha becomes a layer mask and the pixels opaque.
    static func maskFromTransparency(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        try s.edit("From Transparency") { doc, _ in
            var mask = LayerMask.hideAll()
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in
                // Masks are attached to layer coordinates, including pixels temporarily
                // off-canvas: clipping to the document would lose their alpha (#3043).
                let r = surf.contentBounds
                if r.isEmpty { return }
                var px = readRGBA(surf, r)
                mask.surface.writeRegion(r, px.map(\.w))
                mask.surface.prune()
                for i in px.indices { px[i].w = 1 }
                writeRGBA(&surf, r, px)
            }
            let m = mask
            guard doc.updateLayer(id, { $0.mask = m }) != nil else { throw EngineError.noLayer(id) }
        }
        return .null
    }

    /// Layer › Layer Mask › Hide Selection: a mask that hides the selected area.
    static func hideSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let ids = try LayerMulti.maskTargets(s, p)
        try s.edit("Add Layer Mask") { doc, _ in
            guard let sel = doc.selection else { throw EngineError.other("no selection") }
            let bounds = doc.bounds
            let v = sel.coverage(bounds).map { 1 - $0 }
            var mask = LayerMask.revealAll()
            mask.surface.writeRegion(bounds, v)
            mask.surface.prune()
            for id in ids {
                LayerOps.backgroundToLayer(&doc, id)
                guard doc.updateLayer(id, { $0.mask = mask }) != nil else { throw EngineError.noLayer(id) }
            }
            doc.selection = nil
        }
        return .null
    }

    // MARK: Matting

    static func mattingDefringe(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let width = Int(clamp(num(p, "width", 1), 1, 200).rounded())
        return try editRGBA(s, "Defringe", grow: 1) { px, r in Algo.defringe(&px, r.width, r.height, width) }
    }

    /// Remove Black / White Matte: un-premultiply colours that were composited over black or white.
    static func removeMatte(_ s: Session, white: Bool) throws -> JSONValue {
        try editRGBA(s, white ? "Remove White Matte" : "Remove Black Matte", grow: 0) { px, _ in
            for i in px.indices where px[i].w > 0 && px[i].w < 1 {
                let a = px[i].w
                for c in 0..<3 {
                    let v = px[i][c]
                    px[i][c] = clamp(white ? (v - (1 - a)) / a : v / a, 0, 1)
                }
            }
        }
    }

    /// Layer › Matting › Color Decontaminate: fringe colours move toward nearby opaque colours
    /// (the Select and Mask decontamination, driven by the layer's own alpha).
    static func colorDecontaminate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let amount = clamp(num(p, "amount", 100), 0, 100)
        let radius = clamp(num(p, "radius", 4), 1, 100)
        let id = try s.layerParam(.null)
        try s.edit("Color Decontaminate") { doc, _ in
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in
                let r = surf.contentBounds
                if r.isEmpty || !surf.format.alpha { return }
                let alpha = readRGBA(surf, r).map { UInt8((clamp($0.w, 0, 1) * 255).rounded()) }
                surf = decontaminate(surf, bbox: r, alpha: alpha, radius: radius, amount: amount)
            }
        }
        return .null
    }

    // MARK: Smart objects

    /// Native-only: show a linked smart object's file in the platform file manager.
    static func revealInFinder(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { throw EngineError.other("no active layer") }
        guard case .smart(let sm) = l.content else { throw EngineError.other("the active layer is not a smart object") }
        guard case .linked(let path) = sm.source else { throw EngineError.other("embedded smart objects have no file to reveal") }
        return try reveal(path, dryRun: p["dryRun"]?.boolValue ?? false)
    }

    /// Show `path` in the platform file manager; `dryRun` answers the program and arguments
    /// instead (tests). Shared by the smart-object command and the document tab's Reveal in
    /// Finder (UI-217-6).
    static func reveal(_ path: String, dryRun: Bool) throws -> JSONValue {
        let (program, args) = revealCommand(path)
        if dryRun { return ["program": .string(program), "args": .strings(args)] }
        try spawn(program, args)
        return ["path": .string(path)]
    }

    /// The file-manager invocation that selects `path` on this platform.
    static func revealCommand(_ path: String) -> (String, [String]) {
        #if os(macOS)
        return ("open", ["-R", path])
        #elseif os(Windows)
        return ("explorer", ["/select,\(path)"])
        #else
        let parent = (path as NSString).deletingLastPathComponent
        return ("xdg-open", [parent.isEmpty ? "." : parent])
        #endif
    }

    static func spawn(_ program: String, _ args: [String]) throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [program] + args
        do { try proc.run() } catch { throw EngineError.other("\(program): \(error.localizedDescription)") }
        #else
        throw EngineError.other("Reveal in Finder needs the desktop app")
        #endif
    }

    // MARK: Layer style

    /// The Advanced Blending parameters of `layer.layerStyle.blendingOptions`; nil = keep.
    struct AdvancedParams {
        var knockout: Knockout?
        var blendInterior: Bool?
        var blendClipped: Bool?
        var transparencyShapes: Bool?
        var layerMaskHides: Bool?
        var vectorMaskHides: Bool?
        /// Excluded-channel bit mask (from `channels`).
        var excluded: UInt32?

        func apply(_ l: inout Layer) {
            if let k = knockout { l.advanced.knockout = k }
            if let v = blendInterior { l.advanced.blendInterior = v }
            if let v = blendClipped { l.advanced.blendClipped = v }
            if let v = transparencyShapes { l.advanced.transparencyShapes = v }
            if let v = layerMaskHides { l.advanced.layerMaskHidesEffects = v }
            if let v = vectorMaskHides { l.advanced.vectorMaskHidesEffects = v }
            if let x = excluded { l.excludedChannels = x }
        }
    }

    static let blendingCmd = "layer.layerStyle.blendingOptions"

    /// Parse and validate the Advanced Blending keys (wrong types and unknown values are errors).
    static func advancedParams(_ p: JSONValue, _ mode: ColorMode) throws -> AdvancedParams {
        let cmd = blendingCmd
        func flag(_ key: String) throws -> Bool? {
            switch p[key] {
            case nil, .some(.null): return nil
            case .some(.bool(let b)): return b
            case let v?: throw bad(cmd, "\(key): expected true or false (got \(v))")
            }
        }
        var a = AdvancedParams()
        switch p["knockout"] {
        case nil, .some(.null): break
        case .some(.string(let s)):
            guard let k = Knockout(name: s) else { throw bad(cmd, "knockout: expected none, shallow or deep (got `\(s)`)") }
            a.knockout = k
        case let v?: throw bad(cmd, "knockout: expected \"none\", \"shallow\" or \"deep\" (got \(v))")
        }
        switch p["channels"] {
        case nil, .some(.null): break
        case .some(.array(let arr)):
            let n = max(mode.colorChannels, 1)
            if arr.count > n {
                throw bad(cmd, "channels: a \(LayerCopyCommands.modeDebugName(mode)) document has \(n) colour channel(s), got \(arr.count)")
            }
            var mask: UInt32 = 0
            for (i, v) in arr.enumerated() {
                switch v {
                case .bool(true): break
                case .bool(false): mask |= 1 << UInt32(i)
                default: throw bad(cmd, "channels[\(i)]: expected true or false (got \(v))")
                }
            }
            a.excluded = mask
        case let v?: throw bad(cmd, "channels: expected a list of true/false per colour channel (got \(v))")
        }
        a.blendInterior = try flag("blendInteriorEffectsAsGroup")
        a.blendClipped = try flag("blendClippedLayersAsGroup")
        a.transparencyShapes = try flag("transparencyShapesLayer")
        a.layerMaskHides = try flag("layerMaskHidesEffects")
        a.vectorMaskHides = try flag("vectorMaskHidesEffects")
        return a
    }

    /// One `blendIf` entry: (range index, This Layer, Underlying Layer); nil = keep.
    typealias BlendIfEntry = (index: Int, this: BlendRange?, under: BlendRange?)

    /// Parse `blendIf`: `null` (reset: nil) or one or more `{"channel", "thisLayer"?, "underlying"?}`.
    static func blendIfEntries(_ v: JSONValue, _ mode: ColorMode) throws -> [BlendIfEntry]? {
        let cmd = blendingCmd
        let items: [JSONValue]
        switch v {
        case .null: return nil
        case .array(let a): items = a
        case .object: items = [v]
        default: throw bad(cmd, "blendIf: expected an object, a list of objects or null")
        }
        var out: [BlendIfEntry] = []
        for it in items {
            let ch = it["channel"] ?? .null
            guard let i = blendIfChannel(ch, mode) else {
                throw bad(cmd, "blendIf: unknown channel \(ch) for a \(LayerCopyCommands.modeDebugName(mode)) document")
            }
            func range(_ key: String) throws -> BlendRange? {
                guard let r = it[key] else { return nil }
                guard let br = blendRange(r) else {
                    throw bad(cmd, "blendIf.\(key): expected [black, white] or [blackLow, blackHigh, whiteLow, whiteHigh], 0..255, in increasing order (got \(r))")
                }
                return br
            }
            out.append((i, try range("thisLayer"), try range("underlying")))
        }
        return out
    }

    /// Blend If channel → range index: 0 = Gray, then the mode's colour channels in order. A
    /// grayscale document's Gray is its one channel.
    static func blendIfChannel(_ v: JSONValue, _ mode: ColorMode) -> Int? {
        let n = mode.colorChannels
        if let i = v.uint64Value { return i <= UInt64(n) ? Int(i) : nil }
        let name = (v.stringValue ?? "gray").lowercased()
        let names: [String] = switch mode {
        case .rgb, .indexed: ["red", "green", "blue"]
        case .cmyk: ["cyan", "magenta", "yellow", "black"]
        case .lab: ["lightness", "a", "b"]
        default: []
        }
        if name == "gray" || name == "grey" { return n == 1 ? 1 : 0 }
        return names.firstIndex(of: name).map { $0 + 1 }
    }

    /// `[black, white]` (unsplit) or `[blackLow, blackHigh, whiteLow, whiteHigh]`, each 0...255
    /// and in increasing order (the dialog's sliders can't cross).
    static func blendRange(_ v: JSONValue) -> BlendRange? {
        guard let a = v.arrayValue else { return nil }
        var n: [UInt8] = []
        for x in a {
            guard let f = x.doubleValue, f >= 0, f <= 255 else { return nil }
            n.append(UInt8(f.rounded()))
        }
        let q: [UInt8]
        switch n.count {
        case 2: q = [n[0], n[0], n[1], n[1]]
        case 4: q = n
        default: return nil
        }
        for k in 0..<3 where q[k] > q[k + 1] { return nil }
        return BlendRange(bytes: q)
    }

    static func blendingOptions(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = blendingCmd
        let id = try s.layerParam(p)
        var blend: BlendMode?
        if let b = p["blend"]?.stringValue {
            guard let m = Params.blendMode(b) else { throw bad(cmd, "unknown blend mode `\(b)`") }
            blend = m
        }
        let opacity = p["opacity"]?.doubleValue.map { clamp(Float($0) / 100, 0, 1) }
        let fill = p["fillOpacity"]?.doubleValue.map { clamp(Float($0) / 100, 0, 1) }
        guard let mode = s.active?.doc.mode else { throw EngineError.noDocument }
        // nil: keep; .some(nil): reset; .some(entries): set.
        let blendIf: [BlendIfEntry]?? = try p["blendIf"].map { try blendIfEntries($0, mode) }
        let adv = try advancedParams(p, mode)
        try s.edit("Blending Options") { doc, _ in
            guard try doc.updateLayer(id, { (l: inout Layer) -> Void in
                if let b = blend {
                    if b == .passThrough && !l.isGroup { throw bad(cmd, "Pass Through is for groups") }
                    l.blend = b
                }
                if let o = opacity { l.opacity = o }
                if let f = fill { l.fillOpacity = f }
                switch blendIf {
                case .some(.none): l.blendIf = BlendIf()
                case .some(.some(let entries)):
                    for e in entries {
                        let cur = l.blendIf.get(e.index)
                        l.blendIf.set(e.index, BlendRangePair(e.this ?? cur.this, e.under ?? cur.underlying))
                    }
                case .none: break
                }
                adv.apply(&l)
            }) != nil else { throw EngineError.noLayer(id) }
        }
        return .null
    }

    static func globalLight(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let cur = s.active?.doc.globalLight else { throw EngineError.noDocument }
        let raw = num(p, "angle", cur.angle)
        let altitude = clamp(num(p, "altitude", cur.altitude), 0, 90)
        var r = (raw + 180).truncatingRemainder(dividingBy: 360)
        if r < 0 { r += 360 }
        let angle = r - 180
        try s.edit("Global Light") { doc, _ in
            doc.globalLight.angle = angle
            doc.globalLight.altitude = altitude
        }
        return ["angle": .float(angle), "altitude": .float(altitude)]
    }

    /// photocraft `image_cmds::scale_effects`: scales every size-like effect setting by `k`.
    static func scaleEffects(_ fx: inout Effects, _ k: Float) {
        for i in fx.items.indices {
            switch fx.items[i] {
            case .dropShadow(var s): s.distance *= k; s.size *= k; fx.items[i] = .dropShadow(s)
            case .innerShadow(var s): s.distance *= k; s.size *= k; fx.items[i] = .innerShadow(s)
            case .outerGlow(var g): g.size *= k; fx.items[i] = .outerGlow(g)
            case .innerGlow(var g): g.size *= k; fx.items[i] = .innerGlow(g)
            case .stroke(var s):
                s.size *= k
                if case .pattern(var pr) = s.paint { pr.scale *= k; s.paint = .pattern(pr) }
                fx.items[i] = .stroke(s)
            case .satin(var s): s.distance *= k; s.size *= k; fx.items[i] = .satin(s)
            case .bevelEmboss(var b): b.size *= k; b.soften *= k; fx.items[i] = .bevelEmboss(b)
            case .patternOverlay(var o): o.scale *= k; fx.items[i] = .patternOverlay(o)
            case .gradientOverlay, .colorOverlay: break
            }
        }
        // Effects changed: the preserved PSD block no longer applies.
        if k != 1 { fx.psdRaw = nil }
    }

    static func scaleEffectsCommand(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let k = clamp(num(p, "scale", 100), 1, 1000) / 100
        let id = try s.layerParam(p)
        try s.edit("Scale Effects") { doc, _ in
            guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                scaleEffects(&l.effects, k)
                l.effects.psdRaw = nil
            }) != nil else { throw EngineError.noLayer(id) }
        }
        return .null
    }

    /// The kind of an effect (Rust's `mem::discriminant`).
    static func effectKind(_ e: Effect) -> Int {
        switch e {
        case .dropShadow: 0
        case .innerShadow: 1
        case .outerGlow: 2
        case .innerGlow: 3
        case .stroke: 4
        case .colorOverlay: 5
        case .gradientOverlay: 6
        case .patternOverlay: 7
        case .satin: 8
        case .bevelEmboss: 9
        }
    }

    /// Dragging a layer's fx onto another layer in the Layers panel: all its effects (or just the
    /// one at `effect`) move there, or with `copy` are copied. Moving all effects replaces the
    /// target's style, as pasting a layer style does; a single effect replaces the target's
    /// effect of the same kind, else is added.
    static func transferEffects(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "layer.layerStyle.transferEffects"
        func idOf(_ key: String) throws -> LayerId {
            guard let n = p[key]?.uint64Value else { throw bad(cmd, "`\(key)` must be a layer id") }
            return LayerId(n)
        }
        let from = try idOf("from")
        let to = try idOf("to")
        if from == to { throw bad(cmd, "the effects are already on that layer") }
        let copy = p["copy"]?.boolValue ?? false
        let index: Int?
        switch p["effect"] {
        case nil, .some(.null): index = nil
        case let v?:
            guard let i = v.uint64Value.flatMap({ Int(exactly: $0) }) else { throw bad(cmd, "`effect` must be an effect index") }
            index = i
        }
        guard let d = s.active else { throw EngineError.noDocument }
        guard let src = d.doc.layer(from) else { throw EngineError.noLayer(from) }
        guard d.doc.layer(to) != nil else { throw EngineError.noLayer(to) }
        var payload: Effects
        if let i = index {
            guard i < src.effects.items.count else { throw bad(cmd, "the layer has no effect \(i)") }
            payload = Effects(enabled: true, items: [src.effects.items[i]], psdRaw: nil, reference: nil)
        } else {
            payload = src.effects
            payload.psdRaw = nil
        }
        if payload.items.isEmpty { throw bad(cmd, "the layer has no layer effects") }
        let moved = payload
        try s.edit(copy ? "Copy Layer Effects" : "Move Layer Effects") { doc, _ in
            guard doc.updateLayer(to, { (dst: inout Layer) -> Void in
                dst.effects.psdRaw = nil
                if index != nil {
                    dst.effects.enabled = true
                    for e in moved.items {
                        if let slot = dst.effects.items.firstIndex(where: { effectKind($0) == effectKind(e) }) {
                            dst.effects.items[slot] = e
                        } else {
                            dst.effects.items.append(e)
                        }
                    }
                } else {
                    dst.effects = moved
                }
            }) != nil else { throw EngineError.noLayer(to) }
            if !copy {
                guard doc.updateLayer(from, { (src: inout Layer) -> Void in
                    switch index {
                    case let i? where i < src.effects.items.count:
                        src.effects.items.remove(at: i)
                        src.effects.psdRaw = nil
                    case .some: break
                    case nil: src.effects = Effects()
                    }
                }) != nil else { throw EngineError.noLayer(from) }
            }
        }
        return ["from": .id(from), "to": .id(to)]
    }

    /// Effects drawn beneath the layer (they become separate layers below it, unclipped).
    static func isBelow(_ e: Effect) -> Bool {
        switch e {
        case .dropShadow, .outerGlow: true
        case .stroke(let st): st.position == .outside
        case .bevelEmboss(let b): b.style == .outerBevel || b.style == .emboss || b.style == .pillowEmboss
        default: false
        }
    }

    /// The effect's blend mode and opacity, which become the new layer's, with the effect itself
    /// set to Normal at full opacity (photocraft `effect_common_mut`).
    static func neutralize(_ e: inout Effect) -> (BlendMode, Float) {
        func take(_ c: inout FxCommon) -> (BlendMode, Float) {
            let r = (c.blend, c.opacity)
            c.blend = .normal
            c.opacity = 1
            return r
        }
        switch e {
        case .dropShadow(var s): let r = take(&s.common); e = .dropShadow(s); return r
        case .innerShadow(var s): let r = take(&s.common); e = .innerShadow(s); return r
        case .outerGlow(var g): let r = take(&g.common); e = .outerGlow(g); return r
        case .innerGlow(var g): let r = take(&g.common); e = .innerGlow(g); return r
        case .stroke(var s): let r = take(&s.common); e = .stroke(s); return r
        case .colorOverlay(var o): let r = take(&o.common); e = .colorOverlay(o); return r
        case .gradientOverlay(var o): let r = take(&o.common); e = .gradientOverlay(o); return r
        case .patternOverlay(var o): let r = take(&o.common); e = .patternOverlay(o); return r
        case .satin(var s): let r = take(&s.common); e = .satin(s); return r
        case .bevelEmboss: return (.normal, 1)
        }
    }

    /// Layer › Layer Style › Create Layer: each enabled effect is rendered on its own (normal
    /// blend, full opacity) into a pixel layer named like Photoshop's ("<layer>'s Drop Shadow"),
    /// carrying the effect's blend mode and opacity. Shadows/glows/outer strokes go below the
    /// layer; inner effects and overlays go above it, clipped to it. The layer keeps its pixels
    /// and loses its effects.
    static func createLayer(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let renderer = s.services.renderer
        let made = try s.edit("Create Layers") { doc, active -> Int in
            let canvas = doc.bounds
            let fmt = doc.pixelFormat
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            let effects = l.effects.items.filter(\.isEnabled)
            if effects.isEmpty || !l.effects.enabled { throw EngineError.other("the layer has no layer effects") }
            let area = inflate(l.surface.map { $0.contentBounds.union(canvas) } ?? canvas, 256)
            var below: [Layer] = []
            var above: [Layer] = []
            for e in effects {
                var alone = l
                alone.visible = true
                alone.opacity = 1
                alone.blend = .normal
                alone.clipped = false
                alone.mask = nil
                // Fill opacity 0 hides the layer's own pixels; effects still draw.
                alone.fillOpacity = 0
                var e1 = e
                let (blend, opacity) = neutralize(&e1)
                alone.effects.items = [e1]
                alone.effects.psdRaw = nil
                var tmp = Document(name: "fx", size: doc.size, mode: doc.mode, depth: doc.depth)
                tmp.globalLight = doc.globalLight
                tmp.patterns = doc.patterns
                tmp.layers = [alone]
                let buf = try renderer.render(tmp, region: area)
                var surf = Surface(format: fmt)
                surf.writeRegion(area, PixelCodec.fromRGBA(fmt, rgba: buf.px))
                surf.prune()
                var nl = Layer(name: "\(l.name)'s \(e.label)", content: .raster(surf))
                nl.blend = blend
                nl.opacity = opacity
                if isBelow(e) {
                    below.append(nl)
                } else {
                    nl.clipped = true
                    above.append(nl)
                }
            }
            let n = below.count + above.count
            guard doc.updateLayer(id, { (src: inout Layer) -> Void in
                src.effects.items.removeAll()
                src.effects.psdRaw = nil
            }) != nil else { throw EngineError.noLayer(id) }
            // Below layers under the source (in order), clipped layers above it.
            var prev = id
            for nl in above { prev = try doc.insert(nl, at: .above(prev)) }
            for nl in below { try doc.insert(nl, at: .below(id)) }
            active = id
            return n
        }
        return ["layers": .int(made)]
    }

    /// Layer › Layer Content Options…: which editor the active layer opens (UIs show it).
    static func contentOptions(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let l: Layer
        switch activeLayer(s) {
        case .failure(let why): throw EngineError.other(why)
        case .success(let layer): l = layer
        }
        let editor: String
        switch l.content {
        case .adjustment(let a): editor = "adjustment:\(AdjustParams.kind(of: a))"
        case .fill: editor = "fill"
        case .text: editor = "text"
        case .smart: editor = "smartObject"
        case .shape: editor = "shape"
        default: throw EngineError.other("\(l.content.kindName) layers have no content options")
        }
        return ["layer": .id(l.id), "editor": .string(editor)]
    }

    // MARK: Smart object stack modes

    /// Layer › Smart Objects › Stack Mode: the smart object's layers combined per pixel with
    /// `mode` (none: composited), re-rendered from its source (photocraft `stack_mode`).
    static func stackMode(_ s: Session, _ p: JSONValue, _ mode: StackMode?) throws -> JSONValue {
        let id = try s.layerParam(p)
        let label = mode?.label ?? "None"
        let services = s.services
        try s.edit("Stack Mode: \(label)") { doc, _ in
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard case .smart = l.content else { throw EngineError.other("the active layer is not a smart object") }
            doc.updateLayer(id) { $0.withSmartObject { $0.stackMode = mode } }
            try SmartCommands.refresh(&doc, id, services: services)
        }
        return ["stackMode": mode.map { .string($0.id) } ?? .null]
    }

    // MARK: Export just the active layer

    /// The layer rendered alone (visible, its blend mode ignored) and trimmed to its pixels, as a
    /// one-layer document — what Export As does for a layer (photocraft `layer_document`).
    static func layerDocument(_ doc: Document, _ id: LayerId, renderer: EngineRenderer = .shared) throws -> Document {
        guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
        var alone = l
        alone.visible = true
        alone.blend = alone.isGroup ? .passThrough : .normal
        alone.clipped = false
        var tmp = doc
        tmp.layers = [alone]
        tmp.selection = nil
        let area = doc.bounds
        if area.isEmpty { throw EngineError.other("the layer is empty") }
        let buf = try renderer.render(tmp, region: area)
        let w = area.width
        var b = PixelRect.empty
        var (bx0, by0, bx1, by1) = (Int32.max, Int32.max, Int32.min, Int32.min)
        for (i, q) in buf.px.enumerated() where q.w > 0 {
            let x = area.x0 + Int32(i % w), y = area.y0 + Int32(i / w)
            bx0 = min(bx0, x); by0 = min(by0, y); bx1 = max(bx1, x + 1); by1 = max(by1, y + 1)
        }
        if bx0 < bx1 && by0 < by1 { b = PixelRect(x0: bx0, y0: by0, x1: bx1, y1: by1) }
        if b.isEmpty { throw EngineError.other("the layer is empty") }
        let fmt = doc.pixelFormat
        var out = Document(name: l.name, size: PixelSize(width: b.width, height: b.height), mode: doc.mode, depth: doc.depth)
        out.resolutionDpi = doc.resolutionDpi
        out.iccProfile = doc.iccProfile
        var rows: [SIMD4<Float>] = []
        rows.reserveCapacity(b.area)
        for y in b.y0..<b.y1 {
            let row = Int(y - area.y0) * w
            for x in b.x0..<b.x1 { rows.append(buf.px[row + Int(x - area.x0)]) }
        }
        var surf = Surface(format: fmt)
        surf.writeRegion(PixelRect(x: 0, y: 0, width: b.width, height: b.height), PixelCodec.fromRGBA(fmt, rgba: rows))
        out.layers.append(Layer(name: l.name, content: .raster(surf)))
        return out
    }

    static func exportLayer(_ s: Session, _ p: JSONValue, _ cmd: String, pngOnly: Bool) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        let renderer = s.services.renderer
        var ldoc = try layerDocument(d.doc, id, renderer: renderer)
        guard let path = p["path"]?.stringValue, !path.isEmpty else { throw bad(cmd, "missing `path` (UIs ask for one)") }
        if pngOnly && !path.lowercased().hasSuffix(".png") { throw bad(cmd, "Quick Export as PNG writes .png files") }
        let scale = clamp(num(p, "scale", 100), 1, 1000)
        if abs(scale - 100) > 1e-3 {
            // Image Size on a scratch session holding the layer's document.
            let tmp = Session(registry: s.registry, services: s.services, preferences: s.preferences)
            tmp.addDocument(ldoc)
            let w = max((Float(tmp.active?.doc.size.width ?? 1) * scale / 100).rounded(), 1)
            try tmp.execute("image.imageSize", ["width": .float(w)])
            guard let resized = tmp.active?.doc else { throw EngineError.noDocument }
            ldoc = resized
        }
        // Every format photocraft-io writes, layered ones included (photocraft `photocraft_io::export`).
        let (bytes, warnings) = try FileCommands.encode(s, ldoc, path)
        try FileCommands.writeFile(s, path, bytes)
        return ["path": .string(path), "bytes": .int(bytes.count), "width": .int(ldoc.size.width), "height": .int(ldoc.size.height),
                "warnings": .strings(warnings)]
    }

    // MARK: Registration

    static func register(into r: inout CommandRegistry) {
        let m = name
        func spec(_ id: String, _ label: String, _ menu: [String], _ params: String, _ enabled: @escaping CommandEnabled,
                  _ run: @escaping CommandRun) -> CommandSpec {
            CommandSpec(id, label, menu: menu, params: params, module: m, enabled: enabled, run: run)
        }
        r.add(spec("layer.layerMask.apply", "Apply", ["Layer", "Layer Mask"], ##"{"layer":id?}"##, hasRasterWithMask, applyMask))
        r.add(spec("layer.layerMask.fromTransparency", "From Transparency", ["Layer", "Layer Mask"], ##"{"layer":id?}"##, hasRaster, maskFromTransparency))
        r.add(spec("layer.layerMask.hideSelection", "Hide Selection", ["Layer", "Layer Mask"],
                   ##"{"layer":id?} (no layer: every selected layer that can take a mask)"##, hasSelectionLayer, hideSelection))
        r.add(spec("layer.maskAllObjects", "Mask All Objects", ["Layer"], ##"{"layer":id?}"##, hasLayer, maskAllObjects))
        r.add(spec("layer.matting.defringe", "Defringe…", ["Layer", "Matting"], ##"{"width":1..200=1}"##, hasRaster, mattingDefringe))
        r.add(spec("layer.matting.removeBlackMatte", "Remove Black Matte", ["Layer", "Matting"], "{}", hasRaster) { s, _ in try removeMatte(s, white: false) })
        r.add(spec("layer.matting.removeWhiteMatte", "Remove White Matte", ["Layer", "Matting"], "{}", hasRaster) { s, _ in try removeMatte(s, white: true) })
        r.add(spec("layer.matting.colorDecontaminate", "Color Decontaminate…", ["Layer", "Matting"], ##"{"amount":0..100=100,"radius":1..100=4}"##,
                   hasRaster, colorDecontaminate))
        let stackModes: [(String, String)] = [
            ("entropy", "Entropy"), ("kurtosis", "Kurtosis"), ("maximum", "Maximum"), ("mean", "Mean"), ("median", "Median"),
            ("minimum", "Minimum"), ("range", "Range"), ("skewness", "Skewness"), ("standardDeviation", "Standard Deviation"),
            ("summation", "Summation"), ("variance", "Variance"), ("none", "None"),
        ]
        for (id, label) in stackModes {
            let mode = StackMode(id: id)
            r.add(spec("layer.smartObjects.stackMode.\(id)", label, ["Layer", "Smart Objects", "Stack Mode"], ##"{"layer":id?}"##, hasSmart) { s, p in
                try stackMode(s, p, mode)
            })
        }
        r.add(spec("layer.smartObjects.revealInFinder", "Reveal in Finder", ["Layer", "Smart Objects"], ##"{"dryRun":bool=false}"##,
                   hasLinkedSmart, revealInFinder))
        r.add(spec("layer.layerStyle.blendingOptions", "Blending Options…", ["Layer", "Layer Style"],
                   ##"{"layer":id?,"blend":"normal|multiply|…"?,"opacity":0..100?,"fillOpacity":0..100?,"blendIf":{"channel":"gray|red|green|blue|cyan|…"|index="gray","thisLayer":[black,white]|[blackLo,blackHi,whiteLo,whiteHi]?,"underlying":[…]?}|[{…},…]|null?,"channels":[bool,…]?,"knockout":"none|shallow|deep"?,"blendInteriorEffectsAsGroup":bool?,"blendClippedLayersAsGroup":bool?,"transparencyShapesLayer":bool?,"layerMaskHidesEffects":bool?,"vectorMaskHidesEffects":bool?} (Blend If values 0..255; split points fade; null resets. Advanced Blending: channels = which colour channels blend (R G B / C M Y K / L a b); PhotoCraft's defaults are knockout none, interior effects off, clipped layers as group on, transparency shapes on, masks hide effects off)"##,
                   hasLayer, blendingOptions))
        r.add(spec("layer.layerStyle.globalLight", "Global Light…", ["Layer", "Layer Style"], ##"{"angle":-180..180=120,"altitude":0..90=30}"##,
                   Pre.hasDoc, globalLight))
        r.add(spec("layer.layerStyle.createLayer", "Create Layer", ["Layer", "Layer Style"], ##"{"layer":id?}"##, hasEffects, createLayer))
        r.add(spec("layer.layerStyle.scaleEffects", "Scale Effects…", ["Layer", "Layer Style"], ##"{"layer":id?,"scale":1..1000=100} (every effect of the layer, shown or hidden)"##, hasScalableEffects, scaleEffectsCommand))
        r.add(spec("layer.layerStyle.transferEffects", "Move Layer Effects", [],
                   ##"{"from":id,"to":id,"effect":index? (default: all effects),"copy":bool=false}"##, Pre.hasDoc, transferEffects))
        r.add(CommandSpec("layer.layerContentOptions", "Layer Content Options…", menu: ["Layer"], params: "{}", module: m, journal: false,
                          enabled: hasContentOptions, run: contentOptions))
        r.add(spec("layer.quickExportAsPng", "Quick Export as PNG", ["Layer"], ##"{"layer":id?,"path":text}"##, hasLayer) { s, p in
            try exportLayer(s, p, "layer.quickExportAsPng", pngOnly: true)
        })
        r.add(spec("layer.exportAs", "Export As…", ["Layer"], ##"{"layer":id?,"path":text,"scale":1..1000=100} (format from the path's extension)"##,
                   hasLayer) { s, p in
            try exportLayer(s, p, "layer.exportAs", pngOnly: false)
        })
    }
}
