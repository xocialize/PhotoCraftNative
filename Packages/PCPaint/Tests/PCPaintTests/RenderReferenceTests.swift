// Port of photocraft-paint (crates/paint/src/render_reference.rs tests), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The production rasteriser (with its computed-tip fast path) against the frozen scalar reference,
// bit for bit.

import Testing
import PCFoundation
@testable import PCPaint

func compare(_ ctx: BrushContext, _ dab: Dab, dual: Bool, rect: PixelRect, withDepth: Bool) {
    // Reused, dirty buffers also check clearing and resizing.
    var actual = [Float](repeating: 0.75, count: 19), expected = [Float](repeating: 0.75, count: 19)
    var actualDepth = [Float](repeating: 0.25, count: 23), expectedDepth = [Float](repeating: 0.25, count: 23)
    ctx.rasterizeInto(dab, dual: dual, rect: rect, &actual, depth: &actualDepth, withDepth: withDepth)
    ctx.rasterizeReference(dab, dual: dual, rect: rect, &expected, depth: &expectedDepth, withDepth: withDepth)
    for (label, a, b) in [("coverage", actual, expected), ("depth", actualDepth, expectedDepth)] {
        #expect(a.count == b.count)
        let mismatch = zip(a, b).enumerated().first { $0.element.0.bitPattern != $0.element.1.bitPattern }
        #expect(mismatch == nil, "\(label) mismatch \(String(describing: mismatch)); \(dab); dual=\(dual), rect=\(rect)")
    }
}

@Suite struct RenderReferenceTests {
    @Test func computedTipsMatchScalarBits() {
        for aliased in [false, true] {
            for hardness: Float in [-0.5, 0, 0.1, 0.5, 0.9999, 1, 1.5] {
                let ctx = BrushContext(with(BrushSettings()) { $0.aliased = aliased; $0.hardness = hardness })
                for radius: Float in [0.5, 1, 2.99, 3, 3.01, 15, 31.5] {
                    for roundness: Float in [0, 0.1, 0.4, 1] {
                        for alpha: Float in [-0.5, -0.0, 0, 0.37, 1] {
                            var d = Dab.round(PaintPoint(-31.25, 63.75), radius, alpha)
                            d.roundness = roundness
                            d.flipX = true
                            d.flipY = true
                            compare(ctx, d, dual: false, rect: ctx.dabRect(d, dual: false), withDepth: false)
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [(Float(0), false), (1, false), (1, true)])
    func largeCornerDabsKeepOffCanvasCoverage(hardness: Float, aliased: Bool) {
        do {
            let ctx = BrushContext(with(BrushSettings()) { $0.hardness = hardness; $0.aliased = aliased })
            let d = Dab.round(PaintPoint(-1050.25, -1050.75), 1500, 0.73)
            let rect = ctx.dabRect(d, dual: false)
            compare(ctx, d, dual: false, rect: rect, withDepth: false)
            var coverage: [Float] = []
            ctx.rasterize(d, dual: false, rect: rect, &coverage)
            // The layer is an infinite plane: paint outside the visible document must survive.
            #expect(coverage.enumerated().contains { $0.element > 0 && rect.x0 + Int32($0.offset % rect.width) < 0 })
            compare(ctx, d, dual: false, rect: PixelRect(x0: 0, y0: 0, x1: 32, y1: 32), withDepth: false)
            compare(ctx, d, dual: false, rect: PixelRect(x0: 0, y0: 0, x1: 0, y1: 0), withDepth: false)
        }
    }

    @Test func featureAndExceptionalDabsMatchScalarBits() {
        let tip = GrayTile(width: 8, height: 5) { x, y in Float((x + y) % 7) / 6 }
        for feature in 0..<7 {
            var b = with(BrushSettings()) { $0.hardness = 0.25 }
            switch feature {
            case 0: b.noise = true
            case 1: b.wetEdges = true
            case 2: b.aliased = true; b.square = true
            case 3: b.tip = .sampled(tip)
            case 4: b.texture.enabled = true; b.texture.eachTip = true; b.texture.pattern = .tile(tip)
            case 5: b.dualBrush.tip = .sampled(tip)
            default: break
            }
            let ctx = BrushContext(b)
            for dual in [false, true] {
                for withDepth in [false, true] {
                    for (angle, projScale) in [(Float(0), Float(1)), (0.7, 1), (0, 0.6)] {
                        var d = Dab.round(PaintPoint(63.5, -0.25), 15, 0.47)
                        d.angle = angle
                        d.roundness = 0.4
                        d.projScale = projScale
                        compare(ctx, d, dual: dual, rect: ctx.dabRect(d, dual: dual), withDepth: withDepth)
                    }
                }
            }
        }
        let ctx = BrushContext(BrushSettings())
        for value in [Float.nan, Float(bitPattern: 0x7f80_0123), .infinity, -.infinity] {
            for field in 0..<4 {
                var d = Dab.round(PaintPoint(0, 0), 15, 1)
                switch field {
                case 0: d.alpha = value
                case 1: d.angle = value
                case 2: d.radius = value
                default: d.roundness = value
                }
                compare(ctx, d, dual: false, rect: PixelRect(x0: -4, y0: -4, x1: 4, y1: 4), withDepth: false)
            }
            let c2 = BrushContext(with(BrushSettings()) { $0.hardness = value })
            compare(c2, Dab.round(PaintPoint(0, 0), 15, 1), dual: false, rect: PixelRect(x0: -16, y0: -16, x1: 16, y1: 16), withDepth: false)
        }
    }

    @Test func computedTipsMatchAtPixelAndFloatBoundaries() {
        for aliased in [false, true] {
            for center in [PaintPoint(0, -0.0), PaintPoint(0.5, 0.5), PaintPoint(255.9999, -256.0001), PaintPoint(16_777_216.25, -16_777_216.75)] {
                for radius: Float in [3, 3.5, 15.25, 113.75] {
                    for hardness: Float in [0, 0.6, 1] {
                        let ctx = BrushContext(with(BrushSettings()) { $0.hardness = hardness; $0.aliased = aliased })
                        var d = Dab.round(center, radius, 0.137)
                        d.roundness = 0.375
                        compare(ctx, d, dual: false, rect: ctx.dabRect(d, dual: false), withDepth: false)
                    }
                }
            }
        }
    }
}
