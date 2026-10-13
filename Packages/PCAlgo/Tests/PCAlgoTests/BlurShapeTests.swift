// Port of photocraft-algo (crates/algo/src/blur2.rs, shape_blur_tests.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Testing
@testable import PCAlgo
import PCFoundation

@Suite struct BlurShapeTests {
    @Test func smartBlurParity() throws {
        var w: Float = 0
        for m in SmartBlurMode.allCases {
            for q in BlurQuality.allCases {
                for (r, t): (Float, Float) in [(3, 25), (9.5, 60), (0.1, 0.1)] {
                    w = max(w, try Parity.checkVariants(SmartBlur(radius: r, threshold: t, quality: q, mode: m)))
                }
            }
        }
        ParityLog.record("SmartBlur", w)
    }

    @Test func averageParity() throws {
        let w = try Parity.checkVariants(AverageBlur())
        ParityLog.record("Average", w)
    }

    @Test func averageOfTwoHalves() {
        let r = PixelRect(x: 0, y: 0, width: 4, height: 1)
        let img = FloatImage(rect: r, channels: 4, data: [1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1])
        let out = AverageBlur().cpu(img, out: r, ctx: FilterContext(bounds: r, mode: .rgb, alpha: true))
        #expect(abs(out.data[0] - 0.5) < 1e-6 && abs(out.data[2] - 0.5) < 1e-6 && out.data[3] == 1)
    }

    @Test func shapeBlurParity() throws {
        var w: Float = 0
        for s in BlurShape.allCases {
            for r: Float in [0.3, 5, 11.5] {
                w = max(w, try Parity.checkVariants(ShapeBlur(radius: r, shape: s), out: PixelRect(x: 3, y: -2, width: 37, height: 29)))
            }
        }
        ParityLog.record("ShapeBlur", w)
    }

    /// Spans of a circle hold its pixel count; a square of radius r is (2r+1)².
    @Test func spansCountPixels() {
        let sq = SpanKit.Spans(4) { SpanKit.inside(.square, $0, $1) }
        #expect(sq.count == 81)
        let small = SpanKit.Spans(0.2) { SpanKit.inside(.circle, $0, $1) }
        #expect(small.count == 1)
        let ring = SpanKit.Spans(10) { SpanKit.inside(.ring, $0, $1) }
        #expect(ring.rows.count > 21, "a ring has two runs on its middle rows")
    }

    /// The span mean equals the direct mean over the shape's pixels.
    @Test func shapeBlurMatchesDirectMean() {
        let src = TestImage.make(PixelRect(x: -8, y: -8, width: 40, height: 30), channels: 4, alpha: true, seed: 4, eightBit: false)
        let out = PixelRect(x: 0, y: 0, width: 24, height: 14)
        let f = ShapeBlur(radius: 6, shape: .star)
        let fast = f.cpu(src, out: out, ctx: FilterContext(bounds: out, mode: .rgb, alpha: true))
        let sp = f.spans
        var direct = FloatImage(rect: out, channels: 4)
        for y in out.y0..<out.y1 {
            for x in out.x0..<out.x1 {
                var acc = [Double](repeating: 0, count: 4)
                for (dy, a, b) in sp.rows { for dx in a...b {
                    let ax = Double(src.get(x + dx, y + dy, 3))
                    for c in 0..<3 { acc[c] += Double(src.get(x + dx, y + dy, c)) * ax }
                    acc[3] += ax
                } }
                let i = direct.index(x: x, y: y)
                let al = acc[3] / sp.count
                for c in 0..<3 { direct.data[i + c] = al > 1e-7 ? Float(acc[c] / sp.count / al) : 0 }
                direct.data[i + 3] = Float(al)
            }
        }
        #expect(Parity.maxError(fast, direct, alpha: true) < 1e-5)
    }

    @Test func lensBlurParity() throws {
        var w: Float = 0
        let specs: [LensBlur] = [
            LensBlur(radius: 6),
            LensBlur(radius: 9, blades: 5, curvature: 40, rotation: 30, depth: .transparency, focalDistance: 128, brightness: 60, threshold: 140, noise: 20),
            LensBlur(radius: 4, blades: 8, curvature: 100, depth: .transparency, invertDepth: true, noise: 50, distribution: .gaussian, monochromatic: true, seed: 9),
            LensBlur(radius: 0, noise: 10),
        ]
        for s in specs { w = max(w, try Parity.checkVariants(s, out: PixelRect(x: 3, y: -2, width: 37, height: 29))) }
        // Depth from a layer mask.
        let out = PixelRect(x: 0, y: 0, width: 33, height: 27)
        let map = TestImage.make(out.outset(by: 3), channels: 1, alpha: false, seed: 21)
        let lb = LensBlur(radius: 7, depth: .layerMask, focalDistance: 60, depthMap: map)
        let src = TestImage.make(out.outset(by: 8), channels: 4, alpha: true)
        if let e = try Parity.check(lb, src: src, out: out, ctx: FilterContext(bounds: out, mode: .rgb, alpha: true)) { w = max(w, e) }
        ParityLog.record("LensBlur", w)
    }
}
