// Port of photocraft-algo (crates/algo/src/distort.rs, lib.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Filter › Distort, first batch: Twirl, Pinch, Spherize, Wave, Ripple, Polar Coordinates. All
// are inverse mappings centred on the reference bounds (`Halo.bounds`) through
// `DistortKit.remap`; the Metal kernels (Shaders/Distort.metal) evaluate the same map per output
// pixel and sample with `pca_sample`. Constants that don't depend on the pixel (centre, radians,
// wave generators) are computed once in Swift and handed to the GPU, so both sides use identical
// values.

import Foundation
import PCFoundation

// MARK: Option enums

/// Spherize mode (photocraft `SpherizeMode`).
public enum SpherizeMode: String, Codable, Sendable, Hashable, CaseIterable {
    case normal, horizontalOnly, verticalOnly
}

/// Wave shape (photocraft `WaveType`).
public enum WaveType: String, Codable, Sendable, Hashable, CaseIterable {
    case sine, triangle, square
}

/// Ripple size (photocraft `RippleSize`).
public enum RippleSize: String, Codable, Sendable, Hashable, CaseIterable {
    case small, medium, large
}

/// Polar Coordinates direction (photocraft `PolarMode`).
public enum PolarMode: String, Codable, Sendable, Hashable, CaseIterable {
    case rectangularToPolar, polarToRectangular
}

// MARK: GPU uniforms (mirrored by the MSL structs in Distort.metal)

struct DistortTwirlGPU: BitwiseCopyable { var c: SIMD2<Float>; var rr: Float; var a: Float }
struct DistortSpherizeGPU: BitwiseCopyable {
    var c: SIMD2<Float>; var h: SIMD2<Float>; var rr: Float; var a: Float; var mode: UInt32; var pad0: Int32 = 0
}
struct DistortWaveGPU: BitwiseCopyable { var b0: SIMD2<Float>; var ngen: UInt32; var type: UInt32; var edge: UInt32; var nf: Float; var pad0: Int32 = 0; var pad1: Int32 = 0 }
struct DistortRippleGPU: BitwiseCopyable { var b0: SIMD2<Float>; var amp: Float; var len: Float }
struct DistortPolarGPU: BitwiseCopyable {
    var b0: SIMD2<Float>; var wh: SIMD2<Float>; var c: SIMD2<Float>; var rmax: Float; var mode: UInt32
}

// MARK: Twirl

