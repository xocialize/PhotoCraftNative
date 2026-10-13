// Port of photocraft-compose (crates/compose/src/effects.rs) and photocraft-gpu (fx.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Effect maps derived from a layer's shape (its alpha): shadow / glow / satin / bevel coverage and
// the stroke distance fields, built once over the layer's effect region and cropped per tile. They
// depend only on the shape, the effect settings and the global light — never on the backdrop — so
// both compositors cache them per layer state. Soft falloffs are two box blurs (a tent).

import Foundation
import PCDocument
import PCFoundation

/// π rounded to nearest (Swift's `Float.pi` rounds toward zero; Rust's and MSL's are nearest).
let piF: Float = 3.14159265358979323846

@inline(__always) func radians(_ deg: Float) -> Float { deg * (piF / 180) }

public enum EffectMath {
    /// Maximum distance (px) an effect is rendered from the layer's shape.
    public static let maxReach: Float = 512

    /// Height below which an outer bevel pixel counts as off the bevel.
    public static let bevelHeightEps: Float = 1e-5

    /// Pixels an effect stack can reach beyond the layer's shape.
    public static func margin(_ fx: Effects) -> Int32 {
        var m: Float = 0
        for e in fx.items where e.isEnabled {
            let r: Float
            switch e {
            case .dropShadow(let s), .innerShadow(let s): r = s.distance + s.size
            case .outerGlow(let g), .innerGlow(let g): r = g.size
            case .stroke(let s): r = s.size
            case .satin(let s): r = satinDistance(s) + s.size
            case .bevelEmboss(let b): r = b.size + b.soften
            default: r = 0
            }
            if r.isFinite { m = max(m, r) }
        }
        return Int32(min(max(m, 0), maxReach).rounded(.up)) + 2
    }

    /// Whether every enabled effect's maps are local (`maps_are_local`).
    public static func mapsAreLocal(_ fx: Effects) -> Bool {
        fx.items.filter(\.isEnabled).allSatisfy { e in
            switch e {
            case .stroke(let s): if case .gradient = s.paint { return false } else { return true }
            case .dropShadow(let s), .innerShadow(let s): return s.noise <= 0
            case .outerGlow(let g), .innerGlow(let g): return g.technique != .precise && g.noise <= 0
            case .bevelEmboss(let b): return b.technique == .smooth
            default: return true
            }
        }
    }

    /// Satin Distance 0 draws as 1 px.
    public static func satinDistance(_ s: Satin) -> Float { max(s.distance, 1) }

    /// (inside width, outside width) of a stroke.
    public static func strokeWidths(_ st: StrokeFx) -> (inner: Float, outer: Float) {
        switch st.position {
        case .outside: (0, st.size)
        case .inside: (st.size, 0)
        case .center: (st.size / 2, st.size / 2)
        }
    }

    /// Offset of an effect lit from `angle` at `distance`, whole pixels.
    public static func offset(_ angle: Float, _ distance: Float) -> (Float, Float) {
        let a = radians(angle)
        return ((-cosf(a) * distance).rounded(), (sinf(a) * distance).rounded())
    }

    /// Spread / choke of a soft effect: (dilation radius, blur width). The blur takes what the
    /// whole-pixel dilation leaves of the size (ps-corpus fx-drop-shadow, fx-outer-glow: 0 % of
    /// pixels off; photocraft's `size · (1 − spread)` blurs 0.2–0.4 px wider, 2.6 % and 11.7 % off).
    public static func spreadSplit(_ size: Float, _ spread: Float) -> (Float, Float) {
        let r = (size * spread).rounded()
        return (r, max(size - r, 0))
    }

    /// The opacity gain of a gradient glow (opaque from strength `range²`).
    public static func glowGradientGain(_ range: Float) -> Float {
        let r = range.isFinite ? min(max(range, 0.01), 1) : 1
        return 1 / (r * r)
    }

    // MARK: Box / tent

