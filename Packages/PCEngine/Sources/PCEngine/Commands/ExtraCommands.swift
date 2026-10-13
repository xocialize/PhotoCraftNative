// Port of photocraft-engine (crates/engine/src/extra_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Everyday Photoshop commands that build on the core ones: Edit › Stroke, the fixed Transform
// presets (Rotate 180°/90°, Flip), Paste Into / Outside, Reselect, Equalize, Reveal All, Layer from
// Background, Copy/Paste Layer Style, Hide/Show All Effects, layer-mask toggles, the Rasterize
// variants, Delete Hidden / Empty Layers, Ungroup, Hide/Show Layers, Lock Transparent Pixels, Show
// Only This Layer (⌥-click an eye), Average and Clouds.
//
// The Transform presets run `edit.transform` with a nearest-neighbour matrix (exact pixel
// permutations), on the Channels / Layers panel target. Deviations: Stroke's edge
// distances (photocraft-algo `selection::expand`/`contract`, an exact Euclidean distance transform)
// and the Clouds generator are ported here. Rasterize runs `type.rasterize`, `layer.rasterize.shape`
// and `layer.rasterize.vectorMask` as photocraft does when those commands are available, and
// otherwise does the same edit here (PCPlatform's `TextEngine` / `VectorRasterizer` through the
// engine's rasterizer); a feathered or density-reduced mask combination needs vector_cmds' combined
// mask and is reported unavailable by that fallback. Smart objects without a rendered cache
// rasterize through the compositor (photocraft refreshes them with smart_cmds first).

import Foundation
import PCDocument
import PCFoundation
import PCRender

enum ExtraCommands: CommandModule {
    static let name = "extra_cmds"
    static let m = name

    // MARK: Module state

    /// Copy Layer Style's clipboard (photocraft `Session::style_clipboard`).
    struct StyleClip: Sendable, Equatable {
        var effects: Effects
        var blend: BlendMode
        var fillOpacity: Float
        var advanced: AdvancedBlending
    }

    enum StyleClipboardKey: StateKey { static let defaultValue: StyleClip? = nil }

    /// Show Only This Layer's snapshot of every layer's visibility (photocraft `DocState::show_only`).
    struct ShowOnly: Sendable, Equatable {
        var layer: LayerId
        var visibility: [(LayerId, Bool)]
        static func == (a: ShowOnly, b: ShowOnly) -> Bool {
            a.layer == b.layer && a.visibility.count == b.visibility.count && zip(a.visibility, b.visibility).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    enum ShowOnlyKey: StateKey { static let defaultValue: ShowOnly? = nil }

    // MARK: Preconditions

    static let hasMask: CommandEnabled = { s, _ in
        switch s.activeLayer() {
        case .failure(let e): return e.description
        case .success(let l): return l.mask == nil ? "the active layer has no layer mask" : nil
        }
    }

    static let hasClipAndSelection: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        if EditCommands.clipboard(s) == nil { return "the clipboard is empty" }
        return d.doc.selection == nil ? "Paste Into needs a selection" : nil
    }

    static let hasBackground: CommandEnabled = { s, _ in
        guard let d = s.active else { return "no document open" }
        return d.doc.background == nil ? "the document has no Background layer" : nil
    }

    /// The layers a layer-style command acts on: as `LayerMulti.targets`, but with several layers
    /// selected only those `fits` (the Background carries no style).
    static func styleTargets(_ s: Session, _ p: JSONValue, _ fits: (Layer) -> Bool) throws -> [LayerId] {
        let ids = try LayerMulti.targets(s, p)
        if ids.count < 2 { return ids }
        guard let d = s.active else { throw EngineError.noDocument }
        let ok = ids.filter { id in d.doc.layer(id).map { !d.doc.isBackground($0.id) && fits($0) } ?? false }
        if ok.isEmpty { throw EngineError.other("none of the selected layers can take this layer style change") }
        return ok
    }

    /// A key that makes the sub-commands of one command share a single history step.
    static func stepKey(_ s: Session, _ what: String) -> String { "\(what)#\(s.active?.revision ?? 0)" }

    /// Runs `body` with the session's coalescing key set to `key` (photocraft sets
    /// `Session::coalesce_request` around such edits).
    static func coalescing<R>(_ s: Session, _ key: String, _ body: () throws -> R) rethrows -> R {
        let saved = s.coalesceRequest
        s.coalesceRequest = key
        defer { s.coalesceRequest = saved }
        return try body()
    }

    // MARK: Pixel helpers

    /// Rewrite the active pixel layer's RGBA over the selection bounds (or the canvas). `f` gets the
    /// area, the pixels and the selection coverage per pixel; results are blended back by coverage,
    /// and transparency stays locked when the layer locks it. When `p` targets an alpha channel, the
    /// Quick Mask or the layer mask, that grayscale surface is rewritten instead (#935).
    static func mapPixels(_ s: Session, _ label: String, _ p: JSONValue,
                          _ f: (PixelRect, inout [SIMD4<Float>], [Float]) -> Void) throws -> JSONValue {
        let id = try s.layerParam(.null)
        let channel = Channels.targetOf(p) != .pixels
        try s.edit(label) { doc, _ in
            let canvas = doc.bounds
            let selection = doc.selection
            let area = selection.map { $0.contentBounds.intersect(canvas) } ?? canvas
            try FillCommands.checkArea(area, "rewriting pixels")
            func apply(_ surf: inout Surface, _ lockAlpha: Bool) {
                let fmt = surf.format, n = fmt.channels
                var raw = surf.readRegion(area)
                let orig = PixelCodec.toRGBA(fmt, raw: raw)
                let cover = selection?.coverage(area) ?? [Float](repeating: 1, count: orig.count)
                var px = orig
                f(area, &px, cover)
                for i in 0..<min(orig.count, px.count, cover.count) {
                    let k = cover[i]
                    if k <= 0 { continue }
                    var v = orig[i] + (px[i] - orig[i]) * k
                    if lockAlpha { v.w = orig[i].w }
                    let enc = fmt.components(fromRGBA: v)
                    for c in 0..<min(n, enc.count) { raw[i * n + c] = enc[c] }
                }
                surf.writeRegion(area, raw)
                surf.prune()
            }
            if channel {
                try Channels.withTargetSurface(&doc, layer: id, p) { surf, _ in
                    Channels.materialize(&surf, canvas)
                    if area.isEmpty { return }
                    apply(&surf, false)
                }
                return
            }
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            let locks = doc.effectiveLocks(id)
            if locks.pixels || locks.all { throw EngineError.other("Could not complete your request because the layer \"\(l.name)\" is locked") }
            guard case .raster = l.content else { throw EngineError.other("not a pixel layer") }
            if area.isEmpty { return }
            doc.withRaster(of: id) { apply(&$0, locks.transparency) }
        }
        return .null
    }

