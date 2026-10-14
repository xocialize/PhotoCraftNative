// Port of photocraft-gpu (crates/gpu/src/fx.rs map programs, plan.rs `effects`, lib.rs `sync_fx`) and photocraft-compose (crates/compose/src/effects.rs, masks.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Effect maps and feathered masks on the GPU, and the per-cell encoding of a layer with effects.
// Map programs mirror the CPU builders (FxMaps.build) step for step: shifts, dilation, tent blurs
// (four box passes), precise glows, contours, noise, bevel heights / textures / shading run as
// kernels; the distance fields (chamfer, Euclidean, sharp-edge bevel fields) are computed by the
// CPU code the reference uses, from the same inputs, and uploaded — photocraft-gpu's split.

import Foundation
import Metal
import PCDocument
import PCFoundation

/// A layer's effect maps on the GPU (region space, r32Float).
final class GPUFxMaps: @unchecked Sendable {
    let region: PixelRect
    let shape: any MTLTexture
    let per: [[any MTLTexture]]
    let bevelPaint: [EffectMath.BevelPaint]
    let din: (any MTLTexture)?
    let dout: (any MTLTexture)?
    let vdout: (any MTLTexture)?
    let outline: Bool
    let frames: [(UInt32, PixelRect)]
    let bytes: Int
    /// Allocated bytes of the distinct textures held (a map can be the shape itself).
    let heldBytes: Int
    /// Bytes of the build's intermediates (region-sized working textures the build released).
    var buildBytes = 0

    init(region: PixelRect, shape: any MTLTexture, per: [[any MTLTexture]], bevelPaint: [EffectMath.BevelPaint], din: (any MTLTexture)?,
         dout: (any MTLTexture)?, vdout: (any MTLTexture)?, outline: Bool, frames: [(UInt32, PixelRect)]) {
        self.region = region; self.shape = shape; self.per = per; self.bevelPaint = bevelPaint; self.din = din; self.dout = dout
        self.vdout = vdout; self.outline = outline; self.frames = frames
        let n = per.reduce(0) { $0 + $1.count } + 1 + (din == nil ? 0 : 1) + (dout == nil ? 0 : 1) + (vdout == nil ? 0 : 1)
        bytes = n * region.area * 4
        var seen = Set<ObjectIdentifier>()
        var held = 0
        for t in [shape] + per.flatMap({ $0 }) + [din, dout, vdout].compactMap({ $0 }) where seen.insert(ObjectIdentifier(t)).inserted {
            held += t.allocatedSize
        }
        heldBytes = held
    }

    var textures: [any MTLTexture] { [shape] + per.flatMap { $0 } + [din, dout, vdout].compactMap { $0 } }

    func strokeFrame(_ st: StrokeFx) -> PixelRect? {
        let key = EffectMath.strokeWidths(st).outer.bitPattern
        return frames.first { $0.0 == key }?.1
    }
}

/// A feathered (canvas-wide) mask on the GPU.
final class GPUMask: @unchecked Sendable {
    let area: PixelRect
    let texture: (any MTLTexture)?
    let outside: Float
    var bytes: Int { area.area * 4 }
    /// Allocated bytes of `texture`.
    let allocated: Int
    /// Bytes of the build's intermediates.
    var buildBytes = 0
    init(area: PixelRect, texture: (any MTLTexture)?, outside: Float) {
        self.area = area; self.texture = texture; self.outside = outside
        allocated = texture?.allocatedSize ?? 0
    }
}

extension MetalCompositor {
    // MARK: Map-program steps (region space)

    struct MapEncoder {
        let c: MetalCompositor
        let enc: any MTLComputeCommandEncoder
        let region: PixelRect
        var w: Int { region.width }
        var h: Int { region.height }

        func op() -> PCROp {
            var o = PCROp()
            o.origin = SIMD2(region.x0, region.y0)
            o.size = SIMD2(Int32(w), Int32(h))
            return o
        }

        func new(_ ww: Int? = nil, _ hh: Int? = nil) throws -> any MTLTexture {
            guard let t = c.mapTexture(ww ?? w, hh ?? h) else { throw MetalCompositorError.gpu("map texture") }
            return t
        }

        func run(_ name: String, _ o: PCROp, _ tex: [Int: any MTLTexture], buffers: [Int: any MTLBuffer] = [:], grid: (Int, Int)? = nil) throws -> any MTLTexture {
            let out = try new()
            var t = tex
            t[Slot.out] = out
            c.kernels.dispatch(enc, try c.kernels.pipeline(name), op: o, grid: grid ?? (w, h), textures: t, buffers: buffers)
            return out
        }

        func shift(_ src: any MTLTexture, _ dx: Float, _ dy: Float, outside: Float, invert: Bool) throws -> any MTLTexture {
            if dx == 0 && dy == 0 && !invert { return src }
            var o = op(); o.p0 = SIMD4(dx, dy, outside, invert ? 1 : 0)
            return try run("pcr_m_shift", o, [Slot.a: src])
        }

        func upload(_ v: [Float]) throws -> any MTLTexture {
            guard let t = c.valuesTexture(v, w, h) else { throw MetalCompositorError.gpu("field texture") }
            return t
        }

        func dilate(_ src: any MTLTexture, _ dist: any MTLTexture, _ r: Float) throws -> any MTLTexture {
            var o = op(); o.p0.x = r
            return try run("pcr_m_dilate", o, [Slot.a: src, Slot.b: dist])
        }

