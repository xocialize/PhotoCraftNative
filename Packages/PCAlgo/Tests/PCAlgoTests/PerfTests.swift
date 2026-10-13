// Port of photocraft-algo's release timings (crates/algo/src/blur.rs `surface_timing`, docs/*-performance.md), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// Release timings at 4096×4096 RGBA (opt-in: `PCALGO_PERF=1 swift test -c release --filter Perf`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil))
struct PerfTests {
    static let size = Int(ProcessInfo.processInfo.environment["PCALGO_PERF_SIZE"] ?? "4096") ?? 4096

    static func time<F: Filter>(_ name: String, _ f: F, cpu: Bool = true) throws {
        let out = PixelRect(x: 0, y: 0, width: size, height: size)
        let srcRect: PixelRect
        switch f.halo(bounds: out) {
        case .bounds: srcRect = out
        case .radius(let r): srcRect = out.outset(by: r)
        }
        let img = TestImage.make(srcRect, channels: 4, alpha: true, seed: 5)
        let ctx = FilterContext(bounds: out, mode: .rgb, alpha: true)
        // Warm-up (pipeline compilation, allocation).
        _ = try FilterEngine.applyMeasured(f, to: img, output: out, context: ctx, on: .gpu)
        var best = (wall: Double.infinity, gpu: Double.infinity)
        for _ in 0..<3 {
            let (_, s) = try FilterEngine.applyMeasured(f, to: img, output: out, context: ctx, on: .gpu)
            best = (min(best.wall, s.wallSeconds), min(best.gpu, s.gpuSeconds))
        }
        var cpuT = Double.nan
        if cpu {
            let (_, s) = try FilterEngine.applyMeasured(f, to: img, output: out, context: ctx, on: .cpu)
            cpuT = s.wallSeconds
        }
        print(String(format: "PERF\t%@\tcpu %.1f ms\tgpu-wall %.1f ms\tgpu-kernels %.1f ms\t(%dx%d RGBA)",
                     name, cpuT * 1000, best.wall * 1000, best.gpu * 1000, size, size))
    }

    @Test func blurs() throws {
        try Self.time("GaussianBlur r2", GaussianBlur(radius: 2))
        try Self.time("GaussianBlur r20", GaussianBlur(radius: 20))
        try Self.time("BoxBlur r50", BoxBlur(radius: 50))
        try Self.time("MotionBlur 30deg d40", MotionBlur(angle: 30, distance: 40))
        try Self.time("RadialBlur spin 10 good", RadialBlur(amount: 10, method: .spin))
        try Self.time("SurfaceBlur r5 t15", SurfaceBlur(radius: 5, threshold: 15))
        try Self.time("ShapeBlur r20 hexagon", ShapeBlur(radius: 20, shape: .hexagon))
        try Self.time("LensBlur r15", LensBlur(radius: 15, brightness: 30, threshold: 200))
        try Self.time("SmartBlur r5 t25", SmartBlur(radius: 5, threshold: 25))
        try Self.time("IrisBlur 15", IrisBlur())
        try Self.time("TiltShift 15", TiltShift())
        try Self.time("SpinBlur 15deg", SpinBlur())
    }

    @Test func sharpenNoiseOther() throws {
        try Self.time("UnsharpMask r3", UnsharpMask(amount: 100, radius: 3, threshold: 0))
        try Self.time("AddNoise gaussian", AddNoise(amount: 25, distribution: .gaussian))
        try Self.time("Median r3", Median(radius: 3))
        try Self.time("Maximum r5 round", Maximum(radius: 5, preserve: .roundness))
        try Self.time("Minimum r10 square", Minimum(radius: 10))
        try Self.time("ReduceNoise default", ReduceNoise())
    }
}
