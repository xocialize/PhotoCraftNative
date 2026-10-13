// Port of photocraft-algo (crates/algo/src/render.rs, params_ext.rs, lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Render: Fibers, Lens Flare and Lighting Effects. All three work on straight sRGB
// (photocraft `fxutil::rgba` / `set_rgba`), so their Metal paths are `.joint` (Gray- and RGB-like
// documents; CMYK/Lab run the CPU reference under `.auto`). Per-pixel maths only; constants
// that don't depend on the pixel (ghost positions, light geometry) are computed once in Swift and
// handed to the kernels in Shaders/Render.metal.

import Foundation
import PCFoundation

/// Shared helpers of the Render filters.
enum RenderKit {
    /// `body(x, y, px)` over every pixel of `img` (rows in parallel); `px` is the pixel's samples.
    static func forEachPixel(_ img: inout FloatImage, _ body: (Int32, Int32, UnsafeMutableBufferPointer<Float>) -> Void) {
        let r = img.rect, n = img.channels, w = r.width
        if r.isEmpty || n == 0 { return }
        img.data.withUnsafeMutableBufferPointer { d in
            let dp = UnsafeSendable(d.baseAddress!)
            parallelChunks(r.height, minChunk: 2) { rows in
                for row in rows {
                    for col in 0..<w {
                        body(r.x0 + Int32(col), r.y0 + Int32(row), UnsafeMutableBufferPointer(start: dp.value + (row * w + col) * n, count: n))
                    }
                }
            }
        }
    }

    /// Rust's `f32::powi` (LLVM's repeated squaring / compiler-rt `__powisf2`).
    @inline(__always)
    static func powi(_ x: Float, _ n: Int) -> Float {
        var r: Float = 1, a = x, b = n
        while true {
            if b & 1 != 0 { r *= a }
            b >>= 1
            if b == 0 { break }
            a *= a
        }
        return r
    }

    /// photocraft `render::value_noise`: smooth value noise in [0, 1).
    @inline(__always)
    static func valueNoise(_ x: Float, _ y: Float, _ seed: UInt32) -> Float {
        let ix = DistortKit.floorToInt(x.rounded(.down)), iy = DistortKit.floorToInt(y.rounded(.down))
        let tx = x - Float(ix), ty = y - Float(iy)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let h00 = hash01(ix, iy, 0, seed), h10 = hash01(ix &+ 1, iy, 0, seed)
        let h01 = hash01(ix, iy &+ 1, 0, seed), h11 = hash01(ix &+ 1, iy &+ 1, 0, seed)
        let top = h00 + (h10 - h00) * sx
        let bot = h01 + (h11 - h01) * sx
        return top + (bot - top) * sy
    }

    /// photocraft `render::norm3`.
    @inline(__always)
    static func norm3(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let m = Float.maximum((v.x * v.x + v.y * v.y + v.z * v.z).squareRoot(), 1e-9)
        return SIMD3(v.x / m, v.y / m, v.z / m)
    }

    @inline(__always)
    static func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
}

// MARK: Option types

/// Lens Flare lens type (photocraft `LensType`).
public enum LensType: String, Codable, Sendable, Hashable, CaseIterable {
    /// 50–300 mm zoom.
    case zoom, prime35, prime105, moviePrime
}

/// Lighting Effects light type (photocraft `LightKind`).
public enum LightKind: String, Codable, Sendable, Hashable, CaseIterable {
    case spot, point, infinite
}

/// Bump texture source for Lighting Effects (photocraft `TextureChannel`).
public enum TextureChannel: String, Codable, Sendable, Hashable, CaseIterable {
    case none, red, green, blue, alpha, luminance
}

