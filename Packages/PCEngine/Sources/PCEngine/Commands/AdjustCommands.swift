// Port of photocraft-engine (crates/engine/src/adjust_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Image › Adjustments beyond the per-pixel adjustment-layer kinds:
//
// * parameter parsing for Selective Color and Color Lookup (both also adjustment layers; their
//   commands are generated with the other kinds in `CoreCommands`),
// * the destructive-only adjustments: Replace Color, Match Color and HDR Toning (the CPU maths in
//   `AdjustCommands+ToneKit.swift`) and Shadows/Highlights (PCAlgo's ToneKit,
//   `AdjustCommands+ShadowsHighlights.swift`),
// * Image › Adjustments on a smart object recorded as a smart filter (`adjustAsSmartFilter`) and
//   re-run from params (`adjustAsFilter`).
//
// Destructive adjustments convert the target (layer pixels, or a targeted mask / alpha channel /
// Quick Mask) to straight RGBA, so every colour model and bit depth is handled, and blend the
// result through the selection like the other Image › Adjustments commands.

import Foundation
import PCDocument
import PCFoundation

enum AdjustCommands: CommandModule {
    static let name = "adjust_cmds"
    static let m = name

    /// Selective Color range keys in storage order.
    static let ranges = ["reds", "yellows", "greens", "cyans", "blues", "magentas", "whites", "neutrals", "blacks"]

    /// Built-in Color Lookup looks `(id, label)`.
    static var looks: [(id: String, label: String)] { LutFile.builtinLooks }

    // MARK: Param helpers

    /// `key`'s value; a null counts as missing (as in `AdjustParams`).
    static func given(_ p: JSONValue, _ key: String) -> JSONValue? {
        guard let v = p[key], v != .null else { return nil }
        return v
    }

    static func optStr(_ cmd: String, _ p: JSONValue, _ key: String) throws -> String? {
        guard let v = given(p, key) else { return nil }
        guard case .string(let s) = v else { throw EngineError.bad(cmd, "`\(key)` must be a string") }
        return s
    }

    static func optBool(_ cmd: String, _ p: JSONValue, _ key: String) throws -> Bool? {
        guard let v = given(p, key) else { return nil }
        guard case .bool(let b) = v else { throw EngineError.bad(cmd, "`\(key)` must be true or false") }
        return b
    }

    /// A percentage in -100...100 (clamped); anything but a finite number is an error.
    static func percent(_ cmd: String, _ key: String, _ v: JSONValue) throws -> Float {
        guard let x = v.doubleValue, x.isFinite else { throw EngineError.bad(cmd, "`\(key)` must be a number") }
        return Swift.min(Swift.max(Float(x), -100), 100)
    }

    /// photocraft `num`: a number param, else `def`.
    static func num(_ p: JSONValue, _ key: String, _ def: Float) -> Float { p[key]?.doubleValue.map { Float($0) } ?? def }

    // MARK: Selective Color / Color Lookup params

    /// Selective Color from params. Accepts per-range arrays (`"reds":[c,m,y,k]` in percent) and the
    /// dialog's single-range form (`"colors":"reds","cyan":…,"magenta":…,"yellow":…,"black":…`);
    /// `"method":"relative|absolute"`. Unspecified ranges keep `base`'s values; a key of the wrong
    /// type is an error.
    static func selectiveFromParams(_ p: JSONValue, base: Adjustment?) throws -> Adjustment {
        let cmd = "selectiveColor"
        var relative = true
        var adj = [SIMD4<Float>](repeating: .zero, count: 9)
        if case .selectiveColor(let sc)? = base {
            relative = sc.relative
            adj = (0..<9).map { $0 < sc.adjustments.count ? sc.adjustments[$0] : .zero }
        }
        switch try optStr(cmd, p, "method") {
        case nil: break
        case "relative"?: relative = true
        case "absolute"?: relative = false
        case let m?: throw EngineError.bad(cmd, "`method` must be \"relative\" or \"absolute\", not `\(m)`")
        }
        if let b = try optBool(cmd, p, "relative") { relative = b }
        for (i, key) in ranges.enumerated() {
            guard let v = given(p, key) else { continue }
            guard let a = v.arrayValue, a.count == 4 else { throw EngineError.bad(cmd, "`\(key)` must be an array of 4 numbers [c, m, y, k]") }
            for k in 0..<4 { adj[i][k] = try percent(cmd, key, a[k]) }
        }
        if let c = try optStr(cmd, p, "colors") {
            guard let i = ranges.firstIndex(of: c) else {
                throw EngineError.bad(cmd, "unknown range `\(c)` (ranges: \(ranges.joined(separator: ", ")))")
            }
            for (k, key) in ["cyan", "magenta", "yellow", "black"].enumerated() {
                if let v = given(p, key) { adj[i][k] = try percent(cmd, key, v) }
            }
        }
        return .selectiveColor(.init(relative: relative, adjustments: adj))
    }

