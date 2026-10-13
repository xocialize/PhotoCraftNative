// Port of photocraft-compose (crates/compose/src/lib.rs `effect_shape`, `render_content` leaves, multichannel.rs, gradient_fill.rs `render_cmyk_fill`, pattern.rs `pattern_rgba`, shape_split.rs) and photocraft-vector (`CompiledVectorMask`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The leaves of a document plan. Stored pixels (raster layers, masks, fill caches, type / shape /
// smart-object caches) are served straight from their `Surface` (the Metal residency cache keys
// their tiles by generation). Derived leaves (vector-mask coverage, effect shapes, Multichannel
// inks, native CMYK fills) carry a version fingerprint computed at plan time and are built on
// first use (each under its own lock, so tiles that need different leaves never wait on each
// other), then kept in a `DocumentLeafCache` shared across renders: an unchanged layer costs a
// fingerprint, not a rebuild. Effect shapes of groups are rendered by a nested CPU plan, as
// photocraft's `effect_shape` renders the group's content.

import Foundation
import PCDocument
import PCFoundation

/// Leaves, rasterized layers, split shapes and pattern tiles kept across renders (bounded by bytes).
public final class DocumentLeafCache: @unchecked Sendable {
    /// Bytes derived leaves may hold (rasterized layers and split shapes are counted too).
    public var budget: Int
    private let lock = NSLock()
    private var tick: UInt64 = 0

    struct LeafKey: Hashable { let id: LeafID; let version: UInt64 }
    private var leaves: [LeafKey: (leaf: RenderLeaf, bytes: Int, tick: UInt64)] = [:]
    private var rasters: [LayerId: (content: LayerContent, surface: Surface?)] = [:]
    struct SplitKey: Hashable { let layer: LayerId; let canvas: PixelRect; let depth: SampleType }
    private var splits: [SplitKey: (shape: ShapeLayer, parts: (fill: Surface, stroke: Surface)?)] = [:]
    struct PatternKey: Hashable { let id: String; let name: String; let mode: ColorMode; let native: NativeSpace; let version: UInt64 }
    private var patterns: [PatternKey: PatternTile] = [:]

    public init(budget: Int = 1 << 30) { self.budget = budget }

    public func purge() {
        lock.lock(); defer { lock.unlock() }
        leaves.removeAll(); rasters.removeAll(); splits.removeAll(); patterns.removeAll()
    }

    /// Bytes held by derived leaves.
    public var bytes: Int {
        lock.lock(); defer { lock.unlock() }
        return leaves.values.reduce(0) { $0 + $1.bytes }
    }

    func leaf(_ k: LeafKey) -> RenderLeaf? {
        lock.lock(); defer { lock.unlock() }
        guard let e = leaves[k] else { return nil }
        tick += 1
        leaves[k] = (e.leaf, e.bytes, tick)
        return e.leaf
    }

    func store(_ k: LeafKey, _ leaf: RenderLeaf) {
        let bytes: Int
        switch leaf {
        case .image(let img, _, _): bytes = img.data.count * 4
        case .surface: bytes = 0
        }
        lock.lock(); defer { lock.unlock() }
        tick += 1
        // One version per leaf id is enough: older versions of the same leaf go at once.
        for old in leaves.keys where old.id == k.id && old.version != k.version { leaves.removeValue(forKey: old) }
        leaves[k] = (leaf, bytes, tick)
        var total = leaves.values.reduce(0) { $0 + $1.bytes }
        while total > budget && leaves.count > 1 {
            guard let old = leaves.min(by: { $0.value.tick < $1.value.tick }), old.key != k else { break }
            total -= old.value.bytes
            leaves.removeValue(forKey: old.key)
        }
    }

    /// Pixels of an uncached type / shape / smart-object layer, rasterized once per content state.
    func raster(_ l: Layer, in doc: Document, _ r: any LayerRasterizer) -> Surface? {
        lock.lock()
        if let e = rasters[l.id], e.content == l.content { lock.unlock(); return e.surface }
        lock.unlock()
        let s = r.rasterize(l, in: doc)
        lock.lock()
        rasters[l.id] = (l.content, s)
        lock.unlock()
        return s
    }

