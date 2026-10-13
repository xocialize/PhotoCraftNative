// Port of photocraft-paint (crates/paint/src/retouch.rs) and the clone/heal/history sampling sequence of photocraft-engine (crates/engine/src/retouch_cmds.rs, presets/clone_source.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The accumulate-then-composite retouch tools: Clone Stamp, Healing Brush and History Brush. A
// stroke's coverage is accumulated once (`Retouch.strokeCoverage`), the *paint image* is sampled
// once from the pre-stroke state (so pixels painted earlier in the stroke are never re-cloned),
// and composited through the coverage (`Retouch.applyCoverage`). `CloneMapping` is photocraft's
// source mapping (translation, or scale/rotation/flip resampled bilinearly in premultiplied
// space); `CloneSource` keeps the aligned anchor between strokes (Compositor v1.5's Clone Stamp,
// MIT © 2026 Wonder Assembly LLC, was reviewed for the aligned/non-aligned behaviour; photocraft's
// maths is what is ported). The Healing Brush's Poisson solve lives in PCAlgo, so it is injected.

import Foundation
import PCFoundation

/// How a clone stroke samples: destination `d` reads the source at `source + m · (d − anchor)`
/// (`m` row-major 2 × 2).
public struct CloneMapping: Hashable, Sendable {
    public var source: SIMD2<Double>
    public var anchor: SIMD2<Double>
    public var m: SIMD4<Double>

    public init(source: SIMD2<Double>, anchor: SIMD2<Double>, m: SIMD4<Double> = SIMD4(1, 0, 0, 1)) {
        self.source = source; self.anchor = anchor; self.m = m
    }

    /// A plain translation by `offset` (destination + offset = source).
    public static func offset(_ dx: Double, _ dy: Double) -> CloneMapping {
        CloneMapping(source: SIMD2(dx, dy), anchor: .zero)
    }

    public var isTranslation: Bool {
        abs(m.x - 1) < 1e-12 && abs(m.y) < 1e-12 && abs(m.z) < 1e-12 && abs(m.w - 1) < 1e-12
    }

    /// Integer translation (identity transform).
    public var offset: (Int32, Int32) {
        (asI32((source.x - anchor.x).rounded()), asI32((source.y - anchor.y).rounded()))
    }

    public func map(_ x: Double, _ y: Double) -> SIMD2<Double> {
        let dx = x - anchor.x, dy = y - anchor.y
        return SIMD2(source.x + m.x * dx + m.y * dy, source.y + m.z * dx + m.w * dy)
    }

    /// Source pixels needed to resample `dst` (with a two-pixel apron for bilinear).
    public func sourceRect(_ dst: PixelRect) -> PixelRect {
        let pts = [(dst.x0, dst.y0), (dst.x1, dst.y0), (dst.x0, dst.y1), (dst.x1, dst.y1)].map { map(Double($0.0), Double($0.1)) }
        var x0 = Double.greatestFiniteMagnitude, y0 = Double.greatestFiniteMagnitude
        var x1 = -Double.greatestFiniteMagnitude, y1 = -Double.greatestFiniteMagnitude
        for p in pts { x0 = minR(x0, p.x); y0 = minR(y0, p.y); x1 = maxR(x1, p.x); y1 = maxR(y1, p.y) }
        // Input-derived coordinates can be arbitrarily large: clamp before casting, then apply the
        // apron with saturating arithmetic.
        func apron(_ v: Double, _ pad: Int32) -> Int32 { asI32(clampR(v, Double(Int32.min), Double(Int32.max))).satAdd(pad) }
        return PixelRect(apron(x0.rounded(.down), -2), apron(y0.rounded(.down), -2), apron(x1.rounded(.up), 2), apron(y1.rounded(.up), 2))
    }

    /// Matrix taking destination offsets to source offsets for a source's W/H (percent),
    /// rotation (degrees, counter-clockwise on screen) and flips.
    public static func transformMatrix(scale: SIMD2<Double>, rotation: Double, flipH: Bool, flipV: Bool) -> SIMD4<Double> {
        let sx = max(scale.x / 100, 1e-3) * (flipH ? -1 : 1)
        let sy = max(scale.y / 100, 1e-3) * (flipV ? -1 : 1)
        let a = -toRadians(rotation)
        let s = sin(a), c = cos(a)
        let f = SIMD4(c * sx, -s * sy, s * sx, c * sy)
        let det = f.x * f.w - f.y * f.z
        return SIMD4(f.w / det, -f.y / det, -f.z / det, f.x / det)
    }
}

