// Port of photocraft-compose (crates/compose/src/lib.rs, advanced.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The CPU reference compositor: runs a `RenderPlan` over a region in independent 256² tiles in
// parallel (photocraft's `render_tiled`), after building every effect map, feathered mask and
// adjustment table the plan needs once, up front (`prepare_effects`). Effect maps and combined
// masks are cached across renders by leaf version under a byte budget.

import Foundation
import PCDocument
import PCFoundation
import simd

public final class CPUCompositor: @unchecked Sendable {
    /// Side of the independent render tiles.
    public let tileSize: Int
    /// Bytes the effect-map and mask caches may hold.
    public var cacheBudget: Int

    private let lock = NSLock()
    private var fxCache: [FxKey: (maps: FxMaps, tick: UInt64)] = [:]
    private var maskCache: [MaskKey: (mask: CombinedMask, tick: UInt64)] = [:]
    private var tick: UInt64 = 0

    struct FxKey: Hashable {
        let layer: UInt64, shapeVersion: UInt64, effects: Effects, region: PixelRect, light: GlobalLight
        let vectorShape: Bool, outline: Bool
    }

    struct MaskKey: Hashable {
        let spec: MaskSpec, pixelVersion: UInt64, vectorVersion: UInt64, canvas: PixelRect
    }

    public init(tileSize: Int = 256, cacheBudget: Int = 768 << 20) {
        self.tileSize = max(16, tileSize)
        self.cacheBudget = cacheBudget
    }

    /// Drops every cached map and mask.
    public func purge() {
        lock.lock(); defer { lock.unlock() }
        fxCache.removeAll(); maskCache.removeAll()
    }