    /// Color Lookup from params: `"lut"` (a built-in look id or `"none"`), `"file"` (a .cube / .3dl
    /// / .look path) or `"data"` (the file's text, with `"fileName"` naming its format),
    /// `"interpolation":"trilinear|tetrahedral"`, `"dither":bool`. The table is embedded in the
    /// layer, as Photoshop does. Unspecified fields keep `base`'s values; a key of the wrong type is
    /// an error.
    static func lookupFromParams(_ p: JSONValue, base: Adjustment?) throws -> Adjustment {
        let cmd = "colorLookup"
        var name = "", lut: [Float]? = nil, size: UInt32 = 0, tetrahedral = false, dither = false
        if case .colorLookup(let cl)? = base { (name, lut, size, tetrahedral, dither) = (cl.name, cl.lut, cl.size, cl.tetrahedral, cl.dither) }
        var loaded: (LutFile, String)?
        if let id = try optStr(cmd, p, "lut") {
            if id == "none" || id.isEmpty {
                name = ""
                lut = nil
                size = 0
            } else {
                guard let f = LutFile.builtin(id) else {
                    throw EngineError.bad(cmd, "unknown look `\(id)` (built-ins: \(looks.map(\.id).joined(separator: ", ")))")
                }
                loaded = (f, f.title)
            }
        }
        let fileName = try optStr(cmd, p, "fileName")
        if let text = try optStr(cmd, p, "data") {
            let fname = fileName ?? "lut.cube"
            switch LutFile.parse(fname, Array(text.utf8)) {
            case .success(let f): loaded = (f, baseName(fname))
            case .failure(let e): throw EngineError.bad(cmd, e.message)
            }
        }
        if let path = try optStr(cmd, p, "file"), !path.isEmpty {
            guard let data = FileManager.default.contents(atPath: path) else { throw EngineError.bad(cmd, "can't read \(path)") }
            switch LutFile.parse(path, Array(data)) {
            case .success(let f): loaded = (f, baseName(path))
            case .failure(let e): throw EngineError.bad(cmd, "\(path): \(e.message)")
            }
        }
        if let (f, label) = loaded {
            if !f.domainIsDefault {
                let (lo, hi) = f.domainDescription
                throw EngineError.bad(cmd, "`\(label)` declares DOMAIN_MIN \(lo) / DOMAIN_MAX \(hi): Color Lookup applies the plain 0..1 domain, so the look would shift; honouring a custom domain is not supported yet")
            }
            name = label
            size = UInt32(clamping: f.size)
            lut = f.data
        }
        switch try optStr(cmd, p, "interpolation") {
        case nil: break
        case "trilinear"?: tetrahedral = false
        case "tetrahedral"?: tetrahedral = true
        case let i?: throw EngineError.bad(cmd, "`interpolation` must be \"trilinear\" or \"tetrahedral\", not `\(i)`")
        }
        if let b = try optBool(cmd, p, "tetrahedral") { tetrahedral = b }
        if let b = try optBool(cmd, p, "dither") { dither = b }
        return .colorLookup(.init(name: name, lut: lut, size: size, tetrahedral: tetrahedral, dither: dither))
    }