        /// One box pass (`EffectMath.boxLine`): `n` source samples per line, output k reads x0 + k.
        func box(_ src: any MTLTexture, vertical: Bool, n: Int, x0: Int, outLen: Int, lines: Int, bw: Float) throws -> any MTLTexture {
            let (r, f, norm) = EffectMath.boxGeom(bw)
            guard let out = vertical ? c.mapTexture(lines, outLen) : c.mapTexture(outLen, lines) else { throw MetalCompositorError.gpu("box texture") }
            var o = PCROp()
            o.origin = SIMD2(region.x0, region.y0)
            o.size = SIMD2(Int32(outLen), Int32(lines))
            o.p0 = SIMD4(vertical ? 1 : 0, Float(r), Float(f), Float(norm))
            o.aux = SIMD2(Int32(n), Int32(x0))
            let seg = max(64, 2 * r)
            o.p1.x = Float(seg)
            c.kernels.dispatch(enc, try c.kernels.pipeline("pcr_m_box"), op: o, grid: ((outLen + seg - 1) / seg, lines),
                               textures: [Slot.a: src, Slot.out: out])
            return out
        }

        /// `EffectMath.tent`: two box passes along each axis (rows first).
        func tent(_ src: any MTLTexture, _ width: Float) throws -> any MTLTexture {
            if EffectMath.tentKernel(width).0 == 0 || w == 0 || h == 0 { return src }
            let (r, _, _) = EffectMath.boxGeom(width)
            let a = try box(src, vertical: false, n: w, x0: -r, outLen: w + 2 * r, lines: h, bw: width)
            let b = try box(a, vertical: false, n: w + 2 * r, x0: r, outLen: w, lines: h, bw: width)
            let cc = try box(b, vertical: true, n: h, x0: -r, outLen: h + 2 * r, lines: w, bw: width)
            return try box(cc, vertical: true, n: h + 2 * r, x0: r, outLen: h, lines: w, bw: width)
        }

        func blur(_ src: any MTLTexture, _ size: Float) throws -> any MTLTexture {
            size.isFinite ? try tent(src, size) : src
        }

        /// `pcr_m_finish`.
        func finish(_ a: any MTLTexture, b: (any MTLTexture)? = nil, invertBefore: Bool = false, lut: [Float]? = nil, invertAfter: Bool = false,
                    noise: Float = 0, shape: (any MTLTexture)? = nil) throws -> any MTLTexture {
            if b == nil && !invertBefore && lut == nil && !invertAfter && !(noise.isFinite && noise > 0) && shape == nil { return a }
            var o = op()
            o.p0 = SIMD4(b == nil ? 0 : 1, invertBefore ? 1 : 0, lut == nil ? 0 : 1, invertAfter ? 1 : 0)
            o.p1 = SIMD4(noise.isFinite && noise > 0 ? noise : 0, shape == nil ? 0 : 1, 0, 0)
            o.aux.x = Int32(lut?.count ?? 1)
            var tex: [Int: any MTLTexture] = [Slot.a: a]
            if let b { tex[Slot.b] = b }
            if let shape { tex[Slot.c] = shape }
            return try run("pcr_m_finish", o, tex, buffers: [1: c.kernels.buffer(lut ?? [0])!])
        }
    }