    static func boxWidth(_ w: Float) -> Float { w.isNaN ? 1 : min(max(w, 1), maxReach) }

    static func boxWeights(_ w0: Float) -> [Float] {
        let w = boxWidth(w0)
        let half = w / 2
        let r = Int(max((half - 0.5).rounded(.up), 0))
        let v: [Float] = (-r...r).map { i in max(min(Float(i) + 0.5, half) - max(Float(i) - 0.5, -half), 0) }
        let sum = v.reduce(0, +)
        return v.map { $0 / sum }
    }

    /// The 1D kernel of two box passes of width `w`: (radius, weights).
    public static func tentKernel(_ w: Float) -> (Int, [Float]) {
        let b = boxWeights(w)
        let n = b.count * 2 - 1
        var t = [Float](repeating: 0, count: n)
        for (i, x) in b.enumerated() { for (j, y) in b.enumerated() { t[i + j] += x * y } }
        return ((n - 1) / 2, t)
    }

    /// (r, end-tap weight f, 1 / width) of a box of fractional width.
    static func boxGeom(_ bw0: Float) -> (Int, Double, Double) {
        let bw = boxWidth(bw0)
        let half = bw / 2
        let r = Int(max((half - 0.5).rounded(.up), 0))
        let f = Double(min(max(half - (Float(r) - 0.5), 0), 1))
        return (r, f, 1 / Double(bw))
    }

    static func boxLine(_ src: UnsafeBufferPointer<Double>, _ x0: Int, _ dst: UnsafeMutableBufferPointer<Double>, _ bw: Float) {
        let n = src.count
        let (r, f, norm) = boxGeom(bw)
        @inline(__always) func at(_ i: Int) -> Double { (i >= 0 && i < n) ? src[i] : 0 }
        if r == 0 {
            for k in 0..<dst.count { dst[k] = at(x0 + k) }
            return
        }
        var inner: Double = 0
        for i in (x0 - (r - 1))...(x0 + (r - 1)) { inner += at(i) }
        for k in 0..<dst.count {
            let x = x0 + k
            dst[k] = (inner + f * (at(x - r) + at(x + r))) * norm
            inner += at(x + r) - at(x - r + 1)
        }
    }

    /// Two box passes along a line (the tent convolution, zero outside).
    static func tentLine(_ src: UnsafeBufferPointer<Float>, _ dst: UnsafeMutableBufferPointer<Float>, _ bw: Float,
                         _ s: UnsafeMutableBufferPointer<Double>, _ mid: UnsafeMutableBufferPointer<Double>, _ out: UnsafeMutableBufferPointer<Double>) {
        let (r, _, _) = boxGeom(bw)
        let n = src.count
        for i in 0..<n { s[i] = Double(src[i]) }
        let sv = UnsafeBufferPointer(rebasing: s[0..<n])
        let mv = UnsafeMutableBufferPointer(rebasing: mid[0..<(n + 2 * r)])
        boxLine(sv, -r, mv, bw)
        let ov = UnsafeMutableBufferPointer(rebasing: out[0..<n])
        boxLine(UnsafeBufferPointer(mv), r, ov, bw)
        for i in 0..<n { dst[i] = Float(ov[i]) }
    }

