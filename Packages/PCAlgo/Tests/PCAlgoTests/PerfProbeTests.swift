// Port of photocraft-algo (crates/algo/src/blur.rs, gallery.rs box cascades), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Opt-in GPU micro-benchmarks of the box-pass machinery (`PCALGO_PROBE=1 swift test -c release --filter PerfProbe`):
// they chose `GPUPass.directBoxRadius` (row passes with radius ≤ 4 sum directly).

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

/// N clamped box passes along one axis.
struct AxisProbe: Filter {
    var axis: Int32
    var passes: Int
    var radius: Int32
    var label: String { "axis probe" }
    func halo(bounds: PixelRect) -> Halo { .radius(0) }
    func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { src.crop(out) }
    func encodeGPU(_ pass: GPUPass) throws {
        var a = try pass.texture(pass.out), b = try pass.texture(pass.out)
        try pass.dispatchOut("pca_copy", params: NoParams(), textures: [pass.src, a])
        for _ in 0..<passes { try pass.encodeClampedBox(input: a, output: b, rect: pass.out, radius: radius, axis: axis); swap(&a, &b) }
        try pass.copy(a, size: (pass.out.width, pass.out.height), to: pass.dst)
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PCALGO_PROBE"] != nil))
struct PerfProbeTests {
    @Test func axes() throws {
        for (axis, passes, r) in [(Int32(0), 0, Int32(8)), (0, 6, 2), (0, 6, 3), (0, 6, 4), (0, 6, 6), (0, 6, 8), (0, 6, 12)] {
            try PerfTests.time("axis \(axis) x\(passes) r\(r)", AxisProbe(axis: axis, passes: passes, radius: r), cpu: false)
        }
    }
}

/// The Gaussian levels of the gallery's variable blur.
struct LevelsProbe: Filter {
    var levels: Int
    var label: String { "levels probe" }
    func halo(bounds: PixelRect) -> Halo { .radius(0) }
    func cpu(_ src: FloatImage, out: PixelRect, ctx: FilterContext) -> FloatImage { src.crop(out) }
    func encodeGPU(_ pass: GPUPass) throws {
        let p = try pass.texture(pass.out)
        try pass.dispatchOut("pca_copy", params: NoParams(), textures: [pass.src, p])
        let lv = GalleryKit.levelSigmas(9)
        var last = p
        for k in 1...levels {
            let l = try pass.encodeGaussBlurN(p, rect: pass.out, sigma: lv[k])
            if last !== p { pass.recycle(last) }
            last = l
        }
        try pass.copy(last, size: (pass.out.width, pass.out.height), to: pass.dst)
    }
}

extension PerfProbeTests {
    @Test func levels() throws {
        for n in [1, 3, 6] { try PerfTests.time("levels \(n)", LevelsProbe(levels: n), cpu: false) }
    }
}