/// The Clone Source state a tool keeps between strokes (photocraft's clone-source slot):
/// aligned strokes keep sampling relative to the first stroke's pairing; non-aligned strokes
/// restart at the source point.
public struct CloneSource: Hashable, Sendable {
    public var source: SIMD2<Double>
    public var anchor: SIMD2<Double>?
    public var aligned: Bool
    public var scale: SIMD2<Double> = SIMD2(100, 100)
    public var rotation: Double = 0
    public var flipH = false
    public var flipV = false

    public init(source: SIMD2<Double>, aligned: Bool = true) {
        self.source = source
        self.aligned = aligned
    }

    /// The mapping for a stroke starting at `first`; aligned strokes remember the anchor.
    public mutating func mapping(firstPoint first: SIMD2<Double>) -> CloneMapping {
        let m = CloneMapping.transformMatrix(scale: scale, rotation: rotation, flipH: flipH, flipV: flipV)
        let a = (aligned ? anchor : nil) ?? first
        if aligned { anchor = a }
        return CloneMapping(source: source, anchor: a, m: m)
    }

    /// Where the source sits for a brush at `p` (for the canvas crosshair).
    public func samplePoint(for p: SIMD2<Double>) -> SIMD2<Double> {
        guard let a = anchor, aligned else { return source }
        return source + (p - a)
    }
}