    /// The layer's effect maps on the GPU (built into `encoder`, cached by layer state).
    func gpuMaps(_ spec: EffectsSpec, ctx: RenderContext, source: any RenderSource,
                 encoder: () throws -> any MTLComputeCommandEncoder) throws -> GPUFxMaps {
        guard let shapeVersion = source.leafVersion(spec.shape) else { throw MetalCompositorError.gpu(PlanError.missingLeaf(spec.shape).description) }
        let key = CPUCompositor.FxKey(layer: spec.layerID, shapeVersion: shapeVersion, effects: spec.effects, region: spec.region,
                                      light: ctx.globalLight, vectorShape: spec.vectorShape, outline: spec.outline)
        if let hit = fxCache[key] { fxCache[key] = (hit.maps, nextTick()); frameFx.insert(key); return hit.maps }
        let allocatedBefore = mapBytesAllocated
        guard let shapeLeaf = source.leaf(spec.shape) else { throw MetalCompositorError.gpu(PlanError.missingLeaf(spec.shape).description) }
        let region = spec.region
        let shapeCPU = region.isEmpty ? [] : LeafReader.values(shapeLeaf, region)
        let s = FxMap(w: region.width, h: region.height, v: shapeCPU)
        let me = MapEncoder(c: self, enc: try encoder(), region: region)
        let shapeTex = try me.upload(shapeCPU)
        let light = ctx.globalLight
        let items = spec.effects.items.filter(\.isEnabled)
        var bevelPaint = [EffectMath.BevelPaint](repeating: .inner, count: items.count)
        var per: [[any MTLTexture]] = []
        if region.isEmpty {
            per = items.map { _ in [] }
        } else {
            for (i, e) in items.enumerated() {
                switch e {
                case .dropShadow(let sh), .innerShadow(let sh):
                    let inner: Bool
                    if case .innerShadow = e { inner = true } else { inner = false }
                    let angle = sh.useGlobalLight ? light.angle : sh.angle
                    let (dx, dy) = EffectMath.offset(angle, sh.distance)
                    let outside: Float = inner ? 1 : 0
                    var m = try me.shift(shapeTex, dx, dy, outside: outside, invert: inner)
                    let (r, bw) = EffectMath.spreadSplit(sh.size, sh.spread)
                    if r > 0 {
                        let src = inner ? s.map { 1 - $0 } : s
                        let d = DistanceFields.distOutside(src.shifted(dx, dy, outside: outside), .chamfer)
                        m = try me.dilate(m, try me.upload(d), r)
                    }
                    m = try me.blur(m, bw)
                    per.append([try me.finish(m, lut: EffectMath.contourLUT(sh.contour), noise: sh.noise, shape: inner ? shapeTex : nil)])
                case .outerGlow(let g), .innerGlow(let g):
                    let inner: Bool
                    if case .innerGlow = e { inner = true } else { inner = false }
                    var m: any MTLTexture
                    switch g.technique {
                    case .precise:
                        let d = inner ? DistanceFields.distInside(s, .euclidean) : DistanceFields.distOutside(s, .euclidean)
                        let solid = g.size * g.spread
                        var o = me.op(); o.p0 = SIMD4(solid, max(g.size + 1 - solid, 1e-3), 0, 0)
                        m = try me.run("pcr_m_glow", o, [Slot.a: try me.upload(d)])
                    case .softer:
                        m = inner ? try me.shift(shapeTex, 0, 0, outside: 0, invert: true) : shapeTex
                        let (r, bw) = EffectMath.spreadSplit(g.size, g.spread)
                        if r > 0 {
                            let d = DistanceFields.distOutside(inner ? s.map { 1 - $0 } : s, .chamfer)
                            m = try me.dilate(m, try me.upload(d), r)
                        }
                        m = try me.blur(m, bw)
                    }
                    per.append([try me.finish(m, lut: EffectMath.glowLUT(g), invertAfter: inner && g.source == .center, noise: g.noise,
                                              shape: inner ? shapeTex : nil)])
                case .satin(let st):
                    let (dx, dy) = EffectMath.offset(st.angle, EffectMath.satinDistance(st))
                    // `EffectMath.satinMap`: |C(tent(A)) − C(tent(B))|, inverted after, × shape.
                    let lut = EffectMath.satinLUT(st.contour)
                    func contoured(_ m: any MTLTexture) throws -> any MTLTexture {
                        guard let lut else { return m }
                        if !st.antiAlias { return try me.finish(m, lut: lut) }
                        var o = me.op(); o.aux.x = Int32(lut.count)
                        return try me.run("pcr_m_contour_aa", o, [Slot.a: m], buffers: [1: me.c.kernels.buffer(lut)!])
                    }
                    let a = try contoured(try me.tent(try me.shift(shapeTex, dx, dy, outside: 0, invert: false), st.size))
                    let b = try contoured(try me.tent(try me.shift(shapeTex, -dx, -dy, outside: 0, invert: false), st.size))
                    per.append([try me.finish(a, b: b, invertBefore: st.invert, shape: shapeTex)])
                case .bevelEmboss(let b):
                    let (maps, paint) = try bevelMaps(me, s, shapeTex, b, light, spec, source)
                    bevelPaint[i] = paint
                    per.append(maps)
                default:
                    per.append([])
                }
            }
        }
        let hasStroke = items.contains { if case .stroke = $0 { return true } else { return false } }
        var din: (any MTLTexture)?, dout: (any MTLTexture)?, vdout: (any MTLTexture)?
        if hasStroke && !region.isEmpty {
            din = try me.upload(DistanceFields.distInside(s, .chamfer))
            dout = try me.upload(DistanceFields.distOutside(s, .chamfer))
            if spec.vectorShape && !spec.outline { vdout = try me.upload(DistanceFields.distOutside(DistanceFields.localCoverage(s), .chamfer)) }
        }
        var frames: [(UInt32, PixelRect)] = []
        for e in items {
            if case .stroke(let st) = e, case .gradient = st.paint {
                let outW = EffectMath.strokeWidths(st).outer
                if !frames.contains(where: { $0.0 == outW.bitPattern }) { frames.append((outW.bitPattern, EffectMath.strokeFrame(s, outW, region))) }
            }
        }
        let maps = GPUFxMaps(region: region, shape: shapeTex, per: per, bevelPaint: bevelPaint, din: din, dout: dout, vdout: vdout,
                             outline: spec.outline, frames: frames)
        maps.buildBytes = max(0, mapBytesAllocated - allocatedBefore - maps.heldBytes)
        fxCache[key] = (maps, nextTick())
        frameFx.insert(key)
        return maps
    }

    private func bevelMaps(_ me: MapEncoder, _ s: FxMap, _ shapeTex: any MTLTexture, _ b: Bevel, _ light: GlobalLight, _ spec: EffectsSpec,
                           _ source: any RenderSource) throws -> ([any MTLTexture], EffectMath.BevelPaint) {
        let g = EffectMath.bevelGeom(b)
        let size = max(b.size, 1)
        var h: any MTLTexture
        if b.technique == .smooth {
            h = try me.tent(shapeTex, g.width)
        } else {
            let sharp = DistanceFields.sharpEdges(s)
            let din = try me.upload(DistanceFields.bevelDistInside(s, sharp, size))
            let dout = try me.upload(DistanceFields.bevelDistOutside(s, sharp, size))
            let soft = g.chiselSoft > 0
            var o = me.op()
            o.p0 = SIMD4(Float(g.paint.rawValue), size, soft ? 1 : 0, 0)
            h = try me.run("pcr_m_bevel_h", o, [Slot.a: din, Slot.b: dout])
            if soft && g.paint == .both { h = try me.tent(h, g.chiselSoft) }
        }
        if let c = b.contour { h = try me.finish(h, lut: EffectMath.bevelContourLUT(c)) }
        if let t = b.texture, let tile = source.pattern(id: t.id, name: t.name), tile.isPaintable, let pt = patternTexture(tile) {
            let unit = abs(b.depth) > 1e-6 ? max(abs(g.depth / b.depth), 1e-3) : max(g.width, 1)
            let pl = PatternPlacement(anchor: spec.anchor, link: t.link, phase: t.phase, scale: t.scale, angle: 0)
            var o = me.op()
            o.p0 = SIMD4(t.depth / unit, t.invert ? 1 : 0, 0, 0)
            o.p1 = SIMD4(Float(pl.origin.x), Float(pl.origin.y), Float(pl.cs.x), Float(pl.cs.y))
            o.p2 = SIMD4(Float(pl.invScale), Float(tile.width), Float(tile.height), 0)
            h = try me.run("pcr_m_bevel_tex", o, [Slot.a: h, Slot.leaf: pt])
        }
        if b.soften >= 1 { h = try me.tent(h, b.soften) }
        let (angle, altitude) = b.useGlobalLight ? (light.angle, light.altitude) : (b.angle, b.altitude)
        let (sa, ca) = (sinf(radians(angle)), cosf(radians(angle)))
        let (se, ce) = (sinf(radians(altitude)), cosf(radians(altitude)))
        let lut = EffectMath.contourLUT(b.glossContour)
        let lutBuf = kernels.buffer(lut ?? [0])!
        let kind: Float
        switch g.paint {
        case .inner: kind = 0
        case .outer: kind = 1
        case .both: kind = g.pillow ? 3 : 2
        }
        var maps: [any MTLTexture] = []
        for which in [Float(0), 1] {
            var o = me.op()
            o.p0 = SIMD4(ca * ce, -sa * ce, se, se)
            o.p1 = SIMD4(g.depth, kind, which, lut == nil ? 0 : 1)
            o.p2.x = (g.paint == .both || (g.paint == .outer && b.technique != .smooth)) ? 1 : 0
            o.aux.x = Int32(lut?.count ?? 1)
            maps.append(try me.run("pcr_m_bevel_shade", o, [Slot.a: h, Slot.c: shapeTex], buffers: [1: lutBuf]))
        }
        return (maps, g.paint)
    }