    /// Bytes held by cached effect maps and masks.
    public var cacheBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return fxCache.values.reduce(0) { $0 + $1.maps.bytes } + maskCache.values.reduce(0) { $0 + $1.mask.values.count * 4 }
    }

    /// Trims the cached maps and masks for memory pressure, oldest first: to half the bytes held on
    /// a warning, all of them when critical. Returns the bytes freed.
    @discardableResult
    public func trim(_ level: MemoryPressureRelay.Level) -> Int {
        lock.lock(); defer { lock.unlock() }
        let held = fxCache.values.reduce(0) { $0 + $1.maps.bytes } + maskCache.values.reduce(0) { $0 + $1.mask.values.count * 4 }
        let target = level == .critical ? 0 : held / 2
        var bytes = held
        while bytes > target && fxCache.count + maskCache.count > 0 {
            let oldFx = fxCache.min { $0.value.tick < $1.value.tick }
            let oldMask = maskCache.min { $0.value.tick < $1.value.tick }
            if let f = oldFx, oldMask.map({ f.value.tick < $0.value.tick }) ?? true {
                bytes -= f.value.maps.bytes; fxCache.removeValue(forKey: f.key)
            } else if let m = oldMask {
                bytes -= m.value.mask.values.count * 4; maskCache.removeValue(forKey: m.key)
            }
        }
        return held - bytes
    }

    /// Composites `plan` (planned over the document pixels `region`) at level of detail `level`: the
    /// reference for `MetalCompositor.render(_:region:level:source:)`, over the level pixels covering
    /// `region` (LevelOfDetail.swift).
    public func render(_ plan: RenderPlan, region: PixelRect, level: Int, sampled: Bool = false, source: any RenderSource) throws -> RGBABuffer {
        let l = LevelOfDetail.clamp(level)
        if l == 0 { return try render(plan, region: region, source: source) }
        return try render(plan.atLevel(l), region: LevelOfDetail.region(region, level: l), source: LevelSource(source, level: l, sampled: sampled))
    }

    /// Composites `plan` over `region` (straight-alpha RGBA).
    public func render(_ plan: RenderPlan, region: PixelRect, source: any RenderSource) throws -> RGBABuffer {
        try plan.validate()
        if region.isEmpty { return RGBABuffer(transparent: region) }
        let prepared = try prepare(plan, region: region, source: source)
        var out = RGBABuffer(transparent: region)
        var tiles: [PixelRect] = []
        let ts = Int32(tileSize)
        var y = region.y0
        while y < region.y1 {
            var x = region.x0
            let y1 = min(y + ts, region.y1)
            while x < region.x1 {
                let x1 = min(x + ts, region.x1)
                tiles.append(PixelRect(x0: x, y0: y, x1: x1, y1: y1))
                x = x1
            }
            y = y1
        }
        let tileList = tiles
        var parts = [RGBABuffer?](repeating: nil, count: tiles.count)
        let errors = ErrorBox()
        parts.withUnsafeMutableBufferPointer { pp in
            let P = UnsafeSendable(pp)
            DispatchQueue.concurrentPerform(iterations: tiles.count) { i in
                do {
                    var interp = Interpreter(plan: plan, prepared: prepared, source: source, rect: tileList[i])
                    P.value[i] = try interp.run()
                } catch { errors.set(error) }
            }
        }
        if let e = errors.error { throw e }
        for p in parts { if let p { out.paste(p) } }
        return out
    }

    final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var error: Error?
        func set(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
    }

    // MARK: Preparation

    /// What the tiles share: effect maps, combined masks, adjustment tables and filtered backdrops
    /// per op index.
    struct Prepared: @unchecked Sendable {
        var maps: [Int: FxMaps] = [:]
        var masks: [MaskSpec: CombinedMask] = [:]
        var adjustments: [Int: PreparedAdjustment] = [:]
        /// A backdrop filter's backdrop (when the op pushes it) and result, over the render region.
        var backdrops: [Int: (backdrop: RGBABuffer?, filtered: RGBABuffer)] = [:]
    }

    private func prepare(_ plan: RenderPlan, region: PixelRect, source: any RenderSource) throws -> Prepared {
        var p = Prepared()
        let ctx = plan.context
        func needMask(_ m: MaskSpec?) throws {
            guard let m, m.hasFeather, p.masks[m] == nil else { return }
            p.masks[m] = try combinedMask(m, ctx: ctx, source: source)
        }
        for (i, op) in plan.ops.enumerated() {
            switch op {
            case .adjust(let a):
                p.adjustments[i] = PreparedAdjustment(a, transfer: ctx.transfer, depth: ctx.depth, mode: ctx.mode, native: ctx.native)
            case .backdropFilter(let b):
                p.backdrops[i] = try backdrop(b, ctx: ctx, region: region, source: source)
            case .effect(let spec, _):
                p.maps[i] = try effectMaps(spec, ctx: ctx, source: source)
                try needMask(spec.vectorStrokeMask)
            case .drawTiles(let d): try needMask(d.mask)
            case .fill(let f): try needMask(f.mask)
            case .pushMaskShape(let m): try needMask(m)
            case .mask(let m): try needMask(m)
            case .adjustMix(let a): try needMask(a.mask)
            case .popGroup(.isolated(let m)): try needMask(m)
            case .popGroup(.passThrough(_, let m)): try needMask(m)
            default: break
            }
        }
        return p
    }

    private func touch() -> UInt64 { tick += 1; return tick }

    /// `b`'s program composited over the backdrop area of `region` (the region and the filter's
    /// reach within the canvas), and the filter of it over `region`.
    func backdrop(_ b: BackdropFilter, ctx: RenderContext, region: PixelRect, source: any RenderSource) throws -> (backdrop: RGBABuffer?, filtered: RGBABuffer) {
        let area = FilterMath.backdropArea(region, reach: FilterMath.reach(b.spec), canvas: ctx.canvas)
        let back = try render(RenderPlan(context: ctx, ops: b.program), region: area, source: source)
        var filtered: RGBABuffer
        if b.spec.filter.samplesNeighbours {
            filtered = FilterCPU.blur(b.spec, backdrop: back, canvas: ctx.canvas, over: region)
        } else {
            filtered = back.cropped(to: region)
            FilterCPU.apply(b.spec, to: &filtered, canvas: ctx.canvas, hdr: ctx.depth == .f32, native: ctx.native)
        }
        return (b.pushesBackdrop ? back : nil, filtered)
    }

    func combinedMask(_ spec: MaskSpec, ctx: RenderContext, source: any RenderSource) throws -> CombinedMask {
        func version(_ id: LeafID?) throws -> UInt64 {
            guard let id else { return 0 }
            guard let v = source.leafVersion(id) else { throw PlanError.missingLeaf(id) }
            return v
        }
        let key = MaskKey(spec: spec, pixelVersion: try version(spec.pixel), vectorVersion: try version(spec.vector), canvas: ctx.canvas)
        lock.lock()
        if let hit = maskCache[key] { maskCache[key] = (hit.mask, touch()); lock.unlock(); return hit.mask }
        lock.unlock()
        let pixel = try spec.pixel.map { id throws(PlanError) -> RenderLeaf in
            guard let l = source.leaf(id) else { throw PlanError.missingLeaf(id) }
            return l
        }
        let vector = try spec.vector.map { id throws(PlanError) -> RenderLeaf in
            guard let l = source.leaf(id) else { throw PlanError.missingLeaf(id) }
            return l
        }
        let m = MaskMath.buildCombined(spec, pixel: pixel, vector: vector, canvas: ctx.canvas)
        lock.lock()
        maskCache[key] = (m, touch())
        evict()
        lock.unlock()
        return m
    }

    func effectMaps(_ spec: EffectsSpec, ctx: RenderContext, source: any RenderSource) throws -> FxMaps {
        guard let shapeVersion = source.leafVersion(spec.shape) else { throw PlanError.missingLeaf(spec.shape) }
        let key = FxKey(layer: spec.layerID, shapeVersion: shapeVersion, effects: spec.effects, region: spec.region,
                        light: ctx.globalLight, vectorShape: spec.vectorShape, outline: spec.outline)
        lock.lock()
        if let hit = fxCache[key] { fxCache[key] = (hit.maps, touch()); lock.unlock(); return hit.maps }
        lock.unlock()
        guard let shapeLeaf = source.leaf(spec.shape) else { throw PlanError.missingLeaf(spec.shape) }
        let shape = spec.region.isEmpty ? [] : LeafReader.values(shapeLeaf, spec.region)
        let tex = EffectMath.TextureContext(rect: spec.region, anchor: spec.anchor) { id, name in source.pattern(id: id, name: name) }
        let maps = FxMaps.build(effects: spec.effects, shape: shape, rect: spec.region, light: ctx.globalLight,
                                vectorShape: spec.vectorShape, outline: spec.outline, texture: tex)
        lock.lock()
        fxCache[key] = (maps, touch())
        evict()
        lock.unlock()
        return maps
    }

    /// Oldest entries over budget go first (never the newest).
    private func evict() {
        var bytes = fxCache.values.reduce(0) { $0 + $1.maps.bytes } + maskCache.values.reduce(0) { $0 + $1.mask.values.count * 4 }
        while bytes > cacheBudget && fxCache.count + maskCache.count > 1 {
            let oldFx = fxCache.min { $0.value.tick < $1.value.tick }
            let oldMask = maskCache.min { $0.value.tick < $1.value.tick }
            if let f = oldFx, oldMask.map({ f.value.tick < $0.value.tick }) ?? true {
                bytes -= f.value.maps.bytes; fxCache.removeValue(forKey: f.key)
            } else if let m = oldMask {
                bytes -= m.value.mask.values.count * 4; maskCache.removeValue(forKey: m.key)
            } else { break }
        }
    }

    // MARK: Interpreter

    struct Interpreter {
        let plan: RenderPlan
        let prepared: Prepared
        let source: any RenderSource
        let rect: PixelRect
        var stack: [RGBABuffer] = []
        var floors: [RGBABuffer] = []

        init(plan: RenderPlan, prepared: Prepared, source: any RenderSource, rect: PixelRect) {
            self.plan = plan; self.prepared = prepared; self.source = source; self.rect = rect
        }

        var space: BlendSpace { plan.context.space }

        func leaf(_ id: LeafID) throws -> RenderLeaf {
            guard let l = source.leaf(id) else { throw PlanError.missingLeaf(id) }
            return l
        }

        /// `mask_vals` over the tile (nil: no mask).
        func maskValues(_ spec: MaskSpec?) throws -> [Float]? {
            guard let spec else { return nil }
            if spec.hasFeather, let m = prepared.masks[spec] { return m.read(rect) }
            var v: [Float]?
            if let p = spec.pixel {
                var pv = LeafReader.values(try leaf(p), rect)
                if spec.density < 1 { for i in pv.indices { pv[i] = 1 - spec.density * (1 - pv[i]) } }
                v = pv
            }
            if let vid = spec.vector {
                let vv = LeafReader.values(try leaf(vid), rect)
                if var pv = v { for i in pv.indices { pv[i] *= vv[i] }; v = pv } else { v = vv }
            }
            return v ?? [Float](repeating: 1, count: rect.area)
        }

        func applyMask(_ buf: inout RGBABuffer, _ spec: MaskSpec?) throws {
            guard let m = try maskValues(spec) else { return }
            for i in buf.px.indices { buf.px[i].w *= m[i] }
        }

        mutating func pop() -> RGBABuffer { stack.removeLast() }

        mutating func run() throws -> RGBABuffer {
            for (i, op) in plan.ops.enumerated() { try exec(op, i) }
            return stack[0]
        }

        mutating func exec(_ op: DrawOp, _ index: Int) throws {
            let space = self.space
            switch op {
            case .pushGroup(.isolated), .pushTransparent:
                stack.append(RGBABuffer(transparent: rect))
            case .pushGroup(.passThrough):
                stack.append(stack[stack.count - 1])
            case .popGroup(.isolated(let m)):
                try applyMask(&stack[stack.count - 1], m)
            case let .popGroup(.passThrough(opacity, m)):
                let after = pop(), before = pop()
                if opacity >= 1 && m == nil { stack.append(after); return }
                let mv = try maskValues(m)
                var out = after
                for i in out.px.indices {
                    let k = opacity * (mv?[i] ?? 1)
                    let a = before.px[i], b = after.px[i]
                    let wa = a.w * (1 - k), wb = b.w * k
                    let alpha = wa + wb
                    out.px[i] = alpha > 0 ? SIMD4((SIMD3(a.x, a.y, a.z) * wa + SIMD3(b.x, b.y, b.z) * wb) / alpha, alpha) : .zero
                }
                stack.append(out)
            case .pick(let n):
                stack.append(stack[stack.count - 1 - n])
            case .drop:
                stack.removeLast()
            case .swap:
                stack.swapAt(stack.count - 1, stack.count - 2)
            case .remove(let n):
                stack.remove(at: stack.count - 1 - n)
            case .drawTiles(let d):
                var b = RGBABuffer(transparent: rect)
                if let id = d.leaf { b = RGBABuffer(rect: rect, px: LeafReader.rgba(try leaf(id), rect)) }
                try applyMask(&b, d.mask)
                stack.append(b)
            case .fill(let f):
                var b = FillRender.render(f.fill, rect: rect, frame: f.frame, quantum: plan.context.quantum, store: plan.context.storageQuantum,
                                          source: source)
                try applyMask(&b, f.mask)
                stack.append(b)
            case .pushMaskShape(let m):
                let mv = try maskValues(m)
                stack.append(RGBABuffer(rect: rect, px: (0..<rect.area).map { SIMD4(0, 0, 0, mv?[$0] ?? 1) }))
            case .mask(let m):
                try applyMask(&stack[stack.count - 1], m)
            case .composite(let lb):
                let src = pop()
                Compose.blendIntoFill(&stack[stack.count - 1], src, lb, space)
            case .beginClipBase:
                break
            case .clipped(let lb):
                let src = pop()
                Compose.atop(&stack[stack.count - 1], src, lb, space)
            case .adjust:
                prepared.adjustments[index]?.apply(to: &stack[stack.count - 1])
            case .filter(let spec):
                let ctx = plan.context
                FilterCPU.apply(spec, to: &stack[stack.count - 1], canvas: ctx.canvas, hdr: ctx.depth == .f32, native: ctx.native)
            case .backdropFilter:
                guard let b = prepared.backdrops[index] else { throw PlanError.stackUnderflow(op: index) }
                if let back = b.backdrop { stack.append(back.cropped(to: rect)) }
                stack.append(b.filtered.cropped(to: rect))
            case .adjustMix(let a):
                let adjusted = pop()
                let mv = try maskValues(a.mask)
                Compose.adjustMix(&stack[stack.count - 1], adjusted, a, mv, space)
            case .quantize(let q):
                let top = stack.count - 1
                for i in stack[top].px.indices { stack[top].px[i] = ((stack[top].px[i] * q + 0.5).rounded(.down)) / q }
            case .finishLayer(let f):
                let after = pop()
                let own = f.hasOwn ? pop() : nil
                let before = pop()
                stack.append(Compose.finish(before: before, own: own, after: after, f, rgbMode: plan.context.mode == .rgb, ps8: plan.context.space.ps8))
            case let .effect(spec, atop):
                let content = pop()
                guard let maps = prepared.maps[index] else { return }
                var vs: (RGBABuffer, [Float]?)?
                if let sid = spec.vectorStroke {
                    vs = (RGBABuffer(rect: rect, px: LeafReader.rgba(try leaf(sid), rect)), try maskValues(spec.vectorStrokeMask))
                }
                let src = source
                let patterns: EffectsCPU.Patterns = { id, name in src.pattern(id: id, name: name) }
                let top = stack.count - 1
                if atop {
                    let base = stack[top]
                    var opaque = base
                    for i in opaque.px.indices { opaque.px[i].w = 1 }
                    EffectsCPU.composite(spec, content: content, backdrop: &opaque, maps: maps, vectorStroke: vs, patterns: patterns, space: space)
                    for i in stack[top].px.indices where base.px[i].w > 0 {
                        let o = opaque.px[i]
                        stack[top].px[i] = SIMD4(o.x, o.y, o.z, base.px[i].w)
                    }
                } else {
                    EffectsCPU.composite(spec, content: content, backdrop: &stack[top], maps: maps, vectorStroke: vs, patterns: patterns, space: space)
                }
            case .saveFloor:
                floors.append(stack[stack.count - 1])
            case .pushFloor:
                stack.append(floors[floors.count - 1])
            case .dropFloor:
                floors.removeLast()
            case .knockoutBegin(let clipAlpha):
                let backdrop = pop(), shape = pop(), target = pop()
                var knocked = backdrop
                for i in knocked.px.indices {
                    let k = shape.px[i].w
                    if k > 0 {
                        let a = knocked.px[i].w
                        knocked.px[i] = PSBlend.mixClamped(knocked.px[i], target.px[i], min(k, 1))
                        if clipAlpha { knocked.px[i].w = min(knocked.px[i].w, a) }
                    }
                }
                stack.append(contentsOf: [backdrop, shape, knocked, knocked])
            case .knockoutEnd(let opacity):
                var after = pop()
                let knocked = pop(), shape = pop(), before = pop()
                if opacity < 1 {
                    let rest = 1 - min(max(opacity, 0), 1)
                    for i in after.px.indices where shape.px[i].w > 0 {
                        let p = after.px[i], b = before.px[i], k = knocked.px[i]
                        var pm = SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                        pm += rest * (SIMD4(b.x * b.w, b.y * b.w, b.z * b.w, b.w) - SIMD4(k.x * k.w, k.y * k.w, k.z * k.w, k.w))
                        let a = min(max(pm.w, 0), 1)
                        after.px[i] = a > 0 ? SIMD4(min(max(pm.x / a, 0), 1), min(max(pm.y / a, 0), 1), min(max(pm.z / a, 0), 1), a) : .zero
                    }
                }
                stack.append(after)
            case .mixBy(let k):
                let shape = pop()
                var after = pop()
                let before = pop()
                for i in after.px.indices {
                    let m = shape.px[i].w * k
                    if m < 1 { after.px[i] = PSBlend.mixClamped(before.px[i], after.px[i], max(m, 0)) }
                }
                stack.append(after)
            case .addDifference:
                let without = pop(), with = pop()
                var a = pop()
                for i in a.px.indices {
                    let p = a.px[i], w = with.px[i], o = without.px[i]
                    var pm = SIMD4(p.x * p.w, p.y * p.w, p.z * p.w, p.w)
                    pm += SIMD4(w.x * w.w, w.y * w.w, w.z * w.w, w.w) - SIMD4(o.x * o.w, o.y * o.w, o.z * o.w, o.w)
                    let al = min(max(pm.w, 0), 1)
                    a.px[i] = al > 0 ? SIMD4(min(max(pm.x / al, 0), 1), min(max(pm.y / al, 0), 1), min(max(pm.z / al, 0), 1), al) : .zero
                }
                stack.append(a)
            case .restrictTo(let r):
                let after = pop()
                var before = pop()
                let inside = r.intersect(rect)
                if !inside.isEmpty { before.paste(after.cropped(to: inside)) }
                stack.append(before)
            }
        }
    }
}

