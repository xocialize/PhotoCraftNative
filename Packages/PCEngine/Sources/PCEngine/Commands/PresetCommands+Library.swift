// Port of photocraft-engine (crates/engine/src/presets/styles.rs, presets/shapes.rs, presets/tools.rs; the path JSON of vector_cmds.rs and edit_menu_cmds.rs `current_path` they use), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Window › Styles (layer effects plus optional blending, applied to the selected layers), Window ›
// Shapes and the Custom Shape tool (vector shape presets placed as shape layers), and Window › Tool
// Presets (a tool plus its options, opaque JSON the shell fills in). Built-in styles and shapes are
// photocraft's own designs, built from the same effect params as `layer.layerStyle.*` and a small
// path language (`parseShape`).

import Foundation
import PCDocument
import PCFoundation
import PCPlatform

extension PresetCommands {
    // MARK: - Styles

    /// A style: layer effects plus, optionally, the blending options it was saved with.
    struct StylePreset: Hashable, Sendable, Codable, Named {
        var name: String
        var effects: [Effect]
        /// Blending options saved with the style ("Include Layer Blending Options").
        var blend: BlendMode?
        var fillOpacity: Float?

        var presetName: String {
            get { name }
            set { name = newValue }
        }

        init(name: String, effects: [Effect], blend: BlendMode? = nil, fillOpacity: Float? = nil) {
            self.name = name; self.effects = effects; self.blend = blend; self.fillOpacity = fillOpacity
        }

        enum CodingKeys: String, CodingKey { case name, effects, blend, fillOpacity = "fill_opacity" }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            effects = try c.decode([Effect].self, forKey: .effects)
            blend = try c.decodeIfPresent(BlendMode.self, forKey: .blend)
            fillOpacity = try c.decodeIfPresent(Float.self, forKey: .fillOpacity)
        }

        /// From `[[kind, params], …]` in `layer.layerStyle.<kind>` form.
        static func fromSpec(_ name: String, _ fx: JSONValue, _ fill: Float?) -> StylePreset {
            let effects = (fx.arrayValue ?? []).compactMap { e -> Effect? in
                guard let kind = e[0]?.stringValue else { return nil }
                return LayerStyleCommands.effectFromParams(kind, e[1] ?? .null)
            }
            return StylePreset(name: name, effects: effects, blend: nil, fillOpacity: fill)
        }