/// One Lighting Effects light (photocraft `Light`). Positions are fractions of the reference
/// bounds; `z` is the height above the surface as a fraction of the bounds' shorter side. Every
/// field defaults when absent from the JSON (`#[serde(default)]`).
public struct Light: Codable, Sendable, Hashable {
    public var kind: LightKind = .spot
    public var x: Float = 0.25
    public var y: Float = 0.2
    public var z: Float = 0.6
    /// Spot: where the light points (fractions of the bounds).
    public var targetX: Float = 0.5
    public var targetY: Float = 0.55
    /// Infinite: direction the light comes from (degrees, 0 = right, counter-clockwise) and elevation.
    public var angle: Float = 135
    public var elevation: Float = 45
    /// Linear RGB 0–1.
    public var color = SIMD3<Float>(1, 1, 1)
    /// −100…100 (negative lights darken).
    public var intensity: Float = 75
    /// Spot cone half-angle in degrees.
    public var cone: Float = 45
    /// Spot hotspot, 0–100 % of the cone at full intensity.
    public var hotspot: Float = 50
    /// Point light reach as a fraction of the bounds' shorter side.
    public var radius: Float = 0.8

    public init(kind: LightKind = .spot, x: Float = 0.25, y: Float = 0.2, z: Float = 0.6, targetX: Float = 0.5, targetY: Float = 0.55,
                angle: Float = 135, elevation: Float = 45, color: SIMD3<Float> = SIMD3(1, 1, 1), intensity: Float = 75,
                cone: Float = 45, hotspot: Float = 50, radius: Float = 0.8) {
        self.kind = kind; self.x = x; self.y = y; self.z = z; self.targetX = targetX; self.targetY = targetY
        self.angle = angle; self.elevation = elevation; self.color = color; self.intensity = intensity
        self.cone = cone; self.hotspot = hotspot; self.radius = radius
    }

    enum CodingKeys: String, CodingKey { case kind, x, y, z, targetX, targetY, angle, elevation, color, intensity, cone, hotspot, radius }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Light()
        kind = try c.decodeIfPresent(LightKind.self, forKey: .kind) ?? d.kind
        x = try c.decodeIfPresent(Float.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Float.self, forKey: .y) ?? d.y
        z = try c.decodeIfPresent(Float.self, forKey: .z) ?? d.z
        targetX = try c.decodeIfPresent(Float.self, forKey: .targetX) ?? d.targetX
        targetY = try c.decodeIfPresent(Float.self, forKey: .targetY) ?? d.targetY
        angle = try c.decodeIfPresent(Float.self, forKey: .angle) ?? d.angle
        elevation = try c.decodeIfPresent(Float.self, forKey: .elevation) ?? d.elevation
        color = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .color) ?? d.color
        intensity = try c.decodeIfPresent(Float.self, forKey: .intensity) ?? d.intensity
        cone = try c.decodeIfPresent(Float.self, forKey: .cone) ?? d.cone
        hotspot = try c.decodeIfPresent(Float.self, forKey: .hotspot) ?? d.hotspot
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? d.radius
    }
}

// MARK: GPU uniforms (mirrored in Render.metal)

struct RenderFibersGPU: BitwiseCopyable {
    var fg: SIMD4<Float>; var bg: SIMD4<Float>; var fx: Float; var fy: Float; var variance: Float; var seed: UInt32
}
struct RenderFlareGPU: BitwiseCopyable {
    var c: SIMD2<Float>; var s: Float; var bright: Float
    var core: Float; var glow: Float; var ringR: Float; var ringW: Float
    var rays: Float; var streak: Float; var ghosts: UInt32; var pad0: Int32 = 0
}
/// One prepared ghost: (x, y, radius·s, k) and (tint, 0).
struct RenderGhostGPU: BitwiseCopyable { var pos: SIMD4<Float>; var tint: SIMD4<Float> }
struct RenderLightingGPU: BitwiseCopyable {
    var ambient: Float; var shininess: Float; var specK: Float; var metal: Float
    var expo: Float; var hscale: Float; var texture: UInt32; var whiteIsHigh: UInt32
    var lights: UInt32; var pad0: Int32 = 0; var pad1: Int32 = 0; var pad2: Int32 = 0
}
/// One prepared light: position, direction (infinite) or spot axis, colour with intensity/50 in
/// `.w`, and (outer cos, smoothstep upper edge, point reach, kind 0 spot / 1 point / 2 infinite).
struct RenderLightGPU: BitwiseCopyable { var pos: SIMD4<Float>; var dir: SIMD4<Float>; var color: SIMD4<Float>; var extra: SIMD4<Float> }

// MARK: Fibers