extension Retouch {
    /// Bilinear resample of `src` onto `dst` through `map`, premultiplied when `alpha` is set.
    public static func resample(_ src: Region, dst: PixelRect, map: CloneMapping, alpha: Int?) -> Region {
        let n = src.ch
        var out = Region(rect: dst, ch: n)
        let w = dst.width
        var q = [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
        func fetch(_ x: Int32, _ y: Int32, _ k: Int) {
            if x < src.rect.x0 || y < src.rect.y0 || x >= src.rect.x1 || y >= src.rect.y1 {
                for c in 0..<n { q[k][c] = 0 }
                return
            }
            let b = src.index(x, y) * n
            for c in 0..<n { q[k][c] = src.data[b + c] }
            if let a = alpha {
                let av = q[k][a]
                for c in 0..<n where c != a { q[k][c] *= av }
            }
        }
        for i in 0..<dst.area {
            let x = dst.x0 + Int32(i % w), y = dst.y0 + Int32(i / w)
            let s = map.map(Double(x) + 0.5, Double(y) + 0.5)
            let fx = s.x - 0.5, fy = s.y - 0.5
            let x0 = asI32(fx.rounded(.down)), y0 = asI32(fy.rounded(.down))
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            fetch(x0, y0, 0); fetch(x0 &+ 1, y0, 1); fetch(x0, y0 &+ 1, 2); fetch(x0 &+ 1, y0 &+ 1, 3)
            for c in 0..<n {
                let top = q[0][c] + (q[1][c] - q[0][c]) * tx
                let bot = q[2][c] + (q[3][c] - q[2][c]) * tx
                out.data[i * n + c] = top + (bot - top) * ty
            }
            if let a = alpha {
                let av = out.data[i * n + a]
                for c in 0..<n where c != a { out.data[i * n + c] = av > 1e-6 ? out.data[i * n + c] / av : 0 }
            }
        }
        return out
    }

    /// Source pixels for destination `rect`: a translated read, or a bilinear resample when the
    /// mapping scales, rotates or flips. Nil when the sample window leaves the coordinate range.
    public static func cloneSample(_ source: Surface, rect: PixelRect, map: CloneMapping) -> Region? {
        if map.isTranslation {
            let (dx, dy) = map.offset
            let src = rect.translated(dx, dy)
            // `translated` saturates at the Int32 edges: a far source gives a smaller window.
            if src.width != rect.width || src.height != rect.height { return nil }
            var r = Region.read(source, src)
            r.rect = rect
            return r
        }
        let src = Region.read(source, map.sourceRect(rect))
        return resample(src, dst: rect, map: map, alpha: alphaIndex(source.format))
    }

    /// Clamp healed samples to the format's range (alpha and integer formats to 0…1, float colour ≥ 0).
    public static func clampSamples(_ fmt: PixelFormat, _ data: inout [Float]) {
        let n = fmt.channels
        let a = alphaIndex(fmt)
        let float = fmt.sample == .f32
        for i in data.indices {
            let c = i % n
            data[i] = (c == a || !float) ? clampR(data[i], 0, 1) : maxR(data[i], 0)
        }
    }

    /// Grow a stroke's coverage map by `m` pixels of zero coverage (a Dirichlet boundary for the solve).
    public static func padCoverage(_ bounds: PixelRect, _ cov: [Float], _ m: Int32) -> (PixelRect, [Float]) {
        let g = bounds.inflated(m)
        let w = bounds.width, gw = g.width
        var out = [Float](repeating: 0, count: gw * g.height)
        for (i, c) in cov.enumerated() { out[(i / w + Int(m)) * gw + i % w + Int(m)] = c }
        return (g, out)
    }

    /// A seamless-clone solver: `(width, height, channels, source, destination, mask) → pixels`,
    /// photocraft-algo's `poisson::seamless_clone` (PCAlgo provides it).
    public typealias SeamlessClone = (Int, Int, Int, [Float], [Float], [Bool]) -> [Float]

    /// Seamless-clone `src` into `dst` over the mask (both regions cover the same rect). The solve
    /// runs only on the mask's bounding box plus a one-pixel Dirichlet ring; the rest is `dst`.
    public static func healRegion(_ fmt: PixelFormat, src: Region, dst: Region, mask: [Bool], solver: SeamlessClone) -> Region {
        let w = dst.width
        var bbox = PixelRect.empty
        for (i, m) in mask.enumerated() where m {
            let x = dst.rect.x0 + Int32(i % w), y = dst.rect.y0 + Int32(i / w)
            bbox = bbox.union(PixelRect(x, y, x + 1, y + 1))
        }
        var out = dst
        if bbox.isEmpty { return out }
        let r = bbox.inflated(1).intersect(dst.rect)
        let s = src.crop(r), d = dst.crop(r)
        var m: [Bool] = []
        m.reserveCapacity(r.area)
        for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { m.append(mask[dst.index(x, y)]) } }
        var data = solver(d.width, d.height, d.ch, s.data, d.data, m)
        clampSamples(fmt, &data)
        let n = dst.ch, rw = r.width
        for y in r.y0..<r.y1 {
            let o = out.index(r.x0, y) * n, i = Int(y - r.y0) * rw * n
            for k in 0..<(rw * n) { out.data[o + k] = data[i + k] }
        }
        return out
    }

    /// Clone Stamp: the stroke's coverage composited with pixels sampled from `source` (the
    /// pre-stroke layer, or a flattened composite for Sample All Layers) through `map`.
    @discardableResult
    public static func cloneStamp(_ target: inout Surface, _ stroke: Stroke, source: Surface, map: CloneMapping, mode: BlendMode = .normal,
                                  selection: Surface? = nil, lockTransparency: Bool = false) -> PixelRect {
        let (bounds, cov) = strokeCoverage(stroke)
        guard !bounds.isEmpty, let paint = cloneSample(source, rect: bounds, map: map) else { return .empty }
        return applyCoverage(&target, rect: bounds, cov: cov, opacity: stroke.brush.opacity, selection: selection,
                             lockTransparency: lockTransparency, paint: paint, blend: mode)
    }

