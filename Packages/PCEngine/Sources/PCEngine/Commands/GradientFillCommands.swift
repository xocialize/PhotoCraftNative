// Port of photocraft-engine (crates/engine/src/gradient_fill_cmds.rs; the handle geometry of photocraft-compose gradient_fill.rs `handles`/`from_handles`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Live gradients: the Gradient tool's non-destructive mode (Photoshop 2023+). A drag makes a
// Gradient Fill layer above the active layer, masked by the selection, whose start and end points,
// colour stops, opacity stops and midpoints stay editable on canvas afterwards (the classic
// destructive mode is `paint.gradient`). A live gradient is laid out on the canvas ("Align with
// layer" off), so its handles stay put when its mask changes; its start/end points are stored as
// the fill's angle, scale and centre offset, which is what a PSD Gradient Fill holds. Every edit is
// one command, so one history step per gesture: the UI previews a drag with `applySet` and commits
// it once on release.

import Foundation
import PCDocument
import PCFoundation
import PCRender

enum GradientFillCommands: CommandModule {
    static let name = "gradient_fill_cmds"
    static let m = name
    static let create = "gradient.fill.create"
    static let set = "gradient.fill.set"
    static let stop = "gradient.fill.stop"
    static let get = "gradient.fill.get"

    /// Largest coordinate accepted for a start/end point (pixels).
    static let maxCoord: Float = 1.0e7
    /// Scale range of a gradient fill (a fraction): Photoshop allows 10–150 %. A handle drag past it
    /// clamps, so the far handle stops where the scale does.
    static let scaleRange: (Float, Float) = (0.1, 1.5)
    /// Smallest gradient length a handle drag produces (pixels), so the fill stays invertible.
    static let minLen: Float = 0.5

    static func register(into r: inout CommandRegistry) {
        r.add(specs())
    }

    // MARK: Handle geometry (photocraft-compose gradient_fill.rs)

    static func frameDims(_ frame: PixelRect) -> (Float, Float) { (Float(max(frame.width, 1)), Float(max(frame.height, 1))) }

    /// The centre a gradient is laid out around: the frame's centre moved by `offset`.
    static func centre(_ offset: SIMD2<Float>, _ frame: PixelRect) -> SIMD2<Float> {
        let (w, h) = frameDims(frame)
        return SIMD2(Float(frame.x0) + w / 2 + offset.x * w, Float(frame.y0) + h / 2 + offset.y * h)
    }

    /// The gradient's reach from its centre at scale 1: the full chord for Linear, half the chord
    /// for Reflected, the radius for the others.
    static func unitReach(_ style: GradientStyle, _ angle: Float, _ frame: PixelRect) -> Float {
        let (w, h) = frameDims(frame)
        let (chord, len) = GradientMath.units(angle, w, h)
        switch style {
        case .linear: return chord
        case .reflected: return chord / 2
        case .radial, .angle, .diamond: return len / 2
        }
    }

    /// The start and end points (document pixels) of a gradient laid out in `frame`.
    static func handles(_ style: GradientStyle, _ angle: Float, _ scale: Float, _ offset: SIMD2<Float>, _ frame: PixelRect) -> (SIMD2<Float>, SIMD2<Float>) {
        let c = centre(offset, frame)
        let a = angle * (Float.pi / 180)
        let dir = SIMD2(cosf(a), -sinf(a))
        let reach = unitReach(style, angle, frame) * max(scale, 1e-3)
        if style == .linear {
            let h = reach / 2
            return (c - dir * h, c + dir * h)
        }
        return (c, c + dir * reach)
    }

    /// Angle (degrees), scale and centre offset that put a gradient's start and end points at
    /// `from` and `to` in `frame` (inverse of `handles`). A zero-length drag keeps the direction
    /// of `fallbackAngle`.
    static func fromHandles(_ style: GradientStyle, _ from: SIMD2<Float>, _ to: SIMD2<Float>, _ frame: PixelRect,
                            _ fallbackAngle: Float) -> (Float, Float, SIMD2<Float>) {
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        let len0 = hypotf(dx, dy)
        let angle = len0 > 1e-4 ? atan2f(-dy, dx) * (180 / Float.pi) : fallbackAngle
        let len = max(len0, minLen)
        let c = style == .linear ? (from + to) / 2 : from
        let (w, h) = frameDims(frame)
        let offset = SIMD2((c.x - Float(frame.x0) - w / 2) / w, (c.y - Float(frame.y0) - h / 2) / h)
        return (angle, len / unitReach(style, angle, frame), offset)
    }

