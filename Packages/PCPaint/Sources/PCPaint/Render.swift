// Port of photocraft-paint (crates/paint/src/render.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Dab rasterisation and stroke compositing (the CPU reference). A stroke paints into a sparse,
// tiled *stroke buffer* (coverage plus, with Color Dynamics, a premultiplied colour), exactly like
// a private stroke layer: dabs build up with flow up to their opacity ceiling, stroke-level masks
// (Dual Brush, Texture) apply when the buffer is composited, and the whole buffer composites onto
// the pre-stroke pixels at the stroke opacity. Because the buffer is sparse and compositing always
// starts from the pre-stroke pixels, strokes can be fed in chunks and re-composited incrementally
// for interactive painting (`StrokeRenderer`).

import Foundation
import PCFoundation

/// Salt of the 8-bit dither's per-pixel noise.
let ditherSalt: UInt64 = 0x0000_6469_7468_6572
/// Edge of a stroke-buffer tile.
public let covTile: Int32 = 64
/// Computed tips with a smaller radius (in pixels) are rasterised by area, not at pixel centres.
let smallTipRadius: Float = 3
/// Sub-pixel sample offsets (a 4×4 grid) for the area coverage of small tips.
let subpixel: [Float] = [-0.375, -0.125, 0.125, 0.375]
let noiseSalt: UInt64 = 0x006E_6F69_7365
/// How far a Height-mode dab at full depth and coverage reaches into the pattern (#3340).
let heightReach: Float = 12

/// Before a stroke's result is quantised to 8 bits, offset every channel of the pixel by the same
/// deterministic noise of under half a level, so fractional values round up or down in proportion
/// (a soft, low-flow stroke's gradient survives as grain instead of bands).
@inline(__always) func dither8(_ px: UnsafeMutablePointer<Float>, _ n: Int, _ x: Int32, _ y: Int32) {
    let d = (PaintRNG.hash2(x, y, ditherSalt) - 0.5) / 255
    for i in 0..<n { px[i] += d }
}

/// Where an aliased (Pencil) dab of `diameter` pixels centred near (`x`, `y`) lands on the pixel
/// grid: the centre of the pixel holding the point for odd diameters, the nearest pixel corner
/// for even ones.
public func gridCenter(_ x: Double, _ y: Double, _ diameter: Float) -> (Float, Float) {
    let n: Int64 = diameter.isFinite ? asI64(maxR(diameter.rounded(), 1)) : 1
    func snap(_ v: Double) -> Double { n % 2 == 1 ? v.rounded(.down) + 0.5 : v.rounded() }
    return (Float(snap(x)), Float(snap(y)))
}

/// The whole-pixel square `[x0, y0, x1, y1]` an aliased dab of `diameter` pixels at (`x`, `y`)
/// can touch: the Pencil's cursor.
public func gridSquare(_ x: Double, _ y: Double, _ diameter: Float) -> [Double] {
    let n: Double = diameter.isFinite ? Double(clampR(diameter.rounded(), 1, 100_000)) : 1
    let (cx, cy) = gridCenter(x, y, Float(n))
    let h = n / 2
    return [Double(cx) - h, Double(cy) - h, Double(cx) + h, Double(cy) + h]
}

