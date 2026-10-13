// Port of photocraft-compose (crates/compose/src/lib.rs bounds and layer predicates, bounds.rs, advanced.rs predicates), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The questions the planner asks of a layer before emitting ops: where its pixels are (content
// bounds cached per tile generation, so a 4096² layer is scanned once, not every frame), whether
// it can contribute to a region at all, whether it hides everything beneath it, what its effects
// are built from, and the frame its fill is laid out in.

import Foundation
import PCDocument
import PCFoundation

/// `Surface.contentBounds` with each tile's scan cached by (tile generation, default pixel)
/// (photocraft `bounds::content_bounds`), plus a cheap order-independent surface fingerprint.
public enum ContentBounds {
    private struct Key: Hashable { let generation: UInt64; let defaultPixel: [UInt8] }
    nonisolated(unsafe) private static var cache: [Key: PixelRect] = [:]
    private static let lock = NSLock()

    /// Tight bounds of the pixels that differ from the surface's default pixel.
    public static func of(_ s: Surface) -> PixelRect {
        if s.tileCount == 0 { return .empty }
        let dp = s.defaultPixel
        var out = PixelRect.empty
        var todo: [(TileCoord, Tile)] = []
        lock.lock()
        if cache.count > 1 << 16 { cache.removeAll() }
        s.forEachTile { c, t in
            if let b = cache[Key(generation: t.generation, defaultPixel: dp)] {
                if !b.isEmpty { out = out.union(b.offsetBy(dx: c.rect.x0, dy: c.rect.y0)) }
            } else {
                todo.append((c, t))
            }
        }
        lock.unlock()
        if todo.isEmpty { return out }
        let bpp = s.format.bytesPerPixel
        var found = [PixelRect](repeating: .empty, count: todo.count)
        found.withUnsafeMutableBufferPointer { fp in
            let F = UnsafeSendable(fp)
            let T = todo
            DispatchQueue.concurrentPerform(iterations: T.count) { i in
                F.value[i] = scan(T[i].1, dp, bpp)
            }
        }
        lock.lock()
        for (i, (c, t)) in todo.enumerated() {
            cache[Key(generation: t.generation, defaultPixel: dp)] = found[i]
            if !found[i].isEmpty { out = out.union(found[i].offsetBy(dx: c.rect.x0, dy: c.rect.y0)) }
        }
        lock.unlock()
        return out
    }

    /// Tile-local bounds of the pixels of `t` that differ from `dp`.
    private static func scan(_ t: Tile, _ dp: [UInt8], _ bpp: Int) -> PixelRect {
        let ts = Int(tileSize)
        var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0
        t.bytes.withUnsafeBytes { p in
            dp.withUnsafeBytes { d in
                func differs(_ o: Int) -> Bool {
                    for k in 0..<bpp where p[o + k] != d[k] { return true }
                    return false
                }
                for y in 0..<ts {
                    let row = y * ts * bpp
                    var first = -1
                    for x in 0..<ts where differs(row + x * bpp) { first = x; break }
                    if first < 0 { continue }
                    var last = first
                    var x = ts - 1
                    while x > first { if differs(row + x * bpp) { last = x; break }; x -= 1 }
                    x0 = min(x0, first); x1 = max(x1, last + 1)
                    y0 = min(y0, y); y1 = y + 1
                }
            }
        }
        return x0 == Int.max ? .empty : PixelRect(x0: Int32(x0), y0: Int32(y0), x1: Int32(x1), y1: Int32(y1))
    }

    /// Whether `s` has a materialised tile meeting `r` (photocraft `Surface::has_tiles_in`).
    public static func hasTiles(_ s: Surface, in r: PixelRect) -> Bool {
        if r.isEmpty || s.tileCount == 0 { return false }
        let x0 = r.x0 >> 8, y0 = r.y0 >> 8, x1 = (r.x1 - 1) >> 8, y1 = (r.y1 - 1) >> 8
        let span = (Int(x1) - Int(x0) + 1) * (Int(y1) - Int(y0) + 1)
        if span <= s.tileCount {
            for ty in y0...y1 { for tx in x0...x1 where s.tile(TileCoord(tx: tx, ty: ty)) != nil { return true } }
            return false
        }
        var hit = false
        s.forEachTile { c, _ in if !hit && c.tx >= x0 && c.tx <= x1 && c.ty >= y0 && c.ty <= y1 { hit = true } }
        return hit
    }