/// Filter › Render › Fibers: vertical fibrous streaks between the foreground and background
/// colours (straight sRGB RGBA). Variance 1…64 sets how quickly the colour varies across fibres
/// (and how short they are); strength 1…64 stretches each fibre vertically. Output is opaque.
public struct Fibers: Filter, Hashable {
    public var variance: Float
    public var strength: Float
    public var seed: UInt32
    public var foreground: SIMD4<Float>
    public var background: SIMD4<Float>

    public init(variance: Float = 16, strength: Float = 4, seed: UInt32 = 0,
                foreground: SIMD4<Float> = SIMD4(0, 0, 0, 1), background: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        self.variance = variance; self.strength = strength; self.seed = seed; self.foreground = foreground; self.background = background
    }

    public var label: String { "Fibers" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }

    /// (variance, horizontal frequency, vertical frequency).
    var frequencies: (Float, Float, Float) {
        let v = clampf(variance, 1, 64), st = clampf(strength, 1, 64)
        let fx = 0.08 + v / 64 * 0.6
        let fy = fx / (2 + st * 1.5) * (0.5 + v / 32)
        return (v, fx, fy)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let (v, fx, fy) = frequencies
        let fg = foreground, bg = background, seed = self.seed
        var res = src.crop(out)
        RenderKit.forEachPixel(&res) { x, y, px in
            let xf = Float(x), yf = Float(y)
            var sum: Float = 0, amp: Float = 1, norm: Float = 0
            var ax = fx, ay = fy
            for o: UInt32 in 0..<4 {
                sum += RenderKit.valueNoise(xf * ax, yf * ay, seed &+ o &* 977) * amp
                norm += amp
                amp *= 0.55
                ax *= 2
                ay *= 2
            }
            // Fine per-column grain gives the hairline texture.
            let grain = RenderKit.valueNoise(xf * 0.9, yf * fy * 0.25, seed ^ 0x5bd1) - 0.5
            let t = clampf((sum / norm - 0.5) * (1.6 + v / 40) + 0.5 + grain * 0.25, 0, 1)
            let c = SIMD4<Float>(fg.x + (bg.x - fg.x) * t, fg.y + (bg.y - fg.y) * t, fg.z + (bg.z - fg.z) * t, 1)
            ctx.setRGBA(px, c)
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (v, fx, fy) = frequencies
        try pass.dispatchOut("pca_ren_fibers", params: RenderFibersGPU(fg: foreground, bg: background, fx: fx, fy: fy, variance: v, seed: seed))
    }
}

// MARK: Lens Flare

/// Filter › Render › Lens Flare: an additive (screen) glow, rays, halo ring and ghost discs along
/// the line through the image centre. Brightness 10…300 %; centre as a fraction of the bounds.
public struct LensFlare: Filter, Hashable {
    public var brightness: Float
    public var centerX: Float
    public var centerY: Float
    public var lens: LensType

    public init(brightness: Float = 100, centerX: Float = 0.5, centerY: Float = 0.5, lens: LensType = .zoom) {
        self.brightness = brightness; self.centerX = centerX; self.centerY = centerY; self.lens = lens
    }

    public var label: String { "Lens Flare" }
    public func halo(bounds: PixelRect) -> Halo { .radius(0) }
    public var gpuChannels: GPUChannels { .joint }

    /// photocraft's `Ghost` table (t along the flare→centre axis, radius, tint, strength).
    static func ghosts(_ lens: LensType) -> [(t: Float, r: Float, tint: SIMD3<Float>, k: Float)] {
        switch lens {
        case .zoom: [(0.35, 10, SIMD3(0.6, 0.8, 1.0), 0.18), (0.6, 26, SIMD3(0.5, 1.0, 0.6), 0.10), (0.85, 6, SIMD3(1.0, 0.7, 0.4), 0.25),
                     (1.25, 40, SIMD3(0.7, 0.5, 1.0), 0.08), (1.5, 16, SIMD3(1.0, 0.6, 0.5), 0.15), (1.9, 70, SIMD3(0.5, 0.7, 1.0), 0.06)]
        case .prime35: [(0.7, 18, SIMD3(0.6, 1.0, 0.7), 0.12), (1.4, 30, SIMD3(1.0, 0.7, 0.5), 0.09)]
        case .prime105: [(0.5, 14, SIMD3(1.0, 0.8, 0.5), 0.12), (1.6, 50, SIMD3(0.6, 0.7, 1.0), 0.07)]
        case .moviePrime: [(0.4, 8, SIMD3(0.5, 0.7, 1.0), 0.2), (1.0, 20, SIMD3(0.4, 0.6, 1.0), 0.12), (1.6, 12, SIMD3(0.5, 0.8, 1.0), 0.16)]
        }
    }