    // MARK: Distance transform (photocraft-algo selection/distance.rs, selection.rs)

    /// Euclidean distance to the nearest `true` pixel, row-major (Felzenszwalb–Huttenlocher). A mask
    /// with no seeds gives 1e10 everywhere.
    static func edt(_ inside: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let n = w * h
        guard w > 0, h > 0, inside.count == n else { return [] }
        if !inside.contains(true) { return [Float](repeating: 1e10, count: n) }
        if !inside.contains(false) { return [Float](repeating: 0, count: n) }
        let none = Int.max
        var vert = [Int](repeating: none, count: n)
        for x in 0..<w {
            var last = -1
            for y in 0..<h {
                if inside[y * w + x] { last = y }
                if last >= 0 { vert[y * w + x] = y - last }
            }
            last = -1
            for y in stride(from: h - 1, through: 0, by: -1) {
                if inside[y * w + x] { last = y }
                if last >= 0 { vert[y * w + x] = min(vert[y * w + x], last - y) }
            }
        }
        var out = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: w)
        var z = [Double](repeating: 0, count: w + 1)
        for y in 0..<h {
            let row = y * w
            var k = -1
            for q in 0..<w {
                let gq = vert[row + q]
                if gq == none { continue }
                let fq = Double(gq) * Double(gq) + Double(q) * Double(q)
                if k < 0 {
                    k = 0
                    v[0] = q
                    z[0] = -.infinity
                    z[1] = .infinity
                    continue
                }
                var s = 0.0
                while k >= 0 {
                    let p = v[k], gp = vert[row + p]
                    s = (fq - (Double(gp) * Double(gp) + Double(p) * Double(p))) / Double(2 * (q - p))
                    if s <= z[k] { k -= 1 } else { break }
                }
                k += 1
                v[k] = q
                z[k] = k == 0 ? -.infinity : s
                z[k + 1] = .infinity
            }
            if k < 0 {
                for x in 0..<w { out[row + x] = 1e10 }
                continue
            }
            var j = 0
            for x in 0..<w {
                while j < k && z[j + 1] < Double(x) { j += 1 }
                let dx = Double(x - v[j]), g = Double(vert[row + v[j]])
                out[row + x] = Float((dx * dx + g * g).squareRoot())
            }
        }
        return out
    }

    /// photocraft-algo `selection::expand`: grows the selection by `r` pixels.
    static func expand(_ m: [Float], _ w: Int, _ h: Int, _ r: Float) -> [Float] {
        let d = edt(m.map { $0 >= 0.5 }, w, h)
        return zip(m, d).map { max($0, min(max(r + 1 - $1, 0), 1)) }
    }

    /// photocraft-algo `selection::contract`: shrinks the selection by `r` pixels.
    static func contract(_ m: [Float], _ w: Int, _ h: Int, _ r: Float) -> [Float] {
        expand(m.map { 1 - $0 }, w, h, r).map { 1 - $0 }
    }

    // MARK: Edit › Stroke

    static func strokeBad(_ msg: String) -> EngineError { .bad("edit.stroke", msg) }