    static func rowsTent(_ src: [Float], _ w: Int, _ h: Int, _ bw: Float) -> [Float] {
        var dst = [Float](repeating: 0, count: src.count)
        let (r, _, _) = boxGeom(bw)
        src.withUnsafeBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                let (S, D) = (UnsafeSendable(sp), UnsafeSendable(dp))
                parallelChunks(h, work: w * h) { rows in
                    let s = UnsafeMutableBufferPointer<Double>.allocate(capacity: w)
                    let mid = UnsafeMutableBufferPointer<Double>.allocate(capacity: w + 2 * r)
                    let out = UnsafeMutableBufferPointer<Double>.allocate(capacity: w)
                    defer { s.deallocate(); mid.deallocate(); out.deallocate() }
                    for y in rows {
                        let line = UnsafeBufferPointer(rebasing: S.value[(y * w)..<(y * w + w)])
                        let o = UnsafeMutableBufferPointer(rebasing: D.value[(y * w)..<(y * w + w)])
                        tentLine(line, o, bw, s, mid, out)
                    }
                }
            }
        }
        return dst
    }

    static func transpose(_ v: [Float], _ w: Int, _ h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: v.count)
        let b = 32
        v.withUnsafeBufferPointer { vp in
            out.withUnsafeMutableBufferPointer { op in
                for by in stride(from: 0, to: h, by: b) {
                    for bx in stride(from: 0, to: w, by: b) {
                        for y in by..<min(by + b, h) { for x in bx..<min(bx + b, w) { op[x * h + y] = vp[y * w + x] } }
                    }
                }
            }
        }
        return out
    }

    /// Two box passes of width `w` along each axis.
    static func tent(_ m: inout FxMap, _ w: Float) {
        if tentKernel(w).0 == 0 || m.v.isEmpty { return }
        let a = rowsTent(m.v, m.w, m.h, w)
        let t = transpose(a, m.w, m.h)
        let b = rowsTent(t, m.h, m.w, w)
        m.v = transpose(b, m.h, m.w)
    }

    static func blur(_ m: inout FxMap, _ size: Float) {
        if size.isFinite { tent(&m, size) }
    }

    /// Grows the shape by `r` pixels (anti-aliased), keeping its soft edge (chamfer distances).
    static func dilate(_ s: FxMap, _ r: Float) -> FxMap {
        if r <= 0 { return s }
        let d = DistanceFields.distOutside(s, .chamfer)
        var out = s
        for i in out.v.indices {
            out.v[i] = d[i] < 0 ? min(out.v[i] + r, 1) : max(out.v[i], min(max(r + 0.5 - d[i], 0), 1))
        }
        return out
    }

    // MARK: Contours

    public static func contourLUT(_ c: Contour) -> [Float]? {
        switch c {
        case .linear: return nil
        case .custom(let c): return AdjustMath.contourCurveLUT(c.points, corners: c.corners)
        }
    }

    /// Satin's contour, read as for the other effects but applied to each blurred copy before
    /// they are differenced (`satinMap`): a satin pixel is |C(a) − C(b)|.
    public static func satinLUT(_ c: Contour) -> [Float]? { contourLUT(c) }

    /// Interpolated lookup in a 0…1 table (as the GPU's `lut()`).
    @inline(__always) static func lutAt(_ l: [Float], _ v: Float) -> Float {
        let x = (v.isNaN ? 0 : min(max(v, 0), 1)) * Float(l.count - 1)
        let i = Int(x.rounded(.down))
        let j = min(i + 1, l.count - 1)
        return l[i] + (l[j] - l[i]) * (x - Float(i))
    }

    /// A glow's coverage transfer: its contour over the Range.
    public static func glowLUT(_ g: Glow) -> [Float]? { rangedLUT(g.contour, g.range) }

    public static func rangedLUT(_ contour: Contour, _ range0: Float) -> [Float]? {
        let base = contourLUT(contour)
        let range = range0.isFinite ? min(max(range0, 0.01), 1) : 1
        if range >= 0.999 { return base }
        let n = 4096
        return (0..<n).map { k in
            let v = min(Float(k) / Float(n - 1) / range, 1)
            return base.map { lutAt($0, v) } ?? v
        }
    }

    /// The bevel Contour element's height transfer.
    public static func bevelContourLUT(_ c: BevelContour) -> [Float] {
        contourLUT(c.contour) ?? (0..<4096).map { Float($0) / 4095 }
    }

    static func applyLUT(_ m: FxMap, _ l: [Float]?) -> FxMap {
        guard let l else { return m }
        return m.map { lutAt(l, $0) }
    }

    /// Deterministic per-pixel value in 0…1 hashed from document coordinates.
    @inline(__always) public static func hashNoise(_ x: Int64, _ y: Int64) -> Float {
        PSBlend.dissolveNoise(Int32(truncatingIfNeeded: x), Int32(truncatingIfNeeded: y))
    }

    /// Coverage at or below which effect noise leaves a pixel alone. photocraft tests `v <= 0`, which
    /// speckles (at the full noise amplitude) the ~1e-16 residues its f64 running-sum blur leaves in a
    /// blur's tail; those residues differ between any two blur implementations (the GPU's sliding f32
    /// sums leave ~1e-8), which is why photocraft-gpu renders noisy effects on the CPU. A floor far
    /// below one 8-bit step makes noise deterministic across backends (deliberate deviation,
    /// PORT-NOTES).
    public static let noiseFloor: Float = 1e-5

    /// Effect noise: monochrome speckle in the coverage (after the contour).
    static func noise(_ m: inout FxMap, _ amount: Float, _ x0: Int32, _ y0: Int32) {
        if !amount.isFinite || amount <= 0 { return }
        for y in 0..<m.h {
            for x in 0..<m.w {
                let i = y * m.w + x
                if m.v[i] <= noiseFloor { continue }
                let n = hashNoise(Int64(x0) + Int64(x), Int64(y0) + Int64(y))
                m.v[i] = min(max(m.v[i] + (n - 0.5) * 2 * amount, 0), 1)
            }
        }
    }

    // MARK: Maps

    static func shadowMap(_ shape: FxMap, _ s: Shadow, _ light: GlobalLight, inner: Bool, origin: (Int32, Int32)) -> FxMap {
        let angle = s.useGlobalLight ? light.angle : s.angle
        let (dx, dy) = offset(angle, s.distance)
        let src = inner ? shape.map { 1 - $0 } : shape
        var m = src.shifted(dx, dy, outside: inner ? 1 : 0)
        let (r, bw) = spreadSplit(s.size, s.spread)
        m = dilate(m, r)
        blur(&m, bw)
        m = applyLUT(m, contourLUT(s.contour))
        noise(&m, s.noise, origin.0, origin.1)
        if inner { for i in m.v.indices { m.v[i] *= shape.v[i] } }
        return m
    }

    static func glowMap(_ shape: FxMap, _ g: Glow, inner: Bool, origin: (Int32, Int32)) -> FxMap {
        let src = inner ? shape.map { 1 - $0 } : shape
        var m: FxMap
        switch g.technique {
        case .precise:
            let d = inner ? DistanceFields.distInside(shape, .euclidean) : DistanceFields.distOutside(src, .euclidean)
            let solid = g.size * g.spread
            let soft = max(g.size + 1 - solid, 1e-3)
            m = FxMap(w: shape.w, h: shape.h)
            for i in m.v.indices {
                let dd = d[i] + 0.5
                m.v[i] = dd <= solid ? 1 : 0.5 * min(max(1 - (dd - solid) / soft, 0), 1)
            }
        case .softer:
            let (r, bw) = spreadSplit(g.size, g.spread)
            m = dilate(src, r)
            blur(&m, bw)
        }
        m = applyLUT(m, glowLUT(g))
        if inner && g.source == .center { m = m.map { 1 - $0 } }
        noise(&m, g.noise, origin.0, origin.1)
        if inner { for i in m.v.indices { m.v[i] *= shape.v[i] } }
        return m
    }

    /// Satin: each offset copy of the shape blurred (two box passes of the size) and put through
    /// the contour, then |C(A) − C(B)|, inverted after (Photoshop 27.11 M1 raw maps: 14 variants,
    /// every contour, 19° / 90°, distance 11 / 30; see PORT-NOTES phase 4). Contours that are
    /// mirror images (Cone, Cone − Inverted) therefore give the same satin. An anti-aliased
    /// contour is averaged over 3 × 3 samples at +0, ⅓, ⅔ px (`contourSupersampled`). Phase 3's
    /// "difference first, then blur and contour" fitted one corpus file but was 71–120 levels off
    /// on edges parallel to the offset.
    static func satinMap(_ shape: FxMap, _ s: Satin) -> FxMap {
        let (dx, dy) = offset(s.angle, satinDistance(s))
        var a = shape.shifted(dx, dy, outside: 0)
        var b = shape.shifted(-dx, -dy, outside: 0)
        tent(&a, s.size)
        tent(&b, s.size)
        if let l = satinLUT(s.contour) {
            if s.antiAlias {
                a = contourSupersampled(a, l)
                b = contourSupersampled(b, l)
            } else {
                a = a.map { lutAt(l, $0) }
                b = b.map { lutAt(l, $0) }
            }
        }
        var m = FxMap(w: shape.w, h: shape.h, v: zip(a.v, b.v).map { abs($0 - $1) })
        if s.invert { m = m.map { 1 - $0 } }
        for i in m.v.indices { m.v[i] *= shape.v[i] }
        return m
    }

    /// Photoshop's anti-aliased contour (measured through Satin, M1): the mean of the contour over
    /// 3 × 3 bilinear samples of `m` at (x + i/3, y + j/3), i, j ∈ {0, 1, 2}, outside reads 0. The
    /// grid is anchored at the pixel, not centred on it, so the result sits ⅓ px up-left of a
    /// centred evaluation: the plain |C(a) − C(b)| was 2.8–4.9 levels mean off for Cone, this is
    /// 0.2–0.6 (GPU `pcr_m_contour_aa`).
    static func contourSupersampled(_ m: FxMap, _ l: [Float]) -> FxMap {
        var out = FxMap(w: m.w, h: m.h)
        let (w, h) = (m.w, m.h)
        m.v.withUnsafeBufferPointer { src in
            out.v.withUnsafeMutableBufferPointer { dst in
                let (s, d) = (UnsafeSendable(src), UnsafeSendable(dst))
                @inline(__always) func at(_ x: Int, _ y: Int) -> Float { (x < w && y < h) ? s.value[y * w + x] : 0 }
                parallelRows(h, width: w) { y in
                    for x in 0..<w {
                        let (p00, p10, p01, p11) = (at(x, y), at(x + 1, y), at(x, y + 1), at(x + 1, y + 1))
                        var acc: Float = 0
                        for j in 0..<3 {
                            let fy = Float(j) / 3
                            for i in 0..<3 {
                                let fx = Float(i) / 3
                                let v = (p00 * (1 - fx) + p10 * fx) * (1 - fy) + (p01 * (1 - fx) + p11 * fx) * fy
                                acc += lutAt(l, v)
                            }
                        }
                        d.value[y * w + x] = acc / 9
                    }
                }
            }
        }
        return out
    }

    // MARK: Bevel

    /// Where a bevel's maps paint.
    public enum BevelPaint: Int, Sendable { case inner, outer, both }

    public struct BevelGeom: Sendable, Equatable {
        public var paint: BevelPaint
        public var width: Float
        public var depth: Float
        public var pillow: Bool
        public var chiselSoft: Float
    }

    public static func bevelGeom(_ b: Bevel) -> BevelGeom {
        let size = max(b.size, 1)
        let emboss = b.style == .emboss || b.style == .pillowEmboss
        let paint: BevelPaint
        switch b.style {
        case .outerBevel: paint = .outer
        case .emboss, .pillowEmboss: paint = .both
        case .innerBevel, .strokeEmboss: paint = .inner
        }
        let width = emboss ? (size / 2).rounded(.up) : size
        let smooth = b.technique == .smooth
        let sign: Float = b.up ? 1 : -1
        return BevelGeom(paint: paint, width: width, depth: b.depth * (smooth ? width : size / 2) * sign,
                         pillow: b.style == .pillowEmboss, chiselSoft: b.technique == .chiselSoft ? max(size / 4, 1) : 0)
    }

    /// Chiselled height from the inside / outside distances (keep in sync with `pcr_m_bevel_h`).
    public static func bevelChiselH(_ paint: BevelPaint, _ size: Float, _ din: Float, _ dout: Float, soft: Bool) -> Float {
        let ramp = size + 1
        switch paint {
        case .outer where !soft:
            let top = (size + 2) / ramp
            return dout > 0 ? min(max((size + 1.5 - dout) / ramp, 0), top) : top
        case .outer:
            return dout > 0 ? 1 - min(max((dout + 0.5) / ramp, 0), 1) : (size + 2) / ramp
        case .both:
            let half = size / 2 + 0.5
            return din > 0 ? 0.5 + 0.5 * min(max(din / half, 0), 1) : 0.5 - 0.5 * min(max(dout / half, 0), 1)
        case .inner where soft:
            return din > 0 ? min(max((din + 1.5) / ramp, 0), (size + 2) / ramp) : 0
        case .inner:
            return din > 0 ? min(max((din + 0.5) / ramp, 0), 1) : 0
        }
    }

    /// Where a bevel texture tiles: the maps' rectangle and the linked origin.
    public struct TextureContext: Sendable {
        public var rect: PixelRect
        public var anchor: SIMD2<Double>
        public var pattern: @Sendable (String, String) -> PatternTile?
    }

    static func bevelHeight(_ shape: FxMap, _ b: Bevel, _ g: BevelGeom, _ tex: TextureContext) -> FxMap {
        let size = max(b.size, 1)
        var h: FxMap
        if b.technique == .smooth {
            h = shape
            tent(&h, g.width)
        } else {
            let sharp = DistanceFields.sharpEdges(shape)
            let din = DistanceFields.bevelDistInside(shape, sharp, size), dout = DistanceFields.bevelDistOutside(shape, sharp, size)
            h = FxMap(w: shape.w, h: shape.h)
            let soft = g.chiselSoft > 0
            for i in h.v.indices { h.v[i] = bevelChiselH(g.paint, size, din[i], dout[i], soft: soft) }
            if soft && g.paint == .both { tent(&h, g.chiselSoft) }
        }
        if let c = b.contour { h = applyLUT(h, bevelContourLUT(c)) }
        if let t = b.texture, let tile = tex.pattern(t.id, t.name), tile.isPaintable {
            let unit = abs(b.depth) > 1e-6 ? max(abs(g.depth / b.depth), 1e-3) : max(g.width, 1)
            let place = PatternPlacement(anchor: tex.anchor, link: t.link, phase: t.phase, scale: t.scale, angle: 0)
            let k = t.depth / unit
            let (x0, y0) = (tex.rect.x0, tex.rect.y0)
            for y in 0..<h.h {
                for x in 0..<h.w {
                    let (u, v) = place.map(Double(x0 + Int32(x)) + 0.5, Double(y0 + Int32(y)) + 0.5)
                    let p = tile.sample(u, v)
                    let l = (0.299 * p.x + 0.587 * p.y + 0.114 * p.z) * p.w
                    h.v[y * h.w + x] += k * (t.invert ? 1 - l : l)
                }
            }
        }
        if b.soften >= 1 { tent(&h, b.soften) }
        return h
    }

    static func bevelMaps(_ shape: FxMap, _ b: Bevel, _ light: GlobalLight, _ tex: TextureContext) -> ([FxMap], BevelPaint) {
        let g = bevelGeom(b)
        let hmap = bevelHeight(shape, b, g, tex)
        let (angle, altitude) = b.useGlobalLight ? (light.angle, light.altitude) : (b.angle, b.altitude)
        let (sa, ca) = (sinf(radians(angle)), cosf(radians(angle)))
        let (se, ce) = (sinf(radians(altitude)), cosf(radians(altitude)))
        let lv = SIMD3<Float>(ca * ce, -sa * ce, se)
        let reachPast = g.paint == .both || (g.paint == .outer && b.technique != .smooth)
        let (w, h) = (shape.w, shape.h)
        func onBevel(_ x: Int, _ y: Int) -> Bool {
            if hmap.get(x, y) > bevelHeightEps { return true }
            guard reachPast else { return false }
            return hmap.get(x + 1, y) > bevelHeightEps || hmap.get(x - 1, y) > bevelHeightEps
                || hmap.get(x, y + 1) > bevelHeightEps || hmap.get(x, y - 1) > bevelHeightEps
        }
        func shadeInto(_ depth: Float, _ kind: Int) -> (FxMap, FxMap) {
            var hi = FxMap(w: w, h: h), sh = FxMap(w: w, h: h)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let gx = (hmap.get(x + 1, y) - hmap.get(x - 1, y)) * 0.5 * depth
                    let gy = (hmap.get(x, y + 1) - hmap.get(x, y - 1)) * 0.5 * depth
                    let n = SIMD3<Float>(-gx, -gy, 1)
                    let len = (n.x * n.x + n.y * n.y + 1).squareRoot()
                    let shade = (n.x * lv.x + n.y * lv.y + n.z * lv.z) / len
                    let region: Float = kind == 0 ? shape.v[i] : ((shape.v[i] < 1 - insideEps && onBevel(x, y)) ? 1 : 0)
                    let k = shade - se
                    if k > 0 {
                        hi.v[i] = min(max(k / max(1 - se, 1e-3), 0), 1) * region
                    } else {
                        sh.v[i] = min(max(-k / max(se, 1e-3), 0), 1) * region
                    }
                }
            }
            let l = contourLUT(b.glossContour)
            return (applyLUT(hi, l), applyLUT(sh, l))
        }
        switch g.paint {
        case .inner, .outer:
            let (hi, sh) = shadeInto(g.depth, g.paint == .outer ? 1 : 0)
            return ([hi, sh], g.paint)
        case .both:
            let (hi, sh) = shadeInto(g.depth, 0)
            let (ho, so) = shadeInto(g.pillow ? -g.depth : g.depth, 1)
            func mix(_ a: FxMap, _ b: FxMap) -> FxMap {
                FxMap(w: a.w, h: a.h, v: (0..<a.v.count).map { i in
                    let s = shape.v[i]
                    return (s > insideEps ? a.v[i] : 0) + b.v[i] * (1 - min(s, 1))
                })
            }
            return ([mix(hi, ho), mix(sh, so)], .both)
        }
    }

    /// The frame a gradient stroke aligned with the layer is laid out in.
    static func strokeFrame(_ shape: FxMap, _ outW: Float, _ rect: PixelRect) -> PixelRect {
        var (x0, y0, x1, y1) = (Int.max, Int.max, 0, 0)
        for y in 0..<shape.h {
            for x in 0..<shape.w where shape.v[y * shape.w + x] > insideEps {
                x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
            }
        }
        if x0 == Int.max { return rect }
        let grow = outW.isFinite ? max(Int32(min(outW, maxReach).rounded(.up)) - 1, 0) : 0
        return PixelRect(x0: rect.x0 + Int32(x0), y0: rect.y0 + Int32(y0), x1: rect.x0 + Int32(x1), y1: rect.y0 + Int32(y1)).outset(by: grow)
    }
}