    /// The pixel-independent part: uniforms and the ghosts placed along the axis.
    func prepare(_ b: PixelRect) -> (RenderFlareGPU, [RenderGhostGPU]) {
        let bw = Float(b.width), bh = Float(b.height)
        let diag = Float.maximum(hypotf(bw, bh), 1)
        let cx = Float(b.x0) + centerX * bw, cy = Float(b.y0) + centerY * bh
        let mx = Float(b.x0) + bw / 2, my = Float(b.y0) + bh / 2
        let bright = clampf(brightness, 10, 300) / 100
        let s = diag / 1000
        let (core, glow, ringR, ringW, rays, streak): (Float, Float, Float, Float, Float, Float) = switch lens {
        case .zoom: (14, 90, 0, 0, 0.5, 0)
        case .prime35: (12, 70, 90, 6, 0.3, 0)
        case .prime105: (22, 130, 0, 0, 0.8, 0)
        case .moviePrime: (10, 60, 0, 0, 0.2, 1)
        }
        let gs = LensFlare.ghosts(lens).map { g in
            RenderGhostGPU(pos: SIMD4(cx + (mx - cx) * g.t * 2, cy + (my - cy) * g.t * 2, g.r * s, g.k), tint: SIMD4(g.tint, 0))
        }
        return (RenderFlareGPU(c: SIMD2(cx, cy), s: s, bright: bright, core: core, glow: glow, ringR: ringR, ringW: ringW,
                               rays: rays, streak: streak, ghosts: UInt32(gs.count)), gs)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let (p, ghosts) = prepare(ctx.bounds)
        let (cx, cy, s) = (p.c.x, p.c.y, p.s)
        var res = src.crop(out)
        RenderKit.forEachPixel(&res) { x, y, px in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            let dx = fx - cx, dy = fy - cy
            let d = (dx * dx + dy * dy).squareRoot()
            var f = SIMD3<Float>(0, 0, 0)
            // Hot core and wide glow (warm white).
            let q = d / (p.core * s)
            let g = expf(-(q * q)) + 0.35 * expf(-d / (p.glow * s))
            f.x += g * 1.0; f.y += g * 0.95; f.z += g * 0.85
            // Rays: angular modulation decaying with distance.
            if p.rays > 0 {
                let th = atan2f(dy, dx)
                let m = RenderKit.powi(sinf(th * 12) * 0.5 + 0.5, 8) + RenderKit.powi(sinf(th * 7 + 1.3) * 0.5 + 0.5, 12) * 0.6
                let rr = p.rays * m * expf(-d / (p.glow * 1.6 * s))
                f += SIMD3(repeating: rr * 0.6)
            }
            // Anamorphic horizontal streak (movie prime).
            if p.streak > 0 {
                let st = expf(-(abs(dy) / (2.5 * s))) * expf(-(abs(dx) / (450 * s)))
                f.x += st * 0.5; f.y += st * 0.7; f.z += st
            }
            // Halo ring with a slight chromatic spread.
            if p.ringR > 0 {
                for (k, off) in [Float(1.04), 1.0, 0.96].enumerated() {
                    let rd = (d - p.ringR * s * off) / (p.ringW * s)
                    f[k] += 0.18 * expf(-rd * rd)
                }
            }
            // Ghosts along the axis through the centre.
            for gh in ghosts {
                let ex = fx - gh.pos.x, ey = fy - gh.pos.y
                let gd = (ex * ex + ey * ey).squareRoot() / gh.pos.z
                if gd < 1.2 {
                    // photocraft's smoothstep(1, 0.85, gd) is a step at 0.85 (e1 ≤ e0): a ring 0.85…1.2.
                    let e = smoothstep(1.0, 0.85, gd) * (0.6 + 0.4 * gd)
                    f.x += e * gh.pos.w * gh.tint.x; f.y += e * gh.pos.w * gh.tint.y; f.z += e * gh.pos.w * gh.tint.z
                }
            }
            var c = ctx.rgba(UnsafeBufferPointer(px))
            for k in 0..<3 {
                let a = Float.maximum(f[k] * p.bright, 0)
                // Screen keeps highlights below white for display-referred values.
                c[k] = 1 - (1 - c[k]) * (1 - Float.minimum(a, 1))
            }
            ctx.setRGBA(px, c)
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (p, ghosts) = prepare(pass.ctx.bounds)
        try pass.dispatchOut("pca_ren_lens_flare", params: p, buffers: [try pass.buffer(ghosts)])
    }
}

// MARK: Lighting Effects

/// Filter › Render › Lighting Effects: Blinn–Phong shading of the image as a surface (bumped by
/// a texture channel) under spot, point and infinite lights. Gloss/metallic/exposure/ambience
/// −100…100; bump height 0…100.
public struct LightingEffects: Filter, Hashable {
    public var lights: [Light]
    public var gloss: Float
    public var metallic: Float
    public var exposure: Float
    public var ambience: Float
    public var texture: TextureChannel
    public var height: Float
    public var whiteIsHigh: Bool

