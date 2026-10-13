// Port of photocraft-algo (crates/algo/src/tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// photocraft's behavioural tests for the blur / sharpen / noise / other filters, run through the
// Surface-level engine on both backends.

import Foundation
import Testing
@testable import PCAlgo
import PCFoundation

enum Behaviour {
    static let R = PixelRect(x0: 0, y0: 0, x1: 40, y1: 30)

    static func fmt(_ s: SampleType) -> PixelFormat { PixelFormat(mode: .rgb, sample: s, alpha: true) }

    /// photocraft `pattern`.
    static func pattern(_ s: SampleType, _ r: PixelRect) -> Surface {
        var surf = Surface(format: fmt(s))
        var v: [Float] = []
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                v += [Float((x * 7 + y * 3) % 64) / 63, Float((x * x + y) % 50) / 49, Float(y % 9) / 8, 1]
            }
        }
        surf.writeRegion(r, v)
        return surf
    }

    static func flat(_ s: SampleType, _ r: PixelRect, _ px: [Float]) -> Surface {
        var surf = Surface(format: fmt(s))
        surf.fill(r, with: px)
        return surf
    }

    static func run<F: Filter>(_ s: Surface, _ f: F, on b: Backend = .cpu, tile: Int = 256, selection: Surface? = nil, bounds: PixelRect = R) throws -> Surface {
        var out = s
        let area = FilterEngine.outputArea(f, content: s.contentBounds, bounds: bounds)
        try FilterEngine.apply(f, to: &out, area: area, bounds: bounds, selection: selection, on: b, tile: tile)
        return out
    }

    static var backends: [Backend] { AlgoGPU.isAvailable ? [.cpu, .gpu] : [.cpu] }

    /// The lead's filters (photocraft `all_filters` subset plus the second batch's blurs).
    static var filters: [any Filter] {
        [GaussianBlur(radius: 2.5), GaussianBlur(radius: 9), BoxBlur(radius: 2), BoxBlur(radius: 6), MotionBlur(angle: 30, distance: 7),
         RadialBlur(amount: 20, method: .spin), RadialBlur(amount: 30, method: .zoom, centerX: 0.3, centerY: 0.6),
         SurfaceBlur(radius: 3, threshold: 20), UnsharpMask(amount: 150, radius: 1.5, threshold: 2), SmartSharpen(amount: 100, radius: 1, reduceNoise: 20),
         HighPass(radius: 3), AddNoise(amount: 25, distribution: .gaussian, seed: 3), Median(radius: 2), DustAndScratches(radius: 2, threshold: 10),
         Minimum(radius: 1), Maximum(radius: 2), Minimum(radius: 2.5, preserve: .roundness), Maximum(radius: 3, preserve: .roundness),
         Offset(horizontal: 7, vertical: -3, undefined: .wrap), SmartBlur(radius: 4, threshold: 30), LensBlur(radius: 5, noise: 5),
         ShapeBlur(radius: 5, shape: .hexagon), ReduceNoise(), TiltShift(blur: 5), IrisBlur(pins: [IrisPin(blur: 6)]), FieldBlur(),
         SpinBlur(pins: [SpinPin(blurAngle: 40)]), PathBlur(), CustomKernel(kernel: [0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0], scale: 9),
         AverageBlur(), Despeckle(), BlurPreset(.blurMore), SharpenPreset(.sharpenEdges)]
    }
}

@Suite struct BehaviourTests {
    typealias B = Behaviour

