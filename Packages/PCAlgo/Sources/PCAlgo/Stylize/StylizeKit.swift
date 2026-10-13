// Port of photocraft-algo (crates/algo/src/stylize.rs, stylize2.rs, fxutil.rs, pixelate.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Shared helpers of the Stylize / Pixelate area: Rust numeric semantics (saturating `as i32`,
// `div_euclid`, NaN-ignoring `max`, `signum`), an unsafe read view over a FloatImage with
// photocraft `Image::get` semantics, and the luma codes the Metal kernels use to reproduce
// photocraft's two luma functions (`fxutil::luma` and stylize's through-RGB `luma`).

import PCFoundation

enum StylizeKit {
    // MARK: Rust numeric semantics

    /// Rust `v as i32`: truncation toward zero, saturating, NaN → 0.
    @inline(__always)
    static func i32(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        if v >= 2_147_483_648 { return .max }
        if v <= -2_147_483_648 { return .min }
        return Int32(v)
    }

    /// Rust `v as usize`: truncation, negatives and NaN → 0.
    @inline(__always)
    static func usize(_ v: Float) -> Int {
        if !(v > 0) { return 0 }
        if v >= 9.2e18 { return .max }
        return Int(v)
    }

    /// Rust `i32::div_euclid`.
    @inline(__always)
    static func divEuclid(_ a: Int32, _ b: Int32) -> Int32 {
        let q = a / b
        if a % b < 0 { return b > 0 ? q - 1 : q + 1 }
        return q
    }

    /// Rust `f32::max` (a NaN argument yields the other one).
    @inline(__always)
    static func fmax(_ a: Float, _ b: Float) -> Float { Float.maximum(a, b) }

    /// Rust `f32::min` (a NaN argument yields the other one).
    @inline(__always)
    static func fmin(_ a: Float, _ b: Float) -> Float { Float.minimum(a, b) }

    /// Rust `f32::signum`: ±1 by the sign bit (so +0 → 1), NaN → NaN.
    @inline(__always)
    static func signum(_ v: Float) -> Float {
        if v.isNaN { return .nan }
        return v.sign == .minus ? -1 : 1
    }

    /// Rust `f32::to_radians` (Rust's f32 π, not Swift's `Float.pi`, which is one ulp low).
    @inline(__always)
    static func radians(_ deg: Float) -> Float { PCAMath.radians(deg) }

    /// photocraft's `|v| Halo::Radius(v.max(0.0).ceil() as i32 + 1)` (NaN → 0 like Rust's
    /// `max`; capped at `maxCell` so absurd parameters cannot overflow).
    static func reach(_ v: Float) -> Halo { .radius(i32(fmin(fmax(v, 0), maxCell).rounded(.up)) + 1) }

    /// Largest cell / tile size the area works with (keeps cell arithmetic inside Int32; the
    /// dialogs stop far below it).
    static let maxCell: Float = 65_536

    // MARK: Luma codes for the Metal kernels

    /// MSL `pca_sty_luma` code reproducing photocraft `fxutil::luma` for one plane: 0 = `.x`
    /// (gray-like models and Lab's L), 1 = Rec. 601 of `.xyz` (RGB-like). nil for CMYK, whose
    /// luma goes through the managed CMYK conversion (CPU only).
    static func fxLumaCode(_ ctx: FilterContext) -> Int32? {
        if ctx.mode.isGrayLike || ctx.mode == .lab { return 0 }
        if ctx.mode.isRGBLike { return 1 }
        return nil
    }

    /// MSL `pca_sty_luma` code reproducing stylize's `luma` (through sRGB): 2 = gray-like (the
    /// gray replicated to RGB, then Rec. 601), 1 = RGB-like. nil for CMYK and Lab.
    static func rgbLumaCode(_ ctx: FilterContext) -> Int32? {
        if ctx.mode.isGrayLike { return 2 }
        if ctx.mode.isRGBLike { return 1 }
        return nil
    }

    /// Whether every colour channel fits one float4 plane (with alpha in `.w`).
    static func onePlane(_ ctx: FilterContext, channels: Int) -> Bool {
        ctx.colorChannels(channels) <= (ctx.alpha ? 3 : 4)
    }