    /// Identity of a surface's pixels: format, default pixel and every tile's (coordinate,
    /// generation), combined order-independently.
    public static func fingerprint(_ s: Surface) -> UInt64 {
        var h = Fingerprint()
        h.mix(UInt64(s.format.mode.rawValue) << 16 | UInt64(s.format.sample.bytes) << 8 | (s.format.alpha ? 1 : 0))
        for b in s.defaultPixel { h.mix(UInt64(b)) }
        var acc = UInt64(s.tileCount)
        s.forEachTile { c, t in
            var x = t.generation ^ (UInt64(UInt32(bitPattern: c.tx)) << 40) ^ (UInt64(UInt32(bitPattern: c.ty)) << 8)
            x = x &* 0x9e37_79b9_7f4a_7c15
            acc = acc &+ (x ^ (x >> 29))
        }
        h.mix(acc)
        return h.value
    }
}

/// FNV-1a style 64-bit mixing (stable within a process run).
struct Fingerprint {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func mix(_ v: UInt64) {
        value = (value ^ v) &* 0x0100_0000_01b3
        value ^= value >> 31
    }
    mutating func mix(_ r: PixelRect) {
        mix(UInt64(UInt32(bitPattern: r.x0)) << 32 | UInt64(UInt32(bitPattern: r.y0)))
        mix(UInt64(UInt32(bitPattern: r.x1)) << 32 | UInt64(UInt32(bitPattern: r.y1)))
    }
    mutating func mix<H: Hashable>(hashable v: H) {
        var hasher = Hasher()
        hasher.combine(v)
        mix(UInt64(bitPattern: Int64(hasher.finalize())))
    }
    mutating func mix(_ f: Float) { mix(UInt64(f.bitPattern)) }
}

extension PixelRect {
    /// The rect grown by `d` on every side; empty stays empty (photocraft `Rect::inflate`).
    func inflated(_ d: Int32) -> PixelRect { isEmpty ? self : outset(by: d) }
}

/// Layer predicates of compose's `lib.rs` / `advanced.rs`. `pixels` returns the pixels a layer
/// shows (its surface, or the rasterizer's for uncached type / shape / smart layers).
public enum LayerGeometry {
    public typealias Pixels = (Layer) -> Surface?

    /// The layer's own stored pixels (no rasterizer).
    public static let storedPixels: @Sendable (Layer) -> Surface? = { $0.surface }

    // MARK: Effects and advanced blending

    /// `effects::has_effects`.
    public static func hasEffects(_ l: Layer) -> Bool { l.effects.hasVisibleEffects }

    /// `effects::margin`.
    public static func margin(_ l: Layer) -> Int32 { EffectMath.margin(l.effects) }

    /// `advanced::shapeless`: Transparency Shapes Layer off on a layer with a knockout or effects.
    public static func shapeless(_ l: Layer) -> Bool {
        !l.advanced.transparencyShapes && (l.advanced.knockout != .none || hasEffects(l))
    }

    /// `advanced::hides_effects`.
    public static func hidesEffects(_ l: Layer) -> Bool {
        let a = l.advanced
        return hasEffects(l) && ((a.layerMaskHidesEffects && l.mask?.enabled == true) || (a.vectorMaskHidesEffects && l.vectorMask?.enabled == true))
    }

    /// `advanced::effects_source`: the layer without the masks that hide its effects.
    public static func effectsSource(_ l: Layer) -> Layer {
        if !hidesEffects(l) { return l }
        var c = l
        if c.advanced.layerMaskHidesEffects { c.mask = nil }
        if c.advanced.vectorMaskHidesEffects { c.vectorMask = nil }
        return c
    }

    /// `advanced::clips_individually`: Blend Clipped Layers as Group off with visible clipped layers.
    public static func clipsIndividually(_ l: Layer, _ clipped: ArraySlice<Layer>) -> Bool {
        if case .adjustment = l.content { return false }
        return !l.advanced.blendClipped && clipped.contains { $0.visible }
    }

    /// `advanced::needs_floor`.
    public static func needsFloor(_ layers: ArraySlice<Layer>) -> Bool {
        layers.contains { $0.visible && !$0.clipped && $0.advanced.knockout == .shallow }
    }

    /// `effect_outline`: a filled shape's path when its effects follow the outline.
    public static func effectOutline(_ l: Layer) -> VectorPath? {
        guard case .shape(let sh) = l.content else { return nil }
        let strokeInside = sh.stroke.map { $0.width <= 0 || $0.align == .inside } ?? true
        return sh.fill != nil && strokeInside && !sh.path.isEmpty && !sh.path.inverted ? sh.path : nil
    }