    /// Healing Brush: clone, then seamless-clone the sample into the destination over the stroke
    /// (coverage padded by 2 px of Dirichlet boundary), composited through the coverage.
    /// `destination` is what the texture is fitted to (the layer, or the composite when sampling
    /// several layers); nil uses `target`.
    @discardableResult
    public static func healingBrush(_ target: inout Surface, _ stroke: Stroke, source: Surface, destination: Surface? = nil, map: CloneMapping,
                                    mode: BlendMode = .normal, selection: Surface? = nil, lockTransparency: Bool = false,
                                    solver: SeamlessClone) -> PixelRect {
        let (bounds, cov0) = strokeCoverage(stroke)
        if bounds.isEmpty { return .empty }
        let (g, cov) = padCoverage(bounds, cov0, 2)
        guard let src = cloneSample(source, rect: g, map: map) else { return .empty }
        let dst = Region.read(destination ?? target, g)
        let healed = healRegion(target.format, src: src, dst: dst, mask: cov.map { $0 > 0 }, solver: solver)
        return applyCoverage(&target, rect: g, cov: cov, opacity: stroke.brush.opacity, selection: selection,
                             lockTransparency: lockTransparency, paint: healed, blend: mode)
    }

    /// History Brush: paint pixels from an earlier state of the layer.
    @discardableResult
    public static func historyBrush(_ target: inout Surface, _ stroke: Stroke, history: Surface, mode: BlendMode = .normal,
                                    selection: Surface? = nil, lockTransparency: Bool = false) -> PixelRect {
        let (bounds, cov) = strokeCoverage(stroke)
        if bounds.isEmpty { return .empty }
        return applyCoverage(&target, rect: bounds, cov: cov, opacity: stroke.brush.opacity, selection: selection,
                             lockTransparency: lockTransparency, paint: Region.read(history, bounds), blend: mode)
    }
}

/// A retouching stroke shown while it is drawn (photocraft-engine `LiveRetouch`): the dabs so far
/// composited onto the layer exactly as the one-shot command commits them (same coverage,
/// sampling and blend), plus what finishing the stroke now would add. Each changed area is redrawn
/// from the pre-stroke pixels, so overlapping dabs build up as in the commit and pixels painted
/// earlier in the stroke are never re-cloned.
public struct LiveRetouch {
    public enum Paint {
        case clone(source: Surface, map: CloneMapping)
        case history(Surface)
    }

    public private(set) var surface: Surface
    let pre: Surface
    var renderer: StrokeRenderer
    let paint: Paint
    let opacity: Float
    let mode: BlendMode
    let selection: Surface?
    let lockTransparency: Bool
    var tail = PixelRect.empty

    public init(brush: BrushSettings, layer: Surface, paint: Paint, mode: BlendMode = .normal, selection: Surface? = nil,
                lockTransparency: Bool = false, zoom: Float = 1) {
        surface = layer
        pre = layer
        renderer = StrokeRenderer(brush, format: nil, zoom: zoom)
        self.paint = paint
        opacity = brush.opacity
        self.mode = mode
        self.selection = selection
        self.lockTransparency = lockTransparency
    }

    public var bounds: PixelRect { renderer.bounds.union(tail) }

    /// Render more points; returns the rectangle that changed.
    public mutating func push(_ pts: [StrokePoint]) -> PixelRect {
        renderer.push(pts)
        let old = tail
        tail = .empty
        var dmg = PixelRect.empty
        if !old.isEmpty {
            // Back to the stroke without the previous tail.
            var region: [Float] = []
            pre.readRegionReusing(old, &region)
            surface.writeRegionSafe(old, &region)
            renderer.markDirty(old)
            dmg = old
        }
        let r = renderer.takeDirtyRect()
        dmg = dmg.union(composite(r, renderer.coverageIn(r)))
        if var t = renderer.tailPreview() {
            let tr = t.takeDirtyRect()
            tail = composite(tr, t.coverageIn(tr))
            dmg = dmg.union(tail)
        }
        return dmg
    }

    /// Redraw `r` from the pre-stroke pixels with the paint image through coverage `cov`.
    mutating func composite(_ r: PixelRect, _ cov: [Float]) -> PixelRect {
        if r.isEmpty { return r }
        let img: Region
        switch paint {
        case .clone(let source, let map):
            guard let s = Retouch.cloneSample(source, rect: r, map: map) else { return .empty }
            img = s
        case .history(let h): img = Region.read(h, r)
        }
        var region: [Float] = []
        pre.readRegionReusing(r, &region)
        surface.writeRegionSafe(r, &region)
        return Retouch.applyCoverage(&surface, rect: r, cov: cov, opacity: opacity, selection: selection, lockTransparency: lockTransparency,
                                     paint: img, blend: mode).union(r)
    }
}
