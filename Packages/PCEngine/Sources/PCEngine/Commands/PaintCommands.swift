// Port of photocraft-engine (crates/engine/src/paint_cmds.rs) with photocraft-algo paint.rs's `composite_area` (for `paint_gradient`) and presets/gradients.rs (the Gradient tool's stops), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Paint helpers: the Paint Bucket (a wand-style flood fill with the foreground colour or a
// pattern, optionally bounded by the visible composite) and the Gradient tool. Both write to the
// Channels-panel target (layer pixels, its mask, an alpha channel or the Quick Mask) through the
// selection, and are one history step each. The bucket is PCAlgo's `PaintBucket` (wand region via
// `Selection.wandRegion`); the gradient's t and stop sampling are PCAlgo's `GradientTool`.

import Dispatch
import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCRender
import Synchronization

enum PaintCommands: CommandModule {
    static let name = "paint_cmds"
    static let m = "paint_cmds"

    static func f(_ p: JSONValue, _ k: String, _ d: Float) -> Float { p[k]?.doubleValue.map { Float($0) } ?? d }
    static func b(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { p[k]?.boolValue ?? d }

    /// Saturating `f32 as i32`.
    static func i32(_ v: Float) -> Int32 { BrushCommands.i32(Double(v)) }

    // MARK: Compositing (photocraft-algo paint.rs)

    /// Composites `color(x, y)` over `area` of the surface with per-pixel coverage (`coverage(r)`
    /// gives a tile's coverage, row-major). Tiles with zero coverage are left untouched, so their
    /// copy-on-write storage survives (photocraft `composite_area`; PCAlgo's `GradientTool.paint`
    /// rewrites the whole area from one buffer instead, so the Gradient tool keeps this).
    static func compositeArea(_ s: inout Surface, _ area: PixelRect, _ mode: BlendMode, coverage: @Sendable (PixelRect) -> [Float],
                              color: @Sendable (Int32, Int32) -> SIMD4<Float>, lockTransparency: Bool) {
        if area.isEmpty { return }
        let fmt = s.format
        let n = fmt.channels
        let tiles = area.tiles.map { $0.rect.intersect(area) }.filter { !$0.isEmpty }
        let src = s
        let done = Mutex<[(PixelRect, [Float])]>([])
        DispatchQueue.concurrentPerform(iterations: tiles.count) { ti in
            let r = tiles[ti]
            let cov = coverage(r)
            guard cov.contains(where: { $0 > 0 }) else { return }
            var region = src.readRegion(r)
            let w = r.width
            for i in 0..<min(cov.count, r.area) {
                let k = cov[i]
                if !(k > 0) { continue }
                let (x, y) = (r.x0 + Int32(i % w), r.y0 + Int32(i / w))
                let d = region.withUnsafeBufferPointer { PixelCodec.toRGBA(fmt, $0, i * n) }
                var o = Blend.composite(mode, backdrop: d, source: color(x, y), opacity: k)
                if lockTransparency { o.w = d.w }
                let enc = fmt.components(fromRGBA: o)
                for c in 0..<min(n, enc.count) { region[i * n + c] = enc[c] }
            }
            done.withLock { $0.append((r, region)) }
        }
        for (r, region) in done.withLock({ $0 }) { s.writeRegion(r, region) }
    }

    /// Coverage of the selection over `r` (1 without one).
    static func selectionCoverage(_ sel: Surface?, _ r: PixelRect) -> [Float] {
        sel?.coverage(r) ?? [Float](repeating: 1, count: r.area)
    }

    // MARK: Gradient tool (photocraft-algo paint.rs)

    /// Gradient tool over `area` (the selection bounds or canvas).
    static func paintGradient(_ s: inout Surface, _ area: PixelRect, from: SIMD2<Float>, to: SIMD2<Float>, shape: GradientShape,
                              stops: [(Float, SIMD4<Float>)], reverse: Bool, opacity: Float, mode: BlendMode, dither: Bool, selection: Surface?,
                              lockTransparency: Bool) {
        compositeArea(&s, area, mode, coverage: { r in selectionCoverage(selection, r).map { opacity * $0 } }, color: { x, y in
            let t = GradientTool.t(shape, from: from, to: to, x: Float(x) + 0.5, y: Float(y) + 0.5)
            var c = GradientTool.sample(stops, reverse ? 1 - t : t)
            if dither {
                // One quantisation step of monochromatic noise breaks 8-bit banding without speckle.
                let n = (ColorConvert.ditherNoise(x: x, y: y) - 0.5) / 255
                c.x = min(max(c.x + n, 0), 1)
                c.y = min(max(c.y + n, 0), 1)
                c.z = min(max(c.z + n, 0), 1)
            }
            return c
        }, lockTransparency: lockTransparency)
    }

    // MARK: Gradient stops (photocraft presets/gradients.rs)

    enum StopColor: Sendable, Equatable { case foreground, background, rgb(SIMD3<Float>) }

    struct GradientPreset: Sendable {
        var name: String
        /// Colour stops `(location 0..1, colour)`, sorted by location.
        var stops: [(Float, StopColor)]
        /// Transparency stops `(location, opacity 0..1)`; empty = opaque.
        var opacity: [(Float, Float)] = []

        static func hex(_ s: String) -> SIMD3<Float> {
            let h = Array(s.drop { $0 == "#" }.utf8)
            func byte(_ i: Int) -> Float {
                guard i + 2 <= h.count, let v = UInt8(String(decoding: h[i..<i + 2], as: UTF8.self), radix: 16) else { return 0 }
                return Float(v) / 255
            }
            return SIMD3(byte(0), byte(2), byte(4))
        }

        init(name: String, stops: [(Float, StopColor)], opacity: [(Float, Float)] = []) {
            self.name = name; self.stops = stops; self.opacity = opacity
        }

        init(_ name: String, colors: [String]) {
            let n = max(colors.count, 2) - 1
            self.init(name: name, stops: colors.enumerated().map { (Float($0) / Float(n), .rgb(GradientPreset.hex($1))) })
        }

        static let foregroundToBackground = GradientPreset(name: "Foreground to Background", stops: [(0, .foreground), (1, .background)])

        /// The built-in Basics group (the rest of the Gradients panel belongs to the presets port).
        static let basics: [GradientPreset] = [
            foregroundToBackground,
            GradientPreset(name: "Foreground to Transparent", stops: [(0, .foreground), (1, .foreground)], opacity: [(0, 1), (1, 0)]),
            GradientPreset("Black, White", colors: ["#000000", "#ffffff"]),
        ]

        /// RGBA stops for painting: colour and transparency stops merged (see `applyOpacity`).
        func resolve(_ fg: SIMD4<Float>, _ bg: SIMD4<Float>) -> [(Float, SIMD4<Float>)] {
            func rgb(_ c: StopColor) -> SIMD4<Float> {
                switch c {
                case .foreground: SIMD4(fg.x, fg.y, fg.z, 1)
                case .background: SIMD4(bg.x, bg.y, bg.z, 1)
                case .rgb(let v): SIMD4(v.x, v.y, v.z, 1)
                }
            }
            var cs = stops.map { (min(max($0.0, 0), 1), rgb($0.1)) }
            cs = cs.enumerated().sorted { $0.element.0 < $1.element.0 || ($0.element.0 == $1.element.0 && $0.offset < $1.offset) }.map(\.element)
            if cs.isEmpty { cs = [(0, SIMD4(fg.x, fg.y, fg.z, 1)), (1, SIMD4(bg.x, bg.y, bg.z, 1))] }
            return PaintCommands.applyOpacity(cs, opacity)
        }

        /// Parse `{"stops":[[t,"#rrggbb"|"foreground"|"background"],…],"transparency":[[t,0..100],…]}`.
        static func fromParams(_ name: String, _ p: JSONValue, _ cmd: String) throws -> GradientPreset {
            guard let arr = p["stops"]?.arrayValue else { throw EngineError.bad(cmd, "missing `stops`") }
            var stops: [(Float, StopColor)] = []
            for (i, s) in arr.enumerated() {
                var t: Float?, c: String?
                switch s {
                case .array(let a) where a.count == 2:
                    t = a[0].doubleValue.map { Float($0) }
                    c = a[1].stringValue
                case .string(let str):
                    t = arr.count > 1 ? Float(i) / Float(arr.count - 1) : 0
                    c = str
                default: break
                }
                guard let t, let c else { throw EngineError.bad(cmd, ##"stops are [location, "#rrggbb"|"foreground"|"background"]"##) }
                let col: StopColor
                let h = String(c.drop { $0 == "#" })
                switch c {
                case "foreground": col = .foreground
                case "background": col = .background
                case _ where h.utf8.count == 6 && h.allSatisfy(\.isHexDigit) && h.allSatisfy(\.isASCII): col = .rgb(hex(c))
                default: throw EngineError.bad(cmd, "bad stop colour `\(c)`")
                }
                stops.append((min(max(t, 0), 1), col))
            }
            if stops.count < 2 { throw EngineError.bad(cmd, "a gradient needs at least 2 colour stops") }
            stops = stops.enumerated().sorted { $0.element.0 < $1.element.0 || ($0.element.0 == $1.element.0 && $0.offset < $1.offset) }.map(\.element)
            return try GradientPreset(name: name, stops: stops).withTransparency(p, cmd)
        }

        /// This gradient with its transparency stops replaced by explicit `"transparency"` stops.
        func withTransparency(_ p: JSONValue, _ cmd: String) throws -> GradientPreset {
            var g = self
            if let o = try PaintCommands.transparencyParam(p, cmd) { g.opacity = o }
            return g
        }
    }

    /// Piecewise-linear value of sorted `(t, v)` stops at `t` (clamped at the ends).
    static func sample<V>(_ stops: [(Float, V)], _ t: Float, _ mix: (V, V, Float) -> V) -> V? {
        guard let first = stops.first else { return nil }
        if t <= first.0 { return first.1 }
        if stops.count > 1 {
            for i in 0..<(stops.count - 1) {
                let ((t0, a), (t1, b)) = (stops[i], stops[i + 1])
                if t <= t1 { return mix(a, b, t1 > t0 ? (t - t0) / (t1 - t0) : 1) }
            }
        }
        return stops.last?.1
    }

    /// Sorted RGBA colour stops `cs` with transparency stops `(location, opacity 0..1)` multiplied
    /// into their alpha. Where both vary, extra samples keep the product close to per-pixel
    /// interpolation.
    static func applyOpacity(_ cs: [(Float, SIMD4<Float>)], _ opacity: [(Float, Float)]) -> [(Float, SIMD4<Float>)] {
        var os = opacity.map { (min(max($0.0, 0), 1), min(max($0.1, 0), 1)) }
        os = os.enumerated().sorted { $0.element.0 < $1.element.0 || ($0.element.0 == $1.element.0 && $0.offset < $1.offset) }.map(\.element)
        if os.isEmpty || os.allSatisfy({ abs($0.1 - 1) < 1e-6 }) { return cs }
        var ts = cs.map(\.0) + os.map(\.0) + [0, 1]
        ts.sort()
        var dedup: [Float] = []
        for t in ts where dedup.last.map({ abs(t - $0) >= 1e-6 }) ?? true { dedup.append(t) }
        var all: [Float] = []
        if dedup.count > 1 {
            for i in 0..<(dedup.count - 1) {
                for k in 0..<4 { all.append(dedup[i] + (dedup[i + 1] - dedup[i]) * Float(k) / 4) }
            }
        }
        all.append(1)
        return all.map { t in
            var c = sample(cs, t) { a, b, u in a + (b - a) * u } ?? .zero
            c.w *= sample(os, t) { a, b, u in a + (b - a) * u } ?? 1
            return (t, c)
        }
    }

    /// Explicit `"transparency":[[location 0..1, opacity 0..100], …]` as sorted `(location,
    /// opacity 0..1)` stops (`[]` = opaque); nil when `p` has none.
    static func transparencyParam(_ p: JSONValue, _ cmd: String) throws -> [(Float, Float)]? {
        guard let v = p["transparency"] else { return nil }
        guard let arr = v.arrayValue else { throw EngineError.bad(cmd, "`transparency` is [[location, opacity %], …]") }
        if arr.count > 1024 { throw EngineError.bad(cmd, "too many opacity stops (max 1024)") }
        var stops: [(Float, Float)] = []
        for s in arr {
            guard let pair = s.arrayValue, pair.count == 2 else { throw EngineError.bad(cmd, "an opacity stop is [location 0..1, opacity 0..100]") }
            func num(_ i: Int) -> Float? { pair[i].doubleValue.map { Float($0) }.flatMap { $0.isFinite ? $0 : nil } }
            guard let t = num(0), let o = num(1) else { throw EngineError.bad(cmd, "opacity stops are numbers") }
            stops.append((min(max(t, 0), 1), min(max(o / 100, 0), 1)))
        }
        stops = stops.enumerated().sorted { $0.element.0 < $1.element.0 || ($0.element.0 == $1.element.0 && $0.offset < $1.offset) }.map(\.element)
        return stops
    }

    /// Gradient for the Gradient tool: `"gradient": preset name`, else explicit `"stops"`, else
    /// the current gradient; explicit `"transparency"` stops replace its own. nil when the caller
    /// gave `colors` (the legacy evenly spaced form `paint.gradient` handles itself).
    static func toolStops(_ s: Session, _ p: JSONValue) throws -> [(Float, SIMD4<Float>)]? {
        // The Gradients panel (presets) owns the current gradient and the preset library.
        try PresetCommands.toolStops(s, p)
    }

    // MARK: Commands

    static func point(_ p: JSONValue, _ k: String) -> SIMD2<Float>? {
        guard let a = p[k]?.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
        return SIMD2(Float(x), Float(y))
    }

    /// A pattern for the Paint Bucket (photocraft pattern_cmds `resolve_param`): the active
    /// document's patterns by id or name. The session's pattern library belongs to the patterns
    /// port; a key it alone holds is reported as missing.
    static func resolvePattern(_ s: Session, _ cmd: String, _ p: JSONValue) throws -> PCDocument.Pattern {
        try PatternCommands.resolveParam(s, cmd, p)
    }

    /// photocraft pattern_cmds `placement`: (scale, angle, link, phase).
    static func placement(_ p: JSONValue) -> (Float, Float, Bool, SIMD2<Float>) {
        func num(_ k: String, _ d: Double) -> Float { Float(p[k]?.doubleValue ?? d) }
        var phase = SIMD2<Float>(0, 0)
        if let a = p["phase"]?.arrayValue {
            phase = SIMD2(Float(a.first?.doubleValue ?? 0), Float(a.count > 1 ? a[1].doubleValue ?? 0 : 0))
        }
        return (min(max(num("scale", 100) / 100, 0.01), 10), num("angle", 0), p["link"]?.boolValue ?? true, phase)
    }

    static func bucket(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let c = Params.color(p, "color", s.tools.foreground)
        let (x, y) = (i32(f(p, "x", 0).rounded(.down)), i32(f(p, "y", 0).rounded(.down)))
        let (tol, contiguous, aa, opacity) = (f(p, "tolerance", 32), b(p, "contiguous", true), b(p, "antiAlias", true), f(p, "opacity", 100) / 100)
        let all = b(p, "sampleAllLayers", false) && Channels.targetOf(p) == .pixels
        // Other visible layers can define the region, but the fill still writes only to the target.
        var region: SelectionRegion?
        if all {
            let (area, img) = try SelectionCommands.sampleRGBA8(s, allLayers: true)
            region = SelectionCommands.wandRegion(img, area, seed: (x, y), tolerance: tol, contiguous: contiguous, antiAlias: aa)
        }
        // Fill source: foreground colour (default) or a pattern (the Paint Bucket "Fill" dropdown).
        let source = p["contents"]?.stringValue ?? p["source"]?.stringValue ?? "foreground"
        var pattern: (PatternTile, PatternPlacement)?
        if source == "pattern" {
            let pat = try resolvePattern(s, "paint.bucket", p)
            guard pat.isPaintable else { throw EngineError.bad("paint.bucket", "the pattern is empty or too large to paint") }
            let tile = PatternTile(id: pat.id, name: pat.name, width: Int(pat.width), height: Int(pat.height), straight: pat.surface.readRGBA(pat.rect))
            let (scale, angle, _, phase) = placement(p)
            pattern = (tile, PatternPlacement(frame: .empty, link: false, phase: phase, scale: scale, angle: angle))
        }
        let filled: Bool = try s.edit("Paint Bucket") { doc, active in
            let area = doc.bounds
            let sel = doc.selection
            return try Channels.withTargetSurface(&doc, layer: active, p) { surf, lock -> Bool in
                let ok: Bool
                let src: @Sendable (Int32, Int32) -> SIMD4<Float>
                if let pt = pattern {
                    let (tile, place) = pt
                    // The pattern sampled at each filled pixel's centre.
                    src = { px, py in
                        let (u, v) = place.map(Double(px) + 0.5, Double(py) + 0.5)
                        return tile.sample(u, v)
                    }
                } else {
                    src = { _, _ in c }
                }
                if all && region == nil {
                    ok = false
                } else if let region {
                    PaintBucket.fill(&surf, region: region, opacity: opacity, selection: sel, lockTransparency: lock, source: src)
                    ok = true
                } else {
                    ok = PaintBucket.fill(&surf, area: area, seed: (x: x, y: y), tolerance: tol, contiguous: contiguous, antiAlias: aa,
                                          opacity: opacity, selection: sel, lockTransparency: lock, source: src)
                }
                surf.prune()
                return ok
            }
        }
        return ["filled": .bool(filled)]
    }

    static func gradient(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let from = point(p, "from") else { throw EngineError.bad("paint.gradient", "missing from") }
        guard let to = point(p, "to") else { throw EngineError.bad("paint.gradient", "missing to") }
        let shape = GradientShape(rawValue: p["style"]?.stringValue ?? "linear") ?? .linear
        let (fg, bg) = (s.tools.foreground, s.tools.background)
        // A preset (`gradient`), explicit `stops`, or the current gradient (Gradients panel); the
        // legacy `colors` list spaces its colours evenly. Explicit `transparency` applies to all.
        let stops: [(Float, SIMD4<Float>)]
        if let st = try toolStops(s, p) {
            stops = st
        } else {
            let colors = p["colors"]?.arrayValue.map { $0.map { BrushCommands.color($0, fg) } } ?? [fg, bg]
            let n = colors.count
            let cs = colors.enumerated().map { (n > 1 ? Float($0) / Float(n - 1) : 0, $1) }
            stops = applyOpacity(cs, try transparencyParam(p, "paint.gradient") ?? [])
        }
        let reverse = b(p, "reverse", false)
        let opacity = f(p, "opacity", 100) / 100
        let mode = p["mode"]?.stringValue.flatMap(Params.blendMode) ?? .normal
        let dither = b(p, "dither", true) // Photoshop dithers gradients by default (reduces banding).
        try s.edit("Gradient") { doc, active in
            let sel = doc.selection
            let sb = sel.map(\.contentBounds) ?? .empty
            let area = (sb.isEmpty ? doc.bounds : sb).intersect(doc.bounds)
            try Channels.withTargetSurface(&doc, layer: active, p) { surf, lock in
                paintGradient(&surf, area, from: from, to: to, shape: shape, stops: stops, reverse: reverse, opacity: opacity, mode: mode,
                              dither: dither, selection: sel, lockTransparency: lock)
            }
        }
        return .null
    }

    static func register(into r: inout CommandRegistry) {
        r.add([
            CommandSpec("paint.bucket", "Paint Bucket",
                        params: ##"{"x":px,"y":px,"tolerance":0..255=32,"contiguous":bool=true,"antiAlias":bool=true,"sampleAllLayers":bool=false,"contents":"foreground|pattern"="foreground","color":"#rrggbb"=foreground,"pattern":id|name (contents=pattern),"scale":%=100,"angle":deg,"opacity":1..100=100,"target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target}"##,
                        module: m, enabled: BrushCommands.hasPaintable, run: bucket),
            CommandSpec("paint.gradient", "Gradient",
                        params: ##"{"from":[x,y],"to":[x,y],"style":"linear|radial|angle|reflected|diamond"="linear","colors":["#rrggbb",…]? (evenly spaced),"gradient":preset name?,"stops":[[t,"#rrggbb"|"foreground"|"background"],…]?,"transparency":[[t,0..100],…]? (default: the current gradient, see gradient.presets.select),"reverse":bool=false,"dither":bool=true,"opacity":1..100=100,"mode":"normal|multiply|…"="normal","target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target}"##,
                        module: m, enabled: BrushCommands.hasPaintable, run: gradient),
        ])
    }
}