/// Per-pixel compositing steps of compose's `lib.rs` (shared by the interpreter ops).
enum Compose {
    /// `blend_into_fill` / `blend_into_g`, Dissolve included.
    static func blendIntoFill(_ backdrop: inout RGBABuffer, _ src: RGBABuffer, _ lb: LayerBlend, _ space: BlendSpace) {
        let rect = backdrop.rect, w = rect.width
        let special = lb.fill < 1 && PSBlend.fillIsSpecial(lb.mode)
        let opacity = special ? lb.opacity : lb.opacity * lb.fill
        backdrop.px.withUnsafeMutableBufferPointer { bp in
            src.px.withUnsafeBufferPointer { sp in
                let (B, S) = (UnsafeSendable(bp), UnsafeSendable(sp))
                parallelRows(rect.height, width: w) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        var s = S.value[i]
                        if s.w <= 0 { continue }
                        let b = B.value[i]
                        if special {
                            B.value[i] = PSBlend.compositeFill(lb.mode, b, s, opacity: lb.opacity, fill: lb.fill, gamma: lb.textGamma, space)
                        } else if lb.mode == .dissolve {
                            s.w = PSBlend.dissolveDraws(rect.x0 + Int32(x), rect.y0 + Int32(y), opacity: lb.opacity, fill: lb.fill, coverage: s.w) ? 1 : 0
                            B.value[i] = PSBlend.composite(.normal, b, s, 1, space)
                        } else if lb.mode == .normal && lb.textGamma == 1 && !space.lab {
                            B.value[i] = PSBlend.compositeNormalRGB(b, s, opacity)
                        } else {
                            B.value[i] = PSBlend.compositeGamma(lb.mode, b, s, opacity, lb.textGamma, space)
                        }
                    }
                }
            }
        }
    }

    /// `composite_atop` (no effects): blend as if the base were opaque, keep the base's alpha.
    static func atop(_ base: inout RGBABuffer, _ src: RGBABuffer, _ lb: LayerBlend, _ space: BlendSpace) {
        let opacity = lb.opacity * lb.fill
        for i in base.px.indices {
            let p = base.px[i]
            if p.w <= 0 { continue }
            let r = PSBlend.compositeGamma(lb.mode, SIMD4(p.x, p.y, p.z, 1), src.px[i], opacity, lb.textGamma, space)
            base.px[i] = SIMD4(r.x, r.y, r.z, p.w)
        }
    }

    /// An adjustment layer's result mixed back in with its blend mode, opacity and mask.
    static func adjustMix(_ backdrop: inout RGBABuffer, _ adjusted: RGBABuffer, _ a: AdjustMix, _ mask: [Float]?, _ space: BlendSpace) {
        let premultiplied = a.coverage && a.mode == .normal
        for i in backdrop.px.indices {
            let k = a.opacity * (mask?[i] ?? 1)
            if k <= 0 { continue }
            let b = backdrop.px[i], ad = adjusted.px[i]
            if premultiplied {
                // Colour and coverage mixed premultiplied (a blur spreads into clear pixels).
                let alpha = b.w + (ad.w - b.w) * k
                let pb = SIMD3(b.x, b.y, b.z) * b.w, pa = SIMD3(ad.x, ad.y, ad.z) * ad.w
                let c = pb + (pa - pb) * k
                backdrop.px[i] = alpha > 0 ? SIMD4(c / alpha, alpha) : .zero
                continue
            }
            let cb = SIMD3(b.x, b.y, b.z)
            let bl = PSBlend.blend(a.mode, cb, SIMD3(ad.x, ad.y, ad.z), space)
            backdrop.px[i] = SIMD4(cb + (bl - cb) * k, b.w)
        }
    }

    /// Channel restrictions then Blend If on a finished composite.
    static func finish(before: RGBABuffer, own: RGBABuffer?, after a: RGBABuffer, _ f: FinishLayer, rgbMode: Bool, ps8: Bool = false) -> RGBABuffer {
        var out = a
        if let w = f.channels {
            for i in out.px.indices {
                let b = before.px[i], p = out.px[i]
                out.px[i] = SIMD4(b.x + (p.x - b.x) * w.x, b.y + (p.y - b.y) * w.y, b.z + (p.z - b.z) * w.z, p.w)
            }
        }
        if let bi = f.blendIf {
            for i in out.px.indices {
                let p = out.px[i], b = before.px[i]
                let this: SIMD4<Float>? = own.map { o in o.px[i].w > 0 ? o.px[i] : nil } ?? p
                let under: SIMD4<Float>? = b.w > 0 ? b : nil
                let k = BlendIfMath.weight(bi, rgbMode: rgbMode, this: this, under: under, ps8: ps8)
                if k >= 1 { continue }
                let alpha = b.w + (p.w - b.w) * k
                if alpha > 0 {
                    var o = SIMD4<Float>(0, 0, 0, alpha)
                    for c in 0..<3 { o[c] = min(max((b[c] * b.w + (p[c] * p.w - b[c] * b.w) * k) / alpha, 0), 1) }
                    out.px[i] = o
                } else {
                    out.px[i] = .zero
                }
            }
        }
        return out
    }
}