/// Effect maps of one layer over its region (photocraft `FxMaps`).
public final class FxMaps: @unchecked Sendable {
    public let rect: PixelRect
    let shape: FxMap
    /// Per enabled effect (in `items` order): the maps it paints through.
    let per: [[FxMap]]
    let bevelPaint: [EffectMath.BevelPaint]
    let din: [Float]?
    let dout: [Float]?
    let vdout: [Float]?
    let outline: Bool
    /// Frames of gradient strokes by outside width (bit pattern).
    let frames: [(UInt32, PixelRect)]

    init(rect: PixelRect, shape: FxMap, per: [[FxMap]], bevelPaint: [EffectMath.BevelPaint], din: [Float]?, dout: [Float]?,
         vdout: [Float]?, outline: Bool, frames: [(UInt32, PixelRect)]) {
        self.rect = rect; self.shape = shape; self.per = per; self.bevelPaint = bevelPaint; self.din = din
        self.dout = dout; self.vdout = vdout; self.outline = outline; self.frames = frames
    }

    /// Approximate heap size (cache budgeting).
    public var bytes: Int {
        let n = shape.v.count
        let maps = per.reduce(0) { $0 + $1.count }
        return (1 + maps + (din == nil ? 0 : 1) + (dout == nil ? 0 : 1) + (vdout == nil ? 0 : 1)) * n * 4
    }

