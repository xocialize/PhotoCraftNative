// Port of photocraft-engine (crates/engine/src/brush_cmds.rs, and commands.rs `paint.stroke`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Brush engine commands: the Brush/Pencil/Mixer Brush/Color Replacement tools, brush presets and
// the session brush (`tools.setBrush`). The UI's options bar and Brush Settings panel call these.
//
// Brushes are PCPaint `BrushSettings` serialised as camelCase JSON; any command taking a `"brush"`
// object deep-merges it onto the session brush, so partial objects work
// (`{"scattering": {"enabled": true}}`). Strokes are deterministic: the jitter seed is the `seed`
// param or a hash of the points, so a journaled command replays to identical pixels. The live
// (pointer-driven) stroke and its hand-over to the commit live in `BrushCommands+Live.swift`.

import Foundation
import PCDocument
import PCFoundation
import PCPaint
import PCRender

public enum BrushCommands: CommandModule {
    public static let name = "brush_cmds"
    static let m = "brush_cmds"

    // MARK: Module state (photocraft `ToolState::mixer`, `ToolState::brush_gesture`, `Session::live_commit`)

    /// The Mixer Brush's paint reservoir and pickup (session tool state).
    enum MixerKey: StateKey { static let defaultValue = MixerState() }

    /// A coalesced `tools.setBrush` gesture: its key and the brush it started from.
    struct Gesture: Sendable {
        var key: String
        var start: BrushSettings
    }

    enum GestureKey: StateKey { static let defaultValue: Gesture? = nil }

    // MARK: Small helpers

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    static func num(_ p: JSONValue, _ k: String) -> Float? { p[k]?.doubleValue.map { Float($0) } }