/// Filter › Distort › Twirl: rotation that falls off linearly to zero at the bounds' inscribed
/// circle. `angle` −999…999°.
public struct Twirl: Filter, Hashable {
    public var angle: Float
    public init(angle: Float = 50) { self.angle = angle }
    public var label: String { "Twirl" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let (cx, cy, rr) = DistortKit.centre(ctx.bounds)
        let a = DistortKit.radians(angle)
        return DistortKit.remap(src, out, ctx, .repeatEdge) { x, y in
            let dx = x - cx, dy = y - cy
            let r = (dx * dx + dy * dy).squareRoot()
            if r >= rr || rr <= 0 { return (x, y) }
            let t = a * (1 - r / rr)
            let s = sinf(t), c = cosf(t)
            return (cx + dx * c - dy * s, cy + dx * s + dy * c)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (cx, cy, rr) = DistortKit.centre(pass.ctx.bounds)
        try pass.dispatchOut("pca_dis_twirl", params: DistortTwirlGPU(c: SIMD2(cx, cy), rr: rr, a: DistortKit.radians(angle)))
    }
}

// MARK: Pinch

/// Filter › Distort › Pinch: radial power map inside the inscribed circle. `amount` −100…100 %.
public struct Pinch: Filter, Hashable {
    public var amount: Float
    public init(amount: Float = 50) { self.amount = amount }
    public var label: String { "Pinch" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    var a: Float { clampf(amount / 100, -1, 1) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let (cx, cy, rr) = DistortKit.centre(ctx.bounds)
        let e = 1 - a * 0.5
        return DistortKit.remap(src, out, ctx, .repeatEdge) { x, y in
            let dx = x - cx, dy = y - cy
            let r = (dx * dx + dy * dy).squareRoot()
            if r >= rr || r <= 0 { return (x, y) }
            let rs = rr * powf(r / rr, e)
            return (cx + dx * rs / r, cy + dy * rs / r)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let (cx, cy, rr) = DistortKit.centre(pass.ctx.bounds)
        // `a` carries the exponent 1 − a/2 (computed here as on the CPU).
        try pass.dispatchOut("pca_dis_pinch", params: DistortTwirlGPU(c: SIMD2(cx, cy), rr: rr, a: 1 - a * 0.5))
    }
}

// MARK: Spherize

/// Filter › Distort › Spherize: arcsine (positive, magnify) or sine (negative) radial remap,
/// in both directions or one axis only. `amount` −100…100 %.
public struct Spherize: Filter, Hashable {
    public var amount: Float
    public var mode: SpherizeMode
    public init(amount: Float = 100, mode: SpherizeMode = .normal) { self.amount = amount; self.mode = mode }
    public var label: String { "Spherize" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    /// photocraft `sphere_1d`: `rn` in [0, 1).
    static func sphere1D(_ rn: Float, _ a: Float) -> Float {
        let target = a >= 0 ? asinf(rn) * 2 / DistortKit.pi : sinf(rn * DistortKit.halfPi)
        return rn + abs(a) * (target - rn)
    }

    /// Rust `f32::signum` (±0 → ±1).
    @inline(__always) static func signum(_ v: Float) -> Float { v.isNaN ? .nan : (v.sign == .minus ? -1 : 1) }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let b = ctx.bounds
        let (cx, cy, rr) = DistortKit.centre(b)
        let hx = Float(b.width) / 2, hy = Float(b.height) / 2
        let a = clampf(amount / 100, -1, 1)
        let mode = self.mode
        return DistortKit.remap(src, out, ctx, .repeatEdge) { x, y in
            let dx = x - cx, dy = y - cy
            switch mode {
            case .normal:
                let r = (dx * dx + dy * dy).squareRoot()
                if r >= rr || r <= 0 { return (x, y) }
                let rs = rr * Spherize.sphere1D(r / rr, a)
                return (cx + dx * rs / r, cy + dy * rs / r)
            case .horizontalOnly:
                if abs(dx) >= hx { return (x, y) }
                return (cx + Spherize.signum(dx) * hx * Spherize.sphere1D(abs(dx) / hx, a), y)
            case .verticalOnly:
                if abs(dy) >= hy { return (x, y) }
                return (x, cy + Spherize.signum(dy) * hy * Spherize.sphere1D(abs(dy) / hy, a))
            }
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds
        let (cx, cy, rr) = DistortKit.centre(b)
        let m: UInt32 = switch mode { case .normal: 0; case .horizontalOnly: 1; case .verticalOnly: 2 }
        try pass.dispatchOut("pca_dis_spherize", params: DistortSpherizeGPU(
            c: SIMD2(cx, cy), h: SIMD2(Float(b.width) / 2, Float(b.height) / 2), rr: rr, a: clampf(amount / 100, -1, 1), mode: m))
    }
}

// MARK: Wave

/// Filter › Distort › Wave: the sum of `generators` (1…64) seeded waves with wavelengths and
/// amplitudes drawn between the min and max, displacing x by a wave along y and y by one along
/// x; uncovered areas wrap, repeat or turn transparent.
public struct Wave: Filter, Hashable {
    public var generators: UInt32
    public var wavelengthMin: Float
    public var wavelengthMax: Float
    public var amplitudeMin: Float
    public var amplitudeMax: Float
    public var waveType: WaveType
    public var undefined: UndefinedAreas
    public var seed: UInt32

    public init(generators: UInt32 = 5, wavelengthMin: Float = 10, wavelengthMax: Float = 120, amplitudeMin: Float = 5,
                amplitudeMax: Float = 35, waveType: WaveType = .sine, undefined: UndefinedAreas = .wrap, seed: UInt32 = 0) {
        self.generators = generators; self.wavelengthMin = wavelengthMin; self.wavelengthMax = wavelengthMax
        self.amplitudeMin = amplitudeMin; self.amplitudeMax = amplitudeMax; self.waveType = waveType
        self.undefined = undefined; self.seed = seed
    }

    public var label: String { "Wave" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    /// The generators as (wavelength, amplitude, phase x, phase y), photocraft's `gens`.
    var gens: [SIMD4<Float>] {
        let n = min(max(generators, 1), 64)
        let lerp = { (a: Float, b: Float, t: Float) -> Float in a + Float.maximum(b - a, 0) * t }
        return (0..<n).map { i in
            let r = { (k: Int32) -> Float in hash01(Int32(i), k, 7, seed) }
            return SIMD4(Float.maximum(lerp(wavelengthMin, wavelengthMax, r(1)), 1), lerp(amplitudeMin, amplitudeMax, r(2)),
                         r(3) * DistortKit.tau, r(4) * DistortKit.tau)
        }
    }

    /// photocraft `distort::shape`.
    @inline(__always)
    static func shape(_ t: WaveType, _ phase: Float) -> Float {
        let tau = DistortKit.tau
        let p = euclidMod(phase, tau) / tau
        switch t {
        case .sine: return sinf(phase)
        case .triangle: return 1 - 4 * abs(p - 0.5)
        case .square: return p < 0.5 ? 1 : -1
        }
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let gens = self.gens, type = waveType
        let nf = Float(gens.count)
        let b = ctx.bounds, tau = DistortKit.tau
        return DistortKit.remap(src, out, ctx, undefined.edge) { x, y in
            let lx = x - Float(b.x0), ly = y - Float(b.y0)
            var dx: Float = 0, dy: Float = 0
            for g in gens {
                dx += g.y * Wave.shape(type, tau * ly / g.x + g.z)
                dy += g.y * Wave.shape(type, tau * lx / g.x + g.w)
            }
            return (x + dx / nf, y + dy / nf)
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let g = gens, b = pass.ctx.bounds
        let t: UInt32 = switch waveType { case .sine: 0; case .triangle: 1; case .square: 2 }
        try pass.dispatchOut("pca_dis_wave", params: DistortWaveGPU(b0: SIMD2(Float(b.x0), Float(b.y0)), ngen: UInt32(g.count), type: t,
                                                                  edge: undefined.gpuEdge, nf: Float(g.count)),
                             buffers: [try pass.buffer(g)])
    }
}

// MARK: Ripple

/// Filter › Distort › Ripple: one sine wave each way. `amount` −999…999 %; size sets the
/// wavelength (8, 16, 32 px).
public struct Ripple: Filter, Hashable {
    public var amount: Float
    public var size: RippleSize
    public init(amount: Float = 100, size: RippleSize = .medium) { self.amount = amount; self.size = size }
    public var label: String { "Ripple" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    var len: Float { switch size { case .small: 8; case .medium: 16; case .large: 32 } }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let len = self.len
        let amp = amount / 100 * len / 8
        let b = ctx.bounds, tau = DistortKit.tau
        return DistortKit.remap(src, out, ctx, .repeatEdge) { x, y in
            let lx = x - Float(b.x0), ly = y - Float(b.y0)
            return (x + amp * sinf(tau * ly / len), y + amp * sinf(tau * lx / len))
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        let b = pass.ctx.bounds
        try pass.dispatchOut("pca_dis_ripple", params: DistortRippleGPU(b0: SIMD2(Float(b.x0), Float(b.y0)), amp: amount / 100 * len / 8, len: len))
    }
}

// MARK: Polar Coordinates

/// Filter › Distort › Polar Coordinates: rectangular → polar (angle from 12 o'clock clockwise
/// becomes x, radius y) or back; samples outside the bounds are transparent.
public struct PolarCoordinates: Filter, Hashable {
    public var mode: PolarMode
    public init(mode: PolarMode = .rectangularToPolar) { self.mode = mode }
    public var label: String { "Polar Coordinates" }
    public func halo(bounds: PixelRect) -> Halo { .bounds }

    static func geometry(_ b: PixelRect) -> DistortPolarGPU {
        let w = Float(max(b.width, 1)), h = Float(max(b.height, 1))
        return DistortPolarGPU(b0: SIMD2(Float(b.x0), Float(b.y0)), wh: SIMD2(w, h), c: SIMD2(Float(b.x0) + w / 2, Float(b.y0) + h / 2),
                               rmax: min(w, h) / 2, mode: 0)
    }

    public func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage {
        let g = PolarCoordinates.geometry(ctx.bounds), tau = DistortKit.tau
        let (x0, y0, w, h, cx, cy, rmax) = (g.b0.x, g.b0.y, g.wh.x, g.wh.y, g.c.x, g.c.y, g.rmax)
        switch mode {
        case .rectangularToPolar:
            return DistortKit.remap(src, out, ctx, .transparent) { x, y in
                let dx = x - cx, dy = y - cy
                let theta = euclidMod(atan2f(dx, -dy), tau)
                let r = (dx * dx + dy * dy).squareRoot()
                return (x0 + theta / tau * w, y0 + r / rmax * h)
            }
        case .polarToRectangular:
            return DistortKit.remap(src, out, ctx, .transparent) { x, y in
                let theta = (x - x0) / w * tau
                let r = (y - y0) / h * rmax
                return (cx + r * sinf(theta), cy - r * cosf(theta))
            }
        }
    }

    public func encodeGPU(_ pass: GPUPass) throws {
        var g = PolarCoordinates.geometry(pass.ctx.bounds)
        g.mode = mode == .rectangularToPolar ? 0 : 1
        try pass.dispatchOut("pca_dis_polar", params: g)
    }
}