    func strokeFrame(_ st: StrokeFx) -> PixelRect? {
        let key = EffectMath.strokeWidths(st).outer.bitPattern
        return frames.first { $0.0 == key }?.1
    }

    func cropVec(_ v: [Float], to: PixelRect, fill: Float) -> [Float] {
        let (w, h) = (to.width, to.height)
        var out = [Float](repeating: fill, count: w * h)
        let inter = rect.intersect(to)
        if inter.isEmpty { return out }
        let sw = rect.width
        for y in inter.y0..<inter.y1 {
            let s0 = Int(y - rect.y0) * sw + Int(inter.x0 - rect.x0)
            let d0 = Int(y - to.y0) * w + Int(inter.x0 - to.x0)
            for k in 0..<inter.width { out[d0 + k] = v[s0 + k] }
        }
        return out
    }

    func crop(_ m: FxMap, to: PixelRect, fill: Float) -> FxMap {
        FxMap(w: to.width, h: to.height, v: cropVec(m.v, to: to, fill: fill))
    }

    /// Builds every effect map of `effects` from the shape `shape` (row-major over `rect`).
    public static func build(effects: Effects, shape: [Float], rect: PixelRect, light: GlobalLight,
                             vectorShape: Bool, outline: Bool, texture: EffectMath.TextureContext) -> FxMaps {
        let s = FxMap(w: rect.width, h: rect.height, v: shape)
        let items = effects.items.filter(\.isEnabled)
        var bevelPaint = [EffectMath.BevelPaint](repeating: .inner, count: items.count)
        let origin = (rect.x0, rect.y0)
        var per: [[FxMap]] = []
        for (i, e) in items.enumerated() {
            switch e {
            case .dropShadow(let sh): per.append([EffectMath.shadowMap(s, sh, light, inner: false, origin: origin)])
            case .innerShadow(let sh): per.append([EffectMath.shadowMap(s, sh, light, inner: true, origin: origin)])
            case .outerGlow(let g): per.append([EffectMath.glowMap(s, g, inner: false, origin: origin)])
            case .innerGlow(let g): per.append([EffectMath.glowMap(s, g, inner: true, origin: origin)])
            case .satin(let st): per.append([EffectMath.satinMap(s, st)])
            case .bevelEmboss(let b):
                let (maps, paint) = EffectMath.bevelMaps(s, b, light, texture)
                bevelPaint[i] = paint
                per.append(maps)
            default: per.append([])
            }
        }
        let hasStroke = items.contains { if case .stroke = $0 { return true } else { return false } }
        let din = hasStroke ? DistanceFields.distInside(s, .chamfer) : nil
        let dout = hasStroke ? DistanceFields.distOutside(s, .chamfer) : nil
        let vdout = (hasStroke && vectorShape && !outline) ? DistanceFields.distOutside(DistanceFields.localCoverage(s), .chamfer) : nil
        var frames: [(UInt32, PixelRect)] = []
        for e in items {
            if case .stroke(let st) = e, case .gradient = st.paint {
                let outW = EffectMath.strokeWidths(st).outer
                if !frames.contains(where: { $0.0 == outW.bitPattern }) {
                    frames.append((outW.bitPattern, EffectMath.strokeFrame(s, outW, rect)))
                }
            }
        }
        return FxMaps(rect: rect, shape: s, per: per, bevelPaint: bevelPaint, din: din, dout: dout, vdout: vdout, outline: outline,
                      frames: frames)
    }
}