    static func flag(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { p[k]?.boolValue ?? d }

    /// Rust's `f32::clamp` (params are never NaN).
    static func clampF(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

    /// photocraft brush_cmds `color`: `[r,g,b(,a)]` or `"#rrggbb(aa)"`, else `d`.
    static func color(_ v: JSONValue?, _ d: SIMD4<Float>) -> SIMD4<Float> { v.flatMap(Params.color) ?? d }

    /// Rust's `eq_ignore_ascii_case`.
    static func eqi(_ a: String, _ b: String) -> Bool {
        let (x, y) = (Array(a.utf8), Array(b.utf8))
        guard x.count == y.count else { return false }
        func low(_ c: UInt8) -> UInt8 { (65...90).contains(c) ? c + 32 : c }
        for i in x.indices where low(x[i]) != low(y[i]) { return false }
        return true
    }

    /// Rust's `{:?}` of an `f32` (`1e38`, `10.01`, `-1.0`, `inf`), for messages naming a value.
    static func rustDebug(_ x: Float) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-inf" : "inf" }
        if x == 0 { return x.sign == .minus ? "-0.0" : "0.0" }
        let a = abs(x)
        var s = "\(a)"
        var exp = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp = Int(s[s.index(after: e)...]) ?? 0
            s = String(s[..<e])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = parts.first.map(String.init) ?? "0"
        let frac = parts.count > 1 ? String(parts[1]) : ""
        var digits = Array(intPart + frac)
        var point = intPart.count + exp
        while digits.count > 1 && digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.count > 1 && digits.last == "0" { digits.removeLast() }
        let sign = x < 0 ? "-" : ""
        if a < 1e-4 || a >= 1e16 {
            let mant = digits.count > 1 ? "\(digits[0]).\(String(digits.dropFirst()))" : String(digits)
            return "\(sign)\(mant)e\(point - 1)"
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + String(digits) }
        if point >= digits.count { return sign + String(digits) + String(repeating: "0", count: point - digits.count) + ".0" }
        return sign + String(digits[..<point]) + "." + String(digits[point...])
    }

    /// Rust's `{}` of a whole float constant (`5000`, `10`, `1000000`).
    static func rustDisplay(_ x: Double) -> String {
        if x.isFinite, x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        return "\(x)"
    }

    /// Saturating `f64 as i32` (Rust casts saturate; NaN becomes 0).
    static func i32(_ v: Double) -> Int32 {
        if v.isNaN { return 0 }
        if v <= Double(Int32.min) { return .min }
        if v >= Double(Int32.max) { return .max }
        return Int32(v)
    }

    /// One straight RGBA pixel (zero where a 1×1 read can't be formed).
    static func rgbaAt(_ s: Surface, _ x: Int32, _ y: Int32) -> SIMD4<Float> {
        guard x < .max, y < .max else { return .zero }
        return s.rgba(x: x, y: y)
    }

    // MARK: Points

    /// Largest stroke coordinate accepted (a few times the largest document side, 300 000 px).
    static let maxCoord: Double = 1_000_000

    /// Parse `points`: arrays `[x, y, pressure?, tiltX?, tiltY?, rotation?, timeMs?, wheel?]` or
    /// objects `{"x":…, "y":…, "pressure":…, "tiltX":…, …, "time":…}`.
    static func parsePoints(_ p: JSONValue, _ cmd: String) throws -> [StrokePoint] {
        guard let arr = p["points"]?.arrayValue else { throw bad(cmd, "missing `points`") }
        let pts: [StrokePoint] = arr.compactMap { v in
            switch v {
            case .array(let a):
                func g(_ i: Int) -> Double? { i < a.count ? a[i].doubleValue : nil }
                guard let x = g(0), let y = g(1) else { return nil }
                var sp = StrokePoint(x, y, Float(g(2) ?? 1))
                sp.tiltX = Float(g(3) ?? 0)
                sp.tiltY = Float(g(4) ?? 0)
                sp.rotation = Float(g(5) ?? 0)
                sp.time = g(6) ?? 0
                sp.wheel = Float(g(7) ?? 1)
                return sp
            case .object:
                return try? v.decode(as: StrokePoint.self)
            default:
                return nil
            }
        }
        if pts.isEmpty { throw bad(cmd, "`points` is empty") }
        try checkCoords(pts, cmd)
        return pts
    }

    /// A stroke runs dab by dab along its length: an absurd coordinate would mean billions of dabs.
    /// Shared by the painting and the retouch tools' `points` (#976).
    static func checkCoords(_ pts: [StrokePoint], _ cmd: String) throws {
        if pts.contains(where: { !(abs($0.x) <= maxCoord && abs($0.y) <= maxCoord) }) {
            throw bad(cmd, "point coordinates must be finite and within ±\(rustDisplay(maxCoord))")
        }
    }

    // MARK: Brush JSON

    /// Deep-merge `patch` into `base` (objects merge key by key; anything else replaces).
    static func merge(_ base: inout JSONValue, _ patch: JSONValue) {
        guard case .object(var b) = base, case .object(let p) = patch else {
            base = patch
            return
        }
        // A different variant of an externally tagged enum (`{"tile":…}` → `{"procedural":…}`)
        // replaces the old one instead of merging into a two-variant object.
        if b.count == 1 && p.count == 1 && b.keys.first != p.keys.first {
            base = patch
            return
        }
        for (k, v) in p {
            if case .object = v, var bv = b[k], case .object = bv {
                merge(&bv, v)
                b[k] = bv
            } else {
                b[k] = v
            }
        }
        base = .object(b)
    }

    /// serde reads an out-of-range `f32` as infinity; Swift's decoder refuses it. Numbers no
    /// `Float` can hold become the decoder's infinity spelling, so validation names the value.
    static func floatSafe(_ v: JSONValue) -> JSONValue {
        switch v {
        case .number(let n) where n.isFinite && abs(n) > Double(Float.greatestFiniteMagnitude):
            return .string(n > 0 ? "inf" : "-inf")
        case .array(let a): return .array(a.map(floatSafe))
        case .object(let o): return .object(o.mapValues(floatSafe))
        default: return v
        }
    }

    /// A short serde-like description of a decoding failure.
    static func describe(_ e: any Error) -> String {
        func path(_ c: [any CodingKey]) -> String {
            let p = c.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "" : " at `\(p)`"
        }
        guard let d = e as? DecodingError else { return "\(e)" }
        switch d {
        case .typeMismatch(let t, let c): return "invalid type, expected \(t)\(path(c.codingPath))"
        case .valueNotFound(let t, let c): return "invalid type: null, expected \(t)\(path(c.codingPath))"
        case .keyNotFound(let k, let c): return "missing field `\(k.stringValue)`\(path(c.codingPath))"
        case .dataCorrupted(let c): return "\(c.debugDescription)\(path(c.codingPath))"
        @unknown default: return "\(e)"
        }
    }

    static func brushJSON(_ b: BrushSettings) -> JSONValue { .encoded(b) }

    /// Apply a JSON brush patch onto a brush.
    static func mergeBrush(_ base: BrushSettings, _ patch: JSONValue, _ cmd: String) throws -> BrushSettings {
        // Bitmaps the patch doesn't touch (sampled tips, pattern tiles: up to megabytes of base64)
        // skip the JSON round trip, so a Brush Settings slider on an imported tip stays cheap.
        func touches(_ path: [String]) -> Bool {
            var v = patch
            for k in path {
                if let x = v[k] {
                    v = x
                } else {
                    // A non-object on the way replaces the whole section.
                    return v.objectValue == nil
                }
            }
            return true
        }
        var light = base
        var tip: TipShape?, dualTip: TipShape?, pattern: PCPaint.Pattern?
        if !touches(["tip"]) { tip = light.tip; light.tip = .round }
        if !touches(["dualBrush", "tip"]) { dualTip = light.dualBrush.tip; light.dualBrush.tip = .round }
        if !touches(["texture", "pattern"]) { pattern = light.texture.pattern; light.texture.pattern = .default }
        var v: JSONValue
        do { v = try JSONValue(encoding: light) } catch { throw bad(cmd, "\(error)") }
        merge(&v, patch)
        var out: BrushSettings
        do { out = try floatSafe(v).decode(as: BrushSettings.self) } catch { throw bad(cmd, "invalid brush: \(describe(error))") }
        if let tip { out.tip = tip }
        if let dualTip { out.dualBrush.tip = dualTip }
        if let pattern { out.texture.pattern = pattern }
        return out
    }

    /// Rejects brush sizes and Scatter amounts outside their documented ranges, before a brush is
    /// stored or painted with.
    static func validateBrush(_ brush: BrushSettings, _ cmd: String) throws {
        let max = maxBrushSize
        if !brush.size.isFinite || brush.size > max {
            throw bad(cmd, "brush size must be finite and at most \(rustDisplay(Double(max))) px")
        }
        if brush.dualBrush.enabled && (!brush.dualBrush.size.isFinite || brush.dualBrush.size > max) {
            throw bad(cmd, "dual brush size must be finite and at most \(rustDisplay(Double(max))) px")
        }
        // Scatter may exceed 1 (100 %) but not the 1000 % maximum: a huge amount pushed dab
        // centres to infinity (#977).
        let scatterMax = maxScatter
        func inRange(_ v: Float) -> Bool { v >= 0 && v <= scatterMax }
        let sc = brush.scattering.scatter.jitter
        if brush.scattering.enabled && !inRange(sc) {
            throw bad(cmd, "scatter amount \(rustDebug(sc)) is out of range: it must be between 0 and \(rustDisplay(Double(scatterMax))) (1000 %)")
        }
        let ds = brush.dualBrush.scatter
        if brush.dualBrush.enabled && !inRange(ds) {
            throw bad(cmd, "dual brush scatter amount \(rustDebug(ds)) is out of range: it must be between 0 and \(rustDisplay(Double(scatterMax))) (1000 %)")
        }
    }

    /// photocraft `Session::load_brush_tips`: a library preset's tips stay on disk until a stroke
    /// uses them. No preset store is attached to this engine, so only loaded tiles paint.
    static func loadBrushTips(_ b: BrushSettings) throws {
        func check(_ r: StoredTile) throws {
            if r.full == nil { throw EngineError.other("brush tip \(r.key) is not available: no preset store is attached") }
        }
        if case .stored(let r) = b.tip { try check(r) }
        if case .stored(let r) = b.dualBrush.tip { try check(r) }
        if case .stored(let r) = b.texture.pattern { try check(r) }
    }

    static func findPreset(_ s: Session, _ name: String, _ cmd: String) throws -> BrushPreset {
        guard let p = BrushPresets.find(s.tools.presets, name) else { throw bad(cmd, "no brush preset named `\(name)`") }
        return p
    }

    /// Resolve the brush for a stroke command: session brush ← `preset` ← `brush` ← legacy scalar
    /// params; colours from the session; seed from `seed` or the points.
    static func resolveBrush(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> BrushSettings {
        var b = s.tools.brush
        if let name = p["preset"]?.stringValue {
            b = try findPreset(s, name, cmd).brush.pickedOver(s.tools.brush)
        }
        if let patch = p["brush"], patch.objectValue != nil {
            b = try mergeBrush(b, patch, cmd)
        }
        // A library preset's tips stay on disk until a stroke uses them (#1843).
        do { try loadBrushTips(b) } catch { throw bad(cmd, EngineError.wrap(error).description) }
        if let v = num(p, "size") { b.size = max(v, 0.5) }
        if let v = num(p, "hardness") { b.hardness = clampF(v, 0, 1) }
        if let v = num(p, "opacity") { b.opacity = clampF(v, 0, 1) }
        if let v = num(p, "flow") { b.flow = clampF(v, 0, 1) }
        if let v = num(p, "spacing") { b.spacing = clampF(v, 0.01, 10) }
        if let v = num(p, "smoothing") { b.smoothing.amount = clampF(v, 0, 1) }
        b.color = color(p["color"], s.tools.foreground)
        b.background = s.tools.background
        b.erase = flag(p, "erase", false)
        if let seed = p["seed"]?.uint64Value {
            b.seed = seed
        } else {
            b.seed = PaintRNG.seed(fromBytes: Array((p["points"].map { $0.serialized() } ?? "").utf8))
        }
        try validateBrush(b, cmd)
        return b
    }

    /// The seeds a JSON number (a double) holds exactly: a live stroke derives its seed within
    /// them, so its commit's `"seed": live.seed` reproduces it.
    static let seedMask: UInt64 = (1 << 53) - 1

    static func layerId(_ s: Session, _ p: JSONValue) throws -> LayerId {
        if let id = p["layer"]?.uint64Value { return LayerId(id) }
        guard let id = s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return id
    }

    static func damageJSON(_ s: Session, _ dmg: PixelRect) -> JSONValue {
        s.noteDamage(dmg)
        return ["damage": .rect(dmg)]
    }

    /// The target layer (nil for a channel), brush and zoom of a stroke. On a mask or channel the
    /// eraser paints the background colour (Photoshop).
    static func strokeTarget(_ s: Session, _ p: JSONValue, _ brush: BrushSettings) throws -> (LayerId?, BrushSettings, Float) {
        let gray = LayerOps.isMaskTarget(p) || Channels.isChannelTarget(p)
        let id: LayerId? = Channels.isChannelTarget(p) ? nil : try layerId(s, p)
        var b = brush
        if gray && b.erase {
            b.erase = false
            b.color = s.tools.background
        }
        return (id, b, num(p, "zoom") ?? 1)
    }

    /// Erasing a layer with locked transparency (e.g. the Background) can't remove opacity, so it
    /// paints the background colour instead (Photoshop).
    static func eraseLocked(_ brush: inout BrushSettings, _ lock: Bool, _ bg: SIMD4<Float>) {
        if brush.erase && lock {
            brush.erase = false
            brush.color = bg
        }
    }

    /// Pencil Auto Erase: a stroke that starts on a pixel of the foreground colour paints the
    /// background colour instead (Photoshop).
    static func applyAutoErase(_ brush: inout BrushSettings, _ surf: Surface, _ start: StrokePoint?, _ fg: SIMD4<Float>, _ bg: SIMD4<Float>) {
        guard let p0 = start else { return }
        let c = rgbaAt(surf, i32(p0.x.rounded(.down)), i32(p0.y.rounded(.down)))
        if c.w > 0 && (0..<3).allSatisfy({ abs(c[$0] - fg[$0]) < 1.5 / 255 }) {
            brush.color = bg
        }
    }

    // MARK: Stroking

    /// Stroke with a resolved brush onto the target layer (pixels or mask).
    static func strokeWith(_ s: Session, _ cmd: String, _ p: JSONValue, _ label: String, _ brush0: BrushSettings, _ pts: [StrokePoint],
                           autoErase: Bool) throws -> JSONValue {
        let bg = s.tools.background
        let fg = brush0.color
        let symmetry = s.active.flatMap { $0.view[SymmetryCommands.Key.self] }
        let (id, brush1, zoom) = try strokeTarget(s, p, brush0)
        // The live stroke the canvas already rendered for exactly these params: take its pixels
        // instead of rendering the whole stroke again (the hitch at pen-up).
        let offered = s.state[LiveCommitKey.self]
        s.state[LiveCommitKey.self] = nil
        let live = offered.flatMap { $0.matches(s, cmd, p, pts) ? $0 : nil }
        let dmg: PixelRect = try s.edit(label) { doc, _ in
            if let l = live {
                try Channels.withTargetSurface(&doc, layer: id, p) { surf, _ in surf = l.surface }
                return l.bounds
            }
            let sel = doc.selection
            return try Channels.withTargetSurface(&doc, layer: id, p) { surf, lock -> PixelRect in
                var brush = brush1
                eraseLocked(&brush, lock, bg)
                if autoErase { applyAutoErase(&brush, surf, pts.first, fg, bg) }
                if let axis = symmetry {
                    let copies: [StrokeRenderer] = axis.reflectedPasses(pts)
                        .filter { SymmetryCommands.Axis.hasDistinctMirror(pts, $0) }
                        .map { q in
                            var r = StrokeRenderer(brush, format: surf.format, zoom: zoom)
                            r.push(q)
                            r.finish()
                            return r
                        }
                    if copies.isEmpty {
                        return renderStroke(&surf, brush, pts, selection: sel, lockTransparency: lock, zoom: zoom)
                    }
                    let pre = surf
                    var original = StrokeRenderer(brush, format: surf.format, zoom: zoom)
                    original.push(pts)
                    original.finish()
                    return original.compositeUnionMany(copies, pre: pre, target: &surf, selection: sel, lockTransparency: lock)
                }
                return renderStroke(&surf, brush, pts, selection: sel, lockTransparency: lock, zoom: zoom)
            }
        }
        var r = damageJSON(s, dmg)
        if live != nil { r = r.setting("fromLive", true) }
        return r
    }

    /// The Pencil's brush: the session brush made aliased (every pixel fully painted or untouched,
    /// dabs on the pixel grid), hard and at full flow, with the options-bar mode.
    static func pencilBrush(_ s: Session, _ p: JSONValue) throws -> BrushSettings {
        var brush = withBlendMode(try resolveBrush(s, p, "paint.pencil"), p)
        if flag(p, "block", false) { return try blockBrush(brush, p) }
        brush.aliased = true
        if num(p, "hardness") == nil { brush.hardness = 1 }
        if num(p, "flow") == nil { brush.flow = 1 }
        return brush
    }

    /// Edge of the Eraser's Block in screen pixels (Photoshop): constant on screen, so it covers
    /// `blockScreenPx / zoom` document pixels.
    static let blockScreenPx: Double = 16

    /// The Eraser's Block edge in document pixels at view `zoom`: `16 / zoom`, rounded to whole
    /// pixels (a zoom that is not a positive number counts as 100 %).
    static func blockSize(_ zoom0: Double) -> Float {
        let zoom = zoom0.isFinite && zoom0 > 0 ? zoom0 : 1
        return Float(min(max((blockScreenPx / zoom).rounded(), 1), Double(maxBrushSize)))
    }

    /// The Eraser's Block mode (`"block": true`): a hard, aliased square of `blockScreenPx` screen
    /// pixels at the stroke's `"zoom"`. Size, opacity, flow, hardness and the brush's dynamics don't
    /// apply (Photoshop); colour, erase, smoothing and the seed are the resolved brush's.
    static func blockBrush(_ b: BrushSettings, _ p: JSONValue) throws -> BrushSettings {
        let zoom: Double
        if let v = p["zoom"] {
            guard let z = v.doubleValue, z.isFinite, z > 0 else { throw bad("paint.pencil", "`zoom` must be a positive number") }
            zoom = z
        } else {
            zoom = 1
        }
        var out = BrushSettings()
        out.size = blockSize(zoom)
        out.aliased = true
        out.square = true
        out.pressureSize = false
        out.pressureOpacity = false
        out.spacing = 0.25
        out.color = b.color
        out.background = b.background
        out.erase = b.erase
        out.smoothing = b.smoothing
        out.seed = b.seed
        return out
    }

    /// Is the stroke in Photoshop's Clear painting mode (`"mode": "clear"`, #3439)? It erases with
    /// the Brush's or Pencil's own brush; unlike a blend mode it is not a layer mode.
    static func clearMode(_ p: JSONValue) -> Bool { p["mode"]?.stringValue.map { eqi($0, "clear") } ?? false }

    /// Applies the options-bar blend `mode` to a brush (`clear` erases with the brush). The Eraser
    /// has no blend mode in Photoshop, so it is forced to Normal.
    static func withBlendMode(_ b0: BrushSettings, _ p: JSONValue) -> BrushSettings {
        var b = b0
        b.erase = b.erase || clearMode(p)
        if b.erase {
            b.mode = .normal
        } else if let m = p["mode"]?.stringValue.flatMap(Params.blendMode) {
            b.mode = m
        }
        return b
    }

    /// `paint.stroke`: the Brush (and Eraser) tool.
    static func paintStroke(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pts = try parsePoints(p, "paint.stroke")
        let brush = withBlendMode(try resolveBrush(s, p, "paint.stroke"), p)
        let label = brush.erase && !clearMode(p) ? "Eraser" : "Brush Tool"
        return try strokeWith(s, "paint.stroke", p, label, brush, pts, autoErase: false)
    }

    static func pencil(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let pts = try parsePoints(p, "paint.pencil")
        let brush = try pencilBrush(s, p)
        let label = brush.erase && !clearMode(p) ? "Eraser" : "Pencil"
        return try strokeWith(s, "paint.pencil", p, label, brush, pts, autoErase: flag(p, "autoErase", false))
    }

    static func pct(_ p: JSONValue, _ k: String, _ d: Float) -> Float { clampF(num(p, k) ?? d, 0, 100) / 100 }

    static func mixerBrush(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.mixerBrush"
        let pts = try parsePoints(p, cmd)
        let brush = try resolveBrush(s, p, cmd)
        // The brush's Mixer Brush options, overridden by the scalar params.
        let bm = brush.mixer
        let mx = MixerSettings(wet: pct(p, "wet", bm.wet * 100), load: pct(p, "load", bm.load * 100), mix: pct(p, "mix", bm.mix * 100),
                               flow: pct(p, "flow", bm.flow * 100), sampleAllLayers: flag(p, "sampleAllLayers", bm.sampleAllLayers))
        let sampleAll = mx.sampleAllLayers
        let (clean, loadAfter) = (flag(p, "cleanAfterStroke", true), flag(p, "loadAfterStroke", true))
        var state = s.state[MixerKey.self]
        if loadAfter || state.reservoir == nil { state.load(color(p["color"], s.tools.foreground)) }
        let id: LayerId? = Channels.isChannelTarget(p) ? nil : try layerId(s, p)
        let stroke = Stroke(brush: brush, points: pts)
        let renderer = s.services.renderer
        let dmg: PixelRect = try s.edit("Mixer Brush") { doc, _ in
            let sel = doc.selection
            var sample: Surface?
            if sampleAll {
                let ds = dabs(stroke)
                let ctx = BrushContext(stroke.brush)
                let area = ds.reduce(PixelRect.empty) { $0.union(ctx.dabRect($1, dual: false)) }
                var surf = Surface(format: .rgba32f)
                if !area.isEmpty {
                    let buf = try renderer.render(doc, region: area)
                    var flat: [Float] = []
                    flat.reserveCapacity(buf.px.count * 4)
                    for q in buf.px { flat += [q.x, q.y, q.z, q.w] }
                    surf.writeRegion(area, flat)
                }
                sample = surf
            }
            return try Channels.withTargetSurface(&doc, layer: id, p) { surf, lock in
                MixerBrush.apply(&surf, sample: sample, stroke: stroke, settings: mx, state: &state, selection: sel, lockTransparency: lock)
            }
        }
        if clean { state.clean() }
        s.state[MixerKey.self] = state
        return damageJSON(s, dmg)
    }

    /// serde's reading of a unit-variant enum param, with its error text.
    static func enumParam<T: RawRepresentable & CaseIterable>(_ p: JSONValue, _ cmd: String, _ k: String, _ t: T.Type) throws -> T? where T.RawValue == String {
        guard let v = p[k] else { return nil }
        let expected = T.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")
        guard case .string(let s) = v else { throw bad(cmd, "`\(k)`: invalid type: \(v.serialized()), expected one of \(expected)") }
        guard let e = T(rawValue: s) else { throw bad(cmd, "`\(k)`: unknown variant `\(s)`, expected one of \(expected)") }
        return e
    }

    /// `paint.colorReplacement`'s stroke and settings. The replacement colour is the brush colour
    /// (the foreground unless `color` says otherwise). It paints layer pixels only: a mask, alpha
    /// channel or Quick Mask `target` is refused rather than recolouring the layer instead.
    static func colorReplacementSetup(_ s: Session, _ p: JSONValue) throws -> (Stroke, ReplaceSettings, LayerId) {
        let cmd = "paint.colorReplacement"
        if let t = p["target"], t.stringValue != "pixels" {
            throw bad(cmd, "Color Replacement paints layer pixels only (`target` \(t.serialized()) is not \"pixels\")")
        }
        let pts = try parsePoints(p, cmd)
        let brush = try resolveBrush(s, p, cmd)
        let rs = ReplaceSettings(mode: try enumParam(p, cmd, "mode", ReplaceMode.self) ?? .color,
                                 sampling: try enumParam(p, cmd, "sampling", Sampling.self) ?? .continuous,
                                 limits: try enumParam(p, cmd, "limits", Limits.self) ?? .contiguous,
                                 tolerance: pct(p, "tolerance", 30), antiAlias: flag(p, "antiAlias", true),
                                 color: brush.color, background: s.tools.background)
        let id = try layerId(s, p)
        return (Stroke(brush: brush, points: pts), rs, id)
    }

    static func colorReplacement(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let (stroke, rs, id) = try colorReplacementSetup(s, p)
        let dmg: PixelRect = try s.edit("Color Replacement") { doc, _ in
            let sel = doc.selection
            let lock = doc.effectiveLocks(id).transparency
            return try LayerOps.withPaintSurface(&doc, id, .object([:])) { surf in
                ColorReplacement.apply(&surf, stroke, rs, selection: sel, lockTransparency: lock)
            }
        }
        return damageJSON(s, dmg)
    }

    // MARK: Presets

    static func presetsList(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let full = flag(p, "full", false)
        let rows: [JSONValue] = s.tools.presets.map { pr in
            var v: [String: JSONValue] = [
                "name": .string(pr.name), "builtin": .bool(pr.builtin), "size": .float(pr.brush.size), "hardness": .float(pr.brush.hardness),
                "tip": .string({ if case .round = pr.brush.tip { return "round" } else { return "sampled" } }()),
            ]
            // Full settings embed the bitmaps (a tip that can't be loaded stays a reference).
            if full { v["brush"] = brushJSON(pr.brush) }
            return .object(v)
        }
        return ["presets": .array(rows)]
    }

    static func nameParam(_ p: JSONValue, _ cmd: String) throws -> String {
        guard let n = p["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { throw bad(cmd, "missing `name`") }
        return n
    }

    static func presetsChanged(_ s: Session) { s.tools.presetsRevision &+= 1 }

    /// Replace the preset of that name, or append it at the end of the list.
    static func upsert(_ s: Session, _ preset: BrushPreset) {
        if let i = s.tools.presets.firstIndex(where: { eqi($0.name, preset.name) }) {
            s.tools.presets[i] = preset
        } else {
            s.tools.presets.append(preset)
        }
        presetsChanged(s)
    }

    static func presetsSave(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.save"
        let name = try nameParam(p, cmd)
        let brush: BrushSettings
        if let patch = p["brush"], patch.objectValue != nil { brush = try mergeBrush(s.tools.brush, patch, cmd) } else { brush = s.tools.brush }
        upsert(s, BrushPreset(name: name, brush: brush, builtin: false, group: "", folder: []))
        // The saved brush is the current brush now (Photoshop selects the brush it just saved).
        s.tools.currentPreset = name
        return ["name": .string(name), "count": .int(s.tools.presets.count)]
    }

    static func presetsDelete(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.delete"
        let name = try nameParam(p, cmd)
        let before = s.tools.presets.count
        s.tools.presets.removeAll { eqi($0.name, name) }
        if s.tools.presets.count == before { throw bad(cmd, "no brush preset named `\(name)`") }
        if let c = s.tools.currentPreset, eqi(c, name) { s.tools.currentPreset = nil }
        presetsChanged(s)
        return ["count": .int(s.tools.presets.count)]
    }

    /// Overwrite an existing preset with the current brush (or the current brush plus a `brush`
    /// patch), in place. The preset defaults to the one the current brush was picked from. A
    /// built-in that is updated becomes the user's preset.
    static func presetsUpdate(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.update"
        let name: String
        if p.has("name") {
            name = try nameParam(p, cmd)
        } else {
            guard let c = s.tools.currentPreset else { throw bad(cmd, "the current brush was not picked from a preset") }
            name = c
        }
        let brush: BrushSettings
        if let patch = p["brush"], patch.objectValue != nil { brush = try mergeBrush(s.tools.brush, patch, cmd) } else { brush = s.tools.brush }
        guard let i = s.tools.presets.firstIndex(where: { eqi($0.name, name) }) else { throw bad(cmd, "no brush preset named `\(name)`") }
        s.tools.presets[i].brush = brush
        s.tools.presets[i].builtin = false
        let (n, g) = (s.tools.presets[i].name, s.tools.presets[i].group)
        presetsChanged(s)
        return ["name": .string(n), "group": .string(g)]
    }

    /// Mark a preset as the one the current brush was picked from (the UI names it).
    static func presetsSetCurrent(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.presets.setCurrent"
        let name = try nameParam(p, cmd)
        if !s.tools.presets.contains(where: { eqi($0.name, name) }) { throw bad(cmd, "no brush preset named `\(name)`") }
        s.tools.currentPreset = name
        return ["name": .string(name)]
    }

    static let hasSelectionAndPixels: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document" }
        if d.doc.selection == nil { return "no selection" }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return "no active layer" }
        if case .raster = l.content { return nil }
        return "active layer is not a pixel layer"
    }

    /// Largest sampled tip side (like Photoshop's 5000 px limit, kept smaller for preset size).
    static let maxTip: UInt32 = 2500

    static func defineFromSelection(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "brush.defineFromSelection"
        let name = try nameParam(p, cmd)
        guard let d = s.active else { throw EngineError.noDocument }
        guard let sel = d.doc.selection else { throw bad(cmd, "no selection") }
        guard let id = d.activeLayer else { throw EngineError.other("no active layer") }
        guard let surf = d.doc.layer(id)?.surface else { throw bad(cmd, "not a pixel layer") }
        let area = sel.contentBounds.intersect(d.doc.bounds)
        if area.isEmpty { throw bad(cmd, "the selection is empty") }
        // Paint amount = darkness × alpha × selection (black = full paint, like Photoshop).
        let (w, h) = (area.width, area.height)
        let px = surf.readRGBA(area)
        let sc = sel.channels
        let sv = sel.readRegion(area)
        var v = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let c = px[i]
            let l = Blend.lum(SIMD3(c.x, c.y, c.z))
            v[i] = clampF((1 - l) * c.w * sv[i * sc], 0, 1)
        }
        // Crop to the painted extent.
        var (x0, y0, x1, y1) = (w, h, 0, 0)
        for y in 0..<h {
            for x in 0..<w where v[y * w + x] > 1e-4 {
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
            }
        }
        if x1 <= x0 || y1 <= y0 { throw bad(cmd, "the selected pixels contain no paint (all white or transparent)") }
        let (tw, th) = (UInt32(x1 - x0), UInt32(y1 - y0))
        if max(tw, th) > maxTip { throw bad(cmd, "selection too large for a brush tip (\(tw)×\(th); max \(maxTip) px)") }
        var data: [Float] = []
        data.reserveCapacity(Int(tw) * Int(th))
        for y in y0..<y1 { data += v[(y * w + x0)..<(y * w + x1)] }
        var brush = BrushSettings()
        brush.tip = .sampled(GrayTile(width: tw, height: th, floats: data))
        brush.size = Float(max(tw, th))
        brush.spacing = 0.25
        brush.pressureSize = false
        upsert(s, BrushPreset(name: name, brush: brush, builtin: false, group: "", folder: []))
        s.tools.brush = brush
        s.tools.currentPreset = name
        return ["name": .string(name), "width": .int(Int(tw)), "height": .int(Int(th))]
    }