    // MARK: Params

    static func num(_ p: JSONValue, _ k: String) -> Float? {
        guard let v = p[k]?.doubleValue.map({ Float($0) }), v.isFinite else { return nil }
        return v
    }

    static func point(_ cmd: String, _ p: JSONValue, _ k: String) throws -> SIMD2<Float>? {
        guard let v = p[k] else { return nil }
        guard let a = v.arrayValue, a.count == 2 else { throw EngineError.bad(cmd, "`\(k)` is [x, y]") }
        func c(_ i: Int) -> Float? {
            guard let x = a[i].doubleValue.map({ Float($0) }), x.isFinite, abs(x) <= maxCoord else { return nil }
            return x
        }
        guard let x = c(0), let y = c(1) else { throw EngineError.bad(cmd, "`\(k)` needs finite coordinates within ±10000000") }
        return SIMD2(x, y)
    }

    static func styleParam(_ cmd: String, _ p: JSONValue) throws -> GradientStyle? {
        switch p["style"] {
        case nil, .null?: return nil
        case .string(let s)?:
            switch s.lowercased() {
            case "linear": return .linear
            case "radial": return .radial
            case "angle": return .angle
            case "reflected": return .reflected
            case "diamond": return .diamond
            case let o: throw EngineError.bad(cmd, "unknown style `\(o)` (linear|radial|angle|reflected|diamond)")
            }
        default: throw EngineError.bad(cmd, "`style` is a string")
        }
    }

    static func styleName(_ s: GradientStyle) -> String {
        switch s {
        case .linear: "linear"
        case .radial: "radial"
        case .angle: "angle"
        case .reflected: "reflected"
        case .diamond: "diamond"
        }
    }

    /// A stop colour: `"#rrggbb"`, `"#rrggbbaa"`, `[r, g, b, a?]` (0..1), `"foreground"` or
    /// `"background"`.
    static func parseColor(_ v: JSONValue, _ fg: SIMD4<Float>, _ bg: SIMD4<Float>) -> PCColor? {
        var c: SIMD4<Float>
        switch v {
        case .string("foreground"): c = fg
        case .string("background"): c = bg
        case .string(let s):
            let h = LayerStyleCommands.hexBytes(s)
            func b(_ i: Int) -> Float? { LayerStyleCommands.hexPair(h, i).map { Float($0) / 255 } }
            switch h.count {
            case 6:
                guard let r = b(0), let g = b(2), let bl = b(4) else { return nil }
                c = SIMD4(r, g, bl, 1)
            case 8:
                guard let r = b(0), let g = b(2), let bl = b(4), let a = b(6) else { return nil }
                c = SIMD4(r, g, bl, a)
            default:
                return nil
            }
        case .array(let a) where (3...4).contains(a.count):
            func f(_ i: Int) -> Float? {
                guard let x = a[i].doubleValue.map({ Float($0) }), x.isFinite else { return nil }
                return x
            }
            guard let r = f(0), let g = f(1), let bl = f(2) else { return nil }
            var al: Float = 1
            if a.count == 4 {
                guard let x = f(3) else { return nil }
                al = x
            }
            c = SIMD4(r, g, bl, al)
        default:
            return nil
        }
        c = c.clamped(lowerBound: SIMD4(repeating: 0), upperBound: SIMD4(repeating: 1))
        return .rgb(c.x, c.y, c.z, c.w)
    }