    /// Edit › Stroke: a band along the selection edge (or the layer's opaque edge without a selection).
    static func stroke(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        // Whole pixels, rounded up, as in Photoshop (0.5 px strokes 1 px).
        let wv = p["width"]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } ?? 1
        let width = Int(min(max(wv, 1), 250).rounded(.up))
        let color = Params.color(p, "color", s.tools.foreground)
        var mode = BlendMode.normal
        if let v = p["mode"], v != .null {
            guard case .string(let name) = v else { throw strokeBad("mode must be a blend mode name, not \(v.serialized())") }
            guard let b = Params.blendMode(name), b != .passThrough else { throw strokeBad("unknown blend mode `\(name)`") }
            mode = b
        }
        var opacity: Float = 1
        if let v = p["opacity"], v != .null {
            guard let o = v.doubleValue, o.isFinite else { throw strokeBad("opacity must be a finite number from 0 to 100") }
            opacity = Float(min(max(o, 0), 100) / 100)
        }
        var preserve = false
        if let v = p["preserveTransparency"], v != .null {
            guard case .bool(let b) = v else { throw strokeBad("preserveTransparency must be true or false") }
            preserve = b
        }
        let location = p["location"]?.stringValue ?? "center"
        let id = try s.layerParam(p)
        try s.edit("Stroke") { doc, _ in
            let canvas = doc.bounds
            let (w, h) = (canvas.width, canvas.height)
            let edge: [Float]
            if let sel = doc.selection {
                edge = SelectionMath.mask(from: sel, canvas)
            } else {
                guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
                guard let surf = l.surface else { throw EngineError.other("not a pixel layer") }
                edge = surf.readRGBA(canvas).map(\.w)
            }
            // Past the canvas nothing is selected, so the canvas edge is a selection edge like any
            // other (Select All, then Stroke › Inside, frames the canvas): stroke on a padded copy.
            let pad = width + 1
            let (pw, ph) = (w + 2 * pad, h + 2 * pad)
            // The padded working copies are canvas-sized: refuse a canvas they can't be made for.
            let (cells, overflow) = pw.multipliedReportingOverflow(by: ph)
            if overflow || cells > FillCommands.maxWorkingPixels {
                throw EngineError.other("not enough memory for stroking the selection (requested size overflowed); the document was not changed")
            }
            var padded = [Float](repeating: 0, count: pw * ph)
            for y in 0..<h { for x in 0..<w where y * w + x < edge.count { padded[(y + pad) * pw + x + pad] = edge[y * w + x] } }
            // Whole-pixel bands, fully opaque: Center puts the odd pixel inside (1 px is all inside).
            let (outPx, inPx): (Int, Int) = switch location {
            case "inside": (0, width)
            case "outside": (width, 0)
            default: (width / 2, (width + 1) / 2)
            }
            // A hard-edged selection strokes hard, matching Photoshop pixel for pixel on curves:
            // outside, a pixel is stroked when its centre is less than width + 1 from a selected
            // pixel's; inside, less than width + ½ from an unselected pixel's. Soft selections keep
            // soft edges.
            let hard = padded.allSatisfy { $0 <= 0 || $0 >= 1 }
            let inR = hard && inPx > 0 ? Float(inPx) - 0.5 : Float(inPx)
            var outer = expand(padded, pw, ph, Float(outPx))
            var inner = contract(padded, pw, ph, inR)
            if hard {
                outer = outer.map { $0 > 0 ? 1 : 0 }
                inner = inner.map { $0 >= 1 ? 1 : 0 }
            }
            var band = [Float](repeating: 0, count: w * h)
            if outer.count == pw * ph && inner.count == pw * ph {
                for y in 0..<h {
                    for x in 0..<w {
                        let i = (y + pad) * pw + x + pad
                        band[y * w + x] = min(max(outer[i] - inner[i], 0), 1)
                    }
                }
            }
            let bandSurface = SelectionMath.surface(band, canvas)
            let lock = doc.effectiveLocks(id).transparency
            try LayerOps.withPaintSurface(&doc, id, .null) { surf in
                guard let bandSurface else { return }
                let area = bandSurface.contentBounds.intersect(canvas)
                if !area.isEmpty {
                    FillCommands.blendColorMask(&surf, area, color, bandSurface, mode: mode, opacity: opacity, preserveTransparency: preserve || lock)
                    surf.prune()
                }
            }
        }
        return .null
    }

    // MARK: Equalize, Average, Clouds

    /// Histogram equalization, like Photoshop's: one CDF over the R, G and B values of the selected
    /// pixels, applied to every channel.
    static func equalize(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try mapPixels(s, "Equalize", p) { _, px, cover in
            func bin(_ v: Float) -> Int { v.isNaN ? 0 : Int((min(max(v, 0), 1) * 255).rounded()) }
            var hist = [Double](repeating: 0, count: 256)
            for (q, k) in zip(px, cover) where k > 0 && q.w > 0 {
                hist[bin(q.x)] += 1
                hist[bin(q.y)] += 1
                hist[bin(q.z)] += 1
            }
            let total = hist.reduce(0, +)
            if total == 0 { return }
            let first = hist.first { $0 > 0 } ?? 0
            var lut = [Float](repeating: 0, count: 256)
            var acc = 0.0
            for i in 0..<256 {
                acc += hist[i]
                lut[i] = total > first ? Float(min(max((acc - first) / (total - first), 0), 1)) : Float(i) / 255
            }
            // Same 256 bins as the histogram, at every depth (like Photoshop).
            for i in px.indices {
                px[i] = SIMD4(lut[bin(px[i].x)], lut[bin(px[i].y)], lut[bin(px[i].z)], px[i].w)
            }
        }
    }

    /// Filter › Blur › Average: the selection (or layer) filled with its mean colour.
    static func average(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        try mapPixels(s, "Average", p) { _, px, cover in
            var sum = SIMD3<Double>(0, 0, 0), wsum = 0.0, asum = 0.0, n = 0.0
            for (q, k) in zip(px, cover) {
                let w = Double(q.w * k)
                sum += SIMD3(Double(q.x), Double(q.y), Double(q.z)) * w
                wsum += w
                asum += Double(q.w * k)
                n += Double(k)
            }
            if wsum <= 0 { return }
            let avg = SIMD4<Float>(Float(sum.x / wsum), Float(sum.y / wsum), Float(sum.z / wsum), Float(asum / max(n, 1e-9)))
            for i in px.indices { px[i] = avg }
        }
    }

    static func hash(_ x: Int32, _ y: Int32, _ seed: UInt32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8da6_b343 ^ UInt32(bitPattern: y) &* 0xd816_3841 ^ seed &* 0xcb1a_b31f
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h & 0x00ff_ffff) / Float(0x00ff_ffff)
    }

    /// `v` floored to an Int32, saturating (Rust's `as i32`).
    static func floorI32(_ v: Float) -> Int32 {
        let f = v.rounded(.down)
        if f.isNaN { return 0 }
        if f >= Float(Int32.max) { return .max }
        if f <= Float(Int32.min) { return .min }
        return Int32(f)
    }

    /// Smooth value noise, summed over octaves (fBm), in 0…1.
    static func cloudsValue(_ x: Float, _ y: Float, base: Float, seed: UInt32) -> Float {
        var (sum, amp, freq, norm): (Float, Float, Float, Float) = (0, 1, 1 / base, 0)
        for o in UInt32(0)..<8 {
            let (fx, fy) = (x * freq, y * freq)
            let (ix, iy) = (floorI32(fx), floorI32(fy))
            let (tx, ty) = (fx - Float(ix), fy - Float(iy))
            let (sx, sy) = (tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty))
            let s = seed &+ o &* 7919
            let top = hash(ix, iy, s) + (hash(ix &+ 1, iy, s) - hash(ix, iy, s)) * sx
            let bot = hash(ix, iy &+ 1, s) + (hash(ix &+ 1, iy &+ 1, s) - hash(ix, iy &+ 1, s)) * sx
            sum += (top + (bot - top) * sy) * amp
            norm += amp
            amp *= 0.5
            freq *= 2
        }
        // Stretch the bell-shaped sum so the clouds use the full foreground→background range.
        return min(max((sum / norm - 0.5) * 2.2 + 0.5, 0), 1)
    }

    /// Filter › Render › Clouds / Difference Clouds, between the foreground and background colours.
    static func clouds(_ s: Session, _ p: JSONValue, difference: Bool) throws -> JSONValue {
        let (fg, bg) = (s.tools.foreground, s.tools.background)
        let seed = UInt32(truncatingIfNeeded: p["seed"]?.uint64Value ?? 0)
        let size = s.active.map { Float(max($0.doc.size.width, $0.doc.size.height)) } ?? 256
        let base = min(max(size / 4, 16), 512)
        return try mapPixels(s, difference ? "Difference Clouds" : "Clouds", p) { area, px, _ in
            let w = area.width
            for i in px.indices {
                let (x, y) = (Float(Int(area.x0) + i % w), Float(Int(area.y0) + i / w))
                let t = cloudsValue(x, y, base: base, seed: seed)
                let c = SIMD3(fg.x, fg.y, fg.z) + (SIMD3(bg.x, bg.y, bg.z) - SIMD3(fg.x, fg.y, fg.z)) * t
                if difference {
                    px[i] = SIMD4(abs(px[i].x - c.x), abs(px[i].y - c.y), abs(px[i].z - c.z), px[i].w)
                } else {
                    px[i] = SIMD4(c, 1)
                }
            }
        }
    }

    // MARK: Selection / clipboard

    static func reselectTarget(_ s: Session) -> Surface? {
        guard let d = s.active, d.doc.selection == nil else { return nil }
        for i in stride(from: d.history.pastCount - 1, through: 0, by: -1) {
            if let sel = d.history.state(i)?.selection { return sel }
        }
        return nil
    }

    static let canReselect: CommandEnabled = { s, p in
        if let e = Pre.hasDoc(s, p) { return e }
        return reselectTarget(s) == nil ? "there is no selection to restore" : nil
    }

    static func pasteInto(_ s: Session, _ p: JSONValue, outside: Bool) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        guard let selection = d.doc.selection else { throw EngineError.other("Paste Into needs a selection") }
        let canvas = d.doc.bounds
        let b = selection.contentBounds
        // Where the paste shows: the selection, or everything but it.
        let limit: Surface
        if outside {
            let area = b.intersect(canvas)
            var mk = Surface.withDefault(.gray8, [1])
            if !area.isEmpty { mk.writeRegion(area, SelectionMath.mask(from: selection, area).map { 1 - $0 }) }
            limit = mk
        } else {
            limit = selection
        }
        let label = outside ? "Paste Outside" : "Paste Into"
        var params: JSONValue = ["center": [.number((Double(b.x0) + Double(b.x1)) / 2), .number((Double(b.y0) + Double(b.y1)) / 2)]]
        if let c = p["center"] { params = params.setting("center", c) }
        // A targeted colour channel (#2307): the paste goes into it, only where `limit` allows.
        if let k = EditCommands.pasteColorTarget(s, p) {
            return try EditCommands.channelPaste(s, params, k, inPlace: false, limit: limit, label: label)
        }
        if Channels.targetOf(p) != .pixels {
            // A targeted mask or channel (#1035): the paste goes into it, only where `limit` allows.
            params = params.setting("target", p["target"] ?? .null)
            return try EditCommands.pasteToTarget(s, params, inPlace: false, limit: limit, label: label)
        }
        let key = stepKey(s, "pasteInto")
        params = params.setting("coalesce", .string(key)).setting("target", "pixels")
        let r = try s.execute("edit.paste", params)
        let id = try s.layerParam(.null)
        try s.execute("layer.layerMask.revealAll", ["layer": .id(id), "coalesce": .string(key)])
        try coalescing(s, key) {
            try s.edit(label) { doc, _ in
                guard doc.updateLayer(id, { $0.mask = LayerMask(surface: limit, linked: false) }) != nil else { throw EngineError.noLayer(id) }
            }
        }
        return r
    }

    /// The canvas grown to every layer's pixels: Image › Reveal All's new canvas.
    static func revealAllBounds(_ doc: Document) -> PixelRect {
        doc.walk().reduce(doc.bounds) { a, e in
            guard let b = e.layer.surface?.contentBounds, !b.isEmpty else { return a }
            return a.union(b)
        }
    }

    // MARK: Layers

    static func layerFromBackground(_ s: Session) throws -> JSONValue {
        let id = try s.edit("Layer From Background") { doc, active -> LayerId in
            guard let bg = doc.background?.id else { throw EngineError.other("the document has no Background layer") }
            doc.updateBackground { LayerOps.unlockBackground(&$0) }
            active = bg
            return bg
        }
        return ["layer": .id(id)]
    }

    static func toggleMask(_ s: Session, _ p: JSONValue, _ key: String) throws -> JSONValue {
        let id = try s.layerParam(p)
        let label = key == "enabled" ? "Enable/Disable Layer Mask" : "Link/Unlink Layer Mask"
        let v = try s.edit(label) { doc, _ -> Bool in
            guard var mk = doc.layer(id)?.mask else { throw EngineError.other("the layer has no layer mask") }
            let now = key == "enabled" ? mk.enabled : mk.linked
            let next = p[key]?.boolValue ?? !now
            if key == "enabled" { mk.enabled = next } else { mk.linked = next }
            doc.updateLayer(id) { $0.mask = mk }
            return next
        }
        return [key: .bool(v)]
    }

    static func setAllEffects(_ s: Session, _ enabled: Bool) throws -> JSONValue {
        try s.edit(enabled ? "Show All Effects" : "Hide All Effects") { doc, _ in
            doc.forEachLayerMut { l in if !l.effects.items.isEmpty { l.effects.enabled = enabled } }
        }
        return .null
    }

    /// Remove every layer matching `pred` (whole subtrees), keeping at least one layer.
    static func deleteWhere(_ s: Session, _ label: String, _ pred: @escaping (Layer) -> Bool) throws -> JSONValue {
        let n = try s.edit(label) { doc, active -> Int in
            func rec(_ ls: inout [Layer]) -> Int {
                let before = ls.count
                ls.removeAll(where: pred)
                var n = before - ls.count
                for i in ls.indices { ls[i].withChildren { n += rec(&$0) } }
                return n
            }
            var layers = doc.layers
            let n = rec(&layers)
            if layers.isEmpty { throw EngineError.other("a document must keep at least one layer") }
            doc.layers = layers
            if active.map({ doc.layer($0) == nil }) ?? true { active = doc.topLayer }
            return n
        }
        return ["deleted": .int(n)]
    }

    static func isEmptyLayer(_ l: Layer) -> Bool {
        switch l.content {
        case .raster(let s): return s.contentBounds.isEmpty && l.mask == nil && l.effects.items.isEmpty
        case .group(let g): return g.children.allSatisfy(isEmptyLayer)
        default: return false
        }
    }

    static func ungroup(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        try s.edit("Ungroup Layers") { doc, active in
            guard let path = doc.path(of: id), let g = doc.layer(id), let idx = path.last else { throw EngineError.noLayer(id) }
            guard case .group(let group) = g.content else { throw EngineError.other("the active layer is not a group") }
            let children = group.children
            func splice(_ sib: inout [Layer]) {
                guard idx < sib.count else { return }
                sib.remove(at: idx)
                sib.insert(contentsOf: children, at: idx)
            }
            let parent = Array(path.dropLast())
            if parent.isEmpty {
                var layers = doc.layers
                splice(&layers)
                doc.layers = layers
            } else {
                doc.updateLayer(at: parent) { $0.withChildren { splice(&$0) } }
            }
            active = children.last?.id ?? doc.topLayer
        }
        return .null
    }

    static func setVisible(_ s: Session, _ p: JSONValue, _ visible: Bool) throws -> JSONValue {
        if LayerMulti.multi(s, p) { return try LayerMulti.setVisibleSelected(s, visible) }
        let id = try s.layerParam(p)
        try s.edit(visible ? "Show Layer" : "Hide Layer") { doc, _ in
            guard doc.updateLayer(id, { $0.visible = visible }) != nil else { throw EngineError.noLayer(id) }
        }
        return .null
    }

    /// Layer › Hide Layers (⌘,): hide the targeted layers, or show them when every one is already
    /// hidden, as Photoshop's item does, so ⌘, toggles.
    static func hideOrShow(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let targets = LayerMulti.multi(s, p) ? LayerMulti.selected(s) : [try s.layerParam(p)]
        let allHidden = targets.allSatisfy { st.doc.layer($0).map { !$0.visible } ?? false }
        return try setVisible(s, p, allHidden)
    }

    /// `/`: Lock Transparent Pixels on or off for the targeted layers. With several layers targeted,
    /// any unlocked one means lock them all. The Background is left out.
    static func toggleLockTransparency(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        guard let st = s.active else { throw EngineError.noDocument }
        let all = LayerMulti.multi(s, p) ? LayerMulti.selected(s) : [try s.layerParam(p)]
        let targets = all.filter { st.doc.layer($0) != nil && !st.doc.isBackground($0) }
        if targets.isEmpty { throw EngineError.other("the Background layer can't lock transparent pixels") }
        let lock = !targets.allSatisfy { st.doc.layer($0)?.locks.transparency ?? false }
        try s.edit(lock ? "Lock Transparent Pixels" : "Unlock Transparent Pixels") { doc, _ in
            for id in targets { guard doc.updateLayer(id, { $0.locks.transparency = lock }) != nil else { throw EngineError.noLayer(id) } }
        }
        return ["locked": .bool(lock)]
    }

    /// Is the layer at `path` shown alone: it and its enclosing groups visible, every layer outside
    /// it hidden (the layers inside a group keep their own visibility)?
    static func shownAlone(_ doc: Document, _ path: LayerPath) -> Bool {
        doc.walk().allSatisfy { e in
            path.starts(with: e.path) ? e.layer.visible : (e.path.starts(with: path) || !e.layer.visible)
        }
    }

    /// ⌥-click on a layer's eye: show only that layer (and its enclosing groups), or, when it
    /// already is shown alone, restore every layer's visibility from before (every layer shown when
    /// there is no snapshot). One history step either way; the snapshot is view state.
    static func showOnly(_ s: Session, _ p: JSONValue) throws -> JSONValue {
        let id = try s.layerParam(p)
        guard let st = s.active else { throw EngineError.noDocument }
        let doc = st.doc
        guard let path = doc.path(of: id) else { throw EngineError.noLayer(id) }
        // The snapshot only counts while its solo is still in effect.
        let saved = st.view[ShowOnlyKey.self].flatMap { snap in doc.path(of: snap.layer).map { shownAlone(doc, $0) } == true ? snap : nil }
        let walk = doc.walk()
        let solo = !shownAlone(doc, path)
        let label: String
        let rows: [(LayerPath, Bool)]
        let next: ShowOnly?
        if solo {
            let snapshot = saved?.visibility ?? walk.map { ($0.layer.id, $0.layer.visible) }
            // Layers inside the shown layer keep their visibility.
            rows = walk.filter { $0.path.count <= path.count || !$0.path.starts(with: path) }.map { ($0.path, path.starts(with: $0.path)) }
            label = "Show Only This Layer"
            next = ShowOnly(layer: id, visibility: snapshot)
        } else {
            let before = saved.map { Dictionary($0.visibility, uniquingKeysWith: { _, b in b }) }
            // Layers added since the snapshot keep their current visibility.
            rows = walk.map { e in (e.path, before.map { $0[e.layer.id] ?? e.layer.visible } ?? true) }
            label = "Show Layers"
            next = nil
        }
        try s.edit(label) { doc, _ in
            for (p, visible) in rows { doc.updateLayer(at: p) { $0.visible = visible } }
        }
        try? s.updateActive { $0.view[ShowOnlyKey.self] = next }
        return ["shownAlone": .bool(solo)]
    }

    // MARK: Rasterize

    /// Pixels of a fill or smart-object layer's content alone (no mask, effects or opacity).
    static func contentPixels(_ renderer: EngineRenderer, _ doc: Document, _ l: Layer) throws -> Surface {
        var tmp = l
        tmp.mask = nil
        tmp.vectorMask = nil
        tmp.effects.items.removeAll()
        tmp.opacity = 1
        tmp.fillOpacity = 1
        tmp.blend = .normal
        tmp.clipped = false
        tmp.visible = true
        tmp.blendIf = BlendIf()
        var solo = doc
        solo.layers = [tmp]
        solo.selection = nil
        let canvas = doc.bounds
        if canvas.isEmpty { return Surface(format: doc.pixelFormat) }
        var s = try renderer.compositeToSurface(solo, rect: canvas, format: doc.pixelFormat)
        s.prune()
        return s
    }

    static func kindOf(_ s: Session, _ id: LayerId) -> String? {
        guard let l = s.active?.doc.layer(id) else { return nil }
        switch l.content {
        case .text: return "type"
        case .shape: return "shape"
        case .fill: return "fill"
        case .smart: return "smart"
        default: return nil
        }
    }

    /// Runs `cmd` as photocraft does when its module is available here; false when it isn't (the
    /// caller does the same edit itself).
    static func delegated(_ s: Session, _ cmd: String, _ params: JSONValue) throws -> Bool {
        guard s.registry.spec(cmd)?.isAvailable == true else { return false }
        try s.execute(cmd, params)
        return true
    }

    /// Rasterize one layer; `only` restricts it to one kind. Without `only` (Rasterize › Layer /
    /// All Layers) a vector mask becomes a pixel mask too; layer effects stay live. Returns false
    /// when there was nothing to do.
    static func rasterizeOne(_ s: Session, _ id: LayerId, only: String?, key: String) throws -> Bool {
        let vectorMask = only == nil && s.active?.doc.layer(id)?.vectorMask != nil
        let content = try rasterizeContent(s, id, only: only, key: key)
        if vectorMask, try !delegated(s, "layer.rasterize.vectorMask", ["layer": .id(id), "coalesce": .string(key)]) {
            try coalescing(s, key) { try rasterizeVectorMask(s, id) }
        }
        return content || vectorMask
    }

    static func rasterizeContent(_ s: Session, _ id: LayerId, only: String?, key: String) throws -> Bool {
        guard let kind = kindOf(s, id), only.map({ $0 == kind }) ?? true else { return false }
        let renderer = s.services.renderer
        switch kind {
        case "type":
            if try !delegated(s, "type.rasterize", ["layer": .id(id), "coalesce": .string(key)]) {
                try coalescing(s, key) { try rasterizeVector(s, id, type: true) }
            }
        case "shape":
            if try !delegated(s, "layer.rasterize.shape", ["layer": .id(id), "coalesce": .string(key)]) {
                try coalescing(s, key) { try rasterizeVector(s, id, type: false) }
            }
        case "smart":
            try coalescing(s, key) {
                try s.edit("Rasterize Smart Object") { doc, _ in
                    let snapshot = doc
                    guard let snap = doc.layer(id) else { throw EngineError.noLayer(id) }
                    guard case .smart(let sm) = snap.content else { throw EngineError.other("layer \(id.rawValue) is not a smart object") }
                    let fmt = snapshot.pixelFormat
                    var surface = try sm.cache ?? contentPixels(renderer, snapshot, snap)
                    if surface.format != fmt { surface = surface.convertedAny(to: fmt) }
                    doc.updateLayer(id) { l in
                        l.content = .raster(surface)
                        l.psdBlocks.removeAll { ["SoLd", "SoLE", "PlLd"].map { PSDKey($0 as String) }.contains($0.key) }
                    }
                }
            }
        default:
            try coalescing(s, key) {
                try s.edit("Rasterize Fill Content") { doc, _ in
                    guard let snap = doc.layer(id) else { throw EngineError.noLayer(id) }
                    let px = try contentPixels(renderer, doc, snap)
                    doc.updateLayer(id) { l in
                        l.content = .raster(px)
                        l.fillCache = nil
                        // The PSD fill or placed-layer blocks no longer describe the layer.
                        l.psdBlocks.removeAll { ["SoCo", "GdFl", "PtFl", "SoLd", "PlLd", "SoLE"].map { PSDKey($0 as String) }.contains($0.key) }
                    }
                }
            }
        }
        return true
    }

    /// `type.rasterize` / `layer.rasterize.shape` (photocraft type_cmds.rs, vector_cmds.rs
    /// `shape_rasterize`) for when those modules aren't available: the rendered cache, else PCPlatform's
    /// `TextEngine` / `VectorRasterizer` through the engine's rasterizer.
    static func rasterizeVector(_ s: Session, _ id: LayerId, type: Bool) throws {
        let rasterizer = s.services.renderer.rasterizer
        try s.edit(type ? "Rasterize Type" : "Rasterize Shape") { doc, _ in
            let snapshot = doc
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            let fmt = snapshot.pixelFormat
            var surface: Surface
            switch (l.content, type) {
            case (.text(let t), true): surface = t.cache ?? rasterizer.rasterize(l, in: snapshot) ?? Surface(format: fmt)
            case (.shape(let sh), false): surface = sh.cache ?? rasterizer.renderShape(sh, format: fmt, clip: snapshot.bounds) ?? Surface(format: fmt)
            default: throw EngineError.other("layer \(id.rawValue) is not a \(type ? "type" : "shape") layer")
            }
            if surface.format != fmt { surface = surface.convertedAny(to: fmt) }
            let drop = (type ? ["TySh"] : ["vmsk", "vsms", "vogk", "vstk", "vscg", "SoCo", "GdFl", "PtFl"]).map { PSDKey($0 as String) }
            doc.updateLayer(id) { l in
                l.content = .raster(surface)
                l.psdBlocks.removeAll { drop.contains($0.key) }
            }
        }
    }

    /// Vector-mask coverage with density over `area` (photocraft-vector `vector_mask_values`): the
    /// path's coverage within its bounds ±2 px, its far value elsewhere.
    static func vectorMaskValues(_ vm: VectorMask, _ area: PixelRect, _ rasterizer: PlatformRasterizer) -> [Float]? {
        let d = min(max(vm.density, 0), 1)
        func dens(_ v: Float) -> Float { d < 1 ? 1 - d * (1 - v) : v }
        if vm.path.isEmpty { return [Float](repeating: dens(vm.path.inverted ? 0 : 1), count: area.area) }
        var out = [Float](repeating: dens(vm.path.inverted ? 1 : 0), count: area.area)
        guard let cb = vm.path.controlBounds else { return out }
        func i32(_ v: Double, _ dd: Int64) -> Int32 { Int32(clamping: (v.isFinite ? Int64(max(min(v, 9e18), -9e18)) : 0) + dd) }
        let b = PixelRect(x0: i32(cb.x.rounded(.down), -2), y0: i32(cb.y.rounded(.down), -2),
                          x1: i32(cb.z.rounded(.up), 2), y1: i32(cb.w.rounded(.up), 2)).intersect(area)
        if b.isEmpty { return out }
        guard let cov = rasterizer.coverage(of: vm.path, in: b), cov.count == b.area else { return nil }
        let w = area.width, bw = b.width
        for i in 0..<b.area {
            let x = Int(b.x0 - area.x0) + i % bw, y = Int(b.y0 - area.y0) + i / bw
            out[y * w + x] = dens(cov[i])
        }
        return out
    }

    /// `layer.rasterize.vectorMask` (photocraft vector_cmds.rs `vector_mask_rasterize`) for when
    /// vector_cmds isn't available: the vector mask multiplied into the layer mask.
    static func rasterizeVectorMask(_ s: Session, _ id: LayerId) throws {
        let rasterizer = s.services.renderer.rasterizer
        try s.edit("Rasterize Vector Mask") { doc, _ in
            let area = doc.bounds
            let depth = doc.depth
            guard let l = doc.layer(id) else { throw EngineError.noLayer(id) }
            guard let vm = l.vectorMask else { throw EngineError.other("layer has no vector mask") }
            let soft = vm.enabled && (MaskSpec.featherSigma(vm.feather) > 0
                || (l.mask.map { $0.enabled && (MaskSpec.featherSigma($0.feather) > 0 || $0.density < 1) } ?? false))
            if soft {
                throw EngineError.unavailable("layer.rasterize.vectorMask", "a feathered or density-reduced mask combination needs vector_cmds (not ported yet)")
            }
            guard let vals = vectorMaskValues(vm, area, rasterizer) else { throw EngineError.other("the vector mask could not be rendered") }
            var mask = l.mask ?? LayerMask(surface: Surface.withDefault(PixelFormat(mode: .grayscale, sample: depth, alpha: false), [1]))
            // Outside the canvas the vector mask is 0 unless it is empty/inverted; keep the old default there.
            let old = mask.surface.coverage(area)
            mask.surface.writeRegion(area, zip(old, vals).map { $0 * $1 })
            mask.surface.prune()
            doc.updateLayer(id) { l in
                l.vectorMask = nil
                l.mask = mask
            }
        }
    }

    /// Layer › Rasterize › Layer / Type / Shape / Fill Content / Smart Object. With a `layer` param,
    /// just that layer; otherwise every selected layer the command applies to, in one history step.
    static func rasterize(_ s: Session, _ p: JSONValue, only: String?) throws -> JSONValue {
        let ids = try LayerMulti.targets(s, p)
        let many = ids.count > 1
        let key = stepKey(s, "rasterize")
        var done: [LayerId] = []
        for id in ids where try rasterizeOne(s, id, only: only, key: key) { done.append(id) }
        guard let first = done.first else {
            switch (only, many) {
            case (let k?, false): throw EngineError.other("the layer is not a \(k) layer")
            case (let k?, true): throw EngineError.other("none of the selected layers is a \(k) layer")
            case (nil, false): throw EngineError.other("the layer has nothing to rasterize")
            case (nil, true): throw EngineError.other("none of the selected layers has anything to rasterize")
            }
        }
        let active = s.active?.activeLayer.flatMap { done.contains($0) ? $0 : nil }
        return ["layer": .id(active ?? first), "layers": .ids(done)]
    }

    static func rasterizeAll(_ s: Session) throws -> JSONValue {
        let ids = s.active?.doc.walk().map(\.layer.id) ?? []
        let key = stepKey(s, "rasterizeAll")
        var n = 0
        // Every sub-step shares one history entry via the coalescing key.
        for id in ids where try rasterizeOne(s, id, only: nil, key: key) { n += 1 }
        return ["rasterized": .int(n)]
    }

    // MARK: Transform presets

    /// Rotate 180° / 90°, Flip: `edit.transform` with an exact matrix about the frame's centre and
    /// nearest sampling. A targeted alpha channel, the Quick Mask or an unlinked layer mask turns
    /// by itself (#2835) (photocraft `transform_preset`).
    static func transformPreset(_ s: Session, _ p: JSONValue, _ kind: String) throws -> JSONValue {
        guard let d = s.active else { throw EngineError.noDocument }
        let b: PixelRect
        var params: JSONValue
        if let surf = try TransformCommands.loneTarget(d.doc, d.activeLayer, p) {
            b = TransformCommands.targetBounds(d.doc, surf)
            params = ["target": p["target"] ?? .null]
        } else {
            guard let id = d.activeLayer else { throw EngineError.other("no active layer") }
            guard let l = d.doc.layer(id) else { throw EngineError.noLayer(id) }
            b = TransformCommands.transformBounds(d.doc, l)
            params = ["layer": .id(id)]
        }
        if b.isEmpty { throw EngineError.other("nothing to transform") }
        // Integer offsets keep these exact pixel permutations on the grid (nearest sampling).
        let (sx, sy) = (Double(b.x0) + Double(b.x1), Double(b.y0) + Double(b.y1))
        let (cx, cy) = (sx / 2, sy / 2)
        let m: [Double]
        switch kind {
        case "rotate180": m = [-1, 0, 0, -1, sx, sy]
        case "rotate90Cw": m = [0, 1, -1, 0, (cx + cy).rounded(), (cy - cx).rounded()]
        case "rotate90Ccw": m = [0, -1, 1, 0, (cx - cy).rounded(), (cx + cy).rounded()]
        case "flipHorizontal": m = [-1, 0, 0, 1, sx, 0]
        default: m = [1, 0, 0, -1, 0, sy]
        }
        params = params.setting("matrix", .doubles(m)).setting("interpolation", "nearest")
        return try s.execute("edit.transform", params)
    }

    // MARK: Registry

    /// The presets' params: like Free Transform, they follow the Channels and Layers panel target.
    static let transformTarget = #"{"target":"pixels"|"mask"|"quickMask"|{"channel":i}=Channels panel target (an unlinked mask, an alpha channel or the Quick Mask turns alone)}"#

    static func register(into r: inout CommandRegistry) {
        r.add(CommandSpec("edit.stroke", "Stroke…", menu: ["Edit"],
                          params: ##"{"width":1..250=1,"color":"#rrggbb|[r,g,b,a]"=foreground,"location":"inside|center|outside"="center","mode":"any layer blend mode"="normal","opacity":0..100=100,"preserveTransparency":bool=false}"##,
                          module: m, enabled: Pre.hasPixelLayer, run: stroke))
        for (kind, label) in [("rotate180", "Rotate 180°"), ("rotate90Cw", "Rotate 90° Clockwise"), ("rotate90Ccw", "Rotate 90° Counter Clockwise"),
                              ("flipHorizontal", "Flip Horizontal"), ("flipVertical", "Flip Vertical")] {
            r.add(CommandSpec("edit.transform." + kind, label, menu: ["Edit", "Transform"], params: transformTarget, module: m,
                              enabled: TransformCommands.hasLayer) { s, p in try transformPreset(s, p, kind) })
        }
        let pasteParams = #"{"center":[x,y]?,"# + EditCommands.pasteTarget + "}"
        r.add(CommandSpec("edit.pasteSpecial.pasteInto", "Paste Into", menu: ["Edit", "Paste Special"], shortcut: "Cmd+Alt+Shift+V", params: pasteParams,
                          module: m, enabled: hasClipAndSelection) { s, p in try pasteInto(s, p, outside: false) })
        r.add(CommandSpec("edit.pasteSpecial.pasteOutside", "Paste Outside", menu: ["Edit", "Paste Special"], params: pasteParams,
                          module: m, enabled: hasClipAndSelection) { s, p in try pasteInto(s, p, outside: true) })
        r.add(CommandSpec("select.reselect", "Reselect", menu: ["Select"], shortcut: "Cmd+Shift+D", module: m, enabled: canReselect) { s, _ in
            guard let sel = reselectTarget(s) else { throw EngineError.other("there is no selection to restore") }
            try s.edit("Reselect") { doc, _ in doc.selection = sel }
            return ["selected": true]
        })
        r.add(CommandSpec("image.adjustments.equalize", "Equalize", menu: ["Image", "Adjustments"], module: m, enabled: Pre.hasPixelLayer, run: equalize))
        r.add(CommandSpec("image.revealAll", "Reveal All", menu: ["Image"], module: m, enabled: Pre.hasDoc) { s, _ in
            guard let d = s.active else { throw EngineError.noDocument }
            let all = revealAllBounds(d.doc)
            if all == d.doc.bounds { return ["changed": false] }
            try s.execute("image.crop", ["x": .int(Int(all.x0)), "y": .int(Int(all.y0)), "width": .int(all.width), "height": .int(all.height),
                                         "deleteCroppedPixels": false])
            return ["changed": true]
        })
        r.add(CommandSpec("layer.new.layerFromBackground", "Layer From Background…", menu: ["Layer", "New"], module: m, enabled: hasBackground) { s, _ in
            try layerFromBackground(s)
        })
        r.add(CommandSpec("layer.layerStyle.copyLayerStyle", "Copy Layer Style", menu: ["Layer", "Layer Style"], params: #"{"layer":id?}"#,
                          module: m, enabled: Pre.hasLayer) { s, p in
            let id = try s.layerParam(p)
            guard let l = s.active?.doc.layer(id) else { throw EngineError.noLayer(id) }
            s.state[StyleClipboardKey.self] = StyleClip(effects: l.effects, blend: l.blend, fillOpacity: l.fillOpacity, advanced: l.advanced)
            return .null
        })
        r.add(CommandSpec("layer.layerStyle.pasteLayerStyle", "Paste Layer Style", menu: ["Layer", "Layer Style"],
                          params: #"{"layer":id?} (no layer: every selected layer but the Background)"#, module: m,
                          enabled: { s, p in Pre.hasLayer(s, p) ?? (s.state[StyleClipboardKey.self] == nil ? "no layer style has been copied" : nil) }) { s, p in
            let ids = try styleTargets(s, p) { _ in true }
            guard let style = s.state[StyleClipboardKey.self] else { throw EngineError.other("no layer style has been copied") }
            try s.edit("Paste Layer Style") { doc, _ in
                // A style copied from a document in another mode takes this one's colours.
                var fx = style.effects
                let mode = doc.mode
                fx.items = fx.items.map { $0.inMode(mode) }
                for id in ids {
                    guard doc.updateLayer(id, { (l: inout Layer) -> Void in
                        l.effects = fx
                        l.blend = style.blend
                        l.fillOpacity = style.fillOpacity
                        l.advanced = style.advanced
                    }) != nil else { throw EngineError.noLayer(id) }
                }
            }
            return .null
        })
        r.add(CommandSpec("layer.layerStyle.hideAllEffects", "Hide All Effects", menu: ["Layer", "Layer Style"], module: m, enabled: Pre.hasDoc) { s, _ in
            try setAllEffects(s, false)
        })
        r.add(CommandSpec("layer.layerStyle.showAllEffects", "Show All Effects", module: m, enabled: Pre.hasDoc) { s, _ in try setAllEffects(s, true) })
        r.add(CommandSpec("layer.layerMask.enabled", "Disable Layer Mask", menu: ["Layer", "Layer Mask"], params: #"{"layer":id?,"enabled":bool? (default: toggle)}"#,
                          module: m, enabled: hasMask) { s, p in try toggleMask(s, p, "enabled") })
        r.add(CommandSpec("layer.layerMask.linked", "Unlink Layer Mask", menu: ["Layer", "Layer Mask"], params: #"{"layer":id?,"linked":bool? (default: toggle)}"#,
                          module: m, enabled: hasMask) { s, p in try toggleMask(s, p, "linked") })
        let each = #"{"layer":id?} (no layer: every selected layer it applies to)"#
        r.add(CommandSpec("layer.rasterize.layer", "Layer", menu: ["Layer", "Rasterize"], params: each, module: m, enabled: Pre.hasLayer) { s, p in
            try rasterize(s, p, only: nil)
        })
        r.add(CommandSpec("layer.rasterize.allLayers", "All Layers", menu: ["Layer", "Rasterize"], module: m, enabled: Pre.hasDoc) { s, _ in try rasterizeAll(s) })
        for (id, label, kind) in [("layer.rasterize.type", "Type", "type"), ("layer.rasterize.fillContent", "Fill Content", "fill"),
                                  ("layer.rasterize.smartObject", "Smart Object", "smart")] {
            r.add(CommandSpec(id, label, menu: ["Layer", "Rasterize"], params: each, module: m, enabled: Pre.hasLayer) { s, p in try rasterize(s, p, only: kind) })
        }
        r.add(CommandSpec("layer.delete.hiddenLayers", "Hidden Layers", menu: ["Layer", "Delete"], module: m, enabled: Pre.hasDoc) { s, _ in
            try deleteWhere(s, "Delete Hidden Layers") { !$0.visible }
        })
        r.add(CommandSpec("file.scripts.deleteAllEmptyLayers", "Delete All Empty Layers", menu: ["File", "Scripts"], module: m, enabled: Pre.hasDoc) { s, _ in
            try deleteWhere(s, "Delete All Empty Layers", isEmptyLayer)
        })
        r.add(CommandSpec("layer.ungroupLayers", "Ungroup Layers", menu: ["Layer"], shortcut: "Cmd+Shift+G", params: #"{"layer":id?}"#, module: m,
                          enabled: { s, _ in
                              switch s.activeLayer() {
                              case .failure(let e): return e.description
                              case .success(let l): return l.isGroup ? nil : "the active layer is not a group"
                              }
                          }, run: ungroup))
        r.add(CommandSpec("layer.hideLayers", "Hide Layers", menu: ["Layer"], shortcut: "Cmd+,",
                          params: #"{"layer":id?} (shows them instead when every targeted layer is already hidden, so ⌘, toggles)"#,
                          module: m, enabled: Pre.hasLayer, run: hideOrShow))
        r.add(CommandSpec("layer.showLayers", "Show Layers", params: #"{"layer":id?}"#, module: m, enabled: Pre.hasLayer) { s, p in try setVisible(s, p, true) })
        r.add(CommandSpec("layer.toggleLockTransparency", "Lock Transparent Pixels", shortcut: "/",
                          params: #"{"layer":id?} (toggles; several layers selected: locks them all unless every one is locked)"#,
                          module: m, enabled: Pre.hasLayer, run: toggleLockTransparency))
        r.add(CommandSpec("layer.showOnly", "Show Only This Layer",
                          params: #"{"layer":id?} → {shownAlone} (⌥-click a layer's eye; again restores the other layers' visibility)"#,
                          module: m, enabled: Pre.hasLayer, run: showOnly))
        r.add(CommandSpec("filter.blur.average", "Average", menu: ["Filter", "Blur"], module: m, enabled: Pre.hasPixelLayer, run: average))
        r.add(CommandSpec("filter.render.clouds", "Clouds", menu: ["Filter", "Render"], params: #"{"seed":u32=0}"#, module: m, enabled: Pre.hasPixelLayer) { s, p in
            try clouds(s, p, difference: false)
        })
        r.add(CommandSpec("filter.render.differenceClouds", "Difference Clouds", menu: ["Filter", "Render"], params: #"{"seed":u32=0}"#, module: m,
                          enabled: Pre.hasPixelLayer) { s, p in try clouds(s, p, difference: true) })
    }
}