    // MARK: Feathered masks

    func gpuMask(_ spec: MaskSpec, ctx: RenderContext, source: any RenderSource, encoder: () throws -> any MTLComputeCommandEncoder) throws -> GPUMask {
        func get(_ id: LeafID?) throws -> RenderLeaf? {
            guard let id else { return nil }
            guard let l = source.leaf(id) else { throw MetalCompositorError.gpu(PlanError.missingLeaf(id).description) }
            return l
        }
        func version(_ id: LeafID?) throws -> UInt64 {
            guard let id else { return 0 }
            guard let v = source.leafVersion(id) else { throw MetalCompositorError.gpu(PlanError.missingLeaf(id).description) }
            return v
        }
        let key = CPUCompositor.MaskKey(spec: spec, pixelVersion: try version(spec.pixel), vectorVersion: try version(spec.vector), canvas: ctx.canvas)
        if let hit = maskCache[key] { maskCache[key] = (hit.mask, nextTick()); frameMasks.insert(key); return hit.mask }
        let allocatedBefore = mapBytesAllocated
        let pixel = try get(spec.pixel), vector = try get(spec.vector)
        let sv = vector == nil ? 0 : MaskSpec.featherSigma(spec.vectorFeather)
        let sp = pixel == nil ? 0 : MaskSpec.featherSigma(spec.feather)
        let vOut: Float = vector.map(LeafReader.outsideValue) ?? 1
        let pDef: Float = pixel.map { 1 - spec.density * (1 - LeafReader.outsideValue($0)) } ?? 1
        func grow(_ r: PixelRect, _ sigma: Float) -> PixelRect { r.isEmpty ? r : r.outset(by: Int32((sigma * 3).rounded(.up)) + 2) }
        var area = vector.map { grow(LeafReader.extent($0), sv) } ?? .empty
        if let p = pixel, vOut > 0 { area = area.union(grow(LeafReader.extent(p), sp)) }
        area = area.intersect(ctx.canvas)
        let outside = MaskMath.q16(pDef * vOut)
        if area.isEmpty {
            let m = GPUMask(area: .empty, texture: nil, outside: outside)
            maskCache[key] = (m, nextTick())
            frameMasks.insert(key)
            return m
        }
        let me = MapEncoder(c: self, enc: try encoder(), region: area)
        func gather(_ id: LeafID, _ leaf: RenderLeaf, density: Float) throws -> any MTLTexture {
            let b = residency.bind(id, leaf, values: true, cell: area, gather: true)
            var o = me.op()
            o.leafOutside = b.outside
            if b.texture != nil { o.flags |= PCROp.flagLeaf; o.leafOrigin = b.origin; o.leafSize = b.size }
            o.p0.x = density
            var tex: [Int: any MTLTexture] = [:]
            if let t = b.texture { tex[Slot.leaf] = t }
            return try me.run("pcr_mask_gather", o, tex)
        }
        func gaussian(_ src: any MTLTexture, _ sigma: Float) throws -> any MTLTexture {
            let r = MaskMath.gaussianRadius(sigma)
            if r == 0 { return src }
            var cur = src
            for vertical in [false, true] {
                for _ in 0..<3 {
                    var o = me.op()
                    let (n, lines) = vertical ? (area.height, area.width) : (area.width, area.height)
                    o.size = SIMD2(Int32(n), Int32(lines))
                    o.p0.x = vertical ? 1 : 0
                    o.aux.x = Int32(r)
                    let seg = max(64, 2 * r)
                    o.p1.x = Float(seg)
                    cur = try me.run("pcr_mask_box", o, [Slot.a: cur], grid: ((n + seg - 1) / seg, lines))
                }
            }
            return cur
        }
        func exactGaussian(_ src: any MTLTexture, _ sigma: Float) throws -> any MTLTexture {
            let k = MaskMath.gaussianWeights(sigma)
            if k.count == 1 { return src }
            guard let wb = kernels.buffer(k) else { throw MetalCompositorError.gpu("gaussian weights") }
            var cur = src
            for vertical in [false, true] {
                var o = me.op()
                let (n, lines) = vertical ? (area.height, area.width) : (area.width, area.height)
                o.size = SIMD2(Int32(n), Int32(lines))
                o.p0.x = vertical ? 1 : 0
                o.aux.x = Int32(k.count / 2)
                cur = try me.run("pcr_mask_gauss", o, [Slot.a: cur], buffers: [1: wb], grid: (n, lines))
            }
            return cur
        }
        var a: (any MTLTexture)?, b: (any MTLTexture)?
        if let v = vector, let vid = spec.vector { a = try exactGaussian(try gather(vid, v, density: 1), sv) }
        if let p = pixel, let pid = spec.pixel {
            let pm = try gaussian(try gather(pid, p, density: spec.density), sp)
            if a == nil { a = pm } else { b = pm }
        }
        guard let first = a else {
            let m = GPUMask(area: .empty, texture: nil, outside: outside)
            maskCache[key] = (m, nextTick())
            frameMasks.insert(key)
            return m
        }
        var o = me.op()
        o.aux.x = b == nil ? 0 : 1
        var tex: [Int: any MTLTexture] = [Slot.a: first]
        if let b { tex[Slot.b] = b }
        let t = try me.run("pcr_mask_combine", o, tex)
        let m = GPUMask(area: area, texture: t, outside: outside)
        m.buildBytes = max(0, mapBytesAllocated - allocatedBefore - m.allocated)
        maskCache[key] = (m, nextTick())
        frameMasks.insert(key)
        return m
    }
}