    static func hex(_ c: PCColor) -> String {
        let rgb = c.rgb
        func q(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return c.alpha >= 1 ? String(format: "#%02x%02x%02x", q(rgb.x), q(rgb.y), q(rgb.z))
            : String(format: "#%02x%02x%02x%02x", q(rgb.x), q(rgb.y), q(rgb.z), q(c.alpha))
    }

    /// The gradient a `gradient.fill.create` uses: a preset (`"gradient"`, by name ignoring ASCII
    /// case), explicit `"stops"`, else the current gradient; explicit `"transparency"` stops
    /// replace its own.
    static func presetParam(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> PresetCommands.GradientPreset {
        let st = PresetCommands.state(s)
        if let name = p["gradient"]?.stringValue {
            let lower = name.lowercased()
            guard let g = st.gradients.lazy.flatMap(\.items).first(where: { $0.name.lowercased() == lower }) else {
                throw EngineError.bad(cmd, "no gradient preset \"\(name)\" (see gradient.presets.list)")
            }
            return try g.withTransparency(p, cmd)
        }
        if p["stops"] != nil { return try PresetCommands.GradientPreset.fromParams("Custom", p, cmd) }
        return try st.gradient.withTransparency(p, cmd)
    }

    /// The fill and frame of gradient fill layer `id`.
    static func gradientOf(_ s: Session, _ id: LayerId, _ cmd: String) throws -> (GradientFill, PixelRect) {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        guard case .fill(.gradient(let g)) = l.content else { throw EngineError.bad(cmd, "layer \"\(l.name)\" is not a gradient fill layer") }
        return (g, LayerGeometry.fillFrame(l, canvas: d.doc.bounds))
    }

    /// Whether the active layer is a gradient fill layer (the commands' precondition).
    static let hasGradientFill: CommandEnabled = { s, _ in
        switch s.activeLayer() {
        case .failure(let e): return e.description
        case .success(let l):
            if case .fill(.gradient) = l.content { return nil }
            return "the active layer is not a gradient fill layer"
        }
    }

    static func clampScale(_ v: Float) -> Float { min(max(v, scaleRange.0), scaleRange.1) }

    /// The frame a gradient fill of `layer` (with `g`'s align) is laid out in.
    static func frameWithAlign(_ layer: Layer, _ g: GradientFill, _ canvas: PixelRect) -> PixelRect {
        var l = layer
        l.content = .fill(.gradient(g))
        return LayerGeometry.fillFrame(l, canvas: canvas)
    }

    /// photocraft `apply_set`: applies `gradient.fill.set` params to a gradient fill (`layer`
    /// gives its frame; `fg`/`bg` resolve stop colours). Pure, so the canvas previews a handle
    /// drag with exactly what the command will commit.
    static func applySet(_ layer: Layer, _ f: GradientFill, _ canvas: PixelRect, _ p: JSONValue, _ fg: SIMD4<Float>, _ bg: SIMD4<Float>) throws -> GradientFill {
        let cmd = set
        var g = f
        let oldFrame = frameWithAlign(layer, f, canvas)
        let oldHandles = handles(g.style, g.angle, g.scale, g.offset, oldFrame)
        if let v = p["align"] {
            guard let b = v.boolValue else { throw EngineError.bad(cmd, "`align` is a boolean") }
            g.align = b
        }
        let newStyle = try styleParam(cmd, p)
        let explicitGeometry = ["angle", "scale", "offset"].contains { p[$0] != nil }
        if let a = p["angle"] {
            guard let x = a.doubleValue.map({ Float($0) }), x.isFinite else { throw EngineError.bad(cmd, "`angle` is a number (degrees)") }
            var r = x.truncatingRemainder(dividingBy: 360)
            if r < 0 { r += 360 }
            if r > 180 { r -= 360 }
            g.angle = r
        }
        if p["scale"] != nil {
            guard let v = num(p, "scale"), v > 0 else { throw EngineError.bad(cmd, "`scale` is a positive percentage") }
            g.scale = clampScale(v / 100)
        }
        if let o = p["offset"] {
            guard let a = o.arrayValue, a.count == 2 else { throw EngineError.bad(cmd, "`offset` is [x%, y%]") }
            func c(_ i: Int) -> Float? {
                guard let x = a[i].doubleValue.map({ Float($0) }), x.isFinite, abs(x) <= 1.0e5 else { return nil }
                return x
            }
            guard let x = c(0), let y = c(1) else { throw EngineError.bad(cmd, "`offset` needs finite percentages") }
            g.offset = SIMD2(x / 100, y / 100)
        }
        if let v = p["reverse"] {
            guard let b = v.boolValue else { throw EngineError.bad(cmd, "`reverse` is a boolean") }
            g.reverse = b
        }
        if let v = p["dither"] {
            guard let b = v.boolValue else { throw EngineError.bad(cmd, "`dither` is a boolean") }
            g.dither = b
        }
        let from = try point(cmd, p, "from")
        let to = try point(cmd, p, "to")
        var tmp = g
        tmp.stops = []
        tmp.opacityStops = []
        tmp.midpoints = []
        let frame = frameWithAlign(layer, tmp, canvas)
        // A style change alone keeps the handles where they are (they are what the user placed).
        let styleChanged = newStyle.map { $0 != g.style } ?? false
        if let ns = newStyle { g.style = ns }
        if from != nil || to != nil || (styleChanged && !explicitGeometry) {
            let cur = from != nil || to != nil ? handles(g.style, g.angle, g.scale, g.offset, frame) : oldHandles
            let (f0, t0) = (from ?? cur.0, to ?? cur.1)
            let (a, sc, o) = fromHandles(g.style, f0, t0, frame, g.angle)
            (g.angle, g.scale, g.offset) = (a, clampScale(sc), o)
            // Past the scale range the dragged handle stops; the other one stays where it is (#1243).
            var anchor: (SIMD2<Float>, Bool)?
            if from != nil && to == nil { anchor = (t0, false) } else if from == nil && to != nil { anchor = (f0, true) }
            if let (pin, isStart) = anchor, g.scale != sc {
                let (f1, t1) = handles(g.style, g.angle, g.scale, g.offset, frame)
                let at = isStart ? f1 : t1
                let (w, h) = (Float(max(frame.width, 1)), Float(max(frame.height, 1)))
                g.offset += SIMD2((pin.x - at.x) / w, (pin.y - at.y) / h)
            }
        }
        if let v = p["stops"] {
            guard let arr = v.arrayValue else { throw EngineError.bad(cmd, "`stops` is [[location, colour], …]") }
            var new: [ColorStop] = []
            for s in arr {
                guard let pair = s.arrayValue, pair.count == 2 else { throw EngineError.bad(cmd, "a stop is [location 0..1, colour]") }
                guard let t = pair[0].doubleValue.map({ Float($0) }), t.isFinite else { throw EngineError.bad(cmd, "stop location is a number") }
                guard let c = parseColor(pair[1], fg, bg) else {
                    throw EngineError.bad(cmd, ##"stop colour is "#rrggbb", [r,g,b,a], "foreground" or "background""##)
                }
                new.append(ColorStop(min(max(t, 0), 1), c))
            }
            if new.count < 2 { throw EngineError.bad(cmd, "a gradient needs at least 2 colour stops") }
            if new.count > 1024 { throw EngineError.bad(cmd, "too many colour stops (max 1024)") }
            new = PresetCommands.stableSorted(new, by: \.location)
            if new.count != g.stops.count { g.midpoints.removeAll() }
            g.stops = new
        }
        if let new = try PresetCommands.transparencyParam(p, cmd) { g.opacityStops = new }
        if let v = p["midpoints"] {
            guard let arr = v.arrayValue else { throw EngineError.bad(cmd, "`midpoints` is [0..1, …] (one per segment)") }
            var mids: [Float] = []
            for x in arr {
                guard let m = x.doubleValue.map({ Float($0) }), m.isFinite else { throw EngineError.bad(cmd, "midpoints are numbers") }
                mids.append(min(max(m, 0.05), 0.95))
            }
            let segments = max(g.stops.count - 1, 0)
            if mids.count > segments { throw EngineError.bad(cmd, "\(mids.count) midpoints for \(segments) segments") }
            g.midpoints = mids
        }
        return g
    }

    /// photocraft `new_layer`: the Gradient Fill layer `gradient.fill.create` adds for `p` (also
    /// the canvas's live preview of a Gradient tool drag): laid out on the canvas, so the handles
    /// land exactly where the drag was, and masked by the selection.
    static func newLayer(_ s: Session, _ doc: Document, _ p: JSONValue) throws -> Layer {
        let cmd = create
        guard let from = try point(cmd, p, "from") else { throw EngineError.bad(cmd, "missing `from` [x, y]") }
        guard let to = try point(cmd, p, "to") else { throw EngineError.bad(cmd, "missing `to` [x, y]") }
        let style = try styleParam(cmd, p) ?? .linear
        let g = try presetParam(s, p, cmd)
        let (stops, opacityStops) = g.fillStops(s.tools.foreground, s.tools.background)
        let reverse = p["reverse"]?.boolValue ?? false
        let dither = p["dither"]?.boolValue ?? true
        let opacity = min(max(num(p, "opacity") ?? 100, 0), 100) / 100
        let blend: BlendMode
        switch p["mode"]?.stringValue {
        case nil, ""?: blend = .normal
        case let mode?:
            guard let b = Params.blendMode(mode) else { throw EngineError.bad(cmd, "unknown blend mode `\(mode)`") }
            blend = b
        }
        let canvas = doc.bounds
        if canvas.isEmpty { throw EngineError.bad(cmd, "the document is empty") }
        let (angle, scale, offset) = fromHandles(style, from, to, canvas, 0)
        let fill = Fill.gradient(GradientFill(stops: stops, angle: angle, scale: clampScale(scale), style: style, reverse: reverse,
                                              opacityStops: opacityStops, midpoints: [], offset: offset, dither: dither, align: false)).inMode(doc.mode)
        var l = Layer(name: doc.nextLayerName("Gradient Fill"), content: .fill(fill))
        l.opacity = opacity
        l.blend = blend
        l.mask = LayerOps.selectionMask(doc)
        return l
    }

    static func createRun(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let layer = try newLayer(s, d.doc, p)
        let id = try s.edit("New Gradient Fill Layer") { doc, active -> LayerId in
            let id = doc.insertAbove(active, layer)
            active = id
            return id
        }
        return ["layer": .id(id)]
    }

    static func setRun(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let (fill, _) = try gradientOf(s, id, set)
        guard let d = s.active, let layer = d.doc.layer(id) else { throw EngineError.noLayer(id) }
        let new = try applySet(layer, fill, d.doc.bounds, p, s.tools.foreground, s.tools.background)
        if new != fill { try replaceFill(s, id, "Edit Gradient Fill", new) }
        return try describe(s, id)
    }

    static func replaceFill(_ s: Session, _ id: LayerId, _ label: String, _ new: GradientFill) throws {
        guard let d = s.active else { throw EngineError.noDocument }
        try LayerOps.checkPixelsUnlocked(d.doc, id)
        try s.edit(label) { doc, _ in
            let mode = doc.mode
            guard doc.layer(id) != nil else { throw EngineError.noLayer(id) }
            doc.updateLayer(id) { $0.content = .fill(Fill.gradient(new).inMode(mode)) }
        }
    }

    /// Sorted colour stops paired with the midpoint of the segment that follows each.
    static func paired(_ stops: [ColorStop], _ mids: [Float]) -> [(ColorStop, Float)] {
        PresetCommands.stableSorted(stops.enumerated().map { ($0.element, $0.offset < mids.count ? mids[$0.offset] : 0.5) }, by: \.0.location)
    }

    static func unpair(_ v: [(ColorStop, Float)]) -> ([ColorStop], [Float]) {
        let v = PresetCommands.stableSorted(v, by: \.0.location)
        var mids = v.prefix(max(v.count - 1, 0)).map(\.1)
        if mids.allSatisfy({ abs($0 - 0.5) < 1e-6 }) { mids = [] }
        return (v.map(\.0), mids)
    }

    /// The colour stops' own alpha at `t` (without the opacity stops).
    static func rampColorAlpha(_ g: GradientFill, _ t: Float) -> Float {
        let bare = GradientFill(stops: g.stops, angle: 0, scale: 1, style: .linear, reverse: false, opacityStops: [], midpoints: g.midpoints,
                                offset: .zero, dither: false, align: true)
        return max(GradientMath.FillRamp(bare).sample(t).w, 1e-6)
    }

    /// photocraft `apply_stop`: a `gradient.fill.stop` edit of a gradient fill. Pure (see `applySet`).
    static func applyStop(_ f: GradientFill, _ p: JSONValue, _ fg: SIMD4<Float>, _ bg: SIMD4<Float>) throws -> GradientFill {
        let cmd = stop
        var g = f
        guard let action = p["action"]?.stringValue else { throw EngineError.bad(cmd, "missing `action` (add|move|delete|color|opacity|midpoint)") }
        let opacityKind: Bool
        switch p["kind"]?.stringValue ?? "color" {
        case "color": opacityKind = false
        case "opacity": opacityKind = true
        case let o: throw EngineError.bad(cmd, "unknown kind `\(o)` (color|opacity)")
        }
        // The `index` param, checked against the `len` entries it can address before any
        // arithmetic on it: an index is untrusted and can be as large as the integer type (#958).
        func index(_ len: Int, _ what: String) throws -> Int {
            guard let i = p["index"]?.uint64Value else { throw EngineError.bad(cmd, "missing `index` (a stop number from 0)") }
            if i >= UInt64(len) { throw EngineError.bad(cmd, "no \(what) \(i) (there are \(len))") }
            return Int(i)
        }
        func location() throws -> Float {
            guard let v = num(p, "location") else { throw EngineError.bad(cmd, "missing `location` (0..1)") }
            return min(max(v, 0), 1)
        }
        let ramp = GradientMath.FillRamp(f)
        if opacityKind {
            // Opacity stops: an empty list means "opaque" (two 100 % stops when first edited).
            var os = PresetCommands.stableSorted(g.opacityStops.isEmpty ? [OpacityStop(0, 1), OpacityStop(1, 1)] : g.opacityStops, by: \.location)
            func opacity() throws -> Float {
                guard let v = num(p, "opacity") else { throw EngineError.bad(cmd, "missing `opacity` (0..100)") }
                return min(max(v / 100, 0), 1)
            }
            switch action {
            case "add":
                let t = try location()
                let a = num(p, "opacity").map { min(max($0 / 100, 0), 1) } ?? ramp.sample(t).w / rampColorAlpha(f, t)
                os.append(OpacityStop(t, min(max(a, 0), 1)))
            case "move":
                let i = try index(os.count, "opacity stop")
                os[i].location = try location()
            case "delete":
                let i = try index(os.count, "opacity stop")
                if os.count <= 2 { throw EngineError.bad(cmd, "a gradient keeps at least 2 opacity stops") }
                os.remove(at: i)
            case "opacity":
                let i = try index(os.count, "opacity stop")
                os[i].opacity = try opacity()
            default:
                throw EngineError.bad(cmd, "unknown action `\(action)` for opacity stops (add|move|delete|opacity)")
            }
            os = PresetCommands.stableSorted(os, by: \.location)
            if os.count > 1024 { throw EngineError.bad(cmd, "too many opacity stops (max 1024)") }
            g.opacityStops = os
            return g
        }
        var v = paired(g.stops, g.midpoints)
        switch action {
        case "add":
            let t = try location()
            // A new stop takes the colour the gradient has there (Photoshop), unless given.
            let c: PCColor
            if let cv = p["color"] {
                guard let x = parseColor(cv, fg, bg) else { throw EngineError.bad(cmd, "bad `color`") }
                c = x
            } else {
                let smp = ramp.sample(t)
                c = .rgb(smp.x, smp.y, smp.z, rampColorAlpha(f, t))
            }
            // Splitting a segment resets its midpoint.
            if let prev = v.lastIndex(where: { $0.0.location <= t }) { v[prev].1 = 0.5 }
            v.append((ColorStop(t, c), 0.5))
            if v.count > 1024 { throw EngineError.bad(cmd, "too many colour stops (max 1024)") }
        case "move":
            let i = try index(v.count, "colour stop")
            v[i].0.location = try location()
        case "delete":
            let i = try index(v.count, "colour stop")
            if v.count <= 2 { throw EngineError.bad(cmd, "a gradient keeps at least 2 colour stops") }
            v.remove(at: i)
        case "color":
            let i = try index(v.count, "colour stop")
            guard let c = p["color"].flatMap({ parseColor($0, fg, bg) }) else { throw EngineError.bad(cmd, "missing or bad `color`") }
            v[i].0.color = c
        case "midpoint":
            // Segment `i` runs from stop `i` to stop `i + 1`, so there is one fewer than stops.
            let i = try index(max(v.count - 1, 0), "segment")
            guard let mid = num(p, "location") else { throw EngineError.bad(cmd, "missing `location` (0..1 of the segment)") }
            v[i].1 = min(max(mid, 0.05), 0.95)
        default:
            throw EngineError.bad(cmd, "unknown action `\(action)` (add|move|delete|color|midpoint)")
        }
        (g.stops, g.midpoints) = unpair(v)
        return g
    }

    static func stopRun(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        let (fill, _) = try gradientOf(s, id, stop)
        let new = try applyStop(fill, p, s.tools.foreground, s.tools.background)
        if new != fill { try replaceFill(s, id, "Edit Gradient Fill", new) }
        return try describe(s, id)
    }

    /// photocraft `describe_fill`: a gradient fill layer's settings as JSON (`gradient.fill.get`).
    static func describeFill(_ g: GradientFill, _ frame: PixelRect) -> JSONValue {
        let (from, to) = handles(g.style, g.angle, g.scale, g.offset, frame)
        return [
            "style": .string(styleName(g.style)), "angle": .float(g.angle), "scale": .float(g.scale * 100),
            "offset": [.float(g.offset.x * 100), .float(g.offset.y * 100)], "reverse": .bool(g.reverse), "dither": .bool(g.dither),
            "align": .bool(g.align), "from": [.float(from.x), .float(from.y)], "to": [.float(to.x), .float(to.y)],
            "stops": .array(g.stops.map { [.float($0.location), .string(hex($0.color))] }),
            "transparency": .array(g.opacityStops.map { [.float($0.location), .float($0.opacity * 100)] }),
            "midpoints": .floats(g.midpoints),
        ]
    }

    static func describe(_ s: Session, _ id: LayerId) throws -> JSONValue {
        let (f, frame) = try gradientOf(s, id, get)
        return describeFill(f, frame).setting("layer", .id(id))
    }

    static func specs() -> [CommandSpec] {
        [
            CommandSpec(create, "Gradient (Live)",
                        params: ##"{"from":[x,y],"to":[x,y],"style":"linear|radial|angle|reflected|diamond"="linear","gradient":preset name?,"stops":[[t,"#rrggbb"|"foreground"|"background"],…]?,"transparency":[[t,0..100],…]? (default: the current gradient),"reverse":bool=false,"dither":bool=true,"opacity":0..100=100,"mode":"normal|multiply|…"="normal"} → {"layer":id}; a Gradient Fill layer above the active layer, masked by the selection"##,
                        module: m, enabled: Pre.hasDoc, run: createRun),
            CommandSpec(set, "Edit Gradient Fill",
                        params: ##"{"layer":id?,"from":[x,y]?,"to":[x,y]?,"style":"linear|radial|angle|reflected|diamond"?,"angle":deg?,"scale":%?,"offset":[x%,y%]?,"reverse":bool?,"dither":bool?,"align":bool?,"stops":[[t,"#rrggbb"|"#rrggbbaa"|[r,g,b,a]|"foreground"|"background"],…]?,"transparency":[[t,0..100],…]?,"midpoints":[0.05..0.95 per segment]?} → the gradient (see gradient.fill.get)"##,
                        module: m, enabled: hasGradientFill, run: setRun),
            CommandSpec(stop, "Edit Gradient Stop",
                        params: ##"{"layer":id?,"action":"add|move|delete|color|opacity|midpoint","kind":"color|opacity"="color","index":stop (midpoint: segment) number,"location":0..1 (midpoint: of the segment),"color":"#rrggbb"|[r,g,b,a]|"foreground"|"background" (add: default the colour there),"opacity":0..100} → the gradient"##,
                        module: m, enabled: hasGradientFill, run: stopRun),
            CommandSpec(get, "Gradient Fill Settings",
                        params: ##"{"layer":id?} → {"style","angle","scale":%,"offset":[%,%],"reverse","dither","align","from":[x,y],"to":[x,y],"stops":[[t,"#hex"]],"transparency":[[t,%]],"midpoints":[…]}"##,
                        module: m, journal: false, enabled: hasGradientFill) { s, p in try describe(s, try s.layerParam(p)) },
        ]
    }
}