@inline(__always) func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clampR((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Wet Edges: how much paint stays at a pixel whose nearest dab reaches it at `rn` (0 at a dab's
/// centre, 1 at its rim). The interior keeps half the paint, the rim all of it.
@inline(__always) func wetFactor(_ rn: Float) -> Float { 0.5 + 0.5 * smoothstep(0.5, 1, rn) }

/// Combine brush coverage `v` with a mask value `t` (texture/dual tip) at depth `d`. Every mode
/// maps `v = 0` to 0 (a mask never adds paint where the brush has none).
public func maskCombine(_ mode: MaskMode, _ v: Float, _ t: Float, _ d: Float) -> Float {
    if v <= 0 { return 0 }
    @inline(__always) func lerp(_ a: Float, _ b: Float) -> Float { a + (b - a) * d }
    let r: Float
    switch mode {
    case .multiply: r = v * (1 - d + d * t)
    case .subtract: r = maxR(v - d * (1 - t), 0)
    case .darken: r = minR(v, 1 - d + d * t)
    case .overlay:
        let o = v < 0.5 ? 2 * v * t : 1 - 2 * (1 - v) * (1 - t)
        r = lerp(v, o)
    case .colorDodge: r = lerp(v, minR(v / maxR(1 - t, 1e-3), 1))
    case .colorBurn: r = lerp(v, 1 - minR((1 - v) / maxR(t, 1e-3), 1))
    case .linearBurn: r = lerp(v, maxR(v + t - 1, 0))
    case .hardMix: r = lerp(v, v + t > 1 ? 1 : 0)
    case .linearHeight: r = v * clampR((t - (1 - d * v)) * 4 + 0.5, 0, 1)
    case .height: r = t >= 1 - d * v ? v : 0
    }
    return clampR(r, 0, 1)
}

/// Combine brush coverage `v` with a Texture pattern value `t` at depth `d` (Brush Settings ›
/// Texture). Where it differs from `maskCombine` (still used for the Dual Brush) it follows
/// Photoshop as measured with single dabs over a grey ramp (photocraft #3340).
public func textureCombine(_ mode: MaskMode, _ v: Float, _ t: Float, _ d: Float) -> Float {
    if v <= 0 { return 0 }
    let r: Float
    switch mode {
    case .subtract: r = v - d * t
    case .colorDodge: r = v / maxR(1 - d * t, 1e-3)
    case .colorBurn: r = 1 - (1 - v) / maxR(1 - d + d * t, 1e-3)
    // Photoshop steps the depth in 1/255ths here, which shows at the lowest depths.
    case .height: r = heightReach * (d * 255).rounded() / 255 * v - t
    case .linearHeight:
        let reach = heightReach * (d * 255).rounded() / 255 * v
        r = reach < 1 ? reach * (1 - t) : reach - t
    default: r = maskCombine(mode, v, t, d)
    }
    return r.isFinite ? clampR(r, 0, 1) : 0
}

/// The pixel rectangle `reach` (plus 1 px of anti-aliasing slack) around a dab's centre. The casts
/// and the arithmetic saturate, so a far or non-finite centre or reach gives a (possibly empty)
/// rectangle instead of an overflow (#977).
public func rectAround(_ d: Dab, _ reach: Float) -> PixelRect {
    let rr = asI32(reach.rounded(.up)).satAdd(1)
    let cx = asI32(d.center.x.rounded(.down)), cy = asI32(d.center.y.rounded(.down))
    return PixelRect(cx.satSub(rr), cy.satSub(rr), cx.satAdd(rr).satAdd(1), cy.satAdd(rr).satAdd(1))
}

/// A stroke-ready brush: the settings plus prepared tip mips and texture.
public struct BrushContext: Sendable {
    public let brush: BrushSettings
    public let tip: Mips?
    public let dualTip: Mips?
    public let texture: PatternImage?
    // Scalars the per-pixel paths read (cached so no hot loop copies the settings).
    let dualMode: MaskMode
    let texMode: MaskMode
    let texDepth: Float
    let strokeTexture: Bool
    let texScale: Float

    public init(_ brush0: BrushSettings) {
        let brush = brush0.boundedForRender()
        func mips(_ t: TipShape) -> Mips? {
            guard let g = t.bitmap, g.isValid else { return nil }
            return Mips(g)
        }
        tip = mips(brush.tip)
        dualTip = brush.dualBrush.enabled ? mips(brush.dualBrush.tip) : nil
        texture = BrushContext.preparePattern(brush)
        self.brush = brush
        dualMode = brush.dualBrush.mode
        texMode = brush.texture.mode
        texDepth = clampR(brush.texture.depth, 0, 1)
        strokeTexture = texture != nil && !brush.texture.eachTip
        texScale = maxR(brush.texture.scale, 0.01)
    }

    static func preparePattern(_ b: BrushSettings) -> PatternImage? {
        let t = b.texture
        if !t.enabled { return nil }
        var img: PatternImage
        switch t.pattern {
        case .procedural(let style, let size, let seed): img = Procedural.pattern(style, size, seed)
        default:
            guard let g = t.pattern.bitmap, g.isValid else { return nil }
            img = PatternImage(width: Int(g.width), height: Int(g.height), data: g.toF32())
        }
        for i in img.data.indices { img.data[i] = t.level(img.data[i]) }
        return img
    }

    /// Texture value at a document pixel (bilinear, tiled).
    @inline(__always) public func textureAt(_ x: Int32, _ y: Int32) -> Float {
        guard let p = texture else { return 1 }
        let s = texScale
        if s == 1 {
            // Pixel centres land exactly on texels at 100 %.
            return p.data[Int(remEuclid(y, Int32(truncatingIfNeeded: p.height))) * p.width + Int(remEuclid(x, Int32(truncatingIfNeeded: p.width)))]
        }
        let fx = (Float(x) + 0.5) / s - 0.5, fy = (Float(y) + 0.5) / s - 0.5
        let x0 = fx.rounded(.down), y0 = fy.rounded(.down)
        let tx = fx - x0, ty = fy - y0
        let a = p.sampleWrap(x0, y0) + (p.sampleWrap(x0 + 1, y0) - p.sampleWrap(x0, y0)) * tx
        let b = p.sampleWrap(x0, y0 + 1) + (p.sampleWrap(x0 + 1, y0 + 1) - p.sampleWrap(x0, y0 + 1)) * tx
        return a + (b - a) * ty
    }

    /// Bounding rectangle of a dab (rotated sampled tips need the corner reach).
    public func dabRect(_ d: Dab, dual: Bool) -> PixelRect {
        let sampled = dual ? dualTip != nil : tip != nil
        let reach = sampled ? d.radius * Float(2).squareRoot() : d.radius
        return rectAround(d, reach)
    }

    /// Rasterise a dab over `rect` into `out` (tip shape × noise × per-tip texture × wet edges ×
    /// flow). Wet Edges shapes this one dab; a stroke applies it to its accumulated coverage instead.
    public func rasterize(_ d: Dab, dual: Bool, rect: PixelRect, _ out: inout [Float]) {
        var none: [Float] = []
        rasterizeInto(d, dual: dual, rect: rect, &out, depth: &none, withDepth: false)
    }

    /// `rasterize`; with `withDepth`, Wet Edges is left out of `out` and each painted pixel's depth
    /// inside the dab (`1 − rn`) goes to `depth`, for the stroke to apply it.
    public func rasterizeInto(_ d: Dab, dual: Bool, rect: PixelRect, _ out: inout [Float], depth: inout [Float], withDepth: Bool) {
        let w = rect.width, h = rect.height
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: repeatElement(0, count: w * h))
        if withDepth {
            depth.removeAll(keepingCapacity: true)
            depth.append(contentsOf: repeatElement(0, count: w * h))
        }
        let b = brush
        let hardness = dual ? b.dualBrush.hardness : b.hardness
        let mips = dual ? dualTip : tip
        let aliased = b.aliased && !dual
        let wet = b.wetEdges && !dual && !withDepth
        let noise = b.noise && !dual
        let texTip = !dual && b.texture.enabled && b.texture.eachTip && texture != nil
        let (cx, cy) = aliased ? gridCenter(d.center.x, d.center.y, 2 * d.radius) : (Float(d.center.x), Float(d.center.y))
        let sn = sinf(d.angle), cs = cosf(d.angle)
        let fx: Float = d.flipX ? -1 : 1, fy: Float = d.flipY ? -1 : 1
        // Brush Projection: stretch the sampling coordinates along the tilt direction, which
        // foreshortens the tip there by `projScale`.
        let proj: (Float, Float, Float)? = (!dual && d.projScale < 0.999)
            ? (cosf(d.projAngle), sinf(d.projAngle), 1 / maxR(d.projScale, 0.05) - 1) : nil
        let r = d.radius
        let ro = minR(maxR(d.roundness, 0.5 / r), 1)
        let rm = maxR(r * ro, 0.5)
        let reach2 = (rm + 0.5) * (rm + 0.5)
        // Sampled-tip mapping.
        var level = 0
        var invScale: Float = 1, tw: Float = 1, th: Float = 1
        if let m = mips {
            let l0 = m.levels[0]
            let big = Float(max(l0.w, l0.h))
            level = m.levelFor(2 * r * maxR(ro, 0.25))
            invScale = big / (2 * r)
            tw = Float(l0.w); th = Float(l0.h)
        }
        // A pixel offset from the dab centre in tip space: to y-up, project, rotate by −angle, flip.
        @inline(__always) func toTip(_ dx: Float, _ dy: Float) -> (Float, Float) {
            var ux = dx, uy = -dy
            if let (ax, ay, k) = proj {
                let t = (ux * ax + uy * ay) * k
                ux += t * ax
                uy += t * ay
            }
            return ((ux * cs + uy * sn) * fx, (-ux * sn + uy * cs) * fy)
        }
        // A tip a few pixels across takes each pixel's covered area (a 4×4 grid inside it).
        let small = mips == nil && !aliased && rm < smallTipRadius
        let smallReach2 = (rm + 0.75) * (rm + 0.75)
        // Ordinary computed tips take the vectorisable fast path.
        if !(mips != nil || small || (aliased && b.square) || noise || texTip || wet)
            && !withDepth && proj == nil && d.angle == 0 && d.radius.isFinite && d.roundness.isFinite && rm.isFinite
            && cx.isFinite && cy.isFinite && hardness.isFinite && d.alpha.isFinite && w > 0 {
            out.withUnsafeMutableBufferPointer { o in rasterizeRound(d, rect, o, hardness, aliased) }
            return
        }
        if w == 0 || h == 0 { return }
        let square = aliased && b.square
        let texMode = b.texture.mode
        let sub = subpixel
        let sampled = mips != nil
        let lvl = mips.map { $0.levels[level] }
        let lw = lvl?.w ?? 0, lh = lvl?.h ?? 0
        let lv = lvl?.v ?? []
        lv.withUnsafeBufferPointer { lp in
        out.withUnsafeMutableBufferPointer { o in
            depth.withUnsafeMutableBufferPointer { dp in
                for yy in 0..<h {
                    let y = rect.y0 + Int32(yy)
                    let dy = Float(y) + 0.5 - cy
                    for xx in 0..<w {
                        let x = rect.x0 + Int32(xx)
                        let dx = Float(x) + 0.5 - cx
                        let (u, v) = toTip(dx, dy)
                        var val: Float
                        let rn: Float
                        if square {
                            // Block: the whole-pixel square, hard (the Eraser's Block mode).
                            if abs(dx) >= r || abs(dy) >= r { continue }
                            val = 1; rn = 0
                        } else if sampled {
                            let px = u * invScale + tw / 2, py = -(v / ro) * invScale + th / 2
                            if px < -1 || py < -1 || px > tw + 1 || py > th + 1 { continue }
                            let s = Mips.sample(lp, lw, lh, px / tw, py / th)
                            val = aliased ? (s >= 0.5 ? 1 : 0) : s
                            rn = 1 - s
                        } else if small {
                            let d2 = (u * ro) * (u * ro) + v * v
                            if d2 >= smallReach2 { continue }
                            var sum: Float = 0
                            for sy in sub {
                                for sx in sub {
                                    let (su, sv) = toTip(dx + sx, dy + sy)
                                    let sd = ((su * ro) * (su * ro) + sv * sv).squareRoot()
                                    // Each sample anti-aliases over its own quarter pixel.
                                    let inside = clampR((rm - sd) * 4 + 0.5, 0, 1)
                                    if inside > 0 { sum += inside * tipFalloff(minR(sd, rm), rm, hardness) }
                                }
                            }
                            val = sum / Float(sub.count * sub.count)
                            rn = d2.squareRoot() / rm
                        } else {
                            let d2 = (u * ro) * (u * ro) + v * v
                            if d2 >= reach2 { continue }
                            let dd = d2.squareRoot()
                            val = aliased ? (dd <= rm ? 1 : 0) : dabCoverage(dd, rm, hardness)
                            rn = dd / rm
                        }
                        if val <= 0 { continue }
                        if noise && val < 1 {
                            let n = PaintRNG.hash2(x, y, noiseSalt)
                            let hard: Float = n < val ? 1 : 0
                            val += (hard - val) * 0.7
                        }
                        if texTip { val = textureCombine(texMode, val, textureAt(x, y), d.depth) }
                        if wet { val *= wetFactor(rn) }
                        if withDepth { dp[yy * w + xx] = clampR(1 - rn, 0, 1) }
                        o[yy * w + xx] = val * d.alpha
                    }
                }
            }
        }
        }
    }

    /// One dab's dense footprint (for the sequential retouch tools).
    public func footprint(_ d: Dab, index: Int) -> Footprint {
        let rect = dabRect(d, dual: false)
        var cov: [Float] = []
        rasterize(d, dual: false, rect: rect, &cov)
        return Footprint(dab: d, index: index, rect: rect, cov: cov)
    }

    /// Stroke-level masks applied to accumulated coverage `c` at a pixel.
    @inline(__always) public func strokeMask(_ c: Float, dual: Float?, _ x: Int32, _ y: Int32) -> Float {
        strokeMaskWet(c, depth: nil, dual: dual, x, y)
    }

    /// `strokeMask` with Wet Edges from the stroke's depth at the pixel (the deepest any dab reaches).
    @inline(__always) func strokeMaskWet(_ c: Float, depth: Float?, dual: Float?, _ x: Int32, _ y: Int32) -> Float {
        var m = depth.map { c * wetFactor(1 - $0) } ?? c
        if let dv = dual { m = maskCombine(dualMode, m, dv, 1) }
        if strokeTexture { m = textureCombine(texMode, m, textureAt(x, y), texDepth) }
        return m
    }
}

// The zero-angle transform only changes signs; squaring gives the same radial distance.
@inline(never)
func rasterizeRound(_ d: Dab, _ rect: PixelRect, _ out: UnsafeMutableBufferPointer<Float>, _ hardness: Float, _ aliased: Bool) {
    let (cx, cy) = aliased ? gridCenter(d.center.x, d.center.y, 2 * d.radius) : (Float(d.center.x), Float(d.center.y))
    let ro = minR(maxR(d.roundness, 0.5 / d.radius), 1)
    let rm = maxR(d.radius * ro, 0.5)
    let w = rect.width, h = rect.height
    let reach2 = (rm + 0.5) * (rm + 0.5)
    let inner = rm * clampR(hardness, 0, 1)
    let alpha = d.alpha
    let x0f = rect.x0
    for yy in 0..<h {
        let dy = Float(rect.y0 + Int32(yy)) + 0.5 - cy
        let dy2 = dy * dy
        let row = out.baseAddress! + yy * w
        if aliased {
            for xx in 0..<w {
                let dx = Float(x0f + Int32(xx)) + 0.5 - cx
                let d2 = (dx * ro) * (dx * ro) + dy2
                row[xx] = (d2 < reach2 && d2.squareRoot() <= rm) ? alpha : 0
            }
        } else if rm - inner < 1e-3 {
            for xx in 0..<w {
                let dx = Float(x0f + Int32(xx)) + 0.5 - cx
                let d2 = (dx * ro) * (dx * ro) + dy2
                let edge = minR(clampR(rm + 0.5 - d2.squareRoot(), 0, 1), 1)
                row[xx] = (d2 >= reach2 || edge <= 0) ? 0 : edge * alpha
            }
        } else {
            let span = rm - inner
            for xx in 0..<w {
                let dx = Float(x0f + Int32(xx)) + 0.5 - cx
                let d2 = (dx * ro) * (dx * ro) + dy2
                let dd = d2.squareRoot()
                let edge = minR(clampR(rm + 0.5 - dd, 0, 1), 1)
                let t = clampR((dd - inner) / span, 0, 1)
                let s = 1 - t * t
                let s2 = s * s
                let falloff: Float = dd <= inner ? 1 : s2 * s2
                let val = edge * falloff
                row[xx] = (d2 >= reach2 || val <= 0) ? 0 : val * alpha
            }
        }
    }
}

// MARK: - Sparse stroke buffer

/// A stroke-buffer tile key `(tx, ty)` (64-pixel tiles), ordered as photocraft sorts its tuples.
public struct CovKey: Hashable, Sendable, Comparable {
    public var tx: Int32
    public var ty: Int32
    public init(_ tx: Int32, _ ty: Int32) { self.tx = tx; self.ty = ty }
    public static func < (a: CovKey, b: CovKey) -> Bool { (a.tx, a.ty) < (b.tx, b.ty) }
    public var rect: PixelRect { PixelRect(tx * covTile, ty * covTile, (tx + 1) * covTile, (ty + 1) * covTile) }

    /// Every key a rectangle touches.
    static func keys(_ r: PixelRect) -> [CovKey] {
        if r.isEmpty { return [] }
        var out: [CovKey] = []
        for ty in divEuclid(r.y0, covTile)...divEuclid(r.y1 - 1, covTile) {
            for tx in divEuclid(r.x0, covTile)...divEuclid(r.x1 - 1, covTile) { out.append(CovKey(tx, ty)) }
        }
        return out
    }
}

struct CovTile: Sendable {
    var cov: [Float]
    /// Wet Edges: the deepest any dab reaches each pixel (`1 − rn` of the nearest dab), empty
    /// without Wet Edges.
    var depth: [Float]
    /// Premultiplied native colour channels (`nc` per pixel), empty without per-dab colour.
    var col: [Float]
}

/// A sparse tiled coverage (+ optional colour) buffer.
public struct CoverageMap: Sendable {
    var tiles: [CovKey: CovTile] = [:]
    var nc: Int
    public internal(set) var bounds: PixelRect = .empty
    var dirty: Set<CovKey> = []

    public init(colorChannels: Int) { nc = colorChannels }

    static let tilePixels = Int(covTile * covTile)

    @inline(__always) public func get(_ x: Int32, _ y: Int32) -> Float {
        let tx = divEuclid(x, covTile), ty = divEuclid(y, covTile)
        guard let t = tiles[CovKey(tx, ty)] else { return 0 }
        return t.cov[Int((y - ty * covTile) * covTile + (x - tx * covTile))]
    }

    /// Wet Edges depth at a pixel; nil when the stroke has none.
    @inline(__always) public func depth(_ x: Int32, _ y: Int32) -> Float? {
        let tx = divEuclid(x, covTile), ty = divEuclid(y, covTile)
        guard let t = tiles[CovKey(tx, ty)] else { return nil }
        let i = Int((y - ty * covTile) * covTile + (x - tx * covTile))
        return i < t.depth.count ? t.depth[i] : nil
    }

    public var tileKeys: [CovKey] { tiles.keys.sorted() }

    /// Accumulate dab values over `rect`: flow builds up towards the dab's opacity ceiling
    /// (`c ← c + v·(ceil − c)`). `color` = native colour for per-dab colour. `depth` (Wet Edges,
    /// one value per pixel of `rect`) keeps the deepest any dab reaches each pixel.
    mutating func accumulate(_ rect: PixelRect, _ vals: UnsafeBufferPointer<Float>, ceil: Float,
                             color: UnsafeBufferPointer<Float>?, depth: UnsafeBufferPointer<Float>?) {
        if rect.isEmpty { return }
        bounds = bounds.union(rect)
        let w = rect.width
        let nc = self.nc
        let wantCol = color != nil && nc > 0
        let tp = CoverageMap.tilePixels
        for key in CovKey.keys(rect) {
            let tr = key.rect.intersect(rect)
            if tr.isEmpty { continue }
            // Skip tiles this dab doesn't touch.
            var any = false
            scan: for y in tr.y0..<tr.y1 {
                let row = Int(y - rect.y0) * w
                for x in Int(tr.x0 - rect.x0)..<Int(tr.x1 - rect.x0) where vals[row + x] > 0 { any = true; break scan }
            }
            if !any { continue }
            var tile = tiles.removeValue(forKey: key)
                ?? CovTile(cov: [Float](repeating: 0, count: tp), depth: [],
                           col: wantCol ? [Float](repeating: 0, count: tp * nc) : [])
            if wantCol && tile.col.isEmpty { tile.col = [Float](repeating: 0, count: tp * nc) }
            if depth != nil && tile.depth.isEmpty { tile.depth = [Float](repeating: 0, count: tp) }
            dirty.insert(key)
            let hasDepthSlots = !tile.depth.isEmpty
            tile.cov.withUnsafeMutableBufferPointer { cov in
                tile.depth.withUnsafeMutableBufferPointer { dep in
                    tile.col.withUnsafeMutableBufferPointer { col in
                        for y in tr.y0..<tr.y1 {
                            let row = Int(y - rect.y0) * w
                            let trow = Int((y - key.ty * covTile) * covTile)
                            for x in tr.x0..<tr.x1 {
                                let vi = row + Int(x - rect.x0)
                                let v = vals[vi]
                                if v <= 0 { continue }
                                let ti = trow + Int(x - key.tx * covTile)
                                if let dpv = depth, hasDepthSlots { dep[ti] = maxR(dep[ti], dpv[vi]) }
                                let c = cov[ti]
                                let nv = ceil > c ? c + v * (ceil - c) : c
                                if nv <= c { continue }
                                if wantCol, let cl = color {
                                    let k: Float = c < 1 ? (nv - c) / (1 - c) : 0
                                    let p = ti * nc
                                    for i in 0..<nc { col[p + i] = cl[i] * k + col[p + i] * (1 - k) }
                                }
                                cov[ti] = nv
                            }
                        }
                    }
                }
            }
            tiles[key] = tile
        }
    }

    mutating func takeDirty() -> [CovKey] {
        let v = dirty.sorted()
        dirty.removeAll()
        return v
    }

    /// The finished coverage over the tiles `keys`: `tail`'s copy of a tile where finishing the
    /// stroke changes it, else this map's own.
    func finishedSubset(_ tail: CoverageMap?, _ keys: Set<CovKey>) -> CoverageMap {
        var m = CoverageMap(colorChannels: nc)
        for k in keys {
            if let t = tail?.tiles[k] ?? tiles[k] { m.tiles[k] = t }
        }
        m.bounds = tail?.bounds ?? bounds
        return m
    }

    /// Union two passes of the same brush stroke without applying opacity twice where they
    /// overlap. The stronger coverage wins, including its per-dab colour when present.
    mutating func unionMax(_ other: CoverageMap) {
        bounds = bounds.union(other.bounds)
        let nc = self.nc
        for (key, source) in other.tiles {
            guard var target = tiles.removeValue(forKey: key) else {
                tiles[key] = source
                dirty.insert(key)
                continue
            }
            if target.depth.isEmpty {
                target.depth = source.depth
            } else {
                for i in 0..<min(target.depth.count, source.depth.count) { target.depth[i] = maxR(target.depth[i], source.depth[i]) }
            }
            let colOK = nc > 0 && target.col.count == target.cov.count * nc && source.col.count == source.cov.count * nc
            target.cov.withUnsafeMutableBufferPointer { tc in
                source.cov.withUnsafeBufferPointer { sc in
                    target.col.withUnsafeMutableBufferPointer { tcol in
                        source.col.withUnsafeBufferPointer { scol in
                            for i in 0..<min(tc.count, sc.count) where sc[i] > tc[i] {
                                tc[i] = sc[i]
                                if colOK { for j in (i * nc)..<(i * nc + nc) { tcol[j] = scol[j] } }
                            }
                        }
                    }
                }
            }
            tiles[key] = target
            dirty.insert(key)
        }
    }
}

// MARK: - Stroke renderer

/// What `StrokeRenderer.compositeUnionLive` drew last: the coverage tiles of the passes'
/// smoothing tails (redrawn without them next time) and the merged bounds.
public struct UnionLive: Sendable {
    var tailKeys: Set<CovKey> = []
    public internal(set) var bounds: PixelRect = .empty
    public init() {}
}

/// Incremental stroke rendering: feed points, composite dirty tiles from the pre-stroke pixels.
public struct StrokeRenderer: Sendable {
    public var ctx: BrushContext
    var generator: DabGenerator
    var cov: CoverageMap
    var dual: CoverageMap?
    let fmt: PixelFormat?
    let perDabColor: Bool
    var dabsDone = 0
    var scratch: [Float] = []
    /// Wet Edges depth of the dab being accumulated.
    var depthScratch: [Float] = []
    var dabBuf: [Dab] = []
    var dualBuf: [Dab] = []
    var allDabs: [Dab]?

    /// `fmt` = target pixel format (needed for per-dab colour); `zoom` for smoothing.
    public init(_ brush: BrushSettings, format fmt: PixelFormat?, zoom: Float = 1) {
        perDabColor = brush.colorDynamics.enabled && !brush.erase && fmt != nil
        let nc = perDabColor ? (fmt?.mode.colorChannels ?? 0) : 0
        ctx = BrushContext(brush)
        generator = DabGenerator(brush: brush, zoom: zoom)
        cov = CoverageMap(colorChannels: nc)
        dual = brush.dualBrush.enabled ? CoverageMap(colorChannels: 0) : nil
        self.fmt = fmt
    }

    /// Keep a copy of every primary dab (for tests and sequential tools).
    public func recordingDabs() -> StrokeRenderer {
        var r = self
        r.allDabs = []
        return r
    }

    public var dabs: [Dab] { allDabs ?? [] }
    public var dabCount: Int { dabsDone }
    /// Union of the dab rectangles so far.
    public var bounds: PixelRect { cov.bounds }
    /// The stroke buffer (read-only), e.g. for parity tests.
    public var coverage: CoverageMap { cov }
    public var dualCoverage: CoverageMap? { dual }

    mutating func rasterPending() {
        let wet = ctx.brush.wetEdges
        var native = [Float](repeating: 0, count: 8)
        let nc = fmt?.mode.colorChannels ?? 0
        for d in dabBuf {
            let rect = ctx.dabRect(d, dual: false)
            // Wet Edges acts on the whole stroke (#2088): the dab records how deep it reaches each
            // pixel and the stroke darkens its own rim when composited, not every dab's.
            ctx.rasterizeInto(d, dual: false, rect: rect, &scratch, depth: &depthScratch, withDepth: wet)
            let useCol = perDabColor && fmt != nil
            if useCol, let f = fmt { native.withUnsafeMutableBufferPointer { _ = fromRGBA(f, d.color, into: $0.baseAddress!) } }
            scratch.withUnsafeBufferPointer { v in
                native.withUnsafeBufferPointer { col in
                    depthScratch.withUnsafeBufferPointer { dp in
                        cov.accumulate(rect, v, ceil: d.opacity, color: useCol ? UnsafeBufferPointer(rebasing: col[0..<nc]) : nil,
                                       depth: wet ? dp : nil)
                    }
                }
            }
            // Bounds track the full dab rectangle (even fully transparent parts), like the damage.
            cov.bounds = cov.bounds.union(rect)
        }
        if dual != nil {
            for d in dualBuf {
                let rect = ctx.dabRect(d, dual: true)
                ctx.rasterize(d, dual: true, rect: rect, &scratch)
                scratch.withUnsafeBufferPointer { v in dual!.accumulate(rect, v, ceil: 1, color: nil, depth: nil) }
            }
        }
        dabsDone += dabBuf.count
        if allDabs != nil { allDabs!.append(contentsOf: dabBuf) }
        dabBuf.removeAll(keepingCapacity: true)
        dualBuf.removeAll(keepingCapacity: true)
    }

    /// See `DabGenerator.wantsTime`.
    public var wantsTime: Bool { generator.wantsTime }
    /// The string between the brush and the pointer while smoothing lags.
    public var smoothingString: (brush: SIMD2<Double>, pointer: SIMD2<Double>)? { generator.smoothingString }

    /// Feed input points (any chunking gives the same result).
    public mutating func push(_ pts: [StrokePoint]) {
        generator.push(pts, &dabBuf, &dualBuf)
        rasterPending()
    }

    /// End of stroke (smoothing catch-up, a lone first point).
    public mutating func finish() {
        generator.finish(&dabBuf, &dualBuf)
        rasterPending()
    }

    /// The primary dabs finishing the stroke now would add, without finishing it.
    public func tailDabs() -> [Dab] {
        var g = generator
        var d: [Dab] = [], du: [Dab] = []
        g.finish(&d, &du)
        return d
    }

    /// What finishing the stroke now would add (the smoothing catch-up tail, or a lone first dab),
    /// for live previews: a renderer holding copies of the coverage tiles the tail touches with the
    /// tail rendered in, so its `composite` draws exactly those tiles as `finish` would leave them.
    /// Nil when finishing adds nothing.
    public func tailPreview() -> StrokeRenderer? {
        var g = generator
        var d: [Dab] = [], du: [Dab] = []
        g.finish(&d, &du)
        if d.isEmpty && du.isEmpty { return nil }
        var keys = Set<CovKey>()
        for r in d.map({ ctx.dabRect($0, dual: false) }) + du.map({ ctx.dabRect($0, dual: true) }) where !r.isEmpty {
            keys.formUnion(CovKey.keys(r))
        }
        func subset(_ m: CoverageMap) -> CoverageMap {
            var s = CoverageMap(colorChannels: m.nc)
            for k in keys { if let t = m.tiles[k] { s.tiles[k] = t } }
            s.bounds = m.bounds
            return s
        }
        var t = self
        t.generator = g
        t.cov = subset(cov)
        t.dual = dual.map(subset)
        t.scratch = []; t.depthScratch = []
        t.dabBuf = d; t.dualBuf = du
        t.allDabs = nil
        t.rasterPending()
        // Tiles whose coverage the tail doesn't change still composite the same: redraw them all.
        t.cov.dirty.formUnion(t.cov.tiles.keys)
        return t
    }

    /// Mark the coverage tiles over `r` for the next `composite` (e.g. to redraw over a preview).
    public mutating func markDirty(_ r: PixelRect) {
        for k in CovKey.keys(r) where cov.tiles[k] != nil { cov.dirty.insert(k) }
    }

    /// The coverage tiles touched since the last call (or `composite`), as one rectangle clipped to
    /// the stroke bounds, and forget them.
    public mutating func takeDirtyRect() -> PixelRect {
        let r = cov.takeDirty().reduce(PixelRect.empty) { $0.union($1.rect) }
        dual?.dirty.removeAll()
        return r.intersect(bounds)
    }

    /// Final coverage over `r`, one value per pixel in rows.
    public func coverageIn(_ r: PixelRect) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(r.area)
        if r.isEmpty { return out }
        for y in r.y0..<r.y1 { for x in r.x0..<r.x1 { out.append(coverageAt(x, y)) } }
        return out
    }

    /// Final stroke coverage at a pixel (stroke-level masks applied, before opacity/selection).
    public func coverageAt(_ x: Int32, _ y: Int32) -> Float {
        let c = cov.get(x, y)
        if c <= 0 { return 0 }
        return ctx.strokeMaskWet(c, depth: cov.depth(x, y), dual: dual.map { $0.get(x, y) }, x, y)
    }

    /// Dense final coverage over the stroke bounds.
    public func denseCoverage() -> (PixelRect, [Float]) {
        let b = bounds
        let w = b.width
        var out = [Float](repeating: 0, count: w * b.height)
        for (key, t) in cov.tiles {
            let tr = key.rect.intersect(b)
            if tr.isEmpty { continue }
            for y in tr.y0..<tr.y1 {
                for x in tr.x0..<tr.x1 {
                    let ti = Int((y - key.ty * covTile) * covTile + (x - key.tx * covTile))
                    let c = t.cov[ti]
                    if c > 0 {
                        out[Int(y - b.y0) * w + Int(x - b.x0)] =
                            ctx.strokeMaskWet(c, depth: ti < t.depth.count ? t.depth[ti] : nil, dual: dual.map { $0.get(x, y) }, x, y)
                    }
                }
            }
        }
        return (b, out)
    }

    /// Composite the stroke buffer onto `target`, reading original pixels from `pre` (the
    /// pre-stroke surface: a copy of the target taken before the first `push`). With
    /// `all = false` only tiles touched since the last composite are processed (interactive use).
    /// Returns the damaged rectangle.
    @discardableResult
    public mutating func composite(pre: Surface, target: inout Surface, selection: Surface? = nil, lockTransparency: Bool = false, all: Bool) -> PixelRect {
        let keys: [CovKey]
        if all {
            cov.dirty.removeAll()
            keys = cov.tiles.keys.sorted()
        } else {
            keys = cov.takeDirty()
        }
        dual?.dirty.removeAll()
        let dmg = StrokeCompositor.composite(keys: keys, cov: cov, dual: dual, ctx: ctx, perDabColor: perDabColor, bounds: bounds,
                                             pre: pre, target: &target, selection: selection, lockTransparency: lockTransparency)
        return all ? bounds : dmg
    }

    /// Composite the union of this stroke and a mirrored pass as one stroke (overlapping dabs on
    /// a symmetry axis stay under one opacity ceiling).
    @discardableResult
    public func compositeUnion(_ other: StrokeRenderer, pre: Surface, target: inout Surface, selection: Surface? = nil,
                               lockTransparency: Bool = false) -> PixelRect {
        compositeUnionMany([other], pre: pre, target: &target, selection: selection, lockTransparency: lockTransparency)
    }

    /// Combine all symmetry passes before applying brush opacity and selection once.
    @discardableResult
    public func compositeUnionMany(_ others: [StrokeRenderer], pre: Surface, target: inout Surface, selection: Surface? = nil,
                                   lockTransparency: Bool = false) -> PixelRect {
        var merged = self
        for o in others {
            merged.cov.unionMax(o.cov)
            if merged.dual != nil, let from = o.dual { merged.dual!.unionMax(from) }
        }
        return merged.composite(pre: pre, target: &target, selection: selection, lockTransparency: lockTransparency, all: true)
    }

    mutating func drainDirty(into keys: inout Set<CovKey>) {
        keys.formUnion(cov.dirty); cov.dirty.removeAll()
        if dual != nil { keys.formUnion(dual!.dirty); dual!.dirty.removeAll() }
    }

    func allKeys(into keys: inout Set<CovKey>) {
        keys.formUnion(cov.tiles.keys)
        if let d = dual { keys.formUnion(d.tiles.keys) }
    }

    /// Live preview of a stroke painted as several passes (the stroke, then its symmetry mirrors):
    /// leaves `target` as finishing every pass now and compositing them with `compositeUnionMany`
    /// over `pre` would, but redraws only the coverage tiles that changed since the previous call.
    /// `full` redraws every tile: on the first call, or when a pass joins. Returns the damage.
    @discardableResult
    public static func compositeUnionLive(_ passes: inout [StrokeRenderer], live: inout UnionLive, full: Bool, pre: Surface,
                                          target: inout Surface, selection: Surface? = nil, lockTransparency: Bool = false) -> PixelRect {
        var keys = live.tailKeys
        live.tailKeys = []
        for i in passes.indices {
            passes[i].drainDirty(into: &keys)
            if full { passes[i].allKeys(into: &keys) }
        }
        let tails = passes.map { $0.tailPreview() }
        var tailKeys = Set<CovKey>()
        for t in tails { t?.allKeys(into: &tailKeys) }
        keys.formUnion(tailKeys)
        var merged: StrokeRenderer?
        for (p, t) in zip(passes, tails) {
            let c = p.cov.finishedSubset(t?.cov, keys)
            let du = p.dual.map { $0.finishedSubset(t?.dual, keys) }
            if merged == nil {
                var m = p
                m.cov = c
                m.dual = du
                m.scratch = []; m.depthScratch = []; m.dabBuf = []; m.dualBuf = []; m.allDabs = nil
                merged = m
            } else {
                merged!.cov.unionMax(c)
                if merged!.dual != nil, let du { merged!.dual!.unionMax(du) }
            }
        }
        guard var m = merged else { return .empty }
        let before = live.bounds, after = m.bounds
        // Back to the pre-stroke pixels where the previous call drew and nothing covers now.
        var dmg = PixelRect.empty
        var region: [Float] = []
        for k in keys.sorted() {
            let tile = k.rect
            let old = tile.intersect(before)
            if !old.isEmpty {
                pre.readRegionReusing(old, &region)
                target.writeRegionSafe(old, &region)
                dmg = dmg.union(old)
            }
            if m.cov.tiles[k] != nil { dmg = dmg.union(tile.intersect(after)) }
        }
        m.composite(pre: pre, target: &target, selection: selection, lockTransparency: lockTransparency, all: true)
        live.tailKeys = tailKeys
        live.bounds = after
        return dmg
    }
}

/// The per-pixel stroke composite, shared by the CPU renderer and the Metal renderer's fallback
/// (formats or modes its composite kernel does not cover).
enum StrokeCompositor {
    static func composite(keys: [CovKey], cov: CoverageMap, dual: CoverageMap?, ctx: BrushContext, perDabColor: Bool, bounds: PixelRect,
                          pre: Surface, target: inout Surface, selection: Surface?, lockTransparency: Bool) -> PixelRect {
        let fmt = target.format
        let n = fmt.channels
        let aIdx = alphaIndex(fmt)
        let nc = fmt.mode.colorChannels
        let b = ctx.brush
        let opacity = clampR(b.opacity, 0, 1)
        var src = [Float](repeating: 0, count: 8)
        src.withUnsafeMutableBufferPointer { _ = fromRGBA(fmt, b.color, into: $0.baseAddress!) }
        if let a = aIdx { src[a] = b.color.w }
        // 8-bit targets: the pixels the stroke changes are dithered as they are quantised.
        let dither = fmt.sample == .u8
        let normal = b.mode == .normal || b.mode == .dissolve
        var dmg = PixelRect.empty
        var region: [Float] = []
        var enc = [Float](repeating: 0, count: 8)
        let du = dual
        for key in keys {
            guard let tile = cov.tiles[key] else { continue }
            let tr = key.rect.intersect(bounds)
            if tr.isEmpty { continue }
            pre.readRegionReusing(tr, &region)
            let sel = selection.map { $0.readChannel0(tr) }
            let w = tr.width
            let hasDepth = !tile.depth.isEmpty
            let hasCol = perDabColor && !tile.col.isEmpty
            // The dual map shares the tile grid: one lookup per tile, zeros where it has none.
            let hasDual = du != nil
            let dualCov = du?.tiles[key]?.cov ?? []
            let mode = b.mode, seed = b.seed, erase = b.erase
            tile.cov.withUnsafeBufferPointer { covP in
            tile.depth.withUnsafeBufferPointer { depP in
            tile.col.withUnsafeBufferPointer { colP in
            dualCov.withUnsafeBufferPointer { dualP in
            region.withUnsafeMutableBufferPointer { reg in
                src.withUnsafeMutableBufferPointer { sp in
                    enc.withUnsafeMutableBufferPointer { ep in
                        for y in tr.y0..<tr.y1 {
                            for x in tr.x0..<tr.x1 {
                                let ti = Int((y - key.ty * covTile) * covTile + (x - key.tx * covTile))
                                let c = covP[ti]
                                if c <= 0 { continue }
                                let i = Int(y - tr.y0) * w + Int(x - tr.x0)
                                let dv: Float? = hasDual ? (dualP.isEmpty ? 0 : dualP[ti]) : nil
                                let m = ctx.strokeMaskWet(c, depth: hasDepth ? depP[ti] : nil, dual: dv, x, y)
                                let s: Float = sel?[i] ?? 1
                                var k = minR(m * opacity * s, 1)
                                if !(k > 0) { continue }
                                if mode == .dissolve {
                                    k = PaintRNG.hash2(x, y, seed) < k ? 1 : 0
                                    if k == 0 { continue }
                                }
                                let px = reg.baseAddress! + i * n
                                if erase {
                                    if let a = aIdx, !lockTransparency { px[a] *= 1 - k }
                                    if dither { dither8(px, n, x, y) }
                                    continue
                                }
                                if lockTransparency, let a = aIdx, px[a] <= 0 { continue }
                                if hasCol {
                                    for ch in 0..<nc { sp[ch] = colP[ti * nc + ch] / c }
                                }
                                if normal {
                                    overNative(fmt, px, sp.baseAddress!, k, lockTransparency)
                                } else {
                                    let d = toRGBA(fmt, px)
                                    let sr = toRGBA(fmt, sp.baseAddress!)
                                    var o = Blend.composite(b.mode, backdrop: d, source: sr, opacity: k)
                                    if lockTransparency { o.w = d.w }
                                    _ = fromRGBA(fmt, o, into: ep.baseAddress!)
                                    for ch in 0..<n { px[ch] = ep[ch] }
                                }
                                if dither { dither8(px, n, x, y) }
                            }
                        }
                    }
                }
            }
            }
            }
            }
            }
            target.writeRegionSafe(tr, &region)
            dmg = dmg.union(tr)
        }
        return dmg
    }
}

/// Render a whole stroke onto `target` (one-shot). Returns the damaged rectangle.
@discardableResult
public func renderStroke(_ target: inout Surface, _ brush: BrushSettings, _ points: [StrokePoint], selection: Surface? = nil,
                         lockTransparency: Bool = false, zoom: Float = 1) -> PixelRect {
    if points.isEmpty { return .empty }
    let pre = target
    var r = StrokeRenderer(brush, format: target.format, zoom: zoom)
    r.push(points)
    r.finish()
    return r.composite(pre: pre, target: &target, selection: selection, lockTransparency: lockTransparency, all: true)
}
