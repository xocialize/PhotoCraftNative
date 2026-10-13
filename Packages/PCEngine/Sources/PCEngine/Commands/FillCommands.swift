// Port of photocraft-engine (crates/engine/src/fill_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Edit › Fill… (`edit.fill`): Photoshop's Fill dialog as one command. Contents: Foreground /
// Background / Color / Content-Aware / Pattern / History / Black / 50% Gray / White, blended with
// `mode` at `opacity`, optionally preserving the target's transparency. The selection (or the whole
// canvas) is filled, as one history step ("Fill"). Every parameter is validated: a bad one is an
// error, never a trap. The blending here is shared with Edit › Stroke, Paste into a mask or channel
// and Clear on a channel (`blendColorMask`, `compositeOver`, `fillColor`).
//
// photocraft registers `edit.fill` in its core table (commands.rs) and implements it here; this
// module registers it (module "commands", as photocraft's catalogue lists it).
//
// Content-Aware is photocraft-algo's PatchMatch through PCAlgo (`InpaintKit.fill`). Patterns
// resolve through pattern_cmds (the document's, then the session library).

import Dispatch
import Foundation
import PCAlgo
import PCDocument
import PCFoundation
import PCIntelligence
import PCRender
import Synchronization

enum FillCommands: CommandModule {
    static let name = "fill_cmds"
    static let cmd = "edit.fill"

    /// Every `contents` value, in the dialog's order.
    static let contentsKinds = ["foreground", "background", "color", "contentAware", "pattern", "history", "black", "gray", "white"]