    // MARK: The session brush

    /// `tools.setBrush` (also the brush keys' implementation).
    static func setBrush(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "tools.setBrush"
        var b = s.tools.brush
        var picked: String?
        if let name = p["preset"]?.stringValue {
            b = try findPreset(s, name, cmd).brush.pickedOver(s.tools.brush)
            picked = name
        }
        let reset = flag(p, "reset", false)
        if reset { b = BrushSettings() }
        var patch = p.objectValue ?? [:]
        for k in ["preset", "reset", "coalesce"] { patch[k] = nil }
        if let inner = patch.removeValue(forKey: "brush") {
            let tmp = try mergeBrush(b, inner, cmd)
            // Before the second merge: a non-finite value would serialise differently there and be
            // reported as a type error instead of naming the value (#977).
            try validateBrush(tmp, cmd)
            b = tmp
        }
        b = try mergeBrush(b, .object(patch), cmd)
        try validateBrush(b, cmd)
        // The picked preset stays "the current brush" across later edits. Only once the brush is
        // accepted: a failed call leaves no state behind (a `reset` wins over a `preset`).
        if reset {
            s.tools.currentPreset = nil
        } else if let picked {
            s.tools.currentPreset = picked
        }
        // The tool's brush always paints with full tips.
        do { try loadBrushTips(b) } catch { throw bad(cmd, EngineError.wrap(error).description) }
        let before = s.tools.brush
        s.tools.brush = b
        // A coalesced gesture (one slider drag) journals as one call: remember the brush it started from.
        let key = p["coalesce"]?.stringValue.flatMap { p["preset"] == nil && p["reset"] == nil ? $0 : nil }
        func continuing(_ k: String) -> Bool {
            guard s.state[GestureKey.self]?.key == k, let last = s.journal.last else { return false }
            return last.id == cmd && last.params["coalesce"]?.stringValue == k
        }
        if let k = key {
            if !continuing(k) { s.state[GestureKey.self] = Gesture(key: k, start: before) }
        } else {
            s.state[GestureKey.self] = nil
        }
        return brushJSON(s.tools.brush)
    }

