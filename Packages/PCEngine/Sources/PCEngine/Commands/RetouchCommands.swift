// Port of photocraft-engine (crates/engine/src/retouch_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Retouching tools as commands: Clone Stamp, Pattern Stamp, Healing Brush, Spot Healing Brush,
// Patch, Content-Aware Move, Dodge, Burn, Sponge, Blur, Sharpen, Smudge and History Brush (Remove
// is registered by the PCIntelligence glue). Every command takes a Photoshop-style brush
// (`points`, `size`, `hardness`, `opacity`, `flow`, `spacing`, `layer`), respects the active
// selection as a mask and the layer's transparency lock, and works at any depth (8/16/32f) and
// colour model. Like the Brush, each paints the targeted surface: the layer's pixels, its mask
// (`"target":"mask"`), an alpha channel or the Quick Mask (`"target"`, filled in from the
// Channels panel when absent). The dab machinery is PCPaint's `Retouch`; the pixel kernels of
// photocraft-algo the tools need (`poisson`, `retouch`, `inpaint`, `content_aware`) are PCAlgo's,
// reached through `RetouchCommands.Kernels` and the Spot Healing / Content-Aware Move / Patch:
// Content-Aware code in RetouchCommands+ContentAware.swift; Patch and Pattern Stamp (photocraft's
// `retouch_cmds/` subfiles) are in RetouchCommands+Parts.swift.

import Foundation
import PCDocument
import PCFoundation
import PCPaint
import PCRender

enum RetouchCommands: CommandModule {
    static let name = "retouch_cmds"
    static let m = name

    /// photocraft `brush_cmds::MAX_COORD`: stroke points stay within ±1e6.
    static let maxCoord: Double = 1_000_000

    static func bad(_ cmd: String, _ msg: String) -> EngineError { .bad(cmd, msg) }

    /// A pixel layer, a layer with a mask, or a targeted alpha channel / Quick Mask (as the Brush).
    static let hasPixelLayer: CommandEnabled = { s, _ in
        if Channels.editsChannel(s) { return nil }
        guard let d = s.active else { return "no document open" }
        guard let id = d.activeLayer, let l = d.doc.layer(id) else { return "no active layer" }
        if case .raster = l.content { return nil }
        if l.mask != nil { return nil }
        return "active layer is \(l.content.article) \(l.content.kindName) layer, not a pixel layer"
    }

    /// The stroke paints layer pixels (not a mask or channel), so other layers can be sampled.
    static func targetsPixels(_ p: JSONValue) -> Bool { Channels.targetOf(p) == .pixels }

    static func num(_ p: JSONValue, _ k: String, _ d: Float) -> Float { p[k]?.doubleValue.map { Float($0) } ?? d }
    static func flag(_ p: JSONValue, _ k: String, _ d: Bool) -> Bool { p[k]?.boolValue ?? d }
    static func string(_ p: JSONValue, _ k: String, _ d: String) -> String { p[k]?.stringValue ?? d }
    static func point(_ p: JSONValue, _ k: String) -> SIMD2<Double>? {
        guard let a = p[k]?.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
        return SIMD2(x, y)
    }

    /// Rust `f32::clamp` (NaN stays NaN).
    static func clampR(_ v: Float, _ lo: Float, _ hi: Float) -> Float { v < lo ? lo : (v > hi ? hi : v) }

    // MARK: Brush

    /// The brush a retouching stroke paints with: the tool's brush (`base`, its tip, hardness and
    /// shape dynamics) with the shared params of `p` applied.
    static func strokeBrush(_ base: BrushSettings, _ p: JSONValue) -> BrushSettings {
        func pct(_ k: String, _ d: Float, _ lo: Float, _ hi: Float) -> Float { clampR(num(p, k, d), lo, hi) / 100 }
        var b = base
        b.size = Float.maximum(num(p, "size", base.size), 1)
        b.hardness = pct("hardness", base.hardness * 100, 0, 100)
        b.opacity = pct("opacity", 100, 1, 100)
        b.flow = pct("flow", 100, 1, 100)
        // Brush Settings › Brush Tip Shape › Spacing, as the Brush uses it (#2140).
        b.spacing = pct("spacing", base.spacing * 100, 1, 1000)
        b.erase = false
        return b
    }

    /// photocraft `brush_cmds::check_coords`.
    static func checkCoords(_ pts: [StrokePoint], _ cmd: String) throws {
        if pts.contains(where: { !(abs($0.x) <= maxCoord && abs($0.y) <= maxCoord) }) {
            throw bad(cmd, "point coordinates must be finite and within ±\(Int(maxCoord))")
        }
    }