// MARK: - Effects composite in a cell

extension CellRun {
    /// Paint source of an effect pass.
    enum FxPaintSource {
        case color(SIMD3<Float>)
        case gradient(StyleGradient, frame: PixelRect)
        case glowGradient(StyleGradient, gain: Float)
        case pattern(PatternTile, PatternPlacement)
        case none
    }

    func paintSource(_ p: FxPaint, frame: PixelRect, anchor: SIMD2<Double>) -> FxPaintSource {
        switch p {
        case .color(let c): return .color(c.rgb)
        case .gradient(let g): return .gradient(g, frame: frame)
        case .pattern(let pr):
            guard let tile = source.pattern(id: pr.id, name: pr.name), tile.isPaintable else { return .none }
            return .pattern(tile, PatternPlacement(anchor: anchor, link: true, phase: .zero, scale: pr.scale, angle: 0))
        }
    }

    /// Sets the paint fields of `op` (aux.y, colour, gradient geometry / stops, pattern) and returns
    /// the stops buffer and pattern texture to bind.
    func setPaint(_ src: FxPaintSource, _ op: inout PCROp) -> ((any MTLBuffer)?, (any MTLTexture)?) {
        switch src {
        case .color(let c):
            op.aux.y = 0; op.color = SIMD4(c, 1)
            return (nil, nil)
        case let .gradient(g, frame):
            op.aux.y = 1
            let (angle, scale, offset) = GradientMath.layout(g.style, angle: g.angle, scale: g.scale, offset: g.offset, frame: frame)
            op.p0 = SIMD4(angle, scale, g.reverse ? 1 : 0, g.style.index)
            op.p1 = SIMD4(Float(frame.x0), Float(frame.y0), Float(frame.width), Float(frame.height))
            op.p2 = SIMD4(offset.x, offset.y, 0, 0)
            let packed = GradientMath.EffectRamp(g).packed
            op.p6 = SIMD4(Float(packed.color.count), Float(packed.opacity.count), 0, 0)
            return (k.buffer(packed.color + packed.opacity), nil)
        case let .glowGradient(g, gain):
            op.aux.y = 3
            op.p3.x = gain
            let packed = GradientMath.EffectRamp(g).packed
            op.p6 = SIMD4(Float(packed.color.count), Float(packed.opacity.count), 0, 0)
            return (k.buffer(packed.color + packed.opacity), nil)
        case let .pattern(tile, pl):
            op.aux.y = 2
            op.p4 = SIMD4(Float(pl.origin.x), Float(pl.origin.y), Float(pl.cs.x), Float(pl.cs.y))
            op.p5 = SIMD4(Float(pl.invScale), Float(tile.width), Float(tile.height), 0)
            return (nil, compositor.patternTexture(tile))
        case .none:
            return (nil, nil)
        }
    }

    enum Coverage {
        case map(any MTLTexture, outside: Float)
        case full
        case relative(any MTLTexture)
        case insideStroke(any MTLTexture, width: Float)
    }

    /// One effect paint (`pcr_fx_paint`) into a fresh texture; releases `target`.
    mutating func paint(_ target: any MTLTexture, shape: any MTLTexture, cov: Coverage, src: FxPaintSource, blend: BlendMode, opacity: Float,
                        knock: Float?, clip: PixelRect, region: PixelRect) throws -> any MTLTexture {
        if case .none = src { return target }
        var o = baseOp(clip)
        o.mode = blend.rawValue
        o.opacity = opacity
        o.mapOrigin = SIMD2(region.x0, region.y0)
        o.mapSize = SIMD2(Int32(region.width), Int32(region.height))
        var tex: [Int: any MTLTexture] = [Slot.a: target, Slot.c: shape]
        switch cov {
        case let .map(m, outside): o.aux.x = 0; o.p3.w = outside; tex[Slot.leaf] = m
        case .full: o.aux.x = 1
        case .relative(let m): o.aux.x = 2; o.p3.w = 0; tex[Slot.leaf] = m
        case let .insideStroke(m, width): o.aux.x = 3; o.p3.y = width; tex[Slot.leaf] = m
        }
        if let knock { o.flags |= PCROp.fxKnock; o.p3.z = knock }
        let (buf, pat) = setPaint(src, &o)
        if let pat { tex[Slot.pattern] = pat }
        let out = fresh()
        tex[Slot.out] = out
        // pcr_fx_paint reads the shape from texture 2.
        tex[Slot.c] = shape
        k.dispatch(enc, try k.pipeline("pcr_fx_paint"), op: o, grid: grid(o), textures: tex, buffers: buf.map { [1: $0] } ?? [:])
        recycle(target)
        return out
    }