    /// A stroked shape's (fill, stroke) over `canvas` (`shape_split::split`).
    func split(_ l: Layer, _ sh: ShapeLayer, canvas: PixelRect, depth: SampleType, _ r: any LayerRasterizer) -> (fill: Surface, stroke: Surface)? {
        let key = SplitKey(layer: l.id, canvas: canvas, depth: depth)
        lock.lock()
        if let e = splits[key], e.shape == sh { lock.unlock(); return e.parts }
        lock.unlock()
        let fmt = PixelFormat(mode: .rgb, sample: depth, alpha: true)
        var fillOnly = sh, strokeOnly = sh
        fillOnly.stroke = nil; fillOnly.cache = nil
        strokeOnly.fill = nil; strokeOnly.cache = nil
        var parts: (fill: Surface, stroke: Surface)?
        if let f = r.renderShape(fillOnly, format: fmt, clip: canvas), var s = r.renderShape(strokeOnly, format: fmt, clip: canvas) {
            if let cache = sh.cache { ShapeSplit.fitStroke(fill: f, stroke: &s, cache: cache, canvas: canvas) }
            parts = (f, s)
        }
        lock.lock()
        splits[key] = (sh, parts)
        lock.unlock()
        return parts
    }

    /// A document pattern as painted into a `mode` document (`pattern_rgba` + `Tile::new_in`).
    func pattern(_ p: Pattern, mode: ColorMode, native: NativeSpace = .none) -> PatternTile? {
        guard p.isPaintable else { return nil }
        let version = ContentBounds.fingerprint(p.surface)
        let key = PatternKey(id: p.id, name: p.name, mode: mode, native: native, version: version)
        lock.lock()
        if let t = patterns[key] { lock.unlock(); return t }
        lock.unlock()
        if native != .none {
            let t = NativeConvert.pattern(p, native, version: version)
            lock.lock(); if patterns.count > 64 { patterns.removeAll() }; patterns[key] = t; lock.unlock()
            return t
        }
        var px = p.surface.readRGBA(p.rect)
        let paintsIn = mode == .grayscale || mode == .bitmap || mode == .duotone || mode == .cmyk
        if paintsIn && p.surface.format.mode != mode {
            px = px.map { q in
                let rgb = SIMD3(q.x, q.y, q.z)
                switch mode {
                case .cmyk: return SIMD4(ColorConvert.cmykToRGB(ColorConvert.rgbToCMYK(rgb)), q.w)
                default: return SIMD4(SIMD3(repeating: ColorConvert.rgbToGray(rgb)), q.w)
                }
            }
        }
        let t = PatternTile(id: p.id, name: p.name, width: Int(p.width), height: Int(p.height), straight: px, version: version)
        lock.lock()
        if patterns.count > 64 { patterns.removeAll() }
        patterns[key] = t
        lock.unlock()
        return t
    }
}

/// The `RenderSource` of a document plan (see the file header).
public final class DocumentRenderSource: RenderSource, @unchecked Sendable {
    /// How a derived leaf is built (`self` gives access to the other leaves and nested renders).
    typealias Recipe = @Sendable (DocumentRenderSource) throws -> RenderLeaf

    final class Derived: @unchecked Sendable {
        let version: UInt64
        let recipe: Recipe
        let lock = NSLock()
        var value: RenderLeaf?
        init(version: UInt64, recipe: @escaping Recipe) { self.version = version; self.recipe = recipe }
    }

    public let context: RenderContext
    let document: Document
    let cache: DocumentLeafCache
    let rasterizer: any LayerRasterizer
    /// Renders nested plans (group effect shapes).
    let subRenderer: CPUCompositor
    private(set) var direct: [LeafID: RenderLeaf] = [:]
    private(set) var derived: [LeafID: Derived] = [:]
    private let missLock = NSLock()
    private var missList: [RasterMiss] = []

    init(document: Document, context: RenderContext, cache: DocumentLeafCache, rasterizer: any LayerRasterizer, subRenderer: CPUCompositor) {
        self.document = document; self.context = context; self.cache = cache; self.rasterizer = rasterizer; self.subRenderer = subRenderer
    }

    // MARK: Planning-time registration

    func register(_ id: LeafID, _ leaf: RenderLeaf) { direct[id] = leaf }

    func register(_ id: LeafID, version: UInt64, _ recipe: @escaping Recipe) {
        if let d = derived[id], d.version == version { return }
        derived[id] = Derived(version: version, recipe: recipe)
    }

    func isRegistered(_ id: LeafID) -> Bool { direct[id] != nil || derived[id] != nil }

    // MARK: RenderSource

    public func leaf(_ id: LeafID) -> RenderLeaf? {
        if let l = direct[id] { return l }
        guard let d = derived[id] else { return nil }
        d.lock.lock(); defer { d.lock.unlock() }
        if let v = d.value { return v }
        let key = DocumentLeafCache.LeafKey(id: id, version: d.version)
        if let hit = cache.leaf(key) { d.value = hit; return hit }
        guard var made = try? d.recipe(self) else { return nil }
        // The plan-time version identifies the pixels (GPU residency keys images by it).
        if case let .image(img, outside, _) = made { made = .image(img, outside: outside, version: d.version) }
        cache.store(key, made)
        d.value = made
        return made
    }

    public func leafVersion(_ id: LeafID) -> UInt64? {
        if let l = direct[id] { return LeafReader.version(l) }
        return derived[id]?.version
    }

