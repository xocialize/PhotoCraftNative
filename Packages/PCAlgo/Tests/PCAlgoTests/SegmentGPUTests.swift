// Port of photocraft-algo (crates/algo/src/segment/slic.rs, segment/gmm.rs, segment/focus.rs, matting.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// CPU vs Metal parity of the segment area's kernels (Shaders/Segment.metal), and opt-in timings.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum SegGPU {
    /// A textured scene: the disc scene plus a gradient so every kernel sees varied input.
    static func scene(_ w: Int, _ h: Int, seed: UInt64 = 4) -> SegmentRGBImage {
        let (disc, _) = SegTest.discScene(w, h, Float(w) * 0.45, Float(h) * 0.55, Float(min(w, h)) * 0.3, seed: seed)
        var img = disc
        for y in 0..<h {
            for x in 0..<w {
                let p = img.px[y * w + x]
                let g = Float(x) / Float(w) * 0.2
                img.px[y * w + x] = SIMD3(clampf(p.x + g, 0, 1), p.y, clampf(p.z - g, 0, 1))
            }
        }
        return img
    }

    static func maxDiff(_ a: [Float], _ b: [Float]) -> Float { SelGPU.maxDiff(a, b) }
}

@Suite(.enabled(if: AlgoGPU.isAvailable)) struct SegmentGPUTests {
    @Test func slicAssignmentIsExact() throws {
        var worst = 0
        for (w, h, target, compact) in [(120, 120, 64, Float(10)), (173, 97, 200, 20), (301, 211, 900, 5), (64, 400, 37, 40)] {
            let img = SegGPU.scene(w, h, seed: UInt64(w))
            let c = try SLIC.slic(img, target: target, compactness: compact, iters: 10, on: .cpu)
            let g = try SLIC.slic(img, target: target, compactness: compact, iters: 10, on: .gpu)
            let diff = zip(c.labels, g.labels).filter { $0 != $1 }.count
            #expect(c.count == g.count && diff == 0, "\(w)x\(h) target \(target): \(diff) labels differ, counts \(c.count) vs \(g.count)")
            worst = max(worst, diff)
        }
        ParityLog.record("segment SLIC labels (differing)", Float(worst))
    }

    @Test func boxMeanParity() throws {
        var worst: Float = 0
        for (w, h, r) in [(13, 9, 2), (300, 200, 1), (300, 200, 17), (1031, 61, 300), (7, 500, 3)] {
            var rng = SegmentKit.Rng(UInt64(w * h))
            let src = (0..<(w * h)).map { _ in rng.f32() * 4 - 1 }
            let c = Matting.boxMean(src, w: w, h: h, r: r)
            let g = try SegmentKit.GPU.boxMean(src, w: w, h: h, r: r)
            let e = SegGPU.maxDiff(c, g)
            #expect(e < 2e-6, "\(w)x\(h) r=\(r): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("segment box mean", worst)
    }

    @Test func guidedFilterColorParity() throws {
        var worst: Float = 0
        for (w, h, r, eps) in [(120, 90, 4, Float(1e-4)), (257, 131, 10, 1e-2), (64, 300, 2, 1e-3)] {
            let img = SegGPU.scene(w, h)
            let p: [Float] = (0..<(w * h)).map { i in
                let x = i % w, y = i / w
                return (x - w / 2) * (x - w / 2) + (y - h / 2) * (y - h / 2) < (min(w, h) / 3) * (min(w, h) / 3) ? 1 : 0
            }
            let c = try Matting.guidedFilterColor(img, p, r: r, eps: eps, on: .cpu)
            let g = try Matting.guidedFilterColor(img, p, r: r, eps: eps, on: .gpu)
            let e = SegGPU.maxDiff(c, g)
            #expect(e < 5e-3, "\(w)x\(h) r=\(r) eps=\(eps): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("segment guided filter (colour)", worst)
    }

    @Test func gmmDataCostParity() throws {
        let img = SegGPU.scene(200, 150)
        var tri = [UInt8](repeating: GrabCut.bg, count: img.w * img.h)
        for y in 20..<130 { for x in 30..<170 { tri[y * img.w + x] = GrabCut.prFG } }
        let (fg, bg) = try #require(GrabCut.grabcut(img, trimap: &tri, iters: 2))
        let (cf, cb) = try Segment.dataCosts(img, fg: fg, bg: bg, on: .cpu)
        let (gf, gb) = try Segment.dataCosts(img, fg: fg, bg: bg, on: .gpu)
        // Costs reach ~200; the GPU evaluates the quadratic forms in Float, the CPU in Double.
        let e = max(SegGPU.maxDiff(cf, gf), SegGPU.maxDiff(cb, gb))
        #expect(e < 2e-3, "\(e)")
        ParityLog.record("segment GMM data costs", e)
    }

    @Test func focusEnergyParity() throws {
        var worst: Float = 0
        for (w, h) in [(160, 100), (333, 241), (90, 700)] {
            let img = SegGPU.scene(w, h)
            let c = try FocusArea.energy(img, on: .cpu)
            let g = try FocusArea.energy(img, on: .gpu)
            let e = SegGPU.maxDiff(c, g)
            #expect(e < 2e-6, "\(w)x\(h): \(e)")
            worst = max(worst, e)
        }
        ParityLog.record("segment focus energy", worst)
    }

    @Test func selectionsAgreeOnEitherBackend() throws {
        // The GPU stages feed the same decisions: the focus mask built on either backend matches.
        var rng = SegmentKit.Rng(12)
        let (w, h) = (160, 100)
        let noise = (0..<(w * h)).map { _ in rng.f32() }
        let blurred = Matting.boxMean(noise, w: w, h: h, r: 4)
        let img = SegmentRGBImage(w: w, h: h) { x, y in
            let v = x < 80 ? noise[y * w + x] : blurred[y * w + x]
            return SIMD3(v, v * 0.8, 0.3)
        }
        let a = try FocusArea.sharpness(img, noise: 0, on: .cpu), b = try FocusArea.sharpness(img, noise: 0, on: .gpu)
        let flips = zip(a, b).filter { ($0 >= 0.5) != ($1 >= 0.5) }.count
        #expect(flips == 0)
    }
}

/// Release timings of the segment kernels (opt-in: `PCALGO_PERF=1 swift test -c release --filter SegmentPerfTests`).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PERF"] != nil && AlgoGPU.isAvailable))
struct SegmentPerfTests {
    @Test func kernels() throws {
        let (w, h) = (1024, 1024)
        let img = SegGPU.scene(w, h)
        let p: [Float] = (0..<(w * h)).map { i in (i % w - w / 2) * (i % w - w / 2) + (i / w - h / 2) * (i / w - h / 2) < 300 * 300 ? 1 : 0 }
        for b in [Backend.cpu, .gpu] {
            try SelectionPerfTests.time("guided filter colour r=8 1 MP \(b)") { _ = try Matting.guidedFilterColor(img, p, r: 8, eps: 1e-4, on: b) }
            try SelectionPerfTests.time("focus energy 1 MP \(b)") { _ = try FocusArea.energy(img, on: b) }
            try SelectionPerfTests.time("SLIC 1 MP 2000 sp \(b)") { _ = try SLIC.slic(img, target: 2000, compactness: 10, iters: 10, on: b) }
        }
        let small = img.downsample(4)
        var triS = [UInt8](repeating: GrabCut.bg, count: small.w * small.h)
        for y in 25..<225 { for x in 25..<225 { triS[y * small.w + x] = GrabCut.prFG } }
        let (fg, bg) = try #require(GrabCut.grabcut(small, trimap: &triS, iters: 2))
        for b in [Backend.cpu, .gpu] {
            try SelectionPerfTests.time("GMM data costs 1 MP \(b)") { _ = try Segment.dataCosts(img, fg: fg, bg: bg, on: b) }
        }
    }
}