    /// `composite_with_effects` over this cell: [backdrop, content] → result.
    mutating func effect(_ spec: EffectsSpec, atop: Bool, maps: GPUFxMaps, backdrop: any MTLTexture, content: any MTLTexture) throws -> any MTLTexture {
        let clip = (spec.clip ?? cell).intersect(cell)
        if clip.isEmpty {
            let out = fresh()
            k.dispatch(enc, try k.pipeline("pcr_copy"), op: baseOp(), grid: grid(baseOp()), textures: [Slot.a: backdrop, Slot.out: out])
            return out
        }
        let region = maps.region
        let fill = spec.fillOpacity
        let seeThrough = 1 - min(max(fill, 0), 1)
        let sb = spec.bounds
        let anchor = spec.anchor
        let items = spec.effects.items.filter(\.isEnabled)
        let rev = Array(items.enumerated().reversed())
        let relative = spec.shapeless || maps.outline || spec.vectorStroke != nil

        // Vector stroke and its mask.
        var vsTex: (any MTLTexture)?
        var vsOp = PCROp()
        var vsMaskTex: [Int: any MTLTexture] = [:]
        if let sid = spec.vectorStroke {
            let b = try bindLeaf(sid, values: false)
            var o = baseOp()
            o.leafOutside = b.outside
            var tex: [Int: any MTLTexture] = [:]
            if let t = b.texture { o.flags |= PCROp.flagLeaf; o.leafOrigin = b.origin; o.leafSize = b.size; tex[Slot.leaf] = t }
            let t = fresh()
            tex[Slot.out] = t
            k.dispatch(enc, try k.pipeline("pcr_draw_leaf"), op: o, grid: grid(o), textures: tex)
            vsTex = t
            try bindMask(spec.vectorStrokeMask, &vsOp, &vsMaskTex)
        }
        func withMask(_ o: inout PCROp) {
            o.flags |= vsOp.flags & (PCROp.flagMask | PCROp.flagVMask | PCROp.flagCombined | PCROp.flagDensity)
            o.density = vsOp.density; o.maskOrigin = vsOp.maskOrigin; o.maskSize = vsOp.maskSize; o.maskDefault = vsOp.maskDefault
            o.vmaskOrigin = vsOp.vmaskOrigin; o.vmaskSize = vsOp.vmaskSize; o.vmaskOutside = vsOp.vmaskOutside
        }

        // The effect shape.
        let shape = fresh(.r32Float)
        do {
            var o = baseOp(clip)
            o.mapOrigin = SIMD2(region.x0, region.y0); o.mapSize = SIMD2(Int32(region.width), Int32(region.height))
            if spec.shapeless { o.flags |= PCROp.fxShapeless } else if maps.outline { o.flags |= PCROp.fxOutline }
            var tex: [Int: any MTLTexture] = [Slot.b: content, Slot.leaf: maps.shape, Slot.out: shape]
            if let vsTex { o.flags |= PCROp.fxVStroke; withMask(&o); tex[Slot.d] = vsTex; tex.merge(vsMaskTex) { $1 } }
            k.dispatch(enc, try k.pipeline("pcr_fx_shape"), op: o, grid: grid(o), textures: tex)
        }

        // Exterior effects into W.
        var w: any MTLTexture
        if atop {
            w = fresh()
            let o = baseOp(clip)
            k.dispatch(enc, try k.pipeline("pcr_fx_opaque"), op: o, grid: grid(o), textures: [Slot.b: backdrop, Slot.out: w])
        } else {
            w = fresh()
            let o = baseOp(clip)
            k.dispatch(enc, try k.pipeline("pcr_copy"), op: o, grid: grid(o), textures: [Slot.a: backdrop, Slot.out: w])
        }
        for (i, e) in rev {
            if case .dropShadow(let s) = e {
                w = try paint(w, shape: shape, cov: .map(maps.per[i][0], outside: 0), src: .color(s.color.rgb), blend: s.common.blend,
                              opacity: s.common.opacity, knock: s.knocksOut ? seeThrough : nil, clip: clip, region: region)
            }
        }
        for (i, e) in rev {
            if case .outerGlow(let g) = e {
                w = try paint(w, shape: shape, cov: .map(maps.per[i][0], outside: 0), src: glowSource(g, sb, anchor), blend: g.common.blend,
                              opacity: g.common.opacity, knock: seeThrough, clip: clip, region: region)
            }
        }

        // The layer and its interior effects into L.
        let interiorGroup = spec.blendInterior && fill < 1
        // `EffectsCPU.composite`: grouped interior effects drawn atop a shapeless layer's content.
        let clipInterior = spec.shapeless && spec.blendInterior && vsTex == nil
        var l = fresh()
        do {
            var o = baseOp(clip)
            o.p0.x = interiorGroup ? 1 : fill
            if relative && !clipInterior { o.flags |= PCROp.fxRelative }
            var tex: [Int: any MTLTexture] = [Slot.b: content, Slot.c: shape, Slot.out: l]
            if vsTex != nil { o.flags |= PCROp.fxVStroke; withMask(&o); tex.merge(vsMaskTex) { $1 } }
            k.dispatch(enc, try k.pipeline("pcr_fx_lay"), op: o, grid: grid(o), textures: tex)
        }
        for (_, e) in rev {
            if case .patternOverlay(let po) = e {
                let src: FxPaintSource = source.pattern(id: po.id, name: po.name).flatMap { $0.isPaintable ? $0 : nil }
                    .map { .pattern($0, PatternPlacement(anchor: anchor, link: po.link, phase: po.phase, scale: po.scale, angle: po.angle)) } ?? .none
                l = try paint(l, shape: shape, cov: .full, src: src, blend: po.common.blend, opacity: po.common.opacity, knock: nil, clip: clip, region: region)
            }
        }
        for (_, e) in rev {
            if case .gradientOverlay(let go) = e {
                l = try paint(l, shape: shape, cov: .full, src: .gradient(go.gradient, frame: sb), blend: go.common.blend, opacity: go.common.opacity,
                              knock: nil, clip: clip, region: region)
            }
        }
        for (_, e) in rev {
            if case .colorOverlay(let co) = e {
                l = try paint(l, shape: shape, cov: .full, src: .color(co.color.rgb), blend: co.common.blend, opacity: co.common.opacity, knock: nil, clip: clip, region: region)
            }
        }
        for (i, e) in rev {
            if case .satin(let s) = e {
                l = try paint(l, shape: shape, cov: .relative(maps.per[i][0]), src: .color(s.color.rgb), blend: s.common.blend, opacity: s.common.opacity,
                              knock: nil, clip: clip, region: region)
            }
        }
        for (i, e) in rev {
            if case .innerGlow(let g) = e {
                l = try paint(l, shape: shape, cov: .relative(maps.per[i][0]), src: glowSource(g, sb, anchor), blend: g.common.blend,
                              opacity: g.common.opacity, knock: nil, clip: clip, region: region)
            }
        }
        if clipInterior {
            var o = baseOp(clip)
            o.flags |= PCROp.fxRelative
            let out = fresh()
            k.dispatch(enc, try k.pipeline("pcr_fx_scale_alpha"), op: o, grid: grid(o), textures: [Slot.a: l, Slot.b: content, Slot.c: shape, Slot.out: out])
            recycle(l)
            l = out
        }
        if interiorGroup { l = try scaleAlpha(l, shape: shape, byShape: false, fill: fill, clip: clip) }
        for (i, e) in rev {
            if case .innerShadow(let s) = e {
                l = try paint(l, shape: shape, cov: .relative(maps.per[i][0]), src: .color(s.color.rgb), blend: s.common.blend, opacity: s.common.opacity,
                              knock: nil, clip: clip, region: region)
            }
        }
        if let vsTex {
            var o = baseOp(clip)
            o.p0.x = fill
            withMask(&o)
            let out = fresh()
            var tex: [Int: any MTLTexture] = [Slot.a: l, Slot.c: shape, Slot.d: vsTex, Slot.out: out]
            tex.merge(vsMaskTex) { $1 }
            k.dispatch(enc, try k.pipeline("pcr_fx_vstroke"), op: o, grid: grid(o), textures: tex)
            recycle(l)
            l = out
        }
        let strokes: [StrokeFx] = items.compactMap { if case .stroke(let s) = $0 { s } else { nil } }
        func frame(_ st: StrokeFx) -> PixelRect { maps.strokeFrame(st) ?? sb }
        for st in strokes.reversed() {
            let inW = EffectMath.strokeWidths(st).inner
            guard inW > 0, let din = maps.din else { continue }
            l = try paint(l, shape: shape, cov: .insideStroke(din, width: inW), src: paintSource(st.paint, frame: frame(st), anchor: anchor),
                          blend: st.common.blend, opacity: st.common.opacity, knock: nil, clip: clip, region: region)
        }
        for (i, e) in rev {
            if case .bevelEmboss(let b) = e, maps.bevelPaint[i] == .inner {
                l = try paint(l, shape: shape, cov: .relative(maps.per[i][0]), src: .color(b.highlightColor.rgb), blend: b.highlight.blend,
                              opacity: b.highlight.opacity, knock: nil, clip: clip, region: region)
                l = try paint(l, shape: shape, cov: .relative(maps.per[i][1]), src: .color(b.shadowColor.rgb), blend: b.shadow.blend,
                              opacity: b.shadow.opacity, knock: nil, clip: clip, region: region)
            }
        }
        l = try scaleAlpha(l, shape: shape, byShape: true, fill: 1, clip: clip)

        // Outside strokes: the rest of each pixel's area (`EffectsCPU.composite`).
        let outs = strokes.filter { EffectMath.strokeWidths($0).outer > 0 }
        var pre: (any MTLTexture)?
        let split = !outs.isEmpty && !maps.outline && !maps.bevelPaint.contains(.outer) && spec.textGamma == 1
        if !outs.isEmpty, let dout = (spec.vectorShape ? maps.vdout : nil) ?? maps.dout {
            var acc: (any MTLTexture)?, cover: (any MTLTexture)?
            for (n, st) in outs.enumerated() {
                var o = baseOp(clip)
                o.mode = st.common.blend.rawValue
                o.opacity = st.common.opacity
                o.p3.y = EffectMath.strokeWidths(st).outer
                o.mapOrigin = SIMD2(region.x0, region.y0); o.mapSize = SIMD2(Int32(region.width), Int32(region.height))
                if maps.outline { o.flags |= PCROp.fxOutline }
                if spec.vectorShape { o.flags |= PCROp.fxVector }
                if split { o.flags |= PCROp.fxSplit }
                if n == 0 { o.flags |= PCROp.fxFirst }
                let src = paintSource(st.paint, frame: frame(st), anchor: anchor)
                if case .none = src { o.flags |= PCROp.fxNoPaint }
                let (buf, pat) = setPaint(src, &o)
                let accOut = fresh(), coverOut = fresh(.r32Float)
                var tex: [Int: any MTLTexture] = [Slot.a: w, Slot.c: shape, Slot.d: l, Slot.leaf: dout, Slot.out: accOut, Slot.out2: coverOut]
                if let acc { tex[Slot.b] = acc }
                if let cover { tex[Slot.cover] = cover }
                if let pat { tex[Slot.pattern] = pat }
                k.dispatch(enc, try k.pipeline("pcr_fx_stroke_acc"), op: o, grid: grid(o), textures: tex, buffers: buf.map { [1: $0] } ?? [:])
                if let acc { recycle(acc) }
                if let cover { recycle(cover) }
                acc = accOut; cover = coverOut
            }
            if let acc, let cover {
                let o = baseOp(clip)
                let out = fresh()
                k.dispatch(enc, try k.pipeline("pcr_fx_stroke_resolve"), op: o, grid: grid(o),
                           textures: [Slot.a: w, Slot.b: acc, Slot.cover: cover, Slot.out: out])
                recycle(acc); recycle(cover)
                if split { pre = w } else { recycle(w) }
                w = out
            }
        }
        for (i, e) in rev {
            if case .bevelEmboss(let b) = e, maps.bevelPaint[i] == .outer {
                w = try paint(w, shape: shape, cov: .map(maps.per[i][0], outside: 0), src: .color(b.highlightColor.rgb), blend: b.highlight.blend,
                              opacity: b.highlight.opacity, knock: nil, clip: clip, region: region)
                w = try paint(w, shape: shape, cov: .map(maps.per[i][1], outside: 0), src: .color(b.shadowColor.rgb), blend: b.shadow.blend,
                              opacity: b.shadow.opacity, knock: nil, clip: clip, region: region)
            }
        }
        // The layer merged in its mode.
        do {
            var o = baseOp(clip)
            o.mode = (spec.blend == .passThrough ? BlendMode.normal : spec.blend).rawValue
            o.gamma = spec.textGamma
            let out = fresh()
            if let pre {
                k.dispatch(enc, try k.pipeline("pcr_fx_merge_split"), op: o, grid: grid(o),
                           textures: [Slot.a: w, Slot.b: pre, Slot.c: shape, Slot.d: l, Slot.out: out])
                recycle(pre)
            } else {
                k.dispatch(enc, try k.pipeline("pcr_fx_merge"), op: o, grid: grid(o), textures: [Slot.a: w, Slot.d: l, Slot.out: out])
            }
            recycle(w); recycle(l)
            w = out
        }
        for (i, e) in rev {
            if case .bevelEmboss(let b) = e, maps.bevelPaint[i] == .both {
                w = try paint(w, shape: shape, cov: .map(maps.per[i][0], outside: 0), src: .color(b.highlightColor.rgb), blend: b.highlight.blend,
                              opacity: b.highlight.opacity, knock: nil, clip: clip, region: region)
                w = try paint(w, shape: shape, cov: .map(maps.per[i][1], outside: 0), src: .color(b.shadowColor.rgb), blend: b.shadow.blend,
                              opacity: b.shadow.opacity, knock: nil, clip: clip, region: region)
            }
        }
        // Layer opacity against the backdrop; outside the clip the backdrop is unchanged.
        let out = fresh()
        if clip != cell {
            let o = baseOp()
            k.dispatch(enc, try k.pipeline("pcr_copy"), op: o, grid: grid(o), textures: [Slot.a: backdrop, Slot.out: out])
        }
        var o = baseOp(clip)
        o.opacity = spec.opacity
        if atop { o.flags |= PCROp.flagAtop }
        k.dispatch(enc, try k.pipeline("pcr_fx_final"), op: o, grid: grid(o), textures: [Slot.a: w, Slot.b: backdrop, Slot.out: out])
        recycle(w); recycle(shape)
        if let vsTex { recycle(vsTex) }
        return out
    }