    static let params = ##"{"contents":"foreground|background|color|contentAware|pattern|history|black|gray|white"="color","color":"#rrggbb|[r,g,b,a]"=foreground (contents=color),"pattern":id|name (contents=pattern),"scale":%=100,"angle":deg,"state":index? (contents=history; default the oldest state),"colorAdaptation":bool=true (contents=contentAware),"mode":"normal|multiply|…"="normal","opacity":0..100=100,"preserveTransparency":bool=false,"target":"pixels"|"mask"|"quickMask"|{"channel":i}?}"##

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec(cmd, "Fill…", menu: ["Edit"], shortcut: "Shift+F5", params: params, module: "commands",
                          enabled: CoreCommands.hasPixelOrChannel, run: fill))
    }

    static func bad(_ msg: String) -> EngineError { .bad(cmd, msg) }

    // MARK: Sources and blending

    /// What a pixel of the filled area gets before blending.
    enum Source: Sendable {
        case color(SIMD4<Float>)
        /// Straight RGBA per pixel of the rectangle (row-major).
        case pixels(PixelRect, [SIMD4<Float>])
    }

    /// How the source goes onto the target.
    struct BlendSpec: Sendable {
        var mode: BlendMode
        var opacity: Float
        /// Leave every pixel's alpha as it was (Preserve Transparency, or locked transparency).
        var keepAlpha: Bool
        /// Normal mode replaces the pixels, transparency included (History: back to that state).
        var restore: Bool
    }

    // MARK: Params

    /// The `contents` param; without one, `color` (the old `{"color": …}` form, foreground by default).
    static func contents(_ p: JSONValue) throws -> String {
        guard let v = p["contents"], v != .null else { return "color" }
        guard case .string(let c) = v else { throw bad("`contents` must be a string, not \(v.serialized())") }
        guard let k = contentsKinds.first(where: { $0.lowercased() == c.lowercased() }) else {
            throw bad("unknown contents `\(c)` (\(contentsKinds.joined(separator: "|")))")
        }
        return k
    }

    static func mode(_ p: JSONValue) throws -> BlendMode {
        guard let v = p["mode"], v != .null else { return .normal }
        guard case .string(let m) = v else { throw bad("`mode` must be a blend mode name, not \(v.serialized())") }
        guard let b = Params.blendMode(m), b != .passThrough else { throw bad("unknown blend mode `\(m)`") }
        return b
    }

    /// Opacity in percent (0–100) → 0…1.
    static func opacity(_ p: JSONValue) throws -> Float {
        guard let v = p["opacity"], v != .null else { return 1 }
        guard let o = v.doubleValue, o.isFinite else { throw bad("`opacity` must be a number 0..100, not \(v.serialized())") }
        return Float(min(max(o, 0), 100) / 100)
    }

    static func flag(_ p: JSONValue, _ k: String, _ d: Bool) throws -> Bool {
        guard let v = p[k], v != .null else { return d }
        guard case .bool(let b) = v else { throw bad("`\(k)` must be true or false, not \(v.serialized())") }
        return b
    }

    // MARK: Edit › Fill

    @Sendable static func fill(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let contents = try contents(p)
        let mode = try mode(p)
        let opacity = try opacity(p)
        let preserve = try flag(p, "preserveTransparency", false)
        let channel = Channels.isChannelTarget(p)
        let id: LayerId? = channel ? nil : try s.layerParam(p)
        guard let st = s.active else { throw EngineError.noDocument }
        let docBounds = st.doc.bounds
        let sel = st.doc.selection
        let area0 = sel?.contentBounds ?? docBounds
        var out: JSONValue = ["contents": .string(contents)]
        let restore = contents == "history"
        let source: Source
        switch contents {
        case "foreground": source = .color(s.tools.foreground)
        case "background": source = .color(s.tools.background)
        case "color": source = .color(Params.color(p, "color", s.tools.foreground))
        case "black": source = .color(SIMD4(0, 0, 0, 1))
        case "gray": source = .color(SIMD4(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 1))
        case "white": source = .color(SIMD4(repeating: 1))
        case "pattern":
            let pat = try resolvePattern(s, p)
            let (scale, angle, _, phase) = patternPlacement(p)
            guard pat.isPaintable else { throw bad("the pattern is empty or too large to paint") }
            let tile = PatternTile(id: pat.id, name: pat.name, width: Int(pat.width), height: Int(pat.height), straight: patternRGBA(pat))
            // Photoshop's Fill uses the canvas origin.
            let place = PatternPlacement(frame: .empty, link: false, phase: phase, scale: scale, angle: angle)
            out = out.setting("pattern", .string(pat.id))
            try checkArea(area0, "rendering Fill's pattern")
            source = .pixels(area0, renderPattern(tile, place, area0))
        case "history":
            var explicit: Int?
            if let v = p["state"], v != .null {
                guard let i = v.uint64Value, i <= UInt64(Int.max) else { throw bad("`state` must be a history state index, not \(v.serialized())") }
                explicit = Int(i)
            }
            let past = st.history.pastCount
            let sourceDoc: Document
            switch explicit {
            case let i? where i == past: sourceDoc = st.doc
            case let i?:
                guard let d = st.history.state(i) else { throw bad("no history state \(i) (0..=\(past))") }
                sourceDoc = d
            // The History Brush's default source: the oldest state still held.
            case nil: sourceDoc = st.history.state(0) ?? st.doc
            }
            let src: Surface
            do { src = try Channels.readTargetSurface(sourceDoc, layer: id, p) } catch {
                throw EngineError.other("the target did not exist (as pixels, a mask or a channel) in that history state")
            }
            try checkArea(area0, "reading Fill's history source")
            source = .pixels(area0, src.readRGBA(area0))
        case "contentAware":
            guard let sel else { throw EngineError.other("Content-Aware fill needs a selection") }
            if channel || LayerOps.isMaskTarget(p) { throw EngineError.other("Content-Aware fill works on layer pixels only") }
            let adapt = try flag(p, "colorAdaptation", true)
            guard let lid = id else { throw EngineError.other("no active layer") }
            guard let surf = st.doc.layer(lid)?.surface else { throw EngineError.other("Content-Aware fill needs a pixel layer") }
            source = try contentAware(surf, sel, docBounds, colorAdaptation: adapt, seed: p["seed"]?.uint64Value ?? 1)
        default:
            throw bad("unknown contents `\(contents)`")
        }
        try commitFill(s, area0, docBounds, id, p, source, BlendSpec(mode: mode, opacity: opacity, keepAlpha: preserve, restore: restore))
        return out
    }

    /// The "Fill" step: `source` blended into the target over the selection's area.
    static func commitFill(_ s: Session, _ area0: PixelRect, _ docBounds: PixelRect, _ id: LayerId?, _ p: JSONValue, _ source: Source,
                           _ b: BlendSpec) throws {
        let area = area0.intersect(docBounds)
        if area.isEmpty { return }
        try s.edit("Fill") { doc, _ in
            let sel = doc.selection
            try Channels.withTargetSurface(&doc, layer: id, p) { surf, lock in
                var spec = b
                spec.keepAlpha = b.keepAlpha || lock
                blendInto(&surf, area, source, sel, spec)
            }
        }
    }

    /// Most pixels a whole-area working buffer may hold (16 GiB of straight RGBA).
    static let maxWorkingPixels = 1 << 30

    /// photocraft `allocation::filled`'s refusal: an area too large to hold as straight RGBA is an
    /// error, never a trap.
    static func checkArea(_ area: PixelRect, _ purpose: String) throws {
        let (n, overflow) = area.width.multipliedReportingOverflow(by: area.height)
        if overflow || n > maxWorkingPixels {
            throw EngineError.other("not enough memory for \(purpose) (requested size overflowed); the document was not changed")
        }
    }

    // MARK: Patterns

    /// photocraft `pattern_cmds::resolve_param`: the document's patterns, then the session library.
    static func resolvePattern(_ s: Session, _ p: JSONValue) throws -> Pattern {
        try PatternCommands.resolveParam(s, "edit.fill", p)
    }

    /// photocraft `pattern_cmds::placement`: (scale fraction, angle, link, phase).
    static func patternPlacement(_ p: JSONValue) -> (Float, Float, Bool, SIMD2<Float>) {
        func num(_ k: String, _ d: Double) -> Float { Float(p[k]?.doubleValue ?? d) }
        var phase = SIMD2<Float>(0, 0)
        if let a = p["phase"]?.arrayValue {
            phase = SIMD2(Float(a.first?.doubleValue ?? 0), Float(a.count > 1 ? a[1].doubleValue ?? 0 : 0))
        }
        let scale = min(max(num("scale", 100) / 100, 0.01), 10)
        return (scale, num("angle", 0), p["link"]?.boolValue ?? true, phase)
    }

    /// The pattern's pixels as straight RGBA (photocraft `pattern_rgba` into an RGB document).
    static func patternRGBA(_ pat: Pattern) -> [SIMD4<Float>] { pat.surface.readRGBA(pat.rect) }

    /// photocraft `compose::pattern::render`.
    static func renderPattern(_ tile: PatternTile, _ place: PatternPlacement, _ rect: PixelRect) -> [SIMD4<Float>] {
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(rect.area)
        if rect.isEmpty { return out }
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let (u, v) = place.map(Double(x) + 0.5, Double(y) + 0.5)
                out.append(tile.sample(u, v))
            }
        }
        return out
    }

    // MARK: Content-Aware

    /// The sampling window of a Content-Aware fill of `sel`, validated as photocraft's
    /// `content_aware` validates it before running PatchMatch.
    /// photocraft `content_aware`: PatchMatch completion of the selected pixels from Photoshop's
    /// sampling window (PCAlgo `InpaintKit.fill`, on the layer's own channels).
    static func contentAware(_ surf: Surface, _ sel: Surface, _ canvas: PixelRect, colorAdaptation: Bool, seed: UInt64) throws -> Source {
        let window = try contentAwareWindow(sel, canvas: canvas)
        let fmt = surf.format
        let n = fmt.channels
        let (w, h) = try windowSize(window)
        let img = surf.readRegion(window)
        let cov = sel.coverage(window)
        let hole = cov.map { $0 > 0 }
        let opts = InpaintKit.FillOptions(colorAdaptation: InpaintKit.colorLevel(colorAdaptation ? "default" : "none"),
                                          rotations: InpaintKit.rotationLevel("none"), scale: false, mirror: false, seed: seed)
        if img.count != w * h * n { throw EngineError.other("could not read the layer pixels") }
        let filled = InpaintKit.fill(width: w, height: h, channels: n, image: img, hole: hole, source: [Bool](repeating: true, count: w * h), options: opts)
        return .pixels(window, PixelCodec.toRGBA(fmt, raw: filled))
    }

    static func contentAwareWindow(_ sel: Surface, canvas: PixelRect) throws -> PixelRect {
        let hole = sel.contentBounds.intersect(canvas)
        if hole.isEmpty { throw EngineError.other("the selection is outside the canvas") }
        let window = samplingWindow(hole, canvas)
        _ = try windowSize(window)
        // Every pixel of the window selected leaves nothing to sample from.
        var anyOutside = false
        for c in window.tiles where !anyOutside {
            let tr = c.rect.intersect(window)
            if tr.isEmpty { continue }
            if sel.coverage(tr).contains(where: { !($0 > 0) }) { anyOutside = true }
        }
        if !anyOutside { throw EngineError.other("Content-Aware fill needs pixels outside the selection to sample from") }
        return window
    }

    /// Photoshop's Content-Aware sampling window around the selection bounds `hole` (photocraft
    /// `sampling_window`): Edit › Fill, the workspace's Rectangular and Auto areas and the
    /// retouching tools all copy from within it.
    static func samplingWindow(_ hole: PixelRect, _ canvas: PixelRect) -> PixelRect {
        PCIntelligence.samplingWindow(hole: hole.intersect(canvas), canvas: canvas)
    }

    /// The size of a Content-Aware sampling window, or an error for a window too large to read and
    /// fill (#963).
    static func windowSize(_ window: PixelRect) throws -> (Int, Int) {
        let (w, h) = (window.width, window.height)
        if UInt64(w).multipliedReportingOverflow(by: UInt64(h)).overflow || UInt64(w) * UInt64(h) > 400_000_000 {
            throw EngineError.other("the selection is too large for Content-Aware fill")
        }
        return (w, h)
    }

    // MARK: Shared blending

    /// `src` over `surf` across `area` (Normal, 100 %), each pixel weighted by `limit` when given:
    /// a paste into a layer mask or channel, which keeps the pasted pixels' luminosity (#1035).
    static func compositeOver(_ surf: inout Surface, _ src: Surface, _ area: PixelRect, limit: Surface?) {
        if area.isEmpty { return }
        blendInto(&surf, area, .pixels(area, src.readRGBA(area)), limit, BlendSpec(mode: .normal, opacity: 1, keepAlpha: false, restore: false))
    }

    /// `area` of `surf` filled with an opaque `color` (Normal, 100 %), weighted by `sel` when given.
    static func fillColor(_ surf: inout Surface, _ area: PixelRect, _ color: SIMD4<Float>, _ sel: Surface?) {
        blendInto(&surf, area, .color(color), sel, BlendSpec(mode: .normal, opacity: 1, keepAlpha: false, restore: false))
    }

    /// Edit › Fill's compositing for Edit › Stroke: the stroke's band is a coverage mask.
    static func blendColorMask(_ surf: inout Surface, _ area: PixelRect, _ color: SIMD4<Float>, _ coverage: Surface, mode: BlendMode,
                               opacity: Float, preserveTransparency: Bool) {
        blendInto(&surf, area, .color(color), coverage, BlendSpec(mode: mode, opacity: opacity, keepAlpha: preserveTransparency, restore: false))
    }

    /// `d` moved towards `c` by `k`, in premultiplied space (straight RGBA in and out).
    @inline(__always) static func lerp(_ d: SIMD4<Float>, _ c: SIMD4<Float>, _ k: Float) -> SIMD4<Float> {
        let a = d.w * (1 - k) + c.w * k
        if a <= 0 { return .zero }
        let rgb = (SIMD3(d.x, d.y, d.z) * (d.w * (1 - k)) + SIMD3(c.x, c.y, c.z) * (c.w * k)) / a
        return SIMD4(rgb, a)
    }

    /// Blend `source` into `surf` over `area`: per pixel, the selection coverage times the opacity,
    /// in the blend mode. Tiles run in parallel; untouched tiles are not rewritten.
    static func blendInto(_ surf: inout Surface, _ area: PixelRect, _ source: Source, _ sel: Surface?, _ b: BlendSpec) {
        if area.isEmpty { return }
        let fmt = surf.format
        // An opaque colour in Normal mode at 100 % that may replace alpha, unmasked: one fill.
        if case .color(let c) = source, c.w >= 1, b.mode == .normal, b.opacity >= 1, !b.keepAlpha || !fmt.alpha, sel == nil {
            surf.fill(area, with: fmt.components(fromRGBA: c))
            return
        }
        let tiles = area.tiles
        let src = surf
        let results = Mutex<[(PixelRect, [Float])]>([])
        DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
            let tr = tiles[i].rect.intersect(area)
            if tr.isEmpty { return }
            let cov = sel?.coverage(tr)
            var raw = src.readRegion(tr)
            if blendTile(&raw, fmt, tr, source, cov, b) { results.withLock { $0.append((tr, raw)) } }
        }
        for (tr, out) in results.withLock({ $0 }) { surf.writeRegion(tr, out) }
    }

    /// Blends into one tile's pixels (`raw`, the pixels of `tr`); returns whether any changed.
    static func blendTile(_ raw: inout [Float], _ fmt: PixelFormat, _ tr: PixelRect, _ source: Source, _ cov: [Float]?, _ b: BlendSpec) -> Bool {
        let n = fmt.channels
        let blend: BlendMode = b.mode == .dissolve ? .normal : b.mode
        var solid: SIMD4<Float>?
        var pixRect = PixelRect.empty
        var pix: [SIMD4<Float>] = []
        switch source {
        case .color(let c): solid = c
        case .pixels(let r, let px): pixRect = r; pix = px
        }
        // An opaque colour at full coverage in Normal mode just replaces the colour (and the alpha
        // unless it is kept): copy its encoded samples.
        var opaque: [Float]?
        var keep = n
        if let c = solid, c.w >= 1, b.mode == .normal {
            opaque = fmt.components(fromRGBA: c)
            keep = b.keepAlpha && fmt.alpha ? n - 1 : n
        }
        let w = tr.width
        var changed = false
        raw.withUnsafeMutableBufferPointer { p in
            for i in 0..<tr.area {
                var k = (cov.map { i < $0.count ? $0[i] : 0 } ?? 1) * b.opacity
                if k <= 0 { continue }
                let o = i * n
                if o + n > p.count { break }
                if k >= 1, let enc = opaque {
                    for c in 0..<min(keep, enc.count) { p[o + c] = enc[c] }
                    changed = true
                    continue
                }
                let x = tr.x0 + Int32(i % w), y = tr.y0 + Int32(i / w)
                let d = PixelCodec.toRGBA(fmt, UnsafeBufferPointer(p), o)
                var c: SIMD4<Float>
                if let solid {
                    c = solid
                } else if pixRect.contains(x: x, y: y) {
                    let j = Int(y - pixRect.y0) * pixRect.width + Int(x - pixRect.x0)
                    c = j < pix.count ? pix[j] : .zero
                } else {
                    c = .zero
                }
                if b.mode == .dissolve {
                    // Dissolve: each pixel is either fully painted or untouched, with the coverage as odds.
                    k = ColorConvert.ditherNoise(x: x, y: y) < c.w * k ? 1 : 0
                    c.w = 1
                    if k <= 0 { continue }
                }
                var out = b.restore && blend == .normal ? lerp(d, c, k) : Blend.composite(blend, backdrop: d, source: c, opacity: k)
                if b.keepAlpha || !fmt.alpha { out.w = d.w }
                encode(fmt, out, p, o)
                changed = true
            }
        }
        return changed
    }

    /// Writes straight RGBA `c` as `fmt`'s samples at `o`.
    @inline(__always) static func encode(_ fmt: PixelFormat, _ c: SIMD4<Float>, _ p: UnsafeMutableBufferPointer<Float>, _ o: Int) {
        switch fmt.mode {
        case .rgb, .indexed, .multichannel:
            p[o] = c.x; p[o + 1] = c.y; p[o + 2] = c.z
            if fmt.alpha { p[o + 3] = c.w }
        default:
            let e = fmt.components(fromRGBA: c)
            for k in 0..<min(e.count, fmt.channels) { p[o + k] = e[k] }
        }
    }
}