    /// photocraft's contract: the CPU reference is bit-identical whatever the tiling. The Metal
    /// path sums in float where photocraft sums some windows in f64 (prefix sums, buffer blurs)
    /// or with running sums whose start follows the tile, so it is tile-independent to float
    /// rounding: measured premultiplied on a float surface (≤ 2e-6 here; an 8-bit write can round 1
    /// level apart; straight colour is meaningless where alpha is ~0).
    @Test func everyFilterIsTileIndependent() throws {
        let s8 = B.pattern(.u8, B.R)
        var s32 = Surface(format: B.fmt(.f32))
        s32.writeRegion(B.R, s8.readRegion(B.R))
        for f in B.filters {
            func go<F: Filter>(_ f: F) throws {
                let area = FilterEngine.outputArea(f, content: s8.contentBounds, bounds: B.R).union(B.R)
                let a = try B.run(s8, f, on: .cpu, tile: 256), t = try B.run(s8, f, on: .cpu, tile: 7)
                #expect(a.readInterleaved(area) == t.readInterleaved(area), "\(f.label) on the CPU differs between tile sizes")
                if AlgoGPU.isAvailable {
                    let ga = FloatImage(rect: area, channels: 4, data: try B.run(s32, f, on: .gpu, tile: 256).readRegion(area))
                    let gt = FloatImage(rect: area, channels: 4, data: try B.run(s32, f, on: .gpu, tile: 7).readRegion(area))
                    let d = Parity.maxError(ga, gt, alpha: true)
                    #expect(d <= 2e-6, "\(f.label) on the GPU differs between tile sizes by \(d)")
                }
            }
            try go(f)
        }
    }

    @Test func everyFilterChangesSomethingAndRespectsZeroSelection() throws {
        let s = B.pattern(.u16, B.R)
        let none = Surface(format: .gray8)
        for f in B.filters {
            func go<F: Filter>(_ f: F) throws {
                let out = try B.run(s, f)
                #expect(out != s, "\(f.label) did nothing")
                let masked = try B.run(s, f, selection: none)
                let area = FilterEngine.outputArea(f, content: s.contentBounds, bounds: B.R)
                #expect(masked.readRegion(area) == s.readRegion(area), "\(f.label) ignored an empty selection")
            }
            try go(f)
        }
    }