    public func pattern(id: String, name: String) -> PatternTile? {
        guard let p = Pattern.find(document.patterns, id: id, name: name) else { return nil }
        return cache.pattern(p, mode: document.mode, native: context.native)
    }

    // MARK: Misses

    /// What the rasterizer could not provide for this plan so far (derived leaves report theirs
    /// when they are built, i.e. after a render).
    public var misses: [RasterMiss] {
        missLock.lock(); defer { missLock.unlock() }
        return missList
    }

    func recordMiss(_ m: RasterMiss) {
        missLock.lock()
        if !missList.contains(m) { missList.append(m) }
        missLock.unlock()
        (rasterizer as? PlaceholderRasterizer)?.record(m)
    }

    // MARK: Nested renders

    /// Renders a single-buffer program over `rect` on the CPU and returns its alpha.
    func alpha(of ops: [DrawOp], over rect: PixelRect) throws -> [Float] {
        if rect.isEmpty { return [] }
        let b = try subRenderer.render(RenderPlan(context: context, ops: ops), region: rect, source: self)
        return b.px.map(\.w)
    }
}

/// Fitting a split shape's stroke to Photoshop's pixels (`shape_split::fit_stroke`).
enum ShapeSplit {
    static func fitStroke(fill: Surface, stroke: inout Surface, cache: Surface, canvas: PixelRect) {
        let r = ContentBounds.of(cache).union(ContentBounds.of(stroke)).intersect(canvas)
        if r.isEmpty { return }
        let f = fill.readRGBA(r), s = stroke.readRGBA(r), c = cache.readRGBA(r)
        let float = stroke.format.sample == .f32
        var out = [Float](repeating: 0, count: r.area * 4)
        for i in 0..<r.area {
            let fp = f[i], sp = s[i], cp = c[i]
            var p = sp
            if fp.w < 1 - 1e-3 {
                let a = min(max((cp.w - fp.w) / (1 - fp.w), 0), 1)
                if sp.w <= 0 {
                    p = SIMD4(cp.x, cp.y, cp.z, a)
                } else if a > 1e-3 {
                    let k = fp.w * (1 - a)
                    func un(_ j: Int) -> Float {
                        let v = (cp.w * cp[j] - k * fp[j]) / a
                        return float ? v : min(max(v, 0), 1)
                    }
                    p = SIMD4(un(0), un(1), un(2), a)
                } else {
                    p = SIMD4(sp.x, sp.y, sp.z, a)
                }
            }
            out[i * 4] = p.x; out[i * 4 + 1] = p.y; out[i * 4 + 2] = p.z; out[i * 4 + 3] = p.w
        }
        stroke.writeRegion(r, out)
    }
}