    public init(lights: [Light] = [Light()], gloss: Float = 0, metallic: Float = 0, exposure: Float = 0, ambience: Float = 8,
                texture: TextureChannel = .none, height: Float = 50, whiteIsHigh: Bool = true) {
        self.lights = lights; self.gloss = gloss; self.metallic = metallic; self.exposure = exposure; self.ambience = ambience
        self.texture = texture; self.height = height; self.whiteIsHigh = whiteIsHigh
    }

    public var label: String { "Lighting Effects" }
    public func halo(bounds: PixelRect) -> Halo { .reach(1) }
    public var gpuChannels: GPUChannels { .joint }

    /// Uniforms and the per-light constants for the bounds `b`.
    func prepare(_ b: PixelRect) -> (RenderLightingGPU, [RenderLightGPU]) {
        let bw = Float(b.width), bh = Float(b.height)
        let short = Float.maximum(min(bw, bh), 1)
        let g = clampf(gloss, -100, 100)
        let p = RenderLightingGPU(
            ambient: clampf(ambience, -100, 100) / 100 * 0.5, shininess: powf(2, 1 + (g + 100) / 200 * 7), specK: (g + 100) / 200 * 0.7,
            metal: (clampf(metallic, -100, 100) + 100) / 200, expo: powf(2, clampf(exposure, -100, 100) / 50),
            hscale: clampf(height, 0, 100) / 100 * 0.06 * short,
            texture: UInt32(TextureChannel.allCases.firstIndex(of: texture)!), whiteIsHigh: whiteIsHigh ? 1 : 0, lights: UInt32(lights.count))
        let ls = lights.map { l -> RenderLightGPU in
            let lpos = SIMD3(Float(b.x0) + l.x * bw, Float(b.y0) + l.y * bh, l.z * short)
            var dir = SIMD3<Float>(0, 0, 0)
            var extra = SIMD4<Float>(0, 0, 0, 0)
            switch l.kind {
            case .infinite:
                let a = DistortKit.radians(l.angle)
                let s = sinf(a), co = cosf(a)
                let e = DistortKit.radians(clampf(l.elevation, 0, 90))
                dir = RenderKit.norm3(SIMD3(co * cosf(e), -s * cosf(e), sinf(e)))
                extra.w = 2
            case .point:
                extra.z = Float.maximum(l.radius * short, 1)
                extra.w = 1
            case .spot:
                let tgt = SIMD3(Float(b.x0) + l.targetX * bw, Float(b.y0) + l.targetY * bh, 0)
                dir = RenderKit.norm3(SIMD3(tgt.x - lpos.x, tgt.y - lpos.y, tgt.z - lpos.z))
                let cone = clampf(l.cone, 1, 89)
                let outer = cosf(DistortKit.radians(cone))
                let inner = cosf(DistortKit.radians(cone * (clampf(l.hotspot, 0, 100) / 100)))
                extra.x = outer
                extra.y = Float.maximum(inner, outer + 1e-4)
                extra.w = 0
            }
            return RenderLightGPU(pos: SIMD4(lpos, 0), dir: SIMD4(dir, 0), color: SIMD4(l.color, clampf(l.intensity, -100, 100) / 50), extra: extra)
        }
        return (p, ls)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let b = ctx.bounds
        let (p, ls) = prepare(b)
        let n = src.channels, tex = texture, whiteIsHigh = self.whiteIsHigh
        let bump = !(texture == .none || p.hscale <= 0)
        /// photocraft's `tex` closure: the texture value at (x, y) clamped to the bounds.
        func texAt(_ x: Int32, _ y: Int32, _ tmp: UnsafeMutableBufferPointer<Float>) -> Float {
            let xx = min(max(x, b.x0), b.x1 - 1), yy = min(max(y, b.y0), b.y1 - 1)
            for c in 0..<n { tmp[c] = src.get(xx, yy, c) }
            let t = UnsafeBufferPointer(tmp)
            let v: Float
            switch tex {
            case .none: v = 0
            case .alpha: v = ctx.alpha ? tmp[n - 1] : 1
            case .luminance: v = ctx.luma(t)
            case .red, .green, .blue:
                let k = tex == .red ? 0 : tex == .green ? 1 : 2
                v = ctx.mode == .rgb ? tmp[k] : ctx.rgba(t)[k]
            }
            return whiteIsHigh ? v : 1 - v
        }
        var res = src.crop(out)
        RenderKit.forEachPixel(&res) { x, y, px in
            let fx = Float(x) + 0.5, fy = Float(y) + 0.5
            var nrm = SIMD3<Float>(0, 0, 1)
            if bump {
                withUnsafeTemporaryAllocation(of: Float.self, capacity: max(n, 1)) { tmp in
                    let hx = (texAt(x + 1, y, tmp) - texAt(x - 1, y, tmp)) * 0.5 * p.hscale
                    let hy = (texAt(x, y + 1, tmp) - texAt(x, y - 1, tmp)) * 0.5 * p.hscale
                    nrm = RenderKit.norm3(SIMD3(-hx, -hy, 1))
                }
            }
            var c = ctx.rgba(UnsafeBufferPointer(px))
            let base = SIMD3(c.x, c.y, c.z)
            var lit = SIMD3<Float>(repeating: p.ambient)
            var spc = SIMD3<Float>(0, 0, 0)
            for l in ls {
                let ldir: SIMD3<Float>, atten: Float
                switch l.extra.w {
                case 2:
                    (ldir, atten) = (SIMD3(l.dir.x, l.dir.y, l.dir.z), 1)
                case 1:
                    let v = SIMD3(l.pos.x - fx, l.pos.y - fy, l.pos.z)
                    let dist = (v.x * v.x + v.y * v.y).squareRoot()
                    (ldir, atten) = (RenderKit.norm3(v), RenderKit.powi(clampf(1 - dist / l.extra.z, 0, 1), 2))
                default:
                    let ld = RenderKit.norm3(SIMD3(l.pos.x - fx, l.pos.y - fy, l.pos.z))
                    let cosang = -RenderKit.dot3(ld, SIMD3(l.dir.x, l.dir.y, l.dir.z))
                    (ldir, atten) = (ld, smoothstep(l.extra.x, l.extra.y, cosang))
                }
                if atten <= 0 { continue }
                let inten = l.color.w * atten
                let ndl = Float.maximum(RenderKit.dot3(nrm, ldir), 0)
                let hv = RenderKit.norm3(SIMD3(ldir.x, ldir.y, ldir.z + 1))
                let s = powf(Float.maximum(RenderKit.dot3(nrm, hv), 0), p.shininess) * p.specK
                for k in 0..<3 {
                    lit[k] += ndl * inten * l.color[k]
                    // Metallic highlights take the surface colour; plastic ones the light's.
                    let sc = l.color[k] * (1 - p.metal) + base[k] * p.metal
                    spc[k] += s * Float.maximum(inten, 0) * sc
                }
            }
            for k in 0..<3 { c[k] = Float.maximum((base[k] * lit[k] + spc[k]) * p.expo, 0) }
            ctx.setRGBA(px, c)
        }
        return res
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (p, ls) = prepare(pass.ctx.bounds)
        try pass.dispatchOut("pca_ren_lighting", params: p, buffers: [try pass.buffer(ls)])
    }
}