        var json: JSONValue {
            [
                "name": .string(name), "effects": .strings(effects.map(\.label)), "blend": blend.map { .string($0.label) } ?? .null,
                "fillOpacity": fillOpacity.map { .float(($0 * 100).rounded()) } ?? .null,
            ]
        }
    }

    /// Built-in style groups (photocraft's own designs).
    static func builtinStyles() -> [Group<StylePreset>] {
        func s(_ name: String, _ fx: JSONValue, _ fill: Float? = nil) -> StylePreset { .fromSpec(name, fx, fill) }
        return [
            Group("Basics", [
                s("Default Style (None)", []),
                s("Drop Shadow", [["dropShadow", ["distance": 6, "size": 8, "opacity": 60]]]),
                s("Soft Shadow", [["dropShadow", ["distance": 2, "size": 16, "opacity": 45]]]),
                s("Black Stroke", [["stroke", ["size": 3, "color": "#000000", "position": "outside"]]]),
                s("White Stroke", [["stroke", ["size": 3, "color": "#ffffff", "position": "outside"]]]),
                s("Inner Shadow", [["innerShadow", ["distance": 4, "size": 6, "opacity": 55]]]),
                s("Outer Glow", [["outerGlow", ["size": 14, "color": "#ffe9a8", "opacity": 80]]]),
                s("Emboss", [["bevelEmboss", ["style": "emboss", "size": 4, "depth": 120]]]),
            ]),
            Group("Text Effects", [
                s("Neon Blue", [["colorOverlay", ["color": "#d8f4ff"]], ["innerGlow", ["color": "#3fb6ff", "size": 6, "opacity": 90, "blend": "normal"]],
                                ["outerGlow", ["color": "#1e90ff", "size": 22, "opacity": 90]]]),
                s("Neon Pink", [["colorOverlay", ["color": "#ffe1f3"]], ["innerGlow", ["color": "#ff4fb4", "size": 6, "opacity": 90, "blend": "normal"]],
                                ["outerGlow", ["color": "#ff2d95", "size": 22, "opacity": 90]]]),
                s("Chrome", [["gradientOverlay", ["from": "#3a3f47", "to": "#f4f6f8", "angle": 90]],
                             ["bevelEmboss", ["style": "inner", "size": 6, "depth": 250, "soften": 1]],
                             ["stroke", ["size": 1, "color": "#2a2d33", "position": "outside"]]]),
                s("Gold", [["gradientOverlay", ["from": "#8a5a12", "to": "#ffe08a", "angle": 90]], ["bevelEmboss", ["style": "inner", "size": 5, "depth": 180]],
                           ["dropShadow", ["distance": 3, "size": 5, "opacity": 50]]]),
                s("Comic Outline", [["colorOverlay", ["color": "#ffd23f"]], ["stroke", ["size": 4, "color": "#111111", "position": "outside"]],
                                    ["dropShadow", ["distance": 6, "size": 0, "opacity": 100, "angle": 135]]]),
                s("Letterpress", [["colorOverlay", ["color": "#5b6168"]], ["innerShadow", ["distance": 2, "size": 2, "opacity": 70]],
                                  ["dropShadow", ["distance": 1, "size": 0, "color": "#ffffff", "opacity": 60, "blend": "screen", "angle": 90]]]),
                s("Hollow", [["stroke", ["size": 2, "color": "#222222", "position": "inside"]]], 0),
            ]),
            Group("Buttons", [
                s("Glass", [["gradientOverlay", ["from": "#2b6cb0", "to": "#90cdf4", "angle": 90]],
                            ["innerGlow", ["color": "#ffffff", "size": 6, "opacity": 45, "blend": "screen"]],
                            ["bevelEmboss", ["style": "inner", "size": 8, "depth": 100, "soften": 4]], ["dropShadow", ["distance": 3, "size": 8, "opacity": 40]]]),
                s("Gel Green", [["gradientOverlay", ["from": "#1f7a3a", "to": "#7be495", "angle": 90]], ["innerShadow", ["distance": 2, "size": 5, "opacity": 35]],
                                ["bevelEmboss", ["style": "inner", "size": 10, "depth": 150, "soften": 6]]]),
                s("Pressed", [["colorOverlay", ["color": "#d7dbe0"]], ["innerShadow", ["distance": 3, "size": 6, "opacity": 60]],
                              ["stroke", ["size": 1, "color": "#9aa1a9", "position": "inside"]]]),
                s("Pill Red", [["gradientOverlay", ["from": "#9b1c1c", "to": "#f87171", "angle": 90]], ["bevelEmboss", ["style": "pillow", "size": 6, "depth": 120]],
                               ["dropShadow", ["distance": 2, "size": 4, "opacity": 45]]]),
                s("Flat Shadow", [["colorOverlay", ["color": "#3b82f6"]], ["dropShadow", ["distance": 5, "size": 0, "opacity": 35, "angle": 90]]]),
                s("Satin Plum", [["colorOverlay", ["color": "#7e3a8c"]], ["satin", ["color": "#1b0420", "opacity": 55, "size": 18, "distance": 14]],
                                 ["bevelEmboss", ["style": "inner", "size": 4, "depth": 80]]]),
            ]),
        ]
    }

    static func findStyle(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> StylePreset {
        let name = try reqStr(p, "preset", cmd)
        let styles = state(s).styles
        guard let (gi, ii) = find(styles, name, strParam(p, "group")) else { throw EngineError.bad(cmd, "no style \"\(name)\" (see style.presets.list)") }
        return styles[gi].items[ii]
    }

    static func styleList(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        ["groups": .array(state(s).styles.map { ["name": .string($0.name), "presets": .array($0.items.map(\.json))] })]
    }

    /// Target layers: `"layers": [ids]`, `"layer": id`, else every selected layer.
    static func styleTargetLayers(_ s: Session, _ p: JSONValue) -> [LayerId] {
        if let a = p["layers"]?.arrayValue { return a.compactMap(\.uint64Value).map { LayerId($0) } }
        if let id = p["layer"]?.uint64Value { return [LayerId(id)] }
        return LayerMulti.selected(s)
    }

    static func styleApply(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "style.presets.apply"
        let style = try findStyle(s, p, cmd)
        let add = p["add"]?.boolValue ?? false
        let ids = styleTargetLayers(s, p)
        if ids.isEmpty { throw EngineError.bad(cmd, "no target layers") }
        // Pattern overlays name their pattern; resolve to library patterns copied into the document.
        var effects: [Effect] = []
        var pats: [Pattern] = []
        for fx in style.effects {
            let (r, pat) = try PatternCommands.resolveEffect(s, fx)
            effects.append(r)
            if let pat { pats.append(pat) }
        }
        try s.edit("Apply Style: \(style.name)") { doc, _ in
            for pat in pats { PatternCommands.ensureInDoc(&doc, pat) }
            // A preset's colours are RGB; the layer's are in the document's mode.
            let mode = doc.mode
            let fx = effects.map { $0.inMode(mode) }
            for id in ids {
                // Styles can't sit on the Background: Photoshop turns it into a normal layer first.
                LayerOps.backgroundToLayer(&doc, id)
                guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
                doc.updateLayer(id) { l in
                    if add {
                        l.effects.items += fx
                    } else {
                        l.effects.items = fx
                    }
                    l.effects.psdRaw = nil
                    l.effects.enabled = true
                    if !add || style.blend != nil {
                        if let b = style.blend { l.blend = b }
                        if let f = style.fillOpacity {
                            l.fillOpacity = f
                        } else if !add {
                            l.fillOpacity = 1
                        }
                    }
                }
            }
        }
        return ["layers": .ids(ids), "style": .string(style.name)]
    }

    static func styleNew(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "style.presets.new"
        let id = try s.layerParam(p)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        let withFx = p["includeEffects"]?.boolValue ?? true
        let withBlend = p["includeBlending"]?.boolValue ?? true
        if !withFx && !withBlend { throw EngineError.bad(cmd, "include effects and/or blending options") }
        // An explicit effect list (the Layer Style dialog's pending state, in
        // `layer.layerStyle.<kind>` param form) replaces the layer's own effects.
        var listed: [Effect]?
        if let list = p["effects"]?.arrayValue {
            listed = try list.map { e in
                guard let kind = e[0]?.stringValue else { throw EngineError.bad(cmd, "each effect is [kind, params]") }
                guard let fx = LayerStyleCommands.effectFromParams(kind, e[1] ?? .null) else { throw EngineError.bad(cmd, "unknown effect \(kind)") }
                return fx
            }
        }
        var st = state(s)
        let style = StylePreset(
            name: uniqueName(st.styles, strParam(p, "name") ?? "Style"),
            effects: listed ?? (withFx ? l.effects.items : []),
            blend: p["blend"]?.stringValue.flatMap(Params.blendMode) ?? (withBlend ? l.blend : nil),
            fillOpacity: p["fillOpacity"]?.doubleValue.map { Float(min(max($0 / 100, 0), 1)) } ?? (withBlend ? l.fillOpacity : nil))
        let gi = groupIndex(&st.styles, strParam(p, "group"))
        let out: JSONValue = ["name": .string(style.name), "group": .string(st.styles[gi].name), "effects": .int(style.effects.count)]
        st.styles[gi].items.append(style)
        s.state[Key.self] = st
        presetsChanged(s)
        return out
    }

    static func styleEdit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "style.presets.edit"
        let action = try reqStr(p, "action", cmd)
        var groups = state(s).styles
        let r = try editGroups(&groups, action, p, cmd)
        s.state[Key.self].styles = groups
        presetsChanged(s)
        return r
    }

    static func styleReset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var b = builtinStyles()
        var st = state(s)
        if p["append"]?.boolValue ?? false {
            for i in b.indices { b[i].name = uniqueGroup(st.styles, b[i].name) }
            st.styles += b
        } else {
            st.styles = b
        }
        s.state[Key.self] = st
        presetsChanged(s)
        return ["groups": .int(st.styles.count)]
    }

    /// photocraft `styles::thumbnail`: swatch for the Styles panel, the style on a rounded square,
    /// `size`² RGBA8 (straight alpha, transparent around the square).
    static func styleThumbnail(_ s: Session, _ style: StylePreset, _ size: UInt32) throws -> [UInt8] {
        let size = min(max(size, 8), 256)
        let n = Int(size)
        var doc = Document(name: "style", size: PixelSize(width: n, height: n), mode: .rgb, depth: .u8)
        var l = Layer.raster("swatch", format: doc.pixelFormat)
        let fs = Float(size)
        let margin = (fs * 0.2).rounded()
        let (x0, x1) = (margin, fs - margin)
        let r = fs * 0.12
        var px: [Float] = []
        px.reserveCapacity(n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                // Coverage of a rounded square (1 px anti-aliasing).
                let (cx, cy) = (Float(x) + 0.5, Float(y) + 0.5)
                let qx = abs(cx - (x0 + x1) / 2) - ((x1 - x0) / 2 - r)
                let qy = abs(cy - (x0 + x1) / 2) - ((x1 - x0) / 2 - r)
                let d = ((max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0)) - r
                px += [0.86, 0.86, 0.86, min(max(0.5 - d, 0), 1)]
            }
        }
        l.withRaster { $0.writeRegion(PixelRect(x0: 0, y0: 0, x1: Int32(n), y1: Int32(n)), px) }
        for fx in style.effects {
            if let (r, pat) = try? PatternCommands.resolveEffect(s, fx) {
                if let pat { PatternCommands.ensureInDoc(&doc, pat) }
                l.effects.items.append(r)
            }
        }
        l.effects.enabled = true
        if let b = style.blend { l.blend = b }
        if let f = style.fillOpacity { l.fillOpacity = f }
        doc.layers.append(l)
        let buf = try s.services.renderer.render(doc, region: doc.bounds)
        return buf.px.flatMap { p in [p.x, p.y, p.z, p.w].map { UInt8((min(max($0, 0), 1) * 255).rounded()) } }
    }

    static func styleSpecs() -> [CommandSpec] {
        [
            CommandSpec("style.presets.list", "Style Presets", params: "{} → {groups:[{name,presets:[{name,effects,blend,fillOpacity}]}]}",
                        module: m, journal: false, run: styleList),
            CommandSpec("style.presets.apply", "Apply Style",
                        params: ##"{"preset":name,"group":name?,"layers":[ids]?|"layer":id? (default: the selected layers),"add":bool=false (⇧-click: add to the existing effects)} → {layers,style}"##,
                        module: m, enabled: Pre.hasLayer, run: styleApply),
            CommandSpec("style.presets.new", "New Style…",
                        params: ##"{"name":str="Style","group":name?,"layer":id?,"includeEffects":bool=true,"includeBlending":bool=true,"effects":[[kind, params]]? (explicit list, e.g. the Layer Style dialog's pending state; overrides includeEffects),"blend":str?,"fillOpacity":0..100? (override the layer's blending options)}"##,
                        module: m, enabled: Pre.hasLayer, run: styleNew),
            CommandSpec("style.presets.edit", "Edit Style Presets", params: groupEditParams, module: m, run: styleEdit),
            CommandSpec("style.presets.reset", "Restore Default Styles", params: ##"{"append":bool=false}"##, module: m, run: styleReset),
        ]
    }

    // MARK: - Shapes

    /// Group listing Edit › Define Custom Shape results.
    static let customGroup = "Custom Shapes"

    struct ShapePreset: Hashable, Sendable, Codable, Named {
        var name: String
        var path: VectorPath
        var presetName: String {
            get { name }
            set { name = newValue }
        }
    }

    struct ShapeParseError: Error {
        var message: String
    }

    static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> Subpath {
        // Four cubic quarter arcs (κ = 0.5523).
        let k = r * 0.552_284_75
        func knot(_ x: Double, _ y: Double, _ ix: Double, _ iy: Double, _ ox: Double, _ oy: Double) -> Knot {
            .smooth(anchor: PCPoint(x, y), inCtrl: PCPoint(ix, iy), outCtrl: PCPoint(ox, oy))
        }
        return Subpath(closed: true, knots: [
            knot(cx, cy - r, cx - k, cy - r, cx + k, cy - r),
            knot(cx + r, cy, cx + r, cy - k, cx + r, cy + k),
            knot(cx, cy + r, cx + k, cy + r, cx - k, cy + r),
            knot(cx - r, cy, cx - r, cy + k, cx - r, cy - k),
        ], op: .combine)
    }

    /// photocraft `shapes::parse`: the preset path language — `M x y`, `L x y…`,
    /// `C x1 y1 x2 y2 x y…`, `Q x1 y1 x y…`, `Z`, `O cx cy r` (a circle), and `!` before `M`/`O` to
    /// subtract that subpath (holes).
    static func parseShape(_ src: String) throws(ShapeParseError) -> VectorPath {
        let toks = src.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "!", with: " ! ")
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var i = 0
        func num() throws(ShapeParseError) -> Double {
            guard i < toks.count else { throw ShapeParseError(message: "unexpected end") }
            guard let v = Double(toks[i]) else { throw ShapeParseError(message: "expected a number at `\(toks[i])`") }
            i += 1
            return v
        }
        func isNum(_ j: Int) -> Bool { j < toks.count && Double(toks[j]) != nil }
        var subs: [Subpath] = []
        var cur: Subpath?
        var op = PathOp.combine
        func finish(_ closed: Bool) {
            guard var s = cur else { return }
            cur = nil
            s.closed = closed
            if closed && s.knots.count > 1 {
                let (f, l) = (s.knots[0].anchor, s.knots[s.knots.count - 1].anchor)
                if abs(f.x - l.x) < 1e-9 && abs(f.y - l.y) < 1e-9, let last = s.knots.popLast() { s.knots[0].inCtrl = last.inCtrl }
            }
            if !s.knots.isEmpty { subs.append(s) }
        }
        while i < toks.count {
            let t = toks[i]
            i += 1
            switch t {
            case "!":
                op = .subtract
            case "M":
                finish(true)
                let x = try num(), y = try num()
                cur = Subpath(closed: true, knots: [.corner(x, y)], op: op)
                op = .combine
            case "L":
                guard cur != nil else { throw ShapeParseError(message: "L before M") }
                while isNum(i) {
                    let x = try num(), y = try num()
                    cur?.knots.append(.corner(x, y))
                }
            case "C", "Q":
                guard cur != nil else { throw ShapeParseError(message: "curve before M") }
                while isNum(i) {
                    guard let last = cur?.knots.last?.anchor else { throw ShapeParseError(message: "curve before M") }
                    let c1: PCPoint, c2: PCPoint, p: PCPoint
                    if t == "C" {
                        c1 = PCPoint(try num(), try num())
                        c2 = PCPoint(try num(), try num())
                        p = PCPoint(try num(), try num())
                    } else {
                        let q = PCPoint(try num(), try num())
                        p = PCPoint(try num(), try num())
                        c1 = PCPoint(last.x + (q.x - last.x) * 2 / 3, last.y + (q.y - last.y) * 2 / 3)
                        c2 = PCPoint(p.x + (q.x - p.x) * 2 / 3, p.y + (q.y - p.y) * 2 / 3)
                    }
                    if let n = cur?.knots.count, n > 0 { cur?.knots[n - 1].outCtrl = c1 }
                    cur?.knots.append(Knot(anchor: p, inCtrl: c2, outCtrl: p, smooth: false))
                }
            case "Z":
                finish(true)
            case "O":
                finish(true)
                let x = try num(), y = try num(), r = try num()
                var c = circle(x, y, r)
                c.op = op
                op = .combine
                subs.append(c)
            default:
                throw ShapeParseError(message: "unknown command `\(t)`")
            }
        }
        finish(true)
        if subs.isEmpty { throw ShapeParseError(message: "empty path") }
        return VectorPath(subs)
    }

    static func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    /// Star / burst polygon with `n` points in the 100 box (`ratio` = inner / outer radius).
    static func star(_ n: Int, _ ratio: Double, _ rot: Double) -> String {
        var s = ""
        for k in 0..<(2 * n) {
            let r = k % 2 == 0 ? 50.0 : 50.0 * ratio
            let a = rot + Double.pi * Double(k) / Double(n) - Double.pi / 2
            s += "\(k == 0 ? "M" : "L") \(f3(50 + r * cos(a))) \(f3(50 + r * sin(a))) "
        }
        return s + "Z"
    }

    static func sun() -> String {
        var s = "O 50 50 22 "
        for k in 0..<12 {
            let a = 2 * Double.pi * Double(k) / 12
            func p(_ r: Double, _ da: Double) -> (Double, Double) { (50 + r * cos(a + da), 50 + r * sin(a + da)) }
            let (b1, b2, tip) = (p(28, -0.12), p(28, 0.12), p(50, 0))
            s += "M \(f3(b1.0)) \(f3(b1.1)) L \(f3(tip.0)) \(f3(tip.1)) L \(f3(b2.0)) \(f3(b2.1)) Z "
        }
        return s
    }

    static func flower() -> String {
        var s = ""
        for k in 0..<6 {
            let a = 2 * Double.pi * Double(k) / 6 - Double.pi / 2
            s += "O \(f3(50 + 30 * cos(a))) \(f3(50 + 30 * sin(a))) 18 "
        }
        return s + "O 50 50 20 ! O 50 50 9"
    }

    static func shout() -> String {
        // A jagged burst stretched into a bubble, with a tail.
        var s = ""
        let n = 14
        for k in 0..<(2 * n) {
            let r = k % 2 == 0 ? 1.0 : 0.78
            let a = Double.pi * Double(k) / Double(n)
            s += "\(k == 0 ? "M" : "L") \(f3(50 + 50 * r * cos(a))) \(f3(40 + 40 * r * sin(a))) "
        }
        return s + "Z M 30 70 L 14 100 L 46 74 Z"
    }

    /// Built-in shape groups (photocraft's own drawings).
    static func builtinShapes() -> [Group<ShapePreset>] {
        func mk(_ list: [(String, String)]) -> [ShapePreset] {
            list.compactMap { n, src in (try? parseShape(src)).map { ShapePreset(name: n, path: $0) } }
        }
        return [
            Group("Symbols", mk([
                ("Heart", "M 50 92 C 20 70 0 52 0 30 C 0 12 14 0 28 0 C 40 0 47 8 50 16 C 53 8 60 0 72 0 C 86 0 100 12 100 30 C 100 52 80 70 50 92 Z"),
                ("Star", star(5, 0.4, 0)),
                ("Six-Point Star", star(6, 0.55, 0)),
                ("Burst", star(16, 0.72, 0)),
                ("Check Mark", "M 5 55 L 20 40 L 38 58 L 82 12 L 97 27 L 38 88 Z"),
                ("Cross", "M 20 5 L 50 35 L 80 5 L 95 20 L 65 50 L 95 80 L 80 95 L 50 65 L 20 95 L 5 80 L 35 50 L 5 20 Z"),
                ("Plus", "M 38 0 L 62 0 L 62 38 L 100 38 L 100 62 L 62 62 L 62 100 L 38 100 L 38 62 L 0 62 L 0 38 L 38 38 Z"),
                ("Ring", "O 50 50 50 ! O 50 50 32"),
                ("Lightning", "M 58 0 L 18 56 L 44 56 L 34 100 L 82 38 L 55 38 L 70 0 Z"),
                ("Diamond", "M 50 0 L 90 50 L 50 100 L 10 50 Z"),
            ])),
            Group("Arrows", mk([
                ("Arrow Right", "M 0 35 L 55 35 L 55 15 L 100 50 L 55 85 L 55 65 L 0 65 Z"),
                ("Arrow Left", "M 100 35 L 45 35 L 45 15 L 0 50 L 45 85 L 45 65 L 100 65 Z"),
                ("Arrow Up", "M 35 100 L 35 45 L 15 45 L 50 0 L 85 45 L 65 45 L 65 100 Z"),
                ("Arrow Down", "M 35 0 L 35 55 L 15 55 L 50 100 L 85 55 L 65 55 L 65 0 Z"),
                ("Double Arrow", "M 0 50 L 25 20 L 25 38 L 75 38 L 75 20 L 100 50 L 75 80 L 75 62 L 25 62 L 25 80 Z"),
                ("Chevron", "M 10 0 L 45 0 L 95 50 L 45 100 L 10 100 L 60 50 Z"),
                ("Curved Arrow", "M 8 92 C 8 45 35 22 68 22 L 68 4 L 98 34 L 68 64 L 68 44 C 48 44 30 58 30 92 Z"),
            ])),
            Group("Speech Bubbles", mk([
                ("Speech Bubble",
                 "M 15 5 L 85 5 C 93 5 100 12 100 20 L 100 60 C 100 68 93 75 85 75 L 45 75 L 20 98 L 25 75 L 15 75 C 7 75 0 68 0 60 L 0 20 C 0 12 7 5 15 5 Z"),
                ("Round Bubble", "M 50 5 C 78 5 100 22 100 42 C 100 62 78 79 50 79 C 44 79 38 78 33 77 L 12 95 L 18 72 C 7 65 0 54 0 42 C 0 22 22 5 50 5 Z"),
                ("Thought Bubble", "M 50 5 C 78 5 100 20 100 38 C 100 56 78 71 50 71 C 22 71 0 56 0 38 C 0 20 22 5 50 5 Z O 22 82 8 O 9 95 5"),
                ("Shout Bubble", shout()),
            ])),
            Group("Nature", mk([
                ("Leaf",
                 "M 50 0 C 80 20 95 50 80 75 C 72 88 60 92 53 92 L 53 100 L 47 100 L 47 92 C 40 92 28 88 20 75 C 5 50 20 20 50 0 Z ! M 48.5 22 L 51.5 22 L 51.5 88 L 48.5 88 Z"),
                ("Sun", sun()),
                ("Crescent Moon", "O 45 50 45 ! O 66 40 38"),
                ("Cloud", "M 25 80 C 10 80 0 70 0 58 C 0 46 10 37 22 37 C 24 20 38 10 54 10 C 70 10 82 20 85 34 C 95 35 100 45 100 57 C 100 70 90 80 78 80 Z"),
                ("Raindrop", "M 50 0 C 60 25 85 45 85 68 C 85 87 69 100 50 100 C 31 100 15 87 15 68 C 15 45 40 25 50 0 Z"),
                ("Flower", flower()),
                ("Tree", "M 50 0 L 85 45 L 68 45 L 92 75 L 56 75 L 56 100 L 44 100 L 44 75 L 8 75 L 32 45 L 15 45 Z"),
            ])),
            Group("Animals", mk([
                ("Fish", "M 0 50 C 15 25 45 15 70 32 L 96 12 L 88 50 L 96 88 L 70 68 C 45 85 15 75 0 50 Z ! O 20 45 4"),
                ("Cat", "M 15 10 L 35 30 C 45 27 55 27 65 30 L 85 10 L 88 50 C 92 75 72 95 50 95 C 28 95 8 75 12 50 Z ! O 36 58 6 ! O 64 58 6"),
                ("Bird", "M 0 40 C 15 30 35 32 50 50 C 65 32 85 30 100 40 C 85 40 65 48 50 70 C 35 48 15 40 0 40 Z"),
                ("Butterfly",
                 "M 50 30 C 40 5 5 0 5 25 C 5 45 30 50 45 50 C 25 55 10 75 25 90 C 38 100 48 80 50 65 C 52 80 62 100 75 90 C 90 75 75 55 55 50 C 70 50 95 45 95 25 C 95 0 60 5 50 30 Z"),
                ("Paw Print",
                 "M 50 50 C 68 50 82 66 82 80 C 82 92 70 96 60 94 C 55 93 52 91 50 91 C 48 91 45 93 40 94 C 30 96 18 92 18 80 C 18 66 32 50 50 50 Z O 18 42 10 O 37 22 11 O 63 22 11 O 82 42 10"),
                ("Rabbit", "O 50 72 26 M 34 52 C 22 30 24 2 34 2 C 44 2 46 30 44 50 Z M 66 52 C 78 30 76 2 66 2 C 56 2 54 30 56 50 Z"),
            ])),
        ]
    }

    /// Every shape the panel shows: the preset groups plus Define Custom Shape results.
    static func allShapeGroups(_ s: Session) -> [Group<ShapePreset>] {
        var g = state(s).shapes
        let custom = s.state[CustomShapesKey.self].map { ShapePreset(name: $0.name, path: $0.path) }
        if !custom.isEmpty { g.append(Group(customGroup, custom)) }
        return g
    }

    static func lookupShape(_ s: Session, _ name: String, _ group: String?, _ cmd: String) throws -> ShapePreset {
        let groups = allShapeGroups(s)
        guard let (gi, ii) = find(groups, name, group) else { throw EngineError.bad(cmd, "no shape \"\(name)\" (see shape.presets.list)") }
        return groups[gi].items[ii]
    }

    /// Coverage (0...1) of `path` fitted into a `size`² swatch with a small margin.
    static func shapeThumbnail(_ path: VectorPath, _ size: UInt32) -> [Float] {
        let size = min(max(size, 4), 512)
        let m = max(Double(size) * 0.08, 1)
        let fitted = fit(path, SIMD4(m, m, Double(size) - 2 * m, Double(size) - 2 * m), keep: true)
        return VectorRasterizer.fillCoverage(fitted, rect: PixelRect(x0: 0, y0: 0, x1: Int32(size), y1: Int32(size)))
    }

    /// Maps `path` (its control bounds) onto `rect` = [x, y, w, h]; `keep` preserves the aspect
    /// ratio (centred in the rect).
    static func fit(_ path: VectorPath, _ rect: SIMD4<Double>, keep: Bool) -> VectorPath {
        guard let b = path.controlBounds else { return path }
        let (bw, bh) = (max(b.z - b.x, 1e-9), max(b.w - b.y, 1e-9))
        var (sx, sy) = (rect[2] / bw, rect[3] / bh)
        var (ox, oy) = (rect[0], rect[1])
        if keep {
            let k = min(sx, sy)
            ox += (rect[2] - bw * k) / 2
            oy += (rect[3] - bh * k) / 2
            (sx, sy) = (k, k)
        }
        return path.transform(PCAffine(a: sx, b: 0, c: 0, d: sy, e: ox - b.x * sx, f: oy - b.y * sy))
    }

    static func shapeList(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let groups: [JSONValue] = allShapeGroups(s).map { g in
            ["name": .string(g.name), "shapes": .array(g.items.map { ["name": .string($0.name), "subpaths": .int($0.path.subpaths.count)] })]
        }
        return ["groups": .array(groups)]
    }

    static func shapePlace(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "shape.presets.place"
        let name = try reqStr(p, "preset", cmd)
        let shape = try lookupShape(s, name, strParam(p, "group"), cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        let (w, h) = (Double(d.doc.size.width), Double(d.doc.size.height))
        let keep = p["keepAspect"]?.boolValue ?? true
        let rect: SIMD4<Double>
        if let a = p["rect"]?.arrayValue, a.count == 4 {
            let v = a.map { $0.doubleValue ?? 0 }
            // Negative sizes (dragging up/left) flip into a positive rect.
            let (x, wd) = v[2] < 0 ? (v[0] + v[2], -v[2]) : (v[0], v[2])
            let (y, hd) = v[3] < 0 ? (v[1] + v[3], -v[3]) : (v[1], v[3])
            if wd < 1 || hd < 1 { throw EngineError.bad(cmd, "the shape rect is empty") }
            rect = SIMD4(x, y, wd, hd)
        } else {
            let side = min(w, h) * 0.5
            rect = SIMD4((w - side) / 2, (h - side) / 2, side, side)
        }
        let path = fit(shape.path, rect, keep: keep)
        var q: [String: JSONValue] = ["kind": "path", "path": pathJSON(path), "name": .string(strParam(p, "name") ?? shape.name)]
        for k in ["fill", "stroke", "addTo", "op"] { if let v = p[k] { q[k] = v } }
        let r: JSONValue
        if let spec = s.registry.spec("shape.create"), spec.isAvailable {
            r = try call(s, "shape.create", .object(q))
        } else {
            r = try createShapeLayer(s, path, .object(q))
        }
        return r.setting("preset", .string(shape.name))
    }

    static func shapeNew(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "shape.presets.new"
        var path: VectorPath
        switch p["path"] {
        case .object(let o)?:
            do { path = try parsePath(.object(o)) } catch { throw EngineError.bad(cmd, error.message) }
        case .string(let src)? where ["M", "O", "!"].contains(where: { src.drop(while: { $0.isWhitespace }).hasPrefix($0) }):
            do { path = try parseShape(src) } catch { throw EngineError.bad(cmd, error.message) }
        case let other:
            guard let d = s.active else { throw EngineError.bad(cmd, "no document (pass `path`)") }
            guard let cp = currentPath(d.doc, d.activeLayer, other?.stringValue) else { throw EngineError.bad(cmd, "select a path or shape layer first") }
            path = cp
        }
        if path.isEmpty { throw EngineError.bad(cmd, "the path is empty") }
        // Normalise into the 100 box so thumbnails and placing don't depend on where it was drawn.
        path = fit(path, SIMD4(0, 0, 100, 100), keep: true)
        var st = state(s)
        let name = uniqueName(st.shapes, strParam(p, "name") ?? "Shape")
        let gi = groupIndex(&st.shapes, strParam(p, "group"))
        let group = st.shapes[gi].name
        st.shapes[gi].items.append(ShapePreset(name: name, path: path))
        s.state[Key.self] = st
        presetsChanged(s)
        return ["name": .string(name), "group": .string(group)]
    }

    static func shapeEdit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "shape.presets.edit"
        let action = try reqStr(p, "action", cmd)
        // Define Custom Shape results live in the edit state; rename/delete them there.
        func custom(_ n: String) -> Bool {
            let g = strParam(p, "group")
            return (g == nil || g == customGroup) && find(state(s).shapes, n, nil) == nil && s.state[CustomShapesKey.self].contains { $0.name == n }
        }
        let r: JSONValue
        if action == "rename", custom(try reqStr(p, "preset", cmd)) {
            let n = try reqStr(p, "preset", cmd), to = try reqStr(p, "name", cmd)
            if let i = s.state[CustomShapesKey.self].firstIndex(where: { $0.name == n }) { s.state[CustomShapesKey.self][i].name = to }
            r = ["name": .string(to)]
        } else if action == "delete", let n = p["preset"]?.stringValue, custom(n) {
            let n = try reqStr(p, "preset", cmd)
            s.state[CustomShapesKey.self].removeAll { $0.name == n }
            r = ["deleted": 1]
        } else {
            var groups = state(s).shapes
            r = try editGroups(&groups, action, p, cmd)
            s.state[Key.self].shapes = groups
        }
        presetsChanged(s)
        return r
    }

    static func shapeReset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        var b = builtinShapes()
        var st = state(s)
        if p["append"]?.boolValue ?? false {
            for i in b.indices { b[i].name = uniqueGroup(st.shapes, b[i].name) }
            st.shapes += b
        } else {
            st.shapes = b
        }
        s.state[Key.self] = st
        presetsChanged(s)
        return ["groups": .int(st.shapes.count)]
    }

    static func shapeSpecs() -> [CommandSpec] {
        [
            CommandSpec("shape.presets.list", "Shape Presets", params: "{} → {groups:[{name,shapes:[{name,subpaths}]}]}", module: m, journal: false, run: shapeList),
            CommandSpec("shape.presets.place", "Place Custom Shape",
                        params: ##"{"preset":name,"group":name?,"rect":[x,y,w,h]? (default: centred, half the canvas),"keepAspect":bool=true,"fill":…?=foreground,"stroke":…?,"name":str?,"addTo":layerId?,"op":"combine|subtract|intersect|exclude"?} → shape.info (Custom Shape tool / Shapes panel; fill and stroke as in shape.create)"##,
                        module: m, enabled: Pre.hasDoc, run: shapePlace),
            CommandSpec("shape.presets.new", "New Shape Preset",
                        params: ##"{"name":str="Shape","group":name?,"path":{…path}|"M x y L …" (preset path language)|"work"|saved path name? (default: work path, active shape layer or vector mask)}"##,
                        module: m, run: shapeNew),
            CommandSpec("shape.presets.edit", "Edit Shape Presets", params: groupEditParams, module: m, run: shapeEdit),
            CommandSpec("shape.presets.reset", "Restore Default Shapes", params: ##"{"append":bool=false}"##, module: m, run: shapeReset),
        ]
    }

    // MARK: Paths (vector_cmds / edit_menu_cmds helpers)

    static func opFrom(_ s: String) -> PathOp? {
        switch s.lowercased() {
        case "combine", "add", "union": .combine
        case "subtract": .subtract
        case "intersect": .intersect
        case "exclude", "xor": .exclude
        case "join": .join
        default: nil
        }
    }

    static func opName(_ op: PathOp) -> String {
        switch op {
        case .combine: "combine"
        case .subtract: "subtract"
        case .intersect: "intersect"
        case .exclude: "exclude"
        case .join: "join"
        }
    }

    static func pt(_ v: JSONValue) -> PCPoint? {
        switch v {
        case .array(let a) where a.count >= 2:
            guard let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
            return PCPoint(x, y)
        case .object:
            guard let x = v["x"]?.doubleValue, let y = v["y"]?.doubleValue else { return nil }
            return PCPoint(x, y)
        default:
            return nil
        }
    }

    /// photocraft `vector_cmds::parse_path`: a path from the compact JSON form.
    static func parsePath(_ v: JSONValue) throws(ShapeParseError) -> VectorPath {
        guard let subs = v["subpaths"]?.arrayValue else { throw ShapeParseError(message: "path needs `subpaths`") }
        var out: [Subpath] = []
        for (i, s) in subs.enumerated() {
            guard let knotsV = s["knots"]?.arrayValue else { throw ShapeParseError(message: "subpath \(i) needs `knots`") }
            var knots: [Knot] = []
            for (j, k) in knotsV.enumerated() {
                if case .array = k {
                    guard let a = pt(k) else { throw ShapeParseError(message: "knot \(i).\(j): expected [x, y]") }
                    knots.append(.corner(a.x, a.y))
                } else {
                    guard let a = k["anchor"].flatMap(pt) else { throw ShapeParseError(message: "knot \(i).\(j): missing anchor") }
                    func get(_ keys: [String]) -> PCPoint? { keys.lazy.compactMap { k[$0].flatMap(pt) }.first }
                    knots.append(Knot(anchor: a, inCtrl: get(["in", "inCtrl", "in_ctrl"]) ?? a, outCtrl: get(["out", "outCtrl", "out_ctrl"]) ?? a,
                                      smooth: k["smooth"]?.boolValue ?? false))
                }
            }
            var op = PathOp.combine
            if let o = s["op"]?.stringValue {
                guard let x = opFrom(o) else { throw ShapeParseError(message: "subpath \(i): unknown op `\(o)`") }
                op = x
            }
            out.append(Subpath(closed: s["closed"]?.boolValue ?? true, knots: knots, op: op))
        }
        let rule = (v["fillRule"] ?? v["fill_rule"])?.stringValue?.lowercased()
        let fillRule: FillRule = ["evenodd", "even-odd", "even_odd"].contains(rule ?? "") ? .evenOdd : .nonZero
        return VectorPath(out, fillRule: fillRule, inverted: v["inverted"]?.boolValue ?? false)
    }

    /// photocraft `vector_cmds::path_json`: the compact JSON form of a path.
    static func pathJSON(_ p: VectorPath) -> JSONValue {
        func a(_ q: PCPoint) -> JSONValue { [.number(q.x), .number(q.y)] }
        let subs: [JSONValue] = p.subpaths.map { s in
            [
                "closed": .bool(s.closed), "op": .string(opName(s.op)),
                "knots": .array(s.knots.map { ["anchor": a($0.anchor), "in": a($0.inCtrl), "out": a($0.outCtrl), "smooth": .bool($0.smooth)] }),
            ]
        }
        return ["subpaths": .array(subs), "fillRule": .string(p.fillRule == .evenOdd ? "evenodd" : "nonzero"), "inverted": .bool(p.inverted)]
    }

    /// photocraft `edit_menu_cmds::current_path`: the named path (`"work"` or a saved path's name),
    /// else the work path, the active shape layer's path, its vector mask, or the last saved path.
    static func currentPath(_ doc: Document, _ active: LayerId?, _ spec: String?) -> VectorPath? {
        func ok(_ p: VectorPath) -> Bool { !p.subpaths.isEmpty }
        switch spec {
        case "work"?: return doc.workPath.flatMap { ok($0) ? $0 : nil }
        case let name?: return doc.paths.first { $0.name == name }.map(\.path).flatMap { ok($0) ? $0 : nil }
        case nil: break
        }
        if let p = doc.workPath, ok(p) { return p }
        if let l = active.flatMap({ doc.layer($0) }) {
            if case .shape(let sh) = l.content, ok(sh.path) { return sh.path }
            if let vm = l.vectorMask, ok(vm.path) { return vm.path }
        }
        return doc.paths.last.map(\.path).flatMap { ok($0) ? $0 : nil }
    }

    // MARK: Placing without shape.create

    /// `vector_cmds::color`: `[r,g,b(,a)]` or `"#rrggbb(aa)"`.
    static func shapeColor(_ v: JSONValue) -> PCColor? {
        switch v {
        case .array(let a) where a.count >= 3:
            let c = a.map { Float($0.doubleValue ?? 0) }
            return .rgb(c[0], c[1], c[2], c.count > 3 ? c[3] : 1)
        case .string(let s):
            let b = LayerStyleCommands.hexBytes(s)
            func h(_ i: Int) -> Float? { LayerStyleCommands.hexPair(b, i).map { Float($0) / 255 } }
            switch b.count {
            case 6:
                guard let r = h(0), let g = h(2), let bl = h(4) else { return nil }
                return .rgb(r, g, bl)
            case 8:
                guard let r = h(0), let g = h(2), let bl = h(4), let a = h(6) else { return nil }
                return .rgb(r, g, bl, a)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// `vector_cmds::parse_fill`: `"#rrggbb"` / `[r,g,b,a]` / `{"gradient":{…}}` /
    /// `{"pattern":name,"scale"}`; `null` is no fill.
    static func parseShapeFill(_ v: JSONValue) throws(ShapeParseError) -> Fill? {
        if v == .null { return nil }
        if let c = shapeColor(v) { return .solid(c) }
        if let g = v["gradient"] {
            let stops: [ColorStop] = g["stops"]?.arrayValue.map { a in
                a.compactMap { s in
                    guard let t = s[0]?.doubleValue, let c = s[1].flatMap(shapeColor) else { return nil }
                    return ColorStop(Float(t), c)
                }
            } ?? [ColorStop(0, .black), ColorStop(1, .white)]
            return .gradient(GradientFill(stops: stops, angle: Float(g["angle"]?.doubleValue ?? 90), scale: Float(g["scale"]?.doubleValue ?? 100) / 100,
                                          style: LayerStyleCommands.gradientStyle(g["style"]?.stringValue ?? "linear"), reverse: g["reverse"]?.boolValue ?? false))
        }
        if let name = v["pattern"]?.stringValue {
            return .pattern(PatternFill(name: name, scale: Float(v["scale"]?.doubleValue ?? 100) / 100, id: "", angle: 0, link: true, phase: .zero))
        }
        throw ShapeParseError(message: "unrecognised fill \(v.serialized())")
    }

    static func shapeHex(_ c: PCColor) -> String {
        let v = c.rgb
        func q(_ x: Float) -> Int { Int((clamp01(x) * 255).rounded()) }
        return c.alpha < 1 ? String(format: "#%02x%02x%02x%02x", q(v.x), q(v.y), q(v.z), q(c.alpha))
            : String(format: "#%02x%02x%02x", q(v.x), q(v.y), q(v.z))
    }

    static func shapeFillJSON(_ f: Fill) -> JSONValue {
        switch f {
        case .solid(let c): .string(shapeHex(c))
        case .gradient(let g):
            ["gradient": ["stops": .array(g.stops.map { [.float($0.location), .string(shapeHex($0.color))] }), "angle": .float(g.angle),
                          "scale": .float(g.scale * 100), "style": .string(g.style.rawValue.lowercased()), "reverse": .bool(g.reverse)]]
        case .pattern(let p): ["pattern": .string(p.name), "scale": .float(p.scale * 100)]
        }
    }

    static func shapeStrokeJSON(_ s: ShapeStroke) -> JSONValue {
        [
            "width": .float(s.width), "fill": shapeFillJSON(s.paint), "opacity": .float(s.opacity * 100), "align": .string(s.align.rawValue.lowercased()),
            "cap": .string(s.cap.rawValue.lowercased()), "join": .string(s.join.rawValue.lowercased()), "miterLimit": .float(s.miterLimit),
            "dashes": .floats(s.dashes), "dashOffset": .float(s.dashOffset),
        ]
    }

    /// `vector_cmds::shape_info` of a shape layer.
    static func shapeInfo(_ s: Session, _ id: LayerId) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .shape(let sh) = l.content else {
            throw EngineError.other("layer \(id.rawValue) is \(l.content.article) \(l.content.kindName) layer, not a shape layer")
        }
        let bounds: JSONValue = sh.cache.map(\.contentBounds).flatMap { $0.isEmpty ? nil : JSONValue.rect($0) } ?? .null
        return [
            "layer": .id(id), "name": .string(l.name), "path": pathJSON(sh.path), "fill": sh.fill.map(shapeFillJSON) ?? .null,
            "stroke": sh.stroke.map(shapeStrokeJSON) ?? .null, "live": sh.live.map { JSONValue.encoded($0) } ?? .null, "kind": "path", "bounds": bounds,
        ]
    }

    /// `shape.create` with `kind: "path"` for `shape.presets.place` when `vector_cmds` isn't
    /// installed: a shape layer of `path` (fill, name, `addTo`/`op`) rendered through PCPlatform's
    /// `VectorRasterizer`. Strokes need `shape.create`'s stroke parser.
    static func createShapeLayer(_ s: Session, _ path: VectorPath, _ q: JSONValue) throws -> JSONValue {
        let cmd = "shape.create"
        let fg = s.tools.foreground
        let fill: Fill?
        if let v = q["fill"] {
            do { fill = try parseShapeFill(v) } catch { throw EngineError.bad(cmd, error.message) }
        } else {
            fill = .solid(.rgb(fg.x, fg.y, fg.z, fg.w))
        }
        if let st = q["stroke"], st != .null, st != .bool(false) {
            throw EngineError.unavailable("shape.presets.place", "a stroke needs shape.create (vector_cmds)")
        }
        if let target = q["addTo"]?.uint64Value {
            var op = PathOp.combine
            if let o = q["op"]?.stringValue {
                guard let x = opFrom(o) else { throw EngineError.bad(cmd, "unknown `op`") }
                op = x
            }
            let id = LayerId(target)
            if let st = s.active {
                let locks = st.doc.effectiveLocks(id)
                if locks.all || locks.pixels { throw EngineError.other("shape layer is locked") }
            }
            try s.edit("Add Shape") { doc, _ in
                guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
                guard case .shape(var sh) = l.content else {
                    throw EngineError.other("layer \(id.rawValue) is \(l.content.article) \(l.content.kindName) layer, not a shape layer")
                }
                for var sp in path.subpaths {
                    sp.op = op
                    sh.path.subpaths.append(sp)
                }
                sh.live = nil
                sh.psdRaw = nil
                VectorRasterizer.renderCache(&sh, format: doc.pixelFormat, clip: doc.bounds)
                doc.updateLayer(id) { $0.content = .shape(sh) }
            }
            return try shapeInfo(s, id)
        }
        let name = q["name"]?.stringValue
        let id = try s.edit("New Shape Layer") { doc, active -> LayerId in
            var sh = ShapeLayer(path: path, fill: fill)
            VectorRasterizer.renderCache(&sh, format: doc.pixelFormat, clip: doc.bounds)
            let id = doc.insertAbove(active, Layer(name: name ?? doc.nextLayerName("Shape"), content: .shape(sh)))
            active = id
            return id
        }
        return try shapeInfo(s, id)
    }

    // MARK: - Tool presets

    /// A tool plus its options under a name. `options` is opaque JSON the frontend writes and reads
    /// back; the engine understands `"brush"` (brush settings, applied like `tools.setBrush`) and
    /// `"foreground"` (Include Color). Crop presets are `"crop"` tool presets.
    struct ToolPreset: Hashable, Sendable, Codable, Named {
        var name: String
        /// Tool name as the shell spells it (`"brush"`, `"eraser"`, `"gradient"`, …), case-insensitive.
        var tool: String
        var options: JSONValue

        var presetName: String {
            get { name }
            set { name = newValue }
        }

        init(name: String, tool: String, options: JSONValue) { self.name = name; self.tool = tool; self.options = options }

        enum CodingKeys: String, CodingKey { case name, tool, options }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            tool = try c.decode(String.self, forKey: .tool)
            options = try c.decodeIfPresent(JSONValue.self, forKey: .options) ?? .null
        }
    }

    /// The most tool presets kept (saving more is refused; a larger preferences file loads the first).
    static let maxToolPresets = 1000
    /// photocraft `brush_preset_cmds::MAX_NAME`.
    static let maxPresetName = 255

    /// A preset name: trimmed, 1…255 characters.
    static func checkedName(_ name: String, _ cmd: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { throw EngineError.bad(cmd, "the preset name is empty") }
        if n.unicodeScalars.count > maxPresetName { throw EngineError.bad(cmd, "preset names are at most \(maxPresetName) characters") }
        return n
    }

    /// photocraft `tools::load`: saved tool presets read entry by entry, so a damaged entry (wrong
    /// type, empty or overlong name, a duplicate name) is skipped without discarding the others.
    static func loadToolPresets(_ value: JSONValue) -> [ToolPreset] {
        guard let entries = value.arrayValue else { return [] }
        var presets: [ToolPreset] = []
        for e in entries {
            if presets.count >= maxToolPresets { break }
            guard var preset = try? e.decode(as: ToolPreset.self), let name = try? checkedName(preset.name, "") else { continue }
            if preset.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || presets.contains(where: { $0.name == name }) { continue }
            if preset.options.objectValue == nil { preset.options = .object([:]) }
            preset.name = name
            presets.append(preset)
        }
        return presets
    }

    static func normTool(_ t: String) -> String {
        var s = String(t.lowercased().filter { $0 != " " && $0 != "_" && $0 != "-" })
        while s.hasSuffix("tool") { s.removeLast(4) }
        return s
    }

    /// A few starting presets (photocraft's own).
    static func builtinTools() -> [ToolPreset] {
        func brush(_ size: Float, _ hardness: Float) -> JSONValue { ["brush": ["size": .float(size), "hardness": .float(hardness)]] }
        return [
            ToolPreset(name: "Soft Round 100 px", tool: "brush", options: brush(100, 0)),
            ToolPreset(name: "Hard Round 12 px", tool: "brush", options: brush(12, 1)),
            ToolPreset(name: "Soft Eraser 60 px", tool: "eraser", options: brush(60, 0)),
            ToolPreset(name: "Radial Gradient", tool: "gradient", options: ["toolOptions": ["gradient_style": "radial"]]),
            ToolPreset(name: "Clone Soft 40 px", tool: "cloneStamp", options: brush(40, 0.2)),
        ]
    }

    static func toolList(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let filter = strParam(p, "tool").map(normTool)
        let items: [JSONValue] = state(s).toolPresets.filter { filter == nil || normTool($0.tool) == filter }.map {
            ["name": .string($0.name), "tool": .string($0.tool)]
        }
        return ["presets": .array(items)]
    }

    static let brushTools: Set<String> = [
        "brush", "pencil", "eraser", "clonestamp", "healing", "spothealing", "historybrush", "blur", "sharpen", "smudge", "dodge", "burn", "sponge",
        "mixerbrush", "colorreplacement",
    ]

    static func toolNew(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "tool.presets.new"
        let tool = try reqStr(p, "tool", cmd)
        guard case .object(var options) = p["options"] ?? .object([:]) else { throw EngineError.bad(cmd, "`options` must be an object") }
        // Brush-based tools carry the current brush unless the caller sent one.
        if options["brush"] == nil && brushTools.contains(normTool(tool)) { options["brush"] = .encoded(s.tools.brush) }
        if p["includeColor"]?.boolValue ?? false { options["foreground"] = .rgba(s.tools.foreground) }
        var st = state(s)
        if st.toolPresets.count >= maxToolPresets {
            throw EngineError.bad(cmd, "at most \(maxToolPresets) tool presets can be saved; delete some first")
        }
        let base: String
        switch p["name"] {
        case nil, .null?: base = tool
        case .string(let n)? where n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: base = tool
        case .string(let n)?: base = try checkedName(n, cmd)
        default: throw EngineError.bad(cmd, "`name` must be a string")
        }
        let name = uniqueName([Group("", st.toolPresets)], base)
        st.toolPresets.append(ToolPreset(name: name, tool: tool, options: .object(options)))
        s.state[Key.self] = st
        presetsChanged(s)
        return ["name": .string(name), "tool": .string(tool)]
    }

    static func toolSelect(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "tool.presets.select"
        let name = try reqStr(p, "preset", cmd)
        guard let t = state(s).toolPresets.first(where: { $0.name == name }) else {
            throw EngineError.bad(cmd, "no tool preset \"\(name)\" (see tool.presets.list)")
        }
        if let b = t.options["brush"], b.objectValue != nil { _ = try call(s, "tools.setBrush", ["brush": b]) }
        if let c = t.options["foreground"]?.arrayValue, c.count >= 3 {
            let v = c.map { Float($0.doubleValue ?? 0) }
            s.tools.foreground = SIMD4(v[0], v[1], v[2], v.count > 3 ? v[3] : 1)
            s.emit(.toolsChanged)
        }
        return ["name": .string(t.name), "tool": .string(t.tool), "options": t.options]
    }

    static func toolEdit(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "tool.presets.edit"
        let action = try reqStr(p, "action", cmd)
        if action != "rename" && action != "delete" { throw EngineError.bad(cmd, "tool presets support rename and delete") }
        if action == "rename" { _ = try checkedName(try reqStr(p, "name", cmd), cmd) }
        var groups = [Group("", state(s).toolPresets)]
        let r = try editGroups(&groups, action, p, cmd)
        s.state[Key.self].toolPresets = groups.first?.items ?? []
        presetsChanged(s)
        return r
    }

    static func toolReset(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        s.state[Key.self].toolPresets = builtinTools()
        presetsChanged(s)
        return ["presets": .int(state(s).toolPresets.count)]
    }

    static func toolSpecs() -> [CommandSpec] {
        [
            CommandSpec("tool.presets.list", "Tool Presets", params: ##"{"tool":name? (Current Tool Only)} → {presets:[{name,tool}]}"##,
                        module: m, journal: false, run: toolList),
            CommandSpec("tool.presets.new", "New Tool Preset…",
                        params: ##"{"name":str?=tool (at most 255 characters; a taken name gets " 2", " 3"…),"tool":name ("crop" for Crop presets),"options":{…}? (opaque; "brush" defaults to the current brush for painting tools),"includeColor":bool=false}"##,
                        module: m, run: toolNew),
            CommandSpec("tool.presets.select", "Select Tool Preset",
                        params: ##"{"preset":name} → {name,tool,options} (applies "brush" and "foreground"; the shell switches tool and options)"##,
                        module: m, run: toolSelect),
            CommandSpec("tool.presets.edit", "Edit Tool Presets", params: ##"{"action":"rename|delete","preset":name|[names],"name":str (rename)}"##,
                        module: m, run: toolEdit),
            CommandSpec("tool.presets.reset", "Reset Tool Presets", params: "{}", module: m, run: toolReset),
        ]
    }
}