/// Derived-leaf builders.
enum DerivedLeaves {
    /// Multichannel inks over white paper (`multichannel::inks`), opaque RGBA over `rect`.
    static func inks(_ doc: Document, _ rect: PixelRect) -> RenderLeaf {
        var px = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: rect.area)
        for ch in doc.channels {
            if ContentBounds.of(ch.surface).intersect(rect).isEmpty { continue }
            let ink = ch.spot ?? SpotInk(color: .black, solidity: 0)
            let c = ink.color.rgb
            let s = min(max(ink.solidity, 0), 1)
            let n = ch.surface.channels
            let vals = ch.surface.readRegion(rect)
            for i in 0..<rect.area {
                let v = min(max(vals[i * n], 0), 1)
                if v <= 0 { continue }
                let keep = 1 - s * v
                let p = SIMD3(px[i].x, px[i].y, px[i].z)
                let q = keep * p * (1 - v + v * c) + s * v * c
                px[i] = SIMD4(q, 1)
            }
        }
        return .image(RGBABuffer(rect: rect, px: px).floatImage, outside: SIMD4(1, 1, 1, 1), version: 0)
    }

    /// A native CMYK solid / gradient fill read back as RGBA (`render_cmyk_fill`): colours and the
    /// ramp in ink values, stored at the document depth, converted for display.
    static func cmykFill(_ f: Fill, rect: PixelRect, frame: PixelRect, depth: SampleType) -> RenderLeaf? {
        let fmt = PixelFormat(mode: .cmyk, sample: depth, alpha: true)
        func native(_ c: PCColor) -> SIMD4<Float> { c.converted(to: .cmyk).c }
        switch f {
        case .solid(let c):
            var s = Surface(format: fmt)
            let n = native(c)
            s.fill(PixelRect(x: 0, y: 0, width: 1, height: 1), with: [n.x, n.y, n.z, n.w, c.alpha])
            return .image(FloatImage(rect: .empty, channels: 4), outside: s.rgba(x: 0, y: 0), version: 0)
        case .gradient(let g):
            if rect.isEmpty { return .image(FloatImage(rect: .empty, channels: 4), outside: .zero, version: 0) }
            var cmy = g, k = g
            cmy.stops = g.stops.map { st in let n = native(st.color); return ColorStop(st.location, PCColor.rgb(n.x, n.y, n.z, st.color.alpha)) }
            k.stops = g.stops.map { st in let n = native(st.color); return ColorStop(st.location, PCColor.rgb(n.w, 0, 0, st.color.alpha)) }
            let r1 = GradientMath.FillRamp(cmy), r2 = GradientMath.FillRamp(k)
            let (angle, scale, offset) = GradientMath.layout(g.style, angle: g.angle, scale: g.scale, offset: g.offset, frame: frame)
            var data = [Float](repeating: 0, count: rect.area * 5)
            let w = rect.width
            data.withUnsafeMutableBufferPointer { dp in
                let D = UnsafeSendable(dp)
                parallelRows(rect.height, width: w) { j in
                    let y = rect.y0 + Int32(j)
                    for i in 0..<w {
                        let x = rect.x0 + Int32(i)
                        let t = GradientMath.t(g.style, angle: angle, scale: scale, reverse: g.reverse, offset: offset, bounds: frame,
                                               x: Float(x) + 0.5, y: Float(y) + 0.5)
                        var a = r1.sample(t), b = r2.sample(t)
                        if g.dither { a = GradientMath.dither(a, x, y, nil); b = GradientMath.dither(b, x, y, nil) }
                        let o = (j * w + i) * 5
                        D.value[o] = a.x; D.value[o + 1] = a.y; D.value[o + 2] = a.z; D.value[o + 3] = b.x; D.value[o + 4] = a.w
                    }
                }
            }
            var s = Surface(format: fmt)
            s.writeRegion(rect, data)
            return .image(RGBABuffer(rect: rect, px: s.readRGBA(rect)).floatImage, outside: .zero, version: 0)
        case .pattern:
            return nil
        }
    }

    /// Vector-mask coverage with density (`CompiledVectorMask::render`): computed over the path
    /// bounds ±2 px within `area`, its far value outside.
    static func vectorMask(_ vm: VectorMask, area: PixelRect, rasterizer: any LayerRasterizer) -> RenderLeaf {
        let d = min(max(vm.density, 0), 1)
        func dens(_ v: Float) -> Float { d < 1 ? 1 - d * (1 - v) : v }
        if vm.path.isEmpty {
            return .image(FloatImage(rect: .empty, channels: 1), outside: SIMD4(repeating: dens(vm.path.inverted ? 0 : 1)), version: 0)
        }
        let far = dens(vm.path.inverted ? 1 : 0)
        let b = vectorArea(vm.path, area)
        if b.isEmpty { return .image(FloatImage(rect: .empty, channels: 1), outside: SIMD4(repeating: far), version: 0) }
        // The platform rasterizer's coverage when it has one, else the built-in exact one.
        var cov = rasterizer.coverage(of: vm.path, in: b).flatMap { $0.count == b.area ? $0 : nil } ?? PathCoverage.coverage(of: vm.path, in: b)
        if d < 1 { for i in cov.indices { cov[i] = dens(cov[i]) } }
        return .image(FloatImage(rect: b, channels: 1, data: cov), outside: SIMD4(repeating: far), version: 0)
    }

    /// The path's control bounds grown by 2 px (whole pixels), within `area`.
    static func vectorArea(_ path: VectorPath, _ area: PixelRect) -> PixelRect {
        guard let cb = path.controlBounds else { return .empty }
        return PixelRect(x0: Int32(clamping: Int64(cb.x.rounded(.down)) - 2), y0: Int32(clamping: Int64(cb.y.rounded(.down)) - 2),
                         x1: Int32(clamping: Int64(cb.z.rounded(.up)) + 2), y1: Int32(clamping: Int64(cb.w.rounded(.up)) + 2)).intersect(area)
    }

    /// `effect_shape` with a filled shape's outline: `l + (1 − f) × coverage` (f = the largest
    /// alpha in the 3×3 neighbourhood), 1 where the outline covers the pixel, times the masks.
    static func outlineShape(alpha a: [Float], coverage cov: [Float], mask mv: [Float]?, w: Int, h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                var v: Float
                if cov[i] >= 1 - 1e-3 {
                    v = 1
                } else {
                    var f: Float = 0
                    for yy in max(y - 1, 0)..<min(y + 2, h) { for xx in max(x - 1, 0)..<min(x + 2, w) { f = max(f, a[yy * w + xx]) } }
                    v = min(max(a[i] + (1 - min(f, 1)) * cov[i], 0), 1)
                }
                out[i] = v * (mv?[i] ?? 1)
            }
        }
        return out
    }
}