    static func baseName(_ path: String) -> String {
        path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// `layer.setAdjustment` for the kinds edited one range / option at a time: params merge into
    /// the current values; a call with no parameters resets to defaults. nil for other kinds.
    static func updateAdjustment(_ existing: Adjustment, _ p: JSONValue) throws -> Adjustment? {
        let empty = p.objectValue.map { $0.keys.allSatisfy { ["layer", "coalesce", "__kind"].contains($0) } } ?? true
        switch existing {
        case .selectiveColor: return try selectiveFromParams(p, base: empty ? nil : existing)
        case .colorLookup: return try lookupFromParams(p, base: empty ? nil : existing)
        default: return nil
        }
    }

    // MARK: Destructive helpers

    /// Runs `f` on the target surface's content as straight RGBA (`w × h` = content bounds),
    /// blending the result through the selection.
    static func processSurface(_ surf: inout Surface, selection: Surface?, _ f: (inout [SIMD4<Float>], PixelRect) -> Void) {
        let r = surf.contentBounds
        if r.isEmpty { return }
        let fmt = surf.format
        var px = PixelCodec.toRGBA(fmt, raw: surf.readRegion(r))
        let orig = px
        let w = r.width
        f(&px, r)
        guard px.count == orig.count else { return }
        var mixed = [SIMD4<Float>]()
        mixed.reserveCapacity(px.count)
        for i in px.indices {
            let k = selection.map { $0.sampleChannel(x: r.x0 + Int32(i % w), y: r.y0 + Int32(i / w), 0) } ?? 1
            mixed.append(orig[i] + (px[i] - orig[i]) * k)
        }
        surf.writeRegion(r, PixelCodec.fromRGBA(fmt, rgba: mixed))
    }

    /// One history step running `f` on the active pixel layer (or targeted channel or layer mask).
    static func rgbaEdit(_ s: Session, _ label: String, _ p: JSONValue, _ f: (inout [SIMD4<Float>], PixelRect) -> Void) throws -> JSONValue {
        let id = try? s.layerParam(.null)
        if Channels.targetOf(p) != .pixels {
            try s.edit(label) { doc, _ in
                let sel = doc.selection, b = doc.bounds
                try Channels.withTargetSurface(&doc, layer: id, p) { surf, _ in
                    Channels.materialize(&surf, b)
                    processSurface(&surf, selection: sel, f)
                    surf.prune()
                }
            }
            return .null
        }
        guard let id else { throw EngineError.other("no active layer") }
        try s.edit(label) { doc, _ in
            let sel = doc.selection
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in processSurface(&surf, selection: sel, f) }
        }
        return .null
    }