    func glowSource(_ g: Glow, _ sb: PixelRect, _ anchor: SIMD2<Double>) -> FxPaintSource {
        if case .gradient(let gr) = g.paint { return .glowGradient(gr, gain: EffectMath.glowGradientGain(g.range)) }
        return paintSource(g.paint, frame: sb, anchor: anchor)
    }

    mutating func scaleAlpha(_ target: any MTLTexture, shape: any MTLTexture, byShape: Bool, fill: Float, clip: PixelRect) throws -> any MTLTexture {
        var o = baseOp(clip)
        if byShape { o.flags |= PCROp.fxShapeAlpha }
        o.p0.x = fill
        let out = fresh()
        k.dispatch(enc, try k.pipeline("pcr_fx_scale_alpha"), op: o, grid: grid(o), textures: [Slot.a: target, Slot.c: shape, Slot.out: out])
        recycle(target)
        return out
    }
}

extension MetalCompositor {
    /// Reads a single-channel map back (tests and diagnostics).
    func readMap(_ t: any MTLTexture) throws -> [Float] {
        guard let shared = context.makeTexture(width: t.width, height: t.height, pixelFormat: .r32Float, usage: [.shaderRead]),
              let cb = context.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { throw MetalCompositorError.gpu("readMap") }
        blit.copy(from: t, to: shared)
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        return context.readImage(shared, rect: PixelRect(x: 0, y: 0, width: t.width, height: t.height), channels: 1).data
    }

    /// The GPU effect maps of `spec` (tests): every map read back, in `FxMaps.per` order.
    func debugMaps(_ spec: EffectsSpec, ctx: RenderContext, source: any RenderSource) throws -> [[[Float]]] {
        var cb: (any MTLCommandBuffer)?
        var enc: (any MTLComputeCommandEncoder)?
        let maps = try gpuMaps(spec, ctx: ctx, source: source) {
            if let enc { return enc }
            cb = context.queue.makeCommandBuffer()
            enc = cb!.makeComputeCommandEncoder()
            return enc!
        }
        enc?.endEncoding(); cb?.commit(); cb?.waitUntilCompleted()
        return try maps.per.map { try $0.map { try readMap($0) } }
    }
}
