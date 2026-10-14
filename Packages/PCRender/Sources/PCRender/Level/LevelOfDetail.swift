// New (no photocraft counterpart; photocraft's `proxy.rs` proxy documents are the idea, at the plan
// instead of the document, area-averaged instead of nearest-neighbour, and with layer effects and
// vector masks scaled rather than refused): compositing at a level of detail (AB-T-0256).
//
// A composite at level L is the plan run over level pixels, one per 2^L × 2^L block of document
// pixels, from reduced sources:
//
// * `RenderPlan.atLevel(L)` rescales what the plan says in document pixels: the canvas, effect
//   sizes, distances, regions, bounds and reference points, mask feathers, fill frames, pattern scale
//   and phase, artboard rects, filter adjustments (`FilterSpec.atLevel`: blur lengths shrink, grain
//   and noise stay fixed in the document). Everything else (blend modes, opacities, adjustments, Blend If, stack
//   order) is per pixel and stays, but for type layers' text gamma, which is turned off: it bends
//   partial coverage, and a level pixel's coverage is the mean of whole-pixel coverages, whose
//   reduction mixes linearly (black type at half a level pixel is 0.5, not the 0.64 gamma makes).
// * `LevelSource` serves the plan's leaves at the level: surfaces as `.reduced` leaves (tile blocks,
//   TileReduction.swift, cached by tile generation), derived leaves built at the level where the
//   planner registered a level recipe (vector-mask coverage of the scaled path, effect shapes from
//   the scaled nested program), else the full-resolution leaf reduced.
//
// Both compositors then run the level plan unchanged, kernels included, so the CPU reference of a
// level render exists and the GPU's parity to it is the usual GPU-vs-CPU parity. A level composite
// is not `renderReduced` (the exact reduction of the full-resolution composite): blending averaged
// sources is not averaging blended pixels. PORT-NOTES.md states by how much.

import Foundation
import PCDocument
import PCFoundation

public enum LevelOfDetail {
    /// The deepest level reduced sources reach (one level pixel per source tile).
    public static let maxLevel = 8

    @inline(__always) static func clamp(_ level: Int) -> Int { min(max(level, 0), maxLevel) }

    /// The level pixels covering the document pixels `r` (rounded outward to whole blocks).
    public static func region(_ r: PixelRect, level: Int) -> PixelRect {
        if level <= 0 || r.isEmpty { return r }
        let s = Int64(1) << Int64(level)
        func down(_ v: Int32) -> Int32 { Int32(clamping: Int64(v) >= 0 ? Int64(v) / s : -((-Int64(v) + s - 1) / s)) }
        func up(_ v: Int32) -> Int32 { -down(-v) }
        return PixelRect(x0: down(r.x0), y0: down(r.y0), x1: up(r.x1), y1: up(r.y1))
    }

    /// The document pixels level pixels `r` cover.
    public static func documentRect(_ r: PixelRect, level: Int) -> PixelRect {
        if level <= 0 || r.isEmpty { return r }
        let s = Int64(1) << Int64(level)
        return PixelRect(x0: Int32(clamping: Int64(r.x0) * s), y0: Int32(clamping: Int64(r.y0) * s),
                         x1: Int32(clamping: Int64(r.x1) * s), y1: Int32(clamping: Int64(r.y1) * s))
    }

    /// A layout rect (fill frames, effect bounds, artboards) at the level: edges to the nearest level
    /// pixel edge, so a frame keeps its centre and size within half a level pixel.
    static func layout(_ r: PixelRect, level: Int) -> PixelRect {
        if level <= 0 || r.isEmpty { return r }
        let s = Double(1 << level)
        func q(_ v: Int32) -> Int32 { Int32(clamping: Int64((Double(v) / s).rounded())) }
        return PixelRect(x0: q(r.x0), y0: q(r.y0), x1: q(r.x1), y1: q(r.y1))
    }

