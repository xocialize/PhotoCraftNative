// Port of photocraft-compose (crates/compose/src/effects.rs, `composite_with_effects`) and photocraft-gpu (plan.rs `effects`, compose.wgsl `fs_fx*`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Compositing a layer with its effects, bottom to top: drop shadows, outer glows (into a copy of
// the backdrop), then the layer at fill opacity with pattern / gradient / colour overlays, satin,
// inner glows, inner shadows, inside strokes and the inner bevel painted relative to its shape;
// outside strokes and the outer bevel beneath it; the layer merged in its blend mode; emboss styles
// shading the result; layer opacity mixing the whole stack against the backdrop.

import Foundation
import PCDocument
import PCFoundation

/// How a layer with effects composites (the planner fills this from the layer).
public struct EffectsSpec: Sendable, Hashable {
    /// Identifies the layer for map caching (with `shape`'s version).
    public var layerID: UInt64
    public var effects: Effects
    /// The effect shape over `region` (`compose::layer_shape`).
    public var shape: LeafID
    /// Region the maps cover (layer bounds grown by `EffectMath.margin`, within the canvas grown alike).
    public var region: PixelRect
    /// Frame gradients and linked patterns are laid out in (`paint_bounds` / `layer_bounds`).
    public var bounds: PixelRect
    public var blend: BlendMode
    public var opacity: Float
    public var fillOpacity: Float
    /// Text blending gamma of a type layer (1 = off).
    public var textGamma: Float
    /// A shape layer (outside strokes follow its outline, never its interior).
    public var vectorShape: Bool
    /// The shape joins a filled shape's outline (`effect_outline`).
    public var outline: Bool
    /// Transparency Shapes Layer off.
    public var shapeless: Bool
    /// Blend Interior Effects as Group.
    public var blendInterior: Bool
    /// A stroked shape's vector stroke (above interior effects) and the mask for fill ∪ stroke.
    public var vectorStroke: LeafID?
    public var vectorStrokeMask: MaskSpec?
    /// Where compositing the layer can change pixels (photocraft-gpu's effect clip: the region when
    /// the layer is transparent outside it); nil = everywhere. The GPU computes the effect passes only
    /// there; the CPU reference ignores it (its result is the same).
    public var clip: PixelRect?

    public init(layerID: UInt64, effects: Effects, shape: LeafID, region: PixelRect, bounds: PixelRect,
                blend: BlendMode = .normal, opacity: Float = 1, fillOpacity: Float = 1, textGamma: Float = 1,
                vectorShape: Bool = false, outline: Bool = false, shapeless: Bool = false, blendInterior: Bool = false,
                vectorStroke: LeafID? = nil, vectorStrokeMask: MaskSpec? = nil, clip: PixelRect? = nil) {
        self.layerID = layerID; self.effects = effects; self.shape = shape; self.region = region; self.bounds = bounds
        self.blend = blend; self.opacity = opacity; self.fillOpacity = fillOpacity; self.textGamma = textGamma
        self.vectorShape = vectorShape; self.outline = outline; self.shapeless = shapeless; self.blendInterior = blendInterior
        self.vectorStroke = vectorStroke; self.vectorStrokeMask = vectorStrokeMask; self.clip = clip
    }

    /// Linked patterns tile from the effects reference point (else the layer's top-left).
    var anchor: SIMD2<Double> { effects.reference ?? SIMD2(Double(bounds.x0), Double(bounds.y0)) }
}

enum EffectsCPU {
    typealias Patterns = @Sendable (String, String) -> PatternTile?

    /// Composite `color × coverage` into `dst`.
    static func paint(_ dst: inout RGBABuffer, _ m: [Float], _ color: (Int) -> SIMD4<Float>, _ blend: BlendMode, _ opacity: Float, _ space: BlendSpace) {
        for i in dst.px.indices {
            let a = m[i] * opacity
            if a <= 0 { continue }
            let c = color(i)
            dst.px[i] = PSBlend.composite(blend, dst.px[i], SIMD4(c.x, c.y, c.z, c.w * a), 1, space)
        }
    }

