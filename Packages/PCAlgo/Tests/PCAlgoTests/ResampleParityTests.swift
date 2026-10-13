// Port of photocraft-algo (crates/algo/src/resample.rs, transform.rs, warp.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// GPU-vs-CPU parity of the geometry area over the Gray / Gray+A / RGB / RGBA / CMYK+A variants.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct ResampleParityTests {
    static let rect = PixelRect(x: 3, y: -2, width: 61, height: 47)
    static let scales: [(Double, Double)] = [(2, 2), (0.5, 0.5), (1.37, 0.71), (0.71, 1.37), (0.3, 1), (1, 3.3), (0.13, 0.17), (1, 1)]

    @Test(arguments: Resample.allCases)
    func resizeParity(_ filter: Resample) throws {
        var worst: Float = 0
        for (k, (sx, sy)) in Self.scales.enumerated() {
            let canvas: PixelRect? = k % 2 == 0 ? Self.rect : nil
            let e = try RS.variants(Self.rect) { img, ctx, b in
                try Resample.resize(img, sx: sx, sy: sy, filter: filter, canvas: canvas, context: ctx, on: b)
            }
            guard let e else { return }
            #expect(e <= 1.0 / 255.0, "\(filter) \(sx)×\(sy): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("Resample.\(filter.rawValue)", worst)
    }

    /// A non-zero default pixel (a mask's "reveal all", a coloured background around a layer) and
    /// HDR values above 1.
    @Test func resizeParityDefaultPixelAndHDR() throws {
        var worst: Float = 0
        for filter in [Resample.bilinear, .bicubic, .bicubicAutomatic, .lanczos] {
            for (sx, sy) in [(1.6, 0.45), (0.2, 2.5)] {
                let e = try RS.variants(Self.rect, hdr: true) { img, ctx, b in
                    let def = (0..<img.channels).map { Float($0 + 1) * 0.2 }
                    return try Resample.resize(img, sx: sx, sy: sy, filter: filter, context: ctx, defaultPixel: def, on: b)
                }
                guard let e else { return }
                #expect(e <= 1.0 / 255.0, "\(filter) \(sx)×\(sy): \(e)")
                worst = max(worst, e)
            }
        }
        ParityLog.record("Resample default pixel + HDR", worst)
    }

    /// Two-pass bicubics stored as 8-bit between the passes. The kernels repeat the CPU's operation
    /// order (no FMA contraction), so the rounded intermediate levels agree and so do the results.
    @Test func resizeParity8BitIntermediate() throws {
        var worst: Float = 0
        for filter in [Resample.bicubic, .bicubicSharper, .bicubicAutomatic] {
            for (sx, sy) in [(1.37, 0.71), (0.4, 0.6)] {
                let e = try RS.variants(Self.rect) { img, ctx, b in
                    try Resample.resize(img, sx: sx, sy: sy, filter: filter, context: ctx, storage: .u8, on: b)
                }
                guard let e else { return }
                #expect(e <= 1.0 / 255.0, "\(filter) \(sx)×\(sy): \(e)")
                worst = max(worst, e)
            }
        }
        ParityLog.record("Resample 8-bit intermediate", worst)
    }

    static func q(_ v: [(Double, Double)]) -> [SIMD2<Double>] { v.map { SIMD2($0.0, $0.1) } }

    static var homographies: [Homography] {
        let r = rect
        let (x0, y0, x1, y1) = (Double(r.x0), Double(r.y0), Double(r.x1), Double(r.y1))
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let a = 0.5236 // ~30°
        let rot = Homography([cos(a), -sin(a), cx - cos(a) * cx + sin(a) * cy, sin(a), cos(a), cy - sin(a) * cx - cos(a) * cy, 0, 0, 1])
        return [
            rot,
            Homography.rectToQuad([x0, y0, x1, y1], q([(x0 + 10, y0 - 4), (x1 + 20, y0 + 6), (x1 - 3, y1 + 9), (x0 - 6, y1 - 2)]))!,
            Homography([1.7, 0, 0.3, 0, 1.7, -0.6, 0, 0, 1]),
            Homography([0.31, 0.02, 4, -0.03, 0.29, 1, 0, 0, 1]),
            Homography([1, 0, 0.37, 0, 1, -2.61, 0, 0, 1]),
            Homography([0, -1, 0, 1, 0, 0, 0, 0, 1]),
        ]
    }

    @Test(arguments: Interp.allCases)
    func warpParity(_ interp: Interp) throws {
        var worst: Float = 0
        for (i, h) in Self.homographies.enumerated() {
            let e = try RS.variants(Self.rect) { img, ctx, b in
                try Transform.warp(img, h: h, interp: interp, context: ctx, on: b)
            }
            guard let e else { return }
            #expect(e <= 1.0 / 255.0, "\(interp) h\(i): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("Transform.warp \(interp.rawValue)", worst)
    }

    static var maps: [(Double, Double) -> (Double, Double)] {
        let r = rect
        let w = Double(r.width), h = Double(r.height)
        return [
            { x, y in (x, y) },
            { x, y in (x + 3 * sin(y * 0.2), y + 2 * cos(x * 0.15)) },
            { x, y in (0.22 * x + 0.03 * y + 5, 0.19 * y + 0.02 * x * sin(y * 0.1)) },
            { x, y in
                let u = (x - Double(r.x0)) / w - 0.5, v = (y - Double(r.y0)) / h
                return (x * 1.4 + 9 * u * (1 - v), y * 0.8 - 6 * (1 - 4 * u * u) * (1 - v))
            },
        ]
    }

    @Test(arguments: Interp.allCases)
    func meshParity(_ interp: Interp) throws {
        var worst: Float = 0
        for (i, map) in Self.maps.enumerated() {
            let e = try RS.variants(Self.rect) { img, ctx, b in
                try MeshWarp.warpMesh(img, map: map, interp: interp, context: ctx, on: b)
            }
            guard let e else { return }
            #expect(e <= 1.0 / 255.0, "\(interp) map\(i): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("MeshWarp \(interp.rawValue)", worst)
    }

    @Test func unsharpParity() throws {
        var worst: Float = 0
        for (r, t) in [(Float(1.2), Float(0)), (3, 10), (0.6, 0)] {
            worst = max(worst, try Parity.checkVariants(ResampleKit.Unsharp(amount: 30, radius: r, threshold: t)))
        }
        ParityLog.record("Preserve Details unsharp", worst)
    }
}

/// Release timings at 4096² RGBA (`PCALGO_PERF=1 swift test -c release --filter ResamplePerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct ResamplePerfTests {
    static func time(_ name: String, _ run: (Backend) throws -> FloatImage) throws {
        _ = try run(.gpu)
        var gpu = Double.infinity
        for _ in 0..<3 {
            let t0 = Date()
            _ = try run(.gpu)
            gpu = min(gpu, Date().timeIntervalSince(t0))
        }
        let t0 = Date()
        _ = try run(.cpu)
        let cpu = Date().timeIntervalSince(t0)
        print(String(format: "PERF\t%@\tcpu %.1f ms\tgpu-wall %.1f ms", name, cpu * 1000, gpu * 1000))
    }

    @Test func geometry() throws {
        let n = PerfTests.size
        let rect = PixelRect(x: 0, y: 0, width: n, height: n)
        let img = TestImage.make(rect, channels: 4, alpha: true, seed: 5)
        let ctx = FilterContext(bounds: rect, mode: .rgb, alpha: true)
        try Self.time("Resample bicubic ×0.5") { try Resample.resize(img, sx: 0.5, sy: 0.5, filter: .bicubic, context: ctx, on: $0) }
        try Self.time("Resample lanczos ×1.5") { try Resample.resize(img, sx: 1.5, sy: 1.5, filter: .lanczos, context: ctx, on: $0) }
        let a = 0.3, c = Double(n) / 2
        let rot = Homography([cos(a), -sin(a), c - cos(a) * c + sin(a) * c, sin(a), cos(a), c - sin(a) * c - cos(a) * c, 0, 0, 1])
        try Self.time("Transform bicubic rotate") { try Transform.warp(img, h: rot, interp: .bicubic, context: ctx, on: $0) }
        try Self.time("MeshWarp bilinear wave") {
            try MeshWarp.warpMesh(img, map: { x, y in (x + 6 * sin(y * 0.01), y + 6 * cos(x * 0.01)) }, interp: .bilinear, context: ctx, on: $0)
        }
        try Self.time("MeshWarp bicubic ×0.3 bend (subsampled)") {
            try MeshWarp.warpMesh(img, map: { x, y in (0.3 * x + 20 * sin(y * 0.002), 0.3 * y) }, interp: .bicubic, context: ctx, on: $0)
        }
        var field = LiquifyField(bounds: rect, cell: Liquify.autoCell(rect))
        field.applyStroke(LiquifyStroke(tool: .forwardWarp, size: 1200, points: [[1000, 1000], [3000, 2600]]))
        try Self.time("Liquify forward warp") { try Liquify.apply(img, field: field, context: ctx, on: $0) }
    }
}