    /// A pixel layer, or a targeted channel (photocraft `has_pixels`).
    static let hasPixels: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        switch s.activeLayer() {
        case .failure(let e): return e.description
        case .success(let l):
            if case .raster = l.content { return nil }
            return "active layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer"
        }
    }

    /// Image › Adjustments targets: a pixel layer, a smart object (the adjustment is recorded as a
    /// smart filter, as in Photoshop), or a targeted alpha channel / Quick Mask (photocraft
    /// `has_adjustable`).
    static let hasAdjustable: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        switch s.activeLayer() {
        case .failure(let e): return e.description
        case .success(let l):
            switch l.content {
            case .raster: return nil
            case .smart(let sm) where sm.cache != nil: return nil
            default: return "active layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer"
            }
        }
    }

    // MARK: Smart filters

    /// Image › Adjustments on a smart object record `image.adjustments.<kind>` as a smart filter
    /// (Photoshop). true when it was recorded (one history step); false when the command should edit
    /// pixels instead (a mask or channel target, or the active layer is not a smart object).
    ///
    /// photocraft re-renders the object from its source with the filter stack (the selection
    /// becomes the filter mask); a smart object without a renderable source gets the adjustment
    /// applied to its cached appearance, and it is recorded either way.
    static func adjustAsSmartFilter(_ s: Session, kind: String, label: String, _ p: JSONValue) throws -> Bool {
        if LayerOps.isMaskTarget(p) || Channels.isChannelTarget(p) { return false }
        guard let d = s.active, let id = d.activeLayer, case .smart? = d.doc.layer(id)?.content else { return false }
        // The recorded params are the command's own, minus the engine's private `__kind` key.
        let sf = SmartFilter(command: "image.adjustments.\(kind)", params: p.removing("__kind"), blend: .normal, opacity: 1, visible: true)
        let sel = d.doc.selection
        let services = s.services
        try s.edit(label) { doc, _ in try addSmartFilter(&doc, id, sf, selection: sel, services: services) }
        return true
    }

    /// Appends a smart filter to smart object `id` (photocraft `smart_cmds::add_smart_filter`).
    static func addSmartFilter(_ doc: inout Document, _ id: LayerId, _ sf: SmartFilter, selection: Surface?,
                               services: EngineServices? = nil) throws {
        try FilterCommands.addSmartFilter(&doc, id, sf, selection: selection, services: services)
    }

    /// Image › Adjustments run as a smart filter (`image.adjustments.<kind>` recorded on a smart
    /// object): the adjustment applied to a copy of `surf`. nil for kinds or params it can't run.
    static func adjustAsFilter(_ kind: String, _ p: JSONValue, _ surf: Surface) -> Surface? {
        if kind == "shadowsHighlights" { return shadowsHighlightsFilter(p, surf) }
        var out = surf
        let mode = surf.format.mode
        guard let adj = try? AdjustParams.fromParams(kind, p, base: nil, mode: mode) else { return nil }
        Pixels.adjustSurface(&out, adj, selection: nil, mode: mode)
        out.prune()
        return out
    }

    // MARK: Commands

    static func replaceColor(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let c = Params.color(p, "color", s.tools.foreground)
        let fuzz = Swift.min(Swift.max(num(p, "fuzziness", 40), 0), 200)
        let h = Swift.min(Swift.max(num(p, "hue", 0), -180), 180)
        let sat = Swift.min(Swift.max(num(p, "saturation", 0), -100), 100)
        let l = Swift.min(Swift.max(num(p, "lightness", 0), -100), 100)
        return try rgbaEdit(s, "Replace Color", p) { px, _ in
            ToneKit.replaceColor(&px, SIMD3(c.x, c.y, c.z), fuzz, h, sat, l)
        }
    }

    /// Straight RGBA pixels of a document's layer (rendered alone) or its composite, and an
    /// optional selection coverage mask.
    static func statsPixels(_ s: Session, _ doc: Document, layer: UInt64?, useSelection: Bool) throws -> ([SIMD4<Float>], [Float]?) {
        let area = doc.bounds
        let px: [SIMD4<Float>]
        if let raw = layer {
            let lid = LayerId(raw)
            guard let l = doc.layer(lid) else { throw EngineError.noLayer(lid) }
            var solo = doc
            solo.layers = [l]
            px = try s.services.renderer.render(solo, region: area).px
        } else {
            px = try s.services.renderer.render(doc, region: area).px
        }
        let mask = useSelection ? doc.selection.map { $0.coverage(area) } : nil
        return (px, mask)
    }

    static func matchColor(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "image.adjustments.matchColor"
        var o = ToneKit.MatchColor()
        o.luminance = Swift.min(Swift.max(num(p, "luminance", 100), 1), 200)
        o.intensity = Swift.min(Swift.max(num(p, "intensity", 100), 1), 200)
        o.fade = Swift.min(Swift.max(num(p, "fade", 0), 0), 100)
        o.neutralize = p["neutralize"]?.boolValue ?? false
        var source: ToneKit.LabStats?
        // photocraft `as_i64`: a whole number.
        if case .number(let n)? = p["source"], n.isFinite, n == n.rounded(), n >= 0 {
            guard n < Double(s.documents.count) else { throw EngineError.bad(cmd, "no document \(Int64(Swift.min(n, 9.2e18)))") }
            let d = s.documents[Int(n)]
            let (px, mask) = try statsPixels(s, d.doc, layer: p["sourceLayer"]?.uint64Value,
                                             useSelection: p["useSelectionInSource"]?.boolValue ?? false)
            guard let st = ToneKit.labStats(px, mask) else { throw EngineError.bad(cmd, "the source has no opaque pixels") }
            source = st
        }
        // Source "None" with default options matches the image to its own statistics: a no-op, as
        // in Photoshop (Neutralize / Luminance / Color Intensity still act). Target statistics: the
        // layer itself, restricted to the selection when asked.
        let targetSel = p["useSelectionInTarget"]?.boolValue ?? false
        let sel = s.active?.doc.selection
        return try rgbaEdit(s, "Match Color", p) { px, r in
            let mask = targetSel ? sel.map { $0.coverage(r) } : nil
            guard let target = ToneKit.labStats(px, mask) else { return }
            ToneKit.matchColor(&px, target, source, o)
        }
    }

    static func hdrToning(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let d = ToneKit.HdrToning()
        var curve: [(Float, Float)] = []
        for v in p["curve"]?.arrayValue ?? [] {
            if let a = v[0]?.doubleValue, let b = v[1]?.doubleValue { curve.append((Float(a) / 255, Float(b) / 255)) }
        }
        func c(_ key: String, _ def: Float, _ lo: Float, _ hi: Float) -> Float { Swift.min(Swift.max(num(p, key, def), lo), hi) }
        var h = ToneKit.HdrToning()
        h.radius = c("radius", d.radius, 1, 500)
        h.strength = c("strength", d.strength, 0.1, 4)
        h.gamma = c("gamma", d.gamma, 0.1, 2)
        h.exposure = c("exposure", d.exposure, -5, 5)
        h.detail = c("detail", d.detail, -100, 300)
        h.shadow = c("shadow", d.shadow, -100, 100)
        h.highlight = c("highlight", d.highlight, -100, 100)
        h.vibrance = c("vibrance", d.vibrance, -100, 100)
        h.saturation = c("saturation", d.saturation, -100, 100)
        h.curve = curve
        let tone = h
        let renderer = s.services.renderer
        // Like Photoshop, HDR Toning flattens the image first (one history step).
        try s.edit("HDR Toning") { doc, active in
            let buf = try renderer.render(doc, region: doc.bounds)
            var px = buf.px.map { q -> SIMD4<Float> in
                let a = q.w
                return SIMD4(q.x * a + (1 - a), q.y * a + (1 - a), q.z * a + (1 - a), 1)
            }
            ToneKit.hdrToning(&px, buf.rect.width, buf.rect.height, tone)
            let fmt = doc.pixelFormat
            let data = PixelCodec.fromRGBA(fmt, rgba: px)
            var bg = Layer.raster("Background", format: fmt)
            bg.locks.transparency = true
            bg.locks.position = true
            let bounds = doc.bounds
            guard bg.withRaster({ $0.writeRegion(bounds, data) }) != nil else { throw EngineError.other("not a pixel layer") }
            active = bg.id
            doc.layers = [bg]
            doc.selection = nil
        }
        return .null
    }

    /// The Color Lookup built-ins (id, label) for UIs and agents.
    static func listLooks(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        .array(looks.map { ["id": .string($0.id), "label": .string($0.label)] })
    }

    // MARK: Registration

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("image.adjustments.shadowsHighlights", "Shadows/Highlights…", menu: ["Image", "Adjustments"],
                          params: #"{"shadowAmount":0..100=35,"shadowTone":0..100=50,"shadowRadius":0..2500=30,"highlightAmount":0..100=0,"highlightTone":0..100=50,"highlightRadius":0..2500=30,"color":-100..100=20,"midtone":-100..100=0,"blackClip":0..50=0.01,"whiteClip":0..50=0.01}"#,
                          module: m, enabled: hasAdjustable, run: shadowsHighlights))
        r.add(CommandSpec("image.adjustments.replaceColor", "Replace Color…", menu: ["Image", "Adjustments"],
                          params: ##"{"color":json,"fuzziness":0..200=40,"hue":-180..180=0,"saturation":-100..100=0,"lightness":-100..100=0} (color: "#rrggbb", default the foreground colour)"##,
                          module: m, enabled: hasPixels, run: replaceColor))
        r.add(CommandSpec("image.adjustments.matchColor", "Match Color…", menu: ["Image", "Adjustments"],
                          params: #"{"source":doc,"sourceLayer":json,"luminance":1..200=100,"intensity":1..200=100,"fade":0..100=0,"neutralize":bool=false,"useSelectionInSource":bool=false,"useSelectionInTarget":bool=false} (source: document index; sourceLayer: layer id, default the merged image)"#,
                          module: m, enabled: hasPixels, run: matchColor))
        r.add(CommandSpec("image.adjustments.hdrToning", "HDR Toning…", menu: ["Image", "Adjustments"],
                          params: #"{"radius":1..500=30,"strength":0.1..4=0.5,"gamma":0.1..2=1,"exposure":-5..5=0,"detail":-100..300=30,"shadow":-100..100=0,"highlight":-100..100=0,"vibrance":-100..100=0,"saturation":-100..100=20,"curve":[[in,out],…] 0..255} (flattens the image)"#,
                          module: m, enabled: Pre.hasDoc, run: hdrToning))
        r.add(CommandSpec("image.adjustments.colorLookup.list", "List Color Lookup Looks", params: "{}", module: m, journal: false,
                          enabled: Pre.always, run: listLooks))
    }
}