    static func paintColor(_ dst: inout RGBABuffer, _ m: [Float], _ c: SIMD3<Float>, _ blend: BlendMode, _ opacity: Float, _ space: BlendSpace) {
        let col = SIMD4(c, 1)
        paint(&dst, m, { _ in col }, blend, opacity, space)
    }

    static func pixelCentre(_ big: PixelRect, _ i: Int) -> (Float, Float) {
        let w = big.width
        return (Float(big.x0 + Int32(i % w)) + 0.5, Float(big.y0 + Int32(i / w)) + 0.5)
    }

    static func paintPattern(_ dst: inout RGBABuffer, _ m: [Float], _ tile: PatternTile?, _ place: PatternPlacement,
                             _ blend: BlendMode, _ opacity: Float, _ space: BlendSpace) {
        guard let tile, tile.isPaintable else { return }
        let big = dst.rect, w = big.width
        paint(&dst, m, { i in
            let (u, v) = place.map(Double(big.x0 + Int32(i % w)) + 0.5, Double(big.y0 + Int32(i / w)) + 0.5)
            return tile.sample(u, v)
        }, blend, opacity, space)
    }

    static func paintFx(_ dst: inout RGBABuffer, _ m: [Float], _ p: FxPaint, _ shapeBounds: PixelRect, _ anchor: SIMD2<Double>,
                        _ blend: BlendMode, _ opacity: Float, _ patterns: Patterns, _ space: BlendSpace) {
        switch p {
        case .color(let c): paintColor(&dst, m, c.rgb, blend, opacity, space)
        case .gradient(let g):
            let ramp = GradientMath.EffectRamp(g)
            let (angle, scale, offset) = GradientMath.layout(g.style, angle: g.angle, scale: g.scale, offset: g.offset, frame: shapeBounds)
            let big = dst.rect
            paint(&dst, m, { i in
                let (x, y) = pixelCentre(big, i)
                return ramp.sample(GradientMath.t(g.style, angle: angle, scale: scale, reverse: g.reverse, offset: offset, bounds: shapeBounds, x: x, y: y))
            }, blend, opacity, space)
        case .pattern(let pr):
            paintPattern(&dst, m, patterns(pr.id, pr.name), PatternPlacement(anchor: anchor, link: true, phase: .zero, scale: pr.scale, angle: 0), blend, opacity, space)
        }
    }

    static func paintGlow(_ dst: inout RGBABuffer, _ m: [Float], _ g: Glow, _ shapeBounds: PixelRect, _ anchor: SIMD2<Double>,
                          _ patterns: Patterns, _ space: BlendSpace) {
        guard case .gradient(let gradient) = g.paint else {
            return paintFx(&dst, m, g.paint, shapeBounds, anchor, g.common.blend, g.common.opacity, patterns, space)
        }
        let ramp = GradientMath.EffectRamp(gradient)
        let gain = EffectMath.glowGradientGain(g.range)
        let strength = m.map { min($0 * gain, 1) }
        paint(&dst, strength, { i in ramp.sample(1 - min(max(m[i], 0), 1)) }, g.common.blend, g.common.opacity, space)
    }

    /// How much of a drop shadow / outer glow shows beneath a layer of shape coverage `a` at fill
    /// opacity `fill`: `(1 − a) / (1 − fill·a)`. The shape hides it whole where the layer is
    /// see-through (ps-corpus fill-vs-opacity: at 40 % fill the shadow is gone under the layer;
    /// photocraft's `1 − a·(1 − fill)` left 40 % of it, 32 levels), and at 100 % fill an
    /// anti-aliased edge isn't attenuated twice (`shadowKnockoutNeedsSeeThroughFill`).
    @inline(__always) static func knockout(_ a0: Float, _ fill0: Float) -> Float {
        let a = min(max(a0, 0), 1), f = min(max(fill0, 0), 1)
        let d = 1 - f * a
        return d <= 1e-6 ? 1 : (1 - a) / d
    }