    /// Rust's `{:?}` of an `f32` (`1.5`, `20.0`, `1e38`, `inf`).
    static func debugFloat(_ v: Float) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-inf" : "inf" }
        if v == v.rounded(), abs(v) < 1e16 { return "\(Int64(v)).0" }
        return "\(v)".replacingOccurrences(of: "e+", with: "e")
    }

    /// photocraft `brush_cmds::validate_brush`.
    static func validateBrush(_ b: BrushSettings, _ cmd: String) throws {
        let max = maxBrushSize
        if !b.size.isFinite || b.size > max { throw bad(cmd, "brush size must be finite and at most \(Int(max)) px") }
        if b.dualBrush.enabled && (!b.dualBrush.size.isFinite || b.dualBrush.size > max) {
            throw bad(cmd, "dual brush size must be finite and at most \(Int(max)) px")
        }
        let inRange = { (v: Float) in v >= 0 && v <= maxScatter }
        let sc = b.scattering.scatter.jitter
        if b.scattering.enabled && !inRange(sc) {
            throw bad(cmd, "scatter amount \(debugFloat(sc)) is out of range: it must be between 0 and \(Int(maxScatter)) (1000 %)")
        }
        let ds = b.dualBrush.scatter
        if b.dualBrush.enabled && !inRange(ds) {
            throw bad(cmd, "dual brush scatter amount \(debugFloat(ds)) is out of range: it must be between 0 and \(Int(maxScatter)) (1000 %)")
        }
    }

    /// Parse the shared brush params into a stroke on a layer (nil when an alpha channel or the
    /// Quick Mask is targeted).
    static func parseBrush(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> (Stroke, LayerId?) {
        guard let arr = p["points"]?.arrayValue else { throw bad(cmd, "missing `points`") }
        let pts: [StrokePoint] = arr.compactMap { v in
            guard let a = v.arrayValue, a.count >= 2, let x = a[0].doubleValue, let y = a[1].doubleValue else { return nil }
            let pressure = a.count > 2 ? (a[2].doubleValue ?? 1) : 1
            return StrokePoint(x, y, Float(pressure))
        }
        if pts.isEmpty { throw bad(cmd, "`points` is empty") }
        try checkCoords(pts, cmd)
        let brush = strokeBrush(s.tools.brush, p)
        try validateBrush(brush, cmd)
        if Channels.isChannelTarget(p) { return (Stroke(brush: brush, points: pts), nil) }
        guard let id = Params.layerId(p) ?? s.active?.activeLayer else { throw EngineError.other("no active layer") }
        return (Stroke(brush: brush, points: pts), id)
    }

    /// Run `f` on the targeted surface (layer pixels, layer mask, alpha channel or Quick Mask: the
    /// Brush's paint target) inside one undoable step. `f` gets the pre-stroke document, the
    /// surface, the selection and the transparency lock.
    static func runStroke(_ s: Session, _ label: String, _ id: LayerId?, _ p: JSONValue,
                          _ f: (Document, inout Surface, Surface?, Bool) throws -> PixelRect) throws -> PixelRect {
        let dmg = try s.edit(label) { doc, _ in
            let pre = doc
            // No prune: retouching only rewrites pixels inside the stroke.
            return try Channels.withTargetSurface(&doc, layer: id, p) { surf, lock in try f(pre, &surf, pre.selection, lock) }
        }
        s.noteDamage(dmg)
        return dmg
    }

    /// The live stroke offered for exactly this command, params and points (`LiveRetouchStroke.offer`), committed as
    /// one step: its pixels instead of running the stroke again. Nil when nothing matching was offered (an offer is
    /// withdrawn either way).
    static func runOffered(_ s: Session, _ cmd: String, _ label: String, _ id: LayerId?, _ p: JSONValue, _ stroke: Stroke) throws -> PixelRect? {
        guard let live = LiveRetouchStroke.take(s, cmd, p, stroke.points) else { return nil }
        let dmg = try s.edit(label) { doc, _ in
            try Channels.withTargetSurface(&doc, layer: id, p) { surf, _ in surf = live.surface }
            return live.bounds
        }
        s.noteDamage(dmg)
        return dmg
    }

    // MARK: Sampling sources

    /// Which pixels Clone Stamp / Healing Brush sample.
    enum SampleLayers { case current, currentAndBelow, all }

    static func sampleLayers(_ p: JSONValue, _ cmd: String) throws -> SampleLayers {
        switch string(p, "sampleLayer", "current") {
        case "current": return .current
        case "currentAndBelow": return .currentAndBelow
        case "all": return .all
        case let o: throw bad(cmd, "unknown sampleLayer `\(o)` (current|currentAndBelow|all)")
        }
    }

    /// Composite pixels of `rect` in `fmt` (native channels): the whole document, or the target
    /// layer and everything below it.
    static func compositeRegion(_ renderer: EngineRenderer, _ pre: Document, _ id: LayerId?, _ which: SampleLayers, _ rect: PixelRect,
                                _ fmt: PixelFormat) throws -> Region {
        var doc = pre
        if which == .currentAndBelow, let id {
            // Hide everything composited after (above) the target in the bottom-to-top walk.
            let walk = pre.walk()
            if let pos = walk.firstIndex(where: { $0.layer.id == id }) {
                for e in walk[(pos + 1)...] { _ = doc.updateLayer(at: e.path) { $0.visible = false } }
            }
        }
        let n = fmt.channels
        var out = Region(rect: rect, ch: n)
        if rect.isEmpty { return out }
        let buf = try renderer.render(doc, region: rect)
        var enc = [Float](repeating: 0, count: 8)
        enc.withUnsafeMutableBufferPointer { e in
            for (i, px) in buf.px.enumerated() where (i + 1) * n <= out.data.count {
                _ = fromRGBA(fmt, px, into: e.baseAddress!)
                for c in 0..<n { out.data[i * n + c] = e[c] }
            }
        }
        return out
    }

    /// What a stroke samples from: the target surface before the stroke, or the composite.
    struct Sampler {
        let renderer: EngineRenderer
        let pre: Document
        let id: LayerId?
        let surf: Surface
        let which: SampleLayers

        /// Pixels to sample at `rect` (document coordinates, already offset to the source).
        func sample(_ rect: PixelRect) throws -> Region {
            switch which {
            case .current: Region.read(surf, rect)
            default: try compositeRegion(renderer, pre, id, which, rect, surf.format)
            }
        }
    }

    /// Source pixels for destination `rect`: a translated read, or a bilinear resample when the
    /// clone source is scaled, rotated or flipped.
    static func cloneSample(_ sampler: Sampler, _ rect: PixelRect, _ map: CloneMapping, _ cmd: String) throws -> Region {
        if map.isTranslation {
            let off = map.offset
            let src = rect.offsetBy(dx: off.0, dy: off.1)
            // `offsetBy` saturates at the Int32 edges, so a far source (issue #1111) yields a window
            // smaller than `rect`; relabelling that as `rect` would index past the sampled pixels.
            if src.width != rect.width || src.height != rect.height {
                throw bad(cmd, "source offset [\(off.0), \(off.1)] is too far: the sample window leaves the coordinate range")
            }
            var r = try sampler.sample(src)
            r.rect = rect
            return r
        }
        let src = try sampler.sample(map.sourceRect(rect))
        return Retouch.resample(src, dst: rect, map: map, alpha: alphaIndex(sampler.surf.format))
    }

    /// Read-only clone overlay (the Clone Source panel's preview): shares the stroke sampler
    /// without anchoring a source or editing history. Both the destination and the transformed
    /// source are bounded for interactive use.
    static func clonePreview(_ s: Session, rect: PixelRect, map: CloneMapping, sampleLayer: String) throws -> RGBABuffer {
        let cmd = "clone.preview"
        let values = [map.source.x, map.source.y, map.anchor.x, map.anchor.y, map.m.x, map.m.y, map.m.z, map.m.w]
        guard values.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }) else { throw bad(cmd, "invalid preview mapping") }
        let inBudget = [rect.x0, rect.y0, rect.x1, rect.y1].allSatisfy { Int64($0).magnitude < 1_000_000 }
            && [(rect.x0, rect.y0), (rect.x1, rect.y1), (rect.x0, rect.y1), (rect.x1, rect.y0)].allSatisfy { c in
                let q = map.map(Double(c.0), Double(c.1))
                return q.x.isFinite && q.y.isFinite && abs(q.x) < 1_000_000 && abs(q.y) < 1_000_000
            }
        if !inBudget { throw bad(cmd, "preview coordinates exceed their budget") }
        let bounded = { (r: PixelRect) in r.width > 0 && r.height > 0 && r.width <= 1024 && r.height <= 1024 }
        if !bounded(rect) || !bounded(map.sourceRect(rect)) { throw bad(cmd, "preview region exceeds its budget") }
        guard let d = s.active else { throw EngineError.noDocument }
        guard let id = d.activeLayer else { throw bad(cmd, "no active layer") }
        guard let surf = d.doc.layer(id)?.surface else { throw bad(cmd, "no pixel surface") }
        let which = try sampleLayers(["sampleLayer": .string(sampleLayer)], cmd)
        let region = try cloneSample(Sampler(renderer: s.services.renderer, pre: d.doc, id: id, surf: surf, which: which), rect, map, cmd)
        let fmt = surf.format, n = fmt.channels
        let px: [SIMD4<Float>] = region.data.withUnsafeBufferPointer { b in
            (0..<rect.area).map { i in (i + 1) * n <= b.count ? toRGBA(fmt, b.baseAddress! + i * n) : .zero }
        }
        return RGBABuffer(rect: rect, px: px)
    }

    /// Result shared by Clone Stamp and Healing Brush: the offset used and where the next stroke
    /// should sample from if the UI keeps Photoshop's "Aligned" semantics.
    static func cloneResult(_ dmg: PixelRect, _ off: (Int32, Int32), _ aligned: Bool, _ p: JSONValue, _ stroke: Stroke) -> JSONValue {
        let f = stroke.points[0]
        let source = point(p, "source") ?? SIMD2(f.x + Double(off.0), f.y + Double(off.1))
        // Aligned: the offset persists (next stroke samples at its own first point + offset).
        // Non-aligned: every stroke restarts at the original source point.
        return ["damage": .rect(dmg), "offset": [.int(Int(off.0)), .int(Int(off.1))], "aligned": .bool(aligned),
                "nextSource": aligned ? .null : [.number(source.x), .number(source.y)]]
    }

    static func blendParam(_ p: JSONValue, _ cmd: String) throws -> BlendMode {
        guard let m = p["mode"]?.stringValue else { return .normal }
        guard let b = Params.blendMode(m) else { throw bad(cmd, "unknown blend mode `\(m)`") }
        return b
    }

    // MARK: Clone Stamp / Healing Brush / History Brush

    static func firstPoint(_ stroke: Stroke) -> SIMD2<Double> { SIMD2(stroke.points[0].x, stroke.points[0].y) }

    static func cloneStamp(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.cloneStamp"
        let (stroke, id) = try parseBrush(s, p, cmd)
        let which = try sampleLayers(p, cmd)
        let mode = try blendParam(p, cmd)
        let aligned = flag(p, "aligned", true)
        let map = try CloneSourceCommands.mapping(s, p, first: firstPoint(stroke), cmd)
        let off = map.offset
        if let dmg = try runOffered(s, cmd, "Clone Stamp", id, p, stroke) { return cloneResult(dmg, off, aligned, p, stroke).setting("fromLive", true) }
        let renderer = s.services.renderer
        let dmg = try runStroke(s, "Clone Stamp", id, p) { pre, surf, sel, lock in
            let (bounds, cov) = Retouch.strokeCoverage(stroke)
            // Samples come from the pre-stroke state, so pixels painted earlier in the stroke are never re-cloned.
            let paint = try cloneSample(Sampler(renderer: renderer, pre: pre, id: id, surf: surf, which: which), bounds, map, cmd)
            return Retouch.applyCoverage(&surf, rect: bounds, cov: cov, opacity: stroke.brush.opacity, selection: sel, lockTransparency: lock,
                                         paint: paint, blend: mode)
        }
        return cloneResult(dmg, off, aligned, p, stroke)
    }

    /// Seamless-clone `src` into `dst` over the mask (photocraft `heal_region`, with PCAlgo's
    /// Poisson solver).
    static func healRegion(_ fmt: PixelFormat, _ src: Region, _ dst: Region, _ mask: [Bool]) -> Region {
        Retouch.healRegion(fmt, src: src, dst: dst, mask: mask, solver: Kernels.seamlessClone)
    }

    static func healingBrush(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.healingBrush"
        let (stroke, id) = try parseBrush(s, p, cmd)
        let which = try sampleLayers(p, cmd)
        let mode = try blendParam(p, cmd)
        let aligned = flag(p, "aligned", true)
        let map = try CloneSourceCommands.mapping(s, p, first: firstPoint(stroke), cmd)
        let off = map.offset
        let renderer = s.services.renderer
        let dmg = try runStroke(s, "Healing Brush", id, p) { pre, surf, sel, lock in
            let (bounds, cov0) = Retouch.strokeCoverage(stroke)
            let (g, cov) = Retouch.padCoverage(bounds, cov0, 2)
            let fmt = surf.format
            let src = try cloneSample(Sampler(renderer: renderer, pre: pre, id: id, surf: surf, which: which), g, map, cmd)
            // The destination the texture is fitted to: the layer itself, or what the user sees when
            // sampling several layers (so healing onto an empty layer matches the composite).
            let dst = which == .current ? Region.read(surf, g) : try compositeRegion(renderer, pre, id, which, g, fmt)
            let healed = healRegion(fmt, src, dst, cov.map { $0 > 0 })
            return Retouch.applyCoverage(&surf, rect: g, cov: cov, opacity: stroke.brush.opacity, selection: sel, lockTransparency: lock,
                                         paint: healed, blend: mode)
        }
        return cloneResult(dmg, off, aligned, p, stroke)
    }

    /// The History Brush's source: the targeted surface (pixels, mask, channel) as it was in history
    /// state `state` (default: the oldest state still held, the "Open" snapshot unless trimmed).
    static func historySource(_ s: Session, _ id: LayerId?, _ p: JSONValue, _ cmd: String) throws -> Surface {
        guard let st = s.active else { throw EngineError.noDocument }
        let past = st.history.pastCount
        let source: Document
        if let v = p["state"]?.uint64Value {
            if v == UInt64(past) {
                source = st.doc
            } else {
                guard v < UInt64(past), let d = st.history.state(Int(v)) else { throw bad(cmd, "no history state \(v) (0..=\(past))") }
                source = d
            }
        } else {
            source = st.history.state(0) ?? st.doc
        }
        do { return try Channels.readTargetSurface(source, layer: id, p) } catch {
            throw EngineError.other("the target did not exist (as pixels, a mask or a channel) in that history state")
        }
    }

    static func historyBrush(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let cmd = "paint.historyBrush"
        let (stroke, id) = try parseBrush(s, p, cmd)
        let mode = try blendParam(p, cmd)
        let srcSurface = try historySource(s, id, p, cmd)
        let dmg = try runStroke(s, "History Brush", id, p) { _, surf, sel, lock in
            let fmt = surf.format
            let (bounds, cov) = Retouch.strokeCoverage(stroke)
            let paint = Region.read(srcSurface.format == fmt ? srcSurface : srcSurface.convertedAny(to: fmt), bounds)
            return Retouch.applyCoverage(&surf, rect: bounds, cov: cov, opacity: stroke.brush.opacity, selection: sel, lockTransparency: lock,
                                         paint: paint, blend: mode)
        }
        return ["damage": .rect(dmg)]
    }

    // MARK: Toning (Dodge / Burn / Sponge), focus (Blur / Sharpen), Smudge

    /// One dab's edit of the working copy.
    typealias DabEffect = (inout Region, Footprint) -> Void

    /// Per-dab strength such that one pass over a point totals roughly `e`, whatever the spacing.
    @inline(__always)
    static func perDab(_ e: Float, _ spacing: Float) -> Float {
        1 - pow(1 - min(max(e, 0), 1), min(max(spacing, 0.01), 1))
    }

    /// Apply an RGB colour transform `f(rgb, strength)` to each covered pixel of a dab (through
    /// straight RGBA, so it works for Gray/CMYK/Lab too; untouched pixels are never round-tripped).
    static func colorDab(_ fmt: PixelFormat, _ work: inout Region, _ fp: Footprint, _ strength: Float, _ spacing: Float,
                         _ f: (SIMD3<Float>, Float) -> SIMD3<Float>) {
        let r = fp.rect.intersect(work.rect)
        if r.isEmpty { return }
        let n = fmt.channels, a = alphaIndex(fmt)
        var enc = [Float](repeating: 0, count: 8)
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                let k = perDab(fp.at(x, y) * strength, spacing)
                if k <= 0 { continue }
                work.withPixel(x, y) { px in
                    let rgba = toRGBA(fmt, UnsafePointer(px.baseAddress!))
                    let o = f(SIMD3(rgba.x, rgba.y, rgba.z), k)
                    enc.withUnsafeMutableBufferPointer { e in
                        _ = fromRGBA(fmt, SIMD4(o, rgba.w), into: e.baseAddress!)
                        for c in 0..<n where c != a { px[c] = e[c] }
                    }
                }
            }
        }
    }

    /// Dodge and Burn: a stroke tones each pixel once, from its original colour, mixed in by the
    /// stroke's coverage there (`toned` is the full-exposure colour). Dabs build up coverage as in
    /// a brush stroke, capped at full coverage, so overlapping dabs and passes within one stroke
    /// don't compound the tone curve, and a new stroke builds on the last.
    static func toneStroke(_ fmt: PixelFormat, _ toned: @escaping (SIMD3<Float>) -> SIMD3<Float>) -> DabEffect {
        /// Side of the cells that remember, per touched pixel, the coverage applied so far and the
        /// original pixel (copied from the working pixels the first time a dab reaches it).
        let cell: Int32 = 64
        final class Cell {
            /// -1: not touched yet, so `orig` isn't filled in for that pixel.
            var cov: [Float]
            var orig: [Float]
            init(len: Int, n: Int) { cov = [Float](repeating: -1, count: len); orig = [Float](repeating: 0, count: len * n) }
        }
        var cells: [SIMD2<Int32>: Cell] = [:]
        let a = alphaIndex(fmt), n = fmt.channels
        var enc = [Float](repeating: 0, count: 8)
        return { work, fp in
            let r = fp.rect.intersect(work.rect)
            if r.isEmpty { return }
            func divE(_ v: Int32) -> Int32 { v >= 0 ? v / cell : -((-v + cell - 1) / cell) }
            for cy in divE(r.y0)...divE(r.y1 - 1) {
                for cx in divE(r.x0)...divE(r.x1 - 1) {
                    let cr = PixelRect(x0: cx &* cell, y0: cy &* cell, x1: cx &* cell &+ cell, y1: cy &* cell &+ cell)
                    let part = r.intersect(cr)
                    if part.isEmpty { continue }
                    let key = SIMD2(cx, cy)
                    let c: Cell
                    if let e = cells[key] { c = e } else {
                        c = Cell(len: Int(cell * cell), n: n)
                        cells[key] = c
                    }
                    for y in part.y0..<part.y1 {
                        for x in part.x0..<part.x1 {
                            let k = min(max(fp.at(x, y), 0), 1)
                            if k <= 0 { continue }
                            let i = Int((y - cr.y0) * cell + (x - cr.x0))
                            var prev = c.cov[i]
                            if prev < 0 {
                                // First touch: the working pixel is still the original.
                                let src = work.px(x, y)
                                for (j, v) in src.enumerated() { c.orig[i * n + j] = v }
                                prev = 0
                                c.cov[i] = 0
                            }
                            // Dabs build up the stroke's coverage as a brush stroke's do (flow), up
                            // to full coverage; the tone is applied once, from the original.
                            let k2 = prev + k * (1 - prev)
                            if k2 <= prev { continue }
                            c.cov[i] = k2
                            let o = c.orig.withUnsafeBufferPointer { toRGBA(fmt, $0.baseAddress! + i * n) }
                            let rgb = SIMD3(o.x, o.y, o.z)
                            let mixed = rgb + (toned(rgb) - rgb) * k2
                            enc.withUnsafeMutableBufferPointer { e in
                                _ = fromRGBA(fmt, SIMD4(mixed, o.w), into: e.baseAddress!)
                                work.withPixel(x, y) { px in for ch in 0..<n where ch != a { px[ch] = e[ch] } }
                            }
                        }
                    }
                }
            }
        }
    }

    static func toneRange(_ p: JSONValue, _ cmd: String) throws -> ToneRange {
        switch string(p, "range", "midtones") {
        case "shadows": return .shadows
        case "midtones": return .midtones
        case "highlights": return .highlights
        case let o: throw bad(cmd, "unknown range `\(o)` (shadows|midtones|highlights)")
        }
    }

    /// A sequential-dab tool's settings (Dodge, Burn, Sponge, Blur, Sharpen, Smudge), parsed once
    /// and turned into its per-dab effect.
    enum DabTool {
        case tone(burn: Bool, range: ToneRange, exposure: Float, protect: Bool)
        case sponge(saturate: Bool, vibrance: Bool)
        case focus(sharpen: Bool, strength: Float, protect: Bool, sigma: Float)
        case smudge(strength: Float, finger: SIMD4<Float>?, maxSize: Float)

        /// The tool for `cmd` and its history label.
        static func parse(_ s: Session, _ cmd: String, _ p: JSONValue, _ stroke: Stroke) throws -> (DabTool, String) {
            switch cmd {
            case "paint.dodge", "paint.burn":
                let burn = cmd == "paint.burn"
                let tool = DabTool.tone(burn: burn, range: try toneRange(p, cmd), exposure: clampR(num(p, "exposure", 50), 1, 100) / 100,
                                        protect: flag(p, "protectTones", true))
                return (tool, burn ? "Burn Tool" : "Dodge Tool")
            case "paint.sponge":
                let saturate: Bool
                switch string(p, "mode", "desaturate") {
                case "desaturate": saturate = false
                case "saturate": saturate = true
                case let o: throw bad(cmd, "unknown mode `\(o)` (desaturate|saturate)")
                }
                return (.sponge(saturate: saturate, vibrance: flag(p, "vibrance", true)), "Sponge Tool")
            case "paint.blur", "paint.sharpen":
                let sharpen = cmd == "paint.sharpen"
                // Radius: the Gaussian's σ. Without one, Blur's follows the brush and Sharpen's unsharp mask is 1 px.
                let sigma = try focusRadius(p, cmd) ?? (sharpen ? 1 : clampR(stroke.brush.size * 0.03, 1, 4))
                let tool = DabTool.focus(sharpen: sharpen, strength: clampR(num(p, "strength", 50), 1, 100) / 100, protect: flag(p, "protectDetail", true),
                                         sigma: sigma)
                return (tool, sharpen ? "Sharpen Tool" : "Blur Tool")
            case "paint.smudge":
                let finger = flag(p, "fingerPainting", false) ? s.tools.foreground : nil
                return (.smudge(strength: clampR(num(p, "strength", 50), 1, 100) / 100, finger: finger, maxSize: stroke.brush.size), "Smudge Tool")
            default:
                throw bad(cmd, "not a sequential-dab tool")
            }
        }

        /// Blur's and Sharpen's optional `"radius"`, in pixels (the Gaussian's σ), 0.1…100; nil when
        /// it's absent.
        static func focusRadius(_ p: JSONValue, _ cmd: String) throws -> Float? {
            guard let v = p["radius"], v != .null else { return nil }
            guard let r = v.doubleValue, r.isFinite, r > 0 else { throw bad(cmd, "`radius` must be a number of pixels above 0 (0.1..100)") }
            return Float(min(max(r, 0.1), 100))
        }

        /// How far around each dab the effect reads: Blur and Sharpen read a neighbourhood, and Smudge picks up
        /// as far as its carried colour reaches (its radius), so what it picks up never depends on where the
        /// working copy ends, and a live stroke's growing copy gives the same pixels (AB-T-0299).
        var halo: Int32 {
            switch self {
            case .focus(_, _, _, let sigma): Int32((sigma * 3).rounded(.up)) + 1
            case .smudge(_, _, let maxSize): Int32((maxSize / 2).rounded(.up)) + 2
            default: 0
            }
        }

        /// Smudge's state at the start of a stroke in `fmt` (nil for the other tools).
        func smudgeState(_ fmt: PixelFormat) -> Smudge? {
            guard case let .smudge(strength, finger, maxSize) = self else { return nil }
            // Premultiplied mixing: transparent pixels carry no colour, so no dark fringes.
            return Smudge(strength: strength, finger: finger.map { fromRGBA(fmt, $0) }, maxBrushSize: maxSize).withAlpha(alphaIndex(fmt))
        }

        var samplesAllLayers: Bool {
            switch self {
            case .focus, .smudge: true
            default: false
            }
        }

        /// The per-dab effect on a working copy in `fmt`, for a brush of `spacing`.
        func effect(_ fmt: PixelFormat, _ spacing: Float) -> DabEffect {
            let sp = spacing
            switch self {
            case let .tone(burn, range, exposure, protect):
                return toneStroke(fmt) { Kernels.dodgeBurn($0, exposure, range, burn, protect) }
            case let .sponge(saturate, vibrance):
                // Flow is already in each dab's coverage; a full-flow pass moves colours half-way.
                return { work, fp in colorDab(fmt, &work, fp, 0.5, sp) { Kernels.sponge($0, $1, saturate, vibrance) } }
            case let .focus(sharpen, strength, protect, sigma):
                let a = alphaIndex(fmt)
                return { work, fp in
                    let r = fp.rect.intersect(work.rect)
                    if r.isEmpty { return }
                    let (w, h, n) = (work.width, work.height, work.ch)
                    let win = (Int(r.x0 - work.rect.x0), Int(r.y0 - work.rect.y0), Int(r.x1 - work.rect.x0), Int(r.y1 - work.rect.y0))
                    let out = sharpen ? Kernels.localSharpen(work.data, w, h, n, a, win, 1, protect, sigma: sigma)
                                      : Kernels.localBlur(work.data, w, h, n, a, win, sigma)
                    let rw = r.width
                    for y in r.y0..<r.y1 {
                        for x in r.x0..<r.x1 {
                            let k = perDab(fp.at(x, y) * strength, sp)
                            if k <= 0 { continue }
                            let o = (Int(y - r.y0) * rw + Int(x - r.x0)) * n
                            work.withPixel(x, y) { px in for c in 0..<n { px[c] += (out[o + c] - px[c]) * k } }
                        }
                    }
                }
            case .smudge:
                var sm = smudgeState(fmt)!
                return { work, fp in sm.dab(&work, fp) }
            }
        }
    }

    /// "Sample All Layers" for Spot Healing, Blur, Sharpen and Smudge (layer pixels only: a mask
    /// or channel has nothing to sample from other layers).
    static func sampleAllLayers(_ p: JSONValue) -> Bool { flag(p, "sampleAllLayers", false) && targetsPixels(p) }

    /// Sample All Layers for the sequential-dab tools: each dab's effect runs on a copy of the
    /// visible composite (kept across dabs, so a dab sees the earlier ones), and the result is laid
    /// onto the layer under the dab.
    struct AllLayers {
        let renderer: EngineRenderer
        let pre: Document
        let fmt: PixelFormat
        var visible: Region?
        /// A composite that failed (the stroke is then refused).
        var failure: (any Error)?

        mutating func dab(_ work: inout Region, _ fp: Footprint, _ effect: DabEffect) {
            if visible == nil && failure == nil {
                do { visible = try compositeRegion(renderer, pre, nil, .all, work.rect, fmt) } catch { failure = error }
            }
            guard var v = visible, v.rect == work.rect, v.ch == work.ch else {
                effect(&work, fp)
                return
            }
            visible = nil
            effect(&v, fp)
            let r = fp.rect.intersect(work.rect)
            if !r.isEmpty {
                for y in r.y0..<r.y1 {
                    for x in r.x0..<r.x1 where fp.at(x, y) > 0 {
                        let src = v.px(x, y)
                        work.withPixel(x, y) { px in for (c, val) in src.enumerated() { px[c] = val } }
                    }
                }
            }
            visible = v
        }
    }

    /// Dodge, Burn, Sponge, Blur, Sharpen and Smudge: each dab edits a working copy in order
    /// (`Retouch.applyDabStroke`). Blur, Sharpen and Smudge can sample all layers.
    static func dabCommand(_ s: Session, _ p: JSONValue, _ cmd: String) throws -> JSONValue {
        let (stroke, id) = try parseBrush(s, p, cmd)
        let (tool, label) = try DabTool.parse(s, cmd, p, stroke)
        if let dmg = try runOffered(s, cmd, label, id, p, stroke) { return ["damage": .rect(dmg), "fromLive": true] }
        let all = tool.samplesAllLayers && sampleAllLayers(p)
        let renderer = s.services.renderer
        let dmg = try runStroke(s, label, id, p) { pre, surf, sel, lock in
            let fmt = surf.format
            let effect = tool.effect(fmt, stroke.brush.spacing)
            var sampler: AllLayers? = all ? AllLayers(renderer: renderer, pre: pre, fmt: fmt) : nil
            let d = Retouch.applyDabStroke(&surf, stroke, selection: sel, lockTransparency: lock, halo: tool.halo) { work, fp in
                if sampler != nil { sampler!.dab(&work, fp, effect) } else { effect(&work, fp) }
            }
            if let e = sampler?.failure { throw e }
            return d
        }
        return ["damage": .rect(dmg)]
    }

    // MARK: Registry

    /// The brush every retouching command shares, plus the tool's own params.
    static func brushParams(_ extra: String) -> String {
        #"{"points":[[x,y,pressure?],…],"size":1..5000 px=tool size,"hardness":0..100=tool hardness,"opacity":1..100=100,"flow":1..100=100,"spacing":1..1000 (% of size)=Brush Settings spacing,"layer":id?=active,"target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target"#
            + extra + "}"
    }

    static func register(into r: inout CommandRegistry) {
        func dab(_ id: String, _ label: String, _ extra: String) -> CommandSpec {
            CommandSpec(id, label, params: brushParams(extra), module: m, enabled: hasPixelLayer) { s, p in try dabCommand(s, p, id) }
        }
        r.add([
            CommandSpec("paint.cloneStamp", "Clone Stamp",
                        params: brushParams(#","source":[sx,sy] (sampled under the first point) | "offset":[dx,dy],"aligned":bool=true,"sampleLayer":"current|currentAndBelow|all"="current","mode":"normal|multiply|…"="normal" → {"damage","offset","aligned","nextSource"}"#),
                        module: m, enabled: hasPixelLayer, run: cloneStamp),
            CommandSpec("paint.patternStamp", "Pattern Stamp",
                        params: brushParams(#","pattern":id|name?=Patterns panel current,"scale":1..1000 %=100,"angle":deg=0,"aligned":bool=true,"impressionist":bool=false,"mode":"normal|multiply|…"="normal","phase":[px,py]? → {"damage","phase","aligned","pattern"}"#),
                        module: m, enabled: patternStampEnabled, run: patternStamp),
            CommandSpec("paint.healingBrush", "Healing Brush",
                        params: brushParams(#","source":[sx,sy] | "offset":[dx,dy],"aligned":bool=true,"sampleLayer":"current|currentAndBelow|all"="current","mode":"normal|…"="normal" → {"damage","offset","aligned","nextSource"}"#),
                        module: m, enabled: hasPixelLayer, run: healingBrush),
            CommandSpec("paint.spotHealing", "Spot Healing Brush",
                        params: brushParams(#","type":"contentAware|createTexture|proximityMatch"="contentAware","sampleAllLayers":bool=false"#),
                        module: m, enabled: hasPixelLayer, run: spotHealing),
            CommandSpec("paint.patch", "Patch",
                        params: #"{"offset":[dx,dy] (how far the selection was dragged),"mode":"source|destination"="source","contentAware":bool=false (fill the selection content-aware from the dragged-to place; a background job),"structure":1..7=4 (content-aware: 3..7 copy the middle exactly, 1..2 re-synthesise more of it),"color":0..10=0 (content-aware: how far the copy's level adapts to the selection's surroundings),"sampleAllLayers":bool=false (content-aware),"layer":id?=active,"target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target} → {"damage","offset"}"#,
                        module: m, enabled: patchEnabled, run: patch),
            CommandSpec("paint.contentAwareMove", "Content-Aware Move",
                        params: #"{"offset":[dx,dy] (how far the selection was dragged),"mode":"move|extend"="move","structure":1..7=4 (3..7 copy the content exactly but for a band about a patch wide along its edge; 2 widens the band, 1 re-synthesises the content too),"color":0..10=0 (0 keeps the content's level; higher values bring it towards its new place, by up to about 0.04 × color),"sampleAllLayers":bool=false,"scaleX":%=100,"scaleY":%=100 (Transform On Drop: 1..10000, negative flips),"rotate":deg=0 (Transform On Drop, clockwise; scale and rotation are about the selection's centre, before the offset; a transformed patch may reach past the canvas edge),"layer":id?=active,"target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target} → {"damage","offset","mode","transformed"?} (a background job; the selection moves, and is transformed, with the content)"#,
                        module: m, enabled: contentAwareMoveEnabled, run: contentAwareMove),
            dab("paint.dodge", "Dodge", #","range":"shadows|midtones|highlights"="midtones","exposure":1..100=50,"protectTones":bool=true"#),
            dab("paint.burn", "Burn", #","range":"shadows|midtones|highlights"="midtones","exposure":1..100=50,"protectTones":bool=true"#),
            dab("paint.sponge", "Sponge", #","mode":"desaturate|saturate"="desaturate","vibrance":bool=true (flow = sponge strength)"#),
            dab("paint.blur", "Blur", #","strength":1..100=50,"radius":0.1..100 px (the Gaussian's sigma)=3 % of size (1..4),"sampleAllLayers":bool=false"#),
            dab("paint.sharpen", "Sharpen", #","strength":1..100=50,"radius":0.1..100 px (the unsharp mask's sigma)=1,"protectDetail":bool=true,"sampleAllLayers":bool=false"#),
            dab("paint.smudge", "Smudge", #","strength":1..100=50,"fingerPainting":bool=false (starts with the foreground colour),"sampleAllLayers":bool=false"#),
            CommandSpec("paint.historyBrush", "History Brush",
                        params: brushParams(#","state":index (into history.entries; default 0 = the oldest held state, normally the Open snapshot)"#),
                        module: m, enabled: hasPixelLayer, run: historyBrush),
        ])
    }
}