    /// Reduces one tile (`src`: tileSize² pixels of `format`) at `level` (1 … `maxLevel`) into
    /// `dst`: (256 >> level) rows of `rowBytes`, pixels of `format` (TileReduction.swift).
    public static func reduceTile(_ src: UnsafeRawPointer, format: PixelFormat, level: Int, into dst: UnsafeMutableRawPointer, rowBytes: Int) {
        TileReduction.reduce(src, format: format, level: min(max(level, 1), maxLevel), into: dst, rowBytes: rowBytes)
    }

    /// A leaf version at a level (distinct per level, the same for every render at it).
    static func version(_ v: UInt64, _ level: Int, sampled: Bool = false) -> UInt64 {
        if level <= 0 { return v }
        var h = Fingerprint()
        h.mix(v)
        h.mix(0x4c4f_4400 | UInt64(level) | (sampled ? 0x80 : 0))
        return h.value
    }

    /// Any leaf at `level`: surfaces as `.reduced` leaves (`sampled`: previews), images reduced
    /// (`TileReduction.image`; previews too, derived images being small).
    static func reduce(_ leaf: RenderLeaf, level: Int, sampled: Bool = false) -> RenderLeaf {
        if level <= 0 { return leaf }
        switch leaf {
        case .surface(let s): return .reduced(s, level: clamp(level), sampled: sampled)
        case let .reduced(s, l, was): return .reduced(s, level: clamp(l + level), sampled: was || sampled)
        case let .image(img, outside, v):
            return .image(TileReduction.image(img, outside: outside, level: level), outside: outside, version: version(v, level, sampled: sampled))
        }
    }
}

// MARK: - Plans at a level

extension RenderPlan {
    /// This plan over level pixels (see the file header): `region` and leaves at the level come from
    /// `LevelOfDetail.region` and `LevelSource`.
    public func atLevel(_ level: Int) -> RenderPlan {
        if level <= 0 { return self }
        var ctx = context
        ctx.canvas = LevelOfDetail.region(context.canvas, level: level)
        return RenderPlan(context: ctx, ops: ops.map { $0.atLevel(level) })
    }
}

extension DrawOp {
    func atLevel(_ l: Int) -> DrawOp {
        switch self {
        case .drawTiles(var d):
            d.mask = d.mask?.atLevel(l)
            return .drawTiles(d)
        case .fill(let f): return .fill(f.atLevel(l))
        case .pushMaskShape(let m): return .pushMaskShape(m?.atLevel(l))
        case .mask(let m): return .mask(m.atLevel(l))
        case .popGroup(.isolated(let m)): return .popGroup(.isolated(mask: m?.atLevel(l)))
        case let .popGroup(.passThrough(o, m)): return .popGroup(.passThrough(opacity: o, mask: m?.atLevel(l)))
        case .adjustMix(var a):
            a.mask = a.mask?.atLevel(l)
            return .adjustMix(a)
        case let .effect(spec, atop): return .effect(spec.atLevel(l), atop: atop)
        case .filter(let f): return .filter(f.atLevel(l))
        case .backdropFilter(var b):
            b.spec = b.spec.atLevel(l)
            b.program = b.program.map { $0.atLevel(l) }
            return .backdropFilter(b)
        case .restrictTo(let r): return .restrictTo(LevelOfDetail.layout(r, level: l))
        case .composite(var b): b.textGamma = 1; return .composite(b)
        case .clipped(var b): b.textGamma = 1; return .clipped(b)
        default: return self
        }
    }
}

extension MaskSpec {
    /// Feathers in level pixels.
    func atLevel(_ l: Int) -> MaskSpec {
        var m = self
        let s = 1 / Float(1 << l)
        m.feather *= s
        m.vectorFeather *= s
        return m
    }
}

extension FillOp {
    func atLevel(_ l: Int) -> FillOp {
        var f = self
        f.frame = LevelOfDetail.layout(frame, level: l)
        f.mask = mask?.atLevel(l)
        if case .pattern(var p) = fill {
            let s = 1 / Float(1 << l)
            p.scale *= s
            p.phase *= s
            f.fill = .pattern(p)
        }
        return f
    }
}