    /// An outside stroke's share of an edge pixel the outline covers `cov` of, beneath a layer of alpha `l`.
    /// Nothing of a pixel the shape covers whole: photocraft painted the stroke beneath an opaque
    /// interior (invisible in Normal, but a Soft Light layer then blends with the stroke there:
    /// ps-corpus combined-rgb-16, 206 levels).
    @inline(__always) static func outlineShare(_ cov: Float, _ l: Float) -> Float {
        let outside = max(1 - min(max(cov, 0), 1), 0)
        let rest = 1 - min(max(l, 0), 1)
        return rest <= 1e-6 ? (outside > 0 ? 1 : 0) : min(outside / rest, 1)
    }

    /// `composite_with_effects_prepared`: `content` (the layer's pixels over the backdrop's rect,
    /// masked, clipped layers applied) plus its effects into `backdrop`.
    static func composite(_ spec: EffectsSpec, content: RGBABuffer, backdrop: inout RGBABuffer, maps: FxMaps,
                          vectorStroke: (stroke: RGBABuffer, mask: [Float]?)?, patterns: @escaping Patterns, space: BlendSpace) {
        let big = content.rect
        let n = big.area
        let kmask: (Int) -> Float = { i in vectorStroke?.mask?[i] ?? 1 }
        func union(_ i: Int, _ a: Float) -> Float {
            guard let vs = vectorStroke else { return a }
            return kmask(i) * (a + vs.stroke.px[i].w * (1 - a))
        }
        let shape: [Float]
        if spec.shapeless {
            shape = maps.cropVec(maps.shape.v, to: big, fill: 0)
        } else if maps.outline {
            let o = maps.cropVec(maps.shape.v, to: big, fill: 0)
            shape = (0..<n).map { max(o[$0], union($0, content.px[$0].w)) }
        } else {
            shape = (0..<n).map { union($0, content.px[$0].w) }
        }
        let relative = spec.shapeless || maps.outline || vectorStroke != nil
        func fx(_ i: Int, _ k: Int) -> [Float] { maps.cropVec(maps.per[i][k].v, to: big, fill: 0) }
        let sb = spec.bounds
        let anchor = spec.anchor
        let before = backdrop
        var work = backdrop
        let items = spec.effects.items.filter(\.isEnabled)
        let rev = Array(items.enumerated().reversed())
        let fill = spec.fillOpacity
        func inside(_ a: Float) -> Bool { a > insideEps }

        for (i, e) in rev {
            if case .dropShadow(let s) = e {
                var m = fx(i, 0)
                if s.knocksOut { for k in 0..<n { m[k] *= knockout(shape[k], fill) } }
                paintColor(&work, m, s.color.rgb, s.common.blend, s.common.opacity, space)
            }
        }
        for (i, e) in rev {
            if case .outerGlow(let g) = e {
                var m = fx(i, 0)
                for k in 0..<n { m[k] *= knockout(shape[k], fill) }
                paintGlow(&work, m, g, sb, anchor, patterns, space)
            }
        }

        let interiorGroup = spec.blendInterior && fill < 1
        let contentFill: Float = interiorGroup ? 1 : fill
        // Transparency Shapes Layer off with Blend Interior Effects as Group: the grouped interior
        // effects are drawn atop the content, its transparency still hides them (ps-corpus
        // advanced-flags: no overlay where the layer is empty; photocraft paints them across the
        // whole layer).
        let clipInterior = spec.shapeless && spec.blendInterior && vectorStroke == nil
        func relAlpha(_ k: Int) -> Float { min(kmask(k) * content.px[k].w / shape[k], 1) }
        var lay = RGBABuffer(rect: big, px: (0..<n).map { k in
            let p = content.px[k], a = shape[k]
            let alpha: Float = !inside(a) ? 0 : (relative && !clipInterior ? contentFill * relAlpha(k) : contentFill)
            return SIMD4(p.x, p.y, p.z, alpha)
        })
        func rel(_ m: [Float]) -> [Float] { (0..<n).map { inside(shape[$0]) ? min(m[$0] / shape[$0], 1) : 0 } }
        let full = shape.map { inside($0) ? Float(1) : 0 }
        for (_, e) in rev {
            if case .patternOverlay(let po) = e {
                paintPattern(&lay, full, patterns(po.id, po.name), PatternPlacement(anchor: anchor, link: po.link, phase: po.phase, scale: po.scale, angle: po.angle),
                             po.common.blend, po.common.opacity, space)
            }
        }
        for (_, e) in rev {
            if case .gradientOverlay(let go) = e {
                paintFx(&lay, full, .gradient(go.gradient), sb, anchor, go.common.blend, go.common.opacity, patterns, space)
            }
        }
        for (_, e) in rev {
            if case .colorOverlay(let co) = e { paintColor(&lay, full, co.color.rgb, co.common.blend, co.common.opacity, space) }
        }
        for (i, e) in rev {
            if case .satin(let s) = e { paintColor(&lay, rel(fx(i, 0)), s.color.rgb, s.common.blend, s.common.opacity, space) }
        }
        for (i, e) in rev {
            if case .innerGlow(let g) = e { paintGlow(&lay, rel(fx(i, 0)), g, sb, anchor, patterns, space) }
        }
        if clipInterior { for k in 0..<n where inside(shape[k]) { lay.px[k].w *= relAlpha(k) } }
        if interiorGroup { for k in 0..<n { lay.px[k].w *= max(fill, 0) } }
        for (i, e) in rev {
            if case .innerShadow(let s) = e { paintColor(&lay, rel(fx(i, 0)), s.color.rgb, s.common.blend, s.common.opacity, space) }
        }
        if let vs = vectorStroke {
            for k in 0..<n {
                let s = vs.stroke.px[k], a = shape[k]
                if s.w > 0 && inside(a) {
                    lay.px[k] = PSBlend.composite(.normal, lay.px[k], SIMD4(s.x, s.y, s.z, fill * min(kmask(k) * s.w / a, 1)), 1, space)
                }
            }
        }
        let strokes: [StrokeFx] = items.compactMap { if case .stroke(let s) = $0 { s } else { nil } }
        var din: [Float] = [], dout: [Float] = []
        if !strokes.isEmpty, let a = maps.din, let b = maps.dout {
            din = maps.cropVec(a, to: big, fill: 0); dout = maps.cropVec(b, to: big, fill: farDistance)
        }
        func frame(_ st: StrokeFx) -> PixelRect { maps.strokeFrame(st) ?? sb }
        for st in strokes.reversed() {
            let inW = EffectMath.strokeWidths(st).inner
            if inW <= 0 { continue }
            let m = (0..<n).map { k -> Float in inside(shape[k]) ? min(max(inW + 0.5 - din[k], 0), 1) : 0 }
            paintFx(&lay, m, st.paint, frame(st), anchor, st.common.blend, st.common.opacity, patterns, space)
        }
        for (i, e) in rev {
            if case .bevelEmboss(let b) = e, maps.bevelPaint[i] == .inner {
                paintColor(&lay, rel(fx(i, 0)), b.highlightColor.rgb, b.highlight.blend, b.highlight.opacity, space)
                paintColor(&lay, rel(fx(i, 1)), b.shadowColor.rgb, b.shadow.blend, b.shadow.opacity, space)
            }
        }
        for k in 0..<n { lay.px[k].w *= min(shape[k], 1) }
        let vdout: [Float]? = (spec.vectorShape && !strokes.isEmpty) ? maps.vdout.map { maps.cropVec($0, to: big, fill: farDistance) } : nil
        // Outside strokes. A pixel the shape covers by `a` splits: the stroke takes the rest of it
        // (1 − a, its band and opacity) over the exterior result, and the layer takes `a`, blended
        // against the exterior result without the stroke (ps-corpus combined-rgb-16: a Soft
        // Light layer under a gradient mask, 0.18 levels mean in the masked interior; photocraft
        // puts the stroke beneath the layer, which then blends with it, and only at the shape's
        // edge). A filled shape's outline, an outer bevel and type (its gamma-blended edges over
        // the stroke, ps-corpus text-effects) keep the stroke beneath the layer.
        let outer = strokes.contains(where: { EffectMath.strokeWidths($0).outer > 0 })
        let split = outer && !maps.outline && !maps.bevelPaint.contains(.outer) && spec.textGamma == 1
        let pre = work
        if outer {
            var acc = [SIMD4<Float>](repeating: .zero, count: n)
            var cover = [Float](repeating: 0, count: n)
            for st in strokes {
                let outW = EffectMath.strokeWidths(st).outer
                if outW <= 0 { continue }
                let d = vdout ?? dout
                var share = [Float](repeating: 0, count: n)
                for k in 0..<n {
                    let band = min(max(outW + 0.5 - d[k], 0), 1)
                    let kk: Float
                    if maps.outline {
                        kk = band * outlineShare(shape[k], lay.px[k].w)
                    } else if inside(shape[k]) {
                        if spec.vectorShape {
                            kk = 0
                        } else if split {
                            kk = 1
                        } else {
                            let c = min(max(lay.px[k].w, 0), 1)
                            let outside = 1 - min(max(shape[k], 0), 1)
                            kk = c >= 1 ? (outside > 0 ? 1 : 0) : min(max(outside / (1 - c), 0), 1)
                        }
                    } else {
                        kk = band
                    }
                    share[k] = kk * st.common.opacity * (1 - cover[k])
                    cover[k] += share[k]
                }
                var blended = pre
                let ones = share.map { $0 > 0 ? Float(1) : 0 }
                paintFx(&blended, ones, st.paint, frame(st), anchor, st.common.blend, 1, patterns, space)
                for k in 0..<n where share[k] > 0 {
                    let b = blended.px[k]
                    acc[k] += share[k] * SIMD4(b.x * b.w, b.y * b.w, b.z * b.w, b.w)
                }
            }
            for k in 0..<n {
                let c = cover[k]
                if c <= 0 { continue }
                let p = work.px[k], a = acc[k]
                let kk = 1 - min(c, 1)
                let alpha = p.w * kk + a.w
                if alpha > 0 {
                    work.px[k] = SIMD4((p.x * p.w * kk + a.x) / alpha, (p.y * p.w * kk + a.y) / alpha, (p.z * p.w * kk + a.z) / alpha, min(alpha, 1))
                }
            }
        }
        for (i, e) in rev {
            if case .bevelEmboss(let b) = e, maps.bevelPaint[i] == .outer {
                paintColor(&work, fx(i, 0), b.highlightColor.rgb, b.highlight.blend, b.highlight.opacity, space)
                paintColor(&work, fx(i, 1), b.shadowColor.rgb, b.shadow.blend, b.shadow.opacity, space)
            }
        }
        let mode: BlendMode = spec.blend == .passThrough ? .normal : spec.blend
        if split {
            for k in 0..<n {
                let a = min(max(shape[k], 0), 1)
                guard a > 0 else { continue }
                var l = lay.px[k]
                l.w = min(l.w / a, 1)
                let blended = l.w > 0 ? PSBlend.compositeGamma(mode, pre.px[k], l, 1, spec.textGamma, space) : pre.px[k]
                work.px[k] = PSBlend.mixPremul(work.px[k], blended, a)
            }
        } else {
            for k in 0..<n where lay.px[k].w > 0 {
                work.px[k] = PSBlend.compositeGamma(mode, work.px[k], lay.px[k], 1, spec.textGamma, space)
            }
        }
        for (i, e) in rev {
            if case .bevelEmboss(let b) = e, maps.bevelPaint[i] == .both {
                paintColor(&work, fx(i, 0), b.highlightColor.rgb, b.highlight.blend, b.highlight.opacity, space)
                paintColor(&work, fx(i, 1), b.shadowColor.rgb, b.shadow.blend, b.shadow.opacity, space)
            }
        }
        let op = spec.opacity
        for k in 0..<n { backdrop.px[k] = PSBlend.mixPremul(before.px[k], work.px[k], op) }
    }
}