    /// `supportsGPU` of a filter that needs `fxutil::luma` across all colour channels.
    static func supportsFxLuma(_ ctx: FilterContext, channels: Int) -> Bool {
        fxLumaCode(ctx) != nil && onePlane(ctx, channels: channels)
    }

    /// Channels of the whole image a pass belongs to (colour + alpha).
    static func imageChannels(_ pass: GPUPass) -> Int {
        Int(pass.frame.colorChannels) + (pass.ctx.alpha ? 1 : 0)
    }

    /// `n` image samples per `planeChannels` of the plane (`.w` = alpha when the image has it),
    /// for kernels reading a native colour per plane (Tiles / Pointillize fills).
    static func planeColor(_ native: [Float], pass: GPUPass) -> SIMD4<Float> {
        var v = SIMD4<Float>(repeating: 0)
        for (k, c) in pass.planeChannels.enumerated() where c < native.count { v[k] = native[c] }
        if pass.ctx.alpha, let a = native.last { v[3] = a }
        return v
    }
}

/// A read view over a FloatImage's samples with photocraft `Image::get` semantics (0 outside).
/// Valid only inside the `withUnsafeBufferPointer` scope it was made in.
struct StyView {
    let p: UnsafePointer<Float>
    let rect: PixelRect
    let w: Int
    let n: Int

    init(_ buf: UnsafeBufferPointer<Float>, _ img: FloatImage) {
        p = buf.baseAddress ?? UnsafePointer(bitPattern: 16)!
        rect = img.rect; w = img.rect.width; n = img.channels
    }

    @inline(__always)
    func inside(_ x: Int32, _ y: Int32) -> Bool { x >= rect.x0 && x < rect.x1 && y >= rect.y0 && y < rect.y1 }

    @inline(__always)
    func index(_ x: Int32, _ y: Int32) -> Int { (Int(y - rect.y0) * w + Int(x - rect.x0)) * n }

    @inline(__always)
    func get(_ x: Int32, _ y: Int32, _ c: Int) -> Float {
        inside(x, y) ? p[index(x, y) + c] : 0
    }

    /// All `n` samples of pixel (x, y) into `buf` (0 outside) — photocraft `read_px`.
    @inline(__always)
    func read(_ x: Int32, _ y: Int32, _ buf: UnsafeMutablePointer<Float>) {
        if inside(x, y) {
            let i = index(x, y)
            for c in 0..<n { buf[c] = p[i + c] }
        } else {
            for c in 0..<n { buf[c] = 0 }
        }
    }

    /// photocraft `Image::get_edge`.
    @inline(__always)
    func getEdge(_ x: Int32, _ y: Int32, _ c: Int, _ edge: EdgeMode, _ area: PixelRect) -> Float {
        if area.isEmpty { return 0 }
        if area.contains(x: x, y: y) { return get(x, y, c) }
        switch edge {
        case .transparent: return 0
        case .repeatEdge: return get(min(max(x, area.x0), area.x1 - 1), min(max(y, area.y0), area.y1 - 1), c)
        case .wrap:
            let ww = Int32(max(area.width, 1)), hh = Int32(max(area.height, 1))
            return get(area.x0 + euclidMod(x - area.x0, ww), area.y0 + euclidMod(y - area.y0, hh), c)
        }
    }
}

/// Per-worker scratch pixel buffers (MAXC-sized), freed when the scope ends.
@inline(__always)
func withStyScratch<R>(_ count: Int, _ body: (UnsafeMutableBufferPointer<Float>) -> R) -> R {
    let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(count, 1))
    b.initialize(repeating: 0)
    defer { b.deallocate() }
    return body(b)
}

extension FloatImage {
    /// Mutable access to the samples for parallel writers of disjoint pixels.
    mutating func withStyOut<R>(_ body: (UnsafeSendable<UnsafeMutablePointer<Float>>) -> R) -> R {
        data.withUnsafeMutableBufferPointer { b in
            body(UnsafeSendable(b.baseAddress ?? UnsafeMutablePointer(bitPattern: 16)!))
        }
    }
}
