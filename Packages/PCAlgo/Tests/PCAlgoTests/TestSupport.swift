// Port of photocraft-algo's test helpers (crates/algo/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Deterministic test images: smooth gradients, sinusoids, a hard-edged square, hashed noise and
/// (with alpha) a transparent hole and a soft alpha ramp. 8-bit images hold exact `k / 255`
/// levels; HDR images reach 4.
enum TestImage {
    static func make(_ rect: PixelRect, channels: Int, alpha: Bool, seed: UInt32 = 1, eightBit: Bool = true, hdr: Bool = false) -> FloatImage {
        var img = FloatImage(rect: rect, channels: channels)
        let cc = alpha ? channels - 1 : channels
        for y in rect.y0..<rect.y1 {
            for x in rect.x0..<rect.x1 {
                let i = img.index(x: x, y: y)
                let fx = Float(x), fy = Float(y)
                let square = (x % 37 + 37) % 37 < 18 && (y % 29 + 29) % 29 < 13
                for c in 0..<cc {
                    let phase = Float(c) * 1.7 + Float(seed) * 0.3
                    var v = 0.5 + 0.3 * sinf(fx * 0.11 + phase) * cosf(fy * 0.07 - phase)
                    v += 0.15 * (hash01(x, y, UInt32(c), seed) - 0.5)
                    if square { v = c % 2 == 0 ? v * 0.3 + 0.7 : v * 0.4 }
                    v = min(max(v, 0), 1)
                    if hdr { v *= 1 + 3 * hash01(x / 7, y / 5, UInt32(c) + 9, seed) }
                    if eightBit && !hdr { v = (v * 255).rounded() / 255 }
                    img.data[i + c] = v
                }
                if alpha {
                    var a = min(max(0.6 + 0.4 * sinf(fx * 0.05 + fy * 0.03), 0), 1)
                    let dx = fx - Float(rect.x0) - Float(rect.width) * 0.3, dy = fy - Float(rect.y0) - Float(rect.height) * 0.6
                    if dx * dx + dy * dy < 64 { a = 0 }
                    if (x + 3 * y) % 53 == 0 { a = 0 }
                    if eightBit { a = (a * 255).rounded() / 255 }
                    img.data[i + channels - 1] = a
                }
            }
        }
        return img
    }

    /// A Gray / Gray+A / RGB / RGBA / CMYK+A set of contexts with images over `rect`.
    static func variants(_ rect: PixelRect, seed: UInt32 = 1) -> [(FloatImage, FilterContext)] {
        let specs: [(Int, ColorMode, Bool)] = [(4, .rgb, true), (3, .rgb, false), (1, .grayscale, false), (2, .grayscale, true), (5, .cmyk, true)]
        return specs.map { ch, mode, a in
            (make(rect, channels: ch, alpha: a, seed: seed), FilterContext(bounds: rect, mode: mode, alpha: a))
        }
    }
}

/// GPU-vs-CPU parity: max absolute difference of premultiplied colour and alpha (colour is
/// meaningless where transparent), `nil` when there is no Metal device.
enum Parity {
    static func maxError(_ a: FloatImage, _ b: FloatImage, alpha: Bool, relative: Bool = false) -> Float {
        precondition(a.rect == b.rect && a.channels == b.channels, "shape mismatch \(a.rect) \(b.rect)")
        let n = a.channels
        var worst: Float = 0
        for i in 0..<a.rect.area {
            let aa: Float = alpha ? a.data[i * n + n - 1] : 1, ba: Float = alpha ? b.data[i * n + n - 1] : 1
            for c in 0..<n {
                let isA = alpha && c == n - 1
                let va = isA ? aa : a.data[i * n + c] * aa, vb = isA ? ba : b.data[i * n + c] * ba
                var d = abs(va - vb)
                if relative { d /= max(1, abs(va)) }
                if d.isNaN { return .infinity }
                worst = max(worst, d)
            }
        }
        return worst
    }

    /// Runs `filter` on the CPU and the GPU and returns the max premultiplied difference.
    @discardableResult
    static func check<F: Filter>(_ filter: F, src: FloatImage, out: PixelRect? = nil, ctx: FilterContext,
                                 tol: Float = 1.0 / 255.0, relative: Bool = false, coverage: [Float]? = nil,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws -> Float? {
        // No Metal device: nothing to compare. A device whose PCAlgo library fails to compile is a
        // failure, not a skip (it would otherwise pass every parity test vacuously).
        guard MetalContext.shared != nil else { return nil }
        _ = try AlgoGPU.shared()
        let o = out ?? src.rect
        let cpu = try FilterEngine.apply(filter, to: src, output: o, context: ctx, coverage: coverage, on: .cpu)
        let gpu = try FilterEngine.apply(filter, to: src, output: o, context: ctx, coverage: coverage, on: .gpu)
        let err = maxError(cpu, gpu, alpha: ctx.alpha, relative: relative)
        #expect(err <= tol, "\(filter.label) \(ctx.mode) \(src.channels)ch: GPU vs CPU max error \(err) > \(tol)", sourceLocation: sourceLocation)
        return err
    }

    /// `check` over the standard channel variants, with the source grown by the halo.
    @discardableResult
    static func checkVariants<F: Filter>(_ filter: F, out: PixelRect = PixelRect(x: 3, y: -2, width: 61, height: 47),
                                         tol: Float = 1.0 / 255.0, seed: UInt32 = 1, skip: Set<Int> = [],
                                         sourceLocation: SourceLocation = #_sourceLocation) throws -> Float {
        var worst: Float = 0
        let bounds = out
        let srcRect: PixelRect
        switch filter.halo(bounds: bounds) {
        case .bounds: srcRect = bounds
        case .radius(let r): srcRect = out.outset(by: r)
        }
        for (img, ctx0) in TestImage.variants(srcRect, seed: seed) where !skip.contains(img.channels) {
            var ctx = ctx0
            ctx.bounds = bounds
            if !filter.supportsGPU(ctx, channels: img.channels) { continue }
            if let e = try check(filter, src: img, out: out, ctx: ctx, tol: tol, sourceLocation: sourceLocation) { worst = max(worst, e) }
        }
        return worst
    }
}

/// Prints parity numbers (`PARITY<TAB>name<TAB>error`) so the PORT-NOTES table can be regenerated
/// from `swift test` output.
enum ParityLog {
    static func record(_ name: String, _ err: Float) {
        print("PARITY\t\(name)\t\(String(format: "%.3g", err))")
    }
}