    /// The brush as JSON with the bitmaps that `skip` names replaced by placeholders: they can be
    /// megabytes of base64, and skipped ones are equal on both sides.
    static func lightJSON(_ b: BrushSettings, _ skip: (Bool, Bool, Bool)) -> JSONValue {
        var c = b
        if skip.0 { c.tip = .round }
        if skip.1 { c.dualBrush.tip = .round }
        if skip.2 { c.texture.pattern = .default }
        return brushJSON(c)
    }

    /// Fields of `new` that differ from `old`, nested objects diffed key by key: the minimal
    /// `tools.setBrush` `brush` patch that turns `old` into `new` (`{}` when nothing changed).
    static func brushPatch(_ old: BrushSettings, _ new: BrushSettings) -> JSONValue {
        let skip = (old.tip == new.tip, old.dualBrush.tip == new.dualBrush.tip, old.texture.pattern == new.texture.pattern)
        func diff(_ a: JSONValue, _ b: JSONValue) -> JSONValue? {
            if case .object(let ao) = a, case .object(let bo) = b {
                var out: [String: JSONValue] = [:]
                for (k, bv) in bo {
                    if let av = ao[k] {
                        if let d = diff(av, bv) { out[k] = d }
                    } else {
                        out[k] = bv
                    }
                }
                // (Spelled out: `JSONValue` is itself nil-literal-expressible as `null`.)
                if out.isEmpty { return Optional<JSONValue>.none }
                return .some(.object(out))
            }
            // Enums with payloads (tips, patterns) are replaced whole.
            return a != b ? .some(b) : Optional<JSONValue>.none
        }
        return diff(lightJSON(old, skip), lightJSON(new, skip)) ?? .object([:])
    }