extension EffectsSpec {
    func atLevel(_ l: Int) -> EffectsSpec {
        var e = self
        e.effects = effects.scaled(by: 1 / Float(1 << l))
        // The level effect shape covers exactly this region (DocumentRenderSource's level recipes).
        e.region = LevelOfDetail.region(region, level: l)
        e.bounds = LevelOfDetail.layout(bounds, level: l)
        e.clip = clip.map { LevelOfDetail.region($0, level: l) }
        e.vectorStrokeMask = vectorStrokeMask?.atLevel(l)
        e.textGamma = 1
        return e
    }
}

extension FxPaint {
    func scaled(by s: Float) -> FxPaint {
        guard case .pattern(var p) = self else { return self }
        p.scale *= s
        return .pattern(p)
    }
}

extension Effects {
    /// The effects with every length in pixels multiplied by `s` (sizes, distances, softening,
    /// pattern scales and phases, the reference point). Percentages, angles and contours stay. Noise
    /// amplitudes scale too: a level pixel averages 1/s² independent samples, whose spread is s times
    /// one sample's.
    func scaled(by s: Float) -> Effects {
        var e = self
        e.reference = reference.map { $0 * Double(s) }
        e.items = items.map { item in
            switch item {
            case .dropShadow(var x): x.distance *= s; x.size *= s; x.noise *= s; return .dropShadow(x)
            case .innerShadow(var x): x.distance *= s; x.size *= s; x.noise *= s; return .innerShadow(x)
            case .outerGlow(var g): g.size *= s; g.noise *= s; g.paint = g.paint.scaled(by: s); return .outerGlow(g)
            case .innerGlow(var g): g.size *= s; g.noise *= s; g.paint = g.paint.scaled(by: s); return .innerGlow(g)
            case .stroke(var st): st.size *= s; st.paint = st.paint.scaled(by: s); return .stroke(st)
            case .satin(var x): x.distance *= s; x.size *= s; return .satin(x)
            case .bevelEmboss(var b):
                b.size *= s; b.soften *= s
                if var t = b.texture { t.scale *= s; t.phase *= s; b.texture = t }
                return .bevelEmboss(b)
            case .patternOverlay(var p): p.scale *= s; p.phase *= s; return .patternOverlay(p)
            case .colorOverlay, .gradientOverlay: return item
            }
        }
        return e
    }
}

extension VectorPath {
    /// The path in level pixels.
    func atLevel(_ l: Int) -> VectorPath { l <= 0 ? self : transform(.scale(1 / Double(1 << l))) }
}

// MARK: - Sources at a level

/// Leaves at a level of detail for a level plan (see the file header). A `DocumentRenderSource`
/// builds derived leaves at the level and caches them; any other source has its surfaces reduced
/// and its images reduced on each request.
public struct LevelSource: RenderSource {
    public let base: any RenderSource
    public let level: Int
    /// Surfaces sampled (one pixel per block) instead of averaged: a quick preview.
    public let sampled: Bool

    public init(_ base: any RenderSource, level: Int, sampled: Bool = false) {
        self.base = base
        self.level = LevelOfDetail.clamp(level)
        self.sampled = sampled
    }

    public func leaf(_ id: LeafID) -> RenderLeaf? {
        if let d = base as? DocumentRenderSource { return d.leaf(id, level: level, sampled: sampled) }
        return base.leaf(id).map { LevelOfDetail.reduce($0, level: level, sampled: sampled) }
    }

    public func leafVersion(_ id: LeafID) -> UInt64? {
        base.leafVersion(id).map { LevelOfDetail.version($0, level, sampled: sampled) }
    }

    public func pattern(id: String, name: String) -> PatternTile? { base.pattern(id: id, name: name) }
}