/// Fill layer content (`compose::render_fill`).
enum FillRender {
    /// Fill content over `rect`: a dithered gradient rounded to the adjustment `quantum`, then
    /// every channel to the document's stored depth `store` (Photoshop keeps fill layers' pixels
    /// at the document's depth; photocraft-compose renders them so).
    static func render(_ fill: Fill, rect: PixelRect, frame: PixelRect, quantum: Float?, store: Float? = nil, source: any RenderSource) -> RGBABuffer {
        var out = content(fill, rect: rect, frame: frame, quantum: quantum, source: source)
        if let q = store {
            out.px.withUnsafeMutableBufferPointer { p in
                for i in p.indices { p[i] = ((simd_clamp(p[i], .zero, SIMD4(repeating: 1)) * q + 0.5).rounded(.down)) / q }
            }
        }
        return out
    }

    static func content(_ fill: Fill, rect: PixelRect, frame: PixelRect, quantum: Float?, source: any RenderSource) -> RGBABuffer {
        switch fill {
        case .solid(let c):
            return RGBABuffer(rect: rect, filled: SIMD4(c.rgb, c.alpha))
        case .gradient(let g):
            let ramp = GradientMath.FillRamp(g)
            let (angle, scale, offset) = GradientMath.layout(g.style, angle: g.angle, scale: g.scale, offset: g.offset, frame: frame)
            var out = RGBABuffer(transparent: rect)
            let w = rect.width
            out.px.withUnsafeMutableBufferPointer { op in
                let O = UnsafeSendable(op)
                parallelRows(rect.height, width: w) { j in
                    let y = rect.y0 + Int32(j)
                    for i in 0..<w {
                        let x = rect.x0 + Int32(i)
                        let t = GradientMath.t(g.style, angle: angle, scale: scale, reverse: g.reverse, offset: offset, bounds: frame,
                                               x: Float(x) + 0.5, y: Float(y) + 0.5)
                        var p = ramp.sample(t)
                        if g.dither { p = GradientMath.dither(p, x, y, quantum) }
                        O.value[j * w + i] = p
                    }
                }
            }
            return out
        case .pattern(let pf):
            guard let tile = source.pattern(id: pf.id, name: pf.name), tile.isPaintable else { return RGBABuffer(transparent: rect) }
            let place = PatternPlacement(frame: frame, link: pf.link, phase: pf.phase, scale: pf.scale, angle: pf.angle)
            var out = RGBABuffer(transparent: rect)
            let w = rect.width
            for j in 0..<rect.height {
                for i in 0..<w {
                    let (u, v) = place.map(Double(rect.x0 + Int32(i)) + 0.5, Double(rect.y0 + Int32(j)) + 0.5)
                    out.px[j * w + i] = tile.sample(u, v)
                }
            }
            return out
        }
    }
}