    /// Journal hook: consecutive `tools.setBrush` calls with the same `coalesce` key (one drag in
    /// the options bar or the Brush Settings panel) are one journal entry, the patch from the brush
    /// before the gesture to the brush now. Returns true when the call was folded into the
    /// previous entry.
    static func coalesceJournal(_ s: Session, _ id: String, _ params: JSONValue) -> Bool {
        guard id == "tools.setBrush", let key = params["coalesce"]?.stringValue,
              let g = s.state[GestureKey.self], g.key == key, let last = s.journal.last,
              last.id == id, last.params["coalesce"]?.stringValue == key else { return false }
        s.journal[s.journal.count - 1].params = ["brush": brushPatch(g.start, s.tools.brush), "coalesce": .string(key)]
        return true
    }

    // MARK: Preconditions

    /// A layer that can be painted: pixels, or any layer with a mask (paint with `"target":"mask"`).
    static let hasPaintable: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        switch s.activeLayer() {
        case .failure(let e): return e.description
        case .success(let l):
            if case .raster = l.content { return nil }
            if l.mask != nil { return nil }
            return "active layer is \(l.content.article) \(l.content.kindName) layer without a mask"
        }
    }

    // MARK: Registration

    public static func register(into r: inout CommandRegistry) {
        r.hooks.coalesceJournal = { s, id, p in coalesceJournal(s, id, p) }
        // photocraft registers `paint.stroke` in commands.rs; its implementation is here.
        r.add(CommandSpec("paint.stroke", "Brush Stroke",
                          params: ##"{"points":[[x,y,pressure?,tiltX?,tiltY?,rotation?,timeMs?,wheel?],…],"brush":{…BrushSettings}?,"preset":name?,"size":0.5..5000 px?,"hardness":0..1?,"opacity":0..1?,"flow":0..1?,"spacing":0..10?,"color":"#rrggbb"?=foreground,"mode":"normal|multiply|screen|…|clear (erases with this brush)"="normal","erase":bool?,"smoothing":0..1?,"zoom":number=1,"seed":u64?,"target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target}"##,
                          module: "commands", enabled: hasPaintable, run: paintStroke))
        r.add([
            CommandSpec("paint.pencil", "Pencil",
                        params: ##"{"points":[[x,y,pressure?,tiltX?,tiltY?,rotation?,timeMs?,wheel?],…],"brush":{…}?,"preset":name?,"size":0.5..5000 px?,"opacity":0..1?,"color":"#rrggbb"?=foreground,"mode":"normal|multiply|screen|…|clear (erases with this brush)"="normal","erase":bool?,"block":bool=false (a hard 16×16 screen-px square, 16/zoom doc px; size, opacity, flow, hardness and dynamics ignored: the Eraser's Block mode),"zoom":view zoom=1,"autoErase":bool=false,"seed":u64?,"target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target}"##,
                        module: m, enabled: hasPaintable, run: pencil),
            CommandSpec("paint.mixerBrush", "Mixer Brush",
                        params: ##"{"points":[…],"brush":{…}?,"preset":name?,"size":0.5..5000 px?,"wet":0..100=brush.mixer.wet,"load":0..100=brush.mixer.load,"mix":0..100=brush.mixer.mix,"flow":0..100=brush.mixer.flow,"color":"#rrggbb"?=foreground,"sampleAllLayers":bool=brush.mixer.sampleAllLayers,"cleanAfterStroke":bool=true,"loadAfterStroke":bool=true,"seed":u64?}"##,
                        module: m, enabled: hasPaintable, run: mixerBrush),
            CommandSpec("paint.colorReplacement", "Color Replacement",
                        params: ##"{"points":[…],"brush":{…}?,"size":px?,"mode":"hue|saturation|color|luminosity"="color","sampling":"continuous|once|backgroundSwatch"="continuous","limits":"contiguous|discontiguous|findEdges"="contiguous","tolerance":0..100=30,"antiAlias":bool=true,"color":"#rrggbb"?=foreground,"target":"pixels"="pixels","seed":u64?}"##,
                        module: m, enabled: hasPaintable, run: colorReplacement),
            CommandSpec("brush.presets.list", "List Brush Presets", params: #"{"full":bool=false}"#, module: m, journal: false, run: presetsList),
            CommandSpec("brush.presets.save", "Save Brush Preset", params: #"{"name":string,"brush":{…BrushSettings}?=current brush}"#,
                        module: m, run: presetsSave),
            CommandSpec("brush.presets.update", "Update Brush Preset",
                        params: #"{"name":string?=the preset the current brush was picked from,"brush":{…BrushSettings}?=current brush}"#,
                        module: m, run: presetsUpdate),
            CommandSpec("brush.presets.delete", "Delete Brush Preset", params: #"{"name":string}"#, module: m, run: presetsDelete),
            CommandSpec("brush.presets.setCurrent", "Set Current Brush Preset", params: #"{"name":string}"#, module: m, run: presetsSetCurrent),
            CommandSpec("brush.defineFromSelection", "Define Brush Preset…", params: #"{"name":string}"#, module: m,
                        enabled: hasSelectionAndPixels, run: defineFromSelection),
            CommandSpec("brush.get", "Get Brush", params: "{}", module: m, journal: false) { s, _ in brushJSON(s.tools.brush) },
            CommandSpec("tools.setBrush", "Set Brush", params: #"{"preset":name?,"reset":bool?,…BrushSettings fields (camelCase, deep-merged)}"#,
                        module: m, run: setBrush),
        ])
    }
}