    /// `paint_bounds`: a shape layer's path bounds truncated to whole pixels.
    public static func paintBounds(_ l: Layer) -> PixelRect? {
        guard case .shape(let sh) = l.content, let b = sh.path.controlBounds else { return nil }
        let r = PixelRect(x0: Int32(clamping: Int64(b.x.rounded(.down))), y0: Int32(clamping: Int64(b.y.rounded(.down))),
                          x1: Int32(clamping: Int64(b.z.rounded(.down))), y1: Int32(clamping: Int64(b.w.rounded(.down))))
        return r.isEmpty ? nil : r
    }

    // MARK: Bounds

    /// `layer_bounds`: a layer's own pixels (group: union of visible children; fill: the canvas;
    /// artboard: its board; Transparency Shapes Layer off: the canvas).
    public static func layerBounds(_ l: Layer, canvas: PixelRect, pixels: Pixels = storedPixels) -> PixelRect {
        if shapeless(l) { return canvas }
        switch l.content {
        case .group(let g):
            if let ab = g.artboard { return ab.rect }
            return g.children.filter(\.visible).reduce(PixelRect.empty) { $0.union(layerBounds($1, canvas: canvas, pixels: pixels)) }
        case .fill: return canvas
        default:
            let b = pixels(l).map(ContentBounds.of) ?? .empty
            if hasEffects(l), effectOutline(l) != nil, let p = paintBounds(l) { return b.union(p) }
            return b
        }
    }

    /// `effect_source_bounds`: where a layer's effects take their shape from.
    public static func effectSourceBounds(_ l: Layer, canvas: PixelRect, pixels: Pixels = storedPixels) -> PixelRect {
        if case .group(let g) = l.content, g.artboard == nil, !shapeless(l) {
            return g.children.filter(\.visible).reduce(PixelRect.empty) { acc, c in
                let m = hasEffects(c) ? margin(c) : 0
                return acc.union(effectSourceBounds(c, canvas: canvas, pixels: pixels).inflated(m))
            }
        }
        return layerBounds(l, canvas: canvas, pixels: pixels)
    }

    /// `transparent_outside`: every surface the layer draws from is transparent by default.
    public static func transparentOutside(_ l: Layer, pixels: Pixels = storedPixels) -> Bool {
        switch l.content {
        case .group(let g): return g.children.filter(\.visible).allSatisfy { transparentOutside($0, pixels: pixels) }
        case .fill, .adjustment: return true
        default:
            guard let s = pixels(l) else { return true }
            return s.format.alpha && (s.defaultPixelValue.last ?? 0) <= 0
        }
    }

    /// `shapeless_stroke_bounds`: Transparency Shapes Layer off with only local strokes.
    public static func shapelessStrokeBounds(_ l: Layer, pixels: Pixels = storedPixels) -> PixelRect? {
        let a = l.advanced
        if a.transparencyShapes || a.knockout != .none || a.blendInterior || l.clipped || !l.blendIf.isDefault
            || l.mask?.enabled == true || l.vectorMask?.enabled == true || !transparentOutside(l, pixels: pixels)
            || !EffectMath.mapsAreLocal(l.effects) {
            return nil
        }
        let enabled = l.effects.items.filter(\.isEnabled)
        if !l.effects.enabled || enabled.isEmpty { return nil }
        if enabled.contains(where: { if case .stroke = $0 { return false } else { return true } }) { return nil }
        switch l.content {
        case .raster, .text, .shape, .smart:
            let b = pixels(l).map(ContentBounds.of) ?? .empty
            if effectOutline(l) != nil, let p = paintBounds(l) { return b.union(p) }
            return b
        default: return nil
        }
    }

    /// `empty_in`: the layer has nothing to contribute in `rect`.
    public static func emptyIn(_ l: Layer, _ rect: PixelRect, pixels: Pixels = storedPixels) -> Bool {
        if hasEffects(l) {
            let huge = PixelRect(x0: Int32.min / 4, y0: Int32.min / 4, x1: Int32.max / 4, y1: Int32.max / 4)
            let b = shapelessStrokeBounds(l, pixels: pixels) ?? effectSourceBounds(l, canvas: huge, pixels: pixels)
            return transparentOutside(l, pixels: pixels) && b.inflated(margin(l)).intersect(rect).isEmpty
        }
        switch l.content {
        case .raster, .text, .shape, .smart:
            guard let s = pixels(l) else { return true }
            return !ContentBounds.hasTiles(s, in: rect) && (s.defaultPixelValue.last ?? 0) <= 0 && s.format.alpha
        default: return false
        }
    }