    @Test func gaussianIdentityAtTinyRadius() throws {
        let s = B.pattern(.u8, B.R)
        for b in B.backends { #expect(try B.run(s, GaussianBlur(radius: 0.01), on: b).readInterleaved(B.R) == s.readInterleaved(B.R)) }
    }

    @Test func blurPreservesFlatColourAndMass() throws {
        for b in B.backends {
            let s = B.flat(.f32, B.R, [0.3, 0.6, 0.9, 1])
            let p = try B.run(s, GaussianBlur(radius: 3), on: b).pixel(x: 20, y: 15)
            #expect(abs(p[0] - 0.3) < 1e-5 && abs(p[3] - 1) < 1e-5)
            let small = B.flat(.f32, PixelRect(x0: 10, y0: 10, x1: 20, y1: 20), [1, 0, 0, 1])
            for f in [GaussianBlur(radius: 2) as any Filter, BoxBlur(radius: 3)] {
                func go<F: Filter>(_ f: F) throws {
                    let out = try B.run(small, f, on: b)
                    let big = PixelRect(x0: -10, y0: -10, x1: 40, y1: 40)
                    let v = out.readRegion(big)
                    let sum = stride(from: 3, to: v.count, by: 4).reduce(Float(0)) { $0 + v[$1] }
                    #expect(abs(sum - 100) < 0.01, "\(f.label): \(sum)")
                    let edge = out.pixel(x: 9, y: 15)
                    #expect(edge[3] > 0 && abs(edge[0] - 1) < 1e-4, "\(edge)")
                }
                try go(f)
            }
        }
    }

    @Test func blurKeeps16BitPrecision() throws {
        let r = PixelRect(x0: 0, y0: 0, x1: 200, y1: 1)
        var s = Surface(format: B.fmt(.u16))
        s.writeRegion(r, (0..<200).flatMap { [Float($0) / 65535, 0, 0, 1] })
        for b in B.backends {
            var out = s
            try FilterEngine.apply(GaussianBlur(radius: 2), to: &out, area: r, bounds: r, on: b)
            for x in 20..<180 { #expect(Int((out.pixel(x: Int32(x), y: 0)[0] * 65535).rounded()) == x, "x=\(x)") }
        }
    }

    @Test func floatSurfacesKeepHDRValues() throws {
        let s = B.flat(.f32, B.R, [4, 2, 0.5, 1])
        for b in B.backends { #expect(abs(try B.run(s, GaussianBlur(radius: 2), on: b).pixel(x: 20, y: 15)[0] - 4) < 1e-4) }
    }

    @Test func gaussianSigmaMatchesRadius() throws {
        var s = Surface(format: B.fmt(.f32))
        s.setPixel(x: 20, y: 15, [1, 1, 1, 1])
        for b in B.backends {
            var out = s
            try FilterEngine.apply(GaussianBlur(radius: 2), to: &out, area: B.R, bounds: B.R, on: b)
            let a0 = out.pixel(x: 20, y: 15)[3], a2 = out.pixel(x: 22, y: 15)[3]
            #expect(abs(a2 / a0 - expf(-0.5)) < 1e-3)
        }
    }

    @Test func unsharpThresholdAndContrast() throws {
        let s = B.pattern(.f32, B.R)
        for b in B.backends {
            let none = try B.run(s, UnsharpMask(amount: 200, radius: 2, threshold: 255), on: b)
            #expect(none.readRegion(B.R) == s.readRegion(B.R), "threshold 255 disables sharpening")
            let sharp = try B.run(s, UnsharpMask(amount: 200, radius: 2, threshold: 0), on: b)
            func variance(_ surf: Surface) -> Float {
                let v = surf.readRegion(PixelRect(x0: 5, y0: 5, x1: 35, y1: 25))
                let reds = stride(from: 0, to: v.count, by: 4).map { v[$0] }
                let m = reds.reduce(0, +) / Float(reds.count)
                return reds.map { ($0 - m) * ($0 - m) }.reduce(0, +)
            }
            #expect(variance(sharp) > variance(s))
        }
    }

    @Test func noiseIsDeterministicMonochromeAndCentred() throws {
        let s = B.flat(.f32, B.R, [0.5, 0.5, 0.5, 1])
        let f = AddNoise(amount: 50, distribution: .uniform, monochromatic: true, seed: 1)
        for b in B.backends {
            let a = try B.run(s, f, on: b)
            #expect(a == (try B.run(s, f, on: b)))
            let v = a.readRegion(B.R)
            var mean: Float = 0
            for i in stride(from: 0, to: v.count, by: 4) {
                #expect(v[i] == v[i + 1] && v[i + 1] == v[i + 2])
                #expect(abs(v[i] - 0.5) <= 0.25 + 1e-6)
                mean += v[i]
            }
            mean /= Float(v.count / 4)
            #expect(abs(mean - 0.5) < 0.03)
            #expect(a != (try B.run(s, AddNoise(amount: 50, distribution: .uniform, monochromatic: true, seed: 2), on: b)))
        }
    }

    @Test func medianAndDustRemoveASpeck() throws {
        var s = B.flat(.f32, B.R, [0.2, 0.2, 0.2, 1])
        s.setPixel(x: 10, y: 10, [1, 1, 1, 1])
        for b in B.backends {
            #expect(abs(try B.run(s, Median(radius: 1), on: b).pixel(x: 10, y: 10)[0] - 0.2) < 1e-6)
            #expect(abs(try B.run(s, DustAndScratches(radius: 1, threshold: 255), on: b).pixel(x: 10, y: 10)[0] - 1) < 1e-6)
            #expect(abs(try B.run(s, DustAndScratches(radius: 1, threshold: 50), on: b).pixel(x: 10, y: 10)[0] - 0.2) < 1e-6)
        }
    }

    @Test func maximumRoundnessGrowsAPointIntoADisc() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            var s = B.flat(depth, B.R, [0, 0, 0, 1])
            s.setPixel(x: 20, y: 15, [1, 1, 1, 1])
            for radius: Float in [1, 2, 3.5, 6] {
                for b in B.backends {
                    let round = try B.run(s, Maximum(radius: radius, preserve: .roundness), on: b)
                    let square = try B.run(s, Maximum(radius: radius, preserve: .squareness), on: b)
                    let rs = Int32(radius.rounded(.toNearestOrAwayFromZero))
                    for y in B.R.y0..<B.R.y1 {
                        for x in B.R.x0..<B.R.x1 {
                            let dx = x - 20, dy = y - 15
                            #expect((round.pixel(x: x, y: y)[0] > 0.5) == (Float(dx * dx + dy * dy) <= radius * radius))
                            #expect((square.pixel(x: x, y: y)[0] > 0.5) == (abs(dx) <= rs && abs(dy) <= rs))
                        }
                    }
                }
            }
        }
    }

    @Test func offsetWrapRepeatTransparent() throws {
        let s = B.pattern(.u8, B.R)
        for b in B.backends {
            #expect(try B.run(s, Offset(horizontal: 40, vertical: 30, undefined: .wrap), on: b).readInterleaved(B.R) == s.readInterleaved(B.R))
            let t = try B.run(s, Offset(horizontal: 5, vertical: 0, undefined: .transparent), on: b)
            #expect(t.pixel(x: 2, y: 3)[3] == 0)
            #expect(t.pixel(x: 15, y: 3) == s.pixel(x: 10, y: 3))
            #expect(try B.run(s, Offset(horizontal: 5, vertical: 0, undefined: .repeat), on: b).pixel(x: 2, y: 3) == s.pixel(x: 0, y: 3))
        }
    }

    @Test func motionBlurSpreadsAlongAngleOnly() throws {
        var s = B.flat(.f32, B.R, [0, 0, 0, 1])
        for y in Int32(0)..<30 { s.setPixel(x: 20, y: y, [1, 1, 1, 1]) }
        for b in B.backends {
            #expect(try B.run(s, MotionBlur(angle: 0, distance: 6), on: b).pixel(x: 22, y: 15)[0] > 0.05)
            #expect(try B.run(s, MotionBlur(angle: 90, distance: 6), on: b).pixel(x: 22, y: 15)[0] < 1e-4)
        }
    }

    @Test func halosAndOutputArea() {
        #expect(GaussianBlur(radius: 2).halo(bounds: B.R) == .radius(7))
        let content = PixelRect(x0: 10, y0: 10, x1: 20, y1: 20)
        #expect(FilterEngine.outputArea(BoxBlur(radius: 1), content: content, bounds: B.R, selectionBounds: PixelRect(x0: 0, y0: 0, x1: 12, y1: 12)) == PixelRect(x0: 8, y0: 8, x1: 12, y1: 12))
        #expect(FilterEngine.outputArea(RadialBlur(), content: content, bounds: B.R) == B.R)
        #expect(FilterEngine.outputArea(GaussianBlur(radius: 1), content: .empty, bounds: B.R).isEmpty)
    }

    @Test func layerFiltersRepeatTheCanvasEdge() throws {
        for depth in [SampleType.u8, .u16, .f32] {
            let canvas = PixelRect(x0: 0, y0: 0, x1: 40, y1: 30)
            let s = B.flat(depth, canvas, [0.2, 0.6, 0.4, 1])
            let f = GaussianBlur(radius: 6)
            let area = FilterEngine.outputArea(f, content: s.contentBounds, bounds: canvas)
            for b in B.backends {
                var clamped = s
                try FilterEngine.apply(f, to: &clamped, area: area, bounds: canvas, extent: canvas, on: b)
                #expect(clamped.contentBounds == canvas)
                for (x, y): (Int32, Int32) in [(0, 0), (39, 0), (0, 29), (39, 29), (20, 0)] {
                    let px = clamped.pixel(x: x, y: y)
                    #expect(abs(px[3] - 1) < 1e-3 && abs(px[1] - 0.6) < 2e-3, "\(depth) \(b) (\(x),\(y)) \(px)")
                }
                var faded = s
                try FilterEngine.apply(f, to: &faded, area: area, bounds: canvas, on: b)
                #expect(faded.pixel(x: 0, y: 0)[3] < 0.9)
            }
        }
    }

    @Test func paramsCodableRoundTrip() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        let u = try dec.decode(UnsharpMask.self, from: Data(#"{"amount":50,"radius":1,"threshold":0}"#.utf8))
        #expect(u == UnsharpMask(amount: 50, radius: 1, threshold: 0))
        let r = RadialBlur(amount: 20, method: .zoom, quality: .best, centerX: 0.2, centerY: 0.7)
        #expect(try dec.decode(RadialBlur.self, from: enc.encode(r)) == r)
        let m = try dec.decode(Maximum.self, from: Data(#"{"radius":2,"preserve":"roundness"}"#.utf8))
        #expect(m == Maximum(radius: 2, preserve: .roundness))
        let i = IrisBlur(pins: [IrisPin(x: 0.2, blur: 3)])
        #expect(try dec.decode(IrisBlur.self, from: enc.encode(i)) == i)
    }
}