    /// `composite_bounds`: where the layer (and its effects) can be non-transparent; nil = anywhere.
    public static func compositeBounds(_ l: Layer, canvas: PixelRect, pixels: Pixels = storedPixels) -> PixelRect? {
        if !transparentOutside(l, pixels: pixels) { return nil }
        var own = PixelRect.empty
        switch l.content {
        case .group(let g) where g.artboard == nil:
            for c in g.children where c.visible {
                guard let b = compositeBounds(c, canvas: canvas, pixels: pixels) else { return nil }
                own = own.union(b)
            }
        case .adjustment: own = .empty
        default: own = layerBounds(l, canvas: canvas, pixels: pixels)
        }
        if own.isEmpty { return .empty }
        return own.inflated(hasEffects(l) ? margin(l) : 0).intersect(canvas)
    }

    /// `change_bounds`: pixels showing / hiding / restyling the layer can change; nil = anywhere.
    public static func changeBounds(_ l: Layer, canvas: PixelRect, pixels: Pixels = storedPixels) -> PixelRect? {
        func reachesBelow(_ l: Layer) -> Bool {
            switch l.content {
            case .adjustment: return !l.clipped
            case .group(let g) where l.blend == .passThrough: return g.children.contains(where: reachesBelow)
            default: return false
            }
        }
        if case .adjustment = l.content { return nil }
        if reachesBelow(l) { return nil }
        return compositeBounds(l, canvas: canvas, pixels: pixels)
    }

    /// `fill_frame`: the frame a fill layer's gradient / linked pattern is laid out in.
    public static func fillFrame(_ l: Layer, canvas: PixelRect) -> PixelRect {
        var frame = canvas
        if case .fill(.gradient(let g)) = l.content, !g.align { return frame }
        if let m = l.mask, m.enabled, (m.surface.defaultPixelValue.first ?? 1) <= 0 {
            let b = ContentBounds.of(m.surface).intersect(canvas)
            if !b.isEmpty { frame = b }
        }
        if let vm = l.vectorMask, vm.enabled, !vm.path.inverted, let cb = vm.path.controlBounds {
            let b = PixelRect(x0: Int32(clamping: Int64(cb.x.rounded(.down))), y0: Int32(clamping: Int64(cb.y.rounded(.down))),
                              x1: Int32(clamping: Int64(cb.z.rounded(.up))), y1: Int32(clamping: Int64(cb.w.rounded(.up)))).intersect(frame)
            if !b.isEmpty { frame = b }
        }
        return frame
    }

    // MARK: Blending options

    /// `channel_weights`: Blending Options › Channels as display-RGB weights (nil: all blend).
    public static func channelWeights(_ l: Layer, mode: ColorMode) -> SIMD3<Float>? {
        let x = l.excludedChannels
        if x == 0 { return nil }
        func keep(_ bit: UInt32) -> Float { x & (1 << bit) != 0 ? 0 : 1 }
        let w: SIMD3<Float>
        switch mode {
        case .rgb: w = SIMD3(keep(0), keep(1), keep(2))
        case .grayscale, .duotone: w = SIMD3(repeating: keep(0))
        default: return nil
        }
        return w == SIMD3(repeating: 1) ? nil : w
    }

    /// `blend_if_active`.
    public static func blendIfActive(_ l: Layer, mode: ColorMode) -> Bool {
        (mode == .rgb || mode == .grayscale || mode == .duotone) && !l.blendIf.isDefault
    }

    /// `occludes_below`: an opaque, plain, Normal fill layer replaces everything beneath it.
    public static func occludesBelow(_ l: Layer, mode: ColorMode) -> Bool {
        guard case .fill(let f) = l.content else { return false }
        let opaque: Bool
        switch f {
        case .solid(let c): opaque = c.alpha >= 1
        case .gradient(let g): opaque = !g.stops.isEmpty && g.stops.allSatisfy { $0.color.alpha >= 1 } && g.opacityStops.allSatisfy { $0.opacity >= 1 }
        case .pattern: opaque = false
        }
        let cached = l.fillCache.map { $0.fill == f } ?? false
        return opaque && !cached && l.visible && !l.clipped && l.blend == .normal && l.opacity >= 1 && l.fillOpacity >= 1
            && l.mask?.enabled != true && l.vectorMask?.enabled != true && !hasEffects(l) && l.excludedChannels == 0
            && !blendIfActive(l, mode: mode)
    }

    /// Type layers mix coverage at the text gamma.
    public static func textGamma(_ l: Layer, gamma: Float) -> Float {
        if case .text = l.content { return gamma }
        return 1
    }
}
